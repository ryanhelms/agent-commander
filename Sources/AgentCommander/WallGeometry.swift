import SwiftUI

// ATOMIC LEVEL: Values and one layout (the workspace's geometry).
// Plain values the coordinator split and the worker wall are laid out from, so the rules can be
// exercised without a window. Nothing here reads a model, a theme or a view.
//
//   WorkspaceSplitGeometry  coordinator | workers: when the wall opens, how wide the coordinator
//                           is drawn, what the divider reports, and what a pinned panel takes
//   WallPlan                the wall's frames: columns, tile and group frames, what scrolls
//   WallFocus               where the keyboard lands on returning to the wall
//   WallReveal              a request to bring one worker's tile into view
//   WallFrames              places each subview in the frame planned for it (Layout)

// MARK: - Split

/// The coordinator split under the run header, as plain geometry.
struct WorkspaceSplitGeometry: Equatable {
    /// Width of the region under the run header.
    let width: CGFloat
    /// The remembered share of the width the coordinator takes. It is kept as chosen; only what
    /// is drawn is fitted to the window.
    let fraction: Double
    /// The worker region is open. Closed, the coordinator takes the whole width.
    let showsWorkers: Bool
    /// The attention side panel is on screen.
    var showsDrawer = false
    /// The developer pinned the side panel.
    var drawerPinned = false

    static let divider: CGFloat = 1
    /// The coordinator's share never leaves this range, whatever the window allows.
    static let fractionLimits: ClosedRange<Double> = 0.2...0.6
    /// The least the coordinator keeps in a window too narrow for both preferred minimums.
    static let narrowCoordinatorWidth: CGFloat = 220

    /// The wall opens for a worker the run still lists, whatever its state: working, finished,
    /// stopped, disconnected or reconnecting. A zoomed remote worker opens it too. Hand-offs,
    /// reviews and fan-outs the network lists do not: they belong to no run.
    static func showsWorkers(localWorkers: Int, zoomsRemoteWorker: Bool) -> Bool {
        localWorkers > 0 || zoomsRemoteWorker
    }

    /// The widths the coordinator side (coordinator and divider) may take in this window.
    var leadingRange: ClosedRange<CGFloat> {
        let room = max(0, width - Metric.minimumWorkerRegionWidth)
        let least = max(min(Metric.minimumCoordinatorWidth, max(Self.narrowCoordinatorWidth, room)),
                        min(room, width * Self.fractionLimits.lowerBound))
        let most = max(least, min(room, width * Self.fractionLimits.upperBound))
        return least...most
    }

    /// Width of the coordinator side: the coordinator pane and, when the wall is open, the divider.
    var leadingWidth: CGFloat {
        guard showsWorkers else { return max(0, width) }
        let range = leadingRange
        return min(max(0, width), min(max(width * fraction, range.lowerBound), range.upperBound))
    }

    /// Width the coordinator pane itself is drawn at.
    var coordinatorWidth: CGFloat { showsWorkers ? max(0, leadingWidth - Self.divider) : leadingWidth }

    /// Width of the worker region. Zero while the wall is closed.
    var workerWidth: CGFloat { showsWorkers ? max(0, width - leadingWidth) : 0 }

    /// The coordinator's share as drawn, which is what the divider reports and moves from.
    var renderedFraction: Double { width > 0 ? Double(leadingWidth / width) : fraction }

    /// The divider's accessibility value.
    var percent: Int { Int((renderedFraction * 100).rounded()) }

    /// The share to remember after moving the divider by `delta` of the width from where it is
    /// drawn. The result is always a position this window can show.
    func fraction(movedBy delta: Double) -> Double { fraction(from: renderedFraction, movedBy: delta) }

    /// The same from a given starting share: a drag moves from where it began.
    func fraction(from origin: Double, movedBy delta: Double) -> Double {
        guard width > 0 else { return fraction }
        let range = leadingRange
        let target = CGFloat(origin + delta) * width
        return Double(min(max(target, range.lowerBound), range.upperBound) / width)
    }

    /// The pane the side panel sits beside: the worker region, or the coordinator when it is alone.
    private var drawerPaneWidth: CGFloat { showsWorkers ? workerWidth : coordinatorWidth }

    /// Width the pane beside a pinned side panel gives up. Zero when the panel is closed or
    /// unpinned, and when giving it up would leave less than one readable tile: the panel then
    /// lies over the pane, as it does unpinned.
    var drawerReservation: CGFloat {
        guard showsDrawer, drawerPinned else { return 0 }
        let left = drawerPaneWidth - 2 * Metric.paneInset - Metric.attentionDrawerWidth
        return left >= Metric.minimumTileWidth ? Metric.attentionDrawerWidth : 0
    }

    /// Width of the in-window PiP, which never outgrows the pane it floats over.
    var floatingWidth: CGFloat {
        min(Metric.pipWidth, max(250, drawerPaneWidth - 2 * Metric.paneInset))
    }
}

// MARK: - Wall plan

/// The frames of everything on the worker wall for one size, in the scroll content's own
/// coordinates. Standalone workers fill rows of up to three columns, then each group follows in
/// its own frame. One worker fills the wall. A set that fits one row shares it equally. A larger
/// set keeps every row, complete or not, at the regular column width.
struct WallPlan: Equatable {
    struct GroupInput: Equatable {
        let id: String
        /// The parent first, then its nested workers.
        let workers: [String]
        let collapsed: Bool
    }

    struct Input: Equatable {
        /// The wall's own size: the worker pane after its insets and any pinned panel.
        var width: CGFloat
        var height: CGFloat
        var leaves: [String] = []
        var groups: [GroupInput] = []
        /// Width kept clear at the trailing edge of the last row for the PiP.
        var reservedTrailing: CGFloat = 0
        /// Height of what follows the local workers in the same scroll (the remote band).
        var footerHeight: CGFloat = 0
    }

    struct Group: Equatable {
        let id: String
        let workers: [String]
        let collapsed: Bool
        /// The whole group, heading and edge included.
        let frame: CGRect
        let columns: Int
        /// Tile frames inside the group's own tile area, under its heading and inside its inset.
        let tiles: [CGRect]
        var tilesHeight: CGFloat { tiles.map(\.maxY).max() ?? 0 }
    }

    let input: Input
    /// Columns of standalone workers.
    let columns: Int
    /// The regular width of a standalone worker's column.
    let columnWidth: CGFloat
    let leafFrames: [CGRect]
    let groups: [Group]
    /// Width actually kept clear beside the last row. Zero when the row could not give it up.
    let reserved: CGFloat

    /// Columns that fit a width at the least readable tile width, up to the wall's three.
    static func columns(fitting width: CGFloat) -> Int {
        max(1, min(3, Int((width + Metric.tileGap) / (Metric.minimumTileWidth + Metric.tileGap))))
    }

    /// Height of a group beyond its tile rows: the heading, the gaps between rows and the inset
    /// under the last row.
    static func groupChrome(rows: Int) -> CGFloat {
        Metric.groupHeaderHeight + CGFloat(max(0, rows - 1)) * WallFrameLayout.groupInset + WallFrameLayout.groupInset
    }

    /// Frames of `count` tiles in rows of up to `columns` across `width`. One row shares the width
    /// equally; more rows keep the regular column width, so an incomplete row stays aligned.
    static func tileFrames(count: Int, columns: Int, width: CGFloat, rowHeight: CGFloat, rowGap: CGFloat,
                           top: CGFloat = 0) -> [CGRect] {
        guard count > 0 else { return [] }
        let perRow = count <= columns ? count : columns
        let tile = max(0, (width - CGFloat(perRow - 1) * Metric.tileGap) / CGFloat(perRow))
        return (0..<count).map { index in
            CGRect(x: CGFloat(index % perRow) * (tile + Metric.tileGap),
                   y: top + CGFloat(index / perRow) * (rowHeight + rowGap), width: tile, height: rowHeight)
        }
    }

    init(_ input: Input) {
        self.input = input
        let width = max(0, input.width)
        let columns = Self.columns(fitting: width)
        let leafCount = input.leaves.count
        let leafRows = leafCount == 0 ? 0 : (leafCount + columns - 1) / columns
        let sections = leafRows + input.groups.count
        let regular = max(0, (width - CGFloat(min(max(leafCount, 1), columns) - 1) * Metric.tileGap)
                            / CGFloat(min(max(leafCount, 1), columns)))

        // The last row gives way to the PiP only where its tiles stay readable beside it.
        var reserved: CGFloat = 0
        var lastRowTile = regular
        let lastRowCount = leafCount == 0 ? 0 : leafCount - (leafRows - 1) * columns
        if input.reservedTrailing > 0, sections > 1 {
            let room = width - input.reservedTrailing
            if let last = input.groups.last {
                if !last.collapsed, room - 2 * WallFrameLayout.groupInset >= Metric.minimumTileWidth {
                    reserved = input.reservedTrailing
                }
            } else {
                let gaps = CGFloat(lastRowCount - 1) * Metric.tileGap
                let fitted = (room - gaps) / CGFloat(max(1, lastRowCount))
                if fitted >= Metric.minimumTileWidth {
                    reserved = input.reservedTrailing
                    lastRowTile = min(regular, fitted)
                }
            }
        }

        // Each group's columns come from the width inside its own edge.
        struct GroupShape { let width: CGFloat, inner: CGFloat, columns: Int, rows: Int }
        let shapes: [GroupShape] = input.groups.enumerated().map { index, group in
            let own = index == input.groups.count - 1 ? width - reserved : width
            let inner = max(0, own - 2 * WallFrameLayout.groupInset)
            let fit = Self.columns(fitting: inner)
            let rows = group.collapsed ? 0 : max(1, (group.workers.count + fit - 1) / fit)
            return GroupShape(width: own, inner: inner, columns: fit, rows: rows)
        }

        // Heights. A row of standalone workers weighs 1.1 against 1 for a group's tile row, as in
        // the concept. The local workers share the height the footer leaves, and no row goes
        // under the least readable height: the wall scrolls instead.
        let collapsedGroups = input.groups.filter(\.collapsed).count
        let weight = 1.1 * CGFloat(leafRows) + CGFloat(shapes.map(\.rows).reduce(0, +))
        let fixed = CGFloat(collapsedGroups) * Metric.groupHeaderHeight
            + CGFloat(max(0, sections - 1)) * Metric.wallRowGap
        let unit = weight > 0 ? max(0, input.height - input.footerHeight - fixed) / weight : 0
        let leafHeight = max(Metric.minimumWallRowHeight, 1.1 * unit)

        var frames = Self.tileFrames(count: leafCount, columns: columns, width: width, rowHeight: leafHeight,
                                     rowGap: Metric.wallRowGap)
        if reserved > 0, input.groups.isEmpty, lastRowTile < regular {
            for column in 0..<lastRowCount {
                let index = leafCount - lastRowCount + column
                frames[index].origin.x = CGFloat(column) * (lastRowTile + Metric.tileGap)
                frames[index].size.width = lastRowTile
            }
        }
        var y = leafRows == 0 ? 0 : CGFloat(leafRows) * leafHeight + CGFloat(leafRows - 1) * Metric.wallRowGap
        var groups: [Group] = []
        for (group, shape) in zip(input.groups, shapes) {
            if y > 0 { y += Metric.wallRowGap }
            guard !group.collapsed else {
                groups.append(Group(id: group.id, workers: group.workers, collapsed: true,
                                    frame: CGRect(x: 0, y: y, width: shape.width, height: Metric.groupHeaderHeight),
                                    columns: shape.columns, tiles: []))
                y += Metric.groupHeaderHeight
                continue
            }
            let chrome = Self.groupChrome(rows: shape.rows)
            let height = max(CGFloat(shape.rows) * Metric.minimumWallRowHeight + chrome, CGFloat(shape.rows) * unit)
            let tiles = Self.tileFrames(count: group.workers.count, columns: shape.columns, width: shape.inner,
                                        rowHeight: (height - chrome) / CGFloat(shape.rows),
                                        rowGap: WallFrameLayout.groupInset)
            groups.append(Group(id: group.id, workers: group.workers, collapsed: false,
                                frame: CGRect(x: 0, y: y, width: shape.width, height: height),
                                columns: shape.columns, tiles: tiles))
            y += height
        }

        self.columns = columns
        self.columnWidth = regular
        self.leafFrames = frames
        self.groups = groups
        self.reserved = reserved
    }

    /// Height of the local workers' part of the scroll.
    var tilesHeight: CGFloat {
        max(leafFrames.map(\.maxY).max() ?? 0, groups.map(\.frame.maxY).max() ?? 0)
    }

    /// Height of everything in the scroll: the local workers, then the footer.
    var contentHeight: CGFloat { tilesHeight + input.footerHeight }

    /// The content is taller than the wall, so it scrolls.
    var scrolls: Bool { contentHeight > input.height + 0.5 }

    /// The furthest the wall can scroll.
    var maximumOffset: CGFloat { max(0, contentHeight - input.height) }

    /// Frames of the outer layout's children in order: every standalone tile, then every group.
    var outerFrames: [CGRect] { leafFrames + groups.map(\.frame) }

    /// Where a worker's tile is in the scroll content. A worker inside a folded group is at its
    /// group's heading.
    func frame(of workerID: String) -> CGRect? {
        if let index = input.leaves.firstIndex(of: workerID), leafFrames.indices.contains(index) {
            return leafFrames[index]
        }
        for group in groups {
            guard let index = group.workers.firstIndex(of: workerID) else { continue }
            guard !group.collapsed, group.tiles.indices.contains(index) else { return group.frame }
            return group.tiles[index].offsetBy(dx: group.frame.minX + WallFrameLayout.groupInset,
                                               dy: group.frame.minY + Metric.groupHeaderHeight)
        }
        return nil
    }

    /// Every worker in the wall's order: the standalone ones, then each group's.
    var order: [String] { input.leaves + groups.flatMap(\.workers) }

    /// The workers whose tiles are drawn: every one outside a folded group, in the wall's order.
    var shownWorkers: [String] { input.leaves + groups.filter { !$0.collapsed }.flatMap(\.workers) }

    /// The scroll offset that keeps the same worker at the top of the wall after the wall is laid
    /// out again: a column more or fewer, a worker added or gone, a panel pinned beside it. The
    /// worker at the top keeps its distance from the top edge. When it is gone the offset stays,
    /// fitted to the new content.
    static func anchoredOffset(_ offset: CGFloat, from old: WallPlan, to new: WallPlan) -> CGFloat {
        let fitted = min(max(0, offset), new.maximumOffset)
        guard offset > 0.5 else { return fitted }
        for id in old.order {
            guard let before = old.frame(of: id), before.maxY > offset else { continue }
            guard let after = new.frame(of: id) else { return fitted }
            let into = min(offset - before.minY, after.height)
            return min(max(0, after.minY + into), new.maximumOffset)
        }
        return fitted
    }

    /// The scroll offset that shows a worker's tile, moving as little as possible. Nil when the
    /// tile is already in view or the worker is not on the wall.
    func offset(revealing workerID: String, from offset: CGFloat) -> CGFloat? {
        guard let frame = frame(of: workerID) else { return nil }
        let top = offset, bottom = offset + input.height
        if frame.minY >= top, frame.maxY <= bottom { return nil }
        // A tile taller than the wall shows its top.
        let target = frame.minY < top || frame.height > input.height ? frame.minY : frame.maxY - input.height
        let fitted = min(max(0, target), maximumOffset)
        return abs(fitted - offset) > 0.5 ? fitted : nil
    }
}

extension WallPlan.Input {
    /// The plan's input for a wall's workers.
    init(width: CGFloat, height: CGFloat, layout: WallLayout, collapsed: Set<String>,
         reservedTrailing: CGFloat = 0, footerHeight: CGFloat = 0) {
        self.init(width: width, height: height, leaves: layout.leaves.map(\.id),
                  groups: layout.groups.map { group in
                      WallPlan.GroupInput(id: group.id, workers: group.all.map(\.id), collapsed: collapsed.contains(group.id))
                  },
                  reservedTrailing: reservedTrailing, footerHeight: footerHeight)
    }
}

// MARK: - Focus and reveal

/// Where the keyboard goes when the wall comes back from a zoomed worker.
enum WallFocus {
    /// The pane to focus: the worker that was zoomed or last focused while the wall still shows
    /// it, otherwise the coordinator, otherwise the wall's first worker.
    static func returnTarget(preferred: String?, layout: WallLayout, coordinator: String?) -> String? {
        if let preferred, preferred == coordinator || layout.workers.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return coordinator ?? layout.workers.first?.id
    }

    /// Where each worker sits on the wall: its group's ID, or an empty string for a standalone one.
    static func placement(of layout: WallLayout) -> [String: String] {
        var placement: [String: String] = [:]
        for worker in layout.leaves { placement[worker.id] = "" }
        for group in layout.groups { for worker in group.all { placement[worker.id] = group.id } }
        return placement
    }

    /// A worker that is still on the wall moved between standalone and a group, or between groups.
    static func regrouped(_ workerID: String, from old: [String: String], to new: [String: String]) -> Bool {
        guard let before = old[workerID], let after = new[workerID] else { return false }
        return before != after
    }

    /// Whether the keyboard goes back to the worker's pane that held it right before the wall was
    /// regrouped. Only when nothing has the keyboard now: another pane, a reply field or any text
    /// field keeps it.
    static func restoresFocus(paneFocus: String?, replyFocus: String?, textHasKeyboard: Bool) -> Bool {
        paneFocus == nil && replyFocus == nil && !textHasKeyboard
    }

    /// The remote tile the keyboard returns to after its zoom: the same hand-off while the wall
    /// still draws its tile. Nil when it is gone or no longer among the tiles shown.
    @MainActor static func remoteReturnTarget(_ remoteID: String, listed: [String]) -> String? {
        let limit = RemoteWorkerGroup.limit
        return listed.prefix(limit).contains(remoteID) ? remoteID : nil
    }

    /// The folded group that hides a worker's tile, which is opened so focus has a tile to land on.
    static func foldedGroup(hiding workerID: String, layout: WallLayout, collapsed: Set<String>) -> String? {
        layout.groups.first { group in
            collapsed.contains(group.id) && group.all.contains { $0.id == workerID }
        }?.id
    }
}

/// A request to bring one worker's tile into view on the wall. A new token asks again for the
/// same worker.
struct WallReveal: Equatable {
    let workerID: String
    let token: Int
}

// MARK: - Layout

/// Places each subview in the frame planned for it, in order. The children keep their identity
/// when the plan changes, so a tile that moves to another row or column is the same view: its
/// keyboard focus, scroll position and terminal attachment stay with it.
struct WallFrames: Layout {
    let frames: [CGRect]
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? (frames.map(\.maxX).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() where frames.indices.contains(index) {
            let frame = frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
