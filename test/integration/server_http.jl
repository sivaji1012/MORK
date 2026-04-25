"""
server_http.jl — HTTP integration tests for the MORK server.

Ports server/tests/simple.rs + exec_mm2.rs from the server branch.

Starts a MorkServer on TEST_PORT, runs all tests, stops it.
Each test mirrors the corresponding upstream #[tokio::test] function.
"""

using MORK
using HTTP
using JSON3
using Test

const TEST_PORT = 9901
const SERVER_URL = "http://127.0.0.1:$TEST_PORT"

# =====================================================================
# Helpers — mirrors common.rs
# =====================================================================

function wait_for_server(timeout_s=10.0)
    deadline = time() + timeout_s
    while time() < deadline
        try
            r = HTTP.get("$SERVER_URL/status/-"; readtimeout=1, connect_timeout=1)
            r.status == 200 && return true
        catch; end
        sleep(0.01)
    end
    error("Server did not start within $(timeout_s)s")
end

function get_url_status(url::String)
    r = HTTP.get(url)
    j = JSON3.read(String(r.body))
    String(j[:status])
end

function wait_for_status_eq(url::String, expected::String, timeout_s=10.0)
    deadline = time() + timeout_s
    while time() < deadline
        try
            get_url_status(url) == expected && return true
        catch; end
        sleep(0.01)
    end
    error("Timed out waiting for $url to reach status '$expected'")
end

function wait_for_status_ne(url::String, expected::String, timeout_s=10.0)
    deadline = time() + timeout_s
    while time() < deadline
        try
            s = get_url_status(url)
            s != expected && return s
        catch; end
        sleep(0.01)
    end
    error("Timed out waiting for $url to leave status '$expected'")
end

# =====================================================================
# Server lifecycle
# =====================================================================

ss   = ServerSpace(mktempdir())
srv  = serve_background!(ss, TEST_PORT)
wait_for_server()

# =====================================================================
# Test: status endpoint reachable (mirrors simple_request_test)
# =====================================================================

@testset "status endpoint reachable" begin
    r = HTTP.get("$SERVER_URL/status/-")
    @test r.status == 200
    println("PASS  status endpoint: $(String(r.body))")
end

# =====================================================================
# Test: upload + export round-trip (mirrors export_request_test)
# =====================================================================

@testset "upload + export round-trip" begin
    PAYLOAD = "(female Liz)\n(male Tom)\n(male Bob)\n(parent Tom Liz)\n(parent Tom Bob)\n"
    space_expr = "(export_test \$v)"
    file_expr  = "\$v"

    upload_url = "$SERVER_URL/upload/$(HTTP.escapeuri(file_expr))/$(HTTP.escapeuri(space_expr))"
    status_url = "$SERVER_URL/status/$(HTTP.escapeuri(space_expr))"
    export_url = "$SERVER_URL/export/$(HTTP.escapeuri(space_expr))/$(HTTP.escapeuri(file_expr))"

    r = HTTP.post(upload_url; body=PAYLOAD)
    @test r.status == 200
    println("Upload: $(String(r.body))")

    wait_for_status_eq(status_url, "pathClear")

    r = HTTP.get(export_url)
    @test r.status == 200
    exported = String(r.body)
    println("Export:\n$exported")

    sorted_got  = sort(filter(!isempty, split(exported, "\n")))
    sorted_want = sort(filter(!isempty, split(PAYLOAD,  "\n")))
    @test sorted_got == sorted_want
end

# =====================================================================
# Test: upload + transform + export (mirrors transform_basic_request_test)
# =====================================================================

@testset "upload + transform + export" begin
    PAYLOAD = "(a b)\n(x (y z))\n"
    in_expr  = "(transform_basic_test in \$v)"
    out_expr = "(transform_basic_test out \$v)"
    id_expr  = "\$v"

    upload_url    = "$SERVER_URL/upload/$(HTTP.escapeuri(id_expr))/$(HTTP.escapeuri(in_expr))"
    transform_url = "$SERVER_URL/transform"
    export_in_url = "$SERVER_URL/export/$(HTTP.escapeuri(in_expr))/$(HTTP.escapeuri(id_expr))"
    export_out_url= "$SERVER_URL/export/$(HTTP.escapeuri(out_expr))/$(HTTP.escapeuri(id_expr))"
    status_in_url = "$SERVER_URL/status/$(HTTP.escapeuri(in_expr))"

    r = HTTP.post(upload_url; body=PAYLOAD)
    @test r.status == 200

    transform_body = "(transform (, $in_expr) (, $out_expr))"
    r = HTTP.post(transform_url; body=transform_body)
    @test r.status == 200
    println("Transform: $(String(r.body))")

    # Both in and out should export the same identity-transformed data
    r_in  = HTTP.get(export_in_url)
    r_out = HTTP.get(export_out_url)
    @test r_in.status  == 200
    @test r_out.status == 200
    in_text  = String(r_in.body)
    out_text = String(r_out.body)
    @test sort(filter(!isempty, split(in_text,  "\n"))) ==
          sort(filter(!isempty, split(out_text, "\n")))
    println("Transform in==out: PASS ($( length(split(in_text,"\n",keepempty=false)) ) exprs)")
end

# =====================================================================
# Test: clear command (mirrors clear_request_test)
# =====================================================================

@testset "clear command" begin
    PAYLOAD    = "(clear_test a)\n(clear_test b)\n"
    space_expr = "(clear_test \$v)"
    id_expr    = "\$v"

    upload_url = "$SERVER_URL/upload/$(HTTP.escapeuri(id_expr))/$(HTTP.escapeuri(space_expr))"
    clear_url  = "$SERVER_URL/clear/$(HTTP.escapeuri(space_expr))"
    export_url = "$SERVER_URL/export/$(HTTP.escapeuri(space_expr))/$(HTTP.escapeuri(id_expr))"
    status_url = "$SERVER_URL/status/$(HTTP.escapeuri(space_expr))"

    r = HTTP.post(upload_url; body=PAYLOAD)
    @test r.status == 200
    wait_for_status_eq(status_url, "pathClear")

    r = HTTP.get(clear_url)
    @test r.status == 200
    println("Clear: $(String(r.body))")

    r = HTTP.get(export_url)
    @test r.status == 200
    @test isempty(strip(String(r.body)))
    println("After clear: empty ✓")
end

# =====================================================================
# Test: count command
# =====================================================================

@testset "count command" begin
    PAYLOAD    = "(count_test a)\n(count_test b)\n(count_test c)\n"
    space_expr = "(count_test \$v)"
    id_expr    = "\$v"

    upload_url = "$SERVER_URL/upload/$(HTTP.escapeuri(id_expr))/$(HTTP.escapeuri(space_expr))"
    count_url  = "$SERVER_URL/count/$(HTTP.escapeuri(space_expr))"
    status_url = "$SERVER_URL/status/$(HTTP.escapeuri(space_expr))"

    r = HTTP.post(upload_url; body=PAYLOAD)
    @test r.status == 200
    wait_for_status_eq(status_url, "pathClear")

    r = HTTP.get(count_url)
    @test r.status == 200
    println("Count ACK: $(String(r.body))")

    wait_for_status_eq(status_url, "countResult")
    j = JSON3.read(get_url_status isa Function ? String(HTTP.get(status_url).body) : "{}")
    # status endpoint returns JSON with count field after count command
    r2 = HTTP.get(status_url)
    j2 = JSON3.read(String(r2.body))
    @test j2[:status] == "countResult"
    @test j2[:count] == 3
    println("Count result: $(j2[:count]) ✓")
end

# =====================================================================
# Test: metta_thread with exec rules (mirrors metta_thread_without_substitution_adams_hello_world)
# =====================================================================

@testset "metta_thread exec rules" begin
    data_prefix  = "adams_hw_data"
    in_expr      = "($data_prefix \$v)"
    exec_pattern = "(exec \$l_p \$patterns \$templates)"

    upload_url       = "$SERVER_URL/upload/$(HTTP.escapeuri(in_expr))/$(HTTP.escapeuri(in_expr))"
    exec_upload_url  = "$SERVER_URL/upload/$(HTTP.escapeuri(exec_pattern))/$(HTTP.escapeuri(exec_pattern))"
    metta_thread_url = "$SERVER_URL/metta_thread?location=$data_prefix"
    export_url       = "$SERVER_URL/export/$(HTTP.escapeuri(in_expr))/\$v"
    status_url       = "$SERVER_URL/status/$(HTTP.escapeuri(in_expr))"
    thread_status_url= "$SERVER_URL/status/$(HTTP.escapeuri("(exec $data_prefix)"))"

    # Upload data
    upload_payload = "\n($data_prefix T)\n($data_prefix (foo 1))\n($data_prefix (foo 2))"
    r = HTTP.post(upload_url; body=upload_payload)
    @test r.status == 200
    wait_for_status_eq(status_url, "pathClear")

    # Upload exec rules
    exec_payload = "\n(exec ($data_prefix 0)   (, ($data_prefix (foo \$x)))   (, ($data_prefix (bar \$x))) )" *
                   "\n(exec ($data_prefix 0)   (, ($data_prefix T))            (, ($data_prefix ran_exec)) )"
    r = HTTP.post(exec_upload_url; body=exec_payload)
    @test r.status == 200
    wait_for_status_eq(status_url, "pathClear")

    # Run metta_thread
    r = HTTP.get(metta_thread_url)
    @test r.status == 200
    println("metta_thread: $(String(r.body))")
    wait_for_status_eq(thread_status_url, "pathClear"; timeout_s=15.0)

    sleep(0.05)

    # Export and verify
    r = HTTP.get(export_url)
    @test r.status == 200
    lines = filter(!isempty, split(String(r.body), "\n"))
    println("metta_thread export ($(length(lines)) lines):\n$(String(r.body))")
    @test length(lines) == 6
end

# =====================================================================
# Teardown
# =====================================================================

println("\n=== Stopping test server ===")
try; HTTP.get("$SERVER_URL/stop?wait_for_idle"); catch; end
println("=== Server HTTP integration tests complete ===")
