import SwiftUI

// ATOMIC LEVEL: Organisms and the page (Network, Servers).
// Every saved server as a table, and the open server beside it: the certificate review while it is
// blocked, otherwise its key, its settings and who you are on it. The review, the settings and the
// identity band are the tray's organisms, used as they are.
//
//   NetworkServerTable       the servers (organism)
//   NetworkServerInspector   the open server (organism)
//   NetworkServersPage       both, under the page header (page)

struct NetworkServerTable: View {
    @Environment(\.theme) private var theme
    let servers: [NetworkPagesContent.Server]
    let openID: String?
    let now: Date
    let isBusy: Bool
    let open: (String) -> Void
    let signIn: (String) -> Void

    private static let name = ShellColumn(title: "server")
    private static let state = ShellColumn(title: "state", width: 152)
    private static let key = ShellColumn(title: "key", width: 120)
    private static let friends = ShellColumn(title: "friends", width: 52, alignment: .trailing)
    private static let requests = ShellColumn(title: "requests", width: 60, alignment: .trailing)
    private static let verbs: CGFloat = 64

    var body: some View {
        ShellTable(columns: [Self.name, Self.state, Self.key, Self.friends, Self.requests], trailing: Self.verbs,
                   items: servers, empty: "No server yet.") { server in
            let summary = server.summary
            ShellTableRow(isSelected: server.id == openID, spoken: spoken(summary),
                          hint: "Shows its certificate and settings", select: { open(server.id) }, trailing: Self.verbs) {
                HStack(spacing: Space.s) {
                    MultiplayerSwatch(color: MultiplayerTheme.swatch(for: server.id))
                    ShellCellText(title: summary.displayName,
                                  detail: summary.signedIn && !summary.handle.isEmpty
                                    ? "\(summary.host), as \(summary.handle.multiplayerDisplay)" : summary.host)
                    if summary.favorite {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.theme(\.color.attention))
                            .accessibilityHidden(true)
                    }
                }
                .shellCell(Self.name)
                MultiplayerStateLabel(lamp: summary.state.lamp, text: summary.stateTitle(now: now), tone: summary.state.tone)
                    .lineLimit(1)
                    .shellCell(Self.state)
                keyCell(summary).shellCell(Self.key)
                ShellCellFigure(text: server.isOnline ? "\(summary.friendsOnline)" : "–").shellCell(Self.friends)
                ShellCellFigure(text: server.isOnline ? "\(summary.incoming)" : "–", tone: summary.incoming > 0 ? .attention : .neutral)
                    .shellCell(Self.requests)
            } verbs: {
                if summary.state == .signedOut {
                    MultiplayerVerbStrip(verbs: [
                        MultiplayerRowVerb(id: "sign-in", title: "Sign in", isPrimary: true, isEnabled: !isBusy,
                                           hint: "Sign in to \(summary.displayName)", action: { signIn(server.id) })
                    ])
                }
            }
            .padding(.vertical, Space.xs)
            .accessibilityIdentifier("network-server-\(server.id)")
        }
    }

    /// Whether the key is pinned, and the short hash.
    private func keyCell(_ server: MultiplayerServerSummary) -> some View {
        let changed = server.state == .certChanged
        return HStack(spacing: Space.xs + 2) {
            Image(systemName: changed ? "exclamationmark.triangle.fill" : server.pin.isEmpty ? "checkmark.shield" : "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.theme(changed ? \.color.failure : \.color.working))
            Text(changed ? "changed" : server.pin.isEmpty ? "system trust" : MultiplayerHashChip.short(server.pin))
                .themeType(theme.type.fingerprint).lineLimit(1)
                .foregroundStyle(.theme(changed ? \.color.failure : \.color.secondary))
        }
    }

    private func spoken(_ server: MultiplayerServerSummary) -> String {
        var parts = [server.displayName, server.stateTitle(now: now)]
        if server.signedIn, !server.handle.isEmpty { parts.append("signed in as \(server.handle.multiplayerDisplay)") }
        if server.state == .certChanged { parts.append("its certificate changed") }
        if server.incoming > 0 { parts.append("\(server.incoming) friend requests") }
        return parts.joined(separator: ", ")
    }
}

/// The open server. Blocked: the tray's certificate review, with Remove, Trust and Keep blocked.
/// Otherwise its key as a hash chip, the tray's settings, and who you are on it.
struct NetworkServerInspector: View {
    @Environment(\.theme) private var theme
    let server: NetworkPagesContent.Server
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let summary = server.summary
        let header = (summary.state.lamp, summary.stateTitle(now: state.now), summary.state.tone)
        if summary.state == .certChanged {
            NetworkInspector(title: summary.displayName, serverID: server.id, serverName: summary.host, state: header,
                             close: actions.close) {
                MultiplayerCertificateReview(server: summary, presented: state.probe,
                                             confirmingTrust: state.confirmingTrust == server.id,
                                             confirmingRemoval: state.confirmingRemoval == server.id,
                                             isBusy: state.isBusy,
                                             onCheck: { actions.checkCertificate(summary) },
                                             onCancelTrust: actions.cancelTrust, onConfirmTrust: actions.confirmTrust,
                                             onCancelRemove: actions.cancelRemove, onConfirmRemove: actions.confirmRemove)
            } footer: {
                Button("Remove…") { actions.askRemove(summary) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                    .disabled(state.isBusy)
                    .accessibilityLabel("Remove server")
                Button("Trust new certificate…") { actions.askTrust(summary) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(!state.canTrust || state.confirmingTrust == server.id)
                Button("Keep blocked", action: actions.close)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
            }
        } else {
            NetworkInspector(title: summary.displayName, serverID: server.id, serverName: summary.host, state: header,
                             note: summary.signedIn && !summary.handle.isEmpty ? "Signed in as \(summary.handle.multiplayerDisplay)" : nil,
                             close: actions.close) {
                if !summary.pin.isEmpty {
                    MultiplayerBand {
                        MultiplayerHashChip(label: "Server key", hash: summary.pin, trust: .pinned)
                    }
                }
                MultiplayerServerSettings(server: summary, nickname: pages.drafts.nickname, canRename: state.canRename,
                                          isBusy: state.isBusy, confirmingRemoval: state.confirmingRemoval == server.id,
                                          onRename: actions.rename,
                                          onAutoConnect: { actions.setAutoConnect(summary, $0) },
                                          onFavorite: { actions.toggleFavorite(summary) },
                                          onAskRemove: { actions.askRemove(summary) },
                                          onCancelRemove: actions.cancelRemove, onConfirmRemove: actions.confirmRemove)
                if server.isOnline, !server.handle.isEmpty {
                    MultiplayerIdentityBand(handle: server.handle, displayName: server.displayName,
                                            statusMessage: server.statusMessage,
                                            avatar: state.avatar(server.handle, on: server.id), presence: summary.presence,
                                            isAdmin: server.isAdmin, membershipMode: server.membershipMode,
                                            isBusy: state.isBusy,
                                            onEdit: {
                                                actions.go(NetworkPlace.people)
                                                actions.editProfile(server.id)
                                            },
                                            onInvite: { actions.invite?(server.id) },
                                            onMembership: { actions.membership?(server.id) })
                }
            } footer: {
                if summary.signedIn {
                    Button("Sign out") { actions.signOut(server.id) }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(state.isBusy)
                } else if summary.state == .signedOut {
                    Button("Sign in") { actions.signIn(server.id) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(state.isBusy)
                }
            }
        }
    }
}

/// Network, Servers.
struct NetworkServersPage: View {
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        NetworkPageScaffold(place: NetworkPlace.servers, pages: pages) {
            if let add = actions.addServer {
                Button("Add server…", action: add).buttonStyle(ThemeButtonStyle())
                    .help("Opens the network panel on its Add server form")
                    .accessibilityIdentifier("network-add-server")
            }
        } content: {
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "Servers", count: "\(state.servers.count)")
                    NetworkServerTable(servers: state.servers, openID: state.openServer?.id, now: state.now,
                                       isBusy: state.isBusy, open: actions.openServer, signIn: actions.signIn)
                }
            } inspector: {
                if let server = state.openServer {
                    NetworkServerInspector(server: server, pages: pages)
                } else {
                    NetworkInspectorNote(text: "Choose a server to see the key it is pinned to, its settings and who you are on it.")
                }
            }
        }
    }
}
