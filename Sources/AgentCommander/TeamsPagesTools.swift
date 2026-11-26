import SwiftUI

// ATOMIC LEVEL: Organisms and pages (Teams, the team tools).
// Groups, Hosts, Knowledge, Directory and Admin. Each is a collection beside an inspector, like
// the network pages. The group page, the run-on-host page, the knowledge form and item page and
// the reputation page are the tray's, used as they are inside the inspector. The policy form is
// drawn again at page scale from the tray's own fields, because the tray's form carries its
// moderation fields with it.
//
//   TeamsGroupsPage, TeamsHostsPage, TeamsKnowledgePage, TeamsDirectoryPage, TeamsAdminPage   pages
//   TeamsPolicyForm     the relay policy at page scale (organism)
//   TeamsPolicyChange   what a policy draft changes, in words (values)
//   TeamsPageView       the page for a Teams place

// MARK: - Groups

struct TeamsGroupsPage: View {
    let pages: TeamsPages

    private static let name = ShellColumn(title: "group")
    private static let role = ShellColumn(title: "you are", width: 76)
    private static let members = ShellColumn(title: "members", width: 132)
    private static let server = ShellColumn(title: "server", width: NetworkLayout.serverColumn)

    var body: some View {
        let state = pages.content
        TeamsPageScaffold(place: TeamsPlace.groups, pages: pages) {
            if let server = state.servers.first {
                Button("New group…") { pages.send(.newGroup(server: server.id)) }.buttonStyle(ThemeButtonStyle())
                    .accessibilityIdentifier("teams-new-group")
            }
        } content: {
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "Groups", count: "\(state.groupRows.count)")
                    ShellTable(columns: [Self.name, Self.role, Self.members, Self.server], items: state.groupRows,
                               empty: "You are in no group yet. Create one to grant things to several friends at once.") { row in
                        ShellTableRow(isSelected: pages.selection.group == row.id,
                                      spoken: "\(row.group.name.multiplayerDisplay), \(row.group.memberTitle), \(row.isOwner ? "you own it" : "member"), on \(row.serverName)",
                                      hint: "Shows its members", select: { pages.send(.openGroup(row.id)) }) {
                            ShellCellText(title: row.group.name.multiplayerDisplay,
                                          detail: row.isOwner ? "You decide who is in it" : "Owned by \(row.group.owner.multiplayerDisplay)")
                                .shellCell(Self.name)
                            MultiplayerBadge(text: row.isOwner ? "Owner" : "Member", tone: row.isOwner ? .focus : .neutral)
                                .shellCell(Self.role)
                            HStack(spacing: Space.xs) {
                                ForEach(row.group.members.prefix(4), id: \.self) { member in
                                    MultiplayerAvatar(image: nil, name: member.multiplayerDisplay, size: 20)
                                }
                                ShellCellFigure(text: "\(row.group.members.count)")
                            }
                            .shellCell(Self.members)
                            ShellServerTag(id: row.server, name: row.serverName).shellCell(Self.server)
                        }
                        .padding(.vertical, Space.xs)
                        .accessibilityIdentifier("teams-group-\(row.group.id)")
                    }
                }
            } inspector: {
                inspector
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        let state = pages.content
        if case .group(let server)? = pages.selection.composer {
            NetworkInspector(title: "New group", serverID: server, serverName: state.serverName(server),
                             note: "You own it and add friends to it.", close: { pages.send(.closeComposer) }) {
                TeamsFormBand(refusal: state.refusal) {
                    MultiplayerBand {
                        VStack(alignment: .leading, spacing: Space.m) {
                            if state.servers.count > 1 {
                                MultiplayerField(label: "Server") {
                                    MultiplayerMenuField(label: "Server", placeholder: "Choose a server",
                                                         options: state.servers.map { ($0.id, $0.name) },
                                                         selection: Binding(get: { server }, set: { pages.send(.newGroup(server: $0)) }))
                                }
                            }
                            MultiplayerField(label: "Name", hint: "Members see this name.") {
                                MultiplayerTextField(label: "Group name", placeholder: "Relay crew", text: pages.drafts.groupName)
                                    .onSubmit { pages.send(.createGroup) }
                            }
                        }
                    }
                }
            } footer: {
                Button("Cancel") { pages.send(.closeComposer) }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Create group") { pages.send(.createGroup) }.buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(pages.drafts.wrappedValue.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || pages.isRunning("composer", server))
            }
        } else if let key = pages.selection.group, let found = state.group(key) {
            let owner = found.group.isOwned(by: found.server.handle)
            let busy = pages.isRunning("group", key)
            let removing: String? = { if case .removeMember(let handle, key)? = pages.selection.confirming { return handle } else { return nil } }()
            NetworkInspector(title: found.group.name.multiplayerDisplay, serverID: found.server.id, serverName: found.server.name,
                             close: { pages.send(.openGroup(nil)) }) {
                MultiplayerGroupPage(group: found.group, handle: found.server.handle,
                                     addable: state.addable(to: found.group, on: found.server.id), isBusy: busy,
                                     confirmingDelete: pages.selection.confirming == .deleteGroup(key), confirmingRemoval: removing,
                                     onAdd: { pages.send(.addMember($0, group: key)) },
                                     onRemove: { pages.send(.askRemoveMember($0, group: key)) },
                                     onConfirmRemove: { _ in pages.send(.confirm) },
                                     onCancelDelete: { pages.send(.cancelConfirmation) },
                                     onConfirmDelete: { pages.send(.confirm) })
            } footer: {
                if owner {
                    Button("Delete group…") { pages.send(.askDeleteGroup(key)) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                        .disabled(busy || pages.selection.confirming == .deleteGroup(key))
                }
            }
        } else {
            NetworkInspectorNote(text: "Choose a group to see who is in it. You can add friends to a group you own.")
        }
    }
}

// MARK: - Hosts

struct TeamsHostsPage: View {
    @Environment(\.theme) private var theme
    let pages: TeamsPages

    private static let host = ShellColumn(title: "host")
    private static let commands = ShellColumn(title: "enrolled commands")
    private static let grants = ShellColumn(title: "grants", width: 52, alignment: .trailing)
    private static let access = ShellColumn(title: "access", width: 88)
    private static let verbs: CGFloat = 72

    var body: some View {
        let state = pages.content
        TeamsPageScaffold(place: TeamsPlace.hosts, pages: pages) {
            NetworkSplit {
                VStack(alignment: .leading, spacing: theme.space.sectionGap) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ShellBandHeading(title: "You lend", count: "\(state.hostRows.count)",
                                         note: "Nothing runs on your Mac except these commands.")
                        ShellTable(columns: [Self.host, Self.commands, Self.grants], trailing: Self.verbs, items: state.hostRows,
                                   empty: "You lend no host. Enroll a command in agentctl to lend this Mac.") { row in
                            ShellTableRow(isSelected: pages.selection.host == row.id,
                                          spoken: "\(row.host.name.multiplayerDisplay), \(MultiplayerPlural.count(row.host.commands.count, "command")), \(MultiplayerPlural.count(row.host.grants, "grant"))",
                                          hint: "Shows its enrolled commands", select: { pages.send(.openHost(row.id)) },
                                          trailing: Self.verbs) {
                                hostCell(row.host.name, detail: [row.host.environment, row.serverName], tone: .focus).shellCell(Self.host)
                                ShellCellText(title: row.host.commands.map(\.name.multiplayerDisplay).joined(separator: ", "), isData: true)
                                    .shellCell(Self.commands)
                                ShellCellFigure(text: "\(row.host.grants)").shellCell(Self.grants)
                            } verbs: {
                                MultiplayerVerbStrip(verbs: [
                                    MultiplayerRowVerb(id: "share", title: "Share…", hint: "Opens the share sheet for \(row.host.name.multiplayerDisplay)",
                                                       action: { pages.send(.shareHost(resource: row.host.id, server: row.server)) })
                                ])
                            }
                            .padding(.vertical, Space.xs)
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        ShellBandHeading(title: "Friends lend", count: "\(state.offeredHostRows.count)",
                                         note: "Each run follows the owner’s grant and approval.")
                        ShellTable(columns: [Self.host, Self.commands, Self.access], trailing: Self.verbs, items: state.offeredHostRows,
                                   empty: "No friend lends a host on your servers.") { row in
                            offeredRow(row)
                        }
                    }
                }
            } inspector: {
                inspector
            }
        }
    }

    private func hostCell(_ name: String, detail: [String], tone: Tone) -> some View {
        HStack(spacing: Space.s) {
            MultiplayerMark(symbol: "cpu", tone: tone, size: 22)
            ShellCellText(title: name.multiplayerDisplay, detail: detail.filter { !$0.isEmpty }.map(\.multiplayerDisplay).joined(separator: ", "))
        }
    }

    private func offeredRow(_ row: TeamsOfferedHostRow) -> some View {
        let entry = row.entry, usable = entry.canRunOnHost
        let last = row.run.map { "Last run: exit \($0.exitCode), \(MultiplayerPlural.count($0.seconds, "second"))" }
        return ShellTableRow(isSelected: pages.selection.host == row.id,
                             spoken: "\(entry.name.multiplayerDisplay), \(entry.owner.multiplayerDisplay), \(usable ? "you can run on it" : "not granted")\(NetworkSpoken.suffix(last))",
                             hint: "Shows what you can run on it", select: { pages.send(.openHost(row.id)) }, trailing: Self.verbs) {
            hostCell(entry.name, detail: [entry.owner] + (entry.capabilities?.environments ?? []), tone: usable ? .working : .neutral)
                .shellCell(Self.host)
            ShellCellText(title: row.commands.isEmpty ? "not published" : row.commands.map(\.multiplayerDisplay).joined(separator: ", "),
                          detail: last, isData: true, detailTone: row.run.map { $0.succeeded ? .working : .failure } ?? .neutral)
                .shellCell(Self.commands)
            MultiplayerStateLabel(lamp: usable ? .on : .off, text: usable ? "Granted" : "Offered", tone: usable ? .working : .neutral)
                .shellCell(Self.access)
        } verbs: {
            if row.isRunning {
                MultiplayerSpinner().accessibilityLabel("In progress")
            } else if usable {
                MultiplayerVerbStrip(verbs: [
                    MultiplayerRowVerb(id: "run", title: "Run", isPrimary: true, hint: "Opens the commands you can run on \(entry.name.multiplayerDisplay)",
                                       action: { pages.send(.openHost(row.id)) })
                ])
            } else {
                MultiplayerVerbStrip(verbs: [
                    MultiplayerRowVerb(id: "request", title: "Request", hint: "Asks \(entry.owner.multiplayerDisplay) for access",
                                       action: { pages.send(.requestHost(resource: entry.id, server: row.server)) })
                ])
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityIdentifier("teams-host-\(entry.id)")
    }

    @ViewBuilder private var inspector: some View {
        let state = pages.content
        if let key = pages.selection.host, let found = state.offeredHost(key) {
            let entry = found.entry, running = pages.isRunning("host", key)
            NetworkInspector(title: "Run on \(entry.name.multiplayerDisplay)", serverID: found.server.id, serverName: found.server.name,
                             state: entry.canRunOnHost ? (.on, "Granted", .working) : (.off, "Offered", .neutral),
                             note: running ? "Running on \(entry.owner.multiplayerDisplay)’s Mac…" : "The output’s last 64 KB comes back.",
                             close: { pages.send(.openHost(nil)) }) {
                MultiplayerHostRunPage(draft: pages.drafts.hostRun, entry: entry, reply: running ? nil : state.hostRuns[key])
            } footer: {
                if running {
                    MultiplayerSpinner().accessibilityLabel("In progress")
                } else if entry.canRunOnHost {
                    Button("Run") { pages.send(.runHost(resource: entry.id, server: found.server.id)) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(!pages.drafts.wrappedValue.hostRun.canSend)
                        .accessibilityIdentifier("teams-run-host")
                } else {
                    Button("Request access") { pages.send(.requestHost(resource: entry.id, server: found.server.id)) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                }
            }
            .id(key)
        } else if let key = pages.selection.host, let found = state.host(key) {
            NetworkInspector(title: found.host.name.multiplayerDisplay, serverID: found.server.id, serverName: found.server.name,
                             note: MultiplayerPlural.count(found.host.grants, "grant"), close: { pages.send(.openHost(nil)) }) {
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: 2) {
                        MultiplayerBandHeading(title: "Enrolled commands", count: "\(found.host.commands.count)") { EmptyView() }
                        ForEach(Array(found.host.commands.enumerated()), id: \.element.id) { index, command in
                            if index > 0 { ThemeRule() }
                            HStack(spacing: Space.s) {
                                Text(command.name.multiplayerDisplay).font(MultiplayerTheme.data).foregroundStyle(MultiplayerTheme.foreground)
                                    .lineLimit(1).textSelection(.enabled)
                                Spacer(minLength: Space.s)
                                if !command.environment.isEmpty { MultiplayerBadge(text: command.environment.multiplayerDisplay) }
                                MultiplayerBadge(text: command.allowArgs ? "Takes arguments" : "Fixed arguments",
                                                 tone: command.allowArgs ? .attention : .neutral)
                            }
                            .frame(minHeight: 30)
                            .accessibilityElement(children: .combine)
                        }
                        Text("Each is a fixed argument array with a working directory. A friend with a grant chooses one by name.")
                            .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.s)
                    }
                }
            } footer: {
                Button("Share…") { pages.send(.shareHost(resource: found.host.id, server: found.server.id)) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
            }
        } else {
            NetworkInspectorNote(text: "Choose a host. On a friend’s host you choose an enrolled command, run it and read the end of its output.")
        }
    }
}

// MARK: - Knowledge

struct TeamsKnowledgePage: View {
    let pages: TeamsPages

    private static let item = ShellColumn(title: "item")
    private static let visible = ShellColumn(title: "visible to")
    private static let version = ShellColumn(title: "version", width: 48, alignment: .trailing)
    private static let updated = ShellColumn(title: "shared", width: 124, alignment: .trailing)

    var body: some View {
        let state = pages.content
        TeamsPageScaffold(place: TeamsPlace.knowledge, pages: pages) {
            if let server = state.servers.first {
                Button("Share…") { pages.send(.startShare(server: server.id)) }.buttonStyle(ThemeButtonStyle())
                    .accessibilityIdentifier("teams-share-knowledge")
            }
        } content: {
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "Library", count: "\(state.knowledgeRows.count)")
                    ShellTable(columns: [Self.item, Self.visible, Self.version, Self.updated], items: state.knowledgeRows,
                               empty: "Nothing is shared yet. Share a prompt, a skill or an MCP configuration.") { row in
                        let kind = MultiplayerKnowledgeKind.title(for: row.item.kind)
                        ShellTableRow(isSelected: pages.selection.knowledge == row.id,
                                      spoken: "\(row.item.name.multiplayerDisplay), \(kind), visible to \(row.visibility.lowercased()), version \(row.item.version)",
                                      hint: "Shows its content and versions", select: { pages.send(.openKnowledge(row.id)) }) {
                            HStack(spacing: Space.s) {
                                MultiplayerMark(symbol: MultiplayerKnowledgeKind.symbol(for: row.item.kind), tone: row.isMine ? .focus : .neutral,
                                                size: 22)
                                ShellCellText(title: row.item.name.multiplayerDisplay,
                                              detail: "\(kind), \(row.isMine ? "by you" : "by \(row.item.owner.multiplayerDisplay)") on \(row.serverName)")
                            }
                            .shellCell(Self.item)
                            ShellCellText(title: row.visibility).shellCell(Self.visible)
                            ShellCellFigure(text: "v\(row.item.version)").shellCell(Self.version)
                            ShellCellFigure(text: row.item.createdAt.map { MultiplayerTime.display($0, now: state.now) } ?? "–")
                                .shellCell(Self.updated)
                        }
                        .padding(.vertical, Space.xs)
                        .accessibilityIdentifier("teams-knowledge-\(row.item.id)")
                    }
                }
            } inspector: {
                inspector
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        let state = pages.content
        if case .knowledge(let server)? = pages.selection.composer, let found = state.server(server) {
            let widest = state.widestScope(on: server)
            NetworkInspector(title: "Share knowledge", serverID: server, serverName: found.name,
                             note: widest == .server ? "\(found.name) lets knowledge reach everyone on it."
                                                     : "\(found.name) lets knowledge reach \(Self.reach(widest)) at most.",
                             close: { pages.send(.closeComposer) }) {
                // A secret refusal has its own well in the form; any other refusal shows above it.
                TeamsFormBand(refusal: state.refusal.flatMap { MultiplayerSecretCheck.isRefusal($0) ? nil : $0 }) {
                    MultiplayerKnowledgeForm(draft: pages.drafts.knowledge, friends: found.friends, groups: found.groups,
                                             refusal: state.refusal.flatMap { MultiplayerSecretCheck.isRefusal($0) ? $0 : nil })
                }
            } footer: {
                Button("Cancel") { pages.send(.closeComposer) }.buttonStyle(MultiplayerTrayButtonStyle())
                Button("Share") { pages.send(.sendShare) }.buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(!pages.drafts.wrappedValue.knowledge.canSend || pages.isRunning("composer", server))
            }
        } else if let key = pages.selection.knowledge, let found = state.item(key) {
            let item = found.item
            let installing: TeamsInstallDraft? = {
                if case .install(let draft)? = pages.selection.confirming, draft.item == item.id, draft.server == found.server.id { return draft }
                return nil
            }()
            let result = pages.result("install", key), running = pages.isRunning("install", key)
            NetworkInspector(title: item.name.multiplayerDisplay, serverID: found.server.id, serverName: found.server.name,
                             state: running ? (.waiting, "Installing", .neutral) : result.map { $0.isDone ? (.on, "Done", .working) : (.error, "Not installed", .failure) },
                             note: result?.rowText, close: { pages.send(.openKnowledge(nil)) }) {
                if let installing {
                    MultiplayerBand {
                        TeamsConfirmWell(question: installing.question, target: installing.shownDestination,
                                         consequence: installing.consequence, keepTitle: installing.keepTitle,
                                         confirmTitle: installing.confirmTitle,
                                         cancel: { pages.send(.cancelConfirmation) }, confirm: { pages.send(.confirm) })
                    }
                }
                MultiplayerKnowledgeItemPage(item: item, versions: state.versions[key].map { .loaded($0) } ?? .loaded([item]),
                                             groupName: { state.groupName($0, on: found.server.id) }, now: state.now, onRetry: {})
            } footer: {
                Button("\(MultiplayerKnowledgeKind(rawValue: item.kind)?.installTitle ?? "Copy")\(MultiplayerKnowledgeKind(rawValue: item.kind) == .mcp ? "" : "…")") {
                    pages.send(.askInstall(item, server: found.server.id))
                }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(running || installing != nil)
                .accessibilityIdentifier("teams-install")
            }
            .id(key)
        } else {
            NetworkInspectorNote(text: "Choose an item to read it, see its versions and install it. Installing asks first and names where it writes.")
        }
    }

    /// The widest scope a server allows, as "… at most".
    static func reach(_ scope: MultiplayerKnowledgeScope) -> String {
        switch scope {
        case .private: "only you"
        case .friend: "one friend"
        case .group: "a group"
        case .server: "everyone on it"
        }
    }
}

// MARK: - Directory

struct TeamsDirectoryPage: View {
    @Environment(\.theme) private var theme
    let pages: TeamsPages
    @FocusState private var searching: Bool

    private static let resource = ShellColumn(title: "resource")
    private static let endorsed = ShellColumn(title: "endorsed for")
    private static let actions = ShellColumn(title: "actions", width: 52, alignment: .trailing)

    var body: some View {
        let state = pages.content
        let server = pages.selection.searchServer ?? state.servers.first?.id ?? ""
        let found = state.search?.value
        TeamsPageScaffold(place: TeamsPlace.directory, pages: pages) {
            HStack(spacing: Space.s) {
                if state.servers.count > 1 {
                    ShellSegments(options: state.servers.map { (value: $0.id, title: $0.name, help: "Search \($0.name)") },
                                  selection: server, choose: { pages.send(.chooseSearchServer($0)) })
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Server to search")
                }
                TextField("A handle, a name, a tool or an environment", text: pages.drafts.query)
                    .textFieldStyle(.plain)
                    .themeType(theme.type.body)
                    .focused($searching)
                    .themeField(focused: searching)
                    .onSubmit { pages.send(.search) }
                    .accessibilityLabel("Search the directory")
                    .accessibilityIdentifier("teams-directory-query")
                Button("Search") { pages.send(.search) }.buttonStyle(ThemeButtonStyle(prominent: true))
                    .disabled(pages.drafts.wrappedValue.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "Resources", count: found.map { "\($0.resources.count)" },
                                     note: "Only what owners chose to list.")
                    switch state.search {
                    case nil:
                        ShellNote(text: "Search \(state.serverName(server)) for a person or a listed resource.").themePanel()
                    case .loading?:
                        ShellNote(text: "Searching \(state.serverName(server))…", lamp: .waiting).themePanel()
                    case .failed(let reason)?:
                        ShellNote(text: reason, lamp: .error).themePanel()
                    case .loaded(let result)?:
                        ShellTable(columns: [Self.resource, Self.endorsed, Self.actions], items: result.resources,
                                   empty: "No listed resource matches “\(result.query)”.") { hit in
                            let key = TeamsKey.make(hit.id, on: server)
                            ShellTableRow(isSelected: pages.selection.hit == key,
                                          spoken: "\(hit.name.multiplayerDisplay), \(MultiplayerResourceKind.title(for: hit.kind)) of \(hit.handle.multiplayerDisplay), \(MultiplayerPlural.count(hit.endorsements.count, "endorsement"))",
                                          hint: "Shows how it has done", select: { pages.send(.openHit(key)) }) {
                                HStack(spacing: Space.s) {
                                    MultiplayerMark(symbol: MultiplayerResourceKind.symbol(for: hit.kind), size: 22)
                                    ShellCellText(title: hit.name.multiplayerDisplay,
                                                  detail: "\(MultiplayerResourceKind.title(for: hit.kind)), \(hit.handle.multiplayerDisplay)")
                                }
                                .shellCell(Self.resource)
                                Group {
                                    if hit.endorsements.isEmpty { ShellCellFigure(text: "–") } else {
                                        MultiplayerEndorsementChips(endorsements: hit.endorsements, limit: 2)
                                    }
                                }
                                .shellCell(Self.endorsed)
                                ShellCellFigure(text: "\(hit.actions.count)").shellCell(Self.actions)
                            }
                            .padding(.vertical, Space.xs)
                            .accessibilityIdentifier("teams-hit-\(hit.id)")
                        }
                        if !result.handles.isEmpty {
                            ShellBandHeading(title: "People", count: "\(result.handles.count)")
                            HStack(spacing: Space.s) {
                                ForEach(result.handles, id: \.self) { handle in
                                    HStack(spacing: Space.xs + 2) {
                                        MultiplayerAvatar(image: nil, name: handle.multiplayerDisplay, size: 20)
                                        ShellCellFigure(text: handle.multiplayerDisplay)
                                    }
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityAddTraits(.isStaticText)
                                    .accessibilityLabel(handle.multiplayerDisplay)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(Space.m)
                            .themePanel()
                        }
                    }
                }
            } inspector: {
                if let key = pages.selection.hit, let hit = found?.resources.first(where: { TeamsKey.make($0.id, on: server) == key }) {
                    let busy = pages.isRunning("endorse", key)
                    NetworkInspector(title: "Reputation", serverID: server, serverName: state.serverName(server),
                                     note: "An endorsement is listed with the resource.", close: { pages.send(.openHit(nil)) }) {
                        MultiplayerReputationPage(name: hit.name, owner: hit.handle, kind: hit.kind,
                                                  state: .loaded(state.reputation[key] ?? MultiplayerReputation(resource: hit.id)),
                                                  endorsements: hit.endorsements, judgeable: [], outcomes: [:],
                                                  skill: pages.drafts.skill,
                                                  canEndorse: !pages.drafts.wrappedValue.skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                                  now: state.now, isBusy: busy,
                                                  onEndorse: { pages.send(.endorse(resource: hit.id, server: server)) },
                                                  onReport: { _, _ in }, onRetry: {})
                    } footer: {
                        Button("Request access") { pages.send(.requestAccess(resource: hit.id, server: server)) }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                    }
                    .id(key)
                } else {
                    NetworkInspectorNote(text: "Choose a resource to see how its finished requests went and who vouches for it.")
                }
            }
        }
    }
}

// MARK: - Admin

/// What a policy draft changes, as the confirmation names it.
enum TeamsPolicyChange {
    static func list(_ draft: MultiplayerPolicyDraft, from saved: MultiplayerRelayPolicy) -> [(label: String, value: String)] {
        guard let next = draft.policy else { return [] }
        func scope(_ raw: String) -> String { MultiplayerKnowledgeScope(rawValue: raw)?.title ?? raw }
        func limit(_ value: Int, _ unit: String) -> String { value == 0 ? "no limit" : "\(value.formatted()) \(unit)" }
        var lines: [(String, String)] = []
        if next.knowledgeDefault != saved.knowledgeDefault {
            lines.append(("Knowledge shared by default with", "\(scope(saved.knowledgeDefault)) → \(scope(next.knowledgeDefault))"))
        }
        if next.knowledgeWidest != saved.knowledgeWidest {
            lines.append(("Widest knowledge scope", "\(scope(saved.knowledgeWidest)) → \(scope(next.knowledgeWidest))"))
        }
        if next.reputationVisibility != saved.reputationVisibility {
            func title(_ raw: String) -> String { MultiplayerReputationVisibility(rawValue: raw)?.title ?? raw }
            lines.append(("Reputation is visible to", "\(title(saved.reputationVisibility)) → \(title(next.reputationVisibility))"))
        }
        if next.directory != saved.directory {
            lines.append(("Directory search", "\(saved.directory ? "On" : "Off") → \(next.directory ? "On" : "Off")"))
        }
        if next.maxGrantDays != saved.maxGrantDays {
            lines.append(("Longest grant", "\(limit(saved.maxGrantDays, "days")) → \(limit(next.maxGrantDays, "days"))"))
        }
        if next.maxBudgetTokens != saved.maxBudgetTokens {
            lines.append(("Largest token budget", "\(limit(saved.maxBudgetTokens, "tokens")) → \(limit(next.maxBudgetTokens, "tokens"))"))
        }
        if next.retentionDays != saved.retentionDays {
            lines.append(("Keep records for", "\(saved.retentionDays) days → \(next.retentionDays) days"))
        }
        return lines
    }
}

/// The relay policy at page scale: the tray's own fields in three groups on one panel.
struct TeamsPolicyForm: View {
    @Binding var draft: MultiplayerPolicyDraft
    @FocusState private var focus: Field?

    enum Field: Hashable { case grantDays, budget, retention }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.m) {
                    MultiplayerBandHeading(title: "Knowledge") { EmptyView() }
                    MultiplayerChoice(label: "Shared by default with", options: MultiplayerKnowledgeScope.allCases, title: \.title,
                                      selection: $draft.knowledgeDefault)
                    MultiplayerField(label: "Widest scope allowed", hint: "Nobody can share knowledge more widely than this.",
                                     problem: draft.scopeProblem) {
                        MultiplayerSegments(label: "Widest scope allowed", options: MultiplayerKnowledgeScope.allCases, title: \.title,
                                            selection: $draft.knowledgeWidest)
                    }
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.m) {
                    MultiplayerBandHeading(title: "Reputation and directory") { EmptyView() }
                    MultiplayerChoice(label: "Reputation is visible to", options: MultiplayerReputationVisibility.allCases, title: \.title,
                                      selection: $draft.reputationVisibility, note: draft.reputationVisibility.explanation)
                    MultiplayerSettingRow(label: "Directory search") {
                        HStack(spacing: Space.s) {
                            Toggle("Directory search", isOn: $draft.directory).toggleStyle(MultiplayerSwitchStyle())
                            MultiplayerStateLabel(lamp: draft.directory ? .on : .off, text: draft.directory ? "On" : "Off",
                                                  tone: draft.directory ? .working : .neutral)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: "Limits") { EmptyView() }
                    number("Longest grant", unit: "days", text: $draft.maxGrantDays, field: .grantDays, problem: draft.grantDaysProblem)
                    number("Largest token budget", unit: "tokens", text: $draft.maxBudgetTokens, field: .budget, problem: draft.budgetProblem)
                    number("Keep records for", unit: "days", text: $draft.retentionDays, field: .retention, problem: draft.retentionProblem)
                    Text("0 means no limit for grants and budgets. With a budget limit, every grant must set a budget.")
                        .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .themePanel()
    }

    private func number(_ label: String, unit: String, text: Binding<String>, field: Field, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            MultiplayerSettingRow(label: label) {
                HStack(spacing: Space.s) {
                    MultiplayerTextField(label: label, placeholder: "0", text: text, monospaced: true, isFocused: focus == field)
                        .focused($focus, equals: field)
                        .frame(width: 120)
                    Text(unit).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).accessibilityHidden(true)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(MultiplayerTheme.sub)
                    .foregroundStyle(MultiplayerTheme.failure).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TeamsAdminPage: View {
    @Environment(\.theme) private var theme
    let pages: TeamsPages

    var body: some View {
        let state = pages.content
        let server = pages.selection.adminServer.flatMap(state.server) ?? state.adminServers.first
        TeamsPageScaffold(place: TeamsPlace.admin, pages: pages) {
            if let server, server.isAdmin, let saved = server.policy {
                if state.adminServers.count > 1 {
                    ShellSegments(options: state.adminServers.map { (value: $0.id, title: $0.name, help: "Administer \($0.name)") },
                                  selection: server.id, choose: { pages.send(.chooseAdminServer($0)) })
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Server to administer")
                }
                NetworkSplit {
                    policy(server, saved: saved)
                } inspector: {
                    moderation(server)
                }
                // The draft starts from the server's saved policy.
                .task(id: server.id) { if pages.selection.adminServer != server.id { pages.send(.chooseAdminServer(server.id)) } }
            } else {
                ShellLoadNote(text: "You administer no server. A relay’s admin sets its policy and moderates its members here.")
            }
        }
    }

    private func policy(_ server: TeamsPagesContent.Server, saved: MultiplayerRelayPolicy) -> some View {
        let draft = pages.drafts.wrappedValue.policy
        let changes = TeamsPolicyChange.list(draft, from: saved)
        let confirming = pages.selection.confirming == .setPolicy(server: server.id)
        let running = pages.isRunning("policy", server.id)
        return VStack(alignment: .leading, spacing: Space.s) {
            ShellBandHeading(title: "Policy", note: "What \(server.name) allows everyone on it.")
            TeamsPolicyForm(draft: pages.drafts.policy)
            HStack(spacing: Space.s) {
                if running { MultiplayerSpinner() }
                Text(draft.policy == nil ? "Fix the marked fields first."
                     : changes.isEmpty ? "Nothing is changed." : "\(MultiplayerPlural.count(changes.count, "change")) not saved.")
                    .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                Spacer(minLength: Space.s)
                Button("Set policy…") { pages.send(.askSetPolicy(server: server.id)) }
                    .buttonStyle(ThemeButtonStyle(prominent: true, compact: true))
                    .disabled(changes.isEmpty || confirming || running)
                    .accessibilityIdentifier("teams-set-policy")
            }
            if confirming {
                TeamsConfirmWell(question: "Set this policy on \(server.name)?", changes: changes,
                                 consequence: "It applies to everyone on \(server.name) at once. Grants and knowledge that already exist are not changed.",
                                 keepTitle: "Keep current policy", confirmTitle: "Set policy on \(server.name)",
                                 cancel: { pages.send(.cancelConfirmation) }, confirm: { pages.send(.confirm) })
            }
        }
        .frame(maxWidth: TeamsLayout.rowPanel, alignment: .leading)
    }

    private func moderation(_ server: TeamsPagesContent.Server) -> some View {
        let state = pages.content
        let members = state.memberRows(on: server.id)
        return NetworkInspector(title: "Members and devices", serverID: server.id, serverName: server.name,
                                note: "Each of these asks first and names who or what it cuts off.") {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Members", count: "\(members.count)") { EmptyView() }
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { ThemeRule() }
                        memberRow(row, server: server)
                    }
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Devices", count: "\(server.devices.count)") { EmptyView() }
                    if server.devices.isEmpty {
                        Text("No device is signed in.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                    ForEach(Array(server.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { ThemeRule() }
                        deviceRow(device, server: server)
                    }
                }
            }
        }
    }

    @ViewBuilder private func memberRow(_ row: TeamsMemberRow, server: TeamsPagesContent.Server) -> some View {
        let member = row.member, name = member.handle.multiplayerDisplay
        let confirming = pages.selection.confirming == .suspend(handle: member.handle, server: server.id)
        HStack(spacing: Space.s) {
            MultiplayerAvatar(image: nil, name: name, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs + 2) {
                    Text(name).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground).lineLimit(1)
                    if row.isYou { MultiplayerBadge(text: "You") }
                    if member.isAdmin { MultiplayerBadge(text: "Admin", tone: .focus) }
                }
                MultiplayerStateLabel(lamp: member.isSuspended ? .error : .on, text: member.isSuspended ? "Suspended" : "Active",
                                      tone: member.isSuspended ? .failure : .working)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(name), \(member.isSuspended ? "suspended" : "active")\(member.isAdmin ? ", admin" : "")")
            Spacer(minLength: Space.s)
            if row.isRunning {
                MultiplayerSpinner().accessibilityLabel("In progress")
            } else if member.isSuspended {
                Button("Unsuspend") { pages.send(.unsuspend(member.handle, server: server.id)) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .accessibilityLabel("Unsuspend \(name)")
            } else if !row.isYou {
                Button("Suspend…") { pages.send(.askSuspend(member.handle, server: server.id)) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .danger)).disabled(confirming)
                    .accessibilityLabel("Suspend \(name)")
            }
        }
        .frame(minHeight: 40)
        .accessibilityIdentifier("teams-member-\(member.handle)")
        if confirming {
            MultiplayerInlineConfirm(message: "Suspend \(name) on \(server.name)? Every device of theirs is cut off from this relay until you unsuspend them, and they leave the directory.",
                                     keepTitle: "Keep member", confirmTitle: "Suspend \(name)", isBusy: row.isRunning,
                                     onCancel: { pages.send(.cancelConfirmation) }, onConfirm: { pages.send(.confirm) })
                .padding(.bottom, Space.xs + 2)
        }
    }

    @ViewBuilder private func deviceRow(_ device: TeamsDevice, server: TeamsPagesContent.Server) -> some View {
        let confirming = pages.selection.confirming == .revokeDevice(device: device.id, server: server.id)
        let running = pages.isRunning("device", TeamsKey.make(device.id, on: server.id))
        let name = device.name.multiplayerDisplay
        HStack(spacing: Space.s) {
            MultiplayerMark(symbol: "laptopcomputer", size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground).lineLimit(1)
                Text("\(device.owner.multiplayerDisplay), \(device.id.multiplayerDisplay)\(device.lastSeen.map { ", seen \(MultiplayerTime.display($0, now: pages.content.now))" } ?? "")")
                    .font(MultiplayerTheme.fingerprint).foregroundStyle(.inkSecondary).lineLimit(1).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.s)
            if running {
                MultiplayerSpinner().accessibilityLabel("In progress")
            } else {
                Button("Revoke…") { pages.send(.askRevoke(device.id, server: server.id)) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .danger)).disabled(confirming)
                    .accessibilityLabel("Revoke \(name)")
            }
        }
        .frame(minHeight: 40)
        if confirming {
            MultiplayerInlineConfirm(message: "Revoke \(name), \(device.owner.multiplayerDisplay)’s device, on \(server.name)? It is signed out of this relay at once, and its owner has to sign in on it again.",
                                     keepTitle: "Keep device", confirmTitle: "Revoke \(name)", isBusy: running,
                                     onCancel: { pages.send(.cancelConfirmation) }, onConfirm: { pages.send(.confirm) })
                .padding(.bottom, Space.xs + 2)
        }
    }
}

// MARK: - The page for a place

/// The full-size page for a Teams place.
struct TeamsPageView: View {
    let place: String
    let pages: TeamsPages

    var body: some View {
        switch place {
        case TeamsPlace.groups: TeamsGroupsPage(pages: pages)
        case TeamsPlace.hosts: TeamsHostsPage(pages: pages)
        case TeamsPlace.knowledge: TeamsKnowledgePage(pages: pages)
        case TeamsPlace.directory: TeamsDirectoryPage(pages: pages)
        case TeamsPlace.admin: TeamsAdminPage(pages: pages)
        default: TeamsWorkspacePage(place: place, pages: pages)
        }
    }
}
