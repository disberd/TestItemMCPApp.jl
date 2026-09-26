# mcp_server.jl — MCP server main loop

function run_server(input::IO, output::IO)
    endpoint = JSONRPC.JSONRPCEndpoint(input, output; framing=JSONRPC.NewlineDelimitedFraming())
    state = AppState()
    # Over stdio the server has one client, and the endpoint takes all of its messages.
    client = add_client!(state, endpoint)
    idle_timeout = idle_timeout_secs()

    JSONRPC.start(endpoint)
    reaper = start_reaper(state, idle_timeout)

    mcp_debug(state, "transport", "MCP server started, waiting for initialize request")

    try
        serve_loop(state, client, endpoint)
    catch e
        if e isa JSONRPC.TransportError || e isa Base.IOError || e isa InvalidStateException
            mcp_debug(state, "transport", "Connection closed")
        else
            @error "Server error" exception = (e, catch_backtrace())
        end
    finally
        shutdown_server!(state, reaper)
        try
            close(endpoint)
        catch
        end
    end
end

"""
Stop the `reaper` from [`start_reaper`](@ref), close all workspaces and kill all sessions.
"""
function shutdown_server!(state::AppState, reaper)
    # Stop the reaper and let a running sweep end first. A sweep must not use the
    # session controller while the controller shuts down.
    if reaper !== nothing
        close(reaper.timer)
        wait(reaper.task)
    end
    ids = lock(state.lock) do
        collect(keys(state.workspaces))
    end
    foreach(id -> close_workspace!(state, id; force=true), ids)
    shutdown_sessions!(state)
end

function serve_loop(state::AppState, client::Client, endpoint::JSONRPC.JSONRPCEndpoint)
    while true
        msg = JSONRPC.get_next_message(endpoint)
        @async handle_message(state, client, endpoint, msg)
    end
end

"""
Handle `msg` from `client`. Send the response to `sink`, together with the notifications
that the request causes, such as its progress.
"""
function handle_message(state::AppState, client::Client, sink, msg::JSONRPC.Request)
    try
        dispatch_mcp_message(state, client, sink, msg)
    catch e
        report_handler_error(state, sink, msg, e, catch_backtrace())
    end
    return
end

"""
Report a failed request to the client. A `ResourceNotFound` is the client naming something
that does not exist, so it gets the spec's -32002 and no stack trace; anything else is a
genuine server fault and is logged as one.
"""
function report_handler_error(state::AppState, sink, msg::JSONRPC.Request, e, backtrace)
    resource_missing = e isa ResourceNotFound
    if msg.id !== nothing
        code, message, data = resource_missing ?
            (MCP_ERROR_RESOURCE_NOT_FOUND, e.message, Dict{String,Any}("uri" => e.uri)) :
            (MCP_ERROR_INTERNAL, "Internal error: $(sprint(showerror, e))", nothing)
        try
            send_error(sink, msg, code, message, data)
        catch
        end
    end

    if resource_missing
        mcp_debug(state, "resources", e.message)
    else
        @error "Handler error" method = msg.method exception = (e, backtrace)
    end
    return
end

function dispatch_mcp_message(state::AppState, client::Client, sink, msg::JSONRPC.Request)
    method = msg.method
    params = msg.params === nothing ? Dict{String,Any}() : msg.params

    # --- Lifecycle ---
    if method == "initialize"
        result = handle_initialize(state, params)
        send_result(sink, msg, result)
        return
    end

    if method == "notifications/initialized"
        # Client acknowledged initialization — nothing to do
        return
    end

    if method == "ping"
        send_result(sink, msg, Dict{String,Any}())
        return
    end

    # --- Tools ---
    if method == "tools/list"
        result = Dict{String,Any}("tools" => tool_definitions())
        send_result(sink, msg, result)
        return
    end

    if method == "tools/call"
        tool_name = params["name"]::String
        arguments = get(params, "arguments", Dict{String,Any}())
        if arguments isa Dict
            arguments = convert(Dict{String,Any}, arguments)
        else
            arguments = Dict{String,Any}()
        end
        result = handle_tool_call(state, tool_name, arguments;
            progress_token=progress_token_of(params), progress_sink=sink)
        send_result(sink, msg, result)
        return
    end

    # --- Resources ---
    if method == "resources/list"
        result = handle_resources_list(state, params)
        send_result(sink, msg, result)
        return
    end

    if method == "resources/templates/list"
        result = handle_resource_templates_list(state, params)
        send_result(sink, msg, result)
        return
    end

    if method == "resources/read"
        result = handle_resources_read(state, params)
        send_result(sink, msg, result)
        return
    end

    if method == "resources/subscribe"
        result = handle_resources_subscribe(state, client, params)
        send_result(sink, msg, result)
        return
    end

    if method == "resources/unsubscribe"
        result = handle_resources_unsubscribe(state, client, params)
        send_result(sink, msg, result)
        return
    end

    # --- Unknown method ---
    if msg.id !== nothing
        send_error(sink, msg, -32601, "Method not found: $method", nothing)
    end
end

"""
The client opts into progress reporting by putting a `progressToken` in the request's
`_meta`. Per spec it is a string or an integer; anything else is ignored.
"""
function progress_token_of(params)
    meta = get(params, "_meta", nothing)
    meta isa Dict || return nothing
    token = get(meta, "progressToken", nothing)
    return token isa String || token isa Integer ? token : nothing
end
