"""
    MultilayerGraph{T, U, G <: AbstractGraph{T}} <: AbstractMultilayerGraph{T,U}

A concrete type that can represent a general multilayer graph.

# FIELDS

- `adjacency_tensor::Array{U, 4}`: the 4-dimensional tensor that encodes all (weighted) connections within the graph. adjacency_tensor[1,2,3,4] encodes the strength of the (directed or undirected) link between node 1 in layer 3 and node 2 in layer 4.
- `layers::OrderedDict{ Tuple{Int64,Int64}, Layer{T,U,G}}`: the ordered dictionary containing all the layers of the multilayer graph. Their underlying graphs must be all undirected.
- `interlayers::OrderedDict{ Tuple{Int64,Int64}, Interlayer{T,U}}`: the ordered dictionary containing all the interlayers of the multilayer graph. Their underlying graphs must be all undirected.
"""
mutable struct MultilayerGraph{T, U} <: AbstractMultilayerGraph{T,U}
    adjacency_tensor::Array{U, 4}
    layers::OrderedDict{ Tuple{Int64,Int64}, Layer{T}}
    interlayers::OrderedDict{ Tuple{Int64,Int64}, Interlayer{T}}
end

"""
    MultilayerGraph(num_layers::Int64, n_nodes::Int64, min_edges::Int64, max_edges::Int64, graph_type::Type{<: AbstractGraph})

Return a random `MultilayerGraph` with `num_layers` layers, `n_nodes` nodes and each `Layer` and `Interlayer` has a random number of edges between `min_edges` and `max_edges`. `Layers` and `Interlayers` have parametric type `graph_type`.
"""
function MultilayerGraph(num_layers::Int64, n_nodes::Int64, min_edges::Int64, max_edges::Int64, graph_types::Vector{DataType} )

    #TODO: this method requires that all Graphs.jl extensions are such that:
    # The first type parameter of graphs types is the type of the nodes, like the T in SimpleGraph{T};
    # all graph types have a random constructor with signature (nv::Int64, ne::Int64)
    # all graph types have an empty constructor with signature ()
    all([!istrait(IsDirected{graph_type}) for graph_type in graph_types ])  || throw(ErrorException("Not all graph types in argument `graph_types` are undirected."))
    T = get_common_type([graph_type.parameters[1] for graph_type in graph_types])
    U = get_common_type(eltype.([adjacency_matrix(graph_type()) for graph_type in graph_types]))

    layers = Layer{T,U}[]
    for i in 1:num_layers
        graph_type = rand(graph_types)
        push!(layers, Layer(Symbol("layer_$i"), graph_type(n_nodes, rand(min_edges:max_edges)); U = U  ))
    end

    interlayers_idxs = [(i,j) for i in 1:(num_layers-1) for j in (i+i):num_layers]
    interlayers      = [Interlayer(n_nodes, Symbol("interlayer_$(i)_$(j)"), Symbol("layer_$(i)"), Symbol("layer_$(j)"),  rand(graph_types), rand(min_edges:max_edges); U = U ) for (i,j) in interlayers_idxs]
    return MultilayerGraph(layers, interlayers)
end

@traitimpl IsWeighted{MultilayerGraph}

"""
    MultilayerGraph(n_nodes::Int64, T::Type{ <: Number}, U::Type{ <: Number} )

Return a MultilayerGraph with `n_nodes` of type `T` nodes and an adjacency tensor eltype `U`. Use this constructor and then add Layers and Interlayers via the `add_layer!` and `add_interlayer!` methods.
"""
function MultilayerGraph(n_nodes::Int64, T::Type{ <: Number}, U::Type{ <: Number} )
    adjacency_tensor = zeros(U, n_nodes,n_nodes,0,0)
    return MultilayerGraph(adjacency_tensor,OrderedDict{Tuple{Int64,Int64}, Layer{T}}(),OrderedDict{Tuple{Int64,Int64}, Interlayer{T}}())
end

"""
    MultilayerGraph(layers::Vector{ <: Layer{T,U}};  default_interlayer::String  = "multiplex") where {T,U} 

Construct a MultilayerDiGraph with layers `layers` and all interlayers of type `default_interlayer` (only "multiplex" is allowed).
"""
function MultilayerGraph(layers::Vector{ <: Layer{T,U}};  default_interlayer::String  = "multiplex") where {T,U}    
    return MultilayerGraph(layers, Interlayer{T,U}[]; default_interlayer = default_interlayer)

end

"""
    MultilayerGraph(layers::Vector{ <: Layer{T,U }}, specified_interlayers::Vector{ <: Interlayer{T,U}};  default_interlayer::String  = "multiplex") where {T, U}      

Construct a MultilayerDiGraph with layers given by `layers`. The interlayers will be constructed by default according to `default_interlayer` (only `"multiplex"` is allowed), except for those specified in `specified_interlayers`.
"""
function MultilayerGraph(layers::Vector{ <: Layer{T,U }}, specified_interlayers::Vector{ <: Interlayer{T,U}};  default_interlayer::String  = "multiplex") where {T, U}       
    # Check that all layers and specified interlayers are directed
    specified_subgraphs = vcat(layers,specified_interlayers)
    all( [!istrait(IsDirected{typeof(subgraph.graph)}) for subgraph in specified_subgraphs])  || throw(ErrorException("Not all the underlying layers' and interlayers' graphs are undirected."))

    num_nodes = nv(layers[1])
    multilayergraph = MultilayerGraph(num_nodes, T,U)

    for layer in layers
        add_layer!(multilayergraph, layer; new_default_interlayers_type = default_interlayer)
    end

    if !isnothing(specified_interlayers)
        for interlayer in specified_interlayers
            specify_interlayer!(multilayergraph, interlayer)
        end
    end
    
    return multilayergraph 
end

"""
    add_layer!(mg::M,layer::L; interlayers_type = "multiplex") where { T, U, G<: AbstractGraph{T}, M <: MultilayerGraph{T, U}, L <: Layer{T,U,G}}

Add layer `layer` to `mg`. Also add `Interlayer`s of type `interlayers_type` (can only be `"multiplex"`) between the new layer and all the other ones. 
"""
function add_layer!(mg::M,new_layer::L; new_default_interlayers_type = "multiplex") where { T, U, G<: AbstractGraph{T}, M <: MultilayerGraph{T, U}, L <: Layer{T,U,G}}
    # Check that the layer is directed
    !istrait(IsDirected{typeof(new_layer.graph)})  || throw(ErrorException("The `new_layer`'s underlying graph $(new_layer.graph) is directed, so it is not compatible with a `MultilayerGraph`."))

    if new_default_interlayers_type == "multiplex"
        _add_layer!(mg, new_layer; new_default_interlayers_type = SimpleGraph{T})
    end
    
end

"""
    specify_interlayer!(mg::M, new_interlayer::In; symmetric_interlayer_name::String) where { T, U, G<: AbstractGraph{T}, M <: MultilayerGraph{T, U}, In <: Interlayer{T,U,G}}

Specify the interlayer `new_interlayer` as part of `mg`. The underlying graph of `new_interlayer` must be undirected.
"""
function specify_interlayer!(mg::M, new_interlayer::In; symmetric_interlayer_name::String = "interlayer_$(new_interlayer.layer_2)_$(new_interlayer.layer_1)") where { T, U, G<: AbstractGraph{T}, M <: MultilayerGraph{T, U}, In <: Interlayer{T,U,G}}

    # This error could be removed since we are already dispatching on trait
    !istrait(IsDirected{typeof(new_interlayer.graph)})  || throw(ErrorException("The `new_interlayer`'s underlying graphs $(new_interlayer.graph) is directed, so it is not compatible with a `MultilayerGraph`."))

    _specify_interlayer!(mg, new_interlayer; symmetric_interlayer_name = symmetric_interlayer_name )

end

"""
    specify_interlayer!(mg::M, layer_1::Symbol, layer_2::Symbol, graph::G; new_interlayer_name::Symbol, symmetric_interlayer_name::Symbol ,  forbidden_vertices::Tuple{Vararg{MultilayerVertex{T}}}, forbidden_edges::Tuple{Vararg{NTuple{2, MultilayerVertex{T}}}} ) where { T, U, G<: AbstractGraph{T}, M <: MultilayerGraph{T, U}}

Specify an interlayer which is represented by `graph` between `layer_1` and `layer_2`. The Interlayer's name can be specified via `new_interlayer_name`, as the name of its corresponding Interlayer between `layer_2` and `layer_1` which is the same as the new Interlayer except its adjacency matrix is transposed.
"""

function specify_interlayer!(mg::M, layer_1::Symbol, layer_2::Symbol, graph::G; new_interlayer_name::String = "interlayer_$(layer_1)_$(layer_2)", symmetric_interlayer_name::String = "interlayer_$(layer_2)_$(layer_1)", forbidden_vertices::Tuple{Vararg{MultilayerVertex{T}}}, forbidden_edges::Tuple{Vararg{NTuple{2, MultilayerVertex{T}}}} ) where { T, U, G<: AbstractGraph{T}, M <: MultilayerGraph{T, U}} # 

    !istrait(isDirected{G}) || throw(ErrorException("The new interlayer's underlying graphs $(graph) is directed, so it is not compatible with a `MultilayerGraph`."))
    interlayer = Interlayer(Symbol(new_interlayer_name), layer_1, layer_2, graph; forbidden_vertices = forbidden_vertices,  forbidden_edges = forbidden_edges)
    specify_interlayer!(mg, interlayer; symmetric_interlayer_name = symmetric_interlayer_name)
    
end

# Graphs.jl's internals extra overrides

Graphs.degree(mg::M, v::V) where {T, M <:MultilayerGraph{T, <: Real}, V <: MultilayerVertex{T}} = indegree(mg, v)

"""
    add_edge!(mg::M, src::V, dst::V, weight::U) where { T, U <: Real, M <: MultilayerGraph{T,U}, V <: MultilayerVertex{T}}

Add edge from `src` to `dst` with weight `weight` to `mg`.
"""
function Graphs.add_edge!(mg::M, src::V, dst::V, weight::U) where { T, U <: Real, M <: MultilayerGraph{T,U}, V <: MultilayerVertex{T}}
    if !(has_vertex(mg, src) && has_vertex(mg, dst))
        return false
    end

    src_layer_cartIdxs, _src_layer = get_layer(mg, src.layer)
    dst_layer_cartIdxs, _dst_layer = get_layer(mg, dst.layer)
    added  = addede_symmetric = false
    if _src_layer == _dst_layer
        layerContainingEdge_cartIdxs, layerContainingEdge = get_layer(mg, _src_layer.name)
        istrait(IsWeighted{typeof(layerContainingEdge.graph)}) || throw(ErrorException("You are trying to add a weighted edge to an unweighted layer. If you are convinced that the graph type of the layer to which the two vertices $(src) and $(dst) belong is weighted, then please submit an issue so that we may give the `IsWeighted` trait to the graph type."))
        added = added_symmetric = add_edge!(layerContainingEdge, src, dst, weight)
        if added
            mg.adjacency_tensor[src.node,dst.node,src_layer_cartIdxs[1], src_layer_cartIdxs[1]] = weight
            mg.adjacency_tensor[dst.node,src.node,src_layer_cartIdxs[1], src_layer_cartIdxs[1]] = weight
            return true
        else
            return false
        end

    else
        interlayerContainingEdge_cartIdxs, interlayerContainingEdge                   = get_interlayer(mg, _src_layer.name, _dst_layer.name)
        interlayerSymmetricContainingEdge_cartIdxs, interlayerSymmetricContainingEdge = get_interlayer(mg, _dst_layer.name, _src_layer.name)

        istrait(IsWeighted{typeof(interlayerContainingEdge.graph)}) && istrait(IsWeighted{typeof(interlayerSymmetricContainingEdge.graph)}) || throw(ErrorException("You are trying to add a weighted edge to an unweighted interlayer. If you are convinced that the graph type of the interlayer to which the two vertices $(src) and $(dst) belong is weighted, then please submit an issue so that we may give the `IsWeighted` trait to the graph type. Also make sure that you didn't specify the two symmetric interlayer involved with different graph types."))

        added           = add_edge!(interlayerContainingEdge, src, dst, weight)
        added_symmetric = add_edge!(interlayerSymmetricContainingEdge, src, dst, weight)

        added == added_symmetric || throw(ErrorException("add_edge!; While adding and edge to an interlayer and its symmetric, one of the two already has/hasn't the said edge while the other doesn't/does. This implies that the multilayer has been corrupted. If you didn't modify its fields without relying on the provided API, please file an issue."))

        
        if added && added_symmetric
            mg.adjacency_tensor[src.node,dst.node,src_layer_cartIdxs[1], dst_layer_cartIdxs[1]] = weight
            mg.adjacency_tensor[dst.node,src.node,dst_layer_cartIdxs[1], src_layer_cartIdxs[1]] = weight
            return true
        else
            return false
        end

    end
    return added
end

"""
    add_edge!(mg::M, src::V, dst::V, weight::U) where { T, U <: Real, M <: MultilayerGraph{T,U}, V <: MultilayerVertex{T}}

Add edge from `src` to `dst` with weight `one(U)` to `mg`.
"""
function Graphs.add_edge!(mg::M, src::V, dst::V) where { T, U <: Real, M <: MultilayerGraph{T,U}, V <: MultilayerVertex{T}}

    if !(has_vertex(mg, src) && has_vertex(mg, dst))
        return false
    end

    src_layer_cartIdxs, _src_layer = get_layer(mg, src.layer)
    dst_layer_cartIdxs, _dst_layer = get_layer(mg, dst.layer)
    added  = addede_symmetric = false
    if _src_layer == _dst_layer
        layerContainingEdge_cartIdxs, layerContainingEdge = get_layer(mg, _src_layer.name)
        added = added_symmetric = add_edge!(layerContainingEdge, src, dst)
        if added
            mg.adjacency_tensor[src.node,dst.node,src_layer_cartIdxs[1], src_layer_cartIdxs[1]] = one(U)
            mg.adjacency_tensor[dst.node,src.node,src_layer_cartIdxs[1], src_layer_cartIdxs[1]] = one(U)
            return true
        else
            return false
        end

    else
        interlayerContainingEdge_cartIdxs, interlayerContainingEdge                   = get_interlayer(mg, _src_layer.name, _dst_layer.name)
        interlayerSymmetricContainingEdge_cartIdxs, interlayerSymmetricContainingEdge = get_interlayer(mg, _dst_layer.name, _src_layer.name)

        added           = add_edge!(interlayerContainingEdge, src, dst)
        added_symmetric = add_edge!(interlayerSymmetricContainingEdge, src, dst)

        added == added_symmetric ||  throw(ErrorException("add_edge!; While adding and edge to an interlayer and its symmetric, one of the two already has/hasn't the said edge while the other doesn't/does. This implies that the multilayer has been corrupted. If you didn't modify its fields without relying on the provided API, please file an issue."))

        if added && added_symmetric
            mg.adjacency_tensor[src.node,dst.node,src_layer_cartIdxs[1], dst_layer_cartIdxs[1]] = one(U)
            mg.adjacency_tensor[dst.node,src.node,dst_layer_cartIdxs[1], src_layer_cartIdxs[1]] = one(U)
            return true
        else
            return false
        end
    end
    return added
end

"""
    add_edge!(mg::M, me::E) where { T, U <: Real, M <: MultilayerGraph{T,U}, E <: MultilayerEdge{MultilayerVertex{T},U}}

Add weighted edge `me` to `mg`.
"""
Graphs.add_edge!(mg::M, me::E) where { T, U <: Real, M <: MultilayerGraph{T,U}, E <: MultilayerEdge{MultilayerVertex{T},U}} = add_edge!(mg, src(me), dst(me), weight(me))

"""
    add_edge!(mg::M, me::E) where { T, U, M <: MultilayerGraph{T,U}, E <: MultilayerEdge{MultilayerVertex{T},Nothing}}

Add unweighted edge `me` to `mg`.
"""
Graphs.add_edge!(mg::M, me::E) where { T, U, M <: MultilayerGraph{T,U}, E <: MultilayerEdge{MultilayerVertex{T},Nothing}} = add_edge!(mg, src(me), dst(me))


"""
    rem_edge!(mg::M, V1::V, V2::V) where { T, U, M <: MultilayerGraph{T,U}, V <: MultilayerVertex{T}}


Remove edge from `src` to `dst` in `mg`.
"""
function Graphs.rem_edge!(mg::M, src::V, dst::V) where { T, U, M <: MultilayerGraph{T,U}, V <: MultilayerVertex{T}}

    if !(has_vertex(mg, src) && has_vertex(mg, dst))
        return false
    end

    if !has_edge(mg,src,dst)
        println("The multilayer doesn't have any edge between $src and $dst")
        return false
    end 

    src_layer_cartIdxs, _src_layer = get_layer(mg, src.layer)
    dst_layer_cartIdxs, _dst_layer = get_layer(mg, dst.layer)
    if _src_layer == _dst_layer
        layerContainingEdge_cartIdxs, layerContainingEdge = get_layer(mg, _src_layer.name)
        removed = rem_edge!(layerContainingEdge, src, dst)
        if removed
            mg.adjacency_tensor[src.node,dst.node,src_layer_cartIdxs[1], src_layer_cartIdxs[1]] = zero(U)
            mg.adjacency_tensor[dst.node,src.node,src_layer_cartIdxs[1], src_layer_cartIdxs[1]] = zero(U)
            return true
        else
            return false
        end
    else
        interlayerContainingEdge_cartIdxs, interlayerContainingEdge                   = get_interlayer(mg, _src_layer.name, _dst_layer.name)
        interlayerSymmetricContainingEdge_cartIdxs, interlayerSymmetricContainingEdge = get_interlayer(mg, _dst_layer.name, _src_layer.name)

        removed = rem_edge!(interlayerContainingEdge, src, dst)
        removed_symmetric = rem_edge!(interlayerSymmetricContainingEdge, src, dst)

        if removed && removed_symmetric
            mg.adjacency_tensor[src.node,dst.node,src_layer_cartIdxs[1], dst_layer_cartIdxs[1]] = zero(U)
            mg.adjacency_tensor[dst.node,src.node,dst_layer_cartIdxs[1], src_layer_cartIdxs[1]] = zero(U)
            return true
        elseif removed == !removed_symmetric
            throw(ErrorException("rem_edge!; While removing and edge to an interlayer and its symmetric, one of the two already has/hasn't the said edge while the other doesn't/does. This implies that the multilayer has been corrupted. If you didn't modify its fields without relying on the provided API, please file an issue."))
        elseif !removed && !removed_symmetric
            return false
        end
    end
end

"""
    is_directed(m::M) where { M <: MultilayerGraph}

Returns `true` if `m` is directed, `false` otherwise. 
"""
Graphs.is_directed(m::M) where { M <: MultilayerGraph} = false

"""
    is_directed(m::M) where { M <: Type{ <: MultilayerGraph}}

Returns `true` if `m` is directed, `false` otherwise. 
"""
Graphs.is_directed(m::M) where { M <: Type{ <: MultilayerGraph}} = false 


# TODO:
# it may be not well inferred
# function get_projected_monoplex_graph end #approach taken from https://github.com/JuliaGraphs/Graphs.jl/blob/7152d540631219fd51c43ab761ec96f12c27680e/src/core.jl#L124
"""
    get_projected_monoplex_graph(mg::M) where {M<: MultilayerGraph}

Get projected monoplex graph (i.e. that graph that as the same nodes as `mg` but the link between node `i` and `j` has weight equal to the sum of all edges weights between the various vertices representing `i` and `j` in `mg`, accounting for both layers and interlayers). See [De Domenico et al. (2013)](https://doi.org/10.1103/PhysRevX.3.041022).
"""
function get_projected_monoplex_graph(mg::M) where { M<: MultilayerGraph}
    projected_monoplex_adjacency_matrix = dropdims(sum(mg.adjacency_tensor, dims = (3,4)), dims =(3,4)) 
    
    isapproxsymmetric(projected_monoplex_adjacency_matrix) ||  throw(ErrorException("Adjacency / distance matrices must be symmetric"))


    symmetric_projected_monoplex_adjacency_matrix = Symmetric(projected_monoplex_adjacency_matrix)

    return SimpleWeightedGraph{M.parameters[1],  M.parameters[2]}(symmetric_projected_monoplex_adjacency_matrix)
end



# function get_overlay_monoplex_graph end #approach taken from https://github.com/JuliaGraphs/Graphs.jl/blob/7152d540631219fd51c43ab761ec96f12c27680e/src/core.jl#L124
"""
    get_overlay_monoplex_graph(mg::M) where {M<: MultilayerGraph}


Get overlay monoplex graph (i.e. the graph that has the same nodes as `mg` but the link between node `i` and `j` has weight equal to the sum of all edges weights between the various vertices representing `i` and `j` in `mg`, accounting for both layers and interlayers). See [De Domenico et al. (2013)](https://doi.org/10.1103/PhysRevX.3.041022).
"""
function get_overlay_monoplex_graph(mg::M) where {M<: MultilayerGraph}
    projected_overlay_adjacency_matrix = sum([mg.adjacency_tensor[:,:,i,i] for i in 1:size(mg.adjacency_tensor,3)]) 
    return SimpleWeightedGraph{M.parameters[1], M.parameters[2]}(projected_overlay_adjacency_matrix)
end


#TODO:
# We should decide whether to implement is_directed() for the MultilayerGraph. If we do implement it, the normalization factor (2 or 1) will be decided at the MultilayerGraph level,else at the 
# function get_graph_of_layers end #approach taken from https://github.com/JuliaGraphs/Graphs.jl/blob/7152d540631219fd51c43ab761ec96f12c27680e/src/core.jl#L124
"""
    get_graph_of_layers(mg::M) where {M <: MultilayerGraph}

Get a [`DiGraphOfGraph`](@ref) of the layers of `mg`. the weight of each edge between layers are obtained by summing all edge weights in the corresponding interlayer. See [De Domenico et al. (2013)](https://doi.org/10.1103/PhysRevX.3.041022).
"""
function get_graph_of_layers(mg::M; normalization::String = "total_edges") where {M <: MultilayerGraph}
    
    num_layers = length(mg.layers)
    norm_factor = 1
    if cmp(normalization,"total_edges") == 0
        norm_factor = ne(mg)
    end
    adjacency_matrix = reshape([i != j ? (1/norm_factor) * sum(mg.adjacency_tensor[:,:,i,j])/1  : 0.0 for i in 1:num_layers for j in 1:num_layers ], (num_layers,num_layers))


    isapproxsymmetric(adjacency_matrix) || throw(ErrorException("Adjacency / distance matrices must be symmetric"))

    symmetric_adjacency_matrix = Symmetric(adjacency_matrix)

    return GraphOfGraphs(getproperty.(collect(values(mg.layers)), :graph), symmetric_adjacency_matrix)
end



"""
    von_neumann_entropy(mg::M) where {T,U,  M <: MultilayerGraph{T, U}}

Compute the Von Neumann entropy of `mg`, according to [De Domenico et al. (2013)](https://doi.org/10.1103/PhysRevX.3.041022). Only for undirected multilayer graphs.
"""
function von_neumann_entropy(mg::M) where {T,U,  M <: MultilayerGraph{T, U}}
    num_nodes = length(nodes(mg))
    num_layers = length(mg.layers)
    
    # multistrength tensor
    Δ = ein"ijkm,ik,nj,om -> njom"(mg.adjacency_tensor, ones(T, size(mg.adjacency_tensor)[[1,3]]), δ(num_nodes), δ(num_layers)  )
    
    # trace of Δ
    tr_Δ = ein"iikk->"(Δ)[]

    # multilayer laplacian tensor
    L = Δ .- mg.adjacency_tensor

    # multilayer density tensor
    ρ = (1. / tr_Δ) .* L

    eigvals, eigvects = tensoreig(ρ,[2,4],[1,3])

#=     # Check that we are calculating the right eigenvalues
    lhs = ein"ijkm,ik -> jm"(ρ,eigvects[:,:,1])
    rhs = eigvals[1].*eigvects[:,:,1]
    @assert all(lhs .≈ rhs)
    # Indeed we are =#

    Λ = get_diagonal_adjacency_tensor(eigvals, size(mg.adjacency_tensor))

    # Correct for machine precision
    Λ[Λ .< eps()] .= 0.0 
    
    log2Λ = log2.(Λ)

    log2Λ[isinf.(log2Λ)].= 0

    return - ein"ijkm,jimk ->"(Λ,log2Λ)[]
end







