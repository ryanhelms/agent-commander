# Main window increment 6: the triage tray (plan)

Increment 6 of [the main window redesign plan](MAIN-WINDOW-REDESIGN-PLAN.md) makes the Commander network tray a triage tray. It keeps the decisions and quick actions that suit a 400 pt menu-bar panel. Its dense pages open the matching main-window page instead. Issue #19. Written 26 November 2026, after PR #17 merged into `develop` at `91df5dc`.

## Owner decisions needed first

The increment contracts give the dense pages to the tray, so the owner must agree to each move. Each decision:

1. **Which pages leave the tray.** The proposal is the "Moves" column below.
2. **Remove or link.** Either the tray drops a moved page and shows an "Open in Agent Commander" row, or it keeps the page and adds the link. The proposal is to remove each page, but only after its window page has passed a running-window check.
3. **The tray's tabs.** The proposal is to keep Agents, Network and People, with less in each.

## What stays and what moves

| Tray area | Stays in the tray | Moves to the main window | Window place |
|---|---|---|---|
| Home | Status strip, presence, server health and trust, friend and server rows | — | — |
| Approvals and access | Approve, deny and the grant sheet, decided inline | The full list with history | `network.approvals` |
| Friend requests | Accept and decline | — | `people.requests` |
| Shared directory | Consult, Share and Request access as quick actions | Browsing and the inspector | `network.directory` |
| Hand-offs | Take back | The list, results and Apply | `network.handoffs` |
| Threads | — | All | `network.threads` |
| Audit | — | All | `network.audit` |
| Fan-out and compare | — | All | `network.fanout` |
| Watch, control and review | Take back control | Watching and reviewing, in the wall and zoom | Agents wall |
| Groups | — | All | `teams.groups` |
| Workspaces, board, claims and queue | — | All | the workspace's place under `teams.workspaces` |
| Hosts and host run | — | All | `teams.hosts` |
| Knowledge | — | All | `teams.knowledge` |
| Reputation and search | — | All | `teams.directory` |
| Policy and moderation | — | All | `teams.admin` |
| Add server, hosting, profile, invite, membership | All | — | — |

## How the tray opens a window page

The main window adds one typed request, built in main-window files only:

- `CommanderOpenRequest`: a place ID, plus an optional server and item, such as a workspace or a request.
- `CommanderWindowRouter.open(_:)`:
  - brings the cockpit forward through `SingleInstanceCoordinator`, reopening it if it is closed;
  - selects the place and the item;
  - activates the app.
- The tray depends only on this value and this call, not on the window's models or templates. The router is a Command, as recorded in [PATTERN-DECISIONS.md](PATTERN-DECISIONS.md); add a short entry there when it is built.
- Tests:
  - every `MultiplayerSharePage` that moves maps to an existing `CommanderPlace` ID;
  - an unknown item opens the place without an item;
  - a closed window reopens.

The tray side adds an "Open in Agent Commander" row atom where a page used to be. It sends the request and then closes the panel. That change is in `Multiplayer*` files, so the network session makes it.

## Who builds what

| Piece | Owner | Files |
|---|---|---|
| `CommanderOpenRequest`, the router and its tests | Main-window session (Fable 5.2, `frontend-design` first) | New `CommanderWindowRouter.swift` and `CommanderWindowRouterTests.swift`; small edits to `ShellLive.swift` and `CockpitView` |
| The open-in-window row atom and the slimmed tray routes | Network session | `MultiplayerTray*.swift`, `MultiplayerShare*.swift`, `MultiplayerTeams*.swift` and their tests |
| `DESIGN.md`: the open-in-window row, and the tray's reduced page list | Whoever adds each, in the same PR | `DESIGN.md` |
| Running-window check of both sides | Codex, or a verifier subagent | `design/demos/main-window-6/verify/` |

## Order

1. The owner agrees to the table and to remove or link.
2. Main-window PR: the router, its tests, `DESIGN.md`.
3. Network-session PR: the tray links to the window and drops the moved pages. It removes a page only once its window page has passed a running-window check. The increment 5 check is in [main-window-5/verify](demos/main-window-5/verify/REPORT.md).
4. Running-window check of the two together: each tray link opens the right page and item, with the window closed and with it open.

## Prerequisites

- The open increment 5 defects found by the running-window check are fixed, so that no tray page is removed while its window replacement is broken.
- The network session's tray-request issue #18 is closed, or its open items don't block a moved page.
- The main-window gaps carried over from increment 5:
  - Admin moderation needs member and device reads.
  - The combined view needs a full read.
  - The workspace owner isn't exposed.
  
  Until these land, the tray keeps Policy and moderation, or links to the window's partial page. The owner decides which.

## Acceptance

- Every moved tray page is either removed or a link, and each link opens the matching window page and item.
- The tray still decides approvals, access and friend requests inline, sets presence, shows server health and trust, and offers Consult, Share and Take back.
- Nothing in the console, terminal or pretty view changes.
- `swift test` stays green. Both sides pass the running-window check at 1280 × 800 and 1440 × 900.

## Also carried over

These are main-window work and can share the router PR:
- theming the wall's own controls: the run header, "Group by parent", the presentation menu and the key hints;
- the missing "Teams" breadcrumb segment;
- redrawing the increment 4 renders.
