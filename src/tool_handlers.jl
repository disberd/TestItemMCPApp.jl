# tool_handlers.jl — MCP tool call implementations

function handle_tool_call(state::AppState, tool_name::String, arguments::Dict{String,Any})
    if tool_name == "set_workspace_folders"
        return tool_set_workspace_folders(state, arguments)
    elseif tool_name == "update_file"
        return tool_update_file(state, arguments)
    elseif tool_name == "list_testitems"
        return tool_list_testitems(state, arguments)
    elseif tool_name == "run_testitems"
        return tool_run_testitems(state, arguments)
    elseif tool_name == "rerun_failed"
        return tool_rerun_failed(state, arguments)
    elseif tool_name == "cancel_testrun"
        return tool_cancel_testrun(state, arguments)
    elseif tool_name == "get_testrun_results"
        return tool_get_testrun_results(state, arguments)
    elseif tool_name == "get_testitem_detail"
        return tool_get_testitem_detail(state, arguments)
    elseif tool_name == "list_testruns"
        return tool_list_testruns(state, arguments)
    elseif tool_name == "list_test_processes"
        return tool_list_test_processes(state, arguments)
    elseif tool_name == "terminate_test_process"
        return tool_terminate_test_process(state, arguments)
    elseif tool_name == "get_coverage_results"
        return tool_get_coverage_results(state, arguments)
    elseif tool_name == "get_process_output"
        return tool_get_process_output(state, arguments)
    elseif tool_name == "terminate_all_processes"
        return tool_terminate_all_processes(state, arguments)
    elseif tool_name == "close_session"
        return tool_close_session(state, arguments)
    else
        error("Unknown tool: $tool_name")
    end
end

# --- set_workspace_folders ---

function tool_set_workspace_folders(state::AppState, args::Dict{String,Any})
    folders = convert(Vector{String}, args["folders"])
    explicit_id = get(args, "session_id", nothing)
    if explicit_id !== nothing
        explicit_id = String(explicit_id)
        if !occursin(r"^[A-Za-z0-9._-]+$", explicit_id)
            return tool_result_error("session_id must contain only alphanumeric characters, '.', '_', or '-': $(explicit_id)")
        end
    end
    sid = explicit_id !== nothing ? explicit_id : session_key(folders)

    mcp_info(state, "tools", "Setting workspace folders for session $sid: $folders")

    session = lock(state.lock) do
        get!(state.sessions, sid) do
            SessionState(sid)
        end
    end

    session.last_active[] = time()

    jw = JuliaWorkspaces.workspace_from_folders(folders)
    lock(session.lock) do
        session.workspace = jw
    end

    # Initialize controller on first workspace setup
    init_controller!(state, session)

    items = collect_testitems_list(session)
    errors = collect_detection_errors(session)

    notify_resource_list_changed(state)
    notify_resource_updated(state, "workspace://$(sid)/testitems")
    notify_resource_updated(state, "workspace://$(sid)/detection-errors")

    text = "Workspace configured (session=$(sid)) with $(length(folders)) folder(s). " *
           "Detected $(length(items)) test item(s)"
    if !isempty(errors)
        text *= " and $(length(errors)) detection error(s)"
    end
    text *= "."

    session.last_active[] = time()
    return tool_result_text(text)
end

# --- update_file ---

function tool_update_file(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    path = args["path"]::String
    jw = session.workspace
    jw === nothing && return tool_result_error("Workspace not configured. Call set_workspace_folders first.")

    JuliaWorkspaces.update_file_from_disc!(jw, path)

    notify_resource_updated(state, "workspace://$(session.id)/testitems")
    notify_resource_updated(state, "workspace://$(session.id)/detection-errors")

    return tool_result_text("File updated: $path")
end

# --- list_testitems ---

function tool_list_testitems(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    session.workspace === nothing && return tool_result_error("Workspace not configured. Call set_workspace_folders first.")

    filter = build_filter(args)
    items = collect_testitems_list(session; filter=filter)

    return tool_result_json(items)
end

# --- run_testitems ---

function tool_run_testitems(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    session.workspace === nothing && return tool_result_error("Workspace not configured. Call set_workspace_folders first.")

    init_controller!(state, session)

    filter = build_filter(args)
    items, setups, item_package_info = resolve_testitems(session; filter=filter)

    if isempty(items)
        return tool_result_text("No test items matched the given filter.")
    end

    test_envs, env_id_for_item, max_processes, coverage_root_uris, log_level = build_test_environments(args, item_package_info)
    testrun_id = test_envs[1].id

    # Register test environments for on_process_created callback
    lock(session.lock) do
        for env in test_envs
            session.test_env_by_id[env.id] = env
        end
    end

    # Build work units mapping each item to its matching test environment
    timeout = get(args, "timeout", nothing)
    work_units = [
        TestItemControllers.TestRunItem(item.id, env_id_for_item[item.id], timeout, log_level)
        for item in items
    ]

    # Create cancellation source
    cts = CancellationTokens.CancellationTokenSource()
    lock(session.lock) do
        session.cancellation_sources[testrun_id] = cts
    end

    # Register test run record with pending items
    run_record = TestRunRecord(
        testrun_id,
        :running,
        args,
        Dict{String,TestItemResult}(
            item.id => TestItemResult(item.id, item.label, item.uri, :pending, nothing, Any[], String[])
            for item in items
        ),
        nothing,
        Dates.now(),
        nothing,
    )
    lock(session.lock) do
        session.runs[testrun_id] = run_record
    end
    notify_resource_list_changed(state)

    mcp_info(state, "tools", "Starting test run $testrun_id with $(length(items)) item(s)")

    coverage_results = try
        TestItemControllers.execute_testrun(
            session.controller,
            testrun_id,
            test_envs,
            items,
            work_units,
            setups,
            max_processes,
            CancellationTokens.get_token(cts);
            coverage_root_uris=coverage_root_uris,
        )
    catch e
        lock(session.lock) do
            run_record.status = :errored
            run_record.completed_at = Dates.now()
        end
        mcp_error(state, "tools", "Test run $testrun_id failed: $e")
        return tool_result_error("Test run failed: $e")
    finally
        lock(session.lock) do
            delete!(session.cancellation_sources, testrun_id)
        end
    end

    lock(session.lock) do
        run_record.status = :completed
        run_record.completed_at = Dates.now()
        if coverage_results !== nothing
            run_record.coverage = coverage_to_dicts(coverage_results)
        end
    end

    summary = lock(session.lock) do
        run_summary(run_record)
    end

    notify_resource_updated(state, "testrun://$testrun_id/summary")
    notify_resource_updated(state, "testrun://$testrun_id/failures")

    mcp_info(state, "tools", "Test run $testrun_id completed: $(summary["passed"]) passed, $(summary["failed"]) failed, $(summary["errored"]) errored")

    # Return full results inline so the LLM has everything it needs
    failures = lock(session.lock) do
        [
            Dict{String,Any}(
                "testitem_id" => item.testitem_id,
                "label" => item.label,
                "uri" => item.uri,
                "status" => string(item.status),
                "duration_ms" => item.duration,
                "messages" => item.messages,
            ) for item in values(run_record.items) if item.status in (:failed, :errored)
        ]
    end

    result = Dict{String,Any}(
        "summary" => summary,
        "failures" => failures,
    )

    return tool_result_json(result)
end

# --- rerun_failed ---

function tool_rerun_failed(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    testrun_id = args["testrun_id"]::String

    prev_run = lock(session.lock) do
        get(session.runs, testrun_id, nothing)
    end
    prev_run === nothing && return tool_result_error("Test run not found: $testrun_id")

    failed_ids = lock(session.lock) do
        [item.testitem_id for item in values(prev_run.items) if item.status in (:failed, :errored)]
    end
    isempty(failed_ids) && return tool_result_text("No failed or errored items in run $testrun_id.")

    # Build new run args with the failed IDs
    new_args = copy(args)
    new_args["items"] = failed_ids
    # Preserve original profile params
    for key in ("julia_cmd", "julia_args", "max_workers", "timeout", "mode", "julia_num_threads", "julia_env", "log_level")
        if haskey(prev_run.profile_params, key) && !haskey(new_args, key)
            new_args[key] = prev_run.profile_params[key]
        end
    end

    return tool_run_testitems(state, new_args)
end

# --- cancel_testrun ---

function tool_cancel_testrun(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    testrun_id = args["testrun_id"]::String

    cts = lock(session.lock) do
        get(session.cancellation_sources, testrun_id, nothing)
    end
    cts === nothing && return tool_result_error("No active test run with ID: $testrun_id")

    CancellationTokens.cancel(cts)

    lock(session.lock) do
        run = get(session.runs, testrun_id, nothing)
        if run !== nothing
            run.status = :cancelled
            run.completed_at = Dates.now()
        end
    end

    mcp_info(state, "tools", "Cancelled test run $testrun_id")
    return tool_result_text("Test run $testrun_id cancelled.")
end

# --- get_testrun_results ---

function tool_get_testrun_results(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    testrun_id = args["testrun_id"]::String
    include_output = get(args, "include_output", false)::Bool
    include_passing = get(args, "include_passing", false)::Bool

    run = lock(session.lock) do
        get(session.runs, testrun_id, nothing)
    end
    run === nothing && return tool_result_error("Test run not found: $testrun_id")

    summary = lock(session.lock) do
        run_summary(run)
    end

    items_out = lock(session.lock) do
        result = Dict{String,Any}[]
        for item in values(run.items)
            if !include_passing && item.status == :passed
                continue
            end
            d = Dict{String,Any}(
                "testitem_id" => item.testitem_id,
                "label" => item.label,
                "uri" => item.uri,
                "status" => string(item.status),
                "duration_ms" => item.duration,
                "messages" => item.messages,
            )
            if include_output
                d["output"] = join(item.output, "")
            end
            push!(result, d)
        end
        result
    end

    return tool_result_json(Dict{String,Any}("summary" => summary, "items" => items_out))
end

# --- get_testitem_detail ---

function tool_get_testitem_detail(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    testrun_id = args["testrun_id"]::String
    testitem_id = args["testitem_id"]::String

    item = lock(session.lock) do
        run = get(session.runs, testrun_id, nothing)
        run === nothing && return nothing
        get(run.items, testitem_id, nothing)
    end
    item === nothing && return tool_result_error("Test item $testitem_id not found in run $testrun_id")

    d = lock(session.lock) do
        Dict{String,Any}(
            "testitem_id" => item.testitem_id,
            "label" => item.label,
            "uri" => item.uri,
            "status" => string(item.status),
            "duration_ms" => item.duration,
            "messages" => item.messages,
            "output" => join(item.output, ""),
        )
    end

    return tool_result_json(d)
end

# --- list_testruns ---

function tool_list_testruns(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    runs = lock(session.lock) do
        [run_summary(run) for run in values(session.runs)]
    end
    return tool_result_json(runs)
end

# --- list_test_processes ---

function tool_list_test_processes(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    procs = lock(session.lock) do
        [
            Dict{String,Any}(
                "id" => p.id,
                "package_name" => p.package_name,
                "status" => p.status,
                "package_uri" => p.package_uri,
                "project_uri" => p.project_uri,
            ) for p in values(session.processes)
        ]
    end
    return tool_result_json(procs)
end

# --- terminate_test_process ---

function tool_terminate_test_process(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    process_id = args["process_id"]::String
    session.controller === nothing && return tool_result_error("Controller not initialized.")
    TestItemControllers.terminate_test_process(session.controller, process_id)
    return tool_result_text("Process $process_id termination requested.")
end

# --- get_coverage_results ---

function tool_get_coverage_results(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    testrun_id = args["testrun_id"]::String

    coverage = lock(session.lock) do
        run = get(session.runs, testrun_id, nothing)
        run === nothing && return :not_found
        run.coverage === nothing && return :no_coverage
        run.coverage
    end
    coverage === :not_found && return tool_result_error("Test run not found: $testrun_id")
    coverage === :no_coverage && return tool_result_error("No coverage data. Was the run executed with mode=\"Coverage\"?")

    return tool_result_json(coverage)
end

# --- get_process_output ---

function tool_get_process_output(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    process_id = args["process_id"]::String
    output = lock(session.lock) do
        get(session.process_outputs, process_id, nothing)
    end
    output === nothing && return tool_result_error("No output found for process: $process_id")
    return tool_result_text(join(output, ""))
end

# --- terminate_all_processes ---

function tool_terminate_all_processes(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    session.controller === nothing && return tool_result_error("Controller not initialized.")
    process_ids = lock(session.lock) do
        collect(keys(session.processes))
    end
    for pid in process_ids
        TestItemControllers.terminate_test_process(session.controller, pid)
    end
    return tool_result_text("Terminated $(length(process_ids)) process(es).")
end

# --- close_session ---

function tool_close_session(state::AppState, args::Dict{String,Any})
    session = resolve_session(state, args)
    sid = session.id
    removed = lock(state.lock) do
        pop!(state.sessions, sid, nothing)
    end
    removed === nothing && return tool_result_text("Session $sid already closed.")
    shutdown_controller!(removed)
    mcp_info(state, "tools", "Session $sid closed")
    return tool_result_text("Session $sid closed.")
end

# --- Helpers ---

function build_filter(args::Dict{String,Any})
    filter = Dict{Symbol,Any}()
    if haskey(args, "items") && args["items"] !== nothing
        filter[:ids] = Set(convert(Vector{String}, args["items"]))
    end
    if haskey(args, "tags") && args["tags"] !== nothing
        filter[:tags] = convert(Vector{String}, args["tags"])
    end
    if haskey(args, "name_pattern") && args["name_pattern"] !== nothing
        filter[:name_pattern] = args["name_pattern"]::String
    end
    if haskey(args, "file_pattern") && args["file_pattern"] !== nothing
        filter[:file_pattern] = args["file_pattern"]::String
    end
    if haskey(args, "package") && args["package"] !== nothing
        filter[:package] = args["package"]::String
    end
    if haskey(args, "timeout") && args["timeout"] !== nothing
        filter[:timeout] = args["timeout"]
    end
    return isempty(filter) ? nothing : filter
end

function tool_result_text(text::String)
    return Dict{String,Any}(
        "content" => [Dict{String,Any}("type" => "text", "text" => text)],
    )
end

function tool_result_json(data)
    return Dict{String,Any}(
        "content" => [Dict{String,Any}("type" => "text", "text" => JSON.json(data))],
    )
end

function tool_result_error(message::String)
    return Dict{String,Any}(
        "content" => [Dict{String,Any}("type" => "text", "text" => message)],
        "isError" => true,
    )
end

function coverage_to_dicts(coverage_results)
    dicts = Any[]
    for fc in coverage_results
        push!(dicts, Dict{String,Any}(
            "uri" => fc.uri,
            "lines" => [
                Dict{String,Any}("line" => lc.line, "count" => lc.count)
                for lc in fc.lines
            ],
        ))
    end
    return dicts
end
