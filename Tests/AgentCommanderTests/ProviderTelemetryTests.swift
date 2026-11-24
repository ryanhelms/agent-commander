import Foundation
import Testing
@testable import AgentCommander

// Provider telemetry for the footer, thought chunks joined into one Thinking entry, and the
// compact token format at the limits of Int64.

private func message(_ json: String) throws -> AGUIMessage {
    try AGUIMessage(fields: AGUIValue(json: json))
}

@Test func telemetryFieldIsReadExactlyAndAbsentCountsStayAbsent() throws {
    let fields = try AGUIValue(json: #"{"telemetry":{"context":{"used":84000,"size":200000,"cost":{"amount":0.125,"currency":"USD"}},"turnTokens":{"inputTokens":1234,"outputTokens":0}}}"#)
    let telemetry = ProviderTelemetry.reported(fields: fields, messages: [])
    #expect(telemetry.context == ProviderTelemetry.Context(used: 84000, size: 200000, costAmount: "0.125", costCurrency: "USD"))
    #expect(telemetry.context?.percent == 42)
    // A reported zero is kept; an unreported count is nil, never zero.
    #expect(telemetry.tokens == ProviderTelemetry.Tokens(input: 1234, output: 0))
    #expect(telemetry.tokens?.thought == nil)
    #expect(telemetry.statement.contains("input 1234, output 0."))
}

@Test func telemetryFallsBackToTheNewestLiveMessage() throws {
    let messages = [
        try message(#"{"id":"1","role":"system","content":"u","metadata":{"acp":{"source":"live","kind":"usage_update","usage":{"used":10,"size":100}}}}"#),
        try message(#"{"id":"2","role":"system","content":"u","metadata":{"acp":{"source":"live","kind":"usage_update","usage":{"used":20,"size":100}}}}"#),
        try message(#"{"id":"3","role":"system","content":"u","metadata":{"acp":{"source":"provider","kind":"usage_update","usage":{"used":99,"size":100}}}}"#),
        try message(#"{"id":"4","role":"system","content":"done","metadata":{"acp":{"source":"live","kind":"acp.prompt_result","turnTokens":{"thoughtTokens":7}}}}"#),
    ]
    let telemetry = ProviderTelemetry.reported(fields: [:], messages: messages)
    #expect(telemetry.context?.used == 20)
    #expect(telemetry.tokens == ProviderTelemetry.Tokens(thought: 7))
}

@Test func nothingReportedIsEmpty() throws {
    let empty = ProviderTelemetry.reported(fields: try AGUIValue(json: #"{"telemetry":{"turnTokens":{}}}"#), messages: [])
    #expect(empty.isEmpty)
}

@Test func indicatorPercentIsLimitedAndExactCountsKept() {
    let over = ProviderTelemetry.Context(used: 250, size: 200)
    #expect(over.percent == 100)
    #expect(over.fraction == 1)
    #expect(ProviderTelemetry(context: over).statement.contains("250 of 200 context tokens, over the window"))
    #expect(ProviderTelemetry.Context(used: 5, size: 0).percent == nil)
}

@Test func compactFormatsWithoutOverflow() {
    #expect(TranscriptOrigin.compact(950) == "950")
    #expect(TranscriptOrigin.compact(45_249) == "45.2k")
    #expect(TranscriptOrigin.compact(999_950) == "1M")
    #expect(TranscriptOrigin.compact(1_234_567_890) == "1.2B")
    #expect(TranscriptOrigin.compact(Int64.max).hasSuffix("B"))
}

@Test func contiguousThoughtChunksJoinIntoOneThought() throws {
    func thought(_ id: Int, _ text: String, messageID: String = "m1") throws -> AGUIMessage {
        try message(#"{"id":"w:\#(id)","role":"system","content":"\#(text)","metadata":{"acp":{"source":"live","kind":"agent_thought_chunk","messageId":"\#(messageID)","turnId":"t1"}}}"#)
    }
    let reply = try message(#"{"id":"w:9","role":"assistant","content":"Done.","metadata":{"acp":{"source":"live","kind":"agent_message_chunk","messageId":"m1","turnId":"t1"}}}"#)
    let messages = [try thought(1, "Check the "), try thought(2, "timeouts."), reply, try thought(3, "Again", messageID: "m2")]
    let shown = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .pretty)
    #expect(shown.count == 3)
    #expect(shown[0].isThought)
    #expect(shown[0].kind == .other(role: "system", text: "Check the timeouts."))
    #expect(shown[0].sourceIDs == ["w:1", "w:2"])
    // A reply with the same message ID never joins a thought.
    #expect(shown[1].kind == .prose("Done.", fromUser: false))
    #expect(shown[2].isThought && shown[2].sourceIDs == ["w:3"])
    #expect(ConsoleRecordDetail.messageIDs(entryID: shown[0].id, in: messages) == ["w:1", "w:2"])
}
