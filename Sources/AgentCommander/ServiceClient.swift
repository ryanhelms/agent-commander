import Foundation

struct WorkerFollowUp: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let status: String
}

struct WorkerControl: Decodable, Equatable, Sendable {
    let held: Bool
    let generation: Int
    let interruptRequested: Bool?
    let messages: [WorkerFollowUp]?

    private enum CodingKeys: String, CodingKey {
        case held, generation, interruptRequested = "interrupt_requested", messages
    }
}

struct Worker: Decodable, Identifiable, Equatable, Sendable {
    let id, name, role, parentID, runID, state, host, worktree, task, output: String
    let error: String?
    // Optional metadata. Older service records omit these; the interface shows them only when present.
    var client: String? = nil
    var branch: String? = nil
    var createdAt: String? = nil
    var messages: [AGUIMessage]? = nil
    var control: WorkerControl? = nil
    /// Link to the execution host. Sent only for workers in persistent SSH mode, as `connected`
    /// or `reconnecting`. While it reconnects, `state` keeps the worker's own turn state.
    var connection: String? = nil

    /// The service's value for a persistent link that is being re-established. A contract value.
    static let connectionReconnecting = "reconnecting"

    /// The provider session the service has bound this worker to. Legacy and unbound workers
    /// omit it, and they have no provider source to inspect.
    var nativeSession: NativeSession? = nil

    /// The binding, when it names a session. Only then is the worker's source offered.
    var boundSession: NativeSession? {
        nativeSession.flatMap { $0.sessionID.isEmpty ? nil : $0 }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, parentID = "parent_id", runID = "run_id", state, host, worktree, task, output, error
        case client, branch, createdAt = "created_at", messages, control, connection
        case nativeSession = "native_session"
    }
}

/// A worker's provider session, as the service reports it. It is shown for provenance only:
/// requests address the worker by its ID and the service resolves the session itself.
struct NativeSession: Equatable, Sendable {
    let harnessInstance: String
    let sessionID: String
}

extension NativeSession: Decodable {
    private enum CodingKeys: String, CodingKey {
        case harnessInstance = "harness_instance", sessionID = "session_id"
    }

    /// Never throws: an unreadable binding reads as unbound, so it cannot cost the worker its
    /// ordinary console.
    init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        harnessInstance = (try? fields?.decodeIfPresent(String.self, forKey: .harnessInstance)) ?? ""
        sessionID = (try? fields?.decodeIfPresent(String.self, forKey: .sessionID)) ?? ""
    }
}

/// Where a worker's source records are read from. The provider's own history is the default;
/// the other two are named in the request.
enum ConsoleSourceKind: String, CaseIterable, Identifiable, Sendable {
    case provider, live, journal

    var id: String { rawValue }

    /// The `source` query value. The provider history is the request without one.
    var queryValue: String? { self == .provider ? nil : rawValue }
}

/// One record of a worker's source, in the portable SDK envelope. Optional strings that the
/// service leaves out are empty here. `record` is the original structured record as sent.
struct SourceObservation: Identifiable, Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case text(speaker: String, text: String)
        case tool(callID: String, name: String, phase: String, summary: String)
        /// A historical input request. It is shown and never answered from here.
        case input(prompt: String, choices: [String])
        case turnEnded(reason: String)
        /// The source states that records are missing here, and why.
        case gap(reason: String)
        /// A provider extension. `data` is the decoded bytes, nil when the base64 is unreadable.
        case attachment(type: String, mediaType: String, data: Data?)
        /// A record with none of the known bodies.
        case unrecognized
    }

    /// How much of a record is drawn. The whole record stays available to copy.
    static let recordDisplayLimit = 6_000

    /// Position in the selected source, assigned as pages arrive. Stable while that source is open.
    var id: String
    let session: NativeSession?
    let cursor: String
    let turnID: String
    let body: Body
    /// The original record, as indented JSON.
    let record: String
    /// The start of `record`, at most `recordDisplayLimit` characters.
    let recordDisplay: String
    /// Characters of `record` left out of `recordDisplay`.
    let recordOmitted: Int
}

struct SourcePage: Sendable {
    var observations: [SourceObservation]
    let nextCursor: String?
}

extension SourcePage {
    /// Reads the envelope `{ "observations": [...], "nextCursor": "..." }`. Either field may be absent.
    init(envelope data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.rejected("The service returned an unreadable source page.")
        }
        let items = root["observations"] as? [Any] ?? []
        observations = items.enumerated().map { index, item in SourceObservation(json: item, index: index) }
        let next = root["nextCursor"] as? String ?? ""
        nextCursor = next.isEmpty ? nil : next
    }
}

extension SourceObservation {
    init(json: Any, index: Int) {
        let fields = json as? [String: Any] ?? [:]
        func string(_ object: [String: Any], _ key: String) -> String {
            switch object[key] {
            case let value as String: value
            case let value as NSNumber: value.stringValue
            default: ""
            }
        }

        id = String(index)
        if let session = fields["session"] as? [String: Any] {
            self.session = NativeSession(harnessInstance: string(session, "harnessInstance"),
                                         sessionID: string(session, "sessionId"))
        } else {
            session = nil
        }
        cursor = string(fields, "cursor")
        turnID = string(fields, "turnId")

        if let gap = fields["gap"] as? [String: Any] {
            body = .gap(reason: string(gap, "reason"))
        } else if let text = fields["text"] as? [String: Any] {
            body = .text(speaker: string(text, "speaker"), text: string(text, "text"))
        } else if let tool = fields["tool"] as? [String: Any] {
            body = .tool(callID: string(tool, "callId"), name: string(tool, "name"),
                         phase: string(tool, "phase"), summary: string(tool, "summary"))
        } else if let input = fields["input"] as? [String: Any] {
            let choices = (input["choices"] as? [Any] ?? []).map(Self.choiceLabel)
            body = .input(prompt: string(input, "prompt"), choices: choices)
        } else if let ended = fields["turnEnded"] as? [String: Any] {
            body = .turnEnded(reason: string(ended, "reason"))
        } else if let ext = fields["extension"] as? [String: Any] {
            let encoded = string(ext, "data")
            body = .attachment(type: string(ext, "type"), mediaType: string(ext, "mediaType"),
                               data: encoded.isEmpty ? Data() : Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        } else {
            body = .unrecognized
        }

        let full = Self.text(of: json, pretty: true)
        record = full
        if let cut = full.index(full.startIndex, offsetBy: Self.recordDisplayLimit, limitedBy: full.endIndex),
           cut != full.endIndex {
            recordDisplay = String(full[..<cut])
            recordOmitted = full.distance(from: cut, to: full.endIndex)
        } else {
            recordDisplay = full
            recordOmitted = 0
        }
    }

    /// A choice as text: the string itself, or the naming field of a structured choice.
    private static func choiceLabel(_ choice: Any) -> String {
        if let text = choice as? String { return text }
        if let object = choice as? [String: Any] {
            for key in ["label", "title", "name", "text", "value", "id"] {
                if let text = object[key] as? String, !text.isEmpty { return text }
            }
        }
        return text(of: choice, pretty: false)
    }

    private static func text(of json: Any, pretty: Bool) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: options) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct Question: Decodable, Identifiable, Equatable, Sendable {
    let id, workerID, question, status, answer: String
    /// What the service knows about the answer reaching the worker. Absent on older records and on
    /// requests that have no answer yet.
    var delivery: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, workerID = "worker_id", question, status, answer, delivery
    }

    /// The answer was accepted, and the service cannot say whether the worker received it.
    var deliveryIsUnknown: Bool { delivery?.lowercased() == "unknown" }
}

struct Run: Decodable, Identifiable, Equatable, Sendable {
    let id, project, path, task, client, coordinatorID, status: String
    let workers: [Worker]?
    let requests: [Question]?
    // Optional metadata. Older service records omit these; the interface shows them only when present.
    var givenTitle: String? = nil
    var createdAt: String? = nil
    var branch: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, project, path, task, client, coordinatorID = "coordinator_id", status, workers, requests
        case givenTitle = "title", createdAt = "created_at", branch
    }

    var canStop: Bool {
        if status == "running" { return true }
        return status == "failed" && (workers ?? []).contains { !["completed", "failed", "stopped"].contains($0.state) }
    }

    var coordinator: Worker? { workers?.first { $0.id == coordinatorID } }
    var delegates: [Worker] { (workers ?? []).filter { $0.id != coordinatorID } }
    var title: String {
        if let given = givenTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty { return given }
        return String(task.split(whereSeparator: \.isNewline).first ?? "Untitled run")
    }
}

struct RunList: Decodable, Sendable { let runs: [Run]? }

struct PendingDecision: Identifiable {
    let run: Run
    let worker: Worker
    let request: Question
    var id: String { request.id }
}

enum ServiceError: LocalizedError {
    case offline(String)
    case rejected(String)
    var errorDescription: String? {
        switch self { case .offline(let detail), .rejected(let detail): detail }
    }
}

// All GUI operations use the local HTTP API. The serialized client keeps short
// requests off the UI thread and sends project paths and prompt text as JSON data.
actor ServiceClient {
    private let socket: String
    private let command: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["AGENT_COMMANDER_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ??
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Agent Commander")
        socket = environment["AGENT_COMMANDER_SOCKET"] ?? environment["AC_SOCKET"] ?? home.appending(path: "service.sock").path
        if let path = environment["AGENT_COMMANDER_CLI"] ?? environment["AC_CLI"] {
            command = URL(filePath: path)
        } else {
            command = Bundle.main.url(forAuxiliaryExecutable: "agentctl") ??
                Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "agentctl")
        }
    }

    func runs() throws -> [Run] {
        try JSONDecoder().decode(RunList.self, from: request("/v1/runs")).runs ?? []
    }

    func watchRuns() -> AsyncThrowingStream<[Run], Error> {
        AGUIStream.follow(socket: socket)
    }

    func create(path: String, task: String, title: String? = nil, operationID: String) throws -> Run {
        var fields = ["project": URL(filePath: path).lastPathComponent, "path": path, "task": task, "client": "claude"]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { fields["title"] = title }
        return try JSONDecoder().decode(Run.self, from: request("/v1/runs", fields: fields, operationID: operationID))
    }

    func reply(to requestID: String, answer: String, operationID: String) throws {
        _ = try request("/v1/requests/\(requestID)/reply", fields: ["answer": answer], operationID: operationID)
    }

    func stop(runID: String) throws {
        _ = try request("/v1/runs/\(runID)/stop", fields: [String: String]())
    }

    func setWorkerControl(_ workerID: String, held: Bool, generation: Int) throws {
        struct Change: Encodable { let held: Bool; let generation: Int }
        _ = try request("/v1/workers/\(workerID)/control", fields: Change(held: held, generation: generation))
    }

    func sendFollowUp(to workerID: String, text: String, generation: Int, operationID: String) throws {
        struct FollowUp: Encodable { let text: String; let generation: Int }
        _ = try request("/v1/workers/\(workerID)/messages",
                        fields: FollowUp(text: text, generation: generation), operationID: operationID)
    }

    func interruptWorker(_ workerID: String) throws {
        _ = try request("/v1/workers/\(workerID)/interrupt", fields: [String: String]())
    }

    func stopWorker(_ workerID: String) throws {
        _ = try request("/v1/workers/\(workerID)/stop", fields: [String: String]())
    }

    /// One page of a worker's source records. The worker ID is the only address: the service has
    /// already bound the provider session. `cursor` is the `nextCursor` of an earlier page of the
    /// same worker and source.
    ///
    /// A read is not queued behind this client's other requests, and cancelling the calling task
    /// ends the transfer, so an abandoned read does not hold up the next one.
    nonisolated func workerHistory(_ workerID: String, source: ConsoleSourceKind, cursor: String? = nil,
                                   limit: Int = 12) async throws -> SourcePage {
        var query = "limit=\(limit)"
        if let value = source.queryValue { query += "&source=\(value)" }
        if let cursor, !cursor.isEmpty { query += "&cursor=\(Self.percentEncoded(cursor))" }
        let path = "/v1/workers/\(Self.percentEncoded(workerID))/history?\(query)"
        let socket = socket
        let transfer = Transfer()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                // A provider may take longer to read its history than a state change takes to accept.
                let data = try Self.send(socket: socket, path: path, body: nil, operationID: nil,
                                         timeout: 20, transfer: transfer)
                try Task.checkCancellation()
                return try SourcePage(envelope: data)
            }.value
        } onCancel: {
            transfer.cancel()
        }
    }

    /// The process of one cancellable request. Cancelling before it starts stops it at launch.
    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func started(_ process: Process) {
            lock.lock()
            defer { lock.unlock() }
            self.process = process
            if cancelled { process.terminate() }
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// Percent-encodes everything outside the RFC 3986 unreserved set, for one path segment or
    /// query value.
    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    func startService() throws {
        guard let command, FileManager.default.isExecutableFile(atPath: command.path) else {
            throw ServiceError.offline("Start the local service with agentctl start, or open the built Agent Commander app.")
        }
        let process = Process()
        process.executableURL = command
        process.arguments = ["start"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ServiceError.offline(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func request(_ path: String, fields: (any Encodable)? = nil, operationID: String? = nil) throws -> Data {
        let body = try fields.map { try JSONEncoder().encode($0) }
        return try Self.send(socket: socket, path: path, body: body, operationID: operationID)
    }

    /// One request over the owner socket. `transfer`, when given, lets the caller end it early.
    private static func send(socket: String, path: String, body: Data?, operationID: String?,
                             timeout: Int = 6, transfer: Transfer? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/curl")
        var args = ["--disable", "--silent", "--show-error", "--max-time", String(timeout), "--noproxy", "*",
                    "--unix-socket", socket, "--write-out", "\n%{http_code}"]
        if let operationID { args += ["--header", "Idempotency-Key: \(operationID)"] }
        let input = Pipe()
        if body != nil {
            args += ["--header", "Content-Type: application/json", "--data-binary", "@-"]
            process.standardInput = input
        }
        process.arguments = args + ["http://localhost\(path)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        transfer?.started(process)
        if let body {
            try input.fileHandleForWriting.write(contentsOf: body)
            try input.fileHandleForWriting.close()
        }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ServiceError.offline("The local service is unreachable at \(socket).")
        }
        guard let separator = bytes.lastIndex(of: 10), let status = Int(String(decoding: bytes.suffix(from: separator + 1), as: UTF8.self)) else {
            throw ServiceError.rejected("The service returned an unreadable response.")
        }
        let payload = bytes.prefix(upTo: separator)
        guard (200..<300).contains(status) else {
            let info = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let message = info?["error"] as? String ?? info?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw ServiceError.rejected(message)
        }
        return Data(payload)
    }
}
