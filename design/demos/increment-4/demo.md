# Increment 4 demo: Live work

Run on 25 November 2026 against the worktree build (`claude/commander-network-f774d6`, binaries and debug app built 20:33 from `1698292`). The live Agent Commander, its daemon and its device agent were not used or restarted.

What each part ran against:

- **Live tray verbs:** the test device agent (socket `/tmp/acn/net.sock`, same state folder as increment 3). It was restarted once with the fresh `dist/commander-network` (new PID 88349).
- **Relay:** the host-mode relay at `https://ryan-mac.tail.internal:8443` was left running. Only one real user exists on it, so no two-party flow could run live.
- **Relay and device tests:** a scratch PostgreSQL 17 (`dist/postgres`, socket under `/tmp/acn/pg3`, stopped afterwards). No NATS broker is installed, so the two-device acceptance tests skip.
- **MCP tools:** `dist/agentctl mcp` driven over stdio as a coordinator, with a scratch home and a made-up credential, pointed at the test device agent.
- **UI:** the worktree's debug app in panel mode with the fixture (`COMMANDER_NETWORK_BIN` + `AGENT_COMMANDER_NETWORK_PANEL=1`).

## Results

| # | Step | Result | Evidence |
|---|---|---|---|
| 1 | Device tray verbs `watch`, `handover`, `handback`, `handovers`, `fanout`, `review-post` exist and check their input | Pass | `01-…` to `16-…json` |
| 2 | Owner side of `agent.watch`: reads the worker's history from Commander, at most 64 KiB, returns `{events, cursor, state}` | Pass (unit test), with D6 | `60-go-tests.log`: `TestWatchEventsJoinChunksAndKeepToolsAndFailures`; `actions/live.go` |
| 3 | UI: watch page shows the stream with Read-only and Signed badges, worker, line and last-read readouts, and trace rows | Pass (fixture) | `34-ui-watch.png`, `35-ui-watch-after-polling.png` |
| 4 | Watch polls every 2 s while the page is open | Pass (fixture) | Lines went 9, 10, 11 at 20:37:47, :49, :51 (`36-…txt`), `35-…png` |
| 5 | Watch stops when the page closes | Pass (fixture) | `36-watch-stop-on-leave.txt`: 7 helper calls in 8 s while open, none in 8 s after Back; Swift test `aWatchPollsFromItsCursorWhileItsPageIsOpenAndStopsWhenItCloses` |
| 6 | Cockpit shows the watch stream read-only in zoom view, labelled with owner and server | **Fail** (D5) | No watch code in `CockpitView.swift`; the stream is only a tray page |
| 7 | Watch, Suggest, Review and Fan-out end to end between two real users | Not run | One real user. The acceptance tests skip without NATS. |
| 8 | A suggestion always waits for approval and is listed as "Suggestion from fixture-sam" | Pass (fixture, unit test) | `30-ui-agents-tab.png`, `31-ui-suggestion-detail.png`; `TestApprovalModes` |
| 9 | Approving a suggestion runs it and records `ok` in the audit | Pass (fixture) | `32-ui-after-suggestion-approve.png`, `33-fixture-after-suggestion-approve.json` |
| 10 | During a handover, that friend's suggestions run without asking | **Fail** (D2) | `needsApproval` in `device/approvals.go`; `TestApprovalModes` asserts the opposite |
| 11 | Hand over control: friend, 15 min to 2 hours, countdown, "has control" row | Pass (fixture), with D3 and D9 | `51-…`, `52-…`, `53-ui-handover-done.png`, `54-fixture-handovers.json`; `04-…json` (minutes checked) |
| 12 | The holder is named by handle, and Take back works for every holder | **Fail** (D4) | `30-…png` and `51-…png` show "u-sam has control"; `50-ui-take-back.png`: "Couldn't take back control. unknown friend" |
| 13 | Take back for a holder handed over in this session | Pass (fixture) | `55-ui-after-take-back.png`; device `handback` `15-…`, `16-…json` |
| 14 | UI: review result shows the summary, then findings with Important or Nit severity and file:line | Pass (fixture) | `40-ui-review-result.png` |
| 15 | UI: review request composer (title, PR URL or diff, instructions) sends a request | Pass (fixture) | `44-…`, `45-…`, `46-ui-review-requested.png` |
| 16 | Post to PR asks for a URL, shows an inline confirmation, and posts only on "Post review" | Pass (fixture), with D7 | `41-…`, `42-ui-review-post-confirm-scrolled.png`, `43-ui-review-posted.png` (fixture URL `example.invalid`, nothing posted) |
| 17 | Device `review-post` refuses a non-HTTPS URL and a request with no review result | Pass | `09-…`, `10-…json`. A real `gh pr review` was not run, by rule. |
| 18 | UI: fan-out composer sends one prompt to each chosen worker | Pass (fixture) | `47-…`, `48-ui-fanout-sent.png`, `49-fixture-fanout-sent.json` (two children) |
| 19 | Device `fanout` needs 2–32 targets and records each child | Pass | `07-…`, `08-…json`; `device/live.go` |
| 20 | Compare view shows each result side by side; Choose winner marks one | Pass (fixture) | `37-ui-fanout-compare.png`, `38-ui-fanout-winner.png` (button reports `selected`) |
| 21 | The winner survives quitting and reopening the app | Pass, with D8 | `39-ui-fanout-winner-after-relaunch.png`, `56-winner-defaults.txt` |
| 22 | `agentctl mcp` lists `commander_network_online`, `commander_network_thread` and `commander_network_board` with the "Agents cannot…" limit | Pass | `20-mcp-tools.json` |
| 23 | `commander_network_online` and `commander_network_thread` reach the device agent, which checks the coordinator identity | Pass (refusal path) | `20-…json`: "coordinator identity denied" for the made-up credential. A successful call needs a Commander-managed run, so it was not run. |
| 24 | `commander_network_board` reaches the device agent | **Fail** (D1) | `20-…json`: "unknown coordinator network operation" from the MCP client itself |
| 25 | Go tests for Watch, Handover, Fanout, Review, Suggest and Thread | **Fail** (D11) | The requested `-run` pattern matched 2 tests (`TestApprovalsAndReceivedThreads`, `TestWatchEvents…`). All 13 device, 8 actions, 21 control and 1 mcpbridge tests that ran pass; 4 device tests skip (`60-go-tests.log`). |
| 26 | Two-device acceptance tests | Not run | `TestTwoDevicesCollaborateAcrossRelayEdges` and `TestConsultDecisionsAndAuditAcrossDevices` skip without `PILOT_TEST_NATS_URL`. `PILOT_TEST_DOCKER=1` would download a broker image. |
| 27 | Swift tests for the live-work model | Pass | `61-swift-live-tests.log`: 22 tests in 2 suites |
| 28 | Increment 3 fix: a grant without `approval` asks | Pass | `TestApprovalModes` (`""` asks); `needsApproval` returns `g.Approval != "auto"` |
| 29 | Increment 3 fix: status, result and thread follow-ups don't ask and don't spend uses | Pass | `TestApprovalModes`; relay `TestFollowUpsRemainAvailableAfterLastAggregateUse` |
| 30 | Increment 3 fix: approvals carry the friend's handle and the server | Pass, with D9(f) | `approvals()` sets `handle`, `friend`, `server`; `31-…png` shows "fixture-sam on ryan-mac" |
| 31 | Visual conformance with DESIGN.md: hard lines, lamp plus word, mono data, one primary per row, motion | Pass, with D9 | All increment 4 pages above. Corners are 2 pt or less, chips are joined cells, one filled primary per row or footer. |
| 32 | VoiceOver labels on the new controls | Pass, with D10 | Buttons name their target ("Take back control of relay-worker from fixture-jonas", "Choose mei-agent as the winner"); readouts speak as one element ("Worker state, Working", "6 lines read"); the winner reports `selected` |
| 33 | Motion with Reduce Motion on, and Tab through the new controls | Not run | Both need system settings changed (Reduce Motion, Full Keyboard Access) |

**Pass: 25** (1–5, 8, 9, 11, 13–23, 27–32; several with defects noted). **Fail: 5** (6, 10, 12, 24, 25). **Not run: 3** (7, 26, 33), plus the success path in 23 and a real `gh` post in 17.

## Defects

- **D1 [backend]. `commander_network_board` always fails.** `deviceCoordinator.post` in `internal/mcpbridge/network_client.go` accepts only `online` and `thread`:

  ```go
  if verb != "online" && verb != "thread" {
      return nil, errors.New("unknown coordinator network operation")
  }
  ```

  The device agent does handle `POST /coordinator/board`, but the MCP client never sends it (`20-mcp-tools.json`).
- **D2 [backend]. A friend with control still waits for approval on suggestions.** `needsApproval` skips approval during a handover only when `c.Action == "agent.ask"`. `agent.suggest` is checked next and always asks. The contract says a handover switches both `agent.suggest` and `agent.ask` to `auto`, and the UI promises it: "one friend's prompts and suggestions to relay-worker run without asking" (`51-…png`). `TestApprovalModes` asserts the current behaviour (`{"agent.suggest", "auto", handover: true, ask: true}`). The contract's Co-pilot section also says suggestions queue "whatever the grant's approval mode", so settle the wording, then align code, test and UI copy.
- **D3 [backend]. `handover` accepts any user and any resource, and is lost on restart.**
  - It accepted the owner's own handle and a resource that doesn't exist (`13-…json`). It doesn't check that the peer is a friend, holds a grant on the resource, or that the resource is the owner's.
  - For a non-friend, `handovers` returns `"handle": ""` (`14-…json`), which leads to D4.
  - Handovers live only in memory (`Agent.handovers`). Restarting the device agent ends every handover early, and the tray then shows nobody with control.
- **D4 [frontend]. The holder is shown by user ID, and Take back then fails.** The fixture's `handovers` rows have no `handle` (the device has sent one since `1698292`). The UI falls back to the user ID, shows "u-sam has control", and sends `u-sam` as the `handle` to `handback`, which answers "unknown friend" (`50-…png`). The same happens on a real device whenever `handle` is empty (D3). Add `handle` to the fixture, and have Take back work from the user ID or the friend list rather than the display fallback (`MultiplayerLive.swift` line 195).
- **D5 [frontend]. No watch view in the cockpit's zoom view.** The contract asks for the stream read-only in zoom, labelled with owner and server. It exists only as a tray page.
- **D6 [backend]. Watch event times are the time of the read.** `watchEvents` stamps every event with `now`, so a first page of history shows one time for every line. The contract also names `GET /v1/workers/{worker}/output`; the code reads `/history?view=acp` (deliberate per `1698292`). Update the contract to match.
- **D7 [frontend]. The Post to PR confirmation opens out of sight.** After "Post to PR…", the footer button disables and the confirmation renders below the scroll edge (`41-…png`). Nothing visible changes until the reader scrolls (`42-…png`). Scroll the confirmation into view or show it in the footer.
- **D8 [frontend]. The fan-out winner is stored in the app's standard user defaults under the bare request ID.**
  - Any instance with the cockpit bundle ID, including a fixture or debug run, writes into the live app's domain `local.agentcommander.cockpit` (`56-winner-defaults.txt` shows the fixture's `rq-fanout-1`). The demo removed that key afterwards.
  - Request IDs aren't scoped by server, so two servers can collide.
- **D9 [frontend]. Departures from DESIGN.md.**
  - (a) The holder row uses a filled `working` lamp (`30-…png`, `51-…png`). DESIGN.md specifies the Holder badge: `attention` tone with a hand icon.
  - (b) The countdown has no draining line under the time.
  - (c) Times are in the system face, not mono data: approval detail "8:36 PM" and "Nov 26 at 8:36 PM" (`31-…png`), review "Sent 8:04 PM" (`40-…png`), compare "sent 8:16 PM" (`37-…png`).
  - (d) The worker readout shows "awaiting input" with the `off` lamp (outlined circle) instead of `waiting` (open arc) (`35-…png`).
  - (e) On the Control page, "Hand over control" is a system-face heading, while its sibling "Who has control" is a mono band heading (`51-…png`).
  - (f) Approval rows in "Needs you" show the friend but not the server; only the detail page shows the server.
- **D10 [frontend]. Accessibility gaps.**
  - Finding rows and trace rows have role `AXUnknown` (their labels are good).
  - The Friend picker on the Control page is exposed twice, and the presence menu three times (as in increment 3).
  - The holder is spoken as "u-sam has control" (D4).
- **D11 [backend]. No Go tests for most of increment 4.** Nothing tests `handover`, `handback` or `handovers`, `fanout` and its child records, `reviewHandler` or `parseReview`, `review-post`, the suggest flow on the device, the coordinator verbs `online`, `thread` and `board`, or the MCP network tools. The requested `-run 'Watch|Handover|Fanout|Review|Suggest|Thread'` matched 2 tests.
- **D12 [backend]. A 96 KiB diff can't reach a review.** The tray handler caps a request body at 98,304 bytes (`http.MaxBytesReader` in `tray.go`). A 96 KiB diff, once JSON-escaped and wrapped with the title, PR and instructions, is over that cap. `reviewHandler` has no explicit 96 KiB check of its own. This is from reading the code; it was not run.

## State left behind

- The test device agent runs the 20:33 binary (PID 88349), with the same state folder and socket. Its handover map is empty. The local thread for `no-such` from increment 3 (D12 there) is still in its state.
- The host relay was not touched.
- The demo app instances (PIDs 1266 and 13345) were quit. The scratch PostgreSQL was stopped.
- The `multiplayer.fanout.winners` key that the demo wrote into `local.agentcommander.cockpit` (D8) was deleted.
- Profile, presence and membership were not changed. No grants or resources were published on the real relay. Nothing was posted to GitHub.

## Run notes

- App launch: the worktree binary ran directly with `-AllowOnlyOneInstance '<false/>'`, a scratch `AGENT_COMMANDER_HOME`, `AGENT_COMMANDER_NETWORK_PANEL=1`, `COMMANDER_NETWORK_BIN=Tests/Fixtures/commander-network-fixture.py` and a scratch `COMMANDER_NETWORK_FIXTURE_STATE`.
- UI driving: the accessibility API, scoped to the demo PID. No keystrokes were sent.
- **Unexplained event.** The fixture approval `ap-1` (a Consult from fixture-sam) was approved at 20:38:21 without a deliberate press. During the same minutes the window moved and the tray once switched to the Network tab between commands. Pressing Back from the watch page again did not approve anything, so it was not reproduced. Treat it as outside input until shown otherwise.
- Fixture rules that shape the shots: a review whose title contains "wait" stays pending (`46-…png`). The fixture's `watch` adds one line per call until its trace ends at 11 lines.
- MCP: `AGENT_COMMANDER_ROLE=coordinator`, made-up run, worker and token, `COMMANDER_NETWORK_SOCKET=/tmp/acn/net.sock`. The device agent checks the identity against the Commander service and refused it, as expected.
- Go tests: `PILOT_TEST_DATABASE_URL=postgres://demo@/pilottest?host=/tmp/acn/pg3&port=55432 go test ./internal/device/ ./internal/actions/ ./internal/control/ -v`, then `go test ./internal/mcpbridge/` from the repository root. PostgreSQL needs `LC_ALL=en_US.UTF-8`.
