import SwiftUI

// ATOMIC LEVEL: Values and the live page pieces (main-window shell, live).
// What the live main window needs from the network model, as plain values, and the two builders
// that turn live state into the shell's values: the navigation and the Needs you inbox. Nothing
// here reads a model except `ShellNetwork.init(model:)`; the cockpit page passes the values on and
// routes every action back to the model that owns it.
//
//   ShellNetwork          the network model's state the shell shows, as values
//   ShellNetworkActions   the network model's intents the shell can ask for
//   ShellContext          both, plus how the toolbar is drawn and the wall's live work (WallLiveWork);
//                         given to CockpitScreen by the live page
//   LiveShell             place IDs, navigation(…), places(…) and inbox(…) built from live state
//   LiveNeedsYouPage      the inbox page, re-read each second while a request counts down

/// The network model's state as the main window shows it.
struct ShellNetwork: Equatable {
    /// A friend request waiting on the person, with the server it came through.
    struct FriendRequest: Equatable, Identifiable {
        let server: String
        let request: MultiplayerIncoming

        var id: String { "\(server)/\(request.id)" }
    }

    var servers: [MultiplayerServerSummary] = []
    /// Every approval and access request the network lists. One just answered stays listed for
    /// the network's hold, and `answers` says how it came out.
    var approvals: [MultiplayerPending<MultiplayerApproval>] = []
    var access: [MultiplayerPending<MultiplayerAccessRequest>] = []
    /// How a listed request was answered, by its inbox ID. A request without one still waits.
    var answers: [String: MultiplayerAnswer] = [:]
    var friendRequests: [FriendRequest] = []
    var workspaces: [MultiplayerPending<MultiplayerWorkspace>] = []
    /// Resource names by `server/resource`, for the requests above.
    var resourceNames: [String: String] = [:]
    /// Everything the person sent that Hand-offs lists: hand-offs and reviews together.
    var sent = 0
    var friendsOnline = 0
    /// The presence the servers show now. Nil while signed out everywhere.
    var presence: MultiplayerPersonPresence?
    var presenceChoice: MultiplayerPresenceChoice?
    /// The person is an admin on at least one server, so Teams lists Admin.
    var isAdmin = false
    /// Why the last network action didn't go through.
    var failure: String?
    /// The network helper is missing or the server list can't be read.
    var isUnavailable = false

    init() {}

    /// Reads the tray's model. Every property read here is observed by the view that calls it.
    @MainActor init(model: MultiplayerModel) {
        servers = model.servers
        // Every listed row, with the network's own word on the answered ones. The network holds an
        // answered row for a moment so its outcome can be read; the window filters nothing out.
        approvals = model.share.pendingApprovals
        access = model.share.pendingAccess
        for pending in approvals {
            if let answer = model.share.answer(for: pending.item, on: pending.server) { answers[LiveShell.id(pending)] = answer }
        }
        for pending in access {
            if let answer = model.share.answer(for: pending.item, on: pending.server) { answers[LiveShell.id(pending)] = answer }
        }
        // The same rule as the tray's friend groups: a server's requests show only while its
        // session is online and its certificate is the pinned one.
        friendRequests = model.servers.flatMap { server -> [FriendRequest] in
            guard server.state != .certChanged, let session = model.session(server.id), session.isOnline else { return [] }
            return (session.status?.incoming ?? []).map { FriendRequest(server: server.id, request: $0) }
        }
        workspaces = model.share.teams.allWorkspaces
        isAdmin = model.servers.contains { model.isAdmin($0.id) }
        for pending in approvals {
            resourceNames["\(pending.server)/\(pending.item.resource)"] = model.share.resourceName(pending.item.resource, on: pending.server)
        }
        for pending in access {
            resourceNames["\(pending.server)/\(pending.item.resource)"] = model.share.resourceName(pending.item.resource, on: pending.server)
        }
        // The same lists, server by server, that the Hand-offs page reads (NetworkPagesContent.init(model:state:)).
        sent = model.servers.reduce(into: NetworkSentTally()) { tally, server in
            tally.handoffs += model.share.handoffs[server.id]?.count ?? 0
            tally.reviews += model.share.live.reviews[server.id]?.count ?? 0
        }.total
        friendsOnline = model.tally.friendsOnline
        presence = model.shownPresence
        presenceChoice = model.effectivePresenceChoice
        failure = model.failure
        isUnavailable = model.unavailable != nil
    }

    /// The requests that still wait: the listed ones without an answer. Every count uses these.
    var waitingApprovals: [MultiplayerPending<MultiplayerApproval>] { approvals.filter { answers[LiveShell.id($0)] == nil } }
    var waitingAccess: [MultiplayerPending<MultiplayerAccessRequest>] { access.filter { answers[LiveShell.id($0)] == nil } }

    var health: CommanderServerHealth {
        CommanderServerHealth(online: servers.filter { $0.state == .online }.count, total: servers.count)
    }

    /// The person as the first signed-in server names them.
    var profile: CommanderProfile {
        let handle = servers.first { $0.signedIn && !$0.handle.isEmpty }?.handle.multiplayerDisplay ?? ""
        return CommanderProfile(name: handle, handle: handle, presence: presence, choice: presenceChoice)
    }

    func serverName(_ id: String) -> String { servers.first { $0.id == id }?.displayName ?? id }

    func resourceName(_ resource: String, on server: String) -> String {
        (resourceNames["\(server)/\(resource)"] ?? resource).multiplayerDisplay
    }
}

/// The network model's intents the shell can ask for. Answers go through `answers`, the same
/// boundary the network pages use, and each comes back for its own request.
struct ShellNetworkActions {
    var setPresence: @MainActor (MultiplayerPresenceChoice) -> Void = { _ in }
    var answers = NetworkPageActions()
    /// Shows the network panel in its own window. Nil where there is no network helper.
    var openNetworkPanel: (@MainActor () -> Void)? = nil
    /// Opens a network request in the model, so its page shows it: an approval's review.
    var openLink: @MainActor (NetworkDeepLink) -> Void = { _ in }
    /// Fills the grant sheet from a friend's access request. False when the server can't take it.
    var reviewAccess: @MainActor (MultiplayerPending<MultiplayerAccessRequest>) -> Bool = { _ in false }
}

/// What the live page hands the cockpit so it draws the redesigned shell.
struct ShellContext {
    var network: ShellNetwork
    var actions = ShellNetworkActions()
    /// `.hosted` in a window: the cockpit fills the native toolbar. `.drawn` for a headless render.
    var chrome = ShellChrome.hosted
    /// A fixed time for a render or a test. Nil reads the clock each second.
    var now: Date? = nil
    /// The page for a network place. `go` takes the window to another place. Nil leaves the
    /// placeholder.
    var networkPage: (@MainActor (_ place: String, _ go: @escaping (String) -> Void) -> AnyView)? = nil
    /// The page for a Teams place: a workspace or a team tool. Nil leaves the placeholder.
    var teamsPage: (@MainActor (_ place: String, _ go: @escaping (String) -> Void) -> AnyView)? = nil
    /// What the network adds to the coordinator wall: remote workers, who holds control of a
    /// worker, and suggestions waiting. Empty leaves the wall as it is without a network.
    var wall = WallLiveWork()
    var wallActions = WallLiveWorkActions()
    /// The services the app can talk to and the choice of one. Nil leaves the Hosts place out.
    var hosts: CommanderHostsContext? = nil
}

enum LiveShell {
    /// The coordinator wall, the run chooser, the new-run form and the empty state.
    static let wall = "runs"
    static let needsYou = "needs-you"
    static let newRun = "new-run"
    static let settings = "settings"
    /// The services the app can talk to: this Mac and the headless hosts.
    static let hosts = "hosts"
    static let people = "network.people"
    static let servers = "network.servers"
    static let approvals = "network.approvals"
    /// Shown in Teams while the person works in no workspace.
    static let workspaces = "teams.workspaces"

    /// The keys held with a mode's number. ⌘1 stays the coordinator's.
    static let modeModifiers: EventModifiers = [.command, .option]

    static func project(_ path: String) -> String { "project:\(path)" }
    static func team(_ pending: MultiplayerPending<MultiplayerWorkspace>) -> String { "team:\(pending.id)" }

    /// The repository path of a project place.
    static func projectPath(of placeID: String) -> String? {
        placeID.hasPrefix("project:") ? String(placeID.dropFirst("project:".count)) : nil
    }

    static func id(_ approval: MultiplayerPending<MultiplayerApproval>) -> String { "approval:\(approval.id)" }
    static func id(_ access: MultiplayerPending<MultiplayerAccessRequest>) -> String { "access:\(access.id)" }
    static func id(_ friend: ShellNetwork.FriendRequest) -> String { "friend:\(friend.id)" }

    // MARK: Navigation

    /// The whole navigation of the live window.
    ///   Agents    Needs you, Runs, New run, Hosts, then one place per project
    ///   Network   Servers, Directory, Approvals, Hand-offs, Threads, Audit, Fan-out, Shared
    ///   People    People
    ///   Teams     one place per workspace, then the team tools: Groups, Hosts, Knowledge, Directory
    ///             and, for an admin, Admin
    ///   Settings  Settings, at the foot of the rail
    /// `place` is where the window is; on the wall the selected row is the open run's project, and
    /// the new-run form selects New run.
    /// `serviceHost` is the headless host in use, shown as the Hosts row's figure; `showsHosts`
    /// lists the Hosts place.
    static func navigation(runs: [RunSummary], openRunPath: String?, composing: Bool, place: String,
                           needsYou: Int, network: ShellNetwork, isOnline: Bool = true,
                           showsHosts: Bool = false, serviceHost: String? = nil) -> CommanderNavigation {
        func row(_ id: String, _ title: String, _ symbol: String, count: Int = 0, figure: String? = nil,
                 hot: Bool = false, noun: String = "waiting") -> CommanderPlace {
            CommanderPlace(id: id, title: title, mark: .symbol(symbol), count: count, figure: figure,
                           isHot: hot && count > 0, isDetail: true, countNoun: noun)
        }
        var seen = Set<String>()
        let projects = runs.filter { seen.insert($0.path).inserted }.map { run in
            CommanderPlace(id: project(run.path), title: run.project,
                           mark: .letter(String(run.project.prefix(1)).uppercased()), canShare: true)
        }
        let teams = network.workspaces.map { pending in
            CommanderPlace(id: team(pending), title: pending.item.name.multiplayerDisplay,
                           mark: .letter(String(pending.item.name.prefix(1)).uppercased()),
                           count: pending.item.claims.count, countNoun: pending.item.claims.count == 1 ? "claim" : "claims")
        }
        let health = network.health
        let networkPlaces = [
            row(servers, "Servers", "server.rack", figure: health.total > 0 ? health.figure : nil),
            row("network.directory", "Directory", "magnifyingglass"),
            row(approvals, "Approvals", "checkmark.shield", count: network.waitingApprovals.count, hot: true),
            row("network.handoffs", "Hand-offs", "arrow.up.right", count: network.sent, noun: "sent"),
            row("network.threads", "Threads", "bubble.left.and.bubble.right"),
            row("network.audit", "Audit", "list.bullet.rectangle"),
            row("network.fanout", "Fan-out", "arrow.triangle.branch"),
            row("network.shared", "Shared", "square.and.arrow.up.on.square")
        ]
        let places = [
            CommanderPlace(id: Self.needsYou, title: "Needs you", mark: .symbol("tray"), count: needsYou, isHot: needsYou > 0),
            CommanderPlace(id: wall, title: "Runs", mark: .symbol("rectangle.split.2x1"), count: runs.count, countNoun: "runs"),
            // A run can't start while the local service is offline, so the row is off like ⌘N.
            CommanderPlace(id: newRun, title: "New run", mark: .symbol("plus"), isDisabled: !isOnline)
        ] + (showsHosts ? [CommanderPlace(id: hosts, title: "Hosts", mark: .symbol("desktopcomputer"),
                                          figure: serviceHost)] : []) + projects + networkPlaces + [
            row(people, "People", "person.2", count: network.friendsOnline, noun: "friends online")
        ] + (teams.isEmpty ? [row(workspaces, "Workspaces", "rectangle.3.group")] : teams) + teamTools(isAdmin: network.isAdmin) + [
            CommanderPlace(id: settings, title: "Settings", mark: .symbol("gearshape"))
        ]

        var agentSections = [CommanderPlaceGroup(id: "workspace", title: "Workspace",
                                                 placeIDs: [Self.needsYou, wall, newRun] + (showsHosts ? [hosts] : []))]
        if !projects.isEmpty {
            agentSections.append(CommanderPlaceGroup(id: "projects", title: "Projects", placeIDs: projects.map(\.id)))
        }
        let modes = [
            CommanderMode(id: "agents", title: "Agents", symbol: "terminal", sections: agentSections),
            CommanderMode(id: "network", title: "Network", symbol: "network", sections: [
                CommanderPlaceGroup(id: "network", title: "Network", placeIDs: networkPlaces.map(\.id))
            ]),
            CommanderMode(id: "people", title: "People", symbol: "person.2", sections: [
                CommanderPlaceGroup(id: "people", title: "People", placeIDs: [people])
            ]),
            CommanderMode(id: "teams", title: "Teams", symbol: "rectangle.3.group",
                          sections: teamsSections(workspaces: teams.isEmpty ? [workspaces] : teams.map(\.id), isAdmin: network.isAdmin)),
            CommanderMode(id: settings, title: "Settings", symbol: "gearshape", sections: [
                CommanderPlaceGroup(id: settings, title: "Settings", placeIDs: [settings])
            ], isTrailing: true)
        ]

        let known = Set(places.map(\.id))
        let selection: String
        if composing {
            selection = newRun
        } else if isTeamsPlace(place), !known.contains(place) {
            // A workspace that is gone, or the empty Teams place once workspaces arrive, stays in Teams.
            selection = teams.first?.id ?? workspaces
        } else if place == wall || !known.contains(place) {
            selection = openRunPath.map(project).flatMap { known.contains($0) ? $0 : nil } ?? wall
        } else {
            selection = place
        }
        return CommanderNavigation(places: places,
                                   inbox: CommanderInbox(placeID: Self.needsYou, absorbs: [approvals]),
                                   groups: [], modes: modes, footer: [], profile: network.profile, selection: selection)
    }

    /// Every place the network gives the navigation, for a request from outside the window
    /// (CommanderWindowRouter.swift). Runs and projects are the cockpit's own and are left out.
    static func places(network: ShellNetwork) -> Set<String> {
        Set(navigation(runs: [], openRunPath: nil, composing: false, place: wall, needsYou: 0, network: network).places.map(\.id))
    }

    /// A place of the Teams mode: a workspace, the row shown while there is none, or a team tool.
    static func isTeamsPlace(_ id: String) -> Bool { TeamsPlace.hasPage(id) }

    /// The team tools as places. Admin is listed only for an admin.
    static func teamTools(isAdmin: Bool) -> [CommanderPlace] {
        TeamsPlace.tools.filter { isAdmin || $0 != TeamsPlace.admin }.map {
            CommanderPlace(id: $0, title: TeamsPlace.title($0), mark: .symbol(TeamsPlace.symbol($0)), isDetail: true)
        }
    }

    /// The Teams mode's context list: the workspaces, then the team tools.
    static func teamsSections(workspaces: [String], isAdmin: Bool) -> [CommanderPlaceGroup] {
        [CommanderPlaceGroup(id: "teams", title: "Workspaces", placeIDs: workspaces),
         CommanderPlaceGroup(id: "team-tools", title: "Team tools", placeIDs: teamTools(isAdmin: isAdmin).map(\.id))]
    }

    /// True while the selected row means the coordinator wall, the new-run form or the empty state.
    static func showsWall(_ selection: String) -> Bool {
        selection == wall || selection == newRun || projectPath(of: selection) != nil
    }

    /// What a place without a page yet says.
    static func note(for placeID: String, network: ShellNetwork) -> String {
        if network.isUnavailable { return "The network helper isn’t available on this Mac, so there is nothing to show here." }
        if network.servers.isEmpty { return "No server yet. Add one in the network panel; this page arrives with the network pages." }
        if placeID.hasPrefix("team:") { return "This workspace’s goal, claims, board and merge queue arrive with the Teams pages. Open it in the network panel until then." }
        switch placeID {
        case workspaces: return "You work in no workspace yet. Workspaces arrive here with the Teams pages."
        case people: return "Your friends, their presence and their agents arrive with the network pages. They are in the network panel until then."
        case servers: return "Server health, certificates and settings arrive with the network pages. They are in the network panel until then."
        case approvals: return "Decide these in Needs you. The full list arrives with the network pages."
        case "network.shared": return "What you share and what friends share with you arrives with the network pages."
        default: return "This page arrives with the network pages. It is in the network panel until then."
        }
    }

    // MARK: Needs you

    /// One inbox from the person's own stopped workers and the network's requests.
    ///   pending   the cockpit's pending requests, oldest first. Each offers Reply alone, because
    ///             the answer is written in the Attention surfaces.
    ///   network   approvals (Deny, Approve), access requests (Decline, Review) and friend
    ///             requests (Decline, Accept).
    ///   decided   requests answered a moment ago. Each replaces its waiting form, so the outcome
    ///             shows even after the source has dropped the request.
    ///   failures  why the last answer to a request didn't go through, by request. The row says so
    ///             and keeps its answers.
    static func inbox(pending: [RequestPresentation], network: ShellNetwork, now: Date,
                      decided: [NeedsYouItem] = [], failures: [String: String] = [:]) -> NeedsYouInbox {
        var items: [NeedsYouItem] = pending.map { request in
            let isApproval = !request.choices.isEmpty && request.awaitingApprovalToolID != nil
            let detail = request.isWorkerDisconnected
                ? "\(request.workerName) is disconnected. It can’t be answered until \(request.host) reconnects."
                : "\(request.runTitle) in \(request.project) is stopped until this is answered."
            return NeedsYouItem(id: request.id, kind: isApproval ? .workerApproval : .workerQuestion,
                                origin: .worker(name: request.workerName, host: request.host),
                                title: firstLine(request.promptWithoutChoiceList), detail: detail,
                                waiting: nil, answers: [.reply])
        }
        items += network.approvals.map { pending in
            let approval = pending.item
            let server = network.serverName(pending.server)
            let name = "\(network.resourceName(approval.resource, on: pending.server)) on \(server)"
            let detail = approval.isSuggestion
                ? (approval.request.isEmpty ? "For \(name)." : "For \(name): \(approval.request)")
                : (approval.request.isEmpty ? "\(name). Grant is set to Ask each time." : "\(name): \(approval.request)")
            // An answered row keeps its place with its outcome, and its countdown stops.
            let answer = network.answers[id(pending)]
            var item = NeedsYouItem(id: id(pending), kind: .networkApproval,
                                    origin: .friend(handle: handle(approval.peer), server: server, serverID: pending.server),
                                    title: approval.headline, detail: detail,
                                    waiting: answer == nil ? approval.arrived.map { max(0, now.timeIntervalSince($0)) } : nil,
                                    expiresIn: answer == nil ? approval.expires.map { max(0, $0.timeIntervalSince(now)) } : nil)
            item.decision = answer.map(decision)
            return item
        }
        items += network.access.map { pending in
            let request = pending.item
            let server = network.serverName(pending.server)
            let answer = network.answers[id(pending)]
            var item = NeedsYouItem(id: id(pending), kind: .accessRequest,
                                    origin: .friend(handle: handle(request.requester), server: server, serverID: pending.server),
                                    title: "\(handle(request.requester)) asks for access",
                                    detail: "\(network.resourceName(request.resource, on: pending.server)) on \(server). \(MultiplayerAccessRequestsPage.detail(request))",
                                    waiting: answer == nil ? request.createdAt.map { max(0, now.timeIntervalSince($0)) } : nil)
            item.decision = answer.map(decision)
            return item
        }
        items += network.friendRequests.map { friend in
            let server = network.serverName(friend.server)
            return NeedsYouItem(id: id(friend), kind: .friendRequest,
                                origin: .friend(handle: handle(friend.request.handle), server: server, serverID: friend.server),
                                title: "\(handle(friend.request.handle)) sent a friend request",
                                detail: "On \(server). Friends can see presence and ask for access.",
                                waiting: friend.request.requestedAt.map { max(0, now.timeIntervalSince($0)) })
        }
        let answered = Dictionary(decided.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = Set(items.map(\.id))
        let shown = items.map { item -> NeedsYouItem in
            if let done = answered[item.id] { return done }
            var item = item
            item.failure = failures[item.id]
            return item
        }
        return NeedsYouInbox(items: shown + decided.filter { !live.contains($0.id) })
    }

    /// The network's word on an answered request, as the inbox's outcome.
    private static func decision(_ answer: MultiplayerAnswer) -> NeedsYouDecision {
        switch answer {
        case .approved: .approved
        case .denied: .denied
        case .declined, .withdrawn: .declined
        }
    }

    private static func handle(_ raw: String) -> String { raw.isEmpty ? "A friend" : raw.multiplayerDisplay }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespaces)
    }
}

/// The live inbox page. While a request counts down, the inbox is built again each second so the
/// time left and the order stay true. With a fixed time it is built once.
struct LiveNeedsYouPage: View {
    let pending: [RequestPresentation]
    let network: ShellNetwork
    let decided: [NeedsYouItem]
    var failures: [String: String] = [:]
    var now: Date? = nil
    let decide: (NeedsYouInbox, String, NeedsYouDecision) -> Void
    let open: (String) -> Void
    let reply: (String) -> Void

    var body: some View {
        if let now {
            page(at: now)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in page(at: context.date) }
        }
    }

    private func page(at date: Date) -> some View {
        let inbox = LiveShell.inbox(pending: pending, network: network, now: date, decided: decided, failures: failures)
        return NeedsYouPage(inbox: inbox, decide: { id, decision in decide(inbox, id, decision) }, open: open,
                            reply: reply, notice: nil)
    }
}
