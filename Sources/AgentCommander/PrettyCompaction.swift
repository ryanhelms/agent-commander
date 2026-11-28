import CryptoKit
import Foundation
import Observation

// PRETTY COMPACTION (DESIGN.md, "Pretty transcript"; spec section H)
// A provider may compact its context in the middle of a conversation. The service keeps one
// message per compaction, in the place its first update arrived, and replaces that message's
// text as the compaction moves on (internal/provider/acp_activity.go). The provider's summary
// and error stay behind the message's source cursor.
//
//   Values          CompactionMark           what the message says: status, identity, source cursor
//                   PrettyCompaction         the Pretty item: one row per compaction
//                   CompactionRecord         the summary and error the source record holds
//   Feature layer   CompactionSummaryStore   one read of the source record per row
//   Boundary        CompactionReader         the source read, as a closure
//
// Nothing is inferred. A message that is not exactly the service's compaction message keeps its
// place in the folded session updates. A summary is the provider's own text from the record of
// that same compaction, or there is no summary action.

/// What the service's message says about one compaction.
struct CompactionMark: Equatable, Sendable {
    enum Status: Equatable, Sendable { case inProgress, completed, failed }

    /// The ACP kind the service gives the message.
    static let kind = "compaction_update"
    /// The service's text for each status the approved design draws.
    private static let statuses: [String: Status] = [
        "Provider context compaction in progress": .inProgress,
        "Provider context compaction completed": .completed,
        "Provider context compaction failed": .failed
    ]

    let status: Status
    /// The service's identity for the compaction: the SHA-256 of the provider's compaction ID,
    /// in hex. Every update of one compaction carries it.
    let messageID: String
    /// `live` or `provider`: where the record behind `cursor` is read.
    let source: String
    /// The cursor of the latest update's source record. Empty when the service sent none.
    let cursor: String
    /// The turn of that record, which narrows a live read. Nil outside a turn.
    let turnID: String?
    /// Provider history only: the hint for the page that holds the record.
    let pageCursor: String?

    /// Nil unless the message is the service's own compaction message: a `system` message of
    /// kind `compaction_update` that replaces by a message ID, whose text is exactly one of the
    /// three statuses. A cancelled compaction, an unknown status and a record with no identity
    /// are not marked, so each keeps its place as a session update.
    init?(message: AGUIMessage, acp: [String: AGUIValue]) {
        guard message.role == "system", acp["kind"]?.stringValue == Self.kind,
              acp["messageOp"]?.stringValue == "replace",
              let id = acp["messageId"]?.stringValue, !id.isEmpty,
              let source = acp["source"]?.stringValue,
              source == ConsoleSourceKind.live.rawValue || source == ConsoleSourceKind.provider.rawValue,
              let status = Self.statuses[message.content ?? ""] else { return nil }
        self.status = status
        messageID = id
        self.source = source
        cursor = acp["cursor"]?.stringValue ?? ""
        turnID = acp["turnId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        pageCursor = acp["pageCursor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One compaction in the Pretty conversation, at its message's own position. Never folded.
struct PrettyCompaction: Identifiable, Equatable {
    /// The message's ID. The service keeps it while the compaction's status changes, so the row
    /// keeps its place and its open state.
    let id: String
    let entry: TranscriptEntry
    let mark: CompactionMark

    init?(entry: TranscriptEntry) {
        guard case .other = entry.kind, let mark = entry.origin?.compaction else { return nil }
        id = entry.id
        self.entry = entry
        self.mark = mark
    }

    static let runningSentence = ActivitySentence("Compacting the conversation")
    static let failedSentence = ActivitySentence("Couldn't compact the conversation")

    /// The live line's step while the compaction runs.
    var liveStep: ActivityStep {
        ActivityStep(id: id, kind: .quiet, entries: [entry], state: .running, sentence: Self.runningSentence)
    }

    /// The failure line's step. Its reason is the provider's first sentence, when the record of
    /// this compaction holds an error.
    func failureStep(_ record: CompactionRecord?) -> ActivityStep {
        var step = ActivityStep(id: id, kind: .quiet, entries: [entry], state: .failed, sentence: Self.failedSentence,
                                tag: .failed)
        if let error = record?.error {
            let (first, rest) = ActivityFailureWords.firstSentence(error)
            step.failure = ActivityFailure(outcome: .failed, reason: first, exact: first, rest: rest)
        }
        return step
    }
}

/// What the source record of one compaction holds beyond its status.
struct CompactionRecord: Equatable, Sendable {
    /// The provider's summary: its text parts end to end, exactly as sent. Nil when the record
    /// holds none, holds no text, or the SDK left the summary out for its size.
    var summary: String? = nil
    /// The provider's error text. Nil when the record holds none.
    var error: String? = nil

    /// The extension type of the SDK's compaction snapshot.
    static let sourceType = "acp.compaction_state"

    /// Reads the SDK's snapshot `{"compactionId", "status", "error", "summary": [content], "omitted"}`.
    /// Nil unless it is the snapshot of the marked compaction: its compaction ID must hash to the
    /// message's identity. A summary is read only from `text` content parts, and only when the
    /// snapshot was not shortened.
    init?(snapshot data: Data, messageID: String) {
        guard case .object(let fields)? = try? AGUIValue(json: data),
              let id = fields["compactionId"]?.stringValue, !id.isEmpty,
              Self.identity(of: id) == messageID else { return nil }
        if let text = fields["error"]?.stringValue, text.contains(where: { !$0.isWhitespace }) { error = text }
        if case .bool(true)? = fields["omitted"] { return }
        let text = (fields["summary"]?.arrayValue ?? []).reduce(into: "") { text, part in
            guard let part = part.objectValue, part["type"]?.stringValue == "text" else { return }
            text += part["text"]?.stringValue ?? ""
        }
        if text.contains(where: { !$0.isWhitespace }) { summary = text }
    }

    init(summary: String? = nil, error: String? = nil) {
        self.summary = summary
        self.error = error
    }

    /// The service's identity for a provider compaction ID.
    static func identity(of compactionID: String) -> String {
        SHA256.hash(data: Data(compactionID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The record at exactly `mark.cursor` on a page, when it is this compaction's snapshot.
    static func find(_ mark: CompactionMark, in page: SourcePage) -> CompactionRecord? {
        for observation in page.observations where observation.cursor == mark.cursor {
            if case .attachment(let type, _, let data?) = observation.body, type == sourceType,
               let record = CompactionRecord(snapshot: data, messageID: mark.messageID) {
                return record
            }
        }
        return nil
    }
}

/// One page of the source a mark names. `pageCursor` is the `nextCursor` of the page before it,
/// nil for the first.
typealias CompactionReader = @Sendable (_ workerID: String, _ mark: CompactionMark,
                                        _ pageCursor: String?) async throws -> SourcePage

/// The summary and error of each compaction row, read once from the row's own source record.
/// A row asks when it is drawn finished; the divider offers its summary only after a read found
/// usable text. Nothing is read on a timer.
@MainActor @Observable
final class CompactionSummaryStore {
    private struct Key: Hashable {
        let worker, source, cursor: String
    }

    /// The live window holds 256 records and a page at most 128; one more page allows for a gap.
    nonisolated static let pageLimit = 3

    /// One read in flight. The store owns its task, so no surface's cancellation ends it.
    private struct Read {
        let id: Int
        let task: Task<Void, Never>
    }

    private var records: [Key: CompactionRecord] = [:]
    /// The read in flight for each row, shared by every surface that draws the row.
    @ObservationIgnored private var reading: [Key: Read] = [:]
    @ObservationIgnored private var lastRead = 0
    @ObservationIgnored private let read: CompactionReader

    init(read: @escaping CompactionReader) {
        self.read = read
    }

    /// What the last read of this row's record found. Nil until a read has finished, and when the
    /// row has no cursor.
    func record(worker: String, mark: CompactionMark) -> CompactionRecord? {
        records[Key(worker: worker, source: mark.source, cursor: mark.cursor)]
    }

    /// Reads the row's source record, once. A record that is not there, or is not this
    /// compaction's, reads as empty and is not asked for again. A failed read is forgotten, so
    /// the row asks again when it is next drawn.
    ///
    /// Every surface that draws the row shares one read. The store runs it in its own task, so a
    /// surface that closes ends only its own wait: the read goes on for the surfaces still open.
    /// Each caller returns when that read has finished.
    func load(worker: String, mark: CompactionMark) async {
        let key = Key(worker: worker, source: mark.source, cursor: mark.cursor)
        guard !worker.isEmpty, !mark.cursor.isEmpty, mark.status != .inProgress, records[key] == nil else { return }
        if let shared = reading[key] { return await shared.task.value }
        lastRead += 1
        let id = lastRead
        let task = Task { [weak self, read] in
            let found = try? await CompactionSummaryStore.find(worker: worker, mark: mark, read: read)
            // Only the read the store still holds for this row may finish it. One started
            // against the last service finds another read here, or none, and is dropped.
            guard let self, self.reading[key]?.id == id else { return }
            self.reading[key] = nil
            if let found { self.records[key] = found }
        }
        reading[key] = Read(id: id, task: task)
        await task.value
    }

    /// Pages to the record at the mark's cursor. An empty record when no page holds it.
    private nonisolated static func find(worker: String, mark: CompactionMark,
                                         read: CompactionReader) async throws -> CompactionRecord {
        var cursor: String?
        for _ in 0..<pageLimit {
            let page = try await read(worker, mark, cursor)
            try Task.checkCancellation()
            if let record = CompactionRecord.find(mark, in: page) { return record }
            // Provider history answers with the one page that holds the record.
            guard mark.source == ConsoleSourceKind.live.rawValue,
                  let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        return CompactionRecord()
    }

    /// The selected service changed: what the last one held is dropped and its reads in flight
    /// are cancelled and let go, so a row may be read from the new service at once.
    func serviceChanged() {
        for shared in reading.values { shared.task.cancel() }
        reading = [:]
        records = [:]
    }
}

extension CompactionSummaryStore {
    /// The reader the live cockpit uses. A live row reads the worker's live source, narrowed to
    /// the row's turn when it has one. A row from provider history reads the one record at its
    /// cursor.
    static func live(reader: ServiceClient) -> CompactionSummaryStore {
        CompactionSummaryStore { workerID, mark, pageCursor in
            if mark.source == ConsoleSourceKind.live.rawValue {
                return try await reader.workerHistory(workerID, source: .live, cursor: pageCursor, limit: 128,
                                                      turnID: mark.turnID)
            }
            return try await reader.workerRecord(workerID, recordCursor: mark.cursor, pageCursor: mark.pageCursor)
        }
    }
}
