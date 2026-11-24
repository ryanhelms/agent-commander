import Foundation
import Testing
@testable import AgentCommander

/// A source page keeps each observation whole: unknown members, null, numbers as written, and
/// records far longer than 6,000 characters. Every value here is made up for the test.
@Suite struct SourceEnvelopeTests {
    /// 45 digits: more than `Double`, `Int64` or `Decimal` hold.
    static let longInteger = "123456789012345678901234567890123456789012345"
    static let longDecimal = "0.1234567890123456789012345678901234567890123456789"

    static let image: Data = {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes.append(contentsOf: (0..<6_500).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        return Data(bytes)
    }()

    static func page(_ observations: String, next: String = "") throws -> SourcePage {
        let cursor = next.isEmpty ? "" : #", "nextCursor": "\#(next)""#
        return try SourcePage(envelope: Data(#"{"observations": [\#(observations)]\#(cursor)}"#.utf8))
    }

    static func field(_ path: String, in rows: [RecordField]) -> RecordField? {
        rows.first { $0.path == path }
    }

    static func literal(_ path: String, in rows: [RecordField]) -> String? {
        if case .literal(let text)? = field(path, in: rows)?.value { return text }
        return nil
    }

    static func string(_ path: String, in rows: [RecordField]) -> String? {
        if case .string(let text, _)? = field(path, in: rows)?.value { return text }
        return nil
    }

    @Test func numbersNullAndUnknownMembersStayAsWritten() throws {
        let page = try Self.page(#"""
        {
          "cursor": "c-1", "turnId": "t-1",
          "session": {"harnessInstance": "claude-1", "sessionId": "s-1"},
          "text": {"speaker": "assistant", "text": "hello"},
          "sequence": \#(Self.longInteger),
          "ratio": \#(Self.longDecimal),
          "exponent": 1.50E+400,
          "whole": 1.0,
          "parent": null,
          "vendor": {"future": [true, null, {"depth": \#(Self.longInteger)}]}
        }
        """#, next: "c-2")

        #expect(page.nextCursor == "c-2")
        let observation = try #require(page.observations.first)
        #expect(observation.cursor == "c-1")
        #expect(observation.turnID == "t-1")
        #expect(observation.session == NativeSession(harnessInstance: "claude-1", sessionID: "s-1"))
        #expect(observation.body == .text(speaker: "assistant", text: "hello"))

        // The record is the observation itself, read back without loss.
        let record = try AGUIValue(json: observation.record)
        #expect(record["sequence"]?.numberValue?.literal == Self.longInteger)
        #expect(record["ratio"]?.numberValue?.literal == Self.longDecimal)
        #expect(record["exponent"]?.numberValue?.literal == "1.50E+400")
        #expect(record["whole"]?.numberValue?.literal == "1.0")
        #expect(record["parent"] == .null)

        let rows = RecordField.rows(json: observation.record)
        #expect(Self.literal("sequence", in: rows) == Self.longInteger)
        #expect(Self.literal("ratio", in: rows) == Self.longDecimal)
        #expect(Self.literal("exponent", in: rows) == "1.50E+400")
        #expect(Self.literal("whole", in: rows) == "1.0")
        #expect(Self.literal("parent", in: rows) == "null")
        #expect(Self.literal("vendor.future[0]", in: rows) == "true")
        #expect(Self.literal("vendor.future[1]", in: rows) == "null")
        #expect(Self.literal("vendor.future[2].depth", in: rows) == Self.longInteger)
        #expect(Self.string("text.text", in: rows) == "hello")
        #expect(Self.string("session.sessionId", in: rows) == "s-1")
    }

    @Test func aRecordBeyondSixThousandCharactersIsWholeAndNavigable() throws {
        let long = String(repeating: "abcdefghij", count: 1_500)
        let page = try Self.page(#"""
        {
          "cursor": "c-9",
          "tool": {"callId": "call-1", "name": "Read", "phase": "completed", "summary": "\#(long)"},
          "zz_after": {"last": \#(Self.longInteger)}
        }
        """#)
        let observation = try #require(page.observations.first)
        #expect(observation.body == .tool(callID: "call-1", name: "Read", phase: "completed", summary: long))
        #expect(observation.record.count > 15_000)

        // Fields that sort after the long value are still rows of their own.
        let rows = RecordField.rows(json: observation.record)
        #expect(Self.string("tool.summary", in: rows) == long)
        #expect(Self.literal("zz_after.last", in: rows) == Self.longInteger)
    }

    @Test func extensionDataIsKeptAsSentAndDecoded() throws {
        let encoded = Self.image.base64EncodedString()
        let page = try Self.page(#"""
        {
          "cursor": "c-3",
          "extension": {"type": "provider.image", "mediaType": "image/png", "data": "\#(encoded)", "width": 64}
        }
        """#)
        let observation = try #require(page.observations.first)
        #expect(observation.body == .attachment(type: "provider.image", mediaType: "image/png", data: Self.image))

        let rows = RecordField.rows(json: observation.record)
        #expect(Self.string("extension.data", in: rows) == encoded)
        #expect(Self.literal("extension.width", in: rows) == "64")
        guard case .attachment(let mediaType, let data)? = Self.field("extension.data.decoded", in: rows)?.value else {
            Issue.record("the extension's data has no decoded row")
            return
        }
        #expect(mediaType == "image/png")
        #expect(data == Self.image)
    }

    @Test func jsonExtensionListsItsDecodedFields() throws {
        let payload = #"{"usage":{"tokens":\#(Self.longInteger)},"stop":null}"#
        let page = try Self.page(#"""
        {"extension": {"type": "provider.record", "mediaType": "application/json",
                       "data": "\#(Data(payload.utf8).base64EncodedString())"}}
        """#)
        let rows = RecordField.rows(json: try #require(page.observations.first).record)
        #expect(Self.literal("extension.data.decoded.usage.tokens", in: rows) == Self.longInteger)
        #expect(Self.literal("extension.data.decoded.stop", in: rows) == "null")
    }

    @Test func inputChoicesAndOtherBodiesKeepTheirTyping() throws {
        let page = try Self.page(#"""
        {"input": {"prompt": "Proceed?", "choices": ["Yes", {"label": "No", "id": 2}, {"weight": 3}, 7]}},
        {"turnEnded": {"reason": "end_turn"}},
        {"gap": {"reason": "rotated"}},
        {"turnId": 42, "novel": {"a": 1}},
        "not an object"
        """#)
        #expect(page.nextCursor == nil)
        #expect(page.observations.map(\.body) == [
            .input(prompt: "Proceed?", choices: ["Yes", "No", #"{"weight":3}"#, "7"]),
            .turnEnded(reason: "end_turn"),
            .gap(reason: "rotated"),
            .unrecognized,
            .unrecognized
        ])
        #expect(page.observations[3].turnID == "42")
        #expect(page.observations[4].record == #""not an object""#)
    }

    @Test func anEnvelopeThatIsNotAnObjectIsRejected() {
        #expect(throws: (any Error).self) { try SourcePage(envelope: Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try SourcePage(envelope: Data("{".utf8)) }
        #expect((try? SourcePage(envelope: Data("{}".utf8)))?.observations.isEmpty == true)
    }
}
