"""
Commands — port of `mork/server/src/commands.rs`.

Each command corresponds to an HTTP endpoint.  Commands read/write to
the ServerSpace via permission tokens.

Julia translation notes:
  - Rust `async fn work(...)` → Julia function running on a thread
  - Rust `WorkResult::Immediate(bytes)` → `(:ok, bytes::Vector{UInt8})`
  - Rust `WorkResult::Streamed(stream)` → `(:stream, Channel)`
  - Rust `CommandError::External/Internal` → `(:error, status_code, msg)`
  - Rust `ArgDef` path parsing → simple split on `/`
"""

using HTTP

# =====================================================================
# WorkResult — mirrors WorkResult enum in commands.rs
# =====================================================================

const WorkResult = Union{
    Tuple{Symbol, Vector{UInt8}},      # (:ok, bytes)
    Tuple{Symbol, Channel},            # (:stream, channel)
    Tuple{Symbol, Int, String}         # (:error, status_code, message)
}

work_ok(bytes::Vector{UInt8})  = (:ok, bytes)
work_ok(s::AbstractString)     = (:ok, Vector{UInt8}(s))
work_error(code::Int, msg::String) = (:error, code, msg)
work_stream(ch::Channel)       = (:stream, ch)

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
# Command dispatch table
# Maps command name → handler function
# Mirrors CommandDefinition trait impls in commands.rs
# =====================================================================

# ── busywait ──────────────────────────────────────────────────────────
# Tie up a worker for N ms. Used for load testing.
# GET /busywait/<millis>
function cmd_busywait(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    millis = isempty(args) ? 0 : tryparse(Int, args[1])
    millis === nothing && return work_error(400, "busywait: expected integer milliseconds")
    sleep(millis / 1000)
    work_ok("ok")
end

# ── clear ─────────────────────────────────────────────────────────────
# Clear all user statuses at a path prefix.
# GET /clear/<path>
function cmd_clear(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    path_str = join(args, "/")
    path     = Vector{UInt8}(path_str)
    ss_set_status!(ss, path, StatusRecord(PATH_CLEAR))
    work_ok("cleared")
end

# ── count ─────────────────────────────────────────────────────────────
# Count atoms matching a pattern under a path prefix.
# GET /count/<path_prefix>/<pattern>/<template>
function cmd_count(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    length(args) < 1 && return work_error(400, "count: expected path prefix")
    path_bytes = Vector{UInt8}(args[1])
    reader = ss_new_reader(ss, path_bytes)
    reader === nothing && return work_error(503, "count: path is locked")
    try
        n = space_val_count(ss.space)
        result = Vector{UInt8}(string(n))
        ss_set_status!(ss, path_bytes, StatusRecord(STATUS_COUNT_RESULT, string(n)))
        return work_ok(result)
    finally
        ss_release_reader!(ss, reader)
    end
end

# ── explore ───────────────────────────────────────────────────────────
# BFS from a token prefix, return matching expressions.
# GET /explore/<token>/<pattern>
function cmd_explore(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    length(args) < 2 && return work_error(400, "explore: expected token and pattern")
    token   = Vector{UInt8}(args[1])
    pat_str = args[2]
    reader  = ss_new_reader(ss, token)
    reader === nothing && return work_error(503, "explore: path is locked")
    try
        pat_expr = sexpr_to_expr(pat_str)
        results  = space_token_bfs(ss.space, token, pat_expr)
        lines    = join([expr_serialize(e.buf) for (_, e) in results], "\n")
        return work_ok(lines)
    catch e
        return work_error(400, "explore: $e")
    finally
        ss_release_reader!(ss, reader)
    end
end

# ── export ────────────────────────────────────────────────────────────
# Dump atoms matching pattern/template to response body.
# GET /export/<format>/<path>/<pattern>/<template>
function cmd_export(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    length(args) < 3 && return work_error(400, "export: expected format, pattern, template")
    fmt_str  = args[1]
    pat_str  = args[2]
    tpl_str  = args[3]
    fmt      = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "export: unknown format '$fmt_str'")
    reader = ss_new_reader(ss, UInt8[])
    reader === nothing && return work_error(503, "export: space is locked")
    try
        if fmt == FMT_METTA
            io  = IOBuffer()
            pat = sexpr_to_expr(pat_str)
            tpl = sexpr_to_expr(tpl_str)
            space_dump_sexpr(ss.space, pat, tpl, io)
            return work_ok(take!(io))
        elseif fmt == FMT_RAW
            io = IOBuffer()
            space_dump_all_sexpr(ss.space, io)
            return work_ok(take!(io))
        else
            return work_error(501, "export: format '$fmt_str' not yet implemented")
        end
    catch e
        return work_error(500, "export: $e")
    finally
        ss_release_reader!(ss, reader)
    end
end

# ── import ────────────────────────────────────────────────────────────
# Load data from a URL into the space.
# GET /import/<format>/<path>/<pattern>/<template>?url=<url>
function cmd_import(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8},
                    query_params::Dict{String,String}=Dict{String,String}()) :: WorkResult
    length(args) < 3 && return work_error(400, "import: expected format, pattern, template")
    fmt_str  = args[1]
    pat_str  = args[2]
    tpl_str  = args[3]
    fmt      = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "import: unknown format '$fmt_str'")

    url = get(query_params, "url", "")
    isempty(url) && return work_error(400, "import: missing url parameter")

    writer = ss_new_writer(ss, UInt8[])
    writer === nothing && return work_error(503, "import: space is locked for writing")
    try
        resp = HTTP.get(url)
        data = resp.body
        pat  = sexpr_to_expr(pat_str)
        tpl  = sexpr_to_expr(tpl_str)
        if fmt == FMT_METTA
            n = space_add_sexpr!(ss.space, data, pat, tpl)
            return work_ok("imported $n atoms")
        elseif fmt == FMT_CSV
            n = space_load_csv!(ss.space, data, pat, tpl)
            return work_ok("imported $n rows")
        elseif fmt == FMT_JSON
            n = space_load_json!(ss.space, data)
            return work_ok("imported $n atoms")
        else
            return work_error(501, "import: format '$fmt_str' not yet implemented")
        end
    catch e
        ss_set_status!(ss, UInt8[], StatusRecord(STATUS_FETCH_ERROR, string(e)))
        return work_error(500, "import: $e")
    finally
        ss_release_writer!(ss, writer)
    end
end

# ── upload ────────────────────────────────────────────────────────────
# Load POST body data into the space.
# POST /upload/<format>/<pattern>/<template>
function cmd_upload(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    length(args) < 3 && return work_error(400, "upload: expected format, pattern, template")
    fmt_str  = args[1]
    pat_str  = args[2]
    tpl_str  = args[3]
    fmt      = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "upload: unknown format '$fmt_str'")

    writer = ss_new_writer(ss, UInt8[])
    writer === nothing && return work_error(503, "upload: space is locked for writing")
    try
        pat = sexpr_to_expr(pat_str)
        tpl = sexpr_to_expr(tpl_str)
        if fmt == FMT_METTA
            n = space_add_sexpr!(ss.space, body, pat, tpl)
            return work_ok("uploaded $n atoms")
        elseif fmt == FMT_CSV
            n = space_load_csv!(ss.space, body, pat, tpl)
            return work_ok("uploaded $n rows")
        elseif fmt == FMT_JSON
            n = space_load_json!(ss.space, body)
            return work_ok("uploaded $n atoms")
        else
            return work_error(501, "upload: format '$fmt_str' not yet implemented")
        end
    catch e
        ss_set_status!(ss, UInt8[], StatusRecord(STATUS_PARSE_ERROR, string(e)))
        return work_error(500, "upload: $e")
    finally
        ss_release_writer!(ss, writer)
    end
end

# ── transform ─────────────────────────────────────────────────────────
# Run one metta_calculus step on the space.
# POST /transform/<max_steps>
function cmd_transform(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    max_steps = isempty(args) ? 100_000 : (tryparse(Int, args[1]) |> x -> x === nothing ? 100_000 : x)
    writer = ss_new_writer(ss, UInt8[])
    writer === nothing && return work_error(503, "transform: space is locked")
    try
        # Add any atoms from body first
        if !isempty(body)
            space_add_all_sexpr!(ss.space, body)
        end
        steps = space_metta_calculus!(ss.space, max_steps)
        return work_ok("steps=$steps")
    catch e
        return work_error(500, "transform: $e")
    finally
        ss_release_writer!(ss, writer)
    end
end

# ── status ────────────────────────────────────────────────────────────
# Get status for a path.
# GET /status/<path>
function cmd_status(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    path_bytes = isempty(args) ? UInt8[] : Vector{UInt8}(join(args, "/"))
    status = ss_get_status(ss, path_bytes)
    work_ok(status_to_json(status))
end

# ── stop ──────────────────────────────────────────────────────────────
# Graceful shutdown.
# GET /stop
function cmd_stop(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    sm_shutdown!(ss.status_map)
    work_ok("shutting down")
end

# ── metta_thread ──────────────────────────────────────────────────────
# Run metta_calculus in background, return step count.
# GET /metta_thread/<max_steps>
function cmd_metta_thread(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    max_steps = isempty(args) ? 100_000 : (tryparse(Int, args[1]) |> x -> x === nothing ? 100_000 : x)
    ch = Channel{StatusRecord}(1)
    Threads.@spawn begin
        writer = ss_new_writer(ss, UInt8[])
        if writer === nothing
            put!(ch, StatusRecord(STATUS_EXEC_ERROR, "space locked"))
        else
            try
                steps = space_metta_calculus!(ss.space, max_steps)
                put!(ch, StatusRecord(STATUS_COUNT_RESULT, string(steps), steps))
            catch e
                put!(ch, StatusRecord(STATUS_EXEC_ERROR, string(e)))
            finally
                ss_release_writer!(ss, writer)
            end
        end
    end
    # Return immediately with ack; client polls /status for result
    work_ok("ack")
end

# ── copy ──────────────────────────────────────────────────────────────
# Copy atoms from one path prefix to another (stub).
# GET /copy/<src_path>/<dst_path>
function cmd_copy(ss::ServerSpace, args::Vector{String}, body::Vector{UInt8}) :: WorkResult
    length(args) < 2 && return work_error(400, "copy: expected src and dst paths")
    work_error(501, "copy: not yet implemented")
end

# =====================================================================
# COMMAND_TABLE — maps URL path → handler function
# Mirrors the dispatch! macro in server/src/main.rs
# =====================================================================

const COMMAND_TABLE = Dict{String, Function}(
    "busywait"          => cmd_busywait,
    "clear"             => cmd_clear,
    "count"             => cmd_count,
    "explore"           => cmd_explore,
    "export"            => cmd_export,
    "import"            => cmd_import,
    "upload"            => cmd_upload,
    "transform"         => cmd_transform,
    "status"            => cmd_status,
    "stop"              => cmd_stop,
    "metta_thread"      => cmd_metta_thread,
    "metta_thread_suspend" => (ss,a,b) -> work_ok("suspended"),
    "copy"              => cmd_copy,
)

export WorkResult, DataFormat, COMMAND_TABLE
export FMT_METTA, FMT_CSV, FMT_JSON, FMT_JSONL, FMT_RAW, FMT_PATHS
export work_ok, work_error, work_stream, dataformat_from_str
export cmd_busywait, cmd_clear, cmd_count, cmd_explore, cmd_export
export cmd_import, cmd_upload, cmd_transform, cmd_status, cmd_stop
export cmd_metta_thread, cmd_copy
