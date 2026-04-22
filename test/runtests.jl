using Test
using MORK

@testset "MORK" begin
    @testset "Phase 0 skeleton" begin
        @test MORK.version() == v"0.1.0"
    end

    @testset "Ring (ports pathmap/src/ring.rs)" begin
        @testset "Identity-mask constants" begin
            @test SELF_IDENT == UInt64(0x1)
            @test COUNTER_IDENT == UInt64(0x2)
            @test (SELF_IDENT & COUNTER_IDENT) == 0
        end

        @testset "AlgebraicResult variants + predicates" begin
            n = AlgResNone()
            @test is_none(n)
            @test !is_identity(n)
            @test !is_element(n)
            @test identity_mask(n) === nothing

            id = AlgResIdentity(SELF_IDENT)
            @test !is_none(id)
            @test is_identity(id)
            @test !is_element(id)
            @test identity_mask(id) == SELF_IDENT

            el = AlgResElement(UInt32(42))
            @test !is_none(el)
            @test !is_identity(el)
            @test is_element(el)
            @test identity_mask(el) === nothing
            @test el.value == UInt32(42)
        end

        @testset "invert_identity" begin
            # No-op for None and Element
            @test invert_identity(AlgResNone()) isa AlgResNone
            @test invert_identity(AlgResElement(42)).value == 42
            # Swap bits 0 and 1 for Identity
            @test invert_identity(AlgResIdentity(SELF_IDENT)).mask == COUNTER_IDENT
            @test invert_identity(AlgResIdentity(COUNTER_IDENT)).mask == SELF_IDENT
            @test invert_identity(AlgResIdentity(SELF_IDENT | COUNTER_IDENT)).mask ==
                  (SELF_IDENT | COUNTER_IDENT)
            # Higher bits are removed
            @test invert_identity(AlgResIdentity(UInt64(0xFF))).mask ==
                  (SELF_IDENT | COUNTER_IDENT)
        end

        @testset "map / map_into_option / into_option / unwrap_or_else" begin
            # map
            @test Base.map(x -> x + 1, AlgResElement(5)).value == 6
            @test Base.map(x -> x + 1, AlgResNone()) isa AlgResNone
            @test Base.map(x -> x + 1, AlgResIdentity(SELF_IDENT)).mask == SELF_IDENT

            # map_into_option
            @test map_into_option(AlgResElement(42), i -> 99) == 42
            @test map_into_option(AlgResNone(), i -> 99) === nothing
            # Identity(SELF_IDENT) → trailing_zeros(1) == 0 → ident_f(0)
            @test map_into_option(AlgResIdentity(SELF_IDENT), i -> i == 0 ? "self" : "other") == "self"
            @test map_into_option(AlgResIdentity(COUNTER_IDENT), i -> i == 1 ? "other" : "self") == "other"

            # into_option with idents table (1-indexed in Julia, 0-indexed in Rust)
            @test into_option(AlgResElement(42), ["a", "b"]) == 42
            @test into_option(AlgResNone(), ["a", "b"]) === nothing
            @test into_option(AlgResIdentity(SELF_IDENT), ["a", "b"]) == "a"
            @test into_option(AlgResIdentity(COUNTER_IDENT), ["a", "b"]) == "b"

            # unwrap_or_else
            @test unwrap_or_else(AlgResElement(42), i -> 99, () -> 0) == 42
            @test unwrap_or_else(AlgResNone(), i -> 99, () -> 0) == 0
            @test unwrap_or_else(AlgResIdentity(SELF_IDENT), i -> i + 10, () -> 0) == 10
        end

        @testset "AlgebraicStatus" begin
            @test ALG_STATUS_ELEMENT < ALG_STATUS_IDENTITY < ALG_STATUS_NONE
            @test is_none(ALG_STATUS_NONE)
            @test is_identity(ALG_STATUS_IDENTITY)
            @test is_element(ALG_STATUS_ELEMENT)
            @test !is_none(ALG_STATUS_ELEMENT)
        end

        @testset "merge_status" begin
            # All 9 cells of the merge table from upstream ring.rs:374-396
            @test merge_status(ALG_STATUS_NONE,     ALG_STATUS_NONE,     true, true)  == ALG_STATUS_NONE
            @test merge_status(ALG_STATUS_NONE,     ALG_STATUS_ELEMENT,  true, true)  == ALG_STATUS_ELEMENT
            @test merge_status(ALG_STATUS_NONE,     ALG_STATUS_IDENTITY, true, true)  == ALG_STATUS_IDENTITY
            @test merge_status(ALG_STATUS_NONE,     ALG_STATUS_IDENTITY, false, true) == ALG_STATUS_ELEMENT

            @test merge_status(ALG_STATUS_IDENTITY, ALG_STATUS_ELEMENT,  true, true)  == ALG_STATUS_ELEMENT
            @test merge_status(ALG_STATUS_IDENTITY, ALG_STATUS_IDENTITY, true, true)  == ALG_STATUS_IDENTITY
            @test merge_status(ALG_STATUS_IDENTITY, ALG_STATUS_NONE,     true, true)  == ALG_STATUS_IDENTITY
            @test merge_status(ALG_STATUS_IDENTITY, ALG_STATUS_NONE,     true, false) == ALG_STATUS_ELEMENT

            @test merge_status(ALG_STATUS_ELEMENT,  ALG_STATUS_NONE,     true, true)  == ALG_STATUS_ELEMENT
            @test merge_status(ALG_STATUS_ELEMENT,  ALG_STATUS_IDENTITY, true, true)  == ALG_STATUS_ELEMENT
            @test merge_status(ALG_STATUS_ELEMENT,  ALG_STATUS_ELEMENT,  true, true)  == ALG_STATUS_ELEMENT
        end

        @testset "status + from_status roundtrip" begin
            @test status(AlgResNone()) == ALG_STATUS_NONE
            @test status(AlgResElement(1)) == ALG_STATUS_ELEMENT
            @test status(AlgResIdentity(SELF_IDENT)) == ALG_STATUS_IDENTITY
            @test status(AlgResIdentity(COUNTER_IDENT)) == ALG_STATUS_ELEMENT  # no SELF_IDENT bit
            @test status(AlgResIdentity(SELF_IDENT | COUNTER_IDENT)) == ALG_STATUS_IDENTITY

            @test from_status(ALG_STATUS_NONE, () -> 42) isa AlgResNone
            @test from_status(ALG_STATUS_IDENTITY, () -> 42).mask == SELF_IDENT
            @test from_status(ALG_STATUS_ELEMENT, () -> 42).value == 42
        end

        @testset "flatten (AlgebraicResult{Union{Nothing, V}} -> AlgebraicResult{V})" begin
            @test flatten(AlgResNone()) isa AlgResNone
            @test flatten(AlgResIdentity(SELF_IDENT)).mask == SELF_IDENT
            @test flatten(AlgResElement(42)).value == 42
            @test flatten(AlgResElement(nothing)) isa AlgResNone
        end

        @testset "FatAlgebraicResult + to_algebraic_result" begin
            # none
            fn = fat_none(UInt32)
            @test fn.identity_mask == 0
            @test fn.element === nothing
            @test to_algebraic_result(fn) isa AlgResNone

            # element
            fe = fat_element(UInt32(42))
            @test fe.identity_mask == 0
            @test fe.element == UInt32(42)
            r = to_algebraic_result(fe)
            @test r isa AlgResElement
            @test r.value == UInt32(42)

            # identity
            fi = FatAlgebraicResult{UInt32}(SELF_IDENT, UInt32(5))
            r = to_algebraic_result(fi)
            @test r isa AlgResIdentity
            @test r.mask == SELF_IDENT
        end

        @testset "Lattice on integers (pjoin=max, pmeet=min)" begin
            # pjoin = max
            r = pjoin(UInt32(3), UInt32(7))
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT   # result = other (7)

            r = pjoin(UInt32(7), UInt32(3))
            @test r isa AlgResIdentity && r.mask == SELF_IDENT      # result = self

            r = pjoin(UInt32(5), UInt32(5))
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            # pmeet = min
            r = pmeet(UInt32(3), UInt32(7))
            @test r isa AlgResIdentity && r.mask == SELF_IDENT      # result = self (3)

            r = pmeet(UInt32(7), UInt32(3))
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT
        end

        @testset "DistributiveLattice on unsigned ints (psubtract = saturating sub)" begin
            # b >= a → None
            @test psubtract(UInt32(3), UInt32(7)) isa AlgResNone
            @test psubtract(UInt32(5), UInt32(5)) isa AlgResNone

            # b == 0 → Identity (result unchanged)
            r = psubtract(UInt32(5), UInt32(0))
            @test r isa AlgResIdentity && r.mask == SELF_IDENT

            # b > 0, a > b → Element(a - b)
            r = psubtract(UInt32(10), UInt32(3))
            @test r isa AlgResElement && r.value == UInt32(7)
        end

        @testset "Lattice on Bool (pjoin=or, pmeet=and)" begin
            # pjoin
            r = pjoin(false, false)
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            r = pjoin(true, false)
            @test r isa AlgResIdentity && r.mask == SELF_IDENT

            r = pjoin(false, true)
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT

            # pmeet
            r = pmeet(true, true)
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            r = pmeet(true, false)
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT  # result = false = other

            # psubtract
            @test psubtract(false, false) isa AlgResNone
            @test psubtract(false, true) isa AlgResNone
            @test psubtract(true, true) isa AlgResNone
            r = psubtract(true, false)
            @test r isa AlgResIdentity && r.mask == SELF_IDENT
        end

        @testset "Blanket Lattice on Union{Nothing, V}" begin
            # Matches Rust's `impl<V: Lattice + Clone> Lattice for Option<V>`

            # pjoin(Nothing, Nothing) → Identity(both)
            r = pjoin(nothing, nothing)
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            # pjoin(Nothing, Some) → Identity(COUNTER)
            r = pjoin(nothing, UInt32(5))
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT

            # pjoin(Some, Nothing) → Identity(SELF)
            r = pjoin(UInt32(5), nothing)
            @test r isa AlgResIdentity && r.mask == SELF_IDENT

            # pjoin(Some, Some) → delegate to inner
            r = pjoin(UInt32(3), UInt32(7))
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT

            # pmeet(Nothing, Nothing) → Identity(both)
            r = pmeet(nothing, nothing)
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            # pmeet(Nothing, Some) → Element(nothing) (empty result)
            r = pmeet(nothing, UInt32(5))
            @test r isa AlgResElement && r.value === nothing
        end

        @testset "join_all" begin
            # empty → None
            @test join_all(UInt32[]) isa AlgResNone

            # single element → Identity(SELF)
            r = join_all([UInt32(42)])
            @test r isa AlgResIdentity
            @test (r.mask & SELF_IDENT) > 0

            # [3, 7] → max is 7 = second element
            r = join_all([UInt32(3), UInt32(7)])
            @test r isa AlgResIdentity || r isa AlgResElement
            if r isa AlgResElement
                @test r.value == UInt32(7)
            end

            # All equal → Identity with all bits
            r = join_all([UInt32(5), UInt32(5), UInt32(5)])
            @test is_identity(r) || is_element(r)
        end
    end
end
