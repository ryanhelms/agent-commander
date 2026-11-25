import Foundation
import Testing
@testable import AgentCommander

// Narrative activity stories: the card and its first disclosure tell what was asked, what came
// back and what is still needed; repeated polls stay evidence; actions exist only where the
// parent scopes them by exact request ID; every original call stays in Tool details.

private func record(_ id: String, _ status: String, answer: String = "", text: String = "Which receipt code confirms the teal swatch?") -> String {
    #"{"id":"\#(id)","worker_id":"w","question":"\#(text)","status":"\#(status)","answer":"\#(answer)"}"#
}

private func stories(_ wire: Wire, requests: [Question] = [], awaiting: String? = nil,
                     scope: ActivityStoryScope = ActivityStoryScope()) -> [ActivityStory] {
    let entries = CommanderActivity.annotate(wire.entries, requests: requests)
    return ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty), awaitingToolID: awaiting)
        .compactMap { item -> ActivityStory? in
            switch item {
            case .commander(let flow): ActivityStories.story(for: flow, scope: scope)
            case .entry(let entry): ActivityStories.story(for: entry, awaitingToolID: awaiting, scope: scope)
            case .activity: nil
            }
        }
}

private func formScope(_ id: String, holder: String? = nil) -> ActivityStoryScope {
    ActivityStoryScope(requests: [.init(id: id, route: .form, holder: holder)])
}

/// The approved screenshot: one Ask, seven Waits (six still pending, the last answered) and one Result.
private func receiptWire(waits pending: Int = 6, answered: Bool = true, result: Bool = true, resultOpen: Bool = false) -> Wire {
    var wire = Wire()
    wire.user("Confirm the teal swatch receipt.")
    wire.call("mcp__commander__commander_ask", detail: #"{"question":"Which receipt code confirms the teal swatch?"}"#,
              result: record("q-83202cb42d449a0f52b7981d56ac896a", "pending"))
    for _ in 0..<pending {
        wire.call("mcp__commander__commander_wait", commander: ["requestId": "q-83202cb42d449a0f52b7981d56ac896a"],
                  result: record("q-83202cb42d449a0f52b7981d56ac896a", "pending"))
    }
    if answered {
        wire.call("mcp__commander__commander_wait", commander: ["requestId": "q-83202cb42d449a0f52b7981d56ac896a"],
                  result: record("q-83202cb42d449a0f52b7981d56ac896a", "answered", answer: "TEAL-42"))
    }
    if result {
        wire.call("mcp__commander__commander_result", detail: #"{"result":"The confirmed receipt code is TEAL-42."}"#,
                  result: resultOpen ? nil : "{}")
    }
    return wire
}

private let receiptID = "q-83202cb42d449a0f52b7981d56ac896a"

@Suite struct ActivityStoryTests {
    // MARK: Questions

    @Test func aPendingQuestionSaysWhatDecisionIsNeededAndWhoIsNeeded() throws {
        let wire = receiptWire(waits: 3, answered: false, result: false)
        let story = try #require(stories(wire, scope: formScope(receiptID, holder: "planner")).first)
        #expect(story.kind == "Decision needed")
        #expect(story.lead == "“Which receipt code confirms the teal swatch?”")
        #expect(story.status == .waitingForReply)
        #expect(story.context == "Needs planner · request q-83202c")
        // Asked, then the waiting state once: the three probes are evidence, not milestones.
        #expect(story.milestones.map(\.kind) == [.asked, .waiting])
        #expect(story.milestones.map(\.label) == ["Asked", "Waiting for reply"])
        #expect(story.evidence.count == 4)
        #expect(story.outcome == nil)
        // Who is needed is said only when the parent knows it.
        let unknown = try #require(stories(wire).first)
        #expect(unknown.context == "request q-83202c")
        #expect(unknown.milestones.last?.detail == nil)
    }

    @Test func anAnswerThatArrivesBeforeTheReportLeadsAndReportingIsDistinct() throws {
        let open = try #require(stories(receiptWire(resultOpen: true)).first)
        #expect(open.status == .running)
        #expect(open.lead == "“TEAL-42”")
        #expect(open.context == "Asked “Which receipt code confirms the teal swatch?” · reporting to coordinator")
        #expect(open.milestones.map(\.kind) == [.asked, .answered, .reporting])
        #expect(open.milestones.map(\.label) == ["Asked", "Answer arrived", "Reporting to coordinator"])
        // The answer is placed at the call that actually carried it: the seventh wait.
        let answering = open.evidence[7].id
        #expect(open.milestones[1].entryIDs == [answering])

        // Answered with no report yet: no reporting state is invented.
        let unreported = try #require(stories(receiptWire(result: false)).first)
        #expect(unreported.status == .answered)
        #expect(unreported.milestones.map(\.kind) == [.asked, .answered])
        #expect(unreported.outcome == "TEAL-42")
    }

    @Test func theCompleteReceiptStoryMatchesTheApprovedDesign() throws {
        let story = try #require(stories(receiptWire()).first)
        #expect(story.kind == "Question and result")
        #expect(story.status == .complete)
        // The terminal outcome leads; the polls take over neither the lead nor the timeline.
        #expect(story.lead == "The confirmed receipt code is TEAL-42.")
        #expect(story.context == "Asked “Which receipt code confirms the teal swatch?” · answer “TEAL-42”")
        #expect(story.milestones.map(\.label) == ["Asked", "Answer arrived", "Reported to coordinator"])
        #expect(story.milestones.allSatisfy { !$0.label.contains("Wait") })
        // Every original call stays in Tool details, in order.
        #expect(story.steps == "Ask · Wait ×7 · Result")
        #expect(story.evidence.count == 9)
        #expect(story.outcome == "The confirmed receipt code is TEAL-42.")
        #expect(story.relations.first == ActivityRelation(kind: .request, value: receiptID, label: "q-83202c"))
        // Copy is offered for the outcome; no request action once it is answered.
        let actions = story.actions(in: formScope(receiptID))
        #expect(actions.map(\.intent) == [.copy("The confirmed receipt code is TEAL-42.")])
    }

    @Test func identityAndDisclosureKeysHoldAsFactsUpdate() throws {
        let waiting = try #require(stories(receiptWire(waits: 2, answered: false, result: false)).first)
        let answered = try #require(stories(receiptWire(waits: 2, answered: true, result: true, resultOpen: true)).first)
        let complete = try #require(stories(receiptWire(waits: 2)).first)
        #expect(Set([waiting.id, answered.id, complete.id]).count == 1)
        #expect(waiting.milestones[0].id == complete.milestones[0].id)
        #expect(answered.milestones.map(\.id) == Array(complete.milestones.map(\.id)))
        // More probes change neither the story nor any milestone identity.
        let longer = try #require(stories(receiptWire(waits: 6)).first)
        #expect(longer.id == complete.id)
        #expect(longer.milestones.map(\.label) == complete.milestones.map(\.label))
    }

    @Test func unknownHistoryAndFailedProbesAreTruthful() throws {
        var wire = Wire()
        // The ask is not in this transcript; two probes failed the same way, one succeeded.
        wire.call("commander_wait", commander: ["requestId": "req-1"], error: "transport closed")
        wire.call("commander_wait", commander: ["requestId": "req-1"], error: "transport closed")
        wire.call("commander_wait", commander: ["requestId": "req-1"], result: record("req-1", "pending", text: "Ship it?"))
        let story = try #require(stories(wire).first)
        #expect(story.kind == "Decision needed")
        #expect(story.lead == "“Ship it?”")
        #expect(story.context == "ask not in this transcript · request req-1")
        // No Asked milestone is invented; the failure is one milestone, counted.
        #expect(!story.milestones.contains { $0.kind == .asked })
        #expect(story.milestones.map(\.label) == ["Wait failed ×2", "Waiting for reply"])
        #expect(story.milestones[0].detail == "transport closed")
        #expect(story.failedCalls == 2)

        // A request the run reports cancelled says so as its own milestone.
        var asked = Wire()
        asked.call("commander_ask", detail: "Ship it?", result: record("req-2", "pending", text: "Ship it?"))
        let cancelled = Question(id: "req-2", workerID: "w", question: "Ship it?", status: "cancelled", answer: "")
        let closed = try #require(stories(asked, requests: [cancelled]).first)
        #expect(closed.status == .cancelled)
        #expect(closed.milestones.map(\.label) == ["Asked", "Request cancelled"])

        // A reply whose result names another request is recovery evidence, never an answer.
        var reply = Wire()
        reply.call("commander_reply", detail: #"{"request_id":"req-3","answer":"go"}"#, result: record("req-9", "answered", answer: "go"))
        let unconfirmed = try #require(stories(reply).first)
        #expect(unconfirmed.milestones.map(\.label) == ["Reply not confirmed"])
        #expect(unconfirmed.milestones[0].status == .uncertain)
    }

    @Test func theRunsAnswerIsUsedWhenNoCallCarriedIt() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "Which?", result: record("req-1", "pending", text: "Which?"))
        let answered = Question(id: "req-1", workerID: "w", question: "Which?", status: "answered", answer: "Blue")
        let story = try #require(stories(wire, requests: [answered]).first)
        #expect(story.milestones.map(\.label) == ["Asked", "Answered"])
        #expect(story.milestones[1].entryIDs.isEmpty)
        #expect(story.lead == "“Blue”")
        // A run that still has it pending wins over a call that said otherwise.
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: record("req-1", "answered", answer: "x", text: "Which?"))
        let pending = Question(id: "req-1", workerID: "w", question: "Which?", status: "pending", answer: "")
        let stillWaiting = try #require(stories(wire, requests: [pending]).first)
        #expect(stillWaiting.milestones.map(\.kind) == [.asked, .waiting])
    }

    // MARK: Decision scoping

    @Test func requestActionsAreScopedByExactRequestID() throws {
        let story = try #require(stories(receiptWire(waits: 1, answered: false, result: false)).first)
        #expect(story.isDecisionPending)
        // The parent's own form: Reply focuses it.
        let reply = story.actions(in: formScope(receiptID))
        #expect(reply.map(\.intent) == [.focusRequest(receiptID)])
        #expect(reply.first?.label == "Reply" && reply.first?.isPrimary == true)
        // A parent that routes the request elsewhere: Open request.
        let open = story.actions(in: ActivityStoryScope(requests: [.init(id: receiptID, route: .open)]))
        #expect(open.map(\.intent) == [.openRequest(receiptID)])
        // A different or prefix ID, or a parent with no request: no request action.
        #expect(story.actions(in: formScope("q-83202c")).isEmpty)
        #expect(story.actions(in: formScope(receiptID + "0")).isEmpty)
        #expect(story.actions(in: ActivityStoryScope()).isEmpty)
        // Choices read as Choose.
        let choices = story.actions(in: ActivityStoryScope(requests: [.init(id: receiptID, route: .form, offersChoices: true)]))
        #expect(choices.first?.label == "Choose")
        // Source is offered only where the parent can open it.
        #expect(story.actions(in: ActivityStoryScope(canOpenSource: true)).map(\.intent) == [.openSource])
    }

    @Test func anApprovalHoldingACallUsesTheExistingRequestForm() throws {
        var wire = Wire()
        let held = wire.call("commander_send", detail: #"{"worker_id":"w-2","text":"go"}"#)
        let scope = ActivityStoryScope(requests: [.init(id: "perm-1", route: .form, offersChoices: true, awaitingToolID: held)])
        let story = try #require(stories(wire, awaiting: held, scope: scope).first)
        #expect(story.status == .awaitingApproval)
        let actions = story.actions(in: scope)
        #expect(actions.map(\.intent) == [.focusRequest("perm-1")])
        #expect(actions.first?.label == "Review approval")
        // A request holding another call is not this story's approval.
        let other = ActivityStoryScope(requests: [.init(id: "perm-1", route: .form, offersChoices: true, awaitingToolID: "call-x")])
        #expect(story.actions(in: other).isEmpty)
    }

    // MARK: Other Commander families

    @Test func delegationAndControlsAreAcceptedNotComplete() throws {
        var wire = Wire()
        wire.call("commander_delegate", detail: #"{"name":"scout","task":"t","kind":"research"}"#,
                  result: #"{"id":"worker-123456789","name":"scout","state":"starting"}"#)
        wire.call("commander_interrupt", detail: #"{"worker_id":"w-2"}"#, result: #"{"state":"idle"}"#)
        wire.call("commander_send", detail: #"{"worker_id":"w-2","text":"Also check X"}"#, result: #"{"id":"msg-1","status":"queued"}"#)
        let shown = stories(wire)
        #expect(shown.map(\.kind) == ["Delegate worker", "Interrupt worker", "Send follow-up"])
        #expect(shown.map(\.status) == [.accepted, .accepted, .queued])
        #expect(shown[0].relations.map(\.value) == ["worker-123456789"])
        #expect(shown[2].lead == "“Also check X”")
        #expect(shown[2].relations.map(\.kind) == [.worker])
        // The run's record by exact ID settles the follow-up.
        let live = CommanderActivity.annotate(wire.entries, live: CommanderLiveState(followUps: ["w-2": ["msg-1": "completed"]]))
        let settled = ConversationActivity.items(TranscriptEntry.displayed(live, mode: .pretty)).compactMap { item -> ActivityStory? in
            if case .commander(let flow) = item { ActivityStories.story(for: flow, scope: ActivityStoryScope()) } else { nil }
        }
        #expect(settled.last?.status == .complete)
        #expect(shown.allSatisfy { $0.milestones.isEmpty })
    }

    @Test func aCommitAndItsResultTellTheChangeStory() throws {
        let full = "0123456789abcdef0123456789abcdef01234567"
        var wire = Wire()
        wire.call("commander_commit", detail: #"{"files":["a.swift","b.swift"],"message":"Fix swatch"}"#, result: #"{"revision":"\#(full)"}"#)
        wire.call("commander_result", detail: #"{"result":"Fixed the swatch","revision":"\#(full)","tests":[{"command":"swift test","outcome":"pass"}]}"#,
                  result: "{}")
        let story = try #require(stories(wire).first)
        #expect(story.kind == "Commit and result")
        #expect(story.lead == "Fixed the swatch")
        #expect(story.milestones.map(\.label) == ["Committed", "Reported to coordinator"])
        #expect(story.relations.map(\.kind) == [.revision, .file, .file, .test])
        #expect(story.relations[0].value == full)
        #expect(story.relations[3].label == "swift test · pass")
        #expect(story.outcome == "Fixed the swatch")
    }

    @Test func relayReceiptsBecomeMilestonesOnlyWhenTheStatusChanges() throws {
        var wire = Wire()
        wire.call("commander_network_submit", detail: #"{"id":"op-1","targets":[{"resource":"r","action":"agent.ask","payload":{}}]}"#,
                  result: #"{"status":"accepted"}"#)
        for _ in 0..<3 {
            wire.call("commander_network_receipt", detail: #"{"id":"op-1"}"#, result: #"{"children":[{"status":"processing"}]}"#)
        }
        wire.call("commander_network_receipt", detail: #"{"id":"op-1"}"#, error: "relay unavailable")
        wire.call("commander_network_receipt", detail: #"{"id":"op-1"}"#, result: #"{"children":[{"status":"completed"},{"status":"failed"}]}"#)
        let story = try #require(stories(wire).first)
        #expect(story.kind == "Relay operation")
        #expect(story.status == .partial)
        #expect(story.milestones.map(\.label) == ["Submitted", "Receipt: running", "Receipt failed", "Receipt: partial"])
        #expect(story.milestones[2].detail == "relay unavailable")
        #expect(story.lead == "2 recipients · 1 completed, 1 failed")
        #expect(story.evidence.count == 6)
        #expect(story.relations.map(\.value) == ["op-1"])
    }

    @Test func extensionAppAndStatusCallsUseTheirDomainDefaults() throws {
        var wire = Wire()
        wire.call("commander_call_tool", detail: #"{"id":"lint","version":2,"arguments":{}}"#, result: #"{"status":"ok"}"#)
        wire.call("commander_call_frontend", detail: #"{"name":"pick_color","arguments":{}}"#, result: "Picked plum")
        wire.call("commander_status", detail: #"{"wait_seconds":30}"#, result: #"{"status":"running","workers":[{"state":"working"}]}"#)
        wire.call("commander_list_tools", error: "bridge offline")
        let shown = stories(wire)
        #expect(shown.map(\.kind) == ["Call extension", "Call app tool", "Check status", "List extensions"])
        #expect(shown[0].relations.map(\.value) == ["lint"])
        #expect(shown[1].lead == "pick_color")
        #expect(shown[2].lead == "1 worker · 1 working · run running")
        #expect(shown[2].context == "wait up to 30s")
        // A one-call story states its failure in its context.
        #expect(shown[3].status == .failed)
        #expect(shown[3].context == "bridge offline")
    }

    // MARK: Provider tools

    @Test func recognisedProviderToolsTellAOneCallStoryAndOthersKeepTheRawRow() throws {
        var wire = Wire()
        let read = wire.call("Read", detail: "Sources/Swatch.swift", result: "text")
        wire.call("Edit", detail: "Sources/Swatch.swift", result: "ok")
        wire.call("Grep", detail: "teal", result: "3 matches")
        wire.call("Bash", detail: "swift test\n--filter Swatch", error: "exit status 1")
        wire.call("mcp__linear__create_issue", detail: "x", result: "{}")
        wire.call("Read file Sources/a.swift", detail: nil, result: "text")
        let shown = stories(wire)
        #expect(shown.map(\.kind) == ["Read file", "Edit file", "Search", "Run command"])
        #expect(shown[0].id == read + "#story")
        #expect(shown[0].lead == "Sources/Swatch.swift")
        #expect(shown[0].context == "Read")
        #expect(shown[0].status == .complete)
        #expect(shown[0].evidence.map(\.id) == [read])
        // The exact first line of the provider's detail; the failure is stated, not inferred.
        #expect(shown[3].lead == "swift test")
        #expect(shown[3].status == .failed)
        #expect(shown[3].context == "exit status 1 · Bash")
        #expect(shown[3].failedCalls == 1)
        // An unrecognised name, a title, and a Commander tool get no provider story.
        let entries = wire.entries
        #expect(ActivityStories.story(for: entries[4], awaitingToolID: nil, scope: ActivityStoryScope()) == nil)
        #expect(ActivityStories.story(for: entries[5], awaitingToolID: nil, scope: ActivityStoryScope()) == nil)
        let commander = TranscriptEntry(id: "c", kind: .tool(name: "mcp__commander__commander_ask", detail: "q", result: nil))
        #expect(ActivityStories.story(for: commander, awaitingToolID: nil, scope: ActivityStoryScope()) == nil)
    }

    @Test func aProviderToolHeldForApprovalOffersTheExistingForm() throws {
        var wire = Wire()
        let held = wire.call("Bash", detail: "rm -rf build")
        let scope = ActivityStoryScope(requests: [.init(id: "perm-2", route: .form, offersChoices: true, awaitingToolID: held)])
        let story = try #require(stories(wire, awaiting: held, scope: scope).first)
        #expect(story.status == .awaitingApproval)
        #expect(story.actions(in: scope).first?.label == "Review approval")
    }

    // MARK: PiP

    /// The PiP's recent window cuts the Ask off a long wait; anchored from the whole transcript,
    /// the request still reads as one story with its Ask, and every window entry is shown once.
    @Test func thePiPKeepsTheAskOfItsRequest() throws {
        var wire = receiptWire(waits: 6, answered: false, result: false)
        wire.say("Still waiting for the receipt code.")
        let full = wire.entries
        let window = TranscriptEntry.recent(full)
        #expect(!window.contains { $0.id == full[1].id }, "the window must cut the ask for this test")
        // Without the anchor the window loses the Ask.
        let bare = ConversationActivity.items(window).compactMap { item -> CommanderWorkflow? in
            if case .commander(let flow) = item { flow } else { nil }
        }
        #expect(bare.first?.calls.contains { $0.tool == .ask } == false)

        let anchor = try #require(CommanderActivity.workflow(request: receiptID, in: full))
        let anchored = ConversationActivity.items(window, anchor: anchor)
        let flows = anchored.compactMap { item -> CommanderWorkflow? in if case .commander(let flow) = item { flow } else { nil } }
        #expect(flows.count == 1)
        let story = ActivityStories.story(for: flows[0], scope: formScope(receiptID))
        #expect(story.kind == "Decision needed")
        #expect(story.milestones.map(\.kind) == [.asked, .waiting])
        #expect(story.evidence.count == 7)
        #expect(story.actions(in: formScope(receiptID)).first?.intent == .focusRequest(receiptID))
        // Every window entry is still shown exactly once, plus the anchor's earlier calls.
        let shownIDs = anchored.flatMap(\.entries).map(\.id)
        #expect(Set(shownIDs).count == shownIDs.count)
        #expect(Set(window.map(\.id)).isSubset(of: Set(shownIDs)))
        // The anchored story keeps the same identity as on the focused worker.
        let focused = try #require(stories(wire).first)
        #expect(story.id == focused.id)
        // No anchor for a request no Commander call names.
        #expect(CommanderActivity.workflow(request: "perm-1", in: full) == nil)
    }

    // MARK: Release review

    /// Structured provider arguments lead with their stated subject; JSON and placeholders do not.
    @Test func providerStoriesLeadWithTheStatedFact() throws {
        func story(_ name: String, _ detail: String?) -> ActivityStory? {
            let entry = TranscriptEntry(id: "t", kind: .tool(name: name, detail: detail, result: ToolResult(output: "ok")))
            return ActivityStories.story(for: entry, awaitingToolID: nil, scope: ActivityStoryScope())
        }
        let read = try #require(story("Read", #"{"file_path":"Sources/App.swift"}"#))
        #expect(read.lead == "Sources/App.swift")
        #expect(story("Grep", #"{"pattern":"teal","path":"Sources"}"#)?.lead == "teal")
        #expect(story("WebFetch", #"{"url":"https://example.com/a","prompt":"x"}"#)?.lead == "https://example.com/a")
        #expect(story("WebSearch", #"{"query":"swift focus state"}"#)?.lead == "swift focus state")
        #expect(story("Bash", #"{"command":"swift test --filter Swatch","description":"Run"}"#)?.lead == "swift test --filter Swatch")
        #expect(story("shell", #"{"command":["bash","-lc","ls"]}"#)?.lead == "bash -lc ls")
        // Plain fallback, and nothing for JSON without a known field or an ACP placeholder.
        #expect(story("Read", "Sources/App.swift")?.lead == "Sources/App.swift")
        #expect(story("Read", #"{"offset":2}"#)?.lead == nil)
        #expect(story("Read", "other")?.lead == nil)
        // Structured arguments stay behind Tool details on the first expansion; a plain detail does not.
        #expect(!read.showsEvidenceDirectly)
        #expect(story("Read", "Sources/App.swift")?.showsEvidenceDirectly == true)
        // The original arguments remain in the evidence, exactly as sent.
        #expect(read.evidence.first?.kind == .tool(name: "Read", detail: #"{"file_path":"Sources/App.swift"}"#,
                                                    result: ToolResult(output: "ok")))
    }

    @Test func anACPPlaceholderNeverHeadsACommanderStory() throws {
        let entry = TranscriptEntry(id: "c", kind: .tool(name: "commander_wait", detail: "other", result: nil))
        #expect(try #require(CommanderCall(entry: entry)).plainDetail == nil)
        var wire = Wire()
        wire.call("commander_wait", detail: "other")
        let story = try #require(stories(wire).first)
        #expect(story.lead == nil)
        #expect(story.context == nil)
    }

    @Test func theAnswerMilestoneKeepsItsIDWhenTheRunAnswersFirst() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "Which?", result: record("req-1", "pending", text: "Which?"))
        let answered = Question(id: "req-1", workerID: "w", question: "Which?", status: "answered", answer: "Blue")
        let early = try #require(stories(wire, requests: [answered]).first)
        let wait = wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#,
                             result: record("req-1", "answered", answer: "Blue", text: "Which?"))
        let late = try #require(stories(wire, requests: [answered]).first)
        let before = try #require(early.milestones.first { $0.kind == .answered })
        let after = try #require(late.milestones.first { $0.kind == .answered })
        #expect(before.id == after.id)
        #expect(before.entryIDs.isEmpty)
        #expect(after.entryIDs == [wait])
        #expect(late.milestones.filter { $0.kind == .answered }.count == 1)
    }

    @Test func aFailedPollBesideTheAskStillSurfaces() throws {
        var wire = Wire()
        wire.call("commander_ask", detail: "Ship it?", result: record("req-1", "pending", text: "Ship it?"))
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, error: "transport closed")
        wire.call("commander_wait", detail: #"{"request_id":"req-1"}"#, result: record("req-1", "pending", text: "Ship it?"))
        let story = try #require(stories(wire).first)
        #expect(story.milestones.map(\.label) == ["Asked", "Wait failed", "Waiting for reply"])
        #expect(story.milestones.first { $0.kind == .waiting }?.entryIDs.isEmpty == true)
    }

    @Test func aReportHeldForApprovalHasNotStarted() throws {
        let wire = receiptWire(resultOpen: true)
        let report = try #require(wire.entries.last?.id)
        let story = try #require(stories(wire, awaiting: report).first)
        #expect(story.status == .awaitingApproval)
        let held = try #require(story.milestones.last)
        #expect(held.label == "Report awaiting approval")
        #expect(held.status == .awaitingApproval)
        #expect(held.entryIDs == [report])
        #expect(!story.milestones.contains { $0.label == "Reporting to coordinator" })
        #expect(story.context?.hasSuffix("report awaiting approval") == true)
        // The approval's form is offered through the existing request.
        let scope = ActivityStoryScope(requests: [.init(id: "perm-3", route: .form, offersChoices: true, awaitingToolID: report)])
        #expect(story.actions(in: scope).first?.label == "Review approval")
    }

    @Test func aFormActionNeedsAFormThatAcceptsInput() throws {
        let story = try #require(stories(receiptWire(waits: 1, answered: false, result: false)).first)
        let blocked = ActivityStoryScope(requests: [.init(id: receiptID, route: .form, acceptsInput: false)])
        #expect(story.actions(in: blocked).isEmpty)
        // Opening a held request to inspect it stays valid.
        let open = ActivityStoryScope(requests: [.init(id: receiptID, route: .open, acceptsInput: false)])
        #expect(story.actions(in: open).map(\.intent) == [.openRequest(receiptID)])
    }

    @Test func aBoundedTimelineKeepsTheFirstAndLatestMilestones() throws {
        var wire = Wire()
        wire.call("commander_network_submit", detail: #"{"id":"op-1","targets":[]}"#, result: #"{"status":"pending"}"#)
        for status in ["processing", "pending", "processing", "completed"] {
            wire.call("commander_network_receipt", detail: #"{"id":"op-1"}"#, result: #"{"status":"\#(status)"}"#)
        }
        let story = try #require(stories(wire).first)
        #expect(story.milestones.count == 5)
        let bounded = story.timeline(limit: 4)
        #expect(bounded.hidden == 1)
        #expect(bounded.shown.map(\.id) == [story.milestones[0].id] + story.milestones.suffix(3).map(\.id))
        #expect(story.timeline(limit: nil).shown == story.milestones)
    }
}
