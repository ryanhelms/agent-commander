import SwiftUI

// ACTIVITY STORY VIEWS
// Pretty's narrative activity cards. One card serves every surface that draws `PrettyConsoleView`
// (coordinator, wall tile, focused worker, PiP); its density, type size and targeted actions come
// from that parent. Values come from `ActivityStory`; the card emits only its two disclosure
// toggles and typed `ActivityStoryIntent`s. A request is answered only in its existing
// `PrettyRequestForm`: a Reply or Review approval action focuses that one form, and an Open
// request action routes to it, never a second composer.
//
//   Atom       ActivityStatusMark         (CommanderActivityViews.swift) status word and symbol
//   Molecules  ActivityStoryHeader        symbol, kind, lead, context, failed count, status
//              ActivityMilestoneTimeline  the story's verified milestones, bounded on the PiP
//              ActivityActionGroup        the targeted actions the parent can perform
//              ActivityRelationList       exact related identities: request, worker, revision, …
//              ActivityToolDetails        nested disclosure of every original call (raw rows)
//   Organism   ActivityStoryCard          = header + (timeline + relations + actions + Tool details)
//
// The card takes the raw row renderer as a slot (`member`), so every original call is drawn by
// the console's own `TranscriptToolRow` with its detail, result, error and fields action.

/// What the parent surface supplies: which requests it can act on and how. Built by
/// `PrettyACPConsole` from its own reply context or open-request action.
struct ActivityStoryContext {
    var requests: [ActivityStoryScope.Request] = []
    /// Focuses this surface's one request form for the exact request ID.
    var focusRequest: (@MainActor (String) -> Void)? = nil
    /// Opens the exact request where it is answered.
    var openRequest: (@MainActor (String) -> Void)? = nil

    /// A surface showing `request`'s one form: its action focuses that form.
    @MainActor static func form(for request: RequestPresentation?, reply: ReplyContext?) -> ActivityStoryContext {
        guard let request, let reply else { return ActivityStoryContext() }
        let focus = reply.focus
        // The same conditions that block `PrettyRequestForm`'s field and choices.
        let acceptsInput = reply.isOnline && !reply.sending.contains(request.id)
            && request.replyUnavailableStatement == nil
        return ActivityStoryContext(requests: [ActivityStoryScope.Request(request, route: .form, acceptsInput: acceptsInput)],
                                    focusRequest: { id in focus.wrappedValue = id })
    }

    /// A surface that routes each of `requests` to where it is answered.
    @MainActor static func opens(_ requests: [RequestPresentation],
                                 open: @escaping @MainActor (RequestPresentation) -> Void) -> ActivityStoryContext {
        ActivityStoryContext(requests: requests.map { ActivityStoryScope.Request($0, route: .open) },
                             openRequest: { id in
                                 if let request = requests.first(where: { $0.id == id }) { open(request) }
                             })
    }

    func scope(canOpenSource: Bool) -> ActivityStoryScope {
        // A route is offered only where the parent supplied its action.
        let routed = requests.filter { request in
            switch request.route {
            case .form: focusRequest != nil
            case .open: openRequest != nil
            }
        }
        return ActivityStoryScope(requests: routed, canCopy: true, canOpenSource: canOpenSource)
    }
}

/// MOLECULE. The line that stands for the story: what it is, its lead (the outcome when there is
/// one), its context, and its status. A button: it opens the story.
struct ActivityStoryHeader: View {
    let story: ActivityStory
    let isExpanded: Bool
    var fontSize: CGFloat = 12
    var density: PrettyDensity = .regular
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: fontSize - 3.5, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: fontSize - 2)
                    .accessibilityHidden(true)
                Image(systemName: story.symbol)
                    .font(.system(size: fontSize - 1, weight: .medium))
                    .foregroundStyle(story.status == .awaitingApproval ? Palette.attention : Term.violet)
                    .frame(width: fontSize + 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: density == .pip ? 0 : 2) {
                    HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
                        Text(verbatim: story.kind)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(Palette.foreground.opacity(0.9))
                            .lineLimit(1).fixedSize()
                        if let lead = story.lead {
                            Text(verbatim: lead)
                                .font(Term.font(fontSize - 0.5))
                                .foregroundStyle(Term.text)
                                .lineLimit(isExpanded ? 4 : (density == .pip ? 1 : 2)).truncationMode(.tail)
                        }
                    }
                    if let context = story.context {
                        Text(verbatim: context)
                            .font(Term.font(fontSize - 1.5))
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(isExpanded ? 3 : 1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: fontSize * 0.5)
                if story.failedCalls > 0, story.status != .failed {
                    // A failed call stays visible even while the story is unresolved.
                    Text(story.failedCalls == 1 ? "1 call failed" : "\(story.failedCalls) calls failed")
                        .font(.system(size: fontSize - 2, weight: .medium))
                        .foregroundStyle(Term.red)
                        .lineLimit(1).fixedSize()
                }
                ActivityStatusMark(status: story.status, fontSize: fontSize)
            }
            .padding(.horizontal, fontSize * 0.7).padding(.vertical, fontSize * (density == .pip ? 0.3 : 0.45))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textSelection(.disabled)
        .help(story.reference.map { "Linked by exact \($0)" } ?? story.kind)
        .accessibilityLabel(story.accessibilityLabel)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the story")
    }
}

/// MOLECULE. The story's verified milestones in order. A bounded surface shows the first and the
/// latest, and says how many more are in Tool details. Each row keeps its milestone's identity.
struct ActivityMilestoneTimeline: View {
    let story: ActivityStory
    var limit: Int? = nil
    var fontSize: CGFloat = 12

    var body: some View {
        let timeline = story.timeline(limit: limit)
        let mark = fontSize + 2
        VStack(alignment: .leading, spacing: fontSize * 0.45) {
            ForEach(Array(timeline.shown.enumerated()), id: \.element.id) { index, milestone in
                if index == 1, timeline.hidden > 0 {
                    Text(timeline.hidden == 1 ? "1 more step in Tool details" : "\(timeline.hidden) more steps in Tool details")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.inkSecondary)
                        .padding(.leading, mark + fontSize * 0.5)
                }
                HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
                    Image(systemName: milestone.status.symbol)
                        .font(.system(size: fontSize - 2.5, weight: .semibold))
                        .foregroundStyle(milestone.status.ink)
                        .frame(width: mark)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: milestone.label)
                            .font(.system(size: fontSize - 0.5, weight: .medium))
                            .foregroundStyle(Palette.foreground.opacity(0.88))
                        if let detail = milestone.detail {
                            Text(verbatim: detail)
                                .font(Term.font(fontSize - 1.5))
                                .foregroundStyle(Term.text)
                                .lineLimit(limit == nil ? 6 : 2).truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel([milestone.label, milestone.detail, milestone.status.word].compactMap { $0 }.joined(separator: ", "))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }
}

/// MOLECULE. The targeted actions the parent can perform, as native buttons. The primary one
/// (reply, review approval, open request) is prominent; the rest are quiet.
struct ActivityActionGroup: View {
    let actions: [ActivityStoryAction]
    var fontSize: CGFloat = 12
    var density: PrettyDensity = .regular
    let perform: (ActivityStoryIntent) -> Void

    var body: some View {
        HStack(spacing: fontSize * 0.6) {
            ForEach(actions) { action in
                let button = Button { perform(action.intent) } label: {
                    Label(action.label, systemImage: action.symbol).lineLimit(1)
                }
                .help(action.help)
                .accessibilityHint(action.help)
                if action.isPrimary {
                    button.buttonStyle(.borderedProminent)
                } else {
                    button.buttonStyle(.borderless).foregroundStyle(.inkSecondary)
                }
            }
        }
        .font(.system(size: fontSize - 1))
        .controlSize(density == .regular ? .small : .mini)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }
}

/// MOLECULE. Exact related identities, one line per kind. Text only: selectable, with every exact
/// value in its help. Nothing here navigates.
struct ActivityRelationList: View {
    let relations: [ActivityRelation]
    var fontSize: CGFloat = 12

    private static let order: [ActivityRelation.Kind] = [.request, .worker, .operation, .revision, .test, .file, .tool]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.order, id: \.self) { kind in
                let members = relations.filter { $0.kind == kind }
                if !members.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
                        Text(Self.title(kind, count: members.count))
                            .font(.system(size: fontSize - 2, weight: .medium))
                            .foregroundStyle(.inkSecondary)
                            .frame(minWidth: fontSize * 4.5, alignment: .leading)
                        Text(verbatim: members.map(\.label).joined(separator: ", "))
                            .font(Term.font(fontSize - 1.5))
                            .foregroundStyle(Term.text)
                            .lineLimit(3).truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                    .help(members.map(\.value).joined(separator: "\n"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.title(kind, count: members.count)): \(members.map(\.value).joined(separator: ", "))")
                }
            }
        }
    }

    private static func title(_ kind: ActivityRelation.Kind, count: Int) -> String {
        let one: String
        switch kind {
        case .request: one = "Request"
        case .worker: one = "Worker"
        case .operation: one = "Operation"
        case .revision: one = "Revision"
        case .test: one = "Test"
        case .file: one = "File"
        case .tool: one = "Tool"
        }
        return count == 1 ? one : one + "s"
    }
}

/// MOLECULE. The nested disclosure that keeps every original call, error and field in reach,
/// drawn by the console's raw row through the `member` slot. Collapsed by default.
struct ActivityToolDetails<Member: View>: View {
    let story: ActivityStory
    let isExpanded: Bool
    var fontSize: CGFloat = 12
    var density: PrettyDensity = .regular
    let toggle: () -> Void
    @ViewBuilder let member: (TranscriptEntry) -> Member

    var body: some View {
        let count = story.evidence.count == 1 ? "1 call" : "\(story.evidence.count) calls"
        VStack(alignment: .leading, spacing: density == .pip ? 3 : 5) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.45) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: fontSize - 4, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Tool details").font(.system(size: fontSize - 1, weight: .medium))
                    Text(verbatim: count)
                        .font(Term.font(fontSize - 2))
                        .lineLimit(1)
                }
                .foregroundStyle(.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tool details, \(count)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides every original call with its result and error")
            if isExpanded {
                // The step trail sits inside, so the visible story stays quiet.
                if let steps = story.steps {
                    Text(verbatim: steps)
                        .font(Term.font(fontSize - 2))
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(2).truncationMode(.tail)
                }
                ForEach(story.evidence) { entry in member(entry) }
            }
        }
    }
}

/// ORGANISM. An activity story as one quiet card, collapsed by default. Collapsed, it reads as
/// its header, with the primary action beneath while a decision is pending. Open, it tells the
/// story: the timeline, related identities and actions, then Tool details with every original
/// call. A one-call story whose detail is plain text shows its original call directly instead;
/// with structured arguments it keeps them behind Tool details.
struct ActivityStoryCard<Member: View>: View {
    let story: ActivityStory
    let actions: [ActivityStoryAction]
    let isExpanded: Bool
    let isShowingDetails: Bool
    var fontSize: CGFloat = 12
    var density: PrettyDensity = .regular
    let toggle: () -> Void
    let toggleDetails: () -> Void
    let perform: (ActivityStoryIntent) -> Void
    @ViewBuilder let member: (TranscriptEntry) -> Member

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: fontSize * 0.7, style: .continuous)
        let primary = actions.filter(\.isPrimary)
        let indent = fontSize * 0.7 + (fontSize - 2) + (fontSize + 3) + fontSize
        VStack(alignment: .leading, spacing: 0) {
            ActivityStoryHeader(story: story, isExpanded: isExpanded, fontSize: fontSize, density: density, toggle: toggle)
            if !isExpanded, !primary.isEmpty {
                ActivityActionGroup(actions: primary, fontSize: fontSize, density: density, perform: perform)
                    .padding(.leading, indent).padding(.bottom, fontSize * 0.5)
            }
            if isExpanded {
                Rectangle().fill(.inkHairline).frame(height: 1)
                VStack(alignment: .leading, spacing: fontSize * (density == .pip ? 0.45 : 0.7)) {
                    if story.showsEvidenceDirectly {
                        ForEach(story.evidence) { entry in member(entry) }
                    } else if !story.milestones.isEmpty {
                        ActivityMilestoneTimeline(story: story, limit: density == .pip ? 4 : nil, fontSize: fontSize)
                    }
                    if !story.relations.isEmpty {
                        ActivityRelationList(relations: story.relations, fontSize: fontSize)
                    }
                    if !actions.isEmpty {
                        ActivityActionGroup(actions: actions, fontSize: fontSize, density: density, perform: perform)
                    }
                    if !story.showsEvidenceDirectly {
                        ActivityToolDetails(story: story, isExpanded: isShowingDetails, fontSize: fontSize,
                                            density: density, toggle: toggleDetails, member: member)
                    }
                }
                .padding(.horizontal, fontSize * 0.7).padding(.vertical, fontSize * 0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.well)
            }
        }
        .background(Palette.panel.opacity(0.7), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(story.status == .awaitingApproval ? Palette.attentionEdge
                               : story.isDecisionPending ? Palette.attentionSoftEdge : Palette.hairline,
                               lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
