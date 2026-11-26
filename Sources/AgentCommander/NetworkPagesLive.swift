import SwiftUI

// ATOMIC LEVEL: Pages (main-window network pages, live).
// The one file that binds the network pages to the network model. It reads the model into
// `NetworkPagesContent` and sends every intent to an existing public method of the model. The
// pages themselves see only values.
//
// The pages are a second view of the model's route: opening a server, an approval, a hand-off, a
// thread, the audit log or the grant sheet here opens it in the model, exactly as the tray does,
// so the tray shows the same page when it is opened next.
//
//   NetworkPagesContent.init(model:)   the model's state, as values
//   NetworkPageActions.live(model)     THE ACTION BOUNDARY: each result-bearing action, backed by
//                                      today's model methods. When the network model's result
//                                      API arrives (MultiplayerActionResult, declineFriend,
//                                      prepareGrant, sendGrant), only this function changes.
//   NetworkPagesLiveState              the window's own selections and each row's result
//   LiveNetworkPage                    the page for a place, bound to the model

// MARK: - Reading the model

extension NetworkPagesContent {
    /// Reads the network model. Every property read here is observed by the view that calls it.
    @MainActor init(model: MultiplayerModel, results: NetworkRowResults, now: Date? = nil) {
        let share = model.share, live = model.share.live
        self.init(now: now ?? model.currentDate())
        route = model.route
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
        confirmingPost = live.confirmingPost
        if case .share(let server, .review(let request)) = model.route { postProblem = live.postProblem(request, on: server) }
        thread = share.thread
        audit = share.audit
        if case .server(let id) = model.route, let server = model.server(id) {
            probe = model.presentedProbe(for: server)
            canTrust = model.canTrust(server)
        }
        confirmingRemoval = model.confirmingRemoval
        confirmingTrust = model.confirmingTrust
        canRename = model.canRename
        people = model.friendGroups
        friendsAvailable = model.friendsAvailable
        activity = model.filteredActivity
        hasActivity = !model.activity.isEmpty
        unseen = model.unseen
        activityActors = model.activityActors
        avatars = model.avatars
        if case .profile(let id) = model.route { profileAvatar = model.profileAvatar(id) }
        canSaveProfile = model.canSaveProfile
        grantResource = share.grantResource
        grantCompanions = share.grantCompanions
        grantHint = share.grantHint
        canGrant = share.canGrant
        canComment = share.canComment
        canSendFanout = live.canSendFanout
        self.results = results.results
        running = results.running
        if case .share(let server, .grant) = model.route {
            grantRefusal = results.results[NetworkActionResult.key(.grant, "sheet", on: server)]?.reason
        }
        working = model.working
        failure = model.failure
        notice = model.notice
        isUnavailable = model.unavailable != nil
        hasLoaded = model.hasLoaded
    }
}

// MARK: - The action boundary, live

extension NetworkPageActions {
    /// Why an action wasn't started: the model takes one at a time.
    static let busy = "Commander is finishing another network action. Try again in a moment."

    /// Every result-bearing network action, backed by the model's existing methods.
    ///
    /// Today the model reports an action's end only through its shared `failure` and `notice`,
    /// so each closure starts the action, waits for it and reads those two. PENDING TRAY API:
    /// once `MultiplayerActionResult` is on this branch, each body becomes one call
    /// (`await model.decide(…)`, `model.remove(…)`, `model.acceptFriend(…)`, `model.declineFriend(…)`,
    /// `share.prepareGrant(…)`, `model.sendGrant()`) mapped case for case, and `declineFriend`
    /// stops being nil.
    @MainActor static func live(_ model: MultiplayerModel) -> NetworkPageActions {
        let share = model.share

        /// Waits for an action the model started and reads how it ended.
        func finish(_ task: Task<Void, Never>?, id: String, server: String) async -> NetworkActionResult {
            guard let task else { return .failed(id: id, server: server, reason: busy) }
            await task.value
            if let failure = model.failure { return .failed(id: id, server: server, reason: failure) }
            return .done(id: id, server: server, message: model.notice)
        }

        return NetworkPageActions(
            acceptFriend: { request, server in
                guard let session = model.session(server), !session.isBusy else {
                    return .failed(id: request.handle, server: server, reason: busy)
                }
                let task = session.perform(.accept(requestID: request.id, handle: request.handle))
                guard let task else { return .failed(id: request.handle, server: server, reason: busy) }
                await task.value
                if let failure = session.actionFailure { return .failed(id: request.handle, server: server, reason: failure.message) }
                return .done(id: request.handle, server: server, message: session.notice)
            },
            // PENDING TRAY API: the network model has no decline for a friend request yet.
            declineFriend: nil,
            decide: { approval, server, approve in
                await finish(share.decide(approval, on: server, approve: approve), id: approval.id, server: server)
            },
            removeAccess: { request, server, declining in
                await finish(share.remove(request, on: server, declining: declining), id: request.id, server: server)
            },
            prepareGrant: { server, handle, resource, actions in
                share.startGrant(on: server, handle: handle, resourceID: resource, actions: actions)
                return model.route == .share(server, .grant)
            },
            sendGrant: { server in
                let resource = share.grantDraft.resourceID
                guard share.canGrant, let task = share.confirmGrant() else {
                    return .failed(id: resource, server: server, reason: model.isBusy ? busy : share.grantHint)
                }
                return await finish(task, id: resource, server: server)
            })
    }
}

// MARK: - Live state and page

/// The window's own part of the network pages: the two selections the model has no route for, and
/// how each row's last action ended.
@Observable @MainActor
final class NetworkPagesLiveState {
    var selection = NetworkPagesSelection()
    let results = NetworkRowResults()
}

/// The page for a network place, bound to the network model.
struct LiveNetworkPage: View {
    let place: String
    @Bindable var model: MultiplayerModel
    let state: NetworkPagesLiveState
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
    }

    /// Opens what a place shows first, so its page never starts empty: the server that needs a
    /// look, or the audit log of the first server you're signed in to.
    private func enter() {
        switch place {
        case NetworkPlace.servers:
            if case .server = model.route { return }
            let first = model.servers.first { $0.state == .certChanged } ?? model.servers.first
            if let first { model.openServer(first.id) }
        case NetworkPlace.audit:
            if case .share(_, .audit) = model.route { return }
            if let first = model.friendServers.first { model.share.open(.audit(resource: ""), on: first.id) }
        default:
            break
        }
    }

    private func pages(now: Date?) -> NetworkPages {
        @Bindable var share = model.share
        @Bindable var live = model.share.live
        let drafts = NetworkPagesDrafts(nickname: $model.renameDraft, access: $share.accessDraft, grant: $share.grantDraft,
                                        comment: $share.commentDraft, fanout: $live.fanoutDraft, reviewLink: $live.postDraft,
                                        profile: $model.profileDraft, activityServer: $model.activityServer,
                                        activityFriend: $model.activityFriend)
        return NetworkPages(content: NetworkPagesContent(model: model, results: state.results, now: now),
                            selection: state.selection, drafts: drafts, actions: actions)
    }

    /// Every intent, sent to the model method the tray calls for the same thing.
    private var actions: NetworkPagesActions {
        let model = model, share = model.share, live = model.share.live, state = state
        /// Starts a flow whose page is still the tray's, then shows the panel on it.
        func inPanel(_ start: @escaping () -> Void) -> (() -> Void)? {
            openPanel.map { open in { start(); open() } }
        }

        var actions = NetworkPagesActions()
        actions.go = go
        actions.select = { state.selection = $0 }
        actions.openPanel = openPanel
        actions.dismissNotice = { model.dismissNotice() }
        actions.dismissFailure = { model.dismissFailure() }
        actions.refresh = { model.refreshAll() }
        actions.close = { model.go(.home) }
        actions.back = { share.back() }
        actions.bind(.live(model), results: state.results,
                     grantServer: { if case .share(let server, .grant) = model.route { return server } else { return nil } },
                     // The model closes the sheet itself when the grant goes through, and says so in its notice.
                     grantFinished: { _ in })
        actions.setGrantServer = { share.setGrantServer($0) }
        actions.reconcileGrant = { share.reconcileGrantActions() }
        actions.toggleGrantAction = { share.toggleGrantAction($0) }

        // Servers
        actions.openServer = { model.openServer($0) }
        actions.addServer = inPanel { model.startAddServer() }
        actions.signIn = { model.signIn($0) }
        actions.signOut = { model.signOut($0) }
        actions.rename = { model.rename() }
        actions.setAutoConnect = { model.setAutoConnect($0, $1) }
        actions.toggleFavorite = { model.toggleFavorite($0) }
        actions.askRemove = { model.askRemove($0) }
        actions.cancelRemove = { model.cancelRemove() }
        actions.confirmRemove = { model.confirmRemove() }
        actions.checkCertificate = { model.checkCertificate($0) }
        actions.askTrust = { model.askTrust($0) }
        actions.cancelTrust = { model.cancelTrust() }
        actions.confirmTrust = { model.confirmTrust() }

        // Directory. The Consult, Hand off and Watch pages stay the tray's.
        actions.requestAccess = { entry, server in share.startRequestAccess(entry, on: server) }
        actions.sendAccessRequest = { share.sendAccessRequest() }
        if let openPanel {
            actions.consult = { entry, server in share.startConsult(entry.id, on: server); openPanel() }
            actions.handOff = { entry, server in share.startHandoff(entry.id, on: server); openPanel() }
            actions.watch = { entry, server in live.startWatch(entry.id, on: server); openPanel() }
        }

        // Approvals
        actions.openApproval = { id, server in share.open(.approval(id), on: server) }

        // Hand-offs and reviews. Apply stays in the network panel: `apply` is left nil.
        actions.openHandoff = { request, server in share.open(.handoffDetail(request: request), on: server) }
        actions.check = { row, server, result in share.check(row, on: server, result: result) }
        actions.openReview = { request, server in live.openReview(request, on: server) }
        actions.askPost = { live.askPost() }
        actions.cancelPost = { live.cancelPost() }
        actions.confirmPost = { live.confirmPost() }

        // Threads and audit
        actions.openThread = { request, title, server in share.open(.thread(request: request, title: title), on: server) }
        actions.postComment = { share.postComment() }
        actions.openAudit = { resource, server in share.open(.audit(resource: resource), on: server) }
        actions.reload = { share.reloadPage() }

        // Fan-out
        actions.openFanout = { request, server in share.open(.compare(request: request), on: server) }
        actions.chooseWinner = { child, request, server in live.chooseWinner(child, of: request, on: server) }
        actions.startFanout = { live.startFanout(on: $0) }
        actions.toggleFanoutTarget = { live.toggleFanoutTarget($0) }
        actions.sendFanout = { live.sendFanout() }

        // Shared
        actions.takeBack = { handover, server in live.takeBack(handover, on: server) }

        // People. Adding a friend, inviting and membership stay the tray's pages.
        if let openPanel {
            actions.addFriend = { server in model.addFriend(on: server); openPanel() }
            actions.invite = { server in model.startInvite(server); openPanel() }
            actions.membership = { server in model.startMembership(server); openPanel() }
        }
        actions.editProfile = { model.startProfile($0) }
        actions.choosePicture = { if let picture = MultiplayerPictureFile.choose() { model.pickAvatar(picture) } }
        actions.dropPicture = { model.pickAvatar($0) }
        actions.removePicture = { model.removeAvatar() }
        actions.saveProfile = { model.saveProfile() }
        actions.markActivitySeen = { model.markActivitySeen() }
        actions.loadAvatar = { handle, server in model.loadAvatar(server: server, handle: handle) }
        return actions
    }
}
