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
    /// What the surface knows about the turn in progress, for Pretty's live line.
    private let live: PrettyLive?
    private let reportsAsCoordinator: Bool
    /// The jobs this console's calls started, for Pretty's background stack.
    private let background: [BackgroundJob]
    /// On a bounded surface (the PiP), the turn Pretty reads in place of `entries`, shown as
    /// `ActivityConversation.recent`. Nil everywhere else. Console and Terminal never read it.
    private let recentTurn: [TranscriptEntry]?
    private let console: () -> ConsoleContent

    init(
        consoleID: String,
        entries: [TranscriptEntry],
        rawOutput: String = "",
        density: PrettyDensity,
        horizontalInset: CGFloat = 12,
        terminal: NativeTerminalTarget? = nil,
        live: PrettyLive? = nil,
        reportsAsCoordinator: Bool = false,
        background: [BackgroundJob] = [],
        recentTurn: [TranscriptEntry]? = nil,
        @ViewBuilder console: @escaping () -> ConsoleContent
    ) {
        self.recentTurn = recentTurn
        self.background = background
        self.live = live
        self.reportsAsCoordinator = reportsAsCoordinator
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
           PrettyContent.isPresentable(entries: recentTurn ?? entries, rawOutput: rawOutput) {
            pretty
        } else {
            console()
        }
    }

    /// The Pretty console this scrollback draws, with everything the surface gave it.
    var pretty: PrettyConsoleView {
        PrettyConsoleView(
            consoleID: consoleID,
            entries: recentTurn ?? entries,
            rawOutput: rawOutput,
            density: density,
            horizontalInset: horizontalInset,
            showsRecent: recentTurn != nil,
            live: live,
            reportsAsCoordinator: reportsAsCoordinator,
            background: background
        )
    }
}

extension ConsoleScrollback {
    /// A worker's or coordinator's console: its transcript, its live terminal and the jobs its
    /// calls started. Every surface that draws a worker goes through here, so none leaves the
    /// background stack out.
    init(worker: WorkerPresentation, density: PrettyDensity, horizontalInset: CGFloat = 12,
         terminal: NativeTerminalTarget? = nil, live: PrettyLive? = nil, reportsAsCoordinator: Bool = false,
         @ViewBuilder console: @escaping () -> ConsoleContent) {
        self.init(consoleID: worker.id, entries: worker.transcript, rawOutput: worker.output, density: density,
                  horizontalInset: horizontalInset, terminal: terminal, live: live,
                  reportsAsCoordinator: reportsAsCoordinator, background: worker.backgroundJobs, console: console)
    }

    /// The asking worker's console in the PiP: its recent window for Console and Terminal, its
    /// current turn for Pretty, and that worker's jobs.
    init(request: RequestPresentation, density: PrettyDensity, horizontalInset: CGFloat = 12,
         terminal: NativeTerminalTarget? = nil, live: PrettyLive? = nil,
         @ViewBuilder console: @escaping () -> ConsoleContent) {
        self.init(consoleID: request.workerID, entries: request.contextEntries,
                  rawOutput: request.contextTail.joined(separator: "\n"), density: density,
                  horizontalInset: horizontalInset, terminal: terminal, live: live,
                  background: request.workerBackgroundJobs,
                  recentTurn: request.contextEntries.isEmpty ? nil : request.prettyEntries, console: console)
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

/// Where a conversation's scroll view stands: how far its end is below the column's lower edge.
struct PrettyScrollEnd: Equatable {
    var offset: CGFloat
    var column: CGFloat
    var content: CGFloat

    /// The end counts as in view within this distance.
    static let reach: CGFloat = 24

    init(offset: CGFloat, column: CGFloat, content: CGFloat) {
        self.offset = offset
        self.column = column
        self.content = content
    }

    init(_ geometry: ScrollGeometry) {
        self.init(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                  column: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom,
                  content: geometry.contentSize.height)
    }

    var isAtEnd: Bool { content - (offset + column) <= Self.reach }

    /// Whether the view follows its end from now on, or nil to leave that as it is. Only a move
    /// of the reader's own decides it: when the content or the column changed size, the offset
    /// moved with them and says nothing about where the reader wants to be.
    func follows(after old: PrettyScrollEnd) -> Bool? {
        guard abs(content - old.content) < 0.5, abs(column - old.column) < 0.5, offset != old.offset else { return nil }
        return isAtEnd
    }
}

struct PrettyConsoleView: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @Environment(ToolDetailStore.self) private var details: ToolDetailStore?
    @Environment(CompactionSummaryStore.self) private var compactions: CompactionSummaryStore?
    @Environment(ReplyAttachmentStore.self) private var replyAttachments: ReplyAttachmentStore?
    @Environment(SessionMessageStore.self) private var sessionMessages: SessionMessageStore?
    @Environment(\.consoleRecordAccess) private var access
    @State private var localExpanded: Set<String> = []
    /// The reader is at the end of the conversation, so new content keeps the end in view.
    @State private var followsEnd = true
    @State private var position = ScrollPosition()

    let consoleID: String
    let entries: [TranscriptEntry]
    let rawOutput: String
    let density: PrettyDensity
    var horizontalInset: CGFloat = 12
    /// The open tool call of a worker waiting for the developer's reply, which reads as awaiting
    /// approval. Nil everywhere else, so every call keeps the status its result gives it.
    var awaitingToolID: String? = nil
    /// Who approves that call when it is not the developer: the coordinator or parent that
    /// answers a delegated worker's request. Nil reads "Needs your approval".
    var approvalOwner: WorkerInputOwner? = nil
    /// The call the pending permission names by exact ID. Only this call shows its proposed plan
    /// before the decision (`PrettyToolInput.pendingPlan`). Nil when the request names no call.
    var exactApprovalToolID: String? = nil
    /// The requests the parent surface can act on and how, for a line's targeted actions.
    var stories = ActivityStoryContext()
    /// A request's workflow linked over the whole transcript, on a surface showing a recent window.
    var anchor: CommanderWorkflow? = nil
    /// The surface is bounded (the PiP): of the grouped conversation it shows the latest group,
    /// the turn's failures, the report and the live line (`ActivityConversation.recent`).
    var showsRecent = false
    /// What the surface knows about the turn in progress. Nil draws no spinner and no last line.
    var live: PrettyLive? = nil
    /// The console is a coordinator's: its report is the run's result.
    var reportsAsCoordinator = false
    /// The jobs this console's calls started, each read by exact ID (`BackgroundJobs`).
    var background: [BackgroundJob] = []

    private struct Layout {
        var items: [PrettyItem]
        /// The run's jobs and the provider's own, for the background stack.
        var jobs: [BackgroundJob] = []
        /// The thought the agent is in now, drawn by the live line.
        var thinking: ActivityStep?
        var thinkingStarted: Date?
    }

    /// A streamed reply is one turn, as it is in Console. Commander's calls are linked only by
    /// exact IDs; then finished calls and quiet rows fold into groups, and failures, reports,
    /// pending requests, plans and attention events stay in the open (`ActivityConversation`).
    private func layout() -> Layout {
        let summaries = details?.summaries(worker: consoleID) ?? [:]
        let store = details
        let worker = consoleID
        // Read through the store, which matches a feed ID to the key the service keeps.
        var facts = ActivityFacts(summaries: summaries, worker: worker)
        facts.summary = { key in store?.summary(worker: worker, key: key) }
        facts.record = { key in store?.record(worker: worker, key: key) }
        facts.approvalOwner = approvalOwner
        let attachments = replyAttachments
        facts.replyAttachment = { mark in attachments?.attachment(worker: worker, mark: mark) }
        let messages = sessionMessages
        facts.sessionMessage = { mark in messages?.detail(worker: worker, mark: mark) }
        facts.hidesSecrets = store?.hidesSecrets ?? false
        // The older runner sends no console event for a thought: its record is placed by sequence.
        let lookup: (String) -> ToolDetailSummary? = { key in store?.summary(worker: worker, key: key) }
        let records = Array(summaries.values)
        let displayed = PrettyRecordPlacement.withThoughts(
            TranscriptEntry.displayed(entries, mode: .pretty), summaries: records, worker: worker,
            summary: lookup, record: { key in store?.record(worker: worker, key: key) })
        let conversation = ConversationActivity.items(displayed, awaitingToolID: awaitingToolID, anchor: anchor)
        let built = ActivityConversation.items(conversation, awaitingToolID: awaitingToolID, facts: facts,
                                               reportsAsCoordinator: reportsAsCoordinator)
        let ended = PrettyRecordPlacement.withTurnEnds(built, summaries: records, worker: worker, summary: lookup)
        // A form reply's line follows the console event it was sent after, before the turn's end.
        let placed = PrettyRecordPlacement.withFormOutcomes(ended, summaries: records, worker: worker, summary: lookup)
        // Chosen from the finished items, so a failure keeps its line and a group its count.
        let chosen = showsRecent
            ? ActivityConversation.recent(placed, keeping: Set(anchor?.entries.map(\.id) ?? [])) : placed
        // What the turn is doing now is read from before the reply lines the conversation ends with.
        let (items, outcomes) = PrettyRecordPlacement.beforeTrailingOutcomes(chosen)
        // The run's jobs, then the provider's own: background commands and child agents.
        let jobs = background + ProviderJobs.jobs(summaries: records, record: { key in store?.record(worker: worker, key: key) },
                                                  entries: entries, worker: worker,
                                                  hidesSecrets: store?.hidesSecrets ?? false)
        guard let live, live.isActive || live.isDisconnected, let thought = ActivityConversation.liveThought(in: items) else {
            return Layout(items: chosen, jobs: jobs)
        }
        let record = (thought.entries.first?.origin?.messageID).flatMap { store?.summary(worker: worker, key: $0) }
            ?? store?.summary(worker: worker, key: thought.id)
        // A thought whose record holds its end is over: it stays a line, and is not the live one.
        if record?.ended != nil { return Layout(items: chosen, jobs: jobs) }
        return Layout(items: ActivityConversation.withoutLiveThought(items) + outcomes, jobs: jobs, thinking: thought,
                      thinkingStarted: record?.started)
    }

    /// Changes when the transcript gains an entry or a call gains its result: the moments the
    /// service may hold new details. Nothing is read on a timer.
    private var detailRevision: String {
        var results = 0
        for entry in entries { if case .tool(_, _, let result) = entry.kind, result != nil { results += 1 } }
        return "\(consoleID) \(entries.count) \(results)"
    }

    var body: some View {
        let metrics = PrettyMetrics(density)
        let scope = stories.scope(canOpenSource: access?.openSource != nil)
        let layout = layout()
        let shown = layout.items
        // No entry and no line: the unformatted output. A form reply from before the worker's
        // first event is a line, and is drawn as one.
        let isUnformatted = entries.isEmpty && shown.isEmpty
        GeometryReader { column in
        ScrollView(.vertical) {
            // One conversation column. It fills a tile, and stops widening in a broad console so
            // a prompt stays within reach of the answer beneath it.
            LazyVStack(alignment: .leading, spacing: 0) {
                if isUnformatted {
                    PrettyRawBlock(text: rawOutput, metrics: metrics, caption: "Unformatted output")
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        self.item(item, scope: scope, metrics: metrics)
                            .padding(.top, index == 0 ? 0 : spacing(before: item, after: shown[index - 1], metrics: metrics))
                    }
                    // Background work sits at the bottom, above the agent's own live line.
                    if !layout.jobs.isEmpty {
                        BackgroundStack(jobs: layout.jobs, metrics: metrics, isExpanded: isExpanded, toggle: toggle,
                                        openRequest: stories.openRequest,
                                        openSource: access?.openSource)
                            .padding(.top, shown.isEmpty ? 0 : metrics.blockSpacing * 1.4)
                    }
                    lastLine(layout, metrics: metrics)
                        .padding(.top, shown.isEmpty ? 0 : metrics.blockSpacing * 1.4)
                }
            }
            .frame(maxWidth: metrics.columnWidth, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, metrics.verticalInset)
            // The content is never shorter than the column, and a short conversation sits at its
            // top. The scroll view's own top alignment is not used: with it, a lazy stack whose
            // first rows measure shorter than the column opens at the top and stays there.
            .frame(maxWidth: .infinity, minHeight: column.size.height, alignment: .topLeading)
        }
        // Opens at the latest content. A change of size leaves what is in view where it is; while
        // the reader is at the end, the view then moves to the new end. Once they scroll up it
        // does not, whatever arrives.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .scrollPosition($position)
        .onScrollGeometryChange(for: PrettyScrollEnd.self) { PrettyScrollEnd($0) } action: { old, new in
            if let follows = new.follows(after: old) {
                followsEnd = follows
            } else if followsEnd, !new.isAtEnd {
                position.scrollTo(edge: .bottom)
            }
        }
        }
        // The unformatted output and the conversation are two scroll views. One kept across the
        // change holds the old offset, which lies past the end of a shorter conversation.
        .id(isUnformatted)
        .textSelection(.enabled)
        .tint(Palette.focus)
        .environment(\.openURL, PrettyContent.linkPolicy)
        .task(id: detailRevision) {
            // The saved setting first, on any surface: until it is known, job text is drawn hidden.
            await details?.loadSettingsIfNeeded()
            await details?.refresh(worker: consoleID)
            // A report's text may be only in its stored record: summaries leave out long values.
            for key in ActivitySteps.reportsToRead(entries) { await details?.open(worker: consoleID, key: key) }
            // A failed job's reason, a thought's text and a card's content are in the full records.
            let records = Array((details?.summaries(worker: consoleID) ?? [:]).values)
            let cards = entries.compactMap { entry -> String? in
                guard case .tool(let name, _, let result) = entry.kind,
                      PrettyToolCard.kind(name: name, result: result, summary: details?.summary(worker: consoleID, key: entry.detailKey)) != nil
                else { return nil }
                return entry.detailKey
            }
            for key in ProviderJobs.recordsToRead(records) + PrettyRecordPlacement.thoughtsToRead(records) + cards {
                await details?.open(worker: consoleID, key: key)
            }
        }
        // A link or a resource sent as a reply chunk is read from that chunk's own record, in a
        // task of its own: a record that is not there yet never holds up the stored details.
        .task(id: replyAttachmentRevision) {
            let marks = entries.compactMap(\.replyAttachment)
            guard let store = replyAttachments, !marks.isEmpty else { return }
            // Latest first, a few at a time: a long transcript does not start every read at once.
            await store.load(worker: consoleID, marks: marks)
        }
        // A message from another session is read from the records of its own updates. One read
        // serves every update of a turn, and a later one starts where the last one stopped.
        .task(id: sessionMessageRevision) {
            let marks = entries.flatMap(\.sessionMessages)
            guard let store = sessionMessages, !marks.isEmpty else { return }
            await store.load(worker: consoleID, marks: marks)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    /// Changes when the console gains or loses a session message update. Nothing is read on a timer.
    private var sessionMessageRevision: String {
        ([consoleID] + entries.flatMap { $0.sessionMessages.map(\.cursor) }).joined(separator: "\u{1F}")
    }

    /// Changes when the console gains or loses a marked reply chunk. Nothing is read on a timer.
    private var replyAttachmentRevision: String {
        ([consoleID] + entries.compactMap { $0.replyAttachment?.cursor }).joined(separator: "\u{1F}")
    }

    private func spacing(before item: PrettyItem, after previous: PrettyItem, metrics: PrettyMetrics) -> CGFloat {
        func isPrompt(_ item: PrettyItem) -> Bool {
            if case .entry(let entry) = item { return entry.isFromUser }
            return false
        }
        // A change of speaker opens a new turn; everything inside the agent's turn sits closer.
        return isPrompt(item) != isPrompt(previous) || isPrompt(item) ? metrics.turnSpacing : metrics.blockSpacing * 1.4
    }

    @ViewBuilder
    private func item(_ item: PrettyItem, scope: ActivityStoryScope, metrics: PrettyMetrics) -> some View {
        switch item {
        case .entry(let entry):
            row(entry, metrics: metrics)
        case .group(let group):
            VStack(alignment: .leading, spacing: metrics.blockSpacing * 0.8) {
                ActivityGroupView(group: group, metrics: metrics, isExpanded: isExpanded, toggle: toggle,
                                  setAll: setAll) { step in detail(step, scope: scope, metrics: metrics) }
                // A pending question keeps its targeted action in reach while its line is closed.
                if group.isSingle, !isExpanded(group.lines[0].id) {
                    let primary = actions(for: group.lines[0], scope: scope).filter(\.isPrimary)
                    if !primary.isEmpty {
                        ActivityActionGroup(actions: primary, fontSize: metrics.toolSize, density: density) { perform($0) }
                    }
                }
            }
        case .report(let report):
            PrettyReportBlock(report: report, isExpanded: isExpanded(report.id), metrics: metrics,
                              toggle: { toggle(report.id) }) { reportDetail(report, metrics: metrics) }
        case .plan(let plan):
            if let items = plan.items {
                PrettyPlanCard(items: items, metrics: metrics, isLive: live?.isActive == true)
            } else {
                Text(verbatim: plan.fallback).font(metrics.body).foregroundStyle(.inkSecondary)
                    // The older runner keeps the items in the call's stored arguments.
                    .task(id: plan.entries.last?.id) {
                        if let key = plan.entries.last?.id { await details?.open(worker: consoleID, key: key) }
                    }
            }
        case .live(let step):
            // The time comes from the call's stored record, never from when the app saw the call.
            let record = step.entries.last.flatMap { details?.summary(worker: consoleID, key: $0.detailKey) }
            PrettyLiveLine(subject: .call(step), live: live ?? PrettyLive(), isExpanded: false, metrics: metrics,
                           callStarted: live?.callStart(record)) {}
        case .turnEnd(let end):
            PrettyTurnEndLine(end: end, metrics: metrics)
        case .formOutcome(let outcome):
            PrettyFormOutcomeLine(outcome: outcome, metrics: metrics)
        case .compaction(let compaction):
            self.compaction(compaction, itemID: item.id, metrics: metrics)
        case .message(let message):
            // Drawn, selected and said as the transcript setting allows. The fields are those of
            // the message's first update.
            if let first = message.entries.first {
                PrettySessionMessage(message: message, metrics: metrics, hidesSecrets: details?.hidesSecrets ?? false)
                    .recordDetail(consoleID: consoleID, entry: first, face: .pretty(below: false), density: density)
            }
        case .card(let card):
            let key = card.entry?.detailKey ?? card.step.id
            PrettyToolCardView(card: card, summary: details?.summary(worker: consoleID, key: key),
                               record: details?.record(worker: consoleID, key: key), metrics: metrics,
                               isExpanded: isExpanded(card.step.id), toggle: { toggle(card.step.id) }) {
                detail(card.step, scope: scope, metrics: metrics)
            }
        case .approval(let step):
            VStack(alignment: .leading, spacing: metrics.blockSpacing * 0.8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "hand.raised").font(.system(size: metrics.bodySize - 2, weight: .medium))
                        .foregroundStyle(Palette.attention).accessibilityHidden(true)
                    ActivitySentenceText(sentence: step.sentence, metrics: metrics, ink: Palette.attention)
                }
                .accessibilityElement(children: .combine)
                // A proposed plan is read before its decision: this console's record of the call
                // the permission names.
                if let plan = PrettyToolInput.pendingPlan(
                    for: step, exactToolID: exactApprovalToolID, summary: { details?.summary(worker: consoleID, key: $0) },
                    record: { details?.record(worker: consoleID, key: $0) }) {
                    PrettyPlanDocument(plan: plan, metrics: metrics)
                }
                let primary = actions(for: step, scope: scope).filter(\.isPrimary)
                if !primary.isEmpty {
                    ActivityActionGroup(actions: primary, fontSize: metrics.toolSize, density: density) { perform($0) }
                }
            }
            .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        }
    }

    /// One provider compaction, by the status its message states: the live line while it runs,
    /// the divider once it is done, a failure line when it failed. A finished row reads its own
    /// source record once, for the provider's summary or error.
    @ViewBuilder
    private func compaction(_ compaction: PrettyCompaction, itemID: String, metrics: PrettyMetrics) -> some View {
        let record = compactions?.record(worker: consoleID, mark: compaction.mark)
        Group {
            switch compaction.mark.status {
            case .inProgress:
                PrettyLiveLine(subject: .call(compaction.liveStep), live: live ?? PrettyLive(), isExpanded: false,
                               metrics: metrics) {}
            case .completed:
                PrettyCompactionDivider(summary: record?.summary, isExpanded: isExpanded(itemID), metrics: metrics,
                                        toggle: { toggle(itemID) })
            case .failed:
                ActivityFailureLine(step: compaction.failureStep(record), isExpanded: false, metrics: metrics,
                                    opens: false, toggle: {}) { EmptyView() }
                    .frame(maxWidth: metrics.readingWidth, alignment: .leading)
            }
        }
        .task(id: compaction.mark.cursor + " " + String(describing: compaction.mark.status)) {
            await compactions?.load(worker: consoleID, mark: compaction.mark)
        }
    }

    /// The last item of the transcript while a turn runs and no call is open: Thinking, with its
    /// time and text when the provider sent them, or that the agent is responding.
    @ViewBuilder
    private func lastLine(_ layout: Layout, metrics: PrettyMetrics) -> some View {
        if let live {
            if let thought = layout.thinking {
                PrettyLiveLine(subject: .thinking(text: thought.text, started: layout.thinkingStarted), live: live,
                               isExpanded: isExpanded(thought.id), metrics: metrics, copy: copy) { toggle(thought.id) }
            } else if live.isActive, let trailing = live.trailing, !endsWithOpenCall(layout.items) {
                switch trailing {
                case .thinking:
                    PrettyLiveLine(subject: .thinking(text: "", started: nil), live: live, isExpanded: false, metrics: metrics) {}
                case .responding(let name):
                    PrettyLiveLine(subject: .responding(name), live: live, isExpanded: false, metrics: metrics) {}
                }
            }
        }
    }

    private func endsWithOpenCall(_ items: [PrettyItem]) -> Bool {
        // A form reply's line after the open call does not close it.
        switch PrettyRecordPlacement.beforeTrailingOutcomes(items).items.last {
        case .live?, .approval?: true
        // A provider question that waits for its answer is the open call.
        case .card(let card)?: card.step.state == .running
        // A running compaction is the live line.
        case .compaction(let compaction)?: compaction.mark.status == .inProgress
        default: false
        }
    }

    /// The story of a line's Commander calls, for its timeline and targeted actions.
    private func actions(for step: ActivityStep, scope: ActivityStoryScope) -> [ActivityStoryAction] {
        if let flow = step.workflow { return ActivityStories.story(for: flow, scope: scope).actions(in: scope) }
        guard let entry = step.entries.first else { return [] }
        return ActivityStories.story(for: entry, awaitingToolID: awaitingToolID, scope: scope)?.actions(in: scope) ?? []
    }

    /// What an opened line shows: a thought's text; or each call's typed result, after the
    /// milestone timeline when several calls are linked by an exact ID.
    @ViewBuilder
    private func detail(_ step: ActivityStep, scope: ActivityStoryScope, metrics: PrettyMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if step.kind == .thought {
                PrettyThoughtBody(text: step.text, metrics: metrics, copy: copy)
            } else {
                if step.kind == .workflow, let flow = step.workflow {
                    let story = ActivityStories.story(for: flow, scope: scope)
                    if !story.milestones.isEmpty {
                        ActivityMilestoneTimeline(story: story, limit: density == .pip ? 4 : nil, fontSize: metrics.toolSize)
                    }
                    if !story.relations.isEmpty { ActivityRelationList(relations: story.relations, fontSize: metrics.toolSize) }
                }
                let actions = actions(for: step, scope: scope).filter { $0.intent != .openSource }
                if !actions.isEmpty {
                    ActivityActionGroup(actions: actions, fontSize: metrics.toolSize, density: density) { perform($0) }
                }
                if step.entries.count == 1, let entry = step.entries.first {
                    result(entry, step: step, metrics: metrics)
                } else {
                    // Each call stays inside its line, in order, behind its own disclosure.
                    ForEach(Array(step.entries.enumerated()), id: \.element.id) { index, entry in
                        ResultDisclosure(title: callTitle(entry, index: index), metrics: metrics) {
                            result(entry, step: step, metrics: metrics)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func callTitle(_ entry: TranscriptEntry, index: Int) -> String {
        if let call = CommanderCall(entry: entry) {
            let words = ActivityWords.commander(call)
            let failed = call.result.map { ToolStatus(result: $0) != .done } ?? false
            return (failed ? words.failed : call.result == nil ? words.running : words.done).plain
        }
        return "Call \(index + 1)"
    }

    private func result(_ entry: TranscriptEntry, step: ActivityStep, metrics: PrettyMetrics) -> some View {
        let record = details?.record(worker: consoleID, key: entry.detailKey)
        let summary = details?.summary(worker: consoleID, key: entry.detailKey)
        return VStack(alignment: .leading, spacing: 0) {
            // The file and line this worker's own call reported, from its latest stored summary.
            if let location = summary?.openableLocation, let intents = access?.toolLocation {
                ToolLocationAction(workerID: consoleID, detailKey: entry.detailKey, location: location, intents: intents,
                                   metrics: metrics)
            }
            ActivityResultView(source: ActivityResultSource(entry: entry, step: step, record: record, summary: summary),
                               metrics: metrics, hidesSecrets: details?.settings.hideSecrets ?? false,
                               hidesChangeText: details?.hidesSecrets, copy: copy)
                .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
        }
        // The full record is read only now that the line is open.
        .task(id: entry.id) { await details?.open(worker: consoleID, key: entry.detailKey) }
    }

    private func reportDetail(_ report: ActivityReport, metrics: PrettyMetrics) -> some View {
        let call = report.call
        var step = ActivityStep(id: call.entry.id, entries: [call.entry], state: .done, sentence: ActivitySentence(report.heading))
        step.workflow = nil
        let tests = call.tests.map { CommanderCall.join($0.command, $0.outcome) ?? $0.command }
        var sent: [String] = call.revision.map { ["rev " + Identifier.short($0)] } ?? []
        sent += tests
        return VStack(alignment: .leading, spacing: 8) {
            ResultFieldList(rows: [
                ResultField(key: "goes_to", value: .string(reportsAsCoordinator
                    ? "the run's result (a coordinator has no coordinator above it)" : "the coordinator")),
                ResultField(key: "tests_revision", value: sent.isEmpty ? .null : .string(sent.joined(separator: ", "))),
            ], metrics: metrics, labels: ["goes_to": "Goes to", "tests_revision": "Tests, revision"])
            result(call.entry, step: step, metrics: metrics)
        }
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

    /// An entry that is not folded: a prompt, a reply, an attention-tone event or a role note.
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
        case .tool, .output:
            // Every call and result is a line of a group; none reaches here.
            EmptyView()
        case .other(let role, let text):
            if let attachment = entry.replyAttachment.flatMap({ replyAttachments?.attachment(worker: consoleID, mark: $0) }) {
                // Part of the reply, in the place it was sent.
                Group {
                    switch attachment {
                    case .link(let link):
                        ReplyLinkRow(link: link, metrics: metrics, hidesSecrets: details?.hidesSecrets ?? false)
                    case .resource(let resource):
                        ReplyResourceQuote(resource: resource, metrics: metrics, hidesSecrets: details?.hidesSecrets ?? false)
                    }
                }
                .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
            } else if let event = ActivityEvent(entry: entry, hidesSecrets: details?.hidesSecrets ?? false) {
                // A warning, harness stderr or a permission notice: one visible line in the
                // attention ink. It never carries a reply; a request is answered only in its form.
                // A provider notice's title is drawn and spoken as the transcript setting allows.
                PrettyActivityRow(event: event, metrics: metrics)
                    .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
            } else {
                PrettyRoleNote(role: role, text: text, metrics: metrics)
                    .recordDetail(consoleID: consoleID, entry: entry, face: .pretty(below: false), density: density)
            }
        }
    }

    private var copy: (String) -> Void {
        let action = access?.copy ?? RecordPasteboard.copy
        return { action($0) }
    }

    /// Performs a line's targeted action through the parent's own action. Nothing else navigates.
    private func perform(_ intent: ActivityStoryIntent) {
        switch intent {
        case .focusRequest(let id): stories.focusRequest?(id)
        case .openRequest(let id): stories.openRequest?(id)
        case .copy(let text): (access?.copy ?? RecordPasteboard.copy)(text)
        case .openSource: access?.openSource?(consoleID)
        }
    }

    /// Open state is kept per console by the line's first call ID, so a line stays open as later
    /// calls and facts arrive.
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

    private func setAll(_ ids: [String], _ expanded: Bool) {
        for id in ids where isExpanded(id) != expanded { toggle(id) }
    }
}

// MARK: - Metrics

struct PrettyMetrics {
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

    /// Pretty's own corners (DESIGN.md, Pretty transcript): the activity list and field, tags and
    /// wells. They match the black-glass `control` and `chip` values and read no theme.
    let listRadius: CGFloat = 9
    let chipRadius: CGFloat = 5
    /// The prompt bubble, the request form and the message box.
    let blockRadius: CGFloat = 13
    /// Padding of one activity line inside its list.
    let lineInset: CGSize
    /// Type of an opened line's fields, a step below the sentence.
    let detailSize: CGFloat
    /// State tags, IDs and elapsed time, in the terminal face.
    let tagSize: CGFloat
    /// Width of the label column of an opened line's fields.
    let labelWidth: CGFloat
    /// The size of `body`, for values set in the terminal face inside a sentence.
    let bodySize: CGFloat
    /// How many lines a clamped report, thought or quote shows before "Show all".
    let clampLines: Int

    init(_ density: PrettyDensity) {
        self.density = density
        switch density {
        case .regular:
            bodySize = 13
            codeSize = 11.5
            toolSize = 12
            turnSpacing = 22
            blockSpacing = 10
            lineSpacing = 4.5
            verticalInset = 16
            userGutter = 72
            bubbleRadius = 13
            bubbleInset = CGSize(width: 14, height: 9)
            lineInset = CGSize(width: 14, height: 9)
            detailSize = 12.5
            tagSize = 10.5
            labelWidth = 104
            clampLines = 4
        case .compact:
            bodySize = 12.5
            codeSize = 11
            toolSize = 11
            turnSpacing = 14
            blockSpacing = 7
            lineSpacing = 3
            verticalInset = 10
            userGutter = 32
            bubbleRadius = 13
            bubbleInset = CGSize(width: 11, height: 7)
            lineInset = CGSize(width: 10, height: 6)
            detailSize = 11.5
            tagSize = 10
            labelWidth = 84
            clampLines = 6
        case .pip:
            bodySize = 11.5
            codeSize = 10
            toolSize = 10
            turnSpacing = 9
            blockSpacing = 5
            lineSpacing = 1.5
            verticalInset = 6
            userGutter = 20
            bubbleRadius = 10
            bubbleInset = CGSize(width: 8, height: 4)
            lineInset = CGSize(width: 8, height: 5)
            detailSize = 11
            tagSize = 9.5
            labelWidth = 70
            clampLines = 3
        }
        body = .system(size: bodySize)
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

struct PrettySurface: ViewModifier {
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
        case .userTurn: return Palette.selection
        case .code: return Palette.well
        case .raw: return Palette.panel
        }
    }
}

// MARK: - Turns

struct PrettyUserTurn: View {
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
                    .foregroundStyle(Palette.foreground)
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

/// One activity line, in the terminal's restrained voice: a small symbol, a short label and the
/// event's readable detail. An event that may need the developer, such as harness stderr or a
/// permission notice, is drawn in the attention ink; the rest are secondary. Details wrap, so
/// nothing is cut; a record with only fields says so and its fields action opens them.
struct PrettyActivityRow: View {
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

/// Text from a role that is neither the developer nor the agent, such as `system` or `developer`.
/// It is named by its role and set in the terminal face at lower prominence, as written: it is
/// often harness output, so it is not read as Markdown. An entry with no text says so and leaves
/// its content to the fields.
struct PrettyRoleNote: View {
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

struct PrettyAssistantTurn: View {
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

struct PrettyBlock: Identifiable {
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

struct PrettyBlockView: View {
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

struct PrettyCodeBlock: View {
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

struct PrettyTable: View {
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

enum PrettyMarkdown {
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
final class PrettyMarkdownCache {
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

struct PrettyRawBlock: View {
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
    /// Present on the coordinator, which has no action list. The menu then offers the same
    /// provider-session panel a worker's action list does, and presents it here.
    var providerSession: ProviderSessionAccess? = nil
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
            if source != nil || providerSession != nil {
                Divider()
                if let source { ConsoleSourceMenuItems(source: source) }
                if let providerSession { ProviderSessionMenuItems(access: providerSession) }
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
        // Its own anchor on the same control, so the two panels never share a presenter.
        .background { Color.clear.modifier(ProviderSessionPresentation(access: providerSession)) }
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
