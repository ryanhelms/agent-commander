import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The running shimmer (DESIGN.md, Motion, `shimmer`): one 1.2 s sweep every 2 s, eased at both
// ends, then rest. The curve and the schedule are pure values; the modifier changes no layout.

@MainActor @Suite struct PrettyShimmerTests {
    @Test func theBandSweepsForOnePointTwoSecondsThenRests() {
        #expect(PrettyShimmer.progress(at: 0) == 0)
        #expect(PrettyShimmer.progress(at: 0.6) == 0.5)
        #expect(PrettyShimmer.progress(at: 1.2) == nil)
        #expect(PrettyShimmer.progress(at: 1.5) == nil)
        #expect(PrettyShimmer.progress(at: 1.999) == nil)
        // The next period starts the next sweep, at any reference time.
        #expect(PrettyShimmer.progress(at: 2) == 0)
        #expect(abs((PrettyShimmer.progress(at: 2_000_000.6) ?? -1) - 0.5) < 1e-6)
    }

    @Test func theSweepIsSlowAtBothEnds() throws {
        let early = try #require(PrettyShimmer.progress(at: 0.12))
        let late = try #require(PrettyShimmer.progress(at: 1.08))
        #expect(early < 0.1 * 0.5)
        #expect(1 - late < 0.1 * 0.5)
        let steps = stride(from: 0.0, to: 1.2, by: 0.01).compactMap(PrettyShimmer.progress(at:))
        #expect(steps == steps.sorted())
    }

    @Test func theBandStartsAndEndsOutsideTheLabel() {
        #expect(PrettyShimmer.centre(progress: 0, width: 400, band: 180) == -90)
        #expect(PrettyShimmer.centre(progress: 1, width: 400, band: 180) == 490)
        #expect(PrettyShimmer.centre(progress: 0.5, width: 400, band: 180) == 200)
        #expect(PrettyShimmer.band(bodySize: 14) == 182)
    }

    @Test func theTimelineTicksOnlyWhileTheBandMoves() {
        // Asked in the rest: one entry that draws no band, then the next sweep's frames.
        let rest = Date(timeIntervalSinceReferenceDate: 2 * 1000 + 1.5)
        var entries = PrettyShimmer.Schedule().entries(from: rest, mode: .normal)
        let first = entries.next()!.timeIntervalSinceReferenceDate
        #expect(first <= rest.timeIntervalSinceReferenceDate)
        #expect(PrettyShimmer.progress(at: first) == nil)
        let sweep = (0..<73).map { _ in entries.next()!.timeIntervalSinceReferenceDate }
        #expect(abs(sweep[0] - 2 * 1001) < 1e-6)
        #expect(abs(sweep.last! - (2 * 1001 + 1.2)) < 0.002)
        #expect(sweep.dropLast().allSatisfy { PrettyShimmer.progress(at: $0 + 1e-7) != nil })
        #expect(PrettyShimmer.progress(at: sweep.last!) == nil)
        // Then nothing until the sweep after it.
        #expect(abs(entries.next()!.timeIntervalSinceReferenceDate - 2 * 1002) < 1e-6)

        // Asked mid-sweep: starts at the frame already due.
        let moving = Date(timeIntervalSinceReferenceDate: 2 * 1000 + 0.605)
        var later = PrettyShimmer.Schedule().entries(from: moving, mode: .normal)
        let frame = later.next()!.timeIntervalSinceReferenceDate
        #expect(frame <= moving.timeIntervalSinceReferenceDate)
        #expect(moving.timeIntervalSinceReferenceDate - frame < 1.0 / 60)
    }

    @Test func aShimmeringLabelKeepsItsSize() {
        _ = NSApplication.shared
        let label = Text(verbatim: "Reading runner.go").font(.system(size: 14))
        let still = NSHostingView(rootView: label.prettyShimmer(isActive: false, band: 182))
        let moving = NSHostingView(rootView: label.prettyShimmer(isActive: true, band: 182))
        #expect(still.fittingSize.width > 0)
        #expect(still.fittingSize == moving.fittingSize)
    }

    // The working mark: three dots circling one centre, one turn every 3 s.

    @Test func theWorkingMarkTurnsOnceEveryTwoSeconds() {
        #expect(PrettyWorkingMark.turn(at: 0) == 0)
        #expect(PrettyWorkingMark.turn(at: 0.75) == 0.25)
        #expect(PrettyWorkingMark.turn(at: 3) == 0)
        #expect(abs(PrettyWorkingMark.turn(at: 3_000_001.5) - 0.5) < 1e-6)
    }

    @Test func theDotsKeepThreeSizesInsideTheMark() {
        // Every dot stays inside the mark and runs between the smallest and largest size.
        var smallest = CGFloat.infinity, largest = CGFloat.zero
        for size in [CGFloat(10), 12] {
            for step in 0..<400 {
                let dots = PrettyWorkingMark.dots(turn: Double(step) / 400, size: size)
                #expect(dots.count == 3)
                for dot in dots {
                    #expect(dot.centre.x - dot.radius >= 0 && dot.centre.x + dot.radius <= size)
                    #expect(dot.centre.y - dot.radius >= 0 && dot.centre.y + dot.radius <= size)
                    if size == 12 { smallest = min(smallest, dot.radius); largest = max(largest, dot.radius) }
                }
            }
        }
        #expect(abs(smallest - PrettyWorkingMark.smallest) < 0.01 && abs(largest - PrettyWorkingMark.largest) < 0.01)
        // The measured trio is 3 : 2 : 1.2 from largest to smallest.
        #expect(abs(PrettyWorkingMark.largest / PrettyWorkingMark.smallest - 3 / 1.2) < 1e-9)
        // The cycle closes: its end is its start.
        let start = PrettyWorkingMark.dots(turn: 0, size: 12), end = PrettyWorkingMark.dots(turn: 1, size: 12)
        for (a, b) in zip(start, end) {
            #expect(hypot(a.centre.x - b.centre.x, a.centre.y - b.centre.y) < 1e-9 && abs(a.radius - b.radius) < 1e-9)
        }
        // Standing still, the three sizes differ and no dot touches another.
        let resting = PrettyWorkingMark.dots(turn: PrettyWorkingMark.restingTurn, size: 12)
        let radii = resting.map(\.radius).sorted()
        #expect(radii[1] - radii[0] > 0.25 && radii[2] - radii[1] > 0.25)
        for (a, b) in [(0, 1), (1, 2), (0, 2)] {
            let gap = hypot(resting[a].centre.x - resting[b].centre.x, resting[a].centre.y - resting[b].centre.y)
            #expect(gap > resting[a].radius + resting[b].radius)
        }
    }

    @Test func theWorkingMarkHasTheSpinnersFootprint() {
        _ = NSApplication.shared
        for size in [CGFloat(10), 12] {
            #expect(NSHostingView(rootView: PrettyWorkingMark(size: size)).fittingSize
                    == NSHostingView(rootView: PrettySpinner(isSpinning: true, size: size)).fittingSize)
        }
    }

    /// The live line is the same size working as it was with the spinner and a still label.
    @Test func theLiveLineKeepsItsSizeWhileItWorks() {
        _ = NSApplication.shared
        let metrics = PrettyMetrics(.regular)
        func size(_ subject: PrettyLiveLine.Subject, active: Bool) -> CGSize {
            let line = PrettyLiveLine(subject: subject, live: PrettyLive(isActive: active, isDisconnected: false),
                                      isExpanded: false, metrics: metrics) {}
            return NSHostingView(rootView: line.frame(width: 600)).fittingSize
        }
        #expect(size(.thinking(text: "", started: nil), active: true).height
                == size(.thinking(text: "", started: nil), active: false).height)
        #expect(size(.responding("tracer"), active: true) == size(.responding("tracer"), active: false))
    }
}
