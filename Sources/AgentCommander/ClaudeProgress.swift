import SwiftUI

// CLAUDE PROGRESS
// What a quiet local Claude ACP worker last reported about its own turn, for the worker's console
// footer on the wall tile and the focused worker, in every display mode. It reads only the
// service's `claude_progress` member of the worker (`{"updated_at": RFC 3339, "phase": enum}`):
// transcript entries, usage readings and other bookkeeping are never taken as evidence of work.
//
//   Values     ClaudeProgress               the parsed evidence: a phase and the time it was reported
//              ClaudeProgressTrack          present only on an eligible worker (built-in local Claude
//                                           session, delegated worker role); carries the evidence
//              ClaudeProgressDisplay        the display freshness policy at an injected `now`
//   Molecule   ClaudeProgressStatus         the status-area row: `Last update:` phase, clock time and
//                                           advancing age, plus `? progress unknown` and a passive
//                                           `[ Inspect source ]` while progress is unknown
//
// "Unknown" is a display freshness statement, never a stall decision: the worker is not stopped,
// retried or otherwise acted on, and a worker waiting on an addressed request is never called
// unknown. Coordinators, the PiP and other harnesses carry no track and are unchanged.

struct ClaudeProgress: Equatable, Sendable {
    /// The service's phase enum. A value outside it reads as no evidence.
    enum Phase: String, CaseIterable, Sendable {
        case responding, thinking
        case toolPending = "tool_pending", toolRunning = "tool_running", toolCompleted = "tool_completed"
        case toolFailed = "tool_failed", toolCancelled = "tool_cancelled", toolReported = "tool_reported"
        case permissionRequested = "permission_requested"
        case turnCompleted = "turn_completed", turnInterrupted = "turn_interrupted"
        case turnFailed = "turn_failed", turnEnded = "turn_ended"

        /// A neutral label for the last reported event. It names what was reported, not what is
        /// happening now.
        var label: String {
            switch self {
            case .responding: "Responding"
            case .thinking: "Thinking"
            case .toolPending: "Tool pending"
            case .toolRunning: "Tool running"
            case .toolCompleted: "Tool completed"
            case .toolFailed: "Tool failed"
            case .toolCancelled: "Tool cancelled"
            case .toolReported: "Tool reported"
            case .permissionRequested: "Permission requested"
            case .turnCompleted: "Turn completed"
            case .turnInterrupted: "Turn interrupted"
            case .turnFailed: "Turn failed"
            case .turnEnded: "Turn ended"
            }
        }

        /// The outcome of a whole turn. During a newer open turn it is a prior turn's evidence.
        var endsTurn: Bool {
            switch self {
            case .turnCompleted, .turnInterrupted, .turnFailed, .turnEnded: true
            default: false
            }
        }
    }

    /// The service's member name on the worker. A contract value.
    static let fieldName = "claude_progress"

    let phase: Phase
    let updatedAt: Date

    /// The evidence in a worker's fields. Nil when the member is absent, null, not an object, or
    /// carries an unknown phase or an unreadable time.
    static func reported(fields: AGUIValue) -> ClaudeProgress? {
        guard case .object(let progress)? = fields[fieldName],
              let raw = progress["phase"]?.stringValue, let phase = Phase(rawValue: raw),
              let date = parseDate(progress["updated_at"]?.stringValue) else { return nil }
        return ClaudeProgress(phase: phase, updatedAt: date)
    }

    /// RFC 3339 with or without fractional seconds. Nil for anything else.
    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let plain = try? Date(value, strategy: .iso8601) { return plain }
        return try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// Present on a worker only when its progress is tracked: the built-in local Claude native session
/// on a delegated worker. `evidence` is nil when the service sent none (an older service or a newly
/// bound worker) or sent something unreadable.
struct ClaudeProgressTrack: Equatable, Sendable {
    /// The harness instance of the built-in local Claude native session. A contract value.
    static let localClaudeHarness = "local-claude"
    /// The service's role for a delegated worker. A contract value.
    static let delegatedWorkerRole = "worker"

    var evidence: ClaudeProgress?

    /// The track for an eligible worker, or nil for every other worker.
    static func eligible(_ worker: Worker, isCoordinator: Bool) -> ClaudeProgressTrack? {
        guard !isCoordinator, worker.role == delegatedWorkerRole,
              worker.boundSession?.harnessInstance == localClaudeHarness else { return nil }
        return ClaudeProgressTrack(evidence: ClaudeProgress.reported(fields: worker.allFields))
    }
}

/// The display freshness policy, at an injected time so it can be tested without a clock.
struct ClaudeProgressDisplay: Equatable {
    /// Why progress is shown as unknown. Each names its cause for the help tag.
    enum Cause: Equatable {
        /// The turn is open and the service has reported no progress.
        case noEvidence
        /// The service reports the worker's own state as unknown.
        case unknownState
        /// The turn is open and the last evidence is a prior turn's outcome.
        case priorTurnOutcome
        /// The turn is open and the last meaningful update is `staleAfter` seconds old or more.
        case stale
    }

    /// Seconds without a meaningful update during an open turn before progress reads as unknown.
    static let staleAfter: TimeInterval = 30

    let evidence: ClaudeProgress?
    /// Seconds since the evidence, never negative. Nil without evidence.
    let age: TimeInterval?
    /// Nil while the progress is known.
    let unknownCause: Cause?

    var isUnknown: Bool { unknownCause != nil }

    init(track: ClaudeProgressTrack, state: TaskState, now: Date) {
        let evidence = track.evidence
        self.evidence = evidence
        let age = evidence.map { max(0, now.timeIntervalSince($0.updatedAt)) }
        self.age = age
        switch state {
        case .unknown:
            unknownCause = .unknownState
        case .running, .working, .starting:
            // An open turn.
            if let evidence, let age {
                unknownCause = evidence.phase.endsTurn ? .priorTurnOutcome
                    : age >= Self.staleAfter ? .stale : nil
            } else {
                unknownCause = .noEvidence
            }
        case .needsInput, .idle, .stopping, .completed, .failed, .stopped, .disconnected:
            // Waiting on the developer, or no open turn: the last report is shown as it stands,
            // and a waiting worker is never called unknown.
            unknownCause = nil
        }
    }

    /// Whether the footer draws anything. A known worker with no report has nothing to say.
    var isVisible: Bool { evidence != nil || isUnknown }

    // MARK: Words

    /// `12s`, `4m`, `3h`, `2d`: whole units, rounded down.
    static func ageText(_ age: TimeInterval) -> String {
        let seconds = Int(age.rounded(.down))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    /// `12 seconds`, `4 minutes`, for help tags and accessibility.
    static func ageWords(_ age: TimeInterval) -> String {
        let seconds = Int(age.rounded(.down))
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        if seconds < 60 { return unit(seconds, "second") }
        if seconds < 3600 { return unit(seconds / 60, "minute") }
        if seconds < 86_400 { return unit(seconds / 3600, "hour") }
        return unit(seconds / 86_400, "day")
    }

    /// Local `HH:mm:ss`, as `Timestamp.clock` draws times elsewhere in the cockpit.
    var clock: String? {
        evidence.map { evidence in
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: evidence.updatedAt)
            return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        }
    }

    /// The last report as one clause: `Last Claude update: Tool running at 14:16:28, 12 seconds ago.`
    var lastReport: String {
        guard let evidence, let age, let clock else { return "Claude has not reported progress for this worker." }
        return "Last Claude update: \(evidence.phase.label) at \(clock), \(Self.ageWords(age)) ago."
    }

    /// The cause, then the last report. Used for the help tag and the accessible value.
    var statement: String {
        switch unknownCause {
        case nil:
            return lastReport
        case .noEvidence:
            return "Progress unknown: this turn is open and Claude has not reported progress for it."
        case .unknownState:
            return "Progress unknown: the service reports this worker's state as unknown. " + lastReport
        case .priorTurnOutcome:
            return "Progress unknown: this turn is open and the last report is the previous turn's outcome. "
                + lastReport
        case .stale:
            return "Progress unknown: no Claude update in the last \(Int(Self.staleAfter)) seconds of this open turn. "
                + lastReport
        }
    }

    /// The visible report: `tool running · 14:16:28 · 12s`. Nil without evidence.
    var reportText: String? {
        guard let evidence, let age, let clock else { return nil }
        return "\(evidence.phase.label.lowercased()) · \(clock) · \(Self.ageText(age))"
    }
}

// MARK: - Molecule

/// The progress row of a tracked Claude worker, drawn in its own row of the lower status area so
/// the footer's actions and telemetry keep their room. It redraws itself each second through a
/// timeline around this view only, so the age advances and the freshness boundary is crossed
/// without stream traffic. The last phase, clock time and age are never dropped:
///
///   known     `Last update: tool running · 14:16:28 · 12s`
///   unknown   `? progress unknown  Last update: tool running · 14:16:28 · 41s  [ Inspect source ]`
///             on one row, or the report (its time on a second line if needed) above
///             `? progress unknown  [ Inspect source ]` where that is too wide
///   no report `Last update: none`
///
/// The help tag and the accessible value carry the cause and the last report. `[ Inspect source ]`
/// opens this worker's read-only source inspector.
struct ClaudeProgressStatus: View {
    let track: ClaudeProgressTrack
    let state: TaskState
    var workerName: String = ""
    var size: CGFloat = 11
    /// Opens this worker's source inspector. Offered only while progress is unknown.
    var inspectSource: (() -> Void)? = nil

    var body: some View {
        if let evidence = track.evidence {
            TimelineView(ClaudeProgressAgeSchedule(anchor: evidence.updatedAt)) { context in
                face(ClaudeProgressDisplay(track: track, state: state, now: context.date))
            }
        } else {
            // Without evidence the display does not change with time.
            face(ClaudeProgressDisplay(track: track, state: state, now: Date()))
        }
    }

    @ViewBuilder
    private func face(_ display: ClaudeProgressDisplay) -> some View {
        if display.isVisible {
            let inspect = display.isUnknown ? inspectSource : nil
            let gap = size * 0.9
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: gap) {
                    unknownMark(display)
                    report(display, wraps: false)
                    inspectButton(inspect)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 3) {
                    report(display, wraps: true)
                    if display.isUnknown {
                        HStack(alignment: .firstTextBaseline, spacing: gap) {
                            unknownMark(display)
                            inspectButton(inspect)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(Term.font(size))
            .lineLimit(1)
            .monospacedDigit()
            .accessibilityElement(children: .contain)
        }
    }

    /// `? progress unknown`, while progress is unknown. Its meaning is in the report's value.
    @ViewBuilder
    private func unknownMark(_ display: ClaudeProgressDisplay) -> some View {
        if display.isUnknown {
            HStack(spacing: size * 0.45) {
                Text("?")
                Text("progress unknown")
            }
            .foregroundStyle(Term.text)
            .fixedSize()
            .help(display.statement)
            .accessibilityHidden(true)
        }
    }

    /// `Last update: ` then the last phase, its clock time and its advancing age, so the phase
    /// reads as a past report rather than a current claim. Without evidence, `Last update: none`.
    /// When `wraps`, the clock time and age drop to a second line where one line is too wide.
    /// Carries the accessible statement.
    @ViewBuilder
    private func report(_ display: ClaudeProgressDisplay, wraps: Bool) -> some View {
        let spacing = size * 0.45
        Group {
            if let evidence = display.evidence, let clock = display.clock, let age = display.age {
                let phase = HStack(spacing: spacing) {
                    Text("Last update:").foregroundStyle(.inkTermDim)
                    Text(evidence.phase.label.lowercased()).foregroundStyle(Term.text)
                }
                let time = HStack(spacing: spacing) {
                    Text(clock).foregroundStyle(.inkTermDim)
                    Text("·").foregroundStyle(.inkTermDim)
                    Text(ClaudeProgressDisplay.ageText(age)).foregroundStyle(.inkTermDim)
                }
                let oneLine = HStack(spacing: spacing) {
                    phase
                    Text("·").foregroundStyle(.inkTermDim)
                    time
                }.fixedSize()
                if wraps {
                    ViewThatFits(in: .horizontal) {
                        oneLine
                        VStack(alignment: .leading, spacing: 3) { phase; time }.fixedSize()
                    }
                } else {
                    oneLine
                }
            } else {
                HStack(spacing: spacing) {
                    Text("Last update:").foregroundStyle(.inkTermDim)
                    Text("none").foregroundStyle(Term.text)
                }
                .fixedSize()
            }
        }
        .help(display.statement)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workerName.isEmpty ? "Claude progress" : "Claude progress for \(workerName)")
        .accessibilityValue(display.statement)
    }

    @ViewBuilder
    private func inspectButton(_ inspect: (() -> Void)?) -> some View {
        if let inspect {
            Button("Inspect source", action: inspect)
                .buttonStyle(TermButtonStyle(ink: Term.text, size: size))
                .fixedSize()
                .help("Open the read-only source inspector for \(workerName).")
                .accessibilityLabel("Inspect source of \(workerName)")
        }
    }
}

/// Ticks on whole seconds after the report for its first minute, then on whole minutes, so the
/// age text changes exactly when its value does and the 30-second boundary is drawn on time.
struct ClaudeProgressAgeSchedule: TimelineSchedule {
    let anchor: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let elapsed = startDate.timeIntervalSince(anchor)
        var next: Date
        if elapsed <= 0 {
            next = startDate
        } else if elapsed < 60 {
            next = anchor.addingTimeInterval(elapsed.rounded(.down))
        } else {
            next = anchor.addingTimeInterval((elapsed / 60).rounded(.down) * 60)
        }
        let anchor = anchor
        return AnyIterator {
            let current = next
            let age = current.timeIntervalSince(anchor)
            next = age < 0 ? anchor : current.addingTimeInterval(age < 60 ? 1 : 60)
            return current
        }
    }
}
