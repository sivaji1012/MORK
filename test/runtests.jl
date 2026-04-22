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
    end
end
