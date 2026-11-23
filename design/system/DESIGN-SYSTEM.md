# Agent Commander interface system

**Project ownership.** The separately named `design-system` repository is an unrelated project. Agent Commander owns and versions its entire design system in this workspace. Its tokens, fixtures, artwork, documentation and future Swift components have an independent release history. Keep all design changes with the Agent Commander features they serve.

**Review status.** The developer approved the coordinator wall and picture-in-picture direction for the initial local build. The gallery contains 28 visual references for the broader product. Claude Fable 5.2 owns the native design implementation. This specification translates those targets into component behavior for the native Mac app. Codex and Claude Fable 5.2 developed the material, ownership, keyboard and accessibility contracts against the plan and gallery. A browser specimen exercises a few interactions with illustrative data.

[Open the component specimen](index.html) · [Browse the concept gallery](../concepts/index.html) · [Read the portable tokens](tokens.json) · [Atomic Design breakdown](ATOMIC-DESIGN.md)

## Material and color

Use glass where the developer navigates or acts on top of other content. Use a stable opaque background where they read output, compare changes or enter a response. Let the system supply the optics. The wallpaper in the concept images is a design-review backdrop. The app should work over the developer’s actual desktop. [Apple’s material guidance](https://developer.apple.com/design/human-interface-guidelines/materials)

| Material role | Placement | Behavior |
| --- | --- | --- |
| Navigation | Window sidebar, compact rail, grouped toolbar controls | Prefer standard macOS components and regular system glass. Preserve contrast for symbols, titles and keyboard hints as the background changes. |
| Floating control | Front PiP, attention drawer and worker actions menu | Use one glass surface per visual group. Use opaque back cards to identify the next worker and request ID. The front card uses an opaque well for terminal output. |
| Content | Project detail, Git integration, settings, history | Opaque window and panel colors. A border, a heading or some spacing can distinguish sections without another glass layer. |
| Terminal well | Live terminal, read-only tail, transcript and code | Opaque near-black background. Preserve meaningful terminal colors and cursor state. Keep app-owned status outside the terminal byte stream. |
| Notice | Question, permission prompt, failed test or missing receipt | Write the reason and name the affected target. Use a symbol and a semantic color together. |

The portable token file records the black-glass palette, spacing, type and fallback fills. The source concepts use terminal `#0B0C10`, foreground `#F5F5F9`, secondary text `#B7BAC6`, focus `#B5D6FF`, working `#A8E0C0`, and attention `#F1C587`. Coral identifies failure. A blue-fill selection and an exterior keyboard-focus ring can appear on different workers. The person who owns terminal input is always named separately.

## Type, dimensions and density

Use the macOS system font for interface text and the system monospaced face for terminal text, paths, revisions and request IDs. Starting sizes are 32 pt for a page title, 18 for a section, 14 for body text, 13 for controls and terminal output, 12 for ownership, and 11 for incidental metadata. Support user-adjusted terminal text size. At higher density, show fewer columns or fewer lines of output before shrinking critical labels.

Use the 4, 8, 12, 16, 24 and 32 pt spacing scale. Start with a 52 pt toolbar, a 54 pt compact rail and a 204 pt expanded sidebar. The coordinator takes one third of the workspace **after navigation**. Give its draggable divider an 8 pt interaction area. Start with 300 pt wall tiles, a 350 pt PiP and a 310 pt drawer as layout targets. At narrow widths, scroll the wall horizontally, reflow around an open drawer, and preserve the coordinator and the current request. Measure on real window sizes before freezing minimums.

## Component contracts

| Component | Data it receives | Behavior it owns |
| --- | --- | --- |
| Worker tile | Stable assignment and worker IDs, run and parent, host, worktree, current state, attention and owner | Keep the same tile through retries, renames and reconnects. Show a readable terminal preview, status and ownership. Offer assignment, follow-up, zoom, interrupt and stop actions according to capability. Opening a menu preserves the current owner. |
| Terminal well | A screen model for one worker, pane dimensions, rendering mode, connection and lease | Render a passive tail in the wall and PiP. In an interactive terminal, route input only while the developer owns control and that terminal has keyboard focus. Each projection has its own view of one shared screen model. The native input router checks the pane, AppKit first responder and confirmed lease generation before submitting input. Passive views leave the pane geometry alone. Mark transcript gaps. |
| Input ownership control | Worker ID, owning run, holder actor ID and kind, control generation, permission and control state | While observing, display “Input · owner.” After a successful takeover, display “You have input” and a real **Hand back** button. Preserve ownership through focus changes, zoom, PiP dismissal and reconnection. Name a parent worker when it holds input. Show acquiring, releasing, denied or unknown when appropriate. A failed takeover keeps the last confirmed holder visible with its timestamp. |
| Request reply | Run, worker, host, request ID, question or approval, permitted responses and delivery evidence | Use the same contract in PiP, queue, drawer and focused views. A reply targets exactly one request and leaves the terminal lease intact. On concurrent resolution show the recorded answer and actor. When delivery is uncertain, offer to check the original operation. |
| Coordinator split and worker wall | Run, parent relationships, current filter, focused assignment, saved layout | Keep the left pane stationary while the right side switches between wall and zoom. Preserve scroll position and collapsed groups on return. Apply inbox changes without changing the selected tile. |
| Operation detail and integration result | Operation ID, revision where applicable, evidence, outcome and safe continuations | Name the host, request or candidate being acted on. A failed combined test leaves the target branch unadvanced. A provider sign-in resumes the original operation. Both surfaces can be reached from the cockpit and from history. |

**Independent state axes.** Task activity, connection, human attention, message delivery, terminal ownership and keyboard focus are separate values. A disconnected worker may have been working at its last observation. Display both facts with a timestamp. A quiet pane supplies no evidence that a person needs to intervene. The API is authoritative for permissions, ownership and delivery. SwiftUI owns temporary view state such as a drawer’s visibility.

## Keyboard, motion and accessibility

- **PiP arrival.** Announce a new decision once, including the worker and run. Preserve the current first responder. After the developer deliberately focuses a reply field, submit only to the bound request. Restore the previous eligible focus target when they return.
- **Terminal routing.** Support menu equivalents and remapping. Fable identified a conflict in the visual concepts where Option shortcuts can consume a terminal user’s Meta sequences. The proposed native defaults are ⌘1 for the coordinator, ⇧⌘A for the next pending request, ⌘] for worker zoom and ⌘[ for return. Test against full-screen TUIs, input methods and the application menu. Forward ordinary terminal keys, including Escape, according to the active responder. Native shortcut labels can change after that test.
- **Accessible names.** A tile announces the worker, run, host, task state, connection, outstanding request and input holder. Expose its actions through accessibility APIs. Make the terminal buffer readable on demand and announce significant status changes separately from high-volume output.
- **Independent display preferences.** Reduce Transparency replaces translucent chrome with opaque surfaces. Increase Contrast strengthens boundaries, secondary text and the focus ring. Reduce Motion uses an immediate transition or brief fade. Differentiate Without Color preserves labels and distinct symbols. Exercise these settings separately and in combination.
- **Legibility checks.** Start with 4.5:1 for ordinary interface text, including timestamps that convey essential state, and target 7:1 for primary app-rendered terminal text. Measure the rendered result over light and dark desktops. Make Hand back at least 28 pt tall in the compact layout. Recheck actual hit areas and large-text layouts on macOS. [W3C contrast guidance](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)

## Scenarios for iteration

Use the first real planning run to exercise a reply and restore focus. Use the remaining scenarios as the related features land.

1. Take terminal control of Backoff strategy. While typing, receive a PiP from Field ownership in a different run. Use the keyboard to answer its request and return. Verify both recipient IDs, terminal ownership, and restored focus.
2. Open three coordinators with ten workers each. Stream a noisy worker, collapse a family, open the drawer and zoom a quiet worker. Verify stable tile identity, readable output and the responsiveness of the pending approval.
3. Repeat the first scenario using VoiceOver with Reduce Transparency, Increase Contrast and enlarged terminal text. Announce the decision once and make the input holder and handback action discoverable.
4. Disconnect an SSH host after Commander accepts a reply. Restore the connection, show the prior ownership, reconcile the original request and mark any transcript gap. The review fixture includes both an acknowledged reply and an uncertain outcome.

Reuse the [Atomic Design map](ATOMIC-DESIGN.md) and [existing pattern decisions](../PATTERN-DECISIONS.md) as components enter the cockpit. Add a brief decision when an implementation introduces a new boundary or interaction. The [technology decision](../TECHNOLOGY.md) defines the native and host boundaries.
