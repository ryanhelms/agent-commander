import AppKit
import Foundation
import Observation

// Headless Commander hosts: the feature layer.
//
//   CommanderHost          one host `agentctl host list` knows, as sent
//   HostConnectEvent       one line `agentctl host connect` writes
//   HostLink               the connection to the chosen host: connecting, connected, disconnected, failed
//   CommanderHostsService  the two agentctl calls, as closures, so the model runs without a process
//   CommanderHostsModel    owns the list, the one connect process, the connection state and the
//                          choice. It is the only writer of `ServiceEndpoint`.
//   CommanderHostEntry     what the Hosts page draws for one host: values only
//
// The app talks to one service at a time. Choosing a host starts `agentctl host connect`; when it
// says `ready` the endpoint moves to the forwarded socket and every client path follows. Choosing
// This Mac ends the process and moves the endpoint back. See design/HEADLESS-COMMANDER.md,
// "Connecting the Mac to a headless Commander".

/// One headless host from `agentctl host list`.
struct CommanderHost: Decodable, Identifiable, Equatable, Sendable {
    let destination: String
    var options: [String]? = nil
    var version: String? = nil
    var api: Int? = nil
    /// When the host was last deployed, as an ISO 8601 time.
    var updated: String? = nil

    var id: String { destination }

    /// The list as agentctl prints it. Nothing printed, or `null`, is an empty list.
    static func list(json data: Data) throws -> [CommanderHost] {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "null" { return [] }
        return try JSONDecoder().decode([CommanderHost].self, from: Data(text.utf8))
    }
}

/// One event line from `agentctl host connect`.
enum HostConnectEvent: Equatable, Sendable {
    /// The forwarded socket answers.
    case ready(destination: String, socket: String, version: String?, api: Int?)
    /// SSH dropped. agentctl keeps retrying and sends `ready` again.
    case disconnected(destination: String, detail: String)
    /// The host can't be used (an incompatible API version). agentctl exits after it.
    case failed(destination: String, detail: String)

    private struct Line: Decodable {
        let event: String
        let destination: String?
        let socket: String?
        let version: String?
        let api: Int?
        let detail: String?
    }

    /// Nil for a blank line, a line that is not an event, or an event this version doesn't know.
    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = try? JSONDecoder().decode(Line.self, from: Data(trimmed.utf8)) else { return nil }
        let destination = value.destination ?? ""
        switch value.event {
        case "ready":
            guard let socket = value.socket, !socket.isEmpty else { return nil }
            self = .ready(destination: destination, socket: socket, version: value.version, api: value.api)
        case "disconnected":
            self = .disconnected(destination: destination, detail: value.detail ?? "")
        case "failed":
            self = .failed(destination: destination, detail: value.detail ?? "")
        default:
            return nil
        }
    }
}

/// The connection to the chosen host.
enum HostLink: Equatable, Sendable {
    case connecting
    case connected(version: String?)
    case disconnected(detail: String)
    case failed(detail: String)
}

/// One running `agentctl host connect`: its events until it exits, and the way to end it.
struct HostConnection: Sendable {
    let events: AsyncStream<HostConnectEvent>
    /// Ends the process (SIGTERM), which removes the forwarded socket. Safe to call twice.
    let stop: @Sendable () -> Void
}

/// The agentctl calls the hosts model makes.
struct CommanderHostsService: Sendable {
    var list: @Sendable () async throws -> [CommanderHost]
    var connect: @Sendable (_ destination: String) -> HostConnection

    /// The bundled agentctl. Without one, the list says so and a connection fails at once.
    static func live(agentctl: URL? = ServiceEndpoint.agentctl(),
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> CommanderHostsService {
        let missing = "This build of Agent Commander has no agentctl, so it can’t reach a headless host."
        return CommanderHostsService(
            list: {
                guard let agentctl, FileManager.default.isExecutableFile(atPath: agentctl.path) else {
                    throw ServiceError.offline(missing)
                }
                return try await Task.detached {
                    let process = Process()
                    process.executableURL = agentctl
                    process.arguments = ["host", "list"]
                    process.environment = environment
                    let output = Pipe(), errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let complaint = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let text = String(decoding: complaint, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw ServiceError.rejected(text.isEmpty ? "agentctl host list failed." : text)
                    }
                    return try CommanderHost.list(json: data)
                }.value
            },
            connect: { destination in
                guard let agentctl, FileManager.default.isExecutableFile(atPath: agentctl.path) else {
                    return HostConnection(events: AsyncStream { output in
                        output.yield(.failed(destination: destination, detail: missing))
                        output.finish()
                    }, stop: {})
                }
                let process = Process()
                process.executableURL = agentctl
                // The destination is one argument, never a shell word.
                process.arguments = ["host", "connect", destination]
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                let events = AsyncStream<HostConnectEvent> { output in
                    let reader = Task.detached {
                        do {
                            try process.run()
                            for try await line in pipe.fileHandleForReading.bytes.lines {
                                if let event = HostConnectEvent(line: line) { output.yield(event) }
                            }
                        } catch {
                            output.yield(.failed(destination: destination, detail: error.localizedDescription))
                        }
                        output.finish()
                    }
                    output.onTermination = { _ in
                        reader.cancel()
                        if process.isRunning { process.terminate() }
                    }
                }
                return HostConnection(events: events, stop: { if process.isRunning { process.terminate() } })
            })
    }
}

/// What the Hosts page draws for one host. This Mac has a nil `destination`.
struct CommanderHostEntry: Identifiable, Equatable {
    enum State: Equatable {
        /// A host the app is not connected to.
        case idle
        case connecting
        case connected
        case disconnected
        case failed
    }

    static let localID = "this-mac"

    let id: String
    /// Nil for this Mac.
    let destination: String?
    let name: String
    /// The line under the name: what kind of host it is, and its version.
    let kind: String
    let typeLabel: String
    let symbol: String
    let state: State
    /// The service the app talks to now.
    let isInUse: Bool
    var version: String? = nil
    var api: Int? = nil
    var updated: String? = nil
    /// Why the host is disconnected or failed, in agentctl's words.
    var detail: String? = nil

    var isLocal: Bool { destination == nil }

    var stateTitle: String {
        switch state {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .failed: "Can’t connect"
        }
    }

    var tone: Tone {
        switch state {
        case .idle: .neutral
        case .connecting: .focus
        case .connected: .working
        case .disconnected: .attention
        case .failed: .failure
        }
    }

    var stateSymbol: String {
        switch state {
        case .idle: "circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .disconnected: "bolt.slash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// What VoiceOver says for the row.
    var spoken: String {
        [name, kind, stateTitle.lowercased(), isInUse ? "in use" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

@Observable @MainActor
final class CommanderHostsModel {
    /// The hosts agentctl knows, in its order.
    private(set) var hosts: [CommanderHost] = []
    /// Why the list could not be read.
    private(set) var listError: String?
    /// The host chosen: connected, or being connected. Nil while this Mac is chosen.
    private(set) var chosen: String?
    /// The connection to `chosen`.
    private(set) var link: HostLink?
    /// The last failure of each host, kept until that host is chosen again.
    private(set) var failures: [String: String] = [:]
    /// The host whose service the app talks to now. Nil for this Mac.
    private(set) var inUse: String?

    /// Called after the endpoint moved to another socket.
    @ObservationIgnored var serviceChanged: @MainActor () -> Void = {}

    @ObservationIgnored private let endpoint: ServiceEndpoint
    @ObservationIgnored private let service: CommanderHostsService
    @ObservationIgnored private var connection: HostConnection?
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// Counts each choice, so events of a connection that was left are ignored.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    init(endpoint: ServiceEndpoint, service: CommanderHostsService) {
        self.endpoint = endpoint
        self.service = service
    }

    /// The running app's model: the bundled agentctl, and the connect process ends with the app.
    static func live(endpoint: ServiceEndpoint) -> CommanderHostsModel {
        let model = CommanderHostsModel(endpoint: endpoint, service: .live())
        model.quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                    object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.connection?.stop() }
        }
        return model
    }

    /// Reads the host list again. A host that is gone from the list while chosen stays chosen.
    func refresh() async {
        do {
            hosts = try await service.list()
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    /// Chooses the service the app talks to: a host by its destination, or this Mac with nil.
    /// A host is used once its forwarded socket answers; until then the app stays on this Mac.
    func use(_ destination: String?) {
        guard destination != chosen || link == nil || isFailed else { return }
        attempt += 1
        listener?.cancel()
        listener = nil
        connection?.stop()
        connection = nil
        point(at: nil)
        chosen = destination
        link = nil
        guard let destination else { return }
        failures[destination] = nil
        link = .connecting
        let opened = service.connect(destination)
        connection = opened
        let attempt = attempt
        listener = Task { [weak self] in
            for await event in opened.events {
                guard let self, self.attempt == attempt else { return }
                self.take(event, from: destination)
            }
            guard let self, self.attempt == attempt, !Task.isCancelled else { return }
            // agentctl exited. After `failed` that is expected; otherwise the connection is lost.
            if !self.isFailed { self.fail(destination, "The connection to \(destination) ended.") }
        }
    }

    /// The rows of the Hosts page: this Mac first, then the hosts in agentctl's order. A chosen
    /// host that is no longer listed keeps its row. `local` is the app's link to this Mac's
    /// service while it is in use.
    func entries(local: CommanderHostEntry.State = .connected) -> [CommanderHostEntry] {
        var listed = hosts
        if let chosen, !listed.contains(where: { $0.destination == chosen }) {
            listed.append(CommanderHost(destination: chosen))
        }
        let mac = CommanderHostEntry(id: CommanderHostEntry.localID, destination: nil, name: "This Mac",
                                     kind: "Local service", typeLabel: "Local service", symbol: "desktopcomputer",
                                     state: inUse == nil ? local : .idle, isInUse: inUse == nil)
        return [mac] + listed.map { host in
            var state = CommanderHostEntry.State.idle
            var detail = failures[host.destination]
            var version = host.version
            if detail != nil { state = .failed }
            if host.destination == chosen, let link {
                switch link {
                case .connecting: state = .connecting
                case .connected(let live):
                    state = .connected
                    version = live ?? version
                case .disconnected(let reason):
                    state = .disconnected
                    detail = reason
                case .failed(let reason):
                    state = .failed
                    detail = reason
                }
            }
            return CommanderHostEntry(id: host.destination, destination: host.destination, name: host.destination,
                                      kind: version.map { "Headless · \($0)" } ?? "Headless host",
                                      typeLabel: "Headless host", symbol: "server.rack", state: state,
                                      isInUse: inUse == host.destination, version: version, api: host.api,
                                      updated: host.updated, detail: detail?.isEmpty == false ? detail : nil)
        }
    }

    /// The name the toolbar shows for the service in use. Nil for this Mac.
    var serviceName: String? { inUse }

    private var isFailed: Bool {
        if case .failed = link { return true }
        return false
    }

    private func take(_ event: HostConnectEvent, from destination: String) {
        switch event {
        case .ready(_, let socket, let version, _):
            link = .connected(version: version)
            point(at: ServiceEndpoint.Remote(destination: destination, socket: socket))
        case .disconnected(_, let detail):
            // The endpoint stays on the host: agentctl is retrying, and the same socket answers again.
            link = .disconnected(detail: detail)
        case .failed(_, let detail):
            fail(destination, detail)
        }
    }

    /// The host can't be used. The detail stays on its row and the app returns to this Mac.
    private func fail(_ destination: String, _ detail: String) {
        link = .failed(detail: detail)
        failures[destination] = detail
        connection?.stop()
        connection = nil
        point(at: nil)
    }

    private func point(at remote: ServiceEndpoint.Remote?) {
        let changed = endpoint.select(remote)
        inUse = remote?.destination
        if changed { serviceChanged() }
    }
}
