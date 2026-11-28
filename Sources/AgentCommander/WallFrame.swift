import SwiftUI

// ATOMIC LEVEL: Atoms, molecules and organisms (the coordinator wall's own frame).
// Everything on the wall that is not a console: the pane headings, the group container, the
// Remote workers band and the dock under a tile. Each reads `\.theme` (the `wall` roles), takes
// values and emits a targeted action. The console tiles between them are not touched: they keep
// their shell, their controls and their own tokens in every theme.
//
//   WallCount          a pane heading's count (atom)
//   WallHeading        symbol + title + count, the heading over a pane (molecule)
//   WallCrumb          "Worker wall / name" over a zoomed worker or an opened group, with the
//                      opened groups between (molecule)
//   wallGroupFrame     the container a group of tiles sits in (atom, as a modifier)
//   WallWorkRow        a review or fan-out you sent: kind glyph, title, state (molecule)
//   WallRemoteBand     hand-offs as remote worker tiles, then reviews and fan-outs (organism)
//   WallSuggestionRow  a waiting Co-pilot suggestion and the way to its review (molecule)
//   WallControlDock    under a held worker's tile: who holds it, how long, Take back (organism)
//   WallBranchDock     under a child's tile in an opened group: what is under it, Open group (molecule)
//   GroupZoomFrame     an opened group: pinned parent slot, content, hints (template)
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

/// Over a zoomed worker or an opened group: the way back, then the name of what is shown and
/// what marks it. `trail` names the opened groups between the wall and what is shown, outermost
/// first. The back button holds the whole path before the name and goes back one level, to the
/// last name in it; that name is in the heading ink and the levels before it are quieter.
struct WallCrumb<Accessory: View>: View {
    @Environment(\.theme) private var theme
    var trail: [String] = []
    let name: String
    let back: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let heading = theme.wall.headingType
        let path = ["Worker wall"] + trail
        HStack(spacing: Space.s) {
            Button(action: back) {
                HStack(spacing: Space.s) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.theme(\.color.secondary))
                    ForEach(Array(path.enumerated()), id: \.offset) { index, level in
                        if index > 0 {
                            Text("/").themeType(heading).foregroundStyle(.theme(\.color.secondary)).opacity(0.6)
                        }
                        Text(level).themeType(heading).lineLimit(1)
                            .foregroundStyle(.theme(index == path.count - 1 ? \.wall.headingInk : \.color.secondary))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(WallCrumbLabel.back(trail: trail))
            .accessibilityLabel(WallCrumbLabel.back(trail: trail))
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
    init(trail: [String] = [], name: String, back: @escaping () -> Void) {
        self.init(trail: trail, name: name, back: back) { EmptyView() }
    }
}

/// What a wall crumb's back button says it does, for VoiceOver, the pointer and the ⌘[ hint.
enum WallCrumbLabel {
    static func back(trail: [String]) -> String {
        trail.last.map { "Back to \($0)" } ?? "Return to worker wall"
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

/// Docked under a child's tile inside an opened group, when that child delegated workers of its
/// own. None of them is tiled here: the dock counts them, says what they wait for, and opens the
/// child's own group. It sits outside the tile, so the child is a peer of the other children in
/// the grid and its console and controls are as they always are.
struct WallBranchDock: View {
    @Environment(\.theme) private var theme
    /// The child the workers are under.
    let name: String
    let status: GroupBranchStatus
    let open: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(theme.radius.tile, theme.wall.groupRadius), style: .continuous)
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                    .foregroundStyle(.theme(\.color.secondary))
                    .accessibilityHidden(true)
                Text(status.countLabel).themeType(theme.wall.groupNoteType)
                    .foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                Spacer(minLength: Space.s)
                if status.hasDisconnected { StatusLabel(.disconnected, size: 10.5) }
                if let host = status.reconnectingHost { HostLinkStatus(host: host, style: .label, size: 10.5) }
                if status.hasRequest {
                    StatusLabel(text: "Needs input", tone: .attention, symbol: "questionmark.circle.fill", size: 10.5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.spoken(name: name))
            Button(action: open) {
                HStack(spacing: 5) {
                    Text("Open group")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .themeType(theme.type.state)
                .foregroundStyle(.theme(\.color.secondary))
                .frame(minHeight: WallFrameLayout.workRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \(name) over the workers it delegated to")
            .accessibilityLabel("Open group \(name)")
            .accessibilityHint("Shows this worker pinned over the workers it delegated to")
        }
        .padding(.horizontal, WallFrameLayout.groupInset + 1)
        .frame(minHeight: WallFrameLayout.workRow)
        .background(theme.wall.groupFill.color, in: shape)
        .overlay {
            shape.strokeBorder(.theme(status.hasRequest ? \.surface.attentionEdge : \.wall.groupEdge), lineWidth: theme.line.hairline)
        }
        .padding(.top, WallFrameLayout.dockGap)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Templates

/// An opened group under its crumb: the pinned parent's slot, then the content (the children's
/// grid or one zoomed child), then the hints under a grid. The parent's slot is the first child of
/// one stack and is planned from the height alone (`GroupZoomPlan`), so swapping the content never
/// rebuilds or resizes the parent: its keyboard focus and terminal stay with it.
struct GroupZoomFrame<Parent: View, Content: View, Hints: View>: View {
    /// A child is zoomed under the parent, so no hints are drawn.
    let zoomsChild: Bool
    @ViewBuilder let parent: (GroupZoomPlan.Parent) -> Parent
    @ViewBuilder let content: Content
    @ViewBuilder let hints: Hints

    var body: some View {
        GeometryReader { geo in
            let plan = GroupZoomPlan(height: geo.size.height, zoomsChild: zoomsChild)
            VStack(spacing: 0) {
                parent(plan.parent)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, Metric.wallRowGap)
                // The hints take `GroupZoomPlan.hintsHeight` of the stack, as under the wall.
                if !zoomsChild { hints }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
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
