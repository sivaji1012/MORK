#!/usr/bin/env julia
# benchmarks/benchmarks.jl — MORK performance benchmarks
#
# Benchmarks the hot paths in the MORK space calculus:
# space construction, rule firing, pattern matching, sinks.
#
# Run:
#   julia --project=. benchmarks/benchmarks.jl

using MORK, BenchmarkTools

const SUITE = BenchmarkGroup()

# ── Space construction ─────────────────────────────────────────────────

SUITE["construction"] = BenchmarkGroup()

SUITE["construction"]["new_space"] = @benchmarkable new_space()

SUITE["construction"]["add_100_atoms"] = @benchmarkable begin
    s = new_space()
    for i in 1:100
        space_add_all_sexpr!(s, "(fact atom_$i)")
    end
end

# ── Calculus: ground match ─────────────────────────────────────────────

SUITE["calculus"] = BenchmarkGroup()

function _build_ground_space(n)
    s = new_space()
    for i in 1:n
        space_add_all_sexpr!(s, "(n $i)")
    end
    space_add_all_sexpr!(s, """
        (exec 0 (, (n \$x)) (O (processed \$x)))
        (exec 1 (, (n \$x)) (O (- (n \$x))))
    """)
    s
end

SUITE["calculus"]["ground_match_10"] = @benchmarkable begin
    s = _build_ground_space(10)
    space_metta_calculus!(s, 10_000)
end

SUITE["calculus"]["ground_match_100"] = @benchmarkable begin
    s = _build_ground_space(100)
    space_metta_calculus!(s, 100_000)
end

# ── Calculus: two-source join ─────────────────────────────────────────

SUITE["calculus"]["two_source_100"] = @benchmarkable begin
    s = new_space()
    for i in 1:50
        space_add_all_sexpr!(s, "(A item_$i)\n(B item_$i)")
    end
    space_add_all_sexpr!(s, "(exec 0 (, (A \$x) (B \$x)) (O (C \$x)))")
    space_metta_calculus!(s, 100_000)
end

# ── Calculus: float reduction sinks ───────────────────────────────────

SUITE["sinks"] = BenchmarkGroup()

function _build_float_space(n)
    s = new_space()
    vals = join(["(n $(rand() * 100))" for _ in 1:n], "\n")
    space_add_all_sexpr!(s, vals)
    space_add_all_sexpr!(s, """
        (exec 0
            (, (n \$x))
            (O
                (fsum  (total \$c) \$c \$x)
                (fmax  (peak  \$c) \$c \$x)
                (fmin  (floor \$c) \$c \$x)
            )
        )
        (exec 1 (, (n \$x)) (O (- (n \$x))))
    """)
    s
end

SUITE["sinks"]["float_reduce_10"]  = @benchmarkable begin
    s = _build_float_space(10)
    space_metta_calculus!(s, 10_000)
end

SUITE["sinks"]["float_reduce_100"] = @benchmarkable begin
    s = _build_float_space(100)
    space_metta_calculus!(s, 100_000)
end

# ── Expression parsing ─────────────────────────────────────────────────

SUITE["parsing"] = BenchmarkGroup()

SUITE["parsing"]["sexpr_simple"]  = @benchmarkable sexpr_to_expr("(isa alice human)")
SUITE["parsing"]["sexpr_nested"]  = @benchmarkable sexpr_to_expr("(exec 0 (, (A \$x) (B \$x)) (O (C \$x)))")

# ── Run ────────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    println("MORK Benchmarks")
    println("===============")
    println("Julia version: ", VERSION)
    println()

    tune = "--tune" in ARGS
    if tune
        println("Tuning (this may take a few minutes)...")
        tune!(SUITE)
    end

    results = run(SUITE, verbose=true, seconds=tune ? 10 : 3)

    println("\n=== Results ===")
    for (group, bgroup) in results
        println("\n[$group]")
        for (name, trial) in bgroup
            t = median(trial)
            println("  $(rpad(name, 30)) $(BenchmarkTools.prettytime(t.time))  allocs=$(t.allocs)")
        end
    end
end
