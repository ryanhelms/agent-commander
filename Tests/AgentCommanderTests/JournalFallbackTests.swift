import Foundation
import Testing
@testable import AgentCommander

/// An isolated service and four read-only provider files are supplied by verify-journal.py.
@MainActor
@Suite struct JournalFallbackTests {
    private struct Sample: Decodable {
        let worker: String
        let client: String
        let session: String
        let originals: [Data]
        let png: Data
        let gap: String
    }

    private nonisolated static var manifest: String? {
        ProcessInfo.processInfo.environment["COMMANDER_JOURNAL_FIXTURE"]
    }

    @Test(.enabled(if: Self.manifest != nil, "Run verify-journal.py with a released agentctl."))
    func inspectScopedJournalInBothDisplays() async throws {
        let path = try #require(Self.manifest)
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(filePath: path)))
        try #require(samples.count == 4 && Set(samples.map(\.session)).count == 4)
        let service = ServiceClient()
        let modes = ConsoleModeStore()
        var receipts: [String] = []
        for mode in [ConsoleDisplayMode.pretty, .console] {
            for sample in samples {
                modes.setMode(mode, for: sample.worker)
                let display = modes.mode(for: sample.worker)
                try #require(display == mode)
                try await Self.checkTranscript(service, sample, mode: display)
                let model = ConsoleSourceModel { worker, source, cursor in
                    // The title bar opens Provider first. The same UI interaction immediately
                    // selects Journal; no vendor API or CLI is needed in this offline proof.
                    try Task.checkCancellation()
                    guard source == .journal else { throw CancellationError() }
                    return try await service.workerHistory(worker, source: source, cursor: cursor, limit: 1)
                }
                model.inspect(sample.worker)
                try #require(model.inspection?.workerID == sample.worker)
                model.select(.journal)
                var reached: Set<String> = []
                while true {
                    let page = try await Self.loaded(model)
                    try #require(page.workerID == sample.worker && page.source == .journal)
                    guard let cursor = page.nextCursor else { break }
                    try #require(reached.insert(cursor).inserted && reached.count <= sample.originals.count)
                    if reached.count == 1 {
                        let other = try #require(samples.first { $0.client == sample.client && $0.worker != sample.worker })
                        do {
                            _ = try await service.workerHistory(other.worker, source: .journal, cursor: cursor, limit: 1)
                            Issue.record("Journal cursor crossed the \(sample.client) session boundary")
                        } catch ServiceError.rejected(let reason) {
                            #expect(reason.contains("native history page is unavailable"))
                        }
                    }
                    model.loadMore()
                }
                let records = try #require(model.inspection?.observations)
                try #require(records.count == sample.originals.count + 1)
                #expect(Set(records.map(\.cursor)).count == records.count)
                let bound = NativeSession(harnessInstance: "local-" + sample.client, sessionID: sample.session)
                #expect(records.allSatisfy { $0.session == bound && !$0.cursor.isEmpty })
                var images: [Data] = []
                for (record, raw) in zip(records, sample.originals) {
                    guard case .attachment(let type, let media, let original) = record.body else {
                        Issue.record("Expected a retained vendor journal record"); continue
                    }
                    #expect(type.hasPrefix(sample.client + ".journal.") && media == "application/json")
                    #expect(original == raw)
                    let rows = RecordField.rows(json: record.record)
                    try Self.check(AGUIValue(json: raw), at: "extension.data.decoded", in: rows)
                    for row in RecordFieldTests.attachments(in: rows) {
                        if case .attachment("image/png", let data) = row.value {
                            let bytes = try #require(data)
                            let thumbnail = try #require(SourceAttachment.thumbnail(of: bytes))
                            #expect(thumbnail.size.width == 2 && thumbnail.size.height == 2)
                            images.append(bytes)
                        }
                    }
                }
                #expect(images == [sample.png])
                let gap = try #require(records.last)
                #expect(gap.body == .gap(reason: sample.gap))
                #expect(RecordFieldTests.string("gap.reason", in: RecordField.rows(json: gap.record)) == sample.gap)
                #expect(!gap.record.contains("UNRECOGNIZED_"))
                try await Self.checkTranscript(service, sample, mode: display)
                receipts.append(sample.worker + "/" + mode.rawValue)
                model.inspect(nil)
            }
        }
        let output = try #require(ProcessInfo.processInfo.environment["COMMANDER_JOURNAL_RECEIPT"])
        try JSONEncoder().encode(receipts.sorted()).write(to: URL(filePath: output), options: .withoutOverwriting)
    }

    private static func checkTranscript(_ service: ServiceClient, _ sample: Sample, mode: ConsoleDisplayMode) async throws {
        var snapshots = await service.watchRuns().makeAsyncIterator()
        let snapshot = try #require(try await snapshots.next())
        let workers = try #require(snapshot.first?.workers)
        let worker = try #require(workers.first { $0.id == sample.worker })
        let messages = try #require(worker.messages)
        let entries = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: mode)
        let displayed = entries.compactMap { entry -> String? in
            if case .prose(let text, _) = entry.kind { return text }
            return nil
        }
        #expect(displayed == ["VISIBLE-ACP-" + sample.worker])
        #expect(messages.contains { $0.metadata?["acp"]?["cursor"]?.stringValue == "src-" + sample.worker })
    }

    private static func loaded(_ model: ConsoleSourceModel) async throws -> SourceInspection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            if let state = model.inspection {
                if case .failed(let reason) = state.phase { throw ServiceError.rejected(reason) }
                if let reason = state.pageError { throw ServiceError.rejected(reason) }
                if state.phase == .loaded && !state.isLoadingMore { return state }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ServiceError.rejected("Timed out waiting for the native journal inspector")
    }

    private static func check(_ original: AGUIValue, at path: String, in rows: [RecordField]) throws {
        switch original {
        case .object(let fields):
            for (key, item) in fields { try check(item, at: path + "." + key, in: rows) }
        case .array(let items):
            for (index, item) in items.enumerated() { try check(item, at: path + "[\(index)]", in: rows) }
        case .string(let string):
            #expect(RecordFieldTests.string(path, in: rows) == string)
        case .bool, .number, .null:
            #expect(RecordFieldTests.literal(path, in: rows) == original.compactText)
        }
    }

}
