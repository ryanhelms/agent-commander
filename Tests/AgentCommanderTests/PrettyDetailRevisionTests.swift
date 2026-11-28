import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// What Pretty keys its read of stored details on (#205). A full transcript window that advances
// keeps its entry and result counts, so the key holds the material entries' own IDs and the IDs of
// the calls that hold a result. Text is no part of it, and the agent's prose only counts.

@MainActor @Suite struct PrettyDetailRevisionTests {
    static func call(_ number: Int, done: Bool = true, output: String = "ok") -> TranscriptEntry {
        TranscriptEntry(id: String(format: "w:rolling-%03d", number),
                        kind: .tool(name: "Read", detail: nil, result: done ? ToolResult(output: output) : nil))
    }

    static func prose(_ id: String, _ text: String) -> TranscriptEntry {
        TranscriptEntry(id: id, kind: .prose(text, fromUser: false))
    }

    static func revision(_ entries: [TranscriptEntry], worker: String = "w") -> PrettyConsoleView.DetailRevision {
        PrettyConsoleView.DetailRevision(worker: worker, entries: entries)
    }

    /// The two snapshots of the real fixture: 64 calls and 64 results in both, the last call's ID
    /// moved from rolling-099 to rolling-116.
    @Test func aFullWindowThatAdvancesAtTheSameCountsChangesTheKey() {
        let first = (36...99).map { Self.call($0) }
        let second = (53...116).map { Self.call($0) }
        #expect(first.count == 64 && second.count == 64)
        #expect(Self.revision(first) != Self.revision(second))
        // One step is enough: the oldest call left and one arrived.
        #expect(Self.revision(first) != Self.revision((37...100).map { Self.call($0) }))
        #expect(Self.revision(first) == Self.revision((36...99).map { Self.call($0) }))
    }

    @Test func aResultOnAnotherCallAtTheSameCountsChangesTheKey() {
        // One call of three is running in each: the same entries and the same number of results.
        let before = [Self.call(1), Self.call(2, done: false), Self.call(3)]
        let after = [Self.call(1), Self.call(2), Self.call(3, done: false)]
        #expect(Self.revision(before) != Self.revision(after))
        // The window moved one call on while the newest stayed running: both counts held.
        let moved = [Self.call(2), Self.call(3), Self.call(4, done: false)]
        let finished = [Self.call(3), Self.call(4), Self.call(5, done: false)]
        #expect(Self.revision(moved) != Self.revision(finished))
        // A call that gains its result is the plain case, and still changes the key.
        #expect(Self.revision([Self.call(1, done: false)]) != Self.revision([Self.call(1)]))
    }

    @Test func textThatChangesUnderTheSameIDsLeavesTheKeyAsItIs() {
        let calls = [Self.call(1), Self.call(2, done: false)]
        let started = Self.revision(calls + [Self.prose("w:reply", "Reading")])
        // A reply streamed in place, a result's output and a call's own summary are all text.
        #expect(started == Self.revision(calls + [Self.prose("w:reply", "Reading the retry budget, then the tests.")]))
        #expect(started == Self.revision([Self.call(1, output: "a longer result"), Self.call(2, done: false),
                                          Self.prose("w:reply", "Reading")]))
        let summarised = TranscriptEntry(id: calls[1].id, kind: .tool(name: "Read", detail: "retry/budget.ts", result: nil))
        #expect(started == Self.revision([calls[0], summarised, Self.prose("w:reply", "Reading")]))
    }

    /// A v1 ACP stream sends each reply chunk as its own prose entry with a new ID. At the cap
    /// one chunk leaves as one arrives: the counts and the material entries are as they were.
    @Test func streamedChunksReplacedOneForOneLeaveTheKeyAsItIs() {
        let prompt = TranscriptEntry(id: "w:prompt", kind: .prose("Check the budget.", fromUser: true))
        let calls = [Self.call(1), Self.call(2, done: false)]
        func window(_ chunks: ClosedRange<Int>) -> [TranscriptEntry] {
            [prompt] + calls + chunks.map { Self.prose("w:\($0)", "chunk \($0)") }
        }
        #expect(window(10...70).count == window(11...71).count)
        #expect(Self.revision(window(10...70)) == Self.revision(window(11...71)))
        #expect(Self.revision(window(10...70)) == Self.revision(window(40...100)))
        // One more chunk before the cap is a new entry, as it always was.
        #expect(Self.revision(window(10...70)) != Self.revision(window(10...71)))
        // A new prompt in place of the old one is material, at the same counts.
        let next = TranscriptEntry(id: "w:prompt-2", kind: .prose("And the tests.", fromUser: true))
        #expect(Self.revision(window(10...70)) != Self.revision([next] + calls + (11...71).map { Self.prose("w:\($0)", "") }))
        // So is a call that takes a chunk's place.
        #expect(Self.revision(window(10...70)) != Self.revision([prompt] + calls + [Self.call(3)] + (12...71).map { Self.prose("w:\($0)", "") }))
    }

    @Test func theEmptySurfaceTheWorkerAndANewEntryEachHaveTheirOwnKey() {
        let empty = Self.revision([])
        #expect(empty == Self.revision([]) && empty != Self.revision([], worker: "other"))
        let first = Self.revision([Self.prose("w:1", "Hello")])
        #expect(empty != first && first != Self.revision([Self.prose("w:1", "Hello")], worker: "other"))
        #expect(first != Self.revision([Self.prose("w:1", "Hello"), Self.prose("w:2", "Again")]))
    }

    /// The drawn view: the store is asked again when the window advances, and not for new text.
    @Test func theConversationReadsItsDetailsAgainWhenAFullWindowAdvances() async throws {
        _ = NSApplication.shared
        actor Reads {
            private(set) var pages = 0
            func next() -> Int { pages += 1; return pages }
        }
        let reads = Reads()
        let store = ToolDetailStore(source: ToolDetailSource(
            page: { _, _ in ToolDetailPage(revision: UInt64(await reads.next()), records: []) },
            record: { _, _ in throw ServiceError.rejected("tool detail not found") },
            readSettings: { TranscriptSettings() }, writeSettings: { $0 }))
        func view(_ entries: [TranscriptEntry]) -> AnyView {
            AnyView(PrettyConsoleView(consoleID: "w", entries: entries, rawOutput: "", density: .compact)
                .environment(store).frame(width: 420, height: 320))
        }
        func settled(_ pages: Int) async throws {
            for _ in 0..<200 where await reads.pages < pages { try await Task.sleep(for: .milliseconds(10)) }
            // Time for a read that should not happen to happen.
            try await Task.sleep(for: .milliseconds(150))
            #expect(await reads.pages == pages)
        }
        let reply = Self.prose("w:reply", "Reading")
        let host = NSHostingView(rootView: view((36...99).map { Self.call($0) } + [reply]))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await settled(1)
        // The reply grows in place: no read.
        let grown = Self.prose("w:reply", "Reading the budget.")
        host.rootView = view((36...99).map { Self.call($0) } + [grown])
        try await settled(1)
        // The window advances with both counts as they were: one read.
        host.rootView = view((53...116).map { Self.call($0) } + [grown])
        try await settled(2)
    }
}
