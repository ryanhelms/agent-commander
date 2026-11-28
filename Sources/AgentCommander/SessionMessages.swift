import Foundation
import Observation
import SwiftUI

// SESSION MESSAGES (DESIGN.md, "Pretty transcript"; spec section H, "ACP session_message")
// Another session may send this one a message. The provider reports it as `session_message`, an
// upsert of the whole message, and `session_message_chunk`, one more piece of its text. The
// service's console event for each holds a marker, the kind and the provider's message ID; the
// update itself, with the sender and the text, stays behind the event's live source cursor.
//
//   Values          SessionMessageMark     what the event says: kind, message ID, cursor, turn
//                   SessionMessagePatch    what the source record at that cursor changes
//                   SessionMessageDetail   what the store knows about one reference
//                   SessionMessage         one incoming message, as its references leave it
//                   SessionMessages        the messages of one console, each at its first reference
//                   SessionMessageWords    the row's text, with secret-looking values hidden
//   Feature layer   SessionMessageStore    one bounded read of each worker's turn, shared
//   Boundary        SessionMessageReader   the source read, as a closure
//   Molecule        PrettySessionMessage   "Message from sender", then the text beside the report rule
//
// Nothing is inferred. A reference is read only from the original ACP update at its exact cursor:
// an update of the stated kind and message ID, in the stated turn, whose record names its session.
// A message is the references that name one session and one message ID, applied in the order they
// were sent. The event's text, a neighbouring row, a reused sequence and another worker's record
// are never read in their place. A reference whose record is not read keeps its place as a folded
// session update, and so does every later reference of that message ID. That folded line reads
// "Session message" and holds no text of the update (`ActivityEvent.sessionMessageLabel`).
// Nothing is fetched.
//
// For an ACP v2 session the service keeps the updates of one message in one message, lists their
// references in `metadata.acpSources`, and writes both kinds under `session_message` with an
// operation. Each reference is still read from its own record, whose update has the wire kind.

/// What the service's event says about one session message update.
struct SessionMessageMark: Hashable, Sendable {
    enum Kind: String, Sendable {
        /// An upsert: it may replace or clear the content and name the sender and the recipient.
        case snapshot = "session_message"
        /// One more piece of text, appended.
        case chunk = "session_message_chunk"
    }

    let kind: Kind
    /// The provider's ID of the message in the enclosing session's transcript, exactly as sent.
    let messageID: String
    /// The cursor of the update's record in the worker's live source. The runner starts each
    /// cursor with an identifier it draws at random when it starts, so a later run's record
    /// never sits at an earlier run's cursor.
    let cursor: String
    /// The turn of that record, which narrows the read. Nil outside a turn.
    let turnID: String?

    /// Reads one reference. Nil unless it is a live session message update with a message ID and
    /// a cursor. `kind` is the kind of the update on the wire, which the record must have:
    ///
    /// - `session_message` with no operation, or with `replace`: a snapshot.
    /// - `session_message_chunk` with no operation, or with `append`: a chunk.
    /// - `session_message` with `append`, as the service writes a chunk of an ACP v2 session
    ///   under the message's normalised kind: a chunk.
    ///
    /// Any other pairing is not marked. A chunk must state text content; a chunk of any other
    /// content type is not marked and stays a folded session update.
    init?(reference acp: [String: AGUIValue]) {
        guard acp["source"]?.stringValue == ConversationChunks.liveSource,
              let stated = acp["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let id = acp["messageId"]?.stringValue, !id.isEmpty,
              let cursor = acp["cursor"]?.stringValue, !cursor.isEmpty else { return nil }
        let kind: Kind
        switch (stated, acp["messageOp"]) {
        case (.snapshot, nil), (.snapshot, .string("replace")?): kind = .snapshot
        case (.chunk, nil), (.chunk, .string("append")?), (.snapshot, .string("append")?): kind = .chunk
        default: return nil
        }
        switch (kind, acp["contentType"]) {
        case (.chunk, .string("text")?), (.snapshot, nil), (.snapshot, .string("text")?): break
        default: return nil
        }
        self.kind = kind
        messageID = id
        self.cursor = cursor
        turnID = acp["turnId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The references of one service message, in the order they arrived. The service may keep
    /// several updates of one message in a single message: `metadata.acpSources` then lists each
    /// reference in order, the latest among them, and `metadata.acp` is the latest.
    ///
    /// Empty unless every listed reference is a session message update of one message ID and the
    /// latest is among them. A list that holds anything else is not read in part. A message with
    /// no ACP reference is never marked, whatever its text says.
    static func marks(message: AGUIMessage, acp: [String: AGUIValue]) -> [SessionMessageMark] {
        guard message.role != "user", message.role != "tool", message.toolCallID == nil,
              message.toolCalls?.isEmpty ?? true,
              let latest = SessionMessageMark(reference: acp) else { return [] }
        guard let listed = message.metadata?["acpSources"]?.arrayValue, !listed.isEmpty else { return [latest] }
        var marks: [SessionMessageMark] = []
        for value in listed {
            guard let fields = value.objectValue, let mark = SessionMessageMark(reference: fields),
                  mark.messageID == latest.messageID else { return [] }
            if !marks.contains(mark) { marks.append(mark) }
        }
        return marks.contains(latest) ? marks : []
    }
}

/// What one source record changes in a session message.
struct SessionMessagePatch: Equatable, Sendable {
    /// A member of an upsert: left out, sent as `null`, or sent with a value.
    enum Change: Equatable, Sendable {
        case omitted
        case cleared
        case set(String)
    }

    let kind: SessionMessageMark.Kind
    /// The session the record's envelope names: the transcript the message was observed in.
    let session: NativeSession
    let messageID: String
    let cursor: String
    /// The record's turn. Empty outside a turn.
    let turnID: String
    /// A snapshot: omitted leaves the text as it is, cleared (`null` or `[]`) empties it, a value
    /// replaces all of it. A chunk: the text to append.
    var content: Change = .omitted
    /// The sending session. Only a snapshot's `senderSessionId` is read.
    var sender: Change = .omitted
    /// The receiving session, from a snapshot's `recipientSessionId`.
    var recipient: Change = .omitted
    /// A snapshot's `recipientMessageId`. The provider sets it only on the sender's own view.
    var recipientMessage: Change = .omitted

    /// Reads one source record. Nil unless it names its session and a cursor and carries the
    /// original update of a session message with a message ID. A snapshot's content must be
    /// absent, `null` or an array of text parts; a chunk's must be one text part. A record with
    /// any other content, or a member of the wrong type, is not read at all.
    init?(observation: SourceObservation) {
        guard !observation.cursor.isEmpty, let session = observation.session, !session.sessionID.isEmpty,
              let envelope = try? AGUIValue(json: observation.record) else { return nil }
        // A record that names another record as its original is not this update's.
        if let owner = envelope["sourceCursor"]?.stringValue, !owner.isEmpty, owner != observation.cursor { return nil }
        guard let source = (envelope["sourceRecord"] ?? envelope["extension"])?.objectValue,
              SourceAttachment.baseType(source["mediaType"]?.stringValue ?? "") == "application/json",
              let encoded = source["data"]?.stringValue, !encoded.isEmpty,
              let data = RecordBase64.decode(encoded[...].utf8),
              let original = try? AGUIValue(json: data) else { return nil }
        let update: [String: AGUIValue]
        switch source["type"]?.stringValue {
        case ReplyAttachment.paramsType?:
            // The provider's notification names its session: it must be the envelope's.
            guard original["sessionId"]?.stringValue == session.sessionID,
                  let inner = original["update"]?.objectValue else { return nil }
            update = inner
        case ReplyAttachment.updateType?:
            guard let fields = original.objectValue else { return nil }
            update = fields
        default:
            return nil
        }
        guard let kind = update["sessionUpdate"]?.stringValue.flatMap(SessionMessageMark.Kind.init(rawValue:)),
              let id = update["messageId"]?.stringValue, !id.isEmpty else { return nil }
        self.kind = kind
        self.session = session
        messageID = id
        cursor = observation.cursor
        turnID = observation.turnID

        func text(_ part: AGUIValue) -> String? {
            guard part["type"]?.stringValue == "text" else { return nil }
            return part["text"]?.stringValue
        }
        /// A session or message ID member. Nil when it is neither absent, `null` nor a string.
        func identity(_ key: String) -> Change? {
            switch update[key] {
            case nil: .omitted
            case .null?: .cleared
            case .string(let value)?: value.contains(where: { !$0.isWhitespace }) ? .set(value) : .cleared
            default: nil
            }
        }
        switch kind {
        case .chunk:
            guard let piece = update["content"].flatMap(text) else { return nil }
            content = .set(piece)
        case .snapshot:
            switch update["content"] {
            case nil: content = .omitted
            case .null?: content = .cleared
            case .array(let parts)?:
                var joined = ""
                for part in parts {
                    guard let piece = text(part) else { return nil }
                    joined += piece
                }
                content = parts.isEmpty ? .cleared : .set(joined)
            default: return nil
            }
            guard let sender = identity("senderSessionId"), let recipient = identity("recipientSessionId"),
                  let recipientMessage = identity("recipientMessageId") else { return nil }
            self.sender = sender
            self.recipient = recipient
            self.recipientMessage = recipientMessage
        }
        if case .set(let value) = content, value.utf8.count > ReplyAttachment.textLimit { return nil }
    }

    /// The record is the one `mark` names: the same kind and message ID, at its cursor and turn.
    func answers(_ mark: SessionMessageMark) -> Bool {
        kind == mark.kind && messageID == mark.messageID && cursor == mark.cursor && turnID == (mark.turnID ?? "")
    }
}

/// What is known about the record behind one reference.
enum SessionMessageDetail: Equatable, Sendable {
    /// The record was read and is the reference's own.
    case patch(SessionMessagePatch)
    /// No usable record is kept at the cursor: none after two reads, several, or another update.
    case missing
    /// A read is on its way. The reference changes nothing until it answers.
    case awaited
}

/// One incoming message from another session, as its references leave it.
struct SessionMessage: Identifiable, Equatable {
    /// From the first reference kept, so the row keeps its place while later ones arrive.
    let id: String
    let session: NativeSession
    let messageID: String
    /// The references drawn as this row, in the order sent. The first is the row's place.
    var entries: [TranscriptEntry]
    /// The sending session, as the provider names it. Nil when it names none.
    var sender: String?
    /// The text, exactly as the references leave it.
    var text: String
}

/// The session messages of one console. Each is drawn once, at the first of its references that
/// was read; its later references change it there.
struct SessionMessages {
    /// The message drawn at an entry, by that entry's ID.
    private(set) var anchored: [String: SessionMessage] = [:]
    /// Entries a message's row stands for. They are not drawn again.
    private(set) var absorbed: Set<String> = []

    static let none = SessionMessages()

    private init() {}

    /// Reads the references of `entries` in order.
    ///
    /// - A reference whose record was read is applied to the message its record names: its
    ///   session and its message ID. Two messages with the same ID in two sessions stay apart.
    /// - A reference whose read has not answered is not applied, and neither is any later one of
    ///   its message ID, so text is never joined out of order. It waits in the row of the one
    ///   message that has that ID, when there is exactly one.
    /// - A reference with no usable record stays a folded session update, and so does every later
    ///   reference of its message ID: what they would change is not known.
    /// - A reference sent twice is applied once.
    /// - An entry that stands for several references is one row, at that entry. Its references
    ///   are applied in the order they arrived, up to the first still awaited. When one of them
    ///   has no usable record, or their records name two sessions, none of them is applied.
    /// - A message the records say this session sent, or sent to another session, is not drawn:
    ///   its references stay folded session updates.
    init(entries: [TranscriptEntry], detail: (SessionMessageMark) -> SessionMessageDetail?) {
        struct Key: Hashable {
            let session: NativeSession
            let messageID: String
        }
        struct State {
            var entries: [TranscriptEntry] = []
            var sender: String?
            var recipient: String?
            var recipientMessage: String?
            var text = ""
        }
        var states: [Key: State] = [:]
        var order: [Key] = []
        var applied: Set<SessionMessageMark> = []
        var held: Set<String> = []
        var blocked: Set<String> = []

        func set(_ change: SessionMessagePatch.Change, _ value: inout String?) {
            switch change {
            case .omitted: break
            case .cleared: value = nil
            case .set(let text): value = text
            }
        }

        for entry in entries {
            let marks = entry.sessionMessages
            guard let id = marks.first?.messageID, !blocked.contains(id) else { continue }
            // The entry's references in order: the records read, up to the first still awaited.
            var ready: [(mark: SessionMessageMark, patch: SessionMessagePatch)] = []
            var sessions: Set<NativeSession> = []
            var awaits = false, unusable = false
            for mark in marks {
                switch detail(mark) {
                case .patch(let patch)? where patch.answers(mark):
                    sessions.insert(patch.session)
                    if !awaits { ready.append((mark, patch)) }
                case .awaited?: awaits = true
                default: unusable = true
                }
            }
            // One entry is one message: a reference with no usable record, or records that name
            // two sessions, leave the whole entry a session update.
            guard !unusable, sessions.count <= 1 else {
                blocked.insert(id)
                continue
            }
            guard !held.contains(id), let session = sessions.first, !ready.isEmpty else {
                // Not applied yet, or behind a reference that is still awaited.
                held.insert(id)
                let candidates = order.filter { $0.messageID == id }
                if candidates.count == 1 { states[candidates[0]]?.entries.append(entry) }
                continue
            }
            if awaits { held.insert(id) }
            let key = Key(session: session, messageID: id)
            var state = states[key] ?? State()
            for (mark, patch) in ready where applied.insert(mark).inserted {
                switch (patch.kind, patch.content) {
                case (_, .omitted): break
                case (_, .cleared): state.text = ""
                case (.snapshot, .set(let text)): state.text = text
                case (.chunk, .set(let text)): state.text += text
                }
                set(patch.sender, &state.sender)
                set(patch.recipient, &state.recipient)
                set(patch.recipientMessage, &state.recipientMessage)
            }
            guard state.text.utf8.count <= ReplyAttachment.textLimit else {
                blocked.insert(id)
                continue
            }
            if states[key] == nil { order.append(key) }
            state.entries.append(entry)
            states[key] = state
        }

        for key in order {
            guard let state = states[key], let first = state.entries.first else { continue }
            // The enclosing session sent it, or it is addressed elsewhere: not an incoming message.
            let source = key.session.sessionID
            if state.sender == source || state.recipientMessage != nil { continue }
            if let recipient = state.recipient, recipient != source { continue }
            anchored[first.id] = SessionMessage(id: first.id + "#message", session: key.session, messageID: key.messageID,
                                                entries: state.entries, sender: state.sender, text: state.text)
            absorbed.formUnion(state.entries.dropFirst().map(\.id))
        }
    }
}

extension TranscriptEntry {
    /// The marks of the session message updates this entry stands for, in the order they arrived.
    /// Empty for every other entry.
    var sessionMessages: [SessionMessageMark] {
        guard case .other = kind else { return [] }
        return origin?.sessionMessages ?? []
    }
}

/// The text of a message's row as it is drawn, selected and said by VoiceOver: with the values
/// that look like secrets hidden when the saved setting hides them. The text is masked whole,
/// after its pieces are joined, so a value split across two chunks is hidden too.
struct SessionMessageWords: Equatable {
    /// The approved line for a message whose sender the provider does not name.
    static let unnamed = "Message from another session"
    static let lead = "Message from "

    /// The sender as shown. Nil reads `unnamed`.
    let sender: String?
    let text: String
    /// How many values were hidden, in the sender and the text together.
    let hidden: Int

    init(message: SessionMessage, hidesSecrets: Bool) {
        guard hidesSecrets else {
            sender = message.sender
            text = message.text
            hidden = 0
            return
        }
        let name = message.sender.map { SecretValues.masked(prose: $0) }
        let body = SecretValues.masked(prose: message.text)
        sender = name?.text
        text = body.text
        hidden = (name?.count ?? 0) + body.count
    }

    var heading: String { sender.map { Self.lead + $0 } ?? Self.unnamed }
    var hasText: Bool { text.contains(where: { !$0.isWhitespace }) }
    var hiddenNote: String? { hidden == 0 ? nil : hidden == 1 ? "1 value hidden" : "\(hidden) values hidden" }
    /// What VoiceOver says for the row: the same words the row draws, never the text as sent.
    var accessibilityLabel: String { [heading, hasText ? text : nil, hiddenNote].compactMap { $0 }.joined(separator: ". ") }
}

// MARK: - Feature layer

/// One page of a worker's live source, narrowed to `turnID` when it is given. `pageCursor` is
/// the `nextCursor` of the page before it, nil for the first.
typealias SessionMessageReader = @Sendable (_ workerID: String, _ turnID: String?,
                                            _ pageCursor: String?) async throws -> SourcePage

/// The record behind each session message reference. It follows `ReplyAttachmentStore`: every
/// surface that draws a reference shares one read, the store owns that read's task, and a change
/// of service drops what the last service held.
///
/// One read serves every reference of a worker's turn. It keeps the session message records it
/// passes, so a reference whose record was already passed asks for nothing. A later read starts
/// at the last page the one before it reached, not at the first. A record that is not there yet
/// is read for once more after `pause`, and only then counted as missing. Nothing is read on a
/// timer, and at most `concurrentReads` turns are read at once.
@MainActor @Observable
final class SessionMessageStore {
    /// One selection of a worker's live source: one turn, or every record when `turnID` is nil.
    private struct Scope: Hashable {
        let worker: String
        let turnID: String?
    }

    private struct Key: Hashable {
        let worker: String
        let mark: SessionMessageMark
    }

    private struct Records {
        var patches: [String: SessionMessagePatch] = [:]
        /// Cursors that hold another kind of record, or two different ones.
        var rejected: Set<String> = []
        /// Cursors in the order first kept, oldest first.
        var order: [String] = []
        /// The page token of the last page read. The next read starts there.
        var resume: String?
        var touched = 0
        /// The `cost` of the patches kept.
        var bytes = 0

        mutating func drop(_ cursor: String) {
            if let patch = patches.removeValue(forKey: cursor) { bytes -= SessionMessageStore.cost(patch) }
        }
    }

    private struct Read {
        let id: Int
        let task: Task<Void, Never>
    }

    /// What one walk of a scope's pages passed: each record's cursor, and its patch when it is
    /// a session message update.
    private struct Walk: Sendable {
        var records: [(cursor: String, patch: SessionMessagePatch?)] = []
        var resume: String?
    }

    typealias Pause = @Sendable () async throws -> Void

    /// Turns read at once.
    nonisolated static let concurrentReads = 2
    /// Session message records kept for one turn. The oldest are let go first.
    nonisolated static let recordLimit = 512
    /// Bytes of records kept for one turn, counted by `cost`. The oldest are let go first.
    nonisolated static let scopeByteLimit = 1 << 20
    /// Turns kept. The ones asked for longest ago are let go first, never one still being drawn.
    nonisolated static let scopeLimit = 32
    /// Bytes of records kept in all. Beyond it, turns no console is drawing are let go.
    nonisolated static let byteLimit = 8 << 20

    /// What a kept record is counted as: its text and names, and a fixed share for the rest.
    nonisolated static func cost(_ patch: SessionMessagePatch) -> Int {
        func size(_ change: SessionMessagePatch.Change) -> Int {
            if case .set(let text) = change { text.utf8.count } else { 0 }
        }
        return 256 + patch.cursor.utf8.count + patch.turnID.utf8.count + patch.messageID.utf8.count
            + patch.session.sessionID.utf8.count + patch.session.harnessInstance.utf8.count
            + size(patch.content) + size(patch.sender) + size(patch.recipient) + size(patch.recipientMessage)
    }

    private var scopes: [Scope: Records] = [:]
    /// References with no usable record after two reads. Not asked for again.
    private var missing: Set<Key> = []
    /// References whose read failed. Each asks again when it is next drawn.
    private var failed: Set<Key> = []
    @ObservationIgnored private var wanted: [Scope: Set<SessionMessageMark>] = [:]
    @ObservationIgnored private var tries: [Key: Int] = [:]
    @ObservationIgnored private var reading: [Scope: Read] = [:]
    @ObservationIgnored private var lastRead = 0
    @ObservationIgnored private var clock = 0
    /// Changes when the service does. A read of the last service finds another value and stops.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let read: SessionMessageReader
    @ObservationIgnored private let pause: Pause

    init(read: @escaping SessionMessageReader,
         pause: @escaping Pause = { try await Task.sleep(for: ReplyAttachmentStore.rereadDelay) }) {
        self.read = read
        self.pause = pause
    }

    /// A store holding fixed records, for previews and renders. It reads nothing.
    init(fixed: [String: [SessionMessagePatch]]) {
        pause = {}
        read = { _, _, _ in SourcePage(observations: [], nextCursor: nil) }
        for (worker, patches) in fixed {
            for patch in patches {
                let scope = Scope(worker: worker, turnID: patch.turnID.isEmpty ? nil : patch.turnID)
                var records = scopes[scope] ?? Records()
                records.drop(patch.cursor)
                records.patches[patch.cursor] = patch
                records.bytes += Self.cost(patch)
                scopes[scope] = records
            }
        }
    }

    /// What is known about the record behind `mark`. A record that is kept answers at once.
    func detail(worker: String, mark: SessionMessageMark) -> SessionMessageDetail? {
        if let records = scopes[Scope(worker: worker, turnID: mark.turnID)] {
            if records.rejected.contains(mark.cursor) { return .missing }
            if let patch = records.patches[mark.cursor] { return patch.answers(mark) ? .patch(patch) : .missing }
        }
        let key = Key(worker: worker, mark: mark)
        if missing.contains(key) { return .missing }
        return failed.contains(key) ? nil : .awaited
    }

    /// Reads the records behind `marks`, which are in the order sent. Returns when every one is
    /// read, counted as missing, or its read failed. A failed or cancelled read is forgotten, so
    /// its references ask again when they are next drawn.
    func load(worker: String, marks: [SessionMessageMark]) async {
        guard !worker.isEmpty else { return }
        clock += 1
        var asked: [Scope] = []
        for mark in marks {
            let scope = Scope(worker: worker, turnID: mark.turnID), key = Key(worker: worker, mark: mark)
            if !asked.contains(scope) { asked.append(scope) }
            if failed.contains(key) { failed.remove(key) }
            if detail(worker: worker, mark: mark) == .awaited { wanted[scope, default: []].insert(mark) }
        }
        for scope in asked where scopes[scope] != nil { scopes[scope]?.touched = clock }
        trim(keeping: Set(asked))
        // The latest turn first: it is the one being read.
        let tasks = asked.reversed().compactMap { scope in
            wanted[scope]?.isEmpty == false ? start(scope) : reading[scope]?.task
        }
        for task in tasks { await task.value }
    }

    /// The selected service changed: what the last one held is dropped and its reads in flight
    /// are cancelled and let go, so a reference may be read from the new service at once.
    func serviceChanged() {
        generation += 1
        for shared in reading.values { shared.task.cancel() }
        reading = [:]
        scopes = [:]
        missing = []
        failed = []
        wanted = [:]
        tries = [:]
        active = 0
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    // MARK: Reading

    private func start(_ scope: Scope) -> Task<Void, Never> {
        if let shared = reading[scope] { return shared.task }
        lastRead += 1
        let id = lastRead, generation = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(scope, generation: generation)
            if self.generation == generation, self.reading[scope]?.id == id { self.reading[scope] = nil }
        }
        reading[scope] = Read(id: id, task: task)
        return task
    }

    /// Reads a scope until each reference asked for is read or counted as missing.
    private func run(_ scope: Scope, generation: Int) async {
        await enter()
        guard generation == self.generation else { return }
        while true {
            let marks = (wanted[scope] ?? []).filter { detail(worker: scope.worker, mark: $0) == .awaited }
            wanted[scope] = marks
            guard !marks.isEmpty else { break }
            let walk: Walk
            do {
                walk = try await Self.walk(worker: scope.worker, turnID: scope.turnID,
                                           from: scopes[scope]?.resume, read: read)
            } catch {
                guard generation == self.generation else { return }
                forget(marks, in: scope)
                break
            }
            guard generation == self.generation else { return }
            keep(walk, in: scope, wanted: Set(marks.map(\.cursor)))
            var waits = false
            for mark in marks where detail(worker: scope.worker, mark: mark) == .awaited {
                let key = Key(worker: scope.worker, mark: mark)
                if tries[key, default: 0] >= 1 {
                    tries[key] = nil
                    missing.insert(key)
                } else {
                    // The runner sends an event and its source record on separate requests.
                    tries[key] = 1
                    waits = true
                }
            }
            guard waits else { continue }
            leave()
            do { try await pause() } catch {
                guard generation == self.generation else { return }
                forget(wanted[scope] ?? [], in: scope)
                return
            }
            guard generation == self.generation else { return }
            await enter()
            guard generation == self.generation else { return }
        }
        leave()
    }

    private func forget(_ marks: Set<SessionMessageMark>, in scope: Scope) {
        for mark in marks {
            let key = Key(worker: scope.worker, mark: mark)
            tries[key] = nil
            failed.insert(key)
        }
        wanted[scope] = nil
    }

    private func keep(_ walk: Walk, in scope: Scope, wanted: Set<String>) {
        var records = scopes[scope] ?? Records()
        records.resume = walk.resume
        records.touched = clock
        for (cursor, patch) in walk.records where !records.rejected.contains(cursor) {
            if let patch {
                if let known = records.patches[cursor] {
                    // The same record read again is the same; two different ones name neither.
                    guard known != patch else { continue }
                    records.drop(cursor)
                    records.rejected.insert(cursor)
                } else {
                    records.patches[cursor] = patch
                    records.order.append(cursor)
                    records.bytes += Self.cost(patch)
                }
            } else if wanted.contains(cursor) {
                records.drop(cursor)
                records.rejected.insert(cursor)
            }
        }
        while records.order.count > Self.recordLimit || records.bytes > Self.scopeByteLimit, !records.order.isEmpty {
            records.drop(records.order.removeFirst())
        }
        scopes[scope] = records
    }

    /// Lets go of the turns asked for longest ago, beyond `scopeLimit` turns or `byteLimit`
    /// bytes. A turn in `keeping` or being read stays, so one console's turns never push each
    /// other out.
    private func trim(keeping: Set<Scope>) {
        var bytes = scopes.values.reduce(0) { $0 + $1.bytes }
        guard scopes.count > Self.scopeLimit || bytes > Self.byteLimit else { return }
        let idle = scopes.filter { !keeping.contains($0.key) && reading[$0.key] == nil }
            .sorted { $0.value.touched < $1.value.touched }.map(\.key)
        for scope in idle {
            guard scopes.count > Self.scopeLimit || bytes > Self.byteLimit else { break }
            bytes -= scopes[scope]?.bytes ?? 0
            scopes[scope] = nil
            wanted[scope] = nil
            let isOfScope: (Key) -> Bool = { $0.worker == scope.worker && $0.mark.turnID == scope.turnID }
            missing = missing.filter { !isOfScope($0) }
            failed = failed.filter { !isOfScope($0) }
            tries = tries.filter { !isOfScope($0.key) }
        }
    }

    /// Reads the scope's pages from `resume` on, at most `CompactionSummaryStore.pageLimit` of
    /// them. A page token the service no longer takes starts the walk over, once.
    private nonisolated static func walk(worker: String, turnID: String?, from resume: String?,
                                         read: SessionMessageReader) async throws -> Walk {
        var walk = Walk(resume: resume)
        var restarted = false, pages = 0
        while pages < CompactionSummaryStore.pageLimit {
            let page: SourcePage
            do {
                page = try await read(worker, turnID, walk.resume)
            } catch {
                guard walk.resume != nil, !restarted, !Task.isCancelled, !(error is CancellationError) else { throw error }
                restarted = true
                walk = Walk()
                pages = 0
                continue
            }
            try Task.checkCancellation()
            pages += 1
            for observation in page.observations where !observation.cursor.isEmpty {
                walk.records.append((observation.cursor, SessionMessagePatch(observation: observation)))
            }
            guard let next = page.nextCursor, next != walk.resume else { break }
            walk.resume = next
        }
        return walk
    }

    // MARK: Turns at once

    private func enter() async {
        if active < Self.concurrentReads {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func leave() {
        if waiters.isEmpty { active = max(0, active - 1) } else { waiters.removeFirst().resume() }
    }
}

extension SessionMessageStore {
    /// The reader the live cockpit uses: the worker's live source, narrowed to the turn.
    static func live(reader: ServiceClient) -> SessionMessageStore {
        SessionMessageStore { workerID, turnID, pageCursor in
            try await reader.workerHistory(workerID, source: .live, cursor: pageCursor, limit: 128, turnID: turnID)
        }
    }
}

// MARK: - Molecule

/// A message from another session: "Message from sender" in secondary ink with the sender in
/// the foreground ink, then the text as plain text beside the report block's rule. The text is
/// never read as Markdown and holds no link. In full on the focused worker and coordinator; its
/// first lines on a tile and the PiP, then "Show all". With "Hide values that look like secrets"
/// on, those values are hidden in the sender and the text, and a line says how many.
struct PrettySessionMessage: View {
    let message: SessionMessage
    let metrics: PrettyMetrics
    var hidesSecrets = false

    var body: some View {
        let words = SessionMessageWords(message: message, hidesSecrets: hidesSecrets)
        VStack(alignment: .leading, spacing: 4) {
            heading(words).font(.system(size: metrics.detailSize))
                .fixedSize(horizontal: false, vertical: true)
            if words.hasText {
                PrettyClamp(lines: metrics.density == .regular ? nil : metrics.clampLines,
                            lineHeight: metrics.bodySize * 1.5, metrics: metrics) {
                    Text(verbatim: words.text)
                        .font(metrics.body).foregroundStyle(Palette.foreground)
                        .lineSpacing(metrics.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let note = words.hiddenNote {
                Text(verbatim: note).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
            }
        }
        .padding(.leading, metrics.density == .pip ? 9 : 14)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 2) }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(words.heading)
    }

    private func heading(_ words: SessionMessageWords) -> Text {
        guard let sender = words.sender else {
            return Text(verbatim: SessionMessageWords.unnamed).foregroundStyle(.inkSecondary)
        }
        let lead = Text(verbatim: SessionMessageWords.lead).foregroundStyle(.inkSecondary)
        let name = Text(verbatim: sender).foregroundStyle(Palette.foreground).fontWeight(.medium)
        return Text("\(lead)\(name)")
    }
}
