import SwiftUI

// ATOMIC LEVEL: Molecules (workspace, delegation and setup views).
// Small combinations used by more than one page outside the coordinator split. They take values
// and emit targeted actions like the cockpit molecules, and reuse the same atoms and tokens.
// The molecules that read `\.theme` take every colour, radius, type and size from the current
// Theme (ThemeTokens.swift); ConsolePreview is a console surface and never does.

// MARK: - Headings

/// Page heading: where the page sits, its name, a sentence about it, and its primary actions.
struct PageHeader<Actions: View>: View {
    let kicker: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let actions: Actions
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(kicker).themeType(theme.type.label).foregroundStyle(.theme(\.surface.softInk))
                Text(title).themeType(theme.pageType.pageTitle).foregroundStyle(.theme(\.color.foreground))
                    .lineLimit(1).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).themeType(theme.type.body).foregroundStyle(.theme(\.color.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.m)
            HStack(spacing: 10) { actions }
        }
    }
}

/// Section heading with a trailing slot for a count, a state or an action.
struct SectionHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Text(title).themeType(theme.pageType.groupTitle).foregroundStyle(.theme(\.color.foreground))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Quiet supporting text beside a heading or under a control.
struct MetaText: View {
    let text: String
    var monospaced = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .themeType(monospaced ? theme.type.mono : theme.pageType.meta)
            .foregroundStyle(.theme(\.color.secondary))
    }
}

// MARK: - Marks and tags

/// Square symbol mark for a host, client, pane or panel heading.
struct IconTile: View {
    let symbol: String
    var tone: Tone = .neutral
    /// The tile's side in black glass. Other themes scale it by their row-icon size.
    var size: CGFloat = 37
    @Environment(\.theme) private var theme

    var body: some View {
        let side = (size * theme.space.rowIcon / Theme.blackGlass.space.rowIcon).rounded()
        let shape = RoundedRectangle(cornerRadius: min(Radius.avatar, theme.radius.control), style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: side * 0.42))
            .foregroundStyle(.theme(tone.role))
            .frame(width: side, height: side)
            .background(theme.surface.markFill.color, in: shape)
            .overlay { shape.strokeBorder(.theme(\.surface.markEdge)) }
            .accessibilityHidden(true)
    }
}

/// Bordered monospaced tag for a branch, worktree or rule value.
struct ValueTag: View {
    var symbol: String? = "arrow.triangle.branch"
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.chip)
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: theme.type.fingerprint.size)).foregroundStyle(.theme(\.color.secondary))
            }
            Text(text).themeType(theme.type.mono).foregroundStyle(.theme(\.surface.softInk)).lineLimit(1)
        }
        .padding(.horizontal, Space.s)
        .frame(height: theme.space.chipHeightMax)
        .background(theme.surface.tagFill.color, in: shape)
        .overlay { shape.strokeBorder(.theme(\.surface.tagEdge)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - Choices and filters

/// One filter clause: a capsule that names the current value and opens its options.
struct FilterChip: View {
    let name: String
    let symbol: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    if option == selection { Label(option, systemImage: "checkmark") } else { Text(option) }
                }
            }
        } label: {
            Label(selection, systemImage: symbol)
        }
        .filterChipFrame()
        .accessibilityLabel("\(name): \(selection)")
    }
}

/// The frame of a filter clause: the menu label in the theme's filter shape.
struct FilterChipFrame: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = theme.controlShape
        content
            .menuStyle(.borderlessButton)
            .fixedSize()
            .themeType(theme.type.sub)
            .foregroundStyle(.theme(\.surface.softInk))
            .padding(.horizontal, Space.m - 1)
            .frame(height: theme.space.controlHeight)
            .background(theme.surface.chipFill.color, in: shape)
            .overlay { shape.strokeBorder(.theme(\.surface.controlEdge)).allowsHitTesting(false) }
    }
}

extension View {
    func filterChipFrame() -> some View { modifier(FilterChipFrame()) }
}

/// Selected-state surface for a row or card that can be chosen from a set.
struct SelectionCard: ViewModifier {
    let isSelected: Bool
    /// The most the card may round. The theme's tile radius caps it.
    var radius: CGFloat = Radius.field
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(radius, theme.radius.tile), style: .continuous)
        content
            .background {
                if isSelected {
                    shape.fill(theme.surface.selectedFill.style)
                } else {
                    shape.fill(theme.surface.unselectedFill.color)
                }
            }
            .overlay(alignment: .leading) {
                // The selection marker the tab bar uses, on the leading edge.
                if isSelected, theme.line.selectedMarker > 0 {
                    Rectangle().fill(.theme(\.color.focus)).frame(width: theme.line.selectedMarker)
                }
            }
            .clipShape(shape)
            .overlay {
                if isSelected {
                    shape.strokeBorder(.theme(\.surface.selectedEdge))
                } else {
                    shape.strokeBorder(.theme(\.surface.unselectedEdge))
                }
            }
            .contentShape(shape)
    }
}

extension View {
    func selectionCard(_ isSelected: Bool, radius: CGFloat = Radius.field) -> some View {
        modifier(SelectionCard(isSelected: isSelected, radius: radius))
    }
}

/// Check box with a label, for including an item in a set.
struct CheckToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(isOn ? Palette.focus : Palette.field)
                RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? Palette.focus : Palette.fieldBorder)
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.onAccent)
                }
            }
            .frame(width: 17, height: 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Included" : "Not included")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Search field with a clear button.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var isFocused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: theme.type.body.size)).foregroundStyle(.theme(\.color.secondary))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).themeType(theme.type.data)
                .foregroundStyle(.theme(\.color.foreground))
                .focused($isFocused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                SymbolButton(symbol: "xmark", label: "Clear search", size: 10) { text = "" }
                    .foregroundStyle(.theme(\.color.secondary))
            }
        }
        .themeField(focused: isFocused)
    }
}

// MARK: - Explanations and evidence

/// Boxed note with a symbol, a statement and its consequence.
struct Callout: View {
    let symbol: String
    let title: String
    let detail: String
    var tone: Tone = .working
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol).font(.system(size: theme.type.title.size, weight: .medium))
                .foregroundStyle(.theme(tone.role)).padding(.top, 1)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).themeType(theme.type.title).foregroundStyle(.theme(\.color.foreground))
                Text(detail).themeType(theme.type.sub).lineSpacing(3).foregroundStyle(.theme(\.color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l - 1).padding(.vertical, Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tone == .attention ? theme.surface.attentionFill : theme.color.well).color, in: shape)
        .overlay {
            if tone == .attention {
                shape.strokeBorder(.theme(\.surface.attentionEdge))
            } else {
                shape.strokeBorder(.theme(\.color.hair))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One verified (or failed) fact with the evidence for it.
struct EvidenceRow: View {
    let title: String
    let detail: String
    var passed = true

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: passed ? "checkmark" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(passed ? Palette.working : Palette.failure)
                .frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(passed ? "Verified" : "Failed"): \(title). \(detail)")
    }
}

/// A setting: what it does on the left, its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                Text(detail).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
            }
            Spacer(minLength: Space.m)
            control
        }
        .padding(.horizontal, theme.space.sectionInset)
        .padding(.top, theme.space.bandTop).padding(.bottom, theme.space.bandBottom)
    }
}

/// Label over a value, for a compact metadata strip.
struct FactColumn: View {
    let label: String
    let value: String
    var monospaced = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ThemeHeading(text: label)
            Text(value)
                .themeType(monospaced ? theme.type.mono : theme.type.data)
                .foregroundStyle(.theme(\.color.foreground)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Symbol tile with a kicker and a title, heading an inspector card.
struct PanelTitle: View {
    let symbol: String
    let kicker: String
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 5) {
                ThemeHeading(text: kicker)
                Text(title).themeType(theme.pageType.groupTitle)
                    .foregroundStyle(.theme(\.color.foreground)).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Passive console snapshot for an overview tile. It shows a few recent lines and accepts no input;
/// the worker's live terminal is the TerminalWell on its own tile.
struct ConsolePreview: View {
    struct Line: Identifiable, Equatable {
        enum Kind { case label, text, command, quiet, wait, good }
        let id: Int
        let kind: Kind
        let text: String
    }

    let lines: [Line]

    static func make(_ items: [(Line.Kind, String)]) -> [Line] {
        items.enumerated().map { Line(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(line.kind == .label ? .system(size: 10, design: .monospaced) : .system(size: 12, design: .monospaced))
                    .tracking(line.kind == .label ? 0.8 : 0)
                    .foregroundStyle(color(for: line.kind))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.well)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Console preview. " + lines.map(\.text).joined(separator: ". "))
    }

    private func color(for kind: Line.Kind) -> Color {
        switch kind {
        case .label, .quiet: Palette.terminalDim
        case .text: Palette.terminalText
        case .command: Color(hex: 0xC9D3F2)
        case .wait: Palette.attention
        case .good: Color(hex: 0xA5D7B6)
        }
    }
}

// MARK: - Sheet pieces

/// A value chosen from several options, in the field shape.
struct MenuField: View {
    let name: String
    var symbol: String? = nil
    let options: [String]
    @Binding var selection: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: theme.type.body.size - 1)).foregroundStyle(.theme(\.color.secondary))
            }
            Menu {
                ForEach(options, id: \.self) { option in
                    Button { selection = option } label: {
                        if option == selection { Label(option, systemImage: "checkmark") } else { Text(option) }
                    }
                }
            } label: {
                Text(selection)
            }
            .menuStyle(.borderlessButton)
            .themeType(theme.type.body)
            .foregroundStyle(.theme(\.color.foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .themeField()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name): \(selection)")
    }
}

/// Titled group of a form or review, separated from the next by a hairline.
struct FormSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: title) { trailing }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Footer of a task sheet: what the action applies to, then the actions.
struct SheetFooter<Actions: View>: View {
    let symbol: String
    let note: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Label(note, systemImage: symbol).font(.system(size: 12.5)).foregroundStyle(.inkSecondary).lineLimit(1)
            Spacer(minLength: 12)
            actions
        }
    }
}

/// Inspector card surface for the aside of a task sheet.
struct InspectorCard: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, theme.space.sectionInset).padding(.vertical, theme.space.sectionInset + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themePanel()
    }
}

extension View {
    func inspectorCard() -> some View { modifier(InspectorCard()) }
}

/// Multi-line text input in the field shape.
struct TextArea: View {
    let label: String
    @Binding var text: String
    var height: CGFloat = 92
    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.foreground)
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(height: height)
            .background(Palette.field, in: shape)
            .overlay { shape.strokeBorder(isFocused ? Palette.focus : Palette.fieldBorder, lineWidth: isFocused ? 1.5 : 1) }
            .focused($isFocused)
            .accessibilityLabel(label)
    }
}

/// An action that exists but cannot be used now, with the reason available on hover and to VoiceOver.
struct UnavailableAction: View {
    let title: String
    var symbol = "lock"
    let reason: String

    var body: some View {
        Button {} label: { Label(title, systemImage: symbol) }
            .buttonStyle(CapsuleButtonStyle())
            .disabled(true)
            .help(reason)
            .accessibilityLabel(title)
            .accessibilityHint("Unavailable. \(reason)")
    }
}

/// Text with every occurrence of a search term highlighted.
struct HighlightedText: View {
    let text: String
    let term: String
    var monospaced = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(attributed)
            .themeType(monospaced ? theme.type.mono : theme.type.sub)
            .foregroundStyle(.theme(\.surface.softInk))
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return result }
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart...].range(of: needle, options: .caseInsensitive) {
            result[range].swiftUI.backgroundColor = theme.surface.highlightFill.color
            result[range].swiftUI.foregroundColor = theme.surface.highlightInk.color
            searchStart = range.upperBound
        }
        return result
    }
}
