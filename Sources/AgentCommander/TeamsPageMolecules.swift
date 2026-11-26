import SwiftUI

// ATOMIC LEVEL: Molecules, organisms and the page template (main-window Teams pages).
// What the full-size Teams pages add to the network pages' pieces (NetworkPageMolecules.swift).
// Each reads `\.theme`, takes values and emits one targeted action. The tray's atoms and its value
// organisms (claim, queue and pull request rows, endorsement chips, output well, inline confirm,
// the forms) are used as they are.
//
//   TeamsLayout           widths of the board and the forms (foundation)
//   TeamsBandTabs         a workspace's bands as joined cells with their counts (molecule)
//   TeamsFacts            labelled values on one line (molecule)
//   TeamsHolderBadge      who holds a claimed card (atom)
//   TeamsBoardCardView    one card of the board (molecule)
//   TeamsBoardColumns     open, claimed and done, divided by hairlines (organism)
//   TeamsConfirmWell      the second press that names what it does: merge, install, set policy (molecule)
//   TeamsRowPanel         tray rows on one panel, ruled off by hairlines (molecule)
//   TeamsFormBand         a refusal over a form inside an inspector (molecule)
//   TeamsPageScaffold     header, telemetry strip, alert band, then the page's bands (template)

enum TeamsLayout {
    /// The least a board column narrows to.
    static let boardColumn: CGFloat = 168
    /// The least height of a board column, so an empty column still reads as a column.
    static let boardHeight: CGFloat = 220
    /// The widest a form or a panel of rows grows on a wide page.
    static let rowPanel: CGFloat = 640
}

// MARK: - Molecules

/// A workspace's bands as joined cells. One band shows at a time; each cell carries its count.
struct TeamsBandTabs: View {
    struct Cell: Identifiable {
        let band: TeamsBand
        let count: Int
        var tone: Tone = .neutral

        var id: String { band.id }
    }

    @Environment(\.theme) private var theme
    let cells: [Cell]
    let selection: TeamsBand
    let choose: (TeamsBand) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                let isOn = cell.band == selection
                if index > 0 { ThemeRule(vertical: true) }
                Button { choose(cell.band) } label: {
                    HStack(spacing: Space.s) {
                        Text(cell.band.title).themeType(theme.type.heading).textCase(nil)
                            .foregroundStyle(.theme(isOn ? \.color.foreground : \.color.secondary))
                        Text("\(cell.count)").themeType(theme.type.heading).monospacedDigit()
                            .foregroundStyle(.theme(cell.count > 0 && cell.tone != .neutral ? cell.tone.role : \.color.foreground))
                            .contentTransition(.numericText())
                    }
                    .lineLimit(1)
                    .padding(.horizontal, theme.space.sectionInset)
                    .frame(minHeight: theme.space.tabHeight)
                    .background(isOn ? theme.color.panel.color : Color.clear)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.theme(\.color.focus)).frame(height: isOn ? theme.line.selectedMarker : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(cell.band.title), \(cell.count)")
                .accessibilityValue(isOn ? "Selected" : "")
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("teams-band-\(cell.band.id)")
            }
            Spacer(minLength: 0)
        }
        .background(theme.color.well.color)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.theme(\.color.hair), lineWidth: theme.line.hairline) }
        .animation(theme.motion.animation(theme.motion.fast), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bands")
    }
}

/// Labelled values on one line: a workspace's repository, base, integration and group.
struct TeamsFacts: View {
    @Environment(\.theme) private var theme
    let facts: [(label: String, value: String)]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: Space.xs + 2) {
                    Text(fact.label).themeType(theme.type.label).textCase(nil).foregroundStyle(.theme(\.color.secondary))
                    Text(fact.value).themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(fact.label): \(fact.value)")
            }
            Spacer(minLength: 0)
        }
    }
}

/// Who holds a claimed card: the person and the agent, as a badge. Yours is in the focus tone.
struct TeamsHolderBadge: View {
    let holder: String
    let isMine: Bool

    var body: some View {
        MultiplayerBadge(text: holder.multiplayerDisplay, symbol: "terminal", tone: isMine ? .focus : .attention)
            .accessibilityLabel(isMine ? "Held by you, as \(holder.multiplayerDisplay)" : "Held by \(holder.multiplayerDisplay)")
    }
}

/// One card of the board: square, no shadow. Its text opens the card; its one verb moves it on.
struct TeamsBoardCardView: View {
    @Environment(\.theme) private var theme
    let item: TeamsBoardCard
    let isSelected: Bool
    let open: () -> Void
    let claim: () -> Void

    var body: some View {
        let card = item.card, state = card.known
        let shape = RoundedRectangle(cornerRadius: theme.radius.tile, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: Space.xs + 2) {
                    Text(card.title.multiplayerDisplay).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                        .lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if !card.assignee.isEmpty, state != .done {
                        TeamsHolderBadge(holder: card.assignee, isMine: item.isMine)
                    } else if state == .done, !card.assignee.isEmpty {
                        Text(card.assignee.multiplayerDisplay).themeType(theme.type.fingerprint)
                            .foregroundStyle(.theme(\.color.secondary)).lineLimit(1).truncationMode(.middle)
                    }
                    if let text = item.result?.rowText {
                        Text(text).themeType(theme.type.sub).foregroundStyle(.theme(item.result?.rowTone.role ?? \.color.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
            .accessibilityHint("Opens the card")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if item.isRunning {
                MultiplayerSpinner().accessibilityLabel("In progress")
            } else if state == .open {
                Button("Claim", action: claim).buttonStyle(MultiplayerTrayButtonStyle())
                    .accessibilityLabel("Claim \(card.title.multiplayerDisplay)")
            } else if state == .claimed, item.isMine {
                Button("Complete…", action: open).buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .accessibilityLabel("Complete \(card.title.multiplayerDisplay)")
            }
        }
        .padding(.vertical, Space.s)
        .padding(.leading, Space.m)
        .padding(.trailing, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? theme.color.selection.color : theme.color.well.color, in: shape)
        .overlay(alignment: .leading) {
            Rectangle().fill(.theme(isSelected ? \.color.focus : state == .open ? \.color.border : state.tone.role))
                .frame(width: theme.line.selectedMarker)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.theme(\.color.hair), lineWidth: theme.line.hairline) }
        .accessibilityIdentifier("teams-card-\(card.id)")
    }

    private var spoken: String {
        var parts = [item.card.title.multiplayerDisplay, item.card.known.title]
        if !item.card.assignee.isEmpty { parts.append(item.isMine ? "held by you" : "held by \(item.card.assignee.multiplayerDisplay)") }
        if let text = item.result?.rowText { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Organisms

/// The board: one column per state on one panel, divided by hairlines. Each column's heading is
/// its state as a lamp and a word, then its count.
struct TeamsBoardColumns: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let columns: [(state: MultiplayerCard.State, cards: [TeamsBoardCard])]
    /// The open card's ID.
    let selected: String?
    let open: (MultiplayerCard) -> Void
    let claim: (MultiplayerCard) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.state) { index, column in
                if index > 0 { ThemeRule(vertical: true) }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Space.s) {
                        MultiplayerStateLabel(lamp: column.state.lamp, text: column.state.title, tone: column.state.tone)
                        Text("\(column.cards.count)").themeType(theme.type.heading).monospacedDigit()
                            .foregroundStyle(.theme(\.color.foreground)).contentTransition(.numericText())
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.m)
                    .frame(minHeight: theme.space.controlHeightLarge)
                    .background(theme.surface.headerFill.color)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("\(column.state.title), \(MultiplayerPlural.count(column.cards.count, "card"))")
                    ThemeRule()
                    VStack(alignment: .leading, spacing: Space.s) {
                        if column.cards.isEmpty {
                            Text(empty(column.state)).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(column.cards) { item in
                            TeamsBoardCardView(item: item, isSelected: item.id == selected,
                                               open: { open(item.card) }, claim: { claim(item.card) })
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -theme.motion.travel)))
                        }
                    }
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: TeamsLayout.boardColumn, maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(column.state.title) cards")
            }
        }
        .frame(minHeight: TeamsLayout.boardHeight, alignment: .top)
        .themePanel()
        .animation(theme.motion.animation(theme.motion.standard), value: columns.map { $0.cards.map(\.id) })
        .accessibilityIdentifier("teams-board")
    }

    private func empty(_ state: MultiplayerCard.State) -> String {
        switch state {
        case .open: "Nothing is open. Add a card to offer work."
        case .claimed: "Nobody holds a card."
        case .done: "Nothing is finished yet."
        }
    }
}

/// The second press before something that writes or runs: the question, exactly what it acts on,
/// the order when there is one, one sentence about what happens, then a keep button and a primary
/// button. Nothing happens before the primary button.
struct TeamsConfirmWell: View {
    @Environment(\.theme) private var theme
    let question: String
    /// What it writes to or runs, as data: a path, a command, a destination.
    var target: String? = nil
    /// What it does in order, such as the branches of a merge. Numbered because the order is real.
    var steps: [(title: String, detail: String)] = []
    /// Lines of "label: value" naming what changes.
    var changes: [(label: String, value: String)] = []
    let consequence: String
    let keepTitle: String
    let confirmTitle: String
    var isBusy = false
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.tile, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s) {
            Text(question).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if let target {
                Text(target).themeType(theme.type.mono).foregroundStyle(.theme(\.color.focus))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text("\(index + 1)").themeType(theme.type.label).monospacedDigit()
                                .foregroundStyle(.theme(\.color.secondary)).frame(width: 14, alignment: .trailing)
                            Text(step.title).themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground))
                                .lineLimit(1).truncationMode(.middle)
                            Text(step.detail).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.focus))
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel("\(index + 1). \(step.title), \(step.detail)")
                    }
                }
            }
            if !changes.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(change.label).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                            Text(change.value).themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel("\(change.label): \(change.value)")
                    }
                }
            }
            Text(consequence).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button(keepTitle, action: cancel).buttonStyle(MultiplayerTrayButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm).buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(isBusy)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color.well.color, in: shape)
        .overlay { shape.strokeBorder(theme.color.attention.opacity(0.6).color, lineWidth: theme.line.hairline) }
        .multiplayerArriving()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm")
        .accessibilityIdentifier("teams-confirmation")
    }
}

/// Rows drawn by the tray's own row organisms, on one panel and ruled off by hairlines.
struct TeamsRowPanel<Item: Identifiable, Row: View>: View {
    @Environment(\.theme) private var theme
    let items: [Item]
    let empty: String
    var emptyLamp: MultiplayerLamp.Kind = .off
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty { ShellNote(text: empty, lamp: emptyLamp) }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ThemeRule() }
                row(item).padding(.horizontal, Space.m)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
    }
}

/// A form inside an inspector: why its last send was refused, then the form.
struct TeamsFormBand<Form: View>: View {
    let refusal: String?
    @ViewBuilder var form: Form

    var body: some View {
        if let refusal {
            MultiplayerBand { MultiplayerBanner(kind: .failure, message: refusal) }
                .accessibilityIdentifier("teams-form-refusal")
        }
        form
    }
}

// MARK: - Template

/// A Teams page: the header with its one action, the telemetry strip, how the last action ended,
/// then the page's bands. Without a helper or a server it says so instead of the bands.
struct TeamsPageScaffold<Actions: View, Content: View>: View {
    @Environment(\.theme) private var theme
    let place: String
    let pages: TeamsPages
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        let state = pages.content
        WorkspacePage {
            PageHeader(kicker: state.kicker(for: place), title: state.title(for: place), subtitle: state.summary(for: place)) {
                actions
            }
        } content: {
            VStack(alignment: .leading, spacing: theme.space.sectionGap) {
                if state.isUnavailable || state.servers.isEmpty {
                    ShellLoadNote(text: state.isUnavailable
                                  ? "Commander can’t reach the network helper, so there is nothing to show here."
                                  : "Add a server in Network, Servers. Your teams show here once you sign in.",
                                  lamp: state.isUnavailable ? .error : .off)
                } else {
                    let readouts = state.readouts(for: place)
                    if !readouts.isEmpty { ShellReadoutStrip(cells: readouts, large: true) }
                    if let working = state.working {
                        ShellAlertBand(kind: .progress, text: working)
                    } else if let failure = state.failure {
                        ShellAlertBand(kind: .failure, text: failure, dismiss: { pages.send(.dismissFailure) })
                    } else if let notice = state.notice {
                        ShellAlertBand(kind: .success, text: notice, dismiss: { pages.send(.dismissNotice) })
                    }
                    ShellPageBands { content }
                }
            }
        }
        .accessibilityIdentifier("teams-page-\(place)")
    }
}

extension TeamsPageScaffold where Actions == EmptyView {
    init(place: String, pages: TeamsPages, @ViewBuilder content: () -> Content) {
        self.init(place: place, pages: pages, actions: { EmptyView() }, content: content)
    }
}
