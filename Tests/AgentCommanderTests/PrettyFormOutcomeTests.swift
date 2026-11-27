import Foundation
import Testing
@testable import AgentCommander

// The line after the owner's reply to an ACP form request (spec section H): "Answered a form",
// "Declined a form", "Cancelled a form". It is drawn only from the service's `form_outcome`
// record: its words, where it sits, that one request has one line, and the read that fetches the
// record after a reply with no provider activity.

/// One record as the service keeps it: under `form-outcome:` and the request's exact ID
/// (`formOutcomeKeyPrefix`, internal/service/elicitation.go). `key` replaces the whole key.
private func outcome(_ request: String, _ sequence: Int?, _ name: String?, revision: Int = 1,
                     kind: String = "form_outcome", key: String? = nil) -> String {
    var fields = [#""kind":"\#(kind)""#, #""key":"\#(key ?? "form-outcome:" + request)""#, #""revision":\#(revision)"#]
    if let sequence { fields.append(#""sequence":\#(sequence)"#) }
    if let name { fields.append(#""name":"\#(name)""#) }
    return "{" + fields.joined(separator: ",") + "}"
}

private func page(_ revision: Int, _ records: [String] = []) throws -> ToolDetailPage {
    try JSONDecoder().decode(ToolDetailPage.self,
                             from: Data(#"{"revision":\#(revision),"records":[\#(records.joined(separator: ","))]}"#.utf8))
}

/// What a console lays out, as `PrettyConsoleView.layout` builds it.
@MainActor
private func items(_ entries: [TranscriptEntry], _ records: [ToolDetailSummary]) -> [PrettyItem] {
    let store = ToolDetailStore(summaries: ["w": records])
    var facts = ActivityFacts(summaries: store.summaries(worker: "w"))
    facts.summary = { store.summary(worker: "w", key: $0) }
    facts.record = { store.record(worker: "w", key: $0) }
    let built = ActivityConversation.items(ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty)), facts: facts)
    let ended = PrettyRecordPlacement.withTurnEnds(built, summaries: records, worker: "w", summary: facts.summary)
    return PrettyRecordPlacement.withFormOutcomes(ended, summaries: records, worker: "w", summary: facts.summary)
}

private func words(_ items: [PrettyItem]) -> [String] {
    items.map { item in
        switch item {
        case .formOutcome(let outcome): outcome.sentence.plain + " [" + outcome.id + "]"
        case .turnEnd: "turn end"
        case .entry(let entry): entry.id
        case .group: "group"
        case .live: "live"
        default: "other"
        }
    }
}

@MainActor @Suite struct PrettyFormOutcomeTests {
    typealias Records = PrettyRecordsTests

    // MARK: Words

    @Test func eachDecisionReadsAsSectionH() throws {
        func line(_ json: String) throws -> PrettyFormOutcome? {
            PrettyFormOutcome(try #require(try Records.summaries(json).first))
        }
        #expect(try line(outcome("e-1", 3, "accept"))?.sentence.plain == "Answered a form")
        #expect(try line(outcome("e-1", 3, "decline"))?.sentence.plain == "Declined a form")
        #expect(try line(outcome("e-1", 3, "cancel"))?.sentence.plain == "Cancelled a form")
        #expect(try line(outcome("e-1", 3, "accept"))?.spoken == "Answered a form")
        // The line's identity is the request's exact ID, without the service's namespace.
        #expect(try line(outcome("e-1", 3, "accept"))?.id == "e-1")
        #expect(try #require(try Records.summaries(outcome("e-1", 3, "accept")).first).key == "form-outcome:e-1")
    }

    @Test func anUnknownDecisionOrRecordHasNoLine() throws {
        func line(_ json: String) throws -> PrettyFormOutcome? {
            PrettyFormOutcome(try #require(try Records.summaries(json).first))
        }
        // The decision is matched whole and exactly: no other word, case or status reads as one.
        for name in ["Accept", "accepted", "submit", "completed", "pending", "", " accept"] {
            #expect(try line(outcome("e-1", 3, name)) == nil, "\(name)")
        }
        #expect(try line(outcome("e-1", 3, nil)) == nil)
        // Only the service's namespace followed by a request ID is read. A bare request ID or
        // any other key could be a runner's record.
        for key in ["e-1", "form-outcome:", "form-outcome:e-", "form-outcome:toolu_01", "Form-Outcome:e-1",
                    "form_outcome:e-1", "x:form-outcome:e-1", "toolu_01"] {
            #expect(try line(outcome("e-1", 3, "accept", key: key)) == nil, "\(key)")
        }
        #expect(try line(outcome("e-1", -1, "accept")) == nil)
        // Another kind under a request ID is not a reply, whatever it is named.
        #expect(try line(outcome("e-1", 3, "accept", kind: "tool")) == nil)
        // No sequence is the service's zero: before the first console event.
        #expect(try line(outcome("e-1", nil, "accept"))?.sequence == 0)
    }

    @Test func aRequestHasOneLineInTheServicesOrder() throws {
        let records = try Records.summaries([
            outcome("e-b", 5, "decline", revision: 9),
            outcome("e-a", 5, "accept", revision: 4),
            outcome("e-c", 2, "cancel", revision: 12),
            // The same request again: the latest revision is the one read.
            outcome("e-a", 5, "cancel", revision: 6),
            outcome("e-a", 5, "accept", revision: 2),
        ].joined(separator: ","))
        let lines = PrettyFormOutcome.lines(records)
        #expect(lines.map(\.id) == ["e-c", "e-a", "e-b"])
        #expect(lines.map(\.action) == [.cancel, .cancel, .decline])
        // A later record that names no known decision leaves the request without a line: an
        // earlier one is not shown in its place.
        let unknown = try Records.summaries([outcome("e-a", 5, "accept", revision: 4),
                                             outcome("e-a", 5, "expired", revision: 6)].joined(separator: ","))
        #expect(PrettyFormOutcome.lines(unknown).isEmpty)
    }

    // MARK: Placement

    @Test func theLineFollowsTheEventItWasSentAfter() throws {
        var wire = Wire()
        wire.user("Fill it in.")                                              // w:1
        let call = wire.call("Bash", detail: "ask", result: "ok")             // w:2, result w:3
        wire.say("Thanks.")                                                   // w:4
        wire.say("Anything else?")                                            // w:5
        let records = try Records.summaries([
            Records.tool(call, 2),
            outcome("e-late", 4, "decline", revision: 8),
            outcome("e-1", 3, "accept", revision: 7),
            #"{"kind":"turn_end","key":"end","sequence":5,"revision":9,"duration_ms":4000,"stop_reason":"end_turn"}"#,
            // A turn's end named at the reply's own event: the reply's line comes first.
            outcome("e-last", 5, "cancel", revision: 10),
        ].joined(separator: ","))
        let shown = words(items(wire.entries, records))
        #expect(shown.count == 8)
        #expect(Array(shown.prefix(3)) == ["w:1", "group", "Answered a form [e-1]"])
        #expect(shown[4] == "Declined a form [e-late]")
        #expect(Array(shown.suffix(2)) == ["Cancelled a form [e-last]", "turn end"])
    }

    @Test func aReplyBeforeTheFirstEventSitsBeforeEventOne() throws {
        var wire = Wire()
        wire.user("Go.")          // w:1
        wire.say("Going.")        // w:2
        wire.say("Done.")         // w:3
        let records = try Records.summaries(outcome("e-0", 0, "accept"))
        #expect(words(items(wire.entries, records)).first == "Answered a form [e-0]")
        // A transcript that starts later does not show the worker's start: the line is left out.
        let later = Array(wire.entries.dropFirst())
        #expect(!words(items(later, records)).contains { $0.contains("form") })
        // A worker with no entry drawn yet shows the reply alone, and the console has a line to draw.
        #expect(words(items([], records)) == ["Answered a form [e-0]"])
        #expect(PrettyFormOutcome.hasReplyBeforeFirstEvent(records))
        // A reply sent after an event is never moved to the start when its event is not shown.
        let positive = try Records.summaries(outcome("e-1", 2, "accept"))
        #expect(items([], positive).isEmpty && !PrettyFormOutcome.hasReplyBeforeFirstEvent(positive))
        #expect(!words(items(later, positive + records)).contains { $0.contains("e-0") })
    }

    @Test func anOlderOrUnplaceableRecordIsLeftOut() throws {
        var wire = Wire()
        wire.user("Go.")                                           // w:1
        wire.call("Bash", detail: "ls", result: "a")               // no stored record: no sequence
        wire.say("Done.")                                          // w:4
        wire.say("More.")                                          // w:5
        // The reply names event 1; the call after it has no known sequence, so the line could
        // belong on either side of it.
        let unknown = try Records.summaries(outcome("e-1", 1, "accept"))
        #expect(!words(items(wire.entries, unknown)).contains { $0.contains("form") })
        // The window starts after the reply's event: it is not attributed to a later entry.
        let window = Array(wire.entries.suffix(1))
        let old = try Records.summaries(outcome("e-1", 4, "accept"))
        #expect(!words(items(window, old)).contains { $0.contains("form") })
        #expect(words(items(wire.entries, old)).contains("Answered a form [e-1]"))
    }

    @Test func theSameRecordsDrawOneLineHoweverOftenTheyAreBuilt() throws {
        var wire = Wire()
        wire.user("Go.")
        wire.say("Done.")
        let records = try Records.summaries([outcome("e-1", 2, "accept", revision: 3),
                                             outcome("e-1", 2, "accept", revision: 3)].joined(separator: ","))
        let once = items(wire.entries, records)
        #expect(words(once).filter { $0.contains("form") } == ["Answered a form [e-1]"])
        // Placing again over items that already hold the line would be a second row: the view
        // places once, from the records alone.
        #expect(Set(once.map(\.id)).count == once.count)
    }

    @Test func theRecentWindowKeepsOnlyTheLatestWorksReply() throws {
        var wire = Wire()
        wire.user("Two forms.")                                         // w:1
        let first = wire.call("Bash", detail: "one", result: "ok")       // w:2, w:3
        wire.say("First done.")                                         // w:4
        let second = wire.call("Bash", detail: "two", result: "ok")      // w:5, w:6
        wire.say("Second done.")                                        // w:7
        let records = try Records.summaries([
            Records.tool(first, 2), Records.tool(second, 5),
            outcome("e-1", 3, "accept", revision: 4), outcome("e-2", 6, "decline", revision: 8),
        ].joined(separator: ","))
        let all = items(wire.entries, records)
        #expect(words(all).filter { $0.contains("form") } == ["Answered a form [e-1]", "Declined a form [e-2]"])
        // The PiP shows the latest group and what follows it, as it does for a turn's end.
        let recent = ActivityConversation.recent(all)
        #expect(words(recent) == ["group", "Declined a form [e-2]", "w:7"])
    }

    @Test func aReplysLineAfterTheOpenCallDoesNotCloseIt() throws {
        var wire = Wire()
        wire.user("Ask me.")                             // w:1
        let call = wire.call("Bash", detail: "ask")      // w:2, still open
        let records = try Records.summaries([Records.tool(call, 2), outcome("e-1", 2, "accept")].joined(separator: ","))
        let all = items(wire.entries, records)
        #expect(words(all) == ["w:1", "live", "Answered a form [e-1]"])
        let split = PrettyRecordPlacement.beforeTrailingOutcomes(all)
        #expect(words(split.items) == ["w:1", "live"] && words(split.outcomes) == ["Answered a form [e-1]"])
        // With no trailing line the items are returned whole.
        #expect(PrettyRecordPlacement.beforeTrailingOutcomes(split.items).outcomes.isEmpty)
    }
}

// MARK: - The read after a reply

/// Counts page reads and holds the first one until it is released.
private actor Pages {
    private(set) var reads: [UInt64] = []
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func read(after revision: UInt64) -> Int {
        reads.append(revision)
        return reads.count
    }

    func hold() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@MainActor
private func store(_ pages: Pages, answer: @escaping @Sendable (_ read: Int) async throws -> ToolDetailPage) -> ToolDetailStore {
    ToolDetailStore(source: ToolDetailSource(
        page: { _, after in try await answer(await pages.read(after: after)) },
        record: { _, key in ToolDetailRecord(key: key, kind: "form_outcome") },
        readSettings: { TranscriptSettings() },
        writeSettings: { $0 }))
}

@MainActor @Suite struct FormOutcomeRefreshTests {
    /// The first read was answered before the reply's record was stored; a later one holds it.
    private static func heldStore(_ pages: Pages) -> ToolDetailStore {
        store(pages) { read in
            if read == 1 { await pages.hold(); return try page(4) }
            return try page(5, [outcome("e-1", 3, "accept", revision: 5)])
        }
    }

    @Test func aReplysReadDuringAnotherIsMadeOnceAfterIt() async throws {
        let pages = Pages()
        let store = Self.heldStore(pages)
        let first = Task { await store.refresh(worker: "w") }
        while await pages.reads.isEmpty { await Task.yield() }
        // The reply's read arrives while that one is in flight: it starts no second request.
        await store.refresh(worker: "w", afterInFlight: true)
        await store.refresh(worker: "w", afterInFlight: true)
        #expect(await pages.reads == [0])
        #expect(store.summary(worker: "w", key: "form-outcome:e-1") == nil)
        await pages.release()
        await first.value
        // The worker is read once more, after the revision the first read returned.
        #expect(await pages.reads == [0, 4])
        #expect(store.summary(worker: "w", key: "form-outcome:e-1")?.name == "accept")
        #expect(PrettyFormOutcome.lines(Array(store.summaries(worker: "w").values)).map(\.id) == ["e-1"])
        // Nothing is left asked for: the next read is one request.
        await store.refresh(worker: "w")
        #expect(await pages.reads == [0, 4, 5])
    }

    @Test func anOrdinaryReadDuringAnotherIsStillDropped() async throws {
        let pages = Pages()
        let store = Self.heldStore(pages)
        let first = Task { await store.refresh(worker: "w") }
        while await pages.reads.isEmpty { await Task.yield() }
        await store.refresh(worker: "w")
        await pages.release()
        await first.value
        #expect(await pages.reads == [0])
        #expect(store.summary(worker: "w", key: "form-outcome:e-1") == nil)
    }

    @Test func theReplysRecordIsReadOnceWithNoProviderActivity() async throws {
        let pages = Pages()
        await pages.release()
        let store = store(pages) { _ in try page(7, [outcome("e-1", 0, "decline", revision: 7)]) }
        await store.refresh(worker: "w", afterInFlight: true)
        // The service stored the record before it answered the reply: one read holds it.
        #expect(await pages.reads == [0])
        let lines = PrettyFormOutcome.lines(Array(store.summaries(worker: "w").values))
        #expect(lines.map(\.sentence.plain) == ["Declined a form"])
    }

    @Test func aLaterReloadOfTheSameRecordKeepsOneLine() async throws {
        let pages = Pages()
        await pages.release()
        let record = outcome("e-1", 3, "accept", revision: 2)
        // The service starts again and sends its history from the beginning.
        let store = store(pages) { read in try page(read == 1 ? 9 : 2, [record]) }
        await store.refresh(worker: "w", afterInFlight: true)
        await store.refresh(worker: "w")
        #expect(await pages.reads == [0, 9])
        #expect(PrettyFormOutcome.lines(Array(store.summaries(worker: "w").values)).map(\.id) == ["e-1"])
    }
}

// MARK: - The model says when a form reply was accepted

private let session = NativeSession(harnessInstance: "h-1", sessionID: "s-1")
private let scope = ElicitationScope(workerID: "w-1", session: session)

private func request(_ id: String, mode: Elicitation.Mode = .form) throws -> Elicitation {
    let schema = try AGUIValue(json: #"{"type":"object","properties":{"name":{"type":"string"}}}"#)
    return Elicitation(id: id, workerID: "w-1", session: session, mode: mode, message: "Who?",
                requestedSchema: mode == .form ? schema : nil,
                url: mode == .url ? "https://auth.example.com/login" : nil,
                urlHost: mode == .url ? "auth.example.com" : nil)
}

private actor Replies {
    private var results: [Result<Void, Error>]
    private var isOpen = true
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ results: [Result<Void, Error>], held: Bool = false) {
        self.results = results
        isOpen = !held
    }

    func reply() async throws {
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        try results.removeFirst().get()
    }

    func release() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    var isWaiting: Bool { !waiting.isEmpty }
}

@MainActor
private final class Heard {
    var replies: [String] = []
}

@MainActor
private func model(_ list: [Elicitation], _ replies: Replies, heard: Heard) -> ElicitationModel {
    let model = ElicitationModel(
        service: .init(list: { _ in list }, reply: { _, _, _ in try await replies.reply() }),
        pollInterval: .seconds(3600), openExternally: { _ in })
    model.formReplied = { worker, id in heard.replies.append(worker + " " + id) }
    return model
}

@MainActor @Suite struct FormReplyNoticeTests {
    @Test func eachAcceptedFormReplyIsSaidOnce() async throws {
        let heard = Heard()
        let model = model([try request("e-1"), try request("e-2"), try request("e-3")],
                          Replies([.success(()), .success(()), .success(())]), heard: heard)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        for (id, action) in [("e-1", ElicitationAction.accept), ("e-2", .decline), ("e-3", .cancel)] {
            model.reply("w-1", elicitationID: id, action: action)
            await model.replyTask?.value
        }
        #expect(heard.replies == ["w-1 e-1", "w-1 e-2", "w-1 e-3"])
    }

    @Test func aReplyThatWasNotAcceptedIsNotSaid() async throws {
        let heard = Heard()
        let failures: [Result<Void, Error>] = [.failure(ServiceStatusError(status: 409, message: "gone")),
                                               .failure(ServiceStatusError(status: 500, message: "busy"))]
        let model = model([try request("e-1"), try request("e-2")], Replies(failures), heard: heard)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        // Withdrawn, then refused: neither reply stands, so neither has a record to read.
        model.reply("w-1", elicitationID: "e-1", action: .accept)
        await model.replyTask?.value
        model.reply("w-1", elicitationID: "e-2", action: .decline)
        await model.replyTask?.value
        // A reply addressed to another worker sends nothing.
        model.reply("w-2", elicitationID: "e-2", action: .decline)
        #expect(heard.replies.isEmpty)
    }

    @Test func aLinkRequestIsNotAForm() async throws {
        let heard = Heard()
        let model = model([try request("e-url", mode: .url)], Replies([.success(())]), heard: heard)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        model.reply("w-1", elicitationID: "e-url", action: .decline)
        await model.replyTask?.value
        #expect(heard.replies.isEmpty)
    }

    @Test func aReplyAcceptedAfterThePanelClosedIsStillSaid() async throws {
        let heard = Heard()
        let replies = Replies([.success(())], held: true)
        let model = model([try request("e-1")], replies, heard: heard)
        model.inspect("w-1", scope: scope)
        await model.loadTask?.value
        model.reply("w-1", elicitationID: "e-1", action: .accept)
        while !(await replies.isWaiting) { await Task.yield() }
        model.inspect(nil, scope: nil)
        await replies.release()
        await model.replyTask?.value
        #expect(heard.replies == ["w-1 e-1"])
        #expect(model.inspection == nil)
    }
}
