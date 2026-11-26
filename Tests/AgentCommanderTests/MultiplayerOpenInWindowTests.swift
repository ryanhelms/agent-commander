import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The triage tray (design/MAIN-WINDOW-INCREMENT-6-PLAN.md, issue #26):
//   1. Each tray page that has a window page builds the request for it: place, server and item.
//   2. A quick action or a composer has no row.
//   3. The row sends the request, then closes the panel. No real window opens: the opener's two
//      steps and the router's `present` are the seams.
//   4. Requests 1 to 4 of design/demos/main-window-6/TRAY-REQUESTS.md.
//   5. A page that passed its running-window check is gone from the tray: every entry point sends
//      its request and the tray's route stays. The pages the tray keeps still open in it.
//   6. Issue #33: Admin and Review are links too, Watch and Control are kept, and the menu bar panel
//      closes through the scene's dismissal, not `NSWindow.close()`.

@MainActor @Suite struct MultiplayerOpenInWindowTests {
    static let server = "srv-studio"
    static let workspace = "ws-1"

    /// Every tray page with a row: the page, its place, its item, and the breadcrumb drawn.
    static let moved: [(page: MultiplayerSharePage, place: String, item: CommanderOpenRequest.Item?, crumb: String)] = [
        (.requests, NetworkPlace.approvals, nil, "Network › Approvals"),
        (.approval("ap-1"), NetworkPlace.approvals, .approval("ap-1"), "Network › Approvals › this request"),
        (.directory, NetworkPlace.directory, nil, "Network › Directory"),
        (.handoffs, NetworkPlace.handoffs, nil, "Network › Hand-offs"),
        (.handoffDetail(request: "rq-1"), NetworkPlace.handoffs, .handoff(request: "rq-1"), "Network › Hand-offs › this hand-off"),
        (.thread(request: "rq-1", title: "Retries"), NetworkPlace.threads, .thread(request: "rq-1", title: "Retries"),
         "Network › Threads › this thread"),
        (.audit(resource: ""), NetworkPlace.audit, .audit(resource: ""), "Network › Audit"),
        (.audit(resource: "res-relay"), NetworkPlace.audit, .audit(resource: "res-relay"), "Network › Audit › this resource"),
        (.fanout, NetworkPlace.fanout, nil, "Network › Fan-out"),
        (.compare(request: "fo-1"), NetworkPlace.fanout, .fanout(request: "fo-1"), "Network › Fan-out › this fan-out"),
        (.watch(resource: "res-1"), LiveShell.wall, .remoteWorker(resource: "res-1"), "Agents › Runs › this worker"),
        (.control(resource: "res-1"), LiveShell.wall, .remoteWorker(resource: "res-1"), "Agents › Runs › this worker"),
        (.review(request: "rq-2"), LiveShell.wall, .review(request: "rq-2"), "Agents › Runs › this review"),
        (.groups, TeamsPlace.groups, nil, "Teams › Team tools › Groups"),
        (.group("g-1"), TeamsPlace.groups, .group("g-1"), "Teams › Team tools › Groups › this group"),
        (.workspaces, TeamsPlace.workspaces, nil, "Teams › Workspaces"),
        (.workspace(workspace), TeamsPlace.workspaces, .workspace(workspace), "Teams › Workspaces › this workspace"),
        (.claim(workspace: workspace), TeamsPlace.workspaces, .workspace(workspace, band: .claims),
         "Teams › Workspaces › this workspace’s claims"),
        (.card(workspace: workspace, card: "card-1"), TeamsPlace.workspaces, .workspace(workspace, band: .board, card: "card-1"),
         "Teams › Workspaces › this card"),
        (.queueAdd(workspace: workspace), TeamsPlace.workspaces, .workspace(workspace, band: .integration),
         "Teams › Workspaces › this workspace’s integration"),
        (.hosts, TeamsPlace.hosts, nil, "Teams › Team tools › Hosts"),
        (.hostRun(resource: "res-host"), TeamsPlace.hosts, .host(resource: "res-host"), "Teams › Team tools › Hosts › this host"),
        (.knowledge, TeamsPlace.knowledge, nil, "Teams › Team tools › Knowledge"),
        (.knowledgeShare, TeamsPlace.knowledge, nil, "Teams › Team tools › Knowledge"),
        (.knowledgeItem("k-1"), TeamsPlace.knowledge, .knowledge("k-1"), "Teams › Team tools › Knowledge › this item"),
        (.reputation(resource: "res-relay"), TeamsPlace.directory, .reputation(resource: "res-relay"),
         "Teams › Team tools › Directory › this reputation"),
        (.search, TeamsPlace.directory, nil, "Teams › Team tools › Directory"),
        (.policy, TeamsPlace.admin, .server, "Teams › Team tools › Admin › this server’s policy")
    ]

    /// The pages with no window page: quick actions and composers.
    static let kept: [MultiplayerSharePage] = [
        .requestAccess(resource: "r"), .grant, .consult(resource: "r"), .handoff(resource: "r"),
        .reviewRequest(resource: "r"), .workspaceCreate
    ]

    /// Pages with a row that the tray still draws under it. Watch's zoom to a remote tile has not
    /// had its running-window check, and the window has no hand-over composer for Control yet.
    static func pending(_ page: MultiplayerSharePage) -> Bool {
        switch page {
        case .watch, .control: true
        default: false
        }
    }

    /// The pages the tray no longer draws.
    static var removed: [(page: MultiplayerSharePage, place: String, item: CommanderOpenRequest.Item?, crumb: String)] {
        moved.filter { !pending($0.page) }
    }

    // MARK: 1. The request

    @Test func eachMovedPagesRowBuildsItsPlaceServerAndItem() throws {
        for row in Self.moved {
            let link = try #require(MultiplayerWindowLink(page: row.page, server: Self.server), "\(row.page) has no row")
            #expect(link.request == CommanderOpenRequest(place: row.place, server: Self.server, item: row.item), "\(row.page)")
            #expect(link.crumb == row.crumb, "\(row.page)")
        }
    }

    @Test func aRowNamesItsPlaceAsTheWindowDoes() throws {
        for row in Self.moved {
            let link = try #require(MultiplayerWindowLink(page: row.page, server: Self.server))
            let place = link.request.place
            let title = place == LiveShell.wall ? "Runs" : NetworkPlace.hasPage(place) ? NetworkPlace.title(place) : TeamsPlace.title(place)
            #expect(link.place == title, "\(row.page) names \(link.place), the window says \(title)")
            #expect(link.label == "Open \(title) in Agent Commander")
            #expect(link.hint.hasSuffix("loses this panel."))
        }
        let detail = try #require(MultiplayerWindowLink(page: .handoffDetail(request: "rq-1"), server: Self.server))
        #expect(detail.hint == "Shows this hand-off there and closes this panel.")
        #expect(MultiplayerWindowLink(page: .handoffs, server: Self.server)?.hint == "Closes this panel.")
    }

    @Test func everyRowOpensAPlaceTheNavigationLists() throws {
        var network = ShellLiveTests.network
        network.isAdmin = true
        var none = network
        none.workspaces = []
        let places = LiveShell.places(network: network).union(LiveShell.places(network: none))
        for row in Self.moved {
            let link = try #require(MultiplayerWindowLink(page: row.page, server: Self.server))
            #expect(places.contains(link.request.place), "\(row.page) opens \(link.request.place)")
        }
    }

    @Test func aPageThatStaysInTheTrayHasNoRow() {
        #expect(Self.kept.allSatisfy { MultiplayerWindowLink(page: $0, server: Self.server) == nil })
    }

    @Test func everyPageIsEitherMovedOrKept() {
        // A new tray page must be put in one list or the other.
        let all: [MultiplayerSharePage] = Self.moved.map(\.page) + Self.kept
        func name(_ page: MultiplayerSharePage) -> String { String(describing: page).prefix { $0 != "(" }.description }
        let known = Set(all.map(name))
        #expect(known.count == 33)
    }

    // MARK: 3. Open, then close

    @Test func theRowOpensThenClosesThePanel() throws {
        var log: [String] = []
        var sent: [CommanderOpenRequest] = []
        let opener = MultiplayerWindowOpener(open: { sent.append($0); log.append("open") }, close: { log.append("close") })
        let link = try #require(MultiplayerWindowLink(page: .handoffDetail(request: "rq-1"), server: Self.server))
        opener.send(link.request)
        #expect(sent == [CommanderOpenRequest(place: NetworkPlace.handoffs, server: Self.server, item: .handoff(request: "rq-1"))])
        #expect(log == ["open", "close"])
    }

    @Test func aPanelAddsItsOwnCloseAndKeepsTheOpener() {
        var log: [String] = []
        let given = MultiplayerWindowOpener(open: { _ in log.append("open") }, close: { log.append("outer") })
        given.closing { log.append("panel") }.send(CommanderOpenRequest(place: NetworkPlace.audit))
        #expect(log == ["open", "panel"])
    }

    @Test func theRequestReachesTheWindowThroughTheRouter() throws {
        var presented = 0
        var shown: [CommanderOpenRequest] = []
        let router = CommanderWindowRouter(present: { presented += 1 })
        router.attach { shown.append($0) }
        var closed = false
        let opener = MultiplayerWindowOpener(open: { router.open($0) }, close: { closed = true })
        let link = try #require(MultiplayerWindowLink(page: .card(workspace: Self.workspace, card: "card-1"), server: Self.server))
        opener.send(link.request)
        #expect(presented == 1 && closed)
        #expect(shown == [CommanderOpenRequest(place: TeamsPlace.workspaces, server: Self.server,
                                               item: .workspace(Self.workspace, band: .board, card: "card-1"))])
    }

    @Test func thePanelsWindowCloses() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panel = MultiplayerPanelWindow()
        panel.close()    // not in a window yet: nothing happens
        let host = NSHostingView(rootView: MultiplayerPanelWindowProbe(panel: panel))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(panel.window === window)
        window.orderFront(nil)
        #expect(window.isVisible)
        MultiplayerWindowOpener(open: { _ in }).closing { panel.close() }.send(CommanderOpenRequest(place: NetworkPlace.audit))
        #expect(!window.isVisible)
    }

    // MARK: 5. Removed pages

    @Test func theTrayKeepsItsQuickActionsWatchAndControl() {
        for page in Self.kept { #expect(page.staysInTray, "\(page)") }
        for row in Self.moved where Self.pending(row.page) { #expect(row.page.staysInTray, "\(row.page)") }
        for row in Self.removed { #expect(!row.page.staysInTray, "\(row.page)") }
        // 25 pages left the tray; 8 are still drawn in it.
        #expect(Self.removed.count == 26)    // audit is listed twice, with and without a resource
        #expect(Self.kept.count + Self.moved.filter { Self.pending($0.page) }.count == 8)
        // Watch and Control are the pages with a window page that the tray still draws.
        #expect(Self.moved.filter { $0.page.staysInTray }.map(\.page) == [.watch(resource: "res-1"), .control(resource: "res-1")])
        #expect(!MultiplayerSharePage.review(request: "r").staysInTray && !MultiplayerSharePage.policy.staysInTray)
    }

    /// A model on one online server, with an opener that records what it is sent.
    private func tray() async -> (model: MultiplayerModel, pages: MultiplayerPageOpener, sent: () -> [CommanderOpenRequest], closed: () -> Int) {
        let (model, _) = await MultiplayerTeamsFixture.model()
        final class Log { var sent: [CommanderOpenRequest] = []; var closed = 0 }
        let log = Log()
        let opener = MultiplayerWindowOpener(open: { log.sent.append($0) }, close: { log.closed += 1 })
        return (model, MultiplayerPageOpener(share: model.share, window: opener), { log.sent }, { log.closed })
    }

    @Test func aRemovedPagesEntryPointSendsItsRequestAndLeavesTheTrayWhereItWas() async {
        let (model, pages, sent, closed) = await tray()
        let home = MultiplayerTeamsFixture.home
        for row in Self.removed {
            pages.show(row.page, on: home)
            #expect(sent().last == CommanderOpenRequest(place: row.place, server: home, item: row.item), "\(row.page)")
            #expect(model.route == .home, "\(row.page) moved the tray")
        }
        #expect(sent().count == Self.removed.count && closed() == Self.removed.count)
        model.close()
    }

    @Test func aKeptPageStillOpensInTheTray() async {
        let (model, pages, sent, _) = await tray()
        let home = MultiplayerTeamsFixture.home
        let stay: [MultiplayerSharePage] = [
            .requestAccess(resource: "dir-h"), .grant, .consult(resource: "dir-h"), .handoff(resource: "dir-h"),
            .watch(resource: "dir-h"), .control(resource: "res-9"), .reviewRequest(resource: "dir-h"), .workspaceCreate
        ]
        for page in stay {
            model.go(.home)
            pages.show(page, on: home)
            #expect(model.route == .share(home, page), "\(page)")
        }
        #expect(sent().isEmpty)
        model.close()
    }

    @Test func liveRemoteWorkOpensInTheWindow() async {
        let (model, pages, sent, _) = await tray()
        let home = MultiplayerTeamsFixture.home
        func work(_ kind: MultiplayerRemoteWork.Kind) -> MultiplayerRemoteWork {
            MultiplayerRemoteWork(kind: kind, server: home, request: "rq-7", title: "", detail: "", state: "", tone: .neutral, at: nil)
        }
        pages.show(work(.handoff))
        pages.show(work(.fanout))
        pages.show(work(.review))
        #expect(sent() == [CommanderOpenRequest(place: NetworkPlace.handoffs, server: home, item: .handoff(request: "rq-7")),
                           CommanderOpenRequest(place: NetworkPlace.fanout, server: home, item: .fanout(request: "rq-7")),
                           CommanderOpenRequest(place: LiveShell.wall, server: home, item: .review(request: "rq-7"))])
        #expect(model.route == .home)
        model.close()
    }

    // MARK: 6. Admin and Review are links; Watch and Control are kept (issue #33)

    @Test func adminAndReviewSendTheirRequests() async {
        let (model, pages, sent, closed) = await tray()
        let home = MultiplayerTeamsFixture.home
        pages.show(.policy, on: home)
        pages.show(.review(request: "rq-review-1"), on: home)
        #expect(sent() == [CommanderOpenRequest(place: TeamsPlace.admin, server: home, item: .server),
                           CommanderOpenRequest(place: LiveShell.wall, server: home, item: .review(request: "rq-review-1"))])
        // Each one closed the panel, and neither moved the tray.
        #expect(closed() == 2 && model.route == .home)
        model.close()
    }

    @Test func watchStaysInTheTrayWithItsOpenRow() async throws {
        let (model, pages, sent, _) = await tray()
        let home = MultiplayerTeamsFixture.home
        pages.show(.watch(resource: "dir-h"), on: home)
        #expect(model.route == .share(home, .watch(resource: "dir-h")) && sent().isEmpty)
        // Its row still names the worker on the wall.
        let link = try #require(MultiplayerWindowLink(page: .watch(resource: "dir-h"), server: home))
        #expect(link.request == CommanderOpenRequest(place: LiveShell.wall, server: home, item: .remoteWorker(resource: "dir-h")))
        model.close()
    }

    @Test func controlStaysInTheTrayWithItsOpenRowAndHandOver() async throws {
        let (model, defaults, suite) = try await MultiplayerFixesTests.fixtureModel("triage-control")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        let home = MultiplayerFixesTests.home
        var sent: [CommanderOpenRequest] = []
        let pages = MultiplayerPageOpener(share: model.share, window: MultiplayerWindowOpener(open: { sent.append($0) }))
        pages.show(.control(resource: "res-2"), on: home)
        #expect(model.route == .share(home, .control(resource: "res-2")) && sent.isEmpty)
        // Its row names the worker on the wall, and the hand-over form is under it.
        let link = try #require(MultiplayerWindowLink(page: .control(resource: "res-2"), server: home))
        #expect(link.request == CommanderOpenRequest(place: LiveShell.wall, server: home, item: .remoteWorker(resource: "res-2")))
        #expect(link.crumb == "Agents › Runs › this worker")
        await model.settle()
        let nodes = try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model, closesOnOpen: false))
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Open Runs in Agent Commander" })
        #expect(nodes.contains { $0.label == "Hand over control" } && nodes.contains { $0.role == "AXButton" && $0.label == "Hand over" })
    }

    @Test func theHandoffsRowCountsHandoffsAndReviewsAsSent() async throws {
        let server = Self.server
        func row(_ handoffs: Int, _ reviews: Int) throws -> MultiplayerWindowShortcut {
            try #require(MultiplayerWindowShortcut.sharing(on: server, directory: 0, waiting: 0, handoffs: handoffs, reviews: reviews)
                .first { $0.link.request.place == NetworkPlace.handoffs })
        }
        let both = try row(2, 1)
        #expect(both.count == 3 && both.figure == "3 sent" && both.label == "Open Hand-offs in Agent Commander, 3 sent")
        #expect(try row(0, 1).figure == "1 sent")
        #expect(try row(0, 0).figure == nil && row(0, 0).label == "Open Hand-offs in Agent Commander")
        // Only Hand-offs names what it counts.
        let others = MultiplayerWindowShortcut.sharing(on: server, directory: 4, waiting: 2, handoffs: 0)
        #expect(others.map(\.figure) == ["4", "2", nil, nil])

        // The server page draws the fixture's hand-offs and reviews as one count, as the window's page does.
        let (model, defaults, suite) = try await MultiplayerFixesTests.fixtureModel("triage-sent")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        let home = MultiplayerFixesTests.home
        model.openServer(home)
        await model.settle()
        let handoffs = model.share.handoffs[home]?.count ?? 0, reviews = model.share.live.reviews[home]?.count ?? 0
        #expect(handoffs > 0 && reviews > 0)
        let nodes = try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model, closesOnOpen: false))
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Open Hand-offs in Agent Commander, \(handoffs + reviews) sent" },
                "\(nodes.map(\.description))")
    }

    @Test func anAdminsServerPageLinksToAdmin() throws {
        let server = Self.server
        let member = MultiplayerWindowShortcut.serverTeams(on: server, groups: 1, workspaces: 1, hosts: 1, knowledge: 1)
        #expect(!member.contains { $0.link.request.place == TeamsPlace.admin })
        let admin = MultiplayerWindowShortcut.serverTeams(on: server, groups: 1, workspaces: 1, hosts: 1, knowledge: 1, isAdmin: true)
        let row = try #require(admin.last)
        #expect(admin.count == member.count + 1)
        #expect(row.link.request == CommanderOpenRequest(place: TeamsPlace.admin, server: server, item: .server))
        #expect(row.title == "Admin" && row.label == "Open Admin in Agent Commander")
        #expect(row.link.path == "Agent Commander › Teams › Team tools › Admin › this server’s policy")
    }

    @Test func theTrayOffersTakeBackAndAnAdminLink() async throws {
        let (model, defaults, suite) = try await MultiplayerFixesTests.fixtureModel("triage-links")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        func nodes() async throws -> [MultiplayerAXNode] {
            await model.settle()
            return try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model, closesOnOpen: false))
        }
        // Agents: Take back control is still a quick action on the tab.
        model.tab = .agents
        var found = try await nodes()
        #expect(found.contains { $0.role == "AXButton" && $0.label.hasPrefix("Take back control of ") }, "\(found.map(\.description))")
        // A server's page: an admin's Teams band links to Admin; the tray has no Relay policy row.
        model.openServer(MultiplayerFixesTests.home)
        found = try await nodes()
        #expect(model.isAdmin(MultiplayerFixesTests.home))
        #expect(found.contains { $0.role == "AXButton" && $0.label == "Open Admin in Agent Commander" }, "\(found.map(\.description))")
        #expect(!found.contains { $0.label.hasPrefix("Relay policy") })
    }

    // MARK: 6. The menu bar panel closes through the scene (issue #33, defect 1)

    /// A window that counts direct closes and says whether it is on screen.
    final class SpyWindow: NSWindow {
        var closes = 0
        var shown = true
        override func close() { closes += 1; shown = false }
        override var isVisible: Bool { shown }
    }

    private func spy() -> (panel: MultiplayerPanelWindow, window: SpyWindow) {
        _ = NSApplication.shared
        let window = SpyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 100), styleMask: [.borderless],
                               backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let panel = MultiplayerPanelWindow()
        panel.window = window
        panel.grace = .milliseconds(20)
        return (panel, window)
    }

    @Test func theMenuBarPanelClosesThroughTheScenesDismissalNotTheWindow() async {
        let (panel, window) = spy()
        var dismissed = 0
        // The scene takes its own panel down, as `MenuBarExtra` does.
        let dismissal = MultiplayerPanelDismissal { dismissed += 1; window.shown = false }
        let opener = MultiplayerWindowOpener(open: { _ in }).closing { panel.close(through: dismissal) }
        opener.send(CommanderOpenRequest(place: NetworkPlace.audit))
        #expect(dismissed == 1 && window.closes == 0)
        await panel.close(through: dismissal)?.value
        #expect(dismissed == 2 && window.closes == 0, "the window was closed directly")
    }

    @Test func aDismissalThatLeavesThePanelUpFallsBackToTheWindow() async {
        let (panel, window) = spy()
        var dismissed = 0
        let check = panel.close(through: MultiplayerPanelDismissal { dismissed += 1 })
        // Nothing is closed directly until the scene has had its time.
        #expect(dismissed == 1 && window.closes == 0)
        await check?.value
        #expect(window.closes == 1)
    }

    @Test func aPanelOutsideTheMenuBarClosesItsWindow() {
        let (panel, window) = spy()
        #expect(panel.close() == nil)
        #expect(window.closes == 1)
    }

    @Test func theMenuBarSceneGivesItsPanelTheDismissal() throws {
        _ = NSApplication.shared
        final class Seen { var dismissal: MultiplayerPanelDismissal?; var plain: MultiplayerPanelDismissal? }
        struct Reader: View {
            let seen: (MultiplayerPanelDismissal?) -> Void
            @Environment(\.multiplayerPanelDismissal) private var dismissal
            var body: some View {
                seen(dismissal)
                return Color.clear
            }
        }
        let seen = Seen()
        let marked = NSHostingView(rootView: Reader { seen.dismissal = $0 }.multiplayerMenuBarPanel())
        marked.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        marked.layoutSubtreeIfNeeded()
        let plain = NSHostingView(rootView: Reader { seen.plain = $0 })
        plain.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        plain.layoutSubtreeIfNeeded()
        // Only the `MenuBarExtra` content is marked; a join-link window or the cockpit gets none.
        #expect(seen.dismissal != nil && seen.plain == nil)
    }

    @Test func eachTabsCompactRowsSendTheirPlaces() {
        func requests(_ rows: [MultiplayerWindowShortcut]) -> [CommanderOpenRequest] { rows.map(\.link.request) }
        // Agents and People: one row per place, for every server.
        #expect(requests(MultiplayerWindowShortcut.agents()) == [CommanderOpenRequest(place: NetworkPlace.directory),
                                                                 CommanderOpenRequest(place: NetworkPlace.fanout)])
        let teams = MultiplayerWindowShortcut.teams(workspaces: 2, hosts: 0, knowledge: 5)
        #expect(requests(teams) == [CommanderOpenRequest(place: TeamsPlace.workspaces), CommanderOpenRequest(place: TeamsPlace.hosts),
                                    CommanderOpenRequest(place: TeamsPlace.knowledge)])
        #expect(teams.map(\.title) == ["Workspaces", "Hosts", "Knowledge"] && teams.map(\.count) == [2, 0, 5])
        #expect(requests(MultiplayerWindowShortcut.groups(3)) == [CommanderOpenRequest(place: TeamsPlace.groups)])

        // A server's page: the same places, on that server.
        let server = Self.server
        let sharing = MultiplayerWindowShortcut.sharing(on: server, directory: 4, waiting: 2, handoffs: 1)
        #expect(requests(sharing) == [CommanderOpenRequest(place: NetworkPlace.directory, server: server),
                                      CommanderOpenRequest(place: NetworkPlace.approvals, server: server),
                                      CommanderOpenRequest(place: NetworkPlace.handoffs, server: server),
                                      CommanderOpenRequest(place: NetworkPlace.audit, server: server, item: .audit(resource: ""))])
        #expect(sharing.map(\.title) == ["Directory", "Approvals", "Hand-offs", "Audit"])
        #expect(sharing[1].isHot && sharing[1].count == 2)
        let serverTeams = MultiplayerWindowShortcut.serverTeams(on: server, groups: 1, workspaces: 1, hosts: 1, knowledge: 1)
        #expect(requests(serverTeams) == [TeamsPlace.groups, TeamsPlace.workspaces, TeamsPlace.hosts, TeamsPlace.knowledge,
                                          TeamsPlace.directory].map { CommanderOpenRequest(place: $0, server: server) })
    }

    @Test func aCompactRowSaysWhereItLandsAndHowMuchIsThere() throws {
        let row = try #require(MultiplayerWindowShortcut(.handoffs, on: Self.server, symbol: "arrow.up.right", count: 3))
        #expect(row.title == "Hand-offs" && row.link.path == "Agent Commander › Network › Hand-offs")
        #expect(row.label == "Open Hand-offs in Agent Commander, 3" && row.figure == "3")
        #expect(MultiplayerWindowShortcut(.hosts, symbol: "cpu")?.label == "Open Hosts in Agent Commander")
        // A page with no window page has no compact row.
        #expect(MultiplayerWindowShortcut(.grant, symbol: "square.and.arrow.up") == nil)
    }

    @Test func theTabsOfferCompactRowsWhereTheirDensePagesWere() async throws {
        let (model, defaults, suite) = try await MultiplayerFixesTests.fixtureModel("triage-tabs")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        func buttons() async throws -> [String] {
            await model.settle()
            return try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model, closesOnOpen: false))
                .filter { $0.role == "AXButton" }.map(\.label)
        }
        func opens(_ place: String, in labels: [String]) -> Bool { labels.contains { $0.hasPrefix("Open \(place) in Agent Commander") } }

        model.tab = .agents
        var labels = try await buttons()
        for place in ["Directory", "Fan-out", "Workspaces", "Hosts", "Knowledge"] { #expect(opens(place, in: labels), "\(place)\n\(labels)") }
        // What the tray keeps is still there: decisions, quick actions and New workspace.
        #expect(labels.contains { $0.hasPrefix("Approve: ") } && labels.contains { $0.hasPrefix("Deny: ") }, "\(labels)")
        #expect(labels.contains { $0.hasPrefix("Consult ") } && labels.contains { $0.hasPrefix("Share ") }, "\(labels)")
        #expect(labels.contains("New workspace"), "\(labels)")

        model.tab = .people
        labels = try await buttons()
        #expect(opens("Groups", in: labels), "\(labels)")

        model.openServer(MultiplayerFixesTests.home)
        labels = try await buttons()
        for place in ["Directory", "Approvals", "Hand-offs", "Audit", "Groups", "Workspaces", "Hosts", "Knowledge"] {
            #expect(opens(place, in: labels), "\(place)\n\(labels)")
        }
    }

    @Test func aRemovedPageIsItsRowAlone() async throws {
        let (model, defaults, suite) = try await MultiplayerFixesTests.fixtureModel("triage-page")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        let home = MultiplayerFixesTests.home
        // The model can still be put on the page; the tray draws the row and nothing of the page.
        model.share.open(.handoffs, on: home)
        await model.settle()
        var nodes = try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model, closesOnOpen: false))
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Open Hand-offs in Agent Commander" })
        #expect(!nodes.contains { ($0.label + $0.value).contains("Fix flaky reconnect test") })
        // Relay policy passed its check too: the row, and nothing of the page.
        model.go(.home)
        model.share.open(.policy, on: home)
        await model.settle()
        nodes = try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model, closesOnOpen: false))
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Open Admin in Agent Commander" })
        #expect(!nodes.contains { $0.role == "AXButton" && $0.label == "Save policy" })
        // Watch keeps its page under the row.
        model.go(.home)
        model.share.live.startWatch("dir-sam-agent", on: home)
        await model.settle()
        nodes = try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model, closesOnOpen: false))
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Open Runs in Agent Commander" })
        #expect(nodes.contains { ($0.label + $0.value).contains("Read-only") }, "\(nodes.map(\.description))")
    }

    // MARK: 4. Tray requests 1 to 4

    @Test func theSecretRefusalIsOneSentenceRun() {
        let label = MultiplayerKnowledgeForm.secretLabel(MultiplayerSecretCheck.refusal)
        #expect(label.hasPrefix("Not shared: a secret was found. "))
        #expect(label.contains(MultiplayerSentence.sentence(MultiplayerSecretCheck.refusal)))
        #expect(label.hasSuffix("Secrets never travel."))
    }

    @Test func aRefusedShareNamesTheWidestScope() {
        let refusal = MultiplayerKnowledgeHost.refusal
        let forbidden = "Couldn’t share notes. Forbidden."
        #expect(refusal(forbidden, .server, .group, "studio") == "Couldn’t share notes. Forbidden. studio lets knowledge reach a group at most.")
        #expect(refusal(forbidden, .group, .friend, "studio") == "Couldn’t share notes. Forbidden. studio lets knowledge reach one friend at most.")
        // Within the limit, or with no limit known, the reason stands as it is.
        #expect(refusal(forbidden, .group, .group, "studio") == forbidden)
        #expect(refusal(forbidden, .server, nil, "studio") == forbidden)
        // Said once.
        let named = "Couldn’t share notes. studio lets knowledge reach a group at most."
        #expect(refusal(named, .server, .group, "studio") == named)
        #expect(refusal(nil, .server, .group, "studio") == nil)
    }

    @Test func oneMemberLoses() {
        let one = MultiplayerGroup(id: "g", name: "Solo", owner: "ryan", members: ["ryan"])
        let three = MultiplayerGroup(id: "g", name: "Crew", owner: "ryan", members: ["ryan", "mira", "sam"])
        #expect(MultiplayerGroupPage.deleteQuestion(one) == "Delete Solo? Its 1 member loses every grant made to the group.")
        #expect(MultiplayerGroupPage.deleteQuestion(three) == "Delete Crew? Its 3 members lose every grant made to the group.")
    }

    @Test func aRefusedClaimIsPassedOnBeforeTheResult() {
        var log: [String] = []
        let failed = MultiplayerActionResult.failed(id: "", server: Self.server, reason: "Couldn’t claim it. Held by sam/sam-codex.")
        let holder = MultiplayerClaimRefusal(holder: "sam", agent: "sam-codex", claim: "cl-9")
        MultiplayerClaimAnswer(result: failed, refusal: holder)
            .report(to: { log.append("finish \($0.isDone)") }, refused: { log.append("refused \($0.holder)/\($0.agent) \($0.claim)") })
        #expect(log == ["refused sam/sam-codex cl-9", "finish false"])

        // Another refusal, or a claim that was made, reports its result alone.
        log = []
        MultiplayerClaimAnswer(result: failed).report(to: { _ in log.append("finish") }, refused: { _ in log.append("refused") })
        MultiplayerClaimAnswer(result: .done(id: "cl-1", server: Self.server, message: "Claimed."))
            .report(to: { _ in log.append("finish") }, refused: { _ in log.append("refused") })
        #expect(log == ["finish", "finish"])
        // A caller that doesn't ask for the holder still gets the result.
        MultiplayerClaimAnswer(result: failed, refusal: holder).report(to: { _ in log.append("finish") }, refused: nil)
        #expect(log.count == 3)
    }

    @Test func theClaimAndCardHostsTakeOnRefused() {
        let model = MultiplayerModel(client: nil)
        var seen: MultiplayerClaimRefusal?
        let claim = MultiplayerClaimHost(model: model, server: Self.server, workspace: Self.workspace, onFinish: { _ in },
                                         onRefused: { seen = $0 })
        let card = MultiplayerCardHost(model: model, server: Self.server, workspace: Self.workspace, card: "card-1", onFinish: { _ in },
                                       onRefused: { seen = $0 })
        claim.onRefused?(MultiplayerClaimRefusal(holder: "sam"))
        #expect(seen?.holder == "sam")
        card.onRefused?(MultiplayerClaimRefusal(holder: "ines"))
        #expect(seen?.holder == "ines")
        // The callback is optional: the hosts are built as before without it.
        #expect(MultiplayerClaimHost(model: model, server: Self.server, workspace: Self.workspace, onFinish: { _ in }).onRefused == nil)
    }
}
