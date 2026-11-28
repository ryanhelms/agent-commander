import SwiftUI

// ATOMIC LEVEL: Atoms, molecules and organisms (the coordinator wall's own frame).
// Everything on the wall that is not a console: the pane headings, the group container, the
// Remote workers band and the dock under a tile. Each reads `\.theme` (the `wall` roles), takes
// values and emits a targeted action. The console tiles between them are not touched: they keep
// their shell, their controls and their own tokens in every theme.
//
//   WallCount          a pane heading's count (atom)
//   WallHeading        symbol + title + count, the heading over a pane (molecule)
//   WallCrumb          "Worker wall / name" over a zoomed worker (molecule)
//   wallGroupFrame     the container a group of tiles sits in (atom, as a modifier)
//   WallWorkRow        a review or fan-out you sent: kind glyph, title, state (molecule)
//   WallRemoteBand     hand-offs as remote worker tiles, then reviews and fan-outs (organism)
//   WallSuggestionRow  a waiting Co-pilot suggestion and the way to its review (molecule)
//   WallControlDock    under a held worker's tile: who holds it, how long, Take back (organism)
//
// The band composes the tray's RemoteWorkerTile, and the dock the tray's holder row, as they are.

// MARK: - Atoms

/// The count beside a pane heading.
struct WallCount: View {
    @Environment(\.theme) private var theme
    let count: Int
    /// What is counted, for VoiceOver: "5 workers".
    var noun = "workers"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.wall.countRadius)
        Text("\(count)")
            .themeType(theme.wall.countType)
            .monospacedDigit()
            .foregroundStyle(.theme(\.wall.countInk))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(theme.wall.countFill.color, in: shape)
            .overlay { shape.strokeBorder(.theme(\.wall.countEdge)) }
            .contentTransition(.numericText())
            .animation(theme.motion.animation(theme.motion.standard), value: count)
            .accessibilityLabel("\(count) \(noun)")
    }
}

/// The container a group of tiles sits in: the wall's group fill, edge and corner.
private struct WallGroupFrame: ViewModifier {
    @Environment(\.theme) private var theme
    let inset: CGFloat
    let bottom: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.wall.groupRadius, style: .continuous)
        content
            .padding(.horizontal, inset)
            .padding(.bottom, bottom)
            .background(theme.wall.groupFill.color, in: shape)
            .overlay { shape.strokeBorder(.theme(\.wall.groupEdge), lineWidth: theme.line.hairline) }
    }
}

extension View {
    /// Frames a group of tiles on the wall. `bottom` is zero for a group that is folded.
    func wallGroupFrame(inset: CGFloat = WallFrameLayout.groupInset, bottom: CGFloat = WallFrameLayout.groupInset) -> some View {
        modifier(WallGroupFrame(inset: inset, bottom: bottom))
    }
}

enum WallFrameLayout {
    /// Room between a group's edge and its tiles.
    static let groupInset: CGFloat = 9
    /// A review or fan-out row in the band.
    static let workRow: CGFloat = 28
    /// Room between a tile and the dock under it.
    static let dockGap: CGFloat = 4
}

// MARK: - Molecules

/// The heading over a pane of the cockpit: Coordinator, Worker wall.
struct WallHeading: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.theme(\.color.secondary))
                .accessibilityHidden(true)
            Text(title).themeType(theme.wall.headingType).foregroundStyle(.theme(\.wall.headingInk))
            if let count { WallCount(count: count) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Over a zoomed worker: the way back to the wall, then the worker's name and what marks it.
struct WallCrumb<Accessory: View>: View {
    @Environment(\.theme) private var theme
    let name: String
    let back: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let heading = theme.wall.headingType
        HStack(spacing: Space.s) {
            Button(action: back) {
                HStack(spacing: Space.s) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.theme(\.color.secondary))
                    Text("Worker wall").themeType(heading).foregroundStyle(.theme(\.wall.headingInk))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to worker wall")
            Text("/").themeType(heading).foregroundStyle(.theme(\.color.secondary)).opacity(0.6)
                .accessibilityHidden(true)
            Text(name)
                .themeType(ThemeFont(face: heading.face, size: heading.size, weight: .regular))
                .foregroundStyle(.theme(\.surface.softInk))
                .lineLimit(1)
            accessory
        }
    }
}

extension WallCrumb where Accessory == EmptyView {
    init(name: String, back: @escaping () -> Void) {
        self.init(name: name, back: back) { EmptyView() }
    }
}

/// A review or a fan-out you sent that still needs a look. The whole row opens its page.
struct WallWorkRow: View {
    @Environment(\.theme) private var theme
    let work: MultiplayerRemoteWork
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s) {
                Image(systemName: work.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.theme(\.color.secondary))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(work.title).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground)).lineLimit(1)
                Text(work.detail).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.s)
                Text(work.state).themeType(theme.type.state).lineLimit(1)
                    .foregroundStyle(.theme(work.tone == .neutral ? \.color.secondary : work.tone.role))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.theme(\.color.secondary))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: WallFrameLayout.workRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShellRowButtonStyle())
        .help("Open this \(work.kindTitle.lowercased())")
        .accessibilityLabel("\(work.kindTitle): \(work.title), \(work.detail), \(work.state)")
        .accessibilityHint("Opens it on its page")
    }
}

/// A Co-pilot suggestion waiting on the person, at the worker it is for.
struct WallSuggestionRow: View {
    @Environment(\.theme) private var theme
    let suggestion: WallLiveWork.Suggestion
    let review: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            MultiplayerBadge(text: "Suggestion", symbol: "lightbulb.fill", tone: .attention)
            Text(suggestion.sentence)
                .themeType(theme.type.sub)
                .foregroundStyle(.theme(\.color.secondary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Review", action: review)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .help("Read the suggestion and approve or deny it. The worker sees nothing until you approve.")
                .accessibilityLabel("Review the suggestion from \(suggestion.who)")
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Organisms

/// Hand-offs running on friends' Macs, as the network's own remote worker group, then the reviews
/// and fan-outs that still need a look in a group frame of their own. Draws nothing when there is neither.
struct WallRemoteBand: View {
    /// A row never grows past the wall's own three columns.
    static let tileLimit = RemoteWorkerGroup.limit

    @Environment(\.theme) private var theme
    let workers: [MultiplayerRemoteWorker]
    let work: [MultiplayerRemoteWork]
    let now: Date
    /// Zooms a remote worker on the wall.
    let zoom: (MultiplayerRemoteWorker) -> Void
    /// Opens the Hand-offs page, where every hand-off and review is listed.
    let openHandoffs: () -> Void
    /// Opens a review or a fan-out on its page.
    let openWork: (MultiplayerRemoteWork) -> Void
    /// The owner's keyboard focus among the remote tiles, by remote worker ID.
    var focus: FocusState<String?>.Binding? = nil

    var body: some View {
        if !workers.isEmpty || !work.isEmpty {
            let rows = Array(work.prefix(WallLiveWork.rowLimit))
            VStack(spacing: Metric.wallRowGap) {
                // The network's own worker group: its heading, its tiles and its frame follow the theme.
                if !workers.isEmpty {
                    RemoteWorkerGroup(workers: workers, now: now, onOpen: zoom, onOpenAll: openHandoffs, focus: focus)
                }
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        heading(hidden: work.count - rows.count)
                        ForEach(rows) { item in
                            ThemeRule()
                            WallWorkRow(work: item) { openWork(item) }
                        }
                    }
                    .wallGroupFrame(bottom: 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Reviews and fan-outs")
                }
            }
        }
    }

    /// Over the reviews and fan-outs that still need a look, with the way to all of them.
    private func heading(hidden: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 11))
                .foregroundStyle(.theme(\.color.secondary))
                .accessibilityHidden(true)
            Text("Reviews and fan-outs").themeType(theme.wall.groupTitleType).foregroundStyle(.theme(\.wall.headingInk))
                .accessibilityAddTraits(.isHeader)
            Text("\(work.count)").themeType(theme.wall.groupTitleType).monospacedDigit()
                .foregroundStyle(.theme(\.color.foreground))
                .contentTransition(.numericText())
                .animation(theme.motion.animation(theme.motion.standard), value: work.count)
            Text("you sent, still waiting on you")
                .themeType(theme.wall.groupNoteType)
                .foregroundStyle(.theme(\.color.secondary))
                .lineLimit(1)
            Spacer(minLength: Space.s)
            Button(action: openHandoffs) {
                HStack(spacing: 5) {
                    Text(hidden > 0 ? "\(WallLiveWork.more(hidden)) in Hand-offs" : "Hand-offs")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .themeType(theme.type.state)
                .foregroundStyle(.theme(\.color.secondary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Every hand-off and review you sent, with its report and what it left to apply")
            .accessibilityLabel(hidden > 0 ? "Open Hand-offs, \(WallLiveWork.more(hidden)) there" : "Open Hand-offs")
        }
        .frame(minHeight: Metric.groupHeaderHeight)
    }
}

/// Docked under a worker's tile while the network has something to say about that worker: a
/// friend holds control of it (holder badge, countdown, Take back), or a suggestion for it waits.
/// It sits outside the tile, so the console and its controls are as they always are.
struct WallControlDock: View {
    @Environment(\.theme) private var theme
    let controls: [WallLiveWork.Control]
    let suggestions: [WallLiveWork.Suggestion]
    let now: Date
    let isBusy: Bool
    let takeBack: (WallLiveWork.Control) -> Void
    /// Opens who can use this worker, on the Shared page.
    var openShared: (() -> Void)? = nil
    let review: (WallLiveWork.Suggestion) -> Void

    var body: some View {
        if !controls.isEmpty || !suggestions.isEmpty {
            let shape = RoundedRectangle(cornerRadius: min(theme.radius.tile, theme.wall.groupRadius), style: .continuous)
            VStack(spacing: 0) {
                ForEach(controls) { control in
                    if control.id != controls.first?.id { ThemeRule() }
                    MultiplayerHolderRow(handover: control.handover, resourceName: control.resourceName.multiplayerDisplay,
                                         serverName: control.serverName, color: MultiplayerTheme.swatch(for: control.server),
                                         now: now, isBusy: isBusy, onOpen: openShared, onTakeBack: { takeBack(control) })
                }
                ForEach(suggestions) { suggestion in
                    if suggestion.id != suggestions.first?.id || !controls.isEmpty { ThemeRule() }
                    WallSuggestionRow(suggestion: suggestion) { review(suggestion) }
                }
            }
            .padding(.horizontal, WallFrameLayout.groupInset + 1)
            .padding(.vertical, 3)
            .background(theme.wall.groupFill.color, in: shape)
            .overlay { shape.strokeBorder(.theme(controls.isEmpty ? \.wall.groupEdge : \.surface.attentionEdge), lineWidth: theme.line.hairline) }
            .padding(.top, WallFrameLayout.dockGap)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(controls.isEmpty ? "Suggestions for this worker" : "Control of this worker")
        }
    }
}
