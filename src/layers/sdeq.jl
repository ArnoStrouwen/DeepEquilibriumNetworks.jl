struct SkipDeepEquilibriumNetwork{M,S,P,RE1,RE2,A,Se,K} <:
       AbstractDeepEquilibriumNetwork
    model::M
    shortcut::S
    p::P
    re1::RE1
    re2::RE2
    split_idx::Int
    args::A
    kwargs::K
    sensealg::Se
    stats::DEQTrainingStats
end

Flux.@functor SkipDeepEquilibriumNetwork

function Flux.gpu(deq::SkipDeepEquilibriumNetwork)
    return SkipDeepEquilibriumNetwork(
        deq.model |> gpu,
        deq.shortcut |> gpu,
        deq.args...;
        p = deq.p |> gpu,
        sensealg = deq.sensealg,
        deq.kwargs...
    )
end

function SkipDeepEquilibriumNetwork(
    model,
    shortcut,
    args...;
    p = nothing,
    sensealg = SteadyStateAdjoint(
        autodiff = false,
        autojacvec = ZygoteVJP(),
        linsolve = LinSolveKrylovJL(rtol = 0.1f0, atol = 0.1f0),
    ),
    kwargs...,
)
    p1, re1 = Flux.destructure(model)
    p2, re2 = Flux.destructure(shortcut)
    p = p === nothing ? vcat(p1, p2) : p
    return SkipDeepEquilibriumNetwork(
        model,
        shortcut,
        p,
        re1,
        re2,
        length(p1),
        args,
        kwargs,
        sensealg,
        DEQTrainingStats(0),
    )
end

function (deq::SkipDeepEquilibriumNetwork)(
    x::AbstractArray{T},
    p = deq.p,
) where {T}
    p1, p2 = p[1:deq.split_idx], p[deq.split_idx+1:end]
    z = deq.re2(p2)(x)::typeof(x)

    # Dummy call to ensure that mask is generated
    _ = deq.re1(p1)(x)
    update_is_in_deq(true)

    deq.stats.nfe += 2

    # Solving the equation f(u) - u = du = 0
    function dudt(u, _p, t)
        deq.stats.nfe += 1
        return deq.re1(_p)(u, x) .- u
    end

    ssprob = SteadyStateProblem(dudt, z, p1)
    u = solve(
        ssprob,
        deq.args...;
        u0 = z,
        sensealg = deq.sensealg,
        deq.kwargs...,
    ).u::typeof(x)
    res = deq.re1(p1)(u, x)::typeof(x)
    deq.stats.nfe += 1

    update_is_in_deq(false)

    return res, z
end

# function (deq::SkipDeepEquilibriumNetwork)(lapl::AbstractMatrix{T}, x::AbstractArray{T}, p = deq.p) where {T}
#     # Atomic Graph Nets
#     p1, p2 = p[1:deq.split_idx], p[deq.split_idx+1:end]
#     _, u0 = deq.re2(p2)(lapl, x)
#     deq.stats.nfe += 1

#     function dudt(u, _p, t)
#         deq.stats.nfe += 1
#         return deq.re1(_p)(lapl, u, x)[2] .- u
#     end

#     ssprob = SteadyStateProblem(dudt, u0, p1)
#     sol = solve(
#         ssprob,
#         deq.args...;
#         u0 = u0,
#         sensealg = deq.sensealg,
#         deq.kwargs...,
#     )
#     deq.stats.nfe += 1

#     return deq.re1(p1)(lapl, sol.u, x), u0
# end