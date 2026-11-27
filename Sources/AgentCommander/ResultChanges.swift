import Foundation
import SwiftUI

// RESULT CHANGES
// The typed ACP `diff` blocks a stored tool record holds, for the opened Pretty line's change well
// and the counts beside its sentence (DESIGN.md, "Pretty transcript", "Change"; spec sections E
// and H, "ACP tool content `diff`"). The service keeps a call's ACP tool content as sent, in the
// record's `content`, and serves it only on the owner socket:
//
//   content   [{"type":"diff","path":"/abs/file","oldText":"…","newText":"…"}, …]
//
//   Values         ChangeCounts          lines added and removed, exact
//                  ChangeRow             one drawn line: unchanged, added, removed, or a gap
//                  ChangeLines           one block compared: its rows, counts and outcome
//                  ChangeBlock           one diff block: its path and what can be said of it
//                  ResultChanges         every diff block of one record, with total counts
//   Feature layer  LineDiff              the bounded line comparison
//   Atom           ChangeCountsText      "+3 −1" in the working and failure inks
//   Molecules      ResultChangeBlock     the path, then the lines in a `ResultWell`
//                  ResultChangeList      every block of one call, in the order sent
//
// What is read, and what is not:
//
// - Only a list part whose `type` is exactly `diff`. `newText` must be a string and may be empty.
//   `oldText` may be a string, null or absent; null and absent are a new file. Any other key but
//   `_meta`, a repeated key or a wrong type makes the part unreadable, and it is said so.
// - Other parts of the same list are left to their own renderers. The stored text is not changed.
// - Lines are compared as sent: tabs, spaces and blank lines are kept, and a line is split only at
//   a line feed. No file is read, no address followed, and no current file is consulted.
// - The record holds no file line numbers (`oldText` may be a fragment), so none are drawn.
// - Counts are exact or absent. A block the service shortened, a part that could not be read, a
//   block past a bound and a comparison that passed its bound all leave the counts out.

// MARK: - Values

/// The lines one call added and removed. Zero is a count, not an absence.
struct ChangeCounts: Equatable, Sendable {
    var added: Int
    var removed: Int

    /// "+3 −1", with a true minus sign as the approved mockup has it.
    var text: String { "+\(added) \u{2212}\(removed)" }
    var spoken: String {
        ActivityWords.count(added, "line") + " added, " + ActivityWords.count(removed, "line") + " removed"
    }
}

struct ChangeRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, added, removed, gap }

    let kind: Kind
    /// The line as sent, without its line ending. Empty for a gap.
    var text = ""
    /// A gap's unchanged lines that are not drawn.
    var count = 0
}

/// One block whose two texts are whole, compared line by line.
struct ChangeLines: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case changed
        /// Both texts hold no line.
        case empty
        /// The two texts are the same, and hold lines.
        case identical
        /// Every line is the same; only the end of the last line differs.
        case lineEnding
    }

    var outcome: Outcome
    /// The drawn lines, within the row bound. Empty unless the outcome is `changed`.
    var rows: [ChangeRow] = []
    /// Exact, or nil when the comparison passed its bound and fell back to "all removed, then
    /// all added": that is a true account of the change, but not the shortest one.
    var counts: ChangeCounts?
    /// Changed lines past the row bound.
    var undrawn = 0
    /// Drawn lines cut at the character bound.
    var clipped = 0

    var isCoarse: Bool { outcome == .changed && counts == nil }
}

struct ChangeBlock: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case lines(ChangeLines)
        /// The service shortened this block before storing it. Its lines are not compared.
        case shortened
        /// One side holds more lines than the bound. It is not compared.
        case tooLong
    }

    /// The provider's path, as sent. Nil only when a shortened block's path could not be read.
    let path: String?
    /// The block holds no `oldText`, or a null one: the provider reports a new file.
    var isNewFile = false
    let state: State

    var counts: ChangeCounts? {
        if case .lines(let lines) = state { lines.counts } else { nil }
    }
}

struct ResultChanges: Equatable, Sendable {
    /// Bounds on what is read, compared and drawn. The service caps one stored value at 512 KB.
    struct Limits: Sendable {
        /// Bytes of record text considered.
        var textBytes = 2 << 20
        /// Parts of the list looked at.
        var parts = 64
        /// Diff blocks compared and drawn.
        var blocks = 8
        /// Lines on one side of one block.
        var lines = 50_000
        /// Lines left to compare once the shared start and end are set aside, both sides together.
        var compared = 20_000
        /// Added and removed lines the comparison may find.
        var edits = 500
        /// Unchanged lines drawn on each side of a change.
        var context = 3
        /// Rows kept for one block.
        var rows = 400
        /// Characters of one drawn line.
        var lineCharacters = 2_000
    }

    static let none = ResultChanges(blocks: [], unread: 0, undrawn: 0)
    /// The sentence of an edit whose record holds no diff (spec section E, "Change").
    static let absentSentence = "The provider sent no diff for this edit."

    /// The distinct diff blocks, in the order sent. The same block held twice is one block.
    var blocks: [ChangeBlock]
    /// Parts typed `diff` that are not the form.
    var unread: Int
    /// Diff parts past the block or part bound.
    var undrawn: Int
    /// The stored text ends before the list does, whatever kind its last part is: parts after
    /// the cut, diff parts among them, may be missing.
    var endsEarly = false

    var isEmpty: Bool { blocks.isEmpty && unread == 0 && undrawn == 0 }

    /// The call's lines added and removed, only when the whole list was kept and every diff
    /// part in it was read, compared exactly and none was left out.
    var counts: ChangeCounts? {
        guard !blocks.isEmpty, unread == 0, undrawn == 0, !endsEarly else { return nil }
        var total = ChangeCounts(added: 0, removed: 0)
        for block in blocks {
            guard let counts = block.counts else { return nil }
            total.added += counts.added
            total.removed += counts.removed
        }
        return total
    }

    /// Whether any block has lines or a sentence of its own to draw.
    var hasDrawableBlock: Bool {
        blocks.contains { if case .lines = $0.state { true } else { false } }
    }

    /// The diff blocks of one stored record's `content`. `cut` is the service's account of where
    /// it shortened that text.
    static func read(content: String?, cut: StoredCut = .complete, limits: Limits = Limits()) -> ResultChanges {
        guard let content else { return .none }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // A cheap test before any parsing: tool content is a list.
        guard text.utf8.first == UInt8(ascii: "["), text.utf8.count <= limits.textBytes,
              let reading = OrderedJSON.read(text), let items = reading.value.items else { return .none }

        var shortenedStrings: [[String]] = []
        var allShortened = false
        switch cut {
        case .complete, .unrecorded, .end: break
        // Cut somewhere the record does not say: no block is known to be whole.
        case .unlocated: allShortened = true
        case .strings(let paths): shortenedStrings = paths
        }
        // A text that ends early ends inside its last part.
        let endsEarly = reading.isCut || cut == .end

        var found = ResultChanges.none
        found.endsEarly = endsEarly
        var seen: Set<Whole> = []
        for (index, item) in items.enumerated() {
            guard item["type"]?.string == "diff" else { continue }
            guard index < limits.parts, found.blocks.count < limits.blocks else { found.undrawn += 1; continue }
            let isLastOfCutText = endsEarly && index == items.count - 1
            let cutStrings = shortenedStrings.filter { $0.first == String(index) }
            if allShortened || isLastOfCutText || !cutStrings.isEmpty {
                // The path is named only when the record says which strings were cut and the
                // path is not one of them.
                let pathIsWhole = !allShortened && !isLastOfCutText && !cutStrings.contains([String(index), "path"])
                found.blocks.append(ChangeBlock(path: pathIsWhole ? item["path"]?.string.flatMap { $0.isEmpty ? nil : $0 } : nil,
                                                state: .shortened))
                continue
            }
            guard let whole = Whole(item) else { found.unread += 1; continue }
            guard seen.insert(whole).inserted else { continue }
            found.blocks.append(ChangeBlock(path: whole.path, isNewFile: whole.old == nil,
                                            state: compare(old: whole.old ?? "", new: whole.new, limits: limits)))
        }
        return found
    }

    /// One diff part that is exactly the form. Two parts are the same only byte for byte: two
    /// spellings of one character (U+00E9, or `e` and a combining acute) are different parts.
    private struct Whole: Hashable {
        let path: String
        let old: String?
        let new: String

        static let keys: Set<String> = ["type", "path", "oldText", "newText", "_meta"]

        static func == (lhs: Whole, rhs: Whole) -> Bool {
            lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.new.utf8.elementsEqual(rhs.new.utf8)
                && (lhs.old == nil) == (rhs.old == nil) && (lhs.old ?? "").utf8.elementsEqual((rhs.old ?? "").utf8)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(path.utf8.count)
            hasher.combine(old?.utf8.count)
            hasher.combine(new.utf8.count)
        }

        init?(_ part: OrderedJSON) {
            guard let members = part.members, Set(members.map(\.key)).count == members.count,
                  members.allSatisfy({ Self.keys.contains($0.key) }),
                  let path = part["path"]?.string, !path.isEmpty, let new = part["newText"]?.string else { return nil }
            switch part["oldText"] {
            case nil, .null?: old = nil
            case .string(let text)?: old = text
            default: return nil
            }
            self.path = path
            self.new = new
        }
    }

    // MARK: Comparison

    /// One line as its bytes. Lines are compared byte for byte, so two spellings of the same
    /// character are a change.
    typealias Line = ArraySlice<UInt8>

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    /// The lines of a text, split only at a line feed. A final line feed ends the last line; it
    /// does not start an empty one. An empty text holds no line.
    static func lines(_ bytes: [UInt8]) -> [Line] {
        var lines = bytes.split(separator: lineFeed, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    static func compare(old: String, new: String, limits: Limits = Limits()) -> ChangeBlock.State {
        let oldBytes = Array(old.utf8), newBytes = Array(new.utf8)
        func lineCount(_ bytes: [UInt8]) -> Int { bytes.reduce(1) { $1 == lineFeed ? $0 + 1 : $0 } }
        guard lineCount(oldBytes) <= limits.lines + 1, lineCount(newBytes) <= limits.lines + 1 else { return .tooLong }
        let a = lines(oldBytes), b = lines(newBytes)
        if a == b {
            let outcome: ChangeLines.Outcome = oldBytes != newBytes ? .lineEnding : (a.isEmpty ? .empty : .identical)
            return .lines(ChangeLines(outcome: outcome, counts: ChangeCounts(added: 0, removed: 0)))
        }
        // The shared start and end are unchanged whatever lies between them.
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var end = 0
        while end < a.count - start, end < b.count - start, a[a.count - 1 - end] == b[b.count - 1 - end] { end += 1 }
        let oldMiddle = a[start..<(a.count - end)], newMiddle = b[start..<(b.count - end)]

        var script: [LineDiff.Edit]? = nil
        if oldMiddle.count + newMiddle.count <= limits.compared {
            var ids: [Line: Int32] = [:]
            func id(_ line: Line) -> Int32 {
                if let known = ids[line] { return known }
                let next = Int32(ids.count)
                ids[line] = next
                return next
            }
            script = LineDiff.script(oldMiddle.map(id), newMiddle.map(id), maxEdits: limits.edits)
        }
        let exact = script != nil
        // Past a bound: every line between the shared start and end, removed then added.
        let coarse = [LineDiff.Edit](repeating: .removed, count: oldMiddle.count)
            + [LineDiff.Edit](repeating: .added, count: newMiddle.count)
        let edits: [LineDiff.Edit] = script ?? coarse

        // Runs of one kind, over the whole of both texts.
        var runs: [(edit: LineDiff.Edit, count: Int)] = []
        func add(_ edit: LineDiff.Edit, _ count: Int = 1) {
            guard count > 0 else { return }
            if runs.last?.edit == edit { runs[runs.count - 1].count += count } else { runs.append((edit, count)) }
        }
        add(.same, start)
        for edit in edits { add(edit) }
        add(.same, end)

        var result = ChangeLines(outcome: .changed)
        var added = 0, removed = 0, drawnChanges = 0
        var oldAt = 0, newAt = 0
        func row(_ kind: ChangeRow.Kind, _ line: Line) {
            // A carriage return before the line feed is compared, and not drawn.
            var shown = String(decoding: line.last == carriageReturn ? line.dropLast() : line, as: UTF8.self)
            if line.count > limits.lineCharacters, shown.count > limits.lineCharacters {
                shown = String(shown.prefix(limits.lineCharacters))
                result.clipped += 1
            }
            result.rows.append(ChangeRow(kind: kind, text: shown))
        }
        func context(from: Int, count: Int) {
            for offset in 0..<count where result.rows.count < limits.rows { row(.context, a[from + offset]) }
        }
        func gap(from: Int, count: Int) {
            // One hidden line is drawn: a gap of one saves nothing.
            if count == 1 { context(from: from, count: 1) } else if count > 1, result.rows.count < limits.rows {
                result.rows.append(ChangeRow(kind: .gap, count: count))
            }
        }
        for (index, run) in runs.enumerated() {
            switch run.edit {
            case .same:
                let lead = index == 0 ? 0 : min(limits.context, run.count)
                let trail = index == runs.count - 1 ? 0 : min(limits.context, run.count - lead)
                context(from: oldAt, count: lead)
                gap(from: oldAt + lead, count: run.count - lead - trail)
                context(from: oldAt + run.count - trail, count: trail)
                oldAt += run.count
                newAt += run.count
            case .removed:
                for offset in 0..<run.count where result.rows.count < limits.rows { row(.removed, a[oldAt + offset]); drawnChanges += 1 }
                oldAt += run.count
                removed += run.count
            case .added:
                for offset in 0..<run.count where result.rows.count < limits.rows { row(.added, b[newAt + offset]); drawnChanges += 1 }
                newAt += run.count
                added += run.count
            }
        }
        result.undrawn = added + removed - drawnChanges
        result.counts = exact ? ChangeCounts(added: added, removed: removed) : nil
        return .lines(result)
    }
}

// MARK: - Feature layer

/// The shortest line-by-line account of how one text became another (Myers), within a bound.
enum LineDiff {
    enum Edit: Equatable, Sendable { case same, removed, added }

    /// The edits from `a` to `b`, in order, with each run of changes as its removed lines then its
    /// added lines. Nil when the change takes more than `maxEdits` added and removed lines; the
    /// work done before that is bounded by `maxEdits` times the lines given.
    static func script(_ a: [Int32], _ b: [Int32], maxEdits: Int) -> [Edit]? {
        let n = a.count, m = b.count
        let limit = min(n + m, max(0, maxEdits))
        let offset = limit + 1
        // The furthest old line reached on each diagonal `k` (old index minus new index) after
        // the latest round that touched it. -1 where no point inside both texts was reached.
        var reach = [Int32](repeating: -1, count: 2 * limit + 3)
        // What `reach` held before each round, over the diagonals that round reads.
        var before: [[Int32]] = []
        var rounds = -1

        /// Where round `d` enters diagonal `k`: one added line down from diagonal `k + 1`, or one
        /// removed line across from diagonal `k - 1`, whichever reaches further. A step that
        /// would leave either text is not taken. Nil when neither is possible.
        func entry(_ k: Int, _ d: Int, down: Int, right: Int) -> (x: Int, isAdded: Bool)? {
            if d == 0 { return (0, false) }
            var found: (x: Int, isAdded: Bool)? = nil
            if k < d, down >= 0, down - k <= m { found = (down, true) }
            if k > -d, right >= 0, right + 1 <= n, right + 1 > (found?.x ?? -1) { found = (right + 1, false) }
            return found
        }

        search: for d in 0...limit {
            before.append(Array(reach[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                guard let from = entry(k, d, down: Int(reach[offset + k + 1]), right: Int(reach[offset + k - 1])) else {
                    reach[offset + k] = -1
                    continue
                }
                var x = from.x, y = from.x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                reach[offset + k] = Int32(x)
                if x == n, y == m { rounds = d; break search }
            }
        }
        guard rounds >= 0 else { return nil }

        // Walk back from the end, one round at a time, by the same rule.
        var reversed: [Edit] = []
        reversed.reserveCapacity(n + m)
        var x = n, y = m
        for d in stride(from: rounds, through: 0, by: -1) {
            let held = before[d]
            func at(_ k: Int) -> Int { Int(held[k + d + 1]) }
            let k = x - y
            guard let from = entry(k, d, down: at(k + 1), right: at(k - 1)), from.x <= x else { return nil }
            while x > from.x { reversed.append(.same); x -= 1; y -= 1 }
            guard d > 0 else { break }
            if from.isAdded { reversed.append(.added); y -= 1 } else { reversed.append(.removed); x -= 1 }
        }

        // Within one run of changes, the removed lines come first.
        var edits: [Edit] = []
        edits.reserveCapacity(reversed.count)
        var removed = 0, added = 0
        func flush() {
            edits.append(contentsOf: repeatElement(.removed, count: removed))
            edits.append(contentsOf: repeatElement(.added, count: added))
            removed = 0
            added = 0
        }
        for edit in reversed.reversed() {
            switch edit {
            case .same: flush(); edits.append(.same)
            case .removed: removed += 1
            case .added: added += 1
            }
        }
        flush()
        return edits
    }
}

extension ToolDetailRecord {
    /// The diff blocks of this record's tool content, or nil when it holds none. The store reads
    /// them once when it keeps the record (`changes`); a record built elsewhere is read here.
    var resultChanges: ResultChanges? {
        guard kind == "tool" else { return nil }
        let found = changes ?? ResultChanges.read(content: content, cut: StoredCut(record: self, field: "content", isStored: true))
        return found.isEmpty ? nil : found
    }
}

// MARK: - Views

/// "+3 −1" beside an edit's sentence or a block's path: added in the working ink, removed in the
/// failure ink, in the terminal face.
struct ChangeCountsText: View {
    let counts: ChangeCounts
    let size: CGFloat

    var body: some View {
        (Text(verbatim: "+\(counts.added)").foregroundColor(Palette.working)
         + Text(verbatim: " \u{2212}\(counts.removed)").foregroundColor(Palette.failure))
            .font(Term.font(size))
            .lineLimit(1).fixedSize()
            .accessibilityLabel(counts.spoken)
    }
}

/// One diff block: its path, then its lines in the result well, or the sentence that stands for
/// them. A well is drawn only when it has lines.
struct ResultChangeBlock: View {
    let block: ChangeBlock
    let metrics: PrettyMetrics
    var hidesSecrets = false
    /// Whether the block's own counts sit beside its path: when the call holds several blocks.
    var showsCounts = false
    @State private var isRevealed = false

    /// Lines shown before "Show all".
    static let firstView = 12
    static let shortenedSentence = "Commander shortened this change before storing it, so its lines are not compared."
    static let tooLongSentence = "This change has too many lines to compare here."
    static let coarseSentence = "This change is too large to compare line by line. Its removed lines come first, then its added lines."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let path = block.path { PathText(path: path, size: metrics.detailSize - 1) }
                if block.isNewFile {
                    Text("New file").font(.system(size: metrics.detailSize - 1)).foregroundStyle(.inkSecondary)
                        .lineLimit(1).fixedSize()
                }
                if showsCounts, let counts = block.counts, Self.sentence(block) == nil {
                    ChangeCountsText(counts: counts, size: metrics.detailSize - 1)
                }
            }
            switch block.state {
            case .shortened:
                ResultTruncationBanner(text: Self.shortenedSentence, metrics: metrics)
            case .tooLong:
                ResultEmptyState(sentence: Self.tooLongSentence, metrics: metrics)
            case .lines(let lines):
                if let sentence = Self.sentence(block) { ResultEmptyState(sentence: sentence, metrics: metrics) }
                if lines.isCoarse { ResultEmptyState(sentence: Self.coarseSentence, metrics: metrics) }
                if !lines.rows.isEmpty {
                    let drawn = Self.wellLines(lines.rows, hidesSecrets: hidesSecrets && !isRevealed)
                    ResultWell(lines: drawn.lines, metrics: metrics, limit: Self.firstView)
                    ForEach(Self.notes(lines), id: \.self) { ResultEmptyState(sentence: $0, metrics: metrics) }
                    let hidden = hidesSecrets ? Self.wellLines(lines.rows, hidesSecrets: true).hidden : 0
                    if hidden > 0 {
                        HStack(spacing: 12) {
                            Text(hidden == 1 ? "1 value hidden" : "\(hidden) values hidden").foregroundStyle(.inkSecondary)
                            Button(isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
                                .buttonStyle(.plain).foregroundStyle(Palette.focus)
                                .accessibilityLabel(isRevealed ? "Hide the values" : "Reveal the hidden values")
                        }
                        .font(.system(size: metrics.detailSize))
                        .textSelection(.disabled)
                    }
                }
            }
        }
    }

    /// The sentence a block with no changed line reads as. Nil for a block with changes.
    static func sentence(_ block: ChangeBlock) -> String? {
        guard case .lines(let lines) = block.state else { return nil }
        switch lines.outcome {
        case .changed: return nil
        case .empty: return block.isNewFile ? "The new file is empty." : "The provider's diff for this edit is empty."
        case .identical: return "The text is the same before and after this edit."
        case .lineEnding: return "Only the end of the last line changed."
        }
    }

    /// What the bounds left out of a drawn block, in words.
    static func notes(_ lines: ChangeLines) -> [String] {
        var notes: [String] = []
        if lines.undrawn > 0 {
            notes.append(ActivityWords.count(lines.undrawn, "more changed line") + (lines.undrawn == 1 ? " is" : " are") + " not drawn.")
        }
        if lines.clipped > 0 {
            notes.append(ActivityWords.count(lines.clipped, "long line") + (lines.clipped == 1 ? " is" : " are") + " cut short here.")
        }
        return notes
    }

    /// The rows as the well draws them: the sign in the gutter, the line as sent. With
    /// `hidesSecrets`, a secret-looking value in a line is replaced by its hidden form; `hidden`
    /// is how many were.
    static func wellLines(_ rows: [ChangeRow], hidesSecrets: Bool) -> (lines: [ResultWell.Line], hidden: Int) {
        var hidden = 0
        let lines = rows.map { row -> ResultWell.Line in
            var text = row.text
            if hidesSecrets, row.kind != .gap {
                let masked = SecretValues.masked(prose: text)
                if masked.count > 0 {
                    hidden += masked.count
                    // A line that is whole JSON is masked as a re-indented value. A drawn line
                    // stays one line, so it is hidden whole.
                    text = masked.text.contains(where: \.isNewline) ? SecretValues.hidden(text) : masked.text
                }
            }
            switch row.kind {
            case .context: return ResultWell.Line(number: "", text: text)
            case .added: return ResultWell.Line(number: "+", text: text, tone: .added)
            case .removed: return ResultWell.Line(number: "\u{2212}", text: text, tone: .removed)
            case .gap: return ResultWell.Line(number: "", text: ActivityWords.count(row.count, "unchanged line"), tone: .note)
            }
        }
        return (lines, hidden)
    }
}

/// Every diff block of one call, in the order sent, then what could not be drawn.
struct ResultChangeList: View {
    let changes: ResultChanges
    let metrics: PrettyMetrics
    var hidesSecrets = false

    static func unreadSentence(_ count: Int) -> String {
        count == 1 ? "The provider's diff for this edit could not be read."
            : "\(count) of the provider's diffs for this edit could not be read."
    }

    static func undrawnSentence(_ count: Int) -> String {
        ActivityWords.count(count, "more change") + (count == 1 ? " is" : " are") + " not shown."
    }

    /// Said when the stored content ends early after a whole block: the counts are left out.
    static let endsEarlySentence = "Commander kept only the first part of this call's content. Later changes may be missing."

    /// Whether that sentence is drawn: the last block does not already say it was shortened.
    static func saysEndsEarly(_ changes: ResultChanges) -> Bool {
        changes.endsEarly && changes.blocks.last.map { $0.state != .shortened } ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(changes.blocks.enumerated()), id: \.offset) { _, block in
                ResultChangeBlock(block: block, metrics: metrics, hidesSecrets: hidesSecrets,
                                  showsCounts: changes.blocks.count > 1)
            }
            if changes.unread > 0 { ResultEmptyState(sentence: Self.unreadSentence(changes.unread), metrics: metrics) }
            if changes.undrawn > 0 { ResultEmptyState(sentence: Self.undrawnSentence(changes.undrawn), metrics: metrics) }
            if Self.saysEndsEarly(changes) { ResultTruncationBanner(text: Self.endsEarlySentence, metrics: metrics) }
        }
    }
}
