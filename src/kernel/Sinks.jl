"""
Sinks — port of `mork/kernel/src/sinks.rs`.

Provides the `AbstractSink` / `ASink` abstraction for writing query results.
Each sink consumes pattern-matched paths and applies some operation.

Julia translation notes
========================
  - Rust `Sink` trait → Julia abstract type `AbstractSink` + functions
  - Rust `WriteZipperTracked` arg → mutating the btm PathMap directly
  - Rust `USink`, `AUSink` (coroutine-based) → iterative
  - Rust `WASMSink` (wasmtime), `PureSink` (eval-ffi), `Z3Sink` → stubbed
  - Rust `ACTSink` → stubbed (requires ArenaCompactTree mutation)
  - `AlgebraicStatus` return from `subtract_into`/`join_into` → Bool
"""

# =====================================================================
# AbstractSink interface
# =====================================================================

"""
    AbstractSink

Abstract type for write sinks in the MORK query/transform engine.
Mirrors the `Sink` trait in sinks.rs.

Concrete sinks implement:
  - `sink_apply!(s, bindings, path_bytes, btm)` — handle one matched path
  - `sink_finalize!(s, btm)::Bool`              — commit results, return changed
"""
abstract type AbstractSink end

function sink_apply! end
function sink_finalize! end

# =====================================================================
# Helper: compute the constant prefix of an expression
# =====================================================================

"""
    _sink_prefix(e) → Vector{UInt8}

Return the longest constant prefix of expression `e` — the bytes before the
first variable or compound subexpression.  Used by sinks to scope their
WriteZipper to the appropriate path.
"""
function _sink_prefix(e::MORK.Expr) :: Vector{UInt8}
    buf = e.buf
    n   = length(buf)
    i   = 1
    while i <= n
        b   = buf[i]
        tag = try byte_item(b) catch; break end
        if tag isa ExprNewVar || tag isa ExprVarRef
            break
        elseif tag isa ExprArity
            i += 1   # include the arity byte but then stop (children may vary)
            break
        elseif tag isa ExprSymbol
            i += 1 + Int(tag.size)   # include symbol bytes
        end
    end
    buf[1:i-1]
end

# =====================================================================
# CompatSink — insert path directly into BTM
# =====================================================================

"""
    CompatSink

Insert each matched path verbatim into the destination PathMap.
Mirrors `CompatSink` in sinks.rs.
"""
mutable struct CompatSink <: AbstractSink
    expr    ::MORK.Expr
    changed ::Bool
end

CompatSink(e::MORK.Expr) = CompatSink(e, false)

function sink_apply!(s::CompatSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{Nothing})
    set_val_at!(btm, path, nothing) === nothing && (s.changed = true)
end

sink_finalize!(s::CompatSink, ::PathMap{Nothing}) :: Bool = s.changed

# =====================================================================
# AddSink — [2] + <expr>: insert after skipping [2]+ prefix
# =====================================================================

"""
    AddSink

Insert matched paths, skipping the first 3 bytes (`[2] +`).
Mirrors `AddSink` in sinks.rs.
"""
mutable struct AddSink <: AbstractSink
    expr    ::MORK.Expr
    changed ::Bool
end

AddSink(e::MORK.Expr) = AddSink(e, false)

function sink_apply!(s::AddSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{Nothing})
    length(path) > 3 || return
    set_val_at!(btm, path[4:end], nothing) === nothing && (s.changed = true)
end

sink_finalize!(s::AddSink, ::PathMap{Nothing}) :: Bool = s.changed

# =====================================================================
# RemoveSink — [2] - <expr>: collect paths to remove, apply in finalize
# =====================================================================

"""
    RemoveSink

Collect paths to remove, then subtract them from BTM on finalize.
Mirrors `RemoveSink` in sinks.rs.
"""
mutable struct RemoveSink <: AbstractSink
    expr    ::MORK.Expr
    to_remove::Vector{Vector{UInt8}}
end

RemoveSink(e::MORK.Expr) = RemoveSink(e, Vector{UInt8}[])

function sink_apply!(s::RemoveSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{Nothing})
    length(path) > 3 || return
    push!(s.to_remove, path[4:end])
end

function sink_finalize!(s::RemoveSink, btm::PathMap{Nothing}) :: Bool
    changed = false
    for p in s.to_remove
        old = get_val_at(btm, p)
        if old !== nothing || begin
            # check if path exists as a key (for PathMap{Nothing}, old===nothing always)
            wz = write_zipper(btm)
            wz_descend_to!(wz, p)
            v = wz_remove_val!(wz, true)
            v !== nothing
        end
            changed = true
        end
    end
    changed
end

# =====================================================================
# HeadSink — [3] head <N> <expr>: keep top-N lexicographic paths
# =====================================================================

"""
    HeadSink

Keep at most `max` lexicographically smallest paths.
Mirrors `HeadSink` in sinks.rs.
"""
mutable struct HeadSink <: AbstractSink
    expr    ::MORK.Expr
    head    ::Vector{Vector{UInt8}}   # collected paths
    skip    ::Int                     # bytes to skip in each matched path
    max     ::Int
end

function HeadSink(e::MORK.Expr)
    buf = e.buf
    # Expect [3] head <num_symbol> <pattern>
    # skip = 1 (arity) + 1+4 (head symbol) + 1+len(num) bytes
    # parse max from the third child
    skip = 6   # [3] head = 6 bytes minimum; runtime parsing below
    if length(buf) >= 7 && byte_item(buf[1]) isa ExprArity
        # buf[1]=Arity(3), buf[2]=SymbolSize(4), buf[3..6]='head', buf[7]=num symbol
        if length(buf) >= 8
            num_tag = byte_item(buf[7])
            if num_tag isa ExprSymbol
                num_str = String(buf[8 : 7 + Int(num_tag.size)])
                max_n   = tryparse(Int, num_str)
                skip    = 1 + 1 + 4 + 1 + Int(num_tag.size)  # arity+head_sym+num_sym
                max_n !== nothing && return HeadSink(e, Vector{UInt8}[], skip, max_n)
            end
        end
    end
    HeadSink(e, Vector{UInt8}[], skip, 10)  # default max=10
end

function sink_apply!(s::HeadSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{Nothing})
    length(path) <= s.skip && return
    mpath = path[s.skip+1:end]
    if length(s.head) < s.max
        push!(s.head, mpath)
        sort!(s.head)
    elseif mpath < s.head[end]
        s.head[end] = mpath
        sort!(s.head)
    end
end

function sink_finalize!(s::HeadSink, btm::PathMap{Nothing}) :: Bool
    changed = false
    for p in s.head
        old = get_val_at(btm, p)
        set_val_at!(btm, p, nothing)
        old === nothing && (changed = true)
    end
    changed
end

# =====================================================================
# CountSink — [4] count <result_sym> <source_sym> <expr>: count unique
# =====================================================================

"""
    CountSink

Count unique matched expressions and store the count at a fixed key.
Mirrors `CountSink` in sinks.rs.
"""
mutable struct CountSink <: AbstractSink
    expr    ::MORK.Expr
    unique  ::PathMap{Nothing}
    skip    ::Int
end

function CountSink(e::MORK.Expr)
    # [4] count <result> <source> <pattern> — skip varies
    CountSink(e, PathMap{Nothing}(), 0)
end

function sink_apply!(s::CountSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{Nothing})
    set_val_at!(s.unique, path, nothing)
end

function sink_finalize!(s::CountSink, btm::PathMap{Nothing}) :: Bool
    cnt = val_count(s.unique)
    cnt_bytes = Vector{UInt8}(string(cnt))
    key = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(cnt_bytes))))], cnt_bytes)
    old = get_val_at(btm, key)
    set_val_at!(btm, key, nothing)
    old === nothing
end

# =====================================================================
# SumSink — [4] sum <result_sym> <source_sym> <expr>: sum matched values
# =====================================================================

"""
    SumSink

Sum matched big-endian integer values and store result.
Mirrors `SumSink` in sinks.rs (simplified).
"""
mutable struct SumSink <: AbstractSink
    expr     ::MORK.Expr
    unique   ::PathMap{Nothing}
end

SumSink(e::MORK.Expr) = SumSink(e, PathMap{Nothing}())

function sink_apply!(s::SumSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{Nothing})
    set_val_at!(s.unique, path, nothing)
end

function sink_finalize!(s::SumSink, btm::PathMap{Nothing}) :: Bool
    total = Int64(0)
    rz    = read_zipper(s.unique)
    while zipper_to_next_val!(rz)
        p = collect(zipper_path(rz))
        # Try to interpret as big-endian integer symbol
        if !isempty(p)
            tag = byte_item(p[1])
            if tag isa ExprSymbol && Int(tag.size) <= 8
                slice = p[2 : 1 + Int(tag.size)]
                v = Int64(0)
                for b in slice; v = v << 8 | Int64(b); end
                total += v
            end
        end
    end
    sum_bytes = reinterpret(UInt8, [hton(total)])
    key = vcat(UInt8[item_byte(ExprSymbol(UInt8(8)))], collect(sum_bytes))
    old = get_val_at(btm, key)
    set_val_at!(btm, key, nothing)
    old === nothing
end

# =====================================================================
# AndSink — [4] and <result_sym> <source_sym> <expr>: logical AND
# =====================================================================

"""
    AndSink

Logical AND of matched boolean flag values.
Mirrors `AndSink` in sinks.rs (simplified).
"""
mutable struct AndSink <: AbstractSink
    expr   ::MORK.Expr
    result ::Bool
end

AndSink(e::MORK.Expr) = AndSink(e, true)

function sink_apply!(s::AndSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{Nothing})
    # Check if path ends in a "false" symbol
    if !isempty(path)
        p    = collect(path)
        tag  = byte_item(p[1])
        if tag isa ExprSymbol
            sym = String(p[2 : 1 + Int(tag.size)])
            sym == "false" && (s.result = false)
        end
    end
end

function sink_finalize!(s::AndSink, btm::PathMap{Nothing}) :: Bool
    key = s.result ? Vector{UInt8}("true") : Vector{UInt8}("false")
    key_enc = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(key))))], key)
    old = get_val_at(btm, key_enc)
    set_val_at!(btm, key_enc, nothing)
    old === nothing
end

# =====================================================================
# Stub sinks (require external crates)
# =====================================================================

struct ACTSink  <: AbstractSink; expr::MORK.Expr; end
struct WASMSink <: AbstractSink; expr::MORK.Expr; end
struct PureSink <: AbstractSink; expr::MORK.Expr; end
struct Z3Sink   <: AbstractSink; expr::MORK.Expr; end
struct USink    <: AbstractSink; expr::MORK.Expr; end
struct AUSink   <: AbstractSink; expr::MORK.Expr; end
struct HashSink <: AbstractSink; expr::MORK.Expr; end

for T in (ACTSink, WASMSink, PureSink, Z3Sink, USink, AUSink, HashSink)
    @eval sink_apply!(::$T, ::Dict, ::Vector{UInt8}, ::PathMap{Nothing}) =
        error($(string(T)) * " not yet ported")
    @eval sink_finalize!(::$T, ::PathMap{Nothing}) =
        error($(string(T)) * " not yet ported")
end

# Float reduction sinks
struct FloatReductionSink{R} <: AbstractSink
    expr ::MORK.Expr
    op   ::Symbol   # :sum, :min, :max, :prod
end

FloatReductionSink(e::MORK.Expr, op::Symbol) = FloatReductionSink{op}(e, op)

function sink_apply!(s::FloatReductionSink, bindings, path, btm)
    # TODO: float extraction and reduction
end

sink_finalize!(::FloatReductionSink, ::PathMap{Nothing}) = false

# =====================================================================
# ASink — dispatch union
# =====================================================================

"""
    asink_new(expr) → AbstractSink

Construct the appropriate sink from the pattern expression.
Mirrors `ASink::new` in sinks.rs.
"""
function asink_new(e::MORK.Expr) :: AbstractSink
    buf = e.buf
    length(buf) < 2 && return CompatSink(e)

    a1 = buf[1]; a2 = buf[2]

    # [2] + → AddSink
    if a1 == item_byte(ExprArity(UInt8(2))) && a2 == item_byte(ExprSymbol(UInt8(1))) &&
       length(buf) >= 3 && buf[3] == UInt8('+')
        return AddSink(e)
    end

    # [2] - → RemoveSink
    if a1 == item_byte(ExprArity(UInt8(2))) && a2 == item_byte(ExprSymbol(UInt8(1))) &&
       length(buf) >= 3 && buf[3] == UInt8('-')
        return RemoveSink(e)
    end

    # [2] U → USink
    if a1 == item_byte(ExprArity(UInt8(2))) && a2 == item_byte(ExprSymbol(UInt8(1))) &&
       length(buf) >= 3 && buf[3] == UInt8('U')
        return USink(e)
    end

    # [2] AU → AUSink
    if a1 == item_byte(ExprArity(UInt8(2))) && a2 == item_byte(ExprSymbol(UInt8(2))) &&
       length(buf) >= 4 && buf[3] == UInt8('A') && buf[4] == UInt8('U')
        return AUSink(e)
    end

    # [3] head N <expr> → HeadSink
    if a1 == item_byte(ExprArity(UInt8(3))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
       length(buf) >= 6 && buf[3:6] == UInt8[UInt8('h'), UInt8('e'), UInt8('a'), UInt8('d')]
        return HeadSink(e)
    end

    # [4] count <r> <s> <p> → CountSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(5))) &&
       length(buf) >= 7 && buf[3:7] == Vector{UInt8}("count")
        return CountSink(e)
    end

    # [4] hash → HashSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
       length(buf) >= 6 && buf[3:6] == Vector{UInt8}("hash")
        return HashSink(e)
    end

    # [4] sum → SumSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(3))) &&
       length(buf) >= 5 && buf[3:5] == Vector{UInt8}("sum")
        return SumSink(e)
    end

    # [4] and → AndSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(3))) &&
       length(buf) >= 5 && buf[3:5] == Vector{UInt8}("and")
        return AndSink(e)
    end

    # [4] fsum / fmin / fmax → FloatReductionSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(4))) && length(buf) >= 6
        if buf[3] == UInt8('f') && buf[4] == UInt8('s')
            return FloatReductionSink(e, :sum)
        elseif buf[3] == UInt8('f') && buf[4] == UInt8('m') && buf[5] == UInt8('i')
            return FloatReductionSink(e, :min)
        elseif buf[3] == UInt8('f') && buf[4] == UInt8('m') && buf[5] == UInt8('a')
            return FloatReductionSink(e, :max)
        end
    end

    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(5))) &&
       length(buf) >= 7 && buf[3] == UInt8('f') && buf[4] == UInt8('p')
        return FloatReductionSink(e, :prod)
    end

    # [3] ACT → ACTSink
    if a1 == item_byte(ExprArity(UInt8(3))) && a2 == item_byte(ExprSymbol(UInt8(3))) &&
       length(buf) >= 5 && buf[3:5] == Vector{UInt8}("ACT")
        return ACTSink(e)
    end

    # [3] wasm → WASMSink
    if a1 == item_byte(ExprArity(UInt8(3))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
       length(buf) >= 6 && buf[3:6] == Vector{UInt8}("wasm")
        return WASMSink(e)
    end

    CompatSink(e)   # fallback
end

asink_compat(e::MORK.Expr) = CompatSink(e)

# =====================================================================
# Exports
# =====================================================================

export AbstractSink, sink_apply!, sink_finalize!
export CompatSink, AddSink, RemoveSink, HeadSink
export CountSink, SumSink, AndSink
export ACTSink, WASMSink, PureSink, Z3Sink, USink, AUSink, HashSink
export FloatReductionSink
export asink_new, asink_compat
