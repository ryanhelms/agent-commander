# Technology decision

**Select Swift for the desktop cockpit and Go for the Commander service and tools.** The MVP targets macOS 26 or newer. Build from source for personal use first. The public distribution milestone is a signed, notarized download. Remote execution must be tested on both Linux and macOS. The first production harness release adds an embeddable CopilotKit integration and a working reference console. Local and hosted consumers use the same Commander command semantics. [Harness integration plan](HARNESS-INTEGRATION-PLAN.md)

## Where each technology belongs

| Deliverable | Choice | Responsibility |
| --- | --- | --- |
| macOS app | Swift with SwiftUI and AppKit | SwiftUI composes the component system, navigation and inspectors. Use AppKit where the terminal view, first responder, input method, or window behavior requires it. Use the platform’s glass for navigation and floating controls. |
| Background service and remote helper | Go | One portable core tracks runs, scopes commands to their owner, manages tmux, records delivery evidence and serves API requests. The local service and persistent SSH helper can share these packages. An SSH-only host can participate through its available tmux and SSH capabilities. |
| CLI, MCP adapter and managed-worker terminal UI | Go | Thin front ends to the versioned API. The terminal UI shows the conversation when the developer attaches through ordinary tmux. Use the official Go MCP SDK for the protocol adapter. [Go MCP SDK](https://github.com/modelcontextprotocol/go-sdk) |
| Shared contract | Versioned operation, response, error and event schemas | Give each implementation the same IDs, capability descriptions and control rules. Test the Swift and Go clients against common examples. Use portable design tokens and component behavior contracts for future visual clients. |
| Terminal renderer | Evaluate SwiftTerm first | Feed the renderer bytes from a Commander subscription. Send authorized human input through the API. A view must never start its own worker shell. Test an xterm.js surface hosted inside a native window if the native renderer misses a terminal requirement. [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) · [xterm.js flow control](https://xtermjs.org/docs/guides/flowcontrol/) |

## Why this fits

The black-glass design is directly supported by Apple’s frameworks. Standard macOS navigation supplies system materials. A custom floating request control can use SwiftUI regular glass or AppKit’s `NSGlassEffectView`. The terminal beneath it uses an opaque content surface. A native input router uses AppKit’s first responder and the service’s confirmed lease generation to bind a keystroke to its pane when a PiP arrives. On the development Mac, a temporary Swift source successfully type-checked both SwiftUI `glassEffect` and an AppKit glass view with an assigned `contentView` against SDK 26.5. This verifies API availability. Rendering and focus behavior still need a running prototype. [Apple’s AppKit design guidance](https://developer.apple.com/videos/play/wwdc2025/310/) · [Apple’s material roles](https://developer.apple.com/design/human-interface-guidelines/materials)

Go fits the headless half because process supervision, sockets, stream handling, CLI delivery and the MCP entry point can share one implementation across Mac and Linux. Go lists both systems on ARM64 and x86-64. Test native history access through the common Go harness SDK on each advertised target. Compiler target support is only the first check. Use the system OpenSSH client to preserve host aliases, jump hosts and authentication behavior. Put conversation text in framed data on the stream. OpenSSH assembles remote command arguments into a command string, which is exactly where the original quoting failures can reappear. [Go build targets](https://go.dev/doc/install/source#environment) · [OpenSSH manual](https://man.openbsd.org/ssh.1)

| Alternative considered | When to revisit it |
| --- | --- |
| Swift across the entire product | This is viable, including on Linux. Reconsider if a single toolchain becomes the priority and clean-host builds prove SQLite, subprocess handling and distribution work on the required Linux targets. [Swift static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html) |
| TypeScript UI in a desktop WebView | Reconsider if simultaneous browser and desktop delivery becomes a release requirement. A WebView supports a CSS-rendered interpretation of the design and a shared UI. Actual macOS glass, window behavior and terminal focus still require platform decisions. [Tauri architecture](https://v2.tauri.app/concept/architecture/) · [WebKit backdrop filters](https://webkit.org/blog/3632/introducing-backdrop-filters/) |

## Engineering checks as features land

Start using the local cockpit once a coordinator, two workers and a targeted PiP reply work. Run the broader checks alongside the corresponding features.

1. **Local source build.** Build the Mac cockpit and Go binaries on the development Mac. Exercise one request from the GUI, CLI and MCP. Match their operation IDs, authorization outcomes and run events.
2. **Terminal and material spike.** Use a native window with both a busy real agent TUI and the PiP overlay. Compare default glass, Reduce Transparency and Increase Contrast over light and dark desktop backgrounds. Exercise three coordinators and up to thirty workers. Measure memory, CPU, input-to-display latency and time to show an approval under load. Check Unicode width, IME composition, alternate screen, paste, scrollback and VoiceOver. A preview, resize of a tile, or PiP arrival must preserve the external tmux client’s terminal size and the developer’s input target. [tmux control mode](https://github.com/tmux/tmux/wiki/Control-Mode)
3. **Remote host builds.** Run helper-backed and SSH-only scenarios on Linux and remote Macs. Include architecture coverage for the host packages actually shipped. Test an alias through a jump host, service restart, disconnected delivery, recovery of ownership and transcript search after retention expires. Record any CPU or OS combination still awaiting a real run before advertising support.
4. **Distribution.** Start with source build instructions. For distribution, sign the Mac app and its bundled executables with Developer ID, notarize the packaged download and verify first launch on a clean Mac. Test the remote helper independently of the Mac app bundle. [Apple’s notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

The language choice is settled. Renderer selection, measured terminal capacity and packaging are engineering verification items. The [design system](system/DESIGN-SYSTEM.md), [Atomic Design analysis](system/ATOMIC-DESIGN.md), and [pattern decisions](PATTERN-DECISIONS.md) govern the first implementation slice.
