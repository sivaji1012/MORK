"""
EmptyZipper — port of `pathmap/src/empty_zipper.rs`.

A zipper type that moves over a completely empty trie.  All path-existence
and value queries return false/nothing.  Navigation still tracks the path
buffer so absolute-path methods work correctly.
"""

mutable struct EmptyZipper
    path           ::Vector{UInt8}
    path_start_idx ::Int
end

"""
    EmptyZipper() → EmptyZipper

New zipper starting at the root of an empty trie.
"""
EmptyZipper() = EmptyZipper(UInt8[], 0)

"""
    EmptyZipper(root_prefix) → EmptyZipper

New zipper with the given root prefix path.
Mirrors `EmptyZipper::new_at_path`.
"""
function EmptyZipper(root_prefix)
    pv = collect(UInt8, root_prefix)
    EmptyZipper(pv, length(pv))
end

# =====================================================================
# Zipper interface
# =====================================================================

ez_path_exists(::EmptyZipper) = false
ez_is_val(::EmptyZipper)      = false
ez_child_count(::EmptyZipper) = 0
ez_child_mask(::EmptyZipper)  = ByteMask()
ez_val(::EmptyZipper)         = nothing
ez_at_root(z::EmptyZipper)    = length(z.path) == z.path_start_idx
ez_val_count(::EmptyZipper)   = 0
ez_path(z::EmptyZipper)       = view(z.path, z.path_start_idx+1:length(z.path))
ez_origin_path(z::EmptyZipper)= z.path
ez_root_prefix_path(z::EmptyZipper) = view(z.path, 1:z.path_start_idx)

# =====================================================================
# ZipperMoving
# =====================================================================

function ez_reset!(z::EmptyZipper)
    resize!(z.path, z.path_start_idx)
end

function ez_descend_to!(z::EmptyZipper, k)
    append!(z.path, k)
end

function ez_descend_to_byte!(z::EmptyZipper, k::UInt8)
    push!(z.path, k)
end

ez_descend_indexed_byte!(::EmptyZipper, ::Int) = false
ez_descend_first_byte!(::EmptyZipper)          = false
ez_descend_until!(::EmptyZipper)               = false

function ez_ascend!(z::EmptyZipper, steps::Int=1)
    avail = length(z.path) - z.path_start_idx
    if steps > avail
        ez_reset!(z)
        return false
    end
    resize!(z.path, length(z.path) - steps)
    true
end

function ez_ascend_byte!(z::EmptyZipper)
    length(z.path) > z.path_start_idx || return false
    pop!(z.path)
    true
end

function ez_ascend_until!(z::EmptyZipper)
    ez_at_root(z) && return false
    ez_reset!(z)
    true
end

ez_ascend_until_branch!(z::EmptyZipper) = ez_ascend_until!(z)
ez_to_next_sibling_byte!(::EmptyZipper) = false
ez_to_prev_sibling_byte!(::EmptyZipper) = false

# ZipperIteration
ez_to_next_val!(::EmptyZipper)             = false
ez_descend_first_k_path!(::EmptyZipper, _) = false
ez_to_next_k_path!(::EmptyZipper, _)       = false

# ZipperForking
ez_fork!(z::EmptyZipper) = EmptyZipper(ez_origin_path(z))

# =====================================================================
# Exports
# =====================================================================

export EmptyZipper
export ez_path_exists, ez_is_val, ez_child_count, ez_child_mask, ez_val
export ez_at_root, ez_val_count, ez_path, ez_origin_path, ez_root_prefix_path
export ez_reset!, ez_descend_to!, ez_descend_to_byte!
export ez_descend_indexed_byte!, ez_descend_first_byte!, ez_descend_until!
export ez_ascend!, ez_ascend_byte!, ez_ascend_until!, ez_ascend_until_branch!
export ez_to_next_sibling_byte!, ez_to_prev_sibling_byte!
export ez_to_next_val!, ez_descend_first_k_path!, ez_to_next_k_path!
export ez_fork!
