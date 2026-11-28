import Foundation
import Testing
@testable import AgentCommander

// The older Claude runner's thought from before a worker's first console event (issue #110).
// The runner sends no console event for a thought. The service binds one recorded before the
// first event to the event before it, which is 0, and `sequence` is left out of what it sends.
// The record shape is from a real local render: no text, a start and an end 626 ms apart, and a
// first console event of assistant text with sequence 1. A second sample was 882 ms.

@MainActor @Suite struct PrettyStartThoughtTests {
    /// Keys in the runner's own form: `thought-` and a lowercase version 4 UUID.
    static let key = "thought-3f2b8c1e-9a4d-4e6f-8b1a-0c2d4e6f8a1b"
    static let second = "thought-7a1c5e9b-2d4f-4a6c-9e8b-1f3a5c7e9b2d"
    static let real = (start: "2026-11-27T01:59:10.000Z", end: "2026-11-27T01:59:10.626Z")

    /// A thought record as the service sends it. With no `sequence`, the field is left out.
    static func thought(_ key: String = Self.key, sequence: Int? = nil, start: String? = Self.real.start,
                        end: String? = Self.real.end, bytes: Int = 0) -> String {
        var fields = [#""kind":"thought""#, #""key":"\#(key)""#, #""revision":1"#]
        if let sequence { fields.append(#""sequence":\#(sequence)"#) }
        if let start { fields.append(#""started_at":"\#(start)""#) }
        if let end { fields.append(#""ended_at":"\#(end)""#) }
        if bytes > 0 { fields.append(#""result_bytes":\#(bytes)"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func records(_ json: String...) throws -> [ToolDetailSummary] {
        try PrettyRecordsTests.summaries(json.joined(separator: ","))
    }

    /// What the console places, for the transcript `messages` as Pretty displays it.
    static func placed(_ messages: [AGUIMessage], _ records: [ToolDetailSummary], full: [ToolDetailRecord] = [],
                       worker: String = "w") -> [TranscriptEntry] {
        let store = PrettyRecordsTests.store(records, full: full)
        return PrettyRecordPlacement.withThoughts(
            TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .pretty), summaries: records, worker: worker,
            summary: { store.summary(worker: worker, key: $0) }, record: { store.record(worker: worker, key: $0) })
    }

    static func thoughtLines(_ items: [PrettyItem]) -> [ActivityStep] {
        items.flatMap { item -> [ActivityStep] in
            if case .group(let group) = item { return group.lines }
            return []
        }.filter { $0.kind == .thought }
    }

    // MARK: The reported record

    @Test func aTimedThoughtFromBeforeTheFirstEventOpensTheTranscript() throws {
        var wire = Wire()
        wire.say("The lease is renewed in two places.")              // w:1, the first console event
        let samples = [
            Self.thought(),                                           // 626 ms, `sequence` left out
            Self.thought(sequence: 0),                                // the same place, stated
            Self.thought(end: "2026-11-27T01:59:10.882Z"),            // the second sample
        ]
        for sample in samples {
            let records = try Self.records(sample)
            let items = PrettyRecordsTests.items(wire, records)
            guard items.count == 2, case .group(let group) = items[0], case .entry(let reply) = items[1] else {
                Issue.record("the thought is not the line before the first reply: \(sample)")
                continue
            }
            #expect(reply.id == "w:1")
            #expect(group.lines.map(\.sentence.plain) == ["Thought for 1s"])
            let line = group.lines[0]
            // The provider's own time, under a second. No text: the row is static.
            #expect(line.kind == .thought && line.text.isEmpty && !line.opens)
            #expect((line.duration ?? 0) > 0.6 && (line.duration ?? 0) < 0.9)
            #expect(line.entries.first?.id == "w:thought:" + Self.key)
            // Nothing to read: the record holds no text.
            #expect(PrettyRecordPlacement.thoughtsToRead(records).isEmpty)
        }
    }

    @Test func onlyTheOlderRunnersKeyIsPlacedWithoutASequence() {
        #expect(PrettyRecordPlacement.isOlderRunnerThought(Self.key))
        #expect(PrettyRecordPlacement.isOlderRunnerThought(Self.second))
        let others = [
            "thought-0", "thought-a", "thought-",                         // not a UUID
            "3f2b8c1e-9a4d-4e6f-8b1a-0c2d4e6f8a1b",                       // an ACP message ID
            "thought-3F2B8C1E-9A4D-4E6F-8B1A-0C2D4E6F8A1B",               // not the runner's lowercase
            "thought-3f2b8c1e-9a4d-1e6f-8b1a-0c2d4e6f8a1b",               // not version 4
            "thought-3f2b8c1e-9a4d-4e6f-cb1a-0c2d4e6f8a1b",               // not the runner's variant
            "thought-3f2b8c1e9a4d4e6f8b1a0c2d4e6f8a1b",                   // no hyphens
            "thought-3f2b8c1e-9a4d-4e6f-8b1a-0c2d4e6f8a1b0",              // too long
            "turn-end-3f2b8c1e-9a4d-4e6f-8b1a-0c2d4e6f8a1b",
        ]
        for key in others { #expect(!PrettyRecordPlacement.isOlderRunnerThought(key), "\(key)") }
    }

    // MARK: When the start is not in view, or not known

    @Test func aTranscriptThatDoesNotShowTheFirstEventLeavesTheThoughtOut() throws {
        let records = try Self.records(Self.thought())
        var wire = Wire()
        wire.say("First reply.")                                     // w:1
        wire.say("Second reply.")                                    // w:2
        #expect(Self.placed(wire.messages, records).first?.isThought == true)

        // A preview that starts later: the record is not put before another event.
        let preview = Array(wire.messages.dropFirst())
        #expect(Self.placed(preview, records).map(\.id) == ["w:2"])
        // Nothing is shown yet.
        #expect(Self.placed([], records).isEmpty)
        // The entries are another console's: their IDs hold no sequence of this worker.
        #expect(!Self.placed(wire.messages, records, worker: "x").map(\.isThought).contains(true))

        // A first entry whose sequence is not known. A call's is in its stored record.
        var calls = Wire()
        let call = calls.call("Bash", detail: "ls", result: "a")     // w:1, w:2
        calls.say("Done.")                                           // w:3
        #expect(!Self.placed(calls.messages, records).map(\.isThought).contains(true))
        let known = try Self.records(Self.thought(), PrettyRecordsTests.tool(call, 1))
        #expect(Self.placed(calls.messages, known).first?.isThought == true)
        // The first entry is known, and it is not the first event.
        let later = try Self.records(Self.thought(), PrettyRecordsTests.tool(call, 4))
        #expect(!Self.placed(calls.messages, later).map(\.isThought).contains(true))
    }

    @Test func aRecordWithNoSequenceUnderAnotherKeyIsNeverPlaced() throws {
        var wire = Wire()
        wire.say("First reply.")                                     // w:1
        for key in ["thought-0", "m1", "3f2b8c1e-9a4d-4e6f-8b1a-0c2d4e6f8a1b"] {
            let records = try Self.records(Self.thought(key, bytes: 20), Self.thought(key + "-zero", sequence: 0, bytes: 20))
            #expect(!Self.placed(wire.messages, records).map(\.isThought).contains(true), "\(key)")
            #expect(PrettyRecordPlacement.thoughtsToRead(records).isEmpty, "\(key)")
        }
    }

    // MARK: Several turns

    @Test func eachThoughtStaysInItsOwnTurn() throws {
        var wire = Wire()
        wire.say("The first turn's reply.")                          // w:1
        wire.user("Now check the timer.")                            // w:2, a follow-up prompt
        wire.say("The second turn's reply.")                         // w:3
        // The second turn's thought follows its prompt: the service gives it that event's sequence.
        let records = try Self.records(
            Self.thought(Self.second, sequence: 2, start: "2026-11-27T02:03:10Z", end: "2026-11-27T02:03:22Z"),
            Self.thought())
        let start = "w:thought:" + Self.key, next = "w:thought:" + Self.second
        #expect(Self.placed(wire.messages, records).map(\.id) == [start, "w:1", "w:2", next, "w:3"])
        let lines = Self.thoughtLines(PrettyRecordsTests.items(wire, records))
        #expect(lines.map(\.sentence.plain) == ["Thought for 1s", "Thought for 12s"])

        // Shown from the second turn: the first turn's thought is not moved into it.
        let preview = Array(wire.messages.dropFirst())
        #expect(Self.placed(preview, records).map(\.id) == ["w:2", next, "w:3"])

        // A first turn that wrote nothing: its thought stays above the follow-up prompt.
        var quiet = Wire()
        quiet.user("Now check the timer.")                           // w:1
        quiet.say("Checked.")                                        // w:2
        let alone = try Self.records(Self.thought())
        #expect(Self.placed(quiet.messages, alone).map(\.id) == [start, "w:1", "w:2"])
    }

    @Test func thoughtsBeforeTheFirstEventKeepTheProvidersOrder() throws {
        var wire = Wire()
        wire.say("First reply.")                                     // w:1
        let records = try Self.records(
            Self.thought(Self.key, start: "2026-11-27T01:59:12.000Z", end: "2026-11-27T01:59:14.000Z"),
            Self.thought(Self.second, start: "2026-11-27T01:59:10.000Z", end: "2026-11-27T01:59:11.500Z"))
        #expect(Self.placed(wire.messages, records).map(\.id)
                == ["w:thought:" + Self.second, "w:thought:" + Self.key, "w:1"])
    }

    // MARK: Text and missing data

    @Test func textWithNoTimesOpensAndShowsNoTime() throws {
        var wire = Wire()
        wire.say("First reply.")                                     // w:1
        let full = ToolDetailRecord(key: Self.key, kind: "thought", result: "The lease is held.")
        // No times at all, then a start with no end: neither gives a duration.
        for record in [Self.thought(start: nil, end: nil, bytes: 18), Self.thought(end: nil, bytes: 18)] {
            let records = try Self.records(record)
            let lines = Self.thoughtLines(PrettyRecordsTests.items(wire, records, full: [full]))
            #expect(lines.map(\.sentence.plain) == ["Thought"], "\(record)")
            #expect(lines.first?.duration == nil && lines.first?.text == "The lease is held." && lines.first?.opens == true)
            #expect(PrettyRecordPlacement.thoughtsToRead(records) == [Self.key])
        }
        // Timed and with text: the time shows and the line opens.
        let timed = try Self.records(Self.thought(bytes: 18))
        let line = try #require(Self.thoughtLines(PrettyRecordsTests.items(wire, timed, full: [full])).first)
        #expect(line.sentence.plain == "Thought for 1s" && line.opens)
    }

    @Test func aRecordThatSaysNothingIsLeftOut() throws {
        var wire = Wire()
        wire.say("First reply.")                                     // w:1
        // No time and no text; then a start alone, which is not a duration.
        for record in [Self.thought(start: nil, end: nil), Self.thought(end: nil), Self.thought(start: nil)] {
            let records = try Self.records(record)
            #expect(Self.placed(wire.messages, records).map(\.id) == ["w:1"], "\(record)")
            #expect(PrettyRecordPlacement.thoughtsToRead(records).isEmpty)
        }
    }

    // MARK: What stays as it was

    @Test func aConsoleThatCarriesItsOwnThoughtsIsUnchanged() throws {
        let thought = try JSONDecoder().decode(AGUIMessage.self, from: Data(#"""
        {"id":"w:1","role":"system","content":"Check the timeouts.","metadata":{"acp":{"source":"live","kind":"agent_thought_chunk","messageId":"m1","turnId":"t1"}}}
        """#.utf8))
        let messages = [thought, AGUIMessage(id: "w:2", role: "assistant", content: "Done.")]
        let displayed = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .pretty)
        #expect(displayed.map(\.isThought).contains(true))
        // The ACP thought's own record, bound to its console event, and a record in the older
        // runner's form: neither adds an entry.
        let records = try Self.records(
            Self.thought("m1", sequence: 1, start: "2026-11-27T01:59:10Z", end: "2026-11-27T02:01:02Z", bytes: 19),
            Self.thought(), Self.thought(Self.second, sequence: 2, bytes: 4))
        #expect(Self.placed(messages, records) == displayed)
        // Its line keeps its own time, read by its message ID.
        let facts = ActivityFacts(summaries: PrettyRecordsTests.store(records).summaries(worker: "w"))
        let lines = Self.thoughtLines(ActivityConversation.items(ConversationActivity.items(displayed), facts: facts))
        #expect(lines.map(\.sentence.plain) == ["Thought for 1m 52s"])
    }

    @Test func aThoughtWithASequenceIsPlacedAsBefore() throws {
        var wire = Wire()
        wire.user("Think, then answer.")                             // w:1
        wire.say("Answered.")                                        // w:2
        // Any key: a sequence above zero places the record after the event it names.
        let records = try Self.records(Self.thought("thought-1", sequence: 1, start: "2026-01-02T03:04:05.733Z",
                                                    end: "2026-01-02T03:04:17.79Z", bytes: 20))
        #expect(Self.placed(wire.messages, records).map(\.id) == ["w:1", "w:thought:thought-1", "w:2"])
        #expect(PrettyRecordPlacement.thoughtsToRead(records) == ["thought-1"])
    }

    @Test func theNewestTextsAreReadAndTheStartIsDroppedFirst() throws {
        var json: [String] = [Self.thought(start: nil, end: nil, bytes: 4)]
        for number in 1...12 { json.append(Self.thought("t-\(number)", sequence: number, bytes: 4)) }
        let records = try PrettyRecordsTests.summaries(json.joined(separator: ","))
        let later: [String] = (1...12).map { "t-\($0)" }
        // Twelve are kept, the latest by console order: the start is the one dropped.
        #expect(PrettyRecordPlacement.thoughtsToRead(records) == later)
        // With room for it, the start is read too, first.
        let fewer: [String] = [Self.key] + Array(later.dropLast())
        #expect(PrettyRecordPlacement.thoughtsToRead(Array(records.prefix(12))) == fewer)
        #expect(PrettyRecordPlacement.thoughtsToRead(records, limit: 2) == ["t-11", "t-12"])
    }
}
