import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The Add server form's Tailnet band (design/COMMANDER-NETWORK-TAILNET.md, "Device side: the tray
// UI"). Every tailnet, relay and login address here is made up. No test runs `tailscale`, reaches
// a network or touches the real helper.

@MainActor @Suite struct MultiplayerTailnetTests {

    /// A model on the fixture with its own state file and its own tailnet start, each named in a
    /// launcher so tests can run side by side.
    static func fixtureModel(_ start: String, poll: Duration = .milliseconds(40)) async throws -> MultiplayerModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("multiplayer-tailnet-\(start)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launcher = folder.appendingPathComponent("fixture")
        let script = """
        #!/bin/sh
        COMMANDER_NETWORK_FIXTURE_STATE='\(folder.path)/state.json' COMMANDER_NETWORK_FIXTURE_TAILNET='\(start)' \
        exec '\(MultiplayerRenderTests.fixture.path)' "$@"

        """
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let model = MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: launcher)),
                                     usesFixtureHelper: true, steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     tailnetPoll: poll)
        model.open()
        await model.settle()
        model.startAddServer()
        model.tailnet.formAppeared()
        await model.settle()
        return model
    }

    /// Waits for the login poll to bring the model to `running`, or gives up.
    static func waitUntilRunning(_ model: MultiplayerModel) async throws {
        for _ in 0..<200 {
            await model.tailnet.settle()
            if case .running(_, .some, _) = model.tailnet.phase { return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: Contract

    @Test func tracksTheTailnetVerbs() {
        #expect(MultiplayerVerb.tailnetStatus.arguments == ["tray", "tailnet-status"])
        #expect(Set(["tailnet-status", "tailnet-join", "tailnet-relays"])
            .isSubset(of: Set(MultiplayerVerb.allCases.map(\.rawValue))))
    }

    @Test func readsAStatusWithMissingKeys() throws {
        let decoder = JSONDecoder()
        let short = try decoder.decode(MultiplayerTailnetStatus.self,
                                       from: Data(#"{"state":"needsLogin","authURL":"https://login.tail.example/a/1"}"#.utf8))
        #expect(short.installed && short.loginPending && !short.running)
        #expect(short.loginPage?.absoluteString == "https://login.tail.example/a/1")

        let missing = try decoder.decode(MultiplayerTailnetStatus.self, from: Data(#"{"installed":false,"self":null}"#.utf8))
        #expect(!missing.installed && !missing.running && missing.node == nil)

        let empty = try decoder.decode(MultiplayerTailnetStatus.self, from: Data("{}".utf8))
        #expect(!empty.installed && !empty.loginPending && empty.authURL.isEmpty)

        let odd = try decoder.decode(MultiplayerTailnetStatus.self,
                                     from: Data(#"{"installed":true,"authURL":"javascript:alert(1)","loginPending":true}"#.utf8))
        #expect(odd.loginPage == nil)

        let relays = try decoder.decode(MultiplayerTailnetRelayList.self,
                                        from: Data(#"{"relays":[{"dnsName":"build-relay.tail.example"}]}"#.utf8)).relays
        #expect(relays.first?.name == "build-relay")
        #expect(relays.first?.url == "https://build-relay.tail.example")
        #expect(relays.first?.added == false && relays.first?.online == false)
        #expect(try decoder.decode(MultiplayerTailnetRelayList.self, from: Data("{}".utf8)).relays.isEmpty)
    }

    @Test func checksTheJoinDraft() {
        var draft = MultiplayerTailnetDraft()
        #expect(!draft.canJoin && draft.loginServerProblem == nil)
        draft.loginServer = "headscale.example"
        #expect(draft.loginServerProblem != nil && !draft.canJoin)
        draft.loginServer = "http://headscale.example"
        #expect(draft.loginServerProblem != nil)
        draft.loginServer = " https://headscale.example "
        #expect(draft.loginServerProblem == nil && draft.canJoin)
        draft.method = .authKey
        #expect(!draft.canJoin)
        draft.authKey = "fixture-key"
        #expect(draft.canJoin)
    }

    // MARK: States

    @Test func listsRelaysAndChecksTheChosenOne() async throws {
        let model = try await Self.fixtureModel("running")
        guard case .running(let name, let relays?, nil) = model.tailnet.phase else {
            Issue.record("expected a running tailnet, got \(model.tailnet.phase)")
            return
        }
        #expect(name == "fixture-lab")
        #expect(relays.map(\.name) == ["build-relay", "attic-relay", "studio-relay"])
        let added = try #require(relays.first { $0.added })
        let build = try #require(relays.first { $0.name == "build-relay" })
        #expect(added.name == "studio-relay")

        // A relay already in the list is not chosen.
        #expect(model.chooseRelay(added) == nil)
        #expect(model.serverDraft.address.isEmpty && model.currentProbe == .idle)

        // Choosing one fills the address and runs the same check as the Check server button.
        await model.chooseRelay(build)?.value
        #expect(model.serverDraft.address == "https://build-relay.tail.example")
        #expect(model.currentProbe.probe?.passed == true)
        #expect(MultiplayerTailnetBand.matches(model.serverDraft.address, build))
        #expect(MultiplayerTailnetBand.matches("build-relay.tail.example:443", build))
        #expect(!MultiplayerTailnetBand.matches("", build))
        model.tailnet.formDisappeared()
    }

    @Test func saysWhenTheCLIIsMissingOrNoRelayIsTagged() async throws {
        let missing = try await Self.fixtureModel("missing")
        #expect(missing.tailnet.phase == .missing)
        #expect(!missing.tailnet.isPolling)
        missing.tailnet.formDisappeared()

        let empty = try await Self.fixtureModel("empty")
        #expect(empty.tailnet.phase == .running(name: "fixture-lab", relays: [], failure: nil))
        empty.tailnet.formDisappeared()
    }

    @Test func aFailedReadLeavesTheAddressUsable() async throws {
        let model = try await Self.fixtureModel("error")
        guard case .failed(let message) = model.tailnet.phase else {
            Issue.record("expected a failed read, got \(model.tailnet.phase)")
            return
        }
        #expect(message.hasPrefix("Couldn’t check Tailscale."))
        model.serverDraft.address = "lab.example"
        #expect(model.canProbe)
        await model.runProbe()?.value
        #expect(model.currentProbe.probe?.passed == true)
        model.tailnet.formDisappeared()
    }

    @Test func joinsInTheBrowserAndPollsUntilRunning() async throws {
        let model = try await Self.fixtureModel("off")
        #expect(model.tailnet.phase == .signedOut)
        model.tailnet.draft.loginServer = "https://headscale.example"
        await model.tailnet.join(model.tailnet.draft)?.value
        #expect(model.tailnet.phase == .pending(URL(string: "https://login.tail.example/a/f1x7ur3c0de")))
        #expect(model.tailnet.isPolling)
        try await Self.waitUntilRunning(model)
        guard case .running(_, let relays?, _) = model.tailnet.phase else {
            Issue.record("expected the poll to reach a running tailnet, got \(model.tailnet.phase)")
            return
        }
        #expect(relays.count == 3)
        #expect(!model.tailnet.isPolling)
        model.tailnet.formDisappeared()
    }

    @Test func joinsWithAKeyAndDropsIt() async throws {
        let model = try await Self.fixtureModel("off")
        model.tailnet.draft = MultiplayerTailnetDraft(loginServer: "https://headscale.example", method: .authKey, authKey: "bad-key")
        await model.tailnet.join(model.tailnet.draft)?.value
        await model.tailnet.settle()
        #expect(model.tailnet.draft.authKey.isEmpty)
        #expect(model.tailnet.joinFailure?.hasPrefix("Couldn’t join the tailnet.") == true)
        #expect(model.tailnet.phase == .signedOut)

        model.tailnet.draft.authKey = "fixture-key"
        await model.tailnet.join(model.tailnet.draft)?.value
        await model.tailnet.settle()
        #expect(model.tailnet.draft.authKey.isEmpty && model.tailnet.joinFailure == nil)
        guard case .running = model.tailnet.phase else {
            Issue.record("expected a running tailnet, got \(model.tailnet.phase)")
            return
        }
        model.tailnet.formDisappeared()
    }

    @Test func stopsPollingWhenTheFormLeaves() async throws {
        let model = try await Self.fixtureModel("pending", poll: .seconds(3600))
        guard case .pending = model.tailnet.phase else {
            Issue.record("expected a pending login, got \(model.tailnet.phase)")
            return
        }
        #expect(model.tailnet.isPolling)
        model.tailnet.formDisappeared()
        #expect(!model.tailnet.isPolling)
        #expect(model.tailnet.refresh() == nil)
    }

    // MARK: Pictures

    /// Headless pictures of the Add server page in each tailnet state, when MULTIPLAYER_RENDER_DIR
    /// names a folder: `tailnet-<state>.png`.
    @Test(.enabled(if: multiplayerRenderDirectory != nil)) func drawsEveryTailnetState() async throws {
        let folder = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for start in ["running", "empty", "missing", "off", "pending", "error"] {
            let model = try await Self.fixtureModel(start, poll: .seconds(3600))
            try await MultiplayerRenderTests.write(model, "tailnet-\(start)", to: folder)
            model.tailnet.formDisappeared()
        }
    }
}
