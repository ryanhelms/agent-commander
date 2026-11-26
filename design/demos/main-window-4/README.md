# Main window increment 4: live work on the wall

## Where the wall stood at `5680b11`, before this increment

Written before any code changed.

### Already there (from the network session, in `MultiplayerWall.swift`)

- **Remote workers band.** Hand-offs you sent show under the local workers as up to three remote worker tiles. The band draws nothing until there is a hand-off.
- **Remote worker tile.** The console title bar and harness surface of a local tile, with task, from, via and sent as mono lines.
- **Remote zoom.** Choosing a tile zooms it: the hand-off's task and state, then the tray's watch view, read-only. It reads while it is on screen.
- **Network pages.** Hand-offs, Fan-out, Approvals and Shared are full pages bound to the network model (increment 3). Shared shows who holds control and offers Take back.

### Gaps

| # | Gap | Fix in this increment |
|---|---|---|
| 1 | The wall's own frame ignores the theme. In the console theme the pane headings, the worker groups (15 pt corners, glass fill) and the count badge are still black glass. | Wall tokens in both themes; the headings, groups and band read them. |
| 2 | The Remote workers band is console-styled in both themes, so in black glass it has 2 pt corners beside 15 pt groups. | A band composed outside `MultiplayerWall.swift` from the same tile, in the wall's frame. |
| 3 | The wall says nothing when a friend holds one of your workers. Control shows only in the tray and on Shared. | A dock under the held worker's tile: holder badge, countdown, Take back. |
| 4 | A waiting Co-pilot suggestion shows in Needs you and Approvals, not at the worker it is for. | The same dock names who suggests what and opens its review. |
| 5 | The wall reads `MultiplayerModel.shared` inside the cockpit page, so it can't be drawn from values or rendered headless with remote work. | The cockpit takes the wall's live work as a value and sends actions out. |
| 6 | The band and the zoom lead only to the tray ("Open in tray", "n more…"). Reviews and fan-outs you sent don't show on the wall. | Links go to Hand-offs and Fan-out; reviews and fan-outs that still need you are rows in the band. |
| 7 | Apply and Save on a hand-off's artifact open the network panel. | Apply in the Hand-offs inspector, with a confirmation naming the checkout and a result per artifact. |
| 8 | The console tiles' shells and controls must not change. | Untouched. Everything above sits around the tile. |

## What this increment built

**Not seen in a real window.** Everything here was checked by build, 694 unit tests and headless renders. No window was opened, clicked or driven.

### Live work on the wall

| Part | What it does | Live |
|---|---|---|
| Wall frame | The Coordinator and Worker wall headings, the worker groups and the remote band read the theme's new `wall` tokens. Console: mono headings, `panel` groups with hairline edges and 2 pt corners. Black glass: as before. | Yes |
| Remote band | Up to three remote worker tiles, then at most two rows for reviews and fan-outs that still need you. The link at its trailing edge goes to Hand-offs. | Yes |
| Remote zoom | The tray's watch view, read-only, under a wall crumb with a Read-only badge. "Open hand-off" goes to that hand-off in Hand-offs. | Yes |
| Control dock | Under the tile of a worker a friend holds: the tray's holder row with its countdown and Take back. Under a zoomed worker it sits below the console. | Yes |
| Suggestion row | In the same dock: who suggests what, and Review, which opens it in Approvals. | Yes |
| Apply | In the Hand-offs inspector: Apply… or Save… asks for the checkout, a confirmation names it, and each artifact keeps its own result. | Yes |

A local worker is matched to the network by the resource ID it is shared under (`MultiplayerShareTarget.agent(id:).resourceID`). The console tiles, their shells and their controls were not changed; the theme test that scans those files is green.

### The running-window check of increment 3

The report is in [`../main-window-3/verify/`](../main-window-3/verify/REPORT.md).

| # | Defect | What changed |
|---|---|---|
| 3 | Five pages wider than the window at 1280 pt | The split asks the collection for the least width it can take and puts the inspector under it when both don't fit. A page narrower than its bands' least width scrolls them sideways, so the rail never leaves the window. The audit table's two middle columns are 12 pt narrower. A test measures every page at 1280 × 800. |
| 1, 2 | ⌥⌘1 did nothing, ⌥⌘4 opened Runs | See below. |
| 4 | Presence had no element of its own | The servers button and the presence menu are two toolbar items. A toolbar exposes each item as one element, and both were in one item. **Needs a check in a window.** |
| 5 | Access and friend request rows were static text | They are buttons with the selected state and open a request inspector. |
| 6 | Labels left out what the screen shows | Row labels say the time left, the wait or when it was sent. The alert band's sentence and its Dismiss are separate elements. A changed certificate is said once. |
| 7 | Short breadcrumbs cut off | A crumb of 28 characters or fewer keeps its full width. **Needs a check in a window.** |
| 8 | No confirmation after Decline on People | The alert band says "Declined. … can ask again." |
| 9 | The alert band followed to other pages | It clears when its page is left. |
| 10 | "1 friend requests" | "1 friend request". |
| 11 | Choosing a row discarded a form open in the panel | Gone: the window no longer reads or moves the tray's route. |

**The empty text element in the certificate inspector was not found.** The window's inspector header no longer draws an empty server line. If the element remains, it is inside the tray's certificate review, which this increment can't edit.

#### Why ⌥⌘1 and ⌥⌘4 failed

The hidden shortcut buttons captured the navigation as it stood when the window opened, and kept acting on it.

- **⌥⌘1** asked that old navigation to select Agents. It was already in Agents, so it did nothing, from any mode.
- **⌥⌘4** asked it for Teams. With no workspace loaded yet, Teams' first place was the "Workspaces" row. By the time the key was pressed the workspaces had loaded and that row no longer existed, so the window fell back to Runs.
- **⌥⌘2, ⌥⌘3 and ⌥⌘5** worked because their first places never change.

This explains both symptoms exactly, but it was reasoned from the code, not seen in a window. The fix does not depend on it being the only cause:

- A shortcut button now only records a command. The page runs it from its current state.
- A Teams place that no longer exists stays in Teams.
- Every cockpit shortcut is in one table (`CockpitShortcuts`). A test fails if two share a chord, or if another file of the cockpit window binds one of them. It found ⇧⌘A and ⌘N bound twice in `CockpitView.swift` (the older navigation rail's rows); both now come from the table.

No ⌘4 or ⌥⌘4 binding exists anywhere else in the app. The tray binds ⌘1 to ⌘3 in its own window.

### The network model's new calls (PRs #6 and #8)

| Change | Where |
|---|---|
| The window owns its route, reads and drafts. It never reads or moves the tray's route. | `NetworkPagesLiveState`, `LiveNetworkIntents` in `NetworkPagesLive.swift` |
| Consult, Hand off, Request review, Watch, Add friend, Invite, Membership and Add server are hosted on the page, in a composer panel under the telemetry strip. | `NetworkComposer`, `NetworkPageScaffold` |
| The grant sheet takes its full height (`scrolls: false`). | `NetworkGrantInspector` |
| Shared offers Revoke… on a grant, with an inline confirm. | `NetworkSharedInspector` |
| An answered approval or access request keeps its row with its outcome, and is not counted. | `answer(for:on:)`, `waitingApprovals`, `waitingAccess` |
| Threads lists what the network says you take part in: sent and received, consults included. | `loadThreads(on:)` |

## Renders

Whole windows at one pixel per point, console theme unless named.

```sh
WALL_RENDER_DIR=design/demos/main-window-4 NETWORK_FIT_RENDER_DIR=design/demos/main-window-4 \
NETWORK_LIVE_RENDER_DIR=design/demos/main-window-4 swift test --filter "WallRender|NetworkFit|NetworkPagesLive"
```

| Picture | File | Size |
|---|---|---|
| Wall with local and remote workers, a held worker and two rows | `wall-live-work-console.png`, `wall-live-work-black-glass.png` | 1440 × 900 |
| Held worker and a suggestion, no remote work | `wall-held-by-friend-console.png` | 1440 × 900 |
| Remote worker zoomed | `wall-remote-zoom-console.png`, `wall-remote-zoom-black-glass.png` | 1440 × 900 |
| Apply confirmation | `handoffs-apply-confirm-console.png`, `handoffs-apply-confirm-black-glass.png` | 1440 × 900 |
| Apply result | `handoffs-apply-result-console.png` | 1440 × 900 |
| Every network page at the default window size | `fit-1280-*-console.png` (11 files) | 1280 × 800 |
| Consult and Add server hosted on the page, Revoke's confirm, the grant sheet | `live-directory-consult-console.png`, `live-servers-add-server-console.png`, `live-shared-revoke-console.png`, `live-shared-grant-console.png` | 1280 × 800, the page alone, from the network fixture |

The clickable preview is `--design-preview shell-b`, on Runs: the wall shows the sample band and dock, and Take back removes the hold. `network-handoffs` shows Apply.

## Gaps

- **At 1280 pt the inspector is under the table** on Servers, Directory, Approvals and Shared, because their tables can't shrink enough to leave it 400 pt. It is beside the table from about 1310 pt (Directory) to 1375 pt (Servers), and at 1440 pt on all four.
- **The band takes wall height.** With two rows of local tiles, a remote band and the 900 pt window, the lower local tiles scroll.
- **In black glass the tray's parts stay console-styled:** the holder row in the dock, the zoom view, the hosted composers and the inspectors' contents.
- **The remote zoom has two ways out:** the window's "Open hand-off" and the tray organism's own "Open in tray" footer.
- **The zoom is read-only.** Suggesting to a friend's worker is on the hosted Watch composer in Directory.
- **Apply's result is read from the model's banner** after its call ends, because `apply` returns no result of its own. A file saved under a new name is not named.
- **The Apply confirmation doesn't scroll into view.** It is first in the inspector, so it is in view unless the inspector is under a long table.
- **Removing a server still moves the tray** to its home page.
- **Composers open above the page's bands,** not in the inspector beside the row they came from.
- **The wall's controls are not themed yet:** the run header, "Group by parent", the presentation menu and the key hints.
- **The preview's remote tiles don't zoom.** They go to Hand-offs. The zoom is in the live cockpit and in the renders.
- **`previewStateDecidesShowsTheOutcomeThenClears` failed once in six full runs** on a 400 ms wait. It predates this increment.
- **Increment 3's renders in `../main-window-3/` were not redrawn.** At 1440 pt they are unchanged.
