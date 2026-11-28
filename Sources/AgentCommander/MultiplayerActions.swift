import Foundation

// FEATURE MODEL: answers a view outside the tray can await.
// The main window's Needs you inbox and network pages answer requests one row at a time, so each
// answer comes back for that request alone. The tray's own banner still shows the same text; these
// calls add the per-request outcome and never replace it.
// - Every call runs through the same one-at-a-time action the tray uses. A call that can't start
//   says why and sends nothing.
// - A failure's reason is a full sentence, built with `MultiplayerSentence.join`.
// - Every call names its target. None reads or moves the tray's route, so the tray can be on any
//   page, or closed, while a view outside it acts. Drafts are the caller's own.
// - A call that makes something new (a hand-off, a review, a fan-out, a saved server) reports the
//   new thing's ID. A call that brings a value back (a consult's reply, an invite link) returns a
//   `MultiplayerLoad` of it: `.loaded` or `.failed`, never `.loading`.

/// What one answer came to, for the request it was about. After `.done` for an approval or an
/// access request, the live app keeps the answered row in the share model's lists for
/// `MultiplayerShareModel.answeredHold`, so the caller's row can show the outcome before it leaves.
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
    /// The ID of what the action made, when it made something.
    var made: String?
}

/// A value an action brought back, kept until the action's task ends.
@MainActor
private final class MultiplayerActionValue<Value> {
    var value: Value?
}

extension MultiplayerModel {
    /// Why an answer can't be sent right now.
    func notSent(_ lead: String) -> String {
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

    private func answerFriend(_ command: MultiplayerCommand, id: String, on server: String,
                              keepingPage: Bool = false) async -> MultiplayerActionResult {
        guard let session = session(server), session.isOnline else {
            let name = self.server(server)?.displayName ?? "that server"
            return .failed(id: id, server: server,
                           reason: MultiplayerSentence.join(command.failureTitle, "Sign in to \(name) first."))
        }
        guard let task = session.perform(command, keepingPage: keepingPage) else {
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
        if let answer = share.answer(for: approval, on: server) {
            return .failed(id: approval.id, server: server,
                           reason: MultiplayerSentence.join(approve ? "Couldn’t approve the request." : "Couldn’t deny the request.",
                                                            "It was already \(answer.title.lowercased())."))
        }
        return await result(id: approval.id, server: server,
                     failing: approve ? "Couldn’t approve the request." : "Couldn’t deny the request.") {
            share.decide(approval, on: server, approve: approve, report: $0)
        }
    }

    /// Declines an access request sent to you, or withdraws one you sent.
    func remove(_ request: MultiplayerAccessRequest, on server: String, declining: Bool) async -> MultiplayerActionResult {
        if let answer = share.answer(for: request, on: server) {
            return .failed(id: request.id, server: server,
                           reason: MultiplayerSentence.join(declining ? "Couldn’t decline the request." : "Couldn’t withdraw the request.",
                                                            "It was already \(answer.title.lowercased())."))
        }
        return await result(id: request.id, server: server,
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

// MARK: - Actions that name their target

extension MultiplayerModel {
    /// Runs one tray action that makes something new, and reports the new thing's ID.
    func made(server: String, failing lead: String,
                      _ start: (_ report: @escaping @MainActor (String?) -> Void,
                                _ made: @escaping @MainActor (String) -> Void) -> Task<Void, Never>?) async -> MultiplayerActionResult {
        let report = MultiplayerActionReport()
        guard let task = start({ report.failure = $0 }, { report.made = $0 }) else {
            return .failed(id: "", server: server, reason: notSent(lead))
        }
        await task.value
        if let failure = report.failure { return .failed(id: "", server: server, reason: failure) }
        return .done(id: report.made ?? "", server: server, message: notice)
    }

    /// Runs one tray action that brings a value back.
    func brought<Value: Equatable>(failing lead: String,
                                           _ start: (_ report: @escaping @MainActor (String?) -> Void,
                                                     _ keep: @escaping @MainActor (Value) -> Void) -> Task<Void, Never>?) async -> MultiplayerLoad<Value> {
        let report = MultiplayerActionReport()
        let box = MultiplayerActionValue<Value>()
        guard let task = start({ report.failure = $0 }, { box.value = $0 }) else { return .failed(notSent(lead)) }
        await task.value
        if let failure = report.failure { return .failed(failure) }
        guard let value = box.value else { return .failed(MultiplayerSentence.join(lead, "The network helper sent no answer.")) }
        return .loaded(value)
    }

    func refused(_ id: String, _ server: String, _ lead: String, _ why: String) -> MultiplayerActionResult {
        .failed(id: id, server: server, reason: MultiplayerSentence.join(lead, why))
    }

    // MARK: Threads

    /// Posts a comment to a request's thread. The ID is the request's. Read the thread again with
    /// `share.loadThread(_:on:)` to show it.
    func postComment(_ text: String, to request: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t post the comment."
        guard MultiplayerShareModel.canPost(comment: text) else {
            return refused(request, server, lead, text.count > 4000 ? "Keep it under 4,000 characters." : "Write a comment first.")
        }
        return await result(id: request, server: server, failing: lead) {
            share.postComment(text, to: request, on: server, report: $0)
        }
    }

    // MARK: Access requests

    /// Asks a resource's owner for access. The ID is the resource's.
    func sendAccessRequest(_ draft: MultiplayerAccessDraft, for resource: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t send the request."
        guard draft.canSend else { return refused(resource, server, lead, draft.problem ?? "Choose at least one action.") }
        guard share.entry(resource, on: server) != nil else {
            return refused(resource, server, lead, "That resource is no longer in the shared directory.")
        }
        return await result(id: resource, server: server, failing: lead) {
            share.sendAccessRequest(draft, for: resource, on: server, report: $0)
        }
    }

    // MARK: Consult, hand off and review

    /// Sends one prompt to a friend's worker and brings back its reply.
    func sendConsult(_ draft: MultiplayerConsultDraft, to resource: String, on server: String) async -> MultiplayerLoad<MultiplayerSentRequest> {
        let lead = "Couldn’t send the prompt."
        guard draft.canSend else { return .failed(MultiplayerSentence.join(lead, draft.problem ?? "Write a prompt first.")) }
        return await brought(failing: lead) { share.sendConsult(draft, to: resource, on: server, report: $0, then: $1) }
    }

    /// Hands a task to a friend's agent. The ID is the new hand-off's request.
    func sendHandoff(_ draft: MultiplayerHandoffDraft, to resource: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t hand off the task."
        let draft = draft.addressed(toWorkspaceInbox: share.entry(resource, on: server)?.isWorkspaceInbox == true)
        guard draft.canSend else {
            return refused("", server, lead, draft.problem ?? draft.expectedHeadProblem ?? "Give the task a title and say what to do.")
        }
        return await made(server: server, failing: lead) { report, made in
            share.sendHandoff(draft, to: resource, on: server, report: report, then: { made($0.request) })
        }
    }

    /// Asks how a hand-off's run is going, or for its result and artifacts. The ID is the
    /// hand-off's request; what came back is in `share.reports` under it.
    func checkHandoff(_ row: MultiplayerSentRequest, on server: String, result wanted: Bool) async -> MultiplayerActionResult {
        let lead = wanted ? "Couldn’t read the result." : "Couldn’t check the run."
        guard row.run != nil else { return refused(row.request, server, lead, row.refusal ?? "This hand-off has no run yet.") }
        return await result(id: row.request, server: server, failing: lead) {
            share.check(row, on: server, result: wanted, report: $0)
        }
    }

    /// Applies or saves one artifact of a hand-off's result into a local checkout, and answers for
    /// that artifact. The message says what was done and names the saved file's final name when
    /// the device gave it another ("Saved report.md into relay as report.md.1a2b3c4d."). The ID is
    /// the hand-off's request. The caller confirms the checkout with the person first.
    func apply(artifact index: Int, of row: MultiplayerSentRequest, on server: String, checkout: String) async -> MultiplayerActionResult {
        let name = share.reports[row.request].flatMap { $0.artifacts.indices.contains(index) ? $0.artifacts[index].name.multiplayerDisplay : nil }
        let lead = "Couldn’t apply \(name ?? "the artifact")."
        if let problem = share.applyProblem(artifact: index, of: row, checkout: checkout) { return refused(row.request, server, lead, problem) }
        return await result(id: row.request, server: server, failing: lead) {
            share.apply(artifact: index, of: row, on: server, checkout: checkout, report: $0)
        }
    }

    /// Asks a friend's worker for a review. The ID is the new review's request.
    func sendReview(_ draft: MultiplayerReviewDraft, to resource: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t send the review request."
        guard draft.canSend else {
            return refused("", server, lead, draft.problem ?? "Give it a title, and a diff or a pull request.")
        }
        return await made(server: server, failing: lead) { report, made in
            share.live.sendReview(draft, to: resource, on: server, report: report, then: { made($0.request) })
        }
    }

    /// Posts a review's findings to the pull request the caller names. The caller shows what will
    /// be posted and where, and asks the person to confirm, before calling this. The ID is the
    /// review's request.
    func postReview(_ request: String, on server: String, to link: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t post the review."
        if let problem = share.live.postProblem(request, on: server, link: link) { return refused(request, server, lead, problem) }
        return await result(id: request, server: server, failing: lead) {
            share.live.postReview(request, on: server, to: link, report: $0)
        }
    }

    /// Sends a suggestion for a friend's worker and brings back the reply.
    func sendSuggestion(_ text: String, to resource: String, on server: String) async -> MultiplayerLoad<MultiplayerSentRequest> {
        let lead = "Couldn’t send the suggestion."
        guard MultiplayerLiveModel.canSend(suggestion: text) else {
            return .failed(MultiplayerSentence.join(lead, "Write a suggestion of at most 4,096 bytes."))
        }
        return await brought(failing: lead) { share.live.sendSuggestion(text, to: resource, on: server, report: $0, then: $1) }
    }

    // MARK: Fan-out

    /// Sends one prompt to several friends' workers. The ID is the new fan-out's request.
    func sendFanout(_ draft: MultiplayerFanoutDraft, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t send the fan-out."
        guard draft.canSend else { return refused("", server, lead, draft.problem ?? "Choose at least 2 workers and write a prompt.") }
        let reachable = share.live.fanoutTargets(on: server).filter { draft.targets.contains($0.id) }.count
        guard reachable >= MultiplayerFanoutDraft.targetRange.lowerBound else {
            return refused("", server, lead, "Fewer than 2 of the chosen workers can be prompted now.")
        }
        return await made(server: server, failing: lead) { report, made in
            share.live.sendFanout(draft, on: server, report: report, then: { made($0.request) })
        }
    }

    // MARK: Servers

    /// Renames a saved server. The ID and the server are the server's own ID.
    func rename(_ server: MultiplayerServerSummary, to name: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t rename the server."
        if let problem = renameProblem(server.id, to: name) { return refused(server.id, server.id, lead, problem) }
        return await result(id: server.id, server: server.id, failing: lead) { rename(server.id, to: name, report: $0) }
    }

    /// Removes a saved server, by value. The caller asks the person to confirm first. It uses
    /// neither the tray's confirm step nor its route: a tray on any other page stays there, and a
    /// tray on the removed server's own page returns home, because that page is gone. The ID and
    /// the server are the server's own ID.
    func remove(_ server: MultiplayerServerSummary) async -> MultiplayerActionResult {
        let lead = "Couldn’t remove the server."
        guard self.server(server.id) != nil else { return refused(server.id, server.id, lead, "That server is no longer in your list.") }
        return await result(id: server.id, server: server.id, failing: lead) { remove(server.id, report: $0) }
    }

    /// Pins a blocked server's new key: the one the person confirmed, after the caller showed it
    /// from `checkCertificate(of:)` and asked twice, as the tray does. The model checks the server
    /// once more itself. Nothing is sent unless that check shows the confirmed key, and the key is
    /// not the one already pinned.
    func trust(_ server: MultiplayerServerSummary, confirming pin: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t trust the new certificate."
        guard let saved = self.server(server.id), saved.state == .certChanged else {
            return refused(server.id, server.id, lead, "This server isn’t blocked by a changed certificate.")
        }
        guard !isBusy else { return .failed(id: server.id, server: server.id, reason: notSent(lead)) }
        let check = await checkCertificate(of: saved)
        if let failure = check.failure { return refused(server.id, server.id, lead, failure) }
        guard let shown = check.value?.step(.tls)?.pin, !shown.isEmpty, shown == pin, shown != saved.pin else {
            return refused(server.id, server.id, lead, "The server no longer shows the certificate you confirmed. Check it again.")
        }
        return await result(id: server.id, server: server.id, failing: lead) { trust(saved, pin: shown, report: $0) }
    }

    /// Saves a server from the caller's draft and the check that passed for its address, or joins
    /// it when the draft carries an invite. The ID and the server are the saved server's ID.
    func saveServer(_ draft: MultiplayerServerDraft, checked check: MultiplayerProbe) async -> MultiplayerActionResult {
        let lead = draft.invite == nil ? "Couldn’t save the server." : "Couldn’t join the server."
        let form = MultiplayerServerForm(draft: draft, probe: .finished(check, address: draft.trimmedAddress), servers: servers)
        guard form.canSave else { return refused("", "", lead, form.hint) }
        let report = MultiplayerActionReport()
        guard let task = saveServer(draft, checked: check, report: { report.failure = $0 }, then: { report.made = $0.id }) else {
            return .failed(id: "", server: "", reason: notSent(lead))
        }
        await task.value
        if let failure = report.failure { return .failed(id: "", server: "", reason: failure) }
        return .done(id: report.made ?? "", server: report.made ?? "", message: notice)
    }

    // MARK: Profile, invites and membership

    /// Saves your profile on one server. The ID is the server's.
    func saveProfile(_ draft: MultiplayerProfileDraft, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t save your profile."
        if let problem = draft.problem { return refused(server, server, lead, problem) }
        guard draft.hasChanges else { return refused(server, server, lead, "Nothing changed yet.") }
        return await result(id: server, server: server, failing: lead) { saveProfile(draft, on: server, report: $0) }
    }

    /// Makes an invite link for a server and brings it back.
    func createInvite(_ draft: MultiplayerInviteDraft, on server: String) async -> MultiplayerLoad<MultiplayerInvite> {
        let lead = "Couldn’t create the invite."
        guard canInvite(server) else { return .failed(MultiplayerSentence.join(lead, "Only an admin can invite people to this server.")) }
        return await brought(failing: lead) { createInvite(draft, on: server, report: $0, then: $1) }
    }

    /// Saves a relay's membership settings and brings back what the relay now holds.
    func saveMembership(_ draft: MultiplayerMembershipDraft, on server: String) async -> MultiplayerLoad<MultiplayerMembership> {
        let lead = "Couldn’t save membership."
        if let problem = draft.problem { return .failed(MultiplayerSentence.join(lead, problem)) }
        return await brought(failing: lead) { saveMembership(draft, on: server, report: $0, then: $1) }
    }

    // MARK: Friends and grants

    /// Looks the handle up exactly, then sends that person a friend request. Nothing is sent
    /// unless the network returns the same handle. The ID is the handle.
    func sendFriendRequest(to handle: String, on server: String) async -> MultiplayerActionResult {
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = MultiplayerCommand.sendRequest(handle: handle)
        guard let session = session(server), session.isOnline else {
            return await answerFriend(command, id: handle, on: server)    // says to sign in first
        }
        if let failure = await session.lookUp(handle).failure { return refused(handle, server, command.failureTitle, failure) }
        return await answerFriend(command, id: handle, on: server, keepingPage: true)
    }

    /// Ends one grant, by value. It needs no page: the server's own page, its confirm step and the
    /// tray's route stay as they are. The caller asks the person to confirm first. The ID is the grant's.
    func revoke(_ grant: MultiplayerGrant, on server: String) async -> MultiplayerActionResult {
        let command = session(server)?.revokeCommand(grant)
            ?? .revoke(grantID: grant.id, handle: grant.handle, resourceName: grant.resource, capability: grant.capability)
        return await answerFriend(command, id: grant.id, on: server, keepingPage: true)
    }
}
