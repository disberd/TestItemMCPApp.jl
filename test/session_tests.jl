@testitem "set_workspace_folders returns session_id" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    result, _ = mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    @test occursin("session=", result)

    close(ep); close(client_socket); close(server_socket)
end

@testitem "single session auto-resolves without session_id" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    items, _ = mcp_call_tool(ep, "list_testitems", Dict{String,Any}())
    @test items isa AbstractVector
    @test length(items) > 0

    close(ep); close(client_socket); close(server_socket)
end

@testitem "explicit session_id creates named session" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    result, _ = mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
        "folders" => [FIXTURE_PKG_PATH],
        "session_id" => "my-session",
    ))
    @test occursin("session=my-session", result)

    # Can query with explicit session_id
    items, _ = mcp_call_tool(ep, "list_testitems", Dict{String,Any}("session_id" => "my-session"))
    @test length(items) > 0

    close(ep); close(client_socket); close(server_socket)
end

@testitem "multiple sessions require session_id" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
        "folders" => [FIXTURE_PKG_PATH],
        "session_id" => "session-a",
    ))
    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
        "folders" => [FIXTURE_PKG_PATH],
        "session_id" => "session-b",
    ))

    # Without session_id, resolve_session errors inside the tool handler.
    # dispatch_mcp_message catches this and returns it as a tool result with
    # isError=true rather than a JSON-RPC error response.
    result, raw = mcp_call_tool(ep, "list_testitems", Dict{String,Any}())
    @test get(raw, "isError", false) == true
    @test occursin("Multiple sessions", raw["content"][1]["text"])

    # With session_id, should work
    items_a, _ = mcp_call_tool(ep, "list_testitems", Dict{String,Any}("session_id" => "session-a"))
    @test items_a isa AbstractVector

    close(ep); close(client_socket); close(server_socket)
end

@testitem "sessions have isolated test runs" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
        "folders" => [FIXTURE_PKG_PATH],
        "session_id" => "session-a",
    ))
    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
        "folders" => [FIXTURE_PKG_PATH],
        "session_id" => "session-b",
    ))

    # Run tests in session-a only
    result_a, _ = mcp_call_tool(ep, "run_testitems", Dict{String,Any}(
        "session_id" => "session-a",
        "name_pattern" => "pass_test",
    ))
    @test result_a["summary"]["passed"] == 1

    # Session-b should have no runs
    runs_b, _ = mcp_call_tool(ep, "list_testruns", Dict{String,Any}("session_id" => "session-b"))
    @test isempty(runs_b)

    # Session-a should have one run
    runs_a, _ = mcp_call_tool(ep, "list_testruns", Dict{String,Any}("session_id" => "session-a"))
    @test length(runs_a) == 1

    close(ep); close(client_socket); close(server_socket)
end

@testitem "session_id appears in tool schemas" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    tools = mcp_list_tools(ep)
    for tool in tools
        props = tool["inputSchema"]["properties"]
        @test haskey(props, "session_id")
    end

    close(ep); close(client_socket); close(server_socket)
end
