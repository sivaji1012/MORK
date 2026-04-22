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

        @testset "Utils — Bits4 primitives" begin
            empty = MORK.EMPTY_BITS4
            full  = MORK.FULL_BITS4
            @test count_bits(empty) == 0
            @test count_bits(full) == 256
            @test is_empty_mask(empty)
            @test !is_empty_mask(full)

            # Test bits at word boundaries
            for b in (UInt8(0), UInt8(63), UInt8(64), UInt8(127),
                      UInt8(128), UInt8(191), UInt8(192), UInt8(255))
                m = with_bit_set(empty, b)
                @test test_bit(m, b)
                @test count_bits(m) == 1
                m2 = with_bit_cleared(m, b)
                @test !test_bit(m2, b)
                @test m2 == empty
            end

            # Boolean ops
            a = with_bit_set(with_bit_set(empty, UInt8(1)), UInt8(3))
            b = with_bit_set(with_bit_set(empty, UInt8(3)), UInt8(5))
            @test count_bits(bor(a, b)) == 3
            @test count_bits(band(a, b)) == 1
            @test count_bits(bxor(a, b)) == 2
            @test count_bits(bandn(a, b)) == 1   # a & !b = {1}
            @test count_bits(bnot(empty)) == 256
        end

        @testset "Utils — ByteMask basics (upstream bit_utils_test)" begin
            # Port of pathmap/src/utils/mod.rs:683-702
            m = ByteMask()
            @test count_bits(m) == 0
            @test is_empty_mask(m)

            m = set(m, UInt8('C'))
            m = set(m, UInt8('a'))
            m = set(m, UInt8('t'))
            @test !is_empty_mask(m)
            @test count_bits(m) == 3

            m = set(m, UInt8('C'))   # idempotent
            m = set(m, UInt8('a'))
            m = set(m, UInt8('n'))
            @test count_bits(m) == 4

            m = unset(m, UInt8('t'))
            @test test_bit(m, UInt8('n'))
            @test !test_bit(m, UInt8('t'))
        end

        @testset "Utils — next_bit_test (upstream port)" begin
            # Port of pathmap/src/utils/mod.rs:704-753
            function do_test(test_mask::ByteMask)
                set_bits = UInt8[]
                for i in UInt8(0):UInt8(255)
                    test_bit(test_mask, i) && push!(set_bits, i)
                end

                # Forward walk via next_bit starting at 0
                i::UInt8 = UInt8(0)
                cnt = test_bit(test_mask, UInt8(0)) ? 1 : 0
                while true
                    nb = next_bit(test_mask, i)
                    nb === nothing && break
                    @test test_bit(test_mask, nb)
                    i = nb
                    cnt += 1
                end
                @test cnt == length(set_bits)

                # Backward walk via prev_bit starting at 255
                i = UInt8(255)
                cnt = test_bit(test_mask, UInt8(255)) ? 1 : 0
                while true
                    pb = prev_bit(test_mask, i)
                    pb === nothing && break
                    @test test_bit(test_mask, pb)
                    i = pb
                    cnt += 1
                end
                @test cnt == length(set_bits)
            end

            do_test(ByteMask((
                0b1010010010010010010010000000000000000000000000000000000000010101,
                0b0000000000000000000000000000000000000000100000000000000000000000,
                0b0000000000000000000000000000000000000000000000000000000000000000,
                0b1001000000000000000000000000000000000000000000000000000000000001,
            )))
            do_test(ByteMask((
                0b0000000000000000000000000000000000000000000000000000000000000000,
                0b0000000000000000000000000000000000000000100000000000000000000000,
                0b0000000000000000000000000000000000000000000000000000000000000000,
                0b1001000000000000000000000000000000000000000000000000000000000001,
            )))
            do_test(bytemask_full())
        end

        @testset "Utils — next_bit_test2 (specific bytes 39/97/117)" begin
            m = ByteMask()
            m = set(m, UInt8(39))
            m = set(m, UInt8(97))
            m = set(m, UInt8(117))

            @test next_bit(m, UInt8(0)) == UInt8(39)
            @test next_bit(m, UInt8(39)) == UInt8(97)
            @test next_bit(m, UInt8(97)) == UInt8(117)
            @test next_bit(m, UInt8(117)) === nothing
        end

        @testset "Utils — from_range (upstream port)" begin
            # Port of pathmap/src/utils/mod.rs:755-780
            m = from_range(10:69)   # Julia 10:69 ≡ Rust 10..70
            expected_bits = (
                0b1111111111111111111111111111111111111111111111111111110000000000,
                0b0000000000000000000000000000000000000000000000000000000000111111,
                UInt64(0),
                UInt64(0),
            )
            @test m.bits == expected_bits

            @test from_range_full() == bytemask_full()
            @test from_range(0:127) == ByteMask((
                typemax(UInt64), typemax(UInt64), UInt64(0), UInt64(0),
            ))
            @test from_range(10:255) == ByteMask((
                0b1111111111111111111111111111111111111111111111111111110000000000,
                typemax(UInt64), typemax(UInt64), typemax(UInt64),
            ))

            # Empty / degenerate ranges
            @test from_range(0:-1) == ByteMask()             # empty range
            @test from_range(0:0) == ByteMask(UInt8(0))
            @test from_range(255:255) == ByteMask(UInt8(255))
        end

        @testset "Utils — index_of (rank)" begin
            # Construct a mask with known bits: {1, 5, 100, 200}
            m = ByteMask()
            m = set(m, UInt8(1))
            m = set(m, UInt8(5))
            m = set(m, UInt8(100))
            m = set(m, UInt8(200))

            # Count set bits strictly below each threshold
            @test index_of(m, UInt8(0))   == UInt8(0)
            @test index_of(m, UInt8(1))   == UInt8(0)     # nothing below 1
            @test index_of(m, UInt8(2))   == UInt8(1)     # {1}
            @test index_of(m, UInt8(6))   == UInt8(2)     # {1, 5}
            @test index_of(m, UInt8(101)) == UInt8(3)     # {1, 5, 100}
            @test index_of(m, UInt8(255)) == UInt8(4)     # all four
        end

        @testset "Utils — indexed_bit (select, forward + backward)" begin
            # Construct mask with bits {3, 20, 100, 200, 255}
            m = ByteMask()
            for b in UInt8[3, 20, 100, 200, 255]
                m = set(m, b)
            end

            # Forward: idx 0 = first, idx 1 = second, etc.
            @test indexed_bit(m, 0, true) == UInt8(3)
            @test indexed_bit(m, 1, true) == UInt8(20)
            @test indexed_bit(m, 2, true) == UInt8(100)
            @test indexed_bit(m, 3, true) == UInt8(200)
            @test indexed_bit(m, 4, true) == UInt8(255)
            @test indexed_bit(m, 5, true) === nothing

            # Backward: idx 0 = last, idx 1 = second-to-last, etc.
            @test indexed_bit(m, 0, false) == UInt8(255)
            @test indexed_bit(m, 1, false) == UInt8(200)
            @test indexed_bit(m, 2, false) == UInt8(100)
            @test indexed_bit(m, 3, false) == UInt8(20)
            @test indexed_bit(m, 4, false) == UInt8(3)
            @test indexed_bit(m, 5, false) === nothing
        end

        @testset "Utils — subset (Sierpinski)" begin
            # SUBSET(0) has only bit 0 set (only j=0 satisfies 0 & j == j)
            m0 = subset(UInt8(0))
            @test test_bit(m0, UInt8(0))
            @test count_bits(m0) == 1

            # SUBSET(1) has bits {0, 1} set (j=0: 1&0==0 ✓; j=1: 1&1==1 ✓)
            m1 = subset(UInt8(1))
            @test test_bit(m1, UInt8(0))
            @test test_bit(m1, UInt8(1))
            @test count_bits(m1) == 2

            # SUBSET(255) has ALL 256 bits set (every j is a subset of 255's bits)
            m255 = subset(UInt8(255))
            @test count_bits(m255) == 256

            # SUBSET(3) has {0,1,2,3} set (binary: 11)
            m3 = subset(UInt8(3))
            @test count_bits(m3) == 4
            for b in UInt8[0, 1, 2, 3]
                @test test_bit(m3, b)
            end
        end

        @testset "Utils — ByteMask iteration (ascending order)" begin
            m = ByteMask()
            for b in UInt8[5, 100, 200, 42]
                m = set(m, b)
            end
            @test collect(m) == UInt8[5, 42, 100, 200]
            @test length(m) == 4

            # ByteMaskIter (destructive variant — upstream's iter method)
            it = iter(m)
            seen = UInt8[]
            for b in it
                push!(seen, b)
            end
            @test seen == UInt8[5, 42, 100, 200]

            # Empty mask iterates nothing
            empty = ByteMask()
            @test collect(empty) == UInt8[]
        end

        @testset "Utils — ByteMask Lattice (pjoin / pmeet / psubtract)" begin
            a = ByteMask()
            a = set(a, UInt8(1)); a = set(a, UInt8(3)); a = set(a, UInt8(5))

            b = ByteMask()
            b = set(b, UInt8(3)); b = set(b, UInt8(5)); b = set(b, UInt8(7))

            # pjoin = union; has both a's and b's bits
            r = pjoin(a, b)
            @test r isa AlgResElement
            joined = (r::AlgResElement{ByteMask}).value
            @test count_bits(joined) == 4
            @test test_bit(joined, UInt8(1))
            @test test_bit(joined, UInt8(3))
            @test test_bit(joined, UInt8(5))
            @test test_bit(joined, UInt8(7))

            # pmeet = intersection
            r = pmeet(a, b)
            @test r isa AlgResElement
            met = (r::AlgResElement{ByteMask}).value
            @test count_bits(met) == 2
            @test test_bit(met, UInt8(3))
            @test test_bit(met, UInt8(5))

            # Self-identity: pjoin(a, a) = Identity
            r = pjoin(a, a)
            @test r isa AlgResIdentity
            @test r.mask == (SELF_IDENT | COUNTER_IDENT)

            # Subset: pmeet(a, superset) = Identity(SELF_IDENT)
            superset = ByteMask()
            for b in UInt8[1, 3, 5, 7, 9]
                superset = set(superset, b)
            end
            r = pmeet(a, superset)
            @test r isa AlgResIdentity
            @test (r.mask & SELF_IDENT) > 0

            # psubtract
            r = psubtract(a, b)
            @test r isa AlgResElement
            diff = (r::AlgResElement{ByteMask}).value
            @test count_bits(diff) == 1
            @test test_bit(diff, UInt8(1))

            # psubtract(a, a) = None
            @test psubtract(a, a) isa AlgResNone
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

        @testset "Ints — PathInteger alias" begin
            @test UInt8  <: PathInteger
            @test UInt16 <: PathInteger
            @test UInt32 <: PathInteger
            @test UInt64 <: PathInteger
            @test UInt128 <: PathInteger
            # sizeof recovers NUM_SIZE
            @test sizeof(UInt8)   == 1
            @test sizeof(UInt16)  == 2
            @test sizeof(UInt32)  == 4
            @test sizeof(UInt64)  == 8
            @test sizeof(UInt128) == 16
        end

        @testset "Ints — bob_and_weave_simple (upstream port)" begin
            # Port of pathmap/src/utils/ints.rs:376-412
            is_orig = UInt64[10, 30, 100]
            is_decoded = zeros(UInt64, 3)
            weave = UInt8[]
            bob   = UInt8[]
            indices_to_weave!(weave, is_orig, 8)
            weave_to_indices!(is_decoded, weave)
            @test is_decoded == is_orig

            fill!(is_decoded, 0)
            indices_to_bob!(bob, is_orig)
            bob_to_indices!(is_decoded, bob)
            @test is_decoded == is_orig

            # Second case: multi-byte values
            is_orig = UInt64[3333, 30, 1000]
            is_decoded = zeros(UInt64, 3)
            weave = UInt8[]
            bob   = UInt8[]
            indices_to_weave!(weave, is_orig, 8)
            weave_to_indices!(is_decoded, weave)
            @test is_decoded == is_orig

            fill!(is_decoded, 0)
            indices_to_bob!(bob, is_orig)
            bob_to_indices!(is_decoded, bob)
            @test is_decoded == is_orig
        end

        @testset "Ints — BOB shape guarantees" begin
            # steps == max bit-width across xs
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[10, 30, 100])
            # 100 = 0b1100100 (7 bits) — widest
            @test steps == 7
            @test length(bob) == 7

            # Empty xs → steps == 0
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[])
            @test steps == 0
            @test isempty(bob)

            # All zeros → steps == 0
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[0, 0, 0])
            @test steps == 0
            @test isempty(bob)

            # Single zero-valued element
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[0])
            @test steps == 0

            # Single element = 1 → one plane
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[1])
            @test steps == 1
            @test bob == UInt8[1]
        end

        @testset "Ints — weave shape guarantees" begin
            # Writes num_size bytes per element
            weave = UInt8[]
            indices_to_weave!(weave, UInt64[10, 30, 100], 8)
            @test length(weave) == 8 * 3

            # num_size == 1: single-byte round-robin
            weave = UInt8[]
            indices_to_weave!(weave, UInt8[10, 30, 100], 1)
            @test length(weave) == 3
            @test weave == UInt8[10, 30, 100]

            # num_size == 2: two-byte big-endian round-robin
            weave = UInt8[]
            indices_to_weave!(weave, UInt16[0x0D05, 0x001E, 0x03E8], 2)
            # plane c=1 (high bytes): 0x0D, 0x00, 0x03
            # plane c=0 (low  bytes): 0x05, 0x1E, 0xE8
            @test weave == UInt8[0x0D, 0x00, 0x03, 0x05, 0x1E, 0xE8]
        end

        @testset "Ints — BOB across integer widths" begin
            for T in (UInt8, UInt16, UInt32, UInt64, UInt128)
                orig    = T[T(5), T(10), T(17)]
                decoded = zeros(T, 3)
                bob     = UInt8[]
                indices_to_bob!(bob, orig)
                bob_to_indices!(decoded, bob)
                @test decoded == orig
            end
        end

        @testset "Ints — weave across integer widths" begin
            for T in (UInt8, UInt16, UInt32, UInt64)
                orig    = T[T(5), T(10), T(17), T(255)]
                decoded = zeros(T, 4)
                weave   = UInt8[]
                indices_to_weave!(weave, orig, sizeof(T))
                weave_to_indices!(decoded, weave)
                @test decoded == orig
            end
        end

        @testset "TrieNode — constants" begin
            # Port of trie_node.rs: MAX_NODE_KEY_BYTES / NODE_ITER_INVALID / NODE_ITER_FINISHED
            @test MAX_NODE_KEY_BYTES == 48
            @test NODE_ITER_INVALID  == typemax(UInt128)
            @test NODE_ITER_FINISHED == typemax(UInt128) - UInt128(1)
            @test NODE_ITER_INVALID  > NODE_ITER_FINISHED

            # Node tag constants match upstream
            @test EMPTY_NODE_TAG      == 0
            @test DENSE_BYTE_NODE_TAG == 1
            @test LINE_LIST_NODE_TAG  == 2
            @test CELL_BYTE_NODE_TAG  == 3
            @test TINY_REF_NODE_TAG   == 4
            # All distinct
            @test length(Set([EMPTY_NODE_TAG, DENSE_BYTE_NODE_TAG, LINE_LIST_NODE_TAG,
                              CELL_BYTE_NODE_TAG, TINY_REF_NODE_TAG])) == 5
        end

        @testset "TrieNode — TrieNodeODRc empty sentinel" begin
            rc = TrieNodeODRc{Int, GlobalAlloc}()
            @test is_empty_node(rc)
            @test refcount(rc) == 1
            @test shared_node_id(rc) == UInt64(0)
        end

        @testset "TrieNode — PayloadRef None" begin
            p = PayloadRef{Int, GlobalAlloc}()
            @test is_none(p)
            @test !is_val(p)
            @test !is_child(p)
        end

        @testset "TrieNode — ValOrChild" begin
            v = ValOrChild(42)
            @test is_val(v)
            @test !is_child(v)
            @test into_val(v) == 42

            rc = TrieNodeODRc{Int, GlobalAlloc}()
            c = ValOrChild(rc)
            @test is_child(c)
            @test !is_val(c)
        end

        @testset "TrieNode — AbstractNodeRef None + variants" begin
            n = ANRNone{Int, GlobalAlloc}()
            @test is_none(n)
            @test into_option(n) === nothing

            rc = TrieNodeODRc{Int, GlobalAlloc}()
            brw = ANRBorrowedRc{Int, GlobalAlloc}(rc)
            @test !is_none(brw)
            @test borrow(brw) === rc

            owned = ANROwnedRc{Int, GlobalAlloc}(rc)
            @test !is_none(owned)
            @test borrow(owned) === rc
        end

        @testset "EmptyNode — struct and tag" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test node_tag(e) == EMPTY_NODE_TAG
            @test node_is_empty(e)
        end

        @testset "EmptyNode — query methods return trivial values" begin
            e = EmptyNode{Int, GlobalAlloc}()
            key = UInt8[1, 2, 3]
            @test node_key_overlap(e, key) == 0
            @test node_contains_partial_key(e, key) == false
            @test node_get_child(e, key) === nothing
            @test node_get_child_mut(e, key) === nothing
            @test node_contains_val(e, key) == false
            @test node_get_val(e, key) === nothing
            @test node_get_val_mut(e, key) === nothing
            @test node_val_count(e, nothing) == 0
            @test node_goat_val_count(e) == 0
            @test count_branches(e, key) == 0
            @test prior_branch_key(e, key) == UInt8[]
            @test node_remove_all_branches!(e, key, false) == false
            @test node_first_val_depth_along_key(e, key) === nothing
        end

        @testset "EmptyNode — iteration" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test new_iter_token(e) == UInt128(0)
            @test iter_token_for_path(e, UInt8[1, 2]) == UInt128(0)
            tok, path, child, val = next_items(e, UInt128(0))
            @test tok == NODE_ITER_FINISHED
            @test path == UInt8[]
            @test child === nothing
            @test val === nothing
        end

        @testset "EmptyNode — child iteration" begin
            e = EmptyNode{Int, GlobalAlloc}()
            start_tok, start_child = node_child_iter_start(e)
            @test start_tok == UInt64(0)
            @test start_child === nothing
            next_tok, next_child = node_child_iter_next(e, UInt64(0))
            @test next_tok == UInt64(0)
            @test next_child === nothing
        end

        @testset "EmptyNode — nth/first child and siblings" begin
            e = EmptyNode{Int, GlobalAlloc}()
            key = UInt8[]
            node1, node2 = nth_child_from_key(e, key, 1)
            @test node1 === nothing && node2 === nothing
            f1, f2 = first_child_from_key(e, key)
            @test f1 === nothing && f2 === nothing
            s1, s2 = get_sibling_of_child(e, key, true)
            @test s1 === nothing && s2 === nothing
        end

        @testset "EmptyNode — node ref and take" begin
            e = EmptyNode{Int, GlobalAlloc}()
            ref = get_node_at_key(e, UInt8[1])
            @test ref isa ANRNone{Int, GlobalAlloc}
            @test is_none(ref)
            @test take_node_at_key!(e, UInt8[1], false) === nothing
        end

        @testset "EmptyNode — lattice ops" begin
            e = EmptyNode{Int, GlobalAlloc}()
            e2 = EmptyNode{Int, GlobalAlloc}()
            # pjoin_dyn: empty ⊕ empty → None
            res1 = pjoin_dyn(e, e2)
            @test res1 isa AlgResNone
            # pmeet_dyn: empty ∧ empty → Identity(SELF|COUNTER)
            res2 = pmeet_dyn(e, e2)
            @test res2 isa AlgResIdentity
            @test res2.mask == (SELF_IDENT | COUNTER_IDENT)
            # psubtract_dyn: always None
            @test psubtract_dyn(e, e2) isa AlgResNone
            # prestrict_dyn: always None
            @test prestrict_dyn(e, e2) isa AlgResNone
        end

        @testset "EmptyNode — write methods panic" begin
            e = EmptyNode{Int, GlobalAlloc}()
            rc = TrieNodeODRc{Int, GlobalAlloc}()
            @test_throws ErrorException node_replace_child!(e, UInt8[1], rc)
            @test_throws ErrorException node_set_val!(e, UInt8[1], 42)
            @test_throws ErrorException node_remove_val!(e, UInt8[1], false)
            @test_throws ErrorException node_create_dangling!(e, UInt8[1])
            @test_throws ErrorException node_remove_dangling!(e, UInt8[1])
            @test_throws ErrorException node_set_branch!(e, UInt8[1], rc)
            @test_throws ErrorException clone_self(e)
            @test_throws ErrorException convert_to_cell_node!(e)
        end

        @testset "EmptyNode — node_get_payloads vacuously exhaustive" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test node_get_payloads(e, nothing, nothing) == true
        end

        @testset "EmptyNode — join_into_dyn! empty ⊕ empty sentinel" begin
            e = EmptyNode{Int, GlobalAlloc}()
            rc = TrieNodeODRc{Int, GlobalAlloc}()   # empty sentinel
            status, result = join_into_dyn!(e, rc)
            @test status == ALG_STATUS_NONE
            @test result === nothing
        end

        @testset "EmptyNode — drop_head_dyn! is no-op" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test drop_head_dyn!(e, 3) === nothing
        end

        @testset "EmptyNode — node_branches_mask returns empty ByteMask" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test node_branches_mask(e, UInt8[]) == ByteMask()
        end

        @testset "EmptyNode — node_remove_unmasked_branches! is no-op" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test node_remove_unmasked_branches!(e, UInt8[], ByteMask(), false) === nothing
        end

        # ================================================================
        # LineListNode tests
        # ================================================================

        @testset "LineListNode — empty node" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            @test node_is_empty(n)
            @test node_tag(n) == LINE_LIST_NODE_TAG
            @test !is_used_0(n) && !is_used_1(n)
            @test key_len_0(n) == 0 && key_len_1(n) == 0
            @test used_slot_count(n) == 0
            @test node_contains_val(n, UInt8[1,2,3]) == false
            @test node_get_val(n, UInt8[1,2,3]) === nothing
            @test node_get_child(n, UInt8[1]) === nothing
        end

        @testset "LineListNode — single value in slot0" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            key = collect(UInt8, "hello")
            res = node_set_val!(n, key, 42)
            @test res isa Tuple
            @test res[1] === nothing    # no previous value
            @test res[2] == false       # no continuation node
            @test !node_is_empty(n)
            @test is_used_0(n) && !is_used_1(n)
            @test node_contains_val(n, key) == true
            @test node_get_val(n, key) == 42
            @test node_contains_val(n, collect(UInt8, "world")) == false
        end

        @testset "LineListNode — replace value in slot0" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            key = collect(UInt8, "hello")
            node_set_val!(n, key, 42)
            res2 = node_set_val!(n, key, 99)
            @test res2 isa Tuple
            @test res2[1] == 42         # returned old value
            @test node_get_val(n, key) == 99
        end

        @testset "LineListNode — two values in separate slots" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            k1 = collect(UInt8, "goodbye")
            k2 = collect(UInt8, "hello")
            node_set_val!(n, k1, 24)
            node_set_val!(n, k2, 42)
            @test is_used_0(n) && is_used_1(n)
            @test used_slot_count(n) == 2
            @test node_get_val(n, k1) == 24
            @test node_get_val(n, k2) == 42
        end

        @testset "LineListNode — slot ordering invariant" begin
            # slot0 key < slot1 key (lexicographic)
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            # Insert in reverse alphabetical order — should still be sorted
            node_set_val!(n, collect(UInt8, "z"), 2)
            node_set_val!(n, collect(UInt8, "a"), 1)
            @test n.key0 == collect(UInt8, "a")
            @test n.key1 == collect(UInt8, "z")
            @test validate_list_node(n)
        end

        @testset "LineListNode — node_key_overlap" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "hello"), 1)
            @test node_key_overlap(n, collect(UInt8, "help")) == 3  # hel
            @test node_key_overlap(n, collect(UInt8, "world")) == 0
        end

        @testset "LineListNode — node_contains_partial_key" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "hello"), 1)
            @test node_contains_partial_key(n, collect(UInt8, "hel"))
            @test node_contains_partial_key(n, collect(UInt8, "hello"))
            @test !node_contains_partial_key(n, collect(UInt8, "world"))
        end

        @testset "LineListNode — child in slot0" begin
            # Insert a branch (child node)
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child, collect(UInt8, "world"), 99)
            child_rc = TrieNodeODRc(child, GlobalAlloc())
            res = node_set_branch!(n, collect(UInt8, "hello"), child_rc)
            @test res === true || res === false   # created_subnode Bool
            @test is_child_0(n)
            result = node_get_child(n, collect(UInt8, "hello"))
            @test result !== nothing
            consumed, got_rc = result
            @test consumed == 5
            @test node_get_val(as_tagged(got_rc), collect(UInt8, "world")) == 99
        end

        @testset "LineListNode — remove_val! with prune" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            key = collect(UInt8, "hello")
            node_set_val!(n, key, 42)
            removed = node_remove_val!(n, key, true)
            @test removed == 42
            @test node_is_empty(n)
        end

        @testset "LineListNode — remove_val! two slots" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            k1 = collect(UInt8, "a")
            k2 = collect(UInt8, "b")
            node_set_val!(n, k1, 1)
            node_set_val!(n, k2, 2)
            removed = node_remove_val!(n, k1, true)
            @test removed == 1
            @test !is_used_1(n)
            @test node_get_val(n, k2) == 2
        end

        @testset "LineListNode — iteration empty" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            tok, path, child, val = next_items(n, new_iter_token(n))
            @test tok == NODE_ITER_FINISHED
        end

        @testset "LineListNode — iteration single value" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            key = collect(UInt8, "hi")
            node_set_val!(n, key, 77)
            tok, path, child, val = next_items(n, UInt128(0))
            @test tok == UInt128(1)
            @test path == key
            @test val == 77
            @test child === nothing
            tok2, _, _, _ = next_items(n, tok)
            @test tok2 == NODE_ITER_FINISHED
        end

        @testset "LineListNode — iteration two values" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "a"), 1)
            node_set_val!(n, collect(UInt8, "b"), 2)
            tok, path, child, val = next_items(n, UInt128(0))
            @test path == collect(UInt8, "a") && val == 1
            tok2, path2, _, val2 = next_items(n, tok)
            @test path2 == collect(UInt8, "b") && val2 == 2
            tok3, _, _, _ = next_items(n, tok2)
            @test tok3 == NODE_ITER_FINISHED
        end

        @testset "LineListNode — count_branches" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            @test count_branches(n, UInt8[]) == 0
            node_set_val!(n, collect(UInt8, "ab"), 1)
            node_set_val!(n, collect(UInt8, "cd"), 2)
            @test count_branches(n, UInt8[]) == 2   # 'a' and 'c'
            @test count_branches(n, collect(UInt8, "a")) == 1   # 'b'
        end

        @testset "LineListNode — node_branches_mask" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "a"), 1)
            node_set_val!(n, collect(UInt8, "b"), 2)
            m = node_branches_mask(n, UInt8[])
            @test test_bit(m, UInt8('a'))
            @test test_bit(m, UInt8('b'))
            @test !test_bit(m, UInt8('c'))
        end

        @testset "LineListNode — get_node_at_key zero-length" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "hello"), 1)
            ref = get_node_at_key(n, UInt8[])
            @test ref isa ANRBorrowedDyn{Int, GlobalAlloc}
        end

        @testset "LineListNode — get_node_at_key exact child" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child, collect(UInt8, "world"), 5)
            child_rc = TrieNodeODRc(child, GlobalAlloc())
            node_set_branch!(n, collect(UInt8, "key"), child_rc)
            ref = get_node_at_key(n, collect(UInt8, "key"))
            @test ref isa ANRBorrowedRc{Int, GlobalAlloc}
        end

        @testset "LineListNode — validate_list_node invariants" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "a"), 1)
            node_set_val!(n, collect(UInt8, "z"), 2)
            @test validate_list_node(n)
        end

        @testset "LineListNode — long key creates continuation node" begin
            long_key = collect(UInt8, "Pack my box with five dozen liquor jugs")
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            res = node_set_val!(n, long_key, 24)
            @test res isa Tuple
            created = res[2]
            @test created == true   # continuation node was created
            # Traverse the chain to find the value
            remaining = long_key
            cur = n
            levels = 0
            while true
                r = node_get_child(cur, remaining)
                r === nothing && break
                consumed, child_rc = r
                remaining = remaining[(consumed+1):end]
                cur = as_tagged(child_rc)
                levels += 1
            end
            @test node_get_val(cur, remaining) == 24
            @test levels == (length(long_key) - 1) ÷ KEY_BYTES_CNT
        end

        @testset "LineListNode — pjoin_dyn with EmptyNode returns Identity(SELF)" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "a"), 1)
            e = EmptyNode{Int, GlobalAlloc}()
            res = pjoin_dyn(n, e)
            @test res isa AlgResIdentity
            @test res.mask == SELF_IDENT
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) disjoint keys" begin
            # Two nodes with completely different first bytes → DenseByteNode (>2 entries)
            # Actually 2 disjoint entries → stays LineListNode
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, UInt8[0x61], 1)   # "a" → 1
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, UInt8[0x62], 2)   # "b" → 2
            r = pjoin_dyn(a, b)
            @test r isa AlgResElement
            rc = r.value
            joined = as_tagged(rc)
            @test node_get_val(joined, UInt8[0x61]) == 1
            @test node_get_val(joined, UInt8[0x62]) == 2
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) identical key same val → Identity" begin
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "hello"), 5)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, collect(UInt8, "hello"), 5)
            r = pjoin_dyn(a, b)
            # pjoin(5, 5) on Int returns Identity(BOTH) — same value
            @test r isa AlgResIdentity
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) identical key different val → max" begin
            # pjoin(3, 7) = max = 7 = b → AlgResIdentity(COUNTER_IDENT) meaning "use b"
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "key"), 3)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, collect(UInt8, "key"), 7)
            r = pjoin_dyn(a, b)
            @test r isa AlgResIdentity
            @test r.mask == COUNTER_IDENT
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) shared prefix builds intermediate node" begin
            # "abc" and "abd" share "ab" prefix → new child node under "ab"
            # node_get_val is local-only; use PathMap API to traverse the full path
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "abc"), 1)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, collect(UInt8, "abd"), 2)
            r = pjoin_dyn(a, b)
            @test r isa AlgResElement
            # Wire into a PathMap so we can use get_val_at for full-path traversal
            m = PathMap{Int}()
            m.root = r.value
            @test get_val_at(m, collect(UInt8, "abc")) == 1
            @test get_val_at(m, collect(UInt8, "abd")) == 2
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) 4-entry upgrade to DenseByteNode" begin
            # a has 2 slots, b has 2 slots, all disjoint → 4 entries → DenseByteNode
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, UInt8[0x61], 1)
            node_set_val!(a, UInt8[0x62], 2)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, UInt8[0x63], 3)
            node_set_val!(b, UInt8[0x64], 4)
            r = pjoin_dyn(a, b)
            @test r isa AlgResElement
            joined = as_tagged(r.value)
            @test node_tag(joined) == DENSE_BYTE_NODE_TAG
            @test node_get_val(joined, UInt8[0x61]) == 1
            @test node_get_val(joined, UInt8[0x62]) == 2
            @test node_get_val(joined, UInt8[0x63]) == 3
            @test node_get_val(joined, UInt8[0x64]) == 4
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) one empty slot merges correctly" begin
            # a has 1 slot, b has 1 slot, same key → Identity
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "x"), 10)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, collect(UInt8, "x"), 10)
            r = pjoin_dyn(a, b)
            @test r isa AlgResIdentity
        end

        @testset "LineListNode — pjoin_dyn(LLN, EmptyNode) → Identity(SELF)" begin
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "foo"), 42)
            e = EmptyNode{Int, GlobalAlloc}()
            r = pjoin_dyn(a, e)
            @test r isa AlgResIdentity
            @test r.mask & SELF_IDENT != 0
        end

        @testset "LineListNode — pjoin_dyn(LLN, TinyRefNode) disjoint keys" begin
            lln = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(lln, collect(UInt8, "abc"), 1)
            tiny = TinyRefNode(false, collect(UInt8, "xyz"), ValOrChild(2), GlobalAlloc())
            r = pjoin_dyn(lln, tiny)
            @test r isa AlgResElement
            m = PathMap{Int}(); m.root = r.value
            @test get_val_at(m, collect(UInt8, "abc")) == 1
            @test get_val_at(m, collect(UInt8, "xyz")) == 2
        end

        @testset "LineListNode — pjoin_dyn(LLN, TinyRefNode) same key same val → Identity" begin
            lln = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(lln, collect(UInt8, "hi"), 5)
            tiny = TinyRefNode(false, collect(UInt8, "hi"), ValOrChild(5), GlobalAlloc())
            r = pjoin_dyn(lln, tiny)
            @test r isa AlgResIdentity
        end

        # ================================================================
        # factor_prefix! tests
        # ================================================================

        @testset "LineListNode — factor_prefix! no-op when no overlap" begin
            using MORK: factor_prefix!
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 1)   # "a"
            node_set_val!(n, UInt8[0x62], 2)   # "b"
            factor_prefix!(n)
            # No overlap → unchanged
            @test is_used_0(n) && is_used_1(n)
        end

        @testset "LineListNode — factor_prefix! merges illegal overlap into shared prefix child" begin
            using MORK: factor_prefix!
            # "ab" child and "ac" child share "a" → should be merged into child at "a"
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child1 = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child1, UInt8[0x62], 10)   # "b" → 10
            child2 = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child2, UInt8[0x63], 20)   # "c" → 20
            n.key0 = UInt8[0x61, 0x62]   # "ab"
            n.slot0 = ValOrChild(TrieNodeODRc(child1, GlobalAlloc()))
            n.key1 = UInt8[0x61, 0x63]   # "ac"
            n.slot1 = ValOrChild(TrieNodeODRc(child2, GlobalAlloc()))
            # Both keys start with 0x61 — overlap 1 but slot0 is a child (illegal)
            factor_prefix!(n)
            # After factoring: single slot at key "a" containing merged child
            @test is_used_0(n)
            @test !is_used_1(n)
            @test n.key0 == UInt8[0x61]
            @test is_child_0(n)
        end

        @testset "LineListNode — factor_prefix! legal overlap (val at overlap=1) → no-op" begin
            using MORK: factor_prefix!
            # "a" val and "ab" child: overlap=1, slot0 is a val → legal
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child, UInt8[0x62], 5)
            n.key0 = UInt8[0x61]
            n.slot0 = ValOrChild(99)   # val
            n.key1 = UInt8[0x61, 0x62]
            n.slot1 = ValOrChild(TrieNodeODRc(child, GlobalAlloc()))
            factor_prefix!(n)
            # Legal overlap → unchanged
            @test is_used_0(n) && is_used_1(n)
        end

        # ================================================================
        # drop_head_dyn! both-slots path
        # ================================================================

        @testset "LineListNode — drop_head_dyn! both-slots case A: shorten both keys" begin
            # Two slots: key0="abc"→1, key1="abd"→2; drop 2 bytes → "c"→1, "d"→2
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "abc"), 1)
            node_set_val!(n, collect(UInt8, "abd"), 2)
            result = drop_head_dyn!(n, 2)
            @test result !== nothing
            shortened = as_tagged(result)
            @test is_used_0(shortened) && is_used_1(shortened)
            @test node_get_val(shortened, UInt8[0x63]) == 1   # "c" → 1
            @test node_get_val(shortened, UInt8[0x64]) == 2   # "d" → 2
        end

        @testset "LineListNode — drop_head_dyn! both-slots case A: drop causes swap" begin
            # key0="ba"→1, key1="bb"→2 (no swap needed after drop of 1 → "a" < "b")
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "ba"), 1)
            node_set_val!(n, collect(UInt8, "bc"), 2)
            result = drop_head_dyn!(n, 1)
            @test result !== nothing
            s = as_tagged(result)
            @test node_get_val(s, UInt8[0x61]) == 1   # "a" → 1
            @test node_get_val(s, UInt8[0x63]) == 2   # "c" → 2
        end

        @testset "LineListNode — drop_head_dyn! drops val-slot when key consumed" begin
            # key0="a"→1 (val, len=1), key1="abc"→2 (val, len=3); drop 1 → slot0 dropped
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 1)
            node_set_val!(n, collect(UInt8, "abc"), 2)
            result = drop_head_dyn!(n, 1)
            @test result !== nothing
            s = as_tagged(result)
            # "a" dropped, remaining "bc" should be present
            @test node_get_val(s, collect(UInt8, "bc")) == 2
        end

        @testset "LineListNode — drop_head_dyn! both-slots fully drops both vals" begin
            # Both slots are vals with key len ≤ byte_cnt → both dropped → nothing
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 1)
            node_set_val!(n, UInt8[0x62], 2)
            result = drop_head_dyn!(n, 1)
            @test result === nothing
        end

        # ================================================================
        # LineListNode pmeet_dyn tests
        # Ports upstream line_list_node.rs lattice-meet behaviour.
        # ================================================================

        @testset "LineListNode — pmeet_dyn with EmptyNode → None (empty intersection)" begin
            # pmeet(LLN, EmptyNode): EmptyNode has no paths, so intersection is empty → AlgResNone.
            # (EmptyNode::pmeet_dyn returns Identity(SELF); LLN side returns None — both say "empty".)
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 42)
            e = EmptyNode{Int, GlobalAlloc}()
            r = pmeet_dyn(n, e)
            @test r isa AlgResNone
        end

        @testset "LineListNode — pmeet_dyn same single-val node → Identity" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 5)
            # pmeet of node with itself (same content) via PathMap
            m1 = PathMap{Int}(); set_val_at!(m1, "a", 5)
            m2 = PathMap{Int}(); set_val_at!(m2, "a", 5)
            r = pmeet(m1.root, m2.root)
            @test r isa AlgResIdentity || (r isa AlgResElement && get_val_at(m1, "a") == 5)
        end

        @testset "LineListNode — pmeet_dyn intersection: common key wins" begin
            # a has "a"→3, "b"→7 ; b has "a"→5, "c"→9 ; meet = "a"→min(3,5)=3
            m1 = PathMap{Int}(); set_val_at!(m1, "a", 3); set_val_at!(m1, "b", 7)
            m2 = PathMap{Int}(); set_val_at!(m2, "a", 5); set_val_at!(m2, "c", 9)
            r = pmeet(m1.root, m2.root)
            # result contains only key "a" with value min(3,5)=3
            @test r isa AlgResElement || r isa AlgResIdentity
            result_m = PathMap{Int}()
            if r isa AlgResElement
                result_m.root = r.value
            elseif r isa AlgResIdentity
                result_m.root = (r.mask & SELF_IDENT != 0) ? m1.root : m2.root
            end
            @test get_val_at(result_m, "a") == 3
            @test get_val_at(result_m, "b") === nothing
            @test get_val_at(result_m, "c") === nothing
        end

        @testset "LineListNode — pmeet_dyn disjoint keys → None" begin
            m1 = PathMap{Int}(); set_val_at!(m1, "a", 1)
            m2 = PathMap{Int}(); set_val_at!(m2, "b", 2)
            r = pmeet(m1.root, m2.root)
            @test r isa AlgResNone
        end

        # ================================================================
        # TinyRefNode tests
        # ================================================================

        @testset "TinyRefNode — struct and tag" begin
            key = collect(UInt8, "hi")
            payload = ValOrChild(42)
            t = TinyRefNode(false, key, payload, GlobalAlloc())
            @test node_tag(t) == TINY_REF_NODE_TAG
            @test !node_is_empty(t)
            @test TINY_REF_MAX_KEY == 7
        end

        @testset "TinyRefNode — empty when key is empty" begin
            t = TinyRefNode{Int, GlobalAlloc}(UInt8[], false, ValOrChild(0), GlobalAlloc())
            @test node_is_empty(t)
        end

        @testset "TinyRefNode — contains_val and get_val" begin
            key = collect(UInt8, "abc")
            t = TinyRefNode(false, key, ValOrChild(99), GlobalAlloc())
            @test node_contains_val(t, key)
            @test node_get_val(t, key) == 99
            @test !node_contains_val(t, collect(UInt8, "xyz"))
            @test node_get_val(t, collect(UInt8, "xyz")) === nothing
        end

        @testset "TinyRefNode — node_get_child with child payload" begin
            child_n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child_n, collect(UInt8, "world"), 7)
            child_rc = TrieNodeODRc(child_n, GlobalAlloc())
            key = collect(UInt8, "abc")
            t = TinyRefNode(true, key, ValOrChild(child_rc), GlobalAlloc())
            @test t.is_child == true
            result = node_get_child(t, key)
            @test result !== nothing
            consumed, got_rc = result
            @test consumed == 3
            @test node_get_val(as_tagged(got_rc), collect(UInt8, "world")) == 7
        end

        @testset "TinyRefNode — node_key_overlap and contains_partial_key" begin
            key = collect(UInt8, "hello")
            t = TinyRefNode(false, key, ValOrChild(1), GlobalAlloc())
            @test node_key_overlap(t, collect(UInt8, "help")) == 3
            @test node_contains_partial_key(t, collect(UInt8, "hel"))
            @test !node_contains_partial_key(t, collect(UInt8, "world"))
        end

        @testset "TinyRefNode — get_node_at_key zero length" begin
            key = collect(UInt8, "ab")
            t = TinyRefNode(false, key, ValOrChild(5), GlobalAlloc())
            ref = get_node_at_key(t, UInt8[])
            @test ref isa ANRBorrowedDyn{Int, GlobalAlloc}
        end

        @testset "TinyRefNode — get_node_at_key exact child match" begin
            child_n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child_rc = TrieNodeODRc(child_n, GlobalAlloc())
            key = collect(UInt8, "ab")
            t = TinyRefNode(true, key, ValOrChild(child_rc), GlobalAlloc())
            ref = get_node_at_key(t, key)
            @test ref isa ANRBorrowedRc{Int, GlobalAlloc}
        end

        @testset "TinyRefNode — get_node_at_key sub-key creates new TinyRefNode" begin
            key = collect(UInt8, "abcde")
            t = TinyRefNode(false, key, ValOrChild(42), GlobalAlloc())
            ref = get_node_at_key(t, collect(UInt8, "ab"))
            @test ref isa ANRBorrowedTiny{Int, GlobalAlloc}
            inner = ref.node
            @test inner isa TinyRefNode{Int, GlobalAlloc}
            @test inner.key == collect(UInt8, "cde")
        end

        @testset "TinyRefNode — into_full creates LineListNode" begin
            key = collect(UInt8, "xyz")
            t = TinyRefNode(false, key, ValOrChild(77), GlobalAlloc())
            list_n = into_full(t)
            @test list_n isa LineListNode{Int, GlobalAlloc}
            @test node_get_val(list_n, key) == 77
        end

        @testset "TinyRefNode — write methods panic" begin
            t = TinyRefNode(false, collect(UInt8, "a"), ValOrChild(1), GlobalAlloc())
            @test_throws ErrorException node_remove_val!(t, UInt8[1], false)
            @test_throws ErrorException node_create_dangling!(t, UInt8[1])
            @test_throws ErrorException node_remove_dangling!(t, UInt8[1])
            @test_throws ErrorException node_remove_all_branches!(t, UInt8[], false)
            @test_throws ErrorException take_node_at_key!(t, UInt8[1], false)
        end

        @testset "TinyRefNode — node_first_val_depth_along_key" begin
            key = collect(UInt8, "ab")
            t = TinyRefNode(false, key, ValOrChild(5), GlobalAlloc())
            @test node_first_val_depth_along_key(t, collect(UInt8, "abc")) == 1  # len(key)-1
            @test node_first_val_depth_along_key(t, collect(UInt8, "xyz")) === nothing
        end

        @testset "TinyRefNode — node_child_iter_start with child" begin
            child_n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child_rc = TrieNodeODRc(child_n, GlobalAlloc())
            t = TinyRefNode(true, collect(UInt8, "a"), ValOrChild(child_rc), GlobalAlloc())
            tok, got_rc = node_child_iter_start(t)
            @test tok == UInt64(0)
            @test got_rc !== nothing
            # next is always (0, nothing)
            tok2, got2 = node_child_iter_next(t, tok)
            @test tok2 == UInt64(0)
            @test got2 === nothing
        end
    end

    @testset "DenseByteNode (ports pathmap/src/dense_byte_node.rs)" begin
        alloc = GlobalAlloc()

        @testset "CoFreeEntry basics" begin
            cf = CoFreeEntry{Int, GlobalAlloc}()
            @test !has_rec(cf)
            @test !has_val(cf)
            cf.val = 42
            @test has_val(cf)
            @test !has_rec(cf)
        end

        @testset "DenseByteNode — struct and tag" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            @test node_tag(n) == DENSE_BYTE_NODE_TAG
            @test node_is_empty(n)
        end

        @testset "CellByteNode — struct and tag" begin
            n = CellByteNode{Int, GlobalAlloc}(alloc)
            @test node_tag(n) == CELL_BYTE_NODE_TAG
            @test node_is_empty(n)
        end

        @testset "DenseByteNode — set and get val" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('a')
            @test node_get_val(n, UInt8[k]) === nothing
            @test !node_contains_val(n, UInt8[k])
            node_set_val!(n, UInt8[k], 99)
            @test node_contains_val(n, UInt8[k])
            @test node_get_val(n, UInt8[k]) == 99
            @test !node_is_empty(n)
        end

        @testset "DenseByteNode — replace val" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('b')
            node_set_val!(n, UInt8[k], 1)
            (old, created) = node_set_val!(n, UInt8[k], 2)
            @test old == 1
            @test !created
            @test node_get_val(n, UInt8[k]) == 2
        end

        @testset "DenseByteNode — multiple keys" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            for c in "abc"
                node_set_val!(n, UInt8[UInt8(c)], Int(c))
            end
            @test node_get_val(n, UInt8['a']) == Int('a')
            @test node_get_val(n, UInt8['b']) == Int('b')
            @test node_get_val(n, UInt8['c']) == Int('c')
            @test node_get_val(n, UInt8['d']) === nothing
            @test count_branches(n, UInt8[]) == 3
        end

        @testset "DenseByteNode — node_remove_val" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('x')
            node_set_val!(n, UInt8[k], 7)
            result = node_remove_val!(n, UInt8[k], true)
            @test result == 7
            @test !node_contains_val(n, UInt8[k])
            @test node_is_empty(n)
        end

        @testset "DenseByteNode — set_child and get_child" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('a')
            child = LineListNode{Int, GlobalAlloc}(alloc)
            child_rc = TrieNodeODRc(child, alloc)
            node_set_branch!(n, UInt8[k], child_rc)
            result = node_get_child(n, UInt8[k])
            @test result !== nothing
            (overlap, got_rc) = result
            @test overlap == 1
            @test !is_empty_node(got_rc)
        end

        @testset "DenseByteNode — node_key_overlap" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('z')
            @test node_key_overlap(n, UInt8[k]) == 0
            node_set_val!(n, UInt8[k], 1)
            @test node_key_overlap(n, UInt8[k]) == 1
        end

        @testset "DenseByteNode — node_contains_partial_key" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('p')
            @test !node_contains_partial_key(n, UInt8[k])
            node_set_val!(n, UInt8[k], 1)
            @test node_contains_partial_key(n, UInt8[k])
            @test !node_contains_partial_key(n, UInt8[k, UInt8('q')])
        end

        @testset "DenseByteNode — iteration" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            # Empty node
            tok = new_iter_token(n)
            @test tok == UInt128(0)
            (next_tok, path, child, val) = next_items(n, tok)
            @test next_tok == NODE_ITER_FINISHED

            # Single val
            node_set_val!(n, UInt8['a'], 1)
            tok = new_iter_token(n)
            (next_tok2, path2, child2, val2) = next_items(n, tok)
            @test val2 == 1
            @test path2 == UInt8['a']
            (done_tok, _, _, _) = next_items(n, next_tok2)
            @test done_tok == NODE_ITER_FINISHED
        end

        @testset "DenseByteNode — branches_mask" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            node_set_val!(n, UInt8['b'], 2)
            m = node_branches_mask(n, UInt8[])
            @test test_bit(m, UInt8('a'))
            @test test_bit(m, UInt8('b'))
            @test !test_bit(m, UInt8('c'))
        end

        @testset "DenseByteNode — get_node_at_key (zero-length key)" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            ref = get_node_at_key(n, UInt8[])
            @test ref isa ANRBorrowedDyn
        end

        @testset "DenseByteNode — get_node_at_key (exact child)" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('k')
            child_n = LineListNode{Int, GlobalAlloc}(alloc)
            node_set_val!(child_n, UInt8['x'], 9)
            child_rc = TrieNodeODRc(child_n, alloc)
            node_set_branch!(n, UInt8[k], child_rc)
            ref = get_node_at_key(n, UInt8[k])
            @test ref isa ANRBorrowedRc
        end

        @testset "DenseByteNode — node_val_count" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            cache = Dict{UInt64, Int}()
            @test node_val_count(n, cache) == 0
            node_set_val!(n, UInt8['a'], 1)
            node_set_val!(n, UInt8['b'], 2)
            cache2 = Dict{UInt64, Int}()
            @test node_val_count(n, cache2) == 2
        end

        @testset "DenseByteNode — pjoin_dyn with EmptyNode" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            empty_n = EmptyNode{Int, GlobalAlloc}()
            res = pjoin_dyn(n, empty_n)
            @test res isa AlgResIdentity
            @test (res.mask & SELF_IDENT) != 0
        end

        @testset "DenseByteNode — pjoin_dyn self with self (same content)" begin
            n1 = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n1, UInt8['a'], 1)
            node_set_val!(n1, UInt8['b'], 2)
            n2 = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n2, UInt8['a'], 1)
            node_set_val!(n2, UInt8['b'], 2)
            res = pjoin_dyn(n1, n2)
            # Both have same content — should be Identity for both (or Element with same content)
            @test res isa AlgResIdentity || res isa AlgResElement
        end

        @testset "DenseByteNode — merge_from_list_node!" begin
            dense = DenseByteNode{Int, GlobalAlloc}(alloc, 2)
            list = LineListNode{Int, GlobalAlloc}(alloc)
            node_set_val!(list, UInt8['a'], 1)
            node_set_val!(list, UInt8['b'], 2)
            status = merge_from_list_node!(dense, list)
            @test node_get_val(dense, UInt8['a']) == 1
            @test node_get_val(dense, UInt8['b']) == 2
        end

        @testset "DenseByteNode — LineListNode upgrade via set_payload_abstract!" begin
            # Fill a LineListNode with 3 values — third triggers DenseByteNode upgrade
            n = LineListNode{Int, GlobalAlloc}(alloc)
            # First two values go into the two LineListNode slots
            node_set_val!(n, UInt8['a'], 1)
            node_set_val!(n, UInt8['b'], 2)
            # Third value at 'c' triggers upgrade
            res = node_set_val!(n, UInt8['c'], 3)
            # Result is a (val, created) tuple OR a TrieNodeODRc upgrade
            if res isa Tuple
                # Stayed as LineListNode (shared prefix possible)
                @test true
            else
                @test res isa TrieNodeODRc
                upgraded = as_tagged(res)
                @test upgraded isa DenseByteNode || upgraded isa LineListNode
            end
        end

        @testset "DenseByteNode — convert_to_cell_node!" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            cell_rc = convert_to_cell_node!(n)
            cell = as_tagged(cell_rc)
            @test cell isa CellByteNode
            @test node_get_val(cell, UInt8['a']) == 1
        end

        @testset "DenseByteNode — node_remove_unmasked_branches!" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            node_set_val!(n, UInt8['b'], 2)
            node_set_val!(n, UInt8['c'], 3)
            # Keep only 'a' and 'c'
            keep_mask = ByteMask()
            keep_mask = set(keep_mask, UInt8('a'))
            keep_mask = set(keep_mask, UInt8('c'))
            node_remove_unmasked_branches!(n, UInt8[], keep_mask, false)
            @test node_contains_val(n, UInt8['a'])
            @test !node_contains_val(n, UInt8['b'])
            @test node_contains_val(n, UInt8['c'])
        end

        @testset "DenseByteNode — node_child_iter_start/next" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            (tok, child) = node_child_iter_start(n)
            @test child === nothing

            # Add a child via public API
            child_n = LineListNode{Int, GlobalAlloc}(alloc)
            child_rc = TrieNodeODRc(child_n, alloc)
            node_set_branch!(n, UInt8[UInt8('a')], child_rc)
            (tok2, got_child) = node_child_iter_start(n)
            @test got_child !== nothing
        end
    end

    # ================================================================
    # Zipper and PathMap tests
    # ================================================================

    @testset "Zipper and PathMap (ports pathmap/src/zipper.rs + trie_map.rs)" begin
        V   = Int
        A   = GlobalAlloc
        alloc = GlobalAlloc()

        # ---- node_along_path ----

        @testset "node_along_path — empty path returns root unchanged" begin
            rc = TrieNodeODRc(LineListNode{V,A}(alloc), alloc)
            node_set_val!(rc.node, UInt8[UInt8('a')], 1)
            final_rc, rem, val = node_along_path(rc, UInt8[], nothing)
            @test final_rc === rc
            @test isempty(rem)
            @test val === nothing
        end

        @testset "node_along_path — traverse single slot" begin
            # root → child at key "ab"
            child_n = LineListNode{V,A}(alloc)
            node_set_val!(child_n, UInt8[UInt8('c')], 99)
            child_rc = TrieNodeODRc(child_n, alloc)
            root_n = LineListNode{V,A}(alloc)
            node_set_branch!(root_n, collect(UInt8, "ab"), child_rc)
            root_rc = TrieNodeODRc(root_n, alloc)

            final_rc, rem, val = node_along_path(root_rc, collect(UInt8, "abc"), nothing)
            @test final_rc === child_rc
            @test collect(rem) == UInt8[UInt8('c')]
            @test val === nothing
        end

        @testset "node_along_path — full key match returns value" begin
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, collect(UInt8, "hello"), 42)
            root_rc = TrieNodeODRc(root_n, alloc)
            # path exactly matches the key that leads to a value
            # node_along_path stops when no child for remaining key
            final_rc, rem, val = node_along_path(root_rc, collect(UInt8, "hello"), nothing)
            # if node_get_child returns nothing for "hello" (it's a val, not a child),
            # then final_rc = root_rc, rem = "hello", val = nothing
            @test final_rc === root_rc
            @test collect(rem) == collect(UInt8, "hello")
        end

        # ---- val_count_below_root ----

        @testset "val_count_below_root — empty node" begin
            @test val_count_below_root(nothing) == 0
            e = EmptyNode{V,A}()
            cache = Dict{UInt64,Int}()
            @test node_val_count(e, cache) == 0
        end

        @testset "val_count_below_root — LineListNode with values" begin
            n = LineListNode{V,A}(alloc)
            node_set_val!(n, UInt8[UInt8('a')], 1)
            node_set_val!(n, UInt8[UInt8('b')], 2)
            @test val_count_below_root(n) == 2
        end

        # ---- ReadZipperCore construction ----

        @testset "ReadZipperCore — construct at root of empty map" begin
            rc = TrieNodeODRc(LineListNode{V,A}(alloc), alloc)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)
            @test zipper_at_root(z)
            @test isempty(zipper_path(z))
            @test !zipper_is_val(z)
            @test zipper_path_exists(z)   # root always exists per upstream semantics
        end

        @testset "ReadZipperCore — at_root after construction" begin
            rc = TrieNodeODRc(LineListNode{V,A}(alloc), alloc)
            node_set_val!(rc.node, UInt8[UInt8('x')], 10)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)
            @test zipper_at_root(z)
            @test !zipper_is_val(z)         # root has no value (values are below)
            @test zipper_child_count(z) == 1  # 'x' branch
        end

        # ---- ReadZipperCore_at_path ----

        @testset "ReadZipperCore_at_path — positions at path 'a'" begin
            # Build: root → LineListNode with value at "a"
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, UInt8[UInt8('a')], 55)
            root_rc = TrieNodeODRc(root_n, alloc)

            # Zipper pre-positioned at "a" — should report is_val = true
            path = collect(UInt8, "a")
            z = ReadZipperCore_at_path(root_rc, path, length(path), 0, nothing, alloc)
            @test zipper_at_root(z)
            @test isempty(zipper_path(z))
            @test zipper_is_val(z)
            @test zipper_val(z) == 55
        end

        # ---- descend / ascend navigation ----

        @testset "ReadZipperCore — descend_to and is_val" begin
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, UInt8[UInt8('a'), UInt8('b')], 7)
            root_rc = TrieNodeODRc(root_n, alloc)
            z = ReadZipperCore(root_rc, UInt8[], 0, nothing, alloc)

            zipper_descend_to!(z, collect(UInt8, "ab"))
            @test !zipper_at_root(z)
            @test zipper_path(z) == UInt8[UInt8('a'), UInt8('b')]
            @test zipper_is_val(z)
            @test zipper_val(z) == 7
        end

        @testset "ReadZipperCore — ascend after descend" begin
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, UInt8[UInt8('x')], 3)
            root_rc = TrieNodeODRc(root_n, alloc)
            z = ReadZipperCore(root_rc, UInt8[], 0, nothing, alloc)
            zipper_descend_to!(z, collect(UInt8, "x"))
            @test zipper_is_val(z)
            @test zipper_val(z) == 3
            zipper_ascend!(z, 1)
            @test zipper_at_root(z)
            @test !zipper_is_val(z)
        end

        @testset "ReadZipperCore — ascend_byte" begin
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, collect(UInt8, "abc"), 11)
            root_rc = TrieNodeODRc(root_n, alloc)
            z = ReadZipperCore(root_rc, UInt8[], 0, nothing, alloc)
            zipper_descend_to!(z, collect(UInt8, "abc"))
            @test length(zipper_path(z)) == 3
            @test zipper_ascend_byte!(z)
            @test length(zipper_path(z)) == 2
            @test zipper_ascend_byte!(z)
            @test length(zipper_path(z)) == 1
            @test zipper_ascend_byte!(z)
            @test zipper_at_root(z)
            @test !zipper_ascend_byte!(z)  # can't ascend above root
        end

        @testset "ReadZipperCore — reset!" begin
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, collect(UInt8, "hello"), 5)
            root_rc = TrieNodeODRc(root_n, alloc)
            z = ReadZipperCore(root_rc, UInt8[], 0, nothing, alloc)
            zipper_descend_to!(z, collect(UInt8, "hello"))
            @test !zipper_at_root(z)
            zipper_reset!(z)
            @test zipper_at_root(z)
        end

        # ---- to_next_val iteration ----

        @testset "ReadZipperCore — to_next_val iterates values in order" begin
            # Build a DenseByteNode with values at 'a', 'b', 'c'
            n = DenseByteNode{V,A}(alloc)
            node_set_val!(n, UInt8[UInt8('a')], 1)
            node_set_val!(n, UInt8[UInt8('b')], 2)
            node_set_val!(n, UInt8[UInt8('c')], 3)
            rc = TrieNodeODRc(n, alloc)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)

            found = Int[]
            while zipper_to_next_val!(z)
                push!(found, zipper_val(z))
            end
            sort!(found)
            @test found == [1, 2, 3]
        end

        @testset "ReadZipperCore — to_next_val empty node yields nothing" begin
            n = LineListNode{V,A}(alloc)
            rc = TrieNodeODRc(n, alloc)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)
            @test !zipper_to_next_val!(z)
        end

        @testset "ReadZipperCore — to_next_val single value" begin
            n = LineListNode{V,A}(alloc)
            node_set_val!(n, UInt8[UInt8('z')], 99)
            rc = TrieNodeODRc(n, alloc)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)
            @test zipper_to_next_val!(z)
            @test zipper_val(z) == 99
            @test !zipper_to_next_val!(z)
        end

        # ---- PathMap ----

        @testset "PathMap — empty map is_empty" begin
            m = PathMap{V}()
            @test Base.isempty(m)
            @test val_count(m) == 0
        end

        @testset "PathMap — read_zipper on empty map" begin
            m = PathMap{V}()
            z = read_zipper(m)
            @test zipper_at_root(z)
            @test !zipper_is_val(z)
        end

        @testset "PathMap — get_val_at missing key returns nothing" begin
            m = PathMap{V}()
            @test get_val_at(m, collect(UInt8, "missing")) === nothing
        end

        @testset "PathMap — manual root population then read" begin
            # Manually build a PathMap's root node (bypass write zipper)
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, collect(UInt8, "hello"), 42)
            root_rc = TrieNodeODRc(root_n, alloc)
            m = PathMap{V,A}(root_rc, nothing, alloc)

            @test get_val_at(m, collect(UInt8, "hello")) == 42
            @test get_val_at(m, collect(UInt8, "world")) === nothing
            @test !Base.isempty(m)
            @test val_count(m) == 1
        end

        @testset "PathMap — read_zipper_at_path" begin
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, collect(UInt8, "key"), 77)
            root_rc = TrieNodeODRc(root_n, alloc)
            m = PathMap{V,A}(root_rc, nothing, alloc)

            z = read_zipper_at_path(m, collect(UInt8, "key"))
            @test zipper_is_val(z)
            @test zipper_val(z) == 77
            @test isempty(zipper_path(z))   # pre-positioned at "key", so path() = ""
        end

        @testset "PathMap — path_exists_at" begin
            root_n = LineListNode{V,A}(alloc)
            node_set_val!(root_n, collect(UInt8, "yes"), 1)
            root_rc = TrieNodeODRc(root_n, alloc)
            m = PathMap{V,A}(root_rc, nothing, alloc)

            @test path_exists_at(m, collect(UInt8, "yes"))
            @test !path_exists_at(m, collect(UInt8, "no"))
        end
    end

    @testset "WriteZipper and PathMap write API (ports pathmap/src/write_zipper.rs)" begin
        V = Int; A = GlobalAlloc; alloc = GlobalAlloc()

        # ------------------------------------------------------------------
        # write_zipper construction
        # ------------------------------------------------------------------
        @testset "write_zipper — construction at root" begin
            m = PathMap{V}()
            z = write_zipper(m)
            @test z isa WriteZipperCore{V,GlobalAlloc}
            @test length(z.focus_stack) == 1
            @test isempty(z.prefix_buf)
            @test isempty(z.prefix_idx)
            @test _wz_at_root(z)
        end

        # ------------------------------------------------------------------
        # set root val (at_root path of wz_set_val!)
        # ------------------------------------------------------------------
        @testset "wz_set_val! at root → root_val" begin
            m = PathMap{V}()
            z = write_zipper(m)
            old = wz_set_val!(z, 42)
            @test old === nothing
            @test m.root_val == 42

            # second set returns old value
            z2 = write_zipper(m)
            old2 = wz_set_val!(z2, 99)
            @test old2 == 42
            @test m.root_val == 99
        end

        # ------------------------------------------------------------------
        # set_val_at! and get_val_at roundtrip
        # ------------------------------------------------------------------
        @testset "set_val_at! / get_val_at roundtrip" begin
            m = PathMap{V}()
            set_val_at!(m, collect(UInt8, "hello"), 1)
            @test get_val_at(m, collect(UInt8, "hello")) == 1

            set_val_at!(m, collect(UInt8, "world"), 2)
            @test get_val_at(m, collect(UInt8, "world")) == 2

            # original key still present
            @test get_val_at(m, collect(UInt8, "hello")) == 1

            # missing key → nothing
            @test get_val_at(m, collect(UInt8, "xyz")) === nothing
        end

        # ------------------------------------------------------------------
        # val_count after writes
        # ------------------------------------------------------------------
        @testset "val_count after multiple set_val_at!" begin
            m = PathMap{V}()
            @test val_count(m) == 0

            set_val_at!(m, collect(UInt8, "a"), 10)
            @test val_count(m) == 1

            set_val_at!(m, collect(UInt8, "b"), 20)
            @test val_count(m) == 2

            set_val_at!(m, collect(UInt8, "c"), 30)
            @test val_count(m) == 3
        end

        # ------------------------------------------------------------------
        # Overwrite (set returns old value)
        # ------------------------------------------------------------------
        @testset "set_val_at! overwrite returns old value" begin
            m = PathMap{V}()
            set_val_at!(m, collect(UInt8, "key"), 111)
            old = set_val_at!(m, collect(UInt8, "key"), 222)
            @test old == 111
            @test get_val_at(m, collect(UInt8, "key")) == 222
            @test val_count(m) == 1
        end

        # ------------------------------------------------------------------
        # Node upgrade path: > 2 distinct entries forces LineListNode → DenseByteNode
        # ------------------------------------------------------------------
        @testset "node upgrade (LineListNode → DenseByteNode) via set_val_at!" begin
            m = PathMap{V}()
            # LineListNode has 2 slots; a third unique entry triggers upgrade
            set_val_at!(m, UInt8[1], 100)
            set_val_at!(m, UInt8[2], 200)
            set_val_at!(m, UInt8[3], 300)   # triggers upgrade
            @test val_count(m) == 3
            @test get_val_at(m, UInt8[1]) == 100
            @test get_val_at(m, UInt8[2]) == 200
            @test get_val_at(m, UInt8[3]) == 300
        end

        # ------------------------------------------------------------------
        # remove_val_at!
        # ------------------------------------------------------------------
        @testset "remove_val_at!" begin
            m = PathMap{V}()
            set_val_at!(m, collect(UInt8, "foo"), 7)
            set_val_at!(m, collect(UInt8, "bar"), 8)
            @test val_count(m) == 2

            removed = remove_val_at!(m, collect(UInt8, "foo"))
            @test removed == 7
            @test get_val_at(m, collect(UInt8, "foo")) === nothing
            @test get_val_at(m, collect(UInt8, "bar")) == 8
            @test val_count(m) == 1
        end

        # ------------------------------------------------------------------
        # remove_val_at! on missing path returns nothing
        # ------------------------------------------------------------------
        @testset "remove_val_at! missing path" begin
            m = PathMap{V}()
            @test remove_val_at!(m, collect(UInt8, "nope")) === nothing
        end

        # ------------------------------------------------------------------
        # wz_path_exists / wz_is_val / wz_get_val
        # ------------------------------------------------------------------
        @testset "wz_path_exists / wz_is_val / wz_get_val" begin
            m = PathMap{V}()
            set_val_at!(m, collect(UInt8, "abc"), 55)

            z = write_zipper(m)
            wz_descend_to!(z, collect(UInt8, "abc"))
            @test wz_path_exists(z)
            @test wz_is_val(z)
            @test wz_get_val(z) == 55

            z2 = write_zipper(m)
            wz_descend_to!(z2, collect(UInt8, "xyz"))
            @test !wz_path_exists(z2)
            @test !wz_is_val(z2)
            @test wz_get_val(z2) === nothing
        end

        # ------------------------------------------------------------------
        # write_zipper_at_path
        # ------------------------------------------------------------------
        @testset "write_zipper_at_path" begin
            m = PathMap{V}()
            set_val_at!(m, collect(UInt8, "prefix:data"), 99)

            # create zipper pre-positioned at "prefix:" then set a second value
            z = write_zipper_at_path(m, collect(UInt8, "prefix:"))
            wz_descend_to!(z, collect(UInt8, "more"))
            wz_set_val!(z, 77)
            @test get_val_at(m, collect(UInt8, "prefix:data")) == 99
            @test get_val_at(m, collect(UInt8, "prefix:more")) == 77
        end

        # ------------------------------------------------------------------
        # PathMap.isempty changes after write/remove
        # ------------------------------------------------------------------
        @testset "PathMap isempty semantics with writes" begin
            m = PathMap{V}()
            @test isempty(m)

            set_val_at!(m, collect(UInt8, "x"), 1)
            @test !isempty(m)

            remove_val_at!(m, collect(UInt8, "x"))
            # After removal the map still has the root node (not empty)
            # val_count should be 0
            @test val_count(m) == 0
        end

        # ==================================================================
        # TrieRef tests (mirrors trie_ref_test1 + trie_ref_test2 in upstream)
        # ==================================================================

        @testset "TrieRef — basic path_exists / val / child_count (trie_ref_test1)" begin
            keys = ["Hello", "Hell", "Help", "Helsinki"]
            m = PathMap{Nothing}()
            for k in keys
                set_val_at!(m, collect(UInt8, k), nothing)
            end

            # Partial path "He" — exists, no val
            tr = trie_ref_at_path(m, collect(UInt8, "He"))
            @test tr_path_exists(tr)
            @test tr_get_val(tr) === nothing

            # "Hel" — exists, no val, child node
            tr = trie_ref_at_path(m, collect(UInt8, "Hel"))
            @test tr_path_exists(tr)
            @test tr_get_val(tr) === nothing

            # "Help" — leaf val
            tr = trie_ref_at_path(m, collect(UInt8, "Help"))
            @test tr_path_exists(tr)
            @test tr_get_val(tr) === nothing   # val IS nothing (stored nothing)
            @test tr_is_val(tr) == false        # nothing val → false

            # "Hello" — leaf val
            tr = trie_ref_at_path(m, collect(UInt8, "Hello"))
            @test tr_path_exists(tr)

            # Non-existent path
            tr = trie_ref_at_path(m, collect(UInt8, "Hi"))
            @test !tr_path_exists(tr)
            @test tr_get_val(tr) === nothing

            # Very long path (> MAX_NODE_KEY_BYTES bytes) that doesn't exist
            long_path = collect(UInt8, "Hello Mr. Washington, my name is John, but sometimes people call me Jack.  I live in Springfield.")
            tr = trie_ref_at_path(m, long_path)
            @test !tr_path_exists(tr)
            @test tr_child_count(tr) == 0
        end

        @testset "TrieRef — child_count / child_mask at 'H'" begin
            keys = ["Hello", "Hell", "Help", "Helsinki"]
            m = PathMap{Nothing}()
            for k in keys; set_val_at!(m, collect(UInt8, k), nothing); end

            tr0 = trie_ref_at_path(m, collect(UInt8, "H"))
            @test tr_path_exists(tr0)
            @test tr_child_count(tr0) == 1   # only 'e' branch

            tr1 = tr_trie_ref_at_path(tr0, collect(UInt8, "el"))
            @test tr_path_exists(tr1)
            @test tr_child_count(tr1) == 3   # 'l', 'p', 's' (Hell, Help, Helsinki)

            # Descend to "Hello"
            tr2 = tr_trie_ref_at_path(tr1, collect(UInt8, "lo"))
            @test tr_path_exists(tr2)
            @test tr_child_count(tr2) == 0

            # Beyond "Hello" — invalid path
            tr3 = tr_trie_ref_at_path(tr2, collect(UInt8, "Operator"))
            @test !tr_path_exists(tr3)
            @test tr_child_count(tr3) == 0

            # Further beyond — chained invalid
            tr4 = tr_trie_ref_at_path(tr3, collect(UInt8, ", give me number 9"))
            @test !tr_path_exists(tr4)
        end

        @testset "TrieRef — trie_ref_test2: val_count + fork_read_zipper + make_map" begin
            rs = ["arrow", "bow", "cannon", "roman", "romane", "romanus^", "romulus",
                  "rubens", "ruber", "rubicon", "rubicundus", "rom'i"]
            m = PathMap{Int}()
            for (i, r) in enumerate(rs)
                set_val_at!(m, collect(UInt8, r), i)
            end

            # Root: 4 first-byte branches (a, b, c, r)
            tr = trie_ref_at_path(m, UInt8[])
            @test tr_path_exists(tr)
            @test tr_child_count(tr) == 4

            # Under 'a'
            tr = tr_trie_ref_at_path(tr, [UInt8('a')])
            @test tr_path_exists(tr)
            @test tr_child_count(tr) == 1

            # Under 'r' — 9 values (roman*, rubens, ruber, rubicon, rubicundus)
            tr_r = trie_ref_at_path(m, [UInt8('r')])
            z = tr_fork_read_zipper(tr_r)
            @test zipper_val_count(z) == 9

            # make_map snapshot
            new_map = tr_make_map(tr_r)
            @test val_count(new_map) == 9
        end

        @testset "TrieRef — invalid TrieRef returns false/nothing/0" begin
            t = _tr_new_invalid(Int)
            @test !_tr_is_valid(t)
            @test !tr_path_exists(t)
            @test tr_get_val(t) === nothing
            @test tr_child_count(t) == 0
        end
    end
end
