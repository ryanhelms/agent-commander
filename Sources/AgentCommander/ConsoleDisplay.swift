import SwiftUI
import Foundation

// MARK: - Mode + shared presentation state

enum ConsoleDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case console
    case pretty

    var id: String { rawValue }
    var title: String { self == .console ? "Console" : "Pretty" }
    var symbol: String { self == .console ? "terminal" : "text.bubble" }
}

/// Launch-scoped presentation state. One instance, owned by the App, shared by every projection
/// (wall tile, focused tile, coordinator, inspector, PiP). Never persisted, never touches services.
@MainActor
@Observable
final class ConsoleModeStore {
    private(set) var globalMode: ConsoleDisplayMode = .console
    /// Keyed by stable worker/coordinator ID. Only holds values that differ from `globalMode`.
    private(set) var overrides: [String: ConsoleDisplayMode] = [:]
    private(set) var expandedTools: Set<String> = []

    init() {}

    var isMixed: Bool { !overrides.isEmpty }
    var overrideCount: Int { overrides.count }

    func mode(for consoleID: String) -> ConsoleDisplayMode {
        overrides[consoleID] ?? globalMode
    }

    func hasOverride(for consoleID: String) -> Bool {
        overrides[consoleID] != nil
    }

    /// Per-console choice. Choosing the global value returns the console to following global.
    func setMode(_ mode: ConsoleDisplayMode, for consoleID: String) {
        if mode == globalMode {
            overrides[consoleID] = nil
        } else {
            overrides[consoleID] = mode
        }
    }

    func clearOverride(for consoleID: String) {
        overrides[consoleID] = nil
    }

    /// Global choice for current and future IDs. Always clears overrides, including when
    /// re-applying the value that is already global.
    func applyGlobal(_ mode: ConsoleDisplayMode) {
        globalMode = mode
        overrides.removeAll()
    }

    func isToolExpanded(console consoleID: String, entry entryID: String) -> Bool {
        expandedTools.contains(Self.toolKey(consoleID, entryID))
    }

    func toggleTool(console consoleID: String, entry entryID: String) {
        let key = Self.toolKey(consoleID, entryID)
        if expandedTools.contains(key) {
            expandedTools.remove(key)
        } else {
            expandedTools.insert(key)
        }
    }

    private static func toolKey(_ consoleID: String, _ entryID: String) -> String {
        consoleID + "\u{1F}" + entryID
    }
}

// MARK: - Mode switch (wraps the existing Console branch untouched)

enum PrettyDensity: Sendable {
    case regular   // coordinator, focused worker
    case compact   // wall tile, inspector
    case pip       // floating attention stack
}

/// Wrap the existing scrollback `if/else` chain in this. In Console mode, or when Pretty has
/// nothing to show, the closure is rendered as-is, so existing task/wait affordances remain.
struct ConsoleScrollback<ConsoleContent: View>: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?

    private let consoleID: String
    private let entries: [TranscriptEntry]
    private let rawOutput: String
    private let density: PrettyDensity
    private let horizontalInset: CGFloat
    private let console: () -> ConsoleContent

    init(
        consoleID: String,
        entries: [TranscriptEntry],
        rawOutput: String = "",
        density: PrettyDensity,
        horizontalInset: CGFloat = 12,
        @ViewBuilder console: @escaping () -> ConsoleContent
    ) {
        self.consoleID = consoleID
        self.entries = entries
        self.rawOutput = rawOutput
        self.density = density
        self.horizontalInset = horizontalInset
        self.console = console
    }

    var body: some View {
        if (modes?.mode(for: consoleID) ?? .console) == .pretty,
           PrettyContent.isPresentable(entries: entries, rawOutput: rawOutput) {
            PrettyConsoleView(
                consoleID: consoleID,
                entries: entries,
                rawOutput: rawOutput,
                density: density,
                horizontalInset: horizontalInset
            )
        } else {
            console()
        }
    }
}

enum PrettyContent {
    static func isPresentable(entries: [TranscriptEntry], rawOutput: String) -> Bool {
        if entries.isEmpty { return !isBlank(rawOutput) }
        return entries.contains(where: isSubstantive)
    }

    static func isSubstantive(_ entry: TranscriptEntry) -> Bool {
        switch entry.kind {
        case .prose(let text, _): return !isBlank(text)
        case .tool: return true
        case .output(let result): return result.hasText
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        !text.contains { !$0.isWhitespace }
    }
}

// MARK: - Pretty renderer

struct PrettyConsoleView: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @State private var localExpanded: Set<String> = []

    let consoleID: String
    let entries: [TranscriptEntry]
    let rawOutput: String
    let density: PrettyDensity
    var horizontalInset: CGFloat = 12

    var body: some View {
        let metrics = PrettyMetrics(density)
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: metrics.turnSpacing) {
                if entries.isEmpty {
                    PrettyRawBlock(text: rawOutput, metrics: metrics, showsCaption: true)
                } else {
                    ForEach(entries.filter(PrettyContent.isSubstantive)) { entry in
                        row(entry, metrics: metrics)
                    }
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, metrics.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
        .textSelection(.enabled)
        .tint(Palette.focus)
    }

    @ViewBuilder
    private func row(_ entry: TranscriptEntry, metrics: PrettyMetrics) -> some View {
        switch entry.kind {
        case .prose(let text, let fromUser):
            if fromUser {
                PrettyUserTurn(text: text, metrics: metrics)
            } else {
                PrettyAssistantTurn(text: text, metrics: metrics)
            }
        case .tool(let name, let detail, let result):
            TranscriptToolRow(
                name: name,
                detail: detail,
                result: result,
                isExpanded: isExpanded(entry.id),
                fontSize: metrics.toolSize,
                toggle: { toggle(entry.id) }
            )
        case .output(let result):
            // A failed result without its call: the shared status line, then any output.
            if result.error != nil {
                ToolResultStatusLine(result: result, fontSize: metrics.toolSize)
            }
            if result.output.contains(where: { !$0.isWhitespace }) {
                PrettyRawBlock(text: result.output, metrics: metrics, showsCaption: false)
            }
        }
    }

    private func isExpanded(_ entryID: String) -> Bool {
        if let modes { return modes.isToolExpanded(console: consoleID, entry: entryID) }
        return localExpanded.contains(entryID)
    }

    private func toggle(_ entryID: String) {
        if let modes {
            modes.toggleTool(console: consoleID, entry: entryID)
        } else if localExpanded.contains(entryID) {
            localExpanded.remove(entryID)
        } else {
            localExpanded.insert(entryID)
        }
    }
}

// MARK: - Metrics

private struct PrettyMetrics {
    let density: PrettyDensity
    let body: Font
    let codeSize: CGFloat
    let toolSize: CGFloat
    let turnSpacing: CGFloat
    let blockSpacing: CGFloat
    let lineSpacing: CGFloat
    let verticalInset: CGFloat
    let userGutter: CGFloat
    let readingWidth: CGFloat = 720
    let listIndent: CGFloat = 16
    let markerWidth: CGFloat = 16

    init(_ density: PrettyDensity) {
        self.density = density
        switch density {
        case .regular:
            body = .body
            codeSize = 12
            toolSize = 12
            turnSpacing = 14
            blockSpacing = 9
            lineSpacing = 3.5
            verticalInset = 12
            userGutter = 48
        case .compact:
            body = .callout
            codeSize = 11
            toolSize = 11
            turnSpacing = 10
            blockSpacing = 7
            lineSpacing = 2.5
            verticalInset = 10
            userGutter = 24
        case .pip:
            body = .subheadline
            codeSize = 10
            toolSize = 10
            turnSpacing = 6
            blockSpacing = 4
            lineSpacing = 1.5
            verticalInset = 6
            userGutter = 16
        }
    }

    var wrapsCode: Bool { density != .regular }

    func heading(_ level: Int) -> Font {
        switch (density, level) {
        case (.regular, 1): return .title3.weight(.semibold)
        case (.regular, 2): return .headline
        case (.compact, 1): return .headline
        default: return body.weight(.semibold)
        }
    }
}

// MARK: - Surfaces (contrast / transparency aware)

private struct PrettySurface: ViewModifier {
    enum Role { case userTurn, code, raw }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let role: Role
    let radius: CGFloat

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill, in: shape)
            .overlay {
                if role != .userTurn || increased || reduceTransparency {
                    shape.strokeBorder(
                        increased ? Palette.foreground.opacity(0.6) : Palette.border,
                        lineWidth: increased ? 1.5 : 1
                    )
                }
            }
    }

    private var fill: Color {
        switch role {
        case .userTurn: return reduceTransparency ? Palette.panel : Palette.controlFill
        case .code: return Palette.well
        case .raw: return Palette.panel
        }
    }
}

// MARK: - Turns

private struct PrettyUserTurn: View {
    let text: String
    let metrics: PrettyMetrics

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: metrics.userGutter)
            Text(verbatim: text.trimmingCharacters(in: .newlines))
                .font(metrics.body)
                .lineSpacing(metrics.lineSpacing)
                .foregroundStyle(Palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, metrics.density == .pip ? 8 : 11)
                .padding(.vertical, metrics.density == .pip ? 4 : 7)
                .modifier(PrettySurface(role: .userTurn, radius: metrics.density == .pip ? 8 : 11))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Prompt: \(text)")
    }
}

private struct PrettyAssistantTurn: View {
    let text: String
    let metrics: PrettyMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.blockSpacing) {
            ForEach(PrettyMarkdownCache.shared.blocks(for: text)) { block in
                PrettyBlockView(block: block, metrics: metrics)
            }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
    }
}

// MARK: - Markdown blocks

private struct PrettyBlock: Identifiable {
    enum Content {
        case text(AttributedString, headingLevel: Int?)
        case code(String, language: String?)
        case table(rows: [[AttributedString]], hasHeader: Bool)
        case rule
    }

    let id: Int
    var content: Content
    var listDepth: Int = 0
    var marker: String? = nil
    var quoted: Bool = false
}

private struct PrettyBlockView: View {
    let block: PrettyBlock
    let metrics: PrettyMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if block.listDepth > 0 {
                Text(verbatim: block.marker ?? "")
                    .font(metrics.body)
                    .monospacedDigit()
                    .foregroundStyle(.inkSecondary)
                    .frame(minWidth: metrics.markerWidth, alignment: .trailing)
                    .accessibilityHidden(block.marker == nil)
            }
            content
        }
        .padding(.leading, leadingInset)
        .overlay(alignment: .leading) {
            if block.quoted {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.border)
                    .frame(width: 2)
            }
        }
    }

    private var leadingInset: CGFloat {
        CGFloat(max(block.listDepth - 1, 0)) * metrics.listIndent + (block.quoted ? 10 : 0)
    }

    @ViewBuilder
    private var content: some View {
        switch block.content {
        case .text(let string, let headingLevel):
            Text(string)
                .font(headingLevel.map { metrics.heading($0) } ?? metrics.body)
                .lineSpacing(metrics.lineSpacing)
                .foregroundStyle(block.quoted ? Palette.secondary : Palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, headingLevel == nil ? 0 : metrics.blockSpacing * 0.5)
                .accessibilityAddTraits(headingLevel == nil ? [] : .isHeader)
        case .code(let code, let language):
            PrettyCodeBlock(code: code, language: language, metrics: metrics)
        case .table(let rows, let hasHeader):
            PrettyTable(rows: rows, hasHeader: hasHeader, metrics: metrics)
        case .rule:
            Divider()
        }
    }
}

private struct PrettyCodeBlock: View {
    let code: String
    let language: String?
    let metrics: PrettyMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(verbatim: language)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.inkSecondary)
                    .textSelection(.disabled)
            }
            if metrics.wrapsCode {
                codeText
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal) {
                    codeText
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(.horizontal, metrics.density == .pip ? 7 : 10)
        .padding(.vertical, metrics.density == .pip ? 5 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PrettySurface(role: .code, radius: 7))
    }

    private var codeText: some View {
        Text(verbatim: code)
            .font(Term.font(metrics.codeSize))
            .lineSpacing(2)
            .foregroundStyle(Palette.foreground)
    }
}

private struct PrettyTable: View {
    let rows: [[AttributedString]]
    let hasHeader: Bool
    let metrics: PrettyMetrics

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(index == 0 && hasHeader ? metrics.body.weight(.semibold) : metrics.body)
                            .foregroundStyle(Palette.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index == 0 && hasHeader {
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Markdown parsing (Foundation, full syntax)

private enum PrettyMarkdown {
    static func parse(_ source: String) -> [PrettyBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            return [PrettyBlock(id: 0, content: .text(AttributedString(source), headingLevel: nil))]
        }

        var blocks: [PrettyBlock] = []
        var lastListItem: Int?
        var openTable: (id: Int, rowKey: Int)?

        for (intent, range) in attributed.runs[\.presentationIntent] {
            var headingLevel: Int?
            var listDepth = 0
            var nearestListOrdered: Bool?
            var itemOrdinal: Int?
            var itemIdentity: Int?
            var isCode = false
            var language: String?
            var quoted = false
            var isRule = false
            var tableID: Int?
            var rowKey = 0
            var column = 0

            // Components are ordered innermost first.
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    headingLevel = level
                case .orderedList:
                    listDepth += 1
                    if nearestListOrdered == nil { nearestListOrdered = true }
                case .unorderedList:
                    listDepth += 1
                    if nearestListOrdered == nil { nearestListOrdered = false }
                case .listItem(let ordinal):
                    if itemIdentity == nil {
                        itemOrdinal = ordinal
                        itemIdentity = component.identity
                    }
                case .codeBlock(let hint):
                    isCode = true
                    language = hint
                case .blockQuote:
                    quoted = true
                case .thematicBreak:
                    isRule = true
                case .table:
                    tableID = component.identity
                case .tableHeaderRow:
                    rowKey = -1
                case .tableRow(let rowIndex):
                    rowKey = rowIndex
                case .tableCell(let columnIndex):
                    column = columnIndex
                default:
                    break
                }
            }

            let slice = attributed[range]

            if let tableID {
                let cell = AttributedString(slice)
                if openTable?.id == tableID,
                   let last = blocks.indices.last,
                   case .table(var rows, let hasHeader) = blocks[last].content {
                    if openTable?.rowKey == rowKey, !rows.isEmpty {
                        let current = rows[rows.count - 1].count
                        rows[rows.count - 1].append(contentsOf: padding(column - current))
                        rows[rows.count - 1].append(cell)
                    } else {
                        rows.append(padding(column) + [cell])
                    }
                    blocks[last].content = .table(rows: rows, hasHeader: hasHeader || rowKey == -1)
                } else {
                    blocks.append(PrettyBlock(
                        id: blocks.count,
                        content: .table(rows: [padding(column) + [cell]], hasHeader: rowKey == -1)
                    ))
                }
                openTable = (tableID, rowKey)
                lastListItem = nil
                continue
            }
            openTable = nil

            var marker: String?
            if listDepth > 0, let itemIdentity {
                if itemIdentity != lastListItem {
                    marker = nearestListOrdered == true ? "\(itemOrdinal ?? 1)." : "•"
                }
                lastListItem = itemIdentity
            } else {
                lastListItem = nil
            }

            let content: PrettyBlock.Content
            if isRule {
                content = .rule
            } else if isCode {
                var code = String(slice.characters)
                while code.last?.isNewline == true { code.removeLast() }
                content = .code(code, language: language)
            } else {
                if slice.characters.isEmpty { continue }
                content = .text(AttributedString(slice), headingLevel: headingLevel)
            }

            blocks.append(PrettyBlock(
                id: blocks.count,
                content: content,
                listDepth: listDepth,
                marker: marker,
                quoted: quoted
            ))
        }

        if blocks.isEmpty, source.contains(where: { !$0.isWhitespace }) {
            return [PrettyBlock(id: 0, content: .text(AttributedString(source), headingLevel: nil))]
        }
        return blocks
    }

    private static func padding(_ count: Int) -> [AttributedString] {
        Array(repeating: AttributedString(), count: max(0, count))
    }
}

/// Keeps streaming re-renders cheap: unchanged messages are never re-parsed.
@MainActor
private final class PrettyMarkdownCache {
    static let shared = PrettyMarkdownCache()

    private final class Box {
        let blocks: [PrettyBlock]
        init(_ blocks: [PrettyBlock]) { self.blocks = blocks }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    func blocks(for text: String) -> [PrettyBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = PrettyMarkdown.parse(text)
        cache.setObject(Box(blocks), forKey: key, cost: text.utf8.count)
        return blocks
    }
}

// MARK: - Raw / legacy output (no Markdown, no speaker inference)

private struct PrettyRawBlock: View {
    let text: String
    let metrics: PrettyMetrics
    let showsCaption: Bool

    private struct Chunk: Identifiable {
        let id: Int
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.density == .pip ? 3 : 6) {
            if showsCaption {
                Label("Unformatted output", systemImage: "text.alignleft")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.inkSecondary)
                    .textSelection(.disabled)
            }
            LazyVStack(alignment: .leading, spacing: rawLineSpacing) {
                ForEach(chunks) { chunk in
                    Text(verbatim: chunk.text)
                        .font(Term.font(metrics.codeSize))
                        .lineSpacing(rawLineSpacing)
                        .foregroundStyle(Palette.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, metrics.density == .pip ? 7 : 11)
        .padding(.vertical, metrics.density == .pip ? 5 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PrettySurface(role: .raw, radius: 8))
    }

    private var rawLineSpacing: CGFloat { metrics.density == .pip ? 1.5 : 3 }

    /// Lines are kept verbatim; chunking only bounds the size of each Text for long scrollback.
    private var chunks: [Chunk] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        let size = 80
        return stride(from: 0, to: lines.count, by: size).map { start in
            Chunk(id: start, text: lines[start..<min(start + size, lines.count)].joined(separator: "\n"))
        }
    }
}

// MARK: - Per-console titlebar control

/// Compact titlebar menu. Outline icon = following global; filled, tinted icon = overridden.
struct ConsoleModeTitlebarControl: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?

    let consoleID: String
    let consoleName: String
    let client: AgentClient
    var showsTitle = false
    /// Present when this console's worker has a provider source. The menu then offers the source
    /// inspector, in either display mode, and a console that hosts the inspector presents it here.
    var source: ConsoleSourceAccess? = nil

    var body: some View {
        let mode = modes?.mode(for: consoleID) ?? .console
        let overridden = modes?.hasOverride(for: consoleID) ?? false
        let scope = overridden ? "this console only" : "following all consoles"
        // Title-bar control ink at rest; the focus colour while this console overrides the mode.
        let ink = ConsoleHeaderControlInk(active: overridden ? Palette.focus : nil)
        // Semibold, the weight of the action glyph beside it: the regular symbol was too thin to find.
        let glyph = Image(systemName: mode.symbol).fontWeight(.semibold)

        Menu {
            ConsoleModeMenuItems(modes: modes, consoleID: consoleID)
            if let source {
                Divider()
                ConsoleSourceMenuItems(source: source)
            }
            Divider()
            HarnessAccentMenu(client: client)
        } label: {
            // Colour is set inside the label: a menu's button style on macOS replaces a foreground
            // style applied from outside with its own control tint.
            Group {
                if showsTitle {
                    Label { Text(mode.title) } icon: { glyph }
                        .labelStyle(.titleAndIcon)
                } else {
                    glyph
                }
            }
            .symbolVariant(overridden ? .fill : .none)
            .foregroundStyle(ink)
            // The plain style would shrink the target to the glyph; keep the 23pt square the
            // action menu uses. A titled label is wider and only gains the height.
            .frame(minWidth: 23, minHeight: 23).contentShape(Rectangle())
        }
        .symbolVariant(overridden ? .fill : .none)
        .foregroundStyle(ink)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(modes == nil)
        .help("Display: \(mode.title) — \(scope). Change the display mode or \(client.displayName) accent"
              + (source == nil ? "." : ", or inspect this console's source."))
        .accessibilityLabel("Display mode, \(consoleName)")
        .accessibilityValue("\(mode.title), \(scope)")
        .modifier(ConsoleSourcePresentation(source: source))
    }
}

/// The same items, for embedding in an existing action menu.
struct ConsoleModeMenuItems: View {
    let modes: ConsoleModeStore?
    let consoleID: String

    var body: some View {
        if let modes {
            Section("Display — This Console") {
                ForEach(ConsoleDisplayMode.allCases) { mode in
                    Toggle(isOn: Binding(
                        get: { modes.mode(for: consoleID) == mode },
                        set: { _ in modes.setMode(mode, for: consoleID) }
                    )) {
                        Label(mode.title, systemImage: mode.symbol)
                    }
                }
            }
            Button("Follow All Consoles (\(modes.globalMode.title))") {
                modes.clearOverride(for: consoleID)
            }
            .disabled(!modes.hasOverride(for: consoleID))
        }
    }
}

// MARK: - Global toolbar control

struct ConsoleModeToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            ConsoleModeGlobalMenu()
        }
    }
}

struct ConsoleModeGlobalMenu: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?

    var body: some View {
        let mixed = modes?.isMixed ?? false
        let global = modes?.globalMode ?? .console
        let stateTitle = mixed ? "Mixed" : global.title

        Menu {
            if let modes {
                Section(mixed
                        ? "All Consoles — Mixed (\(modes.overrideCount) overridden)"
                        : "All Consoles") {
                    ForEach(ConsoleDisplayMode.allCases) { mode in
                        // Fires on every click, so re-applying the current choice clears overrides.
                        Toggle(isOn: Binding(
                            get: { !modes.isMixed && modes.globalMode == mode },
                            set: { _ in modes.applyGlobal(mode) }
                        )) {
                            Label("\(mode.title) for All", systemImage: mode.symbol)
                        }
                    }
                }
            }
        } label: {
            Label("Display: \(stateTitle)", systemImage: mixed ? "rectangle.split.2x1" : global.symbol)
                .labelStyle(.titleAndIcon)
        }
        .disabled(modes == nil)
        .help(mixed
              ? "Console display is mixed. Choose a mode to apply it to all consoles and clear overrides."
              : "Display mode for all consoles: \(global.title)")
        .accessibilityLabel("Display mode, all consoles")
        .accessibilityValue(stateTitle)
    }
}
