# Load Packages
using Dates, FastDEQ, MLDatasets, MPI, Serialization, Statistics, ParameterSchedulers, Plots, Random, Wandb
using ParameterSchedulers: Stateful, Scheduler, Cos

CUDA.versioninfo()

MPI.Init()
FluxMPI.Init()
enable_fast_mode!()
CUDA.allowscalar(false)

const MPI_COMM_WORLD = MPI.COMM_WORLD
const MPI_COMM_SIZE = MPI.Comm_size(MPI_COMM_WORLD)

## Models
function get_model(maxiters::Int, abstol::T, reltol::T, model_type::String, solver_type::String, batch_size::Int,
                   jac_reg::Bool, args...; mode::Symbol=:rel_norm, solver=Tsit5(), kwargs...) where {T}
    main_layer = Parallel(+, Dense(128, 128, tanh_fast; bias=false), Dense(128, 128, tanh_fast; bias=false))

    if solver_type == "dynamicss"
        solver = get_default_dynamicss_solver(reltol, abstol, solver; mode=mode)
    else
        solver = get_default_ssrootfind_solver(reltol, abstol, LimitedMemoryBroydenSolver; device=gpu,
                                               original_dims=(128, 1), batch_size=batch_size, maxiters=maxiters)
    end

    if model_type == "skip"
        aux_layer = Dense(128, 128, tanh_fast)
        deq = SkipDeepEquilibriumNetwork(main_layer, aux_layer, solver; maxiters=maxiters,
                                         sensealg=get_default_ssadjoint(reltol, abstol, min(maxiters, 15)),
                                         verbose=false, jacobian_regularization=jac_reg)
    else
        _deq = model_type == "vanilla" ? DeepEquilibriumNetwork : SkipDeepEquilibriumNetwork
        deq = _deq(main_layer, solver; maxiters=maxiters,
                   sensealg=get_default_ssadjoint(reltol, abstol, min(maxiters, 15)), verbose=false,
                   jacobian_regularization=jac_reg)
    end

    model = DEQChain(Dense(784, 128, tanh_fast), deq, Dense(128, 10))

    return (MPI_COMM_SIZE > 1 ? DataParallelFluxModel : gpu)(model)
end

## Utilities
register_nfe_counts(deq, buffer) = () -> push!(buffer, get_and_clear_nfe!(deq))

function invoke_gc()
    GC.gc(true)
    CUDA.reclaim()
    return nothing
end

function loss_and_accuracy(model, dataloader)
    matches, total_loss, total_datasize, total_nfe = 0, 0, 0, 0
    for (x, y) in dataloader
        x = gpu(x)
        y = gpu(y)

        ŷ = model(x)
        ŷ = ŷ isa Tuple ? ŷ[1] : ŷ  # Handle SkipDEQ
        total_nfe += get_and_clear_nfe!(model) * size(x, ndims(x))
        total_loss += Flux.Losses.logitcrossentropy(ŷ, y) * size(x, ndims(x))
        matches += sum(argmax.(eachcol(ŷ)) .== Flux.onecold(cpu(y)))
        total_datasize += size(x, ndims(x))
    end
    return (total_loss / total_datasize, matches / total_datasize, total_nfe / total_datasize)
end

## Training Function
function train(config::Dict, name_extension::String="")
    comm = MPI_COMM_WORLD
    rank = MPI.Comm_rank(comm)

    ## Setup Logging & Experiment Configuration
    t = MPI.Bcast!([now()], 0, comm)[1]
    expt_name = "fastdeqjl-supervised_mnist_classification-$(t)-$(name_extension)"
    lg_wandb = WandbLoggerMPI(; project="FastDEQ.jl", name=expt_name, config=config)
    lg_term = PrettyTableLogger("logs/" * expt_name * ".log",
                                ["Epoch Number", "Train/NFE", "Train/Accuracy", "Train/Loss", "Train/Time", "Test/NFE",
                                 "Test/Accuracy", "Test/Loss", "Test/Time"],
                                ["Train/Running/NFE", "Train/Running/Loss"])

    ## Reproducibility
    Random.seed!(get_config(lg_wandb, "seed"))

    ## Dataset
    batch_size = get_config(lg_wandb, "batch_size")
    eval_batch_size = get_config(lg_wandb, "eval_batch_size")

    _xs_train, _ys_train = MNIST.traindata(Float32)
    _xs_test, _ys_test = MNIST.testdata(Float32)
    μ = reshape([0.1307], 1, 1)
    σ² = reshape([0.3081], 1, 1)

    xs_train, ys_train = Flux.flatten(_xs_train), Float32.(Flux.onehotbatch(_ys_train, 0:9))
    _xs_train = (_xs_train .- μ) ./ σ²
    xs_test, ys_test = Flux.flatten(_xs_test), Float32.(Flux.onehotbatch(_ys_test, 0:9))
    _xs_test = (_xs_test .- μ) ./ σ²

    traindata = (xs_train, ys_train)
    trainiter = DataParallelDataLoader(traindata; batchsize=batch_size, shuffle=true)
    trainiter_test = DataParallelDataLoader(traindata; batchsize=eval_batch_size, shuffle=false)
    testiter = DataParallelDataLoader((xs_test, ys_test); batchsize=eval_batch_size, shuffle=false)

    ## Model Setup
    model = get_model(get_config(lg_wandb, "maxiters"), Float32(get_config(lg_wandb, "abstol")),
                      Float32(get_config(lg_wandb, "reltol")), get_config(lg_wandb, "model_type"),
                      get_config(lg_wandb, "solver_type"), batch_size, get_config(lg_wandb, "jac_reg"))

    loss_function = SupervisedLossContainer(Flux.Losses.logitcrossentropy, 1.0f0, 1.0f0)

    ## Warmup
    __x = gpu(rand(784, 1))
    __y = gpu(Flux.onehotbatch([1], 0:9))
    loss_function(model, __x, __y)
    @info "Rank $rank: Forward Pass Warmup Completed"
    Zygote.gradient(() -> loss_function(model, __x, __y), Flux.params(model))
    @info "Rank $rank: Warmup Completed"

    nfe_counts = []
    cb = register_nfe_counts(model, nfe_counts)

    ## Training Loop
    ps = Flux.params(model)
    sched = Stateful(Cos(get_config(lg_wandb, "learning_rate"), 1e-6,
                         length(trainiter) * get_config(lg_wandb, "epochs")))
    opt = ADAMW(get_config(lg_wandb, "learning_rate"), (0.9, 0.999), 0.0000025)
    step = 1

    train_vec = zeros(3)
    test_vec = zeros(3)

    datacount_trainiter = length(trainiter.indices)
    datacount_testiter = length(testiter.indices)
    datacount_trainiter_total = size(xs_train, ndims(xs_train))
    datacount_testiter_total = size(xs_test, ndims(xs_test))

    @info "Rank $rank: [ $datacount_trainiter / $datacount_trainiter_total ] Training Images | [ $datacount_testiter / $datacount_testiter_total ] Test Images"

    for epoch in 1:get_config(lg_wandb, "epochs")
        try
            invoke_gc()
            train_time = 0
            for (x, y) in trainiter
                x = gpu(x)
                y = gpu(y)

                train_start_time = time()
                _res = Zygote.withgradient(() -> loss_function(model, x, y), ps)
                loss = _res.val
                gs = _res.grad
                Flux.Optimise.update!(opt, ps, gs)
                opt[3].eta = ParameterSchedulers.next!(sched)
                train_time += time() - train_start_time

                ### Store the NFE Count
                cb()

                ### Log the losses
                log(lg_wandb,
                    Dict("Training/Step/Loss" => loss, "Training/Step/NFE" => nfe_counts[end],
                         "Training/Step/Count" => step))
                lg_term(; records=Dict("Train/Running/NFE" => nfe_counts[end], "Train/Running/Loss" => loss))
                step += 1
            end

            ### Training Loss/Accuracy
            invoke_gc()
            train_loss, train_acc, train_nfe = loss_and_accuracy(model, trainiter_test)

            if MPI_COMM_SIZE > 1
                train_vec .= [train_loss, train_acc, train_nfe] .* datacount_trainiter
                safe_reduce!(train_vec, +, 0, comm)
                train_loss, train_acc, train_nfe = train_vec ./ datacount_trainiter_total
            end

            log(lg_wandb,
                Dict("Training/Epoch/Count" => epoch, "Training/Epoch/Loss" => train_loss,
                     "Training/Epoch/NFE" => train_nfe, "Training/Epoch/Accuracy" => train_acc))

            ### Testing Loss/Accuracy
            invoke_gc()
            test_time = time()
            test_loss, test_acc, test_nfe = loss_and_accuracy(model, testiter)
            test_time = time() - test_time

            if MPI_COMM_SIZE > 1
                test_vec .= [test_loss, test_acc, test_nfe] .* datacount_trainiter
                safe_reduce!(test_vec, +, 0, comm)
                test_loss, test_acc, test_nfe = test_vec ./ datacount_trainiter_total
            end

            log(lg_wandb,
                Dict("Testing/Epoch/Count" => epoch, "Testing/Epoch/Loss" => test_loss, "Testing/Epoch/NFE" => test_nfe,
                     "Testing/Epoch/Accuracy" => test_acc))
            lg_term(epoch, train_nfe, train_acc, train_loss, train_time, test_nfe, test_acc, test_loss, test_time)

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

## Run Experiment
experiment_configurations = []
for seed in [6171, 3859, 2961]  # Generated this by randomly sampling from 1:10000
    for jac_reg in [true, false]
        for model_type in ["skip", "vanilla"]
            push!(experiment_configurations, (seed, model_type, jac_reg))
        end
    end
end

TASK_ID = parse(Int, ARGS[1])
NUM_TASKS = parse(Int, ARGS[2])

for i in TASK_ID:NUM_TASKS:length(experiment_configurations)
    seed, model_type, jac_reg = experiment_configurations[i]

    if MPI.Comm_rank(MPI_COMM_WORLD) == 0
        @info "Seed = $seed | Model Type = $model_type | Jacobian Regularization = $jac_reg"
    end

    config = Dict("seed" => seed, "learning_rate" => 0.001, "abstol" => 1.0f-2, "reltol" => 1.0f-2,
                "maxiters" => 50, "epochs" => 25, "batch_size" => 64, "eval_batch_size" => 64,
                "model_type" => model_type, "solver_type" => "ssrootfind", "jac_reg" => jac_reg)

    model, nfe_counts = train(config, "seed-$(seed)_model-$(model_type)_jac_reg-$(jac_reg)")
end