import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The triage tray (design/MAIN-WINDOW-INCREMENT-6-PLAN.md, issue #26):
//   1. Each tray page that moves builds the request for its window page: place, server and item.
//   2. A page that stays in the tray has no row.
//   3. The row sends the request, then closes the panel. No real window opens: the opener's two
//      steps and the router's `present` are the seams.
//   4. Requests 1 to 4 of design/demos/main-window-6/TRAY-REQUESTS.md.

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
        (.watch(resource: "res-1"), LiveShell.wall, nil, "Agents › Runs"),
        (.review(request: "rq-2"), LiveShell.wall, nil, "Agents › Runs"),
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

    /// The pages that stay in the tray: quick actions and composers.
    static let kept: [MultiplayerSharePage] = [
        .requestAccess(resource: "r"), .grant, .consult(resource: "r"), .handoff(resource: "r"), .control(resource: "r"),
        .reviewRequest(resource: "r"), .workspaceCreate
    ]

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
