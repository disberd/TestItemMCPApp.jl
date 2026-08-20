# diagnostics.jl — Show JuliaWorkspaces diagnostics and formatting over MCP

# The workspace is read without a lock. The MCP message loop is the only writer, and
# each session owns its workspace. Add a lock here if a background task starts to
# change the workspace.

const DIAGNOSTIC_LIMIT_DEFAULT = 200

"""
Change a client-supplied file path or URI string into a `URI`.
"""
function resolve_uri(value::AbstractString)
    return occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", value) ?
        JuliaWorkspaces.URIs2.URI(value) :
        JuliaWorkspaces.filepath2uri(abspath(value))
end

"""
Cut `s` between the 1-based byte offsets `from` (inclusive) and `to` (exclusive).
The offsets are clamped to the string and moved to character boundaries.
"""
function safe_byte_slice(s::AbstractString, from::Int, to::Int)
    ncu = ncodeunits(s)
    from = clamp(from, 1, ncu + 1)
    to = clamp(to, from, ncu + 1)
    to <= from && return ""
    lo = thisind(s, from)
    hi = prevind(s, thisind(s, to))
    return lo <= hi ? s[lo:hi] : ""
end

"""
Change a `JuliaWorkspaces.Diagnostic` into a dictionary that JSON can encode.

Diagnostic ranges are 1-based byte offsets and exclude the end. This function
changes them into 1-based line and column positions.
"""
function diagnostic_to_dict(jw, diag, uri)
    result = Dict{String,Any}(
        "uri" => string(uri),
        "severity" => string(diag.severity),
        "message" => diag.message,
        "source" => diag.source,
    )
    isempty(diag.tags) || (result["tags"] = string.(diag.tags))

    text_file = try
        JuliaWorkspaces.get_text_file(jw, uri)
    catch
        nothing
    end
    text_file === nothing && return result

    content = text_file.content
    source = content.content
    ncu = ncodeunits(source)
    start_offset = clamp(first(diag.range), 1, ncu + 1)
    stop_offset = clamp(last(diag.range), start_offset, ncu + 1)

    start_pos = JuliaWorkspaces.position_at(content, start_offset)
    stop_pos = JuliaWorkspaces.position_at(content, stop_offset)
    result["range"] = Dict{String,Any}(
        "start" => Dict{String,Any}("line" => start_pos.line, "column" => start_pos.column),
        "end" => Dict{String,Any}("line" => stop_pos.line, "column" => stop_pos.column),
    )

    preview = safe_byte_slice(source, start_offset, stop_offset)
    isempty(preview) || (result["preview"] = preview)

    return result
end

"""
Collect diagnostics from the workspace of `session`. You can limit the result to one
file, and filter it by severity and source.
"""
function collect_diagnostics(
    session::SessionState;
    uri=nothing,
    severity=nothing,
    source=nothing,
    max_results::Int=DIAGNOSTIC_LIMIT_DEFAULT,
    wait_for_ready::Bool=false,
)
    jw = session.workspace
    jw === nothing && error("Workspace not configured. Call set_workspace_folders first.")

    entries = Tuple{Any,Any}[]
    if uri !== nothing
        for d in JuliaWorkspaces.get_diagnostic(jw, uri)
            push!(entries, (something(d.uri, uri), d))
        end
    else
        # `get_diagnostics` gives `uri => Vector{Diagnostic}` entries.
        all_diags = wait_for_ready ?
            JuliaWorkspaces.get_diagnostics_blocking(jw) :
            JuliaWorkspaces.get_diagnostics(jw)
        for (file_uri, diags) in all_diags
            for d in diags
                push!(entries, (something(d.uri, file_uri), d))
            end
        end
    end

    if severity !== nothing
        wanted = Set(Symbol.(severity))
        filter!(e -> e[2].severity in wanted, entries)
    end
    if source !== nothing
        wanted = Set(String.(source))
        filter!(e -> e[2].source in wanted, entries)
    end

    total = length(entries)
    truncated = total > max_results
    truncated && (entries = entries[1:max_results])

    by_file = Dict{String,Vector{Any}}()
    for (file_uri, d) in entries
        push!(get!(by_file, string(file_uri), Any[]), diagnostic_to_dict(jw, d, file_uri))
    end

    severities = Dict{String,Int}()
    for (_, d) in entries
        key = string(d.severity)
        severities[key] = get(severities, key, 0) + 1
    end

    return Dict{String,Any}(
        "total" => total,
        "reported" => length(entries),
        "truncated" => truncated,
        "by_severity" => severities,
        "files" => [
            Dict{String,Any}("uri" => file_uri, "diagnostics" => diags)
            for (file_uri, diags) in sort(collect(by_file), by = first)
        ],
    )
end

"""
Change a `WorkspaceFileEdit` into a dictionary that JSON can encode.
"""
function file_edit_to_dict(edit)
    return Dict{String,Any}(
        "uri" => string(edit.uri),
        "edits" => [
            Dict{String,Any}(
                "start" => Dict{String,Any}("line" => e.start.line, "column" => e.start.column),
                "stop" => Dict{String,Any}("line" => e.stop.line, "column" => e.stop.column),
                "new_text" => e.new_text,
            ) for e in edit.edits
        ],
    )
end

"""
Change a 1-based (line, column) `Position` into a 1-based byte offset.
"""
function offset_of(content, pos)
    line_indices = content.line_indices
    line = clamp(pos.line, 1, length(line_indices))
    return line_indices[line] + pos.column - 1
end

"""
Apply `edits` (in `WorkspaceFileEdit` form) to the text of `content`. The function
returns the new text. It applies the edits from the end to the start, so that the
earlier offsets stay correct.
"""
function apply_text_edits(content, edits)
    source = content.content
    ordered = sort(collect(edits), by = e -> (e.start.line, e.start.column), rev = true)
    for e in ordered
        from = offset_of(content, e.start)
        to = offset_of(content, e.stop)
        prefix = safe_byte_slice(source, 1, from)
        suffix = safe_byte_slice(source, to, ncodeunits(source) + 1)
        source = string(prefix, e.new_text, suffix)
    end
    return source
end
