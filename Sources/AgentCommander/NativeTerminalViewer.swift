import Foundation
import Observation

// NATIVE TERMINAL VIEWER — values and feature models
// Read-only views onto a local worker's live tmux session. They watch; they never type.
//
//   Values          NativeTerminalTarget    the worker a viewer is for, with its eligibility facts
//                   NativeTerminalLaunch    the bundled agentctl and its literal arguments
//                   NativeTerminalFeed      what a well draws: agentctl's output, or fixture bytes
//                   NativeTerminalPhase     what the standalone window is doing
//                   NativeTerminalBlock     why inline viewports for a worker show the transcript
//   Feature models  NativeTerminalViewerModel  the standalone window's attachment and generations
//                   NativeTerminalLedger       inline status per worker: detached, ended, retry
//   AppKit leaf     NativeTerminalWell      (NativeTerminalWell.swift)
//   Components      status, menu items, viewport, window organism and scene
//                   (NativeTerminalComponents.swift)
//
// Local and SSH workers are both candidates: the managed tmux runner lives on this Mac either way,
// and the service resolves (or refuses) a worker's terminal. An unmanaged worker, or one whose tmux
// session is missing, ends its attachment and keeps its transcript.
//
// The app does not look up tmux sockets, sessions or panes. Each visible viewport starts its own
// bundled agentctl, which asks the service for the worker's terminal and supervises that viewer's
// two tmux clients (the read-only viewer and an unsized control client that keeps the window's
// geometry). Concurrent viewports of one worker are independent, size-neutral attachments; a
// viewport that leaves the screen ends its own. Every byte a terminal view would send back is
// dropped, so neither keys, paste, mouse reports nor terminal query replies can reach tmux and
// change the session it shows.

/// The worker a viewer is for. Also the standalone window's value: opening the same worker again
/// brings its window forward, whatever its live state was when the window opened.
struct NativeTerminalTarget: Codable, Hashable, Sendable {
    let workerID: String
    let workerName: String
    /// The service's host name for the worker.
    let host: String
    /// The harness display name, reconstructed into `AgentClient` for the console surface.
    let clientName: String
    /// Where the harness runs, for the title bar's platform mark. It is a label, not a gate: the
    /// managed tmux runner is on this Mac for local and SSH workers alike, and the service decides
    /// whether a worker has one.
    let hostKind: NativeTerminalHostKind
    /// The worker's turn state allows a live terminal: started, and not stopped, finished, failed
    /// or disconnected.
    var isLive: Bool = true

    var client: AgentClient { AgentClient(clientName) }
    var platform: HostPlatform { hostKind.platform }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.workerID == rhs.workerID }
    func hash(into hasher: inout Hasher) { hasher.combine(workerID) }
}

/// `HostPlatform` as a window value can carry it.
enum NativeTerminalHostKind: String, Codable, Sendable {
    case localMac, remoteMac, remoteLinux, unknown

    init(_ platform: HostPlatform) {
        switch platform {
        case .localMac: self = .localMac
        case .remoteMac: self = .remoteMac
        case .remoteLinux: self = .remoteLinux
        case .unknown: self = .unknown
        }
    }

    var platform: HostPlatform {
        switch self {
        case .localMac: .localMac
        case .remoteMac: .remoteMac
        case .remoteLinux: .remoteLinux
        case .unknown: .unknown
        }
    }
}

extension NativeTerminalTarget {
    init(worker: WorkerPresentation) {
        self.init(workerID: worker.id, workerName: worker.name, host: worker.host,
                  clientName: worker.client.displayName, hostKind: NativeTerminalHostKind(worker.platform),
                  isLive: worker.state.allowsLiveTerminal)
    }

    /// The asking worker of a PiP request.
    init(request: RequestPresentation) {
        self.init(workerID: request.workerID, workerName: request.workerName, host: request.host,
                  clientName: request.client.displayName, hostKind: NativeTerminalHostKind(request.platform),
                  isLive: request.workerState.allowsLiveTerminal)
    }
}

extension TaskState {
    /// States in which the worker's managed terminal is expected to exist. A worker that is still
    /// starting may not have its runner yet, so it shows its transcript until it is running rather
    /// than recording a failed attachment. A stopped, finished, failed, disconnected or unreported
    /// worker shows its recorded transcript.
    var allowsLiveTerminal: Bool {
        switch self {
        case .running, .working, .idle, .needsInput: true
        case .starting, .stopping, .completed, .failed, .stopped, .disconnected, .unknown: false
        }
    }
}

/// The one process a viewer may start: the agentctl bundled inside this app, with literal arguments.
struct NativeTerminalLaunch: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String]

    /// The agentctl inside this app bundle. No environment override and no search path: a viewer
    /// started from a development build without a bundle has no agentctl and says so.
    static func bundledAgentctl(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        guard bundle.bundleURL.pathExtension == "app",
              let url = bundle.url(forAuxiliaryExecutable: "agentctl")?.standardizedFileURL,
              url.path.hasPrefix(bundle.bundleURL.standardizedFileURL.path + "/"),
              fileManager.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The fixed argument list. The worker ID is passed as one argument, never through a shell.
    static func arguments(for target: NativeTerminalTarget) -> [String] {
        ["terminal", "observe", target.workerID]
    }

    /// The app's environment for the service socket settings, without a parent tmux, with a
    /// terminal type SwiftTerm renders and a UTF-8 locale so tmux draws box characters.
    /// With a headless host selected, the socket is that host's forwarded one.
    static func environment(from base: [String: String] = ProcessInfo.processInfo.environment,
                            endpoint: ServiceEndpoint = .live) -> [String] {
        var values = endpoint.agentctlEnvironment(from: base)
        // The app accepts AC_SOCKET as an alias (ServiceClient); agentctl reads only the full name.
        // Hand agentctl the socket the app itself uses.
        if values["AGENT_COMMANDER_SOCKET"] == nil, let alias = values["AC_SOCKET"] {
            values["AGENT_COMMANDER_SOCKET"] = alias
        }
        values.removeValue(forKey: "TMUX")
        values.removeValue(forKey: "TMUX_PANE")
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        if values["LC_ALL"] == nil, values["LC_CTYPE"] == nil, values["LANG"] == nil {
            values["LANG"] = "en_US.UTF-8"
        }
        return values.map { "\($0.key)=\($0.value)" }.sorted()
    }

    static func make(for target: NativeTerminalTarget, agentctl: URL?) -> NativeTerminalLaunch? {
        guard let agentctl else { return nil }
        return NativeTerminalLaunch(executable: agentctl, arguments: arguments(for: target), environment: environment())
    }
}

/// What a well draws. A fixture feed starts no process and exists only for design previews.
enum NativeTerminalFeed: Equatable, Sendable {
    case process(NativeTerminalLaunch)
    /// FIXTURE ONLY. Bytes written into the well once, as if a terminal had printed them.
    case fixture(String)
}

/// What the standalone viewer window is doing.
enum NativeTerminalPhase: Equatable {
    /// No viewer can start for this worker or this build. The reason is a full sentence.
    case unsupported(String)
    /// agentctl is running: attaching, or attached and mirroring the session.
    case observing
    /// The developer detached. The worker and its tmux session keep running.
    case detached
    /// agentctl exited on its own. A non-zero code means it could not attach or stay attached,
    /// and its own message is printed in the well above the notice.
    case ended(exitCode: Int32?)

    var isObserving: Bool { self == .observing }
    var canReconnect: Bool {
        switch self {
        case .detached, .ended: true
        case .unsupported, .observing: false
        }
    }
}

/// The standalone window. Each attachment is a generation; reconnecting starts a new one, and an
/// exit reported by an earlier generation is ignored.
@Observable @MainActor
final class NativeTerminalViewerModel {
    let target: NativeTerminalTarget
    let launch: NativeTerminalLaunch?
    private(set) var phase: NativeTerminalPhase
    private(set) var generation = 0

    init(target: NativeTerminalTarget, agentctl: URL? = NativeTerminalLaunch.bundledAgentctl()) {
        self.target = target
        let launch = NativeTerminalLaunch.make(for: target, agentctl: agentctl)
        self.launch = launch
        if launch == nil {
            phase = .unsupported(NativeTerminalLedger.noAgentctlReason(target.workerName))
        } else {
            phase = .observing
        }
    }

    /// Ends this window's agentctl, which detaches both of its tmux clients. The worker and the
    /// tmux server are not touched.
    func detach() {
        guard phase.isObserving else { return }
        phase = .detached
    }

    func reconnect() {
        guard phase.canReconnect, launch != nil else { return }
        generation += 1
        phase = .observing
    }

    func processEnded(generation ended: Int, exitCode: Int32?) {
        guard ended == generation, phase.isObserving else { return }
        phase = .ended(exitCode: exitCode)
    }
}

/// Why the inline viewports of a worker show its transcript instead of the terminal.
enum NativeTerminalBlock: Equatable {
    /// The developer detached. Nothing reattaches until they reconnect.
    case detached
    /// An attachment ended on its own: agentctl could not attach, the service was unavailable, or
    /// the session closed. `message` is the last line agentctl printed.
    case ended(exitCode: Int32?, message: String?)

    /// A sentence for help tags and the menu.
    func statement(workerName: String) -> String {
        switch self {
        case .detached:
            return "Terminal detached. \(workerName) keeps running; its transcript is shown. Reconnect to watch the terminal."
        case .ended(let code, let message):
            let reason = (message?.isEmpty == false ? message! + ". " : "")
            if code == 0 {
                return "The terminal for \(workerName) closed. \(reason)Its transcript is shown. Retry to attach again."
            }
            return "The terminal for \(workerName) could not attach" + (code.map { " (exit \($0))" } ?? "")
                + ". \(reason)Its transcript is shown. Check that the Commander service is running, then retry."
        }
    }
}

/// Inline terminal status for every console of one launch. It holds no process and no view: each
/// visible viewport owns its own attachment. It records only what must outlive a viewport, so a
/// failed or detached worker does not attach again whenever a tile, the focused view or the PiP
/// reappears. Only an explicit reconnect clears a block, which is what prevents a retry storm.
@Observable @MainActor
final class NativeTerminalLedger {
    enum Source: Equatable {
        /// The packaged app: attach with the bundled agentctl.
        case live(URL)
        /// FIXTURE ONLY. Design previews draw sample terminal output and start no process.
        case fixture
        /// No inline terminal in this launch. Consoles keep their transcript.
        case unavailable(String)
    }

    let source: Source
    private(set) var blocks: [String: NativeTerminalBlock] = [:]
    private var generations: [String: Int] = [:]

    init(source: Source) {
        self.source = source
    }

    /// The live app attaches through the bundled agentctl. A design preview shows sample terminal
    /// output only when it is asked to start in Terminal mode, and otherwise none.
    static func forLaunch() -> NativeTerminalLedger {
        if DesignPreviewScenario.requested != nil || MultiplayerLaunch.showsPanelInWindow {
            return NativeTerminalLedger(source: ConversationFixture.display == .terminal
                ? .fixture : .unavailable("Design previews do not attach terminals."))
        }
        if let agentctl = NativeTerminalLaunch.bundledAgentctl() { return NativeTerminalLedger(source: .live(agentctl)) }
        return NativeTerminalLedger(source: .unavailable(noAgentctlReason(nil)))
    }

    static func noAgentctlReason(_ workerName: String?) -> String {
        "This build of Agent Commander has no bundled agentctl, so it cannot open a native terminal. "
            + "Open the built Agent Commander app" + (workerName.map { " to watch \($0)." } ?? ".")
    }

    var isAvailable: Bool {
        if case .unavailable = source { false } else { true }
    }

    /// The worker is a candidate for an inline terminal: live, and this launch can attach. Whether
    /// it has a managed tmux runner is the service's answer; without one the attachment ends, the
    /// worker is recorded as ended, and its consoles keep the transcript.
    func isEligible(_ target: NativeTerminalTarget) -> Bool {
        isAvailable && target.isLive
    }

    /// An eligible worker with no block. Viewports for it attach.
    func shouldAttach(_ target: NativeTerminalTarget) -> Bool {
        isEligible(target) && blocks[target.workerID] == nil
    }

    func block(for workerID: String) -> NativeTerminalBlock? { blocks[workerID] }

    /// Changes only on reconnect, so a viewport's identity, and its attachment, survive every
    /// AG-UI update to the worker.
    func generation(for workerID: String) -> Int { generations[workerID, default: 0] }

    func feed(for target: NativeTerminalTarget) -> NativeTerminalFeed? {
        switch source {
        case .live(let agentctl):
            NativeTerminalLaunch.make(for: target, agentctl: agentctl).map(NativeTerminalFeed.process)
        case .fixture:
            .fixture(NativeTerminalFixture.screen(for: target))
        case .unavailable:
            nil
        }
    }

    /// Ends every inline attachment for the worker. Its consoles show the transcript.
    func detach(_ workerID: String) {
        blocks[workerID] = .detached
    }

    /// Clears the block and gives the worker's viewports a new identity, so each attaches once.
    func reconnect(_ workerID: String) {
        guard blocks[workerID] != nil else { return }
        blocks[workerID] = nil
        generations[workerID, default: 0] += 1
    }

    /// An attachment of the current generation ended by itself. Earlier generations are ignored.
    func attachmentEnded(_ workerID: String, generation: Int, exitCode: Int32?, message: String?) {
        guard generation == self.generation(for: workerID), blocks[workerID] == nil else { return }
        blocks[workerID] = .ended(exitCode: exitCode, message: message)
    }
}

/// FIXTURE ONLY. A terminal screen for design previews of the inline terminal, labelled as a sample.
enum NativeTerminalFixture {
    static func screen(for target: NativeTerminalTarget) -> String {
        let esc = "\u{1B}["
        return [
            "\(esc)2m[fixture · design preview · no process attached]\(esc)0m",
            "\(target.workerName) · worker",
            "",
            "\(esc)36m$\(esc)0m go test ./transport -run TestPartialResponse",
            "  \(esc)32mPASS\(esc)0m  disconnect before body permits replay",
            "  \(esc)32mPASS\(esc)0m  a delivered body prevents duplicate bytes",
            "",
            "2 checks passed. Waiting for the integration decision.",
        ].joined(separator: "\r\n") + "\r\n"
    }
}
