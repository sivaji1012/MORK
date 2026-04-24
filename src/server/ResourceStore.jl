"""
ResourceStore — 1:1 port of `mork/server/src/resource_store.rs`.

Caches and catalogs versioned resources on disk for the import command.
Files are named: <timestamp_hex>-<cmd_id_hex>-<hash_hex>
In-progress files use timestamp IN_PROGRESS_TIMESTAMP = "0000000000000000".

Julia translation notes:
  - Rust `tokio::fs` async → Julia synchronous `Base` file ops
  - Rust `gxhash::gxhash64` → Julia `hash()` (different hash, same purpose)
  - Rust `ResourceHandle::drop` cleanup → explicit finalize! + close
"""

const RS_HASH_SEED         = Int64(1234)
const RS_IN_PROGRESS_TS    = "0000000000000000"

# =====================================================================
# ResourceHandle — mirrors ResourceHandle in resource_store.rs
# =====================================================================

"""
    ResourceHandle

Represents a resource in-use by a command.
Holds the filesystem path; cleanup on finalize or drop.
Mirrors `ResourceHandle` in resource_store.rs.
"""
mutable struct ResourceHandle
    cmd_id     ::UInt64
    identifier ::String
    path       ::Union{String, Nothing}
end

function rh_path(h::ResourceHandle) :: String
    h.path !== nothing || error("ResourceHandle: resource no longer available")
    h.path
end

"""
    rh_finalize!(h, timestamp)

Rename in-progress file to finalized name with real timestamp.
Mirrors `ResourceHandle::finalize` in resource_store.rs.
"""
function rh_finalize!(h::ResourceHandle, new_timestamp::UInt64)
    old_path = rh_path(h)
    hash_val = hash(h.identifier) % typemax(UInt64)
    new_name = string(new_timestamp, base=16, pad=16) * "-" *
               string(h.cmd_id, base=16, pad=16) * "-" *
               string(hash_val, base=16, pad=16)
    dir_path = dirname(old_path)
    new_path = joinpath(dir_path, new_name)
    mv(old_path, new_path)
    h.path = nothing
end

# Cleanup on GC (mirrors Drop impl — removes in-progress file)
function Base.close(h::ResourceHandle)
    if h.path !== nothing
        try; rm(h.path); catch; end
        h.path = nothing
    end
end

# =====================================================================
# ResourceStore — mirrors ResourceStore in resource_store.rs
# =====================================================================

"""
    ResourceStore

Manages versioned cached resources on disk for the import command.
Mirrors `ResourceStore` in resource_store.rs.
"""
struct ResourceStore
    dir_path ::String
end

"""
    ResourceStore(path)

Create (or verify) resource storage directory.
Mirrors `ResourceStore::new_with_dir_path`.
"""
function ResourceStore(path::AbstractString)
    dir = String(path)
    if ispath(dir) && !isdir(dir)
        error("Resource path exists but is not a directory: $dir")
    end
    mkpath(dir)
    ResourceStore(dir)
end

"""
    rs_new_resource(store, identifier, cmd_id) → ResourceHandle

Create a new in-progress resource file. Errors if already exists.
Mirrors `ResourceStore::new_resource`.
"""
function rs_new_resource(store::ResourceStore, identifier::String, cmd_id::UInt64) :: ResourceHandle
    hash_val  = hash(identifier) % typemax(UInt64)
    file_name = RS_IN_PROGRESS_TS * "-" *
                string(cmd_id, base=16, pad=16) * "-" *
                string(hash_val, base=16, pad=16)
    path = joinpath(store.dir_path, file_name)
    isfile(path) && error("Resource already in-progress: $identifier")
    touch(path)
    ResourceHandle(cmd_id, identifier, path)
end

"""
    rs_reset!(store)

Remove all files in the store and recreate the directory.
Mirrors `ResourceStore::reset`.
"""
function rs_reset!(store::ResourceStore)
    rm(store.dir_path; recursive=true, force=true)
    mkpath(store.dir_path)
end

"""
    rs_purge_before!(store, threshold_timestamp)

Remove all files with timestamp < threshold.
Mirrors `ResourceStore::purge_before_timestamp`.
"""
function rs_purge_before!(store::ResourceStore, threshold::UInt64)
    for entry in readdir(store.dir_path; join=true)
        name = basename(entry)
        length(name) >= 33 || continue
        ts_str = name[1:16]
        ts = tryparse(UInt64, ts_str; base=16)
        ts === nothing && continue
        ts < threshold && rm(entry; force=true)
    end
end

export ResourceStore, ResourceHandle
export rh_path, rh_finalize!
export rs_new_resource, rs_reset!, rs_purge_before!
