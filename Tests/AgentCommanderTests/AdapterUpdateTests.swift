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

/// Expects the next recorded event to be `expected`. A failure reports the progress made before it.
/// The wait runs wherever the caller runs: on the main actor for a main-actor test, on no actor
/// for a test that is off it. Only a failure goes to the main actor, to read the feed's state.
private func expectNext(_ events: inout AsyncStream<Exchange.Event>.Iterator, _ expected: Exchange.Event,
                        in exchange: Exchange, feed: AdapterUpdateFeed,
                        isolation: isolated (any Actor)? = #isolation,
                        sourceLocation: SourceLocation = #_sourceLocation) async {
    let event = await events.next(isolation: isolation)
    guard event != expected else { return }
    // No event at all means the wait ended with the task: the time limit cancelled the test.
    let arrival = event == nil ? "no event arrived before the test task was cancelled" : "a different event arrived"
    let seen = await progress(exchange, feed)
    #expect(event == expected, "waiting for \(expected): \(arrival); \(seen)", sourceLocation: sourceLocation)
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
    /// cancelled one has unwound. Each task starts immediately on the main actor, so the order below
    /// is the order of the calls, as in `old.cancel(); await feed.follow()`.
    @Test(.timeLimit(.minutes(1))) func aReopenedWindowTakesOverFromTheCancelledTask() async {
        let exchange = Exchange()
        var events = exchange.events.makeAsyncIterator()
        let feed = AdapterUpdateFeed(connect: { exchange.connect() }, pause: { _ in throw CancellationError() })

        let old = Task.immediate { @MainActor in
            await feed.follow()
            exchange.returned("old")
        }
        defer { old.cancel() }
        await expectNext(&events, .opened(1), in: exchange, feed: feed)

        old.cancel()
        let replacement = Task.immediate { @MainActor in
            await feed.follow()
            exchange.returned("replacement")
        }
        defer { replacement.cancel() }
        // The replacement waits for the cancelled call to let go, then connects once.
        await expectNext(&events, .closed(1), in: exchange, feed: feed)
        await expectNext(&events, .returned("old"), in: exchange, feed: feed)
        await expectNext(&events, .opened(2), in: exchange, feed: feed)
        #expect(exchange.live == 1)

        exchange.send([fixture])
        let read = await until { feed.updates == [fixture] && feed.link == .live }
        #expect(read, "the feed never read the snapshot; \(progress(exchange, feed))")

        replacement.cancel()
        await expectNext(&events, .closed(2), in: exchange, feed: feed)
        await expectNext(&events, .returned("replacement"), in: exchange, feed: feed)
        #expect(exchange.live == 0)
    }

    /// Issue #150 candidate: this body runs off the main actor, so reading an event, checking the
    /// count and cancelling a call do not each wait for a turn on the main actor behind the calls
    /// under test. The feed is still created, followed and observed on the main actor.
    @Test(.timeLimit(.minutes(1))) @concurrent
    func overlappingCallsKeepOneSubscriptionAndLeaveNoneBehind() async {
        // Issue #150: this test alone prints a timed trace, so a run that only hits the time limit
        // still shows its last lifecycle event. "exchange" lines are events as the exchange
        // recorded them; "call" lines are a call's own stages; "pilot" lines are this body's
        // checkpoints, printed after the awaited step before them has ended. A pilot line does not
        // read the feed, which would take a main-actor turn; a failed wait still reports its link.
        let trace = Trace()
        let exchange = Exchange(trace: trace)
        var events = exchange.events.makeAsyncIterator()
        let feed = await MainActor.run {
            AdapterUpdateFeed(connect: { exchange.connect() }, pause: { _ in throw CancellationError() })
        }
        func pilot(_ step: String) {
            trace("pilot", "\(step)\(Task.isCancelled ? "; TEST TASK CANCELLED" : "")")
        }
        let follow: @MainActor @Sendable (String) -> Task<Void, Never> = { name in
            Task.immediate { @MainActor in
                trace("call", "\(name) enters follow")
                await feed.follow()
                trace("call", "\(name) left follow; cancelled \(Task.isCancelled)")
                exchange.returned(name)
            }
        }
        pilot("body started")

        // One main-actor turn starts all three. Each starts immediately and runs until it first
        // waits, so the calls reach the feed in this order with nothing else in between.
        let (first, second, third) = await MainActor.run {
            (follow("first"), follow("second"), follow("third"))
        }
        // A failed wait below must not leave a call following the feed after the test.
        defer { for call in [first, second, third] { call.cancel() } }
        pilot("started first, second, third; awaiting opened(1)")
        await expectNext(&events, .opened(1), in: exchange, feed: feed)
        pilot("wait for opened(1) ended")
        #expect(exchange.live == 1)

        // A waiting call that is cancelled returns without ever connecting.
        pilot("cancelling second")
        second.cancel()
        pilot("cancelled second; awaiting returned(second)")
        await expectNext(&events, .returned("second"), in: exchange, feed: feed)
        pilot("wait for returned(second) ended")
        #expect(exchange.live == 1)

        // The next waiting call connects once the owner has let go.
        pilot("cancelling first, the owner")
        first.cancel()
        pilot("cancelled first; awaiting closed(1)")
        await expectNext(&events, .closed(1), in: exchange, feed: feed)
        pilot("wait for closed(1) ended")
        await expectNext(&events, .returned("first"), in: exchange, feed: feed)
        pilot("wait for returned(first) ended")
        await expectNext(&events, .opened(2), in: exchange, feed: feed)
        pilot("wait for opened(2) ended")
        #expect(exchange.live == 1)
        exchange.send([fixture, other])
        pilot("awaiting the feed to read the snapshot")
        let read = await until { feed.updates == [fixture, other] }
        pilot("wait for the snapshot ended; read \(read)")
        if !read {
            let seen = await progress(exchange, feed)
            #expect(read, "the feed never read the snapshot; \(seen)")
        }

        pilot("cancelling third, the owner")
        third.cancel()
        pilot("cancelled third; awaiting closed(2)")
        await expectNext(&events, .closed(2), in: exchange, feed: feed)
        pilot("wait for closed(2) ended")
        await expectNext(&events, .returned("third"), in: exchange, feed: feed)
        pilot("wait for returned(third) ended")
        #expect(exchange.live == 0)

        // Nothing still holds the feed: a later call connects at once. It is cancelled as soon as
        // its connection opens, before it has read anything.
        let again = await MainActor.run { follow("again") }
        defer { again.cancel() }
        pilot("started again; awaiting opened(3)")
        await expectNext(&events, .opened(3), in: exchange, feed: feed)
        pilot("wait for opened(3) ended; cancelling again before its first snapshot")
        again.cancel()
        pilot("cancelled again; awaiting closed(3)")
        await expectNext(&events, .closed(3), in: exchange, feed: feed)
        pilot("wait for closed(3) ended")
        await expectNext(&events, .returned("again"), in: exchange, feed: feed)
        pilot("wait for returned(again) ended; body finished")
        let live = exchange.live
        if live != 0 {
            let seen = await progress(exchange, feed)
            #expect(live == 0, "\(seen)")
        }
    }

    /// The comparison for the cancel straight after `opened` above: here the call has provably
    /// read from its connection before it is cancelled. If only the immediate cancel stalls, the
    /// stall lies between a connection opening and its first read.
    @Test(.timeLimit(.minutes(1))) func aCallCancelledAfterItsFirstSnapshotLetsGo() async {
        let exchange = Exchange()
        var events = exchange.events.makeAsyncIterator()
        let feed = AdapterUpdateFeed(connect: { exchange.connect() }, pause: { _ in throw CancellationError() })
        let call = Task.immediate { @MainActor in
            await feed.follow()
            exchange.returned("ready")
        }
        defer { call.cancel() }
        await expectNext(&events, .opened(1), in: exchange, feed: feed)

        // The feed starts empty, so this set can only come from the open connection.
        exchange.send([other])
        let read = await until { feed.updates == [other] && feed.link == .live }
        #expect(read, "the feed never read the snapshot; \(progress(exchange, feed))")

        call.cancel()
        await expectNext(&events, .closed(1), in: exchange, feed: feed)
        await expectNext(&events, .returned("ready"), in: exchange, feed: feed)
        #expect(exchange.live == 0, "\(progress(exchange, feed))")
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

/// Prints one line per milestone, each with the seconds since the trace began on a monotonic
/// clock. Search a run log for `[issue-150-overlap]`. Lines are printed and flushed on the
/// caller's own path, so they survive a test that ends at its time limit.
private struct Trace: Sendable {
    private let start = ContinuousClock.now

    var elapsed: Duration { start.duration(to: .now) }

    func callAsFunction(_ source: String, _ what: String, at time: Duration? = nil) {
        let parts = (time ?? elapsed).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        print("[issue-150-overlap] +\(String(format: "%.3f", seconds))s \(source): \(what)")
        fflush(nil)
    }
}

/// Connections that stay open until the feed lets go of them, with an ordered record of each one
/// opening and closing and of each test call returning.
private final class Exchange: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case opened(Int)
        case closed(Int)
        case returned(String)
    }

    let events: AsyncStream<Event>
    private let emit: AsyncStream<Event>.Continuation
    private let lock = NSLock()
    private var lines: [Int: AsyncThrowingStream<[AdapterUpdate], Error>.Continuation] = [:]
    private var opened = 0
    /// Every event in the order it was recorded, whether or not the test has read it yet.
    private var history: [Event] = []
    private let trace: Trace?

    init(trace: Trace? = nil) {
        self.trace = trace
        let stream = AsyncStream.makeStream(of: Event.self)
        events = stream.stream
        emit = stream.continuation
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
        // Under one lock, so the history and the stream always agree on the order.
        // The trace takes its number and time under the lock and prints after it, so a printed
        // line can appear out of place but its number gives the recorded order.
        let (number, time) = lock.withLock {
            history.append(event)
            _ = emit.yield(event)
            return (history.count, trace?.elapsed)
        }
        trace?("exchange", "#\(number) recorded \(event)", at: time)
    }

    func connect() -> AsyncThrowingStream<[AdapterUpdate], Error> {
        AsyncThrowingStream { line in
            let id = lock.withLock {
                opened += 1
                lines[opened] = line
                return opened
            }
            line.onTermination = { [self] reason in
                trace?("exchange", "connection \(id) terminated: \(reason)")
                lock.withLock { lines[id] = nil }
                record(.closed(id))
            }
            record(.opened(id))
        }
    }

    func send(_ updates: [AdapterUpdate]) {
        let open = lock.withLock { Array(lines) }
        for (_, line) in open { line.yield(updates) }
        trace?("exchange", "sent a snapshot of \(updates.count) update(s) to connection(s) \(open.map(\.key).sorted())")
    }

    func returned(_ call: String) { record(.returned(call)) }
}
