# reaper.jl: close the idle workspaces, kill the idle sessions, and remove the idle clients

const IDLE_TIMEOUT_SECS_DEFAULT = 3600

"""
Return the idle timeout in seconds from the `JULIAMCP_IDLE_TIMEOUT_SECS` environment
variable. The default is one hour. Zero turns the reaper off.
"""
function idle_timeout_secs()
    value = get(ENV, "JULIAMCP_IDLE_TIMEOUT_SECS", string(IDLE_TIMEOUT_SECS_DEFAULT))
    secs = tryparse(Int, value)
    (secs === nothing || secs < 0) &&
        error("JULIAMCP_IDLE_TIMEOUT_SECS must be 0 or a positive whole number of seconds, not \"$value\".")
    return secs
end

"""
Return the sorted ids of the test runs of `workspace` that are still running. Hold
`state.lock` while you call it.
"""
active_run_ids(workspace::Workspace) =
    sort!([id for (id, run) in workspace.runs if run.status === :running])

"""
Close the workspace `id`. Remove it from `state`, stop its watcher and close its test
session. Closing the test session stops the test processes of the workspace. The test
run records go away with the workspace.

A workspace with an active test run stays open, unless `force` is true. Then closing
cancels the run. When `last_used_before` is a time, a workspace that a client used at
that time or later also stays open.

Only the caller that removes the workspace from `state` closes it. Return `:closed` when
this call closed the workspace. Else return why it did not: `:not_found`, `:in_use` or
`:active_runs`.
"""
function close_workspace!(state::AppState, id::AbstractString; force::Bool=false, last_used_before=nothing)
    # ponytail: a call that found the workspace before this removal can still start a test
    # session on it, and nothing closes that session. Add a closed flag that
    # `init_controller!` checks if agents close workspaces that other agents still use.
    workspace = lock(state.lock) do
        candidate = get(state.workspaces, id, nothing)
        candidate === nothing && return :not_found
        last_used_before === nothing || candidate.last_used_at < last_used_before || return :in_use
        force || isempty(active_run_ids(candidate)) || return :active_runs
        return pop!(state.workspaces, id)
    end
    workspace isa Symbol && return workspace
    stop_watcher!(workspace)
    shutdown_controller!(state, workspace)
    notify_resource_list_changed(state)
    return :closed
end

"""
Remove the client `id` from `state`, end its GET stream and kill the sessions that it
created. This is the effect of `DELETE`. When `idle_before` is a time, keep a client that
has an open request, or whose last request ended at that time or later.

Return whether this call removed the client.
"""
function remove_client!(state::AppState, id::AbstractString; idle_before=nothing)
    removed = lock(state.lock) do
        client = get(state.clients, id, nothing)
        client === nothing && return nothing
        idle_before === nothing ||
            (client.last_used_at < idle_before && isempty(client.requests)) ||
            return nothing
        delete!(state.clients, id)
        sessions = [session_id for (session_id, rec) in state.sessions if rec.client_id == id]
        foreach(session_id -> delete!(state.sessions, session_id), sessions)
        (; outbox = client.outbox, sessions)
    end
    removed === nothing && return false
    removed.outbox isa Outbox && close(removed.outbox)
    for session_id in removed.sessions
        JSC.terminate_session(state.session_controller, session_id)
        mcp_info(state, "session", "Killed session $session_id of client $id")
    end
    isempty(removed.sessions) || notify_resource_list_changed(state)
    return true
end

"""
Close each workspace and kill each session that no client used in the last
`timeout_secs` seconds. Keep a workspace while it has an active test run. Keep a session
while it has a queued or running request.

When `clients` is true, also remove each client that had no open request in the last
`timeout_secs` seconds, as [`remove_client!`](@ref) does.
"""
function reap_idle!(state::AppState, timeout_secs::Integer; clients::Bool=false)
    limit = Dates.now() - Dates.Second(timeout_secs)

    if clients
        client_ids = lock(state.lock) do
            [id for (id, client) in state.clients if client.last_used_at < limit]
        end
        for id in client_ids
            remove_client!(state, id; idle_before=limit) &&
                mcp_info(state, "reaper", "Removed idle client $id")
        end
    end

    workspace_ids = lock(state.lock) do
        [id for (id, workspace) in state.workspaces if workspace.last_used_at < limit]
    end
    for id in workspace_ids
        close_workspace!(state, id; last_used_before=limit) === :closed &&
            mcp_info(state, "reaper", "Closed idle workspace $id")
    end

    controller = state.session_controller
    controller === nothing && return
    # Do not hold `state.lock` while you ask the controller. Its callbacks take that lock.
    busy = Set(
        info.id for info in JSC.list_sessions(controller)
        if info.queued_requests > 0 || info.current_request !== nothing
    )
    session_ids = lock(state.lock) do
        idle = [id for (id, rec) in state.sessions if rec.last_used_at < limit && !(id in busy)]
        foreach(id -> delete!(state.sessions, id), idle)
        idle
    end
    for id in session_ids
        JSC.terminate_session(controller, id)
        mcp_info(state, "reaper", "Killed idle session $id")
    end
    isempty(session_ids) || notify_resource_list_changed(state)
    return
end

"""
Start the task that calls [`reap_idle!`](@ref) every `max(1, timeout_secs ÷ 4)` seconds,
with `clients`. Return `nothing` when `timeout_secs` is zero, because zero turns the reaper
off. To stop the reaper, close its `timer` and then wait for its `task`.
"""
function start_reaper(state::AppState, timeout_secs::Integer; clients::Bool=false)
    timeout_secs > 0 || return nothing
    interval = max(1, timeout_secs ÷ 4)
    timer = Timer(interval; interval)
    task = @async while true
        try
            wait(timer)
        catch
            break  # `wait` throws after `close(timer)`.
        end
        isopen(timer) || break
        try
            reap_idle!(state, timeout_secs; clients)
        catch err
            @error "Idle reaper failed" exception = (err, catch_backtrace())
        end
    end
    return (; timer, task)
end
