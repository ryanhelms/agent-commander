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

    enum CodingKeys: String, CodingKey {
        case id, name, role, parentID = "parent_id", runID = "run_id", state, host, worktree, task, output, error
        case client, branch, createdAt = "created_at", messages, control
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
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/curl")
        var args = ["--disable", "--silent", "--show-error", "--max-time", "6", "--noproxy", "*",
                    "--unix-socket", socket, "--write-out", "\n%{http_code}"]
        if let operationID { args += ["--header", "Idempotency-Key: \(operationID)"] }
        let body = try fields.map { try JSONEncoder().encode($0) }
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
