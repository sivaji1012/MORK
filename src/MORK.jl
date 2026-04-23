"""
    MORK

Julia port of trueagi-io/MORK + adam-Vandervorst/pathMap.

**Status: Phase 1 — porting pathmap crate module by module, 1:1
with upstream.**

Upstream references:
  - pathmap source: `~/JuliaAGI/dev-zone/PathMap`
  - MORK source:    `~/JuliaAGI/dev-zone/MORK` (branches: `main`, `origin/server`)
  - Planning doc:   `docs/architecture/MORK_PACKAGE_PLAN.md`
  - Upstream notes: `docs/architecture/MORK_UPSTREAM_NOTES.md`

Design discipline (committed memories):
  - `feedback_one_to_one_port_discipline.md` — READ UPSTREAM FIRST
  - `feedback_no_vector_metagraph_first.md`
  - `project_mork_package_architecture.md`
  - `project_pathmap_spec_reference.md`
"""
module MORK

# Allocator shim (`Allocator` + `GlobalAlloc`). Ports pathmap/src/alloc.rs.
include("Alloc.jl")

# Core algebraic machinery (used by everything downstream).
# Ports pathmap/src/ring.rs.
include("Ring.jl")

# 256-bit BitMask surface + ByteMask type + ByteMaskIter.
# Ports pathmap/src/utils/mod.rs.
include("utils/Utils.jl")

# Integer encoding utilities (BOB + weave). Range generators deferred
# until PathMap lands (see Ints.jl header). Ports pathmap/src/utils/ints.rs.
include("utils/Ints.jl")

# TrieNode abstract interface, TrieNodeODRc, PayloadRef, ValOrChild,
# AbstractNodeRef. Ports pathmap/src/trie_node.rs (interface layer).
# Concrete node types land in nodes/*.jl (Phase 1b).
include("nodes/TrieNode.jl")

# Zero-field singleton for empty trie positions.
# Ports pathmap/src/empty_node.rs.
include("nodes/EmptyNode.jl")

# Compact 2-slot trie node. Ports pathmap/src/line_list_node.rs.
# NOTE: lattice ops that cross-dispatch to DenseByteNode/TinyRefNode are
# stubbed with error() until those node types are ported.
include("nodes/LineListNode.jl")

# Read-only 1-entry borrowed view into another node (≤7-byte key).
# Ports pathmap/src/tiny_node.rs.
include("nodes/TinyRefNode.jl")

# 256-slot bitmap-indexed node (DenseByteNode + CellByteNode + CoFreeEntry).
# Ports pathmap/src/dense_byte_node.rs.
include("nodes/DenseByteNode.jl")

# Read zipper (cursor) + PathMap container.
# Ports pathmap/src/zipper.rs (read-only surface) + pathmap/src/trie_map.rs.
include("Zipper.jl")

# Write zipper (mutable cursor) — set_val!, remove_val!, navigation.
# Ports pathmap/src/write_zipper.rs (write surface).  Phase 1c.
include("WriteZipper.jl")

# Lightweight read-only reference to a trie location (TrieRefBorrowed/Owned/TrieRef).
# Ports pathmap/src/trie_ref.rs.
include("TrieRef.jl")

# Zipper path tracking for exclusive-access enforcement.
# Ports pathmap/src/zipper_tracking.rs.
include("ZipperTracking.jl")

# ZipperHead — coordinates multiple zippers into one PathMap.
# Ports pathmap/src/zipper_head.rs.
include("ZipperHead.jl")

# OverlayZipper — virtual union of two source tries.
# Ports pathmap/src/overlay_zipper.rs.
include("OverlayZipper.jl")

# PrefixZipper — prepends a prefix to a source zipper's path space.
# Ports pathmap/src/prefix_zipper.rs.
include("PrefixZipper.jl")

# Further includes land per phase — see MORK_PACKAGE_PLAN.md.

"""
    version() -> VersionNumber
"""
version() = v"0.1.0"

export version

end # module MORK
