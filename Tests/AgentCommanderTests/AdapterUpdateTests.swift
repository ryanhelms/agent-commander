import Foundation
import Observation
import Testing
@testable import AgentCommander

// GET /v1/catalog/notices/events sends `data: {"updates":[...]}` once on connect and again
// whenever the set changes, including `{"updates":[]}` to clear it. Comments are heartbeats.

private let digest = String(repeating: "ab", count: 32)
private let otherDigest = String(repeating: "cd", count: 32)

private func frame(_ updates: String...) -> String {
    #"data: {"updates":[\#(updates.joined(separator: ","))]}"# + "\n\n"
}

private func entry(_ adapter: String, _ current: String, _ available: String, _ sha: String = digest) -> String {
    #"{"adapterId":"\#(adapter)","currentVersion":"\#(current)","availableVersion":"\#(available)","manifestSHA256":"\#(sha)"}"#
}

private let fixture = AdapterUpdate(adapterID: "fixture", currentVersion: "1.0.0", availableVersion: "2.0.0",
                                    manifestSHA256: digest)
private let other = AdapterUpdate(adapterID: "other", currentVersion: "0.4.1", availableVersion: "0.5.0",
                                  manifestSHA256: otherDigest)

private func read(_ body: String) throws -> [AdapterUpdateStream.Reader.Output] {
    var reader = AdapterUpdateStream.Reader()
    return try body.utf8.compactMap { try reader.consume($0) }
}

private final class Flag: @unchecked Sendable { var value = false }

@MainActor private final class Probe {
    weak var feed: AdapterUpdateFeed?
    var seen: [(link: AdapterUpdateFeed.Link, adapters: [String], failures: Int)] = []
}

private func connection(_ snapshots: [[AdapterUpdate]], end: Error) -> AsyncThrowingStream<[AdapterUpdate], Error> {
    // Unbounded here so the test reads every snapshot; production keeps only the newest.
    AsyncThrowingStream { output in
        for snapshot in snapshots { output.yield(snapshot) }
        output.finish(throwing: end)
    }
}

private struct Dropped: Error {}

/// Waits until `condition` holds, woken by each change to the observable state it reads. True
/// when it holds; false when the calling task is cancelled first, as at a test's time limit.
@MainActor private func until(_ condition: @MainActor () -> Bool) async -> Bool {
    while !condition() {
        // One buffered change, so a change made before the wait starts is not lost. A cancelled
        // task ends the stream, and the wait returns nil as it does at the end of a stream.
        let (changes, change) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        withObservationTracking { _ = condition() } onChange: {
            change.yield()
            change.finish()
        }
        var waiting = changes.makeAsyncIterator()
        guard await waiting.next(isolation: MainActor.shared) != nil else { return condition() }
    }
    return true
}

/// What a failed wait had seen: the feed's state, every event recorded so far, and the
/// connections still open.
@MainActor private func progress(_ exchange: Exchange, _ feed: AdapterUpdateFeed) -> String {
    "feed link \(feed.link) with \(feed.updates.count) update(s); \(exchange.progress)"
}

/// Waits only for a phase boundary. The complete order is asserted from the exchange's
/// ledger, so the test does not have to resume an iterator for every recorded event.
private func requireMilestone(_ event: Exchange.Event, in exchange: Exchange, feed: AdapterUpdateFeed,
                              isolation: isolated (any Actor)? = #isolation,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let reached = await exchange.reached(event, isolation: isolation)
    if !reached {
        let seen = await progress(exchange, feed)
        try #require(reached, "the exchange never reached \(event); \(seen)", sourceLocation: sourceLocation)
    }
}

/// A feed whose connections stay open in `exchange` until the feed lets go of them.
@MainActor private func heldFeed(on exchange: Exchange) -> AdapterUpdateFeed {
    AdapterUpdateFeed(connect: { exchange.connect() }, pause: { _ in throw CancellationError() })
}

/// Calls `feed.follow()` in a task that starts at once and runs on the main actor until the call
/// first waits. Calls started in one main-actor turn therefore reach the feed in the order they
/// were started, with nothing else in between. The exchange records `name` when the call returns.
@MainActor private func follow(_ feed: AdapterUpdateFeed, as name: String, in exchange: Exchange) -> Task<Void, Never> {
    Task.immediate { @MainActor in
        await feed.follow()
        exchange.returned(name)
    }
}

/// Expects the feed to reach the state `isRead` describes, which only a snapshot read from its
/// open connection can produce. The wait and the feed's state stay on the main actor.
@MainActor private func requireRead(in exchange: Exchange, feed: AdapterUpdateFeed,
                                   sourceLocation: SourceLocation = #_sourceLocation,
                                   _ isRead: @MainActor () -> Bool) async throws {
    let read = await until(isRead)
    try #require(read, "the feed never read the snapshot; \(progress(exchange, feed))", sourceLocation: sourceLocation)
}

@Suite struct AdapterUpdateSnapshotTests {
    @Test func readsTheDocumentedFrame() throws {
        let updates = try AdapterUpdateSnapshot.decode(Array(
            #"{"updates":[{"adapterId":"fixture","currentVersion":"1.0.0","availableVersion":"2.0.0","manifestSHA256":"\#(digest)"}]}"#.utf8))
        #expect(updates == [fixture])
        #expect(updates.first?.shortManifest == String(digest.prefix(12)))
    }

    @Test func keepsOneOrderedEntryPerAdapter() throws {
        let body = #"{"updates":[\#(entry("other", "0.4.1", "0.5.0", otherDigest)),\#(entry("fixture", "1.0.0", "1.5.0")),\#(entry("fixture", "1.0.0", "2.0.0"))]}"#
        #expect(try AdapterUpdateSnapshot.decode(Array(body.utf8)) == [fixture, other])
    }

    @Test func keepsEveryValidUpdateBeyondTwoHundredFiftySix() throws {
        let adapters = (0..<257).map { String(format: "adapter-%03d", $0) }
        let body = #"{"updates":[\#(adapters.reversed().map { entry($0, "1.0.0", "2.0.0") }.joined(separator: ","))]}"#
        let updates = try AdapterUpdateSnapshot.decode(Array(body.utf8))
        #expect(updates.count == 257)
        #expect(updates.map(\.adapterID) == adapters)
    }

    @Test func leavesOutIncompleteEntriesAndReadsAnEmptyOrMissingList() throws {
        let body = #"{"updates":[{"adapterId":"","availableVersion":"1"},{"adapterId":"x"},{"adapterId":"y","availableVersion":"3.0"}]}"#
        let updates = try AdapterUpdateSnapshot.decode(Array(body.utf8))
        #expect(updates.map(\.adapterID) == ["y"])
        #expect(updates.first?.currentLabel == "none")
        #expect(try AdapterUpdateSnapshot.decode(Array(#"{"updates":[]}"#.utf8)).isEmpty)
        #expect(try AdapterUpdateSnapshot.decode(Array(#"{"updates":null}"#.utf8)).isEmpty)
        #expect(try AdapterUpdateSnapshot.decode(Array("{}".utf8)).isEmpty)
        #expect(throws: (any Error).self) { try AdapterUpdateSnapshot.decode(Array("[1]".utf8)) }
    }
}

@Suite struct AdapterUpdateStreamTests {
    @Test func readsSnapshotsAndSkipsHeartbeatsAndUnreadableFrames() throws {
        let body = ": ping\n\n" + frame(entry("fixture", "1.0.0", "2.0.0")) + ": ping\n\n"
            + "data: not json\n\n"
            + frame(entry("other", "0.4.1", "0.5.0", otherDigest), entry("fixture", "1.0.0", "2.0.0"))
            + frame()
            + "\ncommander-http-status: 200\n"
        #expect(try read(body) == [.updates([fixture]), .updates([fixture, other]), .updates([])])
    }

    @Test func anOldServiceReportsUnsupported() throws {
        #expect(try read("\ncommander-http-status: 404\n") == [.unsupported])
    }

    @Test func aFrameCutOffByADisconnectIsNotDelivered() throws {
        #expect(try read(#"data: {"updates":[\#(entry("fixture", "1.0.0", "2.0.0"))]}"#).isEmpty)
    }

    @Test func anOversizedLineEndsTheConnection() {
        var reader = AdapterUpdateStream.Reader()
        #expect(throws: AGUIValueError.self) {
            for _ in 0...AdapterUpdateStream.lineLimit { _ = try reader.consume(UInt8(ascii: "x")) }
        }
    }

    @Test func anOversizedEventEndsTheConnection() {
        var parser = AGUIEventStreamParser(lineLimit: 64, eventLimit: 16)
        let body = "data: 0123456789\ndata: 0123456789\n\n"
        #expect(throws: AGUIValueError.self) {
            for byte in body.utf8 { _ = try parser.consume(byte) }
        }
    }
}

@Suite @MainActor struct AdapterUpdateFeedTests {
    @Test func anIdenticalSnapshotChangesNothing() {
        let feed = AdapterUpdateFeed(fixture: [fixture])
        let changed = Flag()
        withObservationTracking { _ = feed.updates } onChange: { changed.value = true }
        feed.apply([fixture])
        #expect(!changed.value)
        feed.apply([fixture, other])
        #expect(changed.value)
        #expect(feed.updates == [fixture, other])
    }

    @Test func reconnectsAndReconcilesEachConnectionFromItsSnapshot() async {
        let probe = Probe()
        let attempts = Attempts([
            connection([[fixture], [fixture]], end: AdapterUpdateStream.Failure.disconnected),
            connection([[fixture, other]], end: Dropped()),
            connection([[other], []], end: AdapterUpdateStream.Failure.disconnected),
            connection([], end: AdapterUpdateStream.Failure.unsupported)
        ])
        let feed = AdapterUpdateFeed(connect: { attempts.next() }, pause: { @MainActor failures in
            guard let feed = probe.feed else { throw CancellationError() }
            probe.seen.append((feed.link, feed.updates.map(\.adapterID), failures))
            if probe.seen.count == 4 { throw CancellationError() }
        })
        probe.feed = feed
        #expect(feed.link == .connecting)
        await feed.follow()

        #expect(probe.seen.map { $0.link } == [.reconnecting, .reconnecting, .reconnecting, .unsupported])
        // A drop keeps the last set; the next snapshot replaces it whole, and an empty one clears it.
        #expect(probe.seen.map { $0.adapters } == [["fixture"], ["fixture", "other"], [], []])
        // A snapshot resets the backoff. An old service waits the longest interval.
        #expect(probe.seen.map { $0.failures } == [1, 1, 1, AdapterUpdateFeed.unsupportedFailures])
        #expect(AdapterUpdateFeed.delay(afterFailures: AdapterUpdateFeed.unsupportedFailures) == .seconds(30))
    }

    @Test func anOldServiceClearsAStaleSet() async {
        let attempts = Attempts([connection([], end: AdapterUpdateStream.Failure.unsupported)])
        let feed = AdapterUpdateFeed(connect: { attempts.next() }, pause: { _ in throw CancellationError() })
        feed.apply([fixture])
        await feed.follow()
        #expect(feed.updates.isEmpty)
        #expect(feed.link == .unsupported)
    }

    @Test func backsOffUpToThirtySeconds() {
        let delays = (0...8).map(AdapterUpdateFeed.delay(afterFailures:))
        #expect(delays == [1, 1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
    }

    @Test func aFixtureNeverConnects() async {
        let feed = AdapterUpdateFeed(fixture: [fixture])
        await feed.follow()
        #expect(feed.updates == [fixture])
        #expect(feed.link == .live)
    }

    /// The root model outlives the window; the view task that follows it does not. SwiftUI cancels
    /// the old task on close and starts a new one on reopen, and the new call can arrive before the
    /// cancelled one has unwound, as in `old.cancel(); await feed.follow()`.
    ///
    /// The body runs off the main actor, so reading an event, checking the count and cancelling a
    /// call do not each wait for a main-actor turn behind the calls under test. The feed is still
    /// created, followed and observed on the main actor.
    @Test(.timeLimit(.minutes(1))) @concurrent
    func aReopenedWindowTakesOverFromTheCancelledTask() async throws {
        let exchange = Exchange()
        let (feed, old) = await MainActor.run {
            let held = heldFeed(on: exchange)
            return (held, follow(held, as: "old", in: exchange))
        }
        defer { old.cancel() }
        try #require(exchange.recorded == [.opened(1)])

        // One main-actor turn cancels the old call and starts the replacement, with no wait in
        // between. The old call needs a later turn to unwind, so the replacement reaches the feed
        // while the old call still holds it.
        let replacement = await MainActor.run {
            old.cancel()
            return follow(feed, as: "replacement", in: exchange)
        }
        defer { replacement.cancel() }
        // The replacement waits for the cancelled call to let go, then connects once.
        try await requireMilestone(.opened(2), in: exchange, feed: feed)
        #expect(exchange.live == 1)

        exchange.send([fixture])
        try await requireRead(in: exchange, feed: feed) { feed.updates == [fixture] && feed.link == .live }

        replacement.cancel()
        try await requireMilestone(.returned("replacement"), in: exchange, feed: feed)
        #expect(exchange.recorded == [.opened(1), .closed(1), .returned("old"), .opened(2),
                                      .closed(2), .returned("replacement")])
        #expect(exchange.live == 0)
    }

    /// Like the test above, the body runs off the main actor; the feed is created, followed and
    /// observed on it.
    @Test(.timeLimit(.minutes(1))) @concurrent
    func overlappingCallsKeepOneSubscriptionAndLeaveNoneBehind() async throws {
        let exchange = Exchange()
        // One main-actor turn creates the feed and starts all three calls, so they reach the feed
        // in this order with nothing else in between.
        let (feed, first, second, third) = await MainActor.run {
            let held = heldFeed(on: exchange)
            return (held, follow(held, as: "first", in: exchange), follow(held, as: "second", in: exchange),
                    follow(held, as: "third", in: exchange))
        }
        // A failed wait below must not leave a call following the feed after the test.
        defer { for call in [first, second, third] { call.cancel() } }
        try #require(exchange.recorded == [.opened(1)])
        #expect(exchange.live == 1)

        // A waiting call that is cancelled returns without ever connecting.
        second.cancel()
        try await requireMilestone(.returned("second"), in: exchange, feed: feed)
        #expect(exchange.live == 1)

        // The next waiting call connects once the owner has let go.
        first.cancel()
        try await requireMilestone(.opened(2), in: exchange, feed: feed)
        #expect(exchange.live == 1)
        exchange.send([fixture, other])
        try await requireRead(in: exchange, feed: feed) { feed.updates == [fixture, other] }

        third.cancel()
        try await requireMilestone(.returned("third"), in: exchange, feed: feed)
        #expect(exchange.live == 0)

        // Nothing still holds the feed: a later call connects at once. It is cancelled as soon as
        // its connection opens, before it has read anything.
        let again = await MainActor.run { follow(feed, as: "again", in: exchange) }
        defer { again.cancel() }
        #expect(exchange.recorded.last == .opened(3))
        again.cancel()
        try await requireMilestone(.returned("again"), in: exchange, feed: feed)
        #expect(exchange.recorded == [.opened(1), .returned("second"), .closed(1), .returned("first"),
                                      .opened(2), .closed(2), .returned("third"), .opened(3),
                                      .closed(3), .returned("again")])
        let live = exchange.live
        if live != 0 {
            let seen = await progress(exchange, feed)
            #expect(live == 0, "\(seen)")
        }
    }

    /// The comparison for the cancel straight after `opened` above: here the call has provably
    /// read from its connection before it is cancelled. If only the immediate cancel stalls, the
    /// stall lies between a connection opening and its first read.
    @Test(.timeLimit(.minutes(1))) func aCallCancelledAfterItsFirstSnapshotLetsGo() async throws {
        let exchange = Exchange()
        let feed = AdapterUpdateFeed(connect: { exchange.connect() }, pause: { _ in throw CancellationError() })
        let call = Task.immediate { @MainActor in
            await feed.follow()
            exchange.returned("ready")
        }
        defer { call.cancel() }
        try #require(exchange.recorded == [.opened(1)])

        // The feed starts empty, so this set can only come from the open connection.
        exchange.send([other])
        try await requireRead(in: exchange, feed: feed) { feed.updates == [other] && feed.link == .live }

        call.cancel()
        try await requireMilestone(.returned("ready"), in: exchange, feed: feed)
        #expect(exchange.recorded == [.opened(1), .closed(1), .returned("ready")])
        #expect(exchange.live == 0, "\(progress(exchange, feed))")
    }

    @Test func aRecordedMilestoneSurvivesCancellationOfItsObserver() async {
        let exchange = Exchange()
        let observation = Task.immediate { @MainActor in
            await exchange.reached(.returned("ready"))
        }

        // The observer is suspended in its stream iterator. Cancellation ends that wait;
        // keep this main-actor turn through the record, before the observer can resume.
        observation.cancel()
        exchange.returned("ready")
        #expect(await observation.value)
    }

    @Test func noticeLabelsNameTheCountAndBothVersions() {
        #expect(AdapterUpdateNotice.title(count: 1) == "Adapter update")
        #expect(AdapterUpdateNotice.title(count: 3) == "3 adapter updates")
        #expect(AdapterUpdateNotice.summary([fixture, other]) == "fixture 1.0.0 to 2.0.0; other 0.4.1 to 0.5.0")
    }
}

/// Hands out one scripted connection per attempt; later attempts end at once.
private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [AsyncThrowingStream<[AdapterUpdate], Error>]

    init(_ queue: [AsyncThrowingStream<[AdapterUpdate], Error>]) { self.queue = queue }

    func next() -> AsyncThrowingStream<[AdapterUpdate], Error> {
        lock.lock()
        defer { lock.unlock() }
        return queue.isEmpty ? connection([], end: Dropped()) : queue.removeFirst()
    }
}

/// Connections that stay open until the feed lets go of them, with an ordered record of each one
/// opening and closing and of each test call returning.
private final class Exchange: @unchecked Sendable {
    enum Event: Hashable, Sendable {
        case opened(Int)
        case closed(Int)
        case returned(String)
    }

    private let lock = NSLock()
    private var lines: [Int: AsyncThrowingStream<[AdapterUpdate], Error>.Continuation] = [:]
    private var opened = 0
    private var history: [Event] = []
    private var milestones: [Event: AsyncStream<Void>.Continuation] = [:]

    var recorded: [Event] { lock.withLock { history } }

    /// Registration and replay use the same lock as recording. A cancelled wait cannot
    /// discard a recorded milestone, or cancel the signal for any later phase.
    func reached(_ event: Event, isolation: isolated (any Actor)? = #isolation) async -> Bool {
        let (signal, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let alreadyRecorded = lock.withLock {
            if history.contains(event) { return true }
            milestones[event] = wake
            return false
        }
        if alreadyRecorded { return true }
        defer { lock.withLock { milestones[event] = nil } }
        var iterator = signal.makeAsyncIterator()
        if await iterator.next(isolation: isolation) != nil { return true }
        return lock.withLock { history.contains(event) }
    }

    /// Connections the feed holds open now.
    var live: Int { lock.withLock { lines.count } }

    /// For a failure message: the events recorded so far and the connections still open.
    var progress: String {
        lock.withLock {
            let open = lines.keys.sorted()
            return "events recorded so far \(history); "
                + (open.isEmpty ? "no connection open" : "connection(s) still open \(open)")
        }
    }

    private func record(_ event: Event) {
        let wake = lock.withLock {
            history.append(event)
            return milestones.removeValue(forKey: event)
        }
        wake?.yield()
        wake?.finish()
    }

    func connect() -> AsyncThrowingStream<[AdapterUpdate], Error> {
        AsyncThrowingStream { line in
            let id = lock.withLock {
                opened += 1
                lines[opened] = line
                return opened
            }
            line.onTermination = { [self] _ in
                lock.withLock { lines[id] = nil }
                record(.closed(id))
            }
            record(.opened(id))
        }
    }

    func send(_ updates: [AdapterUpdate]) {
        for line in lock.withLock({ Array(lines.values) }) { line.yield(updates) }
    }

    func returned(_ call: String) { record(.returned(call)) }
}
