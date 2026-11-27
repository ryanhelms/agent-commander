import Foundation
import Testing
@testable import AgentCommander

// The focused Pretty review: request choices from the service, the question shown beside them,
// the run status read from the transcript, and which consoles use the view.

private let formatted = "Retry the flaky test?\nReply with one of the IDs in brackets.\nRun once [run-once]\nSkip [skip-test]"
private let offered = [QuestionChoice(id: "run-once", label: "Run once"), QuestionChoice(id: "skip-test", label: "Skip")]

private func request(question: String, choices: [QuestionChoice]) -> RequestPresentation {
    RequestPresentation(
        id: "q-1", shortID: "q-1", question: question, workerID: "w-1", workerName: "Retry policy review",
        workerIsCoordinator: false, client: .claude, runID: "r-1", runTitle: "Retry policy", project: "Relay",
        host: "local", platform: HostPlatform(serviceHost: "local"), inputHolder: "Retry policy",
        contextTail: [], choices: choices)
}

@Test func questionDecodesChoicesFromJSONAndProjection() throws {
    let json = #"{"id":"q-1","worker_id":"w-1","question":"Q","status":"pending","answer":"","choices":[{"id":"run-once","label":"Run once"},{"id":"skip-test","label":"Skip"}]}"#
    let decoded = try JSONDecoder().decode(Question.self, from: Data(json.utf8))
    #expect(decoded.choices == offered)
    let projected = try Question(projection: AGUIValue(json: json))
    #expect(projected == decoded)
}

@Test func questionWithoutChoicesStaysFreeForm() throws {
    let json = #"{"id":"q-1","worker_id":"w-1","question":"Q","status":"pending","answer":""}"#
    #expect(try JSONDecoder().decode(Question.self, from: Data(json.utf8)).choices == nil)
    #expect(try Question(projection: AGUIValue(json: json)).choices == nil)
}

@Test func malformedOrLegacyChoicesLeaveTheRequestFreeForm() throws {
    for choices in [#"[{"id":"run-once"}]"#, #"["Run once","Skip"]"#, #"[]"#, #""run-once""#] {
        let json = #"{"id":"q-1","worker_id":"w-1","question":"Q","status":"pending","answer":"","choices":\#(choices)}"#
        let projected = try Question(projection: AGUIValue(json: json))
        let decoded = try JSONDecoder().decode(Question.self, from: Data(json.utf8))
        #expect(projected.choices == nil)
        #expect(decoded == projected)
    }
}

@Test func choiceListIsLeftOutOnlyWhenItMatchesTheChoices() {
    #expect(request(question: formatted, choices: offered).promptWithoutChoiceList == "Retry the flaky test?")
    // A different list is not the service's formatting of these choices: shown as sent.
    #expect(request(question: formatted, choices: [offered[0]]).promptWithoutChoiceList == formatted)
    #expect(request(question: formatted, choices: []).promptWithoutChoiceList == formatted)
}

@Test func prettyReviewAppliesOnlyToPrettyWithABoundSession() {
    let session = NativeSession(harnessInstance: "claude-acp", sessionID: "s-1")
    #expect(PrettyACPScope.applies(mode: .pretty, session: session))
    #expect(!PrettyACPScope.applies(mode: .console, session: session))
    #expect(!PrettyACPScope.applies(mode: .terminal, session: session))
    #expect(!PrettyACPScope.applies(mode: .pretty, session: nil))
    #expect(!PrettyACPScope.applies(mode: .pretty, session: NativeSession(harnessInstance: "x", sessionID: "")))
}

@Test func runStatusReadsTheOpenToolAndCounts() {
    let failed = ToolResult(output: "", error: "exit 1")
    let entries = [
        TranscriptEntry(id: "1", kind: .prose("Fix it", fromUser: true)),
        TranscriptEntry(id: "2", kind: .tool(name: "Bash", detail: nil, result: failed)),
        TranscriptEntry(id: "3", kind: .tool(name: "Edit", detail: nil, result: nil)),
    ]
    let running = PrettyRunStatus(state: .working, entries: entries)
    #expect(running.phase == .runningTool("Edit"))
    #expect(running.isLive)
    #expect(running.counts == "1 prompt · 2 tools · 1 failed")
    #expect(PrettyRunStatus(state: .working, entries: Array(entries.prefix(1))).phase == .responding)
    #expect(PrettyRunStatus(state: .needsInput, entries: entries).phase == .waiting)
    #expect(PrettyRunStatus(state: .idle, entries: []).counts == "0 prompts")
}

/// A run whose worker `w2` asks a choice question while `openCalls` have no result. Each open call
/// is followed by enough replies that only the last one stays inside the PiP's recent window.
private func approvalContent(openCalls: [String]) throws -> RunContent {
    var messages: [String] = []
    for (index, call) in openCalls.enumerated() {
        messages.append(#"{"id":"c\#(index)","role":"assistant","toolCalls":[{"id":"\#(call)","type":"function","function":{"name":"Bash","arguments":"{}"}}]}"#)
        if index < openCalls.count - 1 {
            for reply in 0..<TranscriptEntry.recentWindow {
                messages.append(#"{"id":"r\#(index)-\#(reply)","role":"assistant","content":"Step \#(reply)"}"#)
            }
        }
    }
    func worker(_ id: String, role: String, messages: [String] = []) -> String {
        #"{"id":"\#(id)","name":"\#(id)","role":"\#(role)","parent_id":"","run_id":"r1","state":"waiting","host":"local","worktree":"/p","task":"t","output":"","messages":[\#(messages.joined(separator: ","))]}"#
    }
    let request = #"{"id":"q1","worker_id":"w2","question":"Run it?","status":"pending","answer":"","choices":[{"id":"run-once","label":"Run once"}]}"#
    let json = #"{"runs":[{"id":"r1","project":"p","path":"/p","task":"t","client":"claude","coordinator_id":"w1","status":"running","requests":[\#(request)],"workers":[\#(worker("w1", role: "coordinator")),\#(worker("w2", role: "worker", messages: messages))]}]}"#
    return try RunContent(run: #require(Run.list(json: Data(json.utf8)).first))
}

@Test func pipApprovalCallIsResolvedFromTheWholeTranscript() throws {
    func request(_ content: RunContent) -> RequestPresentation? {
        content.wall.workers.first { $0.id == "w2" }?.request
    }
    // One open call: the PiP marks it, as the focused worker does.
    let single = try #require(request(approvalContent(openCalls: ["call-b"])))
    #expect(single.awaitingApprovalToolID == "call-b")
    // A competing open call has been trimmed out of the PiP's window. The window alone shows one
    // open call, but the whole transcript has two, so no call is marked.
    let trimmed = try #require(request(approvalContent(openCalls: ["call-a", "call-b"])))
    #expect(!trimmed.contextEntries.contains { $0.id == "call-a" })
    #expect(trimmed.contextEntries.contains { $0.id == "call-b" })
    #expect(trimmed.awaitingApprovalToolID == nil)
    // Console and Terminal keep the four-entry window. Pretty reads the worker's current turn,
    // which here is the whole transcript: no prompt opens a later one.
    #expect(trimmed.contextEntries == TranscriptEntry.recent(trimmed.turnEntries))
    #expect(trimmed.turnEntries.contains { $0.id == "call-a" })
    #expect(trimmed.prettyEntries == trimmed.turnEntries)
    #expect(ToolStatus.awaitingApproval.word == "Awaiting approval")
}
