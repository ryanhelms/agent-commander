import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// What the Teams pages asked the tray for after increment 5 (design/demos/main-window-5/
// TRAY-REQUESTS.md, requests 1 to 8): a relay's members and devices, a workspace's combined view,
// owner handles, the commands on a host you lend, the policy's knowledge limits, editing and
// leaving a workspace, who stopped a refused claim, and a host with no Cancel.
// Every handle, device and path here is made up. No test reaches a network or the real helper.

private enum TeamsRosterFixture {
    static let home = MultiplayerTeamsFixture.home

    static let roster = #"""
    {"members":[{"handle":"fixture-ada","suspended":false,"admin":true},{"handle":"fixture-bo","suspended":true,"admin":false},
                {"handle":"","suspended":false,"admin":false},{"handle":""},"not a row",{"handle":"fixture-bo","suspended":false}],
     "devices":[{"id":"d-1","name":"","owner":"fixture-ada","online":true,"lastSeen":null},
                {"id":"d-2","name":"","owner":"fixture-bo","online":false,"lastSeen":"2026-11-25T18:04:11Z"},
                {"id":"d-3","owner":""},{"name":"no id"},{"id":"d-1","owner":"fixture-cy"}]}
    """#

    static let combined = #"""
    {"workspace":"ws-1","members":[
      {"handle":"fixture-ada","online":true,"workers":[
        {"id":"res-9","name":"tests","resource":"res-9","agent":"tests","harness":"claude","model":"opus","state":"working","branch":"",
         "checks":null,"claims":[{"id":"cl-2","kind":"card","key":"card-2","expiresAt":"2026-11-25T13:00:00Z"}]}]},
      {"handle":"fixture-bo","online":false,"workers":[
        {"id":"dir-b","name":"bo-agent","resource":"dir-b","agent":"","harness":"codex","model":"","state":"offline","branch":"","checks":null,"claims":[]},
        {"id":"fixture-bo/bo-agent","name":"bo-agent","resource":"","agent":"bo-agent","harness":"","model":"","state":"working","branch":"",
         "checks":{"passed":3,"failed":1,"running":2},"claims":[{"id":"cl-1","kind":"paths","key":"Sources/Relay"},{"kind":"issue"}]},
        {"name":"no id"}]},
      {"handle":"fixture-cy"},{"online":true}]}
    """#

    static let refused = #"={"ok":false,"error":"relay HTTP 409: overlapping claim held by fixture-bo/bo-agent","holder":"fixture-bo","agent":"bo-agent","claim":"cl-1"}"#

    @MainActor static func model() async -> (MultiplayerModel, RoutedMultiplayerHelper) {
        await MultiplayerTeamsFixture.model { call in
            switch call.verb {
            case .adminMembers: return call.input["server"] == .string("s-other") ? "!only a relay admin can list members and devices" : roster
            case .workspaceCombined:
                return call.input["workspace"] == .string("ws-1") ? combined : "!no workspace ws-9 in your groups"
            case .me: return #"{"admin":false,"mode":"invite","knowledgeDefault":"private","knowledgeWidest":"group"}"#
            case .workspaceEdit:
                return call.input["workspace"] == .string("ws-1") ? #"{"id":"ws-1","name":"Reconnect"}"# : "!only the owner can edit workspace ws-2"
            case .workspaceLeave:
                return call.input["workspace"] == .string("ws-1") ? "!the owner cannot leave workspace ws-1" : "{}"
            case .relay where call.method == "POST" && call.path == "/v1/workspaces/ws-1/claims":
                if call.body?["key"] == .string("Sources/Relay") { return refused }
                if call.body?["key"] == .string("#7") { return "!relay HTTP 403: forbidden" }
                return #"{"id":"cl-9"}"#
            default: return nil
            }
        }
    }
}

@Suite struct MultiplayerTeamsRosterContractTests {
    private func json(_ text: String) throws -> MultiplayerJSON { try MultiplayerLiveFixture.json(text) }

    @Test func tracksTheNewVerbs() {
        #expect(MultiplayerVerb.adminMembers.arguments == ["tray", "admin-members"])
        #expect(MultiplayerVerb.workspaceCombined.arguments == ["tray", "workspace-combined"])
        #expect(MultiplayerVerb.workspaceEdit.arguments == ["tray", "workspace-edit"])
        #expect(MultiplayerVerb.workspaceLeave.arguments == ["tray", "workspace-leave"])
    }

    @Test func aRosterKeepsEveryRowItCanReadAndDropsTheRest() throws {
        let roster = MultiplayerRelayRoster(try json(TeamsRosterFixture.roster))
        // A member with no handle yet is listed, under an ID of its own, and can't be moderated.
        #expect(roster.members.map(\.id) == ["fixture-ada", "fixture-bo", "#2", "#3"])
        #expect(roster.members[0] == MultiplayerRelayMember(handle: "fixture-ada", admin: true))
        #expect(roster.members[1].suspended && !roster.members[1].admin && roster.members[1].canModerate)
        #expect(roster.members[2].handle.isEmpty && !roster.members[2].canModerate)
        // The relay stores no device name: the ID stands in for it.
        #expect(roster.devices.map(\.id) == ["d-1", "d-2", "d-3"])
        #expect(roster.devices[0].online == true && roster.devices[0].lastSeen == nil && roster.devices[0].title == "d-1")
        #expect(roster.devices[1].online == false && roster.devices[1].lastSeen == MultiplayerTime.parse("2026-11-25T18:04:11Z"))
        #expect(roster.devices[2].online == nil && roster.devices[2].owner.isEmpty)
        #expect(roster.devices(of: "fixture-bo").map(\.id) == ["d-2"] && roster.devices(of: "").isEmpty)
        // A reply that isn't a roster reads as an empty one.
        #expect(MultiplayerRelayRoster(.null) == MultiplayerRelayRoster())
    }

    @Test func aCombinedViewReadsWorkersWithWhatTheRelayDoesNotKnowLeftEmpty() throws {
        let view = MultiplayerCombinedView(try json(TeamsRosterFixture.combined), workspace: "ws-1")
        #expect(view.workspace == "ws-1" && view.members.map(\.handle) == ["fixture-ada", "fixture-bo", "fixture-cy"])
        let mine = try #require(view.members[0].workers.first)
        #expect(mine.id == "res-9" && mine.isPublished && mine.harness == "claude" && mine.model == "opus")
        #expect(mine.knownState == .working && mine.stateTitle == "Working" && mine.branch.isEmpty)
        // No checks were reported: that is nil, never three zeros.
        #expect(mine.checks == nil)
        // A row's claim is held by the row's own member and agent.
        #expect(mine.claims == [MultiplayerClaim(id: "cl-2", kind: "card", key: "card-2", holder: "fixture-ada/tests",
                                                expiresAt: MultiplayerTime.parse("2026-11-25T13:00:00Z"))])
        // Another member's worker can appear twice: published, and as the holder of a claim.
        let theirs = view.members[1].workers
        #expect(theirs.map(\.id) == ["dir-b", "fixture-bo/bo-agent"] && view.members[1].online == false)
        #expect(theirs[0].knownState == .offline && theirs[0].claims.isEmpty && theirs[0].model.isEmpty)
        #expect(!theirs[1].isPublished && theirs[1].checks == MultiplayerWorkerChecks(passed: 3, failed: 1, running: 2))
        #expect(theirs[1].claims.map(\.id) == ["cl-1"] && theirs[1].claims[0].holder == "fixture-bo/bo-agent")
        #expect(view.members[2].workers.isEmpty && view.members[2].online == nil)
        #expect(view.workers.count == 3)
        // A state this build doesn't know is shown as sent.
        let odd = try #require(MultiplayerCombinedWorker(try json(#"{"id":"w","state":"paused"}"#), handle: "x"))
        #expect(odd.knownState == nil && odd.stateTitle == "paused" && odd.name == "w")
        #expect(MultiplayerCombinedView(.null, workspace: "ws-4") == MultiplayerCombinedView(workspace: "ws-4"))
    }

    @Test func workspacesAndKnowledgeItemsNameTheirOwner() throws {
        let workspace = try #require(MultiplayerWorkspace(try json(#"{"id":"ws-1","owner":"u-ada","ownerHandle":"fixture-ada","name":"Reconnect"}"#)))
        #expect(workspace.owner == "u-ada" && workspace.ownerHandle == "fixture-ada")
        #expect(workspace.isOwned(by: "fixture-ada") && !workspace.isOwned(by: "fixture-bo") && !workspace.isOwned(by: ""))
        let item = try #require(MultiplayerKnowledgeItem(try json(#"{"id":"kn-1","owner":"u-bo","ownerHandle":"fixture-bo","kind":"skill","name":"triage"}"#)))
        #expect(item.owner == "u-bo" && item.ownerHandle == "fixture-bo")
        // An older relay sends neither, and an owner may have no handle.
        #expect(MultiplayerWorkspace(try json(#"{"id":"ws-2"}"#))?.ownerHandle == "")
        #expect(MultiplayerKnowledgeItem(try json(#"{"id":"kn-2","ownerHandle":""}"#))?.ownerHandle == "")
        #expect(MultiplayerWorkspace(id: "ws-3", name: "x").ownerHandle.isEmpty && MultiplayerKnowledgeItem(id: "k", kind: "skill", name: "x").ownerHandle.isEmpty)
    }

    @Test func aHostYouLendListsItsEnrolledCommands() throws {
        let status = try JSONDecoder().decode(MultiplayerStatus.self, from: Data(#"""
        {"online":true,"signedIn":true,"handle":"fixture-ada","resources":[
          {"id":"res-h","name":"studio","kind":"host","actions":["host.run"],
           "capabilities":{"tools":["test","lint"],"commands":[{"name":"test","allowArgs":false,"environment":"macos"},{"name":"lint","allowArgs":true},{"allowArgs":true}]}},
          {"id":"res-e","name":"empty","kind":"host","actions":["host.run"],"capabilities":{"commands":[]}},
          {"id":"res-o","name":"older","kind":"host","actions":["host.run"]},
          {"id":"res-x","name":"odd","kind":"host","actions":["host.run"],"capabilities":"none"}]}
        """#.utf8))
        let host = try #require(status.resources.first)
        #expect(host.capabilities?.commands == [MultiplayerHostCommand(name: "test", environment: "macos"),
                                                MultiplayerHostCommand(name: "lint", allowArgs: true)])
        #expect(host.capabilities?.commandNames == ["test", "lint"] && host.capabilities?.allowsArguments("lint") == true)
        // No commands, none sent and an unreadable value all read as nothing to list.
        #expect(status.resources.dropFirst().map(\.capabilities) == [nil, nil, nil])
        #expect(status.resources.count == 4)
    }

    @Test func aMemberReadsThePolicysKnowledgeLimits() throws {
        func me(_ text: String) throws -> MultiplayerMe { try JSONDecoder().decode(MultiplayerMe.self, from: Data(text.utf8)) }
        let limited = try me(#"{"admin":false,"mode":"invite","knowledgeDefault":"private","knowledgeWidest":"group"}"#)
        #expect(limited.knowledgeDefaultScope == .private && limited.knowledgeWidestScope == .group)
        #expect(limited.allowsKnowledge(.group) == true && limited.allowsKnowledge(.friend) == true && limited.allowsKnowledge(.server) == false)
        // An older relay doesn't say, and a scope this build doesn't know isn't guessed at.
        let older = try me(#"{"admin":true,"mode":"open"}"#)
        #expect(older.knowledgeDefault.isEmpty && older.knowledgeWidestScope == nil && older.allowsKnowledge(.server) == nil)
        let odd = try me(#"{"admin":true,"knowledgeDefault":7,"knowledgeWidest":"galaxy"}"#)
        #expect(odd.knowledgeDefault.isEmpty && odd.knowledgeWidest == "galaxy" && odd.allowsKnowledge(.private) == nil)
        #expect(MultiplayerMe(admin: false, mode: "open") == (try me(#"{"admin":false,"mode":"open"}"#)))
    }

    @Test func aWorkspaceEditSendsOnlyWhatChanged() {
        let saved = MultiplayerWorkspace(id: "ws-1", name: "Reconnect", goal: "Survive renewals", repository: "github.com/example/relay",
                                         base: "main", integration: "queue")
        var edit = MultiplayerWorkspaceEdit(saved)
        #expect(edit.changes(from: saved).isEmpty && edit.hint == nil)
        edit.goal = "  Ship the relay "
        edit.integration = .pullRequest
        #expect(edit.changes(from: saved) == ["goal": "Ship the relay", "integration": "pull_request"])
        edit.name = "  "
        #expect(edit.hint == "Give it a name.")
    }

    @Test func aRefusedClaimNamesItsHolderInEitherShape() throws {
        // The device's envelope.
        let device = try #require(MultiplayerClaimRefusal(try json(#"{"ok":false,"error":"x","holder":"bob","agent":"w-7","claim":"d2"}"#)))
        #expect(device == MultiplayerClaimRefusal(holder: "bob", agent: "w-7", claim: "d2") && device.holderName == "bob/w-7")
        // The relay's own body.
        let relay = try #require(MultiplayerClaimRefusal(try json(#"{"error":"x","holder":"bob/w-7","holderHandle":"bob","claim":"d2"}"#)))
        #expect(relay == device)
        // Any other refusal names no one.
        #expect(MultiplayerClaimRefusal(try json(#"{"ok":false,"error":"relay HTTP 403: forbidden"}"#)) == nil)
        let claims = [MultiplayerClaim(id: "d1", kind: "issue", key: "3", holder: "amy/w-1"),
                      MultiplayerClaim(id: "d2", kind: "issue", key: "12", holder: "bob/w-7")]
        #expect(device.blocking(in: claims)?.id == "d2")
        // Without the claim's ID, the holder's one claim is the row.
        #expect(MultiplayerClaimRefusal(holder: "amy", agent: "w-1").blocking(in: claims)?.id == "d1")
        #expect(MultiplayerClaimRefusal(holder: "cy", agent: "w-1", claim: "gone").blocking(in: claims) == nil)
        // Only a refusal has fields to read.
        #expect(MultiplayerEnvelope.refusal(from: MultiplayerFixture.output(#"{"ok":true,"data":{"holder":"bob"}}"#)) == nil)
        #expect(MultiplayerEnvelope.refusal(from: MultiplayerFixture.output("not json")) == nil)
    }
}

@MainActor @Suite struct MultiplayerTeamsRosterModelTests {
    private let home = TeamsRosterFixture.home

    @Test func theNewReadsAreTheCallersAndLeaveTheTrayAlone() async throws {
        let (model, helper) = await TeamsRosterFixture.model()
        let teams = model.share.teams
        model.go(.hosting)

        let roster = try #require(await teams.loadRoster(on: home).value)
        #expect(roster.members.count == 4 && roster.devices.count == 3)
        #expect(helper.last(.adminMembers)?.input == .object(["server": .string(home)]))
        #expect(await teams.loadRoster(on: "s-other") == .failed("only a relay admin can list members and devices"))

        let view = try #require(await teams.loadCombinedView(of: "ws-1", on: home).value)
        #expect(view.members.count == 3)
        #expect(helper.last(.workspaceCombined)?.input == .object(["server": .string(home), "workspace": .string("ws-1")]))
        #expect(await teams.loadCombinedView(of: "ws-9", on: home) == .failed("no workspace ws-9 in your groups"))

        #expect(await teams.loadMe(on: home).value?.knowledgeWidestScope == .group)
        // The tray's own copy is what a member reads without asking.
        #expect(model.me[home]?.knowledgeDefaultScope == .private)

        #expect(model.route == .hosting && teams.policy == .loading && teams.cards == .loading)
        model.close()
    }

    @Test func rosterRowsAreModeratedByNameAndReadAgain() async throws {
        let (model, helper) = await TeamsRosterFixture.model()
        let roster = try #require(await model.share.teams.loadRoster(on: home).value)
        let member = roster.members[1], device = roster.devices[1]
        #expect(await model.setSuspended(false, member: member.handle, on: home).isDone)
        #expect(helper.relays("POST").last?.path == "/v1/admin/members/fixture-bo/unsuspend")
        #expect(await model.revokeDevice(device.id, on: home).isDone)
        #expect(helper.relays("DELETE").last?.path == "/v1/admin/devices/d-2")
        // A member with no handle can't be named.
        #expect(await model.setSuspended(true, member: roster.members[2].handle, on: home).reason == "Couldn’t suspend the member. Name the member first.")
        model.close()
    }

    @Test func editingAndLeavingAWorkspaceNameTheirTarget() async throws {
        let (model, helper) = await TeamsRosterFixture.model()
        let teams = model.share.teams
        model.go(.hosting)
        let saved = try #require(teams.workspace("ws-1", on: home))

        var edit = MultiplayerWorkspaceEdit(saved)
        #expect(await model.editWorkspace("ws-1", to: edit, on: home).reason == "Couldn’t save the workspace. Nothing changed yet.")
        #expect(helper.last(.workspaceEdit) == nil)
        edit.goal = "Ship the relay"
        let reads = helper.relays("GET").filter { $0.path == "/v1/workspaces" }.count
        let edited = await model.editWorkspace("ws-1", to: edit, on: home)
        #expect(edited == .done(id: "ws-1", server: home, message: "Saved Reconnect."))
        #expect(helper.last(.workspaceEdit)?.input == .object(["server": .string(home), "workspace": .string("ws-1"), "goal": .string("Ship the relay")]))
        // The server's workspaces are read again for every view of it.
        #expect(helper.relays("GET").filter { $0.path == "/v1/workspaces" }.count > reads)
        edit.name = ""
        #expect(await model.editWorkspace("ws-1", to: edit, on: home).reason == "Couldn’t save the workspace. Give it a name.")
        #expect(await model.editWorkspace("ws-9", to: edit, on: home).reason == "Couldn’t save the workspace. Commander can’t find this workspace any more.")

        #expect(await model.leaveWorkspace("ws-1", on: home).reason == "Couldn’t leave the workspace. The owner cannot leave workspace ws-1.")
        let left = await model.leaveWorkspace("ws-2", on: home)
        #expect(left == .done(id: "ws-2", server: home, message: "Left the workspace. Your claims in it ended."))
        #expect(helper.last(.workspaceLeave)?.input == .object(["server": .string(home), "workspace": .string("ws-2")]))
        #expect(await model.leaveWorkspace("ws-1", on: "s-gone").reason == "Couldn’t leave the workspace. Sign in to that server first.")

        #expect(model.route == .hosting && teams.workspaceDraft == MultiplayerWorkspaceDraft())
        model.close()
    }

    @Test func aRefusedClaimSaysWhoHoldsIt() async throws {
        let (model, _) = await TeamsRosterFixture.model()
        let teams = model.share.teams
        var draft = MultiplayerClaimDraft(kind: .paths, key: "Sources/Relay", agent: "tests")

        let held = await model.claimAnswer(draft, in: "ws-1", on: home)
        #expect(held.result.reason == "Couldn’t claim it. Overlapping claim held by fixture-bo/bo-agent.")
        #expect(held.refusal == MultiplayerClaimRefusal(holder: "fixture-bo", agent: "bo-agent", claim: "cl-1"))
        // The row to mark is in the workspace's claims.
        let claims = try #require(teams.workspace("ws-1", on: home)?.claims)
        #expect(held.refusal?.blocking(in: claims)?.key == "Sources/Relay")
        // The plain call reads the same refusal.
        #expect(await model.claim(draft, in: "ws-1", on: home) == held.result)

        // Another refusal, a claim not sent and a claim that was made name no one.
        draft.kind = .issue
        draft.key = "#7"
        let forbidden = await model.claimAnswer(draft, in: "ws-1", on: home)
        #expect(forbidden.result.reason?.hasPrefix("Couldn’t claim it.") == true && !forbidden.result.isDone && forbidden.refusal == nil)
        draft.key = ""
        #expect(await model.claimAnswer(draft, in: "ws-1", on: home) == MultiplayerClaimAnswer(result: .failed(id: "", server: home, reason: "Couldn’t claim it. Say what to claim.")))
        draft.key = "#8"
        let made = await model.claimAnswer(draft, in: "ws-1", on: home)
        #expect(made.result.isDone && made.result.id == "cl-9" && made.refusal == nil)
        model.close()
    }

    /// Request 8: a page that is a host's home has nothing to close.
    @Test func aHostWithNoCancelDrawsNone() async throws {
        let (model, _) = await TeamsRosterFixture.model()
        func buttons(_ host: some View) async throws -> [String] {
            let nodes = try await MultiplayerAX.nodes(of: host.environment(\.theme, .console)) { _ in }
            return nodes.filter { $0.role == "AXButton" }.map(\.label)
        }
        await model.settle()
        let closing = try await buttons(MultiplayerPolicyHost(model: model, server: home, scrolls: false, onCancel: {}, onFinish: { _ in }))
        #expect(closing.contains("Cancel") && closing.contains("Save policy"))
        let atHome = try await buttons(MultiplayerPolicyHost(model: model, server: home, scrolls: false, onFinish: { _ in }))
        #expect(!atHome.contains("Cancel") && atHome.contains("Save policy"))
        // The same holds for the other hosts.
        let workspace = try await buttons(MultiplayerWorkspaceHost(model: model, server: home, scrolls: false, onFinish: { _ in }))
        #expect(!workspace.contains("Cancel") && workspace.contains("Create workspace"))
        let invite = try await buttons(MultiplayerInviteHost(model: model, server: home, scrolls: false, onFinish: { _ in }))
        #expect(!invite.contains("Cancel") && !invite.contains("Close"))
        model.close()
    }
}

/// The review fixture answers each of the new calls, so the window can be checked against it.
@MainActor @Suite struct MultiplayerTeamsRosterFixtureTests {
    private let home = MultiplayerRemoteTests.home

    @Test func theFixtureListsMembersDevicesAndTheCombinedView() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("roster")
        let teams = model.share.teams

        var roster = try #require(await teams.loadRoster(on: home).value)
        #expect(roster.members.map(\.handle) == ["fixture-jonas", "fixture-mei", "fixture-noor", "fixture-ryan", "fixture-sam"])
        #expect(roster.members.filter(\.admin).map(\.handle) == ["fixture-ryan"] && !roster.members.contains(where: \.suspended))
        #expect(roster.devices.count == 6 && roster.devices.allSatisfy { $0.name.isEmpty })
        let away = try #require(roster.devices.first { $0.id == "d-mei" })
        #expect(away.online == false && away.lastSeen != nil)
        // Suspending and revoking from a row show in the next read.
        #expect(await model.setSuspended(true, member: "fixture-sam", on: home).isDone)
        #expect(await model.revokeDevice("d-mei", on: home).isDone)
        roster = try #require(await teams.loadRoster(on: home).value)
        #expect(roster.members.first { $0.handle == "fixture-sam" }?.suspended == true)
        #expect(roster.devices.count == 5 && !roster.devices.contains { $0.id == "d-mei" })
        #expect(await teams.loadRoster(on: "s-fixture-studio") == .failed("only a relay admin can list members and devices"))

        let view = try #require(await teams.loadCombinedView(of: "ws-relay", on: home).value)
        #expect(view.members.map(\.handle) == ["fixture-mei", "fixture-ryan", "fixture-sam"])
        #expect(view.workers.allSatisfy { $0.checks == nil && $0.branch.isEmpty })
        // Your own claim joins your published agent's row.
        let mine = try #require(view.members[1].workers.first)
        #expect(mine.id == "res-2" && mine.knownState == .working && mine.claims.map(\.id) == ["cl-2"] && mine.harness == "claude")
        #expect(mine.claims[0].holder == "fixture-ryan/relay-worker")
        // A friend's worker appears twice: published, and as a claim holder.
        #expect(view.members[2].workers.map(\.id) == ["dir-sam-agent", "fixture-sam/sam-agent"])
        #expect(await teams.loadCombinedView(of: "ws-none", on: home).failure == "no workspace ws-none in your groups")
        model.close()
    }

    @Test func theFixtureCarriesOwnersCommandsAndKnowledgeLimits() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("owners")
        let teams = model.share.teams
        #expect(teams.workspace("ws-relay", on: home)?.ownerHandle == "fixture-ryan")
        #expect(teams.workspace("ws-ios", on: home)?.ownerHandle == "fixture-jonas")
        #expect(teams.item("kn-skill", on: home)?.ownerHandle == "fixture-sam")
        #expect(try #require(await teams.loadVersions(of: "kn-skill", on: home).value).allSatisfy { $0.ownerHandle == "fixture-sam" })
        let host = try #require(teams.myHosts(on: home).first)
        #expect(host.capabilities?.commands == [MultiplayerHostCommand(name: "run-relay-benchmarks", environment: "apple-silicon")])
        #expect(model.me[home]?.knowledgeDefaultScope == .private && model.me[home]?.knowledgeWidestScope == .server)
        #expect(await teams.loadMe(on: "s-fixture-studio").value?.allowsKnowledge(.server) == true)
        model.close()
    }

    @Test func theFixtureEditsAndLeavesWorkspacesAndNamesAClaimsHolder() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("workspaces")
        let teams = model.share.teams
        var edit = MultiplayerWorkspaceEdit(try #require(teams.workspace("ws-relay", on: home)))
        edit.goal = "Ship the relay"
        edit.integration = .pullRequest
        #expect(await model.editWorkspace("ws-relay", to: edit, on: home).isDone)
        let edited = try #require(teams.workspace("ws-relay", on: home))
        #expect(edited.goal == "Ship the relay" && !edited.usesQueue && edited.name == "Relay reconnect" && edited.claims.count == 3)
        // Only the owner edits, and the owner can't leave.
        var theirs = MultiplayerWorkspaceEdit(try #require(teams.workspace("ws-ios", on: home)))
        theirs.base = "main"
        #expect(await model.editWorkspace("ws-ios", to: theirs, on: home).reason == "Couldn’t save the workspace. Only the owner can edit workspace ws-ios.")
        #expect(await model.leaveWorkspace("ws-relay", on: home).reason == "Couldn’t leave the workspace. The owner cannot leave workspace ws-relay.")

        let held = await model.claimAnswer(MultiplayerClaimDraft(kind: .issue, key: "#212", agent: "relay-worker"), in: "ws-relay", on: home)
        #expect(held.refusal == MultiplayerClaimRefusal(holder: "fixture-mei", agent: "mei-agent", claim: "cl-3"))
        #expect(held.refusal?.blocking(in: edited.claims)?.key == "#212" && held.result.reason?.hasPrefix("Couldn’t claim it.") == true)

        #expect(await model.leaveWorkspace("ws-ios", on: home).isDone)
        #expect(teams.workspaces[home]?.map(\.id) == ["ws-relay"])
        #expect(await model.leaveWorkspace("ws-ios", on: home).reason == "Couldn’t leave the workspace. No workspace ws-ios in your groups.")
        // Still in the group.
        #expect(teams.group("grp-ios", on: home)?.members.contains("fixture-ryan") == true)
        model.close()
    }
}
