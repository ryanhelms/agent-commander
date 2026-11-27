import Foundation
import Testing
@testable import AgentCommander

// Commander's own MCP calls in Pretty: every registration has a purposeful label, calls link only
// by exact IDs, and the chronological order of everything else is kept. Sequences follow the wire
// shape the service projects (`function.arguments` = {"detail": …, "commander": {…}}; results as
// the service's JSON, sometimes inside MCP content).

/// Builds a console's messages in order. Each call is an assistant message, its result a tool message.
/// Shared with ActivityStoryTests.
struct Wire {
    var messages: [AGUIMessage] = []
    private var sequence = 0

    private mutating func nextID() -> String { sequence += 1; return "w:\(sequence)" }

    mutating func user(_ text: String) {
        messages.append(AGUIMessage(id: nextID(), role: "user", content: text))
    }

    mutating func say(_ text: String) {
        messages.append(AGUIMessage(id: nextID(), role: "assistant", content: text))
    }

    /// A call with optional result. `detail` and `commander` form the arguments as the service writes them.
    @discardableResult
    mutating func call(_ name: String, detail: String? = nil, commander: [String: String]? = nil,
                       result: String? = nil, error: String? = nil) -> String {
        let id = nextID()
        let callID = "call-" + id
        var arguments: [String: AGUIValue] = [:]
        if let detail { arguments["detail"] = .string(detail) }
        if let commander { arguments["commander"] = .object(commander.mapValues(AGUIValue.string)) }
        let text = AGUIValue.object(arguments).compactText
        messages.append(AGUIMessage(id: id, role: "assistant",
                                    toolCalls: [AGUIToolCall(id: callID, function: .init(name: name, arguments: text))]))
        if result != nil || error != nil {
            messages.append(AGUIMessage(id: nextID(), role: "tool", content: result ?? "", toolCallID: callID, error: error))
        }
        return callID
    }

    var entries: [TranscriptEntry] { TranscriptEntry.entries(from: messages) }
}

private func question(_ id: String, _ status: String, answer: String = "", text: String = "Which database?") -> String {
    #"{"id":"\#(id)","worker_id":"w","question":"\#(text)","status":"\#(status)","answer":"\#(answer)"}"#
}

private func items(_ wire: Wire, awaiting: String? = nil, requests: [Question] = []) -> [ConversationItem] {
    let entries = CommanderActivity.annotate(wire.entries, requests: requests)
    return ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty), awaitingToolID: awaiting)
}

private func workflows(_ items: [ConversationItem]) -> [CommanderWorkflow] {
    items.compactMap { if case .commander(let workflow) = $0 { workflow } else { nil } }
}

@Suite struct CommanderActivityTests {
    // MARK: Registrations

    /// Every `commander_*` name in internal/mcpbridge (server, scoped, network and frontend
    /// registers) has a catalog entry, and the catalog has nothing the bridge does not register.
    @Test func everyBridgeRegistrationIsCatalogued() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = root.appending(path: "internal/mcpbridge")
        var registered = Set<String>()
        for file in ["server.go", "scoped_tools.go", "network.go", "frontend.go"] {
            let source = try String(contentsOf: bridge.appending(path: file), encoding: .utf8)
            let pattern = try Regex(#""(commander_[a-z_]+)""#)
            for match in source.matches(of: pattern) {
                if let name = match.output[1].substring { registered.insert(String(name)) }
            }
        }
        #expect(registered.count == 24)
        #expect(registered == Set(CommanderTool.allCases.map(\.rawValue)))
    }

    @Test func everyToolHasAPurposefulDistinctLabelAndSymbol() {
        let labels = CommanderTool.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        for tool in CommanderTool.allCases {
            #expect(!tool.label.isEmpty && !tool.label.hasPrefix("commander_"))
            #expect(!tool.symbol.isEmpty)
            #expect(!tool.stepName.isEmpty)
        }
        #expect(CommanderTool.ask.family == .request && CommanderTool.wait.family == .request)
        #expect(CommanderTool.reply.family == .request && CommanderTool.reconcileReply.family == .request)
        #expect(CommanderTool.withdrawQuestion.family == .request && CommanderTool.withdrawQuestion.domain == .question)
        #expect(CommanderTool.networkSubmit.family == .operation && CommanderTool.networkReceipt.family == .operation)
        #expect(CommanderTool.result.family == .report)
    }

    @Test func providerPrefixesAreReadAndOtherNamesAreNot() {
        for name in ["commander_wait", "mcp__commander__commander_wait", "mcp.commander.commander_wait",
                     "commander/commander_wait", "commander:commander_wait"] {
            #expect(CommanderTool(name: name) == .wait, "\(name)")
        }
        for name in ["wait", "my_commander_wait", "mcp__other__commander_wait", "commander_wait_more",
                     "mcp__commander__commander_unknown", "Read", "shell"] {
            #expect(CommanderTool(name: name) == nil, "\(name)")
        }
    }

    /// Each tool summarises the argument and response fields it is known to carry.
    @Test func everyToolSummarisesItsFields() throws {
        func call(_ tool: CommanderTool, _ args: String?, _ response: String?) throws -> CommanderCall {
            let entry = TranscriptEntry(id: "c", kind: .tool(name: "mcp__commander__" + tool.rawValue, detail: args,
                                                          result: response.map { ToolResult(output: $0) }))
            return try #require(CommanderCall(entry: entry))
        }
        let cases: [(CommanderTool, String?, String?, String?, String?)] = [
            (.delegate, #"{"name":"scout","task":"t","kind":"research","host":"lab"}"#, #"{"id":"worker-123456789","name":"scout","state":"starting"}"#,
             "scout · research · on lab", "scout · worker worker-1 · starting"),
            (.ask, #"{"question":"Which database?"}"#, question("req-1", "pending"), "“Which database?”", "request req-1"),
            (.wait, #"{"request_id":"req-1","timeout_seconds":45}"#, question("req-1", "answered", answer: "Postgres"),
             "request req-1 · up to 45s", "answer “Postgres”"),
            (.withdrawQuestion, #"{"request_id":"req-1"}"#, question("req-1", "cancelled"), "request req-1", "cancelled"),
            (.reply, #"{"request_id":"req-1","answer":"Postgres"}"#, question("req-1", "answered", answer: "Postgres"),
             "request req-1 · “Postgres”", "answered"),
            (.reconcileReply, #"{"request_id":"req-1"}"#, #"{"id":"req-1","question":"q","status":"answered","answer":"","delivery":"delivered"}"#,
             "request req-1", "answered · delivery delivered"),
            (.result, #"{"result":"Found it\nmore","revision":"abcdef1234567","tests":[{"command":"go test","outcome":"pass"}]}"#, "{}",
             "Found it · rev abcdef12 · 1 test", nil),
            (.commit, #"{"files":["a","b"],"message":"Fix it"}"#, #"{"revision":"0123456789abc"}"#, "Fix it · 2 files", "rev 01234567"),
            (.integrate, #"{"worker_ids":["a","b","c"],"idempotency_key":"k"}"#, #"{"status":"testing"}"#, "3 workers", "testing"),
            (.send, #"{"worker_id":"w-2","text":"Also check X"}"#, #"{"status":"queued"}"#, "worker w-2 · “Also check X”", "queued"),
            (.interrupt, #"{"worker_id":"w-2"}"#, #"{"state":"idle"}"#, "worker w-2", "idle"),
            (.stopWorker, #"{"worker_id":"w-2"}"#, #"{"state":"stopping"}"#, "worker w-2", "stopping"),
            (.status, #"{"wait_seconds":30}"#, #"{"status":"running","workers":[{"state":"working"},{"state":"waiting"}],"requests":[{"status":"pending"}]}"#,
             "wait up to 30s", "2 workers · 1 waiting, 1 working · 1 pending request · run running"),
            (.listTools, nil, #"[{"id":"a"},{"id":"b"}]"#, nil, "2 tools"),
            (.callTool, #"{"id":"lint","version":2,"arguments":{}}"#, #"{"status":"ok"}"#, "lint · v2", "ok"),
            (.networkInbox, nil, #"{"messages":[{"text":"hi"}]}"#, nil, "1 message"),
            (.networkDiscover, nil, #"{"resources":[{"id":"r"},{"id":"s"}]}"#, nil, "2 resources"),
            (.networkSubmit, #"{"id":"op-1","targets":[{"resource":"r","action":"agent.ask","payload":{}}]}"#, #"{"status":"accepted"}"#,
             "operation op-1 · 1 target · agent.ask", "accepted"),
            (.networkReceipt, #"{"id":"op-1"}"#, #"{"status":"completed","recipients":[{"status":"delivered"},{"status":"failed"}]}"#,
             "operation op-1", "completed · 2 recipients · 1 delivered, 1 failed"),
            (.networkOnline, nil, #"{"friends":[{"handle":"sam"},{"handle":"mei"}]}"#, nil, "2 contacts"),
            (.networkThread, #"{"request":"req-1","text":"Looks good"}"#, #"{"request":"req-1","comments":[{"text":"Looks good"}]}"#,
             "request req-1 · “Looks good”", "1 comment"),
            (.networkBoard, #"{"op":"complete","workspace":"ws-1","card":"card-2"}"#, #"{"cards":[{"id":"card-2"}]}"#,
             "complete · ws-1 · card-2", "1 card"),
            (.frontendTools, nil, #"{"tools":[{"name":"pick"}]}"#, nil, "1 tool"),
            (.callFrontend, #"{"name":"pick_color","arguments":{}}"#, "Picked plum", "pick_color", nil),
        ]
        #expect(Set(cases.map(\.0)) == Set(CommanderTool.allCases))
        for (tool, args, response, argumentSummary, responseSummary) in cases {
            let parsed = try call(tool, args, response)
            #expect(parsed.argumentSummary == argumentSummary, "\(tool) arguments")
            #expect(parsed.responseSummary == responseSummary, "\(tool) response")
        }
    }

    @Test func plainDetailFromClaudeAndMCPWrappedResultsAreRead() throws {
        let mcp = #"{"content":[{"type":"text","text":"{\"id\":\"req-9\",\"question\":\"q\",\"status\":\"pending\",\"answer\":\"\"}"}]}"#
        let entry = TranscriptEntry(id: "c", kind: .tool(name: "commander_ask", detail: "Which database?", result: ToolResult(output: mcp)))
        let call = try #require(CommanderCall(entry: entry))
        #expect(call.question == "Which database?")
        #expect(call.requestID == "req-9")
        #expect(call.status == .waitingForReply)
        // Several phases joined by line breaks: the last JSON line is the record.
        let phased = TranscriptEntry(id: "d", kind: .tool(name: "commander_wait", detail: nil,
            result: ToolResult(output: "Tool t completed.\n" + question("req-9", "answered", answer: "yes"))))
        #expect(try #require(CommanderCall(entry: phased)).status == .answered)
    }

    // MARK: Chronological sequences

    /// The screenshot: Ask, then Wait calls that completed with the request still pending, read
    /// as one question that is still waiting for its reply, never as done.
    @Test func askAndCompletedPendingWaitsAreOneQuestionStillWaiting() throws {
        var wire = Wire()
        wire.user("Pick the database.")
        wire.call("mcp__commander__commander_ask", detail: "Which database?", result: question("req-1", "pending"))
        wire.call("mcp__commander__commander_wait", commander: ["requestId": "req-1"], result: question("req-1", "pending"))
        wire.call("mcp__commander__commander_wait", commander: ["requestId": "req-1"], result: question("req-1", "pending"))
        let shown = items(wire)
        #expect(shown.map(\.id) == ["w:1", "call-w:2#commander"])
        let flow = try #require(workflows(shown).first)
        #expect(flow.link == .request("req-1"))
        #expect(flow.status == .waitingForReply)
        #expect(flow.status.isUnresolved)
        #expect(flow.steps == "Ask · Wait ×2")
        #expect(flow.summary == "“Which database?”")
        #expect(flow.title == "Question")
        // Opening it gives every original call, in order, with its own result.
        #expect(flow.entries.map(\.id) == ["call-w:2", "call-w:4", "call-w:6"])
        #expect(flow.entries.allSatisfy { if case .tool(_, _, let result) = $0.kind { result != nil } else { false } })

        // A wait still open reads as waiting too.
        wire.call("mcp__commander__commander_wait", commander: ["requestId": "req-1"])
        #expect(workflows(items(wire)).first?.status == .waitingForReply)
    }

    @Test func liveRequestStateWinsByExactIDOnly() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "Which database?", result: question("req-1", "pending"))
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "pending"))
        let answered = Question(id: "req-1", workerID: "w", question: "Which database?", status: "answered", answer: "Postgres")
        let flow = try #require(workflows(items(wire, requests: [answered])).first)
        #expect(flow.status == .answered)
        #expect(flow.outcome == "answer “Postgres”")
        // A request whose ID only shares a prefix is not this one.
        let other = Question(id: "req-10", workerID: "w", question: "q", status: "answered", answer: "no")
        #expect(workflows(items(wire, requests: [other])).first?.status == .waitingForReply)
        // A run that still has it pending keeps it waiting even after a call said otherwise.
        var later = wire
        later.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "answered", answer: "x"))
        let pending = Question(id: "req-1", workerID: "w", question: "q", status: "pending", answer: "")
        #expect(workflows(items(later, requests: [pending])).first?.status == .waitingForReply)
    }

    /// commander_withdraw_question takes `request_id` and returns the question's record with
    /// status `cancelled`. It joins its question by that exact ID and says withdrawn only on
    /// that record.
    @Test func aWithdrawalJoinsItsQuestionByExactRequestIDAndIsSaidOnlyOnItsOwnRecord() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "Which database?", result: question("req-1", "pending"))
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "pending"))
        wire.call("commander_withdraw_question", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "cancelled"))
        let flow = try #require(workflows(items(wire)).first)
        #expect(workflows(items(wire)).count == 1 && flow.calls.count == 3)
        #expect(flow.link == .request("req-1") && flow.status == .cancelled)
        #expect(flow.calls[2].withdrawalConfirmed && flow.calls[2].answer == nil)

        // ACP keeps only the service's correlation: the exact ID and the state it read.
        var acp = Wire()
        acp.call("commander_ask", detail: "Which database?", result: question("req-1", "pending"))
        acp.call("mcp__commander__commander_withdraw_question", detail: "",
                 commander: ["requestId": "req-1", "requestStatus": "cancelled"], result: "{}")
        let correlated = try #require(workflows(items(acp)).first)
        #expect(correlated.calls.count == 2 && correlated.status == .cancelled)

        // A request whose ID only shares a prefix is another request.
        var other = Wire()
        other.call("commander_ask", detail: "Which database?", result: question("req-1", "pending"))
        other.call("commander_withdraw_question", detail: #"{"request_id":"req-10"}"#, result: question("req-10", "cancelled"))
        let apart = workflows(items(other))
        #expect(apart.count == 2 && apart[0].status == .waitingForReply)

        // A result that is another request's record, or no record, confirms nothing.
        var wrong = Wire()
        wrong.call("commander_withdraw_question", detail: #"{"request_id":"req-1"}"#, result: question("req-2", "cancelled"))
        wrong.call("commander_withdraw_question", detail: #"{"request_id":"req-3"}"#, result: "{}")
        for flow in workflows(items(wrong)) {
            #expect(!flow.calls[0].withdrawalConfirmed && flow.status == .uncertain)
        }

        // A refused withdrawal (answered already, or another worker's) leaves the question as it was.
        var refused = Wire()
        refused.call("commander_ask", detail: "Which database?", result: question("req-1", "pending"))
        refused.call("commander_withdraw_question", detail: #"{"request_id":"req-1"}"#, error: "only pending questions can be withdrawn")
        let kept = try #require(workflows(items(refused)).first)
        #expect(!kept.calls[1].withdrawalConfirmed && kept.status != .cancelled)
    }

    @Test func aFailedPollStaysVisibleWhileTheRequestIsUnresolved() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "q", result: question("req-1", "pending"))
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, error: "transport closed")
        let flow = try #require(workflows(items(wire)).first)
        #expect(flow.calls.count == 2)
        #expect(flow.failedCalls == 1)
        #expect(flow.status == .waitingForReply)
        #expect(flow.accessibilityLabel.contains("1 failed call"))
        // The original call keeps its error.
        guard case .tool(_, _, let result) = flow.entries[1].kind else { Issue.record("no call"); return }
        #expect(result?.error == "transport closed")
    }

    @Test func anAnsweredQuestionTakesTheResultOfItsUninterruptedTurn() throws {
        var wire = Wire()
        wire.user("Pick the database.")
        wire.call("commander_ask", detail: "Which database?", result: question("req-1", "pending"))
        wire.say("Waiting for the developer.")
        wire.call("Read", detail: "notes.md", result: "notes")
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "answered", answer: "Postgres"))
        wire.call("commander_result", detail: #"{"result":"Use Postgres"}"#, result: "{}")
        let shown = items(wire)
        // The question sits where it was asked; the prose and the other tool keep their order.
        #expect(shown.map(\.id) == ["w:1", "call-w:2#commander", "w:4", "call-w:5"])
        let flow = try #require(workflows(shown).first)
        #expect(flow.steps == "Ask · Wait · Result")
        #expect(flow.title == "Question and result")
        #expect(flow.status == .complete)
        #expect(flow.outcome == "answer “Postgres” · result Use Postgres")
        // Nothing is dropped or repeated: each entry is shown once, itself or inside its workflow.
        let displayed = TranscriptEntry.displayed(wire.entries, mode: .pretty)
        let flattened = shown.flatMap(\.entries)
        #expect(flattened.count == displayed.count)
        #expect(Set(flattened.map(\.id)) == Set(displayed.map(\.id)))
    }

    @Test func aResultIsSeparateWhenItsQuestionIsNotProvablyItsOwn() throws {
        // Two outstanding questions in one turn: each stays its own; the result is separate.
        var two = Wire()
        two.user("go")
        two.call("commander_ask", detail: "First?", result: question("req-1", "pending", text: "First?"))
        two.call("commander_ask", detail: "Second?", result: question("req-2", "pending", text: "Second?"))
        two.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "answered", answer: "a"))
        two.call("commander_result", detail: #"{"result":"done"}"#, result: "{}")
        let shownTwo = workflows(items(two))
        #expect(shownTwo.map(\.link) == [.request("req-1"), .request("req-2"), .single])
        #expect(shownTwo[0].status == .answered)
        #expect(shownTwo[1].status == .waitingForReply)
        #expect(shownTwo[2].title == "Report result")

        // A developer prompt between the answer and the result interrupts the turn.
        var later = Wire()
        later.call("commander_ask", detail: "q", result: question("req-1", "pending"))
        later.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "answered", answer: "a"))
        later.user("Now report.")
        later.call("commander_result", detail: #"{"result":"done"}"#, result: "{}")
        #expect(workflows(items(later)).map(\.calls.count) == [2, 1])

        // Not yet answered by any call: the result is not linked, even if the run says answered.
        var unanswered = Wire()
        unanswered.call("commander_ask", detail: "q", result: question("req-1", "pending"))
        unanswered.call("commander_result", detail: #"{"result":"done"}"#, result: "{}")
        let live = Question(id: "req-1", workerID: "w", question: "q", status: "answered", answer: "a")
        #expect(workflows(items(unanswered, requests: [live])).map(\.calls.count) == [1, 1])

        // An ask still without its request ID makes the turn ambiguous.
        var unidentified = Wire()
        unidentified.call("commander_ask", detail: "q", result: question("req-1", "pending"))
        unidentified.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "answered", answer: "a"))
        unidentified.call("commander_ask", detail: "another")
        unidentified.call("commander_result", detail: #"{"result":"done"}"#, result: "{}")
        #expect(workflows(items(unidentified)).map(\.calls.count) == [2, 1, 1])
    }

    @Test func anExplicitRequestIDLinksAResultAcrossTurns() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "q", result: question("req-1", "pending"))
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "answered", answer: "a"))
        wire.user("Report now.")
        wire.call("commander_result", detail: #"{"result":"done"}"#, commander: ["requestId": "req-1"], result: "{}")
        let flows = workflows(items(wire))
        #expect(flows.count == 1)
        #expect(flows[0].steps == "Ask · Wait · Result")
    }

    @Test func multipleOutstandingQuestionsStaySeparateAndWaitsFollowTheirOwnID() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "First?", result: question("req-1", "pending", text: "First?"))
        wire.call("commander_ask", detail: "Second?", result: question("req-2", "pending", text: "Second?"))
        wire.call("commander_wait", detail: #"{"request_id":"req-2"}"#, result: question("req-2", "pending", text: "Second?"))
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "answered", answer: "yes", text: "First?"))
        let flows = workflows(items(wire))
        #expect(flows.map(\.link) == [.request("req-1"), .request("req-2")])
        #expect(flows[0].status == .answered)
        #expect(flows[1].status == .waitingForReply)
        #expect(flows.map(\.steps) == ["Ask · Wait", "Ask · Wait"])
    }

    @Test func replyAndReconcileJoinTheirRequestInThisConsoleOnly() throws {
        var wire = Wire()
        // A coordinator replying to another worker's request: no ask here, so it stands alone.
        wire.call("commander_reply", detail: #"{"request_id":"req-7","answer":"go"}"#, result: question("req-7", "answered", answer: "go"))
        wire.call("commander_reconcile_reply", detail: #"{"request_id":"req-7"}"#,
                  result: #"{"id":"req-7","question":"q","status":"answered","answer":"go","delivery":"unknown"}"#)
        wire.call("commander_reply", detail: #"{"request_id":"req-8","answer":"no"}"#, result: question("req-8", "answered", answer: "no"))
        let flows = workflows(items(wire))
        #expect(flows.map(\.link) == [.request("req-7"), .request("req-8")])
        #expect(flows[0].steps == "Reply · Reconcile")
        #expect(flows[0].title == "Reply")
        #expect(flows[0].status == .answered)
    }

    @Test func networkSubmitAndReceiptLinkOnlyByOperationID() throws {
        var wire = Wire()
        wire.call("mcp__commander__commander_network_submit",
                  detail: #"{"id":"op-1","targets":[{"resource":"r","action":"agent.ask","payload":{}}]}"#,
                  result: #"{"status":"accepted"}"#)
        wire.say("Submitted.")
        wire.call("mcp__commander__commander_network_submit",
                  detail: #"{"id":"op-2","targets":[{"resource":"r","action":"agent.message","payload":{}}]}"#,
                  result: #"{"status":"accepted"}"#)
        wire.call("mcp__commander__commander_network_receipt", detail: #"{"id":"op-1"}"#,
                  result: #"{"status":"completed","recipients":[{"status":"delivered"}]}"#)
        let shown = items(wire)
        #expect(shown.map(\.id) == ["call-w:1#commander", "w:3", "call-w:4#commander"])
        let flows = workflows(shown)
        #expect(flows.map(\.link) == [.operation("op-1"), .operation("op-2")])
        #expect(flows[0].steps == "Submit · Receipt")
        #expect(flows[0].status == .complete)
        #expect(flows[1].status == .queued)
        #expect(flows[0].title == "Network operation")
    }

    @Test func correlationObjectIsReadFromArguments() throws {
        var wire = Wire()
        wire.call("commander_wait", detail: "", commander: ["requestId": "req-3", "requestStatus": "pending", "workerId": "w-1"])
        let entry = try #require(wire.entries.first)
        #expect(entry.commander == CommanderCallFacts(requestID: "req-3", requestStatus: "pending", workerID: "w-1"))
        // A call with no correlation object has none.
        var plain = Wire()
        plain.call("commander_wait", detail: #"{"request_id":"req-3"}"#)
        #expect(plain.entries.first?.commander == nil)
        // A malformed object is ignored.
        #expect(CommanderCallFacts(arguments: #"{"commander":"req-3"}"#) == nil)
        #expect(CommanderCallFacts(arguments: #"{"commander":{"requestId":7}}"#) == nil)
    }

    @Test func aPermissionHoldIsAwaitingApprovalNotAQuestion() throws {
        var wire = Wire()
        let id = wire.call("commander_send", detail: #"{"worker_id":"w-2","text":"go"}"#)
        let flow = try #require(workflows(items(wire, awaiting: id)).first)
        #expect(flow.status == .awaitingApproval)
        #expect(workflows(items(wire)).first?.status == .running)
    }

    @Test func otherToolsKeepTheirGenericRowAndOrder() throws {
        var wire = Wire()
        wire.user("go")
        wire.call("Read", detail: "a.swift", result: "text")
        wire.call("mcp__other__commander_ask", detail: "q", result: "{}")
        wire.call("commander_status", detail: #"{"wait_seconds":0}"#, result: #"{"status":"running","workers":[]}"#)
        wire.say("ok")
        let shown = items(wire)
        #expect(shown.map(\.id) == ["w:1", "call-w:2", "call-w:4", "call-w:6#commander", "w:8"])
        guard case .entry(let read) = shown[1], case .entry(let foreign) = shown[2] else { Issue.record("expected entries"); return }
        #expect(read.kind == .tool(name: "Read", detail: "a.swift", result: ToolResult(output: "text")))
        #expect(foreign.kind == .tool(name: "mcp__other__commander_ask", detail: "q", result: ToolResult(output: "{}")))
        #expect(workflows(shown).first?.title == "Check status")
        #expect(workflows(shown).first?.status == .complete)
    }

    @Test func statusWordsNeverClaimProgressFractions() {
        let statuses: [CommanderActivityStatus] = [.queued, .running, .waitingForReply, .awaitingApproval, .answered,
                                                   .complete, .failed, .cancelled, .declined, .interrupted,
                                                   .partial, .uncertain, .reported("held")]
        for status in statuses { #expect(!status.word.contains("%")) }
        #expect(CommanderActivityStatus(request: "pending") == .waitingForReply)
        #expect(CommanderActivityStatus(request: "answered") == .answered)
        #expect(CommanderActivityStatus(request: "cancelled") == .cancelled)
        #expect(CommanderActivityStatus(operation: "delivery_unknown") == .uncertain)
        #expect(CommanderActivityStatus(operation: "partial") == .partial)
        #expect(CommanderActivityStatus(operation: "expired") == .reported("expired"))
        #expect(CommanderActivityStatus(operation: "expired").word == "Expired")
        #expect(CommanderActivityStatus(operation: "tests_failed") == .failed)
        #expect(CommanderActivityStatus(operation: "tested") == .running)
    }

    // MARK: Live state and exact links (Codex follow-ups)

    @Test func followUpAndIntegrationRowsFollowTheRunsCurrentState() throws {
        var wire = Wire()
        wire.call("commander_send", detail: #"{"worker_id":"w-2","text":"go"}"#, result: #"{"id":"msg-1","status":"queued"}"#)
        wire.call("commander_integrate", detail: #"{"worker_ids":["w-2"],"idempotency_key":"k"}"#,
                  result: #"{"id":"int-1","candidate":{"status":"queued"}}"#)
        #expect(workflows(items(wire)).map(\.status) == [.queued, .queued])

        let live = CommanderLiveState(integrations: ["int-1": "integrated"], followUps: ["w-2": ["msg-1": "completed"]])
        let entries = CommanderActivity.annotate(wire.entries, live: live)
        let shown = workflows(ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty)))
        #expect(shown.map(\.status) == [.complete, .complete])

        // Another worker's message with the same ID, or a prefix ID, is not this follow-up.
        let elsewhere = CommanderLiveState(integrations: ["int-10": "integrated"], followUps: ["w-3": ["msg-1": "completed"]])
        let unchanged = CommanderActivity.annotate(wire.entries, live: elsewhere)
        #expect(workflows(ConversationActivity.items(unchanged)).map(\.status) == [.queued, .queued])

        // A failed integration reads as failed, not complete.
        let failed = CommanderActivity.annotate(wire.entries, live: CommanderLiveState(integrations: ["int-1": "tests_failed"]))
        #expect(workflows(ConversationActivity.items(failed)).last?.status == .failed)
    }

    @Test func liveStateIsReadFromTheRunsOwnRecords() throws {
        let worker = Worker(id: "w-2", name: "w", role: "worker", parentID: "", runID: "r", state: "working",
                            host: "local", worktree: "", task: "t", output: "", messages: [])
        let run = Run(id: "r", project: "p", path: "/p", task: "t", client: "codex", coordinatorID: "w",
                      status: "running", workers: [worker],
                      requests: [Question(id: "req-1", workerID: "w-2", question: "q", status: "pending", answer: "")])
        let live = CommanderLiveState(run: run)
        #expect(live.requests["req-1"]?.status == "pending")
        #expect(live.integrations.isEmpty)
    }

    @Test func aResponseNamingAnotherRequestIsIgnored() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "q", result: question("req-1", "pending"))
        // Correlated to req-1, but the response is req-2's record: its status and answer are not read.
        wire.call("commander_wait", commander: ["requestId": "req-1"], result: question("req-2", "answered", answer: "wrong"))
        let flow = try #require(workflows(items(wire)).first)
        #expect(flow.calls.count == 2)
        #expect(flow.status == .waitingForReply)
        #expect(flow.outcome == nil)
        #expect(flow.calls[1].requestState == nil)
        #expect(flow.calls[1].responseSummary == nil)
    }

    @Test func aReceiptErrorIsNotHiddenBehindAnEarlierQueued() throws {
        var wire = Wire()
        wire.call("commander_network_submit", detail: #"{"id":"op-1","targets":[]}"#, result: #"{"status":"pending"}"#)
        wire.call("commander_network_receipt", detail: #"{"id":"op-1"}"#, error: "relay unavailable")
        let flow = try #require(workflows(items(wire)).first)
        #expect(flow.calls.count == 2)
        #expect(flow.status == .failed)
        #expect(flow.failedCalls == 1)
    }

    @Test func mixedRecipientOutcomesArePartial() throws {
        var wire = Wire()
        wire.call("commander_network_receipt", detail: #"{"id":"op-1"}"#,
                  result: #"{"children":[{"status":"completed"},{"status":"declined"}]}"#)
        let flow = try #require(workflows(items(wire)).first)
        #expect(flow.status == .partial)
        #expect(flow.outcome == "2 recipients · 1 completed, 1 declined")
        // The correlation object's status, when present, is the service's word.
        var stated = Wire()
        stated.call("commander_network_receipt", detail: #"{"id":"op-1"}"#, commander: ["operationId": "op-1", "operationStatus": "partial"],
                    result: #"{"children":[]}"#)
        #expect(workflows(items(stated)).first?.status == .partial)
    }

    /// Older receipts without `commander.operationStatus`: the relay's `children` decide, and the
    /// operation settles only when every child is terminal.
    @Test func olderReceiptsSettleOnlyWhenEveryChildIsTerminal() throws {
        func status(_ children: String, topLevel: String = "") throws -> CommanderActivityStatus {
            var wire = Wire()
            wire.call("commander_network_receipt", detail: #"{"id":"op-1"}"#,
                      result: #"{\#(topLevel)"children":[\#(children)]}"#)
            return try #require(workflows(items(wire)).first).status
        }
        #expect(try status(#"{"status":"completed"},{"status":"processing"}"#) == .running)
        #expect(try status(#"{"status":"completed"},{"status":"pending"}"#) == .queued)
        #expect(try status(#"{"status":"pending"},{"status":"processing"},{"status":"failed"}"#) == .running)
        #expect(try status(#"{"status":"completed"},{"status":"failed"}"#) == .partial)
        #expect(try status(#"{"status":"completed"},{"status":"expired"}"#) == .partial)
        #expect(try status(#"{"status":"completed"},{"status":"delivered"}"#) == .complete)
        #expect(try status(#"{"status":"failed"},{"status":"failed"}"#) == .failed)
        // A top-level word does not settle an operation whose children are still in flight.
        #expect(try status(#"{"status":"completed"},{"status":"processing"}"#, topLevel: #""status":"completed","#) == .running)
        // The service's correlation status, when present, is still the word used.
        var stated = Wire()
        stated.call("commander_network_receipt", detail: #"{"id":"op-1"}"#, commander: ["operationStatus": "completed"],
                    result: #"{"children":[{"status":"processing"}]}"#)
        #expect(workflows(items(stated)).first?.status == .complete)
        #expect(CommanderCall.aggregate([]) == nil)
    }

    @Test func aReplyNamingAnotherRequestDoesNotAnswerThisOne() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "q", result: question("req-1", "pending"))
        wire.call("commander_reply", detail: #"{"request_id":"req-1","answer":"go"}"#, result: question("req-2", "answered", answer: "go"))
        let flow = try #require(workflows(items(wire)).first)
        #expect(flow.calls.count == 2)
        #expect(flow.calls[1].status == .uncertain)
        #expect(!flow.hasAnsweredCall)
        #expect(flow.status == .waitingForReply)
        // So a result in the same turn is not attached to it.
        wire.call("commander_result", detail: #"{"result":"done"}"#, result: "{}")
        #expect(workflows(items(wire)).map(\.calls.count) == [2, 1])

        // A matching reply is answered.
        var matching = Wire()
        matching.call("commander_reply", detail: #"{"request_id":"req-1","answer":"go"}"#, result: question("req-1", "answered", answer: "go"))
        #expect(workflows(items(matching)).first?.status == .answered)
        // An older successful reply whose result names no request relies on its own request_id.
        var older = Wire()
        older.call("commander_reply", detail: #"{"request_id":"req-1","answer":"go"}"#, result: "ok")
        let olderFlow = try #require(workflows(items(older)).first)
        #expect(olderFlow.link == .request("req-1"))
        #expect(olderFlow.status == .answered)
        #expect(olderFlow.hasAnsweredCall)
        // A failed reply answers nothing.
        var failed = Wire()
        failed.call("commander_reply", detail: #"{"request_id":"req-1","answer":"go"}"#, error: "request is not pending")
        #expect(workflows(items(failed)).first?.status == .failed)
    }

    @Test func aResultLinksToItsCommitByTheExactFullRevision() throws {
        let full = "0123456789abcdef0123456789abcdef01234567"
        var wire = Wire()
        wire.user("Fix and report.")
        wire.call("commander_ask", detail: "q", result: question("req-1", "pending"))
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: question("req-1", "answered", answer: "a"))
        wire.call("commander_commit", detail: #"{"files":["a"],"message":"Fix"}"#, result: #"{"revision":"\#(full)"}"#)
        wire.say("Committed.")
        wire.call("commander_result", detail: #"{"result":"Fixed","revision":"\#(full)"}"#, result: "{}")
        let flows = workflows(items(wire))
        // The revision link wins over the one-answered-question rule.
        #expect(flows.map(\.link) == [.request("req-1"), .revision(full)])
        #expect(flows[1].steps == "Commit · Result")
        #expect(flows[1].title == "Commit and result")
        #expect(flows[1].status == .complete)
        #expect(flows[0].calls.count == 2)

        // A short or different revision is no link.
        var short = Wire()
        short.call("commander_commit", detail: #"{"files":["a"],"message":"Fix"}"#, result: #"{"revision":"\#(full)"}"#)
        short.call("commander_result", detail: #"{"result":"Fixed","revision":"0123456789ab"}"#, result: "{}")
        #expect(workflows(items(short)).map(\.calls.count) == [1, 1])
        // No revision on the result: no link.
        var none = Wire()
        none.call("commander_commit", detail: #"{"files":["a"],"message":"Fix"}"#, result: #"{"revision":"\#(full)"}"#)
        none.call("commander_result", detail: #"{"result":"Fixed"}"#, result: "{}")
        #expect(workflows(items(none)).map(\.calls.count) == [1, 1])
    }
}
