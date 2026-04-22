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

    @testset "Phase 1b — stepping: descend_first_byte! + descend_indexed_byte!" begin
        t = PathTrie{UInt32}()
        # Root children at bytes {3, 7, 12}
        t[UInt8[3]]  = UInt32(30)
        t[UInt8[7]]  = UInt32(70)
        t[UInt8[12]] = UInt32(120)

        # descend_first_byte! → byte 3 (smallest)
        z = ReadZipper(t)
        @test descend_first_byte!(z)
        @test path(z) == UInt8[3]
        @test val(z) == UInt32(30)

        # descend_indexed_byte! (1-based Julia convention)
        z2 = ReadZipper(t)
        @test descend_indexed_byte!(z2, 1)       # smallest → 3
        @test path(z2) == UInt8[3]

        z3 = ReadZipper(t)
        @test descend_indexed_byte!(z3, 2)       # middle → 7
        @test path(z3) == UInt8[7]
        @test val(z3) == UInt32(70)

        z4 = ReadZipper(t)
        @test descend_indexed_byte!(z4, 3)       # last → 12
        @test path(z4) == UInt8[12]
        @test val(z4) == UInt32(120)

        # Out-of-range index → false, focus unchanged
        z5 = ReadZipper(t)
        @test !descend_indexed_byte!(z5, 0)      # 0 invalid (1-based)
        @test at_root(z5)
        @test !descend_indexed_byte!(z5, 4)      # past end
        @test at_root(z5)

        # Empty node has no first byte
        t_empty = PathTrie{UInt32}()
        z_empty = ReadZipper(t_empty)
        @test !descend_first_byte!(z_empty)
        @test at_root(z_empty)
    end

    @testset "Phase 1b — jumping: descend_to_existing! + descend_to_val!" begin
        t = PathTrie{UInt32}()
        t[UInt8[1, 2, 3]] = UInt32(123)
        # Notice [1,2,3,4] is NOT in the trie; [1,2,3] is the deepest match

        @testset "descend_to_existing! — partial walk, commits partial" begin
            z = ReadZipper(t)
            consumed = descend_to_existing!(z, UInt8[1, 2, 3, 4, 5])
            @test consumed == 3                    # got through [1,2,3]
            @test path(z) == UInt8[1, 2, 3]        # focus committed to partial walk
            @test val(z) == UInt32(123)

            # All bytes match → consumed == length
            z2 = ReadZipper(t)
            consumed = descend_to_existing!(z2, UInt8[1, 2, 3])
            @test consumed == 3
            @test path(z2) == UInt8[1, 2, 3]

            # Nothing matches → consumed == 0, focus unchanged
            z3 = ReadZipper(t)
            consumed = descend_to_existing!(z3, UInt8[9, 9, 9])
            @test consumed == 0
            @test at_root(z3)

            # Empty path → consumed == 0
            z4 = ReadZipper(t)
            @test descend_to_existing!(z4, UInt8[]) == 0
            @test at_root(z4)
        end

        @testset "descend_to_val! — stops at value" begin
            # Two values along a path: [1,2] and [1,2,3]
            t2 = PathTrie{UInt32}()
            t2[UInt8[1, 2]]    = UInt32(12)
            t2[UInt8[1, 2, 3]] = UInt32(123)

            # Walk [1,2,3]: stops at [1,2] because it has a value
            z = ReadZipper(t2)
            consumed = descend_to_val!(z, UInt8[1, 2, 3])
            @test consumed == 2
            @test path(z) == UInt8[1, 2]
            @test val(z) == UInt32(12)

            # Already on a value → consumed == 0
            z2 = ReadZipper(t2)
            descend_to!(z2, UInt8[1, 2])
            consumed = descend_to_val!(z2, UInt8[3])
            @test consumed == 0
            @test path(z2) == UInt8[1, 2]

            # No value in the path — walks to end (same as descend_to_existing)
            t3 = PathTrie{UInt32}()
            t3[UInt8[1, 2, 3]] = UInt32(999)
            z3 = ReadZipper(t3)
            consumed = descend_to_val!(z3, UInt8[1, 2, 3])
            @test consumed == 3
            @test val(z3) == UInt32(999)
        end
    end

    @testset "Phase 1b — descend_until! / ascend_until! / ascend_until_branch!" begin
        # Build: root → 1 → 2 → 3 → (branches: 4=val_400, 5=val_500)
        # From root, following byte 1 gives a single-child chain until byte 3,
        # where a branch exists.
        t = PathTrie{UInt32}()
        t[UInt8[1, 2, 3, 4]] = UInt32(400)
        t[UInt8[1, 2, 3, 5]] = UInt32(500)

        @testset "descend_until! skips single-child corridor" begin
            z = ReadZipper(t)
            # From root, descend through [1,2,3] (all single-child), stops at 3 (branch)
            consumed = descend_until!(z)
            @test consumed == 3
            @test path(z) == UInt8[1, 2, 3]
            @test !is_val(z)                       # [1,2,3] has no value, just branches
            @test child_count(z) == 2              # branch point

            # Re-run: already at a branch, no descent
            consumed2 = descend_until!(z)
            @test consumed2 == 0

            # Single-child chain ending in a value
            t2 = PathTrie{UInt32}()
            t2[UInt8[1, 2, 3]] = UInt32(123)       # linear to leaf
            z2 = ReadZipper(t2)
            consumed = descend_until!(z2)
            @test consumed == 3
            @test is_val(z2)                       # stops AT the value
            @test val(z2) == UInt32(123)

            # Single-child chain with a value mid-way
            t3 = PathTrie{UInt32}()
            t3[UInt8[1, 2]]    = UInt32(12)        # value at mid
            t3[UInt8[1, 2, 3]] = UInt32(123)       # deeper value
            z3 = ReadZipper(t3)
            consumed = descend_until!(z3)
            @test consumed == 2                    # stopped at [1,2]'s value
            @test val(z3) == UInt32(12)
        end

        @testset "ascend_until! stops at branch, value, or origin" begin
            z = ReadZipper(t)
            descend_to!(z, UInt8[1, 2, 3, 4])
            @test val(z) == UInt32(400)

            # Ascend: [1,2,3,4] → [1,2,3] is a branch point (2 children), stop there
            consumed = ascend_until!(z)
            @test consumed == 1
            @test path(z) == UInt8[1, 2, 3]
            @test child_count(z) == 2

            # Continue ascending: [1,2,3] has >1 children, already stopped.
            # Descend again, force another ascent to root (no intermediate stops)
            descend_to!(z, UInt8[4])             # into the branch
            ascend_until!(z)                     # back to [1,2,3]
            @test path(z) == UInt8[1, 2, 3]

            # ascend_until from a non-branch, non-value path → goes all the way to origin
            t2 = PathTrie{UInt32}()
            t2[UInt8[1, 2, 3, 4]] = UInt32(999)   # linear single-child
            z2 = ReadZipper(t2)
            descend_to!(z2, UInt8[1, 2, 3, 4])
            consumed = ascend_until!(z2)
            @test at_root(z2)                     # walked all the way up
            @test consumed == 4
        end

        @testset "ascend_until_branch! ignores values" begin
            # Path with a value mid-way: [1,2] value, [1,2,3,4] value
            t2 = PathTrie{UInt32}()
            t2[UInt8[1, 2]]       = UInt32(12)
            t2[UInt8[1, 2, 3, 4]] = UInt32(1234)

            # Not a branch anywhere — strict chain from root
            z = ReadZipper(t2)
            descend_to!(z, UInt8[1, 2, 3, 4])

            # ascend_until! stops at [1,2] (value), 2 steps
            z_val = ReadZipper(t2)
            descend_to!(z_val, UInt8[1, 2, 3, 4])
            @test ascend_until!(z_val) == 2
            @test path(z_val) == UInt8[1, 2]

            # ascend_until_branch! ignores the value at [1,2], keeps going to root
            z_br = ReadZipper(t2)
            descend_to!(z_br, UInt8[1, 2, 3, 4])
            @test ascend_until_branch!(z_br) == 4
            @test at_root(z_br)

            # With a true branch mid-way: [1,2] has 2 children
            t3 = PathTrie{UInt32}()
            t3[UInt8[1, 2, 3]] = UInt32(123)
            t3[UInt8[1, 2, 9]] = UInt32(129)
            z3 = ReadZipper(t3)
            descend_to!(z3, UInt8[1, 2, 3])
            @test ascend_until_branch!(z3) == 1   # stops at [1,2] branch
            @test path(z3) == UInt8[1, 2]
        end
    end

    @testset "Phase 1b — sibling navigation" begin
        t = PathTrie{UInt32}()
        # Root has children 3, 7, 12
        t[UInt8[3]]  = UInt32(30)
        t[UInt8[7]]  = UInt32(70)
        t[UInt8[12]] = UInt32(120)

        @testset "to_next_sibling_byte! — ascending order" begin
            z = ReadZipper(t)
            descend_to_byte!(z, UInt8(3))
            @test val(z) == UInt32(30)

            @test to_next_sibling_byte!(z)       # 3 → 7
            @test path(z) == UInt8[7]
            @test val(z) == UInt32(70)

            @test to_next_sibling_byte!(z)       # 7 → 12
            @test path(z) == UInt8[12]
            @test val(z) == UInt32(120)

            @test !to_next_sibling_byte!(z)      # no next — unchanged
            @test path(z) == UInt8[12]
        end

        @testset "to_prev_sibling_byte! — descending order" begin
            z = ReadZipper(t)
            descend_to_byte!(z, UInt8(12))

            @test to_prev_sibling_byte!(z)       # 12 → 7
            @test path(z) == UInt8[7]

            @test to_prev_sibling_byte!(z)       # 7 → 3
            @test path(z) == UInt8[3]

            @test !to_prev_sibling_byte!(z)      # no prev — unchanged
            @test path(z) == UInt8[3]
        end

        @testset "sibling nav at root → false" begin
            z = ReadZipper(t)
            @test !to_next_sibling_byte!(z)      # no parent
            @test !to_prev_sibling_byte!(z)
            @test at_root(z)
        end

        @testset "sibling enumeration via repeated nav" begin
            z = ReadZipper(t)
            descend_first_byte!(z)               # 3
            collected = UInt8[path(z)[end]]
            while to_next_sibling_byte!(z)
                push!(collected, path(z)[end])
            end
            @test collected == UInt8[3, 7, 12]
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
