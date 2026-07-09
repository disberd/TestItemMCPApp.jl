@testmodule MCPTestHelpers begin
    using Sockets, JSONRPC, JSON
    import TestItemMCPApp

    # `setup=[MCPTestHelpers]` only brings exported names into a testitem's scope,
    # not the modules this testmodule itself imported. Re-export JSONRPC and JSON
    # so testitems can call e.g. `JSONRPC.JSONRPCEndpoint(...)` without a separate import.
    export get_named_pipe, start_mcp_server, mcp_initialize!, mcp_call_tool, mcp_list_tools,
        JSONRPC, JSON, FIXTURE_PKG_PATH

    const FIXTURE_PKG_PATH = joinpath(@__DIR__, "fixtures", "FakeTestPkg")

    function get_named_pipe()
        socket_name = JSONRPC.generate_pipe_name()
        server_is_up = Channel(1)
        socket1_channel = Channel(1)
        @async try
            server = listen(socket_name)
            put!(server_is_up, true)
            socket1 = accept(server)
            put!(socket1_channel, socket1)
        catch err
            Base.display_error(err, catch_backtrace())
        end
        wait(server_is_up)
        socket2 = connect(socket_name)
        socket1 = take!(socket1_channel)
        return socket1, socket2
    end

    function start_mcp_server(server_socket)
        task = @async TestItemMCPApp.run_server(server_socket, server_socket)
        return task
    end

    function mcp_initialize!(endpoint::JSONRPC.JSONRPCEndpoint)
        result = JSONRPC.send_request(endpoint, "initialize", Dict{String,Any}(
            "protocolVersion" => "2025-03-26",
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict{String,Any}("name" => "test-client", "version" => "0.1.0"),
        ))
        JSONRPC.send_notification(endpoint, "notifications/initialized", nothing)
        return result
    end

    function mcp_call_tool(endpoint::JSONRPC.JSONRPCEndpoint, tool_name::String, arguments::Dict{String,Any}=Dict{String,Any}())
        result = JSONRPC.send_request(endpoint, "tools/call", Dict{String,Any}(
            "name" => tool_name,
            "arguments" => arguments,
        ))
        content = result["content"]
        text = content[1]["text"]
        parsed = try
            JSON.parse(text)
        catch
            text
        end
        return parsed, result
    end

    function mcp_list_tools(endpoint::JSONRPC.JSONRPCEndpoint)
        result = JSONRPC.send_request(endpoint, "tools/list", Dict{String,Any}())
        return result["tools"]
    end
end
