import SwiftUI

// ATOMIC LEVEL: Pages (design previews of the Teams pages).
// The Teams pages with sample values, clickable: every action changes the sample state the way
// the Teams model will. Nothing here contacts the service, the helper or the network model.
//
//   open "dist/Agent Commander.app" --args --design-preview teams-workspace
//   … teams-board, teams-groups, teams-hosts, teams-knowledge, teams-directory, teams-admin
//
// Each opens sidebar B on that place; the other places are a click away.
//
//   TeamsSample         the sample teams: two servers, their groups, workspaces, hosts and library
//   TeamsPreviewState   the sample state, and the sample's side of the action boundary

extension DesignPreviewScenario {
    /// The place a Teams scenario opens on.
    var teamsPlace: String? {
        switch self {
        case .teamsWorkspace, .teamsBoard: TeamsSample.relayPlace
        case .teamsGroups: TeamsPlace.groups
        case .teamsHosts: TeamsPlace.hosts
        case .teamsKnowledge: TeamsPlace.knowledge
        case .teamsDirectory: TeamsPlace.directory
        case .teamsAdmin: TeamsPlace.admin
        default: nil
        }
    }
}

// MARK: - Sample values

enum TeamsSample {
    static let now = NetworkSample.now
    static let studio = NetworkSample.studio, lab = NetworkSample.lab
    static let relay = "ws-relay", infra = "ws-infra"
    static let relayKey = TeamsKey.make(relay, on: studio), infraKey = TeamsKey.make(infra, on: studio)
    static let relayPlace = TeamsPlace.workspace(relay, on: studio), infraPlace = TeamsPlace.workspace(infra, on: studio)
    /// The card whose claim the sample relay refuses once: someone else got there first.
    static let contested = "card-6"
    /// Where the sample saves an MCP item.
    static let mcpFile = NSHomeDirectory() + "/GitHub/relay/.mcp.json"

    private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private static func ahead(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    static let policy: MultiplayerRelayPolicy = {
        var policy = MultiplayerRelayPolicy()
        policy.knowledgeDefault = "private"
        policy.knowledgeWidest = "group"
        policy.reputationVisibility = "friends"
        policy.directory = true
        policy.maxGrantDays = 30
        policy.maxBudgetTokens = 200_000
        policy.retentionDays = 30
        return policy
    }()

    static let triage = """
    ## Relay triage

    Use this when a relay test fails in CI.

    1. Read the failing test's last 200 lines.
    2. Check whether the lease renewal timer was involved.
    3. Claim the paths before you change anything.

    Finish with a card result that names the branch.
    """

    static let mcp = """
    {
      "mcpServers": {
        "github": {
          "command": "github-mcp-server",
          "env": { "GITHUB_TOKEN": "${GITHUB_TOKEN}" }
        }
      }
    }
    """

    static var content: TeamsPagesContent {
        var studioServer = TeamsPagesContent.Server(id: studio, name: "studio", handle: "ryan", isAdmin: true)
        studioServer.friends = ["mira", "ines", "priya", "sam"].map { MultiplayerFriend(handle: $0, online: $0 != "priya") }
        studioServer.groups = [
            MultiplayerGroup(id: "g-relay", name: "Relay crew", owner: "ryan", members: ["ryan", "mira", "sam"]),
            MultiplayerGroup(id: "g-infra", name: "Infra guild", owner: "ines", members: ["ines", "ryan", "priya"])
        ]
        studioServer.workspaces = [
            MultiplayerWorkspace(id: relay, owner: "ryan", group: "g-relay", name: "Relay launch",
                                 goal: "Ship the per-request retry budget and the lease renewal fix for 1.4.",
                                 repository: "ryanhelms/relay", base: "main", integration: MultiplayerIntegration.queue.rawValue,
                                 claims: [
                                    MultiplayerClaim(id: "cl-1", kind: "issue", key: "#212", holder: "mira/mira-claude", expiresAt: ahead(3_000)),
                                    MultiplayerClaim(id: "cl-2", kind: "paths", key: "Sources/Relay/Lease", holder: "sam/sam-claude", expiresAt: ahead(1_800)),
                                    MultiplayerClaim(id: "cl-3", kind: "card", key: "card-3", holder: "ryan/relay-worker", expiresAt: ahead(2_400)),
                                    MultiplayerClaim(id: "cl-4", kind: "card", key: "card-4", holder: "sam/sam-codex", expiresAt: ahead(1_200))
                                 ]),
            MultiplayerWorkspace(id: infra, owner: "ines", group: "g-infra", name: "Infra guild",
                                 goal: "Move the relay’s CI to the shared runners.",
                                 repository: "adagio/infra", base: "main", integration: MultiplayerIntegration.pullRequest.rawValue,
                                 claims: [MultiplayerClaim(id: "cl-9", kind: "paths", key: "ci/runners", holder: "ines/ines-codex", expiresAt: ahead(2_000))])
        ]
        studioServer.knowledge = [
            MultiplayerKnowledgeItem(id: "k-1", owner: "mira", kind: "skill", name: "relay-triage", content: triage,
                                     visibility: "group:g-relay", version: 3, createdAt: ago(5_400)),
            MultiplayerKnowledgeItem(id: "k-2", owner: "ryan", kind: "prompt", name: "Review checklist",
                                     content: "Check the retry budget, the lease timer and the fake clock before you approve.",
                                     visibility: "group:g-relay", version: 1, createdAt: ago(86_400)),
            MultiplayerKnowledgeItem(id: "k-3", owner: "ines", kind: "mcp", name: "github-mcp", content: mcp,
                                     visibility: "friend:ryan", version: 2, createdAt: ago(172_800)),
            MultiplayerKnowledgeItem(id: "k-4", owner: "sam", kind: "instructions", name: "Commit style",
                                     content: "Conventional Commit subjects under 72 characters. One change per commit.",
                                     visibility: "group:g-relay", version: 1, createdAt: ago(259_200))
        ]
        studioServer.hosts = [
            TeamsHost(id: "host-studio", name: "mac-studio", environment: "macos-15",
                      commands: [MultiplayerHostCommand(name: "run-ios-ui-tests", allowArgs: false, environment: "ios-simulator"),
                                 MultiplayerHostCommand(name: "swift-test", allowArgs: true, environment: "macos-15")],
                      grants: 2)
        ]
        studioServer.offeredHosts = [
            MultiplayerDirectoryEntry(id: "host-build", name: "build-box", kind: MultiplayerResourceKind.host.rawValue, owner: "mira",
                                      offered: [MultiplayerSharePolicy.hostRun], granted: [MultiplayerSharePolicy.hostRun],
                                      capabilities: MultiplayerCapabilities(environments: ["linux"], commands: [
                                        MultiplayerHostCommand(name: "make-integration", allowArgs: true, environment: "linux"),
                                        MultiplayerHostCommand(name: "docker-build", allowArgs: false, environment: "linux")
                                      ])),
            MultiplayerDirectoryEntry(id: "host-rack", name: "ios-rack", kind: MultiplayerResourceKind.host.rawValue, owner: "ines",
                                      offered: [MultiplayerSharePolicy.hostRun],
                                      capabilities: MultiplayerCapabilities(environments: ["ios-simulator"], commands: [
                                        MultiplayerHostCommand(name: "run-ios-ui-tests", allowArgs: false, environment: "ios-simulator")
                                      ]))
        ]
        studioServer.policy = policy
        studioServer.members = [TeamsMember(handle: "ryan", isAdmin: true), TeamsMember(handle: "mira"), TeamsMember(handle: "ines"),
                                TeamsMember(handle: "sam"), TeamsMember(handle: "priya", isSuspended: true), TeamsMember(handle: "tomas")]
        studioServer.devices = [TeamsDevice(id: "dev-7f3a", name: "mira-mbp", owner: "mira", lastSeen: ago(120)),
                                TeamsDevice(id: "dev-22c1", name: "sam-linux", owner: "sam", lastSeen: ago(900)),
                                TeamsDevice(id: "dev-51be", name: "tomas-air", owner: "tomas", lastSeen: ago(86_400))]

        var labServer = TeamsPagesContent.Server(id: lab, name: "lab", handle: "ryan")
        labServer.friends = [MultiplayerFriend(handle: "jonah", online: true)]
        labServer.groups = [MultiplayerGroup(id: "g-docs", name: "Docs circle", owner: "jonah", members: ["jonah", "ryan"])]
        labServer.knowledge = [
            MultiplayerKnowledgeItem(id: "k-5", owner: "jonah", kind: "summary", name: "Retry design notes",
                                     content: "## Why per request\n\nA client-wide budget starves long uploads. Each request now carries its own.",
                                     visibility: "group:g-docs", version: 2, createdAt: ago(43_200))
        ]

        var content = TeamsPagesContent(now: now, servers: [studioServer, labServer])
        content.cards[relayKey] = [
            MultiplayerCard(id: "card-1", title: "Add a per-request retry budget",
                            body: "Move the counter from the client to the request context. Keep `RetryPolicy`’s public fields."),
            MultiplayerCard(id: "card-2", title: "Document the backoff ceiling"),
            MultiplayerCard(id: contested, title: "Fuzz the lease parser", body: "Ten minutes of fuzzing on the wire format."),
            MultiplayerCard(id: "card-3", title: "Stop the renewal timer on release",
                            body: "The timer fires once more after release. Stop it in `Lease.release()`.",
                            state: "claimed", assignee: "ryan/relay-worker"),
            MultiplayerCard(id: "card-4", title: "Port the lease test to the fake clock", state: "claimed", assignee: "sam/sam-codex"),
            MultiplayerCard(id: "card-5", title: "Split retry policy from transport", state: "done", assignee: "mira/mira-claude",
                            result: "Done on `collab/split-policy`, merged in #208."),
            MultiplayerCard(id: "card-7", title: "Pin the relay’s Go toolchain", state: "done", assignee: "sam/sam-codex",
                            result: "`go.mod` now pins 1.24.")
        ]
        content.cards[infraKey] = [MultiplayerCard(id: "card-20", title: "List the jobs that need macOS runners")]
        content.queue[relayKey] = [
            MultiplayerQueueEntry(workspace: relay, branch: "collab/docs-ceiling", checkout: NetworkSample.checkout,
                                  test: ["make", "docs"], added: ago(7_200), state: "merged"),
            MultiplayerQueueEntry(workspace: relay, branch: "collab/retry-budget", checkout: NetworkSample.checkout,
                                  test: ["make", "test"], added: ago(1_800)),
            MultiplayerQueueEntry(workspace: relay, branch: "collab/lease-timer", checkout: NetworkSample.checkout,
                                  test: ["swift", "test", "--filter", "Lease"], added: ago(600))
        ]
        content.pullRequests[infraKey] = .loaded(MultiplayerPullRequestList(workspace: infra, repository: "adagio/infra", pullRequests: [
            MultiplayerPullRequest(number: 41, title: "Run the relay tests on the shared runners",
                                   url: "https://github.com/adagio/infra/pull/41", author: "ines", branch: "ci/shared-runners"),
            MultiplayerPullRequest(number: 39, title: "Cache the Go module download",
                                   url: "https://github.com/adagio/infra/pull/39", author: "priya", branch: "ci/go-cache"),
            MultiplayerPullRequest(number: 36, title: "Drop the nightly matrix to two macOS versions",
                                   url: "https://github.com/adagio/infra/pull/36", author: "ryan", branch: "ci/nightly-matrix")
        ]))
        content.work[relayKey] = [
            TeamsMemberWork(handle: "ryan", workers: [
                TeamsWorker(id: "w-1", name: "relay-worker", capabilities: NetworkSample.fable, state: "Working",
                            branch: "collab/lease-timer", checks: TeamsChecks(passed: 14)),
                TeamsWorker(id: "w-2", name: "docs-agent", capabilities: NetworkSample.opus, state: "Idle", tone: .neutral)
            ]),
            TeamsMemberWork(handle: "mira", workers: [
                TeamsWorker(id: "w-3", name: "mira-claude", capabilities: NetworkSample.opus, state: "Working",
                            branch: "collab/retry-budget", checks: TeamsChecks(isRunning: true))
            ]),
            TeamsMemberWork(handle: "sam", isOnline: false, workers: [
                TeamsWorker(id: "w-4", name: "sam-codex", capabilities: NetworkSample.codex, state: "Waiting on review", tone: .attention,
                            branch: "collab/fake-clock", checks: TeamsChecks(passed: 11, failed: 2)),
                TeamsWorker(id: "w-5", name: "sam-claude", capabilities: NetworkSample.opus, state: "Stopped", tone: .neutral,
                            branch: "collab/lease-parser")
            ])
        ]
        content.work[infraKey] = [
            TeamsMemberWork(handle: "ines", workers: [
                TeamsWorker(id: "w-9", name: "ines-codex", capabilities: NetworkSample.codex, state: "Working",
                            branch: "ci/shared-runners", checks: TeamsChecks(passed: 6))
            ]),
            TeamsMemberWork(handle: "ryan"), TeamsMemberWork(handle: "priya", isOnline: false)
        ]
        content.versions[TeamsKey.make("k-1", on: studio)] = .loaded([
            MultiplayerKnowledgeItem(id: "k-1", owner: "mira", kind: "skill", name: "relay-triage", content: "## Relay triage\n\nRead the failing test first.",
                                     visibility: "private", version: 1, createdAt: ago(604_800)),
            MultiplayerKnowledgeItem(id: "k-1", owner: "mira", kind: "skill", name: "relay-triage",
                                     content: "## Relay triage\n\nRead the failing test first, then check the lease timer.",
                                     visibility: "friend:ryan", version: 2, createdAt: ago(259_200)),
            studioServer.knowledge[0]
        ])
        content.reputation[TeamsKey.make("res-mira-claude", on: studio)] =
            .loaded(MultiplayerReputation(resource: "res-mira-claude", completed: 42, accepted: 37, rejected: 3, medianSeconds: 318))
        content.reputation[TeamsKey.make("host-build", on: studio)] =
            .loaded(MultiplayerReputation(resource: "host-build", completed: 118, accepted: 112, rejected: 1, medianSeconds: 47))
        content.reputation[TeamsKey.make("host-rack", on: studio)] = .loaded(MultiplayerReputation(resource: "host-rack"))
        return content
    }

    /// A content's workspaces as navigation places, with their live claims.
    static func workspacePlaces(_ content: TeamsPagesContent) -> [CommanderPlace] {
        content.servers.flatMap { server in
            server.workspaces.map { workspace in
                CommanderPlace(id: TeamsPlace.workspace(workspace.id, on: server.id), title: workspace.name.multiplayerDisplay,
                               mark: .letter(String(workspace.name.prefix(1)).uppercased()), count: workspace.claims.count,
                               countNoun: workspace.claims.count == 1 ? "claim" : "claims")
            }
        }
    }

    /// What the sample directory returns for any search that isn't for nothing.
    static func search(_ query: String) -> MultiplayerDirectorySearch {
        if query.lowercased().contains("zz") { return MultiplayerDirectorySearch(query: query) }
        return MultiplayerDirectorySearch(query: query, handles: ["sam", "samira"], resources: [
            MultiplayerDirectoryHit(id: "res-mira-claude", handle: "mira", name: "mira-claude", kind: MultiplayerResourceKind.agent.rawValue,
                                    actions: [MultiplayerSharePolicy.ask, MultiplayerSharePolicy.handoff, MultiplayerSharePolicy.review],
                                    capabilities: NetworkSample.opus,
                                    endorsements: [MultiplayerEndorsement(handle: "ines", skill: "swift"),
                                                   MultiplayerEndorsement(handle: "sam", skill: "swift"),
                                                   MultiplayerEndorsement(handle: "sam", skill: "code review")]),
            MultiplayerDirectoryHit(id: "host-build", handle: "mira", name: "build-box", kind: MultiplayerResourceKind.host.rawValue,
                                    actions: [MultiplayerSharePolicy.hostRun],
                                    endorsements: [MultiplayerEndorsement(handle: "priya", skill: "fast builds")]),
            MultiplayerDirectoryHit(id: "host-rack", handle: "ines", name: "ios-rack", kind: MultiplayerResourceKind.host.rawValue,
                                    actions: [MultiplayerSharePolicy.hostRun])
        ])
    }

    static func run(_ draft: MultiplayerHostRunDraft, request: String) -> MultiplayerSentRequest {
        let fails = draft.arguments.contains { $0.lowercased().contains("fail") }
        let output = fails
            ? "$ \(draft.command) \(draft.argumentText)\n=== RUN   TestLeaseRenewal\n--- FAIL: TestLeaseRenewal (0.52s)\n    lease_test.go:42: timer fired after release\nFAIL\nexit status 1"
            : "$ \(draft.command)\(draft.arguments.isEmpty ? "" : " " + draft.argumentText)\n=== RUN   TestRetryBudget\n--- PASS: TestRetryBudget (0.31s)\n=== RUN   TestLeaseRenewal\n--- PASS: TestLeaseRenewal (0.48s)\nPASS\nok  \trelay/integration\t41.2s"
        return MultiplayerSentRequest(request: request, resource: "host-build", action: MultiplayerSharePolicy.hostRun,
                                      title: draft.command, at: now, status: "ok",
                                      value: .object(["command": .string(draft.command), "exitCode": .number(fails ? 1 : 0),
                                                      "output": .string(output), "seconds": .number(41)]))
    }
}

// MARK: - Preview state

/// The sample teams state, the window's own state over it, and the sample's side of the action
/// boundary. It stands in for the Teams model.
@Observable @MainActor
final class TeamsPreviewState {
    var content = TeamsSample.content
    let state = TeamsPagesState()
    /// How long a sample action takes, so its progress can be seen. Tests shorten it.
    var latency: Duration = .milliseconds(450)
    /// Cards whose first claim the sample relay refuses.
    private var contested: Set<String> = [TeamsSample.contested]
    /// Goes to the network pages' own flows. Set by the shell preview.
    @ObservationIgnored var shareHost: (_ resource: String, _ server: String) -> Void = { _, _ in }
    @ObservationIgnored var requestAccess: (_ resource: String, _ server: String) -> Void = { _, _ in }

    /// `place` opens that page's detail, so a page opened directly shows what choosing a row shows.
    init(place: String? = nil, band: TeamsBand? = nil) {
        switch place {
        case TeamsSample.relayPlace?:
            let band = band ?? .combined
            state.selection.band[TeamsSample.relayKey] = band
            if band == .board { state.selection.card = TeamsKey.make("card-3", on: TeamsSample.relayKey) }
        case TeamsPlace.groups?:
            state.selection.group = TeamsKey.make("g-relay", on: TeamsSample.studio)
        case TeamsPlace.hosts?:
            state.selection.host = TeamsKey.make("host-build", on: TeamsSample.studio)
            state.drafts.hostRun = MultiplayerHostRunDraft(command: "make-integration")
        case TeamsPlace.knowledge?:
            state.selection.knowledge = TeamsKey.make("k-1", on: TeamsSample.studio)
        case TeamsPlace.directory?:
            state.drafts.query = "swift"
            state.selection.searchServer = TeamsSample.studio
            state.search = .loaded(TeamsSample.search("swift"))
            state.selection.hit = TeamsKey.make("res-mira-claude", on: TeamsSample.studio)
        default:
            break
        }
        // The policy draft starts from the saved policy, as it does when Admin is opened.
        state.selection.adminServer = TeamsSample.studio
        state.drafts.policy = MultiplayerPolicyDraft(TeamsSample.policy)
    }

    convenience init(scenario: DesignPreviewScenario) {
        self.init(place: scenario.teamsPlace, band: scenario == .teamsBoard ? .board : nil)
    }

    func pages(go: @escaping (String) -> Void) -> TeamsPages { state.pages(content, through: actions, go: go) }

    // MARK: Shell counts

    /// The sample's workspaces as the navigation lists them, with their live claims.
    var workspacePlaces: [CommanderPlace] { TeamsSample.workspacePlaces(content) }

    // MARK: Sample changes

    private func pause() async { try? await Task.sleep(for: latency) }

    private func update(_ id: String, _ change: (inout TeamsPagesContent.Server) -> Void) {
        guard let index = content.servers.firstIndex(where: { $0.id == id }) else { return }
        change(&content.servers[index])
    }

    private func updateWorkspace(_ id: String, on server: String, _ change: (MultiplayerWorkspace) -> MultiplayerWorkspace) {
        update(server) { found in
            guard let index = found.workspaces.firstIndex(where: { $0.id == id }) else { return }
            found.workspaces[index] = change(found.workspaces[index])
        }
    }

    private func setClaims(_ id: String, on server: String, _ change: ([MultiplayerClaim]) -> [MultiplayerClaim]) {
        updateWorkspace(id, on: server) { old in
            MultiplayerWorkspace(id: old.id, owner: old.owner, group: old.group, name: old.name, goal: old.goal,
                                 repository: old.repository, base: old.base, integration: old.integration, claims: change(old.claims))
        }
    }

    private func setCard(_ id: String, in key: String, state: String, assignee: String, result: String? = nil) {
        guard let index = content.cards[key]?.firstIndex(where: { $0.id == id }), let old = content.cards[key]?[index] else { return }
        content.cards[key]?[index] = MultiplayerCard(id: old.id, title: old.title, body: old.body, state: state, assignee: assignee,
                                                     result: result ?? old.result)
    }

    private func setGroup(_ id: String, on server: String, members: ([String]) -> [String]) {
        update(server) { found in
            guard let index = found.groups.firstIndex(where: { $0.id == id }) else { return }
            let old = found.groups[index]
            found.groups[index] = MultiplayerGroup(id: old.id, name: old.name, owner: old.owner, members: members(old.members))
        }
    }

    private func setQueue(_ entry: MultiplayerQueueEntry, in key: String, state: String, output: String = "") {
        guard let index = content.queue[key]?.firstIndex(where: { $0.id == entry.id }) else { return }
        content.queue[key]?[index] = MultiplayerQueueEntry(workspace: entry.workspace, branch: entry.branch, checkout: entry.checkout,
                                                           test: entry.test, added: entry.added, state: state, output: output)
    }

    /// Paths overlap when one is the other or lies under it.
    static func overlaps(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    // MARK: The boundary

    /// The boundary every sample teams action crosses, with the results the Teams model will give.
    var actions: TeamsPageActions {
        var actions = TeamsPageActions()
        actions.claim = { [self] draft, workspace, server in
            await pause()
            let key = TeamsKey.make(workspace, on: server), handle = content.handle(on: server), now = content.now
            let claims = content.workspace(key)?.workspace.claims ?? []
            let wanted = draft.trimmedKey.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let holder = claims.first { claim in
                guard claim.kind == draft.kind.rawValue else { return false }
                if draft.kind == .issue { return claim.key == draft.trimmedKey }
                return wanted.contains { path in claim.key.split(separator: ",").contains { Self.overlaps(path, $0.trimmingCharacters(in: .whitespaces)) } }
            }
            if let holder {
                // The relay answers an overlapping claim with 409 and the holder.
                return .failed(id: draft.trimmedKey, server: server,
                               reason: MultiplayerSentence.join("Couldn’t claim it.", "relay HTTP 409: overlapping claim held by \(holder.holder)"))
            }
            setClaims(workspace, on: server) {
                $0 + [MultiplayerClaim(id: "cl-\($0.count + 20)", kind: draft.kind.rawValue, key: draft.trimmedKey,
                                       holder: "\(handle)/\(draft.trimmedAgent)", expiresAt: now.addingTimeInterval(3_600))]
            }
            return .done(id: draft.trimmedKey, server: server, message: "Claimed \(draft.trimmedKey) for \(draft.trimmedAgent).")
        }
        actions.release = { [self] claim, workspace, server in
            await pause()
            let key = TeamsKey.make(workspace, on: server)
            let found = content.workspace(key)?.workspace.claims.first { $0.id == claim }
            setClaims(workspace, on: server) { $0.filter { $0.id != claim } }
            if let found, found.kind == MultiplayerClaim.Kind.card.rawValue { setCard(found.key, in: key, state: "open", assignee: "") }
            return .done(id: claim, server: server, message: "Released \(found?.key ?? claim).")
        }
        actions.createCard = { [self] draft, workspace, server in
            await pause()
            let key = TeamsKey.make(workspace, on: server)
            let id = "card-\((content.cards[key]?.count ?? 0) + 30)"
            content.cards[key, default: []].insert(MultiplayerCard(id: id, title: draft.trimmedTitle, body: draft.body), at: 0)
            return .done(id: id, server: server, message: "Added “\(draft.trimmedTitle)” to the board.")
        }
        actions.claimCard = { [self] card, workspace, server in
            await pause()
            let key = TeamsKey.make(workspace, on: server), handle = content.handle(on: server), now = content.now
            if contested.remove(card) != nil {
                // Someone else's agent claimed it a moment before: the relay says who.
                let holder = "sam/sam-codex"
                setCard(card, in: key, state: "claimed", assignee: holder)
                setClaims(workspace, on: server) {
                    $0 + [MultiplayerClaim(id: "cl-\($0.count + 20)", kind: "card", key: card, holder: holder,
                                           expiresAt: now.addingTimeInterval(1_800))]
                }
                return .failed(id: card, server: server,
                               reason: MultiplayerSentence.join("Couldn’t claim it.", "relay HTTP 409: overlapping claim held by \(holder)"))
            }
            let holder = "\(handle)/relay-worker"
            setCard(card, in: key, state: "claimed", assignee: holder)
            setClaims(workspace, on: server) {
                $0 + [MultiplayerClaim(id: "cl-\($0.count + 20)", kind: "card", key: card, holder: holder,
                                       expiresAt: now.addingTimeInterval(3_600))]
            }
            return .done(id: card, server: server, message: "Claimed for relay-worker.")
        }
        actions.releaseCard = { [self] card, workspace, server in
            await pause()
            let key = TeamsKey.make(workspace, on: server)
            setCard(card, in: key, state: "open", assignee: "")
            setClaims(workspace, on: server) { $0.filter { !($0.kind == "card" && $0.key == card) } }
            return .done(id: card, server: server, message: "Released. The card is open again.")
        }
        actions.completeCard = { [self] card, result, workspace, server in
            await pause()
            let key = TeamsKey.make(workspace, on: server)
            let assignee = content.card(card, in: key)?.assignee ?? ""
            setCard(card, in: key, state: "done", assignee: assignee, result: result)
            setClaims(workspace, on: server) { $0.filter { !($0.kind == "card" && $0.key == card) } }
            return .done(id: card, server: server, message: "Completed. Its claim is released.")
        }
        actions.queueAdd = { [self] draft, workspace, server in
            await pause()
            let key = TeamsKey.make(workspace, on: server)
            if content.queue[key]?.contains(where: { $0.branch == draft.trimmedBranch && $0.isQueued }) == true {
                return .failed(id: draft.trimmedBranch, server: server, reason: "Couldn’t queue it. \(draft.trimmedBranch) is already in the queue.")
            }
            let entry = MultiplayerQueueEntry(workspace: workspace, branch: draft.trimmedBranch, checkout: draft.checkout,
                                              test: draft.testCommand,
                                              added: content.now.addingTimeInterval(Double(content.queue[key]?.count ?? 0)))
            content.queue[key, default: []].append(entry)
            return .done(id: draft.trimmedBranch, server: server, message: "Queued \(draft.trimmedBranch).")
        }
        actions.removeQueued = { [self] entry, workspace, server in
            await pause()
            let key = TeamsKey.make(workspace, on: server)
            let branch = content.queue[key]?.first { $0.id == entry }?.branch ?? "The branch"
            content.queue[key]?.removeAll { $0.id == entry }
            return .done(id: entry, server: server, message: "\(branch) is out of the queue. The branch itself stays.")
        }
        actions.runMerge = { [self] workspace, server in
            let key = TeamsKey.make(workspace, on: server)
            content.merging.insert(key)
            defer { content.merging.remove(key) }
            var merged = 0, stopped: [String] = []
            for entry in (content.queue[key] ?? []).filter(\.isQueued) {
                await pause()
                // The sample's one failing branch, so a stopped merge can be seen.
                if entry.branch.contains("lease-timer") {
                    setQueue(entry, in: key, state: "failed",
                             output: "Test Suite 'LeaseTests' started.\nLeaseTests.testRenewalStopsOnRelease: XCTAssertEqual failed: (\"1\") is not equal to (\"0\")\nExecuted 9 tests, with 1 failure in 2.4 seconds")
                    stopped.append(entry.branch)
                } else {
                    setQueue(entry, in: key, state: "merged")
                    merged += 1
                }
            }
            let base = content.workspace(key)?.workspace.base ?? "the base"
            let first = "Merged \(MultiplayerPlural.count(merged, "branch", "branches")) into \(base)."
            return .done(id: workspace, server: server,
                         message: stopped.isEmpty ? first : "\(first) \(stopped.formatted(.list(type: .and))) wasn’t merged: its tests failed.")
        }
        // The sample has no file panel.
        actions.chooseCheckout = { NetworkSample.checkout }
        actions.chooseInstallFile = { _ in TeamsSample.mcpFile }

        actions.createGroup = { [self] name, server in
            await pause()
            let handle = content.handle(on: server)
            var id = ""
            update(server) {
                id = "g-\($0.groups.count + 10)"
                $0.groups.append(MultiplayerGroup(id: id, name: name, owner: handle, members: [handle]))
            }
            state.selection.group = TeamsKey.make(id, on: server)
            return .done(id: id, server: server, message: "Created \(name). Add friends to it.")
        }
        actions.setMember = { [self] handle, group, server, isMember in
            await pause()
            setGroup(group, on: server) { isMember ? $0 + [handle] : $0.filter { $0 != handle } }
            let name = content.groupName(group, on: server) ?? group
            return .done(id: handle, server: server,
                         message: isMember ? "\(handle) is in \(name) and has its grants." : "\(handle) is out of \(name) and lost its grants.")
        }
        actions.deleteGroup = { [self] group, server in
            await pause()
            let name = content.groupName(group, on: server) ?? group
            update(server) { $0.groups.removeAll { $0.id == group } }
            return .done(id: group, server: server, message: "Deleted \(name).")
        }
        actions.runHost = { [self] draft, resource, server in
            await pause()
            await pause()
            let reply = TeamsSample.run(draft, request: "run-\(UUID().uuidString.prefix(6))")
            return (.done(id: resource, server: server, message: nil), reply)
        }
        actions.shareKnowledge = { [self] draft, server in
            await pause()
            // The device checks for secrets before anything is sent.
            if MultiplayerSecretCheck.looksSecret(draft.content) {
                return .failed(id: draft.trimmedName, server: server, reason: MultiplayerSecretCheck.refusal)
            }
            let widest = content.widestScope(on: server)
            if draft.scope.rank > widest.rank {
                return .failed(id: draft.trimmedName, server: server,
                               reason: "Couldn’t share it. \(content.serverName(server)) lets knowledge reach \(TeamsKnowledgePage.reach(widest)) at most.")
            }
            let handle = content.handle(on: server), now = content.now
            var id = ""
            update(server) {
                id = "k-\($0.knowledge.count + 10)"
                $0.knowledge.insert(MultiplayerKnowledgeItem(id: id, owner: handle, kind: draft.kind.rawValue, name: draft.trimmedName,
                                                             content: draft.content, visibility: draft.visibility, version: 1,
                                                             createdAt: now), at: 0)
            }
            state.selection.knowledge = TeamsKey.make(id, on: server)
            return .done(id: id, server: server, message: "Shared \(draft.trimmedName) on \(content.serverName(server)).")
        }
        actions.installKnowledge = { [self] draft in
            await pause()
            let message: String
            switch draft.destination {
            case .skill: message = "Installed \(draft.name) at \(draft.shownDestination)."
            case .clipboard: message = "Copied \(draft.name)."
            case .file: message = "Saved \(draft.name) to \(draft.shownDestination)."
            }
            return .done(id: draft.item, server: draft.server, message: message)
        }
        actions.search = { [self] query, _ in
            await pause()
            return .loaded(TeamsSample.search(query))
        }
        actions.endorse = { [self] resource, skill, server in
            await pause()
            return .done(id: resource, server: server, message: "You endorsed it for \(skill) on \(content.serverName(server)).")
        }
        actions.setPolicy = { [self] draft, _, server in
            await pause()
            guard let policy = draft.policy else { return .failed(id: "policy", server: server, reason: "Couldn’t save the policy.") }
            update(server) { $0.policy = policy }
            state.drafts.policy = MultiplayerPolicyDraft(policy)
            return .done(id: "policy", server: server, message: "Policy set on \(content.serverName(server)).")
        }
        actions.setSuspended = { [self] handle, server, suspended in
            await pause()
            update(server) { found in
                guard let index = found.members.firstIndex(where: { $0.handle == handle }) else { return }
                found.members[index].isSuspended = suspended
                // A suspended member's devices are cut off.
                if suspended { found.devices.removeAll { $0.owner == handle } }
            }
            let name = content.serverName(server)
            return .done(id: handle, server: server,
                         message: suspended ? "\(handle) is suspended on \(name)." : "\(handle) can use \(name) again.")
        }
        actions.revokeDevice = { [self] device, server in
            await pause()
            let name = content.server(server)?.devices.first { $0.id == device }?.name ?? device
            update(server) { $0.devices.removeAll { $0.id == device } }
            return .done(id: device, server: server, message: "\(name) is signed out of \(content.serverName(server)).")
        }
        actions.shareHost = { [self] resource, server in shareHost(resource, server) }
        actions.requestAccess = { [self] resource, server in requestAccess(resource, server) }
        return actions
    }
}
