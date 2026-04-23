"""
Pure — port of `mork/kernel/src/pure.rs`.

Numeric primitive operations for the MORK evaluation engine.
Covers u8/u16/u32/u64/i8/i16/i32/i64/f32/f64 arithmetic, bitwise,
transcendental, and conversion operations.

All operations follow the convention:
  - Arguments are Vector{UInt8} (big-endian encoded numeric values)
  - Results are Vector{UInt8} (big-endian encoded)
  - The dispatch table `PURE_OPS` maps name → julia_lambda

Julia translation notes
========================
  - Rust `extern "C" fn name(ExprSource, ExprSink)` →
    Julia `(args::Vector{Vector{UInt8}}) → number` (wrapped by _be_bytes)
  - Rust `expr.consume::<T>()` → `_read_T(arg_bytes[i])`
  - Rust `sink.write(SourceItem::Symbol(bytes))` → return `_be_bytes(result)`
  - eval_ffi not needed — just pure numeric lambdas
"""

# =====================================================================
# Big-endian read/write helpers
# =====================================================================

_be_bytes(x::UInt8)   = [x]
_be_bytes(x::UInt16)  = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::UInt32)  = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::UInt64)  = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Int8)    = [reinterpret(UInt8, x)]
_be_bytes(x::Int16)   = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Int32)   = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Int64)   = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Float32) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Float64) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::AbstractVector{UInt8}) = collect(x)  # passthrough for string ops

_read_u8(b)  = b[1]
_read_u16(b) = ntoh(only(reinterpret(UInt16, b[1:2])))
_read_u32(b) = ntoh(only(reinterpret(UInt32, b[1:4])))
_read_u64(b) = ntoh(only(reinterpret(UInt64, b[1:8])))
_read_i8(b)  = reinterpret(Int8, b[1])
_read_i16(b) = ntoh(only(reinterpret(Int16, b[1:2])))
_read_i32(b) = ntoh(only(reinterpret(Int32, b[1:4])))
_read_i64(b) = ntoh(only(reinterpret(Int64, b[1:8])))
_read_f32(b) = ntoh(only(reinterpret(Float32, b[1:4])))
_read_f64(b) = ntoh(only(reinterpret(Float64, b[1:8])))
_read_u32s(b)= UInt32(_read_u64(b))   # shift amounts stored as u64

# =====================================================================
# pure_apply — main entry point
# =====================================================================

"""
    pure_apply(name, arg_bufs) → Vector{UInt8}

Apply numeric primitive `name` to big-endian byte argument vectors.
Returns the big-endian byte result, throws on unknown name.
"""
function pure_apply(name::String, arg_bufs::Vector{Vector{UInt8}}) :: Vector{UInt8}
    f = get(PURE_OPS, name, nothing)
    f === nothing && error("Unknown pure op: $name")
    _be_bytes(f(arg_bufs))
end

# =====================================================================
# PURE_OPS dispatch table
# =====================================================================

const PURE_OPS = Dict{String, Function}(

    # ── u8 ──────────────────────────────────────────────────────────
    "u8_zeros"        => (a) -> UInt8(0),
    "u8_ones"         => (a) -> ~UInt8(0),
    "u8_not"          => (a) -> ~_read_u8(a[1]),
    "u8_swap_bytes"   => (a) -> _read_u8(a[1]),
    "u8_leading_zeros"=> (a) -> UInt8(leading_zeros(_read_u8(a[1]))),
    "u8_leading_ones" => (a) -> UInt8(leading_ones(_read_u8(a[1]))),
    "u8_count_zeros"  => (a) -> UInt8(count_zeros(_read_u8(a[1]))),
    "u8_count_ones"   => (a) -> UInt8(count_ones(_read_u8(a[1]))),
    "u8_reverse_bits" => (a) -> bitreverse(_read_u8(a[1])),
    "u8_nand"  => (a) -> ~(_read_u8(a[1]) & _read_u8(a[2])),
    "u8_andn"  => (a) ->  _read_u8(a[1]) & ~_read_u8(a[2]),
    "u8_nor"   => (a) -> ~(_read_u8(a[1]) | _read_u8(a[2])),
    "u8_xor"   => (a) ->   xor(_read_u8(a[1]), _read_u8(a[2])),
    "u8_xnor"  => (a) ->  ~xor(_read_u8(a[1]), _read_u8(a[2])),
    "u8_shl"   => (a) -> _read_u8(a[1]) << _read_u32s(a[2]),
    "u8_shr"   => (a) -> _read_u8(a[1]) >> _read_u32s(a[2]),
    "u8_and"   => (a) -> reduce(&,   [_read_u8(x) for x in a]; init=~UInt8(0)),
    "u8_or"    => (a) -> reduce(|,   [_read_u8(x) for x in a]; init=UInt8(0)),
    "u8_parity"=> (a) -> reduce(xor, [_read_u8(x) for x in a]; init=UInt8(0)),

    # ── u16 ─────────────────────────────────────────────────────────
    "u16_zeros"        => (a) -> UInt16(0),
    "u16_ones"         => (a) -> ~UInt16(0),
    "u16_not"          => (a) -> ~_read_u16(a[1]),
    "u16_swap_bytes"   => (a) -> bswap(_read_u16(a[1])),
    "u16_leading_zeros"=> (a) -> UInt16(leading_zeros(_read_u16(a[1]))),
    "u16_leading_ones" => (a) -> UInt16(leading_ones(_read_u16(a[1]))),
    "u16_count_zeros"  => (a) -> UInt16(count_zeros(_read_u16(a[1]))),
    "u16_count_ones"   => (a) -> UInt16(count_ones(_read_u16(a[1]))),
    "u16_reverse_bits" => (a) -> bitreverse(_read_u16(a[1])),
    "u16_nand"  => (a) -> ~(_read_u16(a[1]) & _read_u16(a[2])),
    "u16_andn"  => (a) ->  _read_u16(a[1]) & ~_read_u16(a[2]),
    "u16_nor"   => (a) -> ~(_read_u16(a[1]) | _read_u16(a[2])),
    "u16_xor"   => (a) ->   xor(_read_u16(a[1]), _read_u16(a[2])),
    "u16_xnor"  => (a) ->  ~xor(_read_u16(a[1]), _read_u16(a[2])),
    "u16_shl"   => (a) -> _read_u16(a[1]) << _read_u32s(a[2]),
    "u16_shr"   => (a) -> _read_u16(a[1]) >> _read_u32s(a[2]),
    "u16_and"   => (a) -> reduce(&,   [_read_u16(x) for x in a]; init=~UInt16(0)),
    "u16_or"    => (a) -> reduce(|,   [_read_u16(x) for x in a]; init=UInt16(0)),
    "u16_parity"=> (a) -> reduce(xor, [_read_u16(x) for x in a]; init=UInt16(0)),

    # ── u32 ─────────────────────────────────────────────────────────
    "u32_zeros"        => (a) -> UInt32(0),
    "u32_ones"         => (a) -> ~UInt32(0),
    "u32_not"          => (a) -> ~_read_u32(a[1]),
    "u32_swap_bytes"   => (a) -> bswap(_read_u32(a[1])),
    "u32_leading_zeros"=> (a) -> UInt32(leading_zeros(_read_u32(a[1]))),
    "u32_leading_ones" => (a) -> UInt32(leading_ones(_read_u32(a[1]))),
    "u32_count_zeros"  => (a) -> UInt32(count_zeros(_read_u32(a[1]))),
    "u32_count_ones"   => (a) -> UInt32(count_ones(_read_u32(a[1]))),
    "u32_reverse_bits" => (a) -> bitreverse(_read_u32(a[1])),
    "u32_nand"  => (a) -> ~(_read_u32(a[1]) & _read_u32(a[2])),
    "u32_andn"  => (a) ->  _read_u32(a[1]) & ~_read_u32(a[2]),
    "u32_nor"   => (a) -> ~(_read_u32(a[1]) | _read_u32(a[2])),
    "u32_xor"   => (a) ->   xor(_read_u32(a[1]), _read_u32(a[2])),
    "u32_xnor"  => (a) ->  ~xor(_read_u32(a[1]), _read_u32(a[2])),
    "u32_shl"   => (a) -> _read_u32(a[1]) << _read_u32s(a[2]),
    "u32_shr"   => (a) -> _read_u32(a[1]) >> _read_u32s(a[2]),
    "u32_and"   => (a) -> reduce(&,   [_read_u32(x) for x in a]; init=~UInt32(0)),
    "u32_or"    => (a) -> reduce(|,   [_read_u32(x) for x in a]; init=UInt32(0)),
    "u32_parity"=> (a) -> reduce(xor, [_read_u32(x) for x in a]; init=UInt32(0)),

    # ── u64 ─────────────────────────────────────────────────────────
    "u64_zeros"        => (a) -> UInt64(0),
    "u64_ones"         => (a) -> ~UInt64(0),
    "u64_not"          => (a) -> ~_read_u64(a[1]),
    "u64_swap_bytes"   => (a) -> bswap(_read_u64(a[1])),
    "u64_leading_zeros"=> (a) -> UInt64(leading_zeros(_read_u64(a[1]))),
    "u64_leading_ones" => (a) -> UInt64(leading_ones(_read_u64(a[1]))),
    "u64_count_zeros"  => (a) -> UInt64(count_zeros(_read_u64(a[1]))),
    "u64_count_ones"   => (a) -> UInt64(count_ones(_read_u64(a[1]))),
    "u64_reverse_bits" => (a) -> bitreverse(_read_u64(a[1])),
    "u64_nand"  => (a) -> ~(_read_u64(a[1]) & _read_u64(a[2])),
    "u64_andn"  => (a) ->  _read_u64(a[1]) & ~_read_u64(a[2]),
    "u64_nor"   => (a) -> ~(_read_u64(a[1]) | _read_u64(a[2])),
    "u64_xor"   => (a) ->   xor(_read_u64(a[1]), _read_u64(a[2])),
    "u64_xnor"  => (a) ->  ~xor(_read_u64(a[1]), _read_u64(a[2])),
    "u64_shl"   => (a) -> _read_u64(a[1]) << _read_u32s(a[2]),
    "u64_shr"   => (a) -> _read_u64(a[1]) >> _read_u32s(a[2]),
    "u64_and"   => (a) -> reduce(&,   [_read_u64(x) for x in a]; init=~UInt64(0)),
    "u64_or"    => (a) -> reduce(|,   [_read_u64(x) for x in a]; init=UInt64(0)),
    "u64_parity"=> (a) -> reduce(xor, [_read_u64(x) for x in a]; init=UInt64(0)),

    # ── i8 ──────────────────────────────────────────────────────────
    "i8_zeros"  => (a) -> Int8(0),
    "i8_ones"   => (a) -> Int8(-1),
    "i8_not"    => (a) -> ~_read_i8(a[1]),
    "i8_neg"    => (a) -> -_read_i8(a[1]),
    "i8_abs"    => (a) -> abs(_read_i8(a[1])),
    "i8_signum" => (a) -> Int8(sign(_read_i8(a[1]))),
    "i8_add"    => (a) -> reduce(+, [_read_i8(x) for x in a]; init=Int8(0)),
    "i8_mul"    => (a) -> reduce(*, [_read_i8(x) for x in a]; init=Int8(1)),
    "i8_sub"    => (a) -> _read_i8(a[1]) - _read_i8(a[2]),
    "i8_div"    => (a) -> div(_read_i8(a[1]), _read_i8(a[2])),
    "i8_rem"    => (a) -> rem(_read_i8(a[1]), _read_i8(a[2])),
    "i8_min"    => (a) -> min(_read_i8(a[1]), _read_i8(a[2])),
    "i8_max"    => (a) -> max(_read_i8(a[1]), _read_i8(a[2])),

    # ── i16 ─────────────────────────────────────────────────────────
    "i16_zeros" => (a) -> Int16(0),
    "i16_ones"  => (a) -> Int16(-1),
    "i16_not"   => (a) -> ~_read_i16(a[1]),
    "i16_neg"   => (a) -> -_read_i16(a[1]),
    "i16_abs"   => (a) -> abs(_read_i16(a[1])),
    "i16_signum"=> (a) -> Int16(sign(_read_i16(a[1]))),
    "i16_add"   => (a) -> reduce(+, [_read_i16(x) for x in a]; init=Int16(0)),
    "i16_mul"   => (a) -> reduce(*, [_read_i16(x) for x in a]; init=Int16(1)),
    "i16_sub"   => (a) -> _read_i16(a[1]) - _read_i16(a[2]),
    "i16_div"   => (a) -> div(_read_i16(a[1]), _read_i16(a[2])),
    "i16_rem"   => (a) -> rem(_read_i16(a[1]), _read_i16(a[2])),
    "i16_min"   => (a) -> min(_read_i16(a[1]), _read_i16(a[2])),
    "i16_max"   => (a) -> max(_read_i16(a[1]), _read_i16(a[2])),

    # ── i32 ─────────────────────────────────────────────────────────
    "i32_zeros" => (a) -> Int32(0),
    "i32_ones"  => (a) -> Int32(-1),
    "i32_not"   => (a) -> ~_read_i32(a[1]),
    "i32_neg"   => (a) -> -_read_i32(a[1]),
    "i32_abs"   => (a) -> abs(_read_i32(a[1])),
    "i32_signum"=> (a) -> Int32(sign(_read_i32(a[1]))),
    "i32_add"   => (a) -> reduce(+, [_read_i32(x) for x in a]; init=Int32(0)),
    "i32_mul"   => (a) -> reduce(*, [_read_i32(x) for x in a]; init=Int32(1)),
    "i32_sub"   => (a) -> _read_i32(a[1]) - _read_i32(a[2]),
    "i32_div"   => (a) -> div(_read_i32(a[1]), _read_i32(a[2])),
    "i32_rem"   => (a) -> rem(_read_i32(a[1]), _read_i32(a[2])),
    "i32_min"   => (a) -> min(_read_i32(a[1]), _read_i32(a[2])),
    "i32_max"   => (a) -> max(_read_i32(a[1]), _read_i32(a[2])),

    # ── i64 ─────────────────────────────────────────────────────────
    "i64_zeros" => (a) -> Int64(0),
    "i64_ones"  => (a) -> Int64(-1),
    "i64_not"   => (a) -> ~_read_i64(a[1]),
    "i64_neg"   => (a) -> -_read_i64(a[1]),
    "i64_abs"   => (a) -> abs(_read_i64(a[1])),
    "i64_signum"=> (a) -> Int64(sign(_read_i64(a[1]))),
    "i64_add"   => (a) -> reduce(+, [_read_i64(x) for x in a]; init=Int64(0)),
    "i64_mul"   => (a) -> reduce(*, [_read_i64(x) for x in a]; init=Int64(1)),
    "i64_sub"   => (a) -> _read_i64(a[1]) - _read_i64(a[2]),
    "i64_div"   => (a) -> div(_read_i64(a[1]), _read_i64(a[2])),
    "i64_rem"   => (a) -> rem(_read_i64(a[1]), _read_i64(a[2])),
    "i64_min"   => (a) -> min(_read_i64(a[1]), _read_i64(a[2])),
    "i64_max"   => (a) -> max(_read_i64(a[1]), _read_i64(a[2])),

    # ── f32 ─────────────────────────────────────────────────────────
    "f32_zeros"   => (a) -> Float32(0),
    "f32_ones"    => (a) -> Float32(1),
    "f32_nan"     => (a) -> Float32(NaN),
    "f32_inf"     => (a) -> Float32(Inf),
    "f32_neg_inf" => (a) -> Float32(-Inf),
    "f32_neg"     => (a) -> -_read_f32(a[1]),
    "f32_abs"     => (a) -> abs(_read_f32(a[1])),
    "f32_sqrt"    => (a) -> sqrt(_read_f32(a[1])),
    "f32_cbrt"    => (a) -> cbrt(_read_f32(a[1])),
    "f32_ceil"    => (a) -> ceil(_read_f32(a[1])),
    "f32_floor"   => (a) -> floor(_read_f32(a[1])),
    "f32_round"   => (a) -> round(_read_f32(a[1])),
    "f32_trunc"   => (a) -> trunc(_read_f32(a[1])),
    "f32_fract"   => (a) -> _read_f32(a[1]) - trunc(_read_f32(a[1])),
    "f32_exp"     => (a) -> exp(_read_f32(a[1])),
    "f32_exp2"    => (a) -> exp2(_read_f32(a[1])),
    "f32_ln"      => (a) -> log(_read_f32(a[1])),
    "f32_log2"    => (a) -> log2(_read_f32(a[1])),
    "f32_log10"   => (a) -> log10(_read_f32(a[1])),
    "f32_sin"     => (a) -> sin(_read_f32(a[1])),
    "f32_cos"     => (a) -> cos(_read_f32(a[1])),
    "f32_tan"     => (a) -> tan(_read_f32(a[1])),
    "f32_asin"    => (a) -> asin(_read_f32(a[1])),
    "f32_acos"    => (a) -> acos(_read_f32(a[1])),
    "f32_atan"    => (a) -> atan(_read_f32(a[1])),
    "f32_add"     => (a) -> reduce(+, [_read_f32(x) for x in a]; init=Float32(0)),
    "f32_mul"     => (a) -> reduce(*, [_read_f32(x) for x in a]; init=Float32(1)),
    "f32_sub"     => (a) -> _read_f32(a[1]) - _read_f32(a[2]),
    "f32_div"     => (a) -> _read_f32(a[1]) / _read_f32(a[2]),
    "f32_rem"     => (a) -> rem(_read_f32(a[1]), _read_f32(a[2])),
    "f32_pow"     => (a) -> _read_f32(a[1])^_read_f32(a[2]),
    "f32_min"     => (a) -> min(_read_f32(a[1]), _read_f32(a[2])),
    "f32_max"     => (a) -> max(_read_f32(a[1]), _read_f32(a[2])),
    "f32_atan2"   => (a) -> atan(_read_f32(a[1]), _read_f32(a[2])),
    "f32_hypot"   => (a) -> hypot(_read_f32(a[1]), _read_f32(a[2])),
    "f32_fma"     => (a) -> muladd(_read_f32(a[1]), _read_f32(a[2]), _read_f32(a[3])),

    # ── f64 ─────────────────────────────────────────────────────────
    "f64_zeros"   => (a) -> Float64(0),
    "f64_ones"    => (a) -> Float64(1),
    "f64_nan"     => (a) -> Float64(NaN),
    "f64_inf"     => (a) -> Float64(Inf),
    "f64_neg_inf" => (a) -> Float64(-Inf),
    "f64_neg"     => (a) -> -_read_f64(a[1]),
    "f64_abs"     => (a) -> abs(_read_f64(a[1])),
    "f64_sqrt"    => (a) -> sqrt(_read_f64(a[1])),
    "f64_cbrt"    => (a) -> cbrt(_read_f64(a[1])),
    "f64_ceil"    => (a) -> ceil(_read_f64(a[1])),
    "f64_floor"   => (a) -> floor(_read_f64(a[1])),
    "f64_round"   => (a) -> round(_read_f64(a[1])),
    "f64_trunc"   => (a) -> trunc(_read_f64(a[1])),
    "f64_fract"   => (a) -> _read_f64(a[1]) - trunc(_read_f64(a[1])),
    "f64_exp"     => (a) -> exp(_read_f64(a[1])),
    "f64_exp2"    => (a) -> exp2(_read_f64(a[1])),
    "f64_ln"      => (a) -> log(_read_f64(a[1])),
    "f64_log2"    => (a) -> log2(_read_f64(a[1])),
    "f64_log10"   => (a) -> log10(_read_f64(a[1])),
    "f64_sin"     => (a) -> sin(_read_f64(a[1])),
    "f64_cos"     => (a) -> cos(_read_f64(a[1])),
    "f64_tan"     => (a) -> tan(_read_f64(a[1])),
    "f64_asin"    => (a) -> asin(_read_f64(a[1])),
    "f64_acos"    => (a) -> acos(_read_f64(a[1])),
    "f64_atan"    => (a) -> atan(_read_f64(a[1])),
    "f64_add"     => (a) -> reduce(+, [_read_f64(x) for x in a]; init=Float64(0)),
    "f64_mul"     => (a) -> reduce(*, [_read_f64(x) for x in a]; init=Float64(1)),
    "f64_sub"     => (a) -> _read_f64(a[1]) - _read_f64(a[2]),
    "f64_div"     => (a) -> _read_f64(a[1]) / _read_f64(a[2]),
    "f64_rem"     => (a) -> rem(_read_f64(a[1]), _read_f64(a[2])),
    "f64_pow"     => (a) -> _read_f64(a[1])^_read_f64(a[2]),
    "f64_min"     => (a) -> min(_read_f64(a[1]), _read_f64(a[2])),
    "f64_max"     => (a) -> max(_read_f64(a[1]), _read_f64(a[2])),
    "f64_atan2"   => (a) -> atan(_read_f64(a[1]), _read_f64(a[2])),
    "f64_hypot"   => (a) -> hypot(_read_f64(a[1]), _read_f64(a[2])),
    "f64_fma"     => (a) -> muladd(_read_f64(a[1]), _read_f64(a[2]), _read_f64(a[3])),

    # ── type conversions ─────────────────────────────────────────────
    "u8_to_u16"   => (a) -> UInt16(_read_u8(a[1])),
    "u8_to_u32"   => (a) -> UInt32(_read_u8(a[1])),
    "u8_to_u64"   => (a) -> UInt64(_read_u8(a[1])),
    "u8_to_i8"    => (a) -> reinterpret(Int8, _read_u8(a[1])),
    "u8_to_f32"   => (a) -> Float32(_read_u8(a[1])),
    "u8_to_f64"   => (a) -> Float64(_read_u8(a[1])),
    "u16_to_u8"   => (a) -> UInt8(_read_u16(a[1]) & 0xFF),
    "u16_to_u32"  => (a) -> UInt32(_read_u16(a[1])),
    "u16_to_u64"  => (a) -> UInt64(_read_u16(a[1])),
    "u16_to_i16"  => (a) -> reinterpret(Int16, _read_u16(a[1])),
    "u16_to_f32"  => (a) -> Float32(_read_u16(a[1])),
    "u16_to_f64"  => (a) -> Float64(_read_u16(a[1])),
    "u32_to_u8"   => (a) -> UInt8(_read_u32(a[1]) & 0xFF),
    "u32_to_u16"  => (a) -> UInt16(_read_u32(a[1]) & 0xFFFF),
    "u32_to_u64"  => (a) -> UInt64(_read_u32(a[1])),
    "u32_to_i32"  => (a) -> reinterpret(Int32, _read_u32(a[1])),
    "u32_to_f32"  => (a) -> reinterpret(Float32, _read_u32(a[1])),
    "u32_to_f64"  => (a) -> Float64(_read_u32(a[1])),
    "u64_to_u32"  => (a) -> UInt32(_read_u64(a[1]) & 0xFFFFFFFF),
    "u64_to_i64"  => (a) -> reinterpret(Int64, _read_u64(a[1])),
    "u64_to_f64"  => (a) -> Float64(_read_u64(a[1])),
    "i64_to_u64"  => (a) -> reinterpret(UInt64, _read_i64(a[1])),
    "i64_to_f64"  => (a) -> Float64(_read_i64(a[1])),
    "f32_to_f64"  => (a) -> Float64(_read_f32(a[1])),
    "f64_to_f32"  => (a) -> Float32(_read_f64(a[1])),
    "f64_to_i64"  => (a) -> Int64(_read_f64(a[1])),
    "f64_to_u64"  => (a) -> UInt64(_read_f64(a[1])),

    # ── string conversions ────────────────────────────────────────────
    "u8_from_string"  => (a) -> parse(UInt8,   String(a[1])),
    "u16_from_string" => (a) -> parse(UInt16,  String(a[1])),
    "u32_from_string" => (a) -> parse(UInt32,  String(a[1])),
    "u64_from_string" => (a) -> parse(UInt64,  String(a[1])),
    "i8_from_string"  => (a) -> parse(Int8,    String(a[1])),
    "i16_from_string" => (a) -> parse(Int16,   String(a[1])),
    "i32_from_string" => (a) -> parse(Int32,   String(a[1])),
    "i64_from_string" => (a) -> parse(Int64,   String(a[1])),
    "f32_from_string" => (a) -> parse(Float32, String(a[1])),
    "f64_from_string" => (a) -> parse(Float64, String(a[1])),
    "u8_to_string"    => (a) -> Vector{UInt8}(string(_read_u8(a[1]))),
    "u16_to_string"   => (a) -> Vector{UInt8}(string(_read_u16(a[1]))),
    "u32_to_string"   => (a) -> Vector{UInt8}(string(_read_u32(a[1]))),
    "u64_to_string"   => (a) -> Vector{UInt8}(string(_read_u64(a[1]))),
    "i8_to_string"    => (a) -> Vector{UInt8}(string(_read_i8(a[1]))),
    "i16_to_string"   => (a) -> Vector{UInt8}(string(_read_i16(a[1]))),
    "i32_to_string"   => (a) -> Vector{UInt8}(string(_read_i32(a[1]))),
    "i64_to_string"   => (a) -> Vector{UInt8}(string(_read_i64(a[1]))),
    "f32_to_string"   => (a) -> Vector{UInt8}(string(_read_f32(a[1]))),
    "f64_to_string"   => (a) -> Vector{UInt8}(string(_read_f64(a[1]))),
)

# =====================================================================
# Exports
# =====================================================================

export PURE_OPS, pure_apply
