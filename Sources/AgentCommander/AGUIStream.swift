import Foundation
import Synchronization

/// Identity for values built from the live projection. Two values with the same non-zero stamp
/// came from one build and are equal without comparing their fields, which keeps comparing an
/// unchanged worker or message constant-time. Zero means no identity.
enum AGUIStamp {
    private static let counter = Atomic<UInt64>(0)

    static func next() -> UInt64 { counter.add(1, ordering: .relaxed).newValue }
}

struct AGUIToolCall: Decodable, Identifiable, Equatable, Sendable {
    struct Function: Decodable, Equatable, Sendable {
        let name: String
        /// The arguments as the JSON text the protocol carries. Structured arguments are
        /// written as compact JSON.
        let arguments: String
    }

    let id: String
    let function: Function
    /// Every field of the call as sent, including `type` and fields this model does not name.
    let allFields: AGUIValue

    init(id: String, function: Function) {
        self.id = id
        self.function = function
        allFields = [
            "id": .string(id), "type": "function",
            "function": ["name": .string(function.name), "arguments": .string(function.arguments)]
        ]
    }

    init(fields: AGUIValue) throws {
        guard let id = fields["id"]?.stringValue else { throw AGUIValueError("A tool call has no id") }
        let function = fields["function"]
        let arguments = function?["arguments"]
        self.id = id
        self.function = Function(name: function?["name"]?.stringValue ?? "",
                                 arguments: arguments.map { $0.isNull ? "" : $0.displayText } ?? "")
        allFields = fields
    }

    init(from decoder: Decoder) throws { try self.init(fields: AGUIValue(from: decoder)) }
}

/// Where a message came from in the worker's provider records: the service's
/// `metadata.acp` and `metadata.acpSources` entries.
struct AGUISource: Equatable, Sendable {
    /// The record source, such as the provider history or the live feed.
    let source: String
    /// Opaque position in that source. Empty when the record has none.
    let cursor: String
    let kind: String
    let messageID: String?
    let contentType: String?
    let mimeType: String?
    /// The whole reference, including usage and fields this model does not name.
    let allFields: AGUIValue

    init?(fields: AGUIValue) {
        guard case .object(let members) = fields else { return nil }
        source = members["source"]?.stringValue ?? ""
        cursor = members["cursor"]?.stringValue ?? ""
        kind = members["kind"]?.stringValue ?? ""
        messageID = members["messageId"]?.stringValue
        contentType = members["contentType"]?.stringValue
        mimeType = members["mimeType"]?.stringValue
        allFields = fields
    }
}

struct AGUIMessage: Decodable, Identifiable, Sendable {
    let id: String
    let role: String
    /// The message as readable text. Plain content is itself. Structured content reads as its
    /// text parts, with one bracketed line for each part that is not text. Nil when the
    /// message has no content. `allFields` holds the original.
    let content: String?
    let toolCalls: [AGUIToolCall]?
    let toolCallID: String?
    /// On a `tool` message: why the call ended without succeeding. Absent or empty on success and
    /// in projections that predate it. It is independent of `content`.
    let error: String?
    /// The whole message as the service sent it: explicit nulls, metadata, structured and
    /// multimodal content, and fields this model does not name.
    let allFields: AGUIValue

    private let stamp: UInt64

    static let namedFields: Set<String> = ["id", "role", "content", "toolCalls", "toolCallId", "error"]

    init(id: String, role: String, content: String? = nil, toolCalls: [AGUIToolCall]? = nil,
         toolCallID: String? = nil, error: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.error = error
        var fields: [String: AGUIValue] = ["id": .string(id), "role": .string(role)]
        if let content { fields["content"] = .string(content) }
        if let toolCalls { fields["toolCalls"] = .array(toolCalls.map(\.allFields)) }
        if let toolCallID { fields["toolCallId"] = .string(toolCallID) }
        if let error { fields["error"] = .string(error) }
        allFields = .object(fields)
        stamp = 0
    }

    /// Reads a message from the projection. It needs a string `id` and `role`; everything else
    /// is optional and kept in `allFields` whatever its shape.
    init(fields: AGUIValue) throws {
        guard case .object(let members) = fields else { throw AGUIValueError("A message is not an object") }
        guard let id = members["id"]?.stringValue, let role = members["role"]?.stringValue else {
            throw AGUIValueError("A message has no id or role")
        }
        self.id = id
        self.role = role
        content = members["content"].flatMap(AGUIContent.readableText)
        switch members["toolCalls"] {
        case .array(let calls)?: toolCalls = try calls.map(AGUIToolCall.init(fields:))
        case nil, .null?: toolCalls = nil
        default: throw AGUIValueError("Message \(id) has tool calls that are not a list")
        }
        toolCallID = members["toolCallId"]?.stringValue
        error = members["error"].flatMap { $0.isNull ? nil : $0.displayText }
        allFields = fields
        stamp = AGUIStamp.next()
    }

    init(from decoder: Decoder) throws { try self.init(fields: AGUIValue(from: decoder)) }
}

extension AGUIMessage: Equatable {
    static func == (lhs: AGUIMessage, rhs: AGUIMessage) -> Bool {
        if lhs.stamp != 0, lhs.stamp == rhs.stamp { return true }
        // Every other property is derived from the fields.
        return lhs.allFields == rhs.allFields
    }
}

extension AGUIMessage {
    /// The original `content`. Nil when the message has none; `.null` when it was sent as null.
    var contentValue: AGUIValue? { allFields["content"] }

    /// True when `content` is not plain text, so `content` is a reading of it.
    var hasStructuredContent: Bool { contentValue?.isContainer ?? false }

    /// The service's `metadata` object.
    var metadata: AGUIValue? { allFields["metadata"] }

    /// The provider records this message was built from, oldest first. A folded tool call can
    /// have several. Empty when the service attached none.
    var sources: [AGUISource] {
        guard let metadata else { return [] }
        if let listed = metadata["acpSources"]?.arrayValue, !listed.isEmpty {
            return listed.compactMap(AGUISource.init(fields:))
        }
        return metadata["acp"].flatMap(AGUISource.init(fields:)).map { [$0] } ?? []
    }

    /// The fields the typed properties do not show: everything except `id`, `role`, `error`,
    /// the tool-call fields and plain-text `content`. Structured content stays in. An object.
    var extendedFields: AGUIValue {
        var members = allFields.objectValue ?? [:]
        for key in Self.namedFields where key != "content" || !hasStructuredContent {
            members.removeValue(forKey: key)
        }
        return .object(members)
    }
}

/// Reads AG-UI message content as text. Content is a string, a list of typed parts, or a
/// single part.
enum AGUIContent {
    /// Nil for null. Each part that is not text reads as one bracketed line naming its type,
    /// media type and file, so an attachment is visible where it occurs.
    static func readableText(_ content: AGUIValue) -> String? {
        switch content {
        case .null: nil
        case .string(let text): text
        case .array(let parts): parts.map(partText).joined(separator: "\n")
        case .object: partText(content)
        case .bool, .number: content.compactText
        }
    }

    private static func partText(_ part: AGUIValue) -> String {
        guard case .object(let fields) = part else { return part.displayText }
        let type = fields["type"]?.stringValue
        if let text = fields["text"]?.stringValue, type == nil || type == "text" { return text }
        // The media type and name can sit on the part or on its `source`.
        let source = fields["source"]?.objectValue ?? [:]
        func first(_ keys: [String]) -> String? {
            for key in keys {
                if let text = fields[key]?.stringValue ?? source[key]?.stringValue, !text.isEmpty { return text }
            }
            return nil
        }
        var labels = [type ?? "content"]
        if let media = first(["mimeType", "mediaType", "mime_type", "media_type"]) { labels.append(media) }
        if let name = first(["filename", "name", "title"]) { labels.append(name) }
        return "[" + labels.joined(separator: " · ") + "]"
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

/// Splits a `text/event-stream` body into event payloads, one byte at a time. It also reads the
/// HTTP status line the transport appends after the body.
struct AGUIEventStreamParser {
    enum Output: Equatable {
        /// The joined `data` lines of one complete event.
        case event([UInt8])
        case status(Int)
    }

    /// A line longer than this is not a workspace frame.
    static let lineLimit = 256 << 20
    static let statusField = Array("commander-http-status".utf8)

    private var line: [UInt8] = []
    private var data: [UInt8] = []
    private var hasData = false
    private var afterCarriageReturn = false
    private let maximumLine: Int
    /// The most `data` bytes one event may join. Nil leaves only the line bound.
    private let maximumEvent: Int?

    /// A small feed, such as the catalog notices, passes tighter bounds so a misbehaving
    /// service cannot make it buffer without limit. The workspace feed keeps the defaults.
    init(lineLimit: Int = AGUIEventStreamParser.lineLimit, eventLimit: Int? = nil) {
        maximumLine = lineLimit
        maximumEvent = eventLimit
    }

    /// Feeds one byte. An event is returned at the blank line that ends it, so a frame cut off
    /// by a disconnect is never delivered.
    mutating func consume(_ byte: UInt8) throws -> Output? {
        if byte == 0x0A, afterCarriageReturn {
            afterCarriageReturn = false
            return nil
        }
        afterCarriageReturn = byte == 0x0D
        guard byte == 0x0A || byte == 0x0D else {
            guard line.count < maximumLine else { throw AGUIValueError("An event line is too long") }
            line.append(byte)
            return nil
        }
        defer { line.removeAll(keepingCapacity: line.capacity <= 1 << 16) }
        if line.isEmpty {
            guard hasData else { return nil }
            defer {
                data = []
                hasData = false
            }
            return .event(data)
        }
        let colon = line.firstIndex(of: UInt8(ascii: ":")) ?? line.endIndex
        guard colon > 0 else { return nil } // a comment, which the service uses as its heartbeat
        var start = min(colon + 1, line.endIndex)
        if start < line.endIndex, line[start] == 0x20 { start += 1 }
        let field = line[..<colon]
        if field.elementsEqual("data".utf8) {
            if let maximumEvent, data.count + (line.endIndex - start) + 1 > maximumEvent {
                throw AGUIValueError("An event is too long")
            }
            if hasData { data.append(0x0A) }
            data.append(contentsOf: line[start...])
            hasData = true
        } else if field.elementsEqual(Self.statusField) {
            return Int(String(decoding: line[start...], as: UTF8.self)).map(Output.status)
        }
        return nil
    }
}

enum AGUIStream {
    /// How many times in a row the feed is reopened after losing sync before the failure is
    /// reported. A delta that applies resets the count.
    static let resyncLimit = 3

    /// Follows the workspace. Each element is the complete current state.
    ///
    /// The service is asked for its incremental projection, where each change is a small JSON
    /// Patch against the last state. A service that predates it ignores the request and sends
    /// whole runs, which reduce the same way.
    static func follow(socket: String) -> AsyncThrowingStream<[Run], Error> {
        // Every event is applied in order. A slow viewer only needs the newest fully reduced
        // state, so states it has not taken yet are replaced and nothing accumulates.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { output in
            let producer = Task.detached(priority: .userInitiated) {
                var resyncs = 0
                do {
                    while true {
                        do {
                            try await connect(socket: socket) { runs, fromDelta in
                                if fromDelta { resyncs = 0 }
                                output.yield(runs)
                            }
                        } catch is AGUIValueError {
                            // A frame that cannot be applied leaves the last state in place.
                            // A new connection starts from a fresh snapshot.
                            resyncs += 1
                            guard resyncs <= resyncLimit else { throw AGUIStreamError.badFrame }
                            try await Task.sleep(for: .milliseconds(250 * resyncs))
                        }
                    }
                } catch {
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { _ in producer.cancel() }
        }
    }

    /// One connection, from its snapshot until it ends. It throws `AGUIValueError` when a frame
    /// cannot be applied, and otherwise ends with `disconnected` or `unsupported`.
    private static func connect(socket: String, yield: (_ runs: [Run], _ fromDelta: Bool) -> Void) async throws {
        let client = Process()
        let pipe = Pipe()
        client.executableURL = URL(filePath: "/usr/bin/curl")
        client.arguments = [
            "--disable", "--silent", "--fail", "--no-buffer", "--noproxy", "*",
            "--connect-timeout", "3", "--speed-limit", "1", "--speed-time", "15",
            "--unix-socket", socket, "--header", "Accept: text/event-stream",
            "--write-out", "\ncommander-http-status: %{http_code}\n",
            "http://localhost/v1/ag-ui/events?projection=incremental"
        ]
        client.standardOutput = pipe
        client.standardError = FileHandle.nullDevice
        try client.run()
        let transfer = Transfer(client)
        defer { transfer.end() }
        _ = try? pipe.fileHandleForWriting.close()
        try await withTaskCancellationHandler {
            var parser = AGUIEventStreamParser()
            var reducer = AGUIWorkspaceReducer()
            for try await byte in pipe.fileHandleForReading.bytes {
                guard let output = try parser.consume(byte) else { continue }
                try Task.checkCancellation()
                switch output {
                case .status(404): throw AGUIStreamError.unsupported
                case .status: break
                case .event(let frame):
                    if let change = try reducer.apply(frame: frame) {
                        yield(reducer.runs, change == .delta)
                    }
                }
            }
            try Task.checkCancellation()
            throw AGUIStreamError.disconnected
        } onCancel: {
            transfer.end()
        }
    }

    /// The transport process of one connection. Ending it closes the feed, which ends the read.
    private final class Transfer: @unchecked Sendable {
        private let process: Process

        init(_ process: Process) { self.process = process }

        func end() {
            if process.isRunning { process.terminate() }
        }
    }
}
