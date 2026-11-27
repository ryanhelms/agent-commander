import Foundation
import Testing
@testable import AgentCommander

// A question asked and answered by Claude over ACP (#124). The shape is the one a local run
// kept: the call's name is its ACP title, `commander: commander_ask`; the call carries no
// arguments and no correlation; the result is the request's record inside one MCP text part;
// the call's ID is `<worker ID>:<tool ID>`.

private let worker = "w-26bcf43c68a5b143b015ca632d4d0c2c"
private let otherWorker = "w-0123456789abcdef0123456789abcdef"
private let request = "q-cbdafb2d34353981dfc7ccb97df06093"
private let otherRequest = "q-fedcba9876543210fedcba9876543210"
private let askedText = "Which QA marker should I repeat?"
private let answerText = "QA_ANSWER_72 $literal"

/// The request's record as the bridge returns it, wrapped as the provider kept it.
private func envelope(_ status: String, id: String = request, answer: String = "", question: String = askedText,
                      worker named: String = worker) -> String {
    let record = AGUIValue.object([
        "id": .string(id), "worker_id": .string(named), "question": .string(question),
        "status": .string(status), "answer": .string(answer),
    ]).compactText + "\n"
    return AGUIValue.array([.object(["type": .string("text"), "text": .string(record)])]).compactText
}

private struct ACPWire {
    var messages: [AGUIMessage] = []
    private var count = 0

    @discardableResult
    mutating func call(_ tool: String, detail: String? = nil, result: String? = nil, server: String = "commander: ") -> String {
        count += 1
        let id = "\(worker):toolu_\(count)"
        var fields: [String: AGUIValue] = [:]
        if let detail { fields["detail"] = .string(detail) }
        let arguments = AGUIValue.object(fields).compactText
        messages.append(AGUIMessage(id: "\(worker):\(count)", role: "assistant",
                                    toolCalls: [AGUIToolCall(id: id, function: .init(name: server + tool, arguments: arguments))]))
        if let result {
            messages.append(AGUIMessage(id: "\(worker):\(count)r", role: "tool", content: result, toolCallID: id))
        }
        return id
    }

    func flows(live: [Question] = []) -> [CommanderWorkflow] {
        let entries = CommanderActivity.annotate(TranscriptEntry.entries(from: messages), requests: live)
        return CommanderActivity.items(TranscriptEntry.displayed(entries, mode: .pretty)).compactMap {
            if case .workflow(let flow) = $0 { flow } else { nil }
        }
    }

    func groups(live: [Question] = []) -> [ActivityGroup] {
        let entries = CommanderActivity.annotate(TranscriptEntry.entries(from: messages), requests: live)
        let items = ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty))
        return ActivityConversation.items(items).compactMap { if case .group(let group) = $0 { group } else { nil } }
    }
}

@Suite struct CommanderACPQuestionTests {
    @Test func theACPTitleNamesTheToolAndNearMissesDoNot() {
        #expect(CommanderTool(name: "commander: commander_ask") == .ask)
        #expect(CommanderTool(name: "commander: commander_wait") == .wait)
        #expect(CommanderTool(name: "commander: commander_withdraw_question") == .withdrawQuestion)
        for name in ["commander:  commander_ask", "commander commander_ask", "github: commander_ask",
                     "my commander: commander_ask", "commander: commander_ask ", "commander/ commander_ask",
                     "commander: ask"] {
            #expect(CommanderTool(name: name) == nil, "\(name)")
        }
    }

    @Test func anAskAndItsWaitAreOneAnsweredLineWithTheExactAnswer() throws {
        var wire = ACPWire()
        wire.call("Bash", detail: "ls", result: "a", server: "")
        wire.call("commander_ask", result: envelope("pending"))
        wire.call("commander_wait", result: envelope("answered", answer: answerText))

        let flow = try #require(wire.flows().first)
        #expect(wire.flows().count == 1)
        #expect(flow.link == .request(request) && flow.calls.map(\.tool) == [.ask, .wait])
        #expect(flow.status == .answered)
        #expect(flow.calls[1].recordedAnswer == answerText)
        #expect(flow.outcome == "answer “\(answerText)”")

        let made = wire.groups()
        #expect(made.count == 1 && made[0].lines.count == 2)
        let line = made[0].lines[1]
        #expect(line.kind == .workflow && line.sentence.plain == "Asked: “\(askedText)”" && line.tag == nil)
        #expect(made[0].summary.text == "Ran a command, asked a question and got an answer")
        // The wait on its own words the answer exactly, `$` included.
        #expect(ActivityWords.commander(flow.calls[1]).done.plain == "Got the answer: “\(answerText)”")
        // The opened line's timeline names the answer too.
        let story = ActivityStories.story(for: flow, scope: ActivityStoryScope())
        #expect(story.milestones.contains { $0.label == "Answer arrived" && $0.detail == "“\(answerText)”" })
    }

    @Test func theCallsOwnTitleIsNeverReadAsTheQuestion() throws {
        var wire = ACPWire()
        wire.call("commander_ask", detail: "commander: commander_ask")
        let call = try #require(wire.flows().first?.calls.first)
        #expect(call.plainDetail == nil && call.question == nil)
        #expect(ActivityWords.commander(call).running.plain == "Asking")
    }

    @Test func competingRequestsLinkOnlyByTheirOwnExactID() {
        var wire = ACPWire()
        wire.call("commander_ask", result: envelope("pending"))
        wire.call("commander_ask", result: envelope("pending", id: otherRequest, question: "Second?"))
        wire.call("commander_wait", result: envelope("answered", id: otherRequest, answer: "two", question: "Second?"))
        wire.call("commander_wait", result: envelope("answered", answer: answerText))

        let flows = wire.flows()
        #expect(flows.map(\.link) == [.request(request), .request(otherRequest)])
        #expect(flows.map { $0.calls.count } == [2, 2])
        #expect(flows[0].outcome == "answer “\(answerText)”" && flows[1].outcome == "answer “two”")
        // A request ID that is a prefix of another is a different request.
        var prefix = ACPWire()
        prefix.call("commander_ask", result: envelope("pending"))
        prefix.call("commander_wait", result: envelope("answered", id: String(request.dropLast()), answer: "no"))
        #expect(prefix.flows().map { $0.calls.count } == [1, 1])
        #expect(prefix.flows()[0].status == .waitingForReply)
    }

    @Test func anotherWorkersRecordNeverAnswersThisConsolesQuestion() throws {
        var wire = ACPWire()
        wire.call("commander_ask", result: envelope("pending"))
        let foreign = wire.call("commander_wait", result: envelope("answered", answer: "not ours", worker: otherWorker))

        let flows = wire.flows()
        #expect(flows.count == 2 && flows[0].calls.count == 1 && flows[1].link == .single)
        #expect(flows[0].status == .waitingForReply && flows[0].outcome == nil)
        let stray = try #require(flows[1].calls.first)
        #expect(stray.entry.id == foreign && stray.consoleWorker == worker && stray.recordIsAnotherWorkers)
        #expect(stray.requestID == nil && stray.recordedAnswer == nil && stray.question == nil)
        #expect(ActivityWords.commander(stray).done.plain == "Waited for a reply")
        // Two separate lines: the question, and a wait that says nothing about it.
        let lines = wire.groups().flatMap(\.lines)
        #expect(lines.map(\.sentence.plain) == ["Asked: “\(askedText)”", "Waited for a reply"])
        #expect(lines.allSatisfy { $0.kind == .call })
    }

    @Test func aRecordForADifferentRequestThanTheWaitNamedIsNotRead() throws {
        var wire = ACPWire()
        wire.call("commander_ask", result: envelope("pending"))
        wire.call("commander_wait", detail: #"{"request_id":"\#(request)"}"#,
                  result: envelope("answered", id: otherRequest, answer: "someone else's"))

        let flow = try #require(wire.flows().first)
        #expect(wire.flows().count == 1 && flow.calls.count == 2)
        #expect(flow.status == .waitingForReply && flow.outcome == nil)
        #expect(flow.calls[1].recordedAnswer == nil)
        let made = wire.groups()
        #expect(made.count == 1 && made[0].isSingle && made[0].lines[0].tag?.word == "waiting")
        #expect(made[0].lines[0].sentence.plain == "Asked: “\(askedText)”")
    }

    @Test func aCutResultLinksNothing() {
        var wire = ACPWire()
        wire.call("commander_ask", result: envelope("pending"))
        let whole = envelope("answered", answer: answerText)
        wire.call("commander_wait", result: String(whole.prefix(whole.count - 9)))
        wire.call("commander_wait", result: "[Large tool payload omitted from console preview]")

        let flows = wire.flows()
        #expect(flows.map { $0.calls.count } == [1, 1, 1])
        #expect(flows[0].status == .waitingForReply)
        #expect(flows.dropFirst().allSatisfy { $0.link == .single && $0.outcome == nil })
        #expect(ActivityWords.commander(flows[1].calls[0]).done.plain == "Waited for a reply")
    }

    @Test func aPendingWaitKeepsTheQuestionOpen() {
        var wire = ACPWire()
        wire.call("commander_ask", result: envelope("pending"))
        wire.call("commander_wait", result: envelope("pending"))
        var made = wire.groups()
        #expect(made.count == 1 && made[0].isSingle)
        #expect(made[0].lines[0].sentence.plain == "Asked: “\(askedText)”" && made[0].lines[0].tag?.word == "waiting")
        #expect(wire.flows()[0].outcome == nil)

        // Repeated waits on the same request stay inside the one line; the latest record speaks.
        wire.call("commander_wait", result: envelope("pending"))
        wire.call("commander_wait", result: envelope("answered", answer: answerText))
        wire.call("commander_wait", result: envelope("answered", answer: answerText))
        made = wire.groups()
        #expect(made.count == 1 && made[0].lines.count == 1 && made[0].lines[0].tag == nil)
        #expect(wire.flows().count == 1 && wire.flows()[0].steps == "Ask · Wait ×4")
        #expect(wire.flows()[0].outcome == "answer “\(answerText)”")
    }

    @Test func aWithdrawnOrCancelledQuestionIsNeverAnswered() {
        var wire = ACPWire()
        wire.call("Bash", detail: "ls", result: "a", server: "")
        wire.call("commander_ask", result: envelope("pending"))
        wire.call("commander_wait", result: envelope("pending"))
        wire.call("commander_withdraw_question", result: envelope("cancelled"))
        var made = wire.groups()
        #expect(made.count == 1 && made[0].lines.count == 2)
        #expect(made[0].lines[1].sentence.plain == "Asked: “\(askedText)”" && made[0].lines[1].tag?.word == "cancelled")
        #expect(made[0].summary.text == "Ran a command, asked a question and withdrew it")
        #expect(wire.flows()[0].status == .cancelled && wire.flows()[0].outcome == nil)

        // The run says the request is cancelled: a call's earlier text does not make it answered.
        wire = ACPWire()
        wire.call("Bash", detail: "ls", result: "a", server: "")
        wire.call("commander_ask", result: envelope("pending"))
        wire.call("commander_wait", result: envelope("cancelled", answer: "stale text"))
        let cancelled = Question(id: request, workerID: worker, question: askedText, status: "cancelled", answer: "")
        let states: [[Question]] = [[], [cancelled]]
        for live in states {
            made = wire.groups(live: live)
            #expect(made.count == 1 && made[0].lines[1].tag?.word == "cancelled")
            #expect(made[0].summary.text == "Ran a command, asked a question")
            #expect(wire.flows(live: live)[0].status == .cancelled && wire.flows(live: live)[0].outcome == nil)
            #expect(wire.flows(live: live)[0].calls[1].recordedAnswer == nil)
        }
    }
}
