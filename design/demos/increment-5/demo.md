# Increment 5 demo: Teams

Run on 25 November 2026 against the worktree build (`claude/commander-network-f774d6`, binaries and debug app built 21:05 from `33215d6`). During the run the branch moved to `e7a43b2` (a UI merge, `76279c1`). Everything here was tested at `33215d6`, but conformance is checked against the current DESIGN.md. The live Agent Commander, its daemon and its device agent were not used, quit or restarted.

What each part ran against:

- **Real relay, one user:** the host-mode relay at `https://ryan-mac.tail.internal:8443`, through the test device agent (socket `/tmp/acn/net.sock`, same state folder as increments 3 and 4). The agent was restarted once on the 21:05 `dist/commander-network` (new PID 55775). The relay was not restarted.
- **Merge queue:** a temporary Git repository in the scratch folder with three branches: one clean, one that fails its tests, and one that conflicts.
- **`host.run`:** a temporary demo test in `internal/actions` (deleted after the run) with a temporary command file. Nothing was published to the real relay.
- **Relay and device tests:** a scratch PostgreSQL (`dist/postgres`, socket `/tmp/acn/pg5`, stopped afterwards). No NATS broker is installed, so the two-device acceptance tests skip.
- **MCP:** `dist/agentctl mcp` over stdio as a coordinator, with a scratch home and a made-up credential, pointed at the test device agent.
- **UI:** the worktree's debug app in panel mode with the fixture. The cockpit wall needs the main window, which the fixture can't drive, so D8 was checked with the Swift render tests at `33215d6`.

## Results

| # | Step | Result | Evidence |
|---|---|---|---|
| 1 | Relay groups: create, list with members and owner handle, delete | Pass | `02-…`, `03-…`, `120-…`, `121-…json` |
| 2 | Only friends can be added to a group | Pass, with D3 | `04-group-add-non-friend.json`: refused, but as a bare "not found" |
| 3 | Group grants expand to each member; members added later gain them; members removed lose them; the owner's device mirrors them | Pass (Go tests) | `TestGroupsAndExpandedGrants`, `TestGroupMemberAddedAfterPolicyTightens`, `TestTrayGroupGrantsFollowMembership` in `65-go-tests.log`. Not run on the real relay: no friend and no resource there. |
| 4 | UI: groups band, group page, add-friend menu, remove member, delete with inline confirm, Share with group sheet | Pass (fixture), with D4 and D6 | `70-…`, `71-…`, `73-…`, `74-ui-group-member-removed-without-confirm.png`, `75-ui-group-delete-confirm.png` |
| 5 | Relay workspaces: create with goal, repository, base, group and integration; bad integration refused | Pass | `06-…`, `07-workspace-bad-integration.json` |
| 6 | Claims: issue and paths claims; an overlapping claim (child or parent path, or the same card) gets 409 naming the holder; release frees it; a holder of another user is refused | Pass | `08-…` to `13-…`, `18-…`, `21-…`, `22-…json` |
| 7 | A claim expires 10 minutes after the holder's device lease ends | Pass (code) | `workspaces.go`: `expires_at + interval '10 minutes'` from the live lease; `expiresAt` in `08-…json` |
| 8 | Combined view: workspaces list with their claims | Pass | `11-workspaces-combined.json`; UI `77-ui-workspace.png`, `77-ax-workspace-before.txt` |
| 9 | UI: new workspace, claim page, conflict text, claim and release | Pass (fixture), with D4 and D5 | `89-…`, `90-…`, `79-…`, `80-ui-claim-conflict.png` ("Couldn't claim it. already claimed by fixture-sam/sam-agent"), `81-…png` |
| 10 | Task board: create card, claim (kind `card`) sets `claimed` and the assignee, complete with a result, bad state refused, the card claim ends when done | Pass | `14-…` to `20-…json`; claims after completion listed in step 6 |
| 11 | UI board: state tally, claim a card, open it, complete it, add a card | Pass (fixture), result text not set | `82-ui-card.png`, `83-…`, `84-fixture-cards-after-complete.json`. The result field is a text editor that the accessibility API can't fill, so the card completed with an empty result. |
| 12 | `commander_network_board` is listed and reaches the device agent (increment 4 D1) | Pass (refusal path) | `61-mcp-board.json`: "coordinator identity denied" from the device, no longer "unknown coordinator network operation". The success path needs a Commander-managed run; `TestCoordinatorBoard` covers the device side. |
| 13 | A board-style claim (`PUT` state `claimed`) also creates a `card` claim | Pass | `62-…json`, `63-…txt`, `64-…json` |
| 14 | Merge queue on the device: add three branches, test and merge in order | Pass | `51-…`, `53-queue-merge.json`: `merged`, `failed` (test output kept), `conflict` (merge aborted); `54-queue-repo-log.txt`: only the clean branch landed, and the tree is clean |
| 15 | Merge queue checks its input | **Fail** (D1) | `55-…json`: an unknown workspace and a missing checkout are accepted. `57-…json`: the missing checkout is reported as `conflict` with no output. |
| 16 | The merge queue is kept per server | Pass | File is `state/servers/s-f01fcff5/merge-queue.json`; `56-queue-unknown-server.json`; `TestTrayServerQueues`, `TestQueueMigrationWithExistingServerFile` |
| 17 | UI merge queue: queue a branch, test and merge, failure output well | Pass (fixture) | `86-…png`, `85-ui-workspace-after-merge.png`, `85-ax-…txt`, `87-ax-queue-fail-branch.txt`, `111-render-…png` |
| 18 | `host.run`: only enrolled commands run; arguments append only when allowed; exit code and the last 64 KiB of output; environment label published | Pass, with D2 | `60-host-run-harness.log`: exit 3 and exactly 65,536 bytes ending in the last line; extra arguments appended for `allowArgs`; refused otherwise, for an unenrolled command and with no grant; `TestHostRunRunsOnlyEnrolledCommands`, `TestTrayHostPublishesEnrolledCapabilities` |
| 19 | `host.run` end to end between two users, through grant and approval | Not run | One real user; acceptance tests skip without NATS |
| 20 | UI: hosts page, run on host, output well with exit state | Pass (fixture), with D2 and D7 | `91-ui-hosts.png`, `92-…`, `93-ui-host-run-fail.png` |
| 21 | Knowledge: share, new version, versions list, list | Pass | `32-…` to `35-…json` |
| 22 | Secrets never travel: a token and `password=` are refused with a placeholder hint; a `${NAME}` placeholder is accepted | Pass | `36-…`, `37-…`, `38-…json` (values made up and redacted); UI refuses before sending: `98-ui-knowledge-secret-refused.png` |
| 23 | Install kinds: prompt and instructions return the content; MCP writes the chosen file; no destination or an unknown kind is refused | Pass | `39-…` to `43-…json` |
| 24 | Keychain placeholders that aren't set are reported as missing | Pass | `39-knowledge-install-mcp-missing.json`: `"missing": ["DEMO5_GH_TOKEN"]`, placeholder left in a 0600 file |
| 25 | Skill install writes `~/.claude/skills/<name>/SKILL.md` | Pass (Go test, fixture) | `TestKnowledgeInstall`; UI `96-…png` (fixture writes nothing). Not run on the real machine, by rule. |
| 26 | The admin's `knowledgeDefault` and `knowledgeWidest` limit visibility | Pass (Go test) | `TestKnowledgeVersionsRespectAudienceAndPolicy`; real relay allows `server`, so not exercised there |
| 27 | UI: knowledge library with kind filter, item with Markdown and versions, install skill, MCP item listing what you fill in | Pass (fixture), with D7 | `94-…`, `95-…`, `96-…`, `97-ui-knowledge-mcp.png` ("You fill in: GITHUB_TOKEN"). Save to file and Copy weren't pressed (file dialog, clipboard). |
| 28 | Reputation: outcomes, counts, median time, visibility; endorsements | Pass (Go test), with D3 | `TestOptInDirectoryAndRequestReputation`. On the real relay only the refusals for an unknown resource could run (`44-…`, `47-…`, `48-…json`). |
| 29 | UI: reputation page, endorse a skill | Pass (fixture), with D8 | `99-…`, `100-ui-reputation-endorsed.png` |
| 30 | Directory search: handles, and only listed resources | Pass | `45-…`, `46-…json`; UI `102-ui-directory-search.png` (people and listed resources) |
| 31 | Admin policy read; `/v1/info` has the admin contact and the policy summary | Pass | `30-admin-policy-read.json`, `31-info.json` (contact redacted) |
| 32 | Admin policy write, suspend, unsuspend, device revoke | Pass (relay write, Go test); suspend and revoke not run | `TestRelayPolicy` covers the write. Suspend and revoke have no control test of their own (only `reputation_test.go` touches suspension). Not run on the real relay, by rule. |
| 33 | UI: relay policy page, inline confirm before suspending, refusal of an unknown member, save | Pass (fixture), with D5 | `103-…`, `104-ui-policy-suspend-unknown.png`, `105-fixture-policy-after-save.txt` |
| 34 | The tray's relay verb reaches only team routes | Pass | `49-route-not-allowed.json` |
| 35 | Go tests: control, device, actions | Pass | `65-go-tests.log`: 62 top-level tests pass, 4 skip (2 need NATS, 2 need the macOS Keychain flag) |
| 36 | Go tests: `mcpbridge` | Pass, with D10 | `66-mcpbridge-tests.log`: 3 pass, with `GOWORK=dist/go.work` (the worktree's relative `../agent-acp` replace doesn't resolve) |
| 37 | Swift tests: fixes, teams, render | Pass | `112-swift-tests.log`: 26 tests in 4 suites, at `33215d6` |
| 38 | Increment 3 D8: hand-offs on the cockpit wall as remote workers | Pass (render, tests), with D8 | `110-render-d8-wall-remote-workers.png`; `listsHandoffsAsRemoteWorkers`, `readsHandoffsForTheWallWithNoPanelOpen`. Not seen in a running main window. |
| 39 | Increment 3 D10: tab group, single pickers, thread comments as text | Pass, with D7 | Tabs are an `AXTabGroup` "Sections" with a selected value; Resource, Group and Kind pickers are one element each; thread comments are static text with speaker and time |
| 40 | Increment 3 D11: the hand-off report is drawn as Markdown | Pass | `106-ui-d11-handoff-report-markdown.png`, `106-ax-…txt`: "sam-agent" is a heading, no `##` |
| 41 | DESIGN.md conformance on the Teams pages | Pass, with D4, D6, D8 | Hard lines, mono band headings with counts, lamp plus word on claims, cards and queue rows, one primary per footer, joined-cell state tally, copy chips for IDs |
| 42 | VoiceOver labels on the new controls | Pass, with D7 | Buttons name their target ("Release Sources/Wall", "Claim Bound the renewal wait with a deadline", "Remove fixture-sam from relay-team", "Run an enrolled command on jonas-mac-mini"); readouts speak as one element ("claims, 3") |
| 43 | Reduce Motion, and Tab through the new controls | Not run | Both need system settings changed |

**Pass: 40** (1–14, 16–18, 20–42, several with defects noted). **Fail: 1** (15). **Not run: 2** (19, 43), plus the success path of the board tool (12), skill install on the real machine (25), suspend and revoke on the real relay (32), and the main-window wall (38).

## Defects

- **D1 [backend]. The merge queue accepts entries it can't merge, and mislabels them.**
  - `queue-add` accepts an unknown workspace and a checkout that doesn't exist (`55-…json`). It doesn't check that the workspace uses `queue` integration, or that the checkout is on the workspace's base branch. It merges into whatever branch is checked out.
  - A missing checkout is reported as `conflict` with empty output (`57-…json`), because `mergeBranch` treats any `git merge` error as a conflict.
  - No verb removes an entry, so a bad entry stays in the queue file for good.
- **D2 [backend]. `host.run` refusals don't say why, and the tray can't tell which commands take arguments.**
  - Extra arguments to a command without `allowArgs`, and an unenrolled command, both come back as "action is outside the current local grant" (`60-host-run-harness.log`).
  - The published capabilities list tools and environments but not `allowArgs`, so the Run page offers "Extra arguments" for every command (`93-…png`).
- **D3 [backend]. Team refusals are bare.** Adding a non-friend to a group returns "relay HTTP 404: not found" (`04-…json`). A group grant on an unknown resource returns "invalid request" (`05-…json`). An endorsement or outcome for an unknown resource returns "access denied" or "not found" (`47-…`, `48-…json`). None says which part was wrong.
- **D4 [frontend]. Remove member and Release claim act on the first press.** DESIGN.md (Increment 5) says releasing a claim, suspending a member "and the like" use the inline confirm. Delete group and Suspend member do; Remove member (`74-…png`) and Release (step 9) don't. Removing a member also takes away the group's grants.
- **D5 [frontend]. Error sentences are joined in lower case.** "Couldn't claim it. already claimed by fixture-sam/sam-agent" (`80-…png`) and "Couldn't suspend fixture-nobody. not found" (`104-…png`). The relay's wording also differs from the fixture's ("overlapping claim held by …").
- **D6 [frontend]. Back says "Network" from other tabs.** A group opened from the People tab and a workspace opened from the Agents tab both show "‹ Network", and go back to the tab they came from.
- **D7 [frontend]. Accessibility gaps.**
  - Markdown list items have role `AXUnknown` ("1., Read the failing test…") on the knowledge item. DESIGN.md: nothing is offered without a role.
  - The Granted check, the success notice's tick and each endorsement chip report `AXSelected` true, and the Granted icon is spoken as "Selected".
  - The run result's "exit 1" and "41 s" are separate elements rather than one readout.
  - Workspace rows say "1 claims".
- **D8 [frontend]. Departures from DESIGN.md.**
  - The reputation meter has 24 cells; the Meter atom has 16 (`MultiplayerMeter(… cells: 24 …)`, `100-…png`).
  - At `33215d6` the wall's Remote workers band has a large corner radius and a system-face heading without a count (`110-…png`). The `76279c1` merge describes a 2 pt band with a mono heading. That build wasn't tested.
  - In the hand-off detail, "Done" has no lamp, and Sent and Checked times are in the system face (as in increment 4 D9).
- **D9 [frontend]. A pull-request workspace links only the repository's pull-request list.** The contract says Commander links the pull requests in the workspace view. The page has one "Open pull requests" link to `…/pulls` (`88-ax-…txt`).
- **D10 [backend]. The MCP network client still has no tests.** `internal/mcpbridge` has 3 tests, none for `deviceCoordinator` or the `online`, `thread` and `board` tools (the rest of increment 4 D11). The worktree can't build `mcpbridge` tests without `GOWORK=dist/go.work`.

## State left behind

- **Test device agent:** runs the 21:05 binary (PID 55775), with the same state folder and socket. Its per-server merge queue has 4 settled entries (`merged`, `failed`, `conflict`, and a `conflict` for the made-up `does-not-exist` workspace), which no verb can remove (D1).
- **Real relay:** not restarted, and its policy was only read. The demo group, workspace, claims and cards were removed by deleting the group (cascade). Two private knowledge items remain, because the relay has no delete route: `demo5-review-prompt` (version 3, set back to private) and `demo5-gh-mcp` (placeholder only, no secret). No resources or grants were published. Profile, presence and membership were not changed.
- **Demo app:** the instance (PID 77709) was quit. The user's live app (PID 81015) was not touched. No `multiplayer.*` key was found in `local.agentcommander.cockpit`.
- **Scratch:** PostgreSQL was stopped. The temporary Go test file was deleted. The temporary Git repository, the 33215d6 source copy and the fixture state stay in the session scratch folder. Nothing was written to `~/.claude/skills`. Nothing was merged into a real repository or posted to GitHub.

## Run notes

- **App launch:** the worktree binary ran directly with `-AllowOnlyOneInstance '<false/>'`, a scratch `AGENT_COMMANDER_HOME`, `AGENT_COMMANDER_NETWORK_PANEL=1`, `COMMANDER_NETWORK_BIN=Tests/Fixtures/commander-network-fixture.py` and a scratch `COMMANDER_NETWORK_FIXTURE_STATE`.
- **UI driving:** the accessibility API, scoped to the demo PID. SwiftUI menus aren't exposed to it, so menu choices (server for New workspace, Hosts and Knowledge; the Group picker) were made with Down and Return. These were sent only after checking that the demo PID was frontmost. Text editors can't be filled through the API, so the share-knowledge content was typed the same way.
- **Unexplained input, again.** During the run the tray switched to the People tab, a Share sheet opened with a resource chosen, the claim page opened, the window was zoomed to full screen, and the fixture recorded fixture-priya's friend request as accepted. None matches a command sent here. One Return press, sent while a menu was closing, did open "Share with group…". The rest is unexplained. Treat it as outside input, as in increment 4. Screenshots taken after those moments were retaken or removed.
- **Screenshots:** pages taller than the window couldn't be scrolled without moving the pointer, so content below the fold is evidenced by accessibility dumps (`*-ax-*.txt`) and by the Swift renders.
- **Go tests:** `PILOT_TEST_DATABASE_URL='postgres://postgres@/pilot?host=/tmp/acn/pg5&port=55433' go test -count=1 -p 1 -v ./internal/control/ ./internal/device/ ./internal/actions/`, with `LC_ALL=en_US.UTF-8`.
- **Swift tests:** from a `git archive` copy of `33215d6`: `MULTIPLAYER_RENDER_DIR=… swift test --filter 'MultiplayerFixesTests|MultiplayerTeamsTests|MultiplayerRenderTests'`.
- **MCP:** `AGENT_COMMANDER_ROLE=coordinator`, made-up worker, run and token, `COMMANDER_NETWORK_SOCKET=/tmp/acn/net.sock`.
