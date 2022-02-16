"""
    MultiScaleSkipDeepEquilibriumNetwork(main_layers::Tuple, mapping_layers::Matrix, shortcut_layers::Tuple,
                                         solver; post_fuse_layers::Union{Tuple,Nothing}=nothing, p=nothing,
                                         sensealg=SteadyStateAdjoint(0.1f0, 0.1f0, 10), kwargs...)
    MultiScaleSkipDeepEquilibriumNetwork(main_layers::Tuple, mapping_layers::Matrix, solver;
                                         post_fuse_layers::Union{Tuple,Nothing}=nothing, p=nothing,
                                         sensealg=SteadyStateAdjoint(0.1f0, 0.1f0, 10), kwargs...)

Multiscale Deep Equilibrium Network as proposed in [baimultiscale2020](@cite)

## Arguments

* `main_layers`: Tuple of Explicit Neural Networks. The first network needs to take 2 inputs, the other ones only take 1 input
* `mapping_layers`: Matrix of Explicit Neural Networks. The ``(i, j)^{th}`` network takes the output of ``i^{th}`` `main_layer`
                    and passes it to the ``j^{th}`` `main_layer`
* `shortcut_layers`: Shortcuts for the network (If not given, then we create SkipDEQV2)
* `solver`: Solver for the optimization problem (See: [`ContinuousDEQSolver`](@ref) & [`DiscreteDEQSolver`](@ref))
* `post_fuse_layers`: Tuple of Explicit Neural Networks. Applied after the `mapping_layers` (Default: `nothing`)
* `p`: Optional parameters for the `model`
* `sensealg`: See [`SteadyStateAdjoint`](@ref)
* `kwargs`: Additional Parameters that are directly passed to `solve`

## Example

```julia
# MSkipDEQ
model = MultiScaleSkipDeepEquilibriumNetwork(
    (
        Parallel(+, Dense(4, 4, tanh_fast), Dense(4, 4, tanh_fast)),
        Dense(3, 3, tanh_fast), Dense(2, 2, tanh_fast),
        Dense(1, 1, tanh_fast)
    ),
    [
        NoOpLayer() Dense(4, 3, tanh_fast) Dense(4, 2, tanh_fast) Dense(4, 1, tanh_fast);
        Dense(3, 4, tanh_fast) NoOpLayer() Dense(3, 2, tanh_fast) Dense(3, 1, tanh_fast);
        Dense(2, 4, tanh_fast) Dense(2, 3, tanh_fast) NoOpLayer() Dense(2, 1, tanh_fast);
        Dense(1, 4, tanh_fast) Dense(1, 3, tanh_fast) Dense(1, 2, tanh_fast) NoOpLayer()
    ],
    (
        Dense(4, 4, tanh_fast),
        Dense(4, 3, tanh_fast),
        Dense(4, 2, tanh_fast),
        Dense(4, 1, tanh_fast)
    ),
    ContinuousDEQSolver(VCABM3(); abstol=0.01f0, reltol=0.01f0),
)

model(rand(Float32, 4, 1))


# MSkipDEQV2
model = MultiScaleSkipDeepEquilibriumNetwork(
    (
        Parallel(+, Dense(4, 4, tanh_fast), Dense(4, 4, tanh_fast)),
        Dense(3, 3, tanh_fast), Dense(2, 2, tanh_fast),
        Dense(1, 1, tanh_fast)
    ),
    [
        NoOpLayer() Dense(4, 3, tanh_fast) Dense(4, 2, tanh_fast) Dense(4, 1, tanh_fast);
        Dense(3, 4, tanh_fast) NoOpLayer() Dense(3, 2, tanh_fast) Dense(3, 1, tanh_fast);
        Dense(2, 4, tanh_fast) Dense(2, 3, tanh_fast) NoOpLayer() Dense(2, 1, tanh_fast);
        Dense(1, 4, tanh_fast) Dense(1, 3, tanh_fast) Dense(1, 2, tanh_fast) NoOpLayer()
    ],
    ContinuousDEQSolver(VCABM3(); abstol=0.01f0, reltol=0.01f0),
)

model(rand(Float32, 4, 1))
```

See also: [`DeepEquilibriumNetwork`](@ref), [`SkipDeepEquilibriumNetwork`](@ref), [`MultiScaleDeepEquilibriumNetwork`](@ref)
"""
struct MultiScaleSkipDeepEquilibriumNetwork{M3<:Union{Nothing,Parallel},N,M1<:Parallel,M2<:Union{Chain,FChain},RE1,
                                            RE2,RE3,P,A,K,S} <: AbstractDeepEquilibriumNetwork
    main_layers::M1
    mapping_layers::M2
    shortcut_layers::M3
    main_layers_re::RE1
    mapping_layers_re::RE2
    shortcut_layers_re::RE3
    p::P
    ordered_split_idxs::NTuple{N,Int}
    solver::A
    kwargs::K
    sensealg::S
    stats::DEQTrainingStats

    function MultiScaleSkipDeepEquilibriumNetwork(main_layers::Parallel,
                                                  mapping_layers::Union{Chain,FChain},
                                                  shortcut_layers::Union{Nothing,Parallel}, re1, re2, re3, p,
                                                  ordered_split_idxs, solver::A, kwargs::K, sensealg::S,
                                                  stats) where {A,K,S}
        @assert length(mapping_layers) == 2
        @assert mapping_layers[1] isa MultiParallelNet

        p_main_layers, re_main_layers = destructure_parameters(main_layers)
        p_mapping_layers, re_mapping_layers = destructure_parameters(mapping_layers)
        p_shortcut_layers, re_shortcut_layers = shortcut_layers === nothing ? ([], nothing) :
                                                destructure_parameters(shortcut_layers)

        ordered_split_idxs = tuple(cumsum([0, length(p_main_layers), length(p_mapping_layers),
                                           length(p_shortcut_layers)])...)

        p = p === nothing ? vcat(p_main_layers, p_mapping_layers, p_shortcut_layers) : convert(typeof(p_main_layers), p)

        return new{typeof(shortcut_layers),length(ordered_split_idxs),
                   typeof.((main_layers, mapping_layers, re_main_layers, re_mapping_layers, re_shortcut_layers, p))...,
                   A,K,S}(main_layers, mapping_layers, shortcut_layers, re_main_layers,
                          re_mapping_layers, re_shortcut_layers, p, ordered_split_idxs, solver, kwargs, sensealg, stats)
    end
end

Flux.@functor MultiScaleSkipDeepEquilibriumNetwork

function MultiScaleSkipDeepEquilibriumNetwork(main_layers::Tuple, mapping_layers::Matrix, shortcut_layers::Tuple,
                                              solver; post_fuse_layers::Union{Tuple,Nothing}=nothing, p=nothing,
                                              sensealg=SteadyStateAdjoint(0.1f0, 0.1f0, 10), kwargs...)
    mapping_layers = if post_fuse_layers === nothing
        @assert size(mapping_layers, 1) == size(mapping_layers, 2) == length(main_layers) == length(shortcut_layers)
        Chain(MultiParallelNet(Parallel.(+, map(x -> tuple(x...), eachcol(mapping_layers)))...), NoOpLayer())
    else
        @assert size(mapping_layers, 1) ==
                size(mapping_layers, 2) ==
                length(main_layers) ==
                length(post_fuse_layers) ==
                length(shortcut_layers)
        Chain(MultiParallelNet(Parallel.(+, map(x -> tuple(x...), eachcol(mapping_layers)))...),
              Parallel(flatten_merge, post_fuse_layers...))
    end

    main_layers = Parallel(flatten_merge, main_layers...)
    shortcut_layers = Parallel(flatten_merge, shortcut_layers...)

    return MultiScaleSkipDeepEquilibriumNetwork(main_layers, mapping_layers, shortcut_layers,
                                                nothing, nothing, nothing, p, nothing, solver, kwargs, sensealg,
                                                DEQTrainingStats(0))
end

function MultiScaleSkipDeepEquilibriumNetwork(main_layers::Tuple, mapping_layers::Matrix, solver;
                                              post_fuse_layers::Union{Tuple,Nothing}=nothing, p=nothing,
                                              sensealg=SteadyStateAdjoint(0.1f0, 0.1f0, 10), kwargs...)
    mapping_layers = if post_fuse_layers === nothing
        @assert size(mapping_layers, 1) == size(mapping_layers, 2) == length(main_layers)
        Chain(MultiParallelNet(Parallel.(+, map(x -> tuple(x...), eachcol(mapping_layers)))...), NoOpLayer())
    else
        @assert size(mapping_layers, 1) == size(mapping_layers, 2) == length(main_layers) == length(post_fuse_layers)
        Chain(MultiParallelNet(Parallel.(+, map(x -> tuple(x...), eachcol(mapping_layers)))...),
              Parallel(flatten_merge, post_fuse_layers...))
    end

    main_layers = Parallel(flatten_merge, main_layers...)

    return MultiScaleSkipDeepEquilibriumNetwork(main_layers, mapping_layers, nothing, nothing,
                                                nothing, nothing, p, nothing, solver, kwargs, sensealg,
                                                DEQTrainingStats(0))
end

function (mdeq::MultiScaleSkipDeepEquilibriumNetwork)(x::AbstractArray{T}) where {T}
    current_nfe = mdeq.stats.nfe

    p1, p2, p3 = split_array_by_indices(mdeq.p, mdeq.ordered_split_idxs)
    initial_conditions = mdeq.shortcut_layers_re(p3)(x)
    u_sizes = size.(initial_conditions)
    u_split_idxs = vcat(0, cumsum(length.(initial_conditions) .÷ size(x, ndims(x)))...)
    u0 = Zygote.@ignore vcat(Flux.flatten.(initial_conditions)...)

    N = length(u_sizes)
    update_is_variational_hidden_dropout_mask_reset_allowed(false)

    function dudt_(u, _p)
        mdeq.stats.nfe += 1

        uₛ = split_array_by_indices(u, u_split_idxs)
        p1, p2, _ = split_array_by_indices(_p, mdeq.ordered_split_idxs)

        u_reshaped = ntuple(i -> reshape(uₛ[i], u_sizes[i]), N)

        main_layers_output = mdeq.main_layers_re(p1)((u_reshaped[1], x), u_reshaped[2:end]...)

        return mdeq.mapping_layers_re(p2)(main_layers_output)
    end

    dudt(u, _p, t) = vcat(Flux.flatten.(dudt_(u, _p))...) .- u

    ssprob = SteadyStateProblem(dudt, u0, mdeq.p)
    res = solve(ssprob, mdeq.solver; u0=u0, sensealg=mdeq.sensealg, mdeq.kwargs...).u
    x_ = dudt_(res, mdeq.p)
    residual = Zygote.@ignore Tuple(map((iu) -> reshape(iu[2], u_sizes[iu[1]]),
                                    enumerate(split_array_by_indices(dudt(res, mdeq.p, nothing), u_split_idxs))))

    update_is_variational_hidden_dropout_mask_reset_allowed(true)

    return x_, DeepEquilibriumSolution(x_, initial_conditions, residual, T(0), mdeq.stats.nfe - current_nfe)
end

function (mdeq::MultiScaleSkipDeepEquilibriumNetwork{Nothing})(x::AbstractArray{T}) where {T}
    current_nfe = mdeq.stats.nfe

    p1, p2 = split_array_by_indices(mdeq.p, mdeq.ordered_split_idxs)

    _initial_conditions = Zygote.@ignore [l(x) for l in map(l -> l.layers[1], mdeq.mapping_layers[1].layers)]
    _initial_conditions = mdeq.mapping_layers_re(p2)((x, zero.(_initial_conditions[2:end])...))
    initial_conditions = mdeq.main_layers_re(p1)((zero(_initial_conditions[1]), _initial_conditions[1]),
                                                 _initial_conditions[2:end]...)
    u_sizes = size.(initial_conditions)
    u_split_idxs = vcat(0, cumsum(length.(initial_conditions) .÷ size(x, ndims(x)))...)
    u0 = vcat(Flux.flatten.(initial_conditions)...)

    N = length(u_sizes)
    update_is_variational_hidden_dropout_mask_reset_allowed(false)

    function dudt_(u, _p)
        mdeq.stats.nfe += 1

        uₛ = split_array_by_indices(u, u_split_idxs)
        p1, p2, _ = split_array_by_indices(_p, mdeq.ordered_split_idxs)

        u_reshaped = ntuple(i -> reshape(uₛ[i], u_sizes[i]), N)

        main_layers_output = mdeq.main_layers_re(p1)((u_reshaped[1], x), u_reshaped[2:end]...)

        return mdeq.mapping_layers_re(p2)(main_layers_output)
    end

    dudt(u, _p, t) = vcat(Flux.flatten.(dudt_(u, _p))...) .- u

    ssprob = SteadyStateProblem(dudt, u0, mdeq.p)
    res = solve(ssprob, mdeq.solver; u0=u0, sensealg=mdeq.sensealg, mdeq.kwargs...).u
    x_ = dudt_(res, mdeq.p)
    residual = Zygote.@ignore Tuple(map((iu) -> reshape(iu[2], u_sizes[iu[1]]),
                                    enumerate(split_array_by_indices(dudt(res, mdeq.p, nothing), u_split_idxs))))

    update_is_variational_hidden_dropout_mask_reset_allowed(true)

    return x_, DeepEquilibriumSolution(x_, initial_conditions, residual, T(0), mdeq.stats.nfe - current_nfe)
end
