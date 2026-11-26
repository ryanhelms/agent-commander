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
        #expect(shown?.result?.reason == "Couldn’t claim it. Overlapping claim held by sam/sam-codex.")
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
        #expect(state.state.refusal == "Couldn’t claim it. Overlapping claim held by sam/sam-claude.")
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
    /// counts down, and every count says nothing waits.
    @Test func approvedAndDeniedRowsKeepTheirOutcomeForTheHold() async throws {
        let (model, helper) = MultiplayerAnsweredRowTests.model(
            [.approvals: [Self.twoApprovals, MultiplayerAnsweredRowTests.noApprovals],
             .approve: [MultiplayerShareFixture.empty], .deny: [MultiplayerShareFixture.empty]], hold: .seconds(5))
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
