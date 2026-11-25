import Foundation
import Testing
@testable import AgentCommander

// Structured requests from a worker's agent: the service's JSON, the typed form and its literal
// payload, the URL open rule, and the feature model's scope, replies and withdrawal, with a
// scripted service in place of the socket.

private let bound = NativeSession(harnessInstance: "h-1", sessionID: "s-1")
private let scope = ElicitationScope(workerID: "w-1", session: bound)

private func object(_ json: String) throws -> AGUIValue { try AGUIValue(json: json) }

private func form(_ id: String = "e-form", worker: String = "w-1", session: NativeSession = bound,
                  schema: String = #"{"type":"object","properties":{"name":{"type":"string"}}}"#) throws -> Elicitation {
    Elicitation(id: id, workerID: worker, session: session, mode: .form, message: "Who?",
                requestedSchema: try object(schema))
}

private func link(_ id: String = "e-url", url: String = "https://auth.example.com/login?x=1",
                  host: String = "auth.example.com") -> Elicitation {
    Elicitation(id: id, workerID: "w-1", session: bound, mode: .url, message: "Sign in",
                url: url, urlHost: host)
}

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// A service that answers from scripts and records what it was asked.
private actor ScriptedService {
    struct Reply: Equatable {
        let workerID: String
        let id: String
        let body: String
    }

    private(set) var lists: [String] = []
    private(set) var replies: [Reply] = []
    private var answers: [Result<[Elicitation], Error>]
    private var replyResults: [Result<Void, Error>]

    init(lists: [Result<[Elicitation], Error>], replies: [Result<Void, Error>] = []) {
        answers = lists
        replyResults = replies
    }

    func list(_ workerID: String) throws -> [Elicitation] {
        lists.append(workerID)
        return try (answers.count > 1 ? answers.removeFirst() : answers[0]).get()
    }

    func reply(_ workerID: String, _ id: String, _ body: Data) throws {
        replies.append(Reply(workerID: workerID, id: id, body: String(decoding: body, as: UTF8.self)))
        try replyResults.removeFirst().get()
    }
}

@MainActor
private final class Opened {
    var urls: [URL] = []
}

@MainActor
private func model(_ service: ScriptedService, opened: Opened = Opened()) -> ElicitationModel {
    ElicitationModel(
        service: .init(list: { workerID in try await service.list(workerID) },
                       reply: { workerID, id, body in try await service.reply(workerID, id, body) }),
        pollInterval: .seconds(3600),
        openExternally: { opened.urls.append($0) })
}

@Suite struct ElicitationValueTests {
    @Test func readsFormAndURLRequests() throws {
        let json = #"{"elicitations":[{"id":"e-1","worker_id":"w-1","session":{"harness_instance":"h-1","session_id":"s-1"},"status":"pending","sessionId":"native-1","mode":"form","message":"Pick","toolCallId":"t-9","requestedSchema":{"type":"object"}},{"id":"e-2","worker_id":"w-1","session":{"harness_instance":"h-1","session_id":"s-1"},"status":"accept","mode":"url","message":"Sign in","elicitationId":"opaque","url":"https://xn--80ak6aa92e.com/a","url_host":"xn--80ak6aa92e.com","punycode":true},{"worker_id":"w-1"}]}"#
        let items = try Elicitation.list(json: Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].session == bound && items[0].mode == .form && items[0].status == .pending)
        #expect(items[0].toolCallID == "t-9" && items[0].nativeSessionID == "native-1" && items[0].url == nil)
        #expect(items[1].status == .accepted && items[1].elicitationID == "opaque")
        #expect(items[1].link == ElicitationLink(text: "https://xn--80ak6aa92e.com/a", host: "xn--80ak6aa92e.com", punycode: true))
        #expect(try Elicitation.list(json: Data(#"{"elicitations":null}"#.utf8)).isEmpty)
        #expect(throws: ServiceError.self) { try Elicitation.list(json: Data(#"{"elicitations":{}}"#.utf8)) }
    }

    @Test func typesEachSupportedField() throws {
        let schema = ElicitationSchema(try object(#"{"type":"object","required":["level","email"],"properties":{"zeta":{"type":"boolean","default":true},"email":{"type":"string","format":"email","title":"Email"},"level":{"type":"integer","minimum":1,"maximum":5},"ratio":{"type":"number","default":0.50},"tier":{"type":"string","enum":["a","b"],"enumNames":["Alpha","Beta"]},"tone":{"oneOf":[{"const":"calm","title":"Calm"},{"const":"loud"}]}}}"#))
        #expect(schema.fields.map(\.name) == ["level", "email", "ratio", "tier", "tone", "zeta"])
        #expect(schema.fields[0].kind == .number(integer: true) && schema.fields[0].hint == "whole number · 1 to 5")
        #expect(schema.fields[1].kind == .text(format: "email") && schema.fields[1].title == "Email" && schema.fields[1].isRequired)
        #expect(schema.fields[2].defaultValue == .text("0.50"))
        #expect(schema.fields[3].kind == .choice([.init(value: "a", title: "Alpha"), .init(value: "b", title: "Beta")]))
        #expect(schema.fields[4].kind == .choice([.init(value: "calm", title: "Calm"), .init(value: "loud", title: "loud")]))
        #expect(schema.fields[5].defaultValue == .flag(true))
        #expect(schema.acceptUnavailableReason == nil)
    }

    @Test func explainsUnsupportedShapes() throws {
        let optional = ElicitationSchema(try object(#"{"type":"object","properties":{"tags":{"type":"array"},"ok":{"type":"boolean"}}}"#))
        #expect(optional.fields[1].unsupportedReason != nil)
        #expect(optional.acceptUnavailableReason == nil)
        let required = ElicitationSchema(try object(#"{"type":"object","required":["meta"],"properties":{"meta":{"type":"object"}}}"#))
        #expect(required.acceptUnavailableReason?.contains("required") == true)
        #expect(ElicitationSchema(try object(#"{"type":"array"}"#)).acceptUnavailableReason != nil)
        #expect(ElicitationSchema(nil).acceptUnavailableReason != nil)
        let numbers = ElicitationSchema(try object(#"{"properties":{"n":{"enum":[1,2]}}}"#))
        #expect(numbers.fields[0].unsupportedReason == "Only text choices can be answered here.")
    }

    @Test func sendsLiteralValuesAndLeavesOutEmptyOptionals() throws {
        let schema = ElicitationSchema(try object(#"{"type":"object","required":["note","count"],"properties":{"note":{"type":"string"},"count":{"type":"integer"},"ratio":{"type":"number"},"skip":{"type":"string"},"on":{"type":"boolean"},"tier":{"enum":["a","b"]}}}"#))
        let draft = ElicitationDraft(values: ["note": .text("  say \"$HOME\"\n`ok` ✓ "), "count": .text(" 42 "),
                                              "ratio": .text("1.50"), "on": .flag(false), "tier": .choice("b")])
        let content = try schema.content(from: draft).get()
        let body = String(decoding: ElicitationReply.body(action: .accept, content: content), as: UTF8.self)
        #expect(body == #"{"action":"accept","content":{"count":42,"note":"  say \"$HOME\"\n`ok` ✓ ","on":false,"ratio":1.50,"tier":"b"}}"#)
        // The text survives a JSON round trip exactly.
        let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect((decoded?["content"] as? [String: Any])?["note"] as? String == "  say \"$HOME\"\n`ok` ✓ ")
    }

    @Test func marksEachFieldThatIsNotReady() throws {
        let schema = ElicitationSchema(try object(#"{"type":"object","required":["note","count","on","tier"],"properties":{"note":{"type":"string"},"count":{"type":"integer"},"ratio":{"type":"number"},"on":{"type":"boolean"},"tier":{"enum":["a"]}}}"#))
        let draft = ElicitationDraft(values: ["count": .text("1.5"), "ratio": .text("1e"), "tier": .choice("z")])
        guard case .failure(let error) = schema.content(from: draft) else { Issue.record("expected problems"); return }
        #expect(Set(error.problems.keys) == ["note", "count", "ratio", "on", "tier"])
        #expect(error.problems["count"] == "Enter a whole number, such as 42.")
    }

    @Test func declineCancelAndURLAcceptCarryNoContent() {
        #expect(String(decoding: ElicitationReply.body(action: .decline, content: nil), as: UTF8.self) == #"{"action":"decline"}"#)
        #expect(String(decoding: ElicitationReply.body(action: .cancel, content: nil), as: UTF8.self) == #"{"action":"cancel"}"#)
        #expect(ServiceClient.elicitationReplyPath("w 1", id: "e/2") == "/v1/workers/w%201/elicitations/e%2F2/reply")
        #expect(ServiceClient.elicitationsPath("w-1") == "/v1/workers/w-1/elicitations")
    }

    @Test func opensOnlyTheCheckedWebHost() {
        let good = ElicitationLink(text: "https://Auth.Example.com:8443/p?q#f", host: "auth.example.com", punycode: false)
        #expect(good.openUnavailableReason == nil && good.openableURL != nil)
        #expect(good.hostRange.map { String(good.text[$0]) } == "Auth.Example.com")
        // The service's host is after the user information, so that is the one marked and checked.
        let disguised = ElicitationLink(text: "https://auth.example.com@evil.test/x", host: "evil.test", punycode: false)
        #expect(disguised.hostRange.map { String(disguised.text[$0]) } == "evil.test")
        #expect(ElicitationLink(text: "https://evil.test/", host: "auth.example.com", punycode: false).openableURL == nil)
        #expect(ElicitationLink(text: "file:///etc/passwd", host: "", punycode: false).openableURL == nil)
        #expect(ElicitationLink(text: "javascript:alert(1)", host: "x", punycode: false).openableURL == nil)
        #expect(ElicitationLink(text: "https://xn--pple-43d.com", host: "xn--pple-43d.com", punycode: false).isPunycode)
    }
}

@MainActor
@Suite struct ElicitationModelTests {
    @Test func showsOnlyThisWorkersOwnSession() async throws {
        let other = NativeSession(harnessInstance: "h-1", sessionID: "s-old")
        let service = ScriptedService(lists: [.success([try form("e-1"), try form("e-2", session: other),
                                                        try form("e-3", worker: "w-2")])])
        let model = model(service)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        #expect(model.inspection?.items.map(\.id) == ["e-1"])
        #expect(model.inspection?.outOfScope == 2)
        #expect(await service.lists == ["w-1"])
        // Without a confirmed session nothing is read.
        model.inspect("w-9", scope: nil)
        #expect(model.inspection?.phase != .loading && model.inspection?.scope == nil)
        #expect(await service.lists == ["w-1"])
    }

    @Test func repliesOnlyForTheOpenWorkerAndSendsTheDraft() async throws {
        let service = ScriptedService(lists: [.success([try form("e-1")]), .success([])], replies: [.success(())])
        let model = model(service)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        model.reply("w-2", elicitationID: "e-1", action: .decline)
        model.reply("w-1", elicitationID: "e-9", action: .decline)
        #expect(model.inspection?.replying.isEmpty == true)
        model.edit("e-1", field: "name", value: .text(" Ada "))
        model.reply("w-1", elicitationID: "e-1", action: .accept)
        #expect(model.inspection?.replying["e-1"] == .accept)
        await model.replyTask?.value
        await model.loadTask?.value
        #expect(await service.replies == [.init(workerID: "w-1", id: "e-1",
                                                body: #"{"action":"accept","content":{"name":" Ada "}}"#)])
        #expect(model.inspection?.items.isEmpty == true)
        #expect(model.inspection?.notes.last?.text == "Accepted request e-1.")
    }

    @Test func aConflictReadsAsWithdrawn() async throws {
        let service = ScriptedService(lists: [.success([link()])],
                                      replies: [.failure(ServiceStatusError(status: 409, message: "gone"))])
        let model = model(service)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        model.reply("w-1", elicitationID: "e-url", action: .accept)
        await model.replyTask?.value
        await model.loadTask?.value
        // The stale read that still lists it as pending does not bring it back.
        #expect(model.inspection?.items.isEmpty == true)
        #expect(model.inspection?.notes.last?.text.contains("withdrawn") == true)
        #expect(await service.replies.first?.body == #"{"action":"accept"}"#)
    }

    @Test func otherFailuresKeepTheRequestAndDraft() async throws {
        let service = ScriptedService(lists: [.success([try form("e-1")])], replies: [.failure(Failure("busy"))])
        let model = model(service)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        model.edit("e-1", field: "name", value: .text("x"))
        model.reply("w-1", elicitationID: "e-1", action: .accept)
        await model.replyTask?.value
        #expect(model.inspection?.failures["e-1"] == "busy")
        #expect(model.inspection?.draft(for: "e-1").values["name"] == .text("x"))
    }

    @Test func opensOnlyAnInScopeAddressTheOwnerChose() async throws {
        let opened = Opened()
        let service = ScriptedService(lists: [.success([link(), link("e-bad", url: "https://evil.test/", host: "auth.example.com")])])
        let model = model(service, opened: opened)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        #expect(opened.urls.isEmpty)
        #expect(!model.open("w-2", elicitationID: "e-url"))
        #expect(!model.open("w-1", elicitationID: "e-bad"))
        #expect(model.open("w-1", elicitationID: "e-url"))
        #expect(opened.urls == [URL(string: "https://auth.example.com/login?x=1")!])
    }
}
