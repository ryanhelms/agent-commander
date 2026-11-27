import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

/// Issue #129: an ACP edit keeps its typed `diff` blocks in the stored record's tool content. The
/// opened line draws each block's added and removed lines in the result well, and the sentence
/// gains exact counts once that record has been read. Only the typed form is read.
@MainActor @Suite struct ResultChangeTests {
    static let path = "/repo/internal/service/lease.go"
    static let before = "func (l *lease) renewAt() time.Time {\n\treturn l.expires.Add(-time.Second)\n}\n"
    static let after = "func (l *lease) renewAt() time.Time {\n\thalf := l.expires.Sub(l.granted) / 2\n"
        + "\t// renew at half the lifetime\n\treturn l.granted.Add(half)\n}\n"

    /// One diff part as ACP sends it. `old` nil leaves `oldText` out.
    static func part(_ path: String = ResultChangeTests.path, old: String? = ResultChangeTests.before,
                     new: String = ResultChangeTests.after) -> [String: Any] {
        var part: [String: Any] = ["type": "diff", "path": path, "newText": new]
        if let old { part["oldText"] = old }
        return part
    }

    /// Tool content as the service stores it: the list's JSON text.
    static func content(_ parts: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }

    static let updated = "The file \(path) has been updated."

    /// A stored record as the owner socket serves it, decoded as the app decodes it.
    static func record(content: String?, result: String? = ResultChangeTests.updated, key: String = "call-w:1",
                       truncated: [String]? = nil, shortened: [String: [String]]? = nil) throws -> ToolDetailRecord {
        var wire: [String: Any] = ["key": key, "kind": "tool", "name": "Edit", "title": "Edit lease.go",
                                   "input": #"{"file_path":"\#(path)","old_string":"a","new_string":"b"}"#]
        if let content { wire["content"] = content }
        if let result { wire["result"] = result }
        if let truncated { wire["truncated"] = truncated }
        if let shortened { wire["shortened"] = shortened }
        return try JSONDecoder().decode(ToolDetailRecord.self, from: JSONSerialization.data(withJSONObject: wire))
    }

    static func changes(_ parts: [[String: Any]], limits: ResultChanges.Limits = .init()) -> ResultChanges {
        ResultChanges.read(content: content(parts), limits: limits)
    }

    static func lines(_ block: ChangeBlock?) -> ChangeLines? {
        if case .lines(let lines)? = block?.state { lines } else { nil }
    }

    /// One Edit as the console sends it, and its sentence with the stored record given.
    static func edit(_ record: ToolDetailRecord?, result: String? = "updated", error: String? = nil)
        -> (entry: TranscriptEntry, step: ActivityStep) {
        var wire = Wire()
        wire.call("Edit", detail: path, result: result, error: error)
        let entry = wire.entries[0]
        let step = ActivitySteps.step(tool: entry, awaitingToolID: nil, facts: ActivityFacts(record: { _ in record }))!
        return (entry, step)
    }

    // MARK: The provider's shape

    @Test func aStoredEditRecordDecodesToItsLines() throws {
        let record = try Self.record(content: Self.content([Self.part()]))
        let changes = try #require(record.resultChanges)
        #expect(changes.blocks.count == 1 && changes.unread == 0 && changes.undrawn == 0)
        let block = changes.blocks[0]
        #expect(block.path == Self.path && !block.isNewFile)
        let lines = try #require(Self.lines(block))
        #expect(lines.outcome == .changed)
        #expect(lines.rows.map(\.kind) == [.context, .removed, .added, .added, .added, .context])
        // Tabs are kept as sent, and no line number is made up.
        #expect(lines.rows.map(\.text) == [
            "func (l *lease) renewAt() time.Time {", "\treturn l.expires.Add(-time.Second)",
            "\thalf := l.expires.Sub(l.granted) / 2", "\t// renew at half the lifetime", "\treturn l.granted.Add(half)", "}",
        ])
        #expect(changes.counts == ChangeCounts(added: 3, removed: 1))
        #expect(changes.counts?.text == "+3 \u{2212}1")
        #expect(changes.counts?.spoken == "3 lines added, 1 line removed")
    }

    @Test func tabsAndBlankLinesAreKept() throws {
        let lines = try #require(Self.lines(Self.changes([Self.part(old: "a\n\n\tb\n", new: "a\n\n\tb\n\n\t\tc\n")]).blocks.first))
        #expect(lines.rows.map(\.kind) == [.context, .context, .context, .added, .added])
        #expect(lines.rows.map(\.text) == ["a", "", "\tb", "", "\t\tc"])
        #expect(lines.counts == ChangeCounts(added: 2, removed: 0))
        #expect(lines.counts?.text == "+2 \u{2212}0")
    }

    @Test func aCarriageReturnIsComparedAndNotDrawn() throws {
        let lines = try #require(Self.lines(Self.changes([Self.part(old: "a\r\nb\r\n", new: "a\nb\n")]).blocks.first))
        #expect(lines.counts == ChangeCounts(added: 2, removed: 2))
        #expect(lines.rows.map(\.text) == ["a", "b", "a", "b"])
    }

    // MARK: Context

    @Test func unchangedLinesAroundAChangeAreContextAndTheRestIsAGap() throws {
        let old = (1...30).map { "line \($0)" }
        var new = old
        new[4] = "five"
        new[24] = "twenty-five"
        let lines = try #require(Self.lines(Self.changes([Self.part(old: old.joined(separator: "\n") + "\n",
                                                                    new: new.joined(separator: "\n") + "\n")]).blocks.first))
        #expect(lines.counts == ChangeCounts(added: 2, removed: 2))
        // Four lines lead: three of context, and a gap of one is drawn as its line.
        #expect(lines.rows.prefix(6).map(\.text) == ["line 1", "line 2", "line 3", "line 4", "line 5", "five"])
        #expect(lines.rows.filter { $0.kind == .gap }.map(\.count) == [13, 2])
        #expect(lines.rows.count == 19)
        #expect(lines.rows.filter { $0.kind == .context }.count == 13)
        #expect(lines.undrawn == 0 && lines.clipped == 0)
    }

    @Test func aRemovedLineBetweenUnchangedLines() throws {
        let old = (1...20).map { "line \($0)" }
        var new = old
        new[9] = "ten"
        new.remove(at: 17)
        let lines = try #require(Self.lines(Self.changes([Self.part(old: old.joined(separator: "\n"),
                                                                    new: new.joined(separator: "\n"))]).blocks.first))
        #expect(lines.counts == ChangeCounts(added: 1, removed: 2))
        #expect(lines.rows.map(\.kind) == [.gap, .context, .context, .context, .removed, .added]
                + Array(repeating: .context, count: 7) + [.removed, .context, .context])
        #expect(lines.rows.first?.count == 6)
    }

    // MARK: Creation, removal and nothing

    @Test func anOmittedOrNullOldTextIsANewFile() throws {
        let omitted = Self.changes([Self.part(old: nil, new: "one\ntwo\n")])
        #expect(omitted.blocks.first?.isNewFile == true)
        #expect(Self.lines(omitted.blocks.first)?.rows.map(\.kind) == [.added, .added])
        #expect(omitted.counts == ChangeCounts(added: 2, removed: 0))

        var part = Self.part(old: nil, new: "one\ntwo\n")
        part["oldText"] = NSNull()
        #expect(Self.changes([part]) == omitted)

        // An empty old text is known and empty: the same lines, and not called a new file.
        let empty = Self.changes([Self.part(old: "", new: "one\ntwo\n")])
        #expect(empty.blocks.first?.isNewFile == false && empty.counts == omitted.counts)
    }

    @Test func anEmptyNewTextRemovesEveryLine() throws {
        let changes = Self.changes([Self.part(old: "a\nb\n", new: "")])
        #expect(Self.lines(changes.blocks.first)?.rows == [ChangeRow(kind: .removed, text: "a"), ChangeRow(kind: .removed, text: "b")])
        #expect(changes.counts == ChangeCounts(added: 0, removed: 2))
    }

    @Test func aWholeBlockWithNoChangedLineIsSaidAndHasNoWell() throws {
        let created = Self.changes([Self.part(old: nil, new: "")])
        #expect(Self.lines(created.blocks.first)?.outcome == .empty)
        #expect(ResultChangeBlock.sentence(created.blocks[0]) == "The new file is empty.")
        let empty = Self.changes([Self.part(old: "", new: "")])
        #expect(ResultChangeBlock.sentence(empty.blocks[0]) == "The provider's diff for this edit is empty.")
        let same = Self.changes([Self.part(old: "a\n", new: "a\n")])
        #expect(Self.lines(same.blocks.first)?.outcome == .identical)
        #expect(ResultChangeBlock.sentence(same.blocks[0]) == "The text is the same before and after this edit.")
        let ending = Self.changes([Self.part(old: "a\n", new: "a")])
        #expect(Self.lines(ending.blocks.first)?.outcome == .lineEnding)
        #expect(ResultChangeBlock.sentence(ending.blocks[0]) == "Only the end of the last line changed.")
        for changes in [created, empty, same, ending] {
            // Zero is known, and no row is kept for a well.
            #expect(changes.counts == ChangeCounts(added: 0, removed: 0))
            #expect(Self.lines(changes.blocks.first)?.rows.isEmpty == true)
            #expect(changes.hasDrawableBlock)
        }
        #expect(ResultChangeBlock.sentence(Self.changes([Self.part()]).blocks[0]) == nil)
    }

    // MARK: Absent and malformed

    @Test func contentWithNoTypedDiffHoldsNoChange() throws {
        #expect(try Self.record(content: nil).resultChanges == nil)
        #expect(try Self.record(content: "").resultChanges == nil)
        // A part that is not typed `diff`, an object in place of the list, and text about a diff.
        let text: [String: Any] = ["type": "content", "content": ["type": "text", "text": "diff --git a/x b/x\n-old\n+new"]]
        #expect(try Self.record(content: Self.content([text])).resultChanges == nil)
        #expect(try Self.record(content: Self.content([["type": "Diff", "path": "/a", "newText": "x"]])).resultChanges == nil)
        #expect(try Self.record(content: #"{"type":"diff","path":"/a","newText":"x"}"#).resultChanges == nil)
        #expect(try Self.record(content: "diff --git a/x b/x").resultChanges == nil)
        // A record that is not a tool call.
        let thought = ToolDetailRecord(key: "m1", kind: "thought", content: Self.content([Self.part()]))
        #expect(thought.resultChanges == nil)
        // With no changes, an edit with no result text keeps its sentence.
        let selection = ResultShape.select(tool: "Edit", payload: ResultPayload.read("", cut: .unrecorded), resultText: "", failed: false)
        #expect(selection.shape == .empty(ResultChanges.absentSentence))
        #expect(!ActivityResultView.isAbsentDiff(selection, changes: nil))
        #expect(ActivityResultView.isAbsentDiff(selection, changes: Self.changes([Self.part()])))
    }

    @Test func aDiffPartThatIsNotTheFormIsUnreadNotGuessed() throws {
        let malformed: [[String: Any]] = [
            ["type": "diff", "path": Self.path, "oldText": "a"],
            ["type": "diff", "path": Self.path, "newText": 7],
            ["type": "diff", "path": Self.path, "newText": "b", "oldText": ["a"]],
            ["type": "diff", "path": "", "newText": "b"],
            ["type": "diff", "newText": "b"],
            ["type": "diff", "path": Self.path, "newText": "b", "patch": "@@"],
        ]
        for part in malformed {
            let changes = Self.changes([part])
            #expect(changes.blocks.isEmpty && changes.unread == 1 && changes.counts == nil && !changes.isEmpty)
            #expect(!changes.hasDrawableBlock)
        }
        // A repeated key names two values: neither is chosen.
        let repeated = ResultChanges.read(content: #"[{"type":"diff","path":"/a","newText":"x","newText":"y"}]"#)
        #expect(repeated.blocks.isEmpty && repeated.unread == 1)
        // `_meta` is the protocol's own extension member.
        var meta = Self.part()
        meta["_meta"] = ["source": "claude"]
        #expect(Self.changes([meta]).counts == ChangeCounts(added: 3, removed: 1))
        // One unread part leaves the call's counts out, and the whole block is still drawn.
        let mixed = Self.changes([Self.part(), malformed[0]])
        #expect(mixed.blocks.count == 1 && mixed.unread == 1 && mixed.counts == nil && mixed.hasDrawableBlock)
        #expect(ResultChangeList.unreadSentence(1) == "The provider's diff for this edit could not be read.")
    }

    // MARK: Several parts

    @Test func otherPartsOfTheListAreLeftAlone() throws {
        let text: [String: Any] = ["type": "content", "content": ["type": "text", "text": "Updated the lease."]]
        let terminal: [String: Any] = ["type": "terminal", "terminalId": "term-1"]
        let stored = Self.content([text, Self.part(), terminal])
        let record = try Self.record(content: stored)
        #expect(record.resultChanges?.blocks.count == 1)
        #expect(record.resultChanges?.counts == ChangeCounts(added: 3, removed: 1))
        // The stored text is not changed, and it is not taken for an image result.
        #expect(record.content == stored && record.resultImages == nil)
    }

    @Test func severalBlocksAreDrawnInOrderAndTheSameBlockOnce() throws {
        let other = Self.part("/repo/internal/service/lease_test.go", old: "a\n", new: "a\nb\n")
        let two = Self.changes([Self.part(), other])
        #expect(two.blocks.map(\.path) == [Self.path, "/repo/internal/service/lease_test.go"])
        #expect(two.blocks.map(\.counts) == [ChangeCounts(added: 3, removed: 1), ChangeCounts(added: 1, removed: 0)])
        #expect(two.counts == ChangeCounts(added: 4, removed: 1))
        // The same block held twice is one block; a second edit of the same file is its own.
        #expect(Self.changes([Self.part(), Self.part()]) == Self.changes([Self.part()]))
        let again = Self.changes([Self.part(), Self.part(old: Self.after, new: Self.before)])
        #expect(again.blocks.count == 2 && again.counts == ChangeCounts(added: 4, removed: 4))
    }

    // MARK: Shortened

    @Test func aBlockTheServiceShortenedIsNotCompared() throws {
        let cut = Self.part(new: "func (l *lease) renewAt() time.Time {\n\thalf := l.exp" + PrettyJSON.storedMark)
        let other = Self.part("/repo/b.go", old: "a\n", new: "b\n")
        let record = try Self.record(content: Self.content([cut, other]), truncated: ["content"], shortened: ["content": ["/0/newText"]])
        let changes = try #require(record.resultChanges)
        #expect(changes.blocks.map(\.state) == [.shortened, Self.changes([other]).blocks[0].state])
        // The path was not the string cut, so it is named. The call's counts are left out.
        #expect(changes.blocks[0].path == Self.path && changes.blocks[0].counts == nil)
        #expect(changes.counts == nil)
        #expect(Self.edit(record).step.change == nil)

        let pathCut = try Self.record(content: Self.content([cut]), truncated: ["content"],
                                      shortened: ["content": ["/0/path", "/0/newText"]])
        #expect(pathCut.resultChanges?.blocks == [ChangeBlock(path: nil, state: .shortened)])
    }

    @Test func aTextCutAtItsEndLeavesItsLastBlockOut() throws {
        let whole = Self.content([Self.part("/repo/a.go", old: "x\n", new: "y\n")])
        let stored = String(whole.dropLast()) + #",{"type":"diff","path":"/repo/b.go","oldText":"1\n","newText":"2 and mo"# + PrettyJSON.storedMark
        let record = try Self.record(content: stored, truncated: ["content"], shortened: ["content": [""]])
        let changes = try #require(record.resultChanges)
        #expect(changes.blocks.count == 2)
        #expect(changes.blocks[0].path == "/repo/a.go" && changes.blocks[0].counts == ChangeCounts(added: 1, removed: 1))
        #expect(changes.blocks[1] == ChangeBlock(path: nil, state: .shortened))
        #expect(changes.counts == nil)
    }

    @Test func aCutTheRecordDoesNotLocateLeavesEveryBlockOut() throws {
        let record = try Self.record(content: Self.content([Self.part(), Self.part("/repo/b.go", old: "a\n", new: "b\n")]),
                                     truncated: ["content"])
        #expect(record.resultChanges?.blocks == [ChangeBlock(path: nil, state: .shortened), ChangeBlock(path: nil, state: .shortened)])
        #expect(record.resultChanges?.counts == nil && record.resultChanges?.hasDrawableBlock == false)
    }

    @Test func aWholeTextThatEndsInTheMarkIsLiteral() throws {
        let record = try Self.record(content: Self.content([Self.part(old: "a\n", new: "a" + PrettyJSON.storedMark + "\n")]))
        let lines = try #require(Self.lines(record.resultChanges?.blocks.first))
        #expect(lines.rows == [ChangeRow(kind: .removed, text: "a"), ChangeRow(kind: .added, text: "a" + PrettyJSON.storedMark)])
        #expect(lines.counts == ChangeCounts(added: 1, removed: 1))
    }

    // MARK: Bounds

    @Test func aChangePastTheEditBoundIsDrawnCoarselyWithoutCounts() throws {
        let old = (0..<600).map { "a \($0)" }.joined(separator: "\n"), new = (0..<600).map { "b \($0)" }.joined(separator: "\n")
        let changes = Self.changes([Self.part(old: old, new: new)])
        let lines = try #require(Self.lines(changes.blocks.first))
        #expect(lines.isCoarse && lines.counts == nil && changes.counts == nil)
        #expect(lines.rows.count == 400 && lines.rows.allSatisfy { $0.kind == .removed })
        #expect(lines.undrawn == 800)
        #expect(ResultChangeBlock.notes(lines) == ["800 more changed lines are not drawn."])
    }

    @Test func theBoundsOnLinesRowsCharactersAndBlocksHold() throws {
        let fifty = (0..<50).map { "n \($0)" }.joined(separator: "\n")
        #expect(Self.changes([Self.part(old: nil, new: fifty)], limits: .init(lines: 5)).blocks.first?.state == .tooLong)

        let capped = try #require(Self.lines(Self.changes([Self.part(old: nil, new: fifty)], limits: .init(rows: 10)).blocks.first))
        // The rows are bounded; the counts are still of the whole change.
        #expect(capped.rows.count == 10 && capped.undrawn == 40 && capped.counts == ChangeCounts(added: 50, removed: 0))

        let clipped = try #require(Self.lines(Self.changes([Self.part(old: nil, new: "abcdefghij\n")],
                                                           limits: .init(lineCharacters: 5)).blocks.first))
        #expect(clipped.rows == [ChangeRow(kind: .added, text: "abcde")] && clipped.clipped == 1)
        #expect(ResultChangeBlock.notes(clipped) == ["1 long line is cut short here."])

        let bounded = Self.changes([Self.part(), Self.part("/repo/b.go", old: "a\n", new: "b\n")], limits: .init(blocks: 1))
        #expect(bounded.blocks.count == 1 && bounded.undrawn == 1 && bounded.counts == nil)
        #expect(ResultChangeList.undrawnSentence(1) == "1 more change is not shown.")

        #expect(ResultChanges.read(content: Self.content([Self.part()]), limits: .init(textBytes: 16)).isEmpty)
    }

    /// The comparison against a plain longest-common-subsequence table, over many small inputs.
    @Test func theLineComparisonIsShortestAndRebuildsTheNewText() throws {
        func common(_ a: [Int32], _ b: [Int32]) -> Int {
            var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in 0..<a.count { for j in 0..<b.count {
                table[i + 1][j + 1] = a[i] == b[j] ? table[i][j] + 1 : max(table[i][j + 1], table[i + 1][j])
            } }
            return table[a.count][b.count]
        }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<400 {
            let a = (0..<next(12)).map { _ in Int32(next(4)) }, b = (0..<next(12)).map { _ in Int32(next(4)) }
            let script = try #require(LineDiff.script(a, b, maxEdits: 64))
            var rebuilt: [Int32] = [], oldAt = 0, newAt = 0
            for edit in script {
                switch edit {
                case .same: #expect(a[oldAt] == b[newAt]); rebuilt.append(a[oldAt]); oldAt += 1; newAt += 1
                case .removed: oldAt += 1
                case .added: rebuilt.append(b[newAt]); newAt += 1
                }
            }
            #expect(rebuilt == b && oldAt == a.count)
            #expect(script.filter { $0 != .same }.count == a.count + b.count - 2 * common(a, b))
        }
        #expect(LineDiff.script([1, 2, 3], [1, 3], maxEdits: 8) == [.same, .removed, .same])
        #expect(LineDiff.script([], [1, 2], maxEdits: 8) == [.added, .added])
        #expect(LineDiff.script([1, 2], [], maxEdits: 8) == [.removed, .removed])
        #expect(LineDiff.script([], [], maxEdits: 8) == [])
        // Removed lines come before added lines within one run of changes.
        #expect(LineDiff.script([1, 2, 9], [3, 4, 9], maxEdits: 8) == [.removed, .removed, .added, .added, .same])
        // Past the bound there is no script, and none when the bound is nothing.
        #expect(LineDiff.script([1], [2], maxEdits: 1) == nil)
        #expect(LineDiff.script([1], [2], maxEdits: 0) == nil)
        #expect(LineDiff.script([1], [1], maxEdits: 0) == [.same])
    }

    // MARK: The sentence

    @Test func aFinishedEditGainsItsCountsOnceItsRecordIsRead() throws {
        let record = try Self.record(content: Self.content([Self.part()]))
        let (entry, step) = Self.edit(record)
        #expect(step.sentence.plain == "Edited lease.go" && step.state == .done)
        #expect(step.change == ChangeCounts(added: 3, removed: 1))
        #expect(step.accessibilityLabel == "Edited lease.go, 3 lines added, 1 line removed")
        let source = ActivityResultSource(entry: entry, step: step, record: record)
        #expect(source.changes == record.resultChanges)
        // Source keeps the stored result text exactly.
        #expect(source.resultText == Self.updated)

        // Until the record is read, and for an edit with no diff, there are no counts.
        #expect(Self.edit(nil).step.change == nil)
        let noDiff = try Self.record(content: nil)
        #expect(Self.edit(noDiff).step.change == nil)
        // A whole block with no changed line is a known zero.
        let same = try Self.record(content: Self.content([Self.part(old: "a\n", new: "a\n")]))
        #expect(Self.edit(same).step.change == ChangeCounts(added: 0, removed: 0))
    }

    @Test func aFailedOrRunningEditHasNoCounts() throws {
        let record = try Self.record(content: Self.content([Self.part()]))
        let failed = Self.edit(record, result: "", error: "String to replace not found in file.")
        #expect(failed.step.state == .failed && failed.step.change == nil && failed.step.failure != nil)
        let running = Self.edit(record, result: nil)
        #expect(running.step.state == .running && running.step.change == nil)
        // The proposed change is still in hand for the opened line while the call runs.
        #expect(ActivityResultSource(entry: running.entry, step: running.step, record: record).changes != nil)
    }

    @MainActor @Test func theStoreComparesARecordOnceWhenItKeepsIt() throws {
        let record = try Self.record(content: Self.content([Self.part()]))
        #expect(record.changes == nil)
        let store = ToolDetailStore(summaries: [:], records: ["w": [record]])
        let kept = try #require(store.record(worker: "w", key: "call-w:1"))
        #expect(kept.changes == record.resultChanges && kept.content == record.content)
        // A record with no diff keeps the answer too, so it is not compared again.
        let noDiff = try Self.record(content: nil)
        let plain = ToolDetailStore.kept(noDiff)
        #expect(plain.changes == ResultChanges.none && plain.resultChanges == nil)
    }

    // MARK: Review edges

    @Test func contentThatEndsEarlyAfterAWholeDiffHasNoTotalCounts() throws {
        let whole = Self.content([Self.part()])
        let stored = String(whole.dropLast()) + #",{"type":"content","content":{"type":"text","text":"Updated the le"# + PrettyJSON.storedMark
        let record = try Self.record(content: stored, truncated: ["content"], shortened: ["content": [""]])
        let changes = try #require(record.resultChanges)
        // The whole block is still drawn with its own lines; the call's total is not claimed.
        #expect(changes.blocks.count == 1 && changes.blocks[0].counts == ChangeCounts(added: 3, removed: 1))
        #expect(changes.endsEarly && changes.counts == nil && ResultChangeList.saysEndsEarly(changes))
        #expect(Self.edit(record).step.change == nil)
        // The same text with no record of the cut still ends early.
        #expect(ResultChanges.read(content: stored).counts == nil)

        // A string shortened inside another part, by its path, leaves the diff exact.
        let text: [String: Any] = ["type": "content", "content": ["type": "text", "text": "Updated" + PrettyJSON.storedMark]]
        let local = try Self.record(content: Self.content([Self.part(), text]), truncated: ["content"],
                                    shortened: ["content": ["/1/content/text"]])
        #expect(local.resultChanges?.counts == ChangeCounts(added: 3, removed: 1))
        let saysEndsEarly = local.resultChanges.map { ResultChangeList.saysEndsEarly($0) }
        #expect(saysEndsEarly == false)
    }

    /// The lines of a conversation's groups, with the stored records given by call ID.
    static func groupLines(_ wire: Wire, records: [String: ToolDetailRecord]) -> [ActivityStep] {
        let items = ActivityConversation.items(ConversationActivity.items(TranscriptEntry.displayed(wire.entries, mode: .pretty)),
                                               facts: ActivityFacts(summaries: [:], records: records))
        var lines: [ActivityStep] = []
        for item in items { if case .group(let group) = item { lines += group.lines } }
        return lines
    }

    @Test func editsFoldedIntoOneLineSumTheirCountsOrHaveNone() throws {
        var wire = Wire()
        let first = wire.call("Edit", detail: Self.path, result: "updated")
        let second = wire.call("Edit", detail: Self.path, result: "updated")
        let exact = try Self.record(content: Self.content([Self.part()]), key: first)
        let other = try Self.record(content: Self.content([Self.part(old: "a\n", new: "a\nb\n")]), key: second)
        let both = Self.groupLines(wire, records: [first: exact, second: other])
        #expect(both.count == 1 && both.first?.count == 2)
        #expect(both.first?.change == ChangeCounts(added: 4, removed: 1))

        // One edit of the line has no exact counts: the line has none, whichever edit it is.
        let noDiff = try Self.record(content: nil, key: second)
        #expect(Self.groupLines(wire, records: [first: exact, second: noDiff]).first?.change == nil)
        #expect(Self.groupLines(wire, records: [first: exact]).first?.change == nil)
        #expect(Self.groupLines(wire, records: [second: other]).first?.change == nil)
        #expect(Self.groupLines(wire, records: [first: exact, second: noDiff]).first?.count == 2)
    }

    @Test func anInterruptedEditIsNotCountedAsFinished() throws {
        let record = try Self.record(content: Self.content([Self.part()]))
        let interrupted = Self.edit(record, result: "", error: "Tool interrupted")
        #expect(ToolStatus(result: ToolResult(output: "", error: "Tool interrupted")) == .interrupted)
        #expect(interrupted.step.change == nil)
    }

    @Test func aResultThatNamesItsCallByExactIDTakesThatCallsDiff() throws {
        var wire = Wire()
        wire.messages.append(AGUIMessage(id: "m-1", role: "tool", content: "updated", toolCallID: "toolu_edit"))
        wire.messages.append(AGUIMessage(id: "m-2", role: "tool", content: "updated"))
        wire.messages.append(AGUIMessage(id: "m-3", role: "tool", content: "", toolCallID: "toolu_fail", error: "No such file."))
        let entries = wire.entries
        let record = try Self.record(content: Self.content([Self.part()]), key: "toolu_edit")
        let facts = ActivityFacts(summaries: ["toolu_edit": ToolDetailSummary(key: "toolu_edit", kind: "tool", name: "Edit"),
                                              "toolu_fail": ToolDetailSummary(key: "toolu_fail", kind: "tool", name: "Edit")],
                                  records: ["toolu_edit": record, "toolu_fail": record])
        let named = try #require(ActivitySteps.step(orphan: entries[0], facts: facts))
        #expect(named.change == ChangeCounts(added: 3, removed: 1))
        let source = ActivityResultSource(entry: entries[0], step: named, record: record, summary: facts.summary("toolu_edit"))
        #expect(source.changes == record.resultChanges)

        // A result with no ID takes nothing, even handed the record.
        let bare = try #require(ActivitySteps.step(orphan: entries[1], facts: facts))
        #expect(bare.kind == .orphanResult && bare.change == nil)
        #expect(ActivityResultSource(entry: entries[1], step: bare, record: record).changes == nil)
        // A failed result has no counts.
        let failed = try #require(ActivitySteps.step(orphan: entries[2], facts: facts))
        #expect(failed.state == .failed && failed.change == nil)
    }

    @Test func aDiffStandsInOnlyForAnEditsOwnResultText() throws {
        let diff = Self.changes([Self.part()])
        #expect(ActivityResultView.replacesBody(ResultShape.Selection(shape: .change), changes: diff))
        // A structured result keeps its body and its More fields beside the change.
        #expect(!ActivityResultView.replacesBody(ResultShape.Selection(shape: .generic, remaining: ["extra"]), changes: diff))
        #expect(!ActivityResultView.replacesBody(ResultShape.Selection(shape: .change), changes: nil))
        let shortened = ResultChanges(blocks: [ChangeBlock(path: nil, state: .shortened)], unread: 0, undrawn: 0)
        #expect(!ActivityResultView.replacesBody(ResultShape.Selection(shape: .change), changes: shortened))

        // A record whose result is an image and whose content is a diff keeps both.
        let image = ResultImageTests.list(ResultImageTests.resultPart(ResultImageTests.encoded(ResultImageTests.plum)))
        let record = ToolDetailRecord(key: "call-w:1", kind: "tool", name: "Edit", result: image, content: Self.content([Self.part()]))
        let (entry, step) = Self.edit(record)
        let source = ActivityResultSource(entry: entry, step: step, record: record)
        #expect(source.images?.images == [ResultImageTests.plum])
        #expect(source.changes?.counts == ChangeCounts(added: 3, removed: 1))
    }

    @Test func twoSpellingsOfOneCharacterAreAChange() throws {
        let composed = "caf\u{E9}\n", decomposed = "cafe\u{301}\n"
        // Swift calls the two strings equal; their bytes differ.
        #expect(composed == decomposed && Array(composed.utf8) != Array(decomposed.utf8))
        let changes = Self.changes([Self.part(old: composed, new: decomposed)])
        #expect(Self.lines(changes.blocks.first)?.outcome == .changed)
        #expect(changes.counts == ChangeCounts(added: 1, removed: 1))
        // Nor are two blocks that differ only so taken for one block.
        let two = Self.changes([Self.part(old: nil, new: composed), Self.part(old: nil, new: decomposed)])
        #expect(two.blocks.count == 2 && two.counts == ChangeCounts(added: 2, removed: 0))
    }

    // MARK: Drawn lines

    @Test func drawnLinesCarryTheirSignAndHideSecretsOnlyWhenAsked() throws {
        // An ordinary value: the key beside it is what marks it as one to hide.
        let marker = "qa"
        let rows = [ChangeRow(kind: .gap, count: 13), ChangeRow(kind: .context, text: "\tkeep"),
                    ChangeRow(kind: .removed, text: "key = old"), ChangeRow(kind: .added, text: "\ttoken=" + marker)]
        let plain = ResultChangeBlock.wellLines(rows, hidesSecrets: false)
        #expect(plain.hidden == 0)
        #expect(plain.lines == [
            ResultWell.Line(number: "", text: "13 unchanged lines", tone: .note),
            ResultWell.Line(number: "", text: "\tkeep"),
            ResultWell.Line(number: "\u{2212}", text: "key = old", tone: .removed),
            ResultWell.Line(number: "+", text: "\ttoken=" + marker, tone: .added),
        ])
        let masked = ResultChangeBlock.wellLines(rows, hidesSecrets: true)
        #expect(masked.hidden == 1)
        #expect(!masked.lines[3].text.contains(marker) && masked.lines[3].text.hasPrefix("\ttoken="))
        #expect(masked.lines[3].tone == .added && Array(masked.lines.prefix(3)) == Array(plain.lines.prefix(3)))
        // A line that is whole JSON stays one drawn line.
        let json = ResultChangeBlock.wellLines([ChangeRow(kind: .added, text: #"{"token": "\#(marker)", "name": "relay"}"#)], hidesSecrets: true)
        #expect(json.hidden == 1 && !json.lines[0].text.contains(marker) && !json.lines[0].text.contains(where: \.isNewline))
    }
}

/// A headless picture of the opened edit line, on the focused worker and a wall tile. Skipped
/// unless PRETTY_RENDER_DIR names a folder:
///
///     PRETTY_RENDER_DIR=/tmp/pretty swift test --filter ResultChangeRender
@MainActor @Suite struct ResultChangeRenderTests {
    static func turn() throws -> (entries: [TranscriptEntry], details: ToolDetailStore) {
        var wire = Wire()
        wire.user("Renew the lease earlier, and show me the change.")
        let edit = wire.call("Edit", detail: ResultChangeTests.path, result: "The file \(ResultChangeTests.path) has been updated.")
        let write = wire.call("Write", detail: "/repo/internal/service/clock.go", result: "File created.")
        wire.say("The lease now renews at half its lifetime.")
        let old = (200...230).map { "\t// line \($0)" }
        var new = old
        new[4] = "\thalf := l.expires.Sub(l.granted) / 2"
        new.insert("\t// renew at half the lifetime", at: 5)
        new[26] = "\treturn l.granted.Add(half)"
        let records = [
            try ResultChangeTests.record(content: ResultChangeTests.content([
                ResultChangeTests.part(),
                ResultChangeTests.part("/repo/internal/service/lease_test.go", old: old.joined(separator: "\n") + "\n",
                                       new: new.joined(separator: "\n") + "\n"),
            ]), key: edit),
            try ResultChangeTests.record(content: ResultChangeTests.content([
                ResultChangeTests.part("/repo/internal/service/clock.go", old: nil,
                                       new: "package service\n\nimport \"time\"\n\n// Clock tells the time.\ntype Clock interface {\n\tNow() time.Time\n}\n"),
            ]), result: "File created.", key: write),
        ]
        return (wire.entries, ToolDetailStore(summaries: [:], records: ["c": records]))
    }

    @Test(.enabled(if: prettyRenderDirectory != nil)) func drawsTheOpenedEditLine() async throws {
        let folder = URL(fileURLWithPath: try #require(prettyRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let turn = try Self.turn()
        let open = PrettyRenderTests.kitchenOpenIDs(turn.entries, turn.details)
        for (name, density, size) in [("pretty-change-focused", PrettyDensity.regular, CGSize(width: 800, height: 1100)),
                                      ("pretty-change-tile", .compact, CGSize(width: 440, height: 1100))] {
            try await ShellRenderTests.write(
                PrettyRenderTests.console(turn.entries, density: density, coordinator: false, open: open, size: size, details: turn.details),
                name, theme: .console, to: folder, size: size)
        }
    }
}
