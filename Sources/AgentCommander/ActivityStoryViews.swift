import SwiftUI

// ACTIVITY STORY VIEWS
// The parts an opened Pretty line shows for Commander calls linked by an exact ID. The line
// itself, its group and its typed result are in PrettyConversationViews.swift and
// ActivityResultViews.swift; the story card and its header are retired. Values come from
// `ActivityStory`; a part emits only typed `ActivityStoryIntent`s. A request is answered only in
// its existing `PrettyRequestForm`: a Reply or Review approval action focuses that one form, and
// an Open request action routes to it, never a second composer.
//
//   Atom       ActivityStatusMark         (CommanderActivityViews.swift) status word and symbol
//   Molecules  ActivityMilestoneTimeline  the workflow's verified milestones, bounded on the PiP
//              ActivityActionGroup        the targeted actions the parent can perform
//              ActivityRelationList       exact related identities: request, worker, revision, …

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
