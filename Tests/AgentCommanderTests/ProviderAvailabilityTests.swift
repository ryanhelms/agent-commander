import Foundation
import Testing
@testable import AgentCommander

// `provider_availability` on a worker: `exited` or `checking`; `available` or absent for normal
// behavior. The same value through the legacy feed and the incremental projection, its presentation
// beside the worker's own task state, and the one control gate (take and hand back alike) for
// exited and checking versus other workers.

private func control(held: Bool) -> String { #"{"held":\#(held),"generation":3}"# }

private func workerJSON(id: String, role: String = "worker", state: String = "completed", error: String = "",
                        availability: String? = nil, held: Bool = false) -> String {
    let member = availability.map { #""provider_availability":\#($0),"# } ?? ""
    return #"{"id":"\#(id)","name":"\#(id)","role":"\#(role)","parent_id":"lead","run_id":"r","state":"\#(state)","host":"localhost","worktree":"/tmp/w","task":"build","error":"\#(error)","native_session":{"harness_instance":"local-claude","session_id":"sess-\#(id)"},"control":\#(control(held: held)),\#(member)"outputChunks":[],"messages":[]}"#
}

private func runJSON(_ workers: [String]) -> String {
    #"{"id":"r","project":"p","path":"/p","task":"ship it","client":"claude","coordinator_id":"lead","status":"running","requests":[],"workers":[\#(workers.joined(separator: ","))]}"#
}

/// The service's `error` while checking. A contract value.
private let restartReason = "Service restarted. Waiting for evidence from the original worker."

private let fixtureWorkers = [
    workerJSON(id: "lead", role: "coordinator", state: "working", availability: #""checking""#),
    // The service releases the lease once the exit is confirmed.
    workerJSON(id: "exited", state: "completed", availability: #""exited""#),
    workerJSON(id: "idleExited", state: "idle", availability: #""exited""#),
    workerJSON(id: "checking", state: "unknown", error: restartReason, availability: #""checking""#, held: true),
    workerJSON(id: "checkingIdle", state: "idle", availability: #""checking""#),
    workerJSON(id: "normal", state: "completed", held: true),
    workerJSON(id: "available", state: "idle", availability: #""available""#, held: true),
    workerJSON(id: "future", state: "idle", availability: #""paused""#),
    workerJSON(id: "nulled", state: "idle", availability: "null")
]

private let normalWorkers = ["normal", "available", "future", "nulled"]

@Suite @MainActor struct ProviderAvailabilityTests {
    // MARK: Projection

    @Test func readsOnlyTheTwoContractValues() throws {
        func read(_ member: String?) throws -> ProviderAvailability? {
            try ProviderAvailability(worker: Worker(projection: AGUIValue(json: workerJSON(id: "w", availability: member))))
        }
        #expect(try read(#""exited""#) == .exited)
        #expect(try read(#""checking""#) == .checking)
        // `available`, absent, null, unknown or the wrong kind is the existing behavior.
        for member in [#""available""#, nil, "null", #""paused""#, #""EXITED""#, #""""#, "true", "1", #"{"state":"exited"}"#] {
            #expect(try read(member) == nil, "\(member ?? "absent")")
        }
    }

    @Test func legacyFeedAndRequestDecoderAgree() throws {
        let json = workerJSON(id: "w", availability: #""checking""#)
        let decoded = try JSONDecoder().decode(Worker.self, from: Data(json.utf8))
        let projected = try Worker(projection: AGUIValue(json: json))
        #expect(ProviderAvailability(worker: decoded) == .checking)
        #expect(ProviderAvailability(worker: projected) == .checking)
    }

    @Test func presentationKeepsTheWorkersOwnState() throws {
        let content = try RunContent(run: #require(Run.list(json: Data(#"{"runs":[\#(runJSON(fixtureWorkers))]}"#.utf8)).first))
        // The contract names delegates only: a coordinator is unchanged.
        #expect(content.coordinator?.providerAvailability == nil)
        let byID = Dictionary(uniqueKeysWithValues: content.wall.workers.map { ($0.id, $0) })

        let exited = try #require(byID["exited"])
        #expect(exited.providerAvailability == .exited)
        #expect(exited.state == .completed)
        #expect(byID["idleExited"]?.state == .idle)
        #expect(byID["idleExited"]?.providerAvailability == .exited)

        let checking = try #require(byID["checking"])
        #expect(checking.providerAvailability == .checking)
        if case .unknown = checking.state {} else { Issue.record("checking keeps Unknown, got \(checking.state)") }
        #expect(byID["checkingIdle"]?.state == .idle)

        for id in normalWorkers {
            #expect(byID[id]?.providerAvailability == nil, "\(id)")
            #expect(byID[id]?.availabilityStatement == nil, "\(id)")
        }
    }

    // MARK: Words

    @Test func statementsAreCompactAndOwnTheRestartReasonOnce() {
        let exited = ProviderAvailabilityStatement(availability: .exited, serviceError: "adapter EOF", workerName: "Timeout cases")
        #expect(exited.label == "Claude adapter exited")
        #expect(exited.reason == nil)
        // An exited worker's own error line is unchanged.
        #expect(!exited.suppressesConsoleNotice)
        #expect(exited.statement.contains("Timeout cases"))

        let checking = ProviderAvailabilityStatement(availability: .checking, serviceError: "  \(restartReason)\n",
                                                     workerName: "Timeout cases")
        #expect(checking.label == "Checking Claude session")
        #expect(checking.reason == restartReason)
        #expect(checking.suppressesConsoleNotice)
        #expect(checking.statement.hasPrefix(restartReason))

        for empty in [nil, "", "   "] {
            let bare = ProviderAvailabilityStatement(availability: .checking, serviceError: empty, workerName: "w")
            #expect(bare.reason == ProviderAvailabilityStatement.defaultRestartReason)
            #expect(!bare.suppressesConsoleNotice)
        }
    }

    // MARK: Control gates

    @Test func policyGatesEachAvailability() {
        // One gate for taking and handing back control.
        #expect(ProviderAvailability.allowsControl(nil))
        #expect(!ProviderAvailability.allowsControl(.exited))
        #expect(!ProviderAvailability.allowsControl(.checking))
    }

    @Test func modelOffersNoControlToExitedOrCheckingWorkers() async throws {
        let model = CockpitModel()
        model.runs = try Run.list(json: Data(#"{"runs":[\#(runJSON(fixtureWorkers))]}"#.utf8))

        // Neither taking nor handing back control is offered while exited or checking, whether or
        // not a lease is held; the service rejects every control change in both.
        for id in ["exited", "idleExited", "checking", "checkingIdle"] {
            #expect(!model.canControlWorker(id), "\(id)")
            #expect(!model.canInterruptWorker(id), "\(id)")
            // Refused before any request is made.
            #expect(await model.sendFollowUp(to: id, text: "continue") == false, "\(id)")
            // Stopping is not a control action and is decided as before.
            #expect(model.canStopWorker(id), "\(id)")
        }

        // Every other worker is decided as before.
        for id in normalWorkers {
            #expect(model.canControlWorker(id), "\(id)")
        }
    }

    @Test func followsAvailabilityThroughTheIncrementalFeed() throws {
        var reducer = AGUIWorkspaceReducer()
        let first = runJSON([workerJSON(id: "lead", role: "coordinator", state: "working"),
                             workerJSON(id: "w", state: "completed", held: true)])
        #expect(try reducer.apply(frame: #"{"type":"STATE_SNAPSHOT","snapshot":{"runs":[\#(first)]}}"#) == .snapshot)
        let model = CockpitModel()
        func current() throws -> WorkerPresentation? {
            model.runs = reducer.runs
            return try RunContent(run: #require(reducer.runs.first)).wall.workers.first { $0.id == "w" }
        }
        func delta(_ operation: String) -> String { #"{"type":"STATE_DELTA","delta":[\#(operation)]}"# }

        #expect(try current()?.providerAvailability == nil)
        #expect(model.canControlWorker("w"))

        // The adapter's stream ends after a completed turn: the state stays Completed, the service
        // releases the lease, and neither taking nor handing back control is offered.
        try reducer.apply(frame: delta(#"{"op":"add","path":"/runs/0/workers/1/provider_availability","value":"exited"}"#))
        try reducer.apply(frame: delta(#"{"op":"replace","path":"/runs/0/workers/1/control/held","value":false}"#))
        #expect(try current()?.providerAvailability == .exited)
        #expect(try current()?.state == .completed)
        #expect(!model.canControlWorker("w"))
    }

    @Test func recoversFromCheckingThroughTheIncrementalFeed() throws {
        var reducer = AGUIWorkspaceReducer()
        let first = runJSON([workerJSON(id: "lead", role: "coordinator", state: "working"),
                             workerJSON(id: "w", state: "idle", held: true)])
        #expect(try reducer.apply(frame: #"{"type":"STATE_SNAPSHOT","snapshot":{"runs":[\#(first)]}}"#) == .snapshot)
        let model = CockpitModel()
        func current() throws -> WorkerPresentation? {
            model.runs = reducer.runs
            return try RunContent(run: #require(reducer.runs.first)).wall.workers.first { $0.id == "w" }
        }
        func delta(_ operations: String...) -> String {
            #"{"type":"STATE_DELTA","delta":[\#(operations.joined(separator: ","))]}"#
        }

        // After a restart the service checks the session with its own reason; the task state may
        // read Unknown. Neither taking nor handing back the held lease is offered.
        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/1/provider_availability","value":"checking"}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/state","value":"unknown"}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/error","value":"\#(restartReason)"}"#))
        let checking = try #require(try current())
        #expect(checking.providerAvailability == .checking)
        #expect(checking.availabilityStatement?.reason == restartReason)
        #expect(checking.availabilityStatement?.suppressesConsoleNotice == true)
        #expect(!model.canControlWorker("w"))

        // The checks succeed: the service publishes the literal `available`, clears its reason and
        // restores the state. That is the normal state: no notice, and control is offered again.
        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/workers/1/provider_availability","value":"available"}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/error","value":""}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/state","value":"idle"}"#))
        let recovered = try #require(try current())
        #expect(reducer.runs.first?.workers?.first { $0.id == "w" }?.allFields["provider_availability"]?.stringValue == "available")
        #expect(recovered.providerAvailability == nil)
        #expect(recovered.availabilityStatement == nil)
        #expect(recovered.state == .idle)
        #expect(model.canControlWorker("w"))
    }
}
