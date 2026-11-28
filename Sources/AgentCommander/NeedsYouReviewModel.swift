import Foundation

// ATOMIC LEVEL: Values (Needs you review).
// One request of the Needs you inbox, opened where it is listed: beside the list or as a full view,
// chosen per request. The values here say which request is open, how it is shown, what it reads
// as once it is answered, lapsed, gone or not yet listed, and where an outside link lands. None of
// them answers a request: an answer goes through the page's own actions.
//
//   NeedsYouReviewMode      beside the list, or the full view
//   NeedsYouFact            one labelled line of identity or scope
//   NeedsYouDetail          the full request: prompt, choices, identity, scope and evidence
//   NeedsYouReviewPhase     waiting, answered, expired, gone, loading or missing
//   NeedsYouReviewSubject   the open request as the review draws it
//   NeedsYouReviewState     the open request, each request's mode, and what was last seen of it
//   NeedsYouReviewLayout    whether the review fits beside the list
//   CommanderExternalLink   an `agentcommander://` URL as the one thing it opens

/// How a request's review is shown. Kept per request.
enum NeedsYouReviewMode: String, CaseIterable, Sendable {
    /// Beside the list, which stays in view.
    case aside
    /// In place of the list, at a reading measure.
    case full

    var title: String { self == .aside ? "Beside" : "Full" }
}

/// One labelled line: who, where, or what the request reaches.
struct NeedsYouFact: Equatable, Sendable, Identifiable {
    let label: String
    let value: String
    /// The value is an identifier or a path: drawn as data, cut in the middle, read in full.
    var isData = false

    var id: String { label }
}

/// Everything the source says about one request, read before a decision.
struct NeedsYouDetail: Equatable, Sendable {
    struct Choice: Equatable, Sendable, Identifiable {
        /// The exact ID the service accepts. The answer is this, never the label.
        let id: String
        let label: String
    }

    /// The request's own short reference, as its source names it ("Q-018").
    var reference: String
    /// The whole prompt, as sent.
    var prompt: String
    /// The answers the source offered. Empty for a free-form question and for a network request.
    var choices: [Choice] = []
    /// Who asks, and on whose behalf.
    var identity: [NeedsYouFact] = []
    /// What the request reaches: the project, run, resource or permission.
    var scope: [NeedsYouFact] = []
    /// What the app already holds that bears on the decision, newest last. Empty when it holds none.
    var evidence: [String] = []
    var evidenceTitle = "Recent output"
    /// A worker's request, answered here through the cockpit's reply action.
    var answersHere = false
    /// Why the answer is closed, in full. Nil when the request can be answered.
    var unavailable: String? = nil
    /// What happens to an answer sent now, when it is held. Nil otherwise.
    var held: String? = nil
    /// The page the request lives on, as a secondary action: "Open worker", "Open in Approvals".
    var sourceTitle: String? = nil
    /// What an answer that leaves this page does, so it is told apart from one that decides here:
    /// Review opens the grant sheet, Sign in opens the harness's own sign-in.
    var leavesNote: String? = nil
}

/// What the open request reads as.
enum NeedsYouReviewPhase: Equatable, Sendable {
    case waiting
    case answered(NeedsYouDecision)
    /// Its time ran out before an answer.
    case expired
    /// It was listed and no longer is: answered somewhere else, or withdrawn by its source.
    case gone
    /// A link named it and the lists that would hold it have not been read yet.
    case loading
    /// A link named it and nothing lists it.
    case missing

    /// The state word beside the lamp.
    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .answered(let decision): decision.title
        case .expired: "Expired"
        case .gone: "No longer waiting"
        case .loading: "Looking"
        case .missing: "Not found"
        }
    }

    var tone: Tone {
        switch self {
        case .waiting, .expired: .attention
        case .answered(let decision): decision.tone
        case .gone, .missing: .neutral
        case .loading: .focus
        }
    }

    /// One sentence saying what happened and what to do, for every phase but waiting.
    var statement: String? {
        switch self {
        case .waiting: nil
        case .answered(.inReview): "The review is open on its own page. This request stays here until it is answered."
        case .answered: "This request is answered. Nothing more is needed."
        case .expired: "This request ran out of time before it was answered. Its sender has to ask again."
        case .gone: "This request is no longer waiting. It was answered somewhere else or withdrawn."
        case .loading: "Looking for this request. It shows here as soon as it is listed."
        case .missing: "No request with this link is waiting. It may be answered, expired or withdrawn, or belong to another Mac."
        }
    }

    /// The request can still be decided.
    var isOpen: Bool { self == .waiting }
}

/// The open request as the review draws it. `item` is nil while a linked request is unlisted.
struct NeedsYouReviewSubject: Equatable, Sendable {
    let id: String
    var phase: NeedsYouReviewPhase
    var item: NeedsYouItem? = nil
    var detail: NeedsYouDetail? = nil
}

/// Presentation state of the review, keyed by request ID. It belongs to the feature layer.
struct NeedsYouReviewState: Equatable, Sendable {
    /// What was last seen of the open request, so its outcome stays readable after it is unlisted.
    struct Snapshot: Equatable, Sendable {
        var item: NeedsYouItem
        var detail: NeedsYouDetail?
        /// When the request lapses, as a fixed time. Nil when it has no end.
        var deadline: Date?
    }

    /// The row keyboard focus goes back to. `token` changes with each return.
    struct Return: Equatable, Sendable {
        let id: String
        let token: Int
    }

    private(set) var selectedID: String?
    /// The mode each request was last shown in. A request never opened is shown beside the list.
    private(set) var modes: [String: NeedsYouReviewMode] = [:]
    private(set) var remembered: Snapshot?
    /// False while a link's request may not be listed yet: the lists are still being read.
    var isSettled = true
    private(set) var returnTo: Return?

    /// A request ending within this of its deadline when it left counts as expired.
    static let expiryMargin: TimeInterval = 2

    var isOpen: Bool { selectedID != nil }

    func mode(for id: String) -> NeedsYouReviewMode { modes[id] ?? .aside }
    var mode: NeedsYouReviewMode { selectedID.map(mode(for:)) ?? .aside }

    /// Opens a request. `settled` is false for a link that arrives before the lists are read.
    mutating func open(_ id: String, settled: Bool = true) {
        if selectedID != id { remembered = nil }
        selectedID = id
        isSettled = settled
    }

    /// Sets the mode of the open request only.
    mutating func setMode(_ mode: NeedsYouReviewMode) {
        guard let selectedID else { return }
        modes[selectedID] = mode
    }

    /// Closes the review and names the row focus returns to: the same row when it is still listed,
    /// otherwise the first row, otherwise none. `rows` is the list in the order shown.
    mutating func close(rows: [String]) {
        guard let id = selectedID else { return }
        let target = rows.contains(id) ? id : rows.first
        selectedID = nil
        remembered = nil
        isSettled = true
        returnTo = target.map { Return(id: $0, token: (returnTo?.token ?? 0) + 1) }
    }

    /// The state after seeing the open request listed, or nil when nothing worth keeping changed.
    /// The time a request has waited and has left change each second and are not kept.
    func remembering(_ item: NeedsYouItem, detail: NeedsYouDetail?, now: Date) -> NeedsYouReviewState? {
        guard item.id == selectedID else { return nil }
        var still = item
        still.waiting = nil
        still.expiresIn = nil
        // An answer given here stands while the source still lists the request as waiting.
        if still.decision == nil, let kept = remembered, kept.item.id == item.id, let decision = kept.item.decision {
            still.decision = decision
            still.failure = nil
        }
        let deadline = item.expiresIn.map { now.addingTimeInterval($0) }
        if let remembered, remembered.item == still, remembered.detail == (detail ?? remembered.detail),
           (remembered.deadline == nil) == (deadline == nil) {
            return nil
        }
        var next = self
        next.remembered = Snapshot(item: still, detail: detail ?? remembered?.detail, deadline: deadline ?? remembered?.deadline)
        next.isSettled = true
        return next
    }

    /// Records an answer given here, so it stays readable once the source drops the request.
    mutating func recordAnswer(_ id: String, _ decision: NeedsYouDecision) {
        guard id == selectedID, var snapshot = remembered, snapshot.item.id == id else { return }
        snapshot.item.decision = decision
        snapshot.item.failure = nil
        remembered = snapshot
    }

    /// The open request, read from the inbox when it is listed and from what was last seen when
    /// it is not. Nil when no request is open.
    func subject(in inbox: NeedsYouInbox, detail: NeedsYouDetail?, now: Date) -> NeedsYouReviewSubject? {
        guard let id = selectedID else { return nil }
        let kept = remembered?.item.id == id ? remembered : nil
        if let item = inbox.items.first(where: { $0.id == id }) {
            let phase: NeedsYouReviewPhase
            if let decision = item.decision ?? kept?.item.decision {
                phase = .answered(decision)
            } else if let left = item.expiresIn, left <= 0 {
                phase = .expired
            } else {
                phase = .waiting
            }
            return NeedsYouReviewSubject(id: id, phase: phase, item: item, detail: detail ?? kept?.detail)
        }
        guard let kept else {
            return NeedsYouReviewSubject(id: id, phase: isSettled ? .missing : .loading)
        }
        let phase: NeedsYouReviewPhase
        if let decision = kept.item.decision {
            phase = .answered(decision)
        } else if let deadline = kept.deadline, now >= deadline.addingTimeInterval(-Self.expiryMargin) {
            phase = .expired
        } else {
            phase = .gone
        }
        return NeedsYouReviewSubject(id: id, phase: phase, item: kept.item, detail: kept.detail)
    }
}

/// Whether the review fits beside the list.
enum NeedsYouReviewLayout {
    /// The list's column while a review is beside it: its rows condense to a title and an origin.
    static let listWidth: CGFloat = 372
    /// The least the review takes beside the list: the inspector's own least width.
    static let reviewMinimum: CGFloat = 400
    /// The widest a line of the request runs, so it stays under 80 characters.
    static let measure: CGFloat = 640

    static func fitsAside(width: CGFloat) -> Bool { width >= listWidth + reviewMinimum }

    /// How the review is shown in a canvas of this width: the chosen mode, or the full view when
    /// the two columns don't fit.
    static func shown(_ mode: NeedsYouReviewMode, width: CGFloat) -> NeedsYouReviewMode {
        mode == .aside && fitsAside(width: width) ? .aside : .full
    }
}

/// An `agentcommander://` URL as the one thing it opens. A URL with any other host opens nothing:
/// it is never handed to the join flow.
enum CommanderExternalLink: Equatable, Sendable {
    /// A Needs you request, opened in the main window.
    case needsYou(NeedsYouRequestLink)
    /// A server invite, opened in the network panel's add-server form.
    case invite(URL)

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == MultiplayerInviteLink.scheme else { return nil }
        if let link = NeedsYouRequestLink(url: url) {
            self = .needsYou(link)
        } else if parts.host?.lowercased() == "join" {
            self = .invite(url)
        } else {
            return nil
        }
    }

    /// The first URL of each kind, in the order given. Launch Services may deliver several at once.
    static func first(in urls: [URL]) -> (needsYou: NeedsYouRequestLink?, invite: URL?) {
        var needsYou: NeedsYouRequestLink?, invite: URL?
        for case let link? in urls.map(CommanderExternalLink.init(url:)) {
            switch link {
            case .needsYou(let request): if needsYou == nil { needsYou = request }
            case .invite(let url): if invite == nil { invite = url }
            }
        }
        return (needsYou, invite)
    }
}
