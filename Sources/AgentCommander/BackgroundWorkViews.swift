import AppKit
import SwiftUI

// BACKGROUND WORK VIEWS (DESIGN.md, "Pretty transcript"; spec section G)
// The stack at the bottom of the transcript, above the agent's own live line. Values come from
// `BackgroundJob.swift`; density and type come from the console that draws it.
//
//   Molecule   BackgroundJobLine    one job: mark, sentence, time, tag, chevron
//   Organism   BackgroundStack      the lines in order, the count line, the disconnected line
//
// A part emits its disclosure toggle or a typed intent. Nothing here reads the service.

/// What a surface offers the stack: the service connection and where a link goes.
struct BackgroundWorkAccess {
    /// False while the service is not reachable: no spinner and no timer anywhere in the stack.
    var isConnected = true
    /// Goes to the worker with this exact ID. Nil offers no "Open <name>".
    var openWorker: (@MainActor (String) -> Void)? = nil
    /// Opens the request with this exact ID where it is answered.
    var openRequest: (@MainActor (String) -> Void)? = nil
}

private struct BackgroundWorkAccessKey: EnvironmentKey {
    static var defaultValue: BackgroundWorkAccess { BackgroundWorkAccess() }
}

extension EnvironmentValues {
    var backgroundWork: BackgroundWorkAccess {
        get { self[BackgroundWorkAccessKey.self] }
        set { self[BackgroundWorkAccessKey.self] = newValue }
    }
}

/// A link inside the transcript: focus ink, underlined, a plain button.
struct PrettyLinkButton: View {
    let title: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: size))
            .foregroundStyle(Palette.focus)
            .underline()
            .textSelection(.disabled)
            .fixedSize()
    }
}

// MARK: - Molecule

struct BackgroundJobLine<Detail: View>: View {
    let row: BackgroundStackLayout.Row
    let isExpanded: Bool
    let metrics: PrettyMetrics
    /// Whether the line has anything to open to.
    var opens = true
    /// "Go to the question", for a job that waits on the reader.
    var goToQuestion: (() -> Void)? = nil
    let toggle: () -> Void
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        if row.line.isFailure {
            // The failure line of the transcript, with the record's own reason. Never folded.
            ActivityFailureLine(step: failureStep, isExpanded: isExpanded, metrics: metrics, toggle: toggle, detail: detail)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    if opens {
                        Button(action: toggle) { label }
                            .buttonStyle(ActivityRowButtonStyle())
                            .textSelection(.disabled)
                            .onKeyPress(.rightArrow) { if !isExpanded { toggle() }; return .handled }
                            .onKeyPress(.leftArrow) { if isExpanded { toggle() }; return .handled }
                            .accessibilityLabel(row.line.spoken)
                            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    } else {
                        label
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(row.line.spoken)
                    }
                    if let goToQuestion {
                        PrettyLinkButton(title: "Go to the question", size: metrics.bodySize, action: goToQuestion)
                            .accessibilityHint("Opens \(row.job.name)'s question")
                    }
                    Spacer(minLength: 0)
                }
                if isExpanded, opens {
                    detail()
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 1) }
                        .padding(.leading, 22).padding(.top, 8).padding(.bottom, 4)
                }
            }
        }
    }

    private var failureStep: ActivityStep {
        ActivityStep(id: row.job.id, entries: [], state: .failed, sentence: row.line.sentence, tag: row.line.tag,
                     failure: row.line.reason.map { ActivityFailure(outcome: .failed, reason: $0, exact: $0) })
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 8) {
            BackgroundMark(mark: row.line.mark, size: metrics.density == .pip ? 10 : 12)
            ActivitySentenceText(sentence: row.line.sentence, metrics: metrics)
                .lineLimit(metrics.density == .regular ? 2 : 1).truncationMode(.middle)
            if let started = row.line.started { PrettyElapsedText(started: started, metrics: metrics) }
            if let tag = row.line.tag { ActivityTagView(tag: tag, metrics: metrics) }
            if opens { ActivityChevron(isExpanded: isExpanded, size: metrics.bodySize) }
        }
        .contentShape(Rectangle())
    }
}

/// A job's mark: the spinner, or a hollow, solid or attention dot of the same footprint.
struct BackgroundMark: View {
    let mark: BackgroundJob.Mark?
    var size: CGFloat = 12

    var body: some View {
        switch mark {
        case .spinner: PrettySpinner(isSpinning: true, size: size)
        case .hollow: PrettySpinner(isSpinning: false, size: size)
        case .solid: dot(Palette.secondary)
        case .attention: dot(Palette.attention)
        case nil: Color.clear.frame(width: size, height: size).accessibilityHidden(true)
        }
    }

    private func dot(_ ink: Color) -> some View {
        Circle().fill(ink).frame(width: size * 0.6, height: size * 0.6)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Organism

struct BackgroundStack: View {
    let jobs: [BackgroundJob]
    let metrics: PrettyMetrics
    let isExpanded: (String) -> Bool
    let toggle: (String) -> Void
    /// Opens the request with this ID. Nil offers no "Go to the question".
    var openRequest: (@MainActor (String) -> Void)? = nil
    /// Opens the worker's Source. Nil offers none.
    var openSource: (@MainActor (String) -> Void)? = nil

    @Environment(\.backgroundWork) private var access
    /// The finished and failed lines already spoken, so each is announced once.
    @State private var announced: Set<String>? = nil

    /// The key of the count line's open state.
    static let moreID = "background:more"

    var body: some View {
        // The reported-progress age is the one thing here that changes without a new record.
        if access.isConnected, jobs.contains(where: { $0.progress != nil && TaskState(api: $0.state).isActiveTurn }) {
            TimelineView(.periodic(from: .now, by: 5)) { context in stack(now: context.date) }
        } else {
            stack(now: Date())
        }
    }

    @ViewBuilder private func stack(now: Date) -> some View {
        let layout = BackgroundStackLayout(jobs: jobs, density: metrics.density, connected: access.isConnected, now: now)
        if !layout.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                if layout.isDisconnected {
                    plain(.hollow, "Not connected to the service. This is the last state it sent.")
                }
                ForEach(layout.rows) { line($0) }
                if let count = layout.count {
                    let open = isExpanded(Self.moreID)
                    Button { toggle(Self.moreID) } label: {
                        HStack(alignment: .center, spacing: 8) {
                            BackgroundMark(mark: layout.countSpins ? .spinner : nil, size: metrics.density == .pip ? 10 : 12)
                            Text(verbatim: count).font(metrics.body).foregroundStyle(.inkSecondary)
                            ActivityChevron(isExpanded: open, size: metrics.bodySize)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ActivityRowButtonStyle())
                    .textSelection(.disabled)
                    .accessibilityLabel(count)
                    .accessibilityValue(open ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows the other jobs")
                    if open { ForEach(layout.folded) { line($0) } }
                }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            .frame(maxWidth: metrics.readingWidth, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(layout.spoken)
            .onChange(of: ended(layout), initial: true) { _, ended in announce(ended, layout: layout) }
        }
    }

    private func plain(_ mark: BackgroundJob.Mark, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            BackgroundMark(mark: mark, size: metrics.density == .pip ? 10 : 12)
            Text(verbatim: text).font(metrics.body).foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func line(_ row: BackgroundStackLayout.Row) -> some View {
        let request = row.job.requestID
        return BackgroundJobLine(row: row, isExpanded: isExpanded(row.job.id), metrics: metrics,
                                 opens: row.job.kind != .question,
                                 goToQuestion: request.flatMap { id in (access.openRequest ?? openRequest).map { open in { open(id) } } },
                                 toggle: { toggle(row.job.id) }) { detail(row) }
    }

    // MARK: The opened line

    /// A worker opens to its latest group (closed), any failure and its live line, then
    /// "Open <name>". A follow-up opens to its text and status with origin. Source is last.
    @ViewBuilder private func detail(_ row: BackgroundStackLayout.Row) -> some View {
        let job = row.job
        VStack(alignment: .leading, spacing: 8) {
            switch job.kind {
            case .worker, .stop:
                let turn = BackgroundTurn(job.console)
                if let summary = turn.summary {
                    Text(verbatim: summary).font(metrics.body).foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(turn.failures) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ActivitySentenceText(sentence: step.sentence, metrics: metrics, ink: Palette.failure)
                            if let tag = step.tag { ActivityTagView(tag: tag, metrics: metrics) }
                        }
                        if let reason = step.failure?.reason {
                            Text(verbatim: reason).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let live = turn.live {
                    let active = access.isConnected && TaskState(api: job.state).isActiveTurn
                    PrettyLiveLine(subject: .call(live), live: PrettyLive(isActive: active, isDisconnected: !active),
                                   isExpanded: false, metrics: metrics) {}
                }
            case .followUp:
                if let text = job.text, !text.isEmpty {
                    Text(verbatim: text).font(metrics.body).foregroundStyle(Palette.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                origin(job, "from \(job.name)'s record, by message ID")
            case .integration:
                origin(job, "from the run's record, by integration ID")
            case .providerChild, .command:
                // The exit summary the full record holds, then where the state was read from.
                if let result = job.result, !row.line.isFailure {
                    Text(verbatim: result).font(metrics.body).foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                origin(job, "from this console's records, by tool call ID")
            case .question:
                EmptyView()
            }
            if let worker = job.workerID, !job.name.isEmpty, let open = access.openWorker {
                PrettyLinkButton(title: "Open \(job.name)", size: metrics.bodySize) { open(worker) }
                    .accessibilityHint("Goes to that worker")
            }
            if let worker = job.workerID, let openSource {
                PrettyLinkButton(title: "Source", size: metrics.detailSize) { openSource(worker) }
                    .accessibilityHint("Opens \(job.name)'s provider records")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The record's status word, where it was read from and the exact ID it was read by.
    private func origin(_ job: BackgroundJob, _ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusLamp(word: job.state, size: metrics.detailSize)
            Text(verbatim: access.isConnected ? words : "last sent " + words)
                .font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
            IDChip(id: job.recordID, size: metrics.tagSize + 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: VoiceOver

    private func ended(_ layout: BackgroundStackLayout) -> [String] {
        (layout.rows + layout.folded).filter { $0.line.rank == .failed || $0.line.rank == .finished }.map(\.id)
    }

    /// A finish or failure is spoken once, politely. What is already there when the stack
    /// appears is not announced.
    private func announce(_ ended: [String], layout: BackgroundStackLayout) {
        guard let seen = announced else { announced = Set(ended); return }
        let fresh = (layout.rows + layout.folded).filter { ended.contains($0.id) && !seen.contains($0.id) }
        announced = seen.union(ended)
        guard !fresh.isEmpty else { return }
        var message = AttributedString(fresh.map(\.line.spoken).joined(separator: ". "))
        message.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(message).post()
    }
}

/// A child's latest turn as the opened line draws it: its last group's closed summary, that
/// group's failures and the open call. Built by the transcript's own sentence rules.
struct BackgroundTurn {
    var summary: String? = nil
    var failures: [ActivityStep] = []
    var live: ActivityStep? = nil

    init(_ entries: [TranscriptEntry]) {
        let items = ActivityConversation.items(ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty)))
        for item in items.reversed() {
            if case .group(let group) = item {
                let closed = group.summary
                let words = ([closed.text] + closed.notes).filter { !$0.isEmpty }.joined(separator: ", ")
                summary = group.isSingle ? group.lines[0].sentence.plain : (words.isEmpty ? nil : words)
                failures = group.failures
                break
            }
        }
        if case .live(let step)? = items.last { live = step }
    }
}
