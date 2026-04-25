"""
Server — port of `mork/server/src/main.rs`.

HTTP/1.1 server using HTTP.jl (mirrors Hyper + Tokio in Rust).
Dispatches GET/POST requests to command handlers.

Environment variables (mirrors upstream):
  MORK_SERVER_ADDR  — bind address (default "127.0.0.1")
  MORK_SERVER_PORT  — port (default "8080")

Usage:
  server = MorkServer()
  serve!(server)         # blocks until stop command received
"""

using HTTP

const SERVER_ADDR_ENV = "MORK_SERVER_ADDR"
const SERVER_PORT_ENV = "MORK_SERVER_PORT"
const DEFAULT_ADDR    = "127.0.0.1"
const DEFAULT_PORT    = "8080"

# =====================================================================
# MorkServer — mirrors MorkService in main.rs
# =====================================================================

mutable struct MorkServer
    ss          ::ServerSpace
    addr        ::String
    port        ::Int
    stop_flag   ::Ref{Bool}
    request_counter ::Ref{Int}
end

function MorkServer(; addr::String=get(ENV, SERVER_ADDR_ENV, DEFAULT_ADDR),
                      port::Int=parse(Int, get(ENV, SERVER_PORT_ENV, DEFAULT_PORT)))
    MorkServer(ServerSpace(), addr, port, Ref(false), Ref(0))
end

# =====================================================================
# Request routing — mirrors Service::call in main.rs
# =====================================================================

function _split_command(path::String) :: Tuple{String, Vector{String}}
    # Strip leading slash, split on /, URL-decode each segment
    parts = filter!(!isempty, split(lstrip(path, '/'), '/'))
    isempty(parts) && return ("", String[])
    decoded = [HTTP.URIs.unescapeuri(String(p)) for p in parts]
    decoded[1], decoded[2:end]
end

function _parse_query(uri::HTTP.URI) :: Dict{String,String}
    params = Dict{String,String}()
    isempty(uri.query) && return params
    for pair in split(uri.query, '&')
        kv = split(pair, '='; limit=2)
        length(kv) == 2 && (params[string(kv[1])] = HTTP.URIs.unescapeuri(string(kv[2])))
    end
    params
end

function _handle_request(server::MorkServer, req::HTTP.Request) :: HTTP.Response
    server.request_counter[] += 1
    cmd_id = server.request_counter[]

    uri          = HTTP.URI(req.target)
    cmd_name, args = _split_command(String(uri.path))
    body         = Vector{UInt8}(req.body)
    query_params = _parse_query(uri)

    # Favicon — return minimal transparent ICO so browsers stop retrying with 404s
    if cmd_name == "favicon.ico"
        ico = UInt8[0x00,0x00,0x01,0x00,0x01,0x00,0x01,0x01,0x00,0x00,0x01,0x00,
                    0x18,0x00,0x0A,0x00,0x00,0x00,0x16,0x00,0x00,0x00]
        return HTTP.Response(200, ["Content-Type" => "image/x-icon"], ico)
    end

    # Root path — return API index with clickable links
    if isempty(cmd_name)
        # Use the Host header so links work correctly from any machine (Windows, etc.)
        host_hdr  = HTTP.header(req, "Host", "$(server.addr == "0.0.0.0" ? "localhost" : server.addr):$(server.port)")
        base_url  = "http://$(host_hdr)"
        commands  = sort(collect(keys(COMMAND_TABLE)))
        cmd_links = join(["<li><a href=\"/$c\"><code>/$c</code></a></li>" for c in commands])
        html = """<!DOCTYPE html><html><head><title>MORK Server</title></head><body>
<h2>MORK Server v$(MORK.version())</h2>
<p>Requests: $(server.request_counter[])  |  Space size: $(space_val_count(server.ss.space)) expressions</p>
<h3>Commands</h3><ul>$cmd_links</ul>
<h3>Quick check</h3>
<p><a href="$base_url/status/-">$base_url/status/-</a></p>
<pre>curl $base_url/status/-</pre>
</body></html>"""
        return HTTP.Response(200, ["Content-Type" => "text/html"], html)
    end

    # Stop command check
    if cmd_name == "stop"
        server.stop_flag[] = true
        return HTTP.Response(200, "shutting down")
    end

    entry = get(COMMAND_TABLE, cmd_name, nothing)
    if entry === nothing
        return HTTP.Response(404, "Unknown command: $cmd_name\nAvailable: " * join(sort(collect(keys(COMMAND_TABLE))), ", "))
    end

    _http_method, handler_fn = entry

    result = try
        handler_fn(server.ss, args, query_params, body)
    catch e
        (:error, 500, "Internal error: $e")
    end

    _work_result_to_response(result)
end

function _work_result_to_response(result::WorkResult) :: HTTP.Response
    kind = result[1]
    if kind === :ok
        HTTP.Response(200, result[2])
    elseif kind === :error
        HTTP.Response(result[2], result[3])
    elseif kind === :stream
        # SSE stream: drain channel and format as Server-Sent Events.
        # Mirrors WorkResult::Streamed in the upstream — each StatusRecord
        # is emitted as "data: <json>\n\n" per the SSE spec.
        ch       = result[2]
        buf      = IOBuffer()
        deadline = time() + 10.0   # collect for up to 10 s then flush
        while time() < deadline && (isopen(ch) || isready(ch))
            isready(ch) || sleep(0.05)
            isready(ch) || break
            rec = take!(ch)
            write(buf, "data: ", status_to_json(rec), "\n\n")
        end
        close(ch)
        HTTP.Response(200,
            ["Content-Type" => "text/event-stream",
             "Cache-Control" => "no-cache",
             "Connection"    => "keep-alive"],
            take!(buf))
    else
        HTTP.Response(500, "unknown work result kind")
    end
end

# =====================================================================
# serve! — start the HTTP server (blocks until stop_flag set)
# Mirrors MorkService::run in main.rs
# =====================================================================

"""
    serve!(server; verbose=true)

Start the MORK HTTP server.  Blocks until a /stop request is received
or the process is interrupted.  Mirrors `MorkService::run` in main.rs.
"""
function serve!(server::MorkServer; verbose::Bool=true)
    addr = "$(server.addr):$(server.port)"
    verbose && println("MORK server starting on http://$addr")

    server.stop_flag[] = false

    http_server = HTTP.Sockets.listen(HTTP.Sockets.InetAddr(
        parse(HTTP.Sockets.IPAddr, server.addr), server.port))

    @async HTTP.serve!(http_server) do req
        _handle_request(server, req)
    end

    # Poll until stop flag
    while !server.stop_flag[]
        sleep(0.1)
    end

    verbose && println("MORK server shutting down")
    close(http_server)
    sm_shutdown!(server.ss.status_map)
end

"""
    serve_background!(server) → Task

Start the MORK HTTP server in a background task.  Returns the task.
"""
function serve_background!(server::MorkServer) :: Task
    @async serve!(server; verbose=true)
end

"""
    serve_background!(ss, port; addr="127.0.0.1") → Task

Convenience: wrap `ss` in a `MorkServer` and start it in a background task.
"""
function serve_background!(ss::ServerSpace, port::Int; addr::String="127.0.0.1") :: Task
    srv = MorkServer(ss, addr, port, Ref(false), Ref(0))
    serve_background!(srv)
end

export MorkServer, serve!, serve_background!
