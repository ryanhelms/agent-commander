import Foundation
import Testing
@testable import AgentCommander

// The shared directory, access requests, approvals, audit, the grant sheet, Consult, Hand off and
// threads (design/COMMANDER-NETWORK-INCREMENT-3.md). Every handle, resource and run here is made up.
// No test reaches a network or the real helper.

enum MultiplayerShareFixture {
    static func data<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func object(_ raw: String?) throws -> [String: MultiplayerJSON] {
        guard case .object(let fields) = try data(MultiplayerJSON.self, raw ?? "null") else { return [:] }
        return fields
    }

    static let agentActions = #"["agent.ask","agent.handoff","agent.result","agent.status","thread.comment","thread.read"]"#

    static let status = MultiplayerFixture.output(#"""
    {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada",
     "friends":[{"handle":"fixture-bo"},{"handle":"fixture-cy"}],
     "resources":[{"id":"res-1","name":"relay","kind":"repo","actions":["issue.read","git.push"]}],
     "grants":[{"id":"g-1","handle":"fixture-bo","kind":"repo","resource":"res-1","capability":"git.push","maxUses":5,"expiresAt":"2026-11-24T12:00:00Z"}],
     "shared":[{"id":"dir-1","name":"bo-agent","kind":"agent","owner":"fixture-bo","actions":["agent.ask"],
                "capabilities":{"harness":"codex","model":"fixture-model","slots":2}}],
     "directory":[
       {"id":"dir-1","owner":"u-bo","handle":"fixture-bo","device":"d-1","kind":"agent","name":"bo-agent",
        "actions":\#(agentActions),"grantedActions":["agent.ask","thread.read","thread.comment"],
        "capabilities":{"harness":"codex","model":"fixture-model","slots":2,"tools":["gh"],"environments":["gpu"]}},
       {"id":"dir-2","owner":"u-cy","handle":"fixture-cy","kind":"repo","name":"cy-docs","actions":["issue.read"],"grantedActions":null},
       {"name":"no id, so it is skipped"}]}}
    """#)

    /// The same account after `resource-add` enrolled a worker.
    static let statusWithWorker = MultiplayerFixture.output(#"""
    {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada",
     "friends":[{"handle":"fixture-bo"}],
     "resources":[{"id":"\#(MultiplayerShareTarget.agent(id: "w-7", name: "tests").resourceID)","name":"tests","kind":"agent",
                   "actions":["agent.ask","agent.status","thread.comment","thread.read"]}]}}
    """#)

    static let approvals = MultiplayerFixture.output(#"""
    {"ok":true,"data":{"approvals":[
      {"id":"ap-1","peer":"fixture-bo","resource":"res-1","action":"git.push","summary":"{\"text\":\"push the fix\"}",
       "arrived":"2026-11-23T11:58:00Z","expires":"2026-11-24T11:58:00Z"},
      {"peer":"no id"}]}}
    """#)

    static let empty = MultiplayerFixture.output(#"{"ok":true,"data":{}}"#)
}

@Suite struct MultiplayerShareContractTests {
    @Test func tracksTheNewVerbs() {
        #expect(Set(["approvals", "approve", "deny", "audit", "send", "sent", "handoffs", "thread", "comment",
                     "apply-artifact", "relay"]).isSubset(of: Set(MultiplayerVerb.allCases.map(\.rawValue))))
        #expect(MultiplayerVerb.applyArtifact.arguments == ["tray", "apply-artifact"])
    }

    @Test func aStatusCarriesTheDirectoryWithOfferedAndGrantedActions() throws {
        let status = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: MultiplayerShareFixture.status))
        let entries = status.directoryEntries
        // A row without an ID is dropped; the rest still list.
        #expect(entries.map(\.id) == ["dir-1", "dir-2"])
        let agent = entries[0]
        // The owner is the handle, never the account ID.
        #expect(agent.owner == "fixture-bo" && agent.kind == "agent")
        #expect(agent.granted == ["agent.ask", "thread.read", "thread.comment"])
        #expect(agent.canConsult && !agent.canHandOff)
        // Thread and tracking actions ride along with another; they are never asked for alone.
        #expect(agent.requestable == ["agent.handoff"])
        #expect(agent.capabilities?.headline == "Codex, fixture-model, 2 slots")
        #expect(agent.capabilities?.tags == ["gh", "gpu"])
        #expect(entries[1].granted.isEmpty && entries[1].requestable == ["issue.read"] && entries[1].capabilities == nil)
        #expect(status.shared.first?.capabilities?.harness == "codex")
    }

    @Test func withoutADirectoryTheSharedListIsShownAsGranted() throws {
        let status = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: MultiplayerFixture.status))
        #expect(status.directory == nil)
        let entry = try #require(status.directoryEntries.first)
        #expect(entry.id == "sh-1" && entry.offered == ["agent.ask"] && entry.granted == ["agent.ask"])
        #expect(entry.requestable.isEmpty)
    }

    @Test func aDirectoryRowReadsOlderFieldNames() throws {
        let entry = try MultiplayerShareFixture.data(MultiplayerDirectoryEntry.self,
            #"{"id":"r","owner":"fixture-dee","offered":["agent.ask"],"granted":["agent.ask"],"capabilities":{}}"#)
        #expect(entry.owner == "fixture-dee" && entry.name == "r" && entry.offered == ["agent.ask"])
        #expect(entry.granted == ["agent.ask"] && entry.capabilities == nil)
    }

    @Test func decodesApprovalsAndReadsTheRequestText() throws {
        let list = try #require(try MultiplayerEnvelope.decode(MultiplayerApprovalList.self, from: MultiplayerShareFixture.approvals))
        #expect(list.approvals.map(\.id) == ["ap-1"])
        let approval = list.approvals[0]
        #expect(approval.peer == "fixture-bo" && approval.action == "git.push")
        #expect(approval.request == "push the fix")
        #expect(approval.wants == "wants to push the collaboration branch")
        #expect(approval.arrived == MultiplayerTime.parse("2026-11-23T11:58:00Z"))
        // Go's zero time is "not set"; a summary that isn't JSON is shown as it is.
        let bare = try MultiplayerShareFixture.data(MultiplayerApproval.self,
            #"{"id":"ap-2","summary":"plain words","arrived":"0001-01-01T00:00:00Z"}"#)
        #expect(bare.arrived == nil && bare.request == "plain words" && bare.peer.isEmpty)
    }

    @Test func decodesTheAuditLog() throws {
        let log = try MultiplayerShareFixture.data(MultiplayerAuditLog.self, #"""
        {"entries":[{"request":"rq-1","peer":"fixture-bo","resource":"res-1","action":"agent.ask",
                     "started":"2026-11-23T11:00:00Z","ended":"2026-11-23T11:02:00Z","outcome":"ok","tokens":18400,"summary":"Answered."},
                    {"request":"rq-2","outcome":"budget_exhausted","tokens":-4}]}
        """#)
        #expect(log.entries.count == 2)
        #expect(log.entries[0].outcomeTitle == "Done" && log.entries[0].tokensTitle == "18,400 tokens")
        #expect(log.entries[1].outcomeTitle == "Budget used up" && log.entries[1].outcomeTone == .failure)
        #expect(log.entries[1].tokens == 0 && log.entries[1].tokensTitle == nil)
        let caption = MultiplayerAuditPage.caption(log.entries[0], resourceName: { _ in "relay" },
                                                   now: MultiplayerFixtureClock.start)
        #expect(caption.hasPrefix("relay, ") && caption.hasSuffix("2 min, 18,400 tokens"))
        #expect(try MultiplayerShareFixture.data(MultiplayerAuditLog.self, "{}").entries.isEmpty)
    }

    @Test func decodesAccessRequestsFromTheRelayOrABareList() throws {
        let wrapped = try MultiplayerShareFixture.data(MultiplayerAccessRequestList.self, #"""
        {"requests":[{"id":"ar-1","resource":"res-1","owner":"u-ada","ownerHandle":"fixture-ada","requester":"u-bo",
                      "requesterHandle":"fixture-bo","actions":["issue.read","issue.comment"],"note":" triage ","status":"pending",
                      "createdAt":"2026-11-23T10:00:00Z"},
                     {"resource":"no id"}]}
        """#)
        let request = try #require(wrapped.requests.first)
        #expect(wrapped.requests.count == 1)
        #expect(request.owner == "fixture-ada" && request.requester == "fixture-bo" && request.isPending)
        #expect(request.note == "triage" && request.actionsTitle == "Read issues and Comment on issues")
        let bare = try MultiplayerShareFixture.data(MultiplayerAccessRequestList.self,
            #"[{"id":"ar-2","resource":"res-2","owner":"fixture-ada","from":"fixture-cy","status":"granted"}]"#)
        #expect(bare.requests.first?.requester == "fixture-cy" && bare.requests.first?.statusTitle == "Granted")
    }

    @Test func decodesHandoffsTheirReportsAndArtifacts() throws {
        let list = try MultiplayerShareFixture.data(MultiplayerSentList.self, #"""
        {"handoffs":[
          {"request":"rq-2","child":"c-2","resource":"dir-1","action":"agent.handoff","title":"Add a retry","at":"2026-11-23T11:50:00Z","status":"pending","value":null},
          {"request":"rq-1","resource":"dir-1","action":"agent.handoff","title":"Fix the test","status":"ok","value":{"run":"run-1","worker":"w-1"}}]}
        """#)
        #expect(list.rows.map(\.request) == ["rq-2", "rq-1"])
        #expect(list.rows[0].run == nil && !list.rows[0].isSettled && list.rows[0].refusal?.hasPrefix("Waiting for the owner") == true)
        #expect(list.rows[1].run == "run-1" && list.rows[1].succeeded && list.rows[1].refusal == nil)

        let result = try MultiplayerShareFixture.data(MultiplayerSentRequest.self, #"""
        {"request":"rq-9","id":"c-9","status":"ok","value":{"run":"run-1","state":"completed","summary":"40 runs pass.",
         "updatedAt":"2026-11-23T11:59:00Z","artifacts":[
           {"kind":"report","name":"Result","content":"## bo-agent\n\nDone."},
           {"kind":"patch","name":"fix.patch","content":"--- a\n+++ b\n"},
           {"kind":"branch","name":"handoff/fix"},
           {"name":"no kind"}]}}
        """#)
        let report = try #require(MultiplayerHandoffReport(reply: result, isResult: true))
        #expect(report.request == "rq-9" && report.state == "completed" && report.report == "## bo-agent\n\nDone.")
        #expect(report.artifacts.map(\.kind) == ["report", "patch", "branch"])
        // A patch is applied, a report saved, and a branch is the person's own fetch.
        #expect(report.artifacts.map(\.applyTitle) == ["Save…", "Apply…", nil])
        #expect(MultiplayerRequestState.title(report.state) == "Done")

        let denied = try MultiplayerShareFixture.data(MultiplayerSentRequest.self, #"{"request":"rq-3","status":"denied"}"#)
        #expect(MultiplayerHandoffReport(reply: denied, isResult: false) == nil)
        #expect(denied.refusal == "The owner denied this request.")
        let spent = try MultiplayerShareFixture.data(MultiplayerSentRequest.self, #"{"request":"rq-4","status":"budget_exhausted"}"#)
        #expect(spent.refusal?.contains("token budget") == true)
    }

    @Test func decodesAThreadAndAnAnswer() throws {
        let thread = try MultiplayerShareFixture.data(MultiplayerThread.self, #"""
        {"request":"rq-1","comments":[
          {"id":"cm-1","author":"fixture-ada","authorKind":"person","at":"2026-11-23T11:00:00Z","text":"Logs attached."},
          {"id":"cm-2","author":"bo-agent","authorKind":"agent","at":"2026-11-23T11:20:00Z","text":"Reproduced."}]}
        """#)
        #expect(thread.comments.map(\.id) == ["cm-1", "cm-2"])
        #expect(!thread.comments[0].isAgent && thread.comments[1].isAgent)
        #expect(try MultiplayerShareFixture.data(MultiplayerThread.self, "{}").comments.isEmpty)
        // A Consult's answer is its text, whatever else the result carries.
        let answer = try MultiplayerShareFixture.data(MultiplayerJSON.self, #"{"text":"Look at the lease.","tokens":1200}"#)
        #expect(answer.readable == "Look at the lease.")
        #expect(MultiplayerJSON.string("plain").readable == "plain")
    }

    @Test func activityNamesApprovalsAndAccessRequests() {
        let pending = MultiplayerActivityEvent(server: "s-home", seq: 0, kind: "approval.pending", actor: "fixture-bo",
                                               resource: "res-1", detail: "agent.ask")
        #expect(pending.sentence == "fixture-bo wants to send prompts to the worker. Approve or deny it in the tray")
        let asked = MultiplayerActivityEvent(server: "s-home", seq: 7, kind: "access.requested", actor: "fixture-cy")
        #expect(asked.line(on: "home") == "fixture-cy asked for access on home")
        // The device agent's own events have no sequence, so two of them are still two rows.
        let other = MultiplayerActivityEvent(server: "s-home", seq: 0, kind: "approval.pending", actor: "fixture-cy",
                                             resource: "res-1", detail: "agent.ask")
        #expect(pending.id != other.id && asked.id == "s-home#7")
    }
}

@Suite struct MultiplayerGrantSheetTests {
    @Test func theSheetStartsOnAskEachTimeForOneDayAndTenUses() {
        let draft = MultiplayerShareDraft()
        #expect(draft.approval == .ask && draft.expiry == .day && draft.uses == .ten && draft.attribution == .owner)
        #expect(draft.budgetTokens == 0 && draft.budgetProblem == nil && draft.budgetTitle == "No token limit")
        #expect(draft.limitsTitle == "Up to 10 uses, for 1 day, no token limit")
    }

    @Test func expiryPresetsAreAnHourADayAndAWeek() {
        #expect(MultiplayerShareExpiry.allCases.map(\.title) == ["1 hour", "1 day", "1 week"])
        #expect(MultiplayerShareExpiry.allCases.map(\.interval) == [3600, 86_400, 604_800])
        var draft = MultiplayerShareDraft()
        let now = MultiplayerFixtureClock.start
        for expiry in MultiplayerShareExpiry.allCases {
            draft.expiry = expiry
            #expect(draft.limits(now: now).expiresAt == now.addingTimeInterval(expiry.interval))
        }
    }

    @Test func usePresetsAreOneTenAndTheLargestCountForUnlimited() {
        #expect(MultiplayerShareUses.allCases.map(\.title) == ["1 use", "10 uses", "Unlimited"])
        #expect(MultiplayerShareUses.allCases.map(\.count) == [1, 10, 1_000_000])
        var draft = MultiplayerShareDraft()
        draft.uses = .unlimited
        #expect(draft.limitsTitle.hasPrefix("Unlimited uses, "))
    }

    @Test func theTokenBudgetIsAWholeNumberOrEmpty() {
        var draft = MultiplayerShareDraft()
        draft.budgetText = " 200,000 "
        #expect(draft.budgetTokens == 200_000 && draft.budgetTitle == "200,000 tokens")
        for bad in ["-1", "1.5", "lots", "99999999999"] {
            draft.budgetText = bad
            #expect(draft.budgetTokens == nil && draft.budgetProblem != nil)
            #expect(draft.grants(kind: "agent", offered: ["agent.ask"], now: MultiplayerFixtureClock.start).isEmpty)
        }
    }

    @Test func consultAndHandOffBringTheirThreadAndTrackingActions() {
        #expect(MultiplayerSharePolicy.companions(for: ["agent.ask"]) == ["thread.read", "thread.comment"])
        #expect(MultiplayerSharePolicy.companions(for: ["agent.handoff"])
                == ["thread.read", "thread.comment", "agent.status", "agent.result"])
        #expect(MultiplayerSharePolicy.companions(for: ["git.push"]).isEmpty)
        let offered = ["agent.ask", "agent.handoff", "agent.result", "agent.status", "thread.comment", "thread.read"]
        #expect(MultiplayerSharePolicy.granted(chosen: ["agent.ask"], offered: offered)
                == ["agent.ask", "thread.comment", "thread.read"])
        #expect(MultiplayerSharePolicy.granted(chosen: ["agent.handoff"], offered: offered)
                == ["agent.handoff", "agent.result", "agent.status", "thread.comment", "thread.read"])
        // Nothing the resource doesn't list is ever granted.
        #expect(MultiplayerSharePolicy.granted(chosen: ["agent.ask"], offered: ["agent.ask"]) == ["agent.ask"])
    }

    @Test func eachGrantCarriesThePolicyAsRealNumbers() throws {
        var draft = MultiplayerShareDraft(server: "s-home", handle: "fixture-bo", resourceID: "res-2")
        draft.actions = ["agent.ask"]
        draft.approval = .auto
        draft.expiry = .hour
        draft.uses = .one
        draft.budgetText = "50000"
        draft.attribution = .requester
        let grants = draft.grants(kind: "agent", offered: ["agent.ask", "thread.read", "thread.comment"],
                                  now: MultiplayerFixtureClock.start)
        #expect(grants.count == 3)
        let raw = String(decoding: try MultiplayerClient.encode(grants[0]), as: UTF8.self)
        #expect(raw == #"{"approval":"auto","attribution":"requester","budgetTokens":50000,"capability":"agent.ask","expiresAt":"2026-11-23T13:00:00Z","handle":"fixture-bo","kind":"agent","maxUses":1,"resource":"res-2"}"#)
        // Without a friend or a resource nothing is sent.
        draft.handle = ""
        #expect(draft.grants(kind: "agent", offered: ["agent.ask"], now: MultiplayerFixtureClock.start).isEmpty)
    }

    @Test func aCockpitTargetNamesTheSameResourceEveryTime() {
        let worker = MultiplayerShareTarget.agent(id: "w-7", name: "tests")
        #expect(worker.resourceID == MultiplayerShareTarget.agent(id: "w-7", name: "renamed").resourceID)
        #expect(worker.resourceID != MultiplayerShareTarget.repo(path: "w-7", name: "tests").resourceID)
        #expect(worker.resourceID.hasPrefix("res-") && worker.resourceID.count == 24)
        #expect(worker.kind == "agent" && MultiplayerShareTarget.repo(path: "/tmp/relay", name: "relay").target == "/tmp/relay")
    }
}

@Suite struct MultiplayerRequestTests {
    @Test func aConsultSendsItsPromptAndFilesAsNestedJSON() async throws {
        let helper = ScriptedMultiplayerHelper([.send: [MultiplayerFixture.output(
            #"{"ok":true,"data":{"request":"rq-1","id":"c-1","status":"ok","value":{"text":"Fixture answer."}}}"#)]])
        var draft = MultiplayerConsultDraft(prompt: "  Why does it flake?\nSecond line  ")
        draft.context = [MultiplayerContextItem(name: "ci.log", content: "line \"one\"\n")]
        #expect(draft.canSend && draft.title == "Why does it flake?")
        let reply = try await MultiplayerClient(helper: helper, server: "s-home")
            .send(resource: "dir-1", action: "agent.ask", payload: draft.payload, name: draft.title)
        #expect(reply.request == "rq-1" && reply.succeeded && reply.value?.readable == "Fixture answer.")
        let sent = try MultiplayerShareFixture.object(helper.lastRawInput(.send))
        #expect(sent["server"] == .string("s-home") && sent["capability"] == .string("agent.ask"))
        #expect(sent["name"] == .string("Why does it flake?"))
        #expect(sent["payload"] == .object(["text": .string("Why does it flake?\nSecond line"),
                                            "context": .array([.object(["name": .string("ci.log"), "content": .string("line \"one\"\n")])])]))
    }

    @Test func contextIsBoundedAndOnlySendMayCarryIt() throws {
        let big = MultiplayerContextItem(name: "big.log", content: String(repeating: "x", count: 80 * 1024))
        var draft = MultiplayerConsultDraft(prompt: "Read this")
        draft.context = [big]
        #expect(draft.problem == nil)
        let fields: [String: MultiplayerPayloadValue] = ["resource": "dir-1", "capability": "agent.ask", "payload": .json(draft.payload)]
        #expect(try MultiplayerClient.encode(fields, limit: MultiplayerClient.inputLimit(for: .send)).count > 80 * 1024)
        #expect(throws: MultiplayerFailure.self) { try MultiplayerClient.encode(fields, limit: MultiplayerClient.inputLimit(for: .comment)) }
        draft.context.append(MultiplayerContextItem(name: "more.log", content: String(repeating: "y", count: 12 * 1024)))
        #expect(draft.problem != nil && !draft.canSend)
        draft.context = (0..<17).map { MultiplayerContextItem(name: "f\($0)", content: "") }
        #expect(draft.problem == "Attach at most 16 files.")
        // The same file attached twice is one item, with the newer text.
        let merged = MultiplayerContextBundle.adding([MultiplayerContextItem(name: "a", content: "new")],
                                                     to: [MultiplayerContextItem(name: "a", content: "old"), big])
        #expect(merged.map(\.name) == ["a", "big.log"] && merged[0].content == "new")
    }

    @Test func aHandOffNeedsATitleAndATask() {
        var draft = MultiplayerHandoffDraft()
        #expect(!draft.canSend)
        draft.title = "Fix the test"
        draft.task = " Make it pass. "
        #expect(draft.canSend)
        #expect(draft.payload == .object(["title": .string("Fix the test"), "task": .string("Make it pass.")]))
    }

    @Test func accessRequestsGoThroughTheRelayVerb() async throws {
        let helper = ScriptedMultiplayerHelper([.relay: [MultiplayerShareFixture.empty], .applyArtifact: [MultiplayerShareFixture.empty]])
        let client = MultiplayerClient(helper: helper, server: "s-home")
        let draft = MultiplayerAccessDraft(actions: ["issue.read", "issue.comment"], note: " triage ")
        try await client.requestAccess(draft.body(resource: "res-1"))
        let sent = try MultiplayerShareFixture.object(helper.lastRawInput(.relay))
        #expect(sent["method"] == .string("POST") && sent["path"] == .string("/v1/access-requests"))
        #expect(sent["body"] == .object(["resource": .string("res-1"), "note": .string("triage"),
                                         "actions": .array([.string("issue.comment"), .string("issue.read")])]))
        try await client.removeAccessRequest(id: "ar/1 x")
        #expect(helper.lastInput(.relay) == ["server": "s-home", "method": "DELETE", "path": "/v1/access-requests/ar%2F1%20x"])
        try await client.applyArtifact(request: "rq-9", artifact: 1, checkout: "/tmp/relay")
        #expect(helper.lastRawInput(.applyArtifact) == #"{"artifact":1,"checkout":"\/tmp\/relay","request":"rq-9","server":"s-home"}"#)
    }
}

@MainActor @Suite struct MultiplayerShareModelTests {
    static func model(_ replies: [MultiplayerVerb: [MultiplayerHelperOutput]]) -> (MultiplayerModel, ScriptedMultiplayerHelper) {
        var all = replies
        all[.servers] = all[.servers] ?? [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)]
        all[.status] = all[.status] ?? [MultiplayerShareFixture.status]
        let helper = ScriptedMultiplayerHelper(all)
        return (MultiplayerServerFixture.model(helper), helper)
    }

    @Test func approvalsWaitInNeedsYouUntilApprovedOrDenied() async throws {
        let (model, helper) = Self.model([.approvals: [MultiplayerShareFixture.approvals],
                                          .approve: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        let pending = try #require(model.share.pendingApprovals.first)
        #expect(pending.server == "s-home" && pending.item.id == "ap-1")
        #expect(model.tally.needsYou == 2)    // the friend request and the approval

        model.share.open(.approval("ap-1"), on: "s-home")
        #expect(model.route == .share("s-home", .approval("ap-1")) && model.share.backTitle == "Network")
        await model.share.decide(pending.item, on: "s-home", approve: true)?.value
        #expect(helper.lastInput(.approve) == ["id": "ap-1", "server": "s-home"])
        #expect(model.route == .home && model.notice == "Approved. It runs on this Mac now.")
        model.close()
    }

    @Test func aRefusedDenyKeepsTheRequestWaiting() async throws {
        let (model, _) = Self.model([.approvals: [MultiplayerShareFixture.approvals],
                                     .deny: [MultiplayerFixture.output(#"{"ok":false,"error":"no such request"}"#)]])
        model.open()
        await model.settle()
        let pending = try #require(model.share.pendingApprovals.first)
        await model.share.decide(pending.item, on: "s-home", approve: false)?.value
        #expect(model.failure == "Couldn’t deny the request. no such request")
        #expect(model.share.approvals["s-home"]?.count == 1)
        model.close()
    }

    @Test func theSheetGrantsTheChosenActionsWithThePolicy() async throws {
        let (model, helper) = Self.model([.grant: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        model.share(with: "fixture-bo", on: "s-home")
        #expect(model.route == .share("s-home", .grant))
        // One resource, so it is chosen; its two actions still wait for the owner.
        #expect(model.share.grantDraft.resourceID == "res-1" && model.share.grantDraft.actions.isEmpty)
        #expect(!model.share.canGrant && model.share.grantHint == "Choose at least one action.")
        model.share.toggleGrantAction("git.push")
        model.share.grantDraft.uses = .unlimited
        model.share.grantDraft.budgetText = "1000"
        #expect(model.share.canGrant && model.share.grantCompanions.isEmpty)
        await model.share.confirmGrant()?.value
        #expect(helper.count(.grant) == 1 && helper.count(.resourceAdd) == 0)
        let sent = try MultiplayerShareFixture.object(helper.lastRawInput(.grant))
        #expect(sent["capability"] == .string("git.push") && sent["handle"] == .string("fixture-bo"))
        #expect(sent["approval"] == .string("ask") && sent["attribution"] == .string("owner"))
        #expect(sent["maxUses"] == .number(1_000_000) && sent["budgetTokens"] == .number(1000))
        #expect(model.route == .home && model.notice?.contains("Each use waits for your approval.") == true)
        model.close()
    }

    @Test func sharingAWorkerFromTheCockpitAddsItThenGrantsWhatItReallyOffers() async throws {
        let (model, helper) = Self.model([.status: [MultiplayerShareFixture.status, MultiplayerShareFixture.statusWithWorker],
                                          .resourceAdd: [MultiplayerShareFixture.empty], .grant: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        let worker = MultiplayerShareTarget.agent(id: "w-7", name: "tests")
        #expect(model.share.startShare(worker))
        #expect(model.route == .share("s-home", .grant))
        let resource = try #require(model.share.grantResource)
        #expect(resource.isNew && resource.id == worker.resourceID && resource.choices == ["agent.ask", "agent.handoff"])
        model.share.grantDraft.handle = "fixture-bo"
        model.share.toggleGrantAction("agent.ask")
        #expect(model.share.grantCompanions == ["thread.read", "thread.comment"])
        await model.share.confirmGrant()?.value
        #expect(model.failure == nil)
        let added = try #require(helper.lastInput(.resourceAdd))
        #expect(added == ["id": worker.resourceID, "name": "tests", "kind": "agent", "target": "w-7", "server": "s-home"])
        // The worker lists Consult and the thread actions, so exactly those three are granted.
        #expect(helper.count(.grant) == 3)
        #expect(Array(helper.verbs.drop { $0 != .resourceAdd }.prefix(2)) == [.resourceAdd, .status])
        model.close()
    }

    @Test func aHandOffIsListedAndItsResultIsReadBeforeAnythingIsApplied() async throws {
        let handoff = #"{"request":"rq-1","id":"c-1","status":"ok","value":{"run":"run-1","worker":"w-1"}}"#
        let result = #"{"request":"rq-9","id":"c-9","status":"ok","value":{"run":"run-1","state":"completed","summary":"Done.","artifacts":[{"kind":"patch","name":"fix.patch","content":"--- a\n"}]}}"#
        let (model, helper) = Self.model([
            .send: [MultiplayerFixture.output(#"{"ok":true,"data":\#(handoff)}"#), MultiplayerFixture.output(#"{"ok":true,"data":\#(result)}"#)],
            .applyArtifact: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        model.share.startHandoff("dir-1", on: "s-home")
        model.share.handoffDraft.title = "Fix the test"
        #expect(!model.share.canSendHandoff)
        model.share.handoffDraft.task = "Make it pass."
        await model.share.sendHandoff()?.value
        #expect(model.route == .share("s-home", .handoffDetail(request: "rq-1")))
        let row = try #require(model.share.handoff("rq-1", on: "s-home"))
        #expect(row.run == "run-1" && model.share.handoffState(row).title == "Started")
        #expect(model.share.handoffTarget(row, on: "s-home") == "fixture-bo’s bo-agent")
        // No result yet, so there is nothing to apply.
        #expect(model.share.apply(artifact: 0, of: row, on: "s-home", checkout: "/tmp/relay") == nil)

        await model.share.check(row, on: "s-home", result: true)?.value
        let sent = try MultiplayerShareFixture.object(helper.lastRawInput(.send))
        #expect(sent["capability"] == .string("agent.result") && sent["payload"] == .object(["run": .string("run-1")]))
        #expect(model.share.handoffState(row).title == "Done" && model.share.reports["rq-1"]?.artifacts.count == 1)
        // A relative path is never sent; the result's own request names the artifact.
        #expect(model.share.apply(artifact: 0, of: row, on: "s-home", checkout: "relay") == nil)
        await model.share.apply(artifact: 0, of: row, on: "s-home", checkout: "/tmp/relay")?.value
        #expect(helper.lastRawInput(.applyArtifact)?.contains(#""request":"rq-9""#) == true)
        model.close()
    }

    @Test func aConfirmationDoesNotFollowThePersonToTheNextPage() async {
        let (model, _) = Self.model([:])
        model.open()
        await model.settle()
        model.post(notice: "Profile saved.")
        model.openServer("s-home")
        #expect(model.notice == nil)
        model.close()
    }

    @Test func friendsOnlineCountsEachPersonOnceAndNotAway() async {
        let contacts = MultiplayerFixture.output(#"""
        {"ok":true,"data":{"contacts":[
          {"contactKey":"k-1","displayName":"Bo","rows":[{"server":"s-home","handle":"fixture-bo","presence":"busy"},
                                                        {"server":"s-studio","handle":"fixture-bo","presence":"online"}]},
          {"contactKey":"","rows":[{"server":"s-home","handle":"fixture-cy","presence":"away"}]},
          {"contactKey":"","rows":[{"server":"s-studio","handle":"fixture-dee","presence":"dnd"}]}]}}
        """#)
        let (model, _) = Self.model([.servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home, MultiplayerSocialFixture.studio)],
                                     .contacts: [contacts]])
        model.open()
        await model.settle()
        #expect(model.friendsAvailable == 1 && model.tally.friendsOnline == 1)
        // The device agent starts on Auto, and the header says so before the person has picked.
        #expect(model.effectivePresenceChoice == .auto)
        model.close()
    }
}
