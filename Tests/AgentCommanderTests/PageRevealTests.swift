import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// A confirmation or a sheet that opens below the fold is scrolled into view by its page. The
// first three tests host a page in a window that is never shown, with the bands' sideways scroll
// on as it is in the live window, open something under the fold and read where the page's own
// scroll view ends up. The last checks the offsets themselves.

@MainActor @Suite struct PageRevealTests {
    /// Shorter than the default window, so the sample pages reach under the fold as the fixture's do at 1280 x 800.
    static let window = CGSize(width: 1280, height: 460)

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    /// Hosts the page, runs `open`, and returns how far the page's column was scrolled: the widest
    /// scroll view whose content is taller than it.
    static func scrolled(_ view: some View, height: CGFloat = window.height, after open: () -> Void) async throws -> CGFloat {
        _ = NSApplication.shared
        let root = view.frame(width: window.width, height: height)
            .environment(\.theme, .console)
            .environment(\.reduceTransparencyOverride, true)
            .environment(\.networkPageScrollsSideways, true)
        let host = NSHostingView(rootView: root)
        let panel = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: window.width, height: height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = host
        defer { panel.contentView = nil }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        #expect(scrollViews(in: host).allSatisfy { $0.contentView.bounds.origin.y == 0 }, "the page starts at its top")
        open()
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        let page = scrollViews(in: host)
            .filter { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height }
            .max { $0.frame.width < $1.frame.width }
        let found = try #require(page)
        return found.contentView.bounds.origin.y
    }

    @Test func theMergeConfirmationIsScrolledIntoView() async throws {
        let relay = TeamsSample.relayKey
        let state = TeamsRenderTests.state(.teamsWorkspace, [.showBand(.integration, workspace: relay)])
        let offset = try await Self.scrolled(TeamsRenderTests.shell(.teamsWorkspace, state: state)) {
            state.teams.pages(go: { _ in }).send(.askMerge(workspace: relay))
        }
        #expect(offset > 0)
    }

    @Test func theRevokeConfirmationIsScrolledIntoView() async throws {
        let state = ShellPreviewState(selection: NetworkPlace.shared)
        let shared = state.network.pages(go: { _ in }).content.sharedRows.first { !$0.grants.isEmpty }
        let row = try #require(shared)
        state.network.selection.shared = row.id
        let grant = try #require(row.grants.last)
        let offset = try await Self.scrolled(NetworkRenderTests.shell(.networkShared, state: state), height: 340) {
            state.network.selection.revoking = "\(row.server)/\(grant.id)"
        }
        #expect(offset > 0)
    }

    @Test func theGrantSheetIsScrolledIntoView() async throws {
        let state = ShellPreviewState(selection: NetworkPlace.approvals)
        let pages = state.network.pages(go: { _ in })
        let incoming = pages.content.accessRows.first { $0.isIncoming }
        let row = try #require(incoming)
        let offset = try await Self.scrolled(NetworkRenderTests.shell(.networkApprovals, state: state)) {
            pages.actions.reviewAccess(row.request, row.server)
        }
        #expect(offset > 0)
    }

    @Test func thePageMovesTheLeastThatShowsTheView() {
        let page = PageReveal.Viewport(offset: 0, height: 400, content: 600)
        // Under the fold: its bottom edge, with the margin, comes to the bottom of the page.
        #expect(PageReveal.offset(showing: CGRect(x: 0, y: 430, width: 500, height: 150), in: page, anchor: nil, margin: 16) == 196)
        // Already showing: nothing moves.
        #expect(PageReveal.offset(showing: CGRect(x: 0, y: 100, width: 500, height: 150), in: page, anchor: nil, margin: 16) == nil)
        // Above the page: its top edge comes down to the top.
        let lower = PageReveal.Viewport(offset: 200, height: 400, content: 600)
        #expect(PageReveal.offset(showing: CGRect(x: 0, y: 60, width: 500, height: 100), in: lower, anchor: nil, margin: 16) == 44)
        // Taller than the page, or anchored to the top: its top edge leads.
        #expect(PageReveal.offset(showing: CGRect(x: 0, y: 300, width: 500, height: 700), in: page, anchor: nil, margin: 16) == 284)
        #expect(PageReveal.offset(showing: CGRect(x: 0, y: 150, width: 500, height: 100), in: page, anchor: .top, margin: 16) == 134)
        // A column measured before it grew still reaches the view; an unmeasured page waits.
        let stale = PageReveal.Viewport(offset: 0, height: 400, content: 400)
        #expect(PageReveal.offset(showing: CGRect(x: 0, y: 430, width: 500, height: 150), in: stale, anchor: nil, margin: 16) == 196)
        #expect(PageReveal.offset(showing: CGRect(x: 0, y: 430, width: 500, height: 150), in: PageReveal.Viewport(), anchor: nil, margin: 16) == nil)
    }
}
