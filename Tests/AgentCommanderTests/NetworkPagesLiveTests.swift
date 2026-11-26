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
