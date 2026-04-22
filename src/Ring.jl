"""
Ring — port of `pathmap/src/ring.rs`.

Defines the algebraic-result machinery used throughout MORK:

  - `AlgebraicResult{V}` — result of a lattice/distributive-lattice op
  - `AlgebraicStatus` — in-place-op status
  - `FatAlgebraicResult{V}` — internal dual-carrier (both identity + element)
  - `SELF_IDENT`, `COUNTER_IDENT` — identity-mask bit constants
  - `AbstractLattice`, `AbstractDistributiveLattice` — trait-equivalents
  - `pjoin`, `pmeet`, `psubtract`, `join_into!`, `join_all` — operations
  - Blanket impls on `Nothing`/`V` (Option<V>), integers, Bool

1:1 port of upstream traits. Julia uses abstract types + multiple dispatch
where Rust uses traits. Rust's `&self` becomes Julia's `self` (immutable
read), Rust's `&mut self` becomes Julia's mutating `self!`.
"""

# =====================================================================
# Identity-mask bit constants
# =====================================================================

"""
    SELF_IDENT

Identity-mask bit indicating result is the identity of `self`.
"""
const SELF_IDENT = UInt64(0x1)

"""
    COUNTER_IDENT

Identity-mask bit indicating result is the identity of `other`.
"""
const COUNTER_IDENT = UInt64(0x2)

# =====================================================================
# AlgebraicResult{V}
# =====================================================================

"""
    AlgebraicResult{V}

Result of an algebraic operation on elements in a partial lattice.
1:1 port of `pathmap::ring::AlgebraicResult<V>`.

Three variants (as Julia Union):
  - `AlgResNone()` — operands annihilate; result should be discarded
  - `AlgResIdentity(mask::UInt64)` — result is identical to operand(s)
    indicated by the bitmask (SELF_IDENT / COUNTER_IDENT)
  - `AlgResElement{V}(value::V)` — novel result value

**Invariants (respect or behavior is undefined):**
  - Identity mask must be non-zero for `AlgResIdentity`
  - Bits beyond operation arity must not be set (e.g., arity-2 ops set
    only bit 0 and/or bit 1)
  - Non-commutative ops (like `psubtract`) must never set bits beyond
    SELF_IDENT
"""
struct AlgResNone end

struct AlgResIdentity
    mask::UInt64
end

struct AlgResElement{V}
    value::V
end

const AlgebraicResult{V} = Union{AlgResNone, AlgResIdentity, AlgResElement{V}}

# --- Predicates ---

"""
    is_none(r::AlgebraicResult) -> Bool
"""
is_none(r::AlgResNone) = true
is_none(r::AlgResIdentity) = false
is_none(r::AlgResElement) = false

"""
    is_identity(r::AlgebraicResult) -> Bool
"""
is_identity(r::AlgResNone) = false
is_identity(r::AlgResIdentity) = true
is_identity(r::AlgResElement) = false

"""
    is_element(r::AlgebraicResult) -> Bool
"""
is_element(r::AlgResNone) = false
is_element(r::AlgResIdentity) = false
is_element(r::AlgResElement) = true

"""
    identity_mask(r::AlgebraicResult) -> Union{UInt64, Nothing}

Returns the mask from an `AlgResIdentity`, otherwise `nothing`.
"""
identity_mask(r::AlgResNone) = nothing
identity_mask(r::AlgResIdentity) = r.mask
identity_mask(r::AlgResElement) = nothing

"""
    invert_identity(r) -> AlgebraicResult

Swap SELF_IDENT and COUNTER_IDENT bits in an `AlgResIdentity`. Removes
higher mask bits. No-op for `AlgResNone` / `AlgResElement`.
"""
invert_identity(r::AlgResNone) = r
invert_identity(r::AlgResElement) = r
function invert_identity(r::AlgResIdentity)::AlgResIdentity
    new_mask = ((r.mask & SELF_IDENT) << 1) | ((r.mask & COUNTER_IDENT) >> 1)
    return AlgResIdentity(new_mask)
end

"""
    map(f, r::AlgebraicResult{V}) -> AlgebraicResult{U}

Apply `f` to the element of an `AlgResElement`. Pass through for other variants.
"""
Base.map(f, r::AlgResNone) = r
Base.map(f, r::AlgResIdentity) = r
Base.map(f, r::AlgResElement{V}) where {V} = AlgResElement(f(r.value))

"""
    map_into_option(r, ident_f) -> Union{V, Nothing}

Return `r.value` if `r` is `AlgResElement`, nothing if `AlgResNone`,
else invoke `ident_f(ident_idx)` where `ident_idx` is `trailing_zeros(mask)`.
Matches upstream's `AlgebraicResult::map_into_option`.
"""
map_into_option(r::AlgResNone, ident_f) = nothing
map_into_option(r::AlgResElement, ident_f) = r.value
map_into_option(r::AlgResIdentity, ident_f) = ident_f(trailing_zeros(r.mask))

"""
    into_option(r, idents::AbstractVector) -> Union{V, Nothing}

Return the element value, substituting from `idents` if `r` is identity.
"""
into_option(r::AlgResNone, idents) = nothing
into_option(r::AlgResElement, idents) = r.value
into_option(r::AlgResIdentity, idents) = idents[trailing_zeros(r.mask) + 1]

"""
    unwrap_or_else(r, ident_f, none_f) -> V

Return element value or invoke closures for identity/none.
"""
unwrap_or_else(r::AlgResElement, ident_f, none_f) = r.value
unwrap_or_else(r::AlgResNone, ident_f, none_f) = none_f()
unwrap_or_else(r::AlgResIdentity, ident_f, none_f) = ident_f(trailing_zeros(r.mask))

"""
    from_status(status::AlgebraicStatus, element_f) -> AlgebraicResult

Build an `AlgebraicResult` from an `AlgebraicStatus` + element-builder.
"""
# (defined after AlgebraicStatus below)

# =====================================================================
# AlgebraicStatus
# =====================================================================

"""
    AlgebraicStatus

Status returned from an in-place algebraic operation (takes `&mut self`).
1:1 port of `pathmap::ring::AlgebraicStatus`.

Values are ordered (lowest to highest): `Element < Identity < None`.
Higher values make stronger guarantees about the operation outcome.
"""
@enum AlgebraicStatus::UInt8 begin
    ALG_STATUS_ELEMENT   = 0   # self contains the operation's output
    ALG_STATUS_IDENTITY  = 1   # self was unmodified by the operation
    ALG_STATUS_NONE      = 2   # self was annihilated, now empty
end

is_none(s::AlgebraicStatus)     = s == ALG_STATUS_NONE
is_identity(s::AlgebraicStatus) = s == ALG_STATUS_IDENTITY
is_element(s::AlgebraicStatus)  = s == ALG_STATUS_ELEMENT

"""
    merge_status(a::AlgebraicStatus, b::AlgebraicStatus, a_none::Bool, b_none::Bool) -> AlgebraicStatus

Merge two statuses. `a_none` / `b_none` indicate whether the original
operand values were already `None` (true) or made None by the operation
(false). For ops that can't convert non-None to None (like join), pass
`(true, true)`.
"""
function merge_status(a::AlgebraicStatus, b::AlgebraicStatus,
                      a_none::Bool, b_none::Bool)::AlgebraicStatus
    if a == ALG_STATUS_NONE
        b == ALG_STATUS_NONE     && return ALG_STATUS_NONE
        b == ALG_STATUS_ELEMENT  && return ALG_STATUS_ELEMENT
        # b == ALG_STATUS_IDENTITY
        return a_none ? ALG_STATUS_IDENTITY : ALG_STATUS_ELEMENT
    elseif a == ALG_STATUS_IDENTITY
        b == ALG_STATUS_ELEMENT  && return ALG_STATUS_ELEMENT
        b == ALG_STATUS_IDENTITY && return ALG_STATUS_IDENTITY
        # b == ALG_STATUS_NONE
        return b_none ? ALG_STATUS_IDENTITY : ALG_STATUS_ELEMENT
    else # a == ALG_STATUS_ELEMENT
        return ALG_STATUS_ELEMENT
    end
end

# --- AlgebraicResult -> AlgebraicStatus + constructors ---

"""
    status(r::AlgebraicResult) -> AlgebraicStatus
"""
status(::AlgResNone) = ALG_STATUS_NONE
status(::AlgResElement) = ALG_STATUS_ELEMENT
function status(r::AlgResIdentity)::AlgebraicStatus
    return (r.mask & SELF_IDENT) > 0 ? ALG_STATUS_IDENTITY : ALG_STATUS_ELEMENT
end

"""
    from_status(status::AlgebraicStatus, element_f) -> AlgebraicResult
"""
function from_status(s::AlgebraicStatus, element_f)
    s == ALG_STATUS_NONE     && return AlgResNone()
    s == ALG_STATUS_IDENTITY && return AlgResIdentity(SELF_IDENT)
    return AlgResElement(element_f())
end

# =====================================================================
# AlgebraicResult{Union{Nothing, V}} — flatten helper
# =====================================================================

"""
    flatten(r::AlgebraicResult{Union{Nothing, V}}) -> AlgebraicResult{V}

Flattens an inner `Nothing` into `AlgResNone`. Matches upstream's
`impl<V> AlgebraicResult<Option<V>>` method.
"""
flatten(r::AlgResNone) = r
flatten(r::AlgResIdentity) = r
function flatten(r::AlgResElement)
    r.value === nothing ? AlgResNone() : AlgResElement(r.value)
end

# =====================================================================
# FatAlgebraicResult{V} — internal dual carrier
# =====================================================================

"""
    FatAlgebraicResult{V}

Internal result type carrying both an identity mask AND an optional
element value. Allows operations that produce identity results to
ALSO carry the materialized value. 1:1 port of `pathmap::ring::FatAlgebraicResult`.

Fields:
  - `identity_mask::UInt64` — bitmask of which inputs equal the result
    (0 indicates no identity / Element or None result)
  - `element::Union{V, Nothing}` — materialized value or nothing
"""
mutable struct FatAlgebraicResult{V}
    identity_mask::UInt64
    element::Union{V, Nothing}
end

"""
    fat_none(::Type{V}) -> FatAlgebraicResult{V}
"""
fat_none(::Type{V}) where {V} = FatAlgebraicResult{V}(UInt64(0), nothing)

"""
    fat_element(v::V) -> FatAlgebraicResult{V}
"""
fat_element(v::V) where {V} = FatAlgebraicResult{V}(UInt64(0), v)

"""
    to_algebraic_result(f::FatAlgebraicResult{V}) -> AlgebraicResult{V}

Downconvert. Matches `From<FatAlgebraicResult<V>> for AlgebraicResult<V>`.
"""
function to_algebraic_result(f::FatAlgebraicResult{V})::AlgebraicResult{V} where {V}
    if f.identity_mask > 0
        return AlgResIdentity(f.identity_mask)
    end
    return f.element === nothing ? AlgResNone() : AlgResElement(f.element)
end

# =====================================================================
# Core traits — Lattice, DistributiveLattice
# =====================================================================

"""
    AbstractLattice

Supertype for types implementing union (`pjoin`) and intersection
(`pmeet`) operations. 1:1 port of `pathmap::ring::Lattice`.

Concrete subtypes implement:
  - `pjoin(a::T, b::T) -> AlgebraicResult{T}`
  - `pmeet(a::T, b::T) -> AlgebraicResult{T}`

`join_into!(a, b)` is provided with a default implementation via `pjoin`.
"""
abstract type AbstractLattice end

"""
    pjoin(a, b) -> AlgebraicResult

Union of two lattice elements. To be implemented per concrete type.
"""
function pjoin end

"""
    pmeet(a, b) -> AlgebraicResult

Intersection of two lattice elements.
"""
function pmeet end

"""
    join_into!(self, other) -> AlgebraicStatus

Default mutating version of `pjoin`. Mutates `self` to become the join
of `self` and `other`. Types may override for efficiency.

This is Julia's equivalent of Rust's `trait Lattice` default method
`fn join_into(&mut self, other: Self) -> AlgebraicStatus`.
"""
function join_into!(self, other)
    result = pjoin(self, other)
    return _in_place_default_impl!(result, self, other, _s -> nothing, e -> e)
end

"""
    _in_place_default_impl!(result, self_ref, other, default_f, convert_f) -> AlgebraicStatus

Internal helper for default `join_into!`/`meet_into!` impls. 1:1 port of
`in_place_default_impl`.
"""
function _in_place_default_impl!(result::AlgebraicResult, self_ref, other,
                                 default_f, convert_f)::AlgebraicStatus
    if is_none(result)
        default_f(self_ref)
        return ALG_STATUS_NONE
    elseif is_element(result)
        # We can't reassign self_ref from within this function in Julia (no
        # &mut in the Rust sense). Callers must handle Element result at
        # their level. This is one semantic divergence: Julia's value
        # semantics force the element path back to the caller.
        return ALG_STATUS_ELEMENT
    else # identity
        r = result::AlgResIdentity
        if (r.mask & SELF_IDENT) > 0
            return ALG_STATUS_IDENTITY
        else
            return ALG_STATUS_ELEMENT
        end
    end
end

"""
    AbstractDistributiveLattice

Supertype for lattices that also implement set-difference (`psubtract`).
1:1 port of `pathmap::ring::DistributiveLattice`.

Concrete subtypes implement:
  - `psubtract(a::T, b::T) -> AlgebraicResult{T}`
"""
abstract type AbstractDistributiveLattice <: AbstractLattice end

"""
    psubtract(a, b) -> AlgebraicResult

Set difference / left-minus-right. To be implemented per concrete type.
"""
function psubtract end

"""
    join_all(xs::AbstractVector) -> AlgebraicResult

Consolidate multiple elements via pairwise `pjoin`. Port of upstream
`Lattice::join_all`.
"""
function join_all(xs::AbstractVector{V})::AlgebraicResult{V} where {V}
    isempty(xs) && return AlgResNone()
    # Seed with first element as self-identity
    result = FatAlgebraicResult{V}(SELF_IDENT, xs[1])
    for i in 2:length(xs)
        result = _fat_join(result, xs[i], i - 1)   # i-1 for 0-indexed arg_idx
    end
    return to_algebraic_result(result)
end

# Internal: accumulate join into FatAlgebraicResult (ports FatAlgebraicResult::join)
function _fat_join(f::FatAlgebraicResult{V}, arg::V, arg_idx::Int)::FatAlgebraicResult{V} where {V}
    if f.element === nothing
        return FatAlgebraicResult{V}(f.identity_mask | (UInt64(1) << arg_idx), arg)
    end
    self_element = f.element
    joined = pjoin(self_element, arg)
    if is_none(joined)
        return fat_none(V)
    elseif is_element(joined)
        return fat_element((joined::AlgResElement{V}).value)
    else # identity
        r = joined::AlgResIdentity
        if (r.mask & SELF_IDENT) > 0
            new_mask = f.identity_mask | ((r.mask & COUNTER_IDENT) << (arg_idx - 1))
            return FatAlgebraicResult{V}(new_mask, self_element)
        else
            @assert (r.mask & COUNTER_IDENT) > 0
            new_mask = (r.mask & COUNTER_IDENT) << (arg_idx - 1)
            return FatAlgebraicResult{V}(new_mask, arg)
        end
    end
end

# =====================================================================
# Blanket impls — on Union{Nothing, V} (Rust's Option<V>)
# =====================================================================

# Implements `Lattice for Option<V: Lattice + Clone>`. In Julia, this is
# method dispatch on Union{Nothing, V}.

function pjoin(a::Union{Nothing, V}, b::Union{Nothing, V})::AlgebraicResult{Union{Nothing, V}} where {V}
    if a === nothing
        b === nothing && return AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
        return AlgResIdentity(COUNTER_IDENT)
    else
        b === nothing && return AlgResIdentity(SELF_IDENT)
        r = pjoin(a, b)
        if is_none(r)
            return AlgResElement{Union{Nothing, V}}(nothing)
        elseif is_element(r)
            return AlgResElement{Union{Nothing, V}}((r::AlgResElement{V}).value)
        else
            return r::AlgResIdentity
        end
    end
end

function pmeet(a::Union{Nothing, V}, b::Union{Nothing, V})::AlgebraicResult{Union{Nothing, V}} where {V}
    if a === nothing
        b === nothing && return AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
        return AlgResElement{Union{Nothing, V}}(nothing)
    else
        b === nothing && return AlgResElement{Union{Nothing, V}}(nothing)
        r = pmeet(a, b)
        if is_none(r)
            return AlgResElement{Union{Nothing, V}}(nothing)
        elseif is_element(r)
            return AlgResElement{Union{Nothing, V}}((r::AlgResElement{V}).value)
        else
            return r::AlgResIdentity
        end
    end
end

function psubtract(a::Union{Nothing, V}, b::Union{Nothing, V})::AlgebraicResult{Union{Nothing, V}} where {V}
    if a === nothing
        return AlgResIdentity(SELF_IDENT)
    else
        b === nothing && return AlgResIdentity(SELF_IDENT)
        # Rebind to V to avoid recursing back into this Union{Nothing,V} overload
        av::V = a; bv::V = b
        r = psubtract(av, bv)
        if is_none(r)
            return AlgResElement{Union{Nothing, V}}(nothing)
        elseif is_element(r)
            return AlgResElement{Union{Nothing, V}}((r::AlgResElement{V}).value)
        else
            return r::AlgResIdentity
        end
    end
end

# =====================================================================
# Blanket impls — trivial (unit type)
# =====================================================================

# Rust: `impl Lattice for ()`, `impl DistributiveLattice for ()`
# Julia: `Nothing` is the natural analog

pjoin(::Nothing, ::Nothing) = AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
pmeet(::Nothing, ::Nothing) = AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
psubtract(::Nothing, ::Nothing) = AlgResNone()

# =====================================================================
# Blanket impls — primitives (integers as lattices under max/min)
# =====================================================================

# Rust: `impl Lattice for u64` implements pjoin as max, pmeet as min.
# DistributiveLattice (psubtract) is implemented for some integer types.

for T in (UInt8, UInt16, UInt32, UInt64, UInt128, Int8, Int16, Int32, Int64, Int128)
    @eval begin
        function pjoin(a::$T, b::$T)::AlgebraicResult{$T}
            r = max(a, b)
            if r == a && r == b
                return AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
            elseif r == a
                return AlgResIdentity(SELF_IDENT)
            else
                return AlgResIdentity(COUNTER_IDENT)
            end
        end

        function pmeet(a::$T, b::$T)::AlgebraicResult{$T}
            r = min(a, b)
            if r == a && r == b
                return AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
            elseif r == a
                return AlgResIdentity(SELF_IDENT)
            else
                return AlgResIdentity(COUNTER_IDENT)
            end
        end
    end
end

# psubtract for unsigned ints: saturating subtraction
for T in (UInt8, UInt16, UInt32, UInt64, UInt128)
    @eval begin
        function psubtract(a::$T, b::$T)::AlgebraicResult{$T}
            if b >= a
                return AlgResNone()
            elseif b == 0
                return AlgResIdentity(SELF_IDENT)
            else
                return AlgResElement(a - b)
            end
        end
    end
end

# =====================================================================
# Blanket impls — Bool
# =====================================================================

function pjoin(a::Bool, b::Bool)::AlgebraicResult{Bool}
    r = a | b
    if r == a && r == b
        return AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
    elseif r == a
        return AlgResIdentity(SELF_IDENT)
    else
        return AlgResIdentity(COUNTER_IDENT)
    end
end

function pmeet(a::Bool, b::Bool)::AlgebraicResult{Bool}
    r = a & b
    if r == a && r == b
        return AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
    elseif r == a
        return AlgResIdentity(SELF_IDENT)
    else
        return AlgResIdentity(COUNTER_IDENT)
    end
end

function psubtract(a::Bool, b::Bool)::AlgebraicResult{Bool}
    if !a
        return AlgResNone()
    elseif !b
        return AlgResIdentity(SELF_IDENT)
    else
        # a=true, b=true → a - b = 0 = None
        return AlgResNone()
    end
end

# =====================================================================
# Reference-typed trait variants
# =====================================================================
#
# Upstream ring.rs exposes `LatticeRef` and `DistributiveLatticeRef`,
# which mirror their owned counterparts but allow the result type to
# differ from `Self`. Used for blanket impls on `Option<&T>` (where
# the referenced T is not owned by the caller but the result type
# must still be `Option<T>`).

"""
    AbstractLatticeRef <: AbstractLattice

Reference-typed analog of [`AbstractLattice`]. Upstream:

    pub trait LatticeRef {
        type T;
        fn pjoin(&self, other: &Self) -> AlgebraicResult<Self::T>;
        fn pmeet(&self, other: &Self) -> AlgebraicResult<Self::T>;
    }

The `type T` associated type is handled in Julia via return-type
dispatch — impls may return an `AlgebraicResult{T}` where `T`
differs from the self type.
"""
abstract type AbstractLatticeRef end

"""
    AbstractDistributiveLatticeRef <: AbstractLatticeRef

Reference-typed analog of [`AbstractDistributiveLattice`]. Upstream:

    pub trait DistributiveLatticeRef {
        type T;
        fn psubtract(&self, other: &Self) -> AlgebraicResult<Self::T>;
    }
"""
abstract type AbstractDistributiveLatticeRef <: AbstractLatticeRef end

# =====================================================================
# Quantale (restrict operation)
# =====================================================================

"""
    AbstractQuantale

Used to implement the **restrict** operation. Upstream:

    pub(crate) trait Quantale {
        fn prestrict(&self, other: &Self) -> AlgebraicResult<Self>;
    }

Currently crate-internal in upstream because the semantics of `restrict`
are still being refined. Declared here for API surface fidelity — impls
arrive when concrete node types land.
"""
abstract type AbstractQuantale end

"""
    prestrict(self, other) -> AlgebraicResult

The partial restrict operation. Part of the `Quantale` trait family.
"""
function prestrict end

# =====================================================================
# Internal Hetero mirrors (pub(crate) in upstream)
# =====================================================================
#
# These are "internal mirror" traits where `self` and `other` don't have
# to be exactly the same type, enabling blanket impls. Declared here as
# abstract supertypes so downstream crates can tag the implementations.
# Methods are re-used: `pjoin`, `pmeet`, `psubtract`, `prestrict` — just
# called with a different self/other pairing via multiple dispatch.

"""
    AbstractHeteroLattice

Internal mirror of [`AbstractLattice`] where `self` and `other` may be
different types (enables blanket impls). Upstream `pub(crate)`.
"""
abstract type AbstractHeteroLattice end

"""
    AbstractHeteroDistributiveLattice

Internal mirror of [`AbstractDistributiveLattice`] where `self` and
`other` may be different types. Upstream `pub(crate)`.
"""
abstract type AbstractHeteroDistributiveLattice end

"""
    AbstractHeteroQuantale

Internal mirror of [`AbstractQuantale`] where `self` and `other` may be
different types. Upstream `pub(crate)`.
"""
abstract type AbstractHeteroQuantale end

"""
    convert_hetero(::Type{T}, other) -> T

Part of `HeteroLattice`: convert a value of a different type into the
self type, used by the default `join_into!` impl. One impl per
(Self, Other) pairing.
"""
function convert_hetero end

# =====================================================================
# AlgebraicResult.merge — ports ring.rs AlgebraicResult::merge
# =====================================================================
#
# Combines two independent AlgebraicResults into one, resolving Identity
# by calling self_idents/b_idents to materialise the element when needed,
# and calling merge_f(Option{V}, Option{BV}) -> AlgebraicResult{U} to
# produce the combined element.
#
# self_idents(which::Int)  -> Union{Nothing, V}   (0 = trailing-zeros of mask)
# b_idents(which::Int)     -> Union{Nothing, BV}
# merge_f(a, b)            -> AlgebraicResult{U}
"""
    alg_merge(a, b, self_idents, b_idents, merge_f) → AlgebraicResult

Ports `AlgebraicResult::merge` (ring.rs line 216).
Combines two independent `AlgebraicResult` values by resolving Identity
arms through `self_idents`/`b_idents` callbacks, then calling `merge_f`.
"""
function alg_merge(a, b, self_idents::F1, b_idents::F2, merge_f::F3) where {F1,F2,F3}
    if a isa AlgResNone
        if b isa AlgResNone
            return AlgResNone()
        elseif b isa AlgResElement
            return merge_f(nothing, b.value)
        else  # AlgResIdentity
            si = self_idents(0)
            if si === nothing
                return AlgResIdentity(b.mask)
            else
                bv = b_idents(Int(trailing_zeros(b.mask)))
                return merge_f(nothing, bv)
            end
        end
    elseif a isa AlgResIdentity
        if b isa AlgResNone
            bi = b_idents(0)
            if bi === nothing
                return AlgResIdentity(a.mask)
            else
                sv = self_idents(Int(trailing_zeros(a.mask)))
                return merge_f(sv, nothing)
            end
        elseif b isa AlgResElement
            sv = self_idents(Int(trailing_zeros(a.mask)))
            return merge_f(sv, b.value)
        else  # both Identity
            combined = a.mask & b.mask
            if combined > 0
                return AlgResIdentity(combined)
            else
                sv = self_idents(Int(trailing_zeros(a.mask)))
                bv = b_idents(Int(trailing_zeros(b.mask)))
                return merge_f(sv, bv)
            end
        end
    else  # a isa AlgResElement
        if b isa AlgResNone
            return merge_f(a.value, nothing)
        elseif b isa AlgResElement
            return merge_f(a.value, b.value)
        else  # b isa AlgResIdentity
            bv = b_idents(Int(trailing_zeros(b.mask)))
            return merge_f(a.value, bv)
        end
    end
end

# =====================================================================
# Exports
# =====================================================================

export SELF_IDENT, COUNTER_IDENT
export AlgebraicResult, AlgResNone, AlgResIdentity, AlgResElement
export AlgebraicStatus, ALG_STATUS_ELEMENT, ALG_STATUS_IDENTITY, ALG_STATUS_NONE
export FatAlgebraicResult, fat_none, fat_element
export AbstractLattice, AbstractDistributiveLattice
export AbstractLatticeRef, AbstractDistributiveLatticeRef
export AbstractQuantale
export AbstractHeteroLattice, AbstractHeteroDistributiveLattice, AbstractHeteroQuantale
export is_none, is_identity, is_element, identity_mask, invert_identity
export map_into_option, into_option, unwrap_or_else
export alg_merge
export status, from_status, flatten, to_algebraic_result, merge_status
export pjoin, pmeet, psubtract, prestrict, convert_hetero
export join_into!, join_all
