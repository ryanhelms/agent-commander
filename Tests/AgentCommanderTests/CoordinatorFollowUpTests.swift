import Foundation
import Testing
@testable import AgentCommander

// The owner's text to a coordinator after native reattachment (issue #130). The model sends it
// through the same follow-up route as a delegated worker's, only once the service reports the
// coordinator bound, `available` and under a control record the owner holds. Every other
// coordinator state is refused before a request is made, and no generic worker gate opens.

/// A Unix socket standing in for the service: it records each request's path, idempotency key and
/// body, and answers with the status it is set to. The same shape as the hosts tests' socket.
private final class FollowUpSocket: @unchecked Sendable {
    struct Request: Equatable {
        let path: String
        let operationID: String?
        let body: Data
    }

    let path: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var seen: [Request] = []
    private var status = 200

    var requests: [Request] { lock.withLock { seen } }

    func answer(_ status: Int) { lock.withLock { self.status = status } }

    init() throws {
        path = NSTemporaryDirectory() + "acf-\(getpid())-\(UInt32.random(in: 0..<999_999)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        descriptor = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        try #require(path.utf8.count < capacity)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listener, 16) == 0)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var bytes = [UInt8]()
                var chunk = [UInt8](repeating: 0, count: 4096)
                let separator = Array("\r\n\r\n".utf8)
                func headEnd() -> Int? {
                    guard bytes.count >= separator.count else { return nil }
                    return (0...(bytes.count - separator.count)).first { Array(bytes[$0..<($0 + separator.count)]) == separator }
                }
                func head() -> [String] {
                    String(decoding: bytes[0..<(headEnd() ?? bytes.count)], as: UTF8.self)
                        .components(separatedBy: "\r\n")
                }
                func header(_ name: String) -> String? {
                    head().dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                        .map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
                }
                while headEnd() == nil {
                    let count = read(client, &chunk, chunk.count)
                    guard count > 0 else { break }
                    bytes.append(contentsOf: chunk[0..<count])
                }
                let bodyStart = (headEnd() ?? bytes.count) + separator.count
                let length = header("Content-Length").flatMap { Int($0) } ?? 0
                while bytes.count < bodyStart + length {
                    let count = read(client, &chunk, chunk.count)
                    guard count > 0 else { break }
                    bytes.append(contentsOf: chunk[0..<count])
                }
                let parts = (head().first ?? "").split(separator: " ")
                let body = bytes.count > bodyStart ? Data(bytes[bodyStart...]) : Data()
                let operationID = header("Idempotency-Key")
                var status = 503
                if let self {
                    self.lock.lock()
                    if parts.count > 1 {
                        self.seen.append(Request(path: String(parts[1]), operationID: operationID, body: body))
                    }
                    status = self.status
                    self.lock.unlock()
                }
                let payload = status == 200 ? "{}" : #"{"error":"refused"}"#
                let reply = Array(("HTTP/1.1 \(status) Answer\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n" + payload).utf8)
                _ = write(client, reply, reply.count)
                close(client)
            }
        }
    }

    deinit {
        close(descriptor)
        unlink(path)
    }
}

private func workerJSON(id: String, role: String = "worker", state: String = "idle", session: Bool = true,
                        control: String? = #"{"held":true,"generation":4}"#,
                        availability: String? = "available") -> String {
    let binding = session ? #""native_session":{"harness_instance":"local-claude-cli","session_id":"sess-\#(id)"},"# : ""
    let lease = control.map { #""control":\#($0),"# } ?? ""
    let available = availability.map { #""provider_availability":"\#($0)","# } ?? ""
    return #"{"id":"\#(id)","name":"\#(id)","role":"\#(role)","parent_id":"lead","run_id":"r","state":"\#(state)","host":"localhost","worktree":"/tmp/w","task":"build","error":"",\#(binding)\#(lease)\#(available)"outputChunks":[],"messages":[]}"#
}

private func runs(_ coordinator: String, status: String = "running") throws -> [Run] {
    let worker = workerJSON(id: "w")
    return try Run.list(json: Data(#"{"runs":[{"id":"r","project":"p","path":"/p","task":"ship it","client":"claude","coordinator_id":"lead","status":"\#(status)","requests":[],"workers":[\#(coordinator),\#(worker)]}]}"#.utf8))
}

/// The coordinator as the service reports it once a native resume is verified.
private let reattached = workerJSON(id: "lead", role: "coordinator")

@Suite @MainActor struct CoordinatorFollowUpTests {
    private static func model(_ socket: FollowUpSocket) -> CockpitModel {
        let model = CockpitModel(endpoint: ServiceEndpoint(environment: ["AGENT_COMMANDER_SOCKET": socket.path]))
        model.connection = .online
        return model
    }

    @Test func ownerTextReachesTheReattachedCoordinatorUnderItsCurrentGeneration() async throws {
        let socket = try FollowUpSocket()
        let model = Self.model(socket)
        model.runs = try runs(reattached)
        #expect(model.canSendCoordinatorFollowUp("lead"))

        #expect(await model.sendFollowUp(to: "lead", text: "continue"))
        let request = try #require(socket.requests.first)
        #expect(socket.requests.count == 1)
        // Addressed to exactly the coordinator, under the generation the service last reported.
        #expect(request.path == "/v1/workers/lead/messages")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["text"] as? String == "continue")
        #expect(body["generation"] as? Int == 4)
        #expect(Set(body.keys) == ["text", "generation"])
        #expect(request.operationID?.isEmpty == false)

        // A later reattachment moves the generation: the next send carries the new one.
        model.runs = try runs(workerJSON(id: "lead", role: "coordinator", control: #"{"held":true,"generation":5}"#))
        #expect(await model.sendFollowUp(to: "lead", text: "continue"))
        let next = try #require(socket.requests.last)
        #expect(try #require(try JSONSerialization.jsonObject(with: next.body) as? [String: Any])["generation"] as? Int == 5)
        #expect(next.operationID != request.operationID)
    }

    @Test func aRefusedCoordinatorFollowUpIsRetriedUnderTheSameOperationID() async throws {
        let socket = try FollowUpSocket()
        let model = Self.model(socket)
        model.runs = try runs(reattached)

        socket.answer(503)
        #expect(await model.sendFollowUp(to: "lead", text: "continue") == false)
        #expect(model.notice?.hasPrefix("Send follow-up:") == true)
        socket.answer(200)
        #expect(await model.sendFollowUp(to: "lead", text: "continue"))
        // The same text under the same generation is the same operation; new text is a new one.
        #expect(await model.sendFollowUp(to: "lead", text: "then report"))
        let keys = socket.requests.map(\.operationID)
        #expect(keys.count == 3)
        #expect(keys[0] != nil && keys[0] == keys[1])
        #expect(keys[2] != keys[1])
    }

    @Test func anUnheldStartingOrUnverifiedCoordinatorIsRefusedBeforeAnyRequest() async throws {
        let socket = try FollowUpSocket()
        let model = Self.model(socket)
        func coordinator(state: String = "idle", session: Bool = true,
                         control: String? = #"{"held":true,"generation":4}"#,
                         availability: String? = "available") -> String {
            workerJSON(id: "lead", role: "coordinator", state: state, session: session, control: control,
                       availability: availability)
        }
        let refused: [(String, [Run])] = [
            ("unheld", try runs(coordinator(control: #"{"held":false,"generation":4}"#))),
            ("starting", try runs(coordinator(state: "starting", availability: "reattaching"))),
            ("unknown during recovery", try runs(coordinator(state: "unknown", availability: "reattaching"))),
            ("reattaching", try runs(coordinator(availability: "reattaching"))),
            ("checking", try runs(coordinator(availability: "checking"))),
            ("exited", try runs(coordinator(state: "stopped", control: #"{"held":false,"generation":4}"#,
                                            availability: "exited"))),
            ("availability not reported", try runs(coordinator(availability: nil))),
            ("no control record", try runs(coordinator(control: nil))),
            ("no bound session", try runs(coordinator(session: false))),
            ("run not running", try runs(coordinator(), status: "completed"))
        ]
        for (name, state) in refused {
            model.runs = state
            #expect(!model.canSendCoordinatorFollowUp("lead"), "\(name)")
            #expect(await model.sendFollowUp(to: "lead", text: "continue") == false, "\(name)")
        }
        #expect(socket.requests.isEmpty)
        #expect(model.notice == nil)
    }

    @Test func theCoordinatorGateOpensNoGenericWorkerCapability() async throws {
        let socket = try FollowUpSocket()
        let model = Self.model(socket)
        model.runs = try runs(reattached)
        #expect(model.canSendCoordinatorFollowUp("lead"))

        #expect(!model.canControlWorker("lead"))
        #expect(!model.canInterruptWorker("lead"))
        #expect(!model.canStopWorker("lead"))
        #expect(model.elicitationScope("lead") == nil)
        #expect(model.interruptTarget("lead") == nil)
        await model.takeControl("lead")
        await model.handBack("lead")
        await model.interruptWorker("lead")
        await model.stopWorker("lead")
        await model.cancelFollowUp("lead", messageID: "fu-1")
        // File context is a delegated worker's: a draft with a file is refused, not sent as text.
        let file = FollowUpContextItem(
            id: UUID(), kind: .link, name: "notes.txt", mimeType: "text/plain", byteCount: 10, path: "/tmp/w/notes.txt",
            part: .resourceLink(uri: "file:///tmp/w/notes.txt", name: "notes.txt", mimeType: "text/plain"))
        #expect(await model.sendFollowUp(to: "lead", text: "read this", context: [file]) == false)
        #expect(socket.requests.isEmpty)

        // The gate is the coordinator's alone: a delegated worker is decided as before.
        #expect(!model.canSendCoordinatorFollowUp("w"))
        #expect(model.canControlWorker("w"))
    }
}
