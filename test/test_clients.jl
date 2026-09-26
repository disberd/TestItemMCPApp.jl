# Each HTTP client has its own workspace binding, sessions, and requests. When a client
# closes or cancels the request of a test run, the server cancels that run.

@testitem "each client uses the workspace that it set up last" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server, post, tool_call, initialize, set_up, tool_json, tool_result

    with_http_server() do server
        a = initialize(server)
        b = initialize(server)
        set_up(server, a, "BasicPkg")
        set_up(server, b, "HangPkg")
        list(session) = post(server, tool_call(3, "julia_list_testitems"); session)
        item_names(session) = sort([item["name"] for item in tool_json(list(session))])
        function error_text(session)
            result = tool_result(list(session))
            return get(result, "isError", false) ? only(result["content"])["text"] : ""
        end

        @test item_names(a) == sort(["passing", "also passing", "failing", "erroring", "uses setup",
            "uses snippet", "no default imports"])
        @test item_names(b) == ["hangs forever", "quick"]
        # A client that set up no workspace needs a workspace_id while two workspaces exist.
        @test occursin("workspace_id is required", error_text(initialize(server)))

        # The workspace of A closes. A then gets an error, and it does not use the workspace of B.
        post(server, tool_call(4, "julia_close_workspace"); session=a)
        @test occursin("Call julia_set_workspace_folders again", error_text(a))
        @test item_names(b) == ["hangs forever", "quick"]
        set_up(server, a, "BasicPkg")
        @test length(item_names(a)) == 7
    end
end

@testitem "closing the POST of a test run cancels that run within 3 s" setup=[HTTPTestHelpers] tags=[:e2e] begin
    using .HTTPTestHelpers: with_http_server, post, tool_call, initialize, set_up, testruns, raw_post, events,
        body, wait_until

    with_http_server() do server
        a = initialize(server)
        b = initialize(server)
        set_up(server, a, "HangPkg")
        hang = Dict{String,Any}("name_pattern" => "^hangs", "max_wait_seconds" => 300)

        socket = raw_post(server, tool_call(3, "julia_run_testitems", hang); session=a)
        @test wait_until(() -> length(testruns(server, b)) == 1, 60)
        a_run = only(keys(testruns(server, b)))
        b_call = @async post(server, tool_call(3, "julia_run_testitems", hang); session=b)
        @test wait_until(() -> length(testruns(server, b)) == 2, 60)
        b_run = only(setdiff(keys(testruns(server, b)), [a_run]))

        closed_at = time()
        close(socket)
        @test wait_until(() -> testruns(server, b)[a_run] == "cancelled", 10; interval=0.1)
        @test time() - closed_at < 3
        @test testruns(server, b)[b_run] == "running"

        post(server, tool_call(4, "julia_cancel_testrun", Dict{String,Any}("testrun_id" => b_run)); session=b)
        @test last(events(body(fetch(b_call))))["id"] == 3
    end
end

@testitem "a close before the test run starts cancels the run when it starts" setup=[HTTPTestHelpers] tags=[:e2e] begin
    using .HTTPTestHelpers: with_http_server, tool_call, initialize, set_up, testruns, raw_post, wait_until

    with_http_server() do server
        a = initialize(server)
        set_up(server, a, "HangPkg")
        workspace = only(values(server.state.workspaces))
        client = server.state.clients[a]
        cancelled() = lock(server.state.lock) do
            request = get(client.requests, 3, nothing)
            request !== nothing && request.cancelled
        end

        # The run starts after the discovery of the test items, and the discovery waits for
        # this lock. So the server sees the close before the run starts.
        lock(workspace.workspace_lock) do
            close(raw_post(server, tool_call(3, "julia_run_testitems",
                Dict{String,Any}("name_pattern" => "^hangs", "max_wait_seconds" => 300)); session=a))
            @test wait_until(cancelled, 10)
            @test isempty(workspace.runs)
        end

        @test wait_until(() -> collect(values(testruns(server, a))) == ["cancelled"], 60)
    end
end

@testitem "notifications/cancelled cancels the run of that request of that client" setup=[HTTPTestHelpers] tags=[:e2e] begin
    using .HTTPTestHelpers: with_http_server, post, tool_call, initialize, set_up, testruns, events, body,
        wait_until

    with_http_server() do server
        a = initialize(server)
        b = initialize(server)
        set_up(server, a, "HangPkg")
        hang = Dict{String,Any}("name_pattern" => "^hangs", "max_wait_seconds" => 300)
        cancel(session, id) = post(server, Dict{String,Any}("jsonrpc" => "2.0", "method" => "notifications/cancelled",
            "params" => Dict{String,Any}("requestId" => id)); session)

        # Both clients use the request id 7.
        a_call = @async post(server, tool_call(7, "julia_run_testitems", hang); session=a)
        @test wait_until(() -> length(testruns(server, b)) == 1, 60)
        a_run = only(keys(testruns(server, b)))
        b_call = @async post(server, tool_call(7, "julia_run_testitems", hang); session=b)
        @test wait_until(() -> length(testruns(server, b)) == 2, 60)
        b_run = only(setdiff(keys(testruns(server, b)), [a_run]))

        # A cancel for an unknown request id does nothing.
        @test cancel(a, 8).status == 202
        @test all(==("running"), values(testruns(server, b)))

        @test cancel(a, 7).status == 202
        @test wait_until(() -> testruns(server, b)[a_run] == "cancelled", 10)
        @test testruns(server, b)[b_run] == "running"
        @test last(events(body(fetch(a_call))))["id"] == 7

        cancel(b, 7)
        @test wait_until(() -> testruns(server, b)[b_run] == "cancelled", 10)
        @test last(events(body(fetch(b_call))))["id"] == 7
    end
end

@testitem "DELETE kills the sessions of that client only" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server, post, tool_call, initialize, headers, tool_json, wait_until, HTTP

    with_http_server() do server
        a = initialize(server)
        b = initialize(server)
        create(session) = tool_json(post(server, tool_call(2, "julia_create_session"); session))["session_id"]
        a_session = create(a)
        b_session = create(b)
        listed() = Set(s["session_id"] for s in tool_json(post(server, tool_call(3, "julia_list_sessions"); session=b)))
        live(id) = any(info -> info.id == id, JuliaMCP.JSC.list_sessions(server.state.session_controller))

        # Each client sees the sessions of all clients.
        @test listed() == Set([a_session, b_session])
        @test HTTP.request("DELETE", server.url, headers(server; session=a); status_exception=false).status == 200
        @test listed() == Set([b_session])
        @test wait_until(() -> !live(a_session), 30)
        @test live(b_session)
    end
end

@testitem "the reaper removes an idle client and keeps a client with an open request" setup=[HTTPTestHelpers] begin
    using .HTTPTestHelpers: with_http_server, post, request, tool_call, initialize, tool_json, events, body,
        wait_until

    withenv("JULIAMCP_IDLE_TIMEOUT_SECS" => "2") do
        with_http_server() do server
            busy = initialize(server)
            session_id = tool_json(post(server, tool_call(2, "julia_create_session"); session=busy))["session_id"]
            long = @async post(server, tool_call(3, "julia_eval_code", Dict{String,Any}(
                "session_id" => session_id, "code" => "sleep(600)", "revise" => false)); session=busy)
            evaluating() = any(JuliaMCP.JSC.list_sessions(server.state.session_controller)) do info
                info.id == session_id && info.current_request !== nothing
            end
            @test wait_until(evaluating, 60)

            # The idle client starts after the last finished request of the busy client. So
            # when the reaper removes the idle client, only the open request keeps the busy
            # client.
            idle = initialize(server)
            @test wait_until(() -> !haskey(server.state.clients, idle), 30)
            @test haskey(server.state.clients, busy)
            @test post(server, request(4, "tools/list"); session=idle).status == 404

            post(server, tool_call(5, "julia_kill_session", Dict{String,Any}("session_id" => session_id)); session=busy)
            @test last(events(body(fetch(long))))["id"] == 3
        end
    end
end
