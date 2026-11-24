import Foundation
import Testing
@testable import AgentCommander

// Messages here use the service's wire shape for a live ACP reply: one assistant message per
// `agent_message_chunk`, with ID `<worker>:<sequence>` and the chunk's reference in `metadata.acp`.

private func chunk(_ sequence: Int, _ text: String, messageID: String? = nil, turnID: String? = nil,
                   source: String = "live") throws -> AGUIMessage {
    var acp: [String: AGUIValue] = [
        "source": .string(source), "cursor": .string("cursor-\(sequence)"),
        "kind": "agent_message_chunk", "contentType": "text"
    ]
    if let messageID { acp["messageId"] = .string(messageID) }
    if let turnID { acp["turnId"] = .string(turnID) }
    return try AGUIMessage(fields: [
        "id": .string("w:\(sequence)"), "role": "assistant", "content": .string(text),
        "metadata": ["acp": .object(acp)]
    ])
}

private func message(_ json: String) throws -> AGUIMessage {
    try AGUIMessage(fields: AGUIValue(json: json))
}

/// Cuts `text` into exactly `count` pieces of uneven length, the way tokens arrive.
private func pieces(of text: String, count: Int) -> [String] {
    let characters = Array(text)
    precondition(characters.count >= count)
    var cuts: [String] = []
    var start = 0
    for index in 0..<count {
        let end = index == count - 1 ? characters.count : max(start + 1, characters.count * (index + 1) / count)
        cuts.append(String(characters[start..<end]))
        start = end
    }
    return cuts
}

private let reply = """
    Here is the fix, in two parts.

    1. Keep the **exact** whitespace:

    ```swift
    func join(_ chunks: [String]) -> String {
        chunks.joined()   // no separator, no trimming
    }
    ```

    2. Then run `swift test`.  \nA hard break sits above, and a trailing newline below.

    """

@Suite struct ConversationChunkTests {
    @Test func aStreamedReplyIsOneTurnInPrettyAndEveryChunkInConsole() throws {
        let tokens = pieces(of: reply, count: 87)
        #expect(tokens.count == 87)
        let prompt = try message(#"{"id":"w:1","role":"user","content":"fix it"}"#)
        let chunks = try tokens.enumerated().map { try chunk($0.offset + 2, $0.element) }
        let entries = TranscriptEntry.entries(from: [prompt] + chunks)

        // Console: the prompt and one entry per chunk, in the order they arrived.
        #expect(entries.count == 88)
        #expect(entries.map(\.id) == ["w:1"] + chunks.map(\.id))

        // Pretty: the prompt and one reply.
        let shown = TranscriptEntry.conversation(entries)
        #expect(shown.count == 2)
        #expect(shown[0] == entries[0])
        #expect(shown[1].kind == .prose(reply, fromUser: false))
        #expect(shown[1].id == "w:2#chunks")
        #expect(shown[1].sourceIDs == chunks.map(\.id))
        #expect(shown[1].plainText == reply)
    }

    /// The defect Computer Use found: Console drew each token of a reply on its own line
    /// ("The" / "sw" / "atch" … "C" / "ED" / "AR"). Console now lays out the same joined turn
    /// Pretty does, and keeps everything else as the service wrote it.
    @Test func consoleReadsAStreamedReplyAsOneTurnAndKeepsEveryRecord() throws {
        let tokens = ["The", " sw", "atch", " is", " teal", ",\n", "and", " your", " receipt", " code", " is\n\n",
                      "  C", "ED", "AR", "-", "472", "91", ".", "\n"]
        let replyText = "The swatch is teal,\nand your receipt code is\n\n  CEDAR-47291.\n"
        #expect(tokens.joined() == replyText)
        let usage = "[ACP usage_update] 11232 / 475000 tokens"
        let stderr = "[Provider stderr] warn: retrying\n  attempt 2"

        var messages = [
            try message(#"{"id":"w:1","role":"user","content":"Will you help me review a color swatch?"}"#),
            try message(#"{"id":"w:2","role":"assistant","toolCalls":[{"id":"call-1","type":"function","function":{"name":"mcp.commander.commander_result","arguments":"{}"}}],"metadata":{"acp":{"source":"live","cursor":"cursor-2","kind":"tool_call"}}}"#),
            try message(#"{"id":"w:3","role":"tool","toolCallId":"call-1","content":"ok","metadata":{"acp":{"source":"live","cursor":"cursor-3","kind":"tool_call_update"}}}"#),
            try message(#"{"id":"w:4","role":"system","content":"\#(usage)","metadata":{"acp":{"source":"live","cursor":"cursor-4","kind":"usage_update","usage":{"used":11232,"size":475000}}}}"#)
        ]
        // w:5 … w:23: the reply, one message per token.
        messages += try tokens.enumerated().map { try chunk($0.offset + 5, $0.element, turnID: "t1") }
        messages += [
            // A harness diagnostic with no ACP reference, then the same turn goes on.
            try AGUIMessage(fields: ["id": "w:24", "role": "system", "content": .string(stderr)]),
            try chunk(25, "Done", turnID: "t1"),
            try chunk(26, ".", turnID: "t1"),
            // A result whose call was never sent, with nothing to read.
            try message(#"{"id":"w:27","role":"tool","toolCallId":"gone","content":""}"#),
            // A reply that is only whitespace.
            try chunk(28, " ", turnID: "t2"),
            try chunk(29, "\n", turnID: "t2")
        ]
        let entries = TranscriptEntry.entries(from: messages)
        let console = TranscriptEntry.displayed(entries, mode: .console)

        // Chronological, one entry per reply, a boundary at the tool, the note and the diagnostic.
        #expect(console.map(\.id) == [
            "w:1", "call-1", "w:4", "w:5#chunks", "w:24", "w:25#chunks", "w:27", "w:28#chunks"
        ])
        // The reply is the character stream: no token on its own line, every byte as sent.
        #expect(console[3].kind == .prose(replyText, fromUser: false))
        #expect(console[3].plainText == replyText)
        #expect(Array(console[3].plainText.utf8) == Array(replyText.utf8))
        #expect(console[3].plainText.contains("  CEDAR-47291."))
        #expect(console[3].sourceIDs == (5...23).map { "w:\($0)" })
        #expect(console[5].kind == .prose("Done.", fromUser: false))
        #expect(console[5].sourceIDs == ["w:25", "w:26"])

        // Console keeps the service's own text for the usage note and the diagnostic, each as
        // its own entry in place. Nothing is summarised or folded into an activity.
        #expect(console[2].kind == .other(role: "system", text: usage))
        #expect(console[4].kind == .other(role: "system", text: stderr))
        #expect(console[2] == entries.first { $0.id == "w:4" })
        #expect(console[4] == entries.first { $0.id == "w:24" })
        // The tool call with its result, the orphan result and the whitespace reply are all there.
        #expect(console[1].kind == .tool(name: "mcp.commander.commander_result", detail: nil,
                                         result: ToolResult(output: "ok", error: nil)))
        #expect(console[6].kind == .other(role: "tool", text: ""))
        #expect(console[7].kind == .other(role: "assistant", text: " \n"))
        #expect(console[7].sourceIDs == ["w:28", "w:29"])
        #expect(console[0] == entries[0])

        // Pretty joins the same runs under the same IDs. Only its policy differs: the note is a summary.
        let pretty = TranscriptEntry.displayed(entries, mode: .pretty)
        #expect(pretty.map(\.id) == console.map(\.id))
        #expect(pretty[3] == console[3])
        #expect(pretty[2].kind == .other(role: "system", text: "Context 11.2k of 475k tokens"))
        #expect(pretty == TranscriptEntry.conversation(entries).filter(PrettyContent.isSubstantive))
        #expect(TranscriptEntry.folded(entries, policy: .console) == console)

        // Every original message is reached from a disclosure, in both modes, each exactly once.
        for shown in [console, pretty] {
            let reached = shown.flatMap { ConsoleRecordDetail.messageIDs(entryID: $0.id, in: messages) }
            #expect(reached.sorted() == messages.map(\.id).sorted())
            for entry in shown where entry.sourceIDs.count > 1 {
                #expect(ConsoleRecordDetail.messageIDs(entryID: entry.id, in: messages) == entry.sourceIDs)
            }
        }
        #expect(ConsoleRecordDetail.messageIDs(entryID: "call-1", in: messages) == ["w:2", "w:3"])
        #expect(ConsoleRecordDetail.messageIDs(entryID: "w:27", in: messages) == ["w:27"])
        #expect(ConsoleRecordDetail.messageIDs(entryID: "w:99", in: messages).isEmpty)

        // The grouped inspector lists each chunk whole, with its exact content.
        let turn = try #require(ConversationChunks.turn(entryID: console[3].id, in: messages))
        let sections = ConsoleRecordDetail.turnSections(turn)
        #expect(try AGUIValue(json: sections[0].json)["content"] == .string(replyText))
        #expect(try AGUIValue(json: sections[1].json) == .array(turn.map(\.allFields)))

        // The request surface's window (the PiP) joins the same way and never opens inside a reply.
        let recent = TranscriptEntry.displayed(TranscriptEntry.recent(entries, count: 4), mode: .console)
        #expect(recent.map(\.id) == ["w:24", "w:25#chunks", "w:27", "w:28#chunks"])

        // A transcript with no live chunks is laid out exactly as it was built.
        let plain = Array(entries.prefix(3))
        #expect(TranscriptEntry.displayed(plain, mode: .console) == plain)
    }

    @Test func joinedTextKeepsStreamingWhitespaceAndCodeFences() throws {
        let tokens = ["\n", "Here", " is", " the", " fix", ":\n\n", "```swift\n", "    let x", " = 1\n", "\n",
                      "\tlet y = 2\n", "```", "\n\n", "- one\n", "- two  \n", "  ", "indented tail ", " "]
        let entries = TranscriptEntry.entries(from: try tokens.enumerated().map { try chunk($0.offset + 1, $0.element) })

        // Console keeps its trimmed reading of each message. A chunk that is only whitespace
        // still has an entry, and its exact text is retained.
        #expect(entries.count == tokens.count)
        #expect(entries[2].kind == .prose("is", fromUser: false))
        #expect(entries[9].kind == .other(role: "assistant", text: ""))
        #expect(entries.compactMap { $0.origin?.chunk?.text } == tokens)

        let shown = TranscriptEntry.conversation(entries)
        #expect(shown.count == 1)
        #expect(shown[0].kind == .prose(tokens.joined(), fromUser: false))
        #expect(PrettyContent.isSubstantive(shown[0]))
    }

    @Test func aReplyOfOnlyWhitespaceKeepsARowForItsFields() throws {
        let messages = [
            try message(#"{"id":"w:1","role":"user","content":"hi"}"#),
            try chunk(2, "\n", messageID: "m1"),
            try chunk(3, "  ", messageID: "m1"),
            // Whitespace beside text in one reply stays part of that reply's prose.
            try chunk(4, "\n", messageID: "m2"),
            try chunk(5, "Done", messageID: "m2"),
            try chunk(6, " \n", messageID: "m2")
        ]
        let shown = TranscriptEntry.conversation(TranscriptEntry.entries(from: messages))
            .filter(PrettyContent.isSubstantive)
        #expect(shown.map(\.id) == ["w:1", "w:2#chunks", "w:4#chunks"])

        // The whitespace-only turn: the assistant's record with no text, under the first chunk's
        // turn ID, standing for every chunk, with the content exactly as sent.
        #expect(shown[1].kind == .other(role: "assistant", text: "\n  "))
        #expect(shown[1].sourceIDs == ["w:2", "w:3"])
        #expect(!ConversationActivity.isRoutine(shown[1]))
        let turn = try #require(ConversationChunks.turn(entryID: shown[1].id, in: messages))
        #expect(turn.map(\.id) == ["w:2", "w:3"])
        #expect(ConversationChunks.text(of: turn) == "\n  ")

        #expect(shown[2].kind == .prose("\nDone \n", fromUser: false))
        #expect(shown[2].sourceIDs == ["w:4", "w:5", "w:6"])
    }

    @Test func prettyLeavesOutAnAssignmentOnlyWhenAPromptRepeatsItExactly() throws {
        let task = "Will you help me review a color swatch?"
        let media = #"{"source":"live","kind":"acp.prompt_part","turnId":"op-7","contentType":"image","mimeType":"image/png","itemCount":1}"#
        func entries(_ role: String, _ content: String, acp: String? = nil) throws -> [TranscriptEntry] {
            var fields: [String: AGUIValue] = ["id": "w:1", "role": .string(role), "content": .string(content)]
            if let acp { fields["metadata"] = ["acp": try AGUIValue(json: acp)] }
            return TranscriptEntry.entries(from: [try AGUIMessage(fields: .object(fields))])
        }

        #expect(PrettyContent.repeatsAssignment(task, in: try entries("user", task)))
        #expect(PrettyContent.repeatsAssignment(task + "\n", in: try entries("user", "\n" + task + " ")))
        // The service's media marker is not the developer's text, when the reference vouches for it.
        #expect(PrettyContent.repeatsAssignment(task, in: try entries("user", task + "\n[ACP image] image/png", acp: media)))
        #expect(!PrettyContent.repeatsAssignment(task, in: try entries("user", task + "\n[ACP image] image/png")))

        // A partial match, another role, a different task and an empty one keep the assignment.
        #expect(!PrettyContent.repeatsAssignment(task, in: try entries("user", task + " Say you are ready.")))
        #expect(!PrettyContent.repeatsAssignment(task, in: try entries("user", "review a color swatch")))
        #expect(!PrettyContent.repeatsAssignment(task, in: try entries("assistant", task)))
        #expect(!PrettyContent.repeatsAssignment(task, in: try entries("system", task)))
        #expect(!PrettyContent.repeatsAssignment("Another task", in: try entries("user", task)))
        #expect(!PrettyContent.repeatsAssignment("", in: try entries("user", task)))
        #expect(!PrettyContent.repeatsAssignment(task, in: []))
    }

    @Test func turnsEndAtMessageIdentityToolsUsersAndOtherRecords() throws {
        let messages = [
            try message(#"{"id":"w:1","role":"user","content":"hi"}"#),
            try chunk(2, "A", messageID: "m1"),
            try chunk(3, "B", messageID: "m1"),
            try chunk(4, "C", messageID: "m2"),
            try chunk(5, "D"),
            try message(#"{"id":"w:6","role":"assistant","toolCalls":[{"id":"w:t1","type":"function","function":{"name":"shell","arguments":"{}"}}],"metadata":{"acp":{"source":"live","cursor":"cursor-6","kind":"tool_call"}}}"#),
            try chunk(7, "E"),
            // The result of the earlier call has no entry of its own, and still ends the reply.
            try message(#"{"id":"w:8","role":"tool","toolCallId":"w:t1","content":"ok","metadata":{"acp":{"source":"live","cursor":"cursor-8","kind":"tool_call_update"}}}"#),
            try chunk(9, "F"),
            try message(#"{"id":"w:10","role":"system","content":"usage_update used=45200 size=200000","metadata":{"acp":{"source":"live","cursor":"cursor-10","kind":"usage_update","usage":{"used":45200,"size":200000,"cost":{"amount":0.42,"currency":"USD"}}}}}"#),
            try chunk(11, "G", turnID: "t1"),
            try chunk(12, "H", turnID: "t2"),
            // Provider history is not a live stream: each record is a whole message.
            try chunk(13, "I", source: "provider"),
            try chunk(14, "J", source: "provider"),
            // Messages with no ACP reference are whole messages.
            try message(#"{"id":"w:15","role":"assistant","content":"K"}"#),
            try message(#"{"id":"w:16","role":"assistant","content":"L"}"#),
            try message(#"{"id":"w:17","role":"user","content":"thanks"}"#)
        ]
        let entries = TranscriptEntry.entries(from: messages)
        let shown = TranscriptEntry.conversation(entries)

        #expect(shown.map(\.id) == [
            "w:1", "w:2#chunks", "w:4#chunks", "w:5#chunks", "w:t1", "w:7#chunks", "w:9#chunks", "w:10",
            "w:11#chunks", "w:12#chunks", "w:13", "w:14", "w:15", "w:16", "w:17"
        ])
        #expect(shown[1].kind == .prose("AB", fromUser: false))
        #expect(shown[1].sourceIDs == ["w:2", "w:3"])
        #expect(shown[2].kind == .prose("C", fromUser: false))
        #expect(shown[3].sourceIDs == ["w:5"])
        #expect(shown[5].kind == .prose("E", fromUser: false))
        #expect(shown[6].kind == .prose("F", fromUser: false))
        // The usage record reads as one line in Pretty. Console keeps the service's text.
        #expect(shown[7].kind == .other(role: "system", text: "Context 45.2k of 200k tokens · 0.42 USD"))
        #expect(entries.first { $0.id == "w:10" }?.kind == .other(role: "system", text: "usage_update used=45200 size=200000"))
        // Whole messages are passed through untouched.
        #expect(Array(shown[10...]) == Array(entries.suffix(5)))
        #expect(shown[12].origin == nil)

        // Console is unchanged by any of this: one entry per message that has one.
        #expect(entries.map(\.id) == [
            "w:1", "w:2", "w:3", "w:4", "w:5", "w:t1", "w:7", "w:9", "w:10", "w:11", "w:12", "w:13", "w:14",
            "w:15", "w:16", "w:17"
        ])
    }

    @Test func aTurnResolvesToEveryOriginalMessage() throws {
        let messages = [
            try message(#"{"id":"w:1","role":"user","content":"hi"}"#),
            try chunk(2, " Hello", messageID: "m1"),
            try chunk(3, ",\n", messageID: "m1"),
            try chunk(4, "world ", messageID: "m1"),
            try chunk(5, "Next", messageID: "m2")
        ]
        let turn = try #require(ConversationChunks.turn(entryID: "w:2#chunks", in: messages))
        #expect(turn.map(\.id) == ["w:2", "w:3", "w:4"])
        #expect(ConversationChunks.text(of: turn) == " Hello,\nworld ")

        // A chunk's own ID is its own record, as Console asks for it. Other IDs are not turns.
        #expect(ConversationChunks.turn(entryID: "w:2", in: messages) == nil)
        #expect(ConversationChunks.turn(entryID: "w:1#chunks", in: messages) == nil)
        #expect(ConversationChunks.turn(entryID: "w:9#chunks", in: messages) == nil)
        // A turn asked for by a later chunk starts there, as a window that opens mid-reply does.
        #expect(ConversationChunks.turn(entryID: "w:3#chunks", in: messages)?.map(\.id) == ["w:3", "w:4"])

        let sections = ConsoleRecordDetail.turnSections(turn)
        #expect(sections.map(\.id) == ["turn", "chunks"])
        let summary = try AGUIValue(json: sections[0].json)
        #expect(summary["content"] == " Hello,\nworld ")
        #expect(summary["id"] == "w:2#chunks")
        #expect(summary["acpMessageId"] == "m1")
        #expect(summary["chunkCount"] == 3)
        #expect(summary["messageIds"] == ["w:2", "w:3", "w:4"])
        // Each chunk's message is there whole: its ID, exact content and ACP reference.
        #expect(try AGUIValue(json: sections[1].json) == .array(turn.map(\.allFields)))
        #expect(try AGUIValue(json: sections[1].json)[1]?["metadata"]?["acp"]?["cursor"] == "cursor-3")
    }

    @Test func aTurnKeepsItsIDWhileChunksArriveAndInsideARequestWindow() throws {
        let tokens = pieces(of: reply, count: 87)
        let head = [
            try message(#"{"id":"w:1","role":"user","content":"one"}"#),
            try message(#"{"id":"w:2","role":"assistant","content":"two"}"#),
            try message(#"{"id":"w:3","role":"user","content":"three"}"#)
        ]
        let chunks = try tokens.enumerated().map { try chunk($0.offset + 4, $0.element) }

        for arrived in [1, 2, 40, 87] {
            let shown = TranscriptEntry.conversation(TranscriptEntry.entries(from: head + chunks.prefix(arrived)))
            #expect(shown.count == 4)
            #expect(shown[3].id == "w:4#chunks")
            #expect(shown[3].kind == .prose(tokens.prefix(arrived).joined(), fromUser: false))
        }

        // The request surface counts the reply once, so its window holds the whole reply.
        let entries = TranscriptEntry.entries(from: head + chunks)
        let recent = TranscriptEntry.recent(entries, count: 2)
        #expect(recent.count == 88)
        #expect(TranscriptEntry.conversation(recent).map(\.id) == ["w:3", "w:4#chunks"])
        #expect(TranscriptEntry.recent(entries, count: 10) == entries)
        #expect(TranscriptEntry.recent([], count: 4).isEmpty)
        // Without chunks it is the plain suffix it was.
        let plain = TranscriptEntry.entries(from: head)
        #expect(TranscriptEntry.recent(plain, count: 2) == Array(plain.suffix(2)))
        #expect(TranscriptEntry.conversation(plain) == plain)
    }

    @Test func operationalRecordsSummariseToOneLine() throws {
        #expect(TranscriptOrigin.compact(950) == "950")
        #expect(TranscriptOrigin.compact(45_200) == "45.2k")
        #expect(TranscriptOrigin.compact(200_000) == "200k")
        #expect(TranscriptOrigin.compact(999_960) == "1M")
        #expect(TranscriptOrigin.compact(1_234_567) == "1.2M")

        func summary(_ acp: String) throws -> String? {
            let fields = try #require(AGUIValue(json: acp).objectValue)
            return TranscriptOrigin.operationalSummary(kind: fields["kind"]?.stringValue ?? "", acp: fields)
        }
        #expect(try summary(#"{"kind":"usage_update","usage":{"used":812,"size":0}}"#) == "Context 812 tokens")
        #expect(try summary(#"{"kind":"current_mode_update","modeId":"plan"}"#) == "Current mode · plan")
        #expect(try summary(#"{"kind":"available_commands_update","itemCount":12}"#) == "Available commands · 12")
        #expect(try summary(#"{"kind":"session_info_update"}"#) == "Session info")
        // Message and tool records keep their own text.
        #expect(try summary(#"{"kind":"agent_message_chunk"}"#) == nil)
        #expect(try summary(#"{"kind":"tool_call_update"}"#) == nil)
        #expect(try summary(#"{"kind":"plan"}"#) == nil)
    }
}
