# Native cockpit verification

## Live workflow

Codex operated the source-built macOS app through Computer Use. The sample run is named **Nacre release decisions**. One Claude Code coordinator delegated to **Naming** and **Rollout** through MCP. Each worker opened its own request in a separate managed tmux session.

With Rollout zoomed, Codex typed one draft in its inline reply field and a different, two-line draft in Naming’s picture-in-picture card. Pressing ⌘Return in Naming sent only its answer. Rollout kept its draft and regained focus. After the second reply, both workers returned their respective values to the coordinator, and the run completed. Naming’s result preserved the dollar sign, double quotes and newline.

## Compare the five layouts

Each pair shows the approved concept on the left and a capture of the native SwiftUI window on the right. The captured windows were 1600 points wide and 983–984 points tall. The original concept used a 1600 × 1000 window, so its source layout was rendered at the corresponding captured height for each comparison. Window materials depend on the desktop and focus state.

| View | Visual comparison |
| --- | --- |
| Coordinator and worker wall | [Compare the wall](coordinator-wall.png) |
| Focused worker | [Compare the focused console](focused-worker.png) |
| Picture-in-picture reply | [Compare the attention stack](attention-pip.png) |
| A new request arrives while a worker has focus | [Compare focus and attention](pip-arrival.png) |
| Start a coordinator run | [Compare the run form](start-run.png) |

These visual fixtures use the production view hierarchy with sample data. They can show proposed capabilities such as remote hosts. A normal launch shows the capabilities of the local provider. [Build and preview instructions](../../README.md)

In the final capture, the focused worker’s question starts at y=654 points. The reference places it at y=655. The run-preview card ends at y=825 against y=824 in the concept. The focused request card is about 22 points shorter at its lower edge. It contains the working inline reply field, while the concept shows a button that opens a reply.

## Component ownership

Claude Fable 5.2 implemented the Swift interface. The terminal well is an atom. Worker identity, input ownership and scoped reply fields are molecules. Worker tiles, the wall, the coordinator console and the attention stack are organisms. The cockpit shell and coordinator split arrange them into pages. The live cockpit and the five design scenarios share these components. [Atomic Design analysis](../system/ATOMIC-DESIGN.md) · [Native source](../../Sources/AgentCommander)
