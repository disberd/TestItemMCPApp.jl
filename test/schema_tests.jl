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
