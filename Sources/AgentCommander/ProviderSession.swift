import Observation
import SwiftUI

// PROVIDER SESSION
// What the service knows about the provider session a worker is bound to, the sessions its
// provider lists in that worker's scope, and the developer's explicit reattach of the worker to
// its own original session.
//
//   Values          ProviderSessionStatus        GET  /v1/workers/{worker}/session
//                   ProviderSessionPage          GET  /v1/workers/{worker}/provider-sessions
//                   ProviderReattachRequest      POST /v1/workers/{worker}/reattach
//                   ProviderSessionInspection    what the panel draws for the one open worker
//   Feature layer   ProviderSessionModel         the open worker's reads, pages and reattach
//                   ProviderSessionIntents       the operations the cockpit emits
//   Molecules       ProviderSessionFact          one labelled fact, value at the trailing edge
//                   ProviderCapabilityCheck      one negotiated capability, with its glyph
//                   ProviderSessionRow           one listed session, marked when it is the bound one
//   Organism        ProviderSessionPanel         status, capabilities, discovery, reattach
//                   ProviderSessionPresentation  presents the panel from the worker's title bar
//
// Reattach is always the developer's explicit act on the worker the panel was opened for, and
// always to that worker's own bound session: a listed session is shown, never chosen. The request
// carries the control generation the panel read and one idempotency key, kept for a retry of the
// same worker, generation and acknowledgement. When the service counts deliveries whose outcome is
// unknown, the developer confirms that they stay unresolved. Nothing is sent or resubmitted.

// MARK: - Values

/// The operations the provider negotiated for the session, as the service reports them. A member
/// the service leaves out reads as not offered.
struct ProviderPeerCapabilities: Decodable, Equatable, Sendable {
    var canAnswer = false
    var canInterrupt = false
    var canResume = false
    var canListSessions = false
    var canReadHistory = false

    init(canAnswer: Bool = false, canInterrupt: Bool = false, canResume: Bool = false,
         canListSessions: Bool = false, canReadHistory: Bool = false) {
        self.canAnswer = canAnswer
        self.canInterrupt = canInterrupt
        self.canResume = canResume
        self.canListSessions = canListSessions
        self.canReadHistory = canReadHistory
    }

    private enum CodingKeys: String, CodingKey {
        case canAnswer = "can_answer", canInterrupt = "can_interrupt", canResume = "can_resume"
        case canListSessions = "can_list_sessions", canReadHistory = "can_read_history"
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        canAnswer = try fields.decodeIfPresent(Bool.self, forKey: .canAnswer) ?? false
        canInterrupt = try fields.decodeIfPresent(Bool.self, forKey: .canInterrupt) ?? false
        canResume = try fields.decodeIfPresent(Bool.self, forKey: .canResume) ?? false
        canListSessions = try fields.decodeIfPresent(Bool.self, forKey: .canListSessions) ?? false
        canReadHistory = try fields.decodeIfPresent(Bool.self, forKey: .canReadHistory) ?? false
    }
}

/// One worker's provider session, as `GET /v1/workers/{worker}/session` reports it.
struct ProviderSessionStatus: Decodable, Equatable, Sendable {
    /// Whether the provider's own history of the session can be read now.
    enum History: Equatable, Sendable {
        case available
        /// Readable once the worker has stopped.
        case afterStop
        case unavailable
        /// A value this version does not know, kept as sent.
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "available": self = .available
            case "after_stop": self = .afterStop
            case "unavailable", "": self = .unavailable
            default: self = .other(raw)
            }
        }

        var label: String {
            switch self {
            case .available: "Available"
            case .afterStop: "After stop"
            case .unavailable: "Unavailable"
            case .other(let raw): raw
            }
        }

        var statement: String {
            switch self {
            case .available: "The provider's history of this session can be read now."
            case .afterStop: "The provider's history can be read once this worker has stopped."
            case .unavailable: "The provider's history of this session cannot be read."
            case .other(let raw): "The service reports the history as “\(raw)”."
            }
        }
    }

    /// Nil when the service has no capability record for the session, such as an older worker.
    let peerCapabilities: ProviderPeerCapabilities?
    let canDiscover: Bool
    let canReattach: Bool
    let history: History
    /// The worker's control generation. Nil when the worker has no control record.
    let generation: Int?
    /// Follow-ups and interrupts the service accepted whose delivery it cannot confirm.
    let deliveryUnknown: Int

    init(peerCapabilities: ProviderPeerCapabilities? = nil, canDiscover: Bool = false, canReattach: Bool = false,
         history: History = .unavailable, generation: Int? = nil, deliveryUnknown: Int = 0) {
        self.peerCapabilities = peerCapabilities
        self.canDiscover = canDiscover
        self.canReattach = canReattach
        self.history = history
        self.generation = generation
        self.deliveryUnknown = deliveryUnknown
    }

    private enum CodingKeys: String, CodingKey {
        case peerCapabilities = "peer_capabilities", canDiscover = "can_discover", canReattach = "can_reattach"
        case history, generation, deliveryUnknown = "delivery_unknown"
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        peerCapabilities = try fields.decodeIfPresent(ProviderPeerCapabilities.self, forKey: .peerCapabilities)
        canDiscover = try fields.decodeIfPresent(Bool.self, forKey: .canDiscover) ?? false
        canReattach = try fields.decodeIfPresent(Bool.self, forKey: .canReattach) ?? false
        let history = try fields.decodeIfPresent(String.self, forKey: .history) ?? ""
        self.history = History(history)
        let generation = try fields.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        self.generation = generation > 0 ? generation : nil
        let unknown = try fields.decodeIfPresent(Int.self, forKey: .deliveryUnknown) ?? 0
        deliveryUnknown = max(0, unknown)
    }

    init(json data: Data) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ServiceError.rejected("The service returned an unreadable provider session status.")
        }
    }

    /// Reattach may be sent: the service allows it now and names the generation to send.
    var reattachIsOffered: Bool { canReattach && generation != nil }

    /// Why discovery is not offered, in words. Nil when it is.
    var discoveryUnavailableReason: String? {
        guard !canDiscover else { return nil }
        guard let peerCapabilities else { return "The provider has not reported what this session can do." }
        guard peerCapabilities.canListSessions else { return "This provider does not list its sessions." }
        return "Sessions are listed only for a local worker that Commander launched on a provider binding."
    }

    /// Why reattach is not offered, in words. Nil when it is.
    var reattachUnavailableReason: String? {
        if reattachIsOffered { return nil }
        guard let peerCapabilities else { return "The provider has not reported what this session can do." }
        guard peerCapabilities.canResume else { return "This provider cannot resume a session." }
        if generation == nil { return "This worker has no control record to reattach under." }
        return "Reattach is offered for a stopped or exited local worker with no queued follow-up, its input not held, and room under the run's worker limit."
    }
}

/// One session the provider lists in the worker's scope.
struct ProviderSessionSummary: Decodable, Identifiable, Equatable, Sendable {
    let sessionID: String
    let title: String?

    var id: String { sessionID }

    init(sessionID: String, title: String? = nil) {
        self.sessionID = sessionID
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", title
    }
}

/// One page of the provider's sessions. `nextCursor` is nil at the end.
struct ProviderSessionPage: Decodable, Equatable, Sendable {
    /// Sessions per page. The service accepts 1 to 128.
    static let limit = 32

    let sessions: [ProviderSessionSummary]
    let nextCursor: String?

    init(sessions: [ProviderSessionSummary], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor.flatMap { $0.isEmpty ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessions: try fields.decodeIfPresent([ProviderSessionSummary].self, forKey: .sessions) ?? [],
                  nextCursor: try fields.decodeIfPresent(String.self, forKey: .nextCursor))
    }

    init(json data: Data) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ServiceError.rejected("The service returned an unreadable list of provider sessions.")
        }
    }
}

/// The body of an explicit reattach.
struct ProviderReattachRequest: Encodable, Equatable, Sendable {
    let generation: Int
    let acknowledgeDeliveryUnknown: Bool

    private enum CodingKeys: String, CodingKey {
        case generation, acknowledgeDeliveryUnknown = "acknowledge_delivery_unknown"
    }
}

/// The open worker's provider session, as far as it has been read.
struct ProviderSessionInspection: Equatable {
    enum StatusPhase: Equatable {
        case loading
        case loaded(ProviderSessionStatus)
        case failed(String)
    }

    struct Listing: Equatable {
        enum Phase: Equatable {
            /// Not asked for yet. Discovery is the developer's request.
            case idle
            case loading
            case loaded
            case failed(String)
        }

        var phase: Phase = .idle
        var sessions: [ProviderSessionSummary] = []
        var nextCursor: String? = nil
        var isLoadingMore = false
        /// Why the last request for a further page failed. The pages already read stay in place.
        var pageError: String? = nil
    }

    enum ReattachPhase: Equatable {
        case idle
        case sending
        /// Accepted under this generation. The worker restarts on its own session.
        case accepted
        case failed(String)
    }

    let workerID: String
    var status: StatusPhase = .loading
    /// A read of the status is in flight while an earlier one is shown.
    var isRefreshing = false
    /// Why the last refresh failed. The status already read stays in place.
    var refreshError: String? = nil
    var listing = Listing()
    var reattach: ReattachPhase = .idle

    var loadedStatus: ProviderSessionStatus? {
        if case .loaded(let status) = status { return status }
        return nil
    }
}

// MARK: - Feature model

/// Reads the provider session of the one worker whose panel is open and sends the developer's
/// reattach. Opening another worker or closing drops what was read and any read in flight; a late
/// answer never reaches another worker's panel. A reattach in flight is not abandoned: it is the
/// developer's act, and its outcome is kept for the worker it was sent for.
@Observable @MainActor
final class ProviderSessionModel {
    struct Service: Sendable {
        var status: @Sendable (_ workerID: String) async throws -> ProviderSessionStatus
        var sessions: @Sendable (_ workerID: String, _ cursor: String?) async throws -> ProviderSessionPage
        var reattach: @Sendable (_ workerID: String, _ request: ProviderReattachRequest, _ key: String) async throws -> Void
    }

    /// The reattach the developer last asked for and that has not been accepted. A retry of the
    /// same worker, generation and acknowledgement reuses its key.
    struct PendingReattach: Equatable {
        let workerID: String
        let request: ProviderReattachRequest
        let key: String
    }

    private(set) var inspection: ProviderSessionInspection?
    /// The requests in flight. Read by tests; views read `inspection`.
    @ObservationIgnored private(set) var statusTask: Task<Void, Never>?
    @ObservationIgnored private(set) var listingTask: Task<Void, Never>?
    @ObservationIgnored private(set) var reattachTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pendingReattach: PendingReattach?
    @ObservationIgnored private let service: Service
    /// Changes whenever the open worker changes, so an answer for an earlier one is dropped.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var listingToken = 0

    init(service: Service) {
        self.service = service
    }

    /// Opens the panel's reading on a worker by ID, or closes it with nil. Opening the worker that
    /// is already open keeps what was read.
    func inspect(_ workerID: String?) {
        guard inspection?.workerID != workerID else { return }
        statusTask?.cancel()
        listingTask?.cancel()
        statusTask = nil
        listingTask = nil
        epoch += 1
        guard let workerID, !workerID.isEmpty else {
            inspection = nil
            return
        }
        inspection = ProviderSessionInspection(workerID: workerID)
        loadStatus()
    }

    /// Reads the open worker's status again. What was shown stays until the answer arrives.
    func refresh() {
        guard let current = inspection, !current.isRefreshing, current.status != .loading else { return }
        loadStatus()
    }

    /// Lists the first page of the provider's sessions in the worker's scope. Asked for by the
    /// developer, and again to read the list from the start.
    func discover() {
        guard var current = inspection, current.loadedStatus?.canDiscover == true,
              current.listing.phase != .loading, !current.listing.isLoadingMore else { return }
        current.listing = ProviderSessionInspection.Listing(phase: .loading)
        inspection = current
        fetchSessions(cursor: nil)
    }

    /// Reads the next page of sessions. After a failed page it asks for that page again.
    func loadMoreSessions() {
        guard var current = inspection, current.listing.phase == .loaded,
              let cursor = current.listing.nextCursor, !current.listing.isLoadingMore else { return }
        current.listing.isLoadingMore = true
        current.listing.pageError = nil
        inspection = current
        fetchSessions(cursor: cursor)
    }

    /// Reattaches the open worker to its own bound session, under the generation the panel read.
    /// Refused unless `workerID` is the open worker, the service offers reattach now, and any
    /// unresolved delivery is acknowledged.
    func reattach(_ workerID: String, acknowledgeDeliveryUnknown: Bool) {
        guard var current = inspection, current.workerID == workerID, current.reattach != .sending,
              let status = current.loadedStatus, status.reattachIsOffered, let generation = status.generation,
              status.deliveryUnknown == 0 || acknowledgeDeliveryUnknown else { return }
        // The acknowledgement is sent only when there is something to acknowledge, so a retry of
        // the same state carries the same body.
        let request = ProviderReattachRequest(generation: generation,
                                              acknowledgeDeliveryUnknown: status.deliveryUnknown > 0)
        let key: String
        if let prior = pendingReattach, prior.workerID == workerID, prior.request == request {
            key = prior.key
        } else {
            key = UUID().uuidString
        }
        pendingReattach = PendingReattach(workerID: workerID, request: request, key: key)
        current.reattach = .sending
        inspection = current
        reattachTask = Task { [service] in
            let failure: String?
            do {
                try await service.reattach(workerID, request, key)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            if failure == nil, self.pendingReattach?.key == key { self.pendingReattach = nil }
            guard var latest = self.inspection, latest.workerID == workerID else { return }
            latest.reattach = failure.map(ProviderSessionInspection.ReattachPhase.failed) ?? .accepted
            self.inspection = latest
            // Either way the service's own view is read again: after acceptance the worker is
            // restarting, and after a failure the generation or capabilities may have moved on.
            self.loadStatus()
        }
    }

    private func loadStatus() {
        guard var current = inspection else { return }
        statusTask?.cancel()
        let token = epoch
        let workerID = current.workerID
        if current.loadedStatus != nil {
            current.isRefreshing = true
            current.refreshError = nil
        } else {
            current.status = .loading
        }
        inspection = current
        statusTask = Task { [service] in
            let result: Result<ProviderSessionStatus, Error>
            do {
                result = .success(try await service.status(workerID))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, token == self.epoch, var latest = self.inspection,
                  latest.workerID == workerID else { return }
            latest.isRefreshing = false
            switch result {
            case .success(let status):
                latest.status = .loaded(status)
                latest.refreshError = nil
            case .failure(let error):
                if latest.loadedStatus != nil {
                    latest.refreshError = error.localizedDescription
                } else {
                    latest.status = .failed(error.localizedDescription)
                }
            }
            self.inspection = latest
        }
    }

    private func fetchSessions(cursor: String?) {
        guard let current = inspection else { return }
        listingTask?.cancel()
        listingToken += 1
        let token = listingToken
        let currentEpoch = self.epoch
        let workerID = current.workerID
        listingTask = Task { [service] in
            let result: Result<ProviderSessionPage, Error>
            do {
                result = .success(try await service.sessions(workerID, cursor))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, token == self.listingToken, currentEpoch == self.epoch,
                  var latest = self.inspection, latest.workerID == workerID else { return }
            var listing = latest.listing
            listing.isLoadingMore = false
            switch result {
            case .success(let page):
                var seen = Set((cursor == nil ? [] : listing.sessions).map(\.id))
                let fresh = page.sessions.filter { !$0.sessionID.isEmpty && seen.insert($0.id).inserted }
                listing.sessions = (cursor == nil ? [] : listing.sessions) + fresh
                // A repeated cursor would page forever.
                listing.nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
                listing.phase = .loaded
                listing.pageError = nil
            case .failure(let error):
                if cursor == nil {
                    listing.phase = .failed(error.localizedDescription)
                } else {
                    listing.pageError = error.localizedDescription
                }
            }
            latest.listing = listing
            self.inspection = latest
        }
    }
}

extension ProviderSessionModel {
    /// The model the live cockpit uses. Every request names the worker only; the service resolves
    /// its binding and scope.
    static func live(reader: ServiceClient) -> ProviderSessionModel {
        ProviderSessionModel(service: Service(
            status: { workerID in try await reader.providerSessionStatus(workerID) },
            sessions: { workerID, cursor in try await reader.providerSessions(workerID, cursor: cursor) },
            reattach: { workerID, request, key in
                try await reader.reattachWorker(workerID, request: request, operationID: key)
            }))
    }
}

/// The feature layer's provider-session operations, as the cockpit emits them.
struct ProviderSessionIntents {
    /// Opens the panel's reading on a worker by ID, or closes it with nil.
    var inspect: @MainActor (_ workerID: String?) -> Void
    /// The open reading. A surface draws it only when it is its own worker's.
    var inspection: @MainActor () -> ProviderSessionInspection?
    var refresh: @MainActor () -> Void
    var discover: @MainActor () -> Void
    var loadMore: @MainActor () -> Void
    var reattach: @MainActor (_ workerID: String, _ acknowledgeDeliveryUnknown: Bool) -> Void
}

extension CockpitModel {
    var providerSessionIntents: ProviderSessionIntents {
        ProviderSessionIntents(
            inspect: { [self] workerID in providerSessions.inspect(workerID) },
            inspection: { [self] in providerSessions.inspection },
            refresh: { [self] in providerSessions.refresh() },
            discover: { [self] in providerSessions.discover() },
            loadMore: { [self] in providerSessions.loadMoreSessions() },
            reattach: { [self] workerID, acknowledge in
                providerSessions.reattach(workerID, acknowledgeDeliveryUnknown: acknowledge)
            })
    }
}

// MARK: - Component values

/// What one worker console needs to offer its provider session: the action, and on a console that
/// hosts the panel (a wall tile or the focused worker), the panel's values and intents.
struct ProviderSessionAccess {
    struct Panel {
        let isPresented: Binding<Bool>
        /// This worker's reading. Nil until it starts.
        let inspection: ProviderSessionInspection?
        let refresh: () -> Void
        let discover: () -> Void
        let loadMore: () -> Void
        /// Reattach this worker, acknowledging unresolved delivery when true.
        let reattach: (_ acknowledgeDeliveryUnknown: Bool) -> Void
        let copy: (String) -> Void
    }

    let workerID: String
    let workerName: String
    let client: AgentClient
    let session: NativeSession
    let open: () -> Void
    var panel: Panel? = nil
}

// MARK: - Molecules

/// One labelled fact of the session: the label leading, its value trailing, a sentence beneath
/// when the value needs one. The adoption concept's detail rows.
struct ProviderSessionFact: View {
    let label: String
    let value: String
    var tone: Tone? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(TypeRole.meta).foregroundStyle(.inkSecondary)
                Spacer(minLength: 8)
                Text(verbatim: value).font(TypeRole.label)
                    .foregroundStyle(tone?.color ?? Palette.foreground)
                    .textSelection(.enabled)
            }
            if let detail {
                Text(verbatim: detail).font(TypeRole.caption).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }
}

/// One capability the provider negotiated, as a check or a dash with its name. Text carries the
/// state as well as the glyph.
struct ProviderCapabilityCheck: View {
    let title: String
    let isOffered: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isOffered ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 12))
                .foregroundStyle(isOffered ? AnyShapeStyle(Palette.working) : AnyShapeStyle(.inkSecondary))
                .accessibilityHidden(true)
            Text(title).font(TypeRole.meta)
                .foregroundStyle(isOffered ? AnyShapeStyle(Palette.foreground) : AnyShapeStyle(.inkSecondary))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(isOffered ? "offered" : "not offered")")
    }
}

/// One session the provider listed, in the terminal face. The session bound to this worker says
/// so; the others are shown for reference and are never a reattach target.
struct ProviderSessionRow: View {
    let session: ProviderSessionSummary
    let isBound: Bool
    let copy: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(isBound ? "● " : "○ ").foregroundStyle(isBound ? Term.green : Term.dim)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    Text(verbatim: title).foregroundStyle(Term.bright).lineLimit(2)
                        .textSelection(.enabled)
                }
                Text(verbatim: session.sessionID).foregroundStyle(.inkTermDim)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(session.sessionID)
            }
            Spacer(minLength: 6)
            if isBound {
                Text("this worker").foregroundStyle(Term.green).fixedSize()
            }
            Button("copy") { copy(session.sessionID) }
                .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                .accessibilityLabel("Copy session ID \(session.sessionID)")
        }
        .font(Term.font(11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isBound ? "Session \(session.sessionID), bound to this worker" : "Session \(session.sessionID)")
    }
}

// MARK: - Organism

/// The provider session of one worker: its binding, what the provider can do, whether history can
/// be read, the sessions the provider lists in the worker's scope, and reattach. Loading, an empty
/// list, a failure, paging and each unavailable capability are stated in words.
struct ProviderSessionPanel: View {
    let workerName: String
    let client: AgentClient
    let session: NativeSession
    let panel: ProviderSessionAccess.Panel

    @State private var confirmingReattach = false

    private var inspection: ProviderSessionInspection? { panel.inspection }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    if let status = inspection?.loadedStatus {
                        capabilities(status)
                        discovery(status)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
            if let status = inspection?.loadedStatus {
                Hairline()
                reattachBar(status)
            }
        }
        .frame(width: 460)
        .alert("Reattach with unresolved delivery?", isPresented: $confirmingReattach) {
            Button("Reattach", role: .destructive) { panel.reattach(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unresolvedMessage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider session, \(workerName)")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentAvatar(client: client, size: 18)
                Text(workerName).font(TypeRole.sectionTitle).foregroundStyle(Palette.foreground)
                    .lineLimit(1).truncationMode(.tail)
                Kicker(text: "Provider session")
                Spacer(minLength: 8)
                if inspection?.isRefreshing == true {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Reading the session status again")
                } else {
                    SymbolButton(symbol: "arrow.clockwise", label: "Read the session status again", size: 10) {
                        panel.refresh()
                    }
                    .foregroundStyle(.inkSecondary)
                    .disabled(inspection?.loadedStatus == nil)
                }
                SymbolButton(symbol: "xmark", label: "Close provider session", size: 10) {
                    panel.isPresented.wrappedValue = false
                }
                .foregroundStyle(.inkSecondary)
                .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: sessionLine)
                    .font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Harness \(session.harnessInstance.isEmpty ? "not reported" : session.harnessInstance), session \(session.sessionID)")
                Spacer(minLength: 4)
                Button("copy session") { panel.copy(session.sessionID) }
                    .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                    .accessibilityLabel("Copy session ID \(session.sessionID)")
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private var sessionLine: String {
        ((session.harnessInstance.isEmpty ? [] : [session.harnessInstance])
            + ["session " + session.sessionID]).joined(separator: " · ")
    }

    // MARK: Status

    @ViewBuilder private var statusSection: some View {
        switch inspection?.status {
        case nil, .loading?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading this worker's provider session…").font(TypeRole.meta).foregroundStyle(.inkSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading this worker's provider session")
        case .failed(let message)?:
            failure("The session status could not be read: \(message)", retryTitle: "Read again", retry: panel.refresh)
        case .loaded(let status)?:
            VStack(alignment: .leading, spacing: 0) {
                Kicker(text: "Status").padding(.bottom, 4)
                ProviderSessionFact(label: "History", value: status.history.label,
                                    tone: status.history == .available ? Tone.working : nil,
                                    detail: status.history.statement)
                ProviderSessionFact(label: "Control generation", value: status.generation.map(String.init) ?? "none")
                ProviderSessionFact(label: "Unresolved delivery",
                                    value: status.deliveryUnknown == 0 ? "None" : "\(status.deliveryUnknown)",
                                    tone: status.deliveryUnknown == 0 ? nil : Tone.attention,
                                    detail: status.deliveryUnknown == 0 ? nil
                                        : "Commander accepted \(status.deliveryUnknown == 1 ? "a follow-up or interrupt" : "\(status.deliveryUnknown) follow-ups or interrupts") whose delivery it cannot confirm. They are never sent again automatically.")
                if let error = inspection?.refreshError {
                    Text(verbatim: "The last refresh failed: \(error)")
                        .font(TypeRole.caption).foregroundStyle(Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func capabilities(_ status: ProviderSessionStatus) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Kicker(text: "Provider capabilities")
            if let caps = status.peerCapabilities {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ProviderCapabilityCheck(title: "Resume a session", isOffered: caps.canResume)
                        ProviderCapabilityCheck(title: "List sessions", isOffered: caps.canListSessions)
                    }
                    GridRow {
                        ProviderCapabilityCheck(title: "Read history", isOffered: caps.canReadHistory)
                        ProviderCapabilityCheck(title: "Interrupt a turn", isOffered: caps.canInterrupt)
                    }
                    GridRow {
                        ProviderCapabilityCheck(title: "Answer requests", isOffered: caps.canAnswer)
                        Color.clear.frame(height: 1)
                    }
                }
            } else {
                Text("The provider has not reported what this session can do.")
                    .font(TypeRole.caption).foregroundStyle(.inkSecondary)
            }
        }
    }

    // MARK: Discovery

    private func discovery(_ status: ProviderSessionStatus) -> some View {
        let listing = inspection?.listing ?? ProviderSessionInspection.Listing()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Kicker(text: "Sessions in this worker's scope")
                Spacer(minLength: 6)
                if status.canDiscover, listing.phase != .loading {
                    Button(listing.phase == .idle ? "Discover" : "Read again", action: panel.discover)
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(listing.isLoadingMore)
                        .help("List the sessions the provider keeps for this worker's checkout")
                }
            }
            if let reason = status.discoveryUnavailableReason {
                Text(verbatim: reason).font(TypeRole.caption).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                sessionList(listing)
            }
        }
    }

    @ViewBuilder private func sessionList(_ listing: ProviderSessionInspection.Listing) -> some View {
        switch listing.phase {
        case .idle:
            Text("Discovery asks the provider for the sessions it keeps in this worker's scope. Listing them changes nothing.")
                .font(TypeRole.caption).foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking the provider for its sessions…").font(TypeRole.meta).foregroundStyle(.inkSecondary)
            }
        case .failed(let message):
            failure("The sessions could not be listed: \(message)", retryTitle: "Try again", retry: panel.discover)
        case .loaded:
            VStack(alignment: .leading, spacing: 0) {
                if listing.sessions.isEmpty {
                    Text(listing.nextCursor == nil
                         ? "○ the provider lists no sessions in this worker's scope"
                         : "○ no sessions on this page")
                        .font(Term.font(11.5)).foregroundStyle(.inkTermDim)
                        .padding(10)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(listing.sessions) { item in
                            ProviderSessionRow(session: item, isBound: item.sessionID == session.sessionID,
                                               copy: panel.copy)
                        }
                    }
                    .padding(10)
                }
                listFooter(listing)
            }
            .background(Term.background)
            .overlay { Rectangle().strokeBorder(Term.rule, lineWidth: 1) }
        }
    }

    private func listFooter(_ listing: ProviderSessionInspection.Listing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(listing.sessions.count == 1 ? "1 session" : "\(listing.sessions.count) sessions")
                .font(Term.font(10.75)).foregroundStyle(.inkTermDim)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            if let error = listing.pageError {
                Text(verbatim: "! " + error).font(Term.font(10.75)).foregroundStyle(Term.amber)
                    .lineLimit(1).truncationMode(.tail)
                    .help(error)
                    .accessibilityLabel("The next page could not be read: \(error)")
            }
            if listing.isLoadingMore {
                Text("reading…").font(Term.font(10.75)).foregroundStyle(Term.cyan)
                    .accessibilityLabel("Reading the next page of sessions")
            } else if listing.nextCursor != nil {
                Button(listing.pageError == nil ? "load more" : "retry", action: panel.loadMore)
                    .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10.75))
                    .accessibilityLabel("Load more provider sessions")
            } else if !listing.sessions.isEmpty {
                Text("end of sessions").font(Term.font(10.75)).foregroundStyle(.inkTermDim)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 27)
        .background(Term.bar)
        .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
    }

    // MARK: Reattach

    private func reattachBar(_ status: ProviderSessionStatus) -> some View {
        let phase = inspection?.reattach ?? .idle
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reattach to the original session").font(TypeRole.label).foregroundStyle(Palette.foreground)
                    Text(verbatim: status.reattachUnavailableReason
                         ?? "Restarts \(workerName) on session \(Identifier.short(session.sessionID)). Nothing is sent or resubmitted.")
                        .font(TypeRole.caption).foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if phase == .sending {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Reattaching \(workerName)")
                } else {
                    Button {
                        if status.deliveryUnknown > 0 { confirmingReattach = true } else { panel.reattach(false) }
                    } label: {
                        Label(phase.isFailure ? "Retry reattach" : "Reattach", systemImage: "link")
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: true, height: 30))
                    .disabled(!status.reattachIsOffered || phase == .accepted)
                    .help(status.reattachUnavailableReason ?? "Reattach \(workerName) to its own provider session")
                    .accessibilityLabel("Reattach \(workerName) to its original provider session")
                }
            }
            switch phase {
            case .accepted:
                statusLine("checkmark.circle", "Reattach accepted. \(workerName) is starting on its original session.",
                           tone: .working)
            case .failed(let message):
                statusLine("exclamationmark.triangle", "Reattach was not accepted: \(message)", tone: .failure)
            case .idle, .sending:
                EmptyView()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Palette.panel)
    }

    private var unresolvedMessage: String {
        let count = inspection?.loadedStatus?.deliveryUnknown ?? 0
        let what = count == 1 ? "1 follow-up or interrupt" : "\(count) follow-ups or interrupts"
        return "\(what) to \(workerName) may or may not have been delivered. Reattaching leaves them unresolved: Commander does not send or resubmit them. Check the worker's source before sending anything again."
    }

    // MARK: Shared pieces

    private func failure(_ text: String, retryTitle: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine("xmark.octagon", text, tone: .failure)
            Button(retryTitle, action: retry).buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func statusLine(_ symbol: String, _ text: String, tone: Tone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).accessibilityHidden(true)
            Text(verbatim: text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(TypeRole.caption)
        .foregroundStyle(tone.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension ProviderSessionInspection.ReattachPhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Presents the provider-session panel from the worker console's title bar.
struct ProviderSessionPresentation: ViewModifier {
    let access: ProviderSessionAccess?

    func body(content: Content) -> some View {
        if let access, let panel = access.panel {
            content.popover(isPresented: panel.isPresented, arrowEdge: .bottom) {
                ProviderSessionPanel(workerName: access.workerName, client: access.client,
                                     session: access.session, panel: panel)
            }
        } else {
            content
        }
    }
}
