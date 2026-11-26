import SwiftUI

// ATOMIC LEVEL: Values (main-window network pages).
// Everything the full-size network pages show, as plain values, and everything they can ask for.
// A page takes a `NetworkPages` value and never reads a model. The live window fills it from the
// network model (NetworkPagesLive.swift); the design previews fill it with samples
// (NetworkPagesPreview.swift).
//
// The pages are a second view of the network model's own route. Which server, approval, hand-off,
// thread or fan-out is open is read from `route`, so the main window and the tray never disagree
// about what is open. Only two selections have no route and are kept by the window itself: the
// directory entry and the shared resource (`NetworkPagesSelection`).
//
//   NetworkPlace            the place IDs that have a page
//   NetworkPagesContent     the network's state, as values
//   NetworkPagesSelection   the window's own selections
//   NetworkPagesDrafts      the text and choices being edited, as bindings
//   NetworkPagesActions     the intents a page can emit
//   NetworkActionResult     how one network action ended, for the row it was taken on
//   NetworkPageActions      the one boundary every network action crosses, as async closures
//   NetworkRowResults       runs an action for a row and keeps its result while it shows
//   NetworkPages            all four, as a page receives them
//   Network…Row             one row of a page's table, built from the content

enum NetworkPlace {
    static let servers = LiveShell.servers
    static let directory = "network.directory"
    static let approvals = LiveShell.approvals
    static let handoffs = "network.handoffs"
    static let threads = "network.threads"
    static let audit = "network.audit"
    static let fanout = "network.fanout"
    static let shared = "network.shared"
    static let people = LiveShell.people

    static let all = [servers, directory, approvals, handoffs, threads, audit, fanout, shared, people]

    static func hasPage(_ id: String) -> Bool { all.contains(id) }

    /// The line above the page title.
    static func kicker(_ id: String) -> String {
        id == people ? "PEOPLE" : "NETWORK / \(title(id).uppercased())"
    }

    static func title(_ id: String) -> String {
        switch id {
        case servers: "Servers"
        case directory: "Directory"
        case approvals: "Approvals"
        case handoffs: "Hand-offs"
        case threads: "Threads"
        case audit: "Audit"
        case fanout: "Fan-out"
        case shared: "Shared"
        case people: "People"
        default: ""
        }
    }
}

// MARK: - Content

struct NetworkPagesContent {
    /// One saved server and what its session lists while it is online.
    struct Server: Identifiable {
        var summary: MultiplayerServerSummary
        /// The session is online, so the lists below are current.
        var isOnline = false
        var handle = ""
        var displayName = ""
        var statusMessage = ""
        var isAdmin = false
        var membershipMode: String? = nil
        var friends: [MultiplayerFriend] = []
        var friendRequests: [MultiplayerIncoming] = []
        var grants: [MultiplayerGrant] = []
        var resources: [MultiplayerResource] = []
        var directory: [MultiplayerDirectoryEntry] = []
        var approvals: [MultiplayerApproval] = []
        var incomingAccess: [MultiplayerAccessRequest] = []
        var outgoingAccess: [MultiplayerAccessRequest] = []
        var handoffs: [MultiplayerSentRequest] = []
        var reviews: [MultiplayerSentRequest] = []
        var fanouts: [MultiplayerFanout] = []
        var handovers: [MultiplayerHandover] = []
        /// Friends' workers a fan-out can reach here.
        var fanoutTargets: [MultiplayerDirectoryEntry] {
            directory.filter { $0.kind == MultiplayerResourceKind.agent.rawValue && $0.canConsult }
        }

        var id: String { summary.id }
        var name: String { summary.displayName }
    }

    var now = Date()
    /// The network model's route. The open server, approval, hand-off, thread, audit and fan-out are read from it.
    var route = MultiplayerTrayRoute.home
    var servers: [Server] = []
    /// The latest status or result of a hand-off, by request.
    var reports: [String: MultiplayerHandoffReport] = [:]
    /// The fan-out answers marked as winners on this Mac, by `server/request`.
    var winners: [String: String] = [:]
    /// The pull request a review was posted to, by request.
    var posted: [String: String] = [:]
    var confirmingPost = false
    var postProblem: String? = nil
    var thread: MultiplayerLoad<MultiplayerThread> = .loading
    var audit: MultiplayerLoad<[MultiplayerAuditEntry]> = .loading
    /// The fresh certificate check of the open server.
    var probe = MultiplayerProbeState.idle
    var confirmingRemoval: String? = nil
    var confirmingTrust: String? = nil
    var canTrust = false
    var canRename = false
    /// Friends by server, as the tray groups them.
    var people: [MultiplayerFriendGroup] = []
    var friendsAvailable: Int? = nil
    /// The activity feed under its two filters.
    var activity: [MultiplayerActivityEvent] = []
    var hasActivity = false
    var unseen = 0
    var activityActors: [String] = []
    /// Pictures by `server/handle`.
    var avatars: [String: Data] = [:]
    var profileAvatar: Data? = nil
    var canSaveProfile = false
    /// The resource the grant sheet is about.
    var grantResource: MultiplayerShareResource? = nil
    var grantCompanions: [String] = []
    var grantHint = ""
    var canGrant = false
    var canComment = false
    var canSendFanout = false
    /// How the last action on a row ended, by `NetworkActionResult.key`.
    var results: [String: NetworkActionResult] = [:]
    /// Rows whose action is still running.
    var running: Set<String> = []
    /// Why the grant sheet's last Share was refused.
    var grantRefusal: String? = nil
    /// When each friend request arrived, by `server/request`. Empty until the network model says.
    var friendArrivals: [String: Date] = [:]
    /// What the model is doing now, why its last action failed, and what it last confirmed.
    var working: String? = nil
    var failure: String? = nil
    var notice: String? = nil
    /// The helper is missing or the server list can't be read.
    var isUnavailable = false
    var hasLoaded = true

    var isBusy: Bool { working != nil }

    // MARK: Lookups

    func server(_ id: String) -> Server? { servers.first { $0.id == id } }
    func serverName(_ id: String) -> String { server(id)?.name ?? id }

    /// Servers whose session is online.
    var online: [Server] { servers.filter(\.isOnline) }

    /// The server page open in the model: its settings or its certificate review.
    var openServer: Server? {
        if case .server(let id) = route { return server(id) }
        return nil
    }

    /// The share page open in the model, with its server.
    var sharePage: (server: String, page: MultiplayerSharePage)? {
        if case .share(let server, let page) = route { return (server, page) }
        return nil
    }

    /// The server whose profile editor is open.
    var profileServer: Server? {
        if case .profile(let id) = route { return server(id) }
        return nil
    }

    func entry(_ resource: String, on server: String) -> MultiplayerDirectoryEntry? {
        self.server(server)?.directory.first { $0.id == resource }
    }

    /// A resource's name on a server, yours or a friend's; its ID when neither list names it.
    func resourceName(_ id: String, on server: String) -> String {
        guard let found = self.server(server) else { return id.multiplayerDisplay }
        let name = found.resources.first { $0.id == id }?.name ?? found.directory.first { $0.id == id }?.name ?? id
        return name.multiplayerDisplay
    }

    /// Who a request went to: "mira’s mira-claude".
    func target(of row: MultiplayerSentRequest, on server: String) -> String {
        guard let entry = entry(row.resource, on: server) else { return resourceName(row.resource, on: server) }
        return "\(entry.owner.multiplayerDisplay)’s \(entry.name.multiplayerDisplay)"
    }

    /// A hand-off's state in words: the run's, once asked; otherwise the request's own.
    func state(of row: MultiplayerSentRequest) -> (title: String, tone: Tone) {
        if let state = reports[row.request]?.state, !state.isEmpty {
            return (MultiplayerRequestState.title(state), MultiplayerRequestState.tone(state))
        }
        if row.succeeded { return ("Started", .working) }
        return (MultiplayerRequestState.title(row.status), MultiplayerRequestState.tone(row.status))
    }

    func winner(of request: String, on server: String) -> String? {
        winners[MultiplayerWinnerStore.key(request, on: server)]
    }

    func avatar(_ handle: String, on server: String) -> Data? {
        avatars[MultiplayerAvatarKey.make(server: server, handle: handle)]
    }

    // MARK: Rows

    var approvalRows: [NetworkApprovalRow] {
        servers.flatMap { server in
            server.approvals.map { approval -> NetworkApprovalRow in
                let key = NetworkActionResult.key(.approval, approval.id, on: server.id)
                return NetworkApprovalRow(server: server.id, serverName: server.name, approval: approval,
                                          resourceName: resourceName(approval.resource, on: server.id),
                                          waiting: approval.arrived.map { max(0, now.timeIntervalSince($0)) },
                                          expiresIn: approval.expires.map { max(0, $0.timeIntervalSince(now)) },
                                          result: results[key], isRunning: running.contains(key))
            }
        }
        .sorted { ($0.expiresIn ?? .infinity) < ($1.expiresIn ?? .infinity) }
    }

    /// Requests friends sent for your resources, then the ones you sent, newest first in each.
    var accessRows: [NetworkAccessRow] {
        func rows(_ list: KeyPath<Server, [MultiplayerAccessRequest]>, incoming: Bool) -> [NetworkAccessRow] {
            servers.flatMap { server in
                server[keyPath: list].map { request -> NetworkAccessRow in
                    let key = NetworkActionResult.key(.access, request.id, on: server.id)
                    return NetworkAccessRow(server: server.id, serverName: server.name, request: request,
                                            resourceName: resourceName(request.resource, on: server.id), isIncoming: incoming,
                                            waiting: request.createdAt.map { max(0, now.timeIntervalSince($0)) },
                                            result: results[key], isRunning: running.contains(key))
                }
            }
            .sorted { ($0.waiting ?? .infinity) < ($1.waiting ?? .infinity) }
        }
        return rows(\.incomingAccess, incoming: true) + rows(\.outgoingAccess, incoming: false)
    }

    /// Hand-offs and reviews you sent, newest first.
    var workRows: [NetworkWorkRow] {
        servers.flatMap { server -> [NetworkWorkRow] in
            let handoffs = server.handoffs.map { row -> NetworkWorkRow in
                let state = state(of: row)
                return NetworkWorkRow(kind: .handoff, server: server.id, serverName: server.name, request: row.request,
                                      title: row.title.isEmpty ? "Untitled hand-off" : row.title.multiplayerDisplay,
                                      target: target(of: row, on: server.id), state: state.title, tone: state.tone, at: row.at)
            }
            let reviews = server.reviews.map { row -> NetworkWorkRow in
                let review = MultiplayerReview(row.value)
                return NetworkWorkRow(kind: .review, server: server.id, serverName: server.name, request: row.request,
                                      title: row.title.isEmpty ? "Untitled review" : row.title.multiplayerDisplay,
                                      target: target(of: row, on: server.id),
                                      state: row.succeeded ? (review?.tally ?? "Done") : MultiplayerRequestState.title(row.status),
                                      tone: row.succeeded ? ((review?.important ?? 0) > 0 ? .attention : .working)
                                                          : MultiplayerRequestState.tone(row.status),
                                      at: row.at)
            }
            return handoffs + reviews
        }
        .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
    }

    var fanoutRows: [NetworkWorkRow] {
        servers.flatMap { server in
            server.fanouts.map { fanout in
                let picked = winner(of: fanout.request, on: server.id) != nil
                return NetworkWorkRow(kind: .fanout, server: server.id, serverName: server.name, request: fanout.request,
                                      title: fanout.title.isEmpty ? "Untitled fan-out" : fanout.title.multiplayerDisplay,
                                      target: "\(fanout.children.count) workers",
                                      state: picked ? "Winner chosen" : fanout.progress,
                                      tone: picked || fanout.isSettled ? .working : .attention, at: fanout.at)
            }
        }
        .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
    }

    /// Every request you sent that has a thread: hand-offs, reviews and each fan-out answer.
    var threadRows: [NetworkWorkRow] {
        let answers = servers.flatMap { server in
            server.fanouts.flatMap { fanout in
                fanout.children.map { child in
                    let name = entry(child.resource, on: server.id)?.name.multiplayerDisplay ?? child.resource.multiplayerDisplay
                    return NetworkWorkRow(kind: .answer, server: server.id, serverName: server.name, request: child.id,
                                          title: "\(name): \(fanout.title.multiplayerDisplay)", target: name,
                                          state: MultiplayerRequestState.title(child.status),
                                          tone: MultiplayerRequestState.tone(child.status), at: fanout.at)
                }
            }
        }
        return (workRows + answers).sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
    }

    /// What friends offer on every online server: what you can use first, then by owner and name.
    var directoryRows: [NetworkDirectoryRow] {
        servers.flatMap { server in
            server.directory.map { entry in
                NetworkDirectoryRow(server: server.id, serverName: server.name, entry: entry,
                                    isWaiting: server.outgoingAccess.contains { $0.resource == entry.id && $0.isPending })
            }
        }
        .sorted { left, right in
            if left.entry.granted.isEmpty != right.entry.granted.isEmpty { return !left.entry.granted.isEmpty }
            if left.entry.owner != right.entry.owner { return left.entry.owner < right.entry.owner }
            return left.entry.name < right.entry.name
        }
    }

    /// Your resources on every online server, with the grants given on each.
    var sharedRows: [NetworkSharedRow] {
        servers.flatMap { server in
            server.resources.map { resource in
                NetworkSharedRow(server: server.id, serverName: server.name, resource: resource,
                                 grants: server.grants.filter { $0.resource == resource.id },
                                 holders: server.handovers.filter { $0.resource == resource.id })
            }
        }
    }

    /// Friend requests waiting on you, longest wait first where the arrival is known.
    var friendRequests: [NetworkFriendRow] {
        servers.filter { $0.isOnline && $0.summary.state != .certChanged }.flatMap { server in
            server.friendRequests.map { request -> NetworkFriendRow in
                let key = NetworkActionResult.key(.friend, request.handle, on: server.id)
                return NetworkFriendRow(server: server.id, serverName: server.name, request: request,
                                        waiting: friendArrivals["\(server.id)/\(request.id)"].map { max(0, now.timeIntervalSince($0)) },
                                        result: results[key], isRunning: running.contains(key))
            }
        }
        .sorted { ($0.waiting ?? -1) > ($1.waiting ?? -1) }
    }

    // MARK: Telemetry

    /// The readouts under a page's header.
    func readouts(for place: String) -> [ShellReadout] {
        func cell(_ id: String, _ label: String, _ value: Int, tone: Tone = .neutral) -> ShellReadout {
            ShellReadout(id: id, label: label, value: "\(value)", tone: value > 0 ? tone : .neutral)
        }
        switch place {
        case NetworkPlace.servers:
            let answering = servers.filter { $0.summary.state == .online }.count
            let blocked = servers.filter { $0.summary.state == .certChanged }.count
            let health = CommanderServerHealth(online: answering, total: servers.count)
            return [ShellReadout(id: "online", label: "online", value: health.figure, lamp: answering > 0 ? .on : .off,
                                 tone: health.tone == .working ? .neutral : health.tone, spoken: "servers, \(health.spoken)"),
                    cell("signed-in", "signed in", servers.filter(\.summary.signedIn).count),
                    cell("blocked", "blocked", blocked, tone: .failure),
                    cell("requests", "friend requests", servers.reduce(0) { $0 + $1.summary.incoming }, tone: .attention)]
        case NetworkPlace.directory:
            let rows = directoryRows
            return [cell("offered", "offered", rows.count),
                    cell("usable", "you can use", rows.filter { !$0.entry.granted.isEmpty }.count, tone: .working),
                    cell("asked", "asked for", rows.filter(\.isWaiting).count, tone: .attention),
                    cell("servers", "servers", online.count)]
        case NetworkPlace.approvals:
            let approvals = approvalRows
            let access = accessRows
            var cells = [cell("approvals", "approvals", approvals.count, tone: .attention),
                         cell("access", "access requests", access.filter(\.isIncoming).count, tone: .attention),
                         cell("sent", "you asked", access.filter { !$0.isIncoming && $0.request.isPending }.count)]
            if let soonest = approvals.compactMap(\.expiresIn).min() {
                cells.append(ShellReadout(id: "soonest", label: "first lapses in", value: NeedsYouClock.left(soonest),
                                          tone: soonest < NeedsYouInbox.closing ? .attention : .neutral))
            }
            return cells
        case NetworkPlace.handoffs:
            let rows = workRows
            return [cell("handoffs", "hand-offs", rows.filter { $0.kind == .handoff }.count),
                    cell("reviews", "reviews", rows.filter { $0.kind == .review }.count),
                    cell("working", "working", rows.filter { $0.tone == .working && $0.state != "Done" }.count, tone: .working),
                    cell("waiting", "waiting", rows.filter { $0.tone == .attention }.count, tone: .attention),
                    cell("failed", "failed", rows.filter { $0.tone == .failure }.count, tone: .failure)]
        case NetworkPlace.threads:
            return [cell("requests", "requests", threadRows.count),
                    cell("comments", "comments", thread.value?.comments.count ?? 0),
                    cell("agents", "from agents", thread.value?.comments.filter(\.isAgent).count ?? 0)]
        case NetworkPlace.audit:
            let entries = audit.value ?? []
            return [cell("requests", "requests", entries.count),
                    ShellReadout(id: "tokens", label: "tokens", value: entries.reduce(0) { $0 + $1.tokens }.formatted()),
                    cell("refused", "refused", entries.filter { $0.outcomeTone == .failure }.count, tone: .failure),
                    cell("people", "people", Set(entries.map(\.peer)).subtracting([""]).count)]
        case NetworkPlace.fanout:
            let rows = fanoutRows
            return [cell("fanouts", "fan-outs", rows.count),
                    cell("answering", "still answering", rows.filter { $0.tone == .attention }.count, tone: .attention),
                    cell("winners", "winners chosen", rows.filter { $0.state == "Winner chosen" }.count, tone: .working)]
        case NetworkPlace.shared:
            let rows = sharedRows
            return [cell("resources", "your resources", rows.count),
                    cell("grants", "grants", rows.reduce(0) { $0 + $1.grants.count }),
                    cell("people", "people", Set(rows.flatMap { $0.grants.map(\.handle) }).count),
                    cell("held", "control handed over", rows.reduce(0) { $0 + $1.holders.count }, tone: .attention)]
        case NetworkPlace.people:
            let friends = people.reduce(0) { $0 + $1.people.count }
            let available = friendsAvailable ?? people.reduce(0) { $0 + $1.onlineCount }
            return [ShellReadout(id: "online", label: "online", value: "\(available)/\(friends)", lamp: available > 0 ? .on : .off,
                                 spoken: "friends, \(available) of \(friends) online"),
                    cell("requests", "friend requests", friendRequests.count, tone: .attention),
                    cell("unseen", "new in activity", unseen, tone: .focus),
                    cell("servers", "servers", people.filter(\.isOnline).count)]
        default:
            return []
        }
    }

    /// The one-line state summary under a page's title.
    func summary(for place: String) -> String {
        if isUnavailable { return "The network helper isn’t available on this Mac." }
        if servers.isEmpty { return "No server yet. Add one to see your network here." }
        switch place {
        case NetworkPlace.servers:
            let blocked = servers.filter { $0.summary.state == .certChanged }
            if let first = blocked.first {
                return "\(first.name) presented a different certificate and is blocked until you review it."
            }
            return "Every saved server, its health, the key it is pinned to and how it connects."
        case NetworkPlace.directory: return "What friends offer on your servers. Granted actions work now; ask the owner for the rest."
        case NetworkPlace.approvals: return "Uses of your resources that wait for you, and requests for access in both directions."
        case NetworkPlace.handoffs: return "Tasks you handed to friends’ agents and reviews you asked for, newest first."
        case NetworkPlace.threads: return "The comments on each request you sent. You and the agents write in the same thread."
        case NetworkPlace.audit: return "Every use of a shared resource, with who asked, how it ended and what it cost."
        case NetworkPlace.fanout: return "One prompt sent to several workers, with their answers side by side."
        case NetworkPlace.shared: return "What you share, who can use it and for how long."
        case NetworkPlace.people: return "Your friends on each server, who wants to be one, and what has happened lately."
        default: return ""
        }
    }
}

// MARK: - Rows

struct NetworkApprovalRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let approval: MultiplayerApproval
    let resourceName: String
    let waiting: TimeInterval?
    let expiresIn: TimeInterval?
    var result: NetworkActionResult? = nil
    var isRunning = false

    var id: String { "\(server)/\(approval.id)" }
    var who: String { approval.peer.isEmpty ? "A friend" : approval.peer.multiplayerDisplay }
}

struct NetworkAccessRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let request: MultiplayerAccessRequest
    let resourceName: String
    /// A friend asks you; otherwise you asked a friend.
    let isIncoming: Bool
    let waiting: TimeInterval?
    var result: NetworkActionResult? = nil
    var isRunning = false

    var id: String { "\(server)/\(request.id)" }
    /// The other person: who asks you, or whom you asked.
    var who: String { (isIncoming ? request.requester : request.owner).multiplayerDisplay }
}

struct NetworkFriendRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let request: MultiplayerIncoming
    /// How long the request has waited. Nil while the network model doesn't say when it arrived.
    let waiting: TimeInterval?
    var result: NetworkActionResult? = nil
    var isRunning = false

    var id: String { "\(server)/\(request.id)" }
    var who: String { request.handle.isEmpty ? "Someone" : request.handle.multiplayerDisplay }
}

struct NetworkWorkRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case handoff, review, fanout
        /// One worker's answer to a fan-out.
        case answer

        var symbol: String {
            switch self {
            case .handoff: "arrow.up.right"
            case .review: "list.bullet.rectangle"
            case .fanout, .answer: "arrow.triangle.branch"
            }
        }

        var title: String {
            switch self {
            case .handoff: "hand-off"
            case .review: "review"
            case .fanout: "fan-out"
            case .answer: "answer"
            }
        }
    }

    let kind: Kind
    let server: String
    let serverName: String
    let request: String
    let title: String
    let target: String
    let state: String
    let tone: Tone
    let at: Date?

    var id: String { "\(server)/\(request)" }
}

struct NetworkDirectoryRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let entry: MultiplayerDirectoryEntry
    /// You already asked for this and the owner hasn't answered.
    let isWaiting: Bool

    var id: String { "\(server)/\(entry.id)" }

    /// What the row says about your access.
    var access: (title: String, tone: Tone) {
        if !entry.granted.isEmpty { return ("Granted", .working) }
        return isWaiting ? ("Asked", .attention) : ("Offered", .neutral)
    }
}

struct NetworkSharedRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let resource: MultiplayerResource
    let grants: [MultiplayerGrant]
    /// Friends who hold control of this worker now.
    let holders: [MultiplayerHandover]

    var id: String { "\(server)/\(resource.id)" }
    var people: [String] {
        var seen = Set<String>()
        return grants.map(\.handle).filter { seen.insert($0).inserted }
    }

    /// The grant that lapses first.
    var nextExpiry: Date? { grants.compactMap(\.expiresAt).min() }
}

// MARK: - Selection, drafts, actions

/// The selections that have no route in the network model.
struct NetworkPagesSelection: Equatable {
    /// `server/resource` of the directory entry in the inspector.
    var directory: String? = nil
    /// `server/resource` of your resource in the inspector.
    var shared: String? = nil
}

/// What is being edited, as bindings into whoever owns the text.
struct NetworkPagesDrafts {
    var nickname: Binding<String> = .constant("")
    var access: Binding<MultiplayerAccessDraft> = .constant(MultiplayerAccessDraft())
    var grant: Binding<MultiplayerShareDraft> = .constant(MultiplayerShareDraft())
    var comment: Binding<String> = .constant("")
    var fanout: Binding<MultiplayerFanoutDraft> = .constant(MultiplayerFanoutDraft())
    var reviewLink: Binding<String> = .constant("")
    var profile: Binding<MultiplayerProfileDraft> = .constant(MultiplayerProfileDraft())
    var activityServer: Binding<String?> = .constant(nil)
    var activityFriend: Binding<String?> = .constant(nil)
}

/// The intents a page can emit. Each names what the person asked for; the owner of the state
/// decides what happens. A nil action hides or disables its control.
struct NetworkPagesActions {
    /// Go to another place of the window.
    var go: (String) -> Void = { _ in }
    var select: (NetworkPagesSelection) -> Void = { _ in }
    /// Show the network panel as it stands. Nil where there is no helper.
    var openPanel: (() -> Void)? = nil
    var dismissNotice: () -> Void = {}
    var dismissFailure: () -> Void = {}
    var refresh: () -> Void = {}
    /// Leave whatever detail is open: the model returns to its home.
    var close: () -> Void = {}
    /// Leave a form (request access, grant, fan-out composer) for the page it was opened from.
    var back: () -> Void = {}

    // Servers
    var openServer: (String) -> Void = { _ in }
    var addServer: (() -> Void)? = nil
    var signIn: (String) -> Void = { _ in }
    var signOut: (String) -> Void = { _ in }
    var rename: () -> Void = {}
    var setAutoConnect: (MultiplayerServerSummary, Bool) -> Void = { _, _ in }
    var toggleFavorite: (MultiplayerServerSummary) -> Void = { _ in }
    var askRemove: (MultiplayerServerSummary) -> Void = { _ in }
    var cancelRemove: () -> Void = {}
    var confirmRemove: () -> Void = {}
    var checkCertificate: (MultiplayerServerSummary) -> Void = { _ in }
    var askTrust: (MultiplayerServerSummary) -> Void = { _ in }
    var cancelTrust: () -> Void = {}
    var confirmTrust: () -> Void = {}

    // Directory
    var requestAccess: (MultiplayerDirectoryEntry, String) -> Void = { _, _ in }
    var sendAccessRequest: () -> Void = {}
    /// Consult, Hand off, Watch and Request review open their composer in the network panel.
    var consult: ((MultiplayerDirectoryEntry, String) -> Void)? = nil
    var handOff: ((MultiplayerDirectoryEntry, String) -> Void)? = nil
    var watch: ((MultiplayerDirectoryEntry, String) -> Void)? = nil

    // Approvals and access
    var openApproval: (String, String) -> Void = { _, _ in }
    var decide: (MultiplayerApproval, String, Bool) -> Void = { _, _, _ in }
    var reviewAccess: (MultiplayerAccessRequest, String) -> Void = { _, _ in }
    var removeAccess: (MultiplayerAccessRequest, String, _ declining: Bool) -> Void = { _, _, _ in }

    // Grant sheet
    var share: (_ server: String, _ handle: String?, _ resource: String?) -> Void = { _, _, _ in }
    var setGrantServer: (String) -> Void = { _ in }
    var reconcileGrant: () -> Void = {}
    var toggleGrantAction: (String) -> Void = { _ in }
    var confirmGrant: () -> Void = {}

    // Hand-offs and reviews
    var openHandoff: (String, String) -> Void = { _, _ in }
    var check: (MultiplayerSentRequest, String, _ result: Bool) -> Void = { _, _, _ in }
    /// Apply one artifact of a result. Nil leaves Apply to the network panel.
    var apply: ((Int, MultiplayerArtifact, MultiplayerSentRequest, String) -> Void)? = nil
    var openReview: (String, String) -> Void = { _, _ in }
    var askPost: () -> Void = {}
    var cancelPost: () -> Void = {}
    var confirmPost: () -> Void = {}

    // Threads and audit
    var openThread: (_ request: String, _ title: String, _ server: String) -> Void = { _, _, _ in }
    var postComment: () -> Void = {}
    var openAudit: (_ resource: String, _ server: String) -> Void = { _, _ in }
    var reload: () -> Void = {}

    // Fan-out
    var openFanout: (String, String) -> Void = { _, _ in }
    var chooseWinner: (_ child: String, _ request: String, _ server: String) -> Void = { _, _, _ in }
    var startFanout: (String) -> Void = { _ in }
    var toggleFanoutTarget: (String) -> Void = { _ in }
    var sendFanout: () -> Void = {}

    // Shared
    var takeBack: (MultiplayerHandover, String) -> Void = { _, _ in }

    // People
    var acceptFriend: (MultiplayerIncoming, String) -> Void = { _, _ in }
    /// Nil while the network model can't decline a friend request.
    var declineFriend: ((MultiplayerIncoming, String) -> Void)? = nil
    var addFriend: ((String) -> Void)? = nil
    var editProfile: (String) -> Void = { _ in }
    var choosePicture: () -> Void = {}
    var dropPicture: (Data) -> Void = { _ in }
    var removePicture: () -> Void = {}
    var saveProfile: () -> Void = {}
    var invite: ((String) -> Void)? = nil
    var membership: ((String) -> Void)? = nil
    var markActivitySeen: () -> Void = {}
    /// Reads a friend's picture when its row first shows.
    var loadAvatar: (_ handle: String, _ server: String) -> Void = { _, _ in }
}

/// What a network page receives.
struct NetworkPages {
    var content: NetworkPagesContent
    var selection = NetworkPagesSelection()
    var drafts = NetworkPagesDrafts()
    var actions = NetworkPagesActions()
}

// MARK: - The action boundary

/// How one network action ended. It mirrors the network model's `MultiplayerActionResult`, so the
/// live binding can pass that through unchanged once it is on this branch.
enum NetworkActionResult: Equatable, Sendable {
    case done(id: String, server: String, message: String?)
    case failed(id: String, server: String, reason: String)

    /// What an action was taken on. A friend request's ID is the handle.
    enum Subject: String, Sendable { case approval, access, friend, grant }

    var id: String {
        switch self {
        case .done(let id, _, _), .failed(let id, _, _): id
        }
    }

    var server: String {
        switch self {
        case .done(_, let server, _), .failed(_, let server, _): server
        }
    }

    var isDone: Bool {
        if case .done = self { return true }
        return false
    }

    var message: String? {
        if case .done(_, _, let message) = self { return message }
        return nil
    }

    var reason: String? {
        if case .failed(_, _, let reason) = self { return reason }
        return nil
    }

    /// The key a row's result is kept under.
    static func key(_ subject: Subject, _ id: String, on server: String) -> String { "\(subject.rawValue):\(server)/\(id)" }
}

/// The one boundary every network action of these pages crosses. Each closure does the work and
/// says how it ended for that one request. The live window backs it with the network model
/// (NetworkPagesLive.swift); the previews back it with samples. Nothing else in the pages calls
/// a model.
struct NetworkPageActions {
    typealias Result = NetworkActionResult

    var acceptFriend: @MainActor (MultiplayerIncoming, _ server: String) async -> Result
        = { request, server in .failed(id: request.handle, server: server, reason: "Not available.") }
    /// Nil while the network model can't decline a friend request.
    var declineFriend: (@MainActor (MultiplayerIncoming, _ server: String) async -> Result)? = nil
    var decide: @MainActor (MultiplayerApproval, _ server: String, _ approve: Bool) async -> Result
        = { approval, server, _ in .failed(id: approval.id, server: server, reason: "Not available.") }
    var removeAccess: @MainActor (MultiplayerAccessRequest, _ server: String, _ declining: Bool) async -> Result
        = { request, server, _ in .failed(id: request.id, server: server, reason: "Not available.") }
    /// Fills the grant sheet for a friend, a resource, or both. False when the server can't take it.
    var prepareGrant: @MainActor (_ server: String, _ handle: String?, _ resource: String?, _ actions: Set<String>) -> Bool
        = { _, _, _, _ in false }
    var sendGrant: @MainActor (_ server: String) async -> Result
        = { server in .failed(id: "", server: server, reason: "Not available.") }
}

/// Runs one action for a row and keeps how it ended while the row shows it: a success for a
/// moment, a failure until the row is tried again or leaves.
@Observable @MainActor
final class NetworkRowResults {
    private(set) var results: [String: NetworkActionResult] = [:]
    private(set) var running: Set<String> = []
    /// How long a success stays before its row may leave.
    var dwell: Duration = .milliseconds(2400)

    /// Runs `work` unless the row's action is already running. `finished` is called with the result.
    func run(_ key: String, _ work: @escaping @MainActor () async -> NetworkActionResult,
             finished: @escaping @MainActor (NetworkActionResult) -> Void = { _ in }) {
        guard !running.contains(key) else { return }
        running.insert(key)
        results[key] = nil
        Task {
            let result = await work()
            running.remove(key)
            results[key] = result
            finished(result)
            guard result.isDone else { return }
            try? await Task.sleep(for: dwell)
            if results[key] == result { results[key] = nil }
        }
    }

    func clear(_ key: String) { results[key] = nil }
}

extension NetworkPagesActions {
    /// Sends the result-bearing intents through the boundary and keeps each row's result.
    ///   grantServer    the server the open grant sheet is on
    ///   grantFinished  called when Share ends, so the owner can close the sheet or keep it open
    @MainActor mutating func bind(_ network: NetworkPageActions, results: NetworkRowResults,
                                  grantServer: @escaping @MainActor () -> String?,
                                  grantFinished: @escaping @MainActor (NetworkActionResult) -> Void) {
        decide = { approval, server, approve in
            results.run(NetworkActionResult.key(.approval, approval.id, on: server)) { await network.decide(approval, server, approve) }
        }
        removeAccess = { request, server, declining in
            results.run(NetworkActionResult.key(.access, request.id, on: server)) { await network.removeAccess(request, server, declining) }
        }
        acceptFriend = { request, server in
            results.run(NetworkActionResult.key(.friend, request.handle, on: server)) { await network.acceptFriend(request, server) }
        }
        declineFriend = network.declineFriend.map { decline in
            { request, server in
                results.run(NetworkActionResult.key(.friend, request.handle, on: server)) { await decline(request, server) }
            }
        }
        reviewAccess = { request, server in
            _ = network.prepareGrant(server, request.requester, request.resource, Set(request.actions))
        }
        share = { server, handle, resource in _ = network.prepareGrant(server, handle, resource, []) }
        confirmGrant = {
            guard let server = grantServer() else { return }
            results.run(NetworkActionResult.key(.grant, "sheet", on: server), { await network.sendGrant(server) }, finished: grantFinished)
        }
    }
}

// MARK: - Deep links

/// Where a Needs you row leads: the place, and what to open there.
enum NetworkDeepLink: Equatable {
    case approval(id: String, server: String)
    case access(id: String, server: String)
    case friend(server: String)

    var place: String {
        switch self {
        case .approval, .access: NetworkPlace.approvals
        case .friend: NetworkPlace.people
        }
    }

    /// Reads an inbox row's ID (`approval:server/id`, `access:server/id`, `friend:server/id`). A
    /// worker's own request has no network page and gives nil.
    init?(inboxID: String) {
        func split(_ prefix: String) -> (server: String, id: String)? {
            guard inboxID.hasPrefix(prefix) else { return nil }
            let rest = inboxID.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let server = String(rest[..<slash]), id = String(rest[rest.index(after: slash)...])
            return server.isEmpty || id.isEmpty ? nil : (server, id)
        }
        if let found = split("approval:") {
            self = .approval(id: found.id, server: found.server)
        } else if let found = split("access:") {
            self = .access(id: found.id, server: found.server)
        } else if let found = split("friend:") {
            self = .friend(server: found.server)
        } else {
            return nil
        }
    }
}
