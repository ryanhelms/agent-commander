import Foundation
import Testing
@testable import AgentCommander

/// Capture the cold workspace event and each worker's Provider pages in a private file.
/// This exercises the same row, detail, field and media readers as the native consoles.
@Suite struct ProviderRecoveryTests {
    static var capture: String? { ProcessInfo.processInfo.environment["COMMANDER_PROVIDER_REPLAY"] }

    @Test(.enabled(if: ProviderRecoveryTests.capture != nil, "Set COMMANDER_PROVIDER_REPLAY to a Claude and Codex recovery capture."))
    func restoredRowsReachTheOriginalToolFieldsAndImageInBothModes() throws {
        let path = try #require(Self.capture)
        let capture = try AGUIValue(json: Data(contentsOf: URL(filePath: path)))
        var reducer = AGUIWorkspaceReducer()
        _ = try reducer.apply(event: #require(capture["event"]))
        let run = try #require(reducer.runs.first)
        // Captures with the original thread result come from the release that
        // links terminal turn records into the conversation as well.
        let codexRows = try #require(capture["sessions"]?["codex"]?["provider"]?["observations"]?.arrayValue)
        let includesThread = codexRows.contains { $0["extension"]?["type"]?.stringValue == "codex.history.thread" }
        for name in ["claude", "codex"] {
            let session = try #require(capture["sessions"]?[name])
            let worker = try #require(run.workers?.first { $0.id == session["worker"]?.stringValue })
            let page = try SourcePage(envelope: Data(try #require(session["provider"]).prettyText.utf8))
            let png = try #require(Data(base64Encoded: session["png"]?.stringValue ?? ""))
            let entries = TranscriptEntry.entries(from: try #require(worker.messages))
            var owners: Set<String> = []
            for record in page.observations {
                let envelope = try AGUIValue(json: record.record)
                guard envelope["sourceCursor"]?.stringValue == record.cursor else { continue }
                owners.insert(record.cursor)
            }
            for mode in [ConsoleDisplayMode.pretty, .console] {
                var sawToolFields = false, sawSwatch = false
                var inspected: Set<String> = []
                var openedPrompts: Set<String> = []
                for entry in TranscriptEntry.displayed(entries, mode: mode) {
                    if let reads = session["providerMediaReads"]?.objectValue,
                       case .prompt(let ref)? = PromptAttachmentOffer.resolve(workerID: worker.id, entryID: entry.id,
                            messages: worker.messages ?? [], hasSource: true, session: worker.nativeSession) {
                        let selected = try #require(reads[ref.firstCursor])
                        let response = try SourcePage(envelope: Data(selected.prettyText.utf8))
                        let parts = try ProviderPromptMedia.items(of: response, for: ref)
                        #expect(ref.origin == .provider && ref.itemCount == parts.count)
                        #expect(parts.contains { $0.body == .media(type: "image", mimeType: "image/png", data: png) })
                        openedPrompts.insert(ref.firstCursor)
                    }
                    guard let detail = ConsoleRecordDetail.resolve(entryID: entry.id, worker: worker, run: run),
                          let section = detail.sections.first(where: { $0.id == "sources" }),
                          let refs = try AGUIValue(json: section.json).arrayValue else { continue }
                    for ref in refs {
                        let cursor = try #require(ref["cursor"]?.stringValue)
                        #expect(ref["source"]?.stringValue == "provider")
                        let record = try #require(page.observations.first { $0.cursor == cursor })
                        #expect(record.session?.sessionID == worker.nativeSession?.sessionID)
                        let fields = RecordField.rows(json: record.record)
                        if owners.contains(cursor), inspected.insert(cursor).inserted {
                            let envelope = try AGUIValue(json: record.record)
                            let key = envelope["sourceRecord"] == nil ? "extension" : "sourceRecord"
                            let encoded = try #require(envelope[key]?["data"]?.stringValue)
                            let data = try #require(Data(base64Encoded: encoded))
                            Self.checkFields(try AGUIValue(json: data), path: key + ".data.decoded", rows: fields)
                        }
                        if case .tool(_, _, let result?) = entry.kind {
                            let receipt = name == "claude" ? "PLUM-4761" : "CEDAR-47291"
                            let key = name == "claude" ? "uuid" : "durationMs"
                            if result.output.contains(receipt), fields.contains(where: { $0.path == "sourceRecord.data.decoded." + key }) {
                                sawToolFields = true
                            }
                        }
                        if fields.contains(where: {
                            if case .attachment(let mime, let data?) = $0.value { return mime == "image/png" && data == png }
                            return false
                        }) { sawSwatch = true }
                    }
                }
                #expect(sawToolFields, "\(name) \(mode) could not reach the receipt's native fields")
                #expect(sawSwatch, "\(name) \(mode) could not reach the original swatch bytes")
                if includesThread {
                    #expect(inspected == owners, "\(name) \(mode) could not reach every provider original")
                }
                if let reads = session["providerMediaReads"]?.objectValue {
                    #expect(!reads.isEmpty && openedPrompts == Set(reads.keys),
                            "\(name) \(mode) did not expose the actual prompt attachment response")
                }
            }
        }
    }

    static var liveMethods: String? { ProcessInfo.processInfo.environment["COMMANDER_LIVE_METHOD_REPLAY"] }

    @Test(.enabled(if: ProviderRecoveryTests.liveMethods != nil, "Set COMMANDER_LIVE_METHOD_REPLAY to a private live method capture."))
    func consoleRowsReachEveryReturnedPromptResult() throws {
        let path = try #require(Self.liveMethods)
        let capture = try AGUIValue(json: Data(contentsOf: URL(filePath: path)))
        var reducer = AGUIWorkspaceReducer()
        _ = try reducer.apply(event: #require(capture["event"]))
        let run = try #require(reducer.runs.first)
        for name in ["claude", "codex"] {
            let session = try #require(capture["sessions"]?[name])
            let worker = try #require(run.workers?.first { $0.id == session["worker"]?.stringValue })
            let page = try SourcePage(envelope: Data(try #require(session["live"]).prettyText.utf8))
            let terminals = page.observations.filter { if case .turnEnded = $0.body { true } else { false } }
            try #require(!terminals.isEmpty)
            let entries = TranscriptEntry.entries(from: try #require(worker.messages))
            for mode in [ConsoleDisplayMode.pretty, .console] {
                var reached: Set<String> = []
                for entry in TranscriptEntry.displayed(entries, mode: mode) {
                    guard let detail = ConsoleRecordDetail.resolve(entryID: entry.id, worker: worker, run: run),
                          let refs = detail.sections.first(where: { $0.id == "sources" }),
                          let sources = try AGUIValue(json: refs.json).arrayValue else { continue }
                    for source in sources where source["kind"]?.stringValue == "acp.prompt_result" {
                        let cursor = try #require(source["cursor"]?.stringValue)
                        let record = try #require(terminals.first { $0.cursor == cursor })
                        #expect(source["turnId"]?.stringValue == record.turnID)
                        #expect(record.session?.sessionID == worker.nativeSession?.sessionID)
                        let fields = RecordField.rows(json: record.record)
                        #expect(RecordFieldTests.string("sourceRecord.data.decoded.stopReason", in: fields) == "end_turn")
                        let envelope = try AGUIValue(json: record.record)
                        let encoded = try #require(envelope["sourceRecord"]?["data"]?.stringValue)
                        let bytes = try #require(Data(base64Encoded: encoded))
                        let original = try AGUIValue(json: bytes)
                        #expect(original["usage"] != nil && original["_meta"] != nil)
                        Self.checkFields(original, path: "sourceRecord.data.decoded", rows: fields)
                        reached.insert(cursor)
                    }
                }
                #expect(reached == Set(terminals.map(\.cursor)), "\(name) \(mode) lost a linked ACP terminal record")
            }
        }
    }

    static var updateParams: String? { ProcessInfo.processInfo.environment["COMMANDER_UPDATE_PARAMS_REPLAY"] }

    @Test(.enabled(if: ProviderRecoveryTests.updateParams != nil, "Set COMMANDER_UPDATE_PARAMS_REPLAY to a scoped stdio capture."))
    func bothDisplaysReachActiveAndBetweenTurnACPParameters() throws {
        let path = try #require(Self.updateParams)
        let capture = try AGUIValue(json: Data(contentsOf: URL(filePath: path)))
        var reducer = AGUIWorkspaceReducer()
        _ = try reducer.apply(event: #require(capture["event"]))
        let run = try #require(reducer.runs.first)
        let worker = try #require(run.workers?.first { $0.id == capture["worker"]?.stringValue })
        let page = try SourcePage(envelope: Data(try #require(capture["live"]).prettyText.utf8))
        let expected = try #require(capture["expected"]?.arrayValue)
        var originals: [String: (record: SourceObservation, prefix: String, value: AGUIValue)] = [:]
        var ordered: [AGUIValue] = []
        for record in page.observations {
            let envelope = try AGUIValue(json: record.record)
            guard let key = ["sourceRecord", "extension"].first(where: { envelope[$0]?["type"]?.stringValue == "acp.session_update_params" }) else { continue }
            let data = try #require(envelope[key]?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) })
            let value = try AGUIValue(json: data)
            originals[record.cursor] = (record, key + ".data.decoded", value)
            ordered.append(value)
        }
        try #require(ordered == expected && originals.count == 6)
        let entries = TranscriptEntry.entries(from: try #require(worker.messages))
        for mode in [ConsoleDisplayMode.pretty, .console] {
            var reached: Set<String> = []
            for entry in TranscriptEntry.displayed(entries, mode: mode) {
                guard let detail = ConsoleRecordDetail.resolve(entryID: entry.id, worker: worker, run: run),
                      let refs = detail.sections.first(where: { $0.id == "sources" }),
                      let sources = try AGUIValue(json: refs.json).arrayValue else { continue }
                for source in sources {
                    guard let cursor = source["cursor"]?.stringValue, let original = originals[cursor] else { continue }
                    let rows = RecordField.rows(json: original.record.record)
                    Self.checkFields(original.value, path: original.prefix, rows: rows)
                    let label = original.value["_meta"]?["proof"]?.stringValue
                    #expect(RecordFieldTests.literal(original.prefix + "._meta.revision", in: rows) == "9007199254740993")
                    if label == "idle-missing" {
                        #expect(!rows.contains { $0.path == original.prefix + ".update" })
                    }
                    if label == "typed-result" {
                        let encoded = try #require(original.value["update"]?["content"]?.arrayValue?.last?["content"]?["data"]?.stringValue)
                        let png = try #require(Data(base64Encoded: encoded))
                        #expect(rows.contains { if case .attachment("image/png", let payload) = $0.value { return payload == png }; return false })
                    }
                    reached.insert(cursor)
                }
            }
            #expect(reached == Set(originals.keys), "Missing original ACP records in \(mode)")
        }
    }

    private static func checkFields(_ value: AGUIValue, path: String, rows: [RecordField]) {
        switch value {
        case .object(let members):
            #expect(RecordFieldTests.container(path, in: rows) != nil)
            for (key, member) in members {
                checkFields(member, path: path + "." + key, rows: rows)
            }
        case .array(let items):
            #expect(RecordFieldTests.container(path, in: rows) != nil)
            for (index, item) in items.enumerated() {
                checkFields(item, path: path + "[\(index)]", rows: rows)
            }
        case .string(let text):
            #expect(RecordFieldTests.string(path, in: rows) == text)
        case .number, .bool, .null:
            #expect(RecordFieldTests.literal(path, in: rows) == value.compactText)
        }
    }

    static var wireCapture: String? { ProcessInfo.processInfo.environment["COMMANDER_WIRE_REPLAY"] }

    @Test(.enabled(if: ProviderRecoveryTests.wireCapture != nil, "Set COMMANDER_WIRE_REPLAY to a --require-wire capture"))
    func bothDisplaysReachTheSelectedPeerEnvelopeAndOriginalPayload() throws {
        let path = try #require(Self.wireCapture)
        let capture = try AGUIValue(json: Data(contentsOf: URL(filePath: path)))
        var reducer = AGUIWorkspaceReducer()
        _ = try reducer.apply(event: #require(capture["event"]))
        let run = try #require(reducer.runs.first)
        for (key, count) in [("permission", 3), ("-32603", 1), ("-32800", 1), ("disconnect", 0)] {
            let scenario = try #require(capture["wire"]?[key])
            let worker = try #require(run.workers?.first { $0.id == scenario["worker"]?.stringValue })
            let page = try SourcePage(envelope: Data(scenario.prettyText.utf8))
            let expected = Set(try #require(scenario["cursors"]?.arrayValue).compactMap(\.stringValue))
            try #require(expected.count == count)
            let entries = TranscriptEntry.entries(from: try #require(worker.messages))
            for mode in [ConsoleDisplayMode.pretty, .console] {
                var opened: Set<String> = []
                for entry in TranscriptEntry.displayed(entries, mode: mode) {
                    guard let detail = ConsoleRecordDetail.resolve(entryID: entry.id, worker: worker, run: run),
                          let section = detail.sections.first(where: { $0.id == "sources" }),
                          let links = try AGUIValue(json: section.json).arrayValue else { continue }
                    for link in links {
                        guard let cursor = link["cursor"]?.stringValue, expected.contains(cursor) else { continue }
                        let source = try #require(page.observations.first { $0.cursor == cursor })
                        #expect(source.session?.sessionID == worker.nativeSession?.sessionID)
                        let original = try AGUIValue(json: source.record)
                        let wire = try #require(original["wireProvenance"])
                        let fields = RecordField.rows(json: source.record)
                        Self.checkFields(wire, path: "wireProvenance", rows: fields)
                        let extras = try #require(RecordFieldTests.string("wireProvenance.additionalFieldsJson", in: fields))
                        #expect(extras.contains("9007199254740993"))
                        if wire["method"]?.stringValue == "session/request_permission" {
                            #expect(RecordFieldTests.string("wireProvenance.idJson", in: fields) == "9007199254740993")
                        }
                        if let member = ["sourceRecord", "extension"].first(where: { original[$0]?["data"]?.stringValue != nil }) {
                            let bytes = try #require(original[member]?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) })
                            Self.checkFields(try AGUIValue(json: bytes), path: member + ".data.decoded", rows: fields)
                        }
                        opened.insert(cursor)
                    }
                }
                #expect(opened == expected, "Missing selected wire source for \(key) in \(mode)")
            }
        }
    }
}
