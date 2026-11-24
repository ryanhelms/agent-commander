# First native terminal

## Inline rollout

Computer Use verified the installed app on the isolated RetryLab run. The coordinator and both worker tiles opened in Terminal mode, and focusing Backoff budget kept the coordinator and selected worker live. A pending Transport review request showed that worker’s terminal and its addressed reply field in the floating PiP. Commander recorded the submitted choice on Transport review’s request. Detach exposed Backoff budget’s transcript, and reconnect reopened its original pane. Returning to the wall left exactly three read-only viewers and their three size helpers on the original sessions.

The inline views use the approved window’s square console surface, with the connection indicator in each existing title bar. PiP keeps its request controls under the terminal. The tmux status line and dotted padding are visible when a viewport extends past the pane’s current dimensions. The viewer leaves those dimensions under the control of the worker and any writable tmux client.

The native well appears in All Agents and Smart View design previews with sample output. Those pages currently run as design previews.

## Standalone viewer

[Worker viewer at 920 × 580 points](worker-viewer.png). The capture shows the production SwiftUI viewer containing SwiftTerm’s AppKit view in an offscreen window on macOS. A real local Commander service launched two isolated tmux workers. A scripted model supplied deterministic output for the review. The green status bar and the printed attach instructions came from tmux and the managed runner.

The operator opens **Watch Terminal…** from the coordinator or worker display menu. The native viewer shares the console title bar and square surface. It shows the worker’s live screen and keeps its last frame on detach. The existing Console and Pretty presentations retain their AG-UI subscriptions.

On November 24, 2026, Computer Use opened **Watch Terminal…** for **Transport review** in the rebuilt primary Agent Commander app. Fresh worker output appeared in that viewer, and the sibling’s distinct output appeared on its own wall tile. The tmux switch-session shortcut left the viewer on Transport review. After **Detach** and **Reconnect**, the viewer displayed a line emitted during detachment. Closing and reopening its window displayed another line emitted while closed. The final window was left observing the original worker in the isolated RetryLab test run.

| Check | Observed result |
| --- | --- |
| Worker targeting | Live text arrived in the selected native view. The sibling marker did not appear. Pressing the tmux switch-session shortcut in AppKit kept the same worker on screen. |
| Detach and reopen | The Swift view reattached after detach and after full unmount. Output produced while it was closed appeared on return. |
| Terminal geometry | The read-only viewer preserved the detached worker’s 120 × 38 grid. A writable external terminal resized it to 112 × 39 while the narrower viewer was still open. |
| Client cleanup | Closing the PTY disconnected both viewer-owned clients. Both original worker processes and a separately attached writer survived. |
| Packaged helper | A staged build retained the cockpit bundle ID and passed strict code-signature verification. Foundation found its bundled `agentctl`, which resolved the selected QA worker through the owner socket. The package included the SwiftTerm resource bundle. |
| Scrollback | The tmux client uses the alternate screen. Wheel scrolling in the native viewer did not recover earlier lines. Provider history is accessible in the existing source inspector. |

The repeatable transport check uses real PTYs and private sockets. Run `AGENT_COMMANDER_TEST_TMUX=1 go test ./cmd/agentctl -run TestNativeTerminalObserver -count=1`. Run `make test-native` for the Swift tests including detach, generation changes and unsupported targets.
