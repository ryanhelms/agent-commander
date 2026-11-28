import Foundation

// PROVIDER TOOL KIND (DESIGN.md, "Pretty transcript", "Tool kind"; spec section H, ACP tool `kind`)
// The verb of a tool Commander does not know, from the kind the provider stated for that call.
//
//   Values         ProviderToolKind     the nine ACP kinds that pick a verb, by exact wire value
//   Feature layer  ActivityWords.kind   the wording of one call, from its own stored summary
//
// Honesty rules:
// - The kind and the title are read only from the call's own stored summary, a `tool` record the
//   service kept from the provider's typed ACP update (`tool_kind`, `title`). The call's display
//   name and text never choose a kind, and no other call's record is read.
// - The object is the provider's title as sent: its first line, masked when the transcript
//   setting hides secrets. Nothing is cut from it, added to it or read out of it.
// - A closed group counts the call under its kind only when the same summary holds one exact
//   file location. Without it the call counts as another tool. A title is never read as a path.
// - `other`, a kind not listed here, a missing kind or a missing title keep "Used `tool`".

enum ProviderToolKind: String, CaseIterable, Equatable, Sendable {
    case read, edit, delete, move, search, execute, think, fetch
    case switchMode = "switch_mode"

    /// The kind the provider sent, matched on its whole wire value: no case folding, no trimming.
    init?(wire: String?) {
        guard let wire, let kind = ProviderToolKind(rawValue: wire) else { return nil }
        self = kind
    }

    /// The words before the title: while the call runs, once it has finished, and when it failed.
    var verbs: (running: String, done: String, failed: String) {
        switch self {
        case .read: ("Reading ", "Read ", "Couldn't read ")
        case .edit: ("Editing ", "Edited ", "Couldn't edit ")
        case .delete: ("Deleting ", "Deleted ", "Couldn't delete ")
        case .move: ("Moving ", "Moved ", "Couldn't move ")
        case .search: ("Searching ", "Searched ", "Couldn't search ")
        case .execute: ("Running ", "Ran ", "Couldn't run ")
        case .think: ("Thinking through ", "Thought through ", "Couldn't think through ")
        case .fetch: ("Fetching ", "Fetched ", "Couldn't fetch ")
        case .switchMode: ("Switching mode: ", "Switched mode: ", "Couldn't switch mode: ")
        }
    }

    /// How the call counts in a closed group, once its summary holds an exact file location.
    /// A kind Pretty already counts shares that phrase's key, so the two add up.
    var phrase: ActivityPhrase {
        switch self {
        case .read: ActivityPhrase(key: "read", one: "read a file", many: "read %d files")
        case .edit: ActivityPhrase(key: "edit", one: "edited a file", many: "edited %d files")
        case .delete: ActivityPhrase(key: "delete", one: "deleted a file", many: "deleted %d files")
        case .move: ActivityPhrase(key: "move", one: "moved a file", many: "moved %d files")
        case .search: ActivityPhrase(key: "search", one: "ran a search", many: "ran %d searches")
        case .execute: ActivityPhrase(key: "shell", one: "ran a command", many: "ran %d commands")
        case .think: ActivityPhrase(key: "think", one: "thought", many: "thought %d times")
        // Its own key: the object is a file, so it never adds to a named web fetch's pages.
        case .fetch: ActivityPhrase(key: "fetch", one: "fetched a file", many: "fetched %d files")
        case .switchMode: ActivityPhrase(key: "switch_mode", one: "switched mode", many: "switched mode %d times")
        }
    }
}

extension ActivityWords {
    /// How a group counts a tool Pretty has no phrase for.
    static let otherToolPhrase = ActivityPhrase(key: "other", one: "used another tool", many: "used %d other tools")

    /// The wording of an unknown tool whose own stored summary states a recognised kind and a
    /// title. Nil otherwise, and the caller keeps "Used `tool`".
    ///
    /// - Parameter hidesSecrets: the transcript setting (`ToolDetailStore.hidesSecrets`). The
    ///   title is masked before it enters a sentence, so the line, its help and what VoiceOver
    ///   reads all hold the masked words.
    static func kind(summary: ToolDetailSummary?, hidesSecrets: Bool = false) -> ActivityWording? {
        guard let summary, summary.kind == "tool", let kind = ProviderToolKind(wire: summary.toolKind),
              let sent = summary.title else { return nil }
        let line = ToolDetailText.wholeLine(sent.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty else { return nil }
        let title = hidesSecrets ? SecretValues.masked(prose: line).text : line
        let verbs = kind.verbs
        func sentence(_ verb: String) -> ActivitySentence { ActivitySentence(.text(verb), .strong(title)) }
        return ActivityWording(
            running: sentence(verbs.running), done: sentence(verbs.done), fallback: sentence(verbs.done),
            failed: sentence(verbs.failed),
            // Only the location attached to this very call makes it a counted file action.
            phrase: summary.openableLocation != nil ? kind.phrase : otherToolPhrase,
            // No help of its own: the line's help is then its sentence, which is already masked.
            help: nil)
    }
}
