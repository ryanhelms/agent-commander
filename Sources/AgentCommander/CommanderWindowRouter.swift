import SwiftUI

// ATOMIC LEVEL: Values and the window's entry point (main-window shell, live).
// How anything outside the main window opens one of its pages. The network tray depends on the
// request value and on `CommanderWindowRouter.shared.open(_:)` only, never on the window's models
// or templates. The router is a Command (design/PATTERN-DECISIONS.md, "Opening a window page").
//
//   CommanderOpenRequest       a place, and optionally a server and an item on that place
//   CommanderOpenCatalog       what exists now, so an unknown item falls back to its place
//   CommanderOpenDestination   the place and item a request comes to, once checked
//   CommanderWindowRouter      brings the cockpit forward, reopening it when closed, and hands the
//                              request to the live window; it carries a run or project link
//                              (`CommanderLink`, Projects.swift) the same way
//   CommanderOpenRequest.init(page:server:)   the tray's moved pages as requests
//   CommanderOpenRequest.landingCrumbs        the breadcrumb to where a request lands, for a link's label

/// A page of the main window to open, by the same place IDs the navigation uses.
struct CommanderOpenRequest: Equatable, Sendable {
    /// What to open on the place. Each names its target by the network's own ID.
    enum Item: Equatable, Sendable {
        case approval(String)
        case handoff(request: String)
        case thread(request: String, title: String)
        /// One resource's audit entries, or every resource's when empty.
        case audit(resource: String)
        /// A fan-out's answers, side by side.
        case fanout(request: String)
        case group(String)
        /// A workspace, on one of its bands, with a card open. Board when no band is named.
        case workspace(String, band: TeamsBand? = nil, card: String? = nil)
        case host(resource: String)
        case knowledge(String)
        case reputation(resource: String)
        /// A server's own settings on a page that has one per server: Admin's policy.
        case server
        /// A friend's worker that runs one of your hand-offs, by its resource: the wall zooms to its tile.
        case remoteWorker(resource: String)
        /// A review you sent, opened the way the wall's own review row opens it.
        case review(request: String)
    }

    var place: String
    /// The server the item is on. An item without one can't be found, so its place opens alone.
    var server: String? = nil
    var item: Item? = nil

    init(place: String, server: String? = nil, item: Item? = nil) {
        self.place = place
        self.server = server
        self.item = item
    }
}

/// What exists now. The live window answers from the network model; a test answers from a list.
struct CommanderOpenCatalog {
    /// The places the navigation lists.
    var places: Set<String>
    /// True when the item is on the server.
    var has: @MainActor (_ item: CommanderOpenRequest.Item, _ server: String) -> Bool

    init(places: Set<String>, has: @escaping @MainActor (CommanderOpenRequest.Item, String) -> Bool = { _, _ in true }) {
        self.places = places
        self.has = has
    }
}

/// Where a request comes to: a place the navigation lists, and the item when it exists.
struct CommanderOpenDestination: Equatable {
    var place: String
    var server: String? = nil
    var item: CommanderOpenRequest.Item? = nil
}

extension CommanderOpenRequest {
    /// The place and item this request opens, given what exists. An item that is unknown, or has
    /// no server, is dropped and its place opens alone. A workspace is its own place, so an unknown
    /// one opens Teams where the workspaces are listed. A review opens on the page the wall's
    /// review row goes to, so an unknown one opens the wall, and so does an unknown remote worker.
    @MainActor func destination(in catalog: CommanderOpenCatalog) -> CommanderOpenDestination {
        guard let item, let server, catalog.has(item, server) else { return CommanderOpenDestination(place: place) }
        return destination(of: item, on: server, places: catalog.places)
    }

    /// The one mapping from an item that exists to its place. `destination(in:)` opens it and
    /// `landingCrumbs` names it, so the two can't differ.
    private func destination(of item: Item, on server: String, places: Set<String>) -> CommanderOpenDestination {
        if case .review = item {
            let own = WallLiveWork.place(for: .review)
            guard places.contains(own) else { return CommanderOpenDestination(place: place) }
            return CommanderOpenDestination(place: own, server: server, item: item)
        }
        if case .workspace(let id, _, _) = item {
            let own = TeamsPlace.workspace(id, on: server)
            guard places.contains(own) else { return CommanderOpenDestination(place: place) }
            return CommanderOpenDestination(place: own, server: server, item: item)
        }
        return CommanderOpenDestination(place: place, server: server, item: item)
    }
}

// MARK: - Where a request lands, in words

extension CommanderOpenRequest {
    /// The window's breadcrumb to the place this request opens when its item exists: ["Network",
    /// "Hand-offs"] for a review, ["Agents", "Workspace", "Runs"] for Watch and Control,
    /// ["Teams", "Team tools", "Hosts"] for a host. A link outside the window labels itself with
    /// these, so its words are where the router lands.
    ///
    /// The place comes from the mapping `destination(in:)` uses, and the words from the live
    /// navigation's own crumbs. The navigation is read with every place listed (an admin's) and
    /// no workspace or run, because a label can't name one: a workspace reads "Teams › Workspaces"
    /// and the wall reads its Runs place, whichever project is open.
    var landingCrumbs: [String] {
        var network = ShellNetwork()
        network.isAdmin = true
        func navigation(at place: String) -> CommanderNavigation {
            LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: place, needsYou: 0, network: network)
        }
        let places = Set(navigation(at: LiveShell.wall).places.map(\.id))
        let landing = item.flatMap { item in server.map { destination(of: item, on: $0, places: places).place } } ?? place
        return navigation(at: landing).crumbs
    }
}

// MARK: - The tray's moved pages

extension CommanderOpenRequest {
    /// The tray pages that moved to the main window (design/MAIN-WINDOW-INCREMENT-6-PLAN.md), each
    /// as the request that opens its window page. Nil for a page that stays in the tray: a quick
    /// action or a composer (Consult, Share, Request access, Hand off, Request review, New workspace).
    init?(page: MultiplayerSharePage, server: String? = nil) {
        func request(_ place: String, _ item: Item? = nil) -> CommanderOpenRequest {
            CommanderOpenRequest(place: place, server: server, item: item)
        }
        switch page {
        case .directory: self = request(NetworkPlace.directory)
        // Access requests are answered on Approvals, beside the approvals.
        case .requests: self = request(NetworkPlace.approvals)
        case .approval(let id): self = request(NetworkPlace.approvals, .approval(id))
        case .handoffs: self = request(NetworkPlace.handoffs)
        case .handoffDetail(let id): self = request(NetworkPlace.handoffs, .handoff(request: id))
        case .thread(let id, let title): self = request(NetworkPlace.threads, .thread(request: id, title: title))
        case .audit(let resource): self = request(NetworkPlace.audit, .audit(resource: resource))
        case .fanout: self = request(NetworkPlace.fanout)
        case .compare(let id): self = request(NetworkPlace.fanout, .fanout(request: id))
        case .groups: self = request(TeamsPlace.groups)
        case .group(let id): self = request(TeamsPlace.groups, .group(id))
        case .workspaces: self = request(TeamsPlace.workspaces)
        case .workspace(let id): self = request(TeamsPlace.workspaces, .workspace(id))
        case .claim(let id): self = request(TeamsPlace.workspaces, .workspace(id, band: .claims))
        case .card(let id, let card): self = request(TeamsPlace.workspaces, .workspace(id, band: .board, card: card))
        case .queueAdd(let id): self = request(TeamsPlace.workspaces, .workspace(id, band: .integration))
        case .hosts: self = request(TeamsPlace.hosts)
        case .hostRun(let resource): self = request(TeamsPlace.hosts, .host(resource: resource))
        case .knowledge, .knowledgeShare: self = request(TeamsPlace.knowledge)
        case .knowledgeItem(let id): self = request(TeamsPlace.knowledge, .knowledge(id))
        case .reputation(let resource): self = request(TeamsPlace.directory, .reputation(resource: resource))
        case .search: self = request(TeamsPlace.directory)
        // The tray keeps Policy and moderation for now; the mapping is here for when it links.
        case .policy: self = request(TeamsPlace.admin, .server)
        // Live work is on the wall. Watch names a friend's worker, whose hand-off is a remote tile.
        // Control names a worker by its resource too; one that is no remote tile opens the wall.
        case .watch(let resource), .control(let resource): self = request(LiveShell.wall, .remoteWorker(resource: resource))
        case .review(let id): self = request(LiveShell.wall, .review(request: id))
        // Request review is a composer, as Hand off and Consult are.
        case .requestAccess, .grant, .consult, .handoff, .reviewRequest, .workspaceCreate:
            return nil
        }
    }
}

// MARK: - The router

/// Opens a page of the main window from outside it.
///   open(_:)     brings the cockpit forward (reopening it when it is closed), which also activates
///                the app, then hands the request to the window
///   attach(_:)   the live window says how it shows a request; one that arrived first is handed over
///   detach(_:)   the window closed
/// A request that arrives while the window is closed waits for the reopened window. Only the last
/// one waits: opening a page twice shows the second.
@MainActor
final class CommanderWindowRouter {
    static let shared = CommanderWindowRouter()

    private let present: @MainActor () -> Void
    private var show: (@MainActor (CommanderOpenRequest) -> Void)?
    private var follow: (@MainActor (CommanderLink) -> Void)?
    private var attachment = 0
    private(set) var waiting: CommanderOpenRequest?
    /// An `agentcommander://run/…` or `agentcommander://project/…` link that arrived before the
    /// window could take it: at a cold launch, or while the window was closed. Only the last waits.
    private(set) var waitingLink: CommanderLink?

    /// `present` brings the cockpit window forward and activates the app. A test passes its own.
    init(present: @escaping @MainActor () -> Void = { SingleInstanceCoordinator.shared.bringCockpitForward() }) {
        self.present = present
    }

    func open(_ request: CommanderOpenRequest) {
        waiting = request
        present()
        deliver()
    }

    /// Shows a run or a project named by a link. The cockpit comes forward, reopening when it is
    /// closed, and the window looks the target up on the service it is using. The router only
    /// carries the link: nothing is started and no service is chosen.
    func open(_ link: CommanderLink) {
        waitingLink = link
        present()
        deliver()
    }

    /// Every run and project link in the list, in order; the last one is the one shown. Join
    /// links and anything else are left for their own handler. Returns whether any was taken.
    @discardableResult func open(links urls: [URL]) -> Bool {
        let links = urls.compactMap { CommanderLink($0) }
        guard let last = links.last else { return false }
        open(last)
        return true
    }

    /// The window's own way to show a request, and to follow a link. Returns a token for `detach`.
    @discardableResult func attach(_ show: @escaping @MainActor (CommanderOpenRequest) -> Void,
                                   follow: (@MainActor (CommanderLink) -> Void)? = nil) -> Int {
        attachment += 1
        self.show = show
        self.follow = follow
        deliver()
        return attachment
    }

    /// Forgets the window, unless a newer one has attached since.
    func detach(_ token: Int) {
        if token == attachment {
            show = nil
            follow = nil
        }
    }

    private func deliver() {
        if let show, let request = waiting {
            waiting = nil
            show(request)
        }
        if let follow, let link = waitingLink {
            waitingLink = nil
            follow(link)
        }
    }
}

// MARK: - The live window

extension CommanderOpenCatalog {
    /// What the network model lists now. A thread, an audit log and a reputation are read when
    /// they open, so they count as known on any saved server.
    @MainActor init(places: Set<String>, model: MultiplayerModel) {
        self.init(places: places) { item, server in
            guard model.server(server) != nil else { return false }
            let share = model.share, teams = model.share.teams
            switch item {
            case .approval(let id): return share.approvals[server]?.contains { $0.id == id } == true
            case .handoff(let request): return share.handoff(request, on: server) != nil
            case .fanout(let request): return share.live.fanouts[server]?.contains { $0.id == request } == true
            case .group(let id): return teams.group(id, on: server) != nil
            case .workspace(let id, _, _): return teams.workspace(id, on: server) != nil
            case .host(let resource):
                return teams.myHosts(on: server).contains { $0.id == resource } || teams.friendHosts(on: server).contains { $0.id == resource }
            case .knowledge(let id): return teams.item(id, on: server) != nil
            case .remoteWorker(let resource):
                return CommanderOpenDestination.remoteWorker(resource, on: server, among: share.remoteWorkers) != nil
            case .review(let request): return share.live.review(request, on: server) != nil
            case .thread, .audit, .reputation, .server: return true
            }
        }
    }
}

extension CommanderOpenDestination {
    /// The wall's tile for a friend's worker: the first hand-off listed that runs on it. The wall
    /// lists running hand-offs first, then the newest.
    static func remoteWorker(_ resource: String, on server: String, among workers: [MultiplayerRemoteWorker]) -> MultiplayerRemoteWorker? {
        workers.first { $0.server == server && $0.resource == resource }
    }

    /// Zooms the wall to a remote worker's tile, as choosing the tile does. Nothing changes when
    /// no hand-off runs on the worker.
    @MainActor static func zoom(_ ui: CockpitPresentationState, toRemoteWorker resource: String, on server: String,
                                among workers: [MultiplayerRemoteWorker]) {
        guard let worker = remoteWorker(resource, on: server, among: workers) else { return }
        ui.zoomedWorkerID = nil
        ui.zoomedRemoteWorkerID = worker.id
    }

    /// Shows this destination in the live window: the place, then the item in the window's own
    /// state. The tray's route is never read or moved.
    @MainActor func show(in ui: CockpitPresentationState, model: MultiplayerModel) {
        ui.composingRun = false
        ui.showingRunChooser = false
        ui.shellPlace = place
        guard let item, let server else { return }
        let network = LiveNetworkIntents(model: model, state: ui.networkPages, go: { ui.shellPlace = $0 })
        let teams = ui.teamsPages.pages
        switch item {
        case .approval(let id): ui.networkPages.open(.share(server, .approval(id)))
        case .handoff(let request): network.openWork(.handoff, request: request, on: server)
        case .thread(let request, let title): network.openThread(request, title: title, on: server)
        case .audit(let resource): network.openAudit(resource, on: server)
        case .fanout(let request): network.openWork(.fanout, request: request, on: server)
        case .group(let id): teams.selection.group = TeamsKey.make(id, on: server)
        case .workspace(let id, let band, let card):
            let key = TeamsKey.make(id, on: server)
            if let band { teams.selection.band[key] = band }
            if let card { teams.selection.card = TeamsKey.make(card, on: key) }
        case .host(let resource): teams.selection.host = TeamsKey.make(resource, on: server)
        case .knowledge(let id): teams.selection.knowledge = TeamsKey.make(id, on: server)
        case .reputation(let resource):
            teams.selection.searchServer = server
            teams.selection.hit = TeamsKey.make(resource, on: server)
        case .server: teams.selection.adminServer = server
        case .remoteWorker(let resource): Self.zoom(ui, toRemoteWorker: resource, on: server, among: model.share.remoteWorkers)
        // The wall has no review view of its own: its review row opens the review on Hand-offs.
        case .review(let request): network.openWork(.review, request: request, on: server)
        }
    }
}
