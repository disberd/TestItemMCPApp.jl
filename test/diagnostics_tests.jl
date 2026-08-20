@testitem "get_diagnostics reports a syntax error" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [LINT_PKG_PATH]))

    result, _ = mcp_call_tool(ep, "get_diagnostics", Dict{String,Any}())

    @test result["total"] >= 1
    @test result["truncated"] == false

    bad_file = joinpath(LINT_PKG_PATH, "src", "badsyntax.jl")
    entry = only(filter(f -> occursin("badsyntax.jl", f["uri"]), result["files"]))
    diag = first(entry["diagnostics"])
    # Positions are 1-based line/column pairs, not byte offsets.
    @test diag["range"]["start"]["line"] >= 1
    @test diag["range"]["start"]["column"] >= 1
    @test haskey(diag, "message")

    close(ep); close(client_socket); close(server_socket)
end

@testitem "get_diagnostics filters by path and rejects outside files" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [LINT_PKG_PATH]))

    bad_file = joinpath(LINT_PKG_PATH, "src", "badsyntax.jl")
    scoped, _ = mcp_call_tool(ep, "get_diagnostics", Dict{String,Any}("path" => bad_file))
    @test scoped["total"] >= 1
    @test all(f -> occursin("badsyntax.jl", f["uri"]), scoped["files"])

    _, raw = mcp_call_tool(ep, "get_diagnostics", Dict{String,Any}("path" => joinpath(LINT_PKG_PATH, "src", "nosuchfile.jl")))
    @test raw["isError"] == true

    # A scoped request must obey wait_for_ready too, not only a workspace-wide request.
    ready, _ = mcp_call_tool(ep, "get_diagnostics", Dict{String,Any}(
        "path" => bad_file,
        "wait_for_ready" => true,
    ))
    @test ready["total"] >= scoped["total"]
    @test all(f -> occursin("badsyntax.jl", f["uri"]), ready["files"])

    close(ep); close(client_socket); close(server_socket)
end

@testitem "format_file returns edits and leaves the file alone" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [LINT_PKG_PATH]))

    target = joinpath(LINT_PKG_PATH, "src", "unformatted.jl")
    before = read(target, String)

    result, _ = mcp_call_tool(ep, "format_file", Dict{String,Any}("path" => target))
    @test result["excluded"] == false
    @test result["applied"] == false
    @test result["already_formatted"] == false
    @test !isempty(result["edits"])
    # Without apply=true the file on disc must not change.
    @test read(target, String) == before

    close(ep); close(client_socket); close(server_socket)
end

@testitem "format_file with apply=true rewrites the file" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    # Work on a copy, so that the fixture in the repository stays unformatted.
    workdir = mktempdir()
    cp(LINT_PKG_PATH, joinpath(workdir, "LintPkg"))
    pkg = joinpath(workdir, "LintPkg")
    target = joinpath(pkg, "src", "unformatted.jl")
    before = read(target, String)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [pkg]))

    result, _ = mcp_call_tool(ep, "format_file", Dict{String,Any}("path" => target, "apply" => true))
    @test result["applied"] == true

    after = read(target, String)
    @test after != before

    # Formatting is idempotent: a second pass finds nothing left to change.
    again, _ = mcp_call_tool(ep, "format_file", Dict{String,Any}("path" => target))
    @test again["already_formatted"] == true

    close(ep); close(client_socket); close(server_socket)
    rm(workdir; recursive=true, force=true)
end

@testitem "format_file rejects start_line without stop_line" setup=[MCPTestHelpers] begin
    using Test

    server_socket, client_socket = get_named_pipe()
    start_mcp_server(server_socket)
    ep = JSONRPC.JSONRPCEndpoint(client_socket, client_socket; framing=JSONRPC.NewlineDelimitedFraming())
    JSONRPC.start(ep)
    mcp_initialize!(ep)

    mcp_call_tool(ep, "set_workspace_folders", Dict{String,Any}("folders" => [LINT_PKG_PATH]))

    target = joinpath(LINT_PKG_PATH, "src", "unformatted.jl")
    _, raw = mcp_call_tool(ep, "format_file", Dict{String,Any}("path" => target, "start_line" => 1))
    @test raw["isError"] == true

    close(ep); close(client_socket); close(server_socket)
end
