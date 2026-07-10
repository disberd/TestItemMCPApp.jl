# mcp_resources.jl — MCP resource and resource template definitions

function resource_templates()
    return [
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/summary",
            "name" => "Test Run Summary",
            "description" => "Summary of a test run including pass/fail/error counts and timing.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/failures",
            "name" => "Test Run Failures",
            "description" => "Failed and errored test items with messages and stack traces.",
            "mimeType" => "application/json",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/items/{testitem_id}/output",
            "name" => "Test Item Output",
            "description" => "Captured stdout/stderr for a specific test item.",
            "mimeType" => "text/plain",
        ),
        Dict{String,Any}(
            "uriTemplate" => "testrun://{testrun_id}/coverage",
            "name" => "Test Run Coverage",
            "description" => "Line-level code coverage from a Coverage-mode test run.",
            "mimeType" => "application/json",
        ),
    ]
end

function dynamic_resources(state::AppState)
    res = Dict{String,Any}[]
    lock(state.lock) do
        for (sid, session) in state.sessions
            lock(session.lock) do
                for (id, run) in session.runs
                    push!(res, Dict{String,Any}(
                        "uri" => "testrun://$id/summary",
                        "name" => "Run $id summary ($(run.status))",
                        "mimeType" => "application/json",
                    ))
                end
            end
            push!(res, Dict{String,Any}(
                "uri" => "workspace://$(sid)/testitems",
                "name" => "Detected Test Items (session $sid)",
                "description" => "All test items detected in session $sid.",
                "mimeType" => "application/json",
            ))
            push!(res, Dict{String,Any}(
                "uri" => "workspace://$(sid)/detection-errors",
                "name" => "Detection Errors (session $sid)",
                "description" => "Errors encountered during test item detection in session $sid.",
                "mimeType" => "application/json",
            ))
        end
    end
    return res
end

function find_session_for_testrun(state::AppState, testrun_id::String)
    lock(state.lock) do
        for (_, session) in state.sessions
            run = lock(session.lock) do
                get(session.runs, testrun_id, nothing)
            end
            run !== nothing && return session
        end
        return nothing
    end
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

function read_resource(state::AppState, uri::String)
    # workspace://{session_id}/testitems
    m = match(r"^workspace://([^/]+)/testitems$", uri)
    if m !== nothing
        sid = m[1]
        session = lock(state.lock) do
            get(state.sessions, sid, nothing)
        end
        session === nothing && error("Unknown session: $sid")
        items = collect_testitems_list(session)
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(items))]
    end

    # workspace://{session_id}/detection-errors
    m = match(r"^workspace://([^/]+)/detection-errors$", uri)
    if m !== nothing
        sid = m[1]
        session = lock(state.lock) do
            get(state.sessions, sid, nothing)
        end
        session === nothing && error("Unknown session: $sid")
        errors = collect_detection_errors(session)
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(errors))]
    end

    # testrun://{id}/summary
    m = match(r"^testrun://([^/]+)/summary$", uri)
    if m !== nothing
        run_id = m[1]
        session = find_session_for_testrun(state, run_id)
        session === nothing && error("Test run not found: $run_id")
        summary = lock(session.lock) do
            run = session.runs[run_id]
            run_summary(run)
        end
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(summary))]
    end

    # testrun://{id}/failures
    m = match(r"^testrun://([^/]+)/failures$", uri)
    if m !== nothing
        run_id = m[1]
        session = find_session_for_testrun(state, run_id)
        session === nothing && error("Test run not found: $run_id")
        failures = lock(session.lock) do
            run = session.runs[run_id]
            [
                Dict{String,Any}(
                    "testitem_id" => item.testitem_id,
                    "label" => item.label,
                    "uri" => item.uri,
                    "status" => string(item.status),
                    "duration_ms" => item.duration,
                    "messages" => item.messages,
                ) for item in values(run.items) if item.status in (:failed, :errored)
            ]
        end
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(failures))]
    end

    # testrun://{id}/items/{item_id}/output
    m = match(r"^testrun://([^/]+)/items/([^/]+)/output$", uri)
    if m !== nothing
        run_id, item_id = m[1], m[2]
        session = find_session_for_testrun(state, run_id)
        session === nothing && error("Test run not found: $run_id")
        output = lock(session.lock) do
            run = session.runs[run_id]
            item = get(run.items, item_id, nothing)
            item === nothing && return nothing
            join(item.output, "")
        end
        output === nothing && error("Test item not found: $item_id in run $run_id")
        return [Dict{String,Any}("uri" => uri, "mimeType" => "text/plain", "text" => output)]
    end

    # testrun://{id}/coverage
    m = match(r"^testrun://([^/]+)/coverage$", uri)
    if m !== nothing
        run_id = m[1]
        session = find_session_for_testrun(state, run_id)
        session === nothing && error("Test run not found: $run_id")
        coverage = lock(session.lock) do
            run = session.runs[run_id]
            run.coverage
        end
        coverage === nothing && error("No coverage data for run: $run_id")
        return [Dict{String,Any}("uri" => uri, "mimeType" => "application/json", "text" => JSON.json(coverage))]
    end

    error("Unknown resource URI: $uri")
end

function handle_resources_subscribe(state::AppState, params::Dict)
    uri = params["uri"]::String
    # Subscriptions are session-scoped for workspace URIs, but testrun URIs
    # are globally unique so we store on the matching session.
    m = match(r"^workspace://([^/]+)/", uri)
    if m !== nothing
        sid = m[1]
        session = lock(state.lock) do
            get(state.sessions, sid, nothing)
        end
        if session !== nothing
            lock(session.lock) do
                push!(session.subscriptions, uri)
            end
        end
        return Dict{String,Any}()
    end
    # For testrun URIs, find the session and subscribe there
    m_run = match(r"^testrun://([^/]+)/", uri)
    if m_run !== nothing
        session = find_session_for_testrun(state, m_run[1])
        if session !== nothing
            lock(session.lock) do
                push!(session.subscriptions, uri)
            end
        end
    end
    return Dict{String,Any}()
end

function handle_resources_unsubscribe(state::AppState, params::Dict)
    uri = params["uri"]::String
    m = match(r"^workspace://([^/]+)/", uri)
    if m !== nothing
        sid = m[1]
        session = lock(state.lock) do
            get(state.sessions, sid, nothing)
        end
        if session !== nothing
            lock(session.lock) do
                delete!(session.subscriptions, uri)
            end
        end
        return Dict{String,Any}()
    end
    m_run = match(r"^testrun://([^/]+)/", uri)
    if m_run !== nothing
        session = find_session_for_testrun(state, m_run[1])
        if session !== nothing
            lock(session.lock) do
                delete!(session.subscriptions, uri)
            end
        end
    end
    return Dict{String,Any}()
end
