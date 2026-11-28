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
// they follow one another directly with the same ACP message and turn identity. Live
// `agent_thought_chunk` text the provider emitted is joined the same way into one thought, which
// never joins a reply; it keeps the role the service gave it, and Pretty shows it as Thinking. A message
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
    /// The provider's own message ID, when the reference carries one. A thought's stored times
    /// are kept under it.
    var messageID: String? = nil
    /// How many items the reference counts, such as a plan's entries.
    var itemCount: Int? = nil
    /// Set on the service's own compaction message: its status and the record behind it. Pretty
    /// draws it as the compaction row; see `PrettyCompaction`.
    var compaction: CompactionMark? = nil
    /// Set on a live reply chunk that is a resource link or a resource: the record behind it.
    /// Pretty draws what that record holds in the reply; see `ReplyAttachment`.
    var replyAttachment: ReplyAttachmentMark? = nil
    /// Set on a provider notice: the level its reference states, when it states one. Pretty keeps
    /// a warning, an error and a notice with no level in the open; see `NoticeMark`.
    var notice: NoticeMark? = nil
    /// Set on an ACP `plan_update` or `plan_removed` event the service could tie to one provider
    /// plan: its fingerprint of the provider session and that plan's own ID. Two events are about
    /// the same plan only when these are equal. It is opaque, and is never drawn, spoken or copied.
    var planIdentity: String? = nil
    /// The reference's source is exactly `live`: the event was observed by this console, so its
    /// sequence is the one a stored plan record was kept under. A reopened worker's console is
    /// provider history numbered afresh, while the records kept from its earlier live events
    /// remain under their old sequences; such an event's sequence names no record.
    var planIsLive = false
}

enum ConversationChunks {
    static let liveSource = "live"
    static let chunkKind = "agent_message_chunk"
    /// A piece of the reasoning the provider emitted, as ACP names it.
    static let thoughtKind = "agent_thought_chunk"

    /// The reply a live chunk belongs to. Two chunks join only when their keys are equal, so a
    /// chunk with an ACP message ID never joins one without, or one with another ID.
    struct Key: Equatable, Sendable {
        let messageID: String?
        let turnID: String?
        /// A thought chunk. A thought and a reply never join.
        var isThought = false
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

    /// The key of a live assistant text chunk, or of a live thought chunk from any role but the
    /// developer's. Nil for every other message: a tool call or result, structured content,
    /// provider history, or a message with no ACP mark.
    static func key(of message: AGUIMessage) -> Key? {
        guard message.role != "user", message.toolCallID == nil, message.toolCalls?.isEmpty ?? true,
              case .object(let acp)? = message.metadata?["acp"],
              acp["source"]?.stringValue == liveSource,
              acp["contentType"]?.stringValue ?? "text" == "text",
              !message.hasStructuredContent else { return nil }
        let kind = acp["kind"]?.stringValue
        let isThought: Bool
        if kind == chunkKind, message.role == "assistant" {
            isThought = false
        } else if kind == thoughtKind {
            isThought = true
        } else {
            return nil
        }
        return Key(messageID: identity(acp["messageId"]), turnID: identity(acp["turnId"]), isThought: isThought)
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
        messageID = acp["messageId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        itemCount = acp["itemCount"]?.intValue
        compaction = CompactionMark(message: message, acp: acp)
        replyAttachment = ReplyAttachmentMark(message: message, acp: acp)
        notice = NoticeMark(message: message, acp: acp)
        planIdentity = Self.planIdentity(kind: kind, acp: acp)
        planIsLive = planIdentity != nil && acp["source"]?.stringValue == ConversationChunks.liveSource
    }

    /// The ACP session update that states a plan as it now is, and the one that removes a plan.
    static let planUpdateKind = "plan_update"
    static let planRemovedKind = "plan_removed"

    /// The plan an event is about: `planIdentity` on a `plan_update` or `plan_removed` reference,
    /// when it is exactly 64 lower-case hexadecimal digits. Nil for any other kind or value; the
    /// event is then the folded session update it has always been.
    static func planIdentity(kind: String, acp: [String: AGUIValue]) -> String? {
        guard kind == planUpdateKind || kind == planRemovedKind,
              let text = acp["planIdentity"]?.stringValue, text.utf8.count == 64 else { return nil }
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9"), letters = UInt8(ascii: "a")...UInt8(ascii: "f")
        return text.utf8.allSatisfy { digits.contains($0) || letters.contains($0) } ? text : nil
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

    /// A token count to three figures: 950, 45.2k, 200k, 1.2M, 3.4B. The same in every locale.
    /// Any Int64 is formatted without overflow; a negative count is written in full.
    static func compact(_ count: Int64) -> String {
        func scaled(_ unit: Int64, _ suffix: String) -> String {
            // Divide first, so the largest counts cannot overflow; round half up to tenths.
            let step = unit / 10
            let (quotient, remainder) = count.quotientAndRemainder(dividingBy: step)
            let tenths = quotient + (remainder >= step - remainder ? 1 : 0)
            return String(tenths / 10) + (tenths % 10 == 0 || tenths >= 1000 ? "" : "." + String(tenths % 10)) + suffix
        }
        if count < 1000 { return String(count) }
        // A count that would round up to 1000 of a unit is written in the next unit.
        if count < 999_950 { return scaled(1000, "k") }
        if count < 999_950_000 { return scaled(1_000_000, "M") }
        return scaled(1_000_000_000, "B")
    }
}

extension TranscriptEntry {
    /// The service messages this entry stands for, oldest first. Empty for an entry that is not
    /// built from a marked message, whose own `id` names its record.
    var sourceIDs: [String] { origin?.sourceIDs ?? [] }

    /// True when the message directly before this entry's is a chunk of the same reply.
    var continuesTurn: Bool { origin?.chunk?.joinsPrevious ?? false }

    /// Reasoning the provider emitted as live ACP thought chunks, joined like a reply.
    var isThought: Bool { origin?.kind == ConversationChunks.thoughtKind }

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
        // Terminal mode's fallback is the Console transcript.
        case .terminal, .console: folded(entries, policy: .console)
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
        // The open turn. It is held apart so its text grows in place. `thoughtRole` is the role
        // of a thought's first chunk, nil for a reply.
        var turn: (id: String, origin: TranscriptOrigin, text: String, thoughtRole: String?)?

        func close() {
            guard let open = turn else { return }
            // A thought stays the service's record of its role, text exactly as joined.
            if let role = open.thoughtRole {
                shown.append(TranscriptEntry(id: open.id, kind: .other(role: role, text: open.text), origin: open.origin))
                turn = nil
                return
            }
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
                    var thoughtRole: String?
                    if opened.kind == ConversationChunks.thoughtKind {
                        if case .other(let role, _) = entry.kind { thoughtRole = role } else { thoughtRole = "assistant" }
                    }
                    turn = (ConversationChunks.turnID(firstChunkID: entry.id), opened, chunk.text, thoughtRole)
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

    /// The current conversation turn: the developer's latest prompt and everything after it, or
    /// every entry when there is no prompt. A prompt is never a chunk of a streamed reply, so the
    /// turn never opens inside one. Pretty in the PiP reads its items from this
    /// (`ActivityConversation.recent`); Console and Terminal keep `recent(_:count:)`.
    static func currentTurn(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        guard let prompt = entries.lastIndex(where: \.isFromUser), prompt > 0 else { return entries }
        return Array(entries[prompt...])
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
        let isThought = chunks.first.flatMap { ConversationChunks.key(of: $0) }?.isThought ?? false
        var turn: [String: AGUIValue] = [
            "role": .string(chunks.first?.role ?? "assistant"),
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
                provenance: (isThought ? "The provider's emitted thinking" : "One assistant reply")
                    + " as this view reads it: the content of \(count) live ACP "
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

// MARK: - Activity events

/// What Pretty shows for an activity line: a symbol, a short label and the event's readable text.
/// It is built from the routing the transcript already did: the entry's role and text, and its
/// ACP kind and one-line summary. Nothing is inferred beyond them, and nothing here answers or
/// acts on anything; the entry's fields and source stay where its row's action reaches them.
///
/// Recognised: `usage_update` Context, `current_mode_update` Mode, `available_commands_update`
/// Commands, `session_info_update` Session, `config_option_update` Config, `plan` Plan, and the
/// service's relayed `[Provider stderr]`, `[Provider stdout]`, `[Provider event: …]` and
/// `[Service …]` text. A provider `notice` is read by its reference's level alone (`NoticeMark`):
/// Warning, Error or Notice, with its title as sent. Any other record with an ACP kind is named
/// by that kind and shows its own text. A record with no text has an empty detail: its content is
/// only in its fields.
struct ActivityEvent: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case quiet
        /// May need the developer: harness stderr, a provider event about a permission, or a
        /// notice the provider sent as a warning or an error.
        case attention
    }

    let symbol: String
    let label: String
    let detail: String
    let tone: Tone
    /// The event joins the group of finished lines beside it. False for an event that stays in
    /// the open at its own position: every attention event, and a notice with no stated level.
    let folds: Bool

    var accessibilityLabel: String {
        label + ": " + (detail.isEmpty ? "no text, content in its fields" : detail)
    }

    /// Nil for an entry that is not activity: a prompt, reply, tool, result or thought, and a
    /// note with neither an ACP kind nor a relayed marker, which keeps its role note.
    /// - Parameter hidesSecrets: the transcript setting (`ToolDetailStore.hidesSecrets`). It
    ///   masks a provider notice's title; every other event is unchanged by it.
    init?(entry: TranscriptEntry, hidesSecrets: Bool = false) {
        guard case .other(let role, let text) = entry.kind, !entry.isThought,
              role != "user", role != "assistant" else { return nil }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = entry.origin?.kind ?? ""

        if let notice = entry.origin?.notice {
            // Judged by its reference alone, before any text is read.
            self.init(notice: notice, body: body, hidesSecrets: hidesSecrets)
        } else if let rest = Self.after("[Provider stderr]", in: body) {
            self.init(symbol: "exclamationmark.bubble", label: "stderr", detail: rest, tone: .attention)
        } else if let rest = Self.after("[Provider stdout]", in: body) {
            self.init(symbol: "text.alignleft", label: "stdout", detail: rest, tone: .quiet)
        } else if body.hasPrefix("[Provider event:"), let close = body.firstIndex(of: "]") {
            let name = body[body.index(body.startIndex, offsetBy: "[Provider event:".count)..<close]
                .trimmingCharacters(in: .whitespaces)
            let rest = body[body.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == Self.permissionRequested {
                // The live approval request. Its question is the one the request form answers;
                // the choice list Commander appended for text surfaces is left out here, since the
                // form draws the choices. The record and its fields keep the text as sent.
                let question = Self.withoutChoiceInstructions(rest)
                self.init(symbol: "hand.raised", label: "Approval",
                          detail: question.isEmpty ? "requested" : question, tone: .attention)
                return
            }
            let detail = [name, rest].filter { !$0.isEmpty }.joined(separator: " · ")
            let permission = detail.range(of: "permission", options: .caseInsensitive) != nil
            self.init(symbol: permission ? "hand.raised" : "bolt.horizontal", label: "Provider",
                      detail: detail, tone: permission ? .attention : .quiet)
        } else if body.hasPrefix("[Service "), let close = body.firstIndex(of: "]") {
            let name = body[body.index(body.startIndex, offsetBy: "[Service ".count)..<close]
            let rest = body[body.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(symbol: "gearshape", label: "Service",
                      detail: [String(name), rest].filter { !$0.isEmpty }.joined(separator: " · "), tone: .quiet)
        } else if !kind.isEmpty {
            let known: (symbol: String, label: String)? = switch kind {
            case "usage_update": ("gauge.with.dots.needle.33percent", "Context")
            case "current_mode_update": ("slider.horizontal.3", "Mode")
            case "available_commands_update": ("command", "Commands")
            case "session_info_update": ("info.circle", "Session")
            case "config_option_update": ("switch.2", "Config")
            case "plan": ("list.bullet", "Plan")
            default: nil
            }
            let label = known?.label ?? Self.humanized(kind)
            self.init(symbol: known?.symbol ?? "circle.dashed", label: label,
                      detail: Self.detail(body, kind: kind, label: label), tone: .quiet)
        } else {
            return nil
        }
    }

    /// - Parameter folds: nil folds a quiet event and keeps an attention event in the open.
    init(symbol: String, label: String, detail: String, tone: Tone, folds: Bool? = nil) {
        self.symbol = symbol
        self.label = label
        self.detail = detail
        self.tone = tone
        self.folds = folds ?? (tone == .quiet)
    }

    /// The provider event name the ACP runner gives a live input request.
    static let permissionRequested = "Permission requested"
    /// The line Commander appends to a question that offers choices, before one `Label [id]` line
    /// per choice. The same text `RequestPresentation.promptWithoutChoiceList` removes.
    static let choiceInstructions = "\nReply with one of the IDs in brackets."

    /// `question` without Commander's appended choice instructions, only when they are exactly
    /// there: the instruction line, then one or more `Label [id]` lines to the end and nothing
    /// else. Any other text, a provider's own brackets included, is returned unchanged.
    static func withoutChoiceInstructions(_ question: String) -> String {
        guard let range = question.range(of: choiceInstructions, options: .backwards) else { return question }
        let tail = question[range.upperBound...]
        guard tail.hasPrefix("\n") else { return question }
        let lines = tail.dropFirst().split(separator: "\n", omittingEmptySubsequences: false)
        let isChoice: (Substring) -> Bool = { line in
            guard line.hasSuffix("]"), let open = line.range(of: " [", options: .backwards) else { return false }
            let label = line[..<open.lowerBound]
            let id = line[open.upperBound..<line.index(before: line.endIndex)]
            return !label.trimmingCharacters(in: .whitespaces).isEmpty && !id.isEmpty && !id.contains("]")
        }
        guard !lines.isEmpty, lines.allSatisfy(isChoice) else { return question }
        return question[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text after `marker`, trimmed. Nil when `body` does not start with it.
    private static func after(_ marker: String, in body: String) -> String? {
        guard body.hasPrefix(marker) else { return nil }
        return body.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The readable part of a record's text: without a leading `[ACP kind]` marker, and without
    /// the label the summary already starts with (`Context 13.6k …` reads `13.6k …`).
    private static func detail(_ body: String, kind: String, label: String) -> String {
        var text = Substring(body)
        let marker = "[ACP " + kind + "]"
        if text.hasPrefix(marker) { text = text.dropFirst(marker.count) }
        text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix(label) {
            let rest = text.dropFirst(label.count)
            if rest.isEmpty || rest.first == " " {
                text = Substring(rest.trimmingCharacters(in: .whitespaces))
                if text.hasPrefix("·") { text = Substring(text.dropFirst().trimmingCharacters(in: .whitespaces)) }
            }
        }
        return String(text)
    }

    /// `tool_call_update` reads `Tool call update`; `acp.prompt_result` reads `Prompt result`.
    private static func humanized(_ kind: String) -> String {
        let last = kind.split(separator: ".").last.map(String.init) ?? kind
        let words = last.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
