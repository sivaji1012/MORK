"""
Morphisms — port of `pathmap/src/morphisms.rs`.

Catamorphism (fold from leaves to root) and anamorphism (build from root)
over tries.  Both stepping (every byte) and jumping (only at forks/vals)
variants are provided.  Cached variants skip recomputing shared subtries.

Julia translation notes:
  - Rust `const JUMPING` / `const DEBUG_PATH` → Julia `jumping::Bool` param.
  - Rust `CacheStrategy` trait + `NoCache`/`DoCache` → optional Dict argument.
  - `shared_node_id` → `objectid(node_inner)` for node address-based cache keys.
  - Error/infallible variants unified: Julia functions return values; errors
    propagate normally via throw/try-catch if the alg_f needs them.
"""

# =====================================================================
# CataStackFrame — bookkeeping for one forking point
# =====================================================================

mutable struct _CataFrame
    child_idx  ::Int
    child_cnt  ::Int
    child_addr ::Union{Nothing, UInt64}   # for caching (objectid of node)
end

_CataFrame(z::ReadZipperCore) = _CataFrame(0, zipper_child_count(z), nothing)

function _cata_frame_reset!(f::_CataFrame, z::ReadZipperCore)
    f.child_idx = 0
    f.child_cnt = zipper_child_count(z)
    f.child_addr = nothing
end

# =====================================================================
# ascend_to_fork — internal helper shared by both engines
# =====================================================================
#
# Mirrors `ascend_to_fork` in morphisms.rs.

"""
Internal: ascend from leaf/subtrie back to the nearest fork (or root),
calling alg_f at each step.  `jumping=true` uses ascend_until jumps.
Populates `children` with results from current invocation.
"""
function _cata_ascend_to_fork!(
    z         ::ReadZipperCore{V,A},
    alg_f     ::Function,   # (ByteMask, children::Vector, jump_len::Int, val, path::Vector{UInt8}) -> W
    children  ::Vector,
    jumping   ::Bool
) where {V,A}
    if jumping
        child_mask = zipper_child_mask(z)
        z_children = children   # start with caller-supplied children
        while true
            old_path_len = length(zipper_origin_path(z))
            old_val      = zipper_val(z)
            ascended     = zipper_ascend_until!(z)
            @assert ascended "ascend_until must move"

            origin_path = zipper_origin_path(z)
            cc          = zipper_child_count(z)
            is_val_here = zipper_is_val(z)

            jump_len = if cc != 1 || is_val_here
                old_path_len - (length(origin_path) + 1)
            else
                old_path_len - length(origin_path)
            end
            jump_len = max(0, jump_len)

            w = alg_f(child_mask, z_children, jump_len, old_val, copy(origin_path))

            (cc != 1 || zipper_at_root(z)) && return w

            z_children = [w]
            byte       = length(origin_path) >= old_path_len - jump_len ?
                             origin_path[end] : UInt8(0)
            child_mask = ByteMask(byte)
        end
    else
        # stepping: ascend one byte at a time
        child_mask = zipper_child_mask(z)
        z_children = children
        while true
            origin_path = copy(zipper_origin_path(z))
            byte        = isempty(origin_path) ? UInt8(0) : origin_path[end]
            val         = zipper_val(z)
            w           = alg_f(child_mask, z_children, 0, val, origin_path)

            ascended = zipper_ascend_byte!(z)
            @assert ascended "ascend_byte must move"

            (zipper_child_count(z) != 1 || zipper_at_root(z)) && return w

            z_children = [w]
            child_mask = ByteMask(byte)
        end
    end
end

# =====================================================================
# _zipper_origin_path / _zipper_shared_node_id helpers
# =====================================================================

"""Full path from the ReadZipperCore's origin to cursor."""
function zipper_origin_path(z::ReadZipperCore)
    view(z.prefix_buf, 1:length(z.prefix_buf))
end

"""Unique ID for the current focus node (for caching). 0 if not at node root."""
function zipper_shared_node_id(z::ReadZipperCore)
    # Only meaningful when node_key is empty (at a node boundary)
    isempty(_znode_key(z)) || return nothing
    z.focus_node === nothing ? nothing : UInt64(objectid(z.focus_node))
end

# =====================================================================
# Side-effect catamorphism engine
# =====================================================================
#
# Mirrors `cata_side_effect_body<JUMPING>` in morphisms.rs.

"""
    _cata_side_effect!(z, alg_f, jumping) → W

DFS fold from leaves to root.  At each forking point, calls:
  `alg_f(child_mask::ByteMask, children::Vector{W}, jump_len::Int,
         val::Union{Nothing,V}, path::Vector{UInt8}) → W`
`jumping=true` skips monotone paths between forks.
"""
function _cata_side_effect!(
    z       ::ReadZipperCore{V,A},
    alg_f   ::Function,
    jumping ::Bool
) where {V,A}
    stack    = _CataFrame[]
    children = []
    frame_idx = 0

    zipper_reset!(z)
    push!(stack, _CataFrame(z))

    if !zipper_descend_first_byte!(z)
        # Empty trie special case
        return alg_f(zipper_child_mask(z), [], 0, zipper_val(z),
                     copy(zipper_origin_path(z)))
    end

    while true
        # Descend to leaf or fork
        is_leaf = false
        while zipper_child_count(z) < 2
            if !zipper_descend_until!(z)
                is_leaf = true
                break
            end
        end

        if is_leaf
            cur_w = _cata_ascend_to_fork!(z, alg_f, [], jumping)
            push!(children, cur_w)
            stack[frame_idx+1].child_idx += 1

            # Keep ascending until we reach an unfinished fork
            while stack[frame_idx+1].child_idx == stack[frame_idx+1].child_cnt
                if frame_idx == 0
                    sf       = stack[1]
                    val      = zipper_val(z)
                    cm       = zipper_child_mask(z)
                    @assert sf.child_idx == sf.child_cnt
                    @assert sf.child_cnt == length(children)
                    w = if sf.child_cnt != 1 || val !== nothing || !jumping
                        alg_f(cm, children, 0, val, copy(zipper_origin_path(z)))
                    else
                        pop!(children)
                    end
                    return w
                else
                    sf         = stack[frame_idx+1]
                    child_start = length(children) - sf.child_cnt
                    sub_ch      = children[child_start+1:end]
                    cur_w       = _cata_ascend_to_fork!(z, alg_f, sub_ch, jumping)
                    resize!(children, child_start)
                    frame_idx  -= 1
                    push!(children, cur_w)
                    stack[frame_idx+1].child_idx += 1
                end
            end

            # Descend the next child branch
            descended = zipper_descend_indexed_byte!(z, stack[frame_idx+1].child_idx)
            @assert descended
        else
            # Push new frame and descend first child
            frame_idx += 1
            if frame_idx < length(stack)
                _cata_frame_reset!(stack[frame_idx+1], z)
            else
                push!(stack, _CataFrame(z))
            end
            zipper_descend_first_byte!(z)
        end
    end
end

# =====================================================================
# Cached catamorphism engine
# =====================================================================
#
# Mirrors `into_cata_cached_body<JUMPING>`.

"""
    _cata_cached!(z, alg_f, jumping) → W

Like `_cata_side_effect!` but caches W by node identity (objectid).
Reuses cached results when the zipper reaches a previously seen node.
`alg_f` receives `(child_mask, children, val, sub_path::Vector{UInt8}) → W`
where `sub_path` is the "jumped" sub-path for jumping variant (else `[]`).
"""
function _cata_cached!(
    z       ::ReadZipperCore{V,A},
    alg_f   ::Function,
    jumping ::Bool
) where {V,A}
    zipper_reset!(z)

    stack    = _CataFrame[]
    children = []
    cache    = Dict{UInt64, Any}()   # node objectid → cached W

    push!(stack, _CataFrame(z))

    while true
        frame = stack[end]

        if frame.child_idx < frame.child_cnt
            zipper_descend_indexed_byte!(z, frame.child_idx)
            frame.child_idx += 1
            nid = zipper_shared_node_id(z)
            frame.child_addr = nid

            # Check cache
            if nid !== nothing && haskey(cache, nid)
                push!(children, cache[nid])
                zipper_ascend_byte!(z)
                continue
            end

            # Descend to leaf or fork
            is_leaf = false
            while zipper_child_count(z) < 2
                !zipper_descend_until!(z) && (is_leaf = true; break)
            end

            if is_leaf
                inner_alg = (mask, ch, jump, val, path) -> begin
                    sub_path = jumping ? view(path, max(1,length(path)-jump):length(path)) : UInt8[]
                    alg_f(mask, ch, val, collect(sub_path))
                end
                cur_w = _cata_ascend_to_fork!(z, inner_alg, [], jumping)
                if nid !== nothing; cache[nid] = cur_w; end
                push!(children, cur_w)
                continue
            end

            # Recurse deeper
            push!(stack, _CataFrame(z))
            continue
        end

        # All children of this frame processed
        frame_idx   = length(stack)
        sf          = pop!(stack)
        child_start = length(children) - sf.child_cnt

        if frame_idx == 1
            # Root
            @assert zipper_at_root(z)
            val        = zipper_val(z)
            child_mask = zipper_child_mask(z)
            sub_ch     = children[child_start+1:end]
            w = if jumping && sf.child_cnt == 1 && val === nothing
                pop!(children)
            else
                alg_f(child_mask, sub_ch, val, UInt8[])
            end
            return w
        end

        # Aggregate subtree + ascend
        sub_ch = children[child_start+1:end]
        inner_alg = (mask, ch, jump, val2, path) -> begin
            sub_path = jumping ? view(path, max(1,length(path)-jump):length(path)) : UInt8[]
            alg_f(mask, ch, val2, collect(sub_path))
        end
        cur_w = _cata_ascend_to_fork!(z, inner_alg, sub_ch, jumping)
        resize!(children, child_start)

        parent_frame = stack[end]
        if parent_frame.child_addr !== nothing
            cache[parent_frame.child_addr] = cur_w
        end
        push!(children, cur_w)
    end
end

# =====================================================================
# Public catamorphism API on PathMap and ReadZipperCore
# =====================================================================

"""
    cata_side_effect(m::PathMap, alg_f) → W

Stepping catamorphism on `m`.  `alg_f(child_mask, children, val, path) → W`.
Mirrors `PathMap::into_cata_side_effect`.
"""
function cata_side_effect(m::PathMap{V,A}, alg_f::Function) where {V,A}
    z = read_zipper(m)
    _cata_side_effect!(z, (mask, ch, jump, val, path) -> alg_f(mask, ch, val, path), false)
end

"""
    cata_jumping_side_effect(m::PathMap, alg_f) → W

Jumping catamorphism.  `alg_f(child_mask, children, jump_len, val, path) → W`.
Mirrors `PathMap::into_cata_jumping_side_effect`.
"""
function cata_jumping_side_effect(m::PathMap{V,A}, alg_f::Function) where {V,A}
    z = read_zipper(m)
    _cata_side_effect!(z, alg_f, true)
end

"""
    cata_cached(m::PathMap, alg_f) → W

Cached stepping catamorphism.  `alg_f(child_mask, children, val) → W`.
Mirrors `PathMap::into_cata_cached`.
"""
function cata_cached(m::PathMap{V,A}, alg_f::Function) where {V,A}
    z = read_zipper(m)
    _cata_cached!(z, (mask, ch, val, _sub) -> alg_f(mask, ch, val), false)
end

"""
    cata_jumping_cached(m::PathMap, alg_f) → W

Cached jumping catamorphism.  `alg_f(child_mask, children, val, sub_path) → W`.
Mirrors `PathMap::into_cata_jumping_cached`.
"""
function cata_jumping_cached(m::PathMap{V,A}, alg_f::Function) where {V,A}
    z = read_zipper(m)
    _cata_cached!(z, alg_f, true)
end

# ReadZipperCore variants (take the zipper directly)
function cata_side_effect(z::ReadZipperCore{V,A}, alg_f::Function) where {V,A}
    _cata_side_effect!(z, (mask, ch, jump, val, path) -> alg_f(mask, ch, val, path), false)
end
function cata_jumping_side_effect(z::ReadZipperCore{V,A}, alg_f::Function) where {V,A}
    _cata_side_effect!(z, alg_f, true)
end
function cata_cached(z::ReadZipperCore{V,A}, alg_f::Function) where {V,A}
    _cata_cached!(z, (mask, ch, val, _sub) -> alg_f(mask, ch, val), false)
end
function cata_jumping_cached(z::ReadZipperCore{V,A}, alg_f::Function) where {V,A}
    _cata_cached!(z, alg_f, true)
end

"""
    map_hash(m::PathMap) → UInt64
Hash the trie and all values using structural sharing.
Mirrors `Catamorphism::hash`.
"""
function map_hash(m::PathMap{V,A}) where {V,A}
    cata_cached(m, (mask, children, val) -> begin
        h = hash(mask.bits)
        for c in children; h = hash(h, UInt64(c isa Number ? c : objectid(c))); end
        val !== nothing && (h = hash(h, hash(val)))
        h
    end)
end

# =====================================================================
# Anamorphism — build a trie from a generating function
# =====================================================================
#
# Mirrors `new_map_from_ana_jumping`.

"""
    ana_jumping!(wz::WriteZipperCore, w, coalg_f)

Recursively build a trie by calling `coalg_f(w, path) → (prefix, ByteMask, ws, val)`.
Mirrors `new_map_from_ana_jumping`.
"""
function ana_jumping!(wz::WriteZipperCore{V,A}, w, coalg_f::Function) where {V,A}
    path    = collect(wz_path(wz))
    result  = coalg_f(w, path)
    prefix, bm, ws_iter, mv = result
    prefix_v = collect(UInt8, prefix)
    prefix_len = length(prefix_v)

    wz_descend_to!(wz, prefix_v)
    mv !== nothing && wz_set_val!(wz, mv)

    for (b, wi) in zip(bitmask_iter(bm), ws_iter)
        wz_descend_to_byte!(wz, b)
        ana_jumping!(wz, wi, coalg_f)
        wz_ascend_byte!(wz)
    end

    wz_ascend!(wz, prefix_len)
end

"""Helper: iterate bytes set in a ByteMask."""
function bitmask_iter(mask::ByteMask)
    result = UInt8[]
    m = mask
    while true
        b = next_bit(m, UInt8(0))
        b === nothing && break
        push!(result, b)
        m = unset(m, b)
    end
    result
end

# =====================================================================
# TrieBuilder — anamorphism helper for building tries from callbacks
# =====================================================================
#
# Mirrors `TrieBuilder<V, W, A>` in morphisms.rs.
# Used by callers to declare children before building sub-tries.

"""
    TrieBuilder{V, W, A}

Accumulates child branches (byte + `W` result) for an anamorphism step.
Mirrors `TrieBuilder<V, W, A>`.
"""
mutable struct TrieBuilder{V, W, A<:Allocator}
    child_mask ::ByteMask
    child_paths::Vector{Vector{UInt8}}  # sub-paths > 1 byte
    child_ws   ::Vector{Any}            # W or TrieNodeODRc (WOrNode)
    alloc      ::A
end

TrieBuilder{V,W}(alloc::A) where {V,W,A} = TrieBuilder{V,W,A}(ByteMask(), Vector{UInt8}[], Any[], alloc)
TrieBuilder{V,W}() where {V,W} = TrieBuilder{V,W}(GlobalAlloc())

"""Push a single-byte child branch with result `w`."""
function tb_push_byte!(tb::TrieBuilder, byte::UInt8, w)
    tb.child_mask = set(tb.child_mask, byte)
    push!(tb.child_ws, w)
end

"""Push a multi-byte sub-path child."""
function tb_push!(tb::TrieBuilder, sub_path::AbstractVector{UInt8}, w)
    @assert !isempty(sub_path)
    length(sub_path) > 1 && push!(tb.child_paths, collect(sub_path))
    tb_push_byte!(tb, sub_path[1], w)
end

"""Number of children pushed so far."""
tb_len(tb::TrieBuilder) = length(tb.child_ws)

"""Returns the child mask."""
tb_child_mask(tb::TrieBuilder) = tb.child_mask

"""Graft a read zipper's focus at `byte`."""
function tb_graft_at_byte!(tb::TrieBuilder{V,W,A}, byte::UInt8,
                            rc::TrieNodeODRc{V,A}) where {V,W,A}
    tb.child_mask = set(tb.child_mask, byte)
    push!(tb.child_ws, rc)
end

"""Reset the builder for reuse."""
function tb_reset!(tb::TrieBuilder)
    tb.child_mask = ByteMask()
    empty!(tb.child_paths)
    empty!(tb.child_ws)
end

# =====================================================================
# Exports
# =====================================================================

export cata_side_effect, cata_jumping_side_effect
export cata_cached, cata_jumping_cached
export ana_jumping!
export TrieBuilder, tb_push_byte!, tb_push!, tb_len, tb_child_mask
export tb_graft_at_byte!, tb_reset!
export map_hash
export zipper_origin_path, zipper_shared_node_id
