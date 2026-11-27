import Foundation

// RESULT IMAGES
// The PNG images a stored tool record holds, for the opened Pretty line's thumbnail row and the
// sentence's `image` tag (DESIGN.md, "Pretty transcript"; spec section H, "Images in results").
// Pure values; the row is `ResultImageRow` in ActivityResultViews.swift.
//
// Two retained forms are read, and only when the whole value is that form:
//
//   result    [{"type":"image","source":{"type":"base64","media_type":"image/png","data":"…"}}]
//             Claude's own tool result
//   content   [{"type":"content","content":{"type":"image","mimeType":"image/png","data":"…"}}]
//             the ACP tool content of the same call, which carries the same bytes again
//
// Nothing is inferred: text that mentions an image, a `type` field in other JSON, another media
// type and a list that mixes in any other part are all left to the existing renderers. Nothing
// is fetched; a `uri` beside the data is never followed. The stored text is not changed, so
// Source shows and copies it exactly.

struct ResultImages: Equatable, Sendable {
    /// Bounds on what is read. The service caps one stored value at 512 KB.
    struct Limits: Sendable {
        /// Bytes of record text considered, across the result and the content together.
        var textBytes = 4 << 20
        /// Base64 characters of one image.
        var encodedBytes = 1 << 20
        /// Parts in one list.
        var parts = 16
        /// Pixels along one side, and in the whole image, as the PNG header states them.
        var side = 8_192
        var pixels = 32_000_000
    }

    /// The one media type read.
    static let mediaType = "image/png"
    /// What stands in for a part whose bytes are not usable.
    static let unkeptSentence = "Image (image/png). Commander did not keep it."
    static let none = ResultImages(images: [], unkept: 0)

    /// The distinct usable images, in the order sent. The same bytes held twice are one image.
    var images: [Data]
    /// Parts that name a PNG whose bytes are absent, shortened, invalid or over a limit.
    var unkept: Int

    var isEmpty: Bool { images.isEmpty && unkept == 0 }

    /// The images of one stored record. The result decides: when it is the exact form, the
    /// content adds its copy of each part by position. The content alone is read only when the
    /// record holds no result text.
    static func read(result: String?, content: String?, limits: Limits = Limits()) -> ResultImages {
        var budget = limits.textBytes
        let resultText = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fromResult = parts(resultText, form: .result, limits: limits, budget: &budget)
        if fromResult == nil, !resultText.isEmpty { return .none }
        let fromContent = parts(content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", form: .content,
                                limits: limits, budget: &budget)
        guard fromResult != nil || fromContent != nil else { return .none }

        var images: [Data] = []
        var unkept = 0
        for index in 0..<max(fromResult?.count ?? 0, fromContent?.count ?? 0) {
            let held = [fromResult, fromContent].compactMap { list in
                list.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            }
            if held.isEmpty { unkept += 1 }
            for data in held where !images.contains(data) { images.append(data) }
        }
        return ResultImages(images: images, unkept: unkept)
    }

    // MARK: The two forms

    private enum Form {
        case result, content

        /// The object that states the media type and holds the data, when `part` is this form's
        /// image part exactly: the named keys with the named values, and no other key.
        func image(_ part: OrderedJSON) -> OrderedJSON? {
            switch self {
            case .result:
                guard Self.has(part, only: ["type", "source"]), part["type"]?.string == "image",
                      let source = part["source"], Self.has(source, only: ["type", "media_type", "data"]),
                      source["type"]?.string == "base64", Self.isPNG(source["media_type"]) else { return nil }
                return source
            case .content:
                guard Self.has(part, only: ["type", "content"]), part["type"]?.string == "content",
                      let content = part["content"], Self.has(content, only: ["type", "mimeType", "data", "uri"]),
                      content["type"]?.string == "image", Self.isPNG(content["mimeType"]) else { return nil }
                return content
            }
        }

        private static func has(_ value: OrderedJSON, only keys: Set<String>) -> Bool {
            guard let members = value.members else { return false }
            return members.count <= keys.count && Set(members.map(\.key)).count == members.count
                && members.allSatisfy { keys.contains($0.key) }
        }

        private static func isPNG(_ value: OrderedJSON?) -> Bool {
            value?.string?.trimmingCharacters(in: .whitespaces).lowercased() == ResultImages.mediaType
        }
    }

    /// One list's parts: the usable bytes of each, or nil for a part without them. Nil when the
    /// text is not the form, or is larger than what is left of the budget.
    private static func parts(_ text: String, form: Form, limits: Limits, budget: inout Int) -> [Data?]? {
        // A cheap test before any parsing: the form is a list.
        guard text.utf8.first == UInt8(ascii: "[") else { return nil }
        let size = text.utf8.count
        guard size <= budget else { return nil }
        budget -= size
        guard let reading = OrderedJSON.read(text), let items = reading.value.items,
              !items.isEmpty, items.count <= limits.parts else { return nil }
        var found: [Data?] = []
        for (index, item) in items.enumerated() {
            guard let image = form.image(item) else { return nil }
            // A text that ends early ends inside its last part: those bytes are not whole.
            let isCut = reading.isCut && index == items.count - 1
            found.append(isCut ? nil : png(image["data"]?.string, limits: limits))
        }
        return found
    }

    // MARK: Bytes

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let headerChunk: [UInt8] = [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
    private static let endChunk: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    /// The bytes of base64 text when they are a whole PNG within the limits: its signature, a
    /// header that states a bounded size, and its closing chunk. Nil for anything else, so a
    /// shortened, blanked or mislabelled value is never handed to a decoder.
    static func png(_ encoded: String?, limits: Limits = Limits()) -> Data? {
        guard let encoded, !encoded.isEmpty, encoded.utf8.count <= limits.encodedBytes,
              let data = RecordBase64.decode(encoded[...].utf8), data.count <= SourceAttachment.maximumImageBytes
        else { return nil }
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, Array(bytes[0..<8]) == signature, Array(bytes[8..<16]) == headerChunk,
              data.count >= 24 + endChunk.count, [UInt8](data.suffix(endChunk.count)) == endChunk else { return nil }
        func side(_ at: Int) -> Int { bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        let width = side(16), height = side(20)
        guard width > 0, height > 0, width <= limits.side, height <= limits.side, width * height <= limits.pixels
        else { return nil }
        return data
    }
}

extension ToolDetailRecord {
    /// The PNG images of this record's result, or nil when it holds none. The store reads them
    /// once when it keeps the record (`images`); a record built elsewhere is read here.
    var resultImages: ResultImages? {
        guard kind == "tool" else { return nil }
        let found = images ?? ResultImages.read(result: result, content: content)
        return found.isEmpty ? nil : found
    }
}

extension ActivityTag {
    /// Beside the sentence of a call whose stored result is an image.
    static let image = ActivityTag(word: "image")
}
