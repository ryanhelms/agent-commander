# Main window increment 2: sidebar B, the toolbar readouts and the Needs you inbox

The owner chose sidebar B, the mode rail with a context list, and Console as the default theme. The live main window now uses both. The three prototypes stay as design previews with sample data.

## The live window

| Part | State |
|---|---|
| Mode rail and context list | Live. Built from the cockpit's runs and the network model on every refresh. |
| Agents: Needs you | Live. See [Needs you, live](#needs-you-live). |
| Agents: Runs, project rows, New run | Live, as before: the coordinator wall, the run chooser, each project's newest run and the new-run form. A project row's context menu has Share…. |
| Network: Servers, Directory, Approvals, Hand-offs, Threads, Audit, Fan-out, Shared | Placeholder: the page header, one note and "Open network panel". The row counts are live (servers answering, approvals waiting, hand-offs sent). |
| People: People | Placeholder, with the live count of friends online. |
| Teams | One row per workspace you work in, with its claim count. Each opens a placeholder. With no workspace there is one "Workspaces" row. |
| Settings (gear) | Live Preferences page: the theme choice and the attention presentation both take effect at once and are kept. "Launch settings…" opens the app's Settings window (⌘,). Recording and retention are left out because nothing sets them yet. |
| Toolbar | Live: breadcrumb, the console display menu, adapter updates, the service state, then `servers` (opens Servers) and the `presence` menu, which sets your presence on every signed-in server. |
| Wall, zoom, PiP, Remote workers band, consoles | Unchanged. |

"Open network panel" shows the tray's panel in its own window (`MultiplayerLinkWindow`), which the Share… action already uses.

The window counts as a viewer of the network model while it is open, so the model polls as it does for an open tray.

### Keys

| Keys | What they do |
|---|---|
| ⌘1 | Focus the coordinator (unchanged) |
| ⌘] and ⌘[ | Zoom the focused worker, return to the wall (unchanged) |
| ⇧⌘A | Next request. From another page it first returns to the wall. |
| ⌘N | New run |
| ⌥⌘1 to ⌥⌘4 | Agents, Network, People, Teams |
| ⌥⌘5 | Settings |
| ⌘K, ⌘, | Search workspace and the app's Settings window (unchanged) |

Context-list rows have no number keys, so nothing collides with ⌘1. Changing mode goes to the mode's first place. The sidebar button in the toolbar puts the context list away and leaves the rail. The prototypes keep ⌘1 to ⌘5 for modes.

### Needs you, live

The inbox merges `content.pending` with the network model's approvals, access requests and friend requests, in the order below.

| Row | Answers | What an answer does |
|---|---|---|
| Your worker's question or approval | Reply | Returns to the wall and opens the request exactly as Next request does: the side panel or the PiP, with the reply focused. The row's text does the same. |
| Network approval | Deny, Approve | `share.decide(_:on:approve:)`, as the tray. Counts down each second. |
| Access request | Decline, Review | Decline calls `share.remove(_:on:declining:)`. **Review opens nothing yet**: it shows "In review" for a moment and the request stays. The grant sheet is still in the network panel. |
| Friend request | Accept | `accept(_:on:)`. There is no Decline because the network model has none. |

After an answer the outcome shows for 2.4 seconds, then the row leaves. If the model refuses or fails, the row comes back and the model's failure text shows above the list. The model takes one action at a time; an answer given while it is busy is not taken and the row stays as it was.

A worker's request has no arrival time in the cockpit's data, so its clock cell is empty and workers keep the cockpit's order, oldest first.

### Live renders

From the cockpit fixture's content (two pending requests) and a fixture network state (two servers, two approvals, an access request, a friend request, one workspace). No model is read.

| Picture | File |
|---|---|
| The wall in the shell | `live-wall-console.png` |
| Needs you | `live-needs-you-console.png`, `live-needs-you-black-glass.png` |
| Network, Servers (placeholder) | `live-network-servers-console.png` |
| Settings | `live-settings-console.png` |

### Changes asked of the tray session

- **Decline a friend request.** No model method or helper verb exists. The inbox offers Accept alone until one does.
- **A way to tell that an action was taken and how it ended.** `decide`, `remove` and `accept` report failure only through `failure`, shared by every action. A per-request result would let a row show "Couldn't approve" itself.
- **Review an access request from outside the tray.** `share.review` opens the grant sheet by changing the tray's route. The main window needs the grant sheet as a component it can host, or an agreed way to show the panel on that page.
- **Arrival time on friend requests** (`MultiplayerIncoming` has none), so the row can say how long it has waited.

### Gaps in the live window

- **Not seen in a real window.** Checked by build, 573 unit tests and headless renders. Toolbar items, the presence menu, the run chooser popover, shortcuts and motion were not exercised. The toolbar items are handed the theme explicitly because toolbar content may not inherit it.
- **The wall keeps its black-glass look inside the console shell**: rounded groups and tiles, capsule buttons, the run header. `DESIGN.md` section 6 lists this as open work.
- **New run is not dimmed while the service is offline.** ⌘N is off, and the form itself says the service is offline.
- **All agents, Attention queue, History and Hosts are not wired.** They stay design previews; the plan lists them for increment 2 but this step's brief covered the shell, the toolbar and the inbox.
- **Existing users switch to Console** unless they had chosen a theme. Black glass is in Settings.
- **The cockpit design previews keep the earlier navigation rail.** Only the live page supplies the shell.

## The prototypes

Three sidebar prototypes share one navigation model. Everything below is a design preview with sample data.

## Open a scenario

```sh
open "dist/Agent Commander.app" --args --design-preview shell-a
```

| Scenario | What opens |
|---|---|
| `shell-a` | A, grouped sidebar, on All agents |
| `shell-b` | B, mode rail with context list, on All agents |
| `shell-c` | C, Needs you first, on All agents |
| `needs-you` | The Needs you inbox, in sidebar C |

They are also in the preview gallery menu under "Main window redesign".

Inside the window:

- **Change sidebar:** the A, B, C control in the toolbar, or ⌥⌘1, ⌥⌘2, ⌥⌘3. The selected place stays. This control and the theme control exist only in the preview.
- **Change theme:** the Black glass / Console control beside it, or ⌥⌘T.
- **Change place:** click a row, or press ⌘1 to ⌘9. In B, ⌘1 to ⌘5 choose the mode.
- **Reset the sample data:** choose the scenario again in the gallery menu.

## What each sidebar does

| | A, grouped | B, mode rail | C, Needs you first |
|---|---|---|---|
| Inbox | First row of Workspace | First row of the Agents mode | Pinned at the top with the total and where requests come from |
| Attention, Approvals, Friend requests | Attention is a row | All three are rows | Left out: the inbox lists them |
| Network pages | People, Servers, Shared | Every page: Servers, Directory, Approvals, Hand-offs, Threads, Audit, Fan-out, Shared | People, Servers, Shared |
| Groups fold | No | No | Projects, Network and Teams fold; a folded group keeps its hot count |
| Presence | Toolbar readout | Toolbar readout | Sidebar footer, with the profile |
| Server health | Toolbar readout | Toolbar readout | Toolbar readout |

## What the places open

| Place | Page |
|---|---|
| Needs you | The new inbox |
| Runs, Relay | The coordinator wall, read-only |
| All agents, Beacon | All agents (Beacon filters to that project) |
| Attention | Attention queue |
| History | Search history |
| Hosts | Hosts and capabilities |
| Settings | Preferences |
| Every network and teams place | A placeholder: the page header and one note |

## Needs you

One list, most urgent first:

1. A request with under five minutes left, whatever its kind.
2. Your own stopped workers: approvals and questions, longest wait first.
3. Network approvals, soonest end first.
4. Access requests.
5. Friend requests.

Each row has an origin cell (a worker's square mark, or the server swatch and the friend's avatar), the request, its wait or time left, and its answers: Deny and Approve, Decline and Review, Decline and Accept, or Reply. Reply opens a field under the row. After a decision an outcome well takes the answers' place for 2.4 seconds, then the row leaves. With nothing left, the list says "Nothing is waiting for you".

Answering Q-018 or Q-021 here also answers it in the Attention queue, and the other way round.

## Renders

Each is a whole window at 1440 × 900, one pixel per point. Regenerate them with:

```sh
SHELL_RENDER_DIR=design/demos/main-window-2 swift test --filter ShellRender
```

The same command draws the live renders.

| Picture | Black glass | Console |
|---|---|---|
| A on All agents | `shell-a-black-glass.png` | `shell-a-console.png` |
| B on Network, Servers | `shell-b-black-glass.png` | `shell-b-console.png` |
| C on History | `shell-c-black-glass.png` | `shell-c-console.png` |
| Needs you, in C | `needs-you-black-glass.png` | `needs-you-console.png` |
| Needs you, empty (page only) | `needs-you-empty-black-glass.png` | `needs-you-empty-console.png` |

## Where the pieces are

| Piece | File |
|---|---|
| Navigation model and actions | `Sources/AgentCommander/ShellNavigation.swift` |
| Shell atoms and molecules, toolbar readouts | `Sources/AgentCommander/ShellMolecules.swift` |
| Sidebar A | `Sources/AgentCommander/ShellSidebarGrouped.swift` |
| Sidebar B | `Sources/AgentCommander/ShellModeRail.swift` |
| Sidebar C | `Sources/AgentCommander/ShellNeedsYouSidebar.swift` |
| Shell template | `Sources/AgentCommander/ShellTemplate.swift` |
| Inbox values and ordering | `Sources/AgentCommander/NeedsYouModel.swift` |
| Inbox components and page | `Sources/AgentCommander/NeedsYouPage.swift` |
| Preview scenarios and sample data | `Sources/AgentCommander/ShellPreview.swift` |
| Live values: network snapshot, navigation and inbox builders | `Sources/AgentCommander/ShellLive.swift` |
| Live composition and routing | `CockpitScreen` and `CockpitView` in `Sources/AgentCommander/CockpitView.swift` |
| Tests | `Tests/AgentCommanderTests/ShellNavigationTests.swift`, `ShellLiveTests.swift`, `ShellRenderTests.swift` |

## Known gaps in the prototypes

- **Not seen in a real window.** Everything was checked by build, unit tests and headless renders. The renders draw the toolbar as a band; in the window the same content sits in native toolbar items, which macOS may wrap in its own glass capsules. Clicks, menus, shortcuts and motion were not exercised.
- **Renders use the opaque surfaces.** A headless view can't draw system glass, so the black-glass pictures show the Reduce Transparency form of the sidebar.
- **A and B show the inbox as a row.** The sketches for A and B had no inbox row. It is the first Workspace row so the inbox can be reached from every sidebar.
- **C keeps History.** The sketch for C listed only Runs and All agents under Workspace.
- **A hidden place has no selected row.** Choose a page that only B lists, such as Audit, then switch to A or C: the page stays, and no row is marked.
- **Times stand still.** Waits and countdowns are sample figures and don't tick.
- **Review and the request text open nothing.** Review records "In review". A local request's text opens the Attention queue; a network request's text does nothing until the approval and access pages exist.
- **A-007 is only in the inbox.** The Attention queue page has no sample approval, so Attention counts 2 while the inbox lists 3 local requests.
- **The wall is read-only.** Runs shows the cockpit's own header, coordinator and tiles unchanged. Zoom, typing, the PiP and the Remote workers band are left out.
- **Black glass merges a few sizes.** Rows are 37 pt high (35 today) and counts are 24 pt high (18 today), because both come from existing theme roles.
- **Existing pages keep their own gaps** from increment 1: filter menus and All agents cards look the same in both themes.

## Proposed, not built

- A "needs you" readout in the toolbar for A and B, in place of the inbox row.
- Marking the nearest listed place when the selected page is hidden.
- A countdown that ticks, using the tray's Countdown molecule.

## Waiting for a decision

[`DESIGN-ADDITIONS.md`](DESIGN-ADDITIONS.md) holds the text to add to `DESIGN.md`. `DESIGN.md` was not edited.
