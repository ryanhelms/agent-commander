import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Watch, Co-pilot suggestions, control hand-over, Review exchange and Fan-out
// (design/COMMANDER-NETWORK-INCREMENT-4.md). Every handle, resource and URL here is made up.
// No test reaches a network, the real helper or GitHub.

enum MultiplayerLiveFixture {
    static func json(_ text: String) throws -> MultiplayerJSON {
        try JSONDecoder().decode(MultiplayerJSON.self, from: Data(text.utf8))
    }

    static func ok(_ data: String) -> MultiplayerHelperOutput {
        MultiplayerFixture.output(#"{"ok":true,"data":\#(data)}"#)
    }

    static let live = #"["agent.ask","agent.suggest","agent.watch","review.request","thread.comment","thread.read"]"#

    /// fixture-ada owns one worker, shared with fixture-bo. Two friends' workers can be prompted.
    static let status = MultiplayerFixture.output(#"""
    {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada",
     "friends":[{"handle":"fixture-bo","user":"u-bo"},{"handle":"fixture-cy","user":"u-cy"}],
     "resources":[{"id":"res-9","name":"tests","kind":"agent","actions":\#(live)}],
     "grants":[{"id":"g-1","handle":"fixture-bo","kind":"agent","resource":"res-9","capability":"agent.ask"},
               {"id":"g-2","handle":"fixture-bo","kind":"agent","resource":"res-9","capability":"agent.suggest"},
               {"id":"g-3","handle":"fixture-cy","kind":"agent","resource":"res-9","capability":"agent.watch"}],
     "directory":[
       {"id":"dir-1","owner":"u-bo","handle":"fixture-bo","kind":"agent","name":"bo-agent","actions":\#(live),"grantedActions":\#(live)},
       {"id":"dir-2","owner":"u-cy","handle":"fixture-cy","kind":"agent","name":"cy-agent","actions":\#(live),
        "grantedActions":["agent.ask","thread.read"]},
       {"id":"dir-3","owner":"u-cy","handle":"fixture-cy","kind":"agent","name":"cy-idle","actions":\#(live),"grantedActions":[]}]}}
    """#)

    static let review = #"{"summary":"Bound the wait.","findings":[{"file":"Tests/A.swift","line":43,"severity":"important","text":"No deadline."},{"file":"B.swift","line":0,"severity":"nit","text":"Unused helper."},{"file":"C.swift"}]}"#

    @MainActor static func model(_ replies: [MultiplayerVerb: [MultiplayerHelperOutput]],
                                 winners: MultiplayerWinnerStore = .scratch()) -> (MultiplayerModel, ScriptedMultiplayerHelper) {
        var all = replies
        all[.servers] = all[.servers] ?? [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)]
        all[.status] = all[.status] ?? [status]
        let helper = ScriptedMultiplayerHelper(all)
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     winners: winners, watchInterval: .milliseconds(15))
        return (model, helper)
    }

    /// A winners file of this test's own, empty.
    static func winners() -> MultiplayerWinnerStore { .scratch() }

    /// Waits for something a background poll brings, without sleeping longer than it takes.
    @MainActor static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// A gate a test opens by hand, once. Opening it before anything waits is kept, so no signal is
/// lost; a waiter whose task is cancelled leaves at once.
private final class MultiplayerOneShotGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        stream = made.stream
        continuation = made.continuation
    }

    /// Opens the gate. Opening it again does nothing.
    func release() {
        continuation.yield()
        continuation.finish()
    }

    /// Returns once the gate is open, or throws when the waiting task is cancelled first.
    func wait() async throws {
        for await _ in stream { break }
        try Task.checkCancellation()
    }
}

/// The scripted helper, with the first reply to one verb held until the test opens the gate.
/// The held call reaches the script, and its log, only after the gate opens. A request that names
/// one of `others` is answered by that server's own script, and is never held.
private final class MultiplayerGatedHelper: MultiplayerHelper {
    let scripted: ScriptedMultiplayerHelper
    let gate = MultiplayerOneShotGate()
    private let held: MultiplayerVerb
    private let others: [String: ScriptedMultiplayerHelper]
    private let isUsed = Mutex(false)

    init(_ scripted: ScriptedMultiplayerHelper, holding verb: MultiplayerVerb, others: [String: ScriptedMultiplayerHelper] = [:]) {
        self.scripted = scripted
        self.held = verb
        self.others = others
    }

    func run(verb: MultiplayerVerb, input: Data) async throws -> MultiplayerHelperOutput {
        let server = (try? JSONSerialization.jsonObject(with: input) as? [String: Any])?["server"] as? String
        if let other = server.flatMap({ others[$0] }) { return try await other.run(verb: verb, input: input) }
        let isFirst = verb == held && isUsed.withLock { used in
            defer { used = true }
            return !used
        }
        if isFirst { try await gate.wait() }
        return try await scripted.run(verb: verb, input: input)
    }
}

@Suite struct MultiplayerLiveContractTests {
    @Test func tracksTheLiveVerbs() {
        #expect(Set(["watch", "handover", "handback", "handovers", "fanout", "review-post"])
            .isSubset(of: Set(MultiplayerVerb.allCases.map(\.rawValue))))
        #expect(MultiplayerVerb.reviewPost.arguments == ["tray", "review-post"])
        // A fan-out may carry as much as a single request.
        #expect(MultiplayerClient.inputLimit(for: .fanout) == MultiplayerClient.sendInputLimit)
    }

    @Test func aWatchReplyIsReadBareOrInsideTheRequestsRow() throws {
        let events = #"{"events":[{"at":"2026-11-25T12:00:01Z","kind":"tool","text":"swift test"},{"kind":"odd","text":"said"},{"kind":"status"}],"cursor":"7","state":"running"}"#
        let bare = MultiplayerWatchReply(try MultiplayerLiveFixture.json(events))
        // A line without text is dropped; an unknown kind reads as a message.
        #expect(bare.events.map(\.kind) == [.tool, .message] && bare.cursor == "7" && bare.state == "running")
        #expect(bare.events[0].at != nil && bare.refusal == nil)
        for field in ["value", "result"] {
            let row = MultiplayerWatchReply(try MultiplayerLiveFixture.json(#"{"id":"c-1","status":"ok","\#(field)":\#(events)}"#))
            #expect(row.events.count == 2 && row.cursor == "7" && row.refusal == nil)
        }
    }

    @Test func aWatchReplyReadsCommandersOwnHistoryPage() throws {
        let reply = MultiplayerWatchReply(try MultiplayerLiveFixture.json(#"""
        {"status":"ok","value":{"state":"working","available":true,"page":{"observations":[
          {"cursor":"c-1","text":{"speaker":"assistant","text":"Reading the test."}},
          {"cursor":"c-2","tool":{"name":"shell","summary":"swift test"}},
          {"cursor":"c-3","gap":{"reason":"compacted"}},
          {"cursor":"c-4","turnEnded":{"reason":"awaiting_input"}}],"nextCursor":"page-2"}}}
        """#))
        #expect(reply.events.map(\.kind) == [.message, .tool, .status])
        #expect(reply.events[1].text == "shell: swift test" && reply.cursor == "page-2" && reply.state == "working")
    }

    @Test func aRefusedWatchSaysWhyAndWhetherAskingAgainHelps() throws {
        let denied = MultiplayerWatchReply(try MultiplayerLiveFixture.json(#"{"status":"denied"}"#))
        #expect(denied.refusal == "The owner denied Watch on this worker." && !denied.mayRecover)
        let pending = MultiplayerWatchReply(try MultiplayerLiveFixture.json(#"{"status":"pending"}"#))
        #expect(pending.refusal != nil && pending.mayRecover && pending.events.isEmpty)
    }

    @Test func aWatchLineNeverDrawsACredential() throws {
        let event = try #require(MultiplayerWatchEvent(try MultiplayerLiveFixture.json(
            #"{"kind":"tool","text":"export TOKEN=ghp_\#(String(repeating: "a", count: 36))\nnext"}"#)))
        #expect(event.text == "export [redacted] next")
    }

    @MainActor @Test func aHandoverCountsDownAndIsNamedByHandleOrAccount() throws {
        let now = MultiplayerFixtureClock.start
        let listed = try #require(MultiplayerHandover(try MultiplayerLiveFixture.json(
            #"{"user":"u-bo","resource":"res-9","until":"2026-11-23T12:24:13Z"}"#)))
        // An account alone is never shown as a name, and is what `handback` is given.
        #expect(listed.handle.isEmpty && listed.who == "A friend" && listed.holderKey == "u-bo" && listed.id == "u-bo|res-9")
        #expect(listed.remaining(now: now) == 24 * 60 + 13 && listed.isLive(now: now))
        // With no length known, the line drains over the shortest length that holds what is left.
        #expect(listed.span(now: now) == 1800 && abs(listed.fraction(now: now) - (1453.0 / 1800)) < 0.0001)
        var mine = listed
        mine.minutes = 60
        #expect(mine.span(now: now) == 3600 && abs(mine.fraction(now: now) - (1453.0 / 3600)) < 0.0001)
        // The device agent names the friend and the server.
        let named = try #require(MultiplayerHandover(try MultiplayerLiveFixture.json(
            #"{"user":"u-bo","handle":"fixture-bo","server":"s-home","resource":"res-9","until":"2026-11-23T12:24:13Z"}"#)))
        #expect(named.handle == "fixture-bo" && named.who == "fixture-bo" && named.server == "s-home" && named.holderKey == "u-bo")
        #expect(MultiplayerCountdown.fraction(left: 300, span: 600) == 0.5 && MultiplayerCountdown.fraction(left: 5, span: 0) == 0)
        #expect(!listed.isLive(now: now.addingTimeInterval(3600)) && listed.remaining(now: now.addingTimeInterval(3600)) == 0)
        // A row with no end is not a hand-over.
        #expect(MultiplayerHandover(try MultiplayerLiveFixture.json(#"{"user":"u-bo","resource":"res-9"}"#)) == nil)
        #expect(MultiplayerHandover.clock(1453) == "24:13" && MultiplayerHandover.clock(3733) == "1:02:13")
        #expect(MultiplayerHandover.clock(0.2) == "0:01" && MultiplayerHandover.clock(-5) == "0:00")
        #expect(MultiplayerHandover.spoken(1453) == "25 minutes left" && MultiplayerHandover.spoken(0) == "ended")
        #expect(MultiplayerHandoverLength.allCases.allSatisfy { (1...240).contains($0.rawValue) })
    }

    @Test func aReviewListsItsFindingsAndKeepsARawAnswerAsTheSummary() throws {
        let review = try #require(MultiplayerReview(try MultiplayerLiveFixture.json(MultiplayerLiveFixture.review)))
        // A finding without text is dropped.
        #expect(review.findings.count == 2 && review.important == 1 && review.tally == "1 important, 1 nit")
        #expect(review.findings[0].location == "Tests/A.swift:43" && review.findings[1].location == "B.swift")
        #expect(review.findings[1].severityTitle == "Nit")
        let raw = try #require(MultiplayerReview(.string("  Looks fine to me.  ")))
        #expect(raw.summary == "Looks fine to me." && raw.findings.isEmpty && raw.tally == "No findings")
        #expect(MultiplayerReview(nil) == nil && MultiplayerReview(.object([:])) == nil)
    }

    @Test func aReviewRequestNeedsATitleAndAPullRequestOrADiff() throws {
        var draft = MultiplayerReviewDraft(title: " Bound the wait ")
        #expect(!draft.canSend)
        draft.pr = "github.com/a/b/pull/1"
        #expect(!draft.canSend && draft.problem == "A pull request URL starts with https://.")
        draft.pr = "https://example.test/a/b/pull/1"
        draft.instructions = "Look at the timeout."
        #expect(draft.canSend)
        #expect(draft.payload == .object(["title": .string("Bound the wait"), "pr": .string("https://example.test/a/b/pull/1"),
                                          "instructions": .string("Look at the timeout.")]))
        draft.pr = ""
        draft.diff = MultiplayerContextItem(name: "fix.diff", content: "--- a\n+++ b\n")
        #expect(draft.canSend && draft.payload["diff"] == .string("--- a\n+++ b\n") && draft.payload["pr"] == nil)
        draft.diff = MultiplayerContextItem(name: "big.diff", content: String(repeating: "x", count: 97 * 1024))
        #expect(!draft.canSend)
        #expect(!MultiplayerReviewDraft.isPullRequest("https://exa mple.test/pull/1"))
    }

    @Test func aFanoutReadsItsChildrenFromAListOrFromTheSubmission() throws {
        let children = #"[{"id":"c-1","resource":"dir-1","action":"agent.ask","status":"ok","result":{"text":"Client."}},{"id":"c-2","resource":"dir-2","action":"agent.ask","status":"pending"},{"status":"ok"}]"#
        let nested = try #require(MultiplayerFanout(try MultiplayerLiveFixture.json(#"{"request":"rq-1","children":{"id":"rq-1","children":\#(children)}}"#)))
        let flat = try #require(MultiplayerFanout(try MultiplayerLiveFixture.json(#"{"request":"rq-1","title":"Where?","children":\#(children)}"#)))
        #expect(nested.children == flat.children && flat.title == "Where?")
        #expect(nested.children.map(\.id) == ["c-1", "c-2"])
        #expect(nested.children[0].succeeded && nested.children[0].answer == "Client.")
        #expect(!nested.children[1].isSettled && nested.progress == "1 of 2 answered" && !nested.isSettled)
        #expect(MultiplayerFanout(try MultiplayerLiveFixture.json(#"{"children":[]}"#)) == nil)
    }

    @Test func aFanoutTakesTwoToThirtyTwoTargetsAndAPrompt() {
        var draft = MultiplayerFanoutDraft(targets: ["dir-1"], prompt: "Where should the budget live?\nBe brief.")
        #expect(!draft.canSend)
        draft.targets.insert("dir-2")
        #expect(draft.canSend && draft.title == "Where should the budget live?")
        #expect(draft.payload == .object(["text": .string("Where should the budget live?\nBe brief.")]))
        draft.targets = Set((0..<33).map { "dir-\($0)" })
        #expect(!draft.canSend && draft.problem == "A fan-out takes at most 32 targets.")
        draft.targets = ["dir-1", "dir-2"]
        draft.prompt = "  "
        #expect(!draft.canSend)
    }

    @Test func theWinnerIsKeptOnThisMacAndCanBeCleared() throws {
        let store = MultiplayerLiveFixture.winners()
        defer { try? FileManager.default.removeItem(at: store.file) }
        #expect(store.all.isEmpty)
        store.choose("c-2", for: "rq-1", on: "s-a")
        store.choose("c-9", for: "rq-2", on: "s-a")
        // The same request ID on another server is another fan-out.
        store.choose("c-5", for: "rq-1", on: "s-b")
        #expect(MultiplayerWinnerStore(file: store.file).all == ["s-a/rq-1": "c-2", "s-a/rq-2": "c-9", "s-b/rq-1": "c-5"])
        #expect(store.winner(of: "rq-1", on: "s-a") == "c-2" && store.winner(of: "rq-1", on: "s-b") == "c-5")
        store.choose(nil, for: "rq-1", on: "s-a")
        #expect(store.all == ["s-a/rq-2": "c-9", "s-b/rq-1": "c-5"])
        // The file holds one dictionary under the store's key, and nothing is written to preferences.
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: [String: String]]
        #expect(root?.keys.map { $0 } == [MultiplayerWinnerStore.key])
        #expect(UserDefaults.standard.object(forKey: MultiplayerWinnerStore.key) == nil)
    }

    @Test func theWinnersFileIsNeverInTheLiveAppsFolderForAFixtureRun() {
        let support = URL(filePath: "/Users/someone/Library/Application Support/Agent Commander", directoryHint: .isDirectory)
        let temporary = URL(filePath: "/tmp/scratch", directoryHint: .isDirectory)
        let live = MultiplayerWinnerStore.location(isFixture: false, environment: [:], support: support, temporary: temporary)
        #expect(live.path == "/Users/someone/Library/Application Support/Agent Commander/network/fanout-winners.json")
        let fixture = MultiplayerWinnerStore.location(isFixture: true, environment: [:], support: support, temporary: temporary)
        #expect(fixture.path == "/tmp/scratch/agent-commander-fixture/network/fanout-winners.json")
        // A run with its own home keeps everything there.
        for isFixture in [true, false] {
            let own = MultiplayerWinnerStore.location(isFixture: isFixture, environment: ["AGENT_COMMANDER_HOME": "/tmp/home"],
                                                      support: support, temporary: temporary)
            #expect(own.path == "/tmp/home/network/fanout-winners.json")
        }
    }

    @Test func aSuggestionIsNamedForWhoSentIt() {
        let suggestion = MultiplayerApproval(id: "ap-1", peer: "fixture-bo", resource: "res-9", action: "agent.suggest",
                                             summary: #"{"text":"Pin the clock."}"#)
        #expect(suggestion.isSuggestion && suggestion.headline == "Suggestion from fixture-bo" && suggestion.request == "Pin the clock.")
        let ask = MultiplayerApproval(id: "ap-2", peer: "fixture-bo", resource: "res-9", action: "agent.ask")
        #expect(!ask.isSuggestion && ask.headline == "fixture-bo wants to send prompts to the worker")
        #expect(MultiplayerApproval(id: "ap-3", peer: "", resource: "res-9", action: "agent.suggest").headline == "Suggestion from a friend")
    }

    @Test func theNewActionsHaveWordsAndGrantedOnesEnableTheirVerbs() throws {
        for action in [MultiplayerSharePolicy.watch, MultiplayerSharePolicy.suggest, MultiplayerSharePolicy.review] {
            #expect(MultiplayerCapability.title(action) != action)
            #expect(!MultiplayerCapability.explanation(action, resource: "tests").contains("as the network service defines it"))
            #expect(MultiplayerSharePolicy.expected(kind: "agent").contains(action) && !MultiplayerSharePolicy.isCompanion(action))
        }
        let status = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: MultiplayerLiveFixture.status))
        let entries = status.directoryEntries
        #expect(entries.map(\.canWatch) == [true, false, false] && entries.map(\.canReview) == [true, false, false])
        #expect(entries[0].canSuggest && status.friends.map(\.user) == ["u-bo", "u-cy"])
    }
}

@MainActor @Suite struct MultiplayerLiveModelTests {
    static let home = "s-home"

    @Test func aWatchPollsFromItsCursorWhileItsPageIsOpenAndStopsWhenItCloses() async throws {
        let first = MultiplayerLiveFixture.ok(#"{"status":"ok","value":{"events":[{"kind":"message","text":"one"},{"kind":"tool","text":"two"}],"cursor":"2","state":"running"}}"#)
        let second = MultiplayerLiveFixture.ok(#"{"status":"ok","value":{"events":[{"kind":"message","text":"three"}],"cursor":"3","state":"running"}}"#)
        let idle = MultiplayerLiveFixture.ok(#"{"status":"ok","value":{"events":[],"cursor":"","state":"awaiting_input"}}"#)
        let (model, helper) = MultiplayerLiveFixture.model([.watch: [first, second, idle]])
        model.open()
        await model.settle()
        let live = model.share.live
        live.startWatch("dir-1", on: Self.home)
        #expect(model.route == .share(Self.home, .watch(resource: "dir-1")) && live.watch.phase == .connecting)
        await model.settle()
        #expect(live.watch.events.map(\.text) == ["one", "two"] && live.watch.phase == .live)
        #expect(try MultiplayerShareFixture.object(helper.lastRawInput(.watch))["resource"] == .string("dir-1"))

        #expect(await MultiplayerLiveFixture.eventually { live.watch.state == "awaiting_input" })
        // Each line is its own row, in order; an empty cursor keeps the last one.
        #expect(live.watch.events.map(\.text) == ["one", "two", "three"] && live.watch.events.map(\.id) == [1, 2, 3])
        #expect(live.watch.cursor == "3")
        #expect(try MultiplayerShareFixture.object(helper.lastRawInput(.watch))["after"] == .string("3"))

        model.share.back()
        #expect(model.route == .home && live.watchTask == nil)
        let calls = helper.count(.watch)
        try await Task.sleep(for: .milliseconds(80))
        #expect(helper.count(.watch) == calls)
        model.close()
    }

    @Test func aDeniedWatchStopsAndAFailedOneOffersAnotherTry() async throws {
        let denied = MultiplayerLiveFixture.ok(#"{"id":"c-1","status":"denied"}"#)
        let ok = MultiplayerLiveFixture.ok(#"{"events":[{"kind":"status","text":"Turn started"}],"cursor":"1","state":"running"}"#)
        let (model, helper) = MultiplayerLiveFixture.model([.watch: [denied, MultiplayerFixture.output(#"{"ok":false,"error":"relay unreachable"}"#), ok]])
        model.open()
        await model.settle()
        let live = model.share.live
        live.startWatch("dir-1", on: Self.home)
        await model.settle()
        #expect(live.watch.phase == .stopped("The owner denied Watch on this worker."))
        try await Task.sleep(for: .milliseconds(60))
        #expect(helper.count(.watch) == 1)

        live.retryWatch()
        await model.settle()
        #expect(live.watch.phase == .failed("relay unreachable"))
        live.retryWatch()
        await model.settle()
        #expect(live.watch.phase == .live && live.watch.events.count == 1)
        model.close()
    }

    @Test func aSuggestionGoesToTheOwnerAndWaitsForApproval() async throws {
        let (model, helper) = MultiplayerLiveFixture.model([
            .watch: [MultiplayerLiveFixture.ok(#"{"events":[],"cursor":"","state":"running"}"#)],
            .send: [MultiplayerLiveFixture.ok(#"{"request":"rq-5","id":"c-5","status":"pending"}"#)]])
        model.open()
        await model.settle()
        let live = model.share.live
        live.startWatch("dir-1", on: Self.home)
        await model.settle()
        #expect(!live.canSuggest)
        live.suggestDraft = " Pin the clock. "
        await live.sendSuggestion()?.value
        let sent = try MultiplayerShareFixture.object(helper.lastRawInput(.send))
        #expect(sent["capability"] == .string("agent.suggest") && sent["payload"] == .object(["text": .string("Pin the clock.")]))
        #expect(live.suggestReply?.status == "pending" && live.suggestDraft.isEmpty)
        #expect(model.notice == "Sent. fixture-bo approves each suggestion before the worker sees it.")
        model.close()
    }

    @Test func controlIsHandedToAFriendWhoMayPromptAndTakenBackAtOnce() async throws {
        let listed = MultiplayerLiveFixture.ok(#"{"handovers":[{"user":"u-bo","resource":"res-9","until":"2026-11-23T12:30:00Z"}]}"#)
        let clock = MultiplayerFixtureClock()
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)], .status: [MultiplayerLiveFixture.status],
            .handovers: [MultiplayerLiveFixture.ok(#"{"handovers":[]}"#), listed],
            .handover: [MultiplayerLiveFixture.ok(#"{"handle":"fixture-bo","resource":"res-9","until":"2026-11-23T12:30:00Z"}"#)],
            .handback: [MultiplayerShareFixture.empty]])
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     now: { clock.now })
        model.open()
        await model.settle()
        let live = model.share.live
        // Only a friend who may prompt or suggest can hold control; a watcher can't.
        #expect(live.candidates(for: "res-9", on: Self.home) == ["fixture-bo"])
        live.startControl("res-9", on: Self.home)
        #expect(model.route == .share(Self.home, .control(resource: "res-9")) && live.handoverDraft.handle == "fixture-bo")
        live.handoverDraft.length = .half
        #expect(live.canHandOver)
        await live.handOver()?.value
        // The device agent names the friend by `handle` and refuses fields it doesn't know.
        let sent = try MultiplayerShareFixture.object(helper.lastRawInput(.handover))
        #expect(sent == ["handle": .string("fixture-bo"), "resource": .string("res-9"), "minutes": .number(30),
                         "server": .string(Self.home)])
        await model.settle()
        // The list names an account; the row keeps the handle and the length it was started with.
        let active = try #require(live.activeHandovers.first)
        #expect(active.item.handle == "fixture-bo" && active.item.user == "u-bo" && active.item.minutes == 30)
        #expect(active.item.remaining(now: clock.now) == 1800)
        #expect(model.notice == "fixture-bo has control of tests for 30 minutes. Their prompts and suggestions run without asking.")

        await live.takeBack(active.item, on: Self.home)?.value
        // Take back names the holder by the account the device listed, which always matches.
        #expect(helper.lastInput(.handback) == ["handle": "u-bo", "resource": "res-9", "server": Self.home])
        model.close()
    }

    @Test func aHandoverThatRanOutIsNoLongerShown() async throws {
        let clock = MultiplayerFixtureClock()
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)], .status: [MultiplayerLiveFixture.status],
            .handovers: [MultiplayerLiveFixture.ok(#"{"handovers":[{"user":"u-cy","resource":"res-9","until":"2026-11-23T12:05:00Z"}]}"#)]])
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     now: { clock.now })
        defer { model.close() }
        model.open()
        await model.settle()
        let live = model.share.live
        // Both reads are in before the clock moves: this server's friends, and the hand-over.
        let session = try #require(model.session(Self.home))
        #expect(session.isOnline && session.status?.friends.contains { $0.handle == "fixture-cy" && $0.user == "u-cy" } == true)
        let holder = try #require(live.holders(of: "res-9", on: Self.home).first)
        #expect(holder.id == "u-cy|res-9" && holder.isLive(now: clock.now))
        #expect(live.activeHandovers.map(\.id) == ["\(Self.home)/u-cy|res-9"])
        // Named from the friends list, by account, whichever read answered first.
        #expect(holder.handle == "fixture-cy")
        // The row ends with its time, whatever it is called.
        clock.advance(301)
        #expect(!holder.isLive(now: clock.now))
        #expect(live.holders(of: "res-9", on: Self.home).isEmpty && live.activeHandovers.isEmpty)
    }

    /// The server list starts the status read and the hand-overs read separately, so either can
    /// answer last. `late` is the one held back: `.status` is the order that lost the holder's name.
    @Test(.timeLimit(.minutes(1)), arguments: [MultiplayerVerb.status, .handovers])
    func aLiveHandoverIsNamedOnceFriendStatusArrives(late: MultiplayerVerb) async throws {
        let clock = MultiplayerFixtureClock()
        // On home, u-cy is fixture-cy and u-bo is fixture-bo in the friends list, and nobody has
        // the account u-zed. The device names res-7's holder itself, with another handle.
        let work = "s-work"
        let scripted = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home,
                                                        MultiplayerServerFixture.server(work, name: "work", state: "online", signedIn: true))],
            .status: [MultiplayerLiveFixture.status],
            .handovers: [MultiplayerLiveFixture.ok(#"{"handovers":[{"user":"u-cy","resource":"res-9","until":"2026-11-23T12:05:00Z"},{"user":"u-zed","resource":"res-8","until":"2026-11-23T12:06:00Z"},{"user":"u-bo","handle":"fixture-bo-device","resource":"res-7","until":"2026-11-23T12:07:00Z"}]}"#)]])
        // Another server knows u-zed by name. Its friends never name a row on home.
        let elsewhere = ScriptedMultiplayerHelper([
            .status: [MultiplayerFixture.output(#"{"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada","friends":[{"handle":"fixture-zed","user":"u-zed"}]}}"#)],
            .handovers: [MultiplayerLiveFixture.ok(#"{"handovers":[]}"#)]])
        let helper = MultiplayerGatedHelper(scripted, holding: late, others: [work: elsewhere])
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     now: { clock.now })
        defer {
            helper.gate.release()
            model.close()
        }
        // The list read under test starts first; opening the panel in the same turn finds it in
        // flight and starts no second one.
        let initial = try #require(model.refresh())
        model.open()
        await initial.value
        let live = model.share.live
        let session = try #require(model.session(Self.home))
        let until = try #require(MultiplayerTime.parse("2026-11-23T12:05:00Z"))

        if late == .status {
            // The hand-overs are in while the friends list is still on its way.
            while let task = live.quietTask { await task.value }
            #expect(session.status == nil && session.isRefreshing && scripted.count(.status) == 0)
            let early = live.holders(of: "res-9", on: Self.home)
            #expect(early.map(\.id) == ["u-cy|res-9"] && early.map(\.user) == ["u-cy"] && early.map(\.holderKey) == ["u-cy"])
            // An account alone is never shown as a name.
            #expect(early.map(\.handle) == [""] && early.map(\.who) == ["A friend"])
        } else {
            // The friends list is in while the hand-overs are still on their way.
            await session.settle()
            #expect(session.isOnline && session.status?.friends.contains { $0.handle == "fixture-cy" && $0.user == "u-cy" } == true)
            #expect(live.holders(of: "res-9", on: Self.home).isEmpty && live.activeHandovers.isEmpty)
            #expect(scripted.count(.handovers) == 0)
        }

        helper.gate.release()
        await model.settle()

        // Whichever answered last, the holder is named from the friends list of the same server,
        // without another hand-overs read.
        let holders = live.holders(of: "res-9", on: Self.home)
        #expect(holders.map(\.handle) == ["fixture-cy"], "the holder is named once the friend status is in, whichever of \(late.rawValue) and the other read answered last")
        #expect(holders.map(\.who) == ["fixture-cy"])
        // The row is the one first listed: same account, same key for take back, same end.
        #expect(holders.map(\.id) == ["u-cy|res-9"] && holders.map(\.user) == ["u-cy"] && holders.map(\.holderKey) == ["u-cy"])
        #expect(holders.map(\.until) == [until])
        // An account no friend has stays unnamed.
        let unknown = live.holders(of: "res-8", on: Self.home)
        #expect(unknown.map(\.id) == ["u-zed|res-8"] && unknown.map(\.handle) == [""] && unknown.map(\.who) == ["A friend"])
        #expect(unknown.map(\.holderKey) == ["u-zed"])
        // The other server's status is in too, and it has that account as a friend.
        #expect(model.session(work)?.status?.friends.map(\.user) == ["u-zed"])
        // A handle the device gave is kept, whatever the friends list calls that account.
        let device = live.holders(of: "res-7", on: Self.home)
        #expect(device.map(\.handle) == ["fixture-bo-device"] && device.map(\.holderKey) == ["u-bo"])
        let active = live.activeHandovers
        #expect(active.map(\.id) == ["\(Self.home)/u-cy|res-9", "\(Self.home)/u-zed|res-8", "\(Self.home)/u-bo|res-7"])
        #expect(active.map(\.item.handle) == ["fixture-cy", "", "fixture-bo-device"])
        #expect(scripted.count(.handovers) == 1 && scripted.count(.status) == 1)
    }

    @Test func aReviewIsPostedOnlyAfterAUrlAndAConfirmation() async throws {
        let reply = #"{"request":"rq-7","id":"c-7","status":"ok","value":\#(MultiplayerLiveFixture.review)}"#
        let (model, helper) = MultiplayerLiveFixture.model([.send: [MultiplayerLiveFixture.ok(reply)],
                                                            .reviewPost: [MultiplayerLiveFixture.ok(#"{"posted":"https://example.test/a/b/pull/4"}"#)]])
        model.open()
        await model.settle()
        let live = model.share.live
        live.startReview("dir-1", on: Self.home)
        live.reviewDraft.title = "Bound the wait"
        #expect(!live.canSendReview)
        live.reviewDraft.diff = MultiplayerContextItem(name: "fix.diff", content: "--- a\n")
        await live.sendReview()?.value
        let sent = try MultiplayerShareFixture.object(helper.lastRawInput(.send))
        #expect(sent["capability"] == .string("review.request") && sent["name"] == .string("Bound the wait"))
        // The review is a window page: the composer closes and the tray is back where it was.
        #expect(model.route == .home && model.notice == "bo-agent finished the review.")
        let row = try #require(live.review("rq-7", on: Self.home))
        #expect(MultiplayerReview(row.value)?.findings.count == 2)
        #expect(live.remoteWork.first?.kind == .review && live.remoteWork.first?.state == "1 important, 1 nit")

        // The model's own post still works on its route. No URL, no post; a URL alone posts nothing either.
        live.openReview("rq-7", on: Self.home)
        #expect(live.postProblem("rq-7", on: Self.home) == "Name the pull request to post to.")
        #expect(live.confirmPost() == nil)
        live.postDraft = "https://example.test/a/b/pull/4"
        #expect(live.postProblem("rq-7", on: Self.home) == nil && live.confirmPost() == nil)
        #expect(helper.count(.reviewPost) == 0)
        live.askPost()
        #expect(live.confirmingPost && helper.count(.reviewPost) == 0)
        await live.confirmPost()?.value
        #expect(helper.lastInput(.reviewPost) == ["request": "rq-7", "pr": "https://example.test/a/b/pull/4", "server": Self.home])
        #expect(live.posted["rq-7"] == "https://example.test/a/b/pull/4" && !live.confirmingPost)
        model.close()
    }

    @Test func aPendingReviewHasNothingToPost() async throws {
        let (model, _) = MultiplayerLiveFixture.model([.send: [MultiplayerLiveFixture.ok(#"{"request":"rq-8","status":"pending"}"#)]])
        model.open()
        await model.settle()
        let live = model.share.live
        live.startReview("dir-1", on: Self.home)
        live.reviewDraft.title = "Bound the wait"
        live.reviewDraft.pr = "https://example.test/a/b/pull/4"
        await live.sendReview()?.value
        // The request's own pull request is offered as where to post.
        #expect(live.postDraft == "https://example.test/a/b/pull/4")
        #expect(live.postProblem("rq-8", on: Self.home) == "There is no review result to post yet.")
        live.askPost()
        #expect(live.confirmPost() == nil)
        model.close()
    }

    @Test func aFanoutSendsOnePromptToEachChosenWorkerAndTheWinnerStaysLocal() async throws {
        let winners = MultiplayerLiveFixture.winners()
        defer { try? FileManager.default.removeItem(at: winners.file) }
        let reply = #"{"request":"rq-3","children":{"id":"rq-3","children":[{"id":"c-1","resource":"dir-1","action":"agent.ask","status":"ok","result":{"text":"Client."}},{"id":"c-2","resource":"dir-2","action":"agent.ask","status":"pending"}]}}"#
        // `sent` reports the first target only; the second keeps what the panel last knew.
        let sent = #"{"sent":[{"request":"rq-3","child":"","resource":"dir-1","action":"fanout:agent.ask","title":"Where?","at":"2026-11-25T12:00:00Z","status":"ok","value":{"text":"Client, still."}}]}"#
        let (model, helper) = MultiplayerLiveFixture.model([.fanout: [MultiplayerLiveFixture.ok(reply)], .sent: [MultiplayerLiveFixture.ok(sent)]],
                                                           winners: winners)
        model.open()
        await model.settle()
        let live = model.share.live
        // Only workers you may prompt are targets, and a server needs two of them.
        #expect(live.fanoutTargets(on: Self.home).map(\.id) == ["dir-1", "dir-2"] && live.fanoutServers == [Self.home])
        live.startFanout(on: Self.home)
        #expect(live.fanoutDraft.targets == ["dir-1", "dir-2"] && !live.canSendFanout)
        live.fanoutDraft.prompt = "Where?"
        await live.sendFanout()?.value
        let body = try MultiplayerShareFixture.object(helper.lastRawInput(.fanout))
        #expect(body["targets"] == .array([.object(["resource": .string("dir-1"), "action": .string("agent.ask")]),
                                           .object(["resource": .string("dir-2"), "action": .string("agent.ask")])]))
        #expect(body["payload"] == .object(["text": .string("Where?")]) && body["name"] == .string("Where?"))
        #expect(model.route == .share(Self.home, .compare(request: "rq-3")))
        await model.settle()
        let fanout = try #require(live.fanout("rq-3", on: Self.home))
        #expect(fanout.children.map(\.id) == ["c-1", "c-2"] && fanout.children[0].answer == "Client, still.")
        #expect(fanout.children[1].status == "pending" && fanout.progress == "1 of 2 answered")

        live.chooseWinner("c-1", of: "rq-3", on: Self.home)
        #expect(live.winner(of: "rq-3", on: Self.home) == "c-1" && live.winner(of: "rq-3", on: "s-other") == nil)
        #expect(MultiplayerWinnerStore(file: winners.file).all == ["\(Self.home)/rq-3": "c-1"])
        #expect(live.remoteWork.first { $0.kind == .fanout }?.state == "Winner chosen")
        // Nothing about the choice is sent.
        #expect(helper.verbs.filter { ![.servers, .status, .fanout, .sent, .approvals, .relay, .handoffs, .handovers, .contacts, .activity, .me, .queue, .remoteDevices, .relayDiscover].contains($0) }.isEmpty)
        live.chooseWinner("c-1", of: "rq-3", on: Self.home)
        #expect(live.winner(of: "rq-3", on: Self.home) == nil)
        model.close()
    }

    @Test func aFanoutListedWithItsChildrenShowsEachResult() async throws {
        let sent = #"{"sent":[{"request":"rq-4","resource":"dir-1","action":"fanout:agent.ask","title":"Where?","status":"ok","children":[{"id":"c-1","resource":"dir-1","status":"ok","value":{"text":"Client."}},{"id":"c-2","resource":"dir-2","status":"denied"}]},{"request":"rq-5","resource":"dir-1","action":"review.request","title":"Bound the wait","status":"pending"},{"request":"rq-6","resource":"dir-1","action":"agent.ask","title":"A consult","status":"ok"}]}"#
        let (model, _) = MultiplayerLiveFixture.model([.sent: [MultiplayerLiveFixture.ok(sent)]])
        model.open()
        await model.settle()
        let live = model.share.live
        let fanout = try #require(live.fanout("rq-4", on: Self.home))
        #expect(fanout.isSettled && fanout.children.map(\.status) == ["ok", "denied"])
        // A consult is neither a review nor a fan-out.
        #expect(live.reviews[Self.home]?.map(\.request) == ["rq-5"] && live.fanouts[Self.home]?.count == 1)
        #expect(Set(live.remoteWork.map(\.kind)) == [.review, .fanout])
        live.open(try #require(live.remoteWork.first { $0.kind == .fanout }))
        #expect(model.route == .share(Self.home, .compare(request: "rq-4")))
        model.close()
    }
}
