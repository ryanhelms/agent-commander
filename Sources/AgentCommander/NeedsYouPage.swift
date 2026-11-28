import SwiftUI

// ATOMIC LEVEL: Molecules, organisms and the page (Needs you inbox).
// One list of everything that waits on the person, in the order of urgency. Each row says where
// the request came from and can be decided in place. Every component takes values and emits one
// targeted action; the page owns no request.
//
//   NeedsYouLayout       column widths of the list (foundation)
//   NeedsYouOriginCell   who asks: a worker's square mark, or a server swatch and a friend's avatar
//   NeedsYouKindTag      question, approval, access or friend
//   NeedsYouClockLabel   how long the request has waited, or how long it has left
//   NeedsYouVerbStrip    the row's answers as joined cells, the primary one filled
//   NeedsYouOutcomeWell  the decision, in place of the verb strip
//   NeedsYouReplyField   the answer to a worker's question
//   NeedsYouRow          one request (organism)
//   NeedsYouList         the rows, ruled off by hairlines, or the empty note (organism)
//   NeedsYouPage         header, readouts and the list (page); with a review context, the open
//                        request beside the list or over it (NeedsYouReview.swift)

enum NeedsYouLayout {
    /// The origin cell, so every request starts on the same line.
    static let originWidth: CGFloat = 196
    /// The waiting time or countdown.
    static let clockWidth: CGFloat = 92
    /// The verb strip or the outcome well.
    static let answerWidth: CGFloat = 176
}

// MARK: - Molecules

/// Who asks. A worker is a square mark with its name and host. A friend is the server's swatch and
/// a round avatar with the handle and server.
struct NeedsYouOriginCell: View {
    @Environment(\.theme) private var theme
    let origin: NeedsYouItem.Origin

    var body: some View {
        HStack(spacing: Space.s) {
            switch origin {
            case .worker:
                let shape = RoundedRectangle(cornerRadius: theme.radius.chip, style: .continuous)
                Image(systemName: "terminal")
                    .font(.system(size: theme.space.rowIcon * 0.42, weight: .medium))
                    .foregroundStyle(.theme(\.color.secondary))
                    .frame(width: theme.space.rowIcon, height: theme.space.rowIcon)
                    .background(theme.surface.markFill.color, in: shape)
                    .overlay { shape.strokeBorder(.theme(\.surface.markEdge)) }
                    .padding(.leading, Space.s + 4)
            case .friend(let handle, _, let serverID):
                MultiplayerSwatch(color: MultiplayerTheme.swatch(for: serverID))
                MultiplayerAvatar(image: nil, name: handle, size: theme.space.rowIcon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(origin.name).themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground))
                    .lineLimit(1).truncationMode(.middle)
                Text(origin.place).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        switch origin {
        case .worker(let name, let host): "From your worker \(name) on \(host)"
        case .friend(let handle, let server, _): "From \(handle) on \(server)"
        }
    }
}

/// What kind of request a row is.
struct NeedsYouKindTag: View {
    @Environment(\.theme) private var theme
    let kind: NeedsYouItem.Kind

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.chip, style: .continuous)
        Text(kind.tag)
            .themeType(theme.type.label)
            .textCase(nil)
            .foregroundStyle(.theme(\.color.secondary))
            .lineLimit(1)
            .padding(.horizontal, Space.xs + 1)
            .frame(minHeight: theme.space.chipHeightMin)
            .background(theme.surface.tagFill.color, in: shape)
            .overlay { shape.strokeBorder(.theme(\.surface.tagEdge)) }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// How long the request has left, in tone, or how long it has waited.
struct NeedsYouClockLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil when the request doesn't say when it arrived: the cell then stays empty.
    let waiting: TimeInterval?
    let expiresIn: TimeInterval?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let expiresIn {
                Text(NeedsYouClock.left(expiresIn))
                    .themeType(theme.type.data).monospacedDigit()
                    .foregroundStyle(.theme(expiresIn < NeedsYouInbox.closing ? \.color.attention : \.color.working))
                // The countdown's line: full at the start of the span, empty when the request lapses.
                let tone: KeyPath<Theme, ThemeColor> & Sendable = expiresIn < NeedsYouInbox.closing ? \.color.attention : \.color.working
                Rectangle().fill(.theme(\.color.hair))
                    .frame(width: MultiplayerCountdown.lineWidth, height: 2)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.theme(tone))
                            .frame(width: MultiplayerCountdown.lineWidth * NeedsYouClock.fraction(left: expiresIn, waited: waiting), height: 2)
                            // The line moves evenly through each second; it steps with Reduce Motion.
                            .animation(reduceMotion ? nil : .linear(duration: 1), value: Int(expiresIn))
                    }
                    .accessibilityHidden(true)
            } else if let waiting {
                Text(NeedsYouClock.age(waiting))
                    .themeType(theme.type.data).monospacedDigit()
                    .foregroundStyle(.theme(\.color.foreground))
                Text("waiting").themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary))
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(expiresIn.map { "\(NeedsYouClock.left($0)) left" }
                            ?? waiting.map { "Waiting \(NeedsYouClock.age($0))" } ?? "Waiting")
        .accessibilityHidden(expiresIn == nil && waiting == nil)
    }
}

/// A row's answers as joined cells on one frame. The one primary answer is filled.
struct NeedsYouVerbStrip: View {
    @Environment(\.theme) private var theme
    let verbs: [NeedsYouVerb]
    /// What the answers are about, for VoiceOver and the tooltip.
    let subject: String
    let choose: (NeedsYouVerb) -> Void

    var body: some View {
        let shape = theme.controlShape
        HStack(spacing: 0) {
            ForEach(Array(verbs.enumerated()), id: \.element) { index, verb in
                if index > 0 { Rectangle().fill(.theme(\.surface.controlEdge)).frame(width: theme.line.hairline) }
                Button { choose(verb) } label: {
                    Text(verb.title)
                        .themeType(theme.pageType.control)
                        .foregroundStyle(.theme(verb.isPrimary ? \.color.onAccent : \.surface.controlInk))
                        .lineLimit(1)
                        .padding(.horizontal, Space.m)
                        .frame(minHeight: theme.space.controlHeight)
                        .background((verb.isPrimary ? theme.surface.primaryFill : theme.surface.controlFill).style)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NeedsYouVerbButtonStyle())
                .help("\(verb.title): \(subject)")
                .accessibilityLabel("\(verb.title): \(subject)")
                .accessibilityIdentifier("needs-you-\(verb.rawValue)")
            }
        }
        .fixedSize()
        .clipShape(shape)
        .overlay { shape.strokeBorder(.theme(\.surface.controlEdge), lineWidth: theme.line.hairline) }
    }
}

/// Press feedback for one cell of a verb strip.
struct NeedsYouVerbButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(theme.motion.animation(theme.motion.fast), value: configuration.isPressed)
    }
}

/// The decision, shown where the verb strip was.
struct NeedsYouOutcomeWell: View {
    @Environment(\.theme) private var theme
    let decision: NeedsYouDecision

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
        ThemeStatus(text: decision.title, tone: decision.tone)
            .padding(.horizontal, Space.m)
            .frame(minHeight: theme.space.controlHeight)
            .background(theme.surface.fieldFill.color, in: shape)
            .overlay { shape.strokeBorder(.theme(\.color.hair), lineWidth: theme.line.hairline) }
            .accessibilityIdentifier("needs-you-outcome")
    }
}

/// The answer to a worker's question: a field, then Cancel and Send.
struct NeedsYouReplyField: View {
    @Environment(\.theme) private var theme
    @Binding var draft: String
    let subject: String
    let send: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: Space.s) {
            TextField("Answer \(subject)", text: $draft)
                .textFieldStyle(.plain)
                .themeType(theme.type.body)
                .focused($focused)
                .onSubmit { if !isEmpty { send() } }
                .themeField(focused: focused)
                .accessibilityIdentifier("needs-you-reply-field")
            Button("Cancel", action: cancel)
                .buttonStyle(ThemeButtonStyle(compact: true))
                .keyboardShortcut(.cancelAction)
            Button("Send", action: send)
                .buttonStyle(ThemeButtonStyle(prominent: true, compact: true))
                .disabled(isEmpty)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Organisms

/// One request: who asks, what they ask, how long it has waited, and the answers. Once decided,
/// the outcome takes the answers' place.
struct NeedsYouRow: View {
    @Environment(\.theme) private var theme
    let item: NeedsYouItem
    let isReplying: Bool
    @Binding var draft: String
    let open: () -> Void
    let choose: (NeedsYouVerb) -> Void
    let sendReply: () -> Void
    let cancelReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s + 2) {
            HStack(alignment: .center, spacing: 0) {
                NeedsYouOriginCell(origin: item.origin)
                    .frame(width: NeedsYouLayout.originWidth, alignment: .leading)
                ThemeRule(vertical: true)
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Space.s) {
                            Text(item.title).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                                .lineLimit(1)
                            NeedsYouKindTag(kind: item.kind)
                        }
                        Text(item.failure ?? item.detail).themeType(theme.type.sub)
                            .foregroundStyle(.theme(item.failure == nil ? \.color.secondary : \.color.failure))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, Space.m + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this request")
                .accessibilityLabel("\(item.kind.tag): \(item.title). \(item.failure ?? item.detail)")
                .accessibilityHint("Opens the full request")
                NeedsYouClockLabel(waiting: item.waiting, expiresIn: item.isPending ? item.expiresIn : nil)
                    .frame(width: NeedsYouLayout.clockWidth, alignment: .trailing)
                    .opacity(item.isPending ? 1 : 0)
                    // An answered row keeps the cell's room but says nothing about waiting.
                    .accessibilityHidden(!item.isPending)
                Group {
                    if let decision = item.decision {
                        NeedsYouOutcomeWell(decision: decision).transition(.opacity)
                    } else if !isReplying {
                        NeedsYouVerbStrip(verbs: item.verbs, subject: item.title, choose: choose).transition(.opacity)
                    }
                }
                .frame(width: NeedsYouLayout.answerWidth, alignment: .trailing)
            }
            if isReplying, item.isPending {
                NeedsYouReplyField(draft: $draft, subject: item.origin.name, send: sendReply, cancel: cancelReply)
                    .padding(.leading, NeedsYouLayout.originWidth + Space.m + 2)
            }
        }
        .padding(.vertical, Space.m - 1)
        .padding(.horizontal, Space.m)
        .animation(theme.motion.animation(theme.motion.standard), value: item.decision)
        .animation(theme.motion.animation(theme.motion.standard), value: isReplying)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("needs-you-row-\(item.id)")
    }
}

/// The requests in the order given, ruled off by hairlines on one panel. With none, the note
/// "Nothing is waiting for you".
struct NeedsYouList: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [NeedsYouItem]
    let decide: (String, NeedsYouDecision) -> Void
    let open: (String) -> Void
    /// Where Reply goes when the answer is written somewhere else (the live Attention surfaces).
    /// Nil opens the reply field under the row.
    var reply: ((String) -> Void)? = nil
    /// The list opens requests in place: each row is one button whose only action is Review, and
    /// every decision, reply and outside action is in the review. False keeps the rows' own answers.
    var opensReview = false
    /// A review is beside the list: each row condenses.
    var compact = false
    /// The request shown in the review.
    var selectedID: String? = nil
    /// The row keyboard focus goes back to when the review closes.
    var returnTo: NeedsYouReviewState.Return? = nil
    /// Copies the link that opens a request. Nil offers no link.
    var copyLink: ((String) -> Void)? = nil
    /// The question being answered, and its text so far. Presentation state of this list.
    @State private var replyingID: String?
    @State private var draft = ""
    /// The row whose opening control has keyboard focus, and the one VoiceOver is on. Each row
    /// binds both to its one button.
    @FocusState private var focusedRow: String?
    @AccessibilityFocusState private var spokenRow: String?

    /// How long after a review closes focus is sent to its row, and once more if the first did not
    /// hold: the row is still taking its full form, or the full view is still leaving.
    static let returnDelays: [Duration] = [.milliseconds(90), .milliseconds(240)]

    var body: some View {
        if items.isEmpty {
            ShellLoadNote(text: "Nothing is waiting for you", lamp: .on)
                .accessibilityIdentifier("needs-you-empty")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { ThemeRule() }
                    row(item)
                        // The open row, and the row a closed review returns to, are scrolled into view.
                        .modifier(NeedsYouRowReveal(id: revealID(item.id)))
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .opacity.combined(with: .offset(y: -theme.motion.travel)),
                                                  removal: .opacity.combined(with: .offset(x: theme.motion.travel))))
                }
            }
            .themePanel()
            .animation(theme.motion.animation(theme.motion.standard), value: items.map(\.id))
            .onChange(of: returnTo) { _, target in
                guard let target else { return }
                Task { @MainActor in
                    for delay in Self.returnDelays {
                        try? await Task.sleep(for: delay)
                        guard let row = items.contains(where: { $0.id == target.id }) ? target.id : items.first?.id else { return }
                        if focusedRow == row { break }
                        focusedRow = row
                    }
                    spokenRow = focusedRow
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: NeedsYouItem) -> some View {
        let focus = NeedsYouRowFocus(keyboard: $focusedRow, voiceOver: $spokenRow)
        let copy = copyLink.map { copy in { copy(item.id) } }
        if compact {
            NeedsYouCompactRow(item: item, isSelected: item.id == selectedID, open: { open(item.id) },
                               copyLink: copy, focus: focus)
        } else if opensReview {
            NeedsYouOpenRow(item: item, open: { open(item.id) }, copyLink: copy, focus: focus)
        } else {
            NeedsYouRow(item: item, isReplying: replyingID == item.id, draft: $draft,
                        open: { open(item.id) },
                        choose: { verb in choose(verb, for: item) },
                        sendReply: {
                            decide(item.id, .replied(draft))
                            replyingID = nil
                            draft = ""
                        },
                        cancelReply: {
                            replyingID = nil
                            draft = ""
                        })
        }
    }

    /// A name that is new each time a row should be brought into view: when it opens beside the
    /// list, and when a closed review returns to it.
    private func revealID(_ id: String) -> String? {
        if compact, id == selectedID { return "needs-you-open-\(id)" }
        if !compact, let returnTo, returnTo.id == id { return "needs-you-return-\(id)-\(returnTo.token)" }
        return nil
    }

    private func choose(_ verb: NeedsYouVerb, for item: NeedsYouItem) {
        if let decision = verb.decision {
            decide(item.id, decision)
        } else if let reply {
            reply(item.id)
        } else {
            draft = ""
            replyingID = item.id
        }
    }
}

/// Asks the page to scroll a row into view, once per name. With no name it asks nothing.
struct NeedsYouRowReveal: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id { content.shellRevealed(id) } else { content }
    }
}

// MARK: - Page

/// Needs you: everything that waits on the person, most urgent first. With a review context, a
/// row's one action is Review, which opens that request here: beside the list when both fit,
/// otherwise over it. Every answer is then given in the review. Without one, the rows keep their
/// own answers (a fixture that opts out).
struct NeedsYouPage: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let inbox: NeedsYouInbox
    let decide: (String, NeedsYouDecision) -> Void
    let open: (String) -> Void
    var reply: ((String) -> Void)? = nil
    /// Why the network's requests can't be read or the last answer didn't go through.
    var notice: String? = nil
    /// Opens a request in place. Nil keeps `open` as the row's only way in.
    var review: NeedsYouReviewContext? = nil

    private var readouts: [ShellReadout] {
        var cells = [
            ShellReadout(id: "waiting", label: "waiting", value: "\(inbox.pendingCount)",
                         tone: inbox.pendingCount > 0 ? .attention : .neutral),
            ShellReadout(id: "workers", label: "your workers", value: "\(inbox.localCount)"),
            ShellReadout(id: "network", label: "network", value: "\(inbox.networkCount)")
        ]
        if let soonest = inbox.soonestEnd {
            cells.append(ShellReadout(id: "soonest", label: "first lapses in", value: NeedsYouClock.left(soonest),
                                      tone: soonest < NeedsYouInbox.closing ? .attention : .neutral))
        }
        return cells
    }

    private var subtitle: String {
        inbox.pendingCount == 0
            ? "Questions and approvals from your workers and requests from the network arrive here."
            : "Most urgent first: requests about to lapse, then your stopped workers, then the network."
    }

    var body: some View {
        if let review {
            GeometryReader { geometry in reviewed(review, width: geometry.size.width) }
        } else {
            list(compact: false)
        }
    }

    /// The list with the open request beside it, or under the full view. The list stays in place
    /// under a full view, so closing it returns to the same row at the same scroll position.
    private func reviewed(_ review: NeedsYouReviewContext, width: CGFloat) -> some View {
        let subject = review.state.subject(in: inbox, detail: review.detail, now: review.now)
        let shown = subject.map { _ in NeedsYouReviewLayout.shown(review.state.mode, width: width) }
        return HStack(spacing: 0) {
            list(compact: shown == .aside, review: review, selectedID: subject?.id)
                .frame(width: shown == .aside ? NeedsYouReviewLayout.listWidth : nil)
                .disabled(shown == .full)
                .accessibilityHidden(shown == .full)
            if shown == .aside, let subject {
                ThemeRule(vertical: true)
                panel(subject, shown: .aside, review, width: width)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: theme.motion.travel)))
            }
        }
        .overlay {
            if shown == .full, let subject {
                panel(subject, shown: .full, review, width: width).transition(.opacity)
            }
        }
        .animation(theme.motion.animation(theme.motion.standard), value: shown)
        .onAppear { keep(subject, review) }
        .onChange(of: subject) { _, next in keep(next, review) }
    }

    private func panel(_ subject: NeedsYouReviewSubject, shown: NeedsYouReviewMode, _ review: NeedsYouReviewContext,
                       width: CGFloat) -> some View {
        NeedsYouReview(subject: subject, shown: shown, mode: review.state.mode,
                       offersAside: NeedsYouReviewLayout.fitsAside(width: width),
                       link: NeedsYouRequestLink(id: subject.id)?.url.absoluteString,
                       draft: review.draft, isSending: review.isSending, isOnline: review.isOnline) { action in
            switch action {
            case .close: review.close(inbox.ordered.map(\.id))
            case .setMode(let mode): review.setMode(mode)
            case .copy(let text): review.copy(text)
            case .answer(let text): review.answer(subject.id, text)
            case .openSource: review.openSource(subject.id)
            case .choose(let verb):
                // The request's own answers, routed as they always were. One already on its way is not sent twice.
                guard !review.isSending else { return }
                if let decision = verb.decision { decide(subject.id, decision) } else { (reply ?? open)(subject.id) }
            }
        }
    }

    /// Keeps what the list says about the open request, so its outcome outlives its row.
    private func keep(_ subject: NeedsYouReviewSubject?, _ review: NeedsYouReviewContext) {
        guard let subject, let item = inbox.items.first(where: { $0.id == subject.id }),
              let next = review.state.remembering(item, detail: review.detail, now: review.now) else { return }
        review.remember(next)
    }

    private func list(compact: Bool, review: NeedsYouReviewContext? = nil, selectedID: String? = nil) -> some View {
        var copyLink: ((String) -> Void)?
        if let review {
            copyLink = { id in
                if let link = NeedsYouRequestLink(id: id)?.url.absoluteString { review.copy(link) }
            }
        }
        return WorkspacePage {
            PageHeader(kicker: "WORKSPACE / NEEDS YOU", title: "Needs you", subtitle: compact ? nil : subtitle) { EmptyView() }
        } content: {
            VStack(alignment: .leading, spacing: theme.space.sectionGap) {
                if !compact { ShellReadoutStrip(cells: readouts, large: true) }
                VStack(alignment: .leading, spacing: Space.s + 2) {
                    HStack(spacing: Space.s) {
                        ThemeHeading(text: "Waiting")
                        Text("\(inbox.pendingCount)").themeType(theme.type.heading).textCase(nil)
                            .monospacedDigit().foregroundStyle(.theme(\.color.foreground))
                            .contentTransition(.numericText())
                            .animation(theme.motion.animation(theme.motion.standard), value: inbox.pendingCount)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("Waiting, \(inbox.pendingCount)")
                    if let notice {
                        ShellLoadNote(text: notice, lamp: .error).accessibilityIdentifier("needs-you-notice")
                    }
                    NeedsYouList(items: inbox.ordered, decide: decide, open: review?.open ?? open, reply: reply,
                                 opensReview: review != nil, compact: compact, selectedID: selectedID, returnTo: review?.state.returnTo,
                                 copyLink: copyLink)
                }
            }
        }
    }
}
