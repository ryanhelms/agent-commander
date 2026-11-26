import AppKit
import Foundation
import SwiftUI

// HOSTING ON THIS MAC: the adapter, the model and the tray page.
// Runs the bundled `commander-relay host --json <action>` with no shell: `status` reads the
// host's state, `install` loads the relay's launch agent and `uninstall` removes it. The relay
// itself runs under launchd, so it keeps running after the app quits and after the next log in.
// The tray's Hosting page and the main window's toolbar both read `MultiplayerHostSummary`.

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

enum MultiplayerHostAction: String, Sendable { case status, setup, install, uninstall }

/// The process boundary. Tests substitute a scripted relay. `input` is JSON on stdin (`setup` only).
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

    @ObservationIgnored let control: (any MultiplayerRelayControl)?
    /// How often a start or a stop is checked while launchd brings the relay up or down.
    @ObservationIgnored private let settleInterval: Duration
    /// How many checks before a start that hasn't come up is reported.
    @ObservationIgnored private let settleChecks: Int
    @ObservationIgnored private var task: Task<Void, Never>?

    init(control: (any MultiplayerRelayControl)?, settle: Duration = .seconds(1), settleChecks: Int = 45) {
        self.control = control
        self.settleInterval = settle
        self.settleChecks = settleChecks
        if control == nil { summary.phase = .unavailable }
    }

    /// The bundled relay, or none in a build without it.
    static func live() -> MultiplayerHostModel {
        MultiplayerHostModel(control: MultiplayerRelayLocator.resolve().map { MultiplayerRelayProcess(executable: $0) })
    }

    var isWorking: Bool { task != nil }

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
