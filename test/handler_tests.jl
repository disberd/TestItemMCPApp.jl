@testitem "run_testitems response uses duration_ms key" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    result, _ = mcp_call_tool(ep, "run_testitems", Dict{String,Any}("name_pattern" => "pass_test"))

    summary = result["summary"]
    @test haskey(summary, "duration_ms")
    @test !haskey(summary, "duration")
    @test summary["passed"] == 1

    close(ep); close(client_socket); close(server_socket)
end

@testitem "get_testrun_results items use duration_ms" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    run_result, _ = mcp_call_tool(ep, "run_testitems", Dict{String,Any}("name_pattern" => "pass_test"))
    testrun_id = run_result["summary"]["testrun_id"]

    detail, _ = mcp_call_tool(ep, "get_testrun_results", Dict{String,Any}(
        "testrun_id" => testrun_id,
        "include_passing" => true,
    ))
    item = detail["items"][1]
    @test haskey(item, "duration_ms")
    @test !haskey(item, "duration")

    close(ep); close(client_socket); close(server_socket)
end
