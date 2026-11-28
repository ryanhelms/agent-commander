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
//
// The whole fixture lives on the main actor, as the store does. A test reads its state without
// suspending, and waits only for an event the fixture announces (`Events`): nothing here polls,
// yields in a loop or hops to another executor. On a loaded machine each suspension can cost
// seconds, so a test's length is counted in events, not in turns of the scheduler.

/// What the fixture announces, and the one way a test waits: for a condition on its state.
@MainActor
private final class Events {
    /// How long one wait may last. It orders nothing: it only ends a wait whose event is never
    /// coming, which is a real defect in the store. It is long because other suites hold the
    /// main actor for seconds at a time on a loaded machine, and a wait needs two turns of it.
    static let patience: Duration = .seconds(60)

    private struct Wait {
        let isMet: () -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var waits: [Int: Wait] = [:]
    private var lastID = 0
    /// A wait has run out. Every later wait ends at once, so a stuck test ends after one.
    private(set) var hasExpired = false

    /// The fixture's state changed: ends every wait whose condition now holds.
    func changed() {
        for (id, wait) in waits where wait.isMet() { end(id, met: true) }
    }

    /// Returns once `isMet` holds. False, with one issue, when it does not within `patience` or
    /// the test is cancelled. A condition that already holds suspends nothing.
    func wait(for what: String, until isMet: @escaping () -> Bool) async -> Bool {
        if isMet() { return true }
        guard !hasExpired else { return false }
        lastID += 1
        let id = lastID
        let limit = Task {
            do {
                try await Task.sleep(for: Self.patience)
                end(id, met: false)
            } catch {}
        }
        let met = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waits[id] = Wait(isMet: isMet, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.end(id, met: false) }
        }
        limit.cancel()
        if !met {
            hasExpired = true
            Issue.record("Nothing happened while waiting for \(what).")
        }
        return met
    }

    /// One turn of the main actor, behind every job already queued on it: a cancellation that
    /// was sent has been handled when this returns. Used only before saying what did not happen.
    func settled() async {
        await Task { @MainActor in }.value
    }

    private func end(_ id: Int, met: Bool) {
        waits.removeValue(forKey: id)?.continuation.resume(returning: met)
    }
}

/// The service: each page read is held until the test answers it. Full records answer at once.
@MainActor
private final class Source {
    /// The page reads that reached the service, as `worker@after`.
    private(set) var pages: [String] = []
    /// The full-record reads that reached the service, as `worker/key`.
    private(set) var records: [String] = []
    /// Every call the store made for a page, counted before anything is checked: also one from
    /// a caller that is already cancelled, which sends nothing.
    private(set) var attempts = 0
    private var held: [CheckedContinuation<Result<ToolDetailPage, Error>, Never>] = []
    private let events: Events

    init(_ events: Events) { self.events = events }

    var heldCount: Int { held.count }

    func page(_ worker: String, after: UInt64) async throws -> ToolDetailPage {
        attempts += 1
        // As the service client: a caller that is already cancelled sends nothing.
        try Task.checkCancellation()
        pages.append("\(worker)@\(after)")
        return try await withCheckedContinuation { continuation in
            held.append(continuation)
            events.changed()
        }.get()
    }

    func record(_ worker: String, key: String) -> ToolDetailRecord {
        records.append("\(worker)/\(key)")
        return ToolDetailRecord(key: key, kind: "tool", input: "full \(key)")
    }

    /// Answers the oldest page read still held, when one is held.
    func answer(_ result: Result<ToolDetailPage, Error>) {
        guard !held.isEmpty else { return }
        held.removeFirst().resume(returning: result)
    }
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
    private let events: Events

    init(_ store: ToolDetailStore, worker: String, events: Events) {
        self.events = events
        work = Task {
            entered = true
            events.changed()
            await store.refresh(worker: worker)
            saw = store.summaries(worker: worker).keys.sorted()
            for key in saw { await store.open(worker: worker, key: key) }
            finished = true
            events.changed()
        }
    }

    /// The demand's task, as the tests name it: `task.cancel()` and `await task.value`.
    var task: Demand { self }

    func cancel() { work.cancel() }

    /// Waits for the demand to finish. One that does not is an issue, and is not waited for.
    var value: Void {
        get async { _ = await events.wait(for: "a demand to finish") { self.finished } }
    }
}

@MainActor
private struct Service {
    let events = Events()
    let source: Source
    let store: ToolDetailStore

    init() {
        let source = Source(events)
        self.source = source
        // Both calls run on the main actor, where the store already is.
        store = ToolDetailStore(source: ToolDetailSource(
            page: { @MainActor worker, after in try await source.page(worker, after: after) },
            record: { @MainActor worker, key in source.record(worker, key: key) },
            readSettings: { TranscriptSettings() },
            writeSettings: { $0 }))
    }

    /// Starts a demand and returns once it is inside `refresh`: reading, waiting, or already
    /// returned. The demand announces its start and then runs on without suspending, and this
    /// test shares its actor, so it resumes only when the demand has parked or finished.
    func demand(_ worker: String = "w") async -> Demand {
        let demand = Demand(store, worker: worker, events: events)
        _ = await events.wait(for: "a demand to start") { demand.entered }
        return demand
    }

    /// Starts a demand that reads, and returns once the service holds its page read.
    func reader(_ worker: String = "w") async -> Demand {
        let before = source.pages.count
        let demand = await demand(worker)
        await asked(before + 1, or: demand)
        return demand
    }

    /// Returns once the service has been asked for `count` pages, or `demand` has finished
    /// without asking. A demand that is dropped finishes, so this never waits for a read that
    /// is not coming.
    func asked(_ count: Int, or demand: Demand) async {
        let source = source
        _ = await events.wait(for: "page read \(count)") { source.pages.count >= count || demand.finished }
    }

    /// Whether every demand finishes. A demand that is stuck makes this false.
    func finish(_ demands: [Demand]) async -> Bool {
        await events.wait(for: "\(demands.count) demands to finish") { demands.allSatisfy(\.finished) }
    }

    /// Answers the oldest held page read, when one is held.
    func answer(_ page: ToolDetailPage) { source.answer(.success(page)) }

    /// Ends the oldest held page read as its cancelled caller's request ends.
    func cancelHeld() { source.answer(.failure(CancellationError())) }
}

private func summary(_ key: String, _ revision: UInt64, kind: String = "tool") -> ToolDetailSummary {
    ToolDetailSummary(key: key, kind: kind, sequence: 1, name: kind == "tool" ? "Bash" : "accept", revision: revision)
}

private func page(_ revision: UInt64, _ records: [ToolDetailSummary] = [], retained: [String]? = nil) -> ToolDetailPage {
    ToolDetailPage(revision: revision, records: records, retainedKeys: retained)
}

// One test at a time: each holds reads on the main actor, and they need not compete for it. A
// stuck call ends its test after one wait (`Events.patience`), well inside the limit. The limit
// is only a backstop: a healthy test is about twenty turns of a main actor it shares.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5))) struct PrettyDetailRefreshCoalescingTests {
    // MARK: A read that is cancelled while another call waits

    @Test func aCallThatOverlapsACancelledReadStillReadsItsPage() async {
        let service = Service(), store = service.store, source = service.source
        // A reads for the transcript as it was. Its page is held by the service.
        let a = await service.reader()
        // The transcript settles again: SwiftUI cancels A and starts B before A has unwound.
        a.task.cancel()
        let b = await service.demand()
        #expect(source.pages == ["w@0"])
        #expect(!a.finished && !b.finished)
        service.cancelHeld()
        await a.task.value

        // B reads the page itself. No third trigger is needed.
        await service.asked(2, or: b)
        #expect(source.pages == ["w@0", "w@0"])
        service.answer(page(5, [summary("k", 5)], retained: ["k"]))
        await b.task.value

        // B went on with the exact latest summary, and read the full record it names.
        #expect(b.saw == ["k"])
        #expect(store.summary(worker: "w", key: "k")?.revision == 5)
        #expect(store.record(worker: "w", key: "k")?.input == "full k")
        #expect(source.records == ["w/k"])
        // The cancelled read left nothing behind: the next read is one request, from B's page.
        let next = await service.reader()
        service.answer(page(5, retained: ["k"]))
        await next.task.value
        #expect(source.pages == ["w@0", "w@0", "w@5"])
    }

    @Test func aFormReplyOwedByACancelledReadIsCoveredByTheCallThatWaits() async {
        let service = Service(), store = service.store, source = service.source
        let a = await service.reader()
        a.task.cancel()
        // The reply's read returns at once; the read in flight owes one more.
        await store.refresh(worker: "w", afterInFlight: true)
        let b = await service.demand()
        service.cancelHeld()
        await a.task.value

        // A is cancelled and can read nothing more. B's one read holds the reply's record.
        await service.asked(2, or: b)
        #expect(source.pages == ["w@0", "w@0"])
        service.answer(page(5, [summary("form-outcome:e-1", 5, kind: "form_outcome")], retained: ["form-outcome:e-1"]))
        await b.task.value
        #expect(store.summary(worker: "w", key: "form-outcome:e-1")?.name == "accept")
        #expect(source.pages.count == 2)
    }

    // MARK: Several calls during one read

    @Test func everyCallDuringOneReadIsServedByOneMoreRead() async {
        let service = Service(), store = service.store, source = service.source
        let a = await service.reader()
        let waiting = [await service.demand(), await service.demand(), await service.demand()]
        #expect(source.pages == ["w@0"])
        // A's page was answered before the record the others came for was stored.
        service.answer(page(4, retained: []))
        await a.task.value

        // One of them reads, from A's revision. The others wait for that read and make none.
        await service.asked(2, or: waiting[0])
        #expect(source.pages == ["w@0", "w@4"])
        #expect(waiting.allSatisfy { !$0.finished })
        service.answer(page(5, [summary("k", 5)], retained: ["k"]))
        let done = await service.finish(waiting)
        #expect(done)
        #expect(waiting.map(\.saw) == [["k"], ["k"], ["k"]])
        #expect(source.pages.count == 2 && source.heldCount == 0)
        // The record they all name is read once.
        #expect(store.record(worker: "w", key: "k") != nil)
        #expect(source.records == ["w/k"])
    }

    @Test func aCallDuringTheFollowingReadGetsOneOfItsOwn() async {
        let service = Service(), store = service.store, source = service.source
        let a = await service.reader()
        let b = await service.demand()
        service.answer(page(4, retained: []))
        await a.task.value
        await service.asked(2, or: b)
        // C arrives while B's read is held: that read was sent before C asked.
        let c = await service.demand()
        #expect(source.pages == ["w@0", "w@4"])
        service.answer(page(5, [summary("k", 5)], retained: ["k"]))
        await b.task.value
        await service.asked(3, or: c)
        #expect(source.pages == ["w@0", "w@4", "w@5"])
        service.answer(page(6, [summary("later", 6)], retained: ["k", "later"]))
        await c.task.value
        #expect(b.saw == ["k"] && c.saw == ["k", "later"])
        #expect(store.summaries(worker: "w").keys.sorted() == ["k", "later"])
        #expect(source.pages.count == 3)
    }

    @Test func aFormReplyAndAnOrdinaryCallDuringOneReadShareOneMore() async {
        let service = Service(), store = service.store, source = service.source
        let a = await service.reader()
        await store.refresh(worker: "w", afterInFlight: true)
        let b = await service.demand()
        service.answer(page(4, retained: []))
        // The read in flight makes the reply's read itself. B waits for it and makes none.
        await service.asked(2, or: a)
        #expect(source.pages == ["w@0", "w@4"])
        service.answer(page(5, [summary("form-outcome:e-1", 5, kind: "form_outcome")], retained: ["form-outcome:e-1"]))
        await a.task.value
        await b.task.value
        #expect(b.saw == ["form-outcome:e-1"])
        #expect(source.pages == ["w@0", "w@4"])
    }

    // MARK: A call that is itself obsolete

    @Test func aCancelledCallReadsNothingMore() async {
        let service = Service(), store = service.store, source = service.source
        let a = await service.reader()
        // B waits, and its transcript is replaced before A's read ends.
        let b = await service.demand()
        b.task.cancel()
        service.answer(page(4, [summary("k", 4)], retained: ["k"]))
        await a.task.value
        await b.task.value
        #expect(source.pages == ["w@0"])
        #expect(store.summary(worker: "w", key: "k")?.revision == 4)

        // A lone read that is cancelled ends with its request, and nothing follows it.
        let lone = await service.reader()
        lone.task.cancel()
        service.cancelHeld()
        await lone.task.value
        #expect(source.pages == ["w@0", "w@4"])
        #expect(source.heldCount == 0)
        // The next call is one request, from the last page applied.
        let next = await service.reader()
        service.answer(page(4, retained: ["k"]))
        await next.task.value
        #expect(source.pages == ["w@0", "w@4", "w@4"])
    }

    @Test func aCallCancelledBeforeItStartsAsksNothing() async {
        let service = Service(), store = service.store, source = service.source
        // The transcript was replaced before its task ran. No read is in flight.
        let obsolete = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refresh(worker: "w")
        }
        await obsolete.value
        // The source was not called at all, so nothing relies on it noticing the cancellation.
        #expect(source.attempts == 0)
        // The worker's read was left free: a live call is one request.
        let live = await service.reader()
        service.answer(page(3, [summary("k", 3)], retained: ["k"]))
        await live.task.value
        #expect(live.saw == ["k"])
        #expect(source.attempts == 1)
    }

    @Test func aBurstOfCancelledCallsEndsWhileTheReadIsStillHeld() async {
        let service = Service(), store = service.store, source = service.source
        let a = await service.reader()
        // The transcript settles four more times while A's page is held. Only the last is live.
        let burst = [await service.demand(), await service.demand(), await service.demand()]
        let live = await service.demand()
        for demand in burst { demand.task.cancel() }

        // The cancelled calls end now. A's page is still held, and nothing else was asked.
        let ended = await service.finish(burst)
        #expect(ended)
        #expect(!a.finished && !live.finished)
        #expect(source.attempts == 1 && source.heldCount == 1)

        // A's page arrives. The live call makes the one read that follows, and no other runs.
        service.answer(page(4, retained: []))
        await a.task.value
        await service.asked(2, or: live)
        #expect(source.attempts == 2 && source.heldCount == 1)
        #expect(source.pages == ["w@0", "w@4"])
        service.answer(page(5, [summary("k", 5)], retained: ["k"]))
        let done = await service.finish([live])
        #expect(done)
        #expect(live.saw == ["k"])
        #expect(store.record(worker: "w", key: "k") != nil)
        // Nothing follows unasked: the cancelled calls never read.
        await service.events.settled()
        #expect(source.attempts == 2 && source.heldCount == 0)
    }

    @Test func aCancelledCallAndAChangeOfServiceEachEndAWaitOnce() async {
        let service = Service(), store = service.store, source = service.source
        let old = await service.reader()
        let first = await service.demand(), second = await service.demand()
        // One is cancelled and the service changes before its cancellation is handled; the
        // other is cancelled after the change has already ended its wait.
        first.task.cancel()
        store.serviceChanged()
        second.task.cancel()
        let ended = await service.finish([first, second])
        #expect(ended)
        #expect(source.attempts == 1)

        // The new service is read, and a call waits for that read.
        let new = await service.reader()
        let behind = await service.demand()
        // Neither the late cancellations nor the last service's late page ends that wait.
        service.answer(page(8, [summary("old", 8)], retained: ["old"]))
        await old.task.value
        await service.events.settled()
        #expect(!behind.finished && store.summaries(worker: "w").isEmpty)
        #expect(source.attempts == 2)

        service.answer(page(2, [summary("gone", 2)], retained: ["gone"]))
        await new.task.value
        await service.asked(3, or: behind)
        #expect(source.pages == ["w@0", "w@0", "w@2"])
        service.answer(page(3, retained: ["gone"]))
        let done = await service.finish([behind])
        #expect(done && behind.saw == ["gone"])
        #expect(source.attempts == 3)
    }

    // MARK: Another service, and an older one

    @Test func aCallWaitingOnTheLastServicesReadIsDroppedWithIt() async {
        let service = Service(), store = service.store, source = service.source
        let old = await service.reader()
        let waiting = await service.demand()
        store.serviceChanged()
        // The call was for the last service's transcript. It ends and asks the new one nothing.
        await waiting.task.value
        #expect(source.pages == ["w@0"])

        // The new service is read at once, and a call during that read waits for it.
        let new = await service.reader()
        let behind = await service.demand()
        #expect(source.pages == ["w@0", "w@0"])
        // The last service's page arrives late: it is dropped, and it wakes no one.
        service.answer(page(8, [summary("old", 8)], retained: ["old"]))
        await old.task.value
        #expect(store.summaries(worker: "w").isEmpty)
        #expect(!behind.finished)
        #expect(source.pages.count == 2)

        service.answer(page(2, [summary("gone", 2)], retained: ["gone"]))
        await new.task.value
        await service.asked(3, or: behind)
        #expect(source.pages == ["w@0", "w@0", "w@2"])
        service.answer(page(3, [summary("x", 3)], retained: ["gone", "x"]))
        await behind.task.value
        #expect(behind.saw == ["gone", "x"])
    }

    @Test func anOlderServicesFollowingReadKeepsWhatItDoesNotName() async {
        let service = Service(), store = service.store, source = service.source
        let a = await service.reader()
        a.task.cancel()
        let b = await service.demand()
        // An older service lists no keys. Its page still arrives for the cancelled call.
        service.answer(page(2, [summary("a", 2)]))
        await a.task.value
        await service.asked(2, or: b)
        #expect(source.pages == ["w@0", "w@2"])
        service.answer(page(4, [summary("b", 4)]))
        await b.task.value
        #expect(b.saw == ["a", "b"])
        #expect(store.record(worker: "w", key: "a") != nil && store.record(worker: "w", key: "b") != nil)
    }
}
