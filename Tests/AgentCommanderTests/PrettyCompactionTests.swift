import Foundation
import Testing
@testable import AgentCommander

// A provider compaction in Pretty (DESIGN.md, "Pretty transcript"; spec section H). The messages
// have the shape the service sends for a negotiated ACP session: `acpScopedActivity` writes one
// event per compaction snapshot with the hashed compaction ID and `messageOp: replace`, and
// `aguiMessages` keeps one `system` message under the first event's ID, its text replaced by the
// latest status. The source pages have the SDK's `acp.compaction_state` snapshot, which holds the
// summary chunks the provider sent.

private func message(_ json: String) throws -> AGUIMessage {
    try AGUIMessage(fields: AGUIValue(json: json))
}

/// The service's message for compaction `id`, at console sequence `sequence`, as its latest
/// update left it.
private func compaction(_ sequence: Int, id: String = "cmp-a", status: String?, cursor: String = "c-9",
                        turn: String? = "op-7", source: String = "live", op: String? = "replace",
                        identity: String? = nil) throws -> AGUIMessage {
    var acp = #""source":"\#(source)","cursor":"\#(cursor)","kind":"compaction_update""#
    if let turn { acp += #","turnId":"\#(turn)""# }
    if let identity = identity ?? Optional(CompactionRecord.identity(of: id)), !identity.isEmpty {
        acp += #","messageId":"\#(identity)""#
    }
    if let op { acp += #","messageOp":"\#(op)""# }
    let text = "Provider context compaction" + (status.map { " " + $0 } ?? "")
    return try message(#"{"id":"w:\#(sequence)","role":"system","content":"\#(text)","metadata":{"acp":{\#(acp)}}}"#)
}

/// A notice the provider sent as `info`, so it folds beside a compaction as a session update.
private func notice(_ sequence: Int) throws -> AGUIMessage {
    try message(#"{"id":"w:\#(sequence)","role":"system","content":"[ACP notice] Context is almost full","metadata":{"acp":{"source":"live","cursor":"c-\#(sequence)","turnId":"op-7","kind":"notice","noticeSeverity":"info"}}}"#)
}

private func prose(_ sequence: Int, _ text: String, role: String = "assistant") throws -> AGUIMessage {
    try message(#"{"id":"w:\#(sequence)","role":"\#(role)","content":"\#(text)"}"#)
}

private func pretty(_ messages: [AGUIMessage]) -> [PrettyItem] {
    let entries = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .pretty)
    return ActivityConversation.items(ConversationActivity.items(entries))
}

private func compactions(_ items: [PrettyItem]) -> [PrettyCompaction] {
    items.compactMap { if case .compaction(let compaction) = $0 { compaction } else { nil } }
}

/// The SDK's snapshot of one compaction, as the live source keeps it behind a cursor.
private func observation(cursor: String, id: String = "cmp-a", status: String = "completed", summary: String = "[]",
                         extra: String = "", type: String = "acp.compaction_state") -> String {
    let snapshot = #"{"compactionId":"\#(id)","status":"\#(status)","firstOrdinal":4,"summary":\#(summary)\#(extra)}"#
    let data = Data(snapshot.utf8).base64EncodedString()
    return #"{"session":{"harnessInstance":"claude","sessionId":"s-1"},"cursor":"\#(cursor)","turnId":"op-7","extension":{"type":"\#(type)","mediaType":"application/json","data":"\#(data)"}}"#
}

private func page(_ observations: [String], next: String = "") throws -> SourcePage {
    try SourcePage(envelope: Data(#"{"observations":[\#(observations.joined(separator: ","))],"nextCursor":"\#(next)"}"#.utf8))
}

private let chunks = #"[{"type":"text","text":"The developer asked for a lease fix. "},{"type":"text","text":"The test now uses the fake clock."}]"#

/// Counts the reads a store makes, and what each asked for.
private actor Reads {
    private(set) var cursors: [String?] = []
    func record(_ cursor: String?) -> Int {
        cursors.append(cursor)
        return cursors.count
    }
}

/// Holds a read until the test lets it go, and tells the test when a read has reached it.
private actor Gate {
    private var arrivals = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    /// Called by a read: it waits here until `release()`.
    func wait() async {
        arrivals += 1
        watchers.forEach { $0.resume() }
        watchers = []
        await withCheckedContinuation { held.append($0) }
    }

    /// Returns once a read is waiting, or has waited, here.
    func arrived() async {
        if arrivals == 0 { await withCheckedContinuation { watchers.append($0) } }
    }

    func release() {
        held.forEach { $0.resume() }
        held = []
    }
}

@Suite struct PrettyCompactionTests {
    /// The fixture of the parent issue: a notice, then one compaction's updates, between
    /// two distinct replies.
    private func run(status: String = "completed") throws -> [AGUIMessage] {
        [
            try prose(1, "Renew the lease earlier.", role: "user"),
            try prose(2, "The lease now renews at half its lifetime."),
            try notice(3),
            try compaction(4, status: status),
            try prose(5, "I switched the test to the fake clock.")
        ]
    }

    @Test func aFinishedCompactionIsItsOwnRowBetweenTheRepliesAndTheNoticeStays() throws {
        let items = pretty(try run())

        #expect(items.map(\.id) == ["w:1", "w:2", "w:3#group", "w:4#compaction", "w:5"])
        guard case .entry(let before) = items[1], case .group(let group) = items[2],
              case .compaction(let row) = items[3], case .entry(let after) = items[4] else {
            Issue.record("expected reply, notice, compaction, reply"); return
        }
        #expect(before.kind == .prose("The lease now renews at half its lifetime.", fromUser: false))
        #expect(after.kind == .prose("I switched the test to the fake clock.", fromUser: false))
        // The notice keeps its own place and is not joined to the compaction.
        #expect(group.lines.map(\.id) == ["w:3"])
        #expect(group.summary.text == "1 session update")
        #expect(row.mark.status == .completed)
        #expect(row.mark.messageID == CompactionRecord.identity(of: "cmp-a"))
        #expect(row.mark.source == "live" && row.mark.cursor == "c-9" && row.mark.turnID == "op-7")
        // Every entry is still shown exactly once.
        #expect(items.flatMap(\.entries).map(\.id) == ["w:1", "w:2", "w:3", "w:4", "w:5"])
    }

    @Test func thePhasesOfOneCompactionAreOneRowThatKeepsItsPlace() throws {
        // The service replaces the message's text and cursor; its ID is the first update's.
        let running = pretty(try run(status: "in progress"))
        var done = try run()
        done[3] = try compaction(4, status: "completed", cursor: "c-12")
        let finished = pretty(done)

        #expect(compactions(running).map(\.mark.status) == [.inProgress])
        #expect(compactions(finished).map(\.mark.status) == [.completed])
        #expect(compactions(finished)[0].mark.cursor == "c-12")
        #expect(running.map(\.id) == finished.map(\.id))
        #expect(compactions(running)[0].liveStep.sentence.plain == "Compacting the conversation")
        #expect(compactions(running)[0].liveStep.state == .running)
    }

    @Test func twoCompactionsAreTwoRowsAndEachBreaksTheGroup() throws {
        let items = pretty([
            try prose(1, "Go on.", role: "user"),
            try notice(2),
            try compaction(3, id: "cmp-a", status: "completed"),
            try notice(4),
            try compaction(5, id: "cmp-b", status: "failed", cursor: "c-20"),
            try notice(6)
        ])
        #expect(items.map(\.id) == ["w:1", "w:2#group", "w:3#compaction", "w:4#group", "w:5#compaction", "w:6#group"])
        let rows = compactions(items)
        #expect(rows.map(\.mark.status) == [.completed, .failed])
        #expect(rows[0].mark.messageID != rows[1].mark.messageID)
    }

    @Test func aFailedCompactionReadsItsReasonOnlyFromItsRecord() throws {
        let row = try #require(compactions(pretty(try run(status: "failed"))).first)
        let bare = row.failureStep(nil)
        #expect(bare.sentence.plain == "Couldn't compact the conversation")
        #expect(bare.tag == .failed && bare.failure == nil && bare.state == .failed)

        let step = row.failureStep(CompactionRecord(error: "The summary request was too large. Start a new session."))
        #expect(step.failure?.reason == "The summary request was too large.")
        #expect(step.failure?.rest == "Start a new session.")
    }

    @Test func aRecordThatIsNotExactlyTheServicesKeepsItsFallback() throws {
        let fallbacks = [
            // A status the approved design does not draw, and one the app does not know.
            try compaction(4, status: "cancelled"),
            try compaction(4, status: "paused"),
            // The service's text for a snapshot it could not read: no status, no identity.
            try compaction(4, status: nil, op: nil, identity: ""),
            try compaction(4, status: "completed", identity: ""),
            try compaction(4, status: "completed", op: nil),
            try compaction(4, status: "completed", op: "append"),
            try compaction(4, status: "completed", source: "journal"),
            try message(#"{"id":"w:4","role":"assistant","content":"Provider context compaction completed","metadata":{"acp":{"source":"live","cursor":"c-9","kind":"compaction_update","messageId":"x","messageOp":"replace"}}}"#),
            try message(#"{"id":"w:4","role":"system","content":"Provider context compaction completed","metadata":{"acp":{"source":"live","cursor":"c-9","kind":"usage_update","messageId":"x","messageOp":"replace"}}}"#),
            try message(#"{"id":"w:4","role":"system","content":"Provider context compaction completed"}"#)
        ]
        for fallback in fallbacks {
            var messages = try run()
            messages[3] = fallback
            let items = pretty(messages)
            #expect(compactions(items).isEmpty)
            // Nothing is dropped: the record is still an entry of the conversation.
            #expect(items.flatMap(\.entries).contains { $0.id == "w:4" })
        }
        // A marked update folds with the notice beside it, as before.
        var cancelled = try run()
        cancelled[3] = try compaction(4, status: "cancelled")
        #expect(pretty(cancelled).map(\.id) == ["w:1", "w:2", "w:3#group", "w:5"])
    }

    @Test func consoleAndTerminalKeepTheServicesRow() throws {
        let entries = TranscriptEntry.entries(from: try run())
        for mode in [ConsoleDisplayMode.console, .terminal] {
            let shown = TranscriptEntry.displayed(entries, mode: mode)
            #expect(shown.map(\.id) == ["w:1", "w:2", "w:3", "w:4", "w:5"])
            #expect(shown[3].kind == .other(role: "system", text: "Provider context compaction completed"))
        }
    }

    @Test func thePiPKeepsARunningOrFailedCompactionAndLeavesAnEarlierBoundaryOut() throws {
        func window(_ status: String) throws -> [String] {
            let items = pretty([
                try prose(1, "Go on.", role: "user"),
                try compaction(2, status: status),
                try prose(3, "Reading the lease."),
                try message(#"{"id":"w:4","role":"assistant","toolCalls":[{"id":"w:t1","type":"function","function":{"name":"Read","arguments":"{}"}}]}"#),
                try message(#"{"id":"w:5","role":"tool","toolCallId":"w:t1","content":"ok"}"#),
                try prose(6, "Done.")
            ])
            return ActivityConversation.recent(items).map(\.id)
        }
        #expect(try window("completed") == ["w:t1#group", "w:6"])
        #expect(try window("failed") == ["w:2#compaction", "w:t1#group", "w:6"])
        #expect(try window("in progress") == ["w:2#compaction", "w:t1#group", "w:6"])
        // From the latest group on, the boundary is shown as it is.
        let tail = pretty([
            try prose(1, "Go on.", role: "user"),
            try message(#"{"id":"w:2","role":"assistant","toolCalls":[{"id":"w:t1","type":"function","function":{"name":"Read","arguments":"{}"}}]}"#),
            try message(#"{"id":"w:3","role":"tool","toolCallId":"w:t1","content":"ok"}"#),
            try compaction(4, status: "completed"),
            try prose(5, "Done.")
        ])
        #expect(ActivityConversation.recent(tail).map(\.id) == ["w:t1#group", "w:4#compaction", "w:5"])
    }
}

@Suite struct CompactionRecordTests {
    private let identity = CompactionRecord.identity(of: "cmp-a")

    private func record(_ snapshot: String, identity: String? = nil) -> CompactionRecord? {
        CompactionRecord(snapshot: Data(snapshot.utf8), messageID: identity ?? self.identity)
    }

    @Test func theIdentityIsTheServicesHashOfTheCompactionID() {
        // internal/provider/acp_activity.go: hex(sha256(compactionId)).
        #expect(CompactionRecord.identity(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func summaryChunksAreReadEndToEndExactlyAsSent() {
        let read = record(#"{"compactionId":"cmp-a","status":"completed","firstOrdinal":4,"summary":\#(chunks)}"#)
        #expect(read?.summary == "The developer asked for a lease fix. The test now uses the fake clock.")
        #expect(read?.error == nil)
    }

    @Test func aSnapshotOfAnotherCompactionIsNotRead() {
        let other = #"{"compactionId":"cmp-b","status":"completed","summary":\#(chunks)}"#
        #expect(record(other) == nil)
        #expect(record(#"{"status":"completed","summary":\#(chunks)}"#) == nil)
        #expect(record("not json") == nil)
    }

    @Test func noUsableSummaryIsNoSummary() {
        let cases = [
            #"{"compactionId":"cmp-a","status":"completed","summary":[]}"#,
            #"{"compactionId":"cmp-a","status":"completed"}"#,
            #"{"compactionId":"cmp-a","status":"completed","summary":[{"type":"text","text":" \n"}]}"#,
            #"{"compactionId":"cmp-a","status":"completed","summary":[{"type":"image","mimeType":"image/png","data":"AA=="}]}"#,
            #"{"compactionId":"cmp-a","status":"completed","summary":"A string"}"#,
            // The SDK left the summary out for its size: what remains is not the whole summary.
            #"{"compactionId":"cmp-a","status":"completed","summary":\#(chunks),"omitted":true}"#
        ]
        for snapshot in cases {
            let read = record(snapshot)
            #expect(read != nil)
            #expect(read?.summary == nil)
        }
    }

    @Test func onlyTextPartsAreRead() {
        let mixed = #"[{"type":"text","text":"Kept."},{"type":"resource_link","uri":"file:///x","name":"x"},{"type":"text","text":" Also kept."}]"#
        #expect(record(#"{"compactionId":"cmp-a","status":"completed","summary":\#(mixed)}"#)?.summary == "Kept. Also kept.")
    }

    @Test func aFailedSnapshotHoldsTheProvidersError() {
        let read = record(#"{"compactionId":"cmp-a","status":"failed","error":"Rate limited.","summary":[]}"#)
        #expect(read == CompactionRecord(summary: nil, error: "Rate limited."))
        #expect(record(#"{"compactionId":"cmp-a","status":"failed","error":"  "}"#)?.error == nil)
    }

    @Test func aRecordIsFoundOnlyAtTheExactCursorAndType() throws {
        let mark = try #require(TranscriptEntry.entries(from: [try compaction(4, status: "completed")]).first?.origin?.compaction)
        let summary = "The developer asked for a lease fix. The test now uses the fake clock."
        #expect(CompactionRecord.find(mark, in: try page([observation(cursor: "c-9", summary: chunks)]))?.summary == summary)
        // An earlier update of the same compaction, before its summary arrived, is another cursor.
        #expect(CompactionRecord.find(mark, in: try page([observation(cursor: "c-8", summary: chunks)])) == nil)
        #expect(CompactionRecord.find(mark, in: try page([observation(cursor: "c-9", id: "cmp-b", summary: chunks)])) == nil)
        #expect(CompactionRecord.find(mark, in: try page([observation(cursor: "c-9", summary: chunks, type: "acp.update_params")])) == nil)
        #expect(CompactionRecord.find(mark, in: try page([#"{"cursor":"c-9","gap":{"reason":"expired"}}"#])) == nil)
    }
}

@MainActor @Suite struct CompactionSummaryStoreTests {
    private func mark(status: String = "completed", cursor: String = "c-9", source: String = "live") throws -> CompactionMark {
        try #require(TranscriptEntry.entries(from: [try compaction(4, status: status, cursor: cursor, source: source)])
            .first?.origin?.compaction)
    }

    @Test func aLiveRowPagesToItsRecordAndReadsItOnce() async throws {
        let reads = Reads()
        let store = CompactionSummaryStore { worker, mark, cursor in
            #expect(worker == "w" && mark.turnID == "op-7")
            return await reads.record(cursor) == 1
                ? try page([observation(cursor: "c-8", status: "in_progress")], next: "w.live-1.128")
                : try page([observation(cursor: "c-9", summary: chunks)])
        }
        let mark = try mark()
        #expect(store.record(worker: "w", mark: mark) == nil)
        await store.load(worker: "w", mark: mark)
        await store.load(worker: "w", mark: mark)

        #expect(store.record(worker: "w", mark: mark)?.summary == "The developer asked for a lease fix. The test now uses the fake clock.")
        #expect(await reads.cursors == [nil, "w.live-1.128"])
        // Another worker's row with the same cursor is another record.
        #expect(store.record(worker: "other", mark: mark) == nil)
    }

    @Test func aRecordThatIsGoneReadsAsNoSummaryAndIsNotAskedForAgain() async throws {
        let reads = Reads()
        let store = CompactionSummaryStore { _, _, cursor in
            _ = await reads.record(cursor)
            return try page([#"{"gap":{"reason":"Earlier live ACP source records expired from the retained window"}}"#])
        }
        let mark = try mark()
        await store.load(worker: "w", mark: mark)
        await store.load(worker: "w", mark: mark)
        #expect(store.record(worker: "w", mark: mark) == CompactionRecord())
        #expect(await reads.cursors.count == 1)
    }

    @Test func pagingStopsAtItsLimitAndOnARepeatedCursor() async throws {
        let reads = Reads()
        let store = CompactionSummaryStore { _, _, cursor in
            let read = await reads.record(cursor)
            return try page([], next: "next-\(read)")
        }
        await store.load(worker: "w", mark: try mark())
        #expect(await reads.cursors == [nil, "next-1", "next-2"])

        let repeats = Reads()
        let stuck = CompactionSummaryStore { _, _, cursor in
            _ = await repeats.record(cursor)
            return try page([], next: "same")
        }
        await stuck.load(worker: "w", mark: try mark())
        #expect(await repeats.cursors == [nil, "same"])
    }

    @Test func aRunningRowAndARowWithNoCursorAreNeverRead() async throws {
        let reads = Reads()
        let store = CompactionSummaryStore { _, _, cursor in
            _ = await reads.record(cursor)
            return try page([])
        }
        await store.load(worker: "w", mark: try mark(status: "in progress"))
        await store.load(worker: "w", mark: try mark(cursor: ""))
        await store.load(worker: "", mark: try mark())
        #expect(await reads.cursors.isEmpty)
    }

    @Test func aFailedReadIsAskedForAgain() async throws {
        let reads = Reads()
        let store = CompactionSummaryStore { _, _, cursor in
            if await reads.record(cursor) == 1 { throw ServiceError.rejected("native history page is unavailable") }
            return try page([observation(cursor: "c-9", summary: chunks)])
        }
        let mark = try mark()
        await store.load(worker: "w", mark: mark)
        #expect(store.record(worker: "w", mark: mark) == nil)
        await store.load(worker: "w", mark: mark)
        #expect(store.record(worker: "w", mark: mark)?.summary != nil)
    }

    @Test func aProviderRowReadsItsOneRecordPage() async throws {
        let reads = Reads()
        let store = CompactionSummaryStore { _, mark, cursor in
            _ = await reads.record(cursor)
            #expect(mark.source == "provider")
            return try page([], next: "more")
        }
        await store.load(worker: "w", mark: try mark(source: "provider"))
        #expect(await reads.cursors == [nil])
    }

    /// Starts a second surface's load and returns once it is waiting inside `load`. The task runs
    /// on the main actor, like the test, so from its first line to its first wait nothing else runs.
    private func surface(_ store: CompactionSummaryStore, _ mark: CompactionMark) async -> Task<Void, Never> {
        @MainActor final class Flag { var isSet = false }
        let entered = Flag()
        let task = Task { @MainActor in
            entered.isSet = true
            await store.load(worker: "w", mark: mark)
        }
        while !entered.isSet { await Task.yield() }
        return task
    }

    @Test func aSurfaceThatClosesDoesNotEndTheReadAnotherSurfaceWaitsFor() async throws {
        let reads = Reads()
        let gate = Gate()
        let store = CompactionSummaryStore { _, _, cursor in
            _ = await reads.record(cursor)
            await gate.wait()
            // As the service client does: a cancelled caller's transfer ends.
            try Task.checkCancellation()
            return try page([observation(cursor: "c-9", summary: chunks)])
        }
        let mark = try mark()
        // The wall tile draws the row first and starts the read; the focused worker joins it.
        let tile = await surface(store, mark)
        await gate.arrived()
        let focused = await surface(store, mark)
        // The tile closes while the read is in flight.
        tile.cancel()
        await gate.release()
        await tile.value
        await focused.value

        #expect(store.record(worker: "w", mark: mark)?.summary == "The developer asked for a lease fix. The test now uses the fake clock.")
        #expect(await reads.cursors == [nil])
    }

    @Test func aServiceChangeLetsGoOfAReadInFlightAndItsAnswerIsDropped() async throws {
        let reads = Reads()
        let old = Gate(), fresh = Gate()
        let store = CompactionSummaryStore { _, _, cursor in
            // The last service's read ignores its cancellation and still answers.
            if await reads.record(cursor) == 1 {
                await old.wait()
                return try page([observation(cursor: "c-9", summary: #"[{"type":"text","text":"From the last service."}]"#)])
            }
            await fresh.wait()
            return try page([observation(cursor: "c-9", summary: #"[{"type":"text","text":"From the new service."}]"#)])
        }
        let mark = try mark()
        let before = await surface(store, mark)
        await old.arrived()
        store.serviceChanged()

        // The same row is read from the new service at once, while the old read is still out.
        let after = await surface(store, mark)
        await fresh.arrived()
        #expect(await reads.cursors.count == 2)

        // The old read answers: it writes nothing and leaves the new read in place.
        await old.release()
        await before.value
        #expect(store.record(worker: "w", mark: mark) == nil)
        let joined = await surface(store, mark)
        #expect(await reads.cursors.count == 2)

        await fresh.release()
        await after.value
        await joined.value
        #expect(store.record(worker: "w", mark: mark)?.summary == "From the new service.")
        #expect(await reads.cursors.count == 2)
    }

    @Test func aServiceChangeDropsWhatWasRead() async throws {
        let store = CompactionSummaryStore { _, _, _ in try page([observation(cursor: "c-9", summary: chunks)]) }
        let mark = try mark()
        await store.load(worker: "w", mark: mark)
        #expect(store.record(worker: "w", mark: mark) != nil)
        store.serviceChanged()
        #expect(store.record(worker: "w", mark: mark) == nil)
    }

    @Test func thePreviewFixtureDrawsEachStateThroughTheProductionReaders() async throws {
        let items = pretty(CompactionFixture.messages(workerID: "W-1"))
        let rows = compactions(items)
        #expect(rows.map(\.mark.status) == [.completed, .completed, .failed, .inProgress])
        // The fixture's notice is a warning: in the open, before the first compaction.
        #expect(items.first?.id == "W-1:10")

        for row in rows { await CompactionFixture.store.load(worker: "W-1", mark: row.mark) }
        let records = rows.map { CompactionFixture.store.record(worker: "W-1", mark: $0.mark) }
        #expect(records[0]?.summary?.hasPrefix("The developer asked for timeout coverage") == true)
        #expect(records[1] == CompactionRecord())
        #expect(records[2]?.error?.hasPrefix("The summary request exceeded the context window.") == true)
        #expect(records[3] == nil)
    }
}
