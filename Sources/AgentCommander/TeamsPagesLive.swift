import AppKit
import SwiftUI

// ATOMIC LEVEL: The live page (main-window Teams pages).
// The only file that binds the Teams pages to the network model. It reads the model into
// `TeamsPagesContent` and sends every action to one of the model's calls that name their target
// (MultiplayerTeamsActions.swift). It never reads or moves the tray's route, and it never touches
// a draft of the tray's: opening anything here leaves the tray where it is.
//
// What the window owns:
// - Its place: which band, card, group, host, item, search and form is open (`TeamsPagesState`).
// - Its reads: each board, pull-request list, version list and reputation it asked for, kept by
//   key. The model's actions don't refresh these, so the window reads again after each action.
// - Its second presses: the model's actions ask nothing, so every delete, remove, release, suspend
//   and revoke waits here for a confirmation that names its target.
// Lists the model keeps per server for everyone (groups, workspaces with their claims, the
// library, the merge queue) are read from it each time the page is drawn.
//
//   TeamsLiveMapper       the model's values as the pages' values (pure)
//   TeamsPagesLiveState   the window's reads, its content and its side of the action boundary
//   LiveTeamsPage         a Teams page, read from the model

/// The model's values as the pages' values. Nothing here reads a model.
enum TeamsLiveMapper {
    /// A workspace's combined view from what the relay returns today: its group's members, and
    /// for each the agents that hold a claim. Branches and checks have no read yet.
    static func work(members: [String], claims: [MultiplayerClaim], online: (String) -> Bool) -> [TeamsMemberWork] {
        var handles = members
        for claim in claims where !handles.contains(claim.holderHandle) { handles.append(claim.holderHandle) }
        return handles.filter { !$0.isEmpty }.map { handle in
            var seen = Set<String>()
            let agents = claims.filter { $0.holderHandle == handle }.map(\.holderAgent).filter { !$0.isEmpty && seen.insert($0).inserted }
            return TeamsMemberWork(handle: handle, isOnline: online(handle),
                                   workers: agents.map { TeamsWorker(id: $0, name: $0, state: "Holds a claim", tone: .neutral) })
        }
    }

    /// A host you lend, with the commands enrolled for it on this Mac.
    static func host(_ resource: MultiplayerResource, grants: [MultiplayerGrant]) -> TeamsHost {
        TeamsHost(id: resource.id, name: resource.name, environment: resource.capabilities?.environments.first ?? "",
                  commands: resource.capabilities?.commands ?? [], grants: grants.filter { $0.resource == resource.id }.count)
    }

    /// The relay's combined view as the page's rows. A field the relay has no source for stays
    /// empty: no branch is a dash, and checks that aren't reported are never shown as zero.
    static func work(_ view: MultiplayerCombinedView) -> [TeamsMemberWork] {
        view.members.map { member in
            TeamsMemberWork(handle: member.handle, isOnline: member.online ?? false, workers: member.workers.map { worker in
                let tone: Tone = switch worker.knownState {
                case .working: .working
                case .online: .focus
                case .offline, nil: .neutral
                }
                let checks = worker.checks.map { TeamsChecks(passed: $0.passed, failed: $0.failed, isRunning: $0.running > 0) }
                return TeamsWorker(id: worker.id, name: worker.name,
                                   capabilities: MultiplayerCapabilities(harness: worker.harness, model: worker.model),
                                   state: worker.stateTitle, tone: tone, branch: worker.branch, checks: checks, claims: worker.claims)
            })
        }
    }

    /// The relay's members and devices as the Admin page's rows.
    static func members(_ roster: MultiplayerRelayRoster) -> [TeamsMember] {
        roster.members.map { TeamsMember(handle: $0.handle, isSuspended: $0.suspended, isAdmin: $0.admin, key: $0.id) }
    }

    static func devices(_ roster: MultiplayerRelayRoster) -> [TeamsDevice] {
        roster.devices.map { TeamsDevice(id: $0.id, name: $0.title, owner: $0.owner, lastSeen: $0.lastSeen, isOnline: $0.online) }
    }

    /// How a run of the merge queue ended, as one result: how many merged, and what stopped the rest.
    static func merge(_ load: MultiplayerLoad<[MultiplayerQueueEntry]>, workspace: String, base: String, on server: String) -> NetworkActionResult {
        switch load {
        case .failed(let reason):
            return .failed(id: workspace, server: server, reason: reason)
        case .loading:
            return .failed(id: workspace, server: server, reason: "Couldn’t run the merge queue.")
        case .loaded(let entries):
            let merged = entries.filter { $0.state == "merged" }.count
            let stopped = entries.filter { $0.state != "merged" }
            let first = "Merged \(MultiplayerPlural.count(merged, "branch", "branches")) into \(base.isEmpty ? "the base" : base.multiplayerDisplay)."
            guard !stopped.isEmpty else { return .done(id: workspace, server: server, message: first) }
            let names = stopped.map { "\($0.branch.multiplayerDisplay) (\($0.stateTitle.lowercased()))" }.formatted(.list(type: .and))
            return .done(id: workspace, server: server, message: "\(first) Not merged: \(names). Each keeps its output in the queue.")
        }
    }
}

/// What the live window keeps for the Teams pages.
@Observable @MainActor
final class TeamsPagesLiveState {
    let pages = TeamsPagesState()
    /// The window's own reads, by key.
    var cards: [String: MultiplayerLoad<[MultiplayerCard]>] = [:]
    var pullRequests: [String: MultiplayerLoad<MultiplayerPullRequestList>] = [:]
    var versions: [String: MultiplayerLoad<[MultiplayerKnowledgeItem]>] = [:]
    var reputation: [String: MultiplayerLoad<MultiplayerReputation>] = [:]
    /// A workspace's combined view, by workspace key. Missing until it is read; the page then
    /// shows the members and claim holders it can work out from the lists it has.
    var combined: [String: MultiplayerCombinedView] = [:]
    /// What each server tells a member: how widely its policy lets knowledge travel.
    var me: [String: MultiplayerMe] = [:]
    /// For a server the person administers: its policy, and its members and devices.
    var policies: [String: MultiplayerRelayPolicy] = [:]
    var rosters: [String: MultiplayerRelayRoster] = [:]
    var adminProblems: [String: String] = [:]
    var merging: Set<String> = []

    // MARK: Content

    /// The model's teams state as the pages read it. Every property read here is observed by the
    /// view that calls it.
    func content(_ model: MultiplayerModel, now: Date = Date()) -> TeamsPagesContent {
        let teams = model.share.teams
        var content = TeamsPagesContent(now: now)
        content.isUnavailable = model.unavailable != nil
        content.servers = teams.servers.map { summary in
            let id = summary.id
            let status = model.session(id)?.status
            var server = TeamsPagesContent.Server(id: id, name: summary.displayName, handle: teams.handle(on: id), isAdmin: model.isAdmin(id))
            server.friends = status?.friends ?? []
            server.groups = teams.groups[id] ?? []
            server.workspaces = teams.workspaces[id] ?? []
            server.knowledge = teams.knowledge[id] ?? []
            server.hosts = teams.myHosts(on: id).map { TeamsLiveMapper.host($0, grants: status?.grants ?? []) }
            server.offeredHosts = teams.friendHosts(on: id)
            server.knowledgeWidest = me[id]?.knowledgeWidestScope
            server.policy = policies[id]
            if let roster = rosters[id] {
                server.members = TeamsLiveMapper.members(roster)
                server.devices = TeamsLiveMapper.devices(roster)
            }
            server.adminProblem = adminProblems[id]
            server.requests = server.isAdmin ? model.requests.waiting[id] : nil
            return server
        }
        for server in content.servers {
            for workspace in server.workspaces {
                let key = TeamsKey.make(workspace.id, on: server.id)
                switch cards[key] {
                case .loaded(let list)?: content.cards[key] = list
                case .failed(let reason)?: content.cardProblems[key] = reason
                case .loading?, nil: content.readingCards.insert(key)
                }
                if workspace.usesQueue {
                    content.queue[key] = teams.queue(for: workspace.id)
                } else {
                    content.pullRequests[key] = pullRequests[key] ?? .loading
                }
                let members = server.groups.first { $0.id == workspace.group }?.members ?? []
                content.work[key] = combined[key].map(TeamsLiveMapper.work) ?? TeamsLiveMapper.work(members: members, claims: workspace.claims) { handle in
                    handle == server.handle || server.friends.first { $0.handle == handle }?.online == true
                }
            }
        }
        content.merging = merging
        content.versions = versions
        content.reputation = reputation
        return content
    }

    // MARK: Reads

    /// Reads what the open place and the open rows need. Called when either changes.
    func read(place: String, model: MultiplayerModel) async {
        // The lists the model keeps per server, for a window opened before the tray.
        model.share.teams.refresh()
        if let key = TeamsPlace.workspaceKey(of: place) { await readWorkspace(key, model) }
        if place == TeamsPlace.knowledge, let key = pages.selection.knowledge { await readVersions(key, model) }
        if place == TeamsPlace.directory, let key = pages.selection.hit { await readReputation(key, model) }
        if place == TeamsPlace.knowledge { await readMe(model) }
        if place == TeamsPlace.admin, let server = adminServer(model) { await readAdmin(server, model) }
    }

    /// The server the Admin page shows: the one chosen, or the first the person administers.
    func adminServer(_ model: MultiplayerModel) -> String? {
        let admin = model.share.teams.servers.map(\.id).filter { model.isAdmin($0) }
        return pages.selection.adminServer.flatMap { admin.contains($0) ? $0 : nil } ?? admin.first
    }

    /// Reads what each server tells its members, so a share can name the widest scope allowed.
    func readMe(_ model: MultiplayerModel) async {
        for server in model.share.teams.servers.map(\.id) {
            if case .loaded(let found) = await model.share.teams.loadMe(on: server) { me[server] = found }
        }
    }

    /// Reads a server's policy and its members and devices. The policy form starts from the saved
    /// policy the first time it is read; after that the draft is the person's own.
    func readAdmin(_ server: String, _ model: MultiplayerModel, resetsDraft: Bool = false) async {
        let teams = model.share.teams
        let policy = await teams.loadPolicy(on: server)
        if let saved = policy.value {
            if policies[server] == nil || resetsDraft { pages.drafts.policy = MultiplayerPolicyDraft(saved) }
            policies[server] = saved
        }
        let roster = await teams.loadRoster(on: server)
        if let found = roster.value { rosters[server] = found }
        adminProblems[server] = policy.failure ?? roster.failure
        // The requests to join are the model's own list, read on the tray's cadence too. A relay
        // that won't list them leaves the band out, with no problem shown.
        await model.requests.readWaiting(on: server)?.value
    }

    func readWorkspace(_ key: String, _ model: MultiplayerModel) async {
        guard let parts = TeamsKey.split(key) else { return }
        await readCards(key, model)
        await readCombined(key, model)
        if model.share.teams.workspace(parts.id, on: parts.server)?.usesQueue == false {
            if pullRequests[key]?.value == nil { pullRequests[key] = .loading }
            pullRequests[key] = await model.share.teams.loadPullRequests(in: parts.id, on: parts.server)
        }
    }

    /// Reads a board again. A failed read after a change keeps the board already shown.
    func readCards(_ key: String, _ model: MultiplayerModel) async {
        guard let parts = TeamsKey.split(key) else { return }
        let next = await model.share.teams.loadCards(in: parts.id, on: parts.server)
        if next.value != nil || cards[key]?.value == nil { cards[key] = next }
    }

    /// Reads a workspace's combined view. A failed read keeps what was shown.
    func readCombined(_ key: String, _ model: MultiplayerModel) async {
        guard let parts = TeamsKey.split(key) else { return }
        if case .loaded(let view) = await model.share.teams.loadCombinedView(of: parts.id, on: parts.server) { combined[key] = view }
    }

    func readVersions(_ key: String, _ model: MultiplayerModel) async {
        guard let parts = TeamsKey.split(key) else { return }
        if versions[key]?.value == nil { versions[key] = .loading }
        versions[key] = await model.share.teams.loadVersions(of: parts.id, on: parts.server)
    }

    func readReputation(_ key: String, _ model: MultiplayerModel) async {
        guard let parts = TeamsKey.split(key) else { return }
        if reputation[key]?.value == nil { reputation[key] = .loading }
        reputation[key] = await model.share.teams.loadReputation(of: parts.id, on: parts.server)
    }

    // MARK: The boundary

    /// Every teams action, sent to the model's call that names its target. Each result is the
    /// model's own, case for case. The model's actions don't refresh the window's reads, so each
    /// one that changes a board reads it again before it returns.
    func actions(_ model: MultiplayerModel, share: @escaping @MainActor (_ resource: String, _ server: String) -> Void,
                 requestAccess: @escaping @MainActor (_ resource: String, _ server: String) -> Void) -> TeamsPageActions {
        let teams = model.share.teams
        func gone(_ id: String, _ server: String, _ what: String) -> NetworkActionResult {
            .failed(id: id, server: server, reason: "Commander can’t find this \(what) any more. It may have changed on the relay.")
        }
        var actions = TeamsPageActions()

        // Workspace
        actions.editWorkspace = { edit, workspace, server in NetworkActionResult(await model.editWorkspace(workspace, to: edit, on: server)) }
        actions.leaveWorkspace = { [self] workspace, server in
            let name = teams.workspace(workspace, on: server)?.name.multiplayerDisplay ?? "the workspace"
            let result = NetworkActionResult(await model.leaveWorkspace(workspace, on: server))
            guard result.isDone else { return result }
            let key = TeamsKey.make(workspace, on: server)
            (cards[key], combined[key], pullRequests[key]) = (nil, nil, nil)
            return .done(id: workspace, server: server, message: result.message ?? "Left \(name). Your claims in it have ended.")
        }
        // The answer names who stopped a refused claim, so the page can mark that claim's row.
        actions.claim = { [self] draft, workspace, server in
            let answer = await model.claimAnswer(draft, in: workspace, on: server)
            await readCombined(TeamsKey.make(workspace, on: server), model)
            return TeamsClaimOutcome(result: NetworkActionResult(answer.result), refusal: answer.refusal)
        }
        actions.release = { [self] id, workspace, server in
            guard let claim = teams.workspace(workspace, on: server)?.claims.first(where: { $0.id == id }) else { return gone(id, server, "claim") }
            let result = NetworkActionResult(await model.release(claim, in: workspace, on: server))
            // Releasing a card's claim reopens the card.
            if claim.kind == MultiplayerClaim.Kind.card.rawValue { await readCards(TeamsKey.make(workspace, on: server), model) }
            await readCombined(TeamsKey.make(workspace, on: server), model)
            return result
        }
        actions.createCard = { [self] draft, workspace, server in
            let result = NetworkActionResult(await model.addCard(draft, to: workspace, on: server))
            await readCards(TeamsKey.make(workspace, on: server), model)
            return result
        }
        func move(_ id: String, _ workspace: String, _ server: String, to state: MultiplayerCard.State, result text: String = "") async -> TeamsClaimOutcome {
            let key = TeamsKey.make(workspace, on: server)
            guard let card = self.cards[key]?.value?.first(where: { $0.id == id }) else { return TeamsClaimOutcome(result: gone(id, server, "card")) }
            let answer = state == .done ? await model.completeCardAnswer(card, in: workspace, on: server, result: text)
                                        : await model.updateCardAnswer(card, in: workspace, on: server, to: state, result: text)
            // A refused claim says who holds the card; the board read again shows it in their name.
            await self.readCards(key, model)
            await self.readCombined(key, model)
            return TeamsClaimOutcome(result: NetworkActionResult(answer.result), refusal: answer.refusal)
        }
        actions.claimCard = { id, workspace, server in await move(id, workspace, server, to: .claimed) }
        actions.releaseCard = { id, workspace, server in await move(id, workspace, server, to: .open).result }
        actions.completeCard = { id, text, workspace, server in await move(id, workspace, server, to: .done, result: text) }
        actions.queueAdd = { draft, workspace, server in NetworkActionResult(await model.addToQueue(draft, for: workspace, on: server)) }
        actions.removeQueued = { id, workspace, server in
            guard let entry = teams.queue(for: workspace).first(where: { $0.id == id }) else { return gone(id, server, "queued branch") }
            return NetworkActionResult(await model.removeFromQueue(entry, on: server))
        }
        actions.runMerge = { [self] workspace, server in
            let key = TeamsKey.make(workspace, on: server)
            merging.insert(key)
            defer { merging.remove(key) }
            let base = teams.workspace(workspace, on: server)?.base ?? ""
            return TeamsLiveMapper.merge(await model.runQueue(workspace, on: server), workspace: workspace, base: base, on: server)
        }
        actions.chooseCheckout = { MultiplayerFilePanel.chooseCheckout(for: "the branch") }

        // Groups
        actions.createGroup = { [self] name, server in
            let result = NetworkActionResult(await model.createGroup(named: name, on: server))
            if result.isDone, !result.id.isEmpty { pages.selection.group = TeamsKey.make(result.id, on: server) }
            return result
        }
        actions.setMember = { handle, id, server, isMember in
            guard let group = teams.group(id, on: server) else { return gone(id, server, "group") }
            return NetworkActionResult(isMember ? await model.addMember(handle, to: group, on: server)
                                                : await model.removeMember(handle, from: group, on: server))
        }
        actions.deleteGroup = { id, server in
            guard let group = teams.group(id, on: server) else { return gone(id, server, "group") }
            return NetworkActionResult(await model.deleteGroup(group, on: server))
        }

        // Hosts
        actions.runHost = { draft, resource, server in
            let answer = await model.runOnHost(draft, resource: resource, on: server)
            return (NetworkActionResult(answer.result(id: resource, server: server)), answer.value)
        }
        actions.shareHost = share
        actions.requestAccess = requestAccess

        // Knowledge
        actions.shareKnowledge = { [self] draft, server in
            let result = NetworkActionResult(await model.shareKnowledge(draft, on: server))
            if result.isDone, !result.id.isEmpty { pages.selection.knowledge = TeamsKey.make(result.id, on: server) }
            return result
        }
        actions.installKnowledge = { draft in
            guard let item = teams.item(draft.item, on: draft.server) else { return gone(draft.item, draft.server, "item") }
            var destination = ""
            if case .file(let path) = draft.destination { destination = path }
            return NetworkActionResult(await model.installKnowledge(item, on: draft.server, destination: destination))
        }
        actions.chooseInstallFile = { name in MultiplayerFilePanel.chooseDestination(named: name) }

        // Directory and reputation
        actions.search = { query, server in await teams.searchDirectory(query, on: server) }
        actions.endorse = { [self] resource, skill, server in
            let result = NetworkActionResult(await model.endorse(resource, for: skill, on: server))
            await readReputation(TeamsKey.make(resource, on: server), model)
            return result
        }

        // Admin. The page draws the policy form and the member and device lists itself, so each
        // change is followed by a read of what it changed.
        actions.setPolicy = { [self] draft, saved, server in
            // The page says what was saved, as every Admin change does. The band is Admin's alone.
            let name = model.server(server)?.displayName ?? server
            let result = NetworkActionResult(await model.savePolicy(draft, from: saved, on: server)
                .result(id: server, server: server, message: "Policy set on \(name)."))
            if result.isDone { await readAdmin(server, model, resetsDraft: true) }
            return result
        }
        actions.setSuspended = { [self] handle, server, suspended in
            let result = NetworkActionResult(await model.setSuspended(suspended, member: handle, on: server))
            await readAdmin(server, model)
            return result
        }
        actions.revokeDevice = { [self] device, server in
            let result = NetworkActionResult(await model.revokeDevice(device, on: server))
            await readAdmin(server, model)
            return result
        }
        actions.decideRequest = { [self] request, server, approve in
            let result = NetworkActionResult(await model.decideMembershipRequest(request, on: server, approve: approve))
            // An approval is a member the next time they sign in; the lists are read again either way.
            await readAdmin(server, model)
            return result
        }
        return actions
    }

    // MARK: Hosts

    /// The model's own teams hosts. Each keeps its draft and its refusal, names its target and
    /// never moves the tray. None scrolls: the page does.
    /// `place` is the page the hosts are shown on: what a host confirms is said there alone.
    func host(_ model: MultiplayerModel, place: String? = nil) -> (TeamsHosted) -> AnyView {
        { [self] hosted in
            // Every host is given `onCancel`, so Cancel puts it away and the page is as it was.
            let cancel = { [self] in pages.hostCancelled(hosted) }
            let finish: (MultiplayerActionResult) -> Void = { [self] result in
                pages.hostFinished(hosted, NetworkActionResult(result), from: place)
                // A card's change is read again here, because the board is this window's own read.
                switch hosted {
                case .card(_, let workspace): Task { await readCards(workspace, model); await readCombined(workspace, model) }
                case .claim(let workspace): Task { await readCombined(workspace, model) }
                default: break
                }
            }
            switch hosted {
            case .workspace(let server):
                return AnyView(MultiplayerWorkspaceHost(model: model, server: server, scrolls: false, onCancel: cancel, onFinish: finish))
            case .claim(let key):
                let parts = TeamsKey.split(key) ?? ("", "")
                return AnyView(MultiplayerClaimHost(model: model, server: parts.server, workspace: parts.id, scrolls: false,
                                                    onCancel: cancel, onFinish: finish))
            case .card(let card, let key):
                let parts = TeamsKey.split(key) ?? ("", "")
                return AnyView(MultiplayerCardHost(model: model, server: parts.server, workspace: parts.id, card: card, scrolls: false,
                                                   onCancel: cancel, onFinish: finish))
            case .queue(let key):
                let parts = TeamsKey.split(key) ?? ("", "")
                return AnyView(MultiplayerQueueHost(model: model, server: parts.server, workspace: parts.id, scrolls: false,
                                                    onCancel: cancel, onFinish: finish))
            case .knowledge(let server):
                return AnyView(MultiplayerKnowledgeHost(model: model, server: server, scrolls: false, onCancel: cancel, onFinish: finish))
            case .hostRun(let key):
                let parts = TeamsKey.split(key) ?? ("", "")
                return AnyView(MultiplayerHostRunHost(model: model, server: parts.server, resource: parts.id, scrolls: false,
                                                      onCancel: cancel, onFinish: { _ in }))
            case .policy(let server):
                return AnyView(MultiplayerPolicyHost(model: model, server: server, scrolls: false, onCancel: cancel, onFinish: { _ in }))
            }
        }
    }
}

/// A Teams page in the live window, read from the network model.
struct LiveTeamsPage: View {
    let place: String
    let model: MultiplayerModel
    let state: TeamsPagesLiveState
    let go: (String) -> Void
    /// Opens the network pages' share sheet for a resource. The grant sheet is theirs.
    var share: @MainActor (_ resource: String, _ server: String) -> Void = { _, _ in }

    var body: some View {
        let actions = state.actions(model, share: share, requestAccess: { _, _ in go(NetworkPlace.directory) })
        let pages = state.pages.pages(state.content(model), place: place, through: actions, go: go, host: state.host(model, place: place))
        TeamsPageView(place: place, pages: pages)
            // Reads again when the place or the open row changes.
            .task(id: [place, state.pages.selection.knowledge ?? "", state.pages.selection.hit ?? "",
                       state.pages.selection.adminServer ?? ""]) {
                await state.read(place: place, model: model)
            }
            // What a page said stays on that page: it is cleared when the window leaves it, for
            // another Teams page or for any other place.
            .onChange(of: place) { old, _ in state.pages.left(old) }
            .onDisappear { state.pages.left(place) }
    }
}
