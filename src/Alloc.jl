"""
Alloc — port of `pathmap/src/alloc.rs`.

Upstream shims `std::alloc::Allocator` on nightly and degenerates to an
empty trait + unit type on stable. Julia has no allocator protocol
(GC-managed), so this module provides the same shape as a phantom:

  - `Allocator` — abstract type playing the role of `pub trait Allocator`
  - `GlobalAlloc` — the default unit type
  - `global_alloc()` — returns the default instance

Downstream code that carries `A<:Allocator` parameters for API fidelity
can default to `GlobalAlloc`. Custom allocators (bump, arena) can be
introduced later as concrete subtypes.
"""

"""
    Allocator

Abstract supertype for allocator strategies. On upstream's stable build
this is a marker trait with no methods; same shape here.
"""
abstract type Allocator end

"""
    GlobalAlloc <: Allocator

The default allocator (upstream's `std::alloc::Global` on nightly, `()`
on stable). Julia's GC runs the show; this is a phantom.
"""
struct GlobalAlloc <: Allocator end

"""
    global_alloc() -> GlobalAlloc

Instantiates `GlobalAlloc`. Mirrors upstream's `pub const fn global_alloc()`.
"""
global_alloc() = GlobalAlloc()

export Allocator, GlobalAlloc, global_alloc
