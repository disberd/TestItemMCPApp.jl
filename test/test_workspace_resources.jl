@testitem "resources/list shows one set of resources per workspace" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        ids = [
            MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
                Dict{String,Any}("folders" => [joinpath(MCPTestHelpers.TESTDATA_DIR, name)], "watch" => false)))
            for name in ("BasicPkg", "LintPkg")
        ]
        uris = [r["uri"] for r in MCPTestHelpers.request(client, "resources/list", Dict{String,Any}())["resources"]]

        for id in ids, kind in ("testitems", "detection-errors", "diagnostics")
            @test count(==("workspace://$id/$kind"), uris) == 1
        end
        @test count(startswith("workspace://"), uris) == 6

        templates = [t["uriTemplate"] for t in
            MCPTestHelpers.request(client, "resources/templates/list", Dict{String,Any}())["resourceTemplates"]]
        @test "workspace://{workspace_id}/testitems" in templates
        @test "workspace://{workspace_id}/detection-errors" in templates
        @test "workspace://{workspace_id}/diagnostics" in templates
    end
end

@testitem "workspace resources return the data of their own workspace" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        basic_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")], "watch" => false)))
        lint_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")], "watch" => false)))

        basic_items = MCPTestHelpers.resource_json(
            MCPTestHelpers.read_resource(client, "workspace://$basic_id/testitems"))
        expected = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testitems",
            Dict{String,Any}("workspace_id" => basic_id)))
        @test length(basic_items) == 7
        @test sort([item["id"] for item in basic_items]) == sort([item["id"] for item in expected])

        @test MCPTestHelpers.resource_json(MCPTestHelpers.read_resource(client, "workspace://$lint_id/testitems")) == []
        @test MCPTestHelpers.resource_json(
            MCPTestHelpers.read_resource(client, "workspace://$basic_id/detection-errors")) == []

        lint_report = MCPTestHelpers.resource_json(
            MCPTestHelpers.read_resource(client, "workspace://$lint_id/diagnostics"))
        basic_report = MCPTestHelpers.resource_json(
            MCPTestHelpers.read_resource(client, "workspace://$basic_id/diagnostics"))
        @test lint_report["total"] >= 1
        @test lint_report != basic_report
    end
end

@testitem "an unknown workspace id in a resource URI is not found" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: JSONRPC

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")], "watch" => false))

        for uri in ("workspace://0000000000000000/testitems", "workspace://testitems")
            err = try
                MCPTestHelpers.read_resource(client, uri)
                nothing
            catch e
                e
            end
            @test err isa JSONRPC.JSONRPCError
            @test err.code == JuliaMCP.MCP_ERROR_RESOURCE_NOT_FOUND
            @test err.data["uri"] == uri
        end
    end
end

@testitem "a workspace notifies only the URIs of that workspace" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    first_pkg = MCPTestHelpers.copy_testdata("BasicPkg")
    second_pkg = MCPTestHelpers.copy_testdata("BasicPkg")

    MCPTestHelpers.with_mcp_server() do client
        set_folders(pkg) = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg], "watch_interval" => 0.05)))
        first_id = set_folders(first_pkg)
        second_id = set_folders(second_pkg)
        first_uri = "workspace://$first_id/testitems"
        second_uri = "workspace://$second_id/testitems"
        MCPTestHelpers.subscribe(client, first_uri)
        MCPTestHelpers.subscribe(client, second_uri)

        # Collect the updated URIs until `uri` arrives, then wait for stray notifications.
        function updated_uris_until(uri)
            seen = String[]
            MCPTestHelpers.timed_wait(20.0) do
                for msg in MCPTestHelpers.drain_notifications(client)
                    msg.method == "notifications/resources/updated" && push!(seen, msg.params["uri"])
                end
                uri in seen
            end
            sleep(1.0)
            for msg in MCPTestHelpers.drain_notifications(client)
                msg.method == "notifications/resources/updated" && push!(seen, msg.params["uri"])
            end
            return seen
        end

        MCPTestHelpers.drain_notifications(client)
        write(joinpath(first_pkg, "test", "test_notify.jl"), "@testitem \"notify\" begin\n    @test true\nend\n")
        seen = updated_uris_until(first_uri)
        @test first_uri in seen
        @test !(second_uri in seen)

        MCPTestHelpers.drain_notifications(client)
        set_folders(second_pkg)
        seen = updated_uris_until(second_uri)
        @test second_uri in seen
        @test !(first_uri in seen)
    end
end
