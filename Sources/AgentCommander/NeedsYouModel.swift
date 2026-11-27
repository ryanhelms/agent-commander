import Foundation

// ATOMIC LEVEL: Values (Needs you inbox).
// One inbox for everything that waits on the person: questions and approvals from their own
// workers, and approvals, access requests and friend requests from the network. The values here
// say where each request came from, what can be done with it and which comes first.

/// Something that waits on the person.
struct NeedsYouItem: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case workerQuestion, workerApproval, networkApproval, accessRequest, friendRequest
        /// A harness on this Mac that was signed in and no longer is.
        case harnessSignIn

        /// The word on the row's kind tag.
        var tag: String {
            switch self {
            case .workerQuestion: "question"
            case .workerApproval, .networkApproval: "approval"
            case .accessRequest: "access"
            case .friendRequest: "friend"
            case .harnessSignIn: "sign-in"
            }
        }

        var isLocal: Bool { self == .workerQuestion || self == .workerApproval }
        /// This Mac's own: neither a worker's request nor the network's.
        var isDevice: Bool { self == .harnessSignIn }
    }

    /// Where the request came from.
    enum Origin: Equatable, Sendable {
        /// One of the person's own workers, on a host of theirs.
        case worker(name: String, host: String)
        /// A friend, through a server.
        case friend(handle: String, server: String, serverID: String)

        /// The first line of the origin cell.
        var name: String {
            switch self {
            case .worker(let name, _): name
            case .friend(let handle, _, _): handle
            }
        }

        /// The second line of the origin cell: the host or the server.
        var place: String {
            switch self {
            case .worker(_, let host): host
            case .friend(_, let server, _): server
            }
        }
    }

    let id: String
    var kind: Kind
    var origin: Origin
    var title: String
    var detail: String
    /// Seconds the request has waited. Nil when the source doesn't say when it arrived.
    var waiting: TimeInterval?
    /// Seconds until the request lapses. Nil when it has no end.
    var expiresIn: TimeInterval? = nil
    /// Nil while the request waits.
    var decision: NeedsYouDecision? = nil
    /// Why the last answer didn't go through. The row says so in place of its detail.
    var failure: String? = nil
    /// The answers this request can take here, when they are fewer than its kind's. A live
    /// worker request offers Reply alone; a friend request offers Accept alone.
    var answers: [NeedsYouVerb]? = nil

    var isPending: Bool { decision == nil }

    /// What the row offers, the one primary answer last.
    var verbs: [NeedsYouVerb] {
        if let answers { return answers }
        switch kind {
        case .workerQuestion: return [.reply]
        case .workerApproval, .networkApproval: return [.deny, .approve]
        case .accessRequest: return [.decline, .review]
        case .friendRequest: return [.decline, .accept]
        case .harnessSignIn: return [.signIn]
        }
    }
}

/// An answer a row can offer.
enum NeedsYouVerb: String, Sendable {
    case approve, deny, decline, review, accept, reply
    /// Opens the harness's own sign-in. Like Reply, it decides nothing by itself.
    case signIn

    var title: String { self == .signIn ? "Sign in" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The row's one primary answer.
    var isPrimary: Bool { self == .approve || self == .review || self == .accept || self == .reply || self == .signIn }

    /// The decision the verb makes at once. Reply first needs the text.
    var decision: NeedsYouDecision? {
        switch self {
        case .approve: .approved
        case .deny: .denied
        case .decline: .declined
        case .review: .inReview
        case .accept: .accepted
        case .reply, .signIn: nil
        }
    }
}

/// What the person decided.
enum NeedsYouDecision: Equatable, Sendable {
    case approved, denied, declined, accepted
    /// The full review is open; the request is no longer waiting in the inbox.
    case inReview
    case replied(String)

    /// The word in the outcome well.
    var title: String {
        switch self {
        case .approved: "Approved"
        case .denied: "Denied"
        case .declined: "Declined"
        case .accepted: "Accepted"
        case .inReview: "In review"
        case .replied: "Replied"
        }
    }

    var tone: Tone {
        switch self {
        case .approved, .accepted, .replied: .working
        case .denied: .failure
        case .declined: .neutral
        case .inReview: .focus
        }
    }
}

/// How a duration reads in a row: "42s", "3m", "1h 05m".
enum NeedsYouClock {
    static func age(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h " + String(format: "%02dm", (total % 3600) / 60)
    }

    /// Time left as minutes and seconds, "4:12", or with hours from an hour up, "1:11:00".
    static func left(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return "\(total / 3600):" + String(format: "%02d:%02d", (total % 3600) / 60, total % 60) }
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// The lengths a request is offered for. When a request doesn't say how long it was given,
    /// its line drains over the shortest of these that holds what is left.
    static let spans: [TimeInterval] = [300, 900, 3_600, 28_800, 86_400]

    /// How full a countdown's line is: what is left of the whole span.
    static func fraction(left: TimeInterval, waited: TimeInterval?) -> Double {
        let span = waited.map { $0 + left } ?? spans.first { $0 >= left } ?? left
        return span > 0 ? min(max(left / span, 0), 1) : 0
    }
}

struct NeedsYouInbox: Equatable, Sendable {
    /// A request this close to lapsing goes first whatever its kind. It is the point where a
    /// countdown turns to the attention role.
    static let closing: TimeInterval = 300

    var items: [NeedsYouItem]

    var pending: [NeedsYouItem] { items.filter(\.isPending) }
    var pendingCount: Int { pending.count }
    var localCount: Int { pending.filter(\.kind.isLocal).count }
    var deviceCount: Int { pending.filter(\.kind.isDevice).count }
    var networkCount: Int { pendingCount - localCount - deviceCount }

    func pendingCount(of kind: NeedsYouItem.Kind) -> Int { pending.filter { $0.kind == kind }.count }

    /// The soonest end among the waiting requests.
    var soonestEnd: TimeInterval? { pending.compactMap(\.expiresIn).min() }

    /// "2 from your workers, 4 from the network", naming only the sides that have something.
    var summary: String? {
        var parts: [String] = []
        if localCount > 0 { parts.append("\(localCount) from your workers") }
        if networkCount > 0 { parts.append("\(networkCount) from the network") }
        if deviceCount > 0 { parts.append(deviceCount == 1 ? "1 sign-in" : "\(deviceCount) sign-ins") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Where a request stands in the order of urgency. Lower comes first.
    ///   0  about to lapse (under five minutes left)
    ///   1  your own worker is stopped on an approval or a question
    ///   2  a friend's agent waits on an approval
    ///   3  someone asks for access
    ///   4  a friend request
    static func rank(_ item: NeedsYouItem) -> Int {
        if let left = item.expiresIn, left < closing { return 0 }
        switch item.kind {
        case .workerApproval, .workerQuestion, .harnessSignIn: return 1
        case .networkApproval: return 2
        case .accessRequest: return 3
        case .friendRequest: return 4
        }
    }

    /// The inbox in the order of urgency. Within a rank, the request that lapses soonest comes
    /// first, then the one that has waited longest. A decided request keeps the place it had.
    var ordered: [NeedsYouItem] {
        items.enumerated().sorted { left, right in
            let (a, b) = (left.element, right.element)
            let (rankA, rankB) = (Self.rank(a), Self.rank(b))
            if rankA != rankB { return rankA < rankB }
            let (endA, endB) = (a.expiresIn ?? .infinity, b.expiresIn ?? .infinity)
            if endA != endB { return endA < endB }
            let (waitA, waitB) = (a.waiting ?? 0, b.waiting ?? 0)
            if waitA != waitB { return waitA > waitB }
            return left.offset < right.offset
        }
        .map(\.element)
    }

    /// Records a decision. The first decision stands; an unknown or decided request changes nothing.
    @discardableResult mutating func decide(_ id: String, _ decision: NeedsYouDecision) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isPending else { return false }
        if case .replied(let text) = decision, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        items[index].decision = decision
        return true
    }

    /// Takes a decided request out of the list once its outcome has been shown.
    mutating func clear(_ id: String) {
        items.removeAll { $0.id == id && !$0.isPending }
    }

    /// Takes a request out because it was answered somewhere else.
    mutating func withdraw(_ id: String) {
        items.removeAll { $0.id == id && $0.isPending }
    }
}
