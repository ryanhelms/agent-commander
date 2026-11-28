import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Closing a Needs you review hands keyboard focus back to the row's own button (issue #215).
// The page is hosted in a window of its own, off screen, that can take the keyboard. Nothing here
// touches the running app, the pasteboard or user defaults.

/// A window that can hold the keyboard without a title bar.
final class NeedsYouKeyboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Stands in for the feature layer: the review state, and how often a row asked to open.
@Observable @MainActor
final class NeedsYouReviewHarness {
    var review = NeedsYouReviewState()
    var decided: [String] = []
    var replied: [String] = []
}

struct NeedsYouReviewHarnessPage: View {
    let harness: NeedsYouReviewHarness
    let inbox: NeedsYouInbox

    var body: some View {
        NeedsYouPage(inbox: inbox,
                     decide: { id, _ in harness.decided.append(id) },
                     open: { _ in },
                     reply: { harness.replied.append($0) },
                     review: NeedsYouReviewContext(
                         state: harness.review, detail: nil, now: NeedsYouReviewTests.now, draft: .constant(""),
                         open: { harness.review.open($0) },
                         close: { harness.review.close(rows: $0) },
                         setMode: { harness.review.setMode($0) },
                         copy: { _ in },
                         answer: { _, _ in },
                         openSource: { _ in },
                         remember: { harness.review = $0 }))
    }
}

@MainActor @Suite(.serialized) struct NeedsYouReviewFocusTests {
    static let inbox = NeedsYouInbox(items: [
        NeedsYouReviewTests.item("Q-018"),
        NeedsYouReviewTests.item("N-1", kind: .networkApproval, expiresIn: 600),
        NeedsYouReviewTests.item("Q-021")
    ])

    /// The page in a window of the given width, with the keyboard.
    static func host(_ harness: NeedsYouReviewHarness, width: CGFloat) async throws -> NeedsYouKeyboardWindow {
        _ = NSApplication.shared
        let root = NeedsYouReviewHarnessPage(harness: harness, inbox: inbox)
            .frame(width: width, height: 620)
            .environment(\.theme, .console)
        let window = NeedsYouKeyboardWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 620),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        return window
    }

    static func settle(_ window: NSWindow, for duration: Duration = .milliseconds(450)) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: duration)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Presses Space on whatever holds the keyboard. A row that holds it opens its own request,
    /// which names the row: the hosting view is the first responder for every SwiftUI control.
    static func pressSpace(in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, characters: " ",
                                                      charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            window.sendEvent(event)
        }
    }

    @Test(arguments: [700.0, 1_200.0])
    func closingTheReviewGivesTheKeyboardBackToItsRow(_ width: Double) async throws {
        let harness = NeedsYouReviewHarness()
        let window = try await Self.host(harness, width: CGFloat(width))
        defer { window.close() }
        // Nothing asked for the keyboard yet.
        #expect(window.firstResponder === window)

        harness.review.open("N-1")
        try await Self.settle(window)
        // Opening a request leaves the keyboard where it was; only closing sends it to the row.
        #expect(window.firstResponder === window)
        let shown = NeedsYouReviewLayout.shown(harness.review.mode, width: CGFloat(width))
        #expect(shown == (width < 772 ? .full : .aside))

        harness.review.close(rows: Self.inbox.ordered.map(\.id))
        try await Self.settle(window, for: .milliseconds(700))
        #expect(harness.review.returnTo?.id == "N-1")
        #expect(window.firstResponder !== window, "the keyboard is on a control again, not on the window")
        // The control is that row's own button: it is the last row, and Space opens it.
        #expect(Self.inbox.ordered.last?.id == "N-1" && !harness.review.isOpen)
        try Self.pressSpace(in: window)
        try await Self.settle(window, for: .milliseconds(200))
        #expect(harness.review.selectedID == "N-1")
        // Nothing was decided or sent from the row.
        #expect(harness.decided.isEmpty && harness.replied.isEmpty)
    }

    @Test func aRowThatLeftGivesTheKeyboardToTheFirstRow() async throws {
        let harness = NeedsYouReviewHarness()
        let window = try await Self.host(harness, width: 700)
        defer { window.close() }
        harness.review.open("gone")
        harness.review.isSettled = true
        try await Self.settle(window)
        harness.review.close(rows: Self.inbox.ordered.map(\.id))
        try await Self.settle(window, for: .milliseconds(700))
        try Self.pressSpace(in: window)
        try await Self.settle(window, for: .milliseconds(200))
        #expect(harness.review.selectedID == Self.inbox.ordered.first?.id)
    }
}
