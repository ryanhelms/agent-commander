import Foundation
import Testing
@testable import AgentCommander

// A message from another session (DESIGN.md, "Pretty transcript"; spec section H, "ACP
// session_message"). The events have the shape the service sends for a negotiated ACP session:
// `[ACP session_message]` or `[ACP session_message_chunk] text`, with the kind, the provider's
// message ID and the live source cursor. The update itself stays in the worker's live source at
// that cursor.

private func message(_ json: String) throws -> AGUIMessage {
    try AGUIMessage(fields: AGUIValue(json: json))
}

private func prose(_ sequence: Int, _ text: String, role: String = "assistant") throws -> AGUIMessage {
    try message(#"{"id":"w:\#(sequence)","role":"\#(role)","content":"\#(text)"}"#)
}

private let epoch = "de4f8789c3904bcc08e12bcb16a88d9f"

/// The service's message for one session message update.
private func event(_ sequence: Int, _ id: String?, chunk text: String? = nil, cursor: String? = nil,
                   turn: String? = "op-7", source: String = "live", kind: String? = nil, contentType: String? = nil,
                   role: String = "system") throws -> AGUIMessage {
    let kind = kind ?? (text == nil ? "session_message" : "session_message_chunk")
    var acp = #""source":"\#(source)","kind":"\#(kind)""#
    if let cursor = cursor ?? Optional("\(epoch).\(sequence)"), !cursor.isEmpty { acp += #","cursor":"\#(cursor)""# }
    if let turn { acp += #","turnId":"\#(turn)""# }
    if let id { acp += #","messageId":"\#(id)""# }
    if let type = contentType ?? (text == nil ? nil : "text") { acp += #","contentType":"\#(type)""# }
    let content = "[ACP \(kind)]" + (text.map { " " + $0 } ?? "")
    return try message(#"{"id":"w:\#(sequence)","role":"\#(role)","content":"\#(content)","metadata":{"acp":{\#(acp)}}}"#)
}

/// One live source record: the SDK observation with the provider's original update.
private func record(_ sequence: Int, _ update: String, session: String? = "s-1", params: String? = nil,
                    turn: String = "op-7", cursor: String? = nil, sourceCursor: String? = nil) -> String {
    let original = params.map { #"{"sessionId":"\#($0)","update":\#(update)}"# } ?? update
    let data = Data(original.utf8).base64EncodedString()
    let type = params == nil ? "acp.session_update" : "acp.session_update_params"
    let member = params == nil ? "extension" : "sourceRecord"
    var fields = #""cursor":"\#(cursor ?? "\(epoch).\(sequence)")","turnId":"\#(turn)","\#(member)":{"type":"\#(type)","mediaType":"application/json","data":"\#(data)"}"#
    if let session { fields += #","session":{"harnessInstance":"claude","sessionId":"\#(session)"}"# }
    if let sourceCursor { fields += #","sourceCursor":"\#(sourceCursor)""# }
    return "{\(fields)}"
}

private func snapshot(_ id: String, _ members: String = "") -> String {
    #"{"sessionUpdate":"session_message","messageId":"\#(id)"\#(members.isEmpty ? "" : "," + members)}"#
}

private func piece(_ id: String, _ text: String) -> String {
    #"{"sessionUpdate":"session_message_chunk","messageId":"\#(id)","content":{"type":"text","text":"\#(text)"}}"#
}

private func content(_ text: String) -> String { #""content":[{"type":"text","text":"\#(text)"}]"# }

private func page(_ observations: [String], next: String = "") throws -> SourcePage {
    try SourcePage(envelope: Data(#"{"observations":[\#(observations.joined(separator: ","))],"nextCursor":"\#(next)"}"#.utf8))
}

private func marks(_ messages: [AGUIMessage]) -> [SessionMessageMark] {
    TranscriptEntry.entries(from: messages).flatMap(\.sessionMessages)
}

/// What a read of `records` answers for each reference of `messages`: its own record, or missing.
private func read(_ messages: [AGUIMessage], _ records: [String]) throws -> [SessionMessageMark: SessionMessageDetail] {
    let observations = try page(records).observations
    var details: [SessionMessageMark: SessionMessageDetail] = [:]
    for mark in marks(messages) {
        let found = observations.filter { $0.cursor == mark.cursor }.compactMap(SessionMessagePatch.init(observation:))
        details[mark] = found.count == 1 && found[0].answers(mark) ? .patch(found[0]) : .missing
    }
    return details
}

private func pretty(_ messages: [AGUIMessage], _ details: [SessionMessageMark: SessionMessageDetail] = [:]) -> [PrettyItem] {
    let entries = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .pretty)
    var facts = ActivityFacts.none
    facts.sessionMessage = { details[$0] }
    return ActivityConversation.items(ConversationActivity.items(entries), facts: facts)
}

private func drawn(_ items: [PrettyItem]) -> [SessionMessage] {
    items.compactMap { if case .message(let message) = $0 { message } else { nil } }
}

/// One reference as the service writes it for an ACP v2 session: both kinds of update under the
/// kind `session_message`, with the operation.
private func v2Reference(_ position: Int, _ id: String, _ operation: String, kind: String = "session_message",
                         turn: String = "op-7") -> String {
    #"{"source":"live","cursor":"\#(epoch).\#(position)","turnId":"\#(turn)","kind":"\#(kind)","messageId":"\#(id)","messageOp":"\#(operation)","contentType":"text"}"#
}

/// The service's one message for several updates of one v2 message: `acpSources` lists every
/// reference in the order sent, and `acp` is the latest. `text` is the service's own preview.
private func grouped(_ sequence: Int, _ references: [String], latest: String? = nil, text: String) throws -> AGUIMessage {
    let latest = latest ?? references[references.count - 1]
    let sources = references.count > 1 ? #","acpSources":[\#(references.joined(separator: ","))]"# : ""
    return try message(#"{"id":"w:\#(sequence)","role":"system","content":"\#(text)","metadata":{"acp":\#(latest)\#(sources)}}"#)
}

/// A v2 source record. A snapshot keeps the provider's params as its source record beside the
/// normalised message state; an appended chunk keeps the params as its extension.
private func v2Record(_ position: Int, _ update: String, session: String = "s-1", turn: String = "op-7") -> String {
    let cursor = "\(epoch).\(position)"
    let params = Data(#"{"sessionId":"\#(session)","update":\#(update)}"#.utf8).base64EncodedString()
    let head = #""session":{"harnessInstance":"claude","sessionId":"\#(session)"},"cursor":"\#(cursor)","turnId":"\#(turn)","sourceCursor":"\#(cursor)""#
    let original = #"{"type":"acp.session_update_params","mediaType":"application/json","data":"\#(params)"}"#
    guard update.contains(#""session_message_chunk""#) else {
        // The normalised state holds the text only: no sender and no recipient.
        let state = Data(#"{"kind":"session_message","messageId":"normalised","content":[{"type":"text","text":"NORMALISED"}]}"#.utf8)
            .base64EncodedString()
        return #"{\#(head),"extension":{"type":"acp.v2_message_state","mediaType":"application/json","data":"\#(state)"},"sourceRecord":\#(original)}"#
    }
    return #"{\#(head),"extension":\#(original)}"#
}

/// The sentence of each folded line, as it is drawn and said.
private func foldedWords(_ items: [PrettyItem]) -> [String] {
    items.flatMap { item -> [String] in
        if case .group(let group) = item { return group.lines.map(\.sentence.plain) }
        return []
    }
}

/// The IDs of the entries left as folded session updates.
private func folded(_ items: [PrettyItem]) -> [String] {
    items.flatMap { item -> [String] in
        if case .group(let group) = item { return group.lines.flatMap(\.entries).map(\.id) }
        return []
    }
}

private actor Reads {
    private(set) var cursors: [String?] = []
    private(set) var turns: [String?] = []
    private(set) var pauses = 0
    private var fails = false
    func record(_ turn: String?, _ cursor: String?) throws {
        turns.append(turn)
        cursors.append(cursor)
        if fails { throw ServiceError.rejected("unavailable") }
    }
    func paused() { pauses += 1 }
    func fail(_ value: Bool) { fails = value }
}

@Suite struct SessionMessageTests {
    // MARK: The reference

    @Test func onlyATypedLiveUpdateWithAnIDAndACursorIsMarked() throws {
        func marked(_ message: AGUIMessage) -> SessionMessageMark? {
            TranscriptEntry.entries(from: [message]).first?.sessionMessages.first
        }
        let snapshot = try #require(marked(try event(3, "qa-one")))
        #expect(snapshot.kind == .snapshot && snapshot.messageID == "qa-one" && snapshot.cursor == epoch + ".3"
            && snapshot.turnID == "op-7")
        let chunk = try #require(marked(try event(4, "qa-one", chunk: "FIRST")))
        #expect(chunk.kind == .chunk && chunk.messageID == "qa-one")
        // Outside a turn the reference names none.
        #expect(try #require(marked(try event(5, "qa-one", turn: nil))).turnID == nil)

        // An older preview with the same marker text and no reference is never read as one.
        #expect(marked(try prose(3, "[ACP session_message_chunk] FIRST", role: "system")) == nil)
        #expect(marked(try event(3, "qa-one", source: "provider")) == nil)
        #expect(marked(try event(3, nil)) == nil)
        #expect(marked(try event(3, "qa-one", cursor: "")) == nil)
        #expect(marked(try event(3, "qa-one", role: "user")) == nil)
        #expect(marked(try event(3, "qa-one", kind: "agent_message_chunk")) == nil)
        // A chunk of any other content type keeps the fallback.
        #expect(marked(try event(3, "qa-one", chunk: "x", contentType: "image")) == nil)
        #expect(marked(try event(3, "qa-one", chunk: "x", contentType: "resource_link")) == nil)
    }

    // MARK: The record

    @Test func theRecordIsReadOnlyFromTheUpdateTheReferenceNames() throws {
        func patch(_ record: String) throws -> SessionMessagePatch? {
            SessionMessagePatch(observation: try #require(try page([record]).observations.first))
        }
        let mark = try #require(marks([try event(3, "qa-one")]).first)
        let own = try #require(try patch(record(3, snapshot("qa-one", #""senderSessionId":"sender-alpha","# + content("Hello")))))
        #expect(own.answers(mark) && own.session.sessionID == "s-1" && own.sender == .set("sender-alpha")
            && own.content == .set("Hello"))
        // The provider's notification, when the record keeps it, names the same session.
        #expect(try patch(record(3, snapshot("qa-one"), params: "s-1"))?.answers(mark) == true)
        #expect(try patch(record(3, snapshot("qa-one"), params: "s-2")) == nil)

        // Another message, kind, turn or cursor is not this reference's record.
        #expect(try patch(record(3, snapshot("qa-two")))?.answers(mark) == false)
        #expect(try patch(record(3, piece("qa-one", "x")))?.answers(mark) == false)
        #expect(try patch(record(3, snapshot("qa-one"), turn: "op-8"))?.answers(mark) == false)
        #expect(try patch(record(3, snapshot("qa-one"), turn: ""))?.answers(mark) == false)
        #expect(try patch(record(4, snapshot("qa-one")))?.answers(mark) == false)
        // A reference outside a turn is answered only by a record outside a turn.
        let idle = try #require(marks([try event(3, "qa-one", turn: nil)]).first)
        #expect(try patch(record(3, snapshot("qa-one"), turn: ""))?.answers(idle) == true)
        #expect(own.answers(idle) == false)

        // No session, another record's original, no message ID, another update: not read at all.
        #expect(try patch(record(3, snapshot("qa-one"), session: nil)) == nil)
        #expect(try patch(record(3, snapshot("qa-one"), session: "")) == nil)
        #expect(try patch(record(3, snapshot("qa-one"), sourceCursor: epoch + ".9")) == nil)
        #expect(try patch(record(3, #"{"sessionUpdate":"session_message"}"#)) == nil)
        #expect(try patch(record(3, #"{"sessionUpdate":"session_message","messageId":""}"#)) == nil)
        #expect(try patch(record(3, #"{"sessionUpdate":"agent_message_chunk","messageId":"qa-one","content":{"type":"text","text":"x"}}"#)) == nil)
        // Content that is not text, and a sender that is not a string, are out of scope.
        #expect(try patch(record(3, snapshot("qa-one", #""content":[{"type":"image","mimeType":"image/png","data":"AA=="}]"#))) == nil)
        #expect(try patch(record(3, snapshot("qa-one", #""content":"text""#))) == nil)
        #expect(try patch(record(3, snapshot("qa-one", #""senderSessionId":42"#))) == nil)
        #expect(try patch(record(3, #"{"sessionUpdate":"session_message_chunk","messageId":"qa-one","content":{"type":"resource_link","uri":"https://example.invalid/x","name":"x"}}"#)) == nil)
        // The provider's own key only: another spelling names no sender.
        #expect(try patch(record(3, snapshot("qa-one", #""sender":"x","sender_session_id":"y""#)))?.sender == .omitted)
    }

    @Test func aSnapshotStatesWhatItLeavesClearsAndReplaces() throws {
        func patch(_ members: String) throws -> SessionMessagePatch {
            let observation = try #require(try page([record(3, snapshot("m", members))]).observations.first)
            return try #require(SessionMessagePatch(observation: observation))
        }
        #expect(try patch("").content == .omitted && patch("").sender == .omitted)
        #expect(try patch(#""content":null"#).content == .cleared)
        #expect(try patch(#""content":[]"#).content == .cleared)
        #expect(try patch(#""content":[{"type":"text","text":"a "},{"type":"text","text":"b"}]"#).content == .set("a b"))
        #expect(try patch(#""senderSessionId":null"#).sender == .cleared)
        #expect(try patch(#""recipientSessionId":"s-1","recipientMessageId":"r-9""#).recipient == .set("s-1"))
        #expect(try patch(#""recipientSessionId":"s-1","recipientMessageId":"r-9""#).recipientMessage == .set("r-9"))
    }

    // MARK: The conversation

    /// The captured fixture: two messages between two replies, the second with no sender.
    @Test func theCapturedMessagesAreDrawnBetweenTheirReplies() throws {
        let turn = "initial-w-48c13661de2cf3e21e46bf79727134ea"
        func captured(_ sequence: Int, _ data: String) -> String {
            #"{"session":{"harnessInstance":"local-profile-fixture","sessionId":"pretty-activity-7639"},"cursor":"\#(epoch).\#(sequence)","turnId":"\#(turn)","extension":{"type":"acp.session_update","mediaType":"application/json","data":"\#(data)"}}"#
        }
        let records = [
            captured(3, "eyJzZXNzaW9uVXBkYXRlIjogInNlc3Npb25fbWVzc2FnZSIsICJtZXNzYWdlSWQiOiAicWEtb25lIiwgInNlbmRlclNlc3Npb25JZCI6ICJzZW5kZXItYWxwaGEiLCAiY29udGVudCI6IFt7InR5cGUiOiAidGV4dCIsICJ0ZXh0IjogIkZJUlNUX1NOQVBTSE9UX1FBIn1dfQ=="),
            captured(4, "eyJzZXNzaW9uVXBkYXRlIjogInNlc3Npb25fbWVzc2FnZV9jaHVuayIsICJtZXNzYWdlSWQiOiAicWEtb25lIiwgImNvbnRlbnQiOiB7InR5cGUiOiAidGV4dCIsICJ0ZXh0IjogIkZJUlNUX0NIVU5LX1FBIn19"),
            captured(5, "eyJzZXNzaW9uVXBkYXRlIjogInNlc3Npb25fbWVzc2FnZSIsICJtZXNzYWdlSWQiOiAicWEtdHdvIn0="),
            captured(6, "eyJzZXNzaW9uVXBkYXRlIjogInNlc3Npb25fbWVzc2FnZV9jaHVuayIsICJtZXNzYWdlSWQiOiAicWEtdHdvIiwgImNvbnRlbnQiOiB7InR5cGUiOiAidGV4dCIsICJ0ZXh0IjogIlVOS05PV05fU0VOREVSX1FBIn19")
        ]
        let messages = [
            try prose(1, "ACP activity fixture; execute nothing", role: "user"), try prose(2, "BEFORE_SESSION_MESSAGE_QA"),
            try event(3, "qa-one", turn: turn), try event(4, "qa-one", chunk: "FIRST_CHUNK_QA", turn: turn),
            try event(5, "qa-two", turn: turn), try event(6, "qa-two", chunk: "UNKNOWN_SENDER_QA", turn: turn),
            try prose(7, "AFTER_SESSION_MESSAGE_QA")
        ]
        let items = pretty(messages, try read(messages, records))
        #expect(items.map(\.id) == ["w:1", "w:2", "w:3#message", "w:5#message", "w:7"])
        let rows = drawn(items)
        #expect(rows.map(\.sender) == ["sender-alpha", nil])
        #expect(rows.map(\.text) == ["FIRST_SNAPSHOT_QAFIRST_CHUNK_QA", "UNKNOWN_SENDER_QA"])
        #expect(rows.map(\.session.sessionID) == ["pretty-activity-7639", "pretty-activity-7639"])
        #expect(SessionMessageWords(message: rows[0], hidesSecrets: true).heading == "Message from sender-alpha")
        #expect(SessionMessageWords(message: rows[1], hidesSecrets: true).heading == "Message from another session")
        // Without the records, the same events are the folded session updates they were.
        #expect(drawn(pretty(messages)).isEmpty)
        #expect(folded(pretty(messages)) == ["w:3", "w:4", "w:5", "w:6"])
    }

    @Test func interleavedMessagesAreJoinedByTheirOwnIDNeverByPosition() throws {
        let messages = [
            try prose(1, "Go.", role: "user"),
            try event(2, "a"), try event(3, "b"),
            try event(4, "a", chunk: "same"), try event(5, "b", chunk: "same"),
            try event(6, "b", chunk: " b-tail"), try event(7, "a", chunk: " a-tail"),
            try prose(8, "Done.")
        ]
        let records = [
            record(2, snapshot("a", #""senderSessionId":"alpha","# + content("A: "))),
            record(3, snapshot("b", #""senderSessionId":"beta","# + content("B: "))),
            record(4, piece("a", "same")), record(5, piece("b", "same")),
            record(6, piece("b", " b-tail")), record(7, piece("a", " a-tail"))
        ]
        let items = pretty(messages, try read(messages, records))
        // Each message keeps the place of its first update; the later ones change it there.
        #expect(items.map(\.id) == ["w:1", "w:2#message", "w:3#message", "w:8"])
        let rows = drawn(items)
        #expect(rows.map(\.sender) == ["alpha", "beta"])
        #expect(rows.map(\.text) == ["A: same a-tail", "B: same b-tail"])
        #expect(rows.map { $0.entries.map(\.id) } == [["w:2", "w:4", "w:7"], ["w:3", "w:5", "w:6"]])
    }

    @Test func theSameIDInAnotherSessionIsAnotherMessage() throws {
        let messages = [try event(2, "m"), try event(3, "m"), try event(4, "m", chunk: " more"), try event(5, "m", chunk: " else")]
        let records = [
            record(2, snapshot("m", content("first")), session: "s-1"), record(3, snapshot("m", content("second")), session: "s-2"),
            record(4, piece("m", " more"), session: "s-1"), record(5, piece("m", " else"), session: "s-2")
        ]
        let rows = drawn(pretty(messages, try read(messages, records)))
        #expect(rows.map(\.text) == ["first more", "second else"])
        #expect(rows.map(\.session.sessionID) == ["s-1", "s-2"])
    }

    @Test func aSnapshotReplacesOrClearsAndAnOmittedMemberLeavesWhatWasThere() throws {
        func row(_ updates: [String]) throws -> SessionMessage? {
            let messages = try updates.enumerated().map { index, update in
                try update.contains("session_message_chunk") ? event(index + 2, "m", chunk: "x") : event(index + 2, "m")
            }
            let records = updates.enumerated().map { record($0 + 2, $1) }
            return drawn(pretty(messages, try read(messages, records))).first
        }
        let start = snapshot("m", #""senderSessionId":"alpha","# + content("one"))
        // A chunk appends; a snapshot with content replaces all of it.
        #expect(try row([start, piece("m", " two")])?.text == "one two")
        #expect(try row([start, piece("m", " two"), snapshot("m", content("three"))])?.text == "three")
        // An empty array and `null` clear the text; the sender stays.
        #expect(try row([start, snapshot("m", #""content":[]"#)])?.text == "")
        #expect(try row([start, snapshot("m", #""content":null"#)])?.text == "")
        #expect(try row([start, snapshot("m", #""content":null"#)])?.sender == "alpha")
        // Omitted content and an omitted sender leave both as they were.
        #expect(try row([start, snapshot("m")])?.text == "one")
        #expect(try row([start, snapshot("m")])?.sender == "alpha")
        // A `null` sender clears it; the text stays. A later value names it again.
        #expect(try row([start, snapshot("m", #""senderSessionId":null"#)])?.sender == nil)
        #expect(try row([start, snapshot("m", #""senderSessionId":null"#)])?.text == "one")
        #expect(try row([start, snapshot("m", #""senderSessionId":null"#), snapshot("m", #""senderSessionId":"beta""#)])?.sender == "beta")
        // Cleared, then appended to.
        #expect(try row([start, snapshot("m", #""content":[]"#), piece("m", "new")])?.text == "new")
    }

    @Test func aMessageEndsTheGroupAndProseStillDoes() throws {
        func note(_ sequence: Int) throws -> AGUIMessage {
            try message(#"{"id":"w:\#(sequence)","role":"system","content":"[ACP usage_update] 13 / 50","metadata":{"acp":{"source":"live","kind":"usage_update","usage":{"used":13,"size":50}}}}"#)
        }
        let messages = [
            try prose(1, "Go.", role: "user"), try note(2), try event(3, "m"), try note(4),
            try event(5, "m", chunk: " more"), try note(6), try prose(7, "Done.")
        ]
        let records = [record(3, snapshot("m", content("text"))), record(5, piece("m", " more"))]
        let items = pretty(messages, try read(messages, records))
        // The later update changes the row in place and does not split the group it sits in.
        #expect(items.map(\.id) == ["w:1", "w:2#group", "w:3#message", "w:4#group", "w:7"])
        #expect(folded(items) == ["w:2", "w:4", "w:6"])
        #expect(drawn(items).first?.text == "text more")
    }

    // MARK: Fallback

    @Test func aReferenceWithNoRecordAndEveryLaterOneOfItsIDStayFolded() throws {
        let messages = [
            try event(2, "m"), try event(3, "m", chunk: "lost"), try event(4, "m", chunk: " tail"),
            try event(5, "n"), try event(6, "n", chunk: "kept")
        ]
        var details = try read(messages, [
            record(2, snapshot("m", content("head"))), record(4, piece("m", " tail")),
            record(5, snapshot("n")), record(6, piece("n", "kept"))
        ])
        let items = pretty(messages, details)
        // What the lost update changed is not known, so nothing after it is joined to the text.
        #expect(drawn(items).map(\.text) == ["head", "kept"])
        #expect(folded(items) == ["w:3", "w:4"])
        // The first update lost: no row at all for that message.
        details[marks(messages)[0]] = .missing
        #expect(drawn(pretty(messages, details)).map(\.messageID) == ["n"])
        #expect(folded(pretty(messages, details)) == ["w:2", "w:3", "w:4"])
    }

    @Test func aRecordOfAnotherMessageOrTurnIsNeverUsedInItsPlace() throws {
        let messages = [try event(2, "m"), try event(3, "m", chunk: "text")]
        let foreign = try #require(try page([record(3, piece("other", "text"))]).observations.first)
        let other = try #require(SessionMessagePatch(observation: foreign))
        var details = try read(messages, [record(2, snapshot("m", content("head"))), record(3, piece("m", "text"))])
        // A stored detail that is not the reference's own, however it got there, is not applied.
        details[marks(messages)[1]] = .patch(other)
        let items = pretty(messages, details)
        #expect(drawn(items).map(\.text) == ["head"])
        #expect(folded(items) == ["w:3"])
    }

    @Test func anAwaitedUpdateHoldsItsMessageSoTextIsNeverJoinedOutOfOrder() throws {
        let messages = [try event(2, "m"), try event(3, "m", chunk: " two"), try event(4, "m", chunk: " three")]
        let all = try read(messages, [
            record(2, snapshot("m", content("one"))), record(3, piece("m", " two")), record(4, piece("m", " three"))
        ])
        let found = marks(messages)
        // The third answered before the second: it waits, in the message's row, not as a row.
        var details = all
        details[found[1]] = .awaited
        var items = pretty(messages, details)
        #expect(drawn(items).map(\.text) == ["one"])
        #expect(items.map(\.id) == ["w:2#message"] && folded(items).isEmpty)
        // Once the second answers, the text is in the order sent.
        items = pretty(messages, all)
        #expect(drawn(items).map(\.text) == ["one two three"])
        // Before any update is read there is no row to wait in: each stays a session update.
        details = [found[0]: .awaited, found[1]: .awaited, found[2]: .awaited]
        #expect(drawn(pretty(messages, details)).isEmpty)
        #expect(folded(pretty(messages, details)) == ["w:2", "w:3", "w:4"])
    }

    @Test func anUpdateSentTwiceIsAppliedOnce() throws {
        let messages = [try event(2, "m"), try event(3, "m", chunk: " two"),
                        try event(4, "m", chunk: " two", cursor: epoch + ".3")]
        let details = try read(messages, [record(2, snapshot("m", content("one"))), record(3, piece("m", " two"))])
        let items = pretty(messages, details)
        #expect(drawn(items).map(\.text) == ["one two"])
        #expect(items.map(\.id) == ["w:2#message"])
    }

    // MARK: Direction and sender

    @Test func aMessageThisSessionSentIsNotDrawnAsIncoming() throws {
        func rows(_ updates: [String]) throws -> [PrettyItem] {
            let messages = try updates.indices.map { try event($0 + 2, "m") }
            return pretty(messages, try read(messages, updates.enumerated().map { record($0 + 2, $1) }))
        }
        // The enclosing session is `s-1`.
        #expect(drawn(try rows([snapshot("m", #""senderSessionId":"s-1","# + content("mine"))])).isEmpty)
        #expect(folded(try rows([snapshot("m", #""senderSessionId":"s-1","# + content("mine"))])) == ["w:2"])
        #expect(drawn(try rows([snapshot("m", #""recipientSessionId":"s-2","# + content("to them"))])).isEmpty)
        #expect(drawn(try rows([snapshot("m", #""recipientMessageId":"r-1","# + content("to them"))])).isEmpty)
        // Named as received by this session from another: incoming.
        let incoming = drawn(try rows([snapshot("m", #""senderSessionId":"s-2","recipientSessionId":"s-1","# + content("to me"))]))
        #expect(incoming.map(\.sender) == ["s-2"] && incoming.map(\.text) == ["to me"])
        // A later update may be the one that says which way it went.
        let later = try rows([snapshot("m", content("text")), snapshot("m", #""senderSessionId":"s-1""#)])
        #expect(drawn(later).isEmpty && folded(later) == ["w:2", "w:3"])
        let cleared = try rows([snapshot("m", #""recipientSessionId":"s-2","# + content("text")),
                                snapshot("m", #""recipientSessionId":null,"senderSessionId":"s-2""#)])
        #expect(drawn(cleared).map(\.sender) == ["s-2"])
    }

    @Test func aMessageWithNoSenderReadsTheApprovedLine() throws {
        let messages = [try event(2, "m")]
        let row = try #require(drawn(pretty(messages, try read(messages, [record(2, snapshot("m", content("Hello")))]))).first)
        let words = SessionMessageWords(message: row, hidesSecrets: false)
        #expect(words.heading == "Message from another session" && words.sender == nil)
        #expect(words.accessibilityLabel == "Message from another session. Hello")
        // An empty name is no name.
        let blank = [record(2, snapshot("m", #""senderSessionId":"  ","# + content("Hello")))]
        #expect(drawn(pretty(messages, try read(messages, blank))).first?.sender == nil)
    }

    // MARK: Secrets

    @Test func aValueSplitAcrossChunksIsHiddenInEveryTextTheRowShowsOrSays() throws {
        // Made-up values under a generic key the masker knows. Neither has a provider's key shape.
        let value = "made-up-example-170", name = "made-up-sender-170"
        let messages = [try event(2, "m"), try event(3, "m", chunk: "up-example-"), try event(4, "m", chunk: "170 today.")]
        let records = [
            record(2, snapshot("m", #""senderSessionId":"API_TOKEN=\#(name)","# + content("Use API_TOKEN=made-"))),
            record(3, piece("m", "up-example-")), record(4, piece("m", "170 today."))
        ]
        let row = try #require(drawn(pretty(messages, try read(messages, records))).first)
        #expect(row.text == "Use API_TOKEN=" + value + " today.")

        // Masked after the pieces are joined: the middle piece alone does not look like a value.
        #expect(SecretValues.masked(prose: "up-example-").count == 0)
        let hidden = SessionMessageWords(message: row, hidesSecrets: true)
        for shown in [hidden.text, hidden.heading, hidden.accessibilityLabel, hidden.sender ?? ""] {
            #expect(!shown.contains(value) && !shown.contains("up-example") && !shown.contains(name))
        }
        #expect(hidden.text.hasPrefix("Use API_TOKEN=") && hidden.text.hasSuffix(" today."))
        #expect(hidden.heading.hasPrefix("Message from API_TOKEN="))
        #expect(hidden.hidden == 2 && hidden.hiddenNote == "2 values hidden")
        #expect(hidden.accessibilityLabel.hasSuffix("2 values hidden"))

        let plain = SessionMessageWords(message: row, hidesSecrets: false)
        #expect(plain.text == row.text && plain.hidden == 0 && plain.hiddenNote == nil)
    }

    @Test func anUpdateThatIsNotDrawnAsItsMessageNamesNoTextAndNoSender() throws {
        // The middle piece of a split value: on its own it does not look like one.
        let messages = [
            try prose(1, "Go.", role: "user"), try event(2, "m"), try event(3, "m", chunk: "up-example-"),
            try event(4, "m", chunk: "170 today."), try prose(5, "Done.")
        ]
        let all = try read(messages, [
            record(2, snapshot("m", #""senderSessionId":"made-up-sender-170","# + content("Use API_TOKEN=made-"))),
            record(3, piece("m", "up-example-")), record(4, piece("m", "170 today."))
        ])
        let found = marks(messages)
        // Still being read, expired, failed, or never asked for: the same neutral line.
        let states: [[SessionMessageMark: SessionMessageDetail]] = [
            [:], [found[0]: .awaited, found[1]: .awaited, found[2]: .awaited],
            [found[0]: .missing, found[1]: .missing, found[2]: .missing],
            [found[0]: .missing, found[1]: all[found[1]] ?? .missing, found[2]: all[found[2]] ?? .missing]
        ]
        for details in states {
            let items = pretty(messages, details)
            #expect(drawn(items).isEmpty)
            #expect(folded(items) == ["w:2", "w:3", "w:4"])
            #expect(foldedWords(items) == ["Session message", "Session message", "Session message"])
        }
        // The line and what VoiceOver says for it hold no text of the update and no sender.
        for entry in TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .pretty)
        where !entry.sessionMessages.isEmpty {
            let event = try #require(ActivityEvent(entry: entry, hidesSecrets: false))
            #expect(event.label == "Session message" && event.detail.isEmpty && event.folds)
            #expect(!event.accessibilityLabel.contains("up-example") && !event.accessibilityLabel.contains("170"))
        }
        // The first two expired and the last one read: its text is not shown without them.
        let partial = pretty(messages, [found[0]: .missing, found[1]: .missing, found[2]: all[found[2]] ?? .missing])
        #expect(drawn(partial).isEmpty && !foldedWords(partial).joined().contains("170"))
        // Console keeps the service's text for each update.
        let console = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .console)
        #expect(console.map(\.plainText)[2] == "[ACP session_message_chunk] up-example-")
    }

    /// The captured expiry: the first message's records left the source window, the later
    /// message's are still there, with twelve notices between them.
    @Test func anExpiredMessageKeepsTheNeutralFallbackAndALaterOneIsStillRead() throws {
        var messages = [
            try prose(1, "ACP activity fixture; execute nothing", role: "user"), try prose(2, "BEFORE_SESSION_MESSAGE_QA"),
            try event(3, "expired"), try event(4, "expired", chunk: " EXPIRED_CHUNK_QA")
        ]
        for filler in 1...12 {
            messages.append(try message(#"{"id":"w:\#(filler + 4)","role":"system","content":"[ACP notice] Filler \#(filler)","metadata":{"acp":{"source":"live","cursor":"\#(epoch).\#(filler + 4)","turnId":"op-7","kind":"notice","noticeSeverity":"info"}}}"#))
        }
        messages += [try event(17, "retained"), try event(18, "retained", chunk: " RETAINED_CHUNK_QA"),
                     try prose(19, "AFTER_SESSION_MESSAGE_QA")]
        // What the window still holds: the later pair only.
        let details = try read(messages, [
            record(17, snapshot("retained", #""senderSessionId":"sender-retained","# + content("RETAINED_SNAPSHOT_QA"))),
            record(18, piece("retained", " RETAINED_CHUNK_QA"))
        ])
        let items = pretty(messages, details)
        let rows = drawn(items)
        #expect(rows.map(\.sender) == ["sender-retained"])
        #expect(rows.map(\.text) == ["RETAINED_SNAPSHOT_QA RETAINED_CHUNK_QA"])
        #expect(rows.map { $0.entries.map(\.id) } == [["w:17", "w:18"]])
        // The expired pair stays where it was, as two neutral lines: no sender, no text.
        #expect(Array(folded(items).prefix(2)) == ["w:3", "w:4"])
        #expect(Array(foldedWords(items).prefix(2)) == ["Session message", "Session message"])
        let shown = foldedWords(items).joined(separator: "\n") + rows.map { SessionMessageWords(message: $0, hidesSecrets: false).accessibilityLabel }.joined()
        #expect(!shown.contains("EXPIRED") && !shown.contains("stale-sender"))
        #expect(items.last?.id == "w:19")
    }

    // MARK: ACP v2

    @Test func aV2ReferenceIsReadByItsOperation() throws {
        func mark(_ reference: String) throws -> SessionMessageMark? {
            TranscriptEntry.entries(from: [try grouped(3, [reference], text: "PREVIEW")]).first?.sessionMessages.first
        }
        // Both kinds of update arrive under `session_message`; the operation says which it is.
        #expect(try mark(v2Reference(3, "alpha", "replace"))?.kind == .snapshot)
        #expect(try mark(v2Reference(3, "alpha", "append"))?.kind == .chunk)
        #expect(try mark(v2Reference(3, "alpha", "append", kind: "session_message_chunk"))?.kind == .chunk)
        // A pairing no update has, and an operation the service does not write, are not marked.
        #expect(try mark(v2Reference(3, "alpha", "replace", kind: "session_message_chunk")) == nil)
        #expect(try mark(v2Reference(3, "alpha", "remove")) == nil)
        #expect(try mark(v2Reference(3, "alpha", "append", kind: "agent_message")) == nil)

        // The record must be the update on the wire: a chunk for an append, a snapshot for a replace.
        let append = try #require(try mark(v2Reference(3, "alpha", "append")))
        let replace = try #require(try mark(v2Reference(3, "alpha", "replace")))
        func patch(_ record: String) throws -> SessionMessagePatch? {
            SessionMessagePatch(observation: try #require(try page([record]).observations.first))
        }
        let chunk = try #require(try patch(v2Record(3, piece("alpha", " more"))))
        let whole = try #require(try patch(v2Record(3, snapshot("alpha", #""senderSessionId":"sender-alpha-v2","# + content("text")))))
        #expect(chunk.answers(append) && !chunk.answers(replace))
        #expect(whole.answers(replace) && !whole.answers(append))
        // The provider's params are read, never the normalised state beside them.
        #expect(whole.sender == .set("sender-alpha-v2") && whole.content == .set("text") && whole.messageID == "alpha")
    }

    /// The captured v2 frame: the service keeps each message's updates in one message, with its
    /// references in the order sent. Alpha and beta are interleaved on the wire.
    @Test func aCoalescedV2MessageIsOneQuoteWhereItsEntrySits() throws {
        let messages = [
            try prose(1, "ACP activity fixture; execute nothing", role: "user"), try prose(4, "BEFORE_V2_SESSION_MESSAGE_QA"),
            try grouped(5, [v2Reference(5, "alpha", "replace"), v2Reference(7, "alpha", "append")],
                        text: "ALPHA_SNAPSHOT_V2_QA ALPHA_FRAGMENT_V2_QA"),
            try grouped(6, [v2Reference(6, "beta", "replace"), v2Reference(8, "beta", "replace")], text: "BETA_FINAL_V2_QA"),
            try prose(9, "AFTER_V2_SESSION_MESSAGE_QA")
        ]
        let records = [
            v2Record(5, snapshot("alpha", #""senderSessionId":"sender-alpha-v2","recipientSessionId":"s-1","# + content("ALPHA_SNAPSHOT_V2_QA"))),
            v2Record(6, snapshot("beta", #""senderSessionId":"sender-beta-v2","# + content("BETA_OLD_V2_QA"))),
            v2Record(7, piece("alpha", " ALPHA_FRAGMENT_V2_QA")),
            v2Record(8, snapshot("beta", #""senderSessionId":null,"# + content("BETA_FINAL_V2_QA")))
        ]
        let found = marks(messages)
        #expect(found.map(\.cursor) == [5, 7, 6, 8].map { "\(epoch).\($0)" })
        #expect(found.map(\.kind) == [.snapshot, .chunk, .snapshot, .snapshot])
        let details = try read(messages, records)
        let items = pretty(messages, details)
        #expect(items.map(\.id) == ["w:1", "w:4", "w:5#message", "w:6#message", "w:9"])
        let rows = drawn(items)
        #expect(rows.map(\.sender) == ["sender-alpha-v2", nil])
        #expect(rows.map(\.text) == ["ALPHA_SNAPSHOT_V2_QA ALPHA_FRAGMENT_V2_QA", "BETA_FINAL_V2_QA"])
        #expect(SessionMessageWords(message: rows[1], hidesSecrets: true).heading == "Message from another session")
        // Two cursors, one entry: it is listed once.
        #expect(rows.map { $0.entries.map(\.id) } == [["w:5"], ["w:6"]])

        // The second reference still being read: the first is drawn, and the entry keeps its place.
        var waiting = details
        waiting[found[1]] = .awaited
        #expect(drawn(pretty(messages, waiting)).map(\.text) == ["ALPHA_SNAPSHOT_V2_QA", "BETA_FINAL_V2_QA"])
        #expect(pretty(messages, waiting).map(\.id) == items.map(\.id))
        // One reference expired: none of that entry's is applied, and the preview is not echoed.
        var expired = details
        expired[found[0]] = .missing
        let fallback = pretty(messages, expired)
        #expect(drawn(fallback).map(\.messageID) == ["beta"])
        #expect(folded(fallback) == ["w:5"] && foldedWords(fallback) == ["Session message"])
        // With no records at all, both keep the neutral line.
        #expect(foldedWords(pretty(messages)) == ["Session message", "Session message"])
    }

    @Test func aGroupThatIsNotOneMessageOfOneSessionStaysTheFallback() throws {
        func items(_ references: [String], latest: String? = nil, _ records: [String]) throws -> [PrettyItem] {
            let messages = [try grouped(5, references, latest: latest, text: "PREVIEW_OF_THE_GROUP")]
            return pretty(messages, try read(messages, records))
        }
        let alpha = [
            v2Record(5, snapshot("alpha", #""senderSessionId":"sender-alpha-v2","# + content("one"))),
            v2Record(7, piece("alpha", " two"))
        ]
        func isFallback(_ items: [PrettyItem]) -> Bool {
            drawn(items).isEmpty && foldedWords(items) == ["Session message"]
        }
        // The same group, whole: one quote.
        #expect(drawn(try items([v2Reference(5, "alpha", "replace"), v2Reference(7, "alpha", "append")], alpha)).map(\.text) == ["one two"])
        // A reference of another message in the list.
        #expect(isFallback(try items([v2Reference(5, "alpha", "replace"), v2Reference(7, "beta", "append")],
                                     [alpha[0], v2Record(7, piece("beta", " two"))])))
        // A reference that is not a session message update, or names no cursor.
        #expect(isFallback(try items([v2Reference(5, "alpha", "replace"), v2Reference(7, "alpha", "append", kind: "agent_message")],
                                     latest: v2Reference(5, "alpha", "replace"), alpha)))
        #expect(isFallback(try items([v2Reference(5, "alpha", "replace"), #"{"source":"live","kind":"session_message","messageId":"alpha","messageOp":"append","contentType":"text"}"#],
                                     latest: v2Reference(5, "alpha", "replace"), alpha)))
        // The latest reference is not in the list.
        #expect(isFallback(try items([v2Reference(5, "alpha", "replace"), v2Reference(7, "alpha", "append")],
                                     latest: v2Reference(9, "alpha", "append"), alpha)))
        // The records name two sessions.
        #expect(isFallback(try items([v2Reference(5, "alpha", "replace"), v2Reference(7, "alpha", "append")],
                                     [alpha[0], v2Record(7, piece("alpha", " two"), session: "s-2")])))
        // An append whose record is a snapshot, and a record of another message at the cursor.
        #expect(isFallback(try items([v2Reference(5, "alpha", "replace"), v2Reference(7, "alpha", "append")],
                                     [alpha[0], v2Record(7, snapshot("alpha", content("two")))])))
        #expect(isFallback(try items([v2Reference(5, "alpha", "replace"), v2Reference(7, "alpha", "append")],
                                     [alpha[0], v2Record(7, piece("other", " two"))])))
    }

    @Test func aV2MessageThisSessionSentIsNotDrawnAsIncoming() throws {
        let messages = [try grouped(5, [v2Reference(5, "mine", "replace"), v2Reference(6, "mine", "append")], text: "OUTGOING_ONLY_QA MORE")]
        let records = [
            v2Record(5, snapshot("mine", #""senderSessionId":"s-1","recipientSessionId":"paired-session","# + content("OUTGOING_ONLY_QA"))),
            v2Record(6, piece("mine", " MORE"))
        ]
        let items = pretty(messages, try read(messages, records))
        #expect(drawn(items).isEmpty && foldedWords(items) == ["Session message"])
    }

    // MARK: Console

    @Test func consoleKeepsTheServicesText() throws {
        let messages = [try prose(2, "Before."), try event(3, "m"), try event(4, "m", chunk: "FIRST"), try prose(5, "After.")]
        let console = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .console)
        #expect(console.map(\.id) == ["w:2", "w:3", "w:4", "w:5"])
        #expect(console.map(\.plainText) == ["Before.", "[ACP session_message]", "[ACP session_message_chunk] FIRST", "After."])
    }

    // MARK: The store

    @Test @MainActor func oneReadServesEveryUpdateOfATurnAndALaterOneStartsWhereItStopped() async throws {
        let reads = Reads()
        let first = [try event(2, "m"), try event(3, "m", chunk: "x")]
        let later = first + [try event(4, "m", chunk: "y")]
        let pages: [String?: SourcePage] = [
            nil: try page([record(1, piece("other", "x")), record(2, snapshot("m", content("one")))], next: "w.e.2"),
            "w.e.2": try page([record(3, piece("m", " two")), record(4, piece("m", " three"))])
        ]
        let store = SessionMessageStore(read: { _, turn, cursor in
            try await reads.record(turn, cursor)
            return pages[cursor] ?? SourcePage(observations: [], nextCursor: nil)
        }, pause: { await reads.paused() })

        await store.load(worker: "w", marks: marks(first))
        #expect(await reads.cursors == [nil, "w.e.2"])
        #expect(await reads.turns == ["op-7", "op-7"])
        for mark in marks(first) {
            guard case .patch(let patch)? = store.detail(worker: "w", mark: mark) else { Issue.record("not read"); continue }
            #expect(patch.answers(mark))
        }
        // The record of the next update was already passed: nothing is asked for.
        await store.load(worker: "w", marks: marks(later))
        #expect(await reads.cursors == [nil, "w.e.2"])
        guard case .patch? = store.detail(worker: "w", mark: marks(later)[2]) else { Issue.record("not kept"); return }
        // Another worker's reference at the same cursor is not answered from this worker's read.
        #expect(store.detail(worker: "other", mark: marks(first)[0]) == .awaited)

        // An update whose record is new is read from the last page on, not from the first.
        let newest = later + [try event(5, "m", chunk: "z")]
        await store.load(worker: "w", marks: marks(newest))
        #expect(await reads.cursors == [nil, "w.e.2", "w.e.2", "w.e.2"])
        #expect(await reads.pauses == 1)
        #expect(store.detail(worker: "w", mark: marks(newest)[3]) == .missing)
        // Counted as missing, it is not asked for again.
        await store.load(worker: "w", marks: marks(newest))
        #expect(await reads.cursors.count == 4)
    }

    @Test @MainActor func aRecordThatArrivesAfterItsEventIsFoundByTheOneFurtherRead() async throws {
        let reads = Reads()
        let messages = [try event(2, "m", turn: nil)]
        let late = try page([record(2, snapshot("m", content("one")), turn: "")])
        let store = SessionMessageStore(read: { _, turn, cursor in
            try await reads.record(turn, cursor)
            return await reads.cursors.count == 1 ? SourcePage(observations: [], nextCursor: nil) : late
        }, pause: { await reads.paused() })
        await store.load(worker: "w", marks: marks(messages))
        // Outside a turn the read is not narrowed to one.
        #expect(await reads.turns == [nil, nil])
        #expect(await reads.pauses == 1)
        guard case .patch(let patch)? = store.detail(worker: "w", mark: marks(messages)[0]) else {
            Issue.record("not read"); return
        }
        #expect(patch.content == .set("one"))
    }

    @Test @MainActor func aFailedReadIsNotCountedAsMissingAndAsksAgain() async throws {
        let reads = Reads()
        let messages = [try event(2, "m")]
        let found = try page([record(2, snapshot("m", content("one")))])
        let store = SessionMessageStore(read: { _, turn, cursor in
            try await reads.record(turn, cursor)
            return found
        }, pause: { await reads.paused() })
        await reads.fail(true)
        await store.load(worker: "w", marks: marks(messages))
        // Nothing is known: the update keeps the fallback and is not held as awaited.
        #expect(store.detail(worker: "w", mark: marks(messages)[0]) == nil)
        await reads.fail(false)
        await store.load(worker: "w", marks: marks(messages))
        guard case .patch? = store.detail(worker: "w", mark: marks(messages)[0]) else { Issue.record("not read"); return }
        #expect(await reads.cursors.count == 2)
    }

    @Test @MainActor func twoDifferentRecordsAtOneCursorAndARecordOfAnotherKindNameNothing() async throws {
        let messages = [try event(2, "m"), try event(3, "m", chunk: "x")]
        let store = SessionMessageStore(read: { _, _, _ in
            try page([
                record(2, snapshot("m", content("one"))), record(2, snapshot("m", content("two"))),
                record(3, #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}"#)
            ])
        }, pause: {})
        await store.load(worker: "w", marks: marks(messages))
        #expect(store.detail(worker: "w", mark: marks(messages)[0]) == .missing)
        #expect(store.detail(worker: "w", mark: marks(messages)[1]) == .missing)
    }

    @Test @MainActor func aChangeOfServiceDropsWhatTheLastOneHeld() async throws {
        let reads = Reads()
        let messages = [try event(2, "m")]
        let found = try page([record(2, snapshot("m", content("one")))])
        let store = SessionMessageStore(read: { _, turn, cursor in
            try await reads.record(turn, cursor)
            return found
        }, pause: {})
        await store.load(worker: "w", marks: marks(messages))
        store.serviceChanged()
        #expect(store.detail(worker: "w", mark: marks(messages)[0]) == .awaited)
        await store.load(worker: "w", marks: marks(messages))
        #expect(await reads.cursors == [nil, nil])
        guard case .patch? = store.detail(worker: "w", mark: marks(messages)[0]) else { Issue.record("not read"); return }
    }
}
