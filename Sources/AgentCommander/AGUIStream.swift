import Foundation

struct AGUIToolCall: Decodable, Identifiable, Equatable, Sendable {
    struct Function: Decodable, Equatable, Sendable {
        let name: String
        let arguments: String
    }

    let id: String
    let function: Function
}

struct AGUIMessage: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    let content: String?
    let toolCalls: [AGUIToolCall]?
    let toolCallID: String?
    /// On a `tool` message: why the call ended without succeeding. Absent or empty on success and
    /// in projections that predate it. It is independent of `content`.
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, role, content, toolCalls, toolCallID = "toolCallId", error
    }
}

enum AGUIStreamError: LocalizedError {
    case unsupported
    case badFrame
    case disconnected

    var errorDescription: String? {
        switch self {
        case .unsupported: "The local service needs an update to stream AG-UI."
        case .badFrame: "The live console feed lost sync. Reconnecting."
        case .disconnected: "The live console feed disconnected. Reconnecting."
        }
    }
}

enum AGUIStream {
    static func follow(socket: String) -> AsyncThrowingStream<[Run], Error> {
        // Every event is applied in order. A slow viewer only needs the newest
        // fully reduced state, so intermediate display frames can be coalesced.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { output in
            let producer = Task.detached(priority: .userInitiated) {
                let client = Process()
                let pipe = Pipe()
                client.executableURL = URL(filePath: "/usr/bin/curl")
                client.arguments = [
                    "--disable", "--silent", "--fail", "--no-buffer", "--noproxy", "*",
                    "--connect-timeout", "3", "--speed-limit", "1", "--speed-time", "15",
                    "--unix-socket", socket, "--header", "Accept: text/event-stream",
                    "--write-out", "\ncommander-http-status: %{http_code}\n",
                    "http://localhost/v1/ag-ui/events"
                ]
                client.standardOutput = pipe
                client.standardError = FileHandle.nullDevice
                do {
                    try client.run()
                    defer {
                        if client.isRunning { client.terminate() }
                    }
                    _ = try? pipe.fileHandleForWriting.close()
                    var state = State()
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        try Task.checkCancellation()
                        if line == "commander-http-status: 404" { throw AGUIStreamError.unsupported }
                        // The local gateway emits one JSON data line per SSE frame.
                        // Other lines are heartbeats and the curl status trailer.
                        guard line.hasPrefix("data: ") else { continue }
                        if let runs = try state.apply(Data(line.dropFirst(6).utf8)) {
                            output.yield(runs)
                        }
                    }
                    try Task.checkCancellation()
                    throw AGUIStreamError.disconnected
                } catch {
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { _ in producer.cancel() }
        }
    }

    private struct State {
        private var runs: [Run]?

        mutating func apply(_ data: Data) throws -> [Run]? {
            let decoder = JSONDecoder()
            switch try decoder.decode(EventType.self, from: data).type {
            case "STATE_SNAPSHOT":
                let snapshot = try decoder.decode(Snapshot.self, from: data)
                runs = snapshot.snapshot.runs
            case "STATE_DELTA":
                guard var updated = runs else { throw AGUIStreamError.badFrame }
                let delta = try decoder.decode(Delta.self, from: data)
                for change in delta.delta {
                    switch change {
                    case .runs(let replacements):
                        updated = replacements
                    case .run(let index, let replacement):
                        guard updated.indices.contains(index), replacement.id == updated[index].id else {
                            throw AGUIStreamError.badFrame
                        }
                        updated[index] = replacement
                    }
                }
                runs = updated
            default:
                return nil
            }
            return runs
        }
    }

    private struct EventType: Decodable { let type: String }
    private struct Snapshot: Decodable {
        struct Workspace: Decodable { let runs: [Run] }
        let snapshot: Workspace
    }
    private struct Delta: Decodable { let delta: [Change] }

    private enum Change: Decodable {
        case runs([Run])
        case run(Int, Run)

        private enum CodingKeys: String, CodingKey { case op, path, value }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard try fields.decode(String.self, forKey: .op) == "replace" else {
                throw AGUIStreamError.badFrame
            }
            let path = try fields.decode(String.self, forKey: .path)
            if path == "/runs" {
                self = .runs(try fields.decode([Run].self, forKey: .value))
            } else if path.hasPrefix("/runs/"), let index = Int(path.dropFirst(6)) {
                self = .run(index, try fields.decode(Run.self, forKey: .value))
            } else {
                throw AGUIStreamError.badFrame
            }
        }
    }
}
