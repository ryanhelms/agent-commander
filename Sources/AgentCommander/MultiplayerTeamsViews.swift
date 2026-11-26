import AppKit
import SwiftUI

// ATOMIC LEVEL: Molecules, organisms and pages for teams (increment 5), in the tray's language
// (DESIGN.md). Every colour, face, radius and duration comes from `MultiplayerTheme`.
//   Molecules:  MultiplayerInlineConfirm, MultiplayerStateTally, MultiplayerClaimRow, MultiplayerCardRow,
//               MultiplayerQueueRow, MultiplayerEndorsementChips, MultiplayerOutputWell
//   Organisms:  MultiplayerTeamsBand, MultiplayerGroupsBand, MultiplayerServerTeamsBand
//   Pages:      groups, group, workspaces, new workspace, workspace (combined), claim, card, queue a
//               branch, hosts, run on host, knowledge library, share knowledge, knowledge item,
//               reputation, directory search, relay policy
// Each takes values and emits actions; MultiplayerPanel wires them to MultiplayerTeamsModel.

// MARK: - Molecules

/// The second press before something that can't be undone, stating what goes with it.
struct MultiplayerInlineConfirm: View {
    let message: String
    let keepTitle: String
    let confirmTitle: String
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        MultiplayerWell(edge: MultiplayerTheme.failure) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(keepTitle, action: onCancel).buttonStyle(MultiplayerTrayButtonStyle())
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                        .disabled(isBusy)
                }
            }
        }
        .multiplayerArriving()
    }
}

/// Counts by state as joined cells that also filter: "open 3 | claimed 1 | done 4".
struct MultiplayerStateTally<Option: Hashable>: View {
    struct Cell {
        let option: Option
        let title: String
        let count: Int
        var tone: Tone = .neutral
    }

    let label: String
    let cells: [Cell]
    @Binding var selection: Option

    @Environment(\.theme) private var theme
    var body: some View {
        let shape = theme.trayControl
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.option) { index, cell in
                let isOn = cell.option == selection
                if index > 0 { Rectangle().fill(MultiplayerTheme.border).frame(width: 1) }
                Button { selection = cell.option } label: {
                    HStack(spacing: 6) {
                        Text(cell.title).font(MultiplayerTheme.data)
                        Text("\(cell.count)")
                            .font(MultiplayerTheme.data.monospacedDigit())
                            .multiplayerTicking(cell.count)
                            .foregroundStyle(isOn ? MultiplayerTheme.onAccent
                                                  : cell.tone == .neutral || cell.count == 0 ? MultiplayerTheme.foreground : cell.tone.color)
                    }
                    .foregroundStyle(isOn ? AnyShapeStyle(MultiplayerTheme.onAccent) : AnyShapeStyle(.inkSecondary))
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(isOn ? MultiplayerTheme.focus : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MultiplayerRowButtonStyle())
                .accessibilityLabel("\(cell.title), \(cell.count)")
                .accessibilityValue(isOn ? "Selected" : "")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.border) }
        .animation(MultiplayerTheme.Motion.ease(MultiplayerTheme.Motion.fast), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Who holds what: the kind, the key as data, the holder as person and agent, and when it lapses.
struct MultiplayerClaimRow: View {
    let claim: MultiplayerClaim
    /// What the key names, when the page knows: a claimed card's title.
    var title: String? = nil
    let isMine: Bool
    let now: Date
    let isBusy: Bool
    /// Release is waiting for its second press.
    var isConfirming = false
    /// Asks to release; nothing is sent until `onConfirm`.
    let onRelease: () -> Void
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}

    private var name: String { (title ?? claim.key).multiplayerDisplay }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row
            if isConfirming {
                MultiplayerInlineConfirm(message: "Release \(name)? \(claim.holderAgent.isEmpty ? "Your agent" : claim.holderAgent.multiplayerDisplay) loses its hold, and anyone in the group can claim it.",
                                         keepTitle: "Keep claim", confirmTitle: "Release claim", isBusy: isBusy,
                                         onCancel: onCancel, onConfirm: onConfirm)
            }
        }
        .padding(.vertical, 5)
        .multiplayerArriving()
    }

    private var row: some View {
        HStack(spacing: Space.s) {
            MultiplayerMark(symbol: claim.symbol, tone: isMine ? .focus : .neutral, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text((title ?? claim.key).multiplayerDisplay)
                    .font(title == nil ? MultiplayerTheme.data : MultiplayerTheme.name)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    Text(claim.holderHandle.multiplayerDisplay).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    if !claim.holderAgent.isEmpty {
                        MultiplayerBadge(text: claim.holderAgent.multiplayerDisplay, symbol: "terminal")
                    }
                    if let expires = claim.expiresAt {
                        Text("until \(MultiplayerActivityRow.time(expires, now: now))")
                            .font(MultiplayerTheme.fingerprint)
                            .foregroundStyle(.inkSecondary)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(claim.kindTitle) \((title ?? claim.key).multiplayerDisplay), held by \(claim.holderHandle.multiplayerDisplay)\(claim.holderAgent.isEmpty ? "" : " for \(claim.holderAgent.multiplayerDisplay)")")
            if isMine {
                Button("Release…", action: onRelease)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(isBusy || isConfirming)
                    .accessibilityLabel("Release \(name)")
            } else {
                MultiplayerStateLabel(lamp: .busy, text: "Held", tone: .attention)
            }
        }
    }
}

/// One card of the board: its state as a lamp and a word, its title, who has it, and the one step
/// that moves it on. The text opens the card.
struct MultiplayerCardRow: View {
    let card: MultiplayerCard
    /// The person holds this card's claim.
    let isMine: Bool
    let isBusy: Bool
    let onOpen: () -> Void
    let onClaim: () -> Void

    var body: some View {
        let state = card.known
        HStack(spacing: Space.s) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title.multiplayerDisplay)
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        MultiplayerStateLabel(lamp: state.lamp, text: state.title, tone: state.tone)
                        if !card.assignee.isEmpty {
                            Text(card.assignee.multiplayerDisplay)
                                .font(MultiplayerTheme.fingerprint)
                                .foregroundStyle(isMine ? AnyShapeStyle(MultiplayerTheme.focus) : AnyShapeStyle(.inkSecondary))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(state == .open ? MultiplayerTheme.border : state.tone.color).frame(width: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MultiplayerRowButtonStyle())
            .accessibilityLabel("\(card.title.multiplayerDisplay), \(state.title)\(card.assignee.isEmpty ? "" : ", \(card.assignee.multiplayerDisplay)")")
            .accessibilityHint("Opens the card")
            if state == .open {
                Button("Claim", action: onClaim)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(isBusy)
                    .accessibilityLabel("Claim \(card.title.multiplayerDisplay)")
            } else if state == .claimed, isMine {
                Button("Complete…", action: onOpen)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .accessibilityLabel("Complete \(card.title.multiplayerDisplay)")
            }
        }
        .multiplayerArriving()
    }
}

/// The end of a command's or a test run's output, read closely.
struct MultiplayerOutputWell: View {
    let text: String
    var tone: Tone = .neutral
    var lines = 12

    var body: some View {
        MultiplayerWell(edge: tone == .neutral ? MultiplayerTheme.hair : tone.color.opacity(0.45)) {
            ScrollView(.vertical) {
                Text(text.isEmpty ? "No output." : text)
                    .font(MultiplayerTheme.mono)
                    .foregroundStyle(text.isEmpty ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(MultiplayerTheme.foreground))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: CGFloat(lines) * 15)
            .defaultScrollAnchor(.bottom)
        }
        .accessibilityLabel("Output")
    }
}

/// A branch's place in the merge queue, its state, and what stopped it when something did.
struct MultiplayerQueueRow: View {
    let position: Int
    let entry: MultiplayerQueueEntry
    let now: Date
    var isBusy = false
    /// Remove is waiting for its second press.
    var isConfirming = false
    /// Asks to take the branch out of the queue. Nil hides the action.
    var onRemove: (() -> Void)? = nil
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Text("\(position)")
                        .font(MultiplayerTheme.label)
                        .foregroundStyle(.inkSecondary)
                        .frame(width: 22, height: 22)
                        .background(MultiplayerTheme.well)
                        .overlay { Rectangle().strokeBorder(MultiplayerTheme.border) }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.branch.multiplayerDisplay)
                            .font(MultiplayerTheme.data)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(entry.test.isEmpty ? "no test command" : entry.test.joined(separator: " ").multiplayerDisplay)
                            .font(MultiplayerTheme.fingerprint)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    MultiplayerStateLabel(lamp: entry.lamp, text: entry.stateTitle, tone: entry.tone)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(position). \(entry.branch.multiplayerDisplay), \(entry.stateTitle)")
                .frame(maxWidth: .infinity, alignment: .leading)
                if let onRemove {
                    Button("Remove…", action: onRemove)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(isBusy || isConfirming)
                        .accessibilityLabel("Remove \(entry.branch.multiplayerDisplay) from the merge queue")
                }
            }
            if !entry.output.isEmpty, !entry.isQueued, entry.state != "merged" {
                MultiplayerOutputWell(text: entry.output, tone: .failure, lines: 6)
            }
            if isConfirming {
                MultiplayerInlineConfirm(message: "Remove \(entry.branch.multiplayerDisplay) from the queue? "
                                             + (entry.isQueued ? "It won’t be tested or merged." : "Its result and output are cleared from this Mac.")
                                             + " The branch itself stays.",
                                         keepTitle: "Keep in queue", confirmTitle: "Remove from queue", isBusy: isBusy,
                                         onCancel: onCancel, onConfirm: onConfirm)
            }
        }
        .padding(.vertical, 5)
        .multiplayerArriving()
    }
}

/// One open pull request: its number and branch as data, its title, and who opened it. The row opens
/// the pull request on its host.
struct MultiplayerPullRequestRow: View {
    let pullRequest: MultiplayerPullRequest
    let onOpen: (URL) -> Void

    var body: some View {
        if let link = pullRequest.link {
            Button { onOpen(link) } label: { content(opens: true) }
                .buttonStyle(MultiplayerRowButtonStyle())
                .help(link.absoluteString)
                .accessibilityLabel(pullRequest.spoken)
                .accessibilityHint("Opens the pull request in your browser")
                .multiplayerArriving()
        } else {
            content(opens: false)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(pullRequest.spoken)
                .multiplayerArriving()
        }
    }

    private func content(opens: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(pullRequest.reference)
                .font(MultiplayerTheme.data)
                .foregroundStyle(.inkSecondary)
                .lineLimit(1)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(pullRequest.title.isEmpty ? "Untitled" : pullRequest.title.multiplayerDisplay)
                    .font(MultiplayerTheme.name)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if !pullRequest.branch.isEmpty {
                        Text(pullRequest.branch.multiplayerDisplay)
                            .font(MultiplayerTheme.fingerprint)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                    }
                    if !pullRequest.author.isEmpty {
                        Text(pullRequest.author.multiplayerDisplay)
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                Image(systemName: "arrow.up.right")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Skills people vouch for, each with how many did.
struct MultiplayerEndorsementChips: View {
    let endorsements: [MultiplayerEndorsement]
    var limit = 4

    var body: some View {
        let tally = MultiplayerEndorsement.tally(endorsements)
        if !tally.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(tally.prefix(limit).enumerated()), id: \.offset) { _, entry in
                    MultiplayerBadge(text: entry.count > 1 ? "\(entry.skill.multiplayerDisplay) ×\(entry.count)" : entry.skill.multiplayerDisplay,
                                     symbol: "checkmark.seal", tone: .working)
                }
                if tally.count > limit {
                    Text("+\(tally.count - limit)").font(MultiplayerTheme.label).foregroundStyle(.inkSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("Endorsed for \(tally.map { $0.count > 1 ? "\($0.skill), by \($0.count)" : $0.skill }.formatted(.list(type: .and)))")
        }
    }
}

private func teamsNote(_ text: String) -> some View {
    Text(text)
        .font(MultiplayerTheme.sub)
        .foregroundStyle(.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Organisms

/// Teams on the Agents tab: the workspaces you work in, then the ways into hosts and the library.
struct MultiplayerTeamsBand: View {
    let workspaces: [MultiplayerPending<MultiplayerWorkspace>]
    let hostCount: Int
    let knowledgeCount: Int
    /// The person's handle on a server, to mark their own claims.
    let handle: (String) -> String
    let serverName: (String) -> String
    /// Servers a workspace can be made on. Empty hides the action.
    let servers: [MultiplayerServerSummary]
    let onOpen: (MultiplayerPending<MultiplayerWorkspace>) -> Void
    let onNew: (String) -> Void
    let onHosts: (String) -> Void
    let onKnowledge: (String) -> Void

    var body: some View {
        if !servers.isEmpty {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Workspaces", count: workspaces.isEmpty ? nil : "\(workspaces.count)") {
                        serverAction("New…", symbol: "plus", label: "New workspace", perform: onNew)
                    }
                    if workspaces.isEmpty {
                        teamsNote("A workspace is a goal, a repository and a group. Members claim parts of it so two agents never take the same work.")
                            .padding(.vertical, Space.xs)
                    }
                    ForEach(workspaces) { entry in
                        let mine = entry.item.claims.filter { $0.isHeld(by: handle(entry.server)) }.count
                        Button { onOpen(entry) } label: {
                            HStack(spacing: Space.s) {
                                MultiplayerMark(symbol: "square.stack.3d.up", tone: mine > 0 ? .focus : .neutral)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.item.name.multiplayerDisplay)
                                        .font(MultiplayerTheme.name)
                                        .foregroundStyle(MultiplayerTheme.foreground)
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        MultiplayerSwatch(color: MultiplayerTheme.swatch(for: entry.server))
                                        Text("\(serverName(entry.server)), \(entry.item.goal.multiplayerDisplay)")
                                            .font(MultiplayerTheme.sub)
                                            .foregroundStyle(.inkSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                let count = entry.item.claims.count
                                MultiplayerStateLabel(lamp: count > 0 ? .busy : .off,
                                                      text: MultiplayerPlural.count(count, "claim"),
                                                      tone: count > 0 ? .attention : .neutral)
                            }
                            .frame(minHeight: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MultiplayerRowButtonStyle())
                        .multiplayerArriving()
                        .accessibilityLabel("\(entry.item.name.multiplayerDisplay) on \(serverName(entry.server)), \(MultiplayerPlural.count(entry.item.claims.count, "claim"))")
                        .accessibilityHint("Opens the workspace")
                    }
                    Rectangle().fill(MultiplayerTheme.hair).frame(height: 1).padding(.top, 4)
                    serverLink(symbol: "cpu", title: "Hosts", caption: "Hardware lent to run enrolled commands",
                               count: hostCount, perform: onHosts)
                    serverLink(symbol: "books.vertical", title: "Knowledge library",
                               caption: "Prompts, skills, instructions and MCP settings", count: knowledgeCount,
                               perform: onKnowledge)
                }
                .multiplayerStreaming(workspaces.map(\.id))
            }
        }
    }

    /// A band action that acts on a server: a button with one server, a menu with several.
    @ViewBuilder private func serverAction(_ title: String, symbol: String, label: String,
                                           perform: @escaping (String) -> Void) -> some View {
        if servers.count == 1 {
            Button { perform(servers[0].id) } label: { Label(title, systemImage: symbol) }
                .buttonStyle(MultiplayerTrayButtonStyle())
                .accessibilityLabel(label)
        } else {
            Menu {
                ForEach(servers) { server in Button("On \(server.displayName)") { perform(server.id) } }
            } label: { Label(title, systemImage: symbol) }
            .menuStyle(.button)
            .buttonStyle(MultiplayerTrayButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
        }
    }

    @ViewBuilder private func serverLink(symbol: String, title: String, caption: String, count: Int,
                                         perform: @escaping (String) -> Void) -> some View {
        if servers.count == 1 {
            MultiplayerLinkRow(symbol: symbol, title: title, caption: caption, count: count) { perform(servers[0].id) }
        } else {
            Menu {
                ForEach(servers) { server in Button("On \(server.displayName)") { perform(server.id) } }
            } label: {
                MultiplayerLinkRow(symbol: symbol, title: title, caption: caption, count: count) {}
                    .allowsHitTesting(false)
            }
            .menuStyle(.button)
            .buttonStyle(MultiplayerRowButtonStyle())
            .menuIndicator(.hidden)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(count > 0 ? "\(title), \(count). \(caption)" : "\(title). \(caption)")
        }
    }
}

/// Groups on the People tab: each with its members, and the way to make one.
struct MultiplayerGroupsBand: View {
    let groups: [MultiplayerPending<MultiplayerGroup>]
    let handle: (String) -> String
    let serverName: (String) -> String
    let servers: [MultiplayerServerSummary]
    let onOpen: (MultiplayerPending<MultiplayerGroup>) -> Void
    let onManage: (String) -> Void

    var body: some View {
        if !servers.isEmpty {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Groups", count: groups.isEmpty ? nil : "\(groups.count)") {
                        if servers.count == 1 {
                            Button { onManage(servers[0].id) } label: { Label("New…", systemImage: "plus") }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .accessibilityLabel("New group")
                        } else {
                            Menu {
                                ForEach(servers) { server in Button("On \(server.displayName)") { onManage(server.id) } }
                            } label: { Label("New…", systemImage: "plus") }
                            .menuStyle(.button)
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("New group")
                        }
                    }
                    if groups.isEmpty {
                        teamsNote("Name a group of friends, then share a resource with all of them at once.")
                            .padding(.vertical, Space.xs)
                    }
                    ForEach(groups) { entry in
                        MultiplayerGroupRow(group: entry.item, isOwner: entry.item.isOwned(by: handle(entry.server)),
                                            color: MultiplayerTheme.swatch(for: entry.server),
                                            serverName: serverName(entry.server)) { onOpen(entry) }
                    }
                }
                .multiplayerStreaming(groups.map(\.id))
            }
        }
    }
}

/// A group: its name, how many are in it, the first few of them, and whether it is yours.
struct MultiplayerGroupRow: View {
    let group: MultiplayerGroup
    let isOwner: Bool
    var color: Color? = nil
    var serverName: String? = nil
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Space.s) {
                // People are round: the first members overlap, as a group does.
                HStack(spacing: -8) {
                    ForEach(Array(group.members.prefix(3).enumerated()), id: \.offset) { _, member in
                        MultiplayerAvatar(image: nil, name: member, size: 22)
                    }
                }
                .frame(width: 50, alignment: .leading)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name.multiplayerDisplay)
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let color { MultiplayerSwatch(color: color) }
                        Text([serverName, group.memberTitle].compactMap { $0 }.joined(separator: ", "))
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MultiplayerBadge(text: isOwner ? "Owner" : "Member", tone: isOwner ? .focus : .neutral)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(MultiplayerRowButtonStyle())
        .multiplayerArriving()
        .accessibilityLabel("\(group.name.multiplayerDisplay), \(group.memberTitle), you are \(isOwner ? "the owner" : "a member")")
        .accessibilityHint("Opens the group")
    }
}

/// One server's ways into teams, on the server's own page.
struct MultiplayerServerTeamsBand: View {
    let groupCount: Int
    let workspaceCount: Int
    let hostCount: Int
    let knowledgeCount: Int
    let isAdmin: Bool
    let onGroups: () -> Void
    let onWorkspaces: () -> Void
    let onHosts: () -> Void
    let onKnowledge: () -> Void
    let onSearch: () -> Void
    let onPolicy: () -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 0) {
                MultiplayerBandHeading(title: "Teams")
                MultiplayerLinkRow(symbol: "person.3", title: "Groups", caption: "Named groups of friends you can share with",
                                   count: groupCount, action: onGroups)
                MultiplayerLinkRow(symbol: "square.stack.3d.up", title: "Workspaces",
                                   caption: "Shared goals, claims and the task board", count: workspaceCount, action: onWorkspaces)
                MultiplayerLinkRow(symbol: "cpu", title: "Hosts", caption: "Hardware lent to run enrolled commands",
                                   count: hostCount, action: onHosts)
                MultiplayerLinkRow(symbol: "books.vertical", title: "Knowledge library",
                                   caption: "Prompts, skills, instructions and MCP settings", count: knowledgeCount,
                                   action: onKnowledge)
                MultiplayerLinkRow(symbol: "magnifyingglass", title: "Directory search",
                                   caption: "People and the resources their owners listed", action: onSearch)
                if isAdmin {
                    MultiplayerLinkRow(symbol: "slider.horizontal.3", title: "Relay policy",
                                       caption: "Sharing limits, retention, members and devices", action: onPolicy)
                }
            }
        }
    }
}

// MARK: - Groups

/// Every group on a server, and the field that makes a new one.
struct MultiplayerGroupsPage: View {
    let groups: [MultiplayerGroup]
    let handle: String
    @Binding var draft: String
    let canCreate: Bool
    let onCreate: () -> Void
    let onOpen: (MultiplayerGroup) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        MultiplayerBand {
            MultiplayerField(label: "New group", hint: "You own the groups you create. Only friends can be added.") {
                HStack(spacing: 6) {
                    MultiplayerTextField(label: "Group name", placeholder: "relay-team", text: $draft, isFocused: focused)
                        .focused($focused)
                        .onSubmit { if canCreate { onCreate() } }
                    Button("Create group", action: onCreate)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary, large: true))
                        .disabled(!canCreate)
                }
            }
        }
        MultiplayerSection(title: "Groups", count: groups.count) {
            if groups.isEmpty { teamsNote("No groups on this server yet.").padding(.vertical, Space.xs) }
            ForEach(groups) { group in
                MultiplayerGroupRow(group: group, isOwner: group.isOwned(by: handle)) { onOpen(group) }
            }
        }
    }
}

/// One group: its members, the friends who can join it, and what a grant to it means.
struct MultiplayerGroupPage: View {
    let group: MultiplayerGroup
    let handle: String
    let addable: [MultiplayerFriend]
    let isBusy: Bool
    let confirmingDelete: Bool
    /// The member whose Remove is waiting for its second press.
    var confirmingRemoval: String? = nil
    let onAdd: (String) -> Void
    /// Asks to remove a member; nothing is sent until `onConfirmRemove`.
    let onRemove: (String) -> Void
    var onConfirmRemove: (String) -> Void = { _ in }
    let onCancelDelete: () -> Void
    let onConfirmDelete: () -> Void

    private var isOwner: Bool { group.isOwned(by: handle) }

    /// What deleting a group takes with it. One member takes the singular verb.
    static func deleteQuestion(_ group: MultiplayerGroup) -> String {
        "Delete \(group.name.multiplayerDisplay)? Its \(group.memberTitle) \(group.members.count == 1 ? "loses" : "lose") every grant made to the group."
    }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Text(group.name.multiplayerDisplay).font(MultiplayerTheme.title).foregroundStyle(MultiplayerTheme.foreground)
                    MultiplayerBadge(text: isOwner ? "Owner" : "Member", tone: isOwner ? .focus : .neutral)
                    Spacer(minLength: 0)
                    MultiplayerHashChip(label: "ID", hash: group.id, onCopy: { MultiplayerHashChip.copy($0) })
                }
                teamsNote(isOwner ? "A grant to this group reaches every member. People you add later get it, and people you remove lose it."
                                  : "\(group.owner.multiplayerDisplay) owns this group and decides who is in it.")
                if confirmingDelete {
                    MultiplayerInlineConfirm(message: Self.deleteQuestion(group),
                                             keepTitle: "Keep group", confirmTitle: "Delete group", isBusy: isBusy,
                                             onCancel: onCancelDelete, onConfirm: onConfirmDelete)
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Members", count: "\(group.members.count)") {
                    if isOwner {
                        Menu {
                            ForEach(addable) { friend in
                                Button(friend.handle.multiplayerDisplay) { onAdd(friend.handle) }
                            }
                        } label: { Label("Add friend", systemImage: "plus") }
                        .menuStyle(.button)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(isBusy || addable.isEmpty)
                        .help(addable.isEmpty ? "Every friend on this server is already in the group" : "Add a friend to the group")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Add a friend to \(group.name.multiplayerDisplay)")
                    }
                }
                ForEach(Array(group.members.enumerated()), id: \.element) { index, member in
                    if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                    HStack(spacing: Space.s) {
                        MultiplayerAvatar(image: nil, name: member.multiplayerDisplay, size: 24)
                        Text(member.multiplayerDisplay)
                            .font(MultiplayerTheme.name)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .lineLimit(1)
                        if member == group.owner { MultiplayerBadge(text: "Owner", tone: .focus) }
                        if member == handle { MultiplayerBadge(text: "You") }
                        Spacer(minLength: 0)
                        if isOwner, member != group.owner {
                            Button("Remove…") { onRemove(member) }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(isBusy || confirmingRemoval == member)
                                .accessibilityLabel("Remove \(member.multiplayerDisplay) from \(group.name.multiplayerDisplay)")
                        }
                    }
                    .frame(minHeight: 34)
                    .multiplayerArriving()
                    if confirmingRemoval == member {
                        MultiplayerInlineConfirm(message: "Remove \(member.multiplayerDisplay) from \(group.name.multiplayerDisplay)? They lose every grant made to the group.",
                                                 keepTitle: "Keep member", confirmTitle: "Remove member", isBusy: isBusy,
                                                 onCancel: onCancelDelete, onConfirm: { onConfirmRemove(member) })
                            .padding(.bottom, 6)
                    }
                }
            }
            .multiplayerStreaming(group.members + [confirmingRemoval ?? ""])
        }
    }
}

// MARK: - Workspaces

struct MultiplayerWorkspacesPage: View {
    let workspaces: [MultiplayerWorkspace]
    let handle: String
    let groupName: (String) -> String
    let onOpen: (MultiplayerWorkspace) -> Void

    var body: some View {
        MultiplayerSection(title: "Workspaces", count: workspaces.count) {
            if workspaces.isEmpty {
                teamsNote("No workspace on this server yet. A workspace is a goal, a repository, a base branch and the group that works on it.")
                    .padding(.vertical, Space.xs)
            }
            ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                Button { onOpen(workspace) } label: {
                    HStack(spacing: Space.s) {
                        MultiplayerMark(symbol: "square.stack.3d.up",
                                        tone: workspace.claims.contains { $0.isHeld(by: handle) } ? .focus : .neutral)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name.multiplayerDisplay).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                            Text("\(groupName(workspace.group).multiplayerDisplay), \(MultiplayerIntegration.title(for: workspace.integration).lowercasedFirst)")
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(.inkSecondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        let count = workspace.claims.count
                        MultiplayerStateLabel(lamp: count > 0 ? .busy : .off, text: MultiplayerPlural.count(count, "claim"),
                                              tone: count > 0 ? .attention : .neutral)
                    }
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MultiplayerRowButtonStyle())
                .accessibilityLabel("\(workspace.name.multiplayerDisplay), \(MultiplayerPlural.count(workspace.claims.count, "claim"))")
                .accessibilityHint("Opens the workspace")
            }
        }
    }
}

struct MultiplayerWorkspaceForm: View {
    @Binding var draft: MultiplayerWorkspaceDraft
    let groups: [MultiplayerGroup]
    @FocusState private var focus: Field?

    enum Field: Hashable { case name, goal, repository, base }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                MultiplayerField(label: "Group", hint: groups.isEmpty ? "Create a group first. Its members are the workspace’s members." : nil) {
                    MultiplayerMenuField(label: "Group", placeholder: "Choose a group",
                                         options: groups.map { ($0.id, "\($0.name.multiplayerDisplay), \($0.memberTitle)") },
                                         selection: $draft.group)
                }
                MultiplayerField(label: "Name") {
                    MultiplayerTextField(label: "Name", placeholder: "Relay reconnect", text: $draft.name, isFocused: focus == .name)
                        .focused($focus, equals: .name)
                }
                MultiplayerField(label: "Goal", hint: "One line every member and agent reads first.") {
                    MultiplayerTextField(label: "Goal", placeholder: "Make reconnects survive a lease renewal", text: $draft.goal,
                                         isFocused: focus == .goal)
                        .focused($focus, equals: .goal)
                }
                MultiplayerField(label: "Repository", hint: "Only this name is kept on the relay. Code never crosses it.") {
                    MultiplayerTextField(label: "Repository", placeholder: "github.com/owner/name", text: $draft.repository,
                                         monospaced: true, isFocused: focus == .repository)
                        .focused($focus, equals: .repository)
                }
                MultiplayerField(label: "Base branch") {
                    MultiplayerTextField(label: "Base branch", placeholder: "main", text: $draft.base, monospaced: true,
                                         isFocused: focus == .base)
                        .focused($focus, equals: .base)
                        .frame(width: 160)
                }
                MultiplayerChoice(label: "Work lands through", options: MultiplayerIntegration.allCases, title: \.title,
                                  selection: $draft.integration, note: draft.integration.explanation)
            }
        }
        .onAppear { focus = .name }
    }
}

/// The combined view of one workspace: what it is for, who has claimed what, the board, and how
/// work lands.
struct MultiplayerWorkspacePage: View {
    let workspace: MultiplayerWorkspace
    let group: MultiplayerGroup?
    let handle: String
    let cards: MultiplayerLoad<[MultiplayerCard]>
    let queue: [MultiplayerQueueEntry]
    /// The repository's open pull requests, read while a pull-request workspace's page is open.
    var pullRequests: MultiplayerLoad<MultiplayerPullRequestList> = .loading
    @Binding var cardDraft: MultiplayerCardDraft
    let canAddCard: Bool
    let now: Date
    let isBusy: Bool
    /// The destructive step waiting for its second press, when it is one of this page's.
    var confirming: MultiplayerTeamsConfirmation? = nil
    let onClaim: () -> Void
    /// Asks to release a claim; nothing is sent until `onConfirmRelease`.
    let onRelease: (MultiplayerClaim) -> Void
    var onConfirmRelease: (MultiplayerClaim) -> Void = { _ in }
    /// Asks to take a branch out of the merge queue. Nil hides the action.
    var onRemoveQueued: ((MultiplayerQueueEntry) -> Void)? = nil
    var onConfirmRemoveQueued: (MultiplayerQueueEntry) -> Void = { _ in }
    var onCancelConfirmation: () -> Void = {}
    let onAddCard: () -> Void
    let onOpenCard: (MultiplayerCard) -> Void
    let onClaimCard: (MultiplayerCard) -> Void
    let onQueueAdd: () -> Void
    let onRunQueue: () -> Void
    let onRetryCards: () -> Void
    var onRetryPullRequests: () -> Void = {}
    var onOpenLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @State private var filter = MultiplayerCard.State.open
    @FocusState private var cardFocused: Bool

    private var all: [MultiplayerCard] { cards.value ?? [] }

    private func count(_ state: MultiplayerCard.State) -> Int { all.filter { $0.known == state }.count }

    private var boardCells: [MultiplayerStateTally<MultiplayerCard.State>.Cell] {
        MultiplayerCard.State.allCases.map { .init(option: $0, title: $0.title.lowercased(), count: count($0), tone: $0.tone) }
    }

    var body: some View {
        telemetry
        summary
        claimsBand
        boardBand
        if workspace.usesQueue { queueBand } else { pullRequestBand }
    }

    private var telemetry: some View {
        MultiplayerStatusStrip(cells: [
            MultiplayerReadout(id: "claims", label: "claims", value: "\(workspace.claims.count)",
                               lamp: workspace.claims.isEmpty ? .off : .busy,
                               tone: workspace.claims.isEmpty ? .neutral : .attention),
            MultiplayerReadout(id: "open", label: "open", value: "\(count(.open))"),
            MultiplayerReadout(id: "claimed", label: "claimed", value: "\(count(.claimed))",
                               tone: count(.claimed) > 0 ? .attention : .neutral),
            MultiplayerReadout(id: "done", label: "done", value: "\(count(.done))", tone: count(.done) > 0 ? .working : .neutral),
        ])
    }

    private var summary: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(workspace.goal.multiplayerDisplay)
                    .font(MultiplayerTheme.body)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    MultiplayerSummaryLine(label: "Repository", value: workspace.repository, monospaced: true)
                    MultiplayerSummaryLine(label: "Base", value: workspace.base, monospaced: true)
                    MultiplayerSummaryLine(label: "Group", value: group.map { "\($0.name), \($0.memberTitle)" } ?? workspace.group)
                    MultiplayerSummaryLine(label: "Lands by", value: MultiplayerIntegration.title(for: workspace.integration))
                }
                MultiplayerHashChip(label: "ID", hash: workspace.id, onCopy: { MultiplayerHashChip.copy($0) })
            }
        }
    }

    private var claimsBand: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Claims", count: workspace.claims.isEmpty ? nil : "\(workspace.claims.count)") {
                    Button(action: onClaim) { Label("Claim…", systemImage: "lock") }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(isBusy)
                        .help("Claim an issue or a set of paths for one of your agents")
                        .accessibilityLabel("Claim work in \(workspace.name.multiplayerDisplay)")
                }
                if workspace.claims.isEmpty {
                    teamsNote("Nothing is claimed. Claim an issue, some paths or a card before an agent starts on it.")
                        .padding(.vertical, Space.xs)
                }
                ForEach(Array(workspace.claims.enumerated()), id: \.element.id) { index, claim in
                    if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                    MultiplayerClaimRow(claim: claim, title: claim.kind == "card" ? all.first { $0.id == claim.key }?.title : nil,
                                        isMine: claim.isHeld(by: handle), now: now, isBusy: isBusy,
                                        isConfirming: confirming == .releaseClaim(claim.id),
                                        onRelease: { onRelease(claim) }, onCancel: onCancelConfirmation,
                                        onConfirm: { onConfirmRelease(claim) })
                }
            }
            .multiplayerStreaming(workspace.claims.map { "\($0.id)\(confirming == .releaseClaim($0.id))" })
        }
    }

    private var boardBand: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Board", count: all.isEmpty ? nil : "\(all.count)")
                if cards.value == nil {
                    MultiplayerLoadNote(loading: "Reading the board…", failure: cards.failure,
                                        onRetry: onRetryCards)
                } else {
                    MultiplayerStateTally(label: "Cards by state", cells: boardCells, selection: $filter)
                    let shown = all.filter { $0.known == filter }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, card in
                            if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                            MultiplayerCardRow(card: card, isMine: card.isAssigned(to: handle), isBusy: isBusy,
                                               onOpen: { onOpenCard(card) }, onClaim: { onClaimCard(card) })
                        }
                        if shown.isEmpty {
                            teamsNote(all.isEmpty ? "No cards yet. Add the first piece of work below."
                                                  : "No \(filter.title.lowercased()) cards.")
                                .padding(.vertical, Space.xs)
                        }
                    }
                    .multiplayerStreaming(shown.map(\.id))
                    HStack(spacing: 6) {
                        MultiplayerTextField(label: "New card title", placeholder: "Add a card", text: $cardDraft.title,
                                             isFocused: cardFocused)
                            .focused($cardFocused)
                            .onSubmit { if canAddCard { onAddCard() } }
                        Button("Add card", action: onAddCard)
                            .buttonStyle(MultiplayerTrayButtonStyle(large: true))
                            .disabled(!canAddCard)
                    }
                }
            }
        }
    }

    @ViewBuilder private var queueBand: some View {
        Group {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    let waiting = queue.filter(\.isQueued).count
                    MultiplayerBandHeading(title: "Merge queue", count: queue.isEmpty ? nil : "\(waiting)/\(queue.count)") {
                        Button(action: onQueueAdd) { Label("Queue branch…", systemImage: "plus") }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(isBusy)
                    }
                    if queue.isEmpty {
                        teamsNote("No branch is queued. The queue lives on the owner’s Mac: it tests each branch in order, then merges it into \(workspace.base.multiplayerDisplay).")
                            .padding(.vertical, Space.xs)
                    }
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                        MultiplayerQueueRow(position: index + 1, entry: entry, now: now, isBusy: isBusy,
                                            isConfirming: confirming == .removeQueued(entry.id),
                                            onRemove: onRemoveQueued.map { remove in { remove(entry) } },
                                            onCancel: onCancelConfirmation, onConfirm: { onConfirmRemoveQueued(entry) })
                    }
                    if waiting > 0 {
                        HStack {
                            teamsNote("Runs on this Mac, in each branch’s checkout.")
                            Spacer(minLength: Space.s)
                            Button(waiting == 1 ? "Test and merge 1" : "Test and merge \(waiting)", action: onRunQueue)
                                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                                .disabled(isBusy)
                        }
                        .padding(.top, 6)
                    }
                }
                .multiplayerStreaming(queue.map { "\($0.id)\($0.state)\(confirming == .removeQueued($0.id))" })
            }
        }
    }

    /// The pull requests of this workspace, once they are read for it.
    private var listed: MultiplayerPullRequestList? {
        pullRequests.value.flatMap { $0.workspace == workspace.id ? $0 : nil }
    }

    @ViewBuilder private var pullRequestBand: some View {
        Group {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Pull requests", count: listed.flatMap { $0.pullRequests.isEmpty ? nil : "\($0.pullRequests.count)" }) {
                        if let url = workspace.pullRequestsURL {
                            Button { onOpenLink(url) } label: { Label("Repository", systemImage: "arrow.up.right.square") }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .help(url.absoluteString)
                                .accessibilityLabel("Open the repository’s pull requests in your browser")
                        }
                    }
                    if let listed {
                        if listed.pullRequests.isEmpty {
                            teamsNote("No pull request is open. Members open theirs against \(workspace.base.multiplayerDisplay).")
                                .padding(.vertical, Space.xs)
                        }
                        ForEach(Array(listed.pullRequests.enumerated()), id: \.element.id) { index, pullRequest in
                            if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                            MultiplayerPullRequestRow(pullRequest: pullRequest, onOpen: onOpenLink)
                        }
                        if listed.isCapped {
                            teamsNote("These are the first \(MultiplayerPullRequestList.limit). Open the repository for the rest.")
                                .padding(.top, 6)
                        }
                    } else {
                        MultiplayerLoadNote(loading: "Reading the open pull requests…", failure: pullRequests.failure,
                                            onRetry: onRetryPullRequests)
                            .padding(.vertical, Space.xs)
                    }
                }
                .multiplayerStreaming(listed?.pullRequests.map(\.id) ?? [])
            }
        }
    }
}

struct MultiplayerClaimForm: View {
    @Binding var draft: MultiplayerClaimDraft
    let workspace: MultiplayerWorkspace
    let handle: String
    @FocusState private var focus: Field?

    enum Field: Hashable { case key, agent }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                MultiplayerChoice(label: "Claim", options: [MultiplayerClaim.Kind.issue, .paths], title: \.title,
                                  selection: $draft.kind,
                                  note: draft.kind == .paths ? "A path covers everything under it. An overlapping claim is refused."
                                                             : "One claim per issue. Claim a card from the board.")
                MultiplayerField(label: draft.kind.keyLabel, problem: draft.keyProblem) {
                    MultiplayerTextField(label: draft.kind.keyLabel, placeholder: draft.kind.keyPlaceholder, text: $draft.key,
                                         monospaced: true, isFocused: focus == .key)
                        .focused($focus, equals: .key)
                }
                MultiplayerField(label: "For agent", hint: "The claim is held as \(handle.multiplayerDisplay)/\(draft.trimmedAgent.isEmpty ? "agent" : draft.trimmedAgent.multiplayerDisplay).",
                                 problem: draft.agentProblem) {
                    MultiplayerTextField(label: "Agent", placeholder: "relay-worker", text: $draft.agent, monospaced: true,
                                         isFocused: focus == .agent)
                        .focused($focus, equals: .agent)
                }
            }
        }
        .onAppear { focus = .key }
    }
}

/// One card: what it asks for, who has it, and the result it was finished with.
struct MultiplayerCardPage: View {
    let card: MultiplayerCard
    let handle: String
    @Binding var result: String
    /// Release is waiting for its second press.
    var confirmingRelease = false
    var isBusy = false
    var onCancelRelease: () -> Void = {}
    var onConfirmRelease: () -> Void = {}

    var body: some View {
        let state = card.known
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(card.title.multiplayerDisplay)
                    .font(MultiplayerTheme.title)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: Space.s) {
                    MultiplayerStateLabel(lamp: state.lamp, text: state.title, tone: state.tone)
                    if !card.assignee.isEmpty {
                        MultiplayerBadge(text: card.assignee.multiplayerDisplay, symbol: "terminal",
                                         tone: card.isAssigned(to: handle) ? .focus : .neutral)
                    }
                    Spacer(minLength: 0)
                    MultiplayerHashChip(label: "ID", hash: card.id, onCopy: { MultiplayerHashChip.copy($0) })
                }
                if !card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MultiplayerMarkdown(text: card.body)
                }
                if confirmingRelease {
                    MultiplayerInlineConfirm(message: "Release \(card.title.multiplayerDisplay)? It goes back to open, anyone in the group can claim it, and a result you typed here is not kept.",
                                             keepTitle: "Keep card", confirmTitle: "Release card", isBusy: isBusy,
                                             onCancel: onCancelRelease, onConfirm: onConfirmRelease)
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Result")
                if state == .done {
                    if card.result.isEmpty { teamsNote("Finished with no result written.") } else { MultiplayerMarkdown(text: card.result) }
                } else if state == .claimed, card.isAssigned(to: handle) {
                    MultiplayerTextArea(label: "Result", text: $result, lines: 5)
                    teamsNote("Say what was done and where it is: a branch, a pull request or a commit.")
                } else {
                    teamsNote(state == .claimed ? "\(card.assignee.multiplayerDisplay) is working on it."
                                                : "Claim the card to work on it. The result is written when it is completed.")
                }
            }
        }
    }
}

struct MultiplayerQueueForm: View {
    @Binding var draft: MultiplayerQueueDraft
    let workspace: MultiplayerWorkspace
    let onChooseCheckout: () -> Void
    @FocusState private var focus: Field?

    enum Field: Hashable { case branch, checkout, test }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                MultiplayerField(label: "Branch", hint: "It must already be in the checkout: contributors push it through your git.push grant.") {
                    MultiplayerTextField(label: "Branch", placeholder: "collab/fix-reconnect", text: $draft.branch,
                                         monospaced: true, isFocused: focus == .branch)
                        .focused($focus, equals: .branch)
                }
                MultiplayerField(label: "Checkout", hint: "The local checkout of \(workspace.repository.multiplayerDisplay) to merge in.",
                                 problem: draft.checkoutProblem) {
                    HStack(spacing: 6) {
                        MultiplayerTextField(label: "Checkout", placeholder: "/path/to/checkout", text: $draft.checkout,
                                             monospaced: true, isFocused: focus == .checkout)
                            .focused($focus, equals: .checkout)
                        Button("Choose…", action: onChooseCheckout).buttonStyle(MultiplayerTrayButtonStyle(large: true))
                    }
                }
                MultiplayerField(label: "Test command", hint: "Run in the checkout before the merge is committed. Split on spaces; no shell runs it. Leave empty to merge untested.") {
                    MultiplayerTextField(label: "Test command", placeholder: "swift test", text: $draft.testText, monospaced: true,
                                         isFocused: focus == .test)
                        .focused($focus, equals: .test)
                }
            }
        }
        .onAppear { focus = .branch }
    }
}

// MARK: - Hosts

/// Hosts you lend and hosts friends lend: each with its environments and enrolled commands.
struct MultiplayerHostsPage: View {
    let mine: [MultiplayerResource]
    let theirs: [MultiplayerDirectoryEntry]
    let grantCount: (String) -> Int
    let isWaiting: (String) -> Bool
    let isBusy: Bool
    let onShare: (MultiplayerResource) -> Void
    let onAudit: (MultiplayerResource) -> Void
    let onRun: (MultiplayerDirectoryEntry) -> Void
    let onRequest: (MultiplayerDirectoryEntry) -> Void
    let onReputation: (MultiplayerDirectoryEntry) -> Void

    var body: some View {
        MultiplayerSection(title: "You lend", count: mine.count) {
            if mine.isEmpty {
                teamsNote("To lend this Mac, add a resource of kind Host on this server’s page. It points at a file listing the commands friends may run. Nothing else runs.")
                    .padding(.vertical, Space.xs)
            }
            ForEach(Array(mine.enumerated()), id: \.element.id) { index, host in
                if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                VStack(alignment: .leading, spacing: 6) {
                    let count = grantCount(host.id)
                    MultiplayerRow(symbol: "cpu", tone: count > 0 ? .working : .neutral, title: host.name,
                                   caption: count == 0 ? "Not shared yet" : count == 1 ? "Shared with 1 person" : "Shared with \(count) people")
                    HStack {
                        Spacer(minLength: 0)
                        MultiplayerVerbStrip(verbs: [
                            MultiplayerRowVerb(id: "audit", title: "Audit", hint: "See every run on \(host.name.multiplayerDisplay)") { onAudit(host) },
                            MultiplayerRowVerb(id: "share", title: "Share…", isEnabled: !isBusy,
                                               hint: "Let a friend or a group run commands on \(host.name.multiplayerDisplay)") { onShare(host) },
                        ])
                    }
                }
                .padding(.vertical, 4)
            }
        }
        MultiplayerSection(title: "Friends lend", count: theirs.count) {
            if theirs.isEmpty {
                teamsNote("No friend on this server lends a host yet.").padding(.vertical, Space.xs)
            }
            ForEach(Array(theirs.enumerated()), id: \.element.id) { index, host in
                if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Space.m) {
                        MultiplayerMark(symbol: "cpu", tone: host.canRunOnHost ? .working : .neutral)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name.multiplayerDisplay).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                            Text(host.owner.multiplayerDisplay).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        MultiplayerBadge(text: host.canRunOnHost ? "Granted" : isWaiting(host.id) ? "Request waiting" : "Offered",
                                         symbol: host.canRunOnHost ? "checkmark" : nil, tone: host.canRunOnHost ? .working : .neutral)
                    }
                    if let capabilities = host.capabilities {
                        VStack(alignment: .leading, spacing: 3) {
                            if !capabilities.environments.isEmpty { tags("env", capabilities.environments, spoken: "Environments") }
                            if !capabilities.commandNames.isEmpty { tags("run", capabilities.commandNames, spoken: "Enrolled commands") }
                        }
                    }
                    MultiplayerEndorsementChips(endorsements: host.endorsements)
                    HStack {
                        Spacer(minLength: 0)
                        MultiplayerVerbStrip(verbs: [
                            MultiplayerRowVerb(id: "reputation", title: "Reputation",
                                               hint: "See how runs on \(host.name.multiplayerDisplay) went") { onReputation(host) },
                            host.canRunOnHost
                                ? MultiplayerRowVerb(id: "run", title: "Run…", isPrimary: true, isEnabled: !isBusy,
                                                     hint: "Run an enrolled command on \(host.name.multiplayerDisplay)") { onRun(host) }
                                : MultiplayerRowVerb(id: "request", title: "Request access", isEnabled: !isBusy && !isWaiting(host.id),
                                                     hint: "Ask \(host.owner.multiplayerDisplay) to let you run commands on \(host.name.multiplayerDisplay)") { onRequest(host) },
                        ])
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func tags(_ label: String, _ values: [String], spoken: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(MultiplayerTheme.label).foregroundStyle(.inkSecondary).frame(width: 26, alignment: .leading)
            Text(values.map(\.multiplayerDisplay).joined(separator: "  "))
                .font(MultiplayerTheme.mono)
                .foregroundStyle(MultiplayerTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(spoken): \(values.formatted(.list(type: .and)))")
    }
}

/// Runs one enrolled command on a friend's host and shows its exit code and the end of its output.
struct MultiplayerHostRunPage: View {
    @Binding var draft: MultiplayerHostRunDraft
    let entry: MultiplayerDirectoryEntry?
    let reply: MultiplayerSentRequest?
    @FocusState private var focus: Field?

    enum Field: Hashable { case command, arguments }

    var body: some View {
        let commands = entry?.capabilities?.commandNames ?? []
        let chosen = draft.command.trimmingCharacters(in: .whitespaces)
        // Nil when the host doesn't publish its commands: the field stays, and the owner's Mac decides.
        let allowsArguments = entry?.capabilities?.allowsArguments(chosen)
        let environment = entry?.capabilities?.command(chosen)?.environment ?? ""
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                if let entry {
                    HStack(spacing: Space.s) {
                        MultiplayerMark(symbol: "cpu", tone: .working)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name.multiplayerDisplay).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                            Text("\(entry.owner.multiplayerDisplay)\(entry.capabilities?.environments.isEmpty == false ? ", \(entry.capabilities!.environments.map(\.multiplayerDisplay).joined(separator: ", "))" : "")")
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(.inkSecondary)
                        }
                        .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                MultiplayerField(label: "Command", hint: commands.isEmpty ? "Type the name the owner enrolled. Anything else is refused."
                                                          : environment.isEmpty ? "Only the commands the owner enrolled."
                                                          : "Runs in \(environment.multiplayerDisplay). Only the commands the owner enrolled.") {
                    if commands.isEmpty {
                        MultiplayerTextField(label: "Command", placeholder: "run-ios-ui-tests", text: $draft.command, monospaced: true,
                                             isFocused: focus == .command)
                            .focused($focus, equals: .command)
                    } else if commands.count <= 2 {
                        MultiplayerSegments(label: "Command", options: commands, title: { $0.multiplayerDisplay }, selection: $draft.command)
                    } else {
                        MultiplayerMenuField(label: "Command", placeholder: "Choose a command",
                                             options: commands.map { ($0, $0.multiplayerDisplay) }, selection: $draft.command)
                    }
                }
                if allowsArguments != false {
                    MultiplayerField(label: "Extra arguments",
                                     hint: allowsArguments == true ? "Added after the enrolled arguments."
                                                                   : "Added after the enrolled arguments, and only when the owner’s command allows it.") {
                        MultiplayerTextField(label: "Extra arguments", placeholder: "none", text: $draft.argumentText, monospaced: true,
                                             isFocused: focus == .arguments)
                            .focused($focus, equals: .arguments)
                    }
                    .multiplayerArriving()
                } else if !chosen.isEmpty {
                    teamsNote("\(chosen.multiplayerDisplay) runs exactly as its owner enrolled it. It takes no extra arguments.")
                }
            }
        }
        if let reply {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    if let run = MultiplayerHostRun(reply.value), reply.succeeded {
                        HStack(spacing: Space.s) {
                            MultiplayerBandHeading(title: "Result")
                            // The exit state and the time read as one readout.
                            HStack(spacing: Space.s) {
                                MultiplayerStateLabel(lamp: run.succeeded ? .on : .error, text: "exit \(run.exitCode)",
                                                      tone: run.succeeded ? .working : .failure)
                                Text("\(run.seconds) s").font(MultiplayerTheme.fingerprint).foregroundStyle(.inkSecondary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isStaticText)
                            .accessibilityLabel(run.spoken)
                        }
                        MultiplayerOutputWell(text: run.output, tone: run.succeeded ? .neutral : .failure)
                    } else {
                        MultiplayerBandHeading(title: "Result")
                        MultiplayerBanner(kind: reply.isSettled ? .failure : .attention,
                                          message: reply.refusal ?? "The owner’s Mac didn’t answer.")
                    }
                }
            }
            .multiplayerArriving()
        }
    }
}

// MARK: - Knowledge

struct MultiplayerKnowledgeLibrary: View {
    let items: [MultiplayerKnowledgeItem]
    let groupName: (String) -> String?
    let now: Date
    let onOpen: (MultiplayerKnowledgeItem) -> Void
    @State private var kind = ""

    private func kindCells(_ kinds: [String]) -> [MultiplayerStateTally<String>.Cell] {
        var cells = [MultiplayerStateTally<String>.Cell(option: "", title: "all", count: items.count)]
        for raw in kinds {
            cells.append(.init(option: raw, title: MultiplayerKnowledgeKind.title(for: raw).lowercased(),
                               count: items.filter { $0.kind == raw }.count))
        }
        return cells
    }

    var body: some View {
        let kinds = MultiplayerUnique.keep(items.map(\.kind)) { $0 }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Library", count: items.isEmpty ? nil : "\(items.count)")
                if kinds.count > 1 {
                    MultiplayerStateTally(label: "Kind", cells: kindCells(kinds), selection: $kind)
                }
                let shown = items.filter { kind.isEmpty || $0.kind == kind }
                if items.isEmpty {
                    teamsNote("Nothing is shared with you here yet. Share a prompt, a skill, an instructions snippet, an MCP configuration or a summary.")
                }
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                        Button { onOpen(item) } label: {
                            HStack(spacing: Space.s) {
                                MultiplayerMark(symbol: MultiplayerKnowledgeKind.symbol(for: item.kind), size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name.multiplayerDisplay).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                                    Text("\(MultiplayerKnowledgeKind.title(for: item.kind)), \(MultiplayerKnowledgeScope.describe(item.visibility, groupName: groupName).lowercasedFirst)")
                                        .font(MultiplayerTheme.sub)
                                        .foregroundStyle(.inkSecondary)
                                }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                MultiplayerBadge(text: "v\(item.version)")
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.inkSecondary)
                            }
                            .frame(minHeight: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MultiplayerRowButtonStyle())
                        .multiplayerArriving()
                        .accessibilityLabel("\(item.name.multiplayerDisplay), \(MultiplayerKnowledgeKind.title(for: item.kind)), version \(item.version)")
                        .accessibilityHint("Opens the item")
                    }
                }
                .multiplayerStreaming(shown.map(\.id))
            }
        }
    }
}

struct MultiplayerKnowledgeForm: View {
    @Binding var draft: MultiplayerKnowledgeDraft
    let friends: [MultiplayerFriend]
    let groups: [MultiplayerGroup]
    /// The device refused the last attempt because the content seemed to carry a secret.
    let refusal: String?
    @FocusState private var nameFocused: Bool

    static let secretTitle = "Not shared: a secret was found"
    static let secretAdvice = "Whoever installs the item fills ${NAME} from their own Keychain. Secrets never travel."

    /// The secret refusal as VoiceOver reads it: what happened, why, and what to do instead.
    static func secretLabel(_ problem: String) -> String {
        [secretTitle, problem, secretAdvice].map(MultiplayerSentence.sentence).joined(separator: " ")
    }

    var body: some View {
        if let problem = draft.secretProblem ?? refusal {
            MultiplayerBand {
                MultiplayerWell(edge: MultiplayerTheme.failure) {
                    HStack(alignment: .top, spacing: Space.s) {
                        MultiplayerLamp(kind: .error).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.secretTitle).font(MultiplayerTheme.heading).foregroundStyle(MultiplayerTheme.failure)
                            Text(problem).font(.system(size: 12)).foregroundStyle(MultiplayerTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Self.secretAdvice)
                                .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // One static text with the whole refusal: the lamp, the heading and the two
                    // sentences are not separate elements, and the well is never an empty one.
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(Self.secretLabel(problem))
                }
            }
            .multiplayerArriving()
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                if draft.editing.isEmpty {
                    MultiplayerField(label: "Kind") {
                        MultiplayerMenuField(label: "Kind", placeholder: "Choose a kind",
                                             options: MultiplayerKnowledgeKind.allCases.map { ($0, $0.title) }, selection: $draft.kind)
                    }
                }
                MultiplayerField(label: "Name", problem: draft.nameProblem) {
                    MultiplayerTextField(label: "Name", placeholder: draft.kind == .skill ? "relay-triage" : "Name", text: $draft.name,
                                         isFocused: nameFocused)
                        .focused($nameFocused)
                }
                MultiplayerField(label: "Content",
                                 hint: draft.kind == .mcp ? "Write ${NAME} wherever a token or password goes." : "Markdown is shown formatted.",
                                 problem: draft.secretProblem == nil ? draft.contentProblem : nil) {
                    MultiplayerTextArea(label: "Content", text: $draft.content, lines: 9)
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                MultiplayerChoice(label: "Visible to", options: MultiplayerKnowledgeScope.allCases, title: \.title, selection: $draft.scope,
                                  note: "The relay’s admin can narrow this. A wider scope than the relay allows is refused.")
                    .onChange(of: draft.scope) { draft.target = "" }
                if draft.scope == .friend {
                    MultiplayerField(label: "Friend") {
                        MultiplayerMenuField(label: "Friend", placeholder: "Choose a friend",
                                             options: friends.map { ($0.handle, $0.handle.multiplayerDisplay) }, selection: $draft.target)
                    }
                } else if draft.scope == .group {
                    MultiplayerField(label: "Group", hint: groups.isEmpty ? "You aren’t in a group on this server yet." : nil) {
                        MultiplayerMenuField(label: "Group", placeholder: "Choose a group",
                                             options: groups.map { ($0.id, $0.name.multiplayerDisplay) }, selection: $draft.target)
                    }
                }
            }
        }
        .onAppear { nameFocused = true }
    }
}

/// One item: what it is, who sees it, its content, and each version it has had.
struct MultiplayerKnowledgeItemPage: View {
    let item: MultiplayerKnowledgeItem
    let versions: MultiplayerLoad<[MultiplayerKnowledgeItem]>
    let groupName: (String) -> String?
    let now: Date
    let onRetry: () -> Void
    /// The version being read; the latest when nil.
    @State private var reading: Int?

    var body: some View {
        let shown = versions.value?.first { $0.version == reading } ?? item
        let kind = MultiplayerKnowledgeKind(rawValue: item.kind)
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    MultiplayerMark(symbol: MultiplayerKnowledgeKind.symbol(for: item.kind))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name.multiplayerDisplay).font(MultiplayerTheme.title).foregroundStyle(MultiplayerTheme.foreground)
                        Text("\(MultiplayerKnowledgeKind.title(for: item.kind)), \(MultiplayerKnowledgeScope.describe(shown.visibility, groupName: groupName).lowercasedFirst)")
                            .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    MultiplayerBadge(text: "v\(shown.version)", tone: shown.version == item.version ? .focus : .attention)
                }
                MultiplayerHashChip(label: "ID", hash: item.id, onCopy: { MultiplayerHashChip.copy($0) })
                if !shown.placeholders.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("fill").font(MultiplayerTheme.label).foregroundStyle(.inkSecondary)
                        Text(shown.placeholders.map { "${\($0)}" }.joined(separator: "  "))
                            .font(MultiplayerTheme.mono).foregroundStyle(MultiplayerTheme.attention)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("You fill in: \(shown.placeholders.formatted(.list(type: .and)))")
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: shown.version == item.version ? "Content" : "Content, version \(shown.version)")
                if kind == .mcp {
                    MultiplayerOutputWell(text: shown.content, lines: 16)
                } else {
                    MultiplayerMarkdown(text: shown.content)
                }
                if let kind { teamsNote(kind.installNote) }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Versions", count: versions.value.map { "\($0.count)" })
                if let rows = versions.value {
                    ForEach(Array(rows.sorted { $0.version > $1.version }.enumerated()), id: \.element.version) { index, row in
                        if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                        let isOn = row.version == shown.version
                        Button { reading = row.version == item.version ? nil : row.version } label: {
                            HStack(spacing: Space.s) {
                                Text("v\(row.version)").font(MultiplayerTheme.data)
                                    .foregroundStyle(isOn ? MultiplayerTheme.focus : MultiplayerTheme.foreground)
                                    .frame(width: 34, alignment: .leading)
                                Text(MultiplayerKnowledgeScope.describe(row.visibility, groupName: groupName))
                                    .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).lineLimit(1)
                                Spacer(minLength: Space.s)
                                Text(row.createdAt.map { MultiplayerTime.display($0, now: now) } ?? "")
                                    .font(MultiplayerTheme.fingerprint).foregroundStyle(.inkSecondary)
                            }
                            .frame(minHeight: 28)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(isOn ? MultiplayerTheme.focus : Color.clear).frame(width: 2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MultiplayerRowButtonStyle())
                        .accessibilityLabel("Version \(row.version), \(MultiplayerKnowledgeScope.describe(row.visibility, groupName: groupName))")
                        .accessibilityValue(isOn ? "Selected" : "")
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                } else {
                    MultiplayerLoadNote(loading: "Reading the versions…",
                                        failure: versions.failure,
                                        onRetry: onRetry)
                }
            }
        }
    }
}

// MARK: - Reputation and directory

/// How a resource's finished requests went, who vouches for it, and your own say on both.
struct MultiplayerReputationPage: View {
    let name: String
    let owner: String
    let kind: String
    let state: MultiplayerLoad<MultiplayerReputation>
    let endorsements: [MultiplayerEndorsement]
    let judgeable: [MultiplayerSentRequest]
    let outcomes: [String: Bool]
    @Binding var skill: String
    let canEndorse: Bool
    let now: Date
    let isBusy: Bool
    let onEndorse: () -> Void
    let onReport: (MultiplayerSentRequest, Bool) -> Void
    let onRetry: () -> Void
    @FocusState private var skillFocused: Bool

    var body: some View {
        MultiplayerBand {
            HStack(spacing: Space.s) {
                MultiplayerMark(symbol: MultiplayerResourceKind.symbol(for: kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.multiplayerDisplay).font(MultiplayerTheme.title).foregroundStyle(MultiplayerTheme.foreground)
                    Text(owner.multiplayerDisplay).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                }
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        switch state {
        case .loaded(let reputation):
            MultiplayerStatusStrip(cells: [
                MultiplayerReadout(id: "completed", label: "completed", value: "\(reputation.completed)"),
                MultiplayerReadout(id: "accepted", label: "accepted", value: "\(reputation.accepted)",
                                   tone: reputation.accepted > 0 ? .working : .neutral),
                MultiplayerReadout(id: "rejected", label: "rejected", value: "\(reputation.rejected)",
                                   tone: reputation.rejected > 0 ? .failure : .neutral),
                MultiplayerReadout(id: "median", label: "median", value: reputation.medianTitle,
                                   spoken: "median time, \(reputation.medianTitle)"),
            ])
            if reputation.accepted + reputation.rejected > 0 {
                MultiplayerBand {
                    HStack(spacing: Space.s) {
                        MultiplayerMeter(used: reputation.accepted, limit: reputation.accepted + reputation.rejected, isGood: true)
                        Text("\(reputation.acceptedPercent ?? 0)% of judged results accepted")
                            .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                }
            }
        case .loading:
            MultiplayerBand { MultiplayerLoadNote(loading: "Reading the reputation…", failure: nil, onRetry: onRetry) }
        case .failed(let message):
            MultiplayerBand {
                MultiplayerLoadNote(loading: "", failure: message.localizedCaseInsensitiveContains("forbidden")
                                        ? "This relay’s policy doesn’t show you this resource’s reputation." : message, onRetry: onRetry)
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Endorsements", count: endorsements.isEmpty ? nil : "\(endorsements.count)")
                if endorsements.isEmpty {
                    teamsNote("Nobody has endorsed it yet.")
                } else {
                    ForEach(Array(MultiplayerEndorsement.tally(endorsements).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: Space.s) {
                            MultiplayerBadge(text: entry.skill.multiplayerDisplay, symbol: "checkmark.seal", tone: .working)
                            Text(endorsements.filter { $0.skill == entry.skill }.map(\.handle.multiplayerDisplay).formatted(.list(type: .and)))
                                .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                MultiplayerField(label: "Endorse for a skill", hint: "Open to friends of the owner who have had a request completed here.") {
                    HStack(spacing: 6) {
                        MultiplayerTextField(label: "Skill", placeholder: "swift concurrency", text: $skill, isFocused: skillFocused)
                            .focused($skillFocused)
                            .onSubmit { if canEndorse { onEndorse() } }
                        Button("Endorse", action: onEndorse)
                            .buttonStyle(MultiplayerTrayButtonStyle(large: true))
                            .disabled(!canEndorse)
                    }
                }
            }
        }
        if !judgeable.isEmpty {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Your results", count: "\(judgeable.count)")
                    teamsNote("Say whether you took each result. It counts toward the figures above.")
                    ForEach(Array(judgeable.enumerated()), id: \.element.id) { index, request in
                        if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                        HStack(spacing: Space.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.title.multiplayerDisplay).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                                Text(MultiplayerActivityRow.time(request.at, now: now)).font(MultiplayerTheme.fingerprint).foregroundStyle(.inkSecondary)
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            if let accepted = outcomes[request.request] {
                                MultiplayerStateLabel(lamp: accepted ? .on : .error, text: accepted ? "Accepted" : "Rejected",
                                                      tone: accepted ? .working : .failure)
                            } else {
                                MultiplayerVerbStrip(verbs: [
                                    MultiplayerRowVerb(id: "reject", title: "Reject", isEnabled: !isBusy,
                                                       hint: "Report that you didn’t take the result of \(request.title.multiplayerDisplay)") { onReport(request, false) },
                                    MultiplayerRowVerb(id: "accept", title: "Accept", isPrimary: true, isEnabled: !isBusy,
                                                       hint: "Report that you took the result of \(request.title.multiplayerDisplay)") { onReport(request, true) },
                                ])
                            }
                        }
                        .frame(minHeight: 36)
                    }
                }
            }
        }
    }
}

/// Searches handles, and the resources whose owners chose to list them.
struct MultiplayerDirectorySearchPage: View {
    @Binding var query: String
    let state: MultiplayerLoad<MultiplayerDirectorySearch>
    let onSearch: () -> Void
    let onReputation: (MultiplayerDirectoryHit) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        MultiplayerBand {
            HStack(spacing: 6) {
                MultiplayerTextField(label: "Search the directory", placeholder: "A handle, a name, a tool or an environment",
                                     text: $query, isFocused: focused)
                    .focused($focused)
                    .onSubmit(onSearch)
                Button("Search", action: onSearch)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary, large: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { focused = true }
        switch state {
        case .loading:
            MultiplayerBand { MultiplayerLoadNote(loading: "Searching…", failure: nil, onRetry: onSearch) }
        case .failed(let message):
            MultiplayerBand {
                MultiplayerLoadNote(loading: "", failure: message.localizedCaseInsensitiveContains("forbidden")
                                        ? "This relay’s directory is off. Its admin can turn it on in the relay policy." : message,
                                    onRetry: onSearch)
            }
        case .loaded(let found):
            if found.isEmpty {
                MultiplayerBand {
                    teamsNote(found.query.isEmpty ? "Nothing is listed by default. An owner lists a resource to make it findable here."
                                                  : "Nothing matches “\(found.query.multiplayerDisplay)”.")
                }
            }
            if !found.handles.isEmpty {
                MultiplayerSection(title: "People", count: found.handles.count) {
                    ForEach(Array(found.handles.enumerated()), id: \.element) { index, handle in
                        if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                        HStack(spacing: Space.s) {
                            MultiplayerAvatar(image: nil, name: handle.multiplayerDisplay, size: 24)
                            Text(handle.multiplayerDisplay).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 34)
                    }
                }
            }
            if !found.resources.isEmpty {
                MultiplayerSection(title: "Listed resources", count: found.resources.count) {
                    ForEach(Array(found.resources.enumerated()), id: \.element.id) { index, hit in
                        if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: Space.m) {
                                MultiplayerMark(symbol: MultiplayerResourceKind.symbol(for: hit.kind))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.name.multiplayerDisplay).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                                    Text("\(hit.handle.multiplayerDisplay), \(MultiplayerResourceKind.title(for: hit.kind).lowercased())")
                                        .font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                                }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                                Button("Reputation") { onReputation(hit) }
                                    .buttonStyle(MultiplayerTrayButtonStyle())
                                    .accessibilityLabel("Reputation of \(hit.name.multiplayerDisplay)")
                            }
                            if let capabilities = hit.capabilities {
                                if capabilities.headline != nil { MultiplayerAgentChip(capabilities: capabilities) }
                                if !capabilities.tags.isEmpty {
                                    Text(capabilities.tags.joined(separator: "  ")).font(MultiplayerTheme.mono).foregroundStyle(.inkSecondary)
                                        .accessibilityLabel("Tools and environments: \(capabilities.tags.formatted(.list(type: .and)))")
                                }
                            }
                            MultiplayerEndorsementChips(endorsements: hit.endorsements)
                        }
                        .padding(.vertical, 6)
                        .multiplayerArriving()
                    }
                }
            }
        }
    }
}

// MARK: - Relay policy

/// The relay's sharing limits, and the admin's power over members and devices.
struct MultiplayerPolicyPage: View {
    let state: MultiplayerLoad<MultiplayerRelayPolicy>
    @Binding var draft: MultiplayerPolicyDraft
    let confirming: MultiplayerTeamsConfirmation?
    let isBusy: Bool
    let onRetry: () -> Void
    let onAskSuspend: () -> Void
    let onRestore: () -> Void
    let onAskRevoke: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @FocusState private var focus: Field?

    enum Field: Hashable { case grantDays, budget, retention, member, device }

    var body: some View {
        if state.value == nil {
            MultiplayerBand {
                MultiplayerLoadNote(loading: "Reading the relay policy…",
                                    failure: state.failure, onRetry: onRetry)
            }
        } else {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.m) {
                    MultiplayerBandHeading(title: "Knowledge")
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
                    MultiplayerBandHeading(title: "Reputation and directory")
                    MultiplayerChoice(label: "Reputation is visible to", options: MultiplayerReputationVisibility.allCases, title: \.title,
                                      selection: $draft.reputationVisibility, note: draft.reputationVisibility.explanation)
                    MultiplayerSettingRow(label: "Directory search") {
                        HStack(spacing: Space.s) {
                            Toggle("Directory search", isOn: $draft.directory)
                                .toggleStyle(MultiplayerSwitchStyle())
                            MultiplayerStateLabel(lamp: draft.directory ? .on : .off, text: draft.directory ? "On" : "Off",
                                                  tone: draft.directory ? .working : .neutral)
                                .accessibilityHidden(true)
                        }
                    }
                    teamsNote("When on, members can search handles and the resources their owners listed. Nothing is listed by default.")
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: "Limits")
                    number("Longest grant", unit: "days", text: $draft.maxGrantDays, field: .grantDays, problem: draft.grantDaysProblem)
                    number("Largest token budget", unit: "tokens", text: $draft.maxBudgetTokens, field: .budget, problem: draft.budgetProblem)
                    number("Keep records for", unit: "days", text: $draft.retentionDays, field: .retention, problem: draft.retentionProblem)
                    teamsNote("0 means no limit for grants and budgets. With a budget limit, every grant must set a budget.")
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.m) {
                    MultiplayerBandHeading(title: "Members and devices")
                    MultiplayerField(label: "Member", hint: "A suspended member’s devices can’t use this relay, and they leave the directory.") {
                        HStack(spacing: 6) {
                            MultiplayerTextField(label: "Member handle", placeholder: "handle", text: $draft.member, monospaced: true,
                                                 isFocused: focus == .member)
                                .focused($focus, equals: .member)
                            Button("Restore", action: onRestore)
                                .buttonStyle(MultiplayerTrayButtonStyle(large: true))
                                .disabled(isBusy || draft.trimmedMember.isEmpty)
                                .accessibilityLabel("Restore this member")
                            Button("Suspend…", action: onAskSuspend)
                                .buttonStyle(MultiplayerTrayButtonStyle(role: .danger, large: true))
                                .disabled(isBusy || draft.trimmedMember.isEmpty)
                                .accessibilityLabel("Suspend this member")
                        }
                    }
                    if case .suspend(let handle)? = confirming {
                        MultiplayerInlineConfirm(message: "Suspend \(handle.multiplayerDisplay)? Every device of theirs is cut off from this relay until you restore them.",
                                                 keepTitle: "Keep member", confirmTitle: "Suspend member", isBusy: isBusy,
                                                 onCancel: onCancel, onConfirm: onConfirm)
                    }
                    MultiplayerField(label: "Device", hint: "Revoking a device ends its session. Its owner has to sign in on it again.") {
                        HStack(spacing: 6) {
                            MultiplayerTextField(label: "Device ID", placeholder: "device ID", text: $draft.device, monospaced: true,
                                                 isFocused: focus == .device)
                                .focused($focus, equals: .device)
                            Button("Revoke…", action: onAskRevoke)
                                .buttonStyle(MultiplayerTrayButtonStyle(role: .danger, large: true))
                                .disabled(isBusy || draft.trimmedDevice.isEmpty)
                                .accessibilityLabel("Revoke this device")
                        }
                    }
                    if case .revokeDevice(let device)? = confirming {
                        MultiplayerInlineConfirm(message: "Revoke device \(device.multiplayerDisplay)? It is signed out of this relay at once.",
                                                 keepTitle: "Keep device", confirmTitle: "Revoke device", isBusy: isBusy,
                                                 onCancel: onCancel, onConfirm: onConfirm)
                    }
                }
            }
        }
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
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(MultiplayerTheme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
