#!/usr/bin/env julia
# examples/backward_chaining.jl — Logic reasoning via backward chaining
#
# Ports the upstream MORK bc0/bc1 integration test patterns into a
# self-contained runnable example.
#
# Run:
#   julia --project=. examples/backward_chaining.jl

using MORK

# ── Knowledge base ─────────────────────────────────────────────────────
s = new_space()
space_add_all_sexpr!(s, """
    ;; Facts
    (mortal socrates)
    (human  socrates)
    (human  plato)

    ;; Rules: humans are mortal
    (exec 0
        (, (human \$x))
        (O (mortal \$x))
    )

    ;; Rules: mortals can die
    (exec 1
        (, (mortal \$x))
        (O (can-die \$x))
    )
""")

steps = space_metta_calculus!(s, 10_000)
result = space_dump_all_sexpr(s)

println("=== Backward Chaining ===")
println("Converged in $steps steps\n")

for category in ["mortal", "human", "can-die"]
    matches = filter(l -> startswith(l, "($category "), split(result, "\n"))
    isempty(matches) || println("$category: $(join(matches, ", "))")
end

@assert occursin("(mortal plato)", result)    "plato should be mortal"
@assert occursin("(can-die socrates)", result) "socrates can die"
@assert occursin("(can-die plato)", result)    "plato can die"
println("\n✓ All assertions passed")
