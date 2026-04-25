# test_metta_thread.jl — ports metta_thread_without_substitution_adams_hello_world
# from server/tests/exec_mm2.rs
using MORK, HTTP, JSON3, Test

const PORT = 9905
const BASE = "http://127.0.0.1:$PORT"

ss  = ServerSpace()
srv = serve_background!(ss, PORT)
sleep(2)

function wait_status(url, expected, timeout=10.0)
    deadline = time() + timeout
    while time() < deadline
        try
            j = JSON3.read(HTTP.get(url; readtimeout=2).body)
            String(j[:status]) == expected && return true
        catch; end
        sleep(0.1)
    end
    false
end

@testset "metta_thread — adams hello world (ports exec_mm2.rs)" begin

    # Step 1: Upload data atoms
    r1 = HTTP.post("$BASE/upload/(adams_hw_data%20%24v)/(adams_hw_data%20%24v)", [],
        "(adams_hw_data T)\n(adams_hw_data (foo 1))\n(adams_hw_data (foo 2))\n")
    @test r1.status == 200

    # Step 2: Upload exec rules (match foo→bar + match T→ran_exec)
    execs = """
(exec (adams_hw_data 0)   (, (adams_hw_data (foo \$x)))   (, (adams_hw_data (bar \$x))))
(exec (adams_hw_data 0)   (, (adams_hw_data T))           (, (adams_hw_data ran_exec)))
"""
    r2 = HTTP.post(
        "$BASE/upload/(exec%20%24l_p%20%24patterns%20%24templates)/(exec%20%24l_p%20%24patterns%20%24templates)",
        [], execs)
    @test r2.status == 200

    # Step 3: Run metta_thread at location adams_hw_data
    r3 = HTTP.get("$BASE/metta_thread?location=adams_hw_data")
    @test r3.status == 200
    @test occursin("dispatched", String(r3.body))

    # Wait for thread to finish
    finished = wait_status("$BASE/status/(exec%20adams_hw_data)", "pathClear", 10.0)
    @test finished

    sleep(0.1)

    # Step 4: Export and check results
    exp = String(HTTP.get("$BASE/export/(adams_hw_data%20%24v)/(data%20%24v)").body)
    lines = sort(filter(!isempty, split(exp, "\n")))
    println("Export results:")
    for l in lines; println("  $l"); end

    expected = sort(["(data T)", "(data ran_exec)", "(data (foo 1))",
                     "(data (foo 2))", "(data (bar 1))", "(data (bar 2))"])
    @test lines == expected
end

HTTP.get("$BASE/stop"; readtimeout=2)
println("\nmetta_thread test complete.")
