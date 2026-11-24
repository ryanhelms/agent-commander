import AppKit
import SwiftUI
import Foundation

// MARK: - Mode + shared presentation state

enum ConsoleDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// The live native terminal (NativeTerminalSlot), read-only. A console without one shows its
    /// Console transcript.
    case terminal
    case console
    case pretty

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .console: "Console"
        case .pretty: "Pretty"
        }
    }
    var symbol: String {
        switch self {
        case .terminal: "apple.terminal"
        case .console: "terminal"
        case .pretty: "text.bubble"
        }
    }
}

/// Launch-scoped presentation state. One instance, owned by the App, shared by every projection
/// (wall tile, focused tile, coordinator, inspector, PiP). Never persisted, never touches services.
@MainActor
@Observable
final class ConsoleModeStore {
    /// Pretty by default on every fresh launch: an ACP-bound console shows `PrettyACPConsole`, and
    /// any other console its Pretty transcript, or Console when Pretty has nothing to show.
    /// Terminal stays one choice away in the display menus, per console or for all, and the
    /// standalone terminal window does not read this value.
    private(set) var globalMode: ConsoleDisplayMode = .pretty
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

    /// Entries whose fields are open beneath them, by console and entry. Shared by Console and
    /// Pretty, so changing the display mode keeps an open record open.
    private(set) var expandedDetails: Set<String> = []

    func isDetailExpanded(console consoleID: String, entry entryID: String) -> Bool {
        expandedDetails.contains(Self.toolKey(consoleID, entryID))
    }

    func setDetailExpanded(_ expanded: Bool, console consoleID: String, entry entryID: String) {
        let key = Self.toolKey(consoleID, entryID)
        if expanded { expandedDetails.insert(key) } else { expandedDetails.remove(key) }
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
    /// The worker whose live terminal Terminal mode shows. Nil where a console has none (the
    /// queue inspector); Terminal mode then shows the Console transcript.
    private let terminal: NativeTerminalTarget?
    private let console: () -> ConsoleContent

    init(
        consoleID: String,
        entries: [TranscriptEntry],
        rawOutput: String = "",
        density: PrettyDensity,
        horizontalInset: CGFloat = 12,
        terminal: NativeTerminalTarget? = nil,
        @ViewBuilder console: @escaping () -> ConsoleContent
    ) {
        self.consoleID = consoleID
        self.entries = entries
        self.rawOutput = rawOutput
        self.density = density
        self.horizontalInset = horizontalInset
        self.terminal = terminal
        self.console = console
    }

    var body: some View {
        let mode = modes?.mode(for: consoleID) ?? .console
        if mode == .terminal {
            NativeTerminalSlot(target: terminal, density: density, horizontalInset: horizontalInset, fallback: console)
        } else if mode == .pretty,
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

/// The fixed assignment above a console's scrollback. Pretty leaves it out when the conversation
/// below already shows the same instruction as one of the developer's prompts, so it is not read
/// twice. Console, and Pretty's fallback to Console, always show it.
struct ConsoleAssignment<Content: View>: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?

    let consoleID: String
    let assignment: String
    let entries: [TranscriptEntry]
    var rawOutput: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        let pretty = (modes?.mode(for: consoleID) ?? .console) == .pretty
            && PrettyContent.isPresentable(entries: entries, rawOutput: rawOutput)
        if !(pretty && PrettyContent.repeatsAssignment(assignment, in: entries)) {
            content()
        }
    }
}

enum PrettyContent {
    static func isPresentable(entries: [TranscriptEntry], rawOutput: String) -> Bool {
        if entries.isEmpty { return !isBlank(rawOutput) }
        return entries.contains(where: isSubstantive)
    }

    /// True when one of the developer's prompts in `entries` is exactly `assignment`. The whole
    /// prompt is compared as the service sent it, apart from whitespace around it; a prompt whose
    /// reference says it carried media also matches without the service's trailing media
    /// markers, which the developer did not write. A prompt that only contains the assignment,
    /// a reply that quotes it, and any other role never match.
    static func repeatsAssignment(_ assignment: String, in entries: [TranscriptEntry]) -> Bool {
        let wanted = assignment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return entries.contains { entry in
            guard case .prose(let text, fromUser: true) = entry.kind else { return false }
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted { return true }
            guard let media = entry.promptMedia else { return false }
            let shown = media.display(text)
            // A prompt that was only media reads as a caption, which is not the developer's text.
            return shown.removed > 0 && shown.text != media.caption && shown.text == wanted
        }
    }

    static func isSubstantive(_ entry: TranscriptEntry) -> Bool {
        switch entry.kind {
        case .prose(let text, _): return !isBlank(text)
        case .tool: return true
        case .output(let result): return result.hasText
        case .other: return true
        }
    }

    /// Who an entry reads as. A change of speaker opens a new turn; entries of one speaker sit
    /// closer together.
    static func speaker(of entry: TranscriptEntry) -> String {
        switch entry.kind {
        case .prose(_, let fromUser): return fromUser ? "user" : "assistant"
        case .tool, .output: return "assistant"
        // The provider's thinking belongs to the agent's side of the turn.
        case .other(let role, _): return entry.isThought ? "assistant" : role
        }
    }

    /// What a link in agent text may do when the developer clicks it. A web link opens in the
    /// browser. A file link selects the file in Finder when it exists on this Mac, and is never
    /// opened or run. Every other scheme is left alone. Nothing here opens without a click.
    @MainActor static let linkPolicy = OpenURLAction { url in
        switch url.scheme?.lowercased() {
        case "http", "https":
            return .systemAction
        case "file":
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return .handled
        default:
            return .discarded
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        !text.contains { !$0.isWhitespace }
    }
}

// MARK: - Pretty renderer

struct PrettyConsoleView: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @Environment(\.consoleRecordAccess) private var access
    @State private var localExpanded: Set<String> = []

    let consoleID: String
    let entries: [TranscriptEntry]
    let rawOutput: String
    let density: PrettyDensity
    var horizontalInset: CGFloat = 12
    /// The open tool call of a worker waiting for the developer's reply, which reads as awaiting
    /// approval. Nil everywhere else, so every call keeps the status its result gives it.
    var awaitingToolID: String? = nil

    var body: some View {
        let metrics = PrettyMetrics(density)
        // A streamed reply is one turn, as it is in Console. Pretty then sets adjacent routine
        // entries (usage, session state, harness diagnostics) close together as activity lines in
        // their place, each visible; every other entry is laid out as it is, in order.
        let shown = ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty))
        ScrollView(.vertical) {
            // One conversation column. It fills a tile, and stops widening in a broad console so
            // a prompt stays within reach of the answer beneath it.
            LazyVStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    PrettyRawBlock(text: rawOutput, metrics: metrics, caption: "Unformatted output")
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        Group {
                            switch item {
                            case .entry(let entry):
                                row(entry, metrics: metrics)
                            case .activity(let activity):
                                PrettyActivityRun(activity: activity, metrics: metrics) { entry in
                                    row(entry, metrics: metrics)
                                }
                            }
                        }
                        .padding(.top, index == 0 ? 0 : spacing(before: item, after: shown[index - 1], metrics: metrics))
                    }
                }
            }
            .frame(maxWidth: metrics.columnWidth, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, metrics.verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
        .textSelection(.enabled)
        .tint(Palette.focus)
        .environment(\.openURL, PrettyContent.linkPolicy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    private func spacing(before item: ConversationItem, after previous: ConversationItem, metrics: PrettyMetrics) -> CGFloat {
        guard case .entry(let entry) = item, case .entry(let earlier) = previous else {
            // An activity is a quiet line between turns: nearer than a change of speaker.
            return (metrics.blockSpacing + metrics.turnSpacing) / 2
        }
        return PrettyContent.speaker(of: entry) == PrettyContent.speaker(of: earlier) ? metrics.blockSpacing : metrics.turnSpacing
    }

    /// A prompt as Pretty shows it. The service's trailing media marker is left out of the bubble
    /// when the prompt's reference says it carried media. The attachment action on the entry then
    /// stands for the media; where no action is drawn, a note beneath the bubble does.
    private func prompt(_ text: String, of entry: TranscriptEntry) -> (text: String, note: String?) {
        guard let media = entry.promptMedia else { return (text, nil) }
        let shown = media.display(text)
        guard shown.removed > 0, shown.text != media.caption else { return (shown.text, nil) }
        var hasAction = false
        if let offer = access?.attachments?.offer(consoleID, entry.id) {
            if case .prompt = offer { hasAction = true } else { hasAction = access?.openSource != nil }
        }
        return (shown.text, hasAction ? nil : media.caption)
    }

    @ViewBuilder
    private func row(_ entry: TranscriptEntry, metrics: PrettyMetrics) -> some View {
        switch entry.kind {
        case .prose(let text, let fromUser):
            if fromUser {
                let shown = prompt(text, of: entry)
                PrettyUserTurn(text: shown.text, attachmentNote: shown.note, metrics: metrics)
                    .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
            } else {
                PrettyAssistantTurn(text: text, metrics: metrics)
                    .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: density != .pip), density: density)
            }
        case .tool(let name, let detail, let result):
            TranscriptToolRow(
                name: name,
                detail: detail,
                result: result,
                isExpanded: isExpanded(entry.id),
                fontSize: metrics.toolSize,
                style: .pretty,
                isAwaitingApproval: entry.id == awaitingToolID,
                toggle: { toggle(entry.id) }
            )
            .frame(maxWidth: metrics.readingWidth, alignment: .leading)
            .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
        case .output(let result):
            // A failed result without its call: the shared status line, then any output.
            VStack(alignment: .leading, spacing: metrics.blockSpacing * 0.5) {
                if result.error != nil {
                    ToolResultStatusLine(result: result, fontSize: metrics.toolSize)
                }
                if result.output.contains(where: { !$0.isWhitespace }) {
                    PrettyRawBlock(text: result.output, metrics: metrics, caption: "Tool result")
                }
            }
            .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
        case .other(let role, let text):
            if entry.isThought {
                PrettyThinkingRow(
                    text: text,
                    metrics: metrics,
                    isExpanded: Binding(
                        get: { isExpanded(entry.id) },
                        set: { if $0 != isExpanded(entry.id) { toggle(entry.id) } }))
                    .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
            } else if let event = ActivityEvent(entry: entry) {
                // A recognised event, or any record with an ACP kind: one visible activity line.
                // It never carries a reply; a pending request is answered only in its form.
                PrettyActivityRow(event: event, metrics: metrics)
                    .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
            } else {
                PrettyRoleNote(role: role, text: text, metrics: metrics)
                    .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
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
    /// Corner radius and padding of the developer's bubble. One line reads as a pill.
    let bubbleRadius: CGFloat
    let bubbleInset: CGSize
    /// Widest line of agent text. Code, tables and tool results may use the whole column.
    let readingWidth: CGFloat = 760
    /// Widest the conversation column grows inside a broad console.
    let columnWidth: CGFloat = 900
    let listIndent: CGFloat = 16
    let markerWidth: CGFloat = 16

    init(_ density: PrettyDensity) {
        self.density = density
        switch density {
        case .regular:
            body = .system(size: 14)
            codeSize = 12
            toolSize = 12
            turnSpacing = 24
            blockSpacing = 10
            lineSpacing = 4.5
            verticalInset = 16
            userGutter = 72
            bubbleRadius = 18
            bubbleInset = CGSize(width: 14, height: 9)
        case .compact:
            body = .system(size: 13)
            codeSize = 11
            toolSize = 11
            turnSpacing = 16
            blockSpacing = 7
            lineSpacing = 3
            verticalInset = 11
            userGutter = 32
            bubbleRadius = 15
            bubbleInset = CGSize(width: 11, height: 7)
        case .pip:
            body = .system(size: 12)
            codeSize = 10
            toolSize = 10
            turnSpacing = 9
            blockSpacing = 4
            lineSpacing = 1.5
            verticalInset = 6
            userGutter = 20
            bubbleRadius = 11
            bubbleInset = CGSize(width: 8, height: 4)
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
                if role != .userTurn || increased {
                    shape.strokeBorder(
                        increased ? Palette.foreground.opacity(0.6) : Palette.border,
                        lineWidth: increased ? 1.5 : 1
                    )
                }
            }
    }

    private var fill: Color {
        switch role {
        case .userTurn: return Palette.userBubble
        case .code: return Palette.well
        case .raw: return Palette.panel
        }
    }
}

// MARK: - Turns

private struct PrettyUserTurn: View {
    let text: String
    /// Says the prompt carried media, on a surface that draws no attachment action for it.
    var attachmentNote: String? = nil
    let metrics: PrettyMetrics

    var body: some View {
        // Right-aligned and as wide as its own text, up to a limit: the developer's side of the
        // conversation. The gutter keeps even a long prompt off the agent's margin.
        VStack(alignment: .trailing, spacing: metrics.density == .pip ? 2 : 4) {
            HStack(spacing: 0) {
                Spacer(minLength: metrics.userGutter)
                Text(verbatim: text.trimmingCharacters(in: .newlines))
                    .font(metrics.body)
                    .lineSpacing(metrics.lineSpacing)
                    .foregroundStyle(Palette.userBubbleInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, metrics.bubbleInset.width)
                    .padding(.vertical, metrics.bubbleInset.height)
                    .modifier(PrettySurface(role: .userTurn, radius: metrics.bubbleRadius))
                    .layoutPriority(1)
            }
            if let attachmentNote {
                Label(attachmentNote, systemImage: "paperclip")
                    .font(.system(size: metrics.toolSize - 1, weight: .medium))
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.disabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)" + (attachmentNote.map { ". \($0)" } ?? ""))
    }
}

/// A run of adjacent routine entries, set close together in their place. Every line is visible:
/// nothing that needs the developer can sit behind a count. Each line is the conversation's own
/// row, so it keeps its source and fields action.
private struct PrettyActivityRun<Row: View>: View {
    let activity: ConversationActivity
    let metrics: PrettyMetrics
    @ViewBuilder let row: (TranscriptEntry) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.density == .pip ? 1 : 3) {
            ForEach(activity.entries) { entry in row(entry) }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(activity.accessibilityLabel)
    }
}

/// One activity line, in the terminal's restrained voice: a small symbol, a short label and the
/// event's readable detail. An event that may need the developer, such as harness stderr or a
/// permission notice, is drawn in the attention ink; the rest are secondary. Details wrap, so
/// nothing is cut; a record with only fields says so and its fields action opens them.
private struct PrettyActivityRow: View {
    let event: ActivityEvent
    let metrics: PrettyMetrics

    var body: some View {
        let size = metrics.codeSize
        let ink: Color = event.tone == .attention ? Palette.attention : Palette.secondary
        HStack(alignment: .firstTextBaseline, spacing: metrics.density == .pip ? 5 : 7) {
            Image(systemName: event.symbol)
                .font(.system(size: size - 1, weight: .medium))
                .foregroundStyle(ink)
                .frame(width: size + 2)
                .accessibilityHidden(true)
            Text(verbatim: event.label)
                .font(Term.font(size, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1).fixedSize()
            Text(verbatim: event.detail.isEmpty ? "fields only" : event.detail)
                .font(Term.font(size))
                .foregroundStyle(event.detail.isEmpty ? AnyShapeStyle(.inkTermDim) : AnyShapeStyle(Term.text))
                .lineSpacing(metrics.density == .pip ? 1 : 2)
                // Never clipped, in any density: the conversation scrolls instead.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, metrics.density == .pip ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.accessibilityLabel)
    }
}

/// Reasoning the provider emitted as live ACP thought chunks, joined into one thought. Closed, it
/// is one quiet line, "Thinking" and the start of the thought; open, the whole text in italics
/// beside a tinted rule, so it never reads as the agent's reply. Only emitted thought chunks are
/// shown here; nothing is inferred from other output.
private struct PrettyThinkingRow: View {
    let text: String
    let metrics: PrettyMetrics
    @Binding var isExpanded: Bool

    var body: some View {
        let thought = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = thought.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let size = metrics.toolSize - (metrics.density == .regular ? 0.5 : 0)
        VStack(alignment: .leading, spacing: metrics.blockSpacing * 0.6) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: size - 3, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: size - 2)
                    Image(systemName: "brain").font(.system(size: size - 1))
                    Text("Thinking").fontWeight(.medium)
                    if !isExpanded, !preview.isEmpty {
                        Text(verbatim: preview).italic().foregroundStyle(Palette.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.system(size: size))
                .foregroundStyle(Palette.focus)
                .padding(.vertical, metrics.density == .pip ? 1 : 3)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)
            .help(isExpanded ? "Hide the provider's thinking" : "Show the thinking the provider reported")
            .accessibilityLabel("Thinking")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides the reasoning the provider emitted for this turn")
            if isExpanded {
                Text(verbatim: thought.isEmpty ? "The provider sent no thinking text." : thought)
                    .font(metrics.body.italic())
                    .lineSpacing(metrics.lineSpacing)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, metrics.density == .pip ? 8 : 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(Palette.focus.opacity(0.45)).frame(width: 2)
                    }
                    .accessibilityLabel("Thinking: \(thought)")
            }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Text from a role that is neither the developer nor the agent, such as `system` or `developer`.
/// It is named by its role and set in the terminal face at lower prominence, as written: it is
/// often harness output, so it is not read as Markdown. An entry with no text says so and leaves
/// its content to the fields.
private struct PrettyRoleNote: View {
    let role: String
    let text: String
    let metrics: PrettyMetrics

    var body: some View {
        let name = role.isEmpty ? "record" : role
        VStack(alignment: .leading, spacing: metrics.density == .pip ? 2 : 4) {
            Text(verbatim: name.uppercased())
                .font(.system(size: metrics.density == .regular ? 10 : 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.inkSecondary)
                .textSelection(.disabled)
                .accessibilityAddTraits(.isHeader)
            if text.contains(where: { !$0.isWhitespace }) {
                Text(verbatim: text)
                    .font(Term.font(metrics.codeSize))
                    .lineSpacing(metrics.density == .pip ? 1.5 : 3)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No text. Its content is in the fields.")
                    .font(.system(size: metrics.codeSize))
                    .foregroundStyle(.inkSecondary)
            }
        }
        .padding(.leading, metrics.density == .pip ? 7 : 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(Palette.border).frame(width: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(text.contains(where: { !$0.isWhitespace }) ? text : "no text")")
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
    /// What the block holds, stated above it.
    let caption: String

    private struct Chunk: Identifiable {
        let id: Int
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.density == .pip ? 3 : 6) {
            if metrics.density != .pip || caption != "Tool result" {
                Label(caption, systemImage: "text.alignleft")
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
    /// Present on the wall tile, focused worker, coordinator and PiP. The bar then shows the inline
    /// terminal's status in Terminal mode, and the menu offers detach or reconnect and the
    /// standalone read-only viewer.
    var terminal: NativeTerminalTarget? = nil

    var body: some View {
        let mode = modes?.mode(for: consoleID) ?? .console
        let overridden = modes?.hasOverride(for: consoleID) ?? false
        let scope = overridden ? "this console only" : "following all consoles"
        // Title-bar control ink at rest; the focus colour while this console overrides the mode.
        let ink = ConsoleHeaderControlInk(active: overridden ? Palette.focus : nil)
        // Semibold, the weight of the action glyph beside it: the regular symbol was too thin to find.
        let glyph = Image(systemName: mode.symbol).fontWeight(.semibold)

        HStack(spacing: 6) {
        // The inline terminal's status, in the bar the console already has.
        if let terminal { NativeTerminalChromeStatus(consoleID: consoleID, target: terminal) }
        Menu {
            ConsoleModeMenuItems(modes: modes, consoleID: consoleID)
            if let source {
                Divider()
                ConsoleSourceMenuItems(source: source)
            }
            if let terminal {
                Divider()
                NativeTerminalMenuItems(target: terminal, consoleID: consoleID)
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
