# Increment 3 demo: Share and consult

Run on 25 November 2026 against the worktree build (`claude/commander-network-f774d6`, binaries built 20:04 from `05942f8`). The live Agent Commander, its daemon and its device agent were not used or restarted.

What each part ran against:

- **Live tray verbs:** the test device agent (socket `/tmp/acn/net.sock`, state in the session scratchpad as in increment 2). It was running a 19:29 binary, so it was restarted once with the fresh `dist/commander-network`.
- **Relay:** the host-mode relay at `https://ryan-mac.tail.internal:8443`. It was left running, but it is a 19:29 build. Access requests landed at 19:39 (`c1d9d97`), so this relay answers 404 for them. Relay behaviour was checked with the relay's own tests instead.
- **Relay and device tests:** a scratch PostgreSQL 17 (`dist/postgres`, socket under `/tmp/acn/pg3`, stopped afterwards).
- **UI:** the fixture (`COMMANDER_NETWORK_BIN` + `AGENT_COMMANDER_NETWORK_PANEL=1`), because only one real user exists on the relay.

## Results

| # | Step | Result | Evidence |
|---|---|---|---|
| 1 | Relay stores and returns `capabilities` on `PUT /v1/resources/{id}` and `GET /v1/resources`, including in the directory | Pass (relay test) | `60-go-tests.log`: `TestSharedDirectoryAndAccessRequests` |
| 2 | Device agent fills `harness`/`model` for agent resources; owner can edit capabilities | **Fail** (D2) | Code: `resource-add` in `multiplayer/internal/device/tray.go` |
| 3 | Access requests on the relay: create, list sent and received, withdraw/decline, `access.requested`, marked `granted`, `grant.received` | Pass (relay test) | `60-go-tests.log`: `TestSharedDirectoryAndAccessRequests`, `TestShareGrantLimitsAndDottedSubmissions` |
| 4 | Access requests through the live relay | Not run | Running relay predates the feature: `02-…`, `03-…`, `04-access-request-*.json` all return `relay HTTP 404` |
| 5 | UI: shared directory lists friends' resources with kind, owner, capabilities, offered and granted actions | Pass (fixture) | `45-ui-directory.png` |
| 6 | UI: request access (actions + note), list sent requests, withdraw | Pass (fixture) | `46-ui-request-access.png`, `47-ui-access-requests.png`, `48-ui-after-withdraw.png`, `49-fixture-access-requests.json` |
| 7 | UI: owner reviews an incoming request in the share sheet, sets Auto, 10 uses, 50,000 token budget, "They settle"; request becomes `granted` | Pass (fixture) | `24-ui-access-review.png`, `25-ui-access-grant-filled.png`, `26-ui-after-access-grant.png`, `30-fixture-after-grant-approve-deny.json` |
| 8 | UI: approvals queue shows Consult and Hand off waiting; detail page; Approve runs it; Deny tells the friend | Pass (fixture), with D9 | `20-ui-agents-tab.png`, `21-ui-approval-detail.png`, `22-ui-after-approve.png`, `23-ui-deny.png`, `30-…json` (audit gains `ok` and `denied`) |
| 9 | Device: `approvals`, `approve`, `deny` | Pass for the empty queue and unknown IDs, **Fail** for fields (D4) | `05-approvals.json`, `06-approve-unknown.json`, `07-deny-unknown.json` |
| 10 | Grant default approval is `ask` | **Fail** (D1) | Code: `needsApproval` in `multiplayer/internal/device/approvals.go` |
| 11 | Grant policy fields mirrored to the relay and shown back to the owner | **Fail** (D3) | Code: `grant` and `status` in `tray.go` |
| 12 | Budget: tokens recorded per run; `budget_exhausted` once reached | **Fail** (D5) | Code: no `budget_exhausted` in `multiplayer/`; `AuditEntry.Tokens` is never set |
| 13 | UI: audit page for a resource (newest first, outcome, tokens, summary) | Pass (fixture) | `27-ui-audit.png` |
| 14 | Device: `audit` | Pass (empty), with D6 | `08-audit.json` |
| 15 | UI: Consult shows capabilities, sends a prompt, shows the answer; a pending request shows "Waiting for the owner" | Pass (fixture) | `35-ui-consult.png`, `36-ui-consult-pending.png`, `37-ui-consult-answer.png`, `40-fixture-sent.json` |
| 16 | Consult context bundle (Attach files…) | Not run | It opens a file picker over the user's own folders. The `context` field is accepted by `actions.ask` (`validContext`). |
| 17 | UI: Hand off compose and send; returns run at once; Check status; Get result with report, patch and branch artifacts | Pass (fixture), with D11 | `38-ui-handoff-compose.png`, `39-ui-handoff-sent.png`, `28-ui-handoff-detail.png`, `29-ui-handoff-status.png`, `31-ui-handoff-result.png` |
| 18 | Device: `handoffs`, `sent` | Pass (empty), with D4 | `09-handoffs.json`, `10-sent.json` |
| 19 | Apply an artifact (`git apply` a patch, fetch a branch) | Not run in UI; **Fail** by code (D7) | Apply… opened a folder picker showing the user's Recents. It was cancelled, with no screenshot taken. `13-apply-unknown.json` |
| 20 | Hand-offs shown as remote workers on the cockpit wall | **Fail** (D8) | Shown only in the tray's "Live remote work" (`20-…png`). No hand-off code in `CockpitView.swift` or `Organisms.swift`. |
| 21 | UI: thread shows person and agent comments; posting a comment adds it | Pass (fixture), with D10 | `32-ui-thread.png`, `33-ui-thread-after-comment.png`, `34-fixture-threads.json` |
| 22 | Device: `thread`, `comment` | Pass for reads, with D12 | `11-thread-unknown.json`, `12-comment-unknown.json` |
| 23 | Share… sheet: friend, actions, approval, expiry and use presets, token budget, attribution; calls `grant` | Pass (fixture), with D9 and D13 | `41-ui-share-sheet.png`, `42-ui-share-sheet-filled.png`, `43-ui-after-share.png`, `44-fixture-share-grant.json` |
| 24 | Share… from the cockpit's worker and repository context menus | Not run | Panel mode replaces the cockpit. Code wires `MultiplayerShareLauncher` into worker and repository menus (`CockpitView.swift` 517, 591, 811). |
| 25 | Tabbed tray: Agents, Network, People with counts | Pass | `20-ui-agents-tab.png`, `50-ui-network-tab.png`, `51-ui-people-tab.png` |
| 26 | Keyboard: ⌘1 / ⌘2 / ⌘3 switch tabs; the tab reports `selected` | Pass | `52-ui-cmd2-network.png`; the accessibility API showed `AXSelected` move to Agents, then Network |
| 27 | Keyboard: Tab moves focus through the custom controls | Not run | Full Keyboard Access is off on this Mac, and changing it is a system setting. With it off, Tab kept focus on the window. |
| 28 | VoiceOver labels on custom controls (tabs, segments, approve/deny, artifacts, withdraw) | Pass, with D10 | Segments and tabs expose `AXSelected`. Buttons name their target ("Deny: fixture-sam wants to hand off tasks to the agent", "Withdraw your request for mei-docs"). |
| 29 | Motion with Reduce Motion off and on | Not run | Toggling Reduce Motion changes a system setting. Code: the tab switch is a 0.18 s opacity fade; the row transition and lamp pulse read `accessibilityReduceMotion` and drop movement (`MultiplayerSkin.swift` 21–25, 481–487). |
| 30 | Device-agent tests for approvals, audit, budget, threads, hand-off tray verbs, apply | **Fail** (D14) | `go test ./internal/device/ ./internal/actions/ -run 'Handoff\|Thread\|Approval\|Audit\|Share\|Budget'` matched only `TestHandoffCreatesRunAndOnlyItsPeerCanRead`. All 20 relay tests and 9 device tests pass on scratch PostgreSQL (`60-go-tests.log`). The two-device acceptance test skips without NATS. |

**Pass: 17** (1, 3, 5, 6, 7, 8, 13, 14, 15, 17, 18, 21, 22, 23, 25, 26, 28; several with defects noted). **Fail: 8** (2, 10, 11, 12, 20, 30, the field check in 9, and 19 by code). **Not run: 5** (4, 16, 24, 27, 29), plus the UI part of 19.

## Defects

- **D1. A grant without `approval` runs automatically.** The contract default is `ask`. `needsApproval` returns `g.Approval == "ask"`, so an empty value runs at once. `grant` stores `in.Approval` as given, and `actions.Grant`'s comment says empty means auto. Any caller that omits the field (CLI, MCP, older tray) shares without approval.
- **D2. Capabilities can't be set or filled from the device.** `resource-add` sends only `kind`, `name` and `actions` to `PUT /v1/resources/{id}`. The tray `input` struct has no `capabilities` field. The device does not read harness or model from the Commander service. `status` also drops `capabilities` from own and shared resource rows. On a real relay, the directory, Consult header and "Your agents" show no harness, model, slots, tools or environments.
- **D3. Grant policy fields are not mirrored to the relay and not returned to the tray.** `grant` sends only `action`, `expires_at` and `max_uses` to `PUT /v1/grants/…`. `trayGrant` (in `status`) has no `approval`, `budgetTokens` or `attribution`. The approval detail page and the grant list can show these fields only on the fixture.
- **D4. Device `approvals` and `handoffs` lack contract fields.** `approvals` returns `peer` as the sender's user ID, with no `server` and no friend handle (`handles` is declared and unused). `handoffs` returns `request`, `child`, `resource`, `action`, `title`, `at`, `status` and `value`, but no `server`, `friend`, `state` or `updatedAt`. On a real relay the queue shows a user ID and the hand-off rows have no run state.
- **D5. Token budgets are not enforced, and usage is not recorded.** Nothing in `multiplayer/` produces `budget_exhausted`. `record` in `delivery.go` never sets `Tokens`. The budget and attribution set in the Share sheet have no effect.
- **D6. Audit outcomes don't match the contract or the UI.** The owner's device writes `completed`, `declined` or `uncertain`. Denied, expired and (future) budget refusals are all `declined`, with the code buried in `summary`. The UI maps `denied`, `expired` and `budget_exhausted` to distinct labels that never appear. The requester's device keeps no audit record of requests it sent (contract section 4).
- **D7. `apply-artifact` differs from the contract and can overwrite files.**
  - It takes `request` (the `agent.result` request), not `handoff`.
  - A `branch` artifact is refused ("not applied automatically") instead of fetched.
  - A `report` or `file` artifact is written to `<checkout>/<basename of the remote name>` with `os.WriteFile`. A friend's artifact named `Makefile` or `Package.swift` silently replaces that file in the requester's checkout.
- **D8. Hand-offs are not shown as remote workers on the cockpit wall.** They appear only in the tray's "Live remote work" section.
- **D9. Deny sends no reason, and the approval page omits the budget and the cost.** The UI's Deny buttons (inline and on the detail page) post no `reason`. The device's `decide` ignores `reason` anyway. The approval detail shows Approval and Limits, but not `budgetTokens` or `attribution`, although the grant has them (`21-…png`).
- **D10. Accessibility gaps.**
  - Each sheet and the directory have four unlabeled `AXButton`s at the end of the scroll area (`ax` dumps after `24-…png` and `45-…png`).
  - The Resource and Friend pickers, and the presence menu, are each exposed two or three times (as in increment 2 D7).
  - Thread comments have role `AXUnknown`.
  - Tabs are plain `AXButton`s rather than tab or radio controls (`AXSelected` is set).
- **D11. The hand-off report shows raw Markdown.** "## sam-agent" appears literally in "Result report" (`31-…png`).
- **D12. `comment` on an unknown request succeeds.** For any ID that matches the pattern and isn't in the sent log, the device creates a local thread and returns the comment (`12-comment-unknown.json`). It should reject a request it never received.
- **D13. Status, result and thread actions inherit "Ask each time" and the use limit.** Sharing Send prompts + Hand off creates six grants (`agent.ask`, `agent.handoff`, `agent.status`, `agent.result`, `thread.read`, `thread.comment`), all with `approval: ask` and `maxUses: 10` (`44-…json`). `needsApproval` applies to every action. Each Check status, Get result and thread read therefore waits for the owner and uses up one of the 10 uses. The Share sheet also has no server picker (the contract lists one); the resource's server is implied.
- **D14. No device-agent tests cover the increment 3 owner flows.** The device agent has no unit or acceptance tests for approvals, deny or expiry, audit, budget, threads, `handoffs` or `apply-artifact`. Only `actions.TestHandoffCreatesRunAndOnlyItsPeerCanRead` covers the hand-off action itself.

## State left behind

- The test device agent runs the 20:04 binary (PID 61324), with the same state folder and socket as before. Its state gained one local thread for the made-up request `no-such` (D12).
- The host relay was not touched and still runs the 19:29 build. Rebuild or restart it before demoing access requests live.
- The demo app instance (PID 71075) was quit. The scratch PostgreSQL was stopped. The user's live app, daemon and device agent were not touched.
- Profile, presence and membership were not changed. No resources or grants were published on the real relay.

## Run notes

- App launch: the worktree binary ran directly with `-AllowOnlyOneInstance '<false/>'`, a scratch `AGENT_COMMANDER_HOME`, `AGENT_COMMANDER_NETWORK_PANEL=1`, `COMMANDER_NETWORK_BIN=Tests/Fixtures/commander-network-fixture.py` and a scratch `COMMANDER_NETWORK_FIXTURE_STATE`.
- UI driving: the accessibility API was scoped to the demo PID. Keyboard shortcuts were sent only after checking that the demo PID was frontmost.
- Fixture quirk: the first Consult prompt contained "wait", so the fixture held it as pending (`36-…png`). A second prompt was answered (`37-…png`).
- Relay tests: `PILOT_TEST_DATABASE_URL=postgres://demo@/pilottest?host=/tmp/acn/pg3&port=55432 go test ./internal/control/ ./internal/device/ -v`. PostgreSQL needs `LC_ALL=en_US.UTF-8`, or it exits with "postmaster became multithreaded during startup".
