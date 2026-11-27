import Foundation
import Testing
@testable import AgentCommander

// The durable `control.messages` follow-up receipts of a managed local Claude worker: decoding in
// the legacy and incremental projections, the status vocabulary, what a queued follow-up waits for,
// the retained outcome, and the generation-scoped consequence beside Hand back.

private func messageJSON(_ id: String, _ status: String, generation: Int? = 3) -> String {
    let member = generation.map { #","generation":\#($0)"# } ?? ""
    return #"{"id":"\#(id)","status":"\#(status)","text":"secret follow-up body"\#(member)}"#
}

private func controlJSON(held: Bool = true, generation: Int = 3, activeTurn: String? = nil,
                         messages: [String]) -> String {
    var members = [#""held":\#(held)"#, #""generation":\#(generation)"#,
                   #""messages":[\#(messages.joined(separator: ","))]"#]
    if let activeTurn { members.append(#""active_turn_id":"\#(activeTurn)""#) }
    return "{" + members.joined(separator: ",") + "}"
}

private func workerJSON(_ id: String, role: String = "worker", harness: String = "local-claude",
                        control: String?) -> String {
    let member = control.map { #""control":\#($0),"# } ?? ""
    return #"{"id":"\#(id)","name":"\#(id)","role":"\#(role)","parent_id":"lead","run_id":"r","state":"working","host":"localhost","worktree":"/tmp/w","task":"build","error":"","native_session":{"harness_instance":"\#(harness)","session_id":"sess-\#(id)"},\#(member)"outputChunks":[],"messages":[]}"#
}

private func requestJSON(_ id: String, worker: String, status: String = "pending") -> String {
    #"{"id":"\#(id)","worker_id":"\#(worker)","question":"Allow?","status":"\#(status)","answer":"","choices":[{"id":"allow","label":"Allow"}]}"#
}

/// An operator question without explicit choices: never an approval.
private func questionJSON(_ id: String, worker: String) -> String {
    #"{"id":"\#(id)","worker_id":"\#(worker)","question":"Which branch?","status":"pending","answer":""}"#
}

private func runJSON(_ workers: [String], requests: [String] = []) -> String {
    #"{"id":"r","project":"p","path":"/p","task":"ship it","client":"claude","coordinator_id":"lead","status":"running","requests":[\#(requests.joined(separator: ","))],"workers":[\#(workers.joined(separator: ","))]}"#
}

private let lead = workerJSON("lead", role: "coordinator", control: nil)

private func content(_ workers: [String], requests: [String] = []) throws -> RunContent {
    let runs = try Run.list(json: Data(#"{"runs":[\#(runJSON([lead] + workers, requests: requests))]}"#.utf8))
    return RunContent(run: try #require(runs.first))
}

private func presented(_ id: String, in run: RunContent) throws -> WorkerPresentation {
    try #require(run.wall.workers.first { $0.id == id })
}

private func snapshot(_ workers: [String], requests: [String] = []) -> String {
    #"{"type":"STATE_SNAPSHOT","snapshot":{"runs":[\#(runJSON([lead] + workers, requests: requests))]}}"#
}

private func delta(_ operations: String...) -> String {
    #"{"type":"STATE_DELTA","delta":[\#(operations.joined(separator: ","))]}"#
}

@Suite @MainActor struct FollowUpReceiptTests {
    // MARK: Decoding

    @Test func decodesStatusAndGenerationThroughBothPaths() throws {
        let json = controlJSON(messages: [messageJSON("fu-1", "queued"), messageJSON("fu-2", "delivery_unknown")])
        let direct = try JSONDecoder().decode(WorkerControl.self, from: Data(json.utf8))
        let projected = try WorkerControl(projection: AGUIValue(json: json))
        #expect(direct == projected)
        // The text is kept for the message box's queued line; no receipt statement reads it.
        #expect(direct.messages == [WorkerFollowUp(id: "fu-1", status: "queued", generation: 3, text: "secret follow-up body"),
                                    WorkerFollowUp(id: "fu-2", status: "delivery_unknown", generation: 3, text: "secret follow-up body")])
        #expect(QueuedFollowUp.queued(direct) == [QueuedFollowUp(id: "fu-1", text: "secret follow-up body")])
    }

    @Test func olderProjectionsWithoutGenerationStillDecode() throws {
        let json = controlJSON(messages: [messageJSON("fu-1", "queued", generation: nil),
                                          #"{"id":"fu-2","status":"queued","generation":null}"#])
        let direct = try JSONDecoder().decode(WorkerControl.self, from: Data(json.utf8))
        #expect(direct == (try WorkerControl(projection: AGUIValue(json: json))))
        #expect(direct.messages?.map(\.generation) == [nil, nil])
        #expect(WorkerFollowUp(id: "m", status: "queued") == WorkerFollowUp(id: "m", status: "queued", generation: nil))
    }

    // MARK: Status mapping

    @Test func everyContractStatusHasItsOwnStageWordsAndInk() {
        func receipt(_ status: String) -> FollowUpReceipt { FollowUpReceipt(id: "fu-7f3a9c21d4", status: status) }
        let all = FollowUpReceipt.Status.allCases
        #expect(Set(all.map(\.rawValue)) == ["queued", "processing", "completed", "interrupted", "cancelled",
                                              "failed", "delivery_unknown"])
        for status in all { #expect(receipt(status.rawValue).status == status) }
        let labels = all.map { receipt($0.rawValue).label }
        #expect(Set(labels).count == labels.count)

        #expect(receipt("queued").stage == .awaiting)
        #expect(receipt("queued").label == "Accepted by Commander")
        #expect(receipt("queued").isUnclaimed)
        #expect(receipt("processing").stage == .awaiting)
        #expect(receipt("processing").label == "Claimed by runner")
        #expect(!receipt("processing").isUnclaimed)
        for status in ["completed", "interrupted", "cancelled", "failed", "delivery_unknown"] {
            #expect(receipt(status).stage == .outcome, "\(status)")
            #expect(!receipt(status).isUnclaimed, "\(status)")
        }
        #expect(receipt("completed").ink == .confirmed)
        #expect(receipt("failed").ink == .failure)
        #expect(receipt("delivery_unknown").ink == .attention)
        #expect(receipt("delivery_unknown").label == "Delivery unknown")
        for status in ["interrupted", "cancelled"] { #expect(receipt(status).ink == .settled) }
    }

    @Test func anUnknownStatusIsKeptAsSentAndClaimsNothing() {
        let receipt = FollowUpReceipt(id: "fu-1", status: "rerouted")
        #expect(receipt.status == nil)
        #expect(receipt.stage == .unrecognized)
        #expect(receipt.label == "Reported rerouted")
        #expect(receipt.ink == .attention)
        #expect(!receipt.isUnclaimed)
        let set = FollowUpReceipts(workerName: "w", receipts: [receipt], blocker: .unreported, heldGeneration: 3)
        #expect(set.statement(for: receipt).contains("\"rerouted\", which this version does not recognize"))
        #expect(set.handBackNote == nil)
    }

    @Test func processingNeverReadsAsDelivered() {
        let claimed = FollowUpReceipt(id: "fu-1", status: "processing", generation: 3)
        let set = FollowUpReceipts(workerName: "Timeout cases", receipts: [claimed], blocker: .turn("t"),
                                   heldGeneration: 3)
        let statement = set.statement(for: claimed)
        #expect(statement.contains("runner claimed it"))
        #expect(statement.contains("Delivery to Claude stays unconfirmed"))
        // A claimed follow-up is not explained by a blocker.
        #expect(set.queuedBlocker == nil)
        #expect(set.blockerLabel == nil)
    }

    @Test func receiptsAreIdentifiedWithoutTheirText() throws {
        let run = try content([workerJSON("w", control: controlJSON(messages: [messageJSON("fu-1", "queued")]))])
        let receipts = try #require(try presented("w", in: run).followUpReceipts)
        let words = receipts.summary + receipts.statement(for: try #require(receipts.lead))
            + (receipts.handBackStatement ?? "")
        #expect(!words.contains("secret follow-up body"))
        #expect(words.contains("fu-1"))
    }

    // MARK: Blocker

    @Test func aQueuedFollowUpNamesTheFirstAddressablePendingRequestOfItsWorker() throws {
        let run = try content(
            [workerJSON("w", control: controlJSON(activeTurn: "turn-1", messages: [messageJSON("fu-1", "queued")])),
             workerJSON("other", control: nil)],
            requests: [requestJSON("q-other", worker: "other"), requestJSON("q-done", worker: "w", status: "answered"),
                       requestJSON("q-first", worker: "w"), requestJSON("q-second", worker: "w")])
        let worker = try presented("w", in: run)
        let receipts = try #require(worker.followUpReceipts)
        #expect(receipts.blockingRequest?.id == "q-first")
        #expect(receipts.blockingRequest?.workerID == "w")
        #expect(receipts.blockerLabel == "waits for approval q-first")
        #expect(receipts.statement(for: try #require(receipts.lead))
            .contains("It waits for pending approval q-first from w."))

        // The same request is the focused worker's inline form, so activation focuses it there.
        let ui = CockpitPresentationState()
        ui.zoomedWorkerID = "w"
        let cockpit = CockpitContent(connection: .online, notice: nil, isStopping: false, runs: [], selected: run,
                                     pending: run.awaiting, sending: [])
        #expect(cockpit.inlineRequestID(ui) == receipts.blockingRequest?.id)
        // On the wall it is an Attention request, reachable by its own ID.
        ui.zoomedWorkerID = nil
        #expect(cockpit.attentionQueue(ui).contains { $0.id == "q-first" })
    }

    @Test func aFreeFormQuestionIsNotAnApprovalAndHidesNone() throws {
        let run = try content(
            [workerJSON("w", control: controlJSON(activeTurn: "turn-1", messages: [messageJSON("fu-1", "queued")])),
             workerJSON("asks", control: controlJSON(activeTurn: "turn-2", messages: [messageJSON("fu-2", "queued")])),
             workerJSON("idle", control: controlJSON(messages: [messageJSON("fu-3", "queued")]))],
            requests: [questionJSON("q-free", worker: "w"), requestJSON("q-choice", worker: "w"),
                       questionJSON("q-only", worker: "asks"), questionJSON("q-idle", worker: "idle")])
        let receipts = try #require(try presented("w", in: run).followUpReceipts)
        #expect(receipts.blockingRequest?.id == "q-choice")
        #expect(receipts.blockerLabel == "waits for approval q-choice")
        let statement = receipts.statement(for: try #require(receipts.lead))
        #expect(statement.contains("pending approval q-choice"))
        #expect(!statement.contains("q-free"))

        // A worker with only a free-form question: its active turn, otherwise the neutral queue.
        let asks = try #require(try presented("asks", in: run).followUpReceipts)
        #expect(asks.queuedBlocker == .turn("turn-2"))
        #expect(asks.blockingRequest == nil)
        let idle = try #require(try presented("idle", in: run).followUpReceipts)
        #expect(idle.queuedBlocker == .unreported)
        #expect(idle.statement(for: try #require(idle.lead))
            .contains("Commander is waiting for the runner to claim it."))
    }

    @Test func withoutARequestTheActiveTurnOrANeutralWaitExplainsIt() throws {
        let run = try content([
            workerJSON("turn", control: controlJSON(activeTurn: "turn-4a1f2c3d9e", messages: [messageJSON("a", "queued")])),
            workerJSON("none", control: controlJSON(messages: [messageJSON("b", "queued")])),
            workerJSON("blank", control: controlJSON(activeTurn: "", messages: [messageJSON("c", "queued")]))
        ])
        let turn = try #require(try presented("turn", in: run).followUpReceipts)
        #expect(turn.queuedBlocker == .turn("turn-4a1f2c3d9e"))
        #expect(turn.blockerLabel == "waits for turn turn-4a1")
        #expect(turn.blockingRequest == nil)
        for id in ["none", "blank"] {
            let receipts = try #require(try presented(id, in: run).followUpReceipts)
            #expect(receipts.queuedBlocker == .unreported)
            #expect(receipts.blockerLabel == "waiting")
            #expect(receipts.blockingRequest == nil)
        }
    }

    @Test func blockerSelectionIsDeterministicAndScopedToTheWorker() {
        func request(_ id: String, worker: String, choices: Bool = true) -> RequestPresentation {
            RequestPresentation(id: id, shortID: id, question: "?", workerID: worker, workerName: worker,
                                workerIsCoordinator: false, client: .claude, runID: "r", runTitle: "r", project: "p",
                                host: "h", platform: .localMac, inputHolder: "lead", contextTail: [],
                                choices: choices ? [QuestionChoice(id: "allow", label: "Allow")] : [])
        }
        let requests = [request("", worker: "w"), request("q-x", worker: "x"), request("q-free", worker: "w", choices: false),
                        request("q-1", worker: "w"), request("q-2", worker: "w")]
        for _ in 0..<3 {
            #expect(FollowUpBlocker.observed(workerID: "w", requests: requests, activeTurnID: "t").request?.id == "q-1")
        }
        #expect(FollowUpBlocker.observed(workerID: "y", requests: requests, activeTurnID: "t") == .turn("t"))
        #expect(FollowUpBlocker.observed(workerID: "y", requests: requests, activeTurnID: nil) == .unreported)
    }

    // MARK: Presentation order and persistence

    @Test func anAwaitingReceiptLeadsAndTheLatestOutcomeIsRetained() {
        let set = FollowUpReceipts(workerName: "w", receipts: [
            FollowUpReceipt(id: "old", status: "failed"),
            FollowUpReceipt(id: "done", status: "completed"),
            FollowUpReceipt(id: "odd", status: "rerouted"),
            FollowUpReceipt(id: "claimed", status: "processing"),
            FollowUpReceipt(id: "next", status: "queued")
        ], blocker: .unreported, heldGeneration: nil)
        #expect(set.lead?.id == "claimed")
        #expect(set.shownOpen.map(\.id) == ["claimed", "next"])
        #expect(set.further.map(\.id) == ["odd"])
        #expect(set.retainedOutcome?.id == "done")
        #expect(set.isShown)
    }

    @Test func theOutcomeStaysAfterTheQueueDrainsAndThroughAReconnect() throws {
        var reducer = AGUIWorkspaceReducer()
        let held = controlJSON(activeTurn: "turn-1", messages: [messageJSON("fu-1", "queued")])
        try reducer.apply(frame: snapshot([workerJSON("w", control: held)], requests: [requestJSON("q-1", worker: "w")]))
        func current() throws -> FollowUpReceipts? {
            try presented("w", in: RunContent(run: #require(reducer.runs.first))).followUpReceipts
        }
        #expect(try current()?.lead?.status == .queued)
        #expect(try current()?.blockingRequest?.id == "q-1")

        // The approval is answered, the runner claims the follow-up, and its turn completes.
        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/requests/0/status","value":"answered"}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/control/messages/0/status","value":"processing"}"#))
        #expect(try current()?.lead?.status == .processing)
        #expect(try current()?.queuedBlocker == nil)
        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/workers/1/control/messages/0/status","value":"completed"}"#))
        let settled = try #require(try current())
        #expect(settled.lead == nil)
        #expect(settled.retainedOutcome == FollowUpReceipt(id: "fu-1", status: "completed", generation: 3))
        #expect(try presented("w", in: RunContent(run: #require(reducer.runs.first))).queuedFollowUps == 0)

        // A fresh snapshot after a reconnect shows the same receipt.
        var reconnected = AGUIWorkspaceReducer()
        try reconnected.apply(frame: snapshot([workerJSON("w", control: controlJSON(
            activeTurn: "turn-2", messages: [messageJSON("fu-1", "completed")]))]))
        let after = try presented("w", in: RunContent(run: #require(reconnected.runs.first))).followUpReceipts
        #expect(after?.retainedOutcome == settled.retainedOutcome)

        // A new follow-up leads; the earlier outcome is still retained beside it.
        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/1/control/messages/-","value":\#(messageJSON("fu-2", "queued"))}"#))
        #expect(try current()?.lead?.id == "fu-2")
        #expect(try current()?.retainedOutcome?.id == "fu-1")
    }

    @Test func aClaimedAndAQueuedReceiptAreShownTogether() throws {
        let run = try content(
            [workerJSON("w", control: controlJSON(activeTurn: "turn-1", messages: [
                messageJSON("done", "completed"), messageJSON("running", "processing"),
                messageJSON("next", "queued")]))],
            requests: [requestJSON("q-1", worker: "w")])
        let receipts = try #require(try presented("w", in: run).followUpReceipts)
        #expect(receipts.shownOpen.map(\.id) == ["running", "next"])
        #expect(receipts.further.isEmpty)
        #expect(receipts.retainedOutcome?.id == "done")
        // The queued receipt keeps its exact approval while the earlier one runs.
        #expect(receipts.blockingRequest?.id == "q-1")
        #expect(receipts.statement(for: try #require(receipts.queued)).contains("pending approval q-1"))
        #expect(!receipts.statement(for: try #require(receipts.claimed)).contains("q-1"))
        #expect(receipts.summary.contains("follow-up running claimed by runner"))
        #expect(receipts.summary.contains("follow-up next accepted by commander, waits for approval q-1"))
        // Hand back names only the queued receipt.
        #expect(receipts.handBackCancels.map(\.id) == ["next"])
        let statement = try #require(receipts.handBackStatement)
        #expect(statement.contains("follow-up next, which the runner has not claimed"))
        #expect(!statement.contains("running"))
    }

    // MARK: Hand back

    @Test func handBackNamesOnlyUnclaimedFollowUpsOfTheHeldGeneration() throws {
        let run = try content([
            workerJSON("one", control: controlJSON(generation: 3, messages: [
                messageJSON("a", "queued", generation: 3), messageJSON("b", "processing", generation: 3)])),
            workerJSON("two", control: controlJSON(generation: 3, messages: [
                messageJSON("a", "queued", generation: 3), messageJSON("b", "queued", generation: 3)])),
            workerJSON("stale", control: controlJSON(generation: 4, messages: [messageJSON("a", "queued", generation: 3)])),
            workerJSON("claimed", control: controlJSON(generation: 3, messages: [messageJSON("a", "processing")])),
            workerJSON("legacy", control: controlJSON(generation: 3, messages: [messageJSON("a", "queued", generation: nil)])),
            workerJSON("released", control: controlJSON(held: false, generation: 3, messages: [messageJSON("a", "queued")]))
        ])
        let one = try #require(try presented("one", in: run).followUpReceipts)
        #expect(one.handBackCancels.map(\.id) == ["a"])
        #expect(one.handBackNote == "cancels 1 queued follow-up")
        let statement = try #require(one.handBackStatement)
        #expect(statement.contains("follow-up a,"))
        #expect(!statement.contains("follow-up b"))
        #expect(try presented("two", in: run).followUpReceipts?.handBackNote == "cancels 2 queued follow-ups")
        for id in ["stale", "claimed", "legacy", "released"] {
            #expect(try presented(id, in: run).followUpReceipts?.handBackNote == nil, "\(id)")
            #expect(try presented(id, in: run).followUpReceipts?.handBackStatement == nil, "\(id)")
        }
    }

    @Test func aClaimedReceiptStaysVisibleAcrossHandBack() throws {
        var reducer = AGUIWorkspaceReducer()
        try reducer.apply(frame: snapshot([workerJSON("w", control: controlJSON(messages: [
            messageJSON("claimed", "processing"), messageJSON("waiting", "queued")]))]))
        func current() throws -> FollowUpReceipts {
            let run = try #require(reducer.runs.first)
            let worker = try presented("w", in: RunContent(run: run))
            return try #require(worker.followUpReceipts)
        }
        #expect(try current().handBackCancels.map(\.id) == ["waiting"])

        // The developer hands back: the service cancels the unclaimed one and moves the generation.
        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/workers/1/control/held","value":false}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/control/generation","value":4}"#,
            #"{"op":"replace","path":"/runs/0/workers/1/control/messages/1/status","value":"cancelled"}"#))
        let after = try current()
        #expect(after.lead?.id == "claimed")
        #expect(after.lead?.label == "Claimed by runner")
        #expect(!after.statement(for: try #require(after.lead)).contains("cancel"))
        #expect(after.retainedOutcome?.id == "waiting")
        #expect(after.retainedOutcome?.status == .cancelled)
        #expect(after.handBackNote == nil)
    }

    // MARK: Scope

    @Test func onlyAManagedLocalClaudeWorkerGetsReceipts() throws {
        let messages = [messageJSON("a", "queued")]
        let run = try content([
            workerJSON("claude", control: controlJSON(messages: messages)),
            workerJSON("codex", harness: "codex", control: controlJSON(messages: messages)),
            workerJSON("empty", control: controlJSON(messages: []))
        ])
        #expect(try presented("claude", in: run).followUpReceipts != nil)
        let codex = try presented("codex", in: run)
        #expect(codex.followUpReceipts == nil)
        #expect(codex.queuedFollowUps == 1)
        #expect(try presented("empty", in: run).followUpReceipts == nil)
        #expect(run.coordinator?.followUpReceipts == nil)
    }
}
