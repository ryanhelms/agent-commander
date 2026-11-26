# Main window increment 3: the network pages

The eight Network places and People now have full-size pages. Each is a clickable design preview with sample data, and each is bound to the network model in the live window. This increment also fixes the defects the running-window check of increment 2 found.

**Not seen in a real window.** Everything here was checked by build, 633 unit tests and headless renders. No window was opened, clicked or driven.

## Open a preview

```sh
open "dist/Agent Commander.app" --args --design-preview network-servers
```

| Scenario | Opens sidebar B on |
|---|---|
| `network-servers` | Servers, with harbor's certificate review open |
| `network-directory` | Directory |
| `network-approvals` | Approvals, with mira's request open |
| `network-handoffs` | Hand-offs, with a finished hand-off open |
| `network-threads` | Threads, with that hand-off's thread open |
| `network-audit` | Audit, studio's log |
| `network-fanout` | Fan-out, with three answers side by side |
| `network-shared` | Shared |
| `people` | People |

They are in the preview gallery menu under "Main window redesign". Every place is also a click away inside `shell-b`. Choose the scenario again to reset the sample data.

### What to click

| Page | Try |
|---|---|
| Servers | Choose a row. On harbor: Trust new certificate…, then confirm. On studio: rename it, switch Favorite, Remove server…. |
| Directory | Choose build-box, Request access, tick the action, Send request. The row turns to "Asked". |
| Approvals | Approve or Deny on a row: a spinner, then "Done" and the confirmation on the row for 2.4 s, then the row leaves. Withdraw on priya's row fails the first time: the row says why and keeps Withdraw. Review opens the share sheet beside the list; Share answers the request. Choose Unlimited and Auto within limits to see a refused grant stay on the sheet. |
| Hand-offs | Choose a row. Check status and Get result change the report. Apply posts a confirmation. Thread goes to Threads. |
| Threads | Choose a request, type a comment, Post comment. |
| Audit | Switch server, or choose one resource from the menu. |
| Fan-out | Choose winner (again to clear it). New fan-out…, tick two workers, type a prompt, Send. |
| Shared | Choose a resource. Take back, Share…, Audit. |
| People | Accept or Decline tomas. Share on a friend. Edit profile, change the status, Save profile. Filter the activity feed. |

## Renders

Each is a whole window at 1440 × 900, one pixel per point, console theme unless named.

```sh
NETWORK_RENDER_DIR=design/demos/main-window-3 swift test --filter NetworkRender
```

| Picture | File |
|---|---|
| Servers, certificate review | `network-servers-console.png` |
| Servers, settings | `network-servers-settings-console.png` |
| Directory | `network-directory-console.png` |
| Approvals | `network-approvals-console.png`, `network-approvals-black-glass.png` |
| Approvals, share sheet opened by Review | `network-approvals-grant-console.png` |
| Hand-offs | `network-handoffs-console.png` |
| Threads | `network-threads-console.png` |
| Audit | `network-audit-console.png` |
| Fan-out | `network-fanout-console.png` |
| Shared | `network-shared-console.png` |
| People | `people-console.png` |
| People, profile editor | `people-profile-console.png` |
| The live cockpit drawing a network page | `live-network-handoffs-console.png` |

The increment 2 renders in `../main-window-2/` were not redrawn. They now differ in three places: the presence readout reads "Auto: Online", a countdown has a drain line, and `live-network-servers` would show the real page.

## How a page is built

Every page is the same template: header with one action, telemetry strip, alert band, then a collection beside an inspector.

- **The table is the main window's.** It is the new data table molecule.
- **The inspector holds the tray's organism for the chosen row, unchanged.** It is 420 pt wide so a tray organism sits at its own measure.
- **A page takes one value and never reads a model.** `NetworkPages` carries the content, the window's selections, the drafts as bindings, and the actions.

| Page | Main-window pieces | Tray organisms inside, unchanged |
|---|---|---|
| Servers | Server table | Certificate review, server settings, hash chip, identity band |
| Directory | Directory table | Directory card (the directory page with one entry), request-access form |
| Approvals | Approval table, access table | Approval page, grant sheet |
| Hand-offs | Work table | Hand-off detail, review page |
| Threads | Work table (narrow) | Thread page |
| Audit | Audit table | — |
| Fan-out | Work table (narrow), compare columns | Fan-out composer |
| Shared | Shared table | Holder row, row, grant sheet |
| People | Request table, people grid | Friend row, identity band, activity band, profile editor, grant sheet |

### Counterparts built because the tray's form is fixed to its width

- **Audit table.** The tray's audit page is a list at 400 pt. At page scale it is a table with the same outcome words.
- **Compare columns.** The tray's compare page gives each answer 196 pt and scrolls beyond two. The page form gives each column the room there is.
- **People grid.** The tray's friend groups are one column. The grid puts the tray's own friend row in as many columns as fit.

## Live or demo-only, per page

"Opens the panel" means the action starts the flow in the network model and shows the network panel on it, because that flow's page is still the tray's.

| Page | Live | Opens the panel | Not offered live |
|---|---|---|---|
| Servers | Table, open a server, certificate check, trust, rename, connect automatically, favorite, remove, sign in, sign out | Add server…, Invite someone, Membership | — |
| Directory | Table, directory card, Request access and Send request | Consult, Hand off, Watch | Request review, Run on host |
| Approvals | Both tables, Approve, Deny, Decline, Withdraw with a result on the row, Review opening the hosted grant sheet, the approval page, Audit | — | — |
| Hand-offs | Table, hand-off detail, Check status, Get result, review page, Post to PR…, Thread | Apply and Save on an artifact | — |
| Threads | List, thread, Post comment, Refresh | — | — |
| Audit | Table, server choice, resource menu, Refresh | — | — |
| Fan-out | List, compare columns, Choose winner, New fan-out…, Send, Thread | — | — |
| Shared | Table, grants, Take back, Share…, Audit | — | Revoke a grant |
| People | Friend requests with Accept and Decline and their arrival, friends, Share, identity, Edit profile and Save, activity feed and Mark as seen | Add friend…, Invite someone, Membership | — |

Needs you (increment 2) gained the same answers: a friend request now offers Decline, shows how long it has waited, and a failed answer shows its reason on the row. Review opens the grant sheet in Approvals. A row's text opens its page.

### How the live pages use the network model

- **One file binds them.** `NetworkPagesLive.swift` reads the model into values and sends every intent to a public model method.
- **One boundary carries the answers.** `NetworkPageActions` is a struct of async closures returning `NetworkActionResult`, which mirrors `MultiplayerActionResult` case for case. Live, it calls `acceptFriend`, `declineFriend`, `decide`, `remove`, `prepareGrant` and `sendGrant`. Needs you uses the same boundary.
- **The grant sheet is `MultiplayerGrantHost`.** `prepareGrant` fills the draft, the window hosts the sheet in an inspector, and the tray does not move. A refused grant stays on the sheet.
- **Everything else follows the model's route.** Opening a server, an approval, a hand-off, a thread, the audit log or a fan-out in the window calls the method the tray calls (`openServer`, `share.open`, `live.openReview`). The tray shows the same page when it is opened next. See the first tray request.
- **Two places open something when you enter them.** Servers opens the first blocked server, or the first server. Audit opens the first signed-in server's log.
- **The window is still one viewer.** `CockpitView` already calls `open()` and `close()` on the model, so it polls while the window shows.

## Increment 2 defects

| # | Defect | What changed |
|---|---|---|
| 1, 2 | ⌥⌘1 did nothing, ⌥⌘4 opened Runs | The mode keys are now bound once, with the window's other shortcuts and before ⌘1, and name the digit itself on every keyboard layout (`localization: .custom`). The cause was not confirmed; this is the fix for the likely one. **Needs a check in a window.** |
| 3 | Presence readout had no role, value or press | It is one menu button named "Your presence" with the value "Auto: Busy". The servers readout keeps its own help text. |
| 4 | No check in the presence menu | The choices are menu toggles, so the one in force has a native check. |
| 5 | Toolbar items in glass capsules | The shell's toolbar items hide the shared background. The console display menu and the adapter notice are console controls and were left as they are. **Needs a check in a window.** |
| 6 | New run opened offline | The row is dimmed and takes no press while the service is offline, like ⌘N. |
| 7 | ⇧⌘A from another page | Documented: with no request from your own workers it does nothing. The increment 2 README says so now. |
| 8 | Theme choice with `-appearance.theme` | The Appearance section says the theme is fixed by a launch argument for this run. |
| 9 | Empty breadcrumb on Runs | It reads "Agents / Runs" when no run is open. |
| 10 | "Open network panel" from Approvals | Moot: the placeholder is gone. |
| Minor | "1 claims", Settings eyebrow, countdown over an hour, drain line, answered row's hidden text | "1 claim"; upper case; `h:mm:ss`; a 56 × 2 pt line that drains; the cell is hidden from accessibility once answered. |

### Defect 11, proposed and not built

The cockpit can't be pointed at the network fixture without `AGENT_COMMANDER_NETWORK_PANEL=1`, which replaces the cockpit with the panel.

Proposal: let `MultiplayerModel.live()` honour `COMMANDER_NETWORK_BIN` and `COMMANDER_NETWORK_FIXTURE_STATE` whenever `AGENT_COMMANDER_HOME` is also set, with or without the panel variable. A run with its own home folder is already a test run, so the user's live app can never pick the fixture up by accident. This is a change in `Multiplayer*.swift`, so it is the tray session's to make.

## Gaps

- **Black glass shows console-styled detail.** The tray's atoms and organisms always draw in the console theme. In black glass the tables follow the theme and the inspectors' contents do not. See `network-approvals-black-glass.png`.
- **A live row that succeeds leaves at once.** The model drops an answered approval or request as soon as it is confirmed, so the row is gone before "Done" shows. The alert band carries the confirmation. A failure stays on its row. The previews hold the row for 2.4 s.
- **The pages and the tray share one route.** Choosing a hand-off in the window moves an open tray to it, and navigating the tray changes what the window's inspector shows.
- **Apply is not wired in the window.** The plan holds Apply back until defect D7 (`apply-artifact` can overwrite files) is fixed. Whether it is fixed on `develop` was not checked. Apply and Save show the network panel on the same hand-off.
- **Approve and Deny are wired**, as they have been in Needs you since increment 2. The plan also names D1 (a grant with no `approval` runs automatically) as blocking. Whether D1 is fixed was not checked.
- **Threads lists only what the model already holds**: hand-offs, reviews and fan-out answers. A consult's thread is reachable only from the tray.
- **Times in the previews stand still**, except the holder's countdown on Shared, which the tray's row runs against the real clock.
- **The preview's Needs you inbox and its network pages use different samples.** The sidebar's counts follow the network sample.
- **The hosted grant sheet has a fixed height of 560 pt** and scrolls inside the inspector, because the host brings its own scroll view.
- **Hairline rows are 34 pt for one line.** Rows with a person cell or two lines are taller.

## Proposed, not built

- Request review and Run on host from the Directory inspector.
- Revoke on a grant row in Shared.
- A Watch page in the main window (the plan's increment 4).
- Folding `NeedsYouVerbStrip` and the tray's verb strip into one theme-aware molecule.

## Where the pieces are

| Piece | File |
|---|---|
| Values, rows, the action boundary, deep links | `Sources/AgentCommander/NetworkPagesModel.swift` |
| Data table, inspector, alert band, page template | `Sources/AgentCommander/NetworkPageMolecules.swift` |
| Servers | `Sources/AgentCommander/NetworkPagesServers.swift` |
| Directory, Approvals, Shared, grant inspector | `Sources/AgentCommander/NetworkPagesSharing.swift` |
| Hand-offs, Threads, Audit, Fan-out | `Sources/AgentCommander/NetworkPagesWork.swift` |
| People, and the page router | `Sources/AgentCommander/PeoplePage.swift` |
| Sample network and preview state | `Sources/AgentCommander/NetworkPagesPreview.swift` |
| Live binding | `Sources/AgentCommander/NetworkPagesLive.swift` |
| Tests | `Tests/AgentCommanderTests/NetworkPagesTests.swift`, `NetworkRenderTests.swift` |

`DESIGN.md` was updated in this change: the data table, person cell, row outcome, page alert band, inspector, compare columns and people grid; the network page layout; the shared route and per-row answers. Requests to the tray session are in [`TRAY-REQUESTS.md`](TRAY-REQUESTS.md).
