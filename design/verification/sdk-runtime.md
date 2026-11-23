# Local SDK runtime verification

The standalone Go example ran against Claude Code and Codex using the pinned local profiles. A multiline prompt containing shell punctuation survived a cold history read in both providers. Each streamed a real assistant response, returned an actionable permission request, acknowledged a separately targeted interrupt, and resumed the original native session in a fresh process.

| Provider | Decision observed | Effect |
| --- | --- | --- |
| Claude | Selected the offered one-time allow for a test write | The requested file appeared in the disposable checkout. |
| Codex | Selected the offered cancellation for a test write in read-only mode | The write turn ended and the file was absent. |

## Two-worker cockpit

Computer Use exercised the opt-in Claude backend in a separate signed app bundle with its own socket, state directory, tmux server and disposable project. The coordinator delegated Copper and Maple through MCP. Each worker opened its own native session and raised a different question.

1. Sent `QUARTZ-COPPER-71` to Copper’s request from the attention sidebar. Copper reported that word. Maple continued waiting on its own request.
2. Selected **Interrupt the current turn of Maple**. Maple became idle and its question closed. Copper stayed completed.
3. Selected **Send follow-up** on Maple. Its focused console showed human control and the addressed follow-up. Its original conversation produced `MAPLE-WOKE-39`.
4. Quit the app and restarted the isolated daemon. The saved Commander records held six native handles across two runs, with empty output and console fields. The composed response `MAPLE-WOKE-39` was absent from the saved state. Before reopening the GUI, Maple had zero live events.
5. Reopened the cockpit. Its wall restored Copper’s reported word and Maple’s composed response under their original workers. The read used native history and preserved Maple’s input ownership.

The SDK generator, language conformance suites, Go race tests, and vet passed. Commander’s Go race suite and native build passed. Existing sessions retain their original path. The SDK runner is opt-in for new local Claude sessions. The standalone Codex profile exposes native live and history operations, while managed Codex requires per-run isolation from inherited MCP servers.
