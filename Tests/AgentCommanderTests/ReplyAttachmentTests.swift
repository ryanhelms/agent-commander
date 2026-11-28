import Foundation
import Testing
@testable import AgentCommander

// A resource link and an embedded text resource sent as chunks of a reply (DESIGN.md, "Pretty
// transcript"; spec section H, "ACP content blocks"). The messages have the shape the service
// sends for a negotiated ACP session: `acpActivityEvent` writes a `[ACP <type>]` marker with the
// content type, and the chunk's original `session/update` stays in the worker's live source at
// the event's cursor (`captureObservation`).

private func message(_ json: String) throws -> AGUIMessage {
    try AGUIMessage(fields: AGUIValue(json: json))
}

private func prose(_ sequence: Int, _ text: String, role: String = "assistant") throws -> AGUIMessage {
    try message(#"{"id":"w:\#(sequence)","role":"\#(role)","content":"\#(text)"}"#)
}

/// The service's message for a reply chunk that is not text.
private func chunk(_ sequence: Int, type: String, cursor: String? = nil, turn: String? = "op-7", source: String = "live",
                   kind: String = "agent_message_chunk", role: String = "system") throws -> AGUIMessage {
    var acp = #""source":"\#(source)","kind":"\#(kind)","contentType":"\#(type)","mimeType":"text/plain""#
    if let cursor = cursor ?? Optional("c-\(sequence)"), !cursor.isEmpty { acp += #","cursor":"\#(cursor)""# }
    if let turn { acp += #","turnId":"\#(turn)""# }
    return try message(#"{"id":"w:\#(sequence)","role":"\#(role)","content":"[ACP \#(type)] text/plain fixture://plan","metadata":{"acp":{\#(acp)}}}"#)
}

private let linkContent = #"{"type":"resource_link","uri":"https://example.com/plan.txt","name":"plan.txt","title":"Lease plan","mimeType":"text/plain","size":72}"#
private let quoted = "Renew at half the lifetime.\n  Keep the \"fake\" clock."
private var resourceContent: String {
    let text = String(decoding: try! JSONEncoder().encode(quoted), as: UTF8.self)
    return #"{"type":"resource","resource":{"uri":"fixture://notes","mimeType":"text/plain","text":\#(text)}}"#
}

/// One live source record: the SDK observation with the provider's original params.
private func observation(cursor: String, content: String, kind: String = "agent_message_chunk", session: String? = "s-1",
                         params: String = "s-1", turn: String = "op-7", sourceCursor: String? = nil,
                         type: String = "acp.session_update_params", member: String = "sourceRecord") -> String {
    let update = #"{"sessionUpdate":"\#(kind)","content":\#(content)}"#
    let original = type == "acp.session_update" ? update : #"{"sessionId":"\#(params)","update":\#(update)}"#
    let data = Data(original.utf8).base64EncodedString()
    var fields = #""cursor":"\#(cursor)","turnId":"\#(turn)","\#(member)":{"type":"\#(type)","mediaType":"application/json","data":"\#(data)"}"#
    if let session { fields += #","session":{"harnessInstance":"claude","sessionId":"\#(session)"}"# }
    if let sourceCursor { fields += #","sourceCursor":"\#(sourceCursor)""# }
    return "{\(fields)}"
}

private func page(_ observations: [String], next: String = "") throws -> SourcePage {
    try SourcePage(envelope: Data(#"{"observations":[\#(observations.joined(separator: ","))],"nextCursor":"\#(next)"}"#.utf8))
}

private func mark(_ type: String, cursor: String = "c-3", turn: String? = "op-7") throws -> ReplyAttachmentMark {
    let entries = TranscriptEntry.entries(from: [try chunk(3, type: type, cursor: cursor, turn: turn)])
    return try #require(entries.first?.replyAttachment)
}

private func pretty(_ messages: [AGUIMessage], read: [ReplyAttachmentMark: ReplyAttachment] = [:]) -> [PrettyItem] {
    let entries = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .pretty)
    var facts = ActivityFacts.none
    facts.replyAttachment = { read[$0] }
    return ActivityConversation.items(ConversationActivity.items(entries), facts: facts)
}

private actor Reads {
    private(set) var cursors: [String?] = []
    func record(_ cursor: String?) { cursors.append(cursor) }
}

@Suite struct ReplyAttachmentTests {
    /// The fixture of the issue: a link and a text resource between three distinct replies.
    private func run() throws -> [AGUIMessage] {
        [
            try prose(1, "Show me the plan.", role: "user"),
            try prose(2, "Here is the plan."),
            try chunk(3, type: "resource_link"),
            try prose(4, "And the notes it came from."),
            try chunk(5, type: "resource"),
            try prose(6, "That is everything.")
        ]
    }

    // MARK: The mark

    @Test func onlyALiveReplyChunkOfTheTwoTypesWithACursorIsMarked() throws {
        func marked(_ message: AGUIMessage) -> ReplyAttachmentMark? {
            TranscriptEntry.entries(from: [message]).first?.replyAttachment
        }
        let link = try #require(marked(try chunk(3, type: "resource_link")))
        #expect(link.content == .link && link.cursor == "c-3" && link.turnID == "op-7")
        #expect(marked(try chunk(3, type: "resource"))?.content == .resource)
        #expect(marked(try chunk(3, type: "resource", turn: nil))?.turnID == nil)

        #expect(marked(try chunk(3, type: "image")) == nil)
        #expect(marked(try chunk(3, type: "audio")) == nil)
        #expect(marked(try chunk(3, type: "text")) == nil)
        #expect(marked(try chunk(3, type: "resource_link", cursor: "")) == nil)
        #expect(marked(try chunk(3, type: "resource_link", source: "provider")) == nil)
        #expect(marked(try chunk(3, type: "resource_link", kind: "user_message_chunk")) == nil)
        #expect(marked(try chunk(3, type: "resource_link", kind: "agent_thought_chunk")) == nil)
        #expect(marked(try chunk(3, type: "resource_link", role: "user")) == nil)
        // Prose that looks like the marker carries no reference.
        #expect(marked(try prose(3, "[ACP resource_link] text/plain https://example.com/plan.txt")) == nil)
    }

    // MARK: Exact correlation

    @Test func theLinkIsReadFromTheOriginalUpdateAtTheExactCursor() throws {
        let found = ReplyAttachment.find(try mark("resource_link"), in: try page([
            observation(cursor: "c-2", content: #"{"type":"resource_link","uri":"https://other.example/x","name":"other"}"#),
            observation(cursor: "c-3", content: linkContent),
            observation(cursor: "c-4", content: resourceContent)
        ]).observations)

        guard case .link(let link)? = found else { Issue.record("expected the link"); return }
        #expect(link == ReplyAttachment.Link(name: "plan.txt", uri: "https://example.com/plan.txt", title: "Lease plan",
                                             mimeType: "text/plain", size: 72))
        #expect(link.caption() == "Lease plan, text/plain" && link.sizeText == "72 bytes")
        #expect(link.openable?.absoluteString == "https://example.com/plan.txt")
    }

    @Test func theEmbeddedTextIsKeptExactly() throws {
        let found = ReplyAttachment.find(try mark("resource"), in: try page([
            observation(cursor: "c-3", content: resourceContent)
        ]).observations)

        #expect(found == .resource(ReplyAttachment.Resource(uri: "fixture://notes", mimeType: "text/plain", text: quoted)))
        // The SDK's update without its params wrapper is the same original.
        let bare = ReplyAttachment.find(try mark("resource"), in: try page([
            observation(cursor: "c-3", content: resourceContent, type: "acp.session_update", member: "extension")
        ]).observations)
        #expect(bare == found)
    }

    @Test func aLinkOfAnotherSchemeIsNotOpenable() {
        #expect(ReplyAttachment.Link(name: "plan", uri: "fixture://plan").openable == nil)
        #expect(ReplyAttachment.Link(name: "plan", uri: "javascript:alert(1)").openable == nil)
        #expect(ReplyAttachment.Link(name: "plan", uri: "file:///tmp/plan.txt").openable?.isFileURL == true)
        #expect(ReplyAttachment.Link(name: "plan", uri: "fixture://plan").caption().isEmpty)
    }

    @Test func nothingIsReadFromAnyOtherRecord() throws {
        let link = try mark("resource_link")
        func find(_ observations: [String], _ mark: ReplyAttachmentMark? = nil) throws -> ReplyAttachment? {
            ReplyAttachment.find(mark ?? link, in: try page(observations).observations)
        }
        // A neighbouring chunk, and a record that reuses the same address at another cursor.
        #expect(try find([observation(cursor: "c-2", content: linkContent), observation(cursor: "c-4", content: linkContent)]) == nil)
        // Two records at the cursor name neither.
        #expect(try find([observation(cursor: "c-3", content: linkContent), observation(cursor: "c-3", content: linkContent)]) == nil)
        // Another session: in the provider's own params, or no session stated at all.
        #expect(try find([observation(cursor: "c-3", content: linkContent, params: "s-2")]) == nil)
        #expect(try find([observation(cursor: "c-3", content: linkContent, session: nil)]) == nil)
        // Another turn, and a record whose original is another record.
        #expect(try find([observation(cursor: "c-3", content: linkContent, turn: "op-8")]) == nil)
        #expect(try find([observation(cursor: "c-3", content: linkContent, sourceCursor: "c-1")]) == nil)
        // Not a reply chunk, not the stated content type, not an original update.
        #expect(try find([observation(cursor: "c-3", content: linkContent, kind: "user_message_chunk")]) == nil)
        #expect(try find([observation(cursor: "c-3", content: resourceContent)]) == nil)
        #expect(try find([observation(cursor: "c-3", content: linkContent)], try mark("resource")) == nil)
        #expect(try find([observation(cursor: "c-3", content: linkContent, type: "acp.source_omitted")]) == nil)
        // A link with no name, and a resource that is a blob or has no text.
        #expect(try find([observation(cursor: "c-3", content: #"{"type":"resource_link","uri":"https://example.com/x"}"#)]) == nil)
        #expect(try find([observation(cursor: "c-3", content: #"{"type":"resource","resource":{"uri":"fixture://b","blob":"AAAA"}}"#)],
                         try mark("resource")) == nil)
        #expect(try find([], link) == nil)
    }

    // MARK: Order and fallback

    @Test func aReadLinkAndResourceSitInTheReplyInTheOrderSent() throws {
        let messages = try run()
        let entries = TranscriptEntry.entries(from: messages)
        let link = try #require(entries[2].replyAttachment), resource = try #require(entries[4].replyAttachment)
        let items = pretty(messages, read: [
            link: .link(ReplyAttachment.Link(name: "plan.txt", uri: "https://example.com/plan.txt", size: 72)),
            resource: .resource(ReplyAttachment.Resource(uri: "fixture://notes", text: quoted))
        ])

        #expect(items.map(\.id) == ["w:1", "w:2", "w:3", "w:4", "w:5", "w:6"])
        #expect(items.allSatisfy { if case .entry = $0 { true } else { false } })
        guard case .entry(let before) = items[1], case .entry(let between) = items[3], case .entry(let after) = items[5] else {
            Issue.record("expected three replies"); return
        }
        // The replies around them stay distinct and unchanged.
        #expect(before.kind == .prose("Here is the plan.", fromUser: false))
        #expect(between.kind == .prose("And the notes it came from.", fromUser: false))
        #expect(after.kind == .prose("That is everything.", fromUser: false))
        #expect(items.flatMap(\.entries).map(\.id) == ["w:1", "w:2", "w:3", "w:4", "w:5", "w:6"])
    }

    @Test func withoutARecordEachChunkStaysAFoldedSessionUpdate() throws {
        let items = pretty(try run())

        #expect(items.map(\.id) == ["w:1", "w:2", "w:3#group", "w:4", "w:5#group", "w:6"])
        guard case .group(let first) = items[2], case .group(let second) = items[4] else {
            Issue.record("expected two folded groups"); return
        }
        #expect(first.lines.map(\.id) == ["w:3"] && second.lines.map(\.id) == ["w:5"])
        #expect(first.summary.text == "1 session update")
        // The service's own wording, with nothing added from anywhere else.
        #expect(first.lines[0].sentence.plain.hasSuffix("[ACP resource_link] text/plain fixture://plan"))

        // One read, one not: only the read one leaves its group.
        let entries = TranscriptEntry.entries(from: try run())
        let link = try #require(entries[2].replyAttachment)
        let mixed = pretty(try run(), read: [link: .link(ReplyAttachment.Link(name: "plan.txt", uri: "fixture://plan"))])
        #expect(mixed.map(\.id) == ["w:1", "w:2", "w:3", "w:4", "w:5#group", "w:6"])
    }

    @Test func aReadChunkEndsTheGroupWhereItArrived() throws {
        let usage = #"{"id":"w:3","role":"system","content":"[ACP usage_update] 10 / 100 tokens","metadata":{"acp":{"source":"live","cursor":"u-3","turnId":"op-7","kind":"usage_update","usage":{"used":10,"size":100}}}}"#
        let later = usage.replacingOccurrences(of: "w:3", with: "w:5").replacingOccurrences(of: "u-3", with: "u-5")
        let messages = [try prose(1, "Go on.", role: "user"), try prose(2, "Working."), try message(usage),
                        try chunk(4, type: "resource_link"), try message(later), try prose(6, "Done.")]
        let link = try #require(TranscriptEntry.entries(from: messages)[3].replyAttachment)

        let items = pretty(messages, read: [link: .link(ReplyAttachment.Link(name: "plan.txt", uri: "fixture://plan"))])
        #expect(items.map(\.id) == ["w:1", "w:2", "w:3#group", "w:4", "w:5#group", "w:6"])
        // Without the record the three fold together, as before.
        #expect(pretty(messages).map(\.id) == ["w:1", "w:2", "w:3#group", "w:6"])
    }

    // MARK: Tool results and Console

    @Test func aToolResultWithTheSameContentIsUnchanged() throws {
        let content = #"[{"type":"content","content":\#(linkContent)},{"type":"content","content":\#(resourceContent)}]"#
        let call = #"{"id":"w:3","role":"assistant","toolCalls":[{"id":"w:fetch-1","type":"function","function":{"name":"Fetch","arguments":"{}"}}]}"#
        let result = #"{"id":"w:4","role":"tool","toolCallId":"w:fetch-1","content":"ok","metadata":{"acp":{"source":"live","cursor":"c-3","turnId":"op-7","kind":"tool_call_update","contentType":"resource_link"}}}"#
        let messages = [try prose(1, "Fetch it.", role: "user"), try message(call), try message(result), try prose(5, "Fetched.")]
        let entries = TranscriptEntry.entries(from: messages)
        #expect(entries.allSatisfy { $0.replyAttachment == nil })

        var facts = ActivityFacts(summaries: [:], records: ["w:fetch-1": ToolDetailRecord(key: "w:fetch-1", kind: "tool", name: "Fetch",
                                                                                         result: "ok", content: content)])
        // A reader that would answer for any mark is never asked about a tool's result.
        facts.replyAttachment = { _ in .link(ReplyAttachment.Link(name: "wrong", uri: "fixture://wrong")) }
        let items = ActivityConversation.items(ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty)), facts: facts)
        #expect(items.map(\.id) == ["w:1", "w:fetch-1#group", "w:5"])
        guard case .group(let group) = items[1], let entry = group.lines.first?.entries.first else {
            Issue.record("expected the call's line"); return
        }
        let source = ActivityResultSource(entry: entry, step: group.lines[0], record: facts.record("w:fetch-1"))
        #expect(source.resultText == "ok")
    }

    @Test func consoleKeepsTheServicesText() throws {
        let entries = TranscriptEntry.displayed(TranscriptEntry.entries(from: try run()), mode: .console)
        #expect(entries.map(\.id) == ["w:1", "w:2", "w:3", "w:4", "w:5", "w:6"])
        #expect(entries[2].kind == .other(role: "system", text: "[ACP resource_link] text/plain fixture://plan"))
    }

    // MARK: The store

    @Test @MainActor func aChunkIsReadOnceAcrossPagesOfItsTurn() async throws {
        let reads = Reads()
        let first = try page([observation(cursor: "c-1", content: resourceContent)], next: "n-1")
        let second = try page([observation(cursor: "c-3", content: linkContent)])
        let store = ReplyAttachmentStore { worker, mark, cursor in
            #expect(worker == "w" && mark.turnID == "op-7")
            await reads.record(cursor)
            return cursor == nil ? first : second
        }
        let link = try mark("resource_link")

        #expect(store.attachment(worker: "w", mark: link) == nil)
        await store.load(worker: "w", mark: link)
        await store.load(worker: "w", mark: link)

        guard case .link(let found)? = store.attachment(worker: "w", mark: link) else { Issue.record("expected the link"); return }
        #expect(found.name == "plan.txt" && found.size == 72)
        #expect(await reads.cursors == [nil, "n-1"])
        // Another worker with the same cursor has its own read and its own answer.
        #expect(store.attachment(worker: "other", mark: link) == nil)
    }

    /// The runner sends a chunk's message and its source record on separate requests: the first
    /// read may come before the record. It is read for once more, and every surface shares it.
    @Test @MainActor func aRecordThatArrivesAfterItsMessageIsFoundByTheOneFurtherRead() async throws {
        let reads = Reads(), pauses = Reads()
        let early = try page([observation(cursor: "c-2", content: resourceContent)])
        let ready = try page([observation(cursor: "c-2", content: resourceContent), observation(cursor: "c-3", content: linkContent)])
        let store = ReplyAttachmentStore(read: { _, _, cursor in
            await reads.record(cursor)
            return await reads.cursors.count == 1 ? early : ready
        }, pause: { await pauses.record(nil) })
        let link = try mark("resource_link")

        async let first: Void = store.load(worker: "w", mark: link)
        async let second: Void = store.load(worker: "w", mark: link)
        _ = await (first, second)

        guard case .link(let found)? = store.attachment(worker: "w", mark: link) else { Issue.record("expected the link"); return }
        #expect(found.name == "plan.txt" && found.size == 72)
        #expect(await reads.cursors.count == 2)
        #expect(await pauses.cursors.count == 1)
        await store.load(worker: "w", mark: link)
        #expect(await reads.cursors.count == 2)
    }

    @Test @MainActor func aChunkWhoseRecordNeverArrivesKeepsTheFallbackAfterTwoReads() async throws {
        let reads = Reads(), pauses = Reads()
        let empty = try page([observation(cursor: "c-9", content: linkContent)])
        let store = ReplyAttachmentStore(read: { _, _, cursor in
            await reads.record(cursor)
            return empty
        }, pause: { await pauses.record(nil) })
        let link = try mark("resource_link")

        for _ in 0..<5 { await store.load(worker: "w", mark: link) }
        #expect(store.attachment(worker: "w", mark: link) == nil)
        #expect(await reads.cursors.count == 2)
        #expect(await pauses.cursors.count == 1)

        // A change of service drops what was held: the chunk is read from the new one.
        store.serviceChanged()
        await store.load(worker: "w", mark: link)
        #expect(await reads.cursors.count == 4)
    }

    @Test @MainActor func aRecordThatIsNotTheChunksIsNotReadAgain() async throws {
        let reads = Reads(), pauses = Reads()
        let other = try page([observation(cursor: "c-3", content: linkContent, params: "s-2")])
        let store = ReplyAttachmentStore(read: { _, _, cursor in
            await reads.record(cursor)
            return other
        }, pause: { await pauses.record(nil) })
        let link = try mark("resource_link")

        await store.load(worker: "w", mark: link)
        await store.load(worker: "w", mark: link)
        #expect(store.attachment(worker: "w", mark: link) == nil)
        #expect(await reads.cursors.count == 1)
        #expect(await pauses.cursors.isEmpty)
    }

    @Test @MainActor func aChangeOfServiceDuringTheWaitDropsThatRead() async throws {
        let reads = Reads()
        let empty = try page([])
        let ready = try page([observation(cursor: "c-3", content: linkContent)])
        let store = ReplyAttachmentStore(read: { _, _, cursor in
            await reads.record(cursor)
            return await reads.cursors.count == 1 ? empty : ready
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let link = try mark("resource_link")

        let waiting = Task { await store.load(worker: "w", mark: link) }
        for _ in 0..<10_000 where await reads.cursors.isEmpty { await Task.yield() }
        store.serviceChanged()
        await waiting.value
        // The cancelled wait made no further read and cached nothing.
        #expect(await reads.cursors.count == 1)
        #expect(store.attachment(worker: "w", mark: link) == nil)

        await store.load(worker: "w", mark: link)
        #expect(await reads.cursors.count == 2)
        #expect(store.attachment(worker: "w", mark: link) != nil)
    }

    /// A transcript with many marked chunks reads every one, the latest first, two at a time.
    @Test @MainActor func manyChunksAreReadLatestFirstAFewAtATime() async throws {
        actor Meter {
            var running = 0, peak = 0, order: [String] = []
            func enter(_ cursor: String) { running += 1; peak = max(peak, running); order.append(cursor) }
            func leave() { running -= 1 }
        }
        let meter = Meter()
        let count = 40
        let store = ReplyAttachmentStore(read: { _, mark, _ in
            await meter.enter(mark.cursor)
            for _ in 0..<20 { await Task.yield() }
            await meter.leave()
            return try page([observation(cursor: mark.cursor, content: linkContent)])
        }, pause: {})
        let marks = try (1...count).map { try mark("resource_link", cursor: "c-\($0)") }

        await store.load(worker: "w", marks: marks)

        #expect(await meter.peak <= ReplyAttachmentStore.concurrentReads)
        let order = await meter.order
        #expect(order.count == count && Set(order).count == count)
        #expect(Set(order.prefix(2)) == ["c-\(count)", "c-\(count - 1)"])
        #expect(marks.allSatisfy { store.attachment(worker: "w", mark: $0) != nil })
    }

    /// Every page is read to its end, so a second record at the cursor on a later page is seen.
    @Test @MainActor func aSecondRecordAtTheCursorOnALaterPageNamesNeither() async throws {
        let reads = Reads()
        let first = try page([observation(cursor: "c-3", content: linkContent)], next: "n-1")
        let second = try page([observation(cursor: "c-3", content: linkContent)])
        let store = ReplyAttachmentStore(read: { _, _, cursor in
            await reads.record(cursor)
            return cursor == nil ? first : second
        }, pause: {})
        let link = try mark("resource_link")

        await store.load(worker: "w", mark: link)
        #expect(store.attachment(worker: "w", mark: link) == nil)
        #expect(await reads.cursors == [nil, "n-1"])
    }

    // MARK: The negotiated fixture

    /// The exact console event and live source records of the issue's ACP fixture.
    @Test func theFixturesReplyChunksAreReadFromItsOwnRecords() throws {
        let turn = "initial-w-57d31f234beb97c3ea9a72d4e21eedcf", cursor = "05a5f08c8656b33da3168e51b4367beb"
        func event(_ sequence: Int, _ type: String, _ text: String) throws -> AGUIMessage {
            try message(#"{"id":"w:\#(sequence)","role":"system","content":"\#(text)","metadata":{"acp":{"source":"live","cursor":"\#(cursor).\#(sequence)","turnId":"\#(turn)","kind":"agent_message_chunk","contentType":"\#(type)"}}}"#)
        }
        func record(_ sequence: Int, _ data: String) -> String {
            #"{"session":{"harnessInstance":"local-profile-fixture","sessionId":"pretty-resource-27115"},"cursor":"\#(cursor).\#(sequence)","turnId":"\#(turn)","extension":{"type":"acp.session_update","mediaType":"application/json","data":"\#(data)"}}"#
        }
        let history = try page([
            record(3, "eyJzZXNzaW9uVXBkYXRlIjogImFnZW50X21lc3NhZ2VfY2h1bmsiLCAiY29udGVudCI6IHsidHlwZSI6ICJyZXNvdXJjZV9saW5rIiwgIm5hbWUiOiAiaGFuZG9mZi50eHQiLCAidGl0bGUiOiAiTElOS19USVRMRV9RQV83MiIsICJzaXplIjogNzIsICJtaW1lVHlwZSI6ICJ0ZXh0L3BsYWluIiwgInVyaSI6ICJodHRwczovL2V4YW1wbGUuaW52YWxpZC9oYW5kb2ZmLnR4dCJ9fQ=="),
            record(4, "eyJzZXNzaW9uVXBkYXRlIjogImFnZW50X21lc3NhZ2VfY2h1bmsiLCAiY29udGVudCI6IHsidHlwZSI6ICJyZXNvdXJjZSIsICJyZXNvdXJjZSI6IHsidXJpIjogImh0dHBzOi8vZXhhbXBsZS5pbnZhbGlkL3Jlc291cmNlLnR4dCIsICJtaW1lVHlwZSI6ICJ0ZXh0L3BsYWluIiwgInRleHQiOiAiUkVTT1VSQ0VfUVVPVEFUSU9OX1FBXzcyIn19fQ==")
        ]).observations
        let messages = [
            try prose(1, "ACP attachment replay fixture", role: "user"), try prose(2, "BEFORE_ATTACHMENT_QA_72"),
            try event(3, "resource_link", "[ACP resource_link] text/plain https://example.invalid/handoff.txt"),
            try event(4, "resource", "[ACP resource] https://example.invalid/resource.txt"),
            try prose(7, "AFTER_ATTACHMENT_QA_72")
        ]
        let entries = TranscriptEntry.entries(from: messages)
        let linkMark = try #require(entries[2].replyAttachment), resourceMark = try #require(entries[3].replyAttachment)

        guard case .link(let link)? = ReplyAttachment.find(linkMark, in: history),
              case .resource(let resource)? = ReplyAttachment.find(resourceMark, in: history) else {
            Issue.record("expected the fixture's link and resource"); return
        }
        #expect(link == ReplyAttachment.Link(name: "handoff.txt", uri: "https://example.invalid/handoff.txt",
                                             title: "LINK_TITLE_QA_72", mimeType: "text/plain", size: 72))
        #expect(link.sizeText == "72 bytes" && link.caption() == "LINK_TITLE_QA_72, text/plain")
        #expect(resource == ReplyAttachment.Resource(uri: "https://example.invalid/resource.txt", mimeType: "text/plain",
                                                     text: "RESOURCE_QUOTATION_QA_72"))
        let items = pretty(messages, read: [linkMark: .link(link), resourceMark: .resource(resource)])
        #expect(items.map(\.id) == ["w:1", "w:2", "w:3", "w:4", "w:7"])
    }

    // MARK: Secrets

    @Test func aHiddenValueIsHiddenInEveryTextTheRowShowsOrSays() {
        // An overtly synthetic value: the keyed and Bearer contexts around it are what is masked.
        let placeholder = "fixture-placeholder-for-masking"
        let link = ReplyAttachment.Link(name: "API_TOKEN=\(placeholder)", uri: "https://example.com/get?token=\(placeholder)",
                                        title: "Bearer \(placeholder)", mimeType: "text/plain", size: 72)
        let resource = ReplyAttachment.Resource(uri: "https://example.com/get?token=\(placeholder)", mimeType: "text/plain", text: "x")

        // With the setting off everything is the provider's text.
        #expect(ReplyAttachment.shown(link.name, hidesSecrets: false) == link.name)
        #expect(link.caption().contains(placeholder) && resource.caption().contains(placeholder))
        // With it on, the name, the title, the help and the resource's address hold no secret.
        #expect(!ReplyAttachment.shown(link.name, hidesSecrets: true).contains(placeholder))
        #expect(!link.caption(hidesSecrets: true).contains(placeholder))
        #expect(!ReplyAttachment.shown(link.uri, hidesSecrets: true).contains(placeholder))
        #expect(!resource.caption(hidesSecrets: true).contains(placeholder))
        // The size and type are unchanged, and a click still has the address as sent.
        #expect(link.sizeText == "72 bytes" && link.caption(hidesSecrets: true).hasSuffix("text/plain"))
        #expect(link.openable?.absoluteString == link.uri)
        #expect(resource.caption(hidesSecrets: true).hasSuffix("text/plain"))

        // A type is the provider's free text: a keyed parameter of it is hidden the same way.
        let keyed = "text/plain; token=\(placeholder)"
        let typedLink = ReplyAttachment.Link(name: "plan.txt", uri: "https://example.com/plan.txt", title: "Plan", mimeType: keyed)
        let typedResource = ReplyAttachment.Resource(uri: "https://example.com/notes.txt", mimeType: keyed, text: "x")
        #expect(typedLink.caption() == "Plan, " + keyed)
        #expect(typedResource.caption() == "https://example.com/notes.txt, " + keyed)
        #expect(!typedLink.caption(hidesSecrets: true).contains(placeholder))
        #expect(!typedResource.caption(hidesSecrets: true).contains(placeholder))
        #expect(typedLink.caption(hidesSecrets: true).hasPrefix("Plan, text/plain; token="))
        #expect(typedResource.caption(hidesSecrets: true).hasPrefix("https://example.com/notes.txt, text/plain; token="))
        // An ordinary type reads the same with the setting on or off.
        let plain = ReplyAttachment.Link(name: "plan.txt", uri: "https://example.com/plan.txt", mimeType: "text/plain; charset=utf-8")
        #expect(plain.caption(hidesSecrets: true) == "text/plain; charset=utf-8" && plain.caption() == "text/plain; charset=utf-8")
    }

    @Test @MainActor func aFailedReadIsNotCountedAsMissing() async throws {
        struct Offline: Error {}
        let reads = Reads()
        let good = try page([observation(cursor: "c-3", content: linkContent)])
        let store = ReplyAttachmentStore { _, _, cursor in
            await reads.record(cursor)
            if await reads.cursors.count <= 4 { throw Offline() }
            return good
        }
        let link = try mark("resource_link")

        for _ in 0..<4 { await store.load(worker: "w", mark: link) }
        #expect(store.attachment(worker: "w", mark: link) == nil)
        await store.load(worker: "w", mark: link)
        #expect(store.attachment(worker: "w", mark: link) != nil)
    }
}
