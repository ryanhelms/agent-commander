import Foundation
import Testing
@testable import AgentCommander

// Which call reads a worker's stored details when several ask at once (issue #206).
//
// Pretty reads them in a SwiftUI task bound to the settled transcript. A newer transcript cancels
// that task and starts another. The new task's call arrives while the cancelled one still holds
// the worker's read, and the cancelled read then ends with no page. The new call must still get
// a page read after it arrived, so its transcript shows its details without a third trigger.
//
// Every page read here is held until the test answers it, so the order of events is exact.

/// The service: each page read is held until the test answers it. Full records answer at once.
private actor Source {
    /// The page reads that reached the service, as `worker@after`.
    private(set) var pages: [String] = []
    /// The full-record reads that reached the service, as `worker/key`.
    private(set) var records: [String] = []
    private var held: [CheckedContinuation<Result<ToolDetailPage, Error>, Never>] = []

    /// Every call the store made for a page, counted before anything is checked: also one from
    /// a caller that is already cancelled, which sends nothing.
    private(set) var attempts = 0

    func page(_ worker: String, after: UInt64) async throws -> ToolDetailPage {
        attempts += 1
        // As the service client: a caller that is already cancelled sends nothing.
        try Task.checkCancellation()
        pages.append("\(worker)@\(after)")
        return try await withCheckedContinuation { held.append($0) }.get()
    }

    func record(_ worker: String, key: String) -> ToolDetailRecord {
        records.append("\(worker)/\(key)")
        return ToolDetailRecord(key: key, kind: "tool", input: "full \(key)")
    }

    /// Answers the oldest page read still held.
    func answer(_ result: Result<ToolDetailPage, Error>) { held.removeFirst().resume(returning: result) }

    var heldCount: Int { held.count }
}

/// One run of Pretty's task for a settled transcript: read the worker's summaries, then the full
/// record of every key they name.
@MainActor
private final class Demand {
    private(set) var entered = false
    private(set) var finished = false
    /// The keys the store held when this demand's `refresh` returned.
    private(set) var saw: [String] = []
    private var work: Task<Void, Never>!

    /// The most turns of the main actor any wait here takes. Every wait is counted in turns, so
    /// a call that is stuck fails its test at once and no run waits for it.
    static let turns = 10_000

    /// The demand's task, as the tests name it: `task.cancel()` and `await task.value`.
    var task: Demand { self }

    func cancel() { work.cancel() }

    /// Waits for the demand to finish, for at most `turns`. One that has not is an issue.
    var value: Void {
        get async {
            for _ in 0..<Self.turns where !finished { await Task.yield() }
            if !finished { Issue.record("A demand did not finish: its call is stuck.") }
        }
    }

    init(_ store: ToolDetailStore, worker: String) {
        work = Task {
            entered = true
            await store.refresh(worker: worker)
            saw = store.summaries(worker: worker).keys.sorted()
            for key in saw { await store.open(worker: worker, key: key) }
            finished = true
        }
    }
}

@MainActor
private struct Service {
    let source = Source()
    let store: ToolDetailStore

    init() {
        let source = source
        store = ToolDetailStore(source: ToolDetailSource(
            page: { worker, after in try await source.page(worker, after: after) },
            record: { worker, key in await source.record(worker, key: key) },
            readSettings: { TranscriptSettings() },
            writeSettings: { $0 }))
    }

    /// Starts a demand and returns once it is inside `refresh`: reading, waiting, or already
    /// returned. Nothing suspends between its start and that call.
    func demand(_ worker: String = "w") async -> Demand {
        let demand = Demand(store, worker: worker)
        for _ in 0..<Demand.turns where !demand.entered { await Task.yield() }
        return demand
    }

    /// Starts a demand that reads, and returns once the service holds its page read.
    func reader(_ worker: String = "w") async -> Demand {
        let before = await source.pages.count
        let demand = await demand(worker)
        await asked(before + 1, or: demand)
        return demand
    }

    /// Returns once the service has been asked for `count` pages, or `demand` has finished
    /// without asking, or the turns have run out. A demand that is dropped finishes, and one
    /// that is stuck runs out of turns, so this never waits for a read that is not coming.
    func asked(_ count: Int, or demand: Demand) async {
        for _ in 0..<Demand.turns {
            if await source.pages.count >= count || demand.finished { return }
            await Task.yield()
        }
    }

    /// Whether every demand finishes within the turns. A demand that is stuck makes this false.
    func finish(_ demands: [Demand]) async -> Bool {
        for _ in 0..<Demand.turns where !demands.allSatisfy(\.finished) { await Task.yield() }
        return demands.allSatisfy(\.finished)
    }

    /// Answers the oldest held page read, when one is held.
    func answer(_ page: ToolDetailPage) async {
        guard await source.heldCount > 0 else { return }
        await source.answer(.success(page))
    }

    /// Ends the oldest held page read as its cancelled caller's request ends.
    func cancelHeld() async {
        guard await source.heldCount > 0 else { return }
        await source.answer(.failure(CancellationError()))
    }
}

private func summary(_ key: String, _ revision: UInt64, kind: String = "tool") -> ToolDetailSummary {
    ToolDetailSummary(key: key, kind: kind, sequence: 1, name: kind == "tool" ? "Bash" : "accept", revision: revision)
}

private func page(_ revision: UInt64, _ records: [ToolDetailSummary] = [], retained: [String]? = nil) -> ToolDetailPage {
    ToolDetailPage(revision: revision, records: records, retainedKeys: retained)
}

// Every wait is counted in turns (`Demand.turns`), so a stuck call fails well inside the limit.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PrettyDetailRefreshCoalescingTests {
    // MARK: A read that is cancelled while another call waits

    @Test func aCallThatOverlapsACancelledReadStillReadsItsPage() async {
        let service = Service(), store = service.store
        // A reads for the transcript as it was. Its page is held by the service.
        let a = await service.reader()
        // The transcript settles again: SwiftUI cancels A and starts B before A has unwound.
        a.task.cancel()
        let b = await service.demand()
        #expect(await service.source.pages == ["w@0"])
        await service.cancelHeld()
        await a.task.value

        // B reads the page itself. No third trigger is needed.
        await service.asked(2, or: b)
        #expect(await service.source.pages == ["w@0", "w@0"])
        await service.answer(page(5, [summary("k", 5)], retained: ["k"]))
        await b.task.value

        // B went on with the exact latest summary, and read the full record it names.
        #expect(b.saw == ["k"])
        #expect(store.summary(worker: "w", key: "k")?.revision == 5)
        #expect(store.record(worker: "w", key: "k")?.input == "full k")
        #expect(await service.source.records == ["w/k"])
        // The cancelled read left nothing behind: the next read is one request, from B's page.
        let next = await service.reader()
        await service.answer(page(5, retained: ["k"]))
        await next.task.value
        #expect(await service.source.pages == ["w@0", "w@0", "w@5"])
    }

    @Test func aFormReplyOwedByACancelledReadIsCoveredByTheCallThatWaits() async {
        let service = Service(), store = service.store
        let a = await service.reader()
        a.task.cancel()
        // The reply's read returns at once; the read in flight owes one more.
        await store.refresh(worker: "w", afterInFlight: true)
        let b = await service.demand()
        await service.cancelHeld()
        await a.task.value

        // A is cancelled and can read nothing more. B's one read holds the reply's record.
        await service.asked(2, or: b)
        #expect(await service.source.pages == ["w@0", "w@0"])
        await service.answer(page(5, [summary("form-outcome:e-1", 5, kind: "form_outcome")], retained: ["form-outcome:e-1"]))
        await b.task.value
        #expect(store.summary(worker: "w", key: "form-outcome:e-1")?.name == "accept")
        #expect(await service.source.pages.count == 2)
    }

    // MARK: Several calls during one read

    @Test func everyCallDuringOneReadIsServedByOneMoreRead() async {
        let service = Service(), store = service.store
        let a = await service.reader()
        let waiting = [await service.demand(), await service.demand(), await service.demand()]
        #expect(await service.source.pages == ["w@0"])
        // A's page was answered before the record the others came for was stored.
        await service.answer(page(4, retained: []))
        await a.task.value

        // One of them reads, from A's revision. The others wait for that read and make none.
        await service.asked(2, or: waiting[0])
        #expect(await service.source.pages == ["w@0", "w@4"])
        #expect(waiting.allSatisfy { !$0.finished })
        await service.answer(page(5, [summary("k", 5)], retained: ["k"]))
        for demand in waiting { await demand.task.value }
        #expect(waiting.map(\.saw) == [["k"], ["k"], ["k"]])
        #expect(await service.source.pages.count == 2)
        // The record they all name is read once.
        #expect(store.record(worker: "w", key: "k") != nil)
        #expect(await service.source.records == ["w/k"])
    }

    @Test func aCallDuringTheFollowingReadGetsOneOfItsOwn() async {
        let service = Service(), store = service.store
        let a = await service.reader()
        let b = await service.demand()
        await service.answer(page(4, retained: []))
        await a.task.value
        await service.asked(2, or: b)
        // C arrives while B's read is held: that read was sent before C asked.
        let c = await service.demand()
        #expect(await service.source.pages == ["w@0", "w@4"])
        await service.answer(page(5, [summary("k", 5)], retained: ["k"]))
        await b.task.value
        await service.asked(3, or: c)
        #expect(await service.source.pages == ["w@0", "w@4", "w@5"])
        await service.answer(page(6, [summary("later", 6)], retained: ["k", "later"]))
        await c.task.value
        #expect(b.saw == ["k"] && c.saw == ["k", "later"])
        #expect(store.summaries(worker: "w").keys.sorted() == ["k", "later"])
        #expect(await service.source.pages.count == 3)
    }

    @Test func aFormReplyAndAnOrdinaryCallDuringOneReadShareOneMore() async {
        let service = Service(), store = service.store
        let a = await service.reader()
        await store.refresh(worker: "w", afterInFlight: true)
        let b = await service.demand()
        await service.answer(page(4, retained: []))
        // The read in flight makes the reply's read itself. B waits for it and makes none.
        await service.asked(2, or: a)
        #expect(await service.source.pages == ["w@0", "w@4"])
        await service.answer(page(5, [summary("form-outcome:e-1", 5, kind: "form_outcome")], retained: ["form-outcome:e-1"]))
        await a.task.value
        await b.task.value
        #expect(b.saw == ["form-outcome:e-1"])
        #expect(await service.source.pages == ["w@0", "w@4"])
    }

    // MARK: A call that is itself obsolete

    @Test func aCancelledCallReadsNothingMore() async {
        let service = Service(), store = service.store
        let a = await service.reader()
        // B waits, and its transcript is replaced before A's read ends.
        let b = await service.demand()
        b.task.cancel()
        await service.answer(page(4, [summary("k", 4)], retained: ["k"]))
        await a.task.value
        await b.task.value
        #expect(await service.source.pages == ["w@0"])
        #expect(store.summary(worker: "w", key: "k")?.revision == 4)

        // A lone read that is cancelled ends with its request, and nothing follows it.
        let lone = await service.reader()
        lone.task.cancel()
        await service.cancelHeld()
        await lone.task.value
        #expect(await service.source.pages == ["w@0", "w@4"])
        let held = await service.source.heldCount
        #expect(held == 0)
        // The next call is one request, from the last page applied.
        let next = await service.reader()
        await service.answer(page(4, retained: ["k"]))
        await next.task.value
        #expect(await service.source.pages == ["w@0", "w@4", "w@4"])
    }

    @Test func aCallCancelledBeforeItStartsAsksNothing() async {
        let service = Service(), store = service.store
        // The transcript was replaced before its task ran. No read is in flight.
        let obsolete = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refresh(worker: "w")
        }
        await obsolete.value
        // The source was not called at all, so nothing relies on it noticing the cancellation.
        #expect(await service.source.attempts == 0)
        // The worker's read was left free: a live call is one request.
        let live = await service.reader()
        await service.answer(page(3, [summary("k", 3)], retained: ["k"]))
        await live.task.value
        #expect(live.saw == ["k"])
        #expect(await service.source.attempts == 1)
    }

    @Test func aBurstOfCancelledCallsEndsWhileTheReadIsStillHeld() async {
        let service = Service(), store = service.store
        let a = await service.reader()
        // The transcript settles four more times while A's page is held. Only the last is live.
        let burst = [await service.demand(), await service.demand(), await service.demand()]
        let live = await service.demand()
        for demand in burst { demand.task.cancel() }

        // The cancelled calls end now. A's page is still held, and nothing else was asked.
        let ended = await service.finish(burst)
        #expect(ended)
        #expect(!a.finished && !live.finished)
        var attempts = await service.source.attempts, held = await service.source.heldCount
        #expect(attempts == 1 && held == 1)

        // A's page arrives. The live call makes the one read that follows, and no other runs.
        await service.answer(page(4, retained: []))
        await a.task.value
        await service.asked(2, or: live)
        attempts = await service.source.attempts
        held = await service.source.heldCount
        #expect(attempts == 2 && held == 1)
        #expect(await service.source.pages == ["w@0", "w@4"])
        await service.answer(page(5, [summary("k", 5)], retained: ["k"]))
        // A stuck call fails here and is not waited for.
        let done = await service.finish([live])
        #expect(done)
        #expect(live.saw == ["k"])
        #expect(store.record(worker: "w", key: "k") != nil)
        // Nothing follows unasked: the cancelled calls never read.
        attempts = await service.source.attempts
        held = await service.source.heldCount
        #expect(attempts == 2 && held == 0)
    }

    @Test func aCancelledCallAndAChangeOfServiceEachEndAWaitOnce() async {
        let service = Service(), store = service.store
        let old = await service.reader()
        let first = await service.demand(), second = await service.demand()
        // One is cancelled and the service changes before its cancellation is handled; the
        // other is cancelled after the change has already ended its wait.
        first.task.cancel()
        store.serviceChanged()
        second.task.cancel()
        let ended = await service.finish([first, second])
        #expect(ended)
        #expect(await service.source.attempts == 1)

        // The new service is read, and a call waits for that read.
        let new = await service.reader()
        let behind = await service.demand()
        // Neither the late cancellations nor the last service's late page ends that wait.
        await service.answer(page(8, [summary("old", 8)], retained: ["old"]))
        await old.task.value
        for _ in 0..<100 { await Task.yield() }
        #expect(!behind.finished && store.summaries(worker: "w").isEmpty)
        #expect(await service.source.attempts == 2)

        await service.answer(page(2, [summary("gone", 2)], retained: ["gone"]))
        await new.task.value
        await service.asked(3, or: behind)
        #expect(await service.source.pages == ["w@0", "w@0", "w@2"])
        await service.answer(page(3, retained: ["gone"]))
        let done = await service.finish([behind])
        #expect(done && behind.saw == ["gone"])
        #expect(await service.source.attempts == 3)
    }

    // MARK: Another service, and an older one

    @Test func aCallWaitingOnTheLastServicesReadIsDroppedWithIt() async {
        let service = Service(), store = service.store
        let old = await service.reader()
        let waiting = await service.demand()
        store.serviceChanged()
        // The call was for the last service's transcript. It ends and asks the new one nothing.
        await waiting.task.value
        #expect(await service.source.pages == ["w@0"])

        // The new service is read at once, and a call during that read waits for it.
        let new = await service.reader()
        let behind = await service.demand()
        #expect(await service.source.pages == ["w@0", "w@0"])
        // The last service's page arrives late: it is dropped, and it wakes no one.
        await service.answer(page(8, [summary("old", 8)], retained: ["old"]))
        await old.task.value
        #expect(store.summaries(worker: "w").isEmpty)
        #expect(!behind.finished)
        #expect(await service.source.pages.count == 2)

        await service.answer(page(2, [summary("gone", 2)], retained: ["gone"]))
        await new.task.value
        await service.asked(3, or: behind)
        #expect(await service.source.pages == ["w@0", "w@0", "w@2"])
        await service.answer(page(3, [summary("x", 3)], retained: ["gone", "x"]))
        await behind.task.value
        #expect(behind.saw == ["gone", "x"])
    }

    @Test func anOlderServicesFollowingReadKeepsWhatItDoesNotName() async {
        let service = Service(), store = service.store
        let a = await service.reader()
        a.task.cancel()
        let b = await service.demand()
        // An older service lists no keys. Its page still arrives for the cancelled call.
        await service.answer(page(2, [summary("a", 2)]))
        await a.task.value
        await service.asked(2, or: b)
        #expect(await service.source.pages == ["w@0", "w@2"])
        await service.answer(page(4, [summary("b", 4)]))
        await b.task.value
        #expect(b.saw == ["a", "b"])
        #expect(store.record(worker: "w", key: "a") != nil && store.record(worker: "w", key: "b") != nil)
    }
}
