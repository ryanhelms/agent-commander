import SwiftUI

// ATOMIC LEVEL: Molecules (workspace, delegation and setup views).
// Small combinations used by more than one page outside the coordinator split. They take values
// and emit targeted actions like the cockpit molecules, and reuse the same atoms and tokens.

// MARK: - Headings

/// Page heading: where the page sits, its name, a sentence about it, and its primary actions.
struct PageHeader<Actions: View>: View {
    let kicker: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(kicker).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xD5D9E5))
                Text(title).font(TypeRole.pageTitle).tracking(-1.1).foregroundStyle(Palette.foreground)
                    .lineLimit(1).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(TypeRole.body).foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) { actions }
        }
    }
}

/// Section heading with a trailing slot for a count, a state or an action.
struct SectionHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(TypeRole.section).tracking(-0.4).foregroundStyle(Palette.foreground)
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

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .foregroundStyle(.inkSecondary)
    }
}

// MARK: - Marks and tags

/// Square symbol mark for a host, client, pane or panel heading.
struct IconTile: View {
    let symbol: String
    var tone: Tone = .neutral
    var size: CGFloat = 37

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.avatar, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.42))
            .foregroundStyle(tone.color)
            .frame(width: size, height: size)
            .background(Palette.chrome, in: shape)
            .overlay { shape.strokeBorder(.inkHairline) }
            .accessibilityHidden(true)
    }
}

/// Bordered monospaced tag for a branch, worktree or rule value.
struct ValueTag: View {
    var symbol: String? = "arrow.triangle.branch"
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.inkSecondary) }
            Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color(hex: 0xDCE0EA)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(hex: 0x16171E), in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(hex: 0x3C404E)) }
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12.5))
        .foregroundStyle(Color(hex: 0xE3E5EE))
        .padding(.horizontal, 11)
        .frame(height: 31)
        .background(Color(hex: 0x1A1B22), in: Capsule())
        .overlay { Capsule().strokeBorder(Palette.controlEdge).allowsHitTesting(false) }
        .accessibilityLabel("\(name): \(selection)")
    }
}

/// Selected-state surface for a row or card that can be chosen from a set.
struct SelectionCard: ViewModifier {
    let isSelected: Bool
    var radius: CGFloat = Radius.field

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if isSelected {
                    shape.fill(LinearGradient(colors: [Color(hex: 0x293344), Color(hex: 0x19212C)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(Palette.field.opacity(0.55))
                }
            }
            .overlay { shape.strokeBorder(isSelected ? Color(hex: 0x8BA3C4) : Palette.hairline) }
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.inkSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                .focused($isFocused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                SymbolButton(symbol: "xmark", label: "Clear search", size: 10) { text = "" }
                    .foregroundStyle(.inkSecondary)
            }
        }
        .fieldBox(focused: isFocused, height: 42)
    }
}

// MARK: - Explanations and evidence

/// Boxed note with a symbol, a statement and its consequence.
struct Callout: View {
    let symbol: String
    let title: String
    let detail: String
    var tone: Tone = .working

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(tone.color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text(detail).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .attention ? Palette.attentionFill : Palette.well, in: shape)
        .overlay { shape.strokeBorder(tone == .attention ? Palette.attentionSoftEdge : Palette.hairline) }
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

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 25).padding(.vertical, 22)
    }
}

/// Label over a value, for a compact metadata strip.
struct FactColumn: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: label)
            Text(value)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.foreground).lineLimit(1).truncationMode(.middle)
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

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 5) {
                Kicker(text: kicker)
                Text(title).font(TypeRole.section).tracking(-0.4).foregroundStyle(Palette.foreground).lineLimit(2)
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

    var body: some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.inkSecondary) }
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
            .font(TypeRole.body)
            .foregroundStyle(Palette.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fieldBox()
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
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 25).padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface()
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

    var body: some View {
        Text(attributed)
            .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
            .foregroundStyle(Color(hex: 0xE1E4EE))
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return result }
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart...].range(of: needle, options: .caseInsensitive) {
            result[range].swiftUI.backgroundColor = Color(hex: 0x4A4630)
            result[range].swiftUI.foregroundColor = Color(hex: 0xF4E7B2)
            searchStart = range.upperBound
        }
        return result
    }
}
