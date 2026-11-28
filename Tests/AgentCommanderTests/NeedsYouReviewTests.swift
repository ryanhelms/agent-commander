import Foundation
import Testing
@testable import AgentCommander

// The Needs you review (issue #215):
//   1. One request is open at a time, and each request keeps its own mode.
//   2. The open request reads as waiting, answered, expired, gone, loading or missing.
//   3. Closing returns to the same row, or to the first row when that one has left.
//   4. The review goes beside the list only when both fit.
//   5. A link opens Needs you whatever the catalog lists, and only a join link is an invite.

@MainActor @Suite struct NeedsYouReviewTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(_ id: String, kind: NeedsYouItem.Kind = .workerQuestion, expiresIn: TimeInterval? = nil) -> NeedsYouItem {
        NeedsYouItem(id: id, kind: kind, origin: .worker(name: "Timeout cases", host: "build-01"),
                     title: "Retry after body bytes?", detail: "Retry policy is stopped until this is answered.",
                     waiting: 40, expiresIn: expiresIn)
    }

    static let detail = NeedsYouDetail(reference: "Q-018", prompt: "Should the client retry?", answersHere: true)

    /// A state with `id` open and seen once in the inbox.
    static func seen(_ id: String, in inbox: NeedsYouInbox, detail: NeedsYouDetail? = detail) throws -> NeedsYouReviewState {
        var state = NeedsYouReviewState()
        state.open(id)
        let item = try #require(inbox.items.first { $0.id == id })
        return try #require(state.remembering(item, detail: detail, now: now))
    }

    // MARK: Selection and mode

    @Test func eachRequestKeepsItsOwnMode() {
        var state = NeedsYouReviewState()
        #expect(!state.isOpen && state.mode == .aside)
        state.setMode(.full)
        #expect(state.modes.isEmpty, "no request is open, so nothing changes")
        state.open("Q-018")
        #expect(state.mode == .aside, "a request never opened is shown beside the list")
        state.setMode(.full)
        state.open("Q-021")
        #expect(state.mode == .aside && state.mode(for: "Q-018") == .full)
        state.open("Q-018")
        #expect(state.mode == .full)
    }

    @Test func closingReturnsToTheSameRowOrTheFirstWhenItLeft() {
        var state = NeedsYouReviewState()
        state.open("Q-018")
        state.close(rows: ["A-007", "Q-018", "Q-021"])
        #expect(!state.isOpen && state.returnTo?.id == "Q-018")
        let first = state.returnTo?.token

        state.open("Q-018")
        state.close(rows: ["A-007", "Q-021"])
        #expect(state.returnTo?.id == "A-007", "the row left, so focus goes to the first row")
        #expect(state.returnTo?.token != first, "each return is a new one")

        state.open("Q-018")
        state.close(rows: [])
        #expect(state.returnTo == nil)
    }

    // MARK: Phases

    @Test func aListedRequestWaitsUntilItIsAnsweredOrLapses() throws {
        let inbox = NeedsYouInbox(items: [Self.item("Q-018"), Self.item("N-1", kind: .networkApproval, expiresIn: 0)])
        var state = NeedsYouReviewState()
        #expect(state.subject(in: inbox, detail: nil, now: Self.now) == nil)

        state.open("Q-018")
        let waiting = try #require(state.subject(in: inbox, detail: Self.detail, now: Self.now))
        #expect(waiting.phase == .waiting && waiting.phase.isOpen && waiting.detail == Self.detail)

        var answered = inbox
        answered.decide("Q-018", .approved)
        #expect(state.subject(in: answered, detail: nil, now: Self.now)?.phase == .answered(.approved))

        state.open("N-1")
        #expect(state.subject(in: inbox, detail: nil, now: Self.now)?.phase == .expired)
    }

    @Test func anAnswerGivenHereOutlivesItsRow() throws {
        let inbox = NeedsYouInbox(items: [Self.item("Q-018")])
        var state = try Self.seen("Q-018", in: inbox)
        state.recordAnswer("Q-018", .replied("Retry only idempotent calls."))

        // The service still lists the request for a moment: the answer stands.
        #expect(state.subject(in: inbox, detail: Self.detail, now: Self.now)?.phase == .answered(.replied("Retry only idempotent calls.")))
        let kept = state.remembering(inbox.items[0], detail: Self.detail, now: Self.now)
        #expect(kept == nil, "seeing the waiting row again doesn't drop the answer")

        // Then the row leaves, and the review still reads the outcome and the request.
        let subject = try #require(state.subject(in: NeedsYouInbox(items: []), detail: nil, now: Self.now))
        #expect(subject.phase == .answered(.replied("Retry only idempotent calls.")))
        #expect(subject.item?.id == "Q-018" && subject.detail == Self.detail)
        #expect(!subject.phase.isOpen)
    }

    @Test func aRowThatLeavesReadsAsExpiredOrGone() throws {
        let empty = NeedsYouInbox(items: [])
        let timed = NeedsYouInbox(items: [Self.item("N-1", kind: .networkApproval, expiresIn: 30)])
        let state = try Self.seen("N-1", in: timed)
        // It left well before its end: answered somewhere else, or withdrawn.
        #expect(state.subject(in: empty, detail: nil, now: Self.now.addingTimeInterval(5))?.phase == .gone)
        // It left at its end: it lapsed.
        #expect(state.subject(in: empty, detail: nil, now: Self.now.addingTimeInterval(29))?.phase == .expired)

        let untimed = try Self.seen("Q-018", in: NeedsYouInbox(items: [Self.item("Q-018")]))
        #expect(untimed.subject(in: empty, detail: nil, now: Self.now.addingTimeInterval(9_000))?.phase == .gone)
    }

    @Test func aLinkedRequestIsLookedForBeforeItReadsAsMissing() {
        let empty = NeedsYouInbox(items: [])
        var state = NeedsYouReviewState()
        state.open("Q-404", settled: false)
        let loading = state.subject(in: empty, detail: nil, now: Self.now)
        #expect(loading?.phase == .loading && loading?.item == nil)

        state.isSettled = true
        #expect(state.subject(in: empty, detail: nil, now: Self.now)?.phase == .missing)

        // A request that arrives late is shown as soon as it is listed, settled or not.
        let late = NeedsYouInbox(items: [Self.item("Q-404")])
        #expect(state.subject(in: late, detail: nil, now: Self.now)?.phase == .waiting)
        state.open("Q-405", settled: false)
        #expect(state.subject(in: NeedsYouInbox(items: [Self.item("Q-405")]), detail: nil, now: Self.now)?.phase == .waiting)
    }

    @Test func everyPhaseButWaitingSaysWhatHappened() {
        let phases: [NeedsYouReviewPhase] = [.answered(.approved), .answered(.inReview), .expired, .gone, .loading, .missing]
        #expect(NeedsYouReviewPhase.waiting.statement == nil)
        for phase in phases {
            #expect(phase.statement?.isEmpty == false && !phase.title.isEmpty && !phase.isOpen)
        }
    }

    @Test func theClockAloneIsNotRemembered() throws {
        let inbox = NeedsYouInbox(items: [Self.item("N-1", kind: .networkApproval, expiresIn: 30)])
        let state = try Self.seen("N-1", in: inbox)
        var later = inbox.items[0]
        later.waiting = 41
        later.expiresIn = 29
        #expect(state.remembering(later, detail: Self.detail, now: Self.now.addingTimeInterval(1)) == nil)
        later.failure = "The relay didn’t answer."
        #expect(state.remembering(later, detail: Self.detail, now: Self.now) != nil)
        // Another request's row is never kept for the open one.
        #expect(state.remembering(Self.item("Q-018"), detail: nil, now: Self.now) == nil)
    }

    // MARK: Layout

    @Test func theReviewGoesBesideTheListOnlyWhenBothFit() {
        let least = NeedsYouReviewLayout.listWidth + NeedsYouReviewLayout.reviewMinimum
        #expect(NeedsYouReviewLayout.shown(.aside, width: least) == .aside)
        #expect(NeedsYouReviewLayout.shown(.aside, width: least - 1) == .full, "the compact fallback is the full view")
        #expect(NeedsYouReviewLayout.shown(.full, width: 2_000) == .full)
        // The window's least width leaves the canvas under the two columns, with or without the context list.
        #expect(!NeedsYouReviewLayout.fitsAside(width: 800 - 48 - 196) && !NeedsYouReviewLayout.fitsAside(width: 800 - 48))
        // The default window shows the review beside the list.
        #expect(NeedsYouReviewLayout.fitsAside(width: 1_280 - 48 - 196))
    }

    // MARK: Links

    @Test func aNeedsYouLinkOpensItsRequestWhateverTheCatalogLists() throws {
        let link = try #require(NeedsYouRequestLink(id: "approval:srv-studio/ap-1"))
        let request = CommanderOpenRequest(needsYou: link)
        #expect(request.place == LiveShell.needsYou && request.server == nil)
        // A cold start: nothing is listed yet, and the request keeps its item.
        let nothing = CommanderOpenCatalog(places: []) { _, _ in false }
        #expect(request.destination(in: nothing)
                == CommanderOpenDestination(place: LiveShell.needsYou, item: .needsYou(request: "approval:srv-studio/ap-1")))
        #expect(request.landingCrumbs.last == "Needs you")
    }

    @Test func aLinkedRequestWaitsInTheRouterForAColdWindow() throws {
        var presented = 0
        var shown: [CommanderOpenRequest] = []
        let router = CommanderWindowRouter(present: { presented += 1 })
        let request = CommanderOpenRequest(needsYou: try #require(NeedsYouRequestLink(id: "Q-018")))
        router.open(request)
        #expect(presented == 1 && shown.isEmpty && router.waiting == request)
        router.attach { shown.append($0) }
        #expect(shown == [request] && router.waiting == nil)
    }

    @Test func aLinkedRequestOpensUnsettledThenSettles() async {
        let ui = CockpitPresentationState()
        ui.openNeedsYou(linked: "Q-018", grace: .milliseconds(30))
        #expect(ui.needsYouReview.selectedID == "Q-018" && !ui.needsYouReview.isSettled)
        #expect(await NetworkPagesTests.eventually { ui.needsYouReview.isSettled })
        #expect(ui.shellPlace == LiveShell.wall, "the request alone doesn't move the window; the destination does")
    }

    @Test func onlyAJoinLinkIsAnInvite() throws {
        func link(_ text: String) throws -> CommanderExternalLink? { CommanderExternalLink(url: try #require(URL(string: text))) }
        let request = try #require(NeedsYouRequestLink(id: "Q-018"))
        #expect(try link("agentcommander://needs-you?request=Q-018") == .needsYou(request))
        let join = "agentcommander://join?server=https%3A%2F%2Flab.example&code=c"
        #expect(try link(join) == .invite(try #require(URL(string: join))))
        // Any other host, a malformed request link and another scheme open nothing.
        for other in ["agentcommander://open?server=lab.example", "agentcommander://needs-you?request=Q-018&answer=approve",
                      "agentcommander://needs-you", "https://join?server=lab.example", "agentcommander://settings"] {
            #expect(try link(other) == nil, "\(other)")
        }
        let urls = try [join, "agentcommander://settings", "agentcommander://needs-you?request=Q-018",
                        "agentcommander://needs-you?request=Q-021"].map { try #require(URL(string: $0)) }
        let first = CommanderExternalLink.first(in: urls)
        #expect(first.needsYou == request && first.invite == urls[0])
        #expect(CommanderExternalLink.first(in: [urls[1]]).needsYou == nil && CommanderExternalLink.first(in: [urls[1]]).invite == nil)
    }

    @Test func aCopiedLinkOpensTheSameRequest() throws {
        for id in ["Q-018", "approval:srv-studio/ap-1", "harness:claude"] {
            let url = try #require(NeedsYouRequestLink(id: id)).url
            guard case .needsYou(let link) = CommanderExternalLink(url: url) else {
                Issue.record("\(url) is a Needs you link")
                continue
            }
            #expect(CommanderOpenRequest(needsYou: link).item == .needsYou(request: id))
        }
    }

    // MARK: The full request

    @Test func aNetworkRequestsDetailNamesWhoAsksAndWhatItReaches() throws {
        let network = ShellLiveTests.network
        let approval = try #require(LiveShell.detail(for: "approval:srv-studio/ap-1", pending: [], network: network))
        #expect(approval.reference == "ap-1" && approval.prompt.contains("Read docs/retries.md"))
        #expect(approval.identity.first { $0.label == "From" }?.value.contains("jonah") == true)
        #expect(approval.identity.contains { $0.label == "Request ID" && $0.value == "ap-1" && $0.isData })
        #expect(approval.scope.first?.value.hasPrefix("docs-agent on ") == true)
        #expect(!approval.answersHere && approval.choices.isEmpty && approval.leavesNote == nil)
        #expect(approval.sourceTitle == "Open in Approvals")

        // Review leaves the page for the grant sheet, and the review says so.
        let access = try #require(LiveShell.detail(for: "access:srv-studio/ac-1", pending: [], network: network))
        #expect(access.leavesNote?.contains("grant sheet") == true && !access.answersHere)

        let friend = try #require(LiveShell.detail(for: "friend:srv-studio/fr-1", pending: [], network: network))
        #expect(friend.sourceTitle == "Open in People" && friend.prompt.contains("tomas"))

        let alert = HarnessAlert(harnessID: "claude", name: "Claude Code", expired: true, since: ShellLiveTests.now)
        let signIn = try #require(LiveShell.detail(for: alert.inboxID, pending: [], network: network, harnessAlerts: [alert]))
        #expect(signIn.leavesNote?.contains("stays selected") == true && !signIn.answersHere)

        #expect(LiveShell.detail(for: "approval:srv-studio/gone", pending: [], network: network) == nil)
    }

    @Test func theSampleInboxHasADetailForEveryRow() {
        for item in ShellSample.inbox.items {
            let detail = ShellSample.detail(for: item.id)
            #expect(detail != nil && detail?.answersHere == item.kind.isLocal, "\(item.id)")
        }
        #expect(ShellSample.detail(for: "A-007")?.choices.map(\.id) == ["allow_once", "allow_always", "reject_once"])
        #expect(DesignPreviewScenario(rawValue: "needs-you-review") == .needsYouReview && DesignPreviewScenario.needsYouReview.isShell)
        #expect(ShellPreviewState(scenario: .needsYouReview).review.selectedID == "Q-018")
    }
}
