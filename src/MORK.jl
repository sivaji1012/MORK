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
include("frontend/Frontend.jl")
include("frontend/HEParser.jl")
include("frontend/RosettaParser.jl")
include("frontend/CZ2Parser.jl")
include("frontend/CZ3Parser.jl")

# Kernel: query source abstraction (BTM/ACT/Z3/CmpSource).
# Ports mork/kernel/src/sources.rs.
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
include("server/ServerSpace.jl")

# Command handlers (count, explore, import, export, transform, upload, ...).
# Ports mork/server/src/commands.rs.
include("server/Commands.jl")

# HTTP server entry point.
# Ports mork/server/src/main.rs.
include("server/Server.jl")

"""
    version() -> VersionNumber
"""
version() = v"0.1.0"

export version
export HTTP

end # module MORK
