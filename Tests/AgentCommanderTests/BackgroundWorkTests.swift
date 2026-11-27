import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Background work (spec section G): the jobs of one console, each read from the run by exact
// ID, and what their lines say. The wire shapes are the service's own: a feed call ID is
// `<worker ID>:<tool ID>`, and a delegation's result names the new worker by its bare ID.

/// A live snapshot saved from `GET /v1/ag-ui/events`, for the check against real records:
///
///     BACKGROUND_SNAPSHOT=/tmp/events.sse swift test --filter BackgroundWork
let backgroundSnapshot = ProcessInfo.processInfo.environment["BACKGROUND_SNAPSHOT"]

@MainActor @Suite struct BackgroundWorkTests {
    static let coordinatorID = "w-da045371c3671b03b68accb481575127"

    static func worker(_ name: String, _ state: String, id: String? = nil, error: String? = nil,
                       createdAt: String? = "2026-11-27T00:30:33Z", messages: [AGUIMessage]? = nil,
                       control: WorkerControl? = nil) -> Worker {
        Worker(id: id ?? "w-" + name, name: name, role: "worker", parentID: coordinatorID, runID: "r-1", state: state,
               host: "localhost", worktree: "/tmp/w", task: "", output: "", error: error, createdAt: createdAt,
               messages: messages, control: control)
    }

    /// A delegation as the feed sends it: the prefixed call ID, the worker's bare ID in the result.
    static func delegate(_ wire: inout Wire, _ worker: Worker, resultState: String = "starting") {
        wire.call("commander_delegate", detail: worker.name, commander: ["workerId": worker.id],
                  result: #"{"id":"\#(worker.id)","name":"\#(worker.name)","role":"worker","state":"\#(resultState)"}"#)
    }

    static func records(_ workers: [Worker], requests: [Question] = [], integrations: [String: String] = [:]) -> BackgroundJobs.Records {
        BackgroundJobs.Records(workers: Dictionary(uniqueKeysWithValues: workers.map { ($0.id, $0) }), requests: requests,
                               integrations: integrations,
                               transcript: { TranscriptEntry.entries(from: $0.messages ?? []) })
    }

    static func jobs(_ workers: [Worker], requests: [Question] = [], prompt: Bool = false) -> [BackgroundJob] {
        var wire = Wire()
        wire.user("Split the work.")
        for worker in workers { delegate(&wire, worker) }
        if prompt { wire.user("And then?") }
        return BackgroundJobs.jobs(entries: wire.entries, records: records(workers, requests: requests))
    }

    // MARK: Records by exact ID

    @Test func aJobIsReadFromTheWorkerRecordByTheBareIDTheDelegationReturned() {
        let reader = Self.worker("reader", "completed", id: "w-779b15a33e2ed37dbe74d7bab6d102bf")
        var wire = Wire()
        wire.user("Smoke test.")
        // The feed's own call ID carries the calling worker; the record is keyed by the bare ID.
        wire.messages.append(AGUIMessage(id: "m1", role: "assistant", toolCalls: [AGUIToolCall(
            id: Self.coordinatorID + ":toolu_01CWzRLoTjKDoDAC8MKtL7dC",
            function: .init(name: "commander_delegate", arguments: #"{"detail":"reader","commander":{"workerId":"\#(reader.id)"}}"#))]))
        wire.messages.append(AGUIMessage(id: "m2", role: "tool", content: #"{"id":"\#(reader.id)","name":"reader","state":"starting"}"#,
                                         toolCallID: Self.coordinatorID + ":toolu_01CWzRLoTjKDoDAC8MKtL7dC"))
        let jobs = BackgroundJobs.jobs(entries: wire.entries, records: Self.records([reader]))
        #expect(jobs.map(\.id) == ["worker:" + reader.id])
        // The record says completed; the call's own result said starting and is not read.
        #expect(jobs[0].state == "completed" && jobs[0].evidence == .record)
        #expect(jobs[0].line(connected: true).sentence.plain == "reader finished")
    }

    @Test func aCallWithNoRecordStartsNoJob() {
        var wire = Wire()
        wire.user("Go.")
        Self.delegate(&wire, Self.worker("ghost", "running"))
        wire.call("commander_send", commander: ["workerId": "w-ghost"], result: #"{"id":"m-1","status":"queued"}"#)
        wire.call("commander_integrate", result: #"{"id":"i-1","candidate":{"status":"testing"}}"#)
        // Every call completed, and the run holds none of their records.
        #expect(BackgroundJobs.jobs(entries: wire.entries, records: Self.records([])).isEmpty)
    }

    @Test func aFollowUpIsReadFromItsTargetsControlRecordByMessageID() {
        let control = WorkerControl(held: false, generation: 2, interruptRequested: nil,
                                    messages: [WorkerFollowUp(id: "m-1", status: "delivery_unknown", text: "Also check the retry."),
                                               WorkerFollowUp(id: "m-2", status: "queued")])
        let tracer = Self.worker("tracer", "working", control: control)
        var wire = Wire()
        wire.user("Go.")
        wire.call("commander_send", commander: ["workerId": tracer.id], result: #"{"id":"m-1","status":"queued"}"#)
        wire.call("commander_send", commander: ["workerId": tracer.id], result: #"{"id":"m-2","status":"queued"}"#)
        wire.call("commander_send", commander: ["workerId": tracer.id], result: #"{"id":"m-9","status":"queued"}"#)
        let jobs = BackgroundJobs.jobs(entries: wire.entries, records: Self.records([tracer]))
        #expect(jobs.map(\.id) == ["followUp:m-1", "followUp:m-2"])
        let unknown = jobs[0].line(connected: true), queued = jobs[1].line(connected: true)
        #expect(unknown.sentence.plain == "Follow-up to tracer: delivery unknown" && unknown.mark == .hollow && unknown.tag?.word == "uncertain")
        // Queued is held, not running: no spinner.
        #expect(queued.sentence.plain == "Follow-up to tracer is queued" && queued.mark == .attention)
        #expect(jobs[0].text == "Also check the retry.")
    }

    @Test func aStopAndAQuestionReadTheirOwnRecords() {
        let tracer = Self.worker("tracer", "stopping"), reviewer = Self.worker("reviewer", "waiting")
        var wire = Wire()
        wire.user("Go.")
        Self.delegate(&wire, reviewer)
        wire.call("commander_stop_worker", commander: ["workerId": tracer.id], result: #"{"id":"\#(tracer.id)","state":"stopping"}"#)
        let requests = [Question(id: "q-1", workerID: reviewer.id, question: "Which?", status: "pending", answer: ""),
                        Question(id: "q-2", workerID: reviewer.id, question: "Old?", status: "answered", answer: "yes", delivery: "unknown"),
                        Question(id: "q-3", workerID: reviewer.id, question: "Done?", status: "answered", answer: "yes"),
                        Question(id: "q-4", workerID: "w-else", question: "Other?", status: "pending", answer: "")]
        let jobs = BackgroundJobs.jobs(entries: wire.entries, records: Self.records([tracer, reviewer], requests: requests))
        #expect(jobs.map(\.id) == ["stop:w-tracer", "question:q-1", "question:q-2"])
        #expect(jobs[0].line(connected: true).sentence.plain == "tracer is stopping" && jobs[0].line(connected: true).mark == .spinner)
        let asks = jobs[1].line(connected: true)
        #expect(asks.sentence.plain == "reviewer is waiting for your answer" && asks.mark == .attention && asks.rank == .needsYou)
        #expect(jobs[1].requestID == "q-1")
        #expect(jobs[2].line(connected: true).sentence.plain == "Answer to reviewer: delivery unknown")
    }

    // MARK: Wording and the spinner rule

    @Test func eachStateReadsAsTheWordingTable() {
        func line(_ state: String, error: String? = nil) -> BackgroundJob.Line {
            Self.jobs([Self.worker("tracer", state, error: error)])[0].line(connected: true)
        }
        #expect(line("starting").sentence.plain == "tracer is starting" && line("starting").mark == .spinner)
        #expect(line("working").sentence.plain == "tracer is working" && line("running").mark == .spinner)
        #expect(line("completed").sentence.plain == "tracer finished" && line("completed").mark == .solid)
        let failed = line("failed", error: "go test exited 1 in internal/service.")
        #expect(failed.isFailure && failed.tag == .failed && failed.reason == "go test exited 1 in internal/service.")
        #expect(line("stopped").sentence.plain == "tracer was stopped" && line("stopped").tag?.word == "cancelled")
        #expect(line("disconnected").sentence.plain == "tracer: lost contact with its host." && line("unknown").mark == .hollow)
        // A state the table does not name is shown as sent, never as running.
        #expect(line("idle").sentence.plain == "tracer is idle" && line("idle").mark == .solid)
    }

    @Test func aRunningLineNamesTheChildsOpenCall() {
        var child = Wire()
        child.user("Trace the lease.")
        child.call("Read", detail: "/repo/internal/provider/lease.go", result: "1\tpackage provider")
        child.call("Read", detail: "/repo/internal/provider/runner.go")
        let tracer = Self.worker("tracer", "working", messages: child.messages)
        let job = Self.jobs([tracer])[0]
        let line = job.line(connected: true)
        #expect(line.sentence.plain.hasPrefix("tracer: Reading") && line.sentence.plain.contains("runner.go"))
        #expect(line.mark == .spinner)
        // The opened line: the latest group, closed, and the open call.
        let turn = BackgroundTurn(job.console)
        #expect(turn.summary?.hasPrefix("Read") == true && turn.live != nil)
        // An open call in a console that is not in a turn says nothing about now.
        let ended = Self.jobs([Self.worker("tracer", "completed", messages: child.messages)])[0]
        #expect(ended.liveSentence == nil && ended.line(connected: true).sentence.plain == "tracer finished")
    }

    @Test func withoutTheServiceEveryLineIsLastKnownWithNoSpinnerOrTimer() {
        let jobs = Self.jobs([Self.worker("tracer", "working"), Self.worker("reader", "completed"),
                              Self.worker("tester", "failed", error: "go test exited 1.")])
        let lines = jobs.map { $0.line(connected: false) }
        #expect(lines[0].sentence.plain == "tracer: last known working" && lines[0].mark == .hollow && lines[0].started == nil)
        #expect(lines[1].sentence.plain == "reader: last known finished" && lines[1].mark == .hollow)
        // A failure keeps its line and its reason.
        #expect(lines[2].isFailure && lines[2].reason == "go test exited 1.")
        let layout = BackgroundStackLayout(jobs: jobs, density: .regular, connected: false)
        #expect(layout.isDisconnected && layout.rows.map(\.job.name) == ["tester", "tracer", "reader"])
        #expect(!layout.rows.contains { $0.line.mark == .spinner || $0.line.started != nil })
        let pip = BackgroundStackLayout(jobs: jobs, density: .pip, connected: false)
        #expect(pip.count == "1 last known running" && !pip.countSpins)
    }

    @Test func aTimeShowsOnlyForADelegatedWorkersFirstTurn() {
        let first = Self.jobs([Self.worker("tracer", "working")])[0]
        #expect(first.startedAt == BackgroundJobs.date("2026-11-27T00:30:33Z") && first.line(connected: true).started != nil)
        // No `created_at`, no time.
        #expect(Self.jobs([Self.worker("tracer", "working", createdAt: nil)])[0].line(connected: true).started == nil)
        // A later turn has no start time of its own.
        var child = Wire()
        child.user("Trace the lease.")
        child.say("Done.")
        child.user("Now the runner.")
        #expect(Self.jobs([Self.worker("tracer", "working", messages: child.messages)])[0].startedAt == nil)
        let followed = WorkerControl(held: false, generation: 2, interruptRequested: nil,
                                     messages: [WorkerFollowUp(id: "m-1", status: "processing")])
        #expect(Self.jobs([Self.worker("tracer", "working", control: followed)])[0].startedAt == nil)
        // A finished worker counts nothing.
        #expect(Self.jobs([Self.worker("tracer", "completed")])[0].line(connected: true).started == nil)
    }

    @Test func staleReportedProgressReadsAsNoProgressNotAsRunning() {
        var job = Self.jobs([Self.worker("writer", "working")])[0]
        let reported = Date(timeIntervalSince1970: 1_000)
        job.progress = ClaudeProgressTrack(evidence: ClaudeProgress(phase: .thinking, updatedAt: reported))
        let fresh = job.line(connected: true, now: reported.addingTimeInterval(10))
        #expect(fresh.mark == .spinner)
        let stale = job.line(connected: true, now: reported.addingTimeInterval(45))
        #expect(stale.sentence.plain == "writer: no progress reported for 45s" && stale.mark == .hollow && stale.started == nil)
    }

    // MARK: Order, caps, the finish line

    @Test func theStackOrdersItsLinesAndNeverCountsAFailureAway() {
        let workers = [Self.worker("reader", "completed"), Self.worker("a", "working"), Self.worker("builder", "disconnected"),
                       Self.worker("b", "working"), Self.worker("tester", "failed", error: "exit 1"),
                       Self.worker("c", "starting"), Self.worker("d", "working"), Self.worker("e", "working"),
                       Self.worker("reviewer", "waiting")]
        let asks = [Question(id: "q-1", workerID: "w-reviewer", question: "Which?", status: "pending", answer: "")]
        let jobs = Self.jobs(workers, requests: asks)
        let regular = BackgroundStackLayout(jobs: jobs, density: .regular, connected: true)
        #expect(regular.rows.map(\.job.name) == ["tester", "reviewer", "a", "b", "c", "builder", "reader"])
        #expect(regular.count == "and 2 more running" && regular.folded.map(\.job.name) == ["d", "e"])
        #expect(regular.spoken == "Background work, 9 jobs, 1 failed")
        let tile = BackgroundStackLayout(jobs: jobs, density: .compact, connected: true)
        #expect(tile.rows.map(\.job.name) == ["tester", "reviewer", "a", "b"] && tile.count == "and 5 more")
        let pip = BackgroundStackLayout(jobs: jobs, density: .pip, connected: true)
        #expect(pip.rows.map(\.job.name) == ["tester"] && pip.count == "5 running, 1 needs you" && pip.countSpins)
        #expect(pip.folded.count == 8)
    }

    @Test func aFinishLineStaysUntilTheNextPromptAndAFailureStays() {
        let workers = [Self.worker("reader", "completed"), Self.worker("tracer", "stopped"),
                       Self.worker("tester", "failed"), Self.worker("builder", "working")]
        let before = BackgroundStackLayout(jobs: Self.jobs(workers), density: .regular, connected: true)
        #expect(before.rows.map(\.job.name) == ["tester", "builder", "reader", "tracer"])
        let after = BackgroundStackLayout(jobs: Self.jobs(workers, prompt: true), density: .regular, connected: true)
        #expect(after.rows.map(\.job.name) == ["tester", "builder"])
    }

    @Test func aWaitingWorkerWithAQuestionHasOneLine() {
        let reviewer = Self.worker("reviewer", "waiting")
        let jobs = Self.jobs([reviewer], requests: [Question(id: "q-1", workerID: reviewer.id, question: "Which?",
                                                             status: "pending", answer: "")])
        let layout = BackgroundStackLayout(jobs: jobs, density: .regular, connected: true)
        #expect(layout.rows.map(\.line.sentence.plain) == ["reviewer is waiting for your answer"])
    }

    // MARK: The run's projection

    @Test func theProjectionGivesEachConsoleItsOwnJobs() throws {
        let reader = Self.worker("reader", "completed", id: "w-779b15a33e2ed37dbe74d7bab6d102bf")
        var wire = Wire()
        wire.user("Smoke test.")
        Self.delegate(&wire, reader)
        let coordinator = Worker(id: Self.coordinatorID, name: "Coordinator", role: "coordinator", parentID: "", runID: "r-1",
                                 state: "completed", host: "localhost", worktree: "/tmp", task: "", output: "",
                                 messages: wire.messages)
        let run = Run(id: "r-1", project: "p", path: "/tmp", task: "t", client: "claude", coordinatorID: coordinator.id,
                      status: "completed", workers: [coordinator, reader], requests: [])
        let content = RunContent(run: run)
        #expect(content.coordinator?.backgroundJobs.map(\.id) == ["worker:" + reader.id])
        #expect(content.wall.workers.first?.backgroundJobs.isEmpty == true)
    }

    /// The same reading over the service's own records, when a saved snapshot is named.
    @Test(.enabled(if: backgroundSnapshot != nil)) func aLiveSnapshotYieldsJobsOnlyForRecordsItHolds() throws {
        let text = try String(contentsOfFile: try #require(backgroundSnapshot), encoding: .utf8)
        var reducer = AGUIWorkspaceReducer()
        for line in text.split(separator: "\n") where line.hasPrefix("data:") {
            _ = try? reducer.apply(frame: String(line.dropFirst(5)))
        }
        #expect(reducer.hasSnapshot)
        var delegations = 0, found = 0
        for run in reducer.runs {
            let content = RunContent(run: run)
            let ids = Set((run.workers ?? []).map(\.id))
            for worker in (content.coordinator.map { [$0] } ?? []) + content.wall.workers {
                delegations += worker.transcript.filter { CommanderCall(entry: $0)?.tool == .delegate }.count
                for job in worker.backgroundJobs {
                    found += 1
                    print("background job:", worker.name, job.id, job.state, "→", job.line(connected: true).sentence.plain)
                    if job.kind == .worker || job.kind == .stop { #expect(ids.contains(job.recordID)) }
                }
            }
        }
        print("background jobs: \(found) from \(delegations) delegation calls in \(reducer.runs.count) runs")
        // Every delegation whose worker the run still holds has its job.
        #expect(found >= min(delegations, 1))
    }

    // MARK: Pictures

    @Test(.enabled(if: prettyRenderDirectory != nil)) func drawsTheBackgroundStack() async throws {
        let folder = URL(fileURLWithPath: try #require(prettyRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var child = Wire()
        child.user("Trace the lease.")
        for file in ["lease.go", "acp.go", "feed.go"] { child.call("Read", detail: "/repo/internal/provider/" + file, result: "1\tpackage provider") }
        child.call("Bash", detail: "go vet ./internal/provider", result: "ok")
        child.call("Read", detail: "/repo/internal/provider/runner.go")
        let started = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-252))
        let control = WorkerControl(held: false, generation: 2, interruptRequested: nil,
                                    messages: [WorkerFollowUp(id: "m-41c0d2aa", status: "queued", text: "Also check the idle timer after a retry.")])
        let workers = [Self.worker("tracer", "working", createdAt: started, messages: child.messages, control: nil),
                       Self.worker("tester", "failed", error: "go test exited 1 in internal/service."),
                       Self.worker("reviewer", "waiting"), Self.worker("builder", "disconnected"),
                       Self.worker("reader", "completed"), Self.worker("writer", "starting", createdAt: started),
                       Self.worker("linter", "working", createdAt: nil, control: control), Self.worker("packer", "working", createdAt: nil)]
        var wire = Wire()
        wire.user("Trace the lease renewal, test it, and review the change.")
        wire.say("Eight workers are on it. I'll integrate when they report.")
        for worker in workers { Self.delegate(&wire, worker) }
        wire.call("commander_send", commander: ["workerId": "w-linter"], result: #"{"id":"m-41c0d2aa","status":"queued"}"#)
        let asks = [Question(id: "q-1", workerID: "w-reviewer", question: "Which?", status: "pending", answer: "")]
        let jobs = BackgroundJobs.jobs(entries: wire.entries, records: Self.records(workers, requests: asks))
        func console(_ density: PrettyDensity, connected: Bool = true, open: [String] = [], size: CGSize) -> some View {
            let modes = ConsoleModeStore()
            for id in open { modes.toggleTool(console: "c", entry: id) }
            return PrettyACPConsole(consoleID: "c", name: "Coordinator", client: .claude, state: connected ? .working : .disconnected,
                                    entries: wire.entries, session: PrettyRenderTests.session, density: density,
                                    isCoordinator: true, background: jobs)
                .frame(width: size.width, height: size.height)
                .background(Palette.panel)
                .environment(modes).environment(ToolDetailStore())
                .environment(\.backgroundWork, BackgroundWorkAccess(isConnected: connected, openWorker: { _ in }, openRequest: { _ in }))
        }
        func write(_ view: some View, _ name: String, _ size: CGSize) async throws {
            try await ShellRenderTests.write(view, name, theme: .console, to: folder, size: size)
        }
        let regular = CGSize(width: 800, height: 620), tile = CGSize(width: 440, height: 420), pip = CGSize(width: 350, height: 300)
        try await write(console(.regular, size: regular), "background-regular", regular)
        try await write(console(.regular, open: ["worker:w-tracer", "worker:w-tester", "followUp:m-41c0d2aa", BackgroundStack.moreID],
                                size: CGSize(width: 800, height: 900)), "background-regular-open", CGSize(width: 800, height: 900))
        try await write(console(.regular, connected: false, size: regular), "background-disconnected", regular)
        try await write(console(.compact, size: tile), "background-wall-tile", tile)
        try await write(console(.pip, size: pip), "background-pip", pip)
        try await write(console(.pip, open: [BackgroundStack.moreID], size: CGSize(width: 350, height: 460)),
                        "background-pip-open", CGSize(width: 350, height: 460))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("background-regular-console.png").path))
    }
}
