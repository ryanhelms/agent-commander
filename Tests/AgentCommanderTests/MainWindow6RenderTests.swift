import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of the states increment 6 changed, drawn from the design-preview samples.
// Skipped unless MAIN_WINDOW_6_RENDER_DIR names a folder for the PNG files:
//
//     MAIN_WINDOW_6_RENDER_DIR=design/demos/main-window-6 swift test --filter MainWindow6Render
//
// Each state is drawn as a whole window at 1440 x 900 (`<name>-console.png`) and at 1280 x 800
// (`fit-1280-<name>-console.png`), one pixel per point, in the console theme. The bands' sideways
// scroll is on, as it is in the live window, so a confirmation under the fold is drawn where the
// page scrolls it to. Nothing here opens a window on screen or touches the running app.

let mainWindow6RenderDirectory = ProcessInfo.processInfo.environment["MAIN_WINDOW_6_RENDER_DIR"]

@MainActor @Suite struct MainWindow6RenderTests {
    typealias Drawn = (name: String, view: AnyView)

    static func teams(_ name: String, _ scenario: DesignPreviewScenario, place: String? = nil, _ intents: [TeamsIntent] = [],
                      prepare: (TeamsPreviewState) -> Void = { _ in }) -> Drawn {
        let state = TeamsRenderTests.state(scenario, place: place, intents, prepare: prepare)
        return (name, AnyView(TeamsRenderTests.shell(scenario, state: state)))
    }

    static func network(_ name: String, _ scenario: DesignPreviewScenario, prepare: (ShellPreviewState) -> Void) -> Drawn {
        let state = ShellPreviewState(selection: scenario.networkPlace ?? "")
        prepare(state)
        return (name, AnyView(NetworkRenderTests.shell(scenario, state: state)))
    }

    /// The states the increment changed, by file name.
    static func states() -> [Drawn] {
        let relay = TeamsSample.relayKey, infra = TeamsSample.infraKey, studio = TeamsSample.studio
        return [
            // Breadcrumbs lead with Teams; the owner is a fact, and the owner is offered Edit.
            teams("teams-workspace", .teamsWorkspace),
            teams("teams-hosts", .teamsHosts),
            // The Board tab's figure is the heading's; a Done card carries no claim note.
            teams("teams-board", .teamsBoard),
            // A long queue puts the Run merge confirmation under the fold; the page scrolls to it.
            teams("teams-integration-merge-confirm", .teamsWorkspace, [.showBand(.integration, workspace: relay), .askMerge(workspace: relay)]) { teams in
                for index in 1...6 {
                    teams.content.queue[relay]?.append(MultiplayerQueueEntry(
                        workspace: TeamsSample.relay, branch: "collab/verify-\(index)", checkout: NetworkSample.checkout,
                        test: ["make", "test"], added: TeamsSample.now.addingTimeInterval(TimeInterval(-60 * index))))
                }
            },
            // The owner's edit, and its confirmation naming each change.
            teams("teams-workspace-edit-confirm", .teamsWorkspace) { teams in
                teams.state.drafts.workspace = MultiplayerWorkspaceEdit(name: "Relay reconnect", goal: "Ship the per-request retry budget and the lease renewal fix for 1.4.",
                                                                        repository: "ryanhelms/relay", base: "release/1.4", integration: .queue)
                teams.state.selection.composer = .editWorkspace(relay)
                teams.state.selection.confirming = .saveWorkspace(workspace: relay)
            },
            // A member, not the owner: Leave, after a confirmation.
            teams("teams-workspace-leave-confirm", .teamsWorkspace, place: TeamsSample.infraPlace, [.askLeave(workspace: infra)]),
            // The refusal names the holder, the agent and the claim, and marks the claim's row.
            teams("teams-claims-refused", .teamsWorkspace, [.showBand(.claims, workspace: relay), .startClaim(workspace: relay)]) { teams in
                teams.state.selection.band[relay] = .claims
                teams.state.selection.composer = .claim(workspace: relay)
                teams.state.drafts.claim = MultiplayerClaimDraft(kind: .paths, key: "Sources/Relay", agent: "relay-worker")
                teams.state.refusal = "Couldn’t claim it. sam holds it with the agent sam-claude, under the paths claim Sources/Relay/Lease."
                teams.state.selection.conflict = "cl-2"
            },
            // Owners by handle, and what you shared counted.
            teams("teams-knowledge", .teamsKnowledge),
            teams("teams-knowledge-share", .teamsKnowledge, [.startShare(server: studio)]),
            // "Its 1 member loses".
            teams("teams-groups-delete-confirm", .teamsGroups) { teams in
                teams.content.servers[0].groups.append(MultiplayerGroup(id: "g-solo", name: "Solo runs", owner: "ryan", members: ["ryan"]))
                teams.state.selection.group = TeamsKey.make("g-solo", on: studio)
                teams.state.selection.confirming = .deleteGroup(TeamsKey.make("g-solo", on: studio))
            },
            // Members and devices as the relay lists them, chosen from the list.
            teams("teams-admin", .teamsAdmin),
            teams("teams-admin-suspend-confirm", .teamsAdmin, [.askSuspend("tomas", server: studio)]),
            // The grant sheet and the Revoke confirmation, scrolled into view.
            network("network-approvals-grant", .networkApprovals) { state in
                let pages = state.network.pages(go: { _ in })
                if let row = pages.content.accessRows.first(where: \.isIncoming) { pages.actions.reviewAccess(row.request, row.server) }
            },
            network("network-shared-revoke-confirm", .networkShared) { state in
                guard let row = state.network.pages(go: { _ in }).content.sharedRows.first(where: { !$0.grants.isEmpty }),
                      let grant = row.grants.last else { return }
                state.network.selection.shared = row.id
                state.network.selection.revoking = "\(row.server)/\(grant.id)"
            }
        ]
    }

    @Test func everyStateHasItsOwnName() {
        let names = Self.states().map(\.name)
        #expect(Set(names).count == names.count && !names.isEmpty)
    }

    @Test(.enabled(if: mainWindow6RenderDirectory != nil)) func drawsTheChangedStates() async throws {
        let folder = URL(fileURLWithPath: try #require(mainWindow6RenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (name, view) in Self.states() {
            let live = view.environment(\.networkPageScrollsSideways, true)
            try await ShellRenderTests.write(live, name, theme: .console, to: folder)
            try await ShellRenderTests.write(live, "fit-1280-\(name)", theme: .console, to: folder, size: NetworkFitTests.window)
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fit-1280-teams-integration-merge-confirm-console.png").path))
    }
}
