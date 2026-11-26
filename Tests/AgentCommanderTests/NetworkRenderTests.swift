import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of the nine network pages, drawn from the design-preview samples. Skipped
// unless NETWORK_RENDER_DIR names a folder for the PNG files:
//
//     NETWORK_RENDER_DIR=design/demos/main-window-3 swift test --filter NetworkRender
//
// Each picture is a whole window at 1440 x 900 points and one pixel per point, in the console
// theme, with one black-glass check. Nothing here opens a window on screen, touches the running
// app or reads the network model.

let networkRenderDirectory = ProcessInfo.processInfo.environment["NETWORK_RENDER_DIR"]

@MainActor @Suite struct NetworkRenderTests {
    static let scenarios: [(DesignPreviewScenario, String)] = [
        (.networkServers, "network-servers"), (.networkDirectory, "network-directory"), (.networkApprovals, "network-approvals"),
        (.networkHandoffs, "network-handoffs"), (.networkThreads, "network-threads"), (.networkAudit, "network-audit"),
        (.networkFanout, "network-fanout"), (.networkShared, "network-shared"), (.people, "people")
    ]

    @Test func everyNetworkScenarioOpensOnItsPlace() {
        #expect(Self.scenarios.map { $0.0.networkPlace } == NetworkPlace.all.map(Optional.some))
        #expect(Self.scenarios.allSatisfy { $0.0.rawValue == $0.1 && $0.0.isShell && ShellConcept(scenario: $0.0) == .modeRail })
    }

    /// The sample window: sidebar B on a network place, with that page's detail open.
    static func shell(_ scenario: DesignPreviewScenario, state: ShellPreviewState? = nil) -> some View {
        ShellPreviewPage(store: PreviewStore(scenario: scenario),
                         state: state ?? ShellPreviewState(selection: scenario.networkPlace ?? ""), chrome: .drawn)
    }

    @Test(.enabled(if: networkRenderDirectory != nil)) func drawsTheNetworkPages() async throws {
        let folder = URL(fileURLWithPath: try #require(networkRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (scenario, name) in Self.scenarios {
            try await ShellRenderTests.write(Self.shell(scenario), name, theme: .console, to: folder)
        }
        try await ShellRenderTests.write(Self.shell(.networkApprovals), "network-approvals", theme: .blackGlass, to: folder)

        // States a click reaches: the grant sheet opened by Review, a server's settings, the fan-out composer.
        let review = ShellPreviewState(selection: NetworkPlace.approvals)
        let pages = review.network.pages(go: { _ in })
        if let row = pages.content.accessRows.first(where: \.isIncoming) { pages.actions.reviewAccess(row.request, row.server) }
        try await ShellRenderTests.write(Self.shell(.networkApprovals, state: review), "network-approvals-grant", theme: .console, to: folder)

        let settings = ShellPreviewState(selection: NetworkPlace.servers)
        settings.network.pages(go: { _ in }).actions.openServer(NetworkSample.studio)
        try await ShellRenderTests.write(Self.shell(.networkServers, state: settings), "network-servers-settings", theme: .console, to: folder)

        let people = ShellPreviewState(selection: NetworkPlace.people)
        people.network.pages(go: { _ in }).actions.editProfile(NetworkSample.studio)
        try await ShellRenderTests.write(Self.shell(.people, state: people), "people-profile", theme: .console, to: folder)

        // The live window with the same pages, as the cockpit draws them.
        let live = ShellPreviewState(selection: NetworkPlace.handoffs)
        let store = PreviewStore(scenario: .coordinatorWall)
        store.ui.shellPlace = NetworkPlace.handoffs
        let cockpit = CockpitScreen(
            content: DesignFixture.content(for: store), ui: store.ui, actions: DesignFixture.actions(for: store),
            shell: ShellContext(network: ShellLiveTests.network, chrome: .drawn, now: ShellLiveTests.now,
                                networkPage: { place, go in AnyView(NetworkPageView(place: place, pages: live.network.pages(go: go))) }))
        try await ShellRenderTests.write(cockpit, "live-network-handoffs", theme: .console, to: folder)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("people-console.png").path))
    }
}
