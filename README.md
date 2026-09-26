# JuliaMCP.jl

[![Project Status: Active - The project has reached a stable, usable state and is under active development.](http://www.repostatus.org/badges/latest/active.svg)](http://www.repostatus.org/#active)
[![Build Status](https://github.com/julia-vscode/JuliaMCP.jl/actions/workflows/juliaci.yml/badge.svg?branch=main)](https://github.com/julia-vscode/JuliaMCP.jl/actions/workflows/juliaci.yml)
[![codecov](https://codecov.io/gh/julia-vscode/JuliaMCP.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/julia-vscode/JuliaMCP.jl)

An [MCP](https://modelcontextprotocol.io) server that gives AI coding agents access to a
live Julia development environment.

JuliaMCP wraps the same engines that power the Julia VS Code extension
([JuliaWorkspaces.jl](https://github.com/julia-vscode/JuliaWorkspaces.jl) for analysis,
[TestItemControllers.jl](https://github.com/julia-testitems/TestItemControllers.jl) for test
execution, and
[JuliaSessionControllers.jl](https://github.com/julia-vscode/JuliaSessionControllers.jl) for
long-lived REPL sessions) and exposes them over stdio as MCP tools and resources. An agent
can therefore lint a file, run a subset of test items, read the resulting failure output, and
evaluate code in a persistent session, without shelling out to `julia` and scraping stdout.

The server speaks MCP protocol version `2025-03-26`. All logging goes to stderr; stdout
carries MCP messages exclusively.

## Fork changes

This repository is a fork of [julia-vscode/JuliaMCP.jl](https://github.com/julia-vscode/JuliaMCP.jl).
To install the fork, give its URL to `Pkg.Apps.add`:

```julia
using Pkg
Pkg.Apps.add(url="https://github.com/disberd/TestItemMCPApp.jl")
```

The fork adds these changes to upstream:

| Change | Commits |
|--------|---------|
| Several workspaces in one process, each with its own `workspace_id`, test runs, test processes, resources, and notifications. See [Several clients, one server](#several-clients-one-server). | [`38b4af0`](https://github.com/disberd/TestItemMCPApp.jl/commit/38b4af0ccc645a8b801ba11c02edf23a67b58f09), [`3b7ae29`](https://github.com/disberd/TestItemMCPApp.jl/commit/3b7ae290c36ec17eab3bfb2b44d8ba3f111fc538) |
| An idle reaper that closes unused workspaces and sessions, and the `julia_close_workspace` tool. | [`b649de8`](https://github.com/disberd/TestItemMCPApp.jl/commit/b649de8bf07bb879fa540b472f3edb08c66d47aa) |
| Pass-through tools and arguments for TestItemRuns features: `julia_env` and `log_level` on test runs, `julia_get_process_output`, and `julia_terminate_all_processes`. | [`5cfe129`](https://github.com/disberd/TestItemMCPApp.jl/commit/5cfe129c479057b29a7def136e73fa776ef0b8ab) |
| `max_workers = 1` as the default for a test run, to keep the load low when several clients share the server. Upstream uses `min(Sys.CPU_THREADS, 8)`. | [`5cfe129`](https://github.com/disberd/TestItemMCPApp.jl/commit/5cfe129c479057b29a7def136e73fa776ef0b8ab) |
| `julia_get_diagnostics` with `path` obeys `wait_for_ready`. The fork also proposes this fix upstream. | [`73da529`](https://github.com/disberd/TestItemMCPApp.jl/commit/73da52949562e5a8851102ac152f9e8ddb189c1f) |
| An MCP Streamable HTTP transport: `juliamcp --http` serves several clients from one process. Each client has its own `Mcp-Session-Id`, resource subscriptions, and progress notifications. A bearer token protects the port. See [HTTP transport](#http-transport). | [`7d7ebc6`](https://github.com/disberd/TestItemMCPApp.jl/commit/7d7ebc6dc3f9d44d5dba2226b36bac5d299f6415) |
| Client-scoped behaviour over HTTP: a tool call without a `workspace_id` uses the workspace that its client set up last. A closed request, or `notifications/cancelled`, cancels the test run of the request. `DELETE` kills the sessions of the client, and the reaper removes idle clients. See [Several clients, one server](#several-clients-one-server). | [`482c60d`](https://github.com/disberd/TestItemMCPApp.jl/commit/482c60d5c7cc8ce2276d0170a3b07e6e8395a090) |

Fork pull requests #1 to #5 targeted the code before JuliaMCP, when the package was `TestItemMCPApp` and the app was `juliatimcp`.

## Installation

JuliaMCP is a Julia [app](https://pkgdocs.julialang.org/v1/apps/), which requires Julia 1.12
or newer:

```julia
using Pkg
Pkg.Apps.add(url="https://github.com/julia-vscode/JuliaMCP.jl")
```

This installs a `juliamcp` executable into `~/.julia/bin`. Make sure that directory is on
your `PATH`.

## Usage

Point an MCP client at the `juliamcp` command. For clients that use the common
`mcpServers` JSON format:

```json
{
  "mcpServers": {
    "julia": {
      "command": "juliamcp"
    }
  }
}
```

The server starts with no workspace loaded. An agent's first call is normally
`julia_set_workspace_folders` to tell it which directories to analyse.

### HTTP transport

`juliamcp --http` serves
[MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http)
at `http://127.0.0.1:50020/mcp`. Several clients can use one server process. Each client
has its own `Mcp-Session-Id`, its own resource subscriptions, and the progress of its own
calls.

```sh
juliamcp --http [--port N] [--token-file PATH]
```

- `--port N` sets the port. Without `--port`, the server uses the `JULIAMCP_PORT`
  environment variable, and then `50020`. When another process uses the port, the server
  stops with an error.
- `--token-file PATH` sets the file with the bearer token. Without `--token-file`, the
  server uses the `JULIAMCP_TOKEN_FILE` environment variable, and then `juliamcp/token` in
  the first Julia depot (normally `~/.julia/juliamcp/token`).

Each request must have the header `Authorization: Bearer <token>`, with the token from the
token file. When the token file does not exist, the server writes a new random token to
it. On POSIX, the new file gets mode 0600, and a new directory gets mode 0700. On Windows,
the file has no POSIX modes.

The server listens on `127.0.0.1` only. It refuses a request when the `Host` header is
not `localhost:<port>` or `127.0.0.1:<port>`, and when the `Origin` header names a page
on another host.

The answer to `tools/call` is an event stream: first the progress notifications of the
call, then the response. When the stream has no other output for 1 second, the server
sends the comment `: keepalive`. A write to a closed connection fails, so the server sees
within about 2 seconds that the client closed the request. Then the server cancels the
test run that the call started, as `julia_cancel_testrun` does. `notifications/cancelled`
from the same client, with the id of that request, also cancels the run.

A GET request opens the event stream of the client for the resource notifications. This
stream gets `: keepalive` after 60 seconds with no other output.

For [omp](https://github.com/can1357/oh-my-pi), put this entry in `mcp.json`:

```json
{
  "mcpServers": {
    "juliamcp": {
      "type": "http",
      "url": "http://127.0.0.1:50020/mcp",
      "timeout": 660000,
      "headers": {
        "Authorization": "!printf 'Bearer %s' \"$(cat ~/.julia/juliamcp/token)\""
      }
    }
  }
}
```

omp runs a header value that starts with `!` as a shell command and sends its output.
The `timeout` is in milliseconds. Keep it above `max_wait_seconds` of `julia_run_testitems`
(600 seconds by default). When the omp timeout comes first, omp closes the request, and the
server cancels the test run of the request.

The same server runs on Windows. `julia_interrupt_session` cannot stop code that never
yields, especially on Windows; `julia_kill_session` can.

## What it exposes

### Tools

Every tool is prefixed `julia_` so a model can tell at a glance that it operates on Julia
code, even in clients that do not namespace tools by server.

**Workspace**: `julia_set_workspace_folders`, `julia_close_workspace`

**Code analysis**: `julia_get_diagnostics`, `julia_format_file`

**Test items**: `julia_list_testitems`, `julia_get_testitem_detail`, `julia_run_testitems`,
`julia_rerun_failed`, `julia_cancel_testrun`, `julia_get_testrun_results`,
`julia_list_testruns`, `julia_get_coverage_results`, `julia_list_test_processes`,
`julia_terminate_test_process`, `julia_get_process_output`, `julia_terminate_all_processes`

`julia_run_testitems` waits at most `max_wait_seconds` (default 600) and otherwise hands the
run back with status `"running"`; `julia_get_testrun_results` polls it and
`julia_cancel_testrun` stops it. The per-item `timeout` is independent and bounds each test
item rather than the call.

`julia_run_testitems` and `julia_rerun_failed` also take `julia_env` and `log_level`.
`julia_env` sets environment variables for the test processes, and a `null` value removes a
variable. `log_level` is the minimum log level of the code under test. `julia_rerun_failed`
uses the values of the original run unless the call gives new values. `max_workers` is 1 by
default.

The code analysis tools, the test item tools, and `julia_close_workspace` take an optional
`workspace_id`. See [Several clients, one server](#several-clients-one-server).

**Sessions**: `julia_create_session`, `julia_eval_code`, `julia_profile_code`,
`julia_get_session_variables`, `julia_list_sessions`, `julia_interrupt_session`,
`julia_kill_session`

The workspace tracks the file system itself, so nothing needs to be called after an edit.
`julia_update_file` is routed but not advertised, for embedders that pass `watch: false` to
`julia_set_workspace_folders` and drive refreshes themselves.

### Test item ids

`julia_list_testitems` reports an id for every test item, and `julia_run_testitems`,
`julia_get_testitem_detail` and the `testrun://` resources all take or return those same
ids. They look like this:

```
MyPkg@a1b2c3d4/test/parsing_tests.jl::parse basics
```

That is `<package>/<path>::<label>`.

The package is `<name>@<first eight hex digits of its uuid>`. Both halves matter: the name is
what you recognise, and the uuid fragment separates two different packages that happen to
share a name: a vendored copy sitting beside a dev checkout, say.

The path is the file the `@testitem` is defined in, relative to the root of the package it
belongs to and always written with `/` separators, so an id is identical on Windows and on
Linux, and identical in a dev checkout and on a CI runner. (A file with no filesystem path to
make relative falls back to its full URI, unqualified, since a URI is already unique.)

**An id identifies a test item within its package, not within a workspace.** The *same*
package checked out into two folders (two worktrees, say) produces the same id from both,
deliberately. Two checkouts can only be told apart by their location, and location differs
between a dev checkout and a CI runner, so no single string can be both unique across a
workspace and portable across machines; the id keeps portability. Where uniqueness matters,
this server pairs the id with the package it came from, and results carry the file URI
alongside the id.

**Ids are stable.** They depend only on the file and the test item's name, so inserting or
removing other test items in the same file, or anywhere else in the package, does not change
them. This is what makes `julia_rerun_failed` correct: it re-runs the failed items of an
earlier run by id, and the agent will usually have edited the code in between. The same
holds for ids used in the `items` filter of `julia_run_testitems`, and for ids an agent
writes down and comes back to later. The ids that appear in `juliati`'s results JSON and
JUnit XML output are these same ids.

Two test items in one file are not supposed to share a name. If they do, every occurrence of
that name is suffixed `#1`, `#2`, … so the ids stay unique and each item remains individually
addressable, and a test item definition error is reported for each of them, visible through
`julia_get_diagnostics` and the `workspace://{workspace_id}/detection-errors` resource. This is
the one case where ids are not stable: resolving the duplicate renumbers its siblings.
Duplicate names are a mistake worth fixing rather than a state to persist ids from.

### Resources

Three resources for each workspace cover its current state (`workspace://{workspace_id}/testitems`,
`workspace://{workspace_id}/diagnostics`, `workspace://{workspace_id}/detection-errors`). Dynamic resources are listed as
work happens, so an agent can read large output out of band rather than through a tool
result: `testrun://<id>/summary`, `testprocess://<id>/output`, `session://<id>/info` and
`session://<id>/output`.

## Several clients, one server

One `juliamcp` process can hold several workspaces. `julia_set_workspace_folders` returns a
`workspace_id`, which is a hash of the sorted, normalised folder paths. The same folders give
the same `workspace_id`. A second call with the same folders reuses the workspace and keeps
its test runs.

A workspace tool finds its workspace with these rules:

- With a `workspace_id`, the tool uses that workspace. An unknown `workspace_id` gives a tool
  error that lists the workspaces.
- Without a `workspace_id`, a tool that takes a `testrun_id` or a `process_id` finds the
  workspace from that id.
- Without a `workspace_id`, any other tool uses the workspace that the client set up last
  with `julia_set_workspace_folders`. When the server closed that workspace, the tool gives
  an error that tells you to call `julia_set_workspace_folders` again.
- A client that set up no workspace uses the only workspace. When there are two or more
  workspaces, the tool gives an error that lists each `workspace_id` with its folders. When
  there is no workspace, the error tells you to call `julia_set_workspace_folders`.

The server sends resource notifications only for the workspace that changed.
`notifications/resources/updated` goes only to the clients that subscribed to the resource,
and the progress of a call goes only to the client that made the call.

The server closes each workspace and kills each session that no client used for
`JULIAMCP_IDLE_TIMEOUT_SECS` seconds. The default is `3600`, and `0` turns this off. The
server keeps a workspace with a running test run, and a session with a queued or running
request. `julia_close_workspace` closes a workspace at once. It refuses while a test run of
the workspace is active.

The server records the client that created each session. `DELETE` of a client kills its
sessions. Over stdio, the end of the input kills them. `julia_list_sessions` lists the
sessions of all clients. The server also removes an HTTP client that had no open request
for `JULIAMCP_IDLE_TIMEOUT_SECS` seconds, with the same effect as `DELETE`. The next
request of that client gets 404, and the client then sends `initialize` again to get a new
`Mcp-Session-Id`.

Over stdio, each `juliamcp` process has one client. To connect several clients to one
process, use the [HTTP transport](#http-transport).

## Development

```julia
using Pkg
Pkg.develop(url="https://github.com/julia-vscode/JuliaSessionControllers.jl")  # not yet registered
Pkg.test("JuliaMCP")
```

Tests are written as [test items](https://github.com/julia-testitems/TestItems.jl) and run
with TestItemRunner. `testdata/` deliberately contains `@testitem`s that are
fixtures for the test suite rather than tests of this package, so `test/runtests.jl` filters
them out.
