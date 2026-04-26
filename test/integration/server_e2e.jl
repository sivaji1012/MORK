# server_e2e.jl — end-to-end HTTP server integration tests
# Starts a MorkServer, exercises every command endpoint, stops it.
#
# Run from warm REPL:
#   include("test/integration/server_e2e.jl")
#
# Or standalone:
#   julia --project=. test/integration/server_e2e.jl

using MORK, HTTP, JSON3, Test

const E2E_PORT = 9902
const BASE = "http://127.0.0.1:$E2E_PORT"

# ── Helpers ──────────────────────────────────────────────────────────────

function get(path)
    r = HTTP.get("$BASE$path"; readtimeout=10, connect_timeout=5)
    (r.status, String(r.body))
end

function post(path, body="")
    r = HTTP.post("$BASE$path", [], body; readtimeout=10, connect_timeout=5)
    (r.status, String(r.body))
end

function wait_lock_free(path="$BASE/status/-", timeout_s=5.0)
    deadline = time() + timeout_s
    while time() < deadline
        try
            j = JSON3.read(HTTP.get(path; readtimeout=2).body)
            s = String(j[:status])
            s ∉ ("locked", "counting") && return s
        catch; end
        sleep(0.1)
    end
    "timeout"
end

# ── Server lifecycle ──────────────────────────────────────────────────────

ss  = ServerSpace()
srv = serve_background!(ss, E2E_PORT)
# Wait for server
deadline = time() + 15.0
while time() < deadline
    try; HTTP.get("$BASE/status/-"; readtimeout=1, connect_timeout=1); break; catch; sleep(0.2); end
end

# ── Tests ─────────────────────────────────────────────────────────────────

@testset "MORK Server E2E" begin

    @testset "root page" begin
        status, body = get("/")
        @test status == 200
        @test occursin("MORK Server", body)
        @test occursin("href", body)
    end

    @testset "favicon returns 200 image" begin
        r = HTTP.get("$BASE/favicon.ico")
        @test r.status == 200
        ct = HTTP.header(r, "Content-Type")
        @test occursin("image", ct)
    end

    @testset "status root — pathClear" begin
        status, body = get("/status/-")
        @test status == 200
        j = JSON3.read(body)
        @test String(j[:status]) == "pathClear"
    end

    @testset "upload MeTTa atoms" begin
        status, body = post("/upload/\$/\$",
            "(isa John Person)\n(isa Mary Person)\n(isa Rex Dog)\n" *
            "(likes John Mary)\n(likes Mary Rex)\n(age John 30)\n(age Mary 25)\n")
        @test status == 200
        @test body == "ACK. Upload Successful"
    end

    @testset "count atoms at prefix" begin
        # (isa $x $y) derives prefix [ExprArity(3), ExprSymbol("isa")] — matches all isa-3 atoms
        status, body = get("/count/(isa%20%24x%20%24y)")
        @test status == 200
        @test body == "ACK. Starting Count"
        sleep(1.5)   # async spawn needs time
        _, sbody = get("/status/(isa%20%24x%20%24y)")
        j = JSON3.read(sbody)
        @test String(j[:status]) == "countResult"
        @test j[:count] == 3    # John, Mary, Rex
    end

    @testset "export all atoms" begin
        status, body = get("/export/\$/\$")
        @test status == 200
        lines = filter(!isempty, split(body, "\n"))
        @test length(lines) == 7
        @test any(l -> occursin("isa John Person", l), lines)
    end

    @testset "transform — conjunction join" begin
        # Find all (Person X) who (likes X Y) → produce (person-likes X Y)
        status, body = post("/transform",
            "(transform (, (isa \$x Person) (likes \$x \$y)) (, (person-likes \$x \$y)))")
        @test status == 200
        @test body == "ACK. TranformMultiMulti dispatched"
        sleep(1.5)  # async spawn
        _, exp = get("/export/\$/\$")
        lines = filter(!isempty, split(exp, "\n"))
        @test any(l -> occursin("person-likes John Mary", l), lines)
        @test any(l -> occursin("person-likes Mary Rex", l), lines)
    end

    @testset "export with pattern filter" begin
        # Only atoms matching (person-likes $ $)
        status, body = get("/export/(person-likes%20%24x%20%24y)/\$(person-likes%20\$x%20\$y)")
        @test status == 200
    end

    @testset "clear subtree" begin
        # Clear all person-likes atoms: use (person-likes $x $y) to derive the right prefix
        status, body = get("/clear/(person-likes%20%24x%20%24y)")
        @test status == 200
        @test body == "ACK. Cleared"
        sleep(0.3)
        _, exp = get("/export/\$/\$")
        lines = filter(!isempty, split(exp, "\n"))
        @test !any(l -> occursin("person-likes", l), lines)
        @test length(lines) == 7   # original 7 atoms
    end

    @testset "busywait" begin
        status, body = get("/busywait/100")
        @test status == 200
        @test body == "ACK. Waiting"
    end

    @testset "status_stream returns SSE" begin
        r = HTTP.get("$BASE/status_stream/-"; readtimeout=5)
        @test r.status == 200
        ct = HTTP.header(r, "Content-Type")
        @test occursin("event-stream", ct)
    end

    @testset "unknown command returns 404" begin
        r = HTTP.get("$BASE/does_not_exist"; status_exception=false)
        @test r.status == 404
    end

    @testset "stop server" begin
        status, body = get("/stop")
        @test status == 200
        @test body == "shutting down"
    end
end

println("\nE2E test complete.")
