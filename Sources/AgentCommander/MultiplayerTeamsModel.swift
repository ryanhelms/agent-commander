import Foundation
import Observation

// FEATURE MODEL: teams (design/COMMANDER-NETWORK-INCREMENT-5.md).
// MultiplayerShareModel owns one of these and routes its pages. Rules it keeps:
// - Groups, workspaces and the knowledge library are read quietly for every signed-in server, and
//   only while a panel is open. A page's own list (cards, versions, reputation, policy, a search)
//   is read when the page opens.
// - Every change goes through the tray's one action at a time, so its progress, refusal and
//   confirmation show in the tray's banner.
// - A claim is made in the person's own name: the holder is "<their handle>/<agent>".
// - A host runs only what its owner enrolled. The run travels through `send` like any request, so
//   the owner's grant and approval rules apply.
// - Knowledge that seems to carry a secret is refused here before it is sent, and by the device.
// - Deleting a group, removing a member, releasing a claim or a card, removing a queued branch,
//   suspending a member and revoking a device each ask once more first.
// - A host run carries extra arguments only for a command whose owner allows them.
// - Each change has two forms. The tray's own call reads the tray's draft, checks its second press
//   and, where it moves the tray, sends nothing unless the tray is on its page. It then calls the
//   form that names its target and takes the caller's values, which never reads or moves the
//   route and leaves the tray's drafts and page lists alone. A view outside the tray awaits that
//   form through MultiplayerTeamsActions.swift.

/// A destructive step waiting for its second press.
enum MultiplayerTeamsConfirmation: Equatable {
    case deleteGroup(String)
    case removeMember(group: String, handle: String)
    /// A claim, by its ID.
    case releaseClaim(String)
    /// A card the person holds, by its ID.
    case releaseCard(String)
    /// A merge-queue entry, by its ID.
    case removeQueued(String)
    case suspend(String)
    case revokeDevice(String)
}

@Observable @MainActor
final class MultiplayerTeamsModel {
    @ObservationIgnored weak var share: MultiplayerShareModel?

    private(set) var groups: [String: [MultiplayerGroup]] = [:]
    private(set) var workspaces: [String: [MultiplayerWorkspace]] = [:]
    private(set) var knowledge: [String: [MultiplayerKnowledgeItem]] = [:]
    /// The merge queue on this Mac, for every workspace.
    private(set) var queue: [MultiplayerQueueEntry] = []

    private(set) var cards: MultiplayerLoad<[MultiplayerCard]> = .loading
    /// The open pull requests of the workspace page now open, when it lands work by pull request.
    private(set) var pullRequests: MultiplayerLoad<MultiplayerPullRequestList> = .loading
    private(set) var versions: MultiplayerLoad<[MultiplayerKnowledgeItem]> = .loading
    private(set) var reputation: MultiplayerLoad<MultiplayerReputation> = .loading
    private(set) var search: MultiplayerLoad<MultiplayerDirectorySearch> = .loaded(MultiplayerDirectorySearch())
    private(set) var policy: MultiplayerLoad<MultiplayerRelayPolicy> = .loading
    /// What came back from the host run just sent.
    private(set) var hostReply: MultiplayerSentRequest?
    /// Requests whose outcome was reported from this panel, and how.
    private(set) var outcomes: [String: Bool] = [:]
    private(set) var confirming: MultiplayerTeamsConfirmation?
    /// Why the last knowledge item wasn't shared, when a secret was the reason.
    private(set) var secretRefusal: String?

    var groupDraft = ""
    var workspaceDraft = MultiplayerWorkspaceDraft()
    var claimDraft = MultiplayerClaimDraft()
    var cardDraft = MultiplayerCardDraft()
    var resultDraft = ""
    var queueDraft = MultiplayerQueueDraft()
    var hostDraft = MultiplayerHostRunDraft()
    var knowledgeDraft = MultiplayerKnowledgeDraft()
    var endorseDraft = ""
    var searchDraft = ""
    var policyDraft = MultiplayerPolicyDraft()

    private let client: MultiplayerClient?
    private let clock: () -> Date
    @ObservationIgnored private(set) var quietTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pageTask: Task<Void, Never>?
    @ObservationIgnored private var pageToken = 0
    /// The workspace page reads its pull requests beside its board, so that read has its own task.
    @ObservationIgnored private(set) var pullRequestTask: Task<Void, Never>?
    @ObservationIgnored private var pullRequestToken = 0

    init(client: MultiplayerClient?, now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.clock = now
    }

    private var tray: MultiplayerModel? { share?.tray }

    private func status(_ server: String) -> MultiplayerStatus? {
        guard let session = tray?.session(server), session.isOnline else { return nil }
        return session.status
    }

    func handle(on server: String) -> String { status(server)?.handle ?? "" }

    // MARK: - Lifetime

    /// Reads groups, workspaces, the library and the merge queue for every signed-in server.
    func refresh() {
        guard let client, let tray, tray.viewers > 0, quietTask == nil else { return }
        let ids = tray.servers.filter { $0.state == .online && $0.signedIn }.map(\.id)
        let online = Set(ids)
        groups = groups.filter { online.contains($0.key) }
        workspaces = workspaces.filter { online.contains($0.key) }
        knowledge = knowledge.filter { online.contains($0.key) }
        guard !ids.isEmpty else { return }
        quietTask = Task {
            for id in ids where !Task.isCancelled {
                let scoped = client.scoped(to: id)
                if let next = try? await scoped.groups() { self.groups[id] = next }
                if let next = try? await scoped.workspaces() { self.workspaces[id] = next }
                if let next = try? await scoped.knowledge() { self.knowledge[id] = next }
            }
            if let first = ids.first, let next = try? await client.scoped(to: first).mergeQueue() { self.queue = next }
            self.quietTask = nil
        }
    }

    /// The tray left the share pages.
    func left() {
        pageTask?.cancel()
        pageTask = nil
        pageToken &+= 1
        pullRequestTask?.cancel()
        pullRequestTask = nil
        pullRequestToken &+= 1
        confirming = nil
        secretRefusal = nil
    }

    func cancel() {
        quietTask?.cancel()
        quietTask = nil
        left()
    }

    /// Reads what a page needs as it opens. Pages of other features are ignored.
    func load(_ page: MultiplayerSharePage, on server: String) {
        confirming = nil
        switch page {
        case .groups, .group, .workspaces, .hosts, .knowledge: refresh()
        case .workspace(let id):
            loadCards(id, on: server)
            loadPullRequests(id, on: server)
        case .card(let id, _): loadCards(id, on: server)
        case .knowledgeItem(let id): loadVersions(id, on: server)
        case .reputation(let resource): loadReputation(resource, on: server)
        case .policy: loadPolicy(on: server)
        default: break
        }
    }

    /// Runs one page read, dropping the answer if the page has changed since.
    private func read<Value: Equatable & Sendable>(_ keyPath: ReferenceWritableKeyPath<MultiplayerTeamsModel, MultiplayerLoad<Value>>,
                                                   keeping: Bool = false,
                                                   _ work: @escaping @MainActor (MultiplayerClient) async throws -> Value) {
        guard let client else { return }
        pageTask?.cancel()
        pageToken &+= 1
        let token = pageToken
        if !keeping || self[keyPath: keyPath].value == nil { self[keyPath: keyPath] = .loading }
        pageTask = Task {
            let result: Result<Value, MultiplayerFailure>
            do { result = .success(try await work(client)) } catch { result = .failure(.from(error)) }
            guard token == self.pageToken else { return }
            self.pageTask = nil
            switch result {
            case .success(let value): self[keyPath: keyPath] = .loaded(value)
            case .failure(let failure):
                self[keyPath: keyPath] = .failed(failure == .cancelled ? "The read was stopped. Try again." : failure.message)
            }
        }
    }

    // MARK: - Derived values

    /// Servers where teams can be read and changed now.
    var servers: [MultiplayerServerSummary] { (tray?.servers ?? []).filter { status($0.id) != nil } }

    var allGroups: [MultiplayerPending<MultiplayerGroup>] {
        servers.flatMap { server in (groups[server.id] ?? []).map { MultiplayerPending(server: server.id, item: $0) } }
    }

    var allWorkspaces: [MultiplayerPending<MultiplayerWorkspace>] {
        servers.flatMap { server in (workspaces[server.id] ?? []).map { MultiplayerPending(server: server.id, item: $0) } }
    }

    func group(_ id: String, on server: String) -> MultiplayerGroup? { groups[server]?.first { $0.id == id } }
    func groupName(_ id: String, on server: String) -> String { group(id, on: server)?.name ?? id }
    func workspace(_ id: String, on server: String) -> MultiplayerWorkspace? { workspaces[server]?.first { $0.id == id } }
    func item(_ id: String, on server: String) -> MultiplayerKnowledgeItem? { knowledge[server]?.first { $0.id == id } }
    func card(_ id: String) -> MultiplayerCard? { cards.value?.first { $0.id == id } }

    /// Groups a grant can go to: the ones the person owns.
    func ownedGroups(on server: String) -> [MultiplayerGroup] {
        let me = handle(on: server)
        return (groups[server] ?? []).filter { $0.isOwned(by: me) }
    }

    /// Friends who aren't in the group yet.
    func addable(to group: MultiplayerGroup, on server: String) -> [MultiplayerFriend] {
        (status(server)?.friends ?? []).filter { !group.members.contains($0.handle) }
    }

    func queue(for workspace: String) -> [MultiplayerQueueEntry] { queue.filter { $0.workspace == workspace } }

    /// Hosts you lend, on one server.
    func myHosts(on server: String) -> [MultiplayerResource] {
        (status(server)?.resources ?? []).filter { $0.kind == MultiplayerResourceKind.host.rawValue }
    }

    /// Hosts friends lend, on one server: the ones you can run on first.
    func friendHosts(on server: String) -> [MultiplayerDirectoryEntry] {
        (share?.directory(server) ?? []).filter(\.isHost).sorted { $0.canRunOnHost && !$1.canRunOnHost }
    }

    var hostCount: Int { servers.reduce(0) { $0 + myHosts(on: $1.id).count + friendHosts(on: $1.id).count } }
    var knowledgeCount: Int { servers.reduce(0) { $0 + (knowledge[$1.id]?.count ?? 0) } }

    /// The agent a claim is made for when the person hasn't named one: their first enrolled agent.
    func defaultAgent(on server: String) -> String {
        let names = (status(server)?.resources ?? []).filter { $0.kind == MultiplayerResourceKind.agent.rawValue }.map(\.name)
        return names.first(where: MultiplayerClaimDraft.isAgentName) ?? "me"
    }

    /// Finished requests you sent to a resource, which you can judge.
    func judgeable(_ resource: String, on server: String) -> [MultiplayerSentRequest] {
        let handoffs = share?.handoffs[server] ?? []
        let reviews = share?.live.reviews[server] ?? []
        return (handoffs + reviews).filter { $0.resource == resource && $0.succeeded }
    }

    // MARK: - Confirmations

    func ask(_ step: MultiplayerTeamsConfirmation) { confirming = step }
    func cancelConfirmation() { confirming = nil }

    // MARK: - Groups

    /// Why a group can't take this name, when it can't.
    nonisolated static func groupNameProblem(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the group a name." }
        return name.utf8.count <= 128 ? nil : "Keep the name under 128 bytes."
    }

    var canCreateGroup: Bool { tray?.isBusy == false && Self.groupNameProblem(groupDraft) == nil }

    /// Creates the group typed on the tray's Groups page, then opens it.
    @discardableResult
    func createGroup(on server: String) -> Task<Void, Never>? {
        guard canCreateGroup, tray?.route == .share(server, .groups) else { return nil }
        return createGroup(named: groupDraft, on: server, then: { id in
            self.groupDraft = ""
            if !id.isEmpty { self.share?.open(.group(id), on: server) }
        })
    }

    /// Creates a group with the caller's name. `then` is given the new group's ID.
    @discardableResult
    func createGroup(named name: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                     then: (@MainActor (String) -> Void)? = nil) -> Task<Void, Never>? {
        guard Self.groupNameProblem(name) == nil else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return tray?.act("Creating \(name.multiplayerDisplay)…", failing: "Couldn’t create the group.", report: report) { client in
            let scoped = client.scoped(to: server)
            let id = try await scoped.createGroup(name: name)
            self.groups[server] = try await scoped.groups()
            then?(id)
            self.tray?.post(notice: "Created \(name.multiplayerDisplay). Add friends to it next.")
        }
    }

    /// Adds a friend at once. Removing one takes the group's grants away, so it is sent only from
    /// its confirmation.
    @discardableResult
    func setMember(_ handle: String, in group: MultiplayerGroup, on server: String, isMember: Bool) -> Task<Void, Never>? {
        if !isMember {
            guard confirming == .removeMember(group: group.id, handle: handle) else { return nil }
            confirming = nil
        }
        return changeMember(handle, in: group, on: server, isMember: isMember)
    }

    /// Adds a friend to a group, or removes a member. The caller asks before a removal.
    @discardableResult
    func changeMember(_ handle: String, in group: MultiplayerGroup, on server: String, isMember: Bool,
                      report: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<Void, Never>? {
        let who = handle.multiplayerDisplay, name = group.name.multiplayerDisplay
        return tray?.act(isMember ? "Adding \(who) to \(name)…" : "Removing \(who) from \(name)…",
                         failing: isMember ? "Couldn’t add \(who)." : "Couldn’t remove \(who).",
                         confirmation: isMember ? "\(who) is in \(name) and has the group’s grants."
                                                : "\(who) left \(name) and lost the group’s grants.", report: report) { client in
            let scoped = client.scoped(to: server)
            try await scoped.setGroupMember(handle, in: group.id, isMember: isMember)
            self.groups[server] = try await scoped.groups()
        }
    }

    @discardableResult
    func deleteGroup(_ group: MultiplayerGroup, on server: String) -> Task<Void, Never>? {
        confirming = nil
        return removeGroup(group, on: server, then: {
            if self.tray?.route == .share(server, .group(group.id)) { self.share?.back() }
        })
    }

    /// Deletes a group. The caller asks first. `then` runs once it is gone.
    @discardableResult
    func removeGroup(_ group: MultiplayerGroup, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                     then: (@MainActor () -> Void)? = nil) -> Task<Void, Never>? {
        tray?.act("Deleting \(group.name.multiplayerDisplay)…", failing: "Couldn’t delete the group.", report: report) { client in
            let scoped = client.scoped(to: server)
            try await scoped.deleteGroup(group.id)
            self.groups[server]?.removeAll { $0.id == group.id }
            then?()
            self.tray?.post(notice: "Deleted \(group.name.multiplayerDisplay). Its members lost the group’s grants.")
        }
    }

    // MARK: - Workspaces

    func startWorkspace(on server: String) {
        var draft = MultiplayerWorkspaceDraft()
        let mine = groups[server] ?? []
        if mine.count == 1 { draft.group = mine[0].id }
        workspaceDraft = draft
        share?.open(.workspaceCreate, on: server)
    }

    var canCreateWorkspace: Bool { tray?.isBusy == false && workspaceDraft.canSend }

    @discardableResult
    func createWorkspace(on server: String) -> Task<Void, Never>? {
        guard canCreateWorkspace, tray?.route == .share(server, .workspaceCreate) else { return nil }
        return createWorkspace(workspaceDraft, on: server, then: { id in
            self.workspaceDraft = MultiplayerWorkspaceDraft()
            if !id.isEmpty { self.share?.replace(with: .workspace(id), on: server) } else { self.share?.back() }
        })
    }

    /// Creates a workspace from the caller's draft. `then` is given the new workspace's ID.
    @discardableResult
    func createWorkspace(_ draft: MultiplayerWorkspaceDraft, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                         then: (@MainActor (String) -> Void)? = nil) -> Task<Void, Never>? {
        guard draft.canSend else { return nil }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).multiplayerDisplay
        return tray?.act("Creating \(name)…", failing: "Couldn’t create the workspace.", report: report) { client in
            let scoped = client.scoped(to: server)
            let id = try await scoped.createWorkspace(draft.body)
            self.workspaces[server] = try await scoped.workspaces()
            then?(id)
            self.tray?.post(notice: "Created \(name). Its group can claim work and add cards now.")
        }
    }

    func startClaim(in workspace: String, on server: String) {
        claimDraft = MultiplayerClaimDraft(agent: defaultAgent(on: server))
        share?.open(.claim(workspace: workspace), on: server)
    }

    var canClaim: Bool { tray?.isBusy == false && claimDraft.canSend }

    @discardableResult
    func sendClaim(in workspace: String, on server: String) -> Task<Void, Never>? {
        guard canClaim, tray?.route == .share(server, .claim(workspace: workspace)) else { return nil }
        return sendClaim(claimDraft, in: workspace, on: server, then: { _ in self.share?.back() })
    }

    /// Claims part of a workspace from the caller's draft, in the person's own name. `then` is
    /// given the new claim's ID, which is empty when the relay doesn't name it.
    @discardableResult
    func sendClaim(_ draft: MultiplayerClaimDraft, in workspace: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                   then: (@MainActor (String) -> Void)? = nil) -> Task<Void, Never>? {
        let me = handle(on: server)
        guard draft.canSend, !me.isEmpty else { return nil }
        return tray?.act("Claiming \(draft.trimmedKey.multiplayerDisplay)…", failing: "Couldn’t claim it.", report: report) { client in
            let scoped = client.scoped(to: server)
            let id = try await scoped.claim(draft.body(handle: me), in: workspace)
            self.workspaces[server] = try await scoped.workspaces()
            then?(id)
            self.tray?.post(notice: "Claimed \(draft.trimmedKey.multiplayerDisplay) for \(draft.trimmedAgent.multiplayerDisplay). The claim lasts while this Mac stays connected.")
        }
    }

    /// Sent only from the claim's confirmation.
    @discardableResult
    func release(_ claim: MultiplayerClaim, in workspace: String, on server: String) -> Task<Void, Never>? {
        guard confirming == .releaseClaim(claim.id) else { return nil }
        confirming = nil
        return releaseClaim(claim, in: workspace, on: server, then: { scoped in
            if let next = try? await scoped.cards(in: workspace) { self.cards = .loaded(next) }
        })
    }

    /// Releases a claim. The caller asks first. `then` runs once it is released, with that
    /// server's client.
    @discardableResult
    func releaseClaim(_ claim: MultiplayerClaim, in workspace: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                      then: (@MainActor (MultiplayerClient) async throws -> Void)? = nil) -> Task<Void, Never>? {
        tray?.act("Releasing \(claim.key.multiplayerDisplay)…", failing: "Couldn’t release the claim.",
                  confirmation: "Released \(claim.key.multiplayerDisplay).", report: report) { client in
            let scoped = client.scoped(to: server)
            try await scoped.release(claim: claim.id, in: workspace)
            self.workspaces[server] = try await scoped.workspaces()
            try await then?(scoped)
        }
    }

    // MARK: - Board

    private func loadCards(_ workspace: String, on server: String) {
        refresh()
        read(\.cards, keeping: true) { try await $0.scoped(to: server).cards(in: workspace) }
    }

    /// Reads a pull-request workspace's open pull requests. Runs beside the board's read, only as the
    /// workspace page opens or is refreshed; a merge-queue workspace asks for nothing.
    private func loadPullRequests(_ workspace: String, on server: String) {
        pullRequestTask?.cancel()
        pullRequestTask = nil
        pullRequestToken &+= 1
        if self.workspace(workspace, on: server)?.usesQueue == true { return }
        guard let client else { return }
        let token = pullRequestToken
        if pullRequests.value?.workspace != workspace { pullRequests = .loading }
        pullRequestTask = Task {
            let result: Result<MultiplayerPullRequestList, MultiplayerFailure>
            do { result = .success(try await client.scoped(to: server).pullRequests(in: workspace)) }
            catch { result = .failure(.from(error)) }
            guard token == self.pullRequestToken else { return }
            self.pullRequestTask = nil
            switch result {
            case .success(let list): self.pullRequests = .loaded(list)
            case .failure(let failure):
                self.pullRequests = .failed(failure == .cancelled
                    ? "The read was stopped. Try again."
                    : MultiplayerPullRequestList.problem(failure.message))
            }
        }
    }

    var canAddCard: Bool { tray?.isBusy == false && cardDraft.canSend }

    @discardableResult
    func addCard(to workspace: String, on server: String) -> Task<Void, Never>? {
        guard canAddCard else { return nil }
        return addCard(cardDraft, to: workspace, on: server, then: { _, scoped in
            self.cardDraft = MultiplayerCardDraft()
            self.cards = .loaded(try await scoped.cards(in: workspace))
        })
    }

    /// Adds a card from the caller's draft. `then` is given the new card's ID, which is empty when
    /// the relay doesn't name it, and that server's client.
    @discardableResult
    func addCard(_ draft: MultiplayerCardDraft, to workspace: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                 then: (@MainActor (String, MultiplayerClient) async throws -> Void)? = nil) -> Task<Void, Never>? {
        guard draft.canSend else { return nil }
        return tray?.act("Adding the card…", failing: "Couldn’t add the card.", report: report) { client in
            let scoped = client.scoped(to: server)
            let id = try await scoped.createCard(draft.json, in: workspace)
            try await then?(id, scoped)
        }
    }

    func openCard(_ card: MultiplayerCard, in workspace: String, on server: String) {
        resultDraft = card.result
        share?.open(.card(workspace: workspace, card: card.id), on: server)
    }

    /// Claims a card for one of the person's agents, completes it with a result, or reopens it.
    /// Giving up a card the person holds is sent only from its confirmation.
    @discardableResult
    func move(_ card: MultiplayerCard, in workspace: String, on server: String, to state: MultiplayerCard.State) -> Task<Void, Never>? {
        guard !handle(on: server).isEmpty else { return nil }
        if state == .open && card.known == .claimed { guard confirming == .releaseCard(card.id) else { return nil } }
        confirming = nil
        return updateCard(card, in: workspace, on: server, to: state, result: resultDraft, then: { scoped in
            self.cards = .loaded(try await scoped.cards(in: workspace))
        })
    }

    /// Claims a card, completes it with the caller's result, or reopens it. The caller asks before
    /// giving up a card the person holds. `then` runs once it is changed, with that server's client.
    @discardableResult
    func updateCard(_ card: MultiplayerCard, in workspace: String, on server: String, to state: MultiplayerCard.State,
                    result: String = "", report: (@MainActor (_ failure: String?) -> Void)? = nil,
                    then: (@MainActor (MultiplayerClient) async throws -> Void)? = nil) -> Task<Void, Never>? {
        let me = handle(on: server)
        guard !me.isEmpty else { return nil }
        let releasing = state == .open && card.known == .claimed
        var fields: [String: MultiplayerJSON] = ["state": .string(state.rawValue)]
        let title = card.title.multiplayerDisplay
        let progress: String, done: String
        switch state {
        case .claimed:
            fields["assignee"] = .string("\(me)/\(defaultAgent(on: server))")
            (progress, done) = ("Claiming \(title)…", "Claimed \(title). Nobody else can take it while you hold it.")
        case .done:
            fields["result"] = .string(result.trimmingCharacters(in: .whitespacesAndNewlines))
            (progress, done) = ("Completing \(title)…", "Completed \(title).")
        case .open:
            (progress, done) = releasing ? ("Releasing \(title)…", "Released \(title). Anyone in the group can claim it.")
                                         : ("Reopening \(title)…", "Reopened \(title).")
        }
        return tray?.act(progress, failing: "Couldn’t update the card.", confirmation: done, report: report) { client in
            let scoped = client.scoped(to: server)
            try await scoped.updateCard(card.id, in: workspace, fields: fields)
            try await then?(scoped)
            if let next = try? await scoped.workspaces() { self.workspaces[server] = next }
        }
    }

    // MARK: - Merge queue

    func startQueueAdd(for workspace: String, on server: String) {
        queueDraft = MultiplayerQueueDraft(checkout: queue(for: workspace).last?.checkout ?? "",
                                           testText: queue(for: workspace).last?.test.joined(separator: " ") ?? "")
        share?.open(.queueAdd(workspace: workspace), on: server)
    }

    var canQueue: Bool { tray?.isBusy == false && queueDraft.canSend }

    @discardableResult
    func addToQueue(_ workspace: String, on server: String) -> Task<Void, Never>? {
        guard canQueue, tray?.route == .share(server, .queueAdd(workspace: workspace)) else { return nil }
        return addToQueue(queueDraft, for: workspace, on: server, then: { _ in
            self.queueDraft = MultiplayerQueueDraft()
            self.share?.back()
        })
    }

    /// Queues a branch from the caller's draft. `then` is given the queued entry's ID.
    @discardableResult
    func addToQueue(_ draft: MultiplayerQueueDraft, for workspace: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                    then: (@MainActor (String) -> Void)? = nil) -> Task<Void, Never>? {
        guard draft.canSend else { return nil }
        return tray?.act("Queueing \(draft.trimmedBranch.multiplayerDisplay)…", failing: "Couldn’t queue the branch.", report: report) { client in
            self.queue = try await client.scoped(to: server).queueAdd(workspace: workspace, branch: draft.trimmedBranch,
                                                                      checkout: draft.checkout.trimmingCharacters(in: .whitespaces),
                                                                      testCommand: draft.testCommand)
            then?(self.queue(for: workspace).last { $0.branch == draft.trimmedBranch }?.id ?? "")
            self.tray?.post(notice: "Queued \(draft.trimmedBranch.multiplayerDisplay). Run the queue to test and merge it.")
        }
    }

    /// Tests and merges a workspace's queued branches. It names its workspace and needs no page.
    /// `then` is given the branches that ran, each in the state it ended in.
    @discardableResult
    func runQueue(_ workspace: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                  then: (@MainActor ([MultiplayerQueueEntry]) -> Void)? = nil) -> Task<Void, Never>? {
        let waiting = queue(for: workspace).filter(\.isQueued).count
        guard waiting > 0 else { return nil }
        return tray?.act(waiting == 1 ? "Testing and merging 1 branch…" : "Testing and merging \(waiting) branches…",
                         failing: "Couldn’t run the merge queue.", report: report) { client in
            let before = Set(self.queue(for: workspace).filter(\.isQueued).map(\.id))
            self.queue = try await client.scoped(to: server).queueMerge(workspace: workspace)
            let ran = self.queue(for: workspace).filter { before.contains($0.id) }
            then?(ran)
            let merged = ran.filter { $0.state == "merged" }.count
            if merged == ran.count {
                self.tray?.post(notice: merged == 1 ? "Merged 1 branch." : "Merged \(merged) branches.")
            } else {
                self.tray?.post(failure: "Merged \(merged) of \(ran.count). The others are marked with what stopped them.")
            }
        }
    }

    /// Takes a branch out of the queue: one that settled, or one still waiting. Sent only from its
    /// confirmation.
    @discardableResult
    func removeQueued(_ entry: MultiplayerQueueEntry, on server: String) -> Task<Void, Never>? {
        guard confirming == .removeQueued(entry.id) else { return nil }
        confirming = nil
        return removeFromQueue(entry, on: server)
    }

    /// Takes a branch out of the queue. The caller asks first.
    @discardableResult
    func removeFromQueue(_ entry: MultiplayerQueueEntry, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<Void, Never>? {
        let branch = entry.branch.multiplayerDisplay
        return tray?.act("Removing \(branch) from the queue…", failing: "Couldn’t remove \(branch) from the queue.",
                         confirmation: "Removed \(branch) from the queue. The branch itself is untouched.", report: report) { client in
            self.queue = try await client.scoped(to: server).queueRemove(workspace: entry.workspace, branch: entry.branch)
        }
    }

    // MARK: - Hosts

    /// Whether the chosen command takes extra arguments: nil when the host doesn't say.
    func hostAllowsArguments(_ resource: String, on server: String) -> Bool? {
        hostAllowsArguments(resource, on: server, for: hostDraft.command)
    }

    /// Whether a host's command takes extra arguments: nil when the host doesn't say.
    func hostAllowsArguments(_ resource: String, on server: String, for command: String) -> Bool? {
        share?.entry(resource, on: server)?.capabilities?.allowsArguments(command.trimmingCharacters(in: .whitespaces))
    }

    func startHostRun(_ resource: String, on server: String) {
        let commands = share?.entry(resource, on: server)?.capabilities?.commandNames ?? []
        hostDraft = MultiplayerHostRunDraft(command: commands.count == 1 ? commands[0] : "")
        hostReply = nil
        share?.open(.hostRun(resource: resource), on: server)
    }

    var canRunOnHost: Bool { tray?.isBusy == false && hostDraft.canSend }

    @discardableResult
    func runOnHost(_ resource: String, on server: String) -> Task<Void, Never>? {
        guard canRunOnHost, tray?.route == .share(server, .hostRun(resource: resource)) else { return nil }
        return runOnHost(hostDraft, resource: resource, on: server, then: { self.hostReply = $0 })
    }

    /// Runs one enrolled command on a friend's host, from the caller's draft. `then` is given
    /// what came back.
    @discardableResult
    func runOnHost(_ draft: MultiplayerHostRunDraft, resource: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                   then: @escaping @MainActor (MultiplayerSentRequest) -> Void) -> Task<Void, Never>? {
        guard draft.canSend else { return nil }
        // Arguments typed for another command are never sent to one that takes none.
        let payload = draft.payload(allowingArguments: hostAllowsArguments(resource, on: server, for: draft.command) != false)
        let name = share?.resourceName(resource, on: server).multiplayerDisplay ?? "the host"
        return tray?.act("Running \(draft.command.multiplayerDisplay) on \(name)…", failing: "Couldn’t run the command.", report: report) { client in
            then(try await client.scoped(to: server).send(resource: resource, action: MultiplayerSharePolicy.hostRun,
                                                         payload: payload, name: "Run \(draft.command)"))
        }
    }

    // MARK: - Knowledge

    func startKnowledge(on server: String, editing item: MultiplayerKnowledgeItem? = nil) {
        knowledgeDraft = MultiplayerKnowledgeDraft(editing: item)
        secretRefusal = nil
        share?.open(.knowledgeShare, on: server)
    }

    var canShareKnowledge: Bool { tray?.isBusy == false && knowledgeDraft.canSend }

    @discardableResult
    func shareKnowledge(on server: String) -> Task<Void, Never>? {
        guard canShareKnowledge, tray?.route == .share(server, .knowledgeShare) else { return nil }
        secretRefusal = nil
        return shareKnowledge(knowledgeDraft, on: server, report: { failure in
            if let failure, MultiplayerSecretCheck.isRefusal(failure) { self.secretRefusal = MultiplayerSecretCheck.refusal }
        }, then: { _ in
            self.knowledgeDraft = MultiplayerKnowledgeDraft()
            self.share?.back()
        })
    }

    /// Shares a knowledge item from the caller's draft, or saves a new version of the item the
    /// draft edits. `then` is given the item's ID, which is empty when a new item can't be found
    /// by its name. A refusal for a secret is in the reported sentence
    /// (`MultiplayerSecretCheck.isRefusal`).
    @discardableResult
    func shareKnowledge(_ draft: MultiplayerKnowledgeDraft, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                        then: (@MainActor (String) -> Void)? = nil) -> Task<Void, Never>? {
        guard draft.canSend else { return nil }
        let name = draft.trimmedName.multiplayerDisplay
        return tray?.act(draft.editing.isEmpty ? "Sharing \(name)…" : "Saving a new version of \(name)…",
                         failing: "Couldn’t share \(name).", report: report) { client in
            let scoped = client.scoped(to: server)
            if draft.editing.isEmpty { try await scoped.shareKnowledge(draft.body) } else { try await scoped.updateKnowledge(draft.editing, draft.body) }
            let before = Set((self.knowledge[server] ?? []).map(\.id))
            let next = try await scoped.knowledge()
            self.knowledge[server] = next
            let made = next.first { !before.contains($0.id) && $0.name == draft.trimmedName } ?? next.first { $0.name == draft.trimmedName }
            then?(draft.editing.isEmpty ? made?.id ?? "" : draft.editing)
            self.tray?.post(notice: draft.editing.isEmpty ? "Shared \(name)." : "Saved a new version of \(name).")
        }
    }

    private func loadVersions(_ id: String, on server: String) {
        read(\.versions) { try await $0.scoped(to: server).knowledgeVersions(id) }
    }

    /// Installs a skill, or saves an MCP item to the file the person chose. Other kinds are copied
    /// by the page itself. It names its item and needs no page. `then` is given where it was written.
    @discardableResult
    func install(_ item: MultiplayerKnowledgeItem, on server: String, destination: String = "",
                 report: (@MainActor (_ failure: String?) -> Void)? = nil,
                 then: (@MainActor (String) -> Void)? = nil) -> Task<Void, Never>? {
        let name = item.name.multiplayerDisplay
        return tray?.act("Installing \(name)…", failing: "Couldn’t install \(name).", report: report) { client in
            let path = try await client.scoped(to: server).installKnowledge(item.installItem, destination: destination)
            then?(path)
            self.tray?.post(notice: path.isEmpty ? "Installed \(name)." : "Installed \(name) at \(path.multiplayerDisplay).")
        }
    }

    // MARK: - Reputation and directory

    func startReputation(_ resource: String, on server: String) {
        endorseDraft = ""
        share?.open(.reputation(resource: resource), on: server)
    }

    private func loadReputation(_ resource: String, on server: String) {
        read(\.reputation) { try await $0.scoped(to: server).reputation(resource) }
    }

    @discardableResult
    func report(_ request: MultiplayerSentRequest, on server: String, accepted: Bool) -> Task<Void, Never>? {
        reportOutcome(request, on: server, accepted: accepted, then: { scoped in
            if let next = try? await scoped.reputation(request.resource) { self.reputation = .loaded(next) }
        })
    }

    /// Reports how a finished request turned out. `then` runs once it is reported, with that
    /// server's client.
    @discardableResult
    func reportOutcome(_ request: MultiplayerSentRequest, on server: String, accepted: Bool, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                       then: (@MainActor (MultiplayerClient) async -> Void)? = nil) -> Task<Void, Never>? {
        tray?.act("Reporting the result…", failing: "Couldn’t report the result.",
                  confirmation: accepted ? "Reported as accepted." : "Reported as rejected.", report: report) { client in
            let scoped = client.scoped(to: server)
            try await scoped.reportOutcome(resource: request.resource, request: request.request, accepted: accepted)
            self.outcomes[request.request] = accepted
            await then?(scoped)
        }
    }

    /// Why a skill can't be endorsed as typed, when it can't.
    nonisolated static func skillProblem(_ skill: String) -> String? {
        let skill = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        if skill.isEmpty { return "Name the skill first." }
        return skill.utf8.count <= 128 ? nil : "Keep the skill under 128 bytes."
    }

    var canEndorse: Bool { tray?.isBusy == false && Self.skillProblem(endorseDraft) == nil }

    @discardableResult
    func endorse(_ resource: String, on server: String) -> Task<Void, Never>? {
        guard canEndorse else { return nil }
        return endorse(resource, for: endorseDraft, on: server, then: { self.endorseDraft = "" })
    }

    /// Endorses a resource for the skill the caller names. `then` runs once it is endorsed.
    @discardableResult
    func endorse(_ resource: String, for skill: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                 then: (@MainActor () -> Void)? = nil) -> Task<Void, Never>? {
        guard Self.skillProblem(skill) == nil else { return nil }
        let skill = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        return tray?.act("Endorsing…", failing: "Couldn’t endorse it.",
                         confirmation: "Endorsed for \(skill.multiplayerDisplay).", report: report) { client in
            try await client.scoped(to: server).endorse(resource: resource, skill: skill)
            then?()
            self.tray?.session(server)?.refresh()
        }
    }

    func startSearch(on server: String) {
        searchDraft = ""
        search = .loaded(MultiplayerDirectorySearch())
        share?.open(.search, on: server)
    }

    func runSearch(on server: String) {
        let query = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        read(\.search) { try await $0.scoped(to: server).searchDirectory(query) }
    }

    // MARK: - Relay policy

    private func loadPolicy(on server: String) {
        guard let client else { return }
        pageTask?.cancel()
        pageToken &+= 1
        let token = pageToken
        policy = .loading
        pageTask = Task {
            let result: Result<MultiplayerRelayPolicy, MultiplayerFailure>
            do { result = .success(try await client.scoped(to: server).relayPolicy()) } catch { result = .failure(.from(error)) }
            guard token == self.pageToken else { return }
            self.pageTask = nil
            switch result {
            case .success(let policy):
                self.policy = .loaded(policy)
                self.policyDraft = MultiplayerPolicyDraft(policy)
            case .failure(let failure): self.policy = .failed(failure.message)
            }
        }
    }

    /// The edits not yet saved.
    var policyChanges: [String: MultiplayerJSON]? { policy.value.flatMap { policyDraft.changes(from: $0) } }
    var canSavePolicy: Bool { tray?.isBusy == false && policyChanges?.isEmpty == false }

    @discardableResult
    func savePolicy(on server: String) -> Task<Void, Never>? {
        guard canSavePolicy, let changes = policyChanges, tray?.route == .share(server, .policy) else { return nil }
        return savePolicy(changes, on: server, then: { saved in
            let member = self.policyDraft.member, device = self.policyDraft.device
            self.policy = .loaded(saved)
            self.policyDraft = MultiplayerPolicyDraft(saved)
            (self.policyDraft.member, self.policyDraft.device) = (member, device)
        })
    }

    /// Saves the caller's edits to a relay's policy. `then` is given what the relay now holds.
    @discardableResult
    func savePolicy(_ changes: [String: MultiplayerJSON], on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                    then: @escaping @MainActor (MultiplayerRelayPolicy) -> Void) -> Task<Void, Never>? {
        guard !changes.isEmpty else { return nil }
        return tray?.act("Saving the relay policy…", failing: "Couldn’t save the policy.",
                         confirmation: "Saved. The policy applies to everyone on this relay.", report: report) { client in
            then(try await client.scoped(to: server).setRelayPolicy(changes))
        }
    }

    @discardableResult
    func setSuspended(_ suspended: Bool, on server: String) -> Task<Void, Never>? {
        guard tray?.route == .share(server, .policy) else { return nil }
        confirming = nil
        return setSuspended(suspended, member: policyDraft.trimmedMember, on: server, then: { self.policyDraft.member = "" })
    }

    /// Suspends a member of a relay, or restores one. The caller asks before suspending. `then`
    /// runs once it is done.
    @discardableResult
    func setSuspended(_ suspended: Bool, member handle: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                      then: (@MainActor () -> Void)? = nil) -> Task<Void, Never>? {
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !handle.isEmpty else { return nil }
        let who = handle.multiplayerDisplay
        return tray?.act(suspended ? "Suspending \(who)…" : "Restoring \(who)…",
                         failing: suspended ? "Couldn’t suspend \(who)." : "Couldn’t restore \(who).",
                         confirmation: suspended ? "Suspended \(who). Their devices can’t use this relay until you restore them."
                                                 : "Restored \(who).", report: report) { client in
            try await client.scoped(to: server).setSuspended(handle, suspended)
            then?()
        }
    }

    @discardableResult
    func revokeDevice(on server: String) -> Task<Void, Never>? {
        guard tray?.route == .share(server, .policy) else { return nil }
        confirming = nil
        return revokeDevice(policyDraft.trimmedDevice, on: server, then: { self.policyDraft.device = "" })
    }

    /// Revokes one device on a relay. The caller asks first. `then` runs once it is revoked.
    @discardableResult
    func revokeDevice(_ device: String, on server: String, report: (@MainActor (_ failure: String?) -> Void)? = nil,
                      then: (@MainActor () -> Void)? = nil) -> Task<Void, Never>? {
        let device = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !device.isEmpty else { return nil }
        return tray?.act("Revoking the device…", failing: "Couldn’t revoke the device.",
                         confirmation: "Revoked. That device must sign in again to use this relay.", report: report) { client in
            try await client.scoped(to: server).revokeDevice(device)
            then?()
        }
    }
}
