import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// The main window's network pages, as values:
//   1. Rows, readouts and summaries come from the content alone.
//   2. What is open is read from the network model's route.
//   3. Every answer crosses one boundary and comes back for its own row.
//   4. The sample state behaves as the network model does, so the previews can be clicked through.

@MainActor @Suite struct NetworkPagesTests {
    static let content = NetworkSample.content
    static let studio = NetworkSample.studio

    // MARK: Rows

    @Test func approvalsAreOrderedBySoonestEndAndNameTheirServer() {
        let rows = Self.content.approvalRows
        #expect(rows.map(\.approval.id) == ["ap-2", "ap-1", "ap-3"])
        #expect(rows[0].expiresIn == 252 && rows[0].waiting == 48)
        #expect(rows[0].serverName == "studio" && rows[0].resourceName == "relay-worker")
        #expect(rows[1].serverName == "lab" && rows[1].who == "jonah")
    }

    @Test func accessRowsListRequestsToYouBeforeTheOnesYouSent() {
        let rows = Self.content.accessRows
        #expect(rows.map(\.request.id) == ["ac-1", "ac-2", "ac-3"])
        #expect(rows.map(\.isIncoming) == [true, false, false])
        #expect(rows[0].who == "ines" && rows[1].who == "priya")
    }

    @Test func workRowsCarryEachRequestsStateNewestFirst() {
        let rows = Self.content.workRows
        #expect(rows.map(\.request) == ["ho-2", "ho-1", "rv-1", "ho-3"])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.request, $0) })
        // A hand-off's state is its run's once a report was read; otherwise the request's own.
        #expect(byID["ho-1"]?.state == "Done" && byID["ho-1"]?.tone == .working)
        #expect(byID["ho-2"]?.state == "Waiting" && byID["ho-2"]?.tone == .attention)
        #expect(byID["ho-3"]?.state == "Denied" && byID["ho-3"]?.tone == .failure)
        #expect(byID["rv-1"]?.kind == .review && byID["rv-1"]?.state == "2 important, 1 nit")
        #expect(byID["ho-1"]?.target == "mira’s mira-claude")
    }

    @Test func threadRowsIncludeEveryFanoutAnswer() {
        let rows = Self.content.threadRows
        #expect(rows.filter { $0.kind == .answer }.count == 5)
        #expect(rows.contains { $0.request == "fo-1-a" && $0.title == "mira-claude: Name the option that caps retries per request" })
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func fanoutRowsSayWhenAWinnerIsChosen() {
        let rows = Self.content.fanoutRows
        #expect(rows.map(\.request) == ["fo-1", "fo-2"])
        #expect(rows[0].state == "2 of 3 answered" && rows[0].tone == .attention)
        #expect(rows[1].state == "Winner chosen" && rows[1].tone == .working)
    }

    @Test func directoryRowsPutWhatYouCanUseFirst() {
        let rows = Self.content.directoryRows
        #expect(rows.prefix(3).allSatisfy { !$0.entry.granted.isEmpty })
        #expect(rows.first { $0.entry.id == "d-priya" }?.access.title == "Asked")
        #expect(rows.first { $0.entry.id == "d-build" }?.access.title == "Offered")
        #expect(rows.first { $0.entry.id == "d-mira" }?.access.tone == .working)
    }

    @Test func sharedRowsGroupGrantsByResource() throws {
        let rows = Self.content.sharedRows
        let relay = try #require(rows.first { $0.id == "\(Self.studio)/res-relay" })
        #expect(relay.grants.count == 3 && relay.people == ["mira", "ines"])
        #expect(relay.holders.map(\.who) == ["mira"])
        #expect(relay.nextExpiry == NetworkSample.now.addingTimeInterval(20 * 3600))
        #expect(NetworkSharedInspector.caption(relay.grants[0], now: NetworkSample.now).hasPrefix("Hand off tasks to the agent, up to 10 uses, until "))
        // The same resource on another server is its own row.
        #expect(rows.filter { $0.resource.id == "res-docs" }.count == 2)
    }

    @Test func friendRequestsCarryTheirArrival() {
        let rows = Self.content.friendRequests
        #expect(rows.map(\.who) == ["tomas"])
        #expect(rows[0].waiting == 5_400)
        // A blocked server's requests are hidden, as in the tray.
        #expect(!rows.contains { $0.server == NetworkSample.harbor })
    }

    // MARK: Telemetry

    @Test func everyPlaceHasReadoutsAndASummary() {
        for place in NetworkPlace.all {
            #expect(!Self.content.readouts(for: place).isEmpty, "\(place)")
            #expect(!Self.content.summary(for: place).isEmpty, "\(place)")
            #expect(!NetworkPlace.title(place).isEmpty && !NetworkPlace.kicker(place).isEmpty)
        }
        let servers = Self.content.readouts(for: NetworkPlace.servers)
        #expect(servers.map(\.value) == ["2/3", "2", "1", "1"])
        #expect(servers[2].tone == .failure, "a blocked server is a failure")
        let approvals = Self.content.readouts(for: NetworkPlace.approvals)
        #expect(approvals.map(\.value) == ["3", "1", "1", "4:12"])
        #expect(approvals[3].tone == .attention, "under five minutes left")
        #expect(Self.content.summary(for: NetworkPlace.servers).contains("harbor"))
    }

    @Test func aMissingHelperOrNoServerIsSaidInTheSummary() {
        var content = NetworkPagesContent()
        #expect(content.summary(for: NetworkPlace.directory).hasPrefix("No server yet"))
        content.isUnavailable = true
        #expect(content.summary(for: NetworkPlace.directory).contains("helper"))
    }

    // MARK: Route

    @Test func whatIsOpenIsReadFromTheRoute() {
        var content = Self.content
        #expect(content.openServer == nil && content.sharePage == nil)
        content.route = .server(NetworkSample.harbor)
        #expect(content.openServer?.name == "harbor")
        content.route = .share(Self.studio, .handoffDetail(request: "ho-1"))
        #expect(content.sharePage?.server == Self.studio && content.sharePage?.page == .handoffDetail(request: "ho-1"))
        content.route = .profile(Self.studio)
        #expect(content.profileServer?.id == Self.studio && content.openServer == nil)
    }

    @Test func inboxRowsLeadToTheirPage() {
        #expect(NetworkDeepLink(inboxID: "approval:srv-studio/ap-2") == .approval(id: "ap-2", server: "srv-studio"))
        #expect(NetworkDeepLink(inboxID: "access:srv-studio/ac-1")?.place == NetworkPlace.approvals)
        #expect(NetworkDeepLink(inboxID: "friend:srv-studio/fr-1") == .friend(server: "srv-studio"))
        #expect(NetworkDeepLink(inboxID: "friend:srv-studio/fr-1")?.place == NetworkPlace.people)
        // A worker's own request has no network page.
        #expect(NetworkDeepLink(inboxID: "Q-021") == nil)
        #expect(NetworkDeepLink(inboxID: "approval:nothing") == nil)
        // The IDs are the ones the live inbox gives its rows.
        let approval = MultiplayerPending(server: "srv-studio", item: MultiplayerApproval(id: "ap-2", peer: "mira", resource: "r", action: "a"))
        #expect(NetworkDeepLink(inboxID: LiveShell.id(approval)) == .approval(id: "ap-2", server: "srv-studio"))
    }

    // MARK: The action boundary

    @Test func aResultMirrorsTheNetworkModels() {
        let done = NetworkActionResult(MultiplayerActionResult.done(id: "ap-1", server: "s", message: "Approved."))
        #expect(done == .done(id: "ap-1", server: "s", message: "Approved.") && done.isDone && done.reason == nil)
        let failed = NetworkActionResult(MultiplayerActionResult.failed(id: "ap-1", server: "s", reason: "Couldn’t approve."))
        #expect(!failed.isDone && failed.reason == "Couldn’t approve." && failed.id == "ap-1" && failed.server == "s")
        #expect(failed.rowText == "Couldn’t approve." && failed.rowTone == .failure)
        #expect(done.rowText == "Approved." && done.rowTone == .working)
        #expect(NetworkActionResult.key(.approval, "x", on: "s") != NetworkActionResult.key(.access, "x", on: "s"))
    }

    @Test func aRowKeepsAFailureAndLetsASuccessGo() async throws {
        let results = NetworkRowResults()
        results.dwell = .milliseconds(250)
        var finished: [NetworkActionResult] = []
        results.run("a", { .failed(id: "1", server: "s", reason: "No answer.") }, finished: { finished.append($0) })
        #expect(results.running == ["a"])
        // A second press while the first runs is not taken.
        results.run("a", { .done(id: "1", server: "s", message: nil) })
        #expect(await Self.eventually { results.running.isEmpty })
        #expect(results.results["a"]?.reason == "No answer." && finished.count == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(results.results["a"]?.reason == "No answer.", "a failure stays")
        results.run("a", { .done(id: "1", server: "s", message: "Done.") })
        #expect(await Self.eventually { results.results["a"]?.isDone == true })
        #expect(await Self.eventually { results.results["a"] == nil }, "a success leaves after its dwell")
    }

    // MARK: Sample state

    static func preview() -> NetworkPreviewState {
        let state = NetworkPreviewState()
        state.latency = .milliseconds(1)
        state.results.dwell = .milliseconds(250)
        return state
    }

    /// Waits until the condition holds, for a few seconds at most.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<800 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aRenderOpensEachPagesDetail() {
        #expect(NetworkPreviewState(place: NetworkPlace.servers).content.openServer?.summary.state == .certChanged)
        #expect(NetworkPreviewState(place: NetworkPlace.servers).content.probe.probe?.fingerprint != nil)
        #expect(NetworkPreviewState(place: NetworkPlace.threads).content.thread.value?.comments.count == 4)
        #expect(NetworkPreviewState(place: NetworkPlace.audit).content.audit.value?.count == 8)
        #expect(NetworkPreviewState().content.route == .home)
    }

    @Test func approvingShowsTheRowsResultThenTheRowLeaves() async throws {
        let state = Self.preview()
        let pages = state.pages(go: { _ in })
        let approval = try #require(pages.content.approvalRows.first)
        pages.actions.decide(approval.approval, approval.server, true)
        #expect(state.pages(go: { _ in }).content.approvalRows.first?.isRunning == true)
        func row() -> NetworkApprovalRow? { state.pages(go: { _ in }).content.approvalRows.first { $0.id == approval.id } }
        #expect(await Self.eventually { row()?.result?.message == "Approved. It runs on this Mac now." }, "the row says how it ended")
        #expect(await Self.eventually { row() == nil }, "then it leaves")
    }

    @Test func aFailedWithdrawStaysOnItsRowAndCanBeTriedAgain() async throws {
        let state = Self.preview()
        let row = try #require(state.pages(go: { _ in }).content.accessRows.first { $0.request.id == "ac-2" })
        func shown() -> NetworkAccessRow? { state.pages(go: { _ in }).content.accessRows.first { $0.request.id == "ac-2" } }
        state.pages(go: { _ in }).actions.removeAccess(row.request, row.server, false)
        #expect(await Self.eventually { shown()?.result?.reason?.hasPrefix("Couldn’t withdraw the request.") == true })
        try await Task.sleep(for: .milliseconds(400))
        #expect(shown()?.result?.isDone == false, "the reason stays past the dwell")
        state.pages(go: { _ in }).actions.removeAccess(row.request, row.server, false)
        #expect(await Self.eventually { shown() == nil })
    }

    @Test func aFriendRequestCanBeDeclinedOrAccepted() async throws {
        let state = Self.preview()
        let pages = state.pages(go: { _ in })
        let request = try #require(pages.content.friendRequests.first)
        let decline = try #require(pages.actions.declineFriend)
        decline(request.request, request.server)
        #expect(await Self.eventually { state.pages(go: { _ in }).content.friendRequests.isEmpty })
        #expect(state.content.server(Self.studio)?.friends.contains { $0.handle == "tomas" } == false)

        let other = Self.preview()
        other.pages(go: { _ in }).actions.acceptFriend(request.request, request.server)
        #expect(await Self.eventually { other.content.server(Self.studio)?.friends.contains { $0.handle == "tomas" } == true })
        #expect(other.content.people.first?.people.contains { $0.handle == "tomas" } == true)
    }

    @Test func reviewOpensTheGrantSheetAndGrantingAnswersTheRequest() async throws {
        let state = Self.preview()
        let row = try #require(state.pages(go: { _ in }).content.accessRows.first { $0.request.id == "ac-1" })
        state.pages(go: { _ in }).actions.reviewAccess(row.request, row.server)
        var pages = state.pages(go: { _ in })
        #expect(pages.selection.grant == Self.studio, "the sheet opens in the window")
        #expect(pages.content.route == .home, "and the model's route stays where it was")
        #expect(state.grant.handle == "ines" && state.grant.resourceID == "res-relay")
        #expect(state.grant.actions == [MultiplayerSharePolicy.ask] && pages.content.canGrant)
        #expect(pages.content.grantResource?.name == "relay-worker")

        // The sample relay refuses unlimited uses without asking: the sheet stays open and says why.
        state.grant.uses = .unlimited
        state.grant.approval = .auto
        pages.actions.confirmGrant()
        #expect(await Self.eventually { state.content.grantRefusal?.contains("refused") == true })
        #expect(state.selection.grant == Self.studio, "a refused grant keeps the sheet open")

        state.grant.approval = .ask
        pages.actions.confirmGrant()
        #expect(await Self.eventually { state.selection.grant == nil })
        pages = state.pages(go: { _ in })
        #expect(pages.selection.grant == nil && pages.content.notice?.hasPrefix("ines can use relay-worker until ") == true)
        #expect(!pages.content.accessRows.contains { $0.request.id == "ac-1" }, "granting answered the request")
        #expect(state.content.server(Self.studio)?.grants.contains { $0.handle == "ines" && $0.capability == MultiplayerSharePolicy.ask } == true)
    }

    @Test func aServerCanBeOpenedRenamedTrustedAndRemoved() {
        let state = Self.preview()
        var pages = state.pages(go: { _ in })
        pages.actions.openServer(Self.studio)
        #expect(state.nickname == "studio" && !state.pages(go: { _ in }).content.canRename)
        state.nickname = "atelier"
        pages = state.pages(go: { _ in })
        #expect(pages.content.canRename)
        pages.actions.rename()
        #expect(state.content.server(Self.studio)?.name == "atelier")

        pages.actions.openServer(NetworkSample.harbor)
        pages = state.pages(go: { _ in })
        #expect(pages.content.canTrust && pages.content.probe.probe != nil)
        let harbor = pages.content.openServer!.summary
        pages.actions.askTrust(harbor)
        #expect(state.content.confirmingTrust == NetworkSample.harbor)
        pages.actions.confirmTrust()
        #expect(state.content.server(NetworkSample.harbor)?.summary.pin == NetworkSample.harborNewPin)
        #expect(state.content.server(NetworkSample.harbor)?.summary.state == .signedOut)

        pages.actions.askRemove(harbor)
        pages.actions.confirmRemove()
        #expect(state.content.server(NetworkSample.harbor) == nil && state.content.route == .home)
        #expect(state.health.figure == "2/2")
    }

    @Test func aCommentAWinnerAndAnAccessRequestChangeTheSampleState() throws {
        let state = Self.preview()
        var pages = state.pages(go: { _ in })
        pages.actions.openThread("ho-1", "Move the retry budget to each request", Self.studio)
        state.comment = "  Ship it.  "
        pages = state.pages(go: { _ in })
        #expect(pages.content.canComment)
        pages.actions.postComment()
        #expect(state.content.thread.value?.comments.last?.text == "Ship it." && state.comment.isEmpty)

        pages.actions.chooseWinner("fo-1-b", "fo-1", Self.studio)
        #expect(state.content.winner(of: "fo-1", on: Self.studio) == "fo-1-b")
        pages.actions.chooseWinner("fo-1-b", "fo-1", Self.studio)
        #expect(state.content.winner(of: "fo-1", on: Self.studio) == nil, "choosing it again clears it")

        let build = try #require(state.content.entry("d-build", on: Self.studio))
        pages.actions.requestAccess(build, Self.studio)
        #expect(state.content.route == .share(Self.studio, .requestAccess(resource: "d-build")))
        #expect(state.access.actions == [MultiplayerSharePolicy.hostRun], "the only action is chosen")
        pages.actions.sendAccessRequest()
        #expect(state.content.directoryRows.first { $0.entry.id == "d-build" }?.isWaiting == true)
        #expect(state.content.route == .home)
    }

    @Test func aFanoutCanBeComposedAndSent() {
        let state = Self.preview()
        let pages = state.pages(go: { _ in })
        pages.actions.startFanout(Self.studio)
        #expect(state.content.route == .share(Self.studio, .fanout) && !state.pages(go: { _ in }).content.canSendFanout)
        pages.actions.toggleFanoutTarget("d-mira")
        pages.actions.toggleFanoutTarget("d-ines")
        state.fanout.prompt = "Which name reads best?"
        #expect(state.pages(go: { _ in }).content.canSendFanout)
        pages.actions.sendFanout()
        let sent = state.content.server(Self.studio)?.fanouts.first
        #expect(sent?.children.count == 2 && sent?.title == "Which name reads best?")
        #expect(state.content.route == .share(Self.studio, .compare(request: sent?.request ?? "")))
    }

    // MARK: Shell fixes

    @Test func aCountdownOverAnHourReadsInHoursAndItsLineDrains() {
        #expect(NeedsYouClock.left(252) == "4:12")
        #expect(NeedsYouClock.left(3_600) == "1:00:00")
        #expect(NeedsYouClock.left(85_465) == "23:44:25")
        // With the wait known the span is wait plus time left.
        #expect(NeedsYouClock.fraction(left: 252, waited: 48) == 0.84)
        // Otherwise the shortest offered length that holds what is left.
        #expect(NeedsYouClock.fraction(left: 150, waited: nil) == 0.5)
        #expect(NeedsYouClock.fraction(left: 450, waited: nil) == 0.5)
        #expect(NeedsYouClock.fraction(left: 0, waited: nil) == 0)
    }

    @Test func newRunIsOffWhileTheServiceIsOfflineAndOneClaimIsSingular() {
        let offline = LiveShell.navigation(runs: ShellLiveTests.runs, openRunPath: nil, composing: false, place: LiveShell.wall,
                                           needsYou: 0, network: ShellLiveTests.network, isOnline: false)
        #expect(offline.place(LiveShell.newRun)?.isDisabled == true)
        #expect(ShellLiveTests.navigation().place(LiveShell.newRun)?.isDisabled == false)

        var network = ShellLiveTests.network
        network.workspaces = [MultiplayerPending(server: "srv-studio", item: MultiplayerWorkspace(
            id: "ws-1", name: "Relay launch", claims: [MultiplayerClaim(id: "c-1", kind: "path", key: "retry/", holder: "ryan")]))]
        let teams = ShellLiveTests.navigation(place: "team:srv-studio/ws-1", network: network)
        #expect(teams.selectedPlace?.spoken == "Relay launch, 1 claim")
    }

    @Test func presenceSaysAutoWithWhatTheServersShow() {
        #expect(CommanderProfile(name: "r", handle: "r", presence: .busy, choice: .auto).spokenPresence == "Auto: Busy")
        #expect(CommanderProfile(name: "r", handle: "r", presence: .away, choice: .away).spokenPresence == "Away")
        #expect(CommanderProfile(name: "r", handle: "r", presence: nil, choice: nil).spokenPresence == "Signed out")
    }

    @Test func theLiveInboxOffersDeclineAndShowsAnArrivalAndAFailure() throws {
        var network = ShellLiveTests.network
        network.friendRequests = [ShellNetwork.FriendRequest(server: "srv-studio", request: MultiplayerIncoming(
            id: "fr-1", handle: "tomas", requestedAt: ShellLiveTests.now.addingTimeInterval(-600)))]
        let id = LiveShell.id(network.friendRequests[0])
        let inbox = LiveShell.inbox(pending: [], network: network, now: ShellLiveTests.now, failures: [id: "Couldn’t accept. Try again."])
        let friend = try #require(inbox.items.first { $0.id == id })
        #expect(friend.verbs == [.decline, .accept] && friend.waiting == 600)
        #expect(friend.failure == "Couldn’t accept. Try again." && friend.isPending)
    }
}
