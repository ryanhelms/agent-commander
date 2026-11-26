import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of the tray, drawn from the review fixture. Skipped unless
// MULTIPLAYER_RENDER_DIR names a folder to write PNG files into:
//
//     MULTIPLAYER_RENDER_DIR=/tmp/tray swift test --filter MultiplayerRender
//
// Every picture is drawn twice: in the console theme into the folder itself, and in black glass
// into its `black-glass` subfolder. The clock stands still (`fixedNow`), for the fixture, the model
// and every countdown, so a picture is the same on every run.
//
// Nothing here opens a window on screen, touches the running app or reaches a network.

let multiplayerRenderDirectory = ProcessInfo.processInfo.environment["MULTIPLAYER_RENDER_DIR"]

@MainActor @Suite(.serialized) struct MultiplayerRenderTests {

    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/commander-network-fixture.py")
    }

    /// The instant every picture is drawn at: 28 May 2026, 12:00 UTC.
    static let fixedNow = Date(timeIntervalSince1970: 1_779_969_600)

    /// The themes drawn, each with the folder under the render folder its pictures go to.
    static let themes: [(theme: Theme, folder: String?)] = [(.console, nil), (.blackGlass, "black-glass")]

    /// A model on the review fixture with the clock standing still, and a fresh fixture state.
    static func fixtureModel(state: URL, winners: MultiplayerWinnerStore = .scratch()) -> MultiplayerModel {
        try? FileManager.default.removeItem(at: state)
        setenv("COMMANDER_NETWORK_FIXTURE_STATE", state.path, 1)
        setenv("COMMANDER_NETWORK_FIXTURE_NOW", String(Int(fixedNow.timeIntervalSince1970)), 1)
        return MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: fixture)),
                                usesFixtureHelper: true, steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                winners: winners, now: { fixedNow })
    }

    /// Draws the panel as it stands, at its full height, into one PNG.
    static func write(_ model: MultiplayerModel, _ name: String, to folder: URL, theme: Theme = .console) async throws {
        MultiplayerLayout.bodyHeightOverride = 2400
        defer { MultiplayerLayout.bodyHeightOverride = nil }
        let host = NSHostingView(rootView: MultiplayerPanel(model: model, theme: theme)
            .environment(\.multiplayerFixedNow, fixedNow).preferredColorScheme(.dark))
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

    @Test(.enabled(if: multiplayerRenderDirectory != nil)) func drawsEveryTabAndTheTrayPages() async throws {
        let root = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        _ = NSApplication.shared
        for (theme, subfolder) in Self.themes {
            let folder = subfolder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await Self.drawPages(in: theme, to: folder)
        }
        unsetenv("COMMANDER_NETWORK_FIXTURE_NOW")
    }

    static func drawPages(in theme: Theme, to folder: URL) async throws {
        // The fan-out's winner goes to a scratch file, not to anyone's preferences or app folder.
        let winners = MultiplayerWinnerStore.scratch()
        let model = fixtureModel(state: folder.appendingPathComponent("fixture-state.json"), winners: winners)
        model.open()
        await model.settle()
        model.refresh()
        await model.settle()
        #expect(model.servers.count == 3)

        for tab in MultiplayerTrayTab.allCases {
            model.tab = tab
            try await Self.write(model, "tab-\(tab.rawValue)", to: folder, theme: theme)
        }
        let home = "s-fixture-home"
        let share = model.share
        let live = model.share.live
        let teams = model.share.teams
        // The pages the tray still draws, and some that are only a link now (DESIGN.md, "The triage tray").
        let pages: [(String, () -> Void)] = [
            // Live work (increment 4).
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
            ("grant-sheet", {
                share.startGrant(on: home, handle: "fixture-sam", resourceID: "res-2")
                share.toggleGrantAction("agent.handoff")
            }),
            ("consult", {
                share.startConsult("dir-sam-agent", on: home)
                share.consultDraft.prompt = "Why does the reconnect test flake on CI but pass locally?"
                share.consultDraft.context = [MultiplayerContextItem(name: "ci-run-4127.log", content: String(repeating: "x", count: 18_400))]
            }),
            ("handoff", { share.startHandoff("dir-sam-agent", on: home) }),
            // A page that moved to the main window: the open-in-window row alone.
            ("moved-handoffs", { share.open(.handoffs, on: home) }),
            ("moved-workspace", { share.open(.workspace("ws-relay"), on: home) }),
            ("moved-review", { live.openReview("rq-review-1", on: home) }),
            ("moved-policy", { share.open(.policy, on: home) }),
            ("server", { model.openServer(home) }),
            // Teams (increment 5).
            ("grant-sheet-group", {
                share.startGrant(on: home, group: "grp-relay", resourceID: "res-2")
                share.toggleGrantAction("agent.ask")
            }),
            ("workspace-new", {
                teams.startWorkspace(on: home)
                teams.workspaceDraft.group = "grp-relay"
                teams.workspaceDraft.name = "Avatar uploads"
                teams.workspaceDraft.goal = "Retry failed avatar uploads without duplicating them."
                teams.workspaceDraft.repository = "github.com/example/relay"
            }),
        ]
        for (name, open) in pages {
            model.go(.home)
            open()
            await model.settle()
            try await Self.write(model, name, to: folder, theme: theme)
        }
        model.close()
        try? FileManager.default.removeItem(at: winners.file)
    }

    /// Draws one view at the tray's width (or the width given) and its own height into a PNG, in
    /// the theme a window would give it.
    static func write<Content: View>(view: Content, _ name: String, to folder: URL, settling model: MultiplayerModel,
                                     theme: Theme = .console, width: CGFloat = MultiplayerLayout.width) async throws {
        let host = NSHostingView(rootView: view.frame(width: width).environment(\.theme, theme)
            .environment(\.multiplayerFixedNow, fixedNow).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 900),
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
        let root = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        _ = NSApplication.shared
        for (theme, subfolder) in Self.themes {
            let folder = subfolder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await Self.drawHosts(in: theme, to: folder)
        }
        unsetenv("COMMANDER_NETWORK_FIXTURE_NOW")
    }

    static func drawHosts(in theme: Theme, to folder: URL) async throws {
        let model = fixtureModel(state: folder.appendingPathComponent("fixture-state-hosts.json"))
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
        for (name, host) in hosts { try await Self.write(view: host, name, to: folder, settling: model, theme: theme) }
        // Hosting every composer left the tray where it was.
        #expect(model.route == .home)

        // What the main window composes from outside the tray: the wall's remote workers, the zoom,
        // the dock's holder row, and an answered row with its outcome. Each sits on the theme's canvas.
        let share = model.share, live = model.share.live, now = model.currentDate()
        let workers = share.remoteWorkers
        if !workers.isEmpty {
            try await Self.write(view: ThemeCanvas { RemoteWorkerGroup(workers: workers, now: now, onOpen: { _ in }, onOpenAll: {}).padding(12) },
                                 "wall-remote-group", to: folder, settling: model, theme: theme, width: 760)
        }
        if let worker = workers.first(where: \.canWatch) ?? workers.first {
            let entry = share.entry(worker.resource, on: worker.server)
            var watch = MultiplayerWatchState(server: worker.server, resource: worker.resource)
            if let page = try? await model.client?.scoped(to: worker.server).watch(resource: worker.resource, after: watch.cursor) {
                watch.take(page, at: now)
            }
            let zoom = RemoteWorkerZoom(worker: worker, watch: watch, entry: entry, color: MultiplayerTheme.swatch(for: worker.server),
                                        interval: 2, now: now, footerTitle: nil, allowsSuggestion: true,
                                        suggestion: .constant("Pin the lease clock instead of sleeping."),
                                        onSuggest: {}, onRetry: {}, onOpenTray: {})
            try await Self.write(view: ThemeCanvas { zoom.frame(height: 520).padding(12) }, "wall-remote-zoom", to: folder,
                                 settling: model, theme: theme, width: 560)
        }
        if let held = live.activeHandovers.first {
            let row = MultiplayerHolderRow(handover: held.item, resourceName: share.resourceName(held.item.resource, on: held.server),
                                           serverName: model.server(held.server)?.displayName,
                                           color: MultiplayerTheme.swatch(for: held.server), now: now, isBusy: false, onTakeBack: {})
            try await Self.write(view: ThemeCanvas { row.padding(12) }, "dock-holder-row", to: folder, settling: model, theme: theme)
        }
        let waiting = share.pendingApprovals
        if let first = waiting.first {
            let band = MultiplayerNeedsYou(groups: [], approvals: waiting, access: share.pendingAccess,
                                           serverName: { model.server($0)?.displayName ?? "a server" },
                                           resourceName: { share.resourceName($0, on: $1) }, isBusy: false, onAccept: { _, _ in },
                                           approvalAnswer: { $0.id == first.id ? .approved : nil },
                                           accessAnswer: { _ in .declined })
            try await Self.write(view: ThemeCanvas { band }, "needs-you-answered", to: folder, settling: model, theme: theme)
        }
        model.close()
    }
}
