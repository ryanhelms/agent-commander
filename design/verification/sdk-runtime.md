# Local SDK runtime verification

## Managed Claude model selection

The project selects Opus for Commander-managed Claude sessions and project agents. Claude manages internal calls. In the live CopilotKit workflow the provider reported 28,867 Opus tokens and 1,605 Haiku tokens without assigning a role to the secondary usage. [Live acknowledgement and usage](copilotkit-live/independent-claude-opus.json) · [Claude Code model settings](https://code.claude.com/docs/en/model-config)

With Commander pinned to SDK 0.1.13, a fresh local Claude coordinator inherited `ANTHROPIC_MODEL=sonnet`. The installed Claude ACP adapter 0.109.1 returned `currentValue=sonnet` and advertised `opus` as **Opus 5.5**. Commander sent one `session/set_config_option` request with `configId=model` and `value=opus`. The adapter acknowledged `currentValue=opus` before the first prompt. The test intercepted that prompt before inference.

New managed Claude coordinators and workers use the same model selection for local ACP, SSH and persistent SSH. The legacy CLI receives `--model opus`. Focused race tests covered those launch configurations, the advertised model option, the older `session/set_model` fallback, and session launch failure when the adapter rejects the value or lacks both methods. The scope tests also covered Codex and independently registered adapters. The live acknowledgement above was observed on local ACP. [Model negotiation tests](../../internal/provider/claude_model_test.go) · [Launch scope and legacy CLI tests](../../internal/provider/local_test.go)

## Default selection and rollback

Commander built against SDK 0.1.7 launched a real Claude coordinator, Claude worker and Codex worker with the runtime selector unset. It located both adapters through the SDK harness directory. The developer took both input leases and answered the coordinator's addressed question. All three turns finished and Commander kept the two workers available.

The same service state was reopened with `AGENT_COMMANDER_RUNTIME=legacy`. A new Claude run completed through the legacy CLI. In parallel, both original workers accepted AG-UI prompts, returned the expected assistant text and retained their native session IDs. Handing back the first worker left the run open. The final handback completed it. The test used an isolated socket, tmux server and checkout. [Selection tests](../../internal/provider/local_test.go) · [Ownership tests](../../internal/service/control_test.go)

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
