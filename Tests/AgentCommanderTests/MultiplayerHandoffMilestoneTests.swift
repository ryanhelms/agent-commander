import Foundation
import Testing
@testable import AgentCommander

// A hand-off's Delivered, Accepted and Verified milestones, and the workspace inbox an owner
// offers (issue #231). Every handle, resource and run here is made up. No test reaches a network
// or the real helper.

@Suite struct MultiplayerHandoffMilestoneTests {
    private static func rows(_ json: String) throws -> [MultiplayerSentRequest] {
        try MultiplayerShareFixture.data(MultiplayerSentList.self, #"{"handoffs":[\#(json)]}"#).rows
    }

    private static func row(_ fields: String) throws -> MultiplayerSentRequest {
        try #require(try rows(#"{"request":"rq-1","resource":"dir-1","action":"agent.handoff","title":"Verify","status":"completed",\#(fields)}"#).first)
    }

    private static let delivered = #""deliveredAt":"2026-11-21T11:42:00.125Z""#
    private static let accepted = #""acceptedAt":"2026-11-21T11:42:02Z""#
    private static let verified = #""verifiedAt":"2026-11-21T11:42:03Z""#

    private static func outcomes(_ progress: MultiplayerHandoffProgress) -> [String] {
        progress.milestones.map { milestone in
            switch milestone.outcome {
            case .reached: "reached"
            case .pending: "pending"
            case .missed(let failed): failed ? "failed" : "missed"
            case .unrecorded: "unrecorded"
            }
        }
    }

    @Test func anOlderCompletedHandOffIsNeverVerified() throws {
        // What a device without milestones sends: a finished run and no timestamps.
        let row = try Self.row(#""state":"done","value":{"run":"run-1","state":"done"}"#)
        #expect(row.deliveredAt == nil && row.acceptedAt == nil && row.verifiedAt == nil)

        let listed = MultiplayerHandoffProgress(row: row)
        #expect(listed.title == "Started" && listed.tone == .working && listed.problem == nil)
        #expect(Self.outcomes(listed) == ["unrecorded", "unrecorded", "unrecorded"])

        let result = try MultiplayerShareFixture.data(MultiplayerSentRequest.self,
                                                      #"{"request":"rq-9","status":"ok","value":{"run":"run-1","state":"completed"}}"#)
        let read = MultiplayerHandoffProgress(row: row, report: try #require(MultiplayerHandoffReport(reply: result, isResult: true)))
        #expect(read.title == "Done" && read.tone == .working)
        #expect(read.milestones.allSatisfy { $0.lamp == .off && $0.word == "Not recorded" })
        #expect(read.milestones.last?.spoken(now: Date()) == "Verified, not recorded")
    }

    @Test func anOlderWaitingOrRefusedHandOffKeepsItsLabel() throws {
        let waiting = try #require(try Self.rows(#"{"request":"rq-2","status":"pending","value":null}"#).first)
        #expect(MultiplayerHandoffProgress(row: waiting).title == "Waiting")
        #expect(Self.outcomes(MultiplayerHandoffProgress(row: waiting)) == ["pending", "pending", "pending"])

        let denied = try #require(try Self.rows(#"{"request":"rq-3","status":"denied"}"#).first)
        let progress = MultiplayerHandoffProgress(row: denied)
        #expect(progress.title == "Denied" && progress.tone == .failure)
        #expect(Self.outcomes(progress) == ["failed", "failed", "failed"])
        #expect(progress.milestones.first?.word == "Not delivered")
    }

    @Test func aWorkspaceHandOffShowsTheLatestConfirmedStage() throws {
        let run = #""value":{"run":"handoff-1"}"#
        let stored = try Self.row(#""state":"delivered",\#(Self.delivered),\#(run)"#)
        // Fractional seconds are read.
        #expect(stored.deliveredAt != nil)
        var progress = MultiplayerHandoffProgress(row: stored)
        #expect(progress.title == "Delivered" && progress.tone == .attention)
        #expect(Self.outcomes(progress) == ["reached", "pending", "pending"])
        #expect(progress.milestones[1].spoken(now: Date()) == "Accepted, pending")

        progress = MultiplayerHandoffProgress(row: try Self.row(#""state":"accepted",\#(Self.delivered),\#(Self.accepted),\#(run)"#))
        #expect(progress.title == "Accepted" && progress.tone == .working)
        #expect(Self.outcomes(progress) == ["reached", "reached", "pending"])

        progress = MultiplayerHandoffProgress(row: try Self.row(#""state":"verified",\#(Self.delivered),\#(Self.accepted),\#(Self.verified),\#(run)"#))
        #expect(progress.title == "Verified" && progress.tone == .working && progress.problem == nil)
        #expect(Self.outcomes(progress) == ["reached", "reached", "reached"])
        #expect(progress.milestones.allSatisfy { $0.lamp == .on })
    }

    @Test func deliveryAloneNeverBecomesAcceptedOrVerified() throws {
        // A later stamp without the one before it proves nothing.
        let stray = try Self.row(#""state":"delivered",\#(Self.delivered),\#(Self.verified),"value":{"run":"handoff-1"}"#)
        #expect(MultiplayerHandoffProgress(row: stray).title == "Delivered")
        let orphan = try Self.row(#""state":"completed",\#(Self.accepted),\#(Self.verified),"value":{"run":"handoff-1","state":"completed"}"#)
        #expect(MultiplayerHandoffProgress(row: orphan).title == "Started")
        #expect(Self.outcomes(MultiplayerHandoffProgress(row: orphan)) == ["unrecorded", "unrecorded", "unrecorded"])
    }

    @Test func missingEvidenceAndFailuresStayVisible() throws {
        let stamps = "\(Self.delivered),\(Self.accepted)"
        let unverified = MultiplayerHandoffProgress(row: try Self.row(
            #""state":"unverified",\#(stamps),"value":{"run":"handoff-1","state":"unverified","failure":"missing_evidence"}"#))
        #expect(unverified.title == "Not verified" && unverified.tone == .attention)
        #expect(Self.outcomes(unverified) == ["reached", "reached", "missed"])
        #expect(unverified.milestones.last?.word == "Not verified" && unverified.milestones.last?.lamp == .busy)
        #expect(unverified.problem?.contains("nothing was sent to check") == true)

        let failed = MultiplayerHandoffProgress(row: try Self.row(
            #""state":"failed",\#(stamps),"value":{"run":"handoff-1","state":"failed","failure":"coordinator_stopped"}"#))
        #expect(failed.title == "Failed" && failed.tone == .failure)
        #expect(Self.outcomes(failed) == ["reached", "reached", "failed"])
        #expect(failed.milestones.last?.lamp == .error && failed.problem?.contains("stopped") == true)

        let expired = MultiplayerHandoffProgress(row: try Self.row(
            #""state":"expired",\#(Self.delivered),"value":{"run":"handoff-1","state":"expired","failure":"workspace_handoff_expired"}"#))
        #expect(expired.title == "Expired" && Self.outcomes(expired) == ["reached", "failed", "failed"])
        #expect(expired.milestones[1].word == "Not accepted")
    }

    @Test func aStatusCheckBringsItsMilestonesBeforeTheListIsReadAgain() throws {
        let row = try Self.row(#""state":"delivered",\#(Self.delivered),"value":{"run":"handoff-1"}"#)
        let reply = try MultiplayerShareFixture.data(MultiplayerSentRequest.self, #"""
        {"request":"rq-8","status":"completed",\#(Self.delivered),\#(Self.accepted),\#(Self.verified),
         "value":{"run":"handoff-1","state":"verified"}}
        """#)
        let report = try #require(MultiplayerHandoffReport(reply: reply, isResult: false))
        #expect(MultiplayerHandoffProgress(row: row, report: report).title == "Verified")
    }

    @Test func theOwnerOffersAWorkspaceInboxWithAutoStartOff() throws {
        var draft = MultiplayerResourceDraft()
        draft.kind = .agent
        draft.name = "relay inbox"
        draft.workspace = "ws-relay"
        #expect(draft.isWorkspaceInbox && !draft.autoStart && draft.targetLabel == "Anchor run ID")
        draft.target = "run 7"
        #expect(draft.command(directoryExists: { _ in false }) == nil)
        draft.target = "r-7f3a"
        let command = try #require(draft.command(directoryExists: { _ in false }))
        #expect(command == .addWorkspaceInbox(id: draft.id, name: "relay inbox", workspace: "ws-relay", anchor: "r-7f3a", autoStart: false))
        #expect(command.verb == .resourceAdd && MultiplayerVerb.resourceUpdate.arguments == ["tray", "resource-update"])
        let sent = try MultiplayerShareFixture.object(String(decoding: MultiplayerClient.encode(command.payload), as: UTF8.self))
        #expect(sent == ["id": .string(draft.id), "name": .string("relay inbox"), "kind": .string("agent"),
                         "workspace": .string("ws-relay"), "target": .string("r-7f3a"), "autoStart": .bool(false)])

        // A repository never carries a workspace, even if one was chosen before the kind changed.
        draft.kind = .repo
        draft.target = "/fixture/relay"
        #expect(draft.command(directoryExists: { _ in true }) == .addResource(id: draft.id, name: "relay inbox", kind: "repo", target: "/fixture/relay"))

        let toggle = MultiplayerCommand.setAutoStart(id: "res-1", name: "relay inbox", isOn: true)
        #expect(toggle.verb == .resourceUpdate && toggle.payload == ["id": .string("res-1"), "autoStart": .bool(true)])
    }

    @Test func aResourceReadsItsWorkspaceAndAutoStart() throws {
        let resources = try MultiplayerShareFixture.data([MultiplayerResource].self, #"""
        [{"id":"res-1","name":"worker","kind":"agent","actions":["agent.ask"]},
         {"id":"res-2","name":"relay inbox","kind":"agent","actions":["agent.handoff"],"workspace":"ws-relay"},
         {"id":"res-3","name":"docs inbox","kind":"agent","actions":["agent.handoff"],"workspace":"ws-docs","autoStart":true},
         {"id":"res-4","name":"stray","kind":"agent","actions":[],"autoStart":true}]
        """#)
        #expect(resources.map(\.isWorkspaceInbox) == [false, true, true, false])
        // Off unless the device says on, and never on without a workspace.
        #expect(resources.map(\.autoStart) == [false, false, true, false])
    }

    // MARK: Expected commit

    private static let head = "0123456789abcdef0123456789abcdef01234567"

    @Test func anExpectedCommitIsOptionalAndMustBeAFullHash() {
        var draft = MultiplayerHandoffDraft(title: "Verify", task: "Reach the commit.")
        // Without one the payload is what it always was.
        #expect(draft.canSend && draft.expectedHeadProblem == nil)
        #expect(draft.payload == .object(["title": .string("Verify"), "task": .string("Reach the commit.")]))

        for wrong in ["0123456", String(Self.head.dropLast()), Self.head + "0", "g" + String(Self.head.dropFirst()), "main"] {
            draft.expectedHead = wrong
            #expect(draft.expectedHeadProblem == "Enter the full 40-character commit hash." && !draft.canSend)
        }

        // Pasted with spaces or in capitals, it is sent as the device takes it.
        draft.expectedHead = " \(Self.head.uppercased())\n"
        #expect(draft.canSend && draft.expectedHeadProblem == nil)
        #expect(draft.payload == .object(["title": .string("Verify"), "task": .string("Reach the commit."),
                                          "expectedHead": .string(Self.head)]))

        // Any other recipient gets no commit, valid or not, and is never held up by one.
        #expect(draft.addressed(toWorkspaceInbox: true) == draft)
        draft.expectedHead = "main"
        let legacy = draft.addressed(toWorkspaceInbox: false)
        #expect(legacy.canSend && legacy.payload == .object(["title": .string("Verify"), "task": .string("Reach the commit.")]))
    }

    @Test func aFriendsEntryReadsItsWorkspace() throws {
        let directory = try MultiplayerShareFixture.data([MultiplayerDirectoryEntry].self, #"""
        [{"id":"dir-1","handle":"fixture-bo","kind":"agent","name":"bo-agent","actions":["agent.handoff"]},
         {"id":"dir-3","handle":"fixture-bo","kind":"agent","name":"relay inbox","actions":["agent.handoff"],"workspace":"ws-relay"}]
        """#)
        #expect(directory.map(\.isWorkspaceInbox) == [false, true])
        // The older `shared` list names it the same way.
        let shared = try MultiplayerShareFixture.data([MultiplayerShared].self, #"""
        [{"id":"dir-3","name":"relay inbox","kind":"agent","owner":"fixture-bo","actions":["agent.handoff"],"workspace":"ws-relay"}]
        """#)
        #expect(MultiplayerDirectoryEntry.entries(directory: nil, shared: shared).map(\.isWorkspaceInbox) == [true])
    }

    @MainActor @Test func onlyAWorkspaceInboxIsSentTheExpectedCommit() async throws {
        let status = MultiplayerFixture.output(#"""
        {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada","friends":[{"handle":"fixture-bo"}],
         "directory":[
           {"id":"dir-1","handle":"fixture-bo","kind":"agent","name":"bo-agent","actions":["agent.handoff"],"grantedActions":["agent.handoff"]},
           {"id":"dir-3","handle":"fixture-bo","kind":"agent","name":"relay inbox","actions":["agent.handoff"],
            "grantedActions":["agent.handoff"],"workspace":"ws-relay"}]}}
        """#)
        let reply = { (request: String) in
            MultiplayerFixture.output(#"{"ok":true,"data":{"request":"\#(request)","id":"c-1","status":"ok","value":{"run":"run-1"}}}"#)
        }
        let helper = ScriptedMultiplayerHelper([.servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
                                                .status: [status], .send: [reply("rq-1"), reply("rq-2")]])
        let model = MultiplayerServerFixture.model(helper)
        model.open()
        await model.settle()

        var draft = MultiplayerHandoffDraft(title: "Verify", task: "Reach the commit.")
        draft.expectedHead = Self.head
        await model.share.sendHandoff(draft, to: "dir-3", on: "s-home")?.value
        var sent = try MultiplayerShareFixture.object(helper.lastRawInput(.send))
        #expect(sent["resource"] == .string("dir-3") && sent["capability"] == .string("agent.handoff"))
        #expect(sent["payload"] == .object(["title": .string("Verify"), "task": .string("Reach the commit."),
                                            "expectedHead": .string(Self.head)]))

        // The same draft to a shared worker: the payload it always got.
        await model.share.sendHandoff(draft, to: "dir-1", on: "s-home")?.value
        sent = try MultiplayerShareFixture.object(helper.lastRawInput(.send))
        #expect(sent["resource"] == .string("dir-1"))
        #expect(sent["payload"] == .object(["title": .string("Verify"), "task": .string("Reach the commit.")]))

        // A hash that is not a commit never leaves this Mac.
        draft.expectedHead = "0123456"
        #expect(model.share.sendHandoff(draft, to: "dir-3", on: "s-home") == nil && helper.count(.send) == 2)
    }
}
