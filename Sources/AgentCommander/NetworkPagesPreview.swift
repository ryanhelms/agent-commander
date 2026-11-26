import SwiftUI

// ATOMIC LEVEL: Pages (design previews of the network pages).
// The nine network pages with sample values, clickable: every action changes the sample state the
// way the network model will. Nothing here contacts the service, the helper or the network model.
//
//   open "dist/Agent Commander.app" --args --design-preview network-servers
//   … network-directory, network-approvals, network-handoffs, network-threads, network-audit,
//     network-fanout, network-shared, people
//
// Each opens sidebar B on that place; the other places are a click away.
//
//   NetworkSample         the sample network: three servers, their friends, requests and work
//   NetworkPreviewState   the sample state and what each action does to it

extension DesignPreviewScenario {
    /// The place a network scenario opens on.
    var networkPlace: String? {
        switch self {
        case .networkServers: NetworkPlace.servers
        case .networkDirectory: NetworkPlace.directory
        case .networkApprovals: NetworkPlace.approvals
        case .networkHandoffs: NetworkPlace.handoffs
        case .networkThreads: NetworkPlace.threads
        case .networkAudit: NetworkPlace.audit
        case .networkFanout: NetworkPlace.fanout
        case .networkShared: NetworkPlace.shared
        case .people: NetworkPlace.people
        default: nil
        }
    }
}

// MARK: - Sample values

enum NetworkSample {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let studio = "srv-studio", lab = "srv-lab", harbor = "srv-harbor"
    /// Where the sample Apply puts an artifact.
    static let checkout = NSHomeDirectory() + "/GitHub/relay"

    private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private static func stamp(_ seconds: TimeInterval) -> String { MultiplayerTime.format(ago(seconds)) }

    /// Values whose only initialiser reads the helper's JSON.
    static func decode<Value: Decodable>(_ json: String) -> [Value] {
        (try? JSONDecoder().decode([Value].self, from: Data(json.utf8))) ?? []
    }

    static let studioPin = "sha256/Jc0mE2oUq9Ww3X6r1uY5tPz8LkQnVbA4sD7fGhH2jK0="
    static let harborPin = "sha256/9Qe7Rk2TtY4uI6oP8aS0dF1gH3jK5lZ7xC9vB2nM4qW="
    static let harborNewPin = "sha256/Zx3Cv5Bn7Mq9We1Rt3Yu5Io7Pa9Sd1Fg3Hj5Kl7Zx9C="

    static let opus = MultiplayerCapabilities(harness: "claude", model: "opus-5.5", slots: 3, tools: ["go", "make"], environments: ["macos"])
    static let codex = MultiplayerCapabilities(harness: "codex", model: "gpt-5.5", slots: 2, tools: ["go", "docker"], environments: ["linux"])
    static let fable = MultiplayerCapabilities(harness: "claude", model: "fable-5.2", slots: 1, tools: ["swift"], environments: ["macos"])

    static let agentActions = [MultiplayerSharePolicy.ask, MultiplayerSharePolicy.handoff, MultiplayerSharePolicy.watch,
                               MultiplayerSharePolicy.suggest, MultiplayerSharePolicy.review]
        + MultiplayerSharePolicy.thread + MultiplayerSharePolicy.tracking

    static func handoffReport(result: Bool) -> MultiplayerHandoffReport? {
        var value: [String: MultiplayerJSON] = [
            "state": .string(result ? "done" : "running"),
            "summary": .string(result ? "The retry budget is now per request. 14 tests pass." : "Running make integration: 9 of 14 tests so far."),
            "updatedAt": .string(stamp(result ? 60 : 240))
        ]
        if result {
            value["artifacts"] = .array([
                .object(["kind": .string("report"), "name": .string("report.md"),
                         "content": .string("## Retry budget\n\nMoved the budget from the client to each request.\n\n- `retry/budget.go` holds the counter\n- `retry/policy.go` reads it before each attempt\n\nAll 14 integration tests pass.")]),
                .object(["kind": .string("patch"), "name": .string("retry-budget.patch"), "content": .string("diff --git a/retry/budget.go b/retry/budget.go")]),
                .object(["kind": .string("branch"), "name": .string("handoff/retry-budget")])
            ])
        }
        return MultiplayerHandoffReport(reply: MultiplayerSentRequest(request: "rq-result-1", status: "ok", value: .object(value)),
                                        isResult: result)
    }

    static let reviewValue = MultiplayerJSON.object([
        "summary": .string("The lease renewal is correct. Two things need a change before merge."),
        "findings": .array([
            .object(["file": .string("relay/lease.go"), "line": .number(118), "severity": .string("important"),
                     "text": .string("The renewal timer is not stopped when the lease is released, so it fires once more.")]),
            .object(["file": .string("relay/lease_test.go"), "line": .number(42), "severity": .string("important"),
                     "text": .string("The test sleeps for a fixed 50 ms. Use the fake clock so it can’t flake.")]),
            .object(["file": .string("relay/lease.go"), "line": .number(64), "severity": .string("nit"),
                     "text": .string("`ttl` reads better as `lifetime` here.")])
        ])
    ])

    static func thread(for request: String) -> MultiplayerThread {
        let comments: [MultiplayerComment] = decode("""
        [{"id":"c1","author":"ryan","authorKind":"user","at":"\(stamp(3_300))","text":"Keep the public API as it is. Only the counter moves."},
         {"id":"c2","author":"mira-claude","authorKind":"agent","at":"\(stamp(3_120))","text":"Understood. I’ll keep RetryPolicy’s fields and add the budget to the request context."},
         {"id":"c3","author":"mira","authorKind":"user","at":"\(stamp(1_500))","text":"It may run make integration on my Mac. I approved that."},
         {"id":"c4","author":"mira-claude","authorKind":"agent","at":"\(stamp(240))","text":"9 of 14 integration tests pass so far. The rest are running."}]
        """)
        return MultiplayerThread(comments: request == "ho-1" ? comments : Array(comments.prefix(2)))
    }

    static let audit: [MultiplayerAuditEntry] = decode("""
    [{"request":"au-9","peer":"mira","resource":"res-relay","action":"agent.handoff","started":"\(stamp(52))","ended":"","outcome":"pending","tokens":0,"summary":"Run the integration tests"},
     {"request":"au-8","peer":"jonah","resource":"res-docs","action":"agent.ask","started":"\(stamp(900))","ended":"\(stamp(858))","outcome":"ok","tokens":4210,"summary":"Which retries are safe after partial bodies?"},
     {"request":"au-7","peer":"ines","resource":"res-relay","action":"agent.watch","started":"\(stamp(2_400))","ended":"\(stamp(2_100))","outcome":"ok","tokens":0,"summary":"Watched Retry policy for 5 minutes"},
     {"request":"au-6","peer":"jonah","resource":"res-docs","action":"agent.ask","started":"\(stamp(5_400))","ended":"\(stamp(5_380))","outcome":"denied","tokens":0,"summary":"Read the deploy keys file"},
     {"request":"au-5","peer":"mira","resource":"res-relay","action":"agent.ask","started":"\(stamp(7_800))","ended":"\(stamp(7_731))","outcome":"ok","tokens":8932,"summary":"Explain the backoff ceiling"},
     {"request":"au-4","peer":"mira","resource":"res-relay","action":"review.request","started":"\(stamp(9_600))","ended":"\(stamp(9_420))","outcome":"ok","tokens":15604,"summary":"Review the lease renewal diff"},
     {"request":"au-3","peer":"ines","resource":"res-relay","action":"agent.suggest","started":"\(stamp(12_000))","ended":"\(stamp(11_990))","outcome":"expired","tokens":0,"summary":"Try the fake clock in the lease test"},
     {"request":"au-2","peer":"jonah","resource":"res-docs","action":"agent.ask","started":"\(stamp(14_400))","ended":"\(stamp(14_352))","outcome":"budget_exhausted","tokens":20000,"summary":"Summarise every design note"}]
    """)

    static func summary(_ id: String, _ name: String, state: MultiplayerServerState, pin: String = "", favorite: Bool = false,
                        autoConnect: Bool = true, signedIn: Bool = true, handle: String = "ryan", friendsOnline: Int = 0,
                        incoming: Int = 0, presence: MultiplayerPersonPresence? = .online, lastSeen: Date? = nil) -> MultiplayerServerSummary {
        MultiplayerServerSummary(id: id, url: "https://\(name).example", name: name, favorite: favorite, autoConnect: autoConnect,
                                 pin: pin, lastUsedAt: ago(600), state: state, signedIn: signedIn, handle: signedIn ? handle : "",
                                 lastSeen: lastSeen, friendsOnline: friendsOnline, incoming: incoming, presence: signedIn ? presence : nil)
    }

    /// Three servers: studio (online, most of the work), lab (online) and harbor, whose certificate changed.
    static var content: NetworkPagesContent {
        var studioServer = NetworkPagesContent.Server(summary: summary(studio, "studio", state: .online, pin: studioPin, favorite: true,
                                                                       friendsOnline: 2, incoming: 1))
        studioServer.isOnline = true
        studioServer.handle = "ryan"
        studioServer.displayName = "Ryan"
        studioServer.statusMessage = "Reviewing the retry policy"
        studioServer.isAdmin = true
        studioServer.membershipMode = "invite"
        studioServer.friends = [MultiplayerFriend(handle: "mira", online: true), MultiplayerFriend(handle: "ines", online: true),
                                MultiplayerFriend(handle: "priya", online: false)]
        studioServer.friendRequests = [MultiplayerIncoming(id: "fr-1", handle: "tomas", requestedAt: ago(5_400))]
        studioServer.resources = decode("""
        [{"id":"res-relay","name":"relay-worker","kind":"agent","actions":["agent.ask","agent.handoff","agent.watch","agent.suggest","review.request","thread.read","thread.comment","agent.status","agent.result"]},
         {"id":"res-docs","name":"docs-agent","kind":"agent","actions":["agent.ask","thread.read","thread.comment"]},
         {"id":"res-repo","name":"relay","kind":"repo","actions":["issue.read","issue.comment","git.head"]}]
        """)
        studioServer.grants = [
            MultiplayerGrant(id: "g-1", handle: "mira", kind: "agent", resource: "res-relay", capability: MultiplayerSharePolicy.handoff,
                             maxUses: 10, expiresAt: now.addingTimeInterval(20 * 3600)),
            MultiplayerGrant(id: "g-2", handle: "mira", kind: "agent", resource: "res-relay", capability: MultiplayerSharePolicy.ask,
                             maxUses: 10, expiresAt: now.addingTimeInterval(20 * 3600)),
            MultiplayerGrant(id: "g-3", handle: "ines", kind: "agent", resource: "res-relay", capability: MultiplayerSharePolicy.watch,
                             maxUses: nil, expiresAt: now.addingTimeInterval(6 * 24 * 3600)),
            MultiplayerGrant(id: "g-4", handle: "priya", kind: "agent", resource: "res-docs", capability: MultiplayerSharePolicy.ask,
                             maxUses: 1, expiresAt: now.addingTimeInterval(2_700)),
            MultiplayerGrant(id: "g-5", handle: "mira", kind: "repo", resource: "res-repo", capability: "issue.read",
                             maxUses: 100, expiresAt: now.addingTimeInterval(3 * 24 * 3600))
        ]
        studioServer.directory = [
            MultiplayerDirectoryEntry(id: "d-mira", name: "mira-claude", kind: "agent", owner: "mira", offered: agentActions,
                                      granted: [MultiplayerSharePolicy.ask, MultiplayerSharePolicy.handoff, MultiplayerSharePolicy.review]
                                        + MultiplayerSharePolicy.thread + MultiplayerSharePolicy.tracking,
                                      capabilities: opus,
                                      endorsements: [MultiplayerEndorsement(handle: "ines", skill: "go"), MultiplayerEndorsement(handle: "jonah", skill: "go"),
                                                     MultiplayerEndorsement(handle: "priya", skill: "reviews")]),
            MultiplayerDirectoryEntry(id: "d-ines", name: "ines-fable", kind: "agent", owner: "ines", offered: agentActions,
                                      granted: [MultiplayerSharePolicy.ask] + MultiplayerSharePolicy.thread, capabilities: fable),
            MultiplayerDirectoryEntry(id: "d-priya", name: "priya-codex", kind: "agent", owner: "priya", offered: agentActions,
                                      capabilities: codex),
            MultiplayerDirectoryEntry(id: "d-build", name: "build-box", kind: "host", owner: "priya", offered: [MultiplayerSharePolicy.hostRun])
        ]
        studioServer.approvals = [
            MultiplayerApproval(id: "ap-2", peer: "mira", resource: "res-relay", action: MultiplayerSharePolicy.handoff,
                                summary: "Run the integration tests", arrived: ago(48), expires: now.addingTimeInterval(252)),
            MultiplayerApproval(id: "ap-3", peer: "ines", resource: "res-relay", action: MultiplayerSharePolicy.suggest,
                                summary: "Try the fake clock in the lease test", arrived: ago(20), expires: now.addingTimeInterval(4_260))
        ]
        studioServer.incomingAccess = [
            MultiplayerAccessRequest(id: "ac-1", resource: "res-relay", owner: "ryan", requester: "ines",
                                     actions: [MultiplayerSharePolicy.ask], note: "For the lease test.", createdAt: ago(1_260))
        ]
        studioServer.outgoingAccess = [
            MultiplayerAccessRequest(id: "ac-2", resource: "d-priya", owner: "priya", requester: "ryan",
                                     actions: [MultiplayerSharePolicy.ask], note: "A second opinion on the backoff.", createdAt: ago(5_400)),
            MultiplayerAccessRequest(id: "ac-3", resource: "d-ines", owner: "ines", requester: "ryan",
                                     actions: [MultiplayerSharePolicy.ask], status: "granted", createdAt: ago(90_000))
        ]
        studioServer.handoffs = [
            MultiplayerSentRequest(request: "ho-1", resource: "d-mira", action: MultiplayerSharePolicy.handoff, title: "Move the retry budget to each request",
                                   at: ago(3_400), status: "ok", value: .object(["run": .string("run-7f3a")])),
            MultiplayerSentRequest(request: "ho-2", resource: "d-mira", action: MultiplayerSharePolicy.handoff, title: "Port the lease tests to the fake clock",
                                   at: ago(900), status: "pending"),
            MultiplayerSentRequest(request: "ho-3", resource: "d-ines", action: MultiplayerSharePolicy.handoff, title: "Draft the migration note",
                                   at: ago(88_000), status: "denied", failure: "ines denied this request.")
        ]
        studioServer.reviews = [
            MultiplayerSentRequest(request: "rv-1", resource: "d-mira", action: MultiplayerSharePolicy.review, title: "Lease renewal",
                                   at: ago(9_600), status: "ok", value: reviewValue)
        ]
        studioServer.fanouts = [
            MultiplayerFanout(request: "fo-1", title: "Name the option that caps retries per request", at: ago(1_800), children: [
                MultiplayerFanoutChild(id: "fo-1-a", resource: "d-mira", status: "ok",
                                       value: .string("`retryBudget`. It says what is spent, and it reads well beside `timeoutBudget`, which the client already has.")),
                MultiplayerFanoutChild(id: "fo-1-b", resource: "d-ines", status: "ok",
                                       value: .string("`maxAttempts`. Every HTTP client a reader has used calls it that, so nobody has to look it up.")),
                MultiplayerFanoutChild(id: "fo-1-c", resource: "d-priya", status: "pending")
            ]),
            MultiplayerFanout(request: "fo-2", title: "Is a 60 s backoff ceiling too high?", at: ago(86_000), children: [
                MultiplayerFanoutChild(id: "fo-2-a", resource: "d-mira", status: "ok", value: .string("No. Above 30 s the client is waiting on an outage, and 60 s halves the load on recovery.")),
                MultiplayerFanoutChild(id: "fo-2-b", resource: "d-ines", status: "ok", value: .string("Yes for interactive calls. Keep 30 s there and use 60 s for background work."))
            ])
        ]
        // The tray's holder row counts down against the real clock, so this one is set from it.
        studioServer.handovers = [MultiplayerHandover(handle: "mira", user: "u-mira", resource: "res-relay",
                                                      until: Date().addingTimeInterval(1_140), server: studio, minutes: 30)]

        var labServer = NetworkPagesContent.Server(summary: summary(lab, "lab", state: .online, friendsOnline: 1, presence: .online))
        labServer.isOnline = true
        labServer.handle = "ryan"
        labServer.displayName = "Ryan H."
        labServer.friends = [MultiplayerFriend(handle: "jonah", online: true), MultiplayerFriend(handle: "mira", online: true)]
        labServer.resources = decode("""
        [{"id":"res-docs","name":"docs-agent","kind":"agent","actions":["agent.ask","thread.read","thread.comment"]}]
        """)
        labServer.grants = [MultiplayerGrant(id: "g-9", handle: "jonah", kind: "agent", resource: "res-docs",
                                             capability: MultiplayerSharePolicy.ask, maxUses: 10, expiresAt: now.addingTimeInterval(5 * 3600))]
        labServer.directory = [
            MultiplayerDirectoryEntry(id: "d-jonah", name: "jonah-codex", kind: "agent", owner: "jonah", offered: agentActions,
                                      granted: [MultiplayerSharePolicy.ask, MultiplayerSharePolicy.watch] + MultiplayerSharePolicy.thread,
                                      capabilities: codex)
        ]
        labServer.approvals = [
            MultiplayerApproval(id: "ap-1", peer: "jonah", resource: "res-docs", action: MultiplayerSharePolicy.ask,
                                summary: "Read docs/retries.md", arrived: ago(130), expires: now.addingTimeInterval(700))
        ]

        let harborServer = NetworkPagesContent.Server(summary: summary(harbor, "harbor", state: .certChanged, pin: harborPin, signedIn: false,
                                                                       lastSeen: ago(7_200)))

        var content = NetworkPagesContent(now: now)
        content.servers = [studioServer, labServer, harborServer]
        content.reports = ["ho-1": handoffReport(result: true)].compactMapValues { $0 }
        content.winners = [MultiplayerWinnerStore.key("fo-2", on: studio): "fo-2-a"]
        content.people = people(for: content.servers)
        content.friendsAvailable = 4
        content.activity = [
            MultiplayerActivityEvent(server: studio, seq: 9, at: ago(52), kind: "approval.pending", actor: "mira", resource: "res-relay",
                                     detail: MultiplayerSharePolicy.handoff),
            MultiplayerActivityEvent(server: studio, seq: 8, at: ago(1_260), kind: "access.requested", actor: "ines", resource: "res-relay"),
            MultiplayerActivityEvent(server: studio, seq: 7, at: ago(5_400), kind: "friend.request", actor: "tomas"),
            MultiplayerActivityEvent(server: lab, seq: 4, at: ago(9_000), kind: "grant.received", actor: "jonah", resource: "d-jonah", detail: "jonah-codex"),
            MultiplayerActivityEvent(server: studio, seq: 6, at: ago(20_000), kind: "member.joined", actor: "priya"),
            MultiplayerActivityEvent(server: lab, seq: 3, at: ago(90_000), kind: "friend.accepted", actor: "jonah")
        ]
        content.hasActivity = true
        content.unseen = 3
        content.activityActors = ["ines", "jonah", "mira", "priya", "tomas"]
        return content
    }

    static func people(for servers: [NetworkPagesContent.Server]) -> [MultiplayerFriendGroup] {
        let presence: [String: MultiplayerPersonPresence] = ["mira": .online, "ines": .busy, "priya": .offline, "jonah": .away]
        let status = ["mira": "Pairing on the retry budget", "ines": "In a review until 3", "jonah": "Back at 2"]
        let names = ["mira": "Mira Okafor", "jonah": "Jonah Reyes"]
        return servers.map { server in
            let entries = server.friends.map { friend in
                MultiplayerContactEntry(server: server.id, handle: friend.handle, displayName: names[friend.handle] ?? "",
                                        presence: presence[friend.handle] ?? (friend.online == true ? .online : .offline),
                                        statusMessage: status[friend.handle] ?? "", hasAvatar: false,
                                        alsoOn: friend.handle == "mira" ? [server.id == studio ? "lab" : "studio"] : [])
            }
            return MultiplayerFriendGroup(server: server.summary, friends: MultiplayerFriendGroup.sorted(server.friends),
                                          incoming: server.friendRequests, isOnline: server.isOnline,
                                          canShare: !server.resources.isEmpty, people: entries)
        }
    }

    /// What the fresh check of harbor shows: a key other than the pinned one.
    static let harborProbe = MultiplayerProbeState.finished(
        MultiplayerProbe(url: "https://harbor.example", steps: [
            MultiplayerProbeStep(step: "dns", ok: true), MultiplayerProbeStep(step: "tcp", ok: true),
            MultiplayerProbeStep(step: "tls", ok: true, pin: harborNewPin, systemTrusted: false)
        ]), address: "https://harbor.example")

    /// The route a place opens on in a render, so every page shows its detail.
    static func route(for place: String) -> MultiplayerTrayRoute {
        switch place {
        case NetworkPlace.servers: .server(harbor)
        case NetworkPlace.approvals: .share(studio, .approval("ap-2"))
        case NetworkPlace.handoffs: .share(studio, .handoffDetail(request: "ho-1"))
        case NetworkPlace.threads: .share(studio, .thread(request: "ho-1", title: "Move the retry budget to each request"))
        case NetworkPlace.audit: .share(studio, .audit(resource: ""))
        case NetworkPlace.fanout: .share(studio, .compare(request: "fo-1"))
        default: .home
        }
    }
}

// MARK: - Preview state

/// The sample network and what each action does to it. It stands in for the network model.
@Observable @MainActor
final class NetworkPreviewState {
    var content = NetworkSample.content
    var selection = NetworkPagesSelection(directory: "\(NetworkSample.studio)/d-mira", shared: "\(NetworkSample.studio)/res-relay")
    var nickname = ""
    var access = MultiplayerAccessDraft()
    var grant = MultiplayerShareDraft()
    var comment = ""
    var fanout = MultiplayerFanoutDraft()
    var reviewLink = "https://github.com/example/relay/pull/212"
    var profile = MultiplayerProfileDraft()
    var activityServer: String?
    var activityFriend: String?
    let results = NetworkRowResults()
    /// How long a sample action takes.
    var latency: Duration = .milliseconds(350)
    /// The sample request whose first Withdraw fails, to show a row's failure.
    private var failsOnce: Set<String> = ["ac-2"]

    init(place: String? = nil) {
        if let place { open(NetworkSample.route(for: place)) }
    }

    /// Opens a route and loads what it shows, as the model does.
    func open(_ route: MultiplayerTrayRoute) {
        content.route = route
        content.confirmingRemoval = nil
        content.confirmingTrust = nil
        content.grantRefusal = nil
        switch route {
        case .server(let id):
            guard let server = content.server(id) else { return }
            nickname = server.summary.name
            content.probe = server.summary.state == .certChanged ? NetworkSample.harborProbe : .idle
        case .share(_, .thread(let request, _)):
            content.thread = .loaded(NetworkSample.thread(for: request))
            comment = ""
        case .share(_, .audit(let resource)):
            content.audit = .loaded(NetworkSample.audit.filter { resource.isEmpty || $0.resource == resource })
        case .profile(let id):
            guard let server = content.server(id) else { return }
            profile = MultiplayerProfileDraft(handle: server.handle, displayName: server.displayName, statusMessage: server.statusMessage,
                                              savedHandle: server.handle, savedDisplayName: server.displayName,
                                              savedStatusMessage: server.statusMessage)
        default:
            break
        }
    }

    private func update(_ id: String, _ change: (inout NetworkPagesContent.Server) -> Void) {
        guard let index = content.servers.firstIndex(where: { $0.id == id }) else { return }
        change(&content.servers[index])
        content.people = NetworkSample.people(for: content.servers)
    }

    private func resummarise(_ id: String, name: String? = nil, favorite: Bool? = nil, autoConnect: Bool? = nil,
                             state: MultiplayerServerState? = nil, pin: String? = nil, signedIn: Bool? = nil) {
        update(id) { server in
            let old = server.summary
            let signed = signedIn ?? old.signedIn
            server.summary = MultiplayerServerSummary(
                id: old.id, url: old.url, name: name ?? old.name, favorite: favorite ?? old.favorite,
                autoConnect: autoConnect ?? old.autoConnect, pin: pin ?? old.pin, lastUsedAt: old.lastUsedAt,
                state: state ?? old.state, signedIn: signed, handle: signed ? "ryan" : "", lastSeen: old.lastSeen,
                friendsOnline: old.friendsOnline, incoming: server.friendRequests.count, presence: signed ? .online : nil)
            server.isOnline = server.summary.state == .online
        }
    }

    /// The content as the pages read it now: the sample state, each row's result and the grant sheet's values.
    private var shown: NetworkPagesContent {
        var shown = content
        shown.results = results.results
        shown.running = results.running
        shown.canRename = { () -> Bool in
            guard let server = content.openServer else { return false }
            let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && name != server.summary.name
        }()
        shown.canTrust = content.probe.probe != nil && content.openServer?.summary.state == .certChanged
        shown.canComment = !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        shown.canSendFanout = fanout.canSend
        shown.canSaveProfile = profile.problem == nil && profile.hasChanges
        shown.activity = content.activity.filter {
            (activityServer == nil || $0.server == activityServer) && (activityFriend == nil || $0.actor == activityFriend)
        }
        if let resource = content.server(grant.server)?.resources.first(where: { $0.id == grant.resourceID }) {
            shown.grantResource = MultiplayerShareResource(id: resource.id, name: resource.name, kind: resource.kind,
                                                           offered: resource.actions, isNew: false)
            shown.grantCompanions = resource.actions.filter(MultiplayerSharePolicy.companions(for: grant.actions).contains)
        }
        shown.canGrant = !grant.handle.isEmpty && shown.grantResource != nil && !grant.actions.isEmpty && grant.budgetProblem == nil
        shown.grantHint = grant.handle.isEmpty ? "Choose a friend." : shown.grantResource == nil ? "Choose what to share."
            : grant.actions.isEmpty ? "Choose at least one action." : "You can revoke it at any time."
        return shown
    }

    private func pause() async { try? await Task.sleep(for: latency) }

    /// Changes the sample state once a row has shown its result, so the row leaves after it.
    private func afterResult(_ change: @escaping @MainActor () -> Void) {
        let dwell = results.dwell
        Task {
            try? await Task.sleep(for: dwell)
            change()
        }
    }

    /// The boundary every sample network action crosses, with the results the network model will give.
    var network: NetworkPageActions {
        NetworkPageActions(
            acceptFriend: { [self] request, server in
                await pause()
                afterResult { [self] in
                    update(server) { found in
                        found.friendRequests.removeAll { $0.id == request.id }
                        found.friends.append(MultiplayerFriend(handle: request.handle, online: true))
                    }
                    resummarise(server)
                }
                return .done(id: request.id, server: server,
                             message: "\(request.handle) is now a friend on \(content.serverName(server)).")
            },
            declineFriend: { [self] request, server in
                await pause()
                afterResult { [self] in
                    update(server) { $0.friendRequests.removeAll { $0.id == request.id } }
                    resummarise(server)
                }
                return .done(id: request.id, server: server, message: "Declined. \(request.handle) can ask again.")
            },
            decide: { [self] approval, server, approve in
                await pause()
                if content.route == .share(server, .approval(approval.id)) { open(.home) }
                afterResult { [self] in update(server) { $0.approvals.removeAll { $0.id == approval.id } } }
                return .done(id: approval.id, server: server,
                             message: approve ? "Approved. It runs on this Mac now." : "Denied. \(approval.peer) is told.")
            },
            removeAccess: { [self] request, server, declining in
                await pause()
                if failsOnce.remove(request.id) != nil {
                    return .failed(id: request.id, server: server,
                                   reason: "Couldn’t withdraw the request. \(content.serverName(server)) didn’t answer. Try again.")
                }
                afterResult { [self] in
                    update(server) {
                        $0.incomingAccess.removeAll { $0.id == request.id }
                        $0.outgoingAccess.removeAll { $0.id == request.id }
                    }
                }
                return .done(id: request.id, server: server,
                             message: declining ? "Declined \(request.requester)’s request." : "Request withdrawn.")
            },
            prepareGrant: { [self] server, handle, resource, actions in
                guard let found = content.server(server), found.isOnline else { return false }
                var draft = MultiplayerShareDraft(server: server)
                draft.handle = handle ?? (found.friends.count == 1 ? found.friends[0].handle : "")
                draft.resourceID = resource ?? (found.resources.count == 1 ? found.resources[0].id : "")
                draft.actions = actions
                grant = draft
                content.grantRefusal = nil
                return true
            },
            sendGrant: { [self] server in
                let draft = grant
                await pause()
                // The sample relay's one rule, so a refusal can be seen: no unlimited uses without asking.
                if draft.uses == .unlimited, draft.approval == .auto {
                    return .failed(id: draft.resourceID, server: server,
                                   reason: "The relay refused this grant: unlimited uses must ask each time.")
                }
                let expires = content.now.addingTimeInterval(draft.expiry.interval)
                update(server) { found in
                    for action in draft.actions.sorted() {
                        found.grants.append(MultiplayerGrant(id: "g-\(found.grants.count + 20)", handle: draft.handle, kind: "agent",
                                                             resource: draft.resourceID, capability: action,
                                                             maxUses: draft.uses == .unlimited ? nil : draft.uses.count, expiresAt: expires))
                    }
                    found.incomingAccess.removeAll { $0.requester == draft.handle && $0.resource == draft.resourceID }
                }
                let what = content.resourceName(draft.resourceID, on: server)
                return .done(id: draft.resourceID, server: server,
                             message: "\(draft.handle) can use \(what) until \(MultiplayerTime.display(expires, now: content.now)). "
                                + (draft.approval == .ask ? "Each use waits for your approval." : "Uses run without asking."))
            },
            // The sample has no file panel: every artifact goes to the same sample checkout.
            chooseCheckout: { _ in NetworkSample.checkout },
            applyArtifact: { [self] draft, _ in
                await pause()
                let message = draft.isPatch ? "Applied \(draft.name) to \(draft.folder). The changes are staged, not committed."
                                            : "Saved \(draft.name) into \(draft.folder)."
                content.notice = message
                return .done(id: draft.request, server: draft.server, message: message)
            })
    }

    /// Everything a page needs. `go` changes the window's place.
    func pages(go: @escaping (String) -> Void) -> NetworkPages {
        var actions = NetworkPagesActions()
        actions.go = go
        actions.select = { [self] in selection = $0 }
        actions.dismissNotice = { [self] in content.notice = nil }
        actions.dismissFailure = { [self] in content.failure = nil }
        actions.close = { [self] in open(.home) }
        actions.back = { [self] in open(.home) }
        actions.closeGrant = { [self] in selection.grant = nil }
        // The sample asks before it revokes, like the live page, and then leaves the grant as it is.
        actions.revoke = { _, _ in }
        actions.bind(network, results: results,
                     openGrant: { [self] in selection.grant = $0 },
                     grantServer: { [self] in selection.grant },
                     grantFinished: { [self] result in
                         if result.isDone {
                             grant = MultiplayerShareDraft()
                             selection.grant = nil
                             content.notice = result.message
                         } else {
                             content.grantRefusal = result.reason
                         }
                     })
        actions.bindApply(network, results: results,
                          draft: { [self] in selection.apply },
                          setDraft: { [self] in selection.apply = $0 },
                          row: { [self] draft in content.server(draft.server)?.handoffs.first { $0.request == draft.request } })
        actions.setGrantServer = { [self] server in
            grant.server = server
            grant.handle = ""
            grant.resourceID = ""
            selection.grant = server
        }
        actions.reconcileGrant = { [self] in
            let offered = content.server(grant.server)?.resources.first { $0.id == grant.resourceID }?.actions ?? []
            grant.actions = grant.actions.filter(offered.contains)
        }
        actions.toggleGrantAction = { [self] action in
            if grant.actions.contains(action) { grant.actions.remove(action) } else { grant.actions.insert(action) }
        }

        // Servers
        actions.openServer = { [self] in open(.server($0)) }
        actions.signIn = { [self] in resummarise($0, state: .online, signedIn: true) }
        actions.signOut = { [self] in
            resummarise($0, state: .signedOut, signedIn: false)
        }
        actions.rename = { [self] in
            guard let server = content.openServer else { return }
            resummarise(server.id, name: nickname.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        actions.setAutoConnect = { [self] server, value in resummarise(server.id, autoConnect: value) }
        actions.toggleFavorite = { [self] server in resummarise(server.id, favorite: !server.favorite) }
        actions.askRemove = { [self] server in
            content.confirmingTrust = nil
            content.confirmingRemoval = server.id
        }
        actions.cancelRemove = { [self] in content.confirmingRemoval = nil }
        actions.confirmRemove = { [self] in
            guard let id = content.confirmingRemoval else { return }
            let name = content.serverName(id)
            content.servers.removeAll { $0.id == id }
            content.people = NetworkSample.people(for: content.servers)
            open(.home)
            content.notice = "Removed \(name)."
        }
        actions.checkCertificate = { [self] _ in content.probe = NetworkSample.harborProbe }
        actions.askTrust = { [self] server in
            content.confirmingRemoval = nil
            content.confirmingTrust = server.id
        }
        actions.cancelTrust = { [self] in content.confirmingTrust = nil }
        actions.confirmTrust = { [self] in
            guard let id = content.confirmingTrust else { return }
            resummarise(id, state: .signedOut, pin: NetworkSample.harborNewPin)
            content.confirmingTrust = nil
            content.probe = .idle
            content.notice = "\(content.serverName(id)) is pinned to its new certificate."
        }

        // Directory
        actions.requestAccess = { [self] entry, server in
            access = MultiplayerAccessDraft(actions: entry.requestable.count == 1 ? Set(entry.requestable) : [])
            selection.directory = "\(server)/\(entry.id)"
            open(.share(server, .requestAccess(resource: entry.id)))
        }
        actions.sendAccessRequest = { [self] in
            guard let page = content.sharePage, case .requestAccess(let resource) = page.page,
                  let entry = content.entry(resource, on: page.server) else { return }
            let draft = access, now = content.now
            update(page.server) {
                $0.outgoingAccess.insert(MultiplayerAccessRequest(id: "ac-\($0.outgoingAccess.count + 10)", resource: resource,
                                                                  owner: entry.owner, requester: "ryan",
                                                                  actions: draft.actions.sorted(), note: draft.trimmedNote,
                                                                  createdAt: now), at: 0)
            }
            open(.home)
            content.notice = "Request sent. \(entry.owner) decides whether to share \(entry.name)."
        }

        // Approvals
        actions.openApproval = { [self] id, server in open(.share(server, .approval(id))) }

        // Hand-offs
        actions.openHandoff = { [self] request, server in open(.share(server, .handoffDetail(request: request))) }
        actions.check = { [self] row, _, result in
            if let report = NetworkSample.handoffReport(result: result) { content.reports[row.request] = report }
        }
        actions.openReview = { [self] request, server in open(.share(server, .review(request: request))) }
        actions.askPost = { [self] in content.confirmingPost = true }
        actions.cancelPost = { [self] in content.confirmingPost = false }
        actions.confirmPost = { [self] in
            guard let page = content.sharePage, case .review(let request) = page.page else { return }
            content.confirmingPost = false
            content.posted[request] = reviewLink
            content.notice = "Posted to the pull request as a review comment from your GitHub login."
        }

        // Threads and audit
        actions.openThread = { [self] request, title, server in open(.share(server, .thread(request: request, title: title))) }
        actions.postComment = { [self] in
            let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let data = try? JSONEncoder().encode(text), let quoted = String(data: data, encoding: .utf8) else { return }
            let added: [MultiplayerComment] = NetworkSample.decode("""
            [{"id":"c-\(UUID().uuidString)","author":"ryan","authorKind":"user","at":"\(MultiplayerTime.format(content.now))","text":\(quoted)}]
            """)
            content.thread = .loaded(MultiplayerThread(comments: (content.thread.value?.comments ?? []) + added))
            comment = ""
        }
        actions.openAudit = { [self] resource, server in open(.share(server, .audit(resource: resource))) }
        actions.reload = { [self] in open(content.route) }

        // Fan-out
        actions.openFanout = { [self] request, server in open(.share(server, .compare(request: request))) }
        actions.chooseWinner = { [self] child, request, server in
            let key = MultiplayerWinnerStore.key(request, on: server)
            content.winners[key] = content.winners[key] == child ? nil : child
        }
        actions.startFanout = { [self] server in
            fanout = MultiplayerFanoutDraft()
            open(.share(server, .fanout))
        }
        actions.toggleFanoutTarget = { [self] resource in
            if fanout.targets.contains(resource) { fanout.targets.remove(resource) } else { fanout.targets.insert(resource) }
        }
        actions.sendFanout = { [self] in
            guard let page = content.sharePage, page.page == .fanout, fanout.canSend else { return }
            let draft = fanout, now = content.now
            var request = ""
            update(page.server) { server in
                request = "fo-\(server.fanouts.count + 10)"
                let children = server.fanoutTargets.filter { draft.targets.contains($0.id) }.enumerated().map { index, entry in
                    MultiplayerFanoutChild(id: "\(request)-\(index)", resource: entry.id, status: "pending")
                }
                server.fanouts.insert(MultiplayerFanout(request: request, title: draft.title, at: now, children: children), at: 0)
            }
            fanout = MultiplayerFanoutDraft()
            open(.share(page.server, .compare(request: request)))
        }

        // Shared
        actions.takeBack = { [self] handover, server in
            update(server) { $0.handovers.removeAll { $0.id == handover.id } }
            content.notice = "You have control of \(content.resourceName(handover.resource, on: server)) again."
        }

        // People
        actions.editProfile = { [self] in open(.profile($0)) }
        actions.saveProfile = { [self] in
            guard let server = content.profileServer else { return }
            let draft = profile
            update(server.id) {
                $0.displayName = draft.trimmedDisplayName
                $0.statusMessage = draft.trimmedStatus
            }
            open(.home)
            content.notice = "Profile saved."
        }
        actions.markActivitySeen = { [self] in content.unseen = 0 }

        let drafts = NetworkPagesDrafts(
            nickname: Binding(get: { [self] in nickname }, set: { [self] in nickname = $0 }),
            access: Binding(get: { [self] in access }, set: { [self] in access = $0 }),
            grant: Binding(get: { [self] in grant }, set: { [self] in grant = $0 }),
            comment: Binding(get: { [self] in comment }, set: { [self] in comment = $0 }),
            fanout: Binding(get: { [self] in fanout }, set: { [self] in fanout = $0 }),
            reviewLink: Binding(get: { [self] in reviewLink }, set: { [self] in reviewLink = $0 }),
            profile: Binding(get: { [self] in profile }, set: { [self] in profile = $0 }),
            activityServer: Binding(get: { [self] in activityServer }, set: { [self] in activityServer = $0 }),
            activityFriend: Binding(get: { [self] in activityFriend }, set: { [self] in activityFriend = $0 }))
        return NetworkPages(content: shown, selection: selection, drafts: drafts, actions: actions)
    }

    // MARK: Shell counts

    /// The sample network's counts for the shell's navigation.
    var approvalCount: Int { content.servers.reduce(0) { $0 + $1.approvals.count } }
    var friendRequestCount: Int { content.friendRequests.count }
    var handoffCount: Int { content.servers.reduce(0) { $0 + $1.handoffs.count } }
    var health: CommanderServerHealth {
        CommanderServerHealth(online: content.servers.filter { $0.summary.state == .online }.count, total: content.servers.count)
    }
}
