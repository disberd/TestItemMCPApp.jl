module TestItemMCPApp

import JSON, JSONRPC, JuliaWorkspaces, TestItemControllers
# Use TestItemControllers' bundled CancellationTokens to avoid type mismatch
const CancellationTokens = TestItemControllers.CancellationTokens
import UUIDs, Dates, Logging

include("types.jl")
include("state.jl")
include("mcp_logging.jl")
include("mcp_protocol.jl")
include("bridge.jl")
include("callbacks.jl")
include("mcp_tools.jl")
include("mcp_resources.jl")
include("tool_handlers.jl")
include("mcp_server.jl")

function (@main)(ARGS)
    # The app shim sets JULIA_LOAD_PATH to the app environment. Clear it so
    # spawned test processes inherit a default LOAD_PATH with "@" (active project).
    delete!(ENV, "JULIA_LOAD_PATH")

    debuglogger = Logging.ConsoleLogger(stderr, Logging.Debug)
    Logging.with_logger(debuglogger) do
        run_server(stdin, stdout)
    end
end

end # module TestItemMCPApp
