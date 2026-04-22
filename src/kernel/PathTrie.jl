"""
PathTrie{V} — arena-based parameterized trie with structural-sharing-ready
layout. Phase 1a of ADR-052/MORK_PACKAGE_PLAN Phase 1.

**Reference spec:** https://pathmap-rs.github.io/ and
`project_pathmap_spec_reference.md` memory.

**Design principles:**
  - Arena = `Vector{TrieNode{V}}`. Index 1 = root. Index 0 = null/absent.
  - Children are `UInt32` indices INTO the arena. This makes structural
    sharing possible (two parents can point to the same child index),
    though copy-on-write is deferred to Phase 1d when graft/take_map
    first exercises shared references.
  - Nodes hold an optional value (`Union{V, Nothing}`). `nothing`
    indicates a dangling path (exists structurally, has no value).
  - Sparse child representation via `Dict{UInt8, UInt32}`. Phase 1a
    prioritizes correctness + simplicity; a sorted-pairs or bitmask
    representation can come later if profiling justifies it.
  - Thread safety via `ReentrantLock`. Upstream uses `RwLock`; Julia's
    lock is coarser but sufficient for single-writer scenarios.

**Phase 1a scope (this commit):**
  - `PathTrie{V}` + `TrieNode{V}` structs
  - Base collection API: `trie[path]`, `haskey`, `get`, `delete!`, `length`
  - Path ops: `create_path!`, `prune_path!`, `path_exists_at`
  - `ReadZipper{V}` + `WriteZipper{V}` with stack-based parent tracking
  - Zipper API (upstream-literal): `focus`, `path`, `origin_path`,
    `at_root`, `is_val`, `val`, `set_val!`, `remove_val!`,
    `descend_to`, `descend_to_byte!`, `ascend!`, `reset!`,
    `child_count`, `child_mask`

**Deferred to later sub-phases:**
  - 1b: full movement API (descend_until, ascend_until, sibling nav)
  - 1c: iteration (to_next_val, to_next_step, k-path)
  - 1d: subtrie ops (graft, take_map, insert_prefix) + structural-sharing
        copy-on-write
  - 1e: lattice algebra (join, meet, subtract, restrict)
  - 1f: ZipperHead exclusivity + ProductZipper
  - 1g: serialization
  - 1h: Space integration + utilities (ByteMask, Conflict, Counters)
"""

# ============================================================================
# Node + Trie structs
# ============================================================================

"""
    TrieNode{V}

Single trie node. `value === nothing` means a dangling path (exists
structurally, no stored value).
"""
mutable struct TrieNode{V}
    value::Union{V, Nothing}
    children::Dict{UInt8, UInt32}
end

TrieNode{V}() where {V} = TrieNode{V}(nothing, Dict{UInt8, UInt32}())

function Base.show(io::IO, n::TrieNode{V}) where {V}
    print(io, "TrieNode{", V, "}(value=", n.value === nothing ? "-" : n.value,
          ", #children=", length(n.children), ")")
end

"""
    PathTrie{V}

Arena-backed parameterized trie. Default `V = Nothing` matches upstream
MORK's `PathMap<()>` for pure path-presence storage (the atom store).

Arena slot 1 is the root; slot 0 is reserved as the null/absent sentinel.
"""
mutable struct PathTrie{V}
    arena::Vector{TrieNode{V}}
    lock::ReentrantLock
end

function PathTrie{V}() where {V}
    arena = TrieNode{V}[TrieNode{V}()]   # root at index 1
    return PathTrie{V}(arena, ReentrantLock())
end

PathTrie() = PathTrie{Nothing}()

function Base.show(io::IO, t::PathTrie{V}) where {V}
    print(io, "PathTrie{", V, "}(#nodes=", length(t.arena) - 0, ")")
end

# Internal: walk from root down path. Returns the target node index,
# or UInt32(0) if the path is not present.
function _walk_to(trie::PathTrie, path::AbstractVector{UInt8})::UInt32
    node_idx = UInt32(1)
    @inbounds for b in path
        node = trie.arena[node_idx]
        child_idx = get(node.children, b, UInt32(0))
        child_idx == UInt32(0) && return UInt32(0)
        node_idx = child_idx
    end
    return node_idx
end

# Internal: walk from root, creating missing nodes. Returns target index.
# Caller must hold the lock.
function _walk_or_create!(trie::PathTrie{V}, path::AbstractVector{UInt8})::UInt32 where {V}
    node_idx = UInt32(1)
    @inbounds for b in path
        node = trie.arena[node_idx]
        child_idx = get(node.children, b, UInt32(0))
        if child_idx == UInt32(0)
            push!(trie.arena, TrieNode{V}())
            child_idx = UInt32(length(trie.arena))
            node.children[b] = child_idx
        end
        node_idx = child_idx
    end
    return node_idx
end

# ============================================================================
# Base collection API — PathTrie as a HashMap<Vector{UInt8}, V>
# ============================================================================

"""
    setindex!(trie::PathTrie{V}, value::V, path::AbstractVector{UInt8})

Set the value stored at `path`. Creates any missing nodes. If `path`
already has a value it is overwritten.
"""
function Base.setindex!(trie::PathTrie{V}, value::V, path::AbstractVector{UInt8}) where {V}
    lock(trie.lock) do
        node_idx = _walk_or_create!(trie, path)
        trie.arena[node_idx].value = value
    end
    return value
end

"""
    getindex(trie::PathTrie{V}, path::AbstractVector{UInt8}) -> V

Return the value at `path`. Throws `KeyError` if the path is absent or
dangling.
"""
function Base.getindex(trie::PathTrie{V}, path::AbstractVector{UInt8}) where {V}
    node_idx = _walk_to(trie, path)
    node_idx == UInt32(0) && throw(KeyError(path))
    val = trie.arena[node_idx].value
    val === nothing && throw(KeyError(path))
    return val::V
end

"""
    get(trie::PathTrie{V}, path::AbstractVector{UInt8}, default) -> V or default

Return the value at `path`, or `default` if absent or dangling.
"""
function Base.get(trie::PathTrie{V}, path::AbstractVector{UInt8}, default) where {V}
    node_idx = _walk_to(trie, path)
    node_idx == UInt32(0) && return default
    val = trie.arena[node_idx].value
    val === nothing && return default
    return val
end

"""
    haskey(trie::PathTrie, path::AbstractVector{UInt8}) -> Bool

Whether `path` has a stored value. Dangling paths return `false` (use
`path_exists_at` to include dangling).
"""
function Base.haskey(trie::PathTrie, path::AbstractVector{UInt8})::Bool
    node_idx = _walk_to(trie, path)
    node_idx == UInt32(0) && return false
    return trie.arena[node_idx].value !== nothing
end

"""
    delete!(trie::PathTrie, path::AbstractVector{UInt8}) -> PathTrie

Remove the value at `path` if present. Does NOT prune dangling structure;
use `prune_path!` if that's required.
"""
function Base.delete!(trie::PathTrie, path::AbstractVector{UInt8})
    lock(trie.lock) do
        node_idx = _walk_to(trie, path)
        node_idx != UInt32(0) && (trie.arena[node_idx].value = nothing)
    end
    return trie
end

"""
    length(trie::PathTrie) -> Int

Number of stored values (paths with non-`nothing` values). Dangling paths
not counted. O(arena size).
"""
function Base.length(trie::PathTrie)::Int
    cnt = 0
    @inbounds for i in eachindex(trie.arena)
        trie.arena[i].value !== nothing && (cnt += 1)
    end
    return cnt
end

"""
    isempty(trie::PathTrie) -> Bool
"""
Base.isempty(trie::PathTrie)::Bool = length(trie) == 0

# ============================================================================
# Path operations — upstream API
# ============================================================================

"""
    path_exists_at(trie::PathTrie, path::AbstractVector{UInt8}) -> Bool

Whether `path` exists in the trie — including dangling paths (no value).
Port of upstream `PathMap::path_exists_at`.
"""
path_exists_at(trie::PathTrie, path::AbstractVector{UInt8})::Bool =
    _walk_to(trie, path) != UInt32(0)

"""
    create_path!(trie::PathTrie, path::AbstractVector{UInt8}) -> PathTrie

Ensure `path` exists in the trie without storing a value (dangling path).
If `path` already has a value, the value is preserved. Port of upstream
`PathMap::create_path`.
"""
function create_path!(trie::PathTrie, path::AbstractVector{UInt8})
    lock(trie.lock) do
        _walk_or_create!(trie, path)
    end
    return trie
end

"""
    prune_path!(trie::PathTrie, path::AbstractVector{UInt8}) -> PathTrie

Remove dangling path segments above `path` (walking back toward the
root). A segment is dangling iff it has no value AND no children other
than the one we came from. Stops as soon as a segment is not dangling.

Port of upstream `ZipperWriting::prune_path`. Operates at the PathMap
level here; zipper-scoped version is also useful and will be added in 1b.
"""
function prune_path!(trie::PathTrie, path::AbstractVector{UInt8})
    isempty(path) && return trie
    lock(trie.lock) do
        # Walk, recording the chain of (parent_idx, byte_taken).
        parents = Tuple{UInt32, UInt8}[]
        node_idx = UInt32(1)
        @inbounds for b in path
            node = trie.arena[node_idx]
            child_idx = get(node.children, b, UInt32(0))
            child_idx == UInt32(0) && return trie
            push!(parents, (node_idx, b))
            node_idx = child_idx
        end
        # Walk back. If the current node is dangling, unlink from parent.
        for (parent_idx, byte_taken) in reverse(parents)
            node = trie.arena[node_idx]
            (node.value !== nothing || !isempty(node.children)) && break
            parent = trie.arena[parent_idx]
            delete!(parent.children, byte_taken)
            # Note: we leave the old node in the arena. A future `compact!`
            # sub-phase can garbage-collect unreferenced slots.
            node_idx = parent_idx
        end
    end
    return trie
end

# ============================================================================
# Zippers — ReadZipper + WriteZipper
# ============================================================================

"""
    ReadZipper{V}

Read-only cursor over a PathTrie. Tracks focus via a stack of node indices
(so `ascend!` is O(1) without parent pointers). Port of upstream
`ReadZipper` + the `ZipperMoving`/`ZipperAbsolutePath` trait surface.

Phase 1a implements:
  - Base traits: `focus`, `at_root`, `is_val`, `val`, `child_count`, `child_mask`
  - Movement: `descend_to_byte!`, `descend_to!`, `ascend!`, `reset!`
  - Path queries: `path`, `origin_path`

Deferred: `descend_until`, `ascend_until`, sibling nav (1b);
iteration (1c); forking (1d).
"""
mutable struct ReadZipper{V}
    trie::PathTrie{V}
    # stack[1] = zipper origin (typically root), stack[end] = current focus.
    stack::Vector{UInt32}
    # labels[i] = byte taken from stack[i] to stack[i+1]. len(labels) == len(stack) - 1.
    labels::Vector{UInt8}
    # root_prefix_path: bytes from absolute root to this zipper's origin.
    # Empty when zipper is created at the absolute root; non-empty for forked
    # zippers rooted deeper in the trie (Phase 1d).
    root_prefix::Vector{UInt8}
end

ReadZipper(trie::PathTrie{V}) where {V} =
    ReadZipper{V}(trie, UInt32[1], UInt8[], UInt8[])

"""
    WriteZipper{V}

Mutable cursor. Inherits all ReadZipper capabilities + adds `set_val!`,
`remove_val!`, `create_path!`. Port of upstream `WriteZipper` +
`ZipperWriting` trait.

Phase 1a implements: `set_val!`, `remove_val!`, `create_path!` (zipper-scoped),
and all ReadZipper methods dispatch on WriteZipper too.

Deferred: `graft`, `take_map`, `insert_prefix`, `remove_prefix`,
`remove_branches`, `get_val_or_set_mut`, `get_val_or_set_mut_with` (1d).
"""
mutable struct WriteZipper{V}
    trie::PathTrie{V}
    stack::Vector{UInt32}
    labels::Vector{UInt8}
    root_prefix::Vector{UInt8}
end

WriteZipper(trie::PathTrie{V}) where {V} =
    WriteZipper{V}(trie, UInt32[1], UInt8[], UInt8[])

# Both zipper types share the movement/read API. Use a Union for dispatch.
const AnyZipper{V} = Union{ReadZipper{V}, WriteZipper{V}}

# --- Base traits ---

"""
    focus(z) -> UInt32

Current focus node's arena index.
"""
focus(z::AnyZipper)::UInt32 = @inbounds z.stack[end]

"""
    at_root(z) -> Bool

True iff the zipper is at its origin (hasn't descended).
"""
at_root(z::AnyZipper)::Bool = length(z.stack) == 1

"""
    is_val(z) -> Bool

True iff the current focus has a stored value (not dangling).
"""
is_val(z::AnyZipper) = z.trie.arena[focus(z)].value !== nothing

"""
    val(z) -> Union{V, Nothing}

Value at current focus, or `nothing` if dangling.
"""
val(z::AnyZipper{V}) where {V} = z.trie.arena[focus(z)].value

"""
    child_count(z) -> Int

Number of children branching from the current focus.
"""
child_count(z::AnyZipper)::Int = length(z.trie.arena[focus(z)].children)

"""
    child_mask(z) -> BitVector

256-bit mask: bit `b+1` is true iff child byte `b` exists from focus.
Port of upstream `Zipper::child_mask`.
"""
function child_mask(z::AnyZipper)::BitVector
    mask = falses(256)
    @inbounds for b in keys(z.trie.arena[focus(z)].children)
        mask[Int(b) + 1] = true
    end
    return mask
end

# --- Path queries ---

"""
    path(z) -> Vector{UInt8}

Path from zipper origin to current focus (relative). Port of upstream
`ZipperMoving::path`.
"""
path(z::AnyZipper) = copy(z.labels)

"""
    origin_path(z) -> Vector{UInt8}

Full path from absolute trie root to current focus. Equals
`root_prefix_path ++ path`. Port of upstream `ZipperAbsolutePath::origin_path`.
"""
origin_path(z::AnyZipper) = vcat(z.root_prefix, z.labels)

"""
    root_prefix_path(z) -> Vector{UInt8}

Constant path from absolute root to this zipper's origin. Empty for
root-created zippers; non-empty for forked zippers (Phase 1d).
"""
root_prefix_path(z::AnyZipper) = copy(z.root_prefix)

# --- Movement ---

"""
    descend_to_byte!(z, b::UInt8) -> Bool

Descend to child byte `b`. Returns `true` on success, `false` if no such
child exists (focus unchanged on failure).
"""
function descend_to_byte!(z::AnyZipper, b::UInt8)::Bool
    node = z.trie.arena[focus(z)]
    child_idx = get(node.children, b, UInt32(0))
    child_idx == UInt32(0) && return false
    push!(z.stack, child_idx)
    push!(z.labels, b)
    return true
end

"""
    descend_to!(z, path::AbstractVector{UInt8}) -> Bool

Descend to `path` relative to current focus. Returns `true` iff every
step succeeded. On partial failure, focus is unchanged.
"""
function descend_to!(z::AnyZipper, path::AbstractVector{UInt8})::Bool
    # Walk ahead without mutating, then apply atomically.
    node_idx = focus(z)
    idx_path = UInt32[]
    @inbounds for b in path
        node = z.trie.arena[node_idx]
        child_idx = get(node.children, b, UInt32(0))
        child_idx == UInt32(0) && return false
        push!(idx_path, child_idx)
        node_idx = child_idx
    end
    @inbounds for i in eachindex(path)
        push!(z.stack, idx_path[i])
        push!(z.labels, path[i])
    end
    return true
end

"""
    ascend!(z, n::Int=1)

Ascend `n` steps toward the zipper origin. Clamps at origin (never
ascends past the zipper root).
"""
function ascend!(z::AnyZipper, n::Int=1)
    for _ in 1:n
        length(z.stack) <= 1 && break
        pop!(z.stack)
        pop!(z.labels)
    end
    return z
end

"""
    ascend_byte!(z)

Equivalent to `ascend!(z, 1)`. Matches upstream trait naming.
"""
ascend_byte!(z::AnyZipper) = ascend!(z, 1)

"""
    reset!(z)

Move focus back to zipper origin.
"""
function reset!(z::AnyZipper)
    @inbounds z.stack = UInt32[z.stack[1]]
    empty!(z.labels)
    return z
end

# --- WriteZipper-only mutation ---

"""
    set_val!(z::WriteZipper{V}, v::V) -> Union{V, Nothing}

Store `v` at current focus. Returns the previous value (`nothing` if
the path was dangling or new).
"""
function set_val!(z::WriteZipper{V}, v::V)::Union{V, Nothing} where {V}
    lock(z.trie.lock) do
        node = z.trie.arena[focus(z)]
        old = node.value
        node.value = v
        return old
    end
end

"""
    remove_val!(z::WriteZipper) -> Union{V, Nothing}

Remove the value at current focus (turning it into a dangling path).
Returns the previous value. Does NOT prune; use `prune_path!` separately.
"""
function remove_val!(z::WriteZipper{V})::Union{V, Nothing} where {V}
    lock(z.trie.lock) do
        node = z.trie.arena[focus(z)]
        old = node.value
        node.value = nothing
        return old
    end
end

"""
    create_path!(z::WriteZipper, path::AbstractVector{UInt8}) -> WriteZipper

Ensure `path` exists relative to current focus as a dangling path
(creating nodes as needed). Does not move the focus.
"""
function create_path!(z::WriteZipper, path::AbstractVector{UInt8})
    lock(z.trie.lock) do
        node_idx = focus(z)
        @inbounds for b in path
            node = z.trie.arena[node_idx]
            child_idx = get(node.children, b, UInt32(0))
            if child_idx == UInt32(0)
                push!(z.trie.arena, TrieNode{eltype_V(z.trie)}())
                child_idx = UInt32(length(z.trie.arena))
                node.children[b] = child_idx
            end
            node_idx = child_idx
        end
    end
    return z
end

# Tiny helper — get the V of a PathTrie{V}
@inline eltype_V(::PathTrie{V}) where {V} = V

# ============================================================================
# Exports
# ============================================================================

export PathTrie, TrieNode, ReadZipper, WriteZipper, AnyZipper
export path_exists_at, create_path!, prune_path!
export focus, at_root, is_val, val, child_count, child_mask
export path, origin_path, root_prefix_path
export descend_to_byte!, descend_to!, ascend!, ascend_byte!, reset!
export set_val!, remove_val!
