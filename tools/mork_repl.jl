#!/usr/bin/env julia
# tools/mork_repl.jl — pre-load MORK, then execute commands from stdin or interactively
#
# Interactive (full REPL with history + tab-complete):
#   julia --project=. -i tools/mork_repl.jl
#
# Scripted (agent/CI — pipe one expression per line):
#   echo 'include("/tmp/test.jl")' | julia --project=. tools/mork_repl.jl
#
# Exit codes: 0 = all lines OK, 1 = any line errored.

using MORK

mc(src, n=999_999) = (s=new_space(); space_add_all_sexpr!(s,src); space_metta_calculus!(s,n); space_dump_all_sexpr(s))
t(path=joinpath(@__DIR__,"..","test","runtests.jl")) = include(path)

if isinteractive()
    println("MORK v", MORK.version(), " loaded.  mc(src) | t() | Ctrl-D to quit")
else
    local failed = false
    for line in eachline(stdin)
        isempty(strip(line)) && continue
        try
            result = eval(Meta.parse(line))
            result !== nothing && println(result)
        catch e
            println("ERROR: ", e)
            failed = true
        end
    end
    exit(failed ? 1 : 0)
end
