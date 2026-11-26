import CryptoKit
import Foundation

// MULTIPLAYER CONTRACT: share and consult (design/COMMANDER-NETWORK-INCREMENT-3.md).
// Capabilities, the shared directory, access requests, approvals, the audit log, the grant policy,
// Consult and Hand off requests, threads and result artifacts, as the device agent's tray verbs
// exchange them. Values only; MultiplayerShareModel calls the helper. Replies are read leniently:
// the relay and the device agent may add fields, and a row this build can't read is skipped rather
// than hiding the rest.

// MARK: - JSON

/// Any JSON value: a request payload on the way out, a result on the way back.
indirect enum MultiplayerJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MultiplayerJSON])
    case object([String: MultiplayerJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MultiplayerJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: MultiplayerJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if let whole = Int(exactly: value) { try container.encode(whole) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> MultiplayerJSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var text: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var items: [MultiplayerJSON] {
        if case .array(let values) = self { return values }
        return []
    }

    /// The first of these fields that holds non-empty text.
    func firstText(_ keys: String...) -> String? {
        keys.lazy.compactMap { self[$0]?.text?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// What a person reads: the text itself, the answer field of a result, or compact JSON.
    var readable: String {
        switch self {
        case .null: return ""
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return Int(exactly: value).map(String.init) ?? String(value)
        case .array, .object:
            if let answer = firstText("text", "answer", "result", "output", "summary", "message") { return answer }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}

/// Reads one key leniently: a missing or wrongly typed value is the fallback, never a failure.
private extension KeyedDecodingContainer {
    func text(_ keys: Key...) -> String {
        for key in keys {
            if let value = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    func strings(_ keys: Key...) -> [String]? {
        for key in keys {
            if let value = (try? decodeIfPresent([String].self, forKey: key)) ?? nil {
                return MultiplayerUnique.keep(value) { $0 }
            }
        }
        return nil
    }

    func date(_ keys: Key...) -> Date? {
        let raw = keys.lazy.compactMap { (try? self.decodeIfPresent(String.self, forKey: $0)) ?? nil }.first
        // Go's zero time means "not set".
        return raw.flatMap(MultiplayerTime.parse).flatMap { $0.timeIntervalSince1970 < 0 ? nil : $0 }
    }
}

/// A list whose unreadable rows are dropped.
struct MultiplayerLenientList<Item: Decodable>: Decodable {
    let items: [Item]

    private struct Slot: Decodable {
        let item: Item?
        init(from decoder: any Decoder) throws { item = try? Item(from: decoder) }
    }

    init(from decoder: any Decoder) throws {
        items = ((try? decoder.singleValueContainer().decode([Slot].self)) ?? []).compactMap(\.item)
    }
}

// MARK: - Capabilities and the directory

/// What an owner says a resource can do: its harness, model, free slots, tools and environments.
struct MultiplayerCapabilities: Decodable, Equatable, Sendable {
    let harness: String
    let model: String
    let slots: Int?
    let tools: [String]
    let environments: [String]

    private enum CodingKeys: String, CodingKey { case harness, model, slots, tools, environments }

    init(harness: String = "", model: String = "", slots: Int? = nil, tools: [String] = [], environments: [String] = []) {
        self.harness = harness
        self.model = model
        self.slots = slots
        self.tools = tools
        self.environments = environments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        harness = container.text(.harness)
        model = container.text(.model)
        slots = ((try? container.decodeIfPresent(Int.self, forKey: .slots)) ?? nil).flatMap { $0 > 0 ? $0 : nil }
        tools = container.strings(.tools) ?? []
        environments = container.strings(.environments) ?? []
    }

    var isEmpty: Bool { harness.isEmpty && model.isEmpty && slots == nil && tools.isEmpty && environments.isEmpty }

    /// Harness and model, then slots: "Claude, opus, 2 slots".
    var headline: String? {
        var parts: [String] = []
        if !harness.isEmpty { parts.append(Self.harnessTitle(harness)) }
        if !model.isEmpty { parts.append(model.multiplayerDisplay) }
        if let slots { parts.append(slots == 1 ? "1 slot" : "\(slots) slots") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Tools and environments, as short tags.
    var tags: [String] { (tools + environments).map(\.multiplayerDisplay) }

    static func harnessTitle(_ harness: String) -> String {
        switch harness.lowercased() {
        case "claude": "Claude"
        case "codex": "Codex"
        default: harness.multiplayerDisplay
        }
    }
}

/// A friend's resource in one server's directory: what it offers and what you already hold.
struct MultiplayerDirectoryEntry: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let kind: String
    /// The owner's handle.
    let owner: String
    /// Everything the owner offers on it.
    let offered: [String]
    /// The actions already granted to you.
    let granted: [String]
    let capabilities: MultiplayerCapabilities?

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, owner, handle, ownerHandle, actions, offered, granted, grantedActions, capabilities
    }

    init(id: String, name: String, kind: String, owner: String, offered: [String], granted: [String] = [],
         capabilities: MultiplayerCapabilities? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.owner = owner
        self.offered = offered
        self.granted = granted
        self.capabilities = capabilities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let name = container.text(.name)
        self.name = name.isEmpty ? id : name
        kind = container.text(.kind)
        // The relay's directory names the owner's account in `owner` and their handle in `handle`.
        let handle = container.text(.handle, .ownerHandle)
        owner = handle.isEmpty ? container.text(.owner) : handle
        granted = container.strings(.grantedActions, .granted) ?? []
        offered = MultiplayerUnique.keep((container.strings(.offered, .actions) ?? []) + granted) { $0 }
        let capabilities = (try? container.decodeIfPresent(MultiplayerCapabilities.self, forKey: .capabilities)) ?? nil
        self.capabilities = capabilities.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A row of the older `shared` list: everything it lists is granted.
    init(shared: MultiplayerShared) {
        self.init(id: shared.id, name: shared.name, kind: shared.kind, owner: shared.owner,
                  offered: shared.actions, granted: shared.actions, capabilities: shared.capabilities)
    }

    /// Offered actions you don't hold yet, without the ones that only ride along with another.
    var requestable: [String] {
        offered.filter { !granted.contains($0) && !MultiplayerSharePolicy.isCompanion($0) }
    }

    var canConsult: Bool { granted.contains(MultiplayerSharePolicy.ask) }
    var canHandOff: Bool { granted.contains(MultiplayerSharePolicy.handoff) }

    /// The directory when the helper sends one; otherwise what the `shared` list shows.
    static func entries(directory: [MultiplayerDirectoryEntry]?, shared: [MultiplayerShared]) -> [MultiplayerDirectoryEntry] {
        let rows = directory ?? shared.map(MultiplayerDirectoryEntry.init(shared:))
        return MultiplayerUnique.keep(rows) { $0.id }.sorted { left, right in
            if left.owner != right.owner { return left.owner.localizedStandardCompare(right.owner) == .orderedAscending }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

// MARK: - Access requests

/// A request for access to a resource: one you sent, or one a friend sent you.
struct MultiplayerAccessRequest: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let resource: String
    /// Handles, when the relay gives them.
    let owner: String
    let requester: String
    let actions: [String]
    let note: String
    let status: String
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, resource, owner, ownerHandle, requester, requesterHandle, from, actions, note, status, createdAt, at
    }

    init(id: String, resource: String, owner: String, requester: String, actions: [String], note: String = "",
         status: String = "pending", createdAt: Date? = nil) {
        self.id = id
        self.resource = resource
        self.owner = owner
        self.requester = requester
        self.actions = actions
        self.note = note
        self.status = status
        self.createdAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        resource = container.text(.resource)
        owner = container.text(.ownerHandle, .owner)
        requester = container.text(.requesterHandle, .from, .requester)
        actions = container.strings(.actions) ?? []
        note = container.text(.note)
        let status = container.text(.status)
        self.status = status.isEmpty ? "pending" : status
        createdAt = container.date(.createdAt, .at)
    }

    var isPending: Bool { status == "pending" }

    var statusTitle: String {
        switch status {
        case "pending": "Waiting"
        case "granted": "Granted"
        case "declined", "denied": "Declined"
        default: status.multiplayerDisplay
        }
    }

    var actionsTitle: String {
        actions.isEmpty ? "Access" : actions.map(MultiplayerCapability.title).formatted(.list(type: .and))
    }
}

/// A `relay` reply for GET /v1/access-requests: `{"requests": […]}`, or the bare list.
struct MultiplayerAccessRequestList: Decodable {
    let requests: [MultiplayerAccessRequest]

    private enum CodingKeys: String, CodingKey { case requests, incoming, outgoing }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            let lists = [CodingKeys.requests, .incoming, .outgoing].compactMap {
                (try? container.decodeIfPresent(MultiplayerLenientList<MultiplayerAccessRequest>.self, forKey: $0)) ?? nil
            }
            requests = MultiplayerUnique.keep(lists.flatMap(\.items)) { $0.id }
        } else {
            requests = MultiplayerUnique.keep(try MultiplayerLenientList<MultiplayerAccessRequest>(from: decoder).items) { $0.id }
        }
    }
}

// MARK: - Approvals and audit

/// A friend's request waiting for the owner, under a grant set to Ask each time.
struct MultiplayerApproval: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let peer: String
    let resource: String
    let action: String
    let summary: String
    let arrived: Date?
    let expires: Date?

    private enum CodingKeys: String, CodingKey { case id, peer, friend, handle, resource, action, summary, arrived, expires }

    init(id: String, peer: String, resource: String, action: String, summary: String = "", arrived: Date? = nil,
         expires: Date? = nil) {
        self.id = id
        self.peer = peer
        self.resource = resource
        self.action = action
        self.summary = summary
        self.arrived = arrived
        self.expires = expires
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        peer = container.text(.handle, .friend, .peer)
        resource = container.text(.resource)
        action = container.text(.action)
        summary = container.text(.summary)
        arrived = container.date(.arrived)
        expires = container.date(.expires)
    }

    /// "Send prompts to the worker", in the words of the request: "wants to send prompts to the worker".
    var wants: String { "wants to \(MultiplayerCapability.title(action).lowercasedFirst)" }

    /// The payload summary, made safe to draw. Its text when the payload carries one.
    var request: String {
        let parsed = (try? JSONDecoder().decode(MultiplayerJSON.self, from: Data(summary.utf8)))
        let text = parsed?.firstText("text", "task", "title") ?? summary
        return MultiplayerText.clean(text, limit: 240, redact: true)
    }
}

struct MultiplayerApprovalList: Decodable {
    let approvals: [MultiplayerApproval]

    private enum CodingKeys: String, CodingKey { case approvals }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let list = (try? container.decodeIfPresent(MultiplayerLenientList<MultiplayerApproval>.self, forKey: .approvals)) ?? nil
        approvals = MultiplayerUnique.keep(list?.items ?? []) { $0.id }
    }
}

/// One executed, denied or expired request in the audit log.
struct MultiplayerAuditEntry: Decodable, Equatable, Sendable, Identifiable {
    let request: String
    let peer: String
    let resource: String
    let action: String
    let started: Date?
    let ended: Date?
    let outcome: String
    let tokens: Int
    let summary: String

    private enum CodingKeys: String, CodingKey { case request, peer, resource, action, started, ended, outcome, tokens, summary }

    var id: String { "\(request)#\(action)#\(started?.timeIntervalSince1970 ?? 0)" }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = container.text(.request)
        peer = container.text(.peer)
        resource = container.text(.resource)
        action = container.text(.action)
        started = container.date(.started)
        ended = container.date(.ended)
        outcome = container.text(.outcome)
        tokens = max(((try? container.decodeIfPresent(Int.self, forKey: .tokens)) ?? nil) ?? 0, 0)
        summary = container.text(.summary)
    }

    var outcomeTitle: String { MultiplayerRequestState.title(outcome) }
    var outcomeTone: Tone { MultiplayerRequestState.tone(outcome) }
    var tokensTitle: String? { tokens > 0 ? "\(tokens.formatted()) tokens" : nil }
}

struct MultiplayerAuditLog: Decodable {
    let entries: [MultiplayerAuditEntry]

    private enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = ((try? container.decodeIfPresent(MultiplayerLenientList<MultiplayerAuditEntry>.self, forKey: .entries)) ?? nil)?.items ?? []
    }
}

/// The words for a request's or a run's state, as the device agent and Commander name them.
enum MultiplayerRequestState {
    static func title(_ state: String) -> String {
        switch state.lowercased() {
        case "": "Unknown"
        case "ok", "done", "completed", "complete", "succeeded", "success": "Done"
        case "pending", "queued", "claimed": "Waiting"
        case "running", "working", "active", "started": "Working"
        case "denied": "Denied"
        case "expired": "Expired"
        case "budget_exhausted": "Budget used up"
        case "failed", "error": "Failed"
        case "stopped", "cancelled", "canceled": "Stopped"
        default: state.replacingOccurrences(of: "_", with: " ").multiplayerDisplay
        }
    }

    static func tone(_ state: String) -> Tone {
        switch state.lowercased() {
        case "ok", "done", "completed", "complete", "succeeded", "success", "running", "working", "active", "started": .working
        case "pending", "queued", "claimed": .attention
        case "denied", "expired", "budget_exhausted", "failed", "error": .failure
        default: .neutral
        }
    }

    static func isSettled(_ state: String) -> Bool {
        !["", "pending", "queued", "claimed", "running", "working", "active", "started"].contains(state.lowercased())
    }
}

// MARK: - Requests you sent

/// The reply to `send`, and one row of `sent` or `handoffs`.
struct MultiplayerSentRequest: Decodable, Equatable, Sendable, Identifiable {
    /// The request's ID on this device. Names it for `thread`, `comment` and `apply-artifact`.
    let request: String
    let resource: String
    let action: String
    let title: String
    let at: Date?
    let status: String
    let value: MultiplayerJSON?
    let failure: String

    private enum CodingKeys: String, CodingKey { case request, resource, action, title, at, status, value, failure, error }

    var id: String { request }

    init(request: String, resource: String = "", action: String = "", title: String = "", at: Date? = nil,
         status: String = "", value: MultiplayerJSON? = nil, failure: String = "") {
        self.request = request
        self.resource = resource
        self.action = action
        self.title = title
        self.at = at
        self.status = status
        self.value = value
        self.failure = failure
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = try container.decode(String.self, forKey: .request)
        resource = container.text(.resource)
        action = container.text(.action)
        title = container.text(.title)
        at = container.date(.at)
        status = container.text(.status)
        let value = (try? container.decodeIfPresent(MultiplayerJSON.self, forKey: .value)) ?? nil
        self.value = value == .null ? nil : value
        failure = container.text(.failure, .error)
    }

    /// The run a hand-off started on the owner's Mac.
    var run: String? { value?.firstText("run") }

    var isSettled: Bool { MultiplayerRequestState.isSettled(status) }

    /// Whether the owner's device answered with a result rather than a refusal.
    var succeeded: Bool { ["ok", "done", "completed", "succeeded", "success"].contains(status.lowercased()) }

    /// Why nothing came back, in the reader's terms.
    var refusal: String? {
        switch status.lowercased() {
        case "pending", "queued", "claimed", "": return "Waiting for the owner. With Ask each time, they approve each request first."
        case "denied": return "The owner denied this request."
        case "expired": return "The owner didn’t answer in time, so the request expired."
        case "budget_exhausted": return "This grant’s token budget is used up. Ask the owner for more."
        default:
            if succeeded { return nil }
            let detail = MultiplayerText.clean(failure, limit: 200, redact: true)
            return detail.isEmpty ? "The request ended as “\(MultiplayerRequestState.title(status))”." : detail
        }
    }
}

struct MultiplayerSentList: Decodable {
    let rows: [MultiplayerSentRequest]

    private enum CodingKeys: String, CodingKey { case sent, handoffs }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lists = [CodingKeys.handoffs, .sent].compactMap {
            (try? container.decodeIfPresent(MultiplayerLenientList<MultiplayerSentRequest>.self, forKey: $0)) ?? nil
        }
        rows = MultiplayerUnique.keep(lists.flatMap(\.items)) { $0.request }
    }
}

/// Something a hand-off produced.
struct MultiplayerArtifact: Equatable, Sendable {
    let kind: String
    let name: String
    let content: String
    let url: String

    init?(_ json: MultiplayerJSON) {
        guard let kind = json.firstText("kind") else { return nil }
        self.kind = kind
        name = json.firstText("name") ?? kind
        content = json["content"]?.text ?? ""
        url = json.firstText("url") ?? ""
    }

    var kindTitle: String {
        switch kind {
        case "patch": "Patch"
        case "branch": "Branch"
        case "pull_request": "Pull request"
        case "file": "File"
        case "report": "Report"
        default: kind.multiplayerDisplay
        }
    }

    var symbol: String {
        switch kind {
        case "patch": "plusminus"
        case "branch": "arrow.triangle.branch"
        case "pull_request": "arrow.triangle.pull"
        case "report": "doc.text"
        default: "doc"
        }
    }

    /// What Apply does with it, or nil when the device agent doesn't apply this kind.
    var applyTitle: String? {
        switch kind {
        case "patch": "Apply…"
        case "report", "file": "Save…"
        default: nil
        }
    }

    var applyHint: String {
        switch kind {
        case "patch": "Runs git apply in the checkout you pick."
        case "report", "file": "Saves it into the folder you pick."
        case "branch": "Fetch this branch from the owner’s repository."
        case "pull_request": url.isEmpty ? "Open the pull request on its host." : url.multiplayerDisplay
        default: "Commander doesn’t apply this kind."
        }
    }
}

/// What `agent.status` or `agent.result` said about a hand-off's run.
struct MultiplayerHandoffReport: Equatable, Sendable {
    /// The `agent.result` request that carries the artifacts. `apply-artifact` names it.
    let request: String
    let state: String
    let summary: String
    let updatedAt: Date?
    let artifacts: [MultiplayerArtifact]
    /// True once `agent.result` answered; false after `agent.status` only.
    let isResult: Bool

    init?(reply: MultiplayerSentRequest, isResult: Bool) {
        guard reply.succeeded, let value = reply.value else { return nil }
        request = reply.request
        state = value.firstText("state") ?? ""
        summary = value.firstText("summary") ?? ""
        updatedAt = value["updatedAt"]?.text.flatMap(MultiplayerTime.parse)
        artifacts = (value["artifacts"]?.items ?? []).compactMap(MultiplayerArtifact.init)
        self.isResult = isResult
    }

    /// The report artifact's text, when the run wrote one.
    var report: String? { artifacts.first { $0.kind == "report" && !$0.content.isEmpty }?.content }
}

// MARK: - Threads

struct MultiplayerComment: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let author: String
    let authorKind: String
    let at: Date?
    let text: String

    private enum CodingKeys: String, CodingKey { case id, author, authorKind, at, text }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = container.text(.text)
        let at = container.date(.at)
        let author = container.text(.author)
        let id = container.text(.id)
        self.id = id.isEmpty ? "\(author)#\(at?.timeIntervalSince1970 ?? 0)#\(text.hashValue)" : id
        self.author = author
        authorKind = container.text(.authorKind)
        self.at = at
        self.text = text
    }

    var isAgent: Bool { authorKind == "agent" }
}

struct MultiplayerThread: Decodable, Equatable, Sendable {
    let comments: [MultiplayerComment]

    private enum CodingKeys: String, CodingKey { case comments }

    init(comments: [MultiplayerComment] = []) { self.comments = comments }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let list = (try? container.decodeIfPresent(MultiplayerLenientList<MultiplayerComment>.self, forKey: .comments)) ?? nil
        comments = MultiplayerUnique.keep(list?.items ?? []) { $0.id }
    }
}

// MARK: - Grant policy

/// Which actions travel together, and the action lists a resource has before the device agent has
/// been asked.
enum MultiplayerSharePolicy {
    static let ask = "agent.ask"
    static let handoff = "agent.handoff"
    static let thread = ["thread.read", "thread.comment"]
    static let tracking = ["agent.status", "agent.result"]

    /// Granted with another action, never chosen by themselves.
    static func isCompanion(_ action: String) -> Bool { thread.contains(action) || tracking.contains(action) }

    /// The actions granted with the chosen ones, so threads and hand-off tracking work.
    static func companions(for chosen: Set<String>) -> [String] {
        var extra: [String] = []
        if chosen.contains(ask) || chosen.contains(handoff) { extra += thread }
        if chosen.contains(handoff) { extra += tracking }
        return extra
    }

    /// Every action a grant sends: the chosen ones and their companions, limited to what the
    /// resource offers and in the resource's own order.
    static func granted(chosen: Set<String>, offered: [String]) -> [String] {
        let wanted = chosen.union(companions(for: chosen))
        return offered.filter(wanted.contains)
    }

    /// The actions a new resource of this kind is expected to offer. Used only to fill the sheet
    /// before the resource is added; the grant sends what the device agent then lists.
    static func expected(kind: String) -> [String] {
        switch kind {
        case "agent": [ask, handoff]
        case "repo": ["issue.read", "issue.comment", "issue.close", "git.head", "git.commit", "git.push"]
        default: []
        }
    }
}

enum MultiplayerApprovalMode: String, CaseIterable, Identifiable, Sendable {
    case ask, auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask each time"
        case .auto: "Auto within limits"
        }
    }

    var explanation: String {
        switch self {
        case .ask: "Each use waits in Needs you until you approve it. Unanswered requests expire after 24 hours."
        case .auto: "Each use runs at once, until the uses, the expiry or the token budget is reached."
        }
    }
}

enum MultiplayerShareExpiry: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week

    static let `default` = MultiplayerShareExpiry.day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: "1 hour"
        case .day: "1 day"
        case .week: "1 week"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        }
    }
}

enum MultiplayerShareUses: String, CaseIterable, Identifiable, Sendable {
    case one, ten, unlimited

    static let `default` = MultiplayerShareUses.ten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .one: "1 use"
        case .ten: "10 uses"
        case .unlimited: "Unlimited"
        }
    }

    /// The count sent. The device agent has no "no limit", so unlimited is its largest count.
    var count: Int {
        switch self {
        case .one: 1
        case .ten: 10
        case .unlimited: MultiplayerGrantLimits.usesRange.upperBound
        }
    }
}

enum MultiplayerAttribution: String, CaseIterable, Identifiable, Sendable {
    case owner, requester

    var id: String { rawValue }

    var title: String {
        switch self {
        case .owner: "You pay"
        case .requester: "They settle"
        }
    }

    func explanation(handle: String) -> String {
        let who = handle.isEmpty ? "your friend" : handle.multiplayerDisplay
        switch self {
        case .owner: return "Runs on your provider account and counts against this grant’s budget."
        case .requester: return "Runs on your provider account. The usage is recorded for \(who) to settle with you."
        }
    }
}

/// Something in the cockpit the person chose to share: a worker, or a run's repository.
enum MultiplayerShareTarget: Equatable, Sendable {
    case agent(id: String, name: String)
    case repo(path: String, name: String)

    var kind: String {
        switch self {
        case .agent: MultiplayerResourceKind.agent.rawValue
        case .repo: MultiplayerResourceKind.repo.rawValue
        }
    }

    var name: String {
        switch self {
        case .agent(_, let name), .repo(_, let name): name
        }
    }

    /// The worker's ID or the checkout's path: what `resource-add` enrolls.
    var target: String {
        switch self {
        case .agent(let id, _): id
        case .repo(let path, _): path
        }
    }

    /// The same resource ID every time this target is shared, so adding it twice names one resource.
    var resourceID: String {
        let digest = SHA256.hash(data: Data("\(kind)|\(target)".utf8))
        return "res-" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    var summary: String {
        switch self {
        case .agent(_, let name): "Worker \(name.multiplayerDisplay)"
        case .repo(_, let name): "Repository \(name.multiplayerDisplay)"
        }
    }
}

/// The grant sheet: who, what, and the owner's policy for it.
struct MultiplayerShareDraft: Equatable {
    static let budgetLimit = 1_000_000_000

    var server = ""
    var handle = ""
    var resourceID = ""
    /// Set when the sheet was opened from the cockpit. The resource is added first if it's new.
    var target: MultiplayerShareTarget? = nil
    var actions: Set<String> = []
    var approval = MultiplayerApprovalMode.ask
    var expiry = MultiplayerShareExpiry.default
    var uses = MultiplayerShareUses.default
    /// The token budget field as typed. Empty means no token limit.
    var budgetText = ""
    var attribution = MultiplayerAttribution.owner

    /// The budget to send, 0 for none; nil while the field can't be read.
    var budgetTokens: Int? {
        let grouping: Set<Character> = [",", "_", " ", "'", "\u{00A0}", "\u{202F}"]
        let digits = budgetText.trimmingCharacters(in: .whitespacesAndNewlines).filter { !grouping.contains($0) }
        if digits.isEmpty { return 0 }
        guard digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits),
              value <= Self.budgetLimit else { return nil }
        return value
    }

    var budgetProblem: String? {
        budgetTokens == nil ? "Use a whole number of tokens up to 1,000,000,000, or leave it empty for no limit." : nil
    }

    var budgetTitle: String {
        guard let tokens = budgetTokens, tokens > 0 else { return "No token limit" }
        return "\(tokens.formatted()) tokens"
    }

    /// The limits as of `now`: the presets measured from the moment the owner grants.
    func limits(now: Date) -> MultiplayerGrantLimits {
        MultiplayerGrantLimits(maxUses: uses.count, expiresAt: now.addingTimeInterval(expiry.interval))
    }

    /// One `grant` request per action: the chosen ones and their companions among `offered`.
    func grants(kind: String, offered: [String], now: Date) -> [[String: MultiplayerPayloadValue]] {
        guard !handle.isEmpty, !resourceID.isEmpty, let budget = budgetTokens else { return [] }
        let limits = limits(now: now)
        return MultiplayerSharePolicy.granted(chosen: actions, offered: offered).map { action in
            ["handle": .string(handle), "kind": .string(kind), "resource": .string(resourceID),
             "capability": .string(action), "maxUses": .number(limits.maxUses),
             "expiresAt": .string(limits.expiresAtText), "approval": .string(approval.rawValue),
             "budgetTokens": .number(budget), "attribution": .string(attribution.rawValue)]
        }
    }

    /// "Up to 10 uses, for 1 day, no token limit".
    var limitsTitle: String {
        let uses = uses == .unlimited ? "Unlimited uses" : "Up to \(uses.title)"
        return "\(uses), for \(expiry.title), \(budgetTitle.lowercasedFirst)"
    }
}

// MARK: - Consult and Hand off

/// A file attached to a Consult or a Hand off as context.
struct MultiplayerContextItem: Equatable, Sendable, Identifiable {
    let name: String
    let content: String

    var id: String { name }
    var bytes: Int { content.utf8.count }

    var json: MultiplayerJSON { .object(["name": .string(name), "content": .string(content)]) }
}

enum MultiplayerContextBundle {
    /// The device agent's bounds: 16 items, 96 KiB of content in total.
    static let itemLimit = 16
    static let byteLimit = 96 * 1024
    /// Room left for the prompt and the envelope inside the tray's 96 KiB request.
    static let requestHeadroom = 6 * 1024

    static func bytes(_ items: [MultiplayerContextItem]) -> Int { items.reduce(0) { $0 + $1.bytes } }

    static func problem(_ items: [MultiplayerContextItem], prompt: String) -> String? {
        if items.count > itemLimit { return "Attach at most \(itemLimit) files." }
        // JSON escaping grows the text a little, so the bound leaves room for it.
        let total = bytes(items) + prompt.utf8.count
        if total > byteLimit - requestHeadroom { return "The prompt and files come to \(size(total)). Keep them under \(size(byteLimit - requestHeadroom))." }
        return nil
    }

    static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) bytes" : String(format: "%.0f KiB", (Double(bytes) / 1024).rounded(.up))
    }

    /// Reads a text file as one context item, or says why it can't be attached.
    static func read(_ url: URL) -> Result<MultiplayerContextItem, MultiplayerFailure> {
        let name = url.lastPathComponent
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= byteLimit,
              let data = try? Data(contentsOf: url) else {
            return .failure(.invalidInput("\(name.multiplayerDisplay) is larger than 96 KiB or can’t be read."))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.invalidInput("\(name.multiplayerDisplay) isn’t plain text, so it can’t be sent as context."))
        }
        return .success(MultiplayerContextItem(name: name, content: text))
    }

    /// Adds files to a list, keeping one item per file name.
    static func adding(_ new: [MultiplayerContextItem], to items: [MultiplayerContextItem]) -> [MultiplayerContextItem] {
        MultiplayerUnique.keep(new + items.filter { old in !new.contains { $0.name == old.name } }) { $0.name }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The Consult composer: one prompt to a friend's worker, with files as context.
struct MultiplayerConsultDraft: Equatable {
    var prompt = ""
    var context: [MultiplayerContextItem] = []

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    var problem: String? { MultiplayerContextBundle.problem(context, prompt: prompt) }
    var canSend: Bool { !trimmedPrompt.isEmpty && problem == nil }

    var payload: MultiplayerJSON {
        var fields: [String: MultiplayerJSON] = ["text": .string(trimmedPrompt)]
        if !context.isEmpty { fields["context"] = .array(context.map(\.json)) }
        return .object(fields)
    }

    /// The request's name in the sent list: the prompt's first line.
    var title: String { MultiplayerText.clean(trimmedPrompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "", limit: 80) }
}

/// The Hand off composer: a task for a friend's agent to run by itself.
struct MultiplayerHandoffDraft: Equatable {
    var title = ""
    var task = ""
    var context: [MultiplayerContextItem] = []

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedTask: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }

    var problem: String? {
        if trimmedTitle.count > 120 { return "Keep the title under 120 characters." }
        return MultiplayerContextBundle.problem(context, prompt: task)
    }

    var canSend: Bool { !trimmedTitle.isEmpty && !trimmedTask.isEmpty && problem == nil }

    var payload: MultiplayerJSON {
        var fields: [String: MultiplayerJSON] = ["title": .string(trimmedTitle), "task": .string(trimmedTask)]
        if !context.isEmpty { fields["context"] = .array(context.map(\.json)) }
        return .object(fields)
    }
}

/// The request-access form for one directory entry.
struct MultiplayerAccessDraft: Equatable {
    var actions: Set<String> = []
    var note = ""

    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    var problem: String? { trimmedNote.count > 280 ? "Keep the note under 280 characters." : nil }
    var canSend: Bool { !actions.isEmpty && problem == nil }

    func body(resource: String) -> MultiplayerJSON {
        .object(["resource": .string(resource), "actions": .array(actions.sorted().map { .string($0) }),
                 "note": .string(trimmedNote)])
    }
}

extension String {
    /// The same text with a lowercase first letter, for the middle of a sentence.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Helper calls

extension MultiplayerClient {
    /// `send` may carry 96 KiB of context; the device agent's own bound is 98,304 bytes.
    static let sendInputLimit = 96 * 1024

    func approvals() async throws -> [MultiplayerApproval] {
        try await fetch(.approvals, [:], as: MultiplayerApprovalList.self).approvals
    }

    func decide(approval id: String, approve: Bool, reason: String = "") async throws {
        var payload: [String: MultiplayerPayloadValue] = ["id": .string(id)]
        if !approve, !reason.isEmpty { payload["reason"] = .string(reason) }
        _ = try await fetch(approve ? .approve : .deny, payload, as: MultiplayerIgnored.self, allowsEmpty: true)
    }

    func audit(resource: String? = nil, handle: String? = nil) async throws -> [MultiplayerAuditEntry] {
        var payload: [String: MultiplayerPayloadValue] = [:]
        if let resource, !resource.isEmpty { payload["resource"] = .string(resource) }
        if let handle, !handle.isEmpty { payload["handle"] = .string(handle) }
        return try await fetch(.audit, payload, as: MultiplayerAuditLog.self).entries
    }

    /// Submits one request to a friend's resource and returns what came back in the first seconds.
    func send(resource: String, action: String, payload: MultiplayerJSON, name: String = "") async throws -> MultiplayerSentRequest {
        var fields: [String: MultiplayerPayloadValue] = ["resource": .string(resource), "capability": .string(action),
                                                         "payload": .json(payload)]
        if !name.isEmpty { fields["name"] = .string(name) }
        return try await fetch(.send, fields, as: MultiplayerSentRequest.self)
    }

    func handoffs() async throws -> [MultiplayerSentRequest] {
        try await fetch(.handoffs, [:], as: MultiplayerSentList.self).rows
    }

    func thread(request: String) async throws -> MultiplayerThread {
        try await fetch(.thread, ["request": .string(request)], as: MultiplayerThread.self, allowsEmpty: true)
            ?? MultiplayerThread()
    }

    func comment(request: String, text: String) async throws {
        _ = try await fetch(.comment, ["request": .string(request), "text": .string(text)], as: MultiplayerIgnored.self,
                            allowsEmpty: true)
    }

    func applyArtifact(request: String, artifact: Int, checkout: String) async throws {
        _ = try await fetch(.applyArtifact, ["request": .string(request), "artifact": .number(artifact),
                                             "checkout": .string(checkout)], as: MultiplayerIgnored.self, allowsEmpty: true)
    }

    func accessRequests() async throws -> [MultiplayerAccessRequest] {
        try await fetch(.relay, ["method": "GET", "path": "/v1/access-requests"], as: MultiplayerAccessRequestList.self).requests
    }

    func requestAccess(_ body: MultiplayerJSON) async throws {
        _ = try await fetch(.relay, ["method": "POST", "path": "/v1/access-requests", "body": .json(body)],
                            as: MultiplayerIgnored.self, allowsEmpty: true)
    }

    /// Withdraws a request you sent, or declines one sent to you.
    func removeAccessRequest(id: String) async throws {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let part = id.addingPercentEncoding(withAllowedCharacters: allowed), !part.isEmpty else {
            throw MultiplayerFailure.invalidInput("That request can’t be named.")
        }
        _ = try await fetch(.relay, ["method": "DELETE", "path": .string("/v1/access-requests/\(part)")],
                            as: MultiplayerIgnored.self, allowsEmpty: true)
    }

    /// Sends one prepared request, such as a grant with its policy fields.
    func submit(_ verb: MultiplayerVerb, _ payload: [String: MultiplayerPayloadValue]) async throws {
        _ = try await fetch(verb, payload, as: MultiplayerIgnored.self, allowsEmpty: true)
    }

    /// Like `fetch`, for verbs whose success may carry no data.
    func fetch<Reply: Decodable>(_ verb: MultiplayerVerb, _ payload: [String: MultiplayerPayloadValue],
                                 as type: Reply.Type, allowsEmpty: Bool) async throws -> Reply? {
        do {
            return try MultiplayerEnvelope.decode(Reply.self, from: try await call(verb, payload: payload))
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }
}
