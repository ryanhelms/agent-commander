import AppKit
import SwiftUI

// PRETTY CONVERSATION VIEWS
// Tool activity as sentences in the agent's turn (DESIGN.md, "Pretty transcript"). One set of
// parts serves every surface that draws `PrettyConsoleView`: coordinator, focused worker, wall
// tile and PiP. Density, type and actions come from that parent; values come from
// `ActivitySentence.swift`. A part emits only its disclosure toggle or a typed intent.
//
//   Atoms      ActivityTagView         the small monospaced state tag
//              ActivityChevron         the disclosure mark after a sentence
//              PrettySpinner           the live line's spinner; a hollow dot without evidence
//              StatusLamp              a lamp and a word
//   Molecules  ActivitySentenceText    a sentence's plain, strong and monospaced parts
//              ActivityLine            one sentence, its tag and chevron: a native button
//              ActivityGroupSummary    the secondary-ink summary line and its "N failed"
//              ActivityFailureLine     a failed or blocked call with its reason, never folded
//              PrettyReportBlock       a reported result as quoted prose
//              PrettyLiveLine          the open call, or Thinking with its elapsed time
//              PrettyThoughtBody       a thought's text, in italic beside a rule
//              PrettyPlanCard          a task checklist
//              PrettyClamp             the first lines of a block, then "Show all"
//   Organism   ActivityGroupView       summary + list of lines + failure lines beneath
//
// Pretty reads no theme: it keeps its own `Palette` and `Term` inks and the `PrettyMetrics`
// corners, in every theme.

/// What the surface knows about the turn in progress. Nothing here is inferred from the
/// transcript: the worker's state and the service's reported phase decide it.
struct PrettyLive: Equatable {
    /// The worker is active and the service is connected: a spinner may show.
    var isActive = false
    /// The service is not reachable. Every live line then reads "Last known" with a hollow dot.
    var isDisconnected = false
    /// What the last line says when no call is open.
    var trailing: Trailing? = nil

    enum Trailing: Equatable {
        /// The service reports a thinking phase and sent no thought record.
        case thinking
        case responding(String)
    }

    init(isActive: Bool = false, isDisconnected: Bool = false, trailing: Trailing? = nil) {
        self.isActive = isActive
        self.isDisconnected = isDisconnected
        self.trailing = trailing
    }

    /// - Parameters:
    ///   - reportedPhase: the phase a tracked local Claude worker's service reports. With it,
    ///     "responding" is never inferred: only a reported thinking phase adds a line.
    init(state: TaskState, workerName: String, reportsProgress: Bool = false, reportedPhase: ClaudeProgress.Phase? = nil) {
        switch state {
        case .running, .working, .starting:
            isActive = true
            if reportsProgress {
                trailing = reportedPhase == .thinking ? .thinking : nil
            } else {
                trailing = .responding(workerName)
            }
        case .disconnected:
            isDisconnected = true
        default:
            break
        }
    }
}

// MARK: - Atoms

struct ActivityTagView: View {
    let tag: ActivityTag
    let metrics: PrettyMetrics

    var body: some View {
        let ink: Color = switch tag.tone {
        case .neutral: Palette.secondary
        case .ok: Palette.working
        case .wait: Palette.attention
        case .failure: Palette.failure
        }
        Text(verbatim: tag.word)
            .font(Term.font(metrics.tagSize, weight: .medium))
            .foregroundStyle(ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: metrics.chipRadius, style: .continuous)
                    .strokeBorder(tag.tone == .failure ? Palette.failure.opacity(0.4) : Palette.hairline, lineWidth: 1)
            }
            .accessibilityLabel(tag.word)
    }
}

struct ActivityChevron: View {
    let isExpanded: Bool
    var size: CGFloat = 13
    var ink: Color = Palette.secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(ink)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
            .accessibilityHidden(true)
    }
}

/// The live line's mark. A spinner needs a record that says running over a live connection;
/// otherwise a hollow dot.
struct PrettySpinner: View {
    let isSpinning: Bool
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isSpinning, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                ring.rotationEffect(.degrees(turn * 360))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else if isSpinning {
            ring.frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Circle().strokeBorder(Palette.secondary, lineWidth: 1.5)
                .frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private var ring: some View {
        ZStack {
            Circle().strokeBorder(Palette.border, lineWidth: 1.5)
            Circle().trim(from: 0, to: 0.25).stroke(Palette.working, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .padding(0.75)
                .rotationEffect(.degrees(-90))
        }
    }
}

struct StatusLamp: View {
    let word: String
    var size: CGFloat = 12.5

    /// Tone only for words Commander knows; any other word gets the neutral lamp.
    static func ink(_ word: String) -> Color {
        if ["starting", "queued", "pending", "stopping"].contains(word.lowercased()) { return Palette.attention }
        switch CommanderActivityStatus(operation: word.lowercased().replacingOccurrences(of: " ", with: "_")) {
        case .complete, .answered: return Palette.working
        case .running: return Palette.working
        case .queued, .waitingForReply, .awaitingApproval, .partial, .uncertain, .accepted: return Palette.attention
        case .failed, .declined: return Palette.failure
        case .cancelled, .interrupted: return Palette.secondary
        case .reported:
            switch word.lowercased() {
            case "blocked": return Palette.failure
            case "online", "active", "idle": return Palette.working
            default: return Palette.secondary
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Self.ink(word)).frame(width: 7, height: 7)
            Text(verbatim: ResultField.statusWord(word)).font(.system(size: size)).foregroundStyle(Palette.foreground)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Molecules

struct ActivitySentenceText: View {
    let sentence: ActivitySentence
    let metrics: PrettyMetrics
    /// The ink of the plain words: secondary for a finished sentence, failure for a failed one.
    var ink: Color = Palette.secondary

    var body: some View {
        sentence.parts.reduce(Text(verbatim: "")) { text, part in
            switch part {
            case .text(let words):
                text + Text(verbatim: words).foregroundColor(ink)
            case .strong(let words):
                text + Text(verbatim: words).fontWeight(.medium).foregroundColor(ink == Palette.failure ? ink : Palette.foreground)
            case .mono(let words):
                text + Text(verbatim: words).font(Term.font(metrics.bodySize * 0.9))
                    .foregroundColor(ink == Palette.failure ? ink : Palette.foreground)
            }
        }
        .font(metrics.body)
        .lineSpacing(metrics.lineSpacing * 0.5)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One sentence with its tag and chevron. A native button in tab order: Space or Return toggles,
/// Right opens and Left closes, as a native disclosure. A line that does not open is plain text.
struct ActivityLine: View {
    let step: ActivityStep
    let isExpanded: Bool
    let metrics: PrettyMetrics
    let toggle: () -> Void

    var body: some View {
        if step.opens {
            Button(action: toggle) { label }
                .buttonStyle(ActivityRowButtonStyle())
                .textSelection(.disabled)
                .help(step.help ?? step.sentence.plain)
                .onKeyPress(.rightArrow) { if !isExpanded { toggle() }; return .handled }
                .onKeyPress(.leftArrow) { if isExpanded { toggle() }; return .handled }
                .accessibilityLabel(step.accessibilityLabel)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.accessibilityLabel)
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if step.kind == .quiet, !step.text.isEmpty {
                Image(systemName: step.text)
                    .font(.system(size: metrics.bodySize - 2, weight: .medium))
                    .foregroundStyle(.inkSecondary)
                    .frame(width: metrics.bodySize + 1)
                    .accessibilityHidden(true)
            }
            ActivitySentenceText(sentence: step.sentence, metrics: metrics)
            if let tag = step.tag { ActivityTagView(tag: tag, metrics: metrics) }
            if step.opens { ActivityChevron(isExpanded: isExpanded, size: metrics.bodySize) }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// A row that brightens under the pointer and shows a focus ring from the keyboard.
struct ActivityRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var isHovered = false
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .brightness(isHovered || configuration.isPressed ? 0.12 : 0)
                .onHover { isHovered = $0 }
        }
    }
}

/// The secondary-ink line that stands for a run of finished calls. It never animates.
struct ActivityGroupSummary: View {
    let summary: ActivityGroup.Summary
    let isExpanded: Bool
    let metrics: PrettyMetrics
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (Text(verbatim: ([summary.text] + summary.notes).filter { !$0.isEmpty }.joined(separator: ", "))
                    .foregroundColor(Palette.secondary)
                 + Text(verbatim: summary.failed.isEmpty ? "" : (summary.text.isEmpty && summary.notes.isEmpty ? "" : ", ")
                        + summary.failed.joined(separator: ", "))
                    .foregroundColor(Palette.failure))
                    .font(metrics.body)
                    .fixedSize(horizontal: false, vertical: true)
                ActivityChevron(isExpanded: isExpanded, size: metrics.bodySize)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ActivityRowButtonStyle())
        .textSelection(.disabled)
        .onKeyPress(.rightArrow) { if !isExpanded { toggle() }; return .handled }
        .onKeyPress(.leftArrow) { if isExpanded { toggle() }; return .handled }
        .help("Option-click opens every step")
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// A failed or blocked call. It sits in the open under its group's summary, with its reason on
/// its own line, and opens to the failure renderer.
struct ActivityFailureLine<Detail: View>: View {
    let step: ActivityStep
    let isExpanded: Bool
    let metrics: PrettyMetrics
    let toggle: () -> Void
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ActivitySentenceText(sentence: step.sentence, metrics: metrics, ink: Palette.failure)
                        if let tag = step.tag { ActivityTagView(tag: tag, metrics: metrics) }
                        ActivityChevron(isExpanded: isExpanded, size: metrics.bodySize, ink: Palette.failure)
                        Spacer(minLength: 0)
                    }
                    if let reason = step.failure?.reason {
                        Text(verbatim: reason)
                            .font(.system(size: metrics.bodySize - (metrics.density == .regular ? 0 : 0.5)))
                            .foregroundStyle(.inkSecondary)
                            // The reason wraps on every surface: it is never cut.
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, metrics.lineInset.width).padding(.vertical, metrics.lineInset.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ActivityRowButtonStyle())
            .textSelection(.disabled)
            .help(step.help ?? step.sentence.plain)
            .onKeyPress(.rightArrow) { if !isExpanded { toggle() }; return .handled }
            .onKeyPress(.leftArrow) { if isExpanded { toggle() }; return .handled }
            .accessibilityLabel(step.sentence.plain + ", " + (step.failure?.outcome == .blocked ? "blocked" : "failed")
                                + (step.failure.map { ", " + $0.reason } ?? ""))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                detail()
                    .padding(.horizontal, metrics.lineInset.width).padding(.bottom, metrics.lineInset.height + 3)
            }
        }
        .overlay { shape.strokeBorder(Palette.failure.opacity(0.35), lineWidth: 1) }
    }
}

/// The first lines of a block, then "Show all". Used for a report a closing message follows, an
/// opened thought on a tile, a long quote.
struct PrettyClamp<Content: View>: View {
    /// Nil shows everything.
    let lines: Int?
    let lineHeight: CGFloat
    /// Keep the end in view instead of the start: an opened thought shows its latest lines.
    var keepsEnd = false
    let metrics: PrettyMetrics
    @ViewBuilder let content: () -> Content
    @State private var showsAll = false
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        let limit = lines.map { CGFloat($0) * lineHeight }
        let clamps = !showsAll && limit != nil && fullHeight > (limit ?? 0) + 1
        VStack(alignment: .leading, spacing: 4) {
            content()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(height: clamps ? limit : nil, alignment: keepsEnd ? .bottom : .top)
                .clipped()
                // The cut edge fades, so a clamped block never ends on half a line.
                .mask {
                    if clamps {
                        LinearGradient(stops: keepsEnd
                            ? [.init(color: .clear, location: 0), .init(color: .black, location: min(0.5, lineHeight / (limit ?? 1)))]
                            : [.init(color: .black, location: max(0.5, 1 - lineHeight / (limit ?? 1))), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    } else {
                        Rectangle()
                    }
                }
            if clamps {
                Button("Show all") { showsAll = true }
                    .buttonStyle(.plain)
                    .font(.system(size: metrics.detailSize))
                    .foregroundStyle(Palette.focus)
                    .underline()
                    .accessibilityHint("Shows the whole text")
            }
        }
    }
}

/// A reported result: quoted prose beside a rule, under a heading line that opens to who
/// reported, where it goes and the Source. Never a tool row, never in a group.
struct PrettyReportBlock<Detail: View>: View {
    let report: ActivityReport
    let isExpanded: Bool
    let metrics: PrettyMetrics
    let toggle: () -> Void
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        // In full when nothing follows it on the focused worker and coordinator; its first lines
        // when a closing message follows, and always on a tile and the PiP.
        let clamp: Int? = metrics.density == .regular ? (report.closingMessageFollows ? metrics.clampLines : nil) : metrics.clampLines
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: report.heading).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                    ActivityChevron(isExpanded: isExpanded, size: metrics.detailSize)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ActivityRowButtonStyle())
            .textSelection(.disabled)
            .accessibilityLabel(report.heading)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded { detail().padding(.bottom, 4) }
            PrettyClamp(lines: clamp, lineHeight: metrics.bodySize * 1.5, metrics: metrics) {
                PrettyAssistantTurn(text: report.text, metrics: metrics)
            }
        }
        .padding(.leading, metrics.density == .pip ? 9 : 14)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 2) }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Report")
    }
}

/// A thought's text, exactly as sent: italic, beside a rule, so it never reads as the reply.
struct PrettyThoughtBody: View {
    let text: String
    let metrics: PrettyMetrics
    var copy: ((String) -> Void)? = nil

    var body: some View {
        // A tile shows the latest six lines of an opened thought and the PiP three; the focused
        // worker and coordinator show it all.
        let clamp: Int? = metrics.density == .regular ? nil : (metrics.density == .compact ? 6 : 3)
        VStack(alignment: .leading, spacing: 5) {
            PrettyClamp(lines: clamp, lineHeight: metrics.bodySize * 1.45, keepsEnd: true, metrics: metrics) {
                Text(verbatim: text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(metrics.body.italic())
                    .lineSpacing(metrics.lineSpacing * 0.6)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let copy {
                Button("Copy") { copy(text) }
                    .buttonStyle(.plain).font(Term.font(metrics.tagSize, weight: .medium)).foregroundStyle(.inkSecondary)
                    .help("Copy the thought exactly as sent")
            }
        }
        .padding(.leading, metrics.density == .pip ? 9 : 15)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 2) }
        // Streaming thought text is not announced as it arrives.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thought text")
        .accessibilityValue(text)
    }
}

/// The last thing the agent is doing, inline at the point it belongs to: a spinner, the
/// sentence, and the elapsed time when the record holds a start time. While the agent thinks
/// it takes a chevron and opens to the thought text.
struct PrettyLiveLine: View {
    enum Subject: Equatable {
        case call(ActivityStep)
        /// `started` is the record's own start time; nil shows no time.
        case thinking(text: String, started: Date?)
        case responding(String)
    }

    let subject: Subject
    let live: PrettyLive
    let isExpanded: Bool
    let metrics: PrettyMetrics
    var copy: ((String) -> Void)? = nil
    let toggle: () -> Void

    private var thought: String? {
        guard case .thinking(let text, _) = subject,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.blockSpacing * 0.8) {
            if thought != nil {
                Button(action: toggle) { row }
                    .buttonStyle(ActivityRowButtonStyle())
                    .textSelection(.disabled)
                    .onKeyPress(.rightArrow) { if !isExpanded { toggle() }; return .handled }
                    .onKeyPress(.leftArrow) { if isExpanded { toggle() }; return .handled }
                    .accessibilityLabel(spoken)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else {
                row
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
            }
            if isExpanded, let thought {
                PrettyThoughtBody(text: thought, metrics: metrics, copy: copy)
                    .padding(.leading, 5)
            }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
    }

    private var row: some View {
        HStack(alignment: .center, spacing: metrics.density == .pip ? 7 : 10) {
            PrettySpinner(isSpinning: live.isActive && !live.isDisconnected, size: metrics.density == .pip ? 10 : 12)
            switch subject {
            case .call(let step):
                if live.isDisconnected || !live.isActive {
                    (Text("Last known: ").foregroundColor(Palette.secondary)
                     + Text(verbatim: step.sentence.plain.prefix(1).lowercased() + step.sentence.plain.dropFirst())
                        .foregroundColor(Palette.secondary))
                        .font(metrics.body)
                } else {
                    ActivitySentenceText(sentence: step.sentence, metrics: metrics)
                    elapsed(since: nil)
                }
            case .thinking(_, let started):
                if live.isDisconnected || !live.isActive {
                    Text("Last known: thinking").font(metrics.body).foregroundStyle(.inkSecondary)
                } else {
                    Text("Thinking").font(metrics.body).foregroundStyle(.inkSecondary)
                    elapsed(since: started)
                }
                if thought != nil { ActivityChevron(isExpanded: isExpanded, size: metrics.bodySize) }
            case .responding(let name):
                Text("\(name) is responding").font(metrics.body).foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(metrics.density == .regular ? 2 : 1).truncationMode(.middle)
        .contentShape(Rectangle())
    }

    /// The time since the record's own start, ticking once a second. No start time, no time.
    @ViewBuilder private func elapsed(since started: Date?) -> some View {
        if let started {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(verbatim: ElapsedTime.text(max(0, context.date.timeIntervalSince(started))))
                    .font(Term.font(metrics.tagSize + 0.5)).foregroundStyle(.inkSecondary)
                    .monospacedDigit()
            }
            // Read on focus, never announced on every tick.
            .accessibilityHidden(true)
        }
    }

    private var spoken: String {
        switch subject {
        case .call(let step): return (live.isActive ? "" : "Last known: ") + step.sentence.plain
        case .thinking(_, let started):
            guard live.isActive, !live.isDisconnected else { return "Last known: thinking" }
            return started.map { "Thinking, " + ElapsedTime.spoken(max(0, Date().timeIntervalSince($0))) } ?? "Thinking"
        case .responding(let name): return "\(name) is responding"
        }
    }
}

/// A task checklist, inline at the point the plan was sent and updated in place: done, in
/// progress and pending marks with each item's text.
struct PrettyPlanCard: View {
    let items: [PlanItem]
    let metrics: PrettyMetrics
    var isLive = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("The plan is empty.").font(metrics.body).foregroundStyle(.inkSecondary)
                    .padding(.vertical, 5)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    mark(item.state)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + metrics.bodySize * 0.33 }
                    Text(verbatim: item.state == .inProgress ? (item.activeForm ?? item.content) : item.content)
                        .font(metrics.body)
                        .foregroundStyle(item.state == .inProgress ? AnyShapeStyle(Palette.foreground) : AnyShapeStyle(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, metrics.density == .pip ? 2 : 5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.content + ", " + (item.state == .done ? "done" : item.state == .inProgress ? "in progress" : "pending"))
            }
        }
        .padding(.horizontal, metrics.lineInset.width).padding(.vertical, metrics.density == .pip ? 4 : 8)
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan, \(items.count) items")
    }

    @ViewBuilder private func mark(_ state: PlanItem.Status) -> some View {
        let size: CGFloat = metrics.density == .pip ? 11 : 14
        switch state {
        case .done:
            ZStack {
                Circle().fill(Palette.secondary)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Palette.panel)
            }
            .frame(width: size, height: size)
        case .inProgress:
            PrettySpinner(isSpinning: isLive, size: size)
        case .pending:
            Circle().strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5]))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Organism

/// A run of finished calls: one summary line, closed everywhere by default. Open, a bordered
/// list of its lines; each line opens to its typed result. Failures sit beneath, open or closed.
/// A group of one is its sentence alone.
struct ActivityGroupView<Detail: View>: View {
    let group: ActivityGroup
    let metrics: PrettyMetrics
    let isExpanded: (String) -> Bool
    let toggle: (String) -> Void
    /// Opens or closes the group and every line beneath it (Option-click).
    let setAll: ([String], Bool) -> Void
    @ViewBuilder let detail: (ActivityStep) -> Detail
    @State private var showsEveryLine = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.density == .pip ? 5 : 8) {
            if group.isSingle {
                single(group.lines[0])
            } else if !group.lines.isEmpty {
                let open = isExpanded(group.id)
                ActivityGroupSummary(summary: group.summary, isExpanded: open, metrics: metrics) {
                    if NSEvent.modifierFlags.contains(.option) {
                        setAll([group.id] + group.lines.filter(\.opens).map(\.id), !open)
                    } else {
                        toggle(group.id)
                    }
                }
                if open { list }
            }
            ForEach(group.failures) { failure in
                ActivityFailureLine(step: failure, isExpanded: isExpanded(failure.id), metrics: metrics,
                                    toggle: { toggle(failure.id) }) { detail(failure) }
            }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func single(_ step: ActivityStep) -> some View {
        VStack(alignment: .leading, spacing: metrics.blockSpacing * 0.8) {
            ActivityLine(step: step, isExpanded: isExpanded(step.id), metrics: metrics) { toggle(step.id) }
            if step.opens, isExpanded(step.id) { detail(step) }
        }
    }

    private var list: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous)
        // The PiP shows the first and latest three lines of an open group, then "Show all N".
        let shown = group.shownLines(limit: metrics.density == .pip && !showsEveryLine ? 4 : nil)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.lines.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                if index == 1, shown.hidden > 0 {
                    Button("Show all \(group.lines.count)") { showsEveryLine = true }
                        .buttonStyle(.plain).font(.system(size: metrics.detailSize)).foregroundStyle(Palette.focus)
                        .padding(.horizontal, metrics.lineInset.width).padding(.vertical, metrics.lineInset.height)
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ActivityLine(step: step, isExpanded: isExpanded(step.id), metrics: metrics) { toggle(step.id) }
                        .padding(.horizontal, metrics.lineInset.width).padding(.vertical, metrics.lineInset.height)
                    if step.opens, isExpanded(step.id) {
                        detail(step)
                            .padding(.horizontal, metrics.lineInset.width).padding(.bottom, metrics.lineInset.height + 3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
    }
}
