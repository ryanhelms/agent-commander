import AppKit
import SwiftUI

/// Process entry. Launch admission runs before the App value exists, so a launch handed to an open
/// cockpit, or refused because arbitration failed, exits before any model, window, menu bar item
/// or service starts.
@main
enum AgentCommanderMain {
    @MainActor static func main() {
        SingleInstanceLaunch.admit()
        AgentCommander.main()
    }
}

struct AgentCommander: App {
    @NSApplicationDelegateAdaptor(SingleInstanceAppDelegate.self) private var appDelegate
    @State private var model = CockpitModel()
    @State private var consoleModes = ConsoleModeStore()
    /// Inline native terminal status for every console. Design previews never attach.
    @State private var nativeTerminals = NativeTerminalLedger.forLaunch()
    /// Live network panel state, shared by the menu bar item and the review window.
    @State private var network = MultiplayerModel.shared

    var body: some Scene {
        Window("Agent Commander", id: SingleInstanceLaunch.cockpitSceneID) {
            Group {
                // AGENT_COMMANDER_NETWORK_PANEL=1 shows the same live network panel for review.
                if MultiplayerLaunch.showsPanelInWindow {
                    MultiplayerPanelStage(model: network)
                } else if let scenario = DesignPreviewScenario.requested {
                    // A design-preview launch renders a fixture page and never starts the live subscription.
                    DesignPreviewPage(scenario: scenario)
                } else {
                    CockpitView(model: model)
                }
            }
            .environment(consoleModes)
            .environment(model.toolDetails)
            .environment(model.compactions)
            .environment(model.replyAttachments)
            .environment(nativeTerminals)
            .appTheme()
            .frame(minWidth: 800, minHeight: 540)
            .preferredColorScheme(.dark)
            .singleInstanceCockpitScene()
        }
        .defaultSize(width: 1280, height: 800)
        // Unified (not compact) keeps the real title bar and traffic lights on the 52 pt chrome band.
        .windowToolbarStyle(.unified)
        // Agent Commander > Restart Agent Commander, above Quit.
        .commands { AppRestartCommands() }

        // Agent Commander > Settings… (⌘,) from the system command.
        Settings {
            SingleInstanceSettingsPage()
                .environment(model.toolDetails)
                .singleInstanceAuxiliaryScene()
        }

        // Read-only native terminal for one local worker, opened from its console's display menu.
        NativeTerminalScene(model: model)

        MenuBarExtra {
            MultiplayerPanel(model: network)
                .multiplayerMenuBarPanel()
                .preferredColorScheme(.dark)
        } label: {
            MultiplayerMenuBarLabel(model: network)
        }
        .menuBarExtraStyle(.window)
    }
}
