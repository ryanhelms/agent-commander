# Agent Commander design

This is the visual language for every Agent Commander surface: the main window, zoom, PiP and the Commander network tray. It is drawn from the network tray's redesign on `claude/commander-network-f774d6`. Implement new and restyled views from this document.

The tray proves the language. The main window adopts it. Console mode keeps its current rendering, and so does the provider's output in Terminal mode; the language applies to everything around them. The Pretty transcript has its own approved rules, in [Pretty transcript](#pretty-transcript).

A third theme, `quiet`, is approved but not built: see [Quiet theme](#quiet-theme-two-speeds-approved-target-not-yet-built). It departs from several rules here on purpose. Until it is built, and afterwards for the Console and Black glass themes, the rules in this document apply as written.

Sources of truth in code:

| What | Where |
|---|---|
| Base colour tokens | `design/system/tokens.json`, `Palette` in `DesignTokens.swift` |
| Tray role tokens | `MultiplayerTheme` in `MultiplayerTrayComponents.swift`: each token names a role of `Theme` and resolves it where it is drawn |
| Skin atoms, molecules, motion | `MultiplayerSkin.swift` |
| Tray layout constants | `MultiplayerLayout` in `MultiplayerComponents.swift` |
| Open-in-window row and its opener | `MultiplayerOpenInWindow.swift` |
| Reference mockup | `design/mockups/commander-network-tray.html` |
| Teams components (increment 5) | `MultiplayerTeamsViews.swift`, `MultiplayerMarkdown.swift` |
| Cockpit wall and zoom for remote workers | `MultiplayerWall.swift` |
| Themes | `themes` in `design/system/tokens.json`, `Theme` in `ThemeTokens.swift` |
| The wall's frame and its live work | `WallFrame.swift`, `WallLiveWork.swift` |
| Teams pages (main window) | `TeamsPageMolecules.swift`, `TeamsPagesWorkspace.swift`, `TeamsPagesTools.swift`, `TeamsPagesModel.swift`, `TeamsPagesLive.swift` |
| Harnesses mode (main window) | `Harnesses.swift`, `HarnessesPage.swift`, `HarnessTerminal.swift`; the API is in `design/HARNESSES.md` |

The app has two themes today. **Console** is the default and the language in this document. **Black glass** is the earlier main-window look, kept as an alternative with the same roles. Console is the default. Black glass is chosen in Settings and kept under `appearance.theme`. A component reads a role from `@Environment(\.theme)` and never branches on which theme is active. The console, terminal and pretty view read no theme. Pretty keeps its own `Palette` and `Term` roles and follows the Pretty transcript rules in section 3, in both themes. A third theme, `quiet`, is approved and not yet built; Console stays the default until the user decides otherwise ([Quiet theme](#quiet-theme-two-speeds-approved-target-not-yet-built)).

The tray's components follow the same rule (see "Tray roles" below). Whatever the main window composes from them (a hosted composer, the dock's holder row, the remote worker zoom and group, an inspector's organism) takes the window's theme. The menu bar tray itself sets the console theme at its root (`MultiplayerPanel(model:theme:)`), so it looks the same whichever theme the window uses.
| Remote band (increment 6) | `MultiplayerRemote.swift` |
| Tailnet band (Add server) | `MultiplayerTailnet.swift` |
| Relays nearby and the join checklist | `MultiplayerDiscovery.swift`, `MultiplayerDiscoveryViews.swift` |
| Request access and membership requests | `MultiplayerMembershipRequests.swift`; the admin's list is in `TeamsPagesTools.swift` |
| List publicly (Hosting) | `MultiplayerHosting.swift` |
| Reference renders | `design/demos/increment-2/`, `design/demos/increment-3/`, `design/demos/increment-4/` (after its demo) |

## 1. Direction

An operations console for an agent network. These seven rules describe the Console theme and bind everything built today. The approved `quiet` theme relaxes rules 1 and 2 on the surfaces it names, and keeps rules 3 to 7 ([Quiet theme](#quiet-theme-two-speeds-approved-target-not-yet-built)).

1. **Hard lines.** Hairline grids and rules divide space. No corner is rounder than 2 pt. No soft cards, no large radii, no drop shadows, no glass.
2. **Data is monospaced.** Prose uses the system face. Anything that is data, a state, a count, a label or an action is monospaced.
3. **Every state is a lamp plus a word.** A lamp has its own shape and colour per state, and a word always sits beside it. Colour is never the only signal.
4. **Identity is shown as it is verified.** Keys, pins and fingerprints appear up front as hash chips, with trust and a copy action. Signed results carry a signed badge.
5. **Agents are first-class actors.** Agents show harness and model chips, slot counts, token meters and live traces. Agents and resources are square. People are round.
6. **Custom skin, native behavior.** Every custom control is a `Button`, `Menu`, `Toggle` or text field underneath. Keyboard focus, the focus ring, VoiceOver, shortcuts and window mechanics stay native.
7. **Motion over static.** Changes move. Motion is crisp (100–250 ms), eased out, never bounces, and respects Reduce Motion.

## 2. Tokens

### Colour

Dark by default. The web surface (the Remote page) also has a light theme through `prefers-color-scheme`, using the same roles. Use roles, never raw hex, in components.

| Role | Hex | Use |
|---|---|---|
| `window` | `#090A0D` | Window background |
| `panel` | `#14151A` | Raised region, selected tab |
| `well` | `#0B0C10` | Sunken region: fields, status strip, unselected tabs, marks |
| `hair` | `#26282F` | Hairline rules and grid lines between cells |
| `border` | `#383B44` | Control and chip outlines |
| `foreground` | `#F5F5F9` | Primary ink |
| `secondary` (`.inkSecondary`) | `#B7BAC6` | Labels, metadata, section headings |
| `focus` | `#B5D6FF` | Primary action fill, focus edge, selection marker, tool lines |
| `working` | `#A8E0C0` | Online, success, pinned or verified, live |
| `attention` | `#F1C587` | Waiting, busy, hot counts, status lines |
| `failure` | `#EC9B92` | Error, changed key, destructive action |
| `selection` | `#283344` | Selected or emphasised chip cell |
| `onAccent` | `#101825` | Ink on a `focus` or `attention` fill |

Tinted states use the tone colour at 12% opacity for a fill and 45% opacity for an edge.

Components name a surface, not a base colour: a panel is `panel` with a `hair` edge and no shadow; a mark or a field is `well` with a `border` edge; a standard button is clear with a `border` edge; a primary button is filled `focus`; a selected row or card is `selection` with a 2 pt `focus` leading marker; a table header and a footer are `well`; a search match is filled `attention` with `onAccent` ink.

Light theme roles (web surface only): `window` `#F5F6F8`, `panel` `#FFFFFF`, `well` `#ECEDF1`, `hair` `#D8DAE1`, `border` `#B3B7C2`, `foreground` `#101116`, `secondary` `#4B4E5A`, `focus` `#1D5BB8`, `working` `#1A7548`, `attention` `#8A5800`, `failure` `#B2362A`, `selection` `#DBE6F7`, `onAccent` `#FFFFFF`. Light swatches are `#16A34A`, `#0284C7`, `#DB2777` and `#65A30D`.

**Swatches** identify a server or harness. They are mint `#4ADE80`, sky `#38BDF8`, pink `#F472B6` and lime `#A3E635`. A server's swatch is chosen by a stable FNV hash of its ID. Show it as a 4 × 12 pt bar beside the name, or as a 2 pt left edge on a row's metadata line.

### Material

| Token | Console | Black glass |
|---|---|---|
| Window | Opaque `window` | System glass |
| Canvas | `window` | Dark gradient over the glass |

Reduce Transparency forces the opaque fill in both themes. The web Remote page is unaffected.

Black glass draws the same components through its own tokens: the sidebar floats as a glass sheet, groups are separated by space rather than rules, the selected row has a rounded fill and outline with no marker, and a hot count uses the highlight fill.

### Tray roles

A tray component names a role through `MultiplayerTheme`, or reads `@Environment(\.theme)` for a shape or a size. Neither holds a value: each resolves the role in the theme of the view it is drawn in. In console every role below has the value the tray always drew.

| Tray part | Theme role |
|---|---|
| Inks: `foreground`, `secondary`, `focus`, `working`, `attention`, `failure`, `onAccent`, `selection` | The same role in `color` |
| Rules between rows and bands (`hair`), plain outlines (`border`) | `color.hair`, `color.border` |
| The tray, a hosted composer, the zoom: fill and edge | `surface.panelFill`, `surface.panelEdge` |
| Field, text area, sunken block | `surface.fieldFill`, `surface.fieldEdge`, `radius.control`, `space.fieldHeight`, `line.focusedField` |
| Mark, avatar | `surface.markFill`, `surface.markEdge`, `radius.chip` |
| Button, segments, verb strip | `style.buttonShape`, `surface.controlFill`, `controlEdge`, `controlInk`; primary `surface.primaryFill`, `primaryEdge` with `onAccent` ink; `space.controlHeight` and `controlHeightLarge`; type from `pageType.control`, one point smaller unless large |
| Badge, hash chip, agent chip | `surface.tagEdge`, `radius.chip`, `space.chipHeightMin` and `chipHeightMax` |
| Lamp | `style.statusMark`: the lamp shapes, or one dot in the state's colour |
| Switch | `style.switchShape`: the square track, or the system switch in `surface.switchTint` |
| Tab bar | Chosen tab `surface.panelFill`, others `surface.unselectedFill`; marker `line.selectedMarker` (none where the theme has none); `space.tabHeight`; hot count `surface.highlightFill` and `highlightInk` |
| Status strip, footer | `surface.footerFill` |
| Band | `space.sectionInset`, `bandTop`, `bandBottom`, `line.hairline` |
| Type: `title`, `name`, `body`, `sub`, `heading`, `state`, `data`, `mono`, `label`, `fingerprint`, `figure` | The same role in `type`, with its tracking and case |
| Remote worker group (wall) | `wall.groupFill`, `groupEdge`, `groupRadius`, `groupTitleType`, `groupNoteType` |
| Motion in a view: arriving, streaming, ticking, hover, pulse, meter | `motion` |

Increase Contrast swaps the rule and outline roles for `strongBorder`, as it does in the main window.

Not mapped, because no theme role has their console value: the banner's and the capability note's fills (base palette), the server and harness swatches, and the QR code's ink. `MultiplayerTheme.Motion` keeps the console pace for code that animates outside a view.

### Wall

The coordinator wall's own frame reads the `wall` roles. The console tiles inside it read none of them.

| Token | Console | Black glass |
|---|---|---|
| Pane heading | `heading`, in `secondary` | System 14 semibold, in `foreground` |
| Pane count | `heading` in `foreground`, no fill | Mono 10 on a 4 pt-radius badge |
| Group title | `heading` | System 12 semibold |
| Group note | `sub` | System 10.5 |
| Group fill and edge | `panel` with a `hair` edge | Glass fill `#101117` at 73% with a 22% white edge |
| Group radius | 2 pt | 15 pt |

Increase Contrast swaps the group edge for the strong border, like every other outline.

### Shape

| Token | Value |
|---|---|
| Tile radius | 2 pt |
| Control radius | 2 pt |
| Chip radius | 1 pt |
| Hairline | 1 pt |
| Selected-tab marker | 2 pt, in `focus` |
| Focused field edge | 1.5 pt, in `focus` |

### Type

| Role | Face | Size / weight | Use |
|---|---|---|---|
| `title` | System | 14 semibold | Panel or page title |
| `name` | System | 13 medium | A person's, agent's or item's name |
| `body` | System | 13 | Prose |
| `sub` | System | 11 | Secondary prose under a name |
| `heading` | Mono | 11.5 semibold | Section headings, tab titles |
| `state` | Mono | 10.5 semibold | State words beside lamps |
| `data` | Mono | 11 medium | Values, segment titles |
| `mono` | Mono | 11 | Tool output, paths, IDs |
| `label` | Mono | 9.5 semibold | Readout labels, chips, badges, counts |
| `fingerprint` | Mono | 10.5 | Hashes, times |
| `figure` | Mono | 14 semibold | Big numbers in a readout |
| `pageTitle` | System | 20 semibold | The title of a full-size page |
| `control` | Mono | 12 medium | Button labels |

On a full-size page, a title inside a panel and a section title both use `title`, the note beside a heading uses `sub`, and the line above a page title uses `label`.

Black glass only, provisional: `figure` is system 22 semibold.

Section headings read like `Needs you 3`. The name is in secondary ink and the count is in full ink.

### Spacing and size

| Token | Value |
|---|---|
| Section inset | 14 pt |
| Band padding | 10 pt top, 12 pt bottom |
| Gap between sections | 18 pt |
| Control height | 24 pt (large 28) |
| Field height | 30 pt |
| Row icon (mark or avatar) | 28 pt |
| Tab height | 34 pt |
| Chip height | 16–18 pt |
| Tray width | 400 pt |
| Page inset | 24 pt |
| Table row height | 34 pt |
| Inspector width | 420 pt, so a tray organism sits in it at its own measure. It narrows to 400 pt, the tray's own width, when that is what lets the collection fit beside it. |
| Collection beside an inspector | The collection keeps the least width its table can take. When that leaves the inspector under 400 pt, the inspector goes under the collection, at up to 540 pt. |
| Flexible table column | 132 pt at least |
| Sidebar row height | 28 pt |
| Mode rail width | 48 pt |
| Mode rail cell | 32 pt square, 18 pt icon |
| Context list width | 196 pt |
| Place mark | 18 pt |
| Corner count | 14 pt |
| Toolbar band | 52 pt |

### Motion

| Token | Value | Use |
|---|---|---|
| `fast` | 0.10 s | Hover and press feedback, tab and segment change |
| `standard` | 0.18 s | A row arriving or leaving, a count ticking |
| `slow` | 0.25 s | A meter filling |
| `pulse` | 1.4 s | One beat of a live lamp |
| `travel` | 6 pt | How far an arriving row moves |
| Curve | ease-out only | No spring, no bounce |

Black glass only, provisional: `fast` 0.15 s, `standard` 0.25 s, `slow` 0.35 s, ease-in-out, `travel` 0, `pulse` 1.7 s.

With Reduce Motion on:
- Movement becomes a fade.
- Pulses and spinners stand still.
- Numeric ticks become a cross-fade.

## 3. Components

Apply Atomic Design strictly. Components take values and emit targeted actions. None of them reads a model. The tray's components already follow this; promote them rather than rewriting them.

### Atoms

The descriptions below are the console form. In another theme the same atom takes that theme's roles ("Tray roles" in section 2): in black glass a button is a capsule, a lamp is a dot, the switch is the system switch, and a heading is a tracked capital kicker.

| Component | What it is |
|---|---|
| Lamp | 9 pt state mark: `on` filled circle, `off` outlined circle, `waiting` open arc, `error` diamond, `unknown` focus ring, `busy` square, `away` half-filled circle, `doNotDisturb` circle with a bar. Live lamps pulse. |
| Tone lamp | Where a view has a tone but no specific state, the lamp follows the tone: working `on`, attention `busy`, failure `error`, focus `unknown`, neutral `off` (`Tone.lamp`). The hand-off detail's state uses it. |
| Count | A place's count in `label`, on `hair`. A hot count is filled `attention` with `onAccent` ink. A figure such as "2/3" takes the count's place and is never hot. |
| Place mark | An 18 pt symbol in `secondary`, or `foreground` when selected. A project or workspace is one letter in `focus` on a square mark. |
| Spinner | 12 pt arc turning every 1.1 s. Labelled "In progress". |
| Mark | Square icon tile for a non-person thing: agent, repository, resource. Well fill, border edge, optional tone. |
| Avatar | Round picture, or the initial on the well when there is no picture. |
| Swatch | 4 × 12 pt colour bar. |
| Meter | 16 cells of 5 × 9 pt. Fill is `working`, `attention` at 80% and `failure` at 100%. With `isGood` the bar counts something wanted, such as accepted results, and stays `working` when full. |
| Field box | Sunken well with a 2 pt-radius edge that turns `focus` when focused. |
| Badge | Small outlined label. Tinted when it has a tone. Its symbol is decoration: the word carries the meaning, so a tick is never spoken as "Selected". |
| Signed badge | Marks a result sealed by a pinned device key. |
| Grant badge | An agent row's grant status: Granted is `working` with a check; Offered is outlined. |
| Holder badge | "<handle> has control", `attention` tone with a hand icon. It names the friend's handle, never an account ID; with no handle it says "A friend". |
| Read-only badge | Marks a watch view the viewer cannot steer. |
| Step mark | Health-check step: round tick, square cross, or its number. |
| Button style | Rectangular and monospaced. `standard` is outlined, `primary` is filled `focus` with `onAccent` ink, `danger` uses failure ink and edge. There is one primary action per region; in a verb strip, one per row. |
| Switch style | Square track: filled `working` when on, outlined when off. |
| Row button style | A plain row with hover tint (6%) and press tint (10%). |
| QR code | Modules drawn on whole points (2 pt or more each), `window` ink on a `foreground` tile with a four-module quiet zone and a hairline frame. It prints top-down once (`slow`); with Reduce Motion it fades in. |

### Molecules

| Component | What it is |
|---|---|
| State label | Lamp plus its word. |
| Hash chip | Trust cell (Pinned, System trust or Changed, with an icon), the hash cut to head…tail, and a copy cell. Joined cells on one hairline frame. |
| Agent chip | Harness cell in `focus` on `selection`, then the model, then `×slots`. Joined cells. |
| Segments | A few options as joined cells. The chosen cell is filled `focus`. |
| Menu field | A field box that opens a native menu. |
| Readout | A small label over a figure, with an optional lamp. |
| Status strip | A row of readouts on the well, split by hairlines. Figures tick. |
| Tab bar | Joined tabs split by hairlines, with an icon, a mono title and a count. The selected tab is on `panel` with a 2 pt `focus` lower edge. Hot counts are filled `attention`. Each tab has a ⌘ number shortcut. |
| Verb strip | A row's actions as joined cells on one frame. One cell can be the row's primary action, filled `focus` (for example Consult on a friend's agent row). |
| Band heading | Mono section name, its count, and one trailing action. |
| Band | Padded region with a hairline under it. This is how the tray is divided. |
| Trace row | Time (`HH:MM:SS`), a kind tag and text, with a 2 pt left rule coloured by kind: message `foreground`, tool `focus`, status `attention`. Hairline under each line. |
| Countdown, row form | In a table row the countdown is the time left in `data` over the same 56 × 2 pt line. From an hour up the figure reads `h:mm:ss`. |
| Countdown | Time left as a mono figure, ticking each second, over a 56 × 2 pt line that drains linearly. `working`, then `attention` under five minutes. When the full length isn't known, the line drains over the shortest offered length that holds what is left. With Reduce Motion the line steps. |
| Decision row | A request with the answers its source can take: Deny and Approve, Decline and Review, Accept, or Reply. The primary answer is the last cell. A worker's Reply opens the request where it is answered, beside the wall. |
| Link row | Opens a page: what is there, how many, and a chevron. |
| Version footer | The main window's last row (`AppVersionFooter`): a hairline, then 22 pt on the footer fill with "Agent Commander v0.1.0-pilot.3-236-g441beb9" right-aligned in `sub` and `secondary`: the git version the build stamps as `AgentCommanderGitVersion`, else the bundle's `CFBundleShortVersionString` and `CFBundleVersion`. The text can be selected and copied. Outside a bundle it reads "Development build". |
| Open-in-window row | "Open in Agent Commander": the first row of a tray page that has a main-window page (`MultiplayerOpenInWindowRow`). On the footer fill with a hairline under it, 40 pt high: a window mark in `focus`, the title in `name`, where it lands in `fingerprint` as the window's own breadcrumb ("Network › Hand-offs › this hand-off"), and an up-right arrow because the row leaves the tray. The whole row is one native button. It sends a `CommanderOpenRequest` and then closes the panel. VoiceOver reads "Open Hand-offs in Agent Commander", with the hint "Shows this hand-off there and closes this panel." |
| Window link row | The compact form of the open-in-window row, inside a band where a tab's section used to be (`MultiplayerWindowLinkRow`). 34 pt high, on the band's inset: the place's mark in `secondary`, the place's own name in `name` ("Hand-offs"), where it lands from the app down in `fingerprint` ("Agent Commander › Network › Hand-offs"), a count in `heading` when there is one (`attention` when it waits on the person), and the same up-right arrow with the same motion. One native button; it sends a `CommanderOpenRequest` and closes the panel. VoiceOver reads "Open Hand-offs in Agent Commander, 3". |
| Leaves-tray mark | An 8 pt up-right arrow in `secondary` after a verb or a row state that opens the main window instead of a tray page: Audit in an agent's verb strip, a hand-off or a fan-out in Live remote work. A row that stays keeps the mark's place empty, so states line up. |
| Setting row | Label at a fixed measure, then the control. |
| Well | Sunken block for a value read closely. |
| Choice card | A selectable card: a thumbnail, a round choice mark, the option's name and one line about it. The selected card is filled `selection` with the leading `focus` marker and the word "Selected" in `working`. |
| Theme thumbnail | A small window drawn in one theme's own tokens: its rail, two panels with a state mark, and a primary action. |
| Place row | A place mark, the title in `body` and a trailing count, 28 pt high. The title is laid out first. A figure that is a name (the host in use on the Hosts row) is cut in the middle when the column is too narrow, so a short title never wraps; the row's tooltip says the name in full. A count is never cut. The selected row is filled `selection` with the 2 pt `focus` leading marker. Hover tints it 6%. In the tray each of the first nine rows has a ⌘ number shortcut, named in its tooltip; the main window's context list has none. A place that can be shared (a project) offers Share… in its context menu. |
| Group heading | The group's name in `heading` and secondary ink. A group that folds is a button with a chevron; while folded it shows its hot count beside the name. |
| Mode cell | A 32 pt square cell with an 18 pt icon. The selected cell is filled `selection` with the leading marker. A hot count sits on the top trailing corner at 14 pt. Each cell has a ⌘ number shortcut. |
| Toolbar readouts | A status strip sized for the toolbar: `label` over a `data` value, cells split by hairlines on the well inside one hairline frame. `servers` shows "2/3" with a lamp (`on` when all answer, `busy` and `attention` ink when some do, `error` and `failure` ink when none do) and opens Servers. `presence` shows the lamp and word, has a chevron beside its label and opens the presence choices. `host` shows this Mac's relay ("On", "Off", "Starting", "Not set up") with a lamp (`on` running, `waiting` starting or stopping, `off` stopped) and a chevron, and opens the host menu: Start or Stop hosting, Copy relay address and "Add this relay as a server…" while it runs, then "Connect to a server…" and "Hosting on this Mac…", which open the network panel's pages. | In a window the two are two toolbar items side by side, each on its own hairline frame, so each is its own element: a "servers" button and a "Your presence" menu button whose value is the presence in force ("Auto: Busy"). The host menu is a third item between them: a "Hosting" menu button whose value is the readout ("Hosting on, at https://…"), drawn the same way as presence through `ShellCommandMenu` (a readout with a transparent `ShellCommandPullDown` over it). It is left out where the build has no relay helper. Drawn without a window they are one strip. The presence control is AppKit's own pull-down button with nothing drawn, laid over the readout (`ShellPresencePullDown`): a menu button named "Your presence" whose value is the presence in force, with a check beside the choice in force. The presence cell draws one chevron. The native pull-down over it draws nothing: its own arrow is turned off (`arrowPosition = .noArrow`). |
| Origin cell | Who asks, at a fixed 196 pt so every request starts on one line. A local worker is a 28 pt square mark, its name in `data` and its host in `fingerprint`. A network request is the server's swatch, the friend's round 28 pt avatar, the handle in `data` and the server in `fingerprint`. |
| Kind tag | question, approval, access, friend or sign-in, as a badge in `label` beside the request's title. |
| Clock label | Right-aligned in `data` over a `fingerprint` word: the time left, ticking each second, or the wait. Empty when the source gives no time. |
| Placeholder page | A page that a later increment brings: the page header with one standard action that reaches the content today ("Open network panel"), then a load note saying what will be here. |
| Reply field | A field box under a question's row, then Cancel and a primary Send. Send is off while the field is empty. Return sends and Escape cancels. |
| Alert band | Full-width band under the status strip: `failure` at 12% fill with a 45% lower edge, an error lamp and one sentence, such as "Can't reach your Mac". |
| Load note | A lamp and one sentence in a hairline-topped row. The lamp is `waiting` while reading, `error` when the read failed, `off` when empty, and `on` for "Nothing is waiting for you". |
| Outcome well | A well holding a state label that replaces a verb strip once its action is done, then fades out: Approved, Accepted and Replied in `working`, Denied in `failure`, Declined in neutral, In review in `focus`. |
| Inline confirm | The second press before something that can't be undone: a well with a `failure` edge, one sentence saying what goes with it, then a keep button and a `danger` button. It arrives under the row it belongs to. The review page's "Post this review" confirmation is the same pattern with an `attention` edge and a primary button, and scrolls into view when it opens. |
| State tally | Counts by state as joined cells that also filter: "open 3, claimed 1, done 4". The chosen cell is filled `focus`; elsewhere a count above zero takes its state's tone. |
| Claim row | Who holds what: a kind badge, the key as mono data, the holder as person and agent, when it lapses, and Release for your own, which opens an inline confirm under the row. |
| Card row | One card of a board: its state as a lamp and a word, its title, who has it, and the one step that moves it on. The text opens the card. |
| Queue row | A branch's place in the merge queue as a mono number, the branch, its state, and what stopped it when something did. Remove takes a queued or settled branch out of the queue, after an inline confirm under the row. |
| Pull request row | One open pull request: its number as mono data in secondary ink, the title in `name` on up to two lines, then the branch in `fingerprint` and the author's handle in `sub`. An up-right arrow at the trailing edge says it leaves the app. The whole row opens the pull request in the browser; a row without an https address is plain text. |
| Output well | The end of a command's or test run's output in mono on a well, selectable, with its exit state. The exit state and the time taken are one readout ("Exit 1, 41 seconds"). |
| Endorsement chips | Skills people vouch for as `working` badges with a seal, each with "×n" when more than one person did. The first four show, then "+n". |
| Group row | A group: its name, its member count, the first few avatars, and an Owner (`focus`) or Member badge. |
| Markdown block | Text an agent or friend wrote in Markdown, in the tray's type: headings, paragraphs, lists, fenced code on a well, and rules, with bold, italic, inline code and links. Nothing is fetched; an image stays as its source text. |
| Copy chip | A value as data with a copy action: a label cell on the well, the value in mono, and a copy cell that shows a tick once copied. Joined cells on one frame. The frame clips the system focus ring, so the copy cell draws an inset focus ring. |
| Inset focus ring | For a control whose frame clips the system focus ring, such as a cell joined to its neighbours: 2 pt of `focus` inside the control's own edge while it has keyboard focus. The control stays a native button. |
| Reconnecting server | A saved server that is signed in, set to connect automatically and has no live session (`MultiplayerServerSummary.isReconnecting`). The device agent retries it every second, so its row takes Connecting's waiting lamp and `focus` tone, reads "Reconnecting, online 17 min. ago", and shows the last failure under the row in `sub` and secondary ink. A timeout or refused connection reads "The relay isn’t answering. Agent Commander keeps trying." A server with automatic connection off still reads "Offline, seen …". |
| Relay row | A relay this Mac found (`MultiplayerRelayRow`), drawn the same in the Tailnet band and in Relays nearby: a 28 pt mark (`working` while the relay answers), the name in `name`, then its address in `mono` and secondary ink, with the source ("Tailnet", "Local network", "Public directory") before it in `sub` where the list mixes sources. At the trailing edge a state label, and under it any badges. 34 pt high at least. The whole row is one native button; the chosen row is filled `selection` with the 2 pt `focus` leading marker. In the Tailnet band the state is Online or Offline, and choosing a row fills the server address and starts the health check. In Relays nearby the state is "Ready to join" (`working`), "Confirm to join" (`attention`), "Sign in" (`focus`) or "Unreachable", the badges are "New" (`focus`) and the membership (Open, Allowlist, Invite only), and choosing a row opens its join checklist. A relay that can't be reached has its name in secondary ink, a neutral mark, and the reason under its address in `sub`, in plain words ("It didn’t answer in time.", "This Mac has no route to it.") rather than the device agent's network error. A relay already in the server list has its name in secondary ink and an "Added" badge with a tick in place of the state label, and is plain text, not a button. VoiceOver reads "build-relay, build-relay.tail.example, online", "den-mini, Local network, den-mini.local:8443, new, invite only, confirm to join", or "…, already in your list". |
| Join checklist | The four steps between finding a relay and being a member of it (`MultiplayerJoinChecklistView`): Reachable, Certificate trusted, Signed in, Membership. Each is a health-check step row: a round tick when it passed, a square cross when it failed, its number until then, with what was found in `sub`. The steps complete in order, and the one the checklist stands at carries the one action: "Join a tailnet", "Confirm fingerprint" or "Sign in"; when every step has passed, a standard "Open server". The action is the primary button on the Network tab and a standard button on Add server, where Save server stays primary. While the certificate waits for the person, its step holds a well with "SHA-256 fingerprint to pin", the fingerprint, and, when the relay advertises one on the local network, one line saying whether it is the same: secondary ink when it matches ("a hint, not proof"), `attention` when it differs. A relay verified on the tailnet reads "Verified on your tailnet as build-relay." and never shows a fingerprint. Membership names the mode and what it needs, with the admin's contact when the relay gives one, and says that access can be requested here if sign-in turns the person away. Once the relay has turned the sign-in away, the Signed in step carries a square cross with the relay's own sentence and a standard "Sign in again" (another account may be the one the relay admits), and the Membership step holds the request access molecule: the step is the one the checklist stands at and "Request access" is its action. While a request waits, Signed in goes back to its number ("Sign in once an admin has approved your request.") and nothing is offered; once approved, Signed in carries "Sign in"; a declined request or a full queue marks Membership with a cross. One line under the steps in `sub` names what is left. |
| Request access | A person's request to join a relay that turned their sign-in away (`MultiplayerRequestAccess`), in the join checklist's Membership step and under the server's row. Shown only when the server's own status says a request is possible or one exists. *Can ask*: one sentence in `sub` (the checklist's step says it instead), a field "Note for the admins (optional)" with the hint "They read it beside your email." (past 280 characters: "The relay keeps the first 280 characters."), then "Request access", primary on the Network tab's checklist and standard elsewhere; a spinner and "Sending…" while it goes, and a refusal under the field in `failure`. *Requested*: a state label (waiting lamp, `focus`) and "Requested 2 hours ago. The relay’s admins decide. Commander checks again on its own.", with the note that went along in a well under "Your note". *Approved*: `working`, "Approved 5 minutes ago. You’re admitted the next time you sign in."; Sign in is the checklist's action and the server row's primary button. *Declined*: error lamp, `failure`, "Declined 3 hours ago. You can ask again in about 21 hours." *Queue full*: busy lamp, `attention`, "This relay has too many requests waiting, so it didn’t take yours. Ask ops@lab.example directly." (or "one of its admins" when the relay gave no contact). Ages are whole units in plain words. Nothing here says who else is a member or who decided. |
| Secret field | A field box for a value that is never drawn, such as an auth key (`MultiplayerSecretField`): the system's secure field in mono, marked privacy-sensitive. |
| Device row | A paired device: a mark, its name, "paired … , ends …" in mono, then Rename and Revoke (`danger`). Rename opens a well under the row with a "Device name" field box holding the name, then Cancel and a primary Save name; Return saves and Escape cancels. Revoke opens an inline confirm. One of the two is open at a time, and the row's verbs hide while it is. |

### Main-window molecules and organisms (network pages)

| Component | What it is |
|---|---|
| Data table | Header cells in `label` on the header fill, then hairline rows of 34 pt on one panel. A column has a fixed width or shares what is left; figures and times are mono and right-aligned. The row's cells are one button that selects it (`selection` fill with the leading `focus` marker); its verbs sit after them as a verb strip. With no rows the table shows one note. |
| Person cell | An avatar, the handle in `data`, and under it the server as a swatch and its name. Used where a row is about someone on a server. |
| Row outcome | What takes a row's verb strip after an answer: a spinner while it runs, then a state label "Done" for 2.4 s. The row's second line says what happened in `working`. After a failure the verbs stay and the second line gives the reason in `failure` until the row is tried again. The tray's own form is under "Organisms (in the tray today)". |
| Alert band, page form | The network's last action across the page, under the telemetry strip: a spinner and a sentence on the well while it runs, a lit lamp when it confirmed, the `failure` fill and edge when it failed. Confirmed and failed bands can be dismissed. | The sentence is one static text ("Done: …") and Dismiss is its own button. The band belongs to the page the action was taken on and clears when that page is left. On a Teams page the band is tagged with the place that raised it and is drawn on that place alone, so an action that ends after the window moved on says nothing on the next page. A host that says its own outcome (a host run's exit code, the policy host's "Saved") adds no band.
| Inspector | The panel beside a collection: a title with the server's swatch and name, a state label, a close action, then the content, then a footer on the well with one line of context and the actions. Its content is a tray organism used as it is. With nothing chosen it is one note saying what choosing a row shows. |
| Request inspector | A request with no page of its own (an access request, a friend request), opened by choosing its row: who, what and when as labelled lines, then one `sub` sentence saying what the answers do. |
| Composer panel | A composer opened from a page (Consult, Hand off, Request review, Watch, Add friend, Invite, Membership, Add server): the network's own host in an inspector panel under the telemetry strip and above the page's bands, at up to 540 pt and at its full height, because the page scrolls. Its title names the composer and its server. Cancel, the close action and a finished send put it away; a refusal stays on it. |
| Compare columns, page form | A fan-out's answers side by side, each column as wide as the page allows and 248 pt at least; more than fit scroll sideways. The winner's column is `selection` at 35% with a 2 pt `focus` top edge. |
| People grid | Friends by server on one panel: a header line per server (swatch, name, "2 of 3 online"), then that server's friend rows in as many columns of 248 pt as fit. |

### Main-window molecules and organisms (Teams pages)

| Component | What it is |
|---|---|
| Band tabs | A workspace's bands (Board, Combined view, Integration, Claims) as joined cells on the well, each with its count in its tone. One band shows at a time, so each fits the window. The chosen cell is on `panel` with the 2 pt `focus` lower edge, like a tab. Each cell's figure is the figure its band's heading shows: Board counts every card, done ones too. Where a band lists more rows than its figure counts, the heading gives the figure first and then the rows listed: Integration counts the branches still waiting, and its heading reads "Merge queue 2 queued of 4" once some have merged or failed. |
| Facts line | Labelled values on one line under the telemetry strip: the label in `label`, the value in `data`. A workspace's repository, base, how it lands and its group. |
| Board columns | Open, Claimed and Done side by side on one panel, divided by hairlines. Each column's heading is its state as a lamp and a word, then its count, on the header fill. A column is 168 pt at least. An empty column says so in `sub`. |
| Board card | Square, on the `well` with a hairline edge and no shadow. A 2 pt leading rule takes the state's tone (`border` while open). The title is in `name` on up to three lines and opens the card. A claimed card carries a holder badge. An open card offers Claim; a card you hold offers Complete… as its primary. The open card is filled `selection` with the `focus` rule. A refused claim says why under the title in `failure`, and the card shows who holds it. The refusal names the holder, the agent and the claim from the relay's own fields ("sam holds it with the agent sam-codex, under the card claim Fuzz the lease parser."), and that claim's row is marked in Claims. What a claim said ("Nobody else can take it while you hold it.") shows only while the card is claimed; a Done card carries no note. |
| Holder badge, claim form | Who holds a claimed card, as person and agent ("sam/sam-codex") with a terminal symbol: `focus` when it is yours, `attention` when it is someone else's. |
| Combined view | A data table of every member's workers for a workspace: the member (avatar, handle, online lamp, once per member), the worker (name, state word, agent chip), what it holds (kind badge and key), its branch in mono, and its checks as a state label ("14 passing", "2 failing", "Running"). A member with no worker has a row that says so. The rows come from the relay's combined view (`loadCombinedView`): a published agent, or the holder of a live claim. A worker with more than one claim shows the first and "+1". A field the relay has no source for stays a dash: no branch, and checks that aren't reported are never shown as zero. |
| Confirmation well | The second press before something that writes or runs, on the `well` with an `attention` edge: the question in `name`; what it acts on in mono `focus` (a path, a destination); the steps in order when there is an order, numbered because the order is real; the changes as "label: old → new" lines; one `sub` sentence about what happens; then a keep button and a primary button. Nothing happens before the primary button. It scrolls into view when it opens. |
| Merge confirmation | A confirmation well under the queue's Run merge…: "Run the merge queue for Relay launch?", then each queued branch in order with its test command, then what happens to a branch that fails or conflicts. "Don’t run" and a primary "Run merge". |
| Install confirmation | A confirmation well first in the Knowledge inspector. It names the destination: `~/.claude/skills/<name>/SKILL.md` for a skill, the clipboard for a prompt, instructions or a summary, and the chosen file for an MCP item. It names each `${NAME}` placeholder filled from the Keychain. The buttons say what they do: "Install skill", "Copy", "Save to file". |
| Policy confirmation | A confirmation well under the policy form: "Set this policy on studio?", each change as "old → new", and a primary button that names the server. |
| Workspace edit form | The owner's edit of a workspace, in an inspector panel above the bands, at up to 540 pt: Name, Goal, Repository, Base branch and "Work lands by" as segments. Its footer says the group can't change. "Save changes…" opens a confirmation well inside the form that lists each change as "label: old → new"; nothing is saved before "Save changes". |
| Workspace owner actions | In the page header, before "New workspace…": "Edit…" for the owner, "Leave…" for a member who is not the owner (the relay refuses an owner who leaves). Leave opens a confirmation well above the facts line that says the claims end and how to come back. The facts line names the owner ("owner: you", "owner: ines"). Only the owner is offered "Add branch…", a queued branch's Remove… and "Run merge…"; a member sees the queue and one sentence saying who runs it. |
| Row panel | The tray's own row organisms (claim, queue and pull request rows) on one panel, ruled off by hairlines, at page width. |
| Policy form, page form | The tray's policy fields in three groups on one panel (Knowledge, Reputation and directory, Limits), without the tray's moderation fields. The live Admin page draws it from the policy it reads itself, beside the member and device rows. While the policy is being read the page shows one load note; a failed read says why. |
| Membership requests (Admin) | The first band of the Admin inspector, above Members: "Membership requests" with its count, then one tray need row per person a relay turned away who asked to join: the server's swatch, the email in `name`, the note in the person's own words in quotes and "Asked 25 minutes ago." in `sub` ("No note." when there is none), then Deny (standard) and Approve (primary). Neither asks twice. An answered row leaves at once and the page says "Approved noor@lab.example. They’re admitted the next time they sign in." or "Denied …. They can ask again in 24 hours."; a refusal shows under the row in `failure`. Empty reads "No one is waiting to join." A relay that won't list its requests leaves the band out with no error. The Admin place in the Teams context list carries the waiting count as a hot count, the Admin page's readouts gain "requests to join" in `attention`, and the tray's Admin window link row on a server's page counts them ("2 requests", `attention`). |
| Member and device rows | In the Admin inspector: an avatar or a mark, the name, a state label (Active, Suspended), then Suspend… or Unsuspend, or Revoke…. Suspend and Revoke open an inline confirm under the row that names the person or device and the server. The rows are the relay's own list (`loadRoster`): a member or a device is chosen from it, never typed. A member who hasn't chosen a handle reads "No handle yet" and "Can't be suspended yet". The relay stores no device name, so a device is named by its ID, then its owner and "online now", "seen 2 h ago" or "never connected". |

### Main-window molecules and organisms (Hosts page)

The Hosts page is where the app's one service is chosen: this Mac's, or a headless host's through its SSH-forwarded socket. It is a place of the Agents mode, last in the Workspace group, with the crumb "Agents › Workspace › Hosts". It follows the [Hosts concept](design/concepts/hosts.png): a collection of 382 pt beside an inspector. Every part is an existing atom or molecule; only the host row was promoted to a molecule of its own.

| Component | What it is |
|---|---|
| Host row | One host in a host list (`HostListRow`, a molecule shared by the concept's Hosts page and the live one): a 31 pt icon tile, the name in `name` over what kind of host it is in `sub`, then a state label at the trailing edge. The row shown in the inspector is a selection card, and its tile takes the `working` ink while the host is connected. The host whose service the app is using has an "In use" badge with a tick beside its name. A long name is cut in the middle. VoiceOver reads "acx-headless, Headless · v0.0.6, connected, in use". |
| Host list | A panel (`CommanderHostList`): the heading "Hosts" with the count in mono, This Mac first ("Local service"), then each headless host in agentctl's order ("Headless · v0.0.6"), then a hairline and how a host is added: "Add a headless host from Terminal" over `agentctl host deploy DESTINATION` in mono. A list that can't be read shows a callout with agentctl's reason and keeps This Mac. Choosing a row only shows it in the inspector. |
| Host detail | The inspector (`CommanderHostDetail`): a 46 pt icon tile in the state's tone, the kind as a heading over the name in the page's detail title, and the state label. Then fact columns split by vertical hairlines: Connection ("SSH socket"), Version, API and Deployed for a host; Connection and Runs on for This Mac. The API column is as wide as its number and the others share the room. Deployed is the day and the time in this year ("Nov 26 at 1:05 PM") and the day and the year before it. A value cut in a narrow window shows in full in its tooltip. A disconnected or failed host shows a callout with agentctl's own detail. The footer, on the footer fill, has one line saying which service the app is using or waiting for, and one action. The line is short enough to stay on one line beside the action ("Waiting for SSH. The host keeps its workers running."); its tooltip carries the rest. |

- **States.** A host is Not connected (neutral), Connecting… (`focus`), Connected (`working`), Disconnected (`attention`) or Can’t connect (`failure`). This Mac shows the app's own link to the local service while it is in use, and Not connected while a host is.
- **One action.** "Use this host" is the primary button on a host that is not connected, and reads "Try again" after a failure. A host that is in use, connecting or waiting for SSH has a standard "Disconnect", which returns to This Mac. This Mac has "Use This Mac" while a host is in use, and no button while it is itself in use. The header's one action is a standard "Refresh", which reads the host list again.
- **Elsewhere in the window.** The Hosts place row shows the host in use as its figure. The toolbar's service state names the host: "acx-headless online" in place of "Service online". While SSH is down it reads "acx-headless offline" and the feed banner says "The connection to acx-headless dropped. Reconnecting."; both clear when the host answers again.

### Main-window molecules and organisms (Harnesses page)

The Harnesses mode shows the AI harnesses this Mac can run: whether each is installed, whether it is signed in, and its settings. It is the fifth mode on the rail, after Teams. Its places are filters of one page: Needs sign-in (listed only while a harness needs it), Installed and Available. The page follows the network pages' layout: the header, then a collection beside a 420 pt inspector, which goes under the collection in a narrow window. The API it reads is in [design/HARNESSES.md](design/HARNESSES.md).

| Component | What it is |
|---|---|
| Harness row | One harness in a list (`HarnessRow`): a 31 pt icon tile (a terminal for an agent, a chip for a model runner), the name in `name` over who makes it and what it is in `sub` ("Anthropic · Agent"), the version in `data` and secondary ink in a 76 pt column, then a state label in a 136 pt column at the trailing edge, so versions and states line up down the list. Beside the name: a "Runs" badge in `focus` where Agent Commander can start runs with it, a "Blocked" badge in `attention` where a run can't start now, and an "Off" badge where it is turned off. A harness that isn't installed has its name in soft ink. The row shown in the inspector is a selection card. The host row was not reused because it has no place for a version. VoiceOver reads "Claude Code, Anthropic · Agent, Signed in, version 2.1.332". |
| Harness list | A panel (`HarnessList`): a band heading with the place's name and count, then a harness row per harness. Available is ordered vendor, open source, IDE, model runner, then by name. An empty place is one note ("Every installed harness is signed in."). Choosing a row only shows it in the inspector. |
| Harness detail | The inspector (`HarnessDetail`), on the network inspector: the name over who makes it, and the state label. Then bands of labelled lines: **Install** (state, path and version in mono, or the install command), **Sign-in** (state, account, plan, method, expiry as a time, and where the state was read), **ACP** (adapter in mono, mode), **Settings** (an Enabled switch and a Default model menu field with "Harness default" first). The service's reason a run can't start (`run_blocker`) is a callout in `attention`, first in the inspector; a missing adapter with no such reason is a callout in the ACP band. An unverified harness reads "From credential files" and says in one `sub` sentence that its own status command wasn't checked. The service's own detail on a state (why it is Unknown) shows as a `sub` sentence. A refused call shows its two sentences in a `failure` band under the header. The footer has one line and one primary action. |
| Session sheet | A sign-in or install (`HarnessSessionSheet`), 780 pt wide: an icon tile, "Sign in to OpenCode" in `title` over the command in `mono`, a pulsing "Running" state label, the terminal at 440 pt, then a footer with one sentence and a standard Close. The terminal is one tmux client on the session the service started, and it takes the keyboard. The sheet closes when the client ends; Escape and Close put it away and leave the command running. Where the app finds no tmux, the sheet shows an error note and the same attachment as a command to copy. |
| Run harness gate | In the New run form (`RunHarnessGateRow`), under "Harnesses": one field-shaped row per managed harness that is turned on, with its name, its part in the run ("Coordinator", "Workers") and its state. A harness that can't start a run is dimmed and gives the reason in `attention`: the service's own reason when it sends one, else "Not signed in". "Sign in" shows only where the harness has a sign-in command and isn't signed in; it opens the session sheet. |

- **States.** Signed in (`working`, lamp `on`), Not signed in (`attention`, `busy`), Expired (`failure`, `error`), Unknown (`focus`, `unknown`), No sign-in needed and Not installed (neutral, `off`).
- **One action.** The inspector's primary button is "Install" for a harness that isn't installed and has an install command, and "Sign in" for an installed one that is signed out, expired or unknown and has a sign-in command. A signed-in harness has no button; the footer says when it was last checked. The header's one action is a standard "Refresh", which checks every installed harness again.
- **Unavailable.** While the service doesn't answer or has no harness routes, the page is one panel: an `error` note, "Harness status is unavailable. …", and Try again. The app keeps retrying. A list that was read stays on screen while the connection is down, and the header says so.
- **Elsewhere in the window.** The mode cell's hot count is the number of installed harnesses that are signed out or expired. When a harness that was signed in becomes signed out or expired, Needs you gets a row with the kind tag "sign-in" ("Claude Code signed out", from This Mac) whose one answer is a primary "Sign in", and macOS shows a notification. The row leaves when the harness is signed in again. The New run form lists only managed harnesses that are turned on, and Start run is off while the coordinator's harness can't start a run; the form follows the live list, so it turns back on without being reopened.

### The wall's frame (main window)

| Component | What it is |
|---|---|
| Wall heading | The heading over a pane of the cockpit (Coordinator, Worker wall): a 12 pt symbol, the title in the pane heading role, and the pane count. |
| Wall crumb | Over a zoomed worker: a back chevron and "Worker wall" in the pane heading role, a slash, then the worker's name in regular weight, then what marks it (a Read-only badge on a remote worker). |
| Group frame | The container a group of tiles sits in: group fill, a hairline group edge and the group radius, with 9 pt between the edge and the tiles. A folded group has no room under its heading. |
| Remote band | Under the local workers: the network's own remote worker group (its heading, up to three remote worker tiles, and "n more…" to Hand-offs), then, in a group frame of their own, at most two wall work rows under the heading "Reviews and fan-outs" with its count and a trailing link to Hand-offs. It draws nothing when there is neither. |
| Wall work row | A review or a fan-out you sent that still needs you (a review not yet posted, a fan-out with no winner): its kind glyph, the title in `name`, the target in `sub`, the state right-aligned in its tone, and a chevron. The whole 28 pt row opens its page. |
| Control dock | Under a worker's tile, 4 pt below it and outside its shell, while the network has something to say about that worker. A friend who holds it gets the tray's holder row as it is: the Holder badge, the worker and server, the countdown and Take back. The dock's edge is the attention edge while someone holds control. A waiting Co-pilot suggestion is a suggestion row. Rows are split by hairlines. Under a zoomed worker the dock sits below the console. |
| Suggestion row | A "Suggestion" badge in `attention`, one line in `sub` ("jonah suggests: …"), and Review, which opens the suggestion in Approvals. |
| Apply confirmation | In the Hand-offs inspector, first under its header. Apply… or Save… on an artifact asks for the checkout, then shows a well with an `attention` edge: the question naming the artifact and the folder ("Apply retry-budget.patch to relay?"), the full path in mono `focus`, one `sub` sentence saying what happens and that nothing is overwritten, then "Don’t apply" and a primary "Apply to relay". Nothing is written before the primary button. The other artifacts' buttons are off while it waits. |
| Apply outcome | One per artifact applied, under an "Applied" band heading and kept while the hand-off is open: the artifact's name in `data`, a state label (a spinner and "Applying", "Done" in `working`, "Not applied" in `failure`), and the device's sentence under it. |

### Organisms (in the tray today)

The need row is something waiting on the person: the server's swatch, a title in `name`, one line in `sub`, then the answer. A friend request's line names the server and, when the relay says, how long ago it came ("On home, 5m ago"). A request that can be refused has Decline first and the answer after it as the primary button. Declining a friend request takes one press: it refuses, the sender can ask again, and nothing is deleted.

**Answered rows.** An approval or an access request the person answered stays in the network's lists for 2 seconds (`MultiplayerShareModel.answeredHold`), marked with how it came out (`answer(for:on:)`: Approved, Denied, Declined, Withdrawn). It keeps its place through every read in that time, then leaves. It no longer waits: counts use `waitingApprovals` and `waitingAccess`, and a list that shows outcomes uses `pendingApprovals` and `pendingAccess`. A model built without a hold (a test, a fixture) removes the row at once.

The tray's row outcome is drawn on the decision row in Needs you. Where the row's two verbs were, a state label fades in at the `standard` pace: a lit lamp and "Approved" in `working`, or an unlit lamp and "Denied" or "Declined" in secondary ink. The row's text no longer opens the request and is dimmed. The band's count drops at once. When the hold ends the row leaves as every row does: it fades while moving `travel` to the right, or only fades with Reduce Motion. VoiceOver reads the outcome with the request ("Approved: …").

The activity feed says where a waiting request is answered by a name that holds in both the tray and the main window: "<who> wants to <what>. Approve or deny it under Needs you."

The grant sheet is one form drawn in two places. The tray shows it as a page with the tray's footer. A view outside the tray presents the grant host: the same form in a scroll area over a footer with the hint, Cancel and a primary Share. A refused grant shows its reason in a failure banner at the top of the host and leaves the sheet open.

**Hosts.** Every composer a view outside the tray presents is drawn through a host: the tray's own composer in the host frame (`MultiplayerHostFrame` in `MultiplayerHosts.swift`). There is a host for the grant sheet, Consult, Hand off, Request review, Watch, Add friend, Invite, Membership and Add server. Teams has a host for New workspace, Claim, Card, Queue a branch, Share knowledge, Run on a host and Relay policy (`MultiplayerTeamsHosts.swift`). A host adds no styling. A host's `onCancel` is optional: with none, the footer has no Cancel or Close, for a page that is the host's home and has nothing to close.

- **Frame.** A banner band, the composer, then the tray's footer with the composer's hint, Cancel and the composer's own actions. Cancel reads Close once a host that stays open has something to show (a consult's reply, an invite link, a watch).
- **Scrolling.** A host scrolls its composer by default. With `scrolls: false` it has no scroll view and takes the composer's full height, for a pane that already scrolls.
- **Footer.** A button's label is never cut short. Where the hint and the actions don't fit one row, the hint takes a footer row of its own above the actions.
- **Banner.** A refusal shows in a failure banner at the top and leaves the host open. A confirmation that belongs to the host ("Invite link copied.", "Membership saved.") shows in a success banner in the same place.
- **State.** A host keeps its draft, its reply and its refusal itself, and names its server and resource. It never reads or moves the tray's page, so the tray can show anything, or be closed, while a host is open.
- **Second press.** A host that can undo or remove something (release a card, suspend a member, revoke a device) asks with the composer's own inline confirm and keeps that step itself. The tray's pending confirm is never used or cleared.
- **One route.** The tray has one route, and only the tray's own calls read or move it. Each change has two forms. The tray's form reads the tray's draft and sends nothing unless the tray is on that page. The form a host uses names its server and target and takes the host's own values. It never reads or moves the route, and leaves the tray's drafts and the list on its open page alone. Reads work the same way: a host or a window page reads for itself (`loadCards(in:on:)`, `loadPolicy(on:)` and the like) and keeps the result. Lists kept per server (groups, workspaces, the knowledge library, the merge queue) are shared, so a change made anywhere shows everywhere.

Need row, server row, friend row, activity row, holder row, finding row, control band, remote-work band, agent roster, certificate notice, window link bands (a band heading over window link rows) and Remote band.

The tray's own pages are the watch view, the control page, consult, the hand-off composer, request access, the grant sheet, request review and New workspace. The directory, access requests, approval, hand-off detail, thread, audit, fan-out composer, compare, review and relay policy views are drawn by the main window only ("What the main window reuses").

The hand-off detail shows its state as a state label (lamp plus word, such as "Done") and its Sent and Checked times in `fingerprint`.

**The triage tray.** The tray keeps decisions and quick actions. A page whose main-window page has passed a running-window check is gone from the tray: what is left of it is a link that opens the window page and closes the panel.

What stays in the tray:

- **Home:** the status strip, presence, server health and trust, friend and server rows, and the Remote band.
- **Decisions, inline:** Needs you answers approvals (Approve, Deny), access requests (Review opens the grant sheet, Decline) and friend requests (Accept, Decline) on the row. An approval's text opens that approval in the window.
- **Quick actions:** Consult, Share (the grant sheet), Request access, Hand off, Request review and New workspace, each a composer page with no row.
- **Take back control:** the control band and the control page.
- **Servers and you:** Add server, hosting, a server's page, profile, invite and membership.

**Hosting.** The Hosting page (`MultiplayerHostingPage`, `MultiplayerHosting.swift`) runs this Mac's relay. Its bands: what hosting is; a state label (lamp and word, the lamp beating while the relay runs) over the relay's address in `mono` and its fingerprint (`MultiplayerFingerprintText`), or, before the first setup, the setup form: "Your email" (required, the first admin), "Relay name" (from the Mac's name), and a Google sign-in client ID only when the Mac has no Google Desktop client to reuse, then the address friends will use; and, while the relay runs, the two steps left (add it here, give friends the address), the first ticked once a saved server carries the relay's pin. Once the relay is set up, a last band holds **List publicly** (`MultiplayerHostListingBand`): the name in `name` with a tray switch, off by default, over one paragraph in `sub` that names the directory ("…at directory.bytedesk.ai…") and what it lists. Turning the switch on sends nothing: it shows a "Public address" field in `mono` (placeholder "https://relay.example.org") and a standard "List relay", enabled once the address has the shape of an https origin; "http://" and other shapes are named under the field in `failure` before anything is sent, and the relay checks again. Once listed under an address the band shows "Public address" and "Directory" as labelled `mono` values, then a state label with one line in `sub`: "Listed" (`on`, `working`, "Confirmed with the directory 2 minutes ago."), "Not listed" (error lamp, `failure`, the reason in plain words and "Last tried…"), "Lists when the relay is running" (off lamp, neutral) while the relay is stopped, and "Checking…" (waiting lamp, `focus`, beating, "The relay registers within about 30 seconds.") from turning on until the relay reports its first try; the page reads the relay every 5 seconds meanwhile. "Change address…" (standard) brings the field back with "Update address" and "Cancel". Turning the switch off unlists at once. A refused change shows under the band's controls in `failure`, not in the page's banner. A refused start or stop shows in a failure banner at the top with the relay's own reason. The footer (`MultiplayerHostingActions`) has the primary Start hosting while stopped, and before the first setup, where it is enabled once the form is complete and sets the relay up first; Stop hosting in the danger role, then a primary Add server that fills in the relay's address, while it starts or runs; and Check again when the relay helper can't be run.
- **Still to pass, page and row:** Watch and Control. Each keeps its page with the open-in-window row above it. Watch stays until the wall's zoom to a remote tile passes a check with the service running. Then it becomes a link as the others did. Control is a documented deferral: its page is the only place to hand control to a friend, and no hand-over composer is planned for the window, so the page stays in the tray.

What is now only a link:

| Was a tray page | Opens | Item opened | Where the link is |
|---|---|---|---|
| Shared directory | Network › Directory | — | Agents tab, under Friends’ agents; a server's page |
| Access requests, an approval | Network › Approvals | The approval | A server's page; an approval's text in Needs you |
| Hand-offs, a hand-off | Network › Hand-offs | The hand-off | A server's page; a hand-off in Live remote work; a remote worker's zoom |
| Thread | Network › Threads | The thread | "Open thread" on a consult's reply; Thread on a review |
| Audit | Network › Audit | The resource's entries | A server's page; Audit on one of your agents or resources |
| Fan-out, compare | Network › Fan-out | The fan-out | Agents tab, under Friends’ agents; a fan-out in Live remote work |
| Groups, a group | Teams › Team tools › Groups | — | People tab; a server's page |
| Workspaces, a workspace, claim, card, queue a branch | Teams › Workspaces | — | Agents tab; a server's page |
| Hosts, run on host | Teams › Team tools › Hosts | — | Agents tab; a server's page |
| Knowledge library, share knowledge, a knowledge item | Teams › Team tools › Knowledge | — | Agents tab; a server's page |
| Reputation, directory search | Teams › Team tools › Directory | — | A server's page |
| Relay policy | Teams › Team tools › Admin | The server's policy | An admin's server page, last in the Teams band |
| Review | Network › Hand-offs | The review | A review in Live remote work |

Watch's and Control's rows land on Agents › Workspace › Runs zoomed to the worker. A review's request names the wall; the window's router shows it on Network › Hand-offs, where its findings and Post to PR are, and the review's row reads "Network › Hand-offs". Every row takes its place words from `CommanderOpenRequest.landingCrumbs` and the tray keeps no table of places ([request 6](design/demos/main-window-6/TRAY-REQUESTS.md)). The tray writes only the item words: "this review", "this worker".

- **Control.** The Control verb on one of your agents and a holder row's text in the control band open the tray's control page: who has control, Take back, and the form that hands control to a friend for a while.
- **After Request review sends.** The composer returns to where it was opened and the notice says what happened. The review shows in Live remote work, which opens it in the window.

- **Where a link sits.** A tab's dense section becomes a band of window link rows in the same place, under the section's heading: "Teams" on the Agents tab (Workspaces, Hosts, Knowledge, with New… as the heading's action), "Groups" on the People tab, and "Share and consult" (Directory, Approvals, Hand-offs, Audit, with Share… as the heading's action) and "Teams" on a server's page (Groups, Workspaces, Hosts, Knowledge, Directory, and Admin for an admin). Directory and Fan-out sit under Friends’ agents, below a hairline. A tab's row stands for every server and opens the place alone; a row on a server's page names that server. A row shows the count the section showed. The Hand-offs row counts what the window's page lists, that server's hand-offs plus its reviews, and says so: "3 sent". Approvals and access requests are answered on one window page, so they share a row and a count.
- **A verb or a row that leaves.** Where one thing in a kept row opens the window, it carries the leaves-tray mark and says so in its hint.
- **After a composer sends.** Hand off and New workspace return to where they were opened and say what was made in the notice. The hand-off shows in Live remote work, which opens it in the window.
- **A route to a removed page.** The route cases remain, because the window's own pages and the router name items by them. If the tray is put on one, it draws the open-in-window row alone, with "This page is in the main window now." in the footer. `MultiplayerSharePage.staysInTray` says which pages the tray draws, and `MultiplayerPageOpener` sends every entry point to the tray page or the window page accordingly.
- **No tray page maps to Network › Shared.** The server page's "Access you’ve given" and "Shared with you" lists stay as server rows.
- **Motion.** Under the pointer the row takes the row tint and the arrow leans out a third of `travel` (2 pt up and right) and turns `focus`, at `fast`. Pressed, the arrow goes the full `travel` and fades, at `fast`. With Reduce Motion the arrow stays where it is and only its ink changes. Nothing delays the press: the request is sent at once.
- **Seams.** The row reads `multiplayerWindowOpener` from the environment (`MultiplayerWindowOpener`: open, then close). The shared router is the default; `MultiplayerPanel` adds the close of its own panel. The review stage draws the panel inside the cockpit window and passes `closesOnOpen: false`.
- **Closing the menu bar panel.** `MenuBarExtra` keeps whether its panel is open, and the SDK has no binding to it. The scene's content is marked with `multiplayerMenuBarPanel()`, which hands the panel SwiftUI's `dismiss` as a `MultiplayerPanelDismissal`. A link row closes the panel through it and does not call `NSWindow.close()`, so one click on the menu bar item opens the panel again. If the panel is still on screen after 400 ms, its window is closed directly. A panel in any other window closes that window.

The main window adds the mode rail with a context list (the user's choice of sidebar) and the Needs you row.

A Needs you row is an origin cell, a hairline, the request (title in `name` with its kind tag, one or two lines in `sub`), a clock label and a verb strip. Rows share one panel and are ruled off by hairlines.

A decision row for an approval names the worker and its server ("relay-worker on ryan-mac"). A holder row is the Holder badge over the metadata line, then the countdown, then Take back.

Increment 4 (merged at `341215d`) adds:
- **Control band:** a holder row, a countdown, and Take back.
- **Watch view:** readouts for the worker, line count and last read. A trace with a spinner labelled "every 2 s". Read-only and Signed badges. A suggestion field with a footer note.
- **Review:** a summary, then finding rows with important or nit severity. "Post to PR" has an inline confirmation. A review-request composer.
- **Fan-out:** a composer, and compare columns. "Choose winner" is a standard button; the chosen one shows "Winner" as primary. A footer note says the choice is local only.
- **Live remote work rows:** a leading kind glyph (hand-off ↗, fan-out fork, review list) and a right-aligned state in tone, such as "2 of 2 answered" or "2 important, 1 nit".

Increment 5 (teams) adds:
- **Teams band** (Agents tab), **Groups band** (People tab) and **Teams band** (server page): window link rows since the triage tray; the server page's band ends with a window link row to Admin for an admin.
- **Pages** (drawn by the main window and the hosts since the triage tray; the tray keeps New workspace): groups, group, workspaces, new workspace, workspace (goal, claims, board with a state tally, merge queue or pull requests), claim, card, queue a branch, hosts, run on host (output well), knowledge library, share knowledge, knowledge item (Markdown block and versions), reputation (the 16-cell meter with `isGood`, endorsement chips), directory search and relay policy.
- **Second presses:** deleting a group, removing a member, releasing a claim, releasing a card you hold, removing a branch from the merge queue, suspending a member and revoking a device each use the inline confirm. The first button ends in "…" and is disabled while its confirm is open. Leaving the page ends the confirm.
- **Run on host:** the Extra arguments field shows only for a command whose owner allows them (`capabilities.commands[].allowArgs`). For a command that takes none, a note says so and typed arguments are not sent. A host that doesn't publish its commands keeps the field. The command's environment is named under the picker.
- **Pull-request workspace:** a "Pull requests" band in place of the merge queue. Its heading carries the open count and a trailing Repository button that opens the repository's pull-request list. Each open pull request is a pull request row, split by hairlines. The device reads them with the person's own `gh` only as the page opens and when its Refresh is pressed. While reading, the band shows the spinner and "Reading the open pull requests…"; with none open, one `sub` sentence; when the read fails, the reason in `failure` with Try again (a missing or signed-out `gh` says what to check). At the device's limit of 50, a `sub` line points to the repository for the rest.
- **Remote workers on the cockpit wall:** a hand-off runs on a friend's Mac, so the wall shows it as a remote worker tile: the console title bar and harness surface of a local tile, the friend and server as its host, and task, from, via and sent as mono lines in place of a terminal. Up to three tiles sit in the remote band under the local workers (see "The wall's frame"). The band draws nothing until there is a hand-off, a review or a fan-out to show.
- **Remote worker zoom:** choosing a tile zooms it in the cockpit. The zoom view is a panel with the hand-off's task, target and state, then the tray's watch view (owner and server, Read-only and Signed badges, readouts, trace rows) and a footer with one button, "Open hand-off" (it opens the hand-off's window page) unless the caller titles it or leaves it out (`footerTitle`). It reads while it is on screen. It sends nothing unless the caller allows suggestions (`allowsSuggestion`) and the owner shared Suggest on the worker: then the watch view's suggestion field shows under the trace with the caller's draft, the footer adds a primary "Send suggestion" (⌘Return), and the footer's note says the owner approves each one. Without a Watch grant it says so in a load note. In the main window the bar over it is a wall crumb with a Read-only badge and one standard action, "Open hand-off", which goes to the hand-off on its page; the zoom view then has no footer button of its own, and it takes a suggestion where the owner shared Suggest.

Increment 6 (the tray's Remote band, on the Network tab) adds:
- **Remote band:** a band heading with the paired-device count and a switch. Under it a state label (Serving or Off) and one sentence. While serving: the address as a copy chip; the pairing block (QR code of the pairing link beside the code as a copy chip in `figure` type, a countdown over ten minutes, the link as a copy chip, and New code); then device rows. With no code on show, a state label ("No code" or "Code expired") and one primary action, Pair a device. The device agent names its unused code, so a tray that reopens shows the same QR code, code, link and countdown.
- **Keyboard:** the tray's scrolling page and the Remote band are focus sections. Tab visits every control in one before it moves on, including rows scrolled out of sight, and reaches the footer last.
- **Motion:** the QR code prints once, the block and rows arrive, the countdown drains, and a copy cell ticks. A device that pairs ends the code and the block leaves.

Increment 6 (the Remote web page) adds:
- **Touch scale:** controls are 44 px high, type about 15% larger (body 15, name 15, sub 13.5, heading 13, state 12, figure 17, trace 12.5), and the header icon action is a 52 px full-height cell split off by a hairline.
- **Decision row, phone form:** lamp, title, a countdown on the right, summary, the metadata line with the swatch edge, a 2 px drain line, then Deny (danger) and Approve (primary) as two joined 44 px cells. Under one minute the countdown and line turn `failure`.
- **Pairing steps:** numbered hairline rows on the not-paired screen.
- **Watch band:** the workers friends let you watch, each with an eye mark, its name, the owner's handle, the metadata line and a full-width Watch. It is the way into the watch view without a hand-off.
- **Band action:** a band's one action sits at the trailing edge of its heading as a text verb in `focus` with a 44 px hit area. Activity has Mark seen while something is unseen; a refusal shows under the heading in `failure`.
- **Stopped watch:** when the Mac refuses a watch, the view stops reading, the footer says Stopped, and the load note has a full-width Try again under it. It keeps retrying only while the Mac can't be reached.
- **Sentences:** a lead-in and a device's reason are joined as two sentences, each with a capital and a closing mark, as in the tray. The alert band holds one sentence; the time of the last good read is in the header's state label.
- **Motion:** `arrive` (0.18 s, 6 px travel, ease-out) for new rows and trace lines, `tick` for a changing figure, and a drain line that moves linearly each second. With reduced motion these become fades, and pulses, spinners and the drain stop.

Relay discovery (the tray's Relays nearby band, design/COMMANDER-NETWORK-DISCOVERY.md) adds:
- **Relays nearby band** (`MultiplayerRelaysNearbyBand`), the first band of the Network tab, of Add server, and of the first-run page. A band heading "Relays nearby" with the count, then relay rows split by hairlines: the relays that answer first, then by name. A relay already in the server list is not listed. Choosing a row opens its join checklist under it, inset to the row's padding, with the row's `focus` marker running on beside the steps; choosing it again closes it. The checklist fades in over `standard`. A relay that was joined from its checklist stays listed until the checklist closes.
- *Looking*: a spinner in the heading and "Looking on your tailnet and your local network…". *None*: "No relays nearby. One shows here when it advertises on your tailnet or your local network." A refused read shows its reason in `failure` only while there is nothing to list. Add server and the first-run page show the band only when it has a relay; an Add server form opened from an invite has none.
- **Not on a tailnet**: when the device agent says this Mac is on no tailnet and a relay that lives on one can't be reached (found on the tailnet, or named or failing at a tailnet address in 100.64.0.0/10 or fd7a:115c:a1e0::/48), the Reachable step offers "Join a tailnet". Any other unreachable relay shows its reason only. On the Network tab it opens Add server, whose Tailnet band holds the join form; on Add server the step says "Use the Tailnet section below to join one."
- **Notify me about relays nearby**: on the Network tab the band ends with this label in `sub` and a tray switch. It is on by default and kept under `network.relaysNearby.notify`.
- **New relays**: a relay the person hasn't seen carries the "New" badge, counts on the Network tab, and puts a dot ("•") after the menu bar symbol, ahead of the unseen activity count ("• 3"). VoiceOver adds "2 new relays nearby". With notifications on, each new relay posts one macOS notification, "Relay nearby" with "build-relay is on your tailnet. Open the network tray to join it." Nothing is posted in Do not disturb or while the band is on screen. The band marks what it lists as seen while it is on screen.
- **Request access**: a relay in the list that turned the sign-in away shows where the request stands on its row in place of the join state: "Request access" (`attention`), "Requested" (`focus`), "Sign in" once approved, "Declined" (`failure`) or "Queue full" (`attention`). The server's row in Servers carries the same request access molecule under its pin, inset to the row's text; while a request waits the row's trailing Sign in gives way to the state label "Requested", and once approved Sign in is the row's primary button. The request model (`MultiplayerMembershipRequestModel`) owns the four verbs, reads a waiting request again after each server list, and lets what a verb answered stand until the server's status says something new.
- The discovery model (`MultiplayerDiscoveryModel`) owns the three verbs, the seen marks and the notifications, and reads after each server list. The band takes relays and a checklist and emits select, confirm, sign in, open and join-a-tailnet. Confirm sends the key the device agent observed; the advertised one is only drawn. Sign in is the server's own sign-in.

The Add server form (tray page and host) starts with:
- **Tailnet band** (`MultiplayerTailnetBand`), above the server address. A band heading "Tailnet" with the relay count once they are listed, and a state label as its trailing item. Under it, one of:
  - *Running*: the state label is `on` with the tailnet's name in `working`. Relay rows split by hairlines, ordered online, offline, then added, and one line: "Choose a relay to fill in its address and check it." Choosing a row is the same check as the Check server button; nothing is pinned or saved by the list.
  - *No relays*: "No relays on this tailnet yet. A relay shows here once its node is tagged tag:relay." and Check again.
  - *Not installed*: an `off` lamp and "Not installed", one sentence, then "Get Tailscale" (it opens tailscale.com/download in the browser, so it carries the up-right arrow) and Check again.
  - *Not joined*: an `off` lamp and "Not joined", one sentence, a "Login server" field, segments for "Sign in with browser" and "Use an auth key", a secret field for the key only under that choice, and "Join tailnet". Join is a standard button: the page's one primary action stays Save server. A refused join shows its reason in `failure` above the fields. The key leaves the form when it is sent.
  - *Waiting for sign-in*: a `waiting` lamp with the words in `attention`, one sentence, the login page as a copy chip labelled "login", and "Open login page" with the up-right arrow. The band reads the status every 2 s until this Mac is on the tailnet, then lists the relays. The reads stop when the form leaves.
  - *Not checked*: an `error` lamp, the reason in `failure` as two sentences, "You can still type an address below." and Try again.
- The band is its own region and never disables the address field, the health check or the footer. A form opened from an invite has no Tailnet band, because the invite names its server.
- The tailnet model (`MultiplayerTailnetModel`) owns the three verbs and the poll. The band takes its phase and emits choose, join and refresh. A host keeps its own join draft; what this Mac's tailnet is, is shared.

### What the main window reuses

The network pages (Servers, Directory, Approvals, Hand-offs, Threads, Audit, Fan-out, Shared, People) reuse these as they are, inside an inspector: certificate review, server settings, identity band, directory card, request-access form, approval page, grant sheet (through its host), hand-off detail, review page, thread page, fan-out composer, holder row, friend row, activity band and profile editor. Two are drawn again at page scale because the tray's forms are fixed to its width: the audit list (a data table) and the compare columns.

Reuse the following:
- All atoms and molecules listed above
- Trace row
- Decision row and approval page
- Fan-out compare columns
- Hand-off detail and audit page

The tray keeps its own versions of these:
- Status strip placement
- The three-tab shell
- The compact server and friend rows

### Pretty transcript

This section is the rule for the Pretty view's transcript. Its main view is built: sentences, groups, failure lines, the report, the live line, the Thinking row, typed results with Source, the plan card, the frame and the transcript setting. Background work is built for the records the app holds, the older Claude runner's background commands and child agents among them. So are the edge cases that runner produces. Still to build: a network submit's background line and the ACP edge cases, marked below. Change either from this section, the [spec](design/mockups/pretty-conversation.md) and the [mockup](design/mockups/pretty-conversation.html). Console mode stays as it is, and so does the provider's output in Terminal mode.

| Part | State | Where |
|---|---|---|
| Sentences, grouping, failure words, state tags | Built | `ActivitySentence.swift` |
| Line, group, failure line, report, live line, Thinking, plan card | Built | `PrettyConversationViews.swift` |
| Typed results, pretty-printed JSON, Source, hidden secrets | Built | `ActivityResult.swift`, `ActivityResultViews.swift` |
| Status line, prompt bubble, request form | Built | `FocusedPrettyConsole.swift`, `ConsoleDisplay.swift` |
| Message box with queue, Remove and Stop; Settings › Transcript | Built | `PrettyComposer.swift` |
| Stored tool details: read after the last revision, full record on open | Built | `ToolDetails.swift` |
| Background work: delegated worker, follow-up, stop and interrupt, pending question, integration | Built | `BackgroundJob.swift`, `BackgroundWorkViews.swift` |
| Background work: background command and child agent of the older Claude runner, from `job` records | Built | `PrettyRecords.swift` (`ProviderJobs`) |
| Background work: ACP `subagent_update`, network submit | Not yet built | spec section G |
| Edge cases of the older Claude runner: end-of-turn line, placed thoughts, provider tool sentences, question card, plan document, deliverable card, known failures | Built | `PrettyRecords.swift`, `PrettyRecordViews.swift` |
| Edge cases of ACP: diff, terminal, locations and kind content, content blocks, permission option kinds, elicitation restyle, plan update, notice, compaction, session message, suggestion chips, gap row | Not yet built | spec section H |

**Metrics.** `PrettyMetrics` holds every Pretty size: `body` 13 pt on the focused worker and coordinator, 12.5 pt on a wall tile, 11.5 pt in the PiP; the 9 pt list and field corner, the 5 pt tag and well corner, and the 13 pt corner of the prompt bubble, request form and message box. A Pretty view takes its sizes from there and its inks from `Palette` and `Term`.

It allows four departures from the rules above, inside the Pretty transcript only:

| Rule elsewhere | In the Pretty transcript |
|---|---|
| No corner rounder than 2 pt | Pretty constants in `PrettyMetrics`: 9 pt for the activity list, 5 pt for tags and wells. The prompt bubble, code and raw blocks keep their corners. |
| Data, states, counts, labels and actions are monospaced | Activity sentences and field labels use the system face. IDs, paths, commands, elapsed time and state tags stay monospaced. |
| Activity lines are never collapsed behind a count | Finished calls fold into one summary line. The items listed under "Never collapsed" stay in the open. |
| A status word on every row | Plain success shows no status word; the past tense says it. A tag shows only for another state. |

**Sentences.** Each tool call is one sentence in the agent's turn: a present participle while it runs, past tense when it is done, "Couldn't …" with the reason when it fails. Each sentence has a fallback that needs no argument. Nothing is inferred: a value comes from the call, its result, or the run record by exact ID.

**Grouping.** Consecutive finished calls in one turn fold into a summary line in secondary ink, one phrase per kind in order of first appearance ("Ran 3 commands, read 2 files"), at most three phrases, then "and N more steps". A group of one is its sentence alone. Groups start closed on every surface. Identical consecutive calls with the same outcome are one line with a count tag. A failed call is drawn under the group it follows and ends that group; the summary ends with "N blocked" or "N failed" in failure ink. Open state is kept per console by the first call's ID. In the PiP an open group shows its first and latest three lines, then "Show all N". The PiP chooses what it shows from the grouped conversation of the asking worker's current turn (everything after the developer's latest prompt), never from a count of raw entries (`ActivityConversation.recent`): the latest group that holds a call, and everything after it as it is; before it, every failure of the turn as its failure line, without that group's finished calls; the turn's latest report when none follows; a pending question's line and a live line. A call awaiting approval and the request's own story are kept from any turn. A turn with no group yet shows its latest four items. Earlier turns are left out, so a closed turn never crowds the latest work. Console and Terminal in the PiP keep the worker's four most recent entries. The running call is a live line, inline in the transcript. It shows its elapsed time, ticking each second in the Thinking line's format, only when the call's stored record holds a start time and the worker is active over a live connection (`PrettyLive.callStart`); otherwise it shows no time, never a client-side guess. A value a sentence names (a path, command, pattern or URL) comes from the stored details first, then the call's own text, and keeps its full length until the sentence shortens it. A result with no recorded call is named as its tool only when a stored record has its exact tool call ID. A task checklist is an inline card at the point the plan was sent, updated in place: one per turn, at its first plan event. An ACP plan event reads only the record the service kept from that same console event, matched by the event's sequence; it is never matched by order or count. The card shows the turn's latest event: its items, "The plan is empty." for a record with no items, or the line "Updated the plan: N items" when that event has no record, never an earlier list. Usage, mode, session rows and thinking fold into the group.

**Thinking.** While the agent thinks, the live line reads "Thinking 1m 52s ›": spinner, the word, the elapsed time in the terminal face, a chevron. It is closed by default and opens in place to the thought text, in italic beside a rule, as it streams. When it ends it reads "Thought for 1m 52s", folds into the group and opens to the full text. The time shows only when the record holds a start time (and an end time, once done); otherwise the line reads "Thinking" or "Thought", never a client-side guess. With no thought text from the provider the row has no chevron and is not a button. Disconnected from the service: a hollow dot, "Last known: thinking", no timer. An opened thought clamps to its latest six lines on the wall tile and three in the PiP, with "Show all". VoiceOver reads the line once, with "Collapsed" or "Expanded", and does not announce the time on every tick or the text as it streams.

**Keyboard.** A line that opens (an activity line, a group's summary, a failure line, Thinking or Thought with text) is one native button and one stop in the Tab order when macOS Keyboard navigation is on. While it holds keyboard focus it draws the inset focus ring: 2 pt of `focus` inside the line's own edge, with the 5 pt tag corner, or the 9 pt list corner on a failure line. The ring changes no layout and replaces the system ring, which did not show round a line. Space or Return toggles it, Right opens it and Left closes it. Option-click on a summary opens the group and every step that opens: each line in the list, the lines the PiP holds behind "Show all", and the failed and blocked lines beneath it. Option-click on an open group closes them all. A line that does not open keeps no open state. The summary reads Option from the click's own event (`PrettySummaryPress`), so a plain click toggles the group alone. Its keys and its accessibility press have their own handlers and toggle the group alone. The four share one modifier (`prettyDisclosureKeys`), which sets focus before it hears the arrow keys. A line that does not open is text and takes no stop.

**Scroll.** A conversation opens at its latest content; a short one sits at the top of its column. While the reader is at the end, new content keeps the end in view. Once they scroll up, the view stays where it is until they return to the end (`PrettyScrollEnd`).

**Never collapsed.** A failed or blocked call, with its reason. A pending question or permission request, in the request form. A reported result, drawn as quoted prose: in full, or its first four lines with "Show all" when a closing message follows it. A plan checklist. A warning, harness stderr or a permission notice.

**Failure words.** The tag is `Blocked` or `Failed`. A denial Commander recognises reads in short plain words from one fixed table ("Claude Code is in don't-ask mode."). A shell command the provider ended at its time limit reads `Failed`, "Timed out.", matched only on Claude Code's whole result: the line "Exit code 143", then the line "Command timed out after" and a duration. Claude Code's Read of a missing file shows the diagnostic inside the fence ("File does not exist."). The result must consist of the service's failure line, an opening bare fence, the diagnostic, and the closing fence. Its note for the agent stays in the rest of the message, and Source keeps the fences. Any other error shows the provider's first sentence. The exact text is one click away.

**State tags.** Monospaced, beside the sentence: `accepted`, `starting`, `running`, `waiting`, `partial`, `uncertain`, `cancelled`, `Blocked`, `Failed`. `Blocked` means the provider refused permission and the tool never ran. A delegation, follow-up, stop, interrupt, integration or submit says what was asked; its tag is the run record's state, and `accepted` when the run record says nothing yet.

**Background work.** A job that goes on after its call returns (a delegated worker, a follow-up or queued message, a stop or interrupt, a pending question, an integration, a network submit) keeps its past-tense line where the call happened and also gets a line in a stack at the bottom of the transcript, above the live line. Running: the name, then the child's own live sentence ("**tracer**: Reading `runner.go`"), with a spinner. Finished: "**reader** finished", linking to that worker, until the next prompt. Failed: a failure line with its reason; it never collapses and is never counted away. A spinner needs a record that says running, read by exact ID, over a live connection; otherwise a hollow dot and "last known …". Disconnected from the service: one line says so, and no spinner or timer shows. Up to three running lines, then "and N more running"; the wall tile shows two; the PiP shows every failure and one count line. A line opens in place to the child's latest group, any failure and its live line, then "Open tracer". Elapsed time shows only where the record holds a start time. The older Claude runner's background commands and child agents are read from its `job` records, each joined to its call by exact `tool_use_id`: the line is the provider's own description ("Watch the build"), followed by the child's open call when the record names one, and counts from the record's `started_at`. State `unknown` means the stream ended while the job ran: a hollow dot and "lost contact. Last known: running." The original call returning is never read as the job ending. A child's live sentence is the child's own: a Commander tool reads as its table A sentence ("**asker**: Waiting for a reply"). A job opens to its exit summary. A console draws its stack on every surface, with or without an ACP session. Not built: a line for an ACP child session or a network submit. Full rules: spec section G.

As built, where the spec leaves a case open:

- A job comes from a Commander call in this console that returned or named an exact ID (a delegation's worker, a follow-up's message, a stop's worker, an integration). A delegated worker's question is read from the run's requests by that worker's ID. The run must hold the record, or there is no line.
- A finished, stopped or cancelled job shows while its call is after the console's last prompt. The records hold no end time.
- A lost-contact line reads "**builder**: lost contact with its host." The record does not keep the state before the loss, so no "Last known" follows.
- A queued follow-up has an attention dot and is not counted as running. The PiP's count line names it: "4 running, 1 queued, 1 needs you".
- A worker state the table does not name (`idle`) reads as sent, "**tracer** is idle", with a solid dot, and follows the finish rule.
- A worker waiting on its pending question has the question's line only.
- On a wall tile the count line also stands for the lost-contact and finished lines: "and 5 more". It reads "and N more running" only when every folded job is running.
- A network submit has no line: the app holds its receipt only inside a call's result, which is not a live record.

**JSON is pretty-printed.** Wherever JSON text shows (Source, or output that is JSON), it is indented two spaces, one property per line, keys in the order sent. It is never shown as a one-line string. Copy keeps the exact original text.

**Typed results.** An opened line draws its call and result by their properties: words, labelled fields, lists, tables, and a lamp with a word. A renderer is chosen by the result's shape, with a generic renderer for any other object or list. A state names its origin: "when this call returned" or "now, from the run record". Properties a renderer does not place are listed under "More fields". The wire name, tool ID and exact text sit behind one quiet Source action, closed by default. No raw JSON shows by default.

**The frame.** The run status line, the prompt bubble, the request form and the message box take the same language. The status line is one quiet line: harness chip, lamp and word, counts as a sentence, the short session ID. The request form is a bordered block in the transcript: who asks, the question as prose, choices as buttons, then a reply field. It still answers by exact request ID, keeps one form per request, and in an offline, held, closed or sending state stays visible, disables input and says why. The message box is the follow-up composer with a rounded field; while a turn runs it queues the message ("⌘↩ queues it") and offers Stop, which interrupts the turn and keeps the conversation.

**Hidden secrets.** With "Hide values that look like secrets" on, a value under a secret-looking key (`token`, `secret`, `password`, `authorization`, `cookie`, `credential`, `api_key`, `private_key`; not `idempotency_key`) or in a known form (`Bearer …`, `sk-…`, a JWT) reads "Hidden, N characters" with Reveal. This is applied when a value is drawn, in the typed view and in Source. Copy is disabled until Reveal. The stored record is unchanged. A background job's texts from its `job` record follow the same setting. They are masked whole before anything is cut from them: the description, the child's open call, and the exit summary a failed job's first sentence comes from. So the line, its VoiceOver label and its announcement never hold the value. In prose the value joined to a secret-looking key is hidden too (`API_TOKEN=…`, `--password=…`). A finished job's opened exit summary (`SecretText`) shows the masked text, then "N values hidden" and Reveal, as Source does; with nothing hidden it is plain text. Reveal holds for the text it was pressed on: a changed summary draws hidden again. A failed job's opened line adds no text from the record, so it has no Reveal. The app reads the saved setting when the service first answers and when a transcript is first drawn. Until the service in use has answered, at launch and after a change of host, a job's texts are drawn hidden.

**What is kept.** The service keeps full tool arguments, descriptions, plan items, start times, and a start and end time for each thought. Settings › Transcript offers "Keep everything as sent" (the default), "Hide values that look like secrets" and "Limit large values", with these fixed limits in every case: a single argument, result or content value is capped at 512 KB, and each worker keeps its latest 256 records or 16 MB; older records are dropped. One warning line under the default says: secrets an agent passes to a tool are stored and shown on every surface, including the PiP.

**A turn that waits for a reply.** A worker that asked the developer a question and waits for the reply inside its turn reads needs-input while the service still calls it working. Its turn is running: the open call's live line keeps its spinner, and the message box queues and offers Stop under the interrupt rule. Nothing is inferred after the open call. A worker the service calls waiting, finished or disconnected is unchanged.

**Edge cases.** The spec's section H covers every other record seen in agent transcripts and ACP. Built, for the older Claude runner's records:

- **End-of-turn line** (`PrettyTurnEndLine`), from `turn_end` records: "Worked for 3m 12s" in secondary ink, or why the turn stopped. "Stopped: reached the output limit", "Stopped: reached the request limit for one turn" and "The model declined to continue" are in attention ink; "This turn was cancelled" and "Stopped" (an error with no named reason) in secondary ink. `end_turn` has no words of its own. One line per turn: a stop reason wins over a duration, and the duration is the turn's own result, not a later result that reports a finished background task. Never folded.
- **Placement.** A `turn_end` or `thought` record sits after the last console event at or before its sequence. A message's sequence is in its ID; a tool call's is in its stored record. When the next entry's sequence is not known, the record is left out. A thought whose record holds its end is a line ("Thought for 12s"), never the live Thinking row.
- **Provider tool sentences**: "Loaded tools", "Sent **tracer** a message", "Started a child agent: …", "Started watching: …" and "Scheduled "…"" with an `accepted` tag, "Waited", "Ran `command`" for `exec`, "Ran a script" for `js`. A tool is matched on its whole name, so an extension's `wait` keeps "Used `wait`".
- **Question card** (`PrettyChoiceCard`): a provider's own question while it waits, with each option and its description, a square mark when several may be chosen. Commander does not answer this tool, so the card is read-only and ends "Answer this in the terminal." Answered, it is the line "Asked: "…"".
- **Plan document** (`PrettyPlanDocument`): "Proposed a plan" with an `approved` tag once the call returns, then the plan as Markdown beside the report block's rule. Clamped on a tile and the PiP. While a permission request holds the call, the approval line stays ("Needs your approval to use `ExitPlanMode`") and the same document sits under it, above the request form's choices, so the plan is read before the decision. The permission and the call must agree: the document shows only when the selected pending permission names a tool call by ID and exactly one open call of this worker has that ID (`RequestPresentation.exactApprovalToolID`), however many other calls are open. The text is the record this worker keeps under that call's own ID (`PrettyToolInput.pendingPlan`): never another worker's call with the same ID, another call, or the latest plan. A permission whose ID matches no open call, or more than one, marks no call. A request that names no call keeps the approval line on the one open call, with no document. With no usable plan stored, the approval line and the form stand alone.
- **Deliverable card** (`PrettyDeliverableCard`): "Published **title**" or "Sent you **file**", then a row per file with its name, kind and Open. An artifact's Open uses the one address in that call's own result; with none or several there is no Open. Never folded.
- **Known failures**, matched only on phrases from real results: a user's decline ("You declined this."), a hook ("A hook blocked this."), a Claude Code safety check, the auto mode classifier, a denied tool and an ungranted write are `Blocked`; a call the session ended on is `cancelled`, "Interrupted." A timeout has no real phrase yet and keeps the provider's first sentence.

Not built, all ACP: the Change, Terminal output and location renderers for tool content, the tool `kind` verbs, content blocks (image, audio, resource), permission option kinds, the elicitation restyle, plan update and removal, notices, the compaction divider, the session message line, suggestion chips and the gap row. Also not built: "You chose: …" under an answered question, the API error line, hook message lines, and Approve and Reject on the plan document. A case with no data shows its fallback, never a guess.

**Type and colour.** `body` for prose and sentences; secondary ink for summaries and finished sentences; `failure` ink for a failed or blocked sentence; the terminal face for values. No new colours.

**Components.** Atoms: `ActivityTagView`, `ActivityChevron`, `PrettySpinner`, `StatusLamp`, `IDChip`, `PathText`. Molecules: `ActivitySentenceText`, `ActivityLine`, `ActivityGroupSummary`, `ActivityFailureLine`, `PrettyReportBlock`, `PrettyLiveLine`, `PrettyThoughtBody`, `PrettyPlanCard`, `PrettyClamp`, `PrettyTurnEndLine`, `PrettyChoiceCard`, `PrettyPlanDocument`, `PrettyDeliverableCard`, `ResultFieldList`, `ResultRecordTable`, `ResultQuote`, `ResultWell`, `ResultEmptyState`, `ResultTruncationBanner`, `SecretValue`, `SecretText`, `ResultDisclosure`, `ResultSourceDisclosure`, `PrettyQueuedMessage`, `PrettyComposer`, `PrettyFormButtonStyle`. Organisms: `ActivityGroupView`, `ActivityResultView`, `PrettyToolCardView`, `TranscriptSettingsSection`. They replace `ActivityStoryCard`, `ActivityStoryHeader`, `ActivityToolDetails`, `PrettyActivityRun`, `PrettyThinkingRow` and `PrettyRunningIndicator`, which are removed. `ActivityMilestoneTimeline`, `ActivityRelationList` and `ActivityActionGroup` stay, inside an opened line. Background work adds the molecules `BackgroundJobLine`, `BackgroundMark`, `PrettyElapsedText` and `PrettyLinkButton`, and the organism `BackgroundStack`; its values are `BackgroundJob` and `BackgroundStackLayout`. The honesty rules in `ActivityStory.swift` stay.

### Quiet theme, "Two speeds" (approved target, not yet built)

Approved on 2026-11-26 as option C of the [app restyle proposal](design/mockups/app-restyle.md); [mockup](design/mockups/app-restyle.html). Nothing is in `tokens.json` or Swift. It is a third theme, working name `quiet`, beside Console and Black glass. **Console stays the default until the user decides otherwise** (rollout step 7). Every rule elsewhere in this document still governs Console, Black glass and everything built today. The values below are proposed, and the contrast of the new inks is not measured: measure it in step 1 and adjust before building views.

**The rule.** A surface is for reading or for scanning, and each gets what it needs. Both share one type scale and one corner set.

| Speed | Surfaces | Treatment |
|---|---|---|
| Reading | Transcripts (wall tile body, focused worker, PiP), Needs-you requests, page headers, forms in Setup, Hosts and Harnesses | No boxes round regions. One surface step, space between groups, prose in the system face |
| Scanning | Data tables, the board, claims, the wall grid, the sidebar's rows, the tray | Columns and row height stay. Hairline row rules stay. Mono for values |

**Foundations (proposed).**

| Token | `quiet` value |
|---|---|
| Type, system face | `pageTitle` 20 semibold, `body` 13, `control` 13 medium, `label` 12, transcript 14. Words are in sentence case: no uppercase, no tracking |
| Type, mono | 12 for values a person would copy (IDs, paths, branches, commands, times, counts in a table); 12.5 in the terminal well |
| Colour | `window` `#16171B`, content surface (`panel`) `#1D1E23`, `well` `#101114`, `foreground` `#ECEDF1`, `secondary` `#A6A9B4`, `hair` white at 8%. `focus`, `working`, `attention` and `failure` are unchanged |
| `tertiary` (new role, all three themes) | `#7E818C` in `quiet`: crumbs, group names, quiet counts. Console and Black glass need a value for it in step 1 |
| Corners | 12 pt tile and panel, 7 pt control, 5 pt chip, 13 pt bubble, 8 pt mode-rail cell and board card |
| Spacing | The existing scale (4, 8, 12, 16, 24, 32). Page gutter 24, row padding 9 |
| Dividers | A hairline between table rows, under a tab bar and round a wall tile. None round regions |
| Status lamp | A 7 pt dot plus the word in `body`. Chips are in secondary ink; colour is reserved for state. The spinner is unchanged |
| Motion | Durations unchanged. A disclosure chevron turns 90° in `fast`. Only the spinner and a countdown move by themselves |

**By surface.**

| Surface | Changes | Stays |
|---|---|---|
| Mode rail | 28 pt cells, 8 pt corners, a soft `focus` wash on the selected cell, no cell borders | Hot counts, ⌘ numbers, the leading marker for VoiceOver |
| Sidebar | No rules between groups; group names in 12 pt `tertiary`; the selected row is a wash with 7 pt corners | Counts (mono), place marks, 28 pt rows |
| Page header | Sentence-case crumb in `tertiary`; 20 pt title; the readout is figures in a line, without cells; facts read as one sentence with mono values | The same figures and their tones |
| Tabs | Text tabs on one hairline, 2 pt `focus` under the selected one | Counts, ⌘ numbers |
| Data tables, board, claims | System face for names, mono for values, sentence-case headers, row rules at 8% | Columns, row height, selection, inline confirms |
| Coordinator wall | Tiles on the content surface, 12 pt corners, one hairline edge. Header: name, harness chip, lamp and word. Body: the Pretty transcript. Footer: the ownership line | Group nesting, tile controls, the attention edge |
| Focused worker | Transcript column 760 pt wide; status line, request form and message box as in the Pretty section | Mode switch, source inspector, record fields |
| PiP | The same parts at 11.5 pt: latest group, every failure of the current turn, request block, live line | Exact conversation height, arrival motion, attention edge |
| Needs-you | Each item is the request block; queue order as a quiet count | Routing by exact request ID, keyboard next and previous |
| Setup, Hosts, Harnesses | Forms as labelled lines without band boxes; one primary button per page; install and sign-in output in a terminal well | Field boxes, the secret field, state labels, confirm wells |
| Network and Teams pages | As the tables and page header above; board cards get 8 pt corners and keep the 2 pt state rule | Badges, claims, holder cues, inline confirms |
| Tray | Last, and the type change only. It keeps its grid | Everything else |

**Kept, because it carries meaning.** A lamp plus a word for every state. Harness and model chips, server swatches, avatars. Ownership cues (who holds input). `attention` means "needs you" and nothing else. One primary action per region, `danger` for a destructive one. Native controls, focus rings, ⌘ shortcuts and VoiceOver labels. The Reduce Motion, Reduce Transparency and Increase Contrast overrides. Mono for real data and the terminal. Row rules on scanned surfaces.

**Not copied.** Anthropic's typeface, the Claude mark, their spinner glyph and their window layout. Orange is not a brand accent: `harness.claude` stays as the Claude harness's identity only. The target is the reading quality, drawn with the system face and this app's inks.

**Console mode and Terminal mode.** Console mode's rendering does not change. In Terminal mode the provider's output does not change and cannot: the TUI's layout, boxes, glyphs, wording and 24-bit colours are the provider's, so the well cannot be re-laid out or made to read like a conversation. This approval does cover the Terminal well and its frame: mono 12.5, more padding, the `quiet` `well` ground and default ink, the title bar and status line, and the 16 ANSI colours matched to the theme. Two things are unverified in the pinned SwiftTerm: setting the ANSI palette, and setting line height. Check both in step 5; drop whichever is unsupported.

**The Pretty transcript under `quiet`.** Its rules above apply unchanged in all three themes, and it keeps its own `Palette` and `Term` roles. `quiet` changes the frame round it: the tile, the 760 pt column, the ground. Open question, to settle before step 4: Pretty says `body` (13 pt) and "no new colours", while `quiet` proposes a 14 pt transcript on a lifted ground. Until the user decides, build Pretty at 13 pt with its own inks, and check those inks on `#1D1E23`.

**Rollout.** Each step compares captures with the demo images, and Console and Black glass must come out unchanged.

1. Add the third `ThemeID` with the values above. Add `tertiary` and the lamp-with-body-type status mark to all three themes. Find any view that branches on a theme. No view changes. Check: `ThemeTests`.
2. Main-window frame: mode rail, sidebar, page header, tabs.
3. Data tables, board, claims, Hosts, Harnesses, setup forms.
4. Wall tile, focused worker frame, PiP, Needs-you, together with the Pretty transcript work. Check against the approved wall and PiP screenshots.
5. Terminal well: size, padding, ground, ANSI colours if supported. Check by reading a real Claude Code and Codex TUI in it.
6. Tray: the type change only.
7. The user decides the default theme. Update this document to describe it and keep Console selectable.

## 4. Layout patterns

- **Header:** title, then a one-line state summary, then a single trailing icon action. On a page, Back names where it returns: the tab the page was opened from (Agents, Network or People), the parent page, or the server.
- **Telemetry strip:** a status strip of readouts directly under the header.
- **Places:** a mode rail and a context column. The rail is 48 pt wide on the `well`, split from the column by a hairline. It holds one 32 pt square cell per mode, each with an 18 pt icon: Agents, Network, People, Teams and Harnesses, with Settings at the foot. A mode cell carries its hot count as a corner count. The selected mode is on `panel` with a 2 pt `focus` leading edge. The context column is 196 pt wide. It shows the mode's title in `title` type with its count, then that mode's places as place rows. The selected place has the 2 pt `focus` leading marker. ⌥⌘1–5 select the modes and ⌥⌘6 opens Settings; ⌘1, ⌘[ and ⌘] keep the coordinator, return and zoom. Needs you is the first place row of the Agents mode, and the Agents mode cell's hot count includes its total. Hosts is the last place of its Workspace group. The toolbar's sidebar button puts the context list away and leaves the rail. Changing mode goes to the mode's first place. On the coordinator wall the selected row is the open run's project, and the breadcrumb is the project, the run, then the zoomed worker.
- **Window toolbar:** the app's name and a breadcrumb at the leading edge; toolbar readouts at the trailing edge. Presence lives in the toolbar presence menu. In the main window the trailing edge reads, in order: the console display menu, adapter updates when there are any, the service state, then the toolbar readouts (servers, host, presence). A breadcrumb of place names is never cut short while the toolbar has room.
- **Body:** stacked bands. Each band has a heading with a count and at most one action, and the band's rows follow.
- **Rows:** mark or avatar (28 pt), or a kind glyph for remote work, then the name, then a metadata line with the swatch edge, then trailing verbs. State words sit right-aligned in tone colour.
- **Footer:** one line of context on the well, then the page's actions.
- **Order of urgency:** what needs the person first ("Needs you"), then live work, then what they own, then what others offer.
- **Needs you order:** a request with under five minutes left comes first whatever its kind; then the person's own stopped workers and signed-out harnesses, longest wait first; then network approvals, soonest end first; then access requests; then friend requests. A decided row keeps its place while its outcome shows.
- **Network pages (main window).** The header's trailing action is the page's one way to start something (Add server, New fan-out, Add friend). Under the telemetry strip the body is a collection beside an inspector: a data table on the left and, at 420 pt on the right, the tray's organism for the chosen row (certificate review, server settings, directory card, approval, grant sheet, hand-off detail, review, profile editor, activity band). Threads and Fan-out turn it round: a narrow list of 340 pt, then the thread or the compare columns in the room that is left. Audit is one full-width table with a server choice and a resource menu beside its heading. In a window too narrow for both, the inspector goes under the collection. A page fits the window at its default 1280 × 800: nothing asks for more width than the window has. In a window narrower than the least a page's bands can take, the bands scroll sideways under the header and telemetry strip; the navigation never leaves the window. Shared offers Revoke… on each grant, with an inline confirm under the row. A row answered a moment ago keeps its place with its outcome (Approved, Denied, Declined, Withdrawn) in place of its verbs, and is no longer counted.
- **Harnesses pages (main window).** The header's title is "Harnesses", its line is the tally ("6 installed, 1 needs sign-in, 5 available.") and its trailing action is Refresh. The body is the harness list beside the harness detail at 420 pt. The list keeps 392 pt at least; in a window too narrow for both, the detail goes under it.
- **Teams pages (main window).** Teams has two groups in the context list: Workspaces, one place per workspace with its live claims as its count, and Team tools: Groups, Hosts, Knowledge, Directory and, for an admin of at least one server, Admin. A workspace page is the header with the goal, the telemetry strip, the facts line, the band tabs, then the chosen band. Board, Integration and Claims are a collection beside an inspector; the Combined view is one full-width table. The team tools are a collection beside an inspector, like the network pages. A form opens in the inspector: where the network model hosts the form (claim, card, queue a branch, share knowledge, run on a host, policy, new workspace), the page shows that host with `scrolls: false`, because the page scrolls; New card and New group are the window's own forms. Every Teams page fits 1280 × 800 and 1440 × 900.
- **Preferences.** Sections stack: a mono heading, a `title`, and a trailing scope note. Appearance comes first and offers one choice card per theme, followed by the line "Consoles, terminals and the pretty view look the same in every theme."

## 5. Behaviour

- **Accessibility.** Every lamp and chip has a spoken label. Readouts speak as one element ("approvals, 2"). Headings carry `.isHeader`.
  - The tab bar is a tab group (`AXTabGroup`, "Sections"). Selected tabs and segments carry `.isSelected` and report the value "Selected".
  - Nothing is offered without a role. A trace row, a finding row and a countdown are each one static text with a full label. A menu field or the presence menu is one element with its value. In a Markdown block a list is a group named for its kind and length ("Numbered list, 3 items") and each item is one static text.
  - Only a tab, a segment or a tally cell reports selected. A banner's icon is not an element: its meaning is spoken with the sentence ("Done: Released card-2.").
  - The page's scroll bar is taken out of the accessibility tree (it is four unnamed buttons otherwise). The scroll area still scrolls for VoiceOver and the keyboard.
  - A code is spoken letter by letter. A QR code is an image with a label; its link is also there as text.
- **Keyboard.** In the tray, places switch with ⌘1, ⌘2, ⌘3. In the main window ⌘1 focuses the coordinator, ⌘] zooms a worker and ⌘[ returns to the wall, so the mode rail takes ⌥⌘1 to ⌥⌘6 (Agents, Network, People, Teams, Harnesses, Settings) and context-list rows have no number key. ⌘N starts a run and ⇧⌘A goes to the next request from any page. Every custom control is reachable by Tab. Every shortcut of the main window is in one table (`CockpitShortcuts`), and no two share a chord. A shortcut records its command and the page runs it from its current state. The window also hears the mode keys itself (`CockpitModeKeys`), before it looks for a key equivalent, so each of ⌥⌘1 to ⌥⌘6 acts whatever else in the window wants the chord.
- **App menu.** The app menu keeps the system items. "Restart Agent Commander" sits directly above "Quit Agent Commander", in the same group, with no shortcut (`AppRestartCommands`). It quits as Quit does, so running assignments keep going, and a detached helper reopens the same bundle once the old process has ended. If the helper can't start, the app beeps and stays open.
- **Copy.** Hashes, IDs and trace text can be selected or copied.
- **Errors.** A failure reads as two sentences: what the tray couldn't do, then the reason the device or relay gave, capitalised and closed with a full stop ("Couldn't claim it. Overlapping claim held by sam/agent."). `MultiplayerSentence.join` writes every one, and drops the "relay HTTP 409:" prefix when a reason follows it.
- **Counts.** A count takes its noun's singular: "1 claim", "3 claims" (`MultiplayerPlural.count`), drawn and spoken.
- **The Hand-offs count.** Hand-offs counts everything you sent that its page lists, hand-offs and reviews together, and its noun is "sent". One value holds it (`NetworkSentTally`), so the navigation's place ("Hand-offs, 3 sent"), the page's heading, the heading's spoken label and the telemetry strip's "hand-offs" and "reviews" readouts say the same rows. Where both kinds are listed the heading adds the split after a colon: "Sent by you, 3: 2 hand-offs, 1 review". With one kind it is the number alone: "Sent by you, 2".
- **Empty and loading.** Use a load note: what is being read, or why it couldn't be. Don't leave a blank region.
- **Refused answers.** When a network answer isn't taken or fails, the row returns to its waiting form and the reason shows in an `error` load note above the list.
- **Revealing.** Something that opens below the fold in answer to a press (an inline confirm) scrolls into view, eased, or at once with Reduce Motion. On a full-size page a view asks with `shellRevealed`: the Revoke confirmation, the grant sheet opened by Review or Share, and every confirmation well. The page (`WorkspacePage`) measures the view in its own column and scrolls itself to the offset that shows it (`PageReveal.offset`), with the page's lower inset as margin. It does not use a reader's `scrollTo`: the bands sit in their own sideways scroll, and `scrollTo` moves that inner scroll view and leaves the page where it is.
- **Live work on the wall.** A local worker is matched to the network by the resource it is shared as. Take back on the dock ends the friend's control at once. A remote worker tile zooms; the band's link, a wall work row and "Open hand-off" go to Hand-offs or Fan-out with that request open.
- **Apply.** Apply never overwrites: a patch runs `git apply` and stages the changes without committing, and a file or report is saved under a new name when its name is taken. The confirmation says so and names the checkout before anything is written. Each artifact shows its own result, and a file saved under another name is named in it ("Saved report.md into relay as report.md.1a2b3c4d.").
- **The wall reads for itself.** While a cockpit wall is on screen (`share.wallAppeared()` until `wallDisappeared()`), hand-offs, who holds control and the reviews and fan-outs sent are read with every panel closed, and read again every 15 seconds. Approvals and access requests are read only while a panel is open.
- **Clocks.** A countdown ticks from the real clock. A fixture, a preview or a headless picture sets `multiplayerFixedNow` in the environment (or passes `now:`), and every countdown below counts from that instant.
- **Harness status is pushed, not polled.** The harness feed (`HarnessFeed`) holds one subscription to the service's harness stream and makes every call (check, sign in, install, settings); the page takes values and emits actions. The window asks for a check when the app comes forward, at most once in 30 seconds, and after a session sheet closes. A setting shows at once and returns to its earlier value if the service refuses it.
- **One service at a time.** The hosts model (`CommanderHostsModel`) owns the host list, the one `agentctl host connect` process, the connection state and the choice; the Hosts page takes values and emits `use` and `refresh`. Choosing a host changes nothing until its forwarded socket answers: the app stays on This Mac while it connects. When the host answers, the runs of the last service leave the window and the wall, Needs you and the adapter notice read the host. While SSH is down the app stays on the host and its service state reads offline from the moment agentctl reports the drop; agentctl retries, and when the same socket answers again both event streams start again at once and the same page comes back. Every long-lived child (the two event streams and `agentctl host connect`) is read on its own handle (`FileHandle.ownChunks`), never through `FileHandle.bytes`, whose one shared reader lets a quiet child hold up all the others. A host whose API the app can't use shows agentctl's detail on its row and the app returns to This Mac. Disconnect and quitting the app end the process, which removes the socket. The choice is not kept between launches: the app starts on This Mac.
- **The window owns what it shows.** The main window's network pages keep their own place: which server, approval, hand-off, thread, audit log or fan-out is open, what was read for it, and every draft. They read and act through the network model's calls that name their target (`loadThread(_:on:)`, `postComment(_:to:on:)`, `revoke(_:on:)` and the like), which never read or move the tray's route. Opening something in the window leaves the tray where it is, and a form open in the tray keeps what was typed. Composers are the network's hosts, shown on the page. A server is removed by value too (`remove(_:)`), after the window's own confirmation: the tray's confirm step is not used and its page stays, unless that page is the removed server's own.
- **Answers wait their turn.** The network model runs one action at a time. An answer (approve, deny, decline, withdraw, accept) pressed while another is in flight is not refused and its verbs are not disabled: it joins a line (`NetworkAnswerQueue`), shows its spinner, and goes when the ones before it have ended. One that waits longer than 20 s is sent anyway, and the model's own sentence says why it wasn't taken.
- **Answers per row.** An answer given on a row (approve, deny, decline, withdraw, accept) comes back for that row alone and shows there as a row outcome. The page's alert band still carries the model's own sentence.
- **Teams in the window.** The window owns its place on the Teams pages (band, card, group, host, item, search, form), its drafts and its reads: each board, pull-request list, version list and reputation it asked for. It acts through the network model's calls that name their target. Those calls ask nothing twice and refresh no list of the window's, so the window asks for the second press itself and reads again after each action. Every delete, remove, release, suspend and revoke waits for a confirmation that names its target. No Teams page reads or moves the tray's route.
- **Held answers.** An approval or access request that was answered stays listed for the network's own hold (2 s), with its outcome in place of its verbs. The window builds its rows from every listed request and the network's word on each, in Approvals and in Needs you, and adds no time of its own. An answered row is not counted and its countdown stops; "Waiting on you", "Access requests", the telemetry strip and the navigation count the same rows.
- **Breadcrumbs.** A crumb names the mode, the mode's section, then the place: "Teams › Workspaces › Relay reconnect", "Teams › Team tools › Hosts". A name is said once, so "Network › Approvals" and "People" have no repeated segment.
- **Sentences wrap.** A band heading's note and a context-list row's name wrap in a narrow window (the row to two lines). A table row's second line wraps where every part of it matters, and the row grows: a knowledge row always shows who shared it and on which server. A sentence is never cut with an ellipsis; only a hash, a path or an ID is truncated, in the middle.
- **Owners by handle.** Where the relay sends a handle beside an owner's ID (`ownerHandle` on a workspace and a knowledge item), the page shows the handle and counts "you shared" by it. The ID shows only when no handle was sent.
- **The server's limit, before the refusal.** The share form's footer says how widely the server lets knowledge travel ("studio lets knowledge reach a group at most."), from the policy for an admin or from what the relay tells every member. A refused share that only says "Forbidden." has the same sentence added when the scope asked for was wider. The network's own share host adds it too, from what it reads of the server (`loadMe`).
- **Opened from the tray.** The panel closes after the request is sent. A tray row that says "Open in Agent Commander" sends a `CommanderOpenRequest` (a place, and optionally a server and an item) to `CommanderWindowRouter.open(_:)`. The cockpit comes forward, reopening if it was closed, and shows the place with the item selected in the window's own state; the tray's route does not move. An item the network no longer lists opens its place alone. A workspace that is gone opens Teams. Watch and Control open the wall zoomed to that worker's remote tile, the same zoom as choosing the tile. A review opens on Hand-offs, as the wall's review row does. A worker with no hand-off tile, or a review that is gone, opens the wall as it is.
  - **A link says where it lands.** `CommanderOpenRequest.landingCrumbs` gives the window's own breadcrumb to the place a request opens when its item exists: "Network › Hand-offs" for a review, "Agents › Workspace › Runs" for Watch and Control, "Teams › Team tools › Hosts" for a host. It reads the place from the router's own mapping and the words from the live navigation, so a label built from it can't name another place than the one that opens. A workspace's label ends at "Teams › Workspaces", because the label doesn't know the workspace's name. A link outside the window takes its words from here and writes none of its own.
- **Local notes.** A note kept on this Mac only (a fan-out's winner) lives in Commander's own folder, keyed by server and request. It is never written to the app's preferences, and a fixture run never writes into the live app's folder.

## 6. Open work

- **Token layers.** Done: `Theme` (`ThemeTokens.swift`) holds both themes' roles, and the tray's atoms, molecules, hosts and wall components read them from `@Environment(\.theme)` ("Tray roles" in section 2). Open:
  - Whether the menu bar tray follows the person's choice. It sets console at its root today; following the choice is one line (`.appTheme()` in place of the fixed theme in `MultiplayerPanel`).
  - The banner and the capability note still take base-palette fills, because no theme role has their console value. Add `success` and `progress` surface roles to `Theme`, then map them.
  - Organisms that set a size in place (`.system(size: 12)` body text, 13 pt titles) keep that size in black glass. Move them to `type` roles a page at a time.
  - Rename the components from `Multiplayer*` to app-wide names once they are shared.
- **Coordinate the files.** `MultiplayerTray.swift` (1,522 lines) and `MultiplayerShareViews.swift` (1,355 lines) need splitting. The tray session is still changing every `Sources/AgentCommander/Multiplayer*.swift` file. Promote shared components only by agreement with that session. Increment 5 also edits `CockpitView.swift`, `Organisms.swift` and `Molecules.swift` to put hand-off cards on the cockpit wall (D8).
- **The wall's frame follows the theme; its controls don't yet.** The pane headings, the worker groups, the remote band and the control dock read the `wall` roles. Still in the earlier look in both themes: the run header above the wall, the "Group by parent" control, the presentation menu and the key hints under the wall. The console tiles keep their own shell and radius by design.
