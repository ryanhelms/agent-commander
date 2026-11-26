import Foundation

// COMMANDER TOOL CATALOG
// Every MCP tool Commander registers for a managed session (internal/mcpbridge: server.go,
// scoped_tools.go, network.go, frontend.go), with the words and symbol Pretty uses for it and the
// fields of its arguments and response it summarises. Pure values: no view, no service call.
//
//   Values   CommanderTool          one registered tool: label, symbol, domain, correlation family
//            CommanderPayload       a call's arguments or result read as JSON, through MCP wrappers
//            CommanderCallFacts     the narrow `commander` correlation object in function.arguments,
//                                   plus the live request state the projection read for it
//
// A name that is not one of these stays on the generic tool row, exactly as before.

enum CommanderTool: String, CaseIterable, Sendable {
    // server.go: every managed session
    case delegate = "commander_delegate"
    case ask = "commander_ask"
    case wait = "commander_wait"
    case reply = "commander_reply"
    case reconcileReply = "commander_reconcile_reply"
    case result = "commander_result"
    case commit = "commander_commit"
    case integrate = "commander_integrate"
    case send = "commander_send"
    case interrupt = "commander_interrupt"
    case stopWorker = "commander_stop_worker"
    case status = "commander_status"
    // scoped_tools.go: coordinator only
    case listTools = "commander_list_tools"
    case callTool = "commander_call_tool"
    // network.go: coordinator only
    case networkInbox = "commander_network_inbox"
    case networkDiscover = "commander_network_discover"
    case networkSubmit = "commander_network_submit"
    case networkReceipt = "commander_network_receipt"
    case networkOnline = "commander_network_online"
    case networkThread = "commander_network_thread"
    case networkBoard = "commander_network_board"
    // frontend.go: every managed session
    case frontendTools = "commander_frontend_tools"
    case callFrontend = "commander_call_frontend"

    enum Domain: String, Sendable {
        case question, workers, code, status, extensions, app, network
    }

    /// How calls of this tool may be grouped. Only an exact shared ID ever links two calls.
    enum Family: Sendable {
        /// Correlated by the exact request ID: ask, wait, reply, reconcile.
        case request
        /// Correlated by the exact operation ID: network submit and receipt.
        case operation
        /// Grouped with a question only on proof: an explicit request ID, or one answered
        /// question in the same uninterrupted turn.
        case report
        case standalone
    }

    /// The tool a provider's name stands for. Providers prefix MCP tools with their server:
    /// `mcp__commander__commander_ask`, `mcp.commander.commander_ask`, `commander/commander_ask`.
    /// The name must end with a registered tool name, after a separator, and anything before it
    /// must name the Commander server. Every other name is nil.
    init?(name: String) {
        if let exact = CommanderTool(rawValue: name) { self = exact; return }
        let separators = CharacterSet(charactersIn: ".:/_")
        for tool in Self.allCases where name.hasSuffix(tool.rawValue) {
            let prefix = name.dropLast(tool.rawValue.count)
            guard let separator = prefix.unicodeScalars.last, separators.contains(separator) else { continue }
            // The last component before the tool is the server's name, exactly.
            let server = prefix.lowercased().components(separatedBy: separators).last { !$0.isEmpty }
            guard server == "commander" else { continue }
            self = tool
            return
        }
        return nil
    }

    /// The short label Pretty shows in place of the tool's wire name.
    var label: String {
        switch self {
        case .delegate: "Delegate worker"
        case .ask: "Ask"
        case .wait: "Wait for reply"
        case .reply: "Reply"
        case .reconcileReply: "Reconcile reply"
        case .result: "Report result"
        case .commit: "Commit"
        case .integrate: "Integrate"
        case .send: "Send follow-up"
        case .interrupt: "Interrupt worker"
        case .stopWorker: "Stop worker"
        case .status: "Check status"
        case .listTools: "List extensions"
        case .callTool: "Call extension"
        case .networkInbox: "Read network inbox"
        case .networkDiscover: "Discover network"
        case .networkSubmit: "Submit operation"
        case .networkReceipt: "Read receipt"
        case .networkOnline: "See who is online"
        case .networkThread: "Read request thread"
        case .networkBoard: "Work task board"
        case .frontendTools: "List app tools"
        case .callFrontend: "Call app tool"
        }
    }

    /// The step's short name in a grouped workflow's step trail, such as `Ask · Wait ×3`.
    var stepName: String {
        switch self {
        case .ask: "Ask"
        case .wait: "Wait"
        case .reply: "Reply"
        case .reconcileReply: "Reconcile"
        case .result: "Result"
        case .networkSubmit: "Submit"
        case .networkReceipt: "Receipt"
        default: label
        }
    }

    /// SF Symbol for the tool's domain action.
    var symbol: String {
        switch self {
        case .delegate: "person.badge.plus"
        case .ask: "questionmark.bubble"
        case .wait: "hourglass"
        case .reply: "arrowshape.turn.up.left"
        case .reconcileReply: "arrow.triangle.2.circlepath"
        case .result: "checkmark.seal"
        case .commit: "smallcircle.filled.circle"
        case .integrate: "arrow.triangle.merge"
        case .send: "paperplane"
        case .interrupt: "pause.circle"
        case .stopWorker: "stop.circle"
        case .status: "list.bullet.rectangle"
        case .listTools: "puzzlepiece.extension"
        case .callTool: "puzzlepiece"
        case .networkInbox: "tray"
        case .networkDiscover: "network"
        case .networkSubmit: "arrow.up.forward.circle"
        case .networkReceipt: "envelope.open"
        case .networkOnline: "person.2.wave.2"
        case .networkThread: "text.bubble"
        case .networkBoard: "rectangle.split.3x1"
        case .frontendTools: "macwindow"
        case .callFrontend: "macwindow.badge.plus"
        }
    }

    var domain: Domain {
        switch self {
        case .ask, .wait, .reply, .reconcileReply: .question
        case .delegate, .send, .interrupt, .stopWorker: .workers
        case .result, .commit, .integrate: .code
        case .status: .status
        case .listTools, .callTool: .extensions
        case .frontendTools, .callFrontend: .app
        case .networkInbox, .networkDiscover, .networkSubmit, .networkReceipt, .networkOnline, .networkThread, .networkBoard: .network
        }
    }

    var family: Family {
        switch self {
        case .ask, .wait, .reply, .reconcileReply: .request
        case .networkSubmit, .networkReceipt: .operation
        case .result: .report
        default: .standalone
        }
    }

    /// What the running indicator says while this tool's call is open.
    var runningPhrase: String {
        switch self {
        case .wait: "Waiting for reply"
        case .ask: "Asking"
        case .status: "Checking worker status"
        default: label
        }
    }
}

// MARK: - Payload

/// A call's arguments or result read as JSON. Results arrive as the service's JSON text, as MCP
/// content (`{"content":[{"type":"text","text":"…"}]}` or the bare list), as a JSON string, or as
/// several phases joined by line breaks. Nothing here is trusted beyond reading a field.
enum CommanderPayload {
    static func value(_ text: String?) -> AGUIValue? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = stripFence(text)
        if let whole = parse(text) { return unwrap(whole, depth: 0) }
        // Several phases joined by line breaks: the last line that is JSON is the final word.
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            if let value = parse(candidate) { return unwrap(value, depth: 0) }
        }
        return nil
    }

    private static func parse(_ text: String) -> AGUIValue? {
        guard let first = text.first, first == "{" || first == "[" || first == "\"" else { return nil }
        return try? AGUIValue(json: text)
    }

    private static func stripFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return text }
        var body = text.dropFirst(3).dropLast(3)
        if let newline = body.firstIndex(of: "\n") { body = body[body.index(after: newline)...] }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrap(_ value: AGUIValue, depth: Int) -> AGUIValue {
        guard depth < 4 else { return value }
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let inner = parse(trimmed), inner.stringValue == nil { return unwrap(inner, depth: depth + 1) }
            return value
        case .object(let members):
            if let structured = members["structuredContent"], structured.objectValue != nil {
                return unwrap(structured, depth: depth + 1)
            }
            if let content = members["content"]?.arrayValue, let text = mcpText(content) {
                return parse(text).map { unwrap($0, depth: depth + 1) } ?? .string(text)
            }
            return value
        case .array(let items):
            if let text = mcpText(items) {
                return parse(text).map { unwrap($0, depth: depth + 1) } ?? .string(text)
            }
            return value
        default:
            return value
        }
    }

    /// The text of an MCP content list whose parts are all `text`. Nil otherwise.
    private static func mcpText(_ items: [AGUIValue]) -> String? {
        guard !items.isEmpty else { return nil }
        var parts: [String] = []
        for item in items {
            guard item["type"]?.stringValue == "text", let text = item["text"]?.stringValue else { return nil }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Correlation

/// The narrow correlation object the service may put in a call's `function.arguments` under
/// `commander`, and the live request state the workspace projection read for it. Every field is
/// optional, and an ID is only ever compared whole.
struct CommanderCallFacts: Equatable, Sendable {
    var requestID: String? = nil
    var requestStatus: String? = nil
    var operationID: String? = nil
    var operationStatus: String? = nil
    var workerID: String? = nil
    /// The request's current status in this run (`run.requests`, exact ID), when the projection
    /// found it. It is newer than anything the call itself carried.
    var liveRequestStatus: String? = nil
    var liveAnswer: String? = nil
    /// The current status of the follow-up or integration this call created, read from the
    /// run by its exact ID (`control.messages[].status`, `integrations[].candidate.status`).
    var liveOperationStatus: String? = nil

    var isEmpty: Bool { self == CommanderCallFacts() }

    /// Reads `commander` from a call's arguments text. Nil when it is absent or holds no string.
    init?(arguments: String) {
        guard arguments.contains("commander"),
              let object = try? AGUIValue(json: arguments), let facts = object["commander"]?.objectValue else { return nil }
        func text(_ key: String) -> String? {
            guard let value = facts[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        requestID = text("requestId")
        requestStatus = text("requestStatus")
        operationID = text("operationId")
        operationStatus = text("operationStatus")
        workerID = text("workerId")
        if isEmpty { return nil }
    }

    init(requestID: String? = nil, requestStatus: String? = nil, operationID: String? = nil,
         operationStatus: String? = nil, workerID: String? = nil,
         liveRequestStatus: String? = nil, liveAnswer: String? = nil, liveOperationStatus: String? = nil) {
        self.liveOperationStatus = liveOperationStatus
        self.requestID = requestID
        self.requestStatus = requestStatus
        self.operationID = operationID
        self.operationStatus = operationStatus
        self.workerID = workerID
        self.liveRequestStatus = liveRequestStatus
        self.liveAnswer = liveAnswer
    }
}
