import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import AgentCommander

// Hosting on this Mac:
//   1. The relay's JSON reply decodes, and a refusal keeps the relay's own reason.
//   2. Start installs the launch agent and waits for the relay; Stop removes it.
//   3. A start that never comes up says where the log is and still offers Stop.
//   4. The toolbar's host menu offers the commands that fit the relay's state.

/// A relay whose replies are scripted per action, in order. The last reply repeats.
final class ScriptedRelay: MultiplayerRelayControl {
    private let state: Mutex<(script: [MultiplayerHostAction: [Result<MultiplayerHostReport, MultiplayerHostRefusal>]],
                              calls: [MultiplayerHostAction])>

    init(_ script: [MultiplayerHostAction: [Result<MultiplayerHostReport, MultiplayerHostRefusal>]]) {
        state = Mutex((script, []))
    }

    var calls: [MultiplayerHostAction] { state.withLock { $0.calls } }

    func run(_ action: MultiplayerHostAction) async throws -> MultiplayerHostReport {
        let reply = state.withLock { state -> Result<MultiplayerHostReport, MultiplayerHostRefusal>? in
            state.calls.append(action)
            guard var replies = state.script[action], let first = replies.first else { return nil }
            if replies.count > 1 { replies.removeFirst() }
            state.script[action] = replies
            return first
        }
        guard let reply else { throw MultiplayerHostRefusal(message: "unscripted \(action)") }
        return try reply.get()
    }
}

@MainActor @Suite struct MultiplayerHostingTests {
    static func report(_ state: MultiplayerHostReport.State, installed: Bool = false, pin: String? = nil) -> MultiplayerHostReport {
        MultiplayerHostReport(state: state, installed: installed, name: "studio",
                              url: "https://studio.tailnet.test:443", pin: pin,
                              dir: "/Users/me/Library/Application Support/Agent Commander/relay",
                              log: "/Users/me/Library/Application Support/Agent Commander/relay/logs/relay.err.log")
    }

    static let pin = "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    func settled(_ model: MultiplayerHostModel) async {
        for _ in 0..<200 where model.isWorking { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func decodesTheRelaysReplyAndItsRefusal() throws {
        let ok = Data(#"{"ok":true,"host":{"state":"running","installed":true,"name":"studio","url":"https://studio.test:443","pin":"sha256/x","dir":"/d","log":"/d/logs/relay.err.log"}}"#.utf8)
        let report = try MultiplayerRelayProcess.decode(ok)
        #expect(report.state == .running && report.installed && report.url == "https://studio.test:443" && report.pin == "sha256/x")

        let unconfigured = Data(#"{"ok":true,"host":{"state":"unconfigured","installed":false,"dir":"/d","log":"/d/logs/relay.err.log"}}"#.utf8)
        #expect(try MultiplayerRelayProcess.decode(unconfigured).state == .unconfigured)

        let refused = Data(#"{"ok":false,"error":"launchctl bootstrap: exit status 5"}"#.utf8)
        #expect(throws: MultiplayerHostRefusal(message: "launchctl bootstrap: exit status 5")) {
            try MultiplayerRelayProcess.decode(refused)
        }
        #expect(throws: MultiplayerHostRefusal.self) { try MultiplayerRelayProcess.decode(Data("not json".utf8)) }
    }

    @Test func startWaitsForTheRelayThenStopRemovesIt() async {
        let relay = ScriptedRelay([
            .status: [.success(Self.report(.stopped)), .success(Self.report(.starting, installed: true)),
                      .success(Self.report(.running, installed: true, pin: Self.pin)), .success(Self.report(.stopped))],
            .install: [.success(Self.report(.starting, installed: true))],
            .uninstall: [.success(Self.report(.stopped))],
        ])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1))
        model.refresh()
        await settled(model)
        #expect(model.summary.phase == .stopped && model.summary.canStart && !model.summary.canStop)

        model.start()
        #expect(model.summary.phase == .starting, "the press shows at once")
        await settled(model)
        #expect(model.summary.phase == .running && model.summary.pin == Self.pin && model.summary.failure == nil)
        #expect(model.summary.figure == "On" && model.summary.lamp == .on)

        model.stop()
        #expect(model.summary.phase == .stopping)
        await settled(model)
        #expect(model.summary.phase == .stopped)
        #expect(relay.calls.filter { $0 != .status } == [.install, .uninstall])
    }

    @Test func aStartThatNeverComesUpPointsAtTheLogAndOffersStop() async {
        let relay = ScriptedRelay([
            .status: [.success(Self.report(.stopped)), .success(Self.report(.starting, installed: true))],
            .install: [.success(Self.report(.starting, installed: true))],
        ])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1), settleChecks: 3)
        model.refresh()
        await settled(model)
        model.start()
        await settled(model)
        #expect(model.summary.phase == .starting && model.summary.canStop)
        #expect(model.summary.failure?.contains("relay.err.log") == true)
    }

    @Test func aRefusedStartKeepsTheRelaysReason() async {
        let relay = ScriptedRelay([
            .status: [.success(Self.report(.stopped))],
            .install: [.failure(MultiplayerHostRefusal(message: "launchctl bootstrap: exit status 5"))],
        ])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1))
        model.refresh()
        await settled(model)
        model.start()
        await settled(model)
        #expect(model.summary.phase == .stopped)
        #expect(model.summary.failure == "Couldn’t start the relay. Launchctl bootstrap: exit status 5.")
    }

    @Test func withoutTheRelayHelperHostingIsUnavailable() {
        let model = MultiplayerHostModel(control: nil)
        #expect(model.summary.phase == .unavailable)
        model.start()
        #expect(model.summary.phase == .unavailable && !model.isWorking)
    }

    @Test func addingTheHostedRelayFillsTheAddress() async {
        let relay = ScriptedRelay([.status: [.success(Self.report(.running, installed: true, pin: Self.pin))]])
        let network = MultiplayerModel(client: nil, relay: relay)
        network.host.refresh()
        await settled(network.host)
        #expect(network.hostedServer == nil)
        network.addHostedServer()
        #expect(network.route == .addServer)
        #expect(network.serverDraft.address == "https://studio.tailnet.test:443" && network.serverDraft.name == "studio")
    }

    static func subviews(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + subviews(of: $0) } }

    /// The host menu is one menu button named "Hosting" whose items fit the relay's state.
    @Test func hostMenuOffersCommandsForTheState() throws {
        _ = NSApplication.shared
        var stopped = false
        var host = MultiplayerHostSummary()
        host.phase = .running
        host.url = "https://studio.tailnet.test:443"
        host.pin = Self.pin
        let view = NSHostingView(rootView: ShellHostMenu(host: host, isSaved: false,
                                                         actions: ShellHostingActions(stop: { stopped = true }))
            .environment(\.theme, .console))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let button = try #require(Self.subviews(of: view).compactMap { $0 as? NSPopUpButton }.first)
        #expect(button.cell?.accessibilityLabel() == "Hosting")
        #expect(button.accessibilityIdentifier() == "shell-host")
        let titles = button.itemArray.dropFirst().filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Stop hosting", "Copy relay address", "Add this relay as a server…", "Connect to a server…", "Hosting on this Mac…"])
        let stop = try #require(button.itemArray.first { $0.title == "Stop hosting" })
        _ = stop.target?.perform(stop.action, with: stop)
        #expect(stopped)
    }
}
