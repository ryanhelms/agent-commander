import Foundation
import Testing
@testable import AgentCommander

// The attachments action reads one prompt's media by worker and turn. These cover the reference a
// message must carry, the request it becomes, and the read's paging and cancellation, with a
// scripted loader in place of the service.

private func message(_ id: String = "m1", role: String = "user", acp: String? = nil,
                     content: String = #""look at this""#) throws -> AGUIMessage {
    let metadata = acp.map { #","metadata":{"acp":\#($0)}"# } ?? ""
    return try AGUIMessage(fields: AGUIValue(json: #"{"id":"\#(id)","role":"\#(role)","content":\#(content)\#(metadata)}"#))
}

private let promptACP = #"{"source":"live","kind":"acp.prompt_part","turnId":"op-7","cursor":"prompt-op-7-1","contentType":"image","mimeType":"image/png","itemCount":2}"#

/// An observation as the service sends one prompt part: a JSON extension, base64 inside base64.
private func part(turn: String = "op-7", index: Int, type: String = "image", mime: String = "image/png",
                  bytes: [UInt8] = [1, 2, 3]) -> [String: Any] {
    let inner = #"{"type":"\#(type)","mimeType":"\#(mime)","data":"\#(Data(bytes).base64EncodedString())"}"#
    return ["turnId": turn, "cursor": "prompt-\(turn)-\(index)",
            "extension": ["type": "acp.prompt_part", "mediaType": "application/json",
                          "data": Data(inner.utf8).base64EncodedString()]]
}

private func page(_ observations: [[String: Any]], next: String? = nil) throws -> SourcePage {
    var envelope: [String: Any] = ["observations": observations]
    if let next { envelope["nextCursor"] = next }
    return try SourcePage(envelope: JSONSerialization.data(withJSONObject: envelope))
}

/// A loader that answers from a script and records what it was asked.
private actor ScriptedLoader {
    struct Call: Equatable {
        let workerID: String
        let turnID: String
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
        calls.append(Call(workerID: reference.workerID, turnID: reference.turnID, cursor: cursor))
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

@MainActor
private func model(_ loader: ScriptedLoader) -> PromptAttachmentModel {
    PromptAttachmentModel { reference, cursor in try await loader.load(reference, cursor) }
}

@Suite struct PromptAttachmentReferenceTests {
    @Test func readsTheExactReference() throws {
        let reference = try #require(PromptAttachmentReference(workerID: "w/1", message: message(acp: promptACP)))
        #expect(reference.workerID == "w/1")
        #expect(reference.turnID == "op-7")
        #expect(reference.firstCursor == "prompt-op-7-1")
        #expect(reference.contentType == "image")
        #expect(reference.mimeType == "image/png")
        #expect(reference.itemCount == 2)
    }

    @Test(arguments: [
        #"{"source":"provider","kind":"acp.prompt_part","turnId":"op-7"}"#,
        #"{"source":"live","kind":"acp.session_update","turnId":"op-7"}"#,
        #"{"source":"live","kind":"acp.prompt_part"}"#,
        #"{"source":"live","kind":"acp.prompt_part","turnId":""}"#,
        #"{"source":"live","kind":"acp.prompt_part","turnId":"op-7","cursor":"prompt-op-8-0"}"#,
        #"{"source":"live","kind":"acp.prompt_part","turnId":"op-7","itemCount":0}"#
    ])
    func refusesAnythingElse(acp: String) throws {
        #expect(try PromptAttachmentReference(workerID: "w", message: message(acp: acp)) == nil)
    }

    @Test func onlyAUserMessageOfANamedWorkerHasOne() throws {
        #expect(try PromptAttachmentReference(workerID: "w", message: message(role: "assistant", acp: promptACP)) == nil)
        #expect(try PromptAttachmentReference(workerID: "", message: message(acp: promptACP)) == nil)
    }

    @Test func offersThePromptThenTheSourceThenNothing() throws {
        let image = #"[{"type":"text","text":"see"},{"type":"image","mimeType":"image/png"},{"type":"audio","mimeType":"audio/wav"}]"#
        let messages = [try message("ref", acp: promptACP), try message("legacy", content: image),
                        try message("plain"), try message("agent", role: "assistant", acp: promptACP)]
        func offer(_ id: String, hasSource: Bool = true) -> PromptAttachmentOffer? {
            PromptAttachmentOffer.resolve(workerID: "w", entryID: id, messages: messages, hasSource: hasSource)
        }
        guard case .prompt(let reference)? = offer("ref") else {
            Issue.record("a referenced prompt offers its own media")
            return
        }
        #expect(reference.turnID == "op-7")
        #expect(offer("ref")?.title == "View 2 attachments")
        #expect(offer("legacy") == .workerSource(workerID: "w", count: 2))
        #expect(offer("legacy")?.title == "View 2 attachments in Source…")
        #expect(offer("legacy", hasSource: false) == nil)
        #expect(offer("plain") == nil)
        #expect(offer("agent") == nil)
        #expect(offer("missing") == nil)
    }
}

@Suite struct PromptAttachmentQueryTests {
    @Test func scopesTheRequestToWorkerTurnAndKind() {
        let path = ServiceClient.historyPath("run 1/w&2", source: .live, cursor: "prompt-op 7-3", limit: 4,
                                             turnID: "op/7?x=1", kind: PromptAttachmentReference.kind)
        #expect(path == "/v1/workers/run%201%2Fw%262/history?limit=4&source=live&turnId=op%2F7%3Fx%3D1&kind=acp.prompt_part&cursor=prompt-op%207-3")
    }

    @Test func leavesAnUnscopedRequestAsItWas() {
        #expect(ServiceClient.historyPath("w", source: .provider) == "/v1/workers/w/history?limit=12")
        #expect(ServiceClient.historyPath("w", source: .journal, cursor: "c") == "/v1/workers/w/history?limit=12&source=journal&cursor=c")
    }
}

@Suite @MainActor struct PromptAttachmentModelTests {
    private func reference(_ worker: String = "w", turn: String = "op-7") throws -> PromptAttachmentReference {
        let acp = #"{"source":"live","kind":"acp.prompt_part","turnId":"\#(turn)","itemCount":2}"#
        return try #require(PromptAttachmentReference(workerID: worker, message: message(acp: acp)))
    }

    @Test func decodesItemsInOrderAndPagesByTheIssuedCursor() async throws {
        let gap: [String: Any] = ["turnId": "op-7", "gap": ["reason": "evicted from the live window"]]
        let loader = ScriptedLoader([
            .success(try page([part(index: 1, bytes: [9, 8])], next: "next-1")),
            .success(try page([gap, part(index: 3, type: "audio", mime: "audio/wav", bytes: [7])]))
        ])
        let model = model(loader)
        model.open(try reference())
        #expect(model.inspection?.phase == .loading)
        await model.task?.value

        #expect(model.inspection?.phase == .loaded)
        #expect(model.inspection?.nextCursor == "next-1")
        #expect(model.inspection?.items.map(\.body) == [.media(type: "image", mimeType: "image/png", data: Data([9, 8]))])

        model.loadMore()
        #expect(model.inspection?.isLoadingMore == true)
        await model.task?.value

        let inspection = try #require(model.inspection)
        #expect(inspection.nextCursor == nil)
        #expect(inspection.items.map(\.body) == [
            .media(type: "image", mimeType: "image/png", data: Data([9, 8])),
            .record,
            .media(type: "audio", mimeType: "audio/wav", data: Data([7]))
        ])
        #expect(inspection.items[1].observation.body == .gap(reason: "evicted from the live window"))
        #expect(inspection.items.map(\.id) == ["prompt:0", "prompt:1", "prompt:2"])
        #expect(inspection.mediaCount == 2)
        #expect(await loader.calls == [.init(workerID: "w", turnID: "op-7", cursor: nil),
                                       .init(workerID: "w", turnID: "op-7", cursor: "next-1")])
    }

    @Test func aRecordOfAnotherTurnFailsThePage() async throws {
        let loader = ScriptedLoader([.success(try page([part(index: 0), part(turn: "op-8", index: 0)]))])
        let model = model(loader)
        model.open(try reference())
        await model.task?.value

        let inspection = try #require(model.inspection)
        #expect(inspection.items.isEmpty)
        #expect(inspection.phase == .failed(PromptAttachmentError.foreignTurn("op-8").localizedDescription))
    }

    @Test func aFailedPageKeepsWhatWasReadAndRetries() async throws {
        let loader = ScriptedLoader([
            .success(try page([part(index: 0)], next: "next-1")),
            .failure(ServiceError.rejected("history gap")),
            .success(try page([part(index: 1)]))
        ])
        let model = model(loader)
        model.open(try reference())
        await model.task?.value
        model.loadMore()
        await model.task?.value

        #expect(model.inspection?.pageError == ServiceError.rejected("history gap").localizedDescription)
        #expect(model.inspection?.items.count == 1)
        #expect(model.inspection?.nextCursor == "next-1")

        model.loadMore()
        await model.task?.value
        #expect(model.inspection?.pageError == nil)
        #expect(model.inspection?.items.count == 2)
        #expect(await loader.calls.map(\.cursor) == [nil, "next-1", "next-1"])
    }

    @Test func closingCancelsTheReadAndDropsItsAnswer() async throws {
        let loader = ScriptedLoader(stalls: true)
        let model = model(loader)
        let reference = try reference()
        model.open(reference)
        let inFlight = try #require(model.task)
        while await loader.calls.isEmpty { await Task.yield() }

        // A surface that shows another prompt cannot close this one.
        model.close(try self.reference("other"))
        #expect(model.inspection?.reference == reference)

        model.close(reference)
        #expect(model.inspection == nil)
        #expect(model.task == nil)
        await inFlight.value
        #expect(await loader.cancelled == 1)
        #expect(model.inspection == nil)
    }

    @Test func openingAnotherTurnAbandonsTheFirst() async throws {
        let stalled = ScriptedLoader(stalls: true)
        let answered = ScriptedLoader([.success(try page([part(turn: "op-9", index: 0)]))])
        let model = PromptAttachmentModel { reference, cursor in
            try await (reference.turnID == "op-7" ? stalled : answered).load(reference, cursor)
        }
        model.open(try reference())
        let first = try #require(model.task)
        while await stalled.calls.isEmpty { await Task.yield() }

        let second = try reference("w2", turn: "op-9")
        model.open(second)
        await first.value
        await model.task?.value

        #expect(await stalled.cancelled == 1)
        #expect(model.inspection?.reference == second)
        #expect(model.inspection?.items.count == 1)
        #expect(await answered.calls == [.init(workerID: "w2", turnID: "op-9", cursor: nil)])
    }

    @Test func statesWhyAnExtensionIsNotAPromptPart() throws {
        let plain: [String: Any] = ["turnId": "op-7", "extension": ["type": "x", "mediaType": "image/png", "data": "AQID"]]
        let wrongShape: [String: Any] = ["turnId": "op-7", "extension": [
            "type": "x", "mediaType": "application/json", "data": Data(#"{"type":"video"}"#.utf8).base64EncodedString()]]
        let badBytes: [String: Any] = ["turnId": "op-7", "extension": [
            "type": "x", "mediaType": "application/json",
            "data": Data(#"{"type":"image","mimeType":"image/png","data":"***"}"#.utf8).base64EncodedString()]]
        let items = try page([plain, wrongShape, badBytes]).observations.map(PromptAttachmentItem.init)

        guard case .undecodable = items[0].body, case .undecodable = items[1].body else {
            Issue.record("an extension that is not the agreed part is stated, not rendered")
            return
        }
        #expect(items[1].decoded == #"{"type":"video"}"#)
        #expect(items[2].body == .media(type: "image", mimeType: "image/png", data: nil))
    }
}
