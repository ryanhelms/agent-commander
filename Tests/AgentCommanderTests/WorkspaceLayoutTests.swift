import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The workspace layout of issue #221: when the worker region opens, what the divider remembers and
// reports, how the wall is planned for one, a few and many workers, and what keeps its identity
// while the layout changes. The geometry is exercised as plain values. Two hosted checks draw the
// template and the wall off screen to prove that a view is the same view after the change. Nothing
// here opens a window on screen, touches the running app or writes the app's preferences.

let workspaceRenderDirectory = ProcessInfo.processInfo.environment["WORKSPACE_RENDER_DIR"]

@MainActor @Suite struct WorkspaceSplitTests {
    private func split(_ width: CGFloat, _ fraction: Double = Metric.coordinatorFraction, workers: Bool = true,
                       drawer: Bool = false, pinned: Bool = false) -> WorkspaceSplitGeometry {
        WorkspaceSplitGeometry(width: width, fraction: fraction, showsWorkers: workers, showsDrawer: drawer, drawerPinned: pinned)
    }

    @Test func theWallOpensForAWorkerTheRunListsOrAZoomedRemoteWorker() {
        #expect(!WorkspaceSplitGeometry.showsWorkers(localWorkers: 0, zoomsRemoteWorker: false))
        #expect(WorkspaceSplitGeometry.showsWorkers(localWorkers: 1, zoomsRemoteWorker: false))
        #expect(WorkspaceSplitGeometry.showsWorkers(localWorkers: 0, zoomsRemoteWorker: true))
    }

    @Test func aCoordinatorWithNoWorkersTakesTheWholeWidth() {
        let alone = split(1470, workers: false)
        #expect(alone.coordinatorWidth == 1470)
        #expect(alone.workerWidth == 0)
    }

    @Test func theFirstSplitGivesTheCoordinatorAboutAThird() {
        let open = split(1470)
        #expect(abs(open.leadingWidth - 470.4) < 0.01)
        #expect(open.coordinatorWidth == open.leadingWidth - WorkspaceSplitGeometry.divider)
        #expect(abs(open.workerWidth - 999.6) < 0.01)
        #expect(open.percent == 32)
    }

    @Test func aNarrowWindowKeepsBothPanesUsable() {
        let narrow = split(600)
        #expect(narrow.leadingWidth == 260)
        #expect(narrow.workerWidth == Metric.minimumWorkerRegionWidth)
        // The divider says what is drawn, not the remembered third.
        #expect(narrow.percent == 43)
    }

    @Test func aRememberedPositionIsKeptAndDrawnWhereTheWindowAllows() {
        // 700 pt leaves the coordinator 360 pt beside the least worker region.
        let remembered = split(700, 0.6)
        #expect(remembered.fraction == 0.6)
        #expect(remembered.leadingWidth == 360)
        #expect(remembered.percent == 51)
        // The same choice in a wide window is drawn as chosen.
        #expect(split(2000, 0.6).leadingWidth == 1200)
    }

    @Test func movingTheDividerStartsFromWhereItIsDrawn() {
        let remembered = split(700, 0.6)
        // Further right has no room: the result is the position on screen, not 0.62.
        #expect(abs(remembered.fraction(movedBy: 0.02) - 360.0 / 700) < 0.0001)
        // Left moves at once, from the drawn 360 pt, not from the remembered 60%.
        #expect(abs(remembered.fraction(movedBy: -0.02) - 346.0 / 700) < 0.0001)
        // Every result is a position the window can show.
        for delta in [-1.0, -0.3, 0.3, 1.0] {
            let moved = split(700, remembered.fraction(movedBy: delta))
            #expect(abs(moved.renderedFraction - moved.fraction) < 0.0001)
        }
    }

    @Test func aPinnedPanelTakesItsWidthOnlyWhileATileStaysReadable() {
        #expect(split(1470, drawer: true, pinned: true).drawerReservation == Metric.attentionDrawerWidth)
        // 580 pt of worker region can't hold the panel and a readable tile: the panel lies over it.
        #expect(split(900, drawer: true, pinned: true).drawerReservation == 0)
        #expect(split(1470, drawer: true, pinned: false).drawerReservation == 0)
        #expect(split(1470, drawer: false, pinned: true).drawerReservation == 0)
        // With no workers the panel sits beside the coordinator.
        #expect(split(1470, workers: false, drawer: true, pinned: true).drawerReservation == Metric.attentionDrawerWidth)
    }

    @Test func onlyAPositionTheDividerCanSetIsReadBack() throws {
        let name = "workspace-layout-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CockpitView.storedSplitFraction(in: defaults) == nil)
        defaults.set(0.45, forKey: CockpitView.coordinatorSplitKey)
        #expect(CockpitView.storedSplitFraction(in: defaults) == 0.45)
        defaults.set(3.0, forKey: CockpitView.coordinatorSplitKey)
        #expect(CockpitView.storedSplitFraction(in: defaults) == nil)
    }
}

@MainActor @Suite struct WallPlanTests {
    private func leaves(_ count: Int) -> [String] { (0..<count).map { "l\($0)" } }

    private func plan(width: CGFloat = 1000, height: CGFloat = 700, leaves count: Int = 0,
                      groups: [WallPlan.GroupInput] = [], reserved: CGFloat = 0, footer: CGFloat = 0) -> WallPlan {
        WallPlan(WallPlan.Input(width: width, height: height, leaves: leaves(count), groups: groups,
                                reservedTrailing: reserved, footerHeight: footer))
    }

    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

    @Test func oneWorkerFillsTheWall() {
        let one = plan(leaves: 1)
        #expect(one.leafFrames.count == 1)
        #expect(one.leafFrames[0].origin == .zero && one.leafFrames[0].width == 1000)
        #expect(close(one.leafFrames[0].height, 700))
        #expect(!one.scrolls)
    }

    @Test func twoAndThreeWorkersShareOneRowEqually() {
        let two = plan(leaves: 2)
        #expect(two.leafFrames.map(\.width) == [495, 495])
        #expect(two.leafFrames.map(\.minX) == [0, 505])
        #expect(two.leafFrames.allSatisfy { close($0.height, 700) })
        let three = plan(leaves: 3)
        #expect(three.leafFrames.allSatisfy { close($0.width, 980 / 3) && $0.minY == 0 })
    }

    @Test func twoWorkersStackWhereOnlyOneColumnFits() {
        let stacked = plan(width: 320, height: 600, leaves: 2)
        #expect(stacked.columns == 1)
        #expect(stacked.leafFrames.map(\.width) == [320, 320])
        #expect(stacked.leafFrames[1].minY == stacked.leafFrames[0].maxY + Metric.wallRowGap)
    }

    @Test func aLargerSetKeepsAnIncompleteRowAtTheColumnWidth() {
        let four = plan(leaves: 4)
        #expect(four.columns == 3)
        #expect(four.leafFrames.allSatisfy { close($0.width, four.columnWidth) })
        #expect(four.leafFrames[3].minX == 0)
        #expect(four.leafFrames[3].minY > four.leafFrames[0].maxY)
        // Two rows share the height with the gap between them.
        #expect(close(four.tilesHeight, 700))
        #expect(!four.scrolls)
    }

    @Test func rowsKeepAReadableHeightAndTheWallScrolls() {
        let narrow = plan(width: 320, height: 600, leaves: 3)
        #expect(narrow.leafFrames.allSatisfy { $0.height == Metric.minimumWallRowHeight })
        #expect(narrow.contentHeight == 3 * 250 + 2 * Metric.wallRowGap)
        #expect(narrow.scrolls)
    }

    @Test func theApprovedWideWallKeepsThreeWorkersOverTwoEqualGroupTiles() {
        let group = WallPlan.GroupInput(id: "g", workers: ["p", "m"], collapsed: false)
        let wide = plan(height: 760, leaves: 3, groups: [group], reserved: Metric.pipReservedWidth)
        #expect(wide.leafFrames.count == 3)
        #expect(wide.leafFrames.allSatisfy { close($0.width, 980 / 3) && $0.minY == 0 })
        let framed = wide.groups[0]
        // The group gives way to the PiP; its tiles are equal inside its own edge.
        #expect(wide.reserved == Metric.pipReservedWidth)
        #expect(framed.frame.width == 1000 - Metric.pipReservedWidth)
        #expect(framed.columns == 2)
        #expect(framed.tiles.map(\.width) == [302.5, 302.5])
        // The standalone row weighs 1.1 against the group's 1, and together they fill the wall.
        #expect(close(wide.leafFrames[0].height / framed.frame.height, 1.1))
        #expect(close(framed.frame.maxY, 760))
        // The tiles are what is left of the group under its heading and inside its inset.
        #expect(close(framed.tiles[0].height, framed.frame.height - WallPlan.groupChrome(rows: 1)))
        #expect(!wide.scrolls)
    }

    @Test func aGroupCountsColumnsInsideItsOwnEdge() {
        // 930 pt fits three standalone columns; 912 pt inside the group's edge fits two.
        let group = WallPlan.GroupInput(id: "g", workers: ["p", "a", "b"], collapsed: false)
        let tight = plan(width: 930, height: 900, leaves: 3, groups: [group])
        #expect(tight.columns == 3)
        #expect(tight.groups[0].columns == 2)
        #expect(tight.groups[0].tiles.allSatisfy { $0.width >= Metric.minimumTileWidth })
        // The third tile starts a second row at the same width.
        #expect(tight.groups[0].tiles[2].minX == 0)
        #expect(tight.groups[0].tiles[2].width == tight.groups[0].tiles[0].width)
    }

    @Test func aGroupNeverGoesUnderAReadableTileHeight() {
        let group = WallPlan.GroupInput(id: "g", workers: ["p", "m"], collapsed: false)
        let short = plan(height: 300, leaves: 3, groups: [group])
        #expect(short.groups[0].tiles.allSatisfy { $0.height == Metric.minimumWallRowHeight })
        #expect(short.scrolls)
    }

    @Test func theLastRowGivesWayToThePiPOnlyWhereItsTilesStayReadable() {
        // One tile in the last row: it fits beside the PiP at the column width.
        let roomy = plan(leaves: 4, reserved: Metric.pipReservedWidth)
        #expect(roomy.reserved == Metric.pipReservedWidth)
        #expect(close(roomy.leafFrames[3].width, roomy.columnWidth))
        // 253 pt beside the PiP is not a readable tile: nothing is reserved and the tile keeps its width.
        let cramped = plan(width: 620, leaves: 3, reserved: Metric.pipReservedWidth)
        #expect(cramped.reserved == 0)
        #expect(cramped.leafFrames[2].width == 305)
        // A single row is never squeezed.
        #expect(plan(leaves: 3, reserved: Metric.pipReservedWidth).reserved == 0)
        // A folded group is a heading, not a row to make room in.
        let folded = WallPlan.GroupInput(id: "g", workers: ["p", "m"], collapsed: true)
        #expect(plan(leaves: 3, groups: [folded], reserved: Metric.pipReservedWidth).reserved == 0)
    }

    @Test func remoteSectionsShareTheScrollAndNeverStarveATile() {
        // The footer fits: the tile takes what it leaves and nothing scrolls.
        let fits = plan(leaves: 1, footer: 200)
        #expect(fits.leafFrames[0].height == 500)
        #expect(fits.contentHeight == 700)
        #expect(!fits.scrolls)
        // The footer wants more than the wall has: the tile keeps its height and the wall scrolls.
        let tall = plan(leaves: 1, footer: 600)
        #expect(tall.leafFrames[0].height == Metric.minimumWallRowHeight)
        #expect(tall.contentHeight == 850)
        #expect(tall.scrolls)
    }

    @Test func remoteCardsTakeFewerColumnsInANarrowWall() {
        // Wide: three columns, and a row that is not full keeps the column width.
        let wide = RemoteWorkerGrid.frames(count: 2, width: 897)
        #expect(RemoteWorkerGrid.columns(fitting: 897) == 3)
        #expect(wide.allSatisfy { close($0.width, 877 / 3) && $0.minY == 0 })
        // Narrower: two columns, then the third card on the next row.
        let two = RemoteWorkerGrid.frames(count: 3, width: 430)
        #expect(two.map(\.width) == [210, 210, 210])
        #expect(two[2].minX == 0 && two[2].minY == RemoteWorkerGroup.tileHeight + Metric.tileGap)
        // The narrowest worker region: one readable column.
        let one = RemoteWorkerGrid.frames(count: 3, width: 282)
        #expect(one.allSatisfy { $0.width == 282 && $0.minX == 0 })
        #expect(one.allSatisfy { $0.width >= RemoteWorkerGrid.minimumTileWidth })
    }

    @Test func aFoldedGroupIsItsHeading() {
        let group = WallPlan.GroupInput(id: "g", workers: ["p", "m"], collapsed: true)
        let folded = plan(leaves: 3, groups: [group])
        #expect(folded.groups[0].frame.height == Metric.groupHeaderHeight)
        #expect(folded.groups[0].tiles.isEmpty)
        #expect(close(folded.groups[0].frame.maxY, 700))
        // A worker inside it is found at the heading.
        #expect(folded.frame(of: "m") == folded.groups[0].frame)
    }

    @Test func theWorkerAtTheTopStaysThereWhenTheColumnsChange() {
        let three = plan(height: 400, leaves: 9)
        #expect(three.leafFrames[6].minY == 534)
        // Scrolled 26 pt into the third row, whose first worker is l6.
        let two = plan(width: 650, height: 400, leaves: 9)
        #expect(two.columns == 2)
        #expect(WallPlan.anchoredOffset(560, from: three, to: two) == two.leafFrames[6].minY + 26)
        // At the top it stays at the top.
        #expect(WallPlan.anchoredOffset(0, from: three, to: two) == 0)
    }

    @Test func theOffsetFitsTheNewContentWhenTheTopWorkerIsGone() {
        let nine = plan(height: 400, leaves: 9)
        let three = plan(height: 400, leaves: 3)
        #expect(three.maximumOffset == 0)
        #expect(WallPlan.anchoredOffset(560, from: nine, to: three) == 0)
        // A worker added below keeps the same worker at the top.
        let ten = plan(height: 400, leaves: 10)
        #expect(WallPlan.anchoredOffset(300, from: nine, to: ten) == 300)
    }

    @Test func aTileIsBroughtIntoViewWithTheLeastMovement() {
        let wall = plan(height: 400, leaves: 9)
        #expect(wall.offset(revealing: "l0", from: 0) == nil)
        // Below the fold: its lower edge meets the wall's.
        #expect(wall.offset(revealing: "l8", from: 0) == 384)
        // Above: its top edge meets the wall's.
        #expect(wall.offset(revealing: "l0", from: 384) == 0)
        #expect(wall.offset(revealing: "gone", from: 0) == nil)
    }
}

@MainActor @Suite struct WallIdentityTests {
    /// The sample run's wall at a preview stage.
    static func wall(_ stage: PreviewWallStage, scenario: DesignPreviewScenario = .coordinatorWall) -> WallLayout {
        let store = PreviewStore(scenario: scenario)
        store.wallStage = stage
        return DesignFixture.content(for: store).selected?.wall ?? WallLayout()
    }

    @Test func theStagesGrowTheWallWithoutRenamingOrReorderingAWorker() {
        #expect(Self.wall(.none).workers.isEmpty)
        #expect(Self.wall(.one).workers.map(\.id) == ["W-043"])
        #expect(Self.wall(.two).workers.map(\.id) == ["W-043", "W-044"])
        #expect(Self.wall(.three).workers.map(\.id) == ["W-043", "W-044", "W-045"])
        let many = Self.wall(.many)
        #expect(many.leaves.map(\.id) == ["W-043", "W-044", "W-045", "W-061", "W-062", "W-063", "W-064"])
        #expect(many.groups.map { $0.all.map(\.id) } == [["W-046", "W-047"]])
        #expect(Self.wall(.concept).workers.count == 5)
        #expect(Self.wall(.cleared).workers.isEmpty)
    }

    @Test func aFinishedOrDisconnectedLastWorkerKeepsTheSplit() throws {
        let finished = try #require(Self.wall(.finished).workers.first)
        #expect(finished.id == "W-043" && finished.state == .completed)
        let dropped = try #require(Self.wall(.disconnected).workers.first)
        #expect(dropped.id == "W-043" && dropped.isDisconnected)
        for stage in [PreviewWallStage.finished, .disconnected] {
            #expect(WorkspaceSplitGeometry.showsWorkers(localWorkers: Self.wall(stage).workers.count, zoomsRemoteWorker: false))
        }
        // Only a wall with nobody on it closes the split.
        for stage in [PreviewWallStage.none, .cleared] {
            #expect(!WorkspaceSplitGeometry.showsWorkers(localWorkers: Self.wall(stage).workers.count, zoomsRemoteWorker: false))
        }
    }

    @Test func attentionStaysReachableWithNoWorkers() {
        // Another run's request is still pending while this run has no worker.
        let store = PreviewStore(scenario: .attentionPanel)
        store.wallStage = .none
        let content = DesignFixture.content(for: store)
        #expect(content.selected?.wall.workers.isEmpty == true)
        #expect(content.pending.map(\.id) == ["Q-021"])
        #expect(content.attentionQueue(store.ui).map(\.id) == ["Q-021"])
        // A worker that is not on the wall asks nothing.
        store.wallStage = .concept
        #expect(DesignFixture.content(for: store).pending.map(\.id).contains("Q-018"))
    }

    @Test func theStagesStepInOrderAndStopAtEitherEnd() {
        #expect(PreviewWallStage.concept.stepped(-1) == .concept)
        #expect(PreviewWallStage.concept.stepped(1) == PreviewWallStage.none)
        #expect(PreviewWallStage.disconnected.stepped(1) == .cleared)
        #expect(PreviewWallStage.cleared.stepped(1) == .cleared)
    }

    @Test func theKeyboardReturnsToTheTileOrFallsBack() {
        let wall = Self.wall(.concept)
        #expect(WallFocus.returnTarget(preferred: "W-044", layout: wall, coordinator: "W-042") == "W-044")
        // The zoomed worker is gone: the coordinator takes the keyboard.
        #expect(WallFocus.returnTarget(preferred: "W-099", layout: wall, coordinator: "W-042") == "W-042")
        #expect(WallFocus.returnTarget(preferred: nil, layout: wall, coordinator: "W-042") == "W-042")
        #expect(WallFocus.returnTarget(preferred: "W-042", layout: WallLayout(), coordinator: "W-042") == "W-042")
        // No coordinator reported: the wall's first worker.
        #expect(WallFocus.returnTarget(preferred: "W-099", layout: wall, coordinator: nil) == "W-043")
        // A tile inside a folded group has its group opened.
        #expect(WallFocus.foldedGroup(hiding: "W-047", layout: wall, collapsed: ["W-046"]) == "W-046")
        #expect(WallFocus.foldedGroup(hiding: "W-047", layout: wall, collapsed: []) == nil)
        #expect(WallFocus.foldedGroup(hiding: "W-044", layout: wall, collapsed: ["W-046"]) == nil)
    }

    @Test func aWorkerThatGainsANestedWorkerIsKnownAsRegrouped() {
        let before = WallFocus.placement(of: Self.wall(.three))
        let after = WallFocus.placement(of: Self.wall(.regrouped))
        #expect(before["W-044"] == "" && after["W-044"] == "W-044")
        // Only the worker that moved: its neighbours, a new worker and one that left did not.
        #expect(WallFocus.regrouped("W-044", from: before, to: after))
        #expect(!WallFocus.regrouped("W-043", from: before, to: after))
        #expect(!WallFocus.regrouped("W-065", from: before, to: after))
        #expect(!WallFocus.regrouped("W-044", from: before, to: [:]))
        // And back out of the group.
        #expect(WallFocus.regrouped("W-044", from: after, to: before))
        // Output, status and a worker arriving beside it regroup nobody.
        let more = WallFocus.placement(of: Self.wall(.many))
        #expect(Self.wall(.three).workers.allSatisfy { !WallFocus.regrouped($0.id, from: before, to: more) })
    }

    @Test func theKeyboardGoesBackOnlyWhenNothingElseHasIt() {
        // The tile dropped the keyboard as it moved: it gets it back.
        #expect(WallFocus.restoresFocus(paneFocus: nil, replyFocus: nil, textHasKeyboard: false))
        // The same tile still has it, or the coordinator took it: nothing to do, nothing stolen.
        #expect(!WallFocus.restoresFocus(paneFocus: "W-044", replyFocus: nil, textHasKeyboard: false))
        #expect(!WallFocus.restoresFocus(paneFocus: "W-042", replyFocus: nil, textHasKeyboard: false))
        // A reply to any request, or a draft in any text field, keeps the keyboard.
        #expect(!WallFocus.restoresFocus(paneFocus: nil, replyFocus: "Q-021", textHasKeyboard: false))
        #expect(!WallFocus.restoresFocus(paneFocus: nil, replyFocus: nil, textHasKeyboard: true))
    }

    @Test func aRemoteZoomReturnsToItsOwnTileWhileTheWallDrawsIt() {
        let listed = ["studio/ho-1", "studio/ho-2", "studio/ho-3", "studio/ho-4"]
        #expect(WallFocus.remoteReturnTarget("studio/ho-2", listed: listed) == "studio/ho-2")
        // Past the tiles the wall shows, or no longer listed: the previous pane takes the keyboard.
        #expect(WallFocus.remoteReturnTarget("studio/ho-4", listed: listed) == nil)
        #expect(WallFocus.remoteReturnTarget("studio/ho-9", listed: listed) == nil)
        #expect(WallFocus.remoteReturnTarget("studio/ho-1", listed: []) == nil)
    }

    @Test func followingARequestNeverNamesThePaneTheKeyboardReturnsTo() {
        // Another worker's request sets where a reply returns to, never the pane that held the keyboard.
        let store = PreviewStore(scenario: .attentionPanel)
        store.ui.lastPaneFocusID = "W-043"
        let content = DesignFixture.content(for: store)
        let request = content.pending.first { $0.workerID == "W-047" }
        if let request { store.ui.reveal(request, from: content.selected, selectRun: { _ in }) }
        #expect(request != nil)
        #expect(store.ui.returnFocusWorkerID == "W-047")
        #expect(store.ui.lastPaneFocusID == "W-043")
    }

    @Test func aFoldedGroupSpeaksTheNeedsInputItsHeadingShows() {
        func label(collapsed: Bool, request: Bool) -> String {
            NestedWorkerGroupLabel.spoken(name: "Failure paths", nestedCount: 1, collapsed: collapsed,
                                          hasRequest: request, hasDisconnected: false, reconnectingHost: nil)
        }
        #expect(label(collapsed: true, request: true) == "Failure paths, 1 nested, needs input")
        // Open, the tile that asks says so itself.
        #expect(label(collapsed: false, request: true) == "Failure paths, 1 nested")
        #expect(label(collapsed: true, request: false) == "Failure paths, 1 nested")
        #expect(NestedWorkerGroupLabel.spoken(name: "Failure paths", nestedCount: 2, collapsed: true, hasRequest: true,
                                              hasDisconnected: true, reconnectingHost: "build-01")
                == "Failure paths, 2 nested, needs input, a worker is disconnected, host build-01 reconnecting")
    }
}

// MARK: - Hosted checks

/// What the hosted views are drawn from, and what they report back.
@MainActor @Observable final class LayoutProbe {
    var showsWorkers = false
    var width: CGFloat = 1000
    var wall = WallLayout()
    @ObservationIgnored var appeared: [String: Int] = [:]
    @ObservationIgnored var disappeared: [String: Int] = [:]
    @ObservationIgnored var widths: [String: CGFloat] = [:]
}

/// A view that counts how often it is built into the hierarchy and reports its width.
private struct ProbeMark: View {
    let id: String
    let probe: LayoutProbe

    var body: some View {
        Color.clear
            .onAppear { probe.appeared[id, default: 0] += 1 }
            .onDisappear { probe.disappeared[id, default: 0] += 1 }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { probe.widths[id] = $0 }
    }
}

private struct SplitHost: View {
    let probe: LayoutProbe
    @State private var fraction = Metric.coordinatorFraction

    var body: some View {
        CoordinatorSplit(fraction: $fraction, showsTrailing: probe.showsWorkers, showsFloating: false) {
            EmptyView()
        } leading: {
            ProbeMark(id: "coordinator", probe: probe)
        } trailing: {
            ProbeMark(id: "workers", probe: probe)
        } floating: {
            EmptyView()
        }
    }
}

private struct WallHost: View {
    let probe: LayoutProbe

    var body: some View {
        WorkerWall(layout: probe.wall, collapsed: [], toggleGroup: { _ in }) { worker in
            ProbeMark(id: worker.id, probe: probe)
        }
        .frame(width: probe.width, height: 700)
    }
}

@MainActor @Suite(.serialized) struct WorkspaceMountTests {
    /// Draws a view off screen and returns what lays it out again after a change.
    private func host(_ view: some View, size: CGSize) -> (window: NSWindow, settle: () async throws -> Void) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        return (window, {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
        })
    }

    @Test func theCoordinatorIsTheSameViewWhenTheFirstWorkerArrivesAndTheLastLeaves() async throws {
        let probe = LayoutProbe()
        let (window, settle) = host(SplitHost(probe: probe), size: CGSize(width: 1240, height: 600))
        defer { window.contentView = nil }
        try await settle()
        // Alone, the coordinator has the whole width inside its insets and no worker pane exists.
        #expect(probe.widths["coordinator"] == 1240 - 2 * Metric.paneInset)
        #expect(probe.appeared["workers"] == nil)

        probe.showsWorkers = true
        try await settle()
        let third = try #require(probe.widths["coordinator"])
        #expect(abs(third - (1240 * Metric.coordinatorFraction - WorkspaceSplitGeometry.divider - 2 * Metric.paneInset)) < 0.5)
        #expect(probe.appeared["workers"] == 1)

        probe.showsWorkers = false
        try await settle()
        #expect(probe.widths["coordinator"] == 1240 - 2 * Metric.paneInset)
        #expect(probe.disappeared["workers"] == 1)
        // Built once, never removed: its focus, draft, scroll position and terminal stay with it.
        #expect(probe.appeared["coordinator"] == 1)
        #expect(probe.disappeared["coordinator"] == nil)
    }

    @Test func aTileIsTheSameViewWhenWorkersArriveAndTheColumnsChange() async throws {
        let probe = LayoutProbe()
        probe.wall = WallIdentityTests.wall(.one)
        let (window, settle) = host(WallHost(probe: probe), size: CGSize(width: 1000, height: 700))
        defer { window.contentView = nil }
        try await settle()
        // One worker fills the wall.
        #expect(probe.widths["W-043"] == 1000)

        probe.wall = WallIdentityTests.wall(.three)
        try await settle()
        #expect(abs((probe.widths["W-043"] ?? 0) - 980 / 3) < 0.5)

        probe.wall = WallIdentityTests.wall(.many)
        try await settle()
        // Three columns become two: every tile moves to another row or column.
        probe.width = 650
        try await settle()
        #expect(probe.widths["W-043"] == 320)

        // The group's tiles too, and a worker's status changing leaves every tile in place.
        probe.wall = WallIdentityTests.wall(.concept)
        try await settle()
        for id in ["W-043", "W-044", "W-045", "W-046", "W-047"] {
            #expect(probe.appeared[id] == 1, "\(id) was rebuilt")
            #expect(probe.disappeared[id] == nil, "\(id) was removed")
        }
        // The workers that left were removed once.
        #expect(probe.disappeared["W-061"] == 1)
    }

    @Test func aTileIsTheSameViewWhenItsWorkerMovesIntoAGroupAndBack() async throws {
        let probe = LayoutProbe()
        probe.wall = WallIdentityTests.wall(.three)
        let (window, settle) = host(WallHost(probe: probe), size: CGSize(width: 1000, height: 700))
        defer { window.contentView = nil }
        try await settle()
        let standalone = try #require(probe.widths["W-044"])
        #expect(abs(standalone - 980 / 3) < 0.5)

        // Retry telemetry gains its first nested worker and moves into a new group.
        probe.wall = WallIdentityTests.wall(.regrouped)
        try await settle()
        let grouped = try #require(probe.widths["W-044"])
        // Two equal tiles inside the group's edge.
        #expect(abs(grouped - (1000 - 2 * WallFrameLayout.groupInset - Metric.tileGap) / 2) < 0.5)
        #expect(probe.appeared["W-065"] == 1)

        // The nested worker is gone and it is standalone again.
        probe.wall = WallIdentityTests.wall(.three)
        try await settle()
        #expect(abs((probe.widths["W-044"] ?? 0) - standalone) < 0.5)
        // Never rebuilt, in either direction: the view that held the keyboard still exists.
        for id in ["W-043", "W-044", "W-045"] {
            #expect(probe.appeared[id] == 1, "\(id) was rebuilt")
            #expect(probe.disappeared[id] == nil, "\(id) was removed")
        }
    }

    /// The cockpit at a wall stage, as the design preview draws it, or in the live shell with the
    /// sample remote work when `shell` is set.
    static func cockpit(_ stage: PreviewWallStage, scenario: DesignPreviewScenario = .coordinatorWall,
                        shell: Bool = false) -> some View {
        let store = PreviewStore(scenario: scenario)
        store.wallStage = stage
        if shell { store.ui.shellPlace = LiveShell.wall }
        return CockpitScreen(content: DesignFixture.content(for: store), ui: store.ui, actions: DesignFixture.actions(for: store),
                             fixtureNavigation: shell ? nil : DesignFixture.navigation(for: store),
                             shell: shell ? ShellContext(network: ShellLiveTests.network, chrome: .drawn, now: ShellLiveTests.now,
                                                         wall: WallRenderTests.sample(), wallActions: WallLiveWorkActions()) : nil)
    }

    /// Headless pictures of every wall stage. Skipped unless WORKSPACE_RENDER_DIR names a folder:
    ///
    ///     WORKSPACE_RENDER_DIR=.build/workspace-renders swift test --filter WorkspaceMount
    @Test(.enabled(if: workspaceRenderDirectory != nil)) func drawsTheWallStages() async throws {
        let folder = URL(fileURLWithPath: try #require(workspaceRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for stage in PreviewWallStage.allCases {
            try await ShellRenderTests.write(Self.cockpit(stage), "workspace-\(stage.rawValue)", theme: .console, to: folder)
        }
        // The side panel beside a coordinator with no workers, and the PiP over a wall that scrolls.
        try await ShellRenderTests.write(Self.cockpit(.none, scenario: .attentionPanel), "workspace-none-panel", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(.many, scenario: .pipArrival), "workspace-many-pip", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(.concept, scenario: .attentionPanel), "workspace-concept-panel", theme: .console, to: folder)
        // The live shell: remote work in the wall's scroll, and no split for remote work alone.
        try await ShellRenderTests.write(Self.cockpit(.one, shell: true), "workspace-shell-one", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(.none, shell: true), "workspace-shell-none", theme: .console, to: folder)
        try await ShellRenderTests.write(Self.cockpit(.concept, shell: true), "workspace-shell-narrow", theme: .console, to: folder,
                                         size: CGSize(width: 1000, height: 760))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("workspace-none-console.png").path))
    }
}
