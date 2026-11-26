import AppKit
import SwiftUI

// ATOMIC LEVEL: Atoms and molecules for the network panel.
// They reuse the cockpit's atoms (IconTile, Hairline, SymbolButton, FieldBox), native controls and
// the tray's token layer (MultiplayerTheme), so a server's page reads as part of the tray. Each takes values and emits a targeted action; none reads the
// model or calls the helper. Helper-supplied text is drawn through `multiplayerDisplay`.

enum MultiplayerLayout {
    /// The tray is 400 pt wide (design/mockups/commander-network-tray.html).
    static let width: CGFloat = 400
    static let inset: CGFloat = Space.l
    static let sectionGap: CGFloat = 18
    /// tokens.json layout.minimumHandoffButtonHeight.
    static let controlHeight: CGFloat = 28
    static let fieldHeight: CGFloat = 30
    static let rowIcon: CGFloat = 28

    /// The scrolling body stays on the main display with room for the menu bar, header and footer.
    /// Set by the headless render, which draws a page at its full height instead of scrolling it.
    @MainActor static var bodyHeightOverride: CGFloat?

    @MainActor static var maxBodyHeight: CGFloat {
        if let bodyHeightOverride { return bodyHeightOverride }
        let visible = NSScreen.main?.visibleFrame.height ?? 720
        return max(220, min(520, visible - 200))
    }
}

// MARK: - Atoms

/// Native single-line text field in the cockpit's field box.
struct MultiplayerTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var isFocused = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 13, design: .monospaced) : MultiplayerTheme.name)
            .foregroundStyle(Palette.foreground)
            .autocorrectionDisabled()
            .multiplayerFieldBox(focused: isFocused)
            .accessibilityLabel(label)
    }
}

// MARK: - Molecules

/// A labeled control with its hint, or its validation problem in place of the hint.
struct MultiplayerField<Control: View>: View {
    let label: String
    var hint: String? = nil
    var problem: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(MultiplayerTheme.sub)
                .foregroundStyle(.inkSecondary)
                .accessibilityHidden(true)
            control
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(Palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint {
                Text(hint)
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An identity with its mark, a caption and one trailing action. Shared by every list in the panel.
struct MultiplayerRow<Trailing: View>: View {
    let symbol: String
    var tone: Tone = .neutral
    let title: String
    var monospacedTitle = false
    var caption: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.m) {
            MultiplayerMark(symbol: symbol, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.multiplayerDisplay)
                    .font(monospacedTitle ? .system(size: 12.5, weight: .medium, design: .monospaced) : MultiplayerTheme.name)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(title.multiplayerDisplay)
            .accessibilityElement(children: .combine)
            trailing
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }
}

extension MultiplayerRow where Trailing == EmptyView {
    init(symbol: String, tone: Tone = .neutral, title: String, monospacedTitle: Bool = false, caption: String? = nil) {
        self.init(symbol: symbol, tone: tone, title: title, monospacedTitle: monospacedTitle, caption: caption) { EmptyView() }
    }
}

/// Rows separated by hairlines, or one line inviting the next step when the list is empty.
struct MultiplayerRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let empty: String
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if items.isEmpty {
            Text(empty)
                .font(.system(size: 12))
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Space.xs)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                    row(item)
                }
            }
        }
    }
}

/// A section action in the section's title row.
struct MultiplayerSectionAction {
    let title: String
    let symbol: String
    var isEnabled = true
    var help: String? = nil
    let perform: () -> Void
}

/// A titled list region with an optional count and one action: one band of the tray.
struct MultiplayerSection<Content: View>: View {
    let title: String
    var count: Int? = nil
    var action: MultiplayerSectionAction? = nil
    @ViewBuilder var content: Content

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: title, count: count.flatMap { $0 > 0 ? "\($0)" : nil }) {
                    if let action {
                        Button(action: action.perform) { Label(action.title, systemImage: action.symbol) }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(!action.isEnabled)
                            .help(action.help ?? action.title)
                    }
                }
                content
            }
        }
    }
}

/// One line of activity: work in progress, a confirmed result, a failure with its next step.
struct MultiplayerBanner: View {
    enum Kind { case progress, success, attention, failure }

    let kind: Kind
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MultiplayerTheme.tileRadius, style: .continuous)
        HStack(alignment: .top, spacing: Space.s) {
            icon.frame(width: 16, height: 16)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(spokenKind.map { "\($0): \(message)" } ?? message)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .fixedSize()
            }
            if let onDismiss {
                SymbolButton(symbol: "xmark", label: "Dismiss", size: 10, action: onDismiss)
                    .foregroundStyle(.inkSecondary)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, Space.s)
        .background(fill, in: shape)
        .overlay { shape.strokeBorder(edge) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .progress:
            MultiplayerSpinner()
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.working).accessibilityHidden(true)
        case .attention:
            Image(systemName: "hourglass").foregroundStyle(Palette.attention).accessibilityHidden(true)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failure).accessibilityHidden(true)
        }
    }

    /// What the icon says, spoken with the sentence. The icon itself is not an element: a tick
    /// would report as selected.
    private var spokenKind: String? {
        switch kind {
        case .progress: nil
        case .success: "Done"
        case .attention: "Waiting"
        case .failure: "Problem"
        }
    }

    private var fill: Color {
        switch kind {
        case .progress: Palette.chrome
        case .success: Palette.workingFill
        case .attention: Palette.attentionFill
        case .failure: Palette.failure.opacity(0.10)
        }
    }

    private var edge: Color {
        switch kind {
        case .progress: Palette.hairline
        case .success: Palette.workingEdge
        case .attention: Palette.attentionSoftEdge
        case .failure: Palette.failure.opacity(0.45)
        }
    }
}

/// What an action lets a friend do, stated before it is granted.
struct MultiplayerCapabilityNote: View {
    let capability: String
    let resourceName: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MultiplayerTheme.tileRadius, style: .continuous)
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: MultiplayerCapability.symbol(capability))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.attention)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(MultiplayerCapability.title(capability))
                    .font(MultiplayerTheme.heading)
                    .foregroundStyle(Palette.foreground)
                Text(MultiplayerCapability.explanation(capability, resource: resourceName.multiplayerDisplay))
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.s + 2)
        .background(Palette.attentionFill, in: shape)
        .overlay { shape.strokeBorder(Palette.attentionSoftEdge) }
        .accessibilityElement(children: .combine)
    }
}

/// A labeled value in a confirmation summary.
struct MultiplayerSummaryLine: View {
    let label: String
    let value: String
    var monospaced = false
    /// The value is a time: drawn in the `fingerprint` face, as every time is.
    var isTime = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(label)
                .font(MultiplayerTheme.sub)
                .foregroundStyle(.inkSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value.multiplayerDisplay)
                .font(isTime ? MultiplayerTheme.fingerprint.monospacedDigit()
                      : monospaced ? .system(size: 13, weight: .medium, design: .monospaced) : MultiplayerTheme.name)
                .foregroundStyle(Palette.foreground)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
