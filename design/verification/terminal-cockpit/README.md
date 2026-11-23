# Cockpit terminal design review

Computer Use captured these four views from the rebuilt macOS app in design-preview mode with sample activity paused. The [approved console proof](../../../poc/agui-console/verification/footer-waiting.jpg) supplies the terminal typography, color, prompt and footer treatment. The original concepts supply the layouts.

| View | Original | Native preview | What changed |
| --- | --- | --- | --- |
| Coordinator and worker wall | [Concept](../../concepts/coordinator-wall.png) | [Capture](coordinator-wall.jpg) | The coordinator and five worker tiles use colorized scrollback and slim status lines. Idle and working states are quiet. The waiting tile carries a visible request action. |
| Focused worker | [Concept](../../concepts/focused-worker.png) | [Capture](focused-worker.jpg) | The coordinator stays on the left. On the right, the assignment and colorized transcript lead into the amber inline reply prompt. The bottom line shows input ownership and the handback action. |
| Picture-in-picture reply | [Concept](../../concepts/attention-pip.png) | [Capture](attention-pip.jpg) | The glass stack contains a compact terminal with worker context and the same amber inline reply prompt. The waiting tile uses an ownership icon when its label needs more room. |
| Request arrives during work | [Concept](../../concepts/pip-arrival.png) | [Capture](pip-arrival.jpg) | Backoff strategy keeps its focus ring and handback action as the Field ownership request appears. |

All four surfaces share the AppKit-backed `TerminalWell` atom and `TerminalStatusLine` molecule. The focused worker and PiP share `RequestPrompt` and `RequestReply`. Wall and focused presentations are variants of the same `WorkerTile` organism. PiP uses a smaller transcript and prompt within `AttentionStack`. [Renderer](../../../Sources/AgentCommander/Components.swift) · [Molecules](../../../Sources/AgentCommander/Molecules.swift) · [Organisms](../../../Sources/AgentCommander/Organisms.swift)

Computer Use verified that ⌘Return in the PiP answered Field ownership’s sample request, left Timeout cases pending, and returned keyboard focus to Backoff strategy. The previews use sample data. Tool rows show their visual states as styled text. Live AG-UI and interactive tool disclosures are outside this design pass.
