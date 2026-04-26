# sink_pure.jl — ports of sink_pure_* tests from kernel/src/main.rs
using MORK, Test

function mc(src, steps=typemax(Int))
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, steps)
    s
end

all_lines(s) = Set(filter(!isempty, split(space_dump_all_sexpr(s), "\n")))

# ── sink_pure_basic ───────────────────────────────────────────────────
@testset "sink_pure_basic (reverse_symbol)" begin
    s = mc("""
(A 0 123)
(A 1 racecar)
(A 2 "nipson anomemata me monan opsin")
(exec 0 (, (A \$i \$s))
        (O (pure (B \$i \$rs) \$rs (reverse_symbol \$s))))
""")
    lines = all_lines(s)
    @test "(B 0 321)" in lines
    @test "(B 1 racecar)" in lines
    @test any(contains(l, "B 2") for l in lines)
end

# ── sink_pure_basic_nested ────────────────────────────────────────────
@testset "sink_pure_basic_nested (reverse_symbol twice = identity)" begin
    s = mc("""
(A 0 123)
(A 1 racecar)
(A 2 "nipson anomemata me monan opsin")
(exec 0 (, (A \$i \$s))
        (O (pure (B \$i \$rs) \$rs (reverse_symbol (reverse_symbol \$s)))))
""")
    lines = all_lines(s)
    @test "(B 0 123)" in lines
    @test "(B 1 racecar)" in lines
    @test any(contains(l, "B 2") && contains(l, "nipson") for l in lines)
end

# ── sink_pure_roman_validation ────────────────────────────────────────
@testset "sink_pure_roman_validation (f32 arithmetic)" begin
    s = mc("""
(pair 0.329 1.230)
(func max_f32)
(func min_f32)
(func sub_f32)
(func div_f32)
(func sum_f32)
(func product_f32)
(exec 0 (, (pair \$x \$y) (func \$func))
        (O (pure (result \$func \$z) \$z
            (f32_to_string (\$func (f32_from_string \$x) (f32_from_string \$y))))))
""")
    lines = all_lines(s)
    @test any(contains(l, "result sum_f32") for l in lines)
    @test any(contains(l, "result max_f32") for l in lines)
    @test any(contains(l, "result min_f32") for l in lines)
    @test any(contains(l, "result div_f32") for l in lines)
    @test any(contains(l, "result sub_f32") for l in lines)
    @test any(contains(l, "result product_f32") for l in lines)
end

# ── sink_pure_explode_collapse_ident ──────────────────────────────────
@testset "sink_pure_explode_collapse_ident (explode+collapse = id)" begin
    s = mc("""
(mysym foo)
(exec 0 (, (mysym \$x))
        (O (pure (result \$i) \$i (collapse_symbol (explode_symbol \$x)))))
""")
    lines = all_lines(s)
    @test "(result foo)" in lines
end

# ── sink_bass64url_ident ──────────────────────────────────────────────
@testset "sink_base64url_ident (encode+decode = id)" begin
    s = mc("""
(mysym foo)
(exec 0 (, (mysym \$x))
        (O (pure (result \$i) \$i (decode_base64url (encode_base64url \$x)))))
""")
    lines = all_lines(s)
    @test "(result foo)" in lines
end

# ── sink_hex_ident ────────────────────────────────────────────────────
@testset "sink_hex_ident (encode_hex+decode_hex = id)" begin
    s = mc("""
(mysym foo)
(exec 0 (, (mysym \$x))
        (O (pure (result \$i) \$i (decode_hex (encode_hex \$x)))))
""")
    lines = all_lines(s)
    @test "(result foo)" in lines
end

# ── sink_even_half ────────────────────────────────────────────────────
@testset "sink_even_half (ifnz + i8 ops, integer div/2 for all)" begin
    s = mc("""
(xs 0 10)
(xs 1 11)
(xs 2 12)
(xs 3 13)
(xs 4 14)
(exec 0 (, (xs \$i \$v))
        (O (pure (half \$i \$h) \$h
          (ifnz (u8_xnor (mod_i8 (i8_from_string \$v) (i8_from_string 2)) (u8_zeros))
           then (i8_to_string (div_i8 (i8_from_string \$v) (i8_from_string 2)))))))
""")
    lines = all_lines(s)
    # u8_xnor(x,0)=~x is always non-zero, so ALL 5 produce output (integer div):
    # 10/2=5, 11/2=5, 12/2=6, 13/2=6, 14/2=7
    @test "(half 0 5)" in lines
    @test "(half 1 5)" in lines
    @test "(half 2 6)" in lines
    @test "(half 3 6)" in lines
    @test "(half 4 7)" in lines
end
