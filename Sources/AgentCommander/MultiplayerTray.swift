import SwiftUI

// ATOMIC LEVEL: Organisms and the page for the network tray
// (design/mockups/commander-network-tray.html, states a to e, increment 1 elements only).
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
    let isBusy: Bool
    let onAccept: (MultiplayerIncoming, String) -> Void

    private var count: Int { groups.reduce(0) { $0 + $1.incoming.count } }

    var body: some View {
        if count > 0 {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Needs you", count: "\(count)")
                    ForEach(groups) { group in
                        ForEach(group.incoming) { request in
                            MultiplayerNeedRow(color: MultiplayerTheme.swatch(for: group.server.id),
                                               title: "\(request.handle.multiplayerDisplay) sent a friend request",
                                               detail: "On \(group.server.displayName)",
                                               actionTitle: "Accept", isBusy: isBusy) {
                                onAccept(request, group.server.id)
                            }
                        }
                    }
                }
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
    let onAddFriend: (String) -> Void
    let onShare: (String, String) -> Void

    private var online: Int { groups.reduce(0) { $0 + $1.onlineCount } }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Friends", count: "\(online) online") { addFriend }
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
                    ForEach(group.friends) { friend in
                        MultiplayerFriendRow(friend: friend, canShare: group.canShare, isBusy: isBusy) {
                            onShare(friend.handle, group.server.id)
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
    let onProbe: () -> Void
    @FocusState private var addressFocused: Bool

    var body: some View {
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
                        if stage == .tls, let result = probe.probe, result.needsPinConfirmation,
                           let fingerprint = result.fingerprint {
                            MultiplayerWell {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("SHA-256 fingerprint to pin")
                                        .font(MultiplayerTheme.sub)
                                        .foregroundStyle(.inkSecondary)
                                    MultiplayerFingerprintText(fingerprint: fingerprint)
                                    Toggle("I checked this with the relay admin. Pin it.", isOn: $draft.pinConfirmed)
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                        .font(MultiplayerTheme.sub)
                                        .foregroundStyle(MultiplayerTheme.foreground)
                                        .padding(.top, 2)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
        }

        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerSettingRow(label: "Nickname") {
                    MultiplayerTextField(label: "Nickname", placeholder: "Optional", text: $draft.name)
                }
                MultiplayerSettingRow(label: "Connect automatically") {
                    Toggle("Connect automatically", isOn: $draft.autoConnect)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
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
                ProgressView().controlSize(.mini)
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
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(isBusy)
                }
                MultiplayerSettingRow(label: "Favorite") {
                    Toggle("Favorite", isOn: Binding(get: { server.favorite }, set: { _ in onFavorite() }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
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
                ProgressView().controlSize(.mini)
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
        if case .server(let id) = model.route { return model.server(id) }
        return nil
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        switch model.route {
        case .home:
            MultiplayerTrayHeader(title: "Commander network", subtitle: homeSubtitle) {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
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
        case .addServer:
            MultiplayerTrayHeader(title: "Add server", back: "Back", onBack: { model.go(.home) }) { EmptyView() }
        case .hosting:
            MultiplayerTrayHeader(title: "Hosting on this Mac", back: "Back", onBack: { model.go(.home) }) { EmptyView() }
        case .server:
            if let server = routedServer {
                MultiplayerTrayHeader(title: server.displayName, color: MultiplayerTheme.swatch(for: server.id),
                                      state: (server.state.lamp, server.stateTitle(now: model.currentDate()), server.state.tone),
                                      back: "Servers", onBack: { model.go(.home) }) { EmptyView() }
            }
        }
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
                                     onProbe: { model.runProbe() })
        case .hosting:
            MultiplayerHostingGuide()
        case .server:
            if let server = routedServer { serverPage(server) }
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
                        ProgressView().controlSize(.small)
                        Text("Asking the network helper…").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else {
            MultiplayerBand { MultiplayerTallyBand(tally: model.tally) }
            if model.servers.isEmpty {
                MultiplayerFirstRun(onAddServer: { model.startAddServer() }, onHosting: { model.go(.hosting) })
            } else {
                let groups = model.friendGroups
                MultiplayerServerList(servers: model.servers, now: model.currentDate(), isBusy: model.isBusy,
                                      onAdd: { model.startAddServer() },
                                      onOpen: { model.openServer($0) },
                                      onFavorite: { model.toggleFavorite($0) },
                                      onSignIn: { model.signIn($0) })
                MultiplayerNeedsYou(groups: groups, isBusy: model.isBusy,
                                    onAccept: { model.accept($0, on: $1) })
                MultiplayerFriendGroups(groups: groups, addable: model.friendServers, isBusy: model.isBusy,
                                        onAddFriend: { model.addFriend(on: $0) },
                                        onShare: { model.share(with: $0, on: $1) })
            }
        }
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
            if let session {
                MultiplayerSessionContent(model: session)
                    .padding(.horizontal, MultiplayerTheme.sectionInset)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch model.route {
        case .home:
            MultiplayerTrayFooter(note: "Updates while this panel is open", isFixture: model.usesFixtureHelper) {
                Button("Hosting") { model.go(.hosting) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .help("How to run a relay on this Mac")
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
                Button("Save server") { model.saveServer() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(model.canSaveServer ? KeyboardShortcut.defaultAction : nil)
                    .disabled(!model.canSaveServer)
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
                    MultiplayerTrayFooter(note: server.handle.isEmpty ? nil : "Signed in as \(server.handle.multiplayerDisplay)",
                                          isFixture: model.usesFixtureHelper) {
                        if let session = model.session(server.id), session.canSignOut {
                            Button("Sign out") { session.signOut() }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(session.isBusy)
                        }
                    }
                }
            }
        }
    }
}
