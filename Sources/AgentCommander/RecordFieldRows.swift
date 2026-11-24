import Foundation

// RECORD FIELD ROWS
// Flattens one record's JSON into the rows `RecordFieldRow` draws. Two kinds of row come out:
//
//   Original   every member, element and leaf of the JSON as sent, at its own key path. Strings
//              are whole, numbers keep the literal the service wrote, and null stays null.
//   Derived    what a string leaf carries, listed beneath that leaf under the path segment
//              `decoded`: the fields of JSON text, the fields of base64 JSON, or the bytes of an
//              attachment with their media type.
//
// A string leaf has no members of its own, so `<leaf>.decoded` never names an original field.
// Derived rows are decoded from the text in the record, once, when the rows are built. A link
// stays text; nothing is read from disk or fetched. Limits apply to derived rows only, and a
// limit leaves the original leaf in place and says why nothing is listed beneath it.
//
// The attachment shapes this reads:
//
//   {mediaType|mimeType|media_type|mime_type, data}   base64 beside a media type: the portable
//                                                     observation envelope, an image content
//                                                     part, and Claude's `source` object
//   "data:image/png;base64,…"                         a data URL under any key, as Codex writes
//                                                     `url` and `image_url`
//   "{…}" or "[…]"                                    JSON text in a string, as tool arguments

struct RecordFieldRows {
    /// Bounds on derived rows. Original rows are never limited.
    struct Limits {
        /// How many representations may be decoded one inside another.
        var levels = 8
        /// Derived rows in one record.
        var rows = 20_000
        /// Bytes of text decoded for derived rows in one record.
        var bytes = 96 * 1024 * 1024
    }

    /// The path segment and key of a derived row.
    static let derivedKey = "decoded"

    private var rows: [RecordField] = []
    private let limits: Limits
    private var derivedRows = 0
    private var derivedBytes = 0

    private init(limits: Limits) {
        self.limits = limits
    }

    /// The rows of JSON text. Text that is not JSON is one row holding it as written.
    static func rows(json: String, limits: Limits = Limits()) -> [RecordField] {
        guard let root = try? AGUIValue(json: json) else {
            return [RecordField(id: 0, depth: 0, key: "text", path: "", value: .string(json, length: json.count))]
        }
        var builder = RecordFieldRows(limits: limits)
        builder.emit(root, key: "", path: "", depth: -1, level: 0, declared: nil)
        return builder.rows
    }

    // MARK: Original fields

    private mutating func add(_ value: RecordField.Value, key: String, path: String, depth: Int, level: Int) {
        if level > 0 { derivedRows += 1 }
        rows.append(RecordField(id: rows.count, depth: depth, key: key, path: path, value: value))
    }

    /// Lists a value and everything in it. `depth` is -1 for the root, whose container has no row
    /// of its own. `level` counts the representations decoded to reach this value. `declared` is
    /// the media type an enclosing object states for this value, when it is that object's `data`.
    private mutating func emit(_ value: AGUIValue, key: String, path: String, depth: Int, level: Int, declared: String?) {
        let isRoot = depth < 0
        let row = max(depth, 0)
        switch value {
        case .object(let members):
            if !isRoot {
                add(.container(members.count == 1 ? "{1 field}" : "{\(members.count) fields}"),
                    key: key, path: path, depth: depth, level: level)
            }
            let mediaType = Self.mediaType(declaredIn: members)
            for name in members.keys.sorted() {
                guard let member = members[name] else { continue }
                emit(member, key: name, path: path.isEmpty ? name : path + "." + name, depth: depth + 1,
                     level: level, declared: name == "data" ? mediaType : nil)
            }
        case .array(let items):
            if !isRoot {
                add(.container(items.count == 1 ? "[1 item]" : "[\(items.count) items]"),
                    key: key, path: path, depth: depth, level: level)
            }
            for (index, item) in items.enumerated() {
                emit(item, key: String(index), path: path + "[\(index)]", depth: depth + 1, level: level, declared: nil)
            }
        case .string(let text):
            add(.string(text, length: text.count), key: isRoot ? "text" : key, path: path, depth: row, level: level)
            derive(from: text, declared: declared, path: path, depth: row + 1, level: level)
        case .number(let number):
            add(.literal(number.literal), key: isRoot ? "value" : key, path: path, depth: row, level: level)
        case .bool(let flag):
            add(.literal(flag ? "true" : "false"), key: isRoot ? "value" : key, path: path, depth: row, level: level)
        case .null:
            add(.literal("null"), key: isRoot ? "value" : key, path: path, depth: row, level: level)
        }
    }

    /// The media type an object states for its `data`, under any of the names in use.
    private static func mediaType(declaredIn members: [String: AGUIValue]) -> String? {
        guard members["data"]?.stringValue != nil else { return nil }
        for name in ["mimeType", "mediaType", "mime_type", "media_type"] {
            if let type = members[name]?.stringValue, !type.isEmpty { return type }
        }
        return nil
    }

    // MARK: Derived fields

    /// Lists what a string leaf carries, beneath it. The leaf's own row is already in place.
    private mutating func derive(from text: String, declared: String?, path: String, depth: Int, level: Int) {
        guard !text.isEmpty else { return }
        let dataURL = RecordDataURL(text)
        let looksLikeJSON = dataURL == nil && Self.looksLikeJSON(text)
        guard dataURL != nil || declared != nil || looksLikeJSON else { return }

        let derivedPath = path.isEmpty ? Self.derivedKey : path + "." + Self.derivedKey
        func refuse(_ reason: String) {
            add(.container("not decoded: \(reason). The value above is whole."),
                key: Self.derivedKey, path: derivedPath, depth: depth, level: level + 1)
        }
        guard level < limits.levels else {
            return refuse("\(limits.levels) representations inside one another is the limit")
        }
        let size = text.utf8.count
        guard size <= limits.bytes - derivedBytes else {
            return refuse("this record's decoded values reached the size limit")
        }
        derivedBytes += size

        if let dataURL {
            return present(dataURL.data(), mediaType: dataURL.mediaType, path: derivedPath, depth: depth, level: level)
        }
        if let declared, let data = RecordBase64.decode(text[...].utf8) {
            return present(data, mediaType: declared, path: derivedPath, depth: depth, level: level)
        }
        if looksLikeJSON {
            var text = text
            let bound = text.withUTF8 { Self.valueBound(UnsafeRawBufferPointer($0)) }
            guard bound <= limits.rows - derivedRows else {
                return refuse("this record's decoded fields reached the limit of \(limits.rows.formatted()) rows")
            }
            if let nested = try? AGUIValue(json: text), nested.isContainer {
                return emit(nested, key: Self.derivedKey, path: derivedPath, depth: depth, level: level + 1, declared: nil)
            }
        }
        if let declared {
            // Text beside a media type that is neither base64 nor JSON. The leaf has it as sent.
            add(.attachment(mediaType: declared, data: nil), key: Self.derivedKey, path: derivedPath,
                depth: depth, level: level + 1)
        }
    }

    /// Lists decoded bytes: as fields when they are JSON, and otherwise as an attachment that
    /// keeps the bytes and their media type. Nil data is text that could not be decoded.
    private mutating func present(_ data: Data?, mediaType: String, path: String, depth: Int, level: Int) {
        if let data, !data.isEmpty, Self.isJSON(mediaType),
           data.withUnsafeBytes(Self.valueBound) <= limits.rows - derivedRows,
           let value = try? AGUIValue(json: data) {
            return emit(value, key: Self.derivedKey, path: path, depth: depth, level: level + 1, declared: nil)
        }
        // Not JSON, not readable as JSON, or too many fields to list: the bytes stay whole.
        add(.attachment(mediaType: mediaType, data: data), key: Self.derivedKey, path: path, depth: depth, level: level + 1)
    }

    private static func isJSON(_ mediaType: String) -> Bool {
        let type = (mediaType.split(separator: ";").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return type == "application/json" || type.hasSuffix("+json")
    }

    /// True when text opens and closes as a JSON object or array. A cheap test before parsing.
    private static func looksLikeJSON(_ text: String) -> Bool {
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        let utf8 = text.utf8
        guard let first = utf8.first(where: { !isSpace($0) }), let last = utf8.last(where: { !isSpace($0) }) else {
            return false
        }
        return (first == UInt8(ascii: "{") && last == UInt8(ascii: "}"))
            || (first == UInt8(ascii: "[") && last == UInt8(ascii: "]"))
    }

    /// An upper bound on the values in JSON text, found without building them: one for the
    /// document, and one for each comma and opening bracket outside a string.
    private static func valueBound(_ bytes: UnsafeRawBufferPointer) -> Int {
        var count = 1
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: ","), UInt8(ascii: "["), UInt8(ascii: "{"): count += 1
            default: break
            }
        }
        return count
    }
}

/// An RFC 2397 `data:` URL held in a string. It is read from the string itself. A string that is
/// any other kind of URL is not one of these and stays text.
struct RecordDataURL {
    /// The media type with its parameters, such as `image/png` or `text/plain;charset=utf-8`.
    let mediaType: String
    private let isBase64: Bool
    /// The text after the comma, as a view of the original string.
    private let payload: Substring.UTF8View

    private static let headerLimit = 256

    init?(_ text: String) {
        let utf8 = text.utf8
        var index = utf8.startIndex
        for expected in "data".utf8 {
            guard index < utf8.endIndex, utf8[index] | 0x20 == expected else { return nil }
            index = utf8.index(after: index)
        }
        guard index < utf8.endIndex, utf8[index] == UInt8(ascii: ":") else { return nil }
        index = utf8.index(after: index)

        // The header is short, printable ASCII with no spaces, and ends at the first comma.
        let headerStart = index
        var scanned = 0
        while index < utf8.endIndex, utf8[index] != UInt8(ascii: ",") {
            guard scanned < Self.headerLimit, utf8[index] > 0x20, utf8[index] < 0x7F else { return nil }
            scanned += 1
            index = utf8.index(after: index)
        }
        guard index < utf8.endIndex else { return nil }

        var parts = text[headerStart..<index].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        if let last = parts.last, parts.count > 1 || !last.contains("/"), last.lowercased() == "base64" {
            isBase64 = true
            parts.removeLast()
        } else {
            isBase64 = false
        }
        let type = parts.first ?? ""
        if type.isEmpty {
            // RFC 2397: a data URL that names no type is plain text.
            let parameters = parts.dropFirst().filter { !$0.isEmpty }
            mediaType = parameters.isEmpty ? "text/plain;charset=US-ASCII" : (["text/plain"] + parameters).joined(separator: ";")
        } else {
            let halves = type.split(separator: "/", omittingEmptySubsequences: false)
            guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty else { return nil }
            mediaType = parts.joined(separator: ";")
        }
        payload = text[utf8.index(after: index)...].utf8
    }

    /// The bytes the URL carries. Nil when they are not valid base64 or percent-encoding.
    func data() -> Data? {
        isBase64 ? RecordBase64.decode(payload) : RecordBase64.percentDecoded(payload)
    }
}

enum RecordBase64 {
    /// Decodes standard or URL-safe base64, with or without padding and line breaks. Nil for
    /// text with any other character, so prose beside a media type is not read as data.
    static func decode(_ text: Substring.UTF8View) -> Data? {
        let raw = Data(text)
        if let data = Data(base64Encoded: raw) { return data }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count + 3)
        var padding = 0
        for byte in raw {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            case UInt8(ascii: "="):
                padding += 1
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                guard padding == 0 else { return nil }
                bytes.append(byte)
            case UInt8(ascii: "-"):
                guard padding == 0 else { return nil }
                bytes.append(UInt8(ascii: "+"))
            case UInt8(ascii: "_"):
                guard padding == 0 else { return nil }
                bytes.append(UInt8(ascii: "/"))
            default:
                return nil
            }
        }
        guard padding <= 2, bytes.count % 4 != 1 else { return nil }
        while bytes.count % 4 != 0 { bytes.append(UInt8(ascii: "=")) }
        return Data(base64Encoded: Data(bytes))
    }

    /// The bytes of percent-encoded text. Nil for a `%` that two hex digits do not follow.
    static func percentDecoded(_ text: Substring.UTF8View) -> Data? {
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next().flatMap(hex), let low = iterator.next().flatMap(hex) else { return nil }
            bytes.append(high << 4 | low)
        }
        return Data(bytes)
    }
}
