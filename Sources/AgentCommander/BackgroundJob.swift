import Foundation

// BACKGROUND WORK (DESIGN.md, "Pretty transcript"; spec section G)
// A job is work that goes on after its tool call returns. The call's line stays where it
// happened; the job gets one line in the stack at the bottom of the transcript.
//
//   Value          BackgroundJob           one job: kind, record ID, state, evidence origin
//                  BackgroundJob.Line      what its line says now: words, mark, tag, reason, time
//                  BackgroundStackLayout   order and caps for one surface
//   Feature layer  BackgroundJobs.jobs     the jobs of one console, each read by exact ID
//
// Every state is read from the service's own record by the exact ID a call in this console
// returned or named. No record, no line. A completed tool call is never evidence that the job
// ran or ended.

struct BackgroundJob: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// A delegated worker: `Worker` by worker ID.
        case worker
        /// A follow-up or queued message: `WorkerFollowUp` by message ID.
        case followUp
        /// An interrupt or stop: the target `Worker` by worker ID.
        case stop
        /// A question awaiting an answer: `Question` by request ID.
        case question
        /// An integration: `candidate.status` by integration ID.
        case integration
        /// A provider's own child session. The service keeps no record yet; a later slice
        /// builds these jobs from it. Nothing in this file creates one.
        case providerChild
        /// A background shell command. As `providerChild`.
        case command
    }

    /// Where the state came from. Only `record` may draw a spinner.
    enum Evidence: Equatable {
        /// The service's record, read by exact ID from the live projection.
        case record
        /// The job's own description, with no record behind it: never a spinner.
        case description
    }

    let kind: Kind
    /// The exact ID the record was read by.
    let recordID: String
    /// The record's state or status, exactly as the service wrote it.
    let state: String
    var evidence: Evidence = .record
    /// The worker the line names: the delegated worker, or the follow-up's or question's worker.
    var name = ""
    /// The worker "Open <name>" goes to.
    var workerID: String? = nil
    /// The pending request "Go to the question" opens.
    var requestID: String? = nil
    /// `Worker.error`, shown under a failed line.
    var error: String? = nil
    /// The record's own start time, set only where one exists: a delegated worker's first turn.
    var startedAt: Date? = nil
    /// The child's open call as its own console words it. Nil when no call is open.
    var liveSentence: ActivitySentence? = nil
    /// The child's reported progress, for a tracked local Claude worker.
    var progress: ClaudeProgressTrack? = nil
    /// A follow-up's text or a provider child's own description.
    var text: String? = nil
    /// The child's latest turn, drawn when the line opens.
    var console: [TranscriptEntry] = []
    /// Its call came after this console's last prompt. An ended job shows only while this holds.
    var isSinceLastPrompt = true

    var id: String { kind.rawValue + ":" + recordID }

    // MARK: The line

    enum Rank: Int, Comparable {
        case failed, needsYou, running, lostContact, finished
        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
    }

    enum Mark: Equatable { case spinner, hollow, solid, attention }

    struct Line: Equatable {
        var rank: Rank
        var mark: Mark
        var sentence: ActivitySentence
        var tag: ActivityTag? = nil
        /// The reason under a failed line.
        var reason: String? = nil
        /// The start time the line counts from. Nil shows no time.
        var started: Date? = nil

        var isFailure: Bool { rank == .failed }
        var spoken: String { ([sentence.plain] + [tag?.word, reason].compactMap { $0 }).joined(separator: ", ") }
    }

    /// The subject of the sentence: "**tracer**", "Follow-up to **tracer**", "Integration".
    private var subject: [ActivitySentence.Part] {
        switch kind {
        case .worker, .stop, .question: [.strong(name)]
        case .followUp: [.text("Follow-up to "), .strong(name)]
        case .integration: [.text("Integration")]
        case .providerChild, .command: []
        }
    }

    private func sentence(_ rest: String) -> ActivitySentence { ActivitySentence(parts: subject + [.text(rest)]) }

    /// What the line says. `connected` is the service connection; `now` is read only for the
    /// reported-progress age.
    func line(connected: Bool, now: Date = Date()) -> Line {
        var line = known(now: now)
        guard !connected, line.rank != .failed else { return line }
        // Not connected: the record is the last state the service sent. No spinner, no timer.
        line.mark = .hollow
        line.started = nil
        line.sentence = ActivitySentence(parts: subject + [.text(": last known " + lastKnownWord(line))])
        return line
    }

    private func lastKnownWord(_ line: Line) -> String {
        switch kind {
        case .worker, .stop:
            switch state.lowercased() {
            case "completed": "finished"
            case "running": "working"
            default: Self.plain(state)
            }
        case .question: state.lowercased() == "pending" ? "waiting for your answer" : Self.plain(state)
        case .followUp, .integration, .providerChild, .command: Self.plain(state)
        }
    }

    private static func plain(_ word: String) -> String { word.lowercased().replacingOccurrences(of: "_", with: " ") }

    private func known(now: Date) -> Line {
        let word = state.lowercased()
        switch kind {
        case .worker, .stop:
            switch word {
            case "starting":
                return Line(rank: .running, mark: .spinner, sentence: sentence(" is starting"), started: startedAt)
            case "running", "working":
                if let progress,
                   case let display = ClaudeProgressDisplay(track: progress, state: TaskState(api: state), now: now),
                   display.unknownCause == .stale, let age = display.age {
                    return Line(rank: .lostContact, mark: .hollow,
                                sentence: sentence(": no progress reported for " + ClaudeProgressDisplay.ageText(age)))
                }
                if let liveSentence {
                    return Line(rank: .running, mark: .spinner,
                                sentence: ActivitySentence(parts: subject + [.text(": ")] + liveSentence.parts), started: startedAt)
                }
                return Line(rank: .running, mark: .spinner, sentence: sentence(" is working"), started: startedAt)
            case "stopping":
                return Line(rank: .running, mark: .spinner, sentence: sentence(" is stopping"))
            case "completed":
                return Line(rank: .finished, mark: .solid, sentence: sentence(" finished"))
            case "failed":
                let reason = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Line(rank: .failed, mark: .solid, sentence: sentence(" failed"), tag: .failed,
                            reason: reason.isEmpty ? nil : reason)
            case "stopped":
                return Line(rank: .finished, mark: .solid, sentence: sentence(" was stopped"), tag: ActivityTag(word: "cancelled"))
            case "unknown", TaskState.apiDisconnected:
                return Line(rank: .lostContact, mark: .hollow, sentence: sentence(": lost contact with its host."))
            default:
                // A state the wording table does not name (`idle`, `waiting`): the word as sent.
                return Line(rank: .finished, mark: .solid, sentence: sentence(" is " + Self.plain(state)))
            }
        case .question:
            if word == "pending" {
                return Line(rank: .needsYou, mark: .attention, sentence: sentence(" is waiting for your answer"))
            }
            return Line(rank: .lostContact, mark: .hollow,
                        sentence: ActivitySentence(parts: [.text("Answer to "), .strong(name), .text(": delivery unknown")]),
                        tag: ActivityTag(word: "uncertain", tone: .wait))
        case .followUp:
            switch word {
            case "queued":
                // Held for the next turn: not running, so no spinner.
                return Line(rank: .running, mark: .attention, sentence: sentence(" is queued"))
            case "processing":
                return Line(rank: .running, mark: .spinner, sentence: sentence(" is processing"))
            case "completed":
                return Line(rank: .finished, mark: .solid, sentence: sentence(" finished"))
            case "failed":
                return Line(rank: .failed, mark: .solid, sentence: sentence(" failed"), tag: .failed)
            case "cancelled", "canceled":
                return Line(rank: .finished, mark: .solid, sentence: sentence(" was cancelled"), tag: ActivityTag(word: "cancelled"))
            case "interrupted":
                return Line(rank: .finished, mark: .solid, sentence: sentence(" was interrupted"), tag: ActivityTag(word: "interrupted"))
            case "delivery_unknown":
                return Line(rank: .lostContact, mark: .hollow, sentence: sentence(": delivery unknown"),
                            tag: ActivityTag(word: "uncertain", tone: .wait))
            default:
                return Line(rank: .lostContact, mark: .hollow, sentence: sentence(": " + Self.plain(state)))
            }
        case .integration:
            // The same reading of `candidate.status` the call's own tag uses.
            switch CommanderActivityStatus(operation: state) {
            case .queued: return Line(rank: .running, mark: .attention, sentence: sentence(" is queued"))
            case .running:
                return Line(rank: .running, mark: .spinner, sentence: sentence(" is running"), tag: ActivityTag(word: Self.plain(state)))
            case .complete: return Line(rank: .finished, mark: .solid, sentence: sentence(" finished"))
            case .failed, .declined:
                return Line(rank: .failed, mark: .solid, sentence: sentence(" failed"), tag: .failed, reason: Self.plain(state))
            case .cancelled, .interrupted:
                return Line(rank: .finished, mark: .solid, sentence: sentence(" was stopped"), tag: ActivityTag(word: "cancelled"))
            default:
                return Line(rank: .lostContact, mark: .hollow, sentence: sentence(": " + Self.plain(state)),
                            tag: ActivityTag(word: "uncertain", tone: .wait))
            }
        case .providerChild, .command:
            // The seam for the service's records: its own description, with a spinner only once
            // a record is behind it.
            return Line(rank: .running, mark: evidence == .record ? .spinner : .hollow,
                        sentence: ActivitySentence(text ?? Self.plain(state)), started: startedAt)
        }
    }

    /// Whether the stack holds the job at all. A failure stays while its record says failed; an
    /// ended job stays until the console's next prompt; an answered question has no line.
    func isShown(connected: Bool) -> Bool {
        if kind == .question {
            let word = state.lowercased()
            if word == "pending" { return true }
            return evidence == .record && Self.deliveryUnknown.contains((text ?? "").lowercased()) && isSinceLastPrompt
        }
        return line(connected: true).rank == .finished ? isSinceLastPrompt : true
    }

    /// `Question.delivery` values that read "delivery unknown".
    static let deliveryUnknown: Set<String> = ["unknown", "unconfirmed"]
}

// MARK: - The stack's order and caps

/// The lines one surface draws, in order: failed, needs you, running in the order of their
/// calls, lost contact, finished. A failure is never counted away.
struct BackgroundStackLayout: Equatable {
    struct Row: Identifiable, Equatable {
        let job: BackgroundJob
        let line: BackgroundJob.Line
        var id: String { job.id }
    }

    var rows: [Row] = []
    /// Rows behind the count line. It opens them in place.
    var folded: [Row] = []
    /// "and 2 more running", or the PiP's "4 running, 1 needs you". Nil with nothing folded.
    var count: String? = nil
    /// The count line stands for running work over a live connection.
    var countSpins = false
    var isDisconnected = false
    /// "Background work, 6 jobs, 1 failed".
    var spoken = ""

    var isEmpty: Bool { rows.isEmpty && folded.isEmpty }

    static func runningCap(_ density: PrettyDensity) -> Int { density == .regular ? 3 : 2 }

    init(jobs: [BackgroundJob], density: PrettyDensity, connected: Bool, now: Date = Date()) {
        let shown = jobs.filter { $0.isShown(connected: connected) }
            .map { Row(job: $0, line: $0.line(connected: connected, now: now)) }
        // Ranked by what the record says, so a lost connection never reorders the stack.
        let known = Dictionary(jobs.map { ($0.id, $0.line(connected: true, now: now)) }, uniquingKeysWith: { first, _ in first })
        func rows(_ rank: BackgroundJob.Rank) -> [Row] { shown.filter { known[$0.id]?.rank == rank } }
        // Running is what the record says is running. A queued message is held, not running.
        func runs(_ row: Row) -> Bool { known[row.id]?.mark == .spinner }
        let runningWord = connected ? "running" : "last known running"
        let failed = rows(.failed), needsYou = rows(.needsYou), running = rows(.running)
        let lost = rows(.lostContact), finished = rows(.finished)
        isDisconnected = !connected && !shown.isEmpty
        let total = shown.count
        spoken = "Background work, " + (total == 1 ? "1 job" : "\(total) jobs")
            + (failed.isEmpty ? "" : ", \(failed.count) failed")
        switch density {
        case .regular, .compact:
            let cap = Self.runningCap(density)
            let kept = Array(running.prefix(cap)), more = Array(running.dropFirst(cap))
            // A tile has room for what needs the reader and what runs; the rest is behind the count.
            self.rows = failed + needsYou + kept + (density == .regular ? lost + finished : [])
            folded = more + (density == .regular ? [] : lost + finished)
            if !folded.isEmpty {
                count = "and \(folded.count) more" + (folded.allSatisfy(runs) ? (connected ? " " : ", ") + runningWord : "")
            }
        case .pip:
            self.rows = failed
            folded = needsYou + running + lost + finished
            var parts: [String] = []
            let spinning = running.filter(runs).count, held = running.count - spinning
            if spinning > 0 { parts.append("\(spinning) " + runningWord) }
            if held > 0 { parts.append("\(held) queued") }
            if !needsYou.isEmpty { parts.append(needsYou.count == 1 ? "1 needs you" : "\(needsYou.count) need you") }
            if parts.isEmpty, !folded.isEmpty { parts.append("\(folded.count) more") }
            count = parts.isEmpty ? nil : parts.joined(separator: ", ")
            countSpins = connected && spinning > 0
        }
    }
}

// MARK: - The jobs of one console

enum BackgroundJobs {
    /// The run's records, each keyed by its exact ID.
    struct Records {
        var workers: [String: Worker] = [:]
        /// Every request of the run, pending or not.
        var requests: [Question] = []
        /// Integration ID → `candidate.status`.
        var integrations: [String: String] = [:]
        /// A worker's displayed transcript, for its open call and its latest turn.
        var transcript: (Worker) -> [TranscriptEntry] = { _ in [] }
    }

    /// The jobs the calls in `entries` started, in the order of those calls. A call that names no
    /// ID, or an ID the run holds no record for, starts no job.
    static func jobs(entries: [TranscriptEntry], records: Records) -> [BackgroundJob] {
        let lastPrompt = entries.lastIndex(where: \.isFromUser) ?? -1
        var jobs: [BackgroundJob] = []
        var index: [String: Int] = [:]
        func add(_ job: BackgroundJob) {
            if let at = index[job.id] {
                // The same record named again: the later call decides whether it is still recent.
                jobs[at].isSinceLastPrompt = jobs[at].isSinceLastPrompt || job.isSinceLastPrompt
            } else {
                index[job.id] = jobs.count
                jobs.append(job)
            }
        }
        var delegated: [String] = []
        for (position, entry) in entries.enumerated() {
            guard let call = CommanderCall(entry: entry) else { continue }
            let recent = position > lastPrompt
            switch call.tool {
            case .delegate:
                // The worker ID the call returned, or the one the service attached to the call.
                guard let id = call.field("id") ?? call.facts?.workerID, let worker = records.workers[id] else { continue }
                if index[BackgroundJob.Kind.worker.rawValue + ":" + id] == nil { delegated.append(id) }
                add(Self.worker(worker, kind: .worker, recent: recent, records: records))
            case .interrupt, .stopWorker:
                guard let id = call.targetWorker, let worker = records.workers[id] else { continue }
                let key = BackgroundJob.Kind.worker.rawValue + ":" + id
                if let at = index[key] {
                    jobs[at].isSinceLastPrompt = jobs[at].isSinceLastPrompt || recent
                } else {
                    add(Self.worker(worker, kind: .stop, recent: recent, records: records))
                }
            case .send:
                guard let id = call.operationID, let target = call.targetWorker, let worker = records.workers[target],
                      let message = worker.control?.messages?.first(where: { $0.id == id }), !message.status.isEmpty else { continue }
                var job = BackgroundJob(kind: .followUp, recordID: id, state: message.status, name: worker.name,
                                        workerID: worker.id, text: message.text)
                job.isSinceLastPrompt = recent
                add(job)
            case .integrate:
                guard let id = call.operationID, let status = records.integrations[id] else { continue }
                var job = BackgroundJob(kind: .integration, recordID: id, state: status)
                job.isSinceLastPrompt = recent
                add(job)
            default:
                continue
            }
        }
        // A delegated worker's question, by the worker ID its request record names.
        for request in records.requests {
            guard delegated.contains(request.workerID), let worker = records.workers[request.workerID] else { continue }
            let pending = request.status.lowercased() == "pending"
            guard pending || BackgroundJob.deliveryUnknown.contains(request.delivery?.lowercased() ?? "") else { continue }
            var job = BackgroundJob(kind: .question, recordID: request.id, state: request.status, name: worker.name,
                                    workerID: worker.id, requestID: pending ? request.id : nil, text: request.delivery)
            job.isSinceLastPrompt = jobs.first { $0.kind != .question && $0.workerID == worker.id }?.isSinceLastPrompt ?? true
            add(job)
        }
        // A worker waiting on its pending question has the question's line, not a second one.
        let asking = Set(jobs.filter { $0.kind == .question && $0.requestID != nil }.compactMap(\.workerID))
        return jobs.filter { !(($0.kind == .worker || $0.kind == .stop) && $0.state.lowercased() == "waiting" && asking.contains($0.recordID)) }
    }

    private static func worker(_ worker: Worker, kind: BackgroundJob.Kind, recent: Bool, records: Records) -> BackgroundJob {
        var job = BackgroundJob(kind: kind, recordID: worker.id, state: worker.state, name: worker.name,
                                workerID: worker.id, error: worker.error)
        job.isSinceLastPrompt = recent
        let transcript = records.transcript(worker)
        let turn = transcript.lastIndex(where: \.isFromUser).map { Array(transcript[($0 + 1)...]) } ?? transcript
        job.console = turn
        if TaskState(api: worker.state).isActiveTurn, let last = turn.last, case .tool(_, _, nil) = last.kind {
            job.liveSentence = ActivitySteps.step(tool: last, awaitingToolID: nil, facts: .none)?.sentence
        }
        // A start time exists only for the worker's first turn: `created_at`. A later turn has
        // none, so it shows none.
        let prompts = transcript.filter(\.isFromUser).count
        if kind == .worker, prompts <= 1, (worker.control?.messages ?? []).isEmpty {
            job.startedAt = worker.createdAt.flatMap(Self.date)
        }
        job.progress = ClaudeProgressTrack.eligible(worker, isCoordinator: false)
        return job
    }

    static func date(_ value: String) -> Date? {
        (try? Date(value, strategy: .iso8601))
            ?? (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}
