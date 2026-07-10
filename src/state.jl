# state.jl — Application state

mutable struct SessionState
    const id::String
    workspace::Union{Nothing,JuliaWorkspaces.JuliaWorkspace}
    controller::Union{Nothing,TestItemControllers.TestItemController}
    reactor_task::Union{Nothing,Task}
    runs::Dict{String,TestRunRecord}
    processes::Dict{String,ProcessInfo}
    process_outputs::Dict{String,Vector{String}}
    subscriptions::Set{String}
    cancellation_sources::Dict{String,CancellationTokens.CancellationTokenSource}  # testrun_id → cts
    test_env_by_id::Dict{String,TestItemControllers.TestEnvironment}
    const last_active::Threads.Atomic{Float64}
    lock::ReentrantLock
end

function SessionState(id::String)
    return SessionState(
        id,
        nothing,
        nothing,
        nothing,
        Dict{String,TestRunRecord}(),
        Dict{String,ProcessInfo}(),
        Dict{String,Vector{String}}(),
        Set{String}(),
        Dict{String,CancellationTokens.CancellationTokenSource}(),
        Dict{String,TestItemControllers.TestEnvironment}(),
        Threads.Atomic{Float64}(time()),
        ReentrantLock(),
    )
end

mutable struct AppState
    sessions::Dict{String,SessionState}
    endpoint::JSONRPC.JSONRPCEndpoint
    log_level::Symbol  # MCP log level: :debug, :info, :notice, :warning, :error, :critical, :alert, :emergency
    lock::ReentrantLock
end

function AppState(endpoint::JSONRPC.JSONRPCEndpoint)
    return AppState(
        Dict{String,SessionState}(),
        endpoint,
        :info,
        ReentrantLock(),
    )
end

function session_key(folders::Vector{String})
    string(hash(sort(folders)); base=16)
end

function resolve_session(state::AppState, args::Dict{String,Any})
    session_id = get(args, "session_id", nothing)
    session = if session_id !== nothing
        s = lock(state.lock) do
            get(state.sessions, session_id, nothing)
        end
        s === nothing && error("Unknown session: $session_id")
        s
    else
        lock(state.lock) do
            n = length(state.sessions)
            if n == 0
                error("No workspace configured. Call set_workspace_folders first.")
            elseif n == 1
                first(values(state.sessions))
            else
                error("Multiple sessions active ($(join(keys(state.sessions), ", "))). Pass session_id to disambiguate.")
            end
        end
    end
    session.last_active[] = time()
    return session
end
