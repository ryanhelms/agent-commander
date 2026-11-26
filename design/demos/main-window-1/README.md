# Main window increment 1: the theme layer

Black glass and console are now two app-wide themes. A view reads `@Environment(\.theme)`; the choice is stored in user defaults under `appearance.theme` and defaults to black glass.

## See it

Open any design preview, for example `--design-preview preferences`. Switch the theme in one of three ways:

- Choose a card under **Preferences → Appearance → Theme**.
- Press ⌥⌘T, or click the half-filled circle beside the preview browser in the toolbar.
- Pick a theme in the preview browser's menu.

All three write the same stored choice, so every preview view and the live window follow at once.

## Renders

Each page is drawn alone on the theme's opaque canvas at 1340 × 1080 pt, without the window's navigation and toolbar. Regenerate them with:

```sh
THEME_RENDER_DIR=design/demos/main-window-1 swift test --filter ThemeRender
```

| Page | Black glass | Console |
|---|---|---|
| Preferences | `preferences-black-glass.png` | `preferences-console.png` |
| Hosts | `hosts-black-glass.png` | `hosts-console.png` |
| All agents | `all-agents-black-glass.png` | `all-agents-console.png` |
| Search history | `history-black-glass.png` | `history-console.png` |

## Where the pieces are

| Piece | File |
|---|---|
| Token values for both themes | `design/system/tokens.json`, section `themes` |
| `Theme` and the two themes | `Sources/AgentCommander/ThemeTokens.swift` |
| `\.theme`, the stored choice, theme inks with Increase Contrast | `Sources/AgentCommander/ThemeEnvironment.swift` |
| Theme-aware atoms | `Sources/AgentCommander/ThemeAtoms.swift` |
| Theme thumbnail and choice card | `Sources/AgentCommander/ThemeMolecules.swift` |
| Value and exemption tests | `Tests/AgentCommanderTests/ThemeTests.swift` |
| Render test | `Tests/AgentCommanderTests/ThemeRenderTests.swift` |

## What black glass changed

Black glass keeps today's look. Moving the four pages onto roles merged a few near-identical values:

- Search field height 42 → 40 pt.
- Monospaced values 12.5 or 13 → 12 pt. Match excerpts 13 → 12.5 pt.
- State words 11.5 → 12 pt. "Selected" on a choice card 10.5 → 12 pt.
- Six near-identical light greys became one `softInk`.
- "Save view" and the layout switch 33 → 31 pt high.

## Known gaps

- **Window shell.** The sidebar and toolbar (`NavigationRail`, `WorkspaceToolbar` in `Organisms.swift`) don't read the theme. In console they stay glass over the opaque window. Increment 2 replaces them.
- **Components in files this increment may not edit.** `CapabilityChip` (the run, client and host chips on Search history) and `Kicker` live in `Molecules.swift` and keep their black-glass look. The four pages use `ThemeHeading` instead of `Kicker`; other pages still use `Kicker`.
- **Other preview pages.** They share the themed molecules (`PageHeader`, `IconTile`, `FilterChip`, `DataTable`, `Callout`, `MenuField` and others) but still call `panelSurface`, `Hairline`, `StatusLabel` and `CapsuleButtonStyle` directly. In console they look mixed until each is converted.
- **Filter menus.** The label inside a filter chip is a native borderless menu. It ignores the theme's font, so it stays in the system face in console.
- **All agents cards.** The agent cards are harness console tiles, so they are exempt and look the same in both themes. Only the page around them takes the theme.
- **Live app.** The cockpit gets the theme from the root and its window material follows it (opaque `window` in console). No cockpit component reads the theme yet. The live Settings window has no Theme row yet; until increment 2 wires Preferences, switch from a design preview or with `defaults write local.agentcommander.cockpit appearance.theme console`.
- **Black-glass motion.** Black glass has no motion tokens today except the 1.7 s attention pulse. Its `fast`, `standard` and `slow` values (0.15, 0.25, 0.35 s, ease-in-out) are new and need the owner's approval.
- **Not checked in the running app.** The theme switch was verified by build, unit tests and headless renders only.

## Proposals waiting for a decision

- [`DESIGN-ADDITIONS.md`](DESIGN-ADDITIONS.md): text to add to `DESIGN.md`.
- [`TRAY-CHANGE.md`](TRAY-CHANGE.md): a diff for the tray session that makes `MultiplayerTheme` read the console theme.
