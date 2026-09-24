# watcher.jl — Keep the workspace in sync with on-disc changes

const WATCH_INTERVAL_DEFAULT = 1.0
const WATCH_DEBOUNCE_DEFAULT = 0.25

"""
Whether changes to `path` can affect analysis results.
"""
function is_watched_path(path::AbstractString)
    return JuliaWorkspaces.is_path_julia_file(path) ||
        JuliaWorkspaces.is_path_project_file(path) ||
        JuliaWorkspaces.is_path_manifest_file(path) ||
        JuliaWorkspaces.is_path_toolconfig_file(path)
end

"""
Build a `path => mtime` snapshot of every analysis-relevant file under `folders`.

The walk is `JuliaWorkspaces`' own, under the same [`WORKSPACE_SCOPE`](@ref) the
workspace was built with. Sharing it is what keeps the two in agreement: a
private walk here would re-add files the scoped workspace walk deliberately
skipped, and would miss changes in directories it skipped but the workspace did
not.
"""
function _scan_folders(folders)
    snapshot = Dict{String,Float64}()
    for folder in folders
        isdir(folder) || continue
        for path in JuliaWorkspaces.collect_workspace_paths(folder; scope=WORKSPACE_SCOPE)
            is_watched_path(path) || continue
            try
                snapshot[path] = mtime(path)
            catch
                # File vanished between the walk and the stat.
            end
        end
    end
    return snapshot
end


function scan_folders(workspace::Workspace)
    return with_workspace_lock(workspace) do
        _scan_folders(workspace.folders)
    end
end

"""
Compare two snapshots. Returns `(created, modified, deleted)` path vectors.
"""
function diff_snapshots(old::Dict{String,Float64}, new::Dict{String,Float64})
    created = String[]
    modified = String[]
    for (path, stamp) in new
        if !haskey(old, path)
            push!(created, path)
        elseif old[path] != stamp
            push!(modified, path)
        end
    end
    deleted = String[path for path in keys(old) if !haskey(new, path)]
    return sort!(created), sort!(modified), sort!(deleted)
end

"""
Apply on-disc changes to a workspace. Returns the number of files applied.
"""
function apply_file_changes!(state::AppState, workspace::Workspace, created, modified, deleted)
    applied = 0
    with_workspace_lock(workspace) do
        jw = workspace.workspace
        jw === nothing && return
        for path in Iterators.flatten((created, modified))
            uri = JuliaWorkspaces.filepath2uri(path)
            try
                if JuliaWorkspaces.has_file(jw, uri)
                    JuliaWorkspaces.update_file_from_disc!(jw, path)
                else
                    JuliaWorkspaces.add_file_from_disc!(jw, path)
                end
                applied += 1
            catch err
                mcp_debug(state, "watcher", "Failed to refresh $path: $(sprint(showerror, err))")
            end
        end
        for path in deleted
            uri = JuliaWorkspaces.filepath2uri(path)
            try
                if JuliaWorkspaces.has_file(jw, uri)
                    JuliaWorkspaces.remove_file!(jw, uri)
                    applied += 1
                end
            catch err
                mcp_debug(state, "watcher", "Failed to remove $path: $(sprint(showerror, err))")
            end
        end
    end
    return applied
end

"""
Notify subscribers that the resources of `workspace` changed.
"""
function notify_workspace_updated(state::AppState, workspace::Workspace)
    id = workspace_id_for(state, workspace)
    id === nothing && return
    foreach(uri -> notify_resource_updated(state, uri), workspace_resource_uris(id))
end

"""
Notify subscribers that the resource list and the resources of `workspace` changed.
"""
function notify_workspace_changed(state::AppState, workspace::Workspace)
    notify_resource_list_changed(state)
    notify_workspace_updated(state, workspace)
end

"""
Apply a batch of changes and notify subscribers.
"""
function handle_file_changes!(state::AppState, workspace::Workspace, created, modified, deleted)
    applied = apply_file_changes!(state, workspace, created, modified, deleted)
    applied == 0 && return 0

    mcp_debug(state, "watcher",
        "Workspace refreshed: $(length(created)) added, $(length(modified)) changed, $(length(deleted)) removed")
    notify_workspace_changed(state, workspace)
    return applied
end

function watch_loop(
    state::AppState,
    workspace::Workspace,
    stop::Ref{Bool},
    interval::Float64,
    debounce::Float64,
)
    while !stop[]
        sleep(interval)
        stop[] && break
        try
            old_snapshot = with_workspace_lock(workspace) do
                copy(workspace.watcher_snapshot)
            end
            current = scan_folders(workspace)
            created, modified, deleted = diff_snapshots(old_snapshot, current)
            (isempty(created) && isempty(modified) && isempty(deleted)) && continue

            sleep(debounce)
            stop[] && break
            current = scan_folders(workspace)
            old_snapshot = with_workspace_lock(workspace) do
                copy(workspace.watcher_snapshot)
            end
            created, modified, deleted = diff_snapshots(old_snapshot, current)
            with_workspace_lock(workspace) do
                workspace.watcher_snapshot = current
            end

            handle_file_changes!(state, workspace, created, modified, deleted)
        catch err
            mcp_debug(state, "watcher", "Watch cycle failed: $(sprint(showerror, err))")
        end
    end
end

"""
Start one watcher for a workspace.
"""
# ponytail: N workspaces mean N pollers. Upgrade to one shared snapshot per folder when polling cost matters.
function start_watcher!(
    state::AppState,
    workspace::Workspace;
    interval=WATCH_INTERVAL_DEFAULT,
    debounce=WATCH_DEBOUNCE_DEFAULT,
)
    stop_watcher!(workspace)
    folders = with_workspace_lock(workspace) do
        copy(workspace.folders)
    end
    isempty(folders) && return nothing

    snapshot = scan_folders(workspace)
    stop = Ref(false)
    with_workspace_lock(workspace) do
        workspace.watcher_snapshot = snapshot
        workspace.watcher_stop = stop
    end
    task = @async watch_loop(state, workspace, stop, Float64(interval), Float64(debounce))
    with_workspace_lock(workspace) do
        workspace.watcher_task = task
    end
    mcp_debug(state, "watcher", "Watching $(length(folders)) folder(s) every $(interval)s")
    return task
end

function stop_watcher!(workspace::Workspace)
    with_workspace_lock(workspace) do
        workspace.watcher_stop === nothing || (workspace.watcher_stop[] = true)
        workspace.watcher_stop = nothing
        workspace.watcher_task = nothing
    end
    return nothing
end

function stop_watcher!(state::AppState)
    workspaces = lock(state.lock) do
        collect(values(state.workspaces))
    end
    foreach(stop_watcher!, workspaces)
    return nothing
end
