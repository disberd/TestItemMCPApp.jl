# mcp_resources.jl — MCP resource and resource template definitions

function resource_templates()
    return [
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/summary",
            "name" => "Julia Test Run Summary",
            "description" => "Summary of a Julia test run including pass/fail/error counts and timing.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/failures",
            "name" => "Julia Test Run Failures",
            "description" => "Failed and errored Julia test items with messages and stack traces.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/items/{testitem_id}/output",
            "name" => "Julia Test Item Output",
            "description" => "Full captured stdout/stderr for one Julia test item, untruncated. " *
                             "julia_get_testitem_detail caps its output; read this when that cap bites.",
            "mimeType" => "text/plain",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/coverage",
            "name" => "Julia Test Run Coverage",
            "description" => "Line-level Julia code coverage from a Coverage-mode test run.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testprocess://{process_id}/output",
            "name" => "Julia Test Worker Output",
            "description" => "Raw output of a Julia test worker process. This is where precompilation " *
                             "errors and process crashes surface, which no per-item detail can show.",
            "mimeType" => "text/plain",
        ),
        Dict{String,Any}(
            "uriTemplate" => "session://{session_id}/output",
            "name" => "Julia Session Output",
            "description" => "Recent output of a Julia session that was not attributed to a " *
                             "specific julia_eval_code call, such as printing from a background task.",
            "mimeType" => "text/plain",
        ),
        Dict{String,Any}(
            "uriTemplate" => "session://{session_id}/info",
            "name" => "Julia Session Info",
            "description" => "Status and environment of a Julia session.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "workspace://{workspace_id}/testitems",
            "name" => "Detected Julia Test Items",
            "description" => "All Julia test items (@testitem blocks) detected in one workspace.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "workspace://{workspace_id}/detection-errors",
            "name" => "Julia Test Item Detection Errors",
            "description" => "Errors encountered while detecting Julia test items in one workspace.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "workspace://{workspace_id}/diagnostics",
            "name" => "Julia Workspace Diagnostics",
            "description" => "Julia syntax errors and lint warnings across one workspace.",
            "mimeType" => "application/json",
        ),
    ]
end

"""
The URIs of the resources that show the state of the workspace with `id`.
"""
workspace_resource_uris(id::AbstractString) =
    ["workspace://$id/testitems", "workspace://$id/detection-errors", "workspace://$id/diagnostics"]

function dynamic_resources(state::AppState)
    res = Dict{String,Any}[]
    workspaces, sessions = lock(state.lock) do
        (collect(state.workspaces), collect(state.sessions))
    end
    for (_, workspace) in workspaces
        runs = lock(state.lock) do
            [(id, run.status) for (id, run) in workspace.runs]
        end
        for (id, status) in runs
            push!(res, Dict{String,Any}(
                "uri" => "testrun://$id/summary",
                "name" => "Run $id summary ($status)",
                "mimeType" => "application/json",
            ))
        end
        for p in list_test_processes(workspace)
            push!(res, Dict{String,Any}(
                "uri" => "testprocess://$(p.id)/output",
                "name" => "Process $(p.id) output ($(p.package_name), $(p.status))",
                "mimeType" => "text/plain",
            ))
        end
    end
    for (id, rec) in sessions
        push!(res, Dict{String,Any}(
            "uri" => "session://$id/info",
            "name" => "Session $id ($(rec.status))",
            "mimeType" => "application/json",
        ))
        push!(res, Dict{String,Any}(
            "uri" => "session://$id/output",
            "name" => "Session $id output",
            "mimeType" => "text/plain",
        ))
    end
    for (workspace_id, workspace) in sort(workspaces, by=first)
        folders = with_workspace_lock(workspace) do
            join(workspace.folders, ", ")
        end
        testitems_uri, errors_uri, diagnostics_uri = workspace_resource_uris(workspace_id)
        push!(res, Dict{String,Any}(
            "uri" => testitems_uri,
            "name" => "Detected Julia Test Items ($workspace_id)",
            "description" => "All Julia test items (@testitem blocks) detected in the workspace with folders: $folders",
            "mimeType" => "application/json",
        ))
        push!(res, Dict{String,Any}(
            "uri" => errors_uri,
            "name" => "Julia Test Item Detection Errors ($workspace_id)",
            "description" => "Errors encountered while detecting Julia test items in the workspace with folders: $folders",
            "mimeType" => "application/json",
        ))
        push!(res, Dict{String,Any}(
            "uri" => diagnostics_uri,
            "name" => "Julia Workspace Diagnostics ($workspace_id)",
            "description" => "Julia syntax errors and lint warnings across the workspace with folders: $folders",
            "mimeType" => "application/json",
        ))
    end
    return res
end

function handle_resources_list(state::AppState, params)
    return Dict{String,Any}("resources" => dynamic_resources(state))
end

function handle_resource_templates_list(state::AppState, params)
    return Dict{String,Any}("resourceTemplates" => resource_templates())
end

function handle_resources_read(state::AppState, params::Dict)
    uri = params["uri"]::String
    contents = read_resource(state, uri)
    return Dict{String,Any}("contents" => contents)
end

function resource_workspace(state::AppState, uri::String, id::AbstractString)
    try
        return resolve_workspace(state, Dict{String,Any}("workspace_id" => id))
    catch err
        err isa WorkspaceResolutionError || rethrow()
        throw(ResourceNotFound(uri, err.message))
    end
end

function resource_run(state::AppState, uri::String, run_id::AbstractString)
    run_key = String(run_id)
    workspace = find_workspace_for_run(state, run_key)
    workspace === nothing && throw(ResourceNotFound(uri, "Test run not found: $run_id"))
    run = lock(state.lock) do
        get(workspace.runs, run_key, nothing)
    end
    run === nothing && throw(ResourceNotFound(uri, "Test run not found: $run_id"))
    return workspace, run
end

function read_resource(state::AppState, uri::String)
    m = match(r"^workspace://([^/]+)/(testitems|detection-errors|diagnostics)$", uri)
    if m !== nothing
        workspace = resource_workspace(state, uri, m[1])
        data = if m[2] == "testitems"
            collect_testitems_list(state; workspace=workspace)
        elseif m[2] == "detection-errors"
            collect_detection_errors(state; workspace=workspace)
        else
            collect_diagnostics(state; workspace=workspace)
        end
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(data))]
    end

    m = match(r"^testrun://([^/]+)/summary$", uri)
    if m !== nothing
        run_id = String(m[1])
        _, run = resource_run(state, uri, run_id)
        summary = lock(state.lock) do
            run_summary(run)
        end
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(summary))]
    end

    m = match(r"^testrun://([^/]+)/failures$", uri)
    if m !== nothing
        run_id = String(m[1])
        _, run = resource_run(state, uri, run_id)
        failures = lock(state.lock) do
            [
                Dict{String,Any}(
                    "testitem_id" => item.testitem_id,
                    "label" => item.label,
                    "uri" => item.uri,
                    "status" => string(item.status),
                    "duration" => item.duration,
                    "messages" => item.messages,
                ) for item in values(run.items) if item.status in (:failed, :errored)
            ]
        end
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(failures))]
    end

    m = match(r"^testrun://([^/]+)/items/([^/]+)/output$", uri)
    if m !== nothing
        run_id, item_id = String(m[1]), String(m[2])
        _, run = resource_run(state, uri, run_id)
        output = lock(state.lock) do
            item = get(run.items, item_id, nothing)
            item === nothing ? nothing : join(item.output, "")
        end
        output === nothing && throw(ResourceNotFound(uri, "Test item not found: $item_id in run $run_id"))
        return [Dict{String,Any}("uri" => uri, "mimeType" => "text/plain", "text" => output)]
    end

    m = match(r"^testrun://([^/]+)/coverage$", uri)
    if m !== nothing
        run_id = String(m[1])
        _, run = resource_run(state, uri, run_id)
        coverage = lock(state.lock) do
            run.coverage
        end
        coverage === nothing && throw(ResourceNotFound(uri, "No coverage data for run: $run_id"))
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(coverage))]
    end

    m = match(r"^testprocess://([^/]+)/output$", uri)
    if m !== nothing
        process_id = String(m[1])
        workspace = find_workspace_for_process(state, process_id)
        workspace === nothing && throw(ResourceNotFound(uri, "Test process not found: $process_id"))
        output = with_workspace_lock(workspace) do
            session = workspace.session
            session === nothing ? nothing : TIR.process_output(session, process_id)
        end
        output === nothing && throw(ResourceNotFound(uri, "Test process not found: $process_id"))
        return [Dict{String,Any}("uri" => uri, "mimeType" => "text/plain", "text" => output)]
    end

    # session://{id}/output
    m = match(r"^session://([^/]+)/output$", uri)
    if m !== nothing
        session_id = String(m[1])
        output = lock(state.lock) do
            rec = get(state.sessions, session_id, nothing)
            rec === nothing ? nothing : join(rec.output, "")
        end
        output === nothing && throw(ResourceNotFound(uri, "Session not found: $session_id"))
        return [Dict{String,Any}("uri" => uri, "mimeType" => "text/plain", "text" => output)]
    end

    # session://{id}/info
    m = match(r"^session://([^/]+)/info$", uri)
    if m !== nothing
        session_id = String(m[1])
        info = lock(state.lock) do
            rec = get(state.sessions, session_id, nothing)
            rec === nothing ? nothing : session_dict(rec)
        end
        info === nothing && throw(ResourceNotFound(uri, "Session not found: $session_id"))
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(info))]
    end

    throw(ResourceNotFound(uri, "Unknown resource URI: $uri"))
end

function handle_resources_subscribe(state::AppState, params::Dict)
    uri = params["uri"]::String
    lock(state.lock) do
        push!(state.subscriptions, uri)
    end
    return Dict{String,Any}()
end

function handle_resources_unsubscribe(state::AppState, params::Dict)
    uri = params["uri"]::String
    lock(state.lock) do
        delete!(state.subscriptions, uri)
    end
    return Dict{String,Any}()
end
