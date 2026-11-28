import SwiftUI

// ATOMIC LEVEL: Molecules and the organism (Needs you review).
// One request read in full before it is decided: beside the Needs you list or as a full view.
// Every component takes values and emits one targeted action. None of them answers a request: a
// worker's answer goes out as `.answer`, a row's own answers as `.choose`, and the page routes
// both to the actions that already own them.
//
//   NeedsYouReviewAction    what the review asks for
//   NeedsYouReviewContext   what the page needs to draw a review (values and intents)
//   NeedsYouFactList        labelled lines of identity or scope
//   NeedsYouCopyLink        copies the request's link and says so
//   NeedsYouReviewBar       back or title, the mode, the link and close
//   NeedsYouReviewAnswer    a worker's answer: one button per choice, or a field and Send reply
//   NeedsYouRowFocus        the list's keyboard and VoiceOver focus, by request
//   NeedsYouRowOpening      makes a row's one button the way into its request
//   NeedsYouReviewCue       "Review", drawn as a row's one primary action
//   NeedsYouOpenRow         a full-width row of a list that opens requests in place
//   NeedsYouCompactRow      a row of the list while a review is beside it
//   NeedsYouReview          the open request (organism)

/// What the review asks for. Each is about the one open request.
enum NeedsYouReviewAction: Equatable {
    case close
    case setMode(NeedsYouReviewMode)
    /// Puts a value on the pasteboard: the link, or the request's reference.
    case copy(String)
    /// A worker's answer: the text as written, or a choice's exact ID.
    case answer(String)
    /// One of the row's own answers, with the row's own meaning.
    case choose(NeedsYouVerb)
    /// Opens the page the request lives on.
    case openSource
}

/// What the page needs to draw a review. The feature layer owns the state and every intent.
struct NeedsYouReviewContext {
    var state: NeedsYouReviewState
    /// The open request in full, while its source lists it.
    var detail: NeedsYouDetail?
    var now: Date
    /// The open request's own draft, shared with every other surface that answers it.
    var draft: Binding<String>
    var isSending = false
    var isOnline = true
    var open: (String) -> Void
    /// Closes the review, given the rows in the order shown.
    var close: ([String]) -> Void
    var setMode: (NeedsYouReviewMode) -> Void
    var copy: (String) -> Void
    var answer: (_ id: String, _ text: String) -> Void
    var openSource: (String) -> Void
    /// Keeps what was just seen of the open request.
    var remember: (NeedsYouReviewState) -> Void
}

// MARK: - Molecules

/// Labelled lines: a label at a fixed measure, then the value, which can be selected.
struct NeedsYouFactList: View {
    @Environment(\.theme) private var theme
    let facts: [NeedsYouFact]

    static let labelWidth: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s - 2) {
            ForEach(facts) { fact in
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(fact.label).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                        .frame(width: Self.labelWidth, alignment: .leading)
                    Text(fact.value)
                        .themeType(fact.isData ? theme.type.mono : theme.type.body)
                        .foregroundStyle(.theme(\.color.foreground))
                        .lineLimit(fact.isData ? 1 : 3).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(fact.value)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(fact.label): \(fact.value)")
            }
        }
    }
}

/// Copies the request's link. The button names what it did for a moment: "Copy link", then "Copied link".
struct NeedsYouCopyLink: View {
    @Environment(\.theme) private var theme
    let link: String
    let copy: (String) -> Void
    @State private var copied = false

    var body: some View {
        Button {
            copy(link)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        } label: {
            HStack(spacing: Space.xs + 1) {
                Image(systemName: copied ? "checkmark" : "link").font(.system(size: 9.5, weight: .semibold))
                    .accessibilityHidden(true)
                Text(copied ? "Copied link" : "Copy link")
            }
        }
        .buttonStyle(ThemeButtonStyle(compact: true))
        .help("Copy a link that opens this request in Agent Commander on this Mac")
        .accessibilityLabel(copied ? "Copied link" : "Copy link to this request")
        .accessibilityIdentifier("needs-you-copy-link")
        .animation(theme.motion.animation(theme.motion.fast), value: copied)
    }
}

/// The review's first row: the way back, how it is shown, the link and close.
struct NeedsYouReviewBar: View {
    @Environment(\.theme) private var theme
    /// How the review is shown now, and the mode chosen for this request.
    let shown: NeedsYouReviewMode
    let mode: NeedsYouReviewMode
    /// False when the window is too narrow to show the review beside the list.
    let offersAside: Bool
    let link: String?
    let act: (NeedsYouReviewAction) -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            if shown == .full {
                Button { act(.close) } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "chevron.left").font(.system(size: 9.5, weight: .semibold)).accessibilityHidden(true)
                        Text("Needs you")
                    }
                }
                .buttonStyle(ThemeButtonStyle(compact: true))
                .keyboardShortcut(.cancelAction)
                .help("Back to the list, at this request’s row (Esc)")
                .accessibilityLabel("Back to Needs you")
                .accessibilityIdentifier("needs-you-review-back")
            } else {
                ThemeHeading(text: "Review").accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Space.s)
            if offersAside {
                ShellSegments(options: NeedsYouReviewMode.allCases.map {
                                  (value: $0, title: $0.title,
                                   help: $0 == .aside ? "Show this request beside the list" : "Show this request as a full view")
                              },
                              selection: mode, choose: { act(.setMode($0)) })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("How this request is shown")
                    .accessibilityIdentifier("needs-you-review-mode")
            }
            if let link { NeedsYouCopyLink(link: link) { act(.copy($0)) } }
            if shown == .aside {
                SymbolButton(symbol: "xmark", label: "Close the review (Esc)", size: 10) { act(.close) }
                    .foregroundStyle(.theme(\.color.secondary))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("needs-you-review-close")
            }
        }
        .padding(.horizontal, theme.space.sectionInset)
        .frame(minHeight: theme.space.tabHeight + Space.s)
        .background(theme.surface.footerFill.color)
    }
}

/// A worker's answer. With choices it is one button per choice, and a press sends that choice's
/// exact ID. Without, it is a field and Send reply. It says why it is closed, held or was refused.
struct NeedsYouReviewAnswer: View {
    @Environment(\.theme) private var theme
    let reference: String
    let asker: String
    let choices: [NeedsYouDetail.Choice]
    @Binding var draft: String
    var isSending = false
    var isOnline = true
    /// Why the answer is closed. The controls are off and the draft stays.
    var unavailable: String? = nil
    /// What happens to an answer sent now, when it is held.
    var held: String? = nil
    /// Why the last answer didn't go through.
    var failure: String? = nil
    let answer: (String) -> Void
    @FocusState private var focused: Bool

    private var closed: String? { unavailable ?? (isOnline ? nil : "The local service is offline. Reconnect to answer.") }
    private var blocked: Bool { closed != nil || isSending }
    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let failure {
                line(failure, lamp: .error, role: \.color.failure).accessibilityIdentifier("needs-you-review-failure")
            }
            if let closed {
                line(closed, lamp: .busy, role: \.color.attention)
            } else if let held {
                line(held, lamp: .waiting, role: \.color.secondary)
            }
            if choices.isEmpty { field } else { buttons }
        }
    }

    private func line(_ text: String, lamp: MultiplayerLamp.Kind, role: KeyPath<Theme, ThemeColor> & Sendable) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            MultiplayerLamp(kind: lamp)
            Text(text).themeType(theme.type.sub).foregroundStyle(.theme(role))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(text)
    }

    private var sending: some View {
        HStack(spacing: Space.s) {
            MultiplayerSpinner()
            Text("Sending reply").themeType(theme.type.state).foregroundStyle(.theme(\.color.secondary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sending reply")
    }

    @ViewBuilder private var buttons: some View {
        // One row when the choices fit, otherwise one per line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) { choiceButtons }
            VStack(alignment: .leading, spacing: Space.s) { choiceButtons }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choices for request \(reference)")
    }

    @ViewBuilder private var choiceButtons: some View {
        ForEach(choices) { choice in
            Button { if !blocked { answer(choice.id) } } label: { Text(verbatim: choice.label) }
                .buttonStyle(ThemeButtonStyle())
                .disabled(blocked)
                .help(closed ?? "Reply to \(asker) with \(choice.id)")
                .accessibilityLabel(choice.label)
                .accessibilityHint("Replies to request \(reference) with \(choice.id)")
                .accessibilityIdentifier("needs-you-review-choice-\(choice.id)")
        }
        if isSending { sending }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            TextField("Reply to \(asker)", text: $draft, prompt: Text("Reply to \(asker)"), axis: .vertical)
                .textFieldStyle(.plain)
                .themeType(theme.type.body)
                .lineLimit(1...5)
                .padding(.vertical, Space.s - 2)
                .focused($focused)
                .disabled(blocked)
                .onSubmit { if !blocked, !isEmpty { answer(draft) } }
                .themeField(focused: focused)
                .accessibilityLabel("Reply to request \(reference) from \(asker)")
                .accessibilityHint(closed ?? held ?? "")
                .accessibilityIdentifier("needs-you-review-reply-field")
            if isSending {
                sending.frame(minHeight: theme.space.fieldHeight)
            } else {
                Button("Send reply") { answer(draft) }
                    .buttonStyle(ThemeButtonStyle(prominent: true))
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                    .disabled(blocked || isEmpty)
                    .help(closed ?? "Send this reply to \(asker) (↩ or ⌘↩ while typing)")
                    .accessibilityIdentifier("needs-you-review-send")
            }
        }
    }
}

/// Where focus is on the list's rows, by request ID: the keyboard's and VoiceOver's. The list owns
/// both; each row binds them to its one opening control, so focus can be sent back to a row.
struct NeedsYouRowFocus {
    let keyboard: FocusState<String?>.Binding
    let voiceOver: AccessibilityFocusState<String?>.Binding
}

/// What makes a row's one button the way into its request: it takes keyboard focus whether or not
/// the system's keyboard navigation is on, so a closed review can hand focus back to it; Space and
/// Return open it; VoiceOver reads the request as one element; its menu copies the link.
struct NeedsYouRowOpening: ViewModifier {
    let item: NeedsYouItem
    var isSelected = false
    let focus: NeedsYouRowFocus?
    let open: () -> Void
    var copyLink: (() -> Void)? = nil

    private var spoken: String {
        "\(item.kind.tag): \(item.title). From \(item.origin.name) on \(item.origin.place)"
            + (item.decision.map { ". \($0.title)" } ?? (item.failure.map { ". \($0)" } ?? ""))
    }

    func body(content: Content) -> some View {
        let row = content
            .help("Review this request")
            .contextMenu {
                if let copyLink { Button("Copy Link to Request", action: copyLink) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityHint(isSelected ? "Shown in the review" : "Opens the request’s review, where it is answered")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open() }
            .accessibilityIdentifier("needs-you-row-\(item.id)")
        if let focus {
            row
                // A plain button takes the keyboard only while the system's keyboard navigation is
                // on. This makes the row a focus target always, so `focused` can be set on it.
                .focusable(true, interactions: [.activate, .edit])
                .focused(focus.keyboard, equals: item.id)
                .accessibilityFocused(focus.voiceOver, equals: item.id)
                // Opening the same request twice changes nothing, so the button's own key handling
                // and this one can both run.
                .onKeyPress(keys: [.space, .return]) { _ in
                    open()
                    return .handled
                }
        } else {
            row
        }
    }
}

/// The word "Review" drawn as a row's one primary action. It is part of the row's button, not a
/// control of its own, so the row stays one element.
struct NeedsYouReviewCue: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = theme.controlShape
        Text("Review")
            .themeType(theme.pageType.control)
            .foregroundStyle(.theme(\.color.onAccent))
            .lineLimit(1)
            .padding(.horizontal, Space.m)
            .frame(minHeight: theme.space.controlHeight)
            .background(theme.surface.primaryFill.style, in: shape)
            .overlay { shape.strokeBorder(.theme(\.surface.primaryEdge), lineWidth: theme.line.hairline) }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A row of a list that opens requests in place, at the list's full width: who asks, the request,
/// the clock, and "Review" as its one action. The whole row is one button. Decisions, replies and
/// anything that leaves the page are in the review, never on the row.
struct NeedsYouOpenRow: View {
    @Environment(\.theme) private var theme
    let item: NeedsYouItem
    let open: () -> Void
    var copyLink: (() -> Void)? = nil
    var focus: NeedsYouRowFocus? = nil

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 0) {
                NeedsYouOriginCell(origin: item.origin)
                    .frame(width: NeedsYouLayout.originWidth, alignment: .leading)
                ThemeRule(vertical: true)
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
                NeedsYouClockLabel(waiting: item.waiting, expiresIn: item.isPending ? item.expiresIn : nil)
                    .frame(width: NeedsYouLayout.clockWidth, alignment: .trailing)
                    .opacity(item.isPending ? 1 : 0)
                Group {
                    if let decision = item.decision {
                        NeedsYouOutcomeWell(decision: decision).transition(.opacity)
                    } else {
                        NeedsYouReviewCue().transition(.opacity)
                    }
                }
                .frame(width: NeedsYouLayout.answerWidth, alignment: .trailing)
            }
            .padding(.vertical, Space.m - 1)
            .padding(.horizontal, Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ShellRowButtonStyle())
        .animation(theme.motion.animation(theme.motion.standard), value: item.decision)
        .modifier(NeedsYouRowOpening(item: item, focus: focus, open: open, copyLink: copyLink))
    }
}

/// A row of the list while a review is beside it: the request, who asks and how long it has, as
/// one button that opens it. The answers are in the review.
struct NeedsYouCompactRow: View {
    @Environment(\.theme) private var theme
    let item: NeedsYouItem
    let isSelected: Bool
    let open: () -> Void
    var copyLink: (() -> Void)? = nil
    var focus: NeedsYouRowFocus? = nil

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(item.title).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                        .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s - 2) {
                        NeedsYouKindTag(kind: item.kind)
                        Text("\(item.origin.name) on \(item.origin.place)")
                            .themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let failure = item.failure {
                        Text(failure).themeType(theme.type.sub).foregroundStyle(.theme(\.color.failure))
                            .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.xs)
                if let decision = item.decision {
                    ThemeStatus(text: decision.title, tone: decision.tone)
                } else {
                    NeedsYouClockLabel(waiting: item.waiting, expiresIn: item.expiresIn)
                }
            }
            .padding(.vertical, Space.m - 2)
            .padding(.horizontal, Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ShellSelectable(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .modifier(NeedsYouRowOpening(item: item, isSelected: isSelected, focus: focus, open: open, copyLink: copyLink))
    }
}

// MARK: - Organism

/// The open request: what it is and how it stands, the whole prompt, what it reaches, who asks,
/// what the app already holds about it, and the decision at the foot. Beside the list or as a
/// full view, it is the same organism; only its measure changes.
struct NeedsYouReview: View {
    @Environment(\.theme) private var theme
    let subject: NeedsYouReviewSubject
    let shown: NeedsYouReviewMode
    let mode: NeedsYouReviewMode
    let offersAside: Bool
    /// The link that opens this request from outside the app.
    let link: String?
    @Binding var draft: String
    var isSending = false
    var isOnline = true
    let act: (NeedsYouReviewAction) -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    private var item: NeedsYouItem? { subject.item }
    private var detail: NeedsYouDetail? { subject.detail }
    private var inset: CGFloat { shown == .full ? theme.space.pageInset : theme.space.sectionInset }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeedsYouReviewBar(shown: shown, mode: mode, offersAside: offersAside, link: item == nil ? nil : link, act: act)
            ThemeRule()
            ScrollView(.vertical) {
                Group {
                    if let item { request(item) } else { unlisted }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, inset - 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let item, subject.phase.isOpen {
                ThemeRule()
                decision(item)
                    .padding(.horizontal, inset)
                    .padding(.vertical, Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface.footerFill.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.panelFill.style)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review of \(item?.title ?? "a linked request")")
        .accessibilityIdentifier("needs-you-review")
        .onAppear { titleFocused = true }
        .onChange(of: subject.id) { titleFocused = true }
    }

    // MARK: The request

    @ViewBuilder private func request(_ item: NeedsYouItem) -> some View {
        // In a wide full view, who and what sit beside the prompt; otherwise under it.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: theme.space.sectionGap) {
                    head(item)
                    prompt(item)
                    evidence
                }
                .frame(minWidth: NeedsYouReviewLayout.reviewMinimum, maxWidth: NeedsYouReviewLayout.measure, alignment: .leading)
                ThemeRule(vertical: true)
                VStack(alignment: .leading, spacing: theme.space.sectionGap) { facts }
                    .frame(width: 280, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: theme.space.sectionGap) {
                head(item)
                prompt(item)
                facts
                evidence
            }
            .frame(maxWidth: NeedsYouReviewLayout.measure, alignment: .leading)
        }
    }

    private func head(_ item: NeedsYouItem) -> some View {
        VStack(alignment: .leading, spacing: Space.s + 2) {
            HStack(alignment: .center, spacing: Space.s) {
                NeedsYouKindTag(kind: item.kind)
                if let reference = detail?.reference, !reference.isEmpty {
                    Text(reference).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityLabel("Request \(reference)")
                }
                Spacer(minLength: Space.s)
                ThemeStatus(text: subject.phase.title, tone: subject.phase.tone)
                    .accessibilityIdentifier("needs-you-review-phase")
                if subject.phase.isOpen {
                    NeedsYouClockLabel(waiting: item.waiting, expiresIn: item.expiresIn)
                }
            }
            Text(item.title)
                .themeType(shown == .full ? theme.pageType.pageTitle : theme.type.title)
                .foregroundStyle(.theme(\.color.foreground))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            NeedsYouOriginCell(origin: item.origin)
                // The origin cell insets a worker's mark for the list's column; here it starts the line.
                .padding(.leading, isWorker(item.origin) ? -(Space.s + 4) : 0)
            if let statement = subject.phase.statement {
                ShellNote(text: statement, lamp: lamp(subject.phase))
                    .background(theme.surface.fieldFill.color)
                    .overlay { Rectangle().strokeBorder(.theme(\.color.hair), lineWidth: theme.line.hairline) }
                    .accessibilityIdentifier("needs-you-review-statement")
            }
            if case .answered(.replied(let text)) = subject.phase {
                section("Your reply") {
                    Text(text).themeType(theme.type.body).foregroundStyle(.theme(\.color.foreground))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    private func prompt(_ item: NeedsYouItem) -> some View {
        section("Request") {
            Text(detail?.prompt ?? item.detail)
                .themeType(theme.type.body).lineSpacing(3)
                .foregroundStyle(.theme(\.color.foreground))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("needs-you-review-prompt")
            if let choices = detail?.choices, !choices.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        if index > 0 { ThemeRule() }
                        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                            Text(verbatim: choice.label).themeType(theme.type.body).foregroundStyle(.theme(\.color.foreground))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Space.s)
                            Text(verbatim: choice.id).themeType(theme.type.mono).foregroundStyle(.theme(\.color.secondary))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, Space.m).padding(.vertical, Space.s - 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Choice: \(choice.label), sent as \(choice.id)")
                    }
                }
                .background(theme.surface.fieldFill.color)
                .overlay { Rectangle().strokeBorder(.theme(\.color.hair), lineWidth: theme.line.hairline) }
                .padding(.top, Space.xs)
            }
        }
    }

    @ViewBuilder private var facts: some View {
        if let scope = detail?.scope, !scope.isEmpty {
            section("Scope") { NeedsYouFactList(facts: scope) }
        }
        if let identity = detail?.identity, !identity.isEmpty {
            section("Identity") { NeedsYouFactList(facts: identity) }
        }
    }

    @ViewBuilder private var evidence: some View {
        if let detail, !detail.evidence.isEmpty {
            section(detail.evidenceTitle) {
                MultiplayerOutputWell(text: detail.evidence.joined(separator: "\n"), lines: shown == .full ? 16 : 9)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ThemeHeading(text: title).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: A linked request that isn't listed

    private var unlisted: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ThemeStatus(text: subject.phase.title, tone: subject.phase.tone)
                .accessibilityIdentifier("needs-you-review-phase")
            Text(subject.phase.statement ?? "")
                .themeType(theme.type.body).foregroundStyle(.theme(\.color.foreground))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .accessibilityIdentifier("needs-you-review-statement")
            if subject.phase == .loading { MultiplayerSpinner() }
            NeedsYouFactList(facts: [NeedsYouFact(label: "Request", value: subject.id, isData: true)])
            // The way out is the bar's one command: "‹ Needs you" as a full view, the close mark beside the list.
        }
        .frame(maxWidth: NeedsYouReviewLayout.measure, alignment: .leading)
    }

    // MARK: The decision

    /// The answers, while the request waits. A worker's request is answered here; any other
    /// request takes the row's own answers.
    @ViewBuilder private func decision(_ item: NeedsYouItem) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let detail, detail.answersHere {
                NeedsYouReviewAnswer(reference: detail.reference, asker: item.origin.name, choices: detail.choices,
                                     draft: $draft, isSending: isSending, isOnline: isOnline,
                                     unavailable: detail.unavailable, held: detail.held, failure: item.failure,
                                     answer: { act(.answer($0)) })
                    .frame(maxWidth: NeedsYouReviewLayout.measure, alignment: .leading)
                if let title = detail.sourceTitle { source(title) }
            } else {
                if let failure = item.failure {
                    Text(failure).themeType(theme.type.sub).foregroundStyle(.theme(\.color.failure))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("needs-you-review-failure")
                }
                if let note = detail?.leavesNote {
                    Text(note).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.s) {
                    if let title = detail?.sourceTitle { source(title) }
                    Spacer(minLength: Space.s)
                    if isSending {
                        // This request's own answer is on its way through the network's actions.
                        HStack(spacing: Space.s) {
                            MultiplayerSpinner()
                            Text("Sending").themeType(theme.type.state).foregroundStyle(.theme(\.color.secondary))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel("Sending your answer")
                        .accessibilityIdentifier("needs-you-review-sending")
                    }
                    NeedsYouVerbStrip(verbs: item.verbs, subject: item.title) { verb in
                        if !isSending { act(.choose(verb)) }
                    }
                    .disabled(isSending)
                    .opacity(isSending ? 0.45 : 1)
                }
            }
        }
    }

    private func source(_ title: String) -> some View {
        Button { act(.openSource) } label: {
            HStack(spacing: Space.xs + 1) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .buttonStyle(ThemeButtonStyle(compact: true))
        .help("\(title). This request stays selected in Needs you.")
        .accessibilityHint("Leaves Needs you. This request stays selected.")
        .accessibilityIdentifier("needs-you-review-source")
    }

    private func isWorker(_ origin: NeedsYouItem.Origin) -> Bool {
        if case .worker = origin { return true }
        return false
    }

    private func lamp(_ phase: NeedsYouReviewPhase) -> MultiplayerLamp.Kind {
        switch phase {
        case .waiting, .loading: return .waiting
        case .answered(let decision):
            if decision.tone == .working { return .on }
            return decision.tone == .failure ? .error : .off
        case .expired: return .busy
        case .gone, .missing: return .off
        }
    }
}
