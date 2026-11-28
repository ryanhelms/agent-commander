import Foundation
import Observation

@Observable @MainActor
final class CockpitModel {
    enum Connection: Equatable { case connecting, online, offline(String) }

    /// Every request goes to the service the hosts model selected: this Mac's, or a headless host's.
    private let api: ServiceClient
    /// The headless hosts, the connection to the chosen one and the choice itself.
    let hosts: CommanderHostsModel
    /// Counts each change of service. The window restarts its subscriptions when it changes.
    private(set) var serviceGeneration = 0
    var runs: [Run] = []
    var selectedID = UserDefaults.standard.string(forKey: "selectedRun")
    var connection: Connection = .connecting
    var notice: String?
    var isStopping = false
    var sending: Set<String> = []
    private(set) var workerActions: Set<String> = []
    private var replyAttempts: [String: (text: String, generation: Int?, id: String)] = [:]
    private var followUpAttempts: [String: (text: String, generation: Int, id: String)] = [:]
    private var receivedStreamState = false
    private var usingLegacyService = false
    /// The folders the service in use has recorded as projects, in its order. Empty until the
    /// catalog is read, and for a service without one.
    private(set) var projects: [Project] = []
    /// Whether the service in use has a project catalog. An older one has none, and the window
    /// then lists the directories its runs name.
    private(set) var projectCatalog = ProjectCatalogState.unknown
    /// A folder is being recorded as a project.
    private(set) var isOpeningProject = false
    /// One catalog read at a time; a request that arrives meanwhile is read once more after it.
    @ObservationIgnored private var readingProjects = false
    @ObservationIgnored private var projectsReadAgain = false
    /// Project IDs a run named that the catalog didn't list when it was last read for them. Each
    /// asks for one read, so a run of a project that is gone never reads in a loop.
    @ObservationIgnored private var unknownProjectsAsked = Set<String>()
    @ObservationIgnored private var lastProjectActivationRead = Date.distantPast
    /// Reads the catalog. A test supplies its own.
    @ObservationIgnored var readProjects: (@Sendable () async throws -> [Project])?
    /// Source records for the one console being inspected. A read runs beside the client's other
    /// requests, so a slow provider history never waits in front of a reply or a control change.
    let source: ConsoleSourceModel
    /// The media of the one prompt being viewed, read by its worker and turn.
    let attachments: PromptAttachmentModel
    /// Staged adapter updates, followed on their own subscription. A change of the set never
    /// touches `runs`.
    let adapterUpdates: AdapterUpdateFeed
    /// The harnesses this Mac can run, followed on their own subscription (Harnesses.swift).
    let harnesses: HarnessFeed
    /// The provider session of the one worker whose panel is open, and the developer's reattach.
    let providerSessions: ProviderSessionModel
    /// The structured requests of the one worker whose panel is open, and the owner's replies.
    let elicitations: ElicitationModel
    /// What Pretty shows beyond the console preview: stored tool arguments, results, plan items
    /// and times, and the transcript setting. Read beside the client's other requests.
    let toolDetails: ToolDetailStore
    /// The provider's summary and error of each compaction row, read from its source record.
    let compactions: CompactionSummaryStore
    /// The link or text of each reply chunk that is a resource, read from its source record.
    let replyAttachments: ReplyAttachmentStore
    /// The sender and text of each message from another session, read from its source records.
    let sessionMessages: SessionMessageStore

    init(endpoint: ServiceEndpoint = .live) {
        api = ServiceClient(endpoint: endpoint)
        hosts = .live(endpoint: endpoint)
        let reader = ServiceClient(endpoint: endpoint)
        attachments = .live(reader: reader)
        providerSessions = .live(reader: reader)
        elicitations = .live(reader: reader)
        compactions = CompactionFixture.isRequested ? CompactionFixture.store : .live(reader: reader)
        replyAttachments = .live(reader: reader)
        sessionMessages = .live(reader: reader)
        adapterUpdates = AdapterUpdateFeed { reader.watchAdapterUpdates() }
        toolDetails = ToolDetailStore(source: ToolDetailSource(
            page: { try await reader.toolDetails($0, after: $1) },
            record: { try await reader.toolDetail($0, key: $1) },
            readSettings: { try await reader.transcriptSettings() },
            writeSettings: { try await reader.setTranscriptSettings($0) }))
        harnesses = HarnessFeed(api: HarnessAPI(
            watch: { reader.watchHarnesses() },
            check: { try await reader.checkHarness($0) },
            start: { try await reader.startHarnessSession($0, purpose: $1) },
            saveSettings: { try await reader.saveHarnessSettings($0, $1) }))
        // A harness that was signed in and no longer is: tell the person outside the window too.
        if let notifier = MultiplayerUserNotifier.forThisProcess() {
            harnesses.notify = { alert in
                Task {
                    await notifier.post(id: "harness-\(alert.harnessID)", title: alert.title,
                                        body: "Sign in again in Agent Commander to keep using \(alert.name).")
                }
            }
        }
        source = ConsoleSourceModel { workerID, kind, cursor in
            try await reader.workerHistory(workerID, source: kind, cursor: cursor)
        }
        readProjects = { try await reader.projects() }
        // An accepted form reply has a stored record and may bring no console event. The service
        // stores it before it answers, so one read now holds it.
        elicitations.formReplied = { [toolDetails] workerID, _ in
            Task { await toolDetails.refresh(worker: workerID, afterInFlight: true) }
        }
        hosts.serviceChanged = { [weak self] in self?.serviceChanged() }
        hosts.serviceInterrupted = { [weak self] in self?.serviceInterrupted(host: $0) }
        hosts.serviceResumed = { [weak self] in self?.serviceResumed() }
    }

    /// The SSH connection to the host in use dropped. The service is offline until it answers
    /// again; the runs stay as they were last sent.
    func serviceInterrupted(host: String) {
        connection = .offline(Self.interrupted(host))
    }

    static func interrupted(_ host: String) -> String { "The connection to \(host) dropped. Reconnecting." }

    /// The service can't be reached. While the SSH connection to the host in use is down, that is
    /// the reason shown, whatever the request or the feed said.
    private func lose(_ reason: String) {
        if case .disconnected = hosts.link, let host = hosts.inUse {
            connection = .offline(Self.interrupted(host))
        } else {
            connection = .offline(reason)
        }
    }

    /// The host in use answers again on the same socket. Both subscriptions start again at once
    /// (`serviceGeneration`) instead of waiting out their retry pauses, and the first answer shows.
    func serviceResumed() {
        serviceGeneration += 1
        connection = .connecting
        receivedStreamState = false
        // What was recorded while the link was down shows with the first answer.
        unknownProjectsAsked = []
    }

    /// The selected service changed. What the last one sent is dropped, and the window's
    /// subscriptions start again on the new socket (`serviceGeneration`).
    private func serviceChanged() {
        serviceGeneration += 1
        runs = []
        // The last service's projects are not this one's.
        projects = []
        projectCatalog = .unknown
        unknownProjectsAsked = []
        connection = .connecting
        notice = nil
        receivedStreamState = false
        usingLegacyService = false
        // The new service's transcript setting is not known yet: values stay hidden until it is.
        toolDetails.serviceChanged()
        compactions.serviceChanged()
        replyAttachments.serviceChanged()
        sessionMessages.serviceChanged()
        sending = []
        replyAttempts = [:]
        followUpAttempts = [:]
    }

    var selected: Run? { runs.first { $0.id == selectedID } }

    /// The pending requests the developer answers, by the shared rule (`WorkerInputRoute`): a
    /// coordinator's own, and a delegated worker's only while the developer controls that worker.
    var pending: [PendingDecision] {
        runs.flatMap { run in
            (run.requests ?? []).compactMap { request in
                guard request.status == "pending",
                      let worker = run.workers?.first(where: { $0.id == request.workerID }),
                      run.inputRoute(of: worker).isDeveloper
                else { return nil }
                return PendingDecision(run: run, worker: worker, request: request)
            }
        }
    }

    /// What a reply to a request would do right now, read from the current runs.
    enum ReplyTarget: Equatable {
        /// Send it, under this worker-control generation. Nil for a coordinator's own request
        /// and a worker with no control record.
        case send(generation: Int?)
        /// The request is its owner's again: the developer handed the worker back, or never held it.
        case owner(worker: String, owner: WorkerInputOwner)
        /// No pending request with this ID is in the current runs.
        case gone
    }

    /// Checks a request against the authoritative state at the moment of sending, so a reply
    /// control drawn before a hand-back cannot answer for the developer.
    func replyTarget(requestID: String) -> ReplyTarget {
        for run in runs {
            guard let request = run.requests?.first(where: { $0.id == requestID }) else { continue }
            guard request.status == "pending",
                  let worker = run.workers?.first(where: { $0.id == request.workerID }) else { return .gone }
            switch run.inputRoute(of: worker) {
            case .developer(let generation): return .send(generation: generation)
            case .owner: return .owner(worker: worker.name, owner: run.inputOwner(of: worker))
            }
        }
        return .gone
    }

    /// Answers a request by its exact ID from a reply surface. A request that is no longer the
    /// developer's is not sent, and the notice says who answers it.
    func reply(requestID: String, text: String) async -> Bool {
        if let item = pending.first(where: { $0.id == requestID }) { return await reply(to: item, text: text) }
        if case .owner(let worker, let owner) = replyTarget(requestID: requestID) {
            notice = Self.returnedToOwner(worker: worker, owner: owner, request: requestID)
        }
        return false
    }

    static func returnedToOwner(worker: String, owner: WorkerInputOwner, request: String) -> String {
        "Reply to \(worker): request \(Identifier.short(request)) is with \(owner.phrase) again. "
            + "Take control of \(worker) to answer it."
    }

    func select(_ id: String?) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: "selectedRun")
    }

    func follow() async {
        await refresh(allowStart: true)
        while !Task.isCancelled {
            do {
                let generation = serviceGeneration
                for try await latest in await api.watchRuns() {
                    guard !Task.isCancelled, generation == serviceGeneration else { return }
                    receivedStreamState = true
                    usingLegacyService = false
                    apply(latest)
                }
            } catch AGUIStreamError.unsupported {
                usingLegacyService = true
                await refresh()
            } catch {
                guard !Task.isCancelled else { return }
                lose(error.localizedDescription)
            }
            do {
                try await Task.sleep(for: usingLegacyService ? .seconds(2) : .seconds(1))
            } catch {
                break
            }
        }
    }

    private func apply(_ latest: [Run]) {
        // The first answer, and the first after the service was away, reads the catalog again:
        // a folder opened from Terminal meanwhile is then listed.
        let cameOnline = connection != .online
        connection = .online
        // The service answers: read its saved transcript setting before a result is opened.
        if !toolDetails.settingsLoaded { Task { await toolDetails.loadSettingsIfNeeded() } }
        if runs != latest { runs = latest }
        if selected == nil { select(runs.last?.id) }
        if cameOnline || namesUnknownProject(latest) { Task { await refreshProjects() } }
    }

    // MARK: Projects

    /// True when a run names a project the catalog doesn't list and no read was asked for it yet.
    /// A run started from Terminal in a new folder is how a project first reaches the window.
    private func namesUnknownProject(_ latest: [Run]) -> Bool {
        guard projectCatalog != .unsupported else { return false }
        let known = Set(projects.map(\.id))
        let unknown = Set(latest.compactMap(\.projectID)).subtracting(known).subtracting(unknownProjectsAsked)
        unknownProjectsAsked.formUnion(unknown)
        return !unknown.isEmpty
    }

    /// Reads the project catalog of the service in use. A service without the route is noted as
    /// having no catalog, once, and is not asked again until the service changes. Any other
    /// failure leaves the last list in place: the run feed says whether the service answers.
    func refreshProjects() async {
        guard projectCatalog != .unsupported, let readProjects else { return }
        guard !readingProjects else { projectsReadAgain = true; return }
        readingProjects = true
        defer { readingProjects = false }
        repeat {
            projectsReadAgain = false
            let generation = serviceGeneration
            do {
                let latest = try await readProjects()
                // An answer from the service the window just left is dropped, and the new one is read.
                guard generation == serviceGeneration else { projectsReadAgain = true; continue }
                projectCatalog = .supported
                if projects != latest { projects = latest }
            } catch let refusal as ServiceStatusError where Self.meansNoCatalog(refusal) {
                guard generation == serviceGeneration else { projectsReadAgain = true; continue }
                projectCatalog = .unsupported
                projects = []
            } catch {
                // Offline or a passing error. The list stays as it was last read.
            }
        } while projectsReadAgain && projectCatalog != .unsupported
    }

    /// The service has no such route: it is older than the project catalog.
    private static func meansNoCatalog(_ refusal: ServiceStatusError) -> Bool {
        [404, 405, 501].contains(refusal.status)
    }

    /// The app came forward. A folder may have been opened from Terminal meanwhile, so the catalog
    /// is read again, at most once in five seconds.
    func refreshProjectsOnActivation(now: Date = Date()) {
        guard connection == .online, now.timeIntervalSince(lastProjectActivationRead) >= 5 else { return }
        lastProjectActivationRead = now
        Task { await refreshProjects() }
    }

    /// Records a folder as a project of the service in use. The path is sent as given: on this
    /// Mac it comes from the folder picker, on a headless host it is the host's own path as typed.
    /// Returns nil when the service refuses it, with the reason in the notice. An older service
    /// has no catalog: nil with no notice, and `projectCatalog` says so.
    func openProject(path: String) async -> Project? {
        guard !isOpeningProject else { return nil }
        isOpeningProject = true
        defer { isOpeningProject = false }
        let generation = serviceGeneration
        do {
            let project = try await api.openProject(path: path)
            guard generation == serviceGeneration else { return nil }
            projectCatalog = .supported
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index] = project
            } else {
                projects.append(project)
            }
            return project
        } catch let refusal as ServiceStatusError where Self.meansNoCatalog(refusal) {
            if generation == serviceGeneration { projectCatalog = .unsupported }
            return nil
        } catch {
            notice = "Open folder: \(error.localizedDescription)"
            return nil
        }
    }

    /// Whether a link's target is listed by the service in use right now.
    func lists(_ link: CommanderLink) -> Bool {
        switch link {
        case .run(let id): runs.contains { $0.id == id }
        case .project(let id): projects.contains { $0.id == id }
        }
    }

    /// Waits for a link's target to be listed by the service in use: a run that was just started
    /// reaches the window with its stream, a project with the next catalog read. The service is
    /// never changed and nothing is started. False once the wait is over: `settle` after the
    /// service began answering without it, or `limit` in all.
    func awaitTarget(of link: CommanderLink, settle: Duration = .seconds(6), limit: Duration = .seconds(30),
                     step: Duration = .milliseconds(400)) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        var onlineSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            if lists(link) { return true }
            if connection == .online {
                if onlineSince == nil { onlineSince = clock.now }
                if case .project = link {
                    guard projectCatalog != .unsupported else { return false }
                    await refreshProjects()
                } else if usingLegacyService {
                    await refresh()
                }
                if lists(link) { return true }
            } else {
                onlineSince = nil
            }
            if let onlineSince, clock.now - onlineSince >= settle { return false }
            if clock.now - start >= limit { return false }
            try? await Task.sleep(for: step)
        }
        return false
    }

    /// The service a link's target was looked for on, for a sentence.
    var serviceName: String { hosts.inUse ?? "this Mac" }

    func refresh(allowStart: Bool = false) async {
        let generation = serviceGeneration
        do {
            let latest: [Run]
            do {
                latest = try await api.runs()
            } catch ServiceError.offline where allowStart {
                try await api.startService()
                latest = try await api.runs()
            }
            // An answer from the service the window just left is not shown.
            guard generation == serviceGeneration else { return }
            if !receivedStreamState || usingLegacyService {
                apply(latest)
            }
        } catch {
            guard generation == serviceGeneration else { return }
            lose(error.localizedDescription)
        }
    }

    func create(path: String, task: String, title: String? = nil, operationID: String) async throws {
        let run = try await api.create(path: path, task: task, title: title, operationID: operationID)
        if !runs.contains(where: { $0.id == run.id }) { runs.append(run) }
        select(run.id)
        if usingLegacyService { await refresh() }
    }

    /// Starts a run in a recorded project. The service takes the folder from its own record.
    func create(projectID: String, task: String, title: String? = nil, operationID: String) async throws {
        let run = try await api.create(projectID: projectID, task: task, title: title, operationID: operationID)
        if !runs.contains(where: { $0.id == run.id }) { runs.append(run) }
        select(run.id)
        if usingLegacyService { await refresh() }
    }

    func reply(to item: PendingDecision, text: String) async -> Bool {
        guard !sending.contains(item.id) else { return false }
        // Read from the current runs, so a worker that dropped after the surface was drawn is caught.
        let worker = runs.lazy.compactMap { $0.workers?.first { $0.id == item.worker.id } }.first ?? item.worker
        guard worker.state.lowercased() != TaskState.apiDisconnected else {
            notice = "Reply to \(worker.name): the worker is disconnected. The request stays pending until it is reconciled."
            return false
        }
        // The route as it is now, not as it was when the surface was drawn. A request the current
        // runs do not hold keeps the item's own route, as before.
        let generation: Int?
        switch replyTarget(requestID: item.id) {
        case .send(let current): generation = current
        case .owner(let name, let owner):
            notice = Self.returnedToOwner(worker: name, owner: owner, request: item.id)
            return false
        case .gone:
            guard case .developer(let own) = item.run.inputRoute(of: item.worker) else { return false }
            generation = own
        }
        // The same answer retried under the same generation keeps its idempotency key.
        let prior = replyAttempts[item.id]
        let key = prior.flatMap { $0.text == text && $0.generation == generation ? $0.id : nil } ?? UUID().uuidString
        replyAttempts[item.id] = (text, generation, key)
        sending.insert(item.id)
        defer { sending.remove(item.id) }
        do {
            try await api.reply(to: item.id, answer: text, operationID: key, generation: generation)
            replyAttempts.removeValue(forKey: item.id)
            if usingLegacyService { await refresh() }
            return true
        } catch {
            notice = "Reply to \(item.worker.name): \(error.localizedDescription)"
            if usingLegacyService { await refresh() }
            return false
        }
    }

    func stop(_ run: Run) async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        do { try await api.stop(runID: run.id) } catch { notice = error.localizedDescription }
        if usingLegacyService { await refresh() }
    }

    private func workerTarget(_ id: String) -> (Run, Worker)? {
        guard let run = runs.first(where: { $0.workers?.contains(where: { $0.id == id }) == true }),
              id != run.coordinatorID, let worker = run.workers?.first(where: { $0.id == id })
        else { return nil }
        return (run, worker)
    }

    /// The scope a worker's structured requests are read and answered in: a delegated worker the
    /// cockpit holds, and the provider session the service has bound it to. Nil otherwise.
    func elicitationScope(_ id: String) -> ElicitationScope? {
        guard let (_, worker) = workerTarget(id), let session = worker.boundSession else { return nil }
        return ElicitationScope(workerID: id, session: session)
    }

    /// The one gate for taking and handing back control, and through it interrupting and sending a
    /// follow-up. A worker whose Claude adapter has exited or is being checked after a restart is
    /// offered none of them: the service rejects every control change in both.
    func canControlWorker(_ id: String) -> Bool {
        guard let (run, worker) = workerTarget(id) else { return false }
        return controlRecordApplies(run, worker) && ProviderAvailability.allowsControl(ProviderAvailability(worker: worker))
    }

    private func controlRecordApplies(_ run: Run, _ worker: Worker) -> Bool {
        run.status == "running" && worker.control != nil &&
            ["working", "waiting", "idle", "completed"].contains(worker.state)
    }

    /// The one gate for interrupting a turn. Every surface and `interruptWorker` read it. A
    /// session the service reports as not interruptible is never offered the action; a worker
    /// with no reported capabilities is treated as before.
    func canInterruptWorker(_ id: String) -> Bool {
        guard canControlWorker(id), let (_, worker) = workerTarget(id), let control = worker.control else { return false }
        // An unresolved receipt for the turn the worker is in now waits like `interrupt_requested`:
        // asking again would only return the same receipt.
        return ["working", "waiting"].contains(worker.state) && control.interruptRequested != true &&
            !control.interruptPendsOnActiveTurn && control.sessionCanInterrupt
    }

    func canStopWorker(_ id: String) -> Bool {
        guard let (run, worker) = workerTarget(id), run.status == "running" || run.status == "failed" else { return false }
        return worker.state != "stopped" && (worker.state != "stopping" || worker.error != nil)
    }

    func takeControl(_ id: String) async { await setWorkerControl(id, held: true) }
    func handBack(_ id: String) async { await setWorkerControl(id, held: false) }

    private func setWorkerControl(_ id: String, held: Bool) async {
        guard canControlWorker(id),
              let generation = workerTarget(id)?.1.control?.generation else { return }
        _ = await performWorkerAction(id, label: held ? "Take control" : "Hand back input") {
            try await api.setWorkerControl(id, held: held, generation: generation)
        }
    }

    /// The one gate for the owner's text to a coordinator. Open only after the service has verified
    /// a native resume: it then reports the coordinator bound to its session, `available`, and
    /// under a control record the owner holds. Before and during recovery (`starting`, `unknown`,
    /// `reattaching`, no session, no record) and once the record is no longer held, it is closed.
    /// It grants nothing else: taking and handing back control, interrupting, stopping, file
    /// context and structured requests stay with delegated workers (`workerTarget`).
    func canSendCoordinatorFollowUp(_ id: String) -> Bool { coordinatorFollowUpControl(id) != nil }

    private func coordinatorFollowUpControl(_ id: String) -> WorkerControl? {
        guard let run = runs.first(where: { $0.coordinatorID == id }),
              let worker = run.workers?.first(where: { $0.id == id }), worker.role == "coordinator",
              worker.boundSession != nil, controlRecordApplies(run, worker),
              ProviderAvailability.allowsControl(ProviderAvailability(worker: worker)),
              // An absent or unknown value is normal for a worker. A coordinator is sent to only
              // on the service's own word that the resumed session answers.
              worker.allFields[ProviderAvailability.fieldName]?.stringValue == ProviderAvailability.availableValue,
              let control = worker.control, control.held else { return nil }
        return control
    }

    /// The held control record a text follow-up is sent under: a delegated worker's, or the
    /// record of a coordinator whose gate is open. Read again on every send, so the request
    /// always carries the current generation of exactly the worker it names.
    private func followUpControl(_ id: String) -> WorkerControl? {
        guard canControlWorker(id) else { return coordinatorFollowUpControl(id) }
        return workerTarget(id)?.1.control.flatMap { $0.held ? $0 : nil }
    }

    func sendFollowUp(to id: String, text: String) async -> Bool {
        guard let control = followUpControl(id), !workerActions.contains(id) else { return false }
        let prior = followUpAttempts[id]
        let operationID = prior.flatMap { attempt in
            attempt.text == text && attempt.generation == control.generation ? attempt.id : nil
        } ?? UUID().uuidString
        followUpAttempts[id] = (text, control.generation, operationID)
        let accepted = await performWorkerAction(id, label: "Send follow-up") {
            try await api.sendFollowUp(to: id, text: text, generation: control.generation, operationID: operationID)
        }
        if accepted { followUpAttempts[id] = nil }
        return accepted
    }

    /// Sends a follow-up with file context: the text exactly as written, then each file in the
    /// order it was attached. A draft without files is the text request above. The same draft
    /// retried under the same generation carries the same idempotency key. The whole request is
    /// checked against the service's bound before it is sent; an oversized draft stays in place.
    func sendFollowUp(to id: String, text: String, context: [FollowUpContextItem]) async -> Bool {
        guard !context.isEmpty else { return await sendFollowUp(to: id, text: text) }
        guard canControlWorker(id), let control = workerTarget(id)?.1.control, control.held,
              !workerActions.contains(id) else { return false }
        let capabilities = control.promptCapabilities ?? WorkerPromptCapabilities()
        if context.contains(where: { $0.kind == .link }) && !capabilities.resourceLink
            || context.contains(where: { $0.kind == .snapshot }) && !capabilities.embeddedContext {
            notice = "Send follow-up: this session no longer accepts that file context. Remove it and send again."
            return false
        }
        let body: Data
        do {
            body = try FollowUpContent.requestBody(text: text, context: context, generation: control.generation)
        } catch {
            notice = "Send follow-up: \(error.localizedDescription)"
            return false
        }
        let fingerprint = FollowUpContent.fingerprint(text: text, context: context)
        let prior = followUpAttempts[id]
        let operationID = prior.flatMap { attempt in
            attempt.text == fingerprint && attempt.generation == control.generation ? attempt.id : nil
        } ?? UUID().uuidString
        followUpAttempts[id] = (fingerprint, control.generation, operationID)
        let accepted = await performWorkerAction(id, label: "Send follow-up") {
            try await api.sendFollowUp(to: id, body: body, operationID: operationID)
        }
        if accepted { followUpAttempts[id] = nil }
        return accepted
    }

    /// Takes back a follow-up that is still queued for the worker's next turn.
    func cancelFollowUp(_ id: String, messageID: String) async {
        guard canControlWorker(id) else { return }
        _ = await performWorkerAction(id, label: "Remove queued follow-up") {
            try await api.cancelFollowUp(id, messageID: messageID)
        }
    }

    func interruptWorker(_ id: String) async {
        guard canInterruptWorker(id) else { return }
        // Addressed to the turn and generation of the same control record the gate just read. An
        // older service or another provider reports no active turn and keeps the original request.
        let target = interruptTarget(id)
        _ = await performWorkerAction(id, label: "Interrupt worker") {
            try await api.interruptWorker(id, target: target)
        }
    }

    /// The turn and generation an interrupt of this worker is addressed to, read from its current
    /// control record. Nil when the service reports no active turn.
    func interruptTarget(_ id: String) -> WorkerInterruptTarget? {
        WorkerInterruptTarget(control: workerTarget(id)?.1.control)
    }

    func stopWorker(_ id: String) async {
        guard canStopWorker(id) else { return }
        _ = await performWorkerAction(id, label: "Stop worker") {
            try await api.stopWorker(id)
        }
    }

    private func performWorkerAction(_ id: String, label: String, perform: () async throws -> Void) async -> Bool {
        guard connection == .online, workerActions.insert(id).inserted else { return false }
        defer { workerActions.remove(id) }
        do {
            try await perform()
            if usingLegacyService { await refresh() }
            return true
        } catch {
            notice = "\(label): \(error.localizedDescription)"
            return false
        }
    }
}
