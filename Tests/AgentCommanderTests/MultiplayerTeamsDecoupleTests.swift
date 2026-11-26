import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// Teams reads and changes a view outside the tray owns (issue #12): none reads or moves the tray's
// route, the list on its open page or its drafts, and each names its target, so it works whatever
// page the tray is on. Every handle, resource and path here is made up. No test reaches a network
// or the real helper.

private enum TeamsDecoupleFixture {
    static let versions = #"{"versions":[{"id":"kn-1","kind":"skill","name":"triage","content":"v1","visibility":"private","version":1},{"id":"kn-1","kind":"skill","name":"triage","content":"Triage steps","visibility":"group:grp-1","version":3}]}"#
    static let reputation = #"{"resource":"dir-h","completed":18,"accepted":15,"rejected":1,"medianSeconds":96}"#
    static let directory = #"{"handles":["fixture-bo"],"resources":[{"id":"dir-h","handle":"fixture-bo","name":"bo-mini","kind":"host","actions":["host.run"],"endorsements":[]}]}"#
    static let otherCards = #"{"cards":[{"id":"card-9","title":"Elsewhere","body":"","state":"open","assignee":"","result":""}]}"#
    static let merged = #"{"queue":[{"workspace":"ws-1","branch":"collab/a","checkout":"/tmp/relay","test":[],"added":"2026-11-25T11:00:00Z","state":"merged"},{"workspace":"ws-1","branch":"collab/b","checkout":"/tmp/relay","test":["swift","test"],"added":"2026-11-25T11:30:00Z","state":"failed","output":"1 failure"}]}"#
    static let run = #"{"request":"rq-9","status":"ok","value":{"command":"ui-tests","exitCode":0,"output":"** TEST SUCCEEDED **","seconds":37}}"#

    /// Answers every read and change these tests make.
    @MainActor static func model() async -> (MultiplayerModel, RoutedMultiplayerHelper) {
        await MultiplayerTeamsFixture.model { call in
            switch call.verb {
            case .workspacePRs: return MultiplayerPullRequestContractTests.reply
            case .queueAdd: return MultiplayerTeamsFixture.queue
            case .queueMerge: return merged
            case .queueRemove: return MultiplayerTeamsFixture.queue
            case .send: return run
            case .knowledgeShare:
                return call.input["item"]?["name"] == .string("leaky")
                    ? "!this item seems to contain a secret; replace it with a ${NAME} placeholder before sharing" : "{}"
            case .knowledgeInstall: return #"{"installed":"/Users/fixture/.claude/skills/triage/SKILL.md"}"#
            case .relay:
                switch (call.method, call.path) {
                case ("GET", "/v1/knowledge/kn-1/versions"): return versions
                case ("GET", "/v1/reputation/dir-h"): return reputation
                case ("GET", "/v1/workspaces/ws-9/cards"): return otherCards
                case ("GET", let path) where path.hasPrefix("/v1/directory"):
                    return path.hasSuffix("q=off") ? "!relay HTTP 403: forbidden" : directory
                case ("PUT", "/v1/admin/policy"): return MultiplayerTeamsFixture.policy
                case ("POST", "/v1/groups"): return #"{"id":"grp-7"}"#
                case ("POST", "/v1/workspaces"): return #"{"id":"ws-7"}"#
                case ("POST", "/v1/workspaces/ws-1/claims"):
                    return call.body?["key"] == .string("Sources/Relay") ? "!relay HTTP 409: already claimed by fixture-bo/bo-agent" : #"{"id":"cl-9"}"#
                case ("POST", "/v1/workspaces/ws-1/cards"): return #"{"id":"card-7"}"#
                default: return nil
                }
            default: return nil
            }
        }
    }
}

@MainActor @Suite struct MultiplayerTeamsCallerOwnedReadTests {
    private let home = MultiplayerTeamsFixture.home

    @Test func aTeamsReadLeavesTheRouteAndTheTraysOwnPagesAlone() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        // The tray is somewhere else entirely, and stays there.
        model.go(.hosting)

        let cards = await teams.loadCards(in: "ws-1", on: home)
        #expect(cards.value?.map(\.id) == ["card-1", "card-2", "card-3"])
        let pulls = await teams.loadPullRequests(in: "ws-2", on: home)
        #expect(pulls.value?.pullRequests.map(\.number) == [212, 209])
        #expect(helper.last(.workspacePRs)?.input["workspace"] == .string("ws-2"))
        let queue = await teams.loadQueue(for: "ws-1", on: home)
        #expect(queue.value?.map(\.branch) == ["collab/a", "collab/b"])
        let versions = await teams.loadVersions(of: "kn-1", on: home)
        #expect(versions.value?.map(\.version) == [1, 3])
        let reputation = await teams.loadReputation(of: "dir-h", on: home)
        #expect(reputation.value?.completed == 18)
        let search = await teams.searchDirectory("  ios sim&x ", on: home)
        #expect(search.value?.handles == ["fixture-bo"] && search.value?.query == "ios sim&x")
        #expect(helper.relays("GET").last { $0.path.hasPrefix("/v1/directory") }?.path == "/v1/directory?q=ios%20sim%26x")
        let policy = await teams.loadPolicy(on: home)
        #expect(policy.value?.knowledgeWidest == "group" && helper.relays("PUT").last?.body == .object([:]))

        // Nothing of the tray's own pages was filled, and no draft was touched.
        #expect(teams.cards == .loading && teams.pullRequests == .loading && teams.versions == .loading)
        #expect(teams.reputation == .loading && teams.policy == .loading)
        #expect(teams.search == .loaded(MultiplayerDirectorySearch()) && teams.searchDraft.isEmpty)
        #expect(teams.policyDraft == MultiplayerPolicyDraft())
        #expect(model.route == .hosting)
        model.close()
    }

    @Test func aReadForAnotherWorkspaceLeavesTheTraysOpenBoardAlone() async throws {
        let (model, _) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        model.share.open(.workspace("ws-1"), on: home)
        await model.settle()
        let shown = teams.cards
        #expect(shown.value?.count == 3)
        let other = await teams.loadCards(in: "ws-9", on: home)
        #expect(other.value?.map(\.id) == ["card-9"])
        #expect(teams.cards == shown && model.route == .share(home, .workspace("ws-1")))
        model.close()
    }

    @Test func aFailedTeamsReadSaysWhyAndStillLeavesTheRoute() async throws {
        let (model, _) = await TeamsDecoupleFixture.model()
        let refused = await model.share.teams.searchDirectory("off", on: home)
        #expect(refused.value == nil && refused.failure?.localizedCaseInsensitiveContains("forbidden") == true)
        #expect(model.route == .home && model.share.teams.search == .loaded(MultiplayerDirectorySearch()))
        // With no helper, a read says so and sends nothing.
        let offline = MultiplayerModel(client: nil, setupFailure: .launchFailed)
        let none = await offline.share.teams.loadCards(in: "ws-1", on: home)
        #expect(none.failure == MultiplayerFailure.launchFailed.message)
        let policy = await offline.share.teams.loadPolicy(on: home)
        #expect(policy.failure == MultiplayerFailure.launchFailed.message)
        model.close()
    }
}

@MainActor @Suite struct MultiplayerTeamsExplicitActionTests {
    private let home = MultiplayerTeamsFixture.home

    @Test func groupsAreMadeChangedAndDeletedWhileTheTrayIsElsewhere() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        model.go(.hosting)
        teams.groupDraft = "the tray’s own"

        let blank = await model.createGroup(named: "   ", on: home)
        #expect(blank.reason == "Couldn’t create the group. Give the group a name." && helper.relays("POST").isEmpty)
        let made = await model.createGroup(named: "  relay-team ", on: home)
        #expect(made == .done(id: "grp-7", server: home, message: "Created relay-team. Add friends to it next."))
        #expect(helper.relays("POST").last?.body == .object(["name": .string("relay-team")]))

        let group = try #require(teams.group("grp-1", on: home))
        let added = await model.addMember("fixture-cy", to: group, on: home)
        #expect(added.isDone && added.id == "grp-1" && helper.relays("PUT").last?.path == "/v1/groups/grp-1/members/fixture-cy")
        // The caller asked already: no second press on the tray's model is needed, or left behind.
        let removed = await model.removeMember("fixture-bo", from: group, on: home)
        #expect(removed.isDone && helper.relays("DELETE").last?.path == "/v1/groups/grp-1/members/fixture-bo")
        let deleted = await model.deleteGroup(group, on: home)
        #expect(deleted.isDone && deleted.id == "grp-1" && helper.relays("DELETE").last?.path == "/v1/groups/grp-1")
        #expect(teams.group("grp-1", on: home) == nil)

        // The tray's own field and its route were never involved.
        #expect(teams.groupDraft == "the tray’s own" && teams.confirming == nil && model.route == .hosting)
        let nowhere = await model.createGroup(named: "x", on: "s-nowhere")
        #expect(nowhere.reason == "Couldn’t create the group. Sign in to that server first.")
        model.close()
    }

    @Test func aWorkspaceAClaimAndItsReleaseNameTheirTargets() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        model.go(.addServer)

        var workspace = MultiplayerWorkspaceDraft()
        let unchosen = await model.createWorkspace(workspace, on: home)
        #expect(unchosen.reason == "Couldn’t create the workspace. Choose the group that works in it.")
        workspace.group = "grp-1"
        workspace.name = "Reconnect"
        workspace.goal = "Survive renewals"
        workspace.repository = "github.com/example/relay"
        let created = await model.createWorkspace(workspace, on: home)
        #expect(created.isDone && created.id == "ws-7")
        #expect(helper.relays("POST").last?.body?["integration"] == .string("queue"))

        var claim = MultiplayerClaimDraft(agent: "tests")
        let empty = await model.claim(claim, in: "ws-1", on: home)
        #expect(empty.reason == "Couldn’t claim it. Say what to claim.")
        claim.kind = .paths
        claim.key = "Sources/Relay"
        let held = await model.claim(claim, in: "ws-1", on: home)
        #expect(held.reason == "Couldn’t claim it. Already claimed by fixture-bo/bo-agent.")
        claim.key = "docs"
        let claimed = await model.claim(claim, in: "ws-1", on: home)
        #expect(claimed == .done(id: "cl-9", server: home,
                                 message: "Claimed docs for tests. The claim lasts while this Mac stays connected."))
        #expect(helper.relays("POST").last?.body == .object(["kind": .string("paths"), "key": .string("docs"),
                                                               "holder": .string("fixture-ada/tests")]))

        let mine = try #require(teams.workspace("ws-1", on: home)?.claims[1])
        let released = await model.release(mine, in: "ws-1", on: home)
        #expect(released == .done(id: "cl-2", server: home, message: "Released card-2."))
        #expect(helper.relays("DELETE").last?.path == "/v1/workspaces/ws-1/claims/cl-2")

        // The tray's forms, its board and its route were never involved.
        #expect(teams.workspaceDraft == MultiplayerWorkspaceDraft() && teams.claimDraft == MultiplayerClaimDraft())
        #expect(teams.cards == .loading && model.route == .addServer)
        model.close()
    }

    @Test func cardsAreAddedClaimedAndCompletedWithoutTheTraysBoard() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        model.go(.hosting)
        teams.resultDraft = "the tray’s own"

        let untitled = await model.addCard(MultiplayerCardDraft(), to: "ws-1", on: home)
        #expect(untitled.reason == "Couldn’t add the card. Give the card a title.")
        let added = await model.addCard(MultiplayerCardDraft(title: " Add a soak test "), to: "ws-1", on: home)
        #expect(added.isDone && added.id == "card-7")
        #expect(helper.relays("POST").last?.body?["title"] == .string("Add a soak test"))

        let board = try #require(await teams.loadCards(in: "ws-1", on: home).value)
        let claimed = await model.updateCard(board[0], in: "ws-1", on: home, to: .claimed)
        #expect(claimed == .done(id: "card-1", server: home,
                                 message: "Claimed Bound the wait. Nobody else can take it while you hold it."))
        #expect(helper.relays("PUT").last?.body == .object(["state": .string("claimed"), "assignee": .string("fixture-ada/tests")]))
        let completed = await model.completeCard(board[1], in: "ws-1", on: home, result: " Keyed by lease ID. ")
        #expect(completed.isDone && completed.id == "card-2")
        #expect(helper.relays("PUT").last?.body == .object(["state": .string("done"), "result": .string("Keyed by lease ID.")]))
        // The caller asked before giving up a held card: no second press on the tray's model.
        let released = await model.updateCard(board[1], in: "ws-1", on: home, to: .open)
        #expect(released.message == "Released Key waiters. Anyone in the group can claim it.")

        #expect(teams.cards == .loading && teams.cardDraft == MultiplayerCardDraft() && teams.resultDraft == "the tray’s own")
        #expect(model.route == .hosting)
        model.close()
    }

    @Test func theQueueTakesABranchRunsAndBringsBackWhatRan() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        model.go(.hosting)

        var draft = MultiplayerQueueDraft(branch: "collab/b")
        let nowhere = await model.addToQueue(draft, for: "ws-1", on: home)
        #expect(nowhere.reason == "Couldn’t queue the branch. Choose the checkout to merge in." && helper.last(.queueAdd) == nil)
        draft.checkout = "/tmp/relay"
        draft.testText = "swift test"
        let queued = await model.addToQueue(draft, for: "ws-1", on: home)
        let entry = try #require(teams.queue(for: "ws-1").last)
        #expect(queued == .done(id: entry.id, server: home, message: "Queued collab/b. Run the queue to test and merge it."))
        #expect(helper.last(.queueAdd)?.input["testCommand"] == .array([.string("swift"), .string("test")]))

        let ran = await model.runQueue("ws-1", on: home)
        #expect(ran.value?.map(\.branch) == ["collab/b"] && ran.value?.first?.state == "failed")
        #expect(ran.value?.first?.output == "1 failure" && helper.last(.queueMerge)?.input["workspace"] == .string("ws-1"))
        let idle = await model.runQueue("ws-1", on: home)
        #expect(idle.failure == "Couldn’t run the merge queue. No branch is waiting in the queue.")

        let removed = await model.removeFromQueue(entry, on: home)
        #expect(removed.isDone && removed.id == entry.id && helper.last(.queueRemove)?.input["branch"] == .string("collab/b"))

        #expect(teams.queueDraft == MultiplayerQueueDraft() && teams.confirming == nil && model.route == .hosting)
        model.close()
    }

    @Test func knowledgeIsSharedAndInstalledAndASecretIsRefusedForTheCaller() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        model.go(.hosting)

        var draft = MultiplayerKnowledgeDraft()
        draft.kind = .mcp
        draft.name = "leaky"
        draft.content = "password=hunter2hunter2"
        let caught = await model.shareKnowledge(draft, on: home)
        #expect(caught.reason == "Couldn’t share leaky. \(MultiplayerSecretCheck.refusal)" && helper.last(.knowledgeShare) == nil)
        // A pattern only the device knows: its refusal comes back to the caller, not to the tray's form.
        draft.content = "an odd credential the panel doesn’t recognise"
        let refused = await model.shareKnowledge(draft, on: home)
        #expect(refused.reason.map(MultiplayerSecretCheck.isRefusal) == true && teams.secretRefusal == nil)

        draft.name = "gh"
        draft.content = #"{"env":{"GITHUB_TOKEN":"${GITHUB_TOKEN}"}}"#
        draft.scope = .group
        draft.target = "grp-1"
        let shared = await model.shareKnowledge(draft, on: home)
        #expect(shared == .done(id: "kn-2", server: home, message: "Shared gh."))
        #expect(helper.last(.knowledgeShare)?.input["item"]?["visibility"] == .string("group:grp-1"))

        // A new version of your own item goes to the relay's PUT and reports that item.
        let version = await model.shareKnowledge(MultiplayerKnowledgeDraft(editing: teams.item("kn-2", on: home)), on: home)
        #expect(version == .done(id: "kn-2", server: home, message: "Saved a new version of gh."))
        #expect(helper.relays("PUT").last?.path == "/v1/knowledge/kn-2")

        let item = try #require(teams.item("kn-1", on: home))
        let installed = await model.installKnowledge(item, on: home)
        #expect(installed.isDone && installed.id == "kn-1" && installed.message?.contains("SKILL.md") == true)

        #expect(teams.knowledgeDraft == MultiplayerKnowledgeDraft() && model.route == .hosting)
        model.close()
    }

    @Test func aHostRunAnEndorsementAndAnOutcomeNameTheirTargets() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        model.go(.hosting)

        var run = MultiplayerHostRunDraft()
        let unchosen = await model.runOnHost(run, resource: "dir-h", on: home)
        #expect(unchosen.failure == "Couldn’t run the command. Choose a command first." && helper.last(.send) == nil)
        run.command = "ui-tests"
        run.argumentText = "--only Onboarding"
        let reply = await model.runOnHost(run, resource: "dir-h", on: home)
        #expect(reply.value?.request == "rq-9" && MultiplayerHostRun(reply.value?.value)?.succeeded == true)
        let sent = helper.last(.send)?.input
        #expect(sent?["resource"] == .string("dir-h") && sent?["capability"] == .string("host.run"))
        #expect(sent?["payload"] == .object(["command": .string("ui-tests"), "args": .array([.string("--only"), .string("Onboarding")])]))

        let unnamed = await model.endorse("dir-h", for: " ", on: home)
        #expect(unnamed.reason == "Couldn’t endorse it. Name the skill first.")
        let endorsed = await model.endorse("dir-h", for: " ui tests ", on: home)
        #expect(endorsed == .done(id: "dir-h", server: home, message: "Endorsed for ui tests."))
        #expect(helper.relays("POST").last?.body == .object(["resource": .string("dir-h"), "skill": .string("ui tests")]))

        let mine = try #require(teams.judgeable("dir-h", on: home).first)
        let reported = await model.reportOutcome(of: mine, on: home, accepted: true)
        #expect(reported == .done(id: "rq-1", server: home, message: "Reported as accepted."))
        #expect(helper.relays("POST").last?.path == "/v1/outcomes" && teams.outcomes == ["rq-1": true])

        // The tray's run page, its reply, its field and its reputation page were never involved.
        #expect(teams.hostReply == nil && teams.hostDraft == MultiplayerHostRunDraft() && teams.endorseDraft.isEmpty)
        #expect(teams.reputation == .loading && model.route == .hosting)
        model.close()
    }

    @Test func thePolicyIsSavedAndMembersAndDevicesAreNamedByTheCaller() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        model.go(.hosting)

        let saved = try #require(await teams.loadPolicy(on: home).value)
        var draft = MultiplayerPolicyDraft(saved)
        let unchanged = await model.savePolicy(draft, from: saved, on: home)
        #expect(unchanged.failure == "Couldn’t save the policy. Nothing changed yet." && helper.relays("PUT").count == 1)
        draft.retentionDays = "0"
        let unreadable = await model.savePolicy(draft, from: saved, on: home)
        #expect(unreadable.failure == "Couldn’t save the policy. Use a whole number of days, at least 1.")
        draft.retentionDays = "90"
        draft.directory = false
        draft.maxGrantDays = "14"
        let kept = await model.savePolicy(draft, from: saved, on: home)
        #expect(kept.value?.knowledgeWidest == "group")
        #expect(helper.relays("PUT").last?.body == .object(["directory": .bool(false), "maxGrantDays": .number(14)]))

        let nobody = await model.setSuspended(true, member: "  ", on: home)
        #expect(nobody.reason == "Couldn’t suspend the member. Name the member first." && helper.relays("POST").isEmpty)
        let suspended = await model.setSuspended(true, member: " Fixture-Bo ", on: home)
        #expect(suspended.isDone && suspended.id == "fixture-bo")
        #expect(helper.relays("POST").last?.path == "/v1/admin/members/fixture-bo/suspend")
        let restored = await model.setSuspended(false, member: "fixture-bo", on: home)
        #expect(restored.message == "Restored fixture-bo." && helper.relays("POST").last?.path == "/v1/admin/members/fixture-bo/unsuspend")
        let revoked = await model.revokeDevice(" d-bo/1 ", on: home)
        #expect(revoked == .done(id: "d-bo/1", server: home, message: "Revoked. That device must sign in again to use this relay."))
        #expect(helper.relays("DELETE").last?.path == "/v1/admin/devices/d-bo%2F1")

        // The tray's policy page and its fields were never involved.
        #expect(teams.policy == .loading && teams.policyDraft == MultiplayerPolicyDraft() && teams.confirming == nil)
        #expect(model.route == .hosting)
        model.close()
    }

    @Test func theTraysRouteBoundTeamsCallsStillRefuseOffTheirPage() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        let calls = helper.all.count
        // Every draft is ready to send, but the tray is on none of these pages.
        teams.groupDraft = "relay-team"
        teams.workspaceDraft = MultiplayerWorkspaceDraft(name: "n", goal: "g", repository: "r", group: "grp-1")
        teams.claimDraft = MultiplayerClaimDraft(key: "docs", agent: "tests")
        teams.queueDraft = MultiplayerQueueDraft(branch: "collab/c", checkout: "/tmp/relay")
        teams.hostDraft = MultiplayerHostRunDraft(command: "ui-tests")
        teams.knowledgeDraft.name = "notes"
        teams.knowledgeDraft.content = "Steps"
        teams.policyDraft.member = "fixture-bo"
        teams.policyDraft.device = "d-bo/1"
        #expect(teams.canCreateGroup && teams.canCreateWorkspace && teams.canClaim && teams.canQueue)
        #expect(teams.canRunOnHost && teams.canShareKnowledge)
        #expect(teams.createGroup(on: home) == nil && teams.createWorkspace(on: home) == nil)
        #expect(teams.sendClaim(in: "ws-1", on: home) == nil && teams.addToQueue("ws-1", on: home) == nil)
        #expect(teams.runOnHost("dir-h", on: home) == nil && teams.shareKnowledge(on: home) == nil)
        #expect(teams.savePolicy(on: home) == nil && teams.setSuspended(true, on: home) == nil && teams.revokeDevice(on: home) == nil)
        // A page for another target is not this call's page either.
        model.share.open(.claim(workspace: "ws-9"), on: home)
        #expect(teams.sendClaim(in: "ws-1", on: home) == nil)
        model.share.open(.hostRun(resource: "dir-g"), on: home)
        #expect(teams.runOnHost("dir-h", on: home) == nil)
        await model.settle()
        #expect(helper.all.dropFirst(calls).allSatisfy { $0.verb != .send && ($0.verb != .relay || $0.method == "GET") })
        #expect(teams.groupDraft == "relay-team" && teams.policyDraft.member == "fixture-bo")
        model.close()
    }

    @Test func theTraysOwnCallStillSendsFromItsPageAndMovesTheTray() async throws {
        let (model, helper) = await TeamsDecoupleFixture.model()
        let teams = model.share.teams
        teams.startClaim(in: "ws-1", on: home)
        teams.claimDraft.key = "docs"
        // A caller's change while the tray's form is open leaves the form and its route alone.
        let other = await model.claim(MultiplayerClaimDraft(key: "notes", agent: "tests"), in: "ws-1", on: home)
        #expect(other.isDone && teams.claimDraft.key == "docs" && model.route == .share(home, .claim(workspace: "ws-1")))
        await teams.sendClaim(in: "ws-1", on: home)?.value
        #expect(helper.relays("POST").last?.body?["key"] == .string("docs"))
        #expect(model.route != .share(home, .claim(workspace: "ws-1")))
        model.close()
    }
}

@MainActor @Suite struct MultiplayerTeamsHostTests {
    private let home = MultiplayerTeamsFixture.home

    private func hosts(_ model: MultiplayerModel, item: MultiplayerKnowledgeItem? = nil, scrolls: Bool) -> [(String, AnyView)] {
        let cancel = {}, finish: (MultiplayerActionResult) -> Void = { _ in }
        return [
            ("workspace", AnyView(MultiplayerWorkspaceHost(model: model, server: home, scrolls: scrolls, onCancel: cancel, onFinish: finish))),
            ("claim", AnyView(MultiplayerClaimHost(model: model, server: home, workspace: "ws-1", scrolls: scrolls, onCancel: cancel, onFinish: finish))),
            ("card", AnyView(MultiplayerCardHost(model: model, server: home, workspace: "ws-1", card: "card-2", scrolls: scrolls,
                                                 onCancel: cancel, onFinish: finish))),
            ("queue", AnyView(MultiplayerQueueHost(model: model, server: home, workspace: "ws-1", scrolls: scrolls, onCancel: cancel, onFinish: finish))),
            ("knowledge", AnyView(MultiplayerKnowledgeHost(model: model, server: home, editing: item, scrolls: scrolls,
                                                           onCancel: cancel, onFinish: finish))),
            ("host-run", AnyView(MultiplayerHostRunHost(model: model, server: home, resource: "dir-h", scrolls: scrolls,
                                                        onCancel: cancel, onFinish: finish))),
            ("policy", AnyView(MultiplayerPolicyHost(model: model, server: home, scrolls: scrolls, onCancel: cancel, onFinish: finish))),
        ]
    }

    @Test func everyTeamsHostDrawsWithoutATrayPage() async throws {
        let (model, _) = await TeamsDecoupleFixture.model()
        model.go(.hosting)
        for (name, host) in hosts(model, scrolls: false) {
            #expect(MultiplayerHostTests.height(of: host) > 60, "\(name)")
            // Without `scrolls` a host has no scroll view of its own. A form with a text area
            // keeps the one inside its editor, so those are not asked.
            if ["workspace", "claim", "queue"].contains(name) { #expect(!MultiplayerHostTests.scrolls(host), "\(name)") }
        }
        // By default a host scrolls its composer.
        for (name, host) in hosts(model, scrolls: true) { #expect(MultiplayerHostTests.scrolls(host), "\(name)") }
        await model.settle()
        #expect(model.route == .hosting)
        // Hosting a form fills nothing of the tray's own pages.
        let teams = model.share.teams
        #expect(teams.cards == .loading && teams.policy == .loading && teams.hostReply == nil)
        #expect(teams.claimDraft == MultiplayerClaimDraft() && teams.knowledgeDraft == MultiplayerKnowledgeDraft())
        model.close()
    }

    @Test(.enabled(if: multiplayerRenderDirectory != nil)) func drawsTheTeamsHosts() async throws {
        let folder = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (model, _) = await TeamsDecoupleFixture.model()
        model.go(.hosting)
        for (name, host) in hosts(model, item: model.share.teams.item("kn-2", on: home), scrolls: false) {
            try await MultiplayerRenderTests.write(view: host, "teams-host-\(name)", to: folder, settling: model)
        }
        #expect(model.route == .hosting)
        model.close()
    }
}
