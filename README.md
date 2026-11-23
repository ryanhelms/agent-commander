# Agent Commander

Agent Commander is a native macOS cockpit for supervising agents in tmux. This first local build handles planning and research with a Claude Code coordinator and managed workers. The cockpit streams structured conversation and tool results through AG-UI. The underlying session can also be opened in tmux. Workers ask questions through MCP and continue when the corresponding request is answered.

## Build and open

Use macOS 26 or later with a Swift 6.2+ toolchain and macOS 26 SDK, Go 1.25+, Git, Make, tmux and a signed-in Claude Code CLI. Place the local `agent-acp` checkout beside `agent-commander`. The Go module resolves its SDK from `../agent-acp/sdks/go` during source development. The remaining Go dependencies are pinned in `go.mod` and `go.sum`. Run the following from this checkout.

```sh
make app
open "dist/Agent Commander.app"
```

The local build uses an ad hoc signature. The app starts its per-user service when opened. Closing the window preserves running assignments. Open it again to reconnect.

To review the 28 native screens and states with sample data, open the design gallery from this checkout.

```sh
open -n "dist/Agent Commander.app" --args --design-preview gallery
```

Use the title bar’s preview menu or press ⌥⌘← and ⌥⌘→ to browse. The menu can pause sample activity or reset the current view. You can also open a specific view by its name in the concept gallery, such as `attention-pip` or `integration-blocked`. Preview replies, filters, and other controls use in-memory data. A normal launch opens the live local cockpit. [Original concepts](design/concepts/index.html) · [Native verification](design/verification/README.md)

## Try the SDK-backed local runner

The opt-in runner opens each new Claude coordinator or worker through the independent Go session SDK. The worker’s tmux pane, the cockpit, MCP and the CLI address the same Commander assignment. The service maps that assignment to an immutable native session ID. On reconnect, it reads native history and projects it into the existing console. Commander persists run metadata, decisions, addressed commands and reported findings. It keeps the SDK console projection in memory. Earlier sessions retain their original runner and storage.

With Node 22 or newer, launch a separate development instance from this checkout:

```sh
export AGENT_ACP_HARNESS_DIR="$(cd ../agent-acp/harnesses/local && pwd)"
npm ci --prefix "$AGENT_ACP_HARNESS_DIR"
export PATH="$AGENT_ACP_HARNESS_DIR/node_modules/.bin:$PATH"
export AGENT_COMMANDER_CLAUDE_ACP="$AGENT_ACP_HARNESS_DIR/node_modules/.bin/claude-agent-acp"
export AGENT_COMMANDER_RUNTIME=acp
export AGENT_COMMANDER_HOME="$(mktemp -d /private/tmp/commander-sdk.XXXXXX)"
./dist/agentctl start
"dist/Agent Commander.app/Contents/MacOS/AgentCommander"
```

A service reads these settings at startup. Keep the same `AGENT_COMMANDER_HOME` to revisit that instance. A fresh service with the runtime selector unset uses the existing Claude runner. Codex passes the standalone SDK workflow. The pinned Codex adapter merges other configured MCP servers, so Commander reports managed Codex planning as unavailable until it can enforce the run’s tool permissions. [Native verification](design/verification/sdk-runtime.md)

## Try a planning run

Choose **New run**, select a project directory and enter a planning task. For a quick first run, enter the following task in a small project.

> Plan an onboarding note for this project. Delegate a reader-profile worker and a structure-review worker. Have the first worker ask me which audience I’m writing for and wait for my answer. Have the second suggest three headings while I decide. Bring their findings back together.

The coordinator launches its workers through Commander’s MCP tools. Select a worker to inspect its output. A pending question identifies its originating worker and run. Type the answer into that card and select **Send reply**. The worker receives it through its original request. Prompts and answers travel as data, including whitespace, quotes and dollar signs. Each managed console prints its own tmux attach command. **Stop run** closes delegation for that run and requests cancellation of its managed sessions.

On a managed local Claude worker, open its action menu and choose **Send follow-up…**. Commander takes control, opens the focused console, and sends the message to the same Claude conversation when the current turn ends. Use **Option–Return** to add a line. While you hold control, the coordinator yields replies and control commands for this worker. **Hand back control** returns control and cancels any follow-up that has yet to start. **Interrupt turn** cancels an active turn and keeps its conversation available. **Stop worker…** closes just that worker’s tmux session.

**Needs Attention** uses the right sidebar by default. Choose **Picture-in-picture** from the worker area's attention menu to use a floating, draggable panel that remembers its location. A waiting console adds an amber line inside its harness border. **View request** opens its reply on demand.

Use the display icon in a console’s title bar to choose **Console** or **Pretty** for that worker. Pretty formats conversation text as chat, with Markdown and expandable tool results. The worker keeps its choice on the wall, in zoom and in picture-in-picture. The window toolbar’s **Display** menu applies either mode to every console across runs, including new workers. Each app launch starts in Console mode.

The console header and border identify its harness. Claude Code starts orange, Codex blue, and generic MCP violet. Named custom harnesses receive distinct accents. Open the console’s display menu and choose **Accent for** the harness to pick a color. The choice applies to every console using that harness and is saved on this Mac. Choose **Default** in the same menu to restore its original color.

## Open Devflow from a coordinator

Ask **“Open the Devflow provider editor for this repo”** or **“Open the task management provider in Devflow.”** An interactive coordinator connects to Devflow’s UI-only MCP companion at startup and asks it to open or reuse the console for its checkout. Your request takes you to the specified screen. The coordinator opens the console with its own Commander identity. Choose **Check activity** on Overview to see worker requests available to that identity for the checkout. You review and apply configuration changes in the browser. Planning workers keep their existing tool access.

Commander checks for the UI launcher when a coordinator starts. It looks for Devflow in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin`. Set `AGENT_COMMANDER_DEVFLOW` to an absolute executable path in the service environment for another installation. Start a new run after upgrading Devflow. Planning still works when the companion is unavailable.

## Use the CLI

```sh
./dist/agentctl start
./dist/agentctl run "$PWD" "Plan the documentation for this project."
./dist/agentctl list
./dist/agentctl show RUN_ID
./dist/agentctl reply REQUEST_ID 'Use the SDK developer audience.'
./dist/agentctl take WORKER_ID CURRENT_GENERATION
./dist/agentctl follow-up WORKER_ID HELD_GENERATION 'Check the retry budget too.'
./dist/agentctl hand-back WORKER_ID HELD_GENERATION
./dist/agentctl interrupt WORKER_ID
./dist/agentctl stop-worker WORKER_ID
./dist/agentctl stop RUN_ID
```

To read the local HTTP API directly, run `./dist/agentctl api GET /v1/runs`. For a mutation, pass a JSON body on stdin. All CLI, desktop and MCP domain operations call the same service. Each managed agent receives its own MCP connection bound to its run and worker identity.

The run response lists each live managed worker’s control generation. Taking control and handing it back advance that generation. Coordinators can call `commander_send`, `commander_interrupt`, and `commander_stop_worker` on workers they direct.

The desktop subscribes to `GET /v1/ag-ui/events` on the private Unix socket. The SSE feed opens with a `STATE_SNAPSHOT` and emits `STATE_DELTA` patches, with AG-UI messages grouped by worker. Reconnecting starts from another snapshot. Replies use the existing request-ID endpoint. The Swift app consumes AG-UI directly. The separate CopilotKit proof is under [poc/agui-console](poc/agui-console/README.md).

## Local data and troubleshooting

The default data directory is `~/Library/Application Support/Agent Commander`. It contains the private API socket, persisted run state, recent console output and private provider launch configuration. A detached service writes its startup errors to `service.log`. Treat the directory as private, since transcripts can contain sensitive project content.

- `AGENT_COMMANDER_HOME` selects a separate data directory for development. Its default socket is `service.sock` inside that directory.
- `AGENT_COMMANDER_SOCKET` overrides the socket path for both server and clients. Use a short path for Unix sockets.
- `AGENT_COMMANDER_CLAUDE` and `AGENT_COMMANDER_TMUX` select absolute executable paths when they are installed in a custom location. Start the service with these variables set. Standard Homebrew and user-local locations are checked automatically.
- If Claude asks for authentication, run `claude auth login` in a terminal. Reopen the app or inspect the worker’s launch error. To retry a failed planning task, start a new run.

## Current scope

The initial build supports local managed Claude Code planning workers. It retains a bounded console tail per worker. SSH hosts, Codex-managed workers, adoption of existing panes, arbitrary interactive terminal emulation, coding worktrees, and searchable transcript history are subsequent increments in the [MVP plan](MVP-PLAN.md).

Run `make test` for the Go tests. Run `make smoke` where local Unix sockets are permitted to exercise scoped MCP clients, the API and a disposable tmux worker with a deterministic model fixture. Both commands use local test data. Build the native cockpit with `make app`.
