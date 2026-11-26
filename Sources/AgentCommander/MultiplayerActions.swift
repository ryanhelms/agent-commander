import Foundation

// FEATURE MODEL: answers a view outside the tray can await.
// The main window's Needs you inbox and network pages answer requests one row at a time, so each
// answer comes back for that request alone. The tray's own banner still shows the same text; these
// calls add the per-request outcome and never replace it.
// - Every call runs through the same one-at-a-time action the tray uses. A call that can't start
//   says why and sends nothing.
// - A failure's reason is a full sentence, built with `MultiplayerSentence.join`.

/// What one answer came to, for the request it was about.
enum MultiplayerActionResult: Equatable, Sendable {
    /// The helper confirmed it. `message` is the confirmation the tray shows, when there is one.
    case done(id: String, server: String, message: String?)
    /// Refused, or not sent. `reason` says what happened and is ready to draw.
    case failed(id: String, server: String, reason: String)

    /// The request, approval or resource the answer was about. A friend request's ID is its handle.
    var id: String {
        switch self {
        case .done(let id, _, _), .failed(let id, _, _): id
        }
    }

    var server: String {
        switch self {
        case .done(_, let server, _), .failed(_, let server, _): server
        }
    }

    var isDone: Bool {
        if case .done = self { return true }
        return false
    }

    /// The confirmation, when it went through and there is one.
    var message: String? {
        if case .done(_, _, let message) = self { return message }
        return nil
    }

    /// Why it didn't go through, when it didn't.
    var reason: String? {
        if case .failed(_, _, let reason) = self { return reason }
        return nil
    }
}

/// Carries a tray action's refusal back to the call that started it.
@MainActor
private final class MultiplayerActionReport {
    var failure: String?
}

extension MultiplayerModel {
    /// Why an answer can't be sent right now.
    private func notSent(_ lead: String) -> String {
        if client == nil {
            return MultiplayerSentence.join(lead, unavailable?.message ?? "The network helper isn’t available.")
        }
        return MultiplayerSentence.join(lead, "Another network action is still running. Try again when it finishes.")
    }

    /// Runs one tray action and waits for it. `start` is given the reporter to hand to `act`.
    func result(id: String, server: String, failing lead: String,
                _ start: (_ report: @escaping @MainActor (String?) -> Void) -> Task<Void, Never>?) async -> MultiplayerActionResult {
        let report = MultiplayerActionReport()
        guard let task = start({ report.failure = $0 }) else {
            return .failed(id: id, server: server, reason: notSent(lead))
        }
        await task.value
        if let failure = report.failure { return .failed(id: id, server: server, reason: failure) }
        return .done(id: id, server: server, message: notice)
    }

    // MARK: Friend requests

    /// Accepts a friend request on one server.
    func acceptFriend(_ request: MultiplayerIncoming, on server: String) async -> MultiplayerActionResult {
        await answerFriend(.accept(requestID: request.id, handle: request.handle), id: request.id, on: server)
    }

    /// Refuses a friend request on one server. The sender can ask again.
    func declineFriend(_ request: MultiplayerIncoming, on server: String) async -> MultiplayerActionResult {
        await answerFriend(.decline(handle: request.handle), id: request.id, on: server)
    }

    private func answerFriend(_ command: MultiplayerCommand, id: String, on server: String) async -> MultiplayerActionResult {
        guard let session = session(server), session.isOnline else {
            let name = self.server(server)?.displayName ?? "that server"
            return .failed(id: id, server: server,
                           reason: MultiplayerSentence.join(command.failureTitle, "Sign in to \(name) first."))
        }
        guard let task = session.perform(command) else {
            return .failed(id: id, server: server, reason: notSent(command.failureTitle))
        }
        await task.value
        if let failed = session.actionFailure, failed.command == command {
            return .failed(id: id, server: server, reason: failed.message)
        }
        return .done(id: id, server: server, message: command.confirmation)
    }

    // MARK: Approvals and access requests

    /// Approves or denies one use of a resource that waits under Ask each time.
    func decide(_ approval: MultiplayerApproval, on server: String, approve: Bool) async -> MultiplayerActionResult {
        await result(id: approval.id, server: server,
                     failing: approve ? "Couldn’t approve the request." : "Couldn’t deny the request.") {
            share.decide(approval, on: server, approve: approve, report: $0)
        }
    }

    /// Declines an access request sent to you, or withdraws one you sent.
    func remove(_ request: MultiplayerAccessRequest, on server: String, declining: Bool) async -> MultiplayerActionResult {
        await result(id: request.id, server: server,
                     failing: declining ? "Couldn’t decline the request." : "Couldn’t withdraw the request.") {
            share.remove(request, on: server, declining: declining, report: $0)
        }
    }

    // MARK: Grant sheet

    /// Sends the grant the sheet's draft describes. The ID is the shared resource's.
    func sendGrant() async -> MultiplayerActionResult {
        let draft = share.grantDraft
        guard share.canGrant else {
            let reason = isBusy || client == nil ? notSent("Couldn’t share it.")
                                                      : MultiplayerSentence.join("Couldn’t share it.", share.grantHint)
            return .failed(id: draft.resourceID, server: draft.server, reason: reason)
        }
        return await result(id: draft.resourceID, server: draft.server, failing: "Couldn’t share it.") {
            share.confirmGrant(report: $0)
        }
    }
}
