import Foundation
import Testing
@testable import AgentCommander

// The owner's text to a coordinator after native reattachment (issue #130). The model sends it
// through the same follow-up route as a delegated worker's, only once the service reports the
// coordinator bound, `available` and under a control record the owner holds. Every other
// coordinator state is refused before a request is made, and no generic worker gate opens.

/// The phases a socket fixture went through, each with its time since the fixture started. It
/// holds phase names, counts and status codes only: no request line, header, body or path.
private final class SocketTrace: @unchecked Sendable {
    private static let limit = 64
    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var phases: [String] = []
    private var dropped = 0
    private var connections = 0

    /// The number of the connection just accepted, counted from one.
    func connection() -> Int {
        lock.withLock {
            connections += 1
            return connections
        }
    }

    func note(_ phase: String) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        lock.withLock {
            if phases.count < Self.limit {
                phases.append("+\(elapsed)ms \(phase)")
            } else {
                dropped += 1
            }
        }
    }

    var summary: String {
        lock.withLock {
            phases.joined(separator: ", ") + (dropped > 0 ? ", and \(dropped) later phase(s) not kept" : "")
        }
    }
}

/// A Unix socket standing in for the service: it records each request's path, idempotency key and
/// body, and answers with the status it is set to.
///
/// One read source on a private serial queue owns the listening descriptor. It accepts and serves
/// one client per event, and only its cancel handler closes the descriptor and removes the socket
/// file. That handler runs on the same queue after the last event has been handled, so nothing
/// can call `accept` on the descriptor's number once it is free for another socket to reuse.
private final class FollowUpSocket: @unchecked Sendable {
    struct Request: Equatable {
        let path: String
        let operationID: String?
        let body: Data
    }

    /// A step of opening the listener that failed, with its `errno`.
    struct SetupFailure: Error, CustomStringConvertible {
        let step: String
        let code: Int32
        var description: String { "follow-up socket: \(step) failed, errno \(code)" }
    }

    let path: String
    /// What the listener did and when, for a failure message.
    let trace = SocketTrace()
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var seen: [Request] = []
    private var status = 200

    var requests: [Request] { lock.withLock { seen } }

    func answer(_ status: Int) { lock.withLock { self.status = status } }

    init() throws {
        let path = NSTemporaryDirectory() + "acf-\(getpid())-\(UInt32.random(in: 0..<999_999)).sock"
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        try #require(path.utf8.count < capacity)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SetupFailure(step: "socket", code: errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            // The file at this path, if any, is not this fixture's: leave it.
            let failure = SetupFailure(step: "bind", code: errno)
            close(listener)
            throw failure
        }
        // Nonblocking, so an event with no client behind it returns instead of holding the queue.
        guard listen(listener, 16) == 0, fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK) == 0 else {
            let failure = SetupFailure(step: "listen", code: errno)
            close(listener)
            unlink(path)
            throw failure
        }
        self.path = path
        source = DispatchSource.makeReadSource(fileDescriptor: listener,
                                               queue: DispatchQueue(label: "follow-up-socket"))
        trace.note("listening")
        // The handlers hold the trace, not the fixture, so the fixture is released as before and
        // its `deinit` cancels the source.
        source.setCancelHandler { [trace] in
            close(listener)
            unlink(path)
            trace.note("listener closed")
        }
        source.setEventHandler { [weak self, trace] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno != EWOULDBLOCK { trace.note("accept failed, errno \(errno)") }
                return
            }
            let served = trace.connection()
            trace.note("accepted connection \(served)")
            // Darwin hands the listener's nonblocking mode to the client; the reads below block.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            // A client that has already gone must fail the reply's write, not signal the process.
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
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
            trace.note(headEnd() == nil
                ? "connection \(served) closed before its headers ended, \(bytes.count) byte(s) read"
                : "headers of connection \(served) received")
            let bodyStart = (headEnd() ?? bytes.count) + separator.count
            let length = header("Content-Length").flatMap { Int($0) } ?? 0
            while bytes.count < bodyStart + length {
                let count = read(client, &chunk, chunk.count)
                guard count > 0 else { break }
                bytes.append(contentsOf: chunk[0..<count])
            }
            trace.note("body of connection \(served): \(max(0, bytes.count - bodyStart)) of \(length) byte(s) received")
            let parts = (head().first ?? "").split(separator: " ")
            let body = bytes.count > bodyStart ? Data(bytes[bodyStart...]) : Data()
            let operationID = header("Idempotency-Key")
            var status = 503
            var recorded = false
            if let self {
                self.lock.lock()
                if parts.count > 1 {
                    self.seen.append(Request(path: String(parts[1]), operationID: operationID, body: body))
                    recorded = true
                }
                status = self.status
                self.lock.unlock()
            }
            let payload = status == 200 ? "{}" : #"{"error":"refused"}"#
            let reply = Array(("HTTP/1.1 \(status) Answer\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n" + payload).utf8)
            let written = write(client, reply, reply.count)
            trace.note("connection \(served) answered \(status), request \(recorded ? "recorded" : "not recorded"), "
                + "\(written) of \(reply.count) reply byte(s) written")
            close(client)
        }
        source.activate()
    }

    deinit {
        // The cancel handler closes the descriptor and removes the file, after any event in hand.
        source.cancel()
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

    /// Sends the follow-up and describes the attempt for a failure message: how long the send
    /// took, the notice the model was left with, and what the socket did meanwhile. The socket's
    /// path is taken out of the notice, and no request content is included.
    private static func send(_ text: String, through model: CockpitModel,
                             to socket: FollowUpSocket) async -> (accepted: Bool, attempt: String) {
        let started = DispatchTime.now().uptimeNanoseconds
        let accepted = await model.sendFollowUp(to: "lead", text: text)
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let notice = model.notice.map { "\"\($0.replacingOccurrences(of: socket.path, with: "<socket>"))\"" } ?? "none"
        let attempt = "send returned \(accepted) after \(elapsed)ms; notice: \(notice); "
            + "connection \(model.connection); coordinator gate open: \(model.canSendCoordinatorFollowUp("lead")); "
            + "\(socket.requests.count) request(s) recorded; socket phases: \(socket.trace.summary)"
        return (accepted, attempt)
    }

    @Test func ownerTextReachesTheReattachedCoordinatorUnderItsCurrentGeneration() async throws {
        let socket = try FollowUpSocket()
        let model = Self.model(socket)
        model.runs = try runs(reattached)
        #expect(model.canSendCoordinatorFollowUp("lead"))

        let first = await Self.send("continue", through: model, to: socket)
        #expect(first.accepted, "\(first.attempt)")
        let request = try #require(socket.requests.first, "\(first.attempt)")
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
        let second = await Self.send("continue", through: model, to: socket)
        #expect(second.accepted, "\(second.attempt)")
        let next = try #require(socket.requests.last, "\(second.attempt)")
        #expect(try #require(try JSONSerialization.jsonObject(with: next.body) as? [String: Any])["generation"] as? Int == 5)
        #expect(next.operationID != request.operationID)
    }

    @Test func aRefusedCoordinatorFollowUpIsRetriedUnderTheSameOperationID() async throws {
        let socket = try FollowUpSocket()
        let model = Self.model(socket)
        model.runs = try runs(reattached)

        socket.answer(503)
        let refused = await Self.send("continue", through: model, to: socket)
        #expect(refused.accepted == false, "\(refused.attempt)")
        // The socket's own 503 answer. A send that failed another way, such as the client giving
        // up, leaves a different notice and is not the refusal this test retries.
        try #require(model.notice == "Send follow-up: refused", "\(refused.attempt)")
        socket.answer(200)
        let retried = await Self.send("continue", through: model, to: socket)
        #expect(retried.accepted, "\(retried.attempt)")
        // The same text under the same generation is the same operation; new text is a new one.
        let changed = await Self.send("then report", through: model, to: socket)
        #expect(changed.accepted, "\(changed.attempt)")
        let keys = socket.requests.map(\.operationID)
        // Exactly three requests, required before any of them is read by position.
        try #require(keys.count == 3, "\(changed.attempt)")
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
