using Test
using MORK

@testset "MORK" begin
    @testset "Phase 0 skeleton" begin
        @test MORK.version() == v"0.1.0"
        @test isdefined(MORK, :version)
    end

    @testset "Phase 1a — PathTrie{V} basics" begin
        # Default V = Nothing (matches upstream PathMap<()> atom store)
        @testset "Construction" begin
            t = PathTrie()
            @test t isa PathTrie{Nothing}
            @test length(t) == 0
            @test isempty(t)

            t2 = PathTrie{UInt32}()
            @test t2 isa PathTrie{UInt32}
            @test length(t2) == 0
        end

        @testset "Base collection API — setindex!, getindex, haskey, get, delete!" begin
            t = PathTrie{UInt32}()

            # Insert values
            t[UInt8[1, 2, 3]] = UInt32(100)
            t[UInt8[1, 2, 4]] = UInt32(200)
            t[UInt8[9]]       = UInt32(999)

            # Retrieve
            @test t[UInt8[1, 2, 3]] == UInt32(100)
            @test t[UInt8[1, 2, 4]] == UInt32(200)
            @test t[UInt8[9]]       == UInt32(999)

            # haskey
            @test haskey(t, UInt8[1, 2, 3])
            @test haskey(t, UInt8[9])
            @test !haskey(t, UInt8[1, 2])         # intermediate node has no value
            @test !haskey(t, UInt8[7, 7, 7])      # absent entirely

            # get with default
            @test get(t, UInt8[1, 2, 3], UInt32(0)) == UInt32(100)
            @test get(t, UInt8[7], UInt32(0))      == UInt32(0)

            # Overwrite
            t[UInt8[1, 2, 3]] = UInt32(500)
            @test t[UInt8[1, 2, 3]] == UInt32(500)

            # Length
            @test length(t) == 3

            # delete!
            delete!(t, UInt8[9])
            @test !haskey(t, UInt8[9])
            @test length(t) == 2
            # Deleting non-existent is harmless
            delete!(t, UInt8[1, 2, 2])
            @test length(t) == 2

            # KeyError on absent []-access
            @test_throws KeyError t[UInt8[7, 7, 7]]
        end

        @testset "Dangling paths — path_exists_at + create_path!" begin
            t = PathTrie{UInt32}()

            # create_path! makes a path without a value
            create_path!(t, UInt8[5, 6, 7])
            @test path_exists_at(t, UInt8[5, 6, 7])       # path exists
            @test !haskey(t, UInt8[5, 6, 7])              # but no value
            @test length(t) == 0                           # no stored values
            @test path_exists_at(t, UInt8[5, 6])          # intermediate also exists
            @test path_exists_at(t, UInt8[5])
            @test !path_exists_at(t, UInt8[5, 6, 7, 8])   # absent past leaf
            @test !path_exists_at(t, UInt8[9])

            # Setting a value on a dangling path promotes it
            t[UInt8[5, 6, 7]] = UInt32(42)
            @test haskey(t, UInt8[5, 6, 7])
            @test t[UInt8[5, 6, 7]] == UInt32(42)

            # create_path! on an existing-with-value path preserves the value
            create_path!(t, UInt8[5, 6, 7])
            @test t[UInt8[5, 6, 7]] == UInt32(42)
        end

        @testset "prune_path! — trims dangling segments" begin
            t = PathTrie{UInt32}()
            create_path!(t, UInt8[1, 2, 3, 4, 5])
            @test path_exists_at(t, UInt8[1, 2, 3, 4, 5])

            # prune from the leaf upward. Everything is dangling, so it all goes.
            prune_path!(t, UInt8[1, 2, 3, 4, 5])
            @test !path_exists_at(t, UInt8[1])

            # Now test prune stopping at a value-bearing node
            t[UInt8[1, 2, 3]] = UInt32(99)
            create_path!(t, UInt8[1, 2, 3, 4, 5])
            # Before prune: full chain exists
            @test path_exists_at(t, UInt8[1, 2, 3, 4, 5])
            # Prune from the leaf — should walk up to [1,2,3] and stop (it has a value)
            prune_path!(t, UInt8[1, 2, 3, 4, 5])
            @test path_exists_at(t, UInt8[1, 2, 3])       # survived (has value)
            @test !path_exists_at(t, UInt8[1, 2, 3, 4])   # dangling segments removed
            @test t[UInt8[1, 2, 3]] == UInt32(99)

            # Prune with branching: [1,2,3] has children [4] and other siblings
            t2 = PathTrie{UInt32}()
            t2[UInt8[1, 2, 3]]    = UInt32(10)
            t2[UInt8[1, 2, 4]]    = UInt32(20)    # sibling branch
            create_path!(t2, UInt8[1, 2, 3, 7, 8])
            prune_path!(t2, UInt8[1, 2, 3, 7, 8])
            # [1,2,3] keeps its value; sibling [1,2,4] untouched
            @test t2[UInt8[1, 2, 3]] == UInt32(10)
            @test t2[UInt8[1, 2, 4]] == UInt32(20)
            @test !path_exists_at(t2, UInt8[1, 2, 3, 7])  # dangling extension gone
        end
    end

    @testset "Phase 1a — ReadZipper" begin
        t = PathTrie{UInt32}()
        t[UInt8[1, 2, 3]] = UInt32(100)
        t[UInt8[1, 2, 4]] = UInt32(200)
        t[UInt8[9]]       = UInt32(999)

        @testset "Construction + at_root" begin
            z = ReadZipper(t)
            @test at_root(z)
            @test focus(z) == UInt32(1)
            @test path(z) == UInt8[]
            @test origin_path(z) == UInt8[]
            @test !is_val(z)                # root has no value
            @test val(z) === nothing
        end

        @testset "descend_to_byte! + val + is_val" begin
            z = ReadZipper(t)
            @test descend_to_byte!(z, UInt8(1))
            @test path(z) == UInt8[1]
            @test !at_root(z)
            @test !is_val(z)                # intermediate node
            @test descend_to_byte!(z, UInt8(2))
            @test descend_to_byte!(z, UInt8(3))
            @test is_val(z)
            @test val(z) == UInt32(100)
            @test path(z) == UInt8[1, 2, 3]
            @test origin_path(z) == UInt8[1, 2, 3]

            # Missing child returns false + focus unchanged
            @test !descend_to_byte!(z, UInt8(99))
            @test path(z) == UInt8[1, 2, 3]
            @test val(z) == UInt32(100)
        end

        @testset "descend_to! (multi-byte atomic)" begin
            z = ReadZipper(t)
            @test descend_to!(z, UInt8[1, 2, 3])
            @test val(z) == UInt32(100)

            # Partial failure: focus unchanged
            z2 = ReadZipper(t)
            @test !descend_to!(z2, UInt8[1, 2, 99])     # last step fails
            @test at_root(z2)                           # focus unchanged
            @test path(z2) == UInt8[]
        end

        @testset "ascend! + reset!" begin
            z = ReadZipper(t)
            descend_to!(z, UInt8[1, 2, 3])
            @test path(z) == UInt8[1, 2, 3]

            ascend!(z, 1)
            @test path(z) == UInt8[1, 2]

            ascend!(z, 1)
            @test path(z) == UInt8[1]

            # ascend past root clamps
            ascend!(z, 99)
            @test at_root(z)
            @test path(z) == UInt8[]

            # reset!
            descend_to!(z, UInt8[9])
            @test val(z) == UInt32(999)
            reset!(z)
            @test at_root(z)
        end

        @testset "child_count + child_mask" begin
            z = ReadZipper(t)
            # Root has two children: byte 1 and byte 9
            @test child_count(z) == 2
            m = child_mask(z)
            @test m[Int(UInt8(1)) + 1]
            @test m[Int(UInt8(9)) + 1]
            @test !m[Int(UInt8(5)) + 1]
            @test count(m) == 2

            descend_to_byte!(z, UInt8(1))
            descend_to_byte!(z, UInt8(2))
            # [1,2] branches into 3 and 4
            @test child_count(z) == 2
            m = child_mask(z)
            @test m[Int(UInt8(3)) + 1]
            @test m[Int(UInt8(4)) + 1]
            @test count(m) == 2
        end
    end

    @testset "Phase 1a — WriteZipper" begin
        @testset "set_val! returns previous value" begin
            t = PathTrie{UInt32}()
            w = WriteZipper(t)

            # Descend to path that doesn't exist yet — need to create it first
            create_path!(w, UInt8[1, 2, 3])
            @test descend_to!(w, UInt8[1, 2, 3])

            # Set a value, no previous
            prev = set_val!(w, UInt32(42))
            @test prev === nothing
            @test is_val(w)
            @test val(w) == UInt32(42)

            # Overwrite, previous returned
            prev = set_val!(w, UInt32(100))
            @test prev == UInt32(42)
            @test val(w) == UInt32(100)

            # Verify the trie sees it
            @test t[UInt8[1, 2, 3]] == UInt32(100)
        end

        @testset "remove_val! preserves structure (dangling)" begin
            t = PathTrie{UInt32}()
            t[UInt8[1, 2]] = UInt32(5)
            t[UInt8[1, 2, 3]] = UInt32(10)

            w = WriteZipper(t)
            descend_to!(w, UInt8[1, 2, 3])
            prev = remove_val!(w)
            @test prev == UInt32(10)
            @test !is_val(w)
            @test val(w) === nothing

            # The path still exists structurally
            @test path_exists_at(t, UInt8[1, 2, 3])
            # But no longer has a value
            @test !haskey(t, UInt8[1, 2, 3])
            # The parent value is untouched
            @test t[UInt8[1, 2]] == UInt32(5)
        end

        @testset "zipper create_path! (scoped to current focus)" begin
            t = PathTrie{UInt32}()
            w = WriteZipper(t)

            # Descend requires path to exist; for first-time creation, use
            # zipper create_path! from the root.
            create_path!(w, UInt8[1, 2])
            @test descend_to!(w, UInt8[1, 2])

            # Now create a further path relative to [1,2]
            create_path!(w, UInt8[3, 4])
            # Focus unchanged
            @test path(w) == UInt8[1, 2]
            # But the absolute path [1,2,3,4] now exists as dangling
            @test path_exists_at(t, UInt8[1, 2, 3, 4])
            @test !haskey(t, UInt8[1, 2, 3, 4])
        end
    end
end
