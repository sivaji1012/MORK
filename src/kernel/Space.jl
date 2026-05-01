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
    mmaps  ::Dict{String, ArenaCompactTree}   # ACT file cache (mirrors mmaps in Space)
end

"""    new_space() → Space

Create an empty Space.  Mirrors `Space::new`.
"""
new_space() = Space(PathMap{UnitVal}(), SharedMappingHandle(), false, Dict{String,ArenaCompactTree}())

# Prevent Julia's default struct show from dumping raw PathMap bytes to stdout.
# Upstream equivalent: Space::statistics() prints "val count N".
Base.show(io::IO, s::Space) =
    print(io, "Space($(space_val_count(s)) atoms)")

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

# =====================================================================
# space_query_multi_i — I-pattern query using ASource dispatch
# Mirrors Space::query_multi_i (no_source=false path) in space.rs.
#
# For each argument of the I-pattern, calls asource_new() to dispatch:
#   CompatSource / BTMSource → plain read zipper (same as comma pattern)
#   CmpSource (== / !=)      → PrefixZipper<DependentZipper> via source_factor
#
# All factors are combined in a ProductZipperG, then iterated like
# query_multi_raw: focus must be on the last factor before yielding.
# origin_path (including any prefix from CmpSource) is used as the
# expression for unification, with factor_paths adjusted by prefix length.
# =====================================================================

function space_query_multi_i(btm::PathMap{UnitVal}, pat_expr::MORK.Expr,
                               pat_v::UInt8, effect::Function;
                               mmaps::Dict{String,ArenaCompactTree}=Dict{String,ArenaCompactTree}()) :: Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || return 0
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || return 0

    if n_factors == 1
        effect(Dict{ExprVar,ExprEnv}(), pat_expr.buf)
        return 1
    end

    pat_args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr), pat_args)
    sources = pat_args[2:end]   # ExprEnv for each sub-pattern

    # Build factors: one per sub-pattern via asource_new
    factors = Any[]
    for ee in sources
        span = expr_span(ee.base, Int(ee.offset) + 1)
        sub  = MORK.Expr(Vector{UInt8}(span))
        src  = asource_new(sub)
        # ACTSource uses mmaps cache; all others ignore it
        factor = src isa ACTSource ? source_factor(src, btm, mmaps) : source_factor(src, btm)
        push!(factors, factor)
    end

    # primary = factors[1], secondaries = factors[2:end]
    primary    = popfirst!(factors)
    prz        = ProductZipperG(primary, factors)
    prefix_len = pzg_root_prefix_len(prz)

    candidate        = 0
    bindings_scratch = Dict{ExprVar, ExprEnv}()
    pairs_scratch    = Tuple{ExprEnv, ExprEnv}[]

    while pzg_to_next_val!(prz)
        # Only yield when focus is on the last factor (mirrors query_multi_raw)
        pzg_focus_factor(prz) != pzg_factor_count(prz) - 1 && continue

        # Build expression from origin_path (includes prefix for CmpSource)
        combined = collect(pzg_origin_path(prz))

        # factor_paths are into path(); offset by prefix_len for origin_path
        fps        = pzg_factor_paths(prz)
        boundaries = vcat(0, [fp + prefix_len for fp in fps], length(combined))

        empty!(pairs_scratch)
        all_sliced = true
        for (k, src) in enumerate(sources)
            lo = boundaries[k] + 1
            hi = boundaries[k + 1]
            if lo > hi || lo > length(combined)
                all_sliced = false; break
            end
            expr = MORK.Expr(combined[lo:hi])
            push!(pairs_scratch, (src, ExprEnv(UInt8(k), UInt8(0), UInt32(0), expr)))
        end
        all_sliced || continue
        length(pairs_scratch) < length(sources) && continue

        # Guard: skip incomplete-secondary yields (DependentZipper primary at leaf
        # before secondary fully traversed). Mirrors upstream which reads past end
        # of incomplete paths — we need explicit bounds safety in Julia.
        pzg_child_count(prz) != 0 && (empty!(bindings_scratch); continue)

        result = try
            _expr_unify_inplace!(pairs_scratch, bindings_scratch)
        catch
            nothing  # malformed/incomplete expression bytes — skip
        end
        if result === true
            candidate += 1
            bindings_out = copy(bindings_scratch)
            empty!(bindings_scratch)
            if !effect(bindings_out, combined)
                break
            end
        else
            empty!(bindings_scratch)
        end
    end

    candidate
end

space_query_multi_i(btm::PathMap{UnitVal}, pat_expr::MORK.Expr, effect::Function) =
    space_query_multi_i(btm, pat_expr, UInt8(0), effect)

# Internal hot path — takes pre-allocated scratch buffers so the
# per-unify-attempt Dict allocation is eliminated.
function _space_query_multi_inner!(btm::PathMap{UnitVal},
                                    pat_expr::MORK.Expr,
                                    pat_v::UInt8,
                                    n_factors::Int,
                                    effect::Function,
                                    bindings_scratch::Dict{ExprVar, ExprEnv},
                                    pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}}) :: Int
    # Rule of 64: warn if pattern exceeds practical source limit.
    # ProductZipper with N>2 factors iterates N^M paths (M=trie depth) and
    # becomes intractable beyond 2 secondary factors in practice.
    n_factors > 4 && @warn "query_multi: $(n_factors) sources (>4) may be slow — Rule of 64 boundary"

    pat_args = ExprEnv[]
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

            # Skip spurious enrollment-only yields (secondary path is empty)
            if length(pairs_scratch) < length(sources)
                empty!(bindings_scratch)
                continue
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
# coreferential_transition — DFS query (the no_search=false path)
# =====================================================================
#
# Mirrors `coreferential_transition` in space.rs (lines 92–212).
#
# This is the alternative to ProductZipper for multi-source queries.
# Instead of generating the full Cartesian product then filtering via
# unify, this DFS tracks variable bindings DURING trie traversal:
#
#   ProductZipper (current):  O(K^N) candidates → filter → O(M) matches
#   Coreferential DFS:        O(M × depth) — explores only consistent paths
#
# When the same variable appears in multiple sources, the DFS records
# the trie path length at first binding (references[i]) and on VarRef
# descends directly to that sub-path — skipping all inconsistent branches.
#
# Algorithm (mirrors Rust recursive DFS):
#   stack  — remaining ExprEnv items to match (popped LIFO)
#   references — path-length offsets for De Bruijn NewVar bindings
#   When stack is empty, f(loc) is called (a match has been found).

"""
    _coreferential_transition!(loc, stack, references, f)

Recursive DFS that explores the trie `loc` matching `stack` of ExprEnvs.
Calls `f(loc)` for each complete match (empty stack).
Mirrors `coreferential_transition` in space.rs.
"""
function _coreferential_transition!(loc::ReadZipperCore,
                                     stack::Vector{ExprEnv},
                                     references::Vector{Int},
                                     f::Function)
    if isempty(stack)
        f(loc)
        return
    end

    e = pop!(stack)
    e_byte = e.base.buf[Int(e.offset) + 1]

    tag = byte_item(e_byte)

    if tag isa ExprNewVar
        # NewVar: first occurrence records current path length
        if e.n == 0
            push!(references, length(zipper_path(loc)))
        end

        # Recurse over all variable-tagged child bytes
        m_vars = Base.and(zipper_child_mask(loc), SPACE_VARS)
        for b in m_vars
            zipper_descend_to_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            zipper_ascend_byte!(loc)
        end

        # Recurse over all SymbolSize children (each is a k-path)
        m_sizes = Base.and(zipper_child_mask(loc), SPACE_SIZES)
        for b in m_sizes
            tag_s = byte_item(b)
            tag_s isa ExprSymbol || continue
            size  = Int(tag_s.size)
            zipper_descend_to_byte!(loc, b)
            if zipper_descend_first_k_path!(loc, size)
                while true
                    _coreferential_transition!(loc, stack, references, f)
                    zipper_to_next_k_path!(loc, size) || break
                end
            end
            zipper_ascend_byte!(loc)
        end

        # Recurse over all Arity children — push N fresh NewVar frames
        m_arities = Base.and(zipper_child_mask(loc), SPACE_ARITIES)
        static_nv = item_byte(ExprNewVar())
        for b in m_arities
            tag_a = byte_item(b)
            tag_a isa ExprArity || continue
            arity = Int(tag_a.arity)
            zipper_descend_to_byte!(loc, b)
            ol = length(stack)
            nv_expr = MORK.Expr([static_nv])
            for _ in 1:arity
                push!(stack, ExprEnv(UInt8(255), UInt8(0), UInt32(0), nv_expr))
            end
            _coreferential_transition!(loc, stack, references, f)
            resize!(stack, ol)
            zipper_ascend_byte!(loc)
        end

        e.n == 0 && pop!(references)

    elseif tag isa ExprVarRef
        i = Int(tag.idx)   # De Bruijn index

        new_ee = if e.n == 0 && i < length(references)
            # Resolve: push ExprEnv pointing into current path at recorded offset
            ref_off = references[i + 1]   # 1-based Julia indexing
            path    = zipper_path(loc)
            resolved_buf = Vector{UInt8}(path[ref_off + 1 : end])
            ExprEnv(UInt8(254), UInt8(0), UInt32(0), MORK.Expr(resolved_buf))
        else
            # Out-of-scope VarRef → treat as fresh NewVar (any match)
            static_nv = item_byte(ExprNewVar())
            ExprEnv(UInt8(255), UInt8(0), UInt32(0), MORK.Expr([static_nv]))
        end

        push!(stack, new_ee)

        # Recurse over variable children
        m_vars = Base.and(zipper_child_mask(loc), SPACE_VARS)
        for b in m_vars
            zipper_descend_to_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            zipper_ascend_byte!(loc)
        end

        _coreferential_transition!(loc, stack, references, f)
        pop!(stack)

    elseif tag isa ExprSymbol
        size = Int(tag.size)
        # Recurse over variable children first (they can match anything)
        m_vars = Base.and(zipper_child_mask(loc), SPACE_VARS)
        for b in m_vars
            zipper_descend_to_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            zipper_ascend_byte!(loc)
        end
        # Then try exact symbol descent
        if zipper_descend_to_existing_byte!(loc, e_byte)
            sym_bytes = e.base.buf[Int(e.offset) + 2 : Int(e.offset) + 1 + size]
            if zipper_descend_to_check!(loc, sym_bytes)
                _coreferential_transition!(loc, stack, references, f)
            end
            zipper_ascend!(loc, size + 1)
        end

    elseif tag isa ExprArity
        arity = Int(tag.arity)
        # Recurse over variable children first
        m_vars = Base.and(zipper_child_mask(loc), SPACE_VARS)
        for b in m_vars
            zipper_descend_to_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            zipper_ascend_byte!(loc)
        end
        # Then try exact arity descent
        if zipper_descend_to_existing_byte!(loc, e_byte)
            ol = length(stack)
            ee_args!(e, stack)
            # Reverse the args (Rust reverses before push)
            reverse!(view(stack, ol+1:length(stack)))
            _coreferential_transition!(loc, stack, references, f)
            resize!(stack, ol)
            zipper_ascend_byte!(loc)
        end
    end

    push!(stack, e)
end

"""
    space_query_coref(btm, pat_expr, effect) → Int

DFS coreferential query — the `no_search=false` path from space.rs.
More efficient than ProductZipper for patterns with shared variables:
explores only trie branches consistent with variable bindings.

Calls `effect(loc)` for each match, where `loc` is the ReadZipper
positioned at the end of the matched expression.

Mirrors `query_multi_raw` DFS path (space.rs:1207–1270).
"""
function space_query_coref(btm::PathMap{UnitVal},
                            pat_expr::MORK.Expr,
                            pat_v::UInt8,
                            effect::Function) :: Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || return 0
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || return 0

    if n_factors == 1
        effect(nothing)
        return 1
    end

    pat_args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr), pat_args)
    # sources reversed — DFS pops LIFO, so last source should be on top
    sources   = reverse(pat_args[2:end])
    stack     = Vector{ExprEnv}(sources)
    references = Int[]
    count      = Ref(0)

    loc = read_zipper(btm)
    _coreferential_transition!(loc, stack, references, function(z)
        count[] += 1
        effect(z)
    end)

    count[]
end

space_query_coref(btm::PathMap{UnitVal}, pat::MORK.Expr, f::Function) =
    space_query_coref(btm, pat, UInt8(0), f)

space_query_coref(s::Space, pat::MORK.Expr, f::Function) =
    space_query_coref(s.btm, pat, UInt8(0), f)

# Space-level overloads that pass mmaps for ACT file caching
space_query_multi_i(s::Space, pat::MORK.Expr, f::Function) =
    space_query_multi_i(s.btm, pat, UInt8(0), f; mmaps=s.mmaps)
space_query_multi_i(s::Space, pat::MORK.Expr, pat_v::UInt8, f::Function) =
    space_query_multi_i(s.btm, pat, pat_v, f; mmaps=s.mmaps)

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
# Returns true if the O-template raw bytes indicate an accumulating sink.
# Accumulating sinks must be created ONCE before the query and finalized ONCE after.
# Recognized: count, fsum, fmin, fmax, fprod
function _is_accumulating_sink(raw_bytes::Vector{UInt8}) :: Bool
    length(raw_bytes) < 4 && return false
    t1 = byte_item(raw_bytes[1])
    t1 isa ExprArity || return false
    t2 = byte_item(raw_bytes[2])
    t2 isa ExprSymbol || return false
    sz = Int(t2.size)
    3 + sz > length(raw_bytes) && return false
    name = String(raw_bytes[3 : 3+sz-1])
    name in ("count", "fsum", "fmin", "fmax", "fprod") && return true
    false
end

# Mirrors transform_multi_multi_io(pat_expr, tpl_expr, add, no_source, no_sink)
# no_source=true  → pattern is `,`  (query the trie — compat path)
# no_source=false → pattern is `I`  (external ACT/Z3 source via query_multi_i;
#                                    not ported — requires mmaps/z3s infrastructure.
#                                    Falls back to trie query for now.)
# no_sink=true    → template is `,` (direct set_val_at!)
# no_sink=false   → template is `O` (dispatch through sink machinery)
function space_transform_multi_multi!(s::Space, pat_expr::MORK.Expr, pat_v::UInt8,
                                       tpl_expr::MORK.Expr, tpl_v::UInt8,
                                       add_expr::MORK.Expr;
                                       no_source::Bool=true,
                                       no_sink::Bool=true) :: Tuple{Int, Bool}
    tpl_args = ExprEnv[]
    ee_tpl = ExprEnv(UInt8(0), tpl_v, UInt32(0), tpl_expr)
    ee_args!(ee_tpl, tpl_args)
    template_ees = tpl_args[2:end]

    any_new  = Ref(false)

    # Pre-create persistent (accumulating) sinks for O-templates.
    # CountSink accumulates sources across all matches before finalizing once.
    # Other sinks are created fresh per match (persistent_sinks[k] = nothing).
    persistent_sinks = if no_sink
        nothing
    else
        map(template_ees) do ee
            tpl_span = expr_span(ee.base, Int(ee.offset) + 1)
            raw_bytes = Vector{UInt8}(tpl_span)
            _is_accumulating_sink(raw_bytes) ? asink_new(MORK.Expr(raw_bytes)) : nothing
        end
    end

    # Build read_btm: s.btm + exec atom re-inserted.
    # Mirrors upstream space.rs: `let mut read_copy = self.btm.clone(); read_copy.insert(add.span(), ())`.
    # In Rust, PathMap::clone() is O(1) — Arc refcount bump with COW on first write.
    # Replaced deepcopy (O(n)) with pjoin against a single-entry map: shares all trie
    # nodes structurally via TrieNodeODRc refcounts; only the spine to add_expr is new.
    _exec_singleton = PathMap{UnitVal}()
    set_val_at!(_exec_singleton, add_expr.buf, UNIT_VAL)
    read_btm = pjoin(s.btm, _exec_singleton).value  # unwrap AlgResElement

    # Pre-allocate per-template scratch buffers outside the match closure.
    # Mirrors upstream space.rs: ass/astack/buffer pre-allocated before query_multi,
    # cleared between iterations with ass.clear() / astack.clear() / buffer.clear().
    # Saves 5+ heap allocs per (match × template): template copy, output buf, result
    # slice, rename dict, free/new var vecs.
    n_tpl     = length(template_ees)
    tpl_exprs = Vector{MORK.Expr}(undef, n_tpl)    # template Expr per ee
    out_bufs  = Vector{Vector{UInt8}}(undef, n_tpl) # reusable output buffers
    tpl_ezs   = Vector{ExprZipper}(undef, n_tpl)    # read zippers (reset loc=1 each call)
    tpl_ozs   = Vector{ExprZipper}(undef, n_tpl)    # write zippers (reset loc=1 each call)
    tpl_rdicts = [Dict{ExprVar,UInt8}() for _ in 1:n_tpl]  # rename maps (empty! each call)
    tpl_fvecs  = [ExprVar[] for _ in 1:n_tpl]              # free_vars  (empty! each call)
    tpl_nvecs  = [ExprVar[] for _ in 1:n_tpl]              # new_vars   (empty! each call)
    for (k, ee) in enumerate(template_ees)
        tpl_span     = expr_span(ee.base, Int(ee.offset) + 1)
        tpl_exprs[k] = MORK.Expr(Vector{UInt8}(tpl_span))
        out_bufs[k]  = Vector{UInt8}(undef, max(length(tpl_span) * 4, 64))
        tpl_ezs[k]   = ExprZipper(tpl_exprs[k], 1)
        tpl_ozs[k]   = ExprZipper(MORK.Expr(out_bufs[k]), 1)
    end

    # space_query_multi_i uses s.mmaps for ACT file caching (I-pattern)
    query_fn = no_source ? space_query_multi :
                           (btm, pat, v, f) -> space_query_multi_i(btm, pat, v, f; mmaps=s.mmaps)
    touched  = query_fn(read_btm, pat_expr, pat_v, (bindings, loc_expr) -> begin
        if no_sink
            # `,` template functor — apply each template and insert result directly
            for (k, ee) in enumerate(template_ees)
                ez = tpl_ezs[k]; ez.loc = 1          # reset read position
                oz = tpl_ozs[k]; oz.loc = 1          # reset write position (≡ buffer.clear())
                empty!(tpl_rdicts[k]); empty!(tpl_fvecs[k]); empty!(tpl_nvecs[k])
                expr_apply(UInt8(0), ee.v, UInt8(0), ez, bindings, oz,
                           tpl_rdicts[k], tpl_fvecs[k], tpl_nvecs[k])
                result_view = @view out_bufs[k][1:oz.loc-1]   # zero-copy view (no slice alloc)
                old = get_val_at(s.btm, result_view)
                set_val_at!(s.btm, result_view, UNIT_VAL)
                old === nothing && (any_new[] = true)
            end
        else
            # `O` template functor — apply each template then dispatch to sink.
            # Accumulating sinks (CountSink) use persistent_sinks created before query.
            ps = persistent_sinks::Vector
            for (k, ee) in enumerate(template_ees)
                ez = tpl_ezs[k]; ez.loc = 1
                oz = tpl_ozs[k]; oz.loc = 1
                empty!(tpl_rdicts[k]); empty!(tpl_fvecs[k]); empty!(tpl_nvecs[k])
                expr_apply(UInt8(0), ee.v, UInt8(0), ez, bindings, oz,
                           tpl_rdicts[k], tpl_fvecs[k], tpl_nvecs[k])
                result_expr = MORK.Expr(out_bufs[k][1:oz.loc-1]) # copy needed: sink stores ref
                if ps[k] !== nothing
                    # Accumulating sink: apply but don't finalize yet
                    sink_apply!(ps[k], bindings, result_expr.buf, s.btm)
                else
                    # Immediate sink: create fresh, apply, finalize
                    sink = asink_new(result_expr)
                    sink_apply!(sink, bindings, result_expr.buf, s.btm)
                    changed = sink_finalize!(sink, s.btm)
                    changed && (any_new[] = true)
                end
            end
        end
        true
    end)

    # Finalize accumulating sinks (CountSink etc.) once after all matches
    if !no_sink && persistent_sinks !== nothing
        for sink in persistent_sinks::Vector
            sink === nothing && continue
            changed = sink_finalize!(sink, s.btm)
            changed && (any_new[] = true)
        end
    end

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

    # Read functor byte: pat[offset+3] is the single-char functor (`,` or `I`)
    # tpl[offset+3] is the single-char functor (`,` or `O`)
    # Mirrors upstream: match (*pat_expr.ptr.add(2), *tpl_expr.ptr.add(2))
    pat_functor = pat_buf[pat_off + 3]
    tpl_functor = tpl_buf[tpl_off + 3]

    no_source = (pat_functor == UInt8(','))
    no_sink   = (tpl_functor == UInt8(','))

    if !no_source && pat_functor != UInt8('I')
        return false  # invalid pattern functor
    end
    if !no_sink && tpl_functor != UInt8('O')
        return false  # invalid template functor
    end

    space_transform_multi_multi!(s, pat_expr, pat_ee.v, tpl_expr, tpl_ee.v, rt;
                                  no_source=no_source, no_sink=no_sink)
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
# prefix_subsumption — group prefixes by longest shared prefix
# Mirrors Space::prefix_subsumption in space.rs (line 1278)
# =====================================================================

function space_prefix_subsumption(prefixes::Vector{Vector{UInt8}}) :: Vector{Int}
    n   = length(prefixes)
    out = Vector{Int}(undef, n)
    for i in 1:n
        cur      = prefixes[i]
        best_idx = i
        best_len = length(cur)
        for j in 1:n
            cand = prefixes[j]
            # cand is a prefix of cur iff cand == cur[1:length(cand)]
            cl = length(cand)
            if cl <= length(cur) && cur[1:cl] == cand
                if cl < best_len || (cl == best_len && j < best_idx)
                    best_idx = j
                    best_len = cl
                end
            end
        end
        out[i] = best_idx
    end
    out
end

# =====================================================================
# space_token_bfs — BFS from token prefix, return unifiable matches
# Mirrors Space::token_bfs in space.rs (line 1750)
# =====================================================================

function space_token_bfs(s::Space, token::Vector{UInt8}, pattern::MORK.Expr) :: Vector{Tuple{Vector{UInt8}, MORK.Expr}}
    rz  = read_zipper_at_path(s.btm, token)
    zipper_descend_until!(rz)
    res = Tuple{Vector{UInt8}, MORK.Expr}[]
    cm  = zipper_child_mask(rz)
    for b in cm
        zipper_descend_to_byte!(rz, b)
        # Get representative expression for this byte position:
        # - If already at a value (single-byte key is a leaf value), use current position.
        # - Otherwise advance rzc to the first value in the subtrie via to_next_val!.
        # NOTE: iter_token_for_path starts AFTER the current key, so zipper_to_next_val!
        # on a value position would skip it and return the wrong expression.
        origin = if zipper_is_val(rz)
            copy(rz.prefix_buf)
        else
            rzc = deepcopy(rz)
            zipper_to_next_val!(rzc) || (zipper_ascend_byte!(rz); continue)
            copy(rzc.prefix_buf)
        end
        e = MORK.Expr(origin)
        # expr_unifiable: attempt unification, return true if succeeds
        pairs = Tuple{ExprEnv,ExprEnv}[
            (ExprEnv(UInt8(0), UInt8(0), UInt32(0), e),
             ExprEnv(UInt8(1), UInt8(0), UInt32(0), pattern))
        ]
        scratch = Dict{ExprVar,ExprEnv}()
        if _expr_unify_inplace!(pairs, scratch) === true
            push!(res, (copy(rz.prefix_buf[1:rz.origin_path_len + length(zipper_path(rz))]), e))
        end
        zipper_ascend_byte!(rz)
    end
    res
end

# =====================================================================
# space_load_csv! — load CSV rows as expressions via pattern/template
# Mirrors Space::load_csv in space.rs (line 509)
# =====================================================================

function space_load_csv!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr,
                          separator::UInt8=UInt8(',')) :: Int
    bytes = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    count = 0
    for (i, line) in enumerate(split(String(bytes), '\n'))
        isempty(line) && continue
        fields = split(line, Char(separator))
        # Build expr: (arity+1 row_index field1 field2 ...)
        # row_index = i-1 as decimal string symbol, matching Rust i.to_string()
        row_sym  = string(i - 1)
        parts    = vcat([row_sym], String.(fields))
        arity    = length(parts)
        buf      = UInt8[]
        push!(buf, item_byte(ExprArity(UInt8(arity))))
        for p in parts
            pb = Vector{UInt8}(p)
            push!(buf, item_byte(ExprSymbol(UInt8(length(pb)))))
            append!(buf, pb)
        end
        data_expr = MORK.Expr(buf)

        # Unify with pattern, apply template
        bindings = Dict{ExprVar,ExprEnv}()
        pairs    = Tuple{ExprEnv,ExprEnv}[
            (ExprEnv(UInt8(0), UInt8(0), UInt32(0), pattern),
             ExprEnv(UInt8(1), UInt8(0), UInt32(0), data_expr))
        ]
        _expr_unify_inplace!(pairs, bindings) === true || continue

        out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
        ez_tpl  = ExprZipper(template, 1)
        oz      = ExprZipper(MORK.Expr(out_buf), 1)
        expr_apply(UInt8(0), UInt8(0), UInt8(0), ez_tpl, bindings, oz,
                   Dict{ExprVar,UInt8}(), ExprVar[], ExprVar[])
        set_val_at!(s.btm, oz.root.buf[1:oz.loc-1], UNIT_VAL)
        count += 1
    end
    count
end

# =====================================================================
# space_add_sexpr! / space_remove_sexpr! — pattern+template variants
# Mirrors Space::add_sexpr / remove_sexpr / load_sexpr_impl in space.rs
# =====================================================================

function space_add_sexpr!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr) :: Int
    _space_load_sexpr_impl!(s, src, pattern, template, true)
end

function space_remove_sexpr!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr) :: Int
    _space_load_sexpr_impl!(s, src, pattern, template, false)
end

function _space_load_sexpr_impl!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr, add::Bool) :: Int
    bytes  = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    ctx    = SexprContext(bytes)
    parser = SpaceParser()
    count  = 0
    while true
        buf = Vector{UInt8}(undef, max(length(bytes) * 2, 64))
        z   = ExprZipper(MORK.Expr(buf), 1)
        try
            sexpr_parse!(parser, ctx, z)
        catch e
            e isa SexprException && e.err == SERR_INPUT_FINISHED && break
            rethrow()
        end
        data_expr = MORK.Expr(z.root.buf[1:z.loc-1])
        empty!(ctx.variables)

        # Unify data_expr with pattern, apply template
        bindings = Dict{ExprVar,ExprEnv}()
        pairs    = Tuple{ExprEnv,ExprEnv}[
            (ExprEnv(UInt8(0), UInt8(0), UInt32(0), pattern),
             ExprEnv(UInt8(1), UInt8(0), UInt32(0), data_expr))
        ]
        _expr_unify_inplace!(pairs, bindings) === true || continue

        out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
        ez_tpl  = ExprZipper(template, 1)
        oz      = ExprZipper(MORK.Expr(out_buf), 1)
        expr_apply(UInt8(0), UInt8(0), UInt8(0), ez_tpl, bindings, oz,
                   Dict{ExprVar,UInt8}(), ExprVar[], ExprVar[])
        result_bytes = oz.root.buf[1:oz.loc-1]
        if add; set_val_at!(s.btm, result_bytes, UNIT_VAL)
        else;    remove_val_at!(s.btm, result_bytes); end
        count += 1
    end
    count
end

# =====================================================================
# space_dump_sexpr — dump matching expressions via pattern/template
# Mirrors Space::dump_sexpr in space.rs
# =====================================================================

function space_dump_sexpr(s::Space, pattern::MORK.Expr, template::MORK.Expr, io::IO) :: Int
    # Wrap pattern in comma functor: (, pattern) so query_multi can process it
    pat_wrap_buf = vcat(
        item_byte(ExprArity(UInt8(2))),
        item_byte(ExprSymbol(UInt8(1))), UInt8(','),
        pattern.buf
    )
    pat_wrapped = MORK.Expr(pat_wrap_buf)

    count = Ref(0)
    space_query_multi(s.btm, pat_wrapped, UInt8(0), (bindings, _loc_buf) -> begin
        out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
        ez_tpl  = ExprZipper(template, 1)
        oz      = ExprZipper(MORK.Expr(out_buf), 1)
        expr_apply(UInt8(0), UInt8(0), UInt8(0), ez_tpl, bindings, oz,
                   Dict{ExprVar,UInt8}(), ExprVar[], ExprVar[])
        result_bytes = oz.root.buf[1:oz.loc-1]
        println(io, expr_serialize(result_bytes))
        count[] += 1
        true
    end)
    count[]
end

space_dump_sexpr(s::Space, pattern::MORK.Expr, template::MORK.Expr) =
    space_dump_sexpr(s, pattern, template, stdout)

# =====================================================================
# Persistence — backup/restore tree and paths
# Mirrors Space::backup_tree/restore_tree/backup_paths/restore_paths
# backup_symbols/restore_symbols are no-ops (no interning in this port)
# =====================================================================

function space_backup_tree(s::Space, path::AbstractString)
    open(path, "w") do io; serialize_paths(s.btm, io); end
end

function space_restore_tree!(s::Space, path::AbstractString)
    open(path, "r") do io; deserialize_paths(s.btm, io, UNIT_VAL); end
end

function space_backup_paths(s::Space, path::AbstractString)
    open(path, "w") do io; serialize_paths(s.btm, io); end
end

function space_restore_paths!(s::Space, path::AbstractString)
    open(path, "r") do io; deserialize_paths(s.btm, io, UNIT_VAL); end
end

space_backup_symbols(::Space, ::AbstractString)  = nothing  # no interning in this port
space_restore_symbols!(::Space, ::AbstractString) = nothing

# =====================================================================
# Exports
# =====================================================================

export SPACE_SIZES, SPACE_ARITIES, SPACE_VARS
export SpaceParser
export Space, new_space, space_val_count, space_statistics
export space_add_all_sexpr!, space_remove_all_sexpr!
export space_add_sexpr!, space_remove_sexpr!
export space_dump_all_sexpr, space_dump_sexpr, space_load_json!
export space_backup_tree, space_restore_tree!
export space_backup_paths, space_restore_paths!
# =====================================================================
# space_sexpr_to_expr — server-branch addition
# Mirrors sexpr_to_path / Space::sexpr_to_expr in space_temporary.rs
# =====================================================================

function space_sexpr_to_expr(s::Space, sexpr::AbstractString) :: MORK.Expr
    sexpr_to_expr(sexpr)
end

# =====================================================================
# space_metta_calculus_at! — server-branch addition
# Mirrors Space::metta_calculus(thread_id_sexpr_str, ...) in space_temporary.rs
# Runs metta_calculus consuming only (exec (<location> $priority) ...) atoms.
# =====================================================================

function space_metta_calculus_at!(s::Space, location_sexpr::AbstractString,
                                   max_steps::Int=typemax(Int)) :: Int
    # Build the exec prefix for this location: (exec (<location> $) $ $)
    # Mirrors metta_calculus_impl: prefix_e = format!("(exec ({} $) $ $)", thread_id)
    # CRITICAL: use only the CONSTANT prefix (bytes up to first NewVar) so the
    # read_zipper navigates to the right subtrie. Full buf includes variable bytes
    # (0xC0 NewVar) which don't exist in the stored paths.
    prefix_str = "(exec ($location_sexpr \$) \$ \$)"
    try
        prefix_expr  = sexpr_to_expr(prefix_str)
        prefix_bytes = _derive_prefix(prefix_expr)   # constant prefix only

        done = 0
        while done < max_steps
            rz    = read_zipper_at_path(s.btm, prefix_bytes)
            found = zipper_to_next_val!(rz)
            !found && break

            rel_path  = collect(zipper_path(rz))
            full_path = vcat(prefix_bytes, rel_path)
            remove_val_at!(s.btm, full_path)
            rt = MORK.Expr(full_path)
            space_interpret!(s, rt)
            done += 1
        end
        done
    catch e
        @warn "space_metta_calculus_at!: $e"
        0
    end
end

# =====================================================================
# space_acquire_transform_permissions — server-branch addition
# Mirrors Space::acquire_transform_permissions in space_temporary.rs.
# Returns (read_map, template_prefixes, writer_paths) where:
#   read_map          = PathMap copy of all pattern subtries
#   template_prefixes = Vector{Tuple{Int,Int}} (incremental_start, writer_idx)
#   writer_paths      = Vector{Vector{UInt8}} (one path per unique writer slot)
# =====================================================================

function space_acquire_transform_permissions(s::Space,
                                              patterns::Vector{MORK.Expr},
                                              templates::Vector{MORK.Expr})
    # Compute constant prefix for each expression (longest ground prefix)
    # Simplified: use empty prefix (matches all) — mirrors till_constant_to_full fallback
    _prefix(e::MORK.Expr) = UInt8[]

    # Build template prefix table, sorted shortest-first (mirrors sort_by len)
    tpl_paths = [_prefix(t) for t in templates]
    sorted_idx = sortperm(tpl_paths; by=length)

    # Find unique writer slots via prefix subsumption
    writer_slots = Vector{UInt8}[]
    writer_slot_idx = zeros(Int, length(templates))
    for i in sorted_idx
        path = tpl_paths[i]
        subsumed = false
        for (slot_idx, slot_path) in enumerate(writer_slots)
            overlap = 0
            for j in 1:min(length(path), length(slot_path))
                path[j] == slot_path[j] ? (overlap = j) : break
            end
            if overlap == length(slot_path)
                writer_slot_idx[i] = slot_idx
                subsumed = true
                break
            end
        end
        if !subsumed
            push!(writer_slots, path)
            writer_slot_idx[i] = length(writer_slots)
        end
    end

    # Build template_prefixes: (incremental_path_start, writer_slot_idx)
    template_prefixes = [(length(writer_slots[writer_slot_idx[i]]), writer_slot_idx[i])
                         for i in 1:length(templates)]

    # Build read_map: copy each pattern subtrie
    read_map = PathMap{UnitVal}()
    for pat in patterns
        prefix = _prefix(pat)
        rz = read_zipper_at_path(s.btm, prefix)
        wz = write_zipper_at_path(read_map, prefix)
        while zipper_to_next_val!(rz)
            set_val_at!(read_map, collect(zipper_path(rz)), UNIT_VAL)
        end
    end

    (read_map, template_prefixes, writer_slots)
end

export space_backup_symbols, space_restore_symbols!
export space_prefix_subsumption, space_token_bfs, space_load_csv!
export BreakQuery, space_query_multi, space_query_multi_i, _space_query_multi_inner!
export space_query_coref, _coreferential_transition!
export space_transform_multi_multi!
export space_interpret!, space_metta_calculus!
export space_sexpr_to_expr, space_metta_calculus_at!, space_acquire_transform_permissions

# Precompile hot-path method specializations so JIT fires at package load,
# not on first user call. Mirrors upstream's statically-compiled hot paths.
precompile(space_metta_calculus!, (Space, Int))
precompile(space_interpret!, (Space, MORK.Expr))
precompile(space_add_all_sexpr!, (Space, String))
precompile(space_dump_all_sexpr, (Space,))
precompile(_space_query_multi_inner!, (PathMap{UnitVal}, MORK.Expr, Int, Function, Dict{ExprVar,ExprEnv}, Vector{Tuple{ExprEnv,ExprEnv}}))
