import Foundation
import Testing
@testable import AgentCommander

/// Rows for the attachment shapes Claude and Codex records carry. Every value here is made up for
/// the test: the image bytes are a PNG signature followed by a counting pattern.
@Suite struct RecordFieldTests {
    // MARK: Fixtures

    /// Image bytes long enough that their base64 is well over 6,000 characters.
    static let image: Data = {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes.append(contentsOf: (0..<6_500).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        return Data(bytes)
    }()

    static let imageBase64 = image.base64EncodedString()
    static let imageDataURL = "data:image/png;base64," + imageBase64

    /// The portable observation envelope: JSON as base64, beside its media type.
    static func envelope(_ payload: AGUIValue, kind: String = "prompt") -> AGUIValue {
        [
            "kind": .string(kind),
            "cursor": "c-17",
            "extension": [
                "type": "provider.record",
                "mediaType": "application/json",
                "data": .string(Data(payload.compactText.utf8).base64EncodedString())
            ]
        ]
    }

    static func rows(_ value: AGUIValue) -> [RecordField] {
        RecordField.rows(json: value.prettyText)
    }

    // MARK: Reading rows

    static func field(_ path: String, in rows: [RecordField]) -> RecordField? {
        rows.first { $0.path == path }
    }

    static func string(_ path: String, in rows: [RecordField]) -> String? {
        guard case .string(let text, let length)? = field(path, in: rows)?.value else { return nil }
        #expect(length == text.count)
        return text
    }

    static func literal(_ path: String, in rows: [RecordField]) -> String? {
        guard case .literal(let text)? = field(path, in: rows)?.value else { return nil }
        return text
    }

    static func container(_ path: String, in rows: [RecordField]) -> String? {
        guard case .container(let summary)? = field(path, in: rows)?.value else { return nil }
        return summary
    }

    static func attachment(_ path: String, in rows: [RecordField]) -> (mediaType: String, data: Data?)? {
        guard case .attachment(let mediaType, let data)? = field(path, in: rows)?.value else { return nil }
        return (mediaType, data)
    }

    static func attachments(in rows: [RecordField]) -> [RecordField] {
        rows.filter { if case .attachment = $0.value { true } else { false } }
    }

    /// The image is offered once, at `path`, with its type and exact bytes, and the string it
    /// was decoded from is still listed whole directly above it.
    static func expectImage(at path: String, from original: String, in rows: [RecordField],
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let found = attachment(path, in: rows)
        #expect(found?.mediaType == "image/png", sourceLocation: sourceLocation)
        #expect(found?.data == image, sourceLocation: sourceLocation)
        #expect(attachments(in: rows).count == 1, sourceLocation: sourceLocation)

        let leaf = String(path.dropLast(".decoded".count))
        let text = string(leaf, in: rows)
        #expect(text == original, sourceLocation: sourceLocation)
        #expect((text?.count ?? 0) > 6_000, sourceLocation: sourceLocation)
        if let leafRow = field(leaf, in: rows), let imageRow = field(path, in: rows) {
            #expect(imageRow.id == leafRow.id + 1, sourceLocation: sourceLocation)
            #expect(imageRow.depth == leafRow.depth + 1, sourceLocation: sourceLocation)
            #expect(imageRow.key == "decoded", sourceLocation: sourceLocation)
        }
        expectWellFormed(rows, sourceLocation: sourceLocation)
    }

    /// Row IDs count from zero and no two rows share a path.
    static func expectWellFormed(_ rows: [RecordField], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(rows.map(\.id) == Array(rows.indices), sourceLocation: sourceLocation)
        #expect(Set(rows.map(\.path)).count == rows.count, sourceLocation: sourceLocation)
    }

    // MARK: The six shapes

    /// 1. Live prompt record, the same for Claude and Codex: the envelope's JSON is an image part.
    @Test(arguments: ["claude", "codex"])
    func livePromptImagePart(provider: String) throws {
        let part: AGUIValue = ["type": "image", "mimeType": "image/png", "data": .string(Self.imageBase64),
                               "provider": .string(provider)]
        let record = Self.envelope(part)
        let rows = Self.rows(record)

        // The envelope's own fields, as sent.
        #expect(Self.string("kind", in: rows) == "prompt")
        #expect(Self.string("cursor", in: rows) == "c-17")
        #expect(Self.container("extension", in: rows) == "{3 fields}")
        #expect(Self.string("extension.type", in: rows) == "provider.record")
        #expect(Self.string("extension.mediaType", in: rows) == "application/json")
        #expect(Self.string("extension.data", in: rows) == record["extension"]?["data"]?.stringValue)

        // The JSON it carries, as fields of their own.
        #expect(Self.container("extension.data.decoded", in: rows) == "{4 fields}")
        #expect(Self.string("extension.data.decoded.type", in: rows) == "image")
        #expect(Self.string("extension.data.decoded.mimeType", in: rows) == "image/png")
        #expect(Self.string("extension.data.decoded.provider", in: rows) == provider)
        Self.expectImage(at: "extension.data.decoded.data.decoded", from: Self.imageBase64, in: rows)

        let decoded = try #require(Self.field("extension.data.decoded", in: rows))
        let data = try #require(Self.field("extension.data", in: rows))
        #expect(decoded.key == "decoded")
        #expect(decoded.depth == data.depth + 1)
    }

    /// 2. Claude provider history: `source.data` beside `source.media_type`, inside the envelope.
    @Test func claudeProviderSource() {
        let block: AGUIValue = [
            "type": "image",
            "source": ["type": "base64", "media_type": "image/png", "data": .string(Self.imageBase64)]
        ]
        let rows = Self.rows(Self.envelope(block, kind: "history"))

        #expect(Self.string("extension.data.decoded.source.type", in: rows) == "base64")
        #expect(Self.string("extension.data.decoded.source.media_type", in: rows) == "image/png")
        Self.expectImage(at: "extension.data.decoded.source.data.decoded", from: Self.imageBase64, in: rows)
    }

    /// 3. Claude journal: `message.content[].source.data`.
    @Test func claudeJournalMessageContent() {
        let record: AGUIValue = [
            "type": "user",
            "uuid": "00000000-0000-4000-8000-000000000001",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "What is in this picture?"],
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png", "data": .string(Self.imageBase64)]]
                ]
            ]
        ]
        let rows = Self.rows(record)

        #expect(Self.container("message.content", in: rows) == "[2 items]")
        #expect(Self.string("message.content[0].text", in: rows) == "What is in this picture?")
        #expect(Self.string("message.content[1].source.media_type", in: rows) == "image/png")
        Self.expectImage(at: "message.content[1].source.data.decoded", from: Self.imageBase64, in: rows)
    }

    /// 4. Codex provider history: `url` is a data URL, inside the envelope.
    @Test func codexProviderDataURL() {
        let item: AGUIValue = ["type": "image", "url": .string(Self.imageDataURL)]
        let rows = Self.rows(Self.envelope(item, kind: "history"))

        #expect(Self.string("extension.data.decoded.type", in: rows) == "image")
        Self.expectImage(at: "extension.data.decoded.url.decoded", from: Self.imageDataURL, in: rows)
    }

    /// 5. Codex journal: `payload.content[].image_url`.
    @Test func codexJournalPayloadContent() {
        let record: AGUIValue = [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "Describe the screenshot."],
                    ["type": "input_image", "image_url": .string(Self.imageDataURL)]
                ]
            ]
        ]
        let rows = Self.rows(record)

        #expect(Self.string("payload.content[1].type", in: rows) == "input_image")
        Self.expectImage(at: "payload.content[1].image_url.decoded", from: Self.imageDataURL, in: rows)
    }

    /// 6. Codex journal: `payload.item.content[].image_url`.
    @Test func codexJournalPayloadItemContent() {
        let record: AGUIValue = [
            "type": "event_msg",
            "payload": [
                "type": "item_completed",
                "item": [
                    "id": "item_3",
                    "content": [["type": "input_image", "image_url": .string(Self.imageDataURL)]]
                ]
            ]
        ]
        let rows = Self.rows(record)

        #expect(Self.string("payload.item.id", in: rows) == "item_3")
        Self.expectImage(at: "payload.item.content[0].image_url.decoded", from: Self.imageDataURL, in: rows)
    }

    // MARK: Nesting

    /// Provider history that holds a further envelope is listed at every level.
    @Test func envelopeInsideEnvelope() {
        let inner = Self.envelope(["type": "image", "mimeType": "image/png", "data": .string(Self.imageBase64)])
        let rows = Self.rows(Self.envelope(["note": "replayed", "record": inner], kind: "history"))

        #expect(Self.string("extension.data.decoded.note", in: rows) == "replayed")
        #expect(Self.string("extension.data.decoded.record.kind", in: rows) == "prompt")
        #expect(Self.string("extension.data.decoded.record.extension.mediaType", in: rows) == "application/json")
        Self.expectImage(at: "extension.data.decoded.record.extension.data.decoded.data.decoded",
                         from: Self.imageBase64, in: rows)
    }

    /// JSON text in a string, as tool arguments are sent, is listed beneath the string.
    @Test func jsonTextInAString() {
        // Serialised from a value, so the string is valid JSON whatever the base64 holds.
        let payload: AGUIValue = [
            "path": "notes.txt",
            "limit": 40,
            "image": ["media_type": "image/png", "data": .string(Self.imageBase64)]
        ]
        let arguments = payload.compactText
        let rows = Self.rows(["function": ["name": "read", "arguments": .string(arguments)]])

        #expect(Self.string("function.arguments", in: rows) == arguments)
        #expect(Self.container("function.arguments.decoded", in: rows) == "{3 fields}")
        #expect(Self.string("function.arguments.decoded.path", in: rows) == "notes.txt")
        #expect(Self.literal("function.arguments.decoded.limit", in: rows) == "40")
        Self.expectImage(at: "function.arguments.decoded.image.data.decoded", from: Self.imageBase64, in: rows)
    }

    /// A member named `decoded` in the record is a different path from a derived one.
    @Test func originalMemberNamedDecoded() {
        let rows = Self.rows([
            "decoded": "an original field",
            "mediaType": "application/json",
            "data": .string(Data(#"{"decoded":true}"#.utf8).base64EncodedString())
        ])

        #expect(Self.string("decoded", in: rows) == "an original field")
        #expect(Self.container("data.decoded", in: rows) == "{1 field}")
        #expect(Self.literal("data.decoded.decoded", in: rows) == "true")
        Self.expectWellFormed(rows)
    }

    // MARK: Types and unknown fields

    /// Fields nothing names keep their type and the text the service wrote.
    @Test func unknownFieldsKeepTypeAndLiteral() {
        let json = #"""
        {"big": 123456789012345678901234567890, "negative": -9223372036854775809, "ratio": 1.50,
         "huge": 1E400, "precise": 0.1234567890123456789012345, "zero": -0, "flag": false, "on": true,
         "nothing": null, "empty": "", "digits": "007", "word": "null",
         "future": {"shape": [null, 2, "three", {"deep": null}], "none": {}, "list": []}}
        """#
        let rows = RecordField.rows(json: json)

        #expect(Self.literal("big", in: rows) == "123456789012345678901234567890")
        #expect(Self.literal("negative", in: rows) == "-9223372036854775809")
        #expect(Self.literal("ratio", in: rows) == "1.50")
        #expect(Self.literal("huge", in: rows) == "1E400")
        #expect(Self.literal("precise", in: rows) == "0.1234567890123456789012345")
        #expect(Self.literal("zero", in: rows) == "-0")
        #expect(Self.literal("flag", in: rows) == "false")
        #expect(Self.literal("on", in: rows) == "true")
        #expect(Self.literal("nothing", in: rows) == "null")
        // Text that reads like a literal is still a string.
        #expect(Self.string("empty", in: rows) == "")
        #expect(Self.string("digits", in: rows) == "007")
        #expect(Self.string("word", in: rows) == "null")
        #expect(Self.literal("word", in: rows) == nil)

        #expect(Self.container("future", in: rows) == "{3 fields}")
        #expect(Self.container("future.shape", in: rows) == "[4 items]")
        #expect(Self.literal("future.shape[0]", in: rows) == "null")
        #expect(Self.literal("future.shape[1]", in: rows) == "2")
        #expect(Self.string("future.shape[2]", in: rows) == "three")
        #expect(Self.container("future.shape[3]", in: rows) == "{1 field}")
        #expect(Self.literal("future.shape[3].deep", in: rows) == "null")
        #expect(Self.container("future.none", in: rows) == "{0 fields}")
        #expect(Self.container("future.list", in: rows) == "[0 items]")
        #expect(rows.map(\.key).prefix(3) == ["big", "digits", "empty"])
        Self.expectWellFormed(rows)
    }

    /// The same holds for JSON decoded from an envelope.
    @Test func decodedFieldsKeepTypeAndLiteral() throws {
        let payload = try AGUIValue(json: #"{"seq":18446744073709551616,"cost":0.10,"parent":null,"final":false,"extra":{"k":[1e-7]}}"#)
        let rows = Self.rows(Self.envelope(payload))

        #expect(Self.literal("extension.data.decoded.seq", in: rows) == "18446744073709551616")
        #expect(Self.literal("extension.data.decoded.cost", in: rows) == "0.10")
        #expect(Self.literal("extension.data.decoded.parent", in: rows) == "null")
        #expect(Self.literal("extension.data.decoded.final", in: rows) == "false")
        #expect(Self.literal("extension.data.decoded.extra.k[0]", in: rows) == "1e-7")
        #expect(Self.attachments(in: rows).isEmpty)
        Self.expectWellFormed(rows)
    }

    @Test func rootValues() {
        #expect(RecordField.rows(json: "not json").map(\.key) == ["text"])
        #expect(Self.string("", in: RecordField.rows(json: "not json")) == "not json")
        #expect(Self.literal("", in: RecordField.rows(json: "12345678901234567890123")) == "12345678901234567890123")
        #expect(Self.literal("", in: RecordField.rows(json: "null")) == "null")
        #expect(Self.string("", in: RecordField.rows(json: #""plain""#)) == "plain")
        #expect(RecordField.rows(json: "{}").isEmpty)
    }

    // MARK: Long strings

    /// A long string is one row holding all of it, whether sent or decoded.
    @Test func longStringsAreWhole() {
        let long = String(repeating: "abcdefghij", count: 700) + "END"
        let rows = Self.rows(Self.envelope(["text": .string(long), "type": "text"]))

        #expect(Self.string("extension.data.decoded.text", in: rows) == long)
        let outer = Self.string("extension.data", in: rows)
        #expect((outer?.count ?? 0) > 6_000)
        #expect(outer.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }?.hasSuffix(#"END","type":"text"}"#) == true)

        let direct = RecordField.rows(json: AGUIValue.object(["content": .string(long)]).compactText)
        #expect(Self.string("content", in: direct) == long)
        #expect(direct.count == 1)
    }

    // MARK: Links, unsupported types and failures

    /// A link stays text. Nothing is decoded from it and nothing is offered to render.
    @Test func linksAndPathsStayText() {
        let rows = Self.rows([
            "image_url": "https://example.invalid/picture.png",
            "url": "file:///tmp/picture.png",
            "path": "/tmp/picture.png",
            "note": "data: the totals, by week",
            "content": [["type": "input_image", "image_url": ["url": "http://example.invalid/a.png", "detail": "auto"]]]
        ])

        #expect(Self.string("image_url", in: rows) == "https://example.invalid/picture.png")
        #expect(Self.string("url", in: rows) == "file:///tmp/picture.png")
        #expect(Self.string("note", in: rows) == "data: the totals, by week")
        #expect(Self.string("content[0].image_url.url", in: rows) == "http://example.invalid/a.png")
        #expect(Self.attachments(in: rows).isEmpty)
        #expect(!rows.contains { $0.key == "decoded" })
    }

    /// A data URL in an object, as some clients nest `image_url`.
    @Test func dataURLInsideAnObject() {
        let rows = Self.rows(["image_url": ["url": .string(Self.imageDataURL), "detail": "high"]])
        #expect(Self.string("image_url.detail", in: rows) == "high")
        Self.expectImage(at: "image_url.url.decoded", from: Self.imageDataURL, in: rows)
    }

    /// A type that is not rendered still hands over its bytes and type, and its fields stay.
    @Test func unsupportedTypesKeepBytesAndFields() {
        let bytes = Data((0..<300).map { UInt8(truncatingIfNeeded: $0) })
        let rows = Self.rows([
            "document": ["media_type": "application/pdf", "data": .string(bytes.base64EncodedString()), "title": "Plan"],
            "vector": .string("data:image/svg+xml;base64," + Data("<svg/>".utf8).base64EncodedString()),
            "plain": "data:text/plain;charset=utf-8,hello%20there",
            "untyped": "data:,a%2Cb"
        ])

        #expect(Self.string("document.title", in: rows) == "Plan")
        #expect(Self.string("document.data", in: rows) == bytes.base64EncodedString())
        #expect(Self.attachment("document.data.decoded", in: rows)?.mediaType == "application/pdf")
        #expect(Self.attachment("document.data.decoded", in: rows)?.data == bytes)
        #expect(Self.attachment("vector.decoded", in: rows)?.mediaType == "image/svg+xml")
        #expect(Self.attachment("vector.decoded", in: rows)?.data == Data("<svg/>".utf8))
        #expect(Self.attachment("plain.decoded", in: rows)?.mediaType == "text/plain;charset=utf-8")
        #expect(Self.attachment("plain.decoded", in: rows)?.data == Data("hello there".utf8))
        #expect(Self.attachment("untyped.decoded", in: rows)?.mediaType == "text/plain;charset=US-ASCII")
        #expect(Self.attachment("untyped.decoded", in: rows)?.data == Data("a,b".utf8))
        Self.expectWellFormed(rows)
    }

    /// Base64 as it arrives from different writers: URL-safe, unpadded, and broken across lines.
    @Test func base64Variants() {
        let bytes = Data([0xFB, 0xFF, 0xFE, 0x00, 0x3E, 0x3F, 0x7F])
        let standard = bytes.base64EncodedString()
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let wrapped = String(standard.prefix(4)) + "\r\n" + String(standard.dropFirst(4))
        #expect(urlSafe != standard)

        for encoded in [standard, urlSafe, wrapped] {
            let rows = Self.rows(["mimeType": "application/octet-stream", "data": .string(encoded)])
            #expect(Self.attachment("data.decoded", in: rows)?.data == bytes)
            #expect(Self.string("data", in: rows) == encoded)
        }
    }

    /// Data that does not decode is reported as unreadable, and the text is still there as sent.
    @Test func undecodableDataIsKeptAsSent() {
        let sent = "this is not base64 — it is prose!"
        let broken = Data(#"{"type":"image","data":"#.utf8)
        let rows = Self.rows([
            "prose": ["mimeType": "image/png", "data": .string(sent)],
            "url": "data:image/png;base64,@@@@",
            "truncated": ["mediaType": "application/json", "data": .string(broken.base64EncodedString())],
            "empty": ["mediaType": "image/png", "data": ""],
            "untyped": ["data": .string(Self.imageBase64)]
        ])

        #expect(Self.string("prose.data", in: rows) == sent)
        #expect(Self.attachment("prose.data.decoded", in: rows)?.mediaType == "image/png")
        #expect(Self.attachment("prose.data.decoded", in: rows).map { $0.data == nil } == true)

        #expect(Self.string("url", in: rows) == "data:image/png;base64,@@@@")
        #expect(Self.attachment("url.decoded", in: rows).map { $0.data == nil } == true)

        // JSON that does not parse keeps the bytes it decoded to.
        #expect(Self.attachment("truncated.data.decoded", in: rows)?.mediaType == "application/json")
        #expect(Self.attachment("truncated.data.decoded", in: rows)?.data == broken)
        #expect(Self.string("truncated.data", in: rows) == broken.base64EncodedString())

        // No data, or no stated type: the fields are listed and nothing is derived.
        #expect(Self.string("empty.data", in: rows) == "")
        #expect(!rows.contains { $0.path == "empty.data.decoded" })
        #expect(Self.string("untyped.data", in: rows) == Self.imageBase64)
        #expect(!rows.contains { $0.path == "untyped.data.decoded" })
        Self.expectWellFormed(rows)
    }

    /// JSON sent as text beside a JSON media type, not as base64, is still listed as fields.
    @Test func jsonTextBesideAJSONMediaType() {
        let rows = Self.rows(["mediaType": "application/json", "data": #"{"count": 3, "items": [null]}"#])
        #expect(Self.literal("data.decoded.count", in: rows) == "3")
        #expect(Self.literal("data.decoded.items[0]", in: rows) == "null")
    }

    // MARK: Limits

    /// Envelopes nested past the limit stop being decoded. Every level reached is listed, the
    /// last string is whole, and the row beneath it says why it goes no further.
    @Test func nestingLimit() throws {
        var record: AGUIValue = ["leaf": 1]
        for _ in 0..<5 { record = Self.envelope(record) }
        let json = record.compactText

        let limited = RecordFieldRows.rows(json: json, limits: .init(levels: 3))
        let deepest = "extension.data" + String(repeating: ".decoded.extension.data", count: 3)
        let sent = try #require(Self.string(deepest, in: limited))
        #expect(Data(base64Encoded: sent) != nil)
        let note = try #require(Self.container(deepest + ".decoded", in: limited))
        #expect(note.hasPrefix("not decoded"))
        #expect(!limited.contains { $0.path.hasPrefix(deepest + ".decoded.") })
        Self.expectWellFormed(limited)

        let whole = RecordField.rows(json: json)
        #expect(Self.literal("extension.data" + String(repeating: ".decoded.extension.data", count: 4) + ".decoded.leaf",
                             in: whole) == "1")
    }

    /// JSON text with more fields than the row limit is not expanded. The string is whole, and
    /// original fields are never limited.
    @Test func rowLimit() throws {
        let many = AGUIValue.array((0..<400).map { .number(AGUINumber($0)) })
        let text = many.compactText
        let record: AGUIValue = ["original": many, "arguments": .string(text),
                                 "wrapped": ["mediaType": "application/json",
                                             "data": .string(Data(text.utf8).base64EncodedString())]]
        let rows = RecordFieldRows.rows(json: record.compactText, limits: .init(rows: 100))

        #expect(Self.literal("original[399]", in: rows) == "399")
        #expect(Self.string("arguments", in: rows) == text)
        #expect(try #require(Self.container("arguments.decoded", in: rows)).hasPrefix("not decoded"))
        #expect(!rows.contains { $0.path == "arguments.decoded[0]" })
        // Base64 JSON over the limit keeps its bytes rather than its fields.
        #expect(Self.attachment("wrapped.data.decoded", in: rows)?.data == Data(text.utf8))
        Self.expectWellFormed(rows)

        let unlimited = RecordField.rows(json: record.compactText)
        #expect(Self.literal("arguments.decoded[399]", in: unlimited) == "399")
        #expect(Self.literal("wrapped.data.decoded[399]", in: unlimited) == "399")
    }

    /// Decoded text over the byte limit is left as its string.
    @Test func byteLimit() throws {
        let rows = RecordFieldRows.rows(json: Self.envelope(["type": "text"]).compactText, limits: .init(bytes: 8))
        #expect(Self.string("extension.data", in: rows) != nil)
        #expect(try #require(Self.container("extension.data.decoded", in: rows)).hasPrefix("not decoded"))
    }
}
