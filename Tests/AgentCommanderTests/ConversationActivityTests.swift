import Foundation
import Testing
@testable import AgentCommander

// Messages here use the wire shape of the run in the Pretty correction: usage and session updates
// with an ACP reference, harness stderr relayed as untyped system text, and a prompt with an image.

private func message(_ json: String) throws -> AGUIMessage {
    try AGUIMessage(fields: AGUIValue(json: json))
}

private func usage(_ sequence: Int, used: Int) throws -> AGUIMessage {
    try message(#"{"id":"w:\#(sequence)","role":"system","content":"[ACP usage_update] \#(used) / 1000000 tokens","metadata":{"acp":{"source":"live","cursor":"c-\#(sequence)","kind":"usage_update","usage":{"used":\#(used),"size":1000000}}}}"#)
}

private func stderr(_ sequence: Int) throws -> AGUIMessage {
    try message(#"{"id":"w:\#(sequence)","role":"system","content":"[Provider stderr] [idle-compaction] skip: rate limit status is allowed_warning"}"#)
}

private func prompt(_ text: String, acp: String?) throws -> TranscriptEntry {
    let metadata = acp.map { #","metadata":{"acp":\#($0)}"# } ?? ""
    let content = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    let entries = TranscriptEntry.entries(from: [try message(#"{"id":"w:1","role":"user","content":\#(content)\#(metadata)}"#)])
    return try #require(entries.first)
}

private let imageACP = #"{"source":"live","kind":"acp.prompt_part","turnId":"op-7","cursor":"prompt-op-7-1","contentType":"image","mimeType":"image/png","itemCount":1}"#

@Suite struct ConversationActivityTests {
    private func run() throws -> [AGUIMessage] {
        [
            try message(#"{"id":"w:1","role":"user","content":"Say you are ready."}"#),
            try usage(2, used: 8200),
            try message(#"{"id":"w:3","role":"system","content":"[ACP session_info_update]","metadata":{"acp":{"source":"live","cursor":"c-3","kind":"session_info_update"}}}"#),
            try stderr(4),
            try message(#"{"id":"w:5","role":"user","content":"What color is this swatch?"}"#),
            try usage(6, used: 8300),
            try message(#"{"id":"w:7","role":"assistant","toolCalls":[{"id":"w:t1","type":"function","function":{"name":"Read","arguments":"{}"}}]}"#),
            try message(#"{"id":"w:8","role":"tool","toolCallId":"w:t1","content":"PLUM-4761"}"#),
            try usage(9, used: 8400),
            try usage(10, used: 8500),
            try message(#"{"id":"w:11","role":"assistant","content":"The swatch is purple."}"#),
            // A note the service wrote that is not routine: it stays in the conversation.
            try message(#"{"id":"w:12","role":"system","content":"Retained frontend tool results are unavailable for this operation."}"#),
            try stderr(13)
        ]
    }

    @Test func adjacentRoutineEntriesAreOneActivityInPlace() throws {
        let entries = TranscriptEntry.entries(from: try run())
        let items = ConversationActivity.items(TranscriptEntry.conversation(entries))

        #expect(items.map(\.id) == [
            "w:1", "w:2#activity", "w:5", "w:6#activity", "w:t1", "w:9#activity", "w:11", "w:12", "w:13#activity"
        ])
        guard case .activity(let first) = items[1], case .activity(let third) = items[5] else {
            Issue.record("expected activities"); return
        }
        #expect(first.entries.map(\.id) == ["w:2", "w:3", "w:4"])
        #expect(first.detail == "3 events · 1 stderr")
        #expect(first.accessibilityLabel == "Activity, 3 events, 1 stderr")
        #expect(third.entries.map(\.id) == ["w:9", "w:10"])
        #expect(third.detail == "2 events")
    }

    @Test func nothingIsDroppedAndOrderIsKept() throws {
        let shown = TranscriptEntry.conversation(TranscriptEntry.entries(from: try run()))
        let flattened = ConversationActivity.items(shown).flatMap(\.entries)
        // Opening every activity gives exactly the entries Pretty had, each with its own ID.
        #expect(flattened == shown)
    }

    @Test func anActivityKeepsItsIdentityWhileItGrows() throws {
        var messages = Array(try run().prefix(2))
        let before = ConversationActivity.items(TranscriptEntry.conversation(TranscriptEntry.entries(from: messages)))
        messages.append(try usage(3, used: 8250))
        messages.append(try stderr(4))
        let after = ConversationActivity.items(TranscriptEntry.conversation(TranscriptEntry.entries(from: messages)))
        #expect(before.map(\.id) == ["w:1", "w:2#activity"])
        #expect(after.map(\.id) == before.map(\.id))
    }

    @Test func promptsRepliesToolsAndPlainNotesAreNeverRoutine() throws {
        let quoted = "[Provider stderr] this is what I saw"
        let entries = TranscriptEntry.entries(from: [
            try message(#"{"id":"w:1","role":"user","content":"\#(quoted)"}"#),
            try message(#"{"id":"w:2","role":"assistant","content":"\#(quoted)"}"#),
            try message(#"{"id":"w:3","role":"tool","toolCallId":"gone","content":"\#(quoted)"}"#),
            try message(#"{"id":"w:4","role":"system","content":"The console preview for this operation is unavailable."}"#),
            // An ACP record that is content, not a state update.
            try message(#"{"id":"w:5","role":"system","content":"[ACP image] image/png","metadata":{"acp":{"source":"live","cursor":"c-5","kind":"agent_message_chunk","contentType":"image"}}}"#)
        ])
        #expect(entries.count == 5)
        #expect(!entries.contains(where: ConversationActivity.isRoutine))
    }
}

@Suite struct PromptMediaIndicatorTests {
    @Test func theServiceMarkerIsLeftOutOfAReferencedPrompt() throws {
        let sent = "What color is this swatch? Answer with the receipt code.[ACP image] image/png"
        let entry = try prompt(sent, acp: imageACP)
        let media = try #require(entry.promptMedia)
        let shown = media.display(sent)
        #expect(shown.text == "What color is this swatch? Answer with the receipt code.")
        #expect(shown.removed == 1)
        #expect(media.caption == "1 image attached · image/png")
        // The entry itself is unchanged: Console, the copy action and the fields keep the text as sent.
        #expect(entry.kind == .prose(sent, fromUser: true))
        #expect(entry.plainText == sent)
    }

    @Test func aPromptWithoutTheReferenceIsShownAsWritten() throws {
        let typed = "Why does the log say [ACP image] image/png"
        #expect(try prompt(typed, acp: nil).promptMedia == nil)
        // Another kind, or another source, is not the prompt-part reference.
        #expect(try prompt(typed, acp: #"{"source":"live","kind":"user_message_chunk"}"#).promptMedia == nil)
        #expect(try prompt(typed, acp: #"{"source":"provider","kind":"acp.prompt_part","itemCount":1}"#).promptMedia == nil)
        #expect(try prompt(typed, acp: #"{"source":"live","kind":"acp.prompt_part","itemCount":0}"#).promptMedia == nil)
    }

    @Test func onlyAsManyTrailingMarkersAsTheReferenceCounts() throws {
        let media = try #require(try prompt("x", acp: imageACP).promptMedia)
        // The developer typed the same words before attaching one image: theirs stay.
        let typed = "It printed [ACP image] image/png[ACP image] image/png"
        #expect(media.display(typed).text == "It printed [ACP image] image/png")
        // A marker that is not at the end stays, and so does text that only resembles one.
        #expect(media.display("[ACP image] image/png then text").removed == 0)
        #expect(media.display("see [ACP image] image/png for details").text == "see [ACP image] image/png for details")
        #expect(media.display("ends with [ACP] image/png").removed == 0)
        #expect(media.display("ends with [ACP image] two words").removed == 0)
    }

    @Test func severalMediaPartsAndAMediaOnlyPrompt() throws {
        let two = #"{"source":"live","kind":"acp.prompt_part","turnId":"op-7","contentType":"image","mimeType":"image/png","itemCount":2}"#
        let media = try #require(try prompt("x", acp: two).promptMedia)
        #expect(media.display("Compare these.[ACP image] image/png[ACP audio] audio/wav").text == "Compare these.")
        #expect(media.caption == "2 attachments")
        // With nothing but media, the bubble says what was sent.
        let only = try #require(try prompt("x", acp: imageACP).promptMedia)
        #expect(only.display("[ACP image] image/png").text == "1 image attached · image/png")
    }

    @Test func anAssistantRecordNeverCarriesAPromptIndicator() throws {
        let entries = TranscriptEntry.entries(from: [
            try message(#"{"id":"w:1","role":"assistant","content":"done[ACP image] image/png","metadata":{"acp":\#(imageACP)}}"#)
        ])
        #expect(entries.first?.promptMedia == nil)
    }
}
