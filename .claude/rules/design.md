---
description: Follow DESIGN.md for design and interface work
paths:
  - "Sources/**/*.swift"
  - "design/**"
  - "DESIGN.md"
---

# Follow DESIGN.md

Read [DESIGN.md](../../DESIGN.md) before you design, restyle or build any interface: a view, component, token, motion, mockup or UI defect fix.

- Take colours, radii, type, spacing and motion from its tokens. Never use raw values in a component.
- Reuse its atoms and molecules before adding new ones. Components take values and emit targeted actions.
- If a view needs something it doesn't cover, add it to DESIGN.md in the same change rather than inventing a one-off style.
- Leave Console mode rendering as it is. In Terminal mode, leave the provider's output untouched; its well and frame may change only as the "Quiet theme" section of DESIGN.md describes. Build the Pretty transcript from the "Pretty transcript" section of DESIGN.md.
