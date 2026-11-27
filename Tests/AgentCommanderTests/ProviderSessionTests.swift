import Foundation
import Testing
@testable import AgentCommander

// Provider-session status, discovery and reattach for the selected worker. These cover the
// service's JSON, the request paths, and the feature model's paging, stale answers, failures and
// the reattach key, with a scripted service in place of the socket.

private func status(_ json: String) throws -> ProviderSessionStatus {
    try ProviderSessionStatus(json: Data(json.utf8))
}

private let reattachable = #"{"peer_capabilities":{"can_resume":true,"can_list_sessions":true,"can_read_history":true},"can_discover":true,"can_reattach":true,"history":"after_stop","generation":4,"delivery_unknown":0}"#

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// A service that answers from scripts and records what it was asked.
private actor ScriptedService {
    struct Reattach: Equatable {
        let workerID: String
        let request: ProviderReattachRequest
        let key: String
    }

    private(set) var statusCalls: [String] = []
    private(set) var listCalls: [String?] = []
    private(set) var reattaches: [Reattach] = []
    private var statuses: [Result<ProviderSessionStatus, Error>]
    private var pages: [Result<ProviderSessionPage, Error>]
    private var reattachResults: [Result<Void, Error>]
    private let stallsStatus: Bool

    init(statuses: [Result<ProviderSessionStatus, Error>] = [], pages: [Result<ProviderSessionPage, Error>] = [],
         reattach: [Result<Void, Error>] = [], stallsStatus: Bool = false) {
        self.statuses = statuses
        self.pages = pages
        reattachResults = reattach
        self.stallsStatus = stallsStatus
    }

    func status(_ workerID: String) async throws -> ProviderSessionStatus {
        statusCalls.append(workerID)
        if stallsStatus { try await Task.sleep(for: .seconds(60)) }
        return try statuses.removeFirst().get()
    }

    func sessions(_ workerID: String, _ cursor: String?) throws -> ProviderSessionPage {
        listCalls.append(cursor)
        return try pages.removeFirst().get()
    }

    func reattach(_ workerID: String, _ request: ProviderReattachRequest, _ key: String) throws {
        reattaches.append(Reattach(workerID: workerID, request: request, key: key))
        try reattachResults.removeFirst().get()
    }
}

@MainActor
private func model(_ service: ScriptedService) -> ProviderSessionModel {
    ProviderSessionModel(service: .init(
        status: { workerID in try await service.status(workerID) },
        sessions: { workerID, cursor in try await service.sessions(workerID, cursor) },
        reattach: { workerID, request, key in try await service.reattach(workerID, request, key) }))
}

@Suite struct ProviderSessionValueTests {
    @Test func readsTheServiceStatus() throws {
        let value = try status(#"{"peer_capabilities":{"can_answer":true,"can_interrupt":true,"can_resume":true,"can_list_sessions":false,"can_read_history":true},"can_discover":false,"can_reattach":true,"history":"available","generation":7,"delivery_unknown":2}"#)
        #expect(value.peerCapabilities == ProviderPeerCapabilities(canAnswer: true, canInterrupt: true, canResume: true,
                                                                  canListSessions: false, canReadHistory: true))
        #expect(!value.canDiscover)
        #expect(value.canReattach)
        #expect(value.history == .available)
        #expect(value.generation == 7)
        #expect(value.deliveryUnknown == 2)
        #expect(value.reattachIsOffered)
        #expect(value.reattachUnavailableReason == nil)
        #expect(value.discoveryUnavailableReason == "This provider does not list its sessions.")
    }

    @Test func readsAnOlderOrSparseStatus() throws {
        // `peer_capabilities` and `generation` are omitted when empty.
        let value = try status(#"{"can_discover":false,"can_reattach":false,"history":"unavailable","delivery_unknown":0}"#)
        #expect(value.peerCapabilities == nil)
        #expect(value.generation == nil)
        #expect(!value.reattachIsOffered)
        #expect(value.reattachUnavailableReason == "The provider has not reported what this session can do.")
        #expect(value.discoveryUnavailableReason == "The provider has not reported what this session can do.")
    }

    @Test func namesEachHistoryState() throws {
        #expect(try status(#"{"history":"after_stop"}"#).history == .afterStop)
        #expect(try status(#"{"history":"later"}"#).history == .other("later"))
        #expect(try status(#"{}"#).history == .unavailable)
    }

    @Test func explainsAReattachThatIsNotOffered() throws {
        let noResume = try status(#"{"peer_capabilities":{"can_resume":false},"generation":3}"#)
        #expect(noResume.reattachUnavailableReason == "This provider cannot resume a session.")
        let busy = try status(#"{"peer_capabilities":{"can_resume":true},"can_reattach":false,"generation":3}"#)
        #expect(busy.reattachUnavailableReason?.hasPrefix("Reattach is offered for a stopped") == true)
        // The service may allow it, but without a generation there is nothing to send.
        let noGeneration = try status(#"{"peer_capabilities":{"can_resume":true},"can_reattach":true}"#)
        #expect(!noGeneration.reattachIsOffered)
    }

    @Test func rejectsAnUnreadableStatus() {
        #expect(throws: ServiceError.self) { try status("[]") }
    }

    @Test func readsTheBoundSessionTheStatusReports() throws {
        let value = try status(#"{"generation":5,"native_session":{"harness_instance":"local-claude","session_id":"s-9"}}"#)
        #expect(value.nativeSession == NativeSession(harnessInstance: "local-claude", sessionID: "s-9"))
        // The harness may be unreported; the session ID is what names the binding.
        #expect(try status(#"{"native_session":{"session_id":"s-9"}}"#).nativeSession
                == NativeSession(harnessInstance: "", sessionID: "s-9"))
        // An older service sends no binding.
        #expect(try status(reattachable).nativeSession == nil)
    }

    @Test func readsAnEmptyOrMalformedBindingAsUnbound() throws {
        for binding in ["null", "{}", #"{"session_id":""}"#, #"{"harness_instance":"local-claude"}"#,
                        #"{"harness_instance":"local-claude","session_id":""}"#, #""s-9""#, "[]", #"{"session_id":7}"#] {
            let value = try status(#"{"can_reattach":true,"generation":5,"native_session":\#(binding)}"#)
            #expect(value.nativeSession == nil, "\(binding)")
            // The rest of the status is still read.
            #expect(value.reattachIsOffered, "\(binding)")
        }
        #expect(ProviderSessionStatus(nativeSession: NativeSession(harnessInstance: "h", sessionID: "")).nativeSession == nil)
    }

    @Test func namesTheStatusSessionBeforeTheProjectedOne() {
        let projected = NativeSession(harnessInstance: "local-claude", sessionID: "s-old")
        let recovered = NativeSession(harnessInstance: "local-claude", sessionID: "s-new")
        let reported = ProviderSessionStatus(nativeSession: recovered)
        #expect(ProviderSessionStatus.identity(status: reported, projected: projected) == recovered)
        // A coordinator with nothing projected is named from the status alone.
        #expect(ProviderSessionStatus.identity(status: reported, projected: nil) == recovered)
        // No status yet, or one without a binding: the projected session stands.
        #expect(ProviderSessionStatus.identity(status: nil, projected: projected) == projected)
        #expect(ProviderSessionStatus.identity(status: ProviderSessionStatus(), projected: projected) == projected)
        // Neither names a session: the panel names none.
        #expect(ProviderSessionStatus.identity(status: ProviderSessionStatus(), projected: nil) == nil)
        #expect(ProviderSessionStatus.identity(status: nil,
                                               projected: NativeSession(harnessInstance: "h", sessionID: "")) == nil)
    }

    @Test func readsAPageWithAndWithoutSessions() throws {
        let page = try ProviderSessionPage(json: Data(#"{"sessions":[{"session_id":"s-1","title":"Fix the build"},{"session_id":"s-2"}],"next_cursor":"c2"}"#.utf8))
        #expect(page.sessions == [ProviderSessionSummary(sessionID: "s-1", title: "Fix the build"),
                                  ProviderSessionSummary(sessionID: "s-2")])
        #expect(page.nextCursor == "c2")
        let last = try ProviderSessionPage(json: Data(#"{"sessions":null,"next_cursor":""}"#.utf8))
        #expect(last.sessions.isEmpty)
        #expect(last.nextCursor == nil)
    }

    @Test func encodesTheReattachBody() throws {
        let body = try JSONEncoder().encode(ProviderReattachRequest(generation: 4, acknowledgeDeliveryUnknown: true))
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["generation"] as? Int == 4)
        #expect(fields["acknowledge_delivery_unknown"] as? Bool == true)
        #expect(fields.count == 2)
    }

    @Test func addressesTheWorkerAndEncodesTheCursor() {
        #expect(ServiceClient.providerSessionPath("run 1/w&2") == "/v1/workers/run%201%2Fw%262/session")
        #expect(ServiceClient.providerSessionsPath("w", cursor: "a b/c", limit: 32)
                == "/v1/workers/w/provider-sessions?limit=32&cursor=a%20b%2Fc")
        #expect(ServiceClient.providerSessionsPath("w") == "/v1/workers/w/provider-sessions?limit=32")
        // The service accepts 1 to 128.
        #expect(ServiceClient.providerSessionsPath("w", limit: 500) == "/v1/workers/w/provider-sessions?limit=128")
    }
}

@Suite @MainActor struct ProviderSessionModelTests {
    @Test func readsTheStatusOfTheOpenWorker() async throws {
        let service = ScriptedService(statuses: [.success(try status(reattachable))])
        let model = model(service)
        model.inspect("w-1")
        #expect(model.inspection?.status == .loading)
        await model.statusTask?.value
        #expect(model.inspection?.workerID == "w-1")
        #expect(model.inspection?.loadedStatus?.generation == 4)
        #expect(await service.statusCalls == ["w-1"])
        // Opening the same worker again keeps what was read.
        model.inspect("w-1")
        #expect(await service.statusCalls == ["w-1"])
    }

    @Test func statesAFailedStatusAndReadsAgain() async throws {
        let service = ScriptedService(statuses: [.failure(Failure("worker not found")), .success(try status(reattachable))])
        let model = model(service)
        model.inspect("w-1")
        await model.statusTask?.value
        #expect(model.inspection?.status == .failed("worker not found"))
        model.refresh()
        await model.statusTask?.value
        #expect(model.inspection?.loadedStatus != nil)
    }

    @Test func dropsALateAnswerForAnotherWorker() async throws {
        let service = ScriptedService(statuses: [.success(try status(reattachable))], stallsStatus: true)
        let model = model(service)
        model.inspect("w-1")
        let first = model.statusTask
        model.inspect(nil)
        await first?.value
        #expect(model.inspection == nil)
    }

    @Test func discoversOnRequestAndPagesByTheIssuedCursor() async throws {
        let service = ScriptedService(
            statuses: [.success(try status(reattachable))],
            pages: [.success(ProviderSessionPage(sessions: [.init(sessionID: "s-1"), .init(sessionID: "s-2")], nextCursor: "c2")),
                    .failure(Failure("provider session discovery is unavailable")),
                    .success(ProviderSessionPage(sessions: [.init(sessionID: "s-2"), .init(sessionID: "s-3")], nextCursor: "c2"))])
        let model = model(service)
        model.inspect("w-1")
        await model.statusTask?.value
        // Nothing is listed until the developer asks.
        #expect(model.inspection?.listing.phase == .idle)
        #expect(await service.listCalls.isEmpty)

        model.discover()
        #expect(model.inspection?.listing.phase == .loading)
        await model.listingTask?.value
        #expect(model.inspection?.listing.sessions.map(\.sessionID) == ["s-1", "s-2"])
        #expect(model.inspection?.listing.nextCursor == "c2")

        // A failed further page keeps the sessions already read.
        model.loadMoreSessions()
        await model.listingTask?.value
        #expect(model.inspection?.listing.pageError == "provider session discovery is unavailable")
        #expect(model.inspection?.listing.sessions.count == 2)

        // The retry asks for the same page. A repeated session is listed once, and a cursor the
        // service repeats ends the list.
        model.loadMoreSessions()
        await model.listingTask?.value
        #expect(await service.listCalls == [nil, "c2", "c2"])
        #expect(model.inspection?.listing.sessions.map(\.sessionID) == ["s-1", "s-2", "s-3"])
        #expect(model.inspection?.listing.nextCursor == nil)
        #expect(model.inspection?.listing.pageError == nil)
    }

    @Test func statesAnEmptyListAndAFailedFirstPage() async throws {
        let service = ScriptedService(statuses: [.success(try status(reattachable))],
                                      pages: [.failure(Failure("the selected worker's provider cannot list sessions")),
                                              .success(ProviderSessionPage(sessions: []))])
        let model = model(service)
        model.inspect("w-1")
        await model.statusTask?.value
        model.discover()
        await model.listingTask?.value
        #expect(model.inspection?.listing.phase == .failed("the selected worker's provider cannot list sessions"))
        model.discover()
        await model.listingTask?.value
        #expect(model.inspection?.listing.phase == .loaded)
        #expect(model.inspection?.listing.sessions.isEmpty == true)
    }

    @Test func offersNoDiscoveryWhenTheServiceDoesNot() async throws {
        let service = ScriptedService(statuses: [.success(try status(#"{"peer_capabilities":{"can_list_sessions":false},"can_discover":false}"#))])
        let model = model(service)
        model.inspect("w-1")
        await model.statusTask?.value
        model.discover()
        #expect(model.inspection?.listing.phase == .idle)
        #expect(await service.listCalls.isEmpty)
    }

    @Test func reattachesOnlyTheOpenWorkerUnderTheGenerationItRead() async throws {
        let after = try status(#"{"peer_capabilities":{"can_resume":true},"can_reattach":false,"generation":5}"#)
        let service = ScriptedService(statuses: [.success(try status(reattachable)), .success(after)],
                                      reattach: [.success(())])
        let model = model(service)
        model.inspect("w-1")
        await model.statusTask?.value

        // Another worker is never reattached from this panel.
        model.reattach("w-2", acknowledgeDeliveryUnknown: false)
        #expect(model.reattachTask == nil)

        model.reattach("w-1", acknowledgeDeliveryUnknown: false)
        #expect(model.inspection?.reattach == .sending)
        await model.reattachTask?.value
        await model.statusTask?.value
        let sent = await service.reattaches
        #expect(sent.count == 1)
        #expect(sent.first?.workerID == "w-1")
        #expect(sent.first?.request == ProviderReattachRequest(generation: 4, acknowledgeDeliveryUnknown: false))
        #expect(model.inspection?.reattach == .accepted)
        #expect(model.pendingReattach == nil)
        // The status is read again: the worker is now restarting under a new generation.
        #expect(model.inspection?.loadedStatus?.generation == 5)
        #expect(await service.statusCalls.count == 2)
    }

    @Test func requiresAcknowledgementOfUnresolvedDelivery() async throws {
        let unresolved = try status(#"{"peer_capabilities":{"can_resume":true},"can_reattach":true,"generation":4,"delivery_unknown":1}"#)
        let service = ScriptedService(statuses: [.success(unresolved), .success(unresolved)], reattach: [.success(())])
        let model = model(service)
        model.inspect("w-1")
        await model.statusTask?.value
        model.reattach("w-1", acknowledgeDeliveryUnknown: false)
        #expect(model.reattachTask == nil)
        #expect(model.inspection?.reattach == .idle)

        model.reattach("w-1", acknowledgeDeliveryUnknown: true)
        await model.reattachTask?.value
        #expect(await service.reattaches.first?.request == ProviderReattachRequest(generation: 4, acknowledgeDeliveryUnknown: true))
    }

    @Test func keepsTheKeyForARetryOfTheSameReattach() async throws {
        let offered = try status(reattachable)
        let moved = try status(#"{"peer_capabilities":{"can_resume":true},"can_reattach":true,"generation":6}"#)
        let service = ScriptedService(statuses: [.success(offered), .success(offered), .success(moved)],
                                      reattach: [.failure(ServiceError.offline("The local service is unreachable.")),
                                                 .failure(ServiceError.rejected("the provider binding or control lease is no longer available for reattachment"))])
        let model = model(service)
        model.inspect("w-1")
        await model.statusTask?.value

        model.reattach("w-1", acknowledgeDeliveryUnknown: false)
        await model.reattachTask?.value
        await model.statusTask?.value
        #expect(model.inspection?.reattach == .failed("The local service is unreachable."))
        // Nothing is retried on its own.
        #expect(await service.reattaches.count == 1)

        // The developer retries the same worker and generation: the same key, so the service
        // applies it at most once.
        model.reattach("w-1", acknowledgeDeliveryUnknown: false)
        await model.reattachTask?.value
        await model.statusTask?.value
        let sent = await service.reattaches
        #expect(sent.count == 2)
        #expect(sent[0].key == sent[1].key)
        #expect(model.pendingReattach?.key == sent[0].key)
        // The status read after the failure moved to a new generation; a new request is a new key.
        #expect(model.inspection?.loadedStatus?.generation == 6)
    }

    @Test func offersNoReattachWhileTheServiceDoesNot() async throws {
        let service = ScriptedService(statuses: [.success(try status(#"{"peer_capabilities":{"can_resume":true},"can_reattach":false,"generation":4}"#))])
        let model = model(service)
        model.inspect("w-1")
        await model.statusTask?.value
        model.reattach("w-1", acknowledgeDeliveryUnknown: true)
        #expect(model.reattachTask == nil)
        #expect(await service.reattaches.isEmpty)
    }
}

/// Which consoles offer the provider-session action. The coordinator is offered it like a worker.
@Suite struct ProviderSessionOfferTests {
    private func worker(isCoordinator: Bool, client: AgentClient = .claude,
                        host: String = HostPlatform.serviceLocalMarker,
                        session: NativeSession? = nil) -> WorkerPresentation {
        WorkerPresentation(
            id: "w-1", shortID: "w-1", name: isCoordinator ? "Coordinator" : "worker", client: client,
            host: host, platform: HostPlatform(serviceHost: host), location: "main", locationIsBranch: true,
            task: "", output: "", error: nil, state: .stopped, isCoordinator: isCoordinator, lineage: ["run"],
            control: .observing(holder: "run"), request: nil, startedAt: nil, session: session)
    }

    private let bound = NativeSession(harnessInstance: "local-claude", sessionID: "s-1")

    @Test func offersABoundCoordinatorTheActionLikeABoundWorker() {
        #expect(ProviderSessionAccess.isOffered(to: worker(isCoordinator: false, session: bound)))
        #expect(ProviderSessionAccess.isOffered(to: worker(isCoordinator: true, session: bound)))
        // Bound is enough, whatever the provider or host: the service's status decides the rest.
        #expect(ProviderSessionAccess.isOffered(to: worker(isCoordinator: true, client: .codex,
                                                           host: "studio", session: bound)))
    }

    @Test func offersAnUnboundLocalClaudeCoordinatorTheStatus() {
        #expect(ProviderSessionAccess.isOffered(to: worker(isCoordinator: true)))
    }

    @Test func offersNoOtherUnboundConsoleTheAction() {
        #expect(!ProviderSessionAccess.isOffered(to: worker(isCoordinator: false)))
        #expect(!ProviderSessionAccess.isOffered(to: worker(isCoordinator: true, client: .codex)))
        #expect(!ProviderSessionAccess.isOffered(to: worker(isCoordinator: true, host: "studio")))
    }
}
