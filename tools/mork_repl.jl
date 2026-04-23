#!/usr/bin/env julia
# tools/mork_repl.jl — interactive Julia REPL with MORK pre-loaded
#
# Usage:
#   julia --project=. tools/mork_repl.jl
#
# MORK is loaded once. Type Julia expressions at the prompt.
# Commands:
#   :q   quit
#   :t   run test suite

using MORK

println("MORK v", MORK.version(), " loaded. Type Julia or :q to quit.")

mc(src, n=999_999) = begin
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, n)
    space_dump_all_sexpr(s)
end

while true
    print("mork> ")
    line = readline()
    isempty(line) && continue
    line == ":q" && break
    if line == ":t"
        include(joinpath(@__DIR__, "..", "test", "runtests.jl"))
        continue
    end
    try
        suppress = endswith(rstrip(line), ';')
        result = eval(Meta.parse(line))
        !suppress && result !== nothing && println(result)
    catch e
        println("ERROR: ", e)
    end
end
