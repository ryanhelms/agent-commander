import AppKit
import SwiftUI

// ATOMIC LEVEL: Organisms and the page for the network tray
// (design/mockups/commander-network-tray.html, states a to e; the social organisms are in
// MultiplayerSocialViews.swift).
// Organisms take values and emit actions. `MultiplayerPanel` is the page: it reads the one live
// MultiplayerModel and routes between home, add server, a server's page and hosting (whose page
// and actions are in MultiplayerHosting.swift).

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

    @Environment(\.theme) private var theme
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
        .padding(.horizontal, theme.space.sectionInset)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }
}

/// The tray's last row: a line of context and the page's actions, on the well.
struct MultiplayerTrayFooter<Actions: View>: View {
    var note: String? = nil
    var isFixture = false
    @ViewBuilder var actions: Actions

    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(MultiplayerTheme.hair).frame(height: 1)
            HStack(spacing: Space.s) {
                if isFixture {
                    Label("Fixture helper", systemImage: "testtube.2")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(MultiplayerTheme.attention)
                        .help("Fixture mode: everything here comes from the COMMANDER_NETWORK_BIN fixture, not the bundled helper.")
                } else if let note {
                    Text(note)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.s)
                actions
            }
            .padding(.horizontal, theme.space.sectionInset)
            .padding(.vertical, 9)
            .background(MultiplayerTheme.footerFill)
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
    /// Refuses a friend request. Nil leaves Accept as the one answer.
    var onDecline: ((MultiplayerIncoming, String) -> Void)? = nil
    /// The moment arrival times are measured from.
    var now = Date()
    var onOpenApproval: (MultiplayerPending<MultiplayerApproval>) -> Void = { _ in }
    /// Where an approval's text goes. The tray says it leaves for the main window.
    var approvalOpenHint = "Opens the full request"
    var onDecide: (MultiplayerPending<MultiplayerApproval>, _ approve: Bool) -> Void = { _, _ in }
    var onReviewAccess: (MultiplayerPending<MultiplayerAccessRequest>) -> Void = { _ in }
    var onDeclineAccess: (MultiplayerPending<MultiplayerAccessRequest>) -> Void = { _ in }
    /// How a listed approval or access request came out, while its answered row stays. Such a row
    /// shows its outcome in place of its verbs and is no longer counted.
    var approvalAnswer: (MultiplayerPending<MultiplayerApproval>) -> MultiplayerAnswer? = { _ in nil }
    var accessAnswer: (MultiplayerPending<MultiplayerAccessRequest>) -> MultiplayerAnswer? = { _ in nil }

    /// Every row drawn, answered ones included.
    private var rows: Int { groups.reduce(0) { $0 + $1.incoming.count } + approvals.count + access.count }
    /// What still waits on the person.
    private var count: Int {
        rows - approvals.filter { approvalAnswer($0) != nil }.count - access.filter { accessAnswer($0) != nil }.count
    }

    var body: some View {
        if rows > 0 {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                  Group {
                    MultiplayerBandHeading(title: "Needs you", count: "\(count)")
                    ForEach(approvals) { pending in
                        let approval = pending.item
                        // The worker and its server, so two servers' requests can be told apart.
                        let name = "\(resourceName(approval.resource, pending.server).multiplayerDisplay) on \(serverName(pending.server))"
                        MultiplayerDecisionRow(color: MultiplayerTheme.swatch(for: pending.server),
                                               title: approval.headline,
                                               detail: approval.isSuggestion
                                                   ? (approval.request.isEmpty ? "For \(name)." : "For \(name): \(approval.request)")
                                                   : approval.request.isEmpty ? "\(name). Grant is set to Ask each time."
                                                                              : "\(name): \(approval.request)",
                                               outcome: approvalAnswer(pending), isBusy: isBusy,
                                               openHint: approvalOpenHint,
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
                                               declineTitle: "Decline", acceptTitle: "Review",
                                               outcome: accessAnswer(pending), isBusy: isBusy,
                                               onOpen: { onReviewAccess(pending) },
                                               onDecline: { onDeclineAccess(pending) },
                                               onAccept: { onReviewAccess(pending) })
                            .multiplayerArriving()
                    }
                    ForEach(groups) { group in
                        ForEach(group.incoming) { request in
                            MultiplayerNeedRow(color: MultiplayerTheme.swatch(for: group.server.id),
                                               title: "\(request.handle.multiplayerDisplay) sent a friend request",
                                               detail: Self.friendDetail(request, server: group.server.displayName, now: now),
                                               declineTitle: onDecline == nil ? nil : "Decline",
                                               onDecline: onDecline.map { decline in { decline(request, group.server.id) } },
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

extension MultiplayerNeedsYou {
    /// Where a friend request waits and, when the relay says, how long ago it came: "On home, 5m ago".
    static func friendDetail(_ request: MultiplayerIncoming, server: String, now: Date) -> String {
        guard let arrival = request.arrival(now: now) else { return "On \(server)" }
        return "On \(server), \(arrival)"
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Add friend: choose a server")
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

    @Environment(\.theme) private var theme
    var body: some View {
        MultiplayerBand {
            let shape = theme.trayControl
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
            unread(message.isEmpty ? "Commander couldn’t read the certificate." : message)
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

// MARK: - Page

/// The network tray: the menu bar window, and the cockpit window under AGENT_COMMANDER_NETWORK_PANEL=1.
struct MultiplayerPanel: View {
    let model: MultiplayerModel
    /// The theme the tray is drawn in. The menu bar tray stays in the console theme whatever the
    /// main window uses; whether it follows the person's choice is still to be decided (DESIGN.md
    /// section 6). Its components read `\.theme`, so another theme here restyles all of it.
    var theme: Theme = .console
    /// Whether an "Open in Agent Commander" row closes the window the panel is in. The review
    /// stage draws the panel in the cockpit window itself, which must stay.
    var closesOnOpen = true

    var body: some View {
        MultiplayerPanelContent(model: model, closesOnOpen: closesOnOpen).environment(\.theme, theme)
    }
}

private struct MultiplayerPanelContent: View {
    @Bindable var model: MultiplayerModel
    let closesOnOpen: Bool
    /// The window this panel is in, for the open-in-window row to close.
    @State private var panelWindow = MultiplayerPanelWindow()
    @Environment(\.multiplayerPanelDismissal) private var dismissal
    @Environment(\.multiplayerWindowOpener) private var opener

    @Environment(\.theme) private var theme
    var body: some View {
        shell
            .background { MultiplayerPanelWindowProbe(panel: panelWindow).accessibilityHidden(true) }
            .environment(\.multiplayerWindowOpener, windowOpener)
    }

    /// How this panel opens a window page: the opener it was given, closing its own panel after.
    /// In the menu bar the close goes through the scene's dismissal, not the window.
    private var windowOpener: MultiplayerWindowOpener {
        closesOnOpen ? opener.closing { [panelWindow, dismissal] in panelWindow.close(through: dismissal) } : opener
    }

    /// Shows a page where it lives: in the tray, or in the main window.
    private var pages: MultiplayerPageOpener { MultiplayerPageOpener(share: model.share, window: windowOpener) }

    private var shell: some View {
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
            MultiplayerTrayHeader(title: "Add server", back: model.tab.title, onBack: { model.go(.home) }) { EmptyView() }
        case .hosting:
            MultiplayerTrayHeader(title: "Hosting on this Mac", back: model.tab.title, onBack: { model.go(.home) }) { EmptyView() }
        case .server:
            if let server = routedServer {
                // Inside one of the server's editors, Back returns to the server's own page.
                let session = model.session(server.id)
                let inEditor = server.state != .certChanged && session.map { $0.route != .home } == true
                MultiplayerTrayHeader(title: server.displayName, color: MultiplayerTheme.swatch(for: server.id),
                                      state: (server.state.lamp, server.stateTitle(now: model.currentDate()), server.state.tone),
                                      back: inEditor ? server.displayName : model.tab.title,
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
        // A team page about one thing is titled with its name.
        let teams = model.share.teams
        switch page {
        case .group(let group): return teams.group(group, on: id)?.name.multiplayerDisplay ?? page.title
        case .workspace(let workspace): return teams.workspace(workspace, on: id)?.name.multiplayerDisplay ?? page.title
        case .hostRun(let resource): return "Run on \(model.share.resourceName(resource, on: id).multiplayerDisplay)"
        default: break
        }
        return page.title
    }

    /// Servers online, approvals waiting, unseen activity and the person's presence: always above the tabs.
    private var statusStrip: some View {
        let tally = model.tally
        let waiting = model.share.waitingApprovals.count
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
            MultiplayerTabBar.Tab(id: .agents, count: share.waitingApprovals.count + share.waitingAccess.count, isHot: true),
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
                    MultiplayerBanner(kind: .failure, message: MultiplayerSentence.join("Couldn’t update the server list.", unavailable.message),
                                      actionTitle: unavailable.canRetry ? "Try again" : nil,
                                      action: { model.refresh() })
                }
            }
            .padding(.horizontal, theme.space.sectionInset)
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
            MultiplayerHostingPage(host: model.host.summary, savedServer: model.hostedServer?.displayName,
                                   onDismissFailure: { model.host.dismissFailure() })
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
            // A page that has a window page says so first. One that passed its running-window check
            // is that row alone; the others keep their page under it (DESIGN.md, "The triage tray").
            if let link = MultiplayerWindowLink(page: page, server: id) {
                MultiplayerOpenInWindowRow(link: link)
            }
            if page.staysInTray { sharePage(page, on: id) }
        }
    }

    // MARK: Share and consult

    /// The pages the tray still draws. A page that moved is the open-in-window row alone.
    @ViewBuilder private func sharePage(_ page: MultiplayerSharePage, on id: String) -> some View {
        @Bindable var share = model.share
        if model.session(id)?.isOnline != true {
            MultiplayerBand {
                Text("\(routedServer?.displayName ?? "This server") is offline. Sharing resumes when it’s back.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
            }
        } else {
            switch page {
            case .requestAccess(let resource):
                if let entry = share.entry(resource, on: id) {
                    MultiplayerRequestAccessPage(entry: entry, draft: $share.accessDraft)
                }
            case .grant:
                MultiplayerGrantForm(model: model)
            case .consult(let resource):
                MultiplayerConsultPage(draft: $share.consultDraft, entry: share.entry(resource, on: id),
                                       reply: share.consultReply, attachProblem: share.attachProblem,
                                       onChoose: { share.attach(MultiplayerFilePanel.chooseFiles()) },
                                       onDrop: { share.attach($0) },
                                       onDetach: { share.detach($0) },
                                       onThread: { pages.show(.thread(request: $0.request, title: $0.title), on: id) })
            case .handoff(let resource):
                MultiplayerHandoffComposer(draft: $share.handoffDraft, entry: share.entry(resource, on: id),
                                           attachProblem: share.attachProblem,
                                           onChoose: { share.attach(MultiplayerFilePanel.chooseFiles()) },
                                           onDrop: { share.attach($0) },
                                           onDetach: { share.detach($0) })
            case .watch, .control, .reviewRequest:
                livePage(page, on: id)
            case .workspaceCreate:
                teamsPage(page, on: id)
            case .directory, .requests, .approval, .handoffs, .handoffDetail, .thread, .audit, .fanout, .compare,
                 .review,
                 .groups, .group, .workspaces, .workspace, .claim, .card, .queueAdd, .hosts, .hostRun,
                 .knowledge, .knowledgeShare, .knowledgeItem, .reputation, .search, .policy:
                EmptyView()
            }
        }
    }

    // MARK: Teams

    @ViewBuilder private func teamsPage(_ page: MultiplayerSharePage, on id: String) -> some View {
        @Bindable var teams = model.share.teams
        switch page {
        case .workspaceCreate:
            MultiplayerWorkspaceForm(draft: $teams.workspaceDraft, groups: teams.groups[id] ?? [])
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func teamsFooter(_ page: MultiplayerSharePage, on id: String) -> some View {
        let share = model.share
        let teams = model.share.teams
        switch page {
        case .workspaceCreate:
            MultiplayerTrayFooter(note: teams.workspaceDraft.hint) {
                Button("Cancel") { share.back() }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Create workspace") { teams.createWorkspace(on: id) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(!teams.canCreateWorkspace)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Live work

    @ViewBuilder private func livePage(_ page: MultiplayerSharePage, on id: String) -> some View {
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
                                   draft: $live.handoverDraft, now: model.currentDate(), isBusy: model.isBusy,
                                   onTakeBack: { live.takeBack($0, on: id) })
        case .reviewRequest(let resource):
            MultiplayerReviewComposer(draft: $live.reviewDraft, entry: share.entry(resource, on: id),
                                      attachProblem: live.reviewProblem,
                                      onChoose: { live.attachDiff(MultiplayerFilePanel.chooseFiles()) },
                                      onDrop: { live.attachDiff($0) },
                                      onDetach: { live.detachDiff() })
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
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func shareFooter(_ page: MultiplayerSharePage, on id: String) -> some View {
        let share = model.share
        switch page {
        case .watch, .control, .reviewRequest:
            liveFooter(page, on: id)
        case .workspaceCreate:
            teamsFooter(page, on: id)
        case .requestAccess:
            MultiplayerTrayFooter(note: share.accessDraft.actions.isEmpty ? "Choose at least one action." : nil) {
                Button("Cancel") { share.back() }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Send request") { share.sendAccessRequest() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(model.isBusy || !share.accessDraft.canSend)
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
        case .directory, .requests, .approval, .handoffs, .handoffDetail, .thread, .audit, .fanout, .compare,
             .review,
             .groups, .group, .workspaces, .workspace, .claim, .card, .queueAdd, .hosts, .hostRun,
             .knowledge, .knowledgeShare, .knowledgeItem, .reputation, .search, .policy:
            MultiplayerTrayFooter(note: "This page is in the main window now.") { EmptyView() }
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
        // An answered row stays for the model's hold with its outcome, then leaves.
        MultiplayerNeedsYou(groups: [], approvals: share.pendingApprovals, access: share.pendingAccess,
                            serverName: { model.server($0)?.displayName ?? "a server" },
                            resourceName: { share.resourceName($0, on: $1) },
                            isBusy: model.isBusy,
                            onAccept: { model.accept($0, on: $1) },
                            onOpenApproval: { pages.show(.approval($0.item.id), on: $0.server) },
                            approvalOpenHint: "Opens the full request in Agent Commander and closes this panel.",
                            onDecide: { share.decide($0.item, on: $0.server, approve: $1) },
                            onReviewAccess: { share.review($0.item, on: $0.server) },
                            onDeclineAccess: { share.remove($0.item, on: $0.server, declining: true) },
                            approvalAnswer: { share.answer(for: $0.item, on: $0.server) },
                            accessAnswer: { share.answer(for: $0.item, on: $0.server) })
        let live = share.live
        MultiplayerControlBand(items: live.activeHandovers,
                               resourceName: { share.resourceName($0.item.resource, on: $0.server) },
                               serverName: { model.server($0)?.displayName ?? "a server" },
                               now: model.currentDate(), isBusy: model.isBusy,
                               onOpen: { live.startControl($0.item.resource, on: $0.server) },
                               onTakeBack: { live.takeBack($0.item, on: $0.server) })
        MultiplayerRemoteWorkBand(items: live.remoteWork.map { work in
            MultiplayerRemoteWorkBand.Item(id: work.id, symbol: work.symbol, kind: work.kindTitle, title: work.title,
                                           detail: work.detail, color: MultiplayerTheme.swatch(for: work.server),
                                           state: work.state, tone: work.tone, opensWindow: !work.page.staysInTray,
                                           open: { pages.show(work) })
        })
        MultiplayerAgentRoster(mine: share.myAgents, theirs: share.friendAgents,
                               serverName: { model.server($0)?.displayName ?? "a server" },
                               grantCount: { share.grantCount($0.item.id, on: $0.server) },
                               holder: { live.holders(of: $0.item.id, on: $0.server).first?.handle },
                               isWaiting: { share.waitingRequest(for: $0.item.id, on: $0.server) != nil },
                               isBusy: model.isBusy,
                               shortcuts: MultiplayerWindowShortcut.agents(),
                               onShare: { share.startGrant(on: $0.server, resourceID: $0.item.id) },
                               onAudit: { pages.show(.audit(resource: $0.item.id), on: $0.server) },
                               onControl: { live.startControl($0.item.id, on: $0.server) },
                               onConsult: { share.startConsult($0.item.id, on: $0.server) },
                               onHandOff: { share.startHandoff($0.item.id, on: $0.server) },
                               onWatch: { live.startWatch($0.item.id, on: $0.server) },
                               onReview: { live.startReview($0.item.id, on: $0.server) },
                               onRequest: { share.startRequestAccess($0.item, on: $0.server) })
        // Workspaces, hosts and the knowledge library are window pages. New workspace is still here.
        let teams = share.teams
        if !teams.servers.isEmpty {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 0) {
                    MultiplayerBandHeading(title: "Teams") {
                        MultiplayerServerAction(title: "New…", symbol: "plus", label: "New workspace", servers: teams.servers,
                                                perform: { teams.startWorkspace(on: $0) })
                    }
                    MultiplayerWindowLinkRows(shortcuts: MultiplayerWindowShortcut.teams(
                        workspaces: teams.allWorkspaces.count, hosts: teams.hostCount, knowledge: teams.knowledgeCount))
                }
            }
        }
    }

    /// Network: the servers, their state and the keys they are known by.
    @ViewBuilder private var networkTab: some View {
        MultiplayerServerList(servers: model.servers, now: model.currentDate(), isBusy: model.isBusy,
                              onAdd: { model.startAddServer() },
                              onOpen: { model.openServer($0) },
                              onFavorite: { model.toggleFavorite($0) },
                              onSignIn: { model.signIn($0) })
        let remote = model.remote
        MultiplayerRemoteBand(status: remote.status, failure: remote.failure, pairing: remote.livePairing,
                              pairingExpired: remote.pairingExpired, confirmingRevoke: remote.confirmingRevoke,
                              renaming: remote.renaming,
                              now: model.currentDate(), isBusy: model.isBusy,
                              onSetRunning: { remote.setRunning($0) },
                              onNewCode: { remote.enable() },
                              onCopy: { MultiplayerHashChip.copy($0) },
                              onAskRevoke: { remote.askRevoke($0) },
                              onCancelRevoke: { remote.cancelRevoke() },
                              onConfirmRevoke: { remote.confirmRevoke() },
                              onStartRename: { remote.startRename($0) },
                              onCancelRename: { remote.cancelRename() },
                              onRename: { remote.rename(to: $0) },
                              onRetry: { remote.refresh() })
        MultiplayerBand {
            MultiplayerLinkRow(symbol: "server.rack", title: "Hosting on this Mac",
                               caption: model.host.summary.phase == .running ? "Relay running on this Mac"
                                   : "Start or stop a relay here, with no Docker") { model.go(.hosting) }
        }
    }

    /// People: friend requests, friends by server, and what happened.
    @ViewBuilder private var peopleTab: some View {
        let groups = model.friendGroups
        MultiplayerNeedsYou(groups: groups, isBusy: model.isBusy, onAccept: { model.accept($0, on: $1) },
                            onDecline: { model.decline($0, on: $1) }, now: model.currentDate())
        MultiplayerFriendGroups(groups: groups, addable: model.friendServers, isBusy: model.isBusy,
                                avatar: { model.avatar(server: $0, handle: $1) },
                                onAddFriend: { model.addFriend(on: $0) },
                                onShare: { model.share(with: $0, on: $1) },
                                available: model.friendsAvailable)
        // Groups are a window page.
        let teams = model.share.teams
        if !teams.servers.isEmpty {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 0) {
                    MultiplayerBandHeading(title: "Groups")
                    MultiplayerWindowLinkRows(shortcuts: MultiplayerWindowShortcut.groups(teams.allGroups.count))
                }
            }
        }
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
                // What moved to the main window is a compact row each. Share… and Relay policy stay.
                let waiting = share.unanswered(share.incomingAccess(server.id), on: server.id).count
                    + share.waitingApprovals(on: server.id).count
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: 0) {
                        MultiplayerBandHeading(title: "Share and consult") {
                            let canShare = !model.isBusy && !status.friends.isEmpty && !status.resources.isEmpty
                            Button { share.startGrant(on: server.id) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(!canShare)
                                .help(canShare ? "Give a friend access to one of your resources" : "Add a friend and a resource first")
                        }
                        MultiplayerWindowLinkRows(shortcuts: MultiplayerWindowShortcut.sharing(
                            on: server.id, directory: status.directoryEntries.count, waiting: waiting,
                            handoffs: share.handoffs[server.id]?.count ?? 0,
                            reviews: share.live.reviews[server.id]?.count ?? 0))
                    }
                }
                let teams = share.teams
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: 0) {
                        MultiplayerBandHeading(title: "Teams")
                        MultiplayerWindowLinkRows(shortcuts: MultiplayerWindowShortcut.serverTeams(
                            on: server.id, groups: teams.groups[server.id]?.count ?? 0,
                            workspaces: teams.workspaces[server.id]?.count ?? 0,
                            hosts: teams.myHosts(on: server.id).count + teams.friendHosts(on: server.id).count,
                            knowledge: teams.knowledge[server.id]?.count ?? 0, isAdmin: model.isAdmin(server.id)))
                    }
                }
            }
            if let session {
                MultiplayerSessionContent(model: session,
                                          onShare: { model.share.startGrant(on: server.id, handle: $0, resourceID: $1) },
                                          onAudit: { pages.show(.audit(resource: $0), on: server.id) })
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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Sign out: choose a server")
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
            MultiplayerTrayFooter(note: model.hostingNote) {
                MultiplayerHostingActions(host: model.host.summary, isSaved: model.hostedServer != nil,
                                          onStart: { model.host.start() }, onStop: { model.host.stop() },
                                          onCheck: { model.host.refresh() }, onAddServer: { model.addHostedServer() })
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
