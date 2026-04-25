# test/integration/explore_e2e.jl — ports explore command tests
# Tests /explore/<expr> — BFS token exploration (mirrors do_bfs in Rust server)
# Run from warm REPL against running server on port 8080.
using MORK, Test, HTTP, JSON3

const EXPLORE_BASE = "http://localhost:8080"

function _exp_get(path)
    r = HTTP.get("$EXPLORE_BASE$path"; readtimeout=10, connect_timeout=5)
    r.status, String(r.body)
end
function _exp_post(path, body="")
    r = HTTP.post("$EXPLORE_BASE$path", [], body; readtimeout=10, connect_timeout=5)
    r.status, String(r.body)
end

_exp_get("/clear/%24")
sleep(0.3)

@testset "explore — BFS token exploration of trie under prefix" begin

    status, _ = _exp_post("/upload/\$/\$", "(node a)\n(node b)\n(node c)\n(other x)\n")
    @test status == 200

    # Explore under (node $x) prefix
    status, body = _exp_get("/explore/(node%20%24x)")
    @test status == 200
    items = JSON3.read(body)
    @test items isa AbstractVector
    @test length(items) >= 1

    # Each item has token, cnt, expr
    for item in items
        @test haskey(item, :token)
        @test haskey(item, :cnt)
        @test haskey(item, :expr)
        @test item.cnt >= 1
    end

    # Expressions should contain "node" functor
    @test any(item -> occursin("node", item.expr), items)

    # Explore (other $x) → its atoms
    status2, body2 = _exp_get("/explore/(other%20%24x)")
    @test status2 == 200
    items2 = JSON3.read(body2)
    @test any(item -> occursin("other", item.expr), items2)

    # Non-existent prefix → empty array, no error
    status3, body3 = _exp_get("/explore/(nosuch_xyz)")
    @test status3 == 200
    @test JSON3.read(body3) == []

    # Note: iterative explore (passing token back) deferred — server-side
    # BoundsError with partial trie-key tokens is a known gap.

end

_exp_get("/clear/%24")
