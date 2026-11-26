# Proposed tray change: MultiplayerTheme reads the console theme

Not applied. The tray session owns these files. The change keeps every `MultiplayerTheme` name and value, so no tray component changes and the tray renders stay the same. It only removes the second copy of the values: `Theme.console` is checked against `design/system/tokens.json` by `ThemeTests`.

The tray stays on the console theme whatever the person chooses for the main window. Making the tray follow the choice is a separate decision.

## Sources/AgentCommander/MultiplayerTrayComponents.swift

```diff
 enum MultiplayerTheme {
-    static let panel = Palette.panel
-    static let well = Palette.well
-    static let border = Palette.border
-    static let hair = Color(hex: 0x26282F)
-    static let foreground = Palette.foreground
-    static let focus = Palette.focus
-    static let working = Palette.working
-    static let attention = Palette.attention
-    static let failure = Palette.failure
-    static let selection = Palette.selection
-    static let onAccent = Palette.onAccent
+    /// The tray is always drawn in the console theme (ThemeTokens.swift).
+    private static let theme = Theme.console
+
+    static let panel = theme.color.panel.color
+    static let well = theme.color.well.color
+    static let border = theme.color.border.color
+    static let hair = theme.color.hair.color
+    static let foreground = theme.color.foreground.color
+    static let focus = theme.color.focus.color
+    static let working = theme.color.working.color
+    static let attention = theme.color.attention.color
+    static let failure = theme.color.failure.color
+    static let selection = theme.color.selection.color
+    static let onAccent = theme.color.onAccent.color

     // Hard lines: nothing in the tray is rounder than two points.
-    static let tileRadius: CGFloat = 2
-    static let controlRadius: CGFloat = 2
-    static let chipRadius: CGFloat = 1
-    static let sectionInset: CGFloat = 14
+    static let tileRadius = theme.radius.tile
+    static let controlRadius = theme.radius.control
+    static let chipRadius = theme.radius.chip
+    static let sectionInset = theme.space.sectionInset

     // Prose is set in the system face; anything that is data, a state or a count is monospaced.
-    static let title = Font.system(size: 14, weight: .semibold)
-    static let body = Font.system(size: 13)
-    static let name = Font.system(size: 13, weight: .medium)
-    static let heading = Font.system(size: 11.5, weight: .semibold, design: .monospaced)
-    static let state = Font.system(size: 10.5, weight: .semibold, design: .monospaced)
-    static let sub = Font.system(size: 11)
-    static let mono = Font.system(size: 11, design: .monospaced)
-    static let data = Font.system(size: 11, weight: .medium, design: .monospaced)
-    static let label = Font.system(size: 9.5, weight: .semibold, design: .monospaced)
-    static let fingerprint = Font.system(size: 10.5, design: .monospaced)
-    static let figure = Font.system(size: 14, weight: .semibold, design: .monospaced)
+    static let title = theme.type.title.font
+    static let body = theme.type.body.font
+    static let name = theme.type.name.font
+    static let heading = theme.type.heading.font
+    static let state = theme.type.state.font
+    static let sub = theme.type.sub.font
+    static let mono = theme.type.mono.font
+    static let data = theme.type.data.font
+    static let label = theme.type.label.font
+    static let fingerprint = theme.type.fingerprint.font
+    static let figure = theme.type.figure.font
```

`swatches` and `swatch(for:)` stay as they are.

## Sources/AgentCommander/MultiplayerSkin.swift

```diff
 extension MultiplayerTheme {
     enum Motion {
+        private static let motion = Theme.console.motion
+
         /// Hover and press feedback.
-        static let fast: Double = 0.10
+        static let fast = motion.fast
         /// A row arriving or leaving, a tab changing, a count ticking.
-        static let standard: Double = 0.18
+        static let standard = motion.standard
         /// A meter filling.
-        static let slow: Double = 0.25
+        static let slow = motion.slow
         /// One beat of a live lamp.
-        static let pulse: Double = 1.4
+        static let pulse = motion.pulse
         /// How far an arriving row travels.
-        static let travel: CGFloat = 6
+        static let travel = motion.travel

-        static func ease(_ duration: Double = standard) -> Animation { .easeOut(duration: duration) }
+        static func ease(_ duration: Double = standard) -> Animation { motion.animation(duration) }
     }
 }
```

## Check after applying

```sh
swift build && swift test
MULTIPLAYER_RENDER_DIR=/tmp/tray swift test --filter MultiplayerRender
```

The tray renders should match the committed ones in `design/demos/increment-4/`.

## Two tray atoms the main window already reuses

`ThemeStatus` draws `MultiplayerLamp` and `themeSwitch` applies `MultiplayerSwitchStyle` when the theme is console. Both are used as they are. If either is renamed or its initialiser changes, `Sources/AgentCommander/ThemeAtoms.swift` needs the same change.
