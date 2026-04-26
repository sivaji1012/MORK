# MORK — Julia port of trueagi-io/MORK
# PathMap substrate lives in the PathMap package (sivaji1012/PathMap.git).
# Upstream references:
#   - pathmap: ~/JuliaAGI/dev-zone/PathMap
#   - MORK:    ~/JuliaAGI/dev-zone/MORK (branches: main, origin/server)
module MORK

using Base64
using HTTP: HTTP
using JSON3
using PathMap

# ── Phase 2: Expression layer (mork/expr/) ────────────────────────────────────

# Core expression types: byte encoding, ExprZipper, ExprEnv.
# Ports mork/expr/src/lib.rs.
include("expr/Expr.jl")

# Expression algorithms: traverseh, ee_args!, unify, apply.
# Ports the algorithmic half of mork/expr/src/lib.rs.
include("expr/ExprAlg.jl")

# ── Phase 3: Interning, frontend, kernel ──────────────────────────────────────

# Symbol interning. Ports mork/interning/src/lib.rs.
include("interning/Interning.jl")

# Frontend parsers: MeTTa sexpr + JSON. Ports mork/frontend/src/.
include("frontend/ImmutableString.jl")
include("frontend/Frontend.jl")
include("frontend/HEParser.jl")
include("frontend/RosettaParser.jl")
include("frontend/CZ2Parser.jl")
include("frontend/CZ3Parser.jl")

# Kernel: query source abstraction (BTM/ACT/Z3/CmpSource).
# Ports mork/kernel/src/sources.rs.
include("kernel/Prefix.jl")
include("kernel/Sources.jl")

# Kernel: pure numeric primitives. Ports mork/kernel/src/pure.rs.
include("kernel/Pure.jl")

# Kernel: write sinks. Ports mork/kernel/src/sinks.rs.
include("kernel/Sinks.jl")

# Kernel: Space + query engine. Ports mork/kernel/src/space.rs.
include("kernel/Space.jl")

# Kernel: top-level entry points. Ports mork/kernel/src/main.rs.
include("kernel/Main.jl")

# ── Server layer (mork/server/) ────────────────────────────────────────────────

# ServerSpace + StatusMap — path-level permission tracking.
# Ports mork/server/src/server_space.rs + status_map.rs.
include("server/ResourceStore.jl")
include("server/ServerSpace.jl")

# Command handlers (count, explore, import, export, transform, upload, ...).
# Ports mork/server/src/commands.rs.
include("server/Commands.jl")

# HTTP server entry point.
# Ports mork/server/src/main.rs.
include("server/Server.jl")

# ── MorkL VM (experiments/morkl_interpreter/) ─────────────────────────────────

# Register-based VM for relational trie algebra.
# Ports experiments/morkl_interpreter/src/{lib.rs,cf_iter.rs} (server branch).
include("morkl/MorkL.jl")

# ── DyckZipper (experiments/expr/dyck/) ──────────────────────────────────────

# Compact bit-packed binary tree representation using Dyck words.
# Ports experiments/expr/dyck/{dyck_zipper.rs,left_branch_impl.rs,lib.rs} (server branch).
include("expr/DyckZipper.jl")

# Extend PathMap's ez_reset! for ExprZipper so both share a single function object.
# Mirrors ExprZipper::reset in upstream Rust.
import PathMap: ez_reset!
ez_reset!(z::ExprZipper) = (z.loc = 1; z)
export ez_reset!

"""
    version() -> VersionNumber
"""
version() = v"0.1.0"

export version
export HTTP

# PrecompileTools workload — caches hot method instances during Pkg.precompile().
include("precompile.jl")

end # module MORK
