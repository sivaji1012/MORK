# test/integration/run_all.jl — runs all integration tests
# Mirrors the fn main() call sequence in kernel/src/main.rs.
# Each file corresponds to one upstream test function.
#
# Usage (from warm REPL):
#   include("test/integration/run_all.jl")

const INTEGRATION_DIR = @__DIR__

pass = 0; fail = 0; err = 0
for f in sort(readdir(INTEGRATION_DIR))
    f == "run_all.jl" && continue
    endswith(f, ".jl") || continue
    try
        include(joinpath(INTEGRATION_DIR, f))
        global pass += 1
    catch e
        if e isa Test.TestSetException
            global fail += 1
            println("FAIL  $f")
        else
            global err += 1
            println("ERROR $f: $(typeof(e)): $(sprint(showerror, e))")
        end
    end
end
println("\n=== Integration tests: $pass passed  $fail failed  $err errors ===")
