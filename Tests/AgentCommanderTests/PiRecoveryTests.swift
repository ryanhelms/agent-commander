import AppKit
import Foundation
import Testing
@testable import AgentCommander

/// Uses the restarted service snapshot and provider pages recorded by the Pi integration probe.
@Suite struct PiRecoveryTests {
    static var capture: String? { ProcessInfo.processInfo.environment["COMMANDER_PI_REPLAY"] }

    @Test(.enabled(if: PiRecoveryTests.capture != nil, "Set COMMANDER_PI_REPLAY to a Pi recovery capture."))
    func bothDisplaysReachTheFailedReadAndPNGByTheirOriginalToolIDs() throws {
        let path = try #require(Self.capture)
        let data = try Data(contentsOf: URL(filePath: path))
        let capture = try AGUIValue(json: data)
        let event = try #require(capture["event"])
        let provider = try #require(capture["provider"])
        let bytes = try #require(Data(base64Encoded: capture["png"]?.stringValue ?? ""))
        var reducer = AGUIWorkspaceReducer()
        _ = try reducer.apply(event: event)
        let run = try #require(reducer.runs.first)
        let worker = try #require(run.workers?.first)
        let messages = try #require(worker.messages)
        let entries = TranscriptEntry.entries(from: messages)
        let page = try SourcePage(envelope: Data(provider.prettyText.utf8))

        for mode in [ConsoleDisplayMode.pretty, .console] {
            let shown = TranscriptEntry.displayed(entries, mode: mode)
            for nativeID in ["call_missing_read", "call_swatch_read"] {
                let id = worker.id + ":" + nativeID
                let entry = try #require(shown.first { $0.id == id })
                guard case .tool(_, _, let result?) = entry.kind else {
                    Issue.record("The restored call has no tool disclosure in \(mode).")
                    return
                }
                let fields = try #require(ConsoleRecordDetail.resolve(entryID: id, worker: worker, run: run))
                let section = try #require(fields.sections.first { $0.id == "result" })
                let record = try AGUIValue(json: section.json)
                #expect(record["toolCallId"]?.stringValue == id)
                let reference = try #require(record["metadata"]?["acp"])
                #expect(reference["source"]?.stringValue == "provider")
                let cursor = try #require(reference["cursor"]?.stringValue)
                let observation = try #require(page.observations.first { $0.cursor == cursor })
                let rows = RecordField.rows(json: observation.record)
                let original = "extension.data.decoded.message"
                let call = try #require(rows.first { $0.path == original + ".toolCallId" })
                guard case .string(let callID, _) = call.value else {
                    Issue.record("The provider record lost the Pi call ID.")
                    return
                }
                #expect(callID == nativeID)
                if nativeID == "call_missing_read" {
                    #expect(result.error != nil)
                    #expect(result.output.contains("ENOENT") && result.output.contains("missing-swatch.txt"))
                    let flag = try #require(rows.first { $0.path == original + ".isError" })
                    guard case .literal("true") = flag.value else {
                        Issue.record("The Pi error flag is missing from the source fields.")
                        return
                    }
                } else {
                    #expect(result.error == nil)
                    let field = try #require(rows.first { $0.path == original + ".content[1].data.decoded" })
                    guard case .attachment(let mime, let image?) = field.value else {
                        Issue.record("The PNG in the source fields could not be decoded.")
                        return
                    }
                    #expect(mime == "image/png" && image == bytes)
                    let bitmap = try #require(NSBitmapImageRep(data: image))
                    #expect(bitmap.pixelsWide == 4 && bitmap.pixelsHigh == 4)
                }
            }
        }
    }
}
