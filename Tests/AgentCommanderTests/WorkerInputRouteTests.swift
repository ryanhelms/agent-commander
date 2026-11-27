import Foundation
import Testing
@testable import AgentCommander

// Issue #98. A delegated worker's pending question or portable ACP approval stays with its
// coordinator or delegating parent until the developer takes control of that worker, and returns
// there at once on hand-back. A coordinator's own question is always the developer's. One rule
// (`WorkerInputRoute`) decides it for `CockpitModel.pending`, the reply and `RunContent`.

private let session = NativeSession(harnessInstance: "codex-acp", sessionID: "sess-1")

private func control(held: Bool, generation: Int = 4) -> WorkerControl {
    WorkerControl(held: held, generation: generation, interruptRequested: nil, messages: nil)
}

private func worker(_ id: String, parent: String = "lead", state: String = "waiting",
                    control: WorkerControl? = nil) -> Worker {
    Worker(id: id, name: id, role: id == "lead" ? "coordinator" : "worker", parentID: parent, runID: "r",
           state: state, host: "localhost", worktree: "/tmp/w", task: "build", output: "",
           control: control, nativeSession: session)
}

private func question(_ id: String, worker: String, status: String = "pending") -> Question {
    Question(id: id, workerID: worker, question: "Retry after body bytes?", status: status, answer: "")
}

/// A portable ACP approval: the reply must be the exact ID of one offered choice.
private func approval(_ id: String, worker: String) -> Question {
    Question(id: id, workerID: worker, question: "Allow the write?", status: "pending", answer: "",
             choices: [QuestionChoice(id: "allow_once", label: "Allow once"), QuestionChoice(id: "reject", label: "Reject")])
}

private func run(_ workers: [Worker], _ requests: [Question]) -> Run {
    Run(id: "r", project: "p", path: "/p", task: "ship it", client: "claude", coordinatorID: "lead",
        status: "running", workers: [worker("lead", parent: "", state: "working")] + workers, requests: requests)
}

@MainActor private func model(_ run: Run) -> CockpitModel {
    let model = CockpitModel()
    model.runs = [run]
    return model
}

private func presented(_ id: String, in content: RunContent) throws -> WorkerPresentation {
    try #require(content.wall.workers.first { $0.id == id })
}

@Suite @MainActor struct WorkerInputRouteTests {
    // MARK: The rule

    @Test func theRuleNamesWhoAnswers() {
        #expect(WorkerInputRoute.of(worker("lead"), coordinatorID: "lead") == .developer(generation: nil))
        #expect(WorkerInputRoute.of(worker("w", control: control(held: false)), coordinatorID: "lead") == .owner)
        #expect(WorkerInputRoute.of(worker("w", control: control(held: true, generation: 7)), coordinatorID: "lead")
                == .developer(generation: 7))
        // No control record: the service models no ownership for it, so it answers as before.
        #expect(WorkerInputRoute.of(worker("w"), coordinatorID: "lead") == .developer(generation: nil))
        // A coordinator is never routed to an owner, whatever its control record says.
        #expect(WorkerInputRoute.of(worker("lead", control: control(held: false)), coordinatorID: "lead").isDeveloper)
    }

    // MARK: Observed: the owner answers

    @Test func anUnheldWorkersQuestionAndApprovalStayWithTheCoordinator() throws {
        let run = run([worker("w", control: control(held: false))],
                      [question("q-ask", worker: "w"), approval("q-allow", worker: "w")])
        let model = model(run)
        let content = RunContent(run: run)
        let tile = try presented("w", in: content)

        // Not the developer's: no attention count, no cycle, no PiP, no Needs you, no inline form.
        #expect(model.pending.isEmpty)
        #expect(content.awaiting.isEmpty)
        #expect(CockpitContent(model: model).pending.isEmpty)
        #expect(tile.request == nil && tile.pendingRequests.isEmpty && tile.allRequests.isEmpty)

        // Still the worker's own status and records, by the same exact IDs.
        #expect(tile.state == .needsInput)
        #expect(tile.observedRequests.map(\.id) == ["q-ask", "q-allow"])
        #expect(tile.observedRequests.last?.choices.map(\.id) == ["allow_once", "reject"])
        #expect(tile.control == .observing(holder: "ship it"))
        #expect(tile.statusLabel == "Waiting for coordinator")
        #expect(tile.waitsOnOwner == WorkerInputOwner())
    }

    @Test func aNestedWorkerWaitsForTheParentThatDelegatedIt() throws {
        let run = run([worker("parent", state: "working", control: control(held: false)),
                       worker("child", parent: "parent", control: control(held: false))],
                      [question("q-1", worker: "child")])
        let child = try presented("child", in: RunContent(run: run))
        #expect(child.statusLabel == "Waiting for parent")
        #expect(child.inputOwner?.phrase == "parent")
        #expect(model(run).pending.isEmpty)
    }

    @Test func prettySaysWhoTheWorkerWaitsFor() throws {
        let unheld = run([worker("w", control: control(held: false))], [approval("q-allow", worker: "w")])
        let tile = try presented("w", in: RunContent(run: unheld))
        let observed = PrettyRunStatus(state: tile.state, entries: [], waitingOwner: tile.waitsOnOwner)
        #expect(observed.word == "Waiting for coordinator")
        // The open call's approval anchor is kept: the request still offers its exact choices.
        #expect(tile.anchoringRequest?.id == "q-allow")
        #expect(tile.anchoringRequest?.choices.isEmpty == false)

        let held = run([worker("w", control: control(held: true))], [approval("q-allow", worker: "w")])
        let mine = try presented("w", in: RunContent(run: held))
        #expect(mine.waitsOnOwner == nil && mine.statusLabel == "Needs input")
        #expect(PrettyRunStatus(state: mine.state, entries: [], waitingOwner: mine.waitsOnOwner).word == "Waiting for you")
    }

    /// The observed worker's console holds the exact call its coordinator approves. The permission
    /// names `plan` while `rival` is also open, so the one-open-call rule could not pick it.
    @Test func theObservedConsoleAnchorsTheExactPlanTheCoordinatorApproves() throws {
        func call(_ id: String, _ name: String) -> AGUIMessage {
            AGUIMessage(id: "m-\(id)", role: "assistant",
                        toolCalls: [AGUIToolCall(id: "w:\(id)", function: .init(name: name, arguments: "{}"))])
        }
        let planner = Worker(id: "w", name: "w", role: "worker", parentID: "lead", runID: "r", state: "waiting",
                             host: "localhost", worktree: "/tmp/w", task: "build", output: "",
                             messages: [call("rival", "Bash"), call("plan", "ExitPlanMode")],
                             control: control(held: false), nativeSession: session)
        let permission = Question(id: "q-plan", workerID: "w", question: "Approve the plan?", status: "pending",
                                  answer: "", choices: [QuestionChoice(id: "allow_once", label: "Allow once"),
                                                        QuestionChoice(id: "reject", label: "Reject")],
                                  providerToolCallID: "plan")
        let tile = try presented("w", in: RunContent(run: run([planner], [permission])))
        #expect(tile.transcript.map(\.id).contains("w:rival"))
        let console = PrettyACPConsole(worker: tile, session: session)

        // Nothing the developer can act on: no form, no reply context, no story request action.
        #expect(console.request == nil && console.reply == nil)
        #expect(console.stories.requests.isEmpty)
        #expect(console.stories.focusRequest == nil && console.stories.openRequest == nil)

        // The permission's exact call is the awaiting marker and the one call that shows its plan.
        guard case .resolved(let awaiting) = console.awaitingApproval else {
            Issue.record("The worker's console resolves its awaiting call from the anchoring request")
            return
        }
        #expect(awaiting == "w:plan")
        #expect(console.exactApprovalToolID == "w:plan")
        #expect(console.choiceRequestPending)

        // The coordinator owns the answer.
        #expect(console.waitingOwner == WorkerInputOwner())
        #expect(console.waitingOwner?.waitingLabel == "Waiting for coordinator")
    }

    // MARK: Take control, then hand back

    @Test func takingControlRevealsTheExactRequestAndHandingBackRemovesIt() throws {
        let requests = [question("q-018", worker: "w"), approval("q-allow", worker: "w")]
        let observed = run([worker("w", control: control(held: false, generation: 4))], requests)
        let model = model(observed)
        #expect(model.pending.isEmpty)
        #expect(model.replyTarget(requestID: "q-018") == .owner(worker: "w", owner: WorkerInputOwner()))

        // Take control: the same requests, by the same IDs, are the developer's.
        let taken = run([worker("w", control: control(held: true, generation: 5))], requests)
        model.runs = [taken]
        #expect(model.pending.map(\.id) == ["q-018", "q-allow"])
        let tile = try presented("w", in: RunContent(run: taken))
        #expect(tile.request?.id == "q-018" && tile.observedRequests.isEmpty)
        #expect(tile.pendingRequests.last?.choices.map(\.id) == ["allow_once", "reject"])
        #expect(RunContent(run: taken).awaiting.map(\.id) == ["q-018", "q-allow"])
        // The reply carries the control generation it was read under.
        #expect(model.replyTarget(requestID: "q-018") == .send(generation: 5))
        #expect(model.replyTarget(requestID: "q-allow") == .send(generation: 5))

        // Hand back: the action goes at once, and the question is not dropped.
        let returned = run([worker("w", control: control(held: false, generation: 6))], requests)
        model.runs = [returned]
        #expect(model.pending.isEmpty)
        let back = try presented("w", in: RunContent(run: returned))
        #expect(back.request == nil)
        #expect(back.observedRequests.map(\.id) == ["q-018", "q-allow"])
        #expect(returned.requests?.map(\.status) == ["pending", "pending"])
    }

    @Test func aReplyControlDrawnBeforeHandBackSendsNothing() async throws {
        let requests = [question("q-018", worker: "w")]
        let taken = run([worker("w", control: control(held: true, generation: 5))], requests)
        let model = model(taken)
        let stale = try #require(model.pending.first)

        // The service reports the hand-back while the reply field is still on screen.
        model.runs = [run([worker("w", control: control(held: false, generation: 6))], requests)]
        #expect(await model.reply(requestID: "q-018", text: "No") == false)
        #expect(model.notice?.contains("q-018") == true)
        #expect(model.notice?.contains("Take control of w") == true)
        #expect(model.sending.isEmpty)

        // The item a surface captured earlier is checked against the current state too.
        model.notice = nil
        #expect(await model.reply(to: stale, text: "No") == false)
        #expect(model.notice?.contains("the coordinator") == true)
        #expect(model.sending.isEmpty)
    }

    // MARK: The coordinator's own questions

    @Test func aCoordinatorsEscalationStaysActionableWhoeverHoldsItsWorkers() throws {
        let requests = [question("q-escalate", worker: "lead"), question("q-worker", worker: "w")]
        let run = run([worker("w", control: control(held: false))], requests)
        let model = model(run)
        #expect(model.pending.map(\.id) == ["q-escalate"])
        // A coordinator's own request carries no generation: the reply request is unchanged.
        #expect(model.replyTarget(requestID: "q-escalate") == .send(generation: nil))
        let content = RunContent(run: run)
        #expect(content.awaiting.map(\.id) == ["q-escalate"])
        #expect(content.coordinator?.request?.id == "q-escalate")
        #expect(content.coordinator?.observedRequests.isEmpty == true)
        #expect(content.coordinator?.inputOwner == nil)
        #expect(content.awaiting.first?.workerIsCoordinator == true)
    }

    @Test func aWorkerWithoutAControlRecordAnswersAsBefore() throws {
        let run = run([worker("legacy")], [question("q-1", worker: "legacy")])
        let model = model(run)
        #expect(model.pending.map(\.id) == ["q-1"])
        #expect(model.replyTarget(requestID: "q-1") == .send(generation: nil))
        #expect(try presented("legacy", in: RunContent(run: run)).request?.id == "q-1")
    }

    @Test func anAnsweredOrUnknownRequestHasNoTarget() {
        let run = run([worker("w", control: control(held: true))], [question("q-done", worker: "w", status: "answered")])
        let model = model(run)
        #expect(model.replyTarget(requestID: "q-done") == .gone)
        #expect(model.replyTarget(requestID: "q-missing") == .gone)
    }

    // MARK: The reply request

    @Test func theReplyBodyCarriesAGenerationOnlyForADelegatedWorker() throws {
        func fields(_ generation: Int?) throws -> [String: Any] {
            let data = try ServiceClient.replyBody(answer: "No $HOME `x`", generation: generation)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let own = try fields(nil)
        #expect(own.keys.sorted() == ["answer"])
        #expect(own["answer"] as? String == "No $HOME `x`")
        let delegated = try fields(5)
        #expect(delegated.keys.sorted() == ["answer", "generation"])
        #expect(delegated["generation"] as? Int == 5)
    }

    // MARK: Background line and structured requests

    @Test func theDelegatingConsoleSaysTheOwnerAnswers() {
        var job = BackgroundJob(kind: .question, recordID: "q-1", state: "pending", name: "reviewer", workerID: "w")
        job.questionOwner = WorkerInputOwner()
        let line = job.line(connected: true)
        #expect(line.sentence.plain == "reviewer is waiting for the coordinator's answer")
        #expect(line.rank != .needsYou)
        #expect(job.line(connected: false).sentence.plain == "reviewer: last known waiting for the coordinator's answer")
        // Nothing in the PiP's count says it needs the reader.
        let pip = BackgroundStackLayout(jobs: [job], density: .pip, connected: true)
        #expect(pip.count?.contains("need") != true)

        var mine = BackgroundJob(kind: .question, recordID: "q-2", state: "pending", name: "reviewer", workerID: "w",
                                 requestID: "q-2")
        mine.questionOwner = nil
        #expect(mine.line(connected: true).rank == .needsYou)
    }

    /// The held call's own line names who approves it, on the same exact tool ID.
    @Test func theHeldCallNamesWhoApprovesIt() throws {
        let call = TranscriptEntry(id: "call-1", kind: .tool(name: "shell", detail: "$ rm -rf build", result: nil))
        func sentence(_ owner: WorkerInputOwner?, awaiting: String? = "call-1") throws -> String {
            var facts = ActivityFacts.none
            facts.approvalOwner = owner
            return try #require(ActivitySteps.step(tool: call, awaitingToolID: awaiting, facts: facts)).sentence.plain
        }
        // The developer holds the worker: unchanged.
        let mine = try sentence(nil)
        #expect(mine.hasPrefix("Needs your approval to "))
        // Observed: the coordinator, or the parent that delegated the worker.
        let coordinators = try sentence(WorkerInputOwner())
        #expect(coordinators.hasPrefix("Waiting for the coordinator's approval to "))
        #expect(coordinators.dropFirst("Waiting for the coordinator's approval to ".count)
                == mine.dropFirst("Needs your approval to ".count))
        #expect(try sentence(WorkerInputOwner(parentName: "Failure paths"))
            .hasPrefix("Waiting for Failure paths's approval to "))
        #expect(!coordinators.contains("your"))
        // Only the anchored call reads as held: another ID keeps its own wording.
        #expect(try !sentence(WorkerInputOwner(), awaiting: "call-2").contains("approval"))
        // A tool with no command keeps "use".
        #expect(ActivityWords.approval(name: "write_file", detail: nil, summary: nil, owner: WorkerInputOwner()).plain
                == "Waiting for the coordinator's approval to use write_file")
        #expect(ActivityWords.approval(name: "write_file", detail: nil, summary: nil).plain
                == "Needs your approval to use write_file")
    }

    /// The Input requests panel is a separate owner-only consent path with no coordinator reply
    /// route, so worker control does not gate it: its scope is the bound session, as before.
    @Test func structuredRequestsAreNotGatedByWorkerControl() {
        let scope = ElicitationScope(workerID: "w", session: session)
        #expect(model(run([worker("w", control: control(held: false))], [])).elicitationScope("w") == scope)
        #expect(model(run([worker("w", control: control(held: true))], [])).elicitationScope("w") == scope)
        // The coordinator has no such panel, as before.
        #expect(model(run([], [])).elicitationScope("lead") == nil)
    }

    // MARK: The preview's sample workspace

    @Test func theAccessibleWorkerPreviewShowsBothPaths() throws {
        let store = PreviewStore(scenario: .accessibleWorker)
        func timeoutCases() throws -> WorkerPresentation {
            try #require(DesignFixture.runs(for: store).first?.wall.workers.first { $0.id == "W-047" })
        }
        // Held: the exact Q-018 is the developer's, inline and in Attention.
        #expect(try timeoutCases().control == .held)
        #expect(try timeoutCases().request?.id == "Q-018")
        #expect(DesignFixture.pending(for: store).map(\.id).contains("Q-018"))

        // Hand back: the reply goes at once and the question stays with the worker.
        store.release("W-047")
        let observed = try timeoutCases()
        #expect(observed.control == .observing(holder: "Failure paths"))
        #expect(observed.request == nil)
        #expect(observed.observedRequests.map(\.id) == ["Q-018"])
        #expect(observed.statusLabel == "Waiting for Failure paths")
        #expect(!DesignFixture.pending(for: store).map(\.id).contains("Q-018"))
        #expect(DesignFixture.content(for: store).selected?.awaiting.contains { $0.id == "Q-018" } == false)

        // Take control again: the same request returns.
        store.take("W-047")
        #expect(try timeoutCases().request?.id == "Q-018")
        #expect(DesignFixture.pending(for: store).map(\.id).contains("Q-018"))
    }

    @Test func theOtherPreviewsKeepTheirSampleRequest() {
        for scenario in [DesignPreviewScenario.attentionPip, .pipArrival, .accessibleWall, .attentionSwitch] {
            #expect(DesignFixture.pending(for: PreviewStore(scenario: scenario)).map(\.id) == ["Q-021"])
        }
        for scenario in [DesignPreviewScenario.attentionQueue, .attentionPanel] {
            #expect(DesignFixture.pending(for: PreviewStore(scenario: scenario)).map(\.id) == ["Q-021", "Q-018"])
        }
    }
}
