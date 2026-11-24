import Foundation
import Testing
@testable import AgentCommander

// Tool results the transcript must not lose: one with no text and no call, several for one call,
// and the worker's own feed members in its record.

private func message(_ json: String) throws -> AGUIMessage {
    try AGUIMessage(fields: AGUIValue(json: json))
}

private func detail(_ entryID: String, _ messages: [AGUIMessage]) -> ConsoleRecordDetail? {
    let worker = Worker(id: "w", name: "w", role: "worker", parentID: "", runID: "r", state: "working",
                        host: "local", worktree: "", task: "t", output: "", messages: messages)
    let run = Run(id: "r", project: "p", path: "/p", task: "t", client: "codex", coordinatorID: "w",
                  status: "running", workers: [worker], requests: nil)
    return ConsoleRecordDetail.resolve(entryID: entryID, worker: worker, run: run)
}

@Suite struct ToolResultRecordTests {
    @Test func anOrphanResultWithNoTextKeepsAnEntryAndItsFields() throws {
        let empty = #"{"id":"w:2","role":"tool","toolCallId":"gone","content":"","metadata":{"acp":{"source":"live","cursor":"c-2","kind":"tool_call_update","rawOutput":{"exit":0}}}}"#
        let messages = [
            try message(#"{"id":"w:1","role":"user","content":"go"}"#),
            try message(empty),
            // No content member at all, and no ACP reference.
            try message(#"{"id":"w:3","role":"tool","toolCallId":"gone","vendor":{"depth":[1]}}"#),
            try message(#"{"id":"w:4","role":"tool","toolCallId":"gone","content":"late"}"#)
        ]
        let entries = TranscriptEntry.entries(from: messages)

        // Console: one entry per result, in order, under the message's own ID.
        #expect(entries.map(\.id) == ["w:1", "w:2", "w:3", "w:4"])
        #expect(entries[1].kind == .other(role: "tool", text: ""))
        #expect(entries[1].sourceIDs == ["w:2"])
        #expect(entries[2].kind == .other(role: "tool", text: ""))
        #expect(entries[3].kind == .output(ToolResult(output: "late")))

        // Pretty shows the same entries.
        let shown = TranscriptEntry.conversation(entries).filter(PrettyContent.isSubstantive)
        #expect(shown.map(\.id) == ["w:1", "w:2", "w:3", "w:4"])

        // Both modes resolve the entry by the original message ID, with every field.
        let record = try #require(detail("w:2", messages))
        #expect(record.title == "Tool result")
        #expect(try AGUIValue(json: record.sections[0].json) == AGUIValue(json: empty))
        #expect(record.sections.map(\.id) == ["message", "sources", "worker", "feed", "run"])
        let bare = try #require(detail("w:3", messages))
        #expect(try AGUIValue(json: bare.sections[0].json)["vendor"]?["depth"]?[0] == 1)
    }

    @Test func everyResultOfOneCallIsInTheCallsFields() throws {
        let messages = [
            try message(#"{"id":"w:1","role":"assistant","toolCalls":[{"id":"w:t1","type":"function","function":{"name":"shell","arguments":"{}"}}]}"#),
            try message(#"{"id":"w:2","role":"tool","toolCallId":"w:t1","content":"first","metadata":{"acp":{"source":"live","cursor":"c-2","kind":"tool_call_update"}}}"#),
            try message(#"{"id":"w:3","role":"tool","toolCallId":"w:t1","content":"","error":"exit 1"}"#),
            try message(#"{"id":"w:4","role":"tool","toolCallId":"w:t1","content":"final","metadata":{"acp":{"source":"live","cursor":"c-4","kind":"tool_call_update"}}}"#)
        ]
        // One entry for the call, showing the last result. No result has an entry of its own.
        let entries = TranscriptEntry.entries(from: messages)
        #expect(entries.map(\.id) == ["w:t1"])
        #expect(entries[0].kind == .tool(name: "shell", detail: nil, result: ToolResult(output: "final")))

        let record = try #require(detail("w:t1", messages))
        #expect(record.sections.map(\.id) == ["call", "result:w:2", "result:w:3", "result", "message", "sources", "worker", "feed", "run"])
        #expect(record.sections.map(\.title).prefix(4) == ["Call", "Result 1", "Result 2", "Result 3"])
        #expect(try AGUIValue(json: record.sections[1].json) == messages[1].allFields)
        #expect(try AGUIValue(json: record.sections[2].json)["error"] == "exit 1")
        #expect(try AGUIValue(json: record.sections[3].json) == messages[3].allFields)
        // Sources of every result, oldest first, each once.
        let sourceSection = try #require(record.sections.first { $0.id == "sources" })
        let sources = try AGUIValue(json: sourceSection.json)
        #expect(sources.arrayValue?.map { $0["cursor"]?.stringValue } == ["c-2", "c-4"])
        // Each section copies under its own title.
        #expect(try AGUIValue(json: record.combinedJSON)["Result 1"]?["content"] == "first")

        // A single result keeps the section it had.
        let single = try #require(detail("w:t1", Array(messages.prefix(2))))
        #expect(single.sections.map(\.id).prefix(3) == ["call", "result", "message"])
        #expect(single.sections[1].title == "Result")
    }

    @Test func aWorkersFeedSectionHoldsItsExactChunksAndMessagesOnly() throws {
        var reducer = AGUIWorkspaceReducer()
        try reducer.apply(frame: """
            {"type":"STATE_SNAPSHOT","snapshot":{"runs":[{"id":"r","project":"p","path":"/p","task":"t","client":"codex",\
            "coordinator_id":"w1","status":"running","workers":[\
            {"id":"w1","name":"one","role":"coordinator","parent_id":"","run_id":"r","state":"working","host":"local",\
            "worktree":"/p","task":"t","outputChunks":["a\\n","","b"],"messages":[{"id":"m1","role":"assistant","content":"hello","extra":[1.50]}]},\
            {"id":"w2","name":"two","role":"worker","parent_id":"w1","run_id":"r","state":"working","host":"local",\
            "worktree":"/p","task":"t","outputChunks":["other worker"],"messages":[{"id":"m2","role":"assistant","content":"other worker"}]}]}]}}
            """)
        let run = reducer.runs[0]
        let worker = try #require(run.workers?.first)
        #expect(worker.outputChunks == ["a\n", "", "b"])
        #expect(worker.output == "a\nb")
        #expect(worker.allFields["outputChunks"] == nil)

        let record = try #require(ConsoleRecordDetail.resolve(entryID: "m1", worker: worker, run: run))
        let feedSection = try #require(record.sections.first { $0.id == "feed" })
        let feed = try AGUIValue(json: feedSection.json)
        let original = try #require(worker.messages?.first)
        #expect(feed["outputChunks"] == ["a\n", "", "b"])
        #expect(feed["messages"] == .array([original.allFields]))
        #expect(feed["messages"]?[0]?["extra"]?[0]?.numberValue?.literal == "1.50")
        #expect(!record.combinedJSON.contains("other worker"))

        // A change to the chunks is a different worker, and the section follows it.
        try reducer.apply(frame: #"{"type":"STATE_DELTA","delta":[{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"c"}]}"#)
        let next = try #require(reducer.runs[0].workers?.first)
        #expect(next != worker)
        #expect(worker.outputChunks == ["a\n", "", "b"])
        let after = try #require(ConsoleRecordDetail.resolve(entryID: "m1", worker: next, run: reducer.runs[0]))
        let afterFeed = try #require(after.sections.first { $0.id == "feed" })
        #expect(try AGUIValue(json: afterFeed.json)["outputChunks"] == ["a\n", "", "b", "c"])
    }
}
