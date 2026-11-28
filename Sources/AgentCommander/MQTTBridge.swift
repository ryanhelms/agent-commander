import Foundation
import Observation
import SwiftUI

// The MQTT Bridge plugin's panel: what the local MQTT Bridge daemon carries, read from its own
// HTTP API on the loopback (`mqttbridge serve --http 127.0.0.1:18830`). The app only reads;
// publishing stays in the bridge's own web UI.
//
//   Values         MQTTStatus           the broker's counters
//                  MQTTMessage          one recorded message
//                  MQTTTopic            a topic, its count and its last message
//                  MQTTTopicNode        one level of the topic tree
//                  MQTTPayload          a payload as the inspector shows it: JSON, text or bytes
//   Reading        MQTTSnapshot         reads the daemon's JSON
//                  MQTTStream           one connection to GET /api/stream
//   Feature model  MQTTBridgeFeed       the subscription, the chosen topic, pause and the selection
//   For the page   MQTTContext          the feed's state as values, and its intents (MQTTActions)
//
// The panel (MQTTPanel.swift) takes values and emits actions. Only `MQTTContext.init(feed:)`
// reads the model.

enum MQTTBridge {
    /// The plugin whose panel this is.
    static let pluginID = "adag.mqtt"
    /// Where the daemon serves its API and its web UI.
    static let address = "127.0.0.1:18830"
    static var webUI: URL { URL(string: "http://\(address)")! }
    /// The most messages the live list keeps.
    static let messageLimit = 300
    /// How many recorded messages are read when the list opens or its topic changes.
    static let backlog = 100
}

// MARK: - Values

struct MQTTStatus: Equatable, Sendable {
    var version = ""
    var mqttAddress = ""
    var uptimeSeconds = 0
    var clientsConnected = 0
    var subscriptions = 0
    var messagesReceived = 0
    var messagesSent = 0
    var retained = 0
    var topics = 0
    var messagesRecorded = 0
    /// Topics the bridge stopped tracking because it holds too many.
    var topicsDropped = 0

    /// "2 d 4 h", "47 min", "12 s".
    var uptime: String {
        let seconds = max(0, uptimeSeconds)
        switch seconds {
        case ..<60: return "\(seconds) s"
        case ..<3600: return "\(seconds / 60) min"
        case ..<86_400: return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
        default: return "\(seconds / 86_400) d \(seconds % 86_400 / 3600) h"
        }
    }
}

struct MQTTMessage: Identifiable, Equatable, Sendable {
    enum Encoding: String, Sendable { case utf8, base64 }

    let seq: Int
    var time: Date? = nil
    var topic: String
    /// The payload as text, or as base64 when `encoding` says so.
    var payload = ""
    var encoding: Encoding = .utf8
    /// The payload's size on the wire, in bytes.
    var size = 0
    /// The bridge kept only the start of the payload.
    var truncated = false
    var qos = 0
    var retain = false
    var client = ""

    var id: Int { seq }

    /// One line for the list: text with its line breaks folded, or what the bytes are.
    var preview: String {
        guard encoding == .utf8 else { return "binary, \(MQTTPayload.byteCount(size))" }
        if payload.isEmpty { return "empty" }
        let line = payload.prefix(240).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.isEmpty ? "empty" : line
    }
}

struct MQTTTopic: Identifiable, Equatable, Sendable {
    let topic: String
    var count = 0
    var last: MQTTMessage? = nil
    var lastSeen: Date? = nil

    var id: String { topic }
}

/// One level of the topic tree. `plant/line1/temp` gives three nodes, each inside the last.
struct MQTTTopicNode: Identifiable, Equatable, Sendable {
    /// The levels down to this one, joined by `/`: "plant/line1".
    let path: String
    /// This level's own name: "line1".
    let name: String
    /// Messages on exactly this topic. Zero for a level that is only a prefix.
    var count = 0
    /// Messages on this topic and everything under it.
    var total = 0
    /// Messages were published on exactly this path.
    var isTopic = false
    var children: [MQTTTopicNode] = []

    var id: String { path }
    /// What choosing the node reads: the topic itself and everything under it.
    var filter: String { MQTTTopicTree.filter(for: path) }
}

/// One row of the tree as it is drawn: a node and how deep it sits.
struct MQTTTopicRow: Identifiable, Equatable, Sendable {
    let node: MQTTTopicNode
    let depth: Int
    var isExpanded = false

    var id: String { node.path }
    var hasChildren: Bool { !node.children.isEmpty }
}

enum MQTTTopicTree {
    /// Builds the tree from the bridge's flat list: topics split on `/`, with each level's
    /// total. Levels are ordered by name. An empty level (`a//b`, a leading `/`) is kept as it is
    /// written, because MQTT treats it as a level.
    static func build(_ topics: [MQTTTopic]) -> [MQTTTopicNode] {
        final class Builder {
            let path: String
            let name: String
            var count = 0
            var isTopic = false
            var children: [String: Builder] = [:]

            init(path: String, name: String) {
                self.path = path
                self.name = name
            }

            func node() -> MQTTTopicNode {
                let below = children.values.map { $0.node() }.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return MQTTTopicNode(path: path, name: name, count: count, total: count + below.reduce(0) { $0 + $1.total },
                                     isTopic: isTopic, children: below)
            }
        }
        let root = Builder(path: "", name: "")
        for topic in topics where !topic.topic.isEmpty {
            var at = root
            var path = ""
            for (index, level) in topic.topic.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
                path = index == 0 ? String(level) : "\(path)/\(level)"
                if let next = at.children[String(level)] {
                    at = next
                } else {
                    let next = Builder(path: path, name: String(level))
                    at.children[String(level)] = next
                    at = next
                }
            }
            at.count += topic.count
            at.isTopic = true
        }
        return root.node().children
    }

    /// The filter that reads a node and everything under it.
    static func filter(for path: String) -> String { "\(path)/#" }

    /// The rows to draw: every root, and the children of each expanded node.
    static func rows(_ nodes: [MQTTTopicNode], expanded: Set<String>, depth: Int = 0) -> [MQTTTopicRow] {
        nodes.flatMap { node -> [MQTTTopicRow] in
            let isOpen = expanded.contains(node.path) && !node.children.isEmpty
            return [MQTTTopicRow(node: node, depth: depth, isExpanded: isOpen)]
                + (isOpen ? rows(node.children, expanded: expanded, depth: depth + 1) : [])
        }
    }

    /// Whether a topic is the node at `path` or under it: what the filter `path/#` matches.
    static func matches(_ topic: String, under path: String?) -> Bool {
        guard let path else { return true }
        return topic == path || topic.hasPrefix(path + "/")
    }

    /// The paths that lead to a node, so it can be shown open.
    static func ancestors(of path: String) -> [String] {
        let levels = path.split(separator: "/", omittingEmptySubsequences: false)
        return (1..<max(levels.count, 1)).map { levels.prefix($0).joined(separator: "/") }
    }
}

/// A payload as the inspector shows it.
struct MQTTPayload: Equatable, Sendable {
    enum Form: String, CaseIterable, Sendable {
        case json, text, hex, base64

        var title: String {
            switch self {
            case .json: "JSON"
            case .text: "Text"
            case .hex: "Hex"
            case .base64: "Base64"
            }
        }
    }

    /// The forms on offer, the best one first.
    var forms: [Form] = []
    private var texts: [Form: String] = [:]

    func text(_ form: Form) -> String { texts[form] ?? "" }

    /// The most bytes shown as a hex dump.
    static let hexLimit = 4096

    init(_ message: MQTTMessage) {
        switch message.encoding {
        case .utf8:
            if let value = try? AGUIValue(json: message.payload), value.isContainer {
                forms.append(.json)
                texts[.json] = value.prettyText
            }
            forms.append(.text)
            texts[.text] = message.payload
            forms.append(.hex)
            texts[.hex] = Self.hexDump(Data(message.payload.utf8))
        case .base64:
            let bytes = Data(base64Encoded: message.payload) ?? Data()
            forms = [.hex, .base64]
            texts[.hex] = Self.hexDump(bytes)
            texts[.base64] = message.payload
        }
    }

    static func byteCount(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    /// Sixteen bytes a line: the offset, the bytes in hex, then the printable ASCII.
    static func hexDump(_ data: Data, limit: Int = hexLimit) -> String {
        guard !data.isEmpty else { return "" }
        let bytes = Array(data.prefix(limit))
        var lines: [String] = []
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[start..<min(start + 16, bytes.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(row.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%04x  ", start) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Reading

enum MQTTSnapshot {
    private struct StatusWire: Decodable {
        let version: String?
        let mqtt_address: String?
        let uptime_seconds: Double?
        let clients_connected: Int?
        let subscriptions: Int?
        let messages_received: Int?
        let messages_sent: Int?
        let retained: Int?
        let topics: Int?
        let messages_recorded: Int?
        let topics_dropped: Int?

        var value: MQTTStatus {
            MQTTStatus(version: version ?? "", mqttAddress: mqtt_address ?? "", uptimeSeconds: Int(uptime_seconds ?? 0),
                       clientsConnected: clients_connected ?? 0, subscriptions: subscriptions ?? 0,
                       messagesReceived: messages_received ?? 0, messagesSent: messages_sent ?? 0, retained: retained ?? 0,
                       topics: topics ?? 0, messagesRecorded: messages_recorded ?? 0, topicsDropped: topics_dropped ?? 0)
        }
    }

    private struct MessageWire: Decodable {
        let seq: Int?
        let time: String?
        let topic: String?
        let payload: String?
        let encoding: String?
        let size: Int?
        let truncated: Bool?
        let qos: Int?
        let retain: Bool?
        let client: String?

        var value: MQTTMessage? {
            guard let seq, let topic else { return nil }
            return MQTTMessage(seq: seq, time: MQTTSnapshot.date(time), topic: topic, payload: payload ?? "",
                               encoding: MQTTMessage.Encoding(rawValue: encoding ?? "utf8") ?? .utf8,
                               size: size ?? (payload ?? "").utf8.count, truncated: truncated ?? false, qos: qos ?? 0,
                               retain: retain ?? false, client: client ?? "")
        }
    }

    private struct TopicWire: Decodable {
        let topic: String?
        let count: Int?
        let last: MessageWire?
        let last_seen: String?
    }

    private struct TopicsWire: Decodable { let topics: [TopicWire]? }
    private struct MessagesWire: Decodable { let messages: [MessageWire]? }
    /// A stream event is told apart by its members: a message has a topic, a status an address.
    private struct EventWire: Decodable {
        let topic: String?
        let seq: Int?
        let mqtt_address: String?
        let uptime_seconds: Double?
    }

    /// An RFC 3339 time with any number of fraction digits, as Go writes it.
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        guard let dot = text.firstIndex(of: ".") else { return HarnessSnapshot.date(text) }
        let rest = text[text.index(after: dot)...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let whole = HarnessSnapshot.date(String(text[..<dot]) + rest.dropFirst(digits.count)),
              let fraction = Double("0." + digits) else { return HarnessSnapshot.date(text) }
        return whole.addingTimeInterval(fraction)
    }

    static func status(_ data: Data) throws -> MQTTStatus { try JSONDecoder().decode(StatusWire.self, from: data).value }

    static func message(_ data: Data) throws -> MQTTMessage {
        guard let message = try JSONDecoder().decode(MessageWire.self, from: data).value else {
            throw AGUIValueError("A message has no sequence number or topic")
        }
        return message
    }

    static func topics(_ data: Data) throws -> [MQTTTopic] {
        (try JSONDecoder().decode(TopicsWire.self, from: data).topics ?? []).compactMap { wire in
            guard let topic = wire.topic, !topic.isEmpty else { return nil }
            return MQTTTopic(topic: topic, count: wire.count ?? 0, last: wire.last?.value, lastSeen: MQTTSnapshot.date(wire.last_seen))
        }
    }

    static func messages(_ data: Data) throws -> [MQTTMessage] {
        (try JSONDecoder().decode(MessagesWire.self, from: data).messages ?? []).compactMap(\.value)
    }

    /// One event of `/api/stream`. Nil for a frame that is neither a status nor a message.
    static func event(_ data: Data) -> MQTTStream.Event? {
        guard let shape = try? JSONDecoder().decode(EventWire.self, from: data) else { return nil }
        if shape.topic != nil, shape.seq != nil { return (try? message(data)).map(MQTTStream.Event.message) }
        if shape.mqtt_address != nil || shape.uptime_seconds != nil { return (try? status(data)).map(MQTTStream.Event.status) }
        return nil
    }
}

/// The daemon's HTTP API over the loopback, through the same curl transport as the service's.
enum MQTTStream {
    enum Event: Equatable, Sendable {
        case status(MQTTStatus)
        case message(MQTTMessage)
    }

    enum Failure: Error, Equatable {
        /// Nothing answers at the address, or the answer wasn't the bridge's.
        case offline
        case disconnected
    }

    /// A filter as a query value: everything outside the unreserved set is escaped, so `#`, `+`
    /// and `/` reach the bridge as written.
    static func query(_ items: [(String, String?)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = items.compactMap { name, value in
            value.map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        }
        return pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
    }

    /// One GET, off the main actor.
    static func get(_ path: String, address: String = MQTTBridge.address, timeout: Int = 4) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let client = Process()
            let output = Pipe()
            client.executableURL = URL(filePath: "/usr/bin/curl")
            client.arguments = ["--disable", "--silent", "--fail", "--noproxy", "*", "--connect-timeout", "2",
                                "--max-time", String(timeout), "http://\(address)\(path)"]
            client.standardOutput = output
            client.standardError = FileHandle.nullDevice
            try client.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            client.waitUntilExit()
            guard client.terminationStatus == 0 else { throw Failure.offline }
            return data
        }.value
    }

    /// One connection to the event stream. It always ends by throwing.
    static func connect(filter: String?, address: String = MQTTBridge.address) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(512)) { output in
            let producer = Task.detached(priority: .utility) {
                do {
                    try await read(path: "/api/stream" + query([("filter", filter)]), address: address) { output.yield($0) }
                } catch {
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { _ in producer.cancel() }
        }
    }

    private static func read(path: String, address: String, yield: (Event) -> Void) async throws {
        let client = Process()
        let pipe = Pipe()
        client.executableURL = URL(filePath: "/usr/bin/curl")
        // The bridge sends its status every two seconds, so a stream silent for twenty is gone.
        client.arguments = ["--disable", "--silent", "--fail", "--no-buffer", "--noproxy", "*", "--connect-timeout", "2",
                            "--speed-limit", "1", "--speed-time", "20", "--header", "Accept: text/event-stream",
                            "http://\(address)\(path)"]
        client.standardOutput = pipe
        client.standardError = FileHandle.nullDevice
        try client.run()
        let transfer = Transfer(client)
        defer { transfer.end() }
        _ = try? pipe.fileHandleForWriting.close()
        try await withTaskCancellationHandler {
            var parser = AGUIEventStreamParser(lineLimit: 4 << 20, eventLimit: 4 << 20)
            var received = false
            for await chunk in pipe.fileHandleForReading.ownChunks {
                for byte in chunk {
                    guard case .event(let frame)? = try parser.consume(byte) else { continue }
                    try Task.checkCancellation()
                    if let event = MQTTSnapshot.event(Data(frame)) {
                        received = true
                        yield(event)
                    }
                }
            }
            try Task.checkCancellation()
            throw received ? Failure.disconnected : Failure.offline
        } onCancel: {
            transfer.end()
        }
    }

    private final class Transfer: @unchecked Sendable {
        private let process: Process

        init(_ process: Process) { self.process = process }

        func end() {
            if process.isRunning { process.terminate() }
        }
    }
}

// MARK: - Feature model

/// The daemon's routes, as the feed calls them.
struct MQTTBridgeAPI: Sendable {
    var status: @Sendable () async throws -> MQTTStatus
    var topics: @Sendable () async throws -> [MQTTTopic]
    var messages: @Sendable (_ filter: String?, _ limit: Int) async throws -> [MQTTMessage]
    var stream: @Sendable (_ filter: String?) -> AsyncThrowingStream<MQTTStream.Event, Error>

    static let live = MQTTBridgeAPI(
        status: { try MQTTSnapshot.status(try await MQTTStream.get("/api/status")) },
        topics: { try MQTTSnapshot.topics(try await MQTTStream.get("/api/topics")) },
        messages: { filter, limit in
            try MQTTSnapshot.messages(try await MQTTStream.get("/api/messages" + MQTTStream.query([("filter", filter), ("limit", String(limit))])))
        },
        stream: { MQTTStream.connect(filter: $0) })
}

/// What the bridge carries, kept by one subscription while its panel shows. The topic tree is
/// always the whole broker's; the message list follows the chosen node.
@Observable @MainActor
final class MQTTBridgeFeed {
    enum Link: Equatable {
        case connecting
        case live
        /// The daemon doesn't answer. What was read stays on screen.
        case offline
    }

    private(set) var link: Link = .connecting
    private(set) var status: MQTTStatus?
    private(set) var topics: [MQTTTopic] = []
    /// The live list, newest first, at most `MQTTBridge.messageLimit`.
    private(set) var messages: [MQTTMessage] = []
    /// The chosen node's path. Nil reads every topic.
    private(set) var selectedPath: String?
    private(set) var expanded = Set<String>()
    private(set) var isPaused = false
    /// Messages that arrived while the list was paused, newest first.
    private(set) var held: [MQTTMessage] = []
    /// The message in the inspector, by sequence number.
    private(set) var shownSeq: Int?

    @ObservationIgnored private let api: MQTTBridgeAPI?
    @ObservationIgnored private var lastCall = 0
    @ObservationIgnored private var pause: Task<Void, Never>?
    @ObservationIgnored private var topicsRecorded = -1
    @ObservationIgnored private var topicRead: Task<Void, Never>?

    init(api: MQTTBridgeAPI = .live) { self.api = api }

    /// Fixed contents for previews and fixtures. It never connects.
    init(fixture status: MQTTStatus?, topics: [MQTTTopic] = [], messages: [MQTTMessage] = [], link: Link = .live) {
        api = nil
        self.status = status
        self.topics = topics
        self.messages = messages.sorted { $0.seq > $1.seq }
        self.link = link
        expanded = Set(MQTTTopicTree.build(topics).map(\.path))
    }

    var filter: String? { selectedPath.map(MQTTTopicTree.filter) }
    var shown: MQTTMessage? { shownSeq.flatMap { seq in messages.first { $0.seq == seq } ?? held.first { $0.seq == seq } } }

    // MARK: Subscription

    /// Follows the bridge until the calling task is cancelled: the status, the topics and the
    /// recorded messages, then the stream. A lost stream is reopened after a pause. The newest
    /// call holds the subscription, so choosing a node starts over with its filter.
    func follow() async {
        guard let api else { return }
        lastCall += 1
        let call = lastCall
        var failed = 0
        while !Task.isCancelled, call == lastCall {
            let filter = filter
            do {
                async let status = api.status()
                async let topics = api.topics()
                async let recorded = api.messages(filter, MQTTBridge.backlog)
                let (first, tree, backlog) = try await (status, topics, recorded)
                guard call == lastCall else { return }
                self.status = first
                self.topics = tree
                topicsRecorded = first.messagesRecorded
                if expanded.isEmpty { expanded = Set(MQTTTopicTree.build(tree).map(\.path)) }
                merge(backlog, replacing: true)
                link = .live
                failed = 0
                for try await event in api.stream(filter) {
                    guard call == lastCall else { return }
                    link = .live
                    take(event)
                }
            } catch {
                // Any end is a lost connection. The next round reads everything again.
            }
            guard !Task.isCancelled, call == lastCall else { return }
            link = .offline
            failed += 1
            let wait = Task { _ = try? await Task.sleep(for: .seconds(min(2 * failed, 10))) }
            pause = wait
            await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
        }
    }

    /// Asks again now instead of waiting out the pause between attempts.
    func retry() {
        if link == .offline { link = .connecting }
        pause?.cancel()
    }

    /// One event of the stream.
    func take(_ event: MQTTStream.Event) {
        switch event {
        case .status(let next):
            status = next
            // The tree's counts come from the bridge: read them again when it recorded more.
            if next.messagesRecorded != topicsRecorded { readTopics(recorded: next.messagesRecorded) }
        case .message(let message):
            guard MQTTTopicTree.matches(message.topic, under: selectedPath) else { return }
            if isPaused {
                guard !held.contains(where: { $0.seq == message.seq }) else { return }
                held.insert(message, at: 0)
                if held.count > MQTTBridge.messageLimit { held.removeLast(held.count - MQTTBridge.messageLimit) }
            } else {
                merge([message])
            }
        }
    }

    private func readTopics(recorded: Int) {
        guard let api, topicRead == nil else { return }
        topicRead = Task {
            defer { topicRead = nil }
            guard let next = try? await api.topics() else { return }
            topics = next
            topicsRecorded = recorded
        }
    }

    /// Adds messages to the list: newest first, each sequence number once, cut at the limit.
    private func merge(_ more: [MQTTMessage], replacing: Bool = false) {
        var known = replacing ? [] : messages
        let seen = Set(known.map(\.seq))
        known.append(contentsOf: more.filter { !seen.contains($0.seq) })
        known.sort { $0.seq > $1.seq }
        if known.count > MQTTBridge.messageLimit { known.removeLast(known.count - MQTTBridge.messageLimit) }
        messages = known
        if replacing { held = [] }
    }

    // MARK: Intents

    /// Chooses a node of the tree, or every topic with nil. The list is read again for it.
    /// The caller restarts `follow()` when `filter` changes.
    func select(path: String?) {
        guard path != selectedPath else { return }
        selectedPath = path
        held = []
        // What is already on screen and still matches stays until the new list arrives.
        messages = messages.filter { MQTTTopicTree.matches($0.topic, under: path) }
        if let shownSeq, !messages.contains(where: { $0.seq == shownSeq }) { self.shownSeq = nil }
    }

    func toggle(path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused {
            let waiting = held
            held = []
            merge(waiting)
        }
    }

    func show(seq: Int?) { shownSeq = seq }
}

// MARK: - For the page

/// What the MQTT panel can ask for.
struct MQTTActions {
    var retry: @MainActor () -> Void = {}
    var select: @MainActor (_ path: String?) -> Void = { _ in }
    var toggle: @MainActor (_ path: String) -> Void = { _ in }
    var setPaused: @MainActor (Bool) -> Void = { _ in }
    var show: @MainActor (_ seq: Int?) -> Void = { _ in }
    var openWebUI: @MainActor () -> Void = {}
}

/// The feed's state as the panel shows it, and its intents.
struct MQTTContext {
    var link: MQTTBridgeFeed.Link = .live
    var status: MQTTStatus? = nil
    var tree: [MQTTTopicNode] = []
    var rows: [MQTTTopicRow] = []
    var messages: [MQTTMessage] = []
    var selectedPath: String? = nil
    var isPaused = false
    var heldCount = 0
    var shown: MQTTMessage? = nil
    var actions = MQTTActions()

    init() {}

    /// Reads the feed. Every property read here is observed by the view that calls it.
    @MainActor init(feed: MQTTBridgeFeed, openWebUI: @escaping @MainActor () -> Void = {}) {
        link = feed.link
        status = feed.status
        tree = MQTTTopicTree.build(feed.topics)
        rows = MQTTTopicTree.rows(tree, expanded: feed.expanded)
        messages = feed.messages
        selectedPath = feed.selectedPath
        isPaused = feed.isPaused
        heldCount = feed.held.count
        shown = feed.shown ?? feed.messages.first
        actions = MQTTActions(retry: { feed.retry() }, select: { feed.select(path: $0) }, toggle: { feed.toggle(path: $0) },
                              setPaused: { feed.setPaused($0) }, show: { feed.show(seq: $0) }, openWebUI: openWebUI)
    }

    /// Nothing was ever read and the daemon doesn't answer.
    var isOffline: Bool { link == .offline && status == nil }
    var isLoading: Bool { link == .connecting && status == nil }
    /// Messages on every topic, as the tree counts them.
    var total: Int { tree.reduce(0) { $0 + $1.total } }
    var filter: String? { selectedPath.map(MQTTTopicTree.filter) }
}

// MARK: - Fixtures

/// FIXTURE ONLY. A sample plant broker behind the design preview and the headless pictures.
enum MQTTFixture {
    static let now = PluginFixture.now

    static let status = MQTTStatus(version: "0.1.0", mqttAddress: "127.0.0.1:1885", uptimeSeconds: 9 * 3600 + 14 * 60,
                                   clientsConnected: 4, subscriptions: 9, messagesReceived: 18_422, messagesSent: 51_907,
                                   retained: 6, topics: 9, messagesRecorded: 18_422)

    static var messages: [MQTTMessage] {
        func json(_ seq: Int, _ ago: TimeInterval, _ topic: String, _ payload: String, client: String = "plc-line1", retain: Bool = false, qos: Int = 0) -> MQTTMessage {
            MQTTMessage(seq: seq, time: now.addingTimeInterval(-ago), topic: topic, payload: payload, size: payload.utf8.count,
                        qos: qos, retain: retain, client: client)
        }
        let frame = Data([0x02, 0x10, 0x00, 0x7f, 0xff, 0x3a, 0x41, 0x44, 0x41, 0x47, 0x00, 0x01, 0xc8, 0x42, 0x9a, 0x99,
                          0x19, 0x41, 0x00, 0x00, 0x80, 0x3f, 0x03])
        return [
            json(18_422, 1, "plant/line1/oven/temperature", #"{"value":218.4,"unit":"C","quality":"good","ts":"2026-11-27T19:59:59Z"}"#, qos: 1),
            json(18_421, 2, "plant/line1/conveyor/speed", #"{"value":1.82,"unit":"m/s","setpoint":1.8}"#),
            json(18_420, 3, "plant/line2/filler/state", "RUNNING", client: "plc-line2", retain: true, qos: 1),
            json(18_419, 4, "plant/line1/oven/temperature", #"{"value":218.1,"unit":"C","quality":"good","ts":"2026-11-27T19:59:56Z"}"#, qos: 1),
            MQTTMessage(seq: 18_418, time: now.addingTimeInterval(-5), topic: "plant/line2/scale/raw", payload: frame.base64EncodedString(),
                        encoding: .base64, size: frame.count, qos: 0, client: "scale-gw"),
            json(18_417, 6, "plant/line1/alarms/active", #"[{"id":"A-1042","text":"Oven zone 3 over temperature","severity":2,"since":"2026-11-27T19:41:10Z"}]"#, retain: true, qos: 1),
            json(18_416, 8, "plant/line1/conveyor/speed", #"{"value":1.79,"unit":"m/s","setpoint":1.8}"#),
            json(18_415, 9, "plant/energy/main/power", #"{"kw":412.6,"pf":0.97}"#, client: "epms-gw"),
            json(18_414, 11, "plant/line2/filler/count", "48213", client: "plc-line2"),
            json(18_413, 14, "plant/line1/oven/temperature", #"{"value":217.8,"unit":"C","quality":"good","ts":"2026-11-27T19:59:46Z"}"#, qos: 1),
            json(18_412, 15, "office/hvac/zone4/setpoint", "21.5", client: "bms-gw", retain: true),
            json(18_411, 19, "plant/energy/main/power", #"{"kw":409.9,"pf":0.97}"#, client: "epms-gw")
        ]
    }

    static var topics: [MQTTTopic] {
        let counts: [(String, Int)] = [
            ("plant/line1/oven/temperature", 6_120), ("plant/line1/conveyor/speed", 5_904), ("plant/line1/alarms/active", 37),
            ("plant/line2/filler/state", 212), ("plant/line2/filler/count", 3_088), ("plant/line2/scale/raw", 1_541),
            ("plant/energy/main/power", 1_506), ("office/hvac/zone4/setpoint", 9), ("office/hvac/zone4/temperature", 5)
        ]
        let latest = messages
        return counts.map { topic, count in
            let last = latest.first { $0.topic == topic }
            return MQTTTopic(topic: topic, count: count, last: last, lastSeen: last?.time)
        }
    }

    @MainActor static func feed() -> MQTTBridgeFeed {
        let feed = MQTTBridgeFeed(fixture: status, topics: topics, messages: messages)
        feed.toggle(path: "plant/line1")
        return feed
    }

    @MainActor static func offline() -> MQTTBridgeFeed { MQTTBridgeFeed(fixture: nil, link: .offline) }
}

/// What decides when the window follows the bridge: whether its panel shows, and the chosen topic.
struct MQTTFollow: Hashable {
    let isShown: Bool
    let filter: String?
}
