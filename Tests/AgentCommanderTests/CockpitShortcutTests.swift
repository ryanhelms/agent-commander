import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// The main window's keyboard shortcuts: no two share a chord, the source binds no other key in
// the cockpit window, and a mode key acts on the navigation as it is now.

@MainActor @Suite struct CockpitShortcutTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func noTwoCockpitShortcutsShareAChord() {
        #expect(CockpitShortcuts.collisions.isEmpty, "bound twice: \(CockpitShortcuts.collisions)")
        #expect(Set(CockpitShortcuts.all.map(\.command)).count == CockpitShortcuts.all.count)
        // ⌘1 stays the coordinator's; the modes take ⌥⌘1 to ⌥⌘5 and never plain ⌘ and a digit.
        #expect(CockpitShortcuts.focusCoordinator.chord == "⌘1")
        #expect(CockpitShortcuts.modes.map(\.chord) == ["⌥⌘1", "⌥⌘2", "⌥⌘3", "⌥⌘4", "⌥⌘5"])
        #expect(CockpitShortcuts.modes.map(\.title) == ["Agents", "Network", "People", "Teams", "Settings"])
    }

    /// The rail's modes are the ones the keys are named for, in the same order.
    @Test func theModeKeysFollowTheRail() {
        let navigation = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: LiveShell.wall,
                                              needsYou: 0, network: ShellLiveTests.network)
        #expect(navigation.modeItems.map(\.mode.title) == CockpitShortcuts.modeTitles)
        #expect(navigation.modeItems.map(\.shortcut) == [1, 2, 3, 4, 5])
    }

    /// Every literal shortcut in the app's source, by the window it is bound in. The cockpit's
    /// own file binds keys only through the table, and no other file of the cockpit window binds
    /// a chord the table already holds.
    @Test func noOtherSourceBindsACockpitChord() throws {
        let sources = Self.root.appendingPathComponent("Sources/AgentCommander")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        // .keyboardShortcut("k", modifiers: .command), KeyboardShortcut("1", modifiers: ...), with or without modifiers.
        let literal = try NSRegularExpression(pattern: #"[kK]eyboardShortcut\(\s*(?:KeyEquivalent\()?"(.)"\)?(?:\s*,\s*modifiers:\s*(\[[^\]]*\]|\.[a-z]+))?"#)
        // Windows of their own: the network tray and panel, and the design preview's page.
        func isOtherWindow(_ file: String) -> Bool { file.hasPrefix("Multiplayer") || file == "DesignPreview.swift" || file == "ShellPreview.swift" }
        let taken = Set(CockpitShortcuts.all.map(\.chord) + ["⌘K"])
        var found: [String] = []
        for file in files.sorted() where !isOtherWindow(file) && file != "CockpitShortcuts.swift" {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[try #require(Range(match.range(at: 1), in: text))]).uppercased()
                let modifiers = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ".command"
                let chord = (modifiers.contains("control") ? "⌃" : "") + (modifiers.contains("option") ? "⌥" : "")
                    + (modifiers.contains("shift") ? "⇧" : "") + (modifiers.contains("command") ? "⌘" : "") + key
                found.append("\(file): \(chord)")
                #expect(!taken.contains(chord), "\(file) binds \(chord), which the cockpit table already holds")
            }
        }
        // The cockpit page binds its keys from the table alone.
        #expect(!found.contains { $0.hasPrefix("CockpitView.swift") }, "\(found)")
    }

    /// The scan itself sees a literal shortcut, so an empty result means there is none.
    @Test func theScanSeesLiteralShortcuts() throws {
        let literal = try NSRegularExpression(pattern: #"[kK]eyboardShortcut\(\s*(?:KeyEquivalent\()?"(.)"\)?(?:\s*,\s*modifiers:\s*(\[[^\]]*\]|\.[a-z]+))?"#)
        for sample in [#".keyboardShortcut("4", modifiers: [.command, .option])"#, #"KeyboardShortcut("1", modifiers: .command, localization: .custom)"#,
                       #".keyboardShortcut(KeyEquivalent("k"), modifiers: .command)"#] {
            #expect(literal.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil, "\(sample)")
        }
    }

    // MARK: A mode key acts on the navigation as it is now

    @Test func aKeyCommandIsRecordedAndCounted() {
        let ui = CockpitPresentationState()
        #expect(ui.keyCommand == nil && ui.keyCommandCount == 0)
        ui.press(.mode(3))
        ui.press(.mode(3))
        // The same key twice is two commands.
        #expect(ui.keyCommand == .mode(3) && ui.keyCommandCount == 2)
    }

    /// What ⌥⌘1 and ⌥⌘4 did wrong: they acted on the navigation of the moment the window opened.
    @Test func modeKeysWorkFromTheCurrentNavigation() {
        func navigation(place: String, network: ShellNetwork) -> CommanderNavigation {
            LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: place, needsYou: 0, network: network)
        }
        // ⌥⌘1 from Network goes to Agents. On the navigation of launch (already in Agents) it did nothing.
        var inNetwork = navigation(place: LiveShell.servers, network: ShellLiveTests.network)
        inNetwork.apply(.selectMode("agents"))
        #expect(inNetwork.selection == LiveShell.needsYou)
        var atLaunch = navigation(place: LiveShell.wall, network: ShellLiveTests.network)
        atLaunch.apply(.selectMode("agents"))
        #expect(atLaunch.selection == LiveShell.wall)

        // ⌥⌘4 goes to the first workspace.
        var current = navigation(place: LiveShell.wall, network: ShellLiveTests.network)
        current.apply(.selectMode("teams"))
        let workspace = LiveShell.team(ShellLiveTests.network.workspaces[0])
        #expect(current.selection == workspace)

        // The Teams place of a network with no workspace is gone once one arrives. The window
        // stays in Teams instead of falling back to Runs.
        var empty = ShellLiveTests.network
        empty.workspaces = []
        var before = navigation(place: LiveShell.wall, network: empty)
        before.apply(.selectMode("teams"))
        #expect(before.selection == LiveShell.workspaces)
        let after = navigation(place: LiveShell.workspaces, network: ShellLiveTests.network)
        #expect(after.selection == workspace && after.selectedModeID == "teams")
        // A workspace that is gone leaves the window in Teams too.
        #expect(navigation(place: "team:srv-studio/gone", network: ShellLiveTests.network).selection == workspace)
        #expect(navigation(place: "team:srv-studio/gone", network: empty).selection == LiveShell.workspaces)
        #expect(navigation(place: "nowhere", network: ShellLiveTests.network).selection == LiveShell.wall)
    }
}
