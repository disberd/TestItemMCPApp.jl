# callbacks.jl — TestItemRuns event sink: MCP notifications, progress and run bookkeeping

handle_event(state::AppState, workspace::Workspace, ::TIR.RunEvent) = nothing

function _run_item(
    state::AppState,
    workspace::Workspace,
    run::TIR.TestRun,
    item::TIR.TestItem,
)
    rec = get(workspace.runs, run.id, nothing)
    rec === nothing && return nothing
    return get(rec.items, item.id, nothing)
end

function handle_event(state::AppState, workspace::Workspace, ev::TIR.TestItemStarted)
    lock(state.lock) do
        item = _run_item(state, workspace, ev.run, ev.item)
        item === nothing && return
        item.status = :running
    end
    mcp_info(state, "testitem", "Started: $(ev.item.name)")
    notify_resource_updated(state, "testrun://$(ev.run.id)/summary")
end

function handle_event(state::AppState, workspace::Workspace, ev::TIR.TestItemFinished)
    lock(state.lock) do
        item = _run_item(state, workspace, ev.run, ev.item)
        item === nothing && return
        item.status = ev.status
        item.duration = ev.duration
        if ev.messages !== nothing
            item.messages = [testmessage_to_dict(m) for m in ev.messages]
        end
    end
    label = ev.item.name
    dur_str = ev.duration !== nothing ? " ($(round(ev.duration, digits=2))ms)" : ""
    msg_summary = ev.messages === nothing || isempty(ev.messages) ? "" : ": $(first(ev.messages).message)"
    if ev.status === :passed
        mcp_info(state, "testitem", "Passed: $label$dur_str")
    elseif ev.status === :failed
        mcp_warn(state, "testitem", "Failed: $label$dur_str$msg_summary")
    elseif ev.status === :errored
        mcp_error(state, "testitem", "Errored: $label$dur_str$msg_summary")
    else
        mcp_info(state, "testitem", "Skipped: $label")
    end
    report_run_progress(state, workspace, ev.run.id)
    notify_resource_updated(state, "testrun://$(ev.run.id)/summary")
    ev.status in (:passed, :failed, :errored) &&
        notify_resource_updated(state, "testrun://$(ev.run.id)/failures")
end

function handle_event(state::AppState, workspace::Workspace, ev::TIR.OutputAppended)
    lock(state.lock) do
        item = _run_item(state, workspace, ev.run, ev.item)
        item === nothing && return
        push!(item.output, ev.output)
    end
    notify_resource_updated(state, "testrun://$(ev.run.id)/items/$(ev.item.id)/output")
end

function handle_event(state::AppState, workspace::Workspace, ev::TIR.ProcessCreated)
    mcp_notice(state, "controller", "Process created for $(ev.package_name) (id=$(ev.id))")
    note_run_progress(state, workspace, "starting test process for $(ev.package_name)")
    notify_resource_list_changed(state)
end

function handle_event(state::AppState, workspace::Workspace, ev::TIR.ProcessTerminated)
    mcp_notice(state, "controller", "Process terminated (id=$(ev.id))")
    notify_resource_list_changed(state)
end

function handle_event(state::AppState, workspace::Workspace, ev::TIR.ProcessStatusChanged)
    mcp_debug(state, "controller", "Process $(ev.id): $(ev.status)")
    note_run_progress(state, workspace, "test process $(ev.status)")
end

function handle_event(state::AppState, workspace::Workspace, ev::TIR.ProcessOutput)
    mcp_debug(state, "controller", ev.output)
end

function report_run_progress(state::AppState, workspace::Workspace, testrun_id::String)
    run = lock(state.lock) do
        get(workspace.runs, testrun_id, nothing)
    end
    run === nothing && return
    report_progress!(state, run)
end

function note_run_progress(state::AppState, workspace::Workspace, note::String)
    lock(state.lock) do
        for run in values(workspace.runs)
            run.status === :running && (run.progress_note = note)
        end
    end
end

"""
Create the TestItemRuns session for a workspace.
"""
function init_controller!(state::AppState, workspace::Workspace)
    created = false
    lock(state.lock) do
        session = workspace.session
        if session === nothing || !isopen(session)
            workspace.session = TIR.TestSession(; on_event=ev -> handle_event(state, workspace, ev), max_history=nothing)
            created = true
        end
    end
    created && mcp_notice(state, "transport", "TestItemController initialized")
    return workspace.session
end

function shutdown_controller!(state::AppState, workspace::Workspace)
    session = workspace.session
    session === nothing && return
    close(session)
    lock(state.lock) do
        workspace.session = nothing
        empty!(workspace.active_runs)
    end
end

function init_controller!(state::AppState)
    return init_controller!(state, resolve_workspace(state, Dict{String,Any}()))
end

function shutdown_controller!(state::AppState)
    workspaces = lock(state.lock) do
        collect(values(state.workspaces))
    end
    foreach(workspace -> shutdown_controller!(state, workspace), workspaces)
end
