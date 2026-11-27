import Foundation
import Observation
import SwiftUI

// Harnesses: the AI harnesses this Mac can run, whether each is installed and signed in, and the
// sign-in and install sessions (design/HARNESSES.md).
//
//   Values         Harness              one harness, as the service reports it
//                  HarnessAttachment    the tmux session a login or install runs in
//                  HarnessSession       an attachment the window shows in a sheet
//                  HarnessAlert         a harness that was signed in and no longer is
//                  HarnessTally         the counts the navigation shows
//                  HarnessPlace         the mode's places and how the harnesses fall into them
//   Stream         HarnessSnapshot      reads one `{"harnesses":[...]}` frame
//                  HarnessStream        one connection to GET /v1/harnesses/events on the owner socket
//   Feature model  HarnessFeed          the one subscription, every API call, alerts and the open session
//   For the page   HarnessesContext     the feed's state as values, and its intents (HarnessActions)
//
// The page (HarnessesPage.swift) takes values and emits actions. Only `HarnessesContext.init(feed:)`
// reads the model.

// MARK: - Values

struct Harness: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case agent, runner }

    enum Group: String, CaseIterable, Sendable {
        case vendor, openSource = "open_source", ide, runner

        var title: String {
            switch self {
            case .vendor: "Vendor"
            case .openSource: "Open source"
            case .ide: "IDE"
            case .runner: "Model runner"
            }
        }
    }

    enum AuthState: String, Sendable {
        case signedIn = "signed_in", signedOut = "signed_out", expired
        case notRequired = "not_required", unknown, notInstalled = "not_installed"
    }

    enum AuthSource: String, Sendable {
        case statusCommand = "status_command", credentialFile = "credential_file", environment, keychain, none
    }

    enum ACPMode: String, Sendable {
        case acp, legacy, unsupported
        /// Agent Commander needs the adapter to run this harness and can't find it.
        case adapterMissing = "adapter_missing"
    }

    struct Auth: Equatable, Sendable {
        var state: AuthState = .unknown
        var account = ""
        var plan = ""
        var method = ""
        var expiresAt: Date? = nil
        var source: AuthSource = .none
        var detail = ""
    }

    struct ACP: Equatable, Sendable {
        var adapter = ""
        var installed = false
        var mode: ACPMode = .unsupported
    }

    /// A command the service can run for this harness: install or sign in.
    struct Command: Equatable, Sendable {
        var available = false
        /// The command as the person would type it.
        var display = ""
    }

    struct Settings: Equatable, Sendable {
        var enabled = true
        /// Empty leaves the choice to the harness.
        var defaultModel = ""
    }

    let id: String
    var name: String
    var vendor = ""
    var kind: Kind = .agent
    var group: Group = .vendor
    var website = ""
    /// Agent Commander can start runs with it.
    var managed = false
    /// The probe was checked against the real CLI. An unverified harness reports sign-in from its
    /// credential files only.
    var verified = false
    var installed = false
    var executable = ""
    var version = ""
    var auth = Auth()
    var acp = ACP()
    var install = Command()
    var login = Command()
    var settings = Settings()
    var models: [String] = []
    var checkedAt: Date? = nil
    /// Why Agent Commander can't start a run with it now. Only on a managed harness; empty when it can.
    var runBlocker = ""
    /// What changed since the previous frame. Present only in a stream frame.
    var changed: String? = nil

    /// Installed, and its sign-in is gone: signed out or expired.
    var needsSignIn: Bool { installed && (auth.state == .signedOut || auth.state == .expired) }

    /// A run can start with it now: signed in, and the service names nothing in the way.
    var isReady: Bool { installed && auth.state == .signedIn && runBlocker.isEmpty }

    /// The state as the row and the inspector say it. A harness that isn't installed says so
    /// whatever its sign-in reads.
    var state: (title: String, tone: Tone, lamp: MultiplayerLamp.Kind, symbol: String) {
        guard installed else { return ("Not installed", .neutral, .off, "circle.dashed") }
        switch auth.state {
        case .signedIn: return ("Signed in", .working, .on, "checkmark.circle.fill")
        case .signedOut: return ("Not signed in", .attention, .busy, "person.crop.circle.badge.exclamationmark")
        case .expired: return ("Expired", .failure, .error, "clock.badge.exclamationmark")
        case .notRequired: return ("No sign-in needed", .neutral, .off, "minus.circle")
        case .unknown: return ("Unknown", .focus, .unknown, "questionmark.circle")
        case .notInstalled: return ("Not installed", .neutral, .off, "circle.dashed")
        }
    }

    /// "Anthropic · Agent": who makes it and what it is.
    var kindLine: String {
        let what = kind == .runner ? "Model runner" : "Agent"
        return vendor.isEmpty ? what : "\(vendor) · \(what)"
    }

    var symbol: String { kind == .runner ? "cpu" : "terminal" }

    /// What VoiceOver reads for the row.
    var spoken: String {
        var parts = [name, kindLine, state.title]
        if !version.isEmpty { parts.append("version \(version)") }
        if cantRun { parts.append("can’t start runs") }
        if installed, !settings.enabled { parts.append("turned off") }
        return parts.joined(separator: ", ")
    }

    /// Where the sign-in state was read, as a phrase. An unverified harness is always read from
    /// its credential files.
    var sourceTitle: String {
        if !verified, auth.source != .none { return "From credential files" }
        switch auth.source {
        case .statusCommand: return "From its status command"
        case .credentialFile: return "From credential files"
        case .environment: return "From an API key variable"
        case .keychain: return "From the Keychain"
        case .none: return "Not read"
        }
    }

    var acpModeTitle: String {
        switch acp.mode {
        case .acp: "ACP"
        case .legacy: "Legacy (tmux, without its adapter)"
        case .adapterMissing: "Adapter not found"
        case .unsupported: "No adapter"
        }
    }

    /// Agent Commander starts runs with this harness through an adapter it can't find.
    var adapterIsMissing: Bool { managed && installed && acp.mode == .adapterMissing }

    /// A managed, installed harness the service says can't start a run, or whose adapter is missing.
    var cantRun: Bool { managed && installed && (!runBlocker.isEmpty || acp.mode == .adapterMissing) }

    /// What a missing adapter means, as two sentences.
    var adapterWarning: String {
        let adapter = acp.adapter.isEmpty ? "its ACP adapter" : acp.adapter
        return "Agent Commander can’t find \(adapter). Runs with \(name) can’t start until it is installed or on PATH."
    }
}

/// The tmux session a login or install command runs in.
struct HarnessAttachment: Equatable, Sendable {
    let harnessID: String
    let purpose: String
    let socketPath: String
    let sessionID: String
}

/// A login or install the window is showing.
struct HarnessSession: Identifiable, Equatable, Sendable {
    enum Purpose: String, Sendable {
        case login, install

        var verb: String { self == .login ? "Sign in" : "Install" }
    }

    let harnessID: String
    let harnessName: String
    let purpose: Purpose
    /// The command the session runs, as the person would type it.
    let command: String
    let attachment: HarnessAttachment
    /// FIXTURE ONLY. Text drawn in place of a terminal.
    var fixture: String? = nil

    var id: String { "\(harnessID)/\(purpose.rawValue)/\(attachment.sessionID)" }
    var title: String { purpose == .login ? "Sign in to \(harnessName)" : "Install \(harnessName)" }
}

/// A harness that was signed in and no longer is. It waits in Needs you until the harness is
/// signed in again.
struct HarnessAlert: Identifiable, Equatable, Sendable {
    let harnessID: String
    let name: String
    let expired: Bool
    let since: Date

    var id: String { harnessID }
    /// The Needs you row's ID.
    var inboxID: String { HarnessAlert.inboxPrefix + harnessID }
    var title: String { expired ? "\(name) sign-in expired" : "\(name) signed out" }

    static let inboxPrefix = "harness:"

    /// The harness a Needs you row stands for.
    static func harnessID(inboxID: String) -> String? {
        inboxID.hasPrefix(inboxPrefix) ? String(inboxID.dropFirst(inboxPrefix.count)) : nil
    }
}

/// How many harnesses each place of the mode lists.
struct HarnessTally: Equatable, Sendable {
    var needsSignIn = 0
    var installed = 0
    var available = 0

    init() {}

    init(_ harnesses: [Harness]) {
        needsSignIn = harnesses.filter(\.needsSignIn).count
        installed = harnesses.filter(\.installed).count
        available = harnesses.count - installed
    }

    /// The page header's one line: "5 installed, 1 needs sign-in, 6 available".
    var summary: String {
        var parts = ["\(installed) installed"]
        if needsSignIn > 0 { parts.append(needsSignIn == 1 ? "1 needs sign-in" : "\(needsSignIn) need sign-in") }
        parts.append("\(available) available")
        return parts.joined(separator: ", ")
    }
}

/// The Harnesses mode's places. Each is one filter of the same page.
enum HarnessPlace {
    static let mode = "harnesses"
    static let signIn = "harnesses.sign-in"
    static let installed = "harnesses.installed"
    static let available = "harnesses.available"

    static func hasPage(_ id: String) -> Bool { id == signIn || id == installed || id == available }

    static func title(_ id: String) -> String {
        switch id {
        case signIn: "Needs sign-in"
        case available: "Available"
        default: "Installed"
        }
    }

    /// The mode's places. Needs sign-in is listed only while a harness needs it, so the mode opens
    /// on what is installed when nothing waits.
    static func places(_ tally: HarnessTally) -> [CommanderPlace] {
        var places: [CommanderPlace] = []
        if tally.needsSignIn > 0 {
            places.append(CommanderPlace(id: signIn, title: title(signIn), mark: .symbol("person.badge.key"),
                                         count: tally.needsSignIn, isHot: true, isDetail: true, countNoun: "to sign in"))
        }
        places.append(CommanderPlace(id: installed, title: title(installed), mark: .symbol("checkmark.square"),
                                     count: tally.installed, isDetail: true, countNoun: "installed"))
        places.append(CommanderPlace(id: available, title: title(available), mark: .symbol("arrow.down.square"),
                                     count: tally.available, isDetail: true, countNoun: "available"))
        return places
    }

    /// The rail cell and its context list. Its hot count is the Needs sign-in place's.
    static func mode(_ tally: HarnessTally) -> CommanderMode {
        CommanderMode(id: mode, title: "Harnesses", symbol: "cable.connector", sections: [
            CommanderPlaceGroup(id: mode, title: "Harnesses", placeIDs: places(tally).map(\.id))
        ])
    }

    /// The harnesses a place lists. Installed lists every installed harness, the ones that need
    /// sign-in too. Available is ordered by group, then by name.
    static func harnesses(_ all: [Harness], in place: String) -> [Harness] {
        switch place {
        case signIn:
            return all.filter(\.needsSignIn)
        case available:
            let order = Dictionary(uniqueKeysWithValues: Harness.Group.allCases.enumerated().map { ($1, $0) })
            return all.filter { !$0.installed }.sorted {
                let (a, b) = (order[$0.group] ?? 0, order[$1.group] ?? 0)
                return a != b ? a < b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        default:
            return all.filter(\.installed)
        }
    }

    /// What an empty place says.
    static func emptyNote(_ place: String) -> (text: String, lamp: MultiplayerLamp.Kind) {
        switch place {
        case signIn: ("Every installed harness is signed in.", .on)
        case available: ("Every harness Agent Commander knows is installed.", .on)
        default: ("No harness is installed yet. Choose one under Available to install it.", .off)
        }
    }
}

// MARK: - Stream

enum HarnessSnapshot {
    private struct Envelope: Decodable {
        let harnesses: [Wire]?
        /// A single harness, where a route wraps the one it returns.
        let harness: Wire?
    }

    private struct Wire: Decodable {
        struct Auth: Decodable {
            let state, account, plan, method, expires_at, source, detail: String?
        }
        struct ACP: Decodable {
            let adapter: String?
            let installed: Bool?
            let mode: String?
        }
        struct Command: Decodable {
            let available: Bool?
            let display: String?
        }
        struct Settings: Decodable {
            let enabled: Bool?
            let default_model: String?
        }

        let id: String?
        let name, vendor, kind, group, website, executable, version, checked_at, changed, run_blocker: String?
        let managed, verified, installed: Bool?
        let auth: Auth?
        let acp: ACP?
        let install, login: Command?
        let settings: Settings?
        let models: [String]?

        var value: Harness? {
            guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
            var harness = Harness(id: id, name: name?.isEmpty == false ? name! : id)
            harness.vendor = vendor ?? ""
            harness.kind = kind.flatMap(Harness.Kind.init(rawValue:)) ?? .agent
            harness.group = group.flatMap(Harness.Group.init(rawValue:)) ?? (harness.kind == .runner ? .runner : .vendor)
            harness.website = website ?? ""
            harness.managed = managed ?? false
            harness.verified = verified ?? false
            harness.installed = installed ?? false
            harness.executable = executable ?? ""
            harness.version = version ?? ""
            harness.auth = Harness.Auth(
                state: auth?.state.flatMap(Harness.AuthState.init(rawValue:)) ?? (harness.installed ? .unknown : .notInstalled),
                account: auth?.account ?? "", plan: auth?.plan ?? "", method: auth?.method ?? "",
                expiresAt: HarnessSnapshot.date(auth?.expires_at),
                source: auth?.source.flatMap(Harness.AuthSource.init(rawValue:)) ?? .none,
                detail: auth?.detail ?? "")
            harness.acp = Harness.ACP(adapter: acp?.adapter ?? "", installed: acp?.installed ?? false,
                                      mode: acp?.mode.flatMap(Harness.ACPMode.init(rawValue:)) ?? .unsupported)
            harness.install = Harness.Command(available: install?.available ?? false, display: install?.display ?? "")
            harness.login = Harness.Command(available: login?.available ?? false, display: login?.display ?? "")
            harness.settings = Harness.Settings(enabled: settings?.enabled ?? true, defaultModel: settings?.default_model ?? "")
            harness.models = models ?? []
            harness.checkedAt = HarnessSnapshot.date(checked_at)
            harness.runBlocker = run_blocker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            harness.changed = changed?.isEmpty == false ? changed : nil
            return harness
        }
    }

    private struct AttachmentWire: Decodable {
        let harness_id, purpose, socket_path, session_id: String?
    }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Reads a list frame. The service's order is kept; a second entry with the same ID and an
    /// entry without one are left out. A missing or null list is empty.
    static func decode(_ frame: some Sequence<UInt8>) throws -> [Harness] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(frame))
        var seen = Set<String>()
        return (envelope.harnesses ?? []).compactMap(\.value).filter { seen.insert($0.id).inserted }
    }

    /// Reads the one harness a route returns, bare or wrapped as `{"harness": {...}}`.
    static func decodeOne(_ data: Data) throws -> Harness {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(Envelope.self, from: data), let harness = wrapped.harness?.value { return harness }
        guard let harness = try decoder.decode(Wire.self, from: data).value else {
            throw ServiceError.rejected("The service returned a harness without an ID.")
        }
        return harness
    }

    static func decodeAttachment(_ data: Data) throws -> HarnessAttachment {
        let wire = try JSONDecoder().decode(AttachmentWire.self, from: data)
        guard let socket = wire.socket_path, !socket.isEmpty, let session = wire.session_id, !session.isEmpty else {
            throw ServiceError.rejected("The service started no terminal session.")
        }
        return HarnessAttachment(harnessID: wire.harness_id ?? "", purpose: wire.purpose ?? "", socketPath: socket, sessionID: session)
    }
}

enum HarnessStream {
    static let path = "/v1/harnesses/events"
    static let lineLimit = 1 << 20
    static let eventLimit = 1 << 20

    enum Failure: Error, Equatable {
        /// The service has no harness routes (404).
        case unsupported
        /// The feed ended. The feed model reconnects.
        case disconnected
    }

    /// Turns the transport's bytes into lists. Heartbeat comments are skipped by the parser.
    struct Reader {
        enum Output: Equatable {
            case harnesses([Harness])
            case unsupported
        }

        private var parser = AGUIEventStreamParser(lineLimit: HarnessStream.lineLimit, eventLimit: HarnessStream.eventLimit)

        /// A frame that cannot be read is skipped and the last list stays in place.
        mutating func consume(_ byte: UInt8) throws -> Output? {
            switch try parser.consume(byte) {
            case nil: nil
            case .status(404)?: .unsupported
            case .status?: nil
            case .event(let frame)?: (try? HarnessSnapshot.decode(frame)).map(Output.harnesses)
            }
        }
    }

    /// One connection. Each element is the complete current list. It always ends by throwing.
    /// Frames are kept in order: a change marked in one frame must not be skipped.
    static func connect(socket: String) -> AsyncThrowingStream<[Harness], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { output in
            let producer = Task.detached(priority: .utility) {
                do {
                    try await read(socket: socket) { output.yield($0) }
                } catch {
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { _ in producer.cancel() }
        }
    }

    private static func read(socket: String, yield: ([Harness]) -> Void) async throws {
        let client = Process()
        let pipe = Pipe()
        client.executableURL = URL(filePath: "/usr/bin/curl")
        // No bearer credential: the owner socket is the boundary, and the routes refuse an
        // Authorization header. The service heartbeats every 10 s; a feed silent for a minute is
        // treated as gone and reopened.
        client.arguments = [
            "--disable", "--silent", "--fail", "--no-buffer", "--noproxy", "*",
            "--connect-timeout", "3", "--speed-limit", "1", "--speed-time", "60",
            "--unix-socket", socket, "--header", "Accept: text/event-stream",
            "--write-out", "\ncommander-http-status: %{http_code}\n",
            "http://localhost\(path)"
        ]
        client.standardOutput = pipe
        client.standardError = FileHandle.nullDevice
        try client.run()
        let transfer = Transfer(client)
        defer { transfer.end() }
        _ = try? pipe.fileHandleForWriting.close()
        try await withTaskCancellationHandler {
            var reader = Reader()
            // Its own reader, so a quiet feed never holds up another (`FileHandle.ownChunks`).
            for await chunk in pipe.fileHandleForReading.ownChunks {
                for byte in chunk {
                    guard let output = try reader.consume(byte) else { continue }
                    try Task.checkCancellation()
                    switch output {
                    case .unsupported: throw Failure.unsupported
                    case .harnesses(let harnesses): yield(harnesses)
                    }
                }
            }
            try Task.checkCancellation()
            throw Failure.disconnected
        } onCancel: {
            transfer.end()
        }
    }

    private final class Transfer: @unchecked Sendable {
        private let process: Process

        init(_ process: Process) { self.process = process }

        func end() {
            if process.isRunning { process.terminate() }
        }
    }
}

// MARK: - Feature model

/// The service's harness routes, as the feed calls them.
struct HarnessAPI: Sendable {
    var watch: @Sendable () -> AsyncThrowingStream<[Harness], Error>
    var check: @Sendable (_ id: String) async throws -> Harness
    var start: @Sendable (_ id: String, _ purpose: HarnessSession.Purpose) async throws -> HarnessAttachment
    var saveSettings: @Sendable (_ id: String, _ settings: Harness.Settings) async throws -> Harness
}

/// The harness list the service reports, kept by one subscription, with every call the Harnesses
/// mode makes. A disconnect keeps the last list on screen.
@Observable @MainActor
final class HarnessFeed {
    enum Link: Equatable {
        case connecting
        case live
        /// The connection dropped after a list arrived. The last list is still shown.
        case reconnecting
        /// The service has no harness routes, or can't be reached, and nothing was ever read.
        case unavailable
    }

    private(set) var harnesses: [Harness] = []
    private(set) var link: Link = .connecting
    /// Harnesses that were signed in and no longer are, oldest first.
    private(set) var alerts: [HarnessAlert] = []
    /// Harnesses with a call in flight.
    private(set) var busy = Set<String>()
    /// Why the last call for a harness didn't go through.
    private(set) var failures: [String: String] = [:]
    /// The login or install the window shows.
    private(set) var session: HarnessSession?
    private(set) var isRefreshing = false

    @ObservationIgnored private let api: HarnessAPI?
    /// Tells the person outside the window: a macOS notification.
    @ObservationIgnored var notify: @MainActor (HarnessAlert) -> Void = { _ in }
    @ObservationIgnored private var lastCall = 0
    @ObservationIgnored private var pause: Task<Void, Never>?
    @ObservationIgnored private var lastQuietCheck = Date.distantPast

    init(api: HarnessAPI) { self.api = api }

    /// A fixed list for previews and fixtures. It never connects, and its actions change the list
    /// in place.
    init(fixture harnesses: [Harness], alerts: [HarnessAlert] = [], link: Link = .live) {
        api = nil
        self.harnesses = harnesses
        self.alerts = alerts
        self.link = link
    }

    var tally: HarnessTally { HarnessTally(harnesses) }

    func harness(_ id: String) -> Harness? { harnesses.first { $0.id == id } }

    // MARK: Subscription

    /// Follows the list until the calling task is cancelled. The newest call holds the
    /// subscription: an earlier one stops at its next frame or pause.
    func follow() async {
        guard let api else { return }
        lastCall += 1
        let call = lastCall
        var failed = 0
        while !Task.isCancelled, call == lastCall {
            do {
                for try await frame in api.watch() {
                    guard call == lastCall else { return }
                    failed = 0
                    link = .live
                    apply(frame)
                }
            } catch HarnessStream.Failure.unsupported {
                failed = max(failed, AdapterUpdateFeed.unsupportedFailures - 1)
            } catch {
                // Any other end is a lost connection. The next list reconciles.
            }
            guard !Task.isCancelled, call == lastCall else { return }
            link = harnesses.isEmpty ? .unavailable : .reconnecting
            failed += 1
            let delay = AdapterUpdateFeed.delay(afterFailures: failed)
            let wait = Task { _ = try? await Task.sleep(for: delay) }
            pause = wait
            await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
        }
    }

    /// Asks again now instead of waiting out the pause between attempts.
    func retry() {
        if link == .unavailable { link = .connecting }
        pause?.cancel()
    }

    /// Replaces the list. A harness that was signed in and now is signed out or expired raises an
    /// alert; one that is signed in again clears its alert.
    func apply(_ next: [Harness], now: Date = .now) {
        let before = Dictionary(harnesses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for harness in next {
            if harness.needsSignIn {
                guard before[harness.id]?.auth.state == .signedIn, !alerts.contains(where: { $0.harnessID == harness.id }) else { continue }
                let alert = HarnessAlert(harnessID: harness.id, name: harness.name, expired: harness.auth.state == .expired, since: now)
                alerts.append(alert)
                notify(alert)
            } else {
                alerts.removeAll { $0.harnessID == harness.id }
            }
        }
        let listed = Set(next.map(\.id))
        alerts.removeAll { !listed.contains($0.harnessID) }
        if harnesses != next { harnesses = next }
    }

    /// Puts one harness, as a call returned it, in the list.
    private func place(_ harness: Harness) {
        var next = harnesses
        if let index = next.firstIndex(where: { $0.id == harness.id }) { next[index] = harness } else { next.append(harness) }
        apply(next)
    }

    // MARK: Calls

    /// Probes every installed harness again.
    func refresh() async {
        guard let api, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        retry()
        let ids = harnesses.filter(\.installed).map(\.id)
        await withTaskGroup(of: (String, Result<Harness, Error>).self) { group in
            for id in ids {
                group.addTask {
                    do { return (id, .success(try await api.check(id))) } catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let harness):
                    failures[id] = nil
                    place(harness)
                case .failure(let error):
                    failures[id] = Self.sentence("Couldn’t check it.", error)
                }
            }
        }
    }

    /// The app came forward: probe again, at most once in half a minute.
    func refreshOnActivation(now: Date = .now) {
        guard api != nil, link == .live, now.timeIntervalSince(lastQuietCheck) > 30 else { return }
        lastQuietCheck = now
        Task { await refresh() }
    }

    /// Starts the harness's own sign-in or install command and shows its terminal.
    func start(_ purpose: HarnessSession.Purpose, _ id: String) async {
        guard let harness = harness(id), !busy.contains(id) else { return }
        guard let api else {
            // A fixture has no service: it shows the sheet over sample text.
            session = HarnessSession(harnessID: id, harnessName: harness.name, purpose: purpose,
                                     command: purpose == .login ? harness.login.display : harness.install.display,
                                     attachment: HarnessAttachment(harnessID: id, purpose: purpose.rawValue, socketPath: "", sessionID: "fixture"),
                                     fixture: HarnessFixture.terminal(harness, purpose))
            return
        }
        busy.insert(id)
        failures[id] = nil
        defer { busy.remove(id) }
        do {
            let attachment = try await api.start(id, purpose)
            session = HarnessSession(harnessID: id, harnessName: harness.name, purpose: purpose,
                                     command: purpose == .login ? harness.login.display : harness.install.display,
                                     attachment: attachment)
        } catch {
            failures[id] = Self.sentence(purpose == .login ? "Couldn’t start the sign-in." : "Couldn’t start the install.", error)
        }
    }

    /// The session's terminal ended, or the person closed the sheet. The service checks the
    /// harness when its command exits; the window asks once more so the list is never behind.
    func endSession(exitCode: Int32? = nil, lastLine: String? = nil) {
        guard let ended = session else { return }
        session = nil
        if let exitCode, exitCode != 0 {
            let reason = lastLine?.isEmpty == false ? lastLine! : "The terminal closed with exit code \(exitCode)"
            failures[ended.harnessID] = "The \(ended.purpose == .login ? "sign-in" : "install") terminal closed early. \(reason.hasSuffix(".") ? reason : reason + ".")"
        }
        guard let api else { return }
        let id = ended.harnessID
        Task {
            if let harness = try? await api.check(id) { self.place(harness) }
        }
    }

    func setEnabled(_ enabled: Bool, _ id: String) async {
        guard var settings = harness(id)?.settings, settings.enabled != enabled else { return }
        settings.enabled = enabled
        await save(settings, id)
    }

    func setDefaultModel(_ model: String, _ id: String) async {
        guard var settings = harness(id)?.settings, settings.defaultModel != model else { return }
        settings.defaultModel = model
        await save(settings, id)
    }

    /// Shows the choice at once and puts the earlier one back if the service refuses it.
    private func save(_ settings: Harness.Settings, _ id: String) async {
        guard let index = harnesses.firstIndex(where: { $0.id == id }) else { return }
        let earlier = harnesses[index].settings
        harnesses[index].settings = settings
        guard let api else { return }
        failures[id] = nil
        do {
            place(try await api.saveSettings(id, settings))
        } catch {
            if let index = harnesses.firstIndex(where: { $0.id == id }) { harnesses[index].settings = earlier }
            failures[id] = Self.sentence("Couldn’t save the setting.", error)
        }
    }

    /// Two sentences: what couldn't be done, then the service's reason.
    static func sentence(_ lead: String, _ error: Error) -> String {
        var reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return lead }
        reason = reason.prefix(1).uppercased() + reason.dropFirst()
        if let last = reason.last, !".!?".contains(last) { reason += "." }
        return "\(lead) \(reason)"
    }
}

// MARK: - For the page

/// What the Harnesses mode can ask for.
struct HarnessActions {
    var refresh: @MainActor () async -> Void = {}
    var retry: @MainActor () -> Void = {}
    var signIn: @MainActor (_ id: String) -> Void = { _ in }
    var install: @MainActor (_ id: String) -> Void = { _ in }
    var setEnabled: @MainActor (_ enabled: Bool, _ id: String) -> Void = { _, _ in }
    var setDefaultModel: @MainActor (_ model: String, _ id: String) -> Void = { _, _ in }
    var endSession: @MainActor (_ exitCode: Int32?, _ lastLine: String?) -> Void = { _, _ in }
}

/// The feed's state as the window shows it, and its intents.
struct HarnessesContext {
    var harnesses: [Harness] = []
    var link: HarnessFeed.Link = .live
    var alerts: [HarnessAlert] = []
    var busy = Set<String>()
    var failures: [String: String] = [:]
    var session: HarnessSession? = nil
    var isRefreshing = false
    var actions = HarnessActions()

    init() {}

    /// Reads the feed. Every property read here is observed by the view that calls it.
    @MainActor init(feed: HarnessFeed) {
        harnesses = feed.harnesses
        link = feed.link
        alerts = feed.alerts
        busy = feed.busy
        failures = feed.failures
        session = feed.session
        isRefreshing = feed.isRefreshing
        actions = HarnessActions(
            refresh: { await feed.refresh() },
            retry: { feed.retry() },
            signIn: { id in Task { await feed.start(.login, id) } },
            install: { id in Task { await feed.start(.install, id) } },
            setEnabled: { enabled, id in Task { await feed.setEnabled(enabled, id) } },
            setDefaultModel: { model, id in Task { await feed.setDefaultModel(model, id) } },
            endSession: { code, line in feed.endSession(exitCode: code, lastLine: line) })
    }

    var tally: HarnessTally { HarnessTally(harnesses) }

    /// Nothing was ever read and the service doesn't answer.
    var isUnavailable: Bool { link == .unavailable && harnesses.isEmpty }
    var isLoading: Bool { link == .connecting && harnesses.isEmpty }

    /// The harnesses a run can be started with, for the New run form: the managed ones that are
    /// turned on. Nil while nothing has been read, so a service without harness routes never
    /// holds a run back.
    var runHarnesses: [RunSetupCapabilities.RunHarness]? {
        guard !harnesses.isEmpty else { return nil }
        return harnesses.filter { $0.managed && $0.settings.enabled }.map {
            RunSetupCapabilities.RunHarness(id: $0.id, name: $0.name, isReady: $0.isReady,
                                         state: !$0.installed ? "Not installed" : $0.isReady ? "Signed in"
                                             : $0.auth.state == .signedIn ? "Can’t start runs" : "Not signed in",
                                         reason: $0.runBlocker.isEmpty ? nil : $0.runBlocker,
                                         canSignIn: $0.installed && $0.login.available && $0.auth.state != .signedIn)
        }
    }
}

// MARK: - Fixtures

/// FIXTURE ONLY. The sample list behind the design preview and the headless pictures.
enum HarnessFixture {
    static let now = Date(timeIntervalSince1970: 1_795_732_800)   // 2026-11-26 22:40 UTC

    static var harnesses: [Harness] {
        func make(_ id: String, _ name: String, _ vendor: String, group: Harness.Group = .vendor, kind: Harness.Kind = .agent,
                  _ edit: (inout Harness) -> Void = { _ in }) -> Harness {
            var harness = Harness(id: id, name: name)
            harness.vendor = vendor
            harness.group = group
            harness.kind = kind
            harness.auth.state = .notInstalled
            harness.checkedAt = now
            edit(&harness)
            return harness
        }
        func installed(_ harness: inout Harness, _ executable: String, _ version: String) {
            harness.installed = true
            harness.executable = executable
            harness.version = version
        }
        return [
            make("claude", "Claude Code", "Anthropic") {
                installed(&$0, "/Users/me/.local/bin/claude", "2.1.332")
                $0.managed = true
                $0.verified = true
                $0.auth = Harness.Auth(state: .signedIn, account: "me@example.com", plan: "max", method: "claude.ai",
                                       expiresAt: now.addingTimeInterval(26 * 86_400 + 40_500), source: .statusCommand)
                $0.acp = Harness.ACP(adapter: "claude-agent-acp", installed: true, mode: .acp)
                $0.install = Harness.Command(available: true, display: "npm install -g @anthropic-ai/claude-code")
                $0.login = Harness.Command(available: true, display: "claude auth login")
                $0.models = ["opus", "sonnet", "haiku"]
                $0.settings.defaultModel = "opus"
            },
            // Signed in by its status command's exit code: it names no account.
            make("codex", "Codex", "OpenAI") {
                installed(&$0, "/opt/homebrew/bin/codex", "0.58.0")
                $0.managed = true
                $0.verified = true
                $0.auth = Harness.Auth(state: .signedIn, method: "ChatGPT", source: .statusCommand,
                                       detail: "codex login status exited 0.")
                $0.acp = Harness.ACP(adapter: "codex-acp", installed: false, mode: .adapterMissing)
                $0.runBlocker = "Codex has no dedicated Agent Commander profile on this Mac."
                $0.install = Harness.Command(available: true, display: "npm install -g @openai/codex")
                $0.login = Harness.Command(available: true, display: "codex login")
                $0.models = ["gpt-5.2-codex", "gpt-5.2"]
            },
            make("opencode", "OpenCode", "SST", group: .openSource) {
                installed(&$0, "/opt/homebrew/bin/opencode", "1.0.134")
                $0.verified = true
                $0.auth = Harness.Auth(state: .signedOut, source: .statusCommand, detail: "No provider is signed in.")
                $0.acp = Harness.ACP(adapter: "opencode", installed: true, mode: .acp)
                $0.install = Harness.Command(available: true, display: "brew install sst/tap/opencode")
                $0.login = Harness.Command(available: true, display: "opencode auth login")
            },
            make("copilot", "GitHub Copilot CLI", "GitHub") {
                installed(&$0, "/opt/homebrew/bin/copilot", "0.0.354")
                $0.auth = Harness.Auth(state: .signedIn, account: "octo-me", source: .credentialFile)
                $0.acp = Harness.ACP(adapter: "", installed: false, mode: .legacy)
                $0.install = Harness.Command(available: true, display: "npm install -g @github/copilot")
                $0.login = Harness.Command(available: true, display: "copilot login")
            },
            make("ollama", "Ollama", "Ollama", group: .runner, kind: .runner) {
                installed(&$0, "/usr/local/bin/ollama", "0.12.11")
                $0.verified = true
                $0.auth = Harness.Auth(state: .notRequired)
                $0.install = Harness.Command(available: true, display: "brew install ollama")
                $0.models = ["qwen3-coder:30b", "llama3.3"]
            },
            make("amp", "Amp", "Sourcegraph") {
                installed(&$0, "/opt/homebrew/bin/amp", "0.0.1763")
                $0.auth = Harness.Auth(state: .unknown, source: .none,
                                       detail: "Amp keeps its sign-in where Agent Commander can’t read it. Run amp to see whether it is signed in.")
                $0.install = Harness.Command(available: true, display: "npm install -g @sourcegraph/amp")
                $0.login = Harness.Command(available: true, display: "amp login")
            },
            make("gemini", "Gemini CLI", "Google") {
                $0.install = Harness.Command(available: true, display: "npm install -g @google/gemini-cli")
                $0.login = Harness.Command(available: true, display: "gemini")
                $0.acp = Harness.ACP(adapter: "gemini --experimental-acp", installed: false, mode: .acp)
            },
            make("cursor-agent", "Cursor Agent", "Anysphere", group: .ide) {
                $0.install = Harness.Command(available: true, display: "curl https://cursor.com/install -fsS | bash")
                $0.login = Harness.Command(available: true, display: "cursor-agent login")
            },
            make("aider", "Aider", "Aider", group: .openSource) {
                $0.install = Harness.Command(available: true, display: "pipx install aider-chat")
            },
            make("goose", "Goose", "Block", group: .openSource) {
                $0.install = Harness.Command(available: true, display: "brew install block-goose-cli")
                $0.login = Harness.Command(available: true, display: "goose configure")
                $0.acp = Harness.ACP(adapter: "goose acp", installed: false, mode: .acp)
            },
            make("lmstudio", "LM Studio", "Element Labs", group: .runner, kind: .runner) {
                $0.install = Harness.Command(available: false, display: "")
                $0.website = "https://lmstudio.ai"
            }
        ]
    }

    @MainActor static func feed() -> HarnessFeed { HarnessFeed(fixture: harnesses) }

    /// What a fixture's terminal sheet shows in place of a live session.
    static func terminal(_ harness: Harness, _ purpose: HarnessSession.Purpose) -> String {
        let command = purpose == .login ? harness.login.display : harness.install.display
        let body = purpose == .login
            ? "Opening your browser to sign in…\r\n\r\nIf it didn't open, visit:\r\n  https://example.com/device\r\n\r\nPaste the code here: "
            : "Installing \(harness.name)…\r\n"
        return "$ \(command)\r\n\r\n\(body)"
    }
}
