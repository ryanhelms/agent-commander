# Native cockpit verification

## Design gallery

The native preview gallery opens all 28 approved screen concepts and states in one window. Its sample workspace covers local and remote workers, cross-run attention, adoption, recovery, and successful and blocked integration attempts. Sample output can advance while the view is open. The preview menu can pause that activity or reset the current view. [Open the gallery from the build guide](../../README.md)

Computer Use opened every gallery state. It verified that sending a sample reply resolves the selected request while the other request stays pending, filtering by host or run changes the visible consoles, and selecting a failed integration attempt updates the candidate and combined-test results. These interactions run against sample data. After navigating, the accessibility tree sometimes reports the Next arrow as Previous. The arrow moves forward and its help text identifies the correct direction.

## Approval captures

The [native review gallery](review/index.html) holds all 28 Computer Use screenshots at their original 3200 × 1968 image resolution and displays each beside its original concept. The preview was captured with sample activity paused. The worker-actions capture includes its open popover. Use the gallery to record a decision and notes for each view, then export the review as Markdown.

The [component inventory](review/COMPONENTS.md) maps all 123 named display declarations to the Atomic Design layers, links to their Swift source, and shows how each of the 28 views is composed. The [capture manifest](review/captures.json) records each image’s size and SHA-256 hash.

## Live workflow

### Harness icons

The packaged app rendered the local Claude Code, Codex, Antigravity and Gemini CLI marks in a sample run. A shell, a generic MCP client, an unattributed pane and an unrecognized profile each showed the native terminal symbol. Claude Fable compared the wall, focused worker and PiP against the original layouts. The identity mark sits in the existing accent-colored badge, while the separate control at the right of the header still selects Console or Pretty. [Five title bars at native resolution](harness-icons/title-bars.png) · [Wall and PiP](harness-icons/wall-and-pip.jpg) · [Artwork sources](../../Sources/AgentCommander/Resources/HarnessIcons/ATTRIBUTION.txt)

### Console header contrast

Fable photographed the native wall, focused worker and PiP with sample activity paused. Compared with the approved compositions, the updated consoles keep the compact title rows, black scrollback and amber request cue. The full-width header now uses a darker shade of its harness color, with a brighter perimeter and a dark plate behind the provider mark. [Before and after at actual size](console-styling/before-and-after.png) · [Wall and PiP](console-styling/wall-and-pip.jpg) · [Focused worker](console-styling/focused.jpg)

On matching wall captures, sampled glyph-to-plate contrast rose from roughly 2.6 to 7.7 for Claude, 2.0 to 4.6 for Codex, and 2.5 to 7.7 for MCP. These measurements include the effect of rendering the small glyphs. The rebuilt preview also showed a visible border for a dark violet override with Increase Contrast and Reduce Transparency enabled. Selecting Pretty from Backoff strategy’s title-bar menu left Retry telemetry in Console. Reopening the menu showed Pretty checked, and selecting Console restored the initial state.

### Harness accents

Computer Use compared the native wall, focused console and PiP with the approved layouts. The header now carries a dark tint across its full width, with a matching provider glyph and brighter perimeter. Waiting workers have an additional amber inset. The title bar heights and scrollback positions match the existing console shell. [Wall and PiP](harness-accents/default-wall.jpg) · [Original wall](../concepts/coordinator-wall.png) · [Original PiP](../concepts/attention-pip.png)

Changing Codex to Mint updated both Codex workers in an isolated service run and survived a full app relaunch. The distinct Claude, generic MCP and named custom harness colors remained visible. Choosing Default restored Codex blue across its workers. The same override appeared on the focused worker and wall in the gallery. [Focused override](harness-accents/override-focused.jpg) · [Wall override](harness-accents/override-wall.jpg) · [Original focused worker](../concepts/focused-worker.png)

### Console and Pretty

Computer Use exercised the native app against an isolated local service with two sample runs. On the wall, selecting Pretty for **Rollout notes** formatted its Markdown heading, list, inline code and fenced command. The adjacent Compatibility worker kept its terminal output. Selecting Pretty for all consoles also formatted the coordinator and applied to the other run when opened. Selecting Console for all restored the terminal views. [Mixed wall](console-modes/mixed-wall.jpg) · [All consoles in Pretty](console-modes/all-pretty.jpg)

The worker kept its mode through zoom, a new streamed message and the floating request panel. A draft typed into its focused reply field survived a mode change and appeared in PiP. Changing the mode in PiP updated the focused worker when reopened. Tool results expanded in Pretty. [Focused worker](console-modes/pretty-focused.jpg) · [Floating request](console-modes/pretty-pip.png)

Compared with the approved wall, focus and PiP layouts, the new controls occupy a title-bar accessory and a window toolbar item. Pretty starts short conversations at the top of each pane and uses proportional text with inset code blocks. The request and ownership controls keep their existing positions. [Approved wall](../concepts/coordinator-wall.png) · [Approved focus](../concepts/focused-worker.png) · [Approved PiP](../concepts/attention-pip.png)

### Coordinator and worker replies

Codex operated the source-built macOS app through Computer Use. The sample run is named **Nacre release decisions**. One Claude Code coordinator delegated to **Naming** and **Rollout** through MCP. Each worker opened its own request in a separate managed tmux session.

With Rollout zoomed, Codex typed one draft in its inline reply field and a different, two-line draft in Naming’s picture-in-picture card. Pressing ⌘Return in Naming sent only its answer. Rollout kept its draft and regained focus. After the second reply, both workers returned their respective values to the coordinator, and the run completed. Naming’s result preserved the dollar sign, double quotes and newline.

## Compare the five original local cockpit layouts

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

### Live worker controls

Computer Use opened the focused console for a real local Claude worker, took control, and sent a two-line follow-up containing quotes, a dollar sign and backticks. Claude displayed the literal marker and opened a second request. Interrupt returned the worker to idle and cleared that request while its neighbor’s request stayed pending. The same worker resumed and recalled the marker. Handback removed the focused follow-up field. The worker-specific stop confirmation named the target, and the neighbor answered its own outstanding request and completed afterward.

The [focused-worker concept](../concepts/focused-worker.png) places the ownership cue and handback above the composer. The live capture uses the updated square, harness-tinted terminal shell and preserves that order. The live request has an inline reply field, and the separate composer describes a follow-up to the named worker.

### Shared components

Claude Fable 5.2 implemented the Swift interface. The terminal well is an atom. Worker identity, input ownership and scoped reply fields are molecules. Worker tiles, the wall, the coordinator console and the attention stack are organisms. The cockpit shell and coordinator split arrange them into pages. The live cockpit and the five design scenarios share these components. [Atomic Design analysis](../system/ATOMIC-DESIGN.md) · [Native source](../../Sources/AgentCommander)
