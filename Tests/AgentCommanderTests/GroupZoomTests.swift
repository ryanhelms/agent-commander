import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Group zoom of issue #229: which workers an opened group tiles, how the route goes back one
// level at a time, where the keyboard lands, what a passive update leaves of the route, and how
// the pinned parent is drawn for a height. Everything is exercised as plain values. Nothing here
// opens a window on screen, touches the running app or writes the app's preferences.

/// What the hosted group frame is drawn from, and what its slots report back.
@MainActor @Observable final class GroupFrameProbe {
    var zoomsChild = false
    @ObservationIgnored var appeared: [String: Int] = [:]
    @ObservationIgnored var disappeared: [String: Int] = [:]
    @ObservationIgnored var heights: [String: CGFloat] = [:]
}

/// A slot that counts how often it is built into the hierarchy and reports its height.
private struct GroupFrameMark: View {
    let id: String
    let probe: GroupFrameProbe

    var body: some View {
        Color.clear
            .onAppear { probe.appeared[id, default: 0] += 1 }
            .onDisappear { probe.disappeared[id, default: 0] += 1 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.heights[id] = $0 }
    }
}

/// The group frame with marks in its slots, composed the way the cockpit composes it.
private struct GroupFrameHost: View {
    let probe: GroupFrameProbe

    var body: some View {
        GroupZoomFrame(zoomsChild: probe.zoomsChild) { form in
            switch form {
            case .tile(let height): GroupFrameMark(id: "parent", probe: probe).frame(height: height)
            case .strip: GroupFrameMark(id: "strip", probe: probe).frame(height: 60)
            }
        } content: {
            if probe.zoomsChild {
                GroupFrameMark(id: "child", probe: probe)
            } else {
                GroupFrameMark(id: "grid", probe: probe)
            }
        } hints: {
            Color.clear.frame(height: GroupZoomPlan.hintsHeight)
        }
    }
}

@MainActor @Suite struct GroupZoomTests {
    /// A worker with only what the route and the projection read.
    static func worker(_ id: String, parent: String? = nil, asks: Bool = false) -> WorkerPresentation {
        let request = asks ? RequestPresentation(
            id: "Q-" + id, shortID: "Q-" + id, question: "?", workerID: id, workerName: id, workerIsCoordinator: false,
            client: .codex, runID: "r", runTitle: "Run", project: "P", host: "h", platform: .localMac,
            inputHolder: "Run", contextTail: []) : nil
        return WorkerPresentation(id: id, shortID: id, name: "name-" + id, client: .codex, host: "h", platform: .localMac,
                                  location: "main", locationIsBranch: true, task: "", output: "", error: nil,
                                  state: asks ? .needsInput : .working, isCoordinator: false, lineage: ["Run", id],
                                  parentID: parent, control: .observing(holder: "Run"), request: request, startedAt: nil)
    }

    /// leaf | a ─ b, c ─ d ─ e, and c ─ f. The wall tiles every nested worker flat, as it does today.
    static let wall = WallLayout(
        leaves: [worker("leaf")],
        groups: [WorkerGroup(parent: worker("a"), members: [
            worker("b", parent: "a"), worker("c", parent: "a"), worker("d", parent: "c"),
            worker("e", parent: "d", asks: true), worker("f", parent: "c")
        ])])

    /// One step back, which the route must have.
    static func step(_ route: inout WallRoute) throws -> WallRoute.Back {
        let back = route.back()
        return try #require(back)
    }

    // MARK: Direct children

    @Test func anOpenedGroupTilesOnlyItsDirectChildren() throws {
        let inside = try #require(Self.wall.inside("a"))
        #expect(inside.parent.id == "a")
        // b has no children and c has: both are peers in one grid, and nothing is a group.
        #expect(inside.children.map(\.id) == ["b", "c"])
        #expect(inside.wall.leaves.map(\.id) == ["b", "c"])
        #expect(inside.wall.groups.isEmpty)
        // Everything under c is kept for c's dock; none of it is tiled here.
        #expect(inside.branches.keys.sorted() == ["c"])
        #expect(inside.branches["c"]?.map(\.id) == ["d", "e", "f"])
    }

    @Test func aDeeperGroupOpensOnItsOwnDirectChildren() throws {
        let inside = try #require(Self.wall.inside("c"))
        #expect(inside.parent.id == "c")
        // Wall order: d, then f. d is the branch.
        #expect(inside.wall.leaves.map(\.id) == ["d", "f"])
        #expect(inside.branches["d"]?.map(\.id) == ["e"])
        #expect(inside.branches["f"] == nil)
        // One child fills the group: d holds e alone.
        #expect(Self.wall.inside("d")?.wall.workers.map(\.id) == ["e"])
        #expect(Self.wall.inside("d")?.branches.isEmpty == true)
    }

    @Test func aBranchChildIsAPeerOfTheOtherChildrenInTheGrid() throws {
        // Three direct children, one of them with a worker of its own, in the width of the native
        // capture: three equal columns in one row, never the branch on a row of its own.
        let wall = WallLayout(groups: [WorkerGroup(parent: Self.worker("p"), members: [
            Self.worker("one", parent: "p"), Self.worker("two", parent: "p"), Self.worker("branch", parent: "p"),
            Self.worker("under", parent: "branch")
        ])])
        let inside = try #require(wall.inside("p"))
        let plan = WallPlan(WallPlan.Input(width: 970, height: 420, layout: inside.wall, collapsed: []))
        #expect(plan.groups.isEmpty)
        #expect(plan.columns == 3)
        #expect(plan.leafFrames.count == 3)
        #expect(Set(plan.leafFrames.map(\.minY)) == [0])
        #expect(Set(plan.leafFrames.map(\.width)).count == 1)
        #expect(plan.frame(of: "branch") == plan.leafFrames[2])
        #expect(plan.frame(of: "under") == nil)
    }

    @Test func aBranchDockSpeaksForTheWorkersUnderIt() throws {
        let inside = try #require(Self.wall.inside("a"))
        let status = GroupBranchStatus(nested: try #require(inside.branches["c"]))
        #expect(status.count == 3)
        #expect(status.countLabel == "3 nested workers")
        // e, two levels down, waits for input: its tile is not drawn, so the dock says it.
        #expect(status.hasRequest)
        #expect(!status.hasDisconnected)
        #expect(status.reconnectingHost == nil)
        #expect(status.spoken(name: "Partial bodies") == "Partial bodies, 3 nested, needs input")
        #expect(GroupBranchStatus(nested: [Self.worker("x")]).countLabel == "1 nested worker")
        #expect(!GroupBranchStatus(nested: [Self.worker("x")]).hasRequest)
    }

    @Test func aWorkerWithoutChildrenIsNotAGroup() {
        #expect(Self.wall.inside("b") == nil)
        #expect(Self.wall.inside("leaf") == nil)
        #expect(Self.wall.inside("gone") == nil)
        #expect(Self.wall.children(of: "e").isEmpty)
    }

    @Test func aNestedWorkerWithoutAKnownParentStaysReachable() {
        // No parent named, a parent outside the group, itself, and a cycle: all under the group's parent.
        let wall = WallLayout(groups: [WorkerGroup(parent: Self.worker("a"), members: [
            Self.worker("b"), Self.worker("c", parent: "elsewhere"), Self.worker("d", parent: "d"),
            Self.worker("x", parent: "y"), Self.worker("y", parent: "x")
        ])])
        #expect(Set(wall.children(of: "a").map(\.id)) == ["b", "c", "d", "x", "y"])
        #expect(wall.inside("a")?.children.count == 5)
    }

    @Test func theWallItselfStillTilesEveryNestedWorker() {
        #expect(Self.wall.workers.map(\.id) == ["leaf", "a", "b", "c", "d", "e", "f"])
        #expect(Self.wall.groups.map { $0.all.map(\.id) } == [["a", "b", "c", "d", "e", "f"]])
    }

    @Test func theSampleRunHasANestedBranch() throws {
        let wall = WallIdentityTests.wall(.nested)
        #expect(wall.groups.map { $0.all.map(\.id) } == [["W-046", "W-047", "W-066", "W-067", "W-068"]])
        let outer = try #require(wall.inside("W-046"))
        #expect(outer.wall.leaves.map(\.id) == ["W-047", "W-066"])
        #expect(outer.branches["W-066"]?.map(\.id) == ["W-067", "W-068"])
        #expect(wall.inside("W-066")?.wall.leaves.map(\.id) == ["W-067", "W-068"])
        // The concept's own group opens on its one child.
        #expect(WallIdentityTests.wall(.concept).inside("W-046")?.wall.workers.map(\.id) == ["W-047"])
    }

    // MARK: Back, one level at a time

    @Test func backLeavesExactlyOneLevel() {
        var route = WallRoute()
        route.open("a", from: "leaf", in: Self.wall)
        route.open("c", from: "b", in: Self.wall)
        route.zoomedWorkerID = "f"
        #expect(route.groups.map(\.groupID) == ["a", "c"])

        // A zoomed child returns to its group.
        var back = route.back()
        #expect(back == .unzoomed("f"))
        #expect(route == WallRoute(groups: [GroupZoomLevel(groupID: "a", returnFocus: "leaf"),
                                            GroupZoomLevel(groupID: "c", returnFocus: "b")]))
        // A nested group returns to the group it was opened from.
        back = route.back()
        #expect(back == .closed(GroupZoomLevel(groupID: "c", returnFocus: "b")))
        #expect(route.groups.map(\.groupID) == ["a"])
        // The outer group returns to the wall.
        back = route.back()
        #expect(back == .closed(GroupZoomLevel(groupID: "a", returnFocus: "leaf")))
        #expect(route == WallRoute())
        back = route.back()
        #expect(back == nil)
    }

    @Test func anOrdinaryZoomOnTheWallIsUnchanged() {
        var route = WallRoute(zoomedWorkerID: "leaf")
        let back = route.back()
        #expect(back == .unzoomed("leaf"))
        #expect(route == WallRoute())
    }

    @Test func aGroupOpensFromTheGroupThatHoldsItOrFromTheWall() {
        var route = WallRoute()
        route.open("a", from: nil, in: Self.wall)
        // d is not a direct child of a: the path restarts at the wall and stays a line of parents.
        route.open("d", from: "c", in: Self.wall)
        #expect(route.groups == [GroupZoomLevel(groupID: "d", returnFocus: "c")])
        // Opening the open group again changes nothing but a zoom.
        route.zoomedWorkerID = "e"
        route.open("d", from: "e", in: Self.wall)
        #expect(route == WallRoute(groups: [GroupZoomLevel(groupID: "d", returnFocus: "c")]))
    }

    // MARK: Where the keyboard returns

    @Test func theKeyboardReturnsToThePaneThatHadIt() throws {
        var route = WallRoute()
        route.open("a", from: "leaf", in: Self.wall)
        route.open("c", from: "b", in: Self.wall)
        route.zoomedWorkerID = "f"

        // The zoomed child's own tile, in its group.
        var back = try Self.step(&route)
        #expect(route.focus(after: back, in: Self.wall, collapsed: [], coordinator: "lead") == "f")
        // The pane that had the keyboard when the nested group was opened.
        back = try Self.step(&route)
        #expect(route.focus(after: back, in: Self.wall, collapsed: [], coordinator: "lead") == "b")
        // And the one that had it on the wall.
        back = try Self.step(&route)
        #expect(route.focus(after: back, in: Self.wall, collapsed: [], coordinator: "lead") == "leaf")
    }

    @Test func theCoordinatorKeepsTheKeyboardItHadWhenAGroupWasOpened() throws {
        var route = WallRoute()
        route.open("a", from: "lead", in: Self.wall)
        let back = try Self.step(&route)
        #expect(route.focus(after: back, in: Self.wall, collapsed: [], coordinator: "lead") == "lead")
    }

    @Test func aPaneThatIsGoneFallsBackToTheGroupsOwnTile() throws {
        // The pane is no longer drawn at the level: the group's tile there, then the open group's parent.
        var route = WallRoute(groups: [GroupZoomLevel(groupID: "a", returnFocus: "leaf"),
                                       GroupZoomLevel(groupID: "c", returnFocus: "gone")])
        var back = try Self.step(&route)
        #expect(route.focus(after: back, in: Self.wall, collapsed: [], coordinator: "lead") == "c")
        // An opened group draws every direct child, so a branch child's tile is always there.
        route = WallRoute(groups: [GroupZoomLevel(groupID: "a"), GroupZoomLevel(groupID: "c")])
        back = try Self.step(&route)
        #expect(route.focus(after: back, in: Self.wall, collapsed: ["c"], coordinator: "lead") == "c")
        // On the wall, a tile inside a folded group is not drawn: the coordinator.
        route = WallRoute(groups: [GroupZoomLevel(groupID: "a", returnFocus: "b")])
        back = try Self.step(&route)
        #expect(route.focus(after: back, in: Self.wall, collapsed: ["a"], coordinator: "lead") == "lead")
        #expect(route.focus(after: back, in: Self.wall, collapsed: [], coordinator: "lead") == "b")
    }

    @Test func aFoldedGroupOpensWithoutUnfolding() throws {
        // Open group is its own action: the fold on the wall is as the developer left it.
        var route = WallRoute()
        route.open("a", from: "leaf", in: Self.wall)
        #expect(route.shownPanes(in: Self.wall, collapsed: ["a"]) == ["a", "b", "c"])
        _ = try Self.step(&route)
        #expect(route.shownPanes(in: Self.wall, collapsed: ["a"]) == ["leaf"])
    }

    // MARK: Passive updates

    @Test func aRouteFallsBackToTheNearestSurvivingLevel() {
        let route = WallRoute(groups: [GroupZoomLevel(groupID: "a"), GroupZoomLevel(groupID: "c"),
                                       GroupZoomLevel(groupID: "d")], zoomedWorkerID: "e")
        #expect(route.surviving(in: Self.wall) == route)

        // e is gone: d has no child left, so the pane falls back to c with nothing zoomed.
        let withoutE = WallLayout(groups: [WorkerGroup(parent: Self.worker("a"), members: [
            Self.worker("b", parent: "a"), Self.worker("c", parent: "a"), Self.worker("d", parent: "c"),
            Self.worker("f", parent: "c")
        ])])
        #expect(route.surviving(in: withoutE) == WallRoute(groups: [GroupZoomLevel(groupID: "a"), GroupZoomLevel(groupID: "c")]))

        // c and everything under it is gone: back to a.
        let withoutC = WallLayout(groups: [WorkerGroup(parent: Self.worker("a"), members: [Self.worker("b", parent: "a")])])
        #expect(route.surviving(in: withoutC) == WallRoute(groups: [GroupZoomLevel(groupID: "a")]))

        // The whole group is gone: the wall.
        #expect(route.surviving(in: WallLayout(leaves: [Self.worker("leaf")])) == WallRoute())
        // A zoomed worker that is gone leaves its group open.
        let zoomed = WallRoute(groups: [GroupZoomLevel(groupID: "a")], zoomedWorkerID: "gone")
        #expect(zoomed.surviving(in: Self.wall) == WallRoute(groups: [GroupZoomLevel(groupID: "a")]))
    }

    @Test func aSurvivingRouteKeepsWhereTheKeyboardReturns() {
        // A worker arriving beside the group changes nothing about the route.
        let route = WallRoute(groups: [GroupZoomLevel(groupID: "a", returnFocus: "leaf")], zoomedWorkerID: "b")
        var more = Self.wall
        more.leaves.append(Self.worker("new"))
        #expect(route.surviving(in: more) == route)
    }

    // MARK: The pinned parent

    @Test func theParentKeepsItsTileWhileARowOfChildrenStaysReadable() {
        // A tall pane: a third of it, inside the tile's range.
        #expect(GroupZoomPlan(height: 700, zoomsChild: false).parent == .tile(height: 238))
        #expect(GroupZoomPlan(height: 1200, zoomsChild: false).parent == .tile(height: 280))
        // The least pane that leaves a 250 pt row and the hints under a 170 pt tile.
        let least = 170 + Metric.wallRowGap + Metric.minimumWallRowHeight + GroupZoomPlan.hintsHeight
        #expect(GroupZoomPlan(height: least, zoomsChild: false).parent == .tile(height: 170))
        #expect(GroupZoomPlan(height: least, zoomsChild: false).content == Metric.minimumWallRowHeight)
        #expect(GroupZoomPlan(height: least - 1, zoomsChild: false).parent == .strip)
        #expect(GroupZoomPlan(height: 300, zoomsChild: false).parent == .strip)
        #expect(GroupZoomPlan(height: 300, zoomsChild: false).content == nil)
    }

    @Test func zoomingAChildNeverChangesThePinnedParent() {
        // The parent's form and height come from the height alone, at every height: the tile on a
        // tall pane stays that tile over a zoomed child, and the short pane keeps the strip.
        for height in stride(from: CGFloat(200), through: 1400, by: 1) {
            #expect(GroupZoomPlan(height: height, zoomsChild: true).parent == GroupZoomPlan(height: height, zoomsChild: false).parent)
        }
        #expect(GroupZoomPlan(height: 1200, zoomsChild: true).parent == .tile(height: 280))
        #expect(GroupZoomPlan(height: 300, zoomsChild: true).parent == .strip)
        // Only the room under the parent differs: the zoomed child takes the hints' height too.
        let grid = GroupZoomPlan(height: 800, zoomsChild: false), zoomed = GroupZoomPlan(height: 800, zoomsChild: true)
        #expect(grid.hints == GroupZoomPlan.hintsHeight)
        #expect(zoomed.hints == 0)
        #expect(grid.content == 800 - 272 - Metric.wallRowGap - GroupZoomPlan.hintsHeight)
        #expect(zoomed.content == 800 - 272 - Metric.wallRowGap)
    }

    @Test func thePinnedParentIsTheSameViewWhenAChildIsZoomedAndLeft() async throws {
        // The frame drawn off screen, tall enough for the parent's tile. Swapping the content
        // between the grid and a zoomed child must not rebuild or resize the parent's slot.
        let probe = GroupFrameProbe()
        _ = NSApplication.shared
        let host = NSHostingView(rootView: GroupFrameHost(probe: probe).frame(width: 900, height: 800, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle() async throws {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        try await settle()
        #expect(probe.appeared["parent"] == 1)
        #expect(probe.appeared["grid"] == 1)
        let height = try #require(probe.heights["parent"])
        #expect(height == 272)

        probe.zoomsChild = true
        try await settle()
        probe.zoomsChild = false
        try await settle()
        probe.zoomsChild = true
        try await settle()

        #expect(probe.appeared["parent"] == 1)
        #expect(probe.disappeared["parent"] == nil)
        #expect(probe.heights["parent"] == height)
        // The content did change under it each time.
        #expect(probe.appeared["child"] == 2)
        #expect(probe.appeared["grid"] == 2)
        window.contentView = nil
    }

    @Test func theChildrenUseTheWallsOwnPlan() throws {
        // One child fills the room under the parent; two share a row.
        let one = try #require(Self.wall.inside("d")).wall
        let single = WallPlan(WallPlan.Input(width: 900, height: 400, layout: one, collapsed: []))
        #expect(single.leafFrames == [CGRect(x: 0, y: 0, width: 900, height: 400)])
        let two = try #require(WallIdentityTests.wall(.nested).inside("W-066")).wall
        let pair = WallPlan(WallPlan.Input(width: 910, height: 400, layout: two, collapsed: []))
        #expect(pair.leafFrames.map(\.width) == [450, 450])
        #expect(!pair.scrolls)
    }

    // MARK: Names

    @Test func theCrumbSaysWhereBackGoes() {
        #expect(WallCrumbLabel.back(trail: []) == "Return to worker wall")
        #expect(WallCrumbLabel.back(trail: ["Failure paths"]) == "Back to Failure paths")
        #expect(WallCrumbLabel.back(trail: ["Failure paths", "Partial bodies"]) == "Back to Partial bodies")
    }

    // MARK: Pictures

    /// The cockpit on the nested sample wall with groups opened and, optionally, a worker zoomed.
    static func cockpit(groups: [String], zoom: String? = nil) -> some View {
        let store = PreviewStore(scenario: .coordinatorWall)
        store.wallStage = .nested
        store.ui.groupPath = groups.map { GroupZoomLevel(groupID: $0) }
        store.ui.zoomedWorkerID = zoom
        return CockpitScreen(content: DesignFixture.content(for: store), ui: store.ui, actions: DesignFixture.actions(for: store),
                             fixtureNavigation: DesignFixture.navigation(for: store))
    }

    /// Headless pictures of group zoom. Skipped unless WORKSPACE_RENDER_DIR names a folder:
    ///
    ///     WORKSPACE_RENDER_DIR=.build/workspace-renders swift test --filter GroupZoomTests
    @Test(.enabled(if: workspaceRenderDirectory != nil)) func drawsGroupZoom() async throws {
        let folder = URL(fileURLWithPath: try #require(workspaceRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        try await ShellRenderTests.write(Self.cockpit(groups: []), "group-wall", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(groups: ["W-046"]), "group-open", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(groups: ["W-046"], zoom: "W-047"), "group-child-zoom", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(groups: ["W-046", "W-066"]), "group-nested", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(groups: ["W-046"]), "group-open-short", theme: .console, to: folder,
                                         size: CGSize(width: 1100, height: 640))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("group-open-console.png").path))
    }
}
