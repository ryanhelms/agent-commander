import Foundation

// ACTIVITY SENTENCE
// Pretty reads each tool call as one sentence in the agent's turn, and folds finished sentences
// into one summary line. Pure values; the views are in PrettyConversationViews.swift.
// Spec: design/mockups/pretty-conversation.md, sections A, B and F.
//
//   Values         ActivitySentence       the words of one line: plain, strong and monospaced parts
//                  ActivityTag            the small state tag beside a sentence
//                  ActivityFailure        Blocked or Failed, with the reason and the exact text
//                  ActivityFailureWords   the fixed table of denials Commander recognises
//                  ActivityPhrase         how a line counts in a group's summary
//                  ActivityWording        a call's running, finished, fallback and failed wording
//                  ActivityStep           one line: a call, a linked workflow, a thought, a quiet row
//                  ActivityGroup          finished lines under one summary, failures beneath
//                  ActivityReport         a reported result, drawn as quoted prose
//                  ActivityPlan           a task checklist, one per turn
//                  PrettyItem             what the Pretty conversation lays out, in order
//   Feature layer  ActivityConversation.items   groups a console's conversation items by the rules
//
// Honesty rules, as in ActivityStory.swift: a value comes from the call, its result, or the run's
// record by exact ID. Without it the sentence uses its fallback. Nothing is guessed, no time is
// measured here, and every original entry stays inside its line.

struct ActivitySentence: Equatable {
    enum Part: Equatable {
        case text(String)
        /// A named thing: a worker, a file.
        case strong(String)
        /// A value: a command, a tool's wire name, a time, an ID.
        case mono(String)
    }

    var parts: [Part]

    init(_ parts: Part...) { self.parts = parts }
    init(parts: [Part]) { self.parts = parts }
    init(_ text: String) { parts = [.text(text)] }

    var plain: String {
        parts.map { part in
            switch part {
            case .text(let text), .strong(let text), .mono(let text): text
            }
        }.joined()
    }
}

struct ActivityTag: Equatable {
    enum Tone: Equatable { case neutral, ok, wait, failure }

    let word: String
    var tone: Tone = .neutral

    static let blocked = ActivityTag(word: "Blocked", tone: .failure)
    static let failed = ActivityTag(word: "Failed", tone: .failure)

    /// States that are not plain success. A closed group names them on its summary line.
    static let unresolved: Set<String> = ["accepted", "starting", "running", "working", "queued", "waiting", "partial",
                                          "uncertain", "cancelled", "stopping", "processing"]

    var isNamedOnSummary: Bool { Self.unresolved.contains(word) }

    /// The run record's state word as a tag: as sent, lower case, underscores as spaces.
    static func state(_ word: String) -> ActivityTag {
        let shown = word.lowercased().replacingOccurrences(of: "_", with: " ")
        let tone: Tone
        switch CommanderActivityStatus(operation: word) {
        case .complete, .answered: tone = .ok
        case .failed, .declined: tone = .failure
        case .partial, .uncertain, .cancelled, .interrupted: tone = .wait
        default: tone = .neutral
        }
        return ActivityTag(word: shown, tone: tone)
    }
}

struct ActivityFailure: Equatable {
    enum Outcome: Equatable { case blocked, failed, interrupted }

    let outcome: Outcome
    /// Short plain words for a denial Commander recognises; otherwise the provider's first sentence.
    let reason: String
    /// The provider's first sentence, exactly.
    let exact: String
    /// The rest of the provider's message, written for the agent. Shown as text only.
    var rest: String? = nil

    var tag: ActivityTag {
        switch outcome {
        case .blocked: .blocked
        case .failed: .failed
        case .interrupted: ActivityTag(word: "cancelled", tone: .wait)
        }
    }
    var meaning: String {
        switch outcome {
        case .blocked: "the provider refused permission; the tool never ran"
        case .failed: "the tool ran and reported an error"
        case .interrupted: "the session ended before the tool's result was recorded"
        }
    }
}

/// The fixed table of denials (spec section F, decision 3) and known failures (section H). An
/// entry is added only for text seen in a real record, and is matched on its whole phrase.
enum ActivityFailureWords {
    static let table: [(phrase: String, words: String)] = [
        ("has been denied because Claude Code is running in don't ask mode", "Claude Code is in don't-ask mode."),
        ("permission does not match the active provider turn", "The approval was for an earlier turn."),
        ("developer holds worker input", "Someone holds input for this worker."),
        // Section H, failed results by cause. Each phrase is from a real `is_error` result.
        ("The user doesn't want to proceed with this tool use. The tool use was rejected", "You declined this."),
        ("Permission for this command was denied by a built-in Claude Code safety check", "A Claude Code safety check denied this."),
        ("Permission for this action was denied by the Claude Code auto mode classifier. Reason: [",
         "Claude Code's auto mode denied this."),
    ]

    /// Phrases with a tool name or a path in the middle: both ends must be there, in order.
    static let framed: [(start: String, end: String, words: String, outcome: ActivityFailure.Outcome)] = [
        ("PreToolUse:", " hook error: [", "A hook blocked this.", .blocked),
        ("Permission to use ", " has been denied.", "Permission to use this tool was denied.", .blocked),
        ("Claude requested permissions to write to ", " but you haven't granted it yet.", "Write permission was not granted.", .blocked),
        ("[Tool call interrupted: the session ended before this call's result was recorded", "", "Interrupted.", .interrupted),
    ]

    private static func matches(_ message: String, start: String, end: String) -> Bool {
        guard let from = message.range(of: start) else { return false }
        return end.isEmpty || message.range(of: end, range: from.upperBound..<message.endIndex) != nil
    }

    /// A shell command Claude Code ended at its time limit. The whole result, from a real
    /// `is_error` record (Bash, `sleep 2`, a 100 ms limit), was "Exit code 143", a newline, then
    /// "Command timed out after 0s". Both lines must be there whole, first and in that order, with
    /// a duration as Claude Code writes one. The exit code alone is an ordinary SIGTERM, and the
    /// phrase anywhere else is a mention.
    static let timedOut = "Timed out."
    private static let timeoutExit = "Exit code 143"
    private static let timeoutPhrase = "Command timed out after "

    static func isShellTimeout(_ message: String) -> Bool {
        let lines = message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count >= 2, lines[0] == timeoutExit, lines[1].hasPrefix(timeoutPhrase) else { return false }
        return isDuration(lines[1].dropFirst(timeoutPhrase.count))
    }

    /// "0s", "2m 0s", "1h 0m 0s": whole numbers with a unit, largest unit first, one space apart.
    private static func isDuration(_ text: Substring) -> Bool {
        let units: [Character] = ["d", "h", "m", "s"]
        var smallest = -1
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        for part in parts {
            guard let unit = part.last, let rank = units.firstIndex(of: unit), rank > smallest else { return false }
            let digits = part.dropLast()
            guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            smallest = rank
        }
        return !parts.isEmpty
    }

    /// Claude Code's Read of a missing file, as the service wrote it in a real managed ACP record:
    /// the line "Tool failed.", a bare code fence, the diagnostic, the closing fence, and nothing
    /// else. Returns the diagnostic without its fences. It is read from the output as it arrived:
    /// once lines are trimmed and repeats dropped, the closing fence is gone and the opening one
    /// reads as the first sentence. Any other text, a fence with a language, a missing or extra
    /// fence, or text after the closing fence keeps the output as it is.
    static func missingFileDiagnostic(_ output: String) -> String? {
        let fence = "```", diagnostic = "File does not exist."
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count >= 4, lines[0] == "Tool failed.", lines[1] == fence, lines[lines.count - 1] == fence else { return nil }
        let inner = lines[2..<(lines.count - 1)]
        guard lines[2] == diagnostic || lines[2].hasPrefix(diagnostic + " "),
              !inner.contains(where: { $0.contains(fence) }) else { return nil }
        return inner.joined(separator: "\n")
    }

    static let noReason = "No reason was given."

    /// The failure a result states. `status` is the shared tool status, so a declined or
    /// cancelled permission reads as blocked.
    static func read(_ result: ToolResult, status: ToolStatus) -> ActivityFailure {
        let message = body(result)
        let (first, rest) = firstSentence(message)
        switch status {
        case .declined:
            return ActivityFailure(outcome: .blocked, reason: "You denied this.", exact: first.isEmpty ? "Tool declined." : first, rest: rest)
        case .cancelled:
            return ActivityFailure(outcome: .blocked, reason: "The request was cancelled.",
                                   exact: first.isEmpty ? "Tool cancelled." : first, rest: rest)
        default:
            break
        }
        for entry in table where message.contains(entry.phrase) {
            return ActivityFailure(outcome: .blocked, reason: entry.words, exact: first, rest: rest)
        }
        for entry in framed where matches(message, start: entry.start, end: entry.end) {
            return ActivityFailure(outcome: entry.outcome, reason: entry.words, exact: first, rest: rest)
        }
        if isShellTimeout(message) {
            return ActivityFailure(outcome: .failed, reason: timedOut, exact: first, rest: rest)
        }
        guard !first.isEmpty else { return ActivityFailure(outcome: .failed, reason: noReason, exact: noReason) }
        return ActivityFailure(outcome: .failed, reason: first, exact: first, rest: rest)
    }

    /// The provider's message: the error and the output, without the service's `Tool failed.` line.
    static func body(_ result: ToolResult) -> String {
        var lines: [String] = []
        for text in [result.error, missingFileDiagnostic(result.output) ?? result.output] {
            for line in (text ?? "").split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                var bare = trimmed.lowercased()
                while bare.hasSuffix(".") { bare.removeLast() }
                if trimmed.isEmpty || ["tool failed", "tool declined", "tool cancelled", "tool canceled", "failed"].contains(bare) { continue }
                if !lines.contains(trimmed) { lines.append(trimmed) }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The first sentence, exactly as sent, and what follows it.
    static func firstSentence(_ text: String) -> (first: String, rest: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }
        var end = trimmed.endIndex
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            let next = trimmed.index(after: index)
            if character.isNewline { end = index; break }
            if character == "." || character == "!" || character == "?" {
                if next == trimmed.endIndex { end = next; break }
                if trimmed[next] == " " || trimmed[next].isNewline { end = next; break }
            }
            index = next
        }
        let first = String(trimmed[..<end])
        let rest = String(trimmed[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (first, rest.isEmpty ? nil : rest)
    }
}

/// How a line counts in a summary: "ran a command", "ran 3 commands", "delegated to reader".
struct ActivityPhrase: Equatable {
    let key: String
    let one: String
    /// `%d` stands for the count.
    let many: String
    /// The single named item, which keeps its name: "delegated to reader".
    var named: String? = nil

    func text(count: Int, names: [String]) -> String {
        if count == 1 { return names.first ?? one }
        return many.replacingOccurrences(of: "%d", with: String(count))
    }
}

struct ActivityWording: Equatable {
    var running: ActivitySentence
    /// Past tense, with the values the call and its result hold; the fallback without them.
    var done: ActivitySentence
    var fallback: ActivitySentence
    var failed: ActivitySentence
    var phrase: ActivityPhrase?
    var tag: ActivityTag? = nil
    /// What the line's help shows: a full path, the wire name.
    var help: String? = nil
}

struct ActivityStep: Identifiable, Equatable {
    enum State: Equatable { case running, done, failed, awaitingApproval }
    enum Kind: Equatable { case call, workflow, orphanResult, thought, quiet }

    /// The first entry's ID: stable while later calls join the line.
    let id: String
    var kind: Kind = .call
    var entries: [TranscriptEntry]
    var state: State
    var sentence: ActivitySentence
    var tag: ActivityTag? = nil
    var phrase: ActivityPhrase? = nil
    var failure: ActivityFailure? = nil
    var help: String? = nil
    /// Calls linked by an exact ID, drawn as a milestone timeline when the line opens.
    var workflow: CommanderWorkflow? = nil
    /// How many identical consecutive calls this line stands for.
    var count = 1
    /// A thought's length, when its record holds both times.
    var duration: TimeInterval? = nil
    /// A thought's text, or a quiet row's event. Empty when the provider sent none.
    var text: String = ""
    /// The lines a finished call added and removed, from its stored record's typed diff blocks.
    /// Exact, or nil: never an estimate, and nil until that record has been read.
    var change: ChangeCounts? = nil

    /// Whether the line opens: every call does; a thought only when it has text.
    var opens: Bool {
        switch kind {
        case .thought: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .quiet: false
        default: true
        }
    }

    var accessibilityLabel: String {
        var parts = [sentence.plain]
        if let change { parts.append(change.spoken) }
        if let tag { parts.append(tag.word) }
        if let failure { parts.append(failure.reason) }
        return parts.joined(separator: ", ")
    }
}

struct ActivityGroup: Identifiable, Equatable {
    let id: String
    var lines: [ActivityStep] = []
    /// Never counted away: each is drawn under the summary, open or closed.
    var failures: [ActivityStep] = []

    struct Summary: Equatable {
        /// "Ran 3 commands, read 2 files". Empty for a group whose calls all failed.
        var text: String
        /// Non-success tags named on a closed group: "1 accepted".
        var notes: [String] = []
        /// "1 blocked", "2 failed", in failure ink.
        var failed: [String] = []
        var steps: Int

        var accessibilityLabel: String {
            var head = "Activity, " + (steps == 1 ? "1 step" : "\(steps) steps")
            if !failed.isEmpty { head += ", " + failed.joined(separator: ", ") }
            let body = ([text] + notes).filter { !$0.isEmpty }.joined(separator: ", ")
            return body.isEmpty ? head : head + ". " + body
        }
    }

    /// A group of one has no summary line: its sentence stands alone.
    var isSingle: Bool { lines.count == 1 && failures.isEmpty }

    var summary: Summary { Self.summary(lines: lines, failures: failures) }

    static let phraseCap = 3

    static func summary(lines: [ActivityStep], failures: [ActivityStep]) -> Summary {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var names: [String: [String]] = [:]
        var phrases: [String: ActivityPhrase] = [:]
        for line in lines {
            guard let phrase = line.phrase else { continue }
            if counts[phrase.key] == nil { order.append(phrase.key); phrases[phrase.key] = phrase }
            counts[phrase.key, default: 0] += line.count
            if let named = phrase.named { names[phrase.key, default: []].append(named) }
        }
        var parts = order.prefix(phraseCap).map { key in
            phrases[key]!.text(count: counts[key]!, names: names[key] ?? [])
        }
        let more = order.dropFirst(phraseCap).reduce(0) { $0 + counts[$1]! }
        if more > 0 { parts.append(more == 1 ? "and 1 more step" : "and \(more) more steps") }
        if parts.isEmpty {
            let thoughts = lines.filter { $0.kind == .thought }
            let quiet = lines.filter { $0.kind == .quiet }
            if !thoughts.isEmpty {
                let durations = thoughts.compactMap(\.duration)
                parts = [durations.count == thoughts.count
                    ? "thought for " + ElapsedTime.text(durations.reduce(0, +)) : "thought"]
            } else if !quiet.isEmpty {
                parts = [quiet.count == 1 ? "1 session update" : "\(quiet.count) session updates"]
            }
        }
        var text = parts.joined(separator: ", ")
        text = text.prefix(1).uppercased() + text.dropFirst()

        var tagOrder: [String] = []
        var tagCounts: [String: Int] = [:]
        for line in lines {
            guard let tag = line.tag, tag.isNamedOnSummary else { continue }
            if tagCounts[tag.word] == nil { tagOrder.append(tag.word) }
            tagCounts[tag.word, default: 0] += 1
        }
        let blocked = failures.filter { $0.failure?.outcome == .blocked }.count
        let failed = failures.count - blocked
        var failedParts: [String] = []
        if blocked > 0 { failedParts.append("\(blocked) blocked") }
        if failed > 0 { failedParts.append("\(failed) failed") }
        return Summary(text: text, notes: tagOrder.map { "\(tagCounts[$0]!) \($0)" }, failed: failedParts,
                       steps: lines.reduce(0) { $0 + $1.count } + failures.count)
    }

    /// What an Option-click on the summary opens or closes: the group, each line that opens, and
    /// each failure drawn beneath the list. A line that does not open is left out, so it keeps
    /// no open state. Every line counts, shown or not: a step the PiP holds behind "Show all"
    /// is already open when it is revealed.
    var everyStepIDs: [String] {
        [id] + lines.filter(\.opens).map(\.id) + failures.map(\.id)
    }

    /// The lines an opened group shows on a bounded surface: the first and the latest three,
    /// with how many are left out until "Show all".
    func shownLines(limit: Int?) -> (lines: [ActivityStep], hidden: Int) {
        guard let limit, lines.count > limit else { return (lines, 0) }
        return ([lines[0]] + lines.suffix(limit - 1), lines.count - limit)
    }
}

struct ActivityReport: Identifiable, Equatable {
    let id: String
    let call: CommanderCall
    /// The reported text, exactly as sent.
    let text: String
    /// "Reported to the coordinator" for a worker, "Reported the run result" for a coordinator.
    let heading: String
    /// A closing agent message follows in the same turn, so the report shows its first lines.
    var closingMessageFollows = false
}

struct ActivityPlan: Identifiable, Equatable {
    let id: String
    /// Every plan update of the turn, oldest first. The card shows the latest.
    var entries: [TranscriptEntry]
    /// The latest update's items. Nil when no record holds them: the card is then the line
    /// "Updated the plan". An empty list is a plan known to be empty.
    var items: [PlanItem]?
    /// The item count the latest event carried, when it carried one.
    var count: Int?
    /// The provider plan this card stands for, on an identified ACP plan (`TranscriptOrigin
    /// .planIdentity`). Nil for a `TodoWrite` list and an ACP plan event that names no plan.
    /// Opaque: it matches events to the card and is never drawn, spoken or copied.
    var identity: String? = nil
    /// The provider removed this plan: the card is the line "The plan was removed".
    var isRemoved = false

    static let removedLine = "The plan was removed"

    var fallback: String {
        guard let count else { return "Updated the plan" }
        return count == 1 ? "Updated the plan: 1 item" : "Updated the plan: \(count) items"
    }

    /// The one line drawn in place of the checklist: that the plan was removed, or the fallback.
    var line: String { isRemoved ? Self.removedLine : fallback }

    /// The items the card draws. Nil draws `line`: a removed plan, or one whose latest event has
    /// no record. An identified ACP plan's items are the provider's own words, so with
    /// `hidesSecrets` (the transcript setting, `ToolDetailStore.hidesSecrets`) each is masked
    /// whole, for the eye and for VoiceOver alike. The stored record is unchanged.
    func shown(hidesSecrets: Bool) -> [PlanItem]? {
        guard !isRemoved, let items else { return nil }
        return hidesSecrets && identity != nil ? items.map(\.masked) : items
    }
}

enum PrettyItem: Identifiable, Equatable {
    /// A prompt, a reply, an attention-tone event or a role note: drawn as it is.
    case entry(TranscriptEntry)
    case group(ActivityGroup)
    case report(ActivityReport)
    case plan(ActivityPlan)
    /// The open call: the live line.
    case live(ActivityStep)
    /// A call a permission request holds. Never collapsed.
    case approval(ActivityStep)
    /// A call drawn as a card: a pending question's choices, a proposed plan, a deliverable.
    case card(PrettyToolCard)
    /// The end-of-turn line, from the turn's `turn_end` records. Never folded.
    case turnEnd(PrettyTurnEnd)
    /// The line after the owner's reply to a form request, from its `form_outcome` record.
    case formOutcome(PrettyFormOutcome)
    /// One provider compaction, at its message's own position. Never folded.
    case compaction(PrettyCompaction)

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .group(let group): group.id
        case .report(let report): report.id
        case .plan(let plan): plan.id
        case .live(let step): step.id + "#live"
        case .approval(let step): step.id + "#approval"
        case .card(let card): card.id
        case .turnEnd(let end): end.id + "#turn-end"
        case .formOutcome(let outcome): outcome.id + "#form-outcome"
        case .compaction(let compaction): compaction.id + "#compaction"
        }
    }

    var entries: [TranscriptEntry] {
        switch self {
        case .entry(let entry): [entry]
        case .group(let group): group.lines.flatMap(\.entries) + group.failures.flatMap(\.entries)
        case .report(let report): [report.call.entry]
        case .plan(let plan): plan.entries
        case .live(let step), .approval(let step): step.entries
        case .card(let card): card.step.entries
        case .compaction(let compaction): [compaction.entry]
        case .turnEnd, .formOutcome: []
        }
    }
}

/// The stored details a sentence may read, by a call's or thought's exact key.
struct ActivityFacts {
    var summary: (String) -> ToolDetailSummary? = { _ in nil }
    var record: (String) -> ToolDetailRecord? = { _ in nil }
    /// The console the entries belong to. A message's ID is `<worker>:<sequence>`, so a plan
    /// event is matched to its record only when this is known.
    var worker: String?
    /// Plan records by the console sequence of the event each was kept from. A sequence two
    /// records claim names neither.
    private(set) var plans: [Int: ToolDetailSummary] = [:]
    /// Who approves the console's held call when that is not the developer: the coordinator or
    /// parent that answers a delegated worker's request (`WorkerInputRoute`). Nil: the developer.
    var approvalOwner: WorkerInputOwner? = nil
    /// What was read from a marked reply chunk's own source record. Nil until it is read, and
    /// when no such record is kept: the chunk then stays a folded session update.
    var replyAttachment: (ReplyAttachmentMark) -> ReplyAttachment? = { _ in nil }
    /// The transcript setting as the store answers it (`ToolDetailStore.hidesSecrets`): a
    /// provider notice's title is masked where its line is built.
    var hidesSecrets = false

    static var none: ActivityFacts { ActivityFacts() }

    init(summary: @escaping (String) -> ToolDetailSummary? = { _ in nil },
         record: @escaping (String) -> ToolDetailRecord? = { _ in nil },
         worker: String? = nil, plans: [ToolDetailSummary] = []) {
        self.summary = summary
        self.record = record
        self.worker = worker
        self.plans = Self.bySequence(plans)
    }

    init(summaries: [String: ToolDetailSummary], records: [String: ToolDetailRecord] = [:], worker: String? = nil) {
        summary = { summaries[$0] }
        record = { records[$0] }
        self.worker = worker
        plans = Self.bySequence(Array(summaries.values))
    }

    /// The plan record kept from exactly this console event: the record whose sequence is the
    /// one in the entry's ID. Nil when the console is unknown, the ID holds no sequence, or no
    /// record has it. Never matched by order or count.
    func plan(for entry: TranscriptEntry) -> ToolDetailSummary? {
        guard let worker, let sequence = PrettyRecordPlacement.sequence(of: entry, worker: worker, summary: summary)
        else { return nil }
        return plans[sequence]
    }

    /// The plan record of an identified ACP plan update: the record at the event's sequence,
    /// only when the event was observed live and the record states that it was kept from this
    /// very event, by the event's own cursor, plan identity and turn. A console rebuilt from
    /// provider history numbers its events afresh while the records persist, so a later live
    /// event can have the sequence of a record kept from another one. A record that states no
    /// event, or another event, is not read: the card then shows its fallback.
    func identifiedPlan(for entry: TranscriptEntry) -> ToolDetailSummary? {
        guard let origin = entry.origin, origin.planIsLive, let record = plan(for: entry),
              record.planEvent?.names(cursor: origin.planCursor, planIdentity: origin.planIdentity,
                                      turnID: origin.planTurnID) == true else { return nil }
        return record
    }

    private static func bySequence(_ records: [ToolDetailSummary]) -> [Int: ToolDetailSummary] {
        var found: [Int: ToolDetailSummary] = [:]
        var repeated: Set<Int> = []
        for record in records where record.kind == "plan" {
            guard let sequence = record.sequence, sequence > 0 else { continue }
            if found.updateValue(record, forKey: sequence) != nil { repeated.insert(sequence) }
        }
        for sequence in repeated { found[sequence] = nil }
        return found
    }
}

// MARK: - Wording (table A)

enum ActivityWords {
    static func quote(_ text: String) -> String { "\u{201C}" + CommanderCall.firstLine(text) + "\u{201D}" }

    /// A value cut in the middle, so a long command keeps its start and its end.
    static func middle(_ text: String, limit: Int = 72) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        guard line.count > limit else { return line }
        let head = limit * 2 / 3, tail = limit - head - 1
        return String(line.prefix(head)) + "…" + String(line.suffix(tail))
    }

    static func count(_ number: Int, _ one: String, _ many: String? = nil) -> String {
        number == 1 ? "1 \(one)" : "\(number) \(many ?? one + "s")"
    }

    /// A tool's wire name without its server prefix: `mcp__github__list_issues` reads `list_issues`.
    static func bareName(_ name: String) -> String {
        if let range = name.range(of: "__", options: .backwards), range.upperBound < name.endIndex {
            return String(name[range.upperBound...])
        }
        return name
    }

    static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// `example.com/docs/page` from a URL; the text as sent when it is not one.
    static func hostPath(_ text: String) -> String {
        guard let url = URL(string: text), let host = url.host else { return middle(text, limit: 60) }
        let path = url.path == "/" ? "" : url.path
        return middle(host + path, limit: 60)
    }

    // MARK: Commander tools

    /// A Commander call's wording. `detail` is the call's stored summary, when the service kept one.
    static func commander(_ call: CommanderCall, detail: ToolDetailSummary? = nil) -> ActivityWording {
        func argument(_ key: String) -> String? { call.argument(key) ?? detail?.field(key) }
        // The network tools wrap their data: `{"ok":true,"data":…}`.
        var body = call.response
        if let wrapped = body, wrapped["ok"] != nil, let data = wrapped["data"] { body = data }
        func list(_ keys: String...) -> [AGUIValue]? {
            if let items = body?.arrayValue { return items }
            for key in keys { if let items = body?[key]?.arrayValue { return items } }
            return nil
        }
        func found(_ items: [AGUIValue]?, _ noun: String, none: String, fallback: String) -> ActivitySentence {
            guard let items else { return ActivitySentence(fallback) }
            return ActivitySentence(items.isEmpty ? none : "Found " + count(items.count, noun))
        }
        func liveTag(_ fallback: String = "accepted") -> ActivityTag {
            if let live = call.facts?.liveOperationStatus { return .state(live) }
            switch call.tool {
            case .send, .integrate, .networkSubmit:
                if let state = call.operationState { return .state(state) }
            default: break
            }
            return ActivityTag(word: fallback)
        }
        func wording(_ running: String, _ done: ActivitySentence?, _ fallback: String, _ failed: String,
                     one: String, many: String? = nil, named: String? = nil, tag: ActivityTag? = nil) -> ActivityWording {
            ActivityWording(running: ActivitySentence(running), done: done ?? ActivitySentence(fallback),
                            fallback: ActivitySentence(fallback), failed: ActivitySentence(failed),
                            phrase: ActivityPhrase(key: call.tool.rawValue, one: one, many: many ?? one, named: named),
                            tag: tag, help: call.tool.label)
        }
        let worker = call.targetWorker.map(Identifier.short)

        switch call.tool {
        case .delegate:
            let name = call.field("name") ?? argument("name") ?? call.plainDetail
            return wording("Starting a worker",
                           name.map { ActivitySentence(.text("Delegated to a new worker, "), .strong($0)) },
                           "Delegated to a new worker", "Couldn't start a worker",
                           one: "delegated to a new worker", many: "delegated to %d workers",
                           named: name.map { "delegated to " + $0 }, tag: liveTag())
        case .ask:
            let question = call.question ?? argument("question")
            let short = call.requestID.map { "Asked a question (request \(Identifier.short($0)))" }
            return wording("Asking", question.map { ActivitySentence("Asked: " + quote($0)) },
                           short ?? "Asked a question", "Couldn't send the question", one: "asked a question")
        case .wait:
            let answer = call.recordedAnswer ?? call.facts?.liveAnswer
            return wording("Waiting for a reply", answer.map { ActivitySentence("Got the answer: " + quote($0)) },
                           "Waited for a reply", "Couldn't wait for the reply", one: "waited for a reply")
        case .withdrawQuestion:
            // Withdrawn is said only on the request's own record. Any other result says what
            // was asked, tagged uncertain.
            let confirmed = call.result == nil || call.withdrawalConfirmed
            let short = call.requestID.map { "Withdrew a question (request \(Identifier.short($0)))" }
            return wording("Withdrawing the question",
                           confirmed ? call.question.map { ActivitySentence("Withdrew the question: " + quote($0)) }
                                     : ActivitySentence("Asked to withdraw a question"),
                           short ?? "Withdrew a question", "Couldn't withdraw the question",
                           one: "withdrew a question", many: "withdrew %d questions",
                           tag: confirmed ? nil : ActivityTag(word: "uncertain", tone: .wait))
        case .reply:
            let answer = argument("answer")
            let confirmed = call.result == nil || call.replyConfirmsRequest
            let short = call.requestID.map { "Replied to a question (request \(Identifier.short($0)))" }
            return wording("Replying",
                           confirmed ? answer.map { ActivitySentence("Replied: " + quote($0)) } : ActivitySentence("Sent a reply"),
                           short ?? "Replied to a question", "Couldn't send the reply", one: "replied to a question",
                           tag: confirmed ? nil : ActivityTag(word: "uncertain", tone: .wait))
        case .reconcileReply:
            return wording("Checking whether the reply arrived",
                           call.delivery.map { ActivitySentence("Checked the reply: delivery " + $0) },
                           "Checked a reply's delivery", "Couldn't check the reply", one: "checked a reply")
        case .result:
            return wording("Reporting", nil, "Reported a result", "Couldn't report the result", one: "reported a result")
        case .commit:
            let message = argument("message")
            let files = call.arguments?["files"]?.arrayValue?.count
            var done: ActivitySentence?
            if let message, let files {
                done = ActivitySentence("Committed " + count(files, "file") + ": " + quote(message))
            } else if let message {
                done = ActivitySentence("Committed changes: " + quote(message))
            }
            return wording("Committing", done, "Committed changes", "Couldn't commit",
                           one: "committed changes", many: "made %d commits",
                           tag: call.revision.map { ActivityTag(word: "rev " + Identifier.short($0)) })
        case .integrate:
            let workers = call.arguments?["worker_ids"]?.arrayValue?.count ?? call.response?["workers"]?.arrayValue?.count
            return wording("Starting an integration",
                           workers.map { ActivitySentence("Asked to integrate " + count($0, "worker's", "workers'") + " changes") },
                           "Asked to integrate changes", "Couldn't start the integration",
                           one: "started an integration", tag: liveTag())
        case .send:
            return wording("Sending a follow-up",
                           worker.map { ActivitySentence(.text("Sent "), .mono($0), .text(" a follow-up")) },
                           "Sent a follow-up to a worker", "Couldn't send the follow-up",
                           one: "sent a follow-up", many: "sent %d follow-ups", tag: liveTag())
        case .interrupt:
            return wording("Interrupting", worker.map { ActivitySentence(.text("Asked to interrupt "), .mono($0)) },
                           "Asked to interrupt a worker", "Couldn't interrupt " + (worker ?? "a worker"),
                           one: "asked to interrupt a worker", tag: liveTag())
        case .stopWorker:
            return wording("Stopping", worker.map { ActivitySentence(.text("Asked to stop "), .mono($0)) },
                           "Asked to stop a worker", "Couldn't stop " + (worker ?? "a worker"),
                           one: "asked to stop a worker", tag: liveTag())
        case .status:
            var done: ActivitySentence?
            if let workers = body?["workers"]?.arrayValue, workers.allSatisfy({ $0["state"]?.stringValue != nil }) {
                let running = workers.filter { ["running", "working", "starting"].contains($0["state"]?.stringValue ?? "") }.count
                done = ActivitySentence("Checked the run: " + count(workers.count, "worker") + ", \(running) running")
            }
            return wording("Checking worker progress", done, "Checked worker progress", "Couldn't check the run",
                           one: "checked progress", many: "checked progress %d times")
        case .listTools:
            return wording("Listing extensions",
                           found(list("tools"), "extension", none: "Found no extensions granted", fallback: "Listed extensions"),
                           "Listed extensions", "Couldn't list extensions", one: "listed extensions")
        case .callTool:
            let id = argument("id")
            return ActivityWording(
                running: id.map { ActivitySentence(.text("Calling extension "), .mono($0)) } ?? ActivitySentence("Calling an extension"),
                done: id.map { ActivitySentence(.text("Called extension "), .mono($0)) } ?? ActivitySentence("Called an extension"),
                fallback: ActivitySentence("Called an extension"),
                failed: id.map { ActivitySentence(.text("Extension "), .mono($0), .text(" failed")) } ?? ActivitySentence("Extension failed"),
                phrase: ActivityPhrase(key: call.tool.rawValue, one: "called an extension", many: "called %d extensions"),
                help: call.tool.label)
        case .networkInbox:
            var done: ActivitySentence?
            if let messages = list("messages") {
                done = ActivitySentence("Read the network inbox: " + (messages.isEmpty ? "no messages" : count(messages.count, "message")))
            }
            return wording("Reading the network inbox", done, "Read the network inbox",
                           "Couldn't read the network inbox", one: "read the inbox")
        case .networkDiscover:
            return wording("Looking for shared resources",
                           found(list("resources", "peers"), "shared resource", none: "Found no shared resources",
                                 fallback: "Looked for shared resources"),
                           "Looked for shared resources", "Couldn't look for shared resources",
                           one: "looked for shared resources")
        case .networkSubmit:
            let targets = call.arguments?["targets"]?.arrayValue?.count
            let short = call.operationID.map { "Sent a network operation (\(Identifier.short($0)))" }
            return wording("Sending an operation",
                           targets.map { ActivitySentence("Sent an operation to " + count($0, "resource")) },
                           short ?? "Sent a network operation", "Couldn't send the operation",
                           one: "sent an operation", tag: liveTag())
        case .networkReceipt:
            let state = call.operationState.map { CommanderActivityStatus(operation: $0).word.lowercased() }
            return wording("Checking the receipt", state.map { ActivitySentence("Receipt: " + $0) },
                           "Checked a receipt", "Couldn't read the receipt", one: "checked its receipt")
        case .networkOnline:
            var done: ActivitySentence?
            if let contacts = list("friends", "contacts") {
                if contacts.isEmpty {
                    done = ActivitySentence("No contacts to show")
                } else if contacts.allSatisfy({ $0["online"]?.boolValue != nil }) {
                    let online = contacts.filter { $0["online"]?.boolValue == true }.count
                    done = ActivitySentence(count(contacts.count, "contact") + ", \(online) online")
                }
            }
            return wording("Seeing who is online", done, "Checked who is online", "Couldn't see who is online",
                           one: "checked who is online")
        case .networkThread:
            var done: ActivitySentence?
            if let comments = body?["comments"]?.arrayValue ?? body?["thread"]?.arrayValue {
                done = ActivitySentence("Read a request thread: " + (comments.isEmpty ? "no comments" : count(comments.count, "comment")))
            }
            return wording("Reading a request thread", done, "Read a request thread", "Couldn't read the thread",
                           one: "read a thread")
        case .networkBoard:
            var done: ActivitySentence?
            if let workspaces = body?["workspaces"]?.arrayValue {
                done = ActivitySentence("Opened the task board: " + (workspaces.isEmpty ? "no workspaces" : count(workspaces.count, "workspace")))
            }
            return wording("Opening the task board", done, "Used the task board", "Couldn't use the task board",
                           one: "used the task board")
        case .frontendTools:
            return wording("Listing app tools",
                           found(list("tools"), "app tool", none: "Found no app tools", fallback: "Listed app tools"),
                           "Listed app tools", "Couldn't list app tools", one: "listed app tools")
        case .callFrontend:
            let name = argument("name") ?? call.plainDetail
            return ActivityWording(
                running: name.map { ActivitySentence(.text("Using app tool "), .mono($0)) } ?? ActivitySentence("Using an app tool"),
                done: name.map { ActivitySentence(.text("Used app tool "), .mono($0)) } ?? ActivitySentence("Used an app tool"),
                fallback: ActivitySentence("Used an app tool"),
                failed: name.map { ActivitySentence(.text("App tool "), .mono($0), .text(" failed")) } ?? ActivitySentence("App tool failed"),
                phrase: ActivityPhrase(key: call.tool.rawValue, one: "used an app tool", many: "used %d app tools"),
                help: call.tool.label)
        }
    }

    // MARK: Provider tools

    enum ProviderKind: Equatable { case read, edit, write, search, shell, webSearch, webFetch, plan, other }

    static func providerKind(_ name: String) -> ProviderKind {
        let lower = name.lowercased()
        if ["todowrite", "todo_write", "update_plan"].contains(lower) { return .plan }
        guard let tool = ProviderTool(name: name) else { return .other }
        switch tool.kind {
        case .read: return .read
        case .edit: return .edit
        case .write: return .write
        case .search: return .search
        case .shell: return .shell
        case .web: return lower.contains("fetch") ? .webFetch : .webSearch
        }
    }

    /// The subject a provider tool names (a path, command, pattern or URL). The stored values
    /// come first: the summary's short fields, then the full record's input once it is read.
    /// The call's own text is last: it is the console's preview, which the service may have cut.
    static func fact(_ name: String, detail: String?, summary: ToolDetailSummary?, record: ToolDetailRecord? = nil) -> String? {
        guard let tool = ProviderTool(name: name) else { return nil }
        // The value keeps its full length: each sentence shortens it by its own rule, and a path
        // cut before its file name would name the wrong thing.
        for key in tool.factKeys {
            if let value = summary?.field(key) { return ToolDetailText.wholeLine(value) }
            let parts = (summary?.fields?[key]?.arrayValue ?? []).compactMap { CommanderCall.text($0) }
            if !parts.isEmpty { return ToolDetailText.wholeLine(parts.joined(separator: " ")) }
        }
        // A stored input that was cut short is not read: its last value may be incomplete.
        if let input = record?.input, let read = OrderedJSON.read(input), !read.isCut, read.value.members != nil,
           let fact = tool.fact(from: input, whole: true) {
            return fact
        }
        return tool.fact(from: detail, whole: true)
    }

    static func provider(name: String, detail: String?, summary: ToolDetailSummary? = nil,
                         record: ToolDetailRecord? = nil, hidesSecrets: Bool = false) -> ActivityWording {
        if let special = special(name: name, detail: detail, summary: summary, record: record) { return special }
        let kind = providerKind(name)
        let fact = fact(name, detail: detail, summary: summary, record: record)
        func file(_ running: String, _ done: String, _ failed: String, fallback: String, key: String,
                  one: String, many: String) -> ActivityWording {
            let name = fact.map(fileName)
            func sentence(_ verb: String, _ none: String) -> ActivitySentence {
                name.map { ActivitySentence(.text(verb + " "), .strong($0)) } ?? ActivitySentence(none)
            }
            return ActivityWording(running: sentence(running, running + " a file"), done: sentence(done, fallback),
                                   fallback: ActivitySentence(fallback), failed: sentence(failed, failed + " a file"),
                                   phrase: ActivityPhrase(key: key, one: one, many: many), help: fact)
        }
        switch kind {
        case .read:
            return file("Reading", "Read", "Couldn't read", fallback: "Read a file", key: "read",
                        one: "read a file", many: "read %d files")
        case .edit:
            return file("Editing", "Edited", "Couldn't edit", fallback: "Edited a file", key: "edit",
                        one: "edited a file", many: "edited %d files")
        case .write:
            return file("Writing", "Wrote", "Couldn't write", fallback: "Wrote a file", key: "write",
                        one: "wrote a file", many: "wrote %d files")
        case .search:
            let pattern = fact.map(quote)
            return ActivityWording(
                running: ActivitySentence(pattern.map { "Searching for " + $0 } ?? "Searching files"),
                done: ActivitySentence(pattern.map { "Searched for " + $0 } ?? "Searched files"),
                fallback: ActivitySentence("Searched files"),
                failed: ActivitySentence(pattern.map { "Search for " + $0 + " failed" } ?? "Search failed"),
                phrase: ActivityPhrase(key: "search", one: "ran a search", many: "ran %d searches"), help: fact)
        case .shell:
            let command = fact.map { middle($0) }
            // The model's own description of the command, when the service kept it.
            let description = summary?.field("description")
            let done: ActivitySentence = description.map { ActivitySentence($0) }
                ?? command.map { ActivitySentence(.text("Ran "), .mono($0)) } ?? ActivitySentence("Ran a command")
            return ActivityWording(
                running: command.map { ActivitySentence(.text("Running "), .mono($0)) } ?? ActivitySentence("Running a command"),
                done: done, fallback: ActivitySentence("Ran a command"),
                failed: command.map { ActivitySentence(.mono($0), .text(" failed")) } ?? ActivitySentence("A command failed"),
                phrase: ActivityPhrase(key: "shell", one: "ran a command", many: "ran %d commands"), help: fact)
        case .webSearch:
            let query = fact.map(quote)
            return ActivityWording(
                running: ActivitySentence(query.map { "Searching the web for " + $0 } ?? "Searching the web"),
                done: ActivitySentence(query.map { "Searched the web for " + $0 } ?? "Searched the web"),
                fallback: ActivitySentence("Searched the web"), failed: ActivitySentence("Web search failed"),
                phrase: ActivityPhrase(key: "websearch", one: "searched the web", many: "searched the web %d times"), help: fact)
        case .webFetch:
            let page = fact.map(hostPath)
            return ActivityWording(
                running: page.map { ActivitySentence(.text("Fetching "), .mono($0)) } ?? ActivitySentence("Fetching a page"),
                done: page.map { ActivitySentence(.text("Fetched "), .mono($0)) } ?? ActivitySentence("Fetched a page"),
                fallback: ActivitySentence("Fetched a page"),
                failed: page.map { ActivitySentence(.text("Couldn't fetch "), .mono($0)) } ?? ActivitySentence("Couldn't fetch a page"),
                phrase: ActivityPhrase(key: "webfetch", one: "fetched a page", many: "fetched %d pages"), help: fact)
        case .plan:
            return ActivityWording(running: ActivitySentence("Updating the plan"), done: ActivitySentence("Updated the plan"),
                                   fallback: ActivitySentence("Updated the plan"),
                                   failed: ActivitySentence("Couldn't update the plan"), phrase: nil, help: name)
        case .other:
            // A tool Commander does not know takes its verb from the provider's own kind.
            if let stated = self.kind(summary: summary, hidesSecrets: hidesSecrets) { return stated }
            let bare = bareName(name)
            return ActivityWording(
                running: ActivitySentence(.text("Using "), .mono(bare)), done: ActivitySentence(.text("Used "), .mono(bare)),
                fallback: ActivitySentence(.text("Used "), .mono(bare)), failed: ActivitySentence(.mono(bare), .text(" failed")),
                phrase: otherToolPhrase, help: name)
        }
    }

    /// The provider's own tools that are not a file, search, command or web call (section H).
    /// Matched on the tool's whole name, so an extension's `wait` is not read as the provider's.
    /// Each sentence names a value only when the stored call holds it.
    static func special(name: String, detail: String?, summary: ToolDetailSummary?, record: ToolDetailRecord?) -> ActivityWording? {
        func make(_ running: ActivitySentence, _ done: ActivitySentence, _ failed: String, key: String, one: String,
                  many: String? = nil, tag: ActivityTag? = nil) -> ActivityWording {
            ActivityWording(running: running, done: done, fallback: done, failed: ActivitySentence(failed),
                            phrase: ActivityPhrase(key: key, one: one, many: many ?? one), tag: tag, help: name)
        }
        func field(_ key: String) -> String? {
            if let value = summary?.field(key) { return value }
            return (PrettyToolInput.object(record?.input)?[key] as? String).flatMap { CommanderCall.text(.string($0)) }
        }
        let lower = name.lowercased()
        switch lower {
        case "toolsearch":
            return make(ActivitySentence("Loading tools"), ActivitySentence("Loaded tools"), "Couldn't load tools",
                        key: lower, one: "loaded tools")
        case "sendmessage", "send_message":
            let to = field("to")
            return make(ActivitySentence("Sending a message"),
                        to.map { ActivitySentence(.text("Sent "), .strong($0), .text(" a message")) } ?? ActivitySentence("Sent a message"),
                        "Couldn't send the message", key: "sendmessage", one: "sent a message", many: "sent %d messages")
        case "agent", "task", "spawn_agent":
            let description = field("description")
            return make(ActivitySentence("Starting a child agent"),
                        ActivitySentence("Started a child agent" + (description.map { ": " + CommanderCall.firstLine($0) } ?? "")),
                        "Couldn't start a child agent", key: "agent", one: "started a child agent", many: "started %d child agents")
        case "monitor":
            let description = field("description")
            return make(ActivitySentence("Starting to watch"),
                        ActivitySentence("Started watching" + (description.map { ": " + CommanderCall.firstLine($0) } ?? "")),
                        "Couldn't start watching", key: lower, one: "started watching", many: "started %d watches",
                        tag: ActivityTag(word: "accepted"))
        case "croncreate":
            let prompt = field("prompt")
            return make(ActivitySentence("Scheduling"),
                        ActivitySentence(prompt.map { "Scheduled " + quote($0) } ?? "Scheduled a task"),
                        "Couldn't schedule the task", key: lower, one: "scheduled a task", many: "scheduled %d tasks",
                        tag: ActivityTag(word: "accepted"))
        case "sleep", "wait":
            return make(ActivitySentence("Waiting"), ActivitySentence("Waited"), "Couldn't wait",
                        key: "wait", one: "waited", many: "waited %d times")
        case "exec":
            let command = (field("command") ?? field("cmd") ?? detail.flatMap(ToolDetailText.subject)).map { middle($0) }
            return ActivityWording(
                running: command.map { ActivitySentence(.text("Running "), .mono($0)) } ?? ActivitySentence("Running a command"),
                done: command.map { ActivitySentence(.text("Ran "), .mono($0)) } ?? ActivitySentence("Ran a command"),
                fallback: ActivitySentence("Ran a command"),
                failed: command.map { ActivitySentence(.mono($0), .text(" failed")) } ?? ActivitySentence("A command failed"),
                phrase: ActivityPhrase(key: "shell", one: "ran a command", many: "ran %d commands"), help: name)
        case "js":
            return make(ActivitySentence("Running a script"), ActivitySentence("Ran a script"), "A script failed",
                        key: lower, one: "ran a script", many: "ran %d scripts")
        case "askuserquestion", "request_user_input":
            let question = PrettyChoiceQuestion.questions(input: record?.input).first?.question ?? field("question")
            return make(ActivitySentence("Asking"),
                        ActivitySentence(question.map { "Asked: " + quote($0) } ?? "Asked a question"),
                        "Couldn't ask", key: "askuser", one: "asked a question", many: "asked %d questions")
        case "exitplanmode":
            return make(ActivitySentence("Proposing a plan"), ActivitySentence("Proposed a plan"), "Couldn't propose a plan",
                        key: lower, one: "proposed a plan", many: "proposed %d plans")
        case "artifact":
            // The same tool reads and lists; only a publish is worded here.
            guard field("action") == "publish" else { return nil }
            let title = field("title")
            return make(ActivitySentence("Publishing" + (title.map { " " + $0 } ?? " an artifact")),
                        title.map { ActivitySentence(.text("Published "), .strong($0)) } ?? ActivitySentence("Published an artifact"),
                        "Couldn't publish" + (title.map { " " + $0 } ?? " the artifact"),
                        key: lower, one: "published an artifact", many: "published %d artifacts")
        case "senduserfile":
            let files = PrettyDeliverable(name: name, input: record?.input, summary: summary, result: nil).files
            let named: ActivitySentence? = files.first.map {
                ActivitySentence(parts: [.text("Sent you "), .strong($0.name)]
                                    + (files.count > 1 ? [.text(" and " + count(files.count - 1, "more file"))] : []))
            }
            return make(ActivitySentence("Sending you a file"), named ?? ActivitySentence("Sent you a file"),
                        "Couldn't send the file", key: lower, one: "sent you a file", many: "sent you %d files")
        default:
            return nil
        }
    }

    static let orphanResult = ActivityWording(
        running: ActivitySentence("Waiting for a result"),
        done: ActivitySentence("Got a result whose call was not recorded"),
        fallback: ActivitySentence("Got a result whose call was not recorded"),
        failed: ActivitySentence("A result whose call was not recorded failed"),
        phrase: ActivityPhrase(key: "orphan", one: "got a result with no recorded call",
                               many: "got %d results with no recorded call"))

    /// "Thought for 1m 52s" with both times; "Thought" without. "Thinking 52s" while it runs.
    static func thought(duration: TimeInterval?, live: Bool = false) -> ActivitySentence {
        guard let duration else { return ActivitySentence(live ? "Thinking" : "Thought") }
        return live ? ActivitySentence(.text("Thinking "), .mono(ElapsedTime.text(duration)))
                    : ActivitySentence(.text("Thought for "), .mono(ElapsedTime.text(duration)))
    }

    /// What a held call's line reads: "Needs your approval to run `command`". While the worker's
    /// coordinator or parent answers (`owner`), it names them and asks nothing of the reader:
    /// "Waiting for the coordinator's approval to run `command`".
    static func approval(name: String, detail: String?, summary: ToolDetailSummary?,
                         owner: WorkerInputOwner? = nil) -> ActivitySentence {
        let lead = owner.map { "Waiting for \($0.phrase)'s approval to " } ?? "Needs your approval to "
        if CommanderTool(name: name) == nil, providerKind(name) == .shell,
           let command = fact(name, detail: detail, summary: summary) {
            return ActivitySentence(.text(lead + "run "), .mono(middle(command)))
        }
        return ActivitySentence(.text(lead + "use "), .mono(CommanderTool(name: name)?.rawValue ?? bareName(name)))
    }
}

// MARK: - Steps

enum ActivitySteps {
    static func state(_ status: ToolStatus) -> ActivityStep.State {
        switch status {
        case .running: .running
        case .awaitingApproval: .awaitingApproval
        case .done, .interrupted: .done
        case .failed, .declined, .cancelled: .failed
        }
    }

    private static func apply(_ wording: ActivityWording, to step: inout ActivityStep, status: ToolStatus, result: ToolResult?) {
        step.phrase = wording.phrase
        step.help = wording.help
        switch step.state {
        case .running:
            step.sentence = wording.running
        case .awaitingApproval:
            break
        case .done:
            step.sentence = wording.done
            step.tag = status == .interrupted ? ActivityTag(word: "cancelled", tone: .wait) : wording.tag
        case .failed:
            step.sentence = wording.failed
            let failure = result.map { ActivityFailureWords.read($0, status: status) }
                ?? ActivityFailure(outcome: .failed, reason: ActivityFailureWords.noReason, exact: ActivityFailureWords.noReason)
            step.failure = failure
            step.tag = failure.tag
        }
    }

    /// One tool call that is not Commander's.
    static func step(tool entry: TranscriptEntry, awaitingToolID: String?, facts: ActivityFacts) -> ActivityStep? {
        guard case .tool(let name, let detail, let result) = entry.kind else { return nil }
        let status: ToolStatus = result == nil && entry.id == awaitingToolID ? .awaitingApproval : ToolStatus(result: result)
        let summary = facts.summary(entry.detailKey)
        var step = ActivityStep(id: entry.id, entries: [entry], state: state(status), sentence: ActivitySentence(""))
        if status == .awaitingApproval {
            step.sentence = ActivityWords.approval(name: name, detail: detail, summary: summary,
                                                   owner: facts.approvalOwner)
        }
        let record = facts.record(entry.detailKey)
        apply(ActivityWords.provider(name: name, detail: detail, summary: summary, record: record,
                                     hidesSecrets: facts.hidesSecrets),
              to: &step, status: status, result: result)
        // The stored result is an image. Only the full record says so, so the tag shows once
        // that record has been read: nothing in the summary or the call's text is taken as one.
        if step.state == .done, step.tag == nil, record?.resultImages != nil { step.tag = .image }
        // The same holds for the counts of a finished edit: they come from the full record's
        // typed diff blocks, once it has been read, and only when they are exact. An interrupted
        // edit is not a finished one.
        if status == .done { step.change = record?.resultChanges?.counts }
        return step
    }

    /// A result whose call the service did not send. When the stored details hold a record under
    /// the result's exact tool call ID, the line is worded as that tool's call. Nothing else
    /// names it: not its position, its time or the shape of its text.
    static func step(orphan entry: TranscriptEntry, facts: ActivityFacts = .none) -> ActivityStep? {
        guard case .output(let result) = entry.kind else { return nil }
        let status = ToolStatus(result: result)
        if let key = entry.toolCallID, let summary = facts.summary(key), summary.kind == "tool",
           let name = summary.name, !name.isEmpty {
            var step = ActivityStep(id: entry.id, entries: [entry], state: state(status), sentence: ActivitySentence(""))
            let named = TranscriptEntry(id: entry.id, kind: .tool(name: name, detail: nil, result: result))
            let wording = CommanderCall(entry: named).map { ActivityWords.commander($0, detail: summary) }
                ?? ActivityWords.provider(name: name, detail: nil, summary: summary, record: facts.record(key),
                                          hidesSecrets: facts.hidesSecrets)
            apply(wording, to: &step, status: status, result: result)
            // The record kept under the result's exact tool call ID holds that call's diff.
            if status == .done { step.change = facts.record(key)?.resultChanges?.counts }
            return step
        }
        var step = ActivityStep(id: entry.id, kind: .orphanResult, entries: [entry], state: state(status),
                                sentence: ActivitySentence(""))
        apply(ActivityWords.orphanResult, to: &step, status: status, result: result)
        return step
    }

    /// A finished report's text, exactly as sent. The call's own arguments come first; then the
    /// stored record's input, which keeps a long text the summary's fields leave out; then the
    /// call's plain detail; then the copy the service returned. Nil when none holds it.
    static func reportText(_ call: CommanderCall, facts: ActivityFacts) -> String? {
        if let text = call.argument("result") { return text }
        let key = call.entry.id
        // A stored input that was cut short is not the exact text.
        let stored = facts.record(key)?.input.flatMap { OrderedJSON.read($0) }
            .flatMap { $0.isCut ? nil : $0.value["result"]?.string }
            .flatMap { CommanderCall.text(.string($0)) }
        return stored ?? facts.summary(key)?.field("result") ?? call.plainDetail ?? call.returnedReport
    }

    /// The finished reports in `entries` whose call carries no text. The stored record may hold
    /// it, so the console reads that record once.
    static func reportsToRead(_ entries: [TranscriptEntry]) -> [String] {
        entries.compactMap { entry in
            guard case .tool(let name, _, let result) = entry.kind, CommanderTool(name: name) == .result,
                  ToolStatus(result: result) == .done, CommanderCall(entry: entry)?.argument("result") == nil
            else { return nil }
            return entry.id
        }
    }

    /// Commander calls linked by an exact ID, or one Commander call. `calls` leaves out a report
    /// the conversation draws as prose.
    static func step(workflow flow: CommanderWorkflow, calls: [CommanderCall], facts: ActivityFacts) -> ActivityStep {
        let first = calls[0]
        var step = ActivityStep(id: flow.id, kind: calls.count > 1 ? .workflow : .call, entries: calls.map(\.entry),
                                state: .done, sentence: ActivitySentence(""))
        step.workflow = flow
        if calls.count == 1 {
            let status = first.toolStatus
            step.state = state(status)
            if status == .awaitingApproval {
                step.sentence = ActivityWords.approval(name: first.tool.rawValue, detail: first.detail, summary: nil,
                                                       owner: facts.approvalOwner)
            }
            var wording = ActivityWords.commander(first, detail: facts.summary(first.entry.id))
            // A lone wait that returned no answer is still pending for its request.
            if first.tool == .wait, status == .done, first.status == .waitingForReply {
                wording.tag = ActivityTag(word: "waiting", tone: .wait)
            }
            apply(wording, to: &step, status: status, result: first.result)
            return step
        }
        // Several calls: the workflow's own state speaks. A failed call inside it stays visible
        // through the timeline, and makes the line a failure only when it is the latest word.
        let status = flow.status
        let last = calls[calls.count - 1]
        switch flow.link {
        case .request:
            let question = calls.compactMap(\.question).first
            let answer = calls.compactMap { $0.recordedAnswer ?? $0.facts?.liveAnswer }.last
            let hasAsk = calls.contains { $0.tool == .ask }
            let short = CommanderCall.request(flow.calls[0].requestID ?? "")
            step.sentence = question.map { ActivitySentence("Asked: " + ActivityWords.quote($0)) }
                ?? ActivitySentence(hasAsk ? "Asked a question (\(short))" : "Waited for a reply (\(short))")
            // A cancelled request was never answered, whatever text a call carried.
            let answered = status != .cancelled && (status == .answered || status == .complete || answer != nil)
            // Withdrawn: the request is cancelled and a withdrawal's own record says so.
            let withdrawn = status == .cancelled && calls.contains(where: \.withdrawalConfirmed)
            if question == nil, !hasAsk, withdrawn { step.sentence = ActivitySentence("Withdrew a question (\(short))") }
            let asked = answered ? "asked a question and got an answer"
                : withdrawn ? "asked a question and withdrew it" : "asked a question"
            step.phrase = ActivityPhrase(key: "question",
                                         one: hasAsk ? asked : withdrawn ? "withdrew a question" : "waited for a reply",
                                         many: hasAsk ? "asked %d questions" : withdrawn ? "withdrew %d questions" : "waited for %d replies")
            let probes = calls.filter { $0.tool == .wait }.count
            switch status {
            case .waitingForReply:
                step.tag = ActivityTag(word: "waiting", tone: .wait)
            case .awaitingApproval:
                step.state = .awaitingApproval
            case .failed:
                step.state = .failed
            case .cancelled, .uncertain, .partial:
                step.tag = .state(status.word)
            default:
                if answer == nil, probes > 1 { step.tag = ActivityTag(word: "\(probes) checks") }
            }
        case .operation:
            let submit = calls.first { $0.tool == .networkSubmit } ?? first
            let wording = ActivityWords.commander(submit, detail: facts.summary(submit.entry.id))
            step.sentence = wording.done
            step.phrase = wording.phrase
            step.tag = .state(flow.calls.compactMap(\.operationState).last ?? "accepted")
            if last.toolStatus == .failed { step.state = .failed }
        case .revision, .single:
            let wording = ActivityWords.commander(first, detail: facts.summary(first.entry.id))
            step.sentence = wording.done
            step.phrase = wording.phrase
            step.tag = wording.tag
            if last.toolStatus == .failed { step.state = .failed }
        }
        if step.state == .failed {
            let failing = calls.last { ToolStatus(result: $0.result) == .failed || ToolStatus(result: $0.result) == .declined } ?? last
            let wording = ActivityWords.commander(failing, detail: nil)
            step.sentence = wording.failed
            let failure = failing.result.map { ActivityFailureWords.read($0, status: ToolStatus(result: $0)) }
                ?? ActivityFailure(outcome: .failed, reason: ActivityFailureWords.noReason, exact: ActivityFailureWords.noReason)
            step.failure = failure
            step.tag = failure.tag
        }
        step.help = flow.reference.map { "Linked by exact \($0)" }
        return step
    }

    static func step(thought entry: TranscriptEntry, facts: ActivityFacts) -> ActivityStep? {
        guard entry.isThought, case .other(_, let text) = entry.kind else { return nil }
        // A thought's times are kept under the provider's message ID.
        let summary = (entry.origin?.messageID).flatMap(facts.summary) ?? facts.summary(entry.detailKey)
        let duration = summary?.duration.flatMap { $0 > 0 ? $0 : nil }
        return ActivityStep(id: entry.id, kind: .thought, entries: [entry], state: .done,
                            sentence: ActivityWords.thought(duration: duration), duration: duration, text: text)
    }

    /// A usage, mode, commands or session row: folded with its wording unchanged.
    static func step(quiet entry: TranscriptEntry, event: ActivityEvent) -> ActivityStep {
        let words = event.detail.isEmpty ? event.label : event.label + " " + event.detail
        return ActivityStep(id: entry.id, kind: .quiet, entries: [entry], state: .done,
                            sentence: ActivitySentence(.text(words)), text: event.symbol)
    }
}

// MARK: - Grouping (section B)

enum ActivityConversation {
    /// The Pretty conversation, in order. A run of consecutive finished calls and quiet lines
    /// inside one agent turn is one group. Agent prose, a prompt, a reported result, a pending
    /// request, a plan, a compaction, an attention-tone event, a notice with no stated level and
    /// the open call each end it. A failed call is drawn under the group it follows and ends it
    /// too.
    static func items(_ source: [ConversationItem], awaitingToolID: String? = nil, facts: ActivityFacts = .none,
                      reportsAsCoordinator: Bool = false) -> [PrettyItem] {
        var out: [PrettyItem] = []
        var open: ActivityGroup?
        var planIndex: Int?
        /// The identified ACP plans of the current turn: where each one's card or removal line is.
        var identified: [String: Int] = [:]

        func flush() {
            if let group = open { out.append(.group(group)); open = nil }
        }
        func add(_ step: ActivityStep) {
            if open?.failures.isEmpty == false { flush() }
            if open == nil { open = ActivityGroup(id: step.id + "#group") }
            // Identical consecutive calls with the same outcome are one line with a count.
            let counted = open?.lines.last?.tag?.word.hasSuffix(" times") == true
            if let last = open?.lines.last, last.kind == .call, step.kind == .call, last.sentence == step.sentence,
               last.phrase == step.phrase,
               step.tag == nil ? (last.tag == nil || counted) : (!counted && last.tag == step.tag) {
                var merged = last
                merged.entries += step.entries
                merged.count += step.count
                // The line's counts are of every call it stands for, or absent.
                merged.change = last.change.flatMap { known in
                    step.change.map { ChangeCounts(added: known.added + $0.added, removed: known.removed + $0.removed) }
                }
                if step.tag == nil { merged.tag = ActivityTag(word: "\(merged.count) times") }
                if var group = open { group.lines[group.lines.count - 1] = merged; open = group }
                return
            }
            open?.lines.append(step)
        }
        func route(_ step: ActivityStep) {
            switch step.state {
            case .running:
                flush()
                out.append(.live(step))
            case .awaitingApproval:
                flush()
                out.append(.approval(step))
            case .failed:
                if open == nil { open = ActivityGroup(id: step.id + "#group") }
                open?.failures.append(step)
            case .done:
                if step.tag?.word == "waiting" {
                    // A pending question is never folded: its line stands alone.
                    flush()
                    out.append(.group(ActivityGroup(id: step.id + "#group", lines: [step])))
                } else {
                    add(step)
                }
            }
        }
        /// - Parameter replaces: the event states the whole plan as it now is, so the card shows
        ///   this update alone: without its items it is the count line, never an earlier list.
        func plan(_ entry: TranscriptEntry, items: [PlanItem]?, count: Int?, replaces: Bool = false) {
            flush()
            if let index = planIndex, case .plan(var card) = out[index] {
                card.entries.append(entry)
                if replaces {
                    card.items = items
                    card.count = count
                } else {
                    if let items { card.items = items }
                    if let count { card.count = count }
                }
                out[index] = .plan(card)
            } else {
                out.append(.plan(ActivityPlan(id: entry.id + "#plan", entries: [entry], items: items, count: count)))
                planIndex = out.count - 1
            }
        }
        /// An ACP plan event that names its provider plan. Each plan has one card, where its
        /// first update arrived, and a later update of the same plan changes that card alone.
        /// A removal turns that plan's card into the removal line, in place.
        ///
        /// - An update states the whole plan: without its own record the card is the count
        ///   line, never the list an earlier update held, nor another plan's.
        /// - Only a live event reads a record. An event from provider history, or with any other
        ///   source, is still matched to its plan's card by identity and shows the count line.
        /// - A removal of a plan with no card in this turn is its own line, where it arrived.
        ///   It is never applied to another plan. A repeated removal adds nothing.
        /// - An update after the plan's removal is a new plan: a new card, where it arrived.
        func identifiedPlan(_ entry: TranscriptEntry, identity: String) {
            flush()
            let removes = entry.origin?.kind == TranscriptOrigin.planRemovedKind
            // The record kept from this very event: at its console sequence, and stating the
            // event's own cursor, identity and turn. A removal has none, and neither has an event
            // this console did not observe live: provider history is numbered afresh, so its
            // sequence may be that of an unrelated older record.
            let items = removes ? nil : facts.identifiedPlan(for: entry)?.plan
            let count = removes ? nil : entry.origin?.itemCount
            if let index = identified[identity], case .plan(var card) = out[index], !card.isRemoved || removes {
                card.entries.append(entry)
                if !card.isRemoved {
                    card.items = items
                    card.count = count
                    card.isRemoved = removes
                }
                out[index] = .plan(card)
            } else {
                out.append(.plan(ActivityPlan(id: entry.id + "#plan", entries: [entry], items: items, count: count,
                                              identity: identity, isRemoved: removes)))
                identified[identity] = out.count - 1
            }
        }
        func classify(_ entry: TranscriptEntry) {
            switch entry.kind {
            case .prose(_, let fromUser):
                flush()
                if fromUser { planIndex = nil; identified = [:] }
                out.append(.entry(entry))
            case .tool(let name, let detail, let result):
                if ActivityWords.providerKind(name) == .plan, ToolStatus(result: result) != .failed {
                    let items = PlanItem.items(facts.record(entry.detailKey)?.input.flatMap { OrderedJSON.read($0)?.value })
                        ?? PlanItem.items(detail.flatMap { OrderedJSON.read($0)?.value })
                    plan(entry, items: items, count: nil)
                } else if let step = ActivitySteps.step(tool: entry, awaitingToolID: awaitingToolID, facts: facts) {
                    if CommanderTool(name: name) == nil, step.state != .awaitingApproval,
                       let card = PrettyToolCard.kind(name: name, result: result, summary: facts.summary(entry.detailKey)) {
                        // A result for the reader, a proposed plan, a waiting question: in the open.
                        flush()
                        out.append(.card(PrettyToolCard(kind: card, step: step)))
                    } else {
                        route(step)
                    }
                }
            case .output:
                if let step = ActivitySteps.step(orphan: entry, facts: facts) { route(step) }
            case .other:
                if let compaction = PrettyCompaction(entry: entry) {
                    // One row per compaction, where its first update arrived. It ends the group.
                    flush()
                    out.append(.compaction(compaction))
                } else if let mark = entry.replyAttachment, facts.replyAttachment(mark) != nil {
                    // A link or a text resource the agent sent as part of its reply: it ends the
                    // group where it arrived, as prose does.
                    flush()
                    out.append(.entry(entry))
                } else if let step = ActivitySteps.step(thought: entry, facts: facts) {
                    add(step)
                } else if let identity = entry.origin?.planIdentity {
                    identifiedPlan(entry, identity: identity)
                } else if isPlanEvent(entry) {
                    // The record kept from this very event, by its console sequence.
                    plan(entry, items: facts.plan(for: entry)?.plan, count: entry.origin?.itemCount, replaces: true)
                } else if let event = ActivityEvent(entry: entry, hidesSecrets: facts.hidesSecrets), event.folds {
                    add(ActivitySteps.step(quiet: entry, event: event))
                } else {
                    // An attention event, a notice with no stated level, or a role note: in the
                    // open, where it arrived. It ends the group.
                    flush()
                    out.append(.entry(entry))
                }
            }
        }

        for item in source {
            switch item {
            case .entry(let entry):
                classify(entry)
            case .activity(let activity):
                activity.entries.forEach(classify)
            case .commander(let flow):
                // A reported result is prose in the conversation, never a line in a group.
                let report = flow.calls.last { $0.tool == .result && $0.toolStatus == .done }
                let calls = flow.calls.filter { $0.entry.id != report?.entry.id }
                if !calls.isEmpty { route(ActivitySteps.step(workflow: flow, calls: calls, facts: facts)) }
                if let report {
                    flush()
                    if let text = ActivitySteps.reportText(report, facts: facts) {
                        out.append(.report(ActivityReport(
                            id: report.entry.id + "#report", call: report, text: text,
                            heading: reportsAsCoordinator ? "Reported the run result" : "Reported to the coordinator")))
                    } else {
                        // No copy of the text was kept: the line "Reported a result" stands alone.
                        let line = ActivitySteps.step(workflow: flow, calls: [report], facts: facts)
                        out.append(.group(ActivityGroup(id: report.entry.id + "#report#group", lines: [line])))
                    }
                }
            }
        }
        flush()
        // A report shows its first lines only when the same turn ends with an agent message.
        for index in out.indices {
            guard case .report(var report) = out[index] else { continue }
            for later in out[(index + 1)...] {
                if case .entry(let entry) = later, case .prose(_, let fromUser) = entry.kind {
                    report.closingMessageFollows = !fromUser
                    break
                }
            }
            out[index] = .report(report)
        }
        return out
    }

    /// What a bounded request surface (the PiP) shows of a conversation, chosen from the finished
    /// items so grouping, attribution and failures read exactly as they do on the focused worker.
    /// Only the current turn is read: the items after the developer's latest prompt.
    ///
    /// - The latest group that holds work (a call, a workflow or a result), and everything after
    ///   it as it is: replies, the report, the turn's end, a card, the live line.
    /// - Before that group: every failure of the turn, as failure lines without their group's
    ///   finished calls; the turn's latest report, when none follows; a pending question's line
    ///   and a live line; a provider notice that does not fold. Each keeps its place in order.
    /// - From any turn: a call awaiting approval, and every item holding an entry in `keeping`
    ///   (the request's own workflow), so the request is never cut off.
    ///
    /// A turn with no such group shows its latest `fallback` items instead, the prompt included
    /// when it is among them. Earlier turns are otherwise left out, so they never crowd the latest.
    static func recent(_ items: [PrettyItem], keeping: Set<String> = [],
                       fallback: Int = TranscriptEntry.recentWindow) -> [PrettyItem] {
        func isPrompt(_ item: PrettyItem) -> Bool {
            if case .entry(let entry) = item { return entry.isFromUser }
            return false
        }
        func isPendingQuestion(_ group: ActivityGroup) -> Bool {
            group.isSingle && group.lines[0].tag?.word == "waiting"
        }
        func holdsWork(_ item: PrettyItem) -> Bool {
            guard case .group(let group) = item, !isPendingQuestion(group) else { return false }
            return group.lines.contains { $0.kind == .call || $0.kind == .workflow || $0.kind == .orphanResult }
        }
        func isKept(_ item: PrettyItem) -> Bool {
            if case .approval = item { return true }
            return !keeping.isEmpty && item.entries.contains { keeping.contains($0.id) }
        }
        func isReport(_ item: PrettyItem) -> Bool {
            if case .report = item { return true }
            return false
        }

        let prompt = items.lastIndex(where: isPrompt)
        let turn = prompt.map { $0 + 1 } ?? 0
        let start = items[turn...].lastIndex(where: holdsWork)
            ?? max(prompt ?? 0, items.count - max(fallback, 0))
        let reportFollows = items[start...].contains(where: isReport)
        // Without a group the fallback may open on the prompt, one item before the turn.
        let earlierReport = reportFollows || start <= turn ? nil : (turn..<start).last { isReport(items[$0]) }

        var shown: [PrettyItem] = []
        for index in 0..<start {
            let item = items[index]
            if isKept(item) { shown.append(item); continue }
            guard index >= turn else { continue }
            switch item {
            case .group(let group):
                if isPendingQuestion(group) {
                    shown.append(item)
                } else if !group.failures.isEmpty {
                    shown.append(.group(ActivityGroup(id: group.id, failures: group.failures)))
                }
            case .live:
                shown.append(item)
            case .compaction(let compaction):
                // A running compaction is a live line and a failed one a failure: both stay.
                if compaction.mark.status != .completed { shown.append(item) }
            case .report:
                if index == earlierReport { shown.append(item) }
            case .entry(let entry):
                // A provider notice that does not fold (a warning, an error, or one with no
                // stated level) stays, where it arrived. Every other entry is left out.
                // Chosen by the notice's level alone: no title is read or prepared here.
                if entry.origin?.notice?.folds == false { shown.append(item) }
            case .plan, .approval, .card, .turnEnd, .formOutcome:
                break
            }
        }
        return shown + items[start...]
    }

    static func isPlanEvent(_ entry: TranscriptEntry) -> Bool {
        guard case .other = entry.kind else { return false }
        return entry.origin?.kind == "plan"
    }

    /// The thought the agent is in now: the last item's last line, when the turn is live and the
    /// conversation ends with it. It is drawn as the live line instead of a finished one.
    static func liveThought(in items: [PrettyItem]) -> ActivityStep? {
        guard case .group(let group)? = items.last, group.failures.isEmpty,
              let last = group.lines.last, last.kind == .thought else { return nil }
        return last
    }

    /// `items` without the live thought, which the live line draws.
    static func withoutLiveThought(_ items: [PrettyItem]) -> [PrettyItem] {
        guard case .group(var group)? = items.last, liveThought(in: items) != nil else { return items }
        group.lines.removeLast()
        var rest = Array(items.dropLast())
        if !group.lines.isEmpty { rest.append(.group(group)) }
        return rest
    }
}
