# callbacks.jl — TestItemController callback implementations

function create_controller_callbacks(state::AppState, session::SessionState)
    return TestItemControllers.ControllerCallbacks(
        on_testitem_started = (testrun_id, testitem_id, test_env_id) -> begin
            lock(session.lock) do
                run = get(session.runs, testrun_id, nothing)
                run === nothing && return
                item = get(run.items, testitem_id, nothing)
                item === nothing && return
                item.status = :running
            end
            mcp_info(state, "testitem", "Started: $(get_item_label(session, testrun_id, testitem_id))")
            notify_resource_updated(state, "testrun://$testrun_id/summary")
        end,

        on_testitem_passed = (testrun_id, testitem_id, test_env_id, duration) -> begin
            lock(session.lock) do
                run = get(session.runs, testrun_id, nothing)
                run === nothing && return
                item = get(run.items, testitem_id, nothing)
                item === nothing && return
                item.status = :passed
                item.duration = duration
            end
            mcp_info(state, "testitem", "Passed: $(get_item_label(session, testrun_id, testitem_id)) ($(round(duration, digits=2))s)")
            notify_resource_updated(state, "testrun://$testrun_id/summary")
            notify_resource_updated(state, "testrun://$testrun_id/failures")
        end,

        on_testitem_failed = (testrun_id, testitem_id, test_env_id, messages, duration) -> begin
            lock(session.lock) do
                run = get(session.runs, testrun_id, nothing)
                run === nothing && return
                item = get(run.items, testitem_id, nothing)
                item === nothing && return
                item.status = :failed
                item.duration = duration
                item.messages = [testmessage_to_dict(m) for m in messages]
            end
            label = get_item_label(session, testrun_id, testitem_id)
            msg_summary = isempty(messages) ? "" : ": $(first(messages).message)"
            dur_str = duration !== nothing ? " ($(round(duration, digits=2))s)" : ""
            mcp_warn(state, "testitem", "Failed: $label$dur_str$msg_summary")
            notify_resource_updated(state, "testrun://$testrun_id/summary")
            notify_resource_updated(state, "testrun://$testrun_id/failures")
        end,

        on_testitem_errored = (testrun_id, testitem_id, test_env_id, messages, duration) -> begin
            lock(session.lock) do
                run = get(session.runs, testrun_id, nothing)
                run === nothing && return
                item = get(run.items, testitem_id, nothing)
                item === nothing && return
                item.status = :errored
                item.duration = duration
                item.messages = [testmessage_to_dict(m) for m in messages]
            end
            label = get_item_label(session, testrun_id, testitem_id)
            msg_summary = isempty(messages) ? "" : ": $(first(messages).message)"
            dur_str = duration !== nothing ? " ($(round(duration, digits=2))s)" : ""
            mcp_error(state, "testitem", "Errored: $label$dur_str$msg_summary")
            notify_resource_updated(state, "testrun://$testrun_id/summary")
            notify_resource_updated(state, "testrun://$testrun_id/failures")
        end,

        on_testitem_skipped = (testrun_id, testitem_id, test_env_id) -> begin
            lock(session.lock) do
                run = get(session.runs, testrun_id, nothing)
                run === nothing && return
                item = get(run.items, testitem_id, nothing)
                item === nothing && return
                item.status = :skipped
            end
            mcp_info(state, "testitem", "Skipped: $(get_item_label(session, testrun_id, testitem_id))")
            notify_resource_updated(state, "testrun://$testrun_id/summary")
        end,

        on_append_output = (testrun_id, testitem_id, test_env_id, output) -> begin
            lock(session.lock) do
                run = get(session.runs, testrun_id, nothing)
                run === nothing && return
                item = get(run.items, testitem_id, nothing)
                item === nothing && return
                push!(item.output, output)
            end
            notify_resource_updated(state, "testrun://$testrun_id/items/$testitem_id/output")
        end,

        on_attach_debugger = (testrun_id, debug_pipe_name) -> begin
            # Debugging is excluded from MCP server
        end,

        on_process_created = (id, test_env_id) -> begin
            env = lock(session.lock) do
                get(session.test_env_by_id, test_env_id, nothing)
            end
            package_name = env !== nothing ? env.package_name : ""
            package_uri = env !== nothing ? env.package_uri : ""
            project_uri = env !== nothing ? something(env.project_uri, "") : ""
            lock(session.lock) do
                session.processes[id] = ProcessInfo(id, package_name, "Created", package_uri, project_uri)
                session.process_outputs[id] = String[]
            end
            mcp_notice(state, "controller", "Process created for $package_name (id=$id)")
            notify_resource_list_changed(state)
        end,

        on_process_terminated = (id,) -> begin
            pkg_name = lock(session.lock) do
                p = get(session.processes, id, nothing)
                name = p === nothing ? id : p.package_name
                delete!(session.processes, id)
                delete!(session.process_outputs, id)
                name
            end
            mcp_notice(state, "controller", "Process terminated: $pkg_name (id=$id)")
            notify_resource_list_changed(state)
        end,

        on_process_status_changed = (id, status) -> begin
            lock(session.lock) do
                p = get(session.processes, id, nothing)
                p === nothing && return
                p.status = status
            end
            mcp_debug(state, "controller", "Process $id: $status")
        end,

        on_process_output = (id, output) -> begin
            lock(session.lock) do
                buf = get(session.process_outputs, id, nothing)
                buf === nothing && return
                push!(buf, output)
            end
            mcp_debug(state, "controller", output)
        end,
    )
end

function get_item_label(session::SessionState, testrun_id::String, testitem_id::String)
    lock(session.lock) do
        run = get(session.runs, testrun_id, nothing)
        run === nothing && return testitem_id
        item = get(run.items, testitem_id, nothing)
        item === nothing && return testitem_id
        return item.label
    end
end

function init_controller!(state::AppState, session::SessionState)
    created = lock(session.lock) do
        session.controller !== nothing && return false
        callbacks = create_controller_callbacks(state, session)
        session.controller = TestItemControllers.TestItemController(callbacks; log_level=:Info)
        session.reactor_task = @async Base.run(session.controller)
        return true
    end
    if created
        mcp_notice(state, "transport", "TestItemController initialized for session $(session.id)")
    end
end

function shutdown_controller!(session::SessionState)
    ctrl, task = lock(session.lock) do
        c = session.controller
        t = session.reactor_task
        session.controller = nothing
        session.reactor_task = nothing
        (c, t)
    end
    ctrl === nothing && return
    TestItemControllers.shutdown(ctrl)
    task !== nothing && TestItemControllers.wait_for_shutdown(ctrl, task)
end
