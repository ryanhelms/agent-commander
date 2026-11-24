import Foundation
import Testing
@testable import AgentCommander

// Every pending approval is reachable: Attention is projected by request ID, the focused worker
// keeps one inline form for its first request, and Next request reaches all of them.

private let choices = #"[{"id":"allow-once","label":"Allow once"},{"id":"reject","label":"Reject"}]"#

private func question(_ id: String, status: String = "pending") -> String {
    #"{"id":"\#(id)","worker_id":"w2","question":"Run \#(id)?","status":"\#(status)","answer":"","choices":\#(choices)}"#
}

/// A run whose worker `w2` has the given requests, in the service's order.
private func run(_ requests: [String]) throws -> RunContent {
    func worker(_ id: String, role: String) -> String {
        #"{"id":"\#(id)","name":"\#(id)","role":"\#(role)","parent_id":"","run_id":"r1","state":"waiting","host":"local","worktree":"/p","task":"t","output":""}"#
    }
    let json = #"{"runs":[{"id":"r1","project":"p","path":"/p","task":"t","client":"claude","coordinator_id":"w1","status":"running","requests":[\#(requests.joined(separator: ","))],"workers":[\#(worker("w1", role: "coordinator")),\#(worker("w2", role: "worker"))]}]}"#
    return try RunContent(run: #require(Run.list(json: Data(json.utf8)).first))
}

private func content(_ run: RunContent) -> CockpitContent {
    CockpitContent(connection: .online, notice: nil, isStopping: false, runs: [], selected: run,
                   pending: run.awaiting, sending: [])
}

/// The live cockpit's rules, with `w2`'s console in view in the given variant.
@MainActor private func liveState(focused: Bool) -> CockpitPresentationState {
    let ui = CockpitPresentationState()
    ui.suppressesVisibleSources = true
    ui.cockpitWindowAttended = true
    if focused { ui.zoomedWorkerID = "w2" }
    ui.visibleConsoles = [ConsoleVisibility.key(focused ? .focused : .wall, "w2")]
    return ui
}

@MainActor private func ids(_ requests: [RequestPresentation]) -> [String] { requests.map(\.id) }

@Test func everyPendingRequestOfAWorkerIsProjectedByIDInServiceOrder() throws {
    let run = try run([question("q1"), question("q-old", status: "answered"), question("q2")])
    let worker = try #require(run.wall.workers.first { $0.id == "w2" })
    #expect(worker.request?.id == "q1")
    #expect(worker.allRequests.map(\.id) == ["q1", "q2"])
    #expect(worker.allRequests.allSatisfy { $0.choices.map(\.id) == ["allow-once", "reject"] })
    #expect(run.awaiting.map(\.id) == ["q1", "q2"])
    // The global badge and the run header both count each request.
    #expect(content(run).pending.count == 2)
}

@Test @MainActor func focusedWorkerKeepsItsInlineRequestAndAttentionCarriesTheSecond() throws {
    let content = content(try run([question("q1"), question("q2")]))
    let ui = liveState(focused: true)
    #expect(content.inlineRequestID(ui) == "q1")
    // Suppressed by the request ID shown inline, never by the worker.
    #expect(ids(content.attentionQueue(ui)) == ["q2"])
    // In the side panel and fixtures (no live rule) the result is the same.
    let fixture = CockpitPresentationState()
    fixture.zoomedWorkerID = "w2"
    #expect(ids(content.attentionQueue(fixture)) == ["q2"])
}

@Test @MainActor func aVisibleWallTileHidesOnlyTheRequestItMarks() throws {
    let content = content(try run([question("q1"), question("q2")]))
    let ui = liveState(focused: false)
    #expect(content.isSourceInView(content.pending[0], ui))
    #expect(!content.isSourceInView(content.pending[1], ui))
    #expect(ids(content.attentionQueue(ui)) == ["q2"])
    // Asked for by View request, the first comes back beside it.
    ui.surfacedRequests.insert("q1")
    #expect(ids(content.attentionQueue(ui)) == ["q1", "q2"])
}

@Test @MainActor func floatingPiPCarriesBothWhileTheCockpitIsOutOfSight() throws {
    let content = content(try run([question("q1"), question("q2")]))
    let ui = liveState(focused: true)
    ui.floatsPiP = true
    ui.attentionPresentation = .pip
    ui.cockpitWindowAttended = false
    #expect(content.shownInlineRequestID(ui) == nil)
    #expect(ids(content.attentionQueue(ui)) == ["q1", "q2"])
    // Closing one hides that ID alone.
    ui.dismissedRequests.insert("q1")
    #expect(ids(content.attentionQueue(ui)) == ["q2"])
}

@Test @MainActor func nextRequestReachesBothRequestsOfTheFocusedWorker() throws {
    let content = content(try run([question("q1"), question("q2")]))
    let ui = liveState(focused: true)
    // First press: the request Attention can show.
    #expect(content.attentionNavigation(ui, answering: nil).target == .attention("q2"))
    ui.activeRequestID = "q2"
    ui.reachedRequestID = "q2"
    // Again: the inline form for the first, by its own ID; then back to the second.
    #expect(content.attentionNavigation(ui, answering: nil).target == .inline("q1"))
    ui.reachedRequestID = "q1"
    #expect(content.attentionNavigation(ui, answering: nil).target == .attention("q2"))
    // A reply field with keyboard focus counts as the request being answered.
    ui.reachedRequestID = nil
    #expect(content.attentionNavigation(ui, answering: "q2").target == .inline("q1"))
}

@Test @MainActor func nextRequestCyclesBothOnTheWallAndRestoresClosedRequests() throws {
    let content = content(try run([question("q1"), question("q2")]))
    let ui = liveState(focused: false)
    #expect(content.attentionNavigation(ui, answering: nil).target == .attention("q1"))
    ui.reachedRequestID = "q1"
    #expect(content.attentionNavigation(ui, answering: nil).target == .attention("q2"))
    ui.reachedRequestID = "q2"
    #expect(content.attentionNavigation(ui, answering: nil).target == .attention("q1"))
    // Picked by hand: Next request starts from that request.
    ui.show(requestID: "q2")
    #expect(ui.reachedRequestID == nil)
    #expect(content.attentionNavigation(ui, answering: nil).target == .attention("q2"))
    // Both closed: Next request brings them back.
    ui.dismissedRequests = ["q1", "q2"]
    let navigation = content.attentionNavigation(ui, answering: nil)
    #expect(navigation.candidates.restoresDismissed)
    #expect(navigation.candidates.ids == ["q1", "q2"])
}

@Test @MainActor func afterOneResolvesTheOtherStaysPendingAndActionableByItsID() throws {
    let resolved = content(try run([question("q1", status: "answered"), question("q2")]))
    #expect(resolved.pending.map(\.id) == ["q2"])
    let worker = try #require(resolved.selected?.wall.workers.first { $0.id == "w2" })
    #expect(worker.request?.id == "q2")
    #expect(worker.request?.choices.map(\.id) == ["allow-once", "reject"])
    // Focused: the remaining request moves into the inline form and leaves Attention.
    let focused = liveState(focused: true)
    #expect(ids(resolved.attentionQueue(focused)) == [])
    #expect(resolved.attentionNavigation(focused, answering: nil).target == .inline("q2"))
    // A stale selection of the resolved request is ignored.
    focused.reachedRequestID = "q1"
    #expect(resolved.attentionNavigation(focused, answering: nil).target == .inline("q2"))
    // On the wall it is reached in Attention.
    let wall = liveState(focused: false)
    #expect(resolved.attentionNavigation(wall, answering: nil).target == .attention("q2"))
}

@Test @MainActor func choiceButtonsAnswerWithTheExactID() {
    let choice = QuestionChoice(id: "allow-once", label: "Allow once")
    #expect(RequestChoiceButtons.answer(for: choice) == "allow-once")
}

@Test func navigationOnTheInlineRequestAloneStaysThere() {
    let navigation = AttentionNavigation(order: ["q1"], inline: "q1", dismissed: [], active: nil, current: "q1")
    #expect(navigation.target == .inline("q1"))
    #expect(AttentionNavigation(order: [], inline: nil, dismissed: [], active: nil, current: nil).target == .none)
}
