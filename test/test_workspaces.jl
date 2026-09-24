
@testitem "workspaces keep test items and run histories separate" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        basic = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        lint = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")

        basic_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}("folders" => [basic], "watch" => false)))
        basic_items = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client,
            "julia_list_testitems", Dict{String,Any}("workspace_id" => basic_id)))
        @test !isempty(basic_items)
        passing_id = only(filter(item -> item["name"] == "passing", basic_items))["id"]

        run = MCPTestHelpers.call_tool(client, "julia_run_testitems", Dict{String,Any}(
            "workspace_id" => basic_id,
            "items" => [passing_id],
            "max_wait_seconds" => 300,
        ))
        @test !MCPTestHelpers.is_error(run)

        lint_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}("folders" => [lint], "watch" => false)))
        lint_items = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client,
            "julia_list_testitems", Dict{String,Any}("workspace_id" => lint_id)))
        @test isempty(lint_items)
        @test isempty(MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client,
            "julia_list_testruns", Dict{String,Any}("workspace_id" => lint_id))))

        basic_runs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client,
            "julia_list_testruns", Dict{String,Any}("workspace_id" => basic_id)))
        @test length(basic_runs) == 1
    end
end

@testitem "the same folders reuse the workspace id" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        first_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg], "watch" => false)))
        second_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}(
                "folders" => [joinpath(pkg, ".")],
                "watch" => false,
            )))
        @test second_id == first_id
        lint = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
        @test JuliaMCP.workspace_id([pkg, pkg]) == first_id
        @test JuliaMCP.workspace_id([pkg, lint]) == JuliaMCP.workspace_id([lint, joinpath(pkg, ".")])
    end
end

@testitem "workspace id is optional with one workspace and required with many" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        basic = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        lint = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")

        basic_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}("folders" => [basic], "watch" => false)))
        one_workspace = MCPTestHelpers.call_tool(client, "julia_list_testitems")
        @test !MCPTestHelpers.is_error(one_workspace)
        @test length(MCPTestHelpers.result_json(one_workspace)) == 7

        lint_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}("folders" => [lint], "watch" => false)))
        ambiguous = MCPTestHelpers.call_tool(client, "julia_list_testitems")
        @test MCPTestHelpers.is_error(ambiguous)
        message = MCPTestHelpers.result_text(ambiguous)
        @test occursin(basic_id, message)
        @test occursin(lint_id, message)
        @test occursin(basic, message)
        @test occursin(lint, message)
        unknown = MCPTestHelpers.call_tool(client, "julia_list_testitems",
            Dict{String,Any}("workspace_id" => "missing"))
        @test MCPTestHelpers.is_error(unknown)
        @test occursin("Unknown workspace_id", MCPTestHelpers.result_text(unknown))
    end
end

@testitem "reconfiguring a workspace keeps its run history" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        workspace_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg], "watch" => false)))
        items = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client,
            "julia_list_testitems", Dict{String,Any}("workspace_id" => workspace_id)))
        passing_id = only(filter(item -> item["name"] == "passing", items))["id"]
        run = MCPTestHelpers.call_tool(client, "julia_run_testitems", Dict{String,Any}(
            "workspace_id" => workspace_id,
            "items" => [passing_id],
            "max_wait_seconds" => 300,
        ))
        @test !MCPTestHelpers.is_error(run)

        repeated_id = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg], "watch" => false)))
        @test repeated_id == workspace_id
        runs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client,
            "julia_list_testruns", Dict{String,Any}("workspace_id" => workspace_id)))
        @test length(runs) == 1
    end
end
