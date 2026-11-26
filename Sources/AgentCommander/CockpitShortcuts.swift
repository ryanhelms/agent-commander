import SwiftUI

// ATOMIC LEVEL: Values (the main window's keyboard shortcuts).
// Every shortcut the cockpit window binds, in one table, so no two can meet on one key. The
// hidden buttons that carry them only record which command was pressed
// (`CockpitPresentationState.press`). The page then runs the command from its current state.
//
// Why a command is recorded and not run in the button: a shortcut's button keeps the action it
// was first given. The mode buttons used to capture the navigation as it stood when the window
// opened, so ⌥⌘1 always saw "already in Agents" and did nothing, and ⌥⌘4 went to the Teams place
// of an empty network, which no longer existed once workspaces had loaded, so the window fell
// back to Runs. A recorded command reads nothing until the page handles it.

/// Something a key can ask the cockpit window to do.
enum CockpitCommand: Hashable, Sendable {
    /// The mode at this place on the rail, counting from zero: Agents, Network, People, Teams, Settings.
    case mode(Int)
    case focusCoordinator, zoomWorker, returnToWall, nextRequest, newRun
}

/// One key of the cockpit window.
struct CockpitShortcut: Identifiable, Hashable, Sendable {
    let command: CockpitCommand
    let title: String
    let key: Character
    /// The modifier keys, as `EventModifiers` raw values so the table is hashable.
    let modifierBits: Int

    var id: CockpitCommand { command }
    var modifiers: EventModifiers { EventModifiers(rawValue: modifierBits) }

    /// What tells two shortcuts apart for the system: the key and its exact modifiers.
    var chord: String { "\(modifiers.shellKeyCap)\(String(key).uppercased())" }

    /// The digit or letter itself on every keyboard layout, so ⌥ is never read as another key.
    var shortcut: KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers, localization: .custom)
    }

    init(_ command: CockpitCommand, _ title: String, _ key: Character, _ modifiers: EventModifiers) {
        self.command = command
        self.title = title
        self.key = key
        modifierBits = modifiers.rawValue
    }
}

enum CockpitShortcuts {
    /// The modes on the rail, in order. ⌥⌘1 to ⌥⌘5.
    static let modeTitles = ["Agents", "Network", "People", "Teams", "Settings"]

    static let modes: [CockpitShortcut] = modeTitles.enumerated().map { index, title in
        CockpitShortcut(.mode(index), title, Character("\(index + 1)"), LiveShell.modeModifiers)
    }

    static let focusCoordinator = CockpitShortcut(.focusCoordinator, "Focus coordinator", "1", .command)
    static let zoomWorker = CockpitShortcut(.zoomWorker, "Zoom worker", "]", .command)
    static let returnToWall = CockpitShortcut(.returnToWall, "Return to wall", "[", .command)
    static let nextRequest = CockpitShortcut(.nextRequest, "Next request", "a", [.command, .shift])
    static let newRun = CockpitShortcut(.newRun, "New run", "n", .command)
    /// The toolbar's Search workspace. It is bound on its own toolbar button.
    static let search = (key: Character("k"), modifiers: EventModifiers.command)

    /// Every shortcut the cockpit's hidden buttons bind.
    static let all: [CockpitShortcut] = modes + [focusCoordinator, zoomWorker, returnToWall, nextRequest, newRun]

    /// Chords bound more than once. Empty when the table is sound.
    static var collisions: [String] {
        let chords = all.map(\.chord) + ["\(search.modifiers.shellKeyCap)\(String(search.key).uppercased())"]
        return Dictionary(grouping: chords, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }
}
