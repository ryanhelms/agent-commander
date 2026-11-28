import Foundation
import Observation

// FEATURE MODEL: live work (design/COMMANDER-NETWORK-INCREMENT-4.md).
// MultiplayerShareModel owns one of these and routes its pages. Rules it keeps:
// - A watch polls only while its page is open and a panel is visible, one call at a time. It reads
//   and never writes: nothing here types into the worker.
// - Handing control over, taking it back, sending a suggestion, a review request or a fan-out, and
//   posting a review all go through the tray's one action at a time, so progress and refusal show
//   in the tray's banner.
// - A review is posted to a pull request only after the person names the URL and confirms it.
// - A fan-out's winner is a note on this Mac. It is sent nowhere.
// - A read or an action that names its target never reads or moves the tray's route. The tray's own
//   pages call the same functions with the target their route names.

enum MultiplayerWatchPhase: Equatable {
    case connecting
    case live
    /// No answer yet; the next poll may bring one.
    case waiting(String)
    /// The owner refused or the grant ran out. Polling has stopped.
    case stopped(String)
    case failed(String)

    var isPolling: Bool {
        switch self {
        case .connecting, .live, .waiting: true
        case .stopped, .failed: false
        }
    }
}

/// The stream on the watch page.
struct MultiplayerWatchState: Equatable {
    static let eventLimit = 300

    var server = ""
    var resource = ""
    var events: [MultiplayerWatchEvent] = []
    var cursor = ""
    /// The worker's run state, as the owner's Mac last reported it.
    var state = ""
    var phase = MultiplayerWatchPhase.connecting
    var polls = 0
    var lastAt: Date? = nil
    /// Events ever read, which also numbers the next one.
    var total = 0

    /// Adds what one `watch` call brought to the stream.
    mutating func take(_ reply: MultiplayerWatchReply, at now: Date) {
        polls += 1
        lastAt = now
        if let refusal = reply.refusal {
            phase = reply.mayRecover ? .waiting(refusal) : .stopped(refusal)
            return
        }
        phase = .live
        if !reply.state.isEmpty { state = reply.state }
        if !reply.cursor.isEmpty { cursor = reply.cursor }
        for var event in reply.events {
            total += 1
            event.id = total
            events.append(event)
        }
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }
}

/// Something you sent that is still worth following: a hand-off, a review or a fan-out.
struct MultiplayerRemoteWork: Identifiable, Equatable {
    enum Kind: Equatable { case handoff, review, fanout }

    let kind: Kind
    let server: String
    let request: String
    let title: String
    let detail: String
    let state: String
    let tone: Tone
    let at: Date?

    var id: String { "\(server)/\(request)" }

    var symbol: String {
        switch kind {
        case .handoff: "arrow.up.right"
        case .review: "checklist"
        case .fanout: "arrow.triangle.branch"
        }
    }

    var kindTitle: String {
        switch kind {
        case .handoff: "Hand-off"
        case .review: "Review"
        case .fanout: "Fan-out"
        }
    }
}

@Observable @MainActor
final class MultiplayerLiveModel {
    @ObservationIgnored weak var share: MultiplayerShareModel?

    private(set) var watch = MultiplayerWatchState()
    /// The stream in the cockpit's zoom view. It runs beside the tray's own watch page.
    private(set) var zoomWatch = MultiplayerWatchState()
    @ObservationIgnored private(set) var zoomTask: Task<Void, Never>?
    @ObservationIgnored private var zoomToken = 0
    var suggestDraft = ""
    /// What came back from the suggestion just sent.
    private(set) var suggestReply: MultiplayerSentRequest?

    private(set) var handovers: [String: [MultiplayerHandover]] = [:]
    var handoverDraft = MultiplayerHandoverDraft()

    private(set) var reviews: [String: [MultiplayerSentRequest]] = [:]
    var reviewDraft = MultiplayerReviewDraft()
    private(set) var reviewProblem: String?
    /// The pull request a review's findings go to.
    var postDraft = ""
    private(set) var confirmingPost = false
    /// Reviews posted from this panel, by request, with the pull request they went to.
    private(set) var posted: [String: String] = [:]
    @ObservationIgnored private var reviewLinks: [String: String] = [:]

    private(set) var fanouts: [String: [MultiplayerFanout]] = [:]
    var fanoutDraft = MultiplayerFanoutDraft()
    /// Fan-out winners, keyed by server and request (`MultiplayerWinnerStore.key`).
    private(set) var winners: [String: String]

    private let client: MultiplayerClient?
    private let clock: () -> Date
    private let store: MultiplayerWinnerStore
    private let watchInterval: Duration
    @ObservationIgnored private(set) var quietTask: Task<Void, Never>?
    /// A watch's first read.
    @ObservationIgnored private(set) var pageTask: Task<Void, Never>?
    /// The poll that follows it. Never awaited by `settle`: it runs for as long as the page is open.
    @ObservationIgnored private(set) var watchTask: Task<Void, Never>?
    @ObservationIgnored private var watchToken = 0

    init(client: MultiplayerClient?, now: @escaping () -> Date = { Date() }, winners: MultiplayerWinnerStore,
         watchInterval: Duration = .seconds(2)) {
        self.client = client
        self.clock = now
        self.store = winners
        self.watchInterval = watchInterval
        self.winners = winners.all
    }

    private var tray: MultiplayerModel? { share?.tray }

    private func status(_ server: String) -> MultiplayerStatus? {
        guard let session = tray?.session(server), session.isOnline else { return nil }
        return session.status
    }

    // MARK: - Lifetime

    /// True while a cockpit wall is on screen (`share.wallAppeared()`): the reads below run for it
    /// with every panel closed.
    var watchesWall: Bool { share?.watchesWall == true }

    /// Reads who holds control, and the reviews and fan-outs sent, for every signed-in server,
    /// while a panel is open or a wall is on screen.
    func refresh() {
        guard let client, let tray, tray.viewers > 0 || watchesWall, quietTask == nil else { return }
        let ids = tray.servers.filter { $0.state == .online && $0.signedIn }.map(\.id)
        let online = Set(ids)
        handovers = handovers.filter { online.contains($0.key) }
        reviews = reviews.filter { online.contains($0.key) }
        fanouts = fanouts.filter { online.contains($0.key) }
        guard !ids.isEmpty else { return }
        quietTask = Task {
            for id in ids where !Task.isCancelled {
                let scoped = client.scoped(to: id)
                if let listed = try? await scoped.handovers() { self.handovers[id] = self.merged(listed, on: id) }
                if let rows = try? await scoped.sentRows() { self.take(sent: rows, on: id) }
            }
            self.quietTask = nil
        }
    }

    /// The tray left the share pages, or the page changed.
    func left() {
        endWatch()
        confirmingPost = false
        reviewProblem = nil
    }

    func cancel() {
        quietTask?.cancel()
        quietTask = nil
        endWatch()
        endZoomWatch()
    }

    // MARK: - Watch

    func startWatch(_ resource: String, on server: String) {
        suggestDraft = ""
        suggestReply = nil
        share?.open(.watch(resource: resource), on: server)
    }

    /// Starts reading a worker's output. Returning to a watch already running keeps its stream.
    func beginWatch(_ resource: String, on server: String) {
        if watch.server == server, watch.resource == resource, watch.phase.isPolling, pageTask != nil || watchTask != nil { return }
        endWatch()
        watch = MultiplayerWatchState(server: server, resource: resource)
        guard client != nil else { return }
        let token = watchToken
        pageTask = Task {
            await self.read(token)
            guard token == self.watchToken else { return }
            self.pageTask = nil
            self.poll(token)
        }
    }

    func retryWatch() {
        let resource = watch.resource, server = watch.server
        guard !resource.isEmpty else { return }
        watch.phase = .stopped("")
        beginWatch(resource, on: server)
    }

    func endWatch() {
        watchToken &+= 1
        pageTask?.cancel()
        pageTask = nil
        watchTask?.cancel()
        watchTask = nil
    }

    private func isWatching(_ token: Int) -> Bool {
        guard token == watchToken, let tray, tray.viewers > 0 else { return false }
        return tray.route == .share(watch.server, .watch(resource: watch.resource))
    }

    private func poll(_ token: Int) {
        let interval = watchInterval
        watchTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard self.isWatching(token), self.watch.phase.isPolling else { break }
                await self.read(token)
            }
            if token == self.watchToken { self.watchTask = nil }
        }
    }

    private func read(_ token: Int) async {
        guard let client else { return }
        let result: Result<MultiplayerWatchReply, MultiplayerFailure>
        do {
            result = .success(try await client.scoped(to: watch.server).watch(resource: watch.resource, after: watch.cursor))
        } catch {
            result = .failure(.from(error))
        }
        guard token == watchToken else { return }
        switch result {
        case .success(let reply): take(reply)
        case .failure(let failure):
            if failure != .cancelled { watch.phase = .failed(failure.message) }
        }
    }

    /// Adds what one call brought to the stream.
    func take(_ reply: MultiplayerWatchReply) { watch.take(reply, at: clock()) }

    // MARK: - Cockpit zoom

    /// Starts reading a remote worker's output for the cockpit's zoom view. The view ends it when it
    /// leaves the screen. Asking again for the stream already running keeps it.
    func beginZoomWatch(_ resource: String, on server: String) {
        if zoomWatch.server == server, zoomWatch.resource == resource, zoomWatch.phase.isPolling, zoomTask != nil { return }
        endZoomWatch()
        zoomWatch = MultiplayerWatchState(server: server, resource: resource)
        guard let client, !resource.isEmpty else { return }
        let token = zoomToken, interval = watchInterval
        zoomTask = Task {
            while !Task.isCancelled, token == self.zoomToken {
                let reply: Result<MultiplayerWatchReply, MultiplayerFailure>
                do {
                    reply = .success(try await client.scoped(to: server).watch(resource: resource, after: self.zoomWatch.cursor))
                } catch {
                    reply = .failure(.from(error))
                }
                guard token == self.zoomToken else { return }
                switch reply {
                case .success(let page): self.zoomWatch.take(page, at: self.clock())
                case .failure(let failure): if failure != .cancelled { self.zoomWatch.phase = .failed(failure.message) }
                }
                guard self.zoomWatch.phase.isPolling else { break }
                do { try await Task.sleep(for: interval) } catch { return }
            }
            if token == self.zoomToken { self.zoomTask = nil }
        }
    }

    func endZoomWatch() {
        zoomToken &+= 1
        zoomTask?.cancel()
        zoomTask = nil
    }

    // MARK: - Co-pilot

    var canSuggest: Bool { tray?.isBusy == false && Self.canSend(suggestion: suggestDraft) }

    /// A suggestion that can be sent: not blank, and at most 4,096 bytes.
    nonisolated static func canSend(suggestion draft: String) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf8.count <= 4096
    }

    /// Sends the suggestion typed on the tray's own watch page.
    @discardableResult
    func sendSuggestion() -> Task<Void, Never>? {
        guard let tray, case .share(let server, .watch(let resource)) = tray.route else { return nil }
        return sendSuggestion(suggestDraft, to: resource, on: server, then: { reply in
            self.suggestReply = reply
            self.suggestDraft = ""
        })
    }

    /// Sends a suggestion for a friend's worker. The owner approves it before the worker sees it.
    /// `then` is given the reply, before the confirmation is posted.
    @discardableResult
    func sendSuggestion(_ draft: String, to resource: String, on server: String,
                        report: (@MainActor (_ failure: String?) -> Void)? = nil,
                        then: @escaping @MainActor (MultiplayerSentRequest) -> Void) -> Task<Void, Never>? {
        guard Self.canSend(suggestion: draft), let tray, let share else { return nil }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = share.entry(resource, on: server)?.owner.multiplayerDisplay ?? "the owner"
        return tray.act("Sending your suggestion…", failing: "Couldn’t send the suggestion.", report: report) { client in
            let reply = try await client.scoped(to: server)
                .send(resource: resource, action: MultiplayerSharePolicy.suggest, payload: .object(["text": .string(text)]),
                      name: "Suggestion: \(MultiplayerText.clean(text, limit: 60))")
            then(reply)
            self.tray?.post(notice: reply.succeeded ? "\(owner) approved it. The worker’s answer is below."
                                                    : "Sent. \(owner) approves each suggestion before the worker sees it.")
        }
    }

    /// A stream of one worker's output that its caller owns: a watch outside the tray. The caller
    /// begins it when its view appears and ends it when the view leaves. It never reads the route.
    func stream(_ resource: String, on server: String) -> MultiplayerWatchStream {
        MultiplayerWatchStream(client: client, server: server, resource: resource, interval: watchInterval, now: clock)
    }

    // MARK: - Control

    /// Friends who can be handed control of a worker: the ones who may prompt it or suggest to it.
    func candidates(for resource: String, on server: String) -> [String] {
        let actions = [MultiplayerSharePolicy.ask, MultiplayerSharePolicy.suggest]
        return MultiplayerUnique.keep((status(server)?.grants ?? [])
            .filter { $0.resource == resource && actions.contains($0.capability) }.map(\.handle)) { $0 }
    }

    /// Hand-overs still running, across servers, soonest to end first.
    var activeHandovers: [MultiplayerPending<MultiplayerHandover>] {
        let now = clock()
        return (tray?.servers ?? []).flatMap { server in
            (handovers[server.id] ?? []).filter { $0.isLive(now: now) }.map { MultiplayerPending(server: server.id, item: $0) }
        }
        .sorted { $0.item.until < $1.item.until }
    }

    func holders(of resource: String, on server: String) -> [MultiplayerHandover] {
        let now = clock()
        return (handovers[server] ?? []).filter { $0.resource == resource && $0.isLive(now: now) }
    }

    func startControl(_ resource: String, on server: String) {
        let people = candidates(for: resource, on: server)
        handoverDraft = MultiplayerHandoverDraft(handle: people.count == 1 ? people[0] : "")
        share?.open(.control(resource: resource), on: server)
    }

    var canHandOver: Bool {
        guard let tray, !tray.isBusy, case .share(let server, .control(let resource)) = tray.route else { return false }
        return candidates(for: resource, on: server).contains(handoverDraft.handle)
    }

    @discardableResult
    func handOver() -> Task<Void, Never>? {
        guard canHandOver, let tray, let share, case .share(let server, .control(let resource)) = tray.route else { return nil }
        let draft = handoverDraft
        let who = draft.handle.multiplayerDisplay, what = share.resourceName(resource, on: server).multiplayerDisplay
        let now = clock()
        return tray.act("Handing control of \(what) to \(who)…", failing: "Couldn’t hand over control.",
                        confirmation: "\(who) has control of \(what) for \(draft.length.spoken). Their prompts and suggestions run without asking.") { client in
            let scoped = client.scoped(to: server)
            var row = try await scoped.handover(resource: resource, handle: draft.handle, minutes: draft.length.rawValue)
                ?? MultiplayerHandover(handle: draft.handle, resource: resource,
                                       until: now.addingTimeInterval(Double(draft.length.rawValue) * 60))
            row.handle = draft.handle
            row.minutes = draft.length.rawValue
            self.handovers[server] = [row] + (self.handovers[server] ?? []).filter { $0.resource != resource || $0.handle != draft.handle }
            if let listed = try? await scoped.handovers() { self.handovers[server] = self.merged(listed, on: server) }
        }
    }

    @discardableResult
    func takeBack(_ handover: MultiplayerHandover, on server: String) -> Task<Void, Never>? {
        guard let share else { return nil }
        let what = share.resourceName(handover.resource, on: server).multiplayerDisplay
        let theirs = handover.handle.isEmpty ? "Your friend’s" : "\(handover.who)’s"
        return tray?.act("Taking back control of \(what)…", failing: "Couldn’t take back control.",
                         confirmation: "You have control of \(what) again. \(theirs) requests wait for your approval.") { client in
            try await client.scoped(to: server).handback(resource: handover.resource, holder: handover.holderKey)
            self.handovers[server]?.removeAll { $0.id == handover.id }
        }
    }

    /// The device agent lists a hand-over by account. Names it from the one this panel started, or
    /// from the friends list.
    private func merged(_ listed: [MultiplayerHandover], on server: String) -> [MultiplayerHandover] {
        let known = handovers[server] ?? []
        let friends = status(server)?.friends ?? []
        return listed.map { row in
            var row = row
            if let mine = known.first(where: { $0.resource == row.resource && abs($0.until.timeIntervalSince(row.until)) < 2 }) {
                if row.handle.isEmpty { row.handle = mine.handle }
                row.minutes = mine.minutes
            }
            // A row kept from an earlier read may still be unnamed, so the friends list is asked either way.
            return Self.named(row, friends: friends)
        }
    }

    /// A server's status arrived. Names the hand-overs already listed for it by account alone,
    /// from that server's friends, without reading anything again. A row that has a handle, or
    /// whose account no friend there has, is left as it is; so is everything else about a row.
    func nameHolders(on server: String) {
        guard let rows = handovers[server], let friends = status(server)?.friends else { return }
        let next = rows.map { Self.named($0, friends: friends) }
        if next != rows { handovers[server] = next }
    }

    /// The row with its holder's handle, when it has none and a friend has its account.
    private static func named(_ row: MultiplayerHandover, friends: [MultiplayerFriend]) -> MultiplayerHandover {
        guard row.handle.isEmpty, !row.user.isEmpty,
              let friend = friends.first(where: { $0.user == row.user || $0.id == row.user }) else { return row }
        var row = row
        row.handle = friend.handle
        return row
    }

    // MARK: - Requests sent

    private func take(sent rows: [MultiplayerJSON], on server: String) {
        reviews[server] = rows.compactMap(MultiplayerSentRequest.init(json:)).filter { $0.action == MultiplayerSharePolicy.review }
        let known = fanouts[server] ?? []
        var listed: [MultiplayerFanout] = rows.compactMap { row in
            guard row.firstText("action")?.hasPrefix(MultiplayerSharePolicy.fanoutPrefix) == true,
                  var fanout = MultiplayerFanout(row) else { return nil }
            if fanout.children.isEmpty {
                // `sent` reports the first target only. Keep the others as this panel last knew them.
                fanout.children = known.first { $0.request == fanout.request }?.children ?? []
                let status = row.firstText("status") ?? ""
                if let resource = row.firstText("resource"), !status.isEmpty {
                    if let index = fanout.children.firstIndex(where: { $0.resource == resource }) {
                        fanout.children[index].status = status
                        fanout.children[index].value = row.outcome ?? fanout.children[index].value
                    } else if fanout.children.isEmpty {
                        fanout.children = [MultiplayerFanoutChild(id: row.firstText("child") ?? resource, resource: resource,
                                                                  status: status, value: row.outcome)]
                    }
                }
            }
            return fanout
        }
        // One just sent may not be listed yet.
        listed = known.filter { mine in !listed.contains { $0.request == mine.request } } + listed
        fanouts[server] = listed
    }

    // MARK: - Review exchange

    func startReview(_ resource: String, on server: String) {
        reviewDraft = MultiplayerReviewDraft()
        reviewProblem = nil
        share?.open(.reviewRequest(resource: resource), on: server)
    }

    /// Attaches the diff to review: one text file.
    func attachDiff(_ urls: [URL]) {
        let read = Self.diff(from: urls)
        reviewProblem = read.problem
        if let diff = read.diff { reviewDraft.diff = diff }
    }

    /// The first file of a pick or a drop as a diff, or why it couldn't be read. A composer
    /// outside the tray keeps both in its own state.
    nonisolated static func diff(from urls: [URL]) -> (diff: MultiplayerContextItem?, problem: String?) {
        guard let url = urls.first(where: \.isFileURL) else { return (nil, nil) }
        switch MultiplayerContextBundle.read(url) {
        case .success(let item): return (item, nil)
        case .failure(let failure): return (nil, failure.message)
        }
    }

    func detachDiff() {
        reviewDraft.diff = nil
        reviewProblem = nil
    }

    var canSendReview: Bool { tray?.isBusy == false && reviewDraft.canSend }

    /// Sends the request on the tray's own composer, then returns to where the composer was
    /// opened. The review itself is a window page; Live remote work on the Agents tab opens it.
    @discardableResult
    func sendReview() -> Task<Void, Never>? {
        guard let tray, case .share(let server, .reviewRequest(let resource)) = tray.route else { return nil }
        let link = reviewDraft.trimmedPR
        return sendReview(reviewDraft, to: resource, on: server, then: { row in
            self.reviewDraft = MultiplayerReviewDraft()
            self.postDraft = link
            self.confirmingPost = false
            // The review is a window page: the composer closes, and Live remote work opens it there.
            if self.tray?.route == .share(server, .reviewRequest(resource: resource)) { self.share?.back() }
        })
    }

    /// Asks a friend's worker for a review, with the caller's own draft. `then` is given the new
    /// review's row, before the confirmation is posted.
    @discardableResult
    func sendReview(_ draft: MultiplayerReviewDraft, to resource: String, on server: String,
                    report: (@MainActor (_ failure: String?) -> Void)? = nil,
                    then: (@MainActor (MultiplayerSentRequest) -> Void)? = nil) -> Task<Void, Never>? {
        guard draft.canSend, let tray, let share else { return nil }
        let name = share.resourceName(resource, on: server).multiplayerDisplay
        return tray.act("Asking \(name) for a review…", failing: "Couldn’t send the review request.", report: report) { client in
            let reply = try await client.scoped(to: server)
                .send(resource: resource, action: MultiplayerSharePolicy.review, payload: draft.payload, name: draft.trimmedTitle)
            let row = MultiplayerSentRequest(request: reply.request, resource: resource, action: MultiplayerSharePolicy.review,
                                             title: draft.trimmedTitle, at: self.clock(), status: reply.status,
                                             value: reply.value, failure: reply.failure)
            self.reviews[server] = [row] + (self.reviews[server] ?? []).filter { $0.request != row.request }
            self.reviewLinks[row.request] = draft.trimmedPR
            then?(row)
            self.tray?.post(notice: reply.succeeded ? "\(name) finished the review." : (reply.refusal ?? "The review is waiting for the owner."))
        }
    }

    /// The pull request a review was asked about, or the one its findings were last posted to.
    func reviewLink(_ request: String) -> String { reviewLinks[request] ?? posted[request] ?? "" }

    func openReview(_ request: String, on server: String) {
        postDraft = reviewLink(request)
        confirmingPost = false
        share?.open(.review(request: request), on: server)
    }

    func review(_ request: String, on server: String) -> MultiplayerSentRequest? {
        reviews[server]?.first { $0.request == request }
    }

    /// Why the findings can't be posted yet, or nil when they can.
    func postProblem(_ request: String, on server: String) -> String? {
        postProblem(request, on: server, link: postDraft)
    }

    /// The same, for a link the caller holds.
    func postProblem(_ request: String, on server: String, link: String) -> String? {
        guard let row = review(request, on: server), MultiplayerReview(row.value) != nil, row.succeeded else {
            return "There is no review result to post yet."
        }
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.isEmpty { return "Name the pull request to post to." }
        return MultiplayerReviewDraft.isPullRequest(link) ? nil : "A pull request URL starts with https://."
    }

    /// The first click: shows what will be posted and where. Nothing is sent.
    func askPost() { confirmingPost = true }
    func cancelPost() { confirmingPost = false }

    /// The second click on the tray's own review page.
    @discardableResult
    func confirmPost() -> Task<Void, Never>? {
        guard confirmingPost, let tray, !tray.isBusy, case .share(let server, .review(let request)) = tray.route,
              postProblem(request, on: server) == nil else { return nil }
        confirmingPost = false
        return postReview(request, on: server, to: postDraft)
    }

    /// Posts a review's findings to a pull request the caller names. The caller has already shown
    /// what will be posted and where, and the person has confirmed it.
    @discardableResult
    func postReview(_ request: String, on server: String, to link: String,
                    report: (@MainActor (_ failure: String?) -> Void)? = nil) -> Task<Void, Never>? {
        guard let tray, postProblem(request, on: server, link: link) == nil else { return nil }
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        return tray.act("Posting the review to the pull request…", failing: "Couldn’t post the review.",
                        confirmation: "Posted to the pull request as a review comment from your GitHub login.",
                        report: report) { client in
            try await client.scoped(to: server).postReview(request: request, pr: link)
            self.posted[request] = link
        }
    }

    // MARK: - Fan-out

    /// Friends' workers a fan-out can reach on a server: the ones you may prompt.
    func fanoutTargets(on server: String) -> [MultiplayerDirectoryEntry] {
        (share?.directory(server) ?? []).filter { $0.kind == MultiplayerResourceKind.agent.rawValue && $0.canConsult }
    }

    /// Servers with at least two workers to fan out to.
    var fanoutServers: [String] {
        (tray?.servers ?? []).map(\.id).filter { fanoutTargets(on: $0).count >= MultiplayerFanoutDraft.targetRange.lowerBound }
    }

    func startFanout(on server: String) {
        let targets = fanoutTargets(on: server)
        fanoutDraft = MultiplayerFanoutDraft(targets: targets.count == 2 ? Set(targets.map(\.id)) : [])
        share?.open(.fanout, on: server)
    }

    func toggleFanoutTarget(_ resource: String) {
        if fanoutDraft.targets.contains(resource) { fanoutDraft.targets.remove(resource) } else { fanoutDraft.targets.insert(resource) }
    }

    var canSendFanout: Bool { tray?.isBusy == false && fanoutDraft.canSend }

    /// Sends the fan-out on the tray's own composer, which is then replaced by its results.
    @discardableResult
    func sendFanout() -> Task<Void, Never>? {
        guard let tray, case .share(let server, .fanout) = tray.route else { return nil }
        return sendFanout(fanoutDraft, on: server, then: { fanout in
            self.fanoutDraft = MultiplayerFanoutDraft()
            self.share?.replace(with: .compare(request: fanout.request), on: server)
        })
    }

    /// Sends one prompt to several friends' workers, with the caller's own draft. `then` is given
    /// the new fan-out.
    @discardableResult
    func sendFanout(_ draft: MultiplayerFanoutDraft, on server: String,
                    report: (@MainActor (_ failure: String?) -> Void)? = nil,
                    then: (@MainActor (MultiplayerFanout) -> Void)? = nil) -> Task<Void, Never>? {
        guard draft.canSend, let tray else { return nil }
        // The directory's order, so the columns read the same every time.
        let targets = fanoutTargets(on: server).filter { draft.targets.contains($0.id) }
            .map { (resource: $0.id, action: MultiplayerSharePolicy.ask) }
        guard targets.count >= MultiplayerFanoutDraft.targetRange.lowerBound else { return nil }
        return tray.act("Sending to \(targets.count) workers…", failing: "Couldn’t send the fan-out.", report: report) { client in
            var fanout = try await client.scoped(to: server).fanout(targets: targets, payload: draft.payload, name: draft.title)
            fanout.at = fanout.at ?? self.clock()
            self.fanouts[server] = [fanout] + (self.fanouts[server] ?? []).filter { $0.request != fanout.request }
            then?(fanout)
        }
    }

    /// Reads one fan-out you sent, for the caller. It reads the server's sent requests again, so
    /// the results are the latest; the tray's route and pages are left alone.
    func loadFanout(_ request: String, on server: String) async -> MultiplayerLoad<MultiplayerFanout> {
        guard let client else { return .failed(tray?.unavailable?.message ?? "The network helper isn’t available.") }
        do { take(sent: try await client.scoped(to: server).sentRows(), on: server) } catch {
            return .failed(MultiplayerShareModel.readFailure(error))
        }
        guard let fanout = fanout(request, on: server) else { return .failed("Commander can’t find this fan-out any more.") }
        return .loaded(fanout)
    }

    func fanout(_ request: String, on server: String) -> MultiplayerFanout? {
        fanouts[server]?.first { $0.request == request }
    }

    /// Marks one target's result as the winner, or clears the mark when it is chosen again.
    func chooseWinner(_ child: String, of request: String, on server: String) {
        let next = winner(of: request, on: server) == child ? nil : child
        store.choose(next, for: request, on: server)
        winners = store.all
    }

    /// The child marked as a fan-out's winner on this Mac.
    func winner(of request: String, on server: String) -> String? {
        winners[MultiplayerWinnerStore.key(request, on: server)]
    }

    // MARK: - Remote work

    /// Hand-offs, reviews and fan-outs you sent, newest first.
    var remoteWork: [MultiplayerRemoteWork] {
        guard let share, let tray else { return [] }
        var items: [MultiplayerRemoteWork] = []
        for server in tray.servers {
            let on = "on \(server.displayName)"
            for row in share.handoffs[server.id] ?? [] {
                let state = share.handoffState(row)
                items.append(MultiplayerRemoteWork(kind: .handoff, server: server.id, request: row.request,
                                                   title: row.title.isEmpty ? "Untitled hand-off" : row.title.multiplayerDisplay,
                                                   detail: "\(share.handoffTarget(row, on: server.id)) \(on)",
                                                   state: state.title, tone: state.tone, at: row.at))
            }
            for row in reviews[server.id] ?? [] {
                let review = MultiplayerReview(row.value)
                items.append(MultiplayerRemoteWork(kind: .review, server: server.id, request: row.request,
                                                   title: row.title.isEmpty ? "Untitled review" : row.title.multiplayerDisplay,
                                                   detail: "\(share.handoffTarget(row, on: server.id)) \(on)",
                                                   state: row.succeeded ? (review?.tally ?? "Done") : MultiplayerRequestState.title(row.status),
                                                   tone: row.succeeded ? ((review?.important ?? 0) > 0 ? .attention : .working)
                                                                       : MultiplayerRequestState.tone(row.status),
                                                   at: row.at))
            }
            for fanout in fanouts[server.id] ?? [] {
                let picked = winner(of: fanout.request, on: server.id) != nil
                items.append(MultiplayerRemoteWork(kind: .fanout, server: server.id, request: fanout.request,
                                                   title: fanout.title.isEmpty ? "Untitled fan-out" : fanout.title.multiplayerDisplay,
                                                   detail: "\(fanout.children.count) workers \(on)",
                                                   state: picked ? "Winner chosen" : fanout.progress,
                                                   tone: picked || fanout.isSettled ? .working : .attention, at: fanout.at))
            }
        }
        return items.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
    }

    func open(_ work: MultiplayerRemoteWork) {
        switch work.kind {
        case .handoff: share?.open(.handoffDetail(request: work.request), on: work.server)
        case .review: openReview(work.request, on: work.server)
        case .fanout: share?.open(.compare(request: work.request), on: work.server)
        }
    }
}

/// One worker's output, read for a view outside the tray (`MultiplayerLiveModel.stream(_:on:)`).
/// It reads once on `begin`, then on the watch interval while the owner still answers. It reads
/// and never writes, and it knows nothing of the tray's route.
@Observable @MainActor
final class MultiplayerWatchStream {
    private(set) var state: MultiplayerWatchState

    private let client: MultiplayerClient?
    private let interval: Duration
    private let clock: () -> Date
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var token = 0

    init(client: MultiplayerClient?, server: String, resource: String, interval: Duration, now: @escaping () -> Date) {
        self.client = client
        self.interval = interval
        self.clock = now
        self.state = MultiplayerWatchState(server: server, resource: resource)
    }

    /// Starts reading. Asking again while it runs keeps the stream.
    func begin() {
        guard task == nil, let client, !state.resource.isEmpty else { return }
        if !state.phase.isPolling { state = MultiplayerWatchState(server: state.server, resource: state.resource) }
        token &+= 1
        let token = token, interval = interval, server = state.server, resource = state.resource
        task = Task {
            while !Task.isCancelled, token == self.token {
                let reply: Result<MultiplayerWatchReply, MultiplayerFailure>
                do {
                    reply = .success(try await client.scoped(to: server).watch(resource: resource, after: self.state.cursor))
                } catch {
                    reply = .failure(.from(error))
                }
                guard token == self.token else { return }
                switch reply {
                case .success(let page): self.state.take(page, at: self.clock())
                case .failure(let failure): if failure != .cancelled { self.state.phase = .failed(failure.message) }
                }
                guard self.state.phase.isPolling else { break }
                do { try await Task.sleep(for: interval) } catch { break }
            }
            if token == self.token { self.task = nil }
        }
    }

    func end() {
        token &+= 1
        task?.cancel()
        task = nil
    }

    /// Reads again after the stream stopped or failed.
    func retry() {
        end()
        state.phase = .stopped("")
        begin()
    }
}
