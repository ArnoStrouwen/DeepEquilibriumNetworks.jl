# Load Packages
using CUDA,
    Dates,
    DiffEqSensitivity,
    FastDEQ,
    Flux,
    FluxMPI,
    MLDatasets,
    MPI,
    OrdinaryDiffEq,
    Statistics,
    SteadyStateDiffEq,
    Plots,
    Random,
    Wandb,
    Zygote
using ParameterSchedulers: Scheduler, Cos

MPI.Init()
CUDA.allowscalar(false)

const MPI_COMM_WORLD = MPI.COMM_WORLD
const MPI_COMM_SIZE = MPI.Comm_size(MPI_COMM_WORLD)

## Models
function get_model(
    maxiters::Int,
    abstol::T,
    reltol::T,
    batch_size::Int,
    model_type::String,
) where {T}
    main_layers = (
        BasicResidualBlock((28, 28), 8, 8),
        BasicResidualBlock((14, 14), 16, 16),
        BasicResidualBlock((7, 7), 32, 32),
    )
    mapping_layers = [
        identity downsample_module(8, 16, 28, 14) downsample_module(8, 32, 28, 7)
        upsample_module(16, 8, 14, 28) identity downsample_module(16, 32, 14, 7)
        upsample_module(32, 8, 7, 28) upsample_module(32, 16, 7, 14) identity
    ]
    model = DEQChain(
        expand_channels_module(1, 8),
        (
            model_type == "vanilla" ? MultiScaleDeepEquilibriumNetwork :
            MultiScaleSkipDeepEquilibriumNetwork
        )(
            main_layers,
            mapping_layers,
            get_default_dynamicss_solver(abstol, reltol),
            # get_default_ssrootfind_solver(abstol, reltol, LimitedMemoryBroydenSolver;
            #                               device = gpu, original_dims = (1, (28 * 28 *  8) +
            #                                                                 (14 * 14 * 16) +
            #                                                                 ( 7 *  7 * 32)),
            #                               batch_size = batch_size, maxiters = maxiters),
            maxiters = maxiters,
            sensealg = get_default_ssadjoint(abstol, reltol, maxiters),
            verbose = false,
        ),
        t -> tuple(t...),
        Parallel(
            +,
            downsample_module(8, 32, 28, 7),
            downsample_module(16, 32, 14, 7),
            expand_channels_module(32, 32),
        ),
        Flux.flatten,
        Dense(7 * 7 * 32, 10; bias = true),
    )
    if MPI_COMM_SIZE > 1
        return DataParallelFluxModel(
            model,
            [i % length(CUDA.devices()) for i = 1:MPI_COMM_SIZE],
        )
    else
        return model |> gpu
    end
end


## Utilities
function register_nfe_counts(model, buffer)
    callback() = push!(buffer, get_and_clear_nfe!(model))
    return callback
end

function loss_and_accuracy(model, dataloader)
    matches, total_loss, total_datasize, total_nfe = 0, 0, 0, 0
    for (x, y) in dataloader
        x = x |> gpu
        y = y |> gpu

        ŷ = model(x)
        ŷ = ŷ isa Tuple ? ŷ[1] : ŷ  # Handle SkipDEQ
        total_nfe += get_and_clear_nfe!(model) * size(x, ndims(x))
        total_loss += Flux.Losses.logitcrossentropy(ŷ, y) * size(x, ndims(x))
        matches += sum(argmax.(eachcol(ŷ)) .== Flux.onecold(y |> cpu))
        total_datasize += size(x, ndims(x))
    end
    return (
        total_loss / total_datasize,
        matches / total_datasize,
        total_nfe / total_datasize,
    )
end


## Training Function
function train(config::Dict)
    comm = MPI_COMM_WORLD
    rank = MPI.Comm_rank(comm)

    ## Setup Logging & Experiment Configuration
    expt_name = "fastdeqjl-supervised_mnist_classication-mdeq-$(now())"
    lg_wandb =
        WandbLogger(project = "FastDEQ.jl", name = expt_name, config = config)
    lg_term = PrettyTableLogger(
        expt_name,
        [
            "Epoch Number",
            "Train/NFE",
            "Train/Accuracy",
            "Train/Loss",
            "Test/NFE",
            "Test/Accuracy",
            "Test/Loss",
        ],
        ["Train/Running/NFE", "Train/Running/Loss"],
    )

    ## Reproducibility
    Random.seed!(get_config(lg_wandb, "seed"))

    ## Dataset
    batch_size = get_config(lg_wandb, "batch_size")
    eval_batch_size = get_config(lg_wandb, "eval_batch_size")

    _xs_train, _ys_train = MNIST.traindata(Float32)
    _xs_test, _ys_test = MNIST.testdata(Float32)

    xs_train, ys_train =
        Flux.unsqueeze(_xs_train, 3), Float32.(Flux.onehotbatch(_ys_train, 0:9))
    xs_test, ys_test =
        Flux.unsqueeze(_xs_test, 3), Float32.(Flux.onehotbatch(_ys_test, 0:9))

    traindata = (xs_train, ys_train)
    trainiter = DataParallelDataLoader(
        traindata;
        batchsize = batch_size,
        shuffle = true,
    )
    trainiter_test = DataParallelDataLoader(
        traindata;
        batchsize = eval_batch_size,
        shuffle = false,
    )
    testiter = DataParallelDataLoader(
        (xs_test, ys_test);
        batchsize = eval_batch_size,
        shuffle = false,
    )

    ## Model Setup
    model = get_model(
        get_config(lg_wandb, "maxiters"),
        Float32(get_config(lg_wandb, "abstol")),
        Float32(get_config(lg_wandb, "reltol")),
        batch_size,
        get_config(lg_wandb, "model_type"),
    )

    loss_function =
        SupervisedLossContainer(Flux.Losses.logitcrossentropy, 1.0f0)

    ## Warmup
    __x = rand(28, 28, 1, 1) |> gpu
    __y = Flux.onehotbatch([1], 0:9) |> gpu
    loss_function(model, __x, __y)
    @info "Rank $rank: Forward Pass Warmup Completed"
    Zygote.gradient(() -> loss_function(model, __x, __y), Flux.params(model))
    @info "Rank $rank: Warmup Completed"

    nfe_counts = []
    cb = register_nfe_counts(model, nfe_counts)

    ## Training Loop
    ps = Flux.params(model)
    opt = Scheduler(
        Cos(
            get_config(lg_wandb, "learning_rate"),
            1e-6,
            length(trainiter) * get_config(lg_wandb, "epochs"),
        ),
        ADAM(get_config(lg_wandb, "learning_rate"), (0.9, 0.999)),
    )
    step = 1

    train_vec = zeros(3)
    test_vec = zeros(3)

    datacount_trainiter = length(trainiter.indices)
    datacount_testiter = length(testiter.indices)
    datacount_trainiter_total = size(xs_train, ndims(xs_train))
    datacount_testiter_total = size(xs_test, ndims(xs_test))

    @info "Rank $rank: [ $datacount_trainiter / $datacount_trainiter_total ] Training Images | [ $datacount_testiter / $datacount_testiter_total ] Test Images"

    for epoch = 1:get_config(lg_wandb, "epochs")
        try
            for (x, y) in trainiter
                x = x |> gpu
                y = y |> gpu

                _res = Zygote.withgradient(() -> loss_function(model, x, y), ps)
                loss = _res.val
                gs = _res.grad
                Flux.Optimise.update!(opt, ps, gs)

                ### Store the NFE Count
                cb()

                ### Log the losses
                log(
                    lg_wandb,
                    Dict(
                        "Training/Step/Loss" => loss,
                        "Training/Step/NFE" => nfe_counts[end],
                        "Training/Step/Count" => step,
                    ),
                )
                lg_term(;
                    records = Dict(
                        "Train/Running/NFE" => nfe_counts[end],
                        "Train/Running/Loss" => loss,
                    ),
                )
                step += 1
            end

            ### Training Loss/Accuracy
            train_loss, train_acc, train_nfe =
                loss_and_accuracy(model, trainiter_test)

            if MPI_COMM_SIZE > 1
                train_vec .=
                    [train_loss, train_acc, train_nfe] .* datacount_trainiter
                safe_reduce!(train_vec, +, 0, comm)
                train_loss, train_acc, train_nfe =
                    train_vec ./ datacount_trainiter_total
            end

            log(
                lg_wandb,
                Dict(
                    "Training/Epoch/Count" => epoch,
                    "Training/Epoch/Loss" => train_loss,
                    "Training/Epoch/NFE" => train_nfe,
                    "Training/Epoch/Accuracy" => train_acc,
                ),
            )

            ### Testing Loss/Accuracy
            test_loss, test_acc, test_nfe = loss_and_accuracy(model, testiter)

            if MPI_COMM_SIZE > 1
                test_vec .=
                    [test_loss, test_acc, test_nfe] .* datacount_trainiter
                safe_reduce!(test_vec, +, 0, comm)
                test_loss, test_acc, test_nfe =
                    test_vec ./ datacount_trainiter_total
            end

            log(
                lg_wandb,
                Dict(
                    "Testing/Epoch/Count" => epoch,
                    "Testing/Epoch/Loss" => test_loss,
                    "Testing/Epoch/NFE" => test_nfe,
                    "Testing/Epoch/Accuracy" => test_acc,
                ),
            )
            lg_term(
                epoch,
                train_nfe,
                train_acc,
                train_loss,
                test_nfe,
                test_acc,
                test_loss,
            )

            MPI.Barrier(comm)
        catch ex
            if ex isa Flux.Optimise.StopException
                break
            elseif ex isa Flux.Optimise.SkipException
                continue
            else
                rethrow(ex)
            end
        end
    end

    close(lg_wandb)
    close(lg_term)

    return model, nfe_counts
end

## Plotting
function plot_nfe_counts(nfe_counts_1, nfe_counts_2)
    p = plot(nfe_counts_1, label = "Vanilla DEQ")
    plot!(p, nfe_counts_2, label = "Skip DEQ")
    xlabel!(p, "Training Iteration")
    ylabel!(p, "NFE Count")
    title!(p, "NFE over Training Iterations of DEQ vs SkipDEQ")
    return p
end

## Run Experiment
nfe_count_dict = Dict("vanilla" => [], "skip" => [])

for seed in [1, 11, 111]
    for model_type in ["skip", "vanilla"]
        config = Dict(
            "seed" => seed,
            "learning_rate" => 0.001,
            "abstol" => 0.1f0,
            "reltol" => 0.1f0,
            "maxiters" => 15,
            "epochs" => 25,
            "batch_size" => 64,
            "eval_batch_size" => 128,
            "model_type" => model_type,
        )

        model, nfe_counts = train(config)

        push!(nfe_count_dict[model_type], nfe_counts)
    end
end

plot_nfe_counts(
    vec(mean(hcat(nfe_count_dict["vanilla"]...), dims = 2)),
    vec(mean(hcat(nfe_count_dict["skip"]...), dims = 2)),
)
