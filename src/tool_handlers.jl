# tool_handlers.jl — MCP tool call implementations

const MAX_ITEMS_DEFAULT = 200
# How long `julia_run_testitems` blocks before handing a still-running run back to the
# caller. Ten minutes covers a cold worker start plus precompilation plus a normal suite, so
# the common case is unchanged, while a deadlocked item costs the caller at most ten minutes
# instead of forever. The run itself is never touched by this bound.
const MAX_WAIT_SECONDS_DEFAULT = 600
const MAX_OUTPUT_BYTES_DEFAULT = 8_000
const MAX_MESSAGES_DEFAULT = 20
const MAX_STACK_FRAMES_DEFAULT = 20

"""
Check `arguments` against the `required` list in the tool's declared input
schema. Returns an error result for the client, or `nothing` when valid.
"""
function validate_tool_arguments(tool_name::String, arguments::Dict{String,Any})
    idx = findfirst(d -> d["name"] == tool_name, tool_definitions())
    idx === nothing && return nothing

    schema = tool_definitions()[idx]["inputSchema"]
    missing_args = [
        name for name in get(schema, "required", String[])
        if !haskey(arguments, name) || arguments[name] === nothing
    ]
    isempty(missing_args) && return nothing

    return tool_result_error("Missing required argument(s) for $tool_name: $(join(missing_args, ", "))")
end

function handle_tool_call(state::AppState, tool_name::String, arguments::Dict{String,Any}; progress_token=nothing)
    invalid = validate_tool_arguments(tool_name, arguments)
    invalid === nothing || return invalid

    try
        if tool_name == "julia_set_workspace_folders"
            return tool_set_workspace_folders(state, arguments)
        elseif tool_name == "julia_close_workspace"
            return tool_close_workspace(state, arguments)
        elseif tool_name == "julia_update_file"
            return tool_update_file(state, arguments)
        elseif tool_name == "julia_get_diagnostics"
            return tool_get_diagnostics(state, arguments)
        elseif tool_name == "julia_format_file"
            return tool_format_file(state, arguments)
        elseif tool_name == "julia_list_testitems"
            return tool_list_testitems(state, arguments)
        elseif tool_name == "julia_run_testitems"
            return tool_run_testitems(state, arguments; progress_token=progress_token)
        elseif tool_name == "julia_rerun_failed"
            return tool_rerun_failed(state, arguments; progress_token=progress_token)
        elseif tool_name == "julia_cancel_testrun"
            return tool_cancel_testrun(state, arguments)
        elseif tool_name == "julia_get_testrun_results"
            return tool_get_testrun_results(state, arguments)
        elseif tool_name == "julia_get_testitem_detail"
            return tool_get_testitem_detail(state, arguments)
        elseif tool_name == "julia_list_testruns"
            return tool_list_testruns(state, arguments)
        elseif tool_name == "julia_list_test_processes"
            return tool_list_test_processes(state, arguments)
        elseif tool_name == "julia_terminate_test_process"
            return tool_terminate_test_process(state, arguments)
        elseif tool_name == "julia_get_process_output"
            return tool_get_process_output(state, arguments)
        elseif tool_name == "julia_terminate_all_processes"
            return tool_terminate_all_processes(state, arguments)
        elseif tool_name == "julia_get_coverage_results"
            return tool_get_coverage_results(state, arguments)
        elseif tool_name == "julia_create_session"
            return tool_create_session(state, arguments)
        elseif tool_name == "julia_eval_code"
            return tool_eval_code(state, arguments)
        elseif tool_name == "julia_interrupt_session"
            return tool_interrupt_session(state, arguments)
        elseif tool_name == "julia_kill_session"
            return tool_kill_session(state, arguments)
        elseif tool_name == "julia_list_sessions"
            return tool_list_sessions(state, arguments)
        elseif tool_name == "julia_profile_code"
            return tool_profile_code(state, arguments)
        elseif tool_name == "julia_get_session_variables"
            return tool_get_session_variables(state, arguments)
        else
            error("Unknown tool: $tool_name")
        end
    catch err
        err isa WorkspaceResolutionError || rethrow()
        return tool_result_error(err.message)
    end
end

# --- set_workspace_folders ---

function tool_set_workspace_folders(state::AppState, args::Dict{String,Any})
    folders = normalize_workspace_folders(args["folders"])
    id = workspace_id(folders)
    mcp_info(state, "tools", "Setting workspace folders: $folders")

    workspace = lock(state.lock) do
        found = get!(state.workspaces, id) do
            Workspace(copy(folders))
        end
        # Mark it as used under the same lock as the lookup. Then the idle reaper cannot
        # close it before the setup below.
        found.last_used_at = Dates.now()
        found
    end
    stop_watcher!(workspace)
    with_workspace_lock(workspace) do
        workspace.folders = copy(folders)
        workspace.workspace = JuliaWorkspaces.workspace_from_folders(folders; scope=WORKSPACE_SCOPE)
    end

    init_controller!(state, workspace)
    if something(get(args, "watch", nothing), true)
        start_watcher!(
            state,
            workspace;
            interval = something(get(args, "watch_interval", nothing), WATCH_INTERVAL_DEFAULT),
        )
    else
        stop_watcher!(workspace)
    end

    items = collect_testitems_list(state; workspace=workspace)
    errors = collect_detection_errors(state; workspace=workspace)
    # The setup can take a long time. Mark the workspace as used again, so that its idle
    # time starts at the end of the setup.
    lock(state.lock) do
        workspace.last_used_at = Dates.now()
    end

    notify_workspace_changed(state, workspace)

    text = "Workspace configured with $(length(folders)) folder(s), workspace_id=$id. " *
           "Detected $(length(items)) test item(s)"
    if !isempty(errors)
        text *= " and $(length(errors)) detection error(s)"
    end
    text *= "."

    return tool_result_text(text)
end

# --- close_workspace ---

function tool_close_workspace(state::AppState, args::Dict{String,Any})
    workspace = resolve_workspace(state, args)
    id = workspace_id_for(state, workspace)
    status = id === nothing ? :not_found : close_workspace!(state, id)
    if status === :active_runs
        runs = lock(state.lock) do
            active_run_ids(workspace)
        end
        return tool_result_error(
            "Workspace $id has active test runs: $(join(runs, ", ")). Cancel them with " *
            "julia_cancel_testrun or wait until they finish. Then call julia_close_workspace again.",
        )
    end
    status === :not_found && return tool_result_text("The workspace is already closed.")
    mcp_info(state, "tools", "Closed workspace $id")
    return tool_result_text(
        "Workspace $id is closed. Its test processes are stopped and its test runs are removed.",
    )
end

# --- update_file ---

function tool_update_file(state::AppState, args::Dict{String,Any})
    haskey(args, "path") && args["path"] !== nothing ||
        return tool_result_error("Missing required argument(s) for julia_update_file: path")

    path = args["path"]::String
    workspace = resolve_workspace(state, args)
    jw = workspace.workspace
    jw === nothing && return tool_result_error("Workspace not configured. Call julia_set_workspace_folders first.")

    with_workspace_lock(workspace) do
        JuliaWorkspaces.update_file_from_disc!(jw, path)
        haskey(workspace.watcher_snapshot, path) && (workspace.watcher_snapshot[path] = mtime(path))
    end

    notify_workspace_updated(state, workspace)

    return tool_result_text("File updated: $path")
end

# --- get_diagnostics ---

function tool_get_diagnostics(state::AppState, args::Dict{String,Any})
    workspace = resolve_workspace(state, args)
    jw = workspace.workspace
    jw === nothing && return tool_result_error("Workspace not configured. Call julia_set_workspace_folders first.")

    uri = with_workspace_lock(workspace) do
        haskey(args, "path") && args["path"] !== nothing ? resolve_uri(args["path"]::String) : nothing
    end
    if uri !== nothing && !with_workspace_lock(() -> JuliaWorkspaces.has_file(jw, uri), workspace)
        return tool_result_error("File is not part of the workspace: $(args["path"])")
    end

    result = try
        collect_diagnostics(
            state;
            workspace=workspace,
            uri=uri,
            severity=get(args, "severity", nothing),
            source=get(args, "source", nothing),
            max_results=something(get(args, "max_results", nothing), DIAGNOSTIC_LIMIT_DEFAULT),
            wait_for_ready=something(get(args, "wait_for_ready", nothing), false),
        )
    catch err
        return tool_result_error("Failed to collect diagnostics: $(sprint(showerror, err))")
    end

    return tool_result_json(result)
end
# --- format_file ---

function tool_format_file(state::AppState, args::Dict{String,Any})
    workspace = resolve_workspace(state, args)
    jw = workspace.workspace
    jw === nothing && return tool_result_error("Workspace not configured. Call julia_set_workspace_folders first.")

    path = args["path"]::String
    uri = with_workspace_lock(workspace) do
        resolve_uri(path)
    end
    with_workspace_lock(() -> JuliaWorkspaces.has_file(jw, uri), workspace) ||
        return tool_result_error("File is not part of the workspace: $path")

    start_line = get(args, "start_line", nothing)
    stop_line = get(args, "stop_line", nothing)
    if (start_line === nothing) != (stop_line === nothing)
        return tool_result_error("start_line and stop_line must be supplied together.")
    end

    edit = try
        with_workspace_lock(workspace) do
            start_line === nothing ?
                JuliaWorkspaces.get_format_edits(jw, uri) :
                JuliaWorkspaces.get_format_edits(jw, uri, start_line, stop_line)
        end
    catch err
        return tool_result_error("Formatting failed: $(sprint(showerror, err))")
    end

    if edit === nothing
        return tool_result_json(Dict{String,Any}(
            "uri" => string(uri),
            "edits" => [],
            "excluded" => true,
            "already_formatted" => false,
            "applied" => false,
        ))
    end

    result = file_edit_to_dict(edit)
    result["excluded"] = false
    result["already_formatted"] = isempty(edit.edits)

    if something(get(args, "apply", nothing), false) && !isempty(edit.edits)
        with_workspace_lock(workspace) do
            file_path = JuliaWorkspaces.uri2filepath(uri)
            content = JuliaWorkspaces.get_text_file(jw, uri).content
            write(file_path, apply_text_edits(content, edit.edits))
            JuliaWorkspaces.update_file_from_disc!(jw, file_path)
            haskey(workspace.watcher_snapshot, file_path) &&
                (workspace.watcher_snapshot[file_path] = mtime(file_path))
        end

        notify_workspace_updated(state, workspace)

        result["applied"] = true
    else
        result["applied"] = false
    end

    return tool_result_json(result)
end

# --- list_testitems ---

function tool_list_testitems(state::AppState, args::Dict{String,Any})
    workspace = resolve_workspace(state, args)
    filter = build_filter(args)
    items = collect_testitems_list(state; workspace=workspace, filter=filter)

    return tool_result_json(items)
end
# --- run_testitems ---

function tool_run_testitems(state::AppState, args::Dict{String,Any}; progress_token=nothing)
    workspace = resolve_workspace(state, args)

    max_wait = something(get(args, "max_wait_seconds", nothing), MAX_WAIT_SECONDS_DEFAULT)
    (max_wait isa Real && !(max_wait isa Bool) && isfinite(max_wait) && max_wait >= 0) ||
        return tool_result_error("max_wait_seconds must be a non-negative number of seconds.")
    max_wait = Float64(max_wait)

    init_controller!(state, workspace)

    filter = build_filter(args)
    d = discover(state; workspace=workspace, filter=filter)

    if isempty(d)
        return tool_result_text("No test items matched the given filter.")
    end
    items = d.testitems

    testrun_id = string(UUIDs.uuid4())
    timeout = filter !== nothing ? get(filter, :timeout, nothing) : nothing

    run_record = TestRunRecord(
        testrun_id,
        :running,
        args,
        Dict{String,TestItemResult}(
            item.id => TestItemResult(item.id, item.name, item.uri, :pending, nothing, Any[], String[])
            for item in items
        ),
        nothing,
        Dates.now(),
        nothing,
    )
    lock(state.lock) do
        workspace.runs[testrun_id] = run_record
    end
    notify_resource_list_changed(state)

    run_record.progress_token = progress_token
    if progress_token !== nothing
        notify_progress(state, progress_token, 0, length(items), "$(length(items)) test item(s) — starting")
        run_record.progress_value = 0.0
        start_heartbeat!(state, run_record)
    end

    mcp_info(state, "tools", "Starting test run $testrun_id with $(length(items)) item(s)")

    run = try
        r = TIR.run_async!(workspace.session, d;
            profiles = [run_profile(args)],
            timeout = timeout,
            fail_on_definition_error = false,
            id = testrun_id,
            run_options(args)...)
        lock(state.lock) do
            workspace.active_runs[testrun_id] = r
        end
        r
    catch e
        stop_heartbeat!(run_record)
        lock(state.lock) do
            finalize_run_status!(run_record, :errored)
        end
        mcp_error(state, "tools", "Test run $testrun_id failed to start: $e")
        return tool_result_error("Test run failed: $e")
    end

    if timedwait(() -> istaskdone(run), max_wait; pollint=0.1) === :ok
        summary = finish_run!(state, workspace, run_record, run)
        summary === nothing && return tool_result_error("Test run failed: $(run.error)")
        return tool_result_json(collect_run_payload(state, run_record, summary, args))
    end

    stop_heartbeat!(run_record)
    lock(state.lock) do
        run_record.progress_token = nothing
    end
    mcp_warn(state, "tools", "Test run $testrun_id still running after $(max_wait)s; returning early, the run continues")

    summary = lock(state.lock) do
        run_summary(run_record)
    end
    payload = collect_run_payload(state, run_record, summary, args)
    payload["waited_seconds"] = max_wait
    payload["message"] = running_message(summary, max_wait)

    @async try
        finish_run!(state, workspace, run_record, run)
    catch e
        @error "Finalizing test run $testrun_id after early return failed" exception = (e, catch_backtrace())
    end

    return tool_result_json(payload)
end

"""
Wait for `run` to finish and record its outcome on `run_record`.
"""
function finish_run!(
    state::AppState,
    workspace::Workspace,
    run_record::TestRunRecord,
    run::TIR.TestRun,
)
    testrun_id = run_record.id

    result = try
        fetch(run)
    catch e
        lock(state.lock) do
            finalize_run_status!(run_record, :errored)
        end
        mcp_error(state, "tools", "Test run $testrun_id failed: $e")
        return nothing
    finally
        stop_heartbeat!(run_record)
        lock(state.lock) do
            delete!(workspace.active_runs, testrun_id)
            # The idle time of the workspace starts when its run ends.
            workspace.last_used_at = Dates.now()
        end
    end

    lock(state.lock) do
        finalize_run_status!(run_record, run.status === :cancelled ? :cancelled : :completed)
        if result.coverage !== nothing
            run_record.coverage = coverage_to_dicts(result.coverage)
        end
    end

    summary = lock(state.lock) do
        run_summary(run_record)
    end

    report_progress!(state, run_record; final=true)
    run_record.progress_token = nothing

    notify_resource_updated(state, "testrun://$testrun_id/summary")
    notify_resource_updated(state, "testrun://$testrun_id/failures")

    mcp_info(state, "tools", "Test run $testrun_id completed: $(summary["passed"]) passed, $(summary["failed"]) failed, $(summary["errored"]) errored")

    return summary
end

"The `message` of an early-returned run: what happened, and what to do next."
function running_message(summary, max_wait::Float64)
    done = summary["passed"] + summary["failed"] + summary["errored"] + summary["skipped"]
    return "Still running after $(round(Int, max_wait)) s: $done of $(summary["total"]) item(s) finished, " *
           "$(summary["running"]) running, $(summary["pending"]) pending. The run has NOT been stopped and " *
           "continues in the background. Poll julia_get_testrun_results with testrun_id=\"$(summary["testrun_id"])\" " *
           "until status is no longer \"running\" (each poll returns immediately; leave time between polls), " *
           "or stop it with julia_cancel_testrun. If an item is hanging rather than slow, cancel and rerun " *
           "with a per-item timeout so it is errored and the rest of the suite completes."
end

"""
Compact result payload: a summary plus one status line per test item. Failure messages,
stack traces and captured output are deliberately excluded — they are unbounded, and a
broadly-failing suite would otherwise flood the caller's context. `julia_get_testitem_detail`
serves them on demand.
"""
function collect_run_payload(state::AppState, run::TestRunRecord, summary, args::Dict{String,Any})
    include_passing = something(get(args, "include_passing", nothing), false)
    max_items = something(get(args, "max_items", nothing), MAX_ITEMS_DEFAULT)

    selected, items_out, status = lock(state.lock) do
        selected = [
            item for item in values(run.items)
            if include_passing || item.status !== :passed
        ]
        sort!(selected, by = item -> (status_rank(item), item.label))
        (length(selected), testitem_status_dict.(first(selected, max_items)), run.status)
    end

    # `testrun_id` and `status` are also inside `summary`, but they are the two things a
    # caller reaches for first — and the running/finished distinction has to be trivially
    # visible in both this tool's and `julia_get_testrun_results`'s output.
    payload = Dict{String,Any}(
        "testrun_id" => run.id,
        "status" => string(status),
        "summary" => summary,
        "items" => items_out,
        "total_matching_items" => selected,
        "items_truncated" => selected > length(items_out),
        "detail_hint" => "Messages, stack traces and captured output are not included here. " *
                         "Call julia_get_testitem_detail with testrun_id=\"$(run.id)\" and " *
                         "testitem_ids=[...] for the items you want to inspect.",
    )
    if !include_passing
        payload["note"] = "Passing items are omitted; pass include_passing=true to list them."
    end
    if status === :running
        payload["in_progress_hint"] = "This run has not finished. Poll julia_get_testrun_results with " *
                                      "testrun_id=\"$(run.id)\" until status is no longer \"running\" (each call " *
                                      "returns at once), or stop the run with julia_cancel_testrun."
    end
    return payload
end

# --- rerun_failed ---

function tool_rerun_failed(state::AppState, args::Dict{String,Any}; progress_token=nothing)
    testrun_id = args["testrun_id"]::String
    workspace = haskey(args, "workspace_id") ?
        resolve_workspace(state, args) :
        find_workspace_for_run(state, testrun_id)
    workspace === nothing && return tool_result_error("Test run not found: $testrun_id")

    prev_run = lock(state.lock) do
        get(workspace.runs, testrun_id, nothing)
    end
    prev_run === nothing && return tool_result_error("Test run not found: $testrun_id")

    failed_ids = lock(state.lock) do
        [item.testitem_id for item in values(prev_run.items) if item.status in (:failed, :errored)]
    end
    isempty(failed_ids) && return tool_result_text("No failed or errored items in run $testrun_id.")

    new_args = copy(args)
    new_args["items"] = failed_ids
    new_args["workspace_id"] = workspace_id_for(state, workspace)
    for key in ("julia_cmd", "julia_args", "max_workers", "timeout", "mode", "max_wait_seconds", "julia_env", "log_level")
        if haskey(prev_run.profile_params, key) && !haskey(new_args, key)
            new_args[key] = prev_run.profile_params[key]
        end
    end

    return tool_run_testitems(state, new_args; progress_token=progress_token)
end

# --- cancel_testrun ---
function tool_cancel_testrun(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String
    workspace = haskey(args, "workspace_id") ?
        resolve_workspace(state, args) :
        find_workspace_for_run(state, testrun_id)
    workspace === nothing && return tool_result_error("No test run with ID: $testrun_id")

    run = lock(state.lock) do
        get(workspace.active_runs, testrun_id, nothing)
    end
    run === nothing && return tool_result_error("No active test run with ID: $testrun_id")

    TIR.cancel!(run)

    lock(state.lock) do
        record = get(workspace.runs, testrun_id, nothing)
        if record !== nothing
            finalize_run_status!(record, :cancelled)
            stop_heartbeat!(record)
        end
    end

    mcp_info(state, "tools", "Cancelled test run $testrun_id")
    return tool_result_text("Test run $testrun_id cancelled. Results collected so far stay available via julia_get_testrun_results.")
end

function tool_get_testrun_results(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String
    workspace = haskey(args, "workspace_id") ?
        resolve_workspace(state, args) :
        find_workspace_for_run(state, testrun_id)
    workspace === nothing && return tool_result_error("Test run not found: $testrun_id")

    run = lock(state.lock) do
        get(workspace.runs, testrun_id, nothing)
    end
    run === nothing && return tool_result_error("Test run not found: $testrun_id")

    summary = lock(state.lock) do
        run_summary(run)
    end

    return tool_result_json(collect_run_payload(state, run, summary, args))
end

# --- get_testitem_detail ---

function tool_get_testitem_detail(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String

    ids = String[]
    if haskey(args, "testitem_ids") && args["testitem_ids"] !== nothing
        append!(ids, convert(Vector{String}, args["testitem_ids"]))
    end
    if haskey(args, "testitem_id") && args["testitem_id"] !== nothing
        push!(ids, args["testitem_id"]::String)
    end
    unique!(ids)
    isempty(ids) && return tool_result_error("Provide testitem_ids (or testitem_id) for the items to inspect.")

    workspace = haskey(args, "workspace_id") ?
        resolve_workspace(state, args) :
        find_workspace_for_run(state, testrun_id)
    workspace === nothing && return tool_result_error("Test run not found: $testrun_id")
    run = lock(state.lock) do
        get(workspace.runs, testrun_id, nothing)
    end
    run === nothing && return tool_result_error("Test run not found: $testrun_id")

    max_output_bytes = something(get(args, "max_output_bytes", nothing), MAX_OUTPUT_BYTES_DEFAULT)
    max_messages = something(get(args, "max_messages", nothing), MAX_MESSAGES_DEFAULT)
    max_stack_frames = something(get(args, "max_stack_frames", nothing), MAX_STACK_FRAMES_DEFAULT)

    details = lock(state.lock) do
        [
            testitem_detail_dict(run, id, max_output_bytes, max_messages, max_stack_frames)
            for id in ids
        ]
    end

    return tool_result_json(details)
end

function testitem_detail_dict(run::TestRunRecord, testitem_id::String, max_output_bytes::Integer, max_messages::Integer, max_stack_frames::Integer)
    item = get(run.items, testitem_id, nothing)
    if item === nothing
        return Dict{String,Any}(
            "testitem_id" => testitem_id,
            "found" => false,
            "error" => "No such test item in run $(run.id).",
        )
    end

    output, output_bytes, output_truncated = truncate_output(item.output, max_output_bytes)

    return Dict{String,Any}(
        "testitem_id" => item.testitem_id,
        "found" => true,
        "label" => item.label,
        "uri" => item.uri,
        "status" => string(item.status),
        "duration" => item.duration,
        "messages" => [truncate_message(m, max_stack_frames) for m in first(item.messages, max_messages)],
        "messages_truncated" => length(item.messages) > max_messages,
        "total_messages" => length(item.messages),
        # stdout and stderr are interleaved into one stream by the test process.
        "output" => output,
        "output_truncated" => output_truncated,
        "output_total_bytes" => output_bytes,
        "output_resource" => "testrun://$(run.id)/items/$(item.testitem_id)/output",
    )
end

"""
Keep the tail of the captured output — a failure and its trailing context matter more than
whatever the test printed on the way in.
"""
function truncate_output(chunks::Vector{String}, max_bytes::Integer)
    text = join(chunks, "")
    total = sizeof(text)
    total <= max_bytes && return text, total, false
    tail = SubString(text, thisind(text, max(1, lastindex(text) - max_bytes + 1)))
    return "[… $(total - sizeof(tail)) bytes elided …]\n" * tail, total, true
end

function truncate_message(msg, max_stack_frames::Integer)
    frames = get(msg, "stack_trace", nothing)
    (frames === nothing || length(frames) <= max_stack_frames) && return msg
    out = copy(msg)
    out["stack_trace"] = first(frames, max_stack_frames)
    out["stack_trace_truncated"] = true
    out["total_stack_frames"] = length(frames)
    return out
end

# --- list_testruns ---

function tool_list_testruns(state::AppState, args::Dict{String,Any})
    workspace = resolve_workspace(state, args)
    runs = lock(state.lock) do
        [run_summary(run) for run in values(workspace.runs)]
    end
    return tool_result_json(runs)
end

# --- list_test_processes ---

function tool_list_test_processes(state::AppState, args::Dict{String,Any})
    workspace = resolve_workspace(state, args)
    procs = [
        Dict{String,Any}(
            "id" => p.id,
            "package_name" => p.package_name,
            "status" => p.status,
            "package_uri" => p.package_uri,
            "project_uri" => something(p.project_uri, ""),
        ) for p in list_test_processes(workspace)
    ]
    return tool_result_json(procs)
end

function tool_terminate_test_process(state::AppState, args::Dict{String,Any})
    process_id = args["process_id"]::String
    workspace = haskey(args, "workspace_id") ?
        resolve_workspace(state, args) :
        find_workspace_for_process(state, process_id)
    workspace === nothing && return tool_result_error("Test process not found: $process_id")
    workspace.session === nothing && return tool_result_error("Controller not initialized.")
    with_workspace_lock(workspace) do
        TIR.terminate_process!(workspace.session, process_id)
    end
    return tool_result_text("Process $process_id termination requested.")
end

function tool_get_process_output(state::AppState, args::Dict{String,Any})
    process_id = args["process_id"]::String
    workspace = haskey(args, "workspace_id") ?
        resolve_workspace(state, args) :
        find_workspace_for_process(state, process_id)
    workspace === nothing && return tool_result_error("Test process not found: $process_id")
    output = with_workspace_lock(workspace) do
        session = workspace.session
        session === nothing && return nothing
        any(p -> p.id == process_id, TIR.list_processes(session)) || return nothing
        TIR.process_output(session, process_id)
    end
    output === nothing && return tool_result_error("Test process not found: $process_id")
    max_output_bytes = something(get(args, "max_output_bytes", nothing), MAX_OUTPUT_BYTES_DEFAULT)
    text, _, _ = truncate_output([output], max_output_bytes)
    return tool_result_text(text)
end

function tool_terminate_all_processes(state::AppState, args::Dict{String,Any})
    workspace = resolve_workspace(state, args)
    count = with_workspace_lock(workspace) do
        session = workspace.session
        session === nothing && return 0
        n = length(TIR.list_processes(session))
        TIR.terminate_all_processes!(session)
        n
    end
    return tool_result_text("Termination requested for $count test process(es).")
end

# --- get_coverage_results ---

function tool_get_coverage_results(state::AppState, args::Dict{String,Any})
    testrun_id = args["testrun_id"]::String
    workspace = haskey(args, "workspace_id") ?
        resolve_workspace(state, args) :
        find_workspace_for_run(state, testrun_id)
    workspace === nothing && return tool_result_error("Test run not found: $testrun_id")

    coverage = lock(state.lock) do
        run = get(workspace.runs, testrun_id, nothing)
        run === nothing && return :not_found
        run.coverage === nothing && return :no_coverage
        run.coverage
    end
    coverage === :not_found && return tool_result_error("Test run not found: $testrun_id")
    coverage === :no_coverage && return tool_result_error("No coverage data. Was the run executed with mode=\"Coverage\"?")

    return tool_result_json(coverage)
end

# --- Helpers ---

"""Return the test processes of a workspace."""
function list_test_processes(workspace::Workspace)
    return with_workspace_lock(workspace) do
        session = workspace.session
        session === nothing ? TIR.ProcessInfo[] : TIR.list_processes(session)
    end
end

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
        # `coverage` has one entry per source line; `nothing` means not instrumentable.
        push!(dicts, Dict{String,Any}(
            "uri" => fc.uri,
            "lines" => [
                Dict{String,Any}("line" => i, "count" => c)
                for (i, c) in enumerate(fc.coverage) if c !== nothing
            ],
            "covered_lines" => count(c -> c !== nothing && c > 0, fc.coverage),
            "coverable_lines" => count(!isnothing, fc.coverage),
        ))
    end
    return dicts
end

# --- Julia sessions ---

const PROFILE_ENTRIES_DEFAULT = 25

function tool_create_session(state::AppState, args::Dict{String,Any})
    init_session_controller!(state)

    env = try
        build_session_environment(args)
    catch err
        return tool_result_error("Invalid session environment: $(sprint(showerror, err))")
    end

    session_id = try
        JSC.create_session(state.session_controller, env)
    catch err
        return tool_result_error("Failed to create session: $(sprint(showerror, err))")
    end

    rec = SessionRecord(session_id, env)
    lock(state.lock) do
        state.sessions[session_id] = rec
    end

    notify_resource_list_changed(state)
    return tool_result_json(session_dict(rec))
end

function tool_eval_code(state::AppState, args::Dict{String,Any})
    rec, err = session_record(state, args)
    rec === nothing && return err

    code = args["code"]::String
    request_id = string(UUIDs.uuid4())
    lock(state.lock) do
        rec.request_outputs[request_id] = String[]
        rec.last_used_at = Dates.now()
    end

    try
        if something(get(args, "revise", nothing), true)
            try
                JSC.revise!(state.session_controller, rec.id)
            catch revise_err
                mcp_warn(state, "session", "Revise failed in $(rec.id): $(sprint(showerror, revise_err))")
            end
        end

        result = JSC.evaluate(
            state.session_controller, rec.id, code;
            mod = something(get(args, "module", nothing), "Main"),
            timeout = get(args, "timeout", nothing),
            request_id = request_id,
        )

        payload = Dict{String,Any}(
            "session_id" => rec.id,
            "status" => string(result.status),
            "result" => result.inline,
            "result_type" => result.result_type,
            "elapsed" => result.elapsed,
        )
        if result.status === :error
            payload["error"] = result.all
            payload["stack_trace"] = [
                Dict{String,Any}("label" => f.label, "uri" => f.uri, "line" => f.line)
                for f in something(result.stack_frames, JSC.StackFrame[])
            ]
        end
        add_request_output!(payload, state, rec, request_id, args)
        return tool_result_json(payload)
    catch call_err
        return session_call_error(state, rec, request_id, args, call_err)
    finally
        lock(state.lock) do
            delete!(rec.request_outputs, request_id)
            # The idle time of the session starts when this evaluation ends.
            rec.last_used_at = Dates.now()
        end
    end
end

function tool_interrupt_session(state::AppState, args::Dict{String,Any})
    rec, err = session_record(state, args)
    rec === nothing && return err

    try
        JSC.interrupt_session(state.session_controller, rec.id)
    catch call_err
        return tool_result_error("Failed to interrupt session $(rec.id): $(sprint(showerror, call_err))")
    end
    return tool_result_text("Interrupt sent to session $(rec.id).")
end

function tool_kill_session(state::AppState, args::Dict{String,Any})
    rec, err = session_record(state, args)
    rec === nothing && return err

    try
        JSC.terminate_session(state.session_controller, rec.id)
    catch call_err
        return tool_result_error("Failed to terminate session $(rec.id): $(sprint(showerror, call_err))")
    end

    lock(state.lock) do
        delete!(state.sessions, rec.id)
    end
    notify_resource_list_changed(state)
    return tool_result_text("Session $(rec.id) terminated.")
end

function tool_list_sessions(state::AppState, args::Dict{String,Any})
    controller = state.session_controller
    live = controller === nothing ? JSC.SessionInfo[] : JSC.list_sessions(controller)
    by_id = Dict(info.id => info for info in live)

    sessions = lock(state.lock) do
        [session_dict(rec, get(by_id, rec.id, nothing)) for rec in values(state.sessions)]
    end
    sort!(sessions, by = d -> d["created_at"])
    return tool_result_json(sessions)
end

function tool_profile_code(state::AppState, args::Dict{String,Any})
    rec, err = session_record(state, args)
    rec === nothing && return err

    kind = something(get(args, "kind", nothing), "cpu")
    kind in ("cpu", "alloc") || return tool_result_error("profile kind must be \"cpu\" or \"alloc\", got \"$kind\".")

    request_id = string(UUIDs.uuid4())
    lock(state.lock) do
        rec.request_outputs[request_id] = String[]
        rec.last_used_at = Dates.now()
    end

    try
        result = JSC.profile(
            state.session_controller, rec.id, args["code"]::String;
            kind = Symbol(kind),
            mod = something(get(args, "module", nothing), "Main"),
            timeout = get(args, "timeout", nothing),
            request_id = request_id,
        )

        if result.status !== :success
            message = something(result.error, "Profiling is not supported by this session's Julia version.")
            return tool_result_error("Profiling failed: $message")
        end

        payload = Dict{String,Any}(
            "session_id" => rec.id,
            "kind" => kind,
            "total_samples" => result.total_samples,
            "hot_functions" => profile_hot_functions(
                result, something(get(args, "max_entries", nothing), PROFILE_ENTRIES_DEFAULT),
            ),
        )
        add_request_output!(payload, state, rec, request_id, args)
        return tool_result_json(payload)
    catch call_err
        return session_call_error(state, rec, request_id, args, call_err)
    finally
        lock(state.lock) do
            delete!(rec.request_outputs, request_id)
            # The idle time of the session starts when this profiling ends.
            rec.last_used_at = Dates.now()
        end
    end
end

function tool_get_session_variables(state::AppState, args::Dict{String,Any})
    rec, err = session_record(state, args)
    rec === nothing && return err

    variable_id = get(args, "variable_id", nothing)
    try
        variables = variable_id === nothing ?
            JSC.get_variables(
                state.session_controller, rec.id;
                mod = something(get(args, "module", nothing), "Main"),
                include_modules = something(get(args, "include_modules", nothing), false),
            ) :
            JSC.get_lazy(state.session_controller, rec.id, Int(variable_id))

        return tool_result_json([
            Dict{String,Any}(
                "name" => v.name,
                "type" => v.type,
                "value" => v.value,
                "lazy" => v.lazy,
                "has_children" => v.has_children,
                "variable_id" => v.id,
            ) for v in variables
        ])
    catch call_err
        return tool_result_error("Failed to inspect session $(rec.id): $(sprint(showerror, call_err))")
    end
end

"""
Attach the output a request produced, truncated to the caller's cap.
"""
function add_request_output!(payload::Dict{String,Any}, state::AppState, rec::SessionRecord,
    request_id::String, args::Dict{String,Any})
    max_bytes = something(get(args, "max_output_bytes", nothing), MAX_OUTPUT_BYTES_DEFAULT)
    chunks = lock(state.lock) do
        copy(get(rec.request_outputs, request_id, String[]))
    end
    text, total, truncated = truncate_output(chunks, max_bytes)
    payload["output"] = text
    payload["output_bytes"] = total
    truncated && (payload["output_truncated"] = true)
    return payload
end

"""
Turn a failed session request into a tool error that still carries whatever the code managed
to print — for a timeout that partial output is usually the only clue about where it hung.
"""
function session_call_error(state::AppState, rec::SessionRecord, request_id::String,
    args::Dict{String,Any}, err)
    payload = Dict{String,Any}(
        "session_id" => rec.id,
        "status" => "error",
        "error" => sprint(showerror, err),
    )
    if err isa JSC.RequestTimeoutException
        payload["timed_out"] = true
    elseif err isa JSC.SessionDiedException
        payload["session_died"] = true
        lock(state.lock) do
            haskey(state.sessions, rec.id) && (state.sessions[rec.id].alive = false)
        end
    end
    add_request_output!(payload, state, rec, request_id, args)
    return Dict{String,Any}(
        "content" => [Dict{String,Any}("type" => "text", "text" => JSON.json(payload))],
        "isError" => true,
    )
end

"""
Flatten a profile tree into the hottest functions. The tree itself is far too large to hand
to a model, and self time is what points at the code to change.
"""
function profile_hot_functions(result::JSC.ProfileResult, max_entries::Integer)
    self = Dict{String,Int}()
    total = Dict{String,Int}()
    location = Dict{String,String}()

    function visit(frame::JSC.ProfileFrame)
        key = frame.func
        child_counts = sum(c.count for c in frame.children; init=0)
        self[key] = get(self, key, 0) + max(frame.count - child_counts, 0)
        total[key] = get(total, key, 0) + frame.count
        get!(location, key, "$(frame.file):$(frame.line)")
        foreach(visit, frame.children)
    end

    threads = something(result.threads, Dict{String,JSC.ProfileFrame}())
    # The profiler reports each thread plus an "all" aggregate; walking both double-counts.
    roots = haskey(threads, "all") ? [threads["all"]] : collect(values(threads))
    foreach(visit, roots)

    keys_by_self = sort!(collect(keys(self)), by = k -> (self[k], total[k]), rev = true)
    return [
        Dict{String,Any}(
            "function" => k,
            "self_samples" => self[k],
            "total_samples" => total[k],
            "location" => location[k],
        ) for k in first(keys_by_self, max_entries)
    ]
end
