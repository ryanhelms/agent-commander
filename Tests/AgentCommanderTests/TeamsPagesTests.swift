import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The Teams pages' values, the live mappers, and what each action does to the sample state.

@MainActor @Suite struct TeamsPagesTests {
    static let studio = TeamsSample.studio, relay = TeamsSample.relayKey

    /// A preview state whose sample actions and outcomes take no time.
    static func preview(_ place: String? = nil) -> TeamsPreviewState {
        let state = TeamsPreviewState(place: place)
        state.latency = .zero
        state.state.results.dwell = .milliseconds(20)
        return state
    }

    static func send(_ state: TeamsPreviewState, _ intents: TeamsIntent...) {
        for intent in intents { state.pages(go: { _ in }).send(intent) }
    }

    /// Waits for a sample action to end.
    static func settle(_ state: TeamsPreviewState, until done: @MainActor () -> Bool = { true }) async {
        for _ in 0..<400 where !(state.state.results.running.isEmpty && done()) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: Values

    @Test func placesAndKeys() {
        #expect(TeamsPlace.workspace("ws-1", on: "srv") == "team:srv/ws-1")
        #expect(TeamsPlace.workspaceKey(of: "team:srv/ws-1") == "srv/ws-1" && TeamsPlace.workspaceKey(of: TeamsPlace.groups) == nil)
        #expect(TeamsPlace.tools.allSatisfy(TeamsPlace.hasPage) && TeamsPlace.hasPage(TeamsPlace.workspaces) && !TeamsPlace.hasPage("runs"))
        #expect(TeamsPlace.tools.map(TeamsPlace.title) == ["Groups", "Hosts", "Knowledge", "Directory", "Admin"])
        let parts = TeamsKey.split("srv/a/b")
        #expect(parts?.server == "srv" && parts?.id == "a/b" && TeamsKey.split("nokey") == nil && TeamsKey.split("srv/") == nil)
        #expect(LiveShell.teamTools(isAdmin: false).map(\.id) == Array(TeamsPlace.tools.dropLast()))
        #expect(LiveShell.isTeamsPlace(TeamsPlace.admin) && !LiveShell.isTeamsPlace(NetworkPlace.servers))
    }

    @Test func theBoardHasThreeColumnsAndMarksYourCards() {
        let content = TeamsSample.content
        #expect(content.boardCards(.open, in: Self.relay).map(\.id) == ["card-1", "card-2", "card-6"])
        let claimed = content.boardCards(.claimed, in: Self.relay)
        #expect(claimed.map(\.isMine) == [true, false] && content.boardCards(.done, in: Self.relay).count == 2)
        #expect(content.title(for: TeamsSample.relayPlace) == "Relay launch")
        #expect(content.kicker(for: TeamsSample.relayPlace) == "TEAMS / WORKSPACES / STUDIO")
        #expect(content.readouts(for: TeamsSample.relayPlace).map(\.value) == ["3", "4", "3", "2", "2"])
        #expect(content.readouts(for: TeamsSample.infraPlace).last?.label == "open pull requests")
        #expect(content.summary(for: "team:srv-studio/gone").hasPrefix("This workspace is gone"))
    }

    @Test func theCombinedViewJoinsWorkersToTheirClaims() {
        let rows = TeamsSample.content.combinedRows(in: Self.relay)
        #expect(rows.map(\.showsMember) == [true, false, true, true, false])
        #expect(rows[0].claim?.key == "card-3" && rows[0].isMine && rows[1].claim == nil)
        #expect(rows[2].claim?.kindTitle == "Issue" && rows[4].claim?.key == "Sources/Relay/Lease")
        #expect(rows[3].spoken == "sam, sam-codex, Waiting on review, holds card card-4, branch collab/fake-clock, checks: 2 failing")
        // A member with no worker still has a row.
        #expect(TeamsSample.content.combinedRows(in: TeamsSample.infraKey).last?.worker == nil)
        #expect(TeamsChecks(passed: 3).title == "3 passing" && TeamsChecks(isRunning: true).tone == .focus && TeamsChecks().title == "No checks")
    }

    @Test func installNamesWhereItWrites() {
        let skill = MultiplayerKnowledgeItem(id: "k", kind: "skill", name: "Relay Triage!", content: "x")
        #expect(TeamsInstallDraft.destination(for: skill) == .skill(path: "~/.claude/skills/relay-triage/SKILL.md"))
        let mcp = MultiplayerKnowledgeItem(id: "m", kind: "mcp", name: "github", content: "${GITHUB_TOKEN}")
        #expect(TeamsInstallDraft.destination(for: mcp) == nil, "an MCP item installs nowhere until a file is chosen")
        #expect(TeamsInstallDraft.destination(for: mcp, file: "/tmp/.mcp.json") == .file(path: "/tmp/.mcp.json"))
        #expect(TeamsInstallDraft.destination(for: MultiplayerKnowledgeItem(id: "p", kind: "prompt", name: "p")) == .clipboard)
        let draft = TeamsInstallDraft(server: "s", item: "m", name: "github", kind: "mcp", destination: .file(path: NSHomeDirectory() + "/x/.mcp.json"),
                                      placeholders: ["GITHUB_TOKEN"])
        #expect(draft.shownDestination == "~/x/.mcp.json" && draft.confirmTitle == "Save to file")
        #expect(draft.consequence == "Saves the configuration into this file. ${GITHUB_TOKEN} is filled from your Keychain.")
        #expect(TeamsInstallDraft.skillFolder("  ") == "skill")
    }

    @Test func thePolicyConfirmationNamesEachChange() {
        var draft = MultiplayerPolicyDraft(TeamsSample.policy)
        #expect(TeamsPolicyChange.list(draft, from: TeamsSample.policy).isEmpty)
        draft.knowledgeWidest = .server
        draft.maxGrantDays = "0"
        draft.directory = false
        let lines = TeamsPolicyChange.list(draft, from: TeamsSample.policy)
        #expect(lines.map(\.label) == ["Widest knowledge scope", "Directory search", "Longest grant"])
        #expect(lines.map(\.value) == ["Group → Server", "On → Off", "30 days → no limit"])
        draft.retentionDays = "none"
        #expect(TeamsPolicyChange.list(draft, from: TeamsSample.policy).isEmpty, "a draft that can't be saved changes nothing")
    }

    // MARK: Live mappers

    @Test func theLiveCombinedViewComesFromMembersAndClaims() {
        let claims = [MultiplayerClaim(id: "1", kind: "issue", key: "#1", holder: "mira/mira-claude"),
                      MultiplayerClaim(id: "2", kind: "paths", key: "a", holder: "mira/mira-claude"),
                      MultiplayerClaim(id: "3", kind: "card", key: "c", holder: "tomas/tomas-codex")]
        let work = TeamsLiveMapper.work(members: ["ryan", "mira"], claims: claims) { $0 != "mira" }
        #expect(work.map(\.handle) == ["ryan", "mira", "tomas"], "a holder outside the group is still shown")
        #expect(work.map(\.isOnline) == [true, false, true] && work.map(\.workers.count) == [0, 1, 1])
        #expect(work[1].workers[0].name == "mira-claude" && work[1].workers[0].checks == nil)
    }

    @Test func aMergeRunBecomesOneResult() {
        let entries = [MultiplayerQueueEntry(workspace: "w", branch: "a", state: "merged"),
                       MultiplayerQueueEntry(workspace: "w", branch: "b", state: "failed"),
                       MultiplayerQueueEntry(workspace: "w", branch: "c", state: "conflict")]
        let result = TeamsLiveMapper.merge(.loaded(entries), workspace: "w", base: "main", on: "s")
        #expect(result.message == "Merged 1 branch into main. Not merged: b (tests failed) and c (conflict). Each keeps its output in the queue.")
        #expect(TeamsLiveMapper.merge(.loaded([entries[0]]), workspace: "w", base: "", on: "s").message == "Merged 1 branch into the base.")
        #expect(TeamsLiveMapper.merge(.failed("Couldn’t run the merge queue. No branch is waiting in the queue."), workspace: "w", base: "main", on: "s")
                == .failed(id: "w", server: "s", reason: "Couldn’t run the merge queue. No branch is waiting in the queue."))
    }

    // MARK: Preview flows

    @Test func claimingACardMovesItAndARefusalSaysWhoHoldsIt() async throws {
        let state = Self.preview(TeamsSample.relayPlace)
        let card = try #require(state.content.card("card-1", in: Self.relay))
        Self.send(state, .claimCard(card, workspace: Self.relay))
        await Self.settle(state)
        #expect(state.content.card("card-1", in: Self.relay)?.assignee == "ryan/relay-worker")
        #expect(state.content.workspace(Self.relay)?.workspace.claims.contains { $0.key == "card-1" } == true)

        // The relay answers 409: the card shows who holds it and keeps the reason.
        let contested = try #require(state.content.card(TeamsSample.contested, in: Self.relay))
        Self.send(state, .claimCard(contested, workspace: Self.relay))
        await Self.settle(state)
        #expect(state.content.card(TeamsSample.contested, in: Self.relay)?.assignee == "sam/sam-codex")
        let shown = state.pages(go: { _ in }).content.boardCards(.claimed, in: Self.relay).first { $0.id == TeamsSample.contested }
        // The refusal's own fields name the holder, the agent and the claim; the claim's row is marked.
        #expect(shown?.result?.reason == "Couldn’t claim it. sam holds it with the agent sam-codex, under the card claim Fuzz the lease parser.")
        let blocking = state.content.workspace(Self.relay)?.workspace.claims.first { $0.key == TeamsSample.contested }
        #expect(blocking != nil && state.state.selection.conflict == blocking?.id)
        #expect(state.state.refusal(card: TeamsSample.contested, in: Self.relay) == MultiplayerClaimRefusal(holder: "sam", agent: "sam-codex", claim: blocking?.id ?? ""))
    }

    /// A claim's note is true only while the card is claimed: a Done card doesn't keep it.
    @Test func aDoneCardDropsItsClaimNote() async throws {
        let state = Self.preview(TeamsSample.relayPlace)
        let card = try #require(state.content.card("card-1", in: Self.relay))
        Self.send(state, .claimCard(card, workspace: Self.relay))
        await Self.settle(state)
        func shown(_ column: MultiplayerCard.State) -> TeamsBoardCard? {
            state.pages(go: { _ in }).content.boardCards(column, in: Self.relay).first { $0.id == "card-1" }
        }
        #expect(shown(.claimed)?.result?.message == "Claimed for relay-worker.")
        // The network model's own card host completes it: the window's row result was never run again.
        state.content.cards[Self.relay] = state.content.cards[Self.relay]?.map {
            $0.id == "card-1" ? MultiplayerCard(id: $0.id, title: $0.title, state: "done", assignee: $0.assignee, result: "Shipped.") : $0
        }
        #expect(shown(.done) != nil && shown(.done)?.result == nil)
        // And the host's own finish clears what the claim said.
        state.state.hostFinished(.card("card-1", workspace: Self.relay), .done(id: "card-1", server: Self.studio, message: nil))
        #expect(state.state.results.results[TeamsKey.result("card", TeamsKey.make("card-1", on: Self.relay))] == nil)
    }

    // MARK: Messages stay on their page

    @Test func aMessageShowsOnlyOnThePageThatRaisedIt() async throws {
        let state = Self.preview(TeamsSample.relayPlace)
        let relayPlace = TeamsSample.relayPlace
        func notice(on place: String) -> String? { state.pages(place: place, go: { _ in }).content.notice }
        state.pages(place: relayPlace, go: { _ in }).send(.startQueue(workspace: Self.relay))
        state.state.drafts.queue = MultiplayerQueueDraft(branch: "collab/verify", checkout: NetworkSample.checkout)
        state.pages(place: relayPlace, go: { _ in }).send(.sendQueue)
        await Self.settle(state) { state.state.notice != nil }
        let queued = try #require(state.state.notice)
        // On its own page, and nowhere else: not on Groups, and not above Admin's own messages.
        #expect(notice(on: relayPlace) == queued)
        #expect(notice(on: TeamsPlace.groups) == nil && notice(on: TeamsPlace.admin) == nil)
        // Leaving the page clears it, so it isn't there on the way back.
        state.state.left(relayPlace)
        #expect(state.state.notice == nil && notice(on: relayPlace) == nil)
    }

    @Test func anActionThatEndsAfterYouLeftSaysNothingOnTheNextPage() async {
        let state = Self.preview(TeamsSample.relayPlace)
        state.latency = .milliseconds(60)
        let relayPlace = TeamsSample.relayPlace
        state.pages(place: relayPlace, go: { _ in }).send(.newGroup(server: Self.studio))
        state.state.drafts.groupName = "Verify crew"
        state.pages(place: TeamsPlace.groups, go: { _ in }).send(.createGroup)
        // The window moves on while the group is being created.
        state.state.left(TeamsPlace.groups)
        await Self.settle(state) { state.state.notice != nil }
        #expect(state.pages(place: TeamsPlace.knowledge, go: { _ in }).content.notice == nil)
        #expect(state.pages(place: TeamsPlace.groups, go: { _ in }).content.notice?.contains("Verify crew") == true)
    }

    @Test func aHostThatSaysItsOwnOutcomeAddsNoBand() {
        let state = TeamsPagesState()
        state.hostFinished(.policy(server: Self.studio), .done(id: Self.studio, server: Self.studio, message: "Saved."), from: TeamsPlace.admin)
        #expect(state.notice == nil, "the policy host shows its own Saved")
        state.hostFinished(.queue(workspace: Self.relay), .done(id: "q", server: Self.studio, message: "Queued collab/x."), from: TeamsSample.relayPlace)
        #expect(state.shown(TeamsPagesContent(), place: TeamsSample.relayPlace).notice == "Queued collab/x.")
        #expect(state.shown(TeamsPagesContent(), place: TeamsPlace.admin).notice == nil)
    }

    // MARK: Owner

    @Test func theOwnerEditsAfterAConfirmationThatNamesEachChange() async throws {
        let state = Self.preview(TeamsSample.relayPlace)
        Self.send(state, .startEdit(workspace: Self.relay))
        #expect(state.state.selection.composer == .editWorkspace(Self.relay) && state.state.drafts.workspace.name == "Relay launch")
        // Nothing changed yet: the form says so and asks nothing.
        Self.send(state, .askSaveWorkspace)
        #expect(state.state.refusal == "Nothing changed yet." && state.state.selection.confirming == nil)
        state.state.drafts.workspace.name = "Relay reconnect"
        state.state.drafts.workspace.integration = .pullRequest
        Self.send(state, .askSaveWorkspace)
        #expect(state.state.selection.confirming == .saveWorkspace(workspace: Self.relay))
        let saved = try #require(state.content.workspace(Self.relay)?.workspace)
        let changes = TeamsWorkspaceEditForm.changes(state.state.drafts.workspace, from: saved)
        #expect(changes.map(\.label) == ["Name", "Lands by"])
        #expect(changes.map(\.value) == ["Relay launch → Relay reconnect", "merge queue → pull requests"])
        #expect(state.content.workspace(Self.relay)?.workspace.name == "Relay launch", "nothing is saved before the second press")
        Self.send(state, .confirm)
        await Self.settle(state) { state.state.selection.composer == nil }
        #expect(state.content.workspace(Self.relay)?.workspace.name == "Relay reconnect")
        #expect(state.content.workspace(Self.relay)?.workspace.usesQueue == false && state.state.notice == "Saved Relay reconnect.")
    }

    @Test func onlyTheOwnerEditsAndOnlyAMemberLeaves() async throws {
        let state = Self.preview(TeamsSample.infraPlace)
        let infra = TeamsSample.infraKey
        // ines owns Infra guild: there is nothing for ryan to edit.
        Self.send(state, .startEdit(workspace: infra))
        #expect(state.state.selection.composer == nil)
        // ryan owns Relay launch: the relay refuses an owner who leaves, so it isn't asked.
        Self.send(state, .askLeave(workspace: Self.relay))
        #expect(state.state.selection.confirming == nil)

        var went: [String] = []
        state.pages(place: TeamsSample.infraPlace, go: { went.append($0) }).send(.askLeave(workspace: infra))
        #expect(state.state.selection.confirming == .leaveWorkspace(workspace: infra))
        #expect(state.content.workspace(infra) != nil, "nothing is left before the second press")
        state.pages(place: TeamsSample.infraPlace, go: { went.append($0) }).send(.confirm)
        await Self.settle(state) { !went.isEmpty }
        #expect(state.content.workspace(infra) == nil && went == [TeamsPlace.workspaces])
        #expect(state.state.notice == "Left Infra guild. Your claims in it have ended.")
        let context = try #require(state.content.workspace(Self.relay)).workspace
        #expect(context.isOwned(by: "ryan") && !context.isOwned(by: "mira"))
    }

    // MARK: The new reads

    @Test func theRosterBecomesMemberAndDeviceRows() {
        let roster = MultiplayerRelayRoster(
            members: [MultiplayerRelayMember(handle: "alice", admin: true), MultiplayerRelayMember(handle: "bob", suspended: true),
                      MultiplayerRelayMember(id: "#2", handle: "")],
            devices: [MultiplayerRelayDevice(id: "3f2c", owner: "alice", online: true),
                      MultiplayerRelayDevice(id: "9a71", owner: "bob", online: false, lastSeen: TeamsSample.now.addingTimeInterval(-3_600))])
        let members = TeamsLiveMapper.members(roster), devices = TeamsLiveMapper.devices(roster)
        #expect(members.map(\.id) == ["alice", "bob", "#2"] && members[0].isAdmin && members[1].isSuspended)
        // A member with no handle is listed and can't be suspended yet.
        #expect(members[2].canModerate == false && members[0].canModerate)
        // The relay stores no device name: the ID is the name, and it isn't said twice.
        #expect(devices.map(\.name) == ["3f2c", "9a71"] && devices[0].isOnline == true)
        #expect(TeamsAdminPage.detail(devices[0], now: TeamsSample.now) == "alice, online now")
        #expect(TeamsAdminPage.detail(devices[1], now: TeamsSample.now).hasPrefix("bob, seen "))
        #expect(TeamsAdminPage.detail(TeamsDevice(id: "x", name: "x", owner: "", isOnline: false), now: TeamsSample.now)
                == "a member without a handle, never connected")
    }

    @Test func theCombinedViewBecomesWorkersWithTheirClaims() {
        let claim = MultiplayerClaim(id: "c9", kind: "paths", key: "src", holder: "alice/w-42", expiresAt: nil)
        let other = MultiplayerClaim(id: "c10", kind: "issue", key: "12", holder: "alice/w-42", expiresAt: nil)
        let view = MultiplayerCombinedView(workspace: "ws", members: [
            MultiplayerCombinedMember(handle: "alice", online: true, workers: [
                MultiplayerCombinedWorker(id: "build-worker", name: "Build worker", resource: "build-worker", agent: "w-42",
                                          harness: "claude", model: "opus", state: "working", claims: [claim, other])]),
            MultiplayerCombinedMember(handle: "bob", online: nil, workers: [
                MultiplayerCombinedWorker(id: "bob/w-7", name: "w-7", agent: "w-7", state: "offline",
                                          checks: MultiplayerWorkerChecks(passed: 3, failed: 1))]),
            MultiplayerCombinedMember(handle: "cy", online: false)
        ])
        let work = TeamsLiveMapper.work(view)
        #expect(work.map(\.handle) == ["alice", "bob", "cy"] && work[0].isOnline && !work[1].isOnline)
        let worker = work[0].workers[0]
        #expect(worker.name == "Build worker" && worker.state == "Working" && worker.tone == .working)
        #expect(worker.capabilities.harness == "claude" && worker.capabilities.model == "opus")
        // Nothing the relay has no source for is made up: no branch, and no checks rather than zero.
        #expect(worker.branch.isEmpty && worker.checks == nil && worker.claims == [claim, other])
        #expect(work[1].workers[0].checks == TeamsChecks(passed: 3, failed: 1) && work[1].workers[0].tone == .neutral)

        var content = TeamsSample.content
        content.work[Self.relay] = work
        let rows = content.combinedRows(in: Self.relay)
        #expect(rows.map(\.id) == ["alice/build-worker", "bob/bob/w-7", "cy"])
        #expect(rows[0].claim == claim && rows[0].moreClaims == 1 && rows[0].spoken.contains("holds paths src and 1 more"))
        #expect(rows[2].worker == nil)
    }

    @Test func aRefusalNamesTheHolderTheAgentAndTheClaim() {
        let claims = [MultiplayerClaim(id: "d2", kind: "issue", key: "12", holder: "bob/w-7", expiresAt: nil)]
        let refusal = MultiplayerClaimRefusal(holder: "bob", agent: "w-7", claim: "d2")
        let outcome = TeamsClaimOutcome.failed(id: "12", server: Self.studio, reason: "Couldn’t claim it. Overlapping claim held by bob/w-7.", refusal: refusal)
        #expect(outcome.named(in: claims) { _ in nil }.reason == "Couldn’t claim it. bob holds it with the agent w-7, under the issue claim 12.")
        // The claim isn't in the list any more: its ID is said. No agent: it is left out.
        #expect(TeamsClaimOutcome.sentence(refusal, blocking: nil) { _ in nil } == "bob holds it with the agent w-7, under claim d2.")
        #expect(TeamsClaimOutcome.sentence(MultiplayerClaimRefusal(holder: "bob"), blocking: nil) { _ in nil } == "bob holds it.")
        // Any other refusal is left as the relay said it.
        let plain = TeamsClaimOutcome.failed(id: "12", server: Self.studio, reason: "Couldn’t claim it. The server is offline.")
        #expect(plain.named(in: claims) { _ in nil }.reason == "Couldn’t claim it. The server is offline.")
    }

    // MARK: Knowledge

    @Test func knowledgeCountsWhatYouSharedAndNamesOwnersByHandle() async {
        let state = Self.preview(TeamsPlace.knowledge)
        func shared() -> String? { state.pages(go: { _ in }).content.readouts(for: TeamsPlace.knowledge).first { $0.id == "mine" }?.value }
        let before = state.content.knowledgeRows.filter(\.isMine).count
        // The relay names an owner by user ID. The handle beside it says whose it is.
        #expect(before == 1 && shared() == "1")
        #expect(state.content.knowledgeRows.allSatisfy { TeamsPagesContent.owner(of: $0.item) == $0.item.ownerHandle && !$0.item.owner.hasPrefix($0.item.ownerHandle) })
        #expect(TeamsPagesContent.owner(of: MultiplayerKnowledgeItem(id: "k", owner: "u-sam", kind: "prompt", name: "n")) == "u-sam")
        Self.send(state, .startShare(server: Self.studio))
        state.state.drafts.knowledge.name = "Verify notes"
        state.state.drafts.knowledge.content = "Check the lease timer."
        Self.send(state, .sendShare)
        await Self.settle(state) { state.state.selection.composer == nil }
        #expect(state.content.knowledgeRows.filter(\.isMine).count == before + 1 && shared() == "\(before + 1)")
    }

    @Test func aForbiddenShareNamesTheWidestScopeTheServerAllows() {
        var content = TeamsSample.content
        // The sample's policy lets knowledge reach a group at most.
        #expect(content.reachNote(on: Self.studio) == "studio lets knowledge reach a group at most.")
        #expect(content.shareRefusal("Couldn’t share policy-probe. Forbidden.", scope: .server, on: Self.studio)
                == "Couldn’t share policy-probe. Forbidden. studio lets knowledge reach a group at most.")
        // Within the limit, or when the server hasn't said, the relay's own words stand.
        #expect(content.shareRefusal("Couldn’t share it. Forbidden.", scope: .group, on: Self.studio) == "Couldn’t share it. Forbidden.")
        #expect(content.reachNote(on: TeamsSample.lab) == nil)
        #expect(content.shareRefusal("Couldn’t share it. Forbidden.", scope: .server, on: TeamsSample.lab) == "Couldn’t share it. Forbidden.")
        // A member who isn't an admin knows the limit from what the relay tells every member.
        content.servers[1].knowledgeWidest = .friend
        #expect(content.reachNote(on: TeamsSample.lab) == "lab lets knowledge reach one friend at most.")
    }

    @Test func deletingAGroupSaysLosesForOneMember() {
        let one = MultiplayerGroup(id: "g", name: "Solo", owner: "ryan", members: ["ryan"])
        let three = MultiplayerGroup(id: "g", name: "Crew", owner: "ryan", members: ["ryan", "mira", "sam"])
        #expect(TeamsGroupsPage.deleteQuestion(one) == "Delete Solo? Its 1 member loses every grant made to the group.")
        #expect(TeamsGroupsPage.deleteQuestion(three) == "Delete Crew? Its 3 members lose every grant made to the group.")
    }

    @Test func completingACardWritesItsResultAndReleasesItsClaim() async throws {
        let state = Self.preview(TeamsSample.relayPlace)
        let card = try #require(state.content.card("card-3", in: Self.relay))
        Self.send(state, .openCard("card-3", workspace: Self.relay))
        state.state.drafts.cardResult = "  Done on collab/lease-timer.  "
        Self.send(state, .completeCard(card, workspace: Self.relay))
        await Self.settle(state)
        let done = state.content.card("card-3", in: Self.relay)
        #expect(done?.known == .done && done?.result == "Done on collab/lease-timer.")
        #expect(state.content.workspace(Self.relay)?.workspace.claims.contains { $0.key == "card-3" } == false)
        #expect(state.state.notice == "Completed. Its claim is released." && state.state.drafts.cardResult.isEmpty)
    }

    @Test func releasingAskFirstAndNamesTheClaim() async throws {
        let state = Self.preview(TeamsSample.relayPlace)
        let claim = try #require(state.content.workspace(Self.relay)?.workspace.claims.first { $0.id == "cl-3" })
        Self.send(state, .askRelease(claim, workspace: Self.relay))
        #expect(state.state.selection.confirming == .releaseClaim(claim: "cl-3", workspace: Self.relay))
        #expect(state.content.workspace(Self.relay)?.workspace.claims.count == 4, "nothing is released before the second press")
        Self.send(state, .cancelConfirmation)
        #expect(state.state.selection.confirming == nil)
        Self.send(state, .askRelease(claim, workspace: Self.relay), .confirm)
        await Self.settle(state)
        #expect(state.content.workspace(Self.relay)?.workspace.claims.map(\.id) == ["cl-1", "cl-2", "cl-4"])
        #expect(state.content.card("card-3", in: Self.relay)?.known == .open)
    }

    @Test func anOverlappingClaimIsRefusedAndItsHolderIsMarked() async {
        let state = Self.preview(TeamsSample.relayPlace)
        Self.send(state, .startClaim(workspace: Self.relay))
        state.state.drafts.claim = MultiplayerClaimDraft(kind: .paths, key: "Sources/Relay", agent: "relay-worker")
        Self.send(state, .sendClaim)
        await Self.settle(state) { state.state.refusal != nil }
        #expect(state.state.refusal == "Couldn’t claim it. sam holds it with the agent sam-claude, under the paths claim Sources/Relay/Lease.")
        #expect(state.state.selection.conflict == "cl-2" && state.state.selection.composer == .claim(workspace: Self.relay))
        // Another path is free: the form closes and the claim is listed.
        state.state.drafts.claim.key = "Docs"
        Self.send(state, .sendClaim)
        await Self.settle(state) { state.state.selection.composer == nil }
        #expect(state.state.selection.conflict == nil && state.content.workspace(Self.relay)?.workspace.claims.last?.holder == "ryan/relay-worker")
        #expect(TeamsPreviewState.overlaps("a/b", "a") && !TeamsPreviewState.overlaps("ab", "a"))
    }

    @Test func theMergeRunsOnlyAfterItsConfirmation() async {
        let state = Self.preview(TeamsSample.relayPlace)
        Self.send(state, .startQueue(workspace: Self.relay), .chooseCheckout)
        state.state.drafts.queue.branch = "collab/fuzz"
        state.state.drafts.queue.testText = "make fuzz"
        #expect(state.state.drafts.queue.checkout == NetworkSample.checkout)
        Self.send(state, .sendQueue)
        await Self.settle(state) { state.state.selection.composer == nil }
        #expect(state.content.queue[Self.relay]?.map(\.branch).last == "collab/fuzz")

        Self.send(state, .askMerge(workspace: Self.relay))
        #expect(state.state.selection.confirming == .merge(workspace: Self.relay))
        #expect(state.content.queue[Self.relay]?.filter(\.isQueued).count == 3, "nothing merges before the second press")
        Self.send(state, .confirm)
        await Self.settle(state) { state.state.notice != nil }
        #expect(state.content.queue[Self.relay]?.map(\.state) == ["merged", "merged", "failed", "merged"])
        #expect(state.state.notice == "Merged 2 branches into main. collab/lease-timer wasn’t merged: its tests failed.")
        #expect(state.content.merging.isEmpty)
        #expect(TeamsIntegrationBand.test(MultiplayerQueueEntry(workspace: "w", branch: "b")) == "no test command")
    }

    @Test func groupsAreCreatedChangedAndDeletedAfterAConfirmation() async {
        let state = Self.preview(TeamsPlace.groups)
        Self.send(state, .newGroup(server: Self.studio))
        state.state.drafts.groupName = " Launch crew "
        Self.send(state, .createGroup)
        await Self.settle(state) { state.state.selection.composer == nil }
        let key = TeamsKey.make("g-12", on: Self.studio)
        #expect(state.content.group(key)?.group.name == "Launch crew" && state.state.selection.group == key)
        Self.send(state, .addMember("mira", group: key))
        await Self.settle(state)
        #expect(state.content.group(key)?.group.members == ["ryan", "mira"])
        Self.send(state, .askRemoveMember("mira", group: key))
        #expect(state.content.group(key)?.group.members.count == 2)
        Self.send(state, .confirm)
        await Self.settle(state)
        #expect(state.content.group(key)?.group.members == ["ryan"])
        Self.send(state, .askDeleteGroup(key), .confirm)
        await Self.settle(state) { state.content.group(key) == nil }
        #expect(state.state.selection.group == nil && state.state.notice == "Deleted Launch crew.")
    }

    @Test func aHostRunBringsBackItsExitCodeAndOutput() async {
        let state = Self.preview(TeamsPlace.hosts)
        let key = TeamsKey.make("host-build", on: Self.studio)
        Self.send(state, .runHost(resource: "host-build", server: Self.studio))
        await Self.settle(state) { state.state.hostRuns[key] != nil }
        let row = state.pages(go: { _ in }).content.offeredHostRows.first { $0.id == key }
        #expect(row?.run?.exitCode == 0 && row?.run?.output.contains("PASS") == true && row?.commands == ["make-integration", "docker-build"])
        state.state.drafts.hostRun.argumentText = "--fail"
        Self.send(state, .runHost(resource: "host-build", server: Self.studio))
        await Self.settle(state) { MultiplayerHostRun(state.state.hostRuns[key]?.value)?.exitCode == 1 }
        #expect(MultiplayerHostRun(state.state.hostRuns[key]?.value)?.succeeded == false)
        // Choosing a host starts from its first enrolled command.
        Self.send(state, .openHost(TeamsKey.make("host-rack", on: Self.studio)))
        #expect(state.state.drafts.hostRun.command == "run-ios-ui-tests")
    }

    @Test func sharingKnowledgeRefusesASecretAndAScopeThePolicyDoesNotAllow() async {
        let state = Self.preview(TeamsPlace.knowledge)
        Self.send(state, .startShare(server: Self.studio))
        #expect(state.state.drafts.knowledge.scope == .private, "the draft starts at the relay's default")
        state.state.drafts.knowledge.name = "deploy notes"
        state.state.drafts.knowledge.content = "token = ghp_abcdefghijklmnopqrstuvwxyz123456"
        #expect(state.state.drafts.knowledge.secretProblem == MultiplayerSecretCheck.refusal && !state.state.drafts.knowledge.canSend)
        Self.send(state, .sendShare)
        #expect(state.content.server(Self.studio)?.knowledge.count == 4, "a secret is never sent")

        state.state.drafts.knowledge.content = "Use ${DEPLOY_TOKEN}."
        state.state.drafts.knowledge.scope = .server
        Self.send(state, .sendShare)
        await Self.settle(state) { state.state.refusal != nil }
        #expect(state.state.refusal == "Couldn’t share it. studio lets knowledge reach a group at most.")
        #expect(state.state.selection.composer == .knowledge(server: Self.studio))

        state.state.drafts.knowledge.scope = .group
        state.state.drafts.knowledge.target = "g-relay"
        Self.send(state, .sendShare)
        await Self.settle(state) { state.state.selection.composer == nil }
        #expect(state.content.server(Self.studio)?.knowledge.first?.visibility == "group:g-relay")
        #expect(state.state.notice == "Shared deploy notes on studio." && state.content.widestScope(on: TeamsSample.lab) == .server)
    }

    @Test func installAsksFirstAndNamesTheDestination() async throws {
        let state = Self.preview(TeamsPlace.knowledge)
        let skill = try #require(state.content.item(TeamsKey.make("k-1", on: Self.studio))?.item)
        Self.send(state, .askInstall(skill, server: Self.studio))
        guard case .install(let draft)? = state.state.selection.confirming else { Issue.record("no confirmation"); return }
        #expect(draft.shownDestination == "~/.claude/skills/relay-triage/SKILL.md" && draft.question == "Install relay-triage as a skill?")
        Self.send(state, .confirm)
        await Self.settle(state) { state.state.notice != nil }
        #expect(state.state.notice == "Installed relay-triage at ~/.claude/skills/relay-triage/SKILL.md.")

        // An MCP item names the file that was chosen and the placeholders it fills.
        let mcp = try #require(state.content.item(TeamsKey.make("k-3", on: Self.studio))?.item)
        Self.send(state, .askInstall(mcp, server: Self.studio))
        guard case .install(let file)? = state.state.selection.confirming else { Issue.record("no confirmation"); return }
        #expect(file.destination == .file(path: TeamsSample.mcpFile) && file.placeholders == ["GITHUB_TOKEN"])
    }

    @Test func searchingAndEndorsing() async {
        let state = Self.preview()
        state.state.drafts.query = "  build "
        Self.send(state, .search)
        #expect(state.state.search == .loading && state.state.selection.searchServer == Self.studio)
        await Self.settle(state) { state.state.search?.value != nil }
        #expect(state.state.search?.value?.resources.count == 3 && state.state.search?.value?.query == "build")
        let key = TeamsKey.make("host-rack", on: Self.studio)
        Self.send(state, .openHit(key))
        state.state.drafts.skill = "ios"
        Self.send(state, .endorse(resource: "host-rack", server: Self.studio))
        await Self.settle(state) { state.state.notice != nil }
        #expect(state.state.search?.value?.resources.last?.endorsements == [MultiplayerEndorsement(handle: "ryan", skill: "ios")])
        #expect(state.state.drafts.skill.isEmpty && state.state.notice == "You endorsed it for ios on studio.")
        // A search for nothing says so.
        state.state.drafts.query = "zz"
        Self.send(state, .search)
        await Self.settle(state) { state.state.search?.value?.query == "zz" }
        #expect(state.state.search?.value?.isEmpty == true && state.pages(go: { _ in }).content.readouts(for: TeamsPlace.directory)[0].value == "0")
    }

    @Test func adminChangesAreConfirmedAndNameTheirTarget() async {
        let state = Self.preview(TeamsPlace.admin)
        Self.send(state, .askSetPolicy(server: Self.studio))
        #expect(state.state.selection.confirming == nil, "an unchanged policy has nothing to confirm")
        state.state.drafts.policy.retentionDays = "90"
        Self.send(state, .askSetPolicy(server: Self.studio))
        #expect(state.state.selection.confirming == .setPolicy(server: Self.studio))
        #expect(state.content.server(Self.studio)?.policy?.retentionDays == 30)
        Self.send(state, .confirm)
        await Self.settle(state) { state.state.notice != nil }
        #expect(state.content.server(Self.studio)?.policy?.retentionDays == 90 && state.state.notice == "Policy set on studio.")

        Self.send(state, .askSuspend("tomas", server: Self.studio))
        #expect(state.state.selection.confirming == .suspend(handle: "tomas", server: Self.studio))
        #expect(state.content.memberRows(on: Self.studio).first { $0.member.handle == "tomas" }?.member.isSuspended == false)
        Self.send(state, .confirm)
        await Self.settle(state) { state.content.server(Self.studio)?.devices.count == 2 }
        #expect(state.content.memberRows(on: Self.studio).first { $0.member.handle == "tomas" }?.member.isSuspended == true)
        Self.send(state, .unsuspend("priya", server: Self.studio))
        await Self.settle(state) { state.content.server(Self.studio)?.members.filter(\.isSuspended).count == 1 }
        Self.send(state, .askRevoke("dev-7f3a", server: Self.studio), .confirm)
        await Self.settle(state) { state.content.server(Self.studio)?.devices.count == 1 }
        #expect(state.content.server(Self.studio)?.devices.map(\.id) == ["dev-22c1"])
        #expect(state.content.memberRows(on: Self.studio).first?.isYou == true && state.content.isAdmin)
    }

    @Test func aHostThatFinishedPutsItsFormAwayAndReports() {
        let state = TeamsPagesState()
        state.selection.composer = .claim(workspace: Self.relay)
        state.hostFinished(.claim(workspace: Self.relay), .failed(id: "", server: Self.studio, reason: "Refused."))
        #expect(state.selection.composer != nil && state.failure == nil, "a refusal stays on the host")
        state.hostFinished(.claim(workspace: Self.relay), .done(id: "cl-9", server: Self.studio, message: "Claimed #9."))
        #expect(state.selection.composer == nil && state.notice == "Claimed #9.")
        state.selection.card = "x"
        state.hostFinished(.card("c", workspace: Self.relay), .done(id: "c", server: Self.studio, message: nil))
        #expect(state.selection.card == "x", "the card host stays open")
        state.hostCancelled(.card("c", workspace: Self.relay))
        #expect(state.selection.card == nil)
    }

    // MARK: Fit

    /// Every Teams page and the states a click reaches fit the default window and the wider one.
    @Test func everyTeamsPageFitsTheWindow() {
        _ = NSApplication.shared
        for size in [NetworkFitTests.window, ShellRenderTests.size] {
            for (name, scenario, state) in TeamsRenderTests.states() {
                let host = NSHostingController(rootView: TeamsRenderTests.shell(scenario, state: state)
                    .environment(\.theme, .console).environment(\.reduceTransparencyOverride, true)
                    .environment(\.networkPageScrollsSideways, false))
                let width = host.sizeThatFits(in: size).width
                #expect(width <= size.width, "\(name) asks for \(width) pt at \(size.width)")
            }
        }
    }
}

// The increment 4 running-window defects (design/demos/main-window-4/verify/REPORT.md).
@MainActor @Suite struct MainWindowFourDefectTests {
    static func subviews(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + subviews(of: $0) } }

    /// Presence is one element of its own: a menu button named "Your presence" whose value is the
    /// presence in force, with a check beside the choice in force.
    @Test func presenceIsAMenuButtonWithItsValue() throws {
        _ = NSApplication.shared
        var picked: MultiplayerPresenceChoice?
        let profile = CommanderProfile(name: "Ryan", handle: "ryan", presence: .busy, choice: .auto)
        let host = NSHostingView(rootView: ShellToolbarReadouts(part: .presence, servers: CommanderServerHealth(online: 2, total: 3),
                                                                profile: profile, openServers: {}, pickPresence: { picked = $0 })
            .environment(\.theme, .console))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let button = try #require(Self.subviews(of: host).compactMap { $0 as? NSPopUpButton }.first)
        // An AppKit control's element is its cell.
        let cell = try #require(button.cell)
        #expect(button.pullsDown && cell.isAccessibilityElement(), "role \(String(describing: cell.accessibilityRole()))")
        #expect(cell.accessibilityRole() == .menuButton || cell.accessibilityRole() == .popUpButton)
        #expect(cell.accessibilityLabel() == "Your presence", "label \(String(describing: cell.accessibilityLabel()))")
        #expect(cell.accessibilityValue() as? String == "Auto: Busy", "value \(String(describing: cell.accessibilityValue()))")
        #expect(button.accessibilityIdentifier() == "shell-presence")
        // It covers the readout, so a press on the readout is a press on it.
        #expect(button.frame.width > 40 && button.frame.height > 20)
        let choices = Array(button.itemArray.dropFirst())
        #expect(choices.map(\.title) == MultiplayerPresenceChoice.allCases.map(\.title))
        #expect(choices.filter { $0.state == .on }.map(\.title) == [MultiplayerPresenceChoice.auto.title])
        let away = try #require(choices.first { $0.representedObject as? String == MultiplayerPresenceChoice.away.rawValue })
        _ = away.target?.perform(away.action, with: away)
        #expect(picked == .away)
        window.contentView = nil
    }

    static let twoApprovals = MultiplayerFixture.output(#"""
    {"ok":true,"data":{"approvals":[
      {"id":"ap-1","peer":"fixture-bo","resource":"res-1","action":"git.push","summary":"{\"text\":\"push the fix\"}",
       "arrived":"2026-11-23T11:58:00Z","expires":"2026-11-24T11:58:00Z"},
      {"id":"ap-2","peer":"fixture-cy","resource":"res-1","action":"git.push","summary":"{\"text\":\"push the docs\"}",
       "arrived":"2026-11-23T11:59:00Z","expires":"2026-11-24T11:59:00Z"}]}}
    """#)

    /// One row approved and one denied, then a refresh that no longer lists either: for the
    /// network's hold both rows stay with their outcome, in Approvals and in Needs you, neither
    /// counts down, and every count says nothing waits. The test ends the hold by hand: a hold on
    /// the clock runs out before the checks on a slow machine, and the rows are gone.
    @Test func approvedAndDeniedRowsKeepTheirOutcomeForTheHold() async throws {
        let hold = MultiplayerManualHold()
        let (model, helper) = MultiplayerAnsweredRowTests.model(
            [.approvals: [Self.twoApprovals, MultiplayerAnsweredRowTests.noApprovals],
             .approve: [MultiplayerShareFixture.empty], .deny: [MultiplayerShareFixture.empty]],
            hold: MultiplayerShareModel.answeredHold, holdTimer: hold.timer)
        model.open()
        await model.settle()
        defer { model.close() }
        let listed = model.share.pendingApprovals
        #expect(listed.map(\.item.id) == ["ap-1", "ap-2"])
        let state = NetworkPagesLiveState()
        let before = NetworkPagesContent(model: model, state: state)
        #expect(before.approvalRows.allSatisfy { $0.answer == nil && $0.expiresIn != nil })
        #expect(ShellNetwork(model: model).waitingApprovals.count == 2)

        #expect(await model.decide(listed[0].item, on: listed[0].server, approve: true).isDone)
        #expect(await model.decide(listed[1].item, on: listed[1].server, approve: false).isDone)
        // The refresh after the answers no longer lists them.
        await model.settle()
        #expect(helper.count(.approvals) >= 2 && helper.count(.approve) == 1 && helper.count(.deny) == 1)

        // Approvals: both rows, each with its outcome, and no countdown.
        let content = NetworkPagesContent(model: model, state: state)
        let rows = content.approvalRows.sorted { $0.approval.id < $1.approval.id }
        #expect(rows.map(\.approval.id) == ["ap-1", "ap-2"] && rows.map(\.answer) == [.approved, .denied])
        #expect(rows.allSatisfy { $0.expiresIn == nil && $0.waiting == nil })
        // "Waiting on you" and the telemetry count the same rows: none.
        #expect(rows.filter { $0.answer == nil }.count == model.share.waitingApprovals.count && model.share.waitingApprovals.isEmpty)
        #expect(content.readouts(for: NetworkPlace.approvals).first { $0.id == "approvals" }?.value == "0")
        #expect(!content.readouts(for: NetworkPlace.approvals).contains { $0.id == "soonest" })

        // Needs you and the navigation read the same rows and the same counts.
        let network = ShellNetwork(model: model)
        #expect(network.approvals.count == 2 && network.waitingApprovals.isEmpty && network.waitingAccess.count == model.share.waitingAccess.count)
        let inbox = LiveShell.inbox(pending: [], network: network, now: model.currentDate())
        let items = inbox.items.filter { $0.kind == .networkApproval }.sorted { $0.id < $1.id }
        #expect(items.map(\.decision) == [.approved, .denied] && items.allSatisfy { $0.expiresIn == nil })
        #expect(inbox.pendingCount(of: .networkApproval) == 0)
        let navigation = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: LiveShell.approvals,
                                              needsYou: inbox.pendingCount, network: network)
        #expect(navigation.place(LiveShell.approvals)?.count == 0)

        // Leaving the page and coming back changes nothing while the hold lasts.
        state.open(.home)
        #expect(NetworkPagesContent(model: model, state: state).approvalRows.map(\.answer).count == 2)

        // The hold ends, and both rows leave.
        await hold.end(in: model)
        #expect(hold.asked == [MultiplayerShareModel.answeredHold, MultiplayerShareModel.answeredHold])
        #expect(NetworkPagesContent(model: model, state: state).approvalRows.isEmpty && model.share.pendingApprovals.isEmpty)
    }

    /// The Threads strip counts the comments its rows count.
    @Test func theThreadsStripAgreesWithItsRows() {
        var content = NetworkSample.content
        let summaries: [MultiplayerThreadSummary] = NetworkSample.decode("""
        [{"request":"ho-1","resource":"res-relay","action":"agent.handoff","title":"Retry budget","direction":"sent","comments":2},
         {"request":"ho-2","resource":"res-relay","action":"agent.handoff","title":"Lease","direction":"sent","comments":3},
         {"request":"ho-3","resource":"res-relay","action":"agent.handoff","title":"Docs","direction":"sent"}]
        """)
        #expect(summaries.count == 3)
        content.threads = [NetworkSample.studio: summaries]
        content.thread = .loading
        let cells = content.readouts(for: NetworkPlace.threads)
        #expect(cells.map(\.label) == ["requests", "comments", "in the open thread", "from agents"])
        #expect(cells.map(\.value) == ["3", "5", "0", "0"])
        #expect(content.threadRows.map(\.state).sorted() == ["", "2 comments", "3 comments"])
    }
}

// The merge queue's figures (TeamsPagesWorkspace.swift): the tab, the readout and the heading agree.
@MainActor @Suite struct TeamsQueueCountTests {
    @Test func theHeadingCountsWhatTheTabAndTheReadoutCount() async {
        #expect(TeamsIntegrationBand.queueCount(queued: 4, of: 4) == "4")
        #expect(TeamsIntegrationBand.queueCount(queued: 2, of: 4) == "2 queued of 4")
        #expect(TeamsIntegrationBand.queueCount(queued: 0, of: 3) == "0 queued of 3")
        #expect(TeamsIntegrationBand.queueCount(queued: 0, of: 0) == "0")

        // In the sample, the readout's figure is the heading's first figure before and after a merge.
        let state = TeamsPagesTests.preview(TeamsPlace.workspace("ws-relay", on: TeamsPagesTests.studio))
        func figures() -> (readout: String?, heading: String) {
            let content = state.pages(go: { _ in }).content, entries = content.queue[TeamsPagesTests.relay] ?? []
            let place = TeamsPlace.workspace("ws-relay", on: TeamsPagesTests.studio)
            return (content.readouts(for: place).first { $0.id == "queue" }?.value,
                    TeamsIntegrationBand.queueCount(queued: entries.filter(\.isQueued).count, of: entries.count))
        }
        let before = figures()
        #expect(before.readout != nil && before.heading.hasPrefix(before.readout ?? "?"))
    }
}

// A table cell's second line (NetworkPageMolecules.swift). Laid out, never drawn.
@MainActor @Suite struct ShellCellTextTests {
    static func height(_ wraps: Bool, width: CGFloat) -> CGFloat {
        let cell = ShellCellText(title: "Retry budget", detail: "Skill, by fixture-sam on studio", detailWraps: wraps)
        return NSHostingView(rootView: cell.frame(width: width, alignment: .leading)).fittingSize.height
    }

    /// At the width the knowledge table's item column has in a 1280 pt window with the inspector
    /// open, the second line wraps onto another line and isn't cut short.
    @Test func aKnowledgeRowsSecondLineWrapsInANarrowColumn() {
        let cut = Self.height(false, width: 110), wrapped = Self.height(true, width: 110)
        #expect(wrapped > cut, "the wrapped line takes the height it needs")
        // With room, it stays on one line and the row keeps its height.
        #expect(Self.height(true, width: 400) == Self.height(false, width: 400))
    }
}

// The live binding (TeamsPagesLive.swift), against the teams fixture. No test reaches a network.
@MainActor @Suite struct TeamsPagesLiveTests {
    @Test func theLivePagesReadAndActWithoutMovingTheTray() async throws {
        let (model, _) = await MultiplayerTeamsFixture.model { call in
            guard call.verb == .relay else { return nil }
            switch (call.method, call.path) {
            case ("POST", "/v1/workspaces/ws-1/claims"):
                return call.body?["key"] == .string("Sources/Relay") ? "!relay HTTP 409: already claimed by fixture-bo/bo-agent" : #"{"id":"cl-9"}"#
            default: return nil
            }
        }
        defer { model.close() }
        // The tray is somewhere else entirely, and stays there.
        model.go(.hosting)
        let home = MultiplayerTeamsFixture.home
        let key = TeamsKey.make("ws-1", on: home), place = TeamsPlace.workspace("ws-1", on: home)
        let live = TeamsPagesLiveState()

        // Before the window's own read the board says it is being read; after it, it has the cards.
        #expect(live.content(model).readingCards.contains(key))
        await live.read(place: place, model: model)
        let content = live.content(model)
        #expect(content.cards[key]?.map(\.id) == ["card-1", "card-2", "card-3"] && !content.readingCards.contains(key))
        #expect(content.workspace(key)?.server.handle.isEmpty == false && content.title(for: place) == content.workspace(key)?.workspace.name)
        #expect(content.servers.map(\.id).contains(home) && content.groupRows.count == model.share.teams.allGroups.count)
        #expect(model.share.teams.cards == .loading, "the tray's own board is not read")

        // A refused claim comes back for the form that sent it, with the holder the relay named.
        let actions = live.actions(model, share: { _, _ in }, requestAccess: { _, _ in })
        live.pages.send(.startClaim(workspace: key), in: content, through: actions, go: { _ in })
        live.pages.drafts.claim = MultiplayerClaimDraft(kind: .paths, key: "Sources/Relay", agent: "relay-worker")
        live.pages.send(.sendClaim, in: content, through: actions, go: { _ in })
        for _ in 0..<400 where live.pages.refusal == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(live.pages.refusal?.contains("fixture-bo/bo-agent") == true && live.pages.selection.composer == .claim(workspace: key))

        // The model's own hosts are built for every hosted form.
        let host = live.host(model)
        for hosted in [TeamsHosted.workspace(server: home), .claim(workspace: key), .card("card-1", workspace: key), .queue(workspace: key),
                       .knowledge(server: home), .hostRun(resource: TeamsKey.make("dir-h", on: home)), .policy(server: home)] {
            _ = host(hosted)
        }
        #expect(model.route == .hosting, "nothing the window did moved the tray")
    }

    /// The window's own reads of what the relay added for it: the combined view, the workspace's
    /// owner, what a member may share, and an admin's members and devices. Against the fixture.
    @Test func theLivePagesReadTheRosterTheCombinedViewAndTheOwner() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-teams")
        defer { model.close() }
        let home = MultiplayerRemoteTests.home, tray = model.route
        let live = TeamsPagesLiveState()
        let relay = TeamsKey.make("ws-relay", on: home), ios = TeamsKey.make("ws-ios", on: home)
        let actions = live.actions(model, share: { _, _ in }, requestAccess: { _, _ in })
        func send(_ intent: TeamsIntent, from place: String) {
            live.pages.send(intent, in: live.pages.shown(live.content(model), place: place), through: actions, go: { _ in }, from: place)
        }
        func settle(_ done: @MainActor () -> Bool) async {
            for _ in 0..<400 where !done() || !live.pages.results.running.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        }

        // Combined view: every claim the relay lists for the workspace is on a worker's row, and
        // nothing is made up for a branch or for checks.
        await live.read(place: TeamsPlace.workspace("ws-relay", on: home), model: model)
        var content = live.content(model)
        let listed = try #require(content.workspace(relay)).workspace.claims
        let rows = content.combinedRows(in: relay)
        #expect(Set(rows.compactMap(\.worker).flatMap(\.claims).map(\.id)) == Set(listed.map(\.id)))
        #expect(rows.compactMap(\.worker).allSatisfy { $0.branch.isEmpty && $0.checks == nil })
        #expect(rows.first { $0.isMine }?.worker?.capabilities.harness == "claude")

        // Owner: you own ws-relay, so you edit it and can't leave it. ws-ios is someone else's.
        #expect(content.workspace(relay)?.workspace.isOwned(by: content.handle(on: home)) == true)
        #expect(content.workspace(ios)?.workspace.isOwned(by: content.handle(on: home)) == false)
        send(.askLeave(workspace: relay), from: TeamsPlace.workspace("ws-relay", on: home))
        #expect(live.pages.selection.confirming == nil)
        send(.startEdit(workspace: relay), from: TeamsPlace.workspace("ws-relay", on: home))
        live.pages.drafts.workspace.goal = "Ship the relay"
        send(.askSaveWorkspace, from: TeamsPlace.workspace("ws-relay", on: home))
        #expect(live.pages.selection.confirming == .saveWorkspace(workspace: relay))
        send(.confirm, from: TeamsPlace.workspace("ws-relay", on: home))
        await settle { live.pages.selection.composer == nil }
        #expect(model.share.teams.workspace("ws-relay", on: home)?.goal == "Ship the relay")

        // Knowledge: yours are counted by handle, and the relay's limit is known to a member.
        await live.read(place: TeamsPlace.knowledge, model: model)
        content = live.content(model)
        #expect(content.knownWidestScope(on: home) == .server)
        let mine = content.knowledgeRows.filter(\.isMine).count
        #expect(mine == content.knowledgeRows.filter { $0.item.ownerHandle == content.handle(on: $0.server) }.count)
        #expect(content.knowledgeRows.allSatisfy { !TeamsPagesContent.owner(of: $0.item).hasPrefix("u-") })

        // Admin: the members and devices come from the relay's list, and a suspension shows in it.
        await live.read(place: TeamsPlace.admin, model: model)
        content = live.content(model)
        let server = try #require(content.server(home))
        let saved = try #require(server.policy)
        #expect(server.adminProblem == nil && live.pages.drafts.policy == MultiplayerPolicyDraft(saved))
        #expect(server.members.count >= 2 && server.devices.allSatisfy { $0.name == $0.id })
        let other = try #require(content.memberRows(on: home).first { !$0.isYou && !$0.member.isSuspended })
        send(.askSuspend(other.member.handle, server: home), from: TeamsPlace.admin)
        #expect(live.content(model).server(home)?.members.first { $0.id == other.member.id }?.isSuspended == false, "nothing before the second press")
        send(.confirm, from: TeamsPlace.admin)
        await settle { live.content(model).server(home)?.members.first { $0.id == other.member.id }?.isSuspended == true }
        #expect(live.content(model).server(home)?.members.first { $0.id == other.member.id }?.isSuspended == true)
        // What Admin said stays on Admin.
        #expect(live.pages.shown(live.content(model), place: TeamsPlace.admin).notice != nil)
        #expect(live.pages.shown(live.content(model), place: TeamsPlace.groups).notice == nil)
        #expect(model.route == tray, "nothing the window did moved the tray")
    }

    /// A saved policy is confirmed in one band, on Admin alone.
    @Test func aSavedPolicyIsConfirmedOnAdminAlone() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("pages-live-policy")
        defer { model.close() }
        let home = MultiplayerRemoteTests.home, tray = model.route
        let live = TeamsPagesLiveState()
        let actions = live.actions(model, share: { _, _ in }, requestAccess: { _, _ in })
        func send(_ intent: TeamsIntent) {
            live.pages.send(intent, in: live.pages.shown(live.content(model), place: TeamsPlace.admin), through: actions, go: { _ in },
                            from: TeamsPlace.admin)
        }
        await live.read(place: TeamsPlace.admin, model: model)
        let saved = try #require(live.content(model).server(home)?.policy)
        let days = saved.retentionDays == 90 ? 60 : 90
        live.pages.drafts.policy.retentionDays = String(days)
        send(.askSetPolicy(server: home))
        #expect(live.pages.selection.confirming == .setPolicy(server: home))
        send(.confirm)
        for _ in 0..<400 where live.pages.notice == nil && live.pages.failure == nil || !live.pages.results.running.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let name = try #require(model.server(home)?.displayName)
        #expect(live.pages.failure == nil && live.content(model).server(home)?.policy?.retentionDays == days)
        #expect(live.pages.shown(live.content(model), place: TeamsPlace.admin).notice == "Policy set on \(name).")
        #expect(live.pages.shown(live.content(model), place: TeamsPlace.groups).notice == nil)
        // Leaving Admin takes the band with it.
        live.pages.left(TeamsPlace.admin)
        #expect(live.pages.shown(live.content(model), place: TeamsPlace.admin).notice == nil)
        #expect(model.route == tray, "nothing the window did moved the tray")
    }
}
