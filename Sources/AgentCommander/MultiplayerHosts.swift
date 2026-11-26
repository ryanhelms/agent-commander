import SwiftUI

// ATOMIC LEVEL: Template and organisms for composers hosted outside the tray (DESIGN.md, "Hosts").
//   MultiplayerHostFrame          TEMPLATE: banner, composer and footer; scrolls or takes its height
//   MultiplayerConsultHost        one prompt to a friend's worker, and its reply
//   MultiplayerHandoffHost        a task for a friend's agent
//   MultiplayerReviewRequestHost  a review request
//   MultiplayerWatchHost          a friend's worker's output, and a suggestion for it
//   MultiplayerAddFriendHost      exact-handle lookup, then a friend request
//   MultiplayerInviteHost         an invite link for a server
//   MultiplayerMembershipHost     who may join a relay, for its admin
//   MultiplayerAddServerHost      check a server, then save or join it
// Each draws the tray's own composer component and adds nothing to its styling. Each keeps its
// draft, its reply and its refusal in its own state, names its target in every call, and never
// reads or moves the tray's route. The view that presents a host closes it from `onCancel`, and
// from `onFinish` when the result is done; a refusal stays on the host so the person can fix it.
// The grant sheet's host is in MultiplayerGrantHost.swift.

/// A hosted composer's frame: a banner for a refusal or a confirmation, the composer, and the
/// tray's footer. With `scrolls` it fills the height it is given and scrolls the composer. Without,
/// it takes the composer's full height, for a view that already scrolls.
struct MultiplayerHostFrame<Content: View, Actions: View>: View {
    var scrolls = true
    @Binding var refusal: String?
    /// A confirmation that belongs to the host, such as "Invite link copied."
    var confirmation: Binding<String?> = .constant(nil)
    var note: String? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            if scrolls {
                ScrollView { page }
                    .focusSection()
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                page
            }
            footer
        }
        .background(MultiplayerTheme.panelFill)
        .onChange(of: refusal) { _, refusal in
            if let refusal { AccessibilityNotification.Announcement(refusal).post() }
        }
        .onChange(of: confirmation.wrappedValue) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// The tray's footer. A host adds Cancel to the tray's own actions, so where the note and the
    /// actions don't fit one row at full size, the note takes a footer row of its own above them.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            MultiplayerTrayFooter(note: note) { buttons }
            VStack(spacing: 0) {
                if note != nil { MultiplayerTrayFooter(note: note) { EmptyView() } }
                MultiplayerTrayFooter { buttons }
            }
        }
    }

    /// The actions at their full size: a label is never cut short to make room for the note.
    private var buttons: some View {
        HStack(spacing: Space.s) { actions }.fixedSize()
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = refusal {
                MultiplayerBand {
                    MultiplayerBanner(kind: .failure, message: message, onDismiss: { refusal = nil })
                }
            } else if let message = confirmation.wrappedValue {
                MultiplayerBand {
                    MultiplayerBanner(kind: .success, message: message, onDismiss: { confirmation.wrappedValue = nil })
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The line a share composer shows in place of its form while its server can't be reached.
private struct MultiplayerHostOffline: View {
    let serverName: String

    var body: some View {
        MultiplayerBand {
            Text("\(serverName) is offline. Sharing resumes when it’s back.")
                .font(MultiplayerTheme.sub)
                .foregroundStyle(.inkSecondary)
        }
    }
}

extension MultiplayerModel {
    /// A server's name for a sentence, and whether its session can be used now.
    fileprivate func hostServer(_ id: String) -> (name: String, isOnline: Bool) {
        (server(id)?.displayName ?? "This server", session(id)?.isOnline == true)
    }
}

extension MultiplayerLoad {
    /// A value-bearing answer as the result a host reports. `id` names what the answer was about.
    func result(id: String, server: String, message: String? = nil) -> MultiplayerActionResult {
        if let failure { return .failed(id: id, server: server, reason: failure) }
        return .done(id: id, server: server, message: message)
    }
}

// MARK: - Consult

/// Consult for a view outside the tray: one prompt to a friend's worker, with files as context.
/// The host stays open to show the reply. `onFinish` is called for each prompt sent, with the
/// reply's request as its ID.
struct MultiplayerConsultHost: View {
    let model: MultiplayerModel
    let server: String
    let resource: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    /// Opens the thread of the reply shown. The presenting view owns where a thread is read.
    let onThread: (MultiplayerSentRequest) -> Void
    @State private var draft = MultiplayerConsultDraft()
    @State private var reply: MultiplayerSentRequest?
    @State private var attachProblem: String?
    @State private var refusal: String?

    var body: some View {
        let share = model.share
        let place = model.hostServer(server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, note: model.working ?? "Uses one of your granted uses.") {
            if place.isOnline {
                MultiplayerConsultPage(draft: $draft, entry: share.entry(resource, on: server), reply: reply,
                                       attachProblem: attachProblem,
                                       onChoose: { attach(MultiplayerFilePanel.chooseFiles()) },
                                       onDrop: { attach($0) },
                                       onDetach: { item in
                                           draft.context.removeAll { $0.name == item.name }
                                           attachProblem = nil
                                       },
                                       onThread: onThread)
            } else {
                MultiplayerHostOffline(serverName: place.name)
            }
        } actions: {
            Button(reply == nil ? "Cancel" : "Close", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Send prompt") { send() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isBusy || !draft.canSend || !place.isOnline)
                .help("Send (⌘Return)")
        }
    }

    private func attach(_ urls: [URL]) {
        (draft.context, attachProblem) = MultiplayerShareModel.attaching(urls, to: draft.context)
    }

    private func send() {
        refusal = nil
        let sent = draft
        Task {
            let answer = await model.sendConsult(sent, to: resource, on: server)
            if let value = answer.value {
                reply = value
                draft.prompt = ""
            }
            refusal = answer.failure
            onFinish(answer.result(id: answer.value?.request ?? "", server: server))
        }
    }
}

// MARK: - Hand off

/// Hand off for a view outside the tray. A hand-off that went through reports the new hand-off's
/// request as the result's ID, so the presenting view can show it.
struct MultiplayerHandoffHost: View {
    let model: MultiplayerModel
    let server: String
    let resource: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var draft = MultiplayerHandoffDraft()
    @State private var attachProblem: String?
    @State private var refusal: String?

    var body: some View {
        let place = model.hostServer(server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, note: model.working ?? "Uses one of your granted uses.") {
            if place.isOnline {
                MultiplayerHandoffComposer(draft: $draft, entry: model.share.entry(resource, on: server),
                                           attachProblem: attachProblem,
                                           onChoose: { attach(MultiplayerFilePanel.chooseFiles()) },
                                           onDrop: { attach($0) },
                                           onDetach: { item in
                                               draft.context.removeAll { $0.name == item.name }
                                               attachProblem = nil
                                           })
            } else {
                MultiplayerHostOffline(serverName: place.name)
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Hand off") { send() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isBusy || !draft.canSend || !place.isOnline)
                .help("Hand off (⌘Return)")
        }
    }

    private func attach(_ urls: [URL]) {
        (draft.context, attachProblem) = MultiplayerShareModel.attaching(urls, to: draft.context)
    }

    private func send() {
        refusal = nil
        let sent = draft
        Task {
            let result = await model.sendHandoff(sent, to: resource, on: server)
            if result.isDone { draft = MultiplayerHandoffDraft() }
            refusal = result.reason
            onFinish(result)
        }
    }
}

// MARK: - Request review

/// Request review for a view outside the tray. A request that went through reports the new
/// review's request as the result's ID.
struct MultiplayerReviewRequestHost: View {
    let model: MultiplayerModel
    let server: String
    let resource: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var draft = MultiplayerReviewDraft()
    @State private var attachProblem: String?
    @State private var refusal: String?

    var body: some View {
        let place = model.hostServer(server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, note: model.working ?? "Uses one of your granted uses.") {
            if place.isOnline {
                MultiplayerReviewComposer(draft: $draft, entry: model.share.entry(resource, on: server),
                                          attachProblem: attachProblem,
                                          onChoose: { attach(MultiplayerFilePanel.chooseFiles()) },
                                          onDrop: { attach($0) },
                                          onDetach: {
                                              draft.diff = nil
                                              attachProblem = nil
                                          })
            } else {
                MultiplayerHostOffline(serverName: place.name)
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Request review") { send() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isBusy || !draft.canSend || !place.isOnline)
                .help("Request review (⌘Return)")
        }
    }

    private func attach(_ urls: [URL]) {
        let read = MultiplayerLiveModel.diff(from: urls)
        attachProblem = read.problem
        if let diff = read.diff { draft.diff = diff }
    }

    private func send() {
        refusal = nil
        let sent = draft
        Task {
            let result = await model.sendReview(sent, to: resource, on: server)
            if result.isDone { draft = MultiplayerReviewDraft() }
            refusal = result.reason
            onFinish(result)
        }
    }
}

// MARK: - Watch

/// Watch for a view outside the tray: a friend's worker's output, read while the host is on
/// screen, and a suggestion for it where the grant allows one. The stream is the host's own and
/// runs beside the tray's. `onFinish` is called for each suggestion sent.
struct MultiplayerWatchHost: View {
    let model: MultiplayerModel
    let server: String
    let resource: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var stream: MultiplayerWatchStream?
    @State private var suggestion = ""
    @State private var reply: MultiplayerSentRequest?
    @State private var refusal: String?

    var body: some View {
        let place = model.hostServer(server)
        let entry = model.share.entry(resource, on: server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal,
                             note: model.working ?? "Read-only. Reads while this is open.") {
            if place.isOnline {
                MultiplayerWatchView(watch: stream?.state ?? MultiplayerWatchState(server: server, resource: resource),
                                     entry: entry, serverName: place.name, color: MultiplayerTheme.swatch(for: server),
                                     interval: 2, suggestion: $suggestion, reply: reply,
                                     onRetry: { stream?.retry() })
            } else {
                MultiplayerHostOffline(serverName: place.name)
            }
        } actions: {
            Button("Close", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            if entry?.canSuggest == true {
                Button("Send suggestion") { send() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isBusy || !MultiplayerLiveModel.canSend(suggestion: suggestion) || !place.isOnline)
                    .help("Send the suggestion to the owner (⌘Return)")
            }
        }
        .task(id: "\(server)/\(resource)") {
            stream?.end()
            let next = model.share.live.stream(resource, on: server)
            stream = next
            next.begin()
        }
        .onDisappear { stream?.end() }
    }

    private func send() {
        refusal = nil
        let text = suggestion
        Task {
            let answer = await model.sendSuggestion(text, to: resource, on: server)
            if let value = answer.value {
                reply = value
                suggestion = ""
            }
            refusal = answer.failure
            onFinish(answer.result(id: answer.value?.request ?? "", server: server, message: model.notice))
        }
    }
}

// MARK: - Add friend

/// Add a friend for a view outside the tray: an exact-handle lookup, then an explicit request.
/// The lookup and the field are the host's own, so the server's page in the tray is left alone.
struct MultiplayerAddFriendHost: View {
    let model: MultiplayerModel
    let server: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var handle = ""
    @State private var lookup = MultiplayerLookup.idle
    @State private var refusal: String?

    private var trimmed: String { handle.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let place = model.hostServer(server)
        let session = model.session(server)
        let status = place.isOnline ? session?.status : nil
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal,
                             note: place.isOnline ? "On \(place.name)" : "Sign in to \(place.name) to add a friend.") {
            MultiplayerAddFriendEditor(handle: $handle,
                                       lookup: lookup.handle == trimmed ? lookup : .idle,
                                       friends: Set((status?.friends ?? []).map(\.handle)),
                                       requesters: Set((status?.incoming ?? []).map(\.handle)),
                                       pending: Set((status?.outgoing ?? []).map(\.handle)),
                                       canLookUp: canLookUp(online: place.isOnline),
                                       isBusy: session?.isBusy ?? true,
                                       onLookUp: { lookUp() },
                                       onSend: { send() },
                                       onBack: onCancel)
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private func canLookUp(online: Bool) -> Bool {
        if case .searching = lookup, lookup.handle == trimmed { return false }
        return online && MultiplayerInput.handleProblem(trimmed) == nil
    }

    private func lookUp() {
        let asked = trimmed
        guard let session = model.session(server) else { return }
        lookup = .searching(asked)
        Task {
            let answer = await session.lookUp(asked)
            // A newer lookup, or an edited field, owns the result now.
            guard lookup == .searching(asked) else { return }
            switch answer {
            case .loaded(let found): lookup = .found(found)
            case .failed(let message): lookup = .failed(handle: asked, message: message)
            case .loading: lookup = .idle
            }
        }
    }

    private func send() {
        guard case .found(let found) = lookup, found == trimmed else { return }
        refusal = nil
        Task {
            let result = await model.sendFriendRequest(to: found, on: server)
            if result.isDone {
                handle = ""
                lookup = .idle
            }
            refusal = result.reason
            onFinish(result)
        }
    }
}

// MARK: - Invite

/// Invite for a view outside the tray. The host stays open to show the link. `onFinish` is called
/// for each link made, with the link's code as its ID.
struct MultiplayerInviteHost: View {
    let model: MultiplayerModel
    let server: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var draft = MultiplayerInviteDraft()
    @State private var invite: MultiplayerInvite?
    @State private var refusal: String?
    @State private var confirmation: String?

    var body: some View {
        let place = model.hostServer(server)
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, confirmation: $confirmation,
                             note: model.working ?? (invite == nil ? nil : "Each new link has its own code.")) {
            MultiplayerInvitePage(draft: $draft, invite: invite, serverName: place.name,
                                  canInvite: model.canInvite(server), now: model.currentDate(),
                                  onCopy: { link in
                                      NSPasteboard.general.clearContents()
                                      NSPasteboard.general.setString(link, forType: .string)
                                      confirmation = "Invite link copied."
                                  })
        } actions: {
            Button(invite == nil ? "Cancel" : "Close", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(invite == nil ? "Create invite link" : "Create another") { create() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: invite == nil ? .primary : .standard))
                .disabled(model.isBusy || !model.canInvite(server))
        }
        .task(id: server) { model.refreshMe(server) }
    }

    private func create() {
        refusal = nil
        confirmation = nil
        let asked = draft
        Task {
            let answer = await model.createInvite(asked, on: server)
            if let value = answer.value { invite = value }
            refusal = answer.failure
            onFinish(answer.result(id: answer.value?.code ?? "", server: server))
        }
    }
}

// MARK: - Membership

/// Membership for a view outside the tray: who may join a relay, for its admin. It reads the
/// settings when it appears and keeps them itself. A save that went through stays on the host with
/// what the relay now holds.
struct MultiplayerMembershipHost: View {
    let model: MultiplayerModel
    let server: String
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var state = MultiplayerMembershipState.loading
    @State private var draft = MultiplayerMembershipDraft()
    @State private var refusal: String?
    @State private var confirmation: String?

    private var canSave: Bool {
        guard !model.isBusy, let current = state.membership, draft.problem == nil else { return false }
        return draft.differs(from: current)
    }

    var body: some View {
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, confirmation: $confirmation,
                             note: model.working ?? (state.membership == nil ? nil : "Changes apply to everyone on this relay.")) {
            MultiplayerMembershipPage(state: state, draft: $draft, onRetry: { Task { await load() } })
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save membership") { save() }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(!canSave)
        }
        .task(id: server) { await load() }
    }

    private func load() async {
        state = .loading
        switch await model.loadMembership(on: server) {
        case .loaded(let current):
            state = .loaded(current)
            draft = MultiplayerMembershipDraft(current)
        case .failed(let message):
            state = .failed(message)
        case .loading:
            break
        }
    }

    private func save() {
        refusal = nil
        confirmation = nil
        let asked = draft
        Task {
            let answer = await model.saveMembership(asked, on: server)
            if let saved = answer.value {
                state = .loaded(saved)
                draft = MultiplayerMembershipDraft(saved)
                confirmation = "Membership saved."
            }
            refusal = answer.failure
            onFinish(answer.result(id: server, server: server, message: "Membership saved."))
        }
    }
}

// MARK: - Add server

/// Add server for a view outside the tray: check an address, then save it, or join it from an
/// invite. The draft and the check are the host's own. A save that went through reports the saved
/// server's ID. `onOpenExisting` is given the saved server an address already belongs to.
struct MultiplayerAddServerHost: View {
    let model: MultiplayerModel
    /// An `agentcommander://join` link to open the form from. The check then starts at once.
    var invite: MultiplayerInviteLink? = nil
    var scrolls = true
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    let onOpenExisting: (MultiplayerServerSummary) -> Void
    @State private var draft = MultiplayerServerDraft()
    @State private var probe = MultiplayerProbeState.idle
    @State private var refusal: String?

    private var form: MultiplayerServerForm { MultiplayerServerForm(draft: draft, probe: probe, servers: model.servers) }

    private var canProbe: Bool {
        model.client != nil && !model.isBusy && !probe.isRunning
            && MultiplayerServerAddress.problem(draft.trimmedAddress) == nil
    }

    var body: some View {
        let form = form
        MultiplayerHostFrame(scrolls: scrolls, refusal: $refusal, note: model.working ?? form.hint) {
            MultiplayerAddServerForm(draft: $draft, addressProblem: form.addressProblem, probe: form.currentProbe,
                                     canProbe: canProbe, invite: form.activeInvite, inviteProblem: form.invitePinProblem,
                                     existing: form.existing,
                                     onProbe: { check() },
                                     onOpenExisting: { form.existing.map(onOpenExisting) })
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(form.currentProbe == .idle ? "Check server" : "Check again") { check() }
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(!canProbe)
            // A saved address is opened from its notice at the top of the form, not saved again.
            if form.existing == nil {
                Button(form.activeInvite == nil ? "Save server" : "Join server") { save() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(form.canSave && !model.isBusy ? KeyboardShortcut.defaultAction : nil)
                    .disabled(model.isBusy || !form.canSave)
            }
        }
        .task {
            guard let invite, draft.address.isEmpty else { return }
            draft = MultiplayerServerDraft(address: invite.server, invite: invite)
            check()
        }
    }

    private func check() {
        guard canProbe else { return }
        let address = draft.trimmedAddress
        draft.pinConfirmed = false
        probe = .running(address: address)
        Task {
            let answer = await model.checkServer(at: address)
            // A newer check owns the result now.
            guard probe == .running(address: address) else { return }
            switch answer {
            case .loaded(let result): probe = .finished(result, address: address)
            case .failed(let message): probe = .failed(address: address, message: message)
            case .loading: probe = .idle
            }
        }
    }

    private func save() {
        guard let checked = form.currentProbe.probe else { return }
        refusal = nil
        let asked = draft
        Task {
            let result = await model.saveServer(asked, checked: checked)
            if result.isDone {
                draft = MultiplayerServerDraft()
                probe = .idle
            }
            refusal = result.reason
            onFinish(result)
        }
    }
}
