@testitem "MCP server starts and responds to initialize" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    server_task = start_mcp_server(server_socket)

    client_endpoint = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(client_endpoint)

    result = mcp_initialize!(client_endpoint)
    @test haskey(result, "protocolVersion")
    @test haskey(result, "capabilities")

    close(client_endpoint)
    close(client_socket)
    close(server_socket)
end

@testitem "tools/list returns tool definitions" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    server_task = start_mcp_server(server_socket)

    client_endpoint = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(client_endpoint)
    mcp_initialize!(client_endpoint)

    tools = mcp_list_tools(client_endpoint)
    tool_names = Set(t["name"] for t in tools)
    @test "set_workspace_folders" in tool_names
    @test "run_testitems" in tool_names
    @test "list_testitems" in tool_names

    close(client_endpoint)
    close(client_socket)
    close(server_socket)
end
