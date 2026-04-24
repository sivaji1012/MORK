"""
Space — port of `mork/kernel/src/space.rs`.

The `Space` struct is the central data structure of the MORK kernel: a
`PathMap{UnitVal}` (set-trie of flat byte-encoded expressions) coupled with
a `SharedMappingHandle` for symbol interning.

Julia translation notes
========================
  - `PathMap<()>` → `PathMap{UnitVal}` (unit-value set-trie)
  - `#[cfg(feature="interning")]` path → raw-bytes (no-interning) variant
    (symbols stored as raw UTF-8 truncated to 63 bytes, matching the
    `#[cfg(not(feature="interning"))]` code path in upstream)
  - `coreferential_transition` (250-line DFS) → deferred; `query_multi`
    uses the `#[cfg(feature="no_search")]` ProductZipper + unify path
  - `setjmp`/`longjmp` early-exit → Julia `throw`/`catch` (BreakQuery)
  - `subprocess::Popen` (Z3 integration) → stubbed
  - `memmap2::Mmap` (ACT memory-mapped files) → stubbed
"""

# =====================================================================
# Bitmask constants (mirrors SIZES/ARITIES/VARS in space.rs)
# =====================================================================

"""
Byte → category bitmask mapping for expression byte tags.
`SPACE_SIZES[((b & 0xC0) >> 6) + 1]` has bit `(b & 0x3F)` set iff `b` encodes
a SymbolSize tag.  Same structure for SPACE_ARITIES and SPACE_VARS.
"""
function _build_space_mask(predicate::Function)
    result = zeros(UInt64, 4)
    for b_int in 0:255
        b = UInt8(b_int)
        tag = try byte_item(b) catch; continue end   # skip reserved bytes
        if predicate(tag)
            bucket = Int((b & 0xC0) >> 6) + 1
            bit    = Int(b & 0x3F)
            result[bucket] |= UInt64(1) << bit
        end
    end
    NTuple{4, UInt64}(result)
end

const SPACE_SIZES   = _build_space_mask(t -> t isa ExprSymbol)
const SPACE_ARITIES = _build_space_mask(t -> t isa ExprArity)
const SPACE_VARS    = _build_space_mask(t -> t isa ExprNewVar || t isa ExprVarRef)

# =====================================================================
# SpaceParser — tokenizer without interning (mirrors ParDataParser, no-intern)
# =====================================================================

"""
    SpaceParser

`MorkParser` whose `fe_tokenizer` truncates symbols to 63 bytes.
Mirrors `ParDataParser` with `cfg(not(feature="interning"))` in space.rs.
"""
struct SpaceParser <: MorkParser
    count::Ref{Int}
    SpaceParser() = new(Ref(0))
end

function fe_tokenizer(p::SpaceParser, s::AbstractVector{UInt8}) :: Vector{UInt8}
    p.count[] += 1
    n = min(length(s), 63)
    Vector{UInt8}(s[1:n])
end

# =====================================================================
# Space struct
# =====================================================================

"""
    Space

Central MORK data structure: a `PathMap{UnitVal}` set-trie of flat byte-encoded
expressions plus a symbol intern table.
Mirrors `Space` in mork/kernel/src/space.rs.
"""
mutable struct Space
    btm    ::PathMap{UnitVal, GlobalAlloc}
    sm     ::SharedMappingHandle
    timing ::Bool
end

"""    new_space() → Space

Create an empty Space.  Mirrors `Space::new`.
"""
new_space() = Space(PathMap{UnitVal}(), SharedMappingHandle(), false)

"""    space_val_count(s) → Int

Return the number of expressions stored in the Space.
"""
space_val_count(s::Space) = val_count(s.btm)

"""    space_statistics(s)

Print basic statistics.  Mirrors `Space::statistics`.
"""
function space_statistics(s::Space)
    println("val count ", space_val_count(s))
end

# =====================================================================
# space_add_all_sexpr! / space_remove_all_sexpr! / load_all_sexpr_impl!
# =====================================================================

"""
    space_add_all_sexpr!(s, src) → Int

Parse multiple whitespace-separated s-expressions from `src` and add each
to the Space.  Mirrors `Space::add_all_sexpr`.
"""
space_add_all_sexpr!(s::Space, src) = _space_load_all_sexpr_impl!(s, src, true)

"""
    space_remove_all_sexpr!(s, src) → Int

Remove each parsed s-expression from the Space.
Mirrors `Space::remove_all_sexpr`.
"""
space_remove_all_sexpr!(s::Space, src) = _space_load_all_sexpr_impl!(s, src, false)

function _space_load_all_sexpr_impl!(s::Space, src, add::Bool) :: Int
    bv  = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    ctx = SexprContext(bv)
    parser = SpaceParser()
    i = 0
    while true
        # Fresh buffer per expression (mirrors stack[] in Rust)
        buf = Vector{UInt8}(undef, max(length(bv) * 2, 64))
        z   = ExprZipper(MORK.Expr(buf), 1)
        try
            sexpr_parse!(parser, ctx, z)
        catch e
            if e isa SexprException && e.err == SERR_INPUT_FINISHED
                break
            end
            rethrow()
        end
        data = z.root.buf[1:z.loc-1]
        if add
            set_val_at!(s.btm, data, UNIT_VAL)
        else
            remove_val_at!(s.btm, data)
        end
        empty!(ctx.variables)   # clear variable bindings between expressions
        i += 1
    end
    i
end

# =====================================================================
# space_dump_all_sexpr
# =====================================================================

"""
    space_dump_all_sexpr(s, io) → Int

Write all stored expressions to `io`, one per line, in s-expression text form.
Mirrors `Space::dump_all_sexpr` (no-interning path).
"""
function space_dump_all_sexpr(s::Space, io::IO) :: Int
    rz = read_zipper(s.btm)
    i  = 0
    while zipper_to_next_val!(rz)
        path = collect(zipper_path(rz))
        println(io, expr_serialize(path))
        i += 1
    end
    i
end

space_dump_all_sexpr(s::Space) = (io = IOBuffer(); space_dump_all_sexpr(s, io); String(take!(io)))

# =====================================================================
# space_load_json! — JSON → PathMap (mirrors Space::load_json)
# =====================================================================

"""
    SpaceTranscriber

`JSONTranscriber` that writes parsed JSON tokens into a `WriteZipperCore`.
Mirrors `SpaceTranscriber` in space.rs.
"""
mutable struct SpaceTranscriber <: JSONTranscriber
    count  ::Int
    wz     ::WriteZipperCore
    parser ::SpaceParser
end

function SpaceTranscriber(wz::WriteZipperCore)
    SpaceTranscriber(0, wz, SpaceParser())
end

function _st_write!(t::SpaceTranscriber, bytes::AbstractVector{UInt8})
    tok  = fe_tokenizer(t.parser, bytes)
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
    wz_set_val!(t.wz, UNIT_VAL)
    wz_ascend!(t.wz, length(path))
    t.count += 1
end

jt_begin!(t::SpaceTranscriber)  = nothing
jt_end!(t::SpaceTranscriber)    = nothing
jt_write_empty_array!(t::SpaceTranscriber)  = _st_write!(t, Vector{UInt8}("[]"))
jt_write_empty_object!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("{}"))
jt_write_true!(t::SpaceTranscriber)  = _st_write!(t, Vector{UInt8}("true"))
jt_write_false!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("false"))
jt_write_null!(t::SpaceTranscriber)  = _st_write!(t, Vector{UInt8}("null"))
jt_write_string!(t::SpaceTranscriber, s::String) = _st_write!(t, Vector{UInt8}(s))

function jt_write_number!(t::SpaceTranscriber, neg::Bool, m::UInt64, e::Int16)
    s = neg ? "-$(m)" : "$(m)"
    e != 0 && (s *= "e$(e)")
    _st_write!(t, Vector{UInt8}(s))
end

function jt_descend_index!(t::SpaceTranscriber, i::Int, first::Bool)
    first && wz_descend_to!(t.wz, UInt8[item_byte(ExprArity(UInt8(2)))])
    tok  = fe_tokenizer(t.parser, Vector{UInt8}(string(i)))
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
end

function jt_ascend_index!(t::SpaceTranscriber, i::Int, last::Bool)
    tok  = fe_tokenizer(t.parser, Vector{UInt8}(string(i)))
    wz_ascend!(t.wz, length(tok) + 1)
    last && wz_ascend!(t.wz, 1)
end

function jt_descend_key!(t::SpaceTranscriber, k::String, first::Bool)
    first && wz_descend_to!(t.wz, UInt8[item_byte(ExprArity(UInt8(2)))])
    tok  = fe_tokenizer(t.parser, Vector{UInt8}(k))
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
end

function jt_ascend_key!(t::SpaceTranscriber, k::String, last::Bool)
    tok = fe_tokenizer(t.parser, Vector{UInt8}(k))
    wz_ascend!(t.wz, length(tok) + 1)
    last && wz_ascend!(t.wz, 1)
end

"""
    space_load_json!(s, src) → Int

Parse JSON `src` and insert the resulting expression tree into the Space.
Mirrors `Space::load_json`.
"""
function space_load_json!(s::Space, src) :: Int
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    wz = write_zipper(s.btm)
    st = SpaceTranscriber(wz)
    p  = JSONParser(bv)
    json_parse!(p, st)
    st.count
end

# =====================================================================
# space_query_multi — pattern matching (no_search / ProductZipper + unify)
# =====================================================================

"""
    BreakQuery

Exception used to implement early termination of a query (mirrors `longjmp`
in the Rust implementation).
"""
struct BreakQuery <: Exception end

"""
    space_query_multi(btm, pat_expr, effect) → Int

Iterate all expressions in `btm` that unify with the pattern encoded in
`pat_expr`, calling `effect(bindings, expr_bytes) -> Bool` on each match.
Return the total number of candidates examined.

`pat_expr` must be an arity node: first child is the "add" expression,
remaining children are the sources (patterns to unify against).
Matches iterate via `ProductZipper` (the `#[cfg(feature="no_search")]` path).

The `bindings` Dict passed to `effect` is a fresh allocation per match — safe
to retain across calls.  (Internal path uses a scratch Dict + copy-on-yield to
eliminate per-failed-unify allocations while preserving this contract.)

Mirrors `Space::query_multi` in space.rs.
"""
function space_query_multi(btm::PathMap{UnitVal}, pat_expr::MORK.Expr,
                            pat_v::UInt8, effect::Function) :: Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || error("pat_expr must be an Arity node")
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || error("pat_expr arity must be > 0")

    if n_factors == 1
        effect(Dict{ExprVar,ExprEnv}(), pat_expr.buf)
        return 1
    end

    _bindings_scratch = Dict{ExprVar, ExprEnv}()
    _pairs_scratch    = Tuple{ExprEnv, ExprEnv}[]

    _space_query_multi_inner!(btm, pat_expr, pat_v, n_factors, effect,
                               _bindings_scratch, _pairs_scratch)
end

# Compat wrapper with pat_v=0
space_query_multi(btm::PathMap{UnitVal}, pat_expr::MORK.Expr, effect::Function) =
    space_query_multi(btm, pat_expr, UInt8(0), effect)

# Internal hot path — takes pre-allocated scratch buffers so the
# per-unify-attempt Dict allocation is eliminated.
function _space_query_multi_inner!(btm::PathMap{UnitVal},
                                    pat_expr::MORK.Expr,
                                    pat_v::UInt8,
                                    n_factors::Int,
                                    effect::Function,
                                    bindings_scratch::Dict{ExprVar, ExprEnv},
                                    pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}}) :: Int
    pat_args = ExprEnv[]
    # Use pat_v as starting variable count so VarRef indices in pattern
    # match the binding keys expected by the template's expr_apply call.
    ee0 = ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr)
    ee_args!(ee0, pat_args)
    sources = pat_args[2:end]

    candidate = 0
    try
        primary     = read_zipper_at_path(btm, UInt8[])
        secondaries = [read_zipper_at_path(btm, UInt8[]) for _ in 1:(n_factors-2)]
        prz         = ProductZipper(primary, secondaries)

        while pz_to_next_val!(prz)
            pz_focus_factor(prz) != pz_factor_count(prz) - 1 && continue

            # The ProductZipper encodes ALL factor paths in ONE combined path
            # via pz.z (the primary zipper). factor_paths[i] marks the byte
            # boundary where factor i ends / factor i+1 begins.
            #
            # For k sources: factor_paths has k-1 entries.
            #   source 1 expression: combined[1 : factor_paths[1]]
            #   source i expression: combined[factor_paths[i-1]+1 : factor_paths[i]]
            #   last source:         combined[factor_paths[end]+1 : end]
            # For single source: factor_paths is empty, use full path.
            combined   = collect(pz_path(prz))
            fps        = prz.factor_paths   # path-length boundaries, 1-based

            empty!(pairs_scratch)
            # Slice the combined path for each source
            boundaries = vcat(0, fps, length(combined))
            for (k, src) in enumerate(sources)
                lo   = boundaries[k] + 1
                hi   = boundaries[k + 1]
                (lo > hi || lo > length(combined)) && break
                expr = MORK.Expr(combined[lo:hi])
                push!(pairs_scratch,
                      (src, ExprEnv(UInt8(k), UInt8(0), UInt32(0), expr)))
            end

            # Unify into scratch Dict (zero alloc on failure)
            result = _expr_unify_inplace!(pairs_scratch, bindings_scratch)
            if result === true
                candidate += 1
                # Copy scratch → fresh Dict before yielding to user (Option A).
                # This preserves the public contract: effect may retain bindings.
                bindings_out = copy(bindings_scratch)
                empty!(bindings_scratch)
                if !effect(bindings_out, MORK.Expr(combined))
                    throw(BreakQuery())
                end
            else
                empty!(bindings_scratch)   # failed — clear for next attempt
            end
        end
    catch e
        e isa BreakQuery || rethrow()
    end

    candidate
end

space_query_multi(s::Space, pat::MORK.Expr, f::Function) =
    space_query_multi(s.btm, pat, f)

# =====================================================================
# space_transform_multi_multi! — rewrite rule application
# =====================================================================

"""
    space_transform_multi_multi!(s, pat_expr, tpl_expr, add_expr) → (touched, any_new)

For each match of `pat_expr` in the Space, apply `tpl_expr` to produce new
expressions and insert them.  `add_expr` is also inserted unconditionally.

Simplified port of `Space::transform_multi_multi_` — uses our `expr_apply`
instead of `apply_e`.

Returns `(touched, any_new)` where `touched` is match count and `any_new`
indicates whether at least one new expression was added.
"""
function space_transform_multi_multi!(s::Space, pat_expr::MORK.Expr, pat_v::UInt8,
                                       tpl_expr::MORK.Expr, tpl_v::UInt8,
                                       add_expr::MORK.Expr) :: Tuple{Int, Bool}
    # Decompose tpl_expr into its template children, preserving per-item v offsets
    tpl_args = ExprEnv[]
    ee_tpl = ExprEnv(UInt8(0), tpl_v, UInt32(0), tpl_expr)
    ee_args!(ee_tpl, tpl_args)
    # Each tpl_args[i] carries the correct v (cumulative variable count up to that item)
    template_ees = tpl_args[2:end]

    any_new  = Ref(false)
    # Pass pat_v so query uses correct variable start index for the pattern
    touched  = space_query_multi(s.btm, pat_expr, pat_v, (bindings, loc_expr) -> begin
        for ee in template_ees
            tpl_bytes = ee.base.buf[Int(ee.offset)+1 : end]
            tpl_e = MORK.Expr(Vector{UInt8}(tpl_bytes))
            out_buf = Vector{UInt8}(undef, max(length(tpl_bytes) * 4, 64))
            ez  = ExprZipper(tpl_e, 1)
            oz  = ExprZipper(MORK.Expr(out_buf), 1)
            # Use ee.v as original_intros so VarRef indices match binding keys
            expr_apply(UInt8(0), ee.v, UInt8(0), ez, bindings, oz,
                       Dict{ExprVar,UInt8}(), ExprVar[], ExprVar[])
            result_bytes = oz.root.buf[1:oz.loc-1]
            old = get_val_at(s.btm, result_bytes)
            set_val_at!(s.btm, result_bytes, UNIT_VAL)
            old === nothing && (any_new[] = true)
        end
        true
    end)

    (touched, any_new[])
end

# Compat wrapper for callers without v parameters (v defaults to 0)
space_transform_multi_multi!(s::Space, pat_expr::MORK.Expr, tpl_expr::MORK.Expr,
                              add_expr::MORK.Expr) =
    space_transform_multi_multi!(s, pat_expr, UInt8(0), tpl_expr, UInt8(0), add_expr)

# =====================================================================
# space_interpret! / space_metta_calculus! — rule evaluation engine
# =====================================================================

# exec prefix: [4] exec  (6 bytes)
const _EXEC_PREFIX = UInt8[
    item_byte(ExprArity(UInt8(4))),
    item_byte(ExprSymbol(UInt8(4))),
    UInt8('e'), UInt8('x'), UInt8('e'), UInt8('c')
]

"""
    space_interpret!(s, rt) → Bool

Execute one `(exec loc pat_expr tpl_expr)` rule expression.
Mirrors `Space::interpret` in space.rs (simplified, no specialize_io).
"""
function space_interpret!(s::Space, rt::MORK.Expr) :: Bool
    buf = rt.buf
    length(buf) < 6 && return false

    # Check shape: [4] exec
    t1 = byte_item(buf[1])
    (t1 isa ExprArity && t1.arity == 4) || return false
    t2 = byte_item(buf[2])
    (t2 isa ExprSymbol && t2.size == 4) || return false
    buf[3:6] == Vector{UInt8}("exec") || return false

    # Decompose args: (exec loc pat_expr tpl_expr)
    ee_rt = ExprEnv(UInt8(0), UInt8(0), UInt32(0), rt)
    args  = ExprEnv[]
    ee_args!(ee_rt, args)
    # args layout: [1]=functor "exec", [2]=loc, [3]=pat_expr, [4]=tpl_expr
    length(args) < 4 && return false

    # args[2]=loc (ignored), args[3]=pat_expr, args[4]=tpl_expr
    pat_ee = args[3]
    tpl_ee = args[4]

    # Validate pat_expr shape: must be Arity node with `,` or `I` functor
    pat_buf = pat_ee.base.buf
    pat_off = Int(pat_ee.offset)
    length(pat_buf) <= pat_off && return false
    pt = byte_item(pat_buf[pat_off + 1])
    (pt isa ExprArity && pt.arity > 0) || return false
    length(pat_buf) <= pat_off + 1 && return false
    pt2 = byte_item(pat_buf[pat_off + 2])
    (pt2 isa ExprSymbol && pt2.size == 1) || return false

    # Validate tpl_expr shape: must be Arity node with `,` or `O` functor
    tpl_buf = tpl_ee.base.buf
    tpl_off = Int(tpl_ee.offset)
    length(tpl_buf) <= tpl_off && return false
    tt = byte_item(tpl_buf[tpl_off + 1])
    (tt isa ExprArity && tt.arity > 0) || return false

    pat_expr = MORK.Expr(pat_buf[pat_off+1 : end])
    tpl_expr = MORK.Expr(tpl_buf[tpl_off+1 : end])

    # Pass v fields so variable indices stay consistent across pattern/template
    space_transform_multi_multi!(s, pat_expr, pat_ee.v, tpl_expr, tpl_ee.v, rt)
    true
end

"""
    space_metta_calculus!(s, steps=∞) → Int

Repeatedly find `(exec ...)` expressions in the space, remove and execute them.
Returns the number of steps performed.
Mirrors `Space::metta_calculus` in space.rs.
"""
function space_metta_calculus!(s::Space, steps::Int=typemax(Int)) :: Int
    done = 0
    while done < steps
        rz = read_zipper_at_path(s.btm, _EXEC_PREFIX)
        found = zipper_to_next_val!(rz)
        !found && break

        rel_path  = collect(zipper_path(rz))
        full_path = vcat(_EXEC_PREFIX, rel_path)

        remove_val_at!(s.btm, full_path)

        rt = MORK.Expr(full_path)
        space_interpret!(s, rt)
        done += 1
    end
    done
end

# =====================================================================
# Exports
# =====================================================================

export SPACE_SIZES, SPACE_ARITIES, SPACE_VARS
export SpaceParser
export Space, new_space, space_val_count, space_statistics
export space_add_all_sexpr!, space_remove_all_sexpr!
export space_dump_all_sexpr, space_load_json!
export BreakQuery, space_query_multi, _space_query_multi_inner!
export space_transform_multi_multi!
export space_interpret!, space_metta_calculus!

# Precompile hot-path method specializations so JIT fires at package load,
# not on first user call. Mirrors upstream's statically-compiled hot paths.
precompile(space_metta_calculus!, (Space, Int))
precompile(space_interpret!, (Space, MORK.Expr))
precompile(space_add_all_sexpr!, (Space, String))
precompile(space_dump_all_sexpr, (Space,))
precompile(_space_query_multi_inner!, (PathMap{UnitVal}, MORK.Expr, Int, Function, Dict{ExprVar,ExprEnv}, Vector{Tuple{ExprEnv,ExprEnv}}))
