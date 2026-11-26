import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The live network pages own what they show. Opening a page, reading a thread or the audit log,
// posting, and revoking go through the network model's calls that name their target, and none of
// them moves the tray's route. Run against the network fixture, each test with a state file of its own.
//
//     NETWORK_LIVE_RENDER_DIR=design/demos/main-window-4 swift test --filter NetworkPagesLive
//
// also writes the pages with a hosted composer open, at 1280 x 800.

let networkLiveRenderDirectory = ProcessInfo.processInfo.environment["NETWORK_LIVE_RENDER_DIR"]

@MainActor @Suite(.serialized) struct NetworkPagesLiveTests {
    static let home = MultiplayerFixesTests.home

    static func pages(_ model: MultiplayerModel, _ state: NetworkPagesLiveState) -> (intents: LiveNetworkIntents, actions: NetworkPagesActions) {
        let intents = LiveNetworkIntents(model: model, state: state, go: { _ in })
        return (intents, intents.actions(openPanel: nil))
    }

    /// Waits until a read or an action the page started has ended.
    static func settle(_ model: MultiplayerModel, until done: @MainActor () -> Bool) async {
        for _ in 0..<200 where !done() || model.isBusy { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func openingAndReadingNeverMovesTheTray() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-read")
        defer { model.close() }
        let state = NetworkPagesLiveState()
        let (intents, actions) = Self.pages(model, state)
        // The tray is on a form the person is filling in.
        model.startAddServer()
        let tray = model.route

        let handoff = try #require(model.share.allHandoffs.first)
        actions.openHandoff(handoff.item.request, handoff.server)
        #expect(state.route == .share(handoff.server, .handoffDetail(request: handoff.item.request)))

        actions.openThread(handoff.item.request, handoff.item.title, handoff.server)
        #expect(state.thread == .loading)
        await Self.settle(model) { state.thread != .loading }
        #expect(state.thread.value != nil)

        actions.openAudit("", Self.home)
        await Self.settle(model) { state.audit != .loading }
        #expect(state.audit.value != nil)

        intents.openServer(Self.home)
        #expect(state.route == .server(Self.home) && state.nickname == model.server(Self.home)?.name)
        actions.openApproval("ap-3", Self.home)
        actions.close()
        #expect(state.route == .home)

        // The page's content is the window's own route, and the tray never moved.
        let content = NetworkPagesContent(model: model, state: state)
        #expect(content.route == .home && content.audit == state.audit)
        #expect(model.route == tray)
    }

    @Test func aCommentIsPostedToTheThreadTheWindowHasOpen() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-comment")
        defer { model.close() }
        let state = NetworkPagesLiveState()
        let (_, actions) = Self.pages(model, state)
        let tray = model.route
        let handoff = try #require(model.share.allHandoffs.first)
        actions.openThread(handoff.item.request, handoff.item.title, handoff.server)
        await Self.settle(model) { state.thread != .loading }
        let before = try #require(state.thread.value).comments.count

        state.comment = "Checked from the main window."
        #expect(NetworkPagesContent(model: model, state: state).canComment)
        actions.postComment()
        await Self.settle(model) { state.comment.isEmpty && (state.thread.value?.comments.count ?? 0) > before }
        #expect(state.comment.isEmpty)
        #expect(state.thread.value?.comments.count == before + 1)
        #expect(model.route == tray)
    }

    @Test func threadsListsWhatTheNetworkSaysYouTakePartIn() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-threads")
        defer { model.close() }
        let state = NetworkPagesLiveState()
        let (intents, _) = Self.pages(model, state)
        // Before the read, the list is built from the requests the model already holds.
        #expect(NetworkPagesContent(model: model, state: state).threads == nil)
        intents.readThreads()
        await Self.settle(model) { state.threads != nil }
        let listed = try #require(state.threads?[Self.home])
        let rows = NetworkPagesContent(model: model, state: state).threadRows
        #expect(!listed.isEmpty && !rows.isEmpty)
        // Received requests and consults are there, which the model's own lists never held.
        #expect(rows.contains { $0.kind == .received } == listed.contains { $0.direction == .received })
        #expect(rows.allSatisfy { !$0.request.isEmpty && !$0.title.isEmpty })
    }

    /// A row that was answered stays for a moment with its outcome, and is no longer counted.
    @Test func anAnsweredApprovalShowsItsOutcomeAndLeavesTheCount() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-answer")
        defer { model.close() }
        let state = NetworkPagesLiveState()
        let waiting = model.share.waitingApprovals.count
        let pending = try #require(model.share.waitingApprovals.first)
        #expect(ShellNetwork(model: model).waitingApprovals.count == waiting)
        _ = await model.decide(pending.item, on: pending.server, approve: false)
        let content = NetworkPagesContent(model: model, state: state)
        let key = NetworkActionResult.key(.approval, pending.item.id, on: pending.server)
        if let row = content.approvalRows.first(where: { $0.approval.id == pending.item.id }) {
            // Held: the row says how it came out.
            #expect(row.answer == .denied && content.answered[key] == .denied)
        }
        #expect(ShellNetwork(model: model).waitingApprovals.count == waiting - 1)
        #expect(content.readouts(for: NetworkPlace.approvals).first { $0.id == "approvals" }?.value == "\(waiting - 1)")
    }

    /// The model takes one action at a time. Two answers pressed together both go through: the
    /// second waits its turn instead of being refused.
    @Test func aSecondAnswerWaitsItsTurn() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-queue")
        defer { model.close() }
        let approval = try #require(model.share.waitingApprovals.first)
        let friend = try #require(ShellNetwork(model: model).friendRequests.first)

        // Sent straight to the model, the second is refused while the first runs.
        let actions = NetworkPageActions.live(model, queue: NetworkAnswerQueue())
        let first = Task { @MainActor in await actions.decide(approval.item, approval.server, true) }
        let second = Task { @MainActor in await actions.acceptFriend(friend.request, friend.server) }
        let results = [await first.value, await second.value]
        let refused = results.compactMap { $0.reason }
        #expect(refused.isEmpty, "\(refused)")
        #expect(results.count == 2 && model.share.waitingApprovals.contains { $0.id == approval.id } == false)
    }

    /// An answer that can't get its turn is sent anyway, and the model's own sentence says why.
    @Test func anAnswerThatCannotWaitSaysWhy() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-queue-busy")
        defer { model.close() }
        let queue = NetworkAnswerQueue()
        queue.patience = .milliseconds(1)
        var sent = 0
        let result = await queue.send(on: model) {
            sent += 1
            return .failed(id: "ap", server: Self.home, reason: model.notSent("Couldn’t deny the request."))
        }
        #expect(sent == 1 && result.reason?.hasPrefix("Couldn’t deny the request.") == true)
    }

    @Test func aGrantIsRevokedByValueAndTheRowSaysHowItEnded() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-revoke")
        defer { model.close() }
        let state = NetworkPagesLiveState()
        let (_, actions) = Self.pages(model, state)
        let tray = model.route
        let grants = try #require(model.session(Self.home)?.status?.grants)
        let grant = try #require(grants.first)
        let revoke = try #require(actions.revoke)
        revoke(grant, Self.home)
        let key = NetworkActionResult.key(.grant, grant.id, on: Self.home)
        await Self.settle(model) { !state.results.running.contains(key) }
        #expect(state.results.results[key]?.isDone == true)
        await Self.settle(model) { model.session(Self.home)?.status?.grants.contains { $0.id == grant.id } == false }
        #expect(model.session(Self.home)?.status?.grants.contains { $0.id == grant.id } == false)
        #expect(model.route == tray)
    }

    @Test func composersOpenOnThePageAndTheFanoutDraftIsTheWindowsOwn() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-compose")
        defer { model.close() }
        let state = NetworkPagesLiveState()
        let (_, actions) = Self.pages(model, state)
        let tray = model.route
        let entry = try #require(model.session(Self.home)?.status?.directoryEntries.first { $0.canConsult })

        let consult = try #require(actions.consult), addServer = try #require(actions.addServer), addFriend = try #require(actions.addFriend)
        consult(entry, Self.home)
        #expect(state.selection.composer == .consult(server: Self.home, resource: entry.id))
        addServer()
        #expect(state.selection.composer == .addServer)
        addFriend(Self.home)
        #expect(state.selection.composer == .addFriend(server: Self.home) && state.selection.composer?.server == Self.home)
        actions.closeComposer()
        #expect(state.selection.composer == nil)

        actions.startFanout(Self.home)
        #expect(state.route == .share(Self.home, .fanout))
        let first = try #require(model.share.live.fanoutTargets(on: Self.home).first)
        let had = state.fanout.targets.contains(first.id)
        actions.toggleFanoutTarget(first.id)
        #expect(state.fanout.targets.contains(first.id) != had)
        // Nothing of the tray's own drafts or route was touched.
        #expect(model.share.live.fanoutDraft == MultiplayerFanoutDraft())
        #expect(model.route == tray)
    }

    @Test(.enabled(if: networkLiveRenderDirectory != nil)) func drawsHostedComposersAtTheDefaultWindowSize() async throws {
        let folder = URL(fileURLWithPath: try #require(networkLiveRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-render")
        defer { model.close() }
        func page(_ place: String, _ state: NetworkPagesLiveState) -> some View {
            ThemeCanvas { LiveNetworkPage(place: place, model: model, state: state, go: { _ in }, openPanel: nil) }
        }
        let size = NetworkFitTests.window

        let consult = NetworkPagesLiveState()
        if let entry = model.session(Self.home)?.status?.directoryEntries.first(where: \.canConsult) {
            consult.selection.composer = .consult(server: Self.home, resource: entry.id)
        }
        try await ShellRenderTests.write(page(NetworkPlace.directory, consult), "live-directory-consult", theme: .console, to: folder, size: size)

        let add = NetworkPagesLiveState()
        add.selection.composer = .addServer
        try await ShellRenderTests.write(page(NetworkPlace.servers, add), "live-servers-add-server", theme: .console, to: folder, size: size)

        let shared = NetworkPagesLiveState()
        if let resource = model.session(Self.home)?.status?.resources.first(where: { resource in
            model.session(Self.home)?.status?.grants.contains { $0.resource == resource.id } == true
        }), let grant = model.session(Self.home)?.status?.grants.first(where: { $0.resource == resource.id }) {
            shared.selection.shared = "\(Self.home)/\(resource.id)"
            shared.selection.revoking = "\(Self.home)/\(grant.id)"
        }
        try await ShellRenderTests.write(page(NetworkPlace.shared, shared), "live-shared-revoke", theme: .console, to: folder, size: size)

        let grant = NetworkPagesLiveState()
        if let friend = model.session(Self.home)?.status?.friends.first,
           model.share.prepareGrant(on: Self.home, handle: friend.handle, resourceID: nil, actions: []) {
            grant.selection.grant = Self.home
        }
        try await ShellRenderTests.write(page(NetworkPlace.shared, grant), "live-shared-grant", theme: .console, to: folder, size: size)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("live-directory-consult-console.png").path))
    }
}
