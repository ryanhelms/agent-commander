import AppKit
@preconcurrency import SwiftTerm
import SwiftUI

// NATIVE TERMINAL WELL — the AppKit leaf of the native terminal viewer
// SwiftTerm's LocalProcessTerminalView runs the bundled agentctl in a pseudo-terminal and draws
// what tmux sends. From SwiftUI this is one composable leaf, like the console's terminal well.
//
// Monitoring only. LocalProcessTerminalView is its own TerminalViewDelegate and would write keys,
// paste, mouse reports and terminal query replies to the process. `NativeTerminalInputGuard`
// replaces that delegate: it forwards only the window size, and drops every outgoing byte, the
// remote clipboard (OSC 52) in both directions, link activation, the bell and remote titles. A
// read-only tmux client still honours its detach and switch-client keys, so dropping all input is
// what keeps the selected session fixed. Local selection and ⌘C copy stay with the view.

/// The delegate the observing view uses instead of its own. Only window size reaches the process.
@MainActor
final class NativeTerminalInputGuard: @preconcurrency TerminalViewDelegate {
    weak var view: LocalProcessTerminalView?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Sets the pseudo-terminal size so the tmux client draws to the visible grid. The client is
        // attached with ignore-size, so this never resizes the worker's own window.
        view?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    /// Keys, paste, mouse reports and replies to terminal queries. None are sent.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}

    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    /// The header names the worker; a title set by the remote program is not shown.
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
    private var hasStopped = false
    var onExit: ((Int32?) -> Void)?

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
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nativeBackgroundColor = NSColor(Term.background)
        nativeForegroundColor = NSColor(Term.text)
        selectedTextBackgroundColor = NSColor(Palette.selection)
        caretColor = NSColor(Term.dim)
        setAccessibilityLabel("Read-only terminal")
        setAccessibilityHelp("Mirrors the worker's terminal. Typing and paste are not sent.")
    }

    func start(_ launch: NativeTerminalLaunch) {
        startProcess(executable: launch.executable.path, args: launch.arguments,
                     environment: launch.environment, execName: nil,
                     currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Ends this viewer's agentctl and with it both tmux clients. Safe to call more than once.
    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        onExit = nil
        if process.running { terminate() }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard !hasStopped else { return }
        hasStopped = true
        let report = onExit
        onExit = nil
        report?(exitCode)
    }

    /// The default context menu offers Paste; a viewer has nothing to paste into.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// SwiftUI leaf. One instance is one attachment: the page gives it a new identity to reconnect.
struct NativeTerminalWell: NSViewRepresentable {
    let launch: NativeTerminalLaunch
    /// False after the developer detaches. The last screen stays visible.
    let isLive: Bool
    let onExit: (Int32?) -> Void

    func makeNSView(context: Context) -> NativeTerminalObserverView {
        let view = NativeTerminalObserverView(frame: .zero)
        view.onExit = onExit
        if isLive { view.start(launch) }
        return view
    }

    func updateNSView(_ view: NativeTerminalObserverView, context: Context) {
        if isLive {
            view.onExit = onExit
        } else {
            view.stop()
        }
    }

    static func dismantleNSView(_ view: NativeTerminalObserverView, coordinator: ()) {
        view.stop()
    }
}
