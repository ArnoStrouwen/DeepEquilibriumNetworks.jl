# For testing purposes atm
struct DEQSolver{M,A,AT,RT,TS} <: SteadyStateDiffEq.SteadyStateDiffEqAlgorithm
    alg::A
    abstol::AT
    reltol::RT
    tspan::TS
end

function DEQSolver(alg; mode::Symbol=:abs_norm, abstol=1e-8, reltol=1e-8, tspan=Inf)
    return DEQSolver{Val(mode),typeof(alg),typeof(abstol),typeof(reltol),typeof(tspan)}(alg, abstol, reltol, tspan)
end

function terminate_condition_reltol(integrator, abstol, reltol)
    return all(abs.(DiffEqBase.get_du(integrator)) .<= reltol .* abs.(integrator.u))
end

function terminate_condition_reltol_norm(integrator, abstol, reltol)
    du = DiffEqBase.get_du(integrator)
    return norm(du) <= reltol * norm(du .+ integrator.u)
end

function terminate_condition_abstol(integrator, abstol, reltol)
    return all(abs.(DiffEqBase.get_du(integrator)) .<= abstol)
end

function terminate_condition_abstol_norm(integrator, abstol, reltol)
    return norm(DiffEqBase.get_du(integrator)) <= abstol
end

function terminate_condition(integrator, abstol, reltol)
    return all((abs.(DiffEqBase.get_du(integrator)) .<= reltol .* abs.(integrator.u)) .&
               (abs.(DiffEqBase.get_du(integrator)) .<= abstol))
end

function terminate_condition_norm(integrator, abstol, reltol)
    du = DiffEqBase.get_du(integrator)
    du_norm = norm(du)
    return (du_norm <= reltol * norm(du .+ integrator.u)) && (du_norm <= abstol)
end

get_terminate_condition(::DEQSolver{Val(:abs)}, args...; kwargs...) = terminate_condition_abstol
get_terminate_condition(::DEQSolver{Val(:abs_norm)}, args...; kwargs...) = terminate_condition_abstol_norm
get_terminate_condition(::DEQSolver{Val(:rel)}, args...; kwargs...) = terminate_condition_reltol
get_terminate_condition(::DEQSolver{Val(:rel_norm)}, args...; kwargs...) = terminate_condition_reltol_norm
get_terminate_condition(::DEQSolver{Val(:norm)}, args...; kwargs...) = terminate_condition_norm
get_terminate_condition(::DEQSolver, args...; kwargs...) = terminate_condition

# Termination conditions used in the original DEQ Paper
function get_terminate_condition(::DEQSolver{Val(:abs_deq_default),A,T}, args...; kwargs...) where {A,T}
    nstep = 0
    protective_threshold = T(1e6)
    objective_values = T[]
    function terminate_condition_closure(integrator, abstol, reltol)
        du = DiffEqBase.get_du(integrator)
        objective = norm(du)
        # Main termination condition
        objective <= abstol && return true

        # Terminate if there has been no improvement for the last 30 steps
        nstep += 1
        push!(objective_values, objective)

        objective <= 3 * abstol &&
            nstep >= 30 &&
            maximum(objective_values[(end - nstep):end]) < 1.3 * minimum(objective_values[(end - nstep):end]) &&
            return true

        # Protective break
        objective >= objective_values[1] * protective_threshold * length(du) && return true

        return false
    end
    return terminate_condition_closure
end

function get_terminate_condition(::DEQSolver{Val(:rel_deq_default),A,T}, args...; kwargs...) where {A,T}
    nstep = 0
    protective_threshold = T(1e3)
    objective_values = T[]
    function terminate_condition_closure(integrator, abstol, reltol)
        du = DiffEqBase.get_du(integrator)
        u = integrator.u
        objective = norm(du) / (norm(du .+ u) + eps(T))
        # Main termination condition
        objective <= reltol && return true

        # Terminate if there has been no improvement for the last 30 steps
        nstep += 1
        push!(objective_values, objective)

        objective <= 3 * reltol &&
            nstep >= 30 &&
            maximum(objective_values[(end - nstep + 1):end]) < 1.3 * minimum(objective_values[(end - nstep + 1):end]) &&
            return true

        # Protective break
        objective >= objective_values[1] * protective_threshold * length(du) && return true

        return false
    end
    return terminate_condition_closure
end

function get_terminate_condition(::DEQSolver{Val(:rel_deq_best),A,T}, terminate_stats::Dict, args...; kwargs...) where {A,T}
    nstep = 0
    protective_threshold = T(1e3)
    objective_values = T[]

    terminate_stats[:best_objective_value] = T(Inf)
    terminate_stats[:best_objective_value_iteration] = 0

    function terminate_condition_closure(integrator, abstol, reltol)
        du = DiffEqBase.get_du(integrator)
        u = integrator.u
        objective = norm(du) / (norm(du .+ u) + eps(T))

        if objective < terminate_stats[:best_objective_value]
            terminate_stats[:best_objective_value] = objective
            terminate_stats[:best_objective_value_iteration] = nstep + 1
        end

        # Main termination condition
        objective <= reltol && return true

        # Terminate if there has been no improvement for the last 30 steps
        nstep += 1
        push!(objective_values, objective)

        objective <= 3 * reltol &&
            nstep >= 30 &&
            maximum(objective_values[(end - nstep + 1):end]) < 1.3 * minimum(objective_values[(end - nstep + 1):end]) &&
            return true

        # Protective break
        objective >= objective_values[1] * protective_threshold * length(du) && return true

        return false
    end

    return terminate_condition_closure
end

function get_terminate_condition(::DEQSolver{Val(:abs_deq_best),A,T}, terminate_stats::Dict, args...; kwargs...) where {A,T}
    nstep = 0
    protective_threshold = T(1e3)
    objective_values = T[]

    terminate_stats[:best_objective_value] = T(Inf)
    terminate_stats[:best_objective_value_iteration] = 0

    function terminate_condition_closure(integrator, abstol, reltol)
        du = DiffEqBase.get_du(integrator)
        objective = norm(du)

        if objective < terminate_stats[:best_objective_value]
            terminate_stats[:best_objective_value] = objective
            terminate_stats[:best_objective_value_iteration] = nstep + 1
        end

        # Main termination condition
        objective <= reltol && return true

        # Terminate if there has been no improvement for the last 30 steps
        nstep += 1
        push!(objective_values, objective)

        objective <= 3 * reltol &&
            nstep >= 30 &&
            maximum(objective_values[(end - nstep + 1):end]) < 1.3 * minimum(objective_values[(end - nstep + 1):end]) &&
            return true

        # Protective break
        objective >= objective_values[1] * protective_threshold * length(du) && return true

        return false
    end

    return terminate_condition_closure
end

has_converged(du, u, alg::DEQSolver) = all(abs.(du) .<= alg.abstol .& abs.(du) .<= alg.reltol .* abs.(u))
has_converged(du, u, alg::DEQSolver{Val(:norm)}) = norm(du) <= alg.abstol && norm(du) <= alg.reltol * norm(du .+ u)
has_converged(du, u, alg::DEQSolver{Val(:rel)}) = all(abs.(du) .<= alg.reltol .* abs.(u))
has_converged(du, u, alg::DEQSolver{Val(:rel_norm)}) = norm(du) <= alg.reltol * norm(du .+ u)
has_converged(du, u, alg::DEQSolver{Val(:rel_deq_default)}) = norm(du) <= alg.reltol * norm(du .+ u)
has_converged(du, u, alg::DEQSolver{Val(:rel_deq_best)}) = norm(du) <= alg.reltol * norm(du .+ u)
has_converged(du, u, alg::DEQSolver{Val(:abs)}) = all(abs.(du) .<= alg.abstol)
has_converged(du, u, alg::DEQSolver{Val(:abs_norm)}) = norm(du) <= alg.abstol
has_converged(du, u, alg::DEQSolver{Val(:abs_deq_default)}) = norm(du) <= alg.abstol
has_converged(du, u, alg::DEQSolver{Val(:abs_deq_best)}) = norm(du) <= alg.abstol

function DiffEqBase.__solve(prob::DiffEqBase.AbstractSteadyStateProblem, alg::DEQSolver, args...; kwargs...)
    tspan = alg.tspan isa Tuple ? alg.tspan : convert.(real(eltype(prob.u0)), (zero(alg.tspan), alg.tspan))
    _prob = ODEProblem(prob.f, prob.u0, tspan, prob.p)

    terminate_stats = Dict{Symbol,Any}(:best_objective_value => real(eltype(prob.u0))(Inf),
                                       :best_objective_value_iteration => nothing)

    sol = solve(_prob, alg.alg, args...; kwargs...,
                callback=TerminateSteadyState(alg.abstol, alg.reltol, get_terminate_condition(alg, terminate_stats)))

    u, t = terminate_stats[:best_objective_value_iteration] === nothing ? (sol.u[end], sol.t[end]) :
           (sol.u[terminate_stats[:best_objective_value_iteration] + 1],
            sol.t[terminate_stats[:best_objective_value_iteration] + 1])
    du = prob.f(u, prob.p, t)

    return DiffEqBase.build_solution(prob, alg, u, du;
                                     retcode=(sol.retcode == :Terminated && has_converged(du, u, alg) ?
                                              :Success : :Failure))
end