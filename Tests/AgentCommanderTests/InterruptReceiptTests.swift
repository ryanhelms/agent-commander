import Foundation
import Testing
@testable import AgentCommander

// `control.active_turn_id` and the `control.interrupt` receipt of a bound managed local Claude
// worker: decoding in the legacy and incremental projections, the interrupt request's addressed
// body, the lifecycle wording, and which surfaces show it. Older services keep
// `interrupt_requested` and the original empty request body.

private func receiptJSON(id: String = "int-7f3a9c21d4", turn: String = "turn-4a1f2c3d9e", generation: Int = 3,
                         phase: String = "sent", outcome: String? = nil) -> String {
    let member = outcome.map { #","outcome":"\#($0)""# } ?? ""
    return #"{"id":"\#(id)","turn_id":"\#(turn)","generation":\#(generation),"phase":"\#(phase)"\#(member)}"#
}

private func controlJSON(generation: Int = 3, activeTurn: String? = nil, interrupt: String? = nil,
                         requested: Bool? = nil) -> String {
    var members = [#""held":true"#, #""generation":\#(generation)"#]
    if let activeTurn { members.append(#""active_turn_id":"\#(activeTurn)""#) }
    if let interrupt { members.append(#""interrupt":\#(interrupt)"#) }
    if let requested { members.append(#""interrupt_requested":\#(requested)"#) }
    return "{" + members.joined(separator: ",") + "}"
}

private func workerJSON(_ id: String, role: String = "worker", state: String = "working", control: String?) -> String {
    let member = control.map { #""control":\#($0),"# } ?? ""
    return #"{"id":"\#(id)","name":"\#(id)","role":"\#(role)","parent_id":"lead","run_id":"r","state":"\#(state)","host":"localhost","worktree":"/tmp/w","task":"build","error":"","native_session":{"harness_instance":"local-claude","session_id":"sess-\#(id)"},\#(member)"outputChunks":[],"messages":[]}"#
}

private func runJSON(_ workers: [String]) -> String {
    #"{"id":"r","project":"p","path":"/p","task":"ship it","client":"claude","coordinator_id":"lead","status":"running","requests":[],"workers":[\#(workers.joined(separator: ","))]}"#
}

private func snapshot(_ workers: [String]) -> String {
    #"{"type":"STATE_SNAPSHOT","snapshot":{"runs":[\#(runJSON(workers))]}}"#
}

private func delta(_ operations: String...) -> String {
    #"{"type":"STATE_DELTA","delta":[\#(operations.joined(separator: ","))]}"#
}

private func statement(phase: String = "sent", outcome: String? = nil, active: String? = "turn-4a1f2c3d9e")
    -> InterruptReceiptStatement {
    InterruptReceiptStatement(
        receipt: WorkerInterruptReceipt(id: "int-7f3a9c21d4", turnID: "turn-4a1f2c3d9e", generation: 3,
                                        phase: phase, outcome: outcome),
        workerName: "Timeout cases", activeTurnID: active)
}

/// Absent, then every contract outcome.
private let everyOutcome: [String?] = [nil] + WorkerInterruptReceipt.Outcome.allCases.map { Optional($0.rawValue) }

private func bodyObject(_ target: WorkerInterruptTarget?) throws -> NSDictionary {
    let data = try JSONEncoder().encode(ServiceClient.interruptFields(target))
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

@Suite @MainActor struct InterruptReceiptTests {
    // MARK: Decoding

    @Test func decodesTheReceiptDirectlyAndThroughTheProjection() throws {
        let json = controlJSON(activeTurn: "turn-4a1f2c3d9e", interrupt: receiptJSON())
        let direct = try JSONDecoder().decode(WorkerControl.self, from: Data(json.utf8))
        let projected = try WorkerControl(projection: AGUIValue(json: json))
        #expect(direct == projected)
        #expect(direct.activeTurnID == "turn-4a1f2c3d9e")
        #expect(direct.generation == 3)
        let receipt = try #require(direct.interrupt)
        #expect(receipt == WorkerInterruptReceipt(id: "int-7f3a9c21d4", turnID: "turn-4a1f2c3d9e", generation: 3,
                                                  phase: "sent"))
        #expect(receipt.phase == .sent)
        #expect(receipt.outcome == nil)
        #expect(receipt.isUnresolved)
        // A whole worker from the request API reads the same control.
        let whole = try JSONDecoder().decode(Worker.self, from: Data(workerJSON("w", control: json).utf8))
        #expect(whole.control == direct)
    }

    @Test func readsEveryContractPhaseAndOutcome() throws {
        for phase in WorkerInterruptReceipt.Phase.allCases {
            for outcome in everyOutcome {
                let receipt = try WorkerInterruptReceipt(projection: AGUIValue(
                    json: receiptJSON(phase: phase.rawValue, outcome: outcome)))
                #expect(receipt.phase == phase)
                #expect(receipt.outcome?.rawValue == outcome)
                #expect(receipt.isUnresolved == (outcome == nil))
            }
        }
        // A null outcome is unresolved.
        let nulled = try WorkerInterruptReceipt(projection: AGUIValue(
            json: #"{"id":"i","turn_id":"t","generation":1,"phase":"accepted","outcome":null}"#))
        #expect(nulled.isUnresolved)
    }

    @Test func keepsUnrecognizedValuesAsSent() throws {
        let receipt = try WorkerInterruptReceipt(projection: AGUIValue(
            json: receiptJSON(phase: "queued", outcome: "timed_out")))
        #expect(receipt.phase == nil)
        #expect(receipt.phaseValue == "queued")
        #expect(receipt.outcome == nil)
        #expect(receipt.outcomeValue == "timed_out")
        #expect(!receipt.isUnresolved)
    }

    @Test func olderServicesDecodeAsBefore() throws {
        for json in [controlJSON(), controlJSON(requested: true),
                     #"{"held":true,"generation":3,"active_turn_id":null,"interrupt":null}"#] {
            let control = try WorkerControl(projection: AGUIValue(json: json))
            #expect(control.activeTurnID == nil)
            #expect(control.interrupt == nil)
            #expect(control == (try JSONDecoder().decode(WorkerControl.self, from: Data(json.utf8))))
        }
        // The original constructor still describes a control with neither member.
        #expect(WorkerControl(held: true, generation: 3, interruptRequested: true, messages: nil)
            == (try WorkerControl(projection: AGUIValue(json: controlJSON(requested: true)))))
    }

    @Test func rejectsAReceiptOfTheWrongShape() throws {
        let damaged = [
            "true", "[]", #""sent""#,
            #"{"turn_id":"t","generation":1,"phase":"sent"}"#,
            #"{"id":"i","generation":1,"phase":"sent"}"#,
            #"{"id":"i","turn_id":"t","phase":"sent"}"#,
            #"{"id":"i","turn_id":"t","generation":1}"#,
            #"{"id":"i","turn_id":"t","generation":"1","phase":"sent"}"#,
            #"{"id":"i","turn_id":"t","generation":1,"phase":"sent","outcome":true}"#
        ]
        for receipt in damaged {
            let json = controlJSON(interrupt: receipt)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(WorkerControl.self, from: Data(json.utf8)) }
            #expect(throws: AGUIValueError.self) { try WorkerControl(projection: AGUIValue(json: json)) }
        }
    }

    // MARK: Request

    @Test func addressesTheInterruptToTheObservedTurnAndGeneration() throws {
        let addressed = try WorkerControl(projection: AGUIValue(json: controlJSON(generation: 5, activeTurn: "turn-9")))
        let target = try #require(WorkerInterruptTarget(control: addressed))
        #expect(target == WorkerInterruptTarget(turnID: "turn-9", generation: 5))
        #expect(try bodyObject(target) == ["turn_id": "turn-9", "generation": 5] as NSDictionary)

        // Other and older providers keep the original empty body.
        for json in [controlJSON(), #"{"held":true,"generation":3,"active_turn_id":""}"#] {
            let control = try WorkerControl(projection: AGUIValue(json: json))
            #expect(WorkerInterruptTarget(control: control) == nil)
        }
        #expect(WorkerInterruptTarget(control: nil) == nil)
        #expect(try bodyObject(nil) == [:] as NSDictionary)
    }

    @Test func modelBindsTheTargetToTheCurrentWorkerState() throws {
        var reducer = AGUIWorkspaceReducer()
        try reducer.apply(frame: snapshot([
            workerJSON("lead", role: "coordinator", control: nil),
            workerJSON("w", control: controlJSON(generation: 3, activeTurn: "turn-1")),
            workerJSON("legacy", control: controlJSON(generation: 2))
        ]))
        let model = CockpitModel()
        model.runs = reducer.runs
        #expect(model.interruptTarget("w") == WorkerInterruptTarget(turnID: "turn-1", generation: 3))
        #expect(model.interruptTarget("legacy") == nil)
        #expect(model.interruptTarget("lead") == nil)

        // A new turn and generation: a retry is addressed to what the cockpit now observes.
        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/workers/1/control/active_turn_id","value":"turn-2"}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/control/generation","value":4}"#))
        model.runs = reducer.runs
        #expect(model.interruptTarget("w") == WorkerInterruptTarget(turnID: "turn-2", generation: 4))
    }

    // MARK: Gate

    @Test func anUnresolvedReceiptForTheCurrentTurnWaitsLikeTheLegacyFlag() throws {
        let workers = [
            workerJSON("lead", role: "coordinator", control: nil),
            workerJSON("pending", control: controlJSON(activeTurn: "turn-4a1f2c3d9e", interrupt: receiptJSON())),
            workerJSON("unknownOutcome", control: controlJSON(activeTurn: "turn-4a1f2c3d9e",
                                                              interrupt: receiptJSON(outcome: "unknown"))),
            workerJSON("priorTurn", control: controlJSON(activeTurn: "turn-next",
                                                         interrupt: receiptJSON(outcome: "interrupted"))),
            workerJSON("priorUnresolved", control: controlJSON(activeTurn: "turn-next", interrupt: receiptJSON())),
            workerJSON("legacy", control: controlJSON(requested: true)),
            workerJSON("plain", control: controlJSON())
        ]
        let model = CockpitModel()
        model.runs = try Run.list(json: Data(#"{"runs":[\#(runJSON(workers))]}"#.utf8))
        #expect(!model.canInterruptWorker("pending"))
        #expect(model.canInterruptWorker("unknownOutcome"))
        #expect(model.canInterruptWorker("priorTurn"))
        #expect(model.canInterruptWorker("priorUnresolved"))
        #expect(!model.canInterruptWorker("legacy"))
        #expect(model.canInterruptWorker("plain"))
        // Rendering a receipt never changes control or stopping.
        for id in ["pending", "unknownOutcome", "priorTurn", "priorUnresolved"] {
            #expect(model.canControlWorker(id), "\(id)")
            #expect(model.canStopWorker(id), "\(id)")
        }
    }

    // MARK: Words

    @Test func eachStepAndOutcomeHasItsOwnWords() {
        let steps = WorkerInterruptReceipt.Phase.allCases.map { statement(phase: $0.rawValue).stepLabel }
        #expect(Set(steps).count == steps.count)
        #expect(statement(phase: "accepted").stepLabel == "accepted by service")
        #expect(statement(phase: "claimed").stepLabel == "claimed by runner")
        #expect(statement(phase: "sent").stepLabel == "cancel sent to adapter")
        #expect(statement(phase: "unconfirmed").stepLabel == "send unconfirmed")

        let outcomes = everyOutcome.map { statement(outcome: $0).outcomeLabel }
        #expect(Set(outcomes).count == outcomes.count)
        #expect(statement().outcomeLabel == "unresolved")
        #expect(statement(outcome: "interrupted").outcomeLabel == "turn interrupted")
        #expect(statement(outcome: "completed").outcomeLabel == "turn completed")
        #expect(statement(outcome: "failed").outcomeLabel == "turn failed")
        // The row reads `Interrupt outcome · Turn completed`; ink and statement keep the evidence.
        #expect(statement(outcome: "completed").outcomeTitle == "Turn completed")
        #expect(statement(outcome: "failed").outcomeTitle == "Turn failed")
        #expect(statement().outcomeTitle == "Unresolved")
        #expect(statement(outcome: "completed").statement.contains("The turn completed."))
        #expect(statement(outcome: "failed").statement.contains("The turn ended with a failure."))
        for outcome in ["completed", "failed", "cancelled"] {
            #expect(!statement(outcome: outcome).statement.contains("did not report"), "\(outcome)")
        }
        #expect(statement(outcome: "unknown").outcomeLabel == "unknown")
        #expect(statement(outcome: "cancelled").outcomeLabel == "interrupt cancelled")
        #expect(statement(outcome: "cancelled").statement.contains("The service cancelled this interrupt request."))
    }

    @Test func onlyAnInterruptedOutcomeReadsAsConfirmed() {
        #expect(statement(outcome: "interrupted").ink == .confirmed)
        #expect(statement(outcome: "interrupted").mark == "✓")
        for outcome in ["completed", "cancelled"] { #expect(statement(outcome: outcome).ink == .settled) }
        #expect(statement(outcome: "failed").ink == .failure)
        for outcome: String? in [nil, "unknown", "timed_out"] { #expect(statement(outcome: outcome).ink == .attention) }
        // Only an interrupted outcome says the turn was interrupted.
        for outcome: String? in [nil, "completed", "failed", "unknown", "cancelled"] {
            #expect(!statement(outcome: outcome).statement.contains("ended the turn as interrupted"))
        }
        #expect(statement(outcome: "interrupted").statement.contains("Claude ended the turn as interrupted."))
    }

    @Test func initialTurnLabelKeepsItsWorkerSuffix() {
        #expect(Identifier.turn("initial-w-abc123") == "initial · w-abc123")
        #expect(Identifier.turn("initial-w-abc123def456") == "initial · w-abc123")
        #expect(Identifier.turn("turn-4a1f2c3d9e") == "turn-4a1")
        let initial = InterruptReceiptStatement(
            receipt: WorkerInterruptReceipt(id: "int-7f3a9c21d4", turnID: "initial-w-abc123", generation: 3,
                                            phase: "sent", outcome: nil),
            workerName: "Timeout cases", activeTurnID: nil)
        #expect(initial.shortTurn == "initial · w-abc123")
        #expect(initial.statement.contains("turn initial-w-abc123"))
    }

    @Test func statementsNameTheOriginalTurnAndTheLastConfirmedStep() {
        let open = statement(phase: "sent")
        #expect(open.statement.contains("turn turn-4a1f2c3d9e"))
        #expect(open.statement.contains("int-7f3a9c21d4"))
        #expect(open.statement.contains("Timeout cases"))
        #expect(open.statement.contains("the cancel notification was sent to Claude's adapter"))
        #expect(open.statement.contains("has not been observed yet"))
        #expect(open.statement.contains("Stopping the worker is a separate action"))
        #expect(open.shortTurn == "turn-4a1")
        #expect(!open.originalTurnHasPassed)

        let later = statement(outcome: "completed", active: "turn-next")
        #expect(later.originalTurnHasPassed)
        #expect(later.statement.contains("original turn only"))
        #expect(!later.statement.contains("Inspect source"))
        #expect(!statement(active: nil).originalTurnHasPassed)

        let unrecognized = statement(phase: "queued", outcome: "timed_out")
        #expect(unrecognized.stepLabel == "reported queued")
        #expect(unrecognized.outcomeLabel == "reported timed_out")
        #expect(unrecognized.statement.contains("does not recognize"))
    }

    // MARK: Scope

    @Test func inspectionIsOfferedOnlyWhileTheOutcomeIsOpen() {
        for outcome: String? in [nil, "unknown", "timed_out"] { #expect(statement(outcome: outcome).needsInspection) }
        for outcome in ["interrupted", "completed", "failed", "cancelled"] {
            #expect(!statement(outcome: outcome).needsInspection)
        }
    }

    @Test func focusedAlwaysShowsTheReceiptAndTheWallOnlyWhileOpen() {
        for outcome: String? in [nil, "unknown"] {
            #expect(statement(outcome: outcome).isShown(focused: true))
            #expect(statement(outcome: outcome).isShown(focused: false))
        }
        for outcome in ["interrupted", "completed", "failed", "cancelled"] {
            #expect(statement(outcome: outcome).isShown(focused: true))
            #expect(!statement(outcome: outcome).isShown(focused: false))
        }
    }

    @Test func inspectSourceIsOfferedOncePerTile() {
        let open = statement()
        #expect(InterruptReceiptStatement.rowOffersSource(open, focused: true, hasSource: true, availability: nil))
        #expect(InterruptReceiptStatement.rowOffersSource(open, focused: false, hasSource: true, availability: nil))
        // The availability strip already offers it.
        for availability in ProviderAvailability.allCases {
            #expect(!InterruptReceiptStatement.rowOffersSource(open, focused: true, hasSource: true,
                                                               availability: availability))
        }
        // No source, no receipt, or a settled outcome: nothing here, so the progress row keeps it.
        #expect(!InterruptReceiptStatement.rowOffersSource(open, focused: true, hasSource: false, availability: nil))
        #expect(!InterruptReceiptStatement.rowOffersSource(nil, focused: true, hasSource: true, availability: nil))
        #expect(!InterruptReceiptStatement.rowOffersSource(statement(outcome: "interrupted"), focused: true,
                                                           hasSource: true, availability: nil))
    }

    @Test func presentationScopesTheReceiptToDelegatedWorkers() throws {
        let workers = [
            workerJSON("lead", role: "coordinator",
                       control: controlJSON(activeTurn: "turn-4a1f2c3d9e", interrupt: receiptJSON())),
            workerJSON("pending", control: controlJSON(activeTurn: "turn-4a1f2c3d9e", interrupt: receiptJSON())),
            workerJSON("done", control: controlJSON(activeTurn: "turn-next",
                                                    interrupt: receiptJSON(outcome: "interrupted"), requested: false)),
            workerJSON("legacy", control: controlJSON(requested: true)),
            workerJSON("plain", control: controlJSON())
        ]
        let content = try RunContent(run: #require(Run.list(json: Data(#"{"runs":[\#(runJSON(workers))]}"#.utf8)).first))
        #expect(content.coordinator?.interruptReceipt == nil)
        let byID = Dictionary(uniqueKeysWithValues: content.wall.workers.map { ($0.id, $0) })

        let pending = try #require(byID["pending"]?.interruptReceipt)
        #expect(pending.workerName == "pending")
        #expect(pending.activeTurnID == "turn-4a1f2c3d9e")
        #expect(byID["pending"]?.interruptPending == true)

        #expect(byID["done"]?.interruptReceipt?.receipt.outcome == .interrupted)
        #expect(byID["done"]?.interruptPending == false)

        // An older service keeps the generic cue and its gate.
        #expect(byID["legacy"]?.interruptReceipt == nil)
        #expect(byID["legacy"]?.interruptRequested == true)
        #expect(byID["legacy"]?.interruptPending == true)
        #expect(byID["plain"]?.interruptReceipt == nil)
        #expect(byID["plain"]?.interruptPending == false)
    }

    // MARK: Lifecycle through the incremental feed

    @Test func followsTheLifecycleAndSurvivesAReconnect() throws {
        var reducer = AGUIWorkspaceReducer()
        let lead = workerJSON("lead", role: "coordinator", control: nil)
        try reducer.apply(frame: snapshot([lead, workerJSON("w", control: controlJSON(activeTurn: "turn-4a1f2c3d9e"))]))
        let model = CockpitModel()
        func current() throws -> WorkerPresentation? {
            model.runs = reducer.runs
            return try RunContent(run: #require(reducer.runs.first)).wall.workers.first { $0.id == "w" }
        }

        #expect(try current()?.interruptReceipt == nil)
        #expect(model.canInterruptWorker("w"))

        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/1/control/interrupt","value":\#(receiptJSON(phase: "accepted"))}"#))
        #expect(try current()?.interruptReceipt?.stepLabel == "accepted by service")
        #expect(!model.canInterruptWorker("w"))

        for phase in ["claimed", "sent"] {
            try reducer.apply(frame: delta(
                #"{"op":"replace","path":"/runs/0/workers/1/control/interrupt/phase","value":"\#(phase)"}"#))
            #expect(try current()?.interruptReceipt?.receipt.phaseValue == phase)
            #expect(try current()?.interruptReceipt?.needsInspection == true)
        }

        // The peer stays open: the sent step and an unresolved outcome remain through a reconnect.
        let sent = controlJSON(activeTurn: "turn-4a1f2c3d9e", interrupt: receiptJSON(phase: "sent"))
        var reconnected = AGUIWorkspaceReducer()
        try reconnected.apply(frame: snapshot([lead, workerJSON("w", control: sent)]))
        let afterReconnect = try RunContent(run: #require(reconnected.runs.first)).wall.workers.first { $0.id == "w" }
        #expect(afterReconnect?.interruptReceipt == (try current()?.interruptReceipt))
        #expect(afterReconnect?.interruptReceipt?.outcomeLabel == "unresolved")

        // The turn ends as interrupted, and the receipt stays after the next turn opens.
        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/1/control/interrupt/outcome","value":"interrupted"}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/control/active_turn_id","value":"turn-next"}"#))
        let settled = try #require(try current()?.interruptReceipt)
        #expect(settled.receipt.id == "int-7f3a9c21d4")
        #expect(settled.receipt.turnID == "turn-4a1f2c3d9e")
        #expect(settled.outcomeLabel == "turn interrupted")
        #expect(settled.originalTurnHasPassed)
        #expect(!settled.needsInspection)
        #expect(model.canInterruptWorker("w"))
        #expect(model.interruptTarget("w") == WorkerInterruptTarget(turnID: "turn-next", generation: 3))
    }
}
