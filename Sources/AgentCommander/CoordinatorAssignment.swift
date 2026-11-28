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
        .sheet(isPresented: $isPresented, onDismiss: { focus.restore() }) {
            CoordinatorAssignmentSheet(assignment: assignment, startedAt: startedAt) { isPresented = false }
        }
    }

    /// True when there is an assignment to show. A run without one has no button.
    nonisolated static func isOffered(for assignment: String) -> Bool {
        assignment.contains { !$0.isWhitespace }
    }

    /// The window's first responder at the press. A window sheet leaves it in place; this puts it
    /// back only when something moved it while the sheet was open.
    @MainActor
    private final class FocusReturn {
        private weak var window: NSWindow?
        private weak var responder: NSResponder?

        func capture() {
            window = NSApp.keyWindow
            responder = window?.firstResponder
        }

        func restore() {
            let window = window, responder = responder
            self.window = nil
            self.responder = nil
            // After the sheet has ended and the window is key again.
            DispatchQueue.main.async {
                guard let window, var target = responder, window.firstResponder !== target else { return }
                // A field's editor is shared by the window: return to the field that owned it.
                if let editor = target as? NSText, editor.isFieldEditor {
                    guard let owner = editor.delegate as? NSView else { return }
                    target = owner
                }
                if let view = target as? NSView, view.window !== window { return }
                window.makeFirstResponder(target)
            }
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
