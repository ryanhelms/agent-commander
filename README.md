# Agent Commander

Agent Commander is a native macOS cockpit for supervising agents in tmux. This first local build handles planning and research with a Claude Code coordinator and managed workers. It shows the same live conversation text in the cockpit and in ordinary tmux. Workers can ask a question through MCP, wait while you answer in picture-in-picture, and continue with the answer.

## Build and open

Use macOS 26 or later with a Swift 6.2+ toolchain and macOS 26 SDK, Go 1.25+, Git, Make, tmux and a signed-in Claude Code CLI. The Go dependencies are pinned in `go.mod` and `go.sum`. Run the following from this checkout.

```sh
make app
open "dist/Agent Commander.app"
```

The local build uses an ad hoc signature. The app starts its per-user service when opened. Closing the window preserves running assignments. Open it again to reconnect.

To inspect the approved cockpit layouts with repeatable sample data, open a design preview from this checkout. The preview uses the same SwiftUI components as the live cockpit and does not start a run.

```sh
open -n "dist/Agent Commander.app" --args --design-preview attention-pip
```

The five preview names are `coordinator-wall`, `focused-worker`, `attention-pip`, `pip-arrival` and `start-run`. See the [native screenshots and live workflow verification](design/verification/README.md).

## Try a planning run

Choose **New run**, select a project directory and enter a planning task. For a quick first run, enter the following task in a small project.

> Plan an onboarding note for this project. Delegate a reader-profile worker and a structure-review worker. Have the first worker ask me which audience I’m writing for and wait for my answer. Have the second suggest three headings while I decide. Bring their findings back together.

The coordinator launches its workers through Commander’s MCP tools. Select a worker to inspect its output. A pending question identifies its originating worker and run. Type the answer into that card and select **Send reply**. The worker receives it through its original request. Prompts and answers travel as data, including whitespace, quotes and dollar signs. Each managed console prints its own tmux attach command. **Stop run** closes delegation for that run and requests cancellation of its managed sessions.

## Open Devflow from a coordinator

Ask **“Open the Devflow provider editor for this repo”** or **“Open the task management provider in Devflow.”** An interactive coordinator connects to Devflow’s UI-only MCP companion at startup and asks it to open or reuse the console for its checkout. Your request takes you to the specified screen. The coordinator can open the console, and you review and apply changes there. Planning workers keep their existing tool access.

Commander checks for the UI launcher when a coordinator starts. It looks for Devflow in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin`. Set `AGENT_COMMANDER_DEVFLOW` to an absolute executable path in the service environment for another installation. Start a new run after upgrading Devflow. Planning still works when the companion is unavailable.

## Use the CLI

```sh
./dist/agentctl start
./dist/agentctl run "$PWD" "Plan the documentation for this project."
./dist/agentctl list
./dist/agentctl show RUN_ID
./dist/agentctl reply REQUEST_ID 'Use the SDK developer audience.'
./dist/agentctl stop RUN_ID
```

To read the local HTTP API directly, run `./dist/agentctl api GET /v1/runs`. For a mutation, pass a JSON body on stdin. All CLI, desktop and MCP domain operations call the same service. Each managed agent receives its own MCP connection bound to its run and worker identity.

## Local data and troubleshooting

The default data directory is `~/Library/Application Support/Agent Commander`. It contains the private API socket, persisted run state, recent console output and private provider launch configuration. A detached service writes its startup errors to `service.log`. Treat the directory as private, since transcripts can contain sensitive project content.

- `AGENT_COMMANDER_HOME` selects a separate data directory for development. Its default socket is `service.sock` inside that directory.
- `AGENT_COMMANDER_SOCKET` overrides the socket path for both server and clients. Use a short path for Unix sockets.
- `AGENT_COMMANDER_CLAUDE` and `AGENT_COMMANDER_TMUX` select absolute executable paths when they are installed in a custom location. Start the service with these variables set. Standard Homebrew and user-local locations are checked automatically.
- If Claude asks for authentication, run `claude auth login` in a terminal. Reopen the app or inspect the worker’s launch error. To retry a failed planning task, start a new run.

## Current scope

The initial build supports local managed Claude Code planning workers. It retains a bounded console tail per worker. SSH hosts, Codex-managed workers, adoption of existing panes, arbitrary interactive terminal emulation, coding worktrees, and searchable transcript history are subsequent increments in the [MVP plan](MVP-PLAN.md).

Run `make test` for the Go tests. Run `make smoke` where local Unix sockets are permitted to exercise scoped MCP clients, the API and a disposable tmux worker with a deterministic model fixture. Both commands use local test data. Build the native cockpit with `make app`.
