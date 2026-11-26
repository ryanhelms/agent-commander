import AppKit
import SwiftUI

// ATOMIC LEVEL: Organisms and the page for the network tray
// (design/mockups/commander-network-tray.html, states a to e; the social organisms are in
// MultiplayerSocialViews.swift).
// Organisms take values and emit actions. `MultiplayerPanel` is the page: it reads the one live
// MultiplayerModel and routes between home, add server, a server's page and the hosting note.

// MARK: - Organisms

/// The tray's title row: where you are, its state, and one trailing control.
struct MultiplayerTrayHeader<Trailing: View>: View {
    let title: String
    var color: Color? = nil
    var subtitle: String? = nil
    var state: (lamp: MultiplayerLamp.Kind, text: String, tone: Tone)? = nil
    /// Names the page Back returns to. Nil on the home page.
    var back: String? = nil
    var onBack: () -> Void = {}
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.s) {
            if let back {
                Button(action: onBack) {
                    Label(back, systemImage: "chevron.left")
                        .font(MultiplayerTheme.heading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MultiplayerTheme.focus)
                .keyboardShortcut(.cancelAction)
                .help("\(back) (Esc)")
                Spacer(minLength: Space.s)
            }
            VStack(alignment: back == nil ? .leading : .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    if let color { MultiplayerSwatch(color: color) }
                    Text(title)
                        .font(MultiplayerTheme.title)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                }
                if let state {
                    MultiplayerStateLabel(lamp: state.lamp, text: state.text, tone: state.tone)
                } else if let subtitle {
                    Text(subtitle)
                        .font(MultiplayerTheme.sub.monospacedDigit())
                        .foregroundStyle(.inkSecondary)
                }
            }
            if back == nil { Spacer(minLength: Space.s) }
            trailing
        }
        .padding(.horizontal, MultiplayerTheme.sectionInset)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }
}

/// The tray's last row: a line of context and the page's actions, on the well.
struct MultiplayerTrayFooter<Actions: View>: View {
    var note: String? = nil
    var isFixture = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(MultiplayerTheme.hair).frame(height: 1)
            HStack(spacing: Space.s) {
                if isFixture {
                    Label("Fixture helper", systemImage: "testtube.2")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(MultiplayerTheme.attention)
                        .help("Debug review mode: everything here comes from the COMMANDER_NETWORK_BIN fixture, not the bundled helper.")
                } else if let note {
                    Text(note)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.s)
                actions
            }
            .padding(.horizontal, MultiplayerTheme.sectionInset)
            .padding(.vertical, 9)
            .background(MultiplayerTheme.well)
        }
    }
}

/// First run: what a relay server is, and the way to add one.
struct MultiplayerFirstRun: View {
    let onAddServer: () -> Void
    let onHosting: () -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Add a relay server to start")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text("A relay connects you to friends and their agents. Type the host of a relay someone runs, or host one on this Mac. Commander remembers every server you add.")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Add server", action: onAddServer)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary, large: true))
                        .keyboardShortcut(.defaultAction)
                    Button("Host a relay on this Mac", action: onHosting)
                        .buttonStyle(MultiplayerTrayButtonStyle(large: true))
                }
                .padding(.top, Space.s)
            }
        }
    }
}

/// The saved servers, favorites first, each with its state. A server whose certificate changed
/// carries its blocking notice.
struct MultiplayerServerList: View {
    let servers: [MultiplayerServerSummary]
    let now: Date
    let isBusy: Bool
    let onAdd: () -> Void
    let onOpen: (String) -> Void
    let onFavorite: (MultiplayerServerSummary) -> Void
    let onSignIn: (String) -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Servers") {
                    Button(action: onAdd) { Label("Add server", systemImage: "plus") }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .help("Add a relay server by its address")
                }
                ForEach(servers) { server in
                    MultiplayerServerRow(server: server, now: now, isBusy: isBusy,
                                         hostedHere: MultiplayerServerAddress.isThisMac(server.url),
                                         onOpen: { onOpen(server.id) },
                                         onFavorite: { onFavorite(server) },
                                         onSignIn: { onSignIn(server.id) })
                    if server.state == .certChanged {
                        MultiplayerCertificateNotice(serverName: server.displayName) { onOpen(server.id) }
                            .padding(.bottom, Space.xs)
                    } else if server.state == .error, !server.error.isEmpty {
                        Text(MultiplayerModel.problemText(server.error))
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(MultiplayerTheme.failure)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 28)
                            .padding(.bottom, Space.xs)
                    }
                }
            }
        }
    }
}

/// Friend requests waiting on the person, across servers.
struct MultiplayerNeedsYou: View {
    let groups: [MultiplayerFriendGroup]
    /// Requests under Ask each time, and friends asking for access (increment 3).
    var approvals: [MultiplayerPending<MultiplayerApproval>] = []
    var access: [MultiplayerPending<MultiplayerAccessRequest>] = []
    var serverName: (String) -> String = { $0 }
    var resourceName: (_ resource: String, _ server: String) -> String = { resource, _ in resource }
    let isBusy: Bool
    let onAccept: (MultiplayerIncoming, String) -> Void
    var onOpenApproval: (MultiplayerPending<MultiplayerApproval>) -> Void = { _ in }
    var onDecide: (MultiplayerPending<MultiplayerApproval>, _ approve: Bool) -> Void = { _, _ in }
    var onReviewAccess: (MultiplayerPending<MultiplayerAccessRequest>) -> Void = { _ in }
    var onDeclineAccess: (MultiplayerPending<MultiplayerAccessRequest>) -> Void = { _ in }

    private var count: Int { groups.reduce(0) { $0 + $1.incoming.count } + approvals.count + access.count }

    var body: some View {
        if count > 0 {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                  Group {
                    MultiplayerBandHeading(title: "Needs you", count: "\(count)")
                    ForEach(approvals) { pending in
                        let approval = pending.item
                        let name = resourceName(approval.resource, pending.server).multiplayerDisplay
                        MultiplayerDecisionRow(color: MultiplayerTheme.swatch(for: pending.server),
                                               title: approval.headline,
                                               detail: approval.isSuggestion
                                                   ? (approval.request.isEmpty ? "For \(name)." : "For \(name): \(approval.request)")
                                                   : approval.request.isEmpty ? "On \(name). Grant is set to Ask each time."
                                                                              : "On \(name): \(approval.request)",
                                               isBusy: isBusy,
                                               onOpen: { onOpenApproval(pending) },
                                               onDecline: { onDecide(pending, false) },
                                               onAccept: { onDecide(pending, true) })
                            .multiplayerArriving()
                    }
                    ForEach(access) { pending in
                        let request = pending.item
                        MultiplayerDecisionRow(color: MultiplayerTheme.swatch(for: pending.server),
                                               title: "\(request.requester.multiplayerDisplay) asks for access",
                                               detail: "\(resourceName(request.resource, pending.server).multiplayerDisplay) on \(serverName(pending.server)). \(MultiplayerAccessRequestsPage.detail(request))",
                                               declineTitle: "Decline", acceptTitle: "Review", isBusy: isBusy,
                                               onOpen: { onReviewAccess(pending) },
                                               onDecline: { onDeclineAccess(pending) },
                                               onAccept: { onReviewAccess(pending) })
                            .multiplayerArriving()
                    }
                    ForEach(groups) { group in
                        ForEach(group.incoming) { request in
                            MultiplayerNeedRow(color: MultiplayerTheme.swatch(for: group.server.id),
                                               title: "\(request.handle.multiplayerDisplay) sent a friend request",
                                               detail: "On \(group.server.displayName)",
                                               actionTitle: "Accept", isBusy: isBusy) {
                                onAccept(request, group.server.id)
                            }
                            .multiplayerArriving()
                        }
                    }
                  }
                }
                .multiplayerStreaming(approvals.map(\.id) + access.map(\.id) + groups.flatMap { $0.incoming.map(\.id) })
            }
        }
    }
}

/// Friends grouped by server, online first.
struct MultiplayerFriendGroups: View {
    let groups: [MultiplayerFriendGroup]
    /// Servers a friend can be added on now.
    let addable: [MultiplayerServerSummary]
    let isBusy: Bool
    /// A friend's picture, by server ID and handle.
    let avatar: (String, String) -> Data?
    let onAddFriend: (String) -> Void
    let onShare: (String, String) -> Void
    /// Unique friends online or busy, each counted once across servers. Nil sums the groups.
    var available: Int? = nil

    private var online: Int { available ?? groups.reduce(0) { $0 + $1.onlineCount } }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Friends", count: "\(online) online") { addFriend }
                    .help("Friends who are online or busy. Someone on two servers counts once; away and do not disturb aren’t counted.")
                ForEach(groups) { group in
                    HStack(spacing: 6) {
                        MultiplayerSwatch(color: MultiplayerTheme.swatch(for: group.server.id))
                        Text(group.server.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .lineLimit(1)
                        Text(group.caption)
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                    }
                    .padding(.top, Space.s)
                    .padding(.bottom, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(group.people) { person in
                        MultiplayerFriendRow(person: person, avatar: avatar(person.server, person.handle),
                                             canShare: group.canShare, isBusy: isBusy) {
                            onShare(person.handle, group.server.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var addFriend: some View {
        if addable.count == 1, let only = addable.first {
            Button { onAddFriend(only.id) } label: { Label("Add friend", systemImage: "plus") }
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(isBusy)
                .help("Look up a friend on \(only.displayName) by exact handle")
        } else {
            Menu {
                ForEach(addable) { server in
                    Button("On \(server.displayName)") { onAddFriend(server.id) }
                }
            } label: {
                Label("Add friend", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(MultiplayerTrayButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy || addable.isEmpty)
            .help(addable.isEmpty ? "Sign in to a server first" : "Choose the server to add a friend on")
        }
    }
}

/// Add server: the address, the five-step health check with the fingerprint to pin, and the
/// nickname and connection setting it is saved with.
struct MultiplayerAddServerForm: View {
    @Binding var draft: MultiplayerServerDraft
    let addressProblem: String?
    let probe: MultiplayerProbeState
    let canProbe: Bool
    /// The invite this form was opened from, and why it can't be used, if it can't.
    var invite: MultiplayerInviteLink? = nil
    var inviteProblem: String? = nil
    /// The saved server this address already belongs to.
    var existing: MultiplayerServerSummary? = nil
    let onProbe: () -> Void
    var onOpenExisting: () -> Void = {}
    @FocusState private var addressFocused: Bool

    var body: some View {
        if let invite {
            MultiplayerInviteNote(invite: invite, problem: inviteProblem,
                                  matched: probe.probe?.step(.tls)?.ok == true && inviteProblem == nil)
        }
        if let existing {
            MultiplayerBand {
                MultiplayerWell(edge: MultiplayerTheme.attention) {
                    HStack(alignment: .center, spacing: Space.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Already in your list")
                                .font(MultiplayerTheme.heading)
                                .foregroundStyle(MultiplayerTheme.foreground)
                            Text("This address is saved as \(existing.displayName).")
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open \(existing.displayName)", action: onOpenExisting)
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    }
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Server address")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .accessibilityHidden(true)
                MultiplayerTextField(label: "Server address", placeholder: "relay.example", text: $draft.address,
                                     monospaced: true, isFocused: addressFocused)
                    .focused($addressFocused)
                    .onSubmit { if canProbe { onProbe() } }
                Text(addressProblem ?? "Use host, host:port or https://host:port. The port is 443 unless you give one.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(addressProblem == nil ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(MultiplayerTheme.failure))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { addressFocused = true }

        MultiplayerBand {
            VStack(alignment: .leading, spacing: 0) {
                MultiplayerBandHeading(title: "Health check") { progress }
                if case .failed(_, let message) = probe {
                    Text(message)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(MultiplayerTheme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Space.xs)
                }
                ForEach(Array(MultiplayerProbeStage.allCases.enumerated()), id: \.element) { index, stage in
                    if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                    let step = probe.probe?.step(stage)
                    MultiplayerProbeStepRow(number: index + 1, title: stage.title, passed: step?.ok,
                                            detail: step.map { Self.detail($0, stage: stage) }) {
                        if stage == .tls, invite == nil, existing == nil, let result = probe.probe,
                           result.needsPinConfirmation, let fingerprint = result.fingerprint {
                            MultiplayerWell {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("SHA-256 fingerprint to pin")
                                        .font(MultiplayerTheme.sub)
                                        .foregroundStyle(.inkSecondary)
                                    MultiplayerFingerprintText(fingerprint: fingerprint)
                                    HStack(spacing: Space.s) {
                                        Toggle("I checked this fingerprint with the relay admin. Pin it.", isOn: $draft.pinConfirmed)
                                            .toggleStyle(MultiplayerSwitchStyle())
                                        Text("I checked this with the relay admin. Pin it.")
                                            .font(MultiplayerTheme.sub)
                                            .foregroundStyle(MultiplayerTheme.foreground)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.top, 2)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
        }

        // An invite is joined as the link describes it; the nickname and connection setting come after.
        if invite == nil {
          MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerSettingRow(label: "Nickname") {
                    MultiplayerTextField(label: "Nickname", placeholder: "Optional", text: $draft.name)
                }
                MultiplayerSettingRow(label: "Connect automatically") {
                    Toggle("Connect automatically", isOn: $draft.autoConnect)
                        .toggleStyle(MultiplayerSwitchStyle())
                }
            }
          }
        }
    }

    @ViewBuilder private var progress: some View {
        switch probe {
        case .idle:
            Text("Not run yet").font(MultiplayerTheme.state).foregroundStyle(.inkSecondary)
        case .running:
            HStack(spacing: 6) {
                MultiplayerSpinner()
                Text("Checking…").font(MultiplayerTheme.state).foregroundStyle(MultiplayerTheme.focus)
            }
            .accessibilityElement(children: .combine)
        case .failed:
            Text("Didn’t run").font(MultiplayerTheme.state).foregroundStyle(MultiplayerTheme.failure)
        case .finished(let result, _):
            if let stage = result.stoppedAt, let index = MultiplayerProbeStage.allCases.firstIndex(of: stage) {
                Text("Stopped at step \(index + 1) of \(MultiplayerProbeStage.allCases.count)")
                    .font(MultiplayerTheme.state)
                    .foregroundStyle(MultiplayerTheme.failure)
            } else {
                Text("All \(MultiplayerProbeStage.allCases.count) steps passed")
                    .font(MultiplayerTheme.state)
                    .foregroundStyle(MultiplayerTheme.working)
            }
        }
    }

    /// The helper's own finding, or a plain line when it gave none.
    static func detail(_ step: MultiplayerProbeStep, stage: MultiplayerProbeStage) -> String {
        let text = MultiplayerText.clean(step.detail ?? "", limit: 240, redact: stage != .tls)
        if stage == .relay, step.ok {
            return text.isEmpty ? "Compatible" : text.localizedCaseInsensitiveContains("compatible") ? text : "\(text), compatible"
        }
        if !text.isEmpty { return text }
        if stage == .signin, step.clientConfigured == false {
            return "This Mac has no Desktop OAuth client file for this relay’s client ID. Ask the admin for the file, add it, then check again."
        }
        return step.ok ? "Passed" : "Failed. Check the address, then check again."
    }
}

/// One server's settings: nickname, automatic connection, favorite and removal.
struct MultiplayerServerSettings: View {
    let server: MultiplayerServerSummary
    @Binding var nickname: String
    let canRename: Bool
    let isBusy: Bool
    let confirmingRemoval: Bool
    let onRename: () -> Void
    let onAutoConnect: (Bool) -> Void
    let onFavorite: () -> Void
    let onAskRemove: () -> Void
    let onCancelRemove: () -> Void
    let onConfirmRemove: () -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerSettingRow(label: "Address") {
                    Text(server.host)
                        .font(MultiplayerTheme.mono)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let pinned = MultiplayerFingerprint.text(pin: server.pin) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pinned certificate, SHA-256")
                            .font(.system(size: 12))
                            .foregroundStyle(.inkSecondary)
                        MultiplayerWell { MultiplayerFingerprintText(fingerprint: pinned) }
                    }
                    .padding(.vertical, 4)
                } else {
                    MultiplayerSettingRow(label: "Certificate") {
                        Text(server.pin.isEmpty ? "Trusted by macOS, not pinned" : "Pinned, fingerprint unreadable")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                    }
                }
                MultiplayerSettingRow(label: "Nickname") {
                    HStack(spacing: 6) {
                        MultiplayerTextField(label: "Nickname", placeholder: server.host, text: $nickname)
                            .onSubmit { if canRename { onRename() } }
                        Button("Rename", action: onRename)
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(!canRename)
                    }
                }
                MultiplayerSettingRow(label: "Connect automatically") {
                    Toggle("Connect automatically", isOn: Binding(get: { server.autoConnect }, set: { onAutoConnect($0) }))
                        .toggleStyle(MultiplayerSwitchStyle())
                        .disabled(isBusy)
                }
                MultiplayerSettingRow(label: "Favorite") {
                    Toggle("Favorite", isOn: Binding(get: { server.favorite }, set: { _ in onFavorite() }))
                        .toggleStyle(MultiplayerSwitchStyle())
                        .disabled(isBusy)
                }
                if confirmingRemoval {
                    MultiplayerRemovalConfirmation(serverName: server.displayName, isBusy: isBusy,
                                                   onCancel: onCancelRemove, onConfirm: onConfirmRemove)
                        .padding(.top, Space.xs)
                } else {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Remove server…", action: onAskRemove)
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                            .disabled(isBusy)
                    }
                    .padding(.top, Space.xs)
                }
            }
        }
    }
}

/// The second step before a server is removed, stating what goes with it.
struct MultiplayerRemovalConfirmation: View {
    let serverName: String
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        MultiplayerWell(edge: MultiplayerTheme.failure) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Remove \(serverName)? This signs you out there and deletes its saved sign-in and files from this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button("Keep server", action: onCancel)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                    Button("Remove server", action: onConfirm)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                        .disabled(isBusy)
                }
            }
        }
    }
}

/// A server blocked because its pinned certificate changed: what happened, the pinned fingerprint
/// beside the one presented now, and what stays blocked.
struct MultiplayerCertificateReview: View {
    let server: MultiplayerServerSummary
    let presented: MultiplayerProbeState
    let confirmingTrust: Bool
    let confirmingRemoval: Bool
    let isBusy: Bool
    let onCheck: () -> Void
    let onCancelTrust: () -> Void
    let onConfirmTrust: () -> Void
    let onCancelRemove: () -> Void
    let onConfirmRemove: () -> Void

    var body: some View {
        MultiplayerBand {
            let shape = RoundedRectangle(cornerRadius: MultiplayerTheme.tileRadius, style: .continuous)
            VStack(alignment: .leading, spacing: 4) {
                Text("Commander blocked this connection")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MultiplayerTheme.failure)
                    .accessibilityAddTraits(.isHeader)
                Text("\(server.displayName) presented a certificate that does not match the one you pinned. Either the admin replaced it, or something between you and the relay is intercepting the connection. Compare the new fingerprint with the admin before you trust it.")
                    .font(.system(size: 12))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MultiplayerTheme.failure.opacity(0.10), in: shape)
            .overlay { shape.strokeBorder(MultiplayerTheme.failure) }
        }

        MultiplayerBand {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pinned").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                if let pinned = MultiplayerFingerprint.text(pin: server.pin) {
                    MultiplayerFingerprintText(fingerprint: pinned)
                } else {
                    Text("Commander can’t show the pinned fingerprint.")
                        .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                }
                Text("Presented now")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(MultiplayerTheme.failure)
                    .padding(.top, Space.s)
                presentedNow
            }
        }

        MultiplayerBand {
            VStack(alignment: .leading, spacing: 4) {
                MultiplayerBandHeading(title: "While blocked")
                Text("Friends on \(server.displayName) are hidden and nothing is sent to it. Your other servers stay connected.")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if confirmingTrust {
                    MultiplayerWell(edge: MultiplayerTheme.failure) {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("Trust the new certificate for \(server.displayName)? Do this only if the relay’s admin confirmed the fingerprint shown under “Presented now”.")
                                .font(.system(size: 12))
                                .foregroundStyle(MultiplayerTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Spacer(minLength: 0)
                                Button("Keep blocked", action: onCancelTrust)
                                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                                    .keyboardShortcut(.defaultAction)
                                Button("Trust new certificate", action: onConfirmTrust)
                                    .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                                    .disabled(isBusy)
                            }
                        }
                    }
                    .padding(.top, Space.s)
                }
                if confirmingRemoval {
                    MultiplayerRemovalConfirmation(serverName: server.displayName, isBusy: isBusy,
                                                   onCancel: onCancelRemove, onConfirm: onConfirmRemove)
                        .padding(.top, Space.s)
                }
            }
        }
    }

    @ViewBuilder private var presentedNow: some View {
        switch presented {
        case .running:
            HStack(spacing: 6) {
                MultiplayerSpinner()
                Text("Reading the certificate…").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
            }
            .accessibilityElement(children: .combine)
        case .finished(let result, _):
            if let fingerprint = result.fingerprint {
                MultiplayerWell(edge: MultiplayerTheme.failure) {
                    MultiplayerFingerprintText(fingerprint: fingerprint)
                }
            } else {
                unread("The server didn’t get as far as presenting a certificate.")
            }
        case .failed(_, let message):
            unread(message)
        case .idle:
            unread("Commander hasn’t read the certificate yet.")
        }
    }

    private func unread(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(message)
                .font(MultiplayerTheme.sub)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Check again", action: onCheck)
                .buttonStyle(MultiplayerTrayButtonStyle())
        }
    }
}

/// Hosting in increment 1: guidance only. The relay is started from Terminal; the tray has no
/// hosting controls yet.
struct MultiplayerHostingGuide: View {
    static let command = "commander-relay host install"

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Run a relay on this Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text("One relay process runs under launchd with its own bundled PostgreSQL and embedded NATS. Nothing else to install, and no Docker.")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                step(1, "Start the relay from Terminal. It keeps running after you log in again.")
                MultiplayerWell {
                    Text(Self.command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .textSelection(.enabled)
                }
                .padding(.leading, 24)
                step(2, "Add this Mac’s address here with Add server. The relay made its own certificate, so you confirm its fingerprint once.")
                step(3, "Give friends the same address. They pin the certificate when they add the server.")
                Text("To stop hosting, run commander-relay host uninstall.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .padding(.leading, 24)
                    .textSelection(.enabled)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            MultiplayerStepMark(number: number, passed: nil)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(MultiplayerTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Page

/// The network tray: the menu bar window, and the cockpit window under AGENT_COMMANDER_NETWORK_PANEL=1.
struct MultiplayerPanel: View {
    @Bindable var model: MultiplayerModel

    var body: some View {
        MultiplayerPanelShell {
            header
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                activity
                page
            }
        } footer: {
            footer
        }
        .onAppear { model.open() }
        .onDisappear { model.close() }
        .onChange(of: model.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
        .onChange(of: model.failure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure).post() }
        }
    }

    private var routedServer: MultiplayerServerSummary? {
        model.route.serverID.flatMap { model.server($0) }
    }

    /// Back from a page under a server returns to that server.
    private func subpageHeader(_ title: String) -> some View {
        MultiplayerTrayHeader(title: title, color: routedServer.map { MultiplayerTheme.swatch(for: $0.id) },
                              back: routedServer?.displayName ?? "Back",
                              onBack: { model.route.serverID.map { model.go(.server($0)) } }) { EmptyView() }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        switch model.route {
        case .home:
          VStack(spacing: 0) {
            MultiplayerTrayHeader(title: "Commander network", subtitle: homeSubtitle) {
                if model.isRefreshing {
                    MultiplayerSpinner()
                        .frame(width: 24, height: 24)
                        .accessibilityLabel("Checking status")
                } else {
                    SymbolButton(symbol: "arrow.clockwise", label: "Refresh status") { model.refreshAll() }
                        .foregroundStyle(model.canRefresh ? AnyShapeStyle(MultiplayerTheme.foreground) : AnyShapeStyle(.inkSecondary))
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!model.canRefresh)
                        .help("Refresh status (⌘R)")
                }
            }
            if model.hasLoaded, !model.servers.isEmpty {
                Rectangle().fill(MultiplayerTheme.hair).frame(height: 1)
                statusStrip
                MultiplayerTabBar(tabs: tabs, selection: $model.tab)
                    .padding(.bottom, -1)    // its lower edge is the header's rule
            }
          }
        case .addServer:
            MultiplayerTrayHeader(title: "Add server", back: "Back", onBack: { model.go(.home) }) { EmptyView() }
        case .hosting:
            MultiplayerTrayHeader(title: "Hosting on this Mac", back: "Back", onBack: { model.go(.home) }) { EmptyView() }
        case .server:
            if let server = routedServer {
                // Inside one of the server's editors, Back returns to the server's own page.
                let session = model.session(server.id)
                let inEditor = server.state != .certChanged && session.map { $0.route != .home } == true
                MultiplayerTrayHeader(title: server.displayName, color: MultiplayerTheme.swatch(for: server.id),
                                      state: (server.state.lamp, server.stateTitle(now: model.currentDate()), server.state.tone),
                                      back: inEditor ? "Back" : "Servers",
                                      onBack: { if inEditor { session?.go(.home) } else { model.go(.home) } }) { EmptyView() }
            }
        case .profile: subpageHeader("Your profile")
        case .invite: subpageHeader("Invite")
        case .membership: subpageHeader("Membership")
        case .share(let id, let page):
            MultiplayerTrayHeader(title: shareTitle(page, on: id), color: routedServer.map { MultiplayerTheme.swatch(for: $0.id) },
                                  back: model.share.backTitle, onBack: { model.share.back() }) { EmptyView() }
        }
    }

    /// A share page's title. A suggestion is named for who sent it.
    private func shareTitle(_ page: MultiplayerSharePage, on id: String) -> String {
        if case .approval(let approval) = page, let waiting = model.share.approval(approval, on: id), waiting.isSuggestion {
            return waiting.headline
        }
        return page.title
    }

    /// Servers online, approvals waiting, unseen activity and the person's presence: always above the tabs.
    private var statusStrip: some View {
        let tally = model.tally
        let waiting = model.share.pendingApprovals.count
        return MultiplayerStatusStrip(cells: [
            MultiplayerReadout(id: "servers", label: "servers", value: "\(tally.serversOnline)/\(tally.servers)",
                               lamp: tally.serversOnline > 0 ? .on : .off, spoken: tally.summary),
            MultiplayerReadout(id: "approvals", label: "approvals", value: "\(waiting)", tone: waiting > 0 ? .attention : .neutral,
                               spoken: waiting == 1 ? "1 approval waiting" : "\(waiting) approvals waiting"),
            MultiplayerReadout(id: "unseen", label: "unseen", value: "\(model.unseen)", tone: model.unseen > 0 ? .focus : .neutral,
                               spoken: "\(model.unseen) new in activity"),
        ]) {
            Rectangle().fill(MultiplayerTheme.hair).frame(width: 1)
            MultiplayerPresenceMenu(shown: model.shownPresence, title: model.presenceTitle,
                                    choice: model.effectivePresenceChoice, isEnabled: model.canSetPresence,
                                    onPick: { model.setPresence($0) })
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tabs: [MultiplayerTabBar.Tab] {
        let share = model.share
        let requests = model.servers.reduce(0) { $0 + $1.incoming }
        let trouble = model.servers.filter { $0.state == .certChanged || $0.state == .error }.count
        return [
            MultiplayerTabBar.Tab(id: .agents, count: share.pendingApprovals.count + share.pendingAccess.count, isHot: true),
            MultiplayerTabBar.Tab(id: .network, count: trouble, isHot: true),
            MultiplayerTabBar.Tab(id: .people, count: requests + model.unseen, isHot: requests > 0),
        ]
    }

    private var homeSubtitle: String {
        if model.unavailable != nil { return "Unavailable" }
        return model.hasLoaded ? model.tally.summary : "Checking…"
    }

    // MARK: Body

    @ViewBuilder private var activity: some View {
        if model.working != nil || model.failure != nil || model.notice != nil
            || (model.unavailable != nil && model.hasLoaded) {
            VStack(alignment: .leading, spacing: Space.s) {
                if let working = model.working {
                    MultiplayerBanner(kind: .progress, message: working)
                } else if let failure = model.failure {
                    MultiplayerBanner(kind: .failure, message: failure, onDismiss: { model.dismissFailure() })
                } else if let notice = model.notice {
                    MultiplayerBanner(kind: .success, message: notice, onDismiss: { model.dismissNotice() })
                }
                if model.hasLoaded, let unavailable = model.unavailable {
                    MultiplayerBanner(kind: .failure, message: "Couldn’t update the server list. \(unavailable.message)",
                                      actionTitle: unavailable.canRetry ? "Try again" : nil,
                                      action: { model.refresh() })
                }
            }
            .padding(.horizontal, MultiplayerTheme.sectionInset)
            .padding(.top, 10)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.route {
        case .home: home
        case .addServer:
            MultiplayerAddServerForm(draft: $model.serverDraft, addressProblem: model.addressProblem,
                                     probe: model.currentProbe, canProbe: model.canProbe,
                                     invite: model.activeInvite, inviteProblem: model.invitePinProblem,
                                     existing: model.existingServer,
                                     onProbe: { model.runProbe() },
                                     onOpenExisting: { model.existingServer.map { model.openServer($0.id) } })
        case .hosting:
            MultiplayerHostingGuide()
        case .server:
            if let server = routedServer { serverPage(server) }
        case .profile(let id):
            MultiplayerProfileEditor(draft: $model.profileDraft, avatar: model.profileAvatar(id),
                                     serverName: routedServer?.displayName ?? "this server",
                                     onChoosePicture: { MultiplayerPictureFile.choose().map { model.pickAvatar($0) } },
                                     onDropPicture: { model.pickAvatar($0) },
                                     onRemovePicture: { model.removeAvatar() })
        case .invite(let id):
            MultiplayerInvitePage(draft: $model.inviteDraft, invite: model.invite,
                                  serverName: routedServer?.displayName ?? "this server",
                                  canInvite: model.canInvite(id), now: model.currentDate(),
                                  onCopy: { link in
                                      NSPasteboard.general.clearContents()
                                      NSPasteboard.general.setString(link, forType: .string)
                                      model.post(notice: "Invite link copied.")
                                  })
        case .membership:
            MultiplayerMembershipPage(state: model.membership, draft: $model.membershipDraft,
                                      onRetry: { model.loadMembership() })
        case .share(let id, let page):
            sharePage(page, on: id)
        }
    }

    // MARK: Share and consult

    @ViewBuilder private func sharePage(_ page: MultiplayerSharePage, on id: String) -> some View {
        @Bindable var share = model.share
        let now = model.currentDate()
        let color = MultiplayerTheme.swatch(for: id)
        if model.session(id)?.isOnline != true {
            MultiplayerBand {
                Text("\(routedServer?.displayName ?? "This server") is offline. Sharing resumes when it’s back.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
            }
        } else {
            switch page {
            case .directory:
                MultiplayerDirectoryPage(entries: share.directory(id), isBusy: model.isBusy,
                                         isWaiting: { share.waitingRequest(for: $0, on: id) != nil },
                                         onRequest: { share.startRequestAccess($0, on: id) },
                                         onConsult: { share.startConsult($0.id, on: id) },
                                         onHandOff: { share.startHandoff($0.id, on: id) })
            case .requestAccess(let resource):
                if let entry = share.entry(resource, on: id) {
                    MultiplayerRequestAccessPage(entry: entry, draft: $share.accessDraft)
                }
            case .requests:
                MultiplayerAccessRequestsPage(incoming: share.incomingAccess(id), outgoing: share.outgoingAccess(id),
                                              resourceName: { share.resourceName($0, on: id) }, color: color, now: now,
                                              isBusy: model.isBusy,
                                              onReview: { share.review($0, on: id) },
                                              onDecline: { share.remove($0, on: id, declining: true) },
                                              onWithdraw: { share.remove($0, on: id, declining: false) })
            case .approval(let approvalID):
                if let approval = share.approval(approvalID, on: id) {
                    let status = model.session(id)?.status
                    MultiplayerApprovalPage(approval: approval, serverName: routedServer?.displayName ?? "this server",
                                            color: color, resourceName: share.resourceName(approval.resource, on: id),
                                            kind: status?.resources.first { $0.id == approval.resource }?.kind ?? "",
                                            grant: status?.grants.first {
                                                $0.resource == approval.resource && $0.capability == approval.action
                                                    && (approval.peer.isEmpty || $0.handle == approval.peer)
                                            },
                                            now: now)
                } else {
                    MultiplayerBand {
                        Text("This request was answered or expired.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                }
            case .grant:
                let status = model.session(id)?.status
                MultiplayerGrantSheet(draft: $share.grantDraft, servers: share.shareServers,
                                      friends: status?.friends ?? [], resources: status?.resources ?? [],
                                      resource: share.grantResource, companions: share.grantCompanions,
                                      onServer: { share.setGrantServer($0) },
                                      onResourceChange: { share.reconcileGrantActions() },
                                      onToggle: { share.toggleGrantAction($0) })
            case .consult(let resource):
                MultiplayerConsultPage(draft: $share.consultDraft, entry: share.entry(resource, on: id),
                                       reply: share.consultReply, attachProblem: share.attachProblem,
                                       onChoose: { share.attach(MultiplayerFilePanel.chooseFiles()) },
                                       onDrop: { share.attach($0) },
                                       onDetach: { share.detach($0) },
                                       onThread: { share.open(.thread(request: $0.request, title: $0.title), on: id) })
            case .handoff(let resource):
                MultiplayerHandoffComposer(draft: $share.handoffDraft, entry: share.entry(resource, on: id),
                                           attachProblem: share.attachProblem,
                                           onChoose: { share.attach(MultiplayerFilePanel.chooseFiles()) },
                                           onDrop: { share.attach($0) },
                                           onDetach: { share.detach($0) })
            case .handoffs:
                MultiplayerHandoffList(rows: share.handoffs[id] ?? [], state: { share.handoffState($0) },
                                       target: { share.handoffTarget($0, on: id) }, now: now,
                                       onOpen: { share.open(.handoffDetail(request: $0.request), on: id) })
            case .handoffDetail(let request):
                if let row = share.handoff(request, on: id) {
                    MultiplayerHandoffDetail(row: row, target: share.handoffTarget(row, on: id),
                                             state: share.handoffState(row), report: share.reports[request], now: now,
                                             isBusy: model.isBusy,
                                             onApply: { index, artifact in
                                                 if let checkout = MultiplayerFilePanel.chooseCheckout(for: artifact.name.multiplayerDisplay) {
                                                     share.apply(artifact: index, of: row, on: id, checkout: checkout)
                                                 }
                                             })
                } else {
                    MultiplayerBand {
                        Text("Commander can’t find this hand-off any more.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                }
            case .thread(_, let title):
                MultiplayerThreadPage(title: title, state: share.thread, draft: $share.commentDraft, now: now,
                                      onRetry: { share.reloadPage() })
            case .audit:
                MultiplayerAuditPage(state: share.audit, resourceName: { share.resourceName($0, on: id) }, now: now,
                                     onRetry: { share.reloadPage() })
            case .watch, .control, .reviewRequest, .review, .fanout, .compare:
                livePage(page, on: id, now: now)
            }
        }
    }

    // MARK: Live work

    @ViewBuilder private func livePage(_ page: MultiplayerSharePage, on id: String, now: Date) -> some View {
        let share = model.share
        @Bindable var live = model.share.live
        let serverName = routedServer?.displayName ?? "this server"
        switch page {
        case .watch(let resource):
            MultiplayerWatchView(watch: live.watch, entry: share.entry(resource, on: id), serverName: serverName,
                                 color: MultiplayerTheme.swatch(for: id), interval: 2,
                                 suggestion: $live.suggestDraft, reply: live.suggestReply,
                                 onRetry: { live.retryWatch() })
        case .control(let resource):
            MultiplayerControlPage(resourceName: share.resourceName(resource, on: id).multiplayerDisplay,
                                   holders: live.holders(of: resource, on: id),
                                   candidates: live.candidates(for: resource, on: id),
                                   draft: $live.handoverDraft, isBusy: model.isBusy,
                                   onTakeBack: { live.takeBack($0, on: id) })
        case .reviewRequest(let resource):
            MultiplayerReviewComposer(draft: $live.reviewDraft, entry: share.entry(resource, on: id),
                                      attachProblem: live.reviewProblem,
                                      onChoose: { live.attachDiff(MultiplayerFilePanel.chooseFiles()) },
                                      onDrop: { live.attachDiff($0) },
                                      onDetach: { live.detachDiff() })
        case .review(let request):
            if let row = live.review(request, on: id) {
                MultiplayerReviewPage(row: row, target: share.handoffTarget(row, on: id), review: MultiplayerReview(row.value),
                                      now: now, link: $live.postDraft, posted: live.posted[request],
                                      confirming: live.confirmingPost, problem: live.postProblem(request, on: id),
                                      isBusy: model.isBusy,
                                      onCancel: { live.cancelPost() }, onConfirm: { live.confirmPost() })
            } else {
                MultiplayerBand {
                    Text("Commander can’t find this review any more.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                }
            }
        case .fanout:
            MultiplayerFanoutComposer(draft: $live.fanoutDraft, targets: live.fanoutTargets(on: id),
                                      onToggle: { live.toggleFanoutTarget($0) })
        case .compare(let request):
            if let fanout = live.fanout(request, on: id) {
                MultiplayerComparePage(fanout: fanout,
                                       columns: fanout.children.map { child in
                                           let entry = share.entry(child.resource, on: id)
                                           return MultiplayerComparePage.Column(child: child, name: entry?.name ?? child.resource,
                                                                                owner: entry?.owner ?? "", capabilities: entry?.capabilities)
                                       },
                                       winner: live.winners[request], now: now,
                                       onChoose: { live.chooseWinner($0.id, of: request) },
                                       onThread: { child in
                                           let name = share.entry(child.resource, on: id)?.name ?? child.resource
                                           share.open(.thread(request: child.id, title: "\(name.multiplayerDisplay): \(fanout.title)"), on: id)
                                       })
            } else {
                MultiplayerBand {
                    Text("Commander can’t find this fan-out any more.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func liveFooter(_ page: MultiplayerSharePage, on id: String) -> some View {
        let share = model.share
        let live = model.share.live
        switch page {
        case .watch(let resource):
            MultiplayerTrayFooter(note: "Read-only. Reads while this page is open.") {
                if share.entry(resource, on: id)?.canSuggest == true {
                    Button("Send suggestion") { live.sendSuggestion() }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!live.canSuggest)
                        .help("Send the suggestion to the owner (⌘Return)")
                }
            }
        case .control(let resource):
            MultiplayerTrayFooter(note: live.candidates(for: resource, on: id).isEmpty ? nil
                                        : live.handoverDraft.handle.isEmpty ? "Choose a friend." : nil) {
                Button("Share…") { share.startGrant(on: id, resourceID: resource) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(model.isBusy)
                Button("Hand over") { live.handOver() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(!live.canHandOver)
                    .help("Hand control to the chosen friend for the chosen time")
            }
        case .reviewRequest:
            MultiplayerTrayFooter(note: "Uses one of your granted uses.") {
                Button("Cancel") { share.back() }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Request review") { live.sendReview() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!live.canSendReview)
                    .help("Request review (⌘Return)")
            }
        case .review(let request):
            MultiplayerTrayFooter {
                if let row = live.review(request, on: id) {
                    Button("Thread") { share.open(.thread(request: row.request, title: row.title), on: id) }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                    Button("Refresh") { model.refresh() }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(!model.canRefresh)
                    Spacer(minLength: 0)
                    Button("Post to PR…") { live.askPost() }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(model.isBusy || live.confirmingPost || live.postProblem(request, on: id) != nil)
                        .help(live.postProblem(request, on: id) ?? "Shows what will be posted, then asks you to confirm")
                }
            }
        case .fanout:
            MultiplayerTrayFooter(note: live.fanoutDraft.targets.count < 2 ? "Choose at least 2 workers." : nil) {
                Button("Cancel") { share.back() }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Send to \(max(live.fanoutDraft.targets.count, 2))") { live.sendFanout() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!live.canSendFanout)
                    .help("Send the prompt to every chosen worker (⌘Return)")
            }
        case .compare:
            MultiplayerTrayFooter(note: "The winner is a note on this Mac. Nothing is sent.") {
                Button("Refresh") { model.refresh() }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(!model.canRefresh)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func shareFooter(_ page: MultiplayerSharePage, on id: String) -> some View {
        let share = model.share
        switch page {
        case .watch, .control, .reviewRequest, .review, .fanout, .compare:
            liveFooter(page, on: id)
        case .directory:
            MultiplayerTrayFooter(note: "Granted actions work now. Ask the owner for the rest.") {
                Button("Access requests") { share.open(.requests, on: id) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
            }
        case .requestAccess:
            MultiplayerTrayFooter(note: share.accessDraft.actions.isEmpty ? "Choose at least one action." : nil) {
                Button("Cancel") { share.back() }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Send request") { share.sendAccessRequest() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(model.isBusy || !share.accessDraft.canSend)
            }
        case .requests:
            MultiplayerTrayFooter(note: "Review opens the share sheet. Granting it answers the request.") {
                Button("Shared directory") { share.open(.directory, on: id) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
            }
        case .approval(let approvalID):
            MultiplayerTrayFooter {
                if let approval = share.approval(approvalID, on: id) {
                    Button("Audit") { share.open(.audit(resource: approval.resource), on: id) }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .help("See earlier uses of this resource")
                    Spacer(minLength: 0)
                    Button("Deny") { share.decide(approval, on: id, approve: false) }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(model.isBusy)
                    Button("Approve") { share.decide(approval, on: id, approve: true) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(model.isBusy)
                }
            }
        case .grant:
            MultiplayerTrayFooter(note: share.grantHint) {
                Button("Cancel") { share.back() }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Share") { share.confirmGrant() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(!share.canGrant)
            }
        case .consult:
            MultiplayerTrayFooter(note: "Uses one of your granted uses.") {
                Button("Send prompt") { share.sendConsult() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!share.canSendConsult)
                    .help("Send (⌘Return)")
            }
        case .handoff:
            MultiplayerTrayFooter(note: "Uses one of your granted uses.") {
                Button("Cancel") { share.back() }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Hand off") { share.sendHandoff() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!share.canSendHandoff)
                    .help("Hand off (⌘Return)")
            }
        case .handoffs:
            MultiplayerTrayFooter(note: "Open one to check its run or read its result.") {
                Button("Shared directory") { share.open(.directory, on: id) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
            }
        case .handoffDetail(let request):
            MultiplayerTrayFooter {
                if let row = share.handoff(request, on: id) {
                    Button("Thread") { share.open(.thread(request: row.request, title: row.title), on: id) }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                    Spacer(minLength: 0)
                    Button("Check status") { share.check(row, on: id, result: false) }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(model.isBusy || row.run == nil)
                    Button("Get result") { share.check(row, on: id, result: true) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(model.isBusy || row.run == nil)
                        .help("Reads the run’s report and artifacts. Nothing is applied until you choose to.")
                }
            }
        case .thread:
            MultiplayerTrayFooter {
                Button("Refresh") { share.reloadPage() }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Post comment") { share.postComment() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!share.canComment)
            }
        case .audit:
            MultiplayerTrayFooter(note: "The latest 200 entries, kept on this Mac.") {
                Button("Refresh") { share.reloadPage() }.buttonStyle(MultiplayerTrayButtonStyle())
            }
        }
    }

    @ViewBuilder private var home: some View {
        if !model.hasLoaded {
            MultiplayerBand {
                if let unavailable = model.unavailable {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Can’t reach the network helper")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MultiplayerTheme.foreground)
                        Text(unavailable.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if unavailable.canRetry {
                            Button("Try again") { model.refresh() }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                        }
                    }
                } else {
                    HStack(spacing: Space.s) {
                        MultiplayerSpinner()
                        Text("Asking the network helper…").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else {
            if model.servers.isEmpty {
                MultiplayerFirstRun(onAddServer: { model.startAddServer() }, onHosting: { model.go(.hosting) })
            } else {
                Group {
                    switch model.tab {
                    case .agents: agentsTab
                    case .network: networkTab
                    case .people: peopleTab
                    }
                }
                .id(model.tab)
                .transition(.opacity)
                .animation(MultiplayerTheme.Motion.ease(), value: model.tab)
            }
        }
    }

    /// Agents: what waits on you, live remote work, your agents and your friends' agents.
    @ViewBuilder private var agentsTab: some View {
        let share = model.share
        MultiplayerNeedsYou(groups: [], approvals: share.pendingApprovals, access: share.pendingAccess,
                            serverName: { model.server($0)?.displayName ?? "a server" },
                            resourceName: { share.resourceName($0, on: $1) },
                            isBusy: model.isBusy,
                            onAccept: { model.accept($0, on: $1) },
                            onOpenApproval: { share.open(.approval($0.item.id), on: $0.server) },
                            onDecide: { share.decide($0.item, on: $0.server, approve: $1) },
                            onReviewAccess: { share.review($0.item, on: $0.server) },
                            onDeclineAccess: { share.remove($0.item, on: $0.server, declining: true) })
        let live = share.live
        MultiplayerControlBand(items: live.activeHandovers,
                               resourceName: { share.resourceName($0.item.resource, on: $0.server) },
                               serverName: { model.server($0)?.displayName ?? "a server" },
                               isBusy: model.isBusy,
                               onOpen: { live.startControl($0.item.resource, on: $0.server) },
                               onTakeBack: { live.takeBack($0.item, on: $0.server) })
        MultiplayerRemoteWorkBand(items: live.remoteWork.map { work in
            MultiplayerRemoteWorkBand.Item(id: work.id, symbol: work.symbol, kind: work.kindTitle, title: work.title,
                                           detail: work.detail, color: MultiplayerTheme.swatch(for: work.server),
                                           state: work.state, tone: work.tone, open: { live.open(work) })
        })
        MultiplayerAgentRoster(mine: share.myAgents, theirs: share.friendAgents,
                               serverName: { model.server($0)?.displayName ?? "a server" },
                               grantCount: { share.grantCount($0.item.id, on: $0.server) },
                               holder: { live.holders(of: $0.item.id, on: $0.server).first?.handle },
                               isWaiting: { share.waitingRequest(for: $0.item.id, on: $0.server) != nil },
                               isBusy: model.isBusy,
                               fanoutServers: live.fanoutServers,
                               onShare: { share.startGrant(on: $0.server, resourceID: $0.item.id) },
                               onAudit: { share.open(.audit(resource: $0.item.id), on: $0.server) },
                               onControl: { live.startControl($0.item.id, on: $0.server) },
                               onConsult: { share.startConsult($0.item.id, on: $0.server) },
                               onHandOff: { share.startHandoff($0.item.id, on: $0.server) },
                               onWatch: { live.startWatch($0.item.id, on: $0.server) },
                               onReview: { live.startReview($0.item.id, on: $0.server) },
                               onRequest: { share.startRequestAccess($0.item, on: $0.server) },
                               onDirectory: { share.open(.directory, on: $0) },
                               onFanout: { live.startFanout(on: $0) })
    }

    /// Network: the servers, their state and the keys they are known by.
    @ViewBuilder private var networkTab: some View {
        MultiplayerServerList(servers: model.servers, now: model.currentDate(), isBusy: model.isBusy,
                              onAdd: { model.startAddServer() },
                              onOpen: { model.openServer($0) },
                              onFavorite: { model.toggleFavorite($0) },
                              onSignIn: { model.signIn($0) })
        MultiplayerBand {
            MultiplayerLinkRow(symbol: "server.rack", title: "Hosting on this Mac",
                               caption: "How to run a relay here, with no Docker") { model.go(.hosting) }
        }
    }

    /// People: friend requests, friends by server, and what happened.
    @ViewBuilder private var peopleTab: some View {
        let groups = model.friendGroups
        MultiplayerNeedsYou(groups: groups, isBusy: model.isBusy, onAccept: { model.accept($0, on: $1) })
        MultiplayerFriendGroups(groups: groups, addable: model.friendServers, isBusy: model.isBusy,
                                avatar: { model.avatar(server: $0, handle: $1) },
                                onAddFriend: { model.addFriend(on: $0) },
                                onShare: { model.share(with: $0, on: $1) },
                                available: model.friendsAvailable)
        MultiplayerActivityBand(events: model.filteredActivity, hasAny: !model.activity.isEmpty,
                                unseen: model.unseen, servers: model.servers, actors: model.activityActors,
                                server: $model.activityServer, friend: $model.activityFriend,
                                now: model.currentDate(), onMarkSeen: { model.markActivitySeen() })
    }

    @ViewBuilder private func serverPage(_ server: MultiplayerServerSummary) -> some View {
        if server.state == .certChanged {
            MultiplayerCertificateReview(server: server, presented: model.presentedProbe(for: server),
                                         confirmingTrust: model.confirmingTrust == server.id,
                                         confirmingRemoval: model.confirmingRemoval == server.id,
                                         isBusy: model.isBusy,
                                         onCheck: { model.checkCertificate(server) },
                                         onCancelTrust: { model.cancelTrust() },
                                         onConfirmTrust: { model.confirmTrust() },
                                         onCancelRemove: { model.cancelRemove() },
                                         onConfirmRemove: { model.confirmRemove() })
        } else {
            let session = model.session(server.id)
            if session == nil || session?.route == .home {
                MultiplayerServerSettings(server: server, nickname: $model.renameDraft, canRename: model.canRename,
                                          isBusy: model.isBusy,
                                          confirmingRemoval: model.confirmingRemoval == server.id,
                                          onRename: { model.rename() },
                                          onAutoConnect: { model.setAutoConnect(server, $0) },
                                          onFavorite: { model.toggleFavorite(server) },
                                          onAskRemove: { model.askRemove(server) },
                                          onCancelRemove: { model.cancelRemove() },
                                          onConfirmRemove: { model.confirmRemove() })
            }
            if let session, session.route == .home, session.isOnline, let status = session.status {
                MultiplayerIdentityBand(handle: status.handle, displayName: status.displayName,
                                        statusMessage: status.statusMessage,
                                        avatar: model.avatar(server: server.id, handle: status.handle),
                                        presence: server.presence, isAdmin: model.isAdmin(server.id),
                                        membershipMode: model.me[server.id]?.mode, isBusy: model.isBusy,
                                        onEdit: { model.startProfile(server.id) },
                                        onInvite: { model.startInvite(server.id) },
                                        onMembership: { model.startMembership(server.id) })
                    .task(id: status.hasAvatar) {
                        if status.hasAvatar { model.loadAvatar(server: server.id, handle: status.handle) }
                    }
            }
            if let session, session.route == .home, session.isOnline, let status = session.status {
                let share = model.share
                MultiplayerSharingBand(directoryCount: status.directoryEntries.count,
                                       requestCount: share.incomingAccess(server.id).count,
                                       approvalCount: share.approvals[server.id]?.count ?? 0,
                                       handoffCount: share.handoffs[server.id]?.count ?? 0,
                                       canShare: !model.isBusy && !status.friends.isEmpty && !status.resources.isEmpty,
                                       onShare: { share.startGrant(on: server.id) },
                                       onDirectory: { share.open(.directory, on: server.id) },
                                       onRequests: { share.open(.requests, on: server.id) },
                                       onApprovals: {
                                           if let first = share.approvals[server.id]?.first { share.open(.approval(first.id), on: server.id) }
                                       },
                                       onHandoffs: { share.open(.handoffs, on: server.id) },
                                       onAudit: { share.open(.audit(resource: ""), on: server.id) })
            }
            if let session {
                MultiplayerSessionContent(model: session,
                                          onShare: { model.share.startGrant(on: server.id, handle: $0, resourceID: $1) },
                                          onAudit: { model.share.open(.audit(resource: $0), on: server.id) })
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch model.route {
        case .home:
            MultiplayerTrayFooter(note: "Updates while this panel is open", isFixture: model.usesFixtureHelper) {
                let signedIn = model.servers.filter(\.signedIn)
                if !signedIn.isEmpty {
                    Menu("Sign out") {
                        ForEach(signedIn) { server in
                            Button("Sign out of \(server.displayName)") { model.signOut(server.id) }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .fixedSize()
                    .disabled(model.isBusy)
                }
            }
        case .addServer:
            MultiplayerTrayFooter(note: model.addServerHint) {
                Button(model.currentProbe == .idle ? "Check server" : "Check again") { model.runProbe() }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(!model.canProbe)
                // A saved address is opened from its notice at the top of the form, not saved again.
                if model.existingServer == nil {
                    Button(model.activeInvite == nil ? "Save server" : "Join server") { model.saveServer() }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .keyboardShortcut(model.canSaveServer ? KeyboardShortcut.defaultAction : nil)
                        .disabled(!model.canSaveServer)
                }
            }
        case .hosting:
            MultiplayerTrayFooter(note: "Guidance only. The tray has no hosting controls yet.") {
                Button("Add server") { model.startAddServer() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
            }
        case .server:
            if let server = routedServer {
                if server.state == .certChanged {
                    MultiplayerTrayFooter {
                        Button("Remove…") { model.askRemove(server) }
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                            .disabled(model.isBusy)
                            .accessibilityLabel("Remove server")
                        Spacer(minLength: 0)
                        Button("Trust new certificate…") { model.askTrust(server) }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(!model.canTrust(server) || model.confirmingTrust == server.id)
                        Button("Keep blocked") { model.go(.home) }
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    }
                } else {
                    MultiplayerTrayFooter(note: model.session(server.id)?.route != .home ? nil : server.handle.isEmpty ? nil : "Signed in as \(server.handle.multiplayerDisplay)",
                                          isFixture: model.usesFixtureHelper) {
                        if let session = model.session(server.id), session.canSignOut {
                            Button("Sign out") { session.signOut() }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(session.isBusy)
                        }
                    }
                }
            }
        case .profile(let id):
            MultiplayerTrayFooter(note: model.profileDraft.hasChanges ? "Only what you changed is sent." : "Nothing changed yet.") {
                Button("Cancel") { model.go(.server(id)) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                Button("Save profile") { model.saveProfile() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(model.canSaveProfile ? KeyboardShortcut.defaultAction : nil)
                    .disabled(!model.canSaveProfile)
            }
        case .invite(let id):
            MultiplayerTrayFooter(note: model.invite == nil ? nil : "Each new link has its own code.") {
                Button(model.invite == nil ? "Create invite link" : "Create another") { model.createInvite() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: model.invite == nil ? .primary : .standard))
                    .disabled(model.isBusy || !model.canInvite(id))
            }
        case .membership(let id):
            MultiplayerTrayFooter(note: model.membership.membership == nil ? nil : "Changes apply to everyone on this relay.") {
                Button("Cancel") { model.go(.server(id)) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                Button("Save membership") { model.saveMembership() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(!model.canSaveMembership)
            }
        case .share(let id, let page):
            shareFooter(page, on: id)
        }
    }
}
