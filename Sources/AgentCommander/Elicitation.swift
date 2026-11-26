import AppKit
import Observation
import SwiftUI

// ELICITATION
// Structured requests an ACP agent puts to the owner of a worker: a form to fill in, or a web
// address to open. The owner answers each one from the worker's action list.
//
//   Values          Elicitation                  GET  /v1/workers/{worker}/elicitations
//                   ElicitationSchema            the typed fields of a form request
//                   ElicitationDraft             the owner's values for one form, keyed by field
//                   ElicitationLink              a URL request's address, host and open rule
//                   ElicitationReply             POST /v1/workers/{worker}/elicitations/{id}/reply
//                   ElicitationInspection        what the panel draws for the one open worker
//   Feature layer   ElicitationModel             scope, reads while open, drafts, replies, open
//                   ElicitationIntents           the operations the cockpit emits
//   Molecules       ElicitationFieldControl      one typed form field: text, number, switch, menu,
//                                                checkboxes for a list of choices
//                   ElicitationLinkView          the full address with its host marked
//                   ElicitationDecisionBar       accept, decline and cancel for one request
//   Organisms       ElicitationCard              one request
//                   ElicitationPanel             every request in the worker's scope
//                   ElicitationPresentation      presents the panel beside the worker's actions
//
// The model checks scope: a request is shown and answered only when the service names the open
// worker and that worker's own bound provider session. Every reply names the worker and a request
// the panel has read. A form's values are sent exactly as entered; numbers keep the literal typed.
// Commander never fetches a request's address and never opens a browser by itself: the owner
// chooses to open it and confirms, and only an http or https address whose host is the one the
// service checked is opened. A 404 or 409 reply means the request was withdrawn.

// MARK: - Values

/// The owner's decision on one request.
enum ElicitationAction: String, Equatable, Sendable {
    case accept, decline, cancel

    var pastTense: String {
        switch self {
        case .accept: "Accepted"
        case .decline: "Declined"
        case .cancel: "Cancelled"
        }
    }
}

/// A request's provider session scope: the worker the panel is open for and the session the
/// service has bound it to. Only requests naming both are shown or answered.
struct ElicitationScope: Hashable, Sendable {
    let workerID: String
    let session: NativeSession

    func contains(_ elicitation: Elicitation) -> Bool {
        !workerID.isEmpty && elicitation.workerID == workerID && elicitation.session == session
    }
}

/// One structured request, as `GET /v1/workers/{worker}/elicitations` reports it.
struct Elicitation: Identifiable, Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case form, url
        /// A kind this version does not know, kept as sent. It can be declined or cancelled.
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "form": self = .form
            case "url": self = .url
            default: self = .other(raw)
            }
        }
    }

    enum Status: Equatable, Sendable {
        case pending
        /// A URL request the owner accepted, kept until the agent reports completion.
        case accepted
        case declined, cancelled, completed
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "pending": self = .pending
            case "accept": self = .accepted
            case "decline": self = .declined
            case "cancel": self = .cancelled
            case "completed": self = .completed
            default: self = .other(raw)
            }
        }

        var label: String {
            switch self {
            case .pending: "Waiting for you"
            case .accepted: "Accepted"
            case .declined: "Declined"
            case .cancelled: "Cancelled"
            case .completed: "Completed"
            case .other(let raw): raw.isEmpty ? "Unknown" : raw
            }
        }

        var tone: Tone {
            switch self {
            case .pending: .attention
            case .accepted, .completed: .working
            case .declined, .cancelled, .other: .neutral
            }
        }
    }

    let id: String
    let workerID: String
    let session: NativeSession
    let status: Status
    /// The agent's own ACP session ID, for provenance.
    let nativeSessionID: String
    let mode: Mode
    let message: String
    let toolCallID: String?
    /// The form's JSON Schema, as sent. Nil for a URL request.
    let requestedSchema: AGUIValue?
    /// The agent's opaque ID for a URL request.
    let elicitationID: String?
    /// The full address of a URL request.
    let url: String?
    /// The host the service read from `url`.
    let urlHost: String?
    let punycode: Bool

    init(id: String, workerID: String, session: NativeSession, status: Status = .pending,
         nativeSessionID: String = "", mode: Mode, message: String, toolCallID: String? = nil,
         requestedSchema: AGUIValue? = nil, elicitationID: String? = nil, url: String? = nil,
         urlHost: String? = nil, punycode: Bool = false) {
        self.id = id
        self.workerID = workerID
        self.session = session
        self.status = status
        self.nativeSessionID = nativeSessionID
        self.mode = mode
        self.message = message
        self.toolCallID = toolCallID
        self.requestedSchema = requestedSchema
        self.elicitationID = elicitationID
        self.url = url
        self.urlHost = urlHost
        self.punycode = punycode
    }

    /// Nil for an entry without an ID, which could not be answered.
    init?(projection value: AGUIValue) {
        guard let id = value["id"]?.stringValue, !id.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            value[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(id: id,
                  workerID: value["worker_id"]?.stringValue ?? "",
                  session: value["session"].map { NativeSession(projection: $0) }
                      ?? NativeSession(harnessInstance: "", sessionID: ""),
                  status: Status(value["status"]?.stringValue ?? ""),
                  nativeSessionID: value["sessionId"]?.stringValue ?? "",
                  mode: Mode(value["mode"]?.stringValue ?? ""),
                  message: value["message"]?.stringValue ?? "",
                  toolCallID: text("toolCallId"),
                  requestedSchema: value["requestedSchema"].flatMap { $0.isNull ? nil : $0 },
                  elicitationID: text("elicitationId"),
                  url: text("url"),
                  urlHost: text("url_host"),
                  punycode: value["punycode"]?.boolValue ?? false)
    }

    /// Reads the service's list. Entries without an ID are left out.
    static func list(json data: Data) throws -> [Elicitation] {
        let unreadable = ServiceError.rejected("The service returned an unreadable list of requests.")
        guard let value = try? AGUIValue(json: data), let object = value.objectValue else { throw unreadable }
        guard let items = object["elicitations"], !items.isNull else { return [] }
        guard let array = items.arrayValue else { throw unreadable }
        return array.compactMap { Elicitation(projection: $0) }
    }

    var schema: ElicitationSchema { ElicitationSchema(requestedSchema) }

    /// The address of a URL request. Nil for a form or a URL request without an address.
    var link: ElicitationLink? {
        guard mode == .url, let url else { return nil }
        return ElicitationLink(text: url, host: urlHost ?? "", punycode: punycode)
    }
}

/// A value the owner entered for one field. A number keeps the text typed, so the literal is sent.
enum ElicitationValue: Equatable, Sendable {
    case text(String)
    case flag(Bool)
    case choice(String)
    /// The chosen values of a list of text choices, in the order chosen, each exactly as listed.
    case list([String])
}

/// The owner's values for one form, by field name. A field without a value is left out.
struct ElicitationDraft: Equatable, Sendable {
    var values: [String: ElicitationValue] = [:]

    init(values: [String: ElicitationValue] = [:]) {
        self.values = values
    }

    /// A draft holding the schema's defaults.
    init(defaultsOf schema: ElicitationSchema) {
        var values = [String: ElicitationValue]()
        for field in schema.fields {
            if let value = field.defaultValue { values[field.name] = value }
        }
        self.values = values
    }
}

/// Why a form cannot be sent yet, by field name.
struct ElicitationFormError: LocalizedError, Equatable {
    let problems: [String: String]

    var errorDescription: String? {
        problems.count == 1 ? "One field needs attention." : "\(problems.count) fields need attention."
    }
}

/// The typed fields of a form request. Commander answers a flat object of text, number, integer,
/// boolean, text-choice and list-of-text-choice fields. Anything else is explained and never
/// guessed at; the service validates the answer against the schema.
struct ElicitationSchema: Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let value: String
        let title: String
        var id: String { value }
    }

    enum Kind: Equatable, Sendable {
        /// Free text. `format` is the schema's hint, such as `email` or `date`.
        case text(format: String?)
        case boolean
        case number(integer: Bool)
        /// One of the listed text values.
        case choice([Option])
        /// Any number of the listed text values, each at most once, within the schema's
        /// `minItems` and `maxItems` when it sets them.
        case multiChoice([Option], minItems: Int?, maxItems: Int?)
        /// A shape Commander does not answer, with the reason in words.
        case unsupported(String)
    }

    struct Field: Identifiable, Equatable, Sendable {
        let name: String
        let title: String
        let detail: String?
        let isRequired: Bool
        let kind: Kind
        let defaultValue: ElicitationValue?
        /// The format or bounds, in words.
        let hint: String?

        var id: String { name }

        var unsupportedReason: String? {
            if case .unsupported(let reason) = kind { return reason }
            return nil
        }
    }

    /// Required fields in the schema's `required` order, then the others by name.
    let fields: [Field]
    /// Why the form as a whole cannot be answered here. Nil when it can.
    let unsupportedReason: String?

    init(fields: [Field], unsupportedReason: String? = nil) {
        self.fields = fields
        self.unsupportedReason = unsupportedReason
    }

    init(_ value: AGUIValue?) {
        let parsed = Self.parse(value)
        self.init(fields: parsed.fields, unsupportedReason: parsed.reason)
    }

    /// Why Accept is not offered: the form cannot be read, or a required field cannot be
    /// answered here. Decline and cancel stay available.
    var acceptUnavailableReason: String? {
        if let unsupportedReason { return unsupportedReason + " Decline or cancel it instead." }
        if let field = fields.first(where: { $0.isRequired && $0.unsupportedReason != nil }) {
            return "“\(field.title)” is required and cannot be answered here. Decline or cancel it instead."
        }
        return nil
    }

    /// The `content` object for an accepted form. Text is sent exactly as entered; a number is sent
    /// as the literal typed, without surrounding spaces. An empty optional field is left out.
    func content(from draft: ElicitationDraft) -> Result<AGUIValue, ElicitationFormError> {
        var content = [String: AGUIValue]()
        var problems = [String: String]()
        for field in fields {
            let value = draft.values[field.name]
            switch field.kind {
            case .unsupported:
                if field.isRequired { problems[field.name] = "This field cannot be answered here." }
            case .text:
                guard case .text(let text)? = value, !text.isEmpty else {
                    if field.isRequired { problems[field.name] = "Required." }
                    continue
                }
                content[field.name] = .string(text)
            case .number(let integer):
                var literal = ""
                if case .text(let text)? = value { literal = text.trimmingCharacters(in: .whitespaces) }
                guard !literal.isEmpty else {
                    if field.isRequired { problems[field.name] = "Required." }
                    continue
                }
                if integer, !Self.isIntegerLiteral(literal) {
                    problems[field.name] = "Enter a whole number, such as 42."
                    continue
                }
                guard let number = AGUINumber(literal: literal) else {
                    problems[field.name] = "Enter a number, such as 42 or 2.5."
                    continue
                }
                content[field.name] = .number(number)
            case .boolean:
                guard case .flag(let flag)? = value else {
                    if field.isRequired { problems[field.name] = "Choose on or off." }
                    continue
                }
                content[field.name] = .bool(flag)
            case .choice(let options):
                guard case .choice(let choice)? = value, options.contains(where: { $0.value == choice }) else {
                    if field.isRequired { problems[field.name] = "Choose one." }
                    continue
                }
                content[field.name] = .string(choice)
            case .multiChoice(let options, let minItems, let maxItems):
                // A required list with nothing chosen is the empty list the owner sees; an optional
                // one without a value is left out.
                let selections: [String]
                if case .list(let list)? = value {
                    selections = list
                } else if value == nil && field.isRequired {
                    selections = []
                } else {
                    if field.isRequired { problems[field.name] = "Choose from the list." }
                    continue
                }
                if let problem = Self.listProblem(selections, options: options, minItems: minItems, maxItems: maxItems) {
                    problems[field.name] = problem
                    continue
                }
                content[field.name] = .array(selections.map(AGUIValue.string))
            }
        }
        return problems.isEmpty ? .success(.object(content)) : .failure(ElicitationFormError(problems: problems))
    }

    /// A JSON integer literal: an optional minus and digits without a leading zero.
    static func isIntegerLiteral(_ text: String) -> Bool {
        var digits = Substring(text)
        if digits.first == "-" { digits = digits.dropFirst() }
        guard let first = digits.first, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return first != "0" || digits.count == 1
    }

    /// Why a list's selections cannot be sent: an unlisted or repeated value, or a count outside
    /// the schema's bounds. Nil when they can.
    static func listProblem(_ selections: [String], options: [Option], minItems: Int?, maxItems: Int?) -> String? {
        let known = Set(options.map(\.value))
        if selections.contains(where: { !known.contains($0) }) { return "Choose only the listed options." }
        if Set(selections).count != selections.count { return "Choose each option once." }
        if let minItems, selections.count < minItems { return "Choose at least \(minItems)." }
        if let maxItems, selections.count > maxItems { return "Choose at most \(maxItems)." }
        return nil
    }

    // MARK: Parsing

    private static func parse(_ value: AGUIValue?) -> (fields: [Field], reason: String?) {
        guard let value, !value.isNull else { return ([], "The agent sent no form to fill in.") }
        guard let object = value.objectValue else { return ([], "The form is not described as an object.") }
        if let type = object["type"], type.stringValue != "object" {
            return ([], "The form is not a flat set of fields.")
        }
        let properties: [String: AGUIValue]
        switch object["properties"] {
        case nil, .null?: properties = [:]
        case .object(let members)?: properties = members
        default: return ([], "The form's fields cannot be read.")
        }
        let required = (object["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        var order = [String]()
        for name in required where properties[name] != nil && !order.contains(name) { order.append(name) }
        order += properties.keys.filter { !order.contains($0) }.sorted()
        let requiredNames = Set(required)
        let fields = order.compactMap { name in
            properties[name].map { Self.field(name, $0, required: requiredNames.contains(name)) }
        }
        return (fields, nil)
    }

    private static func field(_ name: String, _ spec: AGUIValue, required: Bool) -> Field {
        let kind = Self.kind(of: spec)
        return Field(name: name,
                     title: spec["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? name,
                     detail: spec["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                     isRequired: required,
                     kind: kind,
                     defaultValue: Self.defaultValue(spec["default"], kind: kind),
                     hint: Self.hint(spec, kind: kind))
    }

    private static func kind(of spec: AGUIValue) -> Kind {
        guard spec.objectValue != nil else { return .unsupported("This field is not described in a way Commander can read.") }
        if let values = spec["enum"] {
            guard let items = values.arrayValue, !items.isEmpty else { return .unsupported("This choice offers no options.") }
            let strings = items.compactMap(\.stringValue)
            guard strings.count == items.count else { return .unsupported("Only text choices can be answered here.") }
            let names = spec["enumNames"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let titles = names.count == strings.count ? names : strings
            return Self.choice(zip(strings, titles).map { Option(value: $0, title: $1) })
        }
        for key in ["oneOf", "anyOf"] {
            guard let items = spec[key]?.arrayValue else { continue }
            let options = items.compactMap { item -> Option? in
                guard let value = item["const"]?.stringValue else { return nil }
                return Option(value: value, title: item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? value)
            }
            guard !items.isEmpty, options.count == items.count else {
                return .unsupported("Only text choices can be answered here.")
            }
            return Self.choice(options)
        }
        switch spec["type"]?.stringValue {
        case "string"?: return .text(format: spec["format"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        case "boolean"?: return .boolean
        case "number"?: return .number(integer: false)
        case "integer"?: return .number(integer: true)
        case "array"?: return Self.list(spec)
        case "object"?: return .unsupported("Nested fields cannot be answered here.")
        case let other?: return .unsupported("A “\(other)” field cannot be answered here.")
        case nil: return .unsupported("This field does not say what kind of value it takes.")
        }
    }

    private static func choice(_ options: [Option]) -> Kind {
        Set(options.map(\.value)).count == options.count
            ? .choice(options) : .unsupported("This choice repeats an option.")
    }

    /// A list whose `items` enumerate text values: `enum` with an optional `"type": "string"`, or
    /// MCP's titled `anyOf` of `const` and `title` without an item type. Any other item shape is
    /// explained, as are bounds that are not whole numbers or cannot be met.
    private static func list(_ spec: AGUIValue) -> Kind {
        let textOnly = Kind.unsupported("Only a list of text choices can be answered here.")
        guard let items = spec["items"], items.objectValue != nil else {
            return .unsupported("A list of several choices cannot be answered here.")
        }
        guard items["oneOf"] == nil, (items["enum"] == nil) != (items["anyOf"] == nil) else { return textOnly }
        var options = [Option]()
        if let values = items["enum"] {
            if let type = items["type"], type.stringValue != "string" { return textOnly }
            guard let array = values.arrayValue, !array.isEmpty else { return .unsupported("This list offers no options.") }
            let strings = array.compactMap(\.stringValue)
            guard strings.count == array.count else { return textOnly }
            let names = items["enumNames"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let titles = names.count == strings.count ? names : strings
            options = zip(strings, titles).map { Option(value: $0, title: $1) }
        } else if let alternatives = items["anyOf"] {
            guard items["type"] == nil, let array = alternatives.arrayValue, !array.isEmpty else { return textOnly }
            options = array.compactMap { item -> Option? in
                guard let value = item["const"]?.stringValue else { return nil }
                return Option(value: value, title: item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? value)
            }
            guard options.count == array.count else { return textOnly }
        }
        guard Set(options.map(\.value)).count == options.count else { return .unsupported("This list repeats an option.") }
        let unreadable = Kind.unsupported("This list's size limits cannot be read.")
        func bound(_ key: String) -> Int?? {
            guard let value = spec[key] else { return .some(nil) }
            guard let literal = value.numberValue?.literal, isIntegerLiteral(literal),
                  let count = Int(literal), count >= 0 else { return nil }
            return .some(count)
        }
        guard let minItems = bound("minItems"), let maxItems = bound("maxItems") else { return unreadable }
        if let minItems, let maxItems, minItems > maxItems { return unreadable }
        if let minItems, minItems > options.count {
            return .unsupported("This list asks for more choices than it offers.")
        }
        return .multiChoice(options, minItems: minItems, maxItems: maxItems)
    }

    private static func defaultValue(_ value: AGUIValue?, kind: Kind) -> ElicitationValue? {
        guard let value else { return nil }
        switch (kind, value) {
        case (.text, .string(let text)):
            return .text(text)
        case (.number(let integer), .number(let number)):
            return !integer || isIntegerLiteral(number.literal) ? .text(number.literal) : nil
        case (.boolean, .bool(let flag)):
            return .flag(flag)
        case (.choice(let options), .string(let choice)):
            return options.contains(where: { $0.value == choice }) ? .choice(choice) : nil
        case (.multiChoice(let options, let minItems, let maxItems), .array(let items)):
            // Kept exactly and in order, and only when it could be sent as it stands.
            let strings = items.compactMap(\.stringValue)
            guard strings.count == items.count,
                  listProblem(strings, options: options, minItems: minItems, maxItems: maxItems) == nil else { return nil }
            return .list(strings)
        default:
            return nil
        }
    }

    private static func hint(_ spec: AGUIValue, kind: Kind) -> String? {
        switch kind {
        case .text(let format):
            var parts = [String]()
            if let format { parts.append(formatLabel(format)) }
            switch (spec["minLength"]?.intValue, spec["maxLength"]?.intValue) {
            case let (low?, high?): parts.append("\(low)–\(high) characters")
            case let (low?, nil): parts.append("at least \(low) characters")
            case let (nil, high?): parts.append("up to \(high) characters")
            default: break
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .number(let integer):
            var parts = [integer ? "whole number" : "number"]
            switch (spec["minimum"]?.numberValue?.literal, spec["maximum"]?.numberValue?.literal) {
            case let (low?, high?): parts.append("\(low) to \(high)")
            case let (low?, nil): parts.append("at least \(low)")
            case let (nil, high?): parts.append("at most \(high)")
            default: break
            }
            return parts.joined(separator: " · ")
        case .multiChoice(_, let low, let high):
            switch (low, high) {
            case let (low?, high?) where low == high: return "choose \(low)"
            case let (low?, high?) where low > 0: return "choose \(low)–\(high)"
            case let (low?, nil) where low > 0: return "choose at least \(low)"
            case let (_, high?): return "choose up to \(high)"
            default: return "choose any"
            }
        case .boolean, .choice, .unsupported:
            return nil
        }
    }

    private static func formatLabel(_ format: String) -> String {
        switch format {
        case "email": "email address"
        case "uri": "web address, not opened"
        case "date": "date, YYYY-MM-DD"
        case "date-time": "date and time, ISO 8601"
        default: format
        }
    }
}

/// The address of a URL request and the rule for opening it. Commander shows the whole address
/// with the checked host marked, and opens it only when the owner asks, only over http or https,
/// and only when its host is the one the service checked.
struct ElicitationLink: Equatable, Sendable {
    let text: String
    let host: String
    /// The service marked the host as punycode, or one of its labels starts with `xn--`.
    let isPunycode: Bool

    init(text: String, host: String, punycode: Bool) {
        self.text = text
        self.host = host
        isPunycode = punycode || host.lowercased().split(separator: ".").contains { $0.hasPrefix("xn--") }
    }

    /// The whole host within the address's authority, after any user information.
    var hostRange: Range<String.Index>? {
        guard !host.isEmpty, let scheme = text.range(of: "://") else { return nil }
        let end = text[scheme.upperBound...].firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        let start = text[scheme.upperBound..<end].lastIndex(of: "@").map { text.index(after: $0) } ?? scheme.upperBound
        guard let found = text.range(of: host, options: [.caseInsensitive], range: start..<end),
              found.lowerBound == start, found.upperBound == end || text[found.upperBound] == ":" else { return nil }
        return found
    }

    /// Why Commander will not open the address. Nil when the owner may open it.
    var openUnavailableReason: String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            return "Commander cannot read this address, so it will not open it."
        }
        guard scheme == "https" || scheme == "http" else {
            return "Commander opens only web addresses that start with https or http."
        }
        guard !host.isEmpty, url.host(percentEncoded: true)?.lowercased() == host.lowercased(), hostRange != nil else {
            return "The address's host is not the host the service checked, so Commander will not open it."
        }
        return nil
    }

    /// The address to hand to the browser. Nil when it may not be opened.
    var openableURL: URL? {
        openUnavailableReason == nil ? URL(string: text) : nil
    }
}

/// The body of a reply: the action, and for an accepted form its content.
enum ElicitationReply {
    static func body(action: ElicitationAction, content: AGUIValue?) -> Data {
        var fields: [String: AGUIValue] = ["action": .string(action.rawValue)]
        if let content { fields["content"] = content }
        return Data(AGUIValue.object(fields).compactText.utf8)
    }
}

/// The open worker's requests, as far as they have been read, with the owner's drafts.
struct ElicitationInspection: Equatable {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// The outcome of a decision whose request has left the list.
    struct Note: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let tone: Tone
    }

    let workerID: String
    /// Nil when the model could not confirm the worker's bound session. Nothing is read.
    let scope: ElicitationScope?
    var phase: Phase = .loading
    /// The requests in scope, in the service's order.
    var items: [Elicitation] = []
    var isRefreshing = false
    /// Why the last refresh failed. The requests already read stay in place.
    var refreshError: String? = nil
    /// Requests the service listed for another worker or session. Never shown or answered.
    var outOfScope = 0
    var drafts: [String: ElicitationDraft] = [:]
    /// Field problems of the last Accept, by request and field name.
    var problems: [String: [String: String]] = [:]
    /// Why the last reply was not accepted, by request.
    var failures: [String: String] = [:]
    /// Replies in flight, by request.
    var replying: [String: ElicitationAction] = [:]
    /// Requests answered or withdrawn here. A read that still lists one as pending is stale.
    var settled: Set<String> = []
    var notes: [Note] = []

    func draft(for id: String) -> ElicitationDraft { drafts[id] ?? ElicitationDraft() }
}

// MARK: - Feature model

/// Reads the requests of the one worker whose panel is open, on opening, after each decision and
/// every few seconds while it stays open, and sends the owner's replies. Closing or opening another
/// worker drops what was read and any read in flight. A reply in flight is the owner's act and is
/// not abandoned.
@Observable @MainActor
final class ElicitationModel {
    struct Service: Sendable {
        var list: @Sendable (_ workerID: String) async throws -> [Elicitation]
        var reply: @Sendable (_ workerID: String, _ elicitationID: String, _ body: Data) async throws -> Void
    }

    private(set) var inspection: ElicitationInspection?
    /// The read in flight. Read by tests; views read `inspection`.
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var replyTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let service: Service
    @ObservationIgnored private let openExternally: @MainActor (URL) -> Void
    @ObservationIgnored private let pollInterval: Duration
    /// Changes whenever the open worker changes, so an answer for an earlier one is dropped.
    @ObservationIgnored private var epoch = 0

    init(service: Service, pollInterval: Duration = .seconds(3),
         openExternally: @escaping @MainActor (URL) -> Void) {
        self.service = service
        self.pollInterval = pollInterval
        self.openExternally = openExternally
    }

    /// Opens the panel's reading on a worker, or closes it with nil. `scope` is the worker's bound
    /// session as the cockpit model knows it; without one nothing is read.
    func inspect(_ workerID: String?, scope: ElicitationScope?) {
        guard inspection?.workerID != workerID || inspection?.scope != scope else { return }
        loadTask?.cancel()
        pollTask?.cancel()
        loadTask = nil
        pollTask = nil
        epoch += 1
        guard let workerID, !workerID.isEmpty else {
            inspection = nil
            return
        }
        guard let scope, scope.workerID == workerID else {
            inspection = ElicitationInspection(
                workerID: workerID, scope: nil,
                phase: .failed("Commander cannot confirm this worker's provider session, so its requests are not shown."))
            return
        }
        inspection = ElicitationInspection(workerID: workerID, scope: scope)
        load()
        poll()
    }

    /// Reads the open worker's requests again now. What was shown stays until the answer arrives.
    func refresh() {
        guard inspection?.scope != nil else { return }
        load()
    }

    /// Sets or clears one field of one request's draft.
    func edit(_ elicitationID: String, field: String, value: ElicitationValue?) {
        guard var current = inspection, current.items.contains(where: { $0.id == elicitationID }) else { return }
        var draft = current.draft(for: elicitationID)
        draft.values[field] = value
        current.drafts[elicitationID] = draft
        current.problems[elicitationID]?[field] = nil
        inspection = current
    }

    /// Sends the owner's decision on one pending request of the open worker. Refused unless the
    /// request is in scope and no reply to it is in flight. An accepted form sends its content and
    /// stays in place with each problem marked when a field is not ready.
    func reply(_ workerID: String, elicitationID: String, action: ElicitationAction) {
        guard var current = inspection, current.workerID == workerID, let scope = current.scope,
              let item = current.items.first(where: { $0.id == elicitationID }), scope.contains(item),
              item.status == .pending, current.replying[elicitationID] == nil else { return }
        var content: AGUIValue? = nil
        if action == .accept {
            switch item.mode {
            case .form:
                let schema = item.schema
                if let reason = schema.acceptUnavailableReason {
                    current.failures[elicitationID] = reason
                    inspection = current
                    return
                }
                switch schema.content(from: current.draft(for: elicitationID)) {
                case .success(let value):
                    content = value
                    current.problems[elicitationID] = nil
                case .failure(let error):
                    current.problems[elicitationID] = error.problems
                    inspection = current
                    return
                }
            case .url:
                break
            case .other:
                return
            }
        }
        let body = ElicitationReply.body(action: action, content: content)
        current.replying[elicitationID] = action
        current.failures[elicitationID] = nil
        inspection = current
        let isForm = item.mode == .form
        replyTask = Task { [service] in
            let failure: Error?
            do {
                try await service.reply(workerID, elicitationID, body)
                failure = nil
            } catch {
                failure = error
            }
            guard var latest = self.inspection, latest.scope == scope else { return }
            latest.replying[elicitationID] = nil
            let short = Identifier.short(elicitationID)
            if let failure {
                if let refusal = failure as? ServiceStatusError, refusal.isWithdrawn {
                    Self.settle(elicitationID, in: &latest)
                    latest.notes.append(.init(text: "Request \(short) was withdrawn. Your answer was not delivered.",
                                              tone: .attention))
                } else {
                    latest.failures[elicitationID] = failure.localizedDescription
                }
            } else if isForm || action != .accept {
                Self.settle(elicitationID, in: &latest)
                latest.notes.append(.init(text: "\(action.pastTense) request \(short).",
                                          tone: action == .accept ? .working : .neutral))
            }
            latest.notes = Array(latest.notes.suffix(3))
            self.inspection = latest
            self.refresh()
        }
    }

    /// Opens a URL request's address in the browser, after the owner has chosen to and confirmed.
    /// Refused unless the request is in scope, still open, and its address may be opened.
    @discardableResult
    func open(_ workerID: String, elicitationID: String) -> Bool {
        guard let current = inspection, current.workerID == workerID, let scope = current.scope,
              let item = current.items.first(where: { $0.id == elicitationID }), scope.contains(item),
              item.status == .pending || item.status == .accepted,
              let url = item.link?.openableURL else { return false }
        openExternally(url)
        return true
    }

    private static func settle(_ id: String, in inspection: inout ElicitationInspection) {
        inspection.settled.insert(id)
        inspection.items.removeAll { $0.id == id }
        inspection.drafts[id] = nil
        inspection.problems[id] = nil
        inspection.failures[id] = nil
    }

    private func load() {
        guard var current = inspection, let scope = current.scope else { return }
        loadTask?.cancel()
        let token = epoch
        if current.phase == .loaded {
            current.isRefreshing = true
        } else {
            current.phase = .loading
        }
        inspection = current
        loadTask = Task { [service] in
            let result: Result<[Elicitation], Error>
            do {
                result = .success(try await service.list(scope.workerID))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, token == self.epoch, var latest = self.inspection,
                  latest.scope == scope else { return }
            self.loadTask = nil
            latest.isRefreshing = false
            switch result {
            case .success(let all):
                let mine = all.filter(scope.contains)
                latest.outOfScope = all.count - mine.count
                let settled = latest.settled
                latest.items = mine.filter { !(settled.contains($0.id) && $0.status == .pending) }
                let shown = Set(latest.items.map(\.id))
                for item in latest.items where item.mode == .form && latest.drafts[item.id] == nil {
                    latest.drafts[item.id] = ElicitationDraft(defaultsOf: item.schema)
                }
                latest.drafts = latest.drafts.filter { shown.contains($0.key) }
                latest.problems = latest.problems.filter { shown.contains($0.key) }
                latest.failures = latest.failures.filter { shown.contains($0.key) }
                latest.phase = .loaded
                latest.refreshError = nil
            case .failure(let error):
                if latest.phase == .loaded {
                    latest.refreshError = error.localizedDescription
                } else {
                    latest.phase = .failed(error.localizedDescription)
                }
            }
            self.inspection = latest
        }
    }

    /// Reads again every interval while the panel stays open on this worker. A read still in
    /// flight is not interrupted.
    private func poll() {
        let token = epoch
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, token == self.epoch else { return }
                if self.loadTask == nil { self.load() }
            }
        }
    }
}

extension ElicitationModel {
    /// The model the live cockpit uses. Requests name the worker; the browser opens only an
    /// address the owner confirmed.
    static func live(reader: ServiceClient) -> ElicitationModel {
        ElicitationModel(
            service: Service(
                list: { workerID in try await reader.elicitations(workerID) },
                reply: { workerID, id, body in try await reader.replyToElicitation(workerID, id: id, body: body) }),
            openExternally: { url in _ = NSWorkspace.shared.open(url) })
    }
}

/// The feature layer's request operations, as the cockpit emits them.
struct ElicitationIntents {
    /// Opens the panel's reading on a worker by ID, or closes it with nil. The cockpit model
    /// supplies the worker's bound session.
    var inspect: @MainActor (_ workerID: String?) -> Void
    /// The open reading. A surface draws it only when it is its own worker's.
    var inspection: @MainActor () -> ElicitationInspection?
    var refresh: @MainActor () -> Void
    var edit: @MainActor (_ elicitationID: String, _ field: String, _ value: ElicitationValue?) -> Void
    var reply: @MainActor (_ workerID: String, _ elicitationID: String, _ action: ElicitationAction) -> Void
    var open: @MainActor (_ workerID: String, _ elicitationID: String) -> Void
}

extension CockpitModel {
    var elicitationIntents: ElicitationIntents {
        ElicitationIntents(
            inspect: { [self] workerID in
                elicitations.inspect(workerID, scope: workerID.flatMap { elicitationScope($0) })
            },
            inspection: { [self] in elicitations.inspection },
            refresh: { [self] in elicitations.refresh() },
            edit: { [self] id, field, value in elicitations.edit(id, field: field, value: value) },
            reply: { [self] workerID, id, action in elicitations.reply(workerID, elicitationID: id, action: action) },
            open: { [self] workerID, id in elicitations.open(workerID, elicitationID: id) })
    }
}

// MARK: - Component values

/// What one worker console needs to offer its requests: the action, and on a console that hosts
/// the panel, the panel's values and intents.
struct ElicitationAccess {
    struct Panel {
        let isPresented: Binding<Bool>
        /// This worker's reading. Nil until it starts.
        let inspection: ElicitationInspection?
        let refresh: () -> Void
        let edit: (_ elicitationID: String, _ field: String, _ value: ElicitationValue?) -> Void
        let reply: (_ elicitationID: String, _ action: ElicitationAction) -> Void
        let open: (_ elicitationID: String) -> Void
        let copy: (String) -> Void
    }

    let workerID: String
    let workerName: String
    let client: AgentClient
    let session: NativeSession
    let open: () -> Void
    var panel: Panel? = nil
}

// MARK: - Molecules

/// One typed form field: its title, whether it is required, its format or bounds, the native
/// control for its kind, its description and the problem the last Accept found.
struct ElicitationFieldControl: View {
    let field: ElicitationSchema.Field
    let value: ElicitationValue?
    var problem: String? = nil
    var isEnabled = true
    let change: (ElicitationValue?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: field.title).font(TypeRole.label).foregroundStyle(Palette.foreground)
                    .lineLimit(2)
                if field.isRequired {
                    Text("required").font(TypeRole.caption).foregroundStyle(.inkSecondary)
                }
                Spacer(minLength: 6)
                if let hint = field.hint {
                    Text(verbatim: hint).font(TypeRole.caption).foregroundStyle(.inkSecondary).lineLimit(1)
                }
            }
            control
            if let detail = field.detail {
                Text(verbatim: detail).font(TypeRole.caption).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let problem {
                Text(verbatim: problem).font(TypeRole.caption).foregroundStyle(Palette.failure)
                    .accessibilityLabel("\(field.title): \(problem)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .text(let format):
            TextField(field.title, text: textBinding, prompt: Text(verbatim: placeholder(format)), axis: .vertical)
                .textFieldStyle(.plain).font(TypeRole.body).foregroundStyle(Palette.foreground)
                .lineLimit(1...4)
                .padding(.vertical, 6)
                .fieldBox(height: 30)
                .disabled(!isEnabled)
                .accessibilityLabel(field.title)
                .accessibilityHint(field.hint ?? "")
        case .number(let integer):
            TextField(field.title, text: textBinding, prompt: Text(verbatim: integer ? "42" : "2.5"))
                .textFieldStyle(.plain).font(TypeRole.terminalSmall).foregroundStyle(Palette.foreground)
                .fieldBox(height: 30)
                .frame(maxWidth: 180, alignment: .leading)
                .disabled(!isEnabled)
                .accessibilityLabel(field.title)
                .accessibilityHint(field.hint ?? (integer ? "Whole number" : "Number"))
        case .boolean:
            HStack(spacing: 8) {
                Toggle(isOn: flagBinding) { Text(verbatim: field.title) }
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!isEnabled)
                    .accessibilityLabel(field.title)
                Text(flagStatement).font(TypeRole.caption).foregroundStyle(.inkSecondary)
                Spacer(minLength: 0)
            }
        case .choice(let options):
            Picker(selection: choiceBinding) {
                Text("Choose…").tag(String?.none)
                ForEach(options) { option in
                    Text(verbatim: option.title).tag(String?.some(option.value))
                }
            } label: {
                Text(verbatim: field.title)
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            .disabled(!isEnabled)
            .accessibilityLabel(field.title)
        case .multiChoice(let options, _, let maxItems):
            // At the maximum, the unchosen options wait until one is cleared.
            let full = maxItems.map { selections.count >= $0 } ?? false
            VStack(alignment: .leading, spacing: 4) {
                ForEach(options) { option in
                    let isChosen = selections.contains(option.value)
                    Toggle(isOn: memberBinding(option.value)) {
                        Text(verbatim: option.title).font(TypeRole.body).foregroundStyle(Palette.foreground)
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                    .disabled(!isEnabled || (full && !isChosen))
                    .accessibilityLabel("\(field.title): \(option.title)")
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(field.title)
            .accessibilityHint(field.hint ?? "")
        case .unsupported(let reason):
            Label {
                Text(verbatim: reason + (field.isRequired ? "" : " It is left out of your answer."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(TypeRole.caption).foregroundStyle(Palette.attention)
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                if case .text(let text)? = value { return text }
                return ""
            },
            // An empty field is no value: an optional one is left out of the answer.
            set: { change($0.isEmpty ? nil : .text($0)) })
    }

    private var flagBinding: Binding<Bool> {
        Binding(
            get: {
                if case .flag(let flag)? = value { return flag }
                return false
            },
            set: { change(.flag($0)) })
    }

    private var choiceBinding: Binding<String?> {
        Binding(
            get: {
                if case .choice(let choice)? = value { return choice }
                return nil
            },
            set: { change($0.map(ElicitationValue.choice)) })
    }

    private var selections: [String] {
        if case .list(let list)? = value { return list }
        return []
    }

    /// Chooses or clears one option. A new choice goes last; the others keep their order and text.
    private func memberBinding(_ option: String) -> Binding<Bool> {
        Binding(
            get: { selections.contains(option) },
            set: { isOn in
                var list = selections.filter { $0 != option }
                if isOn { list.append(option) }
                // Clearing the last choice of an optional list leaves it out of the answer.
                change(list.isEmpty && !field.isRequired ? nil : .list(list))
            })
    }

    private var flagStatement: String {
        guard case .flag(let flag)? = value else { return field.isRequired ? "not chosen" : "not set, left out" }
        return flag ? "On" : "Off"
    }

    private func placeholder(_ format: String?) -> String {
        switch format {
        case "email"?: "name@example.com"
        case "date"?: "YYYY-MM-DD"
        case "date-time"?: "YYYY-MM-DDThh:mm:ssZ"
        default: "Enter text"
        }
    }
}

/// A URL request's address: the checked host on its own line, the full address in the terminal
/// face with that host marked, a punycode warning where it applies, and the owner's explicit open.
/// The address is selectable text, never a link.
struct ElicitationLinkView: View {
    let link: ElicitationLink
    /// The request is still open, so the address may be opened.
    let isOpenOffered: Bool
    /// Asks to open the address. The card confirms before anything opens.
    let open: () -> Void
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.inkSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: link.host.isEmpty ? "host not reported" : link.host)
                    .font(TypeRole.label).foregroundStyle(Palette.attention)
                    .textSelection(.enabled)
                if link.isPunycode {
                    CapabilityChip(text: "punycode", tone: .attention)
                        .help("This host is written in punycode (xn--).")
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Host \(link.host)\(link.isPunycode ? ", punycode" : "")")
            Text(highlighted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Term.background)
                .overlay { Rectangle().strokeBorder(Term.rule, lineWidth: 1) }
                .accessibilityLabel("Address \(link.text)")
            if link.isPunycode {
                Text("The host is written in punycode. Its readable form can imitate a different site, so check every character before opening it.")
                    .font(TypeRole.caption).foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button("Open in Browser…", action: open)
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!isOpenOffered || link.openUnavailableReason != nil)
                    .help(link.openUnavailableReason ?? "Choose to open \(link.host) in your browser. Commander asks you to confirm first.")
                Button("copy address") { copy(link.text) }
                    .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                    .accessibilityLabel("Copy the address")
                Spacer(minLength: 0)
            }
            Text(verbatim: link.openUnavailableReason ?? "Commander does not fetch or open this address by itself.")
                .font(TypeRole.caption)
                .foregroundStyle(link.openUnavailableReason == nil ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(Palette.attention))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The full address, dim, with the checked host bright and bold.
    private var highlighted: AttributedString {
        let font = Term.font(11.5)
        func part(_ text: Substring, color: Color, bold: Bool = false) -> AttributedString {
            var piece = AttributedString(String(text))
            piece.foregroundColor = color
            piece.font = bold ? Term.font(11.5, weight: .bold) : font
            return piece
        }
        guard let range = link.hostRange else { return part(link.text[...], color: Term.text) }
        return part(link.text[..<range.lowerBound], color: Term.dim)
            + part(link.text[range], color: Palette.attention, bold: true)
            + part(link.text[range.upperBound...], color: Term.dim)
    }
}

/// The owner's three decisions on one pending request. Accept is the prominent action and is
/// disabled with its reason when the request cannot be answered here; decline and cancel stay.
struct ElicitationDecisionBar: View {
    let mode: Elicitation.Mode
    let acceptUnavailable: String?
    let replying: ElicitationAction?
    let decide: (ElicitationAction) -> Void

    var body: some View {
        let busy = replying != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Button { decide(.accept) } label: {
                    Label(mode == .form ? "Submit" : "Accept", systemImage: "checkmark")
                }
                .buttonStyle(CapsuleButtonStyle(prominent: true, height: 28))
                .disabled(busy || acceptUnavailable != nil)
                .help(acceptUnavailable ?? acceptHelp)
                Button("Decline") { decide(.decline) }
                    .buttonStyle(CapsuleButtonStyle(height: 28))
                    .disabled(busy)
                    .help("Tell the agent you will not answer this request")
                Button("Cancel") { decide(.cancel) }
                    .buttonStyle(TermButtonStyle(ink: Term.text, size: 11))
                    .disabled(busy)
                    .help("Dismiss the request without answering it")
                    .accessibilityLabel("Cancel the request")
                Spacer(minLength: 6)
                if let replying {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Sending \(replying.rawValue)")
                }
            }
            if let acceptUnavailable {
                Text(verbatim: acceptUnavailable).font(TypeRole.caption).foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var acceptHelp: String {
        switch mode {
        case .form: "Send these values to the agent"
        case .url: "Tell the agent you will open this address. Commander does not open it."
        case .other: "This kind of request cannot be accepted here"
        }
    }
}

// MARK: - Organisms

/// One request: its kind and status, the agent's message, the form or the address, and the
/// owner's decision. Opening an address always asks for confirmation first.
struct ElicitationCard: View {
    let item: Elicitation
    let draft: ElicitationDraft
    let problems: [String: String]
    let failure: String?
    let replying: ElicitationAction?
    let edit: (_ field: String, _ value: ElicitationValue?) -> Void
    let decide: (ElicitationAction) -> Void
    let open: () -> Void
    let copy: (String) -> Void

    @State private var confirmingOpen = false

    var body: some View {
        let schema = item.schema
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Kicker(text: kindTitle)
                Spacer(minLength: 6)
                StatusLabel(text: item.status.label, tone: item.status.tone, symbol: statusSymbol)
            }
            if !item.message.isEmpty {
                Text(verbatim: item.message).font(TypeRole.body).foregroundStyle(Palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            provenance
            switch item.mode {
            case .form:
                if item.status == .pending { form(schema) }
            case .url:
                if let link = item.link {
                    ElicitationLinkView(link: link, isOpenOffered: item.status == .pending || item.status == .accepted,
                                        open: { confirmingOpen = true }, copy: copy)
                } else {
                    caption("The agent sent no address to open.", tone: .attention)
                }
            case .other(let raw):
                caption("Commander cannot show this kind of request (“\(raw)”). Decline or cancel it.", tone: .attention)
            }
            if let failure {
                caption("Not accepted: \(failure)", tone: .failure)
            }
            if item.status == .pending {
                ElicitationDecisionBar(mode: item.mode, acceptUnavailable: acceptUnavailable(schema),
                                       replying: replying, decide: decide)
            } else if let statement {
                caption(statement, tone: item.status.tone)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .strokeBorder(item.status == .pending ? AnyShapeStyle(Palette.attention.opacity(0.55))
                                                      : AnyShapeStyle(.inkEdge), lineWidth: 1)
        }
        .alert("Open this address in your browser?", isPresented: $confirmingOpen) {
            Button("Open in Browser", action: open)
            Button("Don't Open", role: .cancel) {}
        } message: {
            Text(verbatim: openMessage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kindTitle), \(item.status.label)")
    }

    private var kindTitle: String {
        switch item.mode {
        case .form: "Form request"
        case .url: "Link request"
        case .other: "Request"
        }
    }

    private var statusSymbol: String {
        switch item.status {
        case .pending: "questionmark.circle"
        case .accepted, .completed: "checkmark.circle"
        case .declined, .cancelled, .other: "minus.circle"
        }
    }

    private var statement: String? {
        switch item.status {
        case .accepted: "Accepted. The agent reports when it is complete."
        case .completed: "Completed."
        case .pending, .declined, .cancelled, .other: nil
        }
    }

    private var openMessage: String {
        guard let link = item.link else { return "" }
        let warning = link.isPunycode ? "\n\nThe host is written in punycode and can imitate a different site." : ""
        return "Host: \(link.host)\n\n\(link.text)\(warning)\n\nYour browser opens this address. Commander sends nothing to the agent."
    }

    private func acceptUnavailable(_ schema: ElicitationSchema) -> String? {
        switch item.mode {
        case .form: schema.acceptUnavailableReason
        case .url: item.link == nil ? "The agent sent no address. Decline or cancel it instead." : nil
        case .other: "This kind of request cannot be accepted here. Decline or cancel it instead."
        }
    }

    private var provenance: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: (["request \(Identifier.short(item.id))"]
                            + (item.toolCallID.map { ["tool call \(Identifier.short($0))"] } ?? [])).joined(separator: " · "))
                .font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
                .help("Request \(item.id)" + (item.toolCallID.map { ", tool call \($0)" } ?? ""))
            Spacer(minLength: 4)
            Button("copy id") { copy(item.id) }
                .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                .accessibilityLabel("Copy request ID \(item.id)")
        }
    }

    @ViewBuilder private func form(_ schema: ElicitationSchema) -> some View {
        if schema.unsupportedReason == nil {
            if schema.fields.isEmpty {
                caption("This form has no fields. Submit sends an empty answer.", tone: .neutral)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(schema.fields) { field in
                        ElicitationFieldControl(field: field, value: draft.values[field.name],
                                                problem: problems[field.name], isEnabled: replying == nil) { value in
                            edit(field.name, value)
                        }
                    }
                }
            }
        }
    }

    private func caption(_ text: String, tone: Tone) -> some View {
        Text(verbatim: text).font(TypeRole.caption).foregroundStyle(tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Every request the open worker's agent has put to its owner, in the service's order. Loading,
/// none waiting, a failed read and a stale refresh are each stated in words.
struct ElicitationPanel: View {
    let workerName: String
    let client: AgentClient
    let session: NativeSession
    let panel: ElicitationAccess.Panel

    private var inspection: ElicitationInspection? { panel.inspection }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if let notes = inspection?.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(notes) { note in
                                Text(verbatim: note.text).font(TypeRole.caption).foregroundStyle(note.tone.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    content
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A fixed size, like the Source Inspector panel. A popover cannot read a scroll view's
        // content height, so without one it collapses the scroll view to its minimum and clips
        // the form. The cards scroll inside this frame. Loading, empty and URL states sit at the top.
        .frame(width: 460, height: 520, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Input requests, \(workerName)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentAvatar(client: client, size: 18)
                Text(workerName).font(TypeRole.sectionTitle).foregroundStyle(Palette.foreground)
                    .lineLimit(1).truncationMode(.tail)
                Kicker(text: "Input requests")
                Spacer(minLength: 8)
                if inspection?.isRefreshing == true || inspection?.phase == .loading {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Reading this worker's requests")
                } else {
                    SymbolButton(symbol: "arrow.clockwise", label: "Read the requests again", size: 10) {
                        panel.refresh()
                    }
                    .foregroundStyle(.inkSecondary)
                    .disabled(inspection?.scope == nil)
                }
                SymbolButton(symbol: "xmark", label: "Close input requests", size: 10) {
                    panel.isPresented.wrappedValue = false
                }
                .foregroundStyle(.inkSecondary)
                .keyboardShortcut(.cancelAction)
            }
            Text(verbatim: ((session.harnessInstance.isEmpty ? [] : [session.harnessInstance])
                            + ["session " + session.sessionID]).joined(separator: " · "))
                .font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .help("Only requests from this worker's own session are shown")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        switch inspection?.phase {
        case nil, .loading?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading this worker's requests…").font(TypeRole.meta).foregroundStyle(.inkSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading this worker's requests")
        case .failed(let message)?:
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "The requests could not be read: \(message)")
                    .font(TypeRole.caption).foregroundStyle(Palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if inspection?.scope != nil {
                    Button("Read again", action: panel.refresh).buttonStyle(.bordered).controlSize(.small)
                }
            }
        case .loaded?:
            if let inspection {
                loaded(inspection)
            }
        }
    }

    @ViewBuilder private func loaded(_ inspection: ElicitationInspection) -> some View {
        if inspection.items.isEmpty {
            Text("○ no requests from \(workerName.lowercased()) are waiting")
                .font(Term.font(11.5)).foregroundStyle(.inkTermDim)
                .padding(.vertical, 6)
        } else {
            ForEach(inspection.items) { item in
                ElicitationCard(item: item, draft: inspection.draft(for: item.id),
                                problems: inspection.problems[item.id] ?? [:],
                                failure: inspection.failures[item.id],
                                replying: inspection.replying[item.id],
                                edit: { field, value in panel.edit(item.id, field, value) },
                                decide: { action in panel.reply(item.id, action) },
                                open: { panel.open(item.id) },
                                copy: panel.copy)
            }
        }
        if inspection.outOfScope > 0 {
            Text(verbatim: inspection.outOfScope == 1
                 ? "1 request for another worker or session is not shown."
                 : "\(inspection.outOfScope) requests for another worker or session are not shown.")
                .font(TypeRole.caption).foregroundStyle(.inkSecondary)
        }
        if let error = inspection.refreshError {
            Text(verbatim: "The last refresh failed: \(error)")
                .font(TypeRole.caption).foregroundStyle(Palette.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Presents the request panel beside the worker console's action button.
struct ElicitationPresentation: ViewModifier {
    let access: ElicitationAccess?

    func body(content: Content) -> some View {
        if let access, let panel = access.panel {
            content.popover(isPresented: panel.isPresented, arrowEdge: .bottom) {
                ElicitationPanel(workerName: access.workerName, client: access.client,
                                 session: access.session, panel: panel)
            }
        } else {
            content
        }
    }
}
