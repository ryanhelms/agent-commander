import SwiftUI

// ATOMIC LEVEL: Organisms for the teams composers hosted outside the tray (DESIGN.md, "Hosts").
//   MultiplayerWorkspaceHost   a new workspace for a group
//   MultiplayerClaimHost       a claim on part of a workspace
//   MultiplayerCardHost        one card: claim it, complete it with a result, release or reopen it
//   MultiplayerQueueHost       a branch for a workspace's merge queue
//   MultiplayerKnowledgeHost   a knowledge item, or a new version of one
//   MultiplayerHostRunHost     one enrolled command on a friend's host, and its result
//   MultiplayerPolicyHost      a relay's policy, its members and its devices, for its admin
// Each draws the tray's own teams composer in `MultiplayerHostFrame` and adds nothing to its
// styling. Each keeps its draft, what it read, its second press and its refusal in its own state,
// names its target in every call, and never reads or moves the tray's route. The view that
// presents a host closes it from `onCancel`, and from `onFinish` when the result is done; a
// refusal stays on the host so the person can fix it.

/// The line a teams host shows in place of its composer: its server is offline, or what it was
/// opened for is gone.
private struct MultiplayerTeamsHostLine: View {
    let text: String

    var body: some View {
        MultiplayerBand {
            Text(text).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
        }
    }
}

extension MultiplayerModel {
    /// A server's name for a sentence, and whether its session can be used now.
    fileprivate func teamsPlace(_ id: String) -> (name: String, isOnline: Bool) {
        (server(id)?.displayName ?? "This server", session(id)?.isOnline == true)
    }
}

private func teamsOffline(_ name: String) -> String { "\(name) is offline. Team work resumes when it’s back." }
private func teamsGone(_ what: String) -> String { "Commander can’t find this \(what) any more." }

// MARK: - New workspace

/// New workspace for a view outside the tray. A workspace that was created reports its ID.
struct MultiplayerWorkspaceHost: View {
    let model: MultiplayerModel
    let server: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var draft = MultiplayerWorkspaceDraft()
    @State private var refusal: String?

    var body: some View {
        let place = model.teamsPlace(server)
        let groups = model.share.teams.groups[server] ?? []
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, note: model.working ?? draft.hint) {
            if place.isOnline {
                MultiplayerWorkspaceForm(draft: $draft, groups: groups)
            } else {
                MultiplayerTeamsHostLine(text: teamsOffline(place.name))
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Create workspace") { create() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(model.isBusy || !draft.canSend || !place.isOnline)
        }
        .task(id: server) {
            // With one group there is nothing to choose.
            if draft.group.isEmpty, groups.count == 1 { draft.group = groups[0].id }
        }
    }

    private func create() {
        refusal = nil
        let asked = draft
        Task {
            let result = await model.createWorkspace(asked, on: server)
            if result.isDone { draft = MultiplayerWorkspaceDraft() }
            refusal = result.reason
            onFinish(result)
        }
    }
}

// MARK: - Claim

/// Claim for a view outside the tray: an issue or a set of paths in a workspace, for one of the
/// person's agents. A claim that was made reports its ID.
struct MultiplayerClaimHost: View {
    let model: MultiplayerModel
    let server: String
    let workspace: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var draft = MultiplayerClaimDraft()
    @State private var refusal: String?

    var body: some View {
        let place = model.teamsPlace(server)
        let teams = model.share.teams
        let found = teams.workspace(workspace, on: server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal,
                             note: model.working ?? "Refused if someone already holds an overlapping claim.") {
            if !place.isOnline {
                MultiplayerTeamsHostLine(text: teamsOffline(place.name))
            } else if let found {
                MultiplayerClaimForm(draft: $draft, workspace: found, handle: teams.handle(on: server))
            } else {
                MultiplayerTeamsHostLine(text: teamsGone("workspace"))
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Claim") { send() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .keyboardShortcut(canSend(place.isOnline, found) ? KeyboardShortcut.defaultAction : nil)
                .disabled(!canSend(place.isOnline, found))
        }
        .task(id: "\(server)/\(workspace)") {
            if draft.agent.isEmpty { draft.agent = teams.defaultAgent(on: server) }
        }
    }

    private func canSend(_ online: Bool, _ found: MultiplayerWorkspace?) -> Bool {
        !model.isBusy && draft.canSend && online && found != nil
    }

    private func send() {
        refusal = nil
        let asked = draft
        Task {
            let result = await model.claim(asked, in: workspace, on: server)
            if result.isDone { draft = MultiplayerClaimDraft(agent: asked.agent) }
            refusal = result.reason
            onFinish(result)
        }
    }
}

// MARK: - Card

/// One card for a view outside the tray. It reads the board itself when it appears and after each
/// change, and stays open. `onFinish` is called for each change, with the card's ID.
struct MultiplayerCardHost: View {
    let model: MultiplayerModel
    let server: String
    let workspace: String
    let card: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var cards = MultiplayerLoad<[MultiplayerCard]>.loading
    @State private var result = ""
    @State private var confirmingRelease = false
    @State private var refusal: String?

    private var found: MultiplayerCard? { cards.value?.first { $0.id == card } }

    var body: some View {
        let me = model.share.teams.handle(on: server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, note: model.working) {
            if let found {
                MultiplayerCardPage(card: found, handle: me, result: $result,
                                    confirmingRelease: confirmingRelease, isBusy: model.isBusy,
                                    onCancelRelease: { confirmingRelease = false },
                                    onConfirmRelease: { move(found, to: .open) })
            } else if cards.value == nil {
                MultiplayerBand {
                    MultiplayerLoadNote(loading: "Reading the card…", failure: cards.failure,
                                        onRetry: { Task { await load(showingProgress: true) } })
                }
            } else {
                MultiplayerTeamsHostLine(text: teamsGone("card"))
            }
        } actions: {
            Button("Close", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            if let found {
                switch found.known {
                case .open:
                    Button("Claim card") { move(found, to: .claimed) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(model.isBusy)
                case .claimed:
                    if found.isAssigned(to: me) {
                        Button("Release…") { confirmingRelease = true }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(model.isBusy || confirmingRelease)
                        Button("Complete card") { move(found, to: .done) }
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.isBusy)
                            .help("Complete (⌘Return)")
                    }
                case .done:
                    Button("Reopen") { move(found, to: .open) }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(model.isBusy)
                }
            }
        }
        .task(id: "\(server)/\(workspace)/\(card)") {
            result = ""
            confirmingRelease = false
            await load(showingProgress: true)
            result = found?.result ?? ""
        }
    }

    private func load(showingProgress: Bool) async {
        if showingProgress { cards = .loading }
        let next = await model.share.teams.loadCards(in: workspace, on: server)
        // A failed read after a change keeps the card already shown.
        if next.value != nil || cards.value == nil { cards = next }
    }

    private func move(_ card: MultiplayerCard, to state: MultiplayerCard.State) {
        refusal = nil
        confirmingRelease = false
        let text = result
        Task {
            let answer = await model.updateCard(card, in: workspace, on: server, to: state, result: text)
            if answer.isDone { await load(showingProgress: false) }
            refusal = answer.reason
            onFinish(answer)
        }
    }
}

// MARK: - Queue a branch

/// Queue a branch for a view outside the tray. The checkout and the test command start from the
/// workspace's last queued branch. A branch that was queued reports its entry's ID.
struct MultiplayerQueueHost: View {
    let model: MultiplayerModel
    let server: String
    let workspace: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var draft = MultiplayerQueueDraft()
    @State private var refusal: String?

    var body: some View {
        let place = model.teamsPlace(server)
        let teams = model.share.teams
        let found = teams.workspace(workspace, on: server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal,
                             note: model.working ?? "Nothing merges until you run the queue.") {
            if !place.isOnline {
                MultiplayerTeamsHostLine(text: teamsOffline(place.name))
            } else if let found {
                MultiplayerQueueForm(draft: $draft, workspace: found, onChooseCheckout: {
                    if let checkout = MultiplayerFilePanel.chooseCheckout(for: found.name.multiplayerDisplay) {
                        draft.checkout = checkout
                    }
                })
            } else {
                MultiplayerTeamsHostLine(text: teamsGone("workspace"))
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Queue branch") { send() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(model.isBusy || !draft.canSend || !place.isOnline || found == nil)
        }
        .task(id: "\(server)/\(workspace)") {
            guard draft == MultiplayerQueueDraft(), let last = teams.queue(for: workspace).last else { return }
            draft = MultiplayerQueueDraft(checkout: last.checkout, testText: last.test.joined(separator: " "))
        }
    }

    private func send() {
        refusal = nil
        let asked = draft
        Task {
            let result = await model.addToQueue(asked, for: workspace, on: server)
            if result.isDone { draft = MultiplayerQueueDraft(checkout: asked.checkout, testText: asked.testText) }
            refusal = result.reason
            onFinish(result)
        }
    }
}

// MARK: - Share knowledge

/// Share knowledge for a view outside the tray: a new item, or a new version of `editing`. A
/// refusal for a secret stays on the form with what to do about it. An item that was shared
/// reports its ID.
struct MultiplayerKnowledgeHost: View {
    let model: MultiplayerModel
    let server: String
    /// The item a new version is for; nil for a new item.
    var editing: MultiplayerKnowledgeItem? = nil
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var draft = MultiplayerKnowledgeDraft()
    @State private var secretRefusal: String?
    @State private var refusal: String?

    var body: some View {
        let place = model.teamsPlace(server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal,
                             note: model.working ?? (draft.secretProblem == nil ? nil : "Remove the secret to share this.")) {
            if place.isOnline {
                MultiplayerKnowledgeForm(draft: $draft, friends: model.session(server)?.status?.friends ?? [],
                                         groups: model.share.teams.groups[server] ?? [], refusal: secretRefusal)
            } else {
                MultiplayerTeamsHostLine(text: teamsOffline(place.name))
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(draft.editing.isEmpty ? "Share" : "Save new version") { send() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(model.isBusy || !draft.canSend || !place.isOnline)
        }
        .task(id: "\(server)/\(editing?.id ?? "")") {
            draft = MultiplayerKnowledgeDraft(editing: editing)
            secretRefusal = nil
        }
    }

    private func send() {
        refusal = nil
        secretRefusal = nil
        let asked = draft
        Task {
            let result = await model.shareKnowledge(asked, on: server)
            if result.isDone { draft = MultiplayerKnowledgeDraft() }
            if let reason = result.reason, MultiplayerSecretCheck.isRefusal(reason) { secretRefusal = MultiplayerSecretCheck.refusal }
            refusal = result.reason
            onFinish(result)
        }
    }
}

// MARK: - Run on a host

/// Run on a host for a view outside the tray: one enrolled command on a friend's host. The host
/// stays open to show the exit code and the end of the output. `onFinish` is called for each run
/// sent, with the run's request as its ID.
struct MultiplayerHostRunHost: View {
    let model: MultiplayerModel
    let server: String
    let resource: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var draft = MultiplayerHostRunDraft()
    @State private var reply: MultiplayerSentRequest?
    @State private var refusal: String?

    var body: some View {
        let place = model.teamsPlace(server)
        let entry = model.share.entry(resource, on: server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal,
                             note: model.working ?? "Runs on the owner’s Mac, under their grant and approval rules.") {
            if place.isOnline {
                MultiplayerHostRunPage(draft: $draft, entry: entry, reply: reply)
            } else {
                MultiplayerTeamsHostLine(text: teamsOffline(place.name))
            }
        } actions: {
            Button(reply == nil ? "Cancel" : "Close", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Run command") { run() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isBusy || !draft.canSend || !place.isOnline)
                .help("Run (⌘Return)")
        }
        .task(id: "\(server)/\(resource)") {
            // A host with one enrolled command has nothing to choose.
            let commands = entry?.capabilities?.commandNames ?? []
            draft = MultiplayerHostRunDraft(command: commands.count == 1 ? commands[0] : "")
            reply = nil
        }
    }

    private func run() {
        refusal = nil
        let asked = draft
        Task {
            let answer = await model.runOnHost(asked, resource: resource, on: server)
            if let value = answer.value { reply = value }
            refusal = answer.failure
            onFinish(answer.result(id: answer.value?.request ?? "", server: server))
        }
    }
}

// MARK: - Relay policy

/// Relay policy for a view outside the tray, for the relay's admin: its sharing limits, and
/// suspending a member or revoking a device, each after a second press. It reads the policy when
/// it appears and keeps it itself. A change that went through stays on the host. `onFinish` is
/// called for each change: the server's ID for a save, the member's handle or the device's ID
/// otherwise.
struct MultiplayerPolicyHost: View {
    let model: MultiplayerModel
    let server: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var state = MultiplayerLoad<MultiplayerRelayPolicy>.loading
    @State private var draft = MultiplayerPolicyDraft()
    @State private var confirming: MultiplayerTeamsConfirmation?
    @State private var refusal: String?
    @State private var confirmation: String?

    private var hasChanges: Bool { state.value.flatMap { draft.changes(from: $0) }?.isEmpty == false }

    var body: some View {
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, confirmation: $confirmation,
                             note: model.working ?? (state.value == nil ? nil
                                    : hasChanges ? "Applies to everyone on this relay." : "Nothing changed yet.")) {
            MultiplayerPolicyPage(state: state, draft: $draft, confirming: confirming, isBusy: model.isBusy,
                                  onRetry: { Task { await load() } },
                                  onAskSuspend: { confirming = .suspend(draft.trimmedMember) },
                                  onRestore: { setSuspended(false) },
                                  onAskRevoke: { confirming = .revokeDevice(draft.trimmedDevice) },
                                  onCancel: { confirming = nil },
                                  onConfirm: {
                                      if case .suspend? = confirming { setSuspended(true) } else { revoke() }
                                  })
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save policy") { save() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(model.isBusy || !hasChanges)
        }
        .task(id: server) { await load() }
    }

    private func load() async {
        state = .loading
        confirming = nil
        let next = await model.share.teams.loadPolicy(on: server)
        if let policy = next.value { draft = MultiplayerPolicyDraft(policy) }
        state = next
    }

    private func begin() {
        refusal = nil
        confirmation = nil
        confirming = nil
    }

    private func save() {
        guard let saved = state.value else { return }
        begin()
        let asked = draft
        Task {
            let answer = await model.savePolicy(asked, from: saved, on: server)
            let message = "Saved. The policy applies to everyone on this relay."
            if let next = answer.value {
                // The member and the device typed below the policy are not part of the save.
                let (member, device) = (draft.member, draft.device)
                state = .loaded(next)
                draft = MultiplayerPolicyDraft(next)
                (draft.member, draft.device) = (member, device)
                confirmation = message
            }
            refusal = answer.failure
            onFinish(answer.result(id: server, server: server, message: message))
        }
    }

    private func setSuspended(_ suspended: Bool) {
        let member = draft.trimmedMember
        begin()
        Task {
            let result = await model.setSuspended(suspended, member: member, on: server)
            if result.isDone { draft.member = "" }
            confirmation = result.message
            refusal = result.reason
            onFinish(result)
        }
    }

    private func revoke() {
        let device = draft.trimmedDevice
        begin()
        Task {
            let result = await model.revokeDevice(device, on: server)
            if result.isDone { draft.device = "" }
            confirmation = result.message
            refusal = result.reason
            onFinish(result)
        }
    }
}
