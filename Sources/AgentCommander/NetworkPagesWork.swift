import SwiftUI

// ATOMIC LEVEL: Organisms and pages (Network: Hand-offs, Threads, Audit, Fan-out).
// What you sent and what came back. The hand-off detail, the review, the thread and the fan-out
// composer are the tray's organisms, used as they are. Two things are drawn again at page scale
// because the tray's forms are fixed to its width: the audit list becomes a table, and the
// compare columns fill the page instead of scrolling at 196 pt each.
//
//   NetworkWorkTable        requests you sent: hand-offs, reviews, fan-outs or answers (organism)
//   NetworkHandoffsPage     (page)
//   NetworkThreadsPage      (page)
//   NetworkAuditTable       every use of a shared resource (organism)
//   NetworkAuditPage        (page)
//   NetworkCompareColumns   a fan-out's answers side by side (organism)
//   NetworkFanoutPage       (page)

/// Requests you sent. `compact` leaves out the server and time columns for a narrow list.
struct NetworkWorkTable: View {
    @Environment(\.theme) private var theme
    let rows: [NetworkWorkRow]
    let selected: String?
    let now: Date
    var compact = false
    let empty: String
    let open: (NetworkWorkRow) -> Void

    private static let title = ShellColumn(title: "request")
    private static let server = ShellColumn(title: "server", width: NetworkLayout.serverColumn)
    private static let sent = ShellColumn(title: "sent", width: NetworkLayout.timeColumn, alignment: .trailing)
    private static let state = ShellColumn(title: "state", width: NetworkLayout.stateColumn, alignment: .trailing)
    private static let narrowState = ShellColumn(title: "state", width: 112, alignment: .trailing)

    var body: some View {
        ShellTable(columns: compact ? [Self.title, Self.narrowState] : [Self.title, Self.server, Self.sent, Self.state],
                   items: rows, empty: empty) { row in
            ShellTableRow(isSelected: row.id == selected,
                          spoken: "\(row.kind.title): \(row.title), \(row.target) on \(row.serverName), \(row.state)",
                          select: { open(row) }) {
                HStack(spacing: Space.s) {
                    MultiplayerMark(symbol: row.kind.symbol, tone: row.tone == .failure ? .failure : .neutral, size: 20)
                    ShellCellText(title: row.title, detail: compact ? "\(row.target), \(row.serverName)" : row.target)
                }
                .shellCell(Self.title)
                if !compact {
                    ShellServerTag(id: row.server, name: row.serverName).shellCell(Self.server)
                    ShellCellFigure(text: MultiplayerActivityRow.time(row.at, now: now)).shellCell(Self.sent)
                }
                Text(row.state).themeType(theme.type.state).lineLimit(1)
                    .foregroundStyle(.theme(row.tone == .neutral ? \.color.secondary : row.tone.role))
                    .shellCell(compact ? Self.narrowState : Self.state)
            }
            .padding(.vertical, compact ? Space.xs : 0)
            .accessibilityIdentifier("network-work-\(row.id)")
        }
    }
}

// MARK: - Hand-offs

/// Network, Hand-offs: hand-offs and reviews you sent, and the open one's status, result and artifacts.
struct NetworkHandoffsPage: View {
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let rows = state.workRows
        NetworkPageScaffold(place: NetworkPlace.handoffs, pages: pages) {
            NetworkSplit {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "Sent by you", count: "\(rows.count)",
                                     note: "Hand off a task from a friend’s agent in the Directory.")
                    NetworkWorkTable(rows: rows, selected: open(in: rows)?.id, now: state.now,
                                     empty: "You have handed nothing off yet.") { row in
                        if row.kind == .review { actions.openReview(row.request, row.server) } else { actions.openHandoff(row.request, row.server) }
                    }
                }
            } inspector: {
                inspector(open(in: rows))
            }
        }
    }

    private func open(in rows: [NetworkWorkRow]) -> NetworkWorkRow? {
        guard let page = pages.content.sharePage else { return nil }
        switch page.page {
        case .handoffDetail(let request): return rows.first { $0.kind == .handoff && $0.server == page.server && $0.request == request }
        case .review(let request): return rows.first { $0.kind == .review && $0.server == page.server && $0.request == request }
        default: return nil
        }
    }

    @ViewBuilder private func inspector(_ row: NetworkWorkRow?) -> some View {
        let state = pages.content, actions = pages.actions
        let server = row.flatMap { state.server($0.server) }
        if let row, row.kind == .handoff, let sent = server?.handoffs.first(where: { $0.request == row.request }) {
            let draft = pages.selection.apply.flatMap { $0.server == row.server && $0.request == sent.request ? $0 : nil }
            NetworkInspector(title: "Hand-off", serverID: row.server, serverName: row.serverName,
                             note: actions.apply == nil ? "Apply an artifact from the network panel." : nil, close: actions.close) {
                // First in the inspector, so the confirmation and each result are in view without scrolling.
                NetworkApplyBand(outcomes: NetworkApplyOutcome.list(for: sent.request, on: row.server,
                                                                    artifacts: state.reports[sent.request]?.artifacts ?? [],
                                                                    results: state.results, running: state.running),
                                 draft: draft, isBusy: state.isBusy,
                                 cancel: actions.cancelApply, confirm: actions.confirmApply)
                MultiplayerHandoffDetail(row: sent, target: row.target, state: state.state(of: sent),
                                         report: state.reports[sent.request], now: state.now,
                                         // One artifact at a time: a waiting confirmation holds the others.
                                         isBusy: state.isBusy || draft != nil || (actions.apply == nil && actions.openPanel == nil),
                                         onApply: { index, artifact in
                                             if let apply = actions.apply { apply(index, artifact, sent, row.server) } else { actions.openPanel?() }
                                         })
            } footer: {
                Button("Thread") {
                    actions.go(NetworkPlace.threads)
                    actions.openThread(sent.request, sent.title, row.server)
                }
                .buttonStyle(MultiplayerTrayButtonStyle())
                Button("Check status") { actions.check(sent, row.server, false) }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(state.isBusy || sent.run == nil)
                Button("Get result") { actions.check(sent, row.server, true) }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(state.isBusy || sent.run == nil)
                    .help("Reads the run’s report and artifacts. Nothing is applied until you choose to.")
            }
        } else if let row, row.kind == .review, let sent = server?.reviews.first(where: { $0.request == row.request }) {
            NetworkInspector(title: "Review", serverID: row.server, serverName: row.serverName, close: actions.close) {
                MultiplayerReviewPage(row: sent, target: row.target, review: MultiplayerReview(sent.value), now: state.now,
                                      link: pages.drafts.reviewLink, posted: state.posted[sent.request],
                                      confirming: state.confirmingPost, problem: state.postProblem, isBusy: state.isBusy,
                                      onCancel: actions.cancelPost, onConfirm: actions.confirmPost)
            } footer: {
                Button("Thread") {
                    actions.go(NetworkPlace.threads)
                    actions.openThread(sent.request, sent.title, row.server)
                }
                .buttonStyle(MultiplayerTrayButtonStyle())
                Button("Post to PR…", action: actions.askPost)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(state.isBusy || state.confirmingPost || state.postProblem != nil)
                    .help(state.postProblem ?? "Shows what will be posted, then asks you to confirm")
            }
        } else if let page = state.sharePage, page.page.isWorkDetail {
            NetworkInspectorNote(text: "Commander can’t find this request any more.")
        } else {
            NetworkInspectorNote(text: "Choose a hand-off to check its run, read its result and see what it left to apply.")
        }
    }
}

// MARK: - Apply

/// How applying one artifact of a hand-off's result ended, or that it is running.
struct NetworkApplyOutcome: Identifiable, Equatable {
    enum State: Equatable { case running, done(String), failed(String) }

    let index: Int
    let name: String
    let state: State

    var id: Int { index }

    var lamp: MultiplayerLamp.Kind {
        switch state {
        case .running: .waiting
        case .done: .on
        case .failed: .error
        }
    }

    var word: String {
        switch state {
        case .running: "Applying"
        case .done: "Done"
        case .failed: "Not applied"
        }
    }

    var tone: Tone {
        switch state {
        case .running: .neutral
        case .done: .working
        case .failed: .failure
        }
    }

    /// The sentence under the artifact's name.
    var sentence: String {
        switch state {
        case .running: "Writing it into the checkout…"
        case .done(let message): message
        case .failed(let reason): reason
        }
    }

    /// One outcome per artifact that was applied or is being applied, in the artifacts' order.
    static func list(for request: String, on server: String, artifacts: [MultiplayerArtifact],
                     results: [String: NetworkActionResult], running: Set<String>) -> [NetworkApplyOutcome] {
        artifacts.enumerated().compactMap { index, artifact in
            let key = NetworkApplyDraft.key(request: request, index: index, on: server)
            let name = artifact.name.multiplayerDisplay
            if running.contains(key) { return NetworkApplyOutcome(index: index, name: name, state: .running) }
            switch results[key] {
            case .done(_, _, let message)?:
                return NetworkApplyOutcome(index: index, name: name, state: .done(message ?? "Done. Nothing was overwritten."))
            case .failed(_, _, let reason)?:
                return NetworkApplyOutcome(index: index, name: name, state: .failed(reason))
            case nil:
                return nil
            }
        }
    }
}

/// Under a hand-off's artifacts: the confirmation for the artifact about to be applied, naming
/// the checkout, and how each artifact applied so far ended. It sits in the tray's hand-off
/// detail, so it is built from the tray's own band, well and state label.
struct NetworkApplyBand: View {
    static let confirmation = "network-apply-confirmation"

    let outcomes: [NetworkApplyOutcome]
    let draft: NetworkApplyDraft?
    let isBusy: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        if draft != nil || !outcomes.isEmpty {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: outcomes.isEmpty ? "Apply to a checkout" : "Applied", count: outcomes.isEmpty ? nil : "\(outcomes.count)")
                    ForEach(outcomes) { outcome in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Text(outcome.name).font(MultiplayerTheme.data).foregroundStyle(MultiplayerTheme.foreground)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if outcome.state == .running { MultiplayerSpinner() }
                                MultiplayerStateLabel(lamp: outcome.lamp, text: outcome.word, tone: outcome.tone)
                            }
                            Text(outcome.sentence)
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(outcome.tone == .failure ? AnyShapeStyle(MultiplayerTheme.failure) : AnyShapeStyle(.inkSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(outcome.name): \(outcome.word). \(outcome.sentence)")
                        .multiplayerArriving()
                    }
                    if let draft {
                        MultiplayerWell(edge: MultiplayerTheme.attention.opacity(0.6)) {
                            VStack(alignment: .leading, spacing: Space.s) {
                                Text(draft.question)
                                    .font(MultiplayerTheme.name)
                                    .foregroundStyle(MultiplayerTheme.foreground)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                Text(draft.shownPath)
                                    .font(MultiplayerTheme.mono)
                                    .foregroundStyle(MultiplayerTheme.focus)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .accessibilityLabel("Checkout folder: \(draft.shownPath)")
                                Text(draft.consequence)
                                    .font(MultiplayerTheme.sub)
                                    .foregroundStyle(.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: Space.s) {
                                    Spacer(minLength: 0)
                                    Button(draft.isPatch ? "Don’t apply" : "Don’t save", action: cancel)
                                        .buttonStyle(MultiplayerTrayButtonStyle())
                                        .keyboardShortcut(.cancelAction)
                                    Button(draft.confirmTitle, action: confirm)
                                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                                        .disabled(isBusy)
                                }
                            }
                        }
                        .multiplayerArriving()
                        .id(Self.confirmation)
                        .accessibilityIdentifier(Self.confirmation)
                    }
                }
                .multiplayerStreaming(draft)
            }
        }
    }
}

private extension MultiplayerSharePage {
    var isWorkDetail: Bool {
        switch self {
        case .handoffDetail, .review: true
        default: false
        }
    }
}

// MARK: - Threads

/// Network, Threads: every request you sent, and the open one's comments.
struct NetworkThreadsPage: View {
    @Environment(\.theme) private var theme
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let rows = state.threadRows
        let open = openThread(in: rows)
        NetworkPageScaffold(place: NetworkPlace.threads, pages: pages) {
            CollectionInspector(collectionWidth: NetworkLayout.listWidth + 60, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "Requests", count: "\(rows.count)")
                    NetworkWorkTable(rows: rows, selected: open?.row?.id, now: state.now, compact: true,
                                     empty: "Nothing you sent has a thread yet.") { row in
                        actions.openThread(row.request, row.title, row.server)
                    }
                }
            } inspector: {
                if let open {
                    NetworkInspector(title: "Thread", serverID: open.server,
                                     serverName: state.serverName(open.server),
                                     note: "⌘Return posts.", close: actions.close) {
                        MultiplayerThreadPage(title: open.title, state: state.thread, draft: pages.drafts.comment, now: state.now,
                                              onRetry: actions.reload)
                    } footer: {
                        Button("Refresh", action: actions.reload).buttonStyle(MultiplayerTrayButtonStyle())
                        Button("Post comment", action: actions.postComment)
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!state.canComment)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                } else {
                    NetworkInspectorNote(text: "Choose a request to read its thread and add a comment.")
                        .frame(maxWidth: 680, alignment: .leading)
                }
            }
        }
    }

    /// The thread open in the model, with its row when the list has it.
    private func openThread(in rows: [NetworkWorkRow]) -> (server: String, title: String, row: NetworkWorkRow?)? {
        guard let page = pages.content.sharePage, case .thread(let request, let title) = page.page else { return nil }
        return (page.server, title, rows.first { $0.server == page.server && $0.request == request })
    }
}

// MARK: - Audit

/// Every use of a shared resource as a table. The tray's audit page is a list at 400 pt; this is
/// its form at page scale, with the same words for each outcome.
struct NetworkAuditTable: View {
    @Environment(\.theme) private var theme
    let entries: [MultiplayerAuditEntry]
    let resourceName: (String) -> String
    let now: Date

    private static let when = ShellColumn(title: "when", width: NetworkLayout.timeColumn)
    private static let who = ShellColumn(title: "who", width: NetworkLayout.personColumn)
    private static let action = ShellColumn(title: "did", width: 148)
    private static let resource = ShellColumn(title: "on", width: 148)
    private static let summary = ShellColumn(title: "summary")
    private static let took = ShellColumn(title: "took", width: 60, alignment: .trailing)
    private static let tokens = ShellColumn(title: "tokens", width: 72, alignment: .trailing)
    private static let outcome = ShellColumn(title: "outcome", width: 112, alignment: .trailing)

    var body: some View {
        ShellTable(columns: [Self.when, Self.who, Self.action, Self.resource, Self.summary, Self.took, Self.tokens, Self.outcome],
                   items: entries,
                   empty: "Nothing has run yet. Each request a friend sends, and each one you send, is recorded here with its outcome.") { entry in
            ShellTableRow(spoken: spoken(entry)) {
                ShellCellFigure(text: MultiplayerActivityRow.time(entry.started ?? entry.ended, now: now)).shellCell(Self.when)
                HStack(spacing: Space.xs + 2) {
                    MultiplayerAvatar(image: nil, name: entry.peer.isEmpty ? "?" : entry.peer, size: 18)
                    ShellCellFigure(text: entry.peer.isEmpty ? "someone" : entry.peer.multiplayerDisplay)
                }
                .shellCell(Self.who)
                Text(MultiplayerCapability.title(entry.action)).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                    .lineLimit(1).shellCell(Self.action)
                ShellCellFigure(text: resourceName(entry.resource)).shellCell(Self.resource)
                Text(MultiplayerText.clean(entry.summary, limit: 200, redact: true)).themeType(theme.type.sub)
                    .foregroundStyle(.theme(\.color.secondary)).lineLimit(1).textSelection(.enabled)
                    .shellCell(Self.summary)
                ShellCellFigure(text: Self.duration(entry) ?? "–").shellCell(Self.took)
                ShellCellFigure(text: entry.tokens > 0 ? entry.tokens.formatted() : "–").shellCell(Self.tokens)
                Text(entry.outcomeTitle).themeType(theme.type.state).lineLimit(1)
                    .foregroundStyle(.theme(entry.outcomeTone == .neutral ? \.color.secondary : entry.outcomeTone.role))
                    .shellCell(Self.outcome)
            }
        }
    }

    /// How long a request ran: "42 s" or "3 min".
    static func duration(_ entry: MultiplayerAuditEntry) -> String? {
        guard let started = entry.started, let ended = entry.ended, ended > started else { return nil }
        let seconds = Int(ended.timeIntervalSince(started).rounded())
        return seconds < 60 ? "\(max(seconds, 1)) s" : "\(seconds / 60) min"
    }

    private func spoken(_ entry: MultiplayerAuditEntry) -> String {
        let who = entry.peer.isEmpty ? "Someone" : entry.peer.multiplayerDisplay
        return "\(who): \(MultiplayerCapability.title(entry.action).lowercasedFirst), "
            + MultiplayerAuditPage.caption(entry, resourceName: resourceName, now: now) + ", \(entry.outcomeTitle)"
    }
}

/// Network, Audit: one server's log, for every resource or one.
struct NetworkAuditPage: View {
    @Environment(\.theme) private var theme
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let open = openAudit
        NetworkPageScaffold(place: NetworkPlace.audit, pages: pages) {
            Button("Refresh", action: actions.reload).buttonStyle(ThemeButtonStyle()).disabled(open == nil)
        } content: {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.m) {
                    ShellBandHeading(title: "Log", count: state.audit.value.map { "\($0.count)" },
                                     note: "The latest 200 entries, kept on this Mac.")
                    if state.online.count > 1 {
                        ShellSegments(options: state.online.map { (value: $0.id, title: $0.name, help: "The audit log of \($0.name)") },
                                      selection: open?.server ?? "", choose: { actions.openAudit("", $0) })
                            .accessibilityLabel("Server")
                    }
                    if let open, let server = state.server(open.server), !server.resources.isEmpty {
                        Menu {
                            Button("Every resource") { actions.openAudit("", open.server) }
                            Divider()
                            ForEach(server.resources) { resource in
                                Button(resource.name.multiplayerDisplay) { actions.openAudit(resource.id, open.server) }
                            }
                        } label: {
                            Text(open.resource.isEmpty ? "Every resource" : state.resourceName(open.resource, on: open.server))
                        }
                        .menuStyle(.button)
                        .buttonStyle(ThemeButtonStyle(compact: true))
                        .fixedSize()
                        .accessibilityLabel("Resource")
                    }
                }
                if let open {
                    switch state.audit {
                    case .loading:
                        ShellNote(text: "Reading the audit log…", lamp: .waiting).themePanel()
                    case .failed(let message):
                        HStack {
                            ShellNote(text: message, lamp: .error)
                            Button("Try again", action: actions.reload).buttonStyle(ThemeButtonStyle(compact: true))
                                .padding(.trailing, Space.m)
                        }
                        .themePanel()
                    case .loaded(let entries):
                        NetworkAuditTable(entries: entries, resourceName: { state.resourceName($0, on: open.server) }, now: state.now)
                    }
                } else {
                    ShellNote(text: state.online.isEmpty ? "Sign in to a server to read its audit log." : "Choose a server to read its audit log.")
                        .themePanel()
                }
            }
        }
    }

    private var openAudit: (server: String, resource: String)? {
        guard let page = pages.content.sharePage, case .audit(let resource) = page.page else { return nil }
        return (page.server, resource)
    }
}

// MARK: - Fan-out

/// A fan-out's answers side by side, each column as wide as the page allows. More columns than
/// fit keep a readable measure and scroll sideways.
struct NetworkCompareColumns: View {
    @Environment(\.theme) private var theme
    let columns: [MultiplayerComparePage.Column]
    let winner: String?
    let choose: (MultiplayerFanoutChild) -> Void
    let thread: (MultiplayerFanoutChild) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(width: nil).frame(minWidth: CGFloat(columns.count) * NetworkLayout.answerColumn)
            ScrollView(.horizontal) { grid(width: NetworkLayout.answerColumn) }
                .scrollIndicators(.visible)
                .accessibilityLabel("Answers, \(columns.count) columns")
        }
        .animation(theme.motion.animation(theme.motion.standard), value: winner)
    }

    private func grid(width: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                if index > 0 { ThemeRule(vertical: true) }
                cell(column)
                    .frame(width: width)
                    .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ column: MultiplayerComparePage.Column) -> some View {
        let child = column.child
        let isWinner = winner == child.id
        return VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(column.name.multiplayerDisplay).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                    .lineLimit(1).truncationMode(.middle)
                Text(column.owner.multiplayerDisplay).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                if let chip = column.capabilities, chip.headline != nil { MultiplayerAgentChip(capabilities: chip) }
                MultiplayerStateLabel(lamp: child.succeeded ? .on : child.isSettled ? .error : .waiting,
                                      text: MultiplayerRequestState.title(child.status),
                                      tone: MultiplayerRequestState.tone(child.status))
                    .padding(.top, 2)
            }
            .accessibilityElement(children: .combine)
            ThemeRule()
            if child.succeeded {
                Text(child.answer).themeType(theme.type.body).foregroundStyle(.theme(\.color.foreground))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if child.isSettled {
                Text(MultiplayerSentRequest(request: child.id, status: child.status).refusal ?? "No answer.")
                    .themeType(theme.type.sub).foregroundStyle(.theme(\.color.failure))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: Space.xs + 2) {
                    MultiplayerSpinner(size: 10)
                    Text("Waiting for this worker.").themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.s) {
                if child.succeeded {
                    Button(isWinner ? "Winner" : "Choose winner") { choose(child) }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: isWinner ? .primary : .standard))
                        .help(isWinner ? "Clear this choice" : "Mark this answer as the one you’ll use")
                        .accessibilityLabel(isWinner ? "\(column.name.multiplayerDisplay) is the winner"
                                                     : "Choose \(column.name.multiplayerDisplay) as the winner")
                        .accessibilityHint(isWinner ? "Clears the choice" : "Recorded on this Mac only")
                        .accessibilityAddTraits(isWinner ? .isSelected : [])
                }
                Spacer(minLength: 0)
                SymbolButton(symbol: "bubble.left.and.bubble.right", label: "Thread with \(column.name.multiplayerDisplay)") { thread(child) }
                    .foregroundStyle(.theme(\.color.secondary))
            }
        }
        .padding(Space.m)
        .background(isWinner ? theme.color.selection.opacity(0.35).color : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(isWinner ? theme.color.focus.color : Color.clear).frame(height: theme.line.selectedMarker)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.name.multiplayerDisplay), \(column.owner.multiplayerDisplay)\(isWinner ? ", winner" : "")")
    }
}

/// Network, Fan-out: the fan-outs you sent and the open one's answers, or the composer.
struct NetworkFanoutPage: View {
    @Environment(\.theme) private var theme
    let pages: NetworkPages

    var body: some View {
        let state = pages.content, actions = pages.actions
        let rows = state.fanoutRows
        let open = openFanout
        let servers = state.online.filter { $0.fanoutTargets.count >= MultiplayerFanoutDraft.targetRange.lowerBound }
        NetworkPageScaffold(place: NetworkPlace.fanout, pages: pages) {
            if servers.count == 1, let only = servers.first {
                Button("New fan-out…") { actions.startFanout(only.id) }.buttonStyle(ThemeButtonStyle(prominent: true))
                    .disabled(state.isBusy)
            } else {
                Menu("New fan-out…") {
                    ForEach(servers) { server in Button("On \(server.name)") { actions.startFanout(server.id) } }
                }
                .menuStyle(.button)
                .buttonStyle(ThemeButtonStyle(prominent: true))
                .fixedSize()
                .disabled(state.isBusy || servers.isEmpty)
                .help(servers.isEmpty ? "A fan-out needs two workers you may consult on one server" : "Choose the server to fan out on")
            }
        } content: {
            CollectionInspector(collectionWidth: NetworkLayout.listWidth, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.s) {
                    ShellBandHeading(title: "Sent by you", count: "\(rows.count)")
                    NetworkWorkTable(rows: rows, selected: open.map { "\($0.server)/\($0.fanout.request)" }, now: state.now,
                                     compact: true, empty: "You have sent no fan-out yet.") { row in
                        actions.openFanout(row.request, row.server)
                    }
                }
            } inspector: {
                if let page = state.sharePage, page.page == .fanout {
                    composer(on: page.server)
                } else if let open {
                    compare(open.fanout, on: open.server)
                } else {
                    NetworkInspectorNote(text: "Choose a fan-out to compare its answers, or start a new one.")
                }
            }
        }
    }

    private var openFanout: (server: String, fanout: MultiplayerFanout)? {
        guard let page = pages.content.sharePage, case .compare(let request) = page.page,
              let fanout = pages.content.server(page.server)?.fanouts.first(where: { $0.request == request }) else { return nil }
        return (page.server, fanout)
    }

    private func composer(on server: String) -> some View {
        let state = pages.content, actions = pages.actions
        let count = pages.drafts.fanout.wrappedValue.targets.count
        return NetworkInspector(title: "Fan out", serverID: server, serverName: state.serverName(server),
                                note: count < 2 ? "Choose at least 2 workers." : nil, close: actions.back) {
            MultiplayerFanoutComposer(draft: pages.drafts.fanout, targets: state.server(server)?.fanoutTargets ?? [],
                                      onToggle: actions.toggleFanoutTarget)
        } footer: {
            Button("Cancel", action: actions.back).buttonStyle(MultiplayerTrayButtonStyle())
            Button("Send to \(max(count, 2))", action: actions.sendFanout)
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!state.canSendFanout)
        }
        .frame(maxWidth: NetworkLayout.inspectorWidth + 60, alignment: .leading)
    }

    private func compare(_ fanout: MultiplayerFanout, on server: String) -> some View {
        let state = pages.content, actions = pages.actions
        let columns = fanout.children.map { child -> MultiplayerComparePage.Column in
            let entry = state.entry(child.resource, on: server)
            return MultiplayerComparePage.Column(child: child, name: entry?.name ?? child.resource, owner: entry?.owner ?? "",
                                                 capabilities: entry?.capabilities)
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                MultiplayerSwatch(color: MultiplayerTheme.swatch(for: server))
                VStack(alignment: .leading, spacing: 2) {
                    Text(fanout.title.isEmpty ? "Untitled fan-out" : fanout.title.multiplayerDisplay)
                        .themeType(theme.type.title).foregroundStyle(.theme(\.color.foreground))
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    Text("\(columns.count) workers on \(state.serverName(server)), sent \(MultiplayerActivityRow.time(fanout.at, now: state.now))")
                        .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                if fanout.answered > 0 { MultiplayerSignedBadge() }
                MultiplayerStateLabel(lamp: fanout.isSettled ? .on : .waiting, text: fanout.progress,
                                      tone: fanout.isSettled ? .working : .attention)
            }
            .padding(.horizontal, theme.space.sectionInset)
            .padding(.vertical, Space.m)
            ThemeRule()
            if columns.isEmpty {
                ShellNote(text: "Commander no longer has this fan-out’s targets. Send it again to compare.")
            } else {
                NetworkCompareColumns(columns: columns, winner: state.winner(of: fanout.request, on: server),
                                      choose: { actions.chooseWinner($0.id, fanout.request, server) },
                                      thread: { child in
                                          let name = state.entry(child.resource, on: server)?.name ?? child.resource
                                          actions.go(NetworkPlace.threads)
                                          actions.openThread(child.id, "\(name.multiplayerDisplay): \(fanout.title)", server)
                                      })
            }
            ThemeRule()
            Text("The winner is a note on this Mac. Nothing is sent.")
                .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                .padding(.horizontal, theme.space.sectionInset).padding(.vertical, Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface.footerFill.color)
        }
        .themePanel()
        .accessibilityIdentifier("network-compare")
    }
}
