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
//                                       read after the owner's reply to a form request
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

    private enum CodingKeys: String, CodingKey {
        case key, kind, sequence, name, title, plan, truncated, revision, fields, state, location
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
    /// The PNG images of `result` and `content`, read once by the store when it keeps the
    /// record. Never sent by the service; nil on a record the store has not kept.
    var images: ResultImages? = nil
    /// The typed diff blocks of `content`, compared once by the store when it keeps the record.
    /// Never sent by the service; nil on a record the store has not kept.
    var changes: ResultChanges? = nil

    private enum CodingKeys: String, CodingKey {
        case key, kind, name, title, input, result, content, truncated, shortened
        case startedAt = "started_at", endedAt = "ended_at"
    }
}

struct ToolDetailPage: Decodable, Equatable, Sendable {
    let revision: UInt64
    let records: [ToolDetailSummary]
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
    /// Counts each change of service, so an answer from the service just left is dropped.
    @ObservationIgnored private var settingsGeneration = 0
    @ObservationIgnored private var isLoadingSettings = false
    private var summaries: [String: [String: ToolDetailSummary]] = [:]
    private var records: [String: [String: ToolDetailRecord]] = [:]
    @ObservationIgnored private var revisions: [String: UInt64] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    /// Workers whose form reply arrived while their read was in flight: read once more after it.
    @ObservationIgnored private var rereads: Set<String> = []
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored var source: ToolDetailSource?

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
    /// A call that arrives while a read is in flight starts no second one. With `afterInFlight`
    /// (the read after a form reply), the worker is then read once more when that read ends,
    /// from the revision it returned: it may have been answered before the reply's record was
    /// stored. Any other overlapping call is dropped, as before.
    func refresh(worker: String, afterInFlight: Bool = false) async {
        guard let source else { return }
        guard !reading.contains(worker) else {
            if afterInFlight { rereads.insert(worker) }
            return
        }
        reading.insert(worker)
        defer { reading.remove(worker); rereads.remove(worker) }
        repeat {
            rereads.remove(worker)
            guard let page = try? await source.page(worker, revisions[worker] ?? 0) else { continue }
            // A lower revision means the service started again with fewer records.
            if page.revision < (revisions[worker] ?? 0) { summaries[worker] = [:]; records[worker] = [:] }
            revisions[worker] = page.revision
            guard !page.records.isEmpty else { continue }
            var known = summaries[worker] ?? [:]
            for record in page.records {
                known[record.key] = record
                // A changed record's full copy is stale.
                records[worker]?[record.key] = nil
                missing.remove(worker + "\u{1F}" + record.key)
            }
            summaries[worker] = known
        } while rereads.contains(worker)
    }

    /// Reads one full record, when a line is opened. A record the service does not hold is asked
    /// for once.
    func open(worker: String, key: String) async {
        let key = Self.storedKey(worker: worker, key: key)
        let id = worker + "\u{1F}" + key
        guard let source, records[worker]?[key] == nil, !reading.contains(id), !missing.contains(id) else { return }
        reading.insert(id)
        defer { reading.remove(id) }
        guard let record = try? await source.record(worker, key) else { missing.insert(id); return }
        records[worker, default: [:]][key] = ToolDetailStore.kept(record)
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
    func serviceChanged() {
        settingsGeneration += 1
        isLoadingSettings = false
        settings = TranscriptSettings()
        settingsLoaded = false
        settingsError = nil
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
