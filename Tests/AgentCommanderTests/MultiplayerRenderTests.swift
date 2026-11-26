import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of the tray, drawn from the review fixture. Skipped unless
// MULTIPLAYER_RENDER_DIR names a folder to write PNG files into:
//
//     MULTIPLAYER_RENDER_DIR=/tmp/tray swift test --filter MultiplayerRender
//
// Nothing here opens a window on screen, touches the running app or reaches a network.

let multiplayerRenderDirectory = ProcessInfo.processInfo.environment["MULTIPLAYER_RENDER_DIR"]

@MainActor @Suite struct MultiplayerRenderTests {

    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/commander-network-fixture.py")
    }

    /// Draws the panel as it stands, at its full height, into one PNG.
    static func write(_ model: MultiplayerModel, _ name: String, to folder: URL) async throws {
        MultiplayerLayout.bodyHeightOverride = 2400
        defer { MultiplayerLayout.bodyHeightOverride = nil }
        let host = NSHostingView(rootView: MultiplayerPanel(model: model).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: MultiplayerLayout.width, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            try await Task.sleep(for: .milliseconds(120))
        }
        await model.settle()
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        try await Task.sleep(for: .milliseconds(200))
        let bounds = host.bounds
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }

    @Test(.enabled(if: multiplayerRenderDirectory != nil)) func drawsEveryTabAndTheSharePages() async throws {
        let folder = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = folder.appendingPathComponent("fixture-state.json")
        try? FileManager.default.removeItem(at: state)
        setenv("COMMANDER_NETWORK_FIXTURE_STATE", state.path, 1)
        _ = NSApplication.shared

        // The fan-out's winner goes to a scratch file, not to anyone's preferences or app folder.
        let winners = MultiplayerWinnerStore.scratch()
        let model = MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: Self.fixture)),
                                     usesFixtureHelper: true, steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     winners: winners)
        model.open()
        await model.settle()
        model.refresh()
        await model.settle()
        #expect(model.servers.count == 3)

        for tab in MultiplayerTrayTab.allCases {
            model.tab = tab
            try await Self.write(model, "tab-\(tab.rawValue)", to: folder)
        }
        let home = "s-fixture-home"
        let share = model.share
        let live = model.share.live
        let teams = model.share.teams
        let pages: [(String, () -> Void)] = [
            // Live work (increment 4).
            ("suggestion", { share.open(.approval("ap-3"), on: home) }),
            ("watch", {
                live.startWatch("dir-sam-agent", on: home)
                live.suggestDraft = "Pin the lease clock instead of sleeping."
            }),
            ("handover", { live.startControl("res-2", on: home) }),
            ("review-request", {
                live.startReview("dir-sam-agent", on: home)
                live.reviewDraft.title = "Wait for lease renewal before dropping the link"
                live.reviewDraft.pr = "https://github.com/example/relay/pull/212"
                live.reviewDraft.diff = MultiplayerContextItem(name: "reconnect-wait.diff", content: String(repeating: "x", count: 6_200))
            }),
            ("review", { live.openReview("rq-review-1", on: home) }),
            ("review-post", {
                live.openReview("rq-review-1", on: home)
                live.postDraft = "https://github.com/example/relay/pull/212"
                live.askPost()
            }),
            ("fanout", {
                live.startFanout(on: home)
                live.fanoutDraft.prompt = "Where should the retry budget live: the client or the relay? Answer in two sentences."
            }),
            ("fanout-compare", {
                share.open(.compare(request: "rq-fanout-1"), on: home)
                live.chooseWinner("c-fan-2", of: "rq-fanout-1", on: home)
            }),
            ("approval", { share.open(.approval("ap-1"), on: home) }),
            ("directory", { share.open(.directory, on: home) }),
            ("grant-sheet", {
                share.startGrant(on: home, handle: "fixture-sam", resourceID: "res-2")
                share.toggleGrantAction("agent.handoff")
            }),
            ("access-requests", { share.open(.requests, on: home) }),
            ("consult", {
                share.startConsult("dir-sam-agent", on: home)
                share.consultDraft.prompt = "Why does the reconnect test flake on CI but pass locally?"
                share.consultDraft.context = [MultiplayerContextItem(name: "ci-run-4127.log", content: String(repeating: "x", count: 18_400))]
            }),
            ("handoff", { share.startHandoff("dir-sam-agent", on: home) }),
            ("handoffs", { share.open(.handoffs, on: home) }),
            ("thread", { share.open(.thread(request: "rq-handoff-1", title: "Fix flaky reconnect test"), on: home) }),
            ("audit", { share.open(.audit(resource: ""), on: home) }),
            ("server", { model.openServer(home) }),
            // Teams (increment 5).
            ("groups", { share.open(.groups, on: home); teams.groupDraft = "release-crew" }),
            ("group", { share.open(.group("grp-relay"), on: home) }),
            ("group-delete", { share.open(.group("grp-relay"), on: home); teams.ask(.deleteGroup("grp-relay")) }),
            ("group-member", { share.open(.group("grp-ios"), on: home) }),
            ("grant-sheet-group", {
                share.startGrant(on: home, group: "grp-relay", resourceID: "res-2")
                share.toggleGrantAction("agent.ask")
            }),
            ("workspaces", { share.open(.workspaces, on: home) }),
            ("workspace-new", {
                teams.startWorkspace(on: home)
                teams.workspaceDraft.group = "grp-relay"
                teams.workspaceDraft.name = "Avatar uploads"
                teams.workspaceDraft.goal = "Retry failed avatar uploads without duplicating them."
                teams.workspaceDraft.repository = "github.com/example/relay"
            }),
            ("workspace", { share.open(.workspace("ws-relay"), on: home) }),
            ("workspace-pull-requests", { share.open(.workspace("ws-ios"), on: home) }),
            ("claim", {
                teams.startClaim(in: "ws-relay", on: home)
                teams.claimDraft.kind = .paths
                teams.claimDraft.key = "Sources/Relay/Queue.swift, docs"
            }),
            ("queue-add", {
                teams.startQueueAdd(for: "ws-relay", on: home)
                teams.queueDraft.branch = "collab/deadline"
            }),
            ("hosts", { share.open(.hosts, on: home) }),
            ("knowledge", { share.open(.knowledge, on: home) }),
            ("knowledge-share-secret", {
                teams.startKnowledge(on: home)
                teams.knowledgeDraft.kind = .mcp
                teams.knowledgeDraft.name = "github-issues"
                teams.knowledgeDraft.content = "{\n  \"env\": {\"GITHUB_TOKEN\": \"ghp_abcdefghijklmnopqrstuvwxyz0123\"}\n}"
                teams.knowledgeDraft.scope = .group
                teams.knowledgeDraft.target = "grp-relay"
            }),
            ("knowledge-item", { share.open(.knowledgeItem("kn-skill"), on: home) }),
            ("knowledge-item-mcp", { share.open(.knowledgeItem("kn-mcp"), on: home) }),
            ("reputation", { teams.startReputation("dir-sam-agent", on: home); teams.endorseDraft = "code review" }),
            ("reputation-hidden", { teams.startReputation("dir-mei-gpu", on: home) }),
            ("directory-search", {
                teams.startSearch(on: home)
                teams.searchDraft = "ios"
                teams.runSearch(on: home)
            }),
            ("policy", { share.open(.policy, on: home) }),
        ]
        for (name, open) in pages {
            model.go(.home)
            open()
            await model.settle()
            try await Self.write(model, name, to: folder)
        }
        // A hand-off with its result read: the report and the artifacts.
        model.go(.home)
        share.open(.handoffDetail(request: "rq-handoff-1"), on: home)
        if let row = share.handoff("rq-handoff-1", on: home) { await share.check(row, on: home, result: true)?.value }
        try await Self.write(model, "handoff-result", to: folder)
        // Teams pages that show what an action brought back.
        model.go(.home)
        share.open(.workspace("ws-relay"), on: home)
        await model.settle()
        if let card = teams.card("card-2") { teams.openCard(card, in: "ws-relay", on: home) }
        teams.resultDraft = "Waiters are keyed by lease ID. Branch `collab/lease-waiters`, 212 tests pass."
        try await Self.write(model, "card", to: folder)
        model.go(.home)
        teams.startHostRun("dir-jonas-mini", on: home)
        teams.hostDraft.command = "run-ios-ui-tests"
        await teams.runOnHost("dir-jonas-mini", on: home)?.value
        try await Self.write(model, "host-run", to: folder)
        teams.hostDraft.argumentText = "--fail-fast"
        await teams.runOnHost("dir-jonas-mini", on: home)?.value
        try await Self.write(model, "host-run-failed", to: folder)
        model.go(.home)
        share.open(.policy, on: home)
        await model.settle()
        teams.policyDraft.member = "fixture-noor"
        teams.policyDraft.directory = false
        teams.ask(.suspend("fixture-noor"))
        try await Self.write(model, "policy-suspend", to: folder)
        model.go(.home)
        share.open(.workspace("ws-relay"), on: home)
        await model.settle()
        await teams.runQueue("ws-relay", on: home)?.value
        try await Self.write(model, "workspace-queue-merged", to: folder)
        // A pull-request workspace with none open, then with `gh` signed out.
        for (mode, name) in [("empty", "workspace-pull-requests-empty"), ("fail", "workspace-pull-requests-failed")] {
            setenv("COMMANDER_NETWORK_FIXTURE_PRS", mode, 1)
            model.go(.home)
            share.open(.workspace("ws-ios"), on: home)
            await model.settle()
            try await Self.write(model, name, to: folder)
        }
        unsetenv("COMMANDER_NETWORK_FIXTURE_PRS")
        model.close()
        try? FileManager.default.removeItem(at: winners.file)
    }

    /// Draws one view at the tray's width and its own height into a PNG.
    static func write<Content: View>(view: Content, _ name: String, to folder: URL, settling model: MultiplayerModel) async throws {
        let host = NSHostingView(rootView: view.frame(width: MultiplayerLayout.width).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: MultiplayerLayout.width, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            try await Task.sleep(for: .milliseconds(120))
            await model.settle()
        }
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        try await Task.sleep(for: .milliseconds(200))
        let bounds = host.bounds
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }

    /// The composers as a view outside the tray hosts them, each at its full height (`scrolls: false`).
    @Test(.enabled(if: multiplayerRenderDirectory != nil)) func drawsTheHostedComposers() async throws {
        let folder = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = folder.appendingPathComponent("fixture-state-hosts.json")
        try? FileManager.default.removeItem(at: state)
        setenv("COMMANDER_NETWORK_FIXTURE_STATE", state.path, 1)
        _ = NSApplication.shared
        let model = MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: Self.fixture)),
                                     usesFixtureHelper: true, steadyPoll: .seconds(3600), fastPoll: .seconds(3600))
        model.open()
        await model.settle()
        model.refresh()
        await model.settle()
        let home = "s-fixture-home", agent = "dir-sam-agent"
        let cancel = {}, finish: (MultiplayerActionResult) -> Void = { _ in }
        model.share.prepareGrant(on: home)
        let hosts: [(String, AnyView)] = [
            ("host-grant", AnyView(MultiplayerGrantHost(model: model, scrolls: false, onCancel: cancel, onFinish: finish))),
            ("host-consult", AnyView(MultiplayerConsultHost(model: model, server: home, resource: agent, scrolls: false,
                                                            onCancel: cancel, onFinish: finish, onThread: { _ in }))),
            ("host-handoff", AnyView(MultiplayerHandoffHost(model: model, server: home, resource: agent, scrolls: false,
                                                            onCancel: cancel, onFinish: finish))),
            ("host-review-request", AnyView(MultiplayerReviewRequestHost(model: model, server: home, resource: agent, scrolls: false,
                                                                         onCancel: cancel, onFinish: finish))),
            ("host-watch", AnyView(MultiplayerWatchHost(model: model, server: home, resource: agent, scrolls: false,
                                                        onCancel: cancel, onFinish: finish))),
            ("host-add-friend", AnyView(MultiplayerAddFriendHost(model: model, server: home, scrolls: false, onCancel: cancel, onFinish: finish))),
            ("host-invite", AnyView(MultiplayerInviteHost(model: model, server: home, scrolls: false, onCancel: cancel, onFinish: finish))),
            ("host-membership", AnyView(MultiplayerMembershipHost(model: model, server: home, scrolls: false, onCancel: cancel, onFinish: finish))),
            ("host-add-server", AnyView(MultiplayerAddServerHost(model: model, scrolls: false, onCancel: cancel, onFinish: finish,
                                                                 onOpenExisting: { _ in }))),
        ]
        for (name, host) in hosts { try await Self.write(view: host, name, to: folder, settling: model) }
        // Hosting every composer left the tray where it was.
        #expect(model.route == .home)
        model.close()
    }
}
