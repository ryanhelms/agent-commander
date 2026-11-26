import Foundation

// FEATURE MODEL: teams reads and changes a view outside the tray can await.
// The main window's Teams pages read and act per workspace, item or server, so each answer comes
// back to the caller that asked. Same rules as MultiplayerActions.swift:
// - A read is the caller's own. It returns `.loaded` or `.failed`, never `.loading`, and changes
//   nothing: not the tray's route, not the list on the tray's own page, not a draft.
// - A change names its target and takes the caller's values. It runs through the tray's one action
//   at a time, so the tray's banner shows the same progress and outcome. It never reads or moves
//   the route. Lists kept per server (groups, workspaces, the library, the merge queue) are
//   brought up to date for everyone; a list that belongs to the tray's open page is left alone,
//   so the caller reads its own again.
// - The ID reported is what was made or acted on. A change that brings a value back returns a
//   `MultiplayerLoad` of it.
// - Nothing here asks twice. The caller asks the person to confirm before it deletes a group,
//   removes a member, releases a claim or a held card, removes a queued branch, leaves a
//   workspace, suspends a member or revokes a device, as the tray does.

extension MultiplayerKnowledgeDraft {
    /// A draft for a new item, or for a new version of `item`.
    init(editing item: MultiplayerKnowledgeItem?) {
        self.init()
        guard let item else { return }
        editing = item.id
        kind = MultiplayerKnowledgeKind(rawValue: item.kind) ?? .prompt
        name = item.name
        content = item.content
        if let (scope, target) = MultiplayerKnowledgeScope.parse(item.visibility) { (self.scope, self.target) = (scope, target) }
    }
}

// MARK: - Caller-owned reads

extension MultiplayerTeamsModel {
    private func read<Value: Equatable>(_ server: String,
                                        failure: (any Error) -> String = MultiplayerShareModel.readFailure,
                                        _ work: (MultiplayerClient) async throws -> Value) async -> MultiplayerLoad<Value> {
        guard let client = share?.tray?.client else {
            return .failed(share?.tray?.unavailable?.message ?? "The network helper isn’t available.")
        }
        do { return .loaded(try await work(client.scoped(to: server))) } catch { return .failed(failure(error)) }
    }

    /// Reads a workspace's board for the caller, who keeps the result.
    func loadCards(in workspace: String, on server: String) async -> MultiplayerLoad<[MultiplayerCard]> {
        await read(server) { try await $0.cards(in: workspace) }
    }

    /// Reads a pull-request workspace's open pull requests for the caller. The device runs `gh`
    /// with the person's own login. A merge-queue workspace has none to read.
    func loadPullRequests(in workspace: String, on server: String) async -> MultiplayerLoad<MultiplayerPullRequestList> {
        await read(server, failure: { error in
            let failure = MultiplayerFailure.from(error)
            return failure == .cancelled ? "The read was stopped. Try again." : MultiplayerPullRequestList.problem(failure.message)
        }) { try await $0.pullRequests(in: workspace) }
    }

    /// Reads this Mac's merge queue for one workspace, oldest first, for the caller.
    func loadQueue(for workspace: String, on server: String) async -> MultiplayerLoad<[MultiplayerQueueEntry]> {
        await read(server) { try await $0.mergeQueue().filter { $0.workspace == workspace } }
    }

    /// Reads every version of a knowledge item for the caller.
    func loadVersions(of item: String, on server: String) async -> MultiplayerLoad<[MultiplayerKnowledgeItem]> {
        await read(server) { try await $0.knowledgeVersions(item) }
    }

    /// Reads a resource's reputation for the caller.
    func loadReputation(of resource: String, on server: String) async -> MultiplayerLoad<MultiplayerReputation> {
        await read(server) { try await $0.reputation(resource) }
    }

    /// Searches a server's directory for the caller, who keeps the query and the result.
    func searchDirectory(_ query: String, on server: String) async -> MultiplayerLoad<MultiplayerDirectorySearch> {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return await read(server) { try await $0.searchDirectory(query) }
    }

    /// Reads a relay's policy for the caller. Only the relay's admin can.
    func loadPolicy(on server: String) async -> MultiplayerLoad<MultiplayerRelayPolicy> {
        await read(server) { try await $0.relayPolicy() }
    }

    /// Reads a relay's members and devices for the caller. Only the relay's admin can. Act on a
    /// row with `setSuspended(_:member:on:)` and `revokeDevice(_:on:)`, then read again.
    func loadRoster(on server: String) async -> MultiplayerLoad<MultiplayerRelayRoster> {
        await read(server) { try await $0.relayRoster() }
    }

    /// Reads a workspace's combined view for the caller: each member of its group who hasn't left
    /// it, with their workers.
    func loadCombinedView(of workspace: String, on server: String) async -> MultiplayerLoad<MultiplayerCombinedView> {
        await read(server) { try await $0.combinedView(of: workspace) }
    }

    /// Reads what a member can know of a relay for the caller: whether they administer it, how
    /// people join, and how widely its policy lets knowledge travel.
    func loadMe(on server: String) async -> MultiplayerLoad<MultiplayerMe> {
        await read(server) { try await $0.me() }
    }
}

// MARK: - Changes that name their target

extension MultiplayerModel {
    /// Why nothing can be sent to a server now, when nothing can.
    private func teamsOffline(_ server: String) -> String? {
        if session(server)?.isOnline == true { return nil }
        return "Sign in to \(self.server(server)?.displayName ?? "that server") first."
    }

    // MARK: Groups

    /// Creates a group. The ID is the new group's.
    func createGroup(named name: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t create the group."
        if let problem = teamsOffline(server) ?? MultiplayerTeamsModel.groupNameProblem(name) { return refused("", server, lead, problem) }
        return await made(server: server, failing: lead) { report, made in
            share.teams.createGroup(named: name, on: server, report: report, then: made)
        }
    }

    /// Adds a friend to a group, who then has the group's grants. The ID is the group's.
    func addMember(_ handle: String, to group: MultiplayerGroup, on server: String) async -> MultiplayerActionResult {
        await changeMember(handle, in: group, on: server, isMember: true)
    }

    /// Removes a member from a group, who then loses the group's grants. The ID is the group's.
    func removeMember(_ handle: String, from group: MultiplayerGroup, on server: String) async -> MultiplayerActionResult {
        await changeMember(handle, in: group, on: server, isMember: false)
    }

    private func changeMember(_ handle: String, in group: MultiplayerGroup, on server: String, isMember: Bool) async -> MultiplayerActionResult {
        let who = handle.multiplayerDisplay
        let lead = isMember ? "Couldn’t add \(who)." : "Couldn’t remove \(who)."
        if let problem = teamsOffline(server) { return refused(group.id, server, lead, problem) }
        return await result(id: group.id, server: server, failing: lead) {
            share.teams.changeMember(handle, in: group, on: server, isMember: isMember, report: $0)
        }
    }

    /// Deletes a group. Its members lose the group's grants. The ID is the group's.
    func deleteGroup(_ group: MultiplayerGroup, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t delete the group."
        if let problem = teamsOffline(server) { return refused(group.id, server, lead, problem) }
        return await result(id: group.id, server: server, failing: lead) { share.teams.removeGroup(group, on: server, report: $0) }
    }

    // MARK: Workspaces and claims

    /// Creates a workspace. The ID is the new workspace's.
    func createWorkspace(_ draft: MultiplayerWorkspaceDraft, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t create the workspace."
        if let problem = teamsOffline(server) ?? (draft.canSend ? nil : draft.hint ?? "Fill in every field.") {
            return refused("", server, lead, problem)
        }
        return await made(server: server, failing: lead) { report, made in
            share.teams.createWorkspace(draft, on: server, report: report, then: made)
        }
    }

    /// Claims part of a workspace in the person's own name. The ID is the new claim's, or empty
    /// when the relay doesn't name it; the claim is then in `share.teams.workspace(_:on:)`.
    func claim(_ draft: MultiplayerClaimDraft, in workspace: String, on server: String) async -> MultiplayerActionResult {
        await claimAnswer(draft, in: workspace, on: server).result
    }

    /// Claims part of a workspace, as `claim(_:in:on:)` does, and says who stopped it when the
    /// relay refused for an overlap: `refusal` names the holder and the blocking claim, so the
    /// caller can mark that row. `refusal` is nil for a claim that was made and for any other
    /// refusal.
    func claimAnswer(_ draft: MultiplayerClaimDraft, in workspace: String, on server: String) async -> MultiplayerClaimAnswer {
        let lead = "Couldn’t claim it."
        let problem = teamsOffline(server) ?? draft.keyProblem ?? draft.agentProblem
            ?? (draft.canSend ? nil : draft.trimmedKey.isEmpty ? "Say what to claim." : "Name the agent that does the work.")
        if let problem { return MultiplayerClaimAnswer(result: refused("", server, lead, problem)) }
        var refusal: MultiplayerClaimRefusal?
        let result = await made(server: server, failing: lead) { report, made in
            share.teams.sendClaim(draft, in: workspace, on: server, report: report, refused: { refusal = $0 }, then: made)
        }
        return MultiplayerClaimAnswer(result: result, refusal: result.isDone ? nil : refusal)
    }

    /// Saves the owner's edit of a workspace, sending only what differs from the workspace as it
    /// stands. The ID is the workspace's. The edited workspace is then in
    /// `share.teams.workspace(_:on:)`.
    func editWorkspace(_ workspace: String, to edit: MultiplayerWorkspaceEdit, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t save the workspace."
        if let problem = teamsOffline(server) { return refused(workspace, server, lead, problem) }
        guard let saved = share.teams.workspace(workspace, on: server) else {
            return refused(workspace, server, lead, "Commander can’t find this workspace any more.")
        }
        let changes = edit.changes(from: saved)
        if let problem = edit.hint ?? (changes.isEmpty ? "Nothing changed yet." : nil) { return refused(workspace, server, lead, problem) }
        return await result(id: workspace, server: server, failing: lead) {
            share.teams.editWorkspace(workspace, fields: changes, on: server, report: $0)
        }
    }

    /// Leaves a workspace. The person's live claims in it end; they stay in its group. The owner
    /// can't leave. The ID is the workspace's.
    func leaveWorkspace(_ workspace: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t leave the workspace."
        if let problem = teamsOffline(server) { return refused(workspace, server, lead, problem) }
        return await result(id: workspace, server: server, failing: lead) {
            share.teams.leaveWorkspace(workspace, on: server, report: $0)
        }
    }

    /// Releases a claim. The ID is the claim's.
    func release(_ claim: MultiplayerClaim, in workspace: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t release the claim."
        if let problem = teamsOffline(server) { return refused(claim.id, server, lead, problem) }
        return await result(id: claim.id, server: server, failing: lead) {
            share.teams.releaseClaim(claim, in: workspace, on: server, report: $0)
        }
    }

    // MARK: Board

    /// Adds a card to a workspace's board. The ID is the new card's, or empty when the relay
    /// doesn't name it. Read the board again with `share.teams.loadCards(in:on:)` to show it.
    func addCard(_ draft: MultiplayerCardDraft, to workspace: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t add the card."
        let problem = teamsOffline(server)
            ?? (draft.canSend ? nil : draft.trimmedTitle.isEmpty ? "Give the card a title." : "Keep the title under 256 characters.")
        if let problem { return refused("", server, lead, problem) }
        return await made(server: server, failing: lead) { report, made in
            share.teams.addCard(draft, to: workspace, on: server, report: report, then: { id, _ in made(id) })
        }
    }

    /// Moves a card: `.claimed` takes it for the person's first agent, `.done` completes it with
    /// `result`, and `.open` reopens it or gives it up. The ID is the card's.
    func updateCard(_ card: MultiplayerCard, in workspace: String, on server: String,
                    to state: MultiplayerCard.State, result text: String = "") async -> MultiplayerActionResult {
        await updateCardAnswer(card, in: workspace, on: server, to: state, result: text).result
    }

    /// Moves a card, as `updateCard(_:in:on:to:result:)` does, and says who stopped it when the
    /// relay refused because someone else holds the card: `refusal` names the holder and the
    /// blocking claim, so the caller can mark that row. `refusal` is nil for a card that was moved
    /// and for any other refusal.
    func updateCardAnswer(_ card: MultiplayerCard, in workspace: String, on server: String,
                          to state: MultiplayerCard.State, result text: String = "") async -> MultiplayerClaimAnswer {
        let lead = "Couldn’t update the card."
        if let problem = teamsOffline(server) { return MultiplayerClaimAnswer(result: refused(card.id, server, lead, problem)) }
        var refusal: MultiplayerClaimRefusal?
        let result = await result(id: card.id, server: server, failing: lead) {
            share.teams.updateCard(card, in: workspace, on: server, to: state, result: text, report: $0, refused: { refusal = $0 })
        }
        return MultiplayerClaimAnswer(result: result, refusal: result.isDone ? nil : refusal)
    }

    /// Completes a card with the result it was finished with. The ID is the card's.
    func completeCard(_ card: MultiplayerCard, in workspace: String, on server: String, result text: String) async -> MultiplayerActionResult {
        await completeCardAnswer(card, in: workspace, on: server, result: text).result
    }

    /// Completes a card, as `completeCard(_:in:on:result:)` does, and says who holds it when the
    /// relay refused for that.
    func completeCardAnswer(_ card: MultiplayerCard, in workspace: String, on server: String, result text: String) async -> MultiplayerClaimAnswer {
        await updateCardAnswer(card, in: workspace, on: server, to: .done, result: text)
    }

    // MARK: Merge queue

    /// Queues a branch for a workspace. Nothing merges until the queue runs. The ID is the queued
    /// entry's; the queue is in `share.teams.queue(for:)`.
    func addToQueue(_ draft: MultiplayerQueueDraft, for workspace: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t queue the branch."
        let problem = teamsOffline(server) ?? draft.checkoutProblem
            ?? (draft.canSend ? nil : draft.trimmedBranch.isEmpty ? "Name the branch." :
                    draft.trimmedBranch.contains(" ") ? "A branch name has no spaces." : "Choose the checkout to merge in.")
        if let problem { return refused("", server, lead, problem) }
        return await made(server: server, failing: lead) { report, made in
            share.teams.addToQueue(draft, for: workspace, on: server, report: report, then: made)
        }
    }

    /// Tests and merges a workspace's queued branches, and brings back the ones that ran, each in
    /// the state it ended in: `merged`, `conflict` or `failed`, with what stopped it.
    func runQueue(_ workspace: String, on server: String) async -> MultiplayerLoad<[MultiplayerQueueEntry]> {
        let lead = "Couldn’t run the merge queue."
        if let problem = teamsOffline(server) { return .failed(MultiplayerSentence.join(lead, problem)) }
        guard share.teams.queue(for: workspace).contains(where: \.isQueued) else {
            return .failed(MultiplayerSentence.join(lead, "No branch is waiting in the queue."))
        }
        return await brought(failing: lead) { share.teams.runQueue(workspace, on: server, report: $0, then: $1) }
    }

    /// Takes a branch out of the queue, whatever its state. The branch itself is untouched. The ID
    /// is the entry's.
    func removeFromQueue(_ entry: MultiplayerQueueEntry, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t remove \(entry.branch.multiplayerDisplay) from the queue."
        if let problem = teamsOffline(server) { return refused(entry.id, server, lead, problem) }
        return await result(id: entry.id, server: server, failing: lead) { share.teams.removeFromQueue(entry, on: server, report: $0) }
    }

    // MARK: Hosts

    /// Runs one enrolled command on a friend's host and brings back what it answered. Read the run
    /// with `MultiplayerHostRun(reply.value)`.
    func runOnHost(_ draft: MultiplayerHostRunDraft, resource: String, on server: String) async -> MultiplayerLoad<MultiplayerSentRequest> {
        let lead = "Couldn’t run the command."
        let problem = teamsOffline(server)
            ?? (draft.canSend ? nil : draft.arguments.count > 32 ? "Use at most 32 extra arguments." : "Choose a command first.")
        if let problem { return .failed(MultiplayerSentence.join(lead, problem)) }
        return await brought(failing: lead) { share.teams.runOnHost(draft, resource: resource, on: server, report: $0, then: $1) }
    }

    // MARK: Knowledge

    /// Shares a knowledge item, or saves a new version of the item the draft edits. Content that
    /// seems to carry a secret is refused before anything is sent, and by the device
    /// (`MultiplayerSecretCheck.isRefusal` reads that from the reason). The ID is the item's.
    func shareKnowledge(_ draft: MultiplayerKnowledgeDraft, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t share \(draft.trimmedName.isEmpty ? "it" : draft.trimmedName.multiplayerDisplay)."
        var problem = teamsOffline(server) ?? draft.nameProblem ?? draft.contentProblem
        if problem == nil, !draft.canSend {
            problem = draft.trimmedName.isEmpty ? "Give it a name."
                : draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Add its content."
                : "Choose who can see it."
        }
        if let problem { return refused(draft.editing, server, lead, problem) }
        return await made(server: server, failing: lead) { report, made in
            share.teams.shareKnowledge(draft, on: server, report: report, then: made)
        }
    }

    /// Installs a skill, or saves an MCP item to `destination`. The message says where it was
    /// written. The ID is the item's.
    func installKnowledge(_ item: MultiplayerKnowledgeItem, on server: String, destination: String = "") async -> MultiplayerActionResult {
        let lead = "Couldn’t install \(item.name.multiplayerDisplay)."
        if let problem = teamsOffline(server) { return refused(item.id, server, lead, problem) }
        return await result(id: item.id, server: server, failing: lead) {
            share.teams.install(item, on: server, destination: destination, report: $0)
        }
    }

    // MARK: Reputation

    /// Endorses a resource for a skill. The ID is the resource's.
    func endorse(_ resource: String, for skill: String, on server: String) async -> MultiplayerActionResult {
        let lead = "Couldn’t endorse it."
        if let problem = teamsOffline(server) ?? MultiplayerTeamsModel.skillProblem(skill) { return refused(resource, server, lead, problem) }
        return await result(id: resource, server: server, failing: lead) {
            share.teams.endorse(resource, for: skill, on: server, report: $0)
        }
    }

    /// Reports how a finished request you sent turned out. The ID is the request's; the outcome is
    /// then in `share.teams.outcomes`.
    func reportOutcome(of request: MultiplayerSentRequest, on server: String, accepted: Bool) async -> MultiplayerActionResult {
        let lead = "Couldn’t report the result."
        if let problem = teamsOffline(server) { return refused(request.request, server, lead, problem) }
        return await result(id: request.request, server: server, failing: lead) {
            share.teams.reportOutcome(request, on: server, accepted: accepted, report: $0)
        }
    }

    // MARK: Relay policy

    /// Saves the caller's edits to a relay's policy, sending only what differs from `saved`, and
    /// brings back what the relay now holds.
    func savePolicy(_ draft: MultiplayerPolicyDraft, from saved: MultiplayerRelayPolicy, on server: String) async -> MultiplayerLoad<MultiplayerRelayPolicy> {
        let lead = "Couldn’t save the policy."
        var problem = teamsOffline(server) ?? draft.scopeProblem ?? draft.grantDaysProblem ?? draft.budgetProblem ?? draft.retentionProblem
        let changes = draft.changes(from: saved) ?? [:]
        if problem == nil, changes.isEmpty { problem = "Nothing changed yet." }
        if let problem { return .failed(MultiplayerSentence.join(lead, problem)) }
        return await brought(failing: lead) { share.teams.savePolicy(changes, on: server, report: $0, then: $1) }
    }

    /// Suspends a member of a relay, whose devices then can't use it, or restores one. The ID is
    /// the member's handle.
    func setSuspended(_ suspended: Bool, member handle: String, on server: String) async -> MultiplayerActionResult {
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let who = handle.isEmpty ? "the member" : handle.multiplayerDisplay
        let lead = suspended ? "Couldn’t suspend \(who)." : "Couldn’t restore \(who)."
        if let problem = teamsOffline(server) ?? (handle.isEmpty ? "Name the member first." : nil) { return refused(handle, server, lead, problem) }
        return await result(id: handle, server: server, failing: lead) {
            share.teams.setSuspended(suspended, member: handle, on: server, report: $0)
        }
    }

    /// Revokes one device on a relay, which must then sign in again. The ID is the device's.
    func revokeDevice(_ device: String, on server: String) async -> MultiplayerActionResult {
        let device = device.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = "Couldn’t revoke the device."
        if let problem = teamsOffline(server) ?? (device.isEmpty ? "Name the device first." : nil) { return refused(device, server, lead, problem) }
        return await result(id: device, server: server, failing: lead) { share.teams.revokeDevice(device, on: server, report: $0) }
    }
}
