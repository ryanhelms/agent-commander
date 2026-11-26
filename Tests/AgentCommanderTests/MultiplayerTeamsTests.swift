import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Teams (design/COMMANDER-NETWORK-INCREMENT-5.md): groups, workspaces and claims, the board, the
// merge queue, hosts, the knowledge library, reputation, the directory search and relay policy.
// Every handle, resource and path here is made up. No test reaches a network or the real helper.

/// Answers each helper call from a closure and keeps what was asked.
final class RoutedMultiplayerHelper: MultiplayerHelper {
    struct Call: Sendable {
        let verb: MultiplayerVerb
        let input: MultiplayerJSON

        var method: String { input.firstText("method") ?? "" }
        var path: String { input.firstText("path") ?? "" }
        var body: MultiplayerJSON? { input["body"] }
    }

    private let calls = Mutex<[Call]>([])
    private let route: @Sendable (Call) -> String?

    /// `route` returns the reply's `data` as JSON text, "!message" for a refusal, or nil for `{}`.
    init(_ route: @escaping @Sendable (Call) -> String?) { self.route = route }

    func run(verb: MultiplayerVerb, input: Data) async throws -> MultiplayerHelperOutput {
        let call = Call(verb: verb, input: (try? JSONDecoder().decode(MultiplayerJSON.self, from: input)) ?? .null)
        calls.withLock { $0.append(call) }
        let reply = route(call) ?? "{}"
        if reply.hasPrefix("!") {
            let message = String(data: try JSONEncoder().encode(String(reply.dropFirst())), encoding: .utf8) ?? "\"\""
            return MultiplayerFixture.output(#"{"ok":false,"error":\#(message)}"#)
        }
        return MultiplayerFixture.output(#"{"ok":true,"data":\#(reply)}"#)
    }

    var all: [Call] { calls.withLock { $0 } }
    func last(_ verb: MultiplayerVerb) -> Call? { all.last { $0.verb == verb } }
    func relays(_ method: String) -> [Call] { all.filter { $0.verb == .relay && $0.method == method } }
}

enum MultiplayerTeamsFixture {
    static let home = "s-home"

    static let servers = #"{"servers":[{"id":"s-home","url":"https://relay.example.test","name":"home","favorite":false,"autoConnect":true,"pin":"","lastUsedAt":"2026-11-25T12:00:00Z","state":"online","signedIn":true,"handle":"fixture-ada","lastSeen":"2026-11-25T12:00:00Z","error":""}]}"#

    static let status = #"""
    {"online":true,"signedIn":true,"handle":"fixture-ada",
     "friends":[{"handle":"fixture-bo","user":"u-bo"},{"handle":"fixture-cy","user":"u-cy"}],
     "resources":[{"id":"res-9","name":"tests","kind":"agent","actions":["agent.ask","agent.handoff"]},
                  {"id":"res-h","name":"studio","kind":"host","actions":["host.run"]}],
     "grants":[],
     "directory":[
       {"id":"dir-h","owner":"u-bo","handle":"fixture-bo","kind":"host","name":"bo-mini","actions":["host.run"],
        "grantedActions":["host.run"],"capabilities":{"tools":["ui-tests","build"],"environments":["ios-simulator"]},
        "endorsements":[{"handle":"fixture-cy","skill":"ui tests"},{"skill":"ui tests","handle":"fixture-dee"},{"handle":"x"}]},
       {"id":"dir-g","owner":"u-cy","handle":"fixture-cy","kind":"host","name":"cy-gpu","actions":["host.run"],"grantedActions":[]}]}
    """#

    static let groups = #"{"groups":[{"id":"grp-1","name":"relay-team","owner":"u-ada","ownerHandle":"fixture-ada","members":["fixture-ada","fixture-bo"]},{"id":"grp-2","name":"ios","owner":"u-cy","ownerHandle":"fixture-cy","members":["fixture-cy","fixture-ada"]},{"name":"no id"}]}"#

    static let workspaces = #"{"workspaces":[{"id":"ws-1","owner":"u-ada","group":"grp-1","name":"Reconnect","goal":"Survive renewals","repository":"github.com/example/relay","base":"main","integration":"queue","claims":[{"id":"cl-1","kind":"paths","key":"Sources/Relay","holder":"fixture-bo/bo-agent","expiresAt":"2026-11-25T13:00:00Z"},{"id":"cl-2","kind":"card","key":"card-2","holder":"fixture-ada/tests","expiresAt":"0001-01-01T00:00:00Z"},{"kind":"issue"}]}]}"#

    static let cards = #"{"cards":[{"id":"card-1","title":"Bound the wait","body":"","state":"open","assignee":"","result":""},{"id":"card-2","title":"Key waiters","body":"","state":"claimed","assignee":"fixture-ada/tests","result":""},{"id":"card-3","title":"Repro","body":"","state":"done","assignee":"fixture-bo/bo-agent","result":"Done on `x`."},{"title":"no id"}]}"#

    static let knowledge = #"{"items":[{"id":"kn-1","owner":"u-bo","kind":"skill","name":"triage","content":"Triage steps","visibility":"group:grp-1","version":3,"createdAt":"2026-11-25T10:00:00Z"},{"id":"kn-2","owner":"u-ada","kind":"mcp","name":"gh","content":"{\"env\":{\"GITHUB_TOKEN\":\"${GITHUB_TOKEN}\",\"ORG\":\"${ORG}\"}}","visibility":"server","version":1,"createdAt":"2026-11-25T09:00:00Z"}]}"#

    static let queue = #"{"queue":[{"workspace":"ws-1","branch":"collab/a","checkout":"/tmp/relay","test":["swift","test"],"added":"2026-11-25T11:00:00Z","state":"merged"},{"workspace":"ws-1","branch":"collab/b","checkout":"/tmp/relay","test":["swift","test"],"added":"2026-11-25T11:30:00Z","state":"queued"},{"workspace":"ws-9","branch":"other","checkout":"/tmp/x","test":[],"added":"2026-11-25T11:40:00Z","state":"queued"}]}"#

    static let policy = #"{"knowledgeDefault":"private","knowledgeWidest":"group","reputationVisibility":"friends","directory":true,"maxGrantDays":30,"maxBudgetTokens":0,"retentionDays":90}"#

    /// The reads every teams page starts from; `extra` answers first.
    static func route(_ extra: @escaping @Sendable (RoutedMultiplayerHelper.Call) -> String? = { _ in nil })
        -> @Sendable (RoutedMultiplayerHelper.Call) -> String? {
        { call in
            if let reply = extra(call) { return reply }
            switch call.verb {
            case .servers: return servers
            case .status: return status
            case .queue: return queue
            case .me: return #"{"admin":true,"mode":"open"}"#
            case .approvals: return #"{"approvals":[]}"#
            case .handoffs: return #"{"handoffs":[{"request":"rq-1","resource":"dir-h","action":"agent.handoff","title":"Run UI tests","at":"2026-11-25T11:00:00Z","status":"ok","value":{"run":"r-1"}}]}"#
            case .relay where call.method == "GET":
                if call.path == "/v1/groups" { return groups }
                if call.path == "/v1/workspaces" { return workspaces }
                if call.path == "/v1/workspaces/ws-1/cards" { return cards }
                if call.path == "/v1/knowledge" { return knowledge }
                if call.path == "/v1/access-requests" { return #"{"requests":[]}"# }
                return nil
            default: return nil
            }
        }
    }

    @MainActor static func model(_ extra: @escaping @Sendable (RoutedMultiplayerHelper.Call) -> String? = { _ in nil }) async
        -> (MultiplayerModel, RoutedMultiplayerHelper) {
        let helper = RoutedMultiplayerHelper(route(extra))
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600))
        model.open()
        await model.settle()
        model.refresh()
        await model.settle()
        return (model, helper)
    }
}

@Suite struct MultiplayerTeamsContractTests {
    private func json(_ text: String) throws -> MultiplayerJSON { try MultiplayerLiveFixture.json(text) }

    @Test func tracksTheTeamsVerbsAndTheHostKind() {
        #expect(Set(["relay", "queue", "queue-add", "queue-merge", "knowledge-share", "knowledge-install"])
            .isSubset(of: Set(MultiplayerVerb.allCases.map(\.rawValue))))
        #expect(MultiplayerVerb.queueMerge.arguments == ["tray", "queue-merge"])
        #expect(MultiplayerResourceKind(rawValue: "host")?.title == "Host")
        #expect(MultiplayerSharePolicy.expected(kind: "host") == ["host.run"])
        #expect(MultiplayerCapability.title("host.run") == "Run enrolled commands")
        var draft = MultiplayerResourceDraft()
        draft.kind = .host
        draft.name = "studio"
        draft.target = "commands.json"
        #expect(draft.targetProblem(directoryExists: { _ in true }) == "Use an absolute path that starts with /.")
        draft.target = "/Users/fixture/commands.json"
        #expect(draft.command(directoryExists: { _ in false }) != nil)
    }

    @Test func groupsAndWorkspacesAreReadLenientlyAndDropUnreadableRows() throws {
        let groups = (try json(MultiplayerTeamsFixture.groups)["groups"]?.items ?? []).compactMap(MultiplayerGroup.init)
        #expect(groups.map(\.id) == ["grp-1", "grp-2"])
        #expect(groups[0].owner == "fixture-ada" && groups[0].isOwned(by: "fixture-ada") && !groups[1].isOwned(by: "fixture-ada"))
        #expect(groups[0].memberTitle == "2 members" && !groups[0].isOwned(by: ""))

        let workspaces = (try json(MultiplayerTeamsFixture.workspaces)["workspaces"]?.items ?? []).compactMap(MultiplayerWorkspace.init)
        let workspace = try #require(workspaces.first)
        #expect(workspace.usesQueue && workspace.claims.map(\.id) == ["cl-1", "cl-2"])
        #expect(workspace.claims[0].holderHandle == "fixture-bo" && workspace.claims[0].holderAgent == "bo-agent")
        #expect(workspace.claims[0].expiresAt != nil && workspace.claims[1].expiresAt == nil)    // Go's zero time is "not set"
        #expect(workspace.claims[1].isHeld(by: "fixture-ada") && !workspace.claims[0].isHeld(by: "fixture-ada"))
        #expect(workspace.pullRequestsURL?.absoluteString == "https://github.com/example/relay/pulls")
        #expect(MultiplayerWorkspace(id: "w", name: "w", repository: "git@github.com:example/relay.git").pullRequestsURL?.absoluteString
            == "https://github.com/example/relay/pulls")
        #expect(MultiplayerWorkspace(id: "w", name: "w", repository: "/Users/me/relay").pullRequestsURL == nil)
    }

    @Test func cardsAndQueueEntriesCarryAStateALampAndAWord() throws {
        let cards = (try json(MultiplayerTeamsFixture.cards)["cards"]?.items ?? []).compactMap(MultiplayerCard.init)
        #expect(cards.map(\.known) == [.open, .claimed, .done])
        #expect(cards[1].isAssigned(to: "fixture-ada") && !cards[2].isAssigned(to: "fixture-ada"))
        #expect(MultiplayerCard(id: "c", title: "t", state: "odd").known == .open)
        #expect(MultiplayerCard.State.allCases.map(\.title) == ["Open", "Claimed", "Done"])

        let queue = (try json(MultiplayerTeamsFixture.queue)["queue"]?.items ?? []).compactMap(MultiplayerQueueEntry.init)
        #expect(queue.map(\.stateTitle) == ["Merged", "Queued", "Queued"] && queue[1].isQueued && queue[0].test == ["swift", "test"])
        #expect(MultiplayerQueueEntry(workspace: "w", branch: "b", state: "failed").stateTitle == "Tests failed")
        #expect(MultiplayerQueueEntry(workspace: "w", branch: "b", state: "conflict").tone == .failure)
    }

    @Test func draftsSayWhatIsMissingAndBuildTheRelaysBodies() {
        var workspace = MultiplayerWorkspaceDraft()
        #expect(!workspace.canSend && workspace.hint == "Choose the group that works in it.")
        workspace.group = "grp-1"
        workspace.name = " Reconnect "
        workspace.goal = "Survive renewals"
        workspace.repository = "github.com/example/relay"
        workspace.integration = .pullRequest
        #expect(workspace.canSend && workspace.hint == nil)
        #expect(workspace.body == .object(["name": .string("Reconnect"), "goal": .string("Survive renewals"),
                                           "repository": .string("github.com/example/relay"), "base": .string("main"),
                                           "group": .string("grp-1"), "integration": .string("pull_request")]))

        var claim = MultiplayerClaimDraft(kind: .paths, key: "Sources/Relay, /etc", agent: "tests")
        #expect(!claim.canSend && claim.keyProblem != nil)
        claim.key = "Sources/Relay, Tests/Relay"
        #expect(claim.canSend)
        #expect(claim.body(handle: "fixture-ada") == .object(["kind": .string("paths"), "key": .string("Sources/Relay, Tests/Relay"),
                                                               "holder": .string("fixture-ada/tests")]))
        claim.agent = "has space"
        #expect(!claim.canSend && claim.agentProblem != nil)

        var queue = MultiplayerQueueDraft(branch: "collab/a", checkout: "relay", testText: " swift  test --filter Relay ")
        #expect(!queue.canSend && queue.checkoutProblem != nil)
        queue.checkout = "/tmp/relay"
        #expect(queue.canSend && queue.testCommand == ["swift", "test", "--filter", "Relay"])

        var run = MultiplayerHostRunDraft()
        #expect(!run.canSend)
        run.command = "ui-tests"
        #expect(run.payload == .object(["command": .string("ui-tests")]))
        run.argumentText = "--only Onboarding"
        #expect(run.payload["args"] == .array([.string("--only"), .string("Onboarding")]))
    }

    @Test func knowledgeThatLooksLikeASecretIsRefusedBeforeItIsSent() {
        var draft = MultiplayerKnowledgeDraft(kind: .mcp, name: "gh", content: #"{"env":{"GITHUB_TOKEN":"${GITHUB_TOKEN}"}}"#)
        #expect(draft.secretProblem == nil && draft.canSend && draft.visibility == "private")
        draft.content = "token = ghp_abcdefghijklmnopqrstuvwxyz0123"
        #expect(draft.secretProblem == MultiplayerSecretCheck.refusal && !draft.canSend)
        for secret in ["password=hunter2hunter2", "api_key: 'abcdef123456'", "sk-abcdefghijklmnopqrstuvwx", "AKIAABCDEFGHIJKLMNOP",
                       "-----BEGIN RSA PRIVATE KEY-----", "xoxb-1234567890-abc"] {
            #expect(MultiplayerSecretCheck.looksSecret(secret), "\(secret)")
        }
        for plain in ["token=${TOKEN}", "Use your password manager.", "the secret is to test first"] {
            #expect(!MultiplayerSecretCheck.looksSecret(plain), "\(plain)")
        }
        #expect(MultiplayerSecretCheck.isRefusal("this item seems to contain a secret; replace it with a ${NAME} placeholder before sharing"))
        #expect(MultiplayerSecretCheck.placeholders(in: "a ${ONE} b ${TWO} c ${ONE} ${3X}") == ["ONE", "TWO"])

        draft.content = "ok"
        draft.scope = .friend
        #expect(!draft.canSend)
        draft.target = "fixture-bo"
        #expect(draft.canSend && draft.visibility == "friend:fixture-bo")
        #expect(MultiplayerKnowledgeScope.describe("group:grp-1") { $0 == "grp-1" ? "relay-team" : nil } == "Group relay-team")
        #expect(MultiplayerKnowledgeScope.describe("server") == "Everyone on this server")
        #expect(MultiplayerKnowledgeKind.skill.installTitle == "Install skill" && MultiplayerKnowledgeKind.prompt.installTitle == "Copy")
    }

    @Test func reputationAndEndorsementsReadAsFiguresAndTallies() throws {
        let reputation = MultiplayerReputation(try json(#"{"resource":"dir-h","completed":18,"accepted":15,"rejected":1,"medianSeconds":96.4}"#))
        #expect(reputation.completed == 18 && reputation.acceptedPercent == 94 && reputation.medianTitle == "2 min")
        #expect(MultiplayerReputation(resource: "r").medianTitle == "–" && MultiplayerReputation(resource: "r").acceptedPercent == nil)
        #expect(MultiplayerReputation(resource: "r", medianSeconds: 42).medianTitle == "42 s")
        #expect(MultiplayerReputation(resource: "r", medianSeconds: 7200).medianTitle == "2.0 h")
        let tally = MultiplayerEndorsement.tally([.init(handle: "a", skill: "x"), .init(handle: "b", skill: "y"), .init(handle: "c", skill: "y")])
        #expect(tally.map(\.skill) == ["y", "x"] && tally.map(\.count) == [2, 1])
        let hit = try #require(MultiplayerDirectoryHit(try json(#"{"id":"r-1","handle":"fixture-bo","name":"bo-mini","kind":"host","actions":["host.run"],"capabilities":{"tools":["ui-tests"]},"endorsements":[{"handle":"fixture-cy","skill":"ui tests"},{"handle":"x"}]}"#)))
        #expect(hit.capabilities?.tools == ["ui-tests"] && hit.endorsements == [.init(handle: "fixture-cy", skill: "ui tests")])
    }

    @Test func aPolicyEditSendsOnlyWhatChanged() throws {
        let saved = try #require(MultiplayerRelayPolicy(try json(MultiplayerTeamsFixture.policy)))
        #expect(saved.directory && saved.knowledgeWidest == "group" && saved.retentionDays == 90)
        #expect(MultiplayerRelayPolicy(try json(#"{"directory":"on","knowledgeWidest":"server"}"#))?.directory == true)
        #expect(MultiplayerRelayPolicy(try json("{}")) == nil)
        var draft = MultiplayerPolicyDraft(saved)
        #expect(draft.changes(from: saved) == [:])
        draft.directory = false
        draft.maxBudgetTokens = "2,000,000"
        #expect(draft.changes(from: saved) == ["directory": .bool(false), "maxBudgetTokens": .number(2_000_000)])
        draft.knowledgeDefault = .server
        #expect(draft.scopeProblem != nil && draft.changes(from: saved) == nil)
        draft.knowledgeDefault = .private
        draft.retentionDays = "0"
        #expect(draft.retentionProblem != nil && draft.policy == nil)
        draft.retentionDays = "x"
        #expect(draft.retention == nil)
    }

    @Test func aGrantToAGroupNamesTheGroupInPlaceOfTheFriend() {
        var draft = MultiplayerShareDraft(server: "s", resourceID: "res-9")
        draft.actions = ["agent.ask"]
        draft.group = "grp-1"
        let grants = draft.grants(kind: "agent", offered: ["agent.ask"], now: Date(timeIntervalSince1970: 0))
        #expect(grants.count == 1 && grants[0]["group"] == .string("grp-1") && grants[0]["handle"] == nil)
        draft.group = ""
        #expect(draft.grants(kind: "agent", offered: ["agent.ask"], now: Date(timeIntervalSince1970: 0)).isEmpty)
        draft.handle = "fixture-bo"
        let single = draft.grants(kind: "agent", offered: ["agent.ask"], now: Date(timeIntervalSince1970: 0))
        #expect(single[0]["handle"] == .string("fixture-bo") && single[0]["group"] == nil)
    }

    @Test func aHostRunReadsItsExitCodeAndNeverDrawsACredential() throws {
        let run = try #require(MultiplayerHostRun(try json(#"{"command":"ui-tests","exitCode":1,"output":"failed\ntoken=ghp_abcdefghijklmnopqrstuvwxyz0123","seconds":41}"#)))
        #expect(!run.succeeded && run.seconds == 41 && !run.output.contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        #expect(MultiplayerHostRun(try json(#"{"text":"no exit code"}"#)) == nil)
    }

    @Test func aPathSegmentCannotChangeTheRoute() throws {
        #expect(try MultiplayerClient.segment("grp-1") == "grp-1")
        #expect(try MultiplayerClient.segment("a/b?c") == "a%2Fb%3Fc")
        #expect(throws: MultiplayerFailure.self) { try MultiplayerClient.segment("") }
    }
}

@MainActor @Suite struct MultiplayerTeamsModelTests {
    private let home = MultiplayerTeamsFixture.home

    @Test func readsGroupsWorkspacesTheLibraryAndTheQueueWhileAPanelIsOpen() async {
        let (model, helper) = await MultiplayerTeamsFixture.model()
        let teams = model.share.teams
        #expect(teams.groups[home]?.map(\.id) == ["grp-1", "grp-2"])
        #expect(teams.workspaces[home]?.first?.claims.count == 2)
        #expect(teams.knowledge[home]?.map(\.id) == ["kn-1", "kn-2"] && teams.knowledgeCount == 2)
        #expect(teams.queue(for: "ws-1").map(\.branch) == ["collab/a", "collab/b"])
        #expect(teams.ownedGroups(on: home).map(\.id) == ["grp-1"])
        #expect(teams.myHosts(on: home).map(\.id) == ["res-h"] && teams.friendHosts(on: home).map(\.id) == ["dir-h", "dir-g"])
        #expect(teams.hostCount == 3 && teams.handle(on: home) == "fixture-ada" && teams.defaultAgent(on: home) == "tests")
        #expect(helper.relays("GET").map(\.path).contains("/v1/groups"))
        model.close()
    }

    @Test func createsAGroupAddsAFriendAndDeletesOnlyAfterASecondPress() async {
        let (model, helper) = await MultiplayerTeamsFixture.model { call in
            call.verb == .relay && call.method == "POST" && call.path == "/v1/groups" ? #"{"id":"grp-1"}"# : nil
        }
        let teams = model.share.teams
        model.share.open(.groups, on: home)
        #expect(!teams.canCreateGroup)
        teams.groupDraft = "  relay-team "
        await teams.createGroup(on: home)?.value
        #expect(helper.relays("POST").last?.body == .object(["name": .string("relay-team")]))
        #expect(model.route == .share(home, .group("grp-1")) && teams.groupDraft.isEmpty)

        let group = teams.group("grp-1", on: home)!
        #expect(teams.addable(to: group, on: home).map(\.handle) == ["fixture-cy"])
        await teams.setMember("fixture-cy", in: group, on: home, isMember: true)?.value
        #expect(helper.relays("PUT").last?.path == "/v1/groups/grp-1/members/fixture-cy")
        await teams.setMember("fixture-bo", in: group, on: home, isMember: false)?.value
        #expect(helper.relays("DELETE").last?.path == "/v1/groups/grp-1/members/fixture-bo")

        teams.ask(.deleteGroup("grp-1"))
        #expect(teams.confirming == .deleteGroup("grp-1") && helper.relays("DELETE").count == 1)
        await teams.deleteGroup(group, on: home)?.value
        #expect(helper.relays("DELETE").last?.path == "/v1/groups/grp-1" && teams.confirming == nil)
        #expect(teams.group("grp-1", on: home) == nil && model.route != .share(home, .group("grp-1")))
        model.close()
    }

    @Test func sharesWithAGroupThroughTheGrantVerb() async {
        let (model, helper) = await MultiplayerTeamsFixture.model()
        let share = model.share
        share.startGrant(on: home, group: "grp-1", resourceID: "res-9")
        #expect(share.grantDraft.group == "grp-1" && share.grantDraft.handle.isEmpty)
        share.toggleGrantAction("agent.ask")
        #expect(share.canGrant)
        await share.confirmGrant()?.value
        let grant = helper.last(.grant)?.input
        #expect(grant?["group"] == .string("grp-1") && grant?["handle"] == nil && grant?["capability"] == .string("agent.ask"))
        // A group you don't own can't take a grant.
        share.startGrant(on: home, group: "grp-2", resourceID: "res-9")
        share.toggleGrantAction("agent.ask")
        #expect(!share.canGrant)
        model.close()
    }

    @Test func createsAWorkspaceClaimsInThePersonsOwnNameAndShowsWhoHoldsAnOverlap() async {
        let (model, helper) = await MultiplayerTeamsFixture.model { call in
            guard call.verb == .relay, call.method == "POST" else { return nil }
            if call.path == "/v1/workspaces" { return #"{"id":"ws-1"}"# }
            if call.path == "/v1/workspaces/ws-1/claims" {
                return call.body?["key"] == .string("Sources/Relay") ? "!relay HTTP 409: already claimed by fixture-bo/bo-agent" : #"{"id":"cl-9"}"#
            }
            return nil
        }
        let teams = model.share.teams
        teams.startWorkspace(on: home)
        #expect(model.route == .share(home, .workspaceCreate) && teams.workspaceDraft.group.isEmpty)   // two groups: none preselected
        teams.workspaceDraft.group = "grp-1"
        teams.workspaceDraft.name = "Reconnect"
        teams.workspaceDraft.goal = "Survive renewals"
        teams.workspaceDraft.repository = "github.com/example/relay"
        await teams.createWorkspace(on: home)?.value
        #expect(model.route == .share(home, .workspace("ws-1")))
        #expect(helper.relays("POST").first { $0.path == "/v1/workspaces" }?.body?["integration"] == .string("queue"))

        teams.startClaim(in: "ws-1", on: home)
        #expect(teams.claimDraft.agent == "tests")
        teams.claimDraft.kind = .paths
        teams.claimDraft.key = "Sources/Relay"
        await teams.sendClaim(in: "ws-1", on: home)?.value
        #expect(model.failure?.contains("fixture-bo/bo-agent") == true && model.route == .share(home, .claim(workspace: "ws-1")))
        teams.claimDraft.key = "docs"
        await teams.sendClaim(in: "ws-1", on: home)?.value
        #expect(helper.relays("POST").last?.body == .object(["kind": .string("paths"), "key": .string("docs"),
                                                               "holder": .string("fixture-ada/tests")]))
        #expect(model.route == .share(home, .workspace("ws-1")))

        let mine = teams.workspace("ws-1", on: home)!.claims[1]
        await teams.release(mine, in: "ws-1", on: home)?.value
        #expect(helper.relays("DELETE").last?.path == "/v1/workspaces/ws-1/claims/cl-2")
        model.close()
    }

    @Test func theBoardAddsClaimsCompletesAndReopensCards() async {
        let (model, helper) = await MultiplayerTeamsFixture.model()
        let teams = model.share.teams
        model.share.open(.workspace("ws-1"), on: home)
        await model.settle()
        #expect(teams.cards.value?.map(\.id) == ["card-1", "card-2", "card-3"])

        teams.cardDraft.title = " Add a soak test "
        await teams.addCard(to: "ws-1", on: home)?.value
        #expect(helper.relays("POST").last?.path == "/v1/workspaces/ws-1/cards")
        #expect(helper.relays("POST").last?.body?["title"] == .string("Add a soak test") && teams.cardDraft.title.isEmpty)

        let open = teams.card("card-1")!, claimed = teams.card("card-2")!
        await teams.move(open, in: "ws-1", on: home, to: .claimed)?.value
        #expect(helper.relays("PUT").last?.path == "/v1/workspaces/ws-1/cards/card-1")
        #expect(helper.relays("PUT").last?.body == .object(["state": .string("claimed"), "assignee": .string("fixture-ada/tests")]))

        teams.openCard(claimed, in: "ws-1", on: home)
        teams.resultDraft = " Keyed by lease ID on collab/waiters. "
        await teams.move(claimed, in: "ws-1", on: home, to: .done)?.value
        #expect(helper.relays("PUT").last?.body == .object(["state": .string("done"),
                                                              "result": .string("Keyed by lease ID on collab/waiters.")]))
        await teams.move(teams.card("card-3")!, in: "ws-1", on: home, to: .open)?.value
        #expect(helper.relays("PUT").last?.body == .object(["state": .string("open")]))
        model.close()
    }

    @Test func theMergeQueueAddsABranchAndReportsWhatDidNotMerge() async {
        let merged = #"{"queue":[{"workspace":"ws-1","branch":"collab/a","checkout":"/tmp/relay","test":[],"added":"2026-11-25T11:00:00Z","state":"merged"},{"workspace":"ws-1","branch":"collab/b","checkout":"/tmp/relay","test":["swift","test"],"added":"2026-11-25T11:30:00Z","state":"failed","output":"1 failure"}]}"#
        let (model, helper) = await MultiplayerTeamsFixture.model { call in
            call.verb == .queueMerge ? merged : call.verb == .queueAdd ? MultiplayerTeamsFixture.queue : nil
        }
        let teams = model.share.teams
        teams.startQueueAdd(for: "ws-1", on: home)
        #expect(teams.queueDraft.checkout == "/tmp/relay" && teams.queueDraft.testText == "swift test")   // carried from the last entry
        teams.queueDraft.branch = "collab/c"
        await teams.addToQueue("ws-1", on: home)?.value
        let added = helper.last(.queueAdd)?.input
        #expect(added?["workspace"] == .string("ws-1") && added?["branch"] == .string("collab/c"))
        #expect(added?["testCommand"] == .array([.string("swift"), .string("test")]) && added?["checkout"] == .string("/tmp/relay"))

        await teams.runQueue("ws-1", on: home)?.value
        #expect(helper.last(.queueMerge)?.input["workspace"] == .string("ws-1"))
        #expect(model.failure == "Merged 0 of 1. The others are marked with what stopped them.")
        #expect(teams.queue(for: "ws-1").last?.output == "1 failure")
        #expect(teams.runQueue("ws-1", on: home) == nil)    // nothing is queued now
        model.close()
    }

    @Test func aHostRunTravelsAsAnOrdinaryRequestAndKeepsItsResult() async {
        let (model, helper) = await MultiplayerTeamsFixture.model { call in
            call.verb == .send ? #"{"request":"rq-9","status":"ok","value":{"command":"ui-tests","exitCode":0,"output":"** TEST SUCCEEDED **","seconds":37}}"# : nil
        }
        let teams = model.share.teams
        teams.startHostRun("dir-h", on: home)
        #expect(model.route == .share(home, .hostRun(resource: "dir-h")) && teams.hostDraft.command.isEmpty && !teams.canRunOnHost)
        teams.hostDraft.command = "ui-tests"
        teams.hostDraft.argumentText = "--only Onboarding"
        await teams.runOnHost("dir-h", on: home)?.value
        let sent = helper.last(.send)?.input
        #expect(sent?["resource"] == .string("dir-h") && sent?["capability"] == .string("host.run"))
        #expect(sent?["payload"] == .object(["command": .string("ui-tests"), "args": .array([.string("--only"), .string("Onboarding")])]))
        #expect(MultiplayerHostRun(teams.hostReply?.value)?.succeeded == true)
        model.close()
    }

    @Test func sharingKnowledgeShowsTheSecretRefusalAndKeepsTheDraft() async {
        let (model, helper) = await MultiplayerTeamsFixture.model { call in
            switch call.verb {
            case .knowledgeShare:
                return call.input["item"]?["name"] == .string("leaky")
                    ? "!this item seems to contain a secret; replace it with a ${NAME} placeholder before sharing" : "{}"
            case .knowledgeInstall: return #"{"installed":"/Users/fixture/.claude/skills/triage/SKILL.md"}"#
            case .relay where call.path == "/v1/knowledge/kn-1/versions":
                return #"{"versions":[{"id":"kn-1","kind":"skill","name":"triage","content":"v1","visibility":"private","version":1},{"id":"kn-1","kind":"skill","name":"triage","content":"Triage steps","visibility":"group:grp-1","version":3}]}"#
            default: return nil
            }
        }
        let teams = model.share.teams
        teams.startKnowledge(on: home)
        teams.knowledgeDraft.kind = .mcp
        teams.knowledgeDraft.name = "leaky"
        teams.knowledgeDraft.content = "password=hunter2hunter2"
        #expect(!teams.canShareKnowledge && teams.shareKnowledge(on: home) == nil)    // caught before anything is sent
        #expect(helper.last(.knowledgeShare) == nil)
        // A pattern only the device knows: its refusal is shown and the draft is kept.
        teams.knowledgeDraft.content = "an odd credential the panel doesn’t recognise"
        await teams.shareKnowledge(on: home)?.value
        #expect(teams.secretRefusal == MultiplayerSecretCheck.refusal && model.failure?.contains("secret") == true)
        #expect(teams.knowledgeDraft.name == "leaky" && model.route == .share(home, .knowledgeShare))

        teams.knowledgeDraft.name = "gh"
        teams.knowledgeDraft.content = #"{"env":{"GITHUB_TOKEN":"${GITHUB_TOKEN}"}}"#
        teams.knowledgeDraft.scope = .group
        teams.knowledgeDraft.target = "grp-1"
        await teams.shareKnowledge(on: home)?.value
        #expect(helper.last(.knowledgeShare)?.input["item"]?["visibility"] == .string("group:grp-1"))
        #expect(teams.secretRefusal == nil && model.notice == "Shared gh.")

        model.share.open(.knowledgeItem("kn-1"), on: home)
        await model.settle()
        #expect(teams.versions.value?.map(\.version) == [1, 3])
        let item = teams.item("kn-1", on: home)!
        await teams.install(item, on: home)?.value
        #expect(helper.last(.knowledgeInstall)?.input["item"] == .object(["kind": .string("skill"), "name": .string("triage"),
                                                                           "content": .string("Triage steps")]))
        #expect(helper.last(.knowledgeInstall)?.input["destination"] == nil && model.notice?.contains("SKILL.md") == true)
        #expect(teams.item("kn-2", on: home)?.placeholders == ["GITHUB_TOKEN", "ORG"])

        // A new version of your own item goes to the relay's PUT.
        teams.startKnowledge(on: home, editing: teams.item("kn-2", on: home))
        #expect(teams.knowledgeDraft.editing == "kn-2" && teams.knowledgeDraft.scope == .server)
        await teams.shareKnowledge(on: home)?.value
        #expect(helper.relays("PUT").last?.path == "/v1/knowledge/kn-2")
        model.close()
    }

    @Test func reputationOutcomesEndorsementsAndTheSearchUseTheRelaysRoutes() async {
        let (model, helper) = await MultiplayerTeamsFixture.model { call in
            guard call.verb == .relay else { return nil }
            if call.path == "/v1/reputation/dir-h" { return #"{"resource":"dir-h","completed":18,"accepted":15,"rejected":1,"medianSeconds":96}"# }
            if call.path.hasPrefix("/v1/directory") {
                return call.path.hasSuffix("q=off") ? "!relay HTTP 403: forbidden"
                    : #"{"handles":["fixture-bo"],"resources":[{"id":"dir-h","handle":"fixture-bo","name":"bo-mini","kind":"host","actions":["host.run"],"endorsements":[]}]}"#
            }
            return nil
        }
        let teams = model.share.teams
        teams.startReputation("dir-h", on: home)
        await model.settle()
        #expect(teams.reputation.value?.completed == 18)
        #expect(model.share.entry("dir-h", on: home)?.endorsements.map(\.skill) == ["ui tests", "ui tests"])    // the row with no skill is dropped
        let mine = teams.judgeable("dir-h", on: home)
        #expect(mine.map(\.request) == ["rq-1"])
        await teams.report(mine[0], on: home, accepted: true)?.value
        #expect(helper.relays("POST").last?.path == "/v1/outcomes")
        #expect(helper.relays("POST").last?.body == .object(["resource": .string("dir-h"), "request": .string("rq-1"), "accepted": .bool(true)]))
        #expect(teams.outcomes == ["rq-1": true])

        teams.endorseDraft = " ui tests "
        await teams.endorse("dir-h", on: home)?.value
        #expect(helper.relays("POST").last?.body == .object(["resource": .string("dir-h"), "skill": .string("ui tests")]))

        teams.startSearch(on: home)
        teams.searchDraft = "ios sim&x"
        teams.runSearch(on: home)
        await model.settle()
        #expect(helper.relays("GET").last { $0.path.hasPrefix("/v1/directory") }?.path == "/v1/directory?q=ios%20sim%26x")
        #expect(teams.search.value?.handles == ["fixture-bo"] && teams.search.value?.resources.first?.id == "dir-h")
        teams.searchDraft = "off"
        teams.runSearch(on: home)
        await model.settle()
        #expect(teams.search.failure?.contains("forbidden") == true)
        model.close()
    }

    @Test func theAdminPolicySavesOnlyChangesAndAsksBeforeSuspendingOrRevoking() async {
        let (model, helper) = await MultiplayerTeamsFixture.model { call in
            call.verb == .relay && call.path == "/v1/admin/policy" ? MultiplayerTeamsFixture.policy : nil
        }
        let teams = model.share.teams
        #expect(model.isAdmin(home))
        model.share.open(.policy, on: home)
        await model.settle()
        #expect(helper.relays("PUT").last?.body == .object([:]))     // the read changes nothing
        #expect(teams.policy.value?.knowledgeWidest == "group" && teams.policyDraft.knowledgeWidest == .group && !teams.canSavePolicy)
        teams.policyDraft.directory = false
        teams.policyDraft.maxGrantDays = "14"
        #expect(teams.canSavePolicy)
        await teams.savePolicy(on: home)?.value
        #expect(helper.relays("PUT").last?.body == .object(["directory": .bool(false), "maxGrantDays": .number(14)]))

        teams.policyDraft.member = " Fixture-Bo "
        teams.ask(.suspend(teams.policyDraft.trimmedMember))
        #expect(teams.confirming == .suspend("fixture-bo") && helper.relays("POST").isEmpty)
        await teams.setSuspended(true, on: home)?.value
        #expect(helper.relays("POST").last?.path == "/v1/admin/members/fixture-bo/suspend" && teams.confirming == nil)
        teams.policyDraft.member = "fixture-bo"
        await teams.setSuspended(false, on: home)?.value
        #expect(helper.relays("POST").last?.path == "/v1/admin/members/fixture-bo/unsuspend")
        teams.policyDraft.device = "d-bo/1"
        await teams.revokeDevice(on: home)?.value
        #expect(helper.relays("DELETE").last?.path == "/v1/admin/devices/d-bo%2F1" && teams.policyDraft.device.isEmpty)
        model.close()
    }
}
