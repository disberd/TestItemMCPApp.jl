# TestItemMCPApp

MCP server wrapping [TestItemControllers.jl](https://github.com/julia-testitems/TestItemControllers.jl)
for discovering and running `@testitem`/`@testsetup` blocks from Julia packages. Exposes
the same engine as the Julia VS Code test explorer over the
[Model Context Protocol](https://modelcontextprotocol.io/) (stdio, JSON-RPC).

Worker processes persist between runs and hot-reload via Revise, so
subsequent test runs skip recompilation.

## Prerequisites

- Julia 1.12+

## Install

From the Julia REPL Pkg mode (`]`):

```
app add https://github.com/disberd/TestItemMCPApp.jl.git
```

Or equivalently from Julia code:

```julia
import Pkg
Pkg.Apps.add(url="https://github.com/disberd/TestItemMCPApp.jl.git")
```

Both install the `juliatimcp` binary under `~/.julia/bin/`.

## Claude Code setup

```sh
claude mcp add juliatimcp -- juliatimcp
```

Restart the Claude Code session after adding. The server exposes these tools:

| Tool | Purpose |
|------|---------|
| `set_workspace_folders` | Point at one or more Julia projects to scan |
| `list_testitems` | List detected `@testitem` blocks (with optional filters) |
| `run_testitems` | Run test items (filterable by name, tags, file, package) |
| `rerun_failed` | Re-run failures from a previous run |
| `cancel_testrun` | Cancel an in-progress run |
| `get_testrun_results` | Retrieve results for a completed run |
| `get_testitem_detail` | Get per-item output and messages |
| `list_testruns` | List all test runs in this session |
| `list_test_processes` | Show live worker processes |
| `terminate_test_process` | Kill a specific worker |
| `terminate_all_processes` | Kill all workers (for Revise-incompatible changes) |
| `get_process_output` | Retrieve process-level stdout/stderr |
| `get_coverage_results` | Retrieve coverage data (`mode="Coverage"`) |
| `close_session` | Close a session and free its workers |
| `update_file` | Notify the server of a file change on disk |

## Changes from upstream

Fork of [julia-testitems/TestItemMCPApp.jl](https://github.com/julia-testitems/TestItemMCPApp.jl).
Differences from upstream, newest first:

| Change | PR |
|--------|----|
| Resource conservation — default `max_workers=1`, idle session reaper, `close_session` tool | [#4](https://github.com/disberd/TestItemMCPApp.jl/pull/4) |
| Multi-session support — multiple clients share one Julia process via an external mux (see below) | [#3](https://github.com/disberd/TestItemMCPApp.jl/pull/3) |
| Tool schema fixes (`mode` enum, `rerun_failed` parameter gaps, duration units) and new tools (`julia_env`, `log_level`, `get_process_output`, `terminate_all_processes`) | [#2](https://github.com/disberd/TestItemMCPApp.jl/pull/2) |
| General-registry compatibility (resolve deps from General + GithubSatcomRegistry) | [#1](https://github.com/disberd/TestItemMCPApp.jl/pull/1) |

## Multi-session support

The server supports multiple concurrent sessions within a single process,
allowing several MCP clients to share one Julia runtime instead of each
spawning its own. Each session gets an isolated workspace, test controller,
and run history; sessions created with the same workspace folders (and no
explicit `session_id`) share a controller and its worker process pool.
Each test run defaults to 1 worker process to keep memory usage low on a
shared server; pass `max_workers` to `run_testitems` when parallelism is
needed. Idle sessions are automatically removed after 1 hour
(`JULIATIMCP_IDLE_TIMEOUT_SECS` env var, 0 to disable).

Every tool accepts an optional `session_id` parameter.
When only one session is active it is selected automatically,
preserving full backward compatibility with single-client setups.

Because the server uses stdio transport, an external MCP multiplexer is
required to fan multiple client connections into the single pipe.
[rmcp-mux](https://github.com/VetCoders/rmcp-mux) (Rust, headless CLI
daemon) is a good fit — it provides request-ID rewriting, init-response
caching, and a stdio proxy shim so each MCP host connects as usual.
Adding an HTTP transport directly to the server is planned but not yet
implemented.

## Note

Commits on top of the upstream original were developed with significant
contribution from AI coding agents.
