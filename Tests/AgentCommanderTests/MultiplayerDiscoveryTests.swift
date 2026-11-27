import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Relays nearby and the join checklist (design/COMMANDER-NETWORK-DISCOVERY.md, "The tray").
// Every relay, host, pin and contact here is made up. No test browses a network, runs `tailscale`
// or reaches the real helper.

enum MultiplayerDiscoveryFixture {
    static let pin = MultiplayerServerFixture.pin
    /// A different key: what a Bonjour record might claim.
    static let advertised = MultiplayerServerFixture.newPin
    static let fingerprint = (0..<32).map { String(format: "%02X", $0) }.joined(separator: ":")

    /// Found on the tailnet and vouched for by `tailscale whois`: joins with no pin.
    static let build = #"{"id":"r-build","name":"build-relay","url":"https://build-relay.tail.example","sources":["tailnet"],"reachable":true,"pin":"\#(pin)","fingerprint":"\#(fingerprint)","systemTrusted":false,"verified":"tailnet","tailnetNode":"build-relay","version":"0.4.0","mode":"host","membership":"open","issuer":"https://accounts.example","clientId":"fixture.apps.example","added":false,"new":true,"next":"add","lastSeen":"2026-11-27T10:00:00Z"}"#

    /// Found on the local network: its fingerprint needs the person, and it advertises another pin.
    static let den = #"{"id":"r-den","name":"den-mini","url":"https://den-mini.local:8443","sources":["bonjour"],"reachable":true,"pin":"\#(pin)","fingerprint":"\#(fingerprint)","systemTrusted":false,"advertisedPin":"\#(advertised)","membership":"invite","adminContact":"ops@lab.example","added":false,"new":true,"next":"confirm"}"#

    static let attic = #"{"id":"r-attic","name":"attic-relay","url":"https://attic-relay.tail.example","sources":["tailnet"],"reachable":false,"error":"dial tcp 100.64.0.23:443: i/o timeout","added":false,"new":false,"next":"unreachable"}"#

    /// Already in the server list. The device agent still calls it new-free and added.
    static let studio = #"{"id":"r-studio","name":"studio","url":"https://studio.example","sources":["tailnet","bonjour"],"reachable":true,"verified":"tailnet","membership":"allowlist","added":true,"serverId":"s-studio","new":false,"next":"sign-in"}"#

    static func reply(_ relays: [String], sources: String = #"[{"name":"tailnet","ok":true},{"name":"bonjour","ok":true}]"#) -> String {
        #"{"relays":[\#(relays.joined(separator: ","))],"sources":\#(sources),"refreshedAt":"2026-11-27T10:00:30Z"}"#
    }

    static let offTailnet = #"[{"name":"tailnet","ok":false,"detail":"this Mac is not on a tailnet"},{"name":"bonjour","ok":true}]"#

    static func relay(_ json: String) throws -> MultiplayerDiscoveredRelay {
        try JSONDecoder().decode(MultiplayerDiscoveredRelay.self, from: Data(json.utf8))
    }

    /// What the helper holds: the relays it lists and the servers saved so far.
    final class World: Sendable {
        let relays: Mutex<[String]>
        let sources: Mutex<String>
        let servers = Mutex<[String]>([])
        /// The reply a join is refused with, when it should be.
        let refusal = Mutex<String?>(nil)

        init(_ relays: [String], sources: String? = nil) {
            self.relays = Mutex(relays)
            self.sources = Mutex(sources ?? #"[{"name":"tailnet","ok":true},{"name":"bonjour","ok":true}]"#)
        }

        var helper: RoutedMultiplayerHelper {
            RoutedMultiplayerHelper { [self] call in
                switch call.verb {
                case .servers:
                    return #"{"servers":[\#(servers.withLock { $0 }.joined(separator: ","))]}"#
                case .relayDiscover:
                    return MultiplayerDiscoveryFixture.reply(relays.withLock { $0 }, sources: sources.withLock { $0 })
                case .relayJoin:
                    if let refusal = refusal.withLock({ $0 }) { return "!" + refusal }
                    let id = call.input.firstText("relay") ?? ""
                    let name = String(id.dropFirst(2))
                    let saved = MultiplayerServerFixture.server("s-\(name)", name: name, pin: call.input.firstText("pin") ?? "")
                    servers.withLock { $0.append(saved) }
                    return saved
                default:
                    return nil
                }
            }
        }
    }

    @MainActor static func model(_ helper: RoutedMultiplayerHelper, notifier: RecordingNotifier? = nil,
                                 store: MultiplayerDiscoveryStore = .scratch) -> MultiplayerModel {
        MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                         notifier: notifier, discoveryStore: store)
    }

    /// One list read and the discovery read that follows it.
    @MainActor static func read(_ model: MultiplayerModel) async {
        await model.refresh()?.value
        await model.settle()
    }

    static func waitForPosts(_ notifier: RecordingNotifier, count: Int) async {
        for _ in 0..<400 where notifier.bodies.count < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// The keys of a request, as the helper received them. It refuses any it doesn't know.
    static func keys(_ call: RoutedMultiplayerHelper.Call?) -> [String] {
        guard case .object(let fields)? = call?.input else { return [] }
        return fields.keys.sorted()
    }
}

// MARK: - Contract

@Suite struct MultiplayerDiscoveryContractTests {
    @Test func tracksTheDiscoveryVerbs() {
        #expect(MultiplayerVerb.relayDiscover.arguments == ["tray", "relay-discover"])
        #expect(MultiplayerVerb.relayDiscoverSeen.arguments == ["tray", "relay-discover-seen"])
        #expect(MultiplayerVerb.relayJoin.arguments == ["tray", "relay-join"])
    }

    @Test func readsAFullRelay() throws {
        let reply = try JSONDecoder().decode(MultiplayerDiscovery.self, from: Data(MultiplayerDiscoveryFixture.reply(
            [MultiplayerDiscoveryFixture.build, MultiplayerDiscoveryFixture.den, MultiplayerDiscoveryFixture.attic,
             MultiplayerDiscoveryFixture.studio]).utf8))
        #expect(reply.relays.map(\.id) == ["r-build", "r-den", "r-attic", "r-studio"])
        #expect(reply.sources.map(\.name) == ["tailnet", "bonjour"] && reply.sources.allSatisfy(\.ok))
        #expect(reply.refreshedAt == MultiplayerTime.parse("2026-11-27T10:00:30Z") && !reply.notOnTailnet)

        let build = reply.relays[0]
        #expect(build.name == "build-relay" && build.url == "https://build-relay.tail.example")
        #expect(build.sources == [.tailnet] && build.source.title == "Tailnet")
        #expect(build.reachable && build.isTailnetVerified && build.tailnetNode == "build-relay")
        #expect(build.pin == MultiplayerDiscoveryFixture.pin && build.shownFingerprint == MultiplayerDiscoveryFixture.fingerprint)
        #expect(build.membership == .open && build.membership.title == "Open")
        #expect(build.version == "0.4.0" && build.mode == "host" && build.issuer == "https://accounts.example")
        #expect(build.clientID == "fixture.apps.example" && build.isNew && !build.added)
        #expect(build.next == .add && build.step == .add && build.lastSeen != nil)
        #expect(build.advertisedPin.isEmpty && build.advertisedPinMatches == nil)

        let den = reply.relays[1]
        #expect(den.sources == [.bonjour] && den.source.title == "Local network")
        #expect(den.membership.title == "Invite only" && den.adminContact == "ops@lab.example")
        // The Go side leaves a false flag out: an advertised pin without it is a different pin.
        #expect(den.advertisedPin == MultiplayerDiscoveryFixture.advertised && den.advertisedPinMatches == false)
        #expect(den.next == .confirm)

        let attic = reply.relays[2]
        #expect(!attic.reachable && attic.next == .unreachable && attic.membership == .unknown && attic.membership.title == nil)
        #expect(attic.unreachableReason == "It didn’t answer in time.")

        let studio = reply.relays[3]
        // Found twice: the tailnet is the source a row names.
        #expect(studio.sources == [.tailnet, .bonjour] && studio.source == .tailnet)
        #expect(studio.added && studio.serverID == "s-studio" && studio.next == .signIn && studio.membership.title == "Allowlist")
    }

    @Test func readsSparseAndOddReplies() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(MultiplayerDiscovery.self, from: Data("{}".utf8)) == MultiplayerDiscovery())

        let sparse = try decoder.decode(MultiplayerDiscovery.self, from: Data(#"""
        {"relays":[{"id":"r-1"},{"name":"no id"},{"id":""},{"id":"r-1","name":"again"},
                   {"id":"r-2","url":"https://lab.example:8443","sources":["mesh","bonjour",""],"reachable":"yes",
                    "membership":"knock","next":"wave","advertisedPinMatches":true,"lastSeen":"soon"}],
         "sources":[{"name":"tailnet"},{"ok":true},7],"refreshedAt":7}
        """#.utf8))
        // A relay without an ID is dropped, and so is a second row with an ID already listed.
        #expect(sparse.relays.map(\.id) == ["r-1", "r-2"])
        let bare = sparse.relays[0]
        #expect(bare.name.isEmpty && bare.url.isEmpty && bare.sources.isEmpty && !bare.reachable && !bare.added && !bare.isNew)
        #expect(bare.next == .unknown && bare.step == .unreachable && bare.shownFingerprint == nil)
        #expect(bare.unreachableReason == "This Mac can’t reach it right now.")

        let odd = sparse.relays[1]
        #expect(odd.name == "lab.example:8443" && odd.displayName == "lab.example:8443")
        #expect(odd.sources == [.other("mesh"), .bonjour] && odd.source.title == "Nearby")
        // A word this build doesn't know is never read as reachable, open or done.
        #expect(!odd.reachable && odd.membership == .unknown && odd.next == .unknown && odd.lastSeen == nil)
        #expect(odd.advertisedPinMatches == nil)
        #expect(sparse.sources.count == 2 && sparse.sources[0].ok == false && sparse.refreshedAt == nil)
    }

    @Test func aStepThisBuildDoesNotKnowIsReadFromTheFields() {
        var relay = MultiplayerDiscoveredRelay(id: "r-1", name: "lab", url: "https://lab.example", reachable: true)
        #expect(relay.step == .confirm)
        relay.systemTrusted = true
        #expect(relay.step == .add)
        relay.systemTrusted = false
        relay.verified = "Tailnet"
        #expect(relay.step == .add)
        relay.added = true
        #expect(relay.step == .signIn)
        relay.next = .done
        #expect(relay.step == .done)
    }

    @Test func aBonjourNameIsBoundedBeforeItIsDrawn() {
        let relay = MultiplayerDiscoveredRelay(id: "r-1", name: String(repeating: "relay\u{202E}\n", count: 40),
                                               url: "https://lab.example")
        #expect(relay.displayName.count <= 63 && !relay.displayName.contains("\n"))
        #expect(MultiplayerDiscoveredRelay(id: "r-2", name: " \n ", url: "https://lab.example:443/").displayName == "lab.example")
    }

    @Test func joinSendsOnlyTheKeysTheHelperKnows() async throws {
        let helper = RoutedMultiplayerHelper { call in
            call.verb == .relayJoin ? MultiplayerServerFixture.server("s-lab", name: "lab") : nil
        }
        let client = MultiplayerClient(helper: helper)
        _ = try await client.discoverRelays()
        #expect(MultiplayerDiscoveryFixture.keys(helper.last(.relayDiscover)).isEmpty)
        _ = try await client.discoverRelays(refresh: true)
        #expect(helper.last(.relayDiscover)?.input["refresh"] == .bool(true))
        try await client.markRelaysSeen(["r-1", "r-2"])
        #expect(helper.last(.relayDiscoverSeen)?.input["relays"] == .array([.string("r-1"), .string("r-2")]))
        // Nothing to mark is not a call: an empty list would mark every relay.
        try await client.markRelaysSeen([])
        #expect(helper.all.filter { $0.verb == .relayDiscoverSeen }.count == 1)
        _ = try await client.joinRelay(id: "r-1")
        #expect(MultiplayerDiscoveryFixture.keys(helper.last(.relayJoin)) == ["relay"])
        _ = try await client.joinRelay(id: "r-1", pin: MultiplayerDiscoveryFixture.pin)
        #expect(MultiplayerDiscoveryFixture.keys(helper.last(.relayJoin)) == ["pin", "relay"])
    }
}

// MARK: - Checklist

@Suite struct MultiplayerJoinChecklistTests {
    typealias Stage = MultiplayerJoinChecklist.Stage

    static func marks(_ checklist: MultiplayerJoinChecklist) -> [MultiplayerJoinChecklist.Mark] { checklist.steps.map(\.mark) }

    @Test func anUnreachableRelayStopsAtTheFirstStep() throws {
        let attic = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.attic)
        let checklist = MultiplayerJoinChecklist(relay: attic)
        #expect(Self.marks(checklist) == [.failed, .waiting, .waiting, .waiting])
        #expect(checklist.standing == .reachable && checklist.action == nil && checklist.fingerprint == nil)
        #expect(checklist.step(.reachable).detail == "It didn’t answer in time.")
        #expect(checklist.hint == "Waiting for the relay to answer.")
    }

    @Test func offATailnetItOffersToJoinOne() throws {
        let attic = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.attic)
        let checklist = MultiplayerJoinChecklist(relay: attic, notOnTailnet: true)
        #expect(checklist.action == .joinTailnet && checklist.action?.title == "Join a tailnet")
        #expect(checklist.step(.reachable).mark == .failed)
        #expect(checklist.step(.reachable).detail == "This Mac isn’t on a tailnet. Join one to reach this relay.")
        #expect(checklist.hint == "Join a tailnet to reach this relay.")
        // A relay that answers needs no tailnet, whatever the tailnet source says.
        let den = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.den)
        #expect(MultiplayerJoinChecklist(relay: den, notOnTailnet: true).action == .confirmFingerprint)
    }

    @Test func onlyATailnetRelayIsOfferedATailnet() {
        // A local-network relay that fails at a LAN address gains nothing from a tailnet.
        let lan = MultiplayerDiscoveredRelay(id: "r-lan", name: "lan", url: "https://lan.local:8443", sources: [.bonjour],
                                             reachable: false, error: "dial tcp 192.168.8.20:8443: connect: no route to host",
                                             next: .unreachable)
        #expect(!lan.looksLikeTailnet)
        #expect(MultiplayerJoinChecklist(relay: lan, notOnTailnet: true).action == nil)
        #expect(MultiplayerJoinChecklist(relay: lan, notOnTailnet: true).step(.reachable).detail == "This Mac has no route to it.")
        // One that fails at a tailnet address, or is named by one, does.
        var onTailnet = lan
        onTailnet.error = "dial tcp 100.101.7.9:8443: connect: no route to host"
        #expect(onTailnet.looksLikeTailnet)
        #expect(MultiplayerJoinChecklist(relay: onTailnet, notOnTailnet: true).action == .joinTailnet)
        var outside = lan
        outside.error = "dial tcp 100.200.7.9:8443: i/o timeout"
        #expect(!outside.looksLikeTailnet)
        var ipv6 = lan
        ipv6.error = "dial tcp [fd7a:115c:a1e0::9]:443: i/o timeout"
        #expect(ipv6.looksLikeTailnet)
    }

    @MainActor @Test func aDirectoryRelayIsNamedForItsSource() {
        #expect(MultiplayerRelaySource(word: "directory") == .directory)
        #expect(MultiplayerRelaySource.directory.title == "Public directory")
        let listed = MultiplayerDiscoveredRelay(id: "r-pub", name: "public", url: "https://relay.example.org", sources: [.directory])
        #expect(MultiplayerDiscoveryModel.notice(for: listed) == "public is in the public directory. Open the network tray to join it.")
        // A relay found on the tailnet as well is named for the tailnet.
        let both = MultiplayerDiscoveredRelay(id: "r-both", name: "both", url: "https://both.tail.example", sources: [.directory, .tailnet])
        #expect(both.source == .tailnet)
    }

    @Test func unreachableReasonsReadPlainly() {
        func reason(_ error: String) -> String {
            MultiplayerDiscoveredRelay(id: "r", name: "r", url: "https://r.example", reachable: false, error: error).unreachableReason
        }
        #expect(reason("offline on the tailnet") == "It’s offline on the tailnet.")
        #expect(reason("cannot connect: dial tcp 10.0.0.2:443: connect: connection refused") == "It refused the connection. The relay may be stopped.")
        #expect(reason("cannot connect: dial tcp: lookup r.example: no such host") == "Its name doesn’t resolve from this Mac.")
        #expect(reason("TLS handshake failed: remote error") == "Its secure connection failed.")
        #expect(reason("not a Commander relay: HTTP 404") == "It answered, but it isn’t a Commander relay.")
        #expect(reason("") == "This Mac can’t reach it right now.")
        #expect(reason("something new happened") == "Something new happened.")
    }

    @Test func aRelayFoundOffTheTailnetWaitsForItsFingerprint() throws {
        let den = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.den)
        let checklist = MultiplayerJoinChecklist(relay: den)
        #expect(Self.marks(checklist) == [.done, .current, .waiting, .waiting])
        #expect(checklist.standing == .certificate && checklist.action == .confirmFingerprint)
        #expect(checklist.fingerprint == MultiplayerDiscoveryFixture.fingerprint)
        // The advertised pin differs: a warning beside the fingerprint, and still only a hint.
        #expect(checklist.advertisedMatches == false)
        #expect(checklist.step(.reachable).detail == "Answers at den-mini.local:8443.")
        #expect(checklist.step(.membership).detail
                == "Invite only. You need an invite link or the admin’s approval. Ask ops@lab.example.")
        #expect(checklist.hint == "Confirm the fingerprint to add this relay.")

        var matching = den
        matching.advertisedPinMatches = true
        #expect(MultiplayerJoinChecklist(relay: matching).advertisedMatches == true)
        #expect(MultiplayerJoinChecklist(relay: matching).action == .confirmFingerprint)

        // Without an observed key there is nothing to confirm.
        var keyless = den
        keyless.pin = ""
        keyless.fingerprint = ""
        let stuck = MultiplayerJoinChecklist(relay: keyless)
        #expect(stuck.action == nil && stuck.fingerprint == nil && stuck.step(.certificate).mark == .current)
    }

    @Test func aRelayVerifiedOnTheTailnetGoesStraightToSignIn() throws {
        let build = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.build)
        let checklist = MultiplayerJoinChecklist(relay: build)
        #expect(Self.marks(checklist) == [.done, .done, .current, .waiting])
        #expect(checklist.step(.certificate).detail == "Verified on your tailnet as build-relay.")
        #expect(checklist.fingerprint == nil && checklist.advertisedMatches == nil)
        #expect(checklist.standing == .signIn && checklist.action == .signIn)
        #expect(checklist.step(.signIn).detail == "Your browser opens so you can sign in with accounts.example.")
        #expect(checklist.step(.membership).detail == "Open. Anyone who signs in is a member.")
        #expect(checklist.hint == "Sign in to finish.")

        var trusted = build
        trusted.verified = ""
        trusted.systemTrusted = true
        #expect(MultiplayerJoinChecklist(relay: trusted).step(.certificate).detail == "Trusted by macOS.")
    }

    @Test func anAddedRelayFollowsItsServer() throws {
        let den = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.den)
        let saved = MultiplayerServerSummary(id: "s-den", url: den.url, name: "den-mini", pin: den.pin)
        // The saved server is fresher than a row that still says "confirm".
        let added = MultiplayerJoinChecklist(relay: den, server: saved)
        #expect(Self.marks(added) == [.done, .done, .current, .waiting])
        #expect(added.step(.certificate).detail == "You confirmed its fingerprint." && added.fingerprint == nil)
        #expect(added.action == .signIn && added.hint == "Sign in once you have an invite or the admin’s approval.")

        let waiting = MultiplayerJoinChecklist(relay: den, server: saved, signIn: .waitingForBrowser)
        #expect(waiting.action == nil && waiting.step(.signIn).mark == .current)
        #expect(waiting.hint == "Finish signing in in your browser.")

        let refused = MultiplayerJoinChecklist(relay: den, server: saved, signIn: .failed("That account isn’t on the list."))
        #expect(refused.step(.signIn).mark == .failed && refused.step(.signIn).detail == "That account isn’t on the list.")
        #expect(refused.action == .signIn && refused.standing == .signIn)

        let member = MultiplayerServerSummary(id: "s-den", url: den.url, name: "den-mini", state: .online, signedIn: true,
                                              handle: "fixture-ada")
        let done = MultiplayerJoinChecklist(relay: den, server: member)
        #expect(Self.marks(done) == [.done, .done, .done, .done] && done.standing == nil)
        #expect(done.step(.signIn).detail == "Signed in as fixture-ada.")
        #expect(done.step(.membership).detail == "Invite only. You’re a member.")
        #expect(done.action == .openServer("s-den") && done.hint == "You’re in.")
    }

    @Test func membershipSaysWhatEachModeNeeds() throws {
        var relay = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.build)
        relay.membership = .allowlist
        let allowlist = MultiplayerJoinChecklist(relay: relay)
        #expect(allowlist.step(.membership).detail
                == "Allowlist. The admin must add your email before you can sign in. Ask the relay’s admin.")
        #expect(allowlist.step(.membership).mark == .waiting && allowlist.hint == "Sign in once the admin has added your email.")
        relay.membership = .unknown
        #expect(MultiplayerJoinChecklist(relay: relay).step(.membership).detail == "This relay didn’t say how it admits people.")
    }

    @Test func aRowSaysWhereItsRelayStands() throws {
        let build = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.build)
        #expect(build.rowState.text == "Ready to join" && build.rowTags.map(\.text) == ["New", "Open"])
        let den = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.den)
        #expect(den.rowState.text == "Confirm to join" && den.rowTags.map(\.text) == ["New", "Invite only"])
        let attic = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.attic)
        #expect(attic.rowState.text == "Unreachable" && attic.rowTags.isEmpty)
    }

    @Test func theMenuBarLabelJoinsTheDotAndTheCount() {
        #expect(MultiplayerMenuBarLabel.badge(unseen: 0, newRelays: 0) == nil)
        #expect(MultiplayerMenuBarLabel.badge(unseen: 3, newRelays: 0) == "3")
        #expect(MultiplayerMenuBarLabel.badge(unseen: 0, newRelays: 2) == "•")
        #expect(MultiplayerMenuBarLabel.badge(unseen: 3, newRelays: 1) == "• 3")
        #expect(MultiplayerMenuBarLabel.spoken(title: "Your server is online", unseen: 0, newRelays: 0)
                == "Commander network, Your server is online")
        #expect(MultiplayerMenuBarLabel.spoken(title: "No servers yet", unseen: 2, newRelays: 1)
                == "Commander network, No servers yet, 1 new relay nearby, 2 new in activity")
    }
}

// MARK: - Model

@MainActor @Suite struct MultiplayerDiscoveryModelTests {
    typealias Fixture = MultiplayerDiscoveryFixture

    @Test func listsWhatIsNotAddedAndCountsTheNewOnes() async throws {
        let world = Fixture.World([Fixture.den, Fixture.attic, Fixture.studio, Fixture.build])
        world.servers.withLock { $0 = [MultiplayerServerFixture.server("s-studio", name: "studio")] }
        let model = Fixture.model(world.helper)
        #expect(!model.discovery.hasLoaded && model.discovery.nearby.isEmpty)
        await Fixture.read(model)

        let discovery = model.discovery
        #expect(discovery.hasLoaded && discovery.failure == nil && discovery.relays.count == 4)
        // Added relays drop out; the ones that answer come first, by name.
        #expect(discovery.nearby.map(\.id) == ["r-build", "r-den", "r-attic"])
        #expect(discovery.newCount == 2 && !discovery.notOnTailnet)
        #expect(discovery.refreshedAt == MultiplayerTime.parse("2026-11-27T10:00:30Z"))

        // Choosing a relay opens its checklist; choosing it again closes it.
        discovery.select("r-den")
        #expect(discovery.selectedRelay?.id == "r-den")
        #expect(discovery.checklist(for: try #require(discovery.selectedRelay)).action == .confirmFingerprint)
        discovery.select("r-den")
        #expect(discovery.selected == nil)

        // A relay that is gone takes its open checklist with it.
        discovery.select("r-attic")
        world.relays.withLock { $0 = [Fixture.build] }
        await Fixture.read(model)
        #expect(discovery.selected == nil && discovery.nearby.map(\.id) == ["r-build"])
    }

    @Test func aRefusedReadKeepsTheListOnShow() async throws {
        let world = Fixture.World([Fixture.build])
        let failing = Mutex(false)
        let helper = RoutedMultiplayerHelper { call in
            if call.verb == .relayDiscover, failing.withLock({ $0 }) { return "!tailscale status: unreadable output" }
            if call.verb == .servers { return #"{"servers":[]}"# }
            return call.verb == .relayDiscover ? Fixture.reply(world.relays.withLock { $0 }) : nil
        }
        let model = Fixture.model(helper)
        await Fixture.read(model)
        failing.withLock { $0 = true }
        await Fixture.read(model)
        #expect(model.discovery.nearby.map(\.id) == ["r-build"])
        #expect(model.discovery.failure?.hasPrefix("Couldn’t look for relays.") == true)
        failing.withLock { $0 = false }
        // The header's refresh asks for a fresh pass.
        model.refreshAll()
        await model.settle()
        #expect(model.discovery.failure == nil && helper.last(.relayDiscover)?.input["refresh"] == .bool(true))
    }

    @Test func notifiesOnceForEachNewRelayAndNeverForAnAddedOne() async throws {
        let world = Fixture.World([Fixture.build, Fixture.den, Fixture.attic,
                                   Fixture.studio.replacingOccurrences(of: #""new":false"#, with: #""new":true"#)])
        world.servers.withLock { $0 = [MultiplayerServerFixture.server("s-studio", name: "studio")] }
        let helper = world.helper
        let notifier = RecordingNotifier()
        let model = Fixture.model(helper, notifier: notifier)
        await Fixture.read(model)
        await Fixture.waitForPosts(notifier, count: 2)
        // One each for the two new relays, naming the relay and where it is. Nothing for the relay
        // that isn't new, nor for the one already in the list.
        #expect(notifier.bodies == [
            "Relay nearby: build-relay is on your tailnet. Open the network tray to join it.",
            "Relay nearby: den-mini is on your local network. Open the network tray to join it.",
        ])
        // Still new to the device agent, since nobody looked: counted, and not notified again.
        await Fixture.read(model)
        await Fixture.read(model)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(notifier.bodies.count == 2 && model.discovery.newCount == 2)
        #expect(helper.all.filter { $0.verb == .relayDiscoverSeen }.isEmpty)

        // A relay that turns up later is notified on its own.
        world.relays.withLock { $0.append(Fixture.attic.replacingOccurrences(of: "r-attic", with: "r-loft")
            .replacingOccurrences(of: #""new":false"#, with: #""new":true"#)) }
        await Fixture.read(model)
        await Fixture.waitForPosts(notifier, count: 3)
        #expect(notifier.bodies.count == 3 && notifier.bodies.last?.contains("attic-relay is on your tailnet") == true)
    }

    @Test func theSwitchAndDoNotDisturbHoldNotificationsBack() async throws {
        let suite = "multiplayer-discovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MultiplayerDiscoveryStore(defaults: defaults)
        #expect(store.notifies && store.notified.isEmpty)

        let world = Fixture.World([Fixture.build])
        let notifier = RecordingNotifier()
        let model = Fixture.model(world.helper, notifier: notifier, store: store)
        #expect(model.discovery.notifies)
        model.discovery.notifies = false
        #expect(!store.notifies)
        await Fixture.read(model)
        try? await Task.sleep(for: .milliseconds(60))
        // Off: nothing is posted, the relay still counts as new, and it is passed over for good.
        #expect(notifier.bodies.isEmpty && model.discovery.newCount == 1 && store.notified == ["r-build"])
        model.discovery.notifies = true
        world.relays.withLock { $0.append(Fixture.den) }
        await Fixture.read(model)
        await Fixture.waitForPosts(notifier, count: 1)
        #expect(notifier.bodies.count == 1 && notifier.bodies[0].contains("den-mini"))

        // The record outlives the model: a relaunch does not notify the same relay again.
        let again = RecordingNotifier()
        let relaunched = Fixture.model(world.helper, notifier: again, store: store)
        #expect(relaunched.discovery.notifies)
        await Fixture.read(relaunched)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(again.bodies.isEmpty && relaunched.discovery.newCount == 2)

        // Do not disturb posts nothing and keeps the relay for later.
        let quiet = RecordingNotifier()
        let helper = RoutedMultiplayerHelper { call in
            switch call.verb {
            case .servers: return #"{"servers":[]}"#
            case .relayDiscover: return Fixture.reply([Fixture.build])
            default: return nil
            }
        }
        let busy = Fixture.model(helper, notifier: quiet)
        busy.presenceChoice = .dnd
        await Fixture.read(busy)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(busy.isDoNotDisturb && quiet.bodies.isEmpty)
        busy.presenceChoice = .online
        await Fixture.read(busy)
        await Fixture.waitForPosts(quiet, count: 1)
        #expect(quiet.bodies.count == 1)
    }

    @Test func lookingAtTheListMarksItSeenInsteadOfNotifying() async throws {
        let world = Fixture.World([Fixture.build, Fixture.den, Fixture.attic])
        let helper = world.helper
        let notifier = RecordingNotifier()
        let model = Fixture.model(helper, notifier: notifier)
        model.discovery.listAppeared()
        await Fixture.read(model)
        try? await Task.sleep(for: .milliseconds(60))
        // The new relays are named to the device agent, the count clears, and nothing is posted.
        #expect(helper.last(.relayDiscoverSeen)?.input["relays"] == .array([.string("r-build"), .string("r-den")]))
        #expect(model.discovery.newCount == 0 && notifier.bodies.isEmpty)
        #expect(model.discovery.relays.allSatisfy { !$0.isNew })

        // Nothing new, nothing sent.
        world.relays.withLock { $0 = $0.map { $0.replacingOccurrences(of: #""new":true"#, with: #""new":false"#) } }
        await Fixture.read(model)
        #expect(helper.all.filter { $0.verb == .relayDiscoverSeen }.count == 1)

        // With the list gone, a relay seen there is not notified later either.
        model.discovery.listDisappeared()
        world.relays.withLock { $0 = [Fixture.build] }
        await Fixture.read(model)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(notifier.bodies.isEmpty && model.discovery.newCount == 1)

        // Opening the list after the fact marks what it shows.
        model.discovery.listAppeared()
        await model.settle()
        #expect(helper.all.filter { $0.verb == .relayDiscoverSeen }.count == 2 && model.discovery.newCount == 0)
    }

    @Test func confirmingSendsTheObservedPinAndNeverTheAdvertisedOne() async throws {
        let world = Fixture.World([Fixture.den, Fixture.build])
        let helper = world.helper
        let model = Fixture.model(helper)
        await Fixture.read(model)
        let discovery = model.discovery
        let den = try #require(discovery.relays.first { $0.id == "r-den" })
        #expect(den.advertisedPin == Fixture.advertised && den.pin == Fixture.pin)
        discovery.select("r-den")

        // Sign in does nothing while the fingerprint still waits for the person.
        #expect(discovery.signIn(den) == nil)
        #expect(helper.last(.relayJoin) == nil)

        await discovery.confirmFingerprint(den)?.value
        await model.settle()
        let sent = try #require(helper.last(.relayJoin))
        #expect(Fixture.keys(sent) == ["pin", "relay"])
        #expect(sent.input.firstText("relay") == "r-den" && sent.input.firstText("pin") == Fixture.pin)
        #expect(sent.input.firstText("pin") != Fixture.advertised)
        // Confirm adds the relay; signing in stays the person's next step.
        #expect(helper.last(.login) == nil)
        #expect(model.server("s-den") != nil && model.failure == nil)

        // The chosen relay stays listed with its checklist, now standing at Sign in.
        let joined = try #require(discovery.selectedRelay)
        #expect(discovery.nearby.contains { $0.id == "r-den" })
        let checklist = discovery.checklist(for: joined)
        #expect(checklist.standing == .signIn && checklist.action == .signIn)
        #expect(checklist.step(.certificate).detail == "You confirmed its fingerprint.")

        // Confirming twice sends nothing more.
        #expect(discovery.confirmFingerprint(joined) == nil)
        #expect(helper.all.filter { $0.verb == .relayJoin }.count == 1)

        // Sign in hands off to the server's own sign-in.
        discovery.signIn(joined)
        await model.settle()
        #expect(helper.last(.login)?.input.firstText("server") == "s-den")
        #expect(helper.all.filter { $0.verb == .relayJoin }.count == 1)

        // Once its checklist closes, an added relay is out of the list.
        discovery.select(nil)
        #expect(discovery.nearby.map(\.id) == ["r-build"])
    }

    @Test func aVerifiedRelayJoinsWithNoPinThenSignsIn() async throws {
        let world = Fixture.World([Fixture.build])
        let helper = world.helper
        let model = Fixture.model(helper)
        await Fixture.read(model)
        let discovery = model.discovery
        let build = try #require(discovery.relays.first)
        // There is nothing to confirm on a relay the tailnet vouched for.
        #expect(discovery.confirmFingerprint(build) == nil)

        await discovery.signIn(build)?.value
        await model.settle()
        let sent = try #require(helper.last(.relayJoin))
        // The observed pin is known and still not sent: the device agent pins it from its own check.
        #expect(Fixture.keys(sent) == ["relay"] && sent.input.firstText("relay") == "r-build" && !build.pin.isEmpty)
        #expect(helper.last(.login)?.input.firstText("server") == "s-build")
        #expect(model.server("s-build") != nil)
    }

    @Test func aRefusedJoinSaysWhyAndAddsNothing() async throws {
        let world = Fixture.World([Fixture.den])
        world.refusal.withLock { $0 = "the server's certificate does not match the pin" }
        let model = Fixture.model(world.helper)
        await Fixture.read(model)
        let den = try #require(model.discovery.relays.first)
        await model.discovery.confirmFingerprint(den)?.value
        await model.settle()
        #expect(model.failure?.hasPrefix("Couldn’t add den-mini.") == true)
        #expect(model.servers.isEmpty && model.discovery.checklist(for: den).action == .confirmFingerprint)
    }

    @Test func offATailnetTheChecklistOffersToJoinOne() async throws {
        let world = Fixture.World([Fixture.attic.replacingOccurrences(of: #"["tailnet"]"#, with: #"["bonjour"]"#)],
                                  sources: Fixture.offTailnet)
        let model = Fixture.model(world.helper)
        await Fixture.read(model)
        let discovery = model.discovery
        #expect(discovery.notOnTailnet)
        let relay = try #require(discovery.nearby.first)
        #expect(discovery.checklist(for: relay).action == .joinTailnet)
        // Nothing is sent for a relay that can't be reached.
        #expect(discovery.confirmFingerprint(relay) == nil && discovery.signIn(relay) == nil)

        // Tailscale missing is a different reason: no tailnet to join from here.
        world.sources.withLock { $0 = #"[{"name":"tailnet","ok":false,"detail":"Tailscale is not installed"}]"# }
        await Fixture.read(model)
        #expect(!discovery.notOnTailnet && discovery.checklist(for: relay).action == nil)
    }

    @Test func theReviewFixtureListsAndJoinsRelays() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("multiplayer-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let launcher = folder.appendingPathComponent("fixture")
        try """
        #!/bin/sh
        COMMANDER_NETWORK_FIXTURE_STATE='\(folder.path)/state.json' COMMANDER_NETWORK_FIXTURE_DISCOVERY='nearby' \
        exec '\(MultiplayerRenderTests.fixture.path)' "$@"

        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let model = MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: launcher)),
                                     usesFixtureHelper: true, steadyPoll: .seconds(3600), fastPoll: .seconds(3600))
        await Fixture.read(model)
        let discovery = model.discovery
        #expect(discovery.nearby.map(\.name) == ["build-relay", "den-mini", "attic-relay"])
        #expect(discovery.newCount == 3 && discovery.relays.contains { $0.added })

        let den = try #require(discovery.nearby.first { $0.name == "den-mini" })
        #expect(discovery.checklist(for: den).advertisedMatches == true)
        discovery.select(den.id)
        let before = model.servers.count
        await discovery.confirmFingerprint(den)?.value
        await model.settle()
        #expect(model.failure == nil && model.servers.count == before + 1)
        #expect(discovery.checklist(for: try #require(discovery.selectedRelay)).action == .signIn)

        discovery.listAppeared()
        await model.settle()
        await Fixture.read(model)
        #expect(discovery.newCount == 0)
    }
}
