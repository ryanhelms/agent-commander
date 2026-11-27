import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Request access, the admin's membership requests, and List publicly (issue #99;
// design/COMMANDER-NETWORK-DISCOVERY.md, "Membership requests" and "Public directory").
// Every relay, email and address here is made up. No test reaches a relay, a directory or the
// real helpers; the two fixture tests run the review fixtures as processes.

enum MembershipRequestFixture {
    static let now = MultiplayerTime.parse("2026-11-27T12:00:00Z")!
    static let den = "s-den"

    /// What the helper holds for one relay that turns a sign-in away.
    final class World: Sendable {
        /// `status.accessRequest`, as the device agent reports it.
        let word = Mutex("requestable")
        let signedIn = Mutex(false)
        /// What `membership-request` answers: JSON data, or "!message" for a refusal.
        let requestReply = Mutex(#"{"id":"mr-1","status":"pending","note":"","createdAt":"2026-11-27T11:58:00Z"}"#)
        let statusReply = Mutex(#"{"id":"mr-1","status":"pending","note":"","createdAt":"2026-11-27T11:58:00Z"}"#)
        /// What `admin-requests` answers.
        let adminReply = Mutex(#"{"requests":[{"id":"mr-7","email":"noor@lab.example","note":"From the relay team.","status":"pending","createdAt":"2026-11-27T11:35:00Z"},{"id":"mr-8","email":"jules@example.org","status":"pending","createdAt":"2026-11-27T07:00:00Z"}]}"#)
        let isAdmin = Mutex(false)

        var helper: RoutedMultiplayerHelper { RoutedMultiplayerHelper { [self] call in reply(call) } }

        func reply(_ call: RoutedMultiplayerHelper.Call) -> String? {
            do {
                let signedIn = signedIn.withLock { $0 }
                switch call.verb {
                case .servers:
                    return #"{"servers":[\#(MultiplayerServerFixture.server(MembershipRequestFixture.den, name: "den", state: signedIn ? "online" : "signedOut", signedIn: signedIn))]}"#
                case .status:
                    if signedIn { return #"{"online":true,"signedIn":true,"handle":"fixture-ada"}"# }
                    let word = word.withLock { $0 }
                    let error = word.isEmpty ? "" : "this relay did not admit your account."
                    return #"{"online":false,"signedIn":false,"handle":"","error":"\#(error)","accessRequest":"\#(word)"}"#
                case .membershipRequest: return requestReply.withLock { $0 }
                case .membershipRequestStatus: return statusReply.withLock { $0 }
                case .adminRequests: return adminReply.withLock { $0 }
                case .me: return #"{"admin":\#(isAdmin.withLock { $0 }),"mode":"invite"}"#
                default: return nil
                }
            }
        }
    }

    @MainActor static func model(_ helper: RoutedMultiplayerHelper) -> MultiplayerModel {
        MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600), now: { now })
    }

    /// One list read, the server's status, and everything that follows them.
    @MainActor static func read(_ model: MultiplayerModel) async {
        await model.refresh()?.value
        await model.settle()
        await model.session(den)?.refresh()?.value
        await model.settle()
    }

    static func keys(_ call: RoutedMultiplayerHelper.Call?) -> [String] { MultiplayerDiscoveryFixture.keys(call) }

    static func status(_ phase: MultiplayerMembershipRequestStatus.Phase, requested: TimeInterval? = nil,
                       decided: TimeInterval? = nil) -> MultiplayerMembershipRequestStatus {
        MultiplayerMembershipRequestStatus(phase: phase, requestedAt: requested.map { now.addingTimeInterval(-$0) },
                                           decidedAt: decided.map { now.addingTimeInterval(-$0) })
    }

    /// A launcher that runs a review fixture with its own scratch state and environment.
    static func launcher(_ fixture: URL, in folder: URL, named name: String, environment: [String: String]) throws -> URL {
        let launcher = folder.appendingPathComponent(name)
        let variables = environment.map { "\($0.key)='\($0.value)'" }.joined(separator: " ")
        try "#!/bin/sh\n\(variables) exec '\(fixture.path)' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return launcher
    }
}

// MARK: - Contract

@Suite struct MembershipRequestContractTests {
    @Test func tracksTheFourVerbs() {
        #expect(MultiplayerVerb.membershipRequest.arguments == ["tray", "membership-request"])
        #expect(MultiplayerVerb.membershipRequestStatus.arguments == ["tray", "membership-request-status"])
        #expect(MultiplayerVerb.adminRequests.arguments == ["tray", "admin-requests"])
        #expect(MultiplayerVerb.adminRequestDecide.arguments == ["tray", "admin-request-decide"])
    }

    @Test func readsAFullAndASparseRequest() throws {
        let full = try JSONDecoder().decode(MultiplayerMembershipRequest.self, from: Data(#"{"id":"mr-1","status":"denied","note":" Hello ","createdAt":"2026-11-27T10:00:00Z","decidedAt":"2026-11-27T11:00:00Z","email":"ada@example.test"}"#.utf8))
        #expect(full.id == "mr-1" && full.status == .denied && full.note == "Hello" && full.email == "ada@example.test")
        #expect(full.createdAt == MultiplayerTime.parse("2026-11-27T10:00:00Z") && full.decidedAt == MultiplayerTime.parse("2026-11-27T11:00:00Z"))

        // "No request" is a status alone, and a word this build doesn't know reads the same.
        let none = try JSONDecoder().decode(MultiplayerMembershipRequest.self, from: Data(#"{"status":""}"#.utf8))
        #expect(none.id.isEmpty && none.status == .none && none.createdAt == nil && none.shownEmail == "No email given")
        let odd = try JSONDecoder().decode(MultiplayerMembershipRequest.self, from: Data(#"{"id":7,"status":"escalated","createdAt":"soon"}"#.utf8))
        #expect(odd.status == .none && odd.createdAt == nil)
        #expect(try JSONDecoder().decode(MultiplayerMembershipRequest.self, from: Data(#"{"status":"admitted"}"#.utf8)).status == .admitted)
    }

    @Test func anAdminsListDropsWhatItCannotAnswer() throws {
        let list = try JSONDecoder().decode(MultiplayerMembershipRequestList.self, from: Data(#"{"requests":[{"id":"mr-1","email":"a@example.test","status":"pending"},{"email":"nobody@example.test"},"junk",{"id":"mr-1","email":"twice@example.test"}]}"#.utf8))
        #expect(list.requests.map(\.id) == ["mr-1"] && list.requests[0].email == "a@example.test")
        #expect(try JSONDecoder().decode(MultiplayerMembershipRequestList.self, from: Data("{}".utf8)).requests.isEmpty)
    }

    @Test func statusCarriesTheRequestWord() throws {
        func ask(_ extra: String) throws -> MultiplayerMembershipAsk {
            try JSONDecoder().decode(MultiplayerStatus.self, from: Data(#"{"online":false,"signedIn":false\#(extra)}"#.utf8)).membershipAsk
        }
        #expect(try ask("") == .none)
        #expect(try ask(#","accessRequest":"requestable""#) == .requestable)
        #expect(try ask(#","accessRequest":"pending""#) == .pending)
        #expect(try ask(#","accessRequest":"approved""#) == .approved)
        #expect(try ask(#","accessRequest":"denied""#) == .denied)
        #expect(try ask(#","accessRequest":"full""#) == .full)
        // A word from a newer relay, or a value that isn't a word, never offers anything.
        #expect(try ask(#","accessRequest":"waitlisted""#) == .none)
        #expect(try ask(#","accessRequest":3"#) == .none)
    }

    @Test func aNoteIsSentOnlyWhenThereIsOne() async throws {
        let helper = RoutedMultiplayerHelper { _ in #"{"id":"mr-1","status":"pending"}"# }
        let client = MultiplayerClient(helper: helper).scoped(to: "s-den")
        _ = try await client.requestMembership(note: "  ")
        #expect(MembershipRequestFixture.keys(helper.last(.membershipRequest)) == ["server"])
        _ = try await client.requestMembership(note: " I work with Sam. ")
        let sent = try #require(helper.last(.membershipRequest))
        #expect(MembershipRequestFixture.keys(sent) == ["note", "server"])
        #expect(sent.input.firstText("note") == "I work with Sam." && sent.input.firstText("server") == "s-den")

        _ = try await client.membershipRequestStatus()
        #expect(MembershipRequestFixture.keys(helper.last(.membershipRequestStatus)) == ["server"])
        try await client.decideMembershipRequest(id: "mr-7", approve: false)
        let decided = try #require(helper.last(.adminRequestDecide))
        #expect(MembershipRequestFixture.keys(decided) == ["decision", "id", "server"])
        #expect(decided.input.firstText("decision") == "deny" && decided.input.firstText("id") == "mr-7")
    }
}

// MARK: - What each state says

@Suite struct MembershipRequestStateTests {
    typealias Fixture = MembershipRequestFixture

    @Test func eachStateHasItsWordAndItsSentence() {
        let now = Fixture.now
        let requestable = Fixture.status(.requestable)
        #expect(requestable.title == nil && requestable.canRequest && requestable.offersSignIn)
        #expect(requestable.detail(now: now) == "This relay didn’t admit your account. You can ask its admins to let you in.")

        let pending = Fixture.status(.pending, requested: 7200)
        #expect(pending.title == "Requested" && pending.lamp == .waiting && pending.tone == .focus && !pending.offersSignIn)
        #expect(pending.detail(now: now).hasPrefix("Requested 2 hours ago. The relay’s admins decide."))
        #expect(Fixture.status(.pending).detail(now: now).hasPrefix("Requested. "))

        let approved = Fixture.status(.approved, decided: 300)
        #expect(approved.title == "Approved" && approved.lamp == .on && approved.tone == .working && approved.offersSignIn)
        #expect(approved.detail(now: now) == "Approved 5 minutes ago. You’re admitted the next time you sign in.")

        let denied = Fixture.status(.denied, decided: 3 * 3600)
        #expect(denied.title == "Declined" && denied.lamp == .error && denied.tone == .failure)
        #expect(denied.detail(now: now) == "Declined 3 hours ago. You can ask again in about 21 hours.")
        // The relay refused a new request without saying when it declined the last one.
        #expect(Fixture.status(.denied).detail(now: now)
                == "The relay’s admins declined a request from this account in the last day. You can ask again 24 hours after that.")
        #expect(Fixture.status(.denied, decided: 25 * 3600).detail(now: now).hasSuffix("Sign in again to ask once more."))

        let full = Fixture.status(.full)
        #expect(full.title == "Queue full" && full.lamp == .busy && full.tone == .attention)
        #expect(full.detail(now: now) == "This relay has too many requests waiting, so it didn’t take yours. Ask one of its admins directly.")
        #expect(full.detail(contact: "ops@lab.example", now: now).hasSuffix("Ask ops@lab.example directly."))
    }

    @Test func theChecklistOffersRequestAccessOnlyAfterARefusedSignIn() throws {
        let den = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.den)
        let saved = MultiplayerServerSummary(id: "s-den", url: den.url, name: "den-mini")
        let refused = MultiplayerJoinSignIn.failed("This relay did not admit your account. You can ask the relay’s admins to let you in.")

        // Before any refusal the step says what the mode needs and that asking is possible here.
        let plain = MultiplayerJoinChecklist(relay: den, server: saved)
        #expect(plain.action == .signIn && plain.request == nil && !plain.offersSignInAgain)
        #expect(plain.step(.membership).detail == "Invite only. You need an invite link or an admin’s approval. If sign-in turns you away, you can request access here. Its admin is ops@lab.example.")
        #expect(plain.hint == "Sign in. If the relay turns you away, you can request access.")

        let asking = MultiplayerJoinChecklist(relay: den, server: saved, signIn: refused, request: Fixture.status(.requestable), now: Fixture.now)
        #expect(asking.action == .requestAccess && asking.action?.stage == .membership && asking.action?.title == "Request access")
        #expect(asking.offersSignInAgain && asking.step(.signIn).mark == .failed)
        #expect(asking.step(.signIn).detail.hasPrefix("This relay did not admit your account."))
        #expect(asking.step(.membership).mark == .current)
        #expect(asking.step(.membership).detail == "Invite only. You can ask its admins to let you in.")

        let sending = MultiplayerJoinChecklist(relay: den, server: saved, signIn: refused, request: Fixture.status(.sending), now: Fixture.now)
        #expect(sending.action == nil && sending.hint == "Sending your request…" && !sending.offersSignInAgain)
    }

    @Test func theChecklistFollowsARequestToItsAnswer() throws {
        let den = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.den)
        let saved = MultiplayerServerSummary(id: "s-den", url: den.url, name: "den-mini")
        func checklist(_ status: MultiplayerMembershipRequestStatus) -> MultiplayerJoinChecklist {
            MultiplayerJoinChecklist(relay: den, server: saved, request: status, now: Fixture.now)
        }

        let pending = checklist(Fixture.status(.pending, requested: 600))
        #expect(pending.action == nil && pending.hint == "Waiting for the relay’s admins." && !pending.offersSignInAgain)
        #expect(pending.step(.signIn).mark == .waiting && pending.step(.membership).mark == .current)
        #expect(pending.step(.membership).detail.hasPrefix("Invite only. Requested 10 minutes ago."))

        let approved = checklist(Fixture.status(.approved, decided: 300))
        #expect(approved.action == .signIn && approved.hint == "Sign in to finish." && !approved.offersSignInAgain)
        #expect(approved.step(.signIn).mark == .current && approved.step(.signIn).detail == "An admin approved your request. Sign in to finish.")
        #expect(approved.step(.membership).detail.hasPrefix("Invite only. Approved 5 minutes ago."))

        let denied = checklist(Fixture.status(.denied, decided: 3600))
        #expect(denied.action == nil && denied.offersSignInAgain && denied.step(.membership).mark == .failed)
        #expect(denied.step(.membership).detail.contains("You can ask again in about 23 hours."))
        #expect(denied.hint == "The relay’s admins declined this request.")

        let full = checklist(Fixture.status(.full))
        #expect(full.action == nil && full.offersSignInAgain && full.step(.membership).mark == .failed)
        #expect(full.step(.membership).detail.hasSuffix("Ask ops@lab.example directly.") && full.hint == "Ask ops@lab.example directly.")

        // A new sign-in under way, a member, and a relay that isn't in the list leave the request out.
        #expect(MultiplayerJoinChecklist(relay: den, server: saved, signIn: .waitingForBrowser, request: Fixture.status(.pending)).request == nil)
        let member = MultiplayerServerSummary(id: "s-den", url: den.url, name: "den-mini", state: .online, signedIn: true, handle: "fixture-ada")
        #expect(MultiplayerJoinChecklist(relay: den, server: member, request: Fixture.status(.pending)).action == .openServer("s-den"))
        #expect(MultiplayerJoinChecklist(relay: den, request: Fixture.status(.requestable)).action == .confirmFingerprint)
    }
}

// MARK: - The requester's model

@MainActor @Suite struct MembershipRequestModelTests {
    typealias Fixture = MembershipRequestFixture

    @Test func nothingIsOfferedUntilStatusSaysRequestable() async {
        let world = Fixture.World()
        world.word.withLock { $0 = "" }
        let helper = world.helper
        let model = Fixture.model(helper)
        await Fixture.read(model)
        #expect(model.requests.status(for: Fixture.den) == nil)
        #expect(model.requests.request(on: Fixture.den) == nil)
        #expect(!helper.all.contains { $0.verb == .membershipRequest })
        #expect(!helper.all.contains { $0.verb == .membershipRequestStatus }, "nothing is polled while there is no request")
    }

    @Test func requestAccessSendsTheNoteAndShowsRequested() async throws {
        let world = Fixture.World()
        world.requestReply.withLock { $0 = #"{"id":"mr-1","status":"pending","note":"I work with Sam.","createdAt":"2026-11-27T11:58:00Z"}"# }
        let helper = world.helper
        let model = Fixture.model(helper)
        await Fixture.read(model)
        let requests = model.requests
        #expect(requests.status(for: Fixture.den)?.phase == .requestable)

        requests.notes[Fixture.den] = "  I work with Sam. "
        let sending = try #require(requests.request(on: Fixture.den))
        #expect(requests.status(for: Fixture.den)?.phase == .sending)
        #expect(requests.request(on: Fixture.den) == nil, "one request at a time")
        await sending.value
        await model.settle()

        let sent = try #require(helper.last(.membershipRequest))
        #expect(Fixture.keys(sent) == ["note", "server"] && sent.input.firstText("note") == "I work with Sam.")
        let status = try #require(requests.status(for: Fixture.den))
        // The device agent's status still says requestable; what the verb answered stands over it.
        #expect(status.phase == .pending && status.note == "I work with Sam." && status.requestedAt != nil)
        #expect(requests.notes[Fixture.den] == nil && status.failure == nil)
        #expect(model.failure == nil)
    }

    @Test func withoutANoteOnlyTheServerIsSent() async throws {
        let world = Fixture.World()
        let helper = world.helper
        let model = Fixture.model(helper)
        await Fixture.read(model)
        await model.requests.request(on: Fixture.den)?.value
        await model.settle()
        #expect(Fixture.keys(helper.last(.membershipRequest)) == ["server"])
        #expect(model.requests.status(for: Fixture.den)?.phase == .pending)
    }

    @Test func aPendingRequestIsReadAgainOnEachListUntilItIsAnswered() async throws {
        let world = Fixture.World()
        world.word.withLock { $0 = "pending" }
        let helper = world.helper
        let model = Fixture.model(helper)
        await Fixture.read(model)
        // Status said pending on a fresh launch: the next list read fetches the request itself.
        await Fixture.read(model)
        let requests = model.requests
        #expect(helper.all.filter { $0.verb == .membershipRequestStatus }.count >= 1)
        #expect(requests.status(for: Fixture.den)?.phase == .pending && requests.status(for: Fixture.den)?.requestedAt != nil)

        world.statusReply.withLock { $0 = #"{"id":"mr-1","status":"approved","createdAt":"2026-11-27T11:58:00Z","decidedAt":"2026-11-27T11:59:00Z"}"# }
        let before = helper.all.filter { $0.verb == .membershipRequestStatus }.count
        await Fixture.read(model)
        #expect(helper.all.filter { $0.verb == .membershipRequestStatus }.count == before + 1)
        let approved = try #require(requests.status(for: Fixture.den))
        #expect(approved.phase == .approved && approved.decidedAt == MultiplayerTime.parse("2026-11-27T11:59:00Z"))

        // Decided: it is not read again on every list.
        let settled = helper.all.filter { $0.verb == .membershipRequestStatus }.count
        await Fixture.read(model)
        #expect(helper.all.filter { $0.verb == .membershipRequestStatus }.count == settled)

        // Approved offers the server's own sign-in, and a member has no request to show.
        model.signIn(Fixture.den)
        await model.settle()
        #expect(helper.last(.login)?.input.firstText("server") == Fixture.den)
        world.signedIn.withLock { $0 = true }
        await Fixture.read(model)
        #expect(requests.status(for: Fixture.den) == nil && requests.records[Fixture.den] == nil)
    }

    @Test func aDeclinedRequestSaysSoWithItsWait() async throws {
        let world = Fixture.World()
        world.word.withLock { $0 = "pending" }
        world.statusReply.withLock { $0 = #"{"id":"mr-1","status":"denied","createdAt":"2026-11-27T08:00:00Z","decidedAt":"2026-11-27T09:00:00Z"}"# }
        let model = Fixture.model(world.helper)
        await Fixture.read(model)
        await Fixture.read(model)
        let status = try #require(model.requests.status(for: Fixture.den))
        #expect(status.phase == .denied)
        #expect(status.detail(now: Fixture.now) == "Declined 3 hours ago. You can ask again in about 21 hours.")
    }

    @Test func refusalsReadAsTheStateTheyMean() async throws {
        func refused(_ message: String) async -> (MultiplayerMembershipRequestStatus?, MultiplayerModel) {
            let world = Fixture.World()
            world.requestReply.withLock { $0 = "!" + message }
            let model = Fixture.model(world.helper)
            await Fixture.read(model)
            await model.requests.request(on: Fixture.den)?.value
            await model.settle()
            return (model.requests.status(for: Fixture.den), model)
        }
        let (denied, _) = await refused("the relay's admins declined a request from this account in the last day")
        #expect(denied?.phase == .denied && denied?.failure == nil)

        let (full, _) = await refused("the relay has too many pending requests; ask an admin directly")
        #expect(full?.phase == .full)

        // No recent refusal: the person can still ask, after signing in again.
        let (late, _) = await refused("sign in first; a request must follow a refused sign-in from this Mac within 15 minutes")
        #expect(late?.phase == .requestable)
        #expect(late?.failure == "A request has to follow a refused sign-in within 15 minutes. Sign in again, then ask.")

        let (member, _) = await refused("already a member of this relay")
        #expect(member?.phase == .requestable && member?.failure == "This account is already a member of this relay. Sign in again.")

        let (other, model) = await refused("the relay is restarting")
        #expect(other?.phase == .requestable && other?.failure?.hasPrefix("Couldn’t send the request.") == true)
        #expect(model.failure == nil, "the refusal shows under the note, not in the tray's banner")
    }

    @Test func statusDecidesOnceItSaysSomethingNew() async throws {
        let world = Fixture.World()
        world.requestReply.withLock { $0 = "!the relay has too many pending requests; ask an admin directly" }
        let model = Fixture.model(world.helper)
        await Fixture.read(model)
        await model.requests.request(on: Fixture.den)?.value
        await model.settle()
        #expect(model.requests.status(for: Fixture.den)?.phase == .full)
        // A later refused sign-in makes the relay's word new again: asking is offered once more.
        world.word.withLock { $0 = "pending" }
        await Fixture.read(model)
        #expect(model.requests.status(for: Fixture.den)?.phase == .pending)
        world.word.withLock { $0 = "requestable" }
        await Fixture.read(model)
        #expect(model.requests.status(for: Fixture.den)?.phase == .requestable)
    }

    @Test func theDiscoveryChecklistCarriesTheRequest() async throws {
        let world = Fixture.World()
        let relay = MultiplayerDiscoveryFixture.den.replacingOccurrences(of: #""added":false"#, with: #""added":true,"serverId":"s-den""#)
            .replacingOccurrences(of: #""next":"confirm""#, with: #""next":"sign-in""#)
        let helper = RoutedMultiplayerHelper { call in
            call.verb == .relayDiscover ? MultiplayerDiscoveryFixture.reply([relay]) : world.reply(call)
        }
        let model = Fixture.model(helper)
        await Fixture.read(model)
        let den = try #require(model.discovery.relays.first)
        let checklist = model.discovery.checklist(for: den)
        #expect(checklist.action == .requestAccess && checklist.request?.phase == .requestable)
        #expect(checklist.step(.signIn).detail == "This relay did not admit your account.")
        #expect(model.discovery.contact(forServer: "s-den") == "ops@lab.example")
    }

    @Test func theReviewFixtureWalksARequestFromRefusalToSignIn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("membership-request-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let launcher = try Fixture.launcher(MultiplayerRenderTests.fixture, in: folder, named: "network", environment: [
            "COMMANDER_NETWORK_FIXTURE_STATE": folder.appendingPathComponent("state.json").path,
            "COMMANDER_NETWORK_FIXTURE_DISCOVERY": "nearby", "COMMANDER_NETWORK_FIXTURE_ACCESS": "requestable",
        ])
        let helper = MultiplayerProcessHelper(executable: launcher)
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), usesFixtureHelper: true,
                                     steadyPoll: .seconds(3600), fastPoll: .seconds(3600))
        await MultiplayerDiscoveryFixture.read(model)
        let discovery = model.discovery, requests = model.requests
        let den = try #require(discovery.nearby.first { $0.name == "den-mini" })
        discovery.select(den.id)
        await discovery.confirmFingerprint(den)?.value
        await model.settle()
        let server = try #require(discovery.server(for: den)?.id)

        func read() async {
            await model.refresh()?.value
            await model.settle()
            await model.session(server)?.refresh()?.value
            await model.settle()
        }
        // The relay turns the sign-in away, and says the person may ask.
        model.signIn(server)
        await read()
        #expect(model.session(server)?.status?.membershipAsk == .requestable)
        #expect(discovery.checklist(for: try #require(discovery.selectedRelay)).action == .requestAccess)

        requests.notes[server] = "I work with Sam on the relay."
        await requests.request(on: server)?.value
        await read()
        #expect(requests.status(for: server)?.phase == .pending && requests.status(for: server)?.note == "I work with Sam on the relay.")

        // The fixture approves on the third read of the request.
        for _ in 0..<3 where requests.status(for: server)?.phase == .pending { await read() }
        #expect(requests.status(for: server)?.phase == .approved)
        #expect(discovery.checklist(for: try #require(discovery.selectedRelay)).action == .signIn)

        model.signIn(server)
        await model.settle()
        await read()
        #expect(model.server(server)?.signedIn == true && requests.status(for: server) == nil)

        // The admin's side of the same fixture: two people wait on ryan-mac, and none elsewhere.
        let home = "s-fixture-home"
        model.refreshMe(home)
        await model.settle()
        await requests.readWaiting(on: home)?.value
        #expect(requests.waiting[home]?.map(\.email) == ["noor@lab.example", "jules@example.org"])
        await requests.readWaiting(on: "s-fixture-studio")?.value
        #expect(requests.waiting["s-fixture-studio"] == nil)
    }
}

// MARK: - The admin's list

@MainActor @Suite struct MembershipRequestAdminTests {
    typealias Fixture = MembershipRequestFixture

    static func admin() async -> (MultiplayerModel, RoutedMultiplayerHelper, Fixture.World) {
        let world = Fixture.World()
        world.signedIn.withLock { $0 = true }
        world.isAdmin.withLock { $0 = true }
        let helper = world.helper
        let model = Fixture.model(helper)
        // The list, `me`, then the list again: the requests are read once the person is known as an admin.
        await Fixture.read(model)
        await Fixture.read(model)
        return (model, helper, world)
    }

    @Test func anAdminSeesWhoIsWaitingWithTheirNote() async throws {
        let (model, helper, _) = await Self.admin()
        #expect(model.isAdmin(Fixture.den))
        let waiting = try #require(model.requests.waiting[Fixture.den])
        #expect(waiting.map(\.id) == ["mr-7", "mr-8"] && model.requests.waitingCount == 2)
        #expect(Fixture.keys(helper.last(.adminRequests)) == ["server"])
        #expect(TeamsAdminPage.detail(waiting[0], now: Fixture.now) == "“From the relay team.” Asked 25 minutes ago.")
        #expect(TeamsAdminPage.detail(waiting[1], now: Fixture.now) == "Asked 5 hours ago. No note.")

        // Where admins look: the Admin place counts them, and so does the server page's Admin row.
        let network = ShellNetwork(model: model)
        #expect(network.membershipRequests == 2)
        let place = try #require(LiveShell.teamTools(isAdmin: true, requests: 2).first { $0.id == TeamsPlace.admin })
        #expect(place.count == 2 && place.isHot && place.countNoun == "requests waiting")
        #expect(LiveShell.teamTools(isAdmin: true).first { $0.id == TeamsPlace.admin }?.isHot == false)
        let row = try #require(MultiplayerWindowShortcut.serverTeams(on: Fixture.den, groups: 0, workspaces: 0, hosts: 0, knowledge: 0,
                                                                     isAdmin: true, requests: 1).last)
        #expect(row.figure == "1 request" && row.isHot)
    }

    @Test func approveAndDenySendTheDecisionAndTakeTheRowAway() async throws {
        let (model, helper, _) = await Self.admin()
        let approved = await model.decideMembershipRequest("mr-7", on: Fixture.den, approve: true)
        #expect(approved.isDone && approved.message == "Approved noor@lab.example. They’re admitted the next time they sign in.")
        let sent = try #require(helper.last(.adminRequestDecide))
        #expect(Fixture.keys(sent) == ["decision", "id", "server"])
        #expect(sent.input.firstText("decision") == "approve" && sent.input.firstText("id") == "mr-7" && sent.input.firstText("server") == Fixture.den)
        #expect(model.requests.waiting[Fixture.den]?.contains { $0.id == "mr-7" } == false)

        let denied = await model.decideMembershipRequest("mr-8", on: Fixture.den, approve: false)
        #expect(denied.isDone && denied.message == "Denied jules@example.org. They can ask again in 24 hours.")
        #expect(helper.last(.adminRequestDecide)?.input.firstText("decision") == "deny")
    }

    @Test func aRefusedDecisionKeepsTheRowAndSaysWhy() async throws {
        let world = Fixture.World()
        world.signedIn.withLock { $0 = true }
        world.isAdmin.withLock { $0 = true }
        let helper = RoutedMultiplayerHelper { call in
            call.verb == .adminRequestDecide ? "!no pending membership request with that ID" : world.reply(call)
        }
        let model = Fixture.model(helper)
        await Fixture.read(model)
        await Fixture.read(model)
        let result = await model.decideMembershipRequest("mr-7", on: Fixture.den, approve: true)
        #expect(!result.isDone && result.reason?.hasPrefix("Couldn’t approve noor@lab.example.") == true)
    }

    @Test func someoneWhoIsNotAnAdminSeesNothingAndNoError() async {
        let world = Fixture.World()
        world.signedIn.withLock { $0 = true }
        world.adminReply.withLock { $0 = "!only a relay admin can list membership requests" }
        let helper = world.helper
        let model = Fixture.model(helper)
        await Fixture.read(model)
        await Fixture.read(model)
        #expect(!helper.all.contains { $0.verb == .adminRequests }, "a member who isn’t an admin is never asked for the list")
        #expect(model.requests.waiting[Fixture.den] == nil && model.requests.waitingCount == 0)

        // Even asked for directly, a refusal hides the list and raises nothing.
        await model.requests.readWaiting(on: Fixture.den)?.value
        #expect(model.requests.waiting[Fixture.den] == nil && model.failure == nil)
        var server = TeamsPagesContent.Server(id: Fixture.den, name: "den", isAdmin: true)
        server.requests = model.requests.waiting[Fixture.den]
        #expect(server.requests == nil)
    }

    @Test func theAdminPageAnswersARequestThroughItsAction() async throws {
        let state = TeamsPagesState()
        var content = TeamsSample.content
        #expect(content.requestsWaiting == 2)
        #expect(content.readouts(for: TeamsPlace.admin).first { $0.id == "requests" }?.value == "2")
        let sent = Mutex<[String]>([])
        var actions = TeamsPageActions()
        actions.decideRequest = { request, server, approve in
            sent.withLock { $0.append("\(request) \(server) \(approve)") }
            return .done(id: request, server: server, message: "Approved.")
        }
        state.send(.decideRequest("mr-1", server: TeamsSample.studio, approve: true), in: content, through: actions, go: { _ in },
                   from: TeamsPlace.admin)
        for _ in 0..<200 where sent.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(sent.withLock { $0 } == ["mr-1 \(TeamsSample.studio) true"])
        content.servers = content.servers.map { var server = $0; server.requests = nil; return server }
        #expect(content.requestsWaiting == 0)
    }
}

// MARK: - List publicly

/// A relay that records what each action was sent and answers from a script, the last reply repeating.
final class ListingRelay: MultiplayerRelayControl {
    private let state: Mutex<(replies: [MultiplayerHostAction: [Result<MultiplayerHostReport, MultiplayerHostRefusal>]], sent: [(MultiplayerHostAction, Data)])>

    init(_ replies: [MultiplayerHostAction: [Result<MultiplayerHostReport, MultiplayerHostRefusal>]]) {
        state = Mutex((replies, []))
    }

    /// The JSON each `listing` was sent, in order.
    var listings: [[String: String]] {
        state.withLock { $0.sent }.filter { $0.0 == .listing }.map { (try? JSONDecoder().decode([String: String].self, from: $0.1)) ?? [:] }
    }

    var statusReads: Int { state.withLock { $0.sent }.filter { $0.0 == .status }.count }

    func run(_ action: MultiplayerHostAction, input: Data) async throws -> MultiplayerHostReport {
        let reply = state.withLock { state -> Result<MultiplayerHostReport, MultiplayerHostRefusal>? in
            state.sent.append((action, input))
            guard var replies = state.replies[action], let first = replies.first else { return nil }
            if replies.count > 1 { replies.removeFirst() }
            state.replies[action] = replies
            return first
        }
        guard let reply else { throw MultiplayerHostRefusal(message: "unscripted \(action)") }
        return try reply.get()
    }
}

@MainActor @Suite struct HostListingTests {
    static let now = MembershipRequestFixture.now
    static let address = "https://relay.example.org"

    static func report(_ state: MultiplayerHostReport.State = .running, listing: MultiplayerHostListing? = MultiplayerHostListing()) -> MultiplayerHostReport {
        var report = MultiplayerHostingTests.report(state, installed: state == .running, pin: MultiplayerHostingTests.pin)
        report.listing = listing
        return report
    }

    static func summary(_ phase: MultiplayerHostSummary.Phase = .running, _ listing: MultiplayerHostListing?, awaits: Bool = false) -> MultiplayerHostSummary {
        var summary = MultiplayerHostSummary()
        summary.phase = phase
        summary.listing = listing
        summary.listingAwaitsCheck = awaits
        return summary
    }

    func settled(_ model: MultiplayerHostModel) async {
        for _ in 0..<400 where model.isWorking { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func tracksTheListingAction() {
        #expect(MultiplayerHostAction.listing.rawValue == "listing")
    }

    @Test func readsTheListingBlockFullSparseAndUnreadable() throws {
        func decode(_ listing: String) throws -> MultiplayerHostReport {
            try MultiplayerRelayProcess.decode(Data(#"{"ok":true,"host":{"state":"running","installed":true,"dir":"/d","log":"/d/l"\#(listing)}}"#.utf8))
        }
        let full = try #require(try decode(#","listing":{"url":"https://relay.example.org","directory":"https://directory.example","listed":true,"checkedAt":"2026-11-27T11:55:00Z"}"#).listing)
        #expect(full.url == Self.address && full.directory == "https://directory.example" && full.listed && full.error.isEmpty)
        #expect(full.checkedAt == MultiplayerTime.parse("2026-11-27T11:55:00Z"))

        let failed = try #require(try decode(#","listing":{"url":"https://relay.example.org","listed":false,"error":"the relay's address is not public"}"#).listing)
        #expect(!failed.listed && failed.error == "the relay's address is not public" && failed.checkedAt == nil)
        #expect(failed.directory == "https://directory.bytedesk.ai", "the default directory stands in for a missing one")

        let sparse = try #require(try decode(#","listing":{}"#).listing)
        #expect(sparse == MultiplayerHostListing() && sparse.url.isEmpty && !sparse.listed)
        // A block Commander can't read is an unlisted relay, and the rest of the report still stands.
        let odd = try decode(#","listing":"soon""#)
        #expect(odd.state == .running && odd.listing == MultiplayerHostListing())
        #expect(try decode(#","listing":{"url":7,"listed":"yes","checkedAt":"later"}"#).listing == MultiplayerHostListing())
        // An older relay, and a host that was never set up, carry no block.
        #expect(try decode("").listing == nil)
    }

    @Test func theAddressIsCheckedForItsShapeBeforeItIsSent() {
        let problem = MultiplayerHostListingDraft.problem
        #expect(problem("") == nil && problem("https://relay.example.org") == nil && problem("relay.example.org") == nil)
        #expect(problem("relay.example.org:8443") == nil && problem("https://relay.example.org:8443/") == nil)
        #expect(problem("http://relay.example.org") == "Use an https address. A relay can’t be listed over http.")
        let shape = "Enter the relay’s public address, such as https://relay.example.org."
        #expect(problem("relay") == shape && problem("https://") == shape && problem("https://relay.example.org/join") == shape)
        #expect(problem("relay example.org") == shape && problem("me@relay.example.org") == shape && problem("ftp://relay.example.org") == shape)
        #expect(problem("relay.example.org:https") == "The port after the colon must be a number from 1 to 65535.")
        #expect(problem("relay.example.org:0") != nil)
    }

    @Test func eachListingStateHasItsWordAndItsLine() {
        let now = Self.now, checked = now.addingTimeInterval(-120)
        #expect(Self.summary(.running, nil).listingState == .off && !Self.summary(.running, nil).offersListing)
        #expect(Self.summary(.running, MultiplayerHostListing()).listingState == .off)
        #expect(Self.summary(.unconfigured, MultiplayerHostListing()).offersListing == false)
        #expect(Self.summary(.stopped, MultiplayerHostListing()).offersListing)

        let listed = Self.summary(.running, MultiplayerHostListing(url: Self.address, listed: true, checkedAt: checked)).listingState
        #expect(listed == .listed(since: checked) && listed.title == "Listed" && listed.lamp == .on && listed.tone == .working)
        #expect(listed.detail(now: now) == "Confirmed with the directory 2 minutes ago.")

        let refused = Self.summary(.running, MultiplayerHostListing(url: Self.address, error: "the relay's address is not public", checkedAt: checked)).listingState
        #expect(refused.title == "Not listed" && refused.lamp == .error && refused.tone == .failure)
        #expect(refused.detail(now: now) == "The relay’s address isn’t public, so the directory can’t reach it. Last tried 2 minutes ago.")
        #expect(MultiplayerHostListingState.reason("the relay at that URL presents a different key")
                == "The relay at that address presents a different key. Check the address is this relay’s.")
        #expect(MultiplayerHostListingState.reason("cannot reach the directory at directory.bytedesk.ai: dial tcp: no such host")
                == "The relay can’t reach the directory right now. It keeps trying.")
        #expect(MultiplayerHostListingState.reason("") == "The directory didn’t take the listing.")
        #expect(MultiplayerHostListingState.reason("name already taken") == "Name already taken.")

        // Stopped: nothing is listed, whatever the last try said.
        let stopped = Self.summary(.stopped, MultiplayerHostListing(url: Self.address, listed: true, checkedAt: checked)).listingState
        #expect(stopped == .waitsForRelay && stopped.title == "Lists when the relay is running" && stopped.detail(now: now) == nil)

        // Just turned on: Checking… until the relay reports a try, even over an older outcome.
        let fresh = Self.summary(.running, MultiplayerHostListing(url: Self.address)).listingState
        #expect(fresh == .checking && fresh.title == "Checking…" && fresh.lamp == .waiting)
        #expect(Self.summary(.running, MultiplayerHostListing(url: Self.address, error: "old", checkedAt: checked), awaits: true).listingState == .checking)
        #expect(Self.summary(.running, MultiplayerHostListing(directory: "https://directory.bytedesk.ai")).directoryName == "directory.bytedesk.ai")
    }

    @Test func turningOnSendsTheAddressThenFollowsTheRelayUntilItIsListed() async throws {
        let checked = Self.now
        let relay = ListingRelay([
            .status: [.success(Self.report()),
                      .success(Self.report(listing: MultiplayerHostListing(url: Self.address))),
                      .success(Self.report(listing: MultiplayerHostListing(url: Self.address, listed: true, checkedAt: checked)))],
            .listing: [.success(Self.report(listing: MultiplayerHostListing(url: Self.address)))],
        ])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1), listingInterval: .milliseconds(1))
        model.refresh()
        await settled(model)
        #expect(!model.listsPublicly && model.summary.listingState == .off && model.summary.offersListing, "off by default")

        // The switch shows the field and sends nothing.
        model.setListsPublicly(true)
        #expect(model.listsPublicly && model.showsListingField && !model.canList && relay.listings.isEmpty)
        model.listingDraft.address = "http://relay.example.org"
        #expect(!model.canList && model.listingDraft.addressProblem != nil)
        model.list()
        #expect(relay.listings.isEmpty, "an address of the wrong shape is never sent")

        model.listingDraft.address = " relay.example.org "
        #expect(model.canList)
        model.list()
        #expect(model.isChangingListing)
        await settled(model)
        #expect(relay.listings == [["url": "relay.example.org"]], "only the url is sent; the relay normalizes it")
        #expect(model.summary.listedURL == Self.address && model.listsPublicly && !model.showsListingField)
        #expect(model.summary.listingState == .listed(since: checked) && model.listingFailure == nil)
        #expect(relay.statusReads >= 3, "the relay was read again until it reported its registration")
    }

    @Test func turningOffSendsAnEmptyAddress() async throws {
        let listed = MultiplayerHostListing(url: Self.address, listed: true, checkedAt: Self.now)
        let relay = ListingRelay([.status: [.success(Self.report(listing: listed))], .listing: [.success(Self.report())]])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1), listingInterval: .milliseconds(1))
        model.refresh()
        await settled(model)
        #expect(model.listsPublicly && !model.showsListingField, "a listed relay shows its switch on")

        model.setListsPublicly(false)
        #expect(!model.listsPublicly, "the switch moves at once")
        await settled(model)
        #expect(relay.listings == [["url": ""]])
        #expect(!model.listsPublicly && model.summary.listingState == .off)
    }

    @Test func turningOffBeforeAnythingWasListedSendsNothing() async {
        let relay = ListingRelay([.status: [.success(Self.report())]])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1), listingInterval: .milliseconds(1))
        model.refresh()
        await settled(model)
        model.setListsPublicly(true)
        model.listingDraft.address = "relay.example.org"
        model.setListsPublicly(false)
        await settled(model)
        #expect(relay.listings.isEmpty && !model.listsPublicly && model.listingDraft == MultiplayerHostListingDraft())
    }

    @Test func aRefusedListingKeepsTheFormAndTheRelaysReason() async throws {
        let relay = ListingRelay([.status: [.success(Self.report())],
                                  .listing: [.failure(MultiplayerHostRefusal(message: "the public URL must use https"))]])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1), listingInterval: .milliseconds(1))
        model.refresh()
        await settled(model)
        model.setListsPublicly(true)
        model.listingDraft.address = "relay.example.org"
        model.list()
        await settled(model)
        #expect(model.listingFailure == "Couldn’t list the relay. The public URL must use https.")
        #expect(model.listsPublicly && model.showsListingField && model.listingDraft.address == "relay.example.org")
        #expect(model.summary.failure == nil, "the page's own banner is for Start and Stop")
    }

    @Test func aRefusedTurnOffLeavesTheSwitchOn() async {
        let listed = MultiplayerHostListing(url: Self.address, listed: true, checkedAt: Self.now)
        let relay = ListingRelay([.status: [.success(Self.report(listing: listed))],
                                  .listing: [.failure(MultiplayerHostRefusal(message: "host.json is locked"))]])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1), listingInterval: .milliseconds(1))
        model.refresh()
        await settled(model)
        model.setListsPublicly(false)
        await settled(model)
        #expect(model.listsPublicly && model.listingFailure?.hasPrefix("Couldn’t take the relay off the directory.") == true)
    }

    @Test func aListedRelaysAddressCanBeChanged() async throws {
        let listed = MultiplayerHostListing(url: Self.address, listed: true, checkedAt: Self.now)
        let moved = MultiplayerHostListing(url: "https://relay.example.net", listed: true, checkedAt: Self.now.addingTimeInterval(30))
        let relay = ListingRelay([.status: [.success(Self.report(listing: listed)), .success(Self.report(listing: moved))],
                                  .listing: [.success(Self.report(listing: MultiplayerHostListing(url: "https://relay.example.net", listed: true, checkedAt: Self.now)))]])
        let model = MultiplayerHostModel(control: relay, settle: .milliseconds(1), listingInterval: .milliseconds(1))
        model.refresh()
        await settled(model)
        model.editListingAddress()
        #expect(model.showsListingField && model.listingDraft.address == Self.address && !model.canList, "the same address isn’t sent again")
        model.cancelListingEdit()
        #expect(!model.showsListingField)
        model.editListingAddress()
        model.listingDraft.address = "https://relay.example.net"
        model.list()
        await settled(model)
        #expect(relay.listings == [["url": "https://relay.example.net"]] && model.summary.listedURL == "https://relay.example.net")
    }

    @Test func theRelayFixtureListsAndUnlists() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("host-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = MultiplayerRenderTests.fixture.deletingLastPathComponent().appendingPathComponent("commander-relay-fixture.py")
        func relay(_ outcome: String, state: String) throws -> MultiplayerRelayProcess {
            MultiplayerRelayProcess(executable: try MembershipRequestFixture.launcher(fixture, in: folder, named: "relay-\(state)", environment: [
                "COMMANDER_RELAY_FIXTURE_STATE": folder.appendingPathComponent("\(state).json").path,
                "COMMANDER_RELAY_FIXTURE_LISTING": outcome,
            ]))
        }
        let model = MultiplayerHostModel(control: try relay("listed", state: "a"), settle: .milliseconds(1), listingInterval: .milliseconds(1))
        model.refresh()
        await settled(model)
        #expect(model.summary.phase == .running && model.summary.listingState == .off && model.summary.directoryName == "directory.bytedesk.ai")
        model.setListsPublicly(true)
        model.listingDraft.address = "relay.example.org"
        model.list()
        await settled(model)
        #expect(model.summary.listedURL == Self.address && model.listingFailure == nil)
        if case .listed = model.summary.listingState {} else { Issue.record("expected Listed, got \(model.summary.listingState)") }
        model.setListsPublicly(false)
        await settled(model)
        #expect(model.summary.listingState == .off)

        let refusing = MultiplayerHostModel(control: try relay("private", state: "b"), settle: .milliseconds(1), listingInterval: .milliseconds(1))
        refusing.refresh()
        await settled(refusing)
        refusing.setListsPublicly(true)
        refusing.listingDraft.address = Self.address
        refusing.list()
        await settled(refusing)
        if case .notListed(let reason, _) = refusing.summary.listingState {
            #expect(reason == "the relay's address is not public")
        } else {
            Issue.record("expected Not listed, got \(refusing.summary.listingState)")
        }
        // The relay has the last word on the address: http is refused there too, and so is a field it doesn't know.
        let direct = try relay("listed", state: "c")
        await #expect(throws: MultiplayerHostRefusal(message: "the public URL must use https")) {
            _ = try await direct.run(.listing, input: Data(#"{"url":"http://relay.example.org"}"#.utf8))
        }
        await #expect(throws: MultiplayerHostRefusal(message: "invalid request")) {
            _ = try await direct.run(.listing, input: Data(#"{"url":"","public":true}"#.utf8))
        }
    }
}
