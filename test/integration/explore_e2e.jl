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

    # Initial explore under (node $x) prefix — returns initial tokens
    status, body = _exp_get("/explore/(node%20%24x)")
    @test status == 200
    items = JSON3.read(body)
    @test items isa AbstractVector
    @test length(items) >= 1

    for item in items
        @test haskey(item, :token)
        @test haskey(item, :cnt)
        @test haskey(item, :expr)
        @test item.cnt >= 1
    end

    @test any(item -> occursin("node", item.expr), items)

    # Iterative explore: pass token from first result to get deeper results
    if !isempty(items)
        tok_ints = collect(items[1].token)
        if !isempty(tok_ints)
            tok_encoded = join(["%$(uppercase(string(UInt8(b), base=16, pad=2)))" for b in tok_ints])
            status2, body2 = _exp_get("/explore/(node%20%24x)/$tok_encoded")
            @test status2 == 200
            items2 = JSON3.read(body2)
            @test items2 isa AbstractVector
            # Iterative results are the individual (node a/b/c) atoms
            @test length(items2) >= 1
            @test all(item -> occursin("node", item.expr), items2)
        end
    end

    # Non-existent prefix → empty array
    status3, body3 = _exp_get("/explore/(nosuch_xyz)")
    @test status3 == 200
    @test JSON3.read(body3) == []

    # (other $x) prefix
    status4, body4 = _exp_get("/explore/(other%20%24x)")
    @test status4 == 200
    items4 = JSON3.read(body4)
    @test any(item -> occursin("other", item.expr), items4)

end

_exp_get("/clear/%24")
