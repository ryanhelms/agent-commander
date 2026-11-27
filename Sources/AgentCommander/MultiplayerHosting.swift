import AppKit
import Foundation
import SwiftUI

// HOSTING ON THIS MAC: the adapter, the model and the tray page.
// Runs the bundled `commander-relay host --json <action>` with no shell: `status` reads the
// host's state, `install` loads the relay's launch agent and `uninstall` removes it. The relay
// itself runs under launchd, so it keeps running after the app quits and after the next log in.
// The tray's Hosting page and the main window's toolbar both read `MultiplayerHostSummary`.
// `listing` turns the relay's entry in the public directory on or off (design/COMMANDER-NETWORK-
// DISCOVERY.md, "Public directory"). The running relay reads the change within half a minute and
// writes back whether the directory took it; nothing here talks to the directory.

// MARK: - Values

/// One `commander-relay host --json` reply.
struct MultiplayerHostReport: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable { case unconfigured, stopped, starting, running }

    let state: State
    /// The launch agent is in ~/Library/LaunchAgents.
    let installed: Bool
    var name: String? = nil
    /// The address friends type, such as `https://studio.tailnet.ts.net:443`.
    var url: String? = nil
    /// The relay CA's `sha256/<base64 SPKI>` pin. Nil until the relay has started once.
    var pin: String? = nil
    let dir: String
    /// The relay's error log, where a start that failed explains itself.
    let log: String
    /// What this Mac suggests for a first-time setup. Only while unconfigured.
    var setup: MultiplayerHostSuggestion? = nil
    /// The relay's entry in the public directory. Nil until the host is configured.
    var listing: MultiplayerHostListing? = nil
}

/// The relay's entry in the public directory, as every host reply reports it. Every key may be
/// missing, and a block Commander can't read is an unlisted relay.
struct MultiplayerHostListing: Decodable, Equatable, Sendable {
    static let defaultDirectory = "https://directory.bytedesk.ai"

    /// The public https origin the relay is listed under. Empty while it isn't listed.
    var url = ""
    var directory = MultiplayerHostListing.defaultDirectory
    /// The directory took the relay's last registration.
    var listed = false
    /// Why it didn't, in the relay's words.
    var error = ""
    /// When the running relay last tried. Nil until it has.
    var checkedAt: Date? = nil

    private enum CodingKeys: String, CodingKey { case url, directory, listed, error, checkedAt }

    init(url: String = "", directory: String = MultiplayerHostListing.defaultDirectory, listed: Bool = false, error: String = "",
         checkedAt: Date? = nil) {
        self.url = url
        self.directory = directory
        self.listed = listed
        self.error = error
        self.checkedAt = checkedAt
    }

    init(from decoder: any Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func text(_ key: CodingKeys) -> String {
            (((try? values.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        url = text(.url)
        let named = text(.directory)
        if !named.isEmpty { directory = named }
        listed = ((try? values.decodeIfPresent(Bool.self, forKey: .listed)) ?? nil) ?? false
        error = text(.error)
        checkedAt = MultiplayerTime.parse(text(.checkedAt))
    }
}

/// The List publicly form: the switch as the person left it, and the address field.
struct MultiplayerHostListingDraft: Equatable, Sendable {
    /// What the person set the switch to, until the relay's own word agrees. Nil follows the relay.
    var wanted: Bool? = nil
    var address = ""
    /// The address of a listed relay is being changed.
    var isEditing = false

    var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the address can't be sent, when it can't. The relay checks it again and has the last word.
    var addressProblem: String? { Self.problem(trimmedAddress) }

    /// A public https origin: a host, a host and port, or either after `https://`.
    static func problem(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") { return "Use an https address. A relay can’t be listed over http." }
        var rest = lower.hasPrefix("https://") ? String(text.dropFirst(8)) : text
        while rest.hasSuffix("/") { rest.removeLast() }
        let shape = "Enter the relay’s public address, such as https://relay.example.org."
        guard !rest.isEmpty, !rest.contains(where: { $0.isWhitespace }),
              !rest.contains("/"), !rest.contains("@"), !rest.contains("?"), !rest.contains("#"), !rest.contains("://") else { return shape }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return shape }
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65_535).contains(port) else { return "The port after the colon must be a number from 1 to 65535." }
        }
        return nil
    }
}

/// Where the relay's public listing stands, for the Hosting page.
enum MultiplayerHostListingState: Equatable, Sendable {
    case off
    /// Turned on while the relay is stopped: nothing is listed until it runs.
    case waitsForRelay
    /// Turned on; the running relay hasn't said how its registration went yet.
    case checking
    case listed(since: Date?)
    case notListed(reason: String, at: Date?)

    var title: String {
        switch self {
        case .off: "Not listed"
        case .waitsForRelay: "Lists when the relay is running"
        case .checking: "Checking…"
        case .listed: "Listed"
        case .notListed: "Not listed"
        }
    }

    var lamp: MultiplayerLamp.Kind {
        switch self {
        case .off, .waitsForRelay: .off
        case .checking: .waiting
        case .listed: .on
        case .notListed: .error
        }
    }

    var tone: Tone {
        switch self {
        case .off, .waitsForRelay: .neutral
        case .checking: .focus
        case .listed: .working
        case .notListed: .failure
        }
    }

    /// The line under the state. Nil when the state's word says it all.
    func detail(now: Date) -> String? {
        switch self {
        case .off, .waitsForRelay:
            return nil
        case .checking:
            return "The relay registers within about 30 seconds."
        case .listed(let since):
            return MultiplayerMembershipRequest.age(since, now: now).map { "Confirmed with the directory \($0)." }
        case .notListed(let reason, let at):
            let tried = MultiplayerMembershipRequest.age(at, now: now).map { " Last tried \($0)." } ?? ""
            return Self.reason(reason) + tried
        }
    }

    /// The relay's reason as one plain sentence.
    static func reason(_ raw: String) -> String {
        let text = MultiplayerText.clean(raw, limit: 200, redact: true)
        let lower = text.lowercased()
        if lower.contains("not public") { return "The relay’s address isn’t public, so the directory can’t reach it." }
        if lower.contains("different key") { return "The relay at that address presents a different key. Check the address is this relay’s." }
        if lower.contains("cannot reach") || lower.contains("can't reach") || lower.contains("no such host")
            || lower.contains("timeout") || lower.contains("connection refused") {
            return "The relay can’t reach the directory right now. It keeps trying."
        }
        return text.isEmpty || text.contains("[redacted]") ? "The directory didn’t take the listing." : MultiplayerSentence.sentence(text)
    }
}

/// The relay's suggestion for a first-time setup: a name, the addresses it will serve, and the
/// Google Desktop client this Mac already signs in with (nil when it has none).
struct MultiplayerHostSuggestion: Decodable, Equatable, Sendable {
    var name = ""
    var hostnames: [String] = []
    var issuer = ""
    var clientId: String? = nil
}

/// The first-time setup form. Only the email is required; the rest start from the suggestion.
struct MultiplayerHostSetupDraft: Equatable, Sendable {
    var admin = ""
    var name = ""
    var clientID = ""

    var trimmedAdmin: String { admin.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A plain address check: something before and after one @, and a dot in the domain.
    var adminProblem: String? {
        let parts = trimmedAdmin.split(separator: "@", omittingEmptySubsequences: false)
        guard !trimmedAdmin.isEmpty else { return nil }
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !trimmedAdmin.contains(" ") else {
            return "Enter an email address, such as you@example.com."
        }
        return nil
    }
}

/// What hosting looks like now, as values for a view.
struct MultiplayerHostSummary: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// The first status read hasn't answered yet.
        case checking
        /// No relay helper in this build, or it couldn't be run.
        case unavailable
        /// The host has no host.json: it was never set up.
        case unconfigured
        case stopped
        /// The launch agent is loaded and the relay hasn't taken its lock yet.
        case starting
        case running
        case stopping
    }

    var phase = Phase.checking
    var name = ""
    var url = ""
    var pin = ""
    var dir = ""
    var log = ""
    /// What this Mac suggests for the first setup, while unconfigured.
    var suggestion: MultiplayerHostSuggestion?
    /// Why the last start, stop or read didn't go through.
    var failure: String?
    /// The relay's entry in the public directory. Nil until the host is configured.
    var listing: MultiplayerHostListing?
    /// The relay was just told to list, and hasn't reported a try since.
    var listingAwaitsCheck = false

    /// The public address the relay is listed under, or empty.
    var listedURL: String { listing?.url ?? "" }

    /// The directory's host, as the page names it: "directory.bytedesk.ai".
    var directoryName: String {
        MultiplayerServerAddress.host(listing?.directory ?? MultiplayerHostListing.defaultDirectory).multiplayerDisplay
    }

    /// The Hosting page offers List publicly once the relay is set up.
    var offersListing: Bool { listing != nil && phase != .unconfigured && phase != .unavailable && phase != .checking }

    var listingState: MultiplayerHostListingState {
        guard let listing, !listing.url.isEmpty else { return .off }
        guard phase == .running else { return .waitsForRelay }
        if listing.listed { return .listed(since: listing.checkedAt) }
        if listingAwaitsCheck || (listing.checkedAt == nil && listing.error.isEmpty) { return .checking }
        return .notListed(reason: listing.error, at: listing.checkedAt)
    }

    /// A word for the toolbar readout.
    var figure: String {
        switch phase {
        case .checking: "…"
        case .unavailable: "Unavailable"
        case .unconfigured: "Off"
        case .stopped: "Off"
        case .starting: "Starting"
        case .running: "On"
        case .stopping: "Stopping"
        }
    }

    /// The state label on the Hosting page.
    var title: String {
        switch phase {
        case .checking: "Checking this Mac…"
        case .unavailable: "Hosting isn’t available"
        case .unconfigured: "Ready to set up"
        case .stopped: "Relay stopped"
        case .starting: "Starting the relay…"
        case .running: "Relay running"
        case .stopping: "Stopping the relay…"
        }
    }

    var lamp: MultiplayerLamp.Kind {
        switch phase {
        case .running: .on
        case .starting, .stopping, .checking: .waiting
        case .unavailable: .error
        case .unconfigured, .stopped: .off
        }
    }

    var tone: Tone {
        switch phase {
        case .running: .working
        case .unavailable: .failure
        default: failure == nil ? .neutral : .failure
        }
    }

    var isBusy: Bool { phase == .starting || phase == .stopping || phase == .checking }
    /// Start works from a relay that was never set up too: the setup form goes first.
    var canStart: Bool { phase == .stopped || phase == .unconfigured }
    /// The setup needs a sign-in client ID typed in, because this Mac has none to reuse.
    var needsClientID: Bool { (suggestion?.clientId ?? "").isEmpty }
    /// Stop is offered while the launch agent is loaded, even if the relay keeps failing to start.
    var canStop: Bool { phase == .running || phase == .starting }

    /// What VoiceOver says for the toolbar readout.
    var spoken: String {
        switch phase {
        case .running: url.isEmpty ? "Hosting on" : "Hosting on, at \(url)"
        default: "Hosting, \(figure)"
        }
    }
}

// MARK: - Adapter

enum MultiplayerHostAction: String, Sendable {
    case status, setup, install, uninstall
    /// Lists the relay in the public directory under an https address, or with an empty one, unlists it.
    case listing
}

/// The process boundary. Tests substitute a scripted relay. `input` is JSON on stdin (`setup` and
/// `listing`).
protocol MultiplayerRelayControl: Sendable {
    func run(_ action: MultiplayerHostAction, input: Data) async throws -> MultiplayerHostReport
}

extension MultiplayerRelayControl {
    func run(_ action: MultiplayerHostAction) async throws -> MultiplayerHostReport {
        try await run(action, input: Data())
    }
}

/// The relay refused, with its own reason.
struct MultiplayerHostRefusal: Error, Equatable {
    let message: String
}

enum MultiplayerRelayLocator {
    /// Fixture override, honoured only in fixture mode, like COMMANDER_NETWORK_BIN.
    static let overrideVariable = "COMMANDER_RELAY_BIN"
    static let helperName = "commander-relay"

    /// The signed bundle's `Contents/MacOS/commander-relay`, or a fixture in a debug build's
    /// fixture mode. Nil when neither is there to run.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        bundleURL: URL = Bundle.main.bundleURL,
                        debugBuild: Bool = MultiplayerHelperLocator.buildAllowsFixture,
                        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        if MultiplayerHelperLocator.isFixtureMode(environment: environment, debugBuild: debugBuild),
           let raw = environment[overrideVariable], !raw.isEmpty {
            guard raw.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            return isExecutable(url.path(percentEncoded: false)) ? url : nil
        }
        let url = bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)", isDirectory: false)
        return isExecutable(url.path(percentEncoded: false)) ? url : nil
    }
}

/// The real `commander-relay` process.
struct MultiplayerRelayProcess: MultiplayerRelayControl {
    let executable: URL
    /// `launchctl bootstrap` and `bootout` answer in a second or two; the margin is for a slow disk.
    var timeout: Duration = .seconds(30)

    private struct Envelope: Decodable {
        let ok: Bool
        let host: MultiplayerHostReport?
        let error: String?
    }

    func run(_ action: MultiplayerHostAction, input: Data) async throws -> MultiplayerHostReport {
        let stop = MultiplayerStopSignal()
        let executable = executable
        let timeout = timeout
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MultiplayerHelperOutput, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try MultiplayerProcessRun.execute(executable: executable, arguments: ["host", "--json", action.rawValue],
                                                          input: input, timeout: timeout, limit: 64 * 1024, stop: stop)
                    })
                }
            }
        } onCancel: {
            stop.raise(.cancelled)
        }
        return try Self.decode(output.stdout)
    }

    static func decode(_ data: Data) throws -> MultiplayerHostReport {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw MultiplayerHostRefusal(message: "The relay helper gave a reply Commander can’t read.")
        }
        if envelope.ok, let host = envelope.host { return host }
        let reason = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw MultiplayerHostRefusal(message: reason.isEmpty ? "The relay helper didn’t say why." : reason)
    }
}

// MARK: - Model

/// This Mac's relay: its state, and the start and stop intents. The tray's Hosting page and the
/// main window's toolbar share the one instance on `MultiplayerModel`.
@Observable @MainActor
final class MultiplayerHostModel {
    private(set) var summary = MultiplayerHostSummary()
    /// The first-time setup form.
    var setupDraft = MultiplayerHostSetupDraft()
    /// The List publicly switch and its address field.
    var listingDraft = MultiplayerHostListingDraft()
    /// Why the last change to the listing wasn't taken, in the relay's words.
    private(set) var listingFailure: String?
    private(set) var isChangingListing = false

    @ObservationIgnored let control: (any MultiplayerRelayControl)?
    /// How often a start or a stop is checked while launchd brings the relay up or down.
    @ObservationIgnored private let settleInterval: Duration
    /// How many checks before a start that hasn't come up is reported.
    @ObservationIgnored private let settleChecks: Int
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The listing change in flight, then the reads that follow it until the relay has tried.
    @ObservationIgnored private var listingTask: Task<Void, Never>?
    /// How often, and how many times, the relay is read after it was told to list.
    @ObservationIgnored private let listingInterval: Duration
    @ObservationIgnored private let listingChecks: Int
    /// The relay's last try when it was told to list. A later one is its answer.
    @ObservationIgnored private var listingBaseline: Date?
    @ObservationIgnored private var awaitsListingCheck = false

    init(control: (any MultiplayerRelayControl)?, settle: Duration = .seconds(1), settleChecks: Int = 45,
         listingInterval: Duration = .seconds(5), listingChecks: Int = 18) {
        self.control = control
        self.settleInterval = settle
        self.settleChecks = settleChecks
        self.listingInterval = listingInterval
        self.listingChecks = listingChecks
        if control == nil { summary.phase = .unavailable }
    }

    /// The bundled relay, or none in a build without it.
    static func live() -> MultiplayerHostModel {
        MultiplayerHostModel(control: MultiplayerRelayLocator.resolve().map { MultiplayerRelayProcess(executable: $0) })
    }

    var isWorking: Bool { task != nil || listingTask != nil }

    // MARK: List publicly

    /// The switch: what the person set, or the relay's own word.
    var listsPublicly: Bool { listingDraft.wanted ?? !summary.listedURL.isEmpty }

    /// The address differs from the one the relay lists under, so it can be sent.
    var canList: Bool {
        let address = listingDraft.trimmedAddress
        return control != nil && !isChangingListing && summary.offersListing && listsPublicly
            && !address.isEmpty && listingDraft.addressProblem == nil && address != summary.listedURL
    }

    /// The switch moved. Turning it on shows the address field and sends nothing yet; turning it
    /// off unlists a listed relay at once.
    func setListsPublicly(_ on: Bool) {
        listingFailure = nil
        if on {
            listingDraft.wanted = true
            if listingDraft.address.isEmpty { listingDraft.address = summary.listedURL }
        } else if summary.listedURL.isEmpty {
            listingDraft = MultiplayerHostListingDraft()
        } else {
            listingDraft.wanted = false
            sendListing(url: "")
        }
    }

    /// Opens the address field on a listed relay, starting from the address it lists under.
    func editListingAddress() {
        listingFailure = nil
        listingDraft = MultiplayerHostListingDraft(wanted: nil, address: summary.listedURL, isEditing: true)
    }

    func cancelListingEdit() {
        listingFailure = nil
        listingDraft = MultiplayerHostListingDraft()
    }

    /// The address field shows: the relay isn't listed under one yet, or its address is being changed.
    var showsListingField: Bool { listsPublicly && (summary.listedURL.isEmpty || listingDraft.isEditing) }

    /// Lists the relay under the address in the field. The relay checks the address itself.
    func list() {
        guard canList else { return }
        sendListing(url: listingDraft.trimmedAddress)
    }

    private func sendListing(url: String) {
        guard let control, !isChangingListing, let input = try? JSONEncoder().encode(["url": url]) else { return }
        listingTask?.cancel()
        isChangingListing = true
        listingFailure = nil
        let baseline = summary.listing?.checkedAt
        listingTask = Task {
            do {
                let report = try await control.run(.listing, input: input)
                self.listingBaseline = baseline
                self.awaitsListingCheck = !url.isEmpty
                self.apply(report)
                // The relay's word now agrees with the switch.
                self.listingDraft = MultiplayerHostListingDraft()
            } catch is CancellationError {
            } catch {
                self.listingFailure = MultiplayerSentence.join(url.isEmpty ? "Couldn’t take the relay off the directory."
                                                                           : "Couldn’t list the relay.", Self.message(error))
                // A refused turn-off leaves the relay listed, so the switch goes back on.
                if url.isEmpty { self.listingDraft.wanted = nil }
            }
            self.isChangingListing = false
            await self.followListing(control)
            self.listingTask = nil
        }
    }

    /// Reads the relay again until it says how its registration went, or the wait runs out.
    private func followListing(_ control: any MultiplayerRelayControl) async {
        var checks = 0
        while summary.listingState == .checking, checks < listingChecks {
            checks += 1
            try? await Task.sleep(for: listingInterval)
            if Task.isCancelled { return }
            if task == nil { await read(control) }
        }
        if awaitsListingCheck {
            // No answer in the time a registration takes: the relay's own report stands from here.
            awaitsListingCheck = false
            summary.listingAwaitsCheck = false
        }
    }

    func dismissListingFailure() { listingFailure = nil }

    /// Reads the host's state, unless a start or a stop is already doing so.
    func refresh() {
        guard let control, task == nil else { return }
        task = Task {
            await self.read(control)
            self.task = nil
        }
    }

    /// Start from the setup form: it needs an email, and a client ID where the Mac has none.
    var canSetUp: Bool {
        let draft = setupDraft
        return summary.phase == .unconfigured && task == nil && !draft.trimmedAdmin.isEmpty && draft.adminProblem == nil
            && (!summary.needsClientID || !draft.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Writes the relay's configuration from the setup form, loads its launch agent, then waits
    /// until the relay answers, as Start does.
    func setUp() {
        guard let control, canSetUp else { return }
        var payload: [String: String] = ["admin": setupDraft.trimmedAdmin]
        let name = setupDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { payload["name"] = name }
        let clientID = setupDraft.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clientID.isEmpty { payload["clientId"] = clientID }
        guard let input = try? JSONEncoder().encode(payload) else { return }
        summary.failure = nil
        summary.phase = .starting
        task = Task {
            do {
                self.apply(try await control.run(.setup, input: input))
                await self.settle(control, until: .running)
            } catch {
                await self.read(control)
                self.summary.failure = MultiplayerSentence.join("Couldn’t set up the relay.", Self.message(error))
            }
            self.task = nil
        }
    }

    /// Loads the relay's launch agent, then waits until the relay answers or the wait runs out.
    /// A relay that was never set up goes through the setup form instead.
    func start() {
        if summary.phase == .unconfigured { return setUp() }
        guard let control, task == nil, summary.phase == .stopped else { return }
        summary.failure = nil
        summary.phase = .starting
        task = Task {
            do {
                self.apply(try await control.run(.install))
                await self.settle(control, until: .running)
            } catch {
                await self.read(control)
                self.summary.failure = MultiplayerSentence.join("Couldn’t start the relay.", Self.message(error))
            }
            self.task = nil
        }
    }

    /// Unloads and removes the launch agent. The relay's data stays for the next start.
    func stop() {
        guard let control, task == nil, summary.canStop else { return }
        summary.failure = nil
        summary.phase = .stopping
        task = Task {
            do {
                self.apply(try await control.run(.uninstall))
                await self.settle(control, until: .stopped)
            } catch {
                await self.read(control)
                self.summary.failure = MultiplayerSentence.join("Couldn’t stop the relay.", Self.message(error))
            }
            self.task = nil
        }
    }

    func dismissFailure() { summary.failure = nil }

    private func read(_ control: any MultiplayerRelayControl) async {
        do {
            apply(try await control.run(.status))
        } catch is CancellationError {
        } catch {
            summary.phase = .unavailable
            summary.failure = MultiplayerSentence.join("Couldn’t read this Mac’s relay.", Self.message(error))
        }
    }

    /// Checks again until the relay reaches `goal`. A start that never comes up is reported with
    /// where its log is; the launch agent stays loaded, so Stop is still offered.
    private func settle(_ control: any MultiplayerRelayControl, until goal: MultiplayerHostSummary.Phase) async {
        var checks = 0
        while summary.phase != goal, checks < settleChecks {
            checks += 1
            try? await Task.sleep(for: settleInterval)
            if Task.isCancelled { return }
            await read(control)
            if summary.phase == .unavailable { return }
        }
        if goal == .running, summary.phase != .running {
            summary.failure = "The relay hasn’t started yet. Its log is at \(summary.log)."
        }
    }

    private func apply(_ report: MultiplayerHostReport) {
        var next = MultiplayerHostSummary(failure: summary.failure)
        switch report.state {
        case .unconfigured: next.phase = .unconfigured
        case .stopped: next.phase = .stopped
        case .starting: next.phase = .starting
        case .running: next.phase = .running
        }
        // While a stop waits for launchd, the relay still holds its lock for a moment.
        if summary.phase == .stopping, report.state != .stopped { next.phase = .stopping }
        next.name = report.name ?? ""
        next.url = report.url ?? ""
        next.pin = report.pin ?? ""
        next.dir = report.dir
        next.log = report.log
        next.suggestion = report.setup
        next.listing = report.listing
        // The relay has tried since it was told to list, or isn't asked to list any more.
        if awaitsListingCheck, let listing = report.listing,
           listing.url.isEmpty || listing.listed || (listing.checkedAt != nil && listing.checkedAt != listingBaseline) {
            awaitsListingCheck = false
        }
        next.listingAwaitsCheck = awaitsListingCheck && report.listing != nil
        if let setup = report.setup, setupDraft.name.isEmpty { setupDraft.name = setup.name }
        summary = next
    }

    private static func message(_ error: any Error) -> String {
        if let refusal = error as? MultiplayerHostRefusal { return refusal.message }
        return MultiplayerFailure.from(error).message
    }
}

// MARK: - Organisms

/// The tray's Hosting page: what hosting is, this Mac's relay and its address, and what to do
/// next. Start and Stop are in the tray's footer.
struct MultiplayerHostingPage: View {
    let host: MultiplayerHostSummary
    /// The first-time setup form, shown while the relay was never set up.
    @Binding var setup: MultiplayerHostSetupDraft
    /// The saved server whose pin is this relay's, once the person has added it.
    let savedServer: String?
    /// List publicly, where the relay helper offers it. Nil leaves the band out.
    var listing: MultiplayerHostListingBand? = nil
    let onDismissFailure: () -> Void

    var body: some View {
        if let failure = host.failure {
            MultiplayerBand {
                MultiplayerBanner(kind: .failure, message: failure, onDismiss: onDismissFailure)
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Run a relay on this Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text("One relay process runs under launchd with its own bundled PostgreSQL and embedded NATS. Nothing else to install, and no Docker. It keeps running after you quit Commander or log in again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerStateLabel(lamp: host.lamp, text: host.title, tone: host.tone, pulses: host.phase == .running)
                status
            }
        }
        if host.phase == .running || host.phase == .starting {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    step(1, savedServer == nil
                         ? "Add this relay here with Add server. It made its own certificate, so check the fingerprint above matches before you save."
                         : "This relay is saved here as \(savedServer ?? "").", passed: savedServer == nil ? nil : true)
                    step(2, "Give friends the same address. They pin the certificate when they add the server.", passed: nil)
                }
            }
        }
        if let listing, host.offersListing { listing }
    }

    @ViewBuilder private var status: some View {
        switch host.phase {
        case .checking, .stopping:
            EmptyView()
        case .unavailable:
            line("This build of Commander has no relay helper. Build the app with make app to host from here.")
        case .unconfigured:
            setupForm
        case .stopped:
            line(host.name.isEmpty ? "Start hosting to run the relay now and each time you log in."
                                   : "Start hosting to run \(host.name) now and each time you log in.")
            address
        case .starting, .running:
            address
        }
    }

    /// The first start's form: your email makes you the relay's admin. The name and the sign-in
    /// client start from what this Mac suggests.
    @ViewBuilder private var setupForm: some View {
        line("Enter your email and press Start hosting. You become the relay’s first admin, and friends sign in with Google.")
        MultiplayerField(label: "Your email", hint: "Only you can change who joins until you add other admins.",
                         problem: setup.adminProblem) {
            MultiplayerTextField(label: "Your email", placeholder: "you@example.com", text: $setup.admin)
        }
        MultiplayerField(label: "Relay name", hint: "Friends see this name when they add the server.") {
            MultiplayerTextField(label: "Relay name", placeholder: host.suggestion?.name ?? "My relay", text: $setup.name)
        }
        if host.needsClientID {
            MultiplayerField(label: "Google sign-in client ID",
                             hint: "This Mac has no Google Desktop client yet. Paste the client ID your relay admin gave you.") {
                MultiplayerTextField(label: "Google sign-in client ID", placeholder: "….apps.googleusercontent.com",
                                     text: $setup.clientID, monospaced: true)
            }
        }
        if let first = host.suggestion?.hostnames.first {
            line("Friends reach it at \(first).")
        }
    }

    @ViewBuilder private var address: some View {
        if !host.url.isEmpty {
            field("Address") {
                Text(host.url)
                    .font(MultiplayerTheme.mono)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .textSelection(.enabled)
                    .accessibilityLabel("Address \(host.url)")
            }
        }
        if !host.pin.isEmpty {
            field("Fingerprint") { MultiplayerFingerprintText(fingerprint: host.pin) }
        } else if host.phase != .running {
            line("The fingerprint appears after the relay’s first start.")
        }
    }

    private func field<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(MultiplayerTheme.label)
                .foregroundStyle(.inkSecondary)
                .accessibilityHidden(true)
            value()
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(MultiplayerTheme.sub)
            .foregroundStyle(.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ text: String, passed: Bool?) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            MultiplayerStepMark(number: number, passed: passed)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(MultiplayerTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// List publicly, on the Hosting page: a switch, the public https address the relay is listed
/// under, the directory it uses, and whether the directory has it. Off until the person turns it on.
struct MultiplayerHostListingBand: View {
    let host: MultiplayerHostSummary
    @Binding var draft: MultiplayerHostListingDraft
    /// The switch: what the person set, or the relay's own word.
    let isOn: Bool
    /// The address field shows, and whether what is in it can be sent.
    let showsField: Bool
    let canList: Bool
    let isChanging: Bool
    /// Why the last change wasn't taken.
    let failure: String?
    let now: Date
    let onSet: (Bool) -> Void
    let onList: () -> Void
    let onEdit: () -> Void
    let onCancelEdit: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let state = host.listingState
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Text("List publicly")
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                    if isChanging { MultiplayerSpinner() }
                    Toggle("List publicly", isOn: Binding(get: { isOn }, set: onSet))
                        .toggleStyle(MultiplayerSwitchStyle())
                        .disabled(isChanging)
                        .accessibilityHint("Adds this relay to the public directory, or takes it off")
                }
                .frame(minHeight: theme.space.controlHeight)
                line("Lists this relay’s name, address, fingerprint and how it admits people at \(host.directoryName), so people off your network can find it. The directory never sees accounts or members.")
                if isOn {
                    if showsField {
                        MultiplayerField(label: "Public address",
                                         hint: "The https address people outside your network reach this relay at.",
                                         problem: draft.addressProblem) {
                            MultiplayerTextField(label: "Public address", placeholder: "https://relay.example.org", text: $draft.address,
                                                 monospaced: true)
                                .disabled(isChanging)
                                .onSubmit { if canList { onList() } }
                        }
                        HStack(spacing: Space.s) {
                            Button(host.listedURL.isEmpty ? "List relay" : "Update address", action: onList)
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(!canList)
                            if draft.isEditing {
                                Button("Cancel", action: onCancelEdit)
                                    .buttonStyle(MultiplayerTrayButtonStyle())
                                    .disabled(isChanging)
                            }
                        }
                    }
                    if !host.listedURL.isEmpty {
                        if !showsField {
                            value("Public address", host.listedURL)
                        }
                        value("Directory", host.directoryName)
                        VStack(alignment: .leading, spacing: 3) {
                            MultiplayerStateLabel(lamp: state.lamp, text: state.title, tone: state.tone, pulses: state == .checking)
                            if let detail = state.detail(now: now) { line(detail) }
                        }
                        .accessibilityElement(children: .combine)
                        if !showsField {
                            Button("Change address…", action: onEdit)
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(isChanging)
                        }
                    }
                }
                if let failure {
                    Text(failure)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(MultiplayerTheme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(MultiplayerTheme.label)
                .foregroundStyle(.inkSecondary)
                .accessibilityHidden(true)
            Text(text.multiplayerDisplay)
                .font(MultiplayerTheme.mono)
                .foregroundStyle(MultiplayerTheme.foreground)
                .textSelection(.enabled)
                .accessibilityLabel("\(label) \(text)")
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(MultiplayerTheme.sub)
            .foregroundStyle(.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension MultiplayerHostListingBand {
    /// The band on the model's own values and intents.
    @MainActor init(model: MultiplayerHostModel, now: Date) {
        self.init(host: model.summary, draft: Bindable(model).listingDraft, isOn: model.listsPublicly,
                  showsField: model.showsListingField, canList: model.canList, isChanging: model.isChangingListing,
                  failure: model.listingFailure, now: now,
                  onSet: { model.setListsPublicly($0) }, onList: { model.list() },
                  onEdit: { model.editListingAddress() }, onCancelEdit: { model.cancelListingEdit() })
    }
}

/// The Hosting page's footer actions: Start or Stop, then Add server with this relay's address.
struct MultiplayerHostingActions: View {
    let host: MultiplayerHostSummary
    let isSaved: Bool
    /// The setup form is complete, so Start can set the relay up first.
    var canSetUp = false
    let onStart: () -> Void
    let onStop: () -> Void
    let onCheck: () -> Void
    let onAddServer: () -> Void

    var body: some View {
        switch host.phase {
        case .unavailable:
            Button("Check again", action: onCheck)
                .buttonStyle(MultiplayerTrayButtonStyle())
        case .unconfigured:
            Button("Start hosting", action: onStart)
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .keyboardShortcut(canSetUp ? KeyboardShortcut.defaultAction : nil)
                .disabled(!canSetUp)
        case .checking:
            EmptyView()
        case .stopped:
            Button("Start hosting", action: onStart)
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .keyboardShortcut(.defaultAction)
        case .starting, .running, .stopping:
            Button(host.phase == .stopping ? "Stopping…" : "Stop hosting", action: onStop)
                .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                .disabled(!host.canStop)
            if !isSaved {
                Button("Add server", action: onAddServer)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(host.phase != .running || host.url.isEmpty)
            }
        }
    }
}

extension MultiplayerModel {
    /// The saved server that is this Mac's relay: the one pinned to the relay's certificate.
    var hostedServer: MultiplayerServerSummary? {
        let pin = host.summary.pin
        guard !pin.isEmpty else { return nil }
        return servers.first { $0.pin == pin }
    }

    /// Opens Add server with this Mac's relay address filled in.
    func addHostedServer() {
        let summary = host.summary
        guard !summary.url.isEmpty else { return startAddServer() }
        startAddServer()
        serverDraft.address = summary.url
        if !summary.name.isEmpty { serverDraft.name = summary.name }
    }

    /// The tray's footer note on the Hosting page.
    var hostingNote: String? {
        switch host.summary.phase {
        case .running: hostedServer == nil ? "Add it here to use it yourself." : "Running under launchd."
        case .stopped: "Starts again each time you log in, until you stop it."
        case .unconfigured: "Set up once. It then starts each time you log in."
        case .starting: "launchd is starting the relay."
        default: nil
        }
    }
}
