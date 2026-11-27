import Foundation

// ACTIVITY RESULT
// What an opened Pretty line draws: a call's result read by its shape, never as raw JSON. Pure
// values; the views are in ActivityResultViews.swift. Spec: design/mockups/pretty-conversation.md,
// section E.
//
//   Values   OrderedJSON      JSON with its keys in the order sent, read as far as a cut text goes
//            PrettyJSON       the two-space, one-property-per-line form of JSON text
//            ResultPayload    a result unwrapped from MCP content and the network wrapper
//            ResultShape      which renderer a result selects, from its properties alone
//            ResultField      one labelled value of the generic renderer, with its value kind
//            SecretValues     which keys and values look like secrets, and their hidden form
//
// Nothing is inferred. A property the selected renderer does not place stays in `remaining`, and
// the exact text stays behind Source.

/// JSON that keeps key order. `AGUIValue` holds an object as a dictionary, so it cannot.
indirect enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The literal as sent, so a number is never reformatted.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    struct Member: Equatable, Sendable {
        let key: String
        let value: OrderedJSON
    }

    /// What reading a text gave: the value, and whether the text ended inside it.
    struct Reading: Equatable, Sendable {
        let value: OrderedJSON
        /// The text ended before the value closed. Whole members before the end are kept.
        let isCut: Bool
    }

    /// Reads `text` when it is a JSON object, list or string. A text that ends early is read as
    /// far as it goes and marked cut. Nil for any other text, and for JSON followed by more text.
    static func read(_ text: String) -> Reading? {
        var parser = Parser(text)
        parser.skipSpace()
        guard let first = parser.peek, first == "{" || first == "[" || first == "\"" else { return nil }
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipSpace()
        if !parser.isCut, parser.peek != nil { return nil }
        return Reading(value: value, isCut: parser.isCut)
    }

    subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var members: [Member]? { if case .object(let members) = self { members } else { nil } }
    var items: [OrderedJSON]? { if case .array(let items) = self { items } else { nil } }
    var string: String? { if case .string(let text) = self { text } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

    /// A scalar as short text: a string as it is, a number's literal, `true` or `false`.
    var scalarText: String? {
        switch self {
        case .string(let text): text
        case .number(let literal): literal
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    var isScalar: Bool {
        switch self {
        case .array, .object: false
        default: true
        }
    }

    /// Null, an empty string, an empty list or an empty object.
    var isEmpty: Bool {
        switch self {
        case .null: true
        case .string(let text): text.isEmpty
        case .array(let items): items.isEmpty
        case .object(let members): members.isEmpty
        default: false
        }
    }

    private struct Parser {
        private let scalars: [Unicode.Scalar]
        private var index = 0
        var isCut = false

        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        mutating func skipSpace() {
            while let scalar = peek, scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" { index += 1 }
        }

        mutating func value(depth: Int) -> OrderedJSON? {
            skipSpace()
            guard depth < 64, let first = peek else { isCut = true; return nil }
            switch first {
            case "{": return object(depth: depth)
            case "[": return array(depth: depth)
            case "\"": return string().map(OrderedJSON.string)
            default: return literal()
            }
        }

        private mutating func object(depth: Int) -> OrderedJSON? {
            index += 1
            var members: [Member] = []
            while true {
                skipSpace()
                guard let next = peek else { isCut = true; return .object(members) }
                if next == "}" { index += 1; return .object(members) }
                if next == "," { index += 1; continue }
                guard next == "\"", let key = string() else {
                    if isCut { return .object(members) }
                    return nil
                }
                skipSpace()
                guard peek == ":" else {
                    if peek == nil { isCut = true; return .object(members) }
                    return nil
                }
                index += 1
                guard let value = value(depth: depth + 1) else {
                    if isCut { return .object(members) }
                    return nil
                }
                members.append(Member(key: key, value: value))
                if isCut { return .object(members) }
            }
        }

        private mutating func array(depth: Int) -> OrderedJSON? {
            index += 1
            var items: [OrderedJSON] = []
            while true {
                skipSpace()
                guard let next = peek else { isCut = true; return .array(items) }
                if next == "]" { index += 1; return .array(items) }
                if next == "," { index += 1; continue }
                guard let value = value(depth: depth + 1) else {
                    if isCut { return .array(items) }
                    return nil
                }
                // An item the text ended inside, with nothing whole in it, is not an item.
                if isCut, value.isEmpty { return .array(items) }
                items.append(value)
                if isCut { return .array(items) }
            }
        }

        /// A string's text. A string the text ends inside is kept as far as it goes.
        private mutating func string() -> String? {
            index += 1
            var out = String.UnicodeScalarView()
            while let scalar = peek {
                index += 1
                if scalar == "\"" { return String(out) }
                guard scalar == "\\" else { out.append(scalar); continue }
                guard let escaped = peek else { break }
                index += 1
                switch escaped {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    guard let unit = hex4() else { isCut = true; return String(out) }
                    if (0xD800...0xDBFF).contains(unit), peek == "\\", index + 1 < scalars.count, scalars[index + 1] == "u" {
                        index += 2
                        if let low = hex4(), (0xDC00...0xDFFF).contains(low),
                           let joined = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) {
                            out.append(joined)
                        }
                    } else if let scalar = Unicode.Scalar(unit) {
                        out.append(scalar)
                    }
                default: out.append(escaped)
                }
            }
            isCut = true
            return String(out)
        }

        private mutating func hex4() -> UInt32? {
            guard index + 4 <= scalars.count else { index = scalars.count; return nil }
            let digits = String(String.UnicodeScalarView(scalars[index..<index + 4]))
            index += 4
            return UInt32(digits, radix: 16)
        }

        private mutating func literal() -> OrderedJSON? {
            let start = index
            while let scalar = peek, scalar != ",", scalar != "}", scalar != "]",
                  scalar != " ", scalar != "\n", scalar != "\t", scalar != "\r" { index += 1 }
            let word = String(String.UnicodeScalarView(scalars[start..<index]))
            switch word {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                if peek == nil, !word.isEmpty, "truefalsenull".contains(word) == false, Double(word) == nil {
                    isCut = true
                    return nil
                }
                return Double(word) == nil ? nil : .number(word)
            }
        }
    }
}

/// JSON text as Pretty shows it anywhere: two-space indent, one property per line, keys in the
/// order sent. A string that holds JSON stays a string. Copy always uses the original text.
enum PrettyJSON {
    struct Formatted: Equatable {
        let text: String
        let isJSON: Bool
        /// The JSON ended early. It is indented as far as it goes.
        var isCut = false
    }

    /// The service's marks on a shortened value: the console preview's and the stored record's.
    static let shortenedMarks = ["\n[Output shortened]", "…[shortened]"]

    static func format(_ source: String) -> Formatted {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var marked = false
        for mark in shortenedMarks where text.hasSuffix(mark.trimmingCharacters(in: .newlines)) {
            text = String(text.dropLast(mark.trimmingCharacters(in: .newlines).count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            marked = true
        }
        guard let first = text.first, first == "{" || first == "[", let reading = OrderedJSON.read(text) else {
            return Formatted(text: source, isJSON: false)
        }
        var out = ""
        write(reading.value, indent: 0, into: &out)
        return Formatted(text: out, isJSON: true, isCut: reading.isCut || marked)
    }

    static func write(_ value: OrderedJSON, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let literal): out += literal
        case .string(let text): out += quoted(text)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                write(item, indent: indent + 1, into: &out)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += pad + quoted(member.key) + ": "
                write(member.value, indent: indent + 1, into: &out)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// A result's data, read through what wraps it.
struct ResultPayload: Equatable {
    /// The data itself. Nil when the text is not JSON.
    let value: OrderedJSON?
    /// The network wrapper said `ok: false`, or carried a non-empty `error`.
    var wrapperError: String? = nil
    var isCut = false

    /// Step 1 of selection: an MCP content list, `structuredContent`, a JSON string, a code fence,
    /// then the network wrapper `{"ok":true,"data":…}`.
    static func read(_ text: String?) -> ResultPayload {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return ResultPayload(value: nil)
        }
        var marked = false
        for mark in PrettyJSON.shortenedMarks {
            let trimmedMark = mark.trimmingCharacters(in: .newlines)
            if text.hasSuffix(trimmedMark) {
                text = String(text.dropLast(trimmedMark.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                marked = true
            }
        }
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            var body = text.dropFirst(3).dropLast(3)
            if let newline = body.firstIndex(of: "\n") { body = body[body.index(after: newline)...] }
            text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let reading = OrderedJSON.read(text) else { return ResultPayload(value: nil) }
        var value = unwrap(reading.value, depth: 0)
        var error: String?
        if let members = value.members, let ok = value["ok"]?.bool, members.count <= 3 {
            if let message = value["error"]?.scalarText, !message.isEmpty { error = message }
            else if !ok { error = "The network reported a failure." }
            if let data = value["data"] { value = data }
        }
        return ResultPayload(value: value, wrapperError: error, isCut: reading.isCut || marked)
    }

    private static func unwrap(_ value: OrderedJSON, depth: Int) -> OrderedJSON {
        guard depth < 4 else { return value }
        func text(of parts: [OrderedJSON]) -> String? {
            guard !parts.isEmpty else { return nil }
            var texts: [String] = []
            for part in parts {
                guard part["type"]?.string == "text", let text = part["text"]?.string else { return nil }
                texts.append(text)
            }
            return texts.joined(separator: "\n")
        }
        func reread(_ text: String) -> OrderedJSON {
            guard let inner = OrderedJSON.read(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  inner.value.string == nil else { return .string(text) }
            return unwrap(inner.value, depth: depth + 1)
        }
        switch value {
        case .string(let text):
            let inner = reread(text)
            return inner.string == nil ? inner : value
        case .object:
            if let structured = value["structuredContent"], structured.members != nil {
                return unwrap(structured, depth: depth + 1)
            }
            if let parts = value["content"]?.items, let text = text(of: parts) { return reread(text) }
            return value
        case .array(let items):
            if let text = text(of: items) { return reread(text) }
            return value
        default:
            return value
        }
    }
}

/// Which renderer draws a result. Chosen from the tool and the result's own properties; a known
/// tool's renderer is used only when the properties it needs are there.
enum ResultShape: Equatable {
    case failure
    case workerCard
    case runRoster
    case questionCard
    case acknowledgement
    case report
    case operationReceipt
    case followUp
    case controlState
    /// A list of objects sharing most keys, under `key` (nil when the result is the list).
    case recordTable(key: String?)
    case messageList(key: String?)
    case textFile
    case change
    case terminal
    case searchResults
    case webResults
    case checklist(key: String?)
    case generic
    /// Text that is not data: shown quoted, as sent.
    case text
    /// Nothing to draw but a sentence.
    case empty(String)

    struct Selection: Equatable {
        let shape: ResultShape
        /// Top-level properties the renderer places, in the order it shows them.
        var placed: [String] = []
        /// Every other top-level property, in the order sent. Drawn under "More fields".
        var remaining: [String] = []
    }

    /// Steps 2 to 5. `payload` is step 1.
    static func select(tool: String, payload: ResultPayload, resultText: String?, failed: Bool) -> Selection {
        if failed || payload.wrapperError != nil { return Selection(shape: .failure) }
        let commander = CommanderTool(name: tool)
        let provider = ProviderTool(name: tool)
        let text = resultText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let value = payload.value else {
            // Text results: a provider tool names its renderer; anything else is quoted as sent.
            switch provider?.kind {
            case .read?: return Selection(shape: text.isEmpty ? .empty("The file is empty.") : .textFile)
            case .edit?, .write?: return Selection(shape: text.isEmpty ? .empty("The provider sent no diff for this edit.") : .change)
            case .shell?: return Selection(shape: text.isEmpty ? .empty("The command printed nothing.") : .terminal)
            case .search?: return Selection(shape: text.isEmpty ? .empty("Nothing matched.") : .searchResults)
            case .web?: return Selection(shape: text.isEmpty ? .empty("No results.") : .webResults)
            case nil: break
            }
            if commander == .callFrontend || commander == .callTool, text.isEmpty {
                return Selection(shape: .empty("The tool returned nothing."))
            }
            return Selection(shape: text.isEmpty ? .empty("Empty result.") : .text)
        }
        if case .string(let inner) = value {
            return Selection(shape: inner.isEmpty ? .empty("Empty result.") : .text)
        }
        func place(_ shape: ResultShape, _ keys: [String]) -> Selection {
            let all = value.members?.map(\.key) ?? []
            let placed = keys.filter { all.contains($0) }
            return Selection(shape: shape, placed: placed, remaining: all.filter { !placed.contains($0) })
        }
        func has(_ keys: String...) -> Bool { keys.allSatisfy { value[$0] != nil } }
        func list(_ key: String) -> [OrderedJSON]? { value[key]?.items }

        // Step 3: the tool's own empty sentences and renderers, when its properties are there.
        if let commander {
            let emptyLists: [(CommanderTool, [String], String)] = [
                (.listTools, ["tools"], "No extensions are granted."),
                (.frontendTools, ["tools"], "No app tools."),
                (.networkOnline, ["friends", "contacts"], "The contact list is empty."),
                (.networkBoard, ["workspaces"], "No workspaces."),
                (.networkInbox, ["messages"], "No messages."),
                (.networkDiscover, ["resources", "peers"], "No shared resources."),
            ]
            for (tool, keys, sentence) in emptyLists where tool == commander {
                for key in keys {
                    guard let items = list(key) else { continue }
                    if items.isEmpty, value.members?.count == 1 { return Selection(shape: .empty(sentence)) }
                    if commander == .networkInbox { return place(.messageList(key: key), [key]) }
                    if uniform(items) { return place(.recordTable(key: key), [key]) }
                }
                if let items = value.items {
                    if items.isEmpty { return Selection(shape: .empty(sentence)) }
                    if uniform(items) { return Selection(shape: .recordTable(key: nil)) }
                }
            }
            if commander == .result, has("id", "result") { return place(.report, ["id", "result"]) }
        }
        // Step 4: the first matching shape, whatever the tool.
        if has("workers", "status"), list("workers") != nil {
            return place(.runRoster, ["project", "status", "path", "task", "workers", "requests", "integrations"])
        }
        if has("role", "state", "task") {
            return place(.workerCard, ["name", "role", "state", "task", "host", "client", "worktree", "branch",
                                       "created_at", "result", "error"])
        }
        if has("question", "status") {
            return place(.questionCard, ["question", "status", "answer", "worker_id", "delivery", "choices"])
        }
        if has("text", "status", "generation") {
            return place(.followUp, ["text", "status", "stop_reason"])
        }
        if has("held", "generation") {
            return place(.controlState, ["interrupt", "held", "interrupt_requested", "messages"])
        }
        if has("id"), value["status"] != nil || value["candidate"] != nil,
           ["children", "recipients", "targets", "results", "outcomes", "candidate"].contains(where: { value[$0] != nil }) {
            return place(.operationReceipt, ["id", "status", "children", "recipients", "targets", "results", "outcomes",
                                             "workers", "revisions", "target", "candidate"])
        }
        if let items = value.items {
            if items.isEmpty { return Selection(shape: .empty("Empty result.")) }
            if checklist(items) { return Selection(shape: .checklist(key: nil)) }
            if messages(items) { return Selection(shape: .messageList(key: nil)) }
            if uniform(items) { return Selection(shape: .recordTable(key: nil)) }
            return Selection(shape: .generic)
        }
        guard let members = value.members else { return Selection(shape: .generic) }
        if members.isEmpty { return Selection(shape: .empty("Empty result.")) }
        // One list under one key: a checklist, messages or a table.
        let lists = members.filter { $0.value.items != nil }
        if lists.count == 1, let items = lists[0].value.items, !items.isEmpty {
            let key = lists[0].key
            if checklist(items) { return place(.checklist(key: key), [key]) }
            if messages(items) { return place(.messageList(key: key), [key]) }
            if uniform(items), members.count <= 4 { return place(.recordTable(key: key), [key]) }
        }
        if members.count <= 3, members.allSatisfy({ $0.value.isScalar }) {
            return place(.acknowledgement, members.map(\.key))
        }
        return Selection(shape: .generic, remaining: [])
    }

    /// Objects that share most keys: every item is an object and each holds more than half of
    /// the first item's keys.
    static func uniform(_ items: [OrderedJSON]) -> Bool {
        guard let first = items.first?.members?.map(\.key), !first.isEmpty else { return false }
        return items.allSatisfy { item in
            guard let keys = item.members?.map(\.key) else { return false }
            return keys.filter { first.contains($0) }.count * 2 > first.count
        }
    }

    static func checklist(_ items: [OrderedJSON]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0["content"]?.string != nil && $0["status"]?.string != nil }
    }

    static func messages(_ items: [OrderedJSON]) -> Bool {
        !items.isEmpty && items.allSatisfy { item in
            item["text"]?.string != nil
                && ["peer", "sender", "from", "author", "receivedAt", "received_at", "time", "at"].contains { item[$0] != nil }
        }
    }
}

/// One labelled value of the generic renderer.
struct ResultField: Identifiable, Equatable {
    enum Kind: Equatable {
        case status, yesNo, empty, id, path, time, link, number, text, longText
        case scalarList, table, object, secret
    }

    /// The exact key, for help and Source.
    let key: String
    /// Sentence case from the key: `created_at` reads "Created at".
    let label: String
    let kind: Kind
    let value: OrderedJSON
    var id: String { key }

    static let statusKeys: Set<String> = ["state", "status", "phase", "outcome", "presence", "delivery"]

    init(key: String, value: OrderedJSON) {
        self.key = key
        self.value = value
        label = Self.label(key)
        kind = Self.kind(key: key, value: value)
    }

    static func rows(_ value: OrderedJSON, keys: [String]? = nil) -> [ResultField] {
        guard let members = value.members else { return [] }
        if let keys { return keys.compactMap { key in value[key].map { ResultField(key: key, value: $0) } } }
        return members.map { ResultField(key: $0.key, value: $0.value) }
    }

    static func label(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for character in key {
            if character == "_" || character == "-" || character == "." {
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        let text = words.enumerated().map { index, word -> String in
            let lower = word.lowercased()
            if lower == "id" { return "ID" }
            if lower == "url" { return "URL" }
            return index == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
        }.joined(separator: " ")
        return text.isEmpty ? key : text
    }

    static func kind(key: String, value: OrderedJSON) -> Kind {
        if value.isEmpty { return .empty }
        if SecretValues.looksSecret(key: key, value: value) { return .secret }
        switch value {
        case .bool: return .yesNo
        case .number: return .number
        case .object: return .object
        case .array(let items):
            if items.allSatisfy(\.isScalar) { return .scalarList }
            return .table
        case .string(let text):
            let lower = key.lowercased()
            if statusKeys.contains(lower) { return .status }
            if lower == "id" || lower.hasSuffix("_id") || key.hasSuffix("Id") || isIdentifier(text) { return .id }
            if text.count > 280 || text.contains("\n") { return .longText }
            if text.hasPrefix("http://") || text.hasPrefix("https://") { return .link }
            if text.hasPrefix("/") || text.hasPrefix("~/"), !text.contains(" ") { return .path }
            if isTime(text) { return .time }
            return .text
        case .null: return .empty
        }
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard text.count >= 10, !text.contains(" ") else { return false }
        return text.hasPrefix("w-") || text.hasPrefix("r-") || text.hasPrefix("toolu_")
    }

    static func isTime(_ text: String) -> Bool { date(text) != nil }

    static func date(_ text: String) -> Date? {
        guard text.count >= 20, text.count <= 35, text.contains("T") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// A status word as shown: as sent, capitalised, underscores as spaces.
    static func statusWord(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// Keys and values that look like secrets. Applied only when the transcript setting asks for it,
/// and only when a value is drawn: the stored record is never changed.
enum SecretValues {
    static let keyWords = ["token", "secret", "password", "authorization", "cookie", "credential", "api_key",
                           "apikey", "private_key"]

    static func looksSecret(key: String, value: OrderedJSON) -> Bool {
        guard let text = value.string, !text.isEmpty else { return false }
        return keyLooksSecret(key) || valueLooksSecret(text)
    }

    static func keyLooksSecret(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower == "idempotency_key" || lower == "idempotencykey" { return false }
        return keyWords.contains { lower.contains($0) }
    }

    static func valueLooksSecret(_ text: String) -> Bool {
        if text.hasPrefix("Bearer ") && text.count > 15 { return true }
        if text.hasPrefix("sk-") && text.count >= 20 && !text.contains(" ") { return true }
        // A JWT: three base64url parts, the first two starting `eyJ`.
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].hasPrefix("eyJ") && parts[1].hasPrefix("eyJ") && !text.contains(" ")
    }

    static func hidden(_ text: String) -> String {
        text.count == 1 ? "Hidden, 1 character" : "Hidden, \(text.count) characters"
    }

    /// `value` with every secret-looking string replaced by its hidden form, at any depth.
    static func masked(_ value: OrderedJSON, key: String = "") -> OrderedJSON {
        switch value {
        case .string(let text):
            return looksSecret(key: key, value: value) ? .string(hidden(text)) : value
        case .array(let items):
            return .array(items.map { masked($0, key: key) })
        case .object(let members):
            return .object(members.map { OrderedJSON.Member(key: $0.key, value: masked($0.value, key: $0.key)) })
        default:
            return value
        }
    }

    /// Text for Source with secrets hidden: JSON is masked by key and value; other text has its
    /// `Bearer …`, `sk-…` and JWT words replaced. `count` is how many values were hidden.
    static func masked(text: String) -> (text: String, count: Int) {
        if let reading = OrderedJSON.read(text.trimmingCharacters(in: .whitespacesAndNewlines)), reading.value.string == nil {
            let masked = masked(reading.value)
            guard masked != reading.value else { return (text, 0) }
            var out = ""
            PrettyJSON.write(masked, indent: 0, into: &out)
            return (out, count(reading.value))
        }
        var hiddenCount = 0
        var previousWasBearer = false
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let plain = String(word)
            defer { previousWasBearer = plain == "Bearer" }
            if previousWasBearer, plain.count > 8 || valueLooksSecret(plain) {
                hiddenCount += 1
                return hidden(plain)
            }
            if valueLooksSecret(plain) { hiddenCount += 1; return hidden(plain) }
            return plain
        }
        return hiddenCount == 0 ? (text, 0) : (words.joined(separator: " "), hiddenCount)
    }

    /// Prose with secrets hidden: a job's exit summary, a failure's reason, a description. Whole
    /// JSON is masked as Source masks it. Other text is read word by word, across lines: a
    /// `Bearer …`, `sk-…` or JWT word, and the value joined to a secret-looking key
    /// (`API_TOKEN=…`, `--password=…`, `"token":"…"`). Quotes, brackets and sentence punctuation
    /// around a word are kept. Mask before cutting a sentence out of the text: a cut secret no
    /// longer looks like one. `count` is how many values were hidden.
    static func masked(prose text: String) -> (text: String, count: Int) {
        if let reading = OrderedJSON.read(text.trimmingCharacters(in: .whitespacesAndNewlines)), reading.value.string == nil {
            return masked(text: text)
        }
        var out = ""
        var hiddenCount = 0
        var previousWasBearer = false
        var index = text.startIndex
        while index < text.endIndex {
            let isSpace = text[index].isWhitespace
            let end = text[index...].firstIndex { $0.isWhitespace != isSpace } ?? text.endIndex
            let run = text[index..<end]
            index = end
            guard !isSpace else { out += run; continue }
            let core = run.drop { opening.contains($0) }
            let lead = run[run.startIndex..<core.startIndex]
            var word = core
            while let last = word.last, closing.contains(last) { word = word.dropLast() }
            let trail = core[word.endIndex...]
            let wasBearer = previousWasBearer
            previousWasBearer = word.lowercased() == "bearer"
            if !word.isEmpty, valueLooksSecret(String(word)) || (wasBearer && word.count > 8) {
                hiddenCount += 1
                out += lead
                out += hidden(String(word))
                out += trail
            } else if let value = keyedValue(in: word) {
                hiddenCount += 1
                out += lead
                out += word[..<value.lowerBound]
                out += hidden(String(word[value]))
                out += word[value.upperBound...]
                out += trail
            } else {
                out += run
            }
        }
        return hiddenCount == 0 ? (text, 0) : (out, hiddenCount)
    }

    private static let quotes: Set<Character> = ["\"", "'", "`"]
    private static let opening: Set<Character> = quotes.union(["(", "[", "{", "<"])
    private static let closing: Set<Character> = quotes.union([")", "]", "}", ">", ".", ",", ";", ":", "!", "?"])

    /// The value joined to a secret-looking key inside one word: what follows `=` or `:`, without
    /// its quotes. Nil when the word holds no such key, or the key has no value.
    private static func keyedValue(in word: Substring) -> Range<Substring.Index>? {
        for at in word.indices where word[at] == "=" || word[at] == ":" {
            var keyEnd = at
            while keyEnd > word.startIndex, quotes.contains(word[word.index(before: keyEnd)]) { keyEnd = word.index(before: keyEnd) }
            var keyStart = keyEnd
            while keyStart > word.startIndex {
                let before = word.index(before: keyStart)
                guard word[before].isLetter || word[before].isNumber || word[before] == "_" || word[before] == "-" else { break }
                keyStart = before
            }
            guard keyStart < keyEnd, keyLooksSecret(String(word[keyStart..<keyEnd])) else { continue }
            var from = word.index(after: at), to = word.endIndex
            while from < to, quotes.contains(word[from]) { from = word.index(after: from) }
            while to > from, quotes.contains(word[word.index(before: to)]) { to = word.index(before: to) }
            if from < to { return from..<to }
        }
        return nil
    }

    private static func count(_ value: OrderedJSON, key: String = "") -> Int {
        switch value {
        case .string: looksSecret(key: key, value: value) ? 1 : 0
        case .array(let items): items.reduce(0) { $0 + count($1, key: key) }
        case .object(let members): members.reduce(0) { $0 + count($1.value, key: $1.key) }
        default: 0
        }
    }
}
