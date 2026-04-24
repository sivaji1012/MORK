"""
Commands — 1:1 port of `mork/server/src/commands.rs`.

Each command mirrors the upstream Rust CommandDefinition impl exactly:
  - ACK-and-async pattern (count, import, metta_thread) → return ACK immediately,
    spawn background task, write result to status_map
  - Synchronous pattern (clear, copy, status, stop) → return result directly
  - Worker pattern (explore, export, upload, transform) → run blocking work
    on a thread, return result

Julia translation:
  - Rust `tokio::task::spawn_blocking` → `Threads.@spawn`
  - Rust `WorkResult::Immediate(bytes)` → `(:ok, bytes)`
  - Rust `StatusRecord::CountResult(n)` → `StatusRecord(STATUS_COUNT_RESULT, string(n), n)`
  - Rust `derive_prefix_from_expr_slice` → not yet ported (stub: use empty prefix)
  - Rust `pattern_template_from_sexpr_pair` → `_parse_pattern_template`
"""

using HTTP
using JSON3

# =====================================================================
# DataFormat — mirrors DataFormat enum in commands.rs
# =====================================================================

@enum DataFormat begin
    FMT_METTA
    FMT_CSV
    FMT_JSON
    FMT_JSONL
    FMT_RAW
    FMT_PATHS
end

function dataformat_from_str(s::AbstractString) :: Union{DataFormat, Nothing}
    d = Dict("metta"=>FMT_METTA, "csv"=>FMT_CSV, "json"=>FMT_JSON,
             "jsonl"=>FMT_JSONL, "raw"=>FMT_RAW, "paths"=>FMT_PATHS)
    get(d, lowercase(s), nothing)
end

# =====================================================================
# WorkResult — mirrors WorkResult enum in commands.rs
# =====================================================================

# (:ok, bytes)  — WorkResult::Immediate
# (:error, http_status_code::Int, message::String)
# (:stream, channel::Channel) — WorkResult::Streamed (SSE)

const WorkResult = Tuple   # (:ok, bytes) | (:error, code, msg) | (:stream, ch)

work_ok(s::AbstractString)     = (:ok, Vector{UInt8}(s))
work_ok(b::Vector{UInt8})      = (:ok, b)
work_error(code::Int, msg::String) = (:error, code, msg)
work_stream(ch::Channel)       = (:stream, ch)

# =====================================================================
# Helpers
# =====================================================================

# Mirrors pattern_template_from_sexpr_pair in commands.rs
# Parses "(transform (, pat) (, tpl))" or bare "pat_sexpr tpl_sexpr"
function _parse_pattern_template(ss::ServerSpace, pat_str::String, tpl_str::String)
    pat = sexpr_to_expr(pat_str)
    tpl = sexpr_to_expr(tpl_str)
    (pat, tpl)
end

# Derive a path prefix from an expression (stub — upstream uses
# derive_prefix_from_expr_slice which finds the longest ground prefix)
# For now returns empty prefix (matches all).
function _derive_prefix(expr::MORK.Expr) :: Vector{UInt8}
    UInt8[]
end

# Parse transform POST body: "(transform (, pat...) (, tpl...))"
# Mirrors pattern_template_args in commands.rs
function _parse_transform_body(ss::ServerSpace, src::String)
    # Parse the outer (transform ...) expression
    outer = sexpr_to_expr(src)
    args  = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), outer), args)
    length(args) >= 3 || error("transform: expected (transform (, pats...) (, tpls...))")

    # args[1] = "transform" symbol, args[2] = pattern list, args[3] = template list
    pat_list = args[2]
    tpl_list = args[3]

    # Extract sub-expressions from comma list (, e1 e2 ...)
    function extract_comma_list(ee::ExprEnv)
        sub_args = ExprEnv[]
        ee_args!(ee, sub_args)
        length(sub_args) >= 2 || error("expected comma list")
        # sub_args[1] = "," functor, rest are the elements
        [MORK.Expr(Vector{UInt8}(expr_span(a.base, Int(a.offset)+1))) for a in sub_args[2:end]]
    end

    patterns  = extract_comma_list(pat_list)
    templates = extract_comma_list(tpl_list)
    (patterns, templates)
end

# =====================================================================
# busywait — mirrors BusywaitCmd in commands.rs
# GET /busywait/<millis>
# Ties up a worker for N ms. Returns "ACK. Waiting" immediately.
# =====================================================================
function cmd_busywait(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 1 && return work_error(400, "busywait: expected millis argument")
    millis = tryparse(Int, args[1])
    millis === nothing && return work_error(400, "busywait: expected integer milliseconds")
    Threads.@spawn sleep(millis / 1000)
    work_ok("ACK. Waiting")
end

# =====================================================================
# clear — mirrors ClearCmd in commands.rs
# GET /clear/<expr_sexpr>
# Removes all values at the expression's prefix. Synchronous.
# =====================================================================
function cmd_clear(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    isempty(args) && return work_error(400, "clear: expected expr argument")
    expr_str = join(args, "/")
    try
        expr   = sexpr_to_expr(expr_str)
        prefix = _derive_prefix(expr)
        writer = ss_new_writer(ss, prefix)
        writer === nothing && return work_error(503, "clear: path is locked")
        try
            # Remove all values at this prefix (mirrors wz.remove_branches + wz.remove_val)
            wz = write_zipper_at_path(ss.space.btm, prefix)
            wz_remove_val!(wz, true)
        finally
            ss_release_writer!(ss, writer)
        end
        work_ok("ACK. Cleared")
    catch e
        work_error(400, "clear: $e")
    end
end

# =====================================================================
# copy — mirrors CopyCmd in commands.rs
# GET /copy/<src_expr>/<dst_expr>
# Grafts src subtrie into dst. Synchronous.
# =====================================================================
function cmd_copy(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "copy: expected src_expr and dst_expr")
    try
        src_expr   = sexpr_to_expr(args[1])
        dst_expr   = sexpr_to_expr(args[2])
        src_prefix = _derive_prefix(src_expr)
        dst_prefix = _derive_prefix(dst_expr)

        reader = ss_new_reader(ss, src_prefix)
        reader === nothing && return work_error(503, "copy: source path is locked")
        writer = ss_new_writer(ss, dst_prefix)
        if writer === nothing
            ss_release_reader!(ss, reader); return work_error(503, "copy: dest path is locked")
        end
        try
            # Mirrors wz.graft(&rz) — copy source trie into dest
            src_pm = PathMap{UnitVal}()
            rz = read_zipper_at_path(ss.space.btm, src_prefix)
            while zipper_to_next_val!(rz)
                set_val_at!(src_pm, collect(zipper_path(rz)), UNIT_VAL)
            end
            wz = write_zipper_at_path(ss.space.btm, dst_prefix)
            rz2 = read_zipper(src_pm)
            wz_join_into!(wz, rz2.root_node)
        finally
            ss_release_reader!(ss, reader)
            ss_release_writer!(ss, writer)
        end
        work_ok("ACK. Copied")
    catch e
        work_error(500, "copy: $e")
    end
end

# =====================================================================
# count — mirrors CountCmd in commands.rs
# GET /count/<expr_sexpr>
# Returns "ACK. Starting Count" immediately; result stored in status_map.
# =====================================================================
function cmd_count(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    isempty(args) && return work_error(400, "count: expected expr argument")
    expr_str = join(args, "/")
    try
        expr   = sexpr_to_expr(expr_str)
        prefix = _derive_prefix(expr)
        reader = ss_new_reader(ss, prefix)
        reader === nothing && return work_error(503, "count: path is locked")
        Threads.@spawn begin
            try
                rz = read_zipper_at_path(ss.space.btm, prefix)
                n  = zipper_val_count(rz)
                ss_set_status!(ss, prefix, StatusRecord(STATUS_COUNT_RESULT, string(n), n))
            finally
                ss_release_reader!(ss, reader)
            end
        end
        work_ok("ACK. Starting Count")
    catch e
        work_error(400, "count: $e")
    end
end

# =====================================================================
# explore — mirrors ExploreCmd + do_bfs in commands.rs
# GET /explore/<expr_sexpr>/<focus_token_bytes>
# Returns JSON: [{"token":[bytes],"cnt":N,"expr":"..."}]
# focus_token is opaque bytes for iterative exploration.
# =====================================================================
function cmd_explore(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "explore: expected expr and focus_token")
    expr_str    = args[1]
    focus_token = Vector{UInt8}(args[2])  # opaque bytes from prior call

    try
        expr   = sexpr_to_expr(expr_str)
        prefix = _derive_prefix(expr)
        reader = ss_new_reader(ss, prefix)
        reader === nothing && return work_error(503, "explore: path is locked")

        result_pairs = try
            space_token_bfs(ss.space, focus_token, expr)
        finally
            ss_release_reader!(ss, reader)
        end

        # Mirrors do_bfs JSON output: [{"token":[bytes], "cnt":N, "expr":"..."}]
        io = IOBuffer()
        write(io, "[")
        first = true
        for (new_tok, e) in result_pairs
            first || write(io, ",\n")
            first = false
            tok_bytes = join(string.(new_tok), ", ")
            expr_str  = expr_serialize(e.buf)
            write(io, "{\"token\": [$tok_bytes], \"cnt\": 1, \"expr\": $(JSON3.write(expr_str))}")
        end
        write(io, "]")
        work_ok(take!(io))
    catch e
        work_error(400, "explore: $e")
    end
end

# =====================================================================
# export — mirrors ExportCmd + do_export + dump_as_format in commands.rs
# GET /export/<pattern_sexpr>/<template_sexpr>?format=metta&max_write=N
# Returns serialized atoms matching pattern/template.
# =====================================================================
function cmd_export(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "export: expected pattern and template")
    pat_str  = args[1]
    tpl_str  = args[2]
    fmt_str  = get(props, "format", "metta")
    fmt      = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "export: unrecognized format '$fmt_str'")
    max_write = tryparse(Int, get(props, "max_write", "")) |> x -> x === nothing ? typemax(Int) : x

    try
        pat    = sexpr_to_expr(pat_str)
        tpl    = sexpr_to_expr(tpl_str)
        prefix = _derive_prefix(pat)
        reader = ss_new_reader(ss, prefix)
        reader === nothing && return work_error(503, "export: path is locked")

        io = IOBuffer()
        try
            if fmt == FMT_METTA
                space_dump_sexpr(ss.space, pat, tpl, io)
            elseif fmt == FMT_RAW
                rz = read_zipper_at_path(ss.space.btm, prefix)
                n  = 0
                while zipper_to_next_val!(rz) && n < max_write
                    println(io, repr(collect(zipper_path(rz))))
                    n += 1
                end
            elseif fmt == FMT_PATHS
                space_backup_paths(ss.space, io)
            else
                write(io, "Export Error: Unimplemented Export Format")
            end
        finally
            ss_release_reader!(ss, reader)
        end
        work_ok(take!(io))
    catch e
        work_error(500, "export: $e")
    end
end

# =====================================================================
# import — mirrors ImportCmd + do_import in commands.rs
# GET /import/<pattern_sexpr>/<template_sexpr>?uri=<url>&format=metta
# Returns "ACK. Starting Import" immediately; loads data in background.
# =====================================================================
function cmd_import(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "import: expected pattern and template")
    pat_str = args[1]
    tpl_str = args[2]
    uri     = get(props, "uri", "")
    isempty(uri) && return work_error(400, "import: missing uri property")
    fmt_str = get(props, "format", "metta")
    fmt     = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "import: unrecognized format '$fmt_str'")

    try
        pat    = sexpr_to_expr(pat_str)
        tpl    = sexpr_to_expr(tpl_str)
        writer = ss_new_writer(ss, UInt8[])
        writer === nothing && return work_error(503, "import: space is locked for writing")

        # Allocate a ResourceHandle to track the in-progress download on disk.
        # Mirrors ctx.0.resource_store.new_resource(file_uri, cmd.cmd_id) in commands.rs.
        cmd_id      = _ss_next_cmd_id!(ss)
        file_handle = rs_new_resource(ss.resource_store, uri, cmd_id)

        Threads.@spawn begin
            try
                resp = HTTP.get(uri)
                data = resp.body

                # Stream to disk via the ResourceHandle, then read back.
                # Mirrors do_import's BufWriter → file_resource.path() pattern.
                write(rh_path(file_handle), data)

                n = if fmt == FMT_METTA
                    space_add_sexpr!(ss.space, data, pat, tpl)
                elseif fmt == FMT_CSV
                    space_load_csv!(ss.space, data, pat, tpl)
                elseif fmt == FMT_JSON
                    space_load_json!(ss.space, data)
                else
                    0
                end

                ss_set_status!(ss, UInt8[], StatusRecord(STATUS_COUNT_RESULT, string(n), n))
                # Finalize resource: rename in-progress file with real timestamp.
                rh_finalize!(file_handle, UInt64(time_ns()))

            catch e
                ss_set_status!(ss, UInt8[], StatusRecord(STATUS_FETCH_ERROR, string(e)))
                close(file_handle)   # cleanup in-progress file on error
            finally
                ss_release_writer!(ss, writer)
            end
        end
        work_ok("ACK. Starting Import")
    catch e
        work_error(400, "import: $e")
    end
end

# =====================================================================
# upload — mirrors UploadCmd + do_parse in commands.rs
# POST /upload/<pattern_sexpr>/<template_sexpr>?format=metta
# Body = raw data to parse. Returns "ACK. Upload Successful".
# =====================================================================
function cmd_upload(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "upload: expected pattern and template")
    pat_str  = args[1]
    tpl_str  = args[2]
    fmt_str  = get(props, "format", "metta")
    fmt      = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "upload: unrecognized format '$fmt_str'")

    try
        pat    = sexpr_to_expr(pat_str)
        tpl    = sexpr_to_expr(tpl_str)
        writer = ss_new_writer(ss, UInt8[])
        writer === nothing && return work_error(503, "upload: space is locked for writing")
        try
            if fmt == FMT_METTA
                space_add_sexpr!(ss.space, body, pat, tpl)
            elseif fmt == FMT_CSV
                space_load_csv!(ss.space, body, pat, tpl)
            elseif fmt == FMT_JSON
                space_load_json!(ss.space, body)
            else
                return work_error(501, "upload: unimplemented format '$fmt_str'")
            end
        finally
            ss_release_writer!(ss, writer)
        end
        work_ok("ACK. Upload Successful")
    catch e
        work_error(400, "upload: $e")
    end
end

# =====================================================================
# transform — mirrors TransformCmd + pattern_template_args in commands.rs
# POST /transform
# Body = "(transform (, pat...) (, tpl...))"
# Returns "ACK. TranformMultiMulti dispatched" [sic — matches upstream typo]
# =====================================================================
function cmd_transform(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    isempty(body) && return work_error(400, "transform: empty POST body")
    try
        src = String(body)
        (patterns, templates) = _parse_transform_body(ss, src)

        writer = ss_new_writer(ss, UInt8[])
        writer === nothing && return work_error(503, "transform: space is locked")

        Threads.@spawn begin
            try
                for (pat, tpl) in zip(patterns, templates)
                    space_transform_multi_multi!(ss.space, pat, tpl, pat)
                end
            finally
                ss_release_writer!(ss, writer)
            end
        end
        work_ok("ACK. TranformMultiMulti dispatched")
    catch e
        work_error(400, "transform: $e")
    end
end

# =====================================================================
# status — mirrors StatusCmd in commands.rs
# GET /status/<expr_sexpr>
# Returns JSON status for the expression's path. Synchronous.
# =====================================================================
function cmd_status(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    expr_str = isempty(args) ? "" : join(args, "/")
    prefix   = isempty(expr_str) ? UInt8[] : try
        _derive_prefix(sexpr_to_expr(expr_str))
    catch
        UInt8[]
    end
    status = ss_get_status(ss, prefix)
    work_ok(status_to_json(status))
end

# =====================================================================
# stop — mirrors StopCmd in commands.rs
# GET /stop  or  GET /stop?wait_for_idle
# Sets stop flag. Returns ACK.
# =====================================================================
function cmd_stop(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    wait = haskey(props, "wait_for_idle")
    sm_shutdown!(ss.status_map)
    if wait
        work_ok("ACK. Shutdown will occur when server activity stops")
    else
        work_ok("ACK. Initiating Shutdown.  Connections will not longer be accepted")
    end
end

# =====================================================================
# metta_thread — mirrors MettaThreadCmd in commands.rs
# GET /metta_thread?location=<sexpr>
# Runs metta_calculus at location until exhausted. Returns ACK.
# Result/errors stored in status_map at (exec <location>).
# =====================================================================
function cmd_metta_thread(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    location_str = get(props, "location", "")
    isempty(location_str) && return work_error(501,
        "Thread ID substitution is work in progress. Use the `location` property with a constant, e.g. `?location=task_name`.")

    try
        loc_expr = sexpr_to_expr(location_str)
        status_loc_str = "(exec $location_str)"
        status_loc     = Vector{UInt8}(status_loc_str)

        # Acquire write lock on status location — ensures only one thread runs at that location
        writer = ss_new_writer(ss, status_loc)
        writer === nothing && return work_error(409, "Thread is already running at that location.")

        Threads.@spawn begin
            try
                space_metta_calculus!(ss.space, typemax(Int))
            catch e
                ss_set_status!(ss, status_loc, StatusRecord(STATUS_EXEC_ERROR, string(e)))
            finally
                ss_release_writer!(ss, writer)
            end
        end
        work_ok("Thread `$location_str` was dispatched. Errors will be found at the status location: `$status_loc_str`")
    catch e
        work_error(400, "metta_thread: $e")
    end
end

# =====================================================================
# metta_thread_suspend — mirrors MettaThreadSuspendCmd in commands.rs
# GET /metta_thread_suspend/<exec_loc>/<suspend_loc>
# Moves exec expressions from exec_loc to suspend_loc.
# =====================================================================
function cmd_metta_thread_suspend(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "metta_thread_suspend: expected exec_location and suspend_location")
    # Stub — full implementation requires take_map / graft_map on WriteZipper
    work_error(501, "metta_thread_suspend: not yet fully implemented")
end

# =====================================================================
# COMMAND_TABLE — maps URL path → (fn, method)
# Mirrors the dispatch! macro in server/src/main.rs
# =====================================================================

const COMMAND_TABLE = Dict{String, Tuple{Symbol, Function}}(
    "busywait"              => (:GET,  cmd_busywait),
    "clear"                 => (:GET,  cmd_clear),
    "copy"                  => (:GET,  cmd_copy),
    "count"                 => (:GET,  cmd_count),
    "explore"               => (:GET,  cmd_explore),
    "export"                => (:GET,  cmd_export),
    "import"                => (:GET,  cmd_import),
    "status"                => (:GET,  cmd_status),
    "stop"                  => (:GET,  cmd_stop),
    "metta_thread"          => (:GET,  cmd_metta_thread),
    "metta_thread_suspend"  => (:GET,  cmd_metta_thread_suspend),
    "transform"             => (:POST, cmd_transform),
    "upload"                => (:POST, cmd_upload),
)

export WorkResult, DataFormat, COMMAND_TABLE
export FMT_METTA, FMT_CSV, FMT_JSON, FMT_JSONL, FMT_RAW, FMT_PATHS
export work_ok, work_error, work_stream, dataformat_from_str
export cmd_busywait, cmd_clear, cmd_copy, cmd_count, cmd_explore
export cmd_export, cmd_import, cmd_upload, cmd_transform
export cmd_status, cmd_stop, cmd_metta_thread, cmd_metta_thread_suspend
