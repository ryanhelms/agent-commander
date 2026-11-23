import AppKit
import SwiftUI

@main
struct AgentCommander: App {
    @State private var model = CockpitModel()

    var body: some Scene {
        Window("Agent Commander", id: "cockpit") {
            Group {
                // A design-preview launch renders a fixture page and never starts the live subscription.
                if let scenario = DesignPreviewScenario.requested {
                    DesignPreviewPage(scenario: scenario)
                } else {
                    CockpitView(model: model)
                }
            }
            .frame(minWidth: 800, minHeight: 540)
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 800)
        // Unified (not compact) keeps the real title bar and traffic lights on the 52 pt chrome band.
        .windowToolbarStyle(.unified)
    }
}
