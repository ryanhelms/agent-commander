import Foundation
import Testing
@testable import AgentCommander

// The open-in-window router (design/MAIN-WINDOW-INCREMENT-6-PLAN.md):
//   1. Every tray page that moved maps to a place the live navigation lists.
//   2. An unknown item opens its place without an item.
//   3. A request brings the window forward, and one sent while the window is closed is handed to
//      the window that reopens. No real window is involved: `present` and `attach` are the seams.

@MainActor @Suite struct CommanderWindowRouterTests {
    static let server = "srv-studio"
    static let workspace = "ws-1"

    /// An admin with one workspace, so the navigation lists every Teams place.
    static let network: ShellNetwork = {
        var network = ShellLiveTests.network
        network.isAdmin = true
        return network
    }()

    /// Every tray page the plan moves to the window.
    static let moved: [MultiplayerSharePage] = [
        .directory, .requests, .approval("ap-1"), .handoffs, .handoffDetail(request: "rq-1"),
        .thread(request: "rq-1", title: "Retries"), .audit(resource: "res-relay"), .fanout, .compare(request: "fo-1"),
        .groups, .group("g-1"), .workspaces, .workspace(workspace), .claim(workspace: workspace),
        .card(workspace: workspace, card: "card-1"), .queueAdd(workspace: workspace), .hosts, .hostRun(resource: "res-host"),
        .knowledge, .knowledgeShare, .knowledgeItem("k-1"), .reputation(resource: "res-relay"), .search, .policy,
        .watch(resource: "res-relay"), .control(resource: "res-relay"), .review(request: "rv-1")
    ]

    /// Two hand-offs on a friend's worker, running first as the wall lists them, and one elsewhere.
    static let remoteWorkers: [MultiplayerRemoteWorker] = [
        worker("rq-2", resource: "res-relay"), worker("rq-1", resource: "res-relay"), worker("rq-3", resource: "res-ios", server: "srv-home")
    ]

    static func worker(_ request: String, resource: String, server: String = server) -> MultiplayerRemoteWorker {
        MultiplayerRemoteWorker(server: server, request: request, resource: resource, canWatch: true, task: "Fix the test",
                                agent: "relay-worker", friend: "fixture-sam", serverName: "studio", harness: "claude",
                                state: "Running", tone: .working, at: nil)
    }

    /// A catalog that knows the remote workers above and one review, as the live window's does.
    static func wallCatalog() -> CommanderOpenCatalog {
        catalog { item, server in
            switch item {
            case .remoteWorker(let resource): CommanderOpenDestination.remoteWorker(resource, on: server, among: remoteWorkers) != nil
            case .review(let request): request == "rv-1" && server == Self.server
            default: true
            }
        }
    }

    static func catalog(_ network: ShellNetwork = network,
                        has: @escaping @MainActor (CommanderOpenRequest.Item, String) -> Bool = { _, _ in true }) -> CommanderOpenCatalog {
        CommanderOpenCatalog(places: LiveShell.places(network: network), has: has)
    }

    @Test func everyMovedPageOpensAPlaceTheNavigationLists() throws {
        let places = LiveShell.places(network: Self.network)
        for page in Self.moved {
            let request = try #require(CommanderOpenRequest(page: page, server: Self.server), "\(page) has no request")
            let destination = request.destination(in: Self.catalog())
            if page == .workspaces {
                // With a workspace the list is the Teams mode itself: the navigation shows the first one.
                let shown = ShellLiveTests.navigation(place: destination.place, network: Self.network).selection
                #expect(shown == LiveShell.team(Self.network.workspaces[0]))
                // Without one the place is listed as it is.
                var empty = Self.network
                empty.workspaces = []
                #expect(LiveShell.places(network: empty).contains(destination.place))
            } else {
                #expect(places.contains(destination.place), "\(page) opens \(destination.place), which the navigation doesn't list")
            }
        }
    }

    @Test func aMovedPageOpensItsOwnPlaceAndItem() throws {
        func destination(_ page: MultiplayerSharePage) throws -> CommanderOpenDestination {
            let request = try #require(CommanderOpenRequest(page: page, server: Self.server))
            return request.destination(in: Self.catalog())
        }
        let team = TeamsPlace.workspace(Self.workspace, on: Self.server)
        #expect(try destination(.approval("ap-1")) == .init(place: NetworkPlace.approvals, server: Self.server, item: .approval("ap-1")))
        #expect(try destination(.requests) == .init(place: NetworkPlace.approvals))
        #expect(try destination(.compare(request: "fo-1")).item == .fanout(request: "fo-1"))
        #expect(try destination(.workspace(Self.workspace)) == .init(place: team, server: Self.server, item: .workspace(Self.workspace)))
        #expect(try destination(.claim(workspace: Self.workspace)).item == .workspace(Self.workspace, band: .claims))
        #expect(try destination(.card(workspace: Self.workspace, card: "card-1"))
                == .init(place: team, server: Self.server, item: .workspace(Self.workspace, band: .board, card: "card-1")))
        #expect(try destination(.queueAdd(workspace: Self.workspace)).item == .workspace(Self.workspace, band: .integration))
        #expect(try destination(.policy) == .init(place: TeamsPlace.admin, server: Self.server, item: .server))
        #expect(try destination(.knowledgeItem("k-1")).place == TeamsPlace.knowledge)
    }

    @Test func watchControlAndReviewOpenFromTheWall() throws {
        func request(_ page: MultiplayerSharePage) throws -> CommanderOpenRequest {
            try #require(CommanderOpenRequest(page: page, server: Self.server))
        }
        let worker = CommanderOpenRequest.Item.remoteWorker(resource: "res-relay")
        #expect(try request(.watch(resource: "res-relay")) == .init(place: LiveShell.wall, server: Self.server, item: worker))
        #expect(try request(.control(resource: "res-relay")) == .init(place: LiveShell.wall, server: Self.server, item: worker))
        #expect(try request(.review(request: "rv-1")) == .init(place: LiveShell.wall, server: Self.server, item: .review(request: "rv-1")))
        // A known worker stays on the wall with its item; a known review opens where the wall's review row goes.
        let catalog = Self.wallCatalog()
        #expect(try request(.watch(resource: "res-relay")).destination(in: catalog) == .init(place: LiveShell.wall, server: Self.server, item: worker))
        #expect(try request(.review(request: "rv-1")).destination(in: catalog)
                == .init(place: WallLiveWork.place(for: .review), server: Self.server, item: .review(request: "rv-1")))
    }

    @Test func aKnownRemoteWorkerZoomsTheWallToItsTile() throws {
        let request = try #require(CommanderOpenRequest(page: .watch(resource: "res-relay"), server: Self.server))
        let destination = request.destination(in: Self.wallCatalog())
        guard case .remoteWorker(let resource) = destination.item, let server = destination.server else {
            Issue.record("a known worker keeps its item")
            return
        }
        let ui = CockpitPresentationState()
        ui.zoomedWorkerID = "local-1"
        CommanderOpenDestination.zoom(ui, toRemoteWorker: resource, on: server, among: Self.remoteWorkers)
        // The first hand-off listed on that worker, and no local worker beside it.
        #expect(ui.zoomedRemoteWorkerID == Self.remoteWorkers[0].id && ui.zoomedWorkerID == nil)
        // The same resource ID on another server is another worker.
        #expect(CommanderOpenDestination.remoteWorker("res-ios", on: Self.server, among: Self.remoteWorkers) == nil)
        #expect(CommanderOpenDestination.remoteWorker("res-ios", on: "srv-home", among: Self.remoteWorkers)?.request == "rq-3")
    }

    @Test func anUnknownWorkerOrReviewOpensTheWallWithoutZooming() throws {
        let catalog = Self.wallCatalog()
        for page in [MultiplayerSharePage.watch(resource: "res-gone"), .control(resource: "res-mine"), .review(request: "rv-gone")] {
            let request = try #require(CommanderOpenRequest(page: page, server: Self.server))
            #expect(request.destination(in: catalog) == .init(place: LiveShell.wall), "\(page) opens the wall alone")
        }
        // With no server the item can't be found.
        let loose = try #require(CommanderOpenRequest(page: .watch(resource: "res-relay")))
        #expect(loose.destination(in: catalog) == .init(place: LiveShell.wall))
        // A review the network lists, while the navigation has no Hand-offs page for it, opens the wall.
        var places = LiveShell.places(network: Self.network)
        places.remove(WallLiveWork.place(for: .review))
        let review = CommanderOpenRequest(place: LiveShell.wall, server: Self.server, item: .review(request: "rv-1"))
        #expect(review.destination(in: CommanderOpenCatalog(places: places)) == .init(place: LiveShell.wall))
        // Nothing zooms for a worker no hand-off runs on.
        let ui = CockpitPresentationState()
        CommanderOpenDestination.zoom(ui, toRemoteWorker: "res-gone", on: Self.server, among: Self.remoteWorkers)
        #expect(ui.zoomedRemoteWorkerID == nil && ui.zoomedWorkerID == nil)
    }

    @Test func aPageThatStaysInTheTrayHasNoRequest() {
        let kept: [MultiplayerSharePage] = [.requestAccess(resource: "r"), .grant, .consult(resource: "r"), .handoff(resource: "r"),
                                            .reviewRequest(resource: "r"), .workspaceCreate]
        #expect(kept.allSatisfy { CommanderOpenRequest(page: $0, server: Self.server) == nil })
    }

    @Test func anUnknownItemOpensThePlaceWithoutAnItem() {
        let nothing = Self.catalog { _, _ in false }
        let approval = CommanderOpenRequest(place: NetworkPlace.approvals, server: Self.server, item: .approval("gone"))
        #expect(approval.destination(in: nothing) == .init(place: NetworkPlace.approvals))
        // A workspace that is gone opens Teams, where the workspaces are listed.
        let workspace = CommanderOpenRequest(place: TeamsPlace.workspaces, server: Self.server, item: .workspace("gone", band: .claims))
        #expect(workspace.destination(in: nothing) == .init(place: TeamsPlace.workspaces))
        // The relay still lists it, but the navigation has no place for it yet.
        #expect(workspace.destination(in: Self.catalog()) == .init(place: TeamsPlace.workspaces))
        // An item with no server can't be found.
        let loose = CommanderOpenRequest(place: TeamsPlace.groups, item: .group("g-1"))
        #expect(loose.destination(in: Self.catalog()) == .init(place: TeamsPlace.groups))
    }

    @Test func aRequestBringsTheWindowForwardAndReachesIt() {
        var presented = 0
        var shown: [CommanderOpenRequest] = []
        let router = CommanderWindowRouter(present: { presented += 1 })
        router.attach { shown.append($0) }
        let request = CommanderOpenRequest(place: NetworkPlace.audit)
        router.open(request)
        #expect(presented == 1 && shown == [request] && router.waiting == nil)
    }

    @Test func aClosedWindowReopensAndTakesTheRequest() {
        var presented = 0
        var shown: [CommanderOpenRequest] = []
        let router = CommanderWindowRouter(present: { presented += 1 })
        // The window was open and has closed.
        let closed = router.attach { shown.append($0) }
        router.detach(closed)

        let first = CommanderOpenRequest(place: NetworkPlace.threads)
        let last = CommanderOpenRequest(place: TeamsPlace.hosts, server: Self.server, item: .host(resource: "res-host"))
        router.open(first)
        router.open(last)
        // Each asks for the window; nothing is shown until it is back.
        #expect(presented == 2 && shown.isEmpty && router.waiting == last)

        // The reopened window attaches and takes the last request, once.
        let reopened = router.attach { shown.append($0) }
        #expect(shown == [last] && router.waiting == nil)
        // A late detach from the old window doesn't cut off the new one.
        router.detach(closed)
        router.open(first)
        #expect(shown == [last, first])
        router.detach(reopened)
    }
}
