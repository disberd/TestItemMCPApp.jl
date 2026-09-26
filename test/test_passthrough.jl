
@testitem "julia_env reaches the test item and julia_rerun_failed keeps it" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    pkg = MCPTestHelpers.copy_testdata("BasicPkg")
    open(joinpath(pkg, "test", "test_basics.jl"), "a") do io
        println(io, "\n@testitem \"env probe\" begin\n    error(\"probe=\" * get(ENV, \"JULIA_MCP_PROBE\", \"unset\"))\nend")
    end

    probe_message(client, run_id, item_id) = only(only(MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client,
        "julia_get_testitem_detail", Dict{String,Any}("testrun_id" => run_id, "testitem_id" => item_id))))["messages"])["message"]

    MCPTestHelpers.with_mcp_server() do client
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        items = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testitems"))
        probe_id = only(filter(item -> item["name"] == "env probe", items))["id"]

        run = MCPTestHelpers.call_tool(client, "julia_run_testitems", Dict{String,Any}(
            "items" => [probe_id],
            "julia_env" => Dict{String,Any}("JULIA_MCP_PROBE" => "from-julia-env"),
            "log_level" => "Warn",
            "max_wait_seconds" => 300,
        ))
        @test !MCPTestHelpers.is_error(run)
        run_id = MCPTestHelpers.result_json(run)["testrun_id"]
        @test occursin("probe=from-julia-env", probe_message(client, run_id, probe_id))

        rerun = MCPTestHelpers.call_tool(client, "julia_rerun_failed", Dict{String,Any}(
            "testrun_id" => run_id,
            "max_wait_seconds" => 300,
        ))
        @test !MCPTestHelpers.is_error(rerun)
        rerun_id = MCPTestHelpers.result_json(rerun)["testrun_id"]
        @test rerun_id != run_id
        @test occursin("probe=from-julia-env", probe_message(client, rerun_id, probe_id))
    end
end

@testitem "process tools: output and terminate all" setup=[MCPTestHelpers] tags=[:e2e] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "BasicPkg")
        MCPTestHelpers.call_tool(client, "julia_set_workspace_folders",
            Dict{String,Any}("folders" => [pkg], "watch" => false))
        run = MCPTestHelpers.call_tool(client, "julia_run_testitems",
            MCPTestHelpers.to_completion(Dict{String,Any}("max_workers" => 1)))
        @test !MCPTestHelpers.is_error(run)

        procs = MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_test_processes"))
        @test length(procs) == 1

        known = MCPTestHelpers.call_tool(client, "julia_get_process_output",
            Dict{String,Any}("process_id" => only(procs)["id"]))
        @test !MCPTestHelpers.is_error(known)
        @test MCPTestHelpers.result_text(known) isa String

        unknown = MCPTestHelpers.call_tool(client, "julia_get_process_output",
            Dict{String,Any}("process_id" => "no-such-process"))
        @test MCPTestHelpers.is_error(unknown)
        @test occursin("no-such-process", MCPTestHelpers.result_text(unknown))

        terminated = MCPTestHelpers.call_tool(client, "julia_terminate_all_processes")
        @test !MCPTestHelpers.is_error(terminated)
        @test MCPTestHelpers.timed_wait(30.0) do
            isempty(MCPTestHelpers.result_json(
                MCPTestHelpers.call_tool(client, "julia_list_test_processes")))
        end
    end
end
