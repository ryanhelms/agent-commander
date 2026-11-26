import AppKit
import SwiftUI

// ATOMIC LEVEL: Molecules and organisms for live work (design/COMMANDER-NETWORK-INCREMENT-4.md).
// They are drawn with the tray's skin (MultiplayerSkin, MultiplayerTheme): hairline grids, corners
// of two points or less, monospace for data, a lamp and a word for every state. Motion comes only
// from MultiplayerTheme.Motion: trace lines arrive by sliding in under a fade, a countdown ticks,
// a live lamp beats, and all of it stands still with Reduce Motion.
//   Atoms:      MultiplayerSignedBadge, MultiplayerHolderBadge, MultiplayerReadOnlyBadge
//   Molecules:  MultiplayerVerbStrip, MultiplayerTraceRow, MultiplayerCountdown,
//               MultiplayerHolderRow, MultiplayerFindingRow
//   Organisms:  MultiplayerControlBand, MultiplayerWatchView, MultiplayerControlPage,
//               MultiplayerReviewComposer, MultiplayerReviewPage, MultiplayerFanoutComposer,
//               MultiplayerComparePage
// Each takes values and emits actions; MultiplayerPanel wires them to MultiplayerLiveModel.

// MARK: - Molecules

/// One thing a row's subject can do.
struct MultiplayerRowVerb: Identifiable {
    let id: String
    let title: String
    var isPrimary = false
    var isEnabled = true
    /// Said by VoiceOver and shown as the tooltip: the verb with its subject.
    let hint: String
    let action: () -> Void
}

/// A row's actions as joined cells on one hairline frame, so several fit without crowding its text.
struct MultiplayerVerbStrip: View {
    let verbs: [MultiplayerRowVerb]

    @Environment(\.theme) private var theme
    var body: some View {
        let shape = theme.trayControl
        HStack(spacing: 0) {
            ForEach(Array(verbs.enumerated()), id: \.element.id) { index, verb in
                if index > 0 { Rectangle().fill(MultiplayerTheme.border).frame(width: 1) }
                Button(action: verb.action) {
                    Text(verb.title)
                        .font(.system(size: 11, weight: verb.isPrimary ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(verb.isPrimary ? MultiplayerTheme.onAccent : MultiplayerTheme.foreground)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 22)
                        .background(verb.isPrimary ? MultiplayerTheme.focus : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MultiplayerRowButtonStyle())
                .disabled(!verb.isEnabled)
                .opacity(verb.isEnabled ? 1 : 0.45)
                .help(verb.hint)
                .accessibilityLabel(verb.hint)
            }
        }
        .fixedSize()
        .clipShape(shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.border) }
    }
}

/// A result that came sealed from a device whose key this Mac has pinned.
struct MultiplayerSignedBadge: View {
    var body: some View {
        MultiplayerBadge(text: "Signed", symbol: "checkmark.seal.fill", tone: .working)
            .help("Signed by the owner’s device and checked against the key this Mac pinned for it.")
            .accessibilityLabel("Signed by the owner’s pinned device")
    }
}

/// Who holds control of a worker: "<handle> has control", in the attention tone with a hand.
struct MultiplayerHolderBadge: View {
    let who: String

    var body: some View {
        MultiplayerBadge(text: "\(who) has control", symbol: "hand.raised.fill", tone: .attention)
            .accessibilityLabel("\(who) has control")
    }
}

/// Marks a watch view the viewer cannot steer.
struct MultiplayerReadOnlyBadge: View {
    var body: some View {
        MultiplayerBadge(text: "Read-only", symbol: "eye", tone: .neutral)
            .help("You can read this worker’s output. Nothing you type reaches it.")
            .accessibilityLabel("Read-only")
    }
}

/// One line of a watched worker's output: when, what kind, and the text.
struct MultiplayerTraceRow: View {
    let event: MultiplayerWatchEvent

    private var color: Color {
        switch event.kind {
        case .message: MultiplayerTheme.foreground
        case .tool: MultiplayerTheme.focus
        case .status: MultiplayerTheme.attention
        }
    }

    /// "20:14:07", so every line's time is the same width.
    static func time(_ date: Date?) -> String {
        guard let date else { return "--:--:--" }
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    @Environment(\.theme) private var theme
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.time(event.at))
                .font(MultiplayerTheme.fingerprint.monospacedDigit())
                .foregroundStyle(.inkSecondary)
            Text(event.tag)
                .font(MultiplayerTheme.label)
                .foregroundStyle(color)
                .frame(width: (theme.type.label.size * 2.5).rounded(.up), alignment: .leading)
            Text(event.text)
                .font(event.kind == .message ? .system(size: 12) : MultiplayerTheme.mono.font(in: theme))
                .foregroundStyle(event.kind == .status ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(MultiplayerTheme.foreground))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(color.opacity(event.kind == .message ? 0.35 : 0.9)).frame(width: 2) }
        .overlay(alignment: .bottom) { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
        // One static text per line, so assistive apps get a role with the label.
        .accessibilityRepresentation {
            Text("\(event.kindTitle): \(event.text)")
                .accessibilityValue(event.at.map { $0.formatted(date: .omitted, time: .standard) } ?? "")
        }
    }
}

private struct MultiplayerFixedNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// A clock that stands still, for everything below that counts time down: a fixture, a preview
    /// or a headless picture sets it to the instant its data was made for. Nil is the real clock.
    var multiplayerFixedNow: Date? {
        get { self[MultiplayerFixedNowKey.self] }
        set { self[MultiplayerFixedNowKey.self] = newValue }
    }
}

/// Time left, ticking each second, over a line that drains with it.
struct MultiplayerCountdown: View {
    static let lineWidth: CGFloat = 56

    let until: Date
    /// How long the whole span is, in seconds. The line is full at the span and empty at zero.
    let span: TimeInterval
    /// The instant to count from, for a caller with a clock of its own. It stands still: the
    /// figure changes when the caller passes a later instant. Nil counts from the environment's
    /// `multiplayerFixedNow`, or from the real clock, ticking each second.
    var now: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.multiplayerFixedNow) private var fixedNow

    var body: some View {
        if let instant = now ?? fixedNow {
            figure(at: instant)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in figure(at: context.date) }
        }
    }

    private func figure(at instant: Date) -> some View {
            let left = max(until.timeIntervalSince(instant), 0)
            let color = left <= 0 ? MultiplayerTheme.secondary : left < 300 ? MultiplayerTheme.attention : MultiplayerTheme.working
            let text = MultiplayerHandover.clock(left)
            return VStack(alignment: .trailing, spacing: 3) {
                Text(text)
                    .font(MultiplayerTheme.figure.monospacedDigit())
                    .foregroundStyle(color)
                    .multiplayerTicking(text)
                Rectangle().fill(MultiplayerTheme.hair)
                    .frame(width: Self.lineWidth, height: 2)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(color)
                            .frame(width: Self.lineWidth * Self.fraction(left: left, span: span), height: 2)
                            // The line moves evenly through each second; it steps with Reduce Motion.
                            .animation(reduceMotion ? nil : .linear(duration: 1), value: text)
                    }
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(MultiplayerHandover.spoken(left))
    }

    static func fraction(left: TimeInterval, span: TimeInterval) -> Double {
        span > 0 ? min(max(left / span, 0), 1) : 0
    }
}

/// Who holds control of a worker, how long is left, and the way to take it back.
struct MultiplayerHolderRow: View {
    let handover: MultiplayerHandover
    let resourceName: String
    var serverName: String? = nil
    var color: Color? = nil
    let now: Date
    let isBusy: Bool
    var onOpen: (() -> Void)? = nil
    let onTakeBack: () -> Void

    var body: some View {
        let who = handover.who
        HStack(spacing: Space.s) {
            label(who)
            MultiplayerCountdown(until: handover.until, span: handover.span(now: now))
            Button("Take back", action: onTakeBack)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(isBusy)
                .accessibilityLabel("Take back control of \(resourceName) from \(who)")
        }
        .frame(minHeight: 36)
    }

    @ViewBuilder private func label(_ who: String) -> some View {
        let text = VStack(alignment: .leading, spacing: 4) {
            MultiplayerHolderBadge(who: who)
            HStack(spacing: 5) {
                if let color { MultiplayerSwatch(color: color) }
                Text(serverName.map { "\(resourceName) on \($0)" } ?? resourceName)
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        if let onOpen {
            Button(action: onOpen) { text }
                .buttonStyle(.plain)
                .accessibilityLabel("\(who) has control of \(resourceName)\(serverName.map { " on \($0)" } ?? "")")
                .accessibilityHint("Opens control for this worker")
        } else {
            text
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(who) has control of \(resourceName)")
        }
    }
}

/// One finding of a review: how serious, where, and what to do about it.
struct MultiplayerFindingRow: View {
    let finding: MultiplayerFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                MultiplayerBadge(text: finding.severityTitle, tone: finding.isImportant ? .attention : .neutral)
                if !finding.file.isEmpty {
                    Text(finding.location)
                        .font(MultiplayerTheme.mono)
                        .foregroundStyle(MultiplayerTheme.focus)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .help(finding.location)
                }
            }
            Text(finding.text)
                .font(.system(size: 12))
                .foregroundStyle(MultiplayerTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 7)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(finding.isImportant ? MultiplayerTheme.attention : MultiplayerTheme.border).frame(width: 2)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
        .accessibilityRepresentation {
            Text("\(finding.severityTitle), \(finding.file.isEmpty ? "no file" : finding.location). \(finding.text)")
        }
    }
}

private func liveState(_ title: String, _ tone: Tone) -> some View {
    Text(title)
        .font(MultiplayerTheme.state)
        .foregroundStyle(tone == .neutral ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(tone.color))
        .lineLimit(1)
}

private func liveNote(_ text: String, failure: Bool = false) -> some View {
    Text(text)
        .font(MultiplayerTheme.sub)
        .foregroundStyle(failure ? AnyShapeStyle(MultiplayerTheme.failure) : AnyShapeStyle(.inkSecondary))
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Control

/// Workers you have handed over, across servers: who holds each and for how long.
struct MultiplayerControlBand: View {
    let items: [MultiplayerPending<MultiplayerHandover>]
    let resourceName: (MultiplayerPending<MultiplayerHandover>) -> String
    let serverName: (String) -> String
    let now: Date
    let isBusy: Bool
    let onOpen: (MultiplayerPending<MultiplayerHandover>) -> Void
    let onTakeBack: (MultiplayerPending<MultiplayerHandover>) -> Void

    var body: some View {
        if !items.isEmpty {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Control handed over", count: "\(items.count)")
                    ForEach(items) { item in
                        MultiplayerHolderRow(handover: item.item, resourceName: resourceName(item).multiplayerDisplay,
                                             serverName: serverName(item.server),
                                             color: MultiplayerTheme.swatch(for: item.server), now: now, isBusy: isBusy,
                                             onOpen: { onOpen(item) }, onTakeBack: { onTakeBack(item) })
                            .multiplayerArriving()
                    }
                }
                .multiplayerStreaming(items.map(\.id))
            }
        }
    }
}

/// One of your workers: who holds control now, and the form that hands it to a friend for a while.
struct MultiplayerControlPage: View {
    let resourceName: String
    let holders: [MultiplayerHandover]
    let candidates: [String]
    @Binding var draft: MultiplayerHandoverDraft
    let now: Date
    let isBusy: Bool
    let onTakeBack: (MultiplayerHandover) -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Who has control")
                if holders.isEmpty {
                    HStack(spacing: Space.s) {
                        MultiplayerLamp(kind: .off).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("You have control").font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                            liveNote("Friends’ prompts and suggestions to \(resourceName) wait for you, as each grant says.")
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(holders) { handover in
                    MultiplayerHolderRow(handover: handover, resourceName: resourceName, now: now, isBusy: isBusy,
                                         onTakeBack: { onTakeBack(handover) })
                        .multiplayerArriving()
                }
            }
            .multiplayerStreaming(holders.map(\.id))
        }
        // A band with a mono heading, like "Who has control" above it.
        MultiplayerBand {
          VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                MultiplayerBandHeading(title: "Hand over control")
                Text("For the time you choose, one friend’s prompts and suggestions to \(resourceName) run without asking. Control returns when the time ends, or at once when you take it back.")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if candidates.isEmpty {
                liveNote("No friend can prompt or suggest to \(resourceName) yet. Share it with Consult or Suggest first.")
            } else {
                MultiplayerField(label: "Friend") {
                    MultiplayerMenuField(label: "Friend", placeholder: "Choose a friend",
                                         options: candidates.map { (value: $0, title: $0.multiplayerDisplay) },
                                         selection: $draft.handle)
                }
                MultiplayerChoice(label: "For", options: MultiplayerHandoverLength.allCases, title: \.title,
                                  selection: $draft.length,
                                  note: "It still runs on this Mac with your provider account, within the grant’s uses and budget.")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Watch

/// A friend's worker as it runs: whose it is and where, its state, and its output line by line.
/// Read-only. A suggestion, where granted, goes to the owner for approval.
struct MultiplayerWatchView: View {
    let watch: MultiplayerWatchState
    let entry: MultiplayerDirectoryEntry?
    let serverName: String
    let color: Color
    let interval: Int
    @Binding var suggestion: String
    let reply: MultiplayerSentRequest?
    /// False where the view only reads, such as the cockpit's zoom.
    var allowsSuggestion = true
    let onRetry: () -> Void

    private var isLive: Bool { watch.phase == .live }

    var body: some View {
        MultiplayerBand {
            HStack(alignment: .top, spacing: Space.s) {
                MultiplayerMark(symbol: "terminal", tone: isLive ? .working : .neutral, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text((entry?.name ?? watch.resource).multiplayerDisplay)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    if let chip = entry?.capabilities, chip.headline != nil { MultiplayerAgentChip(capabilities: chip) }
                    HStack(spacing: 5) {
                        MultiplayerSwatch(color: color)
                        Text("\(entry?.owner.multiplayerDisplay ?? "A friend") on \(serverName)")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Owned by \(entry?.owner.multiplayerDisplay ?? "a friend") on \(serverName)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    MultiplayerReadOnlyBadge()
                    if isLive { MultiplayerSignedBadge() }
                }
            }
        }
        MultiplayerStatusStrip(cells: [
            MultiplayerReadout(id: "state", label: "worker", value: stateTitle, lamp: lamp, tone: stateTone,
                               spoken: "Worker state, \(stateTitle)"),
            MultiplayerReadout(id: "lines", label: "lines", value: "\(watch.total)",
                               spoken: "\(watch.total) lines read"),
            MultiplayerReadout(id: "read", label: "last read", value: MultiplayerTraceRow.time(watch.lastAt),
                               spoken: "Last read at \(watch.lastAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")"),
        ])
        .fixedSize(horizontal: false, vertical: true)
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 0) {
                MultiplayerBandHeading(title: "Trace") {
                    if watch.phase.isPolling {
                        HStack(spacing: 5) {
                            MultiplayerSpinner(size: 10)
                            Text("every \(interval) s").font(MultiplayerTheme.label).foregroundStyle(.inkSecondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel("Reading every \(interval) seconds")
                    }
                }
                phaseNote
                // Newest first, so a new line arrives where the eye already is.
                ForEach(watch.events.reversed()) { event in
                    MultiplayerTraceRow(event: event).multiplayerArriving()
                }
            }
            .multiplayerStreaming(watch.total)
        }
        if allowsSuggestion, entry?.canSuggest == true {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerField(label: "Suggest a message",
                                     hint: "\(entry?.owner.multiplayerDisplay ?? "The owner") approves each suggestion before the worker sees it. You get the worker’s answer.") {
                        MultiplayerTextArea(label: "Suggestion", text: $suggestion, lines: 2)
                    }
                    if let reply {
                        if reply.succeeded {
                            MultiplayerWell(edge: MultiplayerTheme.working.opacity(0.45)) {
                                Text(reply.value?.readable ?? "")
                                    .font(.system(size: 12))
                                    .foregroundStyle(MultiplayerTheme.foreground)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .accessibilityLabel("The worker’s answer: \(reply.value?.readable ?? "")")
                        } else {
                            liveNote(reply.status.lowercased() == "denied" ? "The owner denied that suggestion."
                                                                           : "Your suggestion is waiting for the owner.",
                                     failure: reply.status.lowercased() == "denied")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var phaseNote: some View {
        switch watch.phase {
        case .connecting:
            liveNote("Asking the owner’s Mac for the worker’s output…").padding(.vertical, 6)
        case .waiting(let text):
            liveNote(text).padding(.vertical, 6)
        case .stopped(let text):
            VStack(alignment: .leading, spacing: Space.s) {
                liveNote(text.isEmpty ? "The watch stopped." : text, failure: true)
                Button("Watch again", action: onRetry).buttonStyle(MultiplayerTrayButtonStyle())
            }
            .padding(.vertical, 6)
        case .failed(let text):
            VStack(alignment: .leading, spacing: Space.s) {
                liveNote(MultiplayerSentence.join("Couldn’t read the output.", text), failure: true)
                Button("Try again", action: onRetry).buttonStyle(MultiplayerTrayButtonStyle())
            }
            .padding(.vertical, 6)
        case .live:
            if watch.events.isEmpty {
                liveNote("Nothing yet. Lines appear here as the worker produces them.").padding(.vertical, 6)
            }
        }
    }

    private var stateTitle: String { watch.stateTitle }
    private var stateTone: Tone { watch.stateTone }
    private var lamp: MultiplayerLamp.Kind { watch.lamp }
}

extension MultiplayerWatchState {
    /// True when the worker has stopped to wait for a person: "awaiting_input", "waiting".
    var isAwaiting: Bool {
        let raw = state.lowercased()
        return raw.contains("await") || raw.contains("waiting")
    }

    var stateTitle: String {
        switch phase {
        case .connecting: "Connecting"
        case .waiting: "Waiting"
        case .stopped: "Stopped"
        case .failed: "No signal"
        case .live: state.isEmpty ? "Live" : MultiplayerRequestState.title(state)
        }
    }

    var stateTone: Tone {
        switch phase {
        case .connecting, .waiting: .focus
        case .stopped, .failed: .failure
        case .live: state.isEmpty ? .working : isAwaiting ? .attention : MultiplayerRequestState.tone(state)
        }
    }

    /// The lamp beside the worker's state. A worker waiting for input shows the open arc.
    var lamp: MultiplayerLamp.Kind {
        switch phase {
        case .connecting, .waiting: .waiting
        case .stopped, .failed: .error
        case .live:
            isAwaiting ? .waiting : stateTone == .failure ? .error : stateTone == .attention ? .busy
                : stateTone == .neutral ? .off : .on
        }
    }
}

// MARK: - Review exchange

/// A change for a friend's worker to review: its title, a pull request or a diff, and what to look for.
struct MultiplayerReviewComposer: View {
    @Binding var draft: MultiplayerReviewDraft
    let entry: MultiplayerDirectoryEntry?
    let attachProblem: String?
    let onChoose: () -> Void
    let onDrop: ([URL]) -> Void
    let onDetach: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        MultiplayerEditorTemplate(title: "Ask \(name) for a review",
                                  intro: "The worker reads the change on your friend’s Mac and answers with a summary and findings. Nothing is posted anywhere until you choose to.") {
            MultiplayerField(label: "Title") {
                MultiplayerTextField(label: "Title", placeholder: "What the change does", text: $draft.title, isFocused: focused)
                    .focused($focused)
            }
            MultiplayerField(label: "Pull request", hint: draft.diff == nil ? "Give a pull request, a diff, or both." : nil) {
                MultiplayerTextField(label: "Pull request URL", placeholder: "https://github.com/owner/repo/pull/12",
                                     text: $draft.pr, monospaced: true)
            }
            MultiplayerField(label: "Diff", hint: draft.diff == nil ? "One text file of up to 96 KiB. Drop it here or choose it." : nil,
                             problem: attachProblem) {
                VStack(alignment: .leading, spacing: 4) {
                    if let diff = draft.diff {
                        HStack(spacing: Space.s) {
                            Image(systemName: "plusminus").font(.system(size: 11)).foregroundStyle(.inkSecondary)
                            Text(diff.name.multiplayerDisplay)
                                .font(MultiplayerTheme.mono)
                                .foregroundStyle(MultiplayerTheme.foreground)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: Space.s)
                            Text(MultiplayerContextBundle.size(diff.bytes))
                                .font(MultiplayerTheme.sub.monospacedDigit())
                                .foregroundStyle(.inkSecondary)
                            SymbolButton(symbol: "xmark", label: "Remove \(diff.name.multiplayerDisplay)", action: onDetach)
                                .foregroundStyle(.inkSecondary)
                        }
                        .accessibilityElement(children: .contain)
                    }
                    Button(action: onChoose) { Label(draft.diff == nil ? "Attach diff…" : "Replace diff…", systemImage: "paperclip") }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    if !files.isEmpty { onDrop(files) }
                    return !files.isEmpty
                }
            }
            MultiplayerField(label: "Instructions", hint: "Optional. What to look at first.", problem: draft.problem) {
                MultiplayerTextArea(label: "Instructions", text: $draft.instructions, lines: 3)
            }
        }
        .onAppear { focused = true }
    }

    private var name: String {
        guard let entry else { return "a friend’s worker" }
        return "\(entry.owner.multiplayerDisplay)’s \(entry.name.multiplayerDisplay)"
    }
}

/// A review that came back: its summary, each finding, and the one way it reaches a pull request.
struct MultiplayerReviewPage: View {
    let row: MultiplayerSentRequest
    let target: String
    let review: MultiplayerReview?
    let now: Date
    @Binding var link: String
    /// The pull request this review was posted to from this panel.
    let posted: String?
    let confirming: Bool
    let problem: String?
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Names the confirmation for the page's scroll view.
    static let confirmation = "multiplayer.review.post-confirmation"

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) { bands }
                // The confirmation opens under the fold. Bring it into view once it is laid out.
                .onChange(of: confirming) { _, isOn in
                    guard isOn else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(30))
                        withAnimation(reduceMotion ? nil : MultiplayerTheme.Motion.ease()) {
                            proxy.scrollTo(Self.confirmation, anchor: .bottom)
                        }
                    }
                }
                .onAppear { if confirming { proxy.scrollTo(Self.confirmation, anchor: .bottom) } }
        }
    }

    @ViewBuilder private var bands: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(row.title.isEmpty ? "Untitled review" : row.title.multiplayerDisplay)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    liveState(review == nil ? MultiplayerRequestState.title(row.status) : "Reviewed",
                              review == nil ? MultiplayerRequestState.tone(row.status) : .working)
                }
                MultiplayerSummaryLine(label: "Reviewer", value: target)
                MultiplayerSummaryLine(label: "Sent", value: MultiplayerActivityRow.time(row.at, now: now), monospaced: true)
                if review != nil {
                    HStack(spacing: 6) {
                        MultiplayerSignedBadge()
                        if posted != nil { MultiplayerBadge(text: "Posted", symbol: "arrow.up.right", tone: .focus) }
                    }
                } else if let refusal = row.refusal {
                    liveNote(refusal, failure: MultiplayerRequestState.tone(row.status) == .failure)
                }
            }
        }
        if let review {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: "Summary")
                    MultiplayerWell {
                        Text(review.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 0) {
                    MultiplayerBandHeading(title: "Findings", count: review.findings.isEmpty ? nil : "\(review.findings.count)") {
                        if !review.findings.isEmpty { liveState(review.tally, review.important > 0 ? .attention : .neutral) }
                    }
                    if review.findings.isEmpty {
                        liveNote("The review listed no findings.").padding(.vertical, 4)
                    }
                    ForEach(review.findings) { MultiplayerFindingRow(finding: $0) }
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: "Post to a pull request")
                    MultiplayerField(label: "Pull request",
                                     hint: "Posts the summary and \(count(review)) as one review comment, from your GitHub login, through gh on this Mac.") {
                        MultiplayerTextField(label: "Pull request URL", placeholder: "https://github.com/owner/repo/pull/12",
                                             text: $link, monospaced: true)
                            .disabled(confirming || isBusy)
                    }
                    if confirming {
                        MultiplayerWell(edge: MultiplayerTheme.attention.opacity(0.6)) {
                            VStack(alignment: .leading, spacing: Space.s) {
                                Text("Post this review to the pull request?")
                                    .font(MultiplayerTheme.name)
                                    .foregroundStyle(MultiplayerTheme.foreground)
                                Text(link.trimmingCharacters(in: .whitespacesAndNewlines).multiplayerDisplay)
                                    .font(MultiplayerTheme.mono)
                                    .foregroundStyle(MultiplayerTheme.focus)
                                    .fixedSize(horizontal: false, vertical: true)
                                liveNote("Everyone who can see the pull request sees it, under your name. A posted comment can’t be taken back from here.")
                                HStack(spacing: Space.s) {
                                    Spacer(minLength: 0)
                                    Button("Don’t post", action: onCancel)
                                        .buttonStyle(MultiplayerTrayButtonStyle())
                                        .keyboardShortcut(.cancelAction)
                                    Button("Post review", action: onConfirm)
                                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                                        .disabled(isBusy || problem != nil)
                                }
                            }
                        }
                        .multiplayerArriving()
                        .id(Self.confirmation)
                    } else if let posted {
                        liveNote("Posted to \(posted.multiplayerDisplay).")
                    } else {
                        liveNote("Nothing has been posted. Commander never posts a review by itself.")
                    }
                }
                .multiplayerStreaming(confirming)
            }
        }
    }

    private func count(_ review: MultiplayerReview) -> String {
        review.findings.count == 1 ? "1 finding" : "\(review.findings.count) findings"
    }
}

// MARK: - Fan-out

/// One prompt for several friends' workers: which ones, and what to ask.
struct MultiplayerFanoutComposer: View {
    @Binding var draft: MultiplayerFanoutDraft
    let targets: [MultiplayerDirectoryEntry]
    let onToggle: (String) -> Void

    var body: some View {
        MultiplayerEditorTemplate(title: "Send one prompt to several workers",
                                  intro: "Each worker answers by itself on its owner’s Mac. You then compare the answers side by side and mark the one you’ll use.") {
            MultiplayerField(label: "Workers",
                             hint: draft.targets.count < 2 ? "Choose at least 2." : "\(draft.targets.count) chosen. Each uses one of your granted uses.") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(targets) { entry in
                        let isOn = draft.targets.contains(entry.id)
                        Button { onToggle(entry.id) } label: {
                            HStack(spacing: Space.s) {
                                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 14))
                                    .foregroundStyle(isOn ? MultiplayerTheme.focus : MultiplayerTheme.border)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name.multiplayerDisplay)
                                        .font(MultiplayerTheme.name)
                                        .foregroundStyle(MultiplayerTheme.foreground)
                                        .lineLimit(1)
                                    Text(entry.owner.multiplayerDisplay).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let chip = entry.capabilities, chip.headline != nil { MultiplayerAgentChip(capabilities: chip) }
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MultiplayerRowButtonStyle())
                        .accessibilityLabel("\(entry.name.multiplayerDisplay), \(entry.owner.multiplayerDisplay)")
                        .accessibilityValue(isOn ? "on" : "off")
                        .accessibilityAddTraits(.isToggle)
                    }
                }
            }
            MultiplayerField(label: "Prompt", problem: draft.problem) {
                MultiplayerTextArea(label: "Prompt", text: $draft.prompt, lines: 5)
            }
        }
    }
}

/// A fan-out's answers in columns, one per worker, with the way to mark a winner.
struct MultiplayerComparePage: View {
    struct Column: Identifiable {
        let child: MultiplayerFanoutChild
        let name: String
        let owner: String
        let capabilities: MultiplayerCapabilities?

        var id: String { child.id }
    }

    let fanout: MultiplayerFanout
    let columns: [Column]
    let winner: String?
    let now: Date
    let onChoose: (MultiplayerFanoutChild) -> Void
    let onThread: (MultiplayerFanoutChild) -> Void

    /// Two columns share the tray's width; more keep a readable measure and scroll sideways.
    static let columnWidth: CGFloat = 196

    @Environment(\.theme) private var theme
    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(fanout.title.isEmpty ? "Untitled fan-out" : fanout.title.multiplayerDisplay)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    liveState(fanout.progress, fanout.isSettled ? .working : .attention)
                        .multiplayerTicking(fanout.answered)
                }
                HStack(spacing: 6) {
                    (Text("\(columns.count) workers, sent ").font(MultiplayerTheme.sub.font(in: theme))
                        + Text(MultiplayerActivityRow.time(fanout.at, now: now)).font(MultiplayerTheme.fingerprint.font(in: theme)))
                        .foregroundStyle(.inkSecondary)
                    Spacer(minLength: 0)
                    if fanout.answered > 0 { MultiplayerSignedBadge() }
                }
            }
        }
        if columns.isEmpty {
            MultiplayerBand { liveNote("Commander no longer has this fan-out’s targets. Send it again to compare.") }
        } else if columns.count <= 2 {
            grid(width: nil)
        } else {
            ScrollView(.horizontal) { grid(width: Self.columnWidth) }
                .scrollIndicators(.visible)
                .accessibilityLabel("Answers, \(columns.count) columns")
        }
    }

    private func grid(width: CGFloat?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(width: 1) }
                    cell(column)
                        .frame(width: width)
                        .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(MultiplayerTheme.hair).frame(height: 1)
        }
        .animation(MultiplayerTheme.Motion.ease(), value: winner)
    }

    private func cell(_ column: Column) -> some View {
        let child = column.child
        let isWinner = winner == child.id
        let tone = MultiplayerRequestState.tone(child.status)
        return VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(column.name.multiplayerDisplay)
                    .font(MultiplayerTheme.name)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(column.owner.multiplayerDisplay)
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                if let chip = column.capabilities, chip.headline != nil { MultiplayerAgentChip(capabilities: chip) }
                MultiplayerStateLabel(lamp: child.succeeded ? .on : child.isSettled ? .error : .waiting,
                                      text: MultiplayerRequestState.title(child.status), tone: tone)
                    .padding(.top, 2)
            }
            .accessibilityElement(children: .combine)
            Rectangle().fill(MultiplayerTheme.hair).frame(height: 1)
            if child.succeeded {
                Text(child.answer)
                    .font(.system(size: 12))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if child.isSettled {
                liveNote(MultiplayerSentRequest(request: child.id, status: child.status).refusal ?? "No answer.", failure: true)
            } else {
                HStack(spacing: 6) {
                    MultiplayerSpinner(size: 10)
                    liveNote("Waiting for this worker.")
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.s) {
                if child.succeeded {
                    Button(isWinner ? "Winner" : "Choose winner") { onChoose(child) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: isWinner ? .primary : .standard))
                        .help(isWinner ? "Clear this choice" : "Mark this answer as the one you’ll use")
                        .accessibilityLabel(isWinner ? "\(column.name.multiplayerDisplay) is the winner"
                                                     : "Choose \(column.name.multiplayerDisplay) as the winner")
                        .accessibilityHint(isWinner ? "Clears the choice" : "Recorded on this Mac only")
                        .accessibilityAddTraits(isWinner ? .isSelected : [])
                }
                Spacer(minLength: 0)
                SymbolButton(symbol: "bubble.left.and.bubble.right", label: "Thread with \(column.name.multiplayerDisplay)") { onThread(child) }
                    .foregroundStyle(.inkSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(isWinner ? MultiplayerTheme.selection.opacity(0.35) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(isWinner ? MultiplayerTheme.focus : Color.clear).frame(height: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.name.multiplayerDisplay), \(column.owner.multiplayerDisplay)\(isWinner ? ", winner" : "")")
    }
}
