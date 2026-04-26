# metta_thread_self_ref.jl — ports metta_thread_without_substitution_self_reference
# from server/tests/exec_mm2.rs
#
# Key pattern: the exec atom matches ITSELF via the conjunction pattern.
# This works because transform_multi_multi re-inserts the exec atom into
# the read copy before querying, so the self-referential pattern fires.
using MORK, HTTP, JSON3, Test

const PORT = 9907
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

const THREAD_ID = "metta_thread_without_substitution_self_reference"

@testset "metta_thread — self-reference (ports exec_mm2.rs)" begin

    # Upload one exec rule that matches exec atoms at the same location
    # Pattern: (, (exec (THREAD_ID 0) \$t \$p))  — matches the exec atom itself
    # Template: (, (THREAD_ID ran_exec))
    execs = """
(exec ($THREAD_ID 0) (, (exec ($THREAD_ID 0) \$t \$p)) (, ($THREAD_ID ran_exec)))
"""
    r = HTTP.post(
        "$BASE/upload/(exec%20%24l_p%20%24patterns%20%24templates)/(exec%20%24l_p%20%24patterns%20%24templates)",
        [], execs)
    @test r.status == 200

    # Run metta_thread at the self-reference location
    r2 = HTTP.get("$BASE/metta_thread?location=$THREAD_ID")
    @test r2.status == 200
    @test occursin("dispatched", String(r2.body))

    # Wait for completion
    finished = wait_status("$BASE/status/(exec%20$THREAD_ID)", "pathClear", 10.0)
    @test finished

    sleep(0.1)

    # Export: map (THREAD_ID $v) → (self_reference $v)
    exp = String(HTTP.get(
        "$BASE/export/($THREAD_ID%20%24v)/(self_reference%20%24v)").body)
    lines = filter(!isempty, split(exp, "\n"))
    println("Export: $lines")

    @test length(lines) == 1
    @test lines[1] == "(self_reference ran_exec)"
end

HTTP.get("$BASE/stop"; readtimeout=2)
println("self-reference test complete.")
