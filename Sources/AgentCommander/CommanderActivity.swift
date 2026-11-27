import Foundation

// COMMANDER ACTIVITY
// Pretty reads Commander's own MCP calls (ask, wait, reply, network submit, …) as purposeful
// activity instead of raw tool rows. A small pure projection; the views are in
// CommanderActivityViews.swift.
//
//   Values         CommanderCall              one Commander tool call: its tool, arguments, response, IDs
//                  CommanderActivityStatus    the status word a call or workflow shows
//                  CommanderWorkflow          calls linked by proof, shown as one collapsed disclosure
//   Feature layer  CommanderActivity.items    groups calls in a console's displayed entries
//                  CommanderActivity.annotate attaches the live request state from `run.requests`
//
// Linking rules. Nothing is linked by position or similarity alone:
// - ask, wait, reply and reconcile join only on the exact, whole request ID, within one console;
// - network submit and receipt join only on the exact operation ID;
// - a result joins a question only when the call names its request ID, or when exactly one
//   question was touched in the same uninterrupted turn (no developer prompt between), that
//   question was already answered by an earlier call, it holds no result yet, and no other
//   question in the turn is still unidentified;
// - every other Commander call is its own workflow of one; any other tool is left as it is.
// A workflow sits where its first call was. Every other entry keeps its place and order.

/// One status, as a Commander call or workflow states it. Never a percentage.
enum CommanderActivityStatus: Equatable, Sendable {
    case queued
    case running
    case waitingForReply
    /// A provider permission prompt holds the call. Distinct from an agent's question.
    case awaitingApproval
    case answered
    case complete
    case failed
    case cancelled
    case declined
    case interrupted
    /// Some recipients or parts succeeded and others did not. Never read as complete or failed.
    case partial
    /// The service cannot say whether it took effect (`uncertain`, `delivery_unknown`, `unknown`).
    case uncertain
    /// The call completed and the service accepted the request (a delegation, follow-up, interrupt,
    /// stop or submission). The asynchronous job's own outcome is not known from the call.
    case accepted
    /// A status word the service sent that has no mapping here, shown as sent.
    case reported(String)

    init(_ tool: ToolStatus) {
        switch tool {
        case .running: self = .running
        case .done: self = .complete
        case .failed: self = .failed
        case .declined: self = .declined
        case .cancelled: self = .cancelled
        case .interrupted: self = .interrupted
        case .awaitingApproval: self = .awaitingApproval
        }
    }

    /// A question's status as the service writes it (`pending`, `answered`, `cancelled`).
    init(request status: String) {
        switch status.lowercased() {
        case "pending", "waiting": self = .waitingForReply
        case "answered": self = .answered
        case "cancelled", "canceled": self = .cancelled
        case "failed": self = .failed
        default: self = .reported(status)
        }
    }

    /// An operation's, follow-up's or integration's status as its service writes it: network
    /// receipts, `control.messages[].status` and `integrations[].candidate.status`.
    init(operation status: String) {
        switch status.lowercased() {
        case "queued", "pending", "accepted", "submitted": self = .queued
        // `tested`: the candidate passed its tests and has not advanced the branch yet.
        case "running", "processing", "in_progress", "delivering", "advancing", "testing", "tested", "working", "starting":
            self = .running
        case "completed", "complete", "delivered", "succeeded", "success", "ok", "done", "integrated", "unchanged":
            self = .complete
        case "partial", "mixed": self = .partial
        case "uncertain", "unknown", "delivery_unknown": self = .uncertain
        case "declined", "denied": self = .declined
        case "failed", "error", "rejected", "refused", "conflict", "merge_failed", "preparation_failed",
             "tests_failed", "candidate_changed", "target_changed", "target_dirty":
            self = .failed
        case "cancelled", "canceled": self = .cancelled
        case "interrupted", "stopped": self = .interrupted
        default: self = .reported(status.replacingOccurrences(of: "_", with: " "))
        }
    }

    var word: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .waitingForReply: "Waiting for reply"
        case .awaitingApproval: "Awaiting approval"
        case .answered: "Answered"
        case .complete: "Complete"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .declined: "Declined"
        case .interrupted: "Interrupted"
        case .partial: "Partial"
        case .uncertain: "Uncertain"
        case .accepted: "Accepted"
        case .reported(let word): word.prefix(1).uppercased() + word.dropFirst()
        }
    }

    /// Still in progress: drawn with a subtle indeterminate indicator, never a fraction.
    var isLive: Bool { self == .running || self == .waitingForReply }

    /// Not yet resolved: the developer or the worker still has something to do.
    var isUnresolved: Bool {
        switch self {
        case .queued, .running, .waitingForReply, .awaitingApproval: true
        default: false
        }
    }
}

// MARK: - One call

struct CommanderCall: Equatable {
    let entry: TranscriptEntry
    let tool: CommanderTool
    let detail: String?
    let result: ToolResult?
    /// The arguments object, when `detail` is JSON.
    let arguments: [String: AGUIValue]?
    /// `detail` when it is plain text, such as the question or worker name a provider reported.
    let plainDetail: String?
    /// The response read through any MCP wrapper. Nil while running or when it is not JSON.
    let response: AGUIValue?
    let facts: CommanderCallFacts?
    let isAwaitingApproval: Bool

    init?(entry: TranscriptEntry, awaitingToolID: String? = nil) {
        guard case .tool(let name, let detail, let result) = entry.kind, let tool = CommanderTool(name: name) else { return nil }
        self.entry = entry
        self.tool = tool
        self.detail = detail
        self.result = result
        let parsed = CommanderPayload.value(detail)
        arguments = parsed?.objectValue
        let text = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An ACP placeholder such as `other` is not the call's detail.
        plainDetail = parsed == nil && !text.isEmpty && !ToolDetailText.isPlaceholder(text) ? text : nil
        // A failed call's output is its error text, not the service's record.
        response = result.flatMap { $0.error == nil ? CommanderPayload.value($0.output) : nil }
        facts = entry.commander
        isAwaitingApproval = result == nil && entry.id == awaitingToolID
    }

    var toolStatus: ToolStatus {
        isAwaitingApproval ? .awaitingApproval : ToolStatus(result: result)
    }

    func argument(_ key: String) -> String? { Self.text(arguments?[key]) }
    func field(_ key: String) -> String? { Self.text(response?[key]) }

    /// The exact request this call is about. The correlation object wins; then the call's own
    /// `request_id`; then the ID of the request record it returned.
    var requestID: String? {
        if let id = facts?.requestID { return id }
        switch tool {
        case .ask: return field("id")
        case .wait, .reply, .reconcileReply: return argument("request_id") ?? field("id")
        default: return nil
        }
    }

    /// The exact operation this call is about: a network operation, or the follow-up message or
    /// integration a call created.
    var operationID: String? {
        if let id = facts?.operationID { return id }
        switch tool {
        case .networkSubmit, .networkReceipt:
            return argument("id") ?? field("id") ?? field("operationId") ?? field("operation_id")
        case .send, .integrate:
            return field("id")
        default: return nil
        }
    }

    /// The response is the record of this call's request: it names no other request. When the
    /// call's request is known from the correlation object or its own `request_id`, a response
    /// with a different `id` is someone else's record and none of its fields are read.
    var responseIsThisRequest: Bool {
        guard tool.family == .request, let response, response["question"] != nil || response["id"] != nil else { return false }
        let known = facts?.requestID ?? (tool == .ask ? nil : argument("request_id"))
        guard let known, let returned = field("id") else { return true }
        return known == returned
    }

    /// A reply that succeeded for its own request: its result is this request's record, or (on
    /// an older record) names no request at all, so the call's own `request_id` stands. A
    /// result naming a different request never confirms this one.
    var replyConfirmsRequest: Bool {
        guard tool == .reply, let result, result.error == nil else { return false }
        return responseIsThisRequest || field("id") == nil
    }

    /// The request's status as this call saw it.
    var requestState: String? {
        if let status = facts?.requestStatus { return status }
        return responseIsThisRequest ? field("status") : nil
    }

    /// The operation's current status: the run's live record first, then what the call carried,
    /// then its response. An older receipt without the service's `operationStatus` is read from
    /// its recipients (`children` in the relay's shape); see `aggregate`.
    var operationState: String? {
        if let live = facts?.liveOperationStatus { return live }
        if let status = facts?.operationStatus { return status }
        switch tool {
        case .networkSubmit, .networkReceipt:
            let outcomes = recipients.compactMap { Self.text($0["status"] ?? $0["outcome"] ?? $0["state"]) }
            if let combined = Self.aggregate(outcomes) { return combined }
            return field("status") ?? field("state")
        case .send, .integrate, .delegate, .interrupt, .stopWorker:
            return field("status") ?? field("state") ?? Self.text(response?["candidate"]?["status"])
        default: return nil
        }
    }

    /// One status for an operation's recipients. Any recipient still processing keeps it Running;
    /// otherwise any still pending keeps it Queued. Only when every recipient is terminal does it
    /// settle: their one shared status, or `partial` when they differ, even if some completed.
    /// Nil without recipients.
    static func aggregate(_ outcomes: [String]) -> String? {
        guard !outcomes.isEmpty else { return nil }
        let statuses = outcomes.map { CommanderActivityStatus(operation: $0) }
        if statuses.contains(.running) { return "processing" }
        if statuses.contains(.queued) { return "pending" }
        // Compared by what each status means, so `completed` and `delivered` agree.
        return Set(statuses.map(\.word)).count == 1 ? outcomes[0] : "partial"
    }

    private var recipients: [AGUIValue] {
        // The relay's receipt holds per-recipient outcomes under `children`.
        (response?["children"] ?? response?["recipients"] ?? response?["outcomes"] ?? response?["targets"] ?? response?["results"])?.arrayValue ?? []
    }

    /// The worker a follow-up, interrupt or stop addressed, exactly as the call named it.
    var targetWorker: String? { argument("worker_id") ?? facts?.workerID }

    /// The full revision a commit returned, or a result reports. Compared whole, never shortened.
    var revision: String? {
        switch tool {
        case .commit: field("revision")
        case .result: argument("revision")
        default: nil
        }
    }

    /// The answer this call returned or sent.
    var answer: String? {
        if let live = facts?.liveAnswer { return live }
        switch tool {
        case .reply: return argument("answer") ?? (responseIsThisRequest ? field("answer") : nil)
        case .wait, .ask, .reconcileReply: return responseIsThisRequest ? field("answer") : nil
        default: return nil
        }
    }

    var question: String? {
        let returned = responseIsThisRequest ? field("question") : nil
        return tool == .ask ? (argument("question") ?? plainDetail ?? returned) : returned
    }

    var status: CommanderActivityStatus {
        let tool = toolStatus
        switch tool {
        case .awaitingApproval: return .awaitingApproval
        case .running: return self.tool == .wait ? .waitingForReply : .running
        case .done: break
        default: return CommanderActivityStatus(tool)
        }
        if self.tool.family == .request, let state = requestState { return CommanderActivityStatus(request: state) }
        // A reply whose result names another request cannot say this one was answered.
        if self.tool == .reply { return replyConfirmsRequest ? .answered : .uncertain }
        // Only a record that is the operation itself gives its status. A delegated, interrupted
        // or stopped worker's own state is in the summary: the call completed, which says only
        // that the service accepted the request, never that the job finished.
        switch self.tool {
        case .send, .integrate, .networkSubmit, .networkReceipt:
            if let state = operationState { return CommanderActivityStatus(operation: state) }
            return self.tool == .networkReceipt ? .complete : .accepted
        case .delegate, .interrupt, .stopWorker:
            return .accepted
        default:
            return .complete
        }
    }

    // MARK: Summaries

    /// What the call asked for, from its arguments.
    var argumentSummary: String? {
        let summary: String?
        switch tool {
        case .delegate:
            summary = Self.join(argument("name") ?? plainDetail, argument("kind"), argument("host").map { "on \($0)" })
        case .ask:
            summary = question.map(Self.quote)
        case .wait:
            summary = Self.join(requestID.map(Self.request), argument("timeout_seconds").map { "up to \($0)s" })
        case .reply:
            summary = Self.join(requestID.map(Self.request), argument("answer").map(Self.quote))
        case .reconcileReply:
            summary = requestID.map(Self.request)
        case .result:
            summary = Self.join(argument("result").map(Self.firstLine) ?? plainDetail.map(Self.firstLine),
                                argument("revision").map { "rev \(Identifier.short($0))" },
                                Self.count(arguments?["tests"], "test"))
        case .commit:
            summary = Self.join(argument("message").map(Self.firstLine), Self.count(arguments?["files"], "file"))
        case .integrate:
            summary = Self.count(arguments?["worker_ids"], "worker")
        case .send:
            summary = Self.join(argument("worker_id").map(Self.worker), argument("text").map(Self.quote))
        case .interrupt, .stopWorker:
            summary = (argument("worker_id") ?? facts?.workerID).map(Self.worker)
        case .status:
            summary = argument("wait_seconds").flatMap { $0 == "0" ? nil : "wait up to \($0)s" }
        case .callTool:
            summary = Self.join(argument("id"), argument("version").map { "v\($0)" })
        case .callFrontend:
            summary = argument("name") ?? plainDetail
        case .networkSubmit:
            let targets = arguments?["targets"]?.arrayValue ?? []
            let actions = Array(Set(targets.compactMap { $0["action"]?.stringValue })).sorted()
            summary = Self.join(operationID.map(Self.operation), Self.count(arguments?["targets"], "target"),
                                actions.isEmpty ? nil : actions.joined(separator: ", "))
        case .networkReceipt:
            summary = operationID.map(Self.operation)
        case .networkThread:
            summary = Self.join(argument("request").map(Self.request), argument("text").map(Self.quote))
        case .networkBoard:
            summary = Self.join(argument("op") ?? "list", argument("workspace"), argument("card"))
        case .listTools, .frontendTools, .networkInbox, .networkDiscover, .networkOnline:
            summary = plainDetail
        }
        return summary ?? plainDetail
    }

    /// What the call returned, from its response's fields. Nil while it runs or when the
    /// response has none of the fields this tool is known to return.
    var responseSummary: String? {
        guard let response else { return nil }
        switch tool {
        case .delegate:
            return Self.join(field("name"), field("id").map(Self.worker), field("state"))
        case .ask:
            return requestID.map(Self.request)
        case .wait, .reconcileReply:
            guard responseIsThisRequest else { return nil }
            if let answer = field("answer"), !answer.isEmpty { return "answer " + Self.quote(answer) }
            return Self.join(field("status"), field("delivery").map { "delivery \($0)" })
        case .reply:
            guard responseIsThisRequest else { return nil }
            return Self.join(field("status"), field("delivery").map { "delivery \($0)" })
        case .result, .commit:
            return Self.join(field("revision").map { "rev \(Identifier.short($0))" }, field("status"))
        case .integrate, .send, .interrupt, .stopWorker:
            return Self.join(operationState?.replacingOccurrences(of: "_", with: " "), field("revision").map { "rev \(Identifier.short($0))" })
        case .status:
            let workers = response["workers"]?.arrayValue ?? []
            let pending = (response["requests"]?.arrayValue ?? []).filter { $0["status"]?.stringValue == "pending" }.count
            var states: [String: Int] = [:]
            for worker in workers { if let state = worker["state"]?.stringValue { states[state, default: 0] += 1 } }
            let stateText = states.keys.sorted().map { "\(states[$0]!) \($0)" }.joined(separator: ", ")
            return Self.join(Self.count(response["workers"], "worker"), stateText.isEmpty ? nil : stateText,
                             pending > 0 ? (pending == 1 ? "1 pending request" : "\(pending) pending requests") : nil,
                             field("status").map { "run \($0)" })
        case .listTools, .frontendTools:
            return Self.count(response.arrayValue != nil ? response : response["tools"], "tool")
        case .networkDiscover:
            return Self.count(response.arrayValue != nil ? response : (response["resources"] ?? response["peers"]), "resource")
        case .networkInbox:
            return Self.count(response.arrayValue != nil ? response : response["messages"], "message")
        case .networkOnline:
            return Self.count(response["friends"], "contact")
        case .networkThread:
            return Self.count(response["comments"] ?? response["thread"], "comment")
        case .networkBoard:
            return Self.count(response["cards"] ?? response["workspaces"], response["cards"] != nil ? "card" : "workspace") ?? field("state")
        case .networkSubmit, .networkReceipt:
            var outcomes: [String: Int] = [:]
            for item in recipients {
                if let state = (item["status"] ?? item["outcome"] ?? item["state"])?.stringValue {
                    outcomes[state, default: 0] += 1
                }
            }
            let outcomeText = outcomes.keys.sorted().map { "\(outcomes[$0]!) \($0)" }.joined(separator: ", ")
            return Self.join(field("status") ?? field("state"),
                             recipients.isEmpty ? nil : Self.count(.array(recipients), "recipient"),
                             outcomeText.isEmpty ? nil : outcomeText)
        case .callTool, .callFrontend:
            if let text = response.stringValue { return Self.firstLine(text) }
            return Self.join(field("status"), field("content").map(Self.firstLine))
        }
    }

    // MARK: Helpers

    static func text(_ value: AGUIValue?) -> String? {
        guard let value else { return nil }
        let text: String
        switch value {
        case .string(let string): text = string
        case .number(let number): text = number.literal
        case .bool(let bool): text = bool ? "true" : "false"
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func join(_ parts: String?...) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    static func count(_ value: AGUIValue?, _ noun: String) -> String? {
        guard let items = value?.arrayValue else { return nil }
        return items.count == 1 ? "1 \(noun)" : "\(items.count) \(noun)s"
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    static func quote(_ text: String) -> String { "“\(firstLine(text))”" }
    static func request(_ id: String) -> String { "request \(Identifier.short(id))" }
    static func operation(_ id: String) -> String { "operation \(Identifier.short(id))" }
    static func worker(_ id: String) -> String { "worker \(Identifier.short(id))" }
}

// MARK: - Workflow

/// Calls linked by proof, shown as one disclosure where the first of them was. Opening it shows
/// every original call, in order, with its own detail, result, error and fields.
struct CommanderWorkflow: Identifiable, Equatable {
    enum Link: Equatable {
        case request(String)
        case operation(String)
        /// A commit and the result that reports its exact, full revision.
        case revision(String)
        /// One call, linked to nothing.
        case single
    }

    private static let suffix = "#commander"

    /// Depends only on the first call, so the disclosure keeps its place and open state.
    let id: String
    var link: Link
    var calls: [CommanderCall]

    init(first: CommanderCall, link: Link) {
        id = first.entry.id + Self.suffix
        self.link = link
        calls = [first]
    }

    var entries: [TranscriptEntry] { calls.map(\.entry) }

    private var questionCalls: [CommanderCall] { calls.filter { $0.tool.family == .request } }
    var report: CommanderCall? { calls.last { $0.tool == .result } }

    /// The request's current status from the run, when the projection found it.
    var liveRequestStatus: String? { calls.compactMap { $0.facts?.liveRequestStatus }.last }

    /// The question was answered by one of the calls themselves (not merely by the run now).
    var hasAnsweredCall: Bool {
        questionCalls.contains { $0.requestState?.lowercased() == "answered" || $0.replyConfirmsRequest }
    }

    var status: CommanderActivityStatus {
        if calls.contains(where: \.isAwaitingApproval) { return .awaitingApproval }
        switch link {
        case .single:
            return calls[0].status
        case .revision:
            // The latest step speaks: the commit, then the result that reported it.
            return calls.last!.status
        case .operation:
            // An open call, or a call that ended without succeeding, is the newest word: a
            // receipt error is never hidden behind an earlier Queued.
            if let last = calls.last, last.toolStatus != .done { return last.status }
            if let state = calls.compactMap(\.operationState).last { return CommanderActivityStatus(operation: state) }
            return calls.last!.status
        case .request:
            let question = questionStatus
            // A grouped result speaks for the workflow once the question is resolved.
            if let report, question == .answered { return report.status }
            return question
        }
    }

    private var questionStatus: CommanderActivityStatus {
        let asked = questionCalls
        if let live = liveRequestStatus { return CommanderActivityStatus(request: live) }
        if let open = asked.last, open.result == nil { return open.status }
        if let state = asked.compactMap(\.requestState).last { return CommanderActivityStatus(request: state) }
        return asked.last?.status ?? .complete
    }

    var symbol: String {
        switch link {
        case .request: calls.contains { $0.tool == .ask } ? CommanderTool.ask.symbol : calls[0].tool.symbol
        case .operation: CommanderTool.networkSubmit.symbol
        case .revision, .single: calls[0].tool.symbol
        }
    }

    var title: String {
        switch link {
        case .request:
            if calls.contains(where: { $0.tool == .ask }) { return report == nil ? "Question" : "Question and result" }
            return calls[0].tool.label
        case .operation:
            return calls.contains { $0.tool == .networkSubmit } ? "Network operation" : calls[0].tool.label
        case .revision:
            return report == nil ? calls[0].tool.label : "Commit and result"
        case .single:
            return calls[0].tool.label
        }
    }

    /// What it is about: the question, the operation's targets, or the call's arguments.
    var summary: String? {
        switch link {
        case .request:
            if let question = calls.compactMap(\.question).first { return CommanderCall.quote(question) }
            return calls.compactMap(\.argumentSummary).first
        case .operation:
            return (calls.first { $0.tool == .networkSubmit } ?? calls[0]).argumentSummary
        case .revision, .single:
            return calls[0].argumentSummary
        }
    }

    /// What came back: the answer, the latest receipt, or the call's response.
    var outcome: String? {
        switch link {
        case .request:
            var parts: [String] = []
            if let answer = calls.compactMap(\.answer).last { parts.append("answer " + CommanderCall.quote(answer)) }
            if let report { parts.append(report.argumentSummary.map { "result \($0)" } ?? "result") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .operation:
            return calls.compactMap(\.responseSummary).last
        case .revision:
            if let report { return report.argumentSummary.map { "result \($0)" } ?? "result" }
            return calls[0].responseSummary
        case .single:
            return calls[0].responseSummary
        }
    }

    /// The exact ID that links the calls, for help and accessibility; shown shortened.
    var reference: String? {
        switch link {
        case .request(let id): "request \(id)"
        case .operation(let id): "operation \(id)"
        case .revision(let revision): "revision \(revision)"
        case .single: nil
        }
    }

    /// The calls in order as steps, repeated ones counted: `Ask · Wait ×3 · Result`. Nil for one call.
    var steps: String? {
        guard calls.count > 1 else { return nil }
        var runs: [(String, Int)] = []
        for call in calls {
            if let last = runs.last, last.0 == call.tool.stepName { runs[runs.count - 1].1 += 1 } else { runs.append((call.tool.stepName, 1)) }
        }
        return runs.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: " · ")
    }

    var failedCalls: Int {
        calls.filter { ToolStatus(result: $0.result) == .failed }.count
    }

    var accessibilityLabel: String {
        var parts = ["Commander \(title)"]
        if let summary { parts.append(summary) }
        if let outcome { parts.append(outcome) }
        parts.append(status.word)
        parts.append(calls.count == 1 ? "1 call" : "\(calls.count) calls")
        if failedCalls > 0 { parts.append(failedCalls == 1 ? "1 failed call" : "\(failedCalls) failed calls") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Projection

enum CommanderItem: Equatable {
    case entry(TranscriptEntry)
    case workflow(CommanderWorkflow)
}

enum CommanderActivity {
    /// The entries in order, with each Commander call in a workflow. Every entry appears exactly
    /// once: as itself, or inside the one workflow that holds it.
    static func items(_ entries: [TranscriptEntry], awaitingToolID: String? = nil) -> [CommanderItem] {
        enum Slot { case entry(TranscriptEntry), workflow(Int) }
        var slots: [Slot] = []
        slots.reserveCapacity(entries.count)
        var workflows: [CommanderWorkflow] = []
        var byRequest: [String: Int] = [:]
        var byOperation: [String: Int] = [:]
        var byRevision: [String: Int] = [:]
        // This turn: question workflows touched, and whether a question has no ID yet.
        var turnQuestions: [Int] = []
        var turnHasUnidentifiedQuestion = false

        func open(_ call: CommanderCall, _ link: CommanderWorkflow.Link) -> Int {
            workflows.append(CommanderWorkflow(first: call, link: link))
            slots.append(.workflow(workflows.count - 1))
            return workflows.count - 1
        }

        for entry in entries {
            if entry.isFromUser {
                turnQuestions = []
                turnHasUnidentifiedQuestion = false
                slots.append(.entry(entry))
                continue
            }
            guard let call = CommanderCall(entry: entry, awaitingToolID: awaitingToolID) else {
                slots.append(.entry(entry))
                continue
            }
            switch call.tool.family {
            case .request:
                if let id = call.requestID {
                    let index: Int
                    if let known = byRequest[id] {
                        workflows[known].calls.append(call)
                        index = known
                    } else {
                        index = open(call, .request(id))
                        byRequest[id] = index
                    }
                    if !turnQuestions.contains(index) { turnQuestions.append(index) }
                } else {
                    _ = open(call, .single)
                    // An ask with no request yet may be a second question: no result can be
                    // placed with certainty in this turn. A failed ask created none.
                    if call.tool == .ask, ToolStatus(result: call.result) != .failed { turnHasUnidentifiedQuestion = true }
                }
            case .operation:
                if let id = call.operationID {
                    if let known = byOperation[id] {
                        workflows[known].calls.append(call)
                    } else {
                        byOperation[id] = open(call, .operation(id))
                    }
                } else {
                    _ = open(call, .single)
                }
            case .report:
                // An exact, full revision a commit in this console returned is the strongest link.
                if let revision = call.revision, let known = byRevision[revision], workflows[known].report == nil {
                    workflows[known].calls.append(call)
                } else if let id = call.facts?.requestID, let known = byRequest[id], workflows[known].report == nil {
                    workflows[known].calls.append(call)
                } else if call.facts?.requestID == nil, turnQuestions.count == 1, !turnHasUnidentifiedQuestion,
                          workflows[turnQuestions[0]].report == nil, workflows[turnQuestions[0]].hasAnsweredCall {
                    workflows[turnQuestions[0]].calls.append(call)
                } else {
                    _ = open(call, .single)
                }
            case .standalone:
                // A commit that returned its revision can be named by a later result. A second
                // commit returning the same revision stays apart: the link must be unambiguous.
                if call.tool == .commit, let revision = call.revision, byRevision[revision] == nil {
                    byRevision[revision] = open(call, .revision(revision))
                } else {
                    _ = open(call, .single)
                }
            }
        }
        return slots.map { slot in
            switch slot {
            case .entry(let entry): .entry(entry)
            case .workflow(let index): .workflow(workflows[index])
            }
        }
    }

    /// The workflow of one exact request, linked over a console's whole transcript. A surface that
    /// shows only a recent window (the PiP) anchors its request's story with it, so the Ask and
    /// every original call stay with the request however short the window. Nil when no Commander
    /// call names the request (an ACP permission request, for one).
    static func workflow(request id: String, in entries: [TranscriptEntry],
                         awaitingToolID: String? = nil) -> CommanderWorkflow? {
        for item in items(TranscriptEntry.displayed(entries, mode: .pretty), awaitingToolID: awaitingToolID) {
            if case .workflow(let flow) = item, flow.link == .request(id) { return flow }
        }
        return nil
    }

    /// The entries with each Commander call given the current state of what it is about, read
    /// from the run by exact ID: a request's status and answer, a follow-up's status on its target
    /// worker, an integration's candidate status. Every other entry is unchanged.
    static func annotate(_ entries: [TranscriptEntry], live: CommanderLiveState) -> [TranscriptEntry] {
        guard !live.isEmpty else { return entries }
        return entries.map { entry in
            guard let call = CommanderCall(entry: entry) else { return entry }
            var facts = entry.commander ?? CommanderCallFacts()
            if call.tool.family == .request || call.tool == .result, let id = call.requestID, let request = live.requests[id] {
                facts.liveRequestStatus = request.status.isEmpty ? nil : request.status
                facts.liveAnswer = request.answer.isEmpty ? nil : request.answer
            } else if call.tool == .send, let id = call.operationID, let worker = call.targetWorker,
                      let status = live.followUps[worker]?[id] {
                facts.liveOperationStatus = status
            } else if call.tool == .integrate, let id = call.operationID, let status = live.integrations[id] {
                facts.liveOperationStatus = status
            } else if call.tool == .delegate, let id = call.field("id"), let state = live.workers[id] {
                // The delegated worker's state now, by the exact ID the call returned.
                facts.liveOperationStatus = state
            } else if call.tool == .interrupt || call.tool == .stopWorker, let id = call.targetWorker,
                      let state = live.workers[id] {
                facts.liveOperationStatus = state
            } else {
                return entry
            }
            var annotated = entry
            annotated.commander = facts
            return annotated
        }
    }

    static func annotate(_ entries: [TranscriptEntry], requests: [Question]) -> [TranscriptEntry] {
        annotate(entries, live: CommanderLiveState(requests: requests))
    }
}

/// The current state the workspace projection already holds for one run, by exact ID. Read
/// once per projection; nothing here polls or calls the service.
struct CommanderLiveState: Equatable {
    var requests: [String: Question] = [:]
    /// Integration ID → `candidate.status`, from the run's `integrations` member.
    var integrations: [String: String] = [:]
    /// Worker ID → follow-up message ID → status, from each worker's `control.messages`.
    var followUps: [String: [String: String]] = [:]
    /// Worker ID → the worker's state as the service writes it.
    var workers: [String: String] = [:]

    var isEmpty: Bool { requests.isEmpty && integrations.isEmpty && followUps.isEmpty && workers.isEmpty }

    init(requests: [Question] = [], integrations: [String: String] = [:], followUps: [String: [String: String]] = [:],
         workers: [String: String] = [:]) {
        self.requests = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.integrations = integrations
        self.followUps = followUps
        self.workers = workers
    }

    init(run: Run) {
        var integrations: [String: String] = [:]
        for item in run.allFields["integrations"]?.arrayValue ?? [] {
            if let id = item["id"]?.stringValue, let status = item["candidate"]?["status"]?.stringValue, !status.isEmpty {
                integrations[id] = status
            }
        }
        var followUps: [String: [String: String]] = [:]
        for worker in run.workers ?? [] {
            for message in worker.control?.messages ?? [] where !message.status.isEmpty {
                followUps[worker.id, default: [:]][message.id] = message.status
            }
        }
        var states: [String: String] = [:]
        for worker in run.workers ?? [] where !worker.state.isEmpty { states[worker.id] = worker.state }
        self.init(requests: run.requests ?? [], integrations: integrations, followUps: followUps, workers: states)
    }
}
