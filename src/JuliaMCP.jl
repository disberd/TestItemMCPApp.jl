module JuliaMCP

import JSON, JSONRPC, JuliaWorkspaces, TestItemRuns
import JuliaSessionControllers
import HTTP, Random
import UUIDs, Dates, Logging

# Never `using` either of these: JuliaSessionControllers exports `shutdown`,
# `wait_for_shutdown`, `list_sessions`; TestItemRuns exports `select`, `run!`, `filename`,
# … — all qualified here.
const JSC = JuliaSessionControllers
const TIR = TestItemRuns

# TestItemRuns re-exports the CancellationTokens module TestItemControllers vendors, and
# tokens cross that boundary — so we must use the same one rather than a separately
# resolved package.
const CancellationTokens = TestItemRuns.CancellationTokens

include("types.jl")
include("state.jl")
include("mcp_logging.jl")
include("mcp_protocol.jl")
include("bridge.jl")
include("session_bridge.jl")
include("diagnostics.jl")
include("watcher.jl")
include("callbacks.jl")
include("reaper.jl")
include("mcp_tools.jl")
include("mcp_resources.jl")
include("tool_handlers.jl")
include("mcp_server.jl")
include("http_server.jl")

const USAGE = "Usage: juliamcp [--http [--port N] [--token-file PATH]]"

"""
Read the command line of `juliamcp`. Return `(; http, port, token_file)`, with `nothing` for
an option that the command line does not give.
"""
function parse_command_line(args)
    http = false
    port = token_file = nothing
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--http"
            http = true
        elseif arg == "--port" && i < length(args)
            i += 1
            port = parse_port(args[i], "--port")
        elseif arg == "--token-file" && i < length(args)
            i += 1
            token_file = args[i]
        else
            throw(ArgumentError("Unknown argument \"$arg\". $USAGE"))
        end
        i += 1
    end
    (http || (port === nothing && token_file === nothing)) ||
        throw(ArgumentError("--port and --token-file need --http. $USAGE"))
    return (; http, port, token_file)
end

function (@main)(ARGS)
    options = parse_command_line(ARGS)
    # All logging goes to stderr — stdout is exclusively for MCP messages
    debuglogger = Logging.ConsoleLogger(stderr, Logging.Debug)
    Logging.with_logger(debuglogger) do
        if options.http
            run_http_server(; port=http_port(options.port), token_file=token_file_path(options.token_file))
        else
            run_server(stdin, stdout)
        end
    end
end

end # module JuliaMCP
