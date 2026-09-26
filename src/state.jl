# state.jl — Application state

# One workspace here serves diagnostics, formatting and test-item queries alike,
# so the folder walk may only skip a directory all three config files exclude.
# `JuliaWorkspaces` composes the kinds as a union, and a kind with no config file
# of its own selects everything — so this prunes nothing until a project actually
# writes the configs.
const WORKSPACE_SCOPE = (:lint, :format, :testitems)

mutable struct Workspace
    workspace::Union{Nothing,JuliaWorkspaces.JuliaWorkspace}
    workspace_lock::ReentrantLock
    session::Union{Nothing,TIR.TestSession}
    runs::Dict{String,TestRunRecord}          # the MCP-facing projection of every run
    active_runs::Dict{String,TIR.TestRun}     # testrun_id → run, while it is running
    folders::Vector{String}
    watcher_task::Union{Nothing,Task}
    watcher_stop::Union{Nothing,Ref{Bool}}
    watcher_snapshot::Dict{String,Float64}
    last_used_at::Dates.DateTime
end

function Workspace(folders::Vector{String}=String[])
    normalized = normalize_workspace_folders(folders)
    return Workspace(
        nothing,
        ReentrantLock(),
        nothing,
        Dict{String,TestRunRecord}(),
        Dict{String,TIR.TestRun}(),
        normalized,
        nothing,
        nothing,
        Dict{String,Float64}(),
        Dates.now(),
    )
end

"""
One MCP connection: the stdio connection, or one `Mcp-Session-Id` over HTTP.

`outbox` gets the notifications that no request caused, such as
`notifications/resources/updated`. Over stdio it is the JSON-RPC endpoint. Over HTTP it is
the `Channel` of the GET stream of the client, or `nothing` while the client has no GET
stream. `AppState.lock` guards `outbox` and `subscriptions`.
"""
mutable struct Client
    const id::String
    const subscriptions::Set{String}
    outbox::Any
end

mutable struct AppState
    clients::Dict{String,Client}
    log_level::Symbol  # MCP log level: :debug, :info, :notice, :warning, :error, :critical, :alert, :emergency
    session_controller::Union{Nothing,JSC.JuliaSessionController}
    session_reactor_task::Union{Nothing,Task}
    sessions::Dict{String,SessionRecord}
    workspaces::Dict{String,Workspace}
    lock::ReentrantLock
end

function AppState()
    return AppState(
        Dict{String,Client}(),
        :info,
        nothing,
        nothing,
        Dict{String,SessionRecord}(),
        Dict{String,Workspace}(),
        ReentrantLock(),
    )
end

"""
Add a new client with a random id to `state` and return it.
"""
function add_client!(state::AppState, outbox=nothing)
    client = Client(string(UUIDs.uuid4()), Set{String}(), outbox)
    lock(state.lock) do
        state.clients[client.id] = client
    end
    return client
end

"""
Run `f` while holding the workspace lock.
"""
with_workspace_lock(f, workspace::Workspace) = lock(f, workspace.workspace_lock)

struct WorkspaceResolutionError <: Exception
    message::String
end

Base.showerror(io::IO, err::WorkspaceResolutionError) = print(io, err.message)

function normalize_workspace_folders(folders)
    paths = String[]
    for folder in folders
        path = normpath(abspath(String(folder)))
        path != dirname(path) && (path = rstrip(path, ('/', '\\')))
        push!(paths, path)
    end
    return unique!(sort!(paths))
end

function workspace_id(folders)
    paths = normalize_workspace_folders(folders)
    return string(hash(join(paths, "\n")); base=16, pad=16)
end

function _workspace_listing_entry(id, workspace)
    folders = with_workspace_lock(workspace) do
        copy(workspace.folders)
    end
    return string(id, ": ", join(folders, ", "))
end

function _workspace_listing(state::AppState)
    entries = lock(state.lock) do
        collect(state.workspaces)
    end
    return join([_workspace_listing_entry(id, workspace) for (id, workspace) in sort(entries, by=first)], "\n")
end

function resolve_workspace(state::AppState, args::AbstractDict)
    requested = get(args, "workspace_id", nothing)
    if requested !== nothing
        id = String(requested)
        workspace = lock(state.lock) do
            get(state.workspaces, id, nothing)
        end
        workspace === nothing && throw(WorkspaceResolutionError(
            "Unknown workspace_id '$id'. Available workspaces:\n$(_workspace_listing(state))",
        ))
        lock(state.lock) do
            workspace.last_used_at = Dates.now()
        end
        return workspace
    end

    entries = lock(state.lock) do
        collect(state.workspaces)
    end
    isempty(entries) && throw(WorkspaceResolutionError(
        "Workspace not configured. Call julia_set_workspace_folders first.",
    ))
    if length(entries) != 1
        listing = _workspace_listing(state)
        throw(WorkspaceResolutionError(
            "workspace_id is required when multiple workspaces exist. Available workspaces:\n$listing",
        ))
    end

    workspace = only(entries).second
    lock(state.lock) do
        workspace.last_used_at = Dates.now()
    end
    return workspace
end

function find_workspace_for_run(state::AppState, testrun_id::AbstractString)
    workspace = lock(state.lock) do
        for candidate in values(state.workspaces)
            haskey(candidate.runs, testrun_id) && return candidate
        end
        nothing
    end
    if workspace !== nothing
        lock(state.lock) do
            workspace.last_used_at = Dates.now()
        end
    end
    return workspace
end

function find_workspace_for_process(state::AppState, process_id::AbstractString)
    workspaces = lock(state.lock) do
        collect(values(state.workspaces))
    end
    for workspace in workspaces
        found = with_workspace_lock(workspace) do
            session = workspace.session
            session !== nothing &&
                any(process -> string(process.id) == String(process_id), TIR.list_processes(session))
        end
        found || continue
        lock(state.lock) do
            workspace.last_used_at = Dates.now()
        end
        return workspace
    end
    return nothing
end

function workspace_id_for(state::AppState, workspace::Workspace)
    return lock(state.lock) do
        for (id, candidate) in state.workspaces
            candidate === workspace && return id
        end
        nothing
    end
end

