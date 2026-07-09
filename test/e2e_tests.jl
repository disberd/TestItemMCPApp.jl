@testitem "rerun_failed preserves julia_num_threads from original run" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))

    # Run with julia_num_threads set — fail_test will fail
    result, _ = mcp_call_tool(ep, "run_testitems", Dict{String,Any}(
        "name_pattern" => "fail_test",
        "julia_num_threads" => "2",
    ))
    testrun_id = result["summary"]["testrun_id"]
    @test result["summary"]["failed"] == 1

    # Rerun failed without specifying julia_num_threads — should inherit "2"
    rerun_result, _ = mcp_call_tool(ep, "rerun_failed", Dict{String,Any}(
        "testrun_id" => testrun_id,
    ))
    # The rerun should still fail (same test) but complete without error
    @test rerun_result["summary"]["failed"] == 1

    close(ep); close(client_socket); close(server_socket)
end

@testitem "run_testitems with mode=Normal succeeds" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    result, _ = mcp_call_tool(ep, "run_testitems", Dict{String,Any}(
        "name_pattern" => "pass_test",
        "mode" => "Normal",
    ))
    @test result["summary"]["passed"] == 1

    close(ep); close(client_socket); close(server_socket)
end
