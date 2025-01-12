module DeepEquilibriumNetworks

include("operator.jl")

include("solvers/solvers.jl")
include("solvers/discrete/broyden.jl")
include("solvers/discrete/limited_memory_broyden.jl")
include("solvers/termination.jl")

include("solve.jl")
include("utils.jl")

include("layers/core.jl")
include("layers/jacobian_stabilization.jl")
include("layers/deq.jl")
include("layers/mdeq.jl")
include("layers/neuralode.jl")

include("adjoint.jl")

Base.similar(ca::Lux.ComponentArray, l::Int64) = similar(Lux.getdata(ca), l)

# DEQ Solvers
export ContinuousDEQSolver, DiscreteDEQSolver, BroydenSolver, LimitedMemoryBroydenSolver

# Utils
export DeepEquilibriumAdjoint, DeepEquilibriumSolution, estimate_jacobian_trace

# Networks
export DeepEquilibriumNetwork, SkipDeepEquilibriumNetwork
export MultiScaleDeepEquilibriumNetwork, MultiScaleSkipDeepEquilibriumNetwork

end
