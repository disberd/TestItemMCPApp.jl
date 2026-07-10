@testitem "idle session reaper removes stale sessions" setup=[MCPTestHelpers] begin
    using Test

    withenv("JULIATIMCP_IDLE_TIMEOUT_SECS" => "5") do
        server_socket, client_socket = get_named_pipe()
        start_mcp_server(server_socket)
        ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
        JSONRPC.start(ep)
        mcp_initialize!(ep)

        mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
            "folders" => [FIXTURE_PKG_PATH],
            "session_id" => "reaper-test",
        ))

        # Confirm session exists
        items, _ = mcp_call_tool(ep, "list_testitems", Dict{String,Any}("session_id" => "reaper-test"))
        @test items isa AbstractVector

        # Wait for idle timeout + reaper sweep (timeout=5, interval=max(1,5÷4)=1)
        sleep(8)

        # Session should be gone — querying it should error
        _, raw = mcp_call_tool(ep, "list_testitems", Dict{String,Any}("session_id" => "reaper-test"))
        @test get(raw, "isError", false) == true
        @test occursin("Unknown session", raw["content"][1]["text"])

        close(ep); close(client_socket); close(server_socket)
    end
end

@testitem "active session is not reaped" setup=[MCPTestHelpers] begin
    using Test

    withenv("JULIATIMCP_IDLE_TIMEOUT_SECS" => "3") do
        server_socket, client_socket = get_named_pipe()
        start_mcp_server(server_socket)
        ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
        JSONRPC.start(ep)
        mcp_initialize!(ep)

        mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}(
            "folders" => [FIXTURE_PKG_PATH],
            "session_id" => "active-test",
        ))

        # Keep the session alive by calling a tool every second for 5 seconds
        for _ in 1:5
            sleep(1)
            items, _ = mcp_call_tool(ep, "list_testitems", Dict{String,Any}("session_id" => "active-test"))
            @test items isa AbstractVector
        end

        # Session should still be alive after 5s even though timeout is 3s
        items, _ = mcp_call_tool(ep, "list_testitems", Dict{String,Any}("session_id" => "active-test"))
        @test items isa AbstractVector
        @test length(items) > 0

        close(ep); close(client_socket); close(server_socket)
    end
end
