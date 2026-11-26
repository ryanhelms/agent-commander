import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of the Teams pages, drawn from the design-preview samples. Skipped unless
// TEAMS_RENDER_DIR names a folder for the PNG files:
//
//     TEAMS_RENDER_DIR=design/demos/main-window-5 swift test --filter TeamsRender
//
// Each state is drawn as a whole window at 1440 x 900 and at 1280 x 800, one pixel per point, in
// the console theme, with one black-glass check. Nothing here opens a window on screen, touches
// the running app or reads the network model.

let teamsRenderDirectory = ProcessInfo.processInfo.environment["TEAMS_RENDER_DIR"]

@MainActor @Suite struct TeamsRenderTests {
    static let scenarios: [(DesignPreviewScenario, String)] = [
        (.teamsWorkspace, "teams-workspace"), (.teamsBoard, "teams-board"), (.teamsGroups, "teams-groups"),
        (.teamsHosts, "teams-hosts"), (.teamsKnowledge, "teams-knowledge"), (.teamsDirectory, "teams-directory"),
        (.teamsAdmin, "teams-admin")
    ]

    /// The sample window: sidebar B on a Teams place.
    static func shell(_ scenario: DesignPreviewScenario, state: ShellPreviewState? = nil) -> some View {
        ShellPreviewPage(store: PreviewStore(scenario: scenario), state: state ?? ShellPreviewState(scenario: scenario), chrome: .drawn)
    }

    /// A scenario's state after the given intents, with nothing left running.
    static func state(_ scenario: DesignPreviewScenario, place: String? = nil, _ intents: [TeamsIntent] = [],
                      prepare: (TeamsPreviewState) -> Void = { _ in }) -> ShellPreviewState {
        let state = ShellPreviewState(scenario: scenario)
        if let place { state.selection = place }
        prepare(state.teams)
        for intent in intents { state.teams.pages(go: { _ in }).send(intent) }
        return state
    }

    /// Every page and the states a click reaches, by file name.
    static func states() -> [(name: String, scenario: DesignPreviewScenario, state: ShellPreviewState)] {
        let relay = TeamsSample.relayKey, studio = TeamsSample.studio
        var all: [(String, DesignPreviewScenario, ShellPreviewState)] = scenarios.map { ($0.1, $0.0, ShellPreviewState(scenario: $0.0)) }
        all.append(("teams-integration-queue", .teamsWorkspace, state(.teamsWorkspace, [.showBand(.integration, workspace: relay)])))
        all.append(("teams-integration-merge-confirm", .teamsWorkspace,
                    state(.teamsWorkspace, [.showBand(.integration, workspace: relay), .askMerge(workspace: relay)])))
        all.append(("teams-integration-pull-requests", .teamsWorkspace,
                    state(.teamsWorkspace, place: TeamsSample.infraPlace, [.showBand(.integration, workspace: TeamsSample.infraKey)])))
        all.append(("teams-claims-refused", .teamsWorkspace, state(.teamsWorkspace, [.showBand(.claims, workspace: relay), .startClaim(workspace: relay)]) { teams in
            teams.state.selection.band[relay] = .claims
            teams.state.selection.composer = .claim(workspace: relay)
            teams.state.drafts.claim = MultiplayerClaimDraft(kind: .paths, key: "Sources/Relay", agent: "relay-worker")
            teams.state.refusal = "Couldn’t claim it. Overlapping claim held by sam/sam-claude."
            teams.state.selection.conflict = "cl-2"
        }))
        all.append(("teams-knowledge-install-confirm", .teamsKnowledge, {
            let state = ShellPreviewState(scenario: .teamsKnowledge)
            if let item = state.teams.content.item(TeamsKey.make("k-1", on: studio))?.item {
                state.teams.pages(go: { _ in }).send(.askInstall(item, server: studio))
            }
            return state
        }()))
        all.append(("teams-knowledge-secret-refused", .teamsKnowledge, state(.teamsKnowledge, [.startShare(server: studio)]) { _ in }))
        all.append(("teams-admin-suspend-confirm", .teamsAdmin, state(.teamsAdmin, [.askSuspend("tomas", server: studio)])))
        return all
    }

    @Test func everyTeamsScenarioOpensOnItsPlace() {
        #expect(Self.scenarios.allSatisfy { $0.0.rawValue == $0.1 && $0.0.isShell && ShellConcept(scenario: $0.0) == .modeRail })
        #expect(Self.scenarios.allSatisfy { $0.0.teamsPlace.map(TeamsPlace.hasPage) == true })
    }

    @Test(.enabled(if: teamsRenderDirectory != nil)) func drawsTheTeamsPages() async throws {
        let folder = URL(fileURLWithPath: try #require(teamsRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (name, scenario, state) in Self.states() {
            try await ShellRenderTests.write(Self.shell(scenario, state: state), name, theme: .console, to: folder)
            try await ShellRenderTests.write(Self.shell(scenario, state: state), "fit-1280-\(name)", theme: .console, to: folder,
                                             size: NetworkFitTests.window)
        }
        try await ShellRenderTests.write(Self.shell(.teamsBoard), "teams-board", theme: .blackGlass, to: folder)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("teams-admin-console.png").path))
    }
}
