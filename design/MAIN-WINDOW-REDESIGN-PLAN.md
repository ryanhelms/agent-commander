# Main window redesign: plan

The main Agent Commander window takes on the Commander network tray's design and features, and becomes a full workspace instead of a run launcher. This plan comes from a grounding report and a planning interview with the owner on 25 November 2026. It names no app code yet.

## Decisions

| Topic | Decision |
|---|---|
| Features | All four groups: live work on the wall, full-size network pages, Teams (increment 5), and wiring of the preview pages that already exist |
| Visual direction | Themeable: black glass and the tray's console skin are both app-wide themes. Build the theme layer first, then reskin. |
| Sidebar | Prototype all three concepts as clickable demos, use them, then pick one: A grouped list, B mode rail with a context list, C "Needs you" inbox first |
| Tray role | Triage and quick actions: approvals, access and friend requests, presence, server trust, Consult, Share and Take back. Dense views open in the main window. |
| Order | Theme layer → sidebar prototypes, Needs you and preview-page wiring → network pages → live work on the wall → Teams |
| Coordination | Work in new files. Each view is first a clickable demo with sample data. Once it is right, convert it to a working screen. |

## Visual source of truth

[`DESIGN.md`](../DESIGN.md) at the repository root governs the look. It was committed on `main` (`ef967a1`) and merged here. Build every main-window view from its tokens, components, layout patterns and behaviour, as `.claude/rules/design.md` requires.

- **Console theme.** `DESIGN.md` defines the console theme. Black glass is the alternate theme and keeps today's main-window look. `DESIGN.md` §6 already asks for this: "a skin redefines one token layer".
- **Exempt.** The console, terminal and pretty view keep their current rendering, as `DESIGN.md` itself says.
- **Not covered.** `DESIGN.md` doesn't cover everything the main window needs. Those parts are proposed as additions to it in [Proposed additions to DESIGN.md](#proposed-additions-to-designmd) below, not invented in code.

## Fixed constraints

- **Never redesign the console, terminal, pretty view, their controls or their shell.** That covers `NativeTerminal*`, `Console*`, `FocusedPrettyConsole`, the harness console tile and header, and their controls. A theme switch leaves them as they are. Everything else may change.
- **`migration/port-branch-leftovers` is merged.** Its 42 commits came in through `main`, so this branch already has its changes to `CockpitView`, `Molecules`, `Organisms`, `Components`, `CockpitModel` and `ServiceClient`, and its new `Elicitation`, `FollowUpContext` and `ProviderSession` files.
- **Don't edit the tray session's files until it hands them over:**
  - every `Sources/AgentCommander/Multiplayer*.swift`
  - `Tests/Fixtures/commander-network-fixture.py`
  - `Tests/AgentCommanderTests/Multiplayer*Tests.swift`
  
  `CockpitView.swift`, `Organisms.swift` and `Molecules.swift` are off limits while its increment 5 is open, because that increment adds the hand-off wall cards (D8).
- **Roles follow `AGENTS.md`.** Fable 5.2 builds the frontend, with Opus as a fallback, and loads `frontend-design` first. Codex or Claude builds the backend. Codex verifies the running app through Computer Use against the approved capture for each state.
- **Each increment ends with a build and a demo.** The demo subagent starts at once, and the next increment starts in parallel with it.
- **Builds and visual checks** use a linked worktree under `~/.worktrees/agent-commander/`, headless fixtures and snapshot renders. Never use the owner's running app.

## Where things stand

- **Main window.** The live navigation has Runs, Attention, a project list and New run. The live pages are the empty state, New run and the coordinator wall.
- **Pages built but not connected.** About 20 pages run only in `DesignPreview` with sample data:
  - All agents, Attention queue, Project, Smart view, Link checkout
  - Delegate worker, Integration, History, Cross-run
  - First run, Hosts, Clients, Adoption, Recovery, Operation detail, Preferences
- **Tray.** It has Agents, Network and People tabs and about 40 organisms that take values. Its model, `MultiplayerModel.shared`, is an `@Observable` singleton. Its polling counts viewers, so the main window can watch the same instance.
- **Backend.**
  - Increments 1–2 are done.
  - Increment 3 passed 17 of 30 demo steps, and none of its 14 defects is fixed in code yet.
  - Increment 4's backend has no tests.
  - Increment 5 has relay routes, but the tray reaches them through a generic `relay` verb, and group grants are missing.
  - Increment 6's backend is done.

## Architecture

### Theme layer

- Add a `themes` section to `design/system/tokens.json` with two themes:
  - `blackGlass`: today's values.
  - `console`: exactly the tokens in [`DESIGN.md`](../DESIGN.md) §2, plus the additions proposed below once the owner approves them.
- A `Theme` value in new `Theme*.swift` files supplies the roles that components read: colour, type, radius, material, density and motion. It reaches views through the SwiftUI environment. `DesignTokens.swift` keeps its current names as the black-glass values, so existing views compile unchanged.
- The console, terminal and pretty view don't read `Theme`. A test enforces that boundary.
- Preferences gains a Theme choice. Use Increase Contrast and Reduce Transparency as they work today.
- Later, `MultiplayerTheme` becomes a view of the console theme. That change touches tray files, so it waits for the tray session's agreement.

### Navigation

- The three sidebar concepts are three navigation templates over one `NavigationModel` (`CommanderNavigation`): groups, items, badges, footer and selection. Pages don't depend on the template.
- **Needs you** is one inbox fed by:
  - local worker questions and approvals (`content.pending`)
  - network approvals, access requests and friend requests (`MultiplayerModel.shared`)
  
  Each row says where it came from and can be decided inline.
- The toolbar carries presence and server health, using the tray's `PresenceMenu` and `StatusStrip`-style readouts.

### Reuse by Atomic Design level

| Level | Reused from the tray as is | New for the main window |
|---|---|---|
| Atoms | Lamp, Mark, Meter, Spinner, Avatar, Swatch, Badge, Signed, Grant, Holder and Read-only badges, FingerprintText, button styles, motion modifiers (full list in `DESIGN.md` §3) | Theme-aware wrappers where an atom hard-codes `MultiplayerTheme` |
| Molecules | HashChip, AgentChip, StateLabel, Segments, TraceRow, VerbStrip, Countdown, HolderRow, FindingRow, DecisionRow, ActivityRow, NeedRow, alert band, load note, outcome well | Inbox row that combines a local request with network origin |
| Organisms | Approval, Watch, Thread, Audit, HandoffDetail, Compare, Directory, GrantSheet, ProfileEditor, Membership, CertificateReview, ServerSettings | Three sidebars, Needs you list, people grid, server table, board columns, workspace combined view |
| Templates | Use the main window's `WorkspacePage`, `CollectionInspector` and `TaskSheet`. Don't use `MultiplayerPanelShell`, which is fixed at 400 pt. | Navigation templates A, B and C |
| Pages | — | Needs you, People, Servers, Shared, Hand-offs, Threads, Audit, Fan-out, Workspaces, Board, Knowledge, Admin |

Tray organisms are used as they are, from new main-window files. Any change to a tray organism goes to the tray session as a request.

## Increments

Every increment works the same way:
1. Build each view as a clickable `DesignPreview` scenario with sample data.
2. Compare it with the matching concept or tray capture.
3. Demo it.
4. Convert it to a live screen in a later step of the same increment.

| # | Scope | Clickable demo | Live conversion | Depends on |
|---|---|---|---|---|
| 0 | **Done.** `migration/port-branch-leftovers` merged into `main` at `ef967a1`, and `main` merged into this branch. All 494 Swift tests pass, and so do the Go `mcpbridge` and `agentctl` tests. File boundaries with the tray session are recorded in [Coordinating with the tray session](#coordinating-with-the-tray-session). | — | — | — |
| 1 | Theme layer: tokens, `Theme`, the two themes, the Preferences toggle, the console exclusion test | Preferences page and three existing preview pages in both themes | Theme toggle in the live app | 0 |
| 2 | Shell: the three sidebar prototypes, toolbar presence and health, the Needs you inbox | All three sidebars switchable in the preview. The owner tries them and picks one. | Chosen sidebar, Needs you and toolbar in the live window. Wire All agents, Attention queue, History, Hosts and Preferences. | 1. Editing `CockpitView` waits until the tray's increment 5 merges. |
| 3 | Network pages: People, Servers (with certificate review), Shared and Directory, Hand-offs, Threads, Audit, Fan-out compare | Each page with fixture data | Bound to `MultiplayerModel.shared`. Tray rows deep-link into these pages. | 2. Wiring approvals and apply waits for the increment 3 fixes to D1, D4, D5 and D7. |
| 4 | Live work on the wall: remote workers from hand-offs, Watch in zoom, co-pilot and control state on the tile | Wall with remote tiles. The tile shell stays unchanged and only its content source is new. | Live data | 3. Agree D8 ownership with the tray session first (see open questions). Increment 4 backend mismatches fixed. |
| 5 | Teams: workspaces with the combined view, board, merge queue, groups, knowledge library, admin policy and moderation | Each page with fixture data | Live, after dedicated tray verbs and group grants exist | 3, plus the increment 5 backend gaps |
| 6 | Make the tray a triage tray: remove the dense pages it no longer needs and link to the main window | — | Tray change, made by or with the tray session | 3–5 and the tray session's OK |

## Coordinating with the tray session

- **New files only.** Main-window code goes in new files, such as `Theme*.swift`, `Shell*.swift`, `Network*Pages.swift`, `Teams*.swift` and `NeedsYou*.swift`. Tray types are imported read-only.
- **Before touching a shared file,** such as `CockpitView`, `Organisms`, `Molecules`, `AgentCommander.swift` or `DesignPreview.swift`, message the tray session and wait until its open increment has merged.
- **Changes to a tray organism** go to the tray session as a request.
- **Notes.** Hand-over notes go in the shared notes folder, not in messages.

## Proposed additions to DESIGN.md

The main window needs these, and `DESIGN.md` doesn't define them yet. `.claude/rules/design.md` requires each addition to go into `DESIGN.md` in the same change as the clickable demo that introduces it. If the owner rejects a demo, its `DESIGN.md` entry is revised or removed in that same review.

| Addition | Why the main window needs it | Proposed starting point |
|---|---|---|
| Sidebar of places | Concepts A, B and C. `DESIGN.md` §4 says only "a tab bar or a sidebar of places". | Rows are 28 pt high with hairline group rules and mono group headings in `heading`. The selected place gets a 2 pt `focus` leading edge, the same marker the tab bar uses. Counts use the tab bar's hot-count fill. Mode rail icons are 18 pt in square 32 pt cells. |
| Page scale | The type roles top out at `title` 14 pt, which suits a 400 pt tray but not a full window | Add `pageTitle`: system 20 semibold. Add a page header made of a title, a one-line state summary and a telemetry strip, following `DESIGN.md` §4. Bands keep their sizes. |
| Wide layouts | Full-width pages, tables and an inspector | Use the existing `WorkspacePage` and `CollectionInspector` templates with hairline grids. Add a data table molecule: mono header cells in `label`, hairline rows, and right-aligned figures. |
| Wall frame around the exempt console | Tiles sit inside a wall that gets themed | Only the gaps, wall headers and group rules take the theme. The console tile shell and its controls stay as they are. Remote workers from hand-offs use the same tile shell with a kind glyph and a Read-only badge in its existing header slot. |
| Needs you inbox row | It combines local and network requests | A decision row with an origin cell: a local worker's mark, or a server swatch and the friend's avatar. Approve and Deny work as `DESIGN.md` specifies. After a decision, an outcome well replaces the verb strip. An empty inbox shows a load note reading "Nothing is waiting for you". |
| Board columns | Teams task board | Columns are hairline-divided, with the band heading pattern for each state. Cards are square, have no shadow, and carry a holder badge when claimed. |
| Window material per theme | Black glass uses system glass. `DESIGN.md` forbids glass. | Material is a theme token for native surfaces: glass in black glass, opaque `window` in console. Reduce Transparency forces the opaque fill in both. The web Remote page is unaffected and keeps its own `prefers-color-scheme` light and dark roles. |
| Toolbar | Presence and server health in the window toolbar | A readout pair (`servers 2/3`, presence menu) in the status-strip style, placed in native toolbar items |

## Open questions and risks

- **Security defects block live wiring.** Increment 3 defects D1 (a grant with no `approval` runs automatically) and D7 (`apply-artifact` can overwrite files) must be fixed before the main window wires approvals or Apply.
- **D8 has two possible owners.** The increment 3 contract gives it to the tray session's increment 5 frontend agent. This plan's increment 4 also covers it. Settle the owner before either side builds it.
- **Increment 5 backend gaps.** It has no dedicated `groups`, `workspaces`, `claim` or `release` verbs, no group grants and no merge-queue tests. Teams pages can be demos before then, but not live.
- **Increment 4 backend.** It has no tests, and watch reads `/history` while the contract says `/output`. Live work stays a demo until the tray session's four queued fixes land.
- **Dark on native.** Per `DESIGN.md` (from `94ea134` on the tray branch), native surfaces are dark only, and only the web Remote page has a light theme. Both native themes stay dark. A native light appearance is out of scope unless the owner adds it. If added, it would start from the web page's light roles, not a new palette.

## Verified and reported

- **Checked in code at `341215d`:**
  - the tray tokens, radii and motion values
  - the model ownership
  - D1 and D5 still present
  - the main window's live navigation
  - the preview-only pages
  - the 42 commits ahead on `migration/port-branch-leftovers` and the files they touch
- **Reported by the tray session and not checked:**
  - the design intent from the owner's interview
  - Codex fixing the increment 3 Go defects now
  - the four queued increment 4 mismatches
  - its file-avoidance list
  - its view of what should be shared and who should own what
