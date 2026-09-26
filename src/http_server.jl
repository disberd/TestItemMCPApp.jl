# http_server.jl: serve MCP Streamable HTTP on 127.0.0.1

const HTTP_PORT_DEFAULT = 50020
const MCP_PATH = "/mcp"
# A GET stream with no other output for this many seconds gets a `: keepalive` comment.
const SSE_KEEPALIVE_SECS = 60.0
# A `tools/call` stream gets `: keepalive` after this many seconds of silence. HTTP.jl does
# not tell a handler that the client closed the connection, but a write to a closed
# connection fails. This write is how the server sees that the client closed the request.
const TOOL_CALL_KEEPALIVE_SECS = 1.0
# The `Origin` of a page that this host serves. The server refuses all other origins.
const LOCAL_ORIGIN = r"^http://(localhost|127\.0\.0\.1)(:\d+)?$"

"""
The messages for one HTTP response, or for the GET stream of one client, as JSON text.
`nothing` tells the SSE writer to send a keepalive comment.
"""
const Outbox = Channel{Union{Nothing,String}}

# An outbox closes when its HTTP response ends. Then the outbox has no reader, so the send
# drops the message.
function send_message(outbox::Outbox, message::Dict{String,Any})
    try
        put!(outbox, JSON.json(message))
    catch err
        err isa InvalidStateException || rethrow()
    end
    return
end

send_notification(outbox::Outbox, method::String, params) =
    send_message(outbox, Dict{String,Any}("jsonrpc" => "2.0", "method" => method, "params" => params))

send_result(outbox::Outbox, msg::JSONRPC.Request, result) =
    send_message(outbox, Dict{String,Any}("jsonrpc" => "2.0", "id" => msg.id, "result" => result))

send_error(outbox::Outbox, msg::JSONRPC.Request, code, message, data) =
    send_message(outbox, Dict{String,Any}(
        "jsonrpc" => "2.0",
        "id" => msg.id,
        "error" => Dict{String,Any}("code" => code, "message" => message, "data" => data),
    ))

function parse_port(value::AbstractString, source::AbstractString)
    port = tryparse(Int, value)
    (port === nothing || !(0 <= port <= 65535)) &&
        throw(ArgumentError("$source must be a port number from 0 to 65535, not \"$value\"."))
    return port
end

"""
Return the HTTP port: `port` when it is not `nothing`, else the `JULIAMCP_PORT` environment
variable, else $HTTP_PORT_DEFAULT.
"""
function http_port(port=nothing)
    port === nothing || return port
    return parse_port(get(ENV, "JULIAMCP_PORT", string(HTTP_PORT_DEFAULT)), "JULIAMCP_PORT")
end

"""
Return the path of the token file: `path` when it is not `nothing`, else the
`JULIAMCP_TOKEN_FILE` environment variable, else `juliamcp/token` in the first depot.
"""
function token_file_path(path=nothing)
    path === nothing || return path
    path = get(ENV, "JULIAMCP_TOKEN_FILE", "")
    return isempty(path) ? joinpath(first(DEPOT_PATH), "juliamcp", "token") : path
end

"""
Return the bearer token in the file at `path`. When the file does not exist, first write a
new token to it: 32 random bytes as hex. On POSIX, the new file gets mode 0600, and a
directory that this call makes gets mode 0700. On Windows, the files have no POSIX modes.
"""
function read_or_create_token(path::AbstractString)
    if !ispath(path)
        dir = dirname(abspath(path))
        if !isdir(dir)
            mkpath(dir)
            chmod(dir, 0o700)
        end
        open(path, "w") do io
            # Set the mode before the token goes into the file.
            chmod(path, 0o600)
            write(io, bytes2hex(rand(Random.RandomDevice(), UInt8, 32)))
        end
    end
    token = strip(read(path, String))
    isempty(token) && error("The token file $path is empty.")
    return String(token)
end

"""
Return whether `a` and `b` are equal. The time does not depend on where the strings
differ, so a client cannot find the token one byte at a time.
"""
function secure_equal(a::AbstractString, b::AbstractString)
    x, y = codeunits(a), codeunits(b)
    length(x) == length(y) || return false
    diff = 0x00
    for i in eachindex(x, y)
        diff |= x[i] ⊻ y[i]
    end
    return diff == 0x00
end

"""
Return `(status, message)` when the server must refuse `request`, else `nothing`. A `Host`
that is not this server, or an `Origin` of a page on another host, gets 403. A missing or
wrong bearer token gets 401.
"""
function access_error(request, token::AbstractString, port::Integer)
    host = lowercase(something(request.host, ""))
    host in ("localhost:$port", "127.0.0.1:$port") ||
        return (403, "The Host header must be localhost:$port or 127.0.0.1:$port.")
    origin = lowercase(HTTP.header(request, "Origin"))
    isempty(origin) || occursin(LOCAL_ORIGIN, origin) ||
        return (403, "The server refuses requests from the origin $origin.")
    bearer = match(r"^Bearer (\S+)$", HTTP.header(request, "Authorization"))
    (bearer !== nothing && secure_equal(bearer[1], token)) ||
        return (401, "The request needs the header Authorization: Bearer <token>, with the token from the token file.")
    return nothing
end

"""
Return the client that the `Mcp-Session-Id` header of `request` names. When the header is
missing or no client has that id, return `(status, message)` for the answer.
"""
function request_client(state::AppState, request)
    id = HTTP.header(request, "Mcp-Session-Id")
    isempty(id) && return (400, "The request needs an Mcp-Session-Id header. Send initialize to get one.")
    client = lock(state.lock) do
        get(state.clients, id, nothing)
    end
    client === nothing && return (404, "Unknown Mcp-Session-Id. Send initialize to get a new one.")
    return client
end

"""
Parse `body` as one JSON-RPC message. Return a `JSONRPC.Request` for a request or a
notification, the `Dict` of a response, and `nothing` when `body` is not one message.
"""
function parse_message(body::AbstractString)
    message = try
        JSON.parse(body)
    catch
        return nothing
    end
    (message isa Dict && get(message, "jsonrpc", nothing) == "2.0") || return nothing
    # A response from the client has an id and no method.
    haskey(message, "method") || return (haskey(message, "id") ? message : nothing)
    method = message["method"]
    params = get(message, "params", nothing)
    id = get(message, "id", nothing)
    (method isa String && params isa Union{Nothing,Dict{String,Any},Vector{Any}} &&
     id isa Union{Nothing,String,Int}) || return nothing
    return JSONRPC.Request(method, params, id, nothing)
end

"""
Answer with `status`, and with the JSON text `body` when it is not empty.
"""
function respond(http::HTTP.Stream, status::Integer, body::AbstractString=""; headers=())
    HTTP.setstatus(http, status)
    for header in headers
        HTTP.setheader(http, header)
    end
    isempty(body) || HTTP.setheader(http, "Content-Type" => "application/json")
    HTTP.setheader(http, "Content-Length" => string(sizeof(body)))
    HTTP.startwrite(http)
    isempty(body) || write(http, body)
    return
end

"""
Answer with `status` and a JSON-RPC error that has `message`.
"""
respond_error(http::HTTP.Stream, status::Integer, message::AbstractString) =
    respond(http, status, JSON.json(Dict{String,Any}(
        "jsonrpc" => "2.0",
        "id" => nothing,
        "error" => Dict{String,Any}("code" => -32600, "message" => message),
    )))

function start_event_stream(http::HTTP.Stream)
    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => "text/event-stream")
    HTTP.setheader(http, "Cache-Control" => "no-cache")
    HTTP.startwrite(http)
    return
end

# Ask the writer of `outbox` for a keepalive comment.
function wake(outbox::Outbox)
    try
        put!(outbox, nothing)
    catch err
        err isa InvalidStateException || rethrow()
    end
    return
end

"""
Write each message from `outbox` to `io` as a server-sent event, until `outbox` closes.
When no message comes for `keepalive` seconds, write the comment `: keepalive`.
"""
function write_events(io::IO, outbox::Outbox; keepalive::Real=SSE_KEEPALIVE_SECS)
    while true
        timer = Timer(_ -> wake(outbox), keepalive)
        message = try
            take!(outbox)
        catch err
            err isa InvalidStateException || rethrow()
            return  # The outbox closed, and it has no message left.
        finally
            close(timer)
        end
        write(io, message === nothing ? ": keepalive\n\n" : "event: message\ndata: $message\n\n")
    end
end

function handle_http(state::AppState, inbox::Channel, token::AbstractString, port::Integer, http::HTTP.Stream)
    request = HTTP.startread(http)
    # Read the body first: when the server closes a connection with unread request bytes, the
    # client can get a reset in place of the answer.
    # ponytail: no size limit, so a local process without the token can make the server hold
    # a large body in memory. Add a limit (413) if that matters.
    body = read(http, String)
    # The path comes first: a client that looks for an OAuth endpoint gets 404, not 401.
    first(split(request.target, '?')) == MCP_PATH ||
        return respond_error(http, 404, "The MCP endpoint is $MCP_PATH.")
    refused = access_error(request, token, port)
    refused === nothing || return respond_error(http, refused...)
    request.method == "POST" && return handle_post(state, inbox, http, request, body)
    request.method == "GET" && return handle_get(state, http, request)
    request.method == "DELETE" && return handle_delete(state, http, request)
    return respond_error(http, 405, "The MCP endpoint takes POST, GET and DELETE.")
end

"""
Answer a POST with one JSON-RPC message. A `tools/call` gets an SSE stream: first the
notifications that the call causes, then the response. When a write to the stream fails,
the client closed the request, and the server cancels the test run of the call. Other
requests get the response as JSON. A notification, or a response from the client, gets 202
and no body.
"""
function handle_post(state::AppState, inbox::Channel, http::HTTP.Stream, request, body::String)
    msg = parse_message(body)
    msg === nothing && return respond_error(http, 400, "The body must be one JSON-RPC message.")
    initialize = msg isa JSONRPC.Request && msg.method == "initialize" && msg.id !== nothing
    client = initialize ? add_client!(state) : request_client(state, request)
    client isa Client || return respond_error(http, client...)
    # The server sends no requests, so a response from the client needs no work.
    msg isa JSONRPC.Request || return respond(http, 202)

    outbox = Outbox(Inf)
    pending = open_request!(state, client, msg)
    put!(inbox, (client, outbox, msg, pending))
    msg.id === nothing && return respond(http, 202)
    if msg.method == "tools/call"
        try
            start_event_stream(http)
            write_events(http, outbox; keepalive=TOOL_CALL_KEEPALIVE_SECS)
        catch
            mcp_info(state, "transport", "Client $(client.id) closed request $(msg.id) before the response")
            cancel_request!(state, pending)
            rethrow()
        finally
            # When the client went away, drop the messages that come later.
            close(outbox)
        end
        return
    end
    answer = nothing
    for message in outbox
        answer = message  # The response is the last message.
    end
    answer === nothing && return respond(http, 202)
    headers = initialize ? ("Mcp-Session-Id" => client.id,) : ()
    return respond(http, 200, answer; headers)
end

"""
Open the SSE stream of a client for the notifications that no request causes. A new GET
stream of the client replaces its old one.
"""
function handle_get(state::AppState, http::HTTP.Stream, request)
    client = request_client(state, request)
    client isa Client || return respond_error(http, client...)
    outbox = Outbox(Inf)
    previous = lock(state.lock) do
        old = client.outbox
        client.outbox = outbox
        old
    end
    previous isa Outbox && close(previous)
    start_event_stream(http)
    try
        write_events(http, outbox)
    finally
        lock(state.lock) do
            client.outbox === outbox && (client.outbox = nothing)
        end
        close(outbox)
    end
    return
end

"""
Remove the client, as [`remove_client!`](@ref) does. Its GET stream ends, its sessions
die, and its next request gets 404.
"""
function handle_delete(state::AppState, http::HTTP.Stream, request)
    client = request_client(state, request)
    client isa Client || return respond_error(http, client...)
    remove_client!(state, client.id)
    mcp_info(state, "transport", "Removed client $(client.id) on DELETE")
    return respond(http, 200)
end

"""
Serve MCP Streamable HTTP on `127.0.0.1:port`, with `token` as the bearer token. Port 0
takes a free port, and `HTTP.port(server)` tells which one.

Return `(; state, server, task)`. The task handles the MCP messages, and it ends after the
server closes. To stop, call [`stop_http_server`](@ref).
"""
function start_http_server(token::AbstractString; port::Integer)
    idle_timeout = idle_timeout_secs()
    state = AppState()
    inbox = Channel{Tuple{Client,Outbox,JSONRPC.Request,Union{Nothing,OpenRequest}}}(Inf)
    bound_port = Ref(Int(port))
    server = try
        HTTP.listen!("127.0.0.1", port) do http
            try
                handle_http(state, inbox, token, bound_port[], http)
            catch err
                # Most failures are clients that went away. HTTP.jl answers 500 when it can.
                @debug "HTTP request failed" exception = (err, catch_backtrace())
                rethrow()
            end
        end
    catch err
        cause = err isa TaskFailedException ? err.task.exception : err
        error("JuliaMCP cannot listen on 127.0.0.1:$port ($(sprint(showerror, cause))). " *
              "Another process can use port $port. Set a different port with --port or JULIAMCP_PORT.")
    end
    bound_port[] = HTTP.port(server)
    task = @async serve_http(state, server, inbox, start_reaper(state, idle_timeout; clients=true))
    return (; state, server, task)
end

"""
Close all connections of the server from [`start_http_server`](@ref). Then wait until its
workspaces are closed and its sessions are killed.
"""
function stop_http_server(http)
    HTTP.forceclose(http.server)
    wait(http.task)
    return
end

"""
Handle each MCP message from `inbox` in its own task, until `server` closes. All the tasks
run on the thread of this loop, as over stdio.
"""
function serve_http(state::AppState, server::HTTP.Server, inbox::Channel, reaper)
    @async try
        wait(server)
    finally
        close(inbox)
    end
    try
        for (client, outbox, msg, request) in inbox
            @async try
                handle_message(state, client, outbox, msg; request)
            finally
                # This ends the HTTP response.
                close(outbox)
            end
        end
    finally
        shutdown_server!(state, reaper)
    end
end

"""
Serve MCP Streamable HTTP on `127.0.0.1:port` until the process stops. Read the bearer
token from `token_file`, or write a new token there.
"""
function run_http_server(; port::Integer, token_file::AbstractString)
    token = read_or_create_token(token_file)
    http = start_http_server(token; port)
    @info "JuliaMCP serves MCP at http://127.0.0.1:$(HTTP.port(http.server))$MCP_PATH. The bearer token is in $token_file."
    wait(http.task)
end
