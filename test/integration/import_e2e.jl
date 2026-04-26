# import_e2e.jl — ports import_request_test from server/tests/simple.rs
# Tests: successful import, bogus URL (fetchError), bad file (parseError)
using MORK, HTTP, JSON3, Test

const PORT = 9906
const BASE = "http://127.0.0.1:$PORT"

ss  = ServerSpace()
srv = serve_background!(ss, PORT)
sleep(2)

function wait_ne(url, expected, timeout=15.0)
    deadline = time() + timeout
    while time() < deadline
        try
            j = JSON3.read(HTTP.get(url; readtimeout=3).body)
            s = String(j[:status])
            s != expected && return s
        catch; end
        sleep(0.2)
    end
    "timeout"
end

function wait_eq(url, expected, timeout=15.0)
    deadline = time() + timeout
    while time() < deadline
        try
            j = JSON3.read(HTTP.get(url; readtimeout=3).body)
            String(j[:status]) == expected && return true
        catch; end
        sleep(0.2)
    end
    false
end

STATUS_URL = "$BASE/status/(import_test%20%24v)"
COUNT_URL  = "$BASE/count/(import_test%20%24v%20%24w)"   # count all 3-arg atoms

@testset "import — end-to-end (ports simple.rs import_request_test)" begin

    # ── Test 1: successful import from GitHub ────────────────────────────
    @testset "1. successful import from URL" begin
        r = HTTP.get("$BASE/import/%24v/(import_test%20%24v)?uri=https://raw.githubusercontent.com/trueagi-io/metta-examples/refs/heads/main/aunt-kg/toy.metta")
        @test r.status == 200
        @test occursin("ACK", String(r.body))

        # Wait for completion
        final_status = wait_ne(STATUS_URL, "pathForbiddenTemporary", 30.0)
        @test final_status == "pathClear"

        # Count atoms loaded
        HTTP.get("$BASE/count/(import_test%20%24v)")
        sleep(1.5)
        j = JSON3.read(HTTP.get(STATUS_URL).body)
        @test String(j[:status]) == "countResult"
        @test j[:count] == 13
    end

    # ── Test 2: bogus URL → fetchError ───────────────────────────────────
    @testset "2. bogus URL sets fetchError status" begin
        r = HTTP.get("$BASE/import/%24v/(import_test%20%24v)?uri=https://raw.githubusercontent.com/trueagi-io/metta-examples/no_such_file.metta")
        @test r.status == 200
        @test occursin("ACK", String(r.body))

        final_status = wait_ne(STATUS_URL, "pathForbiddenTemporary", 20.0)
        @test final_status == "fetchError"
    end

    # ── Test 3: non-MeTTa file → parseError ─────────────────────────────
    @testset "3. non-MeTTa file sets parseError status" begin
        r = HTTP.get("$BASE/import/%24v/(import_test%20%24v)?uri=https://raw.githubusercontent.com/trueagi-io/metta-examples/refs/heads/main/aunt-kg/README.md")
        @test r.status == 200
        @test occursin("ACK", String(r.body))

        final_status = wait_ne(STATUS_URL, "pathForbiddenTemporary", 20.0)
        @test final_status == "parseError"
    end

end

HTTP.get("$BASE/stop"; readtimeout=2)
println("import E2E complete.")
