"""
OverlayZipper — port of `pathmap/src/overlay_zipper.rs`.

A virtual zipper that fuses two underlying zippers (A and B) into one
virtual trie whose paths are the union of A and B.  A `mapping` function
combines values from A and B at each position.

Julia translation notes:
  - Rust generic `Mapping: for<'a> Fn(Option<&'a AV>, Option<&'a BV>) -> Option<&'a OutV>`
    becomes a Julia `Function` field (no HRTB needed; GC handles lifetimes).
  - Both A and B must implement the ReadZipperCore-compatible interface.
  - `val_count()` is unimplemented upstream (todo!()); stubbed here.
"""

# =====================================================================
# OverlayZipper struct
# =====================================================================

"""
    OverlayZipper{VA, VB, VOut, ZA, ZB}

Virtual zipper over the union of two source tries.
Mirrors `OverlayZipper<AV, BV, OutV, AZipper, BZipper, Mapping>`.
"""
mutable struct OverlayZipper{VA, VB, VOut, ZA, ZB}
    a       ::ZA                   # zipper over trie A
    b       ::ZB                   # zipper over trie B
    mapping ::Function             # (Union{Nothing,VA}, Union{Nothing,VB}) → Union{Nothing,VOut}
end

"""
    OverlayZipper(a, b) → OverlayZipper

Default mapping: A-value takes priority over B-value.
Mirrors `OverlayZipper::new`.
"""
function OverlayZipper(a::ZA, b::ZB) where {ZA, ZB}
    zipper_reset!(a)
    zipper_reset!(b)
    VA = _overlay_val_type(ZA)
    VB = _overlay_val_type(ZB)
    OverlayZipper{VA, VB, VA, ZA, ZB}(a, b, (av, bv) -> av !== nothing ? av : bv)
end

"""
    OverlayZipper(a, b, mapping) → OverlayZipper

Custom mapping function.  Mirrors `OverlayZipper::with_mapping`.
"""
function OverlayZipper(a::ZA, b::ZB, mapping::Function) where {ZA, ZB}
    zipper_reset!(a)
    zipper_reset!(b)
    VA   = _overlay_val_type(ZA)
    VB   = _overlay_val_type(ZB)
    VOut = VA   # best-effort; Julia can't infer return type from Function
    OverlayZipper{VA, VB, VOut, ZA, ZB}(a, b, mapping)
end

# Helper to extract value type parameter from ReadZipperCore{V,A}
_overlay_val_type(::Type{ReadZipperCore{V,A}}) where {V,A} = V
_overlay_val_type(::Type{T}) where T = Any

# =====================================================================
# Zipper interface
# =====================================================================

"""Value at the overlay cursor — the mapping function decides."""
function oz_val(oz::OverlayZipper)
    oz.mapping(zipper_val(oz.a), zipper_val(oz.b))
end

oz_is_val(oz::OverlayZipper) = oz_val(oz) !== nothing

oz_path_exists(oz::OverlayZipper) =
    zipper_path_exists(oz.a) || zipper_path_exists(oz.b)

"""Union of both child masks."""
oz_child_mask(oz::OverlayZipper) = zipper_child_mask(oz.a) | zipper_child_mask(oz.b)

oz_child_count(oz::OverlayZipper) = count_bits(oz_child_mask(oz))

"""Path — both zippers are kept in sync so A's path is canonical."""
oz_path(oz::OverlayZipper) = zipper_path(oz.a)

"""val_count is unimplemented upstream (todo!()). Returns 0."""
oz_val_count(::OverlayZipper) = 0

oz_at_root(oz::OverlayZipper) = zipper_at_root(oz.a) || zipper_at_root(oz.b)

# =====================================================================
# ZipperMoving
# =====================================================================

function oz_reset!(oz::OverlayZipper)
    zipper_reset!(oz.a)
    zipper_reset!(oz.b)
end

function oz_descend_to!(oz::OverlayZipper, path)
    zipper_descend_to!(oz.a, path)
    zipper_descend_to!(oz.b, path)
end

function oz_descend_to_byte!(oz::OverlayZipper, k::UInt8)
    zipper_descend_to_byte!(oz.a, k)
    zipper_descend_to_byte!(oz.b, k)
end

function oz_descend_indexed_byte!(oz::OverlayZipper, idx::Int)
    mask = oz_child_mask(oz)
    byte = indexed_bit(mask, idx, true)
    byte === nothing && return false
    oz_descend_to_byte!(oz, byte)
    true
end

oz_descend_first_byte!(oz::OverlayZipper) = oz_descend_indexed_byte!(oz, 0)

function oz_ascend!(oz::OverlayZipper, steps::Int=1)
    zipper_ascend!(oz.a, steps) | zipper_ascend!(oz.b, steps)
end

oz_ascend_byte!(oz::OverlayZipper) = oz_ascend!(oz, 1)

function oz_to_next_sibling_byte!(oz::OverlayZipper)
    _oz_to_sibling!(oz, true)
end

function oz_to_prev_sibling_byte!(oz::OverlayZipper)
    _oz_to_sibling!(oz, false)
end

function _oz_to_sibling!(oz::OverlayZipper, next::Bool)
    path = oz_path(oz)
    isempty(path) && return false
    last = path[end]
    oz_ascend!(oz, 1)
    mask = oz_child_mask(oz)
    maybe_child = next ? next_bit(mask, last) : prev_bit(mask, last)
    if maybe_child !== nothing
        oz_descend_to_byte!(oz, maybe_child)
        return true
    else
        oz_descend_to_byte!(oz, last)
        return false
    end
end

"""
Descend until branch or val in both zippers, keeping them synchronized.
Mirrors `OverlayZipper::descend_until`.
"""
function oz_descend_until!(oz::OverlayZipper)
    start_depth = length(zipper_path(oz.a))
    desc_a = zipper_descend_until!(oz.a)
    desc_b = zipper_descend_until!(oz.b)
    path_a = zipper_path(oz.a)
    path_b = zipper_path(oz.b)
    sub_a  = path_a[start_depth+1:end]
    sub_b  = path_b[start_depth+1:end]

    !desc_a && !desc_b && return false

    if !desc_a && desc_b
        if zipper_child_count(oz.a) == 0
            zipper_descend_to!(oz.a, sub_b)
            return true
        else
            zipper_ascend!(oz.b, length(sub_b))
            return false
        end
    end
    if desc_a && !desc_b
        if zipper_child_count(oz.b) == 0
            zipper_descend_to!(oz.b, sub_a)
            return true
        else
            zipper_ascend!(oz.a, length(sub_a))
            return false
        end
    end

    overlap = find_prefix_overlap(sub_a, sub_b)
    if length(sub_a) > overlap
        zipper_ascend!(oz.a, length(sub_a) - overlap)
    end
    if length(sub_b) > overlap
        zipper_ascend!(oz.b, length(sub_b) - overlap)
    end
    overlap > 0
end

function oz_ascend_until!(oz::OverlayZipper)
    asc_a   = zipper_ascend_until!(oz.a)
    depth_a = length(zipper_path(oz.a))
    asc_b   = zipper_ascend_until!(oz.b)
    depth_b = length(zipper_path(oz.b))
    !(asc_a || asc_b) && return false
    path_a = zipper_path(oz.a)
    path_b = zipper_path(oz.b)
    if depth_b > depth_a
        zipper_descend_to!(oz.a, path_b[depth_a+1:end])
    elseif depth_a > depth_b
        zipper_descend_to!(oz.b, path_a[depth_b+1:end])
    end
    true
end

function oz_ascend_until_branch!(oz::OverlayZipper)
    asc_a   = zipper_ascend_until_branch!(oz.a)
    depth_a = length(zipper_path(oz.a))
    asc_b   = zipper_ascend_until_branch!(oz.b)
    depth_b = length(zipper_path(oz.b))
    path_a = zipper_path(oz.a)
    path_b = zipper_path(oz.b)
    if depth_b > depth_a
        zipper_descend_to!(oz.a, path_b[depth_a+1:end])
    elseif depth_a > depth_b
        zipper_descend_to!(oz.b, path_a[depth_b+1:end])
    end
    asc_a || asc_b
end

function oz_descend_to_existing!(oz::OverlayZipper, path)
    pv     = collect(UInt8, path)
    depth_a = zipper_descend_to_existing!(oz.a, pv)
    depth_b = zipper_descend_to_existing!(oz.b, pv)
    if depth_a > depth_b
        zipper_descend_to!(oz.b, pv[depth_b+1:depth_a])
        depth_a
    elseif depth_b > depth_a
        zipper_descend_to!(oz.a, pv[depth_a+1:depth_b])
        depth_b
    else
        depth_a
    end
end

function oz_descend_to_val!(oz::OverlayZipper, path)
    pv     = collect(UInt8, path)
    depth_a = zipper_descend_to_val!(oz.a, pv)
    depth_b = zipper_descend_to_val!(oz.b, pv)
    if depth_a < depth_b
        if zipper_is_val(oz.a)
            zipper_ascend!(oz.b, depth_b - depth_a)
            depth_a
        else
            zipper_descend_to!(oz.a, pv[depth_a+1:depth_b])
            depth_b
        end
    elseif depth_b < depth_a
        if zipper_is_val(oz.b)
            zipper_ascend!(oz.a, depth_a - depth_b)
            depth_b
        else
            zipper_descend_to!(oz.b, pv[depth_b+1:depth_a])
            depth_a
        end
    else
        depth_a
    end
end

# =====================================================================
# ZipperIteration — to_next_val uses default impl (zipper.rs defaults)
# =====================================================================

function oz_to_next_val!(oz::OverlayZipper)
    loop_count = 0
    while true
        loop_count += 1
        loop_count > 100_000 && return false  # safety guard
        if oz_descend_first_byte!(oz)
            oz_is_val(oz) && return true
            if oz_descend_until!(oz)
                oz_is_val(oz) && return true
            end
        else
            ascending = true
            while ascending
                if oz_to_next_sibling_byte!(oz)
                    oz_is_val(oz) && return true
                    ascending = false
                else
                    oz_ascend_byte!(oz)
                    oz_at_root(oz) && return false
                end
            end
        end
    end
end

# =====================================================================
# Exports
# =====================================================================

export OverlayZipper
export oz_val, oz_is_val, oz_path_exists, oz_child_mask, oz_child_count
export oz_path, oz_val_count, oz_at_root
export oz_reset!, oz_descend_to!, oz_descend_to_byte!, oz_descend_indexed_byte!
export oz_descend_first_byte!, oz_descend_until!, oz_descend_to_existing!
export oz_descend_to_val!, oz_ascend!, oz_ascend_byte!
export oz_ascend_until!, oz_ascend_until_branch!
export oz_to_next_sibling_byte!, oz_to_prev_sibling_byte!
export oz_to_next_val!
