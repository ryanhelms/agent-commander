# Increment 4 contract: Live work

Scope from [the spec](COMMANDER-NETWORK-SERVERS.md), increment 4: Watch, Co-pilot, Review exchange, Fan-out, and agent access to the network through `agentctl mcp`. It builds on increments 1 to 3. Every new action is an ordinary granted action: the owner grants it, and the owner's device enforces it.

## Watch

New action `agent.watch` on `agent` resources, with payload `{"after": "<cursor or empty>"}`. The owner's device reads the shared worker's live history from the local Commander service (`GET /v1/workers/{worker}/history?source=live&view=acp`) and turns agent messages, tool calls and tool failures into events. The history carries no per-record time, so `at` is when the owner's device read the page. It returns events after the cursor: `{"events": [{"at", "kind": "message | tool | status", "text"}], "cursor", "state"}`. It returns at most 64 KiB per call.

- Granting `agent.watch` is how an owner makes a worker watchable.
- The requester's tray polls every 2 seconds while a watch view is open. The tray verb `watch` with `{"server", "resource", "after"}` sends the request and waits up to 8 seconds for the result.
- The cockpit shows the stream read-only in zoom view, labelled with the owner and server.

## Co-pilot

New action `agent.suggest` on `agent` resources, with payload `{"text"}` of at most 4 KiB.

- The owner's device always queues a suggestion for approval, whatever the grant's approval mode. The approvals list shows it as "Suggestion from sam".
- On approval, the device sends the text to the worker as an `agent.ask` turn from the owner. The suggester's result is the worker's answer. Denial returns `denied`.
- **Control:** tray verb `handover` with `{"resource", "handle", "minutes"}` (1–240; the friend must hold `agent.ask` or `agent.suggest` on the resource) temporarily switches that peer's `agent.suggest` and `agent.ask` grants to `auto`. They return to `ask` when the time ends, or at once with `handback`. The tray shows who has control and how long is left.

## Review exchange

New action `review.request` on `agent` resources, with payload `{"title", "diff" (up to 96 KiB) or "pr" (URL), "instructions"}`.

- The owner's device runs it as an `agent.ask` turn with a fixed review prompt. It returns `{"summary", "findings": [{"file", "line", "severity": "important | nit", "text"}]}`. When the worker's answer is not valid JSON, `summary` holds the raw answer and `findings` is empty.
- On the requester's side, tray verb `review-post` with `{"request", "pr"}` posts the findings to the pull request as a review comment through `gh` with the requester's own GitHub login. Nothing posts automatically.

## Fan-out

`submit` already accepts up to 32 targets.

- Tray verb `fanout` with `{"server", "targets": [{"resource", "action"}], "payload"}` sends one payload to every target. It returns the request id, and `sent` and `thread` work per child.
- The tray's compare view shows each target's result side by side, with a button to choose the winner. The choice is recorded locally.

## Agent access to the network

`agentctl mcp` adds these tools to the existing `commander_network_*` set:

| Tool | Does |
|---|---|
| `commander_network_online` | Lists contacts with presence and each one's shared resources, from the device agent's `contacts` and `discover` |
| `commander_network_thread` | Reads or adds to a request's thread |

Consult, Hand off, Watch, Suggest, Review and Fan-out stay reachable through `commander_network_discover`, `commander_network_submit` and `commander_network_receipt`, because they are ordinary granted actions. Agents never accept friends or create or change grants.

The device agent's coordinator API adds the matching verbs `online` and `thread`.

## Ownership

| Part | Owner |
|---|---|
| Owner-side actions, the tray verbs `watch`, `handover`, `handback`, `review-post` and `fanout`, and the coordinator verbs `online` and `thread` | Claude |
| The `agentctl mcp` tools | Codex |
| Tray and cockpit: watch view in zoom, suggestions in approvals, handover controls, review results and posting, the fan-out compare view | Fable |
