import SwiftUI

// ATOMIC LEVEL: Organisms and the page (Teams, a workspace).
// One workspace: what it is for, then one of four bands, chosen by the band tabs.
//   Board           open, claimed and done columns, with the open card beside them
//   Combined view   each member's workers, what each holds, its branch and its checks
//   Integration     the merge queue with Run merge, or the open pull requests
//   Claims          issue, path and card claims with their holders
// The card page, the claim form, the queue form and the claim, queue and pull request rows are the
// tray's, used as they are.
//
//   TeamsBoardBand, TeamsCombinedBand, TeamsIntegrationBand, TeamsClaimsBand   the bands (organisms)
//   TeamsWorkspacePage                                                         the page

/// A workspace page's values, worked out once for its bands.
struct TeamsWorkspaceContext {
    let key: String
    let server: TeamsPagesContent.Server
    let workspace: MultiplayerWorkspace
    let pages: TeamsPages

    var handle: String { server.handle }
    var isOwner: Bool { !handle.isEmpty && workspace.owner == handle }
    var name: String { workspace.name.multiplayerDisplay }
}

// MARK: - Board

struct TeamsBoardBand: View {
    let context: TeamsWorkspaceContext

    var body: some View {
        let pages = context.pages, state = pages.content, key = context.key
        let openID = pages.selection.card.flatMap { $0.hasPrefix(key + "/") ? String($0.dropFirst(key.count + 1)) : nil }
        let total = state.cards[key]?.count ?? 0
        NetworkSplit {
            VStack(alignment: .leading, spacing: Space.s) {
                ShellBandHeading(title: "Board", count: "\(total)", note: "Claim a card to work on it. Complete it with a result.") {
                    Button("New card…") { pages.send(.newCard(workspace: key)) }.buttonStyle(ThemeButtonStyle(compact: true))
                        .accessibilityIdentifier("teams-new-card")
                }
                if let problem = state.cardProblems[key] {
                    ShellNote(text: problem, lamp: .error).themePanel()
                } else if total == 0, state.readingCards.contains(key) {
                    ShellNote(text: "Reading the board…", lamp: .waiting).themePanel()
                } else {
                    TeamsBoardColumns(columns: MultiplayerCard.State.allCases.map { ($0, state.boardCards($0, in: key)) },
                                      selected: openID,
                                      open: { pages.send(.openCard($0.id, workspace: key)) },
                                      claim: { pages.send(.claimCard($0, workspace: key)) })
                }
            }
        } inspector: {
            if pages.selection.composer == .card(workspace: key) {
                cardForm
            } else if let openID, let host = pages.host {
                // The network model's own card host: it reads the card and changes it itself.
                NetworkInspector(title: "Card", serverID: context.server.id, serverName: context.name,
                                 close: { pages.send(.openCard(nil, workspace: key)) }) {
                    host(.card(openID, workspace: key))
                }
                .id(openID)
            } else if let openID, let card = state.card(openID, in: key) {
                cardInspector(card)
            } else {
                NetworkInspectorNote(text: "Choose a card to read it, claim it, or complete it with a result.")
            }
        }
    }

    private var cardForm: some View {
        let pages = context.pages, key = context.key
        return NetworkInspector(title: "New card", serverID: context.server.id, serverName: context.name,
                                note: "Anyone in the group can claim it.", close: { pages.send(.closeComposer) }) {
            TeamsFormBand(refusal: pages.content.refusal) {
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: Space.m) {
                        MultiplayerField(label: "Title") {
                            MultiplayerTextField(label: "Title", placeholder: "What needs doing", text: pages.drafts.card.title)
                        }
                        MultiplayerField(label: "Details", hint: "Markdown is shown formatted.") {
                            MultiplayerTextArea(label: "Details", text: pages.drafts.card.body, lines: 6)
                        }
                    }
                }
            }
        } footer: {
            Button("Cancel") { pages.send(.closeComposer) }.buttonStyle(MultiplayerTrayButtonStyle())
            Button("Add card") { pages.send(.sendCard) }.buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(!pages.drafts.wrappedValue.card.canSend || pages.isRunning("composer", key))
        }
    }

    private func cardInspector(_ card: MultiplayerCard) -> some View {
        let pages = context.pages, key = context.key
        let state = card.known, mine = card.isAssigned(to: context.handle)
        let busy = pages.isRunning("card", TeamsKey.make(card.id, on: key))
        let releasing = pages.selection.confirming == .releaseCard(card: card.id, workspace: key)
        return NetworkInspector(title: "Card", serverID: context.server.id, serverName: context.name,
                                state: (state.lamp, state.title, state.tone),
                                note: state == .claimed && mine ? "Completing it releases your claim." : nil,
                                close: { pages.send(.openCard(nil, workspace: key)) }) {
            MultiplayerCardPage(card: card, handle: context.handle, result: pages.drafts.cardResult,
                                confirmingRelease: releasing, isBusy: busy,
                                onCancelRelease: { pages.send(.cancelConfirmation) }, onConfirmRelease: { pages.send(.confirm) })
        } footer: {
            if state == .open {
                Button("Claim") { pages.send(.claimCard(card, workspace: key)) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary)).disabled(busy)
            } else if state == .claimed, mine {
                Button("Release…") { pages.send(.askReleaseCard(card, workspace: key)) }
                    .buttonStyle(MultiplayerTrayButtonStyle()).disabled(busy || releasing)
                Button("Complete") { pages.send(.completeCard(card, workspace: key)) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary)).disabled(busy)
            }
        }
        .id(card.id)
    }
}

// MARK: - Combined view

/// Each member's workers for the workspace: what each holds, its branch and its checks.
struct TeamsCombinedBand: View {
    @Environment(\.theme) private var theme
    let context: TeamsWorkspaceContext

    private static let member = ShellColumn(title: "member", width: 132)
    private static let worker = ShellColumn(title: "worker")
    private static let claim = ShellColumn(title: "holds")
    private static let branch = ShellColumn(title: "branch")
    private static let checks = ShellColumn(title: "checks", width: 104)
    private static let verbs: CGFloat = 56

    var body: some View {
        let pages = context.pages, key = context.key
        let rows = pages.content.combinedRows(in: key)
        VStack(alignment: .leading, spacing: Space.s) {
            ShellBandHeading(title: "Combined view", count: "\(rows.filter { $0.worker != nil }.count)",
                             note: "Every member’s workers for this workspace, with what each holds.")
            ShellTable(columns: [Self.member, Self.worker, Self.claim, Self.branch, Self.checks], trailing: Self.verbs,
                       items: rows, empty: "Nobody runs a worker for this workspace yet.") { row in
                ShellTableRow(spoken: row.spoken, trailing: Self.verbs) {
                    memberCell(row).shellCell(Self.member)
                    workerCell(row).shellCell(Self.worker)
                    claimCell(row).shellCell(Self.claim)
                    ShellCellText(title: row.worker.map { $0.branch.isEmpty ? "–" : $0.branch.multiplayerDisplay } ?? "–", isData: true)
                        .shellCell(Self.branch)
                    Group {
                        if let checks = row.worker?.checks {
                            MultiplayerStateLabel(lamp: checks.lamp, text: checks.title, tone: checks.tone)
                        } else {
                            ShellCellFigure(text: "–")
                        }
                    }
                    .shellCell(Self.checks)
                } verbs: {
                    if row.worker != nil {
                        MultiplayerVerbStrip(verbs: [
                            MultiplayerRowVerb(id: "open", title: "Open",
                                               hint: row.isMine ? "Opens the worker on the wall" : "Opens the hand-off this worker runs",
                                               action: { pages.send(.openWorker(row, workspace: key)) })
                        ])
                    }
                }
                .padding(.vertical, Space.xs)
            }
        }
    }

    @ViewBuilder private func memberCell(_ row: TeamsCombinedRow) -> some View {
        if row.showsMember {
            HStack(spacing: Space.s) {
                MultiplayerAvatar(image: nil, name: row.handle.multiplayerDisplay, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    ShellCellFigure(text: row.isMine ? "\(row.handle.multiplayerDisplay) (you)" : row.handle.multiplayerDisplay)
                    MultiplayerStateLabel(lamp: row.isOnline ? .on : .off, text: row.isOnline ? "Online" : "Offline",
                                          tone: row.isOnline ? .working : .neutral)
                }
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    @ViewBuilder private func workerCell(_ row: TeamsCombinedRow) -> some View {
        if let worker = row.worker {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(worker.name.multiplayerDisplay).themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground))
                        .lineLimit(1).layoutPriority(1)
                    Text(worker.state).themeType(theme.type.state).foregroundStyle(.theme(worker.tone.role)).lineLimit(1)
                }
                MultiplayerAgentChip(capabilities: worker.capabilities)
            }
        } else {
            Text("No worker here").themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
        }
    }

    @ViewBuilder private func claimCell(_ row: TeamsCombinedRow) -> some View {
        if let claim = row.claim {
            HStack(spacing: Space.xs + 2) {
                MultiplayerBadge(text: claim.kindTitle, symbol: claim.symbol, tone: row.isMine ? .focus : .neutral)
                Text(title(of: claim)).themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground))
                    .lineLimit(1).truncationMode(.middle)
            }
        } else {
            ShellCellFigure(text: "–")
        }
    }

    /// A card claim is named by its card.
    private func title(of claim: MultiplayerClaim) -> String {
        let card = claim.kind == MultiplayerClaim.Kind.card.rawValue ? context.pages.content.card(claim.key, in: context.key) : nil
        return (card?.title ?? claim.key).multiplayerDisplay
    }
}

// MARK: - Integration

/// How work lands: the merge queue on the owner's Mac, or the repository's open pull requests.
struct TeamsIntegrationBand: View {
    @Environment(\.theme) private var theme
    let context: TeamsWorkspaceContext

    var body: some View {
        if context.workspace.usesQueue { queue } else { pullRequests }
    }

    // MARK: Merge queue

    private var queue: some View {
        let pages = context.pages, state = pages.content, key = context.key
        let entries = state.queue[key] ?? []
        let waiting = entries.filter(\.isQueued)
        let merging = state.merging.contains(key) || pages.isRunning("merge", key)
        let confirming = pages.selection.confirming == .merge(workspace: key)
        return NetworkSplit {
            VStack(alignment: .leading, spacing: Space.s) {
                ShellBandHeading(title: "Merge queue", count: "\(entries.count)",
                                 note: context.isOwner ? "Your Mac tests each branch and merges them in order."
                                                       : "\(context.workspace.owner.multiplayerDisplay)’s Mac tests each branch and merges them in order.") {
                    if context.isOwner {
                        Button("Add branch…") { pages.send(.startQueue(workspace: key)) }.buttonStyle(ThemeButtonStyle(compact: true))
                            .disabled(merging)
                    }
                }
                TeamsRowPanel(items: entries.enumerated().map { QueueItem(position: $0.offset + 1, entry: $0.element) },
                              empty: "No branch is queued.") { item in
                    let removing = pages.selection.confirming == .removeQueued(entry: item.entry.id, workspace: key)
                    MultiplayerQueueRow(position: item.position, entry: item.entry, now: state.now,
                                        isBusy: merging || pages.isRunning("queue", TeamsKey.make(item.entry.id, on: key)),
                                        isConfirming: removing,
                                        onRemove: context.isOwner ? { pages.send(.askRemoveQueued(item.entry, workspace: key)) } : nil,
                                        onCancel: { pages.send(.cancelConfirmation) }, onConfirm: { pages.send(.confirm) })
                }
                if context.isOwner {
                    HStack(spacing: Space.s) {
                        if merging {
                            MultiplayerSpinner()
                            Text("Testing and merging \(MultiplayerPlural.count(waiting.count, "branch", "branches"))…")
                                .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                        } else {
                            Text(waiting.isEmpty ? "Nothing waits to be merged."
                                                 : "\(MultiplayerPlural.count(waiting.count, "branch", "branches")) wait to be merged into \(context.workspace.base.multiplayerDisplay).")
                                .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                        }
                        Spacer(minLength: Space.s)
                        Button("Run merge…") { pages.send(.askMerge(workspace: key)) }
                            .buttonStyle(ThemeButtonStyle(prominent: true, compact: true))
                            .disabled(waiting.isEmpty || merging || confirming)
                            .accessibilityIdentifier("teams-run-merge")
                    }
                    if confirming {
                        TeamsConfirmWell(question: "Run the merge queue for \(context.name)?",
                                         steps: waiting.map { ($0.branch.multiplayerDisplay, Self.test($0)) },
                                         consequence: "Your Mac runs each branch’s test command in its checkout, then merges it into \(context.workspace.base.multiplayerDisplay), in this order. A branch whose tests fail or that conflicts is not merged; it stays in the queue with its output.",
                                         keepTitle: "Don’t run", confirmTitle: "Run merge",
                                         cancel: { pages.send(.cancelConfirmation) }, confirm: { pages.send(.confirm) })
                    }
                }
            }
        } inspector: {
            if pages.selection.composer == .queue(workspace: key), let host = pages.host {
                NetworkInspector(title: "Add a branch", serverID: context.server.id, serverName: context.name,
                                 close: { pages.send(.closeComposer) }) {
                    host(.queue(workspace: key))
                }
            } else if pages.selection.composer == .queue(workspace: key) {
                NetworkInspector(title: "Add a branch", serverID: context.server.id, serverName: context.name,
                                 note: "It joins the end of the queue.", close: { pages.send(.closeComposer) }) {
                    TeamsFormBand(refusal: state.refusal) {
                        MultiplayerQueueForm(draft: pages.drafts.queue, workspace: context.workspace,
                                             onChooseCheckout: { pages.send(.chooseCheckout) })
                    }
                } footer: {
                    Button("Cancel") { pages.send(.closeComposer) }.buttonStyle(MultiplayerTrayButtonStyle())
                    Button("Add to queue") { pages.send(.sendQueue) }.buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(!pages.drafts.wrappedValue.queue.canSend || pages.isRunning("composer", key))
                }
            } else {
                NetworkInspectorNote(text: context.isOwner
                    ? "Add a branch a contributor pushed. Run merge asks first, naming each branch’s test command and the order."
                    : "Push your branch through the owner’s git.push grant. The owner queues and merges it.")
            }
        }
    }

    private struct QueueItem: Identifiable {
        let position: Int
        let entry: MultiplayerQueueEntry
        var id: String { entry.id }
    }

    /// A queued branch's test command, as the confirmation names it.
    static func test(_ entry: MultiplayerQueueEntry) -> String {
        entry.test.isEmpty ? "no test command" : entry.test.joined(separator: " ").multiplayerDisplay
    }

    // MARK: Pull requests

    private var pullRequests: some View {
        let pages = context.pages, key = context.key
        let load = pages.content.pullRequests[key] ?? .loading
        let list = load.value?.pullRequests ?? []
        return VStack(alignment: .leading, spacing: Space.s) {
            ShellBandHeading(title: "Pull requests", count: load.value.map { "\($0.pullRequests.count)" },
                             note: "Contributors open pull requests themselves. Read with your own gh.") {
                if let url = context.workspace.pullRequestsURL {
                    Button("Repository") { pages.send(.openLink(url)) }.buttonStyle(ThemeButtonStyle(compact: true))
                        .help(url.absoluteString)
                        .accessibilityHint("Opens the repository’s pull requests in your browser")
                }
            }
            if let failure = load.failure {
                ShellNote(text: failure, lamp: .error).themePanel()
            } else if load.value == nil {
                ShellNote(text: "Reading the open pull requests…", lamp: .waiting).themePanel()
            } else {
                TeamsRowPanel(items: list, empty: "No pull request is open.") { request in
                    MultiplayerPullRequestRow(pullRequest: request, onOpen: { pages.send(.openLink($0)) })
                }
                .frame(maxWidth: TeamsLayout.rowPanel + 200, alignment: .leading)
            }
        }
    }
}

// MARK: - Claims

/// Who holds what: issue, path and card claims. A refused claim names its holder and marks the row.
struct TeamsClaimsBand: View {
    @Environment(\.theme) private var theme
    let context: TeamsWorkspaceContext

    var body: some View {
        let pages = context.pages, state = pages.content, key = context.key
        let claims = context.workspace.claims
        NetworkSplit {
            VStack(alignment: .leading, spacing: Space.s) {
                ShellBandHeading(title: "Claims", count: "\(claims.count)",
                                 note: "A claim lapses 10 minutes after its holder’s Mac goes away.") {
                    Button("Claim…") { pages.send(.startClaim(workspace: key)) }.buttonStyle(ThemeButtonStyle(compact: true))
                        .accessibilityIdentifier("teams-claim")
                }
                TeamsRowPanel(items: claims, empty: "Nothing is claimed.") { claim in
                    let mine = claim.isHeld(by: context.handle)
                    MultiplayerClaimRow(claim: claim,
                                        title: claim.kind == MultiplayerClaim.Kind.card.rawValue ? state.card(claim.key, in: key)?.title : nil,
                                        isMine: mine, now: state.now,
                                        isBusy: pages.isRunning("claim", TeamsKey.make(claim.id, on: key)),
                                        isConfirming: pages.selection.confirming == .releaseClaim(claim: claim.id, workspace: key),
                                        onRelease: { pages.send(.askRelease(claim, workspace: key)) },
                                        onCancel: { pages.send(.cancelConfirmation) }, onConfirm: { pages.send(.confirm) })
                        // The claim that stopped the last attempt is marked.
                        .overlay(alignment: .leading) {
                            if pages.selection.conflict == claim.id {
                                Rectangle().fill(.theme(\.color.attention)).frame(width: theme.line.selectedMarker)
                                    .padding(.leading, -Space.m)
                            }
                        }
                        .accessibilityIdentifier("teams-claim-\(claim.id)")
                }
            }
        } inspector: {
            if pages.selection.composer == .claim(workspace: key), let host = pages.host {
                NetworkInspector(title: "Claim", serverID: context.server.id, serverName: context.name,
                                 close: { pages.send(.closeComposer) }) {
                    host(.claim(workspace: key))
                }
            } else if pages.selection.composer == .claim(workspace: key) {
                NetworkInspector(title: "Claim", serverID: context.server.id, serverName: context.name,
                                 note: "Others see it at once.", close: { pages.send(.closeComposer) }) {
                    TeamsFormBand(refusal: state.refusal) {
                        MultiplayerClaimForm(draft: pages.drafts.claim, workspace: context.workspace, handle: context.handle)
                    }
                } footer: {
                    Button("Cancel") { pages.send(.closeComposer) }.buttonStyle(MultiplayerTrayButtonStyle())
                    Button("Claim") { pages.send(.sendClaim) }.buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(!pages.drafts.wrappedValue.claim.canSend || pages.isRunning("composer", key))
                }
            } else {
                NetworkInspectorNote(text: "Claim an issue or paths before an agent starts on them. An overlapping claim is refused and names who holds it.")
            }
        }
    }
}

// MARK: - Page

/// Teams, one workspace.
struct TeamsWorkspacePage: View {
    let place: String
    let pages: TeamsPages

    var body: some View {
        let state = pages.content
        if let key = TeamsPlace.workspaceKey(of: place), let found = state.workspace(key) {
            let context = TeamsWorkspaceContext(key: key, server: found.server, workspace: found.workspace, pages: pages)
            let band = pages.selection.band(of: key)
            TeamsPageScaffold(place: place, pages: pages) {
                newWorkspace
            } content: {
                VStack(alignment: .leading, spacing: Space.m) {
                    TeamsFacts(facts: facts(context))
                    TeamsBandTabs(cells: cells(context), selection: band, choose: { pages.send(.showBand($0, workspace: key)) })
                }
                switch band {
                case .board: TeamsBoardBand(context: context)
                case .combined: TeamsCombinedBand(context: context)
                case .integration: TeamsIntegrationBand(context: context)
                case .claims: TeamsClaimsBand(context: context)
                }
            }
        } else {
            TeamsPageScaffold(place: place, pages: pages) {
                newWorkspace
            } content: {
                ShellLoadNote(text: place == TeamsPlace.workspaces
                              ? "You work in no workspace yet. A workspace is a goal, a repository and a group; its owner adds your group to it."
                              : "This workspace is gone, or you are no longer in its group.")
            }
        }
    }

    /// Starts a workspace. Offered where the network model hosts the form.
    @ViewBuilder private var newWorkspace: some View {
        if pages.host != nil, let server = TeamsPlace.workspaceKey(of: place).flatMap(TeamsKey.split)?.server ?? pages.content.servers.first?.id {
            Button("New workspace…") { pages.send(.newWorkspace(server: server)) }.buttonStyle(ThemeButtonStyle())
                .accessibilityIdentifier("teams-new-workspace")
        }
    }

    private func facts(_ context: TeamsWorkspaceContext) -> [(label: String, value: String)] {
        let workspace = context.workspace
        let group = context.pages.content.groupName(workspace.group, on: context.server.id) ?? workspace.group
        return [("repository", workspace.repository.multiplayerDisplay), ("base", workspace.base.multiplayerDisplay),
                ("lands by", MultiplayerIntegration.title(for: workspace.integration).lowercased()),
                ("group", group.multiplayerDisplay),
                ("owner", context.isOwner ? "you" : workspace.owner.multiplayerDisplay)]
    }

    private func cells(_ context: TeamsWorkspaceContext) -> [TeamsBandTabs.Cell] {
        let state = context.pages.content, key = context.key
        let landing = context.workspace.usesQueue ? (state.queue[key] ?? []).filter(\.isQueued).count
                                                  : state.pullRequests[key]?.value?.pullRequests.count ?? 0
        return [.init(band: .board, count: (state.cards[key] ?? []).filter { $0.known != .done }.count),
                .init(band: .combined, count: state.combinedRows(in: key).filter { $0.worker != nil }.count),
                .init(band: .integration, count: landing, tone: .focus),
                .init(band: .claims, count: context.workspace.claims.count, tone: .attention)]
    }
}
