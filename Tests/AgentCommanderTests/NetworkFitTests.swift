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

    /// The split puts the inspector beside the collection only when the collection's least width
    /// leaves the inspector at least the tray's own measure.
    @Test func theSplitStacksWhenTheCollectionCannotShrinkEnough() {
        let layout = NetworkSplitLayout()
        // Room to spare: the inspector at its full 420 pt.
        #expect(layout.arrangement(width: 1148, collectionMinimum: 600)
                == .init(beside: true, collection: 712, inspector: 420))    // 1148 - 16 - 420
        // Tight: the inspector narrows, but never under 400 pt.
        #expect(layout.arrangement(width: 1020, collectionMinimum: 600) == .init(beside: true, collection: 600, inspector: 404))
        // Too tight: the inspector goes under, and neither is wider than the page.
        let stacked = layout.arrangement(width: 988, collectionMinimum: 600)
        #expect(stacked == .init(beside: false, collection: 988, inspector: 540))
        #expect(layout.arrangement(width: 480, collectionMinimum: 600) == .init(beside: false, collection: 600, inspector: 480))
    }

    @Test func labelsSayTheTimeTheScreenShows() {
        #expect(NetworkSpoken.clock(waiting: 130, expiresIn: 252) == "4 minutes 12 seconds left")
        #expect(NetworkSpoken.clock(waiting: 130, expiresIn: nil) == "waiting 2 minutes 10 seconds")
        #expect(NetworkSpoken.clock(waiting: nil, expiresIn: nil) == nil)
        #expect(NetworkSpoken.duration(3_660) == "1 hour 1 minute" && NetworkSpoken.duration(7_200) == "2 hours")
        #expect(NetworkSpoken.duration(45) == "45 seconds" && NetworkSpoken.duration(1_260) == "21 minutes")
        #expect(NetworkSpoken.suffix(nil).isEmpty && NetworkSpoken.suffix("waiting 1 second") == ", waiting 1 second")
        #expect(MultiplayerPlural.count(1, "friend request") == "1 friend request")
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
