import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The older Claude runner's records in the Pretty transcript (spec sections G and H): background
// jobs, the end-of-turn line, placed thoughts, the section H sentences and cards. The record
// shapes are the contract's own examples; the failure phrases are from real `is_error` results.

@MainActor @Suite struct PrettyRecordsTests {
    static func summaries(_ json: String) throws -> [ToolDetailSummary] {
        try JSONDecoder().decode(ToolDetailPage.self, from: Data(#"{"revision":1,"records":[\#(json)]}"#.utf8)).records
    }

    /// A tool call's own record, which carries the console sequence its entry does not.
    static func tool(_ id: String, _ sequence: Int, name: String = "Bash", fields: String = "{}") -> String {
        #"{"kind":"tool","key":"\#(id)","sequence":\#(sequence),"name":"\#(name)","fields":\#(fields)}"#
    }

    static func store(_ records: [ToolDetailSummary], full: [ToolDetailRecord] = []) -> ToolDetailStore {
        ToolDetailStore(summaries: ["w": records], records: ["w": full])
    }

    static func items(_ wire: Wire, _ records: [ToolDetailSummary], full: [ToolDetailRecord] = []) -> [PrettyItem] {
        let store = store(records, full: full)
        var facts = ActivityFacts(summaries: store.summaries(worker: "w"))
        facts.summary = { store.summary(worker: "w", key: $0) }
        facts.record = { store.record(worker: "w", key: $0) }
        let entries = PrettyRecordPlacement.withThoughts(TranscriptEntry.displayed(wire.entries, mode: .pretty), summaries: records,
                                                         worker: "w", summary: facts.summary, record: facts.record)
        let built = ActivityConversation.items(ConversationActivity.items(entries), facts: facts)
        return PrettyRecordPlacement.withTurnEnds(built, summaries: records, worker: "w", summary: facts.summary)
    }

    // MARK: Every surface gets the background stack

    @Test func theOlderRunnersConsolesReceiveTheWorkersJobs() throws {
        let reader = BackgroundWorkTests.worker("reader", "working")
        var wire = Wire()
        wire.user("Smoke test.")
        BackgroundWorkTests.delegate(&wire, reader)
        let coordinator = Worker(id: BackgroundWorkTests.coordinatorID, name: "Coordinator", role: "coordinator", parentID: "",
                                 runID: "r-1", state: "waiting", host: "localhost", worktree: "/tmp", task: "", output: "",
                                 messages: wire.messages)
        let ask = Question(id: "q-1", workerID: coordinator.id, question: "Which?", status: "pending", answer: "")
        let run = Run(id: "r-1", project: "p", path: "/tmp", task: "t", client: "claude", coordinatorID: coordinator.id,
                      status: "running", workers: [coordinator, reader], requests: [ask])
        let content = RunContent(run: run)
        let presented = try #require(content.coordinator)
        #expect(!presented.backgroundJobs.isEmpty)
        // Coordinator, wall tile and focused worker draw a worker through this initialiser.
        let console = ConsoleScrollback(worker: presented, density: .regular) { EmptyView() }
        #expect(console.pretty.background == presented.backgroundJobs)
        #expect(console.pretty.consoleID == presented.id)
        // The PiP draws the asking worker's recent window with that worker's jobs.
        let request = try #require(content.awaiting.first)
        #expect(!request.workerBackgroundJobs.isEmpty)
        #expect(ConsoleScrollback(request: request, density: .pip) { EmptyView() }.pretty.background == request.workerBackgroundJobs)
    }

    // MARK: A worker that waits for a reply inside its turn

    @Test func aWorkerWaitingForAReplyInsideItsTurnIsStillInItsTurn() throws {
        func content(askerState: String) -> RunContent {
            var child = Wire()
            child.user("Ask before you write.")
            child.call("commander_ask", commander: ["requestId": "q-1"], result: #"{"id":"q-1","status":"pending"}"#)
            child.call("commander_wait", commander: ["requestId": "q-1"])
            let asker = BackgroundWorkTests.worker("asker", askerState, messages: child.messages)
            var wire = Wire()
            wire.user("Split the work.")
            BackgroundWorkTests.delegate(&wire, asker)
            let coordinator = Worker(id: BackgroundWorkTests.coordinatorID, name: "Coordinator", role: "coordinator", parentID: "",
                                     runID: "r-1", state: "working", host: "localhost", worktree: "/tmp", task: "", output: "",
                                     messages: wire.messages)
            let ask = Question(id: "q-1", workerID: asker.id, question: "Which file?", status: "pending", answer: "")
            return RunContent(run: Run(id: "r-1", project: "p", path: "/tmp", task: "t", client: "claude",
                                       coordinatorID: coordinator.id, status: "running", workers: [coordinator, asker], requests: [ask]))
        }
        let running = content(askerState: "working")
        let asker = try #require(running.wall.workers.first)
        // It reads needs-input, and the service says its turn is running.
        #expect(asker.state == .needsInput && asker.turnIsRunning && asker.isInTurn)
        let live = PrettyLive(state: asker.state, workerName: asker.name, turnIsRunning: asker.turnIsRunning)
        // The open call spins; nothing is inferred after it.
        #expect(live.isActive && !live.isDisconnected && live.trailing == nil)
        #expect(running.awaiting.first?.workerTurnIsRunning == true)
        // The coordinator's line for the child is the child's own live sentence, in table A's words.
        let job = try #require(running.coordinator?.backgroundJobs.first { $0.kind == .worker })
        #expect(job.line(connected: true).sentence.plain == "asker: Waiting for a reply")
        #expect(job.line(connected: true).mark == .spinner)

        // A worker the service calls waiting, finished or disconnected stays as it was.
        for state in ["waiting", "completed", "disconnected"] {
            let other = try #require(content(askerState: state).wall.workers.first)
            #expect(!other.turnIsRunning && !other.isInTurn)
            #expect(!PrettyLive(state: other.state, workerName: other.name, turnIsRunning: other.turnIsRunning).isActive)
        }
        #expect(!PrettyLive(state: .needsInput, workerName: "asker").isActive)
    }

    // MARK: Background jobs from `job` records

    @Test func aJobRecordIsJoinedToItsCallByExactToolUseID() throws {
        var wire = Wire()
        wire.user("Check and inspect.")
        let shell = wire.call("Bash", detail: "echo ok", result: "started")
        let agent = wire.call("Agent", detail: "Inspect the example", result: "launched")
        let records = try Self.summaries(#"""
        {"kind":"job","key":"job-a","sequence":4,"revision":9,"tool_use_id":"\#(agent)","job_kind":"agent","title":"Inspect the example","state":"running","started_at":"2026-01-02T03:04:05Z","open_tool_name":"Read","open_tool_arg":"example.go"},
        {"kind":"job","key":"job-b","sequence":2,"revision":12,"tool_use_id":"\#(shell)","job_kind":"command","title":"Check the example","state":"completed","started_at":"2026-01-02T03:04:05Z","ended_at":"2026-01-02T03:04:07Z","result_bytes":64},
        {"kind":"job","key":"job-c","sequence":2,"tool_use_id":"call-elsewhere","job_kind":"command","title":"Old watch","state":"completed"},
        {"kind":"job","key":"job-d","sequence":2,"tool_use_id":"call-x","job_kind":"hook","title":"Not a job kind","state":"running"}
        """#)
        let full = ToolDetailRecord(key: "job-b", kind: "job", result: #"Background command "Check the example" completed (exit code 0)"#)
        let jobs = ProviderJobs.jobs(summaries: records, record: { $0 == "job-b" ? full : nil }, entries: wire.entries, worker: "w")
        // In the order of their calls. An unknown kind gives no job.
        #expect(jobs.map(\.id) == ["command:" + shell, "providerChild:" + agent, "command:call-elsewhere"])
        let command = jobs[0].line(connected: true), child = jobs[1].line(connected: true)
        #expect(command.sentence.plain == "\u{201C}Check the example\u{201D} finished" && command.mark == .solid)
        #expect(jobs[0].result?.contains("exit code 0") == true)
        // The child's open call is its live sentence; the time is the record's own start.
        #expect(child.sentence.plain == "Inspect the example: Reading example.go" && child.mark == .spinner)
        #expect(child.started == ToolDetailSummary.date("2026-01-02T03:04:05Z"))
        #expect(command.started == nil)
        // A finished job whose call this console no longer holds has no line.
        #expect(jobs[2].isShown(connected: true) == false)
        #expect(ProviderJobs.recordsToRead(records) == ["job-b"])
    }

    @Test func aJobNeverSpinsWithoutARunningRecordAndALiveConnection() throws {
        var wire = Wire()
        wire.user("Go.")
        let call = wire.call("Bash", detail: "make watch", result: "started")
        func job(_ state: String) throws -> BackgroundJob {
            let records = try Self.summaries(#"{"kind":"job","key":"j","sequence":2,"tool_use_id":"\#(call)","job_kind":"command","title":"Watch the build","state":"\#(state)","started_at":"2026-01-02T03:04:05Z"}"#)
            return try #require(ProviderJobs.jobs(summaries: records, entries: wire.entries, worker: "w").first)
        }
        // The stream was lost while the job ran: no end is claimed.
        let unknown = try job("unknown").line(connected: true)
        #expect(unknown.mark == .hollow && unknown.rank == .lostContact && unknown.started == nil)
        #expect(unknown.sentence.plain == "\u{201C}Watch the build\u{201D}: lost contact. Last known: running.")
        let offline = try job("running").line(connected: false)
        #expect(offline.mark == .hollow && offline.started == nil)
        #expect(offline.sentence.plain == "\u{201C}Watch the build\u{201D}: last known running")
        #expect(try job("running").line(connected: true).mark == .spinner)
        let failed = try job("failed").line(connected: true)
        #expect(failed.rank == .failed && failed.tag == .failed)
        #expect(try job("stopped").line(connected: true).tag == ActivityTag(word: "cancelled"))
        // The original tool returning is not evidence: with no record there is no job.
        #expect(ProviderJobs.jobs(summaries: [], entries: wire.entries, worker: "w").isEmpty)
    }

    // MARK: Hidden secrets in a job's texts (issue #73)

    static let bearer = "abcdefghijklmnop", key = "sk-abcdefghijklmnopqrstuv", jwt = "eyJhbGciOi.eyJzdWIiOi.signature"

    @Test func proseHidesEverySecretShapeAndKeepsTheRest() {
        func masked(_ text: String) -> String { SecretValues.masked(prose: text).text }
        // The known forms, with the punctuation, quotes and line ends prose puts around them.
        #expect(masked("Refused: Authorization: Bearer \(Self.bearer).") == "Refused: Authorization: Bearer Hidden, 16 characters.")
        #expect(masked("used \(Self.key)\nthen stopped") == "used Hidden, 25 characters\nthen stopped")
        #expect(masked("The token \"\(Self.jwt)\". Retry.") == "The token \"Hidden, 31 characters\". Retry.")
        // A value joined to a secret-looking key.
        #expect(masked("API_TOKEN=abc123 make deploy") == "API_TOKEN=Hidden, 6 characters make deploy")
        #expect(masked("login --password='hunter2' failed") == "login --password='Hidden, 7 characters' failed")
        #expect(masked("GET https://x.test/y?token=abc1234 gave 403") == "GET https://x.test/y?token=Hidden, 7 characters gave 403")
        #expect(masked(#"sent {"cookie":"sid=1","n":1}"#).contains("sid=1") == false)
        // Whole JSON is masked as Source masks it.
        let json = SecretValues.masked(prose: #"{"password":"hunter2","path":"/x"}"#)
        #expect(json.count == 1 && !json.text.contains("hunter2") && json.text.contains("path"))
        let several = SecretValues.masked(prose: "Bearer \(Self.bearer) and \(Self.key) and SECRET=x1")
        #expect(several.count == 3)
        // Ordinary words stay: a key with no joined value, an idempotency key, plain prose.
        for plain in ["Invalid token: expired", "idempotency_key=k1 was reused", "nothing here", "exit code 1: skip this"] {
            let result = SecretValues.masked(prose: plain)
            #expect(result.text == plain && result.count == 0, "\(plain)")
        }
    }

    /// One job from one `job` record and its full copy.
    private static func job(state: String, title: String = "Deploy the build", result: String, open: String = "",
                            hidesSecrets: Bool) throws -> (job: BackgroundJob, full: ToolDetailRecord) {
        var wire = Wire()
        wire.user("Go.")
        let call = wire.call("Bash", detail: "make deploy", result: "started")
        let records = try summaries(#"{"kind":"job","key":"j","sequence":2,"tool_use_id":"\#(call)","job_kind":"command","title":"\#(title)","state":"\#(state)","result_bytes":64\#(open)}"#)
        let full = ToolDetailRecord(key: "j", kind: "job", result: result)
        let jobs = ProviderJobs.jobs(summaries: records, record: { _ in full }, entries: wire.entries, worker: "w",
                                     hidesSecrets: hidesSecrets)
        return (try #require(jobs.first), full)
    }

    @Test func aFailedJobsSentenceIsCutFromTheMaskedSummary() throws {
        let summary = "Upload refused for Bearer \(Self.bearer) with API_TOKEN=abc123 and \(Self.jwt). Retry later.\n\(Self.key)"
        let (job, full) = try Self.job(state: "failed", result: summary, hidesSecrets: true)
        let line = job.line(connected: true)
        // Masked whole, then cut at the first sentence's own end.
        #expect(line.reason == "Upload refused for Bearer Hidden, 16 characters with API_TOKEN=Hidden, 6 characters and Hidden, 31 characters.")
        // The line, the VoiceOver label and the announcement are all built from these.
        for text in [line.reason ?? "", line.spoken, line.sentence.plain, job.error ?? "", job.hiddenResult ?? ""] {
            for secret in [Self.bearer, "abc123", Self.jwt, Self.key] { #expect(!text.contains(secret), "\(text)") }
        }
        #expect(line.isFailure && line.tag == .failed && job.hiddenCount == 4)
        // The summary as stored is kept, on the job and in the record.
        #expect(job.result == summary && full.result == summary)
    }

    @Test func aFinishedJobsSummaryIsHiddenUntilReveal() throws {
        let summary = "Background command \"Deploy the build\" completed (exit code 0)\nexport API_KEY=\(Self.key)"
        let (job, _) = try Self.job(state: "completed", result: summary, hidesSecrets: true)
        // What the opened line draws, and what Reveal shows.
        #expect(job.hiddenResult == "Background command \"Deploy the build\" completed (exit code 0)\nexport API_KEY=Hidden, 25 characters")
        #expect(job.hiddenCount == 1 && job.result == summary && job.error == nil)
        #expect(job.line(connected: true).sentence.plain == "\u{201C}Deploy the build\u{201D} finished")
        // A summary with nothing to hide offers no Reveal.
        let clean = try Self.job(state: "completed", result: "completed (exit code 0)", hidesSecrets: true).job
        #expect(clean.hiddenResult == nil && clean.hiddenCount == 0 && clean.result == "completed (exit code 0)")
        // The description and the child's open call are masked in the sentence too.
        let running = try Self.job(state: "running", title: "Deploy with API_TOKEN=abc123", result: "",
                                   open: #","open_tool_name":"Bash","open_tool_arg":"curl -H Authorization: Bearer \#(Self.bearer) https://x.test""#,
                                   hidesSecrets: true).job
        let spoken = running.line(connected: true).spoken
        #expect(!spoken.contains("abc123") && !spoken.contains(Self.bearer) && spoken.contains("Hidden, 16 characters"))
        // A long call is masked before the sentence cuts it in the middle: no part of the key is left.
        let long = "sk-" + String(repeating: "abcdefgh", count: 12)
        let cut = try Self.job(state: "running", result: "",
                               open: #","open_tool_name":"Bash","open_tool_arg":"deploy --region eu-west-1 --key \#(long) --wait""#,
                               hidesSecrets: true).job.line(connected: true).spoken
        #expect(!cut.contains("sk-") && !cut.contains("abcdefgh") && cut.contains("Hidden, 99 characters"))
    }

    @Test func withTheSettingOffAJobsTextsAreAsStored() throws {
        let summary = "Upload refused for Bearer \(Self.bearer). Retry later."
        let failed = try Self.job(state: "failed", title: "Deploy with API_TOKEN=abc123", result: summary, hidesSecrets: false).job
        #expect(failed.result == summary && failed.hiddenResult == nil && failed.hiddenCount == 0)
        #expect(failed.line(connected: true).reason == "Upload refused for Bearer \(Self.bearer).")
        #expect(failed.line(connected: true).sentence.plain == "\u{201C}Deploy with API_TOKEN=abc123\u{201D} failed")
        let done = try Self.job(state: "completed", result: "export API_KEY=\(Self.key)", hidesSecrets: false).job
        #expect(done.result == "export API_KEY=\(Self.key)" && done.hiddenResult == nil)
        // The default is off, as before.
        var wire = Wire()
        wire.user("Go.")
        let call = wire.call("Bash", detail: "make deploy", result: "started")
        let records = try Self.summaries(#"{"kind":"job","key":"j","sequence":2,"tool_use_id":"\#(call)","job_kind":"command","title":"Deploy","state":"failed","result_bytes":9}"#)
        let byDefault = ProviderJobs.jobs(summaries: records, record: { _ in ToolDetailRecord(key: "j", kind: "job", result: summary) },
                                          entries: wire.entries, worker: "w")
        #expect(byDefault.first?.error == "Upload refused for Bearer \(Self.bearer)." && byDefault.first?.hiddenResult == nil)
    }

    /// A store whose service answers the setting read with `answer`, or fails it while nil.
    private final class SettingsService: @unchecked Sendable {
        var answer: TranscriptSettings?
        var reads = 0
    }

    @MainActor private static func liveStore(_ service: SettingsService) -> ToolDetailStore {
        ToolDetailStore(source: ToolDetailSource(
            page: { _, _ in ToolDetailPage(revision: 0, records: []) },
            record: { _, key in ToolDetailRecord(key: key, kind: "job") },
            readSettings: {
                service.reads += 1
                guard let answer = service.answer else { throw ServiceError.offline("starting") }
                return answer
            },
            writeSettings: { $0 }))
    }

    @Test @MainActor func aJobsTextsAreHiddenUntilTheServiceSaysWhatWasSaved() async throws {
        let service = SettingsService()
        let store = Self.liveStore(service)
        let summary = "export API_KEY=\(Self.key)"
        // At launch nothing is known, so the transcript masks as if the setting were on.
        #expect(store.hidesSecrets && !store.settingsLoaded && !store.settings.hideSecrets)
        let early = try Self.job(state: "completed", result: summary, hidesSecrets: store.hidesSecrets).job
        #expect(early.hiddenResult == "export API_KEY=Hidden, 25 characters" && early.hiddenCount == 1)
        // A read the service fails leaves it hidden, and the next one asks again.
        await store.loadSettingsIfNeeded()
        #expect(store.hidesSecrets && service.reads == 1)
        // The service holds "keep everything": the texts are as stored from then on.
        service.answer = TranscriptSettings()
        await store.loadSettingsIfNeeded()
        #expect(!store.hidesSecrets && store.settingsLoaded && service.reads == 2)
        #expect(try Self.job(state: "completed", result: summary, hidesSecrets: store.hidesSecrets).job.hiddenResult == nil)
        // Known once per service: it is not read again.
        await store.loadSettingsIfNeeded()
        #expect(service.reads == 2)
        // A store of fixed values reads nothing, and keeps the setting it was given.
        #expect(!ToolDetailStore().hidesSecrets && !Self.store([]).hidesSecrets)
        #expect(ToolDetailStore(summaries: [:], settings: TranscriptSettings(hideSecrets: true)).hidesSecrets)
    }

    @Test @MainActor func aChangeOfServiceHidesAgainAndDropsTheLastServicesAnswer() async {
        let service = SettingsService()
        service.answer = TranscriptSettings()
        let store = Self.liveStore(service)
        await store.loadSettingsIfNeeded()
        #expect(!store.hidesSecrets)
        // Another host: its setting is unknown, so values are hidden until it answers.
        store.serviceChanged()
        #expect(store.hidesSecrets && !store.settingsLoaded)
        service.answer = TranscriptSettings(hideSecrets: true)
        await store.loadSettingsIfNeeded()
        #expect(store.hidesSecrets && store.settingsLoaded && store.settings.hideSecrets)

        // An answer still on its way from the service just left is not applied to the new one.
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let slow = ToolDetailStore(source: ToolDetailSource(
            page: { _, _ in ToolDetailPage(revision: 0, records: []) },
            record: { _, key in ToolDetailRecord(key: key, kind: "job") },
            readSettings: {
                didStart.yield()
                for await _ in release { break }
                return TranscriptSettings()
            },
            writeSettings: { $0 }))
        let read = Task { await slow.loadSettingsIfNeeded() }
        for await _ in started { break }
        slow.serviceChanged()
        doRelease.yield()
        await read.value
        #expect(slow.hidesSecrets && !slow.settingsLoaded)
    }

    @Test func revealShowsOnlyTheTextItWasPressedOn() {
        let stored = "export API_KEY=\(Self.key)", hidden = "export API_KEY=Hidden, 25 characters"
        let pressed = SecretText.Reveal(text: stored, hidden: hidden)
        #expect(SecretText.shown(text: stored, hidden: hidden, revealed: nil) == hidden)
        #expect(SecretText.shown(text: stored, hidden: hidden, revealed: pressed) == stored)
        // The job's summary changed under an open line: the new one is drawn hidden.
        let next = "export API_KEY=sk-another-key-entirely-000", nextHidden = "export API_KEY=Hidden, 26 characters"
        #expect(SecretText.shown(text: next, hidden: nextHidden, revealed: pressed) == nextHidden)
        // The same text masked differently is not what was revealed either.
        #expect(SecretText.shown(text: stored, hidden: "export Hidden, 34 characters", revealed: pressed) == "export Hidden, 34 characters")
        // With nothing hidden the text is plain.
        #expect(SecretText.shown(text: "completed (exit code 0)", hidden: nil, revealed: pressed) == "completed (exit code 0)")
    }

    @Test func aFailedJobsOpenedLineNeverHoldsTheStoredSummary() throws {
        // The failure line draws `line.reason` and nothing else from the record: the stack's
        // detail leaves the exit summary out of a failed line, so it has no Reveal.
        let summary = "Upload refused for Bearer \(Self.bearer) with API_TOKEN=abc123. Retry later."
        let job = try Self.job(state: "failed", result: summary, hidesSecrets: true).job
        let layout = BackgroundStackLayout(jobs: [job], density: .regular, connected: true)
        let row = try #require((layout.rows + layout.folded).first)
        #expect(row.line.isFailure && BackgroundStack.exitSummary(row) == nil)
        let done = try Self.job(state: "completed", result: summary, hidesSecrets: true).job
        let doneLayout = BackgroundStackLayout(jobs: [done], density: .regular, connected: true)
        let doneRow = try #require((doneLayout.rows + doneLayout.folded).first)
        #expect(BackgroundStack.exitSummary(doneRow) == summary)
    }

    // MARK: The end-of-turn line

    @Test func aTurnHasOneEndLineHoweverManyResultsArrive() throws {
        var wire = Wire()
        wire.user("Run it in the background.")          // w:1
        let call = wire.call("Bash", detail: "echo ok", result: "started")   // w:2, result w:3
        wire.say("Done.")                               // w:4
        wire.say("The background command finished.")    // w:5
        wire.user("Next.")                              // w:6
        wire.say("Sure.")                               // w:7
        let records = try Self.summaries(#"""
        \#(Self.tool(call, 2)),
        {"kind":"turn_end","key":"turn-end-one","sequence":4,"revision":13,"duration_ms":192000,"stop_reason":"end_turn","terminal_reason":"completed","is_error":false},
        {"kind":"turn_end","key":"turn-end-two","sequence":5,"revision":14,"duration_ms":9,"is_error":false},
        {"kind":"turn_end","key":"turn-end-three","sequence":7,"revision":15,"stop_reason":"max_tokens","duration_ms":4000}
        """#)
        let items = Self.items(wire, records)
        let ends = items.enumerated().compactMap { index, item -> (Int, PrettyTurnEnd)? in
            if case .turnEnd(let end) = item { return (index, end) }
            return nil
        }
        #expect(ends.count == 2)
        // The turn's own result gives the time; the line sits after the last event the records name.
        #expect(ends[0].1.sentence.plain == "Worked for 3m 12s" && ends[0].1.tone == .secondary)
        if case .entry(let before) = items[ends[0].0 - 1] { #expect(before.id == "w:5") } else { Issue.record("not after the last prose") }
        if case .entry(let after) = items[ends[0].0 + 1] { #expect(after.isFromUser) } else { Issue.record("not before the prompt") }
        // A stop reason wins over a duration.
        #expect(ends[1].1.sentence.plain == "Stopped: reached the output limit" && ends[1].1.tone == .attention)
        #expect(ends[1].0 == items.count - 1)
    }

    @Test func stopReasonsReadAsSectionH() throws {
        func line(_ fields: String) throws -> PrettyTurnEnd? {
            PrettyTurnEnd(try #require(try Self.summaries(#"{"kind":"turn_end","key":"k","sequence":1,\#(fields)}"#).first))
        }
        #expect(try line(#""stop_reason":"max_turn_requests""#)?.sentence.plain == "Stopped: reached the request limit for one turn")
        #expect(try line(#""stop_reason":"refusal""#)?.sentence.plain == "The model declined to continue")
        #expect(try line(#""stop_reason":"cancelled""#)?.tone == .secondary)
        // `end_turn` has no line of its own: with no duration there is nothing to say.
        #expect(try line(#""stop_reason":"end_turn""#) == nil)
        // Zero is a duration; an error with no named reason reads "Stopped".
        #expect(try line(#""duration_ms":0,"is_error":false"#)?.sentence.plain == "Worked for 1s")
        #expect(try line(#""duration_ms":10,"is_error":true"#)?.sentence.plain == "Stopped")
    }

    @Test func aRecordIsLeftOutWhenItsPlaceIsNotKnown() throws {
        var wire = Wire()
        wire.user("Go.")                                           // w:1
        wire.call("Bash", detail: "ls", result: "a")               // no stored record: no sequence
        wire.say("Done.")                                          // w:4
        let end = #"{"kind":"turn_end","key":"e","sequence":1,"duration_ms":2000,"stop_reason":"end_turn"}"#
        // The record names event 1; the call after it has no known sequence, so it could be either side.
        #expect(!Self.items(wire, try Self.summaries(end)).contains { if case .turnEnd = $0 { true } else { false } })
        // No sequence at all: never placed.
        let unplaced = #"{"kind":"turn_end","key":"e","duration_ms":2000,"stop_reason":"end_turn"}"#
        #expect(!Self.items(wire, try Self.summaries(unplaced)).contains { if case .turnEnd = $0 { true } else { false } })
    }

    // MARK: Thoughts

    @Test func aThoughtRecordIsPlacedBySequenceWithItsTime() throws {
        var wire = Wire()
        wire.user("Think, then read.")                                   // w:1
        let read = wire.call("Read", detail: "/repo/a.go", result: "ok")  // w:2
        wire.say("Read it.")                                             // w:4
        let records = try Self.summaries(#"""
        \#(Self.tool(read, 2, name: "Read")),
        {"kind":"thought","key":"thought-1","sequence":1,"revision":6,"started_at":"2026-01-02T03:04:05.733Z","ended_at":"2026-01-02T03:04:17.79Z","result_bytes":20},
        {"kind":"thought","key":"thought-0","revision":5,"result_bytes":20}
        """#)
        let full = ToolDetailRecord(key: "thought-1", kind: "thought", result: "The file is small.")
        let items = Self.items(wire, records, full: [full])
        guard case .group(let group) = items[1] else { Issue.record("no group after the prompt"); return }
        // The thought sits before the read, as one line of the same group. The one with no
        // sequence is not placed.
        #expect(group.lines.map(\.sentence.plain) == ["Thought for 12s", "Read a.go"])
        #expect(group.lines[0].text == "The file is small." && group.lines[0].opens)
        #expect(PrettyRecordPlacement.thoughtsToRead(records) == ["thought-1"])
    }

    // MARK: Section H sentences

    @Test func theProvidersOwnToolsReadAsSentences() throws {
        func words(_ name: String, _ fields: String = "{}", input: String? = nil) throws -> ActivityWording {
            let summary = try #require(try Self.summaries(Self.tool("c", 1, name: name, fields: fields)).first)
            return ActivityWords.provider(name: name, detail: nil, summary: summary,
                                          record: input.map { ToolDetailRecord(key: "c", kind: "tool", input: $0) })
        }
        #expect(try words("ToolSearch").done.plain == "Loaded tools")
        #expect(try words("ToolSearch").running.plain == "Loading tools")
        #expect(try words("SendMessage", #"{"to":"tracer"}"#).done.plain == "Sent tracer a message")
        #expect(try words("SendMessage").done.plain == "Sent a message")
        #expect(try words("Agent", #"{"description":"Inspect the example"}"#).done.plain == "Started a child agent: Inspect the example")
        #expect(try words("Agent").failed.plain == "Couldn't start a child agent")
        #expect(try words("Monitor", #"{"description":"the build log"}"#).done.plain == "Started watching: the build log")
        #expect(try words("Monitor").tag == ActivityTag(word: "accepted"))
        #expect(try words("CronCreate", #"{"prompt":"Check the queue","cron":"0 9 * * *"}"#).done.plain == "Scheduled \u{201C}Check the queue\u{201D}")
        #expect(try words("sleep").done.plain == "Waited" && words("wait").running.plain == "Waiting")
        #expect(try words("exec", #"{"command":"go vet ./..."}"#).done.plain == "Ran go vet ./...")
        #expect(try words("js").done.plain == "Ran a script")
        #expect(try words("ExitPlanMode").done.plain == "Proposed a plan")
        #expect(try words("Artifact", #"{"action":"publish","title":"Release notes"}"#).done.plain == "Published Release notes")
        #expect(try words("SendUserFile", input: #"{"files":["/tmp/out/report.pdf","/tmp/out/data.csv"]}"#).done.plain
                == "Sent you report.pdf and 1 more file")
        let ask = #"{"questions":[{"question":"Which database?","header":"Storage","multiSelect":false,"options":[{"label":"Postgres","description":"Already deployed"},{"label":"SQLite"}]}]}"#
        #expect(try words("AskUserQuestion", input: ask).done.plain == "Asked: \u{201C}Which database?\u{201D}")
        // An extension's tool of the same bare name keeps the generic sentence, as does an
        // artifact call that is not a publish.
        #expect(try words("mcp__timer__wait").done.plain == "Used wait")
        #expect(try words("Artifact", #"{"action":"list"}"#).done.plain == "Used Artifact")
    }

    @Test func knownFailuresReadFromTheirRealPhrases() {
        func read(_ text: String) -> ActivityFailure { ActivityFailureWords.read(ToolResult(output: text, error: "Tool failed."), status: .failed) }
        let declined = read("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file).")
        #expect(declined.reason == "You declined this." && declined.tag == .blocked)
        let hook = read("PreToolUse:Bash hook error: [python3 guard.py]: refused")
        #expect(hook.reason == "A hook blocked this." && hook.tag == .blocked)
        #expect(read("Permission for this command was denied by a built-in Claude Code safety check.").tag == .blocked)
        #expect(read("Permission for this action was denied by the Claude Code auto mode classifier. Reason: [x]").tag == .blocked)
        #expect(read("Permission to use Bash has been denied.").reason == "Permission to use this tool was denied.")
        #expect(read("Claude requested permissions to write to /tmp/a.txt but you haven't granted it yet.").tag == .blocked)
        let interrupted = read("[Tool call interrupted: the session ended before this call's result was recorded]")
        #expect(interrupted.reason == "Interrupted." && interrupted.tag == ActivityTag(word: "cancelled", tone: .wait))
        // Half a framed phrase is not a match.
        #expect(read("PreToolUse:Bash ran fine").tag == .failed)
    }

    /// The whole `is_error` result of a real Claude Code Bash call: `sleep 2` under a 100 ms limit.
    static let shellTimeout = "Exit code 143\nCommand timed out after 0s"

    @Test func aShellTimeoutReadsFromItsRealResult() {
        func read(_ text: String) -> ActivityFailure { ActivityFailureWords.read(ToolResult(output: text, error: "Tool failed."), status: .failed) }
        let timeout = read(Self.shellTimeout)
        #expect(timeout.reason == "Timed out." && timeout.tag == .failed && timeout.outcome == .failed)
        // The provider's own text is kept exactly, one click away.
        #expect(timeout.exact == "Exit code 143" && timeout.rest == "Command timed out after 0s")
        // The same result when the service sends it as the error text.
        #expect(ActivityFailureWords.read(ToolResult(output: "", error: Self.shellTimeout), status: .failed).reason == "Timed out.")
        // Longer limits, as Claude Code writes a duration, and output the command left behind.
        #expect(read("Exit code 143\nCommand timed out after 2m 0s").reason == "Timed out.")
        #expect(read("Exit code 143\nCommand timed out after 1h 0m 0s").reason == "Timed out.")
        let withOutput = read("Exit code 143\nCommand timed out after 30s\nstep 1 of 4")
        #expect(withOutput.reason == "Timed out." && withOutput.rest == "Command timed out after 30s\nstep 1 of 4")

        // Everything else keeps the provider's first sentence and the `Failed` tag.
        let unchanged: [(String, String)] = [
            // The phrase without the exit line it arrived with.
            ("Command timed out after 2m 0s", "Command timed out after 2m 0s"),
            // An ordinary SIGTERM.
            ("Exit code 143", "Exit code 143"),
            ("Exit code 143\nTerminated: 15", "Exit code 143"),
            // Another exit code, or the lines in another order or apart.
            ("Exit code 1\nCommand timed out after 0s", "Exit code 1"),
            ("Exit code 1433\nCommand timed out after 0s", "Exit code 1433"),
            ("Command timed out after 0s\nExit code 143", "Command timed out after 0s"),
            ("Exit code 143\nstep 1 of 4\nCommand timed out after 0s", "Exit code 143"),
            ("Exit code 143 Command timed out after 0s", "Exit code 143 Command timed out after 0s"),
            // A mention: quoted, or inside a longer line.
            ("Exit code 143\n\u{201C}Command timed out after 0s\u{201D}", "Exit code 143"),
            ("Exit code 143\necho: Command timed out after 0s", "Exit code 143"),
            (#"grep: "Exit code 143" then "Command timed out after 0s" not found"#,
             #"grep: "Exit code 143" then "Command timed out after 0s" not found"#),
            // Not a duration.
            ("Exit code 143\nCommand timed out after", "Exit code 143"),
            ("Exit code 143\nCommand timed out after a while", "Exit code 143"),
            ("Exit code 143\nCommand timed out after 0s.", "Exit code 143"),
            ("Exit code 143\nCommand timed out after 0s and was killed", "Exit code 143"),
            ("Exit code 143\nCommand timed out after 0s 2m", "Exit code 143"),
            ("Exit code 143\nCommand timed out after 2m  0s", "Exit code 143"),
            ("Exit code 143\nCommand timed out after -1s", "Exit code 143"),
            ("Exit code 143\nCommand timed out after 1.5s", "Exit code 143"),
            ("Exit code 143\nCommand timed out after 120000ms", "Exit code 143"),
            ("Exit code 143\ncommand timed out after 0s", "Exit code 143"),
        ]
        for (text, first) in unchanged {
            let failure = read(text)
            let note = Comment(rawValue: text)
            #expect(failure.reason == first && failure.exact == first && failure.tag == .failed, note)
        }
        // A permission error that mentions a timeout is still the denial it states.
        let denied = read("Permission to use Bash has been denied.\nExit code 143\nCommand timed out after 0s")
        #expect(denied.reason == "Permission to use this tool was denied." && denied.tag == .blocked)
        // A declined request keeps its own words whatever its text holds.
        #expect(ActivityFailureWords.read(ToolResult(output: Self.shellTimeout, error: "Tool declined."), status: .declined).reason
                == "You denied this.")
    }

    @Test func aShellTimeoutIsAFailureLineInTheTranscript() throws {
        var wire = Wire()
        wire.user("Wait two seconds.")
        let slept = wire.call("Bash", detail: "sleep 2", result: Self.shellTimeout, error: "Tool failed.")
        let records = try Self.summaries(Self.tool(slept, 2, fields: #"{"command":"sleep 2","timeout":100}"#))
        let failures = Self.items(wire, records).flatMap { item -> [ActivityStep] in
            if case .group(let group) = item { group.failures } else { [] }
        }
        let step = try #require(failures.first)
        #expect(failures.count == 1 && step.tag == .failed)
        #expect(step.failure?.reason == "Timed out." && step.failure?.exact == "Exit code 143")
        #expect(step.failure?.rest == "Command timed out after 0s")
        #expect(step.accessibilityLabel.hasSuffix("Failed, Timed out."))
        // The entry Console and Terminal read still holds the provider's text as it arrived.
        let kept = TranscriptEntry.displayed(wire.entries, mode: .console).contains { entry in
            switch entry.kind {
            case .tool(_, _, let result?), .output(let result): result.output == Self.shellTimeout
            default: false
            }
        }
        #expect(kept)
    }

    /// The whole result of a real managed Claude ACP Read of a missing file; its error was "Tool failed.".
    static let missingFileNote = "Note: your current working directory is /private/tmp/ac-read72.QFN76C/Read QA."
    static let missingFile = "Tool failed.\n```\nFile does not exist. \(missingFileNote)\n```"

    @Test func aFencedMissingFileReadsAsItsDiagnosticInTheTranscript() throws {
        var wire = Wire()
        wire.user("Read missing.txt.")
        wire.call("Read", detail: "/private/tmp/ac-read72.QFN76C/Read QA/missing.txt", result: Self.missingFile, error: "Tool failed.")
        let failures = Self.items(wire, []).flatMap { item -> [ActivityStep] in
            if case .group(let group) = item { group.failures } else { [] }
        }
        let step = try #require(failures.first)
        #expect(failures.count == 1 && step.tag == .failed && step.failure?.outcome == .failed)
        #expect(step.failure?.reason == "File does not exist." && step.failure?.exact == "File does not exist.")
        #expect(step.failure?.rest == Self.missingFileNote)
        #expect(step.accessibilityLabel.hasSuffix("Failed, File does not exist."))
        // The opened line, before its stored record arrives: the same failure, and Source holds
        // the result as it arrived, fences included.
        let source = ActivityResultSource(entry: try #require(step.entries.first), step: step, record: nil)
        #expect(source.failure == step.failure && source.statusWord == "failed" && source.resultText == Self.missingFile)
        // So does the entry Console and Terminal read.
        let kept = TranscriptEntry.displayed(wire.entries, mode: .console).contains { entry in
            if case .tool(_, _, let result?) = entry.kind { result.output == Self.missingFile && result.error == "Tool failed." } else { false }
        }
        #expect(kept)
    }

    @Test func onlyTheWholeFencedMissingFileResultIsUnwrapped() {
        func read(_ text: String) -> ActivityFailure { ActivityFailureWords.read(ToolResult(output: text, error: "Tool failed."), status: .failed) }
        #expect(read("Tool failed.\n```\nFile does not exist.\n```") == ActivityFailure(outcome: .failed, reason: "File does not exist.", exact: "File does not exist."))

        // Everything else reads as it did before.
        let unchanged: [(String, String)] = [
            // Another diagnostic in the same wrapper, and one that only starts alike.
            ("Tool failed.\n```\nPermission denied.\n```", "```"),
            ("Tool failed.\n```\nFile does not exist.txt is a directory.\n```", "```"),
            // Cut short, or closed by something else.
            ("Tool failed.\n```\nFile does not exist. \(Self.missingFileNote)", "```"),
            ("Tool failed.\n```\nFile does not exist.\n", "```"),
            ("Tool failed.\n```\nFile does not exist.\n~~~", "```"),
            ("Tool failed.\n```\nFile does not exist.\n````", "```"),
            // A fence with a language, an indented one, or a fence inside.
            ("Tool failed.\n```text\nFile does not exist.\n```", "```text"),
            ("Tool failed.\n ```\nFile does not exist.\n ```", "```"),
            ("Tool failed.\n```\nFile does not exist.\n```\nmore\n```", "```"),
            // Text around the wrapper, or no service line before it.
            ("Tool failed.\n```\nFile does not exist.\n```\nTry another path.", "```"),
            ("Tool failed.\nRead:\n```\nFile does not exist.\n```", "Read:"),
            ("```\nFile does not exist.\n```", "```"),
            // A mention.
            ("Tool failed.\ngrep: \"```\nFile does not exist.\n```\" not found", "grep: \"```"),
        ]
        for (text, first) in unchanged {
            let failure = read(text)
            #expect(failure.reason == first && failure.exact == first && failure.tag == .failed, Comment(rawValue: text))
        }
        // Without fences the diagnostic was already the first sentence.
        #expect(read("Tool failed.\nFile does not exist. \(Self.missingFileNote)").rest == Self.missingFileNote)
        // A declined request and a known denial keep their own words; a timeout is still a timeout.
        #expect(ActivityFailureWords.read(ToolResult(output: Self.missingFile, error: "Tool declined."), status: .declined).reason == "You denied this.")
        let denied = read("Tool failed.\n```\nFile does not exist. Permission to use Read has been denied.\n```")
        #expect(denied.reason == "Permission to use this tool was denied." && denied.tag == .blocked)
        #expect(read(Self.shellTimeout).reason == "Timed out.")

        // A result that succeeded is not a failure, whatever it quotes.
        var wire = Wire()
        wire.call("Read", detail: "/tmp/notes.md", result: Self.missingFile)
        let failed = Self.items(wire, []).contains { item in
            if case .group(let group) = item { !group.failures.isEmpty } else { false }
        }
        #expect(!failed)
    }

    // MARK: Cards

    @Test func aWaitingQuestionAPlanAndADeliverableStandInTheOpen() throws {
        var wire = Wire()
        wire.user("Plan it, publish it, then ask.")
        wire.call("Read", detail: "/repo/a.go", result: "ok")
        let plan = wire.call("ExitPlanMode", result: "User has approved your plan.")
        let artifact = wire.call("Artifact", result: "Published https://claude.ai/artifact/abc123.")
        let listed = wire.call("Artifact", result: "[]")
        let ask = wire.call("AskUserQuestion")
        let records = try Self.summaries([Self.tool(plan, 4, name: "ExitPlanMode"),
                                          Self.tool(artifact, 6, name: "Artifact", fields: #"{"action":"publish","title":"Release notes"}"#),
                                          Self.tool(listed, 8, name: "Artifact", fields: #"{"action":"list"}"#),
                                          Self.tool(ask, 10, name: "AskUserQuestion")].joined(separator: ","))
        let items = Self.items(wire, records)
        let cards = items.compactMap { item -> PrettyToolCard? in if case .card(let card) = item { card } else { nil } }
        #expect(cards.map(\.kind) == [.plan, .deliverable, .question])
        #expect(cards.map(\.step.sentence.plain) == ["Proposed a plan", "Published Release notes", "Asking"])
        // The artifact that only listed is an ordinary folded line.
        #expect(items.contains { if case .group(let group) = $0 { group.lines.contains { $0.sentence.plain == "Used Artifact" } } else { false } })

        let input = #"{"questions":[{"question":"Which database?","multiSelect":true,"options":[{"label":"Postgres","description":"Already deployed"},{"label":"SQLite"}]}]}"#
        let questions = PrettyChoiceQuestion.questions(input: input)
        #expect(questions.first?.options.map(\.label) == ["Postgres", "SQLite"] && questions.first?.allowsSeveral == true)
        // A stored input that was cut short is not read.
        #expect(PrettyChoiceQuestion.questions(input: String(input.prefix(60))).isEmpty)
        #expect(PrettyToolInput.plan(input: ###"{"plan":"# Steps\n1. Read","planFilePath":"/tmp/p.md"}"###, summary: nil) == "# Steps\n1. Read")
        let made = PrettyDeliverable(name: "Artifact", input: nil, summary: records[1],
                                     result: ToolResult(output: "Published https://claude.ai/artifact/abc123."))
        #expect(made.files.first?.name == "Release notes" && made.files.first?.url?.absoluteString == "https://claude.ai/artifact/abc123")
        // Two addresses: no Open, since the call's result does not say which one it is.
        #expect(PrettyDeliverable(name: "Artifact", input: nil, summary: records[1],
                                  result: ToolResult(output: "https://a.example/x https://b.example/y")).files.first?.url == nil)
        // A failed question or plan is the failure line, never a card.
        #expect(PrettyToolCard.kind(name: "ExitPlanMode", result: ToolResult(output: "", error: "Tool failed."), summary: nil) == nil)
    }

    // MARK: Pictures

    @Test(.enabled(if: prettyRenderDirectory != nil)) func drawsTheOlderRunnersRecords() async throws {
        let folder = URL(fileURLWithPath: try #require(prettyRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var wire = Wire()
        wire.user("Check the build in the background, inspect the lease code, and propose a plan.")           // 1
        let read = wire.call("Read", detail: "/repo/internal/provider/lease.go", result: "1\tpackage provider")  // 2
        let search = wire.call("ToolSearch", result: "3 tools")                                                // 4
        let shell = wire.call("Bash", detail: "make watch", result: "started")                                 // 6
        let agent = wire.call("Agent", detail: "Inspect the lease renewal", result: "launched")               // 8
        let lost = wire.call("Bash", detail: "tail -f build.log", result: "started")                           // 10
        let broken = wire.call("Bash", detail: "go test ./...", result: "started")                             // 12
        let denied = wire.call("Bash", detail: "rm -rf build",
                               result: "PreToolUse:Bash hook error: [python3 guard.py]: refused", error: "Tool failed.")              // 14
        let plan = wire.call("ExitPlanMode", result: "User has approved your plan.")                           // 16
        let file = wire.call("SendUserFile", result: "sent")                                                   // 18
        wire.say("The plan is approved and the report is with you. The watch and the child agent are still going.")  // 20
        wire.user("Which store should the lease use?")                                                         // 21
        let ask = wire.call("AskUserQuestion")                                                                 // 22
        let started = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-192))
        let records = try Self.summaries([
            Self.tool(read, 2, name: "Read"), Self.tool(search, 4, name: "ToolSearch"),
            Self.tool(shell, 6, fields: #"{"command":"make watch","description":"Watch the build"}"#),
            Self.tool(agent, 8, name: "Agent", fields: #"{"description":"Inspect the lease renewal"}"#),
            Self.tool(lost, 10), Self.tool(broken, 12), Self.tool(denied, 14),
            Self.tool(plan, 16, name: "ExitPlanMode"), Self.tool(file, 18, name: "SendUserFile"),
            Self.tool(ask, 22, name: "AskUserQuestion"),
            #"{"kind":"thought","key":"th-1","sequence":1,"started_at":"2026-01-02T03:04:05.7Z","ended_at":"2026-01-02T03:04:17.8Z","result_bytes":9}"#,
            #"{"kind":"job","key":"job-shell","sequence":6,"tool_use_id":"\#(shell)","job_kind":"command","title":"Watch the build","state":"running","started_at":"\#(started)"}"#,
            #"{"kind":"job","key":"job-agent","sequence":8,"tool_use_id":"\#(agent)","job_kind":"agent","title":"Inspect the lease renewal","state":"running","started_at":"\#(started)","open_tool_name":"Read","open_tool_arg":"/repo/internal/provider/runner.go"}"#,
            #"{"kind":"job","key":"job-lost","sequence":10,"tool_use_id":"\#(lost)","job_kind":"command","title":"Follow the build log","state":"unknown","started_at":"\#(started)"}"#,
            #"{"kind":"job","key":"job-broken","sequence":12,"tool_use_id":"\#(broken)","job_kind":"command","title":"Run the tests","state":"failed","started_at":"\#(started)","ended_at":"\#(started)","result_bytes":60}"#,
            #"{"kind":"turn_end","key":"end-1","sequence":20,"duration_ms":192000,"stop_reason":"end_turn","terminal_reason":"completed","is_error":false}"#,
        ].joined(separator: ","))
        let full = [
            ToolDetailRecord(key: "th-1", kind: "thought", result: "The lease is renewed in two places."),
            ToolDetailRecord(key: "job-broken", kind: "job", result: #"Background command "Run the tests" failed (exit code 1)"#),
            ToolDetailRecord(key: plan, kind: "tool", input: ###"{"plan":"## Lease renewal\n\n1. Move the renewal timer into `lease.go`.\n2. Retry once after a lost write.\n3. Cover both with a test."}"###),
            ToolDetailRecord(key: file, kind: "tool", input: #"{"files":["/tmp/out/lease-report.pdf"],"caption":"The lease trace, with timings."}"#),
            ToolDetailRecord(key: ask, kind: "tool", input: #"{"questions":[{"question":"Which store should the lease use?","multiSelect":false,"options":[{"label":"Postgres","description":"Already deployed for the relay"},{"label":"SQLite","description":"One file beside the service"}]}]}"#),
        ]
        func console(_ density: PrettyDensity, connected: Bool = true, size: CGSize) -> some View {
            // What `ConsoleScrollback` draws for the older runner: no ACP session.
            PrettyConsoleView(consoleID: "w", entries: wire.entries, rawOutput: "", density: density,
                              live: PrettyLive(state: connected ? .working : .disconnected, workerName: "Coordinator"),
                              reportsAsCoordinator: true)
                .frame(width: size.width, height: size.height)
                .background(Palette.panel)
                .environment(ConsoleModeStore()).environment(Self.store(records, full: full))
                .environment(\.backgroundWork, BackgroundWorkAccess(isConnected: connected))
        }
        func write(_ view: some View, _ name: String, _ size: CGSize) async throws {
            try await ShellRenderTests.write(view, name, theme: .console, to: folder, size: size)
        }
        let regular = CGSize(width: 800, height: 1000), tile = CGSize(width: 440, height: 560), pip = CGSize(width: 350, height: 430)
        try await write(console(.regular, size: regular), "records-regular", regular)
        try await write(console(.regular, connected: false, size: regular), "records-disconnected", regular)
        try await write(console(.compact, size: tile), "records-wall-tile", tile)
        try await write(console(.pip, size: pip), "records-pip", pip)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("records-regular-console.png").path))
    }

    /// A finished job opened to its exit summary and a failed job, with the setting on and off.
    @Test(.enabled(if: prettyRenderDirectory != nil)) func drawsAJobsHiddenSecrets() async throws {
        let folder = URL(fileURLWithPath: try #require(prettyRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var wire = Wire()
        wire.user("Deploy the build and publish the notes.")
        let deploy = wire.call("Bash", detail: "make deploy", result: "started")
        let publish = wire.call("Bash", detail: "make publish", result: "started")
        let records = try Self.summaries([
            Self.tool(deploy, 2, fields: #"{"command":"make deploy","description":"Deploy the build"}"#),
            Self.tool(publish, 4, fields: #"{"command":"make publish","description":"Publish the notes"}"#),
            #"{"kind":"job","key":"job-deploy","sequence":2,"tool_use_id":"\#(deploy)","job_kind":"command","title":"Deploy the build","state":"completed","result_bytes":90}"#,
            #"{"kind":"job","key":"job-publish","sequence":4,"tool_use_id":"\#(publish)","job_kind":"command","title":"Publish the notes","state":"failed","result_bytes":90}"#,
        ].joined(separator: ","))
        let full = [
            ToolDetailRecord(key: "job-deploy", kind: "job",
                             result: "Background command \"Deploy the build\" completed (exit code 0)\nexport API_KEY=\(Self.key)\nAuthorization: Bearer \(Self.bearer)"),
            ToolDetailRecord(key: "job-publish", kind: "job",
                             result: "Upload refused for Bearer \(Self.bearer) with API_TOKEN=abc123. Retry later."),
        ]
        func console(hidesSecrets: Bool, size: CGSize) -> some View {
            let modes = ConsoleModeStore()
            modes.toggleTool(console: "w", entry: "command:" + deploy)
            return PrettyConsoleView(consoleID: "w", entries: wire.entries, rawOutput: "", density: .regular,
                                     live: PrettyLive(state: .working, workerName: "Coordinator"), reportsAsCoordinator: true)
                .frame(width: size.width, height: size.height)
                .background(Palette.panel)
                .environment(modes)
                .environment(ToolDetailStore(summaries: ["w": records], records: ["w": full],
                                             settings: TranscriptSettings(hideSecrets: hidesSecrets)))
                .environment(\.backgroundWork, BackgroundWorkAccess(isConnected: true))
        }
        let size = CGSize(width: 800, height: 460)
        try await ShellRenderTests.write(console(hidesSecrets: true, size: size), "records-secrets-hidden", theme: .console, to: folder, size: size)
        try await ShellRenderTests.write(console(hidesSecrets: false, size: size), "records-secrets-shown", theme: .console, to: folder, size: size)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("records-secrets-hidden-console.png").path))
    }
}
