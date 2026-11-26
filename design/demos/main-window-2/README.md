# Main window increment 2: three sidebars and the Needs you inbox

Three sidebar prototypes share one navigation model. Try each, then pick one. Everything here is a design preview with sample data; nothing is wired to the live app yet.

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

- **Change sidebar:** the A, B, C control in the toolbar, or ⌥⌘1, ⌥⌘2, ⌥⌘3. The selected place stays.
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
| Tests | `Tests/AgentCommanderTests/ShellNavigationTests.swift`, `ShellRenderTests.swift` |

## Known gaps

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
