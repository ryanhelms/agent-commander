import AppKit
import SwiftUI

// ATOMIC LEVEL: one molecule and one organism.
// The coordinator shell keeps the run's assignment out of its scrollback in every display mode.
// `CoordinatorAssignmentButton` sits in the coordinator's ConsoleTitleBar accessory, beside the
// display menu, and presents `CoordinatorAssignmentSheet` with the assignment as it was given.

// MARK: - CoordinatorAssignmentButton (molecule)

/// The coordinator title bar's assignment control: a native icon button with the display menu's
/// 23 pt target and title-bar control ink. It opens the assignment in a window sheet, so the
/// console beneath stays mounted and keys typed while the sheet is open go to the sheet. When the
/// sheet closes, keyboard focus is back where it was when the button was pressed: the terminal or
/// composer after a click, the button itself after a key press.
struct CoordinatorAssignmentButton: View {
    static let label = "Show coordinator assignment"

    let assignment: String
    let startedAt: String?

    @State private var isPresented = false
    @State private var focus = FocusReturn()

    var body: some View {
        Button {
            focus.capture()
            isPresented = true
        } label: {
            // Semibold, the weight of the display glyph beside it. The colour is set inside the
            // label, where the button's style cannot replace it.
            Image(systemName: "doc.text")
                .fontWeight(.semibold)
                .foregroundStyle(.consoleHeaderControlInk(active: isPresented ? Palette.focus : nil))
                .frame(minWidth: 23, minHeight: 23).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Self.label)
        .accessibilityLabel(Self.label)
        .accessibilityIdentifier("coordinator-assignment-show")
        .background(FocusReturnProbe(focus: focus).allowsHitTesting(false))
        .sheet(isPresented: $isPresented, onDismiss: { focus.restore() }) {
            CoordinatorAssignmentSheet(assignment: assignment, startedAt: startedAt) { isPresented = false }
        }
    }

    /// True when there is an assignment to show. A run without one has no button.
    nonisolated static func isOffered(for assignment: String) -> Bool {
        assignment.contains { !$0.isWhitespace }
    }

    /// Where keyboard focus was when the button was pressed, and the way back to it.
    ///
    /// A click moves the window's first responder to the SwiftUI hosting view on mouse-down, before
    /// the button's action runs on mouse-up. `FocusReturnProbe` therefore notes the first responder
    /// as the mouse goes down on the button, ahead of AppKit's dispatch. A key press or an
    /// accessibility press moves nothing, so the action reads the first responder as it is.
    @MainActor
    final class FocusReturn {
        struct Snapshot {
            weak var window: NSWindow?
            weak var responder: NSResponder?
            /// The caret or selection of a text field that was being edited.
            var selection: NSRange?
        }

        /// The button's own window, set by the probe while it is in one.
        weak var window: NSWindow?
        /// Focus as the mouse went down on the button; used by the click that follows.
        private var pressed: Snapshot?
        private var held: Snapshot?

        /// Mouse-down on the button, before AppKit moves the first responder.
        func notePress(in window: NSWindow) {
            pressed = Self.snapshot(of: window)
        }

        /// The press ended away from the button, so no action follows it.
        func abandonPress() {
            pressed = nil
        }

        /// The button's action. A click uses the focus noted at its mouse-down.
        func capture(trigger: NSEvent.EventType? = NSApp.currentEvent?.type) {
            let press = pressed
            pressed = nil
            if trigger == .leftMouseUp, let press, press.window != nil {
                held = press
            } else {
                held = (window ?? NSApp.keyWindow).map(Self.snapshot(of:))
            }
        }

        /// The sheet was dismissed. Puts focus back once the sheet has left the window.
        func restore() {
            guard let snapshot = held else { return }
            held = nil
            settle(snapshot, sheetWaits: 20, checks: 3)
        }

        /// A field's editor is shared by the window and loses its field when editing ends, so a
        /// field being edited is recorded as the field itself.
        static func snapshot(of window: NSWindow) -> Snapshot {
            let responder = window.firstResponder
            if let editor = responder as? NSText, editor.isFieldEditor {
                return Snapshot(window: window, responder: editor.delegate as? NSView,
                                selection: editor.selectedRange)
            }
            return Snapshot(window: window, responder: responder, selection: nil)
        }

        static func holdsFocus(_ target: NSResponder, in window: NSWindow) -> Bool {
            if window.firstResponder === target { return true }
            guard let editor = (target as? NSControl)?.currentEditor() else { return false }
            return window.firstResponder === editor
        }

        /// Waits for the sheet to leave, restores, then checks again on the next turns: SwiftUI can
        /// hand focus back to its hosting view just after the sheet ends.
        private func settle(_ snapshot: Snapshot, sheetWaits: Int, checks: Int) {
            DispatchQueue.main.async {
                guard checks > 0, let window = snapshot.window, let target = snapshot.responder else { return }
                if window.attachedSheet != nil {
                    guard sheetWaits > 0 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.settle(snapshot, sheetWaits: sheetWaits - 1, checks: checks)
                    }
                    return
                }
                // The view left this window while the sheet was open.
                if let view = target as? NSView, view.window !== window { return }
                if !Self.holdsFocus(target, in: window) {
                    guard window.makeFirstResponder(target) else { return }
                    if let selection = snapshot.selection, let editor = (target as? NSControl)?.currentEditor() {
                        let length = (editor.string as NSString).length
                        if NSMaxRange(selection) <= length { editor.selectedRange = selection }
                    }
                }
                self.settle(snapshot, sheetWaits: 0, checks: checks - 1)
            }
        }
    }
}

/// Tells `FocusReturn` which window the button is in, and notes the first responder as the mouse
/// goes down on the button. It draws nothing and takes no clicks.
private struct FocusReturnProbe: NSViewRepresentable {
    let focus: CoordinatorAssignmentButton.FocusReturn

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.focus = focus
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.focus = focus
        focus.window = view.window
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.removeMonitor()
    }

    final class ProbeView: NSView {
        weak var focus: CoordinatorAssignmentButton.FocusReturn?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focus?.window = window
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                // A local monitor sees the event before the window dispatches it.
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                    guard let self else { return event }
                    // Local monitors run on the main thread.
                    nonisolated(unsafe) let mouse = event
                    MainActor.assumeIsolated { self.observe(mouse) }
                    return event
                }
            }
        }

        private func observe(_ event: NSEvent) {
            guard let window, let focus else { return }
            let onButton = event.window === window
                && bounds.contains(convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseDown {
                if onButton { focus.notePress(in: window) } else { focus.abandonPress() }
            } else if !onButton {
                focus.abandonPress()
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - CoordinatorAssignmentSheet (organism)

/// The assignment the developer gave the run, complete and as written. The text wraps to the
/// sheet's measure, can be selected and copied, and scrolls once it is taller than the well.
/// Close and Escape put the sheet away. It sends nothing and changes nothing in the console.
struct CoordinatorAssignmentSheet: View {
    let assignment: String
    let startedAt: String?
    let close: () -> Void

    @Environment(\.theme) private var theme
    /// Laid-out height of the wrapped text, so a short assignment gets a short sheet.
    @State private var textHeight: CGFloat = 0

    /// The well grows with the text up to this height, then scrolls.
    static let maxWellHeight: CGFloat = 420
    static let width: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.m) {
                IconTile(symbol: "doc.text", tone: .focus, size: 31)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Coordinator assignment")
                        .themeType(theme.type.title).foregroundStyle(.theme(\.color.foreground))
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.attribution(startedAt: startedAt))
                        .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: Space.m)
            }
            .padding(.horizontal, theme.space.sectionInset)
            .frame(minHeight: 52)
            ThemeRule()
            ScrollView(.vertical) {
                // One Text, so a selection can run across the whole assignment.
                Text(verbatim: assignment)
                    .themeType(theme.type.body).lineSpacing(4)
                    .foregroundStyle(.theme(\.color.foreground))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, theme.space.sectionInset)
                    .padding(.vertical, Space.m)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                    .accessibilityLabel("Assignment")
                    .accessibilityValue(assignment)
                    .accessibilityIdentifier("coordinator-assignment-text")
            }
            .frame(height: Self.wellHeight(forText: textHeight))
            ThemeRule()
            HStack(spacing: Space.m) {
                Spacer(minLength: Space.m)
                Button("Close", action: close)
                    .buttonStyle(ThemeButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Close the assignment")
                    .accessibilityIdentifier("coordinator-assignment-close")
            }
            .padding(.horizontal, theme.space.sectionInset)
            .padding(.vertical, Space.m)
            .background(theme.surface.footerFill.color)
        }
        .frame(width: Self.width)
        .background(theme.surface.panelFill.style)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coordinator assignment")
    }

    /// Who gave the assignment and when, as the console stated it above the scrollback.
    static func attribution(startedAt: String?) -> String {
        guard let startedAt, !startedAt.isEmpty else { return "From you" }
        return "From you, \(startedAt)"
    }

    /// The text's own height between one comfortable line and the scrolling limit.
    static func wellHeight(forText height: CGFloat) -> CGFloat {
        min(max(height.rounded(.up), 56), maxWellHeight)
    }
}
