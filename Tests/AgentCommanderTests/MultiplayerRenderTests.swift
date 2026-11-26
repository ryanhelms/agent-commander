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

        // The fan-out's winner goes to a scratch domain, not to anyone's preferences.
        let suite = "multiplayer-render"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let model = MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: Self.fixture)),
                                     usesFixtureHelper: true, steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     defaults: defaults)
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
                live.chooseWinner("c-fan-2", of: "rq-fanout-1")
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
        model.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
