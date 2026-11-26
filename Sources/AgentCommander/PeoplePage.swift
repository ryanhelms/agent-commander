import SwiftUI

// ATOMIC LEVEL: Organisms and the page (People).
// Who wants to be a friend, your friends on each server, and beside them who you are and what has
// happened lately. The friend row, the identity band, the activity band and the profile editor are
// the tray's, used as they are; the request table and the grid are the main window's.
//
//   PeopleRequestTable   friend requests, with Accept and Decline (organism)
//   PeopleGrid           friends grouped by server, several to a line (organism)
//   PeopleInspector      you on each server and the activity feed, or the profile editor (organism)
//   PeoplePage           (page)

struct PeopleRequestTable: View {
    let rows: [NetworkFriendRow]
    let isBusy: Bool
    let accept: (NetworkFriendRow) -> Void
    /// Nil while the network model can't decline a friend request.
    let decline: ((NetworkFriendRow) -> Void)?

    private static let who = ShellColumn(title: "from")
    private static let server = ShellColumn(title: "server", width: NetworkLayout.serverColumn)
    private static let clock = ShellColumn(title: "time", width: NeedsYouLayout.clockWidth, alignment: .trailing)
    private static let verbs: CGFloat = 150

    var body: some View {
        ShellTable(columns: [Self.who, Self.server, Self.clock], trailing: Self.verbs, items: rows,
                   empty: "No one is waiting to be your friend.") { row in
            ShellTableRow(spoken: "\(row.who) sent a friend request on \(row.serverName)", trailing: Self.verbs) {
                HStack(spacing: Space.s) {
                    MultiplayerAvatar(image: nil, name: row.who, size: 22)
                    ShellCellText(title: row.who,
                                  detail: row.result?.rowText ?? "Friends can see your presence and ask for access.",
                                  detailTone: row.result?.rowTone ?? .neutral)
                }
                .shellCell(Self.who)
                ShellServerTag(id: row.server, name: row.serverName).shellCell(Self.server)
                NeedsYouClockLabel(waiting: row.waiting, expiresIn: nil).shellCell(Self.clock)
            } verbs: {
                NetworkRowVerbs(isRunning: row.isRunning, result: row.result, verbs: verbs(row))
            }
            .padding(.vertical, Space.xs)
            .accessibilityIdentifier("people-request-\(row.id)")
        }
    }

    private func verbs(_ row: NetworkFriendRow) -> [MultiplayerRowVerb] {
        var verbs: [MultiplayerRowVerb] = []
        if let decline {
            verbs.append(MultiplayerRowVerb(id: "decline", title: "Decline", isEnabled: !isBusy,
                                            hint: "Decline \(row.who)’s friend request", action: { decline(row) }))
        }
        verbs.append(MultiplayerRowVerb(id: "accept", title: "Accept", isPrimary: true, isEnabled: !isBusy,
                                        hint: "Accept \(row.who)’s friend request", action: { accept(row) }))
        return verbs
    }
}

/// Friends by server. Each server is a heading line, then its friends in as many columns as fit.
struct PeopleGrid: View {
    @Environment(\.theme) private var theme
    let groups: [MultiplayerFriendGroup]
    let isBusy: Bool
    let avatar: (_ handle: String, _ server: String) -> Data?
    let share: (_ handle: String, _ server: String) -> Void
    let loadAvatar: (_ handle: String, _ server: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { ThemeRule() }
                HStack(spacing: Space.s) {
                    MultiplayerSwatch(color: MultiplayerTheme.swatch(for: group.server.id))
                    Text(group.server.displayName).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground)).lineLimit(1)
                    Text(group.caption).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.m)
                .frame(minHeight: theme.space.controlHeightLarge)
                .background(theme.surface.headerFill.color)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if !group.people.isEmpty {
                    ThemeRule()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: NetworkLayout.personCell), spacing: Space.l, alignment: .leading)],
                              alignment: .leading, spacing: 0) {
                        ForEach(group.people) { person in
                            MultiplayerFriendRow(person: person, avatar: avatar(person.handle, person.server),
                                                 canShare: group.canShare, isBusy: isBusy) {
                                share(person.handle, group.server.id)
                            }
                            .task(id: person.id) { if person.hasAvatar { loadAvatar(person.handle, person.server) } }
                        }
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.xs)
                }
            }
            if groups.isEmpty { ShellNote(text: "No server yet.") }
        }
        .themePanel()
    }
}

/// Beside the friends: the profile editor while it is open, otherwise you on each server and the
/// activity feed.
struct PeopleInspector: View {
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        if let server = state.profileServer {
            NetworkInspector(title: "Your profile", serverID: server.id, serverName: server.name,
                             note: pages.drafts.profile.wrappedValue.hasChanges ? "Only what you changed is sent." : "Nothing changed yet.",
                             close: actions.close) {
                MultiplayerProfileEditor(draft: pages.drafts.profile, avatar: state.profileAvatar, serverName: server.name,
                                         onChoosePicture: actions.choosePicture, onDropPicture: actions.dropPicture,
                                         onRemovePicture: actions.removePicture)
            } footer: {
                Button("Cancel", action: actions.close).buttonStyle(MultiplayerTrayButtonStyle())
                Button("Save profile", action: actions.saveProfile)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(!state.canSaveProfile)
            }
        } else {
            let mine = state.online.filter { !$0.handle.isEmpty }
            NetworkInspector(title: "You and your network") {
                ForEach(mine) { server in
                    HStack(spacing: Space.xs + 2) {
                        ShellServerTag(id: server.id, name: server.name)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, MultiplayerTheme.sectionInset)
                    .padding(.top, Space.s)
                    MultiplayerIdentityBand(handle: server.handle, displayName: server.displayName,
                                            statusMessage: server.statusMessage,
                                            avatar: state.avatar(server.handle, on: server.id),
                                            presence: server.summary.presence, isAdmin: server.isAdmin,
                                            membershipMode: server.membershipMode, isBusy: state.isBusy,
                                            onEdit: { actions.editProfile(server.id) },
                                            onInvite: { actions.invite?(server.id) },
                                            onMembership: { actions.membership?(server.id) })
                }
                MultiplayerActivityBand(events: state.activity, hasAny: state.hasActivity, unseen: state.unseen,
                                        servers: state.servers.map(\.summary), actors: state.activityActors,
                                        server: pages.drafts.activityServer, friend: pages.drafts.activityFriend,
                                        now: state.now, onMarkSeen: actions.markActivitySeen)
            }
        }
    }
}

/// People.
struct PeoplePage: View {
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let requests = state.friendRequests
        let addable = state.online.filter { $0.summary.state != .certChanged }
        NetworkPageScaffold(place: NetworkPlace.people, pages: pages) {
            if let add = actions.addFriend {
                if addable.count == 1, let only = addable.first {
                    Button("Add friend…") { add(only.id) }.buttonStyle(ThemeButtonStyle()).disabled(state.isBusy)
                        .help("Look up a friend on \(only.name) by exact handle, in the network panel")
                } else {
                    Menu("Add friend…") {
                        ForEach(addable) { server in Button("On \(server.name)") { add(server.id) } }
                    }
                    .menuStyle(.button)
                    .buttonStyle(ThemeButtonStyle())
                    .fixedSize()
                    .disabled(state.isBusy || addable.isEmpty)
                    .help(addable.isEmpty ? "Sign in to a server first" : "Choose the server to add a friend on")
                }
            }
        } content: {
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ShellBandHeading(title: "Friend requests", count: "\(requests.count)")
                        PeopleRequestTable(rows: requests, isBusy: state.isBusy,
                                           accept: { actions.acceptFriend($0.request, $0.server) },
                                           decline: actions.declineFriend.map { decline in { decline($0.request, $0.server) } })
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        let available = state.friendsAvailable ?? state.people.reduce(0) { $0 + $1.onlineCount }
                        ShellBandHeading(title: "Friends", count: "\(available) online",
                                         note: "Someone on two servers counts once.")
                        PeopleGrid(groups: state.people, isBusy: state.isBusy, avatar: state.avatar,
                                   share: { handle, server in actions.share(server, handle, nil) },
                                   loadAvatar: actions.loadAvatar)
                    }
                }
            } inspector: {
                if let server = pages.selection.grant {
                    NetworkGrantInspector(server: server, pages: pages)
                } else {
                    PeopleInspector(pages: pages)
                }
            }
        }
    }
}

// MARK: - Router

/// The page for a network place, from one value.
struct NetworkPageView: View {
    let place: String
    let pages: NetworkPages

    var body: some View {
        switch place {
        case NetworkPlace.servers: NetworkServersPage(pages: pages)
        case NetworkPlace.directory: NetworkDirectoryPage(pages: pages)
        case NetworkPlace.approvals: NetworkApprovalsPage(pages: pages)
        case NetworkPlace.handoffs: NetworkHandoffsPage(pages: pages)
        case NetworkPlace.threads: NetworkThreadsPage(pages: pages)
        case NetworkPlace.audit: NetworkAuditPage(pages: pages)
        case NetworkPlace.fanout: NetworkFanoutPage(pages: pages)
        case NetworkPlace.shared: NetworkSharedPage(pages: pages)
        case NetworkPlace.people: PeoplePage(pages: pages)
        default: EmptyView()
        }
    }
}
