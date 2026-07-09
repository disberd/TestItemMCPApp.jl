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

@testitem "julia_env passes environment variables to test process" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    result, _ = mcp_call_tool(ep, "run_testitems", Dict{String,Any}(
        "name_pattern" => "env_var_test",
        "julia_env" => Dict{String,Any}("MY_TEST_VAR" => "hello"),
    ))
    @test result["summary"]["passed"] == 1
    @test result["summary"]["failed"] == 0

    close(ep); close(client_socket); close(server_socket)
end

@testitem "get_process_output returns captured output" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    mcp_call_tool(ep, "run_testitems", Dict{String,Any}("name_pattern" => "pass_test"))

    procs, _ = mcp_call_tool(ep, "list_test_processes", Dict{String,Any}())
    @test length(procs) >= 1

    output, _ = mcp_call_tool(ep, "get_process_output", Dict{String,Any}(
        "process_id" => procs[1]["id"],
    ))
    @test output isa AbstractString || output isa AbstractVector

    close(ep); close(client_socket); close(server_socket)
end

@testitem "terminate_all_processes kills all workers" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    mcp_call_tool(ep, "run_testitems", Dict{String,Any}("name_pattern" => "pass_test"))

    procs_before, _ = mcp_call_tool(ep, "list_test_processes", Dict{String,Any}())
    @test length(procs_before) >= 1

    result, _ = mcp_call_tool(ep, "terminate_all_processes", Dict{String,Any}())
    @test result isa AbstractString  # "Terminated N process(es)."

    # Give processes time to die
    sleep(1)

    procs_after, _ = mcp_call_tool(ep, "list_test_processes", Dict{String,Any}())
    @test length(procs_after) == 0

    close(ep); close(client_socket); close(server_socket)
end

@testitem "run_testitems with log_level=Debug succeeds" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [FIXTURE_PKG_PATH]))
    result, _ = mcp_call_tool(ep, "run_testitems", Dict{String,Any}(
        "name_pattern" => "pass_test",
        "log_level" => "Debug",
    ))
    @test result["summary"]["passed"] == 1

    close(ep); close(client_socket); close(server_socket)
end
