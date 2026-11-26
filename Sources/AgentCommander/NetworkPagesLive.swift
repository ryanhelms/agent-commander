import SwiftUI

// ATOMIC LEVEL: Pages (main-window network pages, live).
// The one file that binds the network pages to the network model. It reads the model into
// `NetworkPagesContent` and sends every intent to a public method of the model that names its
// target. The pages themselves see only values.
//
// The window owns what it shows. Which server, approval, hand-off, thread, audit log or fan-out is
// open, the thread and the audit entries it read, a server's certificate check, and every draft
// are kept in `NetworkPagesLiveState`. Nothing here reads or moves the tray's route, so the tray
// stays where the person left it and a form open in the panel keeps what was typed. Composers
// (Consult, Hand off, Watch, Add friend, Invite, Membership, Add server and the grant sheet) are
// the network model's own hosts, shown on the page.
//
//   NetworkPagesContent.init(model:state:)   the model's state and the window's own, as values
//   NetworkPageActions.live(model)           THE ACTION BOUNDARY: each result-bearing action, sent
//                                            to the model's per-request calls (MultiplayerActionResult)
//   NetworkPagesLiveState                    the window's route, reads, drafts and each row's result
//   LiveNetworkPage                          the page for a place, bound to the model

// MARK: - Reading the model

extension NetworkPagesContent {
    /// Reads the network model and the window's own state. Every property read here is observed
    /// by the view that calls it.
    @MainActor init(model: MultiplayerModel, state: NetworkPagesLiveState, now: Date? = nil) {
        let share = model.share, live = model.share.live
        self.init(now: now ?? model.currentDate())
        route = state.route
        servers = model.servers.map { summary in
            var server = Server(summary: summary)
            let session = model.session(summary.id)
            // The same rule as the tray: a server's lists show only while its session is online
            // and its certificate is the pinned one.
            if summary.state != .certChanged, let session, session.isOnline, let status = session.status {
                server.isOnline = true
                server.handle = status.handle
                server.displayName = status.displayName
                server.statusMessage = status.statusMessage
                server.friends = status.friends
                server.friendRequests = status.incoming
                server.grants = status.grants
                server.resources = status.resources
                server.directory = status.directoryEntries
            }
            server.isAdmin = model.isAdmin(summary.id)
            server.membershipMode = model.me[summary.id]?.mode
            server.approvals = share.approvals[summary.id] ?? []
            server.incomingAccess = share.incomingAccess(summary.id)
            server.outgoingAccess = share.outgoingAccess(summary.id)
            server.handoffs = share.handoffs[summary.id] ?? []
            server.reviews = live.reviews[summary.id] ?? []
            server.fanouts = live.fanouts[summary.id] ?? []
            server.handovers = live.handovers[summary.id] ?? []
            return server
        }
        reports = share.reports
        winners = live.winners
        posted = live.posted
        confirmingPost = state.confirmingPost
        if case .share(let server, .review(let request)) = state.route {
            postProblem = live.postProblem(request, on: server, link: state.reviewLink)
        }
        thread = state.thread
        audit = state.audit
        if case .server(let id) = state.route, let server = model.server(id) {
            probe = state.probe.address == server.url ? state.probe : .idle
            canTrust = !model.isBusy && state.trustablePin(for: server) != nil
            canRename = model.renameProblem(id, to: state.nickname) == nil
        }
        confirmingRemoval = state.confirmingRemoval
        confirmingTrust = state.confirmingTrust
        people = model.friendGroups
        friendsAvailable = model.friendsAvailable
        activity = model.filteredActivity
        hasActivity = !model.activity.isEmpty
        unseen = model.unseen
        activityActors = model.activityActors
        avatars = model.avatars
        if case .profile(let id) = state.route {
            switch state.profile.avatar {
            case .replace(let encoded): profileAvatar = encoded.image
            case .remove: profileAvatar = nil
            case .keep: profileAvatar = model.avatar(server: id, handle: state.profile.savedHandle)
            }
            canSaveProfile = !model.isBusy && state.profile.problem == nil && state.profile.hasChanges
        }
        grantResource = share.grantResource
        grantCompanions = share.grantCompanions
        grantHint = share.grantHint
        canGrant = share.canGrant
        canComment = !model.isBusy && MultiplayerShareModel.canPost(comment: state.comment)
        canSendFanout = !model.isBusy && state.fanout.canSend
        for server in model.servers {
            for approval in share.approvals[server.id] ?? [] {
                if let answer = share.answer(for: approval, on: server.id) {
                    answered[NetworkActionResult.key(.approval, approval.id, on: server.id)] = answer
                }
            }
            for request in share.incomingAccess(server.id) + share.outgoingAccess(server.id) {
                if let answer = share.answer(for: request, on: server.id) {
                    answered[NetworkActionResult.key(.access, request.id, on: server.id)] = answer
                }
            }
        }
        threads = state.threads
        results = state.results.results
        running = state.results.running
        working = model.working
        failure = model.failure
        notice = model.notice
        isUnavailable = model.unavailable != nil
        hasLoaded = model.hasLoaded
    }
}

// MARK: - The action boundary, live

extension NetworkActionResult {
    /// The network model's result, case for case.
    init(_ result: MultiplayerActionResult) {
        switch result {
        case .done(let id, let server, let message): self = .done(id: id, server: server, message: message)
        case .failed(let id, let server, let reason): self = .failed(id: id, server: server, reason: reason)
        }
    }
}

/// Answers wait their turn. The network model runs one action at a time and refuses a second
/// while the first is in flight, so an answer pressed on another row was lost. Each answer sent
/// from the window joins this line instead: it goes when the answers before it have ended and the
/// model is free. One that waits longer than `patience` is sent anyway, and the model's own
/// sentence says why it wasn't taken.
@MainActor
final class NetworkAnswerQueue {
    static let shared = NetworkAnswerQueue()

    var patience: Duration = .seconds(20)
    private var last: Task<Void, Never>?

    func send(on model: MultiplayerModel, _ work: @escaping @MainActor () async -> NetworkActionResult) async -> NetworkActionResult {
        let previous = last, patience = patience
        let task = Task { @MainActor () -> NetworkActionResult in
            await previous?.value
            let clock = ContinuousClock(), deadline = clock.now + patience
            while model.isBusy, clock.now < deadline { try? await Task.sleep(for: .milliseconds(40)) }
            return await work()
        }
        last = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}

extension NetworkPageActions {
    /// Every result-bearing network action, sent to the network model's own per-request calls
    /// (MultiplayerActions.swift). Each comes back for that one request, so a row shows its own
    /// outcome; the model's banner text is unchanged. The answers (accept, decline, approve, deny,
    /// withdraw) go through `NetworkAnswerQueue`, so a second one pressed at once is not lost.
    @MainActor static func live(_ model: MultiplayerModel, queue: NetworkAnswerQueue = .shared) -> NetworkPageActions {
        NetworkPageActions(
            acceptFriend: { request, server in
                await queue.send(on: model) { NetworkActionResult(await model.acceptFriend(request, on: server)) }
            },
            // A declined request leaves its row at once, so the page's band says what happened.
            declineFriend: { request, server in
                await queue.send(on: model) {
                    let result = NetworkActionResult(await model.declineFriend(request, on: server))
                    if result.isDone, model.notice == nil {
                        let who = request.handle.isEmpty ? "They" : request.handle.multiplayerDisplay
                        model.post(notice: result.message ?? "Declined. \(who) can ask again.")
                    }
                    return result
                }
            },
            decide: { approval, server, approve in
                await queue.send(on: model) { NetworkActionResult(await model.decide(approval, on: server, approve: approve)) }
            },
            removeAccess: { request, server, declining in
                await queue.send(on: model) { NetworkActionResult(await model.remove(request, on: server, declining: declining)) }
            },
            // Fills the sheet's draft without moving the tray. The window then hosts the sheet.
            prepareGrant: { server, handle, resource, actions in
                model.share.prepareGrant(on: server, handle: handle, resourceID: resource, actions: actions)
            },
            // The hosted sheet sends its own grant. This is the same call, for a caller without it.
            sendGrant: { _ in NetworkActionResult(await model.sendGrant()) },
            chooseCheckout: { artifact in MultiplayerFilePanel.chooseCheckout(for: artifact) },
            // The model answers for this one artifact, and names a saved file's final name.
            applyArtifact: { draft, row in
                NetworkActionResult(await model.apply(artifact: draft.index, of: row, on: draft.server, checkout: draft.checkout))
            })
    }
}

// MARK: - Live state and page

/// The window's own part of the network pages: what is open, what it read, what is being typed,
/// and how each row's last action ended. It stands where the tray's route used to.
@Observable @MainActor
final class NetworkPagesLiveState {
    var selection = NetworkPagesSelection()
    let results = NetworkRowResults()
    /// What the window has open. The tray's own route is never read or moved.
    var route = MultiplayerTrayRoute.home
    var thread: MultiplayerLoad<MultiplayerThread> = .loading
    var audit: MultiplayerLoad<[MultiplayerAuditEntry]> = .loading
    /// The threads the person takes part in, by server. Nil until the Threads page first reads them.
    var threads: [String: [MultiplayerThreadSummary]]?
    /// The certificate check of the open server.
    var probe = MultiplayerProbeState.idle
    var confirmingTrust: String?
    /// The server whose Remove waits for its second press. The window's own, not the tray's.
    var confirmingRemoval: String?
    var confirmingPost = false
    var nickname = ""
    var access = MultiplayerAccessDraft()
    var comment = ""
    var fanout = MultiplayerFanoutDraft()
    var reviewLink = ""
    var profile = MultiplayerProfileDraft()
    /// Counts reads, so an answer that arrives after another was asked for is dropped.
    private var reads = 0

    /// The key the open server's fresh check shows, when it can be trusted: TLS was reached and
    /// the key is not the pinned one.
    func trustablePin(for server: MultiplayerServerSummary) -> String? {
        guard probe.address == server.url, let pin = probe.probe?.step(.tls)?.pin, !pin.isEmpty, pin != server.pin else { return nil }
        return pin
    }

    /// Shows a page of the window. Confirmations of the page left behind are put away.
    func open(_ next: MultiplayerTrayRoute) {
        route = next
        confirmingTrust = nil
        confirmingPost = false
        selection.apply = nil
    }

    /// Starts a read and says whether its answer is still the one wanted when it arrives.
    func beginRead() -> Int {
        reads += 1
        return reads
    }

    func isCurrent(_ read: Int) -> Bool { read == reads }
}

/// The page for a network place, bound to the network model.
struct LiveNetworkPage: View {
    let place: String
    var model: MultiplayerModel
    @Bindable var state: NetworkPagesLiveState
    /// Goes to another place of the window.
    let go: (String) -> Void
    /// Shows the network panel in its own window.
    let openPanel: (() -> Void)?

    var body: some View {
        Group {
            // A request that counts down is read again each second, so its time left stays true.
            if place == NetworkPlace.approvals, !model.share.pendingApprovals.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    NetworkPageView(place: place, pages: pages(now: context.date))
                }
            } else {
                NetworkPageView(place: place, pages: pages(now: nil))
            }
        }
        .task(id: place) { enter() }
        // The band says how the last action on this page ended. It does not follow to another page,
        // and what an action on a Teams page or in the tray said does not arrive with the window.
        .onAppear {
            model.dismissNotice()
            model.dismissFailure()
        }
        .onChange(of: place) { _, _ in
            model.dismissNotice()
            model.dismissFailure()
        }
        .onDisappear {
            model.dismissNotice()
            model.dismissFailure()
        }
    }

    /// Opens what a place shows first, so its page never starts empty: the server that needs a
    /// look, or the audit log of the first server you're signed in to.
    private func enter() {
        let live = LiveNetworkIntents(model: model, state: state, go: go)
        switch place {
        case NetworkPlace.servers:
            if case .server = state.route { return }
            let first = model.servers.first { $0.state == .certChanged } ?? model.servers.first
            if let first { live.openServer(first.id) }
        case NetworkPlace.audit:
            if case .share(_, .audit) = state.route { return }
            if let first = model.friendServers.first { live.openAudit("", on: first.id) }
        case NetworkPlace.threads:
            live.readThreads()
        default:
            break
        }
    }

    private func pages(now: Date?) -> NetworkPages {
        @Bindable var share = model.share
        @Bindable var model = model
        let drafts = NetworkPagesDrafts(nickname: $state.nickname, access: $state.access, grant: $share.grantDraft,
                                        comment: $state.comment, fanout: $state.fanout, reviewLink: $state.reviewLink,
                                        profile: $state.profile, activityServer: $model.activityServer,
                                        activityFriend: $model.activityFriend)
        let network = self.model, state = state
        let intents = LiveNetworkIntents(model: network, state: state, go: go)
        return NetworkPages(content: NetworkPagesContent(model: network, state: state, now: now),
                            selection: state.selection, drafts: drafts, actions: intents.actions(openPanel: openPanel),
                            grantHost: { _ in
                                // The page scrolls, so the sheet takes its full height.
                                AnyView(MultiplayerGrantHost(model: network, scrolls: false, onCancel: { state.selection.grant = nil },
                                                             // A refusal stays on the sheet; a grant that went through closes it.
                                                             onFinish: { result in if result.isDone { state.selection.grant = nil } }))
                            },
                            composerHost: { composer in intents.host(composer) })
    }
}

/// Every intent of the live pages. Each changes the window's own state or calls a model method
/// that names its target; none reads or moves the tray's route.
@MainActor
struct LiveNetworkIntents {
    let model: MultiplayerModel
    let state: NetworkPagesLiveState
    let go: (String) -> Void

    private var share: MultiplayerShareModel { model.share }
    private var live: MultiplayerLiveModel { model.share.live }

    // MARK: Opening and reading

    func openServer(_ id: String) {
        guard let server = model.server(id) else { return }
        state.open(.server(id))
        state.nickname = server.name
        state.probe = .idle
        // A blocked server's page is its certificate review, so the new key is read at once.
        if server.state == .certChanged { checkCertificate(server) }
    }

    func checkCertificate(_ server: MultiplayerServerSummary) {
        guard !state.probe.isRunning else { return }
        state.confirmingTrust = nil
        state.probe = .running(address: server.url)
        Task {
            switch await model.checkCertificate(of: server) {
            case .loaded(let probe): state.probe = .finished(probe, address: server.url)
            case .failed(let message): state.probe = .failed(address: server.url, message: message)
            case .loading: state.probe = .idle
            }
        }
    }

    func openThread(_ request: String, title: String, on server: String) {
        state.open(.share(server, .thread(request: request, title: title)))
        state.comment = ""
        readThread(request, on: server)
    }

    private func readThread(_ request: String, on server: String) {
        let read = state.beginRead()
        state.thread = .loading
        Task {
            let thread = await share.loadThread(request, on: server)
            if state.isCurrent(read) { state.thread = thread }
        }
    }

    /// Reads the threads the person takes part in on every signed-in server: sent and received,
    /// consults included. A server that can't be read keeps what it showed before.
    func readThreads() {
        let servers = model.friendServers.map(\.id)
        Task {
            var next = state.threads ?? [:]
            for server in servers {
                if case .loaded(let list) = await share.loadThreads(on: server) { next[server] = list }
            }
            state.threads = next.filter { servers.contains($0.key) }
        }
    }

    func openAudit(_ resource: String, on server: String) {
        state.open(.share(server, .audit(resource: resource)))
        let read = state.beginRead()
        state.audit = .loading
        Task {
            let audit = await share.loadAudit(resource, on: server)
            if state.isCurrent(read) { state.audit = audit }
        }
    }

    /// Reads the open thread or audit log again.
    func reload() {
        guard case .share(let server, let page) = state.route else { return }
        switch page {
        case .thread(let request, _):
            readThread(request, on: server)
            readThreads()
        case .audit(let resource): openAudit(resource, on: server)
        default: break
        }
    }

    /// Opens a hand-off, a review or a fan-out you sent. It is in the model's lists already.
    func openWork(_ kind: MultiplayerRemoteWork.Kind, request: String, on server: String) {
        switch kind {
        case .handoff:
            state.open(.share(server, .handoffDetail(request: request)))
        case .review:
            state.open(.share(server, .review(request: request)))
            state.reviewLink = live.reviewLink(request)
        case .fanout:
            state.open(.share(server, .compare(request: request)))
        }
    }

    // MARK: Hosted composers

    /// The network model's own host for a composer, at its full height because the page scrolls.
    func host(_ composer: NetworkComposer) -> AnyView {
        let model = model, state = state
        let close = { state.selection.composer = nil }
        /// A composer that sent what it was for closes; a refusal stays on it.
        let finish: (MultiplayerActionResult) -> Void = { result in if result.isDone { close() } }
        switch composer {
        case .consult(let server, let resource):
            // The reply shows on the composer, so it stays open after it is sent.
            return AnyView(MultiplayerConsultHost(model: model, server: server, resource: resource, scrolls: false,
                                                  onCancel: close, onFinish: { _ in },
                                                  onThread: { sent in
                                                      close()
                                                      go(NetworkPlace.threads)
                                                      openThread(sent.request, title: sent.title, on: server)
                                                  }))
        case .handoff(let server, let resource):
            return AnyView(MultiplayerHandoffHost(model: model, server: server, resource: resource, scrolls: false,
                                                  onCancel: close, onFinish: { result in
                                                      guard result.isDone else { return }
                                                      close()
                                                      go(NetworkPlace.handoffs)
                                                      openWork(.handoff, request: result.id, on: server)
                                                  }))
        case .reviewRequest(let server, let resource):
            return AnyView(MultiplayerReviewRequestHost(model: model, server: server, resource: resource, scrolls: false,
                                                        onCancel: close, onFinish: { result in
                                                            guard result.isDone else { return }
                                                            close()
                                                            go(NetworkPlace.handoffs)
                                                            openWork(.review, request: result.id, on: server)
                                                        }))
        case .watch(let server, let resource):
            // A watch stays open while it is read; a suggestion's reply shows on it.
            return AnyView(MultiplayerWatchHost(model: model, server: server, resource: resource, scrolls: false,
                                                onCancel: close, onFinish: { _ in }))
        case .addFriend(let server):
            return AnyView(MultiplayerAddFriendHost(model: model, server: server, scrolls: false, onCancel: close, onFinish: finish))
        case .invite(let server):
            // The link shows on the form to be copied, so it stays open.
            return AnyView(MultiplayerInviteHost(model: model, server: server, scrolls: false, onCancel: close, onFinish: { _ in }))
        case .membership(let server):
            return AnyView(MultiplayerMembershipHost(model: model, server: server, scrolls: false, onCancel: close, onFinish: finish))
        case .addServer:
            return AnyView(MultiplayerAddServerHost(model: model, scrolls: false, onCancel: close,
                                                    onFinish: { result in
                                                        guard result.isDone else { return }
                                                        close()
                                                        openServer(result.server)
                                                    },
                                                    onOpenExisting: { server in
                                                        close()
                                                        openServer(server.id)
                                                    }))
        }
    }

    // MARK: Actions

    func actions(openPanel: (() -> Void)?) -> NetworkPagesActions {
        let model = model, share = model.share, live = model.share.live, state = state
        func compose(_ composer: NetworkComposer) { state.selection.composer = composer }

        var actions = NetworkPagesActions()
        actions.go = go
        actions.select = { state.selection = $0 }
        actions.openPanel = openPanel
        actions.dismissNotice = { model.dismissNotice() }
        actions.dismissFailure = { model.dismissFailure() }
        actions.refresh = { model.refreshAll() }
        actions.close = { state.open(.home) }
        actions.back = { state.open(.home) }
        actions.closeGrant = { state.selection.grant = nil }
        actions.closeComposer = { state.selection.composer = nil }
        actions.bind(.live(model), results: state.results,
                     openGrant: { state.selection.grant = $0 },
                     grantServer: { state.selection.grant },
                     grantFinished: { result in if result.isDone { state.selection.grant = nil } })
        actions.bindApply(.live(model), results: state.results,
                          draft: { state.selection.apply },
                          setDraft: { state.selection.apply = $0 },
                          row: { share.handoff($0.request, on: $0.server) })
        actions.setGrantServer = { share.setGrantServer($0) }
        actions.reconcileGrant = { share.reconcileGrantActions() }
        actions.toggleGrantAction = { share.toggleGrantAction($0) }

        // Servers
        actions.openServer = { openServer($0) }
        actions.addServer = { compose(.addServer) }
        actions.signIn = { model.signIn($0) }
        actions.signOut = { model.signOut($0) }
        actions.rename = {
            guard case .server(let id) = state.route, let server = model.server(id) else { return }
            let name = state.nickname
            Task {
                let result = await model.rename(server, to: name)
                if result.isDone, let renamed = model.server(id) { state.nickname = renamed.name }
            }
        }
        actions.setAutoConnect = { model.setAutoConnect($0, $1) }
        actions.toggleFavorite = { model.toggleFavorite($0) }
        // The second press is the window's own, and the removal names its server: a tray on any
        // other page stays there.
        actions.askRemove = { server in
            state.confirmingTrust = nil
            state.confirmingRemoval = server.id
        }
        actions.cancelRemove = { state.confirmingRemoval = nil }
        actions.confirmRemove = {
            guard let id = state.confirmingRemoval, let server = model.server(id) else { return }
            state.confirmingRemoval = nil
            Task {
                if await model.remove(server).isDone, state.route == .server(id) { state.open(.home) }
            }
        }
        actions.checkCertificate = { checkCertificate($0) }
        actions.askTrust = { server in
            guard !model.isBusy, state.trustablePin(for: server) != nil else { return }
            state.confirmingRemoval = nil
            state.confirmingTrust = server.id
        }
        actions.cancelTrust = { state.confirmingTrust = nil }
        actions.confirmTrust = {
            guard let id = state.confirmingTrust, let server = model.server(id), let pin = state.trustablePin(for: server) else { return }
            state.confirmingTrust = nil
            Task {
                // The model checks the server once more itself and pins only the key confirmed here.
                if await model.trust(server, confirming: pin).isDone { state.probe = .idle }
            }
        }

        // Directory. Each composer is the network model's own host, shown on the page.
        actions.requestAccess = { entry, server in
            state.access = MultiplayerAccessDraft(actions: entry.requestable.count == 1 ? Set(entry.requestable) : [])
            state.open(.share(server, .requestAccess(resource: entry.id)))
        }
        actions.sendAccessRequest = {
            guard case .share(let server, .requestAccess(let resource)) = state.route else { return }
            let draft = state.access
            Task {
                if await model.sendAccessRequest(draft, for: resource, on: server).isDone,
                   state.route == .share(server, .requestAccess(resource: resource)) { state.open(.home) }
            }
        }
        actions.consult = { entry, server in compose(.consult(server: server, resource: entry.id)) }
        actions.handOff = { entry, server in compose(.handoff(server: server, resource: entry.id)) }
        actions.watch = { entry, server in compose(.watch(server: server, resource: entry.id)) }
        actions.requestReview = { entry, server in compose(.reviewRequest(server: server, resource: entry.id)) }

        // Approvals
        actions.openApproval = { id, server in state.open(.share(server, .approval(id))) }

        // Hand-offs and reviews. Apply is bound above: choose a checkout, confirm, then the result.
        actions.openHandoff = { request, server in openWork(.handoff, request: request, on: server) }
        actions.check = { row, server, result in Task { _ = await model.checkHandoff(row, on: server, result: result) } }
        actions.openReview = { request, server in openWork(.review, request: request, on: server) }
        actions.askPost = { state.confirmingPost = true }
        actions.cancelPost = { state.confirmingPost = false }
        actions.confirmPost = {
            guard case .share(let server, .review(let request)) = state.route else { return }
            let link = state.reviewLink
            state.confirmingPost = false
            Task { _ = await model.postReview(request, on: server, to: link) }
        }

        // Threads and audit
        actions.openThread = { request, title, server in openThread(request, title: title, on: server) }
        actions.postComment = {
            guard case .share(let server, .thread(let request, _)) = state.route else { return }
            let text = state.comment
            Task {
                guard await model.postComment(text, to: request, on: server).isDone else { return }
                // The typed text is cleared only if it is still what was sent.
                if state.comment == text { state.comment = "" }
                if case .share(server, .thread(request, _)) = state.route { reload() } else { readThreads() }
            }
        }
        actions.openAudit = { resource, server in openAudit(resource, on: server) }
        actions.reload = { reload() }

        // Fan-out
        actions.openFanout = { request, server in openWork(.fanout, request: request, on: server) }
        actions.chooseWinner = { child, request, server in live.chooseWinner(child, of: request, on: server) }
        actions.startFanout = { server in
            let targets = live.fanoutTargets(on: server)
            state.fanout = MultiplayerFanoutDraft(targets: targets.count == 2 ? Set(targets.map(\.id)) : [])
            state.open(.share(server, .fanout))
        }
        actions.toggleFanoutTarget = { resource in
            if state.fanout.targets.contains(resource) { state.fanout.targets.remove(resource) } else { state.fanout.targets.insert(resource) }
        }
        actions.sendFanout = {
            guard case .share(let server, .fanout) = state.route else { return }
            let draft = state.fanout
            Task {
                let result = await model.sendFanout(draft, on: server)
                guard result.isDone else { return }
                state.fanout = MultiplayerFanoutDraft()
                // The composer is replaced by the fan-out it made.
                if state.route == .share(server, .fanout) { openWork(.fanout, request: result.id, on: server) }
            }
        }

        // Shared
        actions.takeBack = { handover, server in live.takeBack(handover, on: server) }
        actions.revoke = { grant, server in
            state.results.run(NetworkActionResult.key(.grant, grant.id, on: server)) {
                NetworkActionResult(await model.revoke(grant, on: server))
            }
        }

        // People. Adding a friend, inviting and membership are hosted on the page.
        actions.addFriend = { server in compose(.addFriend(server: server)) }
        actions.invite = { server in compose(.invite(server: server)) }
        actions.membership = { server in compose(.membership(server: server)) }
        actions.editProfile = { server in
            guard let draft = model.profileDraft(on: server) else { return }
            state.profile = draft
            state.open(.profile(server))
            if let handle = model.session(server)?.status?.handle { model.loadAvatar(server: server, handle: handle) }
        }
        actions.choosePicture = { if let picture = MultiplayerPictureFile.choose() { pick(picture) } }
        actions.dropPicture = { pick($0) }
        actions.removePicture = {
            guard case .profile(let id) = state.route else { return }
            state.profile.avatar = model.avatar(server: id, handle: state.profile.savedHandle) == nil ? .keep : .remove
        }
        actions.saveProfile = {
            guard case .profile(let id) = state.route else { return }
            let draft = state.profile
            Task {
                if await model.saveProfile(draft, on: id).isDone, state.route == .profile(id) { state.open(.home) }
            }
        }
        actions.markActivitySeen = { model.markActivitySeen() }
        actions.loadAvatar = { handle, server in model.loadAvatar(server: server, handle: handle) }
        return actions
    }

    /// Readies a picked image as the new picture, in the window's own draft.
    private func pick(_ file: Data) {
        guard let encoded = MultiplayerAvatarEncoder.encode(file) else {
            model.post(failure: "Commander can’t use that file as a picture. Choose a PNG or JPEG image.")
            return
        }
        model.post(failure: nil)
        state.profile.avatar = .replace(encoded)
    }
}
