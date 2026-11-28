import Foundation
import Testing
@testable import AgentCommander

// What the store keeps once the service has dropped a record (issue #201). The service keeps
// each worker's latest 256 records or 16 MiB. A page that lists the keys it still holds
// (`retained_keys`) is the whole truth about which records exist; a page without the member
// (an older service) says nothing about what was dropped.
//
// Every read here is held until the test answers it, so the order of answers is exact.

/// The calls of one kind, each held until the test answers it.
private actor Held<Value: Sendable> {
    private(set) var asked: [String] = []
    private var waiting: [CheckedContinuation<Result<Value, Error>, Never>] = []

    func answer(_ request: String) async throws -> Value {
        asked.append(request)
        return try await withCheckedContinuation { waiting.append($0) }.get()
    }

    /// Answers the oldest call still held.
    func release(_ result: Result<Value, Error>) { waiting.removeFirst().resume(returning: result) }

    var held: Int { waiting.count }
}

private struct NotHeld: Error {}

@MainActor
private struct Service {
    let pages = Held<ToolDetailPage>()
    let records = Held<ToolDetailRecord>()
    let store: ToolDetailStore

    init() {
        let pages = pages, records = records
        store = ToolDetailStore(source: ToolDetailSource(
            page: { worker, after in try await pages.answer("\(worker)@\(after)") },
            record: { worker, key in try await records.answer("\(worker)/\(key)") },
            readSettings: { TranscriptSettings() },
            writeSettings: { $0 }))
    }

    /// Starts a page read and returns once the service holds it.
    func startRefresh(_ worker: String = "w") async -> Task<Void, Never> {
        let before = await pages.asked.count
        let task = Task { await store.refresh(worker: worker) }
        while await pages.asked.count == before { await Task.yield() }
        return task
    }

    /// One whole page read, answered with `page`.
    func refresh(_ page: ToolDetailPage, worker: String = "w") async {
        let task = await startRefresh(worker)
        await pages.release(.success(page))
        await task.value
    }

    /// Starts a full-record read and returns once the service holds it.
    func startOpen(_ key: String, worker: String = "w") async -> Task<Void, Never> {
        let before = await records.asked.count
        let task = Task { await store.open(worker: worker, key: key) }
        while await records.asked.count == before { await Task.yield() }
        return task
    }

    /// One whole full-record read, answered with the record at `revision`.
    func open(_ key: String, revision: UInt64?, worker: String = "w") async {
        let task = await startOpen(key, worker: worker)
        await records.release(.success(full(key, revision)))
        await task.value
    }
}

private func summary(_ key: String, _ revision: UInt64?) -> ToolDetailSummary {
    ToolDetailSummary(key: key, kind: "tool", name: "Bash", revision: revision)
}

private func full(_ key: String, _ revision: UInt64?) -> ToolDetailRecord {
    ToolDetailRecord(key: key, kind: "tool", input: "at \(revision ?? 0)", revision: revision)
}

private func page(_ revision: UInt64, _ records: [ToolDetailSummary] = [], retained: [String]? = nil) -> ToolDetailPage {
    ToolDetailPage(revision: revision, records: records, retainedKeys: retained)
}

@MainActor @Suite struct ToolDetailRetentionTests {
    // MARK: The wire

    @Test func aPageWithoutTheMemberSaysNothingAndAnEmptyListSaysNoneAreHeld() throws {
        func decoded(_ json: String) throws -> ToolDetailPage {
            try JSONDecoder().decode(ToolDetailPage.self, from: Data(json.utf8))
        }
        // An older service sends no member.
        #expect(try decoded(#"{"revision":4,"records":[]}"#).retainedKeys == nil)
        // An empty list is a statement: the service holds no record.
        #expect(try decoded(#"{"revision":4,"records":[],"retained_keys":[]}"#).retainedKeys == [])
        let listed = try decoded(#"{"revision":4,"records":[{"key":"b","kind":"tool","revision":4}],"retained_keys":["a","b"]}"#)
        #expect(listed.retainedKeys == ["a", "b"] && listed.records.map(\.key) == ["b"])
        // The full record states the revision it was last changed at, when the service sends it.
        let record = #"{"key":"a","kind":"tool","revision":7}"#, older = #"{"key":"a","kind":"tool"}"#
        #expect(try JSONDecoder().decode(ToolDetailRecord.self, from: Data(record.utf8)).revision == 7)
        #expect(try JSONDecoder().decode(ToolDetailRecord.self, from: Data(older.utf8)).revision == nil)
    }

    // MARK: A page that lists the service's keys

    @Test func aDeltaDropsWhatTheServiceNoLongerHoldsAndTheStaleCopyOfAChangedKey() async {
        let service = Service(), store = service.store
        await service.refresh(page(3, [summary("a", 1), summary("b", 2), summary("c", 3)], retained: ["a", "b", "c"]))
        for (key, revision) in [("a", 1), ("b", 2), ("c", 3)] { await service.open(key, revision: UInt64(revision)) }
        #expect(store.record(worker: "w", key: "a") != nil && store.record(worker: "w", key: "c") != nil)

        // Only `b` changed. `a` was dropped by the service, and `c` is listed unchanged.
        await service.refresh(page(5, [summary("b", 5)], retained: ["b", "c"]))
        #expect(await service.pages.asked == ["w@0", "w@3"])
        #expect(store.summaries(worker: "w").keys.sorted() == ["b", "c"])
        #expect(store.summary(worker: "w", key: "a") == nil && store.record(worker: "w", key: "a") == nil)
        #expect(store.summary(worker: "w", key: "b")?.revision == 5 && store.record(worker: "w", key: "b") == nil)
        #expect(store.summary(worker: "w", key: "c")?.revision == 3 && store.record(worker: "w", key: "c")?.revision == 3)

        // The changed key is read again when its line is opened, and that copy is kept.
        await service.open("b", revision: 5)
        #expect(store.record(worker: "w", key: "b")?.input == "at 5")

        // An empty list drops everything.
        await service.refresh(page(6, retained: []))
        #expect(store.summaries(worker: "w").isEmpty && store.record(worker: "w", key: "b") == nil
                && store.record(worker: "w", key: "c") == nil)
    }

    @Test func anOlderServicesPageKeepsEveryRecordItDoesNotName() async {
        let service = Service(), store = service.store
        await service.refresh(page(2, [summary("a", 1), summary("b", 2)]))
        await service.open("a", revision: 1)
        await service.open("b", revision: 2)
        // No member: `a` is kept with its full copy, and only the changed key's copy is dropped.
        await service.refresh(page(4, [summary("b", 4)]))
        #expect(store.summary(worker: "w", key: "a")?.revision == 1 && store.record(worker: "w", key: "a") != nil)
        #expect(store.summary(worker: "w", key: "b")?.revision == 4 && store.record(worker: "w", key: "b") == nil)
        // A record opened before any page was read is kept, as before.
        await service.open("early", revision: nil, worker: "other")
        #expect(store.record(worker: "other", key: "early") != nil)
    }

    @Test func aPageWithoutTheMemberAfterOneWithItReadsAsAnOlderServices() async {
        let service = Service(), store = service.store
        await service.refresh(page(3, [summary("a", 3)], retained: ["a"]))
        await service.open("a", revision: 3)
        // The same socket now answers as an older service: no member, and a new key.
        await service.refresh(page(5, [summary("b", 5)]))
        // Nothing cached is dropped.
        #expect(store.summaries(worker: "w").keys.sorted() == ["a", "b"] && store.record(worker: "w", key: "a") != nil)
        // The new key's record is at the page's revision, and absent from the old list. It is kept.
        await service.open("b", revision: 5)
        #expect(store.record(worker: "w", key: "b")?.input == "at 5")
        // So is one that states no revision, as an older service's may not.
        await service.refresh(page(6, [summary("c", nil)]))
        await service.open("c", revision: nil)
        #expect(store.record(worker: "w", key: "c") != nil)
        // A later page that lists keys is the whole truth again.
        await service.refresh(page(7, retained: ["b"]))
        #expect(store.summaries(worker: "w").keys.sorted() == ["b"] && store.record(worker: "w", key: "a") == nil
                && store.record(worker: "w", key: "b") != nil && store.record(worker: "w", key: "c") == nil)
    }

    // MARK: A full record that arrives late

    @Test func aLateCopyOfAKeyThatWasDroppedAndCameBackIsNotKept() async {
        let service = Service(), store = service.store
        await service.refresh(page(3, [summary("k", 3)], retained: ["k"]))
        let late = await service.startOpen("k")
        // While that read is held the service drops the key, then stores it again, changed.
        await service.refresh(page(4, retained: []))
        #expect(store.summary(worker: "w", key: "k") == nil)
        await service.refresh(page(9, [summary("k", 9)], retained: ["k"]))
        await service.records.release(.success(full("k", 3)))
        await late.value
        // The copy from before the drop is older than the record now held.
        #expect(store.record(worker: "w", key: "k") == nil)
        // It is not marked missing either: the next open reads the current copy.
        await service.open("k", revision: 9)
        #expect(await service.records.asked == ["w/k", "w/k"])
        #expect(store.record(worker: "w", key: "k")?.input == "at 9")
    }

    @Test func aLateCopyOfAKeyThatStaysDroppedIsNotRestored() async {
        let service = Service(), store = service.store
        await service.refresh(page(3, [summary("k", 3)], retained: ["k"]))
        let late = await service.startOpen("k")
        await service.refresh(page(4, retained: []))
        await service.records.release(.success(full("k", 3)))
        await late.value
        #expect(store.record(worker: "w", key: "k") == nil && store.summary(worker: "w", key: "k") == nil)
    }

    @Test func aRecordWrittenAfterTheLastPageIsKeptUntilAPageCoversIt() async {
        let service = Service(), store = service.store
        await service.refresh(page(3, [summary("old", 3)], retained: ["old"]))
        // The line is opened before the page that lists its record has been read.
        await service.open("new", revision: 5)
        #expect(store.record(worker: "w", key: "new")?.input == "at 5")
        // A page answered before the record was stored does not list it, and does not drop it.
        await service.refresh(page(4, retained: ["old"]))
        #expect(store.record(worker: "w", key: "new") != nil)
        // The page that carries the same change keeps the copy: nothing is read twice.
        await service.refresh(page(5, [summary("new", 5)], retained: ["old", "new"]))
        #expect(store.record(worker: "w", key: "new")?.input == "at 5")
        #expect(await service.records.asked == ["w/new"])
        // Once a page past that change does not list it, it is gone.
        await service.refresh(page(6, retained: ["old"]))
        #expect(store.record(worker: "w", key: "new") == nil && store.summary(worker: "w", key: "new") == nil)
    }

    // MARK: A record the service does not hold

    @Test func aLateNotFoundDoesNotHideAKeyTheServiceNowHolds() async {
        let service = Service(), store = service.store
        await service.refresh(page(3, [summary("k", 3)], retained: ["k"]))
        let late = await service.startOpen("k")
        // The key changes while the service is still answering that it holds none.
        await service.refresh(page(6, [summary("k", 6)], retained: ["k"]))
        await service.records.release(.failure(NotHeld()))
        await late.value
        #expect(store.record(worker: "w", key: "k") == nil)
        // The key is asked for again, and its record is kept.
        await service.open("k", revision: 6)
        #expect(await service.records.asked == ["w/k", "w/k"])
        #expect(store.record(worker: "w", key: "k")?.input == "at 6")
    }

    @Test func aKeyTheServiceDoesNotHoldIsAskedForOnceUntilAPageNamesIt() async {
        let service = Service(), store = service.store
        await service.refresh(page(3, [summary("k", 3)], retained: ["k"]))
        let first = await service.startOpen("k")
        await service.records.release(.failure(NotHeld()))
        await first.value
        // Known missing: opening the line again asks nothing, with or without an unrelated page.
        await store.open(worker: "w", key: "k")
        await service.refresh(page(4, [summary("other", 4)], retained: ["k", "other"]))
        await store.open(worker: "w", key: "k")
        #expect(await service.records.asked == ["w/k"])
        // A page that names the key as changed makes it readable again.
        await service.refresh(page(5, [summary("k", 5)], retained: ["k", "other"]))
        await service.open("k", revision: 5)
        #expect(await service.records.asked == ["w/k", "w/k"])
        #expect(store.record(worker: "w", key: "k") != nil)
    }

    // MARK: Another service, and one that started again

    @Test func aChangeOfServiceDropsTheLastServicesRecordsAndItsReadsInFlight() async {
        let service = Service(), store = service.store
        await service.refresh(page(7, [summary("a", 6), summary("gone", 7)], retained: ["a", "gone"]))
        await service.open("a", revision: 6)
        let missed = await service.startOpen("gone")
        await service.records.release(.failure(NotHeld()))
        await missed.value
        // A page read and a full-record read are on their way from the first service.
        let oldPage = await service.startRefresh()
        let oldRecord = await service.startOpen("b")

        store.serviceChanged()
        #expect(store.summaries(worker: "w").isEmpty && store.record(worker: "w", key: "a") == nil)

        // The new service is read at once, from the beginning: the old read does not block it.
        let newPage = await service.startRefresh()
        #expect(await service.pages.asked == ["w@0", "w@7", "w@0"])

        // The first service's answers arrive late and are dropped.
        await service.pages.release(.success(page(8, [summary("b", 8)], retained: ["a", "gone", "b"])))
        await service.records.release(.success(full("b", 8)))
        await oldPage.value
        await oldRecord.value
        #expect(store.summaries(worker: "w").isEmpty && store.record(worker: "w", key: "b") == nil)

        // The old read ending did not end the new one: a second call still starts no request.
        // It waits for the new read, then asks once for the page after it (issue #206).
        let second = Task { await store.refresh(worker: "w") }
        await Task.yield()
        let asked = await service.pages.asked.count, held = await service.pages.held
        #expect(asked == 3 && held == 1)
        await service.pages.release(.success(page(2, [summary("gone", 2)], retained: ["gone"])))
        await newPage.value
        #expect(store.summaries(worker: "w").keys.sorted() == ["gone"])
        while await service.pages.asked.count == 3 { await Task.yield() }
        await service.pages.release(.success(page(2, retained: ["gone"])))
        await second.value
        // Whenever the second call ran, it never asked the new service beside the read in flight.
        #expect(await service.pages.asked == ["w@0", "w@7", "w@0", "w@2"])

        // What the first service did not hold is asked of the new one, and the cursor is its own.
        await service.open("gone", revision: 2)
        #expect(store.record(worker: "w", key: "gone")?.input == "at 2")
        await service.refresh(page(2, retained: ["gone"]))
        #expect(await service.pages.asked.last == "w@2")
    }

    @Test func aLowerRevisionStartsTheWorkerAgainAndDropsALateCopyFromBefore() async {
        let service = Service(), store = service.store
        await service.refresh(page(9, [summary("a", 8), summary("b", 9)], retained: ["a", "b"]))
        await service.open("a", revision: 8)
        let late = await service.startOpen("b")

        // The service started again with less history. Its lower page is whole.
        await service.refresh(page(2, [summary("a", 2)], retained: ["a"]))
        #expect(await service.pages.asked == ["w@0", "w@9"])
        #expect(store.summaries(worker: "w").keys.sorted() == ["a"])
        #expect(store.summary(worker: "w", key: "a")?.revision == 2 && store.record(worker: "w", key: "a") == nil)

        // The copy read before the restart names a revision the new history has not reached.
        await service.records.release(.success(full("b", 9)))
        await late.value
        #expect(store.record(worker: "w", key: "b") == nil && store.summary(worker: "w", key: "b") == nil)

        // The worker reads on from the new history, and its records open as usual.
        await service.open("a", revision: 2)
        #expect(store.record(worker: "w", key: "a")?.input == "at 2")
        await service.refresh(page(3, [summary("c", 3)], retained: ["a", "c"]))
        #expect(await service.pages.asked.last == "w@2")
        #expect(store.summaries(worker: "w").keys.sorted() == ["a", "c"] && store.record(worker: "w", key: "a") != nil)
    }
}
