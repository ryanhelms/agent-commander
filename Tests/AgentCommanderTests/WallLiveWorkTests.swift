import Foundation
import Testing
@testable import AgentCommander

// The wall's live work: how a local worker is matched to what the network says about it, which
// remote work earns a row, where each kind opens, and Apply's three steps (choose, confirm, result).

@MainActor @Suite struct WallLiveWorkTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func control(_ worker: String, handle: String, minutes: Double, server: String = "srv-a") -> WallLiveWork.Control {
        WallLiveWork.Control(server: server, serverName: "studio",
                             handover: MultiplayerHandover(handle: handle, resource: WallLiveWork.resourceID(forWorker: worker),
                                                           until: now.addingTimeInterval(minutes * 60)),
                             resourceName: worker)
    }

    @Test func aWorkerIsMatchedByTheResourceItIsSharedAs() {
        // Sharing a worker names its resource from the worker's ID alone, whatever it is called.
        let id = WallLiveWork.resourceID(forWorker: "W-044")
        #expect(id == MultiplayerShareTarget.agent(id: "W-044", name: "Retry telemetry").resourceID)
        #expect(id == MultiplayerShareTarget.agent(id: "W-044", name: "renamed").resourceID)
        #expect(id != WallLiveWork.resourceID(forWorker: "W-045"))
        #expect(id != MultiplayerShareTarget.repo(path: "W-044", name: "x").resourceID)
    }

    @Test func aHeldWorkerShowsItsHoldersSoonestFirstAndOnlyWhileTheyHold() {
        var wall = WallLiveWork()
        wall.now = Self.now
        wall.controls = [Self.control("W-044", handle: "mira", minutes: 24), Self.control("W-044", handle: "jonah", minutes: 5),
                         Self.control("W-044", handle: "late", minutes: -1), Self.control("W-045", handle: "ines", minutes: 9)]
        #expect(wall.controls(forWorker: "W-044").map(\.handover.handle) == ["jonah", "mira"])
        #expect(wall.controls(forWorker: "W-045").map(\.handover.handle) == ["ines"])
        #expect(wall.controls(forWorker: "W-046").isEmpty)
    }

    @Test func aSuggestionShowsAtTheWorkerItIsFor() {
        var wall = WallLiveWork()
        wall.suggestions = [
            WallLiveWork.Suggestion(server: "srv-a", approval: "ap-1", resource: WallLiveWork.resourceID(forWorker: "W-045"),
                                    who: "jonah", text: "Check the streaming client too."),
            WallLiveWork.Suggestion(server: "srv-a", approval: "ap-2", resource: "res-other", who: "A friend", text: "")
        ]
        #expect(wall.suggestions(forWorker: "W-045").map(\.approval) == ["ap-1"])
        #expect(wall.suggestions(forWorker: "W-044").isEmpty)
        #expect(wall.suggestions[0].sentence == "jonah suggests: Check the streaming client too.")
        #expect(wall.suggestions[1].sentence == "A friend sent a suggestion")
        #expect(!wall.isEmpty && WallLiveWork().isEmpty)
    }

    @Test func onlyReviewsAndFanOutsThatStillNeedALookGetARow() {
        func work(_ kind: MultiplayerRemoteWork.Kind, _ request: String) -> MultiplayerRemoteWork {
            MultiplayerRemoteWork(kind: kind, server: "srv-a", request: request, title: request, detail: "", state: "", tone: .neutral, at: nil)
        }
        let all = [work(.handoff, "ho-1"), work(.review, "rv-1"), work(.review, "rv-posted"), work(.fanout, "fo-1"), work(.fanout, "fo-won")]
        let rows = WallLiveWork.rows(all) { $0.request == "rv-posted" || $0.request == "fo-won" }
        #expect(rows.map(\.request) == ["rv-1", "fo-1"])
        #expect(WallLiveWork.place(for: .handoff) == NetworkPlace.handoffs)
        #expect(WallLiveWork.place(for: .review) == NetworkPlace.handoffs)
        #expect(WallLiveWork.place(for: .fanout) == NetworkPlace.fanout)
        #expect(WallLiveWork.more(1) == "1 more" && WallLiveWork.more(3) == "3 more")
    }

    @Test func theSampleAttachesToThePreviewRunsWorkers() {
        let wall = WallSample.work(now: Self.now)
        #expect(wall.controls(forWorker: WallSample.heldWorker).count == 1)
        #expect(wall.suggestions(forWorker: WallSample.suggestedWorker).count == 1)
        #expect(wall.remoteWorkers.count == 2 && wall.work.count == 2)
        #expect(WallSample.watch(now: Self.now).events.count == 6)
    }

    /// The network model's own state, read as the wall's value, and the wall's intents sent back.
    @Test func readsTheNetworkModelAndOpensWorkOnItsRoute() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("wall-live-work")
        defer { model.close() }
        let wall = WallLiveWork(model: model)
        #expect(wall.remoteWorkers == model.share.remoteWorkers && !wall.remoteWorkers.isEmpty)
        #expect(wall.controls.map(\.handover) == model.share.live.activeHandovers.map(\.item))
        #expect(wall.suggestions.count == model.share.pendingApprovals.filter(\.item.isSuggestion).count)
        #expect(wall.work.allSatisfy { $0.kind != .handoff })
        if let control = wall.controls.first {
            #expect(control.resourceName == model.share.resourceName(control.handover.resource, on: control.server))
        }
        let pages = NetworkPagesLiveState()
        let actions = WallLiveWorkActions.live(model, pages: pages)
        let first = try #require(wall.remoteWorkers.first)
        let before = model.route
        actions.openWork(.handoff, first.request, first.server)
        // The window's own page opens it. The tray stays where it was.
        #expect(pages.route == .share(first.server, .handoffDetail(request: first.request)))
        #expect(model.route == before)
        #expect(actions.zoom != nil)
    }

    // MARK: Apply

    static let patch = NetworkApplyDraft(server: "srv-a", request: "ho-1", index: 1, name: "retry-budget.patch", kind: "patch",
                                         checkout: "/Users/someone/GitHub/relay")

    @Test func theConfirmationNamesTheCheckoutAndSaysNothingIsOverwritten() {
        let patch = Self.patch
        #expect(patch.folder == "relay")
        #expect(patch.question == "Apply retry-budget.patch to relay?")
        #expect(patch.confirmTitle == "Apply to relay")
        #expect(patch.consequence.contains("Nothing is committed"))
        let report = NetworkApplyDraft(server: "srv-a", request: "ho-1", index: 0, name: "report.md", kind: "report",
                                       checkout: NSHomeDirectory() + "/GitHub/relay")
        #expect(report.question == "Save report.md into relay?")
        #expect(report.consequence.contains("Nothing is overwritten"))
        #expect(report.shownPath == "~/GitHub/relay")
        #expect(patch.shownPath == "/Users/someone/GitHub/relay")
        #expect(patch.key != report.key)
        #expect(patch.key == NetworkApplyDraft.key(request: "ho-1", index: 1, on: "srv-a"))
    }

    /// Choosing a checkout writes nothing. Only the confirmation sends, once, and its result stays.
    @Test func applyWaitsForItsConfirmationAndKeepsEachArtifactsResult() async throws {
        let results = NetworkRowResults()
        results.dwell = .milliseconds(10)
        var draft: NetworkApplyDraft?
        var sent: [NetworkApplyDraft] = []
        var chosen: String? = "/tmp/relay"
        var fails = false
        var network = NetworkPageActions()
        network.chooseCheckout = { _ in chosen }
        network.applyArtifact = { waiting, _ in
            sent.append(waiting)
            return fails ? .failed(id: waiting.request, server: waiting.server, reason: "Couldn’t apply it. git apply failed.")
                         : .done(id: waiting.request, server: waiting.server, message: "Applied to relay.")
        }
        let row = MultiplayerSentRequest(request: "ho-1", resource: "d-mira", action: MultiplayerSharePolicy.handoff, title: "t")
        var actions = NetworkPagesActions()
        #expect(actions.apply == nil)
        actions.bindApply(network, results: results, draft: { draft }, setDraft: { draft = $0 }, row: { _ in row })
        let apply = try #require(actions.apply)
        let artifacts = try #require(NetworkSample.handoffReport(result: true)).artifacts

        // No folder chosen: nothing waits and nothing is sent.
        chosen = nil
        apply(1, artifacts[1], row, "srv-a")
        #expect(draft == nil && sent.isEmpty)

        chosen = "/tmp/relay"
        apply(1, artifacts[1], row, "srv-a")
        #expect(draft?.checkout == "/tmp/relay" && draft?.name == "retry-budget.patch" && draft?.isPatch == true)
        #expect(sent.isEmpty)
        actions.cancelApply()
        #expect(draft == nil && sent.isEmpty)

        apply(1, artifacts[1], row, "srv-a")
        let key = try #require(draft?.key)
        actions.confirmApply()
        #expect(draft == nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(sent.count == 1)
        // A success stays beside its artifact; it does not leave after the dwell.
        #expect(results.results[key]?.message == "Applied to relay.")
        actions.confirmApply()
        try await Task.sleep(for: .milliseconds(20))
        #expect(sent.count == 1)

        // Another artifact fails: its own result, and the first one's is untouched.
        fails = true
        apply(0, artifacts[0], row, "srv-a")
        let other = try #require(draft?.key)
        actions.confirmApply()
        try await Task.sleep(for: .milliseconds(40))
        #expect(results.results[other]?.reason == "Couldn’t apply it. git apply failed.")
        #expect(results.results[key]?.isDone == true)

        let outcomes = NetworkApplyOutcome.list(for: "ho-1", on: "srv-a", artifacts: artifacts, results: results.results, running: [])
        #expect(outcomes.map(\.index) == [0, 1])
        #expect(outcomes[0].state == .failed("Couldn’t apply it. git apply failed.") && outcomes[0].word == "Not applied")
        #expect(outcomes[1].state == .done("Applied to relay.") && outcomes[1].lamp == .on)
        let running = NetworkApplyOutcome.list(for: "ho-1", on: "srv-a", artifacts: artifacts, results: [:], running: [key])
        #expect(running.map(\.state) == [.running])
    }

    /// Without the boundary's apply, the page leaves Apply to the network panel.
    @Test func applyStaysWithThePanelWhereTheBoundaryHasNone() {
        var actions = NetworkPagesActions()
        actions.bindApply(NetworkPageActions(), results: NetworkRowResults(), draft: { nil }, setDraft: { _ in }, row: { _ in nil })
        #expect(actions.apply == nil)
    }
}
