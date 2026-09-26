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
A request that a client sent and that has no response yet.

`cancelled` becomes true when the client closes the request or sends
`notifications/cancelled` for it. `testrun_id` is the test run that the request started.
`AppState.lock` guards both.
"""
mutable struct OpenRequest
    const id::Union{String,Int}
    cancelled::Bool
    testrun_id::Union{Nothing,String}
end

"""
One MCP connection: the stdio connection, or one `Mcp-Session-Id` over HTTP.

`outbox` gets the notifications that no request caused, such as
`notifications/resources/updated`. Over stdio it is the JSON-RPC endpoint. Over HTTP it is
the `Channel` of the GET stream of the client, or `nothing` while the client has no GET
stream.

`workspace_id` is the workspace that the client set up last with
`julia_set_workspace_folders`. `requests` holds the open requests of the client by their
JSON-RPC id. `last_used_at` is the time when the last request of the client ended, or when
the client started. `AppState.lock` guards all fields.
"""
mutable struct Client
    const id::String
    const subscriptions::Set{String}
    outbox::Any
    workspace_id::Union{Nothing,String}
    const requests::Dict{Any,OpenRequest}
    last_used_at::Dates.DateTime
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
    client = Client(string(UUIDs.uuid4()), Set{String}(), outbox, nothing, Dict{Any,OpenRequest}(), Dates.now())
    lock(state.lock) do
        state.clients[client.id] = client
    end
    return client
end

"""
Record `msg` from `client` as an open request and return its [`OpenRequest`](@ref), or
return `nothing` when `msg` is a notification. Call this before a task handles `msg`: then
a cancel that comes at once finds the request. Call [`close_request!`](@ref) after the
response.
"""
function open_request!(state::AppState, client::Client, msg::JSONRPC.Request)
    msg.id === nothing && return nothing
    request = OpenRequest(msg.id, false, nothing)
    lock(state.lock) do
        client.requests[msg.id] = request
    end
    return request
end

function close_request!(state::AppState, client::Client, request::OpenRequest)
    lock(state.lock) do
        get(client.requests, request.id, nothing) === request && delete!(client.requests, request.id)
        # The idle time of the client starts when its request ends.
        client.last_used_at = Dates.now()
    end
    return
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

"""
Return the workspace for a tool call with the arguments `args` from `client`: the
`workspace_id` in `args`, else the workspace that `client` set up last, else the only
workspace. Else throw a `WorkspaceResolutionError` that tells the agent what to do.
"""
function resolve_workspace(state::AppState, args::AbstractDict; client=nothing)
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

    if client !== nothing
        bound, workspace = lock(state.lock) do
            id = client.workspace_id
            found = id === nothing ? nothing : get(state.workspaces, id, nothing)
            found === nothing || (found.last_used_at = Dates.now())
            id, found
        end
        workspace === nothing || return workspace
        bound === nothing || throw(WorkspaceResolutionError(
            "The workspace $bound that this client set up is closed. The server closes a workspace " *
            "that no client used for a time, and julia_close_workspace closes it at once. " *
            "Call julia_set_workspace_folders again.",
        ))
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

