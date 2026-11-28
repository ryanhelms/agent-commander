import Foundation
import Testing
@testable import AgentCommander

// The MQTT Bridge panel: reading the daemon's JSON, building the topic tree, the payload forms,
// and the feed's list, filter and pause.

@MainActor @Suite struct MQTTBridgeTests {
    static let statusJSON = #"{"version":"0.1.0","mqtt_address":"127.0.0.1:1885","uptime_seconds":2867,"clients_connected":2,"subscriptions":3,"messages_received":40,"messages_sent":90,"retained":1,"topics":4,"messages_recorded":40}"#
    static let messageJSON = #"{"seq":41,"time":"2026-11-27T20:00:00.123456789Z","topic":"plant/line1/temp","payload":"{\"v\":21.5}","encoding":"utf8","size":10,"qos":1,"retain":true,"client":"plc-1"}"#

    @Test func readsTheStatus() throws {
        let status = try MQTTSnapshot.status(Data(Self.statusJSON.utf8))
        #expect(status.version == "0.1.0" && status.mqttAddress == "127.0.0.1:1885" && status.uptimeSeconds == 2867)
        #expect(status.clientsConnected == 2 && status.subscriptions == 3 && status.messagesReceived == 40 && status.messagesSent == 90)
        #expect(status.retained == 1 && status.topics == 4 && status.messagesRecorded == 40 && status.topicsDropped == 0)
        #expect(status.uptime == "47 min")
        #expect(MQTTStatus(uptimeSeconds: 12).uptime == "12 s" && MQTTStatus(uptimeSeconds: 2 * 3600 + 300).uptime == "2 h 5 min")
        #expect(MQTTStatus(uptimeSeconds: 2 * 86_400 + 4 * 3600).uptime == "2 d 4 h")
        let dropped = try MQTTSnapshot.status(Data(#"{"topics_dropped":7,"uptime_seconds":1.9}"#.utf8))
        #expect(dropped.topicsDropped == 7 && dropped.uptimeSeconds == 1)
    }

    @Test func readsSourcesAndTheViewer() throws {
        let json = ##"{"version":"0.2.0","sources":[{"id":"b1","name":"Home","url":"mqtt://127.0.0.1:1883","topics":"#","prefix":"home","added_by":"nick (nick)","added_at":"2026-11-28T04:18:26Z","status":{"broker":"127.0.0.1:1883","connected":true,"messages":176}},{"id":"c2","name":"Lab","prefix":"lab","status":{"connected":false,"last_error":"connection refused"}},{"name":"no id"}],"viewer":{"login":"ryan","device":"ryan-mbp","can_edit":true}}"##
        let status = try MQTTSnapshot.status(Data(json.utf8))
        #expect(status.sources.map(\.id) == ["b1", "c2"])
        let home = try #require(status.sources.first)
        #expect(home.name == "Home" && home.url == "mqtt://127.0.0.1:1883" && home.prefix == "home" && home.addedBy == "nick (nick)")
        #expect(home.connected && home.messages == 176 && home.lastError.isEmpty && home.filter == "home/#")
        #expect(home.addedAt?.timeIntervalSince1970 == 1_795_839_506)
        #expect(!status.sources[1].connected && status.sources[1].lastError == "connection refused" && status.sources[1].topics == "#")
        #expect(status.viewer == MQTTViewer(login: "ryan", device: "ryan-mbp", canEdit: true))
        // A bridge older than sources says nothing about either.
        let old = try MQTTSnapshot.status(Data(Self.statusJSON.utf8))
        #expect(old.sources.isEmpty && old.viewer == nil)
    }

    @Test func theBridgeAddressFollowsTheRulesOfThePlugin() {
        #expect(MQTTBridge.address(bridgeURL: "http://100.64.0.6:18830") == "100.64.0.6:18830")
        #expect(MQTTBridge.address(bridgeURL: " http://100.127.255.1:80/ ") == "100.127.255.1:80")
        #expect(MQTTBridge.address(bridgeURL: "http://127.0.0.1:18830") == "127.0.0.1:18830")
        #expect(MQTTBridge.address(bridgeURL: "http://localhost:18830") == "localhost:18830")
        for refused in ["https://100.64.0.6:18830", "http://192.168.50.99:18830", "http://100.128.0.1:18830",
                        "http://100.63.255.255:18830", "http://100.64.0.6", "http://u:p@100.64.0.6:18830",
                        "http://100.64.0.6:18830/api", "http://100.64.0.6:18830?x=1", "http://nick-bms.tail.internal:18830",
                        "http://8.8.8.8:80", "100.64.0.6:18830", "", "http://100.64.0:18830", "http://100.64.0.256:1"] {
            #expect(MQTTBridge.address(bridgeURL: refused) == nil, "\(refused)")
        }
    }

    @Test func theBridgeIsTheOneTheGrantsName() {
        func plugin(_ grants: [PluginGrant], id: String = MQTTBridge.pluginID) -> Plugin {
            Plugin(id: id, name: "MQTT", tools: [PluginTool(id: "\(id).list_topics", grants: grants)])
        }
        func url(_ raw: String) -> AGUIValue { .object([MQTTBridge.urlSetting: .string(raw)]) }
        #expect(MQTTBridge.address(in: []) == MQTTBridge.defaultAddress)
        #expect(MQTTBridge.address(in: [plugin([PluginGrant(project: "/a")])]) == MQTTBridge.defaultAddress)
        // Another plugin's setting is not this one's.
        #expect(MQTTBridge.address(in: [plugin([PluginGrant(project: "/a", settings: url("http://100.64.0.9:1"))], id: "x.other")])
                == MQTTBridge.defaultAddress)
        // A grant the service loaded wins over one written since; an invalid URL is passed over.
        let grants = [PluginGrant(project: "/a", settings: url("http://100.64.0.7:18830"), active: false),
                      PluginGrant(project: "/c", settings: url("http://192.168.50.99:18830")),
                      PluginGrant(project: "/d", settings: url("http://100.64.0.6:18830"))]
        #expect(MQTTBridge.address(in: [plugin(grants)]) == "100.64.0.6:18830")
        #expect(MQTTBridge.address(in: [plugin(Array(grants.prefix(2)))]) == "100.64.0.7:18830")
        #expect(MQTTBridge.isLocal("127.0.0.1:18830") && MQTTBridge.isLocal("localhost:1") && !MQTTBridge.isLocal("100.64.0.6:18830"))
    }

    @Test func anotherBridgeStartsClean() async {
        let asked = Asked()
        let feed = MQTTBridgeFeed(makeAPI: { address in
            MQTTBridgeAPI(status: { await asked.add(address); return MQTTStatus(version: address) }, topics: { [] },
                          messages: { _, _ in [] }, stream: { _ in AsyncThrowingStream { $0.finish(throwing: MQTTStream.Failure.disconnected) } })
        })
        #expect(feed.address == MQTTBridge.defaultAddress)
        let first = Task { await feed.follow() }
        for _ in 0..<50 where feed.status == nil { try? await Task.sleep(for: .milliseconds(10)) }
        first.cancel()
        await first.value
        #expect(feed.status?.version == MQTTBridge.defaultAddress)
        feed.select(path: "home")
        feed.use(address: "100.64.0.6:18830")
        #expect(feed.status == nil && feed.selectedPath == nil && feed.link == .connecting && feed.address == "100.64.0.6:18830")
        let second = Task { await feed.follow() }
        for _ in 0..<50 where feed.status == nil { try? await Task.sleep(for: .milliseconds(10)) }
        second.cancel()
        await second.value
        #expect(feed.status?.version == "100.64.0.6:18830" && MQTTContext(feed: feed).whereabouts == "at 100.64.0.6:18830")
        #expect(await asked.addresses.contains("100.64.0.6:18830"))
    }

    actor Asked {
        var addresses: [String] = []
        func add(_ address: String) { addresses.append(address) }
    }

    @Test func readsMessagesAndTopics() throws {
        let message = try MQTTSnapshot.message(Data(Self.messageJSON.utf8))
        #expect(message.seq == 41 && message.topic == "plant/line1/temp" && message.payload == #"{"v":21.5}"# && message.encoding == .utf8)
        #expect(message.size == 10 && message.qos == 1 && message.retain && message.client == "plc-1" && !message.truncated)
        // Go writes nanoseconds: the fraction is kept to the millisecond the list shows.
        let time = try #require(message.time)
        #expect(abs(time.timeIntervalSince1970 - 1_795_809_600.123456789) < 0.0005)
        #expect(MQTTSnapshot.date("2026-11-27T20:00:00Z")?.timeIntervalSince1970 == 1_795_809_600)
        #expect(MQTTSnapshot.date("2026-11-27T21:00:00.5+01:00")?.timeIntervalSince1970 == 1_795_809_600.5)
        #expect(MQTTSnapshot.date("") == nil && MQTTSnapshot.date("soon") == nil)

        let binary = try MQTTSnapshot.message(Data(#"{"seq":2,"topic":"t","payload":"AAEC","encoding":"base64","size":3,"truncated":true}"#.utf8))
        #expect(binary.encoding == .base64 && binary.truncated && binary.preview == "binary, 3 B" && binary.time == nil)
        #expect(throws: (any Error).self) { try MQTTSnapshot.message(Data(#"{"topic":"t"}"#.utf8)) }

        let list = try MQTTSnapshot.messages(Data("{\"messages\":[\(Self.messageJSON),{\"seq\":40,\"topic\":\"a\"},{\"payload\":\"lost\"}]}".utf8))
        #expect(list.map(\.seq) == [41, 40])
        #expect(try MQTTSnapshot.messages(Data(#"{"messages":null}"#.utf8)).isEmpty)

        let topics = try MQTTSnapshot.topics(Data("{\"topics\":[{\"topic\":\"plant/line1/temp\",\"count\":12,\"last\":\(Self.messageJSON),\"last_seen\":\"2026-11-27T20:00:00Z\"},{\"count\":1}]}".utf8))
        #expect(topics.count == 1 && topics[0].count == 12 && topics[0].last?.seq == 41 && topics[0].lastSeen != nil)
    }

    @Test func aStreamEventIsToldApartByItsMembers() {
        #expect(MQTTSnapshot.event(Data(Self.statusJSON.utf8)) == .status(try! MQTTSnapshot.status(Data(Self.statusJSON.utf8))))
        guard case .message(let message)? = MQTTSnapshot.event(Data(Self.messageJSON.utf8)) else {
            Issue.record("a message frame was not read as a message")
            return
        }
        #expect(message.seq == 41)
        #expect(MQTTSnapshot.event(Data(#"{"hello":1}"#.utf8)) == nil && MQTTSnapshot.event(Data("nope".utf8)) == nil)

        // The stream's frames go through the shared event-stream parser; the event name is not needed.
        var parser = AGUIEventStreamParser()
        var events: [MQTTStream.Event] = []
        for byte in Array("event: status\ndata: \(Self.statusJSON)\n\nevent: message\ndata: \(Self.messageJSON)\n\n".utf8) {
            if case .event(let frame)? = try? parser.consume(byte), let event = MQTTSnapshot.event(Data(frame)) { events.append(event) }
        }
        #expect(events.count == 2 && events.last == .message(message))
    }

    @Test func aFilterIsEscapedForTheQuery() {
        #expect(MQTTStream.query([("filter", "plant/line 1/+/#"), ("limit", "100")]) == "?filter=plant%2Fline%201%2F%2B%2F%23&limit=100")
        #expect(MQTTStream.query([("filter", nil)]) == "" && MQTTStream.query([("filter", nil), ("limit", "5")]) == "?limit=5")
    }

    @Test func theTopicTreeSplitsOnSlashesAndSumsCounts() {
        let tree = MQTTTopicTree.build([
            MQTTTopic(topic: "plant/line1/temp", count: 5), MQTTTopic(topic: "plant/line1", count: 2),
            MQTTTopic(topic: "plant/line2/state", count: 3), MQTTTopic(topic: "office", count: 1),
            MQTTTopic(topic: "plant/line10/x", count: 1), MQTTTopic(topic: "", count: 9)
        ])
        #expect(tree.map(\.name) == ["office", "plant"] && tree.map(\.total) == [1, 11])
        let plant = tree[1]
        #expect(!plant.isTopic && plant.count == 0 && plant.path == "plant" && plant.filter == "plant/#")
        // Names sort as a person reads them: line2 before line10.
        #expect(plant.children.map(\.name) == ["line1", "line2", "line10"])
        let line1 = plant.children[0]
        // A topic that is also a prefix keeps its own count beside its children's.
        #expect(line1.isTopic && line1.count == 2 && line1.total == 7 && line1.path == "plant/line1")
        #expect(line1.children.map(\.path) == ["plant/line1/temp"] && line1.children[0].isTopic && line1.children[0].children.isEmpty)
        #expect(tree[0].isTopic && tree[0].children.isEmpty)

        // An empty level is a level in MQTT: a leading slash and a doubled one are kept.
        let odd = MQTTTopicTree.build([MQTTTopic(topic: "/a", count: 1), MQTTTopic(topic: "a//b", count: 2)])
        #expect(odd.map(\.name) == ["", "a"] && odd[0].children.map(\.path) == ["/a"])
        #expect(odd[1].children.map(\.name) == [""] && odd[1].children[0].children.map(\.path) == ["a//b"] && odd[1].total == 2)
        #expect(MQTTTopicTree.build([]).isEmpty)
    }

    @Test func theRowsFollowWhatIsOpen() {
        let tree = MQTTTopicTree.build(MQTTFixture.topics)
        #expect(MQTTTopicTree.rows(tree, expanded: []).map(\.node.path) == ["office", "plant"])
        let open = MQTTTopicTree.rows(tree, expanded: ["plant", "plant/line1"])
        #expect(open.map(\.node.path) == ["office", "plant", "plant/energy", "plant/line1", "plant/line1/alarms", "plant/line1/conveyor",
                                          "plant/line1/oven", "plant/line2"])
        #expect(open.map(\.depth) == [0, 0, 1, 1, 2, 2, 2, 1])
        #expect(open.map(\.isExpanded) == [false, true, false, true, false, false, false, false] && open[0].hasChildren)
        #expect(MQTTTopicTree.matches("plant/line1/temp", under: "plant/line1") && MQTTTopicTree.matches("plant/line1", under: "plant/line1"))
        #expect(!MQTTTopicTree.matches("plant/line10/x", under: "plant/line1") && MQTTTopicTree.matches("anything", under: nil))
        #expect(MQTTTopicTree.ancestors(of: "plant/line1/temp") == ["plant", "plant/line1"] && MQTTTopicTree.ancestors(of: "plant").isEmpty)
    }

    @Test func aPayloadOffersTheFormsThatFit() {
        let json = MQTTPayload(MQTTMessage(seq: 1, topic: "t", payload: #"{"b":1,"a":[true]}"#, size: 18))
        #expect(json.forms == [.json, .text, .hex])
        #expect(json.text(.json) == "{\n  \"a\": [\n    true\n  ],\n  \"b\": 1\n}" && json.text(.text) == #"{"b":1,"a":[true]}"#)
        // A bare number or word is text, not a document to indent.
        #expect(MQTTPayload(MQTTMessage(seq: 2, topic: "t", payload: "21.5", size: 4)).forms == [.text, .hex])
        #expect(MQTTPayload(MQTTMessage(seq: 3, topic: "t", payload: "RUNNING", size: 7)).forms == [.text, .hex])
        let binary = MQTTPayload(MQTTMessage(seq: 4, topic: "t", payload: Data([0x00, 0x41, 0xff]).base64EncodedString(), encoding: .base64, size: 3))
        #expect(binary.forms == [.hex, .base64] && binary.text(.base64) == "AEH/")
        #expect(binary.text(.hex) == "0000  00 41 ff" + String(repeating: " ", count: 39) + "  .A.")
        let dump = MQTTPayload.hexDump(Data((0..<40).map { UInt8($0) }), limit: 32)
        #expect(dump.split(separator: "\n").count == 3 && dump.hasSuffix("… 8 more bytes") && dump.contains("0010  10 11"))
        #expect(MQTTPayload.hexDump(Data()).isEmpty)
        #expect(MQTTPayload.byteCount(512) == "512 B" && MQTTPayload.byteCount(4096).contains("KB"))
        #expect(MQTTMessage(seq: 5, topic: "t", payload: " a\n  b \n", size: 8).preview == "a b" && MQTTMessage(seq: 6, topic: "t").preview == "empty")
    }

    // MARK: Feed

    private nonisolated static func message(_ seq: Int, _ topic: String) -> MQTTMessage { MQTTMessage(seq: seq, topic: topic, payload: "\(seq)", size: 1) }

    @Test func theListIsNewestFirstCappedAndFollowsTheChosenTopic() {
        let feed = MQTTBridgeFeed(fixture: MQTTFixture.status, topics: MQTTFixture.topics,
                                  messages: [Self.message(2, "plant/a"), Self.message(1, "office/b")])
        feed.take(.message(Self.message(3, "plant/c")))
        feed.take(.message(Self.message(3, "plant/c")))
        #expect(feed.messages.map(\.seq) == [3, 2, 1])
        for seq in 4...(MQTTBridge.messageLimit + 10) { feed.take(.message(Self.message(seq, "plant/a"))) }
        #expect(feed.messages.count == MQTTBridge.messageLimit && feed.messages.first?.seq == MQTTBridge.messageLimit + 10)

        feed.show(seq: MQTTBridge.messageLimit + 10)
        feed.select(path: "office")
        // What no longer matches leaves at once, with the message that was shown.
        #expect(feed.filter == "office/#" && feed.messages.isEmpty && feed.shown == nil)
        feed.take(.message(Self.message(900, "plant/a")))
        feed.take(.message(Self.message(901, "office/hvac/zone4")))
        #expect(feed.messages.map(\.seq) == [901])
        feed.select(path: nil)
        #expect(feed.filter == nil)

        feed.take(.status(MQTTStatus(version: "0.2.0", messagesRecorded: 5)))
        #expect(feed.status?.version == "0.2.0")
    }

    @Test func pauseHoldsNewMessagesUntilResume() {
        let feed = MQTTBridgeFeed(fixture: MQTTFixture.status, messages: [Self.message(1, "a")])
        feed.setPaused(true)
        feed.take(.message(Self.message(2, "a")))
        feed.take(.message(Self.message(3, "a")))
        feed.take(.message(Self.message(3, "a")))
        #expect(feed.isPaused && feed.messages.map(\.seq) == [1] && feed.held.map(\.seq) == [3, 2])
        let context = MQTTContext(feed: feed)
        #expect(context.isPaused && context.heldCount == 2 && context.shown?.seq == 1)
        feed.setPaused(false)
        #expect(!feed.isPaused && feed.held.isEmpty && feed.messages.map(\.seq) == [3, 2, 1])
    }

    private final class Reads: @unchecked Sendable {
        var filters: [String?] = []
        var online = false
    }

    @Test func theFeedReadsTheBacklogThenTheStreamAndSaysWhenTheBridgeIsDown() async {
        let reads = Reads()
        let api = MQTTBridgeAPI(
            status: {
                guard reads.online else { throw MQTTStream.Failure.offline }
                return MQTTFixture.status
            },
            topics: { MQTTFixture.topics },
            messages: { filter, _ in
                reads.filters.append(filter)
                return [MQTTBridgeTests.message(10, "plant/a"), MQTTBridgeTests.message(11, "plant/b")]
            },
            stream: { _ in
                AsyncThrowingStream { output in
                    output.yield(.message(MQTTBridgeTests.message(12, "plant/c")))
                    output.yield(.message(MQTTBridgeTests.message(11, "plant/b")))
                    output.finish(throwing: MQTTStream.Failure.disconnected)
                }
            })
        let feed = MQTTBridgeFeed(api: api)
        #expect(MQTTContext(feed: feed).isLoading)
        let down = Task { await feed.follow() }
        for _ in 0..<200 where feed.link != .offline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(feed.link == .offline && feed.status == nil && MQTTContext(feed: feed).isOffline)
        down.cancel()
        await down.value

        reads.online = true
        feed.select(path: "plant")
        let up = Task { await feed.follow() }
        for _ in 0..<200 where feed.messages.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        // The backlog, then the stream's new message; the one both carry is listed once.
        #expect(feed.messages.map(\.seq) == [12, 11, 10] && feed.status == MQTTFixture.status && reads.filters.last == "plant/#")
        #expect(feed.topics.count == MQTTFixture.topics.count && feed.expanded == ["office", "plant"])
        up.cancel()
        await up.value
        let context = MQTTContext(feed: feed)
        #expect(context.selectedPath == "plant" && context.total == 18_422 && context.rows.contains { $0.node.path == "plant/line1" })
    }

    /// Against a running bridge: `MQTT_BRIDGE_LIVE=1 swift test --filter MQTTBridge`, with
    /// `MQTT_BRIDGE_URL=http://100.64.0.6:18830` for the shared one (a bridge on this Mac otherwise).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MQTT_BRIDGE_LIVE"] != nil)) func followsTheRunningBridge() async throws {
        let feed = MQTTBridgeFeed()
        if let raw = ProcessInfo.processInfo.environment["MQTT_BRIDGE_URL"] { feed.use(address: try #require(MQTTBridge.address(bridgeURL: raw))) }
        let follow = Task { await feed.follow() }
        // The first status of the stream arrives within two seconds of the connection.
        var streamed = false
        for _ in 0..<60 where !streamed {
            try await Task.sleep(for: .milliseconds(100))
            streamed = feed.link == .live && (feed.status?.uptimeSeconds ?? 0) > 0
        }
        let first = try #require(feed.status)
        #expect(feed.link == .live && !first.version.isEmpty && !first.mqttAddress.isEmpty)
        try await Task.sleep(for: .seconds(3))
        #expect((feed.status?.uptimeSeconds ?? 0) > first.uptimeSeconds, "the stream's status events move the uptime on")
        follow.cancel()
        await follow.value
        // Nothing answers on a closed port: the feed says offline and keeps what it has.
        let closed = MQTTBridgeFeed(api: MQTTBridgeAPI(
            status: { try MQTTSnapshot.status(try await MQTTStream.get("/api/status", address: "127.0.0.1:9")) },
            topics: { [] }, messages: { _, _ in [] }, stream: { MQTTStream.connect(filter: $0, address: "127.0.0.1:9") }))
        let down = Task { await closed.follow() }
        for _ in 0..<60 where closed.link != .offline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(closed.link == .offline && closed.status == nil)
        down.cancel()
        await down.value
    }

    @Test func theFixtureFillsThePanel() {
        let context = MQTTContext(feed: MQTTFixture.feed())
        #expect(context.link == .live && context.messages.count == 12 && context.messages.first?.seq == 18_422)
        #expect(context.tree.map(\.name) == ["office", "plant"] && context.rows.contains { $0.node.path == "plant/line1/oven" })
        let cells = MQTTPanelPage.readouts(MQTTFixture.status, link: .live)
        #expect(cells.map(\.label) == ["broker", "uptime", "clients", "subscriptions", "received", "sent", "retained", "topics"])
        #expect(cells[0].value == "Running" && cells[0].lamp == .on && cells[1].value == "9 h 14 min" && cells[4].value == 18_422.formatted())
        var dropped = MQTTFixture.status
        dropped.topicsDropped = 3
        #expect(MQTTPanelPage.readouts(dropped, link: .offline).last?.label == "topics dropped")
        #expect(MQTTPanelPage.readouts(dropped, link: .offline)[0].lamp == .error && MQTTPanelPage.readouts(dropped, link: .offline)[0].value == "Offline")
        let offline = MQTTContext(feed: MQTTFixture.offline())
        #expect(offline.isOffline && !offline.isLoading && offline.status == nil)
    }
}
