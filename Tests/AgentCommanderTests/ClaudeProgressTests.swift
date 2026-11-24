import Foundation
import Testing
@testable import AgentCommander

// Quiet local Claude ACP workers: the `claude_progress` member, who carries a track, the display
// freshness policy at an injected time, the age timeline, and the Pretty status that no longer
// infers work for a tracked worker.

private let reportedAt = "2026-11-24T14:16:28.250Z"
private let reportedDate = ClaudeProgress.parseDate(reportedAt)!

private func workerJSON(id: String = "w2", role: String = "worker", state: String = "working",
                        harness: String? = "local-claude", progress: String? = nil) -> String {
    let session = harness.map { #""native_session":{"harness_instance":"\#($0)","session_id":"sess-1"},"# } ?? ""
    let member = progress.map { #""claude_progress":\#($0),"# } ?? ""
    return #"{"id":"\#(id)","name":"\#(id)","role":"\#(role)","parent_id":"w1","run_id":"r1","state":"\#(state)","host":"localhost","worktree":"/tmp/w","task":"build","error":"",\#(session)\#(member)"outputChunks":[],"messages":[]}"#
}

private func worker(_ json: String) throws -> Worker { try Worker(projection: AGUIValue(json: json)) }

private func progress(_ phase: String, at time: String = reportedAt) -> String {
    #"{"updated_at":"\#(time)","phase":"\#(phase)"}"#
}

private func display(_ phase: ClaudeProgress.Phase?, state: TaskState, age: TimeInterval) -> ClaudeProgressDisplay {
    let track = ClaudeProgressTrack(evidence: phase.map { ClaudeProgress(phase: $0, updatedAt: reportedDate) })
    return ClaudeProgressDisplay(track: track, state: state, now: reportedDate.addingTimeInterval(age))
}

// MARK: - Parsing and eligibility

@Test func progressReadsEveryPhaseWithOrWithoutFractionalSeconds() throws {
    for phase in ClaudeProgress.Phase.allCases {
        let evidence = try #require(ClaudeProgressTrack.eligible(
            worker(workerJSON(progress: progress(phase.rawValue))), isCoordinator: false)?.evidence)
        #expect(evidence.phase == phase)
        #expect(evidence.updatedAt == reportedDate)
    }
    let fields = try AGUIValue(json: #"{"claude_progress":\#(progress("thinking", at: "2026-11-24T14:16:28Z"))}"#)
    let plain = try #require(ClaudeProgress.reported(fields: fields))
    #expect(plain.phase == .thinking)
    #expect(plain.updatedAt == reportedDate.addingTimeInterval(-0.25))
    #expect(ClaudeProgress.Phase.toolPending.label == "Tool pending")
    #expect(ClaudeProgress.Phase.toolReported.label == "Tool reported")
}

@Test func unreadableProgressIsNoEvidence() throws {
    for member in [progress("streaming"), progress("tool_running", at: "yesterday"), progress("tool_running", at: ""),
                   #"{"phase":"tool_running"}"#, #"{"updated_at":"\#(reportedAt)"}"#, "null", #""tool_running""#, "[]"] {
        let track = try #require(ClaudeProgressTrack.eligible(worker(workerJSON(progress: member)), isCoordinator: false))
        #expect(track.evidence == nil, "\(member)")
    }
    // An older service or a newly bound worker omits the member: still tracked, with no evidence.
    let omitted = try #require(ClaudeProgressTrack.eligible(worker(workerJSON()), isCoordinator: false))
    #expect(omitted.evidence == nil)
}

@Test func onlyDelegatedWorkersOnTheLocalClaudeSessionAreTracked() throws {
    let report = progress("tool_running")
    #expect(try ClaudeProgressTrack.eligible(worker(workerJSON(progress: report)), isCoordinator: false) != nil)
    #expect(try ClaudeProgressTrack.eligible(worker(workerJSON(role: "coordinator", progress: report)), isCoordinator: true) == nil)
    #expect(try ClaudeProgressTrack.eligible(worker(workerJSON(harness: "claude-code-acp", progress: report)), isCoordinator: false) == nil)
    #expect(try ClaudeProgressTrack.eligible(worker(workerJSON(harness: "codex-acp", progress: report)), isCoordinator: false) == nil)
    #expect(try ClaudeProgressTrack.eligible(worker(workerJSON(harness: nil, progress: report)), isCoordinator: false) == nil)
}

@Test func liveMappingCarriesTheTrackToTheWorkerAndNotTheCoordinator() throws {
    let coordinator = workerJSON(id: "w1", role: "coordinator", progress: progress("responding"))
    let delegated = workerJSON(id: "w2", progress: progress("tool_running"))
    let codex = workerJSON(id: "w3", harness: "codex-acp", progress: progress("tool_running"))
    let json = #"{"runs":[{"id":"r1","project":"p","path":"/p","task":"t","client":"claude","coordinator_id":"w1","status":"running","requests":[],"workers":[\#(coordinator),\#(delegated),\#(codex)]}]}"#
    let content = try RunContent(run: #require(Run.list(json: Data(json.utf8)).first))
    #expect(content.coordinator?.claudeProgress == nil)
    let byID = Dictionary(uniqueKeysWithValues: content.wall.workers.map { ($0.id, $0) })
    #expect(byID["w2"]?.claudeProgress?.evidence?.phase == .toolRunning)
    #expect(byID["w3"]?.claudeProgress == nil)
}

// MARK: - Display freshness policy

@Test func openTurnWithoutEvidenceIsUnknown() {
    let shown = display(nil, state: .working, age: 0)
    #expect(shown.unknownCause == .noEvidence)
    #expect(shown.isVisible)
    #expect(shown.reportText == nil)
    #expect(shown.statement.hasPrefix("Progress unknown"))
}

@Test func openTurnCrossesTheStaleBoundaryAtThirtySeconds() {
    #expect(display(.toolRunning, state: .working, age: 0).unknownCause == nil)
    #expect(display(.toolRunning, state: .running, age: 29.9).unknownCause == nil)
    #expect(display(.toolRunning, state: .working, age: 30).unknownCause == .stale)
    #expect(display(.thinking, state: .starting, age: 600).unknownCause == .stale)
    // The cause and the last report, with no disclaimer.
    let stale = display(.toolRunning, state: .working, age: 41)
    #expect(stale.statement.contains("no Claude update in the last 30 seconds"))
    #expect(stale.statement.contains("Tool running"))
    #expect(stale.statement.contains("41 seconds ago"))
    #expect(!stale.statement.contains("stall"))
}

@Test func unknownProgressKeepsTheLastPhaseTimeAndAge() {
    // The visible report is the same whether progress is known or unknown, so the unknown face
    // never drops the last phase, its clock time or its advancing age.
    let known = display(.toolRunning, state: .working, age: 12)
    let stale = display(.toolRunning, state: .working, age: 41)
    let unknownState = display(.responding, state: .unknown("unknown"), age: 75)
    let prior = display(.turnCompleted, state: .working, age: 3)
    for shown in [known, stale, unknownState, prior] {
        let clock = shown.clock ?? "missing"
        #expect(shown.reportText?.contains(" · \(clock) · ") == true)
    }
    #expect(known.reportText?.hasPrefix("tool running · ") == true)
    #expect(known.reportText?.hasSuffix(" · 12s") == true)
    #expect(stale.reportText?.hasSuffix(" · 41s") == true)
    #expect(unknownState.reportText?.hasPrefix("responding · ") == true)
    #expect(unknownState.reportText?.hasSuffix(" · 1m") == true)
    #expect(prior.reportText?.hasPrefix("turn completed · ") == true)
}

@Test func priorTurnOutcomeDuringAnOpenTurnIsUnknown() {
    for phase: ClaudeProgress.Phase in [.turnCompleted, .turnInterrupted, .turnFailed, .turnEnded] {
        #expect(display(phase, state: .working, age: 1).unknownCause == .priorTurnOutcome)
        // With no open turn, the same outcome is simply the last report.
        #expect(display(phase, state: .idle, age: 1).unknownCause == nil)
    }
}

@Test func explicitUnknownStateIsUnknownWithOrWithoutEvidence() {
    #expect(display(nil, state: .unknown("unknown"), age: 0).unknownCause == .unknownState)
    #expect(display(.responding, state: .unknown("unknown"), age: 2).unknownCause == .unknownState)
}

@Test func waitingAndClosedWorkersShowTheirLastReportAndAreNeverUnknown() {
    let waiting = display(.permissionRequested, state: .needsInput, age: 3600)
    #expect(waiting.unknownCause == nil)
    #expect(waiting.isVisible)
    #expect(waiting.lastReport.contains("Permission requested"))
    for state: TaskState in [.idle, .completed, .failed, .stopped, .stopping, .disconnected] {
        let shown = display(.turnCompleted, state: state, age: 7200)
        #expect(shown.unknownCause == nil, "\(state)")
        #expect(shown.isVisible, "\(state)")
    }
    // A known worker without a report draws nothing.
    #expect(!display(nil, state: .needsInput, age: 0).isVisible)
    #expect(!display(nil, state: .idle, age: 0).isVisible)
}

@Test func ageIsNeverNegativeAndUsesWholeUnits() {
    #expect(display(.thinking, state: .working, age: -5).age == 0)
    #expect(ClaudeProgressDisplay.ageText(0) == "0s")
    #expect(ClaudeProgressDisplay.ageText(29.99) == "29s")
    #expect(ClaudeProgressDisplay.ageText(61) == "1m")
    #expect(ClaudeProgressDisplay.ageText(7200) == "2h")
    #expect(ClaudeProgressDisplay.ageText(200_000) == "2d")
    #expect(ClaudeProgressDisplay.ageWords(1) == "1 second")
}

// MARK: - Timeline

@Test func ageScheduleTicksOnTheBoundaryWithoutStreamTraffic() {
    let schedule = ClaudeProgressAgeSchedule(anchor: reportedDate)
    let start = reportedDate.addingTimeInterval(27.4)
    let ticks = Array(schedule.entries(from: start, mode: .normal).prefix(5))
        .map { $0.timeIntervalSince(reportedDate) }
    #expect(ticks == [27, 28, 29, 30, 31])
    // After the first minute it ticks on whole minutes.
    let later = Array(schedule.entries(from: reportedDate.addingTimeInterval(125), mode: .normal).prefix(3))
        .map { $0.timeIntervalSince(reportedDate) }
    #expect(later == [120, 180, 240])
}

// MARK: - Pretty status

@Test func trackedWorkerPrettyStatusInfersNoWork() {
    let entries = [TranscriptEntry(id: "c1", kind: .tool(name: "Bash", detail: nil, result: nil))]
    let tracked = PrettyRunStatus(state: .working, entries: entries, reportsProgress: true)
    #expect(tracked.phase == .active(.working))
    #expect(!tracked.isLive)
    #expect(tracked.word == "Working")
    // A waiting worker keeps its approval reading.
    let waiting = PrettyRunStatus(state: .needsInput, entries: entries, reportsProgress: true)
    #expect(waiting.phase == .waiting)
    #expect(waiting.awaitingToolID(choiceRequestPending: true) == "c1")
    // Every other provider is unchanged.
    #expect(PrettyRunStatus(state: .working, entries: entries).phase == .runningTool("Bash"))
}

@Test func trackedWorkerPrettyStatusKeepsAnExplicitUnknownState() {
    let tracked = PrettyRunStatus(state: .unknown("unknown"), entries: [], reportsProgress: true)
    #expect(tracked.phase == .active(.unknown("unknown")))
    #expect(tracked.word == "Unknown")
    #expect(!tracked.isLive)
    // Untracked workers keep their existing reading.
    #expect(PrettyRunStatus(state: .unknown("unknown"), entries: []).phase == .idle)
    #expect(PrettyRunStatus(state: .idle, entries: [], reportsProgress: true).phase == .idle)
}
