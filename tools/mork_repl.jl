#!/usr/bin/env julia
# tools/mork_repl.jl — pre-load MORK into a Julia interactive session
#
# Usage (full REPL with history + tab-complete):
#   julia --project=. -i tools/mork_repl.jl
#
# The -i flag drops you into Julia's built-in REPL after this script runs.
# You get: tab completion, up-arrow history, ?help, @edit, multi-line input.
#
# Convenience helpers available at the prompt:
#   mc(src)          — create space, load s-exprs, run metta_calculus, dump
#   t()              — run full test suite
#   t(path)          — run a specific test file

using MORK

mc(src, n=999_999) = begin
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, n)
    space_dump_all_sexpr(s)
end

t(path=joinpath(@__DIR__, "..", "test", "runtests.jl")) = include(path)

println("MORK v", MORK.version(), " loaded.")
println("  mc(src)   — eval s-expr string through metta_calculus")
println("  t()       — run test suite   t(path) — run file")
println("  Ctrl-D    — quit")
