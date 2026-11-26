# Increment 6 demo: Remote

Run on 25 November 2026, 22:19 to 22:38, against the worktree build (`claude/commander-network-f774d6`, HEAD `34a21b0`; `dist/` binaries and the debug app built 22:19). The live Agent Commander, its daemon and its device agent were not used, quit or restarted. The host-mode relay at `https://ryan-mac.tail.internal:8443` was not restarted.

What each part ran against:

- **Remote server:** the test device agent (socket `/tmp/acn/net.sock`, the same state folder as increments 3 to 5), restarted once on the 22:19 `dist/commander-network` (PID 55775 stopped, new PID 30008). This Mac's tailnet address is `100.64.0.1`, which `ryan-mac.tail.internal` resolves to.
- **Browser:** the Claude built-in browser pane (Chromium), emulating a 375 × 812 phone in dark and light. No phone was available.
- **Tray, real:** the worktree debug app in panel mode with `COMMANDER_NETWORK_BIN` set to the real `dist/commander-network` and `COMMANDER_NETWORK_SOCKET=/tmp/acn/net.sock`, so the Remote band drove the test device agent.
- **Tray, fixture:** a second debug app instance with `Tests/Fixtures/commander-network-fixture.py` and a fresh fixture state, for the increment 5 UI retests, Reduce Motion and Full Keyboard Access.
- **Approvals, hand-offs and watch on the page:** the relay has one real user, so no real approval, hand-off or watchable resource exists. Those page states were drawn by replacing `window.fetch` in the page for the read routes only (marked "stub" below). The approve, deny and watch refusals also ran unstubbed against the device agent.
- **Merge queue:** a temporary Git repository in the session scratch folder, and a temporary group with two workspaces on the real relay, deleted afterwards.
- **Go tests:** a scratch PostgreSQL (`dist/postgres`, data from demo 5, listening on `127.0.0.1:55433` and `/tmp/acn/pg5`, stopped afterwards) and `PILOT_TEST_DOCKER=1` (local `nats:2.12-alpine` image, no pull).

## Results

| # | Step | Result | Evidence |
|---|---|---|---|
| 1 | `remote-enable` binds only to the tailnet or loopback address | Pass | `03-…json`: `http://100.64.0.1:8780`. `04-listen-sockets.txt`: one listener, `100.64.0.1:8780`. `02-…txt`: `0.0.0.0`, `[::]`, `localhost`, `:8780` and a LAN address are refused. `06-…txt`: nothing answers on `192.168.1.144`, `192.168.64.1` or `127.0.0.1` |
| 2 | `remote-devices` reports `pairing` while a code is on offer, and drops it once the code is used | Pass | `05-…json`, `25-remote-devices-after-pair.json`, `37-…json` |
| 3 | Unpaired: `GET /` is served without a session, with a CSP and no external assets; every API route answers 401; the page shows the pairing steps | Pass | `07-unpaired.txt` (page bytes equal the embedded `index.html`), `10-web-unpaired-dark.jpg`, `11-web-unpaired-light.jpg` |
| 4 | Pairing through the QR link in a real browser | Pass, with D7 | The QR code in the tray decodes to exactly `pairURL`. Opening it redirected 303 to `/` and showed the overview (`12-…jpg`). `26-pair-cookie-headers.txt`: `HttpOnly; SameSite=Strict`, 30 days. `document.cookie` is empty in the page. The same code a second time and a wrong code both give 403 |
| 5 | Tray Remote band: switch, Serving, address chip, QR code, code chip, countdown, link chip, New code | Pass, with D1 | `22-tray-remote-pairing-block.png` (code, link and QR blanked), `23-ax-…txt` (code spoken letter by letter) |
| 6 | Tray: a device that pairs ends the code, the block leaves, the device row and heading count appear | Pass | `24-tray-after-pair.png`, `24-ax-…txt`: "Remote 1", "Phone, paired Nov 25, ends Dec 25", "No code" |
| 7 | Tray: a code that runs out shows "Code expired" and Pair a device | Pass | `36-…png`, `36-ax-…txt` |
| 8 | Tray: Revoke asks inline, then the revoked browser gets 401 and the pairing screen | Pass | `28-…png` ("Revoke Phone? It is signed out at once and has to pair again.", Keep and Revoke), `29-…png`, `33-…json`; the browser read 401 and showed "Not paired" after reload |
| 9 | Switch off stops serving and keeps pairings; switch on serves again and the kept session works | Pass | `34-remote-disable.txt` (no listener, paired curl device unreachable, still listed), `34-tray-remote-off.png`, `35-remote-reenable.txt` (200 for the kept session) |
| 10 | Overview, paired, real data | Pass | `12-web-paired-overview-dark.jpg`, `30-api-overview.json` |
| 11 | Approvals: approve and deny | Pass (stub for the list; real refusals), with D2 and D4 | `13-…jpg` (two decision rows; the 0:45 one in `failure`), `14-…jpg` (outcome wells; both POSTs carried `X-Commander-Remote: 1`). Unstubbed: `31-…txt` ("no such pending request", "unknown decision", "unknown server"); `15-web-approve-refused-real.jpg` |
| 12 | Activity and mark seen | Pass (API), with D3 | `32-activity-mark-seen.txt`: unseen 2 → 0, and the tray's own `servers` count also reads 0. The page has no Mark seen control |
| 13 | Hand-offs | Pass (real empty list; stub row) | `30-api-handoffs.json`, `12-…jpg` ("No hand-offs yet"), `13-…jpg` (stub row with Watch) |
| 14 | Watchable list | Pass (API), with D3 | `30-api-watchable.json`: `[]`, as expected with one user. The page never asks for it |
| 15 | Watch view polls | Pass (stub), with D4 and D5 | `16-web-stub-watch-polling-dark.jpg`: reads every 2 s and passes each cursor (`after=`, `c1`, `c2`, …). Unstubbed: `17-web-watch-real-no-grant.jpg` |
| 16 | `X-Commander-Remote` guard on POSTs | Pass | `31-…txt`: a POST without the header, or with `0`, gets 400 "missing request guard"; DELETE gets 405 |
| 17 | Phone width, dark and light | Pass | 375 px, no horizontal scroll (`scrollWidth` 375); body background `#090A0D` dark and `#F5F6F8` light. `10-` to `19-…jpg` |
| 18 | DESIGN.md: touch scale, decision row, load note, alert band, outcome well | Pass, with D2 and D6 | Measured: buttons 44 px; body 15, name 15, sub 13.5, heading 13 (mono), state 12; header icon cell 52 × 56. Deny and Approve are joined (0 px gap). Under a minute the countdown turns `#EC9B92`. Load notes in `12-…jpg`. Alert band `19-web-alert-band-light.jpg`. Outcome wells `14-…jpg` |
| 19 | Page with reduced motion | Pass | With macOS Reduce Motion on, the browser matched `prefers-reduced-motion: reduce`; the page's rule turns `arrive` and `tick` into fades and stops lamps, spinners and the drain |
| 20 | Cockpit watch zoom from a remote worker tile | Not run | Fixture mode (`AGENT_COMMANDER_NETWORK_PANEL=1`) replaces the main window with the panel, and the real agent has no hand-off, so no tile exists to click |
| 21 | Inc. 5 step 15: the merge queue checks its input | Pass | Refused: unknown workspace (`44-`), pull-request workspace (`45-`), missing checkout (`46-`), not a Git work tree (`47-`), relative path (`48-`), no branch. At merge: from a checkout on another branch it switched to `main` and merged only the clean branch (`51-`, `52-queue-repo-log.txt`); failing tests are `failed`; a conflict is `conflict`; an unknown branch is `failed` with git's message; a dirty checkout is `failed` "the checkout has uncommitted changes" (`53-`) |
| 22 | Inc. 5: `queue-remove` | Pass | `54-` removed demo 5's stale `does-not-exist` entry; `55-` refuses a missing branch; the queue is empty afterwards (`57-…json`) |
| 23 | Inc. 5: `host.run` refusals and `allowArgs` | Pass | `60-host-run-tests.log`: "echo does not accept extra arguments", "other is not an enrolled command"; a request without a grant is still `access_denied`. The device sends the reason with the failure (`delivery.go`). Fixture UI: Extra arguments only for `run-ios-ui-tests` (`84-`), a note for `build-release` (`85-`) |
| 24 | Inc. 5: team refusals are readable | Pass | `61-` "nobody-demo6 is not your friend"; `62-` "no resource no-such-resource"; `64-` "to endorse resource …, you must be friends with its owner and have completed a request for it"; `65-` "no request rq-x from you for resource …"; `67-` "you can only claim work under your own handle"; `68-`, `69-` "no workspace no-such-ws in your groups" |
| 25 | Inc. 5 D4: Remove member and Release claim confirm inline | Pass | `80-…png` (Keep member, Remove member), `81-…png` (Keep claim, Release claim) |
| 26 | Inc. 5 D5: error sentences | Pass | `82-…png`: "Couldn’t claim it. Overlapping claim held by fixture-mei/mei-agent." The fixture now uses the relay's wording |
| 27 | Inc. 5 D6: Back names the tab | Pass | Group from People shows "‹ People"; workspace from Agents shows "‹ Agents" |
| 28 | Inc. 5 D7: accessibility | Pass | `83-…txt`: "Numbered list, 3 items"; Granted and endorsement chips are plain text; `86-…txt`: "Exit 1, 41 seconds" is one element; "iOS onboarding …, 1 claim" |
| 29 | Inc. 5 D8: DESIGN.md departures | Pass | `87-…png`: 16-cell meter. `88-…png`: hand-off state with a lamp, Sent time in the mono face. The wall band was not seen (step 20) |
| 30 | Inc. 5 step 19: two-device acceptance tests with Docker | Pass | `70-acceptance-docker.log`: `TestTwoDevicesCollaborateAcrossRelayEdges`, `TestConsultDecisionsAndAuditAcrossDevices`, `TestTwoEdgeNetwork` pass. None of them sends `host.run`, so `host.run` between two users is still covered only by the unit tests |
| 31 | All Go tests with PostgreSQL and Docker | Pass | `71-go-tests-all.log`: all 8 packages `ok` |
| 32 | Inc. 5 step 43: tray motion with Reduce Motion | Pass | Turning Remote on: with Reduce Motion the second frame cross-fades the whole block (`91-…frame2-crossfade.png`); without it the QR code is still printing row by row (`95-…frame2.png`) |
| 33 | Inc. 5 step 43: Tab with Full Keyboard Access | Pass, with D8 | `92-fka-tab-order.txt`: Tab reaches the tabs, presence, every server row, the Remote switch, the address, code and link copy cells, New code and each Revoke |
| 34 | Settings restored | Pass | `90-settings-original.txt`, `94-settings-restored.txt` |

**Pass: 33. Fail: 0. Not run: 1** (20). The page's approval, hand-off and watch states use a stubbed read (11, 13, 15); the refusals in the same steps ran against the device agent.

## Defects

- **D1 [frontend]. The tray ignores the code on offer after it restarts.** `remote-devices` returns `pairing` so a restarted tray can draw the same QR code. `MultiplayerRemoteStatus` doesn't read it, so the band shows "No code" while a code is live (`20-…png` next to `21-…json`, taken at the same moment). The fixture's `remote-devices` doesn't return `pairing` either.
- **D2 [frontend]. "Denied" is drawn neutral on the page.** DESIGN.md's outcome well puts Denied in `failure`. `decide()` uses the `off` lamp and no tone (`14-…jpg`).
- **D3 [frontend]. The page has no watchable list and no Mark seen.** It never calls `/api/watchable` or `/api/activity/seen`. A watch view opens only from a hand-off row, and nothing on the page clears the Unseen figure.
- **D4 [frontend]. Page errors are joined in lower case.** "Couldn't approve. no such pending request" (`15-…jpg`) and "Couldn't read this worker. requested shared resource or capability unavailable" (`17-…jpg`). This is increment 5 D5 on the web page.
- **D5 [frontend]. A watch link opened directly shows the server ID and retries for good.** After a reload on `#watch/…` the subtitle is `s-f01fcff5`, not the server name, and a refusal that needs a grant is retried every 2 s without end (`17-…jpg`).
- **D6 [frontend]. The alert band has three sentences.** DESIGN.md: "an error lamp and one sentence". The band reads "Can't reach your Mac. Check that this phone is on the tailnet and Remote is on in the tray. Trying again every 5 s. Showing what was read at …" (`19-…jpg`).
- **D7 [backend]. A paired device can't be named.** The contract lists each device "with the name the person gives it". `/pair` accepts `?name=`, but the QR link has none and no step asks, so every phone is "Phone" (`24-ax-…txt`).
- **D8 [frontend]. Tab order and focus ring in the tray.** With Full Keyboard Access, the footer's Sign out menu is reached between New code and the first Revoke, and again between the two Revoke buttons (`92-…txt`, steps 20–24). With focus on "Copy the address", the capture shows no focus ring on that cell (`93-…png`).

## Notes, not defects

- `GET /pair` spends the code and sets the session. A link preview or prefetch that opens the URL would pair itself instead of the phone.
- The served URL uses the IP address (`http://100.64.0.1:8780`). The contract's example uses the tailnet name.
- A wrong pairing code is refused without any rate limit. With 40-bit codes that last 10 minutes this is not practical to guess.
- `queue-remove` of an entry that doesn't exist succeeds silently. `queue-add` accepts a branch that doesn't exist and fails it at merge time.
- AGENTS.md in this worktree has no "Using this Mac" section. The run followed the coordinator's quoted permissions.
- The scratch PostgreSQL had to listen on `127.0.0.1`. The relay refuses a socket-only database URL ("invalid database connection URL"), which is why demo 5's acceptance tests could not run that way.

## Windows driven and settings changed

| Window or setting | What was done | Restored |
|---|---|---|
| Debug app instance 1 (PID 35391, worktree `dist/Agent Commander.app`, real helper on the test device agent) | Network tab, Remote switch off and on, Pair a device, Revoke Phone with confirm, Refresh. Accessibility API and window captures | Quit (SIGTERM) |
| Debug app instance 2 (PID 70854, same bundle, fixture) | People, group page, Remove member (kept), Agents, workspace, Release (kept), claim page, Knowledge, Hosts, Run on host, Reputation, hand-off detail, iOS workspace, Network, Remote switch on, off and on. Tab key events sent to this PID only | Quit (SIGTERM) |
| System Settings (opened by this run; not running before) | Accessibility › Motion and Accessibility › Keyboard. Mouse clicks on the two switches, with System Settings frontmost | Quit |
| Built-in browser pane | Opened at the remote page, phone viewport, dark and light emulation, fetch stub in the page | Viewport reset to desktop; tab closed |
| Reduce Motion | Recorded off (`ReduceMotionEnabled = 0`, `universalaccess reduceMotion` unset). Turned on 22:32, off 22:34 | Off (`NSWorkspace` reports false). The `com.apple.universalaccess reduceMotion` key now exists with value 0; the domain refused `defaults delete` |
| Full Keyboard Access | Recorded off (`FullKeyboardAccessEnabled = 0`, `AppleKeyboardUIMode` unset). Turned on 22:32, off 22:34 | Off (`FullKeyboardAccessEnabled = 0`). `AppleKeyboardUIMode`, which the switch created with value 0, was deleted |

The user's live app was not running during the run and was not opened. Its `agentctl` (PID 81027) and device agent (PID 68661) were not touched.

## State left behind

- **Test device agent:** runs the 22:19 binary (PID 30008), same state folder and socket. Remote is off, no device is paired, and no code is on offer (`38-cleanup-revoke-disable.txt`). Its merge queue is empty; demo 5's four stale entries were removed. Activity on `s-f01fcff5` is marked seen.
- **Real relay:** not restarted. The demo group `demo6-team` and its two workspaces were created and then deleted (`120-`, `121-…json`). No resources, grants, endorsements or outcomes were written.
- **Scratch:** PostgreSQL stopped. No NATS container left. The temporary Git repository, the not-Git folder, both app homes and the fixture state stay in the session scratch folder. Nothing was committed.

## Run notes

- **Device agent:** `COMMANDER_NETWORK_STATE=<scratch>/net/state COMMANDER_NETWORK_SOCKET=/tmp/acn/net.sock ./dist/commander-network serve`.
- **App launch:** `"dist/Agent Commander.app/Contents/MacOS/AgentCommander" -AllowOnlyOneInstance '<false/>'` with a scratch `AGENT_COMMANDER_HOME` and `AGENT_COMMANDER_NETWORK_PANEL=1`; instance 1 also set `COMMANDER_NETWORK_BIN=$PWD/dist/commander-network` and `COMMANDER_NETWORK_SOCKET`, instance 2 the fixture and `COMMANDER_NETWORK_FIXTURE_STATE`.
- **Go tests:** `LC_ALL=en_US.UTF-8 PILOT_TEST_DOCKER=1 PILOT_TEST_DATABASE_URL='postgres://postgres@127.0.0.1:55433/pilot?sslmode=disable' go test -count=1 -p 1 ./...` in `multiplayer`.
- **Redaction:** pairing codes and the session cookie are replaced with `REDACTED`, and the code, link and QR code are blanked in `22-…png`. The fixture's codes in `91-`, `93-` and `95-…png` are made up. No email or token appears in this folder.
