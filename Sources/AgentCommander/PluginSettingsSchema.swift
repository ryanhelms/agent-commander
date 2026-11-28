import Foundation

// A plugin's `settings_schema`, as the grant form reads it (design/PLUGINS.md).
//
//   PluginSchemaCheck      checks a JSON value against the part of JSON Schema plugins use
//   PluginSettingsSchema   the schema as form fields, where every property is one the form has a
//                          control for; anything else is edited as JSON
//   PluginSettingsInput    what the form holds
//   PluginSettingsProblems why a grant can't be sent yet, by field
//
// The app checks before it sends so a mistake is shown beside its field. The service checks the
// whole schema again and its answer is final.

/// Why settings can't be sent yet, by field name. `PluginSettingsSchema.general` holds what
/// belongs to no single field.
struct PluginSettingsProblems: Error, Equatable {
    var byField: [String: String] = [:]

    var isEmpty: Bool { byField.isEmpty }
}

/// What the settings form holds, by field name. A field with no entry is left out of the grant.
struct PluginSettingsInput: Equatable, Sendable {
    /// Text, numbers as typed, the chosen value of a choice, and a list with one entry per line.
    var text: [String: String] = [:]
    var flags: [String: Bool] = [:]
}

/// Checks a value against a schema: `type`, `enum`, `required`, `properties`,
/// `additionalProperties`, `minLength`, `maxLength`, `minimum`, `maximum`, `exclusiveMinimum`,
/// `exclusiveMaximum`, `minItems`, `maxItems`, `uniqueItems` and `items`. A keyword it doesn't
/// know is left to the service.
enum PluginSchemaCheck {
    struct Problem: Equatable {
        /// Member names and array positions from the root to the value.
        let path: [String]
        let message: String

        /// "topics, entry 3: At most 256 characters."
        var sentence: String {
            guard !path.isEmpty else { return message }
            let place = path.enumerated().map { index, part in
                index > 0 && Int(part) != nil ? "entry \((Int(part) ?? 0) + 1)" : part
            }.joined(separator: ", ")
            return "\(place): \(message)"
        }
    }

    static func problems(in value: AGUIValue, schema: AGUIValue, path: [String] = []) -> [Problem] {
        guard let rules = schema.objectValue else { return [] }
        if let types = typeNames(rules["type"]), !types.contains(where: { matches(value, type: $0) }) {
            return [Problem(path: path, message: expected(types))]
        }
        var found: [Problem] = []
        if let allowed = rules["enum"]?.arrayValue, !allowed.contains(where: { $0.isJSONEqual(to: value) }) {
            found.append(Problem(path: path, message: "Use one of: \(allowed.map(\.displayText).joined(separator: ", "))."))
        }
        switch value {
        case .string(let text):
            let length = text.unicodeScalars.count
            if let least = rules["minLength"]?.intValue, length < least {
                found.append(Problem(path: path, message: length == 0 ? "Enter text." : "At least \(count(least, "character"))."))
            }
            if let most = rules["maxLength"]?.intValue, length > most {
                found.append(Problem(path: path, message: "At most \(count(most, "character"))."))
            }
        case .number(let number):
            let figure = number.doubleValue
            if let least = rules["minimum"]?.numberValue, figure < least.doubleValue {
                found.append(Problem(path: path, message: "At least \(least.literal)."))
            }
            if let most = rules["maximum"]?.numberValue, figure > most.doubleValue {
                found.append(Problem(path: path, message: "At most \(most.literal)."))
            }
            if let least = rules["exclusiveMinimum"]?.numberValue, figure <= least.doubleValue {
                found.append(Problem(path: path, message: "More than \(least.literal)."))
            }
            if let most = rules["exclusiveMaximum"]?.numberValue, figure >= most.doubleValue {
                found.append(Problem(path: path, message: "Less than \(most.literal)."))
            }
        case .array(let items):
            if let least = rules["minItems"]?.intValue, items.count < least {
                found.append(Problem(path: path, message: "At least \(count(least, "entry", plural: "entries"))."))
            }
            if let most = rules["maxItems"]?.intValue, items.count > most {
                found.append(Problem(path: path, message: "At most \(count(most, "entry", plural: "entries"))."))
            }
            if rules["uniqueItems"]?.boolValue == true {
                for (index, item) in items.enumerated() where items[..<index].contains(where: { $0.isJSONEqual(to: item) }) {
                    found.append(Problem(path: path + [String(index)], message: "Listed twice."))
                }
            }
            if let each = rules["items"], each.objectValue != nil {
                for (index, item) in items.enumerated() {
                    found += problems(in: item, schema: each, path: path + [String(index)])
                }
            }
        case .object(let members):
            for name in rules["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where members[name] == nil {
                found.append(Problem(path: path + [name], message: "Required."))
            }
            let properties = rules["properties"]?.objectValue ?? [:]
            for name in members.keys.sorted() {
                guard let member = members[name] else { continue }
                if let property = properties[name] {
                    found += problems(in: member, schema: property, path: path + [name])
                } else if rules["additionalProperties"]?.boolValue == false {
                    found.append(Problem(path: path + [name], message: "Not a setting of this plugin."))
                } else if let other = rules["additionalProperties"], other.objectValue != nil {
                    found += problems(in: member, schema: other, path: path + [name])
                }
            }
        case .null, .bool:
            break
        }
        return found
    }

    /// `type` as a list of names: it is one name or an array of them.
    private static func typeNames(_ value: AGUIValue?) -> [String]? {
        if let name = value?.stringValue { return [name] }
        return value?.arrayValue?.compactMap(\.stringValue)
    }

    static func matches(_ value: AGUIValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("number", .number), ("array", .array), ("object", .object): true
        case ("integer", .number(let number)): isWhole(number)
        default: false
        }
    }

    /// A whole number, written as one (`3`) or as its decimal (`3.0`).
    static func isWhole(_ number: AGUINumber) -> Bool {
        if number.int64Value != nil { return true }
        let figure = number.doubleValue
        return figure.isFinite && figure.rounded() == figure
    }

    private static func expected(_ types: [String]) -> String {
        let words = types.map { type in
            switch type {
            case "string": "text"
            case "integer": "a whole number"
            case "number": "a number"
            case "boolean": "true or false"
            case "array": "a list"
            case "object": "an object"
            default: type
            }
        }
        return "Use \(words.joined(separator: " or "))."
    }

    private static func count(_ number: Int, _ noun: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? noun : plural ?? noun + "s")"
    }
}

/// A plugin's settings as a form. The common shapes get a control each: text, a whole or
/// decimal number, a switch, one of a few text values, and a list of text values. A schema with
/// anything else is edited as JSON and checked the same way.
struct PluginSettingsSchema: Equatable, Sendable {
    /// The key of a problem that belongs to the whole form.
    static let general = ""

    enum Kind: Equatable, Sendable {
        case text
        case number(integer: Bool)
        case boolean
        case choice([String])
        /// Text values, one per line in the form.
        case list
    }

    struct Field: Identifiable, Equatable, Sendable {
        let name: String
        let title: String
        let detail: String?
        let isRequired: Bool
        let kind: Kind
        /// The bounds in words: "2 to 40 characters".
        let hint: String?

        var id: String { name }
    }

    /// The schema as the plugin declared it.
    let source: AGUIValue
    /// Required fields in the schema's `required` order, then the others by name.
    let fields: [Field]
    /// Every property has a control. False leaves the JSON editor only.
    let isFormable: Bool
    /// Why there is no form, in one sentence.
    let rawReason: String?

    init(_ source: AGUIValue) {
        self.source = source
        let (fields, reason) = Self.read(source)
        self.fields = fields
        isFormable = reason == nil
        rawReason = reason
    }

    private static let compositions = ["allOf", "anyOf", "oneOf", "not", "if", "$ref", "patternProperties", "dependentRequired", "dependentSchemas"]

    private static func read(_ source: AGUIValue) -> ([Field], String?) {
        guard let root = source.objectValue else { return ([], "The plugin’s settings schema can’t be read as a form.") }
        if let type = root["type"], type.stringValue != "object" { return ([], "These settings aren’t a flat list of fields.") }
        if compositions.contains(where: { root[$0] != nil }) { return ([], "These settings have rules the form can’t show.") }
        let properties = root["properties"]?.objectValue ?? [:]
        guard !properties.isEmpty else { return ([], "The plugin names no settings, so they are edited as JSON.") }
        let required = root["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var fields: [Field] = []
        let order = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
        for name in order {
            guard let property = properties[name], let kind = kind(of: property) else {
                return ([], "“\(name)” has a shape the form has no control for.")
            }
            let title = property["title"]?.stringValue
            fields.append(Field(name: name, title: title?.isEmpty == false ? title! : name,
                                detail: property["description"]?.stringValue, isRequired: required.contains(name),
                                kind: kind, hint: hint(for: property, kind: kind)))
        }
        return (fields, nil)
    }

    private static func kind(of property: AGUIValue) -> Kind? {
        guard let rules = property.objectValue, !compositions.contains(where: { rules[$0] != nil }) else { return nil }
        switch rules["type"]?.stringValue {
        case "string":
            guard let options = rules["enum"]?.arrayValue else { return .text }
            let values = options.compactMap(\.stringValue)
            return values.count == options.count && !values.isEmpty ? .choice(values) : nil
        case "integer": return rules["enum"] == nil ? .number(integer: true) : nil
        case "number": return rules["enum"] == nil ? .number(integer: false) : nil
        case "boolean": return .boolean
        case "array":
            guard let items = rules["items"]?.objectValue, items["type"]?.stringValue == "string", items["enum"] == nil,
                  !compositions.contains(where: { items[$0] != nil }) else { return nil }
            return .list
        default: return nil
        }
    }

    private static func hint(for property: AGUIValue, kind: Kind) -> String? {
        func range(_ least: String?, _ most: String?, _ noun: String) -> String? {
            switch (least, most) {
            case (let least?, let most?): "\(least) to \(most)\(noun)"
            case (let least?, nil): "At least \(least)\(noun)"
            case (nil, let most?): "Up to \(most)\(noun)"
            default: nil
            }
        }
        switch kind {
        case .text:
            let least = property["minLength"]?.intValue.flatMap { $0 > 1 ? String($0) : nil }
            return range(least, property["maxLength"]?.intValue.map(String.init), " characters")
        case .number(let integer):
            return range(property["minimum"]?.numberValue?.literal, property["maximum"]?.numberValue?.literal, "")
                ?? (integer ? "Whole number" : "Number")
        case .list:
            let least = property["minItems"]?.intValue.flatMap { $0 > 0 ? String($0) : nil }
            let bounds = range(least, property["maxItems"]?.intValue.map(String.init), "")
            return bounds.map { "\($0), one per line" } ?? "One per line"
        case .boolean, .choice:
            return nil
        }
    }

    // MARK: Form to settings

    /// The entries of a list field: one per line, without the space round them or empty lines.
    static func entries(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The settings object the form holds, and what in it couldn't be read as its field's kind.
    private func object(from input: PluginSettingsInput) -> (value: [String: AGUIValue], problems: [String: String]) {
        var members: [String: AGUIValue] = [:]
        var problems: [String: String] = [:]
        for field in fields {
            let text = input.text[field.name] ?? ""
            switch field.kind {
            case .text, .choice:
                if !text.isEmpty { members[field.name] = .string(text) }
            case .number(let integer):
                let literal = text.trimmingCharacters(in: .whitespaces)
                guard !literal.isEmpty else { continue }
                guard let number = AGUINumber(literal: literal) else {
                    problems[field.name] = integer ? "Enter a whole number, such as 42." : "Enter a number, such as 42 or 2.5."
                    continue
                }
                if integer, !PluginSchemaCheck.isWhole(number) {
                    problems[field.name] = "Enter a whole number, such as 42."
                    continue
                }
                members[field.name] = .number(number)
            case .boolean:
                // A required switch that was never touched is sent as off.
                if let flag = input.flags[field.name] ?? (field.isRequired ? false : nil) { members[field.name] = .bool(flag) }
            case .list:
                let entries = Self.entries(text)
                if !entries.isEmpty { members[field.name] = .array(entries.map(AGUIValue.string)) }
            }
        }
        return (members, problems)
    }

    /// The settings for a grant, checked against the schema. An empty optional field is left out.
    func value(from input: PluginSettingsInput) -> Result<AGUIValue, PluginSettingsProblems> {
        let (members, unread) = object(from: input)
        var problems = PluginSettingsProblems(byField: unread)
        for problem in PluginSchemaCheck.problems(in: .object(members), schema: source) {
            let field = problem.path.first ?? Self.general
            guard problems.byField[field] == nil else { continue }
            // A problem inside a list names the entry; one on the field itself is said plainly.
            problems.byField[field] = problem.path.count > 1
                ? PluginSchemaCheck.Problem(path: Array(problem.path.dropFirst()).map { "entry \((Int($0) ?? 0) + 1)" }, message: problem.message).sentence.capitalizedFirst
                : problem.message
        }
        return problems.isEmpty ? .success(.object(members)) : .failure(problems)
    }

    /// The form's contents as JSON, with anything that can't be read left out. Used when the
    /// person moves from the form to the JSON editor.
    func draftValue(from input: PluginSettingsInput) -> AGUIValue { .object(object(from: input).value) }

    /// The form contents for existing settings. Nil when they hold something the form can't show.
    func input(from value: AGUIValue) -> PluginSettingsInput? {
        guard isFormable, let members = value.objectValue else { return nil }
        var input = PluginSettingsInput()
        for (name, member) in members {
            guard let field = fields.first(where: { $0.name == name }) else { return nil }
            switch (field.kind, member) {
            case (.text, .string(let text)):
                input.text[name] = text
            case (.choice(let options), .string(let text)) where options.contains(text):
                input.text[name] = text
            case (.number, .number(let number)):
                input.text[name] = number.literal
            case (.boolean, .bool(let flag)):
                input.flags[name] = flag
            case (.list, .array(let items)):
                let entries = items.compactMap(\.stringValue)
                guard entries.count == items.count, !entries.contains(where: { $0.contains(where: \.isNewline) }) else { return nil }
                input.text[name] = entries.joined(separator: "\n")
            default:
                return nil
            }
        }
        return input
    }

    // MARK: JSON to settings

    /// The settings typed as JSON, checked against the schema. Empty text is an empty object.
    func value(fromJSON text: String) -> Result<AGUIValue, PluginSettingsProblems> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func failure(_ message: String) -> Result<AGUIValue, PluginSettingsProblems> {
            .failure(PluginSettingsProblems(byField: [Self.general: message]))
        }
        guard let value = trimmed.isEmpty ? AGUIValue.object([:]) : try? AGUIValue(json: trimmed) else { return failure("This isn’t valid JSON. Check the quotes, commas and brackets.") }
        guard value.objectValue != nil else { return failure("Settings are a JSON object, such as {\"name\": \"value\"}.") }
        let problems = PluginSchemaCheck.problems(in: value, schema: source)
        guard !problems.isEmpty else { return .success(value) }
        let shown = problems.prefix(4).map(\.sentence)
        let more = problems.count > shown.count ? ["And \(problems.count - shown.count) more."] : []
        return failure((shown + more).joined(separator: "\n"))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
