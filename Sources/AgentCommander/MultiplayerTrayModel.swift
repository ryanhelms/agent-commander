import Foundation
import Observation

// FEATURE MODEL: the network tray.
// Owns the server list, the add-server health check, the per-server settings and one
// MultiplayerSessionModel per saved server. Components receive its values and call its intents.
// Rules it keeps:
// - The list is the device agent's. Every server action is followed by a fresh `servers` read.
// - One server action at a time. Starting one drops any list read in flight.
// - A server is saved only from a health check that passed for the address still in the field,
//   and, when the system doesn't trust the certificate, only after the person confirms the pin.
// - A changed certificate is trusted only from a fresh check of that server and a second confirmation.
// - Sessions poll only while a panel is open. With notifications available, the list and the feed
//   are also read every other poll interval while it is closed (MultiplayerSocialModel.swift).

enum MultiplayerTrayRoute: Equatable {
    case home
    case addServer
    /// One server: its settings and its session, or the certificate review while it is blocked.
    case server(String)
    case hosting
    /// One server's profile editor, invite link and admin membership settings (increment 2).
    case profile(String)
    case invite(String)
    case membership(String)

    /// The saved server this page belongs to.
    var serverID: String? {
        switch self {
        case .server(let id), .profile(let id), .invite(let id), .membership(let id): id
        case .home, .addServer, .hosting: nil
        }
    }
}

/// The admin membership page's read of the relay's settings.
enum MultiplayerMembershipState: Equatable {
    case loading
    case loaded(MultiplayerMembership)
    case failed(String)

    var membership: MultiplayerMembership? {
        if case .loaded(let membership) = self { return membership }
        return nil
    }
}

enum MultiplayerProbeState: Equatable {
    case idle
    case running(address: String)
    case finished(MultiplayerProbe, address: String)
    case failed(address: String, message: String)

    var address: String? {
        switch self {
        case .idle: nil
        case .running(let address), .finished(_, let address), .failed(let address, _): address
        }
    }

    var probe: MultiplayerProbe? {
        if case .finished(let probe, _) = self { return probe }
        return nil
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// The band of counts at the top of the tray.
struct MultiplayerTally: Equatable {
    let servers: Int
    let serversOnline: Int
    let friendsOnline: Int
    let needsYou: Int

    var summary: String {
        switch servers {
        case 0: "No servers yet"
        case 1: serversOnline == 1 ? "Your server is online" : "Your server is offline"
        default: "\(serversOnline) of \(servers) servers online"
        }
    }
}

/// The friends of one server, as the home list groups them.
struct MultiplayerFriendGroup: Equatable, Identifiable {
    let server: MultiplayerServerSummary
    /// Online first, then by handle. Empty unless this server's session is online.
    let friends: [MultiplayerFriend]
    let incoming: [MultiplayerIncoming]
    let isOnline: Bool
    /// This server has a resource of yours to share.
    var canShare = false
    /// The same friends as the tray draws them: presence, status and links to other servers.
    var people: [MultiplayerContactEntry] = []

    var id: String { server.id }
    var onlineCount: Int {
        people.isEmpty ? friends.filter { $0.online == true }.count : people.filter(\.presence.isConnected).count
    }

    var caption: String {
        if !isOnline {
            switch server.state {
            case .certChanged: return "blocked, friends hidden"
            case .signedOut: return "signed out"
            case .connecting: return "connecting"
            default: return "offline, friends not shown"
            }
        }
        return friends.isEmpty ? "no friends yet" : "\(onlineCount) of \(friends.count) online"
    }

    static func sorted(_ friends: [MultiplayerFriend]) -> [MultiplayerFriend] {
        friends.sorted { left, right in
            let leftOnline = left.online == true, rightOnline = right.online == true
            if leftOnline != rightOnline { return leftOnline }
            return left.handle.localizedStandardCompare(right.handle) == .orderedAscending
        }
    }
}

@Observable @MainActor
final class MultiplayerModel {
    /// Favorites first, then most recently used.
    private(set) var servers: [MultiplayerServerSummary] = []
    /// A `servers` reply has arrived at least once.
    private(set) var hasLoaded = false
    private(set) var listFailure: MultiplayerFailure?
    private(set) var isRefreshing = false
    private(set) var route: MultiplayerTrayRoute = .home
    /// Progress text of the server action in flight.
    private(set) var working: String?
    private(set) var failure: String?
    private(set) var notice: String?
    private(set) var probe: MultiplayerProbeState = .idle
    /// The server whose Remove is waiting for its confirmation.
    private(set) var confirmingRemoval: String?
    /// The server whose new certificate is waiting for its second confirmation.
    private(set) var confirmingTrust: String?

    var serverDraft = MultiplayerServerDraft()
    /// The nickname field on a server's page.
    var renameDraft = ""

    // Social (increment 2). The intents are in MultiplayerSocialModel.swift.
    /// Linked contacts, once a `contacts` reply has arrived.
    var contacts: [MultiplayerContact]?
    /// The feed across servers, newest first.
    var activity: [MultiplayerActivityEvent] = []
    var activityCursor = ""
    var unseen = 0
    /// The feed's filters: one server's ID and one friend's handle, or nil for all.
    var activityServer: String?
    var activityFriend: String?
    /// Whether this account administers each server, and how people join it.
    var me: [String: MultiplayerMe] = [:]
    /// The person's presence choice, once a `presence` reply has said it.
    var presenceChoice: MultiplayerPresenceChoice?
    /// Avatar image bytes by `server/handle`.
    var avatars: [String: Data] = [:]
    var profileDraft = MultiplayerProfileDraft()
    var inviteDraft = MultiplayerInviteDraft()
    /// The link made on the invite page now open.
    var invite: MultiplayerInvite?
    var membership: MultiplayerMembershipState = .loading
    var membershipDraft = MultiplayerMembershipDraft()
    @ObservationIgnored var socialTask: Task<Void, Never>?
    @ObservationIgnored var membershipTask: Task<Void, Never>?
    @ObservationIgnored var membershipToken = 0
    /// Avatar and `me` reads in flight, by what they read.
    @ObservationIgnored var sideTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var watchTask: Task<Void, Never>?
    /// A feed reply has arrived, so later events are new ones.
    @ObservationIgnored var activityLoaded = false
    @ObservationIgnored let notifier: (any MultiplayerNotifying)?

    let usesFixtureHelper: Bool
    let setupFailure: MultiplayerFailure?

    let client: MultiplayerClient?
    let steadyPoll: Duration
    private let fastPoll: Duration
    private let clock: () -> Date
    private var sessions: [String: MultiplayerSessionModel] = [:]
    @ObservationIgnored private(set) var viewers = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshToken = 0
    @ObservationIgnored private var probeToken = 0

    init(client: MultiplayerClient?,
         setupFailure: MultiplayerFailure? = nil,
         usesFixtureHelper: Bool = false,
         steadyPoll: Duration = .seconds(15),
         fastPoll: Duration = .seconds(3),
         notifier: (any MultiplayerNotifying)? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.notifier = notifier
        self.setupFailure = setupFailure
        self.usesFixtureHelper = usesFixtureHelper
        self.steadyPoll = steadyPoll
        self.fastPoll = fastPoll
        self.clock = now
    }

    /// The one live model: the menu bar panel, the review window and invite links all use it.
    static let shared = MultiplayerModel.live()

    /// The app's model: the bundled helper, or a COMMANDER_NETWORK_BIN fixture in debug review mode.
    static func live() -> MultiplayerModel {
        switch MultiplayerHelperLocator.resolve() {
        case .success(let location):
            MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: location.url)),
                             usesFixtureHelper: location.isFixture, notifier: MultiplayerUserNotifier.forThisProcess())
        case .failure(let failure):
            MultiplayerModel(client: nil, setupFailure: failure)
        }
    }

    // MARK: - Derived values

    func currentDate() -> Date { clock() }

    var isBusy: Bool { working != nil }
    var canRefresh: Bool { client != nil && !isBusy && !isRefreshing }

    /// Why the list can't be shown, when it can't.
    var unavailable: MultiplayerFailure? { setupFailure ?? listFailure }

    func server(_ id: String) -> MultiplayerServerSummary? { servers.first { $0.id == id } }
    func session(_ id: String) -> MultiplayerSessionModel? { sessions[id] }

    var tally: MultiplayerTally {
        MultiplayerTally(servers: servers.count,
                         serversOnline: servers.filter { $0.state == .online }.count,
                         friendsOnline: servers.reduce(0) { $0 + $1.friendsOnline },
                         needsYou: servers.reduce(0) { $0 + $1.incoming })
    }

    /// One group per server, in list order. A server's friends come from its own session, and
    /// only while that session is online.
    var friendGroups: [MultiplayerFriendGroup] {
        servers.map { server in
            let session = sessions[server.id]
            let status = server.state == .certChanged || session?.isOnline != true ? nil : session?.status
            return MultiplayerFriendGroup(server: server,
                                          friends: MultiplayerFriendGroup.sorted(status?.friends ?? []),
                                          incoming: status?.incoming ?? [],
                                          isOnline: status != nil,
                                          canShare: !(status?.resources.isEmpty ?? true),
                                          people: MultiplayerContactGrouping.entries(friends: status?.friends ?? [],
                                                                                     on: server.id,
                                                                                     contacts: contacts ?? [],
                                                                                     servers: servers))
        }
    }

    /// A server's own problem text, made safe to draw.
    nonisolated static func problemText(_ raw: String) -> String {
        MultiplayerSessionModel.serviceText(raw) ?? "This server reported a problem. Refresh to check again."
    }

    var menuSymbol: String {
        if unavailable != nil || servers.contains(where: { $0.state == .certChanged }) { return "person.2.slash" }
        return servers.contains { $0.state == .online } ? "person.2.fill" : "person.2"
    }

    var menuTitle: String {
        if unavailable != nil { return "Unavailable" }
        if servers.contains(where: { $0.state == .certChanged }) { return "A server’s certificate changed" }
        return tally.summary
    }

    // MARK: Add server

    var addressProblem: String? {
        serverDraft.trimmedAddress.isEmpty ? nil : MultiplayerServerAddress.problem(serverDraft.trimmedAddress)
    }

    /// The health check for the address now in the field. Editing the field retires an older one.
    var currentProbe: MultiplayerProbeState {
        guard route == .addServer else { return .idle }
        return probe.address == serverDraft.trimmedAddress ? probe : .idle
    }

    var canProbe: Bool {
        client != nil && !isBusy && !probe.isRunning
            && MultiplayerServerAddress.problem(serverDraft.trimmedAddress) == nil
    }

    var canSaveServer: Bool {
        guard !isBusy, let result = currentProbe.probe, result.passed, existingServer == nil else { return false }
        if activeInvite != nil { return invitePinProblem == nil }
        return !result.needsPinConfirmation || serverDraft.pinConfirmed
    }

    /// The saved server the checked address already belongs to, by the helper's word or by address.
    var existingServer: MultiplayerServerSummary? {
        guard route == .addServer else { return nil }
        if let id = currentProbe.probe?.existing, let saved = server(id) { return saved }
        guard let checked = currentProbe.probe?.url else { return nil }
        let host = MultiplayerServerAddress.host(checked).lowercased()
        return servers.first { MultiplayerServerAddress.host($0.url).lowercased() == host }
    }

    /// The invite the form was opened from, while the address is still its server.
    var activeInvite: MultiplayerInviteLink? {
        guard route == .addServer, let invite = serverDraft.invite,
              MultiplayerServerAddress.host(invite.server) == MultiplayerServerAddress.host(serverDraft.trimmedAddress)
        else { return nil }
        return invite
    }

    /// Why the invite's fingerprint can't stand in for the person's own check, when it can't.
    var invitePinProblem: String? {
        guard let invite = activeInvite, let result = currentProbe.probe, let tls = result.step(.tls), tls.ok else { return nil }
        let presented = tls.pin ?? ""
        if !invite.pin.isEmpty {
            return presented == invite.pin ? nil
                : "This server’s certificate doesn’t match the invite. Don’t join. Ask the person who invited you for a new link."
        }
        return result.needsPinConfirmation
            ? "The invite carries no fingerprint, and macOS doesn’t already trust this certificate. Ask for a new invite link."
            : nil
    }

    /// What stands between the form and Save, in one line.
    var addServerHint: String {
        switch currentProbe {
        case .idle: return activeInvite == nil ? "Check the server before you save it." : "Check the server before you join it."
        case .running: return "Checking…"
        case .failed: return "The check didn’t run. Try again."
        case .finished(let result, _):
            if let stage = result.stoppedAt, let index = MultiplayerProbeStage.allCases.firstIndex(of: stage) {
                return "Fix step \(index + 1) to finish."
            }
            if let saved = existingServer { return "\(saved.displayName) is already in your list." }
            if activeInvite != nil { return invitePinProblem == nil ? "Ready to join." : "This invite can’t be used." }
            if result.needsPinConfirmation, !serverDraft.pinConfirmed { return "Confirm the fingerprint to finish." }
            return "Ready to save."
        }
    }

    // MARK: Certificate review

    /// The fresh check of a blocked server, while its page is open.
    func presentedProbe(for server: MultiplayerServerSummary) -> MultiplayerProbeState {
        guard route == .server(server.id), probe.address == server.url else { return .idle }
        return probe
    }

    /// The new key can be trusted: the fresh check reached TLS and shows a key other than the pinned one.
    func canTrust(_ server: MultiplayerServerSummary) -> Bool {
        guard !isBusy, let pin = presentedProbe(for: server).probe?.step(.tls)?.pin else { return false }
        return !pin.isEmpty && pin != server.pin
    }

    // MARK: - Panel lifetime

    /// A panel became visible. The first viewer starts the poll, for the list and every session.
    func open() {
        viewers += 1
        guard viewers == 1, client != nil else { return }
        sessions.values.forEach { $0.open() }
        pollTask?.cancel()
        let first = tick()
        pollTask = Task { [weak self] in
            var interval = first
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let next = self?.tick() else { return }
                interval = next
            }
        }
    }

    /// A panel closed. The last viewer stops the poll and every helper call in flight.
    func close() {
        guard viewers > 0 else { return }
        viewers -= 1
        guard viewers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
        cancelRefresh()
        cancelProbe()
        actionTask?.cancel()
        cancelSocial()
        confirmingRemoval = nil
        confirmingTrust = nil
        sessions.values.forEach { $0.close() }
    }

    private func tick() -> Duration {
        if !isBusy { refresh() }
        let settling = servers.contains { $0.state == .connecting } || sessions.values.contains { $0.awaitingBrowser }
        return settling ? fastPoll : steadyPoll
    }

    // MARK: - Server list

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard let client, !isBusy, !isRefreshing else { return nil }
        refreshToken &+= 1
        let token = refreshToken
        isRefreshing = true
        let task = Task {
            let result: Result<[MultiplayerServerSummary], MultiplayerFailure>
            do { result = .success(try await client.servers()) } catch { result = .failure(.from(error)) }
            self.finishRefresh(result, token: token)
        }
        refreshTask = task
        return task
    }

    /// The header's refresh: the list, and every server's session.
    func refreshAll() {
        refresh()
        sessions.values.forEach { $0.refresh() }
    }

    private func finishRefresh(_ result: Result<[MultiplayerServerSummary], MultiplayerFailure>, token: Int) {
        guard token == refreshToken else { return }
        isRefreshing = false
        refreshTask = nil
        switch result {
        case .success(let next):
            hasLoaded = true
            listFailure = nil
            apply(next)
            refreshSocial()
        case .failure(.cancelled):
            break
        case .failure(let failure):
            listFailure = failure
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        if isRefreshing {
            refreshToken &+= 1
            isRefreshing = false
        }
    }

    /// Takes a new list: one session per server, and a route that still names a saved server.
    private func apply(_ next: [MultiplayerServerSummary]) {
        servers = MultiplayerServerSummary.ordered(next)
        let ids = Set(servers.map(\.id))
        for (id, session) in sessions where !ids.contains(id) {
            if viewers > 0 { session.close() }
            sessions[id] = nil
        }
        guard let client else { return }
        for id in ids where sessions[id] == nil {
            let session = MultiplayerSessionModel(client: client.scoped(to: id), usesFixtureHelper: usesFixtureHelper,
                                                  steadyPoll: steadyPoll, fastPoll: fastPoll, now: clock)
            sessions[id] = session
            if viewers > 0 { session.open() }
        }
        if let id = route.serverID, !ids.contains(id) { go(.home) }
        me = me.filter { ids.contains($0.key) }
        if let id = activityServer, !ids.contains(id) { activityServer = nil }
        if let id = confirmingRemoval, !ids.contains(id) { confirmingRemoval = nil }
        if let id = confirmingTrust, server(id)?.state != .certChanged { confirmingTrust = nil }
    }

    /// Replaces one row with the helper's reply, ahead of the list read that follows.
    func merge(_ summary: MultiplayerServerSummary) {
        apply(servers.filter { $0.id != summary.id } + [summary])
    }

    // MARK: - Server actions

    @discardableResult
    func act(_ progress: String, failing title: String, confirmation: String? = nil,
                     _ work: @escaping @MainActor (MultiplayerClient) async throws -> Void) -> Task<Void, Never>? {
        guard let client, !isBusy else { return nil }
        cancelRefresh()
        working = progress
        failure = nil
        notice = nil
        let task = Task {
            do {
                try await work(client)
                if let confirmation { self.notice = confirmation }
            } catch {
                let reason = MultiplayerFailure.from(error)
                self.failure = reason.outcomeUnknown
                    ? "\(reason.message) Check the server list before trying again."
                    : "\(title) \(reason.message)"
            }
            self.working = nil
            self.actionTask = nil
            self.refresh()
        }
        actionTask = task
        return task
    }

    /// A result or a refusal from an intent that didn't go through `act`.
    func post(notice text: String) { notice = text }
    func post(failure text: String?) { failure = text }

    func dismissNotice() { notice = nil }
    func dismissFailure() { failure = nil }

    @discardableResult
    func toggleFavorite(_ server: MultiplayerServerSummary) -> Task<Void, Never>? {
        let favorite = !server.favorite
        return act(favorite ? "Adding \(server.displayName) to favorites…" : "Removing \(server.displayName) from favorites…",
                   failing: "Couldn’t change the favorite.") { client in
            self.merge(try await client.updateServer(id: server.id, favorite: favorite))
        }
    }

    @discardableResult
    func setAutoConnect(_ server: MultiplayerServerSummary, _ autoConnect: Bool) -> Task<Void, Never>? {
        guard autoConnect != server.autoConnect else { return nil }
        return act("Updating \(server.displayName)…", failing: "Couldn’t change that setting.") { client in
            self.merge(try await client.updateServer(id: server.id, autoConnect: autoConnect))
        }
    }

    var canRename: Bool {
        guard case .server(let id) = route, let server = server(id), !isBusy else { return false }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 80 && name != server.name
    }

    @discardableResult
    func rename() -> Task<Void, Never>? {
        guard canRename, case .server(let id) = route else { return nil }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return act("Renaming to \(name.multiplayerDisplay)…", failing: "Couldn’t rename the server.") { client in
            self.merge(try await client.updateServer(id: id, name: name))
        }
    }

    func askRemove(_ server: MultiplayerServerSummary) {
        confirmingTrust = nil
        confirmingRemoval = server.id
    }

    func cancelRemove() { confirmingRemoval = nil }

    /// Removes the server. The helper also signs out and deletes that server's Keychain item and files.
    @discardableResult
    func confirmRemove() -> Task<Void, Never>? {
        guard let id = confirmingRemoval, let server = server(id) else { return nil }
        confirmingRemoval = nil
        return act("Removing \(server.displayName)…", failing: "Couldn’t remove the server.",
                   confirmation: "Removed \(server.displayName).") { client in
            try await client.removeServer(id: id)
            self.go(.home)
        }
    }

    func askTrust(_ server: MultiplayerServerSummary) {
        guard canTrust(server) else { return }
        confirmingRemoval = nil
        confirmingTrust = server.id
    }

    func cancelTrust() { confirmingTrust = nil }

    /// Pins the key the fresh check showed. Sent only from the second confirmation.
    @discardableResult
    func confirmTrust() -> Task<Void, Never>? {
        guard let id = confirmingTrust, let server = server(id), canTrust(server),
              let pin = presentedProbe(for: server).probe?.step(.tls)?.pin
        else { return nil }
        confirmingTrust = nil
        return act("Trusting the new certificate for \(server.displayName)…",
                   failing: "Couldn’t trust the new certificate.",
                   confirmation: "\(server.displayName) is pinned to its new certificate.") { client in
            self.merge(try await client.trustServer(id: id, pin: pin))
            self.probe = .idle
        }
    }

    // MARK: - Health check

    /// Checks the address in the add-server field.
    @discardableResult
    func runProbe() -> Task<Void, Never>? {
        guard canProbe else { return nil }
        serverDraft.pinConfirmed = false
        return startProbe(serverDraft.trimmedAddress)
    }

    /// Checks a blocked server again, to read the certificate it presents now.
    @discardableResult
    func checkCertificate(_ server: MultiplayerServerSummary) -> Task<Void, Never>? {
        guard !probe.isRunning else { return nil }
        confirmingTrust = nil
        return startProbe(server.url)
    }

    private func startProbe(_ address: String) -> Task<Void, Never>? {
        guard let client else { return nil }
        cancelProbe()
        let token = probeToken
        probe = .running(address: address)
        let task = Task {
            let result: Result<MultiplayerProbe, MultiplayerFailure>
            do { result = .success(try await client.probe(url: address)) } catch { result = .failure(.from(error)) }
            guard token == self.probeToken else { return }
            self.probeTask = nil
            switch result {
            case .success(let probe): self.probe = .finished(probe, address: address)
            case .failure(.cancelled): self.probe = .idle
            case .failure(let failure): self.probe = .failed(address: address, message: failure.message)
            }
        }
        probeTask = task
        return task
    }

    private func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
        probeToken &+= 1
        if probe.isRunning { probe = .idle }
    }

    /// Saves the checked server with the pin from its check. A server the person switched
    /// "Connect automatically" off for is saved, then told not to connect.
    @discardableResult
    func saveServer() -> Task<Void, Never>? {
        guard canSaveServer, let result = currentProbe.probe else { return nil }
        if let invite = activeInvite { return join(invite) }
        let draft = serverDraft
        let pin = result.pin
        return act("Saving the server…", failing: "Couldn’t save the server.") { client in
            var saved = try await client.addServer(url: draft.trimmedAddress, name: draft.trimmedName, pin: pin)
            if !draft.autoConnect, saved.autoConnect {
                saved = (try? await client.updateServer(id: saved.id, autoConnect: false)) ?? saved
            }
            self.merge(saved)
            self.notice = "Added \(saved.displayName)."
            self.serverDraft = MultiplayerServerDraft()
            self.probe = .idle
            self.go(.home)
        }
    }

    // MARK: - Navigation

    func go(_ next: MultiplayerTrayRoute) {
        guard route != next else { return }
        if case .server(let id) = route, next.serverID != id { sessions[id]?.go(.home) }
        cancelProbe()
        membershipTask?.cancel()
        membershipTask = nil
        membershipToken &+= 1
        invite = nil
        probe = .idle
        confirmingRemoval = nil
        confirmingTrust = nil
        failure = nil
        route = next
        if case .server(let id) = next, let server = server(id) {
            renameDraft = server.name
            if server.state == .certChanged { checkCertificate(server) }
            refreshMe(id)
        }
    }

    func startAddServer() {
        serverDraft = MultiplayerServerDraft()
        go(.addServer)
    }

    func openServer(_ id: String) {
        guard server(id) != nil else { return }
        go(.server(id))
    }

    // MARK: Per-server session intents, from the home list

    func signIn(_ id: String) { sessions[id]?.signIn() }
    func signOut(_ id: String) { sessions[id]?.signOut() }

    func accept(_ request: MultiplayerIncoming, on id: String) { sessions[id]?.accept(request) }

    /// Opens the server's page on its share form for one friend.
    func share(with handle: String, on id: String) {
        guard let session = sessions[id], session.isOnline else { return }
        openServer(id)
        session.startGrant(handle: handle)
    }

    /// Opens the server's page on its add-friend form.
    func addFriend(on id: String) {
        guard let session = sessions[id], session.isOnline else { return }
        openServer(id)
        session.startAddFriend()
    }

    /// Servers a friend can be added on now.
    var friendServers: [MultiplayerServerSummary] {
        servers.filter { $0.state != .certChanged && sessions[$0.id]?.isOnline == true }
    }

    // MARK: - Testing support

    /// Waits until no helper call started by this model or its sessions is in flight.
    func settle() async {
        while true {
            if let task = actionTask ?? refreshTask ?? probeTask ?? socialTask ?? membershipTask ?? sideTasks.values.first {
                await task.value
                continue
            }
            for session in sessions.values { await session.settle() }
            if actionTask == nil, refreshTask == nil, probeTask == nil, socialTask == nil, membershipTask == nil,
               sideTasks.isEmpty { return }
        }
    }
}
