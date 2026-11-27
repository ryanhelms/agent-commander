import Foundation
import Observation
import SwiftUI

// MEMBERSHIP REQUESTS (design/COMMANDER-NETWORK-DISCOVERY.md, "Membership requests").
// A person a relay turned away at sign-in may ask its admins to let them in, and an admin approves
// or denies each request. The device agent owns the rules: a request must follow a refused sign-in
// from this Mac, a denial holds for a day, and the relay caps its queue. Rules this file keeps:
// - Request access is offered only when the server's own `status` says `requestable`.
// - What a verb answered stands until `status` says something new; then `status` decides.
// - A pending request is read again on the tray's cadence, after each server list.
// - Nothing here says who else is a member of a relay, or who decided a request.
// - An admin's list that can't be read is left out, without an error: a member who isn't an
//   admin sees nothing.
//
// ATOMIC LEVELS:
//   values     MultiplayerMembershipAsk, MultiplayerMembershipRequest, MultiplayerMembershipRequestStatus
//   model      MultiplayerMembershipRequestModel (owns the four verbs)
//   molecule   MultiplayerRequestAccess (state label, the note field and Request access)

// MARK: - Contract

/// Where a membership request stands, in the device agent's word (`status.accessRequest`). A word
/// this build doesn't know reads as `none`, never as something the person can act on.
enum MultiplayerMembershipAsk: String, Sendable, Equatable {
    case none = ""
    /// Sign-in was refused, and the person may ask.
    case requestable
    case pending, approved, denied
    /// The relay's queue of pending requests is full.
    case full

    init(word: String) { self = Self(rawValue: word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .none }
}

/// One membership request: the person's own, as `membership-request` and `membership-request-status`
/// answer, or one waiting on an admin, as `admin-requests` lists it. Every key may be missing.
struct MultiplayerMembershipRequest: Decodable, Equatable, Sendable, Identifiable {
    /// The relay's word on a request. `admitted` means the person has signed in since it was approved.
    enum Status: String, Sendable, Equatable {
        case none = "", pending, approved, denied, admitted
    }

    let id: String
    var status: Status
    /// The requester's email. Only an admin's list carries it.
    var email: String
    var note: String
    var createdAt: Date?
    var decidedAt: Date?

    private enum CodingKeys: String, CodingKey { case id, status, email, note, createdAt, decidedAt }

    init(id: String, status: Status = .pending, email: String = "", note: String = "", createdAt: Date? = nil,
         decidedAt: Date? = nil) {
        self.id = id
        self.status = status
        self.email = email
        self.note = note
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            (((try? values.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        id = text(.id)
        status = Status(rawValue: text(.status).lowercased()) ?? .none
        email = text(.email)
        note = text(.note)
        createdAt = MultiplayerTime.parse(text(.createdAt))
        decidedAt = MultiplayerTime.parse(text(.decidedAt))
    }

    /// The email, made safe to draw.
    var shownEmail: String {
        let shown = MultiplayerText.clean(email, limit: 120)
        return shown.isEmpty ? "No email given" : shown
    }

    /// The note, made safe to draw. The relay keeps 280 characters.
    var shownNote: String { MultiplayerText.clean(note, limit: Self.noteLimit) }

    static let noteLimit = 280

    /// "5 minutes ago", "2 hours ago", "3 days ago", or "just now". Nil for a time that hasn't
    /// happened yet. Whole units in plain words, so a sentence reads the same on every Mac.
    static func age(_ date: Date?, now: Date) -> String? {
        guard let date, date <= now else { return nil }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(MultiplayerPlural.count(seconds / 60, "minute")) ago" }
        if seconds < 86_400 { return "\(MultiplayerPlural.count(seconds / 3600, "hour")) ago" }
        return "\(MultiplayerPlural.count(seconds / 86_400, "day")) ago"
    }
}

/// An `admin-requests` reply. A request without an ID is dropped, because it couldn't be answered.
struct MultiplayerMembershipRequestList: Decodable, Equatable, Sendable {
    let requests: [MultiplayerMembershipRequest]

    private enum CodingKeys: String, CodingKey { case requests }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let listed = ((try? values.decodeIfPresent(MultiplayerLenientList<MultiplayerMembershipRequest>.self, forKey: .requests)) ?? nil)?.items ?? []
        requests = MultiplayerUnique.keep(listed.filter { !$0.id.isEmpty }) { $0.id }
    }
}

extension MultiplayerClient {
    /// Asks the relay's admins to admit this account. The note is sent only when there is one.
    func requestMembership(note: String) async throws -> MultiplayerMembershipRequest {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await fetch(.membershipRequest, note.isEmpty ? [:] : ["note": .string(note)], as: MultiplayerMembershipRequest.self)
    }

    /// The person's own request on this relay. Its status is empty when there is none.
    func membershipRequestStatus() async throws -> MultiplayerMembershipRequest {
        try await fetch(.membershipRequestStatus, [:], as: MultiplayerMembershipRequest.self)
    }

    /// The requests waiting on this relay's admins. Refused for anyone who isn't one.
    func adminMembershipRequests() async throws -> [MultiplayerMembershipRequest] {
        try await fetch(.adminRequests, [:], as: MultiplayerMembershipRequestList.self).requests
    }

    func decideMembershipRequest(id: String, approve: Bool) async throws {
        do {
            let output = try await call(.adminRequestDecide, payload: ["id": .string(id), "decision": .string(approve ? "approve" : "deny")])
            _ = try MultiplayerEnvelope.decode(MultiplayerIgnored.self, from: output)
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }
}

// MARK: - Values for a view

/// A person's request to join one relay, as a view draws it.
struct MultiplayerMembershipRequestStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Sign-in was refused and the person may ask.
        case requestable
        case sending
        case pending
        /// Admitted at the next sign-in.
        case approved
        case denied
        /// The relay took no request because too many are waiting.
        case full
    }

    var phase: Phase
    /// The note that went with the request.
    var note = ""
    var requestedAt: Date? = nil
    var decidedAt: Date? = nil
    /// Why the last Request access wasn't taken.
    var failure: String? = nil

    /// How long a denial holds before the person can ask again.
    static let denialHold: TimeInterval = 24 * 60 * 60

    /// The state's word. Nil while the person hasn't asked: the field and the button say it.
    var title: String? {
        switch phase {
        case .requestable, .sending: nil
        case .pending: "Requested"
        case .approved: "Approved"
        case .denied: "Declined"
        case .full: "Queue full"
        }
    }

    var lamp: MultiplayerLamp.Kind {
        switch phase {
        case .requestable, .sending, .pending: .waiting
        case .approved: .on
        case .denied: .error
        case .full: .busy
        }
    }

    var tone: Tone {
        switch phase {
        case .requestable, .sending, .pending: .focus
        case .approved: .working
        case .denied: .failure
        case .full: .attention
        }
    }

    /// Whether the person can ask now.
    var canRequest: Bool { phase == .requestable }

    /// Signing in again can help: with the approval, or with another account after a refusal.
    var offersSignIn: Bool { phase != .sending && phase != .pending }

    /// What stands, in a sentence or two. `contact` is the relay's admin contact, when it gave one.
    func detail(contact: String = "", now: Date) -> String {
        let contact = MultiplayerText.clean(contact, limit: 120)
        switch phase {
        case .requestable:
            return "This relay didn’t admit your account. You can ask its admins to let you in."
        case .sending:
            return "Sending your request…"
        case .pending:
            let lead = MultiplayerMembershipRequest.age(requestedAt, now: now).map { "Requested \($0)." } ?? "Requested."
            return "\(lead) The relay’s admins decide. Commander checks again on its own."
        case .approved:
            let lead = MultiplayerMembershipRequest.age(decidedAt, now: now).map { "Approved \($0)." } ?? "Approved."
            return "\(lead) You’re admitted the next time you sign in."
        case .denied:
            guard let decidedAt, decidedAt <= now else {
                return "The relay’s admins declined a request from this account in the last day. You can ask again 24 hours after that."
            }
            let lead = MultiplayerMembershipRequest.age(decidedAt, now: now).map { "Declined \($0)." } ?? "Declined."
            let left = decidedAt.addingTimeInterval(Self.denialHold).timeIntervalSince(now)
            guard left > 0 else { return "\(lead) Sign in again to ask once more." }
            let hours = Int((left / 3600).rounded(.up))
            return "\(lead) You can ask again in about \(MultiplayerPlural.count(hours, "hour"))."
        case .full:
            let ask = contact.isEmpty ? "Ask one of its admins directly." : "Ask \(contact) directly."
            return "This relay has too many requests waiting, so it didn’t take yours. \(ask)"
        }
    }

    /// What VoiceOver says for the state.
    func spoken(contact: String = "", now: Date) -> String {
        [title, detail(contact: contact, now: now)].compactMap { $0 }.joined(separator: ". ")
    }
}

// MARK: - Model

/// Membership requests across the server list: the person's own on each relay that turned them
/// away, and the ones waiting on them where they are an admin.
@MainActor @Observable
final class MultiplayerMembershipRequestModel {
    /// What a verb answered, and the status word it answered over. It stands while the word is the same.
    private struct Mark: Equatable {
        let basis: MultiplayerMembershipAsk
        let state: MultiplayerMembershipAsk
    }

    /// The person's own request on each server, as the relay last gave it.
    private(set) var records: [String: MultiplayerMembershipRequest] = [:]
    private var marks: [String: Mark] = [:]
    private(set) var sending: Set<String> = []
    /// Why the last Request access on a server wasn't taken.
    private(set) var failures: [String: String] = [:]
    /// The note field, by server.
    var notes: [String: String] = [:]
    /// The requests waiting on the person, by the server they administer. A server whose list
    /// can't be read has no entry.
    private(set) var waiting: [String: [MultiplayerMembershipRequest]] = [:]

    @ObservationIgnored weak var tray: MultiplayerModel?
    private let client: MultiplayerClient?
    @ObservationIgnored private var reads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var adminReads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var sends: [String: Task<Void, Never>] = [:]
    /// Servers whose decided request has been read once, so it isn't read on every pass.
    @ObservationIgnored private var settled: Set<String> = []

    init(client: MultiplayerClient?) {
        self.client = client
    }

    // MARK: Derived values

    /// The status word of a server the person isn't signed in to.
    private func word(_ server: String) -> MultiplayerMembershipAsk {
        guard let tray, let saved = tray.server(server), !saved.signedIn, saved.state != .certChanged else { return .none }
        return tray.session(server)?.status?.membershipAsk ?? .none
    }

    private func ask(_ server: String) -> MultiplayerMembershipAsk {
        let word = word(server)
        if let mark = marks[server], mark.basis == word { return mark.state }
        return word
    }

    /// The person's request on a server, or nil when there is nothing to ask or to show.
    func status(for server: String) -> MultiplayerMembershipRequestStatus? {
        guard let tray, let saved = tray.server(server), !saved.signedIn, saved.state != .certChanged else { return nil }
        let phase: MultiplayerMembershipRequestStatus.Phase
        if sending.contains(server) {
            phase = .sending
        } else {
            switch ask(server) {
            case .none: return nil
            case .requestable: phase = .requestable
            case .pending: phase = .pending
            case .approved: phase = .approved
            case .denied: phase = .denied
            case .full: phase = .full
            }
        }
        let record = records[server]
        return MultiplayerMembershipRequestStatus(phase: phase, note: record?.shownNote ?? "", requestedAt: record?.createdAt,
                                                  decidedAt: record?.decidedAt,
                                                  failure: phase == .requestable ? failures[server] : nil)
    }

    /// Whether Request access can start now.
    var canAct: Bool { client != nil && tray?.isBusy == false }

    /// Every request waiting on the person, across the servers they administer.
    var waitingCount: Int { waiting.values.reduce(0) { $0 + $1.count } }

    func waitingCount(on server: String) -> Int { waiting[server]?.count ?? 0 }

    // MARK: Reads

    /// Reads what changed since the last server list: a pending request, a decided one that hasn't
    /// been read, and the admin's list on each server the person administers.
    func refresh() {
        guard let client, let tray else { return }
        let ids = Set(tray.servers.map(\.id))
        forget(except: ids)
        for server in tray.servers {
            let id = server.id
            if server.signedIn {
                clear(id)
            } else if reads[id] == nil, !sending.contains(id) {
                switch ask(id) {
                case .pending: read(id, with: client)
                case .approved, .denied: if !settled.contains(id) { read(id, with: client) }
                case .none, .requestable, .full: break
                }
            }
            if tray.isAdmin(id), tray.session(id)?.isOnline == true {
                readWaiting(on: id)
            } else if waiting[id] != nil {
                waiting[id] = nil
            }
        }
    }

    private func read(_ server: String, with client: MultiplayerClient) {
        let basis = word(server)
        reads[server] = Task {
            let found = try? await client.scoped(to: server).membershipRequestStatus()
            self.reads[server] = nil
            guard let found, !Task.isCancelled else { return }
            self.take(found, on: server, over: basis)
        }
    }

    /// Takes the relay's word on the person's own request.
    private func take(_ request: MultiplayerMembershipRequest, on server: String, over basis: MultiplayerMembershipAsk) {
        switch request.status {
        case .pending:
            records[server] = request
            marks[server] = Mark(basis: basis, state: .pending)
        case .approved:
            records[server] = request
            marks[server] = Mark(basis: basis, state: .approved)
            settled.insert(server)
        case .denied:
            records[server] = request
            marks[server] = Mark(basis: basis, state: .denied)
            settled.insert(server)
        case .admitted, .none:
            // Admitted means signed in already: the server list says so on its next read.
            records[server] = nil
            marks[server] = Mark(basis: basis, state: .none)
        }
    }

    /// Reads the requests waiting on one server's admins. A refusal hides the list and says nothing.
    @discardableResult
    func readWaiting(on server: String) -> Task<Void, Never>? {
        guard let client else { return nil }
        if let running = adminReads[server] { return running }
        let task = Task {
            let found = try? await client.scoped(to: server).adminMembershipRequests()
            self.adminReads[server] = nil
            guard !Task.isCancelled else { return }
            self.waiting[server] = found?.filter { $0.status == .pending }
        }
        adminReads[server] = task
        return task
    }

    /// A request an admin answered leaves the list at once, ahead of the next read.
    func answered(_ id: String, on server: String) {
        waiting[server]?.removeAll { $0.id == id }
    }

    private func clear(_ server: String) {
        records[server] = nil
        marks[server] = nil
        failures[server] = nil
        notes[server] = nil
        settled.remove(server)
    }

    private func forget(except ids: Set<String>) {
        for id in Set(records.keys).union(marks.keys).union(failures.keys).union(notes.keys) where !ids.contains(id) { clear(id) }
        waiting = waiting.filter { ids.contains($0.key) }
    }

    /// The panel closed: the reads in flight stop. A request being sent is left to finish.
    func cancel() {
        (Array(reads.values) + Array(adminReads.values)).forEach { $0.cancel() }
        reads = [:]
        adminReads = [:]
    }

    // MARK: Intents

    /// Asks the relay's admins to admit this account, with the note in the field when there is one.
    @discardableResult
    func request(on server: String) -> Task<Void, Never>? {
        guard let client, canAct, !sending.contains(server), status(for: server)?.canRequest == true else { return nil }
        let basis = word(server)
        let note = (notes[server] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        sending.insert(server)
        failures[server] = nil
        let task = Task {
            let answer: Result<MultiplayerMembershipRequest, MultiplayerFailure>
            do { answer = .success(try await client.scoped(to: server).requestMembership(note: note)) } catch { answer = .failure(.from(error)) }
            self.sending.remove(server)
            self.sends[server] = nil
            switch answer {
            case .success(var made):
                if made.note.isEmpty { made.note = note }
                self.records[server] = made
                self.marks[server] = Mark(basis: basis, state: .pending)
                self.notes[server] = nil
            case .failure(.cancelled):
                break
            case .failure(let reason):
                self.refused(reason.message, on: server, over: basis)
            }
            // The device agent's own word follows on the server's next status.
            self.tray?.session(server)?.refresh()
        }
        sends[server] = task
        return task
    }

    /// Reads a refusal as the state it means. Anything else is shown under the note field.
    private func refused(_ message: String, on server: String, over basis: MultiplayerMembershipAsk) {
        let lower = message.lowercased()
        if lower.contains("declined a request") {
            records[server] = nil
            marks[server] = Mark(basis: basis, state: .denied)
        } else if lower.contains("too many pending") {
            marks[server] = Mark(basis: basis, state: .full)
        } else if lower.contains("sign in first") {
            failures[server] = "A request has to follow a refused sign-in within 15 minutes. Sign in again, then ask."
        } else if lower.contains("already a member") {
            failures[server] = "This account is already a member of this relay. Sign in again."
        } else {
            failures[server] = MultiplayerSentence.join("Couldn’t send the request.", message)
        }
    }

    // MARK: Testing support

    /// A request being sent or read, if any.
    var quietTask: Task<Void, Never>? { sends.values.first ?? reads.values.first ?? adminReads.values.first }

    /// Waits until no request is being sent or read.
    func settle() async {
        while let task = quietTask { await task.value }
    }
}

extension MultiplayerModel {
    /// Approves or denies one membership request on a relay the person administers. The ID is the
    /// request's. An approval admits the person the next time they sign in.
    func decideMembershipRequest(_ id: String, on server: String, approve: Bool) async -> MultiplayerActionResult {
        let who = requests.waiting[server]?.first { $0.id == id }?.shownEmail ?? "the request"
        let lead = approve ? "Couldn’t approve \(who)." : "Couldn’t deny \(who)."
        guard session(server)?.isOnline == true else {
            return .failed(id: id, server: server,
                           reason: MultiplayerSentence.join(lead, "Sign in to \(self.server(server)?.displayName ?? "that server") first."))
        }
        return await result(id: id, server: server, failing: lead) { report in
            act(approve ? "Approving \(who)…" : "Denying \(who)…", failing: lead,
                confirmation: approve ? "Approved \(who). They’re admitted the next time they sign in."
                                      : "Denied \(who). They can ask again in 24 hours.", report: report) { client in
                try await client.scoped(to: server).decideMembershipRequest(id: id, approve: approve)
                self.requests.answered(id, on: server)
            }
        }
    }
}

// MARK: - Molecule

/// A person's request to join a relay: where it stands, and while they can ask, the note field and
/// Request access. Drawn in the join checklist's Membership step and under a server's row.
struct MultiplayerRequestAccess: View {
    let status: MultiplayerMembershipRequestStatus
    /// The relay's admin contact, when it gave one.
    var contact = ""
    let now: Date
    @Binding var note: String
    /// Whether an action can start now.
    let canAct: Bool
    /// Request access is the page's primary action.
    var isProminent = true
    /// The join checklist says the sentence in its own step, so it leaves this out.
    var showsDetail = true
    /// A server's row that already says "Requested" leaves the state label out.
    var showsState = true
    let onRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if showsState, let title = status.title {
                MultiplayerStateLabel(lamp: status.lamp, text: title, tone: status.tone)
                    .accessibilityHidden(showsDetail)
            }
            if showsDetail {
                Text(status.detail(contact: contact, now: now))
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(status.spoken(contact: contact, now: now))
            }
            if status.phase == .pending, !status.note.isEmpty {
                MultiplayerWell {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your note")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                        Text(status.note)
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if status.phase == .requestable || status.phase == .sending { form }
        }
    }

    @ViewBuilder private var form: some View {
        let isSending = status.phase == .sending
        MultiplayerField(label: "Note for the admins (optional)",
                         hint: note.count > MultiplayerMembershipRequest.noteLimit
                            ? "The relay keeps the first \(MultiplayerMembershipRequest.noteLimit) characters."
                            : "They read it beside your email.",
                         problem: status.failure) {
            MultiplayerTextField(label: "Note for the admins, optional", placeholder: "Who you are, or why you’d like to join", text: $note)
                .disabled(isSending)
        }
        HStack(spacing: Space.s) {
            Button("Request access", action: onRequest)
                .buttonStyle(MultiplayerTrayButtonStyle(role: isProminent ? .primary : .standard))
                .disabled(!canAct || isSending)
                .accessibilityHint("Asks this relay’s admins to let you in")
            if isSending {
                MultiplayerSpinner()
                Text("Sending…")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
            }
        }
        .padding(.top, 2)
    }
}
