import Foundation

/// Reduces the workspace feed to the current runs.
///
/// A `STATE_SNAPSHOT` replaces everything. A `STATE_DELTA` is one RFC 6902 patch and applies
/// whole or not at all: a patch that fails leaves the state as it was and throws. The state is
/// kept as a tree of runs and workers. A patch edits only the nodes on its path, and only those
/// are rebuilt as models. Every other run, worker and message is reused as it is.
struct AGUIWorkspaceReducer: Sendable {
    enum Change: Equatable, Sendable {
        case snapshot
        case delta
    }

    /// The service's reason when it sent a snapshot in place of deltas this viewer was too far
    /// behind to receive.
    static let deltaExpiredReason = "workspace_delta_expired"

    private var root: AGUIWorkspaceNode?

    /// The current state. Empty until the first snapshot.
    private(set) var runs: [Run] = []

    /// `metadata.commander.reason` of the last snapshot. Nil for an ordinary one.
    private(set) var snapshotReason: String?

    var hasSnapshot: Bool { root != nil }

    /// The whole state as one JSON document, built on request. For diagnostics and tests.
    var document: AGUIValue? { root?.value }

    /// Applies one event payload. Returns nil for an event that does not carry workspace state.
    @discardableResult
    mutating func apply(frame: [UInt8]) throws -> Change? { try apply(event: AGUIValue(json: frame)) }

    @discardableResult
    mutating func apply(frame: String) throws -> Change? { try apply(event: AGUIValue(json: frame)) }

    @discardableResult
    mutating func apply(event: AGUIValue) throws -> Change? {
        guard case .object(let fields) = event, let type = fields["type"]?.stringValue else {
            throw AGUIValueError("An event has no type")
        }
        switch type {
        case "STATE_SNAPSHOT":
            guard let snapshot = fields["snapshot"] else { throw AGUIValueError("A snapshot has no state") }
            var next = try AGUIWorkspaceNode(value: snapshot)
            runs = try next.materialize()
            root = next
            snapshotReason = fields["metadata"]?["commander"]?["reason"]?.stringValue
            return .snapshot
        case "STATE_DELTA":
            // The copy shares every node with the current state. Edits are made to the copy,
            // and it replaces the state only when the whole patch applied and still reads as runs.
            guard var next = root else { throw AGUIValueError("A delta arrived before any snapshot") }
            switch fields["delta"] {
            case .array(let operations)?:
                for operation in operations { try next.apply(operation: operation) }
            case nil:
                break // the service omits an empty patch
            default:
                throw AGUIValueError("A delta is not a list of operations")
            }
            runs = try next.materialize()
            root = next
            return .delta
        default:
            return nil
        }
    }
}

/// The state document: `{ "runs": [...] }` and any other members the service adds.
struct AGUIWorkspaceNode: Sendable {
    private var fields: [String: AGUIValue]
    private var runs: [AGUIRunNode]?

    init(value: AGUIValue) throws {
        guard case .object(var members) = value else { throw AGUIValueError("The workspace state is not an object") }
        runs = try AGUINode.list(members.removeValue(forKey: "runs"), make: AGUIRunNode.init(value:))
        fields = members
    }

    var value: AGUIValue {
        var members = fields
        if let runs { members["runs"] = .array(runs.map(\.value)) }
        return .object(members)
    }

    /// Applies one RFC 6902 operation object.
    mutating func apply(operation: AGUIValue) throws {
        guard case .object(let fields) = operation, let name = fields["op"]?.stringValue,
              let pathText = fields["path"]?.stringValue else {
            throw AGUIValueError("A patch operation has no op or path")
        }
        let path = try AGUIPointer(pathText).tokens
        func source() throws -> [String] {
            guard let text = fields["from"]?.stringValue else { throw AGUIValueError("\(name): no from") }
            return try AGUIPointer(text).tokens
        }
        // RFC 6902 requires `value` on add, replace and test. An explicit null is a value; a
        // missing member is a malformed operation and fails the whole delta.
        func operand() throws -> AGUIValue {
            guard let operand = fields["value"] else { throw AGUIValueError("\(name): no value") }
            return operand
        }
        switch name {
        case "add": try edit(.add(operand()), at: path[...])
        case "replace": try edit(.replace(operand()), at: path[...])
        case "remove": try edit(.remove, at: path[...])
        case "copy":
            try edit(.add(value.value(at: source()[...])), at: path[...])
        case "move":
            let from = try source()
            guard from != path else { return }
            guard !path.starts(with: from) else { throw AGUIValueError("move: the target is inside the source") }
            let moved = try value.value(at: from[...])
            try edit(.remove, at: from[...])
            try edit(.add(moved), at: path[...])
        case "test":
            // By value: `1` passes against `1.0`. State equality is by literal and is not used here.
            let expected = try operand()
            guard try value.value(at: path[...]).isJSONEqual(to: expected) else {
                throw AGUIValueError("test: \(pathText) has a different value")
            }
        default:
            throw AGUIValueError("Unknown patch operation \(name)")
        }
    }

    mutating func edit(_ edit: AGUIEdit, at path: ArraySlice<String>) throws {
        guard let head = path.first else {
            switch edit {
            case .add(let value), .replace(let value): self = try AGUIWorkspaceNode(value: value)
            case .remove: throw AGUIValueError("remove: the whole state cannot be removed")
            }
            return
        }
        if head == "runs" {
            try AGUINode.edit(&runs, edit, at: path.dropFirst(), make: AGUIRunNode.init(value:)) { run, edit, rest in
                try run.edit(edit, at: rest)
            }
        } else {
            try AGUIPatch.edit(&fields, edit, at: path)
        }
    }

    mutating func materialize() throws -> [Run] {
        guard runs != nil else { return [] }
        var models: [Run] = []
        models.reserveCapacity(runs!.count)
        for index in runs!.indices { models.append(try runs![index].materialize()) }
        return models
    }
}

/// One run: its own fields, and its workers as nodes.
struct AGUIRunNode: Sendable {
    private var fields: [String: AGUIValue]
    private var workers: [AGUIWorkerNode]?
    private var model: Run?

    init(value: AGUIValue) throws {
        guard case .object(var members) = value else { throw AGUIValueError("A run is not an object") }
        workers = try AGUINode.list(members.removeValue(forKey: "workers"), make: AGUIWorkerNode.init(value:))
        fields = members
    }

    var value: AGUIValue {
        var members = fields
        if let workers { members["workers"] = .array(workers.map(\.value)) }
        return .object(members)
    }

    /// `path` is not empty.
    mutating func edit(_ edit: AGUIEdit, at path: ArraySlice<String>) throws {
        model = nil
        if path.first == "workers" {
            try AGUINode.edit(&workers, edit, at: path.dropFirst(), make: AGUIWorkerNode.init(value:)) { worker, edit, rest in
                try worker.edit(edit, at: rest)
            }
        } else {
            try AGUIPatch.edit(&fields, edit, at: path)
        }
    }

    mutating func materialize() throws -> Run {
        if let model { return model }
        var models: [Worker]?
        if workers != nil {
            models = []
            models!.reserveCapacity(workers!.count)
            for index in workers!.indices { models!.append(try workers![index].materialize()) }
        }
        let built = try Run(projection: fields, workers: models)
        model = built
        return built
    }
}

/// One worker: its own fields, its output as the feed's chunks, and its messages as models.
struct AGUIWorkerNode: Sendable {
    private var fields: [String: AGUIValue]
    private var outputChunks: [String]?
    private var messages: [AGUIMessage]?
    private var model: Worker?

    init(value: AGUIValue) throws {
        guard case .object(var members) = value else { throw AGUIValueError("A worker is not an object") }
        outputChunks = try AGUINode.list(members.removeValue(forKey: "outputChunks"), make: Self.chunk)
        messages = try AGUINode.list(members.removeValue(forKey: "messages"), make: AGUIMessage.init(fields:))
        fields = members
    }

    var value: AGUIValue {
        var members = fields
        if let outputChunks { members["outputChunks"] = .array(outputChunks.map(AGUIValue.string)) }
        if let messages { members["messages"] = .array(messages.map(\.allFields)) }
        return .object(members)
    }

    private static func chunk(_ value: AGUIValue) throws -> String {
        guard case .string(let text) = value else { throw AGUIValueError("An output chunk is not a string") }
        return text
    }

    /// `path` is not empty.
    mutating func edit(_ edit: AGUIEdit, at path: ArraySlice<String>) throws {
        model = nil
        switch path.first {
        case "outputChunks":
            try AGUINode.edit(&outputChunks, edit, at: path.dropFirst(), make: Self.chunk) { _, edit, _ in
                throw AGUIValueError("\(edit.name): an output chunk has no members")
            }
        case "messages":
            try AGUINode.edit(&messages, edit, at: path.dropFirst(), make: AGUIMessage.init(fields:)) { message, edit, rest in
                var fields = message.allFields
                try fields.apply(edit, at: rest)
                message = try AGUIMessage(fields: fields)
            }
        default:
            try AGUIPatch.edit(&fields, edit, at: path)
        }
    }

    mutating func materialize() throws -> Worker {
        if let model { return model }
        let built = try Worker(projection: fields, outputChunks: outputChunks, messages: messages)
        model = built
        return built
    }
}

enum AGUINode {
    /// Reads a list member. A missing or null member is no list.
    static func list<Element>(_ value: AGUIValue?, make: (AGUIValue) throws -> Element) throws -> [Element]? {
        switch value {
        case nil, .null?: return nil
        case .array(let items)?: return try items.map(make)
        default: throw AGUIValueError("A list member holds a value that is not a list")
        }
    }

    /// Applies an edit at or below a list member. `path` is what follows the member's name:
    /// empty for the list itself, one token for an element, more for inside an element.
    static func edit<Element>(_ list: inout [Element]?, _ edit: AGUIEdit, at path: ArraySlice<String>,
                              make: (AGUIValue) throws -> Element,
                              descend: (inout Element, AGUIEdit, ArraySlice<String>) throws -> Void) throws {
        guard let token = path.first else {
            switch edit {
            case .add(let value):
                list = try Self.list(value, make: make)
            case .replace(let value):
                guard list != nil else { throw AGUIValueError("replace: the list does not exist") }
                list = try Self.list(value, make: make)
            case .remove:
                guard list != nil else { throw AGUIValueError("remove: the list does not exist") }
                list = nil
            }
            return
        }
        guard list != nil else { throw AGUIValueError("\(edit.name): the list does not exist") }
        if path.count == 1 {
            try AGUIPatch.edit(&list!, edit, token: token, make: make)
        } else {
            guard let index = AGUIPointer.index(token), index < list!.count else {
                throw AGUIValueError("\(edit.name): no list element \(token)")
            }
            try descend(&list![index], edit, path.dropFirst())
        }
    }
}

/// Typed reads of an object's members. A member of the wrong kind is an error, so a damaged
/// record is rejected and never shown as a blank one.
extension Dictionary where Key == String, Value == AGUIValue {
    func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw AGUIValueError("Missing \(key)") }
        return value
    }

    /// Nil when the member is missing or null.
    func optionalString(_ key: String) throws -> String? {
        switch self[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw AGUIValueError("\(key) is not a string")
        }
    }

    func optionalBool(_ key: String) throws -> Bool? {
        switch self[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        default: throw AGUIValueError("\(key) is not a boolean")
        }
    }

    func optionalInt(_ key: String) throws -> Int? {
        switch self[key] {
        case nil, .null?: return nil
        case .number(let value)?:
            guard let integer = value.intValue else { throw AGUIValueError("\(key) is not an integer") }
            return integer
        default: throw AGUIValueError("\(key) is not a number")
        }
    }

    func optionalList<Element>(_ key: String, make: (AGUIValue) throws -> Element) throws -> [Element]? {
        try AGUINode.list(self[key], make: make)
    }
}
