import AppKit
@preconcurrency import SwiftTerm
import SwiftUI

// HARNESS TERMINAL — the terminal a sign-in or install runs in.
//
// The service starts the harness's own command in a dedicated tmux session and returns its
// socket and session (design/HARNESSES.md). This well attaches one tmux client to that session.
// Unlike the worker viewer (NativeTerminalWell.swift), which only watches, this terminal takes the
// keyboard: a sign-in asks for a choice, a pasted code or Return. What is typed goes to tmux and
// from there to the harness; Agent Commander reads none of it and stores nothing.
//
//   Values     HarnessTerminalLaunch   tmux and its literal arguments for one attachment
//   AppKit     HarnessTerminalView     SwiftTerm's LocalProcessTerminalView in the console's colours
//   Leaf       HarnessTerminalWell     one attachment; reports when the client exits
//   Organism   HarnessSessionSheet     title, command, the well, and Close
//
// The worker viewer, the console and the pretty view are not changed by anything here.

enum HarnessTerminalLaunch {
    /// Where tmux is usually installed, then the folders on PATH.
    static func tmux(environment: [String: String] = ProcessInfo.processInfo.environment,
                     fileManager: FileManager = .default) -> URL? {
        let usual = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin"]
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (usual + path).map { URL(filePath: $0).appending(path: "tmux") }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// The fixed argument list. The socket and session are passed as arguments, never through a shell.
    static func arguments(for attachment: HarnessAttachment) -> [String] {
        ["-S", attachment.socketPath, "attach-session", "-t", attachment.sessionID]
    }

    /// The feed for one attachment. Nil when this Mac has no tmux the app can find.
    static func feed(for session: HarnessSession) -> NativeTerminalFeed? {
        if let fixture = session.fixture { return .fixture(fixture) }
        guard let tmux = tmux() else { return nil }
        return .process(NativeTerminalLaunch(executable: tmux, arguments: arguments(for: session.attachment),
                                             environment: NativeTerminalLaunch.environment()))
    }

    /// The same attachment as a command for Terminal, when the app can't run it itself.
    static func command(for attachment: HarnessAttachment) -> String {
        "tmux -S '\(attachment.socketPath)' attach-session -t '\(attachment.sessionID)'"
    }
}

/// An interactive terminal for one tmux client. Stopping it ends the client only: the session and
/// the command in it keep running until the command exits.
final class HarnessTerminalView: LocalProcessTerminalView {
    private var hasStarted = false
    private var hasStopped = false
    /// Called once when the client ends by itself, with its exit code and the last line it printed.
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
        nativeBackgroundColor = NSColor(Term.background)
        nativeForegroundColor = NSColor(Term.text)
        selectedTextBackgroundColor = NSColor(Palette.selection)
        caretColor = NSColor(Term.text)
        font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }

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

    private func lastPrintedLine() -> String? {
        let terminal = getTerminal()
        for row in stride(from: terminal.rows - 1, through: 0, by: -1) {
            let text = terminal.getLine(row: row)?.translateToString(trimRight: true)
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !text.isEmpty { return String(text.prefix(240)) }
        }
        return nil
    }
}

/// SwiftUI leaf. One instance is one tmux client. It takes the keyboard when it appears.
struct HarnessTerminalWell: NSViewRepresentable {
    let feed: NativeTerminalFeed
    let label: String
    let onExit: (_ exitCode: Int32?, _ lastLine: String?) -> Void

    func makeNSView(context: Context) -> HarnessTerminalView {
        let view = HarnessTerminalView(frame: .zero)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp("What you type goes to the harness’s own command. Agent Commander stores none of it.")
        view.onExit = onExit
        view.begin(feed)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: HarnessTerminalView, context: Context) {
        view.onExit = onExit
    }

    static func dismantleNSView(_ view: HarnessTerminalView, coordinator: ()) {
        view.stop()
    }
}

/// The sheet a sign-in or install runs in: what it is, the command, its terminal, and Close.
/// When the terminal's client ends, `ended` is called and the caller puts the sheet away.
struct HarnessSessionSheet: View {
    let session: HarnessSession
    let ended: (_ exitCode: Int32?, _ lastLine: String?) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.m) {
                IconTile(symbol: session.purpose == .login ? "person.badge.key" : "arrow.down.square", tone: .focus, size: 31)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).themeType(theme.type.title).foregroundStyle(.theme(\.color.foreground))
                        .accessibilityAddTraits(.isHeader)
                    if !session.command.isEmpty {
                        Text(session.command).themeType(theme.type.mono).foregroundStyle(.theme(\.color.secondary))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                Spacer(minLength: Space.m)
                MultiplayerStateLabel(lamp: .on, text: "Running", tone: .working, pulses: true)
            }
            .padding(.horizontal, theme.space.sectionInset)
            .frame(minHeight: 52)
            ThemeRule()
            terminal
            ThemeRule()
            HStack(spacing: Space.m) {
                Text(session.purpose == .login
                     ? "This is \(session.harnessName)’s own sign-in. What you type goes to it; Agent Commander stores nothing. The sheet closes when it finishes."
                     : "This is \(session.harnessName)’s own install command. The sheet closes when it finishes.")
                    .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.m)
                Button("Close") { ended(nil, nil) }
                    .buttonStyle(ThemeButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Close this sheet. The command keeps running until it finishes.")
                    .accessibilityIdentifier("harness-session-close")
            }
            .padding(.horizontal, theme.space.sectionInset)
            .padding(.vertical, Space.m)
            .background(theme.surface.footerFill.color)
        }
        .frame(width: 780)
        .background(theme.surface.panelFill.style)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.title)
    }

    @ViewBuilder private var terminal: some View {
        if let feed = HarnessTerminalLaunch.feed(for: session) {
            HarnessTerminalWell(feed: feed, label: "\(session.title), terminal", onExit: ended)
                .padding(.horizontal, Space.s).padding(.vertical, Space.s)
                .frame(height: 440)
                .background(Term.background)
                .id(session.id)
        } else {
            // No tmux the app can run: say so, and give the same attachment as a command.
            VStack(alignment: .leading, spacing: Space.m) {
                ShellNote(text: "Agent Commander couldn’t find tmux on this Mac to show the terminal. Run this in Terminal to continue.",
                          lamp: .error)
                Text(HarnessTerminalLaunch.command(for: session.attachment))
                    .themeType(theme.type.mono).foregroundStyle(.theme(\.color.foreground))
                    .textSelection(.enabled)
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themeField()
                    .padding(.horizontal, Space.m)
            }
            .padding(.vertical, Space.m)
            .frame(height: 440, alignment: .topLeading)
        }
    }
}
