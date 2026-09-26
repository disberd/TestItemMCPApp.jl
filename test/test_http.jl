@testmodule HTTPTestHelpers begin

using JuliaMCP
using JuliaMCP: HTTP, JSON

const TESTDATA_DIR = joinpath(dirname(@__DIR__), "testdata")

"""
Run `f(server)` against a live HTTP server on a free port, with its token file in a new
temporary directory.
"""
function with_http_server(f)
    token_file = joinpath(mktempdir(), "juliamcp", "token")
    token = JuliaMCP.read_or_create_token(token_file)
    http = JuliaMCP.start_http_server(token; port=0)
    port = HTTP.port(http.server)
    try
        f((; http.state, port, token, url="http://127.0.0.1:$port/mcp"))
    finally
        JuliaMCP.stop_http_server(http)
    end
end

function headers(server; session=nothing, token=server.token, extra=())
    result = Pair{String,String}[
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream",
    ]
    token === nothing || push!(result, "Authorization" => "Bearer $token")
    session === nothing || push!(result, "Mcp-Session-Id" => session)
    append!(result, extra)
    return result
end

"""
Send `message` as one POST and return the HTTP response.
"""
post(server, message; kwargs...) =
    HTTP.request("POST", server.url, headers(server; kwargs...), JSON.json(message); status_exception=false)

request(id, method, params=Dict{String,Any}()) =
    Dict{String,Any}("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)

function tool_call(id, name, arguments=Dict{String,Any}(); progress_token=nothing)
    params = Dict{String,Any}("name" => name, "arguments" => arguments)
    progress_token === nothing || (params["_meta"] = Dict{String,Any}("progressToken" => progress_token))
    return request(id, "tools/call", params)
end

"""
Send `initialize` and `notifications/initialized`. Return the `Mcp-Session-Id`.
"""
function initialize(server)
    response = post(server, request(1, "initialize", Dict{String,Any}(
        "protocolVersion" => JuliaMCP.MCP_PROTOCOL_VERSION,
        "capabilities" => Dict{String,Any}(),
        "clientInfo" => Dict{String,Any}("name" => "HTTPTestHelpers", "version" => "0.0.1"),
    )))
    response.status == 200 || error("initialize failed with status $(response.status)")
    session = HTTP.header(response, "Mcp-Session-Id")
    post(server, Dict{String,Any}("jsonrpc" => "2.0", "method" => "notifications/initialized"); session)
    return session
end

body(response) = String(copy(response.body))

"""
Return the JSON-RPC messages in the SSE text `text`.
"""
events(text) = [JSON.parse(line[7:end]) for line in split(text, '\n') if startswith(line, "data: ")]

"""
Return the JSON value in the text content of the tool result of the SSE response.
"""
tool_json(response) = JSON.parse(only(last(events(body(response)))["result"]["content"])["text"])

function wait_until(f, timeout; interval=0.05)
    deadline = time() + timeout
    while time() < deadline
        f() && return true
        sleep(interval)
    end
    return f()
end

"""
Open the GET stream of `session`. Return a `Channel` that gets each JSON-RPC message on
the stream.
"""
function open_stream(server, session)
    messages = Channel{Any}(Inf)
    @async HTTP.request("GET", server.url, headers(server; session);
        status_exception=false, sse_callback=event -> put!(messages, JSON.parse(event.data)))
    # The server attaches the stream to the client before it sends the headers.
    attached() = lock(server.state.lock) do
        server.state.clients[session].outbox !== nothing
    end
    wait_until(attached, 30) || error("The GET stream of $session did not open.")
    return messages
end

function drain(messages::Channel)
    result = Any[]
    while isready(messages)
        push!(result, take!(messages))
    end
    return result
end

end

@testitem "initialize gives each client its own Mcp-Session-Id" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server, post, request, initialize, body, HTTP, JSON

    with_http_server() do server
        response = post(server, request(1, "initialize", Dict{String,Any}(
            "protocolVersion" => JuliaMCP.MCP_PROTOCOL_VERSION,
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict{String,Any}("name" => "test", "version" => "0"),
        )))
        @test response.status == 200
        @test startswith(HTTP.header(response, "Content-Type"), "application/json")
        answer = JSON.parse(body(response))
        @test answer["id"] == 1
        @test answer["result"]["serverInfo"]["name"] == "JuliaMCP"
        first_id = HTTP.header(response, "Mcp-Session-Id")
        @test !isempty(first_id)

        second_id = initialize(server)
        @test !isempty(second_id)
        @test second_id != first_id
    end
end

@testitem "HTTP requests need the token, a local origin and a known Mcp-Session-Id" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server, post, request, initialize

    with_http_server() do server
        session = initialize(server)
        list = request(2, "tools/list")

        @test post(server, list; session).status == 200
        @test post(server, list; session, token=nothing).status == 401
        @test post(server, list; session, token="0"^64).status == 401
        @test post(server, list; session, extra=["Origin" => "http://evil.example"]).status == 403
        @test post(server, list; session, extra=["Host" => "evil.example:$(server.port)"]).status == 403
        @test post(server, list; session, extra=["Origin" => "http://localhost:3000"]).status == 200
        @test post(server, list).status == 400
        @test post(server, list; session="no-such-session").status == 404
    end
end

@testitem "a tools/call answer is an SSE stream with only its own progress" setup=[HTTPTestHelpers] tags=[:e2e] begin
    using .HTTPTestHelpers: with_http_server, post, tool_call, initialize, open_stream, drain, events, body,
        wait_until, TESTDATA_DIR, HTTP

    with_http_server() do server
        a = initialize(server)
        b = initialize(server)
        a_stream = open_stream(server, a)
        b_stream = open_stream(server, b)
        pkg = joinpath(TESTDATA_DIR, "BasicPkg")
        setup = post(server, tool_call(2, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false)); session=a)
        @test setup.status == 200
        # The workspace setup sends list_changed on both GET streams. Wait for it on each.
        @test wait_until(() -> any(m -> m["method"] == "notifications/resources/list_changed", drain(a_stream)), 30)
        @test wait_until(() -> any(m -> m["method"] == "notifications/resources/list_changed", drain(b_stream)), 30)

        response = post(server, tool_call(3, "julia_run_testitems"; progress_token="tok-a"); session=a)
        @test response.status == 200
        @test startswith(HTTP.header(response, "Content-Type"), "text/event-stream")
        messages = events(body(response))
        answer = last(messages)
        @test answer["id"] == 3
        @test haskey(answer, "result")
        progress = messages[1:end-1]
        @test !isempty(progress)
        @test all(m -> m["method"] == "notifications/progress", progress)
        @test all(m -> m["params"]["progressToken"] == "tok-a", progress)

        # The GET streams carry notifications that no request caused, and no progress.
        sleep(1)
        for stream in (a_stream, b_stream)
            @test !any(m -> m["method"] == "notifications/progress", drain(stream))
        end
    end
end

@testitem "a resource subscription notifies only the client that made it" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server, post, request, tool_call, initialize, open_stream, drain,
        wait_until, TESTDATA_DIR

    with_http_server() do server
        a = initialize(server)
        b = initialize(server)
        a_stream = open_stream(server, a)
        b_stream = open_stream(server, b)
        pkg = joinpath(TESTDATA_DIR, "BasicPkg")
        uri = "workspace://$(JuliaMCP.workspace_id([pkg]))/testitems"
        @test post(server, request(2, "resources/subscribe", Dict{String,Any}("uri" => uri)); session=a).status == 200

        post(server, tool_call(3, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false)); session=b)

        updated(m) = m["method"] == "notifications/resources/updated" && m["params"]["uri"] == uri
        listed(m) = m["method"] == "notifications/resources/list_changed"
        a_seen = Any[]
        @test wait_until(() -> any(updated, append!(a_seen, drain(a_stream))), 30)
        @test any(listed, a_seen)
        b_seen = Any[]
        @test wait_until(() -> any(listed, append!(b_seen, drain(b_stream))), 30)
        sleep(1)
        append!(b_seen, drain(b_stream))
        @test !any(updated, b_seen)
    end
end

@testitem "DELETE ends one client and leaves the others" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server, post, request, initialize, headers, HTTP

    with_http_server() do server
        a = initialize(server)
        b = initialize(server)
        delete(session) = HTTP.request("DELETE", server.url, headers(server; session); status_exception=false)

        @test delete(a).status == 200
        @test !haskey(server.state.clients, a)
        @test post(server, request(2, "tools/list"); session=a).status == 404
        @test delete(a).status == 404
        @test post(server, request(2, "tools/list"); session=b).status == 200
    end
end

@testitem "a long tools/call does not delay other requests" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server, post, request, tool_call, initialize, tool_json, events, body,
        wait_until

    with_http_server() do server
        a = initialize(server)
        b = initialize(server)
        session_id = tool_json(post(server, tool_call(2, "julia_create_session"); session=a))["session_id"]
        long = @async post(server, tool_call(3, "julia_eval_code", Dict{String,Any}(
            "session_id" => session_id, "code" => "sleep(600)", "revise" => false)); session=a)
        busy() = any(JuliaMCP.JSC.list_sessions(server.state.session_controller)) do info
            info.id == session_id && info.current_request !== nothing
        end
        @test wait_until(busy, 60)

        for session in (a, b)
            elapsed = @elapsed response = post(server, request(4, "tools/list"); session)
            @test response.status == 200
            @test elapsed < 5
        end
        @test !istaskdone(long)

        post(server, tool_call(5, "julia_kill_session", Dict{String,Any}("session_id" => session_id)); session=b)
        @test last(events(body(fetch(long))))["id"] == 3
    end
end

@testitem "the token file is created with private modes" setup=[HTTPTestHelpers] begin
    dir = joinpath(mktempdir(), "juliamcp")
    path = joinpath(dir, "token")
    token = JuliaMCP.read_or_create_token(path)
    @test occursin(r"^[0-9a-f]{64}$", token)
    @test JuliaMCP.read_or_create_token(path) == token
    if !Sys.iswindows()
        @test filemode(dir) & 0o777 == 0o700
        @test filemode(path) & 0o777 == 0o600
    end
end

@testitem "a busy port fails with an error that names the port and how to change it" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server

    with_http_server() do server
        err = try
            JuliaMCP.start_http_server(server.token; port=server.port)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin(string(server.port), err.msg)
        @test occursin("--port", err.msg)
        @test occursin("JULIAMCP_PORT", err.msg)
    end
end

@testitem "the port and the token file come from options, then the environment, then defaults" begin
    withenv("JULIAMCP_PORT" => nothing, "JULIAMCP_TOKEN_FILE" => nothing) do
        @test JuliaMCP.http_port() == 50020
        @test JuliaMCP.token_file_path() == joinpath(first(DEPOT_PATH), "juliamcp", "token")
    end
    withenv("JULIAMCP_PORT" => "50123", "JULIAMCP_TOKEN_FILE" => "/tmp/env-token") do
        @test JuliaMCP.http_port() == 50123
        @test JuliaMCP.http_port(50124) == 50124
        @test JuliaMCP.token_file_path() == "/tmp/env-token"
        @test JuliaMCP.token_file_path("/tmp/option-token") == "/tmp/option-token"
    end
    withenv("JULIAMCP_PORT" => "http") do
        @test_throws "JULIAMCP_PORT must be a port number" JuliaMCP.http_port()
    end

    options = JuliaMCP.parse_command_line(["--http", "--port", "50125", "--token-file", "/tmp/t"])
    @test options == (; http=true, port=50125, token_file="/tmp/t")
    @test JuliaMCP.parse_command_line(String[]) == (; http=false, port=nothing, token_file=nothing)
    @test_throws "need --http" JuliaMCP.parse_command_line(["--port", "50125"])
    @test_throws "Unknown argument" JuliaMCP.parse_command_line(["--verbose"])
end

@testitem "an SSE stream writes a keepalive comment after a silence" begin
    outbox = JuliaMCP.Outbox(Inf)
    io = IOBuffer()
    writer = @async JuliaMCP.write_events(io, outbox; keepalive=0.2)
    sleep(0.7)
    put!(outbox, "{\"jsonrpc\":\"2.0\"}")
    close(outbox)
    wait(writer)
    text = String(take!(io))
    @test startswith(text, ": keepalive\n\n")
    @test endswith(text, "event: message\ndata: {\"jsonrpc\":\"2.0\"}\n\n")
end
