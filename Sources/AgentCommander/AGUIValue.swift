import Foundation

/// A JSON number, kept as the literal the service sent. Integers beyond 64 bits and decimals
/// with more digits than a `Double` holds keep their text.
struct AGUINumber: Sendable, CustomStringConvertible {
    /// A valid JSON number literal.
    let literal: String

    init(_ value: Int) { literal = String(value) }
    init(_ value: Int64) { literal = String(value) }
    init(_ value: UInt64) { literal = String(value) }

    /// Non-finite values have no JSON form and read as zero.
    init(_ value: Double) { literal = value.isFinite ? "\(value)" : "0" }

    /// Nil unless `literal` follows the JSON number grammar.
    init?(literal: String) {
        var text = literal
        let valid = text.withUTF8 { bytes in
            AGUIValue.Parser.numberEnd(in: bytes, from: 0) == bytes.count && !bytes.isEmpty
        }
        guard valid else { return nil }
        self.literal = literal
    }

    fileprivate init(verified literal: String) { self.literal = literal }

    /// The exact integer, when the literal is one and fits.
    var int64Value: Int64? { Int64(literal) }
    var intValue: Int? { Int(literal) }
    /// The nearest double. Very large magnitudes read as infinity.
    var doubleValue: Double { Double(literal) ?? 0 }
    var decimalValue: Decimal? { Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")) }

    var description: String { literal }
}

extension AGUINumber: Equatable {
    /// Exact: two numbers are equal when the service wrote them the same way. `1`, `1.0` and
    /// `1e0` differ, and so do long literals that round to one `Double`, so no streamed change
    /// to a number is hidden from state or views. `hasSameValue(as:)` compares the values.
    static func == (lhs: AGUINumber, rhs: AGUINumber) -> Bool { lhs.literal == rhs.literal }
}

extension AGUINumber {
    /// Mathematical equality, computed exactly on the decimal digits: `1`, `1.00` and `1e0` are
    /// one value, `0` and `-0` are one value, and literals of any length that differ in any
    /// significant digit are different values. Nothing is rounded, and the work is proportional
    /// to the literal's length whatever its magnitude.
    ///
    /// An exponent of more than 18 digits is compared as written. Two such numbers are the same
    /// value only when their exponents and digit positions match, so the answer for them can be
    /// false for equal values and is never true for different ones.
    func hasSameValue(as other: AGUINumber) -> Bool {
        literal == other.literal || Normalized(literal) == Normalized(other.literal)
    }

    /// A number as its significant digits and the power of ten of the last one.
    private struct Normalized: Equatable {
        enum Scale: Equatable {
            case exact(Int)
            /// An exponent too long for an `Int`, as its sign and digits, and the shift the
            /// mantissa adds to it.
            case beyond(negative: Bool, digits: [UInt8], shift: Int)
        }

        var negative = false
        /// No leading or trailing zeros. Empty for zero, which has no sign and no scale.
        var digits: [UInt8] = []
        var scale = Scale.exact(0)

        init(_ literal: String) {
            let bytes = Array(literal.utf8)
            let minus = bytes.first == UInt8(ascii: "-")
            var index = minus ? 1 : 0
            var mantissa: [UInt8] = []
            mantissa.reserveCapacity(bytes.count)
            var fraction = 0, inFraction = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: ".") {
                    inFraction = true
                } else if byte >= 0x30, byte <= 0x39 {
                    mantissa.append(byte)
                    if inFraction { fraction += 1 }
                } else {
                    break // the exponent mark
                }
                index += 1
            }
            var exponentNegative = false
            var exponent: ArraySlice<UInt8> = []
            if index < bytes.count {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                    exponentNegative = bytes[index] == UInt8(ascii: "-")
                    index += 1
                }
                exponent = bytes[index...].drop { $0 == 0x30 }
            }

            let leading = mantissa.prefix { $0 == 0x30 }.count
            guard leading < mantissa.count else { return }
            var trailing = 0
            while mantissa[mantissa.count - 1 - trailing] == 0x30 { trailing += 1 }
            negative = minus
            digits = Array(mantissa[leading..<(mantissa.count - trailing)])
            let shift = trailing - fraction
            if exponent.count <= 18 {
                // Below 10^18, so neither this nor adding the shift can overflow.
                let magnitude = exponent.reduce(0) { $0 * 10 + Int($1 - 0x30) }
                scale = .exact((exponentNegative ? -magnitude : magnitude) + shift)
            } else {
                scale = .beyond(negative: exponentNegative, digits: Array(exponent), shift: shift)
            }
        }
    }
}

extension AGUIValue {
    /// JSON equality as RFC 6902 section 4.6 defines it for `test`: numbers by value, strings by
    /// code point, arrays in order, objects by member whatever their order. `==` is stricter
    /// about numbers and is the one for state and views.
    func isJSONEqual(to other: AGUIValue) -> Bool {
        switch (self, other) {
        case (.null, .null): true
        case (.bool(let left), .bool(let right)): left == right
        case (.number(let left), .number(let right)): left.hasSameValue(as: right)
        case (.string(let left), .string(let right)): left.utf8.elementsEqual(right.utf8)
        case (.array(let left), .array(let right)):
            left.count == right.count && zip(left, right).allSatisfy { $0.isJSONEqual(to: $1) }
        case (.object(let left), .object(let right)):
            left.count == right.count && left.allSatisfy { key, value in
                right[key].map { value.isJSONEqual(to: $0) } ?? false
            }
        default: false
        }
    }
}

/// Any JSON value from the service, kept whole. It carries the fields the typed models do not
/// name: tool metadata, multimodal content, provider extensions and fields added later.
///
/// Object members are unordered; `prettyText` sorts them. A repeated member keeps its last value.
indirect enum AGUIValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(AGUINumber)
    case string(String)
    case array([AGUIValue])
    case object([String: AGUIValue])
}

struct AGUIValueError: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: Reading

extension AGUIValue {
    var isNull: Bool { if case .null = self { true } else { false } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var numberValue: AGUINumber? { if case .number(let value) = self { value } else { nil } }
    var intValue: Int? { numberValue?.intValue }
    var doubleValue: Double? { numberValue?.doubleValue }
    var arrayValue: [AGUIValue]? { if case .array(let value) = self { value } else { nil } }
    var objectValue: [String: AGUIValue]? { if case .object(let value) = self { value } else { nil } }

    /// A member of an object. Nil for a missing member and for any other kind of value.
    subscript(key: String) -> AGUIValue? { objectValue?[key] }

    /// An element of an array. Nil when out of range and for any other kind of value.
    subscript(index: Int) -> AGUIValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// Member names in display order. Empty for anything other than an object.
    var sortedKeys: [String] { objectValue?.keys.sorted() ?? [] }

    /// True for an object or array, which an inspector shows as a tree.
    var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }

    /// The value as an inspector line: a string without its quotes, anything else as JSON.
    var displayText: String { stringValue ?? compactText }

    /// Indented JSON with sorted members, for inspectors and copying.
    var prettyText: String { serialized(pretty: true) }

    /// Single-line JSON with sorted members.
    var compactText: String { serialized(pretty: false) }
}

extension AGUIValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(AGUINumber(value)) }
    init(floatLiteral value: Double) { self = .number(AGUINumber(value)) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: AGUIValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, AGUIValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension AGUIValue: CustomStringConvertible {
    var description: String { compactText }
}

// MARK: Codable

extension AGUIValue: Codable {
    /// For values that arrive through a `Decoder`. A decoder has already converted numbers, so
    /// this keeps the precision the decoder had. `init(json:)` keeps the literal.
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode(Int64.self) {
            self = .number(AGUINumber(value))
        } else if let value = try? single.decode(UInt64.self) {
            self = .number(AGUINumber(value))
        } else if let value = try? single.decode(Double.self) {
            self = .number(AGUINumber(value))
        } else if let value = try? single.decode([AGUIValue].self) {
            self = .array(value)
        } else {
            self = .object(try single.decode([String: AGUIValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let value): try single.encode(value)
        case .string(let value): try single.encode(value)
        case .array(let value): try single.encode(value)
        case .object(let value): try single.encode(value)
        case .number(let value):
            if let integer = value.int64Value {
                try single.encode(integer)
            } else if let unsigned = UInt64(value.literal) {
                try single.encode(unsigned)
            } else if let decimal = value.decimalValue,
                      AGUINumber(literal: "\(decimal)")?.hasSameValue(as: value) == true {
                try single.encode(decimal)
            } else {
                try single.encode(value.doubleValue)
            }
        }
    }
}

// MARK: Writing

extension AGUIValue {
    private func serialized(pretty: Bool) -> String {
        var text = ""
        write(to: &text, pretty: pretty, depth: 0)
        return text
    }

    private func write(to text: inout String, pretty: Bool, depth: Int) {
        func newline(_ level: Int) {
            guard pretty else { return }
            text.append("\n")
            for _ in 0..<level { text.append("  ") }
        }
        switch self {
        case .null: text.append("null")
        case .bool(let value): text.append(value ? "true" : "false")
        case .number(let value): text.append(value.literal)
        case .string(let value): Self.writeString(value, to: &text)
        case .array(let items):
            guard !items.isEmpty else { return text.append("[]") }
            text.append("[")
            for (index, item) in items.enumerated() {
                if index > 0 { text.append(",") }
                newline(depth + 1)
                item.write(to: &text, pretty: pretty, depth: depth + 1)
            }
            newline(depth)
            text.append("]")
        case .object(let members):
            guard !members.isEmpty else { return text.append("{}") }
            text.append("{")
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { text.append(",") }
                newline(depth + 1)
                Self.writeString(key, to: &text)
                text.append(pretty ? ": " : ":")
                members[key]?.write(to: &text, pretty: pretty, depth: depth + 1)
            }
            newline(depth)
            text.append("}")
        }
    }

    private static func writeString(_ value: String, to text: inout String) {
        text.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text.append("\\\"")
            case "\\": text.append("\\\\")
            case "\n": text.append("\\n")
            case "\r": text.append("\\r")
            case "\t": text.append("\\t")
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    text.append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text.append("\"")
    }
}

// MARK: Parsing

extension AGUIValue {
    /// Parses one JSON document. Stricter than the grammar nowhere and looser nowhere: invalid
    /// UTF-8, raw control characters, trailing bytes and excessive nesting are all rejected.
    init(json data: Data) throws {
        self = try data.withUnsafeBytes { raw in
            try Self.parse(raw.bindMemory(to: UInt8.self))
        }
    }

    init(json text: String) throws {
        var text = text
        self = try text.withUTF8 { try Self.parse($0) }
    }

    init(json bytes: [UInt8]) throws {
        self = try bytes.withUnsafeBufferPointer { try Self.parse($0) }
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) throws -> AGUIValue {
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.position == bytes.count else { throw parser.failure("unexpected bytes after the value") }
        return value
    }

    fileprivate struct Parser {
        static let depthLimit = 256

        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0

        func failure(_ reason: String) -> AGUIValueError {
            AGUIValueError("Invalid JSON at byte \(position): \(reason)")
        }

        mutating func skipWhitespace() {
            while position < bytes.count {
                switch bytes[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                default: return
                }
            }
        }

        mutating func value(depth: Int) throws -> AGUIValue {
            guard position < bytes.count else { throw failure("the document ends early") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        private mutating func literal(_ word: StaticString) throws {
            let count = word.utf8CodeUnitCount
            guard position + count <= bytes.count,
                  memcmp(bytes.baseAddress! + position, word.utf8Start, count) == 0
            else { throw failure("unknown literal") }
            position += count
        }

        private mutating func object(depth: Int) throws -> AGUIValue {
            guard depth < Self.depthLimit else { throw failure("nesting is too deep") }
            position += 1
            var members: [String: AGUIValue] = [:]
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
                position += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                    throw failure("expected a member name")
                }
                let key = try string()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw failure("expected ':'") }
                position += 1
                skipWhitespace()
                members[key] = try value(depth: depth + 1)
                skipWhitespace()
                guard position < bytes.count else { throw failure("the object is not closed") }
                let byte = bytes[position]
                position += 1
                if byte == UInt8(ascii: "}") { return .object(members) }
                guard byte == UInt8(ascii: ",") else { throw failure("expected ',' or '}'") }
            }
        }

        private mutating func array(depth: Int) throws -> AGUIValue {
            guard depth < Self.depthLimit else { throw failure("nesting is too deep") }
            position += 1
            var items: [AGUIValue] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
                position += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard position < bytes.count else { throw failure("the array is not closed") }
                let byte = bytes[position]
                position += 1
                if byte == UInt8(ascii: "]") { return .array(items) }
                guard byte == UInt8(ascii: ",") else { throw failure("expected ',' or ']'") }
            }
        }

        /// The index after the number that starts at `start`, or nil when none does.
        static func numberEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
            var index = start
            func digit(_ at: Int) -> Bool { at < bytes.count && bytes[at] >= 0x30 && bytes[at] <= 0x39 }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digit(index) else { return nil }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while digit(index) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digit(index) else { return nil }
                while digit(index) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digit(index) else { return nil }
                while digit(index) { index += 1 }
            }
            return index
        }

        private mutating func number() throws -> AGUINumber {
            guard let end = Self.numberEnd(in: bytes, from: position) else { throw failure("expected a value") }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[position..<end]), as: UTF8.self)
            position = end
            return AGUINumber(verified: text)
        }

        private mutating func string() throws -> String {
            position += 1
            let start = position
            // Most strings have no escapes and are read in one pass.
            while position < bytes.count {
                let byte = bytes[position]
                if byte == UInt8(ascii: "\"") {
                    let text = try text(UnsafeBufferPointer(rebasing: bytes[start..<position]))
                    position += 1
                    return text
                }
                if byte == UInt8(ascii: "\\") { break }
                guard byte >= 0x20 else { throw failure("a control character inside a string") }
                position += 1
            }
            var buffer = Array(bytes[start..<position])
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return try buffer.withUnsafeBufferPointer { try text($0) }
                case UInt8(ascii: "\\"):
                    guard position < bytes.count else { throw failure("the string is not closed") }
                    let escape = bytes[position]
                    position += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(escape)
                    case UInt8(ascii: "b"): buffer.append(0x08)
                    case UInt8(ascii: "f"): buffer.append(0x0C)
                    case UInt8(ascii: "n"): buffer.append(0x0A)
                    case UInt8(ascii: "r"): buffer.append(0x0D)
                    case UInt8(ascii: "t"): buffer.append(0x09)
                    case UInt8(ascii: "u"): try appendEscapedScalar(to: &buffer)
                    default: throw failure("unknown escape")
                    }
                default:
                    guard byte >= 0x20 else { throw failure("a control character inside a string") }
                    buffer.append(byte)
                }
            }
            throw failure("the string is not closed")
        }

        private func text(_ utf8: UnsafeBufferPointer<UInt8>) throws -> String {
            guard let text = String(validating: utf8, as: UTF8.self) else { throw failure("invalid UTF-8") }
            return text
        }

        private mutating func hexUnit() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw failure("a short \\u escape") }
            var unit: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[position]
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte) - 0x30
                case 0x41...0x46: digit = UInt32(byte) - 0x41 + 10
                case 0x61...0x66: digit = UInt32(byte) - 0x61 + 10
                default: throw failure("a malformed \\u escape")
                }
                unit = unit << 4 | digit
                position += 1
            }
            return unit
        }

        /// Reads the four digits after `\u`, and the low half of a surrogate pair when one follows.
        /// A surrogate with no partner becomes U+FFFD, as the service's own encoder writes it.
        private mutating func appendEscapedScalar(to buffer: inout [UInt8]) throws {
            var code = try hexUnit()
            if (0xD800..<0xDC00).contains(code) {
                let rewind = position
                if position + 2 <= bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") {
                    position += 2
                    let low = try hexUnit()
                    if (0xDC00..<0xE000).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        position = rewind
                        code = 0xFFFD
                    }
                } else {
                    code = 0xFFFD
                }
            } else if (0xDC00..<0xE000).contains(code) {
                code = 0xFFFD
            }
            let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
            buffer.append(contentsOf: UTF8.encodedScalar(scalar))
        }
    }
}

extension UTF8 {
    fileprivate static func encodedScalar(_ scalar: Unicode.Scalar) -> [UInt8] {
        Array(String(Character(scalar)).utf8)
    }
}

// MARK: JSON Pointer and JSON Patch

/// An RFC 6901 pointer, as its unescaped reference tokens.
struct AGUIPointer: Equatable, Sendable, CustomStringConvertible {
    let tokens: [String]

    init(tokens: [String]) { self.tokens = tokens }

    /// `""` addresses the whole document. Any other pointer starts with `/`. `~1` is `/` and
    /// `~0` is `~` inside a token; any other use of `~` is malformed.
    init(_ text: String) throws {
        guard !text.isEmpty else {
            tokens = []
            return
        }
        guard text.hasPrefix("/") else { throw AGUIValueError("Pointer \(text) does not start with '/'") }
        tokens = try text.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { part in
            guard part.contains("~") else { return String(part) }
            var token = ""
            var escaping = false
            for character in part {
                if escaping {
                    switch character {
                    case "0": token.append("~")
                    case "1": token.append("/")
                    default: throw AGUIValueError("Pointer \(text) has a malformed escape")
                    }
                    escaping = false
                } else if character == "~" {
                    escaping = true
                } else {
                    token.append(character)
                }
            }
            guard !escaping else { throw AGUIValueError("Pointer \(text) has a malformed escape") }
            return token
        }
    }

    var description: String {
        tokens.map { "/" + $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined()
    }

    /// An array index token: decimal digits with no leading zero.
    static func index(_ token: String) -> Int? {
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              token == "0" || !token.hasPrefix("0") else { return nil }
        return Int(token)
    }
}

/// The three RFC 6902 operations that change a location. `move`, `copy` and `test` are built
/// from these and a read.
enum AGUIEdit: Equatable, Sendable {
    case add(AGUIValue)
    case replace(AGUIValue)
    case remove

    var name: String {
        switch self {
        case .add: "add"
        case .replace: "replace"
        case .remove: "remove"
        }
    }
}

enum AGUIPatch {
    /// Applies an edit to one position of an array. `-` is the position after the last element,
    /// for `add` only. `make` converts the value only once the position is known to be valid.
    static func edit<Element>(_ items: inout [Element], _ edit: AGUIEdit, token: String,
                              make: (AGUIValue) throws -> Element) throws {
        switch edit {
        case .add(let value):
            let index = token == "-" ? items.count : AGUIPointer.index(token)
            guard let index, index <= items.count else { throw AGUIValueError("add: no array position \(token)") }
            let element = try make(value)
            if index == items.count { items.append(element) } else { items.insert(element, at: index) }
        case .replace(let value):
            guard let index = AGUIPointer.index(token), index < items.count else {
                throw AGUIValueError("replace: no array element \(token)")
            }
            items[index] = try make(value)
        case .remove:
            guard let index = AGUIPointer.index(token), index < items.count else {
                throw AGUIValueError("remove: no array element \(token)")
            }
            items.remove(at: index)
        }
    }

    /// Applies an edit below an object's members. `path` is not empty.
    static func edit(_ members: inout [String: AGUIValue], _ edit: AGUIEdit, at path: ArraySlice<String>) throws {
        let key = path[path.startIndex]
        if path.count == 1 {
            switch edit {
            case .add(let value):
                members[key] = value
            case .replace(let value):
                guard members[key] != nil else { throw AGUIValueError("replace: no member \(key)") }
                members[key] = value
            case .remove:
                guard members.removeValue(forKey: key) != nil else { throw AGUIValueError("remove: no member \(key)") }
            }
            return
        }
        guard let index = members.index(forKey: key) else { throw AGUIValueError("\(edit.name): no member \(key)") }
        try members.values[index].apply(edit, at: path.dropFirst())
    }
}

extension AGUIValue {
    /// The value a pointer addresses.
    func value(at path: ArraySlice<String>) throws -> AGUIValue {
        guard let token = path.first else { return self }
        switch self {
        case .object(let members):
            guard let member = members[token] else { throw AGUIValueError("no member \(token)") }
            return try member.value(at: path.dropFirst())
        case .array(let items):
            guard let index = AGUIPointer.index(token), index < items.count else {
                throw AGUIValueError("no array element \(token)")
            }
            return try items[index].value(at: path.dropFirst())
        default:
            throw AGUIValueError("\(token) is below a value that has no members")
        }
    }

    /// Applies one edit in place. An empty path addresses this value itself.
    ///
    /// Only the containers on the path are touched. A failed edit leaves the value as it was.
    mutating func apply(_ edit: AGUIEdit, at path: ArraySlice<String>) throws {
        guard let token = path.first else {
            switch edit {
            case .add(let value), .replace(let value): self = value
            case .remove: throw AGUIValueError("remove: the whole value cannot be removed")
            }
            return
        }
        switch self {
        case .object(var members):
            // Release this value's reference so the members are edited where they are.
            self = .null
            defer { self = .object(members) }
            try AGUIPatch.edit(&members, edit, at: path)
        case .array(var items):
            self = .null
            defer { self = .array(items) }
            if path.count == 1 {
                try AGUIPatch.edit(&items, edit, token: token) { $0 }
            } else {
                guard let index = AGUIPointer.index(token), index < items.count else {
                    throw AGUIValueError("\(edit.name): no array element \(token)")
                }
                try items[index].apply(edit, at: path.dropFirst())
            }
        default:
            throw AGUIValueError("\(edit.name): \(token) is below a value that has no members")
        }
    }
}
