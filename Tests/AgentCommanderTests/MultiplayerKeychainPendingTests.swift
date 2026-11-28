import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// A server whose credential waits on macOS Keychain (issue 139). The sentences are the device
// agent's own. Every host and ID is made up; no test reaches a network, the helper or Keychain.

/// The one server the helper lists, as JSON. A test replaces it to move the list on.
private final class ListedServer: Sendable {
    let json: Mutex<String>
    init(_ json: String) { self.json = Mutex(json) }
}

@MainActor @Suite struct MultiplayerKeychainPendingTests {
    static let waiting = "Respond to the macOS Keychain prompt if one appears. Agent Commander will continue when access is ready."
    static let declined = "Keychain access was declined or unavailable. Turn Connect automatically off and on to retry, then respond to any macOS prompt."

    static func summary(state: String, error: String) -> String {
        #"{"id":"s-lab","url":"https://lab.example","name":"lab","favorite":false,"autoConnect":true,"pin":"","state":"\#(state)","signedIn":false,"handle":"","error":"\#(error)","friendsOnline":0,"incoming":0}"#
    }

    static func status(state: String, error: String) -> MultiplayerHelperOutput {
        MultiplayerFixture.output(#"{"ok":true,"data":{"state":"\#(state)","error":"\#(error)","online":false,"signedIn":false,"loginPending":false,"handle":"","friends":[],"incoming":[],"outgoing":[],"grants":[],"resources":[],"shared":[]}}"#)
    }

    @Test func theSummaryReadsAsItsOwnWaitingState() throws {
        let server = try JSONDecoder().decode(MultiplayerServerSummary.self,
                                              from: Data(Self.summary(state: "keychainPending", error: Self.waiting).utf8))
        #expect(server.state == .keychainPending)
        #expect(server.state.title == "Waiting for Keychain…" && server.stateTitle() == "Waiting for Keychain…")
        // Connecting's lamp and tone, under its own word.
        #expect(server.state.tone == .focus && server.state.lamp == .waiting)
        #expect(server.state.tone == MultiplayerServerState.connecting.tone)
        #expect(server.state.lamp == MultiplayerServerState.connecting.lamp)
        #expect(!server.isReconnecting && server.shownState == .keychainPending && !server.showsSession)
        #expect(MultiplayerModel.problemLine(server) == Self.waiting)

        // The line is never empty, and never the device agent's text when that looks like a secret.
        let bare = MultiplayerServerSummary(id: "s", url: "https://lab.example", name: "lab", state: .keychainPending)
        #expect(MultiplayerModel.problemLine(bare) == MultiplayerServerSummary.keychainWaitingText)
        let odd = MultiplayerServerSummary(id: "s", url: "https://lab.example", name: "lab", state: .keychainPending,
                                           error: "token=abc123 was refused")
        #expect(MultiplayerModel.problemLine(odd) == MultiplayerServerSummary.keychainWaitingText)
    }

    @Test func aDeclinedPromptIsAnErrorWithTheWayToRetry() throws {
        let server = try JSONDecoder().decode(MultiplayerServerSummary.self,
                                              from: Data(Self.summary(state: "error", error: Self.declined).utf8))
        #expect(server.state == .error && server.state.tone == .failure)
        // In error and not signed in: the device agent holds no session, so none is drawn.
        #expect(server.hasNoSession && !server.showsSession)
        #expect(MultiplayerModel.listedHold(server) == .serviceError(Self.declined))
        #expect(MultiplayerModel.problemLine(server) == Self.declined)
    }

    /// The one saved server as the list gives it while connected: signed in, online, presence chosen
    /// by the device agent.
    static let online = #"{"id":"s-lab","url":"https://lab.example","name":"lab","favorite":false,"autoConnect":true,"pin":"","state":"online","signedIn":true,"handle":"fixture-ada","error":"","friendsOnline":2,"incoming":1,"presence":"busy","presenceMode":"auto"}"#

    /// The scoped status of the connected phase, as `data`. The timeline below never replaces it.
    static let onlineStatus = #"""
    {"online":true,"signedIn":true,"handle":"fixture-ada",
     "friends":[{"handle":"fixture-cy","online":true},{"handle":"fixture-bo","online":true}],
     "incoming":[{"id":"in-1","handle":"fixture-dee"}],
     "resources":[{"id":"res-1","name":"relay","kind":"repo","actions":["issue.read"]}]}
    """#

    /// The scoped status once the device agent has a connection and no sign-in, as `data`.
    static let signedOutStatus = #"{"online":false,"signedIn":false,"loginPending":false,"handle":"","friends":[],"incoming":[],"outgoing":[],"grants":[],"resources":[],"shared":[]}"#

    static let contacts = #"{"contacts":[{"contactKey":"k","displayName":"Cy","rows":[{"server":"s-lab","handle":"fixture-cy","presence":"online","online":true}]}]}"#

    /// Nothing of the connected phase is drawn: no friends, requests, availability, presence or sign-out,
    /// on the tray, the window's pages or the shell.
    private func expectNothingOnline(_ model: MultiplayerModel, caption: String) throws {
        // The session's own status is still the connected one. The list's word outranks it.
        let session = try #require(model.session("s-lab"))
        #expect(session.status?.online == true && session.status?.friends.count == 2)
        #expect(!session.isOnline && !session.canSignOut && session.statusDetail == nil)

        #expect(model.tally.serversOnline == 0 && model.tally.friendsOnline == 0 && model.menuSymbol == "person.2")
        let group = model.friendGroups[0]
        #expect(!group.isOnline && group.friends.isEmpty && group.incoming.isEmpty && !group.canShare)
        #expect(group.caption == caption)
        #expect(model.friendServers.isEmpty && model.friendsAvailable == 0)
        #expect(model.requests.status(for: "s-lab") == nil)
        #expect(model.profileDraft(on: "s-lab") == nil)

        // "Auto: Busy" belongs to the connected phase.
        #expect(model.shownPresence == nil && model.effectivePresenceChoice == nil && !model.canSetPresence)
        #expect(model.presenceTitle == "Presence")

        let shell = ShellNetwork(model: model)
        #expect(shell.friendRequests.isEmpty && shell.friendsOnline == 0 && shell.health.online == 0)
        #expect(shell.presence == nil && shell.profile.spokenPresence == "Signed out")

        let page = try #require(NetworkPagesContent(model: model, state: NetworkPagesLiveState()).server("s-lab"))
        #expect(!page.isOnline)
    }

    @Test func aServerThatWasOnlineShowsNothingOfItWhileWaitingOrAfterMacOSRefuses() async throws {
        let listed = ListedServer(Self.online)
        let scoped = ListedServer(Self.onlineStatus)
        let contacts = Self.contacts
        let helper = RoutedMultiplayerHelper { call -> String? in
            switch call.verb {
            case .servers: return #"{"servers":[\#(listed.json.withLock { $0 })]}"#
            case .status: return scoped.json.withLock { $0 }    // lags the list until a step below moves it
            case .contacts: return contacts
            default: return nil
            }
        }
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600))
        model.open()
        await model.settle()

        // Connected: the friends, the request, the availability and the presence are all there.
        #expect(model.servers.map(\.state) == [.online])
        let session = try #require(model.session("s-lab"))
        #expect(session.isOnline && session.canSignOut && session.listedHold == nil)
        #expect(model.friendGroups[0].isOnline && model.friendGroups[0].friends.count == 2 && model.friendGroups[0].incoming.count == 1)
        #expect(model.friendServers.map(\.id) == ["s-lab"] && model.friendsAvailable == 1)
        #expect(model.shownPresence == .busy && model.presenceTitle == "Auto: Busy")
        #expect(ShellNetwork(model: model).profile.spokenPresence == "Auto: Busy")
        #expect(ShellNetwork(model: model).friendRequests.count == 1)

        // The list now says the server waits for Keychain. Its status poll hasn't caught up.
        listed.json.withLock { $0 = Self.summary(state: "keychainPending", error: Self.waiting) }
        await model.refresh()?.value
        await model.settle()
        #expect(model.servers.map(\.state) == [.keychainPending])
        #expect(session.presence == .keychainPending(detail: Self.waiting))
        try expectNothingOnline(model, caption: "waiting for Keychain")

        model.signIn("s-lab")    // there is no sign-in to start
        await model.settle()
        #expect(!helper.all.contains { $0.verb == .login })

        // macOS refused: an error, not signed in. Still the same stale status underneath.
        listed.json.withLock { $0 = Self.summary(state: "error", error: Self.declined) }
        await model.refresh()?.value
        await model.settle()
        #expect(model.servers.map(\.state) == [.error] && model.servers[0].hasNoSession)
        #expect(session.presence == .serviceError(Self.declined))
        try expectNothingOnline(model, caption: model.friendGroups[0].caption)
        #expect(MultiplayerModel.problemLine(model.servers[0]) == Self.declined)

        // A read of the status that fails during the hold doesn't replace the list's word.
        scoped.json.withLock { $0 = "!The device agent isn’t answering." }
        await session.refresh()?.value
        #expect(session.statusFailure != nil && session.presence == .serviceError(Self.declined))
        #expect(!session.isOnline && !session.canSignOut)

        // Retried: the list says signed out. What was read before and during the hold is dropped
        // and the server is read again, so nothing of the connected phase comes back meanwhile.
        let reads = helper.all.filter { $0.verb == .status }.count
        scoped.json.withLock { $0 = Self.signedOutStatus }
        listed.json.withLock { $0 = Self.summary(state: "signedOut", error: "") }
        await model.refresh()?.value
        #expect(session.listedHold == nil && session.statusFailure == nil && session.status?.online != true)
        #expect(!session.isOnline && !session.canSignOut)
        await model.settle()
        await session.settle()
        #expect(helper.all.filter { $0.verb == .status }.count > reads)
        #expect(model.servers.map(\.state) == [.signedOut])
        #expect(session.presence == .signedOut && !session.canSignOut)
        #expect(!model.friendGroups[0].isOnline && model.friendGroups[0].friends.isEmpty)

        // The list says online before the session has read it: still nothing to show.
        scoped.json.withLock { $0 = Self.onlineStatus }
        listed.json.withLock { $0 = Self.online }
        await model.refresh()?.value
        await model.settle()
        #expect(model.servers.map(\.state) == [.online] && session.listedHold == nil)
        #expect(!session.isOnline && model.friendGroups[0].friends.isEmpty)

        // Once it has, the session shows again.
        await session.refresh()?.value
        #expect(session.isOnline && session.canSignOut && model.friendGroups[0].friends.count == 2)
        #expect(model.presenceTitle == "Auto: Busy")
        model.close()
    }

    @Test func otherStatesKeepTheirSession() {
        func server(_ state: MultiplayerServerState, signedIn: Bool, error: String = "") -> MultiplayerServerSummary {
            MultiplayerServerSummary(id: "s", url: "https://lab.example", name: "lab", state: state, signedIn: signedIn, error: error)
        }
        // Offline, reconnecting, signed out and a signed-in error read from their session as before.
        for kept in [server(.online, signedIn: true), server(.offline, signedIn: true), server(.signedOut, signedIn: false),
                     server(.connecting, signedIn: false), server(.error, signedIn: true, error: "lease expired")] {
            #expect(!kept.hasNoSession && kept.showsSession && MultiplayerModel.listedHold(kept) == nil)
        }
        // A changed certificate hides the session by its own rule, with its own notice.
        let changed = server(.certChanged, signedIn: true)
        #expect(!changed.hasNoSession && !changed.showsSession && MultiplayerModel.listedHold(changed) == nil)
    }

    @Test func theJoinChecklistWaitsForKeychainWithoutASignInButton() throws {
        let den = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.den)
        let saved = MultiplayerServerSummary(id: "s-den", url: "https://den-mini.local:8443", name: "den-mini", state: .keychainPending)
        let waiting = MultiplayerJoinChecklist(relay: den, server: saved, signIn: .waitingForKeychain(Self.waiting))
        #expect(waiting.standing == .signIn && waiting.action == nil && !waiting.offersSignInAgain)
        #expect(waiting.step(.signIn).mark == .current && waiting.step(.signIn).detail == Self.waiting)
        #expect(waiting.hint == "Waiting for Keychain…")
        // Any other signed-out server still offers the sign-in.
        let signedOut = MultiplayerServerSummary(id: "s-den", url: "https://den-mini.local:8443", name: "den-mini", state: .signedOut)
        #expect(MultiplayerJoinChecklist(relay: den, server: signedOut).action == .signIn)
    }

    @Test func theJoinChecklistOffersNoSignInAfterMacOSRefuses() throws {
        let den = try MultiplayerDiscoveryFixture.relay(MultiplayerDiscoveryFixture.den)
        let saved = MultiplayerServerSummary(id: "s-den", url: "https://den-mini.local:8443", name: "den-mini", state: .error,
                                             error: Self.declined)
        #expect(saved.hasNoSession)
        // The step carries the device agent's sentence, which names the way to retry.
        let refused = MultiplayerJoinChecklist(relay: den, server: saved)
        #expect(refused.standing == .signIn && refused.action == nil && !refused.offersSignInAgain)
        #expect(refused.step(.signIn).mark == .failed && refused.step(.signIn).detail == Self.declined)
        #expect(refused.hint == MultiplayerJoinChecklist.heldHint)
        // A sign-in that failed earlier offers none either.
        #expect(MultiplayerJoinChecklist(relay: den, server: saved, signIn: .failed("That account isn’t on the list.")).action == nil)
        // In error but signed in, the server still has its session and reads as a member.
        let member = MultiplayerServerSummary(id: "s-den", url: "https://den-mini.local:8443", name: "den-mini", state: .error,
                                              signedIn: true, error: "lease expired")
        #expect(MultiplayerJoinChecklist(relay: den, server: member).action == .openServer("s-den"))
    }

    /// The session of a server in one activation phase, once the tray has read the list and its status.
    private func session(state: String, error: String) async throws -> MultiplayerSessionModel {
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(Self.summary(state: state, error: error))],
            .status: [Self.status(state: state, error: error)],
        ])
        let model = MultiplayerServerFixture.model(helper)
        model.open()
        await model.settle()
        let session = try #require(model.session("s-lab"))
        model.close()
        return session
    }

    @Test func theSessionNamesThePhaseAndOffersNoSignIn() async throws {
        let waiting = try await session(state: "keychainPending", error: Self.waiting)
        #expect(waiting.presence == .keychainPending(detail: Self.waiting))
        #expect(waiting.presence.title == "Waiting for Keychain…" && waiting.presence.tone == .focus)
        #expect(!waiting.isOnline && !waiting.canSignOut)

        // macOS refused: a problem, recovered from the auto-connect switch, not a sign-in to repeat.
        let declined = try await session(state: "error", error: Self.declined)
        #expect(declined.presence == .serviceError(Self.declined))
        #expect(!declined.isOnline && !declined.canSignOut)

        // An ordinary start is a wait, not a sign-in that didn't finish.
        let starting = try await session(state: "connecting", error: "The server is starting. Try again shortly.")
        #expect(starting.presence == .checking)
        #expect(!starting.isOnline)
    }

    @Test func aStatusWithoutAPhaseReadsAsBefore() throws {
        let old = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: MultiplayerServerFixture.homeStatus))
        #expect(old.activation == nil && old.online && old.signedIn)
        let odd = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: Self.status(state: "quarantined", error: "")))
        #expect(odd.activation == .unknown && !odd.online && !odd.signedIn)
    }
}
