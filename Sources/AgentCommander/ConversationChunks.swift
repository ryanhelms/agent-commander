import Foundation

// CONVERSATION CHUNKS
// A live ACP agent streams one reply as many `agent_message_chunk` updates, and the service
// projects each as its own assistant message. `TranscriptEntry.entries(from:)` keeps one entry per
// message. Console and Pretty both read a run of them as one turn, so a reply is the characters
// the agent streamed and not one token per row. They differ only by display policy: Console keeps
// every other entry and its text as the service wrote it, Pretty summarises operational notes.
//
//   Values          TranscriptOrigin              what `metadata.acp` says about an entry's record
//                   ConversationChunks.DisplayPolicy  what a display mode does beyond joining chunks
//   Feature layer   ConversationChunks.key        whether a message is a live chunk, and of which reply
//                   TranscriptEntry.folded        chunk runs joined, under a display policy
//                   TranscriptEntry.displayed     the entries a display mode lays out; both views call it
//                   TranscriptEntry.conversation  Pretty's fold: chunk runs joined, notes summarised
//                   ConversationChunks.turn       the original messages behind a joined turn
//                   ConsoleRecordDetail.messageIDs  the messages an entry's fields reach
//
// Only messages the service marks as live `agent_message_chunk` text are joined, and only while
// they follow one another directly with the same ACP message and turn identity. A message
// without that mark is a whole message and stays its own entry. The joined text is the chunks'
// content end to end, with nothing trimmed or inserted.

/// What the service's `metadata.acp` says about the record behind a transcript entry. Read once,
/// when the entry is built, by member access on the message's retained fields.
struct TranscriptOrigin: Equatable, Sendable {
    /// One piece of a streamed assistant reply.
    struct Chunk: Equatable, Sendable {
        /// The content exactly as sent, with its leading and trailing whitespace.
        var text: String
        /// The message directly before this one is a chunk of the same reply.
        var joinsPrevious: Bool
    }

    /// The ACP session update, such as `agent_message_chunk` or `usage_update`.
    let kind: String
    /// IDs of the service messages this entry stands for, oldest first. One for an entry built
    /// from a message; every chunk for a joined turn.
    var sourceIDs: [String]
    /// Set on a live assistant chunk.
    var chunk: Chunk?
    /// One line for an operational record, such as context usage. Pretty shows it in place of
    /// the record's text. The text and every field stay in the record.
    var summary: String?
    /// Set on a developer's prompt whose reference says it carried media. Pretty uses it to keep
    /// the service's marker out of the prompt's text; see `PromptMediaIndicator`.
    var promptMedia: PromptMediaIndicator? = nil
}

enum ConversationChunks {
    static let liveSource = "live"
    static let chunkKind = "agent_message_chunk"

    /// The reply a live chunk belongs to. Two chunks join only when their keys are equal, so a
    /// chunk with an ACP message ID never joins one without, or one with another ID.
    struct Key: Equatable, Sendable {
        let messageID: String?
        let turnID: String?
    }

    /// What a display mode does to a transcript beyond joining the chunks of a reply. Joining is
    /// the same in every mode: same runs, same turn IDs, same exact text, same source IDs.
    struct DisplayPolicy: Equatable, Sendable {
        /// An operational note (usage, mode, session info) reads as its one-line summary. When
        /// false the note keeps the text the service wrote.
        var summarisesNotes: Bool

        /// Console: chunks joined, every other entry exactly as built, nothing left out.
        static let console = DisplayPolicy(summarisesNotes: false)
        /// Pretty: chunks joined and operational notes summarised.
        static let pretty = DisplayPolicy(summarisesNotes: true)
    }

    /// The key of a live assistant text chunk. Nil for every other message: another role, a tool
    /// call or result, structured content, provider history, or a message with no ACP mark.
    static func key(of message: AGUIMessage) -> Key? {
        guard message.role == "assistant", message.toolCallID == nil, message.toolCalls?.isEmpty ?? true,
              case .object(let acp)? = message.metadata?["acp"],
              acp["kind"]?.stringValue == chunkKind, acp["source"]?.stringValue == liveSource,
              acp["contentType"]?.stringValue ?? "text" == "text",
              !message.hasStructuredContent else { return nil }
        return Key(messageID: identity(acp["messageId"]), turnID: identity(acp["turnId"]))
    }

    private static func identity(_ value: AGUIValue?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }

    // MARK: Turn identity

    private static let turnSuffix = "#chunks"

    /// The ID of the Pretty turn that starts at a chunk. It depends only on the first chunk's
    /// message ID, so the turn keeps its place and its open state while more chunks arrive.
    static func turnID(firstChunkID: String) -> String { firstChunkID + turnSuffix }

    /// The first chunk's message ID, when `entryID` names a joined turn.
    static func firstChunkID(ofTurn entryID: String) -> String? {
        entryID.hasSuffix(turnSuffix) ? String(entryID.dropLast(turnSuffix.count)) : nil
    }

    /// The original messages of a joined turn, oldest first: the first chunk and each chunk of
    /// the same reply that directly follows it. Nil when `entryID` is not a turn of `messages`.
    static func turn(entryID: String, in messages: [AGUIMessage]) -> ArraySlice<AGUIMessage>? {
        guard let firstID = firstChunkID(ofTurn: entryID),
              let start = messages.firstIndex(where: { $0.id == firstID }),
              let key = key(of: messages[start]) else { return nil }
        var end = start + 1
        while end < messages.count, self.key(of: messages[end]) == key { end += 1 }
        return messages[start..<end]
    }

    /// The text of a turn: each chunk's content end to end.
    static func text(of chunks: some Sequence<AGUIMessage>) -> String {
        chunks.reduce(into: "") { $0 += $1.content ?? "" }
    }
}

extension TranscriptOrigin {
    /// The origin of the entry built from `message`. Nil when the service attached no ACP
    /// reference, as for a message from a harness without one.
    /// - Parameter previous: the key of the message directly before this one.
    init?(message: AGUIMessage, key: ConversationChunks.Key?, previous: ConversationChunks.Key?) {
        guard case .object(let acp)? = message.metadata?["acp"] else { return nil }
        kind = acp["kind"]?.stringValue ?? ""
        sourceIDs = [message.id]
        chunk = key.map { Chunk(text: message.content ?? "", joinsPrevious: $0 == previous) }
        summary = message.role == "user" || message.role == "assistant" ? nil : Self.operationalSummary(kind: kind, acp: acp)
        promptMedia = message.role == "user" ? PromptMediaIndicator(acp: acp) : nil
    }

    /// One line for a session update that reports state: usage, mode, commands, configuration.
    /// Nil for message and tool records, whose text is the content.
    static func operationalSummary(kind: String, acp: [String: AGUIValue]) -> String? {
        guard kind.hasSuffix("_update"), kind != "tool_call_update" else { return nil }
        if case .object(let usage)? = acp["usage"], let used = usage["used"]?.numberValue?.int64Value {
            var line = "Context " + compact(used)
            if let size = usage["size"]?.numberValue?.int64Value, size > 0 { line += " of " + compact(size) }
            line += " tokens"
            if case .object(let cost)? = usage["cost"], let amount = cost["amount"]?.numberValue {
                line += " · " + amount.literal + (cost["currency"]?.stringValue.map { " " + $0 } ?? "")
            }
            return line
        }
        var name = kind.dropLast("_update".count).replacingOccurrences(of: "_", with: " ")
        name = name.prefix(1).uppercased() + name.dropFirst()
        if let mode = acp["modeId"]?.stringValue, !mode.isEmpty { return name + " · " + mode }
        if let count = acp["itemCount"]?.intValue { return name + " · " + String(count) }
        return name
    }

    /// A token count to three figures: 950, 45.2k, 200k, 1.2M. The same in every locale.
    static func compact(_ count: Int64) -> String {
        func scaled(_ unit: Int64, _ suffix: String) -> String {
            let tenths = (count * 10 + unit / 2) / unit
            return String(tenths / 10) + (tenths % 10 == 0 || tenths >= 1000 ? "" : "." + String(tenths % 10)) + suffix
        }
        if count < 1000 { return String(count) }
        // 999,950 and above rounds to 1000k; say 1M.
        return count < 999_950 ? scaled(1000, "k") : scaled(1_000_000, "M")
    }
}

extension TranscriptEntry {
    /// The service messages this entry stands for, oldest first. Empty for an entry that is not
    /// built from a marked message, whose own `id` names its record.
    var sourceIDs: [String] { origin?.sourceIDs ?? [] }

    /// True when the message directly before this entry's is a chunk of the same reply.
    var continuesTurn: Bool { origin?.chunk?.joinsPrevious ?? false }

    /// The entries Pretty shows: `folded` under the Pretty policy, so chunk runs are joined and
    /// an operational note reads as its one-line summary.
    static func conversation(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        folded(entries, policy: .pretty)
    }

    /// The entries a console lays out in `mode`, from the entries built from its messages. Both
    /// renderers call this: `TranscriptView` with `.console`, `PrettyConsoleView` with `.pretty`.
    ///
    /// Console is every entry in the order it arrived, with each run of live chunks of one reply
    /// as one turn; diagnostics, usage notes, orphan results and records with no text keep their
    /// own entry and the service's text. Pretty is the same turns with operational notes
    /// summarised and blank prose left out; it then groups routine entries into activities,
    /// which hold every entry they stand for.
    static func displayed(_ entries: [TranscriptEntry], mode: ConsoleDisplayMode) -> [TranscriptEntry] {
        switch mode {
        case .console: folded(entries, policy: .console)
        case .pretty: folded(entries, policy: .pretty).filter(PrettyContent.isSubstantive)
        }
    }

    /// Joins live chunks into turns. Each run of live chunks of one reply is one assistant turn
    /// whose text is the chunks' content end to end, whitespace included. The turn's ID comes
    /// from its first chunk and its origin lists every chunk's message ID. A turn of only
    /// whitespace is the assistant's record with that exact text and nothing to read. Under a
    /// policy that summarises notes, an operational note reads as its one-line summary. Every
    /// other entry is passed through as it is, in order; none is dropped or moved.
    static func folded(_ entries: [TranscriptEntry], policy: ConversationChunks.DisplayPolicy) -> [TranscriptEntry] {
        guard entries.contains(where: {
            $0.origin?.chunk != nil || (policy.summarisesNotes && $0.origin?.summary != nil)
        }) else { return entries }
        var shown: [TranscriptEntry] = []
        shown.reserveCapacity(entries.count)
        // The open turn. It is held apart so its text grows in place.
        var turn: (id: String, origin: TranscriptOrigin, text: String)?

        func close() {
            guard let open = turn else { return }
            // A reply that is only whitespace has nothing to read as prose. It stays as the
            // assistant's record with no text, as Console shows such a chunk, so its fields are
            // still reached from the turn. The text is kept exactly; whitespace beside other
            // chunks of a reply is part of that reply's prose and is not touched.
            let kind: Kind = open.text.contains(where: { !$0.isWhitespace })
                ? .prose(open.text, fromUser: false)
                : .other(role: "assistant", text: open.text)
            shown.append(TranscriptEntry(id: open.id, kind: kind, origin: open.origin))
            turn = nil
        }

        for entry in entries {
            guard let origin = entry.origin else { close(); shown.append(entry); continue }
            if let chunk = origin.chunk {
                if chunk.joinsPrevious, turn != nil {
                    turn?.text += chunk.text
                    turn?.origin.sourceIDs += origin.sourceIDs
                } else {
                    // The first chunk, or the first one inside a window that starts mid-reply.
                    close()
                    var opened = origin
                    opened.chunk?.joinsPrevious = false
                    turn = (ConversationChunks.turnID(firstChunkID: entry.id), opened, chunk.text)
                }
                continue
            }
            close()
            if policy.summarisesNotes, let summary = origin.summary, case .other(let role, _) = entry.kind {
                shown.append(TranscriptEntry(id: entry.id, kind: .other(role: role, text: summary), origin: origin))
            } else {
                shown.append(entry)
            }
        }
        close()
        return shown
    }

    /// The most recent entries for a request surface: the last `count` of them, where a
    /// streamed reply counts once however many chunks it has, so the window never opens inside
    /// a reply.
    static func recent(_ entries: [TranscriptEntry], count: Int = recentWindow) -> [TranscriptEntry] {
        var start = entries.count, units = 0
        // Walking back, a unit is counted at the entry that opens it, so the walk stops on one.
        while start > 0, units < count {
            start -= 1
            if !entries[start].continuesTurn { units += 1 }
        }
        return Array(entries[start...])
    }
}

extension ConsoleRecordDetail {
    /// The IDs of the service messages that the fields of entry `entryID` show, oldest first.
    /// It follows the lookup `resolve` makes: a joined turn reaches every chunk's message; a
    /// message entry reaches that message; a tool call reaches the message that made the call,
    /// then every result that answers it. Empty when the ID names nothing in `messages`.
    ///
    /// Taken over every entry of `TranscriptEntry.displayed(_:mode:)`, in either mode, the IDs
    /// cover every message: nothing the service sent is out of reach of a disclosure.
    static func messageIDs(entryID: String, in messages: [AGUIMessage]) -> [String] {
        if let chunks = ConversationChunks.turn(entryID: entryID, in: messages) { return chunks.map(\.id) }
        if messages.contains(where: { $0.id == entryID }) { return [entryID] }
        if let calling = messages.first(where: { ($0.toolCalls ?? []).contains { $0.id == entryID } }) {
            return [calling.id] + messages.filter { $0.role == "tool" && $0.toolCallID == entryID }.map(\.id)
        }
        return []
    }

    /// The fields behind a joined turn: the turn as the console reads it, then every chunk's message
    /// exactly as the service sent it, metadata included, in the order they arrived.
    static func turnSections(_ chunks: ArraySlice<AGUIMessage>) -> [Section] {
        let originals: [AGUIValue] = chunks.map { message in
            let fields: AGUIValue = message.allFields
            return fields
        }
        var turn: [String: AGUIValue] = [
            "role": "assistant",
            "content": .string(ConversationChunks.text(of: chunks)),
            "chunkCount": .number(AGUINumber(chunks.count)),
            "messageIds": .array(chunks.map { .string($0.id) })
        ]
        if let first = chunks.first, let key = ConversationChunks.key(of: first) {
            turn["id"] = .string(ConversationChunks.turnID(firstChunkID: first.id))
            if let messageID = key.messageID { turn["acpMessageId"] = .string(messageID) }
            if let turnID = key.turnID { turn["acpTurnId"] = .string(turnID) }
        }
        let count = chunks.count
        return [
            Section(
                id: "turn", title: "Turn",
                provenance: "One assistant reply as this view reads it: the content of \(count) live ACP "
                    + "\(count == 1 ? "chunk" : "chunks") end to end, with nothing trimmed or added. "
                    + "The service sent each chunk as its own message.",
                json: AGUIValue.object(turn).prettyText),
            Section(
                id: "chunks", title: "Chunks",
                provenance: "Commander's AG-UI message for each chunk, in the order they arrived, with its own ID "
                    + "and ACP source reference.",
                json: AGUIValue.array(originals).prettyText)
        ]
    }
}
