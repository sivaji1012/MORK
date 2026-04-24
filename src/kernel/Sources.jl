"""
Sources — port of `mork/kernel/src/sources.rs`.

Provides the `ASource` / `AFactor` abstraction for creating factor zippers
in the multi-source query engine.  Mirrors the `Source` trait + implementors.

Julia translation notes
========================
  - Rust `Source` trait → Julia abstract type `AbstractSource`
  - Rust `AFactor<'trie>` enum (PolyZipper derive) → Union type `AFactorZipper`
  - Rust `gen move` coroutine → regular iterator / Array
  - Rust `ACTMmapZipper`, `Z3Source`, `CmpSource` → stubbed (not yet ported)
  - Rust `destruct!` proc-macro → direct byte inspection
  - ResourceRequest/Resource enums → Julia enums/structs
"""

# =====================================================================
# ResourceRequest / Resource
# =====================================================================

"""
    ResourceRequest

Which backing store a source needs access to.
Mirrors `ResourceRequest` in sources.rs.
"""
@enum ResourceRequestKind begin
    RREQ_BTM
    RREQ_ACT
    RREQ_Z3
end

struct ResourceRequest
    kind ::ResourceRequestKind
    name ::String   # ACT filename or Z3 instance name; empty for BTM
end

ResourceRequest(k::ResourceRequestKind) = ResourceRequest(k, "")

# =====================================================================
# AbstractSource / ASource dispatch
# =====================================================================

"""
    AbstractSource

Abstract type for query factor sources.
Mirrors the `Source` trait in sources.rs.
"""
abstract type AbstractSource end

"""
    source_requests(s) → Vector{ResourceRequest}

List of resources this source requires.
"""
function source_requests end

"""
    source_factor(s, btm) → ReadZipperCore

Create the read zipper (factor) for this source.
"""
function source_factor end

# ── CompatSource (BTM, no prefix) ────────────────────────────────────

"""
    CompatSource

Plain BTM read zipper with no prefix constraint.
Mirrors `CompatSource` in sources.rs.
"""
struct CompatSource
    expr ::MORK.Expr
end

source_requests(s::CompatSource) = [ResourceRequest(RREQ_BTM)]

function source_factor(s::CompatSource, btm::PathMap{UnitVal})
    read_zipper_at_path(btm, UInt8[])
end

# ── BTMSource (BTM, with [2] BTM prefix) ─────────────────────────────

"""
    BTMSource

BTM read zipper scoped to the `[2] BTM` prefix subtrie.
Mirrors `BTMSource` in sources.rs.
"""
struct BTMSource
    expr ::MORK.Expr
end

const _BTM_SOURCE_PREFIX = UInt8[
    item_byte(ExprArity(UInt8(2))),
    item_byte(ExprSymbol(UInt8(3))),
    UInt8('B'), UInt8('T'), UInt8('M')
]

source_requests(s::BTMSource) = [ResourceRequest(RREQ_BTM)]

function source_factor(s::BTMSource, btm::PathMap{UnitVal})
    inner = read_zipper_at_path(btm, UInt8[])
    PrefixZipper(_BTM_SOURCE_PREFIX, inner)
end

# ── ACTSource (memory-mapped ACT file) ───────────────────────────────

"""
    ACTSource

Reads from an ArenaCompactTree memory-mapped file.
Mirrors `ACTSource` in sources.rs.  NOT YET PORTED — stubs throw.
"""
struct ACTSource
    expr ::MORK.Expr
    act  ::String
end

source_requests(s::ACTSource) = [ResourceRequest(RREQ_ACT, s.act)]

source_factor(s::ACTSource, btm::PathMap{UnitVal}) =
    error("ACTSource not yet ported")

# ── CmpSource (equality / inequality comparison) ──────────────────────

"""
    CmpSource

DependentZipper-based equality/inequality comparison source.
Mirrors `CmpSource` in sources.rs.  NOT YET PORTED — stubs throw.
"""
struct CmpSource
    expr ::MORK.Expr
    cmp  ::Int   # 0 = ==, 1 = !=
end

source_requests(s::CmpSource) = [ResourceRequest(RREQ_BTM)]

# Mirrors CmpSource::source in sources.rs.
# Returns PrefixZipper(EQ/NE_PREFIX, DependentZipper(btm_rz, policy))
# The DependentZipper extends the BTM read zipper's path with the secondary,
# so origin_path = [3]== + (primary_path)(secondary_path).
function source_factor(s::CmpSource, btm::PathMap{UnitVal})
    cmp      = s.cmp
    map_clone = deepcopy(btm)   # for != : need full BTM copy to subtract from

    # Policy: (payload, path, c) → (payload, Union{nothing, ReadZipperCore})
    # Mirrors CmpSource::policy in sources.rs
    function cmp_policy(payload, path::Vector{UInt8}, c::Int)
        if c == 0
            if cmp == 0  # ==: secondary = single-entry PathMap at this path
                single = PathMap{UnitVal}()
                set_val_at!(single, path, UNIT_VAL)
                return (payload, read_zipper(single))
            else          # !=: secondary = BTM clone minus this path
                complement = deepcopy(map_clone)
                remove_val_at!(complement, path)
                return (payload, read_zipper(complement))
            end
        else
            return (payload, nothing)
        end
    end

    primary_rz = read_zipper_at_path(btm, UInt8[])
    dpz        = DependentZipper(primary_rz, nothing, cmp_policy)
    prefix     = cmp == 0 ? _EQ_PREFIX : _NE_PREFIX
    PrefixZipper(prefix, dpz)
end

const _EQ_PREFIX = UInt8[item_byte(ExprArity(UInt8(3))), item_byte(ExprSymbol(UInt8(2))), UInt8('='), UInt8('=')]
const _NE_PREFIX = UInt8[item_byte(ExprArity(UInt8(3))), item_byte(ExprSymbol(UInt8(2))), UInt8('!'), UInt8('=')]

# ── ASource — dispatch wrapper ────────────────────────────────────────

"""
    ASource

Union type dispatching to the correct concrete source implementation.
Mirrors `ASource` enum in sources.rs.
"""
const ASource = Union{CompatSource, BTMSource, ACTSource, CmpSource}

"""
    asource_new(expr) → ASource

Construct the appropriate source for the given pattern expression.
Mirrors `ASource::new` in sources.rs.
"""
function asource_new(e::MORK.Expr) :: ASource
    buf = e.buf
    length(buf) >= 1 || return CompatSource(e)

    # [2] BTM ...
    if length(buf) >= 5 &&
       buf[1] == item_byte(ExprArity(UInt8(2))) &&
       buf[2] == item_byte(ExprSymbol(UInt8(3))) &&
       buf[3] == UInt8('B') && buf[4] == UInt8('T') && buf[5] == UInt8('M')
        return BTMSource(e)
    end

    # [3] ACT <name> ...
    if length(buf) >= 5 &&
       buf[1] == item_byte(ExprArity(UInt8(3))) &&
       buf[2] == item_byte(ExprSymbol(UInt8(3))) &&
       buf[3] == UInt8('A') && buf[4] == UInt8('C') && buf[5] == UInt8('T')
        # extract the ACT name from the expression bytes
        name_tag = byte_item(buf[6])
        if name_tag isa ExprSymbol
            act_name = String(buf[7 : 6 + Int(name_tag.size)])
            return ACTSource(e, act_name)
        end
    end

    # [3] == ... or [3] != ...
    if length(buf) >= 4 &&
       buf[1] == item_byte(ExprArity(UInt8(3))) &&
       buf[2] == item_byte(ExprSymbol(UInt8(2)))
        if buf[3] == UInt8('=') && buf[4] == UInt8('=')
            return CmpSource(e, 0)
        elseif buf[3] == UInt8('!') && buf[4] == UInt8('=')
            return CmpSource(e, 1)
        end
    end

    CompatSource(e)   # fallback
end

asource_compat(e::MORK.Expr) = CompatSource(e)

# =====================================================================
# Exports
# =====================================================================

export ResourceRequestKind, RREQ_BTM, RREQ_ACT, RREQ_Z3
export ResourceRequest
export AbstractSource, CompatSource, BTMSource, ACTSource, CmpSource
export ASource, asource_new, asource_compat
export source_requests, source_factor
