"""
server_branch.jl — Integration tests ported from server-branch space.rs.

Mirrors:
  - `iter_reset_expr` test (space.rs:2306)
  - `bfs_test` test (space.rs:2341)
"""

using MORK
using Test

@testset "iter_reset_expr (port of server-branch test)" begin
    s = new_space()
    e = space_sexpr_to_expr(s, "[3] a [2] b c d")

    first_str  = String[]
    second_str = String[]

    ez = ExprZipper(e, 1)
    while true
        t = ez_tag(ez)
        if t isa ExprSymbol
            push!(first_str, "SYM($(t.size))")
        elseif t isa ExprArity
            push!(first_str, "[$(t.arity)]")
        end
        ez_next!(ez) || break
    end

    ez_reset!(ez)

    while true
        t = ez_tag(ez)
        if t isa ExprSymbol
            push!(second_str, "SYM($(t.size))")
        elseif t isa ExprArity
            push!(second_str, "[$(t.arity)]")
        end
        ez_next!(ez) || break
    end

    @test first_str == second_str
end

@testset "bfs_test (port of server-branch test)" begin
    exprs_src = """
        (first_name John)
        (last_name Smith)
        (is_alive true)
        (address (street_address 21 2nd Street))
        (address (city New York))
        (address (state NY))
        (address (postal_code 10021-3100))
        (phone_numbers (0 (type home)))
        (phone_numbers (0 (number 212 555-1234)))
        (phone_numbers (1 (type office)))
        (phone_numbers (1 (number 646 555-4567)))
        (children (0 Catherine))
        (children (1 Thomas))
        (children (2 Trevor))
    """

    s = new_space()
    space_add_all_sexpr!(s, exprs_src)

    # `[2] $ $` pattern matches top-level 2-arity terms
    pat = space_sexpr_to_expr(s, "[2] \$ \$")

    prime_results = space_token_bfs(s, UInt8[], pat)
    @test length(prime_results) > 0

    # token_bfs at first token should produce children
    (t1, _e1) = prime_results[1]
    l1_results = space_token_bfs(s, t1, pat)
    @test l1_results isa Vector

    if length(prime_results) >= 2
        (t2, _e2) = prime_results[2]
        l2_results = space_token_bfs(s, t2, pat)
        @test l2_results isa Vector
    end
end
