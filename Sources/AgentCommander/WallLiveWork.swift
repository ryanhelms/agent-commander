import SwiftUI

// ATOMIC LEVEL: Values (coordinator wall, live work from the network).
// What the network adds to the wall, as plain values: the hand-offs running on friends' Macs,
// the reviews and fan-outs that still need a look, who holds control of one of your workers, and
// the Co-pilot suggestions waiting on you. The cockpit page receives this value and sends every
// action out; only `WallLiveWork.init(model:)` reads the network model, through its public state.
//
//   WallLiveWork               the value
//   WallLiveWork.Control       a friend holds one of your workers for a while
//   WallLiveWork.Suggestion    a friend's suggestion for one of your workers, waiting for you
//   WallLiveWork.init(model:)  the network model's state, as that value
//   WallLiveWorkActions        what the wall can ask the network for

struct WallLiveWork: Equatable {
    /// A friend holds control of one of your workers until a time.
    struct Control: Identifiable, Equatable {
        let server: String
        let serverName: String
        let handover: MultiplayerHandover
        let resourceName: String

        var id: String { "\(server)/\(handover.id)" }
    }

    /// A Co-pilot suggestion for one of your workers. It waits for you whatever the grant says.
    struct Suggestion: Identifiable, Equatable {
        let server: String
        let approval: String
        let resource: String
        /// The friend's handle, or "A friend".
        let who: String
        let text: String

        var id: String { "\(server)/\(approval)" }

        var sentence: String { text.isEmpty ? "\(who) sent a suggestion" : "\(who) suggests: \(text)" }
    }

    /// The most rows of reviews and fan-outs the band lists. The rest are on their pages.
    static let rowLimit = 2

    /// Hand-offs you sent, running first, as the wall's remote workers.
    var remoteWorkers: [MultiplayerRemoteWorker] = []
    /// Reviews and fan-outs you sent that still need a look, newest first.
    var work: [MultiplayerRemoteWork] = []
    var controls: [Control] = []
    var suggestions: [Suggestion] = []
    /// A network action is running, so another can't start.
    var isBusy = false
    var now = Date()

    var isEmpty: Bool { remoteWorkers.isEmpty && work.isEmpty && controls.isEmpty && suggestions.isEmpty }

    // MARK: Mapping a local worker to what the network says about it

    /// The network resource a local worker is shared as. Sharing a worker always names it this
    /// way (`MultiplayerShareTarget.resourceID`), so a hand-over or a suggestion for that
    /// resource belongs to this worker's tile.
    static func resourceID(forWorker id: String) -> String {
        MultiplayerShareTarget.agent(id: id, name: "").resourceID
    }

    /// Who holds this worker now, soonest to end first.
    func controls(forWorker id: String) -> [Control] {
        let resource = Self.resourceID(forWorker: id)
        return controls.filter { $0.handover.resource == resource && $0.handover.isLive(now: now) }
            .sorted { $0.handover.until < $1.handover.until }
    }

    func suggestions(forWorker id: String) -> [Suggestion] {
        let resource = Self.resourceID(forWorker: id)
        return suggestions.filter { $0.resource == resource }
    }

    /// The reviews and fan-outs worth a row on the wall: hand-offs are tiles already, and a review
    /// that was posted or a fan-out whose winner is chosen needs nothing more.
    static func rows(_ work: [MultiplayerRemoteWork], isSettled: (MultiplayerRemoteWork) -> Bool) -> [MultiplayerRemoteWork] {
        work.filter { $0.kind != .handoff && !isSettled($0) }
    }

    /// The page a kind of remote work opens on.
    static func place(for kind: MultiplayerRemoteWork.Kind) -> String {
        switch kind {
        case .handoff, .review: NetworkPlace.handoffs
        case .fanout: NetworkPlace.fanout
        }
    }

    /// "Review", "2 reviews": what the band's link to the rest names.
    static func more(_ count: Int) -> String { count == 1 ? "1 more" : "\(count) more" }
}

extension WallLiveWork {
    /// Reads the network model. Every property read here is observed by the view that calls it.
    @MainActor init(model: MultiplayerModel, now: Date? = nil) {
        let share = model.share, live = model.share.live
        self.now = now ?? model.currentDate()
        remoteWorkers = share.remoteWorkers
        work = Self.rows(live.remoteWork) { item in
            item.kind == .review ? live.posted[item.request] != nil : live.winner(of: item.request, on: item.server) != nil
        }
        controls = live.activeHandovers.map { pending in
            Control(server: pending.server, serverName: model.server(pending.server)?.displayName ?? pending.server,
                    handover: pending.item, resourceName: share.resourceName(pending.item.resource, on: pending.server))
        }
        suggestions = share.pendingApprovals.filter(\.item.isSuggestion).map { pending in
            Suggestion(server: pending.server, approval: pending.item.id, resource: pending.item.resource,
                       who: pending.item.peer.isEmpty ? "A friend" : pending.item.peer.multiplayerDisplay,
                       text: pending.item.request)
        }
        isBusy = model.isBusy
    }
}

/// What the wall can ask the network for. The live window backs each with the network model's
/// own public method; a preview or a render backs them with samples.
struct WallLiveWorkActions {
    /// Ends a friend's control of a worker now.
    var takeBack: @MainActor (WallLiveWork.Control) -> Void = { _ in }
    /// Opens a hand-off, a review or a fan-out in the network model, so its page shows it.
    var openWork: @MainActor (MultiplayerRemoteWork.Kind, _ request: String, _ server: String) -> Void = { _, _, _ in }
    /// The wall shows, or stops showing. The network reads hand-offs while it does.
    var appeared: @MainActor () -> Void = {}
    var disappeared: @MainActor () -> Void = {}
    /// The zoom view of one remote worker. `gone` is called when its hand-off is no longer listed.
    /// Nil where remote workers can't be zoomed.
    var zoom: (@MainActor (_ workerID: String, _ gone: @escaping () -> Void) -> AnyView)? = nil
}

extension WallLiveWorkActions {
    /// Every wall intent, sent to the network model's own public methods.
    @MainActor static func live(_ model: MultiplayerModel) -> WallLiveWorkActions {
        let share = model.share, live = model.share.live
        return WallLiveWorkActions(
            takeBack: { control in live.takeBack(control.handover, on: control.server) },
            openWork: { kind, request, server in
                switch kind {
                case .handoff: share.open(.handoffDetail(request: request), on: server)
                case .review: live.openReview(request, on: server)
                case .fanout: share.open(.compare(request: request), on: server)
                }
            },
            appeared: { share.wallAppeared() },
            disappeared: { share.wallDisappeared() },
            zoom: { id, gone in AnyView(MultiplayerRemoteWorkerZoomHost(model: model, workerID: id, onGone: gone)) })
    }
}
