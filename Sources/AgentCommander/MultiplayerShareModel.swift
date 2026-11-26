import Foundation
import Observation

// FEATURE MODEL: share and consult (design/COMMANDER-NETWORK-INCREMENT-3.md).
// The tray's MultiplayerModel owns one of these. It reads each server's approvals, access requests
// and hand-offs, and holds the grant sheet, the request-access form, the Consult and Hand off
// composers, a request's thread and the audit list. Rules it keeps:
// - Every mutation goes through the tray's one action at a time, so its progress, refusal and
//   confirmation show in the tray's banner.
// - Approvals, access requests and hand-offs are read quietly, and only while a panel is open.
// - A grant sends only actions the resource lists. A worker or repository shared from the cockpit is
//   added first, and the device agent's own action list for it then decides what is granted.
// - Granting Consult or Hand off also grants the thread actions, and Hand off the two tracking
//   actions, so the friend can follow what they sent.
// - Nothing a hand-off produced is applied until the person picks a checkout for it.
// - A read or an action that names its target never reads or moves the tray's route. The tray's own
//   pages call the same functions with the target their route names.

/// A page under one server in the tray.
enum MultiplayerSharePage: Equatable {
    case directory
    case requestAccess(resource: String)
    /// Access requests sent to you and by you.
    case requests
    case approval(String)
    case grant
    case consult(resource: String)
    case handoff(resource: String)
    case handoffs
    case handoffDetail(request: String)
    case thread(request: String, title: String)
    /// One resource's audit entries, or every resource's when empty.
    case audit(resource: String)
    /// Live work (increment 4): a friend's worker's output, as it runs.
    case watch(resource: String)
    /// Who holds control of one of your workers, and for how long.
    case control(resource: String)
    case reviewRequest(resource: String)
    case review(request: String)
    case fanout
    /// A fan-out's results, side by side.
    case compare(request: String)
    /// Teams (increment 5).
    case groups
    case group(String)
    case workspaces
    case workspaceCreate
    /// One workspace, combined: its goal, who has claimed what, the board and how work lands.
    case workspace(String)
    case claim(workspace: String)
    case card(workspace: String, card: String)
    case queueAdd(workspace: String)
    case hosts
    case hostRun(resource: String)
    case knowledge
    case knowledgeShare
    case knowledgeItem(String)
    case reputation(resource: String)
    case search
    case policy

    var title: String {
        switch self {
        case .directory: "Shared directory"
        case .requestAccess: "Request access"
        case .requests: "Access requests"
        case .approval: "Approve this action?"
        case .grant: "Share"
        case .consult: "Consult"
        case .handoff: "Hand off"
        case .handoffs: "Hand-offs"
        case .handoffDetail: "Hand-off"
        case .thread: "Thread"
        case .audit: "Audit"
        case .watch: "Watch"
        case .control: "Control"
        case .reviewRequest: "Request review"
        case .review: "Review"
        case .fanout: "Fan out"
        case .compare: "Compare"
        case .groups: "Groups"
        case .group: "Group"
        case .workspaces: "Workspaces"
        case .workspaceCreate: "New workspace"
        case .workspace: "Workspace"
        case .claim: "Claim work"
        case .card: "Card"
        case .queueAdd: "Queue a branch"
        case .hosts: "Hosts"
        case .hostRun: "Run on host"
        case .knowledgeShare: "Share knowledge"
        case .knowledge: "Knowledge library"
        case .knowledgeItem: "Knowledge item"
        case .reputation: "Reputation"
        case .search: "Directory search"
        case .policy: "Relay policy"
        }
    }
}

/// A read's answer. The tray keeps one per page it reads on opening. A read a caller owns
/// (`loadThread(_:on:)` and the like) returns `.loaded` or `.failed`, never `.loading`.
enum MultiplayerLoad<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// Why the read failed, when it did.
    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// An approval or an access request with the server it waits on.
struct MultiplayerPending<Item: Equatable & Identifiable>: Equatable, Identifiable where Item.ID == String {
    let server: String
    let item: Item

    var id: String { "\(server)/\(item.id)" }
}

/// What the grant sheet shows for the chosen resource.
struct MultiplayerShareResource: Equatable {
    let id: String
    let name: String
    let kind: String
    /// Every action it offers, or is expected to offer once added.
    let offered: [String]
    /// Not on this server yet: sharing adds it first.
    let isNew: Bool

    /// The actions the owner chooses between.
    var choices: [String] { offered.filter { !MultiplayerSharePolicy.isCompanion($0) } }
}

/// What an answered row's hold waits on. The live app waits on the clock; a test passes its own
/// and ends the hold by hand.
struct MultiplayerHoldTimer: Sendable {
    let wait: @Sendable (Duration) async -> Void

    static let clock = MultiplayerHoldTimer { try? await Task.sleep(for: $0) }
}

/// How a request the person answered came out. Its row stays in the model's lists for a moment
/// with this, so a live row can say so before it leaves. A row the relay still lists after that
/// moment keeps it until the relay stops listing the request.
enum MultiplayerAnswer: String, Equatable, Sendable {
    case approved, denied, declined, withdrawn

    var title: String {
        switch self {
        case .approved: "Approved"
        case .denied: "Denied"
        case .declined: "Declined"
        case .withdrawn: "Withdrawn"
        }
    }
}

@Observable @MainActor
final class MultiplayerShareModel {
    /// How long the live app keeps an answered row: long enough to read one word. The row's own
    /// arrival and exit still use the motion tokens.
    nonisolated static let answeredHold: Duration = .seconds(2)

    @ObservationIgnored weak var tray: MultiplayerModel?

    private(set) var approvals: [String: [MultiplayerApproval]] = [:]
    private(set) var accessRequests: [String: [MultiplayerAccessRequest]] = [:]
    /// The approvals and access requests answered and still in the lists above, by `answerKey`.
    /// Each leaves the lists, and this, once its hold has ended and the relay no longer lists it.
    private(set) var answered: [String: MultiplayerAnswer] = [:]
    /// Every answer given, until a read shows the relay has stopped listing its request. It
    /// outlasts the hold, so a request the relay keeps listing never reads as waiting again.
    @ObservationIgnored private var outcomes: [String: MultiplayerAnswer] = [:]
    /// Whether the latest read since the answer listed the request. No entry: no read since.
    @ObservationIgnored private var relayLists: [String: Bool] = [:]
    private(set) var handoffs: [String: [MultiplayerSentRequest]] = [:]
    /// The latest status or result of a hand-off, by the hand-off's request ID.
    private(set) var reports: [String: MultiplayerHandoffReport] = [:]
    /// What came back from the Consult just sent.
    private(set) var consultReply: MultiplayerSentRequest?
    private(set) var thread: MultiplayerLoad<MultiplayerThread> = .loading
    private(set) var audit: MultiplayerLoad<[MultiplayerAuditEntry]> = .loading

    var grantDraft = MultiplayerShareDraft()
    var accessDraft = MultiplayerAccessDraft()
    var consultDraft = MultiplayerConsultDraft()
    var handoffDraft = MultiplayerHandoffDraft()
    var commentDraft = ""
    /// Why the last file couldn't be attached.
    private(set) var attachProblem: String?

    /// Live work (increment 4): watch, control, reviews and fan-outs.
    let live: MultiplayerLiveModel
    /// Teams (increment 5): groups, workspaces, hosts, knowledge, reputation and relay policy.
    let teams: MultiplayerTeamsModel

    private let client: MultiplayerClient?
    private let clock: () -> Date
    /// How long an answered row stays. Zero removes it at once.
    private let hold: Duration
    private let holdTimer: MultiplayerHoldTimer
    @ObservationIgnored private var holdTasks: [String: Task<Void, Never>] = [:]
    /// The pages Back returns through.
    @ObservationIgnored private var trail: [MultiplayerTrayRoute] = []
    @ObservationIgnored private(set) var quietTask: Task<Void, Never>?
    /// Cockpit walls on screen.
    @ObservationIgnored private(set) var wallViewers = 0
    /// How often the wall reads while no panel is open. The tray's own poll does it otherwise.
    private let wallPoll: Duration
    @ObservationIgnored private var wallTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pageTask: Task<Void, Never>?
    @ObservationIgnored private var pageToken = 0

    init(client: MultiplayerClient?, now: @escaping () -> Date = { Date() }, winners: MultiplayerWinnerStore = .scratch(),
         watchInterval: Duration = .seconds(2), answeredHold: Duration = .zero, wallPoll: Duration = .seconds(15),
         holdTimer: MultiplayerHoldTimer = .clock) {
        self.wallPoll = wallPoll
        self.holdTimer = holdTimer
        self.client = client
        self.clock = now
        self.hold = answeredHold
        self.live = MultiplayerLiveModel(client: client, now: now, winners: winners,
                                         watchInterval: watchInterval)
        self.teams = MultiplayerTeamsModel(client: client, now: now)
        self.live.share = self
        self.teams.share = self
    }

    // MARK: - Navigation

    /// Opens a page under a server, remembering where Back goes.
    func open(_ page: MultiplayerSharePage, on server: String) {
        guard let tray, tray.server(server) != nil else { return }
        let current = tray.route
        if current != .share(server, page) { trail.append(current) }
        tray.go(.share(server, page), keepingShareTrail: true)
        load(page, on: server)
    }

    /// Returns to the page this one was opened from, or to the server's own page.
    func back() {
        guard let tray else { return }
        teams.cancelConfirmation()    // a second press belongs to the page it was asked on
        let fallback = tray.route.serverID.map(MultiplayerTrayRoute.server) ?? .home
        let previous = trail.popLast() ?? fallback
        tray.go(previous, keepingShareTrail: true)
        if case .share(let server, let page) = previous { load(page, on: server) } else { live.left() }
    }

    /// The name of the page Back returns to.
    var backTitle: String {
        guard let tray else { return "Back" }
        switch trail.last {
        case .home?: return tray.tab.title    // the tab it was opened from: Agents, Network or People
        case .share(_, let page)?: return page.title
        case .server(let id)?: return tray.server(id)?.displayName ?? "Back"
        default: return tray.route.serverID.flatMap { tray.server($0)?.displayName } ?? "Back"
        }
    }

    /// The tray left the share pages by another way.
    func leftSharePages() {
        trail = []
        pageTask?.cancel()
        pageTask = nil
        pageToken &+= 1
        attachProblem = nil
        live.left()
        teams.left()
    }

    private func load(_ page: MultiplayerSharePage, on server: String) {
        switch page {
        case .thread(let request, _): showThread(request, on: server)
        case .audit(let resource): showAudit(resource, on: server)
        case .handoffs, .handoffDetail: refresh()
        case .watch(let resource): live.beginWatch(resource, on: server)
        case .control, .review, .compare: live.refresh()
        default: teams.load(page, on: server)
        }
        if case .watch = page {} else { live.endWatch() }
    }

    /// Replaces the page now open with the one it produced; Back still returns to where it was opened.
    func replace(with page: MultiplayerSharePage, on server: String) {
        tray?.go(.share(server, page), keepingShareTrail: true)
        load(page, on: server)
    }

    // MARK: - Quiet reads

    /// Reads approvals, access requests and hand-offs for every server the person is signed in to.
    /// Called after each server list while a panel is open.
    func refresh() {
        guard let client, let tray, tray.viewers > 0 || wallViewers > 0, quietTask == nil else { return }
        let ids = tray.servers.filter { $0.state == .online && $0.signedIn }.map(\.id)
        let live = Set(ids)
        // With only the cockpit wall showing, the wall's own rows are read: hand-offs here, and who
        // holds control and the reviews and fan-outs sent in the live model.
        guard tray.viewers > 0 else {
            handoffs = handoffs.filter { live.contains($0.key) }
            self.live.refresh()
            guard !ids.isEmpty else { return }
            quietTask = Task {
                for id in ids where !Task.isCancelled {
                    if let next = try? await client.scoped(to: id).handoffs() { self.handoffs[id] = next }
                }
                self.quietTask = nil
            }
            return
        }
        approvals = approvals.filter { live.contains($0.key) }
        accessRequests = accessRequests.filter { live.contains($0.key) }
        handoffs = handoffs.filter { live.contains($0.key) }
        self.live.refresh()
        self.teams.refresh()
        guard !ids.isEmpty else { return }
        quietTask = Task {
            for id in ids where !Task.isCancelled {
                let scoped = client.scoped(to: id)
                if let next = try? await scoped.approvals() {
                    self.approvals[id] = self.keepingAnswered(next, from: self.approvals[id], kind: .approval, on: id)
                }
                if let next = try? await scoped.accessRequests() {
                    self.accessRequests[id] = self.keepingAnswered(next, from: self.accessRequests[id], kind: .access, on: id)
                }
                if let next = try? await scoped.handoffs() { self.handoffs[id] = next }
            }
            self.quietTask = nil
        }
    }

    /// The cockpit wall shows hand-offs as remote workers, hand-overs on its dock and sent reviews
    /// and fan-outs as work rows, so they are read while it is on screen even with every panel
    /// closed. A view that shows the wall calls this when it appears and `wallDisappeared()` when
    /// it leaves; the count is the one signal, and `watchesWall` reads it. The first wall reads the
    /// server list once if nothing has, then again at the wall's pace while no panel is open.
    func wallAppeared() {
        wallViewers += 1
        guard wallViewers == 1, let tray else { return }
        if tray.hasLoaded { refresh() } else { tray.refresh() }
        wallTask?.cancel()
        wallTask = Task { [weak self, wallPoll] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: wallPoll) } catch { return }
                guard let self, self.wallViewers > 0 else { return }
                // An open panel polls the list itself, and each list read ends in `refresh()`.
                if let tray = self.tray, tray.viewers == 0 { tray.refresh() }
            }
        }
    }

    func wallDisappeared() {
        wallViewers = max(0, wallViewers - 1)
        guard wallViewers == 0 else { return }
        wallTask?.cancel()
        wallTask = nil
    }

    /// True while a cockpit wall is on screen: the wall's rows are kept current with no panel open.
    var watchesWall: Bool { wallViewers > 0 }

    func cancel() {
        quietTask?.cancel()
        quietTask = nil
        pageTask?.cancel()
        pageTask = nil
        pageToken &+= 1
        live.cancel()
        teams.cancel()
    }

    // MARK: - Derived values

    private func status(_ server: String) -> MultiplayerStatus? {
        guard let session = tray?.session(server), session.isOnline else { return nil }
        return session.status
    }

    func directory(_ server: String) -> [MultiplayerDirectoryEntry] { status(server)?.directoryEntries ?? [] }

    func entry(_ resource: String, on server: String) -> MultiplayerDirectoryEntry? {
        directory(server).first { $0.id == resource }
    }

    /// A resource's name on a server, yours or a friend's; its ID when neither list names it.
    func resourceName(_ id: String, on server: String) -> String {
        guard let status = status(server) else { return id }
        return status.resources.first { $0.id == id }?.name ?? status.directoryEntries.first { $0.id == id }?.name ?? id
    }

    /// Agents you enrolled, on every server you're signed in to.
    var myAgents: [MultiplayerPending<MultiplayerResource>] {
        (tray?.servers ?? []).flatMap { server in
            (status(server.id)?.resources ?? []).filter { $0.kind == MultiplayerResourceKind.agent.rawValue }
                .map { MultiplayerPending(server: server.id, item: $0) }
        }
    }

    /// Friends' agents, on every server you're signed in to: the ones you can use first.
    var friendAgents: [MultiplayerPending<MultiplayerDirectoryEntry>] {
        (tray?.servers ?? []).flatMap { server in
            directory(server.id).filter { $0.kind == MultiplayerResourceKind.agent.rawValue }
                .map { MultiplayerPending(server: server.id, item: $0) }
        }
        .sorted { !$0.item.granted.isEmpty && $1.item.granted.isEmpty }
    }

    /// How many grants you have given on one of your resources.
    func grantCount(_ resource: String, on server: String) -> Int {
        Set((status(server)?.grants ?? []).filter { $0.resource == resource }.map(\.handle)).count
    }

    // MARK: - Answered rows

    enum AnswerKind: String { case approval, access }

    /// An approval and an access request can share an ID, and an ID is only unique on its server.
    nonisolated static func answerKey(_ kind: AnswerKind, _ id: String, on server: String) -> String {
        "\(kind.rawValue)/\(server)/\(id)"
    }

    /// How an approval came out, while its answered row is still listed: through the hold, and
    /// after it for as long as the relay keeps listing the request. Nil while it waits.
    func answer(for approval: MultiplayerApproval, on server: String) -> MultiplayerAnswer? {
        answered[Self.answerKey(.approval, approval.id, on: server)]
    }

    /// How an access request came out, while its answered row is still listed, as for an approval.
    /// Nil while it waits.
    func answer(for request: MultiplayerAccessRequest, on server: String) -> MultiplayerAnswer? {
        answered[Self.answerKey(.access, request.id, on: server)]
    }

    /// The approvals that still wait: `pendingApprovals` without the answered rows. Counts use this.
    var waitingApprovals: [MultiplayerPending<MultiplayerApproval>] {
        pendingApprovals.filter { answer(for: $0.item, on: $0.server) == nil }
    }

    func waitingApprovals(on server: String) -> [MultiplayerApproval] {
        (approvals[server] ?? []).filter { answer(for: $0, on: server) == nil }
    }

    /// The access requests that still wait on the person: `pendingAccess` without the answered rows.
    var waitingAccess: [MultiplayerPending<MultiplayerAccessRequest>] {
        pendingAccess.filter { answer(for: $0.item, on: $0.server) == nil }
    }

    /// The given access requests without the ones just answered.
    func unanswered(_ requests: [MultiplayerAccessRequest], on server: String) -> [MultiplayerAccessRequest] {
        requests.filter { answer(for: $0, on: server) == nil }
    }

    /// Marks a row answered. It stays through the hold, or not at all with no hold. When the hold
    /// ends the row leaves, unless the relay's latest read still lists it: then it stays answered
    /// until a read no longer does.
    private func leave(_ answer: MultiplayerAnswer, key: String, remove: @escaping @MainActor () -> Void) {
        outcomes[key] = answer
        relayLists[key] = nil
        holdTasks[key]?.cancel()
        holdTasks[key] = nil
        guard hold > .zero else { return remove() }
        answered[key] = answer
        holdTasks[key] = Task { [weak self, hold, holdTimer] in
            await holdTimer.wait(hold)
            guard let self, !Task.isCancelled else { return }
            self.holdTasks[key] = nil
            switch self.relayLists[key] {
            case true?: return                       // still listed: the answer stays with the row
            case false?: self.outcomes[key] = nil    // the relay let it go during the hold
            case nil: break                          // not read since: the next read decides
            }
            self.answered[key] = nil
            remove()
        }
    }

    /// Testing support: waits until every hold in progress is over.
    func settleHolds() async {
        while let task = holdTasks.values.first { await task.value }
    }

    /// Takes a fresh read. An answered row the read no longer lists stays, in its place, until its
    /// hold ends. One the read still lists keeps its answer, hold or no hold. An answer whose hold
    /// is over is dropped once the read stops listing its request.
    private func keepingAnswered<Item: Identifiable>(_ next: [Item], from old: [Item]?, kind: AnswerKind,
                                                     on server: String) -> [Item] where Item.ID == String {
        let listed = Set(next.map(\.id))
        let prefix = Self.answerKey(kind, "", on: server)
        for (key, outcome) in outcomes where key.hasPrefix(prefix) {
            if listed.contains(String(key.dropFirst(prefix.count))) {
                relayLists[key] = true
                answered[key] = outcome
            } else if holdTasks[key] == nil {
                outcomes[key] = nil
                relayLists[key] = nil
                answered[key] = nil
            } else {
                relayLists[key] = false
            }
        }
        var rows = next
        for (index, row) in (old ?? []).enumerated()
        where answered[Self.answerKey(kind, row.id, on: server)] != nil && !rows.contains(where: { $0.id == row.id }) {
            rows.insert(row, at: min(index, rows.count))
        }
        return rows
    }

    /// Every approval listed for the person, oldest first within each server. One just answered
    /// stays for a moment; `answer(for:on:)` says so.
    var pendingApprovals: [MultiplayerPending<MultiplayerApproval>] {
        (tray?.servers ?? []).flatMap { server in
            (approvals[server.id] ?? []).map { MultiplayerPending(server: server.id, item: $0) }
        }
    }

    func approval(_ id: String, on server: String) -> MultiplayerApproval? {
        approvals[server]?.first { $0.id == id }
    }

    /// Requests friends sent for your resources that still wait on you.
    func incomingAccess(_ server: String) -> [MultiplayerAccessRequest] {
        guard let handle = status(server)?.handle, !handle.isEmpty else { return [] }
        return (accessRequests[server] ?? []).filter { $0.isPending && $0.owner == handle }
    }

    /// Requests you sent, whatever became of them.
    func outgoingAccess(_ server: String) -> [MultiplayerAccessRequest] {
        guard let handle = status(server)?.handle, !handle.isEmpty else { return [] }
        return (accessRequests[server] ?? []).filter { $0.requester == handle }
    }

    var pendingAccess: [MultiplayerPending<MultiplayerAccessRequest>] {
        (tray?.servers ?? []).flatMap { server in
            incomingAccess(server.id).map { MultiplayerPending(server: server.id, item: $0) }
        }
    }

    /// The request you already sent for a resource and that still waits.
    func waitingRequest(for resource: String, on server: String) -> MultiplayerAccessRequest? {
        unanswered(outgoingAccess(server), on: server).first { $0.resource == resource && $0.isPending }
    }

    /// Every hand-off you sent, newest first, with its server.
    var allHandoffs: [MultiplayerPending<MultiplayerSentRequest>] {
        (tray?.servers ?? []).flatMap { server in
            (handoffs[server.id] ?? []).map { MultiplayerPending(server: server.id, item: $0) }
        }
    }

    func handoff(_ request: String, on server: String) -> MultiplayerSentRequest? {
        handoffs[server]?.first { $0.request == request }
    }

    /// A hand-off's state in words: the run's, once asked; otherwise the request's own.
    func handoffState(_ row: MultiplayerSentRequest) -> (title: String, tone: Tone) {
        if let state = reports[row.request]?.state, !state.isEmpty {
            return (MultiplayerRequestState.title(state), MultiplayerRequestState.tone(state))
        }
        if row.succeeded { return ("Started", .working) }
        return (MultiplayerRequestState.title(row.status), MultiplayerRequestState.tone(row.status))
    }

    /// Who a hand-off went to: "priya’s agent sam-agent".
    func handoffTarget(_ row: MultiplayerSentRequest, on server: String) -> String {
        guard let entry = entry(row.resource, on: server) else { return resourceName(row.resource, on: server).multiplayerDisplay }
        return "\(entry.owner.multiplayerDisplay)’s \(entry.name.multiplayerDisplay)"
    }

    // MARK: - Approvals

    @discardableResult
    func decide(_ approval: MultiplayerApproval, on server: String, approve: Bool,
                report: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<Void, Never>? {
        let who = approval.peer.multiplayerDisplay
        guard answer(for: approval, on: server) == nil else { return nil }
        return tray?.act(approve ? "Approving \(who)’s request…" : "Denying \(who)’s request…",
                         failing: approve ? "Couldn’t approve the request." : "Couldn’t deny the request.",
                         confirmation: approve ? "Approved. It runs on this Mac now." : "Denied. \(who) is told.",
                         report: report) { client in
            try await client.scoped(to: server).decide(approval: approval.id, approve: approve)
            self.leave(approve ? .approved : .denied, key: Self.answerKey(.approval, approval.id, on: server)) {
                self.approvals[server]?.removeAll { $0.id == approval.id }
            }
            if self.tray?.route == .share(server, .approval(approval.id)) { self.back() }
        }
    }

    // MARK: - Access requests

    func startRequestAccess(_ entry: MultiplayerDirectoryEntry, on server: String) {
        accessDraft = MultiplayerAccessDraft(actions: entry.requestable.count == 1 ? Set(entry.requestable) : [])
        open(.requestAccess(resource: entry.id), on: server)
    }

    /// Sends the request on the tray's own page.
    @discardableResult
    func sendAccessRequest() -> Task<Void, Never>? {
        guard let tray, case .share(let server, .requestAccess(let resource)) = tray.route else { return nil }
        return sendAccessRequest(accessDraft, for: resource, on: server, then: {
            self.accessDraft = MultiplayerAccessDraft()
            self.back()
        })
    }

    /// Asks a resource's owner for access, with the caller's own draft. `then` runs once it is sent.
    @discardableResult
    func sendAccessRequest(_ draft: MultiplayerAccessDraft, for resource: String, on server: String,
                           report: (@MainActor (_ failure: String?) -> Void)? = nil,
                           then: (@MainActor () -> Void)? = nil) -> Task<Void, Never>? {
        guard let tray, draft.canSend, let entry = entry(resource, on: server) else { return nil }
        let body = draft.body(resource: resource)
        return tray.act("Asking \(entry.owner.multiplayerDisplay) for access…", failing: "Couldn’t send the request.",
                        confirmation: "Request sent. \(entry.owner.multiplayerDisplay) decides whether to share \(entry.name.multiplayerDisplay).",
                        report: report) { client in
            try await client.scoped(to: server).requestAccess(body)
            if let next = try? await client.scoped(to: server).accessRequests() {
                self.accessRequests[server] = self.keepingAnswered(next, from: self.accessRequests[server], kind: .access, on: server)
            }
            then?()
        }
    }

    /// Withdraws a request you sent, or declines one sent to you.
    @discardableResult
    func remove(_ request: MultiplayerAccessRequest, on server: String, declining: Bool,
                report: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<Void, Never>? {
        guard answer(for: request, on: server) == nil else { return nil }
        return tray?.act(declining ? "Declining the request…" : "Withdrawing your request…",
                  failing: declining ? "Couldn’t decline the request." : "Couldn’t withdraw the request.",
                  confirmation: declining ? "Declined \(request.requester.multiplayerDisplay)’s request." : "Request withdrawn.",
                  report: report) { client in
            try await client.scoped(to: server).removeAccessRequest(id: request.id)
            self.leave(declining ? .declined : .withdrawn, key: Self.answerKey(.access, request.id, on: server)) {
                self.accessRequests[server]?.removeAll { $0.id == request.id }
            }
        }
    }

    /// Opens the grant sheet filled in from a friend's request. Granting is the approval.
    func review(_ request: MultiplayerAccessRequest, on server: String) {
        startGrant(on: server, handle: request.requester, resourceID: request.resource, actions: Set(request.actions))
    }

    // MARK: - Grant sheet

    /// Opens the sheet for a friend, a resource, or both, preselecting any single option.
    func startGrant(on server: String, handle: String? = nil, group: String? = nil, resourceID: String? = nil,
                    actions: Set<String> = []) {
        guard prepareGrant(on: server, handle: handle, group: group, resourceID: resourceID, actions: actions) else { return }
        open(.grant, on: server)
    }

    /// Fills the sheet's draft without opening a tray page, for a view that hosts the sheet itself
    /// (`MultiplayerGrantHost`). False when the server has no status to share from.
    @discardableResult
    func prepareGrant(on server: String, handle: String? = nil, group: String? = nil, resourceID: String? = nil,
                      actions: Set<String> = []) -> Bool {
        guard let status = status(server) else { return false }
        var draft = MultiplayerShareDraft(server: server)
        draft.handle = handle ?? (status.friends.count == 1 && group == nil ? status.friends[0].handle : "")
        draft.group = group ?? ""
        draft.resourceID = resourceID ?? (status.resources.count == 1 ? status.resources[0].id : "")
        draft.actions = actions
        grantDraft = draft
        reconcileGrantActions()
        return true
    }

    /// The tray is showing the sheet as its own page.
    private var grantIsTrayPage: Bool {
        if case .share(_, .grant)? = tray?.route { return true }
        return false
    }

    /// Servers a cockpit worker or repository can be shared on now.
    var shareServers: [MultiplayerServerSummary] { tray?.friendServers ?? [] }

    /// Opens the sheet for something chosen in the cockpit. False when no server can take it yet.
    @discardableResult
    func startShare(_ target: MultiplayerShareTarget) -> Bool {
        guard let tray else { return false }
        guard let server = shareServers.first(where: { $0.id == tray.route.serverID }) ?? shareServers.first else {
            tray.go(.home)
            tray.post(failure: "Sign in to a server before you share \(target.name.multiplayerDisplay).")
            return false
        }
        var draft = MultiplayerShareDraft(server: server.id, resourceID: target.resourceID, target: target)
        if let friends = status(server.id)?.friends, friends.count == 1 { draft.handle = friends[0].handle }
        grantDraft = draft
        reconcileGrantActions()
        open(.grant, on: server.id)
        return true
    }

    /// Moves the open sheet to another server, keeping the policy the owner chose.
    func setGrantServer(_ server: String) {
        guard let tray, grantDraft.server != server, status(server) != nil else { return }
        let onTrayPage = grantIsTrayPage
        grantDraft.server = server
        let friends = status(server)?.friends ?? []
        if !friends.contains(where: { $0.handle == grantDraft.handle }) {
            grantDraft.handle = friends.count == 1 ? friends[0].handle : ""
        }
        grantDraft.group = ""
        if grantDraft.target == nil { grantDraft.resourceID = "" }
        reconcileGrantActions()
        if onTrayPage { tray.go(.share(server, .grant), keepingShareTrail: true) }
    }

    /// The resource the sheet is about, with the actions it offers.
    var grantResource: MultiplayerShareResource? {
        let known = status(grantDraft.server)?.resources.first { $0.id == grantDraft.resourceID }
        if let known {
            return MultiplayerShareResource(id: known.id, name: known.name, kind: known.kind, offered: known.actions, isNew: false)
        }
        guard let target = grantDraft.target, target.resourceID == grantDraft.resourceID else { return nil }
        return MultiplayerShareResource(id: target.resourceID, name: target.name, kind: target.kind,
                                        offered: MultiplayerSharePolicy.expected(kind: target.kind), isNew: true)
    }

    /// Keeps the chosen actions within what the chosen resource offers.
    func reconcileGrantActions() {
        let choices = grantResource?.choices ?? []
        grantDraft.actions = grantDraft.actions.filter(choices.contains)
        if grantDraft.actions.isEmpty, choices.count == 1 { grantDraft.actions = [choices[0]] }
    }

    func toggleGrantAction(_ action: String) {
        if grantDraft.actions.contains(action) { grantDraft.actions.remove(action) } else { grantDraft.actions.insert(action) }
    }

    /// The actions granted alongside the chosen ones.
    var grantCompanions: [String] {
        guard let resource = grantResource else { return [] }
        let extra = MultiplayerSharePolicy.companions(for: grantDraft.actions)
        return resource.isNew ? extra : resource.offered.filter(extra.contains)
    }

    var canGrant: Bool {
        guard let tray, !tray.isBusy, let status = status(grantDraft.server), grantResource != nil else { return false }
        let hasAudience = grantDraft.group.isEmpty
            ? status.friends.contains { $0.handle == grantDraft.handle }
            : teams.ownedGroups(on: grantDraft.server).contains { $0.id == grantDraft.group }
        return hasAudience && !grantDraft.actions.isEmpty && grantDraft.budgetProblem == nil
    }

    /// What stands between the sheet and Share, in one line.
    var grantHint: String {
        guard let status = status(grantDraft.server) else { return "This server is offline." }
        if status.friends.isEmpty { return "Add a friend on this server first." }
        if grantDraft.handle.isEmpty, grantDraft.group.isEmpty { return "Choose a friend or a group." }
        guard let resource = grantResource else { return "Choose what to share." }
        if grantDraft.actions.isEmpty { return "Choose at least one action." }
        if grantDraft.budgetProblem != nil { return "Fix the token budget." }
        return resource.isNew ? "Adds \(resource.name.multiplayerDisplay) to this server, then shares it." : "You can revoke it at any time."
    }

    /// Adds the resource if it's new, then sends one grant per action with the owner's policy.
    @discardableResult
    func confirmGrant(report: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<Void, Never>? {
        guard canGrant, let tray, let resource = grantResource else { return nil }
        let draft = grantDraft
        let now = clock()
        let who = draft.group.isEmpty ? draft.handle.multiplayerDisplay
                                      : "everyone in \(teams.groupName(draft.group, on: draft.server).multiplayerDisplay)"
        let what = resource.name.multiplayerDisplay
        return tray.act("Sharing \(what) with \(who)…", failing: "Couldn’t share \(what).", report: report) { client in
            let scoped = client.scoped(to: draft.server)
            var offered = resource.offered
            if resource.isNew, let target = draft.target {
                try await scoped.perform(.addResource(id: resource.id, name: target.name, kind: target.kind, target: target.target))
                offered = try await scoped.status().resources.first { $0.id == resource.id }?.actions ?? []
            }
            let grants = draft.grants(kind: resource.kind, offered: offered, now: now)
            guard !grants.isEmpty else {
                throw MultiplayerFailure.rejected("\(what) was added, but it doesn’t offer the actions you chose. Open it on this server to see what it offers.")
            }
            for grant in grants { try await scoped.submit(.grant, grant) }
            let limits = draft.limits(now: now)
            self.grantDraft = MultiplayerShareDraft()
            self.tray?.session(draft.server)?.refresh()
            // A hosted sheet is closed by its host; only the tray's own page goes back.
            if self.grantIsTrayPage { self.back() }
            self.tray?.post(notice: "\(who) can use \(what) until \(MultiplayerTime.display(limits.expiresAt)). \(draft.approval == .ask ? "Each use waits for your approval." : "Uses run without asking.")")
        }
    }

    // MARK: - Consult and Hand off

    func startConsult(_ resource: String, on server: String) {
        consultDraft = MultiplayerConsultDraft()
        consultReply = nil
        attachProblem = nil
        open(.consult(resource: resource), on: server)
    }

    func startHandoff(_ resource: String, on server: String) {
        handoffDraft = MultiplayerHandoffDraft()
        attachProblem = nil
        open(.handoff(resource: resource), on: server)
    }

    /// Attaches text files to the composer now open.
    func attach(_ urls: [URL]) {
        guard let tray, case .share(_, let page) = tray.route else { return }
        switch page {
        case .consult: (consultDraft.context, attachProblem) = Self.attaching(urls, to: consultDraft.context)
        case .handoff: (handoffDraft.context, attachProblem) = Self.attaching(urls, to: handoffDraft.context)
        default: attachProblem = Self.attaching(urls, to: []).problem
        }
    }

    /// Text files added to a composer's context, and why the last unreadable one was left out.
    /// A composer outside the tray keeps both in its own state.
    nonisolated static func attaching(_ urls: [URL], to context: [MultiplayerContextItem])
        -> (context: [MultiplayerContextItem], problem: String?) {
        var items: [MultiplayerContextItem] = []
        var problem: String?
        for url in urls where url.isFileURL {
            switch MultiplayerContextBundle.read(url) {
            case .success(let item): items.append(item)
            case .failure(let failure): problem = failure.message
            }
        }
        return (MultiplayerContextBundle.adding(items, to: context), problem)
    }

    func detach(_ item: MultiplayerContextItem) {
        consultDraft.context.removeAll { $0.name == item.name }
        handoffDraft.context.removeAll { $0.name == item.name }
        attachProblem = nil
    }

    var canSendConsult: Bool { tray?.isBusy == false && consultDraft.canSend }
    var canSendHandoff: Bool { tray?.isBusy == false && handoffDraft.canSend }

    /// Sends the prompt on the tray's own Consult page.
    @discardableResult
    func sendConsult() -> Task<Void, Never>? {
        guard let tray, case .share(let server, .consult(let resource)) = tray.route else { return nil }
        return sendConsult(consultDraft, to: resource, on: server, then: { reply in
            self.consultReply = reply
            self.consultDraft.prompt = ""
        })
    }

    /// Sends one prompt to a friend's worker, with the caller's own draft. `then` is given the reply.
    @discardableResult
    func sendConsult(_ draft: MultiplayerConsultDraft, to resource: String, on server: String,
                     report: (@MainActor (_ failure: String?) -> Void)? = nil,
                     then: @escaping @MainActor (MultiplayerSentRequest) -> Void) -> Task<Void, Never>? {
        guard draft.canSend, let tray else { return nil }
        let name = resourceName(resource, on: server).multiplayerDisplay
        return tray.act("Asking \(name)…", failing: "Couldn’t send the prompt.", report: report) { client in
            then(try await client.scoped(to: server)
                .send(resource: resource, action: MultiplayerSharePolicy.ask, payload: draft.payload, name: draft.title))
        }
    }

    /// Hands off the task on the tray's own composer, then returns to where the composer was
    /// opened. The hand-off itself is a window page; Live remote work on the Agents tab opens it.
    @discardableResult
    func sendHandoff() -> Task<Void, Never>? {
        guard let tray, case .share(let server, .handoff(let resource)) = tray.route else { return nil }
        return sendHandoff(handoffDraft, to: resource, on: server, then: { row in
            self.handoffDraft = MultiplayerHandoffDraft()
            if self.tray?.route == .share(server, .handoff(resource: resource)) { self.back() }
        })
    }

    /// Hands a task to a friend's agent, with the caller's own draft. `then` is given the new
    /// hand-off's row, before the confirmation is posted.
    @discardableResult
    func sendHandoff(_ draft: MultiplayerHandoffDraft, to resource: String, on server: String,
                     report: (@MainActor (_ failure: String?) -> Void)? = nil,
                     then: (@MainActor (MultiplayerSentRequest) -> Void)? = nil) -> Task<Void, Never>? {
        guard draft.canSend, let tray else { return nil }
        let name = resourceName(resource, on: server).multiplayerDisplay
        return tray.act("Handing off to \(name)…", failing: "Couldn’t hand off the task.", report: report) { client in
            let scoped = client.scoped(to: server)
            let reply = try await scoped.send(resource: resource, action: MultiplayerSharePolicy.handoff,
                                              payload: draft.payload, name: draft.trimmedTitle)
            let row = MultiplayerSentRequest(request: reply.request, resource: resource, action: MultiplayerSharePolicy.handoff,
                                             title: draft.trimmedTitle, at: self.clock(), status: reply.status,
                                             value: reply.value, failure: reply.failure)
            self.handoffs[server] = [row] + (self.handoffs[server] ?? []).filter { $0.request != row.request }
            if let next = try? await scoped.handoffs(), next.contains(where: { $0.request == row.request }) {
                self.handoffs[server] = next
            }
            then?(row)
            self.tray?.post(notice: reply.succeeded ? "Handed off. \(name) started a run for it."
                                                    : (reply.refusal ?? "The hand-off is waiting for the owner."))
        }
    }

    /// Reads one hand-off you sent, for the caller. It reads the server's hand-offs again, so the
    /// row is the latest; the tray's route and pages are left alone.
    func loadHandoff(_ request: String, on server: String) async -> MultiplayerLoad<MultiplayerSentRequest> {
        guard let client else { return .failed(unavailableText) }
        do { handoffs[server] = try await client.scoped(to: server).handoffs() } catch { return .failed(Self.readFailure(error)) }
        guard let row = handoff(request, on: server) else { return .failed("Commander can’t find this hand-off any more.") }
        return .loaded(row)
    }

    /// Asks the owner's agent how a hand-off's run is going, or for its result and artifacts.
    @discardableResult
    func check(_ row: MultiplayerSentRequest, on server: String, result: Bool,
               report: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<Void, Never>? {
        guard let run = row.run else {
            tray?.post(failure: row.refusal ?? "This hand-off has no run yet.")
            return nil
        }
        let action = result ? MultiplayerSharePolicy.tracking[1] : MultiplayerSharePolicy.tracking[0]
        return tray?.act(result ? "Reading the result…" : "Checking the run…",
                         failing: result ? "Couldn’t read the result." : "Couldn’t check the run.", report: report) { client in
            let reply = try await client.scoped(to: server).send(resource: row.resource, action: action,
                                                                 payload: .object(["run": .string(run)]),
                                                                 name: "\(result ? "Result" : "Status"): \(row.title)")
            guard let report = MultiplayerHandoffReport(reply: reply, isResult: result) else {
                throw MultiplayerFailure.rejected(reply.refusal ?? "The owner’s agent didn’t answer.")
            }
            // A status check keeps the artifacts an earlier result brought.
            if !result, let earlier = self.reports[row.request], earlier.isResult, earlier.state == report.state { return }
            self.reports[row.request] = report
        }
    }

    /// Why an artifact can't be applied, or nil when it can be sent.
    func applyProblem(artifact index: Int, of row: MultiplayerSentRequest, checkout: String) -> String? {
        guard let report = reports[row.request], report.isResult else { return "Read the hand-off’s result first." }
        guard report.artifacts.indices.contains(index) else { return "That artifact is no longer in the result." }
        return checkout.hasPrefix("/") ? nil : "Choose a local checkout."
    }

    /// Applies or saves one artifact of a hand-off's result into the checkout the person picked.
    /// The confirmation names the saved file's final name when the device gave it another.
    @discardableResult
    func apply(artifact index: Int, of row: MultiplayerSentRequest, on server: String, checkout: String,
               report: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<Void, Never>? {
        guard applyProblem(artifact: index, of: row, checkout: checkout) == nil, let result = reports[row.request] else { return nil }
        let artifact = result.artifacts[index]
        let name = artifact.name.multiplayerDisplay
        let folder = URL(fileURLWithPath: checkout).lastPathComponent.multiplayerDisplay
        return tray?.act("Applying \(name) to \(folder)…", failing: "Couldn’t apply \(name).", report: report) { client in
            let done = try await client.scoped(to: server).appliedArtifact(request: result.request, artifact: index, checkout: checkout)
            self.tray?.post(notice: done.confirmation(artifact: name, patch: artifact.kind == "patch", folder: folder))
        }
    }

    /// The resource a local worker is shared as: the one a hand-over, a suggestion or a grant for
    /// that worker names. Nil when the worker isn't shared on any signed-in server, or on the
    /// server named.
    func resource(forWorker id: String, on server: String? = nil) -> MultiplayerResource? {
        let shared = MultiplayerShareTarget.agent(id: id, name: "").resourceID
        for saved in tray?.servers ?? [] where server == nil || saved.id == server {
            guard let session = tray?.session(saved.id), session.isOnline else { continue }
            if let found = session.status?.resources.first(where: { $0.id == shared }) { return found }
        }
        return nil
    }

    // MARK: - Threads

    /// Why a read can't start without the helper.
    private var unavailableText: String { tray?.unavailable?.message ?? "The network helper isn’t available." }

    /// A failed read, as the sentence its page shows.
    nonisolated static func readFailure(_ error: any Error) -> String {
        let failure = MultiplayerFailure.from(error)
        return failure == .cancelled ? "The read was stopped. Try again." : failure.message
    }

    /// Reads a request's thread for the caller, who keeps the result. It reads and changes nothing
    /// of the tray: not its route, and not the thread on its own page.
    func loadThread(_ request: String, on server: String) async -> MultiplayerLoad<MultiplayerThread> {
        guard let client else { return .failed(unavailableText) }
        do { return .loaded(try await client.scoped(to: server).thread(request: request)) } catch { return .failed(Self.readFailure(error)) }
    }

    /// Reads the threads the person takes part in on one server, sent and received, consults
    /// included, newest first, for the caller, who keeps the result. It reads and changes nothing
    /// of the tray: not its route, and no list on the model.
    func loadThreads(on server: String) async -> MultiplayerLoad<[MultiplayerThreadSummary]> {
        guard let client else { return .failed(unavailableText) }
        do { return .loaded(try await client.scoped(to: server).threads()) } catch { return .failed(Self.readFailure(error)) }
    }

    /// The tray's thread page: the same read, kept on the model for the page now open.
    private func showThread(_ request: String, on server: String) {
        guard client != nil else { return }
        pageTask?.cancel()
        pageToken &+= 1
        let token = pageToken
        thread = .loading
        commentDraft = ""
        pageTask = Task {
            let result = await self.loadThread(request, on: server)
            guard token == self.pageToken else { return }
            self.pageTask = nil
            self.thread = result
        }
    }

    func reloadPage() {
        guard let tray, case .share(let server, let page) = tray.route else { return }
        load(page, on: server)
    }

    var canComment: Bool {
        tray?.isBusy == false && Self.canPost(comment: commentDraft)
    }

    /// Posts the comment typed on the tray's own thread page, then reads that thread again.
    @discardableResult
    func postComment() -> Task<Void, Never>? {
        guard let tray, case .share(let server, .thread(let request, _)) = tray.route else { return nil }
        return postComment(commentDraft, to: request, on: server, then: { scoped in
            self.commentDraft = ""
            if let next = try? await scoped.thread(request: request) { self.thread = .loaded(next) }
        })
    }

    /// A comment that can be sent: not blank, and at most 4,000 characters.
    nonisolated static func canPost(comment text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 4000
    }

    /// Posts a comment to a request's thread. `then` runs once it is posted, with that server's client.
    @discardableResult
    func postComment(_ text: String, to request: String, on server: String,
                     report: (@MainActor (_ failure: String?) -> Void)? = nil,
                     then: (@MainActor (MultiplayerClient) async -> Void)? = nil) -> Task<Void, Never>? {
        guard Self.canPost(comment: text), let tray else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return tray.act("Posting your comment…", failing: "Couldn’t post the comment.", report: report) { client in
            let scoped = client.scoped(to: server)
            try await scoped.comment(request: request, text: text)
            await then?(scoped)
        }
    }

    // MARK: - Audit

    /// Reads one resource's audit entries, or every resource's when `resource` is empty, for the
    /// caller, who keeps the result. The tray's route and its own audit page are left alone.
    func loadAudit(_ resource: String = "", on server: String) async -> MultiplayerLoad<[MultiplayerAuditEntry]> {
        guard let client else { return .failed(unavailableText) }
        do { return .loaded(try await client.scoped(to: server).audit(resource: resource)) } catch { return .failed(Self.readFailure(error)) }
    }

    /// The tray's audit page: the same read, kept on the model for the page now open.
    private func showAudit(_ resource: String, on server: String) {
        guard client != nil else { return }
        pageTask?.cancel()
        pageToken &+= 1
        let token = pageToken
        audit = .loading
        pageTask = Task {
            let result = await self.loadAudit(resource, on: server)
            guard token == self.pageToken else { return }
            self.pageTask = nil
            self.audit = result
        }
    }
}
