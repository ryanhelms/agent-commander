import Foundation
import Observation

// NATIVE TERMINAL VIEWER — values and feature model
// A read-only window onto one local worker's live tmux session. It watches; it never types.
//
//   Values          NativeTerminalTarget    the worker a viewer window is opened for
//                   NativeTerminalLaunch    the bundled agentctl and its literal arguments
//                   NativeTerminalPhase     what the viewer is doing, in words the header can show
//   Feature model   NativeTerminalViewerModel  one window's attachment and its generations
//   AppKit leaf     NativeTerminalWell      (NativeTerminalWell.swift)
//   Components      header, menu items, organism, page, scene (NativeTerminalComponents.swift)
//
// The app does not look up tmux sockets, sessions or panes. The bundled agentctl asks the service
// for the worker's terminal and supervises the viewer's two tmux clients (the read-only viewer and
// an unsized control client that keeps the window's geometry); any error it reports is printed in
// the well. Every byte the terminal view would send back is dropped, so neither keys, paste,
// mouse reports nor terminal query replies can reach tmux and change the session it shows.

/// The worker a viewer is opened for. A window value: opening the same worker again brings its
/// existing window forward rather than starting a second attachment.
struct NativeTerminalTarget: Codable, Hashable, Sendable {
    let workerID: String
    let workerName: String
    /// The service's host name for the worker.
    let host: String
    /// The harness display name, reconstructed into `AgentClient` for the console surface.
    let clientName: String
    /// True only when the service reported the worker on this Mac.
    let isLocal: Bool

    var client: AgentClient { AgentClient(clientName) }
}

extension NativeTerminalTarget {
    init(worker: WorkerPresentation) {
        self.init(workerID: worker.id, workerName: worker.name, host: worker.host,
                  clientName: worker.client.displayName, isLocal: worker.platform == .localMac)
    }

    /// Why this worker has no native viewer, or nil when it can have one.
    var unsupportedReason: String? {
        isLocal ? nil : "The native terminal viewer is available only for workers running on this Mac. "
            + "\(workerName) runs on \(host)."
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
    static func environment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var values = base
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

/// What the viewer is doing.
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

/// One viewer window. Each attachment is a generation; reconnecting starts a new one, and an exit
/// reported by an earlier generation is ignored.
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
        if let reason = target.unsupportedReason {
            phase = .unsupported(reason)
        } else if launch == nil {
            phase = .unsupported("This build of Agent Commander has no bundled agentctl, so it cannot open a "
                + "native terminal. Open the built Agent Commander app to watch \(target.workerName).")
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
