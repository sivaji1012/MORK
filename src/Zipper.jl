"""
ReadZipperCore — port of `pathmap/src/zipper.rs` (read zipper + PathMap).

Ports:
  - `node_along_path` utility
  - `val_count_below_root` utility
  - `ReadZipperCore{V,A}` (= Rust's `ReadZipperUntracked` — lifetime
    distinctions vanish in Julia's GC-managed world)
  - All `ZipperMoving`, `ZipperIteration`, `ZipperReadOnlyValues` methods
  - `PathMap{V,A}` container with read API

Write zipper (`write_zipper.rs`), zipper head, and exotic zippers
(ProductZipper, OverlayZipper, etc.) are deferred to Phase 1c.

Design note — inner-node storage (TaggedNodeRef analogue):
  Upstream stores `TaggedNodeRef<'a, V, A>` (typed raw ptr) in focus_node and ancestors.
  Julia equivalent: `Union{Nothing, AbstractTrieNode{V,A}}` where `nothing` = EmptyNode sentinel.
  The root_node TrieNodeODRc is kept as an anchor to ensure the root sub-trie stays reachable.
"""

# =====================================================================
# Module-level constants
# =====================================================================

const EXPECTED_DEPTH    = 16
const EXPECTED_PATH_LEN = 64

# =====================================================================
# _fnode — EmptyNode-safe inner-node accessor
# =====================================================================
#
# Upstream: `TaggedNodeRef<'a, V, A>` — a typed raw reference to the concrete node.
# Julia: `Union{Nothing, AbstractTrieNode{V,A}}` — `nothing` = EmptyNode sentinel.

@inline function _fnode(inner, ::Type{V}, ::Type{A}) where {V, A<:Allocator}
    inner === nothing ? EmptyNode{V,A}() : inner
end

# Extract the inner node from a TrieNodeODRc (returns nothing for empty)
@inline _rc_inner(rc::TrieNodeODRc) = rc.node

# =====================================================================
# node_along_path
# =====================================================================
#
# Rust: `pub(crate) fn node_along_path<...>` in zipper.rs.
# Descends as far as possible along `path` from `root_rc`.
# Returns (final_rc, remaining_key_view, val).

function node_along_path(root_rc::TrieNodeODRc{V,A},
                         path,
                         root_val::Union{Nothing,V},
                         stop_short::Bool=false) where {V,A}
    node   = root_rc
    key    = path
    val    = root_val
    inner  = _fnode(_rc_inner(node), V, A)

    if !isempty(key)
        while true
            result = node_get_child(inner, key)
            result === nothing && break
            consumed, next_rc = result
            if consumed < length(key)
                node  = next_rc
                key   = view(key, consumed+1:length(key))
                inner = _fnode(_rc_inner(node), V, A)
            else
                if !stop_short
                    val = node_get_val(inner, key)
                    node = next_rc
                    key  = view(key, 1:0)   # empty subarray
                else
                    val = nothing
                end
                break
            end
        end
    end

    (node, key, val)
end

# =====================================================================
# val_count_below_root
# =====================================================================

function val_count_below_root(inner_node)
    inner_node === nothing && return 0
    cache = Dict{UInt64,Int}()
    node_val_count(inner_node, cache)
end

# =====================================================================
# ReadZipperCore struct
# =====================================================================
#
# Rust: `pub struct ReadZipperCore<'a, 'path, V, A>` in a pub(crate) mod.
#
# Julia differences:
#  - OwnedOrBorrowed<'a, TrieNodeODRc>  → root_node::TrieNodeODRc (GC owns all)
#  - TaggedNodeRef<'a, V, A>            → Any (inner AbstractTrieNode or nothing)
#  - SliceOrLen<'path>                  → origin_path_len::Int
#  - MiriWrapper<T>                     → plain T (no Miri concerns)
#  - Lifetime params 'a, 'path          → dropped

"""
    ReadZipperCore{V, A<:Allocator}

Read-only cursor into a `PathMap`-like trie.  Corresponds to both
`ReadZipperCore` and `ReadZipperUntracked` in upstream.

focus_node and ancestors store `Union{Nothing,AbstractTrieNode{V,A}}` —
the Julia equivalent of upstream's `TaggedNodeRef<'a,V,A>` typed ref.
`nothing` is the EmptyNode sentinel. NOT `TrieNodeODRc` wrappers.
"""
mutable struct ReadZipperCore{V, A<:Allocator}
    root_key_start  ::Int               # 0-indexed: prefix_buf[root_key_start+1:] = root key
    root_val        ::Union{Nothing, V} # value at the zipper root (if any)
    root_node       ::TrieNodeODRc{V,A} # anchor Rc — keeps root sub-trie alive
    focus_node      ::Union{Nothing, AbstractTrieNode{V,A}}  # nothing = EmptyNode sentinel (TaggedNodeRef<V,A>)
    focus_iter_token::UInt128           # iteration token (NODE_ITER_INVALID = unstarted)
    prefix_buf      ::Vector{UInt8}     # full path buffer: origin_path ++ relative_path
    origin_path_len ::Int               # length of initial path prefix embedded in prefix_buf
    ancestors       ::Vector{Tuple{Union{Nothing,AbstractTrieNode{V,A}}, UInt128, Int}} # (TaggedNodeRef, iter_tok, key_offset_0)
    alloc           ::A
end

const ReadZipperUntracked{V,A} = ReadZipperCore{V,A}

# =====================================================================
# Constructors
# =====================================================================

# Internal constructor: root_rc already positioned; path = full prefix_buf content.
# root_key_start_0 is the 0-indexed offset of the root node's key in path.
function ReadZipperCore(root_rc::TrieNodeODRc{V,A},
                        path::AbstractVector{UInt8},
                        root_key_start_0::Int,
                        root_val::Union{Nothing,V},
                        alloc::A) where {V, A<:Allocator}
    ReadZipperCore{V,A}(
        root_key_start_0,
        root_val,
        root_rc,
        _rc_inner(root_rc),                         # focus_node = inner node
        NODE_ITER_INVALID,
        Vector{UInt8}(path),
        length(path),                               # origin_path_len
        Tuple{Union{Nothing,AbstractTrieNode{V,A}}, UInt128, Int}[],
        alloc,
    )
end

# Full constructor with path traversal (mirrors new_with_node_and_path_in).
# Traverses path[root_key_start_0+1:] within root_rc, then positions the
# zipper root at the deepest reachable node.
function ReadZipperCore_at_path(root_rc::TrieNodeODRc{V,A},
                                path::AbstractVector{UInt8},
                                root_prefix_len::Int,
                                root_key_start_0::Int,
                                root_val::Union{Nothing,V},
                                alloc::A) where {V, A<:Allocator}
    sub_path = view(path, root_key_start_0+1:length(path))
    final_rc, remaining_key, val = node_along_path(root_rc, sub_path, root_val, false)
    new_root_key_start = root_prefix_len - length(remaining_key)  # 0-indexed
    ReadZipperCore(final_rc, path, new_root_key_start, val, alloc)
end

# =====================================================================
# Internal helpers
# =====================================================================

# Type-parameterized EmptyNode fallback for focus dispatch
@inline _zfnode(z::ReadZipperCore{V,A}) where {V,A} = _fnode(z.focus_node, V, A)

# 0-indexed byte offset in prefix_buf where the focus node's key starts
@inline function _znode_key_start(z::ReadZipperCore)
    isempty(z.ancestors) ? z.root_key_start : z.ancestors[end][3]
end

# The key bytes within the focus node (view into prefix_buf, 0-indexed offset)
@inline function _znode_key(z::ReadZipperCore)
    ks = _znode_key_start(z)
    view(z.prefix_buf, ks+1:length(z.prefix_buf))
end

# How many bytes can be ascended within the current node (without popping ancestor)
@inline function _excess_key_len(z::ReadZipperCore)
    lb = isempty(z.ancestors) ? z.origin_path_len : z.ancestors[end][3]
    length(z.prefix_buf) - lb
end

# 0-indexed start of the parent's key in prefix_buf
@inline function _parent_key_start(z::ReadZipperCore)
    length(z.ancestors) >= 2 ? z.ancestors[end-1][3] : z.root_key_start
end

# Key leading to focus_node within its parent
@inline function _parent_key(z::ReadZipperCore)
    ks = _parent_key_start(z)
    view(z.prefix_buf, ks+1:_znode_key_start(z))
end

# prepare_buffers!: no-op in Julia (buffers always allocated)
@inline _prepare_buffers!(::ReadZipperCore) = nothing

# is_val_internal: does the current focus position hold a value?
function _is_val_internal(z::ReadZipperCore{V,A}) where {V,A}
    key = _znode_key(z)
    if !isempty(key)
        node_contains_val(_zfnode(z), key)
    elseif !isempty(z.ancestors)
        parent = z.ancestors[end][1]
        node_contains_val(_fnode(parent, V, A), _parent_key(z))
    else
        !isnothing(z.root_val)
    end
end

# get_val: value at current focus
function _get_val(z::ReadZipperCore{V,A}) where {V,A}
    key = _znode_key(z)
    if !isempty(key)
        node_get_val(_zfnode(z), key)
    elseif !isempty(z.ancestors)
        parent = z.ancestors[end][1]
        node_get_val(_fnode(parent, V, A), _parent_key(z))
    else
        z.root_val
    end
end

# regularize!: descend into child if node_get_child(focus, node_key) succeeds
function _regularize!(z::ReadZipperCore{V,A}) where {V,A}
    nk = _znode_key(z)
    result = node_get_child(_zfnode(z), nk)
    result === nothing && return
    _, next_rc = result
    push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
    z.focus_node = _rc_inner(next_rc)
    z.focus_iter_token = NODE_ITER_INVALID
end

# ascend across nodes: pop one ancestor without changing prefix_buf length
function _ascend_across_nodes!(z::ReadZipperCore)
    if !isempty(z.ancestors)
        focus_node, iter_tok, _ = pop!(z.ancestors)
        z.focus_node       = focus_node
        z.focus_iter_token = iter_tok
    else
        z.focus_iter_token = NODE_ITER_INVALID
    end
end

# ascend within node: trim prefix_buf to just past the prior branch key
function _ascend_within_node!(z::ReadZipperCore{V,A}) where {V,A}
    branch_key = prior_branch_key(_zfnode(z), _znode_key(z))
    new_len = max(z.origin_path_len, _znode_key_start(z) + length(branch_key))
    resize!(z.prefix_buf, new_len)
end

# descend_to_internal!: extend prefix_buf with k, descend via node_get_child
function _descend_to_internal!(z::ReadZipperCore{V,A}, k) where {V,A}
    z.focus_iter_token = NODE_ITER_INVALID
    append!(z.prefix_buf, k)
    key_start = _znode_key_start(z)
    key = view(z.prefix_buf, key_start+1:length(z.prefix_buf))

    while true
        result = node_get_child(_zfnode(z), key)
        result === nothing && break
        consumed, next_rc = result
        key_start += consumed
        push!(z.ancestors, (z.focus_node, NODE_ITER_INVALID, key_start))
        z.focus_node = _rc_inner(next_rc)
        if consumed < length(key)
            key = view(z.prefix_buf, key_start+1:length(z.prefix_buf))
        else
            return view(z.prefix_buf, 1:0)  # empty
        end
    end
    key
end

# descend to the first child (for descend_until, descend_first_byte)
function _descend_first!(z::ReadZipperCore{V,A}) where {V,A}
    _prepare_buffers!(z)
    prefix_opt, child_opt = first_child_from_key(_zfnode(z), _znode_key(z))
    prefix_opt === nothing && return   # unreachable per upstream
    append!(z.prefix_buf, prefix_opt)
    if child_opt !== nothing
        push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
        z.focus_node = child_opt   # already AbstractTrieNode (from first_child_from_key)
        z.focus_iter_token = NODE_ITER_INVALID
        if isempty(prefix_opt)
            _descend_first!(z)   # recurse if zero-byte prefix (node boundary)
        end
    end
end

# =====================================================================
# Zipper interface methods
# =====================================================================

function zipper_path_exists(z::ReadZipperCore{V,A}) where {V,A}
    key = _znode_key(z)
    isempty(key) ? true : node_contains_partial_key(_zfnode(z), key)
end

zipper_is_val(z::ReadZipperCore)  = _is_val_internal(z)
zipper_val(z::ReadZipperCore)     = _get_val(z)

function zipper_child_count(z::ReadZipperCore{V,A}) where {V,A}
    count_branches(_zfnode(z), _znode_key(z))
end

function zipper_child_mask(z::ReadZipperCore{V,A}) where {V,A}
    node_branches_mask(_zfnode(z), _znode_key(z))
end

# =====================================================================
# ZipperMoving methods
# =====================================================================

zipper_at_root(z::ReadZipperCore) = length(z.prefix_buf) <= z.origin_path_len

function zipper_reset!(z::ReadZipperCore)
    while !isempty(z.ancestors)
        focus_node, iter_tok, _ = pop!(z.ancestors)
        z.focus_node       = focus_node
        z.focus_iter_token = iter_tok
    end
    resize!(z.prefix_buf, z.origin_path_len)
end

# path relative to zipper root
@inline zipper_path(z::ReadZipperCore) =
    view(z.prefix_buf, z.origin_path_len+1:length(z.prefix_buf))

function zipper_val_count(z::ReadZipperCore{V,A}) where {V,A}
    root_val_cnt = _is_val_internal(z) ? 1 : 0
    nk = _znode_key(z)
    if isempty(nk)
        val_count_below_root(_zfnode(z)) + root_val_cnt
    else
        result = node_get_child(_zfnode(z), nk)
        if result !== nothing
            _, sub_rc = result
            val_count_below_root(_fnode(_rc_inner(sub_rc), V, A)) + root_val_cnt
        else
            root_val_cnt
        end
    end
end

function zipper_descend_to!(z::ReadZipperCore, k)
    isempty(k) && return
    _prepare_buffers!(z)
    _descend_to_internal!(z, k)
    nothing
end

function zipper_descend_to_check!(z::ReadZipperCore{V,A}, k) where {V,A}
    isempty(k) && return zipper_path_exists(z)
    _prepare_buffers!(z)
    remaining = _descend_to_internal!(z, k)
    isempty(remaining) ? true : node_contains_partial_key(_zfnode(z), remaining)
end

function zipper_descend_to_byte!(z::ReadZipperCore{V,A}, k::UInt8) where {V,A}
    _prepare_buffers!(z)
    push!(z.prefix_buf, k)
    z.focus_iter_token = NODE_ITER_INVALID
    nk = _znode_key(z)
    result = node_get_child(_zfnode(z), nk)
    if result !== nothing
        _, next_rc = result
        push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
        z.focus_node = _rc_inner(next_rc)
    end
    nothing
end

function zipper_descend_to_existing_byte!(z::ReadZipperCore{V,A}, k::UInt8) where {V,A}
    _prepare_buffers!(z)
    push!(z.prefix_buf, k)
    nk = _znode_key(z)
    result = node_get_child(_zfnode(z), nk)
    if result !== nothing
        z.focus_iter_token = NODE_ITER_INVALID
        _, next_rc = result
        push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
        z.focus_node = _rc_inner(next_rc)
        return true
    end
    if node_contains_partial_key(_zfnode(z), nk)
        return true
    end
    pop!(z.prefix_buf)
    false
end

function zipper_descend_indexed_byte!(z::ReadZipperCore{V,A}, child_idx::Int) where {V,A}
    _prepare_buffers!(z)
    prefix_opt, child_opt = nth_child_from_key(_zfnode(z), _znode_key(z), child_idx)
    prefix_opt === nothing && return false
    push!(z.prefix_buf, prefix_opt)
    if child_opt !== nothing
        push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
        z.focus_node = child_opt   # AbstractTrieNode from nth_child_from_key
        z.focus_iter_token = NODE_ITER_INVALID
    end
    true
end

function zipper_descend_first_byte!(z::ReadZipperCore{V,A}) where {V,A}
    _prepare_buffers!(z)
    cur_tok = iter_token_for_path(_zfnode(z), _znode_key(z))
    z.focus_iter_token = cur_tok
    new_tok, key_bytes, child_rc, _value = next_items(_zfnode(z), z.focus_iter_token)
    new_tok == NODE_ITER_FINISHED && return false

    byte_idx = length(_znode_key(z)) + 1  # 1-indexed byte in key_bytes
    byte_idx > length(key_bytes) && return false

    z.focus_iter_token = new_tok
    push!(z.prefix_buf, key_bytes[byte_idx])

    if length(key_bytes) == byte_idx && child_rc !== nothing
        push!(z.ancestors, (z.focus_node, new_tok, length(z.prefix_buf)))
        z.focus_node = _rc_inner(child_rc)
        z.focus_iter_token = new_iter_token(_zfnode(z))
    end
    true
end

function zipper_descend_until!(z::ReadZipperCore)
    moved = false
    while zipper_child_count(z) == 1
        moved = true
        _descend_first!(z)
        _is_val_internal(z) && break
    end
    moved
end

function zipper_ascend!(z::ReadZipperCore, steps::Int)
    while steps > 0
        if _excess_key_len(z) == 0
            isempty(z.ancestors) && return false
            focus_node, iter_tok, _ = pop!(z.ancestors)
            z.focus_node       = focus_node
            z.focus_iter_token = iter_tok
        end
        cur_jump = min(steps, _excess_key_len(z))
        resize!(z.prefix_buf, length(z.prefix_buf) - cur_jump)
        steps -= cur_jump
    end
    true
end

function zipper_ascend_byte!(z::ReadZipperCore)
    if _excess_key_len(z) == 0
        isempty(z.ancestors) && return false
        focus_node, iter_tok, _ = pop!(z.ancestors)
        z.focus_node       = focus_node
        z.focus_iter_token = iter_tok
    end
    pop!(z.prefix_buf)
    true
end

function zipper_ascend_until!(z::ReadZipperCore{V,A}) where {V,A}
    zipper_at_root(z) && return false
    while true
        isempty(_znode_key(z)) && _ascend_across_nodes!(z)
        _ascend_within_node!(z)
        (zipper_child_count(z) > 1 || _is_val_internal(z) || zipper_at_root(z)) && return true
    end
end

function zipper_ascend_until_branch!(z::ReadZipperCore{V,A}) where {V,A}
    zipper_at_root(z) && return false
    while true
        isempty(_znode_key(z)) && _ascend_across_nodes!(z)
        _ascend_within_node!(z)
        (zipper_child_count(z) > 1 || zipper_at_root(z)) && return true
    end
end

# =====================================================================
# ZipperIteration — to_next_val!
# =====================================================================

function _to_next_get_val!(z::ReadZipperCore{V,A}) where {V,A}
    _prepare_buffers!(z)
    while true
        if z.focus_iter_token == NODE_ITER_INVALID
            z.focus_iter_token = iter_token_for_path(_zfnode(z), _znode_key(z))
        end

        new_tok, key_bytes, child_rc, value = if z.focus_iter_token != NODE_ITER_FINISHED
            next_items(_zfnode(z), z.focus_iter_token)
        else
            (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
        end

        if new_tok != NODE_ITER_FINISHED
            z.focus_iter_token = new_tok
            key_start = _znode_key_start(z)

            # Guard: don't traverse above the origin root
            origin_len = z.origin_path_len
            if key_start < origin_len
                unmod_len = origin_len - key_start
                if unmod_len > length(key_bytes) ||
                   view(z.prefix_buf, key_start+1:origin_len) != view(key_bytes, 1:unmod_len)
                    resize!(z.prefix_buf, origin_len)
                    return nothing
                end
            end

            resize!(z.prefix_buf, key_start)
            append!(z.prefix_buf, key_bytes)

            if child_rc !== nothing
                push!(z.ancestors, (z.focus_node, new_tok, length(z.prefix_buf)))
                z.focus_node = _rc_inner(child_rc)
                z.focus_iter_token = new_iter_token(_zfnode(z))
            end

            value !== nothing && return value
        else
            # Ascend to the next ancestor
            if !isempty(z.ancestors)
                focus_node, iter_tok, prefix_offset = pop!(z.ancestors)
                z.focus_node       = focus_node
                z.focus_iter_token = iter_tok
                resize!(z.prefix_buf, prefix_offset)
            else
                z.focus_iter_token = NODE_ITER_INVALID
                resize!(z.prefix_buf, z.origin_path_len)
                return nothing
            end
        end
    end
end

zipper_to_next_val!(z::ReadZipperCore) = _to_next_get_val!(z) !== nothing

# =====================================================================
# PathMap container (ports pathmap/src/trie_map.rs — read API)
# =====================================================================

"""
    PathMap{V, A<:Allocator}

Byte-slice-keyed trie map.  Ports `PathMap<V,A>` from `trie_map.rs`.
Read API is fully implemented via `ReadZipperCore`.
Write API (`set_val_at!`, `remove_val_at!`) is Phase 1c.
"""
mutable struct PathMap{V, A<:Allocator}
    root     ::Union{Nothing, TrieNodeODRc{V,A}}
    root_val ::Union{Nothing, V}
    alloc    ::A
end

PathMap{V}() where V =
    PathMap{V, GlobalAlloc}(nothing, nothing, GlobalAlloc())

PathMap{V,A}(alloc::A) where {V, A<:Allocator} =
    PathMap{V,A}(nothing, nothing, alloc)

function _ensure_root!(m::PathMap{V,A}) where {V,A}
    m.root === nothing || return
    m.root = TrieNodeODRc(LineListNode{V,A}(m.alloc), m.alloc)
end

# ---- read zipper factories ----

"""
    read_zipper(m::PathMap) -> ReadZipperCore

Creates a read-only zipper at the root of `m`.
"""
function read_zipper(m::PathMap{V,A}) where {V,A}
    _ensure_root!(m)
    root_rc = m.root::TrieNodeODRc{V,A}
    ReadZipperCore(root_rc, UInt8[], 0, m.root_val, m.alloc)
end

"""
    read_zipper_at_path(m::PathMap, path) -> ReadZipperCore

Creates a read-only zipper pre-positioned at `path`.
"""
function read_zipper_at_path(m::PathMap{V,A}, path) where {V,A}
    _ensure_root!(m)
    root_rc = m.root::TrieNodeODRc{V,A}
    path_v  = Vector{UInt8}(path)
    rv      = isempty(path_v) ? m.root_val : nothing
    ReadZipperCore_at_path(root_rc, path_v, length(path_v), 0, rv, m.alloc)
end

# ---- high-level read API ----

"""
    get_val_at(m::PathMap, path) -> Union{Nothing, V}
"""
function get_val_at(m::PathMap, path)
    _ensure_root!(m)
    z = read_zipper_at_path(m, path)
    zipper_val(z)
end

"""
    path_exists_at(m::PathMap, path) -> Bool
"""
function path_exists_at(m::PathMap, path)
    _ensure_root!(m)
    z = read_zipper_at_path(m, path)
    zipper_path_exists(z)
end

function Base.isempty(m::PathMap)
    root_empty = m.root === nothing || node_is_empty(_fnode(_rc_inner(m.root), eltype_V(m), eltype_A(m)))
    root_empty && isnothing(m.root_val)
end

# type helpers for PathMap parameterization
eltype_V(::PathMap{V}) where V = V
eltype_A(::PathMap{V,A}) where {V,A} = A

"""
    val_count(m::PathMap) -> Int

Total values. O(N).
"""
function val_count(m::PathMap{V,A}) where {V,A}
    rv = isnothing(m.root_val) ? 0 : 1
    m.root === nothing ? rv : val_count_below_root(_fnode(_rc_inner(m.root), V, A)) + rv
end

# =====================================================================
# Exports
# =====================================================================

export ReadZipperCore, ReadZipperCore_at_path, ReadZipperUntracked
export node_along_path, val_count_below_root
export zipper_path_exists, zipper_is_val, zipper_val
export zipper_child_count, zipper_child_mask
export zipper_at_root, zipper_reset!, zipper_path, zipper_val_count
export zipper_descend_to!, zipper_descend_to_check!
export zipper_descend_to_byte!, zipper_descend_to_existing_byte!
export zipper_descend_indexed_byte!, zipper_descend_first_byte!
export zipper_descend_until!
export zipper_ascend!, zipper_ascend_byte!
export zipper_ascend_until!, zipper_ascend_until_branch!
export zipper_to_next_val!
export PathMap, _ensure_root!, read_zipper, read_zipper_at_path, get_val_at, path_exists_at, val_count
