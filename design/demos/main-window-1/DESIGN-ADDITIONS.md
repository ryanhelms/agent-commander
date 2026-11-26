# Proposed additions to DESIGN.md

`DESIGN.md` was not edited. Increment 1 uses the values below; they are in `design/system/tokens.json` under `themes.console` (`pageType`, `space.pageInset`, `space.rowHeight`, `surface`, `style`). Approve, change or reject each one. The text is ready to paste.

## 1. After the introduction's source table: themes

Add this row to the "Sources of truth in code" table:

```markdown
| Themes | `themes` in `design/system/tokens.json`, `Theme` in `ThemeTokens.swift` |
```

Add this paragraph after the table:

```markdown
The app has two themes. **Console** is the language in this document. **Black glass** is the earlier main-window look, kept as an alternative with the same roles. A component reads a role from `@Environment(\.theme)` and never branches on which theme is active. The console, terminal and pretty view read no theme.
```

## 2. Section 2, Type: page-scale roles

Add these rows to the Type table:

```markdown
| `pageTitle` | System | 20 semibold | The title of a full-size page |
| `control` | Mono | 12 medium | Button labels |
```

Add this sentence under the table:

```markdown
On a full-size page, a title inside a panel and a section title both use `title`, the note beside a heading uses `sub`, and the line above a page title uses `label`.
```

`control` records what `MultiplayerTrayButtonStyle` already does for a large button.

## 3. Section 2, Spacing and size

Add these rows:

```markdown
| Page inset | 24 pt |
| Table row height | 34 pt |
```

## 4. Section 2, Colour: surface roles

Add this paragraph after the tinted-states sentence:

```markdown
Components name a surface, not a base colour: a panel is `panel` with a `hair` edge and no shadow; a mark or a field is `well` with a `border` edge; a standard button is clear with a `border` edge; a primary button is filled `focus`; a selected row or card is `selection` with a 2 pt `focus` leading marker; a table header and a footer are `well`; a search match is filled `attention` with `onAccent` ink.
```

## 5. New subsection in section 2: Material

```markdown
### Material

| Token | Console | Black glass |
|---|---|---|
| Window | Opaque `window` | System glass |
| Canvas | `window` | Dark gradient over the glass |

Reduce Transparency forces the opaque fill in both themes. The web Remote page is unaffected.
```

## 6. Section 3, Atoms: state on a full-size page

Add this row:

```markdown
| Tone lamp | Where a view has a tone but no specific state, the lamp follows the tone: working `on`, attention `busy`, failure `error`, focus `unknown`, neutral `off`. |
```

## 7. Section 3, Molecules: theme choice

Add these rows:

```markdown
| Choice card | A selectable card: a thumbnail, a round choice mark, the option's name and one line about it. The selected card is filled `selection` with the leading `focus` marker and the word "Selected" in `working`. |
| Theme thumbnail | A small window drawn in one theme's own tokens: its rail, two panels with a state mark, and a primary action. |
```

## 8. Section 4, Layout patterns: Preferences

```markdown
- **Preferences.** Sections stack: a mono heading, a `title`, and a trailing scope note. Appearance comes first and offers one choice card per theme, followed by the line "Consoles, terminals and the pretty view look the same in every theme."
```

## 9. Section 6, Open work

Replace the first sentence of "Unify the token layers" with:

```markdown
- **Unify the token layers.** `Theme` (`ThemeTokens.swift`) now holds both themes' roles, type, radii, spacing and motion, checked against `design/system/tokens.json`. `MultiplayerTheme` still holds its own copy; point it at `Theme.console` (see `design/demos/main-window-1/TRAY-CHANGE.md`).
```

## Black glass values that have no source today

These are in `themes.blackGlass` and need a decision because nothing in the current app defines them:

- Motion `fast` 0.15 s, `standard` 0.25 s, `slow` 0.35 s, ease-in-out, `travel` 0. Only `pulse` 1.7 s comes from existing code (the attention glow).
- `figure` is system 22 semibold.
