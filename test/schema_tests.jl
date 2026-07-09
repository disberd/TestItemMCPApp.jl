@testitem "run_testitems mode enum uses Normal not Run" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    tools = mcp_list_tools(ep)
    run_tool = only(t for t in tools if t["name"] == "run_testitems")
    mode_prop = run_tool["inputSchema"]["properties"]["mode"]
    @test mode_prop["enum"] == ["Normal", "Coverage"]

    close(ep); close(client_socket); close(server_socket)
end

@testitem "rerun_failed schema includes julia_num_threads and mode" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    tools = mcp_list_tools(ep)
    rerun_tool = only(t for t in tools if t["name"] == "rerun_failed")
    props = rerun_tool["inputSchema"]["properties"]
    @test haskey(props, "julia_num_threads")
    @test haskey(props, "mode")
    @test props["mode"]["enum"] == ["Normal", "Coverage"]

    close(ep); close(client_socket); close(server_socket)
end

@testitem "run_testitems schema has julia_env and log_level" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    tools = mcp_list_tools(ep)
    run_tool = only(t for t in tools if t["name"] == "run_testitems")
    props = run_tool["inputSchema"]["properties"]
    @test haskey(props, "julia_env")
    @test haskey(props, "log_level")
    @test props["log_level"]["enum"] == ["Debug", "Info", "Warn", "Error"]

    close(ep); close(client_socket); close(server_socket)
end

@testitem "get_process_output and terminate_all_processes tools exist" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    tools = mcp_list_tools(ep)
    tool_names = Set(t["name"] for t in tools)
    @test "get_process_output" in tool_names
    @test "terminate_all_processes" in tool_names

    close(ep); close(client_socket); close(server_socket)
end

@testitem "rerun_failed schema has julia_env and log_level" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    tools = mcp_list_tools(ep)
    rerun_tool = only(t for t in tools if t["name"] == "rerun_failed")
    props = rerun_tool["inputSchema"]["properties"]
    @test haskey(props, "julia_env")
    @test haskey(props, "log_level")

    close(ep); close(client_socket); close(server_socket)
end
