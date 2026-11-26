import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of live work on the wall, drawn from the cockpit fixture and the wall's
// sample values. Skipped unless WALL_RENDER_DIR names a folder for the PNG files:
//
//     WALL_RENDER_DIR=design/demos/main-window-4 swift test --filter WallRender
//
// Each picture is a whole window at 1440 x 900 points and one pixel per point. Nothing here opens
// a window on screen, touches the running app or reads the network model.

let wallRenderDirectory = ProcessInfo.processInfo.environment["WALL_RENDER_DIR"]

@MainActor @Suite struct WallRenderTests {
    /// The live cockpit on the wall, with the sample live work. `zoomed` zooms a remote worker.
    /// The tray's countdown runs against the real clock, so the sample hold is timed from now.
    static func sample() -> WallLiveWork {
        var wall = WallSample.work(now: ShellLiveTests.now)
        wall.now = Date()
        wall.controls = WallSample.work(now: wall.now).controls
        return wall
    }

    static func cockpit(zoomed: String? = nil, wall: WallLiveWork = WallRenderTests.sample()) -> some View {
        let store = PreviewStore(scenario: .coordinatorWall)
        store.ui.shellPlace = LiveShell.wall
        store.ui.zoomedRemoteWorkerID = zoomed
        var actions = WallLiveWorkActions()
        actions.zoom = { id, _ in WallSample.zoom(id, now: ShellLiveTests.now) }
        return CockpitScreen(content: DesignFixture.content(for: store), ui: store.ui, actions: DesignFixture.actions(for: store),
                             shell: ShellContext(network: ShellLiveTests.network, chrome: .drawn, now: ShellLiveTests.now,
                                                 wall: wall, wallActions: actions))
    }

    /// Hand-offs with the sample result open and one artifact waiting for its confirmation.
    static func applyConfirmation(applied: Bool) -> some View {
        let state = ShellPreviewState(selection: NetworkPlace.handoffs)
        let pages = state.network.pages(go: { _ in })
        if let row = pages.content.server(NetworkSample.studio)?.handoffs.first(where: { $0.request == "ho-1" }),
           let artifacts = pages.content.reports["ho-1"]?.artifacts {
            pages.actions.apply?(1, artifacts[1], row, NetworkSample.studio)
            if applied { state.network.latency = .zero; state.network.pages(go: { _ in }).actions.confirmApply() }
        }
        return ShellPreviewPage(store: PreviewStore(scenario: .networkHandoffs), state: state, chrome: .drawn)
    }

    @Test func theCockpitDrawsTheWallFromValues() {
        // The render's wall has something to show in each part.
        let wall = WallSample.work(now: ShellLiveTests.now)
        #expect(!wall.remoteWorkers.isEmpty && !wall.work.isEmpty && !wall.controls.isEmpty && !wall.suggestions.isEmpty)
    }

    @Test(.enabled(if: wallRenderDirectory != nil)) func drawsLiveWorkOnTheWall() async throws {
        let folder = URL(fileURLWithPath: try #require(wallRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for theme in [Theme.console, Theme.blackGlass] {
            try await ShellRenderTests.write(Self.cockpit(), "wall-live-work", theme: theme, to: folder)
        }
        // Only a held worker and a suggestion: no remote work.
        var held = Self.sample()
        held.remoteWorkers = []
        held.work = []
        try await ShellRenderTests.write(Self.cockpit(wall: held), "wall-held-by-friend", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(zoomed: "\(WallSample.studio)/ho-1"), "wall-remote-zoom", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(zoomed: "\(WallSample.studio)/ho-1"), "wall-remote-zoom", theme: .blackGlass, to: folder)
        try await ShellRenderTests.write(Self.applyConfirmation(applied: false), "handoffs-apply-confirm", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.applyConfirmation(applied: false), "handoffs-apply-confirm", theme: .blackGlass, to: folder)
        try await ShellRenderTests.write(Self.applyConfirmation(applied: true), "handoffs-apply-result", theme: .console, to: folder)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("wall-live-work-console.png").path))
    }
}
