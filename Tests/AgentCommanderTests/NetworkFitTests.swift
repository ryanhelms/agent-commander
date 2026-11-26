import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The network pages fit the window at its default size, 1280 x 800: nothing asks for more width
// than the window has, so the rail stays on screen and every action can be reached.
//
//     NETWORK_FIT_RENDER_DIR=design/demos/main-window-4 swift test --filter NetworkFit
//
// writes each page at 1280 x 800 as `fit-1280-<page>-console.png`.

let networkFitRenderDirectory = ProcessInfo.processInfo.environment["NETWORK_FIT_RENDER_DIR"]

@MainActor @Suite struct NetworkFitTests {
    /// The window's default and smallest content size.
    static let window = CGSize(width: 1280, height: 800)

    /// The width a view takes when it is offered the window: more than the window when it can't shrink to it.
    static func leastWidth(_ view: some View) -> CGFloat {
        let host = NSHostingController(rootView: view.environment(\.theme, .console).environment(\.reduceTransparencyOverride, true)
            // Without the sideways scroll, a page that can't shrink to the window asks for more.
            .environment(\.networkPageScrollsSideways, false))
        return host.sizeThatFits(in: window).width
    }

    /// The states the running-window check found too wide, and the rest of the pages.
    static func states() -> [(name: String, scenario: DesignPreviewScenario, state: ShellPreviewState)] {
        var all: [(String, DesignPreviewScenario, ShellPreviewState)] = NetworkRenderTests.scenarios.map { scenario, name in
            (name, scenario, ShellPreviewState(selection: scenario.networkPlace ?? ""))
        }
        let grant = ShellPreviewState(selection: NetworkPlace.approvals)
        let pages = grant.network.pages(go: { _ in })
        if let row = pages.content.accessRows.first(where: \.isIncoming) { pages.actions.reviewAccess(row.request, row.server) }
        all.append(("network-approvals-grant", .networkApprovals, grant))
        let settings = ShellPreviewState(selection: NetworkPlace.servers)
        settings.network.pages(go: { _ in }).actions.openServer(NetworkSample.studio)
        all.append(("network-servers-settings", .networkServers, settings))
        return all
    }

    @Test func everyNetworkPageFitsTheDefaultWindow() {
        _ = NSApplication.shared
        for (name, scenario, state) in Self.states() {
            let width = Self.leastWidth(NetworkRenderTests.shell(scenario, state: state))
            #expect(width <= Self.window.width, "\(name) asks for \(width) pt")
        }
    }

    @Test(.enabled(if: networkFitRenderDirectory != nil)) func drawsThePagesAtTheDefaultWindowSize() async throws {
        let folder = URL(fileURLWithPath: try #require(networkFitRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (name, scenario, state) in Self.states() {
            try await ShellRenderTests.write(NetworkRenderTests.shell(scenario, state: state), "fit-1280-\(name)", theme: .console,
                                             to: folder, size: Self.window)
        }
    }
}
