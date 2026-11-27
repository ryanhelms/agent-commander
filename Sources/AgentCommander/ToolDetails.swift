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
//                                       full records read one at a time, on request
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

    private enum CodingKeys: String, CodingKey {
        case key, kind, sequence, name, title, plan, truncated, revision, fields
        case toolKind = "tool_kind", startedAt = "started_at", endedAt = "ended_at"
        case inputBytes = "input_bytes", resultBytes = "result_bytes"
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

    private enum CodingKeys: String, CodingKey {
        case key, kind, name, title, input, result, content, truncated
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
    private(set) var settingsLoaded = false
    private var summaries: [String: [String: ToolDetailSummary]] = [:]
    private var records: [String: [String: ToolDetailRecord]] = [:]
    @ObservationIgnored private var revisions: [String: UInt64] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored var source: ToolDetailSource?

    init(source: ToolDetailSource? = nil) { self.source = source }

    /// A store holding fixed values, for previews and renders. It reads nothing.
    init(summaries: [String: [ToolDetailSummary]], records: [String: [ToolDetailRecord]] = [:],
         settings: TranscriptSettings = TranscriptSettings()) {
        self.summaries = summaries.mapValues { Dictionary($0.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }) }
        self.records = records.mapValues { Dictionary($0.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }) }
        self.settings = settings
    }

    func summary(worker: String, key: String) -> ToolDetailSummary? { summaries[worker]?[key] }
    func record(worker: String, key: String) -> ToolDetailRecord? { records[worker]?[key] }
    func summaries(worker: String) -> [String: ToolDetailSummary] { summaries[worker] ?? [:] }

    /// Reads the worker's summaries changed since the last revision seen. Called when its
    /// transcript gains an entry or its state changes, never on a timer.
    func refresh(worker: String) async {
        guard let source, !reading.contains(worker) else { return }
        reading.insert(worker)
        defer { reading.remove(worker) }
        guard let page = try? await source.page(worker, revisions[worker] ?? 0) else { return }
        // A lower revision means the service started again with fewer records.
        if page.revision < (revisions[worker] ?? 0) { summaries[worker] = [:]; records[worker] = [:] }
        revisions[worker] = page.revision
        guard !page.records.isEmpty else { return }
        var known = summaries[worker] ?? [:]
        for record in page.records {
            known[record.key] = record
            // A changed record's full copy is stale.
            records[worker]?[record.key] = nil
            missing.remove(worker + "\u{1F}" + record.key)
        }
        summaries[worker] = known
    }

    /// Reads one full record, when a line is opened. A record the service does not hold is asked
    /// for once.
    func open(worker: String, key: String) async {
        let id = worker + "\u{1F}" + key
        guard let source, records[worker]?[key] == nil, !reading.contains(id), !missing.contains(id) else { return }
        reading.insert(id)
        defer { reading.remove(id) }
        guard let record = try? await source.record(worker, key) else { missing.insert(id); return }
        records[worker, default: [:]][key] = record
    }

    func loadSettings() async {
        guard let source, let read = try? await source.readSettings() else { return }
        settings = read
        settingsLoaded = true
    }

    /// Saves a change. The shown value moves only when the service accepts it.
    func save(_ next: TranscriptSettings) async {
        guard let source else { settings = next; return }
        do {
            settings = try await source.writeSettings(next)
            settingsError = nil
            settingsLoaded = true
        } catch {
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
