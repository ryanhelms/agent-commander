import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The Harnesses mode: reading the service's list, the navigation's counts, the alert when a
// sign-in lapses, and the run form's gate. `HARNESS_RENDER_DIR` names a folder for headless
// pictures of the fixture pages:
//
//     HARNESS_RENDER_DIR=design/demos/harnesses swift test --filter Harnesses

let harnessRenderDirectory = ProcessInfo.processInfo.environment["HARNESS_RENDER_DIR"]

@MainActor @Suite struct HarnessesTests {
    static let frame = """
    {"harnesses":[
      {"id":"claude","name":"Claude Code","vendor":"Anthropic","kind":"agent","group":"vendor","managed":true,"verified":true,
       "installed":true,"executable":"/Users/me/.local/bin/claude","version":"2.1.332",
       "auth":{"state":"signed_in","account":"me@example.com","plan":"max","method":"claude.ai",
               "expires_at":"2026-12-23T09:55:41Z","source":"status_command","detail":""},
       "acp":{"adapter":"claude-agent-acp","installed":true,"mode":"acp"},
       "install":{"available":true,"display":"npm install -g @anthropic-ai/claude-code"},
       "login":{"available":true,"display":"claude auth login"},
       "settings":{"enabled":true,"default_model":""},"models":["opus","sonnet"],
       "checked_at":"2026-11-26T22:40:00Z","changed":"auth"},
      {"id":"codex","name":"Codex","managed":true,"installed":true,"auth":{"state":"signed_in","source":"environment"},
       "acp":{"adapter":"codex-acp","installed":false,"mode":"adapter_missing"},"run_blocker":"No Codex profile."},
      {"id":"ollama","name":"Ollama","kind":"runner","group":"runner","installed":true,"auth":{"state":"not_required"}},
      {"id":"gemini","name":"Gemini CLI","installed":false,"auth":{"state":"not_installed"}},
      {"name":"No ID"}
    ]}
    """

    @Test func readsAListFrame() throws {
        let harnesses = try HarnessSnapshot.decode(Array(Self.frame.utf8))
        #expect(harnesses.map(\.id) == ["claude", "codex", "ollama", "gemini"])
        let claude = harnesses[0]
        #expect(claude.auth.state == .signedIn && claude.auth.account == "me@example.com" && claude.auth.expiresAt != nil)
        #expect(claude.acp.mode == .acp && claude.models == ["opus", "sonnet"] && claude.changed == "auth")
        #expect(claude.isReady && claude.state.title == "Signed in")
        let codex = harnesses[1]
        #expect(codex.auth.source == .environment && codex.acp.mode == .adapterMissing)
        #expect(codex.runBlocker == "No Codex profile." && !codex.isReady && codex.cantRun)
        #expect(harnesses[2].kind == .runner && harnesses[2].state.title == "No sign-in needed")
        #expect(harnesses[3].state.title == "Not installed")
        // A value the app doesn't know never fails the frame.
        let odd = try HarnessSnapshot.decode(Array(#"{"harnesses":[{"id":"x","installed":true,"auth":{"state":"new"},"acp":{"mode":"new"}}]}"#.utf8))
        #expect(odd.first?.auth.state == .unknown && odd.first?.acp.mode == .unsupported)
        #expect(try HarnessSnapshot.decode(Array(#"{"harnesses":null}"#.utf8)).isEmpty)
    }

    @Test func readsOneHarnessBareOrWrappedAndAnAttachment() throws {
        #expect(try HarnessSnapshot.decodeOne(Data(#"{"id":"claude","name":"Claude Code"}"#.utf8)).id == "claude")
        #expect(try HarnessSnapshot.decodeOne(Data(#"{"harness":{"id":"codex"}}"#.utf8)).id == "codex")
        let attachment = try HarnessSnapshot.decodeAttachment(
            Data(#"{"harness_id":"codex","purpose":"login","socket_path":"/tmp/tmux-501/ac-login","session_id":"$3"}"#.utf8))
        #expect(HarnessTerminalLaunch.arguments(for: attachment) == ["-S", "/tmp/tmux-501/ac-login", "attach-session", "-t", "$3"])
        #expect(throws: (any Error).self) { try HarnessSnapshot.decodeAttachment(Data("{}".utf8)) }
    }

    @Test func theStreamReaderSkipsHeartbeatsAndSays404() throws {
        var reader = HarnessStream.Reader()
        var outputs: [HarnessStream.Reader.Output] = []
        let body = ": heartbeat\n\ndata: {\"harnesses\":[{\"id\":\"claude\"}]}\n\n"
        for byte in Array(body.utf8) { if let output = try reader.consume(byte) { outputs.append(output) } }
        #expect(outputs.count == 1)
        if case .harnesses(let list)? = outputs.first { #expect(list.map(\.id) == ["claude"]) }
        var missing = HarnessStream.Reader()
        var said404 = false
        for byte in Array("\ncommander-http-status: 404\n".utf8) where try missing.consume(byte) == .unsupported { said404 = true }
        #expect(said404)
    }

    @Test func theModeListsItsPlacesAndCountsWhatNeedsSignIn() {
        let tally = HarnessTally(HarnessFixture.harnesses)
        #expect(tally.needsSignIn == 1 && tally.installed == 6 && tally.available == 5)
        #expect(tally.summary == "6 installed, 1 needs sign-in, 5 available")
        let navigation = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: HarnessPlace.installed,
                                              needsYou: 0, network: ShellNetwork(), harnesses: tally)
        let mode = navigation.modeItems[4]
        #expect(mode.mode.title == "Harnesses" && mode.isSelected && mode.hotCount == 1 && mode.shortcut == 5)
        #expect(navigation.modeItems[5].mode.id == LiveShell.settings && navigation.modeItems[5].shortcut == 6)
        #expect(navigation.contextSections.flatMap(\.items).map(\.place.title) == ["Needs sign-in", "Installed", "Available"])
        #expect(navigation.crumbs == ["Harnesses", "Installed"])
        // With nothing to sign in, the place leaves the list and the mode opens on Installed.
        var quiet = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: HarnessPlace.signIn,
                                         needsYou: 0, network: ShellNetwork())
        #expect(quiet.selection == HarnessPlace.installed && quiet.modeItems[4].hotCount == 0)
        quiet.apply(.selectMode("agents"))
        quiet.apply(.selectMode(HarnessPlace.mode))
        #expect(quiet.selection == HarnessPlace.installed)
        #expect(HarnessPlace.harnesses(HarnessFixture.harnesses, in: HarnessPlace.signIn).map(\.id) == ["opencode"])
        #expect(HarnessPlace.harnesses(HarnessFixture.harnesses, in: HarnessPlace.available).first?.group == .vendor)
    }

    @Test func aLapsedSignInRaisesOneAlertAndASignInClearsIt() {
        var list = HarnessFixture.harnesses
        let feed = HarnessFeed(fixture: list)
        var notified: [HarnessAlert] = []
        feed.notify = { notified.append($0) }
        // The first list raises nothing: OpenCode was never seen signed in.
        feed.apply(list)
        #expect(feed.alerts.isEmpty)
        list[0].auth.state = .signedOut
        feed.apply(list, now: HarnessFixture.now)
        feed.apply(list, now: HarnessFixture.now)
        #expect(feed.alerts.map(\.title) == ["Claude Code signed out"] && notified.count == 1)
        let inbox = LiveShell.inbox(pending: [], network: ShellNetwork(), now: HarnessFixture.now.addingTimeInterval(90),
                                    harnessAlerts: feed.alerts)
        #expect(inbox.items.first?.kind == .harnessSignIn && inbox.items.first?.verbs == [.signIn])
        #expect(inbox.items.first?.waiting == 90 && inbox.summary == "1 sign-in")
        #expect(HarnessAlert.harnessID(inboxID: inbox.items[0].id) == "claude")
        list[0].auth.state = .expired
        feed.apply(list)
        #expect(feed.alerts.count == 1)
        list[0].auth.state = .signedIn
        feed.apply(list)
        #expect(feed.alerts.isEmpty)
        list[1].auth.state = .expired
        feed.apply(list)
        #expect(feed.alerts.map(\.title) == ["Codex sign-in expired"] && notified.count == 2)
    }

    @Test func theRunFormHoldsAHarnessThatIsNotReady() {
        var list = HarnessFixture.harnesses
        var context = HarnessesContext()
        #expect(context.runHarnesses == nil, "nothing read: no run is held back")
        context.harnesses = list
        var setup = RunSetupCapabilities()
        setup.harnesses = context.runHarnesses
        // Managed and turned on: Claude Code is ready; Codex is signed in but blocked.
        #expect(setup.harnesses?.map(\.id) == ["claude", "codex"])
        #expect(setup.harnesses?[1].isReady == false && setup.harnesses?[1].reason?.contains("profile") == true)
        #expect(setup.harnesses?[1].canSignIn == false)
        #expect(setup.coordinatorBlock == nil)
        list[0].auth.state = .signedOut
        context.harnesses = list
        setup.harnesses = context.runHarnesses
        #expect(setup.harnesses?[0].state == "Not signed in" && setup.harnesses?[0].canSignIn == true)
        #expect(setup.coordinatorBlock != nil)
        // The list changes under the open form: signed in again, the block is gone.
        list[0].auth.state = .signedIn
        list[0].settings.enabled = false
        context.harnesses = list
        setup.harnesses = context.runHarnesses
        #expect(setup.harnesses?.map(\.id) == ["codex"] && setup.coordinatorBlock?.contains("turned off") == true)
    }

    @Test func aFixtureChangesItsSettingsInPlace() async {
        let feed = HarnessFixture.feed()
        await feed.setEnabled(false, "claude")
        await feed.setDefaultModel("sonnet", "claude")
        #expect(feed.harness("claude")?.settings == Harness.Settings(enabled: false, defaultModel: "sonnet"))
        await feed.start(.login, "opencode")
        #expect(feed.session?.title == "Sign in to OpenCode" && feed.session?.fixture != nil)
        feed.endSession(exitCode: 1, lastLine: "no sessions")
        #expect(feed.session == nil && feed.failures["opencode"]?.hasSuffix("no sessions.") == true)
    }

    @Test func theScenariosOpenOnTheirPlaces() {
        #expect(DesignPreviewScenario.harnesses.harnessPlace == HarnessPlace.installed)
        #expect(DesignPreviewScenario.harnessesAvailable.isShell && ShellConcept(scenario: .harnessesAvailable) == .modeRail)
        #expect(ShellPreviewState(scenario: .harnesses).selection == HarnessPlace.installed)
    }

    @Test(.enabled(if: harnessRenderDirectory != nil)) func drawsTheHarnessPages() async throws {
        let folder = URL(fileURLWithPath: try #require(harnessRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        func shell(_ scenario: DesignPreviewScenario, place: String? = nil, shown: String? = nil) -> some View {
            let state = ShellPreviewState(scenario: scenario)
            if let place { state.selection = place }
            state.harnessShown = shown
            return ShellPreviewPage(store: PreviewStore(scenario: scenario), state: state, chrome: .drawn)
        }
        try await ShellRenderTests.write(shell(.harnesses), "harnesses-installed", theme: .console, to: folder)
        try await ShellRenderTests.write(shell(.harnesses, shown: "codex"), "harnesses-codex-blocked", theme: .console, to: folder)
        try await ShellRenderTests.write(shell(.harnesses, shown: "copilot"), "harnesses-unverified", theme: .console, to: folder)
        try await ShellRenderTests.write(shell(.harnesses, place: HarnessPlace.signIn), "harnesses-needs-sign-in", theme: .console, to: folder)
        try await ShellRenderTests.write(shell(.harnessesAvailable), "harnesses-available", theme: .console, to: folder)
        try await ShellRenderTests.write(shell(.harnesses), "fit-1280-harnesses-installed", theme: .console, to: folder,
                                         size: NetworkFitTests.window)
        try await ShellRenderTests.write(shell(.harnesses), "harnesses-installed", theme: .blackGlass, to: folder)
        var missing = HarnessesContext()
        missing.link = .unavailable
        try await ShellRenderTests.write(
            ThemeCanvas { HarnessesPage(place: HarnessPlace.installed, crumbs: ["Harnesses", "Installed"], context: missing, shown: .constant(nil)) },
            "harnesses-unavailable", theme: .console, to: folder)
        try await ShellRenderTests.write(
            HarnessSessionSheet(session: HarnessSession(harnessID: "opencode", harnessName: "OpenCode", purpose: .login,
                                                        command: "opencode auth login",
                                                        attachment: HarnessAttachment(harnessID: "opencode", purpose: "login", socketPath: "", sessionID: "fixture"),
                                                        fixture: HarnessFixture.terminal(HarnessFixture.harnesses[2], .login))) { _, _ in },
            "harness-sign-in-sheet", theme: .console, to: folder, size: CGSize(width: 780, height: 560))
        var setup = RunSetupCapabilities()
        var list = HarnessFixture.harnesses
        list[0].auth.state = .signedOut
        var context = HarnessesContext()
        context.harnesses = list
        setup.harnesses = context.runHarnesses
        try await ShellRenderTests.write(
            NewRunView(connection: .online, draft: NewRunDraft(path: "/code/relay", task: "Tighten the retry budget."), projectName: "Relay",
                       capabilities: setup, create: { _, _, _, _ in }, cancel: {}, signIn: { _ in }),
            "new-run-gate", theme: .console, to: folder)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("harnesses-installed-console.png").path))
    }
}
