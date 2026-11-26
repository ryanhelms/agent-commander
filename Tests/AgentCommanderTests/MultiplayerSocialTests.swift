import AppKit
import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Presence, contacts, the feed, invites and membership (design/COMMANDER-NETWORK-INCREMENT-2.md).
// Every host, handle, email and pin here is made up. No test reaches a network or the real helper.

final class RecordingNotifier: MultiplayerNotifying {
    private let posts = Mutex<[String]>([])
    func post(id: String, title: String, body: String) async { posts.withLock { $0.append("\(title): \(body)") } }
    var bodies: [String] { posts.withLock { $0 } }
}

enum MultiplayerSocialFixture {
    static func data<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static let studio = MultiplayerServerFixture.server("s-studio", name: "studio", lastUsedAt: "2026-11-25T17:00:00Z",
                                                        state: "online", signedIn: true)

    static func feed(_ events: String, cursor: String, unseen: Int) -> MultiplayerHelperOutput {
        MultiplayerFixture.output(#"{"ok":true,"data":{"events":[\#(events)],"cursor":"\#(cursor)","unseen":\#(unseen)}}"#)
    }

    static let request = #"{"server":"s-home","seq":5,"at":"2026-11-26T01:02:03Z","kind":"friend.request","actor":"fixture-dee"}"#
    static let joined = #"{"server":"s-home","seq":6,"at":"2026-11-26T01:05:00Z","kind":"member.joined","actor":"fixture-cy","detail":"via invite"}"#

    static func link(pin: String = MultiplayerServerFixture.pin) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = pin.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "agentcommander://join?server=https%3A%2F%2Flab.example%3A8443&pin=\(encoded)&code=fixture-code&from=fixture-bo"
    }
}

@Suite struct MultiplayerSocialContractTests {
    @Test func tracksTheNewVerbs() {
        #expect(Set(["presence", "contacts", "activity", "activity-seen", "avatar", "membership", "membership-set",
                     "invite-create", "join", "me"]).isSubset(of: Set(MultiplayerVerb.allCases.map(\.rawValue))))
        #expect(MultiplayerVerb.activitySeen.arguments == ["tray", "activity-seen"])
    }

    @Test func aServerSummaryCarriesPresenceAndUnseen() throws {
        let server = try MultiplayerSocialFixture.data(MultiplayerServerSummary.self,
            #"{"id":"s-1","url":"https://a.example","state":"online","presence":"dnd","unseen":3}"#)
        #expect(server.presence == .dnd && server.unseen == 3)
        let older = try MultiplayerSocialFixture.data(MultiplayerServerSummary.self,
            #"{"id":"s-1","url":"https://a.example","state":"online","presence":"sleeping","unseen":-2}"#)
        // A word this build doesn't know is never read as online; a bad count is zero.
        #expect(older.presence == .unknown && older.unseen == 0)
        let sparse = try MultiplayerSocialFixture.data(MultiplayerServerSummary.self,
            #"{"id":"s-1","url":"https://a.example","state":"online"}"#)
        #expect(sparse.presence == nil)
    }

    @Test func decodesContactsWithPresenceFromTheWordOrTheOlderFlag() throws {
        struct Reply: Decodable { let contacts: [MultiplayerContact] }
        let reply = try MultiplayerSocialFixture.data(Reply.self, #"""
        {"contacts":[{"contactKey":"abc","displayName":"Sam R","rows":[
            {"server":"s-home","handle":"fixture-sam","presence":"busy","online":true,"statusMessage":" 2 agents ","hasAvatar":true},
            {"server":"s-studio","handle":"sam","online":false}]},
          {"rows":[{"server":"s-home","handle":"fixture-bo","online":true}]}]}
        """#)
        #expect(reply.contacts[0].rows[0] == MultiplayerContactRow(server: "s-home", handle: "fixture-sam", presence: .busy,
                                                                   statusMessage: "2 agents", hasAvatar: true))
        #expect(reply.contacts[0].rows[1].presence == .offline)
        #expect(reply.contacts[1].contactKey.isEmpty && reply.contacts[1].rows[0].presence == .online)
    }

    @Test func decodesTheFeedAndWritesEachEventAsASentence() throws {
        let feed = try MultiplayerSocialFixture.data(MultiplayerActivityFeed.self,
            #"{"events":[\#(MultiplayerSocialFixture.joined),\#(MultiplayerSocialFixture.request),{"server":"s-home","seq":2,"kind":"relay.rotated"}],"cursor":"c-6","unseen":2}"#)
        #expect(feed.cursor == "c-6" && feed.unseen == 2)
        #expect(feed.events.map(\.id) == ["s-home#6", "s-home#5", "s-home#2"])
        #expect(feed.events[0].sentence == "fixture-cy joined: via invite")
        #expect(feed.events[1].sentence == "fixture-dee sent a friend request")
        #expect(feed.events[1].at == MultiplayerTime.parse("2026-11-26T01:02:03Z"))
        #expect(feed.events[2].sentence == "Someone: relay.rotated")
        // Newest first, whatever order the pieces arrive in, and never the same event twice.
        let merged = MultiplayerActivityEvent.newestFirst(feed.events.reversed() + feed.events)
        #expect(merged.map(\.seq) == [6, 5, 2])
    }

    @Test func decodesMembershipMeInviteAvatarAndPresenceReplies() throws {
        let membership = try MultiplayerSocialFixture.data(MultiplayerMembership.self,
            #"{"mode":"allowlist","allowedEmails":["a@example.test"],"admins":["b@example.test"],"memberCount":3}"#)
        #expect(membership.mode == "allowlist" && membership.memberCount == 3 && membership.admins == ["b@example.test"])
        let me = try MultiplayerSocialFixture.data(MultiplayerMe.self, #"{"admin":false,"mode":"invite"}"#)
        #expect(!me.admin && !me.canInvite)
        #expect(MultiplayerMe(admin: false, mode: "open").canInvite && MultiplayerMe(admin: true, mode: "invite").canInvite)
        let invite = try MultiplayerSocialFixture.data(MultiplayerInvite.self,
            #"{"link":"agentcommander://join?server=a","code":"c","expiresAt":"2026-12-01T00:00:00Z"}"#)
        #expect(invite.code == "c" && invite.expiresAt != nil)
        let avatar = try MultiplayerSocialFixture.data(MultiplayerAvatarImage.self, #"{"contentType":"image/png","data":"iVBORw=="}"#)
        #expect(avatar.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(throws: (any Error).self) {
            try MultiplayerSocialFixture.data(MultiplayerAvatarImage.self, #"{"contentType":"image/png","data":"***"}"#)
        }
        let presence = try MultiplayerSocialFixture.data(MultiplayerPresenceReply.self, #"{"presence":"busy","auto":true}"#)
        #expect(presence.presence == .busy && presence.auto)
    }

    @Test func aStatusCarriesTheProfileWhenTheHelperSendsIt() throws {
        let status = try MultiplayerSocialFixture.data(MultiplayerStatus.self,
            #"{"online":true,"signedIn":true,"handle":"fixture-ada","displayName":"Ada","statusMessage":"Shipping","hasAvatar":true}"#)
        #expect(status.displayName == "Ada" && status.statusMessage == "Shipping" && status.hasAvatar)
        let older = try MultiplayerSocialFixture.data(MultiplayerStatus.self, #"{"online":true,"signedIn":true}"#)
        #expect(older.displayName.isEmpty && !older.hasAvatar)
    }
}

@Suite struct MultiplayerContactGroupingTests {
    static let servers = [MultiplayerServerSummary(id: "s-home", url: "https://home.example", name: "home"),
                          MultiplayerServerSummary(id: "s-team", url: "https://team.example", name: "team-relay"),
                          MultiplayerServerSummary(id: "s-lab", url: "https://lab.example", name: "lab")]

    static let contacts = [
        MultiplayerContact(contactKey: "k-sam", displayName: "Sam", rows: [
            MultiplayerContactRow(server: "s-lab", handle: "sam-lab", presence: .offline),
            MultiplayerContactRow(server: "s-home", handle: "fixture-sam", presence: .busy, statusMessage: "2 agents running", hasAvatar: true),
            MultiplayerContactRow(server: "s-team", handle: "sam", presence: .busy),
            MultiplayerContactRow(server: "s-gone", handle: "sam", presence: .online)]),
        MultiplayerContact(rows: [MultiplayerContactRow(server: "s-home", handle: "fixture-zed", presence: .dnd)]),
        MultiplayerContact(rows: [MultiplayerContactRow(server: "s-home", handle: "fixture-bo", presence: .offline)]),
    ]

    @Test func ordersPeopleWithALiveDeviceFirstThenByName() {
        let friends = ["fixture-bo", "fixture-zed", "fixture-ada", "fixture-sam"].map { MultiplayerFriend(handle: $0, online: $0 == "fixture-ada") }
        let entries = MultiplayerContactGrouping.entries(friends: friends, on: "s-home", contacts: Self.contacts, servers: Self.servers)
        // Connected: fixture-ada (online), fixture-zed (do not disturb), Sam (busy). Then the offline friend.
        #expect(entries.map(\.title) == ["fixture-ada", "fixture-zed", "Sam", "fixture-bo"])
        #expect(entries.map(\.presence) == [.online, .dnd, .busy, .offline])
    }

    @Test func aLinkedContactNamesItsOtherServersInListOrder() throws {
        let friends = [MultiplayerFriend(handle: "fixture-sam", online: true), MultiplayerFriend(handle: "fixture-bo", online: false)]
        let entries = MultiplayerContactGrouping.entries(friends: friends, on: "s-home", contacts: Self.contacts, servers: Self.servers)
        let sam = try #require(entries.first { $0.handle == "fixture-sam" })
        // The other servers in list order; a server that is no longer saved is left out.
        #expect(sam.alsoOn == ["team-relay", "lab"])
        #expect(sam.linkBadge == "also on team-relay and lab")
        #expect(sam.caption == "Busy, 2 agents running" && sam.handleCaption == "fixture-sam" && sam.hasAvatar)
        #expect(entries.first { $0.handle == "fixture-bo" }?.linkBadge == nil)

        let onTeam = MultiplayerContactGrouping.entries(friends: [MultiplayerFriend(handle: "sam")], on: "s-team",
                                                        contacts: Self.contacts, servers: Self.servers)
        #expect(onTeam.first?.linkBadge == "also on home and lab")
    }

    @Test func aFriendTheContactsReplyHasNotCaughtUpWithIsStillListed() {
        let entries = MultiplayerContactGrouping.entries(friends: [MultiplayerFriend(handle: "fixture-new", online: true),
                                                                   MultiplayerFriend(handle: "fixture-quiet")],
                                                         on: "s-home", contacts: [], servers: Self.servers)
        #expect(entries.map(\.handle) == ["fixture-new", "fixture-quiet"])
        #expect(entries.map(\.presence) == [.online, .unknown])
    }
}

@Suite struct MultiplayerInviteLinkTests {
    @Test func readsEveryFieldOfAnEncodedLink() throws {
        let link = try #require(MultiplayerInviteLink.parse("  " + MultiplayerSocialFixture.link() + "\n"))
        #expect(link.server == "https://lab.example:8443")
        #expect(link.pin == MultiplayerServerFixture.pin)
        #expect(link.code == "fixture-code" && link.from == "fixture-bo")
        #expect(link.raw == MultiplayerSocialFixture.link())
    }

    @Test func acceptsABareHostAnEmptyPinAndNoCode() throws {
        let link = try #require(MultiplayerInviteLink.parse("AgentCommander://join?server=relay.example/&pin="))
        #expect(link.server == "https://relay.example" && link.pin.isEmpty && link.code.isEmpty && link.from.isEmpty)
    }

    @Test func refusesAnythingThatIsNotAJoinLinkToAnHTTPSRelay() {
        for text in ["", "https://lab.example", "agentcommander://open?server=lab.example", "agentcommander://join",
                     "agentcommander://join?server=http%3A%2F%2Flab.example",
                     "agentcommander://join?server=https%3A%2F%2Flab.example%2Fpath",
                     "agentcommander://join?server=https%3A%2F%2Fuser%40lab.example",
                     "agentcommander://join?server=lab.example&pin=md5%2Fabc",
                     "agentcommander://join?server=lab.example&from=two%20words",
                     "agentcommander://join?server=lab%20example"] {
            #expect(MultiplayerInviteLink.parse(text) == nil, "\(text)")
        }
    }
}

@Suite struct MultiplayerSocialClientTests {
    @Test func membershipIsSentAsRealListsAndAnInviteAsRealNumbers() async throws {
        let helper = ScriptedMultiplayerHelper([
            .membershipSet: [MultiplayerFixture.output(#"{"ok":true,"data":{"mode":"invite","allowedEmails":[],"admins":["a@example.test"],"memberCount":1}}"#)],
            .inviteCreate: [MultiplayerFixture.output(#"{"ok":true,"data":{"link":"agentcommander://join?server=a.example","code":"c"}}"#)],
        ])
        let client = MultiplayerClient(helper: helper).scoped(to: "s-home")
        _ = try await client.setMembership(mode: "invite", allowedEmails: [], admins: ["a@example.test"])
        #expect(helper.lastRawInput(.membershipSet) == #"{"admins":["a@example.test"],"allowedEmails":[],"mode":"invite","server":"s-home"}"#)
        _ = try await client.createInvite(maxUses: 5, ttlHours: 168)
        #expect(helper.lastRawInput(.inviteCreate) == #"{"maxUses":5,"server":"s-home","ttlHours":168}"#)
    }

    @Test func aProfileWithAnAvatarFitsTheHelperInputAndOtherVerbsKeepTheSmallLimit() throws {
        let avatar = "data:image/jpeg;base64," + String(repeating: "A", count: MultiplayerAvatarEncoder.limit - 23)
        let payload: [String: MultiplayerPayloadValue] = ["avatar": .string(avatar), "server": "s-home"]
        #expect(throws: MultiplayerFailure.self) { try MultiplayerClient.encode(payload) }
        #expect(try MultiplayerClient.encode(payload, limit: MultiplayerClient.inputLimit(for: .profile)).count > MultiplayerClient.inputLimit)
        #expect(MultiplayerClient.inputLimit(for: .status) == MultiplayerClient.inputLimit)
    }

    @Test func aLargePictureIsCroppedAndShrunkToFitTheLimit() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 600, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(rep.bitmapData)
        var seed: UInt32 = 7
        for index in 0..<(rep.bytesPerRow * 600) {    // noise, so the file is far over the limit
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = index % 4 == 3 ? 255 : UInt8(seed >> 24)
        }
        let file = try #require(rep.representation(using: .png, properties: [:]))
        #expect(file.count > MultiplayerAvatarEncoder.limit)
        let encoded = try #require(MultiplayerAvatarEncoder.encode(file))
        #expect(encoded.dataURL.utf8.count <= MultiplayerAvatarEncoder.limit)
        #expect(encoded.dataURL.hasPrefix("data:image/jpeg;base64,"))
        let result = try #require(NSBitmapImageRep(data: encoded.image))
        #expect(result.pixelsWide == result.pixelsHigh && result.pixelsWide <= 256)
        #expect(MultiplayerAvatarEncoder.encode(Data("not a picture".utf8)) == nil)
    }
}

@MainActor @Suite struct MultiplayerSocialModelTests {
    static func model(_ helper: ScriptedMultiplayerHelper, notifier: RecordingNotifier? = nil) -> MultiplayerModel {
        MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                         notifier: notifier)
    }

    @Test func friendsCarryPresenceAndLinksFromContacts() async throws {
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home, MultiplayerSocialFixture.studio)],
            .status: [MultiplayerServerFixture.homeStatus],
            .contacts: [MultiplayerFixture.output(#"""
            {"ok":true,"data":{"contacts":[{"contactKey":"k","displayName":"Cy","rows":[
              {"server":"s-home","handle":"fixture-cy","presence":"busy"},{"server":"s-studio","handle":"cy","presence":"busy"}]}]}}
            """#)],
            .me: [MultiplayerFixture.output(#"{"ok":true,"data":{"admin":true,"mode":"allowlist"}}"#)],
        ])
        let model = Self.model(helper)
        model.open()
        await model.settle()
        let home = try #require(model.friendGroups.first { $0.id == "s-home" })
        // "Cy" sorts ahead of "fixture-bo": a display name is what the row is ordered by.
        #expect(home.people.map(\.handle) == ["fixture-cy", "fixture-bo", "fixture-zed"])
        #expect(home.people[0].linkBadge == "also on studio" && home.people[0].presence == .busy)
        #expect(home.caption == "2 of 3 online")
        #expect(model.isAdmin("s-home") && model.canInvite("s-home"))
        model.close()
    }

    @Test func newEventsAreNotifiedAfterTheFirstFeedAndNeverWhileDoNotDisturb() async {
        let dnd = MultiplayerServerFixture.server("s-home", name: "home", state: "online", signedIn: true)
            .replacingOccurrences(of: #""error":"""#, with: #""error":"","presence":"dnd""#)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home),
                       MultiplayerServerFixture.servers(MultiplayerServerFixture.home),
                       MultiplayerServerFixture.servers(dnd)],
            .activity: [MultiplayerSocialFixture.feed(MultiplayerSocialFixture.request, cursor: "c-5", unseen: 1),
                        MultiplayerSocialFixture.feed(MultiplayerSocialFixture.joined, cursor: "c-6", unseen: 2),
                        MultiplayerSocialFixture.feed(#"{"server":"s-home","seq":7,"kind":"friend.accepted","actor":"fixture-bo"}"#, cursor: "c-7", unseen: 3)],
            .activitySeen: [MultiplayerFixture.output(#"{"ok":true,"data":{}}"#)],
        ])
        let notifier = RecordingNotifier()
        let model = Self.model(helper, notifier: notifier)
        await model.refresh()?.value
        await model.settle()
        // What was already in the feed when Commander started is history, not news.
        #expect(model.activity.map(\.seq) == [5] && model.unseen == 1)
        #expect(notifier.bodies.isEmpty)

        await model.refresh()?.value
        await model.settle()
        await Task.yield()
        #expect(helper.lastInput(.activity)?["after"] == "c-5")
        #expect(model.activity.map(\.seq) == [6, 5] && model.unseen == 2)
        for _ in 0..<50 where notifier.bodies.isEmpty { await Task.yield() }
        #expect(notifier.bodies == ["home: fixture-cy joined: via invite"])

        await model.refresh()?.value
        await model.settle()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.isDoNotDisturb && model.activity.count == 3)
        #expect(notifier.bodies.count == 1)

        model.activityFriend = "fixture-dee"
        #expect(model.filteredActivity.map(\.seq) == [5])
        #expect(model.activityActors == ["fixture-bo", "fixture-cy", "fixture-dee"])
        await model.markActivitySeen()?.value
        #expect(model.unseen == 0 && helper.lastInput(.activitySeen)?["cursor"] == "c-7")
    }

    @Test func anInviteLinkFillsTheFormAndJoinsOnlyWhenTheCertificateMatchesIt() async throws {
        let joined = MultiplayerFixture.output(#"{"ok":true,"data":\#(MultiplayerServerFixture.server("s-lab", name: "lab", state: "connecting", pin: MultiplayerServerFixture.pin))}"#)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .serverProbe: [MultiplayerServerFixture.probe(pin: MultiplayerServerFixture.newPin), MultiplayerServerFixture.probe()],
            .join: [joined],
        ])
        let model = Self.model(helper)
        await model.refresh()?.value
        #expect(!model.openInvite("agentcommander://join?server=http://lab.example"))
        #expect(model.failure != nil && model.route == .home)

        #expect(model.openInvite(MultiplayerSocialFixture.link()))
        #expect(model.route == .addServer && model.serverDraft.address == "https://lab.example:8443")
        await model.settle()
        // The server presents a key other than the invite's: nothing can be joined.
        #expect(model.activeInvite != nil && model.invitePinProblem != nil && !model.canSaveServer)
        #expect(model.saveServer() == nil && helper.count(.join) == 0)

        await model.runProbe()?.value
        #expect(model.invitePinProblem == nil && model.canSaveServer && model.addServerHint == "Ready to join.")
        await model.saveServer()?.value
        #expect(helper.lastInput(.join)?["link"] == MultiplayerSocialFixture.link())
        #expect(helper.count(.serverAdd) == 0)
        #expect(model.route == .home && model.notice?.contains("fixture-bo") == true)

        // Editing the address away from the invite's server makes it an ordinary add again.
        model.openInvite("agentcommander://join?server=other.example&pin=")
        model.serverDraft.address = "elsewhere.example"
        #expect(model.activeInvite == nil)
    }

    @Test func anAddressAlreadyInTheListCannotBeSavedAgain() async {
        let existing = MultiplayerFixture.output(#"""
        {"ok":true,"data":{"url":"https://home.example","existing":"s-home","steps":[
          {"step":"dns","ok":true},{"step":"tcp","ok":true},{"step":"tls","ok":true,"systemTrusted":true},
          {"step":"relay","ok":true,"detail":"commander-relay host 1"},{"step":"signin","ok":true}]}}
        """#)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .serverProbe: [existing],
        ])
        let model = Self.model(helper)
        await model.refresh()?.value
        model.startAddServer()
        model.serverDraft.address = "home.example"
        await model.runProbe()?.value
        #expect(model.existingServer?.id == "s-home")
        #expect(!model.canSaveServer && model.addServerHint == "home is already in your list.")
        #expect(model.saveServer() == nil && helper.count(.serverAdd) == 0)
        let relay = model.currentProbe.probe?.step(.relay)
        #expect(relay.map { MultiplayerAddServerForm.detail($0, stage: .relay) } == "commander-relay host 1, compatible")
    }

    @Test func aProfileSaveSendsOnlyWhatChanged() async throws {
        let status = MultiplayerFixture.output(#"{"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada","displayName":"Ada","statusMessage":"Old"}}"#)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .status: [status],
            .profile: [MultiplayerFixture.output(#"{"ok":true,"data":{}}"#)],
            .presence: [MultiplayerFixture.output(#"{"ok":true,"data":{"presence":"dnd","auto":false}}"#)],
        ])
        let model = Self.model(helper)
        model.open()
        await model.settle()
        model.startProfile("s-home")
        #expect(model.route == .profile("s-home") && model.profileDraft.displayName == "Ada")
        #expect(!model.canSaveProfile)
        model.profileDraft.statusMessage = "Shipping the relay"
        #expect(model.canSaveProfile)
        await model.saveProfile()?.value
        #expect(helper.lastInput(.profile) == ["server": "s-home", "statusMessage": "Shipping the relay"])
        #expect(model.route == .server("s-home"))

        await model.setPresence(.dnd)?.value
        #expect(helper.lastInput(.presence) == ["server": "s-home", "presence": "dnd"])
        #expect(model.presenceChoice == .dnd && model.isDoNotDisturb)
        model.close()
    }

    @Test func membershipIsForAdminsAndKeepsAnAdmin() async throws {
        let current = #"{"mode":"allowlist","allowedEmails":["a@example.test"],"admins":["b@example.test"],"memberCount":2}"#
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .me: [MultiplayerFixture.output(#"{"ok":true,"data":{"admin":true,"mode":"allowlist"}}"#)],
            .membership: [MultiplayerFixture.output(#"{"ok":true,"data":\#(current)}"#)],
            .membershipSet: [MultiplayerFixture.output(#"{"ok":true,"data":{"mode":"invite","allowedEmails":["a@example.test","c@example.test"],"admins":["b@example.test"],"memberCount":2}}"#)],
        ])
        let model = Self.model(helper)
        model.startMembership("s-home")
        #expect(model.route == .home)    // not known to be an admin yet
        await model.refresh()?.value
        await model.settle()
        model.startMembership("s-home")
        await model.settle()
        #expect(model.membership.membership?.memberCount == 2 && !model.canSaveMembership)
        model.membershipDraft.admins = ""
        #expect(model.membershipDraft.problem == "Keep at least one admin." && !model.canSaveMembership)
        model.membershipDraft.admins = "B@example.test"
        model.membershipDraft.mode = "invite"
        model.membershipDraft.allowedEmails = "a@example.test, c@example.test\na@example.test"
        #expect(model.canSaveMembership)
        await model.saveMembership()?.value
        #expect(helper.lastRawInput(.membershipSet) == #"{"admins":["b@example.test"],"allowedEmails":["a@example.test","c@example.test"],"mode":"invite","server":"s-home"}"#)
        #expect(model.membership.membership?.mode == "invite")
    }

    @Test func recognisesAServerHostedOnThisMac() {
        let names: Set<String> = ["ryan-mac.local", "ryan-mac", "localhost"]
        #expect(MultiplayerServerAddress.isThisMac("https://ryan-mac.tail.internal:8443", localNames: names))
        #expect(MultiplayerServerAddress.isThisMac("https://localhost", localNames: names))
        #expect(!MultiplayerServerAddress.isThisMac("https://relay.team.example", localNames: names))
        #expect(!MultiplayerServerAddress.isThisMac("https://100.64.0.1", localNames: ["100"]))
        #expect(MultiplayerTally(servers: 1, serversOnline: 1, friendsOnline: 0, needsYou: 0).summary == "Your server is online")
    }
}
