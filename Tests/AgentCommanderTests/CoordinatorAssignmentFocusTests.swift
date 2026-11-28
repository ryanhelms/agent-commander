import AppKit
import Testing
@testable import AgentCommander

/// The assignment button returns keyboard focus to where it was before the press. A click moves
/// the first responder to the hosting view on mouse-down, so each test replays that order.
@Suite @MainActor struct CoordinatorAssignmentFocusTests {
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A window with a "terminal" and the "hosting view" a click on the button moves focus to.
    private func fixture() -> (window: NSWindow, terminal: NSView, host: NSView, focus: CoordinatorAssignmentButton.FocusReturn) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = FocusableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let terminal = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(terminal)
        window.contentView = host
        let focus = CoordinatorAssignmentButton.FocusReturn()
        focus.window = window
        return (window, terminal, host, focus)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test func clickReturnsFocusHeldBeforeTheMouseWentDown() async {
        let (window, terminal, host, focus) = fixture()
        #expect(window.makeFirstResponder(terminal))

        focus.notePress(in: window)                 // mouse-down, before dispatch
        #expect(window.makeFirstResponder(host))    // AppKit moves focus to the hosting view
        focus.capture(trigger: .leftMouseUp)        // the button's action
        focus.restore()
        await settle()

        #expect(window.firstResponder === terminal)
    }

    @Test func keyPressLeavesFocusWhereItIs() async {
        let (window, terminal, host, focus) = fixture()
        #expect(window.makeFirstResponder(terminal))
        #expect(window.makeFirstResponder(host))

        focus.capture(trigger: .keyDown)
        focus.restore()
        await settle()

        #expect(window.firstResponder === host)
    }

    @Test func keyPressIgnoresAnEarlierMouseDown() async {
        let (window, terminal, host, focus) = fixture()
        #expect(window.makeFirstResponder(terminal))
        focus.notePress(in: window)
        #expect(window.makeFirstResponder(host))

        focus.capture(trigger: .keyDown)
        focus.restore()
        await settle()

        #expect(window.firstResponder === host)
    }

    @Test func abandonedPressIsNotUsedByALaterClick() async {
        let (window, terminal, host, focus) = fixture()
        #expect(window.makeFirstResponder(terminal))
        focus.notePress(in: window)
        focus.abandonPress()
        #expect(window.makeFirstResponder(host))

        focus.capture(trigger: .leftMouseUp)
        focus.restore()
        await settle()

        #expect(window.firstResponder === host)
    }

    @Test func focusMovedWhileTheSheetWasOpenIsPutBack() async {
        let (window, terminal, host, focus) = fixture()
        #expect(window.makeFirstResponder(terminal))

        focus.capture(trigger: .keyDown)
        #expect(window.makeFirstResponder(host))
        focus.restore()
        await settle()

        #expect(window.firstResponder === terminal)
    }

    @Test func focusIsNotReturnedToAViewThatLeftTheWindow() async {
        let (window, terminal, host, focus) = fixture()
        #expect(window.makeFirstResponder(terminal))
        focus.notePress(in: window)
        #expect(window.makeFirstResponder(host))
        focus.capture(trigger: .leftMouseUp)
        terminal.removeFromSuperview()
        focus.restore()
        await settle()

        #expect(window.firstResponder !== terminal)
    }

    @Test func editedFieldIsReturnedWithItsCaret() async {
        let (window, _, host, focus) = fixture()
        let field = NSTextField(string: "retry the build")
        field.frame = NSRect(x: 100, y: 0, width: 100, height: 22)
        host.addSubview(field)
        #expect(window.makeFirstResponder(field))
        field.currentEditor()?.selectedRange = NSRange(location: 5, length: 0)

        focus.notePress(in: window)
        #expect(window.makeFirstResponder(host))    // editing ends; the editor loses its field
        focus.capture(trigger: .leftMouseUp)
        focus.restore()
        await settle()

        #expect(field.currentEditor() != nil)
        #expect(window.firstResponder === field.currentEditor())
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 5, length: 0))
    }
}
