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
                     path::Vector{UInt8}, btm::PathMap{UnitVal})
    set_val_at!(btm, path, UNIT_VAL) === nothing && (s.changed = true)
end

sink_finalize!(s::CompatSink, ::PathMap{UnitVal}) :: Bool = s.changed

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
                     path::Vector{UInt8}, btm::PathMap{UnitVal})
    length(path) > 3 || return
    set_val_at!(btm, path[4:end], UNIT_VAL) === nothing && (s.changed = true)
end

sink_finalize!(s::AddSink, ::PathMap{UnitVal}) :: Bool = s.changed

# =====================================================================
# RemoveSink — [2] - <expr>: collect paths to remove, apply in finalize
# =====================================================================

"""
    RemoveSink

Collect paths to remove, then subtract them from BTM on finalize.
Mirrors `RemoveSink` in sinks.rs.
"""
# Upstream: collects paths into an internal PathMap, then calls wz.subtract_into
# on finalize — one trie-level operation instead of N individual removes.
mutable struct RemoveSink <: AbstractSink
    expr   ::MORK.Expr
    remove ::PathMap{UnitVal}
end

RemoveSink(e::MORK.Expr) = RemoveSink(e, PathMap{UnitVal}())

function sink_apply!(s::RemoveSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{UnitVal})
    length(path) > 3 || return
    set_val_at!(s.remove, path[4:end], UNIT_VAL)
end

function sink_finalize!(s::RemoveSink, btm::PathMap{UnitVal}) :: Bool
    # Subtract collected paths from btm using per-path removal.
    changed = false
    rz = read_zipper(s.remove)
    while zipper_to_next_val!(rz)
        path = collect(zipper_path(rz))
        old = get_val_at(btm, path)
        if old !== nothing
            remove_val_at!(btm, path)
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
# Upstream: collects paths into an internal PathMap (not Vector).
# top tracks the lexicographically largest path in head (for O(1) displacement check).
# finalize uses wz_join_into! (one trie-level merge instead of N individual inserts).
mutable struct HeadSink <: AbstractSink
    expr  ::MORK.Expr
    head  ::PathMap{UnitVal}  # collected paths — mirrors upstream PathMap<()>
    skip  ::Int
    count ::Int
    max   ::Int
    top   ::Vector{UInt8}     # largest path in head (mirrors upstream top: Vec<u8>)
end

function HeadSink(e::MORK.Expr)
    buf = e.buf
    skip = 6
    max_n = 10
    if length(buf) >= 8 && byte_item(buf[1]) isa ExprArity
        num_tag = byte_item(buf[7])
        if num_tag isa ExprSymbol
            num_str = String(buf[8 : 7 + Int(num_tag.size)])
            parsed  = tryparse(Int, num_str)
            if parsed !== nothing
                skip  = 1 + 1 + 4 + 1 + Int(num_tag.size)
                max_n = parsed
            end
        end
    end
    HeadSink(e, PathMap{UnitVal}(), skip, 0, max_n, UInt8[])
end

function sink_apply!(s::HeadSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{UnitVal})
    length(path) <= s.skip && return
    mpath = path[s.skip+1:end]
    if s.count == s.max
        # At capacity: only accept if mpath < top (displaces current largest)
        if mpath >= s.top
            return  # doesn't displace
        end
        set_val_at!(s.head, mpath, UNIT_VAL)
        remove_val_at!(s.head, s.top)
        # find new top: descend to last path in head trie
        rz = read_zipper(s.head)
        zipper_descend_last_path!(rz)
        s.top = collect(zipper_path(rz))
    else
        if set_val_at!(s.head, mpath, UNIT_VAL) === nothing  # newly inserted
            s.count += 1
            if isempty(s.top) || mpath > s.top
                s.top = copy(mpath)
            end
        end
    end
end

function sink_finalize!(s::HeadSink, btm::PathMap{UnitVal}) :: Bool
    wz = write_zipper(btm)
    status = wz_join_into!(wz, s.head.root)
    status != ALG_STATUS_IDENTITY
end

# =====================================================================
# CountSink — [4] count <result_sym> <source_sym> <expr>: count unique
# =====================================================================

"""
    CountSink

Count unique source values per output template, then store the count.
Mirrors `CountSink` in sinks.rs.

Accumulating sink: sink_apply! collects sources, sink_finalize! counts and writes.
Used by space_transform_multi_multi! as a persistent sink (not per-match).
"""
mutable struct CountSink <: AbstractSink
    expr        ::MORK.Expr
    # Groups: (template_bytes → unique_sources PathMap)
    # Each template may be different across matches (different outer bindings).
    by_template ::Vector{Tuple{Vector{UInt8}, PathMap{UnitVal}}}
end

CountSink(e::MORK.Expr) = CountSink(e, Tuple{Vector{UInt8}, PathMap{UnitVal}}[])

function sink_apply!(s::CountSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{UnitVal})
    # path = bound expression bytes: (count <template> <var> <source>)
    # Parse the 4-arg count expression to extract template and source.
    length(path) < 7 && return
    args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), MORK.Expr(path)), args)
    length(args) < 4 && return

    # Extract template bytes (arg2) and source bytes (arg4)
    tpl_start = Int(args[2].offset) + 1
    tpl_end   = _expr_end_offset(path, tpl_start)
    tpl_bytes = path[tpl_start : tpl_end-1]

    src_start = Int(args[4].offset) + 1
    src_end   = _expr_end_offset(path, src_start)
    src_bytes = path[src_start : src_end-1]

    # Find or create the entry for this template
    entry = findfirst(t -> t[1] == tpl_bytes, s.by_template)
    if entry === nothing
        push!(s.by_template, (tpl_bytes, PathMap{UnitVal}()))
        entry = length(s.by_template)
    end
    set_val_at!(s.by_template[entry][2], src_bytes, UNIT_VAL)
end

function sink_finalize!(s::CountSink, btm::PathMap{UnitVal}) :: Bool
    changed = false
    for (tpl_bytes, sources) in s.by_template
        cnt     = val_count(sources)
        cnt_str = string(cnt)
        cnt_mork = vcat(item_byte(ExprSymbol(UInt8(length(cnt_str)))), Vector{UInt8}(cnt_str))
        out = _pure_substitute_first_var(tpl_bytes, 1, length(tpl_bytes), cnt_mork)
        out === nothing && continue
        old = get_val_at(btm, out)
        set_val_at!(btm, out, UNIT_VAL)
        old === nothing && (changed = true)
    end
    changed
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
    unique   ::PathMap{UnitVal}
end

SumSink(e::MORK.Expr) = SumSink(e, PathMap{UnitVal}())

function sink_apply!(s::SumSink, bindings::Dict{ExprVar,ExprEnv},
                     path::Vector{UInt8}, btm::PathMap{UnitVal})
    set_val_at!(s.unique, path, UNIT_VAL)
end

function sink_finalize!(s::SumSink, btm::PathMap{UnitVal}) :: Bool
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
    set_val_at!(btm, key, UNIT_VAL)
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
                     path::Vector{UInt8}, btm::PathMap{UnitVal})
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

function sink_finalize!(s::AndSink, btm::PathMap{UnitVal}) :: Bool
    key = s.result ? Vector{UInt8}("true") : Vector{UInt8}("false")
    key_enc = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(key))))], key)
    old = get_val_at(btm, key_enc)
    set_val_at!(btm, key_enc, UNIT_VAL)
    old === nothing
end

# =====================================================================
# Stub sinks (require external crates)
# =====================================================================

struct ACTSink  <: AbstractSink; expr::MORK.Expr; end
struct WASMSink <: AbstractSink; expr::MORK.Expr; end
struct Z3Sink   <: AbstractSink; expr::MORK.Expr; end
struct USink    <: AbstractSink; expr::MORK.Expr; end
struct AUSink   <: AbstractSink; expr::MORK.Expr; end
struct HashSink <: AbstractSink; expr::MORK.Expr; end

for T in (ACTSink, WASMSink, Z3Sink, USink, AUSink, HashSink)
    @eval sink_apply!(::$T, ::Dict, ::Vector{UInt8}, ::PathMap{UnitVal}) =
        error($(string(T)) * " not yet ported")
    @eval sink_finalize!(::$T, ::PathMap{UnitVal}) =
        error($(string(T)) * " not yet ported")
end

# =====================================================================
# PureSink — port of PureSink in sinks.rs
# (pure <template> <var> <formula>)
# Evaluates <formula> using PURE_OPS, substitutes result into <template>,
# and stores the result in the space.
# =====================================================================

mutable struct PureSink <: AbstractSink
    expr    ::MORK.Expr
    changed ::Bool
end
PureSink(e::MORK.Expr) = PureSink(e, false)

"""
    _pure_eval_formula(buf, off) → Union{Vector{UInt8}, Nothing}

Recursively evaluate a pure-ops formula rooted at byte offset `off` (1-based).

INVARIANT: returns a COMPLETE MORK sub-expression (header byte included):
  - Scalar symbol result  → ExprSymbol(n) + payload bytes
  - Compound expression   → ExprArity(n) + children (for `tuple`, `explode_symbol`, `quote`)
  - Skip signal           → nothing  (e.g. `ifnz` with zero cond and no else)

Args passed to `pure_apply` are stripped of their header (raw payloads).

Mirrors EvalScope::eval in experiments/eval/src/lib.rs.
"""
function _pure_eval_formula(buf::Vector{UInt8}, off::Int) :: Union{Vector{UInt8}, Nothing}
    off > length(buf) && return nothing
    tag = byte_item(buf[off])

    if tag isa ExprSymbol
        # Return complete MORK symbol (header + payload)
        n = Int(tag.size)
        return buf[off : off+n]
    end

    if tag isa ExprArity
        n_args = Int(tag.arity) - 1   # first child is the functor name
        n_args < 0 && return nothing

        # Parse functor name
        fn_off = off + 1
        fn_tag = byte_item(buf[fn_off])
        fn_tag isa ExprSymbol || return nothing
        fn_size = Int(fn_tag.size)
        fn_name = String(buf[fn_off+1 : fn_off+fn_size])

        # Collect arg byte spans
        arg_spans = UnitRange{Int}[]
        cur = fn_off + 1 + fn_size
        for _ in 1:n_args
            cur > length(buf) && break
            span_end = _expr_end_offset(buf, cur)
            push!(arg_spans, cur:span_end-1)
            cur = span_end
        end

        # ── ifnz: short-circuit conditional ──────────────────────────
        if fn_name == "ifnz" && length(arg_spans) >= 3
            cond = _pure_eval_formula(buf, first(arg_spans[1]))
            cond === nothing && return nothing
            cond_payload = _pure_strip_header(cond)
            is_nz = !all(==(0x00), cond_payload)
            # arg_spans[2] is the "then" keyword — skip it
            if is_nz
                return _pure_eval_formula(buf, first(arg_spans[3]))
            elseif length(arg_spans) == 5
                return _pure_eval_formula(buf, first(arg_spans[5]))
            else
                return nothing
            end
        end

        # ── quote: return the inner expression bytes verbatim ─────────
        if fn_name == "'" && length(arg_spans) >= 1
            return buf[arg_spans[1]]
        end

        # ── Evaluate all args eagerly; pass raw payloads to pure_apply ─
        arg_results = Vector{UInt8}[]
        for span in arg_spans
            r = _pure_eval_formula(buf, first(span))
            r === nothing && return nothing
            push!(arg_results, _pure_strip_header(r))
        end

        # Ops that return full MORK expressions (not scalar payloads)
        if fn_name == "tuple" || fn_name == "explode_symbol"
            f = get(PURE_OPS, fn_name, nothing)
            f === nothing && return nothing
            result_mork = try f(arg_results) catch; return nothing end
            return result_mork isa Vector{UInt8} ? result_mork : nothing
        end

        # Standard scalar ops: get payload, wrap as ExprSymbol
        result_payload = try
            pure_apply(fn_name, arg_results)
        catch
            return nothing
        end
        n = length(result_payload)
        n == 0 && return nothing
        return vcat(item_byte(ExprSymbol(UInt8(n))), result_payload)
    end

    nothing
end

"""
    _pure_strip_header(mork_expr) → Vector{UInt8}

Strip the leading ExprSymbol header byte from a scalar MORK expression to get
raw payload bytes. For arity expressions (tuple etc.), return as-is.
"""
function _pure_strip_header(mork_expr::Vector{UInt8}) :: Vector{UInt8}
    isempty(mork_expr) && return mork_expr
    tag = try byte_item(mork_expr[1]) catch; return mork_expr end
    tag isa ExprSymbol ? mork_expr[2:end] : mork_expr
end

"""
    _expr_end_offset(buf, off) → Int

Return the offset just past the expression starting at `off` (exclusive end).
"""
function _expr_end_offset(buf::Vector{UInt8}, off::Int) :: Int
    off > length(buf) && return off
    tag = byte_item(buf[off])
    if tag isa ExprSymbol
        return off + 1 + Int(tag.size)
    elseif tag isa ExprArity
        cur = off + 1
        for _ in 1:Int(tag.arity)
            cur > length(buf) && break
            cur = _expr_end_offset(buf, cur)
        end
        return cur
    elseif tag isa ExprNewVar || tag isa ExprVarRef
        return off + 1
    end
    off + 1
end

function sink_apply!(s::PureSink, bindings::Dict, path::Vector{UInt8}, btm::PathMap{UnitVal})
    buf = s.expr.buf
    length(buf) < 2 || byte_item(buf[1]) isa ExprArity || return

    # Parse (pure <template> <var> <formula>) — 4 children
    args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), s.expr), args)
    length(args) < 4 && return

    # Extract sub-expression byte spans
    tpl_ee     = args[2]
    formula_ee = args[4]

    tpl_start     = Int(tpl_ee.offset) + 1
    formula_start = Int(formula_ee.offset) + 1
    tpl_buf     = tpl_ee.base.buf
    formula_buf = formula_ee.base.buf

    formula_start > length(formula_buf) && return

    # Evaluate formula — returns a complete MORK sub-expression (header included)
    result_mork = _pure_eval_formula(formula_buf, formula_start)
    result_mork === nothing && return

    # Substitute: walk template bytes, replace first VarRef/NewVar with result_mork
    tpl_end = _expr_end_offset(tpl_buf, tpl_start)
    out = _pure_substitute_first_var(tpl_buf, tpl_start, tpl_end - 1, result_mork)
    out === nothing && return

    old = get_val_at(btm, out)
    set_val_at!(btm, out, UNIT_VAL)
    old === nothing && (s.changed = true)
end

"""
    _pure_substitute_first_var(buf, from, to, replacement) → Vector{UInt8}

Walk the expression in buf[from:to], replacing the first VarRef or NewVar
with `replacement` bytes. Returns the resulting byte vector, or `nothing`
if no variable slot was found.
"""
function _pure_substitute_first_var(buf::Vector{UInt8}, from::Int, to::Int,
                                     replacement::Vector{UInt8}) :: Union{Vector{UInt8}, Nothing}
    out = UInt8[]
    found = Ref(false)
    _pure_copy_subst!(buf, from, to, replacement, out, found)
    found[] ? out : nothing
end

function _pure_copy_subst!(buf::Vector{UInt8}, from::Int, to::Int,
                            repl::Vector{UInt8}, out::Vector{UInt8}, found::Ref{Bool})
    from > to && return
    tag = byte_item(buf[from])
    if (tag isa ExprNewVar || tag isa ExprVarRef) && !found[]
        append!(out, repl)
        found[] = true
        return
    end
    if tag isa ExprSymbol
        n = Int(tag.size)
        append!(out, buf[from : from + n])
        return
    end
    if tag isa ExprArity
        push!(out, buf[from])
        cur = from + 1
        for _ in 1:Int(tag.arity)
            cur > to && break
            child_end = _expr_end_offset(buf, cur) - 1
            _pure_copy_subst!(buf, cur, child_end, repl, out, found)
            cur = child_end + 1
        end
        return
    end
    push!(out, buf[from])
end

sink_finalize!(s::PureSink, ::PathMap{UnitVal}) = (c = s.changed; s.changed = false; c)

# Float reduction sinks
struct FloatReductionSink{R} <: AbstractSink
    expr ::MORK.Expr
    op   ::Symbol   # :sum, :min, :max, :prod
end

FloatReductionSink(e::MORK.Expr, op::Symbol) = FloatReductionSink{op}(e, op)

function sink_apply!(s::FloatReductionSink, bindings, path, btm)
    # TODO: float extraction and reduction
end

sink_finalize!(::FloatReductionSink, ::PathMap{UnitVal}) = false

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

    # [4] pure → PureSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
       length(buf) >= 6 && buf[3:6] == Vector{UInt8}("pure")
        return PureSink(e)
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
export _pure_eval_formula, _expr_end_offset
export FloatReductionSink
export asink_new, asink_compat
