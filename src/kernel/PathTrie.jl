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
# ByteMask — 256-bit fixed-size mask (port of pathmap::utils::ByteMask)
# ============================================================================

"""
    ByteMask

256-bit mask over UInt8 values. Stack-allocated, zero-allocation.
Port of upstream `pathmap::utils::ByteMask`. Used throughout the
pathmap/MORK API wherever a "which bytes are present" result is needed
(e.g., `child_mask`).

Stored as four `UInt64` words covering bit positions 0-255 in ascending
order (word 0 holds bits for bytes 0-63, word 3 holds bits for bytes 192-255).

Immutable — constructor variants produce new values rather than mutating.
"""
struct ByteMask
    w0::UInt64   # bytes 0..63
    w1::UInt64   # bytes 64..127
    w2::UInt64   # bytes 128..191
    w3::UInt64   # bytes 192..255
end

ByteMask() = ByteMask(UInt64(0), UInt64(0), UInt64(0), UInt64(0))

@inline function _bm_word_bit(b::UInt8)::Tuple{Int, Int}
    # Returns (word_index 0..3, bit_index 0..63)
    i = Int(b)
    return (i >> 6, i & 0x3F)
end

"""
    mask[b::UInt8] -> Bool

Test whether byte `b` is set in the mask.
"""
@inline function Base.getindex(mask::ByteMask, b::UInt8)::Bool
    w, bit = _bm_word_bit(b)
    word = w == 0 ? mask.w0 :
           w == 1 ? mask.w1 :
           w == 2 ? mask.w2 :
                    mask.w3
    return (word >> bit) & UInt64(1) != UInt64(0)
end

"""
    set(mask::ByteMask, b::UInt8) -> ByteMask

Return a new mask with byte `b` set.
"""
function set(mask::ByteMask, b::UInt8)::ByteMask
    w, bit = _bm_word_bit(b)
    one_at = UInt64(1) << bit
    return w == 0 ? ByteMask(mask.w0 | one_at, mask.w1, mask.w2, mask.w3) :
           w == 1 ? ByteMask(mask.w0, mask.w1 | one_at, mask.w2, mask.w3) :
           w == 2 ? ByteMask(mask.w0, mask.w1, mask.w2 | one_at, mask.w3) :
                    ByteMask(mask.w0, mask.w1, mask.w2, mask.w3 | one_at)
end

"""
    unset(mask::ByteMask, b::UInt8) -> ByteMask

Return a new mask with byte `b` cleared.
"""
function unset(mask::ByteMask, b::UInt8)::ByteMask
    w, bit = _bm_word_bit(b)
    clear = ~(UInt64(1) << bit)
    return w == 0 ? ByteMask(mask.w0 & clear, mask.w1, mask.w2, mask.w3) :
           w == 1 ? ByteMask(mask.w0, mask.w1 & clear, mask.w2, mask.w3) :
           w == 2 ? ByteMask(mask.w0, mask.w1, mask.w2 & clear, mask.w3) :
                    ByteMask(mask.w0, mask.w1, mask.w2, mask.w3 & clear)
end

"""
    count(mask::ByteMask) -> Int

Number of bytes set in the mask.
"""
Base.count(mask::ByteMask)::Int =
    count_ones(mask.w0) + count_ones(mask.w1) + count_ones(mask.w2) + count_ones(mask.w3)

"""
    isempty(mask::ByteMask) -> Bool
"""
Base.isempty(mask::ByteMask)::Bool =
    mask.w0 == 0 && mask.w1 == 0 && mask.w2 == 0 && mask.w3 == 0

"""
    iterate(mask::ByteMask)

Iterate over set bytes in ascending order. Produces `UInt8` values.
"""
function Base.iterate(mask::ByteMask, state::Int=0)
    while state < 256
        if mask[UInt8(state)]
            return (UInt8(state), state + 1)
        end
        state += 1
    end
    return nothing
end

Base.eltype(::Type{ByteMask}) = UInt8
Base.IteratorSize(::Type{ByteMask}) = Base.HasLength()
Base.length(mask::ByteMask) = count(mask)

function Base.show(io::IO, mask::ByteMask)
    n = count(mask)
    print(io, "ByteMask(", n, " set")
    if 0 < n <= 8
        vals = [b for b in mask]
        print(io, ": ", join(string.(vals), ", "))
    end
    print(io, ")")
end

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
    child_mask(z) -> ByteMask

256-bit fixed mask of child bytes present at focus. Port of upstream
`Zipper::child_mask` returning `pathmap::utils::ByteMask`. Zero-allocation
(stack-allocated struct, four UInt64 words).
"""
function child_mask(z::AnyZipper)::ByteMask
    mask = ByteMask()
    @inbounds for b in keys(z.trie.arena[focus(z)].children)
        mask = set(mask, b)
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

# ============================================================================
# Phase 1b — full movement API
# ============================================================================
#
# All of upstream's remaining `ZipperMoving` trait methods:
#   - Stepping:  descend_first_byte!, descend_indexed_byte!
#   - Jumping:   descend_to_existing!, descend_to_val!, descend_until!,
#                ascend_until!, ascend_until_branch!
#   - Siblings:  to_next_sibling_byte!, to_prev_sibling_byte!

# --- Small helpers on the focus node ---

@inline _focus_node(z::AnyZipper) = @inbounds z.trie.arena[focus(z)]

# Return child bytes sorted ascending. O(n) scan + O(n log n) sort.
# Phase 1a uses Dict which doesn't preserve order; a future sorted-vector
# or bitmask child representation would make this O(n).
@inline function _sorted_child_bytes(node::TrieNode)::Vector{UInt8}
    bytes = collect(keys(node.children))
    sort!(bytes)
    return bytes
end

# --- Stepping ---

"""
    descend_first_byte!(z) -> Bool

Descend to the smallest-valued child byte. Returns `false` if the focus
has no children (focus unchanged). Port of upstream
`ZipperMoving::descend_first_byte`.
"""
function descend_first_byte!(z::AnyZipper)::Bool
    node = _focus_node(z)
    isempty(node.children) && return false
    # Find minimum byte — O(n) single pass
    min_b = typemax(UInt8)
    @inbounds for b in keys(node.children)
        b < min_b && (min_b = b)
    end
    return descend_to_byte!(z, min_b)
end

"""
    descend_indexed_byte!(z, i::Int) -> Bool

Descend to the i-th child in ascending byte order (1-based — Julia
convention; upstream is 0-based — document divergence). Returns
`false` if `i` is out of range. Port of upstream
`ZipperMoving::descend_indexed_byte`.
"""
function descend_indexed_byte!(z::AnyZipper, i::Int)::Bool
    node = _focus_node(z)
    (i < 1 || i > length(node.children)) && return false
    bytes = _sorted_child_bytes(node)
    return descend_to_byte!(z, bytes[i])
end

# --- Jumping (partial-success variants) ---

"""
    descend_to_existing!(z, path::AbstractVector{UInt8}) -> Int

Walk `path` as far as the trie allows, stopping at the first missing byte.
Returns the number of bytes successfully consumed (0 if the first byte
is absent, `length(path)` on full success). Unlike `descend_to!`, this
commits partial walks. Port of upstream
`ZipperMoving::descend_to_existing`.
"""
function descend_to_existing!(z::AnyZipper, path::AbstractVector{UInt8})::Int
    consumed = 0
    @inbounds for b in path
        node = _focus_node(z)
        child_idx = get(node.children, b, UInt32(0))
        child_idx == UInt32(0) && break
        push!(z.stack, child_idx)
        push!(z.labels, b)
        consumed += 1
    end
    return consumed
end

"""
    descend_to_val!(z, path::AbstractVector{UInt8}) -> Int

Like `descend_to_existing!` but also stops as soon as the focus reaches
a node that has a stored value. Returns bytes consumed. Useful for
walking toward the furthest value-bearing path. Port of upstream
`ZipperMoving::descend_to_val`.
"""
function descend_to_val!(z::AnyZipper, path::AbstractVector{UInt8})::Int
    consumed = 0
    # If the zipper already sits on a value before descending, stop immediately.
    is_val(z) && return 0
    @inbounds for b in path
        node = _focus_node(z)
        child_idx = get(node.children, b, UInt32(0))
        child_idx == UInt32(0) && break
        push!(z.stack, child_idx)
        push!(z.labels, b)
        consumed += 1
        # Stop AT the newly-focused node if it has a value
        is_val(z) && break
    end
    return consumed
end

"""
    descend_until!(z) -> Int

Descend along the single-child chain from the current focus until
reaching a node that either:
  - has a value
  - has multiple children (branch point)
  - has zero children (leaf)

Returns the number of bytes descended (0 if focus already sits at
such a stopping point). Port of upstream `ZipperMoving::descend_until`.

Efficient for skipping past single-child corridors during traversal.
"""
function descend_until!(z::AnyZipper)::Int
    consumed = 0
    while true
        node = _focus_node(z)
        # Stop if focus has a value, 0 children, or > 1 children
        (node.value !== nothing) && break
        n = length(node.children)
        n != 1 && break
        # Exactly one child — descend
        only_byte = first(keys(node.children))
        child_idx = node.children[only_byte]
        push!(z.stack, child_idx)
        push!(z.labels, only_byte)
        consumed += 1
    end
    return consumed
end

"""
    ascend_until!(z) -> Int

Ascend until reaching zipper origin OR a node with multiple children
OR a node with a value. Returns the number of bytes ascended.
Port of upstream `ZipperMoving::ascend_until`.
"""
function ascend_until!(z::AnyZipper)::Int
    consumed = 0
    while !at_root(z)
        # Pop one level, then check if the NEW focus is a stopping point
        pop!(z.stack)
        pop!(z.labels)
        consumed += 1
        node = _focus_node(z)
        (node.value !== nothing) && break
        length(node.children) > 1 && break
    end
    return consumed
end

"""
    ascend_until_branch!(z) -> Int

Ascend until reaching zipper origin OR a node with multiple children.
Unlike `ascend_until!`, does NOT stop at value-bearing nodes — only at
true branch points or origin. Port of upstream
`ZipperMoving::ascend_until_branch`.
"""
function ascend_until_branch!(z::AnyZipper)::Int
    consumed = 0
    while !at_root(z)
        pop!(z.stack)
        pop!(z.labels)
        consumed += 1
        length(_focus_node(z).children) > 1 && break
    end
    return consumed
end

# --- Sibling navigation ---

"""
    to_next_sibling_byte!(z) -> Bool

Move laterally to the next sibling (smallest child byte of the parent
strictly greater than the label that brought us here). Returns `false`
if there is no next sibling (focus unchanged). Port of upstream
`ZipperMoving::to_next_sibling_byte`.

At-root zippers cannot have siblings (no parent), so they always return false.
"""
function to_next_sibling_byte!(z::AnyZipper)::Bool
    at_root(z) && return false
    last_byte = @inbounds z.labels[end]
    parent_idx = @inbounds z.stack[end - 1]
    parent = z.trie.arena[parent_idx]
    # Find smallest byte > last_byte among parent.children
    next_byte = nothing
    next_child = UInt32(0)
    @inbounds for (b, idx) in parent.children
        if b > last_byte && (next_byte === nothing || b < next_byte)
            next_byte = b
            next_child = idx
        end
    end
    next_byte === nothing && return false
    @inbounds z.stack[end] = next_child
    @inbounds z.labels[end] = next_byte
    return true
end

"""
    to_prev_sibling_byte!(z) -> Bool

Move laterally to the previous sibling (largest child byte of the
parent strictly less than the label that brought us here). Returns
`false` if there is no previous sibling. Port of upstream
`ZipperMoving::to_prev_sibling_byte`.
"""
function to_prev_sibling_byte!(z::AnyZipper)::Bool
    at_root(z) && return false
    last_byte = @inbounds z.labels[end]
    parent_idx = @inbounds z.stack[end - 1]
    parent = z.trie.arena[parent_idx]
    prev_byte = nothing
    prev_child = UInt32(0)
    @inbounds for (b, idx) in parent.children
        if b < last_byte && (prev_byte === nothing || b > prev_byte)
            prev_byte = b
            prev_child = idx
        end
    end
    prev_byte === nothing && return false
    @inbounds z.stack[end] = prev_child
    @inbounds z.labels[end] = prev_byte
    return true
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

export ByteMask, set, unset
export PathTrie, TrieNode, ReadZipper, WriteZipper, AnyZipper
export path_exists_at, create_path!, prune_path!
export focus, at_root, is_val, val, child_count, child_mask
export path, origin_path, root_prefix_path
export descend_to_byte!, descend_to!, ascend!, ascend_byte!, reset!
export descend_first_byte!, descend_indexed_byte!
export descend_to_existing!, descend_to_val!
export descend_until!, ascend_until!, ascend_until_branch!
export to_next_sibling_byte!, to_prev_sibling_byte!
export set_val!, remove_val!
