# Design rules

Read the [Agent Commander design specification](../../DESIGN.md) before any design or interface work. It defines the visual language for the main window, zoom, PiP, and network tray.

Use the specified colors, radii, type, spacing, and motion tokens for every component value they cover. Reuse existing atoms and molecules first. When a view needs a new design rule, propose it and update the design specification in the same change. Update the specification in the same commit whenever you add or alter a component, token, or motion.

Keep all design tokens, components, fixtures and assets in this repository. The repository named `design-system` is a separate project.

## Components and verification

Apply Brad Frost’s Atomic Design strictly to each implemented view. Start with the [component map](../../design/system/ATOMIC-DESIGN.md) and [local tokens](../../design/system/tokens.json). Compose native controls and styled atoms into molecules, then feature organisms, layout templates and pages. A standard native control can serve directly as an atom. Share component implementations between the wall, zoom and PiP when they have the same responsibility. Components receive values and emit targeted actions. The API and feature models own domain operations and subscriptions.

When changing a screen, identify its actual Swift components and compare the rendered state with the matching [original screenshot](../../design/concepts/index.html). Record any visible differences that matter. Use the approved coordinator wall and PiP as the starting point for the local build.

## Console, Terminal, and Pretty

Preserve Console mode rendering and the provider's output in Terminal mode. Limit changes to the Terminal well or frame to those described in the [Quiet theme section](../../DESIGN.md#quiet-theme-two-speeds-approved-target-not-yet-built). Follow the [Pretty transcript section](../../DESIGN.md#pretty-transcript) for the Pretty transcript.
