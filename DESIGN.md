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

Light theme roles (web surface only): `window` `#F5F6F8`, `panel` `#FFFFFF`, `well` `#ECEDF1`, `hair` `#D8DAE1`, `border` `#B3B7C2`, `foreground` `#101116`, `secondary` `#4B4E5A`, `focus` `#1D5BB8`, `working` `#1A7548`, `attention` `#8A5800`, `failure` `#B2362A`, `selection` `#DBE6F7`, `onAccent` `#FFFFFF`. Light swatches are `#16A34A`, `#0284C7`, `#DB2777` and `#65A30D`.

**Swatches** identify a server or harness. They are mint `#4ADE80`, sky `#38BDF8`, pink `#F472B6` and lime `#A3E635`. A server's swatch is chosen by a stable FNV hash of its ID. Show it as a 4 × 12 pt bar beside the name, or as a 2 pt left edge on a row's metadata line.

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

### Motion

| Token | Value | Use |
|---|---|---|
| `fast` | 0.10 s | Hover and press feedback, tab and segment change |
| `standard` | 0.18 s | A row arriving or leaving, a count ticking |
| `slow` | 0.25 s | A meter filling |
| `pulse` | 1.4 s | One beat of a live lamp |
| `travel` | 6 pt | How far an arriving row moves |
| Curve | ease-out only | No spring, no bounce |

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
| Spinner | 12 pt arc turning every 1.1 s. Labelled "In progress". |
| Mark | Square icon tile for a non-person thing: agent, repository, resource. Well fill, border edge, optional tone. |
| Avatar | Round picture, or the initial on the well when there is no picture. |
| Swatch | 4 × 12 pt colour bar. |
| Meter | 16 cells of 5 × 9 pt. Fill is `working`, `attention` at 80% and `failure` at 100%. |
| Field box | Sunken well with a 2 pt-radius edge that turns `focus` when focused. |
| Badge | Small outlined label. Tinted when it has a tone. |
| Signed badge | Marks a result sealed by a pinned device key. |
| Grant badge | An agent row's grant status: Granted is `working` with a check; Offered is outlined. |
| Holder badge | "<handle> has control", `attention` tone with a hand icon. |
| Read-only badge | Marks a watch view the viewer cannot steer. |
| Step mark | Health-check step: round tick, square cross, or its number. |
| Button style | Rectangular and monospaced. `standard` is outlined, `primary` is filled `focus` with `onAccent` ink, `danger` uses failure ink and edge. There is one primary action per region; in a verb strip, one per row. |
| Switch style | Square track: filled `working` when on, outlined when off. |
| Row button style | A plain row with hover tint (6%) and press tint (10%). |

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
| Countdown | Time left, ticking each second, over a line that drains. |
| Decision row | A request with Deny and Approve (or Decline and Review). The text opens the full review. |
| Link row | Opens a page: what is there, how many, and a chevron. |
| Setting row | Label at a fixed measure, then the control. |
| Well | Sunken block for a value read closely. |
| Alert band | Full-width band under the status strip: `failure` at 12% fill with a 45% lower edge, an error lamp and one sentence, such as "Can't reach your Mac". |
| Load note | A lamp and one sentence in a hairline-topped row. The lamp is `waiting` while reading, `error` when the read failed, `off` when empty, and `on` for "Nothing is waiting for you". |
| Outcome well | A well holding a state label ("Approved", "Denied") that replaces a verb strip once its action is done, then fades out. |

### Organisms (in the tray today)

Need row, server row, friend row, activity row, holder row, finding row, control band, remote-work band, sharing band, agent roster, and certificate notice.

The pages are watch view, compare (fan-out columns), consult, hand-off composer, hand-off list, hand-off detail, thread, audit, directory, access requests, approval and grant sheet.

Increment 4 (merged at `341215d`) adds:
- **Control band:** a holder row, a countdown, and Take back.
- **Watch view:** readouts for the worker, line count and last read. A trace with a spinner labelled "every 2 s". Read-only and Signed badges. A suggestion field with a footer note.
- **Review:** a summary, then finding rows with important or nit severity. "Post to PR" has an inline confirmation. A review-request composer.
- **Fan-out:** a composer, and compare columns. "Choose winner" is a standard button; the chosen one shows "Winner" as primary. A footer note says the choice is local only.
- **Live remote work rows:** a leading kind glyph (hand-off ↗, fan-out fork, review list) and a right-aligned state in tone, such as "2 of 2 answered" or "2 important, 1 nit".

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

## 5. Behaviour

- **Accessibility.** Every lamp and chip has a spoken label. Readouts speak as one element ("approvals, 2"). Selected tabs and segments carry `.isSelected`. Headings carry `.isHeader`.
- **Keyboard.** Places switch with ⌘1, ⌘2, ⌘3 and so on. Every custom control is reachable by Tab.
- **Copy.** Hashes, IDs and trace text can be selected or copied.
- **Empty and loading.** Use a load note: what is being read, or why it couldn't be. Don't leave a blank region.

## 6. Open work

- **Unify the token layers.** `MultiplayerTheme` holds the tray's roles, radii, type and motion. `design/system/tokens.json` and `DesignTokens.swift` hold the base palette. Move the theme's roles, type, radii and motion into the shared token layer. Rename the components from `Multiplayer*` to app-wide names once they are shared. The design must stay pluggable and themeable: a skin redefines one token layer.
- **Coordinate the files.** `MultiplayerTray.swift` (1,522 lines) and `MultiplayerShareViews.swift` (1,355 lines) need splitting. The tray session is still changing every `Sources/AgentCommander/Multiplayer*.swift` file. Promote shared components only by agreement with that session. Increment 5 also edits `CockpitView.swift`, `Organisms.swift` and `Molecules.swift` to put hand-off cards on the cockpit wall (D8).
