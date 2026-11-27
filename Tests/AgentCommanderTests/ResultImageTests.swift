import AppKit
import Foundation
import Testing
@testable import AgentCommander

/// Issue #122: a Read of a PNG keeps its image twice in the stored record, as Claude's result part
/// and as ACP tool content. The opened line draws one thumbnail per distinct image and the
/// sentence gains the `image` tag. Only those two exact forms are read.
@Suite struct ResultImageTests {
    /// A whole PNG of one colour. Two colours give two distinct images.
    static func png(red: CGFloat = 0.5, side: Int = 2) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let colour = NSColor(deviceRed: red, green: 0.1, blue: 0.6, alpha: 1)
        for x in 0..<side { for y in 0..<side { rep.setColor(colour, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    static let plum = png(red: 0.5)
    static let teal = png(red: 0.0)

    /// Claude's own result part, with `data` as the encoded text given.
    static func resultPart(_ data: String?) -> String {
        #"{"type":"image","source":{"type":"base64","media_type":"image/png""#
            + (data.map { #","data":""# + $0 + "\"" } ?? "") + "}}"
    }

    /// The ACP tool content part of the same call.
    static func contentPart(_ data: String?) -> String {
        #"{"type":"content","content":{"type":"image","mimeType":"image/png""#
            + (data.map { #","data":""# + $0 + "\"" } ?? "") + "}}"
    }

    static func list(_ parts: String...) -> String { "[" + parts.joined(separator: ",") + "]" }
    static func encoded(_ data: Data) -> String { data.base64EncodedString() }

    static func record(result: String?, content: String? = nil, kind: String = "tool") -> ToolDetailRecord {
        ToolDetailRecord(key: "call-w:1", kind: kind, name: "Read", input: #"{"file_path":"/tmp/swatch.png"}"#,
                         result: result, content: content)
    }

    /// One finished Read as the console sends it, and its sentence with the stored record given.
    static func read(_ record: ToolDetailRecord?, error: String? = nil) -> (entry: TranscriptEntry, step: ActivityStep) {
        var wire = Wire()
        wire.call("Read", detail: "/tmp/swatch.png", result: "[image]", error: error)
        let entry = wire.entries[0]
        let step = ActivitySteps.step(tool: entry, awaitingToolID: nil, facts: ActivityFacts(record: { _ in record }))!
        return (entry, step)
    }

    // MARK: The retained forms

    @Test func theResultFormAloneIsOneImage() {
        let stored = Self.list(Self.resultPart(Self.encoded(Self.plum)))
        let record = Self.record(result: stored)
        #expect(record.resultImages == ResultImages(images: [Self.plum], unkept: 0))

        let (entry, step) = Self.read(record)
        #expect(step.tag == .image && step.state == .done)
        let source = ActivityResultSource(entry: entry, step: step, record: record)
        #expect(source.images?.images == [Self.plum])
        // Source keeps the stored text exactly, for its view and its Copy.
        #expect(source.resultText == stored)
    }

    @Test func theContentFormAloneIsOneImage() {
        let record = Self.record(result: nil, content: Self.list(Self.contentPart(Self.encoded(Self.plum))))
        #expect(record.resultImages == ResultImages(images: [Self.plum], unkept: 0))
        #expect(Self.record(result: "  ", content: Self.list(Self.contentPart(Self.encoded(Self.plum)))).resultImages?.images == [Self.plum])
    }

    @Test func whitespaceAndURLSafeBase64AreRead() {
        let spaced = " [ " + Self.resultPart(Self.encoded(Self.plum)) + " ]\n"
        #expect(Self.record(result: spaced).resultImages?.images == [Self.plum])
        let urlSafe = Self.encoded(Self.plum).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(ResultImages.png(urlSafe) == Self.plum)
    }

    // MARK: Duplicates

    @Test func theSameBytesInBothFormsAreOneThumbnail() {
        let record = Self.record(result: Self.list(Self.resultPart(Self.encoded(Self.plum))),
                                 content: Self.list(Self.contentPart(Self.encoded(Self.plum))))
        #expect(record.resultImages == ResultImages(images: [Self.plum], unkept: 0))
    }

    @Test func distinctImagesAreAllKeptInOrder() {
        let two = Self.record(result: Self.list(Self.resultPart(Self.encoded(Self.plum)), Self.resultPart(Self.encoded(Self.teal))),
                              content: Self.list(Self.contentPart(Self.encoded(Self.plum)), Self.contentPart(Self.encoded(Self.teal))))
        #expect(two.resultImages == ResultImages(images: [Self.plum, Self.teal], unkept: 0))
        // The two forms disagree at one position: both images are real, and both show.
        let differing = Self.record(result: Self.list(Self.resultPart(Self.encoded(Self.plum))),
                                    content: Self.list(Self.contentPart(Self.encoded(Self.teal))))
        #expect(differing.resultImages?.images == [Self.plum, Self.teal])
    }

    @Test func theSameBytesTwiceInOneListAreOneThumbnail() {
        let part = Self.resultPart(Self.encoded(Self.plum))
        #expect(Self.record(result: Self.list(part, part)).resultImages == ResultImages(images: [Self.plum], unkept: 0))
    }

    // MARK: Bytes that are absent or not usable

    @Test func aPartWithoutUsableBytesIsNamedAsNotKept() {
        let truncated = Self.plum.dropLast(12)
        let unusable: [String?] = [
            nil,                                                        // no data member
            "",                                                         // blanked by the service
            String(Self.encoded(Self.plum).prefix(40)) + PrettyJSON.storedMark, // shortened before it was stored
            "not base64 at all!",
            Data("plain text, not a PNG".utf8).base64EncodedString(),   // valid base64, wrong bytes
            Data(truncated).base64EncodedString(),                      // a PNG without its end
        ]
        for data in unusable {
            let record = Self.record(result: Self.list(Self.resultPart(data)))
            #expect(record.resultImages == ResultImages(images: [], unkept: 1), "data: \(data ?? "nil")")
            // The line still opens, with its tag, and Source still has the stored text.
            let (entry, step) = Self.read(record)
            #expect(step.tag == .image && step.opens)
            #expect(ActivityResultSource(entry: entry, step: step, record: record).resultText == record.result)
        }
        #expect(ResultImages.unkeptSentence == "Image (image/png). Commander did not keep it.")
    }

    @Test func theOtherFormSuppliesBytesTheResultLost() {
        let record = Self.record(result: Self.list(Self.resultPart("")),
                                 content: Self.list(Self.contentPart(Self.encoded(Self.plum))))
        #expect(record.resultImages == ResultImages(images: [Self.plum], unkept: 0))
        // Each position is settled on its own: one kept in either form, one in neither.
        let mixed = Self.record(result: Self.list(Self.resultPart(Self.encoded(Self.plum)), Self.resultPart("")),
                                content: Self.list(Self.contentPart(""), Self.contentPart("")))
        #expect(mixed.resultImages == ResultImages(images: [Self.plum], unkept: 1))
    }

    @Test func aResultCutInsideItsDataKeepsTheDescriptor() {
        let whole = Self.list(Self.resultPart(Self.encoded(Self.plum)))
        let cut = String(whole.prefix(whole.count - 30))
        #expect(Self.record(result: cut).resultImages == ResultImages(images: [], unkept: 1))
    }

    // MARK: Limits

    @Test func valuesOverALimitAreNotDecoded() {
        let stored = Self.list(Self.resultPart(Self.encoded(Self.plum)))
        var limits = ResultImages.Limits()
        limits.encodedBytes = 16
        #expect(ResultImages.read(result: stored, content: nil, limits: limits) == ResultImages(images: [], unkept: 1))

        // The header states more pixels than the limit: the bytes never reach a decoder.
        limits = ResultImages.Limits()
        limits.side = 1
        #expect(ResultImages.read(result: stored, content: nil, limits: limits) == ResultImages(images: [], unkept: 1))
        limits = ResultImages.Limits()
        limits.pixels = 3
        #expect(ResultImages.read(result: stored, content: nil, limits: limits) == ResultImages(images: [], unkept: 1))

        // More text than is considered at all: the record is left to the existing renderers.
        limits = ResultImages.Limits()
        limits.textBytes = stored.utf8.count - 1
        #expect(ResultImages.read(result: stored, content: nil, limits: limits).isEmpty)

        // The budget is shared: the result uses it, and the content is then not read.
        limits.textBytes = stored.utf8.count
        let content = Self.list(Self.contentPart(Self.encoded(Self.teal)))
        #expect(ResultImages.read(result: stored, content: content, limits: limits).images == [Self.plum])

        // More parts than one list may hold.
        limits = ResultImages.Limits()
        limits.parts = 1
        let part = Self.resultPart(Self.encoded(Self.plum))
        #expect(ResultImages.read(result: Self.list(part, part), content: nil, limits: limits).isEmpty)
    }

    // MARK: No false match

    @Test func nothingElseIsReadAsAnImage() {
        let data = Self.encoded(Self.plum)
        let others: [String] = [
            "The file is an image (image/png).",
            "image/png",
            #"[{"type":"image"}]"#,
            #"[{"type":"image","mimeType":"image/png","data":""# + data + #""}]"#,
            #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":""# + data + #""}}"#,
            #"[{"name":"swatch","type":"image","media_type":"image/png"}]"#,
            #"{"result":"# + Self.list(Self.resultPart(data)) + "}",
            // Other media types, and a source that is not base64.
            #"[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":""# + data + #""}}]"#,
            #"[{"type":"audio","source":{"type":"base64","media_type":"audio/wav","data":""# + data + #""}}]"#,
            #"[{"type":"image","source":{"type":"url","media_type":"image/png","url":"https://example.org/a.png"}}]"#,
            // A list that mixes in another part, and a part with a member the form does not have.
            Self.list(#"{"type":"text","text":"Here is the image."}"#, Self.resultPart(data)),
            #"[{"type":"image","note":"x","source":{"type":"base64","media_type":"image/png","data":""# + data + #""}}]"#,
            #"["data:image/png;base64,"# + data + #""]"#,
            "[]",
        ]
        for text in others {
            let record = Self.record(result: text)
            #expect(record.resultImages == nil, "read as an image: \(text.prefix(60))")
            #expect(Self.read(record).step.tag == nil)
        }
        // A result that is something else is not overruled by the content beside it.
        let withContent = Self.record(result: "1\tline one", content: Self.list(Self.contentPart(data)))
        #expect(withContent.resultImages == nil)
        // The content form is not accepted where the result form belongs, nor the reverse.
        #expect(Self.record(result: Self.list(Self.contentPart(data))).resultImages == nil)
        #expect(Self.record(result: nil, content: Self.list(Self.resultPart(data))).resultImages == nil)
        // Only a tool record is read.
        #expect(Self.record(result: Self.list(Self.resultPart(data)), kind: "job").resultImages == nil)
    }

    @Test func existingResultsKeepTheirRenderers() {
        // A text file read, with no image in its record: the same source and selection as before.
        let record = Self.record(result: "1\tline one\n2\tline two")
        let (entry, step) = Self.read(record)
        let source = ActivityResultSource(entry: entry, step: step, record: record)
        #expect(source.images == nil && step.tag == nil)
        let payload = ResultPayload.read(source.resultText, cut: source.resultCut)
        #expect(ResultShape.select(tool: "Read", payload: payload, resultText: source.resultText, failed: false).shape == .textFile)
    }

    // MARK: When the tag shows

    @Test func theTagNeedsTheStoredRecordAndAFinishedCall() {
        let record = Self.record(result: Self.list(Self.resultPart(Self.encoded(Self.plum))))
        // Before the record is read there is no evidence, and no tag.
        #expect(Self.read(nil).step.tag == nil)
        #expect(Self.read(record).step.tag == .image)
        // A failed call keeps its failure tag and its failure renderer.
        let failed = Self.read(record, error: "File does not exist.")
        #expect(failed.step.state == .failed && failed.step.tag != .image)
        // It is not a state, so a closed group's summary does not count it.
        #expect(!ActivityTag.image.isNamedOnSummary)
    }

    @MainActor @Test func theStoreReadsARecordsImagesOnce() {
        let record = Self.record(result: Self.list(Self.resultPart(Self.encoded(Self.plum))))
        #expect(record.images == nil)
        let store = ToolDetailStore(summaries: [:], records: ["w": [
            ToolDetailRecord(key: "k0", kind: "tool", name: "Read", result: record.result),
            ToolDetailRecord(key: "k1", kind: "tool", name: "Read", result: "plain"),
        ]])
        #expect(store.record(worker: "w", key: "k0")?.images == ResultImages(images: [Self.plum], unkept: 0))
        #expect(store.record(worker: "w", key: "k1")?.images == ResultImages.none)
        #expect(store.record(worker: "w", key: "k1")?.resultImages == nil)
    }

    @MainActor @Test func aKeptImageDecodesToABoundedThumbnail() throws {
        let large = Self.png(side: 400)
        let images = try #require(Self.record(result: Self.list(Self.resultPart(Self.encoded(large)))).resultImages)
        let thumbnail = try #require(SourceAttachment.thumbnail(of: images.images[0], maxPixel: Int(ResultImageRow.box.width) * 2))
        #expect(thumbnail.size.width == 352 && thumbnail.size.height == 352)
    }
}
