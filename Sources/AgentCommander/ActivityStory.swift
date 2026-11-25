import Foundation

// ACTIVITY STORY
// The narrative presentation of tool activity in Pretty: what was asked or done, what came back,
// and what is still needed. A pure presentation model; the views are in ActivityStoryViews.swift.
//
//   Values      ActivityStory            one card's story: lead, context, status, milestones,
//                                        relations, copyable outcome and its exact evidence
//               ActivityMilestone        one verified step on the story's timeline
//               ActivityRelation         an exact related identity (request, worker, revision, …)
//               ActivityStoryScope       what the parent surface can act on, by exact request ID
//               ActivityStoryIntent      a typed targeted action a card emits
//   Renderers   ActivityStoryRenderer    the one interface every specialised renderer implements
//               QuestionStoryRenderer    ask, wait, reply, reconcile and the linked result
//               RelayStoryRenderer       network submit and receipts of one operation
//               ChangeStoryRenderer      a commit and the result that reports its full revision
//               CommanderCallStoryRenderer  any other single Commander call, by domain
//               ProviderToolStoryRenderer   recognised provider tools (read, edit, search, shell, web)
//   Assembly    ActivityStory.assemble   the shared rules: failures, evidence, accessibility
//               ActivityStories          picks the renderer for a workflow or an entry
//
// Rules every renderer keeps:
// - nothing is inferred: no intent, outcome, percentage, timestamp or association beyond what a
//   call's own record or the run's record (by exact ID) states;
// - repeated wait probes are evidence, never milestones; the timeline shows a waiting state once;
// - every original call stays in `evidence`, in order, and is drawn by the raw tool row;
// - a failed call always surfaces: as a milestone on a timeline, or in the context line;
// - a completed tool call is not a completed asynchronous job: a delegation, follow-up or stop
//   reads as Accepted until the run's record states the outcome.

struct ActivityMilestone: Identifiable, Equatable {
    enum Kind: Equatable {
        case asked, waiting, answered, replied, reconciled, reporting, reported
        case submitted, receipt, committed, closed, failed
    }

    /// Stable as facts update: the source call's entry ID (plus a role suffix), or the story's
    /// ID plus a role for a state that has no single source call.
    let id: String
    let kind: Kind
    let label: String
    var detail: String? = nil
    let status: CommanderActivityStatus
    /// The exact original calls that state this milestone. Empty when the run's record states it.
    var entryIDs: [String] = []
}

struct ActivityRelation: Identifiable, Equatable {
    enum Kind: String { case request, worker, operation, revision, test, file, tool }
    let kind: Kind
    /// The exact identity, never shortened.
    let value: String
    /// How the relation reads; may shorten an ID. The exact value is in its help and label.
    let label: String
    var id: String { kind.rawValue + ":" + value }
}

/// What a specialised renderer supplies. `ActivityStory.assemble` adds the shared parts.
struct ActivityStoryContent: Equatable {
    var symbol: String
    /// What kind of activity this is, such as `Decision needed`, `Question and result`, `Read file`.
    var kind: String
    /// The headline: a terminal answer or outcome, the decision needed, or the subject.
    var lead: String? = nil
    /// The second line: what it was about, who is needed, the exact reference shortened.
    var context: String? = nil
    var milestones: [ActivityMilestone] = []
    var relations: [ActivityRelation] = []
    /// The exact outcome text the Copy action copies. Nil where there is none worth copying.
    var outcome: String? = nil
    /// The exact request this story is about, for scoping a reply or approval action.
    var requestID: String? = nil
    /// The exact linking ID for help and accessibility.
    var reference: String? = nil
}

struct ActivityStory: Identifiable, Equatable {
    let id: String
    let symbol: String
    let kind: String
    let lead: String?
    let context: String?
    let status: CommanderActivityStatus
    let milestones: [ActivityMilestone]
    let relations: [ActivityRelation]
    let outcome: String?
    let requestID: String?
    let reference: String?
    /// Every original entry, in order. The Tool details disclosure draws each with the raw row.
    let evidence: [TranscriptEntry]
    /// The step trail of the original calls (`Ask · Wait ×7 · Result`), for the details label.
    let steps: String?
    let failedCalls: Int
    /// A call's arguments are structured (a JSON object). The raw row then stays behind Tool
    /// details even for a one-call story, so the first expansion is not a wall of JSON.
    let hasStructuredDetail: Bool

    /// A one-call story with only a plain detail shows its raw row directly when opened; every
    /// other story keeps its original calls behind the nested Tool details disclosure.
    var showsEvidenceDirectly: Bool { milestones.isEmpty && !hasStructuredDetail }

    /// The request is still waiting for a reply.
    var isDecisionPending: Bool { requestID != nil && status == .waitingForReply }

    /// The shared assembly. A failed call that no milestone already states becomes one failure
    /// milestone per distinct step and error (`×n` when repeated); a story without a timeline
    /// leads its context with the first failure instead.
    static func assemble(id: String, status: CommanderActivityStatus, evidence: [TranscriptEntry],
                         steps: String? = nil, content: ActivityStoryContent) -> ActivityStory {
        var milestones = content.milestones
        var context = content.context
        let stated = Set(milestones.flatMap(\.entryIDs))
        var failures: [(key: String, milestone: ActivityMilestone)] = []
        var failedCalls = 0
        for entry in evidence {
            guard case .tool(let name, _, let result) = entry.kind, let result,
                  ToolStatus(result: result) == .failed else { continue }
            failedCalls += 1
            guard !stated.contains(entry.id) else { continue }
            let step = CommanderTool(name: name)?.stepName ?? name
            let error = result.error.map(CommanderCall.firstLine) ?? "Failed"
            let key = step + "\u{1F}" + error
            if let index = failures.firstIndex(where: { $0.key == key }) {
                failures[index].milestone.entryIDs.append(entry.id)
            } else {
                failures.append((key, ActivityMilestone(id: entry.id + "#failed", kind: .failed, label: "\(step) failed",
                                                         detail: error, status: .failed, entryIDs: [entry.id])))
            }
        }
        if milestones.isEmpty {
            if let first = failures.first { context = CommanderCall.join(first.milestone.detail, context) }
        } else {
            for failure in failures {
                var milestone = failure.milestone
                if milestone.entryIDs.count > 1 {
                    milestone = ActivityMilestone(id: milestone.id, kind: .failed,
                                                  label: "\(milestone.label) ×\(milestone.entryIDs.count)",
                                                  detail: milestone.detail, status: .failed, entryIDs: milestone.entryIDs)
                }
                // In order of the call that first failed, among the calls' own milestones.
                let firstIndex = evidence.firstIndex { $0.id == milestone.entryIDs[0] } ?? evidence.count
                let position = milestones.firstIndex { other in
                    guard let source = other.entryIDs.first,
                          let index = evidence.firstIndex(where: { $0.id == source }) else {
                        // A state with no source call (waiting, the run's answer) stays last.
                        return true
                    }
                    return index > firstIndex
                } ?? milestones.count
                milestones.insert(milestone, at: position)
            }
        }
        return ActivityStory(id: id, symbol: content.symbol, kind: content.kind, lead: content.lead, context: context,
                             status: status, milestones: milestones, relations: content.relations,
                             outcome: content.outcome, requestID: content.requestID, reference: content.reference,
                             evidence: evidence, steps: steps, failedCalls: failedCalls,
                             hasStructuredDetail: evidence.contains { entry in
                                 guard case .tool(_, let detail, _) = entry.kind else { return false }
                                 return CommanderPayload.value(detail)?.objectValue != nil
                             })
    }

    /// The timeline a bounded surface shows: the first milestone and the latest ones, with how
    /// many are left out. Every milestone stays in the story; nothing is dropped from evidence.
    func timeline(limit: Int?) -> (shown: [ActivityMilestone], hidden: Int) {
        guard let limit, limit >= 2, milestones.count > limit else { return (milestones, 0) }
        let tail = milestones.suffix(limit - 1)
        return ([milestones[0]] + tail, milestones.count - limit)
    }

    var accessibilityLabel: String {
        var parts = [kind]
        if let lead { parts.append(lead) }
        if let context { parts.append(context) }
        parts.append(status.word)
        if evidence.count > 1 { parts.append("\(evidence.count) tool calls") }
        if failedCalls > 0 { parts.append(failedCalls == 1 ? "1 failed call" : "\(failedCalls) failed calls") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Scope and intents

/// What the parent surface can act on. Built from the parent's own request and actions; a card
/// offers an action only for a request named here by its exact ID.
struct ActivityStoryScope: Equatable {
    struct Request: Equatable {
        enum Route: Equatable {
            /// The parent shows this request's one `PrettyRequestForm`; the action focuses it.
            case form
            /// The parent opens the request where it is answered (Attention, the focused worker).
            case open
        }
        let id: String
        let route: Route
        /// Who holds input for the asking worker, as its ownership cue names them. Nil when unknown.
        var holder: String? = nil
        var offersChoices = false
        /// The one open call this request's approval holds, resolved from the whole transcript.
        var awaitingToolID: String? = nil
        /// The parent's form can take input now: online, reply not closed, no send in flight. A
        /// form route is offered only then; an open route stays valid for inspecting it.
        var acceptsInput = true

        init(id: String, route: Route, holder: String? = nil, offersChoices: Bool = false,
             awaitingToolID: String? = nil, acceptsInput: Bool = true) {
            self.id = id
            self.route = route
            self.holder = holder
            self.offersChoices = offersChoices
            self.awaitingToolID = awaitingToolID
            self.acceptsInput = acceptsInput
        }

        init(_ request: RequestPresentation, route: Route, acceptsInput: Bool = true) {
            self.init(id: request.id, route: route,
                      // The coordinator's own question is the developer's to answer.
                      // The run title names no person or worker, so it is no holder either.
                      holder: request.workerIsCoordinator || request.inputHolder.isEmpty
                          || request.inputHolder == request.runTitle ? nil : request.inputHolder,
                      offersChoices: !request.choices.isEmpty,
                      awaitingToolID: request.awaitingApprovalToolID,
                      acceptsInput: acceptsInput)
        }
    }

    var requests: [Request] = []
    var canCopy = true
    var canOpenSource = false

    func request(_ id: String?) -> Request? {
        guard let id else { return nil }
        return requests.first { $0.id == id }
    }

    /// The request a story's targeted action addresses: a pending question by its exact ID, or
    /// the approval that holds one of the story's own calls.
    func request(for story: ActivityStory) -> Request? {
        if story.isDecisionPending, let request = request(story.requestID) { return request }
        if story.status == .awaitingApproval {
            let ids = Set(story.evidence.map(\.id))
            return requests.first { request in request.awaitingToolID.map { ids.contains($0) } == true }
        }
        return nil
    }
}

enum ActivityStoryIntent: Hashable {
    /// Focus the parent's own request form for this exact request (reply or approval choices).
    case focusRequest(String)
    /// Open this exact request where the parent routes it.
    case openRequest(String)
    case copy(String)
    case openSource
}

struct ActivityStoryAction: Identifiable, Equatable {
    let intent: ActivityStoryIntent
    let label: String
    let symbol: String
    var isPrimary = false
    let help: String
    var id: ActivityStoryIntent { intent }
}

extension ActivityStory {
    /// The targeted actions the parent can perform for this story. Only an action the scope
    /// names is offered; nothing here navigates on its own.
    func actions(in scope: ActivityStoryScope) -> [ActivityStoryAction] {
        var actions: [ActivityStoryAction] = []
        if let request = scope.request(for: self) {
            let approval = status == .awaitingApproval
            let short = Identifier.short(request.id)
            switch request.route {
            case .form where !request.acceptsInput:
                break // Its form cannot take input now (offline, closed or sending).
            case .form:
                actions.append(ActivityStoryAction(
                    intent: .focusRequest(request.id),
                    label: approval ? "Review approval" : (request.offersChoices ? "Choose" : "Reply"),
                    symbol: approval ? "hand.raised" : "arrowshape.turn.up.left", isPrimary: true,
                    help: "Go to the form for request \(short)"))
            case .open:
                actions.append(ActivityStoryAction(
                    intent: .openRequest(request.id), label: approval ? "Open approval" : "Open request",
                    symbol: "arrow.up.forward.square", isPrimary: true,
                    help: "Open request \(short) where it is answered"))
            }
        }
        if scope.canCopy, let outcome {
            actions.append(ActivityStoryAction(intent: .copy(outcome), label: "Copy outcome", symbol: "doc.on.doc",
                                               help: "Copy the outcome text exactly"))
        }
        if scope.canOpenSource {
            actions.append(ActivityStoryAction(intent: .openSource, label: "Source", symbol: "curlybraces",
                                               help: "Open this worker's provider source"))
        }
        return actions
    }
}

// MARK: - Renderers

/// The one interface a specialised renderer implements: from its source, the story's content.
protocol ActivityStoryRenderer {
    associatedtype Source
    static func content(for source: Source, scope: ActivityStoryScope) -> ActivityStoryContent
}

/// The report step a question or a change shares: open, done or (through the shared failure
/// rule) failed. `commander_result` reports to the caller's coordinator, as its tool states.
private func reportMilestone(_ report: CommanderCall?) -> ActivityMilestone? {
    guard let report else { return nil }
    let id = report.entry.id
    switch report.toolStatus {
    case .awaitingApproval:
        // A provider permission holds the report: it has not started.
        return ActivityMilestone(id: id, kind: .reporting, label: "Report awaiting approval",
                                 detail: report.reportText, status: .awaitingApproval, entryIDs: [id])
    case .running:
        return ActivityMilestone(id: id, kind: .reporting, label: "Reporting to coordinator",
                                 detail: report.reportText, status: .running, entryIDs: [id])
    case .done:
        return ActivityMilestone(id: id, kind: .reported, label: "Reported to coordinator",
                                 detail: report.reportText, status: .complete, entryIDs: [id])
    default:
        return nil
    }
}

private func reportRelations(_ report: CommanderCall?) -> [ActivityRelation] {
    guard let report else { return [] }
    var relations: [ActivityRelation] = []
    if let revision = report.revision {
        relations.append(ActivityRelation(kind: .revision, value: revision, label: "rev \(Identifier.short(revision))"))
    }
    for test in report.tests {
        relations.append(ActivityRelation(kind: .test, value: test.command,
                                          label: CommanderCall.join(test.command, test.outcome) ?? test.command))
    }
    return relations
}

enum QuestionStoryRenderer: ActivityStoryRenderer {
    static func content(for flow: CommanderWorkflow, scope: ActivityStoryScope) -> ActivityStoryContent {
        guard case .request(let requestID) = flow.link else {
            return CommanderCallStoryRenderer.content(for: flow.calls[0], scope: scope)
        }
        let calls = flow.calls
        let status = flow.status
        let live = flow.liveRequestStatus.map { CommanderActivityStatus(request: $0) }
        let liveAnswer = calls.compactMap { $0.facts?.liveAnswer }.last
        let question = calls.compactMap(\.question).first
        let hasAsk = calls.contains { $0.tool == .ask }
        let report = flow.report
        var milestones: [ActivityMilestone] = []
        var answer: String?
        var answerArrived = false

        for call in calls where call.tool != .result {
            let id = call.entry.id
            switch call.tool {
            case .ask:
                switch call.toolStatus {
                case .running:
                    milestones.append(ActivityMilestone(id: id, kind: .asked, label: "Asking", detail: call.question,
                                                        status: .running, entryIDs: [id]))
                case .done:
                    milestones.append(ActivityMilestone(id: id, kind: .asked, label: "Asked", detail: call.question,
                                                        status: .complete, entryIDs: [id]))
                default: break // the shared failure rule states it
                }
            case .wait, .reply, .reconcileReply:
                guard call.toolStatus == .done else { continue }
                if call.tool == .reconcileReply {
                    milestones.append(ActivityMilestone(
                        id: id, kind: .reconciled, label: "Delivery reconciled",
                        detail: call.delivery.map { "delivery \($0)" }, status: call.status, entryIDs: [id]))
                }
                if call.tool == .reply, !call.replyConfirmsRequest {
                    // Recovery evidence: the reply's result does not confirm this request.
                    milestones.append(ActivityMilestone(id: id, kind: .replied, label: "Reply not confirmed",
                                                        detail: call.recordedAnswer ?? call.argument("answer"),
                                                        status: .uncertain, entryIDs: [id]))
                    continue
                }
                // The answer as it arrived: the first call whose own record says answered. The
                // run's current record wins when it says the request is still pending.
                guard !answerArrived, live != .waitingForReply, call.answersRequest else { continue }
                answerArrived = true
                answer = call.recordedAnswer ?? liveAnswer
                // One answer milestone per story, whichever record states it first: the run's
                // request, then the call that returned it. Only its detail and linkage change.
                milestones.append(ActivityMilestone(
                    id: flow.id + "#answer", kind: call.tool == .reply ? .replied : .answered,
                    label: call.tool == .reply ? "Replied" : "Answer arrived",
                    detail: answer.map(CommanderCall.quote), status: .answered, entryIDs: [id]))
            default: break
            }
        }
        if !answerArrived, live == .answered {
            // No call carried it; the run's record by exact ID does.
            answer = liveAnswer
            milestones.append(ActivityMilestone(id: flow.id + "#answer", kind: .answered, label: "Answered",
                                                detail: liveAnswer.map(CommanderCall.quote), status: .answered))
        }
        if let live, live != .waitingForReply, live != .answered {
            milestones.append(ActivityMilestone(id: flow.id + "#closed", kind: .closed,
                                                label: "Request \(live.word.lowercased())", status: live))
        }
        let holder = scope.request(requestID)?.holder
        if status == .waitingForReply {
            // The current state, once. The wait probes stay evidence, so a failed probe still
            // surfaces through the shared failure rule.
            milestones.append(ActivityMilestone(id: flow.id + "#waiting", kind: .waiting, label: "Waiting for reply",
                                                detail: holder.map { "Needs \($0)" }, status: .waitingForReply))
        }
        if let reported = reportMilestone(report) { milestones.append(reported) }

        let quoted = question.map(CommanderCall.quote)
        let shortRequest = CommanderCall.request(requestID)
        let reportText = report?.toolStatus == .done ? report?.reportText : nil
        let unseenAsk = hasAsk ? nil : "ask not in this transcript"
        var content = ActivityStoryContent(symbol: CommanderTool.ask.symbol, kind: hasAsk ? "Question" : "Request",
                                           milestones: milestones, relations: [], requestID: requestID,
                                           reference: "request \(requestID)")
        if !hasAsk, calls.contains(where: { $0.tool == .reply }) {
            content.kind = "Reply"
            content.symbol = CommanderTool.reply.symbol
        }
        if let reportText, status == .complete {
            content.kind = "Question and result"
            content.lead = CommanderCall.firstLine(reportText)
            content.context = CommanderCall.join(quoted.map { "Asked \($0)" }, answer.map { "answer " + CommanderCall.quote($0) })
            content.outcome = reportText
        } else if let answer {
            content.lead = CommanderCall.quote(answer)
            let reporting: String? = switch report?.toolStatus {
            case .running?: "reporting to coordinator"
            case .awaitingApproval?: "report awaiting approval"
            default: nil
            }
            content.context = CommanderCall.join(quoted.map { "Asked \($0)" } ?? unseenAsk, reporting)
            content.outcome = answer
        } else if status == .waitingForReply {
            content.kind = "Decision needed"
            content.lead = quoted ?? shortRequest
            content.context = CommanderCall.join(holder.map { "Needs \($0)" }, unseenAsk, shortRequest)
        } else if status == .awaitingApproval {
            content.kind = "Approval needed"
            content.lead = quoted ?? shortRequest
            content.context = shortRequest
        } else {
            content.lead = quoted ?? shortRequest
            content.context = CommanderCall.join(unseenAsk, shortRequest)
        }
        // The relation list already titles the line "Request": the short ID alone.
        content.relations = [ActivityRelation(kind: .request, value: requestID, label: Identifier.short(requestID))]
            + reportRelations(report)
        return content
    }
}

enum RelayStoryRenderer: ActivityStoryRenderer {
    static func content(for flow: CommanderWorkflow, scope: ActivityStoryScope) -> ActivityStoryContent {
        guard case .operation(let operationID) = flow.link else {
            return CommanderCallStoryRenderer.content(for: flow.calls[0], scope: scope)
        }
        var milestones: [ActivityMilestone] = []
        var lastState: String?
        for call in flow.calls where call.toolStatus == .done {
            let id = call.entry.id
            if call.tool == .networkSubmit {
                milestones.append(ActivityMilestone(id: id, kind: .submitted, label: "Submitted",
                                                    detail: call.argumentSummary, status: .complete, entryIDs: [id]))
            } else if let state = call.operationState, state != lastState {
                // A receipt is a milestone only when it states a new status; repeats are evidence.
                lastState = state
                let status = CommanderActivityStatus(operation: state)
                milestones.append(ActivityMilestone(id: id, kind: .receipt, label: "Receipt: \(status.word.lowercased())",
                                                    detail: call.responseSummary, status: status, entryIDs: [id]))
            }
        }
        let submit = flow.calls.first { $0.tool == .networkSubmit }
        let latest = flow.calls.compactMap(\.responseSummary).last
        let settled = !flow.status.isUnresolved
        return ActivityStoryContent(
            symbol: CommanderTool.networkSubmit.symbol, kind: "Relay operation",
            lead: settled ? (latest ?? submit?.argumentSummary) : (submit?.argumentSummary ?? latest),
            context: CommanderCall.join(settled ? submit?.argumentSummary : latest, CommanderCall.operation(operationID)),
            milestones: milestones,
            relations: [ActivityRelation(kind: .operation, value: operationID, label: CommanderCall.operation(operationID))],
            reference: "operation \(operationID)")
    }
}

enum ChangeStoryRenderer: ActivityStoryRenderer {
    static func content(for flow: CommanderWorkflow, scope: ActivityStoryScope) -> ActivityStoryContent {
        guard case .revision(let revision) = flow.link, let commit = flow.calls.first(where: { $0.tool == .commit }) else {
            return CommanderCallStoryRenderer.content(for: flow.calls[0], scope: scope)
        }
        let report = flow.report
        var milestones = [ActivityMilestone(id: commit.entry.id, kind: .committed, label: "Committed",
                                            detail: commit.argumentSummary, status: commit.status, entryIDs: [commit.entry.id])]
        if let reported = reportMilestone(report) { milestones.append(reported) }
        let reportText = report?.toolStatus == .done ? report?.reportText : nil
        var relations = [ActivityRelation(kind: .revision, value: revision, label: "rev \(Identifier.short(revision))")]
        relations += commit.files.map { ActivityRelation(kind: .file, value: $0, label: $0) }
        relations += reportRelations(report).filter { $0.kind != .revision }
        return ActivityStoryContent(
            symbol: CommanderTool.commit.symbol, kind: report == nil ? "Commit" : "Commit and result",
            lead: reportText.map(CommanderCall.firstLine) ?? commit.argument("message").map(CommanderCall.firstLine),
            context: CommanderCall.join(reportText == nil ? nil : commit.argument("message").map(CommanderCall.firstLine),
                                        "rev \(Identifier.short(revision))"),
            milestones: milestones, relations: relations, outcome: reportText,
            reference: "revision \(revision)")
    }
}

/// Any Commander call that stands alone, by its domain. One call tells its story in its card's
/// lead and context; it has no timeline.
enum CommanderCallStoryRenderer: ActivityStoryRenderer {
    static func content(for call: CommanderCall, scope: ActivityStoryScope) -> ActivityStoryContent {
        var content = ActivityStoryContent(symbol: call.tool.symbol, kind: call.tool.label,
                                           lead: call.argumentSummary, context: call.responseSummary)
        switch call.tool {
        case .delegate:
            if let id = call.field("id") {
                content.relations.append(ActivityRelation(kind: .worker, value: id, label: CommanderCall.worker(id)))
            }
        case .send, .interrupt, .stopWorker:
            if let worker = call.targetWorker {
                content.relations.append(ActivityRelation(kind: .worker, value: worker, label: CommanderCall.worker(worker)))
            }
            if call.tool == .send {
                content.lead = call.argument("text").map(CommanderCall.quote) ?? content.lead
                content.context = CommanderCall.join(call.targetWorker.map(CommanderCall.worker), call.responseSummary)
            }
        case .result:
            content.lead = call.reportText.map(CommanderCall.firstLine) ?? content.lead
            content.context = CommanderCall.join(call.revision.map { "rev \(Identifier.short($0))" },
                                                 CommanderCall.count(call.arguments?["tests"], "test"))
            content.outcome = call.toolStatus == .done ? call.reportText : nil
            content.relations = reportRelations(call)
            content.requestID = call.facts?.requestID
        case .commit:
            if let revision = call.revision {
                content.relations.append(ActivityRelation(kind: .revision, value: revision, label: "rev \(Identifier.short(revision))"))
            }
            content.relations += call.files.map { ActivityRelation(kind: .file, value: $0, label: $0) }
        case .callTool:
            if let tool = call.argument("id") {
                content.relations.append(ActivityRelation(kind: .tool, value: tool, label: tool))
            }
        case .status:
            // What the run said leads; what was asked of it follows.
            content.lead = call.responseSummary ?? content.lead
            content.context = call.responseSummary == nil ? nil : call.argumentSummary
        case .integrate:
            if let id = call.operationID {
                content.relations.append(ActivityRelation(kind: .operation, value: id, label: CommanderCall.operation(id)))
            }
        case .ask, .wait, .reply, .reconcileReply:
            // A request call whose request is not yet known.
            content.lead = call.question.map(CommanderCall.quote) ?? content.lead
        default:
            break
        }
        if case .operation = call.tool.family, let id = call.operationID {
            content.relations.append(ActivityRelation(kind: .operation, value: id, label: CommanderCall.operation(id)))
        }
        return content
    }
}

/// A provider tool recognised by its exact name. Every other name keeps the raw tool row.
struct ProviderTool: Equatable {
    enum Kind: Equatable { case read, edit, write, search, shell, web }
    let kind: Kind

    private static let names: [String: Kind] = {
        var names: [String: Kind] = [:]
        for name in ["read", "read_file", "view", "notebookread"] { names[name] = .read }
        for name in ["edit", "multiedit", "notebookedit", "apply_patch", "edit_file", "str_replace_based_edit_tool"] { names[name] = .edit }
        for name in ["write", "write_file", "create_file"] { names[name] = .write }
        for name in ["grep", "glob", "search", "grep_search", "file_search", "list_dir", "ls", "codebase_search"] { names[name] = .search }
        for name in ["bash", "shell", "exec_command", "local_shell", "run_command", "run_terminal_cmd"] { names[name] = .shell }
        for name in ["websearch", "web_search", "webfetch", "web_fetch"] { names[name] = .web }
        return names
    }()

    /// Only an exact tool name (any case) is recognised; a title or a prefixed name is not.
    init?(name: String) {
        guard let kind = Self.names[name.lowercased()] else { return nil }
        self.kind = kind
    }

    var label: String {
        switch kind {
        case .read: "Read file"
        case .edit: "Edit file"
        case .write: "Write file"
        case .search: "Search"
        case .shell: "Run command"
        case .web: "Web"
        }
    }

    /// The argument fields that state this tool's subject, in order of preference.
    var factKeys: [String] {
        switch kind {
        case .read, .edit, .write: ["file_path", "path", "filePath", "notebook_path", "target_file", "file"]
        case .search: ["pattern", "query", "regex", "glob", "q", "path"]
        case .shell: ["command", "cmd", "script"]
        case .web: ["url", "query", "q"]
        }
    }

    /// The fact a headline leads with: the first known field of structured arguments (a list,
    /// such as a command's argv, joined by spaces), or a plain detail's first line. Nil for JSON
    /// without a known field and for an ACP placeholder: the arguments stay in Tool details.
    func fact(from detail: String?) -> String? {
        guard let text = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let value = CommanderPayload.value(text) else { return ToolDetailText.headline(text) }
        if let string = value.stringValue { return ToolDetailText.headline(string) }
        guard let object = value.objectValue else { return nil }
        for key in factKeys {
            if let scalar = CommanderCall.text(object[key]) { return CommanderCall.firstLine(scalar) }
            let parts = (object[key]?.arrayValue ?? []).compactMap { CommanderCall.text($0) }
            if !parts.isEmpty { return CommanderCall.firstLine(parts.joined(separator: " ")) }
        }
        return nil
    }

    var symbol: String {
        switch kind {
        case .read: "doc.text"
        case .edit: "pencil"
        case .write: "square.and.pencil"
        case .search: "magnifyingglass"
        case .shell: "terminal"
        case .web: "globe"
        }
    }
}

enum ProviderToolStoryRenderer: ActivityStoryRenderer {
    struct Source { let tool: ProviderTool; let name: String; let detail: String? }

    /// The provider's stated subject leads (a path, pattern, URL or command); the exact tool
    /// name follows. The original arguments stay in Tool details.
    static func content(for source: Source, scope: ActivityStoryScope) -> ActivityStoryContent {
        ActivityStoryContent(symbol: source.tool.symbol, kind: source.tool.label,
                             lead: source.tool.fact(from: source.detail), context: source.name)
    }
}

/// A tool call's plain detail as a headline. ACP sends its tool kind (`other`, `read`, `execute`,
/// …) where a provider gave no title; that placeholder is never a headline.
enum ToolDetailText {
    static let placeholders: Set<String> = ["other", "read", "edit", "delete", "move", "search", "execute",
                                            "think", "fetch", "switch_mode"]

    static func isPlaceholder(_ text: String) -> Bool {
        placeholders.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func headline(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPlaceholder(trimmed) else { return nil }
        return CommanderCall.firstLine(trimmed)
    }
}

// MARK: - Selection

enum ActivityStories {
    static func story(for flow: CommanderWorkflow, scope: ActivityStoryScope) -> ActivityStory {
        let content: ActivityStoryContent
        switch flow.link {
        case .request: content = QuestionStoryRenderer.content(for: flow, scope: scope)
        case .operation: content = RelayStoryRenderer.content(for: flow, scope: scope)
        case .revision: content = ChangeStoryRenderer.content(for: flow, scope: scope)
        case .single: content = CommanderCallStoryRenderer.content(for: flow.calls[0], scope: scope)
        }
        return ActivityStory.assemble(id: flow.id, status: flow.status, evidence: flow.entries,
                                      steps: flow.steps, content: content)
    }

    /// A recognised provider tool's story, or nil: the entry keeps its raw tool row.
    static func story(for entry: TranscriptEntry, awaitingToolID: String?, scope: ActivityStoryScope) -> ActivityStory? {
        guard case .tool(let name, let detail, let result) = entry.kind, CommanderTool(name: name) == nil,
              let tool = ProviderTool(name: name) else { return nil }
        let toolStatus = result == nil && entry.id == awaitingToolID ? ToolStatus.awaitingApproval : ToolStatus(result: result)
        let content = ProviderToolStoryRenderer.content(for: .init(tool: tool, name: name, detail: detail), scope: scope)
        return ActivityStory.assemble(id: entry.id + "#story", status: CommanderActivityStatus(toolStatus),
                                      evidence: [entry], content: content)
    }
}

// MARK: - Call accessors the renderers share

extension CommanderCall {
    /// The answer this call's own record carries, never the run's current record.
    var recordedAnswer: String? {
        switch tool {
        case .reply: return replyConfirmsRequest ? argument("answer") : nil
        case .wait, .ask, .reconcileReply: return responseIsThisRequest ? field("answer") : nil
        default: return nil
        }
    }

    /// The call's own record says the request was answered.
    var answersRequest: Bool {
        requestState?.lowercased() == "answered" || replyConfirmsRequest
    }

    var delivery: String? { responseIsThisRequest ? field("delivery") : nil }

    /// The text a result reported, exactly as sent.
    var reportText: String? {
        guard tool == .result else { return nil }
        return argument("result") ?? plainDetail
    }

    var tests: [(command: String, outcome: String?)] {
        (arguments?["tests"]?.arrayValue ?? []).compactMap { test in
            guard let command = Self.text(test["command"]) ?? Self.text(test["name"]) else { return nil }
            return (command, Self.text(test["outcome"]) ?? Self.text(test["status"]))
        }
    }

    var files: [String] {
        (arguments?["files"]?.arrayValue ?? []).compactMap { Self.text($0) }
    }
}
