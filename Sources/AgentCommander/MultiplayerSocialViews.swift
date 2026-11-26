import AppKit
import SwiftUI
import UniformTypeIdentifiers

// ATOMIC LEVEL: Organisms for the tray's social pages
// (design/mockups/commander-network-tray.html, the elements marked Inc 2).
// Presence picker, activity feed, a server's identity band, profile editor, invite page and admin
// membership page. Each takes values and emits actions; MultiplayerPanel wires them to the model.

/// The header's presence control: the presence the servers show now, and the five choices.
struct MultiplayerPresenceMenu: View {
    let shown: MultiplayerPersonPresence?
    let title: String
    /// Nil until the device agent has said which choice is in force.
    let choice: MultiplayerPresenceChoice?
    let isEnabled: Bool
    let onPick: (MultiplayerPresenceChoice) -> Void

    var body: some View {
        Menu {
            ForEach(MultiplayerPresenceChoice.allCases) { option in
                Button { onPick(option) } label: {
                    if option == choice {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            // Drawn as a cell of the status strip: the readout is also the control.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text("presence").font(MultiplayerTheme.label)
                    Image(systemName: "chevron.down").font(.system(size: 6.5, weight: .bold))
                }
                .foregroundStyle(.inkSecondary)
                HStack(spacing: 5) {
                    MultiplayerLamp(kind: shown?.lamp ?? .off, size: 8)
                    Text(title)
                        .font(MultiplayerTheme.data)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(1)
                }
                .frame(minHeight: 17)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 122, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.6)
        .help(isEnabled ? "Choose the presence your friends see. Auto shows Busy while agents run and Away when this Mac is idle."
              : "Sign in to a server to set your presence")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your presence")
        .accessibilityValue(title)
        .accessibilityHint("Opens a list to choose from")
    }
}

/// The feed across servers, newest first, with a filter by server and by friend.
struct MultiplayerActivityBand: View {
    let events: [MultiplayerActivityEvent]
    /// Whether the unfiltered feed has anything, to tell "nothing yet" from "nothing matches".
    let hasAny: Bool
    let unseen: Int
    let servers: [MultiplayerServerSummary]
    let actors: [String]
    @Binding var server: String?
    @Binding var friend: String?
    let now: Date
    let onMarkSeen: () -> Void
    @State private var showsAll = false

    static let preview = 6

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 4) {
                MultiplayerBandHeading(title: "Activity", count: unseen > 0 ? "\(unseen) new" : nil) {
                    filter(title: servers.first { $0.id == server }?.displayName ?? "All servers", label: "Filter by server") {
                        Button("All servers") { server = nil }
                        Divider()
                        ForEach(servers) { option in
                            Button(option.displayName) { server = option.id }
                        }
                    }
                    filter(title: friend?.multiplayerDisplay ?? "All friends", label: "Filter by friend") {
                        Button("All friends") { friend = nil }
                        Divider()
                        ForEach(actors, id: \.self) { actor in
                            Button(actor.multiplayerDisplay) { friend = actor }
                        }
                    }
                }
                if events.isEmpty {
                    Text(hasAny ? "Nothing matches these filters." : "Friend requests, shared access and new members show up here.")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let shown = showsAll ? events : Array(events.prefix(Self.preview))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                        MultiplayerActivityRow(event: event,
                                               serverName: servers.first { $0.id == event.server }?.displayName,
                                               color: MultiplayerTheme.swatch(for: event.server),
                                               isNew: server == nil && friend == nil && index < unseen, now: now)
                            .multiplayerArriving()
                    }
                    HStack(spacing: 6) {
                        if events.count > Self.preview {
                            Button(showsAll ? "Show fewer" : "Show all \(events.count)") { showsAll.toggle() }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                        }
                        if unseen > 0 {
                            Button("Mark as seen", action: onMarkSeen)
                                .buttonStyle(MultiplayerTrayButtonStyle())
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .multiplayerStreaming(events.map(\.id))
        }
    }

    private func filter<Items: View>(title: String, label: String, @ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(MultiplayerTrayButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(title)")
    }
}

/// Who the person is on one server, with the ways to change it and to bring others in.
struct MultiplayerIdentityBand: View {
    let handle: String
    let displayName: String
    let statusMessage: String
    let avatar: Data?
    let presence: MultiplayerPersonPresence?
    let isAdmin: Bool
    let membershipMode: String?
    let isBusy: Bool
    let onEdit: () -> Void
    let onInvite: () -> Void
    let onMembership: () -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "You on this server") {
                    if isAdmin { MultiplayerBadge(text: "Admin") }
                }
                HStack(alignment: .center, spacing: Space.m) {
                    MultiplayerAvatar(image: avatar, name: displayName.isEmpty ? handle : displayName, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((displayName.isEmpty ? handle : displayName).multiplayerDisplay)
                            .font(MultiplayerTheme.name)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let presence { MultiplayerLamp(kind: presence.lamp) }
                            Text([displayName.isEmpty ? nil : handle.multiplayerDisplay, presence?.title]
                                .compactMap { $0 }.joined(separator: ", "))
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(.inkSecondary)
                                .lineLimit(1)
                        }
                        if !statusMessage.isEmpty {
                            Text(statusMessage.multiplayerDisplay)
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(.inkSecondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 6) {
                    Button("Edit profile", action: onEdit)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                    Button("Invite someone", action: onInvite)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                    if isAdmin {
                        Button("Membership", action: onMembership)
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .help(membershipMode.map { "This relay is \(MultiplayerMembershipMode.title(for: $0).lowercased()). Change who can join." }
                                  ?? "Change who can join this relay")
                    }
                }
                .disabled(isBusy)
            }
        }
    }
}

/// One server's profile: picture, display name, handle and status line.
struct MultiplayerProfileEditor: View {
    @Binding var draft: MultiplayerProfileDraft
    let avatar: Data?
    let serverName: String
    let onChoosePicture: () -> Void
    let onDropPicture: (Data) -> Void
    let onRemovePicture: () -> Void

    var body: some View {
        MultiplayerBand {
            HStack(alignment: .center, spacing: Space.m) {
                MultiplayerAvatar(image: avatar, name: draft.trimmedDisplayName.isEmpty ? draft.trimmedHandle : draft.trimmedDisplayName,
                                  size: 56)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first, let file = MultiplayerPictureFile.read(url) else { return false }
                        onDropPicture(file)
                        return true
                    }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button("Choose picture…", action: onChoosePicture)
                            .buttonStyle(MultiplayerTrayButtonStyle())
                        if avatar != nil {
                            Button("Remove", action: onRemovePicture)
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .accessibilityLabel("Remove picture")
                        }
                    }
                    Text(pictureNote)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerSettingRow(label: "Display name") {
                    MultiplayerTextField(label: "Display name", placeholder: "Optional", text: $draft.displayName)
                }
                MultiplayerSettingRow(label: "Handle") {
                    MultiplayerTextField(label: "Handle", placeholder: "Your handle", text: $draft.handle, monospaced: true)
                }
                MultiplayerSettingRow(label: "Status") {
                    MultiplayerTextField(label: "Status message", placeholder: "What you’re working on", text: $draft.statusMessage)
                }
                Text(draft.problem ?? "Friends on \(serverName) see this. They add you by your handle, typed exactly.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(draft.problem == nil ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(MultiplayerTheme.failure))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
            }
        }
    }

    private var pictureNote: String {
        switch draft.avatar {
        case .replace(let encoded): "New picture, \(encoded.dataURL.utf8.count.formatted(.byteCount(style: .file))). Saved when you choose Save profile."
        case .remove: "The picture is removed when you choose Save profile."
        case .keep: "PNG or JPEG. Commander crops it square and shrinks it to fit 64 KB."
        }
    }
}

/// Reads a picked or dropped picture file, within a size no avatar source needs to exceed.
enum MultiplayerPictureFile {
    static let limit = 40 * 1024 * 1024

    static func read(_ url: URL) -> Data? {
        guard url.isFileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The system's open panel, for one image file.
    @MainActor static func choose() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for your profile"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return read(url)
    }
}

/// Makes an invite link for one server and copies it.
struct MultiplayerInvitePage: View {
    @Binding var draft: MultiplayerInviteDraft
    let invite: MultiplayerInvite?
    let serverName: String
    let canInvite: Bool
    let now: Date
    let onCopy: (String) -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Invite someone to \(serverName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text(canInvite
                     ? "The link carries this server’s address, its certificate fingerprint and a code. Opening it in Agent Commander adds the server and sends you a friend request."
                     : "Only an admin can create invites for this relay.")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if canInvite {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerSettingRow(label: "People who can use it") {
                        HStack(spacing: 6) {
                            Button { draft.maxUses -= 1 } label: { Image(systemName: "minus") }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(draft.maxUses <= MultiplayerInviteDraft.usesRange.lowerBound)
                                .accessibilityLabel("Fewer people")
                            Text("\(draft.maxUses)")
                                .font(MultiplayerTheme.figure)
                                .foregroundStyle(MultiplayerTheme.foreground)
                                .frame(minWidth: 30)
                                .accessibilityLabel("\(draft.maxUses) people can use the invite")
                            Button { draft.maxUses += 1 } label: { Image(systemName: "plus") }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(draft.maxUses >= MultiplayerInviteDraft.usesRange.upperBound)
                                .accessibilityLabel("More people")
                        }
                    }
                    MultiplayerSettingRow(label: "Expires after") {
                        MultiplayerSegments(label: "Expires after", options: MultiplayerInviteDraft.lifetimes.map(\.hours),
                                            title: { hours in MultiplayerInviteDraft.lifetimes.first { $0.hours == hours }?.title ?? "\(hours) h" },
                                            selection: $draft.ttlHours)
                    }
                }
            }
        }
        if let invite {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: "Invite link")
                    MultiplayerWell {
                        Text(invite.link)
                            .font(MultiplayerTheme.mono)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Space.s) {
                        Text(invite.expiresAt.map { "Expires \(MultiplayerTime.display($0, now: now))" } ?? "Send it to the person you’re inviting.")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                        Spacer(minLength: 0)
                        Button("Copy link") { onCopy(invite.link) }
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    }
                }
            }
        }
    }
}

/// What the add-server form says about the invite it was opened from.
struct MultiplayerInviteNote: View {
    let invite: MultiplayerInviteLink
    /// Nil while the check hasn't reached the certificate, or when the invite's fingerprint matches.
    let problem: String?
    let matched: Bool

    var body: some View {
        MultiplayerBand {
            MultiplayerWell(edge: problem == nil ? MultiplayerTheme.border : MultiplayerTheme.failure) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(invite.from.isEmpty ? "You opened an invite link" : "\(invite.from.multiplayerDisplay) invited you")
                        .font(MultiplayerTheme.heading)
                        .foregroundStyle(problem == nil ? MultiplayerTheme.foreground : MultiplayerTheme.failure)
                    Text(problem ?? (matched
                                     ? "The certificate matches the fingerprint in the invite. Joining adds this server and opens your browser to sign in."
                                     : "Commander checks the server, then compares its certificate with the invite."))
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(problem == nil ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(MultiplayerTheme.foreground))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The relay's membership settings, for its admins: who can join, the allowed emails and the admins.
struct MultiplayerMembershipPage: View {
    let state: MultiplayerMembershipState
    @Binding var draft: MultiplayerMembershipDraft
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .loading:
            MultiplayerBand {
                HStack(spacing: Space.s) {
                    MultiplayerSpinner()
                    Text("Reading this relay’s membership…").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        case .failed(let message):
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(MultiplayerSentence.join("Couldn’t read this relay’s membership.", message))
                        .font(.system(size: 12))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again", action: onRetry)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                }
            }
        case .loaded(let membership):
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: "Who can join",
                                           count: membership.memberCount == 1 ? "1 member" : "\(membership.memberCount) members")
                    let known = MultiplayerMembershipMode.allCases.map(\.rawValue)
                    MultiplayerSegments(label: "Who can join",
                                        options: known.contains(draft.mode) ? known : known + [draft.mode],
                                        title: { MultiplayerMembershipMode(rawValue: $0)?.title ?? $0.multiplayerDisplay },
                                        selection: $draft.mode)
                    Text(MultiplayerMembershipMode(rawValue: draft.mode)?.explanation ?? "This relay uses a mode this version of Commander doesn’t know.")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.xs) {
                    MultiplayerBandHeading(title: "Allowed emails", count: "\(draft.allowedList.count)")
                    MultiplayerTextArea(label: "Allowed emails", text: $draft.allowedEmails, lines: 4)
                    Text(draft.mode == MultiplayerMembershipMode.open.rawValue
                         ? "Not used while the relay is open. One address per line."
                         : "One address per line.")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.xs) {
                    MultiplayerBandHeading(title: "Admins", count: "\(draft.adminList.count)")
                    MultiplayerTextArea(label: "Admins", text: $draft.admins, lines: 2)
                    Text(draft.problem ?? "Admins change these settings and create invites. The relay keeps at least one.")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(draft.problem == nil ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(MultiplayerTheme.failure))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A window for the tray when a link opens it: the menu bar panel can't be opened from code.
@MainActor
enum MultiplayerLinkWindow {
    private static var window: NSWindow?

    static func show(_ model: MultiplayerModel) {
        if window == nil {
            let host = NSHostingController(rootView: MultiplayerPanel(model: model).preferredColorScheme(.dark))
            let created = NSWindow(contentViewController: host)
            created.title = "Commander network"
            created.styleMask = [.titled, .closable, .fullSizeContentView]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens every join link in the list; other URLs are ignored.
    static func open(_ urls: [URL], in model: MultiplayerModel) {
        let links = urls.filter { $0.scheme?.lowercased() == MultiplayerInviteLink.scheme }
        guard let link = links.first else { return }
        model.openInvite(link.absoluteString)
        show(model)
    }
}
