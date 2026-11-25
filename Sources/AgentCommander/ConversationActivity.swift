import Foundation

// CONVERSATION ACTIVITY
// A live run reports usage, session state and harness diagnostics between the things people say.
// Console keeps each as its own row. Pretty reads a run of them as one collapsed "Activity"
// disclosure, in the place they happened, so the conversation stays the developer's prompts, the
// agent's replies and its tools.
//
//   Values          ConversationActivity          one run of adjacent routine entries, in order
//                   ConversationItem              what Pretty lays out: an entry, or an activity
//                   PromptMediaIndicator          the media a prompt's `metadata.acp` says it carried
//   Feature layer   ConversationActivity.items    groups routine entries; passes every other through
//                   PromptMediaIndicator.display  a prompt's text without the service's trailing marker
//
// Nothing is dropped. An activity holds every entry it stands for, with its own ID, and opening it
// shows each one with its own fields action. Only display changes: the entries, their text and
// their records are the ones Console shows.

/// A run of adjacent routine entries, shown as one disclosure.
struct ConversationActivity: Identifiable, Equatable {
    private static let suffix = "#activity"

    /// Text the service puts in front of harness output it relays, on a message with no ACP mark.
    /// Only a message of a role other than `user` and `assistant` is compared, so a prompt or a
    /// reply that quotes one of these stays a prompt or a reply.
    static let operationalMarkers = ["[Provider stderr]", "[Provider stdout]", "[Provider event:", "[Service "]
    private static let stderrMarker = "[Provider stderr]"

    /// Depends only on the first entry, so the disclosure keeps its place and its open state while
    /// more routine entries arrive behind it.
    let id: String
    /// Every entry of the run, oldest first, as Pretty would show each on its own.
    var entries: [TranscriptEntry]

    init(first: TranscriptEntry) {
        id = first.id + Self.suffix
        entries = [first]
    }

    /// True for an entry that reports state instead of saying something: an ACP session update
    /// with a one-line summary (usage, mode, commands, session info, configuration), or relayed
    /// harness output behind one of `operationalMarkers`. Prompts, replies, tools, tool results,
    /// and any other note, such as a gap the service reports, are never routine.
    static func isRoutine(_ entry: TranscriptEntry) -> Bool {
        guard case .other(let role, let text) = entry.kind, role != "user", role != "assistant" else { return false }
        if entry.origin?.summary != nil { return true }
        return operationalMarkers.contains { text.hasPrefix($0) }
    }

    /// The items of a recent window, with `anchor` (a request's workflow linked over the whole
    /// transcript) in place of that request's calls; see `anchored(_:_:)`.
    static func items(_ entries: [TranscriptEntry], awaitingToolID: String? = nil,
                      anchor: CommanderWorkflow?) -> [ConversationItem] {
        let windowed = items(entries, awaitingToolID: awaitingToolID)
        guard let anchor else { return windowed }
        return anchored(windowed, anchor)
    }

    /// The window's items with the anchor's story in place of every window item that holds any of
    /// its calls: once, where the first such item was, or first when the window holds none of
    /// them. A window item's other calls, which the window alone might have linked with it, are
    /// linked again on their own, so every entry is still shown exactly once.
    static func anchored(_ items: [ConversationItem], _ anchor: CommanderWorkflow) -> [ConversationItem] {
        let owned = Set(anchor.entries.map(\.id))
        var result: [ConversationItem] = []
        var placed = false
        for item in items {
            guard item.entries.contains(where: { owned.contains($0.id) }) else { result.append(item); continue }
            if !placed { result.append(.commander(anchor)); placed = true }
            let others = item.entries.filter { !owned.contains($0.id) }
            if !others.isEmpty { result += Self.items(others) }
        }
        if !placed { result.insert(.commander(anchor), at: 0) }
        return result
    }

    /// The entries Pretty lays out, in order. Each run of adjacent routine entries is one
    /// activity; every other entry is passed through as it is. Order is never changed, and an
    /// activity never reaches across an entry that is not routine.
    /// Commander's own tool calls are first read into `CommanderWorkflow`s; a workflow is not
    /// routine, so it ends a run like any other entry. `awaitingToolID` is the one open call a
    /// provider permission holds, so its workflow reads as awaiting approval.
    static func items(_ entries: [TranscriptEntry], awaitingToolID: String? = nil) -> [ConversationItem] {
        var items: [ConversationItem] = []
        items.reserveCapacity(entries.count)
        var open: ConversationActivity?
        for commanderItem in CommanderActivity.items(entries, awaitingToolID: awaitingToolID) {
            guard case .entry(let entry) = commanderItem else {
                if let activity = open { items.append(.activity(activity)); open = nil }
                if case .workflow(let workflow) = commanderItem { items.append(.commander(workflow)) }
                continue
            }
            if isRoutine(entry) {
                if open == nil { open = ConversationActivity(first: entry) } else { open?.entries.append(entry) }
            } else {
                if let activity = open { items.append(.activity(activity)); open = nil }
                items.append(.entry(entry))
            }
        }
        if let activity = open { items.append(.activity(activity)) }
        return items
    }

    /// How many of the entries are harness diagnostics, which can matter more than a usage count.
    var stderrCount: Int {
        entries.filter { entry in
            if case .other(_, let text) = entry.kind { return text.hasPrefix(Self.stderrMarker) }
            return false
        }.count
    }

    /// What the collapsed disclosure says after its name, such as `3 events · 1 stderr`.
    var detail: String {
        var parts = [entries.count == 1 ? "1 event" : "\(entries.count) events"]
        if stderrCount > 0 { parts.append("\(stderrCount) stderr") }
        return parts.joined(separator: " · ")
    }

    /// The disclosure's accessible name, such as `Activity, 3 events, 1 stderr`.
    var accessibilityLabel: String {
        "Activity, " + detail.replacingOccurrences(of: " · ", with: ", ")
    }
}

/// One thing in the Pretty conversation column.
enum ConversationItem: Identifiable, Equatable {
    case entry(TranscriptEntry)
    case activity(ConversationActivity)
    /// Commander calls linked by proof, or one Commander call; see `CommanderActivity`.
    case commander(CommanderWorkflow)

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .activity(let activity): activity.id
        case .commander(let workflow): workflow.id
        }
    }

    /// Every entry the item stands for, in order.
    var entries: [TranscriptEntry] {
        switch self {
        case .entry(let entry): [entry]
        case .activity(let activity): activity.entries
        case .commander(let workflow): workflow.entries
        }
    }
}

/// The media a developer's prompt carried, as its message's `metadata.acp` states it. The service
/// writes the prompt's text parts end to end and a `[ACP <type>] <media type>` marker for each
/// media part. Pretty shows the prompt without the markers at its end; the message's content is
/// unchanged, and Console, the copy action and the fields show it exactly as sent.
struct PromptMediaIndicator: Equatable, Sendable {
    /// The first media part's type, such as `image`. Empty when the reference does not say.
    let contentType: String
    let mimeType: String
    /// How many media parts the reference says the prompt carried. At least one.
    let count: Int

    /// Nil unless the reference marks a live prompt with media: source `live`, kind
    /// `acp.prompt_part`. A prompt without that reference is shown exactly as written, so text a
    /// developer typed that looks like a marker is never removed, and an older prompt keeps its
    /// bracketed marker as the sign that it carried media. A prompt recovered from provider
    /// history (kind `provider_prompt_media`) has no service markers, so its text is never
    /// trimmed either.
    init?(acp: [String: AGUIValue]) {
        guard acp["source"]?.stringValue == ConversationChunks.liveSource,
              acp["kind"]?.stringValue == PromptAttachmentReference.kind else { return nil }
        let stated = acp["itemCount"]?.intValue
        if let stated, stated < 1 { return nil }
        contentType = acp["contentType"]?.stringValue ?? ""
        mimeType = acp["mimeType"]?.stringValue ?? ""
        count = stated ?? 1
    }

    /// What stands in for the removed markers where no attachment action is drawn.
    var caption: String {
        guard count == 1 else { return "\(count) attachments" }
        let noun = contentType.isEmpty ? "attachment" : contentType
        return "1 \(noun) attached" + (mimeType.isEmpty ? "" : " · \(mimeType)")
    }

    /// The prompt as Pretty shows it. At most `count` markers are removed, and only from the end:
    /// a marker anywhere else, or one more than the reference counts, stays as text.
    /// - Returns: the text to show, and how many markers were removed. A prompt that was only
    ///   media reads as the caption.
    func display(_ text: String) -> (text: String, removed: Int) {
        var shown = Substring(text)
        var removed = 0
        while removed < count, let marker = Self.trailingMarker(in: shown) {
            shown = shown[..<marker]
            removed += 1
        }
        guard removed > 0 else { return (text, 0) }
        let kept = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        return (kept.isEmpty ? caption : kept, removed)
    }

    /// Where a `[ACP <type>]` or `[ACP <type>] <media type>` marker starts, when `text` ends
    /// with exactly one. The type is letters and underscores; the media type has no spaces or
    /// brackets.
    private static func trailingMarker(in text: Substring) -> Substring.Index? {
        guard let open = text.range(of: "[ACP ", options: .backwards) else { return nil }
        let tail = text[open.upperBound...]
        guard let close = tail.firstIndex(of: "]") else { return nil }
        let type = tail[..<close]
        guard !type.isEmpty, type.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        let rest = tail[tail.index(after: close)...]
        if rest.isEmpty { return open.lowerBound }
        guard rest.first == " " else { return nil }
        let media = rest.dropFirst()
        guard !media.isEmpty, !media.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "]" }) else { return nil }
        return open.lowerBound
    }
}

extension TranscriptEntry {
    /// The media reference of a developer's prompt. Nil for every other entry.
    var promptMedia: PromptMediaIndicator? { isFromUser ? origin?.promptMedia : nil }
}
