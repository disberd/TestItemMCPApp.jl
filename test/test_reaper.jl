# The idle reaper closes the workspaces and kills the sessions that no client used for longer
# than the idle timeout. `julia_close_workspace` closes one workspace when an agent asks for it.

@testitem "JULIAMCP_IDLE_TIMEOUT_SECS sets the idle timeout and 0 turns reaping off" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    pkg = joinpath(MCPTestHelpers.TESTDATA_DIR, "LintPkg")
    configure(client) = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
        "julia_set_workspace_folders", Dict{String,Any}("folders" => [pkg], "watch" => false)))
    # A call with an unknown workspace id lists the open workspaces in its error. It uses none
    # of them, so it does not reset their idle time.
    is_open(client, id) = occursin(id, MCPTestHelpers.result_text(MCPTestHelpers.call_tool(client,
        "julia_list_testitems", Dict{String,Any}("workspace_id" => "unknown"))))

    withenv("JULIAMCP_IDLE_TIMEOUT_SECS" => "2") do
        MCPTestHelpers.with_mcp_server() do client
            id = configure(client)
            @test MCPTestHelpers.timed_wait(() -> !is_open(client, id), 60.0; interval=0.5)
        end
    end

    withenv("JULIAMCP_IDLE_TIMEOUT_SECS" => "0") do
        MCPTestHelpers.with_mcp_server() do client
            id = configure(client)
            sleep(4)
            @test is_open(client, id)
        end
    end
end

@testitem "the reaper closes an idle workspace and keeps a used or running one" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: TestRunRecord, TestItemResult
    using Dates

    MCPTestHelpers.with_app_state() do state
        idle = MCPTestHelpers.add_workspace!(state, [mktempdir()])
        running = MCPTestHelpers.add_workspace!(state, [mktempdir()])
        recent = MCPTestHelpers.add_workspace!(state, [mktempdir()])
        idle_id, running_id, recent_id = (JuliaMCP.workspace_id(w.folders) for w in (idle, running, recent))

        watcher = JuliaMCP.start_watcher!(state, idle; interval=0.05)
        session = JuliaMCP.init_controller!(state, idle)
        run = TestRunRecord("run-1", :running, Dict{String,Any}(), Dict{String,TestItemResult}(),
            nothing, Dates.now(), nothing)
        running.runs["run-1"] = run
        idle.last_used_at = Dates.now() - Dates.Minute(5)
        running.last_used_at = Dates.now() - Dates.Minute(5)

        JuliaMCP.reap_idle!(state, 60)

        @test !haskey(state.workspaces, idle_id)
        @test haskey(state.workspaces, running_id)
        @test haskey(state.workspaces, recent_id)
        # Closing a workspace stops its watcher and closes its test session.
        @test MCPTestHelpers.timed_wait(() -> istaskdone(watcher), 10.0)
        @test !isopen(session)

        # A finished run does not keep its workspace open.
        JuliaMCP.finalize_run_status!(run, :completed)
        JuliaMCP.reap_idle!(state, 60)
        @test !haskey(state.workspaces, running_id)
        @test haskey(state.workspaces, recent_id)
    end
end

@testitem "the reaper kills an idle session and keeps a busy one" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using Dates

    MCPTestHelpers.with_app_state() do state
        create() = MCPTestHelpers.result_json(
            JuliaMCP.handle_tool_call(state, "julia_create_session", Dict{String,Any}()))["session_id"]
        idle = create()
        busy = create()
        sessions() = JuliaMCP.JSC.list_sessions(state.session_controller)

        evaluation = @async JuliaMCP.handle_tool_call(state, "julia_eval_code",
            Dict{String,Any}("session_id" => busy, "code" => "sleep(600)", "revise" => false))
        @test MCPTestHelpers.timed_wait(60.0; interval=0.1) do
            any(info -> info.id == busy && info.current_request !== nothing, sessions())
        end
        lock(state.lock) do
            for rec in values(state.sessions)
                rec.last_used_at = Dates.now() - Dates.Minute(5)
            end
        end

        JuliaMCP.reap_idle!(state, 60)

        @test lock(() -> collect(keys(state.sessions)), state.lock) == [busy]
        @test MCPTestHelpers.timed_wait(() -> !any(info -> info.id == idle, sessions()), 30.0)
        @test any(info -> info.id == busy && info.alive, sessions())
        @test !istaskdone(evaluation)
    end
end

@testitem "julia_close_workspace closes one workspace and leaves the other" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers

    MCPTestHelpers.with_mcp_server() do client
        configure(pkg) = MCPTestHelpers.workspace_id_from_result(MCPTestHelpers.call_tool(client,
            "julia_set_workspace_folders", Dict{String,Any}(
                "folders" => [joinpath(MCPTestHelpers.TESTDATA_DIR, pkg)],
                "watch" => false,
            )))
        basic_id = configure("BasicPkg")
        lint_id = configure("LintPkg")
        MCPTestHelpers.drain_notifications(client)

        closed = MCPTestHelpers.call_tool(client, "julia_close_workspace",
            Dict{String,Any}("workspace_id" => basic_id))
        @test !MCPTestHelpers.is_error(closed)
        @test occursin(basic_id, MCPTestHelpers.result_text(closed))
        @test MCPTestHelpers.wait_for_notification(client, "notifications/resources/list_changed";
            timeout=10.0) !== nothing

        gone = MCPTestHelpers.call_tool(client, "julia_list_testitems",
            Dict{String,Any}("workspace_id" => basic_id))
        @test MCPTestHelpers.is_error(gone)
        @test occursin("Unknown workspace_id", MCPTestHelpers.result_text(gone))

        # The other workspace stays open. The client set it up last, so it needs no id.
        @test !MCPTestHelpers.is_error(MCPTestHelpers.call_tool(client, "julia_list_testitems",
            Dict{String,Any}("workspace_id" => lint_id)))
        @test MCPTestHelpers.result_json(MCPTestHelpers.call_tool(client, "julia_list_testitems")) == []
    end
end

@testitem "julia_close_workspace refuses while a test run is active" setup=[MCPTestHelpers] begin
    using .MCPTestHelpers
    using JuliaMCP: TestRunRecord, TestItemResult
    using Dates

    MCPTestHelpers.with_app_state() do state
        MCPTestHelpers.add_workspace!(state, [mktempdir()])
        run = TestRunRecord("run-1", :running, Dict{String,Any}(), Dict{String,TestItemResult}(),
            nothing, Dates.now(), nothing)
        only(values(state.workspaces)).runs["run-1"] = run

        refused = JuliaMCP.handle_tool_call(state, "julia_close_workspace", Dict{String,Any}())
        @test MCPTestHelpers.is_error(refused)
        @test occursin("run-1", MCPTestHelpers.result_text(refused))
        @test occursin("julia_cancel_testrun", MCPTestHelpers.result_text(refused))
        @test length(state.workspaces) == 1

        # After the agent cancels the run, the same call closes the workspace.
        JuliaMCP.finalize_run_status!(run, :cancelled)
        closed = JuliaMCP.handle_tool_call(state, "julia_close_workspace", Dict{String,Any}())
        @test !MCPTestHelpers.is_error(closed)
        @test isempty(state.workspaces)
    end
end
