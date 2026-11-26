import SwiftUI

// ATOMIC LEVEL: Values (main-window network pages).
// Everything the full-size network pages show, as plain values, and everything they can ask for.
// A page takes a `NetworkPages` value and never reads a model. The live window fills it from the
// network model (NetworkPagesLive.swift); the design previews fill it with samples
// (NetworkPagesPreview.swift).
//
// The pages are a second view of the network model's own route. Which server, approval, hand-off,
// thread or fan-out is open is read from `route`, so the main window and the tray never disagree
// about what is open. Three selections have no route and are kept by the window itself: the
// directory entry, the shared resource, and the server the grant sheet is open on
// (`NetworkPagesSelection`). The grant sheet never moves the tray.
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
    /// How an approval or access request just answered came out, by its row's result key, while
    /// the network still lists it.
    var answered: [String: MultiplayerAnswer] = [:]
    /// The threads the person takes part in, by server, as the network listed them. Nil until
    /// they are read; the list is then built from the requests the model already holds.
    var threads: [String: [MultiplayerThreadSummary]]? = nil
    var results: [String: NetworkActionResult] = [:]
    /// Rows whose action is still running.
    var running: Set<String> = []
    /// Why the grant sheet's last Share was refused.
    var grantRefusal: String? = nil
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
                // An answered row no longer waits: its clock stops and it sorts after the ones that do.
                let answer = answered[key]
                return NetworkApprovalRow(server: server.id, serverName: server.name, approval: approval,
                                          resourceName: resourceName(approval.resource, on: server.id),
                                          waiting: answer == nil ? approval.arrived.map { max(0, now.timeIntervalSince($0)) } : nil,
                                          expiresIn: answer == nil ? approval.expires.map { max(0, $0.timeIntervalSince(now)) } : nil,
                                          result: results[key], isRunning: running.contains(key), answer: answer)
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
                                            result: results[key], isRunning: running.contains(key), answer: answered[key])
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
        if let threads { return Self.rows(threads: threads, in: self) }
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

    /// The network's own list of threads as rows: sent and received, consults included, newest first.
    static func rows(threads: [String: [MultiplayerThreadSummary]], in content: NetworkPagesContent) -> [NetworkWorkRow] {
        content.servers.flatMap { server -> [NetworkWorkRow] in
            (threads[server.id] ?? []).flatMap { summary -> [NetworkWorkRow] in
                let name = content.resourceName(summary.resource, on: server.id).multiplayerDisplay
                let received = summary.direction == .received
                let who = (summary.handle.isEmpty ? summary.peer : summary.handle).multiplayerDisplay
                let kind: NetworkWorkRow.Kind = received ? .received
                    : summary.action == MultiplayerSharePolicy.handoff ? .handoff
                    : summary.action == MultiplayerSharePolicy.review ? .review
                    : summary.action.hasPrefix(MultiplayerSharePolicy.fanoutPrefix) ? .fanout : .consult
                let title = summary.title.isEmpty ? "Untitled \(kind.title)" : summary.title.multiplayerDisplay
                let comments = summary.comments.map { MultiplayerPlural.count($0, "comment") } ?? ""
                func row(_ request: String, _ title: String, _ target: String, _ kind: NetworkWorkRow.Kind) -> NetworkWorkRow {
                    NetworkWorkRow(kind: kind, server: server.id, serverName: server.name, request: request, title: title,
                                   target: target, state: comments, tone: .neutral, at: summary.lastCommentAt ?? summary.at)
                }
                // A fan-out's thread is one per worker it went to.
                if !summary.children.isEmpty {
                    return summary.children.map { child in
                        let worker = content.resourceName(child.resource, on: server.id).multiplayerDisplay
                        return row(child.request, "\(worker): \(title)", worker, .answer)
                    }
                }
                return [row(summary.request, title, received && !who.isEmpty ? "\(who), to \(name)" : name, kind)]
            }
        }
        .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
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
                let key = NetworkActionResult.key(.friend, request.id, on: server.id)
                return NetworkFriendRow(server: server.id, serverName: server.name, request: request,
                                        waiting: request.requestedAt.map { max(0, now.timeIntervalSince($0)) },
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
            // An answered row still shows its outcome, but it no longer waits and isn't counted.
            var cells = [cell("approvals", "approvals", approvals.filter { $0.answer == nil }.count, tone: .attention),
                         cell("access", "access requests", access.filter { $0.isIncoming && $0.answer == nil }.count, tone: .attention),
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
            // The comments the rows count, so the strip and the rows agree; then the open thread's own.
            let listed = threads?.values.reduce(0) { $0 + $1.reduce(0) { $0 + ($1.comments ?? 0) } }
            return [cell("requests", "requests", threadRows.count),
                    cell("comments", "comments", listed ?? thread.value?.comments.count ?? 0),
                    cell("open", "in the open thread", thread.value?.comments.count ?? 0),
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
        case NetworkPlace.threads: return "The comments on each request you sent or were sent. You and the agents write in the same thread."
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
    /// How it came out, while the network still lists the answered row.
    var answer: MultiplayerAnswer? = nil

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
    /// How it came out, while the network still lists the answered row.
    var answer: MultiplayerAnswer? = nil

    var id: String { "\(server)/\(request.id)" }
    /// The other person: who asks you, or whom you asked.
    var who: String { (isIncoming ? request.requester : request.owner).multiplayerDisplay }
}

struct NetworkFriendRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let request: MultiplayerIncoming
    /// How long the request has waited. Nil when the relay gave no time.
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
        /// A prompt you sent to a friend's worker, or a suggestion.
        case consult
        /// A request a friend sent to a resource of yours.
        case received

        var symbol: String {
            switch self {
            case .handoff: "arrow.up.right"
            case .review: "list.bullet.rectangle"
            case .fanout, .answer: "arrow.triangle.branch"
            case .consult: "bubble.left"
            case .received: "arrow.down.left"
            }
        }

        var title: String {
            switch self {
            case .handoff: "hand-off"
            case .review: "review"
            case .fanout: "fan-out"
            case .answer: "answer"
            case .consult: "consult"
            case .received: "request to you"
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
    /// The server the grant sheet is open on. Nil while it is closed.
    var grant: String? = nil
    /// The artifact waiting for its confirmation, with the checkout chosen for it.
    var apply: NetworkApplyDraft? = nil
    /// The access request in the inspector, as its row's ID.
    var access: String? = nil
    /// The friend request in the inspector, as its row's ID.
    var friend: String? = nil
    /// The composer open on the page. Nil while none is.
    var composer: NetworkComposer? = nil
    /// The grant waiting for its second press before it is revoked, as `server/grant`.
    var revoking: String? = nil
}

/// A composer the network model hosts for a view outside the tray, with what it is for.
enum NetworkComposer: Hashable {
    case consult(server: String, resource: String)
    case handoff(server: String, resource: String)
    case reviewRequest(server: String, resource: String)
    case watch(server: String, resource: String)
    case addFriend(server: String)
    case invite(server: String)
    case membership(server: String)
    case addServer

    var title: String {
        switch self {
        case .consult: "Consult"
        case .handoff: "Hand off"
        case .reviewRequest: "Request review"
        case .watch: "Watch"
        case .addFriend: "Add friend"
        case .invite: "Invite someone"
        case .membership: "Membership"
        case .addServer: "Add server"
        }
    }

    /// The server it is on. Adding a server has none yet.
    var server: String? {
        switch self {
        case .consult(let server, _), .handoff(let server, _), .reviewRequest(let server, _), .watch(let server, _),
             .addFriend(let server), .invite(let server), .membership(let server): server
        case .addServer: nil
        }
    }
}

/// One artifact of a hand-off's result and the checkout the person chose for it. Nothing is
/// written until they confirm.
struct NetworkApplyDraft: Equatable {
    let server: String
    /// The hand-off's request.
    let request: String
    let index: Int
    let name: String
    let kind: String
    /// The checkout's full path.
    let checkout: String

    /// The checkout's folder name, as the confirmation and the result name it.
    var folder: String { Self.folder(of: checkout) }
    var isPatch: Bool { kind == "patch" }

    static func folder(of checkout: String) -> String {
        let name = URL(fileURLWithPath: checkout).lastPathComponent
        return name.isEmpty || name == "/" ? checkout : name
    }

    /// The path with the home folder as "~", for one line of mono.
    var shownPath: String {
        let home = NSHomeDirectory()
        return checkout == home || checkout.hasPrefix(home + "/") ? "~" + checkout.dropFirst(home.count) : checkout
    }

    var question: String { isPatch ? "Apply \(name) to \(folder)?" : "Save \(name) into \(folder)?" }

    /// What confirming does, and what it never does.
    var consequence: String {
        isPatch
            ? "Runs git apply in this checkout and stages the changes. Nothing is committed. If the patch doesn’t fit, nothing changes."
            : "Saves it as a new file in this folder. If a file with that name is already there, it is saved under a new name. Nothing is overwritten."
    }

    var confirmTitle: String { isPatch ? "Apply to \(folder)" : "Save into \(folder)" }

    /// The key an artifact's result is kept under: one per artifact of a hand-off.
    static func key(request: String, index: Int, on server: String) -> String {
        NetworkActionResult.key(.artifact, "\(request)#\(index)", on: server)
    }

    var key: String { Self.key(request: request, index: index, on: server) }
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
    /// Consult, Hand off, Watch and Request review open their composer on the page.
    var consult: ((MultiplayerDirectoryEntry, String) -> Void)? = nil
    var handOff: ((MultiplayerDirectoryEntry, String) -> Void)? = nil
    var watch: ((MultiplayerDirectoryEntry, String) -> Void)? = nil
    var requestReview: ((MultiplayerDirectoryEntry, String) -> Void)? = nil
    /// Puts the open composer away.
    var closeComposer: () -> Void = {}

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
    var closeGrant: () -> Void = {}

    // Hand-offs and reviews
    var openHandoff: (String, String) -> Void = { _, _ in }
    var check: (MultiplayerSentRequest, String, _ result: Bool) -> Void = { _, _, _ in }
    /// Apply one artifact of a result. Nil leaves Apply to the network panel.
    var apply: ((Int, MultiplayerArtifact, MultiplayerSentRequest, String) -> Void)? = nil
    /// Applies the artifact waiting in `selection.apply` to its checkout, or puts it away.
    var confirmApply: () -> Void = {}
    var cancelApply: () -> Void = {}
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
    /// Ends one grant. The page asks for a second press first. Nil where a grant can't be revoked.
    var revoke: ((MultiplayerGrant, String) -> Void)? = nil

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
    /// The network model's own grant sheet for a server, with its footer. Nil draws the sheet from
    /// the values above (the previews).
    var grantHost: ((_ server: String) -> AnyView)? = nil
    /// The network model's own host for a composer. Nil where composers aren't offered.
    var composerHost: ((NetworkComposer) -> AnyView)? = nil
}

// MARK: - The action boundary

/// How one network action ended. It mirrors the network model's `MultiplayerActionResult`, so the
/// live binding can pass that through unchanged once it is on this branch.
enum NetworkActionResult: Equatable, Sendable {
    case done(id: String, server: String, message: String?)
    case failed(id: String, server: String, reason: String)

    /// What an action was taken on.
    enum Subject: String, Sendable { case approval, access, friend, grant, artifact }

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
        = { request, server in .failed(id: request.id, server: server, reason: "Not available.") }
    /// Nil where a friend request can't be declined.
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
    /// Asks which checkout an artifact goes to. Nil when the person chose none.
    var chooseCheckout: (@MainActor (_ artifact: String) -> String?)? = nil
    /// Applies or saves one artifact of a hand-off's result into a checkout. Nil leaves Apply to
    /// the network panel.
    var applyArtifact: (@MainActor (NetworkApplyDraft, MultiplayerSentRequest) async -> Result)? = nil
}

/// Runs one action for a row and keeps how it ended while the row shows it: a success for a
/// moment, a failure until the row is tried again or leaves.
@Observable @MainActor
final class NetworkRowResults {
    private(set) var results: [String: NetworkActionResult] = [:]
    private(set) var running: Set<String> = []
    /// How long a success stays before its row may leave.
    /// As long as the network holds an answered row, so the window adds no time of its own.
    var dwell: Duration = MultiplayerShareModel.answeredHold

    /// Runs `work` unless the row's action is already running. `finished` is called with the result.
    /// `keeps` leaves a success in place: an artifact's result stays beside it.
    func run(_ key: String, keeps: Bool = false, _ work: @escaping @MainActor () async -> NetworkActionResult,
             finished: @escaping @MainActor (NetworkActionResult) -> Void = { _ in }) {
        guard !running.contains(key) else { return }
        running.insert(key)
        results[key] = nil
        Task {
            let result = await work()
            running.remove(key)
            results[key] = result
            finished(result)
            guard result.isDone, !keeps else { return }
            try? await Task.sleep(for: dwell)
            if results[key] == result { results[key] = nil }
        }
    }

    func clear(_ key: String) { results[key] = nil }
}

extension NetworkPagesActions {
    /// Sends the result-bearing intents through the boundary and keeps each row's result.
    ///   openGrant      shows the grant sheet on a server, once its draft is filled
    ///   grantServer    the server the open grant sheet is on
    ///   grantFinished  called when Share ends, so the owner can close the sheet or keep it open
    @MainActor mutating func bind(_ network: NetworkPageActions, results: NetworkRowResults,
                                  openGrant: @escaping @MainActor (String) -> Void,
                                  grantServer: @escaping @MainActor () -> String?,
                                  grantFinished: @escaping @MainActor (NetworkActionResult) -> Void) {
        decide = { approval, server, approve in
            results.run(NetworkActionResult.key(.approval, approval.id, on: server)) { await network.decide(approval, server, approve) }
        }
        removeAccess = { request, server, declining in
            results.run(NetworkActionResult.key(.access, request.id, on: server)) { await network.removeAccess(request, server, declining) }
        }
        acceptFriend = { request, server in
            results.run(NetworkActionResult.key(.friend, request.id, on: server)) { await network.acceptFriend(request, server) }
        }
        declineFriend = network.declineFriend.map { decline in
            { request, server in
                results.run(NetworkActionResult.key(.friend, request.id, on: server)) { await decline(request, server) }
            }
        }
        reviewAccess = { request, server in
            if network.prepareGrant(server, request.requester, request.resource, Set(request.actions)) { openGrant(server) }
        }
        share = { server, handle, resource in if network.prepareGrant(server, handle, resource, []) { openGrant(server) } }
        confirmGrant = {
            guard let server = grantServer() else { return }
            results.run(NetworkActionResult.key(.grant, "sheet", on: server), { await network.sendGrant(server) }, finished: grantFinished)
        }
    }
}

extension NetworkPagesActions {
    /// Apply in three steps, each a value the page can show: choose the checkout, confirm, result.
    /// Choosing a checkout only fills `selection.apply`; nothing is written until `confirmApply`.
    ///   draft     the artifact waiting for its confirmation
    ///   setDraft  shows or puts away the confirmation
    ///   row       the hand-off a draft belongs to, as the network holds it now
    @MainActor mutating func bindApply(_ network: NetworkPageActions, results: NetworkRowResults,
                                       draft: @escaping @MainActor () -> NetworkApplyDraft?,
                                       setDraft: @escaping @MainActor (NetworkApplyDraft?) -> Void,
                                       row: @escaping @MainActor (NetworkApplyDraft) -> MultiplayerSentRequest?) {
        guard let choose = network.chooseCheckout, let send = network.applyArtifact else { return }
        apply = { index, artifact, sent, server in
            guard let checkout = choose(artifact.name.multiplayerDisplay), checkout.hasPrefix("/") else { return }
            let next = NetworkApplyDraft(server: server, request: sent.request, index: index,
                                         name: artifact.name.multiplayerDisplay, kind: artifact.kind, checkout: checkout)
            results.clear(next.key)
            setDraft(next)
        }
        cancelApply = { setDraft(nil) }
        confirmApply = {
            guard let waiting = draft() else { return }
            setDraft(nil)
            guard let sent = row(waiting) else {
                results.run(waiting.key, keeps: true) {
                    .failed(id: waiting.request, server: waiting.server, reason: "Commander can’t find this hand-off any more.")
                }
                return
            }
            results.run(waiting.key, keeps: true) { await send(waiting, sent) }
        }
    }
}

/// What a row's clock says aloud, so a label holds what the screen shows.
enum NetworkSpoken {
    /// "4 minutes 12 seconds left", "waiting 2 minutes", or nothing when the source gives no time.
    static func clock(waiting: TimeInterval?, expiresIn: TimeInterval?) -> String? {
        if let expiresIn { return "\(duration(expiresIn)) left" }
        if let waiting { return "waiting \(duration(waiting))" }
        return nil
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        func unit(_ count: Int, _ noun: String) -> String { MultiplayerPlural.count(count, noun) }
        if hours > 0 { return minutes > 0 ? "\(unit(hours, "hour")) \(unit(minutes, "minute"))" : unit(hours, "hour") }
        if minutes > 0 { return rest > 0 && minutes < 10 ? "\(unit(minutes, "minute")) \(unit(rest, "second"))" : unit(minutes, "minute") }
        return unit(rest, "second")
    }

    /// A sentence joined to what follows it: nothing when there is no time to say.
    static func suffix(_ text: String?) -> String { text.map { ", \($0)" } ?? "" }
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
