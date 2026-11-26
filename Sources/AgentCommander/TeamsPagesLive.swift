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

    /// A host you lend. Its enrolled commands are not in the resource the relay lists.
    static func host(_ resource: MultiplayerResource, grants: [MultiplayerGrant]) -> TeamsHost {
        TeamsHost(id: resource.id, name: resource.name, grants: grants.filter { $0.resource == resource.id }.count)
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
                content.work[key] = TeamsLiveMapper.work(members: members, claims: workspace.claims) { handle in
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
    }

    func readWorkspace(_ key: String, _ model: MultiplayerModel) async {
        guard let parts = TeamsKey.split(key) else { return }
        await readCards(key, model)
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
        actions.claim = { draft, workspace, server in NetworkActionResult(await model.claim(draft, in: workspace, on: server)) }
        actions.release = { [self] id, workspace, server in
            guard let claim = teams.workspace(workspace, on: server)?.claims.first(where: { $0.id == id }) else { return gone(id, server, "claim") }
            let result = NetworkActionResult(await model.release(claim, in: workspace, on: server))
            // Releasing a card's claim reopens the card.
            if claim.kind == MultiplayerClaim.Kind.card.rawValue { await readCards(TeamsKey.make(workspace, on: server), model) }
            return result
        }
        actions.createCard = { [self] draft, workspace, server in
            let result = NetworkActionResult(await model.addCard(draft, to: workspace, on: server))
            await readCards(TeamsKey.make(workspace, on: server), model)
            return result
        }
        func move(_ id: String, _ workspace: String, _ server: String, to state: MultiplayerCard.State, result text: String = "") async -> NetworkActionResult {
            let key = TeamsKey.make(workspace, on: server)
            guard let card = self.cards[key]?.value?.first(where: { $0.id == id }) else { return gone(id, server, "card") }
            let result = NetworkActionResult(await model.updateCard(card, in: workspace, on: server, to: state, result: text))
            // A refused claim says who holds the card; the board read again shows it in their name.
            await self.readCards(key, model)
            return result
        }
        actions.claimCard = { id, workspace, server in await move(id, workspace, server, to: .claimed) }
        actions.releaseCard = { id, workspace, server in await move(id, workspace, server, to: .open) }
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

        // Admin. The live page hosts the model's own policy form; these serve a caller without it.
        actions.setPolicy = { draft, saved, server in
            NetworkActionResult(await model.savePolicy(draft, from: saved, on: server).result(id: server, server: server))
        }
        actions.setSuspended = { handle, server, suspended in NetworkActionResult(await model.setSuspended(suspended, member: handle, on: server)) }
        actions.revokeDevice = { device, server in NetworkActionResult(await model.revokeDevice(device, on: server)) }
        return actions
    }

    // MARK: Hosts

    /// The model's own teams hosts. Each keeps its draft and its refusal, names its target and
    /// never moves the tray. None scrolls: the page does.
    func host(_ model: MultiplayerModel) -> (TeamsHosted) -> AnyView {
        { [self] hosted in
            let cancel = { [self] in pages.hostCancelled(hosted) }
            let finish: (MultiplayerActionResult) -> Void = { [self] result in
                pages.hostFinished(hosted, NetworkActionResult(result))
                // A card's change is read again here, because the board is this window's own read.
                if case .card(_, let workspace) = hosted { Task { await readCards(workspace, model) } }
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
        let pages = state.pages.pages(state.content(model), through: actions, go: go, host: state.host(model))
        TeamsPageView(place: place, pages: pages)
            // Reads again when the place or the open row changes.
            .task(id: [place, state.pages.selection.knowledge ?? "", state.pages.selection.hit ?? ""]) {
                await state.read(place: place, model: model)
            }
    }
}
