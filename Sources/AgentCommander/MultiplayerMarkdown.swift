import SwiftUI

// ATOMIC LEVEL: Molecule for the network tray.
// Text an agent or a friend wrote in Markdown, drawn in the tray's own type: a hand-off's report,
// a shared knowledge item. It reads headings, paragraphs, bullet and numbered lists, fenced code
// and rules, with bold, italic, inline code and links inside a line. Anything else stays as the
// text it was. Nothing is fetched: an image is left as its source text.
//   Values:    MultiplayerMarkdownBlock, MultiplayerMarkdownParser
//   Molecule:  MultiplayerMarkdown

/// One block of a Markdown text.
enum MultiplayerMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A run of list items. `ordered` keeps each item's own number.
    case list(ordered: Bool, items: [MultiplayerMarkdownItem])
    case code(String)
    case rule
}

struct MultiplayerMarkdownItem: Equatable, Sendable {
    /// "1." for a numbered item; empty for a bullet.
    var marker = ""
    var text: String
    /// How far it is nested: 0 for the outer list.
    var depth = 0
}

enum MultiplayerMarkdownParser {
    /// The most text one view reads. A longer report is cut, and says so.
    static let limit = 64 * 1024

    static func blocks(_ source: String) -> [MultiplayerMarkdownBlock] {
        var blocks: [MultiplayerMarkdownBlock] = []
        var paragraph: [String] = []
        var items: [MultiplayerMarkdownItem] = []
        var ordered = false
        var code: [String]? = nil
        var fence = ""

        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func endList() {
            if !items.isEmpty { blocks.append(.list(ordered: ordered, items: items)) }
            items = []
        }

        let text = source.count > limit ? String(source.prefix(limit)) + "\n\n…" : source
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                endParagraph()
                endList()
                fence = String(trimmed.prefix(3))
                code = []
                continue
            }
            if trimmed.isEmpty {
                endParagraph()
                endList()
                continue
            }
            if let heading = heading(trimmed) {
                endParagraph()
                endList()
                blocks.append(heading)
                continue
            }
            if trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first),
               trimmed.allSatisfy({ $0 == first || $0 == " " }), trimmed.filter({ $0 == first }).count >= 3 {
                endParagraph()
                endList()
                blocks.append(.rule)
                continue
            }
            if let item = item(line) {
                endParagraph()
                let isOrdered = !item.marker.isEmpty
                if !items.isEmpty, item.depth == 0, isOrdered != ordered { endList() }
                if items.isEmpty { ordered = isOrdered }
                items.append(item)
                continue
            }
            // A line under a list item continues it; any other line joins the paragraph.
            if !items.isEmpty, line.first == " " || line.first == "\t" {
                items[items.count - 1].text += " " + trimmed
            } else {
                endList()
                paragraph.append(trimmed)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        endParagraph()
        endList()
        return blocks
    }

    private static func heading(_ line: String) -> MultiplayerMarkdownBlock? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        var text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        // A closing run of hashes is decoration.
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }

    private static func item(_ line: String) -> MultiplayerMarkdownItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let depth = min(indent / 2, 3)
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : MultiplayerMarkdownItem(text: text, depth: depth)
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        let rest = body.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 4, let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : MultiplayerMarkdownItem(marker: "\(digits).", text: text, depth: depth)
        }
        return nil
    }

    /// Bold, italic, inline code and links inside one line. Text that doesn't parse is shown as written.
    /// `code` is the face of inline code: the caller's theme's `data` role.
    static func inline(_ text: String, code: Font = Theme.console.type.data.font) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].font = code
        }
        return parsed
    }

    /// One list item as VoiceOver reads it: "1. Read the failing test", or the words alone for a bullet.
    static func spoken(_ item: MultiplayerMarkdownItem) -> String {
        (item.marker.isEmpty ? "" : "\(item.marker) ") + String(inline(item.text).characters)
    }

    /// The text as VoiceOver reads it: no marks, one block per sentence break.
    static func spoken(_ blocks: [MultiplayerMarkdownBlock]) -> String {
        func plain(_ text: String) -> String { String(inline(text).characters) }
        return blocks.compactMap { block -> String? in
            switch block {
            case .heading(_, let text): plain(text)
            case .paragraph(let text): plain(text)
            case .list(_, let items): items.map { ($0.marker.isEmpty ? "" : "\($0.marker) ") + plain($0.text) }.joined(separator: ". ")
            case .code(let text): "Code: \(text)"
            case .rule: nil
            }
        }
        .joined(separator: ". ")
    }
}

/// Markdown drawn with the tray's tokens. Each block is selectable text.
struct MultiplayerMarkdown: View {
    private let blocks: [MultiplayerMarkdownBlock]
    @Environment(\.theme) private var theme

    private func inline(_ text: String) -> AttributedString {
        MultiplayerMarkdownParser.inline(text, code: theme.type.data.font)
    }

    init(text: String) {
        blocks = MultiplayerMarkdownParser.blocks(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let level, let text):
                    VStack(alignment: .leading, spacing: 3) {
                        Text(inline(text))
                            .font(level <= 2 ? .system(size: level == 1 ? 14 : 13, weight: .semibold) : MultiplayerTheme.heading.font(in: theme))
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        // A first- or second-level heading sits on a hairline, like a band heading.
                        if level <= 2 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                    }
                    .padding(.top, index == 0 ? 0 : 4)
                case .paragraph(let text):
                    Text(inline(text))
                        .font(.system(size: 12))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.marker.isEmpty ? "–" : item.marker)
                                    .font(MultiplayerTheme.data)
                                    .foregroundStyle(.inkSecondary)
                                    .frame(minWidth: 14, alignment: .trailing)
                                Text(inline(item.text))
                                    .font(.system(size: 12))
                                    .foregroundStyle(MultiplayerTheme.foreground)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, CGFloat(item.depth) * 14)
                            // One static text per item: its number, then its words.
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isStaticText)
                            .accessibilityLabel(MultiplayerMarkdownParser.spoken(item))
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(ordered ? "Numbered list" : "List"), \(MultiplayerPlural.count(items.count, "item"))")
                case .code(let text):
                    let shape = theme.trayChip
                    ScrollView(.horizontal) {
                        Text(text)
                            .font(MultiplayerTheme.data)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(8)
                    }
                    .scrollIndicators(.never)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MultiplayerTheme.panel, in: shape)
                    .overlay { shape.strokeBorder(MultiplayerTheme.hair) }
                    .accessibilityLabel("Code")
                    .accessibilityValue(text)
                case .rule:
                    Rectangle().fill(MultiplayerTheme.hair).frame(height: 1).accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
