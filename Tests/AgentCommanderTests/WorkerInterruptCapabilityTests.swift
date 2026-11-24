import Foundation
import Testing
@testable import AgentCommander

// `control.session_capabilities` is optional. When the service sends it, `can_interrupt` is
// stated. A worker without it comes from an older service or a legacy runner.

private func control(_ capabilities: String?) -> String {
    let member = capabilities.map { #","session_capabilities":\#($0)"# } ?? ""
    return #"{"held":false,"generation":2\#(member)}"#
}

private func worker(_ id: String, state: String = "working", control: String?) -> String {
    let member = control.map { #""control":\#($0),"# } ?? ""
    return #"{"id":"\#(id)","name":"\#(id)","role":"worker","parent_id":"lead","run_id":"r","state":"\#(state)","host":"local","worktree":"/tmp/w","task":"build","error":"",\#(member)"outputChunks":[],"messages":[]}"#
}

private func run(_ workers: [String]) -> String {
    #"{"id":"r","project":"p","path":"/p","task":"ship it","client":"claude","coordinator_id":"lead","status":"running","worker_limit":4,"requests":[],"workers":[\#(workers.joined(separator: ","))]}"#
}

private func delta(_ operations: String...) -> String {
    #"{"type":"STATE_DELTA","delta":[\#(operations.joined(separator: ","))]}"#
}

private let cannot = #"{"can_interrupt":false}"#
private let can = #"{"can_interrupt":true}"#

@Suite @MainActor struct WorkerInterruptCapabilityTests {
    @Test func decodesTheCapabilityDirectlyAndThroughTheProjection() throws {
        let cases: [(String?, WorkerSessionCapabilities?, Bool)] = [
            (cannot, WorkerSessionCapabilities(canInterrupt: false), false),
            (can, WorkerSessionCapabilities(canInterrupt: true), true),
            (nil, nil, true),
            ("null", nil, true)
        ]
        for (capabilities, expected, canInterrupt) in cases {
            let json = control(capabilities)
            let direct = try JSONDecoder().decode(WorkerControl.self, from: Data(json.utf8))
            let projected = try WorkerControl(projection: AGUIValue(json: json))
            #expect(direct == projected)
            #expect(direct.sessionCapabilities == expected)
            #expect(direct.sessionCanInterrupt == canInterrupt)
            #expect(direct.held == false)
            #expect(direct.generation == 2)
            // A whole worker from the request API reads the same control.
            let whole = try JSONDecoder().decode(Worker.self, from: Data(worker("w", control: json).utf8))
            #expect(whole.control == direct)
        }
        // The original constructor still describes a worker with no reported capabilities.
        #expect(WorkerControl(held: false, generation: 2, interruptRequested: nil, messages: nil)
            == (try WorkerControl(projection: AGUIValue(json: control(nil)))))
    }

    @Test func rejectsACapabilityOfTheWrongKind() throws {
        for damaged in [#"{"can_interrupt":"no"}"#, "true", "[]"] {
            let json = control(damaged)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(WorkerControl.self, from: Data(json.utf8)) }
            #expect(throws: AGUIValueError.self) { try WorkerControl(projection: AGUIValue(json: json)) }
        }
    }

    @Test func offersInterruptOnlyWhereTheSessionAllowsIt() throws {
        let workers = [
            worker("lead", control: nil),
            worker("cannot", control: control(cannot)),
            worker("can", control: control(can)),
            worker("absent", control: control(nil)),
            worker("idle", state: "idle", control: control(can)),
            worker("uncontrolled", control: nil)
        ]
        let body = #"{"runs":[\#(run(workers))]}"#
        let model = CockpitModel()
        model.runs = try Run.list(json: Data(body.utf8))

        #expect(!model.canInterruptWorker("cannot"))
        #expect(model.canInterruptWorker("can"))
        #expect(model.canInterruptWorker("absent"))
        // The capability adds nothing where interrupting did not apply before.
        #expect(!model.canInterruptWorker("idle"))
        #expect(!model.canInterruptWorker("uncontrolled"))
        #expect(!model.canInterruptWorker("lead"))
        // Every other action is decided as before.
        for id in ["cannot", "can", "absent"] {
            #expect(model.canControlWorker(id))
            #expect(model.canStopWorker(id))
        }
    }

    @Test func followsTheCapabilityThroughTheIncrementalFeed() throws {
        var reducer = AGUIWorkspaceReducer()
        let first = run([worker("lead", control: nil), worker("w", control: control(cannot)),
                         worker("legacy", control: control(nil))])
        #expect(try reducer.apply(frame: #"{"type":"STATE_SNAPSHOT","snapshot":{"runs":[\#(first)]}}"#) == .snapshot)
        let model = CockpitModel()
        func current() -> WorkerControl? {
            model.runs = reducer.runs
            return reducer.runs[0].workers?[1].control
        }

        #expect(current()?.sessionCapabilities == WorkerSessionCapabilities(canInterrupt: false))
        #expect(!model.canInterruptWorker("w"))
        #expect(model.canInterruptWorker("legacy"))
        #expect(model.canControlWorker("w"))
        #expect(model.canStopWorker("w"))

        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/workers/1/control/session_capabilities/can_interrupt","value":true}"#))
        #expect(current()?.sessionCapabilities == WorkerSessionCapabilities(canInterrupt: true))
        #expect(model.canInterruptWorker("w"))

        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/workers/1/control/session_capabilities","value":\#(cannot)}"#))
        #expect(current()?.sessionCanInterrupt == false)
        #expect(!model.canInterruptWorker("w"))

        try reducer.apply(frame: delta(#"{"op":"remove","path":"/runs/0/workers/1/control/session_capabilities"}"#))
        #expect(current()?.sessionCapabilities == nil)
        #expect(model.canInterruptWorker("w"))

        // A worker that gains the capability later is gated from that frame on.
        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/2/control/session_capabilities","value":\#(cannot)}"#))
        model.runs = reducer.runs
        #expect(!model.canInterruptWorker("legacy"))
        #expect(reducer.runs[0].workers?[2].allFields["control"]?["session_capabilities"]?["can_interrupt"] == false)
    }
}
