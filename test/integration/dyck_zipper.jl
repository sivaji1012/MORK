# test_dyck.jl — DyckZipper tests
using MORK, Test

@testset "DyckWord validation" begin
    # valid leaf: word = 1 (single leaf)
    @test dyck_valid_non_empty(UInt64(1))
    # valid 2-leaf: 0b110 = 6
    @test dyck_valid_non_empty(UInt64(0b110))
    # valid 3-leaf: 0b11010 = 26
    @test dyck_valid_non_empty(UInt64(0b11010))
    # invalid: 0
    @test !dyck_valid_non_empty(UInt64(0))
    # invalid: highest bit set (would need leading_zeros==0)
    # 0x8000000000000000 has leading_zeros==0 → false
    @test !dyck_valid_non_empty(UInt64(0x8000000000000000))
end

@testset "dyck_word_new" begin
    @test dyck_word_new(UInt64(1)) !== nothing
    @test dyck_word_new(UInt64(0b110)) !== nothing
    @test dyck_word_new(UInt64(0)) === nothing
end

@testset "DyckStructureZipperU64 construction" begin
    # leaf
    z = DyckStructureZipperU64(UInt64(1))
    @test z !== nothing
    @test dsz_is_leaf(z)
    @test dsz_at_root(z)

    # 2-leaf tree: structure = 0b110
    z2 = DyckStructureZipperU64(UInt64(0b110))
    @test z2 !== nothing
    @test !dsz_is_leaf(z2)
    @test dsz_at_root(z2)

    # empty → nothing
    @test DyckStructureZipperU64(UInt64(0)) === nothing
end

@testset "DyckStructureZipperU64 navigation" begin
    # 2-leaf tree: structure = 0b110 (binary: branch with two leaves)
    z = DyckStructureZipperU64(UInt64(0b110))

    # descend left
    @test dsz_descend_left!(z)
    @test dsz_is_leaf(z)
    @test !dsz_at_root(z)

    # can't descend further (leaf)
    @test !dsz_descend_left!(z)

    # ascend
    @test dsz_ascend!(z)
    @test dsz_at_root(z)

    # descend right
    @test dsz_descend_right!(z)
    @test dsz_is_leaf(z)

    # ascend to root
    dsz_ascend_to_root!(z)
    @test dsz_at_root(z)
end

@testset "DyckStructureZipperU64 leaf indices" begin
    # single leaf: structure = 1
    z = DyckStructureZipperU64(UInt64(1))
    leaves = dsz_depth_first_leaves(z)
    @test length(leaves) >= 1

    # 2-leaf tree
    z2 = DyckStructureZipperU64(UInt64(0b110))
    bf = dsz_breadth_first_leaves(z2)
    df = dsz_depth_first_leaves(z2)
    @test length(bf) == 2
    @test length(df) == 2
end

@testset "DyckStructureZipperU64 substructure" begin
    z = DyckStructureZipperU64(UInt64(0b110))
    sub = dsz_current_substructure(z)
    @test sub isa DyckWord
    @test sub.word == UInt64(0b110)

    # descend left — substructure should be leaf
    dsz_descend_left!(z)
    sub_leaf = dsz_current_substructure(z)
    @test sub_leaf.word == UInt64(1)
end

@testset "DYCK_ZIPPER_LEAF constant" begin
    z = DyckStructureZipperU64(DYCK_WORD_LEAF.word)
    @test z !== nothing
    @test dsz_is_leaf(z)
end

@testset "left_to_right / right_to_left" begin
    z = DyckStructureZipperU64(UInt64(0b110))
    # at root — side-to-side should fail
    @test !dsz_left_to_right!(z)
    @test !dsz_right_to_left!(z)

    # descend left, then move to right
    dsz_descend_left!(z)
    @test dsz_left_to_right!(z)   # now at right child
    @test dsz_is_leaf(z)

    # move back left
    @test dsz_right_to_left!(z)
    @test dsz_is_leaf(z)
end

println("All DyckZipper tests passed!")
