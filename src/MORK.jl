"""
    MORK

Julia port of trueagi-io/MORK + adam-Vandervorst/pathMap.

Source layout mirrors upstream crate structure:

  src/core/      — Alloc.jl, Ring.jl          (pathmap/src/{alloc,ring}.rs)
  src/utils/     — Utils.jl, Ints.jl           (pathmap/src/utils/)
  src/nodes/     — TrieNode, EmptyNode, ...     (pathmap/src/*node*.rs)
  src/zipper/    — Zipper, WriteZipper, ...     (pathmap/src/zipper*.rs + extras)
  src/pathmap/   — Morphisms, Arena, Paths, ... (pathmap/src/{morphisms,arena,paths,counters}.rs)
  src/expr/      — Expr.jl, ExprAlg.jl          (mork/expr/src/lib.rs)
  src/interning/ — Interning.jl                 (mork/interning/src/)
  src/frontend/  — Frontend.jl                  (mork/frontend/src/)
  src/kernel/    — Space.jl                     (mork/kernel/src/space.rs)

Upstream references:
  - pathmap source: `~/JuliaAGI/dev-zone/PathMap`
  - MORK source:    `~/JuliaAGI/dev-zone/MORK` (branches: `main`, `origin/server`)
  - Planning doc:   `docs/architecture/MORK_PACKAGE_PLAN.md`
  - Upstream notes: `docs/architecture/MORK_UPSTREAM_NOTES.md`
"""
module MORK

# ── Core algebraic primitives ─────────────────────────────────────────────────

# Allocator shim (`Allocator` + `GlobalAlloc`). Ports pathmap/src/alloc.rs.
include("core/Alloc.jl")

# Core algebraic machinery (used by everything downstream).
# Ports pathmap/src/ring.rs.
include("core/Ring.jl")

# ── Utility types ─────────────────────────────────────────────────────────────

# 256-bit BitMask surface + ByteMask type + ByteMaskIter.
# Ports pathmap/src/utils/mod.rs.
include("utils/Utils.jl")

# Integer encoding utilities (BOB + weave).
# Ports pathmap/src/utils/ints.rs.
include("utils/Ints.jl")

# ── Trie node types ───────────────────────────────────────────────────────────

# TrieNode abstract interface, TrieNodeODRc, PayloadRef, ValOrChild.
# Ports pathmap/src/trie_node.rs.
include("nodes/TrieNode.jl")

# Zero-field singleton for empty trie positions. Ports pathmap/src/empty_node.rs.
include("nodes/EmptyNode.jl")

# Compact 2-slot trie node. Ports pathmap/src/line_list_node.rs.
include("nodes/LineListNode.jl")

# Read-only 1-entry borrowed view (≤7-byte key). Ports pathmap/src/tiny_node.rs.
include("nodes/TinyRefNode.jl")

# 256-slot bitmap-indexed node. Ports pathmap/src/dense_byte_node.rs.
include("nodes/DenseByteNode.jl")
include("nodes/BridgeNode.jl")

# ── Zipper / cursor layer ─────────────────────────────────────────────────────

# Read zipper + PathMap container.
# Ports pathmap/src/zipper.rs + pathmap/src/trie_map.rs.
include("zipper/Zipper.jl")

# Write zipper — mutable cursor with set_val!, remove_val!, navigation.
# Ports pathmap/src/write_zipper.rs.
include("zipper/WriteZipper.jl")

# Lightweight read-only trie reference (TrieRefBorrowed/Owned/TrieRef).
# Ports pathmap/src/trie_ref.rs.
include("zipper/TrieRef.jl")

# Zipper path tracking for exclusive-access enforcement.
# Ports pathmap/src/zipper_tracking.rs.
include("zipper/ZipperTracking.jl")

# ZipperHead — coordinates multiple zippers into one PathMap.
# Ports pathmap/src/zipper_head.rs.
include("zipper/ZipperHead.jl")

# OverlayZipper — virtual union of two source tries.
# Ports pathmap/src/overlay_zipper.rs.
include("zipper/OverlayZipper.jl")

# PrefixZipper — prepends a fixed prefix to a source zipper's path space.
# Ports pathmap/src/prefix_zipper.rs.
include("zipper/PrefixZipper.jl")

# ProductZipper — Cartesian-product virtual trie over N factor zippers.
# Ports pathmap/src/product_zipper.rs.
include("zipper/ProductZipper.jl")

# EmptyZipper — zipper over an empty trie (always-absent view).
# Ports pathmap/src/empty_zipper.rs.
include("zipper/EmptyZipper.jl")

# DependentZipper — product zipper with on-the-fly factor generation.
# Ports pathmap/src/dependent_zipper.rs.
include("zipper/DependentZipper.jl")

# ── PathMap algorithmic layer ─────────────────────────────────────────────────

# Morphisms — catamorphism/anamorphism fold machinery over tries.
# Ports pathmap/src/morphisms.rs.
include("pathmap/Morphisms.jl")

# ArenaCompact — compact binary trie file format + ACTZipper.
# Ports pathmap/src/arena_compact.rs.
include("pathmap/ArenaCompact.jl")

# PathsSerialization — .paths zlib-compressed trie serialization.
# Ports pathmap/src/paths_serialization.rs.
include("pathmap/PathsSerialization.jl")

# Counters — trie structural statistics and diagnostic histograms.
# Ports pathmap/src/counters.rs.
include("pathmap/Counters.jl")

# ── Phase 2: Expression layer (mork_expr crate) ───────────────────────────────

# Core expression types: byte encoding, ExprZipper, ExprEnv, OwnedSourceItem.
# Ports mork/expr/src/lib.rs.
include("expr/Expr.jl")

# Expression algorithms: traverseh, ee_args!, unify, apply.
# Ports the algorithmic half of mork/expr/src/lib.rs.
include("expr/ExprAlg.jl")

# ── Phase 3: Interning, frontend, kernel ──────────────────────────────────────

# Symbol interning: 128-bucket PathMap-backed symbol table.
# Ports mork/interning/src/lib.rs + handle.rs + symbol_backing.rs.
include("interning/Interning.jl")

# Frontend parsers: MeTTa sexpr + JSON → ExprZipper.
# Ports mork/frontend/src/bytestring_parser.rs + json_parser.rs.
include("frontend/Frontend.jl")

# Kernel: query source abstraction (BTM/ACT/Z3/CmpSource).
# Ports mork/kernel/src/sources.rs.
include("kernel/Sources.jl")

# Kernel: Space struct + pattern-matching query engine.
# Ports mork/kernel/src/space.rs (core subset; Z3/mmap/coroutine paths stubbed).
include("kernel/Space.jl")

# Further includes land per phase — see MORK_PACKAGE_PLAN.md.

"""
    version() -> VersionNumber
"""
version() = v"0.1.0"

export version

end # module MORK
