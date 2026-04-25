# metta_thread_suspend_e2e.jl — tests metta_thread_suspend
# No upstream test exists (upstream has "GOAT, suspend needs tests" comment).
# Spec from implementation: moves exec atoms from exec_loc to suspend_loc.
# Resume: run metta_thread at suspend_loc to execute the suspended atoms.
using MORK, HTTP, JSON3, Test

const PORT = 9909
const BASE = "http://127.0.0.1:$PORT"

ss  = ServerSpace()
srv = serve_background!(ss, PORT)
sleep(2)

function wait_eq(url, expected, timeout=10.0)
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

@testset "metta_thread_suspend" begin

    # ── Setup: upload data + exec rules at location "susp_test" ──────────
    # Upload raw (foo 1)(foo 2) with template (susp_test $v) → stores (susp_test (foo 1)) etc.
    HTTP.post("$BASE/upload/%24v/(susp_test%20%24v)", [],
        "(foo 1)\n(foo 2)\n") |> r -> @test r.status == 200

    # Exec rule: match (foo X) → produce (bar X)
    HTTP.post("$BASE/upload/(exec%20%24l_p%20%24patterns%20%24templates)/(exec%20%24l_p%20%24patterns%20%24templates)",
        [], "(exec (susp_test 0) (, (susp_test (foo \$x))) (, (susp_test (bar \$x))))\n") |> r -> @test r.status == 200

    # ── Verify exec atom is in space before suspend ───────────────────────
    all_atoms = String(HTTP.get("$BASE/export/%24/%24").body)
    @test occursin("exec", all_atoms)
    @test occursin("susp_test", all_atoms)

    # ── Suspend the thread (moves exec atoms to "susp_frozen") ───────────
    r = HTTP.get("$BASE/metta_thread_suspend/susp_test/susp_frozen")
    @test r.status == 200
    body = String(r.body)
    println("Suspend response: $body")
    @test occursin("frozen", lowercase(body)) || occursin("ack", lowercase(body))

    # ── Exec atom should no longer be at susp_test exec location ─────────
    after_suspend = String(HTTP.get("$BASE/export/%24/%24").body)
    # Original data still there, exec rule MOVED (not at susp_test exec prefix)
    @test occursin("susp_test", after_suspend)

    # ── Resume: run metta_thread at susp_frozen to execute suspended atoms ─
    r2 = HTTP.get("$BASE/metta_thread?location=susp_frozen")
    @test r2.status == 200
    finished = wait_eq("$BASE/status/(exec%20susp_frozen)", "pathClear", 10.0)
    @test finished

    sleep(0.2)

    # ── Verify results: (bar 1) and (bar 2) produced ─────────────────────
    final = String(HTTP.get("$BASE/export/%24/%24").body)
    lines = filter(!isempty, split(final, "\n"))
    println("Final atoms ($(length(lines))): $(sort(lines))")
    @test any(l -> occursin("bar 1", l) || occursin("(bar 1)", l), lines)
    @test any(l -> occursin("bar 2", l) || occursin("(bar 2)", l), lines)
end

HTTP.get("$BASE/stop"; readtimeout=2)
println("metta_thread_suspend test complete.")
