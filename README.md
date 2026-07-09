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
| `update_file` | Notify the server of a file change on disk |

## Upstream

Fork of [julia-testitems/TestItemMCPApp.jl](https://github.com/julia-testitems/TestItemMCPApp.jl),
with fixes to tool schemas (mode enum, `rerun_failed` parameter gaps, duration
units) and additional features (`julia_env`, `log_level`, `get_process_output`,
`terminate_all_processes`) not yet available upstream.

## Note

Commits on top of the upstream original were developed with significant
contribution from AI coding agents.
