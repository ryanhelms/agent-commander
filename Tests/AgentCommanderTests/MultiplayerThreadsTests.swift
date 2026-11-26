import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Requests 4, 7, 9 and 10 of design/demos/main-window-3/TRAY-REQUESTS.md: an answered row stays for
// a moment, the list of threads the person takes part in, the activity sentence that is true in the
// tray and the main window, and the cockpit's fixture mode. Every name here is made up.

@Suite struct MultiplayerThreadsContractTests {
    static let threads = MultiplayerFixture.output(#"""
    {"ok":true,"data":{"threads":[
      {"request":"ap-7","resource":"res-1","action":"agent.suggest","title":"Pin the clock","at":"2026-11-23T11:59:00Z",
       "direction":"received","peer":"u-bo","handle":"fixture-bo","comments":0},
      {"request":"rq-5","resource":"dir-1","action":"agent.ask","title":"Why does it flake?","at":"2026-11-23T11:50:00Z",
       "direction":"sent","peer":"","handle":""},
      {"request":"rq-4","resource":"res-1","action":"agent.handoff","title":"Run UI tests","at":"2026-11-23T11:40:00Z",
       "direction":"received","peer":"u-bo","handle":"","comments":3,"lastCommentAt":"2026-11-23T11:45:00Z"},
      {"request":"rq-3","resource":"dir-1","action":"agent.fanout","title":"Where?","at":"2026-11-23T11:30:00Z",
       "direction":"sent","peer":"","handle":"",
       "children":[{"request":"c-1","resource":"dir-1"},{"request":"c-2","resource":"dir-2"},{"resource":"no request"},
                   {"request":"c-1","resource":"dir-1"}]},
      {"request":"rq-2","resource":7,"action":null,"at":"not a time","direction":"sideways","comments":"many","children":"none"},
      {"request":"rq-5","title":"a repeat is dropped"},
      {"title":"no request, so it is skipped"},
      "not a row"]}}
    """#)

    @Test func theVerbIsReadOnlyAndNamesNoTarget() {
        #expect(MultiplayerVerb.threads.arguments == ["tray", "threads"])
        #expect(MultiplayerVerb(rawValue: "threads") == .threads)
    }

    @Test func readsSentAndReceivedRowsLeniently() throws {
        let rows = try #require(try MultiplayerEnvelope.decode(MultiplayerThreadList.self, from: Self.threads)).threads
        #expect(rows.map(\.request) == ["ap-7", "rq-5", "rq-4", "rq-3", "rq-2"])
        let now = MultiplayerFixtureClock.start

        // A request still waiting for approval is a received row, with no comments yet.
        let waiting = rows[0]
        #expect(waiting.isReceived && waiting.comments == 0 && waiting.lastCommentAt == nil)
        #expect(waiting.sender == "fixture-bo" && waiting.peer == "u-bo")

        // A consult you sent names no peer: the caller shows the resource.
        let consult = rows[1]
        #expect(consult.isSent && consult.isConsult && !consult.isFanout)
        #expect(consult.peer.isEmpty && consult.handle.isEmpty && consult.sender.isEmpty && consult.resource == "dir-1")
        #expect(consult.comments == nil && consult.children.isEmpty)
        #expect(consult.at == now.addingTimeInterval(-600))
        #expect(consult.actionTitle == MultiplayerCapability.title("agent.ask"))

        let received = rows[2]
        #expect(received.direction == .received && received.comments == 3 && !received.isConsult)
        #expect(received.lastCommentAt == now.addingTimeInterval(-900))
        #expect(received.sender == "u-bo")    // no handle given, so the account

        let fanout = rows[3]
        #expect(fanout.isFanout && fanout.children == [.init(request: "c-1", resource: "dir-1"), .init(request: "c-2", resource: "dir-2")])

        // Wrongly typed fields fall back; the row is kept for its request.
        let odd = rows[4]
        #expect(odd.resource.isEmpty && odd.action.isEmpty && odd.title.isEmpty && odd.at == nil)
        #expect(odd.direction == nil && !odd.isSent && !odd.isReceived && odd.comments == nil && odd.children.isEmpty)
    }

    @Test func anEmptyOrOverlongReplyIsAList() throws {
        let none = try #require(try MultiplayerEnvelope.decode(MultiplayerThreadList.self,
                                                              from: MultiplayerFixture.output(#"{"ok":true,"data":{"threads":null}}"#)))
        #expect(none.threads.isEmpty)
        let many = (1...60).map { #"{"request":"rq-\#($0)","direction":"sent","comments":-4}"# }.joined(separator: ",")
        let capped = try #require(try MultiplayerEnvelope.decode(MultiplayerThreadList.self,
                                                                from: MultiplayerFixture.output(#"{"ok":true,"data":{"threads":[\#(many)]}}"#)))
        #expect(capped.threads.count == MultiplayerThreadList.limit && capped.threads.first?.request == "rq-1")
        #expect(capped.threads.allSatisfy { $0.comments == 0 })
    }

    @Test func theApprovalSentenceIsTrueInTheTrayAndTheMainWindow() {
        let event = MultiplayerActivityEvent(server: "s-home", seq: 1, kind: "approval.pending", actor: "fixture-bo",
                                             resource: "res-1", detail: "agent.ask")
        #expect(event.sentence == "fixture-bo wants to send prompts to the worker. Approve or deny it under Needs you")
        #expect(event.line(on: "team-relay") == "\(event.sentence), on team-relay")
        #expect(!event.sentence.localizedCaseInsensitiveContains("tray"))
    }
}

@MainActor @Suite struct MultiplayerThreadsModelTests {
    @Test func aCallerReadsTheThreadListWithoutMovingTheTray() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.threads: [MultiplayerThreadsContractTests.threads]])
        model.open()
        await model.settle()
        model.go(.hosting)
        let before = helper.count(.threads)
        #expect(before == 0)    // the tray never reads it by itself

        let load = await model.share.loadThreads(on: "s-home")
        #expect(load.value?.map(\.request) == ["ap-7", "rq-5", "rq-4", "rq-3", "rq-2"])
        #expect(helper.lastInput(.threads) == ["server": "s-home"])
        #expect(model.route == .hosting && model.share.thread == .loading)
        #expect(!model.isBusy && model.failure == nil && model.notice == nil)
        model.close()
    }

    @Test func aFailedThreadListSaysWhy() async throws {
        let refused = MultiplayerFixture.output(#"{"ok":false,"error":"relay HTTP 403: not signed in"}"#)
        let (model, _) = MultiplayerShareModelTests.model([.threads: [refused]])
        model.open()
        await model.settle()
        let load = await model.share.loadThreads(on: "s-home")
        #expect(load.value == nil && load.failure?.isEmpty == false)
        #expect(model.route == .home && model.failure == nil)
        let offline = MultiplayerModel(client: nil, setupFailure: .launchFailed)
        let none = await offline.share.loadThreads(on: "s-home")
        #expect(none.failure == MultiplayerFailure.launchFailed.message)
        model.close()
    }

    @Test func theFixtureListsAConsultAndReceivedThreadsWithComments() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("threads")
        let home = MultiplayerRemoteTests.home
        let rows = try #require(await model.share.loadThreads(on: home).value)
        #expect(rows.count <= MultiplayerThreadList.limit)
        #expect(rows.compactMap(\.at) == rows.compactMap(\.at).sorted(by: >))

        // What you sent names no peer.
        let sent = rows.filter(\.isSent)
        #expect(!sent.isEmpty && sent.allSatisfy { $0.peer.isEmpty && $0.handle.isEmpty && $0.comments == nil && !$0.resource.isEmpty })
        let consult = try #require(sent.first { $0.isConsult })
        #expect(consult.request == "rq-consult-1")
        #expect(sent.contains { $0.action == "agent.handoff" } && sent.contains { $0.action == "agent.review" })
        #expect(sent.first { $0.isFanout }?.children.count == 2)

        // What friends sent you always counts its comments, and dates the newest only when there is one.
        let received = rows.filter(\.isReceived)
        #expect(received.allSatisfy { $0.comments != nil && $0.sender == "fixture-sam" })
        #expect(received.allSatisfy { ($0.comments ?? 0 > 0) == ($0.lastCommentAt != nil) })
        let talked = try #require(received.first { $0.request == "rq-in-9" })
        #expect(talked.comments == 2 && talked.isConsult)
        // The count is the thread's own.
        let thread = await model.share.loadThread(talked.request, on: home)
        #expect(thread.value?.comments.count == 2)
        // Requests still waiting for approval are received rows.
        let waiting = model.share.pendingApprovals.map(\.item.id)
        #expect(!waiting.isEmpty && Set(waiting).isSubset(of: Set(received.map(\.request))))

        // A comment raises the count and dates it.
        let quiet = try #require(received.first { $0.comments == 0 })
        let posted = await model.postComment("Noted.", to: quiet.request, on: home)
        #expect(posted.isDone)
        let again = try #require(await model.share.loadThreads(on: home).value?.first { $0.request == quiet.request })
        #expect(again.comments == 1 && again.lastCommentAt != nil)
        #expect(model.route == .home)
        model.close()
    }
}

/// Request 4: an answered row stays in the lists, marked, until its hold ends.
@MainActor @Suite struct MultiplayerAnsweredRowTests {
    static let noApprovals = MultiplayerFixture.output(#"{"ok":true,"data":{"approvals":[]}}"#)
    static func model(_ replies: [MultiplayerVerb: [MultiplayerHelperOutput]], hold: Duration) -> (MultiplayerModel, ScriptedMultiplayerHelper) {
        var all = replies
        all[.servers] = [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)]
        all[.status] = [MultiplayerShareFixture.status]
        let helper = ScriptedMultiplayerHelper(all)
        return (MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                 answeredHold: hold), helper)
    }

    /// Waits for a held row to leave, without tying the test to the clock.
    static func wait(_ what: @MainActor () -> Bool) async {
        for _ in 0..<400 where !what() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theLiveAppHoldsForAboutTwoSecondsAndAModelBuiltWithoutOneDoesNot() {
        #expect(MultiplayerShareModel.answeredHold == .seconds(2))
        #expect(MultiplayerAnswer.approved.title == "Approved" && MultiplayerAnswer.withdrawn.title == "Withdrawn")
        #expect(MultiplayerShareModel.answerKey(.approval, "x-1", on: "s-home") != MultiplayerShareModel.answerKey(.access, "x-1", on: "s-home"))
        #expect(MultiplayerShareModel.answerKey(.approval, "x-1", on: "s-home") != MultiplayerShareModel.answerKey(.approval, "x-1", on: "s-work"))
    }

    @Test func anAnsweredApprovalStaysMarkedThenLeaves() async throws {
        // The next read no longer lists it, as the relay stops listing an answered approval.
        let (model, helper) = Self.model([.approvals: [MultiplayerShareFixture.approvals, Self.noApprovals],
                                          .approve: [MultiplayerShareFixture.empty]], hold: .milliseconds(400))
        model.open()
        await model.settle()
        let pending = try #require(model.share.pendingApprovals.first)
        #expect(model.share.answer(for: pending.item, on: "s-home") == nil && model.tally.needsYou == 2)
        model.share.open(.approval("ap-1"), on: "s-home")

        let result = await model.decide(pending.item, on: "s-home", approve: true)
        #expect(result == .done(id: "ap-1", server: "s-home", message: "Approved. It runs on this Mac now."))
        // The row is still listed, and says how it came out.
        #expect(model.share.pendingApprovals.map(\.item.id) == ["ap-1"])
        #expect(model.share.approvals["s-home"]?.map(\.id) == ["ap-1"])
        #expect(model.share.answer(for: pending.item, on: "s-home") == .approved)
        // Nothing still counts it, and the tray's own page has gone back.
        #expect(model.share.waitingApprovals.isEmpty && model.share.waitingApprovals(on: "s-home").isEmpty)
        #expect(model.tally.needsYou == 1 && model.route == .home)

        // It can't be answered twice, and nothing is sent.
        let again = await model.decide(pending.item, on: "s-home", approve: false)
        #expect(again == .failed(id: "ap-1", server: "s-home", reason: "Couldn’t deny the request. It was already approved."))
        #expect(model.share.decide(pending.item, on: "s-home", approve: false) == nil)
        #expect(helper.count(.deny) == 0 && helper.count(.approve) == 1)

        // The read after the action no longer lists it. It stays until the hold ends.
        await model.settle()
        #expect(helper.count(.approvals) >= 2)
        if model.share.answer(for: pending.item, on: "s-home") != nil {
            #expect(model.share.approvals["s-home"]?.map(\.id) == ["ap-1"])
        }

        await Self.wait { model.share.answered.isEmpty }
        #expect(model.share.answered.isEmpty && model.share.approvals["s-home"]?.isEmpty == true)
        #expect(model.share.pendingApprovals.isEmpty && model.tally.needsYou == 1)
        model.close()
    }

    @Test func aRefusedAnswerMarksNothing() async throws {
        let (model, _) = Self.model([.approvals: [MultiplayerShareFixture.approvals],
                                     .deny: [MultiplayerFixture.output(#"{"ok":false,"error":"no such request"}"#)]],
                                    hold: .milliseconds(400))
        model.open()
        await model.settle()
        let pending = try #require(model.share.pendingApprovals.first)
        let denied = await model.decide(pending.item, on: "s-home", approve: false)
        #expect(!denied.isDone && model.share.answered.isEmpty)
        #expect(model.share.waitingApprovals.map(\.item.id) == ["ap-1"])
        model.close()
    }

    @Test func declinedAndWithdrawnAccessRequestsStayMarkedThenLeave() async throws {
        let helper = AccessRequestHelper()
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     answeredHold: .milliseconds(400))
        model.open()
        await model.settle()
        let incoming = try #require(model.share.incomingAccess("s-home").first)
        let outgoing = try #require(model.share.outgoingAccess("s-home").first)
        #expect(incoming.id == "ar-1" && outgoing.id == "ar-2" && model.share.waitingAccess.count == 1)
        #expect(model.share.waitingRequest(for: "dir-2", on: "s-home")?.id == "ar-2")

        let declined = await model.remove(incoming, on: "s-home", declining: true)
        #expect(declined.isDone && helper.removed == ["ar-1"])
        #expect(model.share.answer(for: incoming, on: "s-home") == .declined)
        #expect(model.share.pendingAccess.map(\.item.id) == ["ar-1"] && model.share.waitingAccess.isEmpty)
        #expect(model.share.unanswered(model.share.incomingAccess("s-home"), on: "s-home").isEmpty)
        let twice = await model.remove(incoming, on: "s-home", declining: true)
        #expect(twice.reason == "Couldn’t decline the request. It was already declined.")
        #expect(helper.removed == ["ar-1"])

        // The read after the action no longer lists it. It stays, in its place, until the hold ends.
        await model.settle()
        if model.share.answer(for: incoming, on: "s-home") != nil {
            #expect(model.share.accessRequests["s-home"]?.map(\.id) == ["ar-1", "ar-2"])
        }
        let withdrawn = await model.remove(outgoing, on: "s-home", declining: false)
        #expect(withdrawn.isDone && model.share.answer(for: outgoing, on: "s-home") == .withdrawn)
        // The directory may offer the request again at once.
        #expect(model.share.waitingRequest(for: "dir-2", on: "s-home") == nil)

        await Self.wait { model.share.answered.isEmpty }
        await model.settle()
        #expect(model.share.answered.isEmpty && helper.removed == ["ar-1", "ar-2"])
        #expect(model.share.incomingAccess("s-home").isEmpty && model.share.outgoingAccess("s-home").isEmpty)
        model.close()
    }

    @Test func withNoHoldAnAnsweredRowLeavesAtOnce() async throws {
        let (model, _) = Self.model([.approvals: [MultiplayerShareFixture.approvals], .approve: [MultiplayerShareFixture.empty]], hold: .zero)
        model.open()
        await model.settle()
        let pending = try #require(model.share.pendingApprovals.first)
        let result = await model.decide(pending.item, on: "s-home", approve: true)
        #expect(result.isDone && model.share.answered.isEmpty && model.share.approvals["s-home"]?.isEmpty == true)
        model.close()
    }
}

/// Answers the relay's access-request routes from a list that shrinks as requests are removed, as
/// the relay does. Every other read comes back empty.
private final class AccessRequestHelper: MultiplayerHelper {
    private let left = Mutex(["ar-1", "ar-2"])
    private let gone = Mutex<[String]>([])

    var removed: [String] { gone.withLock { $0 } }

    private static let rows = [
        "ar-1": #"{"id":"ar-1","resource":"res-1","owner":"u-ada","ownerHandle":"fixture-ada","requester":"u-bo","requesterHandle":"fixture-bo","actions":["issue.read"],"status":"pending","createdAt":"2026-11-23T11:00:00Z"}"#,
        "ar-2": #"{"id":"ar-2","resource":"dir-2","owner":"u-cy","ownerHandle":"fixture-cy","requester":"u-ada","requesterHandle":"fixture-ada","actions":["issue.read"],"status":"pending","createdAt":"2026-11-23T10:00:00Z"}"#]

    func run(verb: MultiplayerVerb, input: Data) async throws -> MultiplayerHelperOutput {
        switch verb {
        case .servers: return MultiplayerServerFixture.servers(MultiplayerServerFixture.home)
        case .status: return MultiplayerShareFixture.status
        case .relay:
            let fields = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
            let path = fields["path"] as? String ?? "", method = (fields["method"] as? String ?? "").uppercased()
            guard path.hasPrefix("/v1/access-requests") else { return MultiplayerShareFixture.empty }
            if method == "DELETE" {
                let id = String(path.split(separator: "/").last ?? "")
                left.withLock { $0.removeAll { $0 == id } }
                gone.withLock { $0.append(id) }
                return MultiplayerShareFixture.empty
            }
            let rows = left.withLock { $0 }.compactMap { Self.rows[$0] }.joined(separator: ",")
            return MultiplayerFixture.output(#"{"ok":true,"data":{"requests":[\#(rows)]}}"#)
        default: return MultiplayerShareFixture.empty
        }
    }
}

/// Request 10: the cockpit runs against the fixture only in a debug build with a home of its own.
@Suite struct MultiplayerFixtureEnvironmentTests {
    static let live = URL(filePath: "/Users/someone/Library/Application Support/Agent Commander", directoryHint: .isDirectory)
    static let bundle = URL(fileURLWithPath: "/Applications/Fixture.app")
    static let bundledPath = "/Applications/Fixture.app/Contents/MacOS/commander-network"
    static let bundled = MultiplayerHelperLocation(url: URL(fileURLWithPath: bundledPath), isFixture: false)
    static let fixture = MultiplayerHelperLocation(url: URL(fileURLWithPath: "/fixture/helper"), isFixture: true)

    static func resolve(_ environment: [String: String], debugBuild: Bool = true,
                        isExecutable: @escaping (String) -> Bool = { _ in true }) -> Result<MultiplayerHelperLocation, MultiplayerFailure> {
        MultiplayerHelperLocator.resolve(environment: environment, bundleURL: bundle, debugBuild: debugBuild, liveHome: live,
                                         isExecutable: isExecutable)
    }

    static func cockpit(home: String?) -> [String: String] {
        var environment = ["COMMANDER_NETWORK_BIN": "/fixture/helper", "COMMANDER_NETWORK_FIXTURE_STATE": "/tmp/run/state.json"]
        environment["AGENT_COMMANDER_HOME"] = home
        return environment
    }

    @Test func aHomeOfItsOwnIsAnAbsoluteFolderAwayFromTheLiveApps() {
        let own: (String?) -> Bool = { MultiplayerHelperLocator.hasOwnHome(environment: Self.cockpit(home: $0), liveHome: Self.live) }
        #expect(own("/tmp/run"))
        #expect(own("/Users/someone/Library/Application Support/Agent Commander Review"))
        #expect(!own(nil) && !own("") && !own("relative/home") && !own("~/home"))
        // The live folder itself, however it is spelled, a folder inside it, and one that holds it.
        #expect(!own(Self.live.path) && !own(Self.live.path + "/"))
        #expect(!own("/Users/someone/Library/Application Support/Other/../Agent Commander"))
        #expect(!own(Self.live.path + "/network") && !own("/Users/someone/Library") && !own("/"))
    }

    @Test func theCockpitUsesTheFixtureWithItsOwnHomeAndNoPanelSwitch() {
        #expect(MultiplayerHelperLocator.isFixtureMode(environment: Self.cockpit(home: "/tmp/run"), debugBuild: true, liveHome: Self.live))
        #expect(Self.resolve(Self.cockpit(home: "/tmp/run")) == .success(Self.fixture))
        // The state file is the fixture's own business: the override alone is enough.
        #expect(Self.resolve(["AGENT_COMMANDER_HOME": "/tmp/run", "COMMANDER_NETWORK_BIN": "/fixture/helper"]) == .success(Self.fixture))
        // A bad override still fails loudly instead of falling back.
        #expect(Self.resolve(["AGENT_COMMANDER_HOME": "/tmp/run", "COMMANDER_NETWORK_BIN": "helper"]) == .failure(.badOverride))
        #expect(Self.resolve(Self.cockpit(home: "/tmp/run"), isExecutable: { $0 == Self.bundledPath }) == .failure(.badOverride))
        // The review panel switch works as before.
        #expect(Self.resolve(["AGENT_COMMANDER_NETWORK_PANEL": "1", "COMMANDER_NETWORK_BIN": "/fixture/helper"]) == .success(Self.fixture))
    }

    @Test func theLiveAppNeverPicksUpTheFixture() {
        // The fixture variables alone: no home.
        #expect(Self.resolve(Self.cockpit(home: nil)) == .success(Self.bundled))
        // A home that is the live folder, or inside it.
        #expect(Self.resolve(Self.cockpit(home: Self.live.path)) == .success(Self.bundled))
        #expect(Self.resolve(Self.cockpit(home: Self.live.path + "/review")) == .success(Self.bundled))
        #expect(Self.resolve(Self.cockpit(home: "relative")) == .success(Self.bundled))
        // Its own home, but no fixture named.
        #expect(Self.resolve(["AGENT_COMMANDER_HOME": "/tmp/run"]) == .success(Self.bundled))
        #expect(Self.resolve(["AGENT_COMMANDER_HOME": "/tmp/run", "COMMANDER_NETWORK_FIXTURE_STATE": "/tmp/run/state.json"])
                == .success(Self.bundled))
        // A release build, whatever is set.
        var everything = Self.cockpit(home: "/tmp/run")
        everything["AGENT_COMMANDER_NETWORK_PANEL"] = "1"
        #expect(Self.resolve(everything, debugBuild: false) == .success(Self.bundled))
        #expect(!MultiplayerHelperLocator.isFixtureMode(environment: everything, debugBuild: false, liveHome: Self.live))
    }

    @Test func aFixtureRunNeverWritesIntoTheLiveAppsFolder() {
        let temporary = URL(filePath: "/tmp/scratch", directoryHint: .isDirectory)
        let location: (Bool, String?) -> String = { isFixture, home in
            var environment: [String: String] = [:]
            environment["AGENT_COMMANDER_HOME"] = home
            return MultiplayerWinnerStore.location(isFixture: isFixture, environment: environment, support: Self.live,
                                                   temporary: temporary).path
        }
        // The cockpit on the fixture keeps everything in its own home.
        #expect(location(true, "/tmp/run") == "/tmp/run/network/fanout-winners.json")
        // The review panel on the fixture, with no home or with the live folder named as home.
        for home in [nil, Self.live.path, Self.live.path + "/review", "relative"] {
            let path = location(true, home)
            #expect(path == "/tmp/scratch/agent-commander-fixture/network/fanout-winners.json")
            #expect(!path.hasPrefix(Self.live.path))
        }
        // The live app is unchanged.
        #expect(location(false, nil) == Self.live.path + "/network/fanout-winners.json")
        #expect(location(false, "/tmp/home") == "/tmp/home/network/fanout-winners.json")
    }
}
