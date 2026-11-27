# App restyle toward the conversation language: proposal

**Option C was chosen on 2026-11-26** and is being recorded in DESIGN.md as an approved target. Nothing is in tokens.json or Swift. Mockup: [app-restyle.html](app-restyle.html). The Pretty transcript itself is already approved in DESIGN.md ("Pretty transcript"); this covers everything else.

**Recommendation:** option C, built as a third theme beside Console and Black glass, so nothing ships until each surface has been compared.

## What the current language costs, and what the target does instead

Measured against the Console theme (`Theme.console` in `ThemeTokens.swift`) and the capture `design/demos/main-window-6/fit-1280-teams-workspace-console.png`.

| Today | Cost to the reader | Target |
|---|---|---|
| Mono for headings, labels, states, counts and buttons (`heading` 11.5, `state` 10.5, `label` 9.5, `control` 12) | Words set in mono at 9.5 to 11.5 pt read slowly; real data (a branch, an ID) no longer stands out, because everything looks like data | System face for words. Mono only for values a person would copy: IDs, paths, branches, commands, times, counts in a table |
| Uppercase crumbs and lowercase mono labels | Two label styles, both low in legibility | Sentence case throughout |
| A border round every region; joined cells; 2 pt corners | Every edge has the same weight, so nothing leads the eye | One surface step for the content area, hairlines only between scanned rows, space between groups |
| State words in coloured mono, plus coloured chips | Five inks compete on one row | Lamp and word in body type; chips in secondary ink; colour reserved for state |
| 11 to 13 pt body on `#090A0D` | Small type on near-black with bright rules is tiring in long sessions | 13 pt body, 14 pt in transcripts, on a slightly lifted ground with softer rules |

## What to keep, because it carries meaning

| Keep | Why |
|---|---|
| Lamp plus word for every state | Colour is never the only signal |
| Harness and model chips, server swatches, avatars | Identity at a glance on the wall |
| Ownership cues ("Input: Retry policy", who holds input) | Says who may type |
| Attention ink means "needs you" and nothing else | The PiP and Needs-you depend on it |
| One primary action per region; `danger` for destructive | Existing rule, unchanged |
| Native controls, focus rings, ⌘ shortcuts, VoiceOver labels | Behaviour, not style |
| Reduce Motion, Reduce Transparency, Increase Contrast overrides | Already in tokens |
| Mono for real data and the terminal | It is data |
| Row rules in data tables, the board and the wall grid | Scanned surfaces need alignment |

## What not to copy

Anthropic's typeface, the Claude mark, the orange accent as a brand colour (`harness.claude` stays, as the Claude harness's identity only), their spinner glyph, and their window layout. The target is the reading quality, drawn with the system face and this app's own inks.

## Three options

| | A. Quiet console | B. Conversation everywhere | C. Two speeds (recommended) |
|---|---|---|---|
| Idea | Keep every grid and box; change type only | Drop rules and boxes on every surface | Conversation language where people read; row rules stay where people scan |
| Type | System face for words, sizes up one step | Same as C | System 13 body, 12 labels, 20 page title; mono 12 for values |
| Corners | 2 pt (unchanged) | 12 pt surfaces, 8 pt controls | 12 pt tiles and panels, 7 pt controls, 5 pt chips |
| Dividers | Unchanged | None; space only | Hairline at 8% white between table rows and under tab bars; none round regions |
| Ground | Unchanged | One flat surface | Window `#16171B`, content `#1D1E23`, well `#101114` (proposed) |
| Cost | Small: token values in `Theme.console` | Large; dense tables and the wall lose alignment | Medium: a third theme plus a few role additions |
| Risk | Still reads as boxed and busy | Twenty workers on a wall become hard to scan | Two rule sets to keep apart; stated per surface below |
| Gain | Legibility of labels | Closest to the screenshots | Most of B's calm where it matters, none of its scanning loss |

Why C: the screenshots the user likes are a single reading column. The app also has surfaces a reader scans, not reads: the combined view, the board, claims, the wall. Those need rules and columns. C gives each what it needs and uses one type scale and one corner set for both.

## Option C by surface

| Surface | Change | Stays |
|---|---|---|
| Mode rail | 28 pt cells with 8 pt corners; selected cell is a soft `focus` wash; no cell borders | Hot counts, ⌘ numbers, leading marker for VoiceOver |
| Sidebar | No rules between groups; group names in 12 pt tertiary ink; selected row is a 7 pt-corner wash | Counts (mono), place marks, row height 28 pt |
| Page header | Sentence-case crumb in tertiary ink; 20 pt title; readout strip becomes figures in a line, no cells; facts ("repository", "base") as one sentence with mono values | The same figures and their tones |
| Tabs | Text tabs on one hairline, 2 pt `focus` under the selected one | Counts, ⌘ numbers |
| Data tables, board, claims | System face for names, mono for values, header labels in sentence case, row rules at 8% | Columns, row height, selection behaviour, inline confirms |
| Coordinator wall | Tiles on the content ground with 12 pt corners and one hairline edge; header is name, harness chip, lamp and word; body is the Pretty transcript (summary lines, prose, request block); footer keeps the ownership line | Group nesting, tile controls, attention edge on a tile that needs you |
| Focused worker | Transcript column at 760 pt reading width; status line, request form and message box as in the Pretty section | Mode switch, source inspector, record fields |
| PiP | Same parts at 11.5 pt: latest group, any failure, request block, live line | Exact conversation height, arrival motion, attention edge |
| Needs-you | Each item is the request block (who asks, question, choices); queue order in a quiet count | Routing by exact request ID, keyboard next/previous |
| Setup, Hosts, Harnesses | Forms as labelled lines without band boxes; one primary button per page; install and sign-in output in a terminal well | Field boxes, secret field, state labels, confirm wells |
| Network and Teams pages | As data tables and page header above; cards on the board get 8 pt corners and keep the 2 pt state rule | Badges, claims, holder cues, inline confirms |
| Tray | Last. It proved the Console language and is a dense, glanceable surface: adopt the type change only (option A) and keep its grid | Everything else |

| Foundation | Proposed |
|---|---|
| Type | System: 20 semibold title, 13 body, 13 medium control, 12 label, 14 transcript. Mono: 12 values, 12.5 terminal. No uppercase, no tracking |
| Colour | Foreground `#ECEDF1`, secondary `#A6A9B4`, tertiary `#7E818C` (new role), hair 8% white. `focus`, `working`, `attention`, `failure` unchanged |
| Corners | 12 tile and panel, 7 control, 5 chip, 13 bubble |
| Spacing | Existing scale (4, 8, 12, 16, 24, 32). Page gutter 24, row padding 9 |
| Status lamps | 7 pt dot plus the word in body type. Spinner unchanged |
| Motion | Unchanged durations. Disclosure chevron turns 90° in `fast`; nothing animates by itself except the spinner and the countdown |

## Terminal and Console modes: what is possible

Checked in the code:

| Fact | Where |
|---|---|
| Terminal mode is SwiftTerm's `LocalProcessTerminalView` running `agentctl` in a pseudo-terminal and drawing what the provider's TUI prints. It observes only. | `NativeTerminalWell.swift` (header comment, `NativeTerminalObserverView`) |
| Commander sets the default ground, default ink, selection, caret and the font (system mono at a given size). | `NativeTerminalWell.swift` lines 76 to 85; `HarnessTerminal.swift` lines 68 to 72 |
| The session runs with `TERM=xterm-256color` and `COLORTERM=truecolor`, so the TUI chooses its own 24-bit colours. | `NativeTerminalViewer.swift` lines 139 to 140 |
| Console mode is Commander's own SwiftUI transcript with its own palette (`Term` in `DesignTokens.swift`). | `ConsoleDisplay.swift`, `ConsoleScrollback` |

| Terminal mode | Can Commander change it? |
|---|---|
| Font face and size, default ink and ground, caret, selection | Yes, done today |
| Padding round the well, the title bar, the status line, the surrounding tile | Yes |
| The 16 ANSI colours | Likely, through SwiftTerm's palette call; the app does not set it today and I did not verify the call in the pinned version |
| Line height | Not verified in SwiftTerm |
| The TUI's layout, boxes, glyphs, wording, 24-bit colours | No. They are the provider's output |

So Terminal mode gets a calmer well (12.5 pt, more padding, softer ground, matching ANSI colours if supported) and the new frame round it. It cannot be made to read like a conversation; that is what Pretty is for. Console mode can be fully restyled, because Commander draws it, but DESIGN.md freezes it for now: decide later whether Console mode adopts Pretty's sentences or stays a log.

## Rollout, using the existing Theme mechanism

| Step | What | Check |
|---|---|---|
| 1 | Add a third `ThemeID` (working name `quiet`) with the values above; add the `tertiary` colour role and the lamp-with-body-type status mark to all three themes. No view changes | `ThemeTests`; every view still reads roles only |
| 2 | Main-window frame: mode rail, sidebar, page header, tabs | Capture against the demo images, both old themes unchanged |
| 3 | Data tables, board, claims, Hosts, Harnesses, setup forms | Same |
| 4 | Wall tile, focused worker frame, PiP, Needs-you (these also take the Pretty transcript work) | Compare with the approved wall and PiP screenshots |
| 5 | Terminal well: size, padding, ground, ANSI colours if supported | Read a real Claude Code and Codex TUI in it |
| 6 | Tray: type change only | Tray captures |
| 7 | Decide the default theme; update DESIGN.md to describe it; keep Console selectable | The user's call |

Views that branch on a theme, if any exist, must be found in step 1; DESIGN.md says none should.

## Not verified

- No capture of the running app was taken for this proposal. "Before" is drawn from one demo image and the Console theme's token values; the wall "before" is illustrative.
- I looked at two reference images (the Teams workspace capture and the coordinator-wall concept), not the zoom, PiP or tray captures.
- Contrast of the proposed inks was not measured.
- SwiftTerm's ANSI palette and line-height support in the pinned version.
