import Darwin
import Foundation
import Synchronization

// MULTIPLAYER ADAPTER.
// Runs the bundled `commander-network` helper as a child process: positional arguments, JSON on
// stdin, one bounded JSON envelope on stdout. No shell, no logging of the input or the reply.
// The work runs on a background queue; cancellation and the deadline stop the child.

/// The process boundary. Tests substitute a scripted helper.
protocol MultiplayerHelper: Sendable {
    func run(verb: MultiplayerVerb, input: Data) async throws -> MultiplayerHelperOutput
}

struct MultiplayerHelperLocation: Equatable, Sendable {
    let url: URL
    /// True when COMMANDER_NETWORK_BIN points at a review fixture instead of the bundled helper.
    let isFixture: Bool
}

enum MultiplayerHelperLocator {
    /// Fixture override, honoured only in fixture mode: a DEBUG build launched with
    /// AGENT_COMMANDER_NETWORK_PANEL=1. Must then be an absolute path to an executable.
    static let overrideVariable = "COMMANDER_NETWORK_BIN"
    static let helperName = "commander-network"

    /// Release builds never run a substitute helper, whatever the environment says.
    static var buildAllowsFixture: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Fixture mode is explicit: a debug build and the review/test panel switch together.
    static func isFixtureMode(environment: [String: String], debugBuild: Bool) -> Bool {
        debugBuild && environment[MultiplayerLaunch.panelVariable] == "1"
    }

    /// Normal launches always use the signed bundle's `Contents/MacOS/commander-network`; the
    /// override is ignored outside fixture mode. In fixture mode a set override must be valid:
    /// a relative or non-executable path fails rather than falling back to either helper.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        bundleURL: URL = Bundle.main.bundleURL,
                        debugBuild: Bool = buildAllowsFixture,
                        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> Result<MultiplayerHelperLocation, MultiplayerFailure>
    {
        if isFixtureMode(environment: environment, debugBuild: debugBuild),
           let raw = environment[overrideVariable], !raw.isEmpty {
            guard raw.hasPrefix("/") else { return .failure(.badOverride) }
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            guard isExecutable(url.path(percentEncoded: false)) else { return .failure(.badOverride) }
            return .success(MultiplayerHelperLocation(url: url, isFixture: true))
        }
        let url = bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)", isDirectory: false)
        guard isExecutable(url.path(percentEncoded: false)) else { return .failure(.helperMissing) }
        return .success(MultiplayerHelperLocation(url: url, isFixture: false))
    }
}

/// Encodes commands, runs the helper and reads its envelope. Every error leaves as a
/// `MultiplayerFailure`.
struct MultiplayerClient: Sendable {
    static let inputLimit = 16 * 1024
    /// `profile` may carry an avatar: a data URL of at most 64 KiB, plus the other fields.
    static let profileInputLimit = MultiplayerAvatarEncoder.limit + 8 * 1024

    static func inputLimit(for verb: MultiplayerVerb) -> Int {
        switch verb {
        case .profile: profileInputLimit
        case .send, .fanout: sendInputLimit
        default: inputLimit
        }
    }

    let helper: any MultiplayerHelper
    /// The server every request acts on, sent as `"server"`. Nil for the server-list verbs.
    var server: String? = nil

    /// The same helper, acting on one server.
    func scoped(to server: String) -> MultiplayerClient {
        MultiplayerClient(helper: helper, server: server)
    }

    private struct Found: Decodable {
        let handle: String
    }

    /// A definite status reply, or a failure. Never a guess.
    func status() async throws -> MultiplayerStatus {
        do {
            let output = try await call(.status, payload: [:])
            guard let status = try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: output) else {
                throw MultiplayerFailure.invalidResponse
            }
            return status
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }

    /// Explicit exact-handle lookup. Returns the handle the network reports.
    func lookUp(handle: String) async throws -> String {
        do {
            let output = try await call(.search, payload: ["handle": .string(handle)])
            guard let found = try MultiplayerEnvelope.decode(Found.self, from: output), !found.handle.isEmpty else {
                throw MultiplayerFailure.invalidResponse
            }
            return found.handle
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }

    /// Runs one command. Returns only when the helper confirmed it.
    func perform(_ command: MultiplayerCommand) async throws {
        do {
            let output = try await call(command.verb, payload: command.payload)
            _ = try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: output)
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }

    /// Hands one repository's GitHub token to the helper, which keeps it in the Keychain. Only the
    /// owner's resource ID and the token are sent. Failures never carry the value.
    func saveRepoCredential(resourceID: String, token: String) async throws {
        guard !resourceID.isEmpty, MultiplayerCredential.problem(token) == nil else {
            throw MultiplayerFailure.invalidInput("That token can’t be sent.")
        }
        do {
            let output = try await call(.repoCredential, payload: ["resource": .string(resourceID), "token": .string(token)])
            _ = try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: output)
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }

    /// The exact stdin bytes for one request: a sorted JSON object, at most `inputLimit` bytes.
    static func encode(_ payload: [String: MultiplayerPayloadValue], limit: Int = inputLimit) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let input = try? encoder.encode(payload), input.count <= limit else {
            throw MultiplayerFailure.invalidInput("That entry is too long to send.")
        }
        return input
    }

    // MARK: Server list

    private struct ServerList: Decodable {
        let servers: [MultiplayerServerSummary]
    }

    /// The saved servers, favorites first, then most recently used.
    func servers() async throws -> [MultiplayerServerSummary] {
        MultiplayerServerSummary.ordered(try await fetch(.servers, [:], as: ServerList.self).servers)
    }

    /// The staged health check for an address the person typed. Nothing is saved.
    func probe(url: String) async throws -> MultiplayerProbe {
        try await fetch(.serverProbe, ["url": .string(url)], as: MultiplayerProbe.self)
    }

    func addServer(url: String, name: String, pin: String) async throws -> MultiplayerServerSummary {
        var payload: [String: MultiplayerPayloadValue] = ["url": .string(url), "pin": .string(pin)]
        if !name.isEmpty { payload["name"] = .string(name) }
        return try await fetch(.serverAdd, payload, as: MultiplayerServerSummary.self)
    }

    /// Sends only the settings that are given.
    func updateServer(id: String, name: String? = nil, favorite: Bool? = nil,
                      autoConnect: Bool? = nil) async throws -> MultiplayerServerSummary {
        var payload: [String: MultiplayerPayloadValue] = ["server": .string(id)]
        if let name { payload["name"] = .string(name) }
        if let favorite { payload["favorite"] = .bool(favorite) }
        if let autoConnect { payload["autoConnect"] = .bool(autoConnect) }
        return try await fetch(.serverUpdate, payload, as: MultiplayerServerSummary.self)
    }

    func removeServer(id: String) async throws {
        do {
            let output = try await call(.serverRemove, payload: ["server": .string(id)])
            _ = try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: output)
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }

    /// Accepts the key a pinned server now presents.
    func trustServer(id: String, pin: String) async throws -> MultiplayerServerSummary {
        try await fetch(.serverTrust, ["server": .string(id), "pin": .string(pin)], as: MultiplayerServerSummary.self)
    }

    // MARK: Social (increment 2)

    private struct ContactList: Decodable {
        let contacts: [MultiplayerContact]
    }

    private func send(_ verb: MultiplayerVerb, _ payload: [String: MultiplayerPayloadValue]) async throws {
        do {
            let output = try await call(verb, payload: payload)
            _ = try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: output)
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }

    /// Sends only the profile fields that are given. An empty `avatar` removes the picture.
    func setProfile(handle: String? = nil, displayName: String? = nil, statusMessage: String? = nil,
                    avatar: String? = nil) async throws {
        var payload: [String: MultiplayerPayloadValue] = [:]
        if let handle { payload["handle"] = .string(handle) }
        if let displayName { payload["displayName"] = .string(displayName) }
        if let statusMessage { payload["statusMessage"] = .string(statusMessage) }
        if let avatar { payload["avatar"] = .string(avatar) }
        try await send(.profile, payload)
    }

    func setPresence(_ choice: MultiplayerPresenceChoice) async throws -> MultiplayerPresenceReply {
        try await fetch(.presence, ["presence": .string(choice.rawValue)], as: MultiplayerPresenceReply.self)
    }

    /// Friends across every server, linked by contact key.
    func contacts() async throws -> [MultiplayerContact] {
        try await fetch(.contacts, [:], as: ContactList.self).contacts
    }

    /// The feed across servers; with a cursor, the events after it.
    func activity(after cursor: String? = nil) async throws -> MultiplayerActivityFeed {
        try await fetch(.activity, cursor.map { ["after": .string($0)] } ?? [:], as: MultiplayerActivityFeed.self)
    }

    func markActivitySeen(cursor: String) async throws {
        try await send(.activitySeen, ["cursor": .string(cursor)])
    }

    func avatar(handle: String) async throws -> MultiplayerAvatarImage {
        try await fetch(.avatar, ["handle": .string(handle)], as: MultiplayerAvatarImage.self)
    }

    func me() async throws -> MultiplayerMe {
        try await fetch(.me, [:], as: MultiplayerMe.self)
    }

    func membership() async throws -> MultiplayerMembership {
        try await fetch(.membership, [:], as: MultiplayerMembership.self)
    }

    func setMembership(mode: String, allowedEmails: [String], admins: [String]) async throws -> MultiplayerMembership {
        try await fetch(.membershipSet, ["mode": .string(mode), "allowedEmails": .strings(allowedEmails),
                                         "admins": .strings(admins)], as: MultiplayerMembership.self)
    }

    func createInvite(maxUses: Int, ttlHours: Int) async throws -> MultiplayerInvite {
        try await fetch(.inviteCreate, ["maxUses": .number(maxUses), "ttlHours": .number(ttlHours)],
                        as: MultiplayerInvite.self)
    }

    /// Adds the invite's server with its pin and starts sign-in carrying the invite code.
    func join(link: String) async throws -> MultiplayerServerSummary {
        try await fetch(.join, ["link": .string(link)], as: MultiplayerServerSummary.self)
    }

    func fetch<Reply: Decodable>(_ verb: MultiplayerVerb, _ payload: [String: MultiplayerPayloadValue],
                                         as type: Reply.Type) async throws -> Reply {
        do {
            let output = try await call(verb, payload: payload)
            guard let reply = try MultiplayerEnvelope.decode(Reply.self, from: output) else {
                throw MultiplayerFailure.invalidResponse
            }
            return reply
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }

    func call(_ verb: MultiplayerVerb, payload: [String: MultiplayerPayloadValue]) async throws -> MultiplayerHelperOutput {
        var payload = payload
        if let server, payload["server"] == nil { payload["server"] = .string(server) }
        let input = try Self.encode(payload, limit: Self.inputLimit(for: verb))
        try Task.checkCancellation()
        return try await helper.run(verb: verb, input: input)
    }
}

/// Raised once by cancellation, the deadline or the output bound. Read by the reading loop.
final class MultiplayerStopSignal: Sendable {
    enum Reason: Sendable, Equatable { case cancelled, timedOut, oversized }

    private let state = Mutex<Reason?>(nil)

    func raise(_ reason: Reason) {
        state.withLock { current in
            if current == nil { current = reason }
        }
    }

    var reason: Reason? { state.withLock { $0 } }
}

/// The real helper process.
struct MultiplayerProcessHelper: MultiplayerHelper {
    let executable: URL
    var timeout: Duration = .seconds(20)
    var outputLimit = 256 * 1024

    func run(verb: MultiplayerVerb, input: Data) async throws -> MultiplayerHelperOutput {
        let stop = MultiplayerStopSignal()
        let executable = executable
        let arguments = verb.arguments
        let timeout = timeout
        let limit = outputLimit
        let inputLimit = MultiplayerClient.inputLimit(for: verb)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MultiplayerHelperOutput, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try MultiplayerProcessRun.execute(executable: executable, arguments: arguments, input: input,
                                                          timeout: timeout, limit: limit, stop: stop,
                                                          inputLimit: inputLimit)
                    })
                }
            }
        } onCancel: {
            stop.raise(.cancelled)
        }
    }
}

/// One blocking invocation on a background queue. The `Process` never leaves this function.
enum MultiplayerProcessRun {
    static func execute(executable: URL, arguments: [String], input: Data, timeout: Duration,
                        limit: Int, stop: MultiplayerStopSignal,
                        inputLimit: Int = MultiplayerClient.inputLimit) throws -> MultiplayerHelperOutput {
        if stop.reason != nil { throw MultiplayerFailure.cancelled }
        guard input.count <= inputLimit else {
            throw MultiplayerFailure.invalidInput("That entry is too long to send.")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw MultiplayerFailure.launchFailed
        }
        // The deadline starts before any input is written, so a child that never reads cannot hold us.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        let reader = stdoutPipe.fileHandleForReading
        defer { try? reader.close() }
        let descriptor = reader.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        // stdin is written in nonblocking chunks inside the same poll loop that drains stdout, so
        // neither pipe filling up can stall the other. A helper that exits without reading stdin
        // must not raise SIGPIPE in the app.
        let writer = stdinPipe.fileHandleForWriting
        let inputDescriptor = writer.fileDescriptor
        _ = fcntl(inputDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(inputDescriptor, F_SETFL, fcntl(inputDescriptor, F_GETFL) | O_NONBLOCK)
        var written = 0
        var writerOpen = true
        func closeWriter() {
            guard writerOpen else { return }
            writerOpen = false
            try? writer.close()
        }
        defer { closeWriter() }
        if input.isEmpty { closeWriter() }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var exitedAt: ContinuousClock.Instant?

        reading: while stop.reason == nil {
            if clock.now >= deadline {
                stop.raise(.timedOut)
                break
            }
            var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
            if writerOpen { descriptors.append(pollfd(fd: inputDescriptor, events: Int16(POLLOUT), revents: 0)) }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if writerOpen, descriptors.count > 1, descriptors[1].revents != 0 {
                if descriptors[1].revents & Int16(POLLOUT) == 0 {
                    closeWriter()    // the child closed its stdin
                } else {
                    let count = input.withUnsafeBytes { bytes in
                        bytes.baseAddress.map { Darwin.write(inputDescriptor, $0 + written, bytes.count - written) } ?? 0
                    }
                    if count > 0 {
                        written += count
                        if written >= input.count { closeWriter() }
                    } else if count < 0, errno != EAGAIN, errno != EINTR {
                        closeWriter()    // EPIPE: the child stopped reading
                    }
                }
            }
            if descriptors[0].revents == 0 {
                // A descendant (such as a browser launcher) may hold the pipe after the helper exits.
                if !process.isRunning {
                    let since = exitedAt ?? clock.now
                    exitedAt = since
                    if clock.now - since > .milliseconds(250) { break }
                }
                continue
            }
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    output.append(contentsOf: buffer[0..<count])
                    if output.count > limit {
                        stop.raise(.oversized)
                        break reading
                    }
                } else if count == 0 {
                    break reading
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN {
                    break    // drained: wait for more
                } else {
                    break reading
                }
            }
        }

        if let reason = stop.reason {
            terminate(process)
            switch reason {
            case .cancelled: throw MultiplayerFailure.cancelled
            case .timedOut: throw MultiplayerFailure.timedOut
            case .oversized: throw MultiplayerFailure.oversized
            }
        }

        while process.isRunning {
            if stop.reason != nil || clock.now >= deadline {
                terminate(process)
                throw stop.reason == .cancelled ? MultiplayerFailure.cancelled : MultiplayerFailure.timedOut
            }
            usleep(10_000)
        }
        return MultiplayerHelperOutput(exitStatus: process.terminationStatus, stdout: output)
    }

    /// SIGTERM, a short grace period, then SIGKILL.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let clock = ContinuousClock()
        let grace = clock.now.advanced(by: .seconds(1))
        while process.isRunning && clock.now < grace { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
