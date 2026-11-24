import Foundation
import Testing
@testable import AgentCommander

// A prompt recovered from Claude or Codex history opens its media from its own chat message. The
// message names the one provider record that owns the prompt; the panel reads that record alone
// and decodes the prompt's top-level image and audio parts from it. These cover the reference,
// the request, the answer's identity checks, both providers' record shapes as the service's
// provider projector recognizes them, and the read's cancellation, with synthetic records in
// place of the service. No real transcript is used.

private let boundSession = NativeSession(harnessInstance: "fixture-harness", sessionID: "s-1")

private func userMessage(_ id: String = "m1", acp: String?, content: String = #""compare these""#) throws -> AGUIMessage {
    let metadata = acp.map { #","metadata":{"acp":\#($0)}"# } ?? ""
    return try AGUIMessage(fields: AGUIValue(json: #"{"id":"\#(id)","role":"user","content":\#(content)\#(metadata)}"#))
}

/// The provider reference of a recovered prompt. Historical Claude prompts often carry no turn.
private func providerACP(cursor: String = "rec-1", page: String? = nil, turn: String? = nil,
                         contentType: String = "mixed", count: Int = 2) -> String {
    var members = [#""source":"provider""#, #""kind":"provider_prompt_media""#, #""cursor":"\#(cursor)""#,
                   #""contentType":"\#(contentType)""#, #""itemCount":\#(count)"#]
    if let page { members.append(#""pageCursor":"\#(page)""#) }
    if let turn { members.append(#""turnId":"\#(turn)""#) }
    return "{" + members.joined(separator: ",") + "}"
}

private func providerReference(cursor: String = "rec-1", page: String? = nil, turn: String? = nil,
                               count: Int = 2, session: NativeSession? = boundSession) throws -> PromptAttachmentReference {
    try #require(PromptAttachmentReference(workerID: "w", message: userMessage(acp: providerACP(
        cursor: cursor, page: page, turn: turn, count: count)), session: session))
}

private let claudeType = "claude.history.message"
private let codexType = "codex.history.item"

/// One SDK observation whose original provider record is `owner`, base64 in `sourceRecord`.
/// An owner names itself as its `sourceCursor`, as the service writes it.
private func observation(cursor: String = "rec-1", sourceCursor: String? = nil, turn: String? = nil,
                         harness: String = "fixture-harness", sessionID: String = "s-1",
                         recordType: String = claudeType, owner: String) -> [String: Any] {
    var item: [String: Any] = [
        "session": ["harnessInstance": harness, "sessionId": sessionID],
        "cursor": cursor,
        "sourceCursor": sourceCursor ?? cursor,
        "text": ["speaker": "user", "text": "compare these"],
        "sourceRecord": ["type": recordType, "mediaType": "application/json",
                         "data": Data(owner.utf8).base64EncodedString()]
    ]
    if let turn { item["turnId"] = turn }
    return item
}

private func gapObservation(cursor: String? = "rec-1", harness: String = "fixture-harness",
                            reason: String = "the record is no longer in provider history") -> [String: Any] {
    var item: [String: Any] = ["session": ["harnessInstance": harness, "sessionId": "s-1"], "gap": ["reason": reason]]
    if let cursor { item["cursor"] = cursor }
    return item
}

private func sourcePage(_ observations: [[String: Any]], next: String? = nil) throws -> SourcePage {
    var envelope: [String: Any] = ["observations": observations]
    if let next { envelope["nextCursor"] = next }
    return try SourcePage(envelope: JSONSerialization.data(withJSONObject: envelope))
}

private func decode(_ page: SourcePage, _ reference: PromptAttachmentReference) throws -> [PromptAttachmentItem] {
    try ProviderPromptMedia.items(of: page, for: reference)
}

private func reason(_ body: PromptAttachmentItem.Body) -> String? {
    switch body {
    case .unavailable(_, _, let reason), .undecodable(let reason): reason
    case .media, .record: nil
    }
}

// Bytes [1,2,3] = AQID, [7,8,9] = BwgJ, [0xFF,0xD8,0xFF] = /9j/.

/// A Claude user record: media first, a text block, a repeated image with identical bytes, audio,
/// an external image link, a block type Claude does not use for prompt media, and an image
/// nested in a tool result. The last two are not prompt parts.
private let claudeMixed = #"""
{"type":"user","uuid":"u-1","message":{"role":"user","content":[
 {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AQID"}},
 {"type":"text","text":"compare these"},
 {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AQID"}},
 {"type":"audio","source":{"type":"base64","media_type":"audio/wav","data":"BwgJ"}},
 {"type":"image","source":{"type":"url","url":"https://example.invalid/chart.png"}},
 {"type":"localImage","path":"/tmp/not-a-claude-part.png"},
 {"type":"tool_result","tool_use_id":"t-1","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]}
]}}
"""#

/// A Codex user message: a data-URL image first, a local file, an external link, data-URL
/// audio, an input type the projector does not count, then text.
private let codexMixed = #"""
{"type":"userMessage","id":"item-1","content":[
 {"type":"image","url":"data:image/jpeg;base64,/9j/"},
 {"type":"localImage","path":"/tmp/fixture-screenshot.png"},
 {"type":"image","url":"https://example.invalid/diagram.png"},
 {"type":"audio","url":"data:audio/wav;base64,BwgJ"},
 {"type":"input_image","image_url":"data:image/png;base64,AQID"},
 {"type":"text","text":"why does this differ?"}
]}
"""#

@Suite struct ProviderPromptReferenceTests {
    @Test func readsTheProviderReferenceWithoutATurn() throws {
        let reference = try providerReference(page: "page-3")
        #expect(reference.origin == .provider)
        #expect(reference.firstCursor == "rec-1")
        #expect(reference.pageCursor == "page-3")
        #expect(reference.turnID.isEmpty)
        #expect(reference.contentType == "mixed")
        #expect(reference.itemCount == 2)
        #expect(reference.session == boundSession)
        #expect(reference.provenance == "Provider history")
    }

    @Test func anAbsentPageHintReadsTheFirstPage() throws {
        #expect(try providerReference().pageCursor == nil)
    }

    @Test func aLiveReferenceKeepsItsOwnProvenance() throws {
        let live = #"{"source":"live","kind":"acp.prompt_part","turnId":"op-7","itemCount":1}"#
        let reference = try #require(PromptAttachmentReference(workerID: "w", message: userMessage(acp: live),
                                                               session: boundSession))
        #expect(reference.origin == .live)
        #expect(reference.session == nil)
        #expect(reference.provenance == "Live ACP source")
    }

    @Test(arguments: [
        #"{"source":"provider","kind":"provider_prompt_media","contentType":"image"}"#,
        #"{"source":"provider","kind":"provider_prompt_media","cursor":"","contentType":"image"}"#,
        #"{"source":"provider","kind":"provider_prompt_media","cursor":"rec-1"}"#,
        #"{"source":"provider","kind":"provider_prompt_media","cursor":"rec-1","contentType":"video"}"#,
        #"{"source":"provider","kind":"provider_prompt_media","cursor":"rec-1","contentType":"image","itemCount":0}"#,
        #"{"source":"live","kind":"provider_prompt_media","cursor":"rec-1","contentType":"image"}"#,
        #"{"source":"provider","kind":"acp.prompt_part","cursor":"rec-1","contentType":"image","turnId":"op-1"}"#
    ])
    func refusesAnythingElse(acp: String) throws {
        #expect(try PromptAttachmentReference(workerID: "w", message: userMessage(acp: acp)) == nil)
    }

    @Test func bothModesOfferThePromptItselfIncludingMediaOnly() throws {
        let messages = [
            try userMessage("recovered", acp: providerACP()),
            try userMessage("live", acp: #"{"source":"live","kind":"acp.prompt_part","turnId":"op-7","itemCount":1}"#),
            // A prompt that was only media: the service writes a placeholder, or nothing.
            try userMessage("media-only", acp: providerACP(cursor: "rec-2", contentType: "image", count: 1),
                            content: #""[Attachment]""#),
            try userMessage("no-text", acp: providerACP(cursor: "rec-3", contentType: "audio", count: 1), content: #""""#)
        ]
        func offer(_ id: String) -> PromptAttachmentOffer? {
            PromptAttachmentOffer.resolve(workerID: "w", entryID: id, messages: messages, hasSource: true,
                                          session: boundSession)
        }
        guard case .prompt(let recovered)? = offer("recovered"), case .prompt(let live)? = offer("live"),
              case .prompt(let mediaOnly)? = offer("media-only"), case .prompt(let noText)? = offer("no-text") else {
            Issue.record("each prompt offers its own media")
            return
        }
        #expect(recovered.origin == .provider)
        #expect(live.origin == .live)
        #expect(mediaOnly.firstCursor == "rec-2")
        #expect(noText.firstCursor == "rec-3")
        #expect(offer("recovered")?.title == "View 2 attachments")
        #expect(offer("media-only")?.title == "View attachment")
    }

    @Test func aRecoveredPromptKeepsTextThatLooksLikeAMarker() throws {
        // The provider projector writes no service markers, so a developer's own trailing
        // "[ACP image]" is their text and stays.
        let acp = try #require(AGUIValue(json: providerACP(contentType: "image", count: 1)).objectValue)
        #expect(PromptMediaIndicator(acp: acp) == nil)
        let message = try userMessage(acp: providerACP(contentType: "image", count: 1),
                                      content: #""see this [ACP image] image/png""#)
        let entry = try #require(TranscriptEntry.entries(from: [message]).first)
        #expect(entry.promptMedia == nil)
        #expect(entry.kind == .prose("see this [ACP image] image/png", fromUser: true))
    }
}

@Suite struct ProviderPromptRequestTests {
    @Test func namesOnlyTheRecordAndItsPage() {
        let path = ServiceClient.recordPath("run 1/w&2", recordCursor: "claude:u-1/0?x=1", pageCursor: "page 3+")
        #expect(path == "/v1/workers/run%201%2Fw%262/history?recordCursor=claude%3Au-1%2F0%3Fx%3D1&cursor=page%203%2B")
    }

    @Test func withoutAPageHintItStartsAtTheFirstPage() {
        let path = ServiceClient.recordPath("w", recordCursor: "rec-1")
        #expect(path == "/v1/workers/w/history?recordCursor=rec-1")
        for omitted in ["source=", "kind=", "turnId=", "view=", "limit=", "&cursor="] {
            #expect(!path.contains(omitted))
        }
    }
}

@Suite struct ProviderPromptDecodingTests {
    @Test func decodesClaudesTopLevelPartsInOrderWithRepeats() throws {
        let items = try decode(sourcePage([observation(owner: claudeMixed)]), providerReference(count: 4))
        #expect(items.count == 4)
        #expect(items[0].body == .media(type: "image", mimeType: "image/png", data: Data([1, 2, 3])))
        #expect(items[1].body == .media(type: "image", mimeType: "image/png", data: Data([1, 2, 3])))
        #expect(items[2].body == .media(type: "audio", mimeType: "audio/wav", data: Data([7, 8, 9])))
        guard case .unavailable("image", "", let why) = items[3].body else {
            Issue.record("an external image link is stated, not followed")
            return
        }
        #expect(why.contains("does not follow links"))
        // Identical bytes are still two parts, each with its own ID and its own fields.
        #expect(Set(items.map(\.id)).count == 4)
        #expect(items.allSatisfy { $0.decodedTitle == ProviderPromptMedia.partTitle })
        #expect(items[3].decoded?.contains("https://example.invalid/chart.png") == true)
        #expect(items.allSatisfy { $0.observation.cursor == "rec-1" })
        // The original record stays whole for the fields view.
        #expect(items[0].observation.record.contains(claudeType))
    }

    @Test func decodesCodexInputsMediaFirst() throws {
        let items = try decode(sourcePage([observation(turn: "turn-4", recordType: codexType, owner: codexMixed)]),
                               providerReference(turn: "turn-4", count: 4))
        #expect(items.count == 4)
        #expect(items[0].body == .media(type: "image", mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF])))
        guard case .unavailable("image", "", let local) = items[1].body,
              case .unavailable("image", "", let link) = items[2].body else {
            Issue.record("a local file and a link are stated, not read")
            return
        }
        #expect(local.contains("local files"))
        #expect(link.contains("does not follow links"))
        #expect(items[1].decoded?.contains("/tmp/fixture-screenshot.png") == true)
        #expect(items[3].body == .media(type: "audio", mimeType: "audio/wav", data: Data([7, 8, 9])))
    }

    @Test func aMediaOnlyPromptHasOnlyItsParts() throws {
        let owner = #"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/gif","data":"AQID"}}]}}"#
        let items = try decode(sourcePage([observation(owner: owner)]), providerReference(count: 1))
        #expect(items.map(\.body) == [.media(type: "image", mimeType: "image/gif", data: Data([1, 2, 3]))])
    }

    @Test func statesWhyARecordIsNotDecoded() throws {
        let cases: [(type: String, owner: String, says: String)] = [
            (claudeType, #"{"type":"assistant","message":{"content":[]}}"#, "Claude record is not a user message"),
            (codexType, #"{"type":"user","message":{"content":[]}}"#, "Codex record is not a user message"),
            (claudeType, #"{"type":"user","message":{"content":"text only"}}"#, "no image or audio part"),
            (codexType, #"{"type":"userMessage"}"#, "no content list"),
            (claudeType, #"[1,2]"#, "not a JSON object"),
            ("provider.other", #"{"type":"user"}"#, "not a Claude or Codex history record")
        ]
        for (type, owner, says) in cases {
            let items = try decode(sourcePage([observation(recordType: type, owner: owner)]), providerReference())
            #expect(items.count == 1)
            #expect(reason(items[0].body)?.contains(says) == true, "\(type) \(owner)")
            #expect(!items[0].isPart)
        }

        var notBase64 = observation(owner: "{}")
        notBase64["sourceRecord"] = ["type": claudeType, "mediaType": "application/json", "data": "***"]
        #expect(try reason(decode(sourcePage([notBase64]), providerReference())[0].body)?.contains("not valid base64") == true)

        // Only `sourceRecord` is the owner's original; an `extension` is not read in its place.
        var extensionOnly = observation(owner: claudeMixed)
        extensionOnly["extension"] = extensionOnly.removeValue(forKey: "sourceRecord")
        #expect(try reason(decode(sourcePage([extensionOnly]), providerReference())[0].body)?.contains("no original provider record") == true)
    }

    @Test func describesMalformedMissingOrEmptyPartData() throws {
        let owner = #"""
        {"type":"user","message":{"content":[
         {"type":"image","source":{"type":"base64","media_type":"image/png","data":"***"}},
         {"type":"image","source":{"type":"base64","media_type":"image/png"}},
         {"type":"image","source":{"type":"base64","media_type":"image/png","data":""}},
         {"type":"image","source":{"type":"base64","data":"AQID"}},
         {"type":"image","source":{"type":"file","file_id":"file-1"}},
         {"type":"audio"}
        ]}}
        """#
        let items = try decode(sourcePage([observation(owner: owner)]), providerReference(count: 6))
        #expect(items.count == 6)
        #expect(items[0].body == .media(type: "image", mimeType: "image/png", data: nil))
        #expect(items[1].body == .unavailable(type: "image", mimeType: "image/png",
                                              reason: "It declares inline base64 data but carries none."))
        // An explicitly empty payload is not the same as a missing one.
        #expect(items[2].body == .media(type: "image", mimeType: "image/png", data: Data()))
        #expect(reason(items[3].body)?.contains("no media type") == true)
        #expect(reason(items[4].body)?.contains("stores by ID") == true)
        #expect(reason(items[5].body)?.contains("no source") == true)
        let allAreParts = items.allSatisfy { $0.isPart }
        #expect(allAreParts)
    }

    @Test func describesMalformedCodexInputs() throws {
        let owner = #"""
        {"type":"userMessage","content":[
         {"type":"image","url":"data:image/png;base64"},
         {"type":"image","url":"data:image/png,AQID"},
         {"type":"image","url":"data:;base64,AQID"},
         {"type":"audio"},
         {"type":"localImage"}
        ]}
        """#
        let items = try decode(sourcePage([observation(recordType: codexType, owner: owner)]), providerReference(count: 5))
        #expect(items.count == 5)
        #expect(reason(items[0].body)?.contains("no data section") == true)
        #expect(reason(items[1].body)?.contains("not base64") == true)
        #expect(reason(items[2].body)?.contains("no media type") == true)
        #expect(reason(items[3].body)?.contains("no URL") == true)
        #expect(reason(items[4].body)?.contains("no path") == true)
    }
}

@Suite struct ProviderPromptIdentityTests {
    @Test func aRecordAtAnotherCursorFailsTheRead() throws {
        let page = try sourcePage([observation(cursor: "rec-9", owner: claudeMixed)])
        let reference = try providerReference()
        #expect(throws: PromptAttachmentError.otherRecord("rec-9")) { try decode(page, reference) }
    }

    @Test func aSiblingOfAnotherOwnerFailsTheRead() throws {
        let page = try sourcePage([observation(sourceCursor: "rec-0", owner: claudeMixed)])
        let reference = try providerReference()
        #expect(throws: PromptAttachmentError.siblingRecord("rec-0")) { try decode(page, reference) }
    }

    @Test func noRecordOrSeveralFailTheRead() throws {
        let reference = try providerReference()
        let empty = try sourcePage([])
        let two = try sourcePage([observation(owner: claudeMixed), observation(owner: claudeMixed)])
        #expect(throws: PromptAttachmentError.recordCount(0)) { try decode(empty, reference) }
        #expect(throws: PromptAttachmentError.recordCount(2)) { try decode(two, reference) }
    }

    @Test func aMatchingRecordWithAFurtherPageFails() throws {
        let page = try sourcePage([observation(owner: claudeMixed)], next: "elsewhere")
        let reference = try providerReference()
        #expect(throws: PromptAttachmentError.furtherPage) { try decode(page, reference) }
    }

    @Test func aKnownSessionMustBeNamedExactly() throws {
        let reference = try providerReference()
        let otherSession = try sourcePage([observation(sessionID: "s-2", owner: claudeMixed)])
        let otherHarness = try sourcePage([observation(harness: "other-harness", owner: claudeMixed)])
        let noHarness = try sourcePage([observation(harness: "", owner: claudeMixed)])
        var unnamed = observation(owner: claudeMixed)
        unnamed.removeValue(forKey: "session")
        let noSession = try sourcePage([unnamed])
        #expect(throws: PromptAttachmentError.otherSession("fixture-harness · s-2")) { try decode(otherSession, reference) }
        #expect(throws: PromptAttachmentError.otherSession("other-harness · s-1")) { try decode(otherHarness, reference) }
        #expect(throws: PromptAttachmentError.otherSession("no harness · s-1")) { try decode(noHarness, reference) }
        #expect(throws: PromptAttachmentError.otherSession("none stated")) { try decode(noSession, reference) }
        // Without a known session there is nothing to compare.
        #expect(try decode(otherSession, providerReference(session: nil)).count == 4)
    }

    @Test func aRecordOfAnotherTurnFailsTheRead() throws {
        let otherTurn = try sourcePage([observation(turn: "turn-5", recordType: codexType, owner: codexMixed)])
        #expect(throws: PromptAttachmentError.foreignTurn("turn-5")) { try decode(otherTurn, providerReference(turn: "turn-4")) }
        // A reference without a turn accepts the record's own turn.
        #expect(try decode(otherTurn, providerReference()).count == 4)
    }

    @Test func oneGapIsShownAsTheSourceStatesIt() throws {
        let items = try decode(sourcePage([gapObservation()]), providerReference())
        #expect(items.count == 1)
        #expect(items[0].body == .record)
        #expect(items[0].observation.body == .gap(reason: "the record is no longer in provider history"))
        #expect(try decode(sourcePage([gapObservation(cursor: nil)]), providerReference()).count == 1)
    }

    @Test func aGapWithMorePagesForAnotherRecordOrSessionFails() throws {
        let reference = try providerReference()
        let withMore = try sourcePage([gapObservation()], next: "more")
        let elsewhere = try sourcePage([gapObservation(cursor: "rec-9")])
        let otherHarness = try sourcePage([gapObservation(harness: "other-harness")])
        #expect(throws: PromptAttachmentError.furtherPage) { try decode(withMore, reference) }
        #expect(throws: PromptAttachmentError.otherRecord("rec-9")) { try decode(elsewhere, reference) }
        #expect(throws: PromptAttachmentError.otherSession("other-harness · s-1")) { try decode(otherHarness, reference) }
    }
}

/// A loader that answers provider reads from a script, or stalls until cancelled.
private actor RecordLoader {
    struct Call: Equatable, Sendable {
        let reference: PromptAttachmentReference
        let cursor: String?
    }

    private(set) var calls: [Call] = []
    private(set) var cancelled = 0
    private var script: [Result<SourcePage, Error>]
    private let stalls: Bool

    init(_ script: [Result<SourcePage, Error>] = [], stalls: Bool = false) {
        self.script = script
        self.stalls = stalls
    }

    func load(_ reference: PromptAttachmentReference, _ cursor: String?) async throws -> SourcePage {
        calls.append(Call(reference: reference, cursor: cursor))
        if stalls {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled += 1
                throw error
            }
        }
        return try script.removeFirst().get()
    }
}

@Suite @MainActor struct ProviderPromptModelTests {
    @Test func readsTheOneRecordAndNeverPages() async throws {
        let loader = RecordLoader([.success(try sourcePage([observation(owner: claudeMixed)]))])
        let model = PromptAttachmentModel { reference, cursor in try await loader.load(reference, cursor) }
        let reference = try providerReference(page: "page-3", count: 4)
        model.open(reference)
        #expect(model.inspection?.phase == .loading)
        await model.task?.value

        let inspection = try #require(model.inspection)
        #expect(inspection.phase == .loaded)
        #expect(inspection.items.count == 4)
        #expect(inspection.partCount == 4)
        #expect(inspection.mediaCount == 3)
        #expect(inspection.nextCursor == nil)
        model.loadMore()
        #expect(model.inspection?.isLoadingMore == false)
        #expect(await loader.calls == [RecordLoader.Call(reference: reference, cursor: nil)])
    }

    @Test func aFurtherPageFailsClosedWithNothingShown() async throws {
        let loader = RecordLoader([.success(try sourcePage([observation(owner: claudeMixed)], next: "elsewhere"))])
        let model = PromptAttachmentModel { reference, cursor in try await loader.load(reference, cursor) }
        model.open(try providerReference())
        await model.task?.value
        #expect(model.inspection?.items.isEmpty == true)
        #expect(model.inspection?.phase == .failed(PromptAttachmentError.furtherPage.localizedDescription))
        #expect(await loader.calls.count == 1)
    }

    @Test func aWrongRecordIsAFailureWithNothingShown() async throws {
        let loader = RecordLoader([.success(try sourcePage([observation(cursor: "rec-9", owner: claudeMixed)]))])
        let model = PromptAttachmentModel { reference, cursor in try await loader.load(reference, cursor) }
        model.open(try providerReference())
        await model.task?.value
        #expect(model.inspection?.items.isEmpty == true)
        #expect(model.inspection?.phase == .failed(PromptAttachmentError.otherRecord("rec-9").localizedDescription))
    }

    @Test func aStaleAnswerIsDroppedWhenAnotherPromptOpens() async throws {
        let stalled = RecordLoader(stalls: true)
        let answered = RecordLoader([.success(try sourcePage([observation(cursor: "rec-2", recordType: codexType,
                                                                          owner: codexMixed)]))])
        let model = PromptAttachmentModel { reference, cursor in
            try await (reference.firstCursor == "rec-1" ? stalled : answered).load(reference, cursor)
        }
        model.open(try providerReference())
        let first = try #require(model.task)
        while await stalled.calls.isEmpty { await Task.yield() }

        let second = try providerReference(cursor: "rec-2", count: 4)
        model.open(second)
        await first.value
        await model.task?.value

        #expect(await stalled.cancelled == 1)
        #expect(model.inspection?.reference == second)
        #expect(model.inspection?.items.count == 4)
    }

    @Test func closingCancelsTheRead() async throws {
        let loader = RecordLoader(stalls: true)
        let model = PromptAttachmentModel { reference, cursor in try await loader.load(reference, cursor) }
        let reference = try providerReference()
        model.open(reference)
        let inFlight = try #require(model.task)
        while await loader.calls.isEmpty { await Task.yield() }
        model.close(reference)
        await inFlight.value
        #expect(await loader.cancelled == 1)
        #expect(model.inspection == nil)
    }
}
