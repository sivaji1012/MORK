"""
WriteZipperCore — port of `pathmap/src/write_zipper.rs` (Phase 1c).

Ports:
  - `WriteZipperCore{V,A}` struct + KeyFields-equivalent fields
  - `in_zipper_mut_static_result` / `replace_top_node` COW upgrade helpers
  - `descend_to_internal` / `mend_root` / `ascend` navigation
  - `set_val` / `remove_val` mutation primitives
  - `write_zipper` / `write_zipper_at_path` PathMap constructors
  - `set_val_at!` / `remove_val_at!` high-level PathMap API (replaces stubs)

Design notes vs Rust:
  - `MutNodeStack` (raw-ptr cursor) → `Vector{TrieNodeODRc{V,A}}` (GC refs).
    The Julia GC prevents dangling; we mutate `TrieNodeODRc.node` in-place or
    call `node_replace_child!` on the parent when an upgrade occurs.
  - `KeyFields` is inlined into the struct (no lifetime split needed).
  - `root_val: *mut Option<V>` → `pathmap.root_val` accessed via the PathMap ref.
  - Focus semantics: `focus_stack[end]` = the node CONTAINING the cursor position;
    `_wz_node_key(z)` = remaining path WITHIN that node to reach the cursor.
    (Same as Rust's `focus_stack.top()` + `key.node_key()`.)
"""

# =====================================================================
# WriteZipperCore struct
# =====================================================================

"""
    WriteZipperCore{V, A<:Allocator}

Mutable write cursor into a `PathMap`.  Corresponds to `WriteZipperCore` /
`WriteZipperUntracked` in upstream (lifetimes dropped in Julia).

Fields mirror `WriteZipperCore + KeyFields` in write_zipper.rs:
  - `pathmap`         — owning PathMap (for root replacement + root_val access)
  - `root_key_start`  — 0-indexed offset of root node's key in `prefix_buf`
  - `prefix_buf`      — full path bytes (origin prefix + traversal extension)
  - `origin_path_len` — length of the initial origin-path prefix in `prefix_buf`
  - `prefix_idx`      — 0-indexed key_start offsets, one per ancestor level
  - `focus_stack`     — TrieNodeODRc references from root down to current focus
  - `alloc`           — allocator (carried for node creation)
"""
mutable struct WriteZipperCore{V, A<:Allocator}
    pathmap         ::PathMap{V,A}
    root_key_start  ::Int                        # 0-indexed (mirrors KeyFields.root_key_start)
    prefix_buf      ::Vector{UInt8}              # mirrors KeyFields.prefix_buf
    origin_path_len ::Int                        # mirrors origin_path.len()
    prefix_idx      ::Vector{Int}                # 0-indexed per level (mirrors KeyFields.prefix_idx)
    focus_stack     ::Vector{TrieNodeODRc{V,A}}  # mirrors MutNodeStack
    alloc           ::A
end

const WriteZipperUntracked{V,A} = WriteZipperCore{V,A}

# =====================================================================
# Key helpers
# =====================================================================
#
# Mirror KeyFields methods: node_key_start, node_key, parent_key, excess_key_len

@inline function _wz_node_key_start(z::WriteZipperCore)
    isempty(z.prefix_idx) ? z.root_key_start : z.prefix_idx[end]
end

@inline function _wz_node_key(z::WriteZipperCore)
    ks = _wz_node_key_start(z)
    view(z.prefix_buf, ks+1:length(z.prefix_buf))
end

@inline _wz_at_root(z::WriteZipperCore) = isempty(_wz_node_key(z))

# Key from the grandparent to the current focus (used by _wz_replace_top_node!)
# Mirrors KeyFields.parent_key()
@inline function _wz_parent_key(z::WriteZipperCore)
    ks = length(z.prefix_idx) > 1 ? z.prefix_idx[end-1] : z.root_key_start
    ke = _wz_node_key_start(z)   # 0-indexed end (exclusive in Rust → inclusive at ke in Julia)
    view(z.prefix_buf, ks+1:ke)
end

# =====================================================================
# _wz_replace_top_node! — COW upgrade when a node needs replacement
# =====================================================================
#
# Mirrors `replace_top_node` in write_zipper.rs (lines 2373-2388).
# When `node_set_val!` / `node_set_branch!` returns a `TrieNodeODRc`
# replacement (LineListNode → DenseByteNode upgrade), we:
#   depth > 1 : pop, tell parent to replace its child slot, re-push new_rc
#   depth == 1: update pathmap.root directly

function _wz_replace_top_node!(z::WriteZipperCore{V,A},
                                new_rc::TrieNodeODRc{V,A}) where {V,A}
    if length(z.focus_stack) > 1
        pop!(z.focus_stack)
        parent_node = z.focus_stack[end].node
        pk = collect(_wz_parent_key(z))          # parent_key as owned Vector
        node_replace_child!(parent_node, pk, new_rc)
        push!(z.focus_stack, new_rc)
    else
        # At root: update PathMap.root and the stack root entry
        z.pathmap.root = new_rc
        z.focus_stack[1] = new_rc
    end
end

# =====================================================================
# _wz_in_mut_static_result! — try mutation, handle upgrade
# =====================================================================
#
# Mirrors `in_zipper_mut_static_result` (write_zipper.rs line 2134).
# Calls `node_f(focus_node, key)`.  If the result is a TrieNodeODRc
# (upgrade), replaces the top node and calls `retry_f`.

function _wz_in_mut_static_result!(z::WriteZipperCore{V,A},
                                    node_f::Function,
                                    retry_f::Function) where {V,A}
    key        = collect(_wz_node_key(z))
    focus_node = z.focus_stack[end].node
    result     = node_f(focus_node, key)
    if result isa TrieNodeODRc
        _wz_replace_top_node!(z, result)
        new_focus = z.focus_stack[end].node
        retry_f(new_focus, key)
    else
        result
    end
end

# =====================================================================
# _wz_descend_to_internal! — follow prefix_buf, pushing nodes
# =====================================================================
#
# Mirrors `descend_to_internal` (write_zipper.rs line 2317).
# WriteZipper stops descending when < 2 bytes remain (node_key >= 1 byte
# must remain for the focus-holds-parent invariant).

function _wz_descend_to_internal!(z::WriteZipperCore{V,A}) where {V,A}
    key_start = _wz_node_key_start(z)
    key       = view(z.prefix_buf, key_start+1:length(z.prefix_buf))
    length(key) < 2 && return

    while true
        focus_node = z.focus_stack[end].node
        result     = node_get_child(focus_node, key)
        result === nothing && break
        consumed, child_rc = result
        # Only descend if there are bytes remaining AFTER consuming this child's key
        consumed >= length(key) && break
        key_start += consumed
        push!(z.prefix_idx,    key_start)
        push!(z.focus_stack,   child_rc)
        key = view(z.prefix_buf, key_start+1:length(z.prefix_buf))
        length(key) < 2 && break   # must keep >= 1 byte as node_key
    end
end

# =====================================================================
# _wz_mend_root! — regularize after subnode creation above origin root
# =====================================================================
#
# Mirrors `mend_root` (write_zipper.rs line 2298).
# Only active when origin_path_len > 1 and focus is at the root level.
# For write_zipper(m) / write_zipper_at_path with origin_path_len = 0,
# this is always a no-op.

function _wz_mend_root!(z::WriteZipperCore{V,A}) where {V,A}
    (isempty(z.prefix_idx) && z.origin_path_len > 1) || return
    length(z.focus_stack) == 1 || return
    root_prefix = view(z.prefix_buf, 1:z.origin_path_len)
    nks = z.root_key_start
    nks >= length(root_prefix) && return
    root_slice = view(root_prefix, nks+1:length(root_prefix))
    root_rc    = z.focus_stack[1]
    # Traverse root_slice to find the deepest reachable node
    (final_rc, remaining, _) = node_along_path(root_rc, root_slice, nothing, true)
    if length(remaining) < length(root_slice)
        z.root_key_start += length(root_slice) - length(remaining)
    end
    z.focus_stack[1] = final_rc
end

# =====================================================================
# wz_set_val! — set a value at the cursor position
# =====================================================================
#
# Mirrors WriteZipperCore::set_val (write_zipper.rs line 1345).

"""
    wz_set_val!(z::WriteZipperCore, val) -> Union{Nothing, V}

Set the value at the zipper's current cursor position.  Returns the
previously stored value (or `nothing`).  Handles COW node upgrades
transparently.  Mirrors upstream `WriteZipperCore::set_val`.
"""
function wz_set_val!(z::WriteZipperCore{V,A}, val::V) where {V,A}
    nk = _wz_node_key(z)
    if isempty(nk)
        # At root: write directly to PathMap.root_val
        old_val          = z.pathmap.root_val
        z.pathmap.root_val = val
        return old_val
    end

    (old_val, created_subnode) = _wz_in_mut_static_result!(z,
        (node, key) -> node_set_val!(node, key, val),
        (_node, _key) -> (nothing, true))  # retry after upgrade always creates subnode

    if created_subnode
        _wz_mend_root!(z)
        _wz_descend_to_internal!(z)
    end
    old_val
end

# =====================================================================
# wz_remove_val! — remove the value at the cursor position
# =====================================================================
#
# Mirrors WriteZipperCore::remove_val (write_zipper.rs line 1362).
# No COW upgrade is needed for removal.

"""
    wz_remove_val!(z::WriteZipperCore, prune::Bool=false) -> Union{Nothing, V}

Remove the value at the zipper's current cursor position.  If `prune`
is true, empty dangling paths are pruned.  Mirrors `remove_val`.
"""
function wz_remove_val!(z::WriteZipperCore{V,A}, prune::Bool=false) where {V,A}
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        old_val            = z.pathmap.root_val
        z.pathmap.root_val = nothing
        return old_val
    end
    focus_node = z.focus_stack[end].node
    node_remove_val!(focus_node, nk, prune)
end

# =====================================================================
# wz_descend_to! — navigate the write zipper to a sub-path
# =====================================================================
#
# Mirrors ZipperMoving::descend_to (write_zipper.rs line 1005).

"""
    wz_descend_to!(z::WriteZipperCore, k) -> nothing

Extend the cursor's path by `k` bytes and descend as far as possible
through existing trie nodes.  Mirrors `descend_to`.
"""
function wz_descend_to!(z::WriteZipperCore, k)
    isempty(k) && return
    append!(z.prefix_buf, k)
    _wz_descend_to_internal!(z)
    nothing
end

# =====================================================================
# wz_ascend! — move cursor up N bytes
# =====================================================================
#
# Mirrors ZipperMoving::ascend (write_zipper.rs line 1012).

"""
    wz_ascend!(z::WriteZipperCore, steps::Int=1) -> Bool

Ascend `steps` bytes toward the zipper root.  Returns `true` on success,
`false` if the zipper is already at the root.  Mirrors `ascend`.
"""
function wz_ascend!(z::WriteZipperCore, steps::Int=1)
    while true
        if isempty(_wz_node_key(z))
            # ascend_across_nodes: pop ancestor level if possible (no-op at root)
            if !isempty(z.prefix_idx)
                pop!(z.focus_stack)
                pop!(z.prefix_idx)
            end
        end
        steps == 0 && return true
        _wz_at_root(z) && return false
        cur_jump = min(steps, length(_wz_node_key(z)))
        resize!(z.prefix_buf, length(z.prefix_buf) - cur_jump)
        steps -= cur_jump
    end
end

# =====================================================================
# Read-like queries on WriteZipperCore
# =====================================================================

"""
    wz_path_exists(z::WriteZipperCore) -> Bool

True iff the trie contains any path starting at the cursor.
Mirrors `path_exists`.
"""
function wz_path_exists(z::WriteZipperCore{V,A}) where {V,A}
    nk = _wz_node_key(z)
    isempty(nk) && return true
    focus_node = z.focus_stack[end].node
    node_contains_partial_key(focus_node, nk)
end

"""
    wz_is_val(z::WriteZipperCore) -> Bool

True iff there is a value at the cursor position.  Mirrors `is_val`.
"""
function wz_is_val(z::WriteZipperCore{V,A}) where {V,A}
    nk = _wz_node_key(z)
    if isempty(nk)
        return !isnothing(z.pathmap.root_val)
    end
    focus_node = z.focus_stack[end].node
    node_contains_val(focus_node, nk)
end

"""
    wz_get_val(z::WriteZipperCore) -> Union{Nothing, V}

Return the value at the cursor position (or `nothing`).  Mirrors `val`.
"""
function wz_get_val(z::WriteZipperCore{V,A}) where {V,A}
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        return z.pathmap.root_val
    end
    focus_node = z.focus_stack[end].node
    node_get_val(focus_node, nk)
end

# path relative to the zipper's origin
wz_path(z::WriteZipperCore) =
    view(z.prefix_buf, z.origin_path_len+1:length(z.prefix_buf))

# =====================================================================
# PathMap write zipper constructors
# =====================================================================
#
# Mirrors PathMap::write_zipper / write_zipper_at_path (trie_map.rs).

"""
    write_zipper(m::PathMap) -> WriteZipperCore

Create a write zipper at the root of `m`.  Mirrors `PathMap::write_zipper`.
"""
function write_zipper(m::PathMap{V,A}) where {V,A}
    _ensure_root!(m)
    root_rc = m.root::TrieNodeODRc{V,A}
    WriteZipperCore{V,A}(
        m,
        0,                              # root_key_start (0-indexed)
        UInt8[],                        # prefix_buf (empty = at origin)
        0,                              # origin_path_len
        Int[],                          # prefix_idx
        TrieNodeODRc{V,A}[root_rc],    # focus_stack: [root]
        m.alloc
    )
end

"""
    write_zipper_at_path(m::PathMap, path) -> WriteZipperCore

Create a write zipper pre-positioned at `path`.
Mirrors `PathMap::write_zipper_at_path`.
"""
function write_zipper_at_path(m::PathMap{V,A}, path) where {V,A}
    _ensure_root!(m)
    path_v = collect(UInt8, path)
    if isempty(path_v)
        return write_zipper(m)
    end
    root_rc = m.root::TrieNodeODRc{V,A}
    # Build zipper with full path as prefix_buf, then descend
    # root_key_start = 0 (origin is at the absolute map root)
    z = WriteZipperCore{V,A}(
        m,
        0,
        path_v,                         # prefix_buf = path
        length(path_v),                 # origin_path_len = path.len()
        Int[],                          # prefix_idx starts empty
        TrieNodeODRc{V,A}[root_rc],
        m.alloc
    )
    _wz_descend_to_internal!(z)
    z
end

# =====================================================================
# PathMap high-level write API  (replaces stubs in Zipper.jl)
# =====================================================================

"""
    set_val_at!(m::PathMap, path, val) -> Union{Nothing, V}

Set the value at `path` in `m`.  Returns the previously stored value.
"""
function set_val_at!(m::PathMap{V,A}, path, val::V) where {V,A}
    z = write_zipper(m)
    wz_descend_to!(z, collect(UInt8, path))
    wz_set_val!(z, val)
end

"""
    remove_val_at!(m::PathMap, path, prune::Bool=false) -> Union{Nothing, V}

Remove the value at `path` in `m`.  Returns the removed value.
"""
function remove_val_at!(m::PathMap{V,A}, path, prune::Bool=false) where {V,A}
    m.root === nothing && return nothing
    z = write_zipper_at_path(m, collect(UInt8, path))
    wz_remove_val!(z, prune)
end

# =====================================================================
# _wz_get_focus_anr — get AbstractNodeRef at cursor position
# =====================================================================
#
# Mirrors WriteZipperCore::get_focus (write_zipper.rs:1231).
# Non-root: delegate to get_node_at_key on the focus node.
# At root: wrap the root TrieNodeODRc as ANRBorrowedRc.

function _wz_get_focus_anr(z::WriteZipperCore{V,A}) where {V,A}
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        ANRBorrowedRc{V,A}(z.focus_stack[1])
    else
        get_node_at_key(z.focus_stack[end].node, nk)
    end
end

# =====================================================================
# _wz_remove_branches! — remove all branches at cursor
# =====================================================================
#
# Mirrors WriteZipperCore::remove_branches (write_zipper.rs:1948).
# prune=true path (prune_path_internal) is deferred — passing false is safe.

function _wz_remove_branches!(z::WriteZipperCore{V,A}, prune::Bool) where {V,A}
    nk = collect(_wz_node_key(z))
    if !isempty(nk)
        focus_node = z.focus_stack[end].node
        removed = node_remove_all_branches!(focus_node, nk, prune)
        removed
    else
        @assert length(z.focus_stack) == 1
        if node_is_empty(z.focus_stack[1].node)
            return false
        end
        empty_rc = TrieNodeODRc(LineListNode{V,A}(z.alloc), z.alloc)
        z.pathmap.root = empty_rc
        z.focus_stack[1] = empty_rc
        true
    end
end

# =====================================================================
# _wz_graft_internal! — plant src at cursor (core of all lattice ops)
# =====================================================================
#
# Mirrors WriteZipperCore::graft_internal (write_zipper.rs:2101).
# src === nothing → _wz_remove_branches!
# at root (node_key empty) → direct stack/pathmap root replacement
# otherwise → node_set_branch! via _wz_in_mut_static_result!

function _wz_graft_internal!(z::WriteZipperCore{V,A},
                              src::Union{Nothing,TrieNodeODRc{V,A}}) where {V,A}
    if src !== nothing
        nk = collect(_wz_node_key(z))
        if !isempty(nk)
            sub_branch_added = _wz_in_mut_static_result!(z,
                (node, key) -> node_set_branch!(node, key, src),
                (_, _)      -> true)
            if sub_branch_added
                _wz_mend_root!(z)
                _wz_descend_to_internal!(z)
            end
        else
            z.pathmap.root   = src
            z.focus_stack[1] = src
        end
    else
        _wz_remove_branches!(z, false)
    end
end

# =====================================================================
# wz_graft! / wz_graft_map! — unconditional subtrie replacement
# =====================================================================
#
# Mirrors WriteZipperCore::graft / graft_map (write_zipper.rs:1401/1411).
# graft_root_vals feature not enabled — root val handling omitted.

"""
    wz_graft!(z, src_anr)

Replace the subtrie at the cursor with `src_anr`'s subtrie.
"""
function wz_graft!(z::WriteZipperCore{V,A}, src_anr::AbstractNodeRef{V,A}) where {V,A}
    _wz_graft_internal!(z, into_option(src_anr))
end

"""
    wz_graft_map!(z, map)

Replace the subtrie at the cursor with `map`'s root node.
"""
function wz_graft_map!(z::WriteZipperCore{V,A}, map::PathMap{V,A}) where {V,A}
    _wz_graft_internal!(z, map.root)
end

# =====================================================================
# wz_join_into! — pjoin self with src, result stored in self
# =====================================================================
#
# Mirrors WriteZipperCore::join_into (write_zipper.rs:1499).
# Returns AlgebraicStatus.

"""
    wz_join_into!(z, src_anr) -> AlgebraicStatus

Join (lattice-sup) self's subtrie with `src_anr`. Result written to self.
"""
function wz_join_into!(z::WriteZipperCore{V,A}, src_anr::AbstractNodeRef{V,A}) where {V,A}
    if is_none(src_anr) || node_is_empty(as_tagged(src_anr))
        focus_anr = _wz_get_focus_anr(z)
        return (is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))) ?
               ALG_STATUS_NONE : ALG_STATUS_IDENTITY
    end
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr)
        _wz_graft_internal!(z, into_option(src_anr))
        return ALG_STATUS_ELEMENT
    end
    self_node = as_tagged(focus_anr)
    if node_is_empty(self_node)
        _wz_graft_internal!(z, into_option(src_anr))
        return ALG_STATUS_ELEMENT
    end
    result = pjoin_dyn(self_node, as_tagged(src_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        result.mask & SELF_IDENT > 0 ? ALG_STATUS_IDENTITY :
            (_wz_graft_internal!(z, into_option(src_anr)); ALG_STATUS_ELEMENT)
    else
        _wz_graft_internal!(z, nothing)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_join_map_into! — pjoin self with PathMap, result stored in self
# =====================================================================
#
# Mirrors WriteZipperCore::join_map_into (write_zipper.rs:1535).

"""
    wz_join_map_into!(z, map) -> AlgebraicStatus

Join self's subtrie with `map`. Result written to self.
"""
function wz_join_map_into!(z::WriteZipperCore{V,A}, map::PathMap{V,A}) where {V,A}
    src_rc = map.root
    if src_rc === nothing
        focus_anr = _wz_get_focus_anr(z)
        return (is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))) ?
               ALG_STATUS_NONE : ALG_STATUS_IDENTITY
    end
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr)
        _wz_graft_internal!(z, src_rc)
        return ALG_STATUS_ELEMENT
    end
    self_node = as_tagged(focus_anr)
    if node_is_empty(self_node)
        _wz_graft_internal!(z, src_rc)
        return ALG_STATUS_ELEMENT
    end
    result = pjoin_dyn(self_node, src_rc.node)
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        result.mask & SELF_IDENT > 0 ? ALG_STATUS_IDENTITY :
            (_wz_graft_internal!(z, src_rc); ALG_STATUS_ELEMENT)
    else
        _wz_graft_internal!(z, nothing)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_meet_into! — pmeet self with src, result stored in self
# =====================================================================
#
# Mirrors WriteZipperCore::meet_into (write_zipper.rs:1718).

"""
    wz_meet_into!(z, src_anr, prune=false) -> AlgebraicStatus

Meet (lattice-inf) self's subtrie with `src_anr`. Result written to self.
`prune=true` removes empty dangling ancestor paths (not yet implemented).
"""
function wz_meet_into!(z::WriteZipperCore{V,A}, src_anr::AbstractNodeRef{V,A},
                       prune::Bool=false) where {V,A}
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))
        return ALG_STATUS_NONE
    end
    if is_none(src_anr)
        _wz_graft_internal!(z, nothing)
        return ALG_STATUS_NONE
    end
    self_node = as_tagged(focus_anr)
    result = pmeet_dyn(self_node, as_tagged(src_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        result.mask & SELF_IDENT > 0 ? ALG_STATUS_IDENTITY :
            (_wz_graft_internal!(z, into_option(src_anr)); ALG_STATUS_ELEMENT)
    else
        _wz_graft_internal!(z, nothing)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_subtract_into! — psubtract src from self, result stored in self
# =====================================================================
#
# Mirrors WriteZipperCore::subtract_into (write_zipper.rs:1829).

"""
    wz_subtract_into!(z, src_anr, prune=false) -> AlgebraicStatus

Subtract `src_anr` from self's subtrie. Result written to self.
`prune=true` removes empty dangling paths (not yet implemented).
"""
function wz_subtract_into!(z::WriteZipperCore{V,A}, src_anr::AbstractNodeRef{V,A},
                            prune::Bool=false) where {V,A}
    focus_anr = _wz_get_focus_anr(z)
    self_empty = is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))
    if is_none(src_anr)
        return self_empty ? ALG_STATUS_NONE : ALG_STATUS_IDENTITY
    end
    if self_empty
        return ALG_STATUS_NONE
    end
    self_node = as_tagged(focus_anr)
    result = psubtract_dyn(self_node, as_tagged(src_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        ALG_STATUS_IDENTITY   # subtract is non-commutative → only SELF_IDENT possible
    else
        _wz_graft_internal!(z, nothing)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_restrict! — prestrict self to src's domain
# =====================================================================
#
# Mirrors WriteZipperCore::restrict (write_zipper.rs:1900).

"""
    wz_restrict!(z, src_anr) -> AlgebraicStatus

Restrict self's subtrie to paths present in `src_anr`.
"""
function wz_restrict!(z::WriteZipperCore{V,A}, src_anr::AbstractNodeRef{V,A}) where {V,A}
    if is_none(src_anr)
        _wz_graft_internal!(z, nothing)
        return ALG_STATUS_NONE
    end
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr)
        return ALG_STATUS_NONE
    end
    self_node = as_tagged(focus_anr)
    result = prestrict_dyn(self_node, as_tagged(src_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        ALG_STATUS_IDENTITY   # restrict is non-commutative → only SELF_IDENT possible
    else
        _wz_graft_internal!(z, nothing)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# Exports
# =====================================================================

# =====================================================================
# ZipperMoving — navigation trait methods
# =====================================================================
#
# Ports WriteZipperCore ZipperMoving impl (write_zipper.rs:976-1075)
# and the ZipperMoving default methods in zipper.rs:232-420.
# All rely on _wz_node_key, wz_descend_to!, wz_ascend!, wz_child_mask.

"""
    wz_at_root(z) → Bool

True iff the zipper is at its origin root (path length == origin_path_len).
Mirrors `ZipperMoving::at_root`.
"""
@inline wz_at_root(z::WriteZipperCore) = length(z.prefix_buf) <= z.origin_path_len

"""
    wz_reset!(z) → nothing

Reset the zipper to its origin root.
Mirrors `WriteZipperCore::reset` (write_zipper.rs:982).
"""
function wz_reset!(z::WriteZipperCore{V,A}) where {V,A}
    # Pop back to root frame
    while length(z.focus_stack) > 1
        pop!(z.focus_stack)
    end
    resize!(z.prefix_buf, z.origin_path_len)
    empty!(z.prefix_idx)
    nothing
end

"""
    wz_child_mask(z) → ByteMask

Returns a `ByteMask` of which byte-branches exist at the cursor position.
Mirrors `WriteZipperCore::child_mask` (write_zipper.rs:922).
"""
function wz_child_mask(z::WriteZipperCore{V,A}) where {V,A}
    isempty(z.focus_stack) && return ByteMask()
    focus_node = z.focus_stack[end].node
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        return node_branches_mask(focus_node, UInt8[])
    end
    result = node_get_child(focus_node, nk)
    if result !== nothing
        consumed, child_rc = result
        child_node = as_tagged(child_rc)
        if length(nk) >= consumed
            return node_branches_mask(child_node, nk[consumed+1:end])
        else
            return ByteMask()
        end
    end
    node_branches_mask(focus_node, nk)
end

"""
    wz_child_count(z) → Int

Returns the number of byte-branches at the cursor position.
Mirrors `WriteZipperCore::child_count` (write_zipper.rs:914).
"""
function wz_child_count(z::WriteZipperCore{V,A}) where {V,A}
    isempty(z.focus_stack) && return 0
    focus_node = z.focus_stack[end].node
    nk = collect(_wz_node_key(z))
    count_branches(focus_node, nk)
end

"""
    wz_val_count(z) → Int

Returns the number of values in the subtrie rooted at the cursor.
Mirrors `WriteZipperCore::val_count` (write_zipper.rs:997).
"""
function wz_val_count(z::WriteZipperCore{V,A}) where {V,A}
    root_val = wz_is_val(z) ? 1 : 0
    focus_anr = _wz_get_focus_anr(z)
    is_none(focus_anr) && return root_val
    val_count_below_root(as_tagged(focus_anr)) + root_val
end

"""
    wz_descend_to_byte!(z, k::UInt8) → nothing

Descend the cursor one byte into child `k`.
Default impl: descend_to([k]).  Mirrors ZipperMoving::descend_to_byte.
"""
@inline function wz_descend_to_byte!(z::WriteZipperCore, k::UInt8)
    wz_descend_to!(z, UInt8[k])
end

"""
    wz_descend_indexed_byte!(z, idx::Int) → Bool

Descend to the `idx`-th child (0-based) in byte order.
Returns `false` if `idx >= child_count`.
Mirrors ZipperMoving::descend_indexed_byte (zipper.rs:256).
"""
function wz_descend_indexed_byte!(z::WriteZipperCore, idx::Int)
    mask = wz_child_mask(z)
    child_byte = indexed_bit(mask, idx, true)
    child_byte === nothing && return false
    wz_descend_to_byte!(z, child_byte)
    true
end

"""
    wz_descend_first_byte!(z) → Bool

Descend to the first (lexicographically smallest) child.
Mirrors ZipperMoving::descend_first_byte (zipper.rs:279).
"""
@inline wz_descend_first_byte!(z::WriteZipperCore) = wz_descend_indexed_byte!(z, 0)

"""
    wz_ascend_byte!(z) → Bool

Ascend exactly one byte.  Returns `false` if already at root.
Mirrors ZipperMoving::ascend_byte (zipper.rs:340).
"""
@inline wz_ascend_byte!(z::WriteZipperCore) = wz_ascend!(z, 1)

"""
    wz_to_next_sibling_byte!(z) → Bool

Move to the next sibling byte at the same depth.
Returns `false` if already the last sibling.
Mirrors ZipperMoving::to_next_sibling_byte (zipper.rs:364).
"""
function wz_to_next_sibling_byte!(z::WriteZipperCore)
    cur_path = wz_path(z)
    isempty(cur_path) && return false
    cur_byte = last(cur_path)
    !wz_ascend_byte!(z) && return false
    mask = wz_child_mask(z)
    next = next_bit(mask, cur_byte)
    if next !== nothing
        wz_descend_to_byte!(z, next)
        return true
    else
        wz_descend_to_byte!(z, cur_byte)
        return false
    end
end

"""
    wz_to_prev_sibling_byte!(z) → Bool

Move to the previous sibling byte at the same depth.
Returns `false` if already the first sibling.
Mirrors ZipperMoving::to_prev_sibling_byte (zipper.rs:395).
"""
function wz_to_prev_sibling_byte!(z::WriteZipperCore)
    cur_path = wz_path(z)
    isempty(cur_path) && return false
    cur_byte = last(cur_path)
    !wz_ascend_byte!(z) && return false
    mask = wz_child_mask(z)
    prev = prev_bit(mask, cur_byte)
    if prev !== nothing
        wz_descend_to_byte!(z, prev)
        return true
    else
        wz_descend_to_byte!(z, cur_byte)
        return false
    end
end

"""
    wz_take_focus!(z, prune=false) → Union{Nothing, TrieNodeODRc}

Remove and return the subtrie at the cursor.
If `prune`, empty ancestor paths are pruned.
Mirrors `WriteZipperCore::take_focus` (write_zipper.rs:2057).
"""
function wz_take_focus!(z::WriteZipperCore{V,A}, prune::Bool=false) where {V,A}
    focus_anr = _wz_get_focus_anr(z)
    is_none(focus_anr) && return nothing
    rc = into_option(focus_anr)
    rc === nothing && return nothing
    _wz_graft_internal!(z, nothing)
    rc
end

"""
    wz_take_map!(z, prune=false) → Union{Nothing, PathMap}

Remove and return a PathMap snapshot at the cursor.
Mirrors `WriteZipperCore::take_map` (write_zipper.rs:1973).
"""
function wz_take_map!(z::WriteZipperCore{V,A}, prune::Bool=false) where {V,A}
    root_node = wz_take_focus!(z, prune)
    root_node === nothing ? nothing : PathMap{V,A}(z.alloc, root_node, nothing)
end

# =====================================================================
# Exports
# =====================================================================

export WriteZipperCore, WriteZipperUntracked
export _wz_at_root, _wz_node_key, _wz_node_key_start
export wz_set_val!, wz_remove_val!
export wz_descend_to!, wz_ascend!
export wz_path_exists, wz_is_val, wz_get_val, wz_path
export write_zipper, write_zipper_at_path
export set_val_at!, remove_val_at!
export _wz_get_focus_anr, _wz_graft_internal!, _wz_remove_branches!
export wz_graft!, wz_graft_map!
export wz_join_into!, wz_join_map_into!
export wz_meet_into!, wz_subtract_into!, wz_restrict!
export wz_at_root, wz_reset!
export wz_child_mask, wz_child_count, wz_val_count
export wz_descend_to_byte!, wz_descend_indexed_byte!
export wz_descend_first_byte!, wz_ascend_byte!
export wz_to_next_sibling_byte!, wz_to_prev_sibling_byte!
export wz_take_focus!, wz_take_map!
export tr_get_focus_anr
