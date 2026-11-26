# Increment 3 contract: Share and consult

Scope from [the spec](COMMANDER-NETWORK-SERVERS.md), increment 3: capabilities, the shared directory, sharing from the cockpit, approval modes, budgets with cost attribution, audit, and the Consult and Hand off modes with threads and result artifacts. It builds on increments 1 and 2.

## What exists today

- An owner publishes a **resource** (`repo`, `agent` or `coordinator`) with the actions it supports. The owner grants one friend specific actions on it, with an expiry and a use limit.
- A requester's coordinator submits sealed requests. The owner's device claims each one, checks the grant (`actions.Execute`) and runs it. Results return sealed.
- `agent.ask` sends a prompt to a local worker and returns its answer. That is **Consult** in its simplest form.

## Changes

### 1. Capabilities

A resource gains an optional `capabilities` object, set by its owner:

```json
{"harness": "claude | codex | other", "model": "free text", "slots": 2,
 "tools": ["MCP server or CLI names"], "environments": ["ios-simulator", "gpu", "..."]}
```

The relay stores it and returns it with each resource (`PUT /v1/resources/{id}` and `GET /v1/resources`). The device agent fills `harness` and `model` for agent resources from the local Commander service when it can, and the owner can edit them.

### 2. Shared directory and access requests

- The tray's directory lists every friend's resources per server, from `GET /v1/resources`: name, kind, owner, capabilities, the actions offered, and the actions already granted to me.
- `POST /v1/access-requests` with `{"resource", "actions": [...], "note"}` creates a request. The owner gets an `access.requested` event. `GET /v1/access-requests` lists requests sent to me and by me. `DELETE /v1/access-requests/{id}` withdraws or declines one.
- The owner approves by creating the grant as today. The relay then marks the request `granted` and the requester gets `grant.received`.

### 3. Grant policy: approval mode and budget

A grant gains these fields, set by the owner when granting:

| Field | Values | Default |
|---|---|---|
| `approval` | `ask` (each use waits for the owner) or `auto` (runs within limits) | `ask` |
| `budgetTokens` | Maximum provider tokens across all uses; 0 means no token limit | 0 |
| `attribution` | `owner` (owner's account, counted against the budget) or `requester` (usage recorded for the requester to settle) | `owner` |

These fields live on the owner's device as part of `actions.Grant`, and are mirrored to the relay for display only. Enforcement happens on the owner's device, as it does today.

**Ask each time:** when a claimed request's grant has `approval: ask`, the owner's device does not run it. It stores the request as **pending** and emits a local `approval.pending` activity item. Tray verbs:

- `approvals` returns pending requests: id, server, friend, resource, action, a payload summary, and when it arrived.
- `approve` with `{"id"}` runs the request now.
- `deny` with `{"id", "reason"}` returns a `denied` result to the requester.

A pending request expires after 24 hours and returns `expired`.

**Budget:** each run records the tokens it used, when the local Commander service reports them. Once `budgetTokens` is reached, further requests return `budget_exhausted`.

### 4. Audit

The owner's device keeps an audit log per grant in its state folder: request id, friend, action, start and end times, outcome, tokens and a result summary. Tray verb `audit` with `{"resource"?, "peer"?}` returns the latest 200 entries. The requester's device keeps the same record for requests it sent.

### 5. Consult

**Consult** is `agent.ask` with two additions:

- **Context bundle:** the payload may include `context`, a list of `{"name", "content"}` items (files, diffs, logs), up to 96 KiB in total. The owner's worker receives them with the prompt.
- **Thread:** every request has a thread (section 7).

### 6. Hand off

New action `agent.handoff` on `agent` resources. The payload is `{"title", "task", "repository"?, "context"?}`. The owner's device creates a Commander run for its enrolled agent with that task and returns `{"run", "worker"}` at once. The requester tracks it with:

- `agent.status`: `{"run"}` returns `{"state", "summary", "updatedAt"}`.
- `agent.result`: `{"run"}` returns the final result and its **artifacts**: `{"kind": "patch | branch | pull_request | file | report", "name", "content" or "url"}`.

Both are granted together with `agent.handoff`. On the requester's side, the device agent lists hand-offs with tray verb `handoffs`, which returns id, server, friend, title, state and updatedAt. The cockpit shows each hand-off as a remote worker on the wall.

**Applying results:** tray verb `apply-artifact` with `{"handoff", "artifact"}` applies a `patch` with `git apply`, or fetches a `branch`, into a checkout the requester names. Nothing is applied automatically.

### 7. Threads

Every Consult and Hand off request has a thread. A comment is `{"id", "author", "authorKind": "person | agent", "at", "text"}`. Comments travel as sealed envelopes, exactly like requests and results, so the relay sees only routing metadata. Tray verbs:

- `thread` with `{"request"}` returns the comments.
- `comment` with `{"request", "text"}` posts one.

### 8. Share from the cockpit

The cockpit's worker and repository context menus gain **Share…**. It opens a sheet that picks a server, a friend, the actions, the approval mode, an expiry and use-limit preset (1 hour, 1 day or 1 week; 1, 10 or unlimited uses), a token budget and the attribution. It then calls `resource-add` if needed, followed by `grant`.

## Ownership

| Part | Owner |
|---|---|
| Relay: capabilities, access requests, grant fields mirror, events | Codex |
| Device agent: approvals, budget, audit, hand-off, status, result, apply, threads, Consult context | Claude |
| Tray and cockpit: directory, access requests, approvals queue, grant sheet, hand-off workers on the wall, threads, artifacts, Share… | Fable |
