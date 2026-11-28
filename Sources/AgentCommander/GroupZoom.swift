import SwiftUI

// ATOMIC LEVEL: Values (zooming into a group of workers).
// Plain values the worker pane is drawn and navigated from while a group is open, so the rules
// can be exercised without a window. Nothing here reads a model, a theme or a view.
//
//   WallLayout.children(of:)  a worker's direct children, in the wall's order
//   WallLayout.inside(_:)     what an opened group shows (GroupInside): its parent, its direct
//                             children as peers, and what is under each branch child
//   GroupBranchStatus         what a branch child's dock says about the workers under it
//   GroupZoomLevel            one opened group, with the pane the keyboard returns to
//   WallRoute                 where the worker pane is: the opened groups, then a zoomed worker
//   GroupZoomPlan             how the pinned parent is drawn for one height

// MARK: - Direct children

extension WallLayout {
    /// Every worker's direct children by the parent's ID, in the wall's order. A nested worker
    /// whose own parent is not in its group (an older record, a parent that left) counts as a
    /// direct child of the group's parent, so no worker is ever unreachable.
    var directChildren: [String: [WorkerPresentation]] {
        var children: [String: [WorkerPresentation]] = [:]
        for group in groups {
            let nested = group.members
            let ids = Set(nested.map(\.id)).union([group.parent.id])
            var own: [String: [WorkerPresentation]] = [:]
            for worker in nested {
                let named = worker.parentID.flatMap { ids.contains($0) && $0 != worker.id ? $0 : nil }
                own[named ?? group.parent.id, default: []].append(worker)
            }
            // A parent cycle would leave its workers under no one: they go under the group's parent.
            var reached: Set<String> = [group.parent.id]
            var queue = [group.parent.id]
            while let next = queue.popLast() {
                for child in own[next] ?? [] where reached.insert(child.id).inserted { queue.append(child.id) }
            }
            for worker in nested where !reached.contains(worker.id) {
                own = own.mapValues { $0.filter { $0.id != worker.id } }
                own[group.parent.id, default: []].append(worker)
            }
            children.merge(own.filter { !$0.value.isEmpty }) { first, _ in first }
        }
        return children
    }

    /// A worker's direct children, in the wall's order. Empty for a worker with none, and for one
    /// the wall does not list.
    func children(of workerID: String) -> [WorkerPresentation] { directChildren[workerID] ?? [] }

    /// What one group shows when it is opened. Nil when the wall does not list the worker or it
    /// has no children.
    func inside(_ groupID: String) -> GroupInside? {
        let children = directChildren
        guard let direct = children[groupID], !direct.isEmpty,
              let parent = workers.first(where: { $0.id == groupID }) else { return nil }
        func descendants(of id: String, seen: inout Set<String>) -> [WorkerPresentation] {
            (children[id] ?? []).flatMap { child -> [WorkerPresentation] in
                guard seen.insert(child.id).inserted else { return [] }
                return [child] + descendants(of: child.id, seen: &seen)
            }
        }
        var branches: [String: [WorkerPresentation]] = [:]
        for child in direct {
            var seen: Set<String> = [groupID, child.id]
            let below = descendants(of: child.id, seen: &seen)
            if !below.isEmpty { branches[child.id] = below }
        }
        return GroupInside(parent: parent, children: direct, branches: branches)
    }
}

/// An opened group: the worker that delegated and its direct children. Every direct child is a
/// peer in one grid, whether or not it has children of its own.
struct GroupInside: Equatable {
    let parent: WorkerPresentation
    /// The parent's direct children, in the wall's order.
    let children: [WorkerPresentation]
    /// Everything under each child that has children of its own, by that child's ID. None of it
    /// is tiled until the child's own group is opened; the child's dock counts it and says what
    /// it waits for.
    let branches: [String: [WorkerPresentation]]

    /// The children as a wall of standalone tiles, so the wall's own plan sizes them.
    var wall: WallLayout { WallLayout(leaves: children) }
}

/// What a branch child's dock says about the workers under it, whose tiles are not drawn.
struct GroupBranchStatus: Equatable {
    let count: Int
    let hasRequest: Bool
    let hasDisconnected: Bool
    /// Hosts whose persistent SSH link is reconnecting, named together. Nil when none is.
    let reconnectingHost: String?

    init(nested: [WorkerPresentation]) {
        count = nested.count
        hasRequest = nested.contains { $0.request != nil }
        hasDisconnected = nested.contains(where: \.isDisconnected)
        let hosts = Set(nested.filter(\.hostIsReconnecting).map(\.host)).sorted()
        reconnectingHost = hosts.isEmpty ? nil : hosts.joined(separator: ", ")
    }

    var countLabel: String { count == 1 ? "1 nested worker" : "\(count) nested workers" }

    /// What VoiceOver reads for the dock: the same words as a folded group's heading.
    func spoken(name: String) -> String {
        NestedWorkerGroupLabel.spoken(name: name, nestedCount: count, collapsed: true, hasRequest: hasRequest,
                                      hasDisconnected: hasDisconnected, reconnectingHost: reconnectingHost)
    }
}

// MARK: - Route

/// One group the developer opened, by its parent's stable ID.
struct GroupZoomLevel: Equatable {
    let groupID: String
    /// The pane that held the keyboard where this group was opened from. Going back returns it.
    var returnFocus: String? = nil
}

/// Where the worker pane is: the wall, a group opened inside it, a group opened inside that one,
/// and last a zoomed worker. Going back always leaves exactly one of these.
struct WallRoute: Equatable {
    /// The opened groups, outermost first. Empty on the wall.
    var groups: [GroupZoomLevel] = []
    var zoomedWorkerID: String? = nil

    /// What going back one level left.
    enum Back: Equatable {
        /// A zoomed worker, back to the group or the wall it was zoomed in.
        case unzoomed(String)
        /// A group, back to the group or the wall it was opened from.
        case closed(GroupZoomLevel)
    }

    /// The group whose children the pane shows. Nil on the wall.
    var groupID: String? { groups.last?.groupID }

    /// Opens a group from where the route is now. A group that is not a direct child of the open
    /// one is opened from the wall, so the path is always a true line of parents.
    mutating func open(_ groupID: String, from focus: String?, in layout: WallLayout) {
        guard self.groupID != groupID else { zoomedWorkerID = nil; return }
        let level = GroupZoomLevel(groupID: groupID, returnFocus: focus)
        if let current = self.groupID, layout.children(of: current).contains(where: { $0.id == groupID }) {
            groups.append(level)
        } else {
            groups = [level]
        }
        zoomedWorkerID = nil
    }

    /// Goes back exactly one level: a zoomed worker to its group or the wall, a nested group to
    /// the group it was opened from, the outer group to the wall. Nil on the wall.
    mutating func back() -> Back? {
        if let workerID = zoomedWorkerID {
            zoomedWorkerID = nil
            return .unzoomed(workerID)
        }
        return groups.popLast().map(Back.closed)
    }

    /// The route the wall can still show. A group that is gone, has lost its last child or is no
    /// longer a child of the group before it ends the path there, so the pane falls back to the
    /// nearest level that survives. A zoomed worker that is gone falls back to its level.
    func surviving(in layout: WallLayout) -> WallRoute {
        let children = layout.directChildren
        var kept: [GroupZoomLevel] = []
        for level in groups {
            guard !(children[level.groupID] ?? []).isEmpty else { break }
            if let outer = kept.last, !(children[outer.groupID] ?? []).contains(where: { $0.id == level.groupID }) { break }
            if kept.isEmpty, !layout.workers.contains(where: { $0.id == level.groupID }) { break }
            kept.append(level)
        }
        let zoomed = zoomedWorkerID.flatMap { id in layout.workers.contains { $0.id == id } ? id : nil }
        return WallRoute(groups: kept, zoomedWorkerID: zoomed)
    }

    /// The panes drawn at the route's level while no worker is zoomed: the open group's parent and
    /// its direct children, or the wall's tiles. On the wall a tile inside a folded group is not
    /// drawn; an opened group draws every direct child.
    func shownPanes(in layout: WallLayout, collapsed: Set<String>) -> [String] {
        guard let groupID else {
            return layout.leaves.map(\.id) + layout.groups.filter { !collapsed.contains($0.id) }.flatMap { $0.all.map(\.id) }
        }
        guard let inside = layout.inside(groupID) else { return [] }
        return [inside.parent.id] + inside.children.map(\.id)
    }

    /// The pane the keyboard goes to after `back`, on the route as it is now. After a zoom: the
    /// worker that was zoomed. After a group: the pane that held the keyboard when it was opened,
    /// then the group's own tile. Each only while the level draws it; otherwise the open group's
    /// parent, the coordinator, or the first pane drawn.
    func focus(after back: Back, in layout: WallLayout, collapsed: Set<String>, coordinator: String?) -> String? {
        let shown = shownPanes(in: layout, collapsed: collapsed)
        let preferred: [String?]
        switch back {
        case .unzoomed(let workerID): preferred = [workerID]
        case .closed(let level): preferred = [level.returnFocus, level.groupID]
        }
        for case let id? in preferred where id == coordinator || shown.contains(id) { return id }
        return groupID ?? coordinator ?? shown.first
    }
}

// MARK: - Plan

/// How the open group's parent is pinned for one height of the room under the crumb. The parent's
/// form and height come from that height alone, never from what is under it, so the parent is the
/// same mounted tile over its children and over a zoomed child, and its terminal stays attached.
struct GroupZoomPlan: Equatable {
    enum Parent: Equatable {
        /// The parent's wall tile, at this height.
        case tile(height: CGFloat)
        /// The parent's identity and status alone: its title bar and its status line.
        case strip
    }

    /// The share of the height the parent's tile takes, and the range it stays in.
    static let tileShare: CGFloat = 0.34
    static let tileHeights: ClosedRange<CGFloat> = 170...280
    /// The key hints under the children's grid. A zoomed child has none, and takes that room.
    static let hintsHeight: CGFloat = 20

    let parent: Parent
    /// Height the hints take under the content: under the grid only.
    let hints: CGFloat
    /// Room for the children's grid or the zoomed child under a tile and its gap. Nil under the
    /// strip, whose height is its own.
    let content: CGFloat?

    /// The parent keeps its tile while a row of children, with the hints under it, stays readable
    /// below. A zoomed child is judged by the same room, so selecting one never changes the
    /// parent. In a shorter pane the parent is its identity and status alone, in both states.
    init(height: CGFloat, zoomsChild: Bool) {
        let tile = min(max((height * Self.tileShare).rounded(), Self.tileHeights.lowerBound), Self.tileHeights.upperBound)
        let left = height - tile - Metric.wallRowGap
        hints = zoomsChild ? 0 : Self.hintsHeight
        if left - Self.hintsHeight >= Metric.minimumWallRowHeight {
            parent = .tile(height: tile)
            content = left - hints
        } else {
            parent = .strip
            content = nil
        }
    }
}
