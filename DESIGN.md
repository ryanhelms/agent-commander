# Agent Commander design

This is the visual language for every Agent Commander surface: the main window, zoom, PiP and the Commander network tray. It is drawn from the network tray's redesign on `claude/commander-network-f774d6`. Implement new and restyled views from this document.

The tray proves the language. The main window adopts it. The console, terminal and pretty view keep their current rendering; the language applies to everything around them.

Sources of truth in code:

| What | Where |
|---|---|
| Base colour tokens | `design/system/tokens.json`, `Palette` in `DesignTokens.swift` |
| Tray role tokens | `MultiplayerTheme` in `MultiplayerTrayComponents.swift` |
| Skin atoms, molecules, motion | `MultiplayerSkin.swift` |
| Tray layout constants | `MultiplayerLayout` in `MultiplayerComponents.swift` |
| Reference mockup | `design/mockups/commander-network-tray.html` |
| Teams components (increment 5) | `MultiplayerTeamsViews.swift`, `MultiplayerMarkdown.swift` |
| Cockpit wall and zoom for remote workers | `MultiplayerWall.swift` |
| Themes | `themes` in `design/system/tokens.json`, `Theme` in `ThemeTokens.swift` |

The app has two themes. **Console** is the language in this document. **Black glass** is the earlier main-window look, kept as an alternative with the same roles. A component reads a role from `@Environment(\.theme)` and never branches on which theme is active. The console, terminal and pretty view read no theme.
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

| Component | What it is |
|---|---|
| Lamp | 9 pt state mark: `on` filled circle, `off` outlined circle, `waiting` open arc, `error` diamond, `unknown` focus ring, `busy` square, `away` half-filled circle, `doNotDisturb` circle with a bar. Live lamps pulse. |
| Tone lamp | Where a view has a tone but no specific state, the lamp follows the tone: working `on`, attention `busy`, failure `error`, focus `unknown`, neutral `off`. |
| Spinner | 12 pt arc turning every 1.1 s. Labelled "In progress". |
| Mark | Square icon tile for a non-person thing: agent, repository, resource. Well fill, border edge, optional tone. |
| Avatar | Round picture, or the initial on the well when there is no picture. |
| Swatch | 4 × 12 pt colour bar. |
| Meter | 16 cells of 5 × 9 pt. Fill is `working`, `attention` at 80% and `failure` at 100%. With `isGood` the bar counts something wanted, such as accepted results, and stays `working` when full. |
| Field box | Sunken well with a 2 pt-radius edge that turns `focus` when focused. |
| Badge | Small outlined label. Tinted when it has a tone. |
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
| Countdown | Time left as a mono figure, ticking each second, over a 56 × 2 pt line that drains linearly. `working`, then `attention` under five minutes. When the full length isn't known, the line drains over the shortest offered length that holds what is left. With Reduce Motion the line steps. |
| Decision row | A request with Deny and Approve (or Decline and Review). The text opens the full review. |
| Link row | Opens a page: what is there, how many, and a chevron. |
| Setting row | Label at a fixed measure, then the control. |
| Well | Sunken block for a value read closely. |
| Choice card | A selectable card: a thumbnail, a round choice mark, the option's name and one line about it. The selected card is filled `selection` with the leading `focus` marker and the word "Selected" in `working`. |
| Theme thumbnail | A small window drawn in one theme's own tokens: its rail, two panels with a state mark, and a primary action. |
| Alert band | Full-width band under the status strip: `failure` at 12% fill with a 45% lower edge, an error lamp and one sentence, such as "Can't reach your Mac". |
| Load note | A lamp and one sentence in a hairline-topped row. The lamp is `waiting` while reading, `error` when the read failed, `off` when empty, and `on` for "Nothing is waiting for you". |
| Outcome well | A well holding a state label ("Approved", "Denied") that replaces a verb strip once its action is done, then fades out. |
| Inline confirm | The second press before something that can't be undone: a well with a `failure` edge, one sentence saying what goes with it, then a keep button and a `danger` button. It arrives under the row it belongs to. The review page's "Post this review" confirmation is the same pattern with an `attention` edge and a primary button, and scrolls into view when it opens. |
| State tally | Counts by state as joined cells that also filter: "open 3, claimed 1, done 4". The chosen cell is filled `focus`; elsewhere a count above zero takes its state's tone. |
| Claim row | Who holds what: a kind badge, the key as mono data, the holder as person and agent, when it lapses, and Release for your own. |
| Card row | One card of a board: its state as a lamp and a word, its title, who has it, and the one step that moves it on. The text opens the card. |
| Queue row | A branch's place in the merge queue as a mono number, the branch, its state, and what stopped it when something did. |
| Output well | The end of a command's or test run's output in mono on a well, selectable, with its exit state. |
| Endorsement chips | Skills people vouch for as `working` badges with a seal, each with "×n" when more than one person did. The first four show, then "+n". |
| Group row | A group: its name, its member count, the first few avatars, and an Owner (`focus`) or Member badge. |
| Markdown block | Text an agent or friend wrote in Markdown, in the tray's type: headings, paragraphs, lists, fenced code on a well, and rules, with bold, italic, inline code and links. Nothing is fetched; an image stays as its source text. |
| Copy chip | A value as data with a copy action: a label cell on the well, the value in mono, and a copy cell that shows a tick once copied. Joined cells on one frame. |
| Device row | A paired device: a mark, its name, "paired … , ends …" in mono, and Revoke (`danger`), which opens an inline confirm. |

### Organisms (in the tray today)

Need row, server row, friend row, activity row, holder row, finding row, control band, remote-work band, sharing band, agent roster, certificate notice, workspaces band, groups band, server teams band, and Remote band.

The pages are watch view, compare (fan-out columns), consult, hand-off composer, hand-off list, hand-off detail, thread, audit, directory, access requests, approval and grant sheet.

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
- **Pages:** groups, group, workspaces, new workspace, workspace (goal, claims, board with a state tally, merge queue), claim, card, queue a branch, hosts, run on host (output well), knowledge library, share knowledge, knowledge item (Markdown block and versions), reputation (meter with `isGood`, endorsement chips), directory search and relay policy. Deleting a group, releasing a claim, suspending a member and the like use the inline confirm.
- **Remote workers on the cockpit wall:** a hand-off runs on a friend's Mac, so the wall shows it as a remote worker tile: the console title bar and harness surface of a local tile, the friend and server as its host, and task, from, via and sent as mono lines in place of a terminal. Up to three tiles sit in a Remote workers band under the local workers: a hairline frame with the 2 pt tile radius and a mono band heading with its count. The band draws nothing until there is a hand-off.
- **Remote worker zoom:** choosing a tile zooms it in the cockpit. The zoom view is a panel with the hand-off's task, target and state, then the tray's watch view (owner and server, Read-only and Signed badges, readouts, trace rows) and a footer with "Open in tray". It reads while it is on screen and never sends. Without a Watch grant it says so in a load note.

Increment 6 (the tray's Remote band, on the Network tab) adds:
- **Remote band:** a band heading with the paired-device count and a switch. Under it a state label (Serving or Off) and one sentence. While serving: the address as a copy chip; the pairing block (QR code of the pairing link beside the code as a copy chip in `figure` type, a countdown over ten minutes, the link as a copy chip, and New code); then device rows. With no code on show, a state label ("No code" or "Code expired") and one primary action, Pair a device.
- **Motion:** the QR code prints once, the block and rows arrive, the countdown drains, and a copy cell ticks. A device that pairs ends the code and the block leaves.

Increment 6 (the Remote web page) adds:
- **Touch scale:** controls are 44 px high, type about 15% larger (body 15, name 15, sub 13.5, heading 13, state 12, figure 17, trace 12.5), and the header icon action is a 52 px full-height cell split off by a hairline.
- **Decision row, phone form:** lamp, title, a countdown on the right, summary, the metadata line with the swatch edge, a 2 px drain line, then Deny (danger) and Approve (primary) as two joined 44 px cells. Under one minute the countdown and line turn `failure`.
- **Pairing steps:** numbered hairline rows on the not-paired screen.
- **Motion:** `arrive` (0.18 s, 6 px travel, ease-out) for new rows and trace lines, `tick` for a changing figure, and a drain line that moves linearly each second. With reduced motion these become fades, and pulses, spinners and the drain stop.

### What the main window reuses

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

- **Header:** title, then a one-line state summary, then a single trailing icon action.
- **Telemetry strip:** a status strip of readouts directly under the header.
- **Places:** a tab bar or a sidebar of places. Each place shows a count.
- **Body:** stacked bands. Each band has a heading with a count and at most one action, and the band's rows follow.
- **Rows:** mark or avatar (28 pt), or a kind glyph for remote work, then the name, then a metadata line with the swatch edge, then trailing verbs. State words sit right-aligned in tone colour.
- **Footer:** one line of context on the well, then the page's actions.
- **Order of urgency:** what needs the person first ("Needs you"), then live work, then what they own, then what others offer.
- **Preferences.** Sections stack: a mono heading, a `title`, and a trailing scope note. Appearance comes first and offers one choice card per theme, followed by the line "Consoles, terminals and the pretty view look the same in every theme."

## 5. Behaviour

- **Accessibility.** Every lamp and chip has a spoken label. Readouts speak as one element ("approvals, 2"). Headings carry `.isHeader`.
  - The tab bar is a tab group (`AXTabGroup`, "Sections"). Selected tabs and segments carry `.isSelected` and report the value "Selected".
  - Nothing is offered without a role. A trace row, a finding row and a countdown are each one static text with a full label. A menu field or the presence menu is one element with its value.
  - The page's scroll bar is taken out of the accessibility tree (it is four unnamed buttons otherwise). The scroll area still scrolls for VoiceOver and the keyboard.
  - A code is spoken letter by letter. A QR code is an image with a label; its link is also there as text.
- **Keyboard.** Places switch with ⌘1, ⌘2, ⌘3 and so on. Every custom control is reachable by Tab.
- **Copy.** Hashes, IDs and trace text can be selected or copied.
- **Empty and loading.** Use a load note: what is being read, or why it couldn't be. Don't leave a blank region.
- **Revealing.** Something that opens below the fold in answer to a press (an inline confirm) scrolls into view, eased, or at once with Reduce Motion.
- **Local notes.** A note kept on this Mac only (a fan-out's winner) lives in Commander's own folder, keyed by server and request. It is never written to the app's preferences, and a fixture run never writes into the live app's folder.

## 6. Open work

- **Unify the token layers.** `Theme` (`ThemeTokens.swift`) now holds both themes' roles, type, radii, spacing and motion, checked against `design/system/tokens.json`. `MultiplayerTheme` reads `Theme.console`, so the tray always draws in the console theme; making the tray follow the person's choice is a separate decision. Rename the components from `Multiplayer*` to app-wide names once they are shared. The design must stay pluggable and themeable: a skin redefines one token layer.
- **Coordinate the files.** `MultiplayerTray.swift` (1,522 lines) and `MultiplayerShareViews.swift` (1,355 lines) need splitting. The tray session is still changing every `Sources/AgentCommander/Multiplayer*.swift` file. Promote shared components only by agreement with that session. Increment 5 also edits `CockpitView.swift`, `Organisms.swift` and `Molecules.swift` to put hand-off cards on the cockpit wall (D8).
- **Bring the wall's own groups to hard lines.** The Remote workers band uses the 2 pt tile radius. The local worker groups beside it still use the main window's older `Radius.group` (15 pt) and `Radius.tile` (13 pt), as do the console tiles inside the band. Restyle them together when the main window adopts this language.
