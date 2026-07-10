@testitem "close_session removes session and terminates controller" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
        "folders" => [FIXTURE_PKG_PATH],
        "session_id" => "close-test",
    ))

    # Session exists
    items, _ = mcp_call_tool(ep, "list_testitems", Dict{String,Any}("session_id" => "close-test"))
    @test items isa AbstractVector

    # Close it
    result, _ = mcp_call_tool(ep, "close_session", Dict{String,Any}("session_id" => "close-test"))
    @test occursin("closed", result)

    # Session is gone
    _, raw = mcp_call_tool(ep, "list_testitems", Dict{String,Any}("session_id" => "close-test"))
    @test get(raw, "isError", false) == true
    @test occursin("Unknown session", raw["content"][1]["text"])

    close(ep); close(client_socket); close(server_socket)
end

@testitem "close_session auto-resolves single session" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))

    # Close without session_id — auto-resolves the single session
    result, _ = mcp_call_tool(ep, "close_session", Dict{String,Any}())
    @test occursin("closed", result)

    # No sessions remain
    _, raw = mcp_call_tool(ep, "list_testitems", Dict{String,Any}())
    @test get(raw, "isError", false) == true
    @test occursin("No workspace configured", raw["content"][1]["text"])

    close(ep); close(client_socket); close(server_socket)
end

@testitem "close_session errors when ambiguous" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
        "folders" => [FIXTURE_PKG_PATH], "session_id" => "s1"))
    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
        "folders" => [FIXTURE_PKG_PATH], "session_id" => "s2"))

    # Without session_id, should error (multiple sessions)
    _, raw = mcp_call_tool(ep, "close_session", Dict{String,Any}())
    @test get(raw, "isError", false) == true
    @test occursin("Multiple sessions", raw["content"][1]["text"])

    close(ep); close(client_socket); close(server_socket)
end

@testitem "close_session tool appears in tools/list" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    tools = mcp_list_tools(ep)
    tool_names = Set(t["name"] for t in tools)
    @test "close_session" in tool_names

    # Verify schema
    close_tool = only(t for t in tools if t["name"] == "close_session")
    @test haskey(close_tool["inputSchema"]["properties"], "session_id")

    close(ep); close(client_socket); close(server_socket)
end
