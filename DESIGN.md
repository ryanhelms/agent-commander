# Agent Commander design

This is the visual language for every Agent Commander surface: the main window, zoom, PiP and the Commander network tray. It is drawn from the network tray's redesign on `claude/commander-network-f774d6`. Implement new and restyled views from this document.

The tray proves the language. The main window adopts it. The console, terminal and pretty view keep their current rendering; the language applies to everything around them.

Sources of truth in code:

| What | Where |
|---|---|
| Base colour tokens | `design/system/tokens.json`, `Palette` in `DesignTokens.swift` |
| Tray role tokens | `MultiplayerTheme` in `MultiplayerTrayComponents.swift`: each token names a role of `Theme` and resolves it where it is drawn |
| Skin atoms, molecules, motion | `MultiplayerSkin.swift` |
| Tray layout constants | `MultiplayerLayout` in `MultiplayerComponents.swift` |
| Reference mockup | `design/mockups/commander-network-tray.html` |
| Teams components (increment 5) | `MultiplayerTeamsViews.swift`, `MultiplayerMarkdown.swift` |
| Cockpit wall and zoom for remote workers | `MultiplayerWall.swift` |
| Themes | `themes` in `design/system/tokens.json`, `Theme` in `ThemeTokens.swift` |
| The wall's frame and its live work | `WallFrame.swift`, `WallLiveWork.swift` |
| Teams pages (main window) | `TeamsPageMolecules.swift`, `TeamsPagesWorkspace.swift`, `TeamsPagesTools.swift`, `TeamsPagesModel.swift`, `TeamsPagesLive.swift` |

The app has two themes. **Console** is the default and the language in this document. **Black glass** is the earlier main-window look, kept as an alternative with the same roles. Console is the default. Black glass is chosen in Settings and kept under `appearance.theme`. A component reads a role from `@Environment(\.theme)` and never branches on which theme is active. The console, terminal and pretty view read no theme.

The tray's components follow the same rule (see "Tray roles" below). Whatever the main window composes from them (a hosted composer, the dock's holder row, the remote worker zoom and group, an inspector's organism) takes the window's theme. The menu bar tray itself sets the console theme at its root (`MultiplayerPanel(model:theme:)`), so it looks the same whichever theme the window uses.
| Remote band (increment 6) | `MultiplayerRemote.swift` |
| Reference renders | `design/demos/increment-2/`, `design/demos/increment-3/`, `design/demos/increment-4/` (after its demo) |

## 1. Direction

An operations console for an agent network.

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
| Setting row | Label at a fixed measure, then the control. |
| Well | Sunken block for a value read closely. |
| Choice card | A selectable card: a thumbnail, a round choice mark, the option's name and one line about it. The selected card is filled `selection` with the leading `focus` marker and the word "Selected" in `working`. |
| Theme thumbnail | A small window drawn in one theme's own tokens: its rail, two panels with a state mark, and a primary action. |
| Place row | A place mark, the title in `body` and a trailing count, 28 pt high. The selected row is filled `selection` with the 2 pt `focus` leading marker. Hover tints it 6%. In the tray each of the first nine rows has a ⌘ number shortcut, named in its tooltip; the main window's context list has none. A place that can be shared (a project) offers Share… in its context menu. |
| Group heading | The group's name in `heading` and secondary ink. A group that folds is a button with a chevron; while folded it shows its hot count beside the name. |
| Mode cell | A 32 pt square cell with an 18 pt icon. The selected cell is filled `selection` with the leading marker. A hot count sits on the top trailing corner at 14 pt. Each cell has a ⌘ number shortcut. |
| Toolbar readouts | A status strip sized for the toolbar: `label` over a `data` value, cells split by hairlines on the well inside one hairline frame. `servers` shows "2/3" with a lamp (`on` when all answer, `busy` and `attention` ink when some do, `error` and `failure` ink when none do) and opens Servers. `presence` shows the lamp and word, has a chevron beside its label and opens the presence choices. | In a window the two are two toolbar items side by side, each on its own hairline frame, so each is its own element: a "servers" button and a "Your presence" menu button whose value is the presence in force ("Auto: Busy"). Drawn without a window they are one strip. The presence control is AppKit's own pull-down button with nothing drawn, laid over the readout (`ShellPresencePullDown`): a menu button named "Your presence" whose value is the presence in force, with a check beside the choice in force.
| Origin cell | Who asks, at a fixed 196 pt so every request starts on one line. A local worker is a 28 pt square mark, its name in `data` and its host in `fingerprint`. A network request is the server's swatch, the friend's round 28 pt avatar, the handle in `data` and the server in `fingerprint`. |
| Kind tag | question, approval, access or friend, as a badge in `label` beside the request's title. |
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
| Device row | A paired device: a mark, its name, "paired … , ends …" in mono, then Rename and Revoke (`danger`). Rename opens a well under the row with a "Device name" field box holding the name, then Cancel and a primary Save name; Return saves and Escape cancels. Revoke opens an inline confirm. One of the two is open at a time, and the row's verbs hide while it is. |

### Main-window molecules and organisms (network pages)

| Component | What it is |
|---|---|
| Data table | Header cells in `label` on the header fill, then hairline rows of 34 pt on one panel. A column has a fixed width or shares what is left; figures and times are mono and right-aligned. The row's cells are one button that selects it (`selection` fill with the leading `focus` marker); its verbs sit after them as a verb strip. With no rows the table shows one note. |
| Person cell | An avatar, the handle in `data`, and under it the server as a swatch and its name. Used where a row is about someone on a server. |
| Row outcome | What takes a row's verb strip after an answer: a spinner while it runs, then a state label "Done" for 2.4 s. The row's second line says what happened in `working`. After a failure the verbs stay and the second line gives the reason in `failure` until the row is tried again. The tray's own form is under "Organisms (in the tray today)". |
| Alert band, page form | The network's last action across the page, under the telemetry strip: a spinner and a sentence on the well while it runs, a lit lamp when it confirmed, the `failure` fill and edge when it failed. Confirmed and failed bands can be dismissed. | The sentence is one static text ("Done: …") and Dismiss is its own button. The band belongs to the page the action was taken on and clears when that page is left.
| Inspector | The panel beside a collection: a title with the server's swatch and name, a state label, a close action, then the content, then a footer on the well with one line of context and the actions. Its content is a tray organism used as it is. With nothing chosen it is one note saying what choosing a row shows. |
| Request inspector | A request with no page of its own (an access request, a friend request), opened by choosing its row: who, what and when as labelled lines, then one `sub` sentence saying what the answers do. |
| Composer panel | A composer opened from a page (Consult, Hand off, Request review, Watch, Add friend, Invite, Membership, Add server): the network's own host in an inspector panel under the telemetry strip and above the page's bands, at up to 540 pt and at its full height, because the page scrolls. Its title names the composer and its server. Cancel, the close action and a finished send put it away; a refusal stays on it. |
| Compare columns, page form | A fan-out's answers side by side, each column as wide as the page allows and 248 pt at least; more than fit scroll sideways. The winner's column is `selection` at 35% with a 2 pt `focus` top edge. |
| People grid | Friends by server on one panel: a header line per server (swatch, name, "2 of 3 online"), then that server's friend rows in as many columns of 248 pt as fit. |

### Main-window molecules and organisms (Teams pages)

| Component | What it is |
|---|---|
| Band tabs | A workspace's bands (Board, Combined view, Integration, Claims) as joined cells on the well, each with its count in its tone. One band shows at a time, so each fits the window. The chosen cell is on `panel` with the 2 pt `focus` lower edge, like a tab. |
| Facts line | Labelled values on one line under the telemetry strip: the label in `label`, the value in `data`. A workspace's repository, base, how it lands and its group. |
| Board columns | Open, Claimed and Done side by side on one panel, divided by hairlines. Each column's heading is its state as a lamp and a word, then its count, on the header fill. A column is 168 pt at least. An empty column says so in `sub`. |
| Board card | Square, on the `well` with a hairline edge and no shadow. A 2 pt leading rule takes the state's tone (`border` while open). The title is in `name` on up to three lines and opens the card. A claimed card carries a holder badge. An open card offers Claim; a card you hold offers Complete… as its primary. The open card is filled `selection` with the `focus` rule. A refused claim says why under the title in `failure`, and the card shows who holds it. |
| Holder badge, claim form | Who holds a claimed card, as person and agent ("sam/sam-codex") with a terminal symbol: `focus` when it is yours, `attention` when it is someone else's. |
| Combined view | A data table of every member's workers for a workspace: the member (avatar, handle, online lamp, once per member), the worker (name, state word, agent chip), what it holds (kind badge and key), its branch in mono, and its checks as a state label ("14 passing", "2 failing", "Running"). A member with no worker has a row that says so. |
| Confirmation well | The second press before something that writes or runs, on the `well` with an `attention` edge: the question in `name`; what it acts on in mono `focus` (a path, a destination); the steps in order when there is an order, numbered because the order is real; the changes as "label: old → new" lines; one `sub` sentence about what happens; then a keep button and a primary button. Nothing happens before the primary button. It scrolls into view when it opens. |
| Merge confirmation | A confirmation well under the queue's Run merge…: "Run the merge queue for Relay launch?", then each queued branch in order with its test command, then what happens to a branch that fails or conflicts. "Don’t run" and a primary "Run merge". |
| Install confirmation | A confirmation well first in the Knowledge inspector. It names the destination: `~/.claude/skills/<name>/SKILL.md` for a skill, the clipboard for a prompt, instructions or a summary, and the chosen file for an MCP item. It names each `${NAME}` placeholder filled from the Keychain. The buttons say what they do: "Install skill", "Copy", "Save to file". |
| Policy confirmation | A confirmation well under the policy form: "Set this policy on studio?", each change as "old → new", and a primary button that names the server. |
| Row panel | The tray's own row organisms (claim, queue and pull request rows) on one panel, ruled off by hairlines, at page width. |
| Policy form, page form | The tray's policy fields in three groups on one panel (Knowledge, Reputation and directory, Limits), without the tray's moderation fields. Used where the window has a member list to moderate from. |
| Member and device rows | In the Admin inspector: an avatar or a mark, the name, a state label (Active, Suspended), then Suspend… or Unsuspend, or Revoke…. Suspend and Revoke open an inline confirm under the row that names the person or device and the server. |

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

Need row, server row, friend row, activity row, holder row, finding row, control band, remote-work band, sharing band, agent roster, certificate notice, workspaces band, groups band, server teams band, and Remote band.

The pages are watch view, compare (fan-out columns), consult, hand-off composer, hand-off list, hand-off detail, thread, audit, directory, access requests, approval and grant sheet.

The hand-off detail shows its state as a state label (lamp plus word, such as "Done") and its Sent and Checked times in `fingerprint`.

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
- **Workspaces band** (Agents tab): the workspaces you work in, each with its goal and a claim count in tone, then link rows to hosts and the knowledge library.
- **Groups band** (People tab): group rows, and one action to manage groups.
- **Server teams band** (server page): link rows into that server's groups, workspaces, hosts, knowledge and, for an admin, policy.
- **Pages:** groups, group, workspaces, new workspace, workspace (goal, claims, board with a state tally, merge queue or pull requests), claim, card, queue a branch, hosts, run on host (output well), knowledge library, share knowledge, knowledge item (Markdown block and versions), reputation (the 16-cell meter with `isGood`, endorsement chips), directory search and relay policy.
- **Second presses:** deleting a group, removing a member, releasing a claim, releasing a card you hold, removing a branch from the merge queue, suspending a member and revoking a device each use the inline confirm. The first button ends in "…" and is disabled while its confirm is open. Leaving the page ends the confirm.
- **Run on host:** the Extra arguments field shows only for a command whose owner allows them (`capabilities.commands[].allowArgs`). For a command that takes none, a note says so and typed arguments are not sent. A host that doesn't publish its commands keeps the field. The command's environment is named under the picker.
- **Pull-request workspace:** a "Pull requests" band in place of the merge queue. Its heading carries the open count and a trailing Repository button that opens the repository's pull-request list. Each open pull request is a pull request row, split by hairlines. The device reads them with the person's own `gh` only as the page opens and when its Refresh is pressed. While reading, the band shows the spinner and "Reading the open pull requests…"; with none open, one `sub` sentence; when the read fails, the reason in `failure` with Try again (a missing or signed-out `gh` says what to check). At the device's limit of 50, a `sub` line points to the repository for the rest.
- **Remote workers on the cockpit wall:** a hand-off runs on a friend's Mac, so the wall shows it as a remote worker tile: the console title bar and harness surface of a local tile, the friend and server as its host, and task, from, via and sent as mono lines in place of a terminal. Up to three tiles sit in the remote band under the local workers (see "The wall's frame"). The band draws nothing until there is a hand-off, a review or a fan-out to show.
- **Remote worker zoom:** choosing a tile zooms it in the cockpit. The zoom view is a panel with the hand-off's task, target and state, then the tray's watch view (owner and server, Read-only and Signed badges, readouts, trace rows) and a footer with one button, "Open in tray" unless the caller titles it or leaves it out (`footerTitle`). It reads while it is on screen. It sends nothing unless the caller allows suggestions (`allowsSuggestion`) and the owner shared Suggest on the worker: then the watch view's suggestion field shows under the trace with the caller's draft, the footer adds a primary "Send suggestion" (⌘Return), and the footer's note says the owner approves each one. Without a Watch grant it says so in a load note. In the main window the bar over it is a wall crumb with a Read-only badge and one standard action, "Open hand-off", which goes to the hand-off on its page; the zoom view then has no footer button of its own, and it takes a suggestion where the owner shared Suggest.

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

## 4. Layout patterns

- **Header:** title, then a one-line state summary, then a single trailing icon action. On a page, Back names where it returns: the tab the page was opened from (Agents, Network or People), the parent page, or the server.
- **Telemetry strip:** a status strip of readouts directly under the header.
- **Places:** a mode rail and a context column. The rail is 48 pt wide on the `well`, split from the column by a hairline. It holds one 32 pt square cell per mode, each with an 18 pt icon: Agents, Network, People and Teams, with Settings at the foot. A mode cell carries its hot count as a corner count. The selected mode is on `panel` with a 2 pt `focus` leading edge. The context column is 196 pt wide. It shows the mode's title in `title` type with its count, then that mode's places as place rows. The selected place has the 2 pt `focus` leading marker. ⌥⌘1–4 select the modes and ⌥⌘5 opens Settings; ⌘1, ⌘[ and ⌘] keep the coordinator, return and zoom. Needs you is the first place row of the Agents mode, and the Agents mode cell's hot count includes its total. The toolbar's sidebar button puts the context list away and leaves the rail. Changing mode goes to the mode's first place. On the coordinator wall the selected row is the open run's project, and the breadcrumb is the project, the run, then the zoomed worker.
- **Window toolbar:** the app's name and a breadcrumb at the leading edge; toolbar readouts at the trailing edge. Presence lives in the toolbar presence menu. In the main window the trailing edge reads, in order: the console display menu, adapter updates when there are any, the service state, then the toolbar readouts. A breadcrumb of place names is never cut short while the toolbar has room.
- **Body:** stacked bands. Each band has a heading with a count and at most one action, and the band's rows follow.
- **Rows:** mark or avatar (28 pt), or a kind glyph for remote work, then the name, then a metadata line with the swatch edge, then trailing verbs. State words sit right-aligned in tone colour.
- **Footer:** one line of context on the well, then the page's actions.
- **Order of urgency:** what needs the person first ("Needs you"), then live work, then what they own, then what others offer.
- **Needs you order:** a request with under five minutes left comes first whatever its kind; then the person's own stopped workers, longest wait first; then network approvals, soonest end first; then access requests; then friend requests. A decided row keeps its place while its outcome shows.
- **Network pages (main window).** The header's trailing action is the page's one way to start something (Add server, New fan-out, Add friend). Under the telemetry strip the body is a collection beside an inspector: a data table on the left and, at 420 pt on the right, the tray's organism for the chosen row (certificate review, server settings, directory card, approval, grant sheet, hand-off detail, review, profile editor, activity band). Threads and Fan-out turn it round: a narrow list of 340 pt, then the thread or the compare columns in the room that is left. Audit is one full-width table with a server choice and a resource menu beside its heading. In a window too narrow for both, the inspector goes under the collection. A page fits the window at its default 1280 × 800: nothing asks for more width than the window has. In a window narrower than the least a page's bands can take, the bands scroll sideways under the header and telemetry strip; the navigation never leaves the window. Shared offers Revoke… on each grant, with an inline confirm under the row. A row answered a moment ago keeps its place with its outcome (Approved, Denied, Declined, Withdrawn) in place of its verbs, and is no longer counted.
- **Teams pages (main window).** Teams has two groups in the context list: Workspaces, one place per workspace with its live claims as its count, and Team tools: Groups, Hosts, Knowledge, Directory and, for an admin of at least one server, Admin. A workspace page is the header with the goal, the telemetry strip, the facts line, the band tabs, then the chosen band. Board, Integration and Claims are a collection beside an inspector; the Combined view is one full-width table. The team tools are a collection beside an inspector, like the network pages. A form opens in the inspector: where the network model hosts the form (claim, card, queue a branch, share knowledge, run on a host, policy, new workspace), the page shows that host with `scrolls: false`, because the page scrolls; New card and New group are the window's own forms. Every Teams page fits 1280 × 800 and 1440 × 900.
- **Preferences.** Sections stack: a mono heading, a `title`, and a trailing scope note. Appearance comes first and offers one choice card per theme, followed by the line "Consoles, terminals and the pretty view look the same in every theme."

## 5. Behaviour

- **Accessibility.** Every lamp and chip has a spoken label. Readouts speak as one element ("approvals, 2"). Headings carry `.isHeader`.
  - The tab bar is a tab group (`AXTabGroup`, "Sections"). Selected tabs and segments carry `.isSelected` and report the value "Selected".
  - Nothing is offered without a role. A trace row, a finding row and a countdown are each one static text with a full label. A menu field or the presence menu is one element with its value. In a Markdown block a list is a group named for its kind and length ("Numbered list, 3 items") and each item is one static text.
  - Only a tab, a segment or a tally cell reports selected. A banner's icon is not an element: its meaning is spoken with the sentence ("Done: Released card-2.").
  - The page's scroll bar is taken out of the accessibility tree (it is four unnamed buttons otherwise). The scroll area still scrolls for VoiceOver and the keyboard.
  - A code is spoken letter by letter. A QR code is an image with a label; its link is also there as text.
- **Keyboard.** In the tray, places switch with ⌘1, ⌘2, ⌘3. In the main window ⌘1 focuses the coordinator, ⌘] zooms a worker and ⌘[ returns to the wall, so the mode rail takes ⌥⌘1 to ⌥⌘5 (Agents, Network, People, Teams, Settings) and context-list rows have no number key. ⌘N starts a run and ⇧⌘A goes to the next request from any page. Every custom control is reachable by Tab. Every shortcut of the main window is in one table (`CockpitShortcuts`), and no two share a chord. A shortcut records its command and the page runs it from its current state. The window also hears the mode keys itself (`CockpitModeKeys`), before it looks for a key equivalent, so each of ⌥⌘1 to ⌥⌘5 acts whatever else in the window wants the chord.
- **Copy.** Hashes, IDs and trace text can be selected or copied.
- **Errors.** A failure reads as two sentences: what the tray couldn't do, then the reason the device or relay gave, capitalised and closed with a full stop ("Couldn't claim it. Overlapping claim held by sam/agent."). `MultiplayerSentence.join` writes every one, and drops the "relay HTTP 409:" prefix when a reason follows it.
- **Counts.** A count takes its noun's singular: "1 claim", "3 claims" (`MultiplayerPlural.count`), drawn and spoken.
- **Empty and loading.** Use a load note: what is being read, or why it couldn't be. Don't leave a blank region.
- **Refused answers.** When a network answer isn't taken or fails, the row returns to its waiting form and the reason shows in an `error` load note above the list.
- **Revealing.** Something that opens below the fold in answer to a press (an inline confirm) scrolls into view, eased, or at once with Reduce Motion. On a full-size page a view asks with `shellRevealed`: the Revoke confirmation, the grant sheet opened by Review or Share, and every confirmation well. The page (`WorkspacePage`) measures the view in its own column and scrolls itself to the offset that shows it (`PageReveal.offset`), with the page's lower inset as margin. It does not use a reader's `scrollTo`: the bands sit in their own sideways scroll, and `scrollTo` moves that inner scroll view and leaves the page where it is.
- **Live work on the wall.** A local worker is matched to the network by the resource it is shared as. Take back on the dock ends the friend's control at once. A remote worker tile zooms; the band's link, a wall work row and "Open hand-off" go to Hand-offs or Fan-out with that request open.
- **Apply.** Apply never overwrites: a patch runs `git apply` and stages the changes without committing, and a file or report is saved under a new name when its name is taken. The confirmation says so and names the checkout before anything is written. Each artifact shows its own result, and a file saved under another name is named in it ("Saved report.md into relay as report.md.1a2b3c4d.").
- **The wall reads for itself.** While a cockpit wall is on screen (`share.wallAppeared()` until `wallDisappeared()`), hand-offs, who holds control and the reviews and fan-outs sent are read with every panel closed, and read again every 15 seconds. Approvals and access requests are read only while a panel is open.
- **Clocks.** A countdown ticks from the real clock. A fixture, a preview or a headless picture sets `multiplayerFixedNow` in the environment (or passes `now:`), and every countdown below counts from that instant.
- **The window owns what it shows.** The main window's network pages keep their own place: which server, approval, hand-off, thread, audit log or fan-out is open, what was read for it, and every draft. They read and act through the network model's calls that name their target (`loadThread(_:on:)`, `postComment(_:to:on:)`, `revoke(_:on:)` and the like), which never read or move the tray's route. Opening something in the window leaves the tray where it is, and a form open in the tray keeps what was typed. Composers are the network's hosts, shown on the page. A server is removed by value too (`remove(_:)`), after the window's own confirmation: the tray's confirm step is not used and its page stays, unless that page is the removed server's own.
- **Answers per row.** An answer given on a row (approve, deny, decline, withdraw, accept) comes back for that row alone and shows there as a row outcome. The page's alert band still carries the model's own sentence.
- **Teams in the window.** The window owns its place on the Teams pages (band, card, group, host, item, search, form), its drafts and its reads: each board, pull-request list, version list and reputation it asked for. It acts through the network model's calls that name their target. Those calls ask nothing twice and refresh no list of the window's, so the window asks for the second press itself and reads again after each action. Every delete, remove, release, suspend and revoke waits for a confirmation that names its target. No Teams page reads or moves the tray's route.
- **Held answers.** An approval or access request that was answered stays listed for the network's own hold (2 s), with its outcome in place of its verbs. The window builds its rows from every listed request and the network's word on each, in Approvals and in Needs you, and adds no time of its own. An answered row is not counted and its countdown stops; "Waiting on you", "Access requests", the telemetry strip and the navigation count the same rows.
- **Opened from the tray.** A tray row that says "Open in Agent Commander" sends a `CommanderOpenRequest` (a place, and optionally a server and an item) to `CommanderWindowRouter.open(_:)`. The cockpit comes forward, reopening if it was closed, and shows the place with the item selected in the window's own state; the tray's route does not move. An item the network no longer lists opens its place alone. A workspace that is gone opens Teams.
- **Local notes.** A note kept on this Mac only (a fan-out's winner) lives in Commander's own folder, keyed by server and request. It is never written to the app's preferences, and a fixture run never writes into the live app's folder.

## 6. Open work

- **Token layers.** Done: `Theme` (`ThemeTokens.swift`) holds both themes' roles, and the tray's atoms, molecules, hosts and wall components read them from `@Environment(\.theme)` ("Tray roles" in section 2). Open:
  - Whether the menu bar tray follows the person's choice. It sets console at its root today; following the choice is one line (`.appTheme()` in place of the fixed theme in `MultiplayerPanel`).
  - The banner and the capability note still take base-palette fills, because no theme role has their console value. Add `success` and `progress` surface roles to `Theme`, then map them.
  - Organisms that set a size in place (`.system(size: 12)` body text, 13 pt titles) keep that size in black glass. Move them to `type` roles a page at a time.
  - Rename the components from `Multiplayer*` to app-wide names once they are shared.
- **Coordinate the files.** `MultiplayerTray.swift` (1,522 lines) and `MultiplayerShareViews.swift` (1,355 lines) need splitting. The tray session is still changing every `Sources/AgentCommander/Multiplayer*.swift` file. Promote shared components only by agreement with that session. Increment 5 also edits `CockpitView.swift`, `Organisms.swift` and `Molecules.swift` to put hand-off cards on the cockpit wall (D8).
- **The wall's frame follows the theme; its controls don't yet.** The pane headings, the worker groups, the remote band and the control dock read the `wall` roles. Still in the earlier look in both themes: the run header above the wall, the "Group by parent" control, the presentation menu and the key hints under the wall. The console tiles keep their own shell and radius by design.
