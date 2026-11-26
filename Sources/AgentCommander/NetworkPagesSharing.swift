import SwiftUI

// ATOMIC LEVEL: Organisms and pages (Network: Directory, Approvals, Shared).
// Three collections with an inspector. The tables are the main window's; what the inspector holds
// is the tray's organism for that thing, used as it is: the directory card, the request-access
// form, the approval page and the grant sheet.
//
//   NetworkGrantInspector       the grant sheet, with Cancel and Share (organism)
//   NetworkDirectoryTable       what friends offer (organism)
//   NetworkDirectoryPage        (page)
//   NetworkApprovalTable        uses of your resources that wait for you (organism)
//   NetworkAccessTable          access requests, both ways (organism)
//   NetworkApprovalsPage        (page)
//   NetworkSharedTable          your resources and who can use them (organism)
//   NetworkSharedInspector      one resource's grants and who holds control (organism)
//   NetworkSharedPage           (page)

// MARK: - Grant sheet

/// The tray's grant sheet in an inspector. Granting answers an access request it was opened from.
struct NetworkGrantInspector: View {
    let server: String
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let found = state.server(server)
        if let host = pages.grantHost {
            // The network model's own sheet, with its footer: Share reports its result there, and a
            // refusal stays on the sheet.
            NetworkInspector(title: "Share", serverID: server, serverName: state.serverName(server), close: actions.closeGrant) {
                host(server)
            }
            // A sheet opened by Review or Share may be under the table in a narrow window.
            .shellRevealed("grant-sheet", anchor: .top)
        } else {
            sample.shellRevealed("grant-sheet", anchor: .top)
        }
    }

    /// The sheet drawn from values, for the previews.
    private var sample: some View {
        let state = pages.content, actions = pages.actions
        let found = state.server(server)
        return NetworkInspector(title: "Share", serverID: server, serverName: state.serverName(server), note: state.grantHint,
                         close: actions.closeGrant) {
            if let refusal = state.grantRefusal {
                MultiplayerBand { MultiplayerBanner(kind: .failure, message: refusal) }
                    .accessibilityIdentifier("network-grant-refusal")
            }
            MultiplayerGrantSheet(draft: pages.drafts.grant, servers: state.online.map(\.summary),
                                  friends: found?.friends ?? [], resources: found?.resources ?? [],
                                  resource: state.grantResource, companions: state.grantCompanions,
                                  onServer: actions.setGrantServer, onResourceChange: actions.reconcileGrant,
                                  onToggle: actions.toggleGrantAction)
        } footer: {
            Button("Cancel", action: actions.closeGrant).buttonStyle(MultiplayerTrayButtonStyle())
            Button("Share", action: actions.confirmGrant)
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(!state.canGrant)
                .accessibilityIdentifier("network-grant-share")
        }
    }
}

// MARK: - Directory

struct NetworkDirectoryTable: View {
    @Environment(\.theme) private var theme
    let rows: [NetworkDirectoryRow]
    let selected: String?
    let select: (NetworkDirectoryRow) -> Void

    private static let name = ShellColumn(title: "resource")
    private static let owner = ShellColumn(title: "owner", width: NetworkLayout.personColumn)
    private static let agent = ShellColumn(title: "runs on", width: 190)
    private static let access = ShellColumn(title: "your access", width: 84)

    var body: some View {
        ShellTable(columns: [Self.name, Self.owner, Self.agent, Self.access], items: rows,
                   empty: "No friend has published a resource yet. When one does, it shows here with what it offers.") { row in
            let entry = row.entry
            ShellTableRow(isSelected: row.id == selected, spoken: spoken(row), hint: "Shows what it offers",
                          select: { select(row) }) {
                HStack(spacing: Space.s) {
                    MultiplayerMark(symbol: MultiplayerResourceKind.symbol(for: entry.kind),
                                    tone: entry.granted.isEmpty ? .neutral : .working, size: 20)
                    ShellCellText(title: entry.name.multiplayerDisplay, detail: actions(entry))
                }
                .shellCell(Self.name)
                ShellPersonCell(name: entry.owner.isEmpty ? "a friend" : entry.owner.multiplayerDisplay,
                                serverID: row.server, serverName: row.serverName)
                    .shellCell(Self.owner)
                Group {
                    if let chip = entry.capabilities, chip.headline != nil {
                        MultiplayerAgentChip(capabilities: chip)
                    } else {
                        Text(MultiplayerResourceKind.title(for: entry.kind).multiplayerDisplay)
                            .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                    }
                }
                .shellCell(Self.agent)
                MultiplayerStateLabel(lamp: entry.granted.isEmpty ? (row.isWaiting ? .waiting : .off) : .on,
                                      text: row.access.title, tone: row.access.tone)
                    .shellCell(Self.access)
            }
            .padding(.vertical, Space.xs)
            .accessibilityIdentifier("network-directory-\(row.id)")
        }
    }

    /// The actions a row names: what is granted, then how many more are offered.
    private func actions(_ entry: MultiplayerDirectoryEntry) -> String {
        let shown = entry.offered.filter { !MultiplayerSharePolicy.isCompanion($0) }
        let granted = shown.filter(entry.granted.contains).map(MultiplayerCapability.title)
        let more = shown.count - granted.count
        if granted.isEmpty { return shown.map(MultiplayerCapability.title).joined(separator: ", ") }
        return granted.joined(separator: ", ") + (more > 0 ? ", \(more) more offered" : "")
    }

    private func spoken(_ row: NetworkDirectoryRow) -> String {
        "\(row.entry.name.multiplayerDisplay), \(row.entry.owner.multiplayerDisplay) on \(row.serverName), \(row.access.title)"
    }
}

/// Network, Directory.
struct NetworkDirectoryPage: View {
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let rows = state.directoryRows
        NetworkPageScaffold(place: NetworkPlace.directory, pages: pages) {
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "Offered by friends", count: "\(rows.count)")
                    NetworkDirectoryTable(rows: rows, selected: selected(in: rows)?.id) { row in
                        var next = pages.selection
                        next.directory = row.id
                        actions.select(next)
                    }
                }
            } inspector: {
                inspector(selected(in: rows))
            }
        }
    }

    /// The entry being asked for wins; otherwise the row the person chose.
    private func selected(in rows: [NetworkDirectoryRow]) -> NetworkDirectoryRow? {
        if let page = pages.content.sharePage, case .requestAccess(let resource) = page.page {
            return rows.first { $0.server == page.server && $0.entry.id == resource }
        }
        return rows.first { $0.id == pages.selection.directory }
    }

    @ViewBuilder private func inspector(_ row: NetworkDirectoryRow?) -> some View {
        let state = pages.content, actions = pages.actions
        if let row {
            let asking = state.sharePage.map { $0.server == row.server && $0.page == .requestAccess(resource: row.entry.id) } ?? false
            if asking {
                NetworkInspector(title: "Request access", serverID: row.server, serverName: row.serverName,
                                 note: pages.drafts.access.wrappedValue.actions.isEmpty ? "Choose at least one action." : nil,
                                 close: actions.back) {
                    MultiplayerRequestAccessPage(entry: row.entry, draft: pages.drafts.access)
                } footer: {
                    Button("Cancel", action: actions.back).buttonStyle(MultiplayerTrayButtonStyle())
                    Button("Send request", action: actions.sendAccessRequest)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(state.isBusy || !pages.drafts.access.wrappedValue.canSend)
                }
            } else {
                NetworkInspector(title: row.entry.name.multiplayerDisplay, serverID: row.server, serverName: row.serverName,
                                 note: nil) {
                    MultiplayerDirectoryPage(entries: [row.entry], isBusy: state.isBusy || state.server(row.server)?.isOnline != true,
                                             isWaiting: { _ in row.isWaiting },
                                             onRequest: { actions.requestAccess($0, row.server) },
                                             onConsult: { actions.consult?($0, row.server) },
                                             onHandOff: { actions.handOff?($0, row.server) })
                } footer: {
                    if row.entry.canReview, let review = actions.requestReview {
                        Button("Request review") { review(row.entry, row.server) }.buttonStyle(MultiplayerTrayButtonStyle())
                            .help("Ask this worker to review a diff or a pull request")
                    }
                    if row.entry.canWatch, let watch = actions.watch {
                        Button("Watch") { watch(row.entry, row.server) }.buttonStyle(MultiplayerTrayButtonStyle())
                            .help("Read the worker’s live output and send it a suggestion")
                    }
                }
            }
        } else {
            NetworkInspectorNote(text: "Choose a resource to see what it offers and what you can do with it.")
        }
    }
}

// MARK: - Approvals

struct NetworkApprovalTable: View {
    @Environment(\.theme) private var theme
    let rows: [NetworkApprovalRow]
    let selected: String?
    let isBusy: Bool
    let open: (NetworkApprovalRow) -> Void
    let decide: (NetworkApprovalRow, Bool) -> Void

    private static let who = ShellColumn(title: "from", width: NetworkLayout.personColumn)
    private static let wants = ShellColumn(title: "wants to")
    private static let clock = ShellColumn(title: "time", width: NeedsYouLayout.clockWidth, alignment: .trailing)
    private static let verbs: CGFloat = 150

    var body: some View {
        ShellTable(columns: [Self.who, Self.wants, Self.clock], trailing: Self.verbs, items: rows,
                   empty: "Nothing is waiting for you", emptyLamp: .on) { row in
            ShellTableRow(isSelected: row.id == selected,
                          spoken: "\(row.approval.headline), \(row.resourceName) on \(row.serverName)"
                            + NetworkSpoken.suffix(row.answer?.title ?? NetworkSpoken.clock(waiting: row.waiting, expiresIn: row.expiresIn)),
                          hint: "Shows the request and the grant it runs under", select: { open(row) }, trailing: Self.verbs) {
                ShellPersonCell(name: row.who, serverID: row.server, serverName: row.serverName).shellCell(Self.who)
                ShellCellText(title: row.approval.headline,
                              detail: row.result?.rowText
                                ?? (row.approval.request.isEmpty ? row.resourceName : "\(row.resourceName): \(row.approval.request)"),
                              detailTone: row.result?.rowTone ?? .neutral)
                    .shellCell(Self.wants)
                NeedsYouClockLabel(waiting: row.waiting, expiresIn: row.expiresIn).shellCell(Self.clock)
            } verbs: {
                NetworkRowVerbs(isRunning: row.isRunning, result: row.result, answer: row.answer, verbs: [
                    MultiplayerRowVerb(id: "deny", title: "Deny", isEnabled: !isBusy,
                                       hint: "Deny \(row.who)’s request", action: { decide(row, false) }),
                    MultiplayerRowVerb(id: "approve", title: "Approve", isPrimary: true, isEnabled: !isBusy,
                                       hint: "Approve \(row.who)’s request", action: { decide(row, true) })
                ])
            }
            .padding(.vertical, Space.xs)
            .accessibilityIdentifier("network-approval-\(row.id)")
        }
    }
}

struct NetworkAccessTable: View {
    @Environment(\.theme) private var theme
    let rows: [NetworkAccessRow]
    /// The row in the inspector.
    var selected: String? = nil
    let now: Date
    let isBusy: Bool
    /// Shows a request in the inspector. Nil leaves the rows as text.
    var select: ((NetworkAccessRow) -> Void)? = nil
    let review: (NetworkAccessRow) -> Void
    /// Declines a request sent to you, or withdraws one you sent.
    let remove: (NetworkAccessRow) -> Void

    private static let who = ShellColumn(title: "who", width: NetworkLayout.personColumn)
    private static let what = ShellColumn(title: "asks for")
    private static let way = ShellColumn(title: "sent", width: 56)
    private static let sent = ShellColumn(title: "when", width: 72, alignment: .trailing)
    private static let verbs: CGFloat = 150

    var body: some View {
        ShellTable(columns: [Self.who, Self.what, Self.way, Self.sent], trailing: Self.verbs, items: rows,
                   empty: "No access request is open. Ask for access from the Directory.") { row in
            let request = row.request
            ShellTableRow(isSelected: row.id == selected, spoken: spoken(row), hint: "Shows the request",
                          select: select.map { select in { select(row) } }, trailing: Self.verbs) {
                ShellPersonCell(name: row.who, serverID: row.server, serverName: row.serverName).shellCell(Self.who)
                ShellCellText(title: row.resourceName, detail: row.result?.rowText ?? MultiplayerAccessRequestsPage.detail(request),
                              detailTone: row.result?.rowTone ?? .neutral)
                    .shellCell(Self.what)
                MultiplayerBadge(text: row.isIncoming ? "to you" : "by you", tone: row.isIncoming ? .attention : .neutral)
                    .shellCell(Self.way)
                ShellCellFigure(text: MultiplayerActivityRow.time(request.createdAt, now: now)).shellCell(Self.sent)
            } verbs: {
                if row.isIncoming {
                    NetworkRowVerbs(isRunning: row.isRunning, result: row.result, answer: row.answer, verbs: [
                        MultiplayerRowVerb(id: "decline", title: "Decline", isEnabled: !isBusy,
                                           hint: "Decline \(row.who)’s request", action: { remove(row) }),
                        MultiplayerRowVerb(id: "review", title: "Review", isPrimary: true, isEnabled: !isBusy,
                                           hint: "Review \(row.who)’s request in the share sheet", action: { review(row) })
                    ])
                } else if request.isPending {
                    NetworkRowVerbs(isRunning: row.isRunning, result: row.result, answer: row.answer, verbs: [
                        MultiplayerRowVerb(id: "withdraw", title: "Withdraw", isEnabled: !isBusy,
                                           hint: "Withdraw your request for \(row.resourceName)", action: { remove(row) })
                    ])
                } else {
                    MultiplayerStateLabel(lamp: request.status == "granted" ? .on : .off, text: request.statusTitle,
                                          tone: request.status == "granted" ? .working : .neutral)
                }
            }
            .padding(.vertical, Space.xs)
            .accessibilityIdentifier("network-access-\(row.id)")
        }
    }

    private func spoken(_ row: NetworkAccessRow) -> String {
        let when = MultiplayerActivityRow.time(row.request.createdAt, now: now)
        let sent = when.isEmpty ? "" : " Sent \(when)."
        return row.isIncoming
            ? "\(row.who) asks for \(row.resourceName) on \(row.serverName). \(MultiplayerAccessRequestsPage.detail(row.request))\(sent)"
            : "You asked \(row.who) for \(row.resourceName) on \(row.serverName). \(row.request.statusTitle).\(sent)"
    }
}

/// Network, Approvals.
struct NetworkApprovalsPage: View {
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let approvals = state.approvalRows, access = state.accessRows
        NetworkPageScaffold(place: NetworkPlace.approvals, pages: pages) {
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        // An answered row still shows its outcome, but it no longer waits and isn't counted.
                        ShellBandHeading(title: "Waiting on you", count: "\(approvals.filter { $0.answer == nil }.count)",
                                         note: approvals.isEmpty ? nil : "A grant set to Ask each time stops here until you answer.")
                        NetworkApprovalTable(rows: approvals, selected: openApproval(in: approvals)?.id, isBusy: state.isBusy,
                                             open: {
                                                 select(access: nil)
                                                 actions.openApproval($0.approval.id, $0.server)
                                             },
                                             decide: { row, approve in actions.decide(row.approval, row.server, approve) })
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        ShellBandHeading(title: "Access requests", count: "\(access.count)",
                                         note: "Review opens the share sheet. Granting it answers the request.")
                        NetworkAccessTable(rows: access, selected: openApproval(in: approvals) == nil ? pages.selection.access : nil,
                                           now: state.now, isBusy: state.isBusy,
                                           select: { row in
                                               // One thing in the inspector: the open approval gives way.
                                               actions.close()
                                               select(access: row.id)
                                           },
                                           review: { actions.reviewAccess($0.request, $0.server) },
                                           remove: { actions.removeAccess($0.request, $0.server, $0.isIncoming) })
                    }
                }
            } inspector: {
                if let server = pages.selection.grant {
                    NetworkGrantInspector(server: server, pages: pages)
                } else if openApproval(in: approvals) == nil, let row = access.first(where: { $0.id == pages.selection.access }) {
                    accessInspector(row)
                } else {
                    inspector(openApproval(in: approvals))
                }
            }
        }
    }

    private func select(access id: String?) {
        var next = pages.selection
        next.access = id
        pages.actions.select(next)
    }

    private func accessInspector(_ row: NetworkAccessRow) -> some View {
        let request = row.request, now = pages.content.now
        var lines: [(label: String, value: String)] = [
            (row.isIncoming ? "From" : "To", row.who),
            ("Resource", row.resourceName),
            ("Asks to", MultiplayerAccessRequestsPage.detail(request))
        ]
        let when = MultiplayerActivityRow.time(request.createdAt, now: now)
        if !when.isEmpty { lines.append(("Sent", when)) }
        if !row.isIncoming { lines.append(("State", request.statusTitle)) }
        return NetworkRequestInspector(title: "Access request", serverID: row.server, serverName: row.serverName, lines: lines,
                                       note: row.isIncoming
                                        ? "Review opens the share sheet with what they asked for. Sharing answers the request; Decline refuses it and they can ask again."
                                        : "\(row.who) decides. Withdraw takes the request back.",
                                       close: { select(access: nil) })
    }

    private func openApproval(in rows: [NetworkApprovalRow]) -> NetworkApprovalRow? {
        guard let page = pages.content.sharePage, case .approval(let id) = page.page else { return nil }
        return rows.first { $0.server == page.server && $0.approval.id == id }
    }

    @ViewBuilder private func inspector(_ row: NetworkApprovalRow?) -> some View {
        let state = pages.content, actions = pages.actions
        if let server = pages.selection.grant {
            NetworkGrantInspector(server: server, pages: pages)
        } else if let row {
            let approval = row.approval
            let server = state.server(row.server)
            NetworkInspector(title: approval.isSuggestion ? approval.headline : "Approve this action?", serverID: row.server,
                             serverName: row.serverName, close: actions.close) {
                MultiplayerApprovalPage(approval: approval, serverName: row.serverName,
                                        color: MultiplayerTheme.swatch(for: row.server), resourceName: row.resourceName,
                                        kind: server?.resources.first { $0.id == approval.resource }?.kind ?? "",
                                        grant: server?.grants.first {
                                            $0.resource == approval.resource && $0.capability == approval.action
                                                && (approval.peer.isEmpty || $0.handle == approval.peer)
                                        },
                                        now: state.now)
            } footer: {
                Button("Audit") {
                    actions.go(NetworkPlace.audit)
                    actions.openAudit(approval.resource, row.server)
                }
                .buttonStyle(MultiplayerTrayButtonStyle())
                .help("See earlier uses of this resource")
                Button("Deny") { actions.decide(approval, row.server, false) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(state.isBusy)
                Button("Approve") { actions.decide(approval, row.server, true) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(state.isBusy)
            }
        } else if let page = state.sharePage, case .approval = page.page {
            NetworkInspectorNote(text: "This request was answered or expired.")
        } else {
            NetworkInspectorNote(text: "Choose a request to see what it runs and the grant it runs under.")
        }
    }
}

// MARK: - Shared

struct NetworkSharedTable: View {
    @Environment(\.theme) private var theme
    let rows: [NetworkSharedRow]
    let selected: String?
    let now: Date
    let isBusy: Bool
    let select: (NetworkSharedRow) -> Void
    let share: (NetworkSharedRow) -> Void

    private static let name = ShellColumn(title: "resource")
    private static let people = ShellColumn(title: "shared with", width: 176)
    private static let grants = ShellColumn(title: "grants", width: 48, alignment: .trailing)
    private static let lapses = ShellColumn(title: "first lapses", width: 132, alignment: .trailing)
    private static let verbs: CGFloat = 64

    var body: some View {
        ShellTable(columns: [Self.name, Self.people, Self.grants, Self.lapses], trailing: Self.verbs, items: rows,
                   empty: "You share nothing yet. Share a worker or a repository from its menu on the wall.") { row in
            ShellTableRow(isSelected: row.id == selected, spoken: spoken(row), hint: "Shows its grants",
                          select: { select(row) }, trailing: Self.verbs) {
                HStack(spacing: Space.s) {
                    MultiplayerMark(symbol: MultiplayerResourceKind.symbol(for: row.resource.kind),
                                    tone: row.grants.isEmpty ? .neutral : .working, size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Space.s) {
                            ShellCellText(title: row.resource.name.multiplayerDisplay)
                            Text(MultiplayerResourceKind.title(for: row.resource.kind).multiplayerDisplay)
                                .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                        }
                        HStack(spacing: Space.s) {
                            ShellServerTag(id: row.server, name: row.serverName)
                            if let holder = row.holders.first { MultiplayerHolderBadge(who: holder.who) }
                        }
                    }
                }
                .shellCell(Self.name)
                people(row).shellCell(Self.people)
                ShellCellFigure(text: "\(row.grants.count)").shellCell(Self.grants)
                ShellCellFigure(text: row.nextExpiry.map { MultiplayerTime.display($0, now: now) } ?? "–").shellCell(Self.lapses)
            } verbs: {
                MultiplayerVerbStrip(verbs: [
                    MultiplayerRowVerb(id: "share", title: "Share…", isEnabled: !isBusy,
                                       hint: "Share \(row.resource.name.multiplayerDisplay) with a friend", action: { share(row) })
                ])
            }
            .padding(.vertical, Space.xs)
            .accessibilityIdentifier("network-shared-\(row.id)")
        }
    }

    /// The first three people as avatars, then how many more.
    @ViewBuilder private func people(_ row: NetworkSharedRow) -> some View {
        let people = row.people
        if people.isEmpty {
            Text("no one yet").themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
        } else {
            HStack(spacing: Space.xs) {
                ForEach(people.prefix(3), id: \.self) { MultiplayerAvatar(image: nil, name: $0, size: 18) }
                Text(people.prefix(2).map(\.multiplayerDisplay).joined(separator: ", ") + (people.count > 2 ? " +\(people.count - 2)" : ""))
                    .themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground)).lineLimit(1)
            }
        }
    }

    private func spoken(_ row: NetworkSharedRow) -> String {
        let who = row.people.isEmpty ? "shared with no one" : "shared with \(row.people.map(\.multiplayerDisplay).formatted(.list(type: .and)))"
        return "\(row.resource.name.multiplayerDisplay) on \(row.serverName), \(who)"
    }
}

/// One of your resources: every grant on it, and who holds control now.
struct NetworkSharedInspector: View {
    let row: NetworkSharedRow
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        NetworkInspector(title: row.resource.name.multiplayerDisplay, serverID: row.server, serverName: row.serverName,
                         note: actions.revoke == nil ? "Revoke a grant from the server’s page in the network panel." : nil) {
            if !row.holders.isEmpty {
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: Space.s) {
                        MultiplayerBandHeading(title: "Control", count: "\(row.holders.count)")
                        ForEach(row.holders) { holder in
                            MultiplayerHolderRow(handover: holder, resourceName: row.resource.name.multiplayerDisplay,
                                                 now: state.now, isBusy: state.isBusy,
                                                 onTakeBack: { actions.takeBack(holder, row.server) })
                        }
                    }
                }
            }
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Grants", count: row.grants.isEmpty ? nil : "\(row.grants.count)")
                    if row.grants.isEmpty {
                        Text("No one can use this yet.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                    ForEach(row.grants) { grant in
                        let key = "\(row.server)/\(grant.id)"
                        let result = state.results[NetworkActionResult.key(.grant, grant.id, on: row.server)]
                        let isRunning = state.running.contains(NetworkActionResult.key(.grant, grant.id, on: row.server))
                        MultiplayerRow(symbol: MultiplayerCapability.symbol(grant.capability), tone: .working,
                                       title: grant.handle, caption: result?.reason ?? Self.caption(grant, now: state.now)) {
                            if isRunning {
                                MultiplayerSpinner()
                            } else if actions.revoke != nil {
                                // The first press asks; the confirm under the row ends the grant.
                                Button("Revoke…") { select(revoking: key) }
                                    .buttonStyle(MultiplayerTrayButtonStyle())
                                    .disabled(state.isBusy || pages.selection.revoking == key)
                                    .accessibilityLabel("Revoke \(MultiplayerCapability.title(grant.capability)) from \(grant.handle.multiplayerDisplay)")
                            }
                        }
                        if pages.selection.revoking == key, let revoke = actions.revoke {
                            MultiplayerInlineConfirm(
                                message: "Revoke \(MultiplayerCapability.title(grant.capability)) from \(grant.handle.multiplayerDisplay)? \(grant.handle.multiplayerDisplay) can no longer use \(row.resource.name.multiplayerDisplay) this way. Requests already running finish. You can share it again later.",
                                keepTitle: "Keep grant", confirmTitle: "Revoke", isBusy: state.isBusy,
                                onCancel: { select(revoking: nil) },
                                onConfirm: {
                                    select(revoking: nil)
                                    revoke(grant, row.server)
                                })
                                .shellRevealed("revoke-\(key)")
                        }
                    }
                }
            }
        } footer: {
            Button("Audit") {
                actions.go(NetworkPlace.audit)
                actions.openAudit(row.resource.id, row.server)
            }
            .buttonStyle(MultiplayerTrayButtonStyle())
            .help("See every use of this resource")
            Button("Share…") { actions.share(row.server, nil, row.resource.id) }
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(state.isBusy)
        }
    }

    private func select(revoking key: String?) {
        var next = pages.selection
        next.revoking = key
        pages.actions.select(next)
    }

    /// "Consult, up to 10 uses, until 14:30".
    static func caption(_ grant: MultiplayerGrant, now: Date) -> String {
        var parts = [MultiplayerCapability.title(grant.capability)]
        if let uses = grant.maxUses { parts.append("up to \(MultiplayerGrantLimits.usesTitle(uses))") }
        if let expiresAt = grant.expiresAt { parts.append("until \(MultiplayerTime.display(expiresAt, now: now))") }
        return parts.joined(separator: ", ")
    }
}

/// Network, Shared.
struct NetworkSharedPage: View {
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let rows = state.sharedRows
        let selected = rows.first { $0.id == pages.selection.shared }
        NetworkPageScaffold(place: NetworkPlace.shared, pages: pages) {
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "You share", count: "\(rows.count)")
                    NetworkSharedTable(rows: rows, selected: selected?.id, now: state.now, isBusy: state.isBusy,
                                       select: { row in
                                           var next = pages.selection
                                           next.shared = row.id
                                           actions.select(next)
                                       },
                                       share: { actions.share($0.server, nil, $0.resource.id) })
                }
            } inspector: {
                if let server = pages.selection.grant {
                    NetworkGrantInspector(server: server, pages: pages)
                } else if let selected {
                    NetworkSharedInspector(row: selected, pages: pages)
                } else {
                    NetworkInspectorNote(text: "Choose a resource to see who can use it, for how long, and who holds control.")
                }
            }
        }
    }
}
