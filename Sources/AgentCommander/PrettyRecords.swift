import Foundation

// PRETTY RECORDS (DESIGN.md, "Pretty transcript"; spec sections G and H)
// What the older Claude runner keeps beside the console, read through `ToolDetailStore`:
//
//   job        a background command or a child agent, joined to its call by exact tool_use_id
//   turn_end   one per result envelope: duration, stop reason, error flag
//   thought    a thought's times and text; this runner sends no console event for it
//
//   Value          PrettyTurnEnd          the end-of-turn line: words and ink
//                  PrettyToolCard         a call drawn as a card: choices, a plan, a deliverable
//                  PrettyChoiceQuestion   one question of a choice card
//                  PrettyDeliverable      a published artifact or a sent file
//   Feature layer  ProviderJobs.jobs      the background jobs of one console's `job` records
//                  PrettyRecordPlacement  where a record sits, by console sequence
//
// A record is placed by its console sequence against entries whose own sequence is known. When
// the neighbouring entry's sequence is not known, the record is left out. No client-side guess.
// The one record with no sequence that is placed is the older runner's thought from before the
// worker's first console event: it sits before console event 1 (`isBeforeFirstEvent`).

// MARK: - Background jobs from `job` records

enum ProviderJobs {
    /// The jobs the `job` records describe, in the order of the calls that started them. Each is
    /// joined to its console call by the record's exact `tool_use_id`. A record of a kind other
    /// than `command` or `agent`, or with no state, gives no job.
    ///
    /// With `hidesSecrets` (the transcript setting), every text a record gives a line is masked
    /// before anything is derived from it: the description, the child's open call, and the exit
    /// summary a failure's first sentence is cut from. The line, its VoiceOver label and its
    /// announcement are built from the masked text. The exit summary as stored stays in `result`,
    /// which the opened line shows only after Reveal.
    static func jobs(summaries: [ToolDetailSummary], record: (String) -> ToolDetailRecord? = { _ in nil },
                     entries: [TranscriptEntry], worker: String, hidesSecrets: Bool = false) -> [BackgroundJob] {
        func shown(_ text: String?) -> String? {
            guard hidesSecrets, let text else { return text }
            return SecretValues.masked(prose: text).text
        }
        let lastPrompt = entries.lastIndex(where: \.isFromUser) ?? -1
        var calls: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if case .tool = entry.kind { calls[ToolDetailStore.storedKey(worker: worker, key: entry.id)] = index }
        }
        let records = summaries.filter { $0.kind == "job" }.sorted {
            let a = $0.toolUseID.flatMap { calls[$0] } ?? Int.max, b = $1.toolUseID.flatMap { calls[$0] } ?? Int.max
            return a != b ? a < b : ($0.sequence ?? 0, $0.key) < ($1.sequence ?? 0, $1.key)
        }
        var jobs: [BackgroundJob] = []
        var seen = Set<String>()
        for summary in records {
            guard let callID = summary.toolUseID, !callID.isEmpty, let state = summary.state, !state.isEmpty,
                  let kind: BackgroundJob.Kind = summary.jobKind == "agent" ? .providerChild
                      : summary.jobKind == "command" ? .command : nil,
                  seen.insert(callID).inserted else { continue }
            var job = BackgroundJob(kind: kind, recordID: callID, state: state)
            job.detailKey = summary.key
            job.text = shown(summary.title?.trimmingCharacters(in: .whitespacesAndNewlines))
            let word = state.lowercased()
            // The runner's observation time, shown only while the record says running.
            if word == "running" { job.startedAt = summary.started }
            if word == "running", let tool = summary.openToolName, !tool.isEmpty {
                job.liveSentence = ActivityWords.provider(name: tool, detail: shown(summary.openToolArg)).running
            }
            // The exit summary is in the full record, read when the line opens or the job fails.
            let result = record(summary.key)?.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !result.isEmpty {
                job.result = result
                // Masked whole, then cut: a secret the sentence's end falls inside stays hidden.
                let masked = hidesSecrets ? SecretValues.masked(prose: result) : (text: result, count: 0)
                if masked.count > 0 { (job.hiddenResult, job.hiddenCount) = (masked.text, masked.count) }
                if word == "failed" { job.error = ActivityFailureWords.firstSentence(masked.text).first }
            }
            // A job whose call this console no longer holds is kept only while it has not ended.
            job.isSinceLastPrompt = calls[callID].map { $0 > lastPrompt } ?? false
            jobs.append(job)
        }
        return jobs
    }

    /// The `job` records whose full copy the stack reads at once: a failure shows its reason.
    static func recordsToRead(_ summaries: [ToolDetailSummary]) -> [String] {
        summaries.filter { $0.kind == "job" && $0.state?.lowercased() != "running" && ($0.resultBytes ?? 0) > 0 }.map(\.key)
    }
}

// MARK: - The end-of-turn line

struct PrettyTurnEnd: Identifiable, Equatable {
    enum Tone: Equatable { case attention, secondary }

    /// The record's own key.
    let id: String
    let sentence: ActivitySentence
    let tone: Tone
    /// The line states why the turn stopped. A stop reason wins over a duration.
    var isStop = false

    /// What one `turn_end` record says, or nil when it says nothing to draw: `end_turn` with no
    /// duration. The stop-reason words are spec section H's.
    init?(_ summary: ToolDetailSummary) {
        guard summary.kind == "turn_end" else { return nil }
        id = summary.key
        switch summary.stopReason?.lowercased() {
        case "max_tokens":
            (sentence, tone, isStop) = (ActivitySentence("Stopped: reached the output limit"), .attention, true)
        case "max_turn_requests":
            (sentence, tone, isStop) = (ActivitySentence("Stopped: reached the request limit for one turn"), .attention, true)
        case "refusal":
            (sentence, tone, isStop) = (ActivitySentence("The model declined to continue"), .attention, true)
        case "cancelled":
            (sentence, tone, isStop) = (ActivitySentence("This turn was cancelled"), .secondary, true)
        default:
            if summary.isError == true {
                // The provider marked the result an error and named none of the reasons above.
                (sentence, tone, isStop) = (ActivitySentence("Stopped"), .secondary, true)
            } else if let duration = summary.durationMS, duration >= 0 {
                sentence = ActivitySentence(.text("Worked for "), .mono(ElapsedTime.text(Double(duration) / 1000)))
                tone = .secondary
            } else {
                return nil
            }
        }
    }

    var spoken: String { sentence.plain }

    /// One line for a turn that holds several result records. A stop reason wins, the latest
    /// one. Otherwise the turn's own result gives the duration: the first record that names a
    /// reason. A later result that only reports a finished background task names none.
    static func line(for records: [ToolDetailSummary]) -> PrettyTurnEnd? {
        let lines = records.compactMap { record in PrettyTurnEnd(record).map { (record, $0) } }
        if let stop = lines.last(where: { $0.1.isStop }) { return stop.1 }
        let own = lines.first { $0.0.stopReason != nil || $0.0.terminalReason != nil }
        return (own ?? lines.last)?.1
    }
}

// MARK: - Placement by console sequence

enum PrettyRecordPlacement {
    typealias Summary = (String) -> ToolDetailSummary?

    /// The console sequence of an entry, when it is known. A message's ID is `<worker>:<sequence>`.
    /// A tool call's ID is its tool ID, so its sequence is read from its stored record. A thought
    /// placed from its record carries that record's key.
    static func sequence(of entry: TranscriptEntry, worker: String, summary: Summary) -> Int? {
        if entry.isThought, let key = entry.origin?.messageID, let record = summary(key), record.kind == "thought" {
            return record.sequence
        }
        switch entry.kind {
        case .tool:
            return summary(entry.detailKey)?.sequence
        case .output:
            if let key = entry.toolCallID, let sequence = summary(key)?.sequence { return sequence }
            return number(entry.id, worker: worker)
        case .prose, .other:
            return number(entry.id, worker: worker)
        }
    }

    private static func number(_ id: String, worker: String) -> Int? {
        let prefix = worker + ":"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy(\.isASCII), rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    /// The index of the entry a record with `sequence` comes directly after: the last entry at or
    /// before it. Nil when no entry is, or when the entry after that one has no known sequence,
    /// so it cannot be told which side of it the record belongs.
    static func anchor(_ sequence: Int, in sequences: [Int?]) -> Int? {
        guard sequence > 0, let index = sequences.lastIndex(where: { $0.map { $0 <= sequence } ?? false }) else { return nil }
        if index + 1 < sequences.count, sequences[index + 1] == nil { return nil }
        return index
    }

    /// The key the older Claude runner gives a thought: `thought-` and the lowercase version 4
    /// UUID it makes for each one. An ACP thought is kept under the provider's message ID.
    static func isOlderRunnerThought(_ key: String) -> Bool {
        let prefix = "thought-".utf8
        guard key.utf8.count == prefix.count + 36, key.utf8.starts(with: prefix) else { return false }
        for (index, byte) in key.utf8.dropFirst(prefix.count).enumerated() {
            let isHex = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            switch index {
            case 8, 13, 18, 23: guard byte == UInt8(ascii: "-") else { return false }
            case 14: guard byte == UInt8(ascii: "4") else { return false }
            case 19: guard "89ab".utf8.contains(byte) else { return false }
            default: guard isHex else { return false }
            }
        }
        return true
    }

    /// A thought the older runner recorded before the worker's first console event. The service
    /// binds it to the event before the first, which is 0, and sends no sequence for it. Any
    /// later thought of that runner has the sequence of the event it follows.
    static func isBeforeFirstEvent(_ thought: ToolDetailSummary) -> Bool {
        thought.kind == "thought" && (thought.sequence ?? 0) == 0 && isOlderRunnerThought(thought.key)
    }

    /// Console order, then the provider's own start time. The key keeps the order stable.
    private static func inOrder(_ a: ToolDetailSummary, _ b: ToolDetailSummary) -> Bool {
        (a.sequence ?? 0, a.startedAt ?? "", a.key) < (b.sequence ?? 0, b.startedAt ?? "", b.key)
    }

    /// `entries` with the older runner's thought records placed in order. That runner sends no
    /// console event for a thought, so each record becomes an entry the thought line is built
    /// from. A console that carries its own thoughts is returned unchanged.
    ///
    /// A thought from before the first console event sits before the first entry, and only when
    /// that entry is console event 1. A transcript that starts later, or whose first entry has no
    /// known sequence, does not show the worker's start: the record is left out.
    static func withThoughts(_ entries: [TranscriptEntry], summaries: [ToolDetailSummary], worker: String,
                             summary: Summary, record: (String) -> ToolDetailRecord?) -> [TranscriptEntry] {
        let placeable = summaries.filter { $0.kind == "thought" && (($0.sequence ?? 0) > 0 || isBeforeFirstEvent($0)) }
        guard !placeable.isEmpty, !entries.contains(where: \.isThought) else { return entries }
        let sequences = entries.map { sequence(of: $0, worker: worker, summary: summary) }
        let startsAtFirstEvent = (sequences.first ?? nil) == 1
        // Thoughts by the index of the entry each follows. `beforeFirst` is before every entry.
        let beforeFirst = -1
        var after: [Int: [TranscriptEntry]] = [:]
        for thought in placeable.sorted(by: inOrder) {
            // A record with neither a time nor text says nothing.
            let text = record(thought.key)?.result ?? ""
            guard thought.duration != nil || (thought.resultBytes ?? 0) > 0 || !text.isEmpty else { continue }
            let place = thought.sequence ?? 0
            let start: Int? = startsAtFirstEvent ? beforeFirst : nil
            guard let index = place > 0 ? anchor(place, in: sequences) : start else { continue }
            let origin = TranscriptOrigin(kind: ConversationChunks.thoughtKind, sourceIDs: [], messageID: thought.key)
            after[index, default: []].append(TranscriptEntry(id: worker + ":thought:" + thought.key,
                                                             kind: .other(role: "assistant", text: text), origin: origin))
        }
        guard !after.isEmpty else { return entries }
        var out: [TranscriptEntry] = after[beforeFirst] ?? []
        out.reserveCapacity(entries.count + placeable.count)
        for (index, entry) in entries.enumerated() {
            out.append(entry)
            out += after[index] ?? []
        }
        return out
    }

    /// The thought records whose text the console reads: the newest few that hold any. A thought
    /// from before the first console event is the oldest, so it is the first one dropped.
    static func thoughtsToRead(_ summaries: [ToolDetailSummary], limit: Int = 12) -> [String] {
        summaries.filter { $0.kind == "thought" && ($0.resultBytes ?? 0) > 0 && (($0.sequence ?? 0) > 0 || isBeforeFirstEvent($0)) }
            .sorted(by: inOrder).suffix(limit).map(\.key)
    }

    /// `items` with one end-of-turn line per turn, after the item that holds the last console
    /// event its records name. A turn is what lies between two of the developer's prompts.
    static func withTurnEnds(_ items: [PrettyItem], summaries: [ToolDetailSummary], worker: String,
                             summary: Summary) -> [PrettyItem] {
        let ends = summaries.filter { $0.kind == "turn_end" && ($0.sequence ?? 0) > 0 }
            .sorted { ($0.sequence ?? 0, $0.revision ?? 0, $0.key) < ($1.sequence ?? 0, $1.revision ?? 0, $1.key) }
        guard !ends.isEmpty else { return items }
        // Entries in console order, each with the item that draws it and the turn it is in.
        var placed: [(sequence: Int?, item: Int, turn: Int)] = []
        var turn = 0
        for (index, item) in items.enumerated() {
            for entry in item.entries {
                if entry.isFromUser { turn += 1 }
                placed.append((sequence(of: entry, worker: worker, summary: summary), index, turn))
            }
        }
        // A workflow draws a later call in an earlier item; the anchor is still the last drawn
        // entry at or before the record.
        let ordered = placed
        let sequences = ordered.map(\.sequence)
        var byTurn: [Int: (records: [ToolDetailSummary], item: Int)] = [:]
        for end in ends {
            guard let index = anchor(end.sequence ?? 0, in: sequences) else { continue }
            let at = ordered[index]
            var group = byTurn[at.turn] ?? ([], at.item)
            group.records.append(end)
            group.item = max(group.item, at.item)
            byTurn[at.turn] = group
        }
        var out = items
        for group in byTurn.values.sorted(by: { $0.item > $1.item }) {
            guard let line = PrettyTurnEnd.line(for: group.records) else { continue }
            out.insert(.turnEnd(line), at: group.item + 1)
        }
        return out
    }
}

// MARK: - Calls drawn as cards (section H)

/// A provider call the transcript draws in the open: a pending question's choices, a proposed
/// plan, or something made for the reader. Never folded.
struct PrettyToolCard: Identifiable, Equatable {
    enum Kind: Equatable { case question, plan, deliverable }

    let kind: Kind
    let step: ActivityStep

    var id: String { step.id + "#card" }
    var entry: TranscriptEntry? { step.entries.first }

    /// Which card a call is drawn as, or nil for a line. A question is a card only while it
    /// waits; a plan while it is proposed or accepted; a deliverable once it exists. A failed
    /// call is always the failure line.
    static func kind(name: String, result: ToolResult?, summary: ToolDetailSummary?) -> Kind? {
        let status = ToolStatus(result: result)
        switch name.lowercased() {
        case "askuserquestion", "request_user_input": return result == nil ? .question : nil
        case "exitplanmode": return status == .done || result == nil ? .plan : nil
        case "senduserfile": return status == .done ? .deliverable : nil
        case "artifact":
            // Only a publish makes something: the same tool also reads and lists.
            return status == .done && summary?.field("action") == "publish" ? .deliverable : nil
        default: return nil
        }
    }
}

struct PrettyChoiceQuestion: Equatable, Identifiable {
    struct Option: Equatable, Identifiable {
        let id: Int
        let label: String
        var description: String? = nil
    }

    let id: Int
    let question: String
    var header: String? = nil
    var allowsSeveral = false
    var options: [Option] = []

    /// The questions of an `AskUserQuestion` input, exactly as sent. Empty when the stored input
    /// is not held or was cut short.
    static func questions(input: String?) -> [PrettyChoiceQuestion] {
        guard let object = PrettyToolInput.object(input), let list = object["questions"] as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, item in
            guard let question = (item["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty else { return nil }
            let options = ((item["options"] as? [[String: Any]]) ?? []).enumerated().compactMap { at, option -> Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                let description = (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return Option(id: at, label: label, description: description)
            }
            return PrettyChoiceQuestion(id: index, question: question, header: item["header"] as? String,
                                        allowsSeveral: item["multiSelect"] as? Bool ?? false, options: options)
        }
    }
}

struct PrettyDeliverable: Equatable {
    struct File: Equatable, Identifiable {
        let name: String
        /// "Artifact", or the file's extension in capitals.
        let kind: String
        /// Where Open goes. Nil offers no Open.
        var url: URL? = nil
        var id: String { name + (url?.absoluteString ?? "") }
    }

    var files: [File] = []
    var caption: String? = nil

    /// What a finished `Artifact` or `SendUserFile` call made, from its stored input. An
    /// artifact's link is the one address in that call's own result; with none, or more than
    /// one, there is no Open.
    init(name: String, input: String?, summary: ToolDetailSummary?, result: ToolResult?) {
        let object = PrettyToolInput.object(input)
        func text(_ key: String) -> String? {
            ((object?[key] as? String) ?? summary?.field(key)).flatMap { $0.isEmpty ? nil : $0 }
        }
        switch name.lowercased() {
        case "senduserfile":
            let paths = (object?["files"] as? [String])
                ?? (summary?.fields?["files"]?.arrayValue ?? []).compactMap { CommanderCall.text($0) }
            files = paths.map { path in
                let url = URL(fileURLWithPath: path)
                let type = url.pathExtension.uppercased()
                return File(name: url.lastPathComponent, kind: type.isEmpty ? "File" : type + " file",
                            url: path.hasPrefix("/") ? url : nil)
            }
            caption = text("caption")
        default:
            let title = text("title") ?? text("file_path").map { URL(fileURLWithPath: $0).lastPathComponent }
            let links = Self.links(in: result?.output ?? "")
            files = [File(name: title ?? "Artifact", kind: "Artifact", url: links.count == 1 ? links[0] : nil)]
        }
    }

    /// The https addresses in a known tool's own result text.
    static func links(in text: String) -> [URL] {
        var found: [URL] = []
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "<" || $0 == ">" || $0 == ")" || $0 == "(" }) {
            guard word.hasPrefix("https://") else { continue }
            var address = String(word)
            while let last = address.last, ".,;:".contains(last) { address.removeLast() }
            if let url = URL(string: address), url.host != nil, !found.contains(url) { found.append(url) }
        }
        return found
    }
}

enum PrettyToolInput {
    /// A stored input as an object. Nil when it is not whole JSON: a value cut short is not read.
    static func object(_ input: String?) -> [String: Any]? {
        guard let input, let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The plan an `ExitPlanMode` call proposed, as Markdown.
    static func plan(input: String?, summary: ToolDetailSummary?) -> String? {
        let text = (object(input)?["plan"] as? String) ?? summary?.field("plan")
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// The plan a held `ExitPlanMode` call proposes, drawn before its decision. `exactToolID` is
    /// the call the pending permission names (`RequestPresentation.exactApprovalToolID`), and the
    /// held call must be that one: a call marked only because it is the one open call shows no
    /// plan. `summary` and `record` read one console's stored details, so the plan is the one
    /// kept by this worker under this call's own ID: never another worker's call with the same
    /// ID, another call, or the latest plan. Nil for any other call, and when no usable plan is
    /// stored: the approval line and the request form then stand alone.
    static func pendingPlan(for step: ActivityStep, exactToolID: String?, summary: (String) -> ToolDetailSummary?,
                            record: (String) -> ToolDetailRecord?) -> String? {
        guard let exactToolID, step.state == .awaitingApproval, step.entries.count == 1,
              let entry = step.entries.first, entry.id == exactToolID,
              case .tool(let name, _, nil) = entry.kind, CommanderTool(name: name) == nil,
              PrettyToolCard.kind(name: name, result: nil, summary: nil) == .plan else { return nil }
        let stored = record(entry.detailKey), brief = summary(entry.detailKey)
        // A record kept under this ID for a different tool is not this call's plan.
        for kept in [stored?.name, brief?.name] {
            if let kept, kept.caseInsensitiveCompare(name) != .orderedSame { return nil }
        }
        return plan(input: stored?.input, summary: brief)
    }
}
