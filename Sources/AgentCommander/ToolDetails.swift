import Foundation
import Observation

// TOOL DETAILS
// What Pretty shows beyond the console preview: a call's short argument values for its sentence,
// its times, a plan's items, and (once a line is opened) the full arguments and result. The
// service keeps them apart from the console events and serves them only on the owner socket
// (internal/service/tool_details.go).
//
//   Values         ToolDetailSummary    one record without its large values
//                  ToolDetailRecord     one full record, read when a line is opened
//                  PlanItem             one item of a task checklist
//                  TranscriptSettings   what new records keep, and whether secrets are hidden
//   Feature layer  ToolDetailStore      summaries by worker, read after the last revision seen;
//                                       full records read one at a time, on request; one
//                                       read after the owner's reply to a form request; one
//                                       read at a time per worker, and one more for the calls
//                                       that arrived during it; a page that lists the
//                                       service's keys drops every other copy
//   Boundary       ToolDetailSource     the four service calls, as closures
//
// The store never guesses: a record stored before the service kept details has no entry, and the
// sentence then uses its fallback wording.

struct PlanItem: Decodable, Equatable, Sendable, Identifiable {
    enum Status: Equatable, Sendable { case done, inProgress, pending }

    let content: String
    let status: String
    /// The words a `TodoWrite` item shows while in progress. Nil elsewhere.
    var activeForm: String? = nil
    var id: String { content }

    private enum CodingKeys: String, CodingKey { case content, status, activeForm }

    var state: Status {
        switch status.lowercased() {
        case "completed", "done": .done
        case "in_progress", "inprogress", "active": .inProgress
        default: .pending
        }
    }

    init(content: String, status: String, activeForm: String? = nil) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }

    /// The item as drawn when the transcript setting hides secrets: its words with every
    /// secret-looking value replaced. The whole text is masked, before any view shortens it.
    var masked: PlanItem {
        PlanItem(content: SecretValues.masked(prose: content).text, status: status,
                 activeForm: activeForm.map { SecretValues.masked(prose: $0).text })
    }

    /// The items of a `TodoWrite` call's arguments, or of a plan record. Nil when `value` holds
    /// no list of items with `content` and `status`.
    static func items(_ value: OrderedJSON?) -> [PlanItem]? {
        guard let value else { return nil }
        guard let list = value.items ?? value["todos"]?.items ?? value["entries"]?.items,
              ResultShape.checklist(list) else { return nil }
        return list.map {
            PlanItem(content: $0["content"]?.string ?? "", status: $0["status"]?.string ?? "",
                     activeForm: $0["activeForm"]?.string)
        }
    }
}

/// The console event an identified ACP plan record was kept from, as the service states it on
/// the record (`plan_event`): that event's own cursor and plan identity, and its turn when it
/// had one. A console's sequence numbers start again when it is rebuilt from provider history,
/// while its records persist, so a sequence alone can name a record kept from another event.
/// The record belongs to an event only when these agree with the event's own reference.
///
/// Decoding never fails: a member that is missing or not a string leaves the binding unusable,
/// and it then matches no event.
struct PlanEventBinding: Decodable, Equatable, Sendable {
    var cursor: String
    var planIdentity: String
    /// Nil when the event was outside a turn.
    var turnID: String?

    private enum CodingKeys: String, CodingKey { case cursor, planIdentity, turnID = "turnId" }

    init(cursor: String, planIdentity: String, turnID: String? = nil) {
        self.cursor = cursor
        self.planIdentity = planIdentity
        self.turnID = turnID
    }

    init(from decoder: Decoder) throws {
        let members = try? decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? members?.decode(String.self, forKey: key)) ?? "" }
        cursor = text(.cursor)
        planIdentity = text(.planIdentity)
        if members?.contains(.turnID) == true {
            // A turn that is stated must be a usable string, or the binding names no event.
            let turn = text(.turnID)
            turnID = turn
            if turn.isEmpty { cursor = "" }
        } else {
            turnID = nil
        }
    }

    /// The record was kept from the event with exactly this cursor, plan identity and turn.
    func names(cursor: String?, planIdentity: String?, turnID: String?) -> Bool {
        guard let cursor, let planIdentity, !self.cursor.isEmpty, !self.planIdentity.isEmpty else { return false }
        return self.cursor == cursor && self.planIdentity == planIdentity && self.turnID == turnID
    }
}

struct ToolDetailSummary: Decodable, Equatable, Sendable {
    let key: String
    let kind: String
    var sequence: Int? = nil
    var name: String? = nil
    var title: String? = nil
    var toolKind: String? = nil
    var plan: [PlanItem]? = nil
    var startedAt: String? = nil
    var endedAt: String? = nil
    var truncated: [String]? = nil
    var revision: UInt64? = nil
    /// The input's short top-level values.
    var fields: [String: AGUIValue]? = nil
    var inputBytes: Int? = nil
    var resultBytes: Int? = nil
    /// A `job` record: the console call that started it, `command` or `agent`, and the runner's
    /// state word. `openToolName` and `openToolArg` are a child's latest open call.
    var toolUseID: String? = nil
    var jobKind: String? = nil
    var state: String? = nil
    var openToolName: String? = nil
    var openToolArg: String? = nil
    /// A `turn_end` record. Zero and false are meaningful; nil means the provider sent none.
    var durationMS: Int? = nil
    var stopReason: String? = nil
    var terminalReason: String? = nil
    var isError: Bool? = nil
    /// The one file and line an ACP tool reported for this call. Nil when the service sent
    /// none; a member that is not one valid location holds no value (`ToolLocation.swift`).
    var location: ToolLocationField? = nil
    /// A `plan` record of an identified ACP plan: the console event it was kept from. Nil on
    /// every other record, and on one stored before the service stated it.
    var planEvent: PlanEventBinding? = nil

    private enum CodingKeys: String, CodingKey {
        case key, kind, sequence, name, title, plan, truncated, revision, fields, state, location
        case planEvent = "plan_event"
        case toolKind = "tool_kind", startedAt = "started_at", endedAt = "ended_at"
        case inputBytes = "input_bytes", resultBytes = "result_bytes"
        case toolUseID = "tool_use_id", jobKind = "job_kind"
        case openToolName = "open_tool_name", openToolArg = "open_tool_arg"
        case durationMS = "duration_ms", stopReason = "stop_reason", terminalReason = "terminal_reason", isError = "is_error"
    }

    func field(_ name: String) -> String? { CommanderCall.text(fields?[name]) }

    var started: Date? { startedAt.flatMap(Self.date) }
    var ended: Date? { endedAt.flatMap(Self.date) }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

struct ToolDetailRecord: Decodable, Equatable, Sendable {
    let key: String
    let kind: String
    var name: String? = nil
    var title: String? = nil
    var input: String? = nil
    var result: String? = nil
    var content: String? = nil
    var startedAt: String? = nil
    var endedAt: String? = nil
    var truncated: [String]? = nil
    /// Where the service cut each value in `truncated`: JSON Pointers to the strings it
    /// shortened, or one empty pointer for a cut at the end of the whole value. Absent from an
    /// older record or service.
    var shortened: [String: [String]]? = nil
    /// The worker revision at which the service last changed this record. Absent from an older
    /// record or service. The store compares it with the summary's, so a copy read before a
    /// change is never kept over the change.
    var revision: UInt64? = nil
    /// The PNG images of `result` and `content`, read once by the store when it keeps the
    /// record. Never sent by the service; nil on a record the store has not kept.
    var images: ResultImages? = nil
    /// The typed diff blocks of `content`, compared once by the store when it keeps the record.
    /// Never sent by the service; nil on a record the store has not kept.
    var changes: ResultChanges? = nil

    private enum CodingKeys: String, CodingKey {
        case key, kind, name, title, input, result, content, truncated, shortened, revision
        case startedAt = "started_at", endedAt = "ended_at"
    }
}

struct ToolDetailPage: Decodable, Equatable, Sendable {
    let revision: UInt64
    /// The records new or changed after the revision asked for.
    let records: [ToolDetailSummary]
    /// Every key the service holds for the worker at `revision`, unchanged ones included. An
    /// empty list says it holds none. Nil when the member is absent (an older service): the page
    /// then says nothing about what was dropped, and the store keeps what it has.
    let retainedKeys: [String]?

    private enum CodingKeys: String, CodingKey { case revision, records, retainedKeys = "retained_keys" }

    init(revision: UInt64, records: [ToolDetailSummary], retainedKeys: [String]? = nil) {
        self.revision = revision
        self.records = records
        self.retainedKeys = retainedKeys
    }
}

struct TranscriptSettings: Codable, Equatable, Sendable {
    /// Applied by the app when it draws a value. The stored record is unchanged.
    var hideSecrets = false
    /// New values longer than this are shortened before they are stored. Zero is no limit.
    var limitBytes = 0

    /// The limit the setting offers, and the bounds the service accepts.
    static let offeredLimit = 16 << 10
    static let limitRange = 1024...524_288

    private enum CodingKeys: String, CodingKey {
        case hideSecrets = "hide_secrets", limitBytes = "limit_bytes"
    }

    init(hideSecrets: Bool = false, limitBytes: Int = 0) {
        self.hideSecrets = hideSecrets
        self.limitBytes = limitBytes
    }

    var keepsEverything: Bool { !hideSecrets && limitBytes == 0 }
}

/// The service calls the store makes. Every one goes over the owner socket.
struct ToolDetailSource: Sendable {
    var page: @Sendable (_ workerID: String, _ after: UInt64) async throws -> ToolDetailPage
    var record: @Sendable (_ workerID: String, _ key: String) async throws -> ToolDetailRecord
    var readSettings: @Sendable () async throws -> TranscriptSettings
    var writeSettings: @Sendable (TranscriptSettings) async throws -> TranscriptSettings
}

/// Launch-scoped. One instance, owned by the App and shared by every surface that draws Pretty.
@MainActor
@Observable
final class ToolDetailStore {
    private(set) var settings = TranscriptSettings()
    /// Why the last settings change was not saved. Nil once one is.
    private(set) var settingsError: String?
    /// The service in use has answered with its saved setting, or accepted a change to it.
    private(set) var settingsLoaded = false
    /// Counts each change of service, so an answer from the service just left is dropped:
    /// its setting, its pages and its full records alike.
    @ObservationIgnored private var settingsGeneration = 0
    @ObservationIgnored private var isLoadingSettings = false
    private var summaries: [String: [String: ToolDetailSummary]] = [:]
    private var records: [String: [String: ToolDetailRecord]] = [:]
    @ObservationIgnored private var revisions: [String: UInt64] = [:]
    /// The keys the service said it holds, by worker, when its last page listed them. No entry
    /// when that page listed none: an older service never lists them.
    @ObservationIgnored private var retained: [String: Set<String>] = [:]
    /// The page read in flight for each worker, by its token. A read ends only its own token, so
    /// one left over from the last service cannot end the read that replaced it.
    @ObservationIgnored private var pageReads: [String: Int] = [:]
    /// The calls waiting for a worker's read in flight to end, each under its own token. Each
    /// then reads, or returns. An entry is resumed by whoever removes it, so exactly once.
    @ObservationIgnored private var pageWaiters: [String: [Int: CheckedContinuation<Void, Never>]] = [:]
    /// The latest page request that ended with an answer, by worker. Requests share the tokens'
    /// count, so a later number is a request sent later.
    @ObservationIgnored private var answeredReads: [String: Int] = [:]
    /// The full-record reads in flight, by worker and key.
    @ObservationIgnored private var recordReads: [ReadID: RecordRead] = [:]
    @ObservationIgnored private var lastToken = 0
    /// Workers whose form reply arrived while their read was in flight: read once more after it.
    @ObservationIgnored private var rereads: Set<String> = []
    /// Keys the service did not hold when asked, by worker. Each is asked for once.
    @ObservationIgnored private var missing: [String: Set<String>] = [:]
    @ObservationIgnored var source: ToolDetailSource?

    private struct ReadID: Hashable {
        let worker: String
        let key: String
    }

    /// One full-record read in flight. `changed` is set when a page changes or drops its key
    /// before the answer arrives.
    private struct RecordRead {
        let token: Int
        var changed = false
    }

    /// The most keys remembered as missing for one worker. Past it the list starts again, which
    /// costs one more request for a key that is opened again.
    nonisolated static let missingLimit = 256

    init(source: ToolDetailSource? = nil) { self.source = source }

    /// A store holding fixed values, for previews and renders. It reads nothing.
    init(summaries: [String: [ToolDetailSummary]], records: [String: [ToolDetailRecord]] = [:],
         settings: TranscriptSettings = TranscriptSettings()) {
        self.summaries = summaries.mapValues { Dictionary($0.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }) }
        self.records = records.mapValues {
            Dictionary($0.map { ($0.key, ToolDetailStore.kept($0)) }, uniquingKeysWith: { _, last in last })
        }
        self.settings = settings
    }

    /// The key the service keeps a record under. The workspace feed names a tool call
    /// `<worker ID>:<tool ID>`; the service keeps its details under the tool ID alone.
    nonisolated static func storedKey(worker: String, key: String) -> String {
        let prefix = worker + ":"
        return key.hasPrefix(prefix) && key.count > prefix.count ? String(key.dropFirst(prefix.count)) : key
    }

    func summary(worker: String, key: String) -> ToolDetailSummary? {
        summaries[worker]?[Self.storedKey(worker: worker, key: key)]
    }
    func record(worker: String, key: String) -> ToolDetailRecord? {
        records[worker]?[Self.storedKey(worker: worker, key: key)]
    }
    func summaries(worker: String) -> [String: ToolDetailSummary] { summaries[worker] ?? [:] }

    /// Reads the worker's summaries changed since the last revision seen. Called when its
    /// transcript gains an entry or its state changes, never on a timer.
    ///
    /// One read runs per worker at a time. A call that arrives during it starts no second one:
    ///
    /// - With `afterInFlight` (the read after a form reply) it returns at once, and the read in
    ///   flight is followed by one more, from the revision it returned: it may have been
    ///   answered before the reply's record was stored.
    /// - Any other call waits. It needs a page asked for after it arrived, so it returns once
    ///   such a request has ended with an answer. The first call to find none makes the request
    ///   itself, and the calls that arrived with it wait for that one. A read whose caller was
    ///   cancelled ends with no answer, so the latest transcript's call still reads its page.
    ///
    /// The read belongs to the call that makes it, and is cancelled with it. A call that is
    /// already cancelled asks nothing. One cancelled while it waits returns at once, without
    /// waiting for the read in flight. One whose service changed reads nothing.
    ///
    /// A page that lists the service's keys (`retainedKeys`) is the whole truth about which
    /// records exist: every cached summary and full record it does not list is dropped, except a
    /// full record whose revision is later than the page's. A page that lists none (an older
    /// service) drops nothing, and ends what the last list said.
    func refresh(worker: String, afterInFlight: Bool = false) async {
        // A cancelled call's transcript was replaced: it asks nothing, even with no read in flight.
        guard let source, !Task.isCancelled else { return }
        let generation = settingsGeneration
        if pageReads[worker] != nil {
            if afterInFlight {
                rereads.insert(worker)
                return
            }
            guard await mustReadAfterWaiting(worker: worker, arrived: lastToken, generation: generation) else { return }
        }
        lastToken += 1
        let token = lastToken
        pageReads[worker] = token
        defer {
            if pageReads[worker] == token {
                pageReads[worker] = nil
                rereads.remove(worker)
                pageWaiters.removeValue(forKey: worker)?.values.forEach { $0.resume() }
            }
        }
        repeat {
            rereads.remove(worker)
            let after = revisions[worker] ?? 0
            lastToken += 1
            let request = lastToken
            let page = try? await source.page(worker, after)
            // The service changed during the read: the answer is the last service's.
            guard generation == settingsGeneration, pageReads[worker] == token else { return }
            if let page { apply(page, worker: worker, after: after) }
            // A cancelled call's request ends unanswered, so a call that waited makes its own.
            // A request the service failed is an answer: the calls that waited do not repeat it.
            if page != nil || !Task.isCancelled { answeredReads[worker] = request }
        } while rereads.contains(worker)
    }

    /// Waits while another call reads the worker. True when this call must make the next
    /// request: none sent after it arrived (`arrived`, the token count then) has been answered,
    /// and none is in flight. False when one has been, or when this call is cancelled or its
    /// service has changed.
    private func mustReadAfterWaiting(worker: String, arrived: Int, generation: Int) async -> Bool {
        while pageReads[worker] != nil {
            await readInFlightEnded(worker: worker)
            guard generation == settingsGeneration, !Task.isCancelled else { return false }
            if (answeredReads[worker] ?? 0) > arrived { return false }
        }
        return true
    }

    /// Returns when the worker's read in flight ends, the service changes, or this call is
    /// cancelled, whichever is first.
    ///
    /// The wait is filed under a token of its own. Cancellation removes that one entry, so it
    /// cannot touch a wait filed later, and an entry already taken (by the read's end or a
    /// change of service) is left alone. A call cancelled before its wait is filed files none.
    private func readInFlightEnded(worker: String) async {
        lastToken += 1
        let token = lastToken
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    pageWaiters[worker, default: [:]][token] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.endWait(worker: worker, token: token) }
        }
    }

    private func endWait(worker: String, token: Int) {
        guard let waiter = pageWaiters[worker]?.removeValue(forKey: token) else { return }
        if pageWaiters[worker]?.isEmpty == true { pageWaiters[worker] = nil }
        waiter.resume()
    }

    private func apply(_ page: ToolDetailPage, worker: String, after: UInt64) {
        // A lower revision means the service started again with fewer records. Nothing read
        // before it is kept, and a full record still on its way is dropped when it arrives.
        if page.revision < after { forget(worker: worker) }
        revisions[worker] = page.revision
        var known = summaries[worker] ?? [:]
        var full = records[worker] ?? [:]
        var changed: Set<String> = []
        for record in page.records {
            known[record.key] = record
            changed.insert(record.key)
            // A changed record's full copy is stale, unless it was read at this change or later.
            if let copy = full[record.key], !Self.isCurrent(copy.revision, for: record.revision) {
                full[record.key] = nil
            }
            missing[worker]?.remove(record.key)
        }
        if let listed = page.retainedKeys {
            let keys = Set(listed)
            retained[worker] = keys
            for key in known.keys where !keys.contains(key) {
                known[key] = nil
                changed.insert(key)
            }
            // A full record stored after this page was answered is kept until a page covers it.
            for (key, copy) in full where !keys.contains(key) && (copy.revision ?? 0) <= page.revision {
                full[key] = nil
                changed.insert(key)
            }
        } else {
            // This page lists no keys, so the last list no longer describes the service. The
            // cached copies stay; a full record is judged by its summary alone from here on.
            retained[worker] = nil
        }
        for key in changed { recordReads[ReadID(worker: worker, key: key)]?.changed = true }
        if known != summaries[worker] ?? [:] { summaries[worker] = known }
        if full != records[worker] ?? [:] { records[worker] = full }
    }

    /// Whether a full copy read at `copy` holds a summary's change at `summary`. Without both
    /// revisions (an older record or service) nothing shows that it does.
    private nonisolated static func isCurrent(_ copy: UInt64?, for summary: UInt64?) -> Bool {
        guard let copy, let summary else { return false }
        return copy >= summary
    }

    /// Drops everything read for one worker, and disowns its full-record reads in flight.
    private func forget(worker: String) {
        summaries[worker] = nil
        records[worker] = nil
        retained[worker] = nil
        missing[worker] = nil
        recordReads = recordReads.filter { $0.key.worker != worker }
    }

    /// Reads one full record, when a line is opened. A record the service does not hold is asked
    /// for once.
    ///
    /// The answer is kept only while it is the service's current copy: the same service and
    /// worker history, a key the service still holds, and a revision no older than the summary's.
    /// A record just written may arrive before the page that lists it; its revision is then
    /// past the last page's, and it is kept.
    func open(worker: String, key: String) async {
        let key = Self.storedKey(worker: worker, key: key)
        let id = ReadID(worker: worker, key: key)
        guard let source, records[worker]?[key] == nil, recordReads[id] == nil,
              missing[worker]?.contains(key) != true else { return }
        lastToken += 1
        let token = lastToken
        recordReads[id] = RecordRead(token: token)
        let answer = try? await source.record(worker, key)
        // Another service, or a worker whose history started again: the answer is not this one's.
        guard let read = recordReads[id], read.token == token else { return }
        recordReads[id] = nil
        guard let answer else {
            // The key changed while the service was saying it held none: it may hold it now.
            guard !read.changed else { return }
            if (missing[worker]?.count ?? 0) >= Self.missingLimit { missing[worker] = nil }
            missing[worker, default: []].insert(key)
            return
        }
        guard keeps(answer, worker: worker, key: key, changed: read.changed) else { return }
        records[worker, default: [:]][key] = ToolDetailStore.kept(answer)
    }

    private func keeps(_ answer: ToolDetailRecord, worker: String, key: String, changed: Bool) -> Bool {
        if let keys = retained[worker], !keys.contains(key) {
            // Not held at the last page: only a record stored after that page is current.
            guard let revision = answer.revision else { return false }
            return revision > (revisions[worker] ?? 0)
        }
        if let revision = answer.revision, let summary = summaries[worker]?[key]?.revision {
            return revision >= summary
        }
        // No revisions to compare (an older record or service): keep it unless the key changed
        // while it was read.
        return !changed
    }

    /// The record with its result's PNG images read, once, so a sentence's tag and an opened
    /// line's thumbnails do not read the record's text again each time they are drawn.
    nonisolated static func withImages(_ record: ToolDetailRecord) -> ToolDetailRecord {
        guard record.kind == "tool", record.images == nil else { return record }
        var kept = record
        kept.images = ResultImages.read(result: record.result, content: record.content)
        return kept
    }

    /// The record as the store keeps it: its images read and its diff blocks compared, once. The
    /// comparison is bounded (`ResultChanges.Limits`), so keeping a record does not stall a frame.
    nonisolated static func kept(_ record: ToolDetailRecord) -> ToolDetailRecord {
        var kept = withImages(record)
        guard kept.kind == "tool", kept.changes == nil else { return kept }
        kept.changes = ResultChanges.read(content: record.content,
                                          cut: StoredCut(record: record, field: "content", isStored: true))
        return kept
    }

    /// Whether a drawn value that looks like a secret is hidden. Until the service in use has
    /// said what was saved, the answer is yes: a transcript drawn at launch, or just after a
    /// change of host, never shows a value the saved setting hides. A store of fixed values
    /// reads nothing, so its setting is the one it was given.
    var hidesSecrets: Bool { settings.hideSecrets || (source != nil && !settingsLoaded) }

    func loadSettings() async {
        let generation = settingsGeneration
        guard let source, let read = try? await source.readSettings(), generation == settingsGeneration else { return }
        settings = read
        settingsLoaded = true
    }

    /// Reads the saved setting once per service: when the service first answers, and when a
    /// transcript is drawn before it has. A failed read is tried again at the next of those.
    func loadSettingsIfNeeded() async {
        guard source != nil, !settingsLoaded, !isLoadingSettings else { return }
        let generation = settingsGeneration
        isLoadingSettings = true
        await loadSettings()
        // A change of service during the read freed the flag for the new service's read.
        if generation == settingsGeneration { isLoadingSettings = false }
    }

    /// The selected service changed. The last one's setting is dropped, so values are hidden
    /// until the new service says what it holds.
    ///
    /// Its records go too: every summary and full copy, and what was known about its reads. A
    /// read still in flight belongs to the last service, and its answer is dropped. A call
    /// waiting for that read was for the last service's transcript: it ends without reading.
    func serviceChanged() {
        settingsGeneration += 1
        isLoadingSettings = false
        settings = TranscriptSettings()
        settingsLoaded = false
        settingsError = nil
        if !summaries.isEmpty { summaries = [:] }
        if !records.isEmpty { records = [:] }
        revisions = [:]
        retained = [:]
        pageReads = [:]
        answeredReads = [:]
        recordReads = [:]
        rereads = []
        missing = [:]
        let waiters = pageWaiters
        pageWaiters = [:]
        waiters.values.forEach { $0.values.forEach { $0.resume() } }
    }

    /// Saves a change. The shown value moves only when the service accepts it.
    func save(_ next: TranscriptSettings) async {
        guard let source else { settings = next; return }
        let generation = settingsGeneration
        do {
            let saved = try await source.writeSettings(next)
            guard generation == settingsGeneration else { return }
            settings = saved
            settingsError = nil
            settingsLoaded = true
        } catch {
            guard generation == settingsGeneration else { return }
            settingsError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

extension ToolDetailSummary {
    /// How long the record took, when it holds both times. Never a client-side guess.
    var duration: TimeInterval? {
        guard let start = started, let end = ended, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }
}

enum ElapsedTime {
    /// "52s", then "1m 52s". Under one second reads "1s".
    static func text(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// "1 minute 52 seconds", for VoiceOver.
    static func spoken(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded(.down)))
        func unit(_ count: Int, _ noun: String) -> String { count == 1 ? "1 \(noun)" : "\(count) \(noun)s" }
        if seconds < 60 { return unit(seconds, "second") }
        if seconds < 3600 { return unit(seconds / 60, "minute") + " " + unit(seconds % 60, "second") }
        return unit(seconds / 3600, "hour") + " " + unit((seconds % 3600) / 60, "minute")
    }
}
