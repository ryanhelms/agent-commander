import AppKit
@preconcurrency import SwiftTerm
import SwiftUI

// NATIVE TERMINAL WELL — the AppKit leaf of every native terminal viewport
// SwiftTerm's LocalProcessTerminalView runs the bundled agentctl in a pseudo-terminal and draws
// what tmux sends. From SwiftUI this is one composable leaf, like the console's terminal well. The
// standalone window, the wall tile, the focused worker, the coordinator and the PiP each place
// their own instance; an instance is never moved between presentations.
//
// Monitoring only. LocalProcessTerminalView is its own TerminalViewDelegate and would write keys,
// paste, mouse reports and terminal query replies to the process. `NativeTerminalInputGuard`
// replaces that delegate: it forwards only the window size, and drops every outgoing byte, the
// remote clipboard (OSC 52) in both directions, link activation, the bell and remote titles. A
// read-only tmux client still honours its detach and switch-client keys, so dropping all input is
// what keeps the selected session fixed.
//
// Key chords stay with the app. The view never interprets a key: keyDown goes on up the responder
// chain, so cockpit shortcuts and focus keys work while the terminal has focus. ⌘C copies a local
// selection; Paste does nothing. The wheel scrolls the terminal's own scrollback when it has one,
// and otherwise the surface around it, because tmux draws on the alternate screen.

/// The delegate the observing view uses instead of its own. Only window size reaches the process.
@MainActor
final class NativeTerminalInputGuard: @preconcurrency TerminalViewDelegate {
    weak var view: LocalProcessTerminalView?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Sets this viewer's pseudo-terminal size so its tmux client draws to the visible grid.
        // agentctl attaches size-neutrally, so this never resizes the worker's own window.
        view?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    /// Keys, paste, mouse reports and replies to terminal queries. None are sent.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}

    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    /// The console title bar names the worker; a title set by the remote program is not shown.
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A LocalProcessTerminalView that only observes. Stopping it sends SIGTERM to the agentctl process
/// and closes the pseudo-terminal. agentctl supervises the viewer's two tmux clients and detaches
/// both when it ends; the tmux server, the worker's session and the worker keep running.
final class NativeTerminalObserverView: LocalProcessTerminalView {
    private let inputGuard = NativeTerminalInputGuard()
    private var hasStarted = false
    private var hasStopped = false
    /// Called once when the process ends by itself, with its exit code and the last line it printed.
    var onExit: ((Int32?, String?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        inputGuard.view = self
        terminalDelegate = inputGuard
        // Mouse drags select text here instead of being reported to the program, and nothing in
        // the output becomes a clickable link.
        allowMouseReporting = false
        linkReporting = .none
        nativeBackgroundColor = NSColor(Term.background)
        nativeForegroundColor = NSColor(Term.text)
        selectedTextBackgroundColor = NSColor(Palette.selection)
        caretColor = NSColor(Term.dim)
        setFontSize(12)
    }

    func setFontSize(_ size: CGFloat) {
        guard font.pointSize != size else { return }
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func describe(workerName: String) {
        setAccessibilityLabel("Read-only terminal, \(workerName)")
        setAccessibilityHelp("Mirrors \(workerName)'s terminal. Typing and paste are not sent. Select text and press Command-C to copy.")
    }

    /// Starts the feed once. A fixture feed writes its bytes and starts no process.
    func begin(_ source: NativeTerminalFeed) {
        guard !hasStarted else { return }
        hasStarted = true
        switch source {
        case .process(let launch):
            startProcess(executable: launch.executable.path, args: launch.arguments,
                         environment: launch.environment, execName: nil,
                         currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        case .fixture(let text):
            feed(text: text)
        }
    }

    /// Ends this viewer's agentctl and with it both tmux clients. Safe to call more than once.
    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        onExit = nil
        if hasStarted, process.running { terminate() }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard !hasStopped else { return }
        hasStopped = true
        let report = onExit
        onExit = nil
        report?(exitCode, lastPrintedLine())
    }

    /// The last non-blank line on screen: agentctl's own error, when it could not attach.
    private func lastPrintedLine() -> String? {
        let terminal = getTerminal()
        for row in stride(from: terminal.rows - 1, through: 0, by: -1) {
            let text = terminal.getLine(row: row)?.translateToString(trimRight: true)
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !text.isEmpty { return String(text.prefix(240)) }
        }
        return nil
    }

    // MARK: Input isolation (keyDown and scrollWheel are public, not open, in SwiftTerm; the
    // container below handles them)

    /// The default context menu offers Paste; a viewer has nothing to paste into.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func paste(_ sender: Any) {}
}

/// Holds one observer view and keeps keys and the wheel with the app.
///
/// Keys: while the terminal has keyboard focus, a local monitor takes each key before SwiftTerm
/// sees it. Tab and Shift-Tab move focus on, and other plain keys go up the responder chain from
/// this container. A key with Command is left alone, so menu shortcuts, ⌘C on a selection and
/// ⌘W work as everywhere else.
/// Wheel: the terminal is hit only when it has scrollback of its own; otherwise the container
/// takes the event and passes it to the surface around it, so a wall of terminals still scrolls.
final class NativeTerminalContainerView: NSView {
    let terminal = NativeTerminalObserverView(frame: .zero)
    private var keyMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .scrollWheel, !terminal.canScroll { return self }
        return hit
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeKeyMonitor()
        } else if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                // Local monitors run on the main thread. Only a Bool crosses the isolation boundary.
                nonisolated(unsafe) let key = event
                let passThrough = MainActor.assumeIsolated { self.route(key) }
                return passThrough ? event : nil
            }
        }
    }

    /// Handles a key aimed at the terminal. Returns true to let AppKit deliver the event as usual.
    private func route(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.firstResponder === terminal else { return true }
        if event.modifierFlags.contains(.command) { return true }
        if event.keyCode == 48 {   // Tab
            if event.modifierFlags.contains(.shift) {
                window.selectKeyView(preceding: terminal)
            } else {
                window.selectKeyView(following: terminal)
            }
            return false
        }
        nextResponder?.keyDown(with: event)
        return false
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func stop() {
        removeKeyMonitor()
        terminal.stop()
    }
}

/// SwiftUI leaf. One instance is one attachment; a viewport gives it a new identity to reconnect.
/// SwiftUI keeps the instance while the surface stays on screen, so worker updates never reattach.
struct NativeTerminalWell: NSViewRepresentable {
    let feed: NativeTerminalFeed
    /// False after the developer detaches the standalone window. The last screen stays visible.
    var isLive = true
    var fontSize: CGFloat = 12
    var workerName = ""
    let onExit: (_ exitCode: Int32?, _ lastLine: String?) -> Void

    func makeNSView(context: Context) -> NativeTerminalContainerView {
        let view = NativeTerminalContainerView(frame: .zero)
        view.terminal.setFontSize(fontSize)
        view.terminal.describe(workerName: workerName)
        view.terminal.onExit = onExit
        if isLive { view.terminal.begin(feed) }
        return view
    }

    func updateNSView(_ view: NativeTerminalContainerView, context: Context) {
        view.terminal.setFontSize(fontSize)
        if isLive {
            view.terminal.onExit = onExit
        } else {
            view.terminal.stop()
        }
    }

    static func dismantleNSView(_ view: NativeTerminalContainerView, coordinator: ()) {
        view.stop()
    }
}
