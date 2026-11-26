import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Every handle, ID and path here is made up for the test. No test reaches a network or the real
// helper; the process tests run only /usr/bin/false and /usr/bin/yes.

enum MultiplayerFixture {
    static func output(_ json: String, status: Int32 = 0) -> MultiplayerHelperOutput {
        MultiplayerHelperOutput(exitStatus: status, stdout: Data(json.utf8))
    }

    static let ok = output(#"{"ok":true}"#)

    /// Not a credential: an inert placeholder that only exercises the token path.
    static let placeholderToken = "placeholder-value-0"

    static let status = output(#"""
    {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada",
     "friends":[{"handle":"fixture-bo"},{"handle":"fixture-bo"}],
     "incoming":[{"id":"in-1","handle":"fixture-cy"}],
     "grants":[{"id":"g-1","handle":"fixture-bo","kind":"repo","resource":"res-1","capability":"git.push"}],
     "resources":[{"id":"res-1","name":"relay","kind":"repo","actions":["issue.read","git.push"]}],
     "shared":[{"id":"sh-1","name":"bo-agent","kind":"agent","owner":"fixture-bo","actions":["agent.ask"]}]}}
    """#)
}

/// Replies from a script, one queue per verb; the last reply repeats. Records what was sent, except
/// that a `repo-credential` token is checked against a placeholder and recorded only as a mark.
final class ScriptedMultiplayerHelper: MultiplayerHelper {
    private let replies: Mutex<[MultiplayerVerb: [MultiplayerHelperOutput]]>
    private let log = Mutex<[(MultiplayerVerb, Data)]>([])

    init(_ replies: [MultiplayerVerb: [MultiplayerHelperOutput]]) {
        self.replies = Mutex(replies)
    }

    func run(verb: MultiplayerVerb, input: Data) async throws -> MultiplayerHelperOutput {
        var recorded = input
        if verb == .repoCredential, var fields = try? JSONDecoder().decode([String: String].self, from: input) {
            fields["token"] = fields["token"] == MultiplayerFixture.placeholderToken ? "<placeholder>" : "<other>"
            recorded = (try? JSONEncoder().encode(fields)) ?? Data()
        }
        log.withLock { $0.append((verb, recorded)) }
        let next: MultiplayerHelperOutput? = replies.withLock { queues in
            guard var queue = queues[verb], let first = queue.first else { return nil }
            if queue.count > 1 { queue.removeFirst() }
            queues[verb] = queue
            return first
        }
        guard let next else { throw MultiplayerFailure.launchFailed }
        return next
    }

    var verbs: [MultiplayerVerb] { log.withLock { $0.map(\.0) } }

    /// The last all-string request for a verb. A request with a number in it reads as nil here.
    func lastInput(_ verb: MultiplayerVerb) -> [String: String]? {
        guard let data = log.withLock({ $0.last(where: { $0.0 == verb })?.1 }) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// The exact stdin text of the last request for a verb.
    func lastRawInput(_ verb: MultiplayerVerb) -> String? {
        log.withLock { $0.last(where: { $0.0 == verb })?.1 }.map { String(decoding: $0, as: UTF8.self) }
    }

    func count(_ verb: MultiplayerVerb) -> Int { verbs.filter { $0 == verb }.count }
}

/// A clock the test moves by hand.
final class MultiplayerFixtureClock: Sendable {
    /// 2026-11-23T12:00:00Z, a whole minute.
    static let start = Date(timeIntervalSince1970: 1_795_435_200)
    private let value = Mutex(MultiplayerFixtureClock.start)

    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

extension MultiplayerFixture {
    static let hour: TimeInterval = 3600

    static func grantInput(maxUses: Int, expiresAt: String) -> String {
        #"{"capability":"git.push","expiresAt":"\#(expiresAt)","handle":"fixture-bo","kind":"repo","maxUses":\#(maxUses),"resource":"res-1"}"#
    }
}

@Suite struct MultiplayerContractTests {
    @Test func statusDecodesDefiniteValuesAndDropsDuplicates() throws {
        let status = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: MultiplayerFixture.status))
        #expect(status.online && status.signedIn)
        #expect(status.handle == "fixture-ada")
        #expect(status.friends.map(\.handle) == ["fixture-bo"])
        #expect(status.incoming.map(\.id) == ["in-1"])
        #expect(status.grants.first?.capability == "git.push")
        #expect(status.resources.first?.actions == ["issue.read", "git.push"])
        #expect(status.shared.first?.owner == "fixture-bo")
    }

    @Test func statusWithoutDefiniteOnlineIsUnreadable() {
        #expect(throws: MultiplayerFailure.invalidResponse) {
            try MultiplayerEnvelope.decode(MultiplayerStatus.self,
                                           from: MultiplayerFixture.output(#"{"ok":true,"data":{"signedIn":true}}"#))
        }
    }

    @Test func helperErrorIsSurfacedWithoutControlCharacters() {
        let reply = MultiplayerFixture.output(#"{"ok":false,"error":"no such\nhandle\u001b[31m"}"#, status: 1)
        #expect(throws: MultiplayerFailure.rejected("no such handle [31m")) {
            try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: reply)
        }
    }

    @Test func nonzeroExitIsNeverSuccess() {
        #expect(throws: MultiplayerFailure.exited(2)) {
            try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: MultiplayerFixture.output("panic", status: 2))
        }
        #expect(throws: MultiplayerFailure.exited(1)) {
            try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: MultiplayerFixture.output(#"{"ok":true}"#, status: 1))
        }
    }

    @Test func unreadableOutputIsRejected() {
        for text in ["", "not json", "[true]", #"{"ok":"yes"}"#, #"{"ok":true}{"ok":true}"#] {
            #expect(throws: MultiplayerFailure.invalidResponse) {
                try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: MultiplayerFixture.output(text))
            }
        }
    }

    @Test func emptySuccessDataIsAccepted() throws {
        for text in [#"{"ok":true}"#, #"{"ok":true,"data":null}"#, #"{"ok":true,"data":{}}"#] {
            _ = try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: MultiplayerFixture.output(text))
        }
    }

    @Test func commandsCarryOnlyTheirScopedFields() {
        #expect(MultiplayerVerb.resourceAdd.arguments == ["tray", "resource-add"])
        #expect(MultiplayerCommand.login.payload.isEmpty)
        #expect(MultiplayerCommand.claimHandle("fixture-ada").verb == .profile)
        let limits = MultiplayerGrantLimits(maxUses: 100, expiresAt: MultiplayerFixtureClock.start.addingTimeInterval(24 * MultiplayerFixture.hour))
        let grant = MultiplayerCommand.grant(handle: "fixture-bo", kind: "repo", resourceID: "res-1",
                                             resourceName: "relay", capability: "git.push", limits: limits)
        #expect(grant.payload == ["handle": "fixture-bo", "kind": "repo", "resource": "res-1", "capability": "git.push",
                                  "maxUses": 100, "expiresAt": "2026-11-24T12:00:00Z"])
        #expect(MultiplayerCommand.revoke(grantID: "g-1", handle: "fixture-bo", resourceName: "relay",
                                          capability: "git.push").payload == ["id": "g-1"])
        #expect(MultiplayerCommand.accept(requestID: "in-1", handle: "fixture-cy").payload == ["id": "in-1"])
    }

    @Test func grantStdinHasANumericUseCountAndAUTCExpiryString() throws {
        #expect(MultiplayerTime.format(MultiplayerFixtureClock.start) == "2026-11-23T12:00:00Z")
        let limits = MultiplayerGrantLimits(maxUses: 1_000_000,
                                            expiresAt: MultiplayerFixtureClock.start.addingTimeInterval(7 * 24 * MultiplayerFixture.hour + 42))
        let grant = MultiplayerCommand.grant(handle: "fixture-bo", kind: "repo", resourceID: "res-1",
                                             resourceName: "relay", capability: "git.push", limits: limits)
        let data = try MultiplayerClient.encode(grant.payload)
        #expect(String(decoding: data, as: UTF8.self)
                == MultiplayerFixture.grantInput(maxUses: 1_000_000, expiresAt: "2026-11-30T12:00:00Z"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["maxUses"] is NSNumber)
        #expect(!(object["maxUses"] is String))
        #expect(object["expiresAt"] as? String == "2026-11-30T12:00:00Z")
    }

    @Test func otherVerbsStillSendOnlyStrings() throws {
        let commands: [MultiplayerCommand] = [
            .claimHandle("fixture-ada"), .sendRequest(handle: "fixture-bo"), .accept(requestID: "in-1", handle: "fixture-cy"),
            .revoke(grantID: "g-1", handle: "fixture-bo", resourceName: "relay", capability: "git.push"),
            .addResource(id: "res-2", name: "relay", kind: "repo", target: "/fixture/relay"),
        ]
        for command in commands {
            let data = try MultiplayerClient.encode(command.payload)
            let fields = try JSONDecoder().decode([String: String].self, from: data)
            #expect(fields.keys.sorted() == command.payload.keys.sorted())
        }
        #expect(try MultiplayerClient.encode(MultiplayerCommand.logout.payload) == Data("{}".utf8))
    }

    @Test func useCountAcceptsOnlyWholeNumbersInRange() {
        #expect(MultiplayerGrantLimits.parseUses("1") == .success(1))
        #expect(MultiplayerGrantLimits.parseUses("1000000") == .success(1_000_000))
        #expect(MultiplayerGrantLimits.parseUses(" 1,000,000 ") == .success(1_000_000))
        #expect(MultiplayerGrantLimits.parseUses("100") == .success(MultiplayerGrantLimits.defaultUses))
        #expect(MultiplayerGrantLimits.parseUses("") == .failure(.usesMissing))
        #expect(MultiplayerGrantLimits.parseUses("0") == .failure(.usesOutOfRange))
        #expect(MultiplayerGrantLimits.parseUses("1000001") == .failure(.usesOutOfRange))
        #expect(MultiplayerGrantLimits.parseUses("99999999999999999999") == .failure(.usesOutOfRange))
        #expect(MultiplayerGrantLimits.parseUses("-5") == .failure(.usesNotWhole))
        #expect(MultiplayerGrantLimits.parseUses("2.5") == .failure(.usesNotWhole))
        #expect(MultiplayerGrantLimits.parseUses("1e3") == .failure(.usesNotWhole))
        #expect(MultiplayerGrantLimits.parseUses("\u{0661}\u{0662}") == .failure(.usesNotWhole))
    }

    @Test func draftDefaultsToOneHundredUsesForTwentyFourHours() throws {
        let draft = MultiplayerGrantDraft()
        #expect(draft.maxUsesText == "100")
        #expect(draft.expiry == .day)
        let limits = try #require(draft.limits(now: MultiplayerFixtureClock.start))
        #expect(limits.maxUses == 100)
        #expect(limits.expiresAtText == "2026-11-24T12:00:00Z")
    }

    @Test func draftLimitsUseWholeMinutesAndBoundACustomTime() throws {
        let now = MultiplayerFixtureClock.start.addingTimeInterval(30)
        var draft = MultiplayerGrantDraft()
        draft.maxUsesText = "7"
        draft.expiry = .workday
        let preset = try #require(draft.limits(now: now))
        #expect(preset.maxUses == 7)
        #expect(preset.expiresAtText == "2026-11-23T20:00:00Z")    // seconds drop, so the reviewed minute is the sent one

        draft.expiry = .custom
        draft.customExpiry = now.addingTimeInterval(3 * 24 * MultiplayerFixture.hour + 15)
        let custom = try #require(draft.limits(now: now))
        #expect(custom.expiresAtText == "2026-11-26T12:00:00Z")
        draft.customExpiry = now.addingTimeInterval(20)
        #expect(draft.expiryProblem(now: now) == .expiryTooSoon)
        #expect(draft.limits(now: now) == nil)
        draft.customExpiry = now.addingTimeInterval(400 * 24 * MultiplayerFixture.hour)
        #expect(draft.expiryProblem(now: now) == .expiryTooFar)
        draft.customExpiry = now.addingTimeInterval(MultiplayerFixture.hour)
        draft.maxUsesText = "0"
        #expect(draft.usesProblem == .usesOutOfRange)
        #expect(draft.limits(now: now) == nil)
    }

    @Test func grantRowsReadLimitsWhenSuppliedAndStillDecodeSparseReplies() throws {
        let reply = MultiplayerFixture.output(#"""
        {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada","grants":[
         {"id":"g-1","handle":"fixture-bo","kind":"repo","resource":"res-1","capability":"git.push",
          "maxUses":250,"expiresAt":"2026-11-24T12:00:00Z"},
         {"id":"g-2","handle":"fixture-bo","kind":"repo","resource":"res-1","capability":"issue.read",
          "expiresAt":"2026-11-24T12:00:00.500Z"},
         {"id":"g-3","handle":"fixture-bo","kind":"repo","resource":"res-1","capability":"git.head",
          "maxUses":"100","expiresAt":1795521600},
         {"id":"g-4","handle":"fixture-bo","kind":"repo","resource":"res-1","capability":"issue.close"}]}}
        """#)
        let status = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: reply))
        #expect(status.grants.map(\.id) == ["g-1", "g-2", "g-3", "g-4"])
        #expect(status.grants[0].maxUses == 250)
        #expect(status.grants[0].expiresAt.map(MultiplayerTime.format) == "2026-11-24T12:00:00Z")
        #expect(status.grants[1].maxUses == nil)
        #expect(status.grants[1].expiresAt != nil)
        #expect(status.grants[2].maxUses == nil && status.grants[2].expiresAt == nil)
        #expect(status.grants[3].maxUses == nil && status.grants[3].expiresAt == nil)

        let sparse = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: MultiplayerFixture.status))
        #expect(sparse.grants.first?.maxUses == nil && sparse.grants.first?.expiresAt == nil)
    }

    @Test func agentGrantsExplainWhatTheFriendCanDoBeforeConsent() {
        let ask = MultiplayerCapability.explanation("agent.ask", resource: "W-7")
        for phrase in ["submit prompts", "existing tools", "tool permissions you’ve enabled", "your provider quota"] {
            #expect(ask.contains(phrase))
        }
        let message = MultiplayerCapability.explanation("agent.message", resource: "C-1")
        for phrase in ["private inbox", "decides whether to act", "nothing runs automatically"] {
            #expect(message.contains(phrase))
        }
    }

    @Test func resourceDraftValidatesTheExactTarget() {
        var draft = MultiplayerResourceDraft()
        draft.name = "relay"
        draft.target = "src/relay"
        #expect(draft.command(directoryExists: { _ in true }) == nil)
        draft.target = "/fixture/../relay"
        #expect(draft.command(directoryExists: { _ in true }) == nil)
        draft.target = "/fixture/relay"
        #expect(draft.command(directoryExists: { _ in false }) == nil)
        #expect(draft.command(directoryExists: { _ in true })
                == .addResource(id: draft.id, name: "relay", kind: "repo", target: "/fixture/relay"))
        draft.kind = .agent
        draft.target = "run 7"
        #expect(draft.command(directoryExists: { _ in false }) == nil)
        draft.target = "W-7"
        #expect(draft.command(directoryExists: { _ in false })
                == .addResource(id: draft.id, name: "relay", kind: "agent", target: "W-7"))
    }

    @Test func displayTextDropsBidirectionalOverrides() {
        #expect("fixture\u{202E}eda".multiplayerDisplay == "fixture eda")
        #expect(String(repeating: "a", count: 500).multiplayerDisplay.count == 120)
    }

    static let bundle = URL(fileURLWithPath: "/Applications/Fixture.app")
    static let bundledPath = "/Applications/Fixture.app/Contents/MacOS/commander-network"
    static let bundled = MultiplayerHelperLocation(url: URL(fileURLWithPath: bundledPath), isFixture: false)

    /// Fixture mode, stated explicitly: a debug build launched with AGENT_COMMANDER_NETWORK_PANEL=1.
    static func fixtureMode(_ override: String) -> [String: String] {
        ["COMMANDER_NETWORK_BIN": override, "AGENT_COMMANDER_NETWORK_PANEL": "1"]
    }

    @Test func fixtureModeAcceptsOnlyAnAbsoluteExecutableOverride() {
        #expect(MultiplayerHelperLocator.resolve(environment: Self.fixtureMode("fixture-helper"), bundleURL: Self.bundle,
                                                 debugBuild: true, isExecutable: { _ in true }) == .failure(.badOverride))
        #expect(MultiplayerHelperLocator.resolve(environment: Self.fixtureMode("~/fixture-helper"), bundleURL: Self.bundle,
                                                 debugBuild: true, isExecutable: { _ in true }) == .failure(.badOverride))
        // A bad fixture fails loudly; it never falls back to the bundled helper.
        #expect(MultiplayerHelperLocator.resolve(environment: Self.fixtureMode("/fixture/helper"), bundleURL: Self.bundle,
                                                 debugBuild: true, isExecutable: { _ in false }) == .failure(.badOverride))
        #expect(MultiplayerHelperLocator.resolve(environment: Self.fixtureMode("/fixture/helper"), bundleURL: Self.bundle,
                                                 debugBuild: true, isExecutable: { _ in true })
                == .success(MultiplayerHelperLocation(url: URL(fileURLWithPath: "/fixture/helper"), isFixture: true)))
    }

    @Test func normalLaunchesIgnoreTheOverrideAndUseTheBundledHelper() {
        let onlyBundled: (String) -> Bool = { $0 == Self.bundledPath }
        // Debug build without the review switch.
        #expect(MultiplayerHelperLocator.resolve(environment: ["COMMANDER_NETWORK_BIN": "/fixture/helper"],
                                                 bundleURL: Self.bundle, debugBuild: true, isExecutable: onlyBundled)
                == .success(Self.bundled))
        // Release build, even with the review switch.
        #expect(MultiplayerHelperLocator.resolve(environment: Self.fixtureMode("/fixture/helper"),
                                                 bundleURL: Self.bundle, debugBuild: false, isExecutable: { _ in true })
                == .success(Self.bundled))
        #expect(MultiplayerHelperLocator.resolve(environment: Self.fixtureMode("relative-helper"),
                                                 bundleURL: Self.bundle, debugBuild: false, isExecutable: onlyBundled)
                == .success(Self.bundled))
        // No bundled helper: the override is still not used outside fixture mode.
        #expect(MultiplayerHelperLocator.resolve(environment: ["COMMANDER_NETWORK_BIN": "/fixture/helper"],
                                                 bundleURL: Self.bundle, debugBuild: false,
                                                 isExecutable: { $0 == "/fixture/helper" }) == .failure(.helperMissing))
        // Fixture mode without an override uses the bundled helper too.
        #expect(MultiplayerHelperLocator.resolve(environment: ["AGENT_COMMANDER_NETWORK_PANEL": "1"], bundleURL: Self.bundle,
                                                 debugBuild: true, isExecutable: onlyBundled) == .success(Self.bundled))
        #expect(MultiplayerHelperLocator.resolve(environment: [:], bundleURL: Self.bundle, debugBuild: true,
                                                 isExecutable: { _ in false }) == .failure(.helperMissing))
    }
}

@Suite struct MultiplayerProcessTests {
    @Test func nonzeroExitWithoutOutputIsReported() async throws {
        let helper = MultiplayerProcessHelper(executable: URL(fileURLWithPath: "/usr/bin/false"))
        let output = try await helper.run(verb: .status, input: Data("{}".utf8))
        #expect(output.exitStatus != 0)
        #expect(throws: MultiplayerFailure.exited(output.exitStatus)) {
            try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: output)
        }
    }

    @Test func unboundedOutputIsStopped() async {
        let helper = MultiplayerProcessHelper(executable: URL(fileURLWithPath: "/usr/bin/yes"),
                                              timeout: .seconds(10), outputLimit: 4096)
        await #expect(throws: MultiplayerFailure.oversized) {
            try await helper.run(verb: .status, input: Data("{}".utf8))
        }
    }

    @Test func fullInputToAChildThatNeverReadsCannotHang() async {
        let input = Data(repeating: 0x20, count: MultiplayerClient.inputLimit)
        let started = ContinuousClock.now
        // `false` exits without reading; the write must stop on EPIPE without SIGPIPE.
        let quits = MultiplayerProcessHelper(executable: URL(fileURLWithPath: "/usr/bin/false"), timeout: .seconds(5))
        let output = try? await quits.run(verb: .status, input: input)
        #expect(output.map { $0.exitStatus != 0 } ?? false)
        // `yes` never reads stdin and floods stdout; the bound or deadline must end it.
        let floods = MultiplayerProcessHelper(executable: URL(fileURLWithPath: "/usr/bin/yes"),
                                              timeout: .seconds(2), outputLimit: 1 << 20)
        do {
            _ = try await floods.run(verb: .status, input: input)
            Issue.record("A child that never answers must not succeed")
        } catch {
            #expect([MultiplayerFailure.oversized, .timedOut].contains(MultiplayerFailure.from(error)))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func inputOverTheLimitIsNeverWritten() async {
        let helper = MultiplayerProcessHelper(executable: URL(fileURLWithPath: "/usr/bin/false"))
        await #expect(throws: MultiplayerFailure.invalidInput("That entry is too long to send.")) {
            try await helper.run(verb: .status, input: Data(count: MultiplayerClient.inputLimit + 1))
        }
    }

    @Test func missingExecutableFailsToLaunch() async {
        let helper = MultiplayerProcessHelper(executable: URL(fileURLWithPath: "/nonexistent/commander-network"))
        await #expect(throws: MultiplayerFailure.launchFailed) {
            try await helper.run(verb: .status, input: Data("{}".utf8))
        }
    }
}

@MainActor @Suite struct MultiplayerModelTests {
    static func model(_ helper: ScriptedMultiplayerHelper, clock: MultiplayerFixtureClock? = nil) -> MultiplayerSessionModel {
        MultiplayerSessionModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600),
                         fastPoll: .seconds(3600), directoryExists: { _ in true },
                         now: { clock?.now ?? Date() })
    }

    @Test func nothingIsAssumedBeforeTheHelperAnswers() {
        let helper = ScriptedMultiplayerHelper([:])
        let model = Self.model(helper)
        #expect(model.presence == .offline)
        #expect(model.status == nil)
        #expect(!model.isOnline)
        #expect(helper.verbs.isEmpty)
    }

    @Test func openingReadsStatusAndShowsOnlineFromADefiniteReply() async {
        let helper = ScriptedMultiplayerHelper([.status: [MultiplayerFixture.status]])
        let model = Self.model(helper)
        model.open()
        await Task.yield()
        await model.settle()
        #expect(model.presence == .online(handle: "fixture-ada"))
        model.close()
    }

    @Test func failedStatusIsNeverOnline() async {
        let helper = ScriptedMultiplayerHelper([.status: [MultiplayerFixture.output(#"{"ok":true,"data":{"online":true}}"#)]])
        let model = Self.model(helper)
        await model.refresh()?.value
        #expect(model.presence == .unavailable(MultiplayerFailure.invalidResponse.message))
        #expect(model.status == nil)
    }

    @Test func missingHelperIsUnavailableWithoutRetry() {
        let model = MultiplayerSessionModel(client: nil, setupFailure: .helperMissing)
        #expect(model.presence == .unavailable(MultiplayerFailure.helperMissing.message))
        #expect(model.refresh() == nil)
    }

    @Test func friendRequestNeedsAnExactLookupAndIsConfirmedOnlyByTheHelper() async {
        let helper = ScriptedMultiplayerHelper([
            .status: [MultiplayerFixture.status],
            .search: [MultiplayerFixture.output(#"{"ok":true,"data":{"handle":"fixture-dee"}}"#)],
            .request: [MultiplayerFixture.ok],
        ])
        let model = Self.model(helper)
        model.open()
        await Task.yield()
        await model.settle()
        model.startAddFriend()
        model.sendFriendRequest()
        #expect(model.running == nil)

        model.friendDraft = "fixture-dee"
        await model.lookUpFriend()?.value
        #expect(model.currentLookup == .found("fixture-dee"))
        model.sendFriendRequest()
        #expect(model.notice == nil)
        await model.settle()
        #expect(model.notice == "Friend request sent to fixture-dee.")
        #expect(helper.lastInput(.request) == ["handle": "fixture-dee"])
        #expect(helper.verbs.filter { $0 == .status }.count == 2)
        #expect(model.route == .home)
        model.close()
    }

    @Test func aDifferentHandleFromLookupSendsNothing() async {
        let helper = ScriptedMultiplayerHelper([
            .status: [MultiplayerFixture.status],
            .search: [MultiplayerFixture.output(#"{"ok":true,"data":{"handle":"Fixture-Dee"}}"#)],
        ])
        let model = Self.model(helper)
        await model.refresh()?.value
        model.friendDraft = "fixture-dee"
        await model.lookUpFriend()?.value
        guard case .failed = model.currentLookup else {
            Issue.record("A mismatched handle must not be offered")
            return
        }
        model.sendFriendRequest()
        #expect(!helper.verbs.contains(.request))
    }

    @Test func refusedGrantShowsTheHelperErrorAndNoConfirmation() async {
        let helper = ScriptedMultiplayerHelper([
            .status: [MultiplayerFixture.status],
            .grant: [MultiplayerFixture.output(#"{"ok":false,"error":"grant limit reached"}"#, status: 1)],
        ])
        let clock = MultiplayerFixtureClock()
        let model = Self.model(helper, clock: clock)
        await model.refresh()?.value
        model.startGrant(handle: "fixture-bo", resourceID: "res-1")
        model.grantDraft.capability = "git.push"
        model.confirmGrant()
        #expect(model.running == nil)    // a grant is sent only from its confirmation step
        model.reviewGrant()
        model.confirmGrant()
        await model.settle()
        #expect(model.notice == nil)
        #expect(model.actionFailure?.message == "Couldn’t grant access. Grant limit reached.")
        #expect(model.actionFailure?.actionTitle == "Try again")
        #expect(helper.lastRawInput(.grant) == MultiplayerFixture.grantInput(maxUses: 100, expiresAt: "2026-11-24T12:00:00Z"))
    }

    /// Opens the share form for fixture-bo on relay with git.push chosen, at the fixture clock.
    static func grantModel(_ grantReply: MultiplayerHelperOutput = MultiplayerFixture.ok)
        async -> (MultiplayerSessionModel, ScriptedMultiplayerHelper, MultiplayerFixtureClock)
    {
        let helper = ScriptedMultiplayerHelper([.status: [MultiplayerFixture.status], .grant: [grantReply]])
        let clock = MultiplayerFixtureClock()
        let model = Self.model(helper, clock: clock)
        await model.refresh()?.value
        model.startGrant(handle: "fixture-bo", resourceID: "res-1")
        model.grantDraft.capability = "git.push"
        return (model, helper, clock)
    }

    @Test func useCountBoundsGateTheReview() async {
        let (model, helper, _) = await Self.grantModel()
        for text in ["", "0", "1000001", "12.5", "-1"] {
            model.grantDraft.maxUsesText = text
            #expect(!model.canReviewGrant)
            #expect(model.grantUsesProblem != nil)
            model.reviewGrant()
            #expect(model.route == .grant)
        }
        model.grantDraft.maxUsesText = "1000000"
        #expect(model.canReviewGrant)
        model.grantDraft.maxUsesText = "1"
        #expect(model.grantUsesProblem == nil)
        model.reviewGrant()
        #expect(model.route == .confirmGrant)
        #expect(helper.count(.grant) == 0)    // reviewing sends nothing
    }

    @Test func confirmationSendsTheReviewedLimitsAfterADelay() async throws {
        let (model, helper, clock) = await Self.grantModel()
        model.grantDraft.maxUsesText = "250"
        model.grantDraft.expiry = .threeDays
        model.reviewGrant()
        guard case .grant(_, _, _, _, _, let reviewed)? = model.reviewedGrant else {
            Issue.record("Review must fix concrete limits")
            return
        }
        #expect(reviewed == MultiplayerGrantLimits(maxUses: 250, expiresAt: MultiplayerFixtureClock.start.addingTimeInterval(72 * MultiplayerFixture.hour)))
        clock.advance(10 * 60)    // the owner reads the confirmation for ten minutes
        model.confirmGrant()
        await model.settle()
        #expect(helper.lastRawInput(.grant) == MultiplayerFixture.grantInput(maxUses: 250, expiresAt: "2026-11-26T12:00:00Z"))
        #expect(model.notice?.contains("up to 250 uses until") == true)
        #expect(model.reviewedGrant == nil)
        #expect(model.route == .home)
    }

    @Test func aLapsedReviewSendsNothingAndAsksForReconfirmation() async {
        let (model, helper, clock) = await Self.grantModel()
        model.grantDraft.expiry = .hour
        model.reviewGrant()
        clock.advance(2 * MultiplayerFixture.hour)
        model.confirmGrant()
        #expect(model.running == nil)
        #expect(helper.count(.grant) == 0)
        #expect(model.route == .confirmGrant)
        #expect(model.grantReviewNote != nil)
        guard case .grant(_, _, _, _, _, let fresh)? = model.reviewedGrant else {
            Issue.record("A lapsed review must be replaced by a fresh one")
            return
        }
        #expect(fresh.expiresAtText == "2026-11-23T15:00:00Z")
        model.confirmGrant()    // the owner confirms the new limits
        await model.settle()
        #expect(helper.count(.grant) == 1)
        #expect(helper.lastRawInput(.grant) == MultiplayerFixture.grantInput(maxUses: 100, expiresAt: "2026-11-23T15:00:00Z"))
    }

    @Test func aLapsedCustomTimeReturnsToTheEditor() async {
        let (model, helper, clock) = await Self.grantModel()
        model.grantDraft.expiry = .custom
        model.grantDraft.customExpiry = MultiplayerFixtureClock.start.addingTimeInterval(10 * 60)
        model.reviewGrant()
        #expect(model.route == .confirmGrant)
        clock.advance(20 * 60)
        model.confirmGrant()
        #expect(helper.count(.grant) == 0)
        #expect(model.route == .grant)
        #expect(model.reviewedGrant == nil)
        #expect(model.grantExpiryProblem == MultiplayerLimitProblem.expiryTooSoon.message)
        #expect(!model.canReviewGrant)
    }

    @Test func switchingToACustomTimeStartsAtThePresetsEnd() async {
        let (model, _, _) = await Self.grantModel()
        model.grantDraft.expiry = .week
        model.grantDraft.expiry = .custom
        model.grantExpiryChanged(from: .week)
        #expect(MultiplayerTime.format(model.grantDraft.customExpiry) == "2026-11-30T12:00:00Z")
        #expect(model.canReviewGrant)
    }

    @Test func anUnconfirmedGrantIsCheckedNeverResent() async {
        let (model, helper, _) = await Self.grantModel(MultiplayerFixture.output("", status: 1))
        model.reviewGrant()
        model.confirmGrant()
        await model.settle()
        #expect(model.actionFailure?.actionTitle == "Check status")
        model.retryAction()
        await model.settle()
        #expect(helper.count(.grant) == 1)
        #expect(helper.count(.status) == 2)
    }

    @Test func aRefusedGrantIsNotResentWithALapsedExpiry() async {
        let refused = MultiplayerFixture.output(#"{"ok":false,"error":"try later"}"#, status: 1)
        let (model, helper, clock) = await Self.grantModel(refused)
        model.grantDraft.expiry = .hour
        model.reviewGrant()
        model.confirmGrant()
        await model.settle()
        #expect(model.actionFailure?.actionTitle == "Try again")
        clock.advance(2 * MultiplayerFixture.hour)
        model.retryAction()
        await model.settle()
        #expect(helper.count(.grant) == 1)
        #expect(model.route == .confirmGrant)
        #expect(model.grantReviewNote != nil)
    }

    @Test func unconfirmedRevokeIsCheckedNotResent() async throws {
        let helper = ScriptedMultiplayerHelper([
            .status: [MultiplayerFixture.status],
            .revoke: [MultiplayerFixture.output("", status: 1)],
        ])
        let model = Self.model(helper)
        await model.refresh()?.value
        let grant = try #require(model.status?.grants.first)
        model.askRevoke(grant)
        model.confirmRevoke()
        await model.settle()
        #expect(model.actionFailure?.actionTitle == "Check status")
        model.retryAction()
        await model.settle()
        #expect(helper.verbs.filter { $0 == .revoke }.count == 1)
        #expect(helper.verbs.filter { $0 == .status }.count == 2)
    }

    @Test func signInWaitsForTheStatusToConfirm() async {
        let signedOut = MultiplayerFixture.output(#"{"ok":true,"data":{"online":true,"signedIn":false,"handle":""}}"#)
        let pending = MultiplayerFixture.output(#"{"ok":true,"data":{"online":true,"signedIn":false,"loginPending":true}}"#)
        let helper = ScriptedMultiplayerHelper([.status: [signedOut, pending], .login: [MultiplayerFixture.ok]])
        let model = Self.model(helper)
        model.open()
        await Task.yield()
        await model.settle()
        #expect(model.presence == .signedOut)
        model.signIn()
        await model.settle()
        #expect(model.presence == .waitingForBrowser)
        #expect(!model.isOnline)
        model.close()
    }

    @Test func serviceLoginStateIsAuthoritativeAcrossReopen() async {
        let pending = MultiplayerFixture.output(#"{"ok":true,"data":{"online":false,"signedIn":false,"loginPending":true}}"#)
        let ended = MultiplayerFixture.output(#"{"ok":true,"data":{"online":false,"signedIn":false,"loginPending":false}}"#)
        let helper = ScriptedMultiplayerHelper([.status: [pending, ended]])
        let model = Self.model(helper)
        model.open()
        await Task.yield()
        await model.settle()
        #expect(model.presence == .waitingForBrowser)
        model.close()
        #expect(model.status == nil)    // a reopen asks the service before showing sign-in state
        model.open()
        await Task.yield()
        await model.settle()
        #expect(model.presence == .signInIncomplete(detail: nil))
        model.close()
    }

    /// A made-up enrollment refusal, phrased as the service's display-safe text.
    static let refusal = "This account needs access to the relay. Sign in again and choose the invited account."

    static func signedOut(error: String) -> MultiplayerHelperOutput {
        MultiplayerFixture.output(#"{"ok":true,"data":{"online":true,"signedIn":false,"loginPending":false,"error":"\#(error)"}}"#)
    }

    @Test func aDeniedSignInShowsTheReasonAndCanBeRetried() async {
        let pending = MultiplayerFixture.output(#"{"ok":true,"data":{"online":true,"signedIn":false,"loginPending":true}}"#)
        let helper = ScriptedMultiplayerHelper([
            .status: [pending, Self.signedOut(error: Self.refusal), pending, MultiplayerFixture.status],
            .login: [MultiplayerFixture.ok],
        ])
        let model = Self.model(helper)
        model.open()
        await Task.yield()
        await model.settle()
        #expect(model.presence == .waitingForBrowser)

        await model.refresh()?.value    // the browser sign-in was refused at enrollment
        #expect(model.presence == .signInIncomplete(detail: Self.refusal))
        #expect(!model.isOnline && !model.canSignOut)

        model.signIn()    // the card keeps Sign in with browser, so the developer can choose another account
        await model.settle()
        #expect(helper.count(.login) == 1)
        #expect(model.presence == .waitingForBrowser)

        await model.refresh()?.value
        #expect(model.presence == .online(handle: "fixture-ada"))
        model.close()
    }

    @Test func aReopenedPanelOffersSignInForASignedOutError() async {
        let helper = ScriptedMultiplayerHelper([
            .status: [Self.signedOut(error: Self.refusal)],
            .login: [MultiplayerFixture.ok],
        ])
        let model = Self.model(helper)
        model.open()
        await Task.yield()
        await model.settle()
        model.close()
        model.open()
        await Task.yield()
        await model.settle()
        #expect(model.presence == .signInIncomplete(detail: Self.refusal))
        model.signIn()
        await model.settle()
        #expect(helper.count(.login) == 1)
        model.close()
    }

    @Test func aSignedOutErrorThatNeedsRedactionFallsBackToTheGenericLine() async {
        let helper = ScriptedMultiplayerHelper([.status: [Self.signedOut(error: "denied github_pat_placeholder")]])
        let model = Self.model(helper)
        await model.refresh()?.value
        #expect(model.presence == .signInIncomplete(detail: nil))
    }

    @Test func aSignedInErrorStaysAServiceProblem() async {
        let reply = MultiplayerFixture.output(#"""
        {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada","error":"\#(Self.refusal)"}}
        """#)
        let helper = ScriptedMultiplayerHelper([.status: [reply]])
        let model = Self.model(helper)
        await model.refresh()?.value
        #expect(model.presence == .serviceError(Self.refusal))
        #expect(!model.isOnline)
        #expect(model.canSignOut)
    }

    @Test func serviceErrorIsNeverOnlineAndHidesHandleAndSecrets() async {
        let reply = MultiplayerFixture.output(#"""
        {"ok":true,"data":{"online":true,"signedIn":true,"handle":"","error":"auth failed ghp_placeholder"}}
        """#)
        let helper = ScriptedMultiplayerHelper([.status: [reply]])
        let model = Self.model(helper)
        await model.refresh()?.value
        guard case .serviceError(let text) = model.presence else {
            Issue.record("A status error must win over online and handle setup")
            return
        }
        #expect(!text.contains("ghp_"))
        #expect(model.statusDetail == nil)
        #expect(!model.isOnline)
        #expect(model.canRefresh)
    }

    @Test func outgoingAndPresenceAreShownOnlyWhenSupplied() throws {
        let reply = MultiplayerFixture.output(#"""
        {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada",
         "friends":[{"id":"f-1","handle":"fixture-bo","online":true},{"handle":"fixture-cy"}],
         "outgoing":[{"id":"o-1","handle":"fixture-dee","online":false}]}}
        """#)
        let status = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: reply))
        #expect(status.friends.map(\.presenceTitle) == ["Online", nil])
        #expect(status.friends.last?.id == "fixture-cy")
        #expect(status.outgoing.first?.presenceTitle == "Offline")
        #expect(!status.loginPending && status.error.isEmpty)
    }
}

@MainActor @Suite struct MultiplayerCredentialTests {
    static func onlineModel() async -> (MultiplayerSessionModel, ScriptedMultiplayerHelper) {
        let helper = ScriptedMultiplayerHelper([
            .status: [MultiplayerFixture.status],
            .repoCredential: [MultiplayerFixture.ok],
        ])
        let model = MultiplayerModelTests.model(helper)
        model.open()
        await Task.yield()
        await model.settle()
        return (model, helper)
    }

    @Test func onlyAnOwnedRepositoryOpensTheEditor() async {
        let (model, _) = await Self.onlineModel()
        model.startCredential(resourceID: "sh-1")    // shared with you: never offered
        #expect(model.route == .home)
        model.startCredential(resourceID: "res-1")
        #expect(model.route == .repoCredential(resourceID: "res-1"))
        #expect(model.credentialResource?.id == "res-1")
        model.close()
    }

    @Test func emptyOrSpacedEntrySendsNothing() async {
        let (model, helper) = await Self.onlineModel()
        model.startCredential(resourceID: "res-1")
        #expect(!model.canSaveCredential)
        #expect(model.saveCredential() == nil)
        model.startCredential(resourceID: "res-1")
        model.credentialEntry.value = "two words"
        #expect(model.credentialProblem != nil)
        #expect(model.saveCredential() == nil)
        #expect(model.credentialEntry.value.isEmpty)
        #expect(!helper.verbs.contains(.repoCredential))
        model.close()
    }

    @Test func saveSendsOnlyResourceAndTokenAndKeepsNothing() async {
        let (model, helper) = await Self.onlineModel()
        model.startCredential(resourceID: "res-1")
        model.credentialEntry.value = MultiplayerFixture.placeholderToken
        model.saveCredential()
        #expect(model.credentialEntry.value.isEmpty)    // cleared before the helper answers
        #expect(model.route == .home)
        await model.settle()
        #expect(helper.lastInput(.repoCredential) == ["resource": "res-1", "token": "<placeholder>"])
        #expect(model.notice == "Saved the GitHub token for relay.")
        #expect(String(describing: model.credentialEntry) == "MultiplayerSecretEntry(redacted)")
        model.close()
    }

    @Test func unconfirmedSaveAsksForReentryWithoutKeepingTheValue() async {
        let helper = ScriptedMultiplayerHelper([
            .status: [MultiplayerFixture.status],
            .repoCredential: [MultiplayerFixture.output("", status: 1)],
        ])
        let model = MultiplayerModelTests.model(helper)
        await model.refresh()?.value
        model.startCredential(resourceID: "res-1")
        model.credentialEntry.value = MultiplayerFixture.placeholderToken
        model.saveCredential()
        await model.settle()
        let failure = model.credentialFailure
        #expect(failure?.actionTitle == "Enter again")
        #expect(failure?.message.contains(MultiplayerFixture.placeholderToken) == false)
        #expect(model.actionFailure == nil)
        model.reenterCredential()
        #expect(model.route == .repoCredential(resourceID: "res-1"))
        #expect(model.credentialEntry.value.isEmpty)
        #expect(helper.verbs.filter { $0 == .repoCredential }.count == 1)
    }

    @Test func cancelNavigationAndCloseClearTheEntry() async {
        let (model, _) = await Self.onlineModel()
        model.startCredential(resourceID: "res-1")
        model.credentialEntry.value = MultiplayerFixture.placeholderToken
        model.go(.home)
        #expect(model.credentialEntry.value.isEmpty)
        model.startCredential(resourceID: "res-1")
        model.credentialEntry.value = MultiplayerFixture.placeholderToken
        model.close()
        #expect(model.credentialEntry.value.isEmpty)
        #expect(model.route == .home)
    }

    @Test func clientRejectsAnEmptyTokenBeforeTheHelper() async {
        let helper = ScriptedMultiplayerHelper([.repoCredential: [MultiplayerFixture.ok]])
        await #expect(throws: MultiplayerFailure.invalidInput("That token can’t be sent.")) {
            try await MultiplayerClient(helper: helper).saveRepoCredential(resourceID: "res-1", token: "")
        }
        #expect(helper.verbs.isEmpty)
    }

    @Test func redactionHidesTokenShapedWords() {
        let text = MultiplayerText.clean("denied github_pat_placeholder and \(String(repeating: "a1", count: 20))",
                                         limit: 200, redact: true)
        #expect(text == "denied [redacted] and [redacted]")
    }
}
