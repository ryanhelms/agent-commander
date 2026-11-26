import Foundation
import Testing
@testable import AgentCommander

// The server list, health check and tray model (design/COMMANDER-NETWORK-INCREMENT-1.md).
// Every host, handle, ID and pin here is made up. No test reaches a network or the real helper.

enum MultiplayerServerFixture {
    /// SHA-256 of nothing in particular: thirty-two bytes counting up from zero, and from 0x80.
    static let pin = "sha256/" + Data((0..<32).map { UInt8($0) }).base64EncodedString()
    static let newPin = "sha256/" + Data((0..<32).map { UInt8($0 + 0x80) }).base64EncodedString()

    static func server(_ id: String, name: String, favorite: Bool = false, lastUsedAt: String? = nil,
                       state: String = "signedOut", pin: String = "", signedIn: Bool = false,
                       friendsOnline: Int = 0, incoming: Int = 0) -> String {
        let used = lastUsedAt.map { #","lastUsedAt":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","url":"https://\#(name).example","name":"\#(name)","favorite":\#(favorite),"autoConnect":true,"pin":"\#(pin)","state":"\#(state)","signedIn":\#(signedIn),"handle":"\#(signedIn ? "fixture-ada" : "")","error":"","friendsOnline":\#(friendsOnline),"incoming":\#(incoming)\#(used)}"#
    }

    static func servers(_ servers: String...) -> MultiplayerHelperOutput {
        MultiplayerFixture.output(#"{"ok":true,"data":{"servers":[\#(servers.joined(separator: ","))]}}"#)
    }

    static func probe(trusted: Bool = false, pin: String = MultiplayerServerFixture.pin, signIn: Bool = true) -> MultiplayerHelperOutput {
        MultiplayerFixture.output(#"""
        {"ok":true,"data":{"url":"https://lab.example:8443","steps":[
          {"step":"dns","ok":true,"detail":"100.64.0.1"},
          {"step":"tcp","ok":true,"detail":"100.64.0.1:8443 in 4 ms"},
          {"step":"tls","ok":true,"detail":"checked","pin":"\#(pin)","systemTrusted":\#(trusted)},
          {"step":"relay","ok":true,"detail":"commander-relay host"},
          {"step":"signin","ok":\#(signIn),"detail":"https://accounts.example","clientId":"fixture.apps.example","clientConfigured":\#(signIn)}
        ]}}
        """#)
    }

    static let home = server("s-home", name: "home", favorite: true, lastUsedAt: "2026-11-25T18:05:00Z",
                             state: "online", pin: pin, signedIn: true, friendsOnline: 1, incoming: 1)
    static let team = server("s-team", name: "team", lastUsedAt: "2026-11-25T19:00:00Z", state: "certChanged", pin: pin)

    static let homeStatus = MultiplayerFixture.output(#"""
    {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada",
     "friends":[{"handle":"fixture-zed","online":false},{"handle":"fixture-cy","online":true},{"handle":"fixture-bo","online":true}],
     "incoming":[{"id":"in-1","handle":"fixture-dee"}],
     "resources":[{"id":"res-1","name":"relay","kind":"repo","actions":["issue.read"]}]}}
    """#)

    @MainActor static func model(_ helper: ScriptedMultiplayerHelper) -> MultiplayerModel {
        MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600))
    }
}

@Suite struct MultiplayerServerContractTests {
    @Test func tracksTheNewVerbs() {
        #expect(MultiplayerVerb.serverProbe.arguments == ["tray", "server-probe"])
        #expect(MultiplayerVerb.servers.arguments == ["tray", "servers"])
        #expect(Set(["server-add", "server-update", "server-remove", "server-trust"])
            .isSubset(of: Set(MultiplayerVerb.allCases.map(\.rawValue))))
    }

    @Test func decodesTheContractSummary() throws {
        let json = #"""
        {"id":"s-3f2a9c1d","url":"https://ryan-mac.tail.internal","name":"ryan-mac",
         "favorite":true,"autoConnect":true,"pin":"sha256/AAAA","lastUsedAt":"2026-11-25T18:05:00Z",
         "state":"online","signedIn":true,"handle":"ryan","lastSeen":"2026-11-25T18:06:00Z","error":"",
         "friendsOnline":2,"incoming":1}
        """#
        let server = try JSONDecoder().decode(MultiplayerServerSummary.self, from: Data(json.utf8))
        #expect(server.id == "s-3f2a9c1d")
        #expect(server.state == .online)
        #expect(server.favorite && server.autoConnect && server.signedIn)
        #expect(server.handle == "ryan")
        #expect(server.friendsOnline == 2 && server.incoming == 1)
        #expect(server.lastUsedAt == MultiplayerTime.parse("2026-11-25T18:05:00Z"))
        #expect(server.host == "ryan-mac.tail.internal")

        let again = try JSONDecoder().decode(MultiplayerServerSummary.self, from: JSONEncoder().encode(server))
        #expect(again == server)
    }

    @Test func aSparseSummaryStillListsAndAnUnknownStateIsNeverOnline() throws {
        let json = #"{"id":"s-1","url":"https://lab.example:8443","state":"quarantined"}"#
        let server = try JSONDecoder().decode(MultiplayerServerSummary.self, from: Data(json.utf8))
        #expect(server.state == .unknown)
        #expect(server.displayName == "lab.example:8443")
        #expect(server.lastUsedAt == nil && !server.signedIn && server.pin.isEmpty)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MultiplayerServerSummary.self, from: Data(#"{"id":"s-1","url":"x"}"#.utf8))
        }
    }

    @Test func decodesAProbeAndReadsItsPin() throws {
        let probe = try #require(try MultiplayerEnvelope.decode(MultiplayerProbe.self, from: MultiplayerServerFixture.probe()))
        #expect(probe.steps.map(\.step) == ["dns", "tcp", "tls", "relay", "signin"])
        #expect(probe.passed)
        #expect(probe.stoppedAt == nil)
        #expect(probe.needsPinConfirmation)
        #expect(probe.pin == MultiplayerServerFixture.pin)
        #expect(probe.fingerprint?.hasPrefix("00:01:02:03") == true)
        #expect(probe.step(.signin)?.clientConfigured == true)

        let trusted = try #require(try MultiplayerEnvelope.decode(MultiplayerProbe.self, from: MultiplayerServerFixture.probe(trusted: true)))
        #expect(trusted.passed && !trusted.needsPinConfirmation && trusted.pin.isEmpty)
    }

    @Test func aFailedStepEndsTheProbe() throws {
        let json = #"{"url":"https://lab.example","steps":[{"step":"dns","ok":true,"detail":"100.64.0.1"},{"step":"tcp","ok":false,"detail":"refused"}]}"#
        let probe = try JSONDecoder().decode(MultiplayerProbe.self, from: Data(json.utf8))
        #expect(!probe.passed)
        #expect(probe.stoppedAt == .tcp)
        #expect(probe.step(.tls) == nil)

        let signIn = try #require(try MultiplayerEnvelope.decode(MultiplayerProbe.self, from: MultiplayerServerFixture.probe(signIn: false)))
        #expect(!signIn.passed && signIn.stoppedAt == .signin)
    }

    @Test func rendersAPinAsAFingerprint() {
        let text = MultiplayerFingerprint.text(pin: MultiplayerServerFixture.pin)
        #expect(text?.split(separator: ":").count == 32)
        #expect(text?.hasSuffix("1E:1F") == true)
        #expect(MultiplayerFingerprint.text(pin: "") == nil)
        #expect(MultiplayerFingerprint.text(pin: "md5/AAAA") == nil)
        #expect(MultiplayerFingerprint.lines(text ?? "").split(separator: "\n").count == 2)
    }

    @Test func checksAnAddressOnlyForWhatTheHelperCouldNeverRead() {
        #expect(MultiplayerServerAddress.problem("relay.example") == nil)
        #expect(MultiplayerServerAddress.problem("relay.example:8443") == nil)
        #expect(MultiplayerServerAddress.problem("https://relay.example:8443") == nil)
        #expect(MultiplayerServerAddress.problem("http://relay.example") != nil)
        #expect(MultiplayerServerAddress.problem("relay example") != nil)
        #expect(MultiplayerServerAddress.problem("") != nil)
        #expect(MultiplayerServerAddress.host("https://relay.example:443/") == "relay.example")
    }

    @Test func ordersFavoritesFirstThenMostRecentlyUsed() {
        func server(_ id: String, favorite: Bool = false, used: String? = nil) -> MultiplayerServerSummary {
            MultiplayerServerSummary(id: id, url: "https://\(id).example", name: id, favorite: favorite,
                                     lastUsedAt: used.flatMap(MultiplayerTime.parse))
        }
        let ordered = MultiplayerServerSummary.ordered([
            server("never"),
            server("old", used: "2026-11-01T00:00:00Z"),
            server("fav-old", favorite: true, used: "2026-10-01T00:00:00Z"),
            server("new", used: "2026-11-25T00:00:00Z"),
            server("fav-new", favorite: true, used: "2026-11-20T00:00:00Z"),
            server("new", used: "2026-11-25T00:00:00Z"),
        ])
        #expect(ordered.map(\.id) == ["fav-new", "fav-old", "new", "old", "never"])
    }
}

@Suite struct MultiplayerServerClientTests {
    @Test func aScopedClientNamesItsServerOnExistingVerbs() async throws {
        let helper = ScriptedMultiplayerHelper([.status: [MultiplayerFixture.status], .request: [MultiplayerFixture.ok]])
        let client = MultiplayerClient(helper: helper).scoped(to: "s-home")
        _ = try await client.status()
        #expect(helper.lastInput(.status) == ["server": "s-home"])
        try await client.perform(.sendRequest(handle: "fixture-bo"))
        #expect(helper.lastInput(.request) == ["handle": "fixture-bo", "server": "s-home"])

        let unscoped = ScriptedMultiplayerHelper([.status: [MultiplayerFixture.status]])
        _ = try await MultiplayerClient(helper: unscoped).status()
        #expect(unscoped.lastRawInput(.status) == "{}")
    }

    @Test func sendsOnlyTheSettingsGivenAsRealBooleans() async throws {
        let reply = MultiplayerFixture.output(#"{"ok":true,"data":\#(MultiplayerServerFixture.home)}"#)
        let helper = ScriptedMultiplayerHelper([.serverUpdate: [reply], .serverAdd: [reply], .serverTrust: [reply],
                                                .serverRemove: [MultiplayerFixture.output(#"{"ok":true,"data":{}}"#)]])
        let client = MultiplayerClient(helper: helper)
        let updated = try await client.updateServer(id: "s-home", favorite: false)
        #expect(updated.id == "s-home")
        #expect(helper.lastRawInput(.serverUpdate) == #"{"favorite":false,"server":"s-home"}"#)
        _ = try await client.addServer(url: "lab.example:8443", name: "", pin: "")
        #expect(helper.lastInput(.serverAdd) == ["url": "lab.example:8443", "pin": ""])
        _ = try await client.trustServer(id: "s-home", pin: MultiplayerServerFixture.newPin)
        #expect(helper.lastInput(.serverTrust) == ["server": "s-home", "pin": MultiplayerServerFixture.newPin])
        try await client.removeServer(id: "s-home")
        #expect(helper.lastInput(.serverRemove) == ["server": "s-home"])
    }
}

@MainActor @Suite struct MultiplayerTrayModelTests {
    @Test func listsServersInOrderWithASessionEach() async {
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.team, MultiplayerServerFixture.home)],
            .status: [MultiplayerServerFixture.homeStatus],
        ])
        let model = MultiplayerServerFixture.model(helper)
        #expect(!model.hasLoaded)
        model.open()
        await model.settle()
        #expect(model.hasLoaded)
        #expect(model.servers.map(\.id) == ["s-home", "s-team"])
        #expect(model.session("s-home") != nil && model.session("s-team") != nil)
        #expect(model.tally == MultiplayerTally(servers: 2, serversOnline: 1, friendsOnline: 1, needsYou: 1))
        #expect(model.tally.summary == "1 of 2 servers online")
        #expect(model.menuSymbol == "person.2.slash")

        let groups = model.friendGroups
        #expect(groups.map(\.id) == ["s-home", "s-team"])
        #expect(groups[0].friends.map(\.handle) == ["fixture-bo", "fixture-cy", "fixture-zed"])
        #expect(groups[0].caption == "2 of 3 online")
        #expect(groups[0].incoming.map(\.handle) == ["fixture-dee"])
        #expect(groups[0].canShare)
        // A blocked server shows no friends, whatever its session answered.
        #expect(groups[1].friends.isEmpty && !groups[1].isOnline)
        #expect(groups[1].caption == "blocked, friends hidden")
        model.close()
    }

    @Test func firstRunHasNoServers() async {
        let helper = ScriptedMultiplayerHelper([.servers: [MultiplayerServerFixture.servers()]])
        let model = MultiplayerServerFixture.model(helper)
        await model.refresh()?.value
        #expect(model.hasLoaded && model.servers.isEmpty)
        #expect(model.tally.summary == "No servers yet")
        #expect(model.unavailable == nil)

        let missing = MultiplayerModel(client: nil, setupFailure: .helperMissing)
        #expect(missing.unavailable == .helperMissing)
        #expect(missing.refresh() == nil)
    }

    @Test func savesOnlyAfterTheCheckPassesAndThePinIsConfirmed() async {
        let added = MultiplayerServerFixture.server("s-lab", name: "lab", pin: MultiplayerServerFixture.pin)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(), MultiplayerServerFixture.servers(added)],
            .serverProbe: [MultiplayerServerFixture.probe(signIn: false), MultiplayerServerFixture.probe()],
            .serverAdd: [MultiplayerFixture.output(#"{"ok":true,"data":\#(added)}"#)],
            .serverUpdate: [MultiplayerFixture.output(#"{"ok":true,"data":\#(added)}"#)],
            .status: [MultiplayerFixture.output(#"{"ok":true,"data":{"online":false,"signedIn":false}}"#)],
        ])
        let model = MultiplayerServerFixture.model(helper)
        await model.refresh()?.value
        model.startAddServer()
        #expect(!model.canProbe && !model.canSaveServer)

        model.serverDraft.address = " lab.example:8443 "
        #expect(model.canProbe)
        await model.runProbe()?.value
        #expect(helper.lastInput(.serverProbe) == ["url": "lab.example:8443"])
        #expect(model.currentProbe.probe?.stoppedAt == .signin)
        #expect(!model.canSaveServer)
        #expect(model.addServerHint == "Fix step 5 to finish.")
        #expect(model.saveServer() == nil)

        await model.runProbe()?.value
        #expect(model.currentProbe.probe?.passed == true)
        #expect(!model.canSaveServer)
        #expect(model.addServerHint == "Confirm the fingerprint to finish.")
        model.serverDraft.pinConfirmed = true
        #expect(model.canSaveServer)

        // Editing the address retires the check.
        model.serverDraft.address = "other.example"
        #expect(model.currentProbe == .idle && !model.canSaveServer)
        model.serverDraft.address = "lab.example:8443"
        model.serverDraft.name = "lab"
        model.serverDraft.autoConnect = false
        #expect(model.canSaveServer)

        model.saveServer()
        await model.settle()
        #expect(helper.lastInput(.serverAdd) == ["url": "lab.example:8443", "name": "lab", "pin": MultiplayerServerFixture.pin])
        #expect(helper.lastRawInput(.serverUpdate) == #"{"autoConnect":false,"server":"s-lab"}"#)
        #expect(model.route == .home)
        #expect(model.servers.map(\.id) == ["s-lab"])
        #expect(model.notice == "Added lab.")
        #expect(model.failure == nil)
    }

    @Test func aSystemTrustedServerSavesWithAnEmptyPin() async {
        let added = MultiplayerServerFixture.server("s-lab", name: "lab")
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(added)],
            .serverProbe: [MultiplayerServerFixture.probe(trusted: true)],
            .serverAdd: [MultiplayerFixture.output(#"{"ok":true,"data":\#(added)}"#)],
            .status: [MultiplayerFixture.output(#"{"ok":true,"data":{"online":false,"signedIn":false}}"#)],
        ])
        let model = MultiplayerServerFixture.model(helper)
        model.startAddServer()
        model.serverDraft.address = "lab.example:8443"
        await model.runProbe()?.value
        #expect(model.canSaveServer)
        model.saveServer()
        await model.settle()
        #expect(helper.lastInput(.serverAdd) == ["url": "lab.example:8443", "pin": ""])
        #expect(helper.count(.serverUpdate) == 0)
    }

    @Test func trustsAChangedCertificateOnlyFromAFreshCheckAndASecondConfirmation() async throws {
        let trusted = MultiplayerServerFixture.server("s-team", name: "team", pin: MultiplayerServerFixture.newPin)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.team), MultiplayerServerFixture.servers(trusted)],
            .serverProbe: [MultiplayerServerFixture.probe(pin: MultiplayerServerFixture.newPin)],
            .serverTrust: [MultiplayerFixture.output(#"{"ok":true,"data":\#(trusted)}"#)],
            .status: [MultiplayerFixture.output(#"{"ok":true,"data":{"online":false,"signedIn":false}}"#)],
        ])
        let model = MultiplayerServerFixture.model(helper)
        await model.refresh()?.value
        let blocked = try #require(model.server("s-team"))
        #expect(blocked.state == .certChanged)
        #expect(!model.canTrust(blocked))

        model.openServer("s-team")
        await model.settle()
        #expect(helper.lastInput(.serverProbe) == ["url": "https://team.example"])
        #expect(model.presentedProbe(for: blocked).probe?.pin == MultiplayerServerFixture.newPin)
        #expect(model.canTrust(blocked))
        #expect(model.confirmTrust() == nil)
        #expect(helper.count(.serverTrust) == 0)

        model.askTrust(blocked)
        #expect(model.confirmingTrust == "s-team")
        model.confirmTrust()
        await model.settle()
        #expect(helper.lastInput(.serverTrust) == ["server": "s-team", "pin": MultiplayerServerFixture.newPin])
        #expect(model.server("s-team")?.state == .signedOut)
        #expect(model.confirmingTrust == nil)
    }

    @Test func updatesAndRemovesAServer() async throws {
        let starred = MultiplayerServerFixture.server("s-team", name: "team", favorite: true, state: "offline")
        let plain = MultiplayerServerFixture.server("s-team", name: "team", state: "offline")
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home, plain),
                       MultiplayerServerFixture.servers(MultiplayerServerFixture.home, starred),
                       MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .serverUpdate: [MultiplayerFixture.output(#"{"ok":true,"data":\#(starred)}"#)],
            .serverRemove: [MultiplayerFixture.output(#"{"ok":true,"data":{}}"#)],
            .status: [MultiplayerServerFixture.homeStatus],
        ])
        let model = MultiplayerServerFixture.model(helper)
        await model.refresh()?.value
        let team = try #require(model.server("s-team"))
        model.toggleFavorite(team)
        await model.settle()
        #expect(helper.lastRawInput(.serverUpdate) == #"{"favorite":true,"server":"s-team"}"#)
        #expect(model.server("s-team")?.favorite == true)

        model.openServer("s-team")
        #expect(model.renameDraft == "team")
        #expect(model.confirmRemove() == nil)
        model.askRemove(team)
        model.confirmRemove()
        await model.settle()
        #expect(helper.lastInput(.serverRemove) == ["server": "s-team"])
        #expect(model.route == .home)
        #expect(model.servers.map(\.id) == ["s-home"])
        #expect(model.session("s-team") == nil)
    }

    @Test func aRefusedActionSaysWhyAndKeepsTheList() async throws {
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .serverUpdate: [MultiplayerFixture.output(#"{"ok":false,"error":"no such server"}"#)],
            .status: [MultiplayerServerFixture.homeStatus],
        ])
        let model = MultiplayerServerFixture.model(helper)
        await model.refresh()?.value
        model.toggleFavorite(try #require(model.server("s-home")))
        await model.settle()
        #expect(model.failure == "Couldn’t change the favorite. no such server")
        #expect(model.servers.map(\.id) == ["s-home"])
        #expect(!model.isBusy)
    }
}
