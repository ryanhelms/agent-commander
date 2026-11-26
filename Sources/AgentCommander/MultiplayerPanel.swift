import SwiftUI

// ATOMIC LEVEL: Organisms and templates for one server's session, the tray's shell and the review
// stage. `MultiplayerPanel` (MultiplayerTray.swift) is the menu bar window and, with AGENT_COMMANDER_NETWORK_PANEL=1,
// the content of the cockpit window for review. Both read one live MultiplayerModel; nothing here
// supplies a status of its own.

enum MultiplayerLaunch {
    static let panelVariable = "AGENT_COMMANDER_NETWORK_PANEL"
    /// Shows the live network panel in the cockpit window instead of the cockpit.
    static let showsPanelInWindow = ProcessInfo.processInfo.environment[panelVariable] == "1"
}

// MARK: - Organisms

/// Everything before the developer is online: check, sign in, wait for the browser, claim a handle,
/// or recover from an unavailable helper. Each state has one clear next step.
struct MultiplayerAccountCard: View {
    let presence: MultiplayerPresence
    let hasStatus: Bool
    let isBusy: Bool
    let canRetry: Bool
    @Binding var handleDraft: String
    let handleProblem: String?
    let canClaim: Bool
    let onCheck: () -> Void
    let onSignIn: () -> Void
    let onClaim: () -> Void
    @FocusState private var handleFocused: Bool

    init(presence: MultiplayerPresence, hasStatus: Bool, isBusy: Bool, canRetry: Bool,
         handleDraft: Binding<String>, handleProblem: String?, canClaim: Bool,
         onCheck: @escaping () -> Void, onSignIn: @escaping () -> Void, onClaim: @escaping () -> Void) {
        self.presence = presence
        self.hasStatus = hasStatus
        self.isBusy = isBusy
        self.canRetry = canRetry
        self._handleDraft = handleDraft
        self.handleProblem = handleProblem
        self.canClaim = canClaim
        self.onCheck = onCheck
        self.onSignIn = onSignIn
        self.onClaim = onClaim
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                IconTile(symbol: symbol, tone: presence.tone, size: MultiplayerLayout.rowIcon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var controls: some View {
        switch presence {
        case .checking:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Asking the network helper…").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
            }
            .accessibilityElement(children: .combine)
        case .offline:
            trailingButton(hasStatus ? "Check again" : "Check status", prominent: !hasStatus, action: onCheck)
        case .signedOut, .signInIncomplete:
            trailingButton("Sign in with browser", prominent: true, action: onSignIn)
        case .serviceError:
            trailingButton("Refresh", prominent: false, action: onCheck)
        case .waitingForBrowser:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small).accessibilityLabel("Waiting for sign-in")
                Spacer(minLength: 0)
                Button("Open browser again", action: onSignIn)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(isBusy)
            }
        case .needsHandle:
            MultiplayerField(label: "Handle", hint: "Friends add you by typing this exactly.", problem: handleProblem) {
                HStack(spacing: Space.s) {
                    MultiplayerTextField(label: "Handle", placeholder: "Your handle", text: $handleDraft,
                                         monospaced: true, isFocused: handleFocused)
                        .focused($handleFocused)
                        .onSubmit { if canClaim { onClaim() } }
                    Button("Claim", action: onClaim)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary, large: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canClaim)
                }
            }
            .onAppear { handleFocused = true }
        case .unavailable:
            if canRetry { trailingButton("Try again", prominent: false, action: onCheck) }
        case .online:
            EmptyView()
        }
    }

    private func trailingButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button(title, action: action)
                .buttonStyle(MultiplayerTrayButtonStyle(role: prominent ? .primary : .standard))
                .keyboardShortcut(prominent ? KeyboardShortcut.defaultAction : nil)
                .disabled(isBusy)
        }
    }

    private var symbol: String {
        switch presence {
        case .offline, .checking: "wifi.slash"
        case .signedOut: "person.crop.circle"
        case .waitingForBrowser: "safari"
        case .signInIncomplete: "person.crop.circle.badge.exclamationmark"
        case .needsHandle: "at"
        case .serviceError: "exclamationmark.icloud"
        case .unavailable: "exclamationmark.triangle"
        case .online: "person.2"
        }
    }

    private var title: String {
        switch presence {
        case .offline: hasStatus ? "The network is offline" : "Not connected"
        case .checking: "Checking your network status"
        case .signedOut: "Sign in to the network"
        case .waitingForBrowser: "Finish signing in in your browser"
        case .signInIncomplete: "Sign-in didn’t finish"
        case .needsHandle: "Choose your handle"
        case .serviceError: "The network service reported a problem"
        case .unavailable: "Can’t reach the network helper"
        case .online: "Online"
        }
    }

    private var message: String {
        switch presence {
        case .offline:
            hasStatus
                ? "The helper reports the network offline. Your friends and grants are kept; sharing resumes when it’s back."
                : "Commander checks the network only while this panel is open."
        case .checking: "This takes a moment."
        case .signedOut: "Your browser opens to sign in. You’ll show as online once the network confirms it."
        case .waitingForBrowser: "This panel checks every few seconds and updates when sign-in is complete."
        case .signInIncomplete(let detail):
            detail ?? "The browser sign-in ended without signing you in. Start it again when you’re ready."
        case .needsHandle: "You’re signed in. Claim a handle so friends can find you."
        case .serviceError(let message): message
        case .unavailable(let message): message
        case .online: ""
        }
    }
}

/// The online home: requests, friends, your resources, access you gave, and what friends share.
struct MultiplayerHomeLists: View {
    let status: MultiplayerStatus
    let isBusy: Bool
    let resourceName: (String) -> String
    let onAccept: (MultiplayerIncoming) -> Void
    let onAddFriend: () -> Void
    let onAddResource: () -> Void
    let onShare: (_ handle: String?, _ resourceID: String?) -> Void
    let onRevoke: (MultiplayerGrant) -> Void
    let onSetCredential: (_ resourceID: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !status.incoming.isEmpty {
                MultiplayerSection(title: "Friend requests", count: status.incoming.count) {
                    MultiplayerRows(items: status.incoming, empty: "") { request in
                        MultiplayerRow(symbol: "person.badge.plus", tone: .attention, title: request.handle,
                                       monospacedTitle: true, caption: "Wants to be your friend") {
                            Button("Accept") { onAccept(request) }
                                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                                .disabled(isBusy)
                                .accessibilityLabel("Accept friend request from \(request.handle.multiplayerDisplay)")
                        }
                    }
                }
            }

            MultiplayerSection(title: "Friends", count: status.friends.count,
                               action: MultiplayerSectionAction(title: "Add friend", symbol: "plus", isEnabled: !isBusy,
                                                                help: "Look up a friend by exact handle", perform: onAddFriend)) {
                MultiplayerRows(items: status.friends, empty: "Add a friend by their exact handle to start sharing.") { friend in
                    MultiplayerRow(symbol: "person", tone: presenceTone(friend), title: friend.handle, monospacedTitle: true,
                                   caption: [friend.presenceTitle, grantSummary(for: friend.handle)]
                                       .compactMap { $0 }.joined(separator: " · ")) {
                        Button("Share") { onShare(friend.handle, nil) }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(isBusy || status.resources.isEmpty)
                            .help(status.resources.isEmpty ? "Add a resource first" : "Share a resource with \(friend.handle.multiplayerDisplay)")
                            .accessibilityLabel("Share with \(friend.handle.multiplayerDisplay)")
                    }
                }
            }

            if !status.outgoing.isEmpty {
                MultiplayerSection(title: "Requests you’ve sent", count: status.outgoing.count) {
                    MultiplayerRows(items: status.outgoing, empty: "") { request in
                        MultiplayerRow(symbol: "paperplane", tone: presenceTone(request), title: request.handle,
                                       monospacedTitle: true,
                                       caption: ["Waiting for them to accept", request.presenceTitle]
                                           .compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }

            MultiplayerSection(title: "Your resources", count: status.resources.count,
                               action: MultiplayerSectionAction(title: "Add", symbol: "plus", isEnabled: !isBusy,
                                                                help: "Add a repository or agent", perform: onAddResource)) {
                MultiplayerRows(items: status.resources, empty: "Add a repository checkout or an agent you might share.") { resource in
                    MultiplayerRow(symbol: MultiplayerResourceKind.symbol(for: resource.kind), title: resource.name,
                                   caption: resourceSummary(resource)) {
                        if MultiplayerSessionModel.takesCredential(resource) {
                            SymbolButton(symbol: "key", label: "Set GitHub token for \(resource.name.multiplayerDisplay)") {
                                onSetCredential(resource.id)
                            }
                            .foregroundStyle(isBusy ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(Palette.foreground))
                            .disabled(isBusy)
                        }
                        Button("Share") { onShare(nil, resource.id) }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(isBusy || status.friends.isEmpty || resource.actions.isEmpty)
                            .help(status.friends.isEmpty ? "Add a friend first" : "Share \(resource.name.multiplayerDisplay)")
                            .accessibilityLabel("Share \(resource.name.multiplayerDisplay)")
                    }
                }
            }

            MultiplayerSection(title: "Access you’ve given", count: status.grants.count) {
                MultiplayerRows(items: status.grants, empty: "You haven’t given anyone access.") { grant in
                    MultiplayerRow(symbol: "key", tone: .attention, title: grant.handle, monospacedTitle: true,
                                   caption: grantCaption(grant)) {
                        Button("Revoke") { onRevoke(grant) }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(isBusy)
                            .accessibilityLabel("Revoke \(grant.handle.multiplayerDisplay)’s access")
                    }
                }
            }

            MultiplayerSection(title: "Shared with you", count: status.shared.count) {
                MultiplayerRows(items: status.shared, empty: "Nothing has been shared with you yet.") { shared in
                    MultiplayerRow(symbol: MultiplayerResourceKind.symbol(for: shared.kind), tone: .working,
                                   title: shared.name, caption: sharedSummary(shared))
                }
            }
        }
    }

    /// Green only when the service says online; unknown presence keeps the neutral identity tone.
    private func presenceTone(_ person: MultiplayerFriend) -> Tone {
        switch person.online {
        case true?: .working
        case false?: .neutral
        case nil: .focus
        }
    }

    private func grantSummary(for handle: String) -> String {
        let count = status.grants.filter { $0.handle == handle }.count
        switch count {
        case 0: return "No access shared"
        case 1: return "1 grant from you"
        default: return "\(count) grants from you"
        }
    }

    /// Action and resource, then the helper's limits only when it reported them.
    private func grantCaption(_ grant: MultiplayerGrant) -> String {
        var parts = [MultiplayerCapability.title(grant.capability), resourceName(grant.resource).multiplayerDisplay]
        if let uses = grant.maxUses { parts.append("Up to \(MultiplayerGrantLimits.usesTitle(uses))") }
        if let expiresAt = grant.expiresAt { parts.append("Expires \(MultiplayerTime.display(expiresAt))") }
        return parts.joined(separator: " · ")
    }

    private func resourceSummary(_ resource: MultiplayerResource) -> String {
        let kind = MultiplayerResourceKind.title(for: resource.kind).multiplayerDisplay
        switch resource.actions.count {
        case 0: return "\(kind) · No actions available"
        case 1: return "\(kind) · 1 action"
        default: return "\(kind) · \(resource.actions.count) actions"
        }
    }

    private func sharedSummary(_ shared: MultiplayerShared) -> String {
        let actions = shared.actions.map(MultiplayerCapability.title).joined(separator: ", ")
        let owner = "From \(shared.owner.multiplayerDisplay)"
        return actions.isEmpty ? owner : "\(owner) · \(actions.multiplayerDisplay)"
    }
}

// MARK: - Template

/// Header, scrolling bands and footer at the tray's fixed width. The body grows with its content
/// up to a height that keeps the panel on the main display, then scrolls. Bands pad themselves.
struct MultiplayerPanelShell<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @State private var contentHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(MultiplayerTheme.hair).frame(height: 1)
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 120), MultiplayerLayout.maxBodyHeight))
            footer
        }
        .frame(width: MultiplayerLayout.width)
        .background(MultiplayerTheme.panel)
    }
}

/// A title and a sentence above one editor's fields and actions, as one band. The tray's header
/// carries Back.
struct MultiplayerEditorTemplate<Content: View>: View {
    let title: String
    var intro: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        MultiplayerBand {
          VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let intro {
                    Text(intro)
                        .font(.system(size: 12))
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Trailing actions at the foot of an editor.
struct MultiplayerEditorActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Space.s) {
            Spacer(minLength: 0)
            content
        }
        .padding(.top, Space.xs)
    }
}

// MARK: - Editors

/// Explicit exact-handle lookup, then an explicit request. No search, suggestion or contact import.
struct MultiplayerAddFriendEditor: View {
    @Binding var handle: String
    let lookup: MultiplayerLookup
    let friends: Set<String>
    let requesters: Set<String>
    let pending: Set<String>
    let canLookUp: Bool
    let isBusy: Bool
    let onLookUp: () -> Void
    let onSend: () -> Void
    let onBack: () -> Void
    @FocusState private var fieldFocused: Bool

    init(handle: Binding<String>, lookup: MultiplayerLookup, friends: Set<String>, requesters: Set<String>,
         pending: Set<String>, canLookUp: Bool, isBusy: Bool, onLookUp: @escaping () -> Void,
         onSend: @escaping () -> Void, onBack: @escaping () -> Void) {
        self._handle = handle
        self.lookup = lookup
        self.friends = friends
        self.requesters = requesters
        self.pending = pending
        self.canLookUp = canLookUp
        self.isBusy = isBusy
        self.onLookUp = onLookUp
        self.onSend = onSend
        self.onBack = onBack
    }

    var body: some View {
        MultiplayerEditorTemplate(title: "Add a friend",
                                  intro: "Look up one person by their exact handle. Nothing is sent until you choose Send request.") {
            MultiplayerField(label: "Handle", hint: "Commander looks up the handle exactly as typed.") {
                HStack(spacing: Space.s) {
                    MultiplayerTextField(label: "Friend’s handle", placeholder: "Exact handle", text: $handle,
                                         monospaced: true, isFocused: fieldFocused)
                        .focused($fieldFocused)
                        .onSubmit { if canLookUp { onLookUp() } }
                    Button("Look up", action: onLookUp)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: isFound ? .standard : .primary, large: true))
                        .keyboardShortcut(isFound ? nil : KeyboardShortcut.defaultAction)
                        .disabled(!canLookUp)
                }
            }
            result
        }
        .onAppear { fieldFocused = true }
    }

    private var isFound: Bool {
        if case .found = lookup { return true }
        return false
    }

    @ViewBuilder private var result: some View {
        switch lookup {
        case .idle:
            EmptyView()
        case .searching(let handle):
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Looking up \(handle.multiplayerDisplay)…").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
            }
            .accessibilityElement(children: .combine)
        case .found(let handle):
            let relation = friends.contains(handle) ? "Already your friend."
                : requesters.contains(handle) ? "They’ve already asked to be your friend. Accept it from the main list."
                : pending.contains(handle) ? "Your request is waiting for them to accept."
                : "Found on the network."
            let canSend = !friends.contains(handle) && !requesters.contains(handle) && !pending.contains(handle)
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerRow(symbol: "person.crop.circle.badge.checkmark", tone: .working, title: handle,
                               monospacedTitle: true, caption: relation)
                if canSend {
                    MultiplayerEditorActions {
                        Button("Send request", action: onSend)
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                            .keyboardShortcut(.defaultAction)
                            .disabled(isBusy)
                            .accessibilityLabel("Send friend request to \(handle.multiplayerDisplay)")
                    }
                }
            }
        case .failed(_, let message):
            MultiplayerBanner(kind: .failure, message: message)
        }
    }
}

/// Names a local repository checkout or agent run. Adding does not share it.
struct MultiplayerAddResourceEditor: View {
    @Binding var draft: MultiplayerResourceDraft
    let nameProblem: String?
    let targetProblem: String?
    let canAdd: Bool
    let onAdd: () -> Void
    let onBack: () -> Void
    @FocusState private var focus: Field?

    enum Field: Hashable { case name, target }

    init(draft: Binding<MultiplayerResourceDraft>, nameProblem: String?, targetProblem: String?, canAdd: Bool,
         onAdd: @escaping () -> Void, onBack: @escaping () -> Void) {
        self._draft = draft
        self.nameProblem = nameProblem
        self.targetProblem = targetProblem
        self.canAdd = canAdd
        self.onAdd = onAdd
        self.onBack = onBack
    }

    var body: some View {
        MultiplayerEditorTemplate(title: "Add a resource",
                                  intro: "Adding a resource doesn’t share it. You choose who can use it afterwards.") {
            Picker("Kind", selection: $draft.kind) {
                ForEach(MultiplayerResourceKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Resource kind")

            MultiplayerField(label: "Name", hint: "Friends see this name.", problem: nameProblem) {
                MultiplayerTextField(label: "Name", placeholder: "Name", text: $draft.name, isFocused: focus == .name)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .target }
            }

            MultiplayerField(label: draft.kind.targetLabel, hint: draft.kind.targetHint, problem: targetProblem) {
                MultiplayerTextField(label: draft.kind.targetLabel, placeholder: draft.kind.targetPlaceholder,
                                     text: $draft.target, monospaced: true, isFocused: focus == .target)
                    .focused($focus, equals: .target)
                    .onSubmit { if canAdd { onAdd() } }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard draft.kind == .repo, let url = urls.first, url.isFileURL else { return false }
                        draft.target = url.path(percentEncoded: false)
                        return true
                    }
            }

            MultiplayerEditorActions {
                Button("Add resource", action: onAdd)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .onAppear { focus = .name }
    }
}

/// One friend, one resource, one service-listed action and its limits, then a review step.
struct MultiplayerGrantEditor: View {
    @Binding var draft: MultiplayerGrantDraft
    let friends: [MultiplayerFriend]
    let resources: [MultiplayerResource]
    let selectedResource: MultiplayerResource?
    let usesProblem: String?
    let expiryProblem: String?
    let customExpiryRange: ClosedRange<Date>
    let note: String?
    let canContinue: Bool
    let onResourceChange: () -> Void
    let onExpiryChange: (_ previous: MultiplayerGrantExpiry) -> Void
    let onContinue: () -> Void
    let onBack: () -> Void

    var body: some View {
        MultiplayerEditorTemplate(title: "Share a resource",
                                  intro: "Give one friend one action on one of your resources. You’ll review it before anything is sent.") {
            if let note {
                MultiplayerBanner(kind: .attention, message: note)
            }

            MultiplayerField(label: "Friend") {
                Picker("Friend", selection: $draft.handle) {
                    Text("Choose a friend").tag("")
                    ForEach(friends) { friend in
                        Text(friend.handle.multiplayerDisplay).tag(friend.handle)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Friend")
            }

            MultiplayerField(label: "Resource") {
                Picker("Resource", selection: $draft.resourceID) {
                    Text("Choose a resource").tag("")
                    ForEach(resources) { resource in
                        Text("\(resource.name.multiplayerDisplay) — \(MultiplayerResourceKind.title(for: resource.kind))")
                            .tag(resource.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Resource")
                .onChange(of: draft.resourceID) { onResourceChange() }
            }

            MultiplayerField(label: "Action",
                             hint: selectedResource == nil ? "Choose a resource to see the actions it allows." : "Actions come from the network service.") {
                Picker("Action", selection: $draft.capability) {
                    Text("Choose an action").tag("")
                    ForEach(selectedResource?.actions ?? [], id: \.self) { action in
                        Text(MultiplayerCapability.title(action)).tag(action)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(selectedResource == nil)
                .accessibilityLabel("Action")
            }

            if let resource = selectedResource, resource.actions.contains(draft.capability) {
                MultiplayerCapabilityNote(capability: draft.capability, resourceName: resource.name)
            }

            MultiplayerGrantLimitsField(draft: $draft, usesProblem: usesProblem, expiryProblem: expiryProblem,
                                        customExpiryRange: customExpiryRange, canContinue: canContinue,
                                        onExpiryChange: onExpiryChange, onContinue: onContinue)

            MultiplayerEditorActions {
                Button("Review", action: onContinue)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
    }
}

/// Maximum uses and expiry on one compact line, with a native date picker for a custom time.
/// Access ends at whichever limit is reached first.
struct MultiplayerGrantLimitsField: View {
    @Binding var draft: MultiplayerGrantDraft
    let usesProblem: String?
    let expiryProblem: String?
    let customExpiryRange: ClosedRange<Date>
    let canContinue: Bool
    let onExpiryChange: (_ previous: MultiplayerGrantExpiry) -> Void
    let onContinue: () -> Void
    @FocusState private var usesFocused: Bool

    var body: some View {
        MultiplayerField(label: "Limits",
                         hint: "Access ends at whichever limit is reached first.",
                         problem: usesProblem ?? expiryProblem) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    HStack(spacing: 2) {
                        MultiplayerTextField(label: "Maximum uses", placeholder: "\(MultiplayerGrantLimits.defaultUses)",
                                             text: $draft.maxUsesText, monospaced: true, isFocused: usesFocused)
                            .focused($usesFocused)
                            .frame(width: 84)
                            .onSubmit { if canContinue { onContinue() } }
                            .help("1 to 1,000,000")
                        Stepper("Maximum uses", value: usesStep, in: MultiplayerGrantLimits.usesRange)
                            .labelsHidden()
                            .accessibilityLabel("Maximum uses")
                    }
                    Text("uses")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .accessibilityHidden(true)
                    Spacer(minLength: Space.s)
                    Picker("Expires after", selection: $draft.expiry) {
                        ForEach(MultiplayerGrantExpiry.allCases) { expiry in
                            Text(expiry.title).tag(expiry)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Access duration")
                    .onChange(of: draft.expiry) { previous, _ in onExpiryChange(previous) }
                }
                if draft.expiry == .custom {
                    HStack(spacing: Space.s) {
                        Text("Expires at")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .accessibilityHidden(true)
                        DatePicker("Expiry date and time", selection: $draft.customExpiry, in: customExpiryRange,
                                   displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .accessibilityLabel("Expiry date and time")
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// The stepper moves from the typed value, or from the default while the field can't be read.
    private var usesStep: Binding<Int> {
        Binding(
            get: {
                if case .success(let uses) = MultiplayerGrantLimits.parseUses(draft.maxUsesText) { return uses }
                return MultiplayerGrantLimits.defaultUses
            },
            set: { draft.maxUsesText = String($0) }
        )
    }
}

/// The deliberate step before a grant is sent. Shows the reviewed limits that will be sent.
struct MultiplayerGrantConfirmation: View {
    let handle: String
    let resourceName: String
    let kind: String
    let capability: String
    let limits: MultiplayerGrantLimits
    let note: String?
    let isBusy: Bool
    let onConfirm: () -> Void
    let onBack: () -> Void

    var body: some View {
        let expires = MultiplayerTime.display(limits.expiresAt)
        MultiplayerEditorTemplate(title: "Give \(handle.multiplayerDisplay) access?") {
            if let note {
                MultiplayerBanner(kind: .attention, message: note)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerSummaryLine(label: "Friend", value: handle, monospaced: true)
                MultiplayerSummaryLine(label: "Resource",
                                       value: "\(resourceName) — \(MultiplayerResourceKind.title(for: kind))")
                MultiplayerSummaryLine(label: "Action", value: MultiplayerCapability.title(capability))
                MultiplayerSummaryLine(label: "Uses", value: "Up to \(limits.usesTitle)")
                MultiplayerSummaryLine(label: "Expires", value: expires)
                    .help("Sent as \(limits.expiresAtText)")
            }
            MultiplayerCapabilityNote(capability: capability, resourceName: resourceName)
            Text("Access ends after \(limits.usesTitle) or at \(expires), whichever comes first. You can revoke it here at any time.")
                .font(MultiplayerTheme.sub)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            MultiplayerEditorActions {
                Button("Cancel", action: onBack)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                Button("Grant access", action: onConfirm)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
    }
}

/// The deliberate step before a grant is revoked. Return does not revoke; the button must be chosen.
struct MultiplayerRevokeConfirmation: View {
    let grant: MultiplayerGrant
    let resourceName: String
    let isBusy: Bool
    let onConfirm: () -> Void
    let onBack: () -> Void

    var body: some View {
        MultiplayerEditorTemplate(title: "Revoke \(grant.handle.multiplayerDisplay)’s access?") {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerSummaryLine(label: "Friend", value: grant.handle, monospaced: true)
                MultiplayerSummaryLine(label: "Resource", value: resourceName)
                MultiplayerSummaryLine(label: "Action", value: MultiplayerCapability.title(grant.capability))
            }
            Text("Once the network confirms, \(grant.handle.multiplayerDisplay) can no longer \(MultiplayerCapability.title(grant.capability).lowercased()) on \(resourceName.multiplayerDisplay).")
                .font(.system(size: 12))
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            MultiplayerEditorActions {
                Button("Cancel", action: onBack)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                Button("Revoke access", role: .destructive, action: onConfirm)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                    .disabled(isBusy)
            }
        }
    }
}

/// One owned repository's GitHub token. The masked field is the only place the value is drawn,
/// and the model clears it on save, cancel, navigation and panel close.
struct MultiplayerCredentialEditor: View {
    let resourceName: String
    @Bindable var entry: MultiplayerSecretEntry
    let problem: String?
    let canSave: Bool
    let isBusy: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        MultiplayerEditorTemplate(title: "GitHub token for \(resourceName.multiplayerDisplay)",
                                  intro: "Used only for shared issue actions and pushes to this repository.") {
            MultiplayerSummaryLine(label: "Repository", value: resourceName)
            MultiplayerField(label: "Token",
                             hint: "Use a GitHub token restricted to this repository. The network helper stores it in your macOS Keychain; Commander doesn’t keep it.",
                             problem: problem) {
                SecureField("Paste token", text: $entry.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.foreground)
                    .fieldBox(focused: focused, height: MultiplayerLayout.fieldHeight)
                    .focused($focused)
                    .privacySensitive()
                    .onSubmit { if canSave { onSave() } }
                    .accessibilityLabel("GitHub token for \(resourceName.multiplayerDisplay)")
            }
            MultiplayerEditorActions {
                Button("Cancel", action: onCancel)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                Button("Save token", action: onSave)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isBusy)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Server session

/// One server's account, friends, resources and grants: the body of a server's page in the tray.
/// The tray's model opens and closes the session; this only draws it.
struct MultiplayerSessionContent: View {
    @Bindable var model: MultiplayerSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            activity
                .padding(.horizontal, MultiplayerTheme.sectionInset)
                .padding(.top, 10)
            page
        }
        .onChange(of: model.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
        .onChange(of: model.actionFailure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure.message).post() }
        }
        .onChange(of: model.credentialFailure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure.message).post() }
        }
        .onChange(of: model.grantReviewNote) { _, note in
            if let note { AccessibilityNotification.Announcement(note).post() }
        }
    }

    @ViewBuilder private var activity: some View {
        if let running = model.running {
            MultiplayerBanner(kind: .progress, message: running.progress)
        } else if let name = model.savingCredentialFor {
            MultiplayerBanner(kind: .progress, message: "Saving the GitHub token for \(name.multiplayerDisplay)…")
        } else if let failure = model.credentialFailure {
            MultiplayerBanner(kind: .failure, message: failure.message, actionTitle: failure.actionTitle,
                              action: { model.reenterCredential() }, onDismiss: { model.dismissFailure() })
        } else if let failure = model.actionFailure {
            MultiplayerBanner(kind: .failure, message: failure.message, actionTitle: failure.actionTitle,
                              action: { model.retryAction() }, onDismiss: { model.dismissFailure() })
        } else if let notice = model.notice {
            MultiplayerBanner(kind: .success, message: notice, onDismiss: { model.dismissNotice() })
        }
    }

    @ViewBuilder private var page: some View {
        if model.isOnline, let status = model.status {
            switch model.route {
            case .home:
                MultiplayerHomeLists(status: status, isBusy: model.isBusy,
                                     resourceName: { model.resourceName(for: $0) },
                                     onAccept: { model.accept($0) },
                                     onAddFriend: { model.startAddFriend() },
                                     onAddResource: { model.startAddResource() },
                                     onShare: { model.startGrant(handle: $0, resourceID: $1) },
                                     onRevoke: { model.askRevoke($0) },
                                     onSetCredential: { model.startCredential(resourceID: $0) })
            case .addFriend:
                MultiplayerAddFriendEditor(handle: $model.friendDraft, lookup: model.currentLookup,
                                           friends: Set(status.friends.map(\.handle)),
                                           requesters: Set(status.incoming.map(\.handle)),
                                           pending: Set(status.outgoing.map(\.handle)),
                                           canLookUp: model.canLookUp, isBusy: model.isBusy,
                                           onLookUp: { model.lookUpFriend() },
                                           onSend: { model.sendFriendRequest() },
                                           onBack: { model.go(.home) })
            case .addResource:
                MultiplayerAddResourceEditor(draft: $model.resourceDraft,
                                             nameProblem: model.resourceNameProblem,
                                             targetProblem: model.resourceTargetProblem,
                                             canAdd: model.canAddResource,
                                             onAdd: { model.addResource() },
                                             onBack: { model.go(.home) })
            case .grant:
                MultiplayerGrantEditor(draft: $model.grantDraft, friends: status.friends, resources: status.resources,
                                       selectedResource: model.grantResource,
                                       usesProblem: model.grantUsesProblem,
                                       expiryProblem: model.grantExpiryProblem,
                                       customExpiryRange: model.customExpiryRange,
                                       note: model.grantReviewNote,
                                       canContinue: model.canReviewGrant,
                                       onResourceChange: { model.reconcileGrantCapability() },
                                       onExpiryChange: { model.grantExpiryChanged(from: $0) },
                                       onContinue: { model.reviewGrant() },
                                       onBack: { model.go(.home) })
            case .confirmGrant:
                if case .grant(let handle, let kind, _, let resourceName, let capability, let limits)? = model.reviewedGrant {
                    MultiplayerGrantConfirmation(handle: handle, resourceName: resourceName, kind: kind,
                                                 capability: capability, limits: limits,
                                                 note: model.grantReviewNote, isBusy: model.isBusy,
                                                 onConfirm: { model.confirmGrant() },
                                                 onBack: { model.go(.grant) })
                }
            case .confirmRevoke(let grant):
                MultiplayerRevokeConfirmation(grant: grant, resourceName: model.resourceName(for: grant.resource),
                                              isBusy: model.isBusy,
                                              onConfirm: { model.confirmRevoke() },
                                              onBack: { model.go(.home) })
            case .repoCredential:
                if let resource = model.credentialResource {
                    MultiplayerCredentialEditor(resourceName: resource.name, entry: model.credentialEntry,
                                                problem: model.credentialProblem, canSave: model.canSaveCredential,
                                                isBusy: model.isBusy,
                                                onSave: { model.saveCredential() },
                                                onCancel: { model.go(.home) })
                }
            }
        } else {
            MultiplayerBand {
                MultiplayerAccountCard(presence: model.presence, hasStatus: model.status != nil,
                                       isBusy: model.isBusy, canRetry: model.setupFailure == nil,
                                       handleDraft: $model.handleDraft, handleProblem: model.handleDraftProblem,
                                       canClaim: model.canClaimHandle,
                                       onCheck: { model.refresh() },
                                       onSignIn: { model.signIn() },
                                       onClaim: { model.claimHandle() })
            }
        }
    }
}

/// The cockpit window's review stage for the same live panel.
struct MultiplayerPanelStage: View {
    let model: MultiplayerModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous)
        ZStack {
            Palette.window.ignoresSafeArea()
            ScrollView([.vertical]) {
                VStack(spacing: Space.m) {
                    MultiplayerPanel(model: model)
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(.inkEdge) }
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    Text("The menu bar network panel, shown in this window for review. It uses the same live helper.")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                }
                .padding(Space.xxl)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The menu bar item: the network's state as a symbol with a spoken name.
struct MultiplayerMenuBarLabel: View {
    let model: MultiplayerModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.menuSymbol)
            if model.unseen > 0 { Text("\(model.unseen)").monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Commander network, \(model.menuTitle)\(model.unseen > 0 ? ", \(model.unseen) new in activity" : "")")
    }
}
