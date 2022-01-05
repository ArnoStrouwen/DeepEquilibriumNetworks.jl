function expand_mid(arr::AbstractMatrix, M::Int)
    s1, s2 = size(arr)
    return repeat(reshape(arr, s1, 1, s2), 1, M, 1)
end

function expand_mid(arr::CuMatrix, M::Int)
    s1, s2 = size(arr)
    return reshape(arr, s1, 1, s2) .+ CUDA.zeros(eltype(arr), s1, M, s2)
end

function expand_mid(arr::AbstractMatrix, ex::AbstractArray)
    s1, s2 = size(arr)
    return reshape(arr, s1, 1, s2) .+ ex
end

Zygote.@adjoint function expand_mid(arr::CuArray, M::Int)
    s1, s2 = size(arr)
    expand_mid_sensitivity(Δ) = (reshape(sum(Δ; dims=2), s1, s2), nothing)
    return reshape(arr, s1, 1, s2) .+ CUDA.zeros(eltype(arr), 1, M, 1), expand_mid_sensitivity
end

Zygote.@adjoint function expand_mid(arr::AbstractMatrix, ex::AbstractArray)
    s1, s2 = size(arr)
    expand_mid_sensitivity(Δ) = (reshape(sum(Δ; dims=2), s1, s2), nothing)
    return reshape(arr, s1, 1, s2) .+ ex, expand_mid_sensitivity
end

struct ExpandMid{X<:AbstractArray}
    x::X
end

Flux.trainable(::ExpandMid) = ()

@functor ExpandMid

ExpandMid(M::Int) = ExpandMid(zeros(Float32, 1, M, 1))

(e::ExpandMid)(x::AbstractMatrix) = expand_mid(x, e.x)

struct MaterialsProjectResidualGraphConv{C1,C2}
    c1::C1
    c2::C2

    function MaterialsProjectResidualGraphConv(atom_feature_length::Int, neighbor_feature_length::Int,
                                               expand_mid_dims::Int)
        c1 = MaterialsProjectGraphConv(atom_feature_length, neighbor_feature_length, expand_mid_dims)
        c2 = MaterialsProjectGraphConv(atom_feature_length, neighbor_feature_length, expand_mid_dims)
        return new{typeof(c1),typeof(c2)}(c1, c2)
    end

    MaterialsProjectResidualGraphConv(c1::C1, c2::C2) where {C1,C2} = new{C1,C2}(c1, c2)
end

@functor MaterialsProjectResidualGraphConv

function (r::MaterialsProjectResidualGraphConv)(atom_in_features_1::AbstractMatrix{T},
                                                atom_in_features_2::AbstractMatrix{T},
                                                neighbor_features::AbstractArray{T,3},
                                                neighbor_feature_indices::AbstractMatrix{S}) where {T,S<:Int}
    return r.c1(atom_in_features_1, neighbor_features, neighbor_feature_indices) .+
           r.c2(atom_in_features_2, neighbor_features, neighbor_feature_indices)
end

struct MaterialsProjectGraphConv{L1,B1,B2,E}
    atom_feature_length::Int
    neighbor_feature_length::Int
    fc_full::L1
    bn1::B1
    bn2::B2
    exmid::E
end

@functor MaterialsProjectGraphConv

function MaterialsProjectGraphConv(atom_feature_length::Int, neighbor_feature_length::Int, expand_mid_dims::Int)
    fc_full = Dense(2 * atom_feature_length + neighbor_feature_length, 2 * atom_feature_length)
    bn1 = GroupNormV2(2 * atom_feature_length, 8; track_stats=false)
    bn2 = GroupNormV2(atom_feature_length, 8; track_stats=false)
    exmid = ExpandMid(expand_mid_dims)
    return MaterialsProjectGraphConv(atom_feature_length, neighbor_feature_length, fc_full, bn1, bn2, exmid)
end

function (c::MaterialsProjectGraphConv)(atom_in_features::AbstractMatrix{T}, neighbor_features::AbstractArray{T,3},
                                        neighbor_feature_indices::AbstractMatrix{S}) where {T,S<:Int}
    M, N = size(neighbor_feature_indices)
    atom_neighbor_features = atom_in_features[:, neighbor_feature_indices]
    ex_atom_in_features = c.exmid(atom_in_features)

    total_neighbor_features = vcat(ex_atom_in_features, atom_neighbor_features, neighbor_features)
    total_gated_features = c.fc_full(total_neighbor_features)
    total_gated_features = reshape(c.bn1(reshape(total_gated_features, 2 * c.atom_feature_length, :)),
                                   2 * c.atom_feature_length, M, N)

    neighbor_filter = σ.(total_gated_features[1:(c.atom_feature_length), :, :])
    neighbor_core = softplus.(total_gated_features[(c.atom_feature_length + 1):end, :, :])

    neighbor_sumed = c.bn2(reshape(sum(neighbor_filter .* neighbor_core; dims=2), c.atom_feature_length, N))

    return softplus.(atom_in_features .+ neighbor_sumed), neighbor_features, neighbor_feature_indices
end

struct MaterialsProjectCrystalGraphConvNet{E,C,CF,F}
    embedding::E
    convs::C
    conv_to_fc::CF
    fcs::F
end

@functor MaterialsProjectCrystalGraphConvNet

function MaterialsProjectCrystalGraphConvNet(; deq=false, sdeq=false, original_atom_feature_length::Int,
                                             neighbor_feature_length::Int, atom_feature_length::Int=64, num_conv::Int=3,
                                             h_feature_length::Int=128, n_hidden::Int=1, expand_mid_dims::Int=12,
                                             maxiters=10, abstol=1.0f-2, reltol=1.0f-2, ode_solver=Tsit5())
    embedding = Dense(original_atom_feature_length, atom_feature_length)
    if deq
        convs = DeepEquilibriumNetwork(MaterialsProjectResidualGraphConv(atom_feature_length, neighbor_feature_length,
                                                                         expand_mid_dims),
                                       get_default_dynamicss_solver(reltol, abstol, ode_solver);
                                       sensealg=get_default_ssadjoint(reltol, abstol, maxiters), maxiters=maxiters,
                                       verbose=false)
    elseif sdeq
        convs = SkipDeepEquilibriumNetwork(MaterialsProjectResidualGraphConv(atom_feature_length,
                                                                             neighbor_feature_length, expand_mid_dims),
                                           MaterialsProjectGraphConv(atom_feature_length, neighbor_feature_length,
                                                                     expand_mid_dims),
                                           get_default_dynamicss_solver(reltol, abstol, ode_solver);
                                           sensealg=get_default_ssadjoint(reltol, abstol, maxiters), maxiters=maxiters,
                                           verbose=false)
    else
        convs = FChain([MaterialsProjectGraphConv(atom_feature_length, neighbor_feature_length, expand_mid_dims)
                        for _ in 1:num_conv]...)
    end
    conv_to_fc = Dense(atom_feature_length, h_feature_length, softplus)

    fcs = FChain(vcat([Dense(h_feature_length, h_feature_length, softplus) for _ in 1:(n_hidden - 1)],
                      [Dense(h_feature_length, 1)])...)

    return MaterialsProjectCrystalGraphConvNet(embedding, convs, conv_to_fc, fcs)
end

function (c::MaterialsProjectCrystalGraphConvNet)(atom_features::AbstractMatrix{T},
                                                  neighbor_features::AbstractArray{T,3},
                                                  neighbor_feature_indices::AbstractMatrix{S},
                                                  crystal_atom_indices::AbstractVector) where {T,S<:Int}
    atom_features = c.embedding(atom_features)
    atom_features, neighbor_features, neighbor_feature_indices = c.convs(atom_features, neighbor_features,
                                                                         neighbor_feature_indices)
    crystal_features = pool(c, atom_features, crystal_atom_indices)
    crystal_features = c.conv_to_fc(softplus.(crystal_features))
    return (c.fcs(crystal_features),)
end

function (c::MaterialsProjectCrystalGraphConvNet{E,C})(atom_features::AbstractMatrix{T},
                                                       neighbor_features::AbstractArray{T,3},
                                                       neighbor_feature_indices::AbstractMatrix{S},
                                                       crystal_atom_indices::AbstractVector) where {T,S<:Int,E,
                                                                                                    C<:Union{DeepEquilibriumNetwork,
                                                                                                             SkipDeepEquilibriumNetwork}}
    atom_features = c.embedding(atom_features)
    (atom_features, neighbor_features, neighbor_feature_indices), soln = c.convs(atom_features, neighbor_features,
                                                                                 neighbor_feature_indices)
    crystal_features = pool(c, atom_features, crystal_atom_indices)
    crystal_features = c.conv_to_fc(softplus.(crystal_features))
    return c.fcs(crystal_features), soln
end

function pool(c::MaterialsProjectCrystalGraphConvNet, atom_features::AbstractMatrix{T},
              crystal_atom_indices::AbstractVector) where {T}
    return hcat([mean(atom_features[:, idx_map]; dims=2) for idx_map in crystal_atom_indices]...)
end

get_and_clear_nfe!(::MaterialsProjectCrystalGraphConvNet) = -1

function get_and_clear_nfe!(model::MaterialsProjectCrystalGraphConvNet{E,C}) where {E,
                                                                                    C<:Union{DeepEquilibriumNetwork,
                                                                                             SkipDeepEquilibriumNetwork}}
    return get_and_clear_nfe!(model.convs)
end