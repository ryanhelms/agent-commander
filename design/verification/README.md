# Native cockpit verification

The independent agent-acp candidate is verified through its installed Go, npm and Python packages. The release build checks Commander's Go module pin in a fresh cache. [SDK release verification](sdk-release/README.md)

## Design gallery

The native preview gallery opens all 28 approved screen concepts and states in one window. Its sample workspace covers local and remote workers, cross-run attention, adoption, recovery, and successful and blocked integration attempts. Sample output can advance while the view is open. The preview menu can pause that activity or reset the current view. [Open the gallery from the build guide](../../README.md)

Computer Use opened every gallery state. It verified that sending a sample reply resolves the selected request while the other request stays pending, filtering by host or run changes the visible consoles, and selecting a failed integration attempt updates the candidate and combined-test results. These interactions run against sample data. After navigating, the accessibility tree sometimes reports the Next arrow as Previous. The arrow moves forward and its help text identifies the correct direction.

## Approval captures

The [native review gallery](review/index.html) holds all 28 Computer Use screenshots at their original 3200 × 1968 image resolution and displays each beside its original concept. The preview was captured with sample activity paused. The worker-actions capture includes its open popover. Use the gallery to record a decision and notes for each view, then export the review as Markdown.

The [component inventory](review/COMPONENTS.md) maps all 123 named display declarations to the Atomic Design layers, links to their Swift source, and shows how each of the 28 views is composed. The [capture manifest](review/captures.json) records each image’s size and SHA-256 hash.

## Live workflow

### CopilotKit reference console

The same browser workflow sent prompts, opened tool results and answered addressed requests against real Claude and Codex workers. An independent AG-UI consumer repeated the interaction on each harness. [Live evidence and captures](copilotkit-live/README.md)

### Native source inspector

The focused conversation and receipt checks use real Claude and Codex workers on the incremental workspace feed. [Native conversation and attachment verification](incremental-native/README.md)

The running native app opened selected worker source records directly from the wall. Provider history, live ACP details and an explicit journal gap were verified with macOS Accessibility. The focused Pretty console displayed the selected worker's live record. Its PiP action opened that worker's inspector and left the underlying request pending. [Native source captures](native-source/README.md)

The independently installed Pi translator and stock Antigravity executable supplied the onboarding checks in native Pretty, native Console and the independently installed CopilotKit connector. Pi returned the file result in its tool message and passive history. Antigravity reported the completed tool call and returned the file marker in assistant text. [Pi verification](pi-translation.md) · [Antigravity verification](stock-acp.md)

### 30-pane workspace load

The test Mac ran 30 active tmux panes and answered approvals from one worker while another streamed sustained output. The reconnect preserved the pending request ID, and scoped history returned a complete large attachment while the shared workspace stream carried a notice. [Measurements and reproduction](30-pane/README.md)

### Transcript coverage

The synthetic fixtures distinguish saved Claude and Codex records, vendor stdout, ACP updates and the workspace AG-UI projection. The manifest maps each record shape to its available preview, scoped history, and remaining coverage. [Transcript coverage](transcript-coverage/README.md)

The signed November 23 Opus build reopened the real Color Studio service in a separate local window. Both the plum Claude worker and teal Codex worker showed Pretty on the worker wall. Opening **Read receipt.txt** displayed `PLUM-4761`. The Claude prompt’s **View attachment** control decoded the retained 110-byte PNG. The controls were collapsed again for manual inspection. The full native suite passed all 148 tests in 26 suites with the provider, wire, incremental and journal fixtures enabled.

### Frontend tools

The managed harness can invoke an app-defined tool through its worker-scoped MCP bridge. Test coverage includes live harness interaction, hosted and relayed authorization, and the embedded AG-UI client. [Frontend tool verification](frontend-tools.md)

### Catalog updates with live workers

Two local service instances shared a test publisher and used separate pin directories. Concurrent explicit refreshes from separate CLI processes downloaded one signed update per owner. The observing service sent its initial empty set, the verified 2.0.0 release over the 1.0.0 pin, an empty set on activation and the same release after rollback followed by another refresh. A reconnect recovered the current set. An invalid signature produced no notice or download. The neighboring service and the existing conversations retained their state. [Cross-process reproduction](catalog-notices/verify.mjs)

Two independent Commander services subscribed to catalog notices while separate CLI processes verified signed updates, activated a pin and rolled it back. A reconnected reader recovered the current notice and both services retained their own conversations. [Cross-process acceptance and native QA fixture](catalog-notices/README.md)

On macOS arm64, Commander exercised two signed releases for each of three distributions through a local TLS catalog. The platform executable, npm tarball and Python wheel each launched three managed tmux workers. While the first worker waited for permission on 1.0.0, refresh rejected a bad publisher signature before downloading the archive, then two concurrent refreshes returned the same verified stage after a single download. The second worker launched on 2.0.0 after explicit activation. The third launched on 1.0.0 after rollback, with both earlier workers still waiting. All nine workers completed with the release marker from their own launch after receiving their addressed replies. The matrix passed with the Go race detector against the packaged SDK 0.1.7. [Worker lifecycle test](../../internal/provider/catalog_timeline_test.go) · [Offline package tests](../../internal/catalog/packages_test.go)

A verified retry of the active version returns its existing installation. Replacing the selected stage’s archive after the first activation now returns a SHA-256 mismatch on retry and preserves the existing pin. [Activation regression](../../internal/catalog/pin_test.go)

In a network-disabled Linux arm64 container, the CLI registered the pinned publisher's endpoints and fetched a signed update from a loopback TLS catalog. An invalid signature caused zero archive downloads. A valid refresh and retry made one download and returned the same stage ID. The active executable stayed on 1.0.0 until activation. Rollback restored that executable and kept the configured proof endpoints.

The Linux arm64 CLI also ran each distribution's full lifecycle in a separate network-disabled container with a loopback HTTPS catalog. The catalog advertised a platform binary without its optional digest, an npm name without a version, and a PyPI name without a version. Each publisher-signed entry supplied the missing digest or exact pin. For every family, the operator discovered the entry, installed 1.0.0, received a verified notice for 2.0.0, tried an incorrect publisher key, applied the update with the correct key, and rolled back to 1.0.0. Go tests also reject mismatched release claims, changed artifacts, interrupted staging and incompatible package executables. [ACP catalog format](https://github.com/agentclientprotocol/registry/blob/main/FORMAT.md#distribution-types)

Regression tests canceled binary, npm and Python activation after extraction and immediately before the pin switch. The existing executable remained selected, the unfinished installation was removed, and the same stage applied successfully on retry. These tests passed on macOS and in network-disabled Linux arm64 containers. The binary fixture also canceled a download at EOF and verified that no stage was published. A built CLI returned on Ctrl-C during both refresh and rollback while another process still held the catalog lock. [Binary tests](../../internal/catalog/pin_test.go) · [Package tests](../../internal/catalog/packages_test.go) · [Stage test](../../internal/catalog/stage_test.go)

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

## Computer Use app identity

Use the canonical `dist/Agent Commander.app` bundle with identifier `local.agentcommander.cockpit` for all cockpit QA, including the wall, Pretty and Console, design previews and the multiplayer panel. Reuse the running cockpit. Isolate each test service with its own state directory and socket. For a test that requires different startup arguments or a different socket, use the same bundle at its next planned relaunch. Earlier captures in this directory document the QA bundle identities in use at the time.
