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

# Further includes land per phase — see MORK_PACKAGE_PLAN.md.

"""
    version() -> VersionNumber
"""
version() = v"0.1.0"

export version

end # module MORK
