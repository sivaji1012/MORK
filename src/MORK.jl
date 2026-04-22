"""
    MORK

Clean Julia port of trueagi-io/MORK — the high-performance metagraph
substrate for Hyperon/MeTTa systems.

**Status: Phase 0 — skeleton.**
See `docs/architecture/MORK_PACKAGE_PLAN.md` for the phased
implementation roadmap.

**Principles** (committed in memory):
  - Zero PRIMUS dependencies (this package is foundational)
  - Metagraph-first substrate: no Vector-typed atom/byte/tensor storage
    (`feedback_no_vector_metagraph_first.md`)
  - Generic library: no domain hardcoding
    (`project_mork_package_architecture.md`)
  - Practical auxiliary indices: small Dict-based caches allowed for
    hot paths; matches upstream's own `HashMap` usage
  - 1:1 parity port across upstream `main` + `server` branches
    (`project_mork_server_branch_reference.md`)

Each subdirectory in `src/` corresponds to an upstream MORK crate or a
PRIMUS-specific extension:
  - `expr/`         — matches upstream `expr/` crate
  - `frontend/`     — matches upstream `frontend/` crate
  - `kernel/`       — matches upstream `kernel/` crate
  - `server/`       — matches upstream `server/` crate (origin/server branch)
  - `client/`       — Julia port of upstream `python/client.py`
  - `distributed/`  — PRIMUS extension: N-node HPC scaling via Dagger + MPI
  - `runtime/`      — PRIMUS extension: ZipperVM, interpreter, reflection
"""
module MORK

# --- Phase 0: no substantive modules yet ---
#
# Subdirectories exist under src/ as placeholders. Each phase of the plan
# adds its include chain here:
#
#   Phase 1 (kernel):   include("kernel/PathTrie.jl"); include("kernel/Space.jl"); …
#   Phase 2 (expr):     include("expr/Tag.jl"); include("expr/ExprSpan.jl"); …
#   Phase 3 (frontend): include("frontend/SExpr.jl"); …
#   Phase 4 (server):   include("server/Server.jl"); …
#   Phase 5 (distr):    include("distributed/DistributedPathTrie.jl"); …
#   Phase 6 (runtime):  include("runtime/ZipperVM.jl"); …
#
# Landing criterion for Phase 0: `using MORK` succeeds and test suite passes.

"""
    version() -> VersionNumber

MORK package version.
"""
version() = v"0.1.0"

export version

end # module MORK
