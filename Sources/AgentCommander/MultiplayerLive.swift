import Foundation

// MULTIPLAYER CONTRACT: live work (design/COMMANDER-NETWORK-INCREMENT-4.md).
// Watch, Co-pilot suggestions and control hand-over, Review exchange and Fan-out, as the device
// agent's tray verbs `watch`, `handover`, `handback`, `handovers`, `fanout` and `review-post`
// exchange them. Values only; MultiplayerLiveModel calls the helper. Every reply is read from plain
// JSON, leniently: a field this build can't read is left out rather than failing the page, and a
// result is taken from `value` or `result`, whichever the device agent names.

extension MultiplayerSharePolicy {
    static let watch = "agent.watch"
    static let suggest = "agent.suggest"
    static let review = "review.request"
    /// `sent` lists a fan-out under "fanout:" and the action its first target ran.
    static let fanoutPrefix = "fanout:"
}

extension MultiplayerDirectoryEntry {
    var canWatch: Bool { granted.contains(MultiplayerSharePolicy.watch) }
    var canSuggest: Bool { granted.contains(MultiplayerSharePolicy.suggest) }
    var canReview: Bool { granted.contains(MultiplayerSharePolicy.review) }
}

extension MultiplayerApproval {
    /// A Co-pilot suggestion: it always waits for the owner, whatever the grant says.
    var isSuggestion: Bool { action == MultiplayerSharePolicy.suggest }

    /// "Suggestion from sam", or what the friend wants to do.
    var headline: String {
        let who = peer.isEmpty ? "a friend" : peer.multiplayerDisplay
        return isSuggestion ? "Suggestion from \(who)" : "\(peer.isEmpty ? "A friend" : who) \(wants)"
    }
}

extension MultiplayerJSON {
    var int: Int? {
        if case .number(let value) = self { return Int(exactly: value.rounded()) }
        return nil
    }

    /// A request's result, under either name the device agent uses.
    var outcome: MultiplayerJSON? {
        let value = self["value"] ?? self["result"]
        return value == .null ? nil : value
    }
}

extension MultiplayerSentRequest {
    /// One row of `sent`, read from plain JSON so a fan-out's children can be read beside it.
    init?(json: MultiplayerJSON) {
        guard let request = json.firstText("request") else { return nil }
        self.init(request: request, resource: json.firstText("resource") ?? "", action: json.firstText("action") ?? "",
                  title: json.firstText("title") ?? "", at: json["at"]?.text.flatMap(MultiplayerTime.parse),
                  status: json.firstText("status") ?? "", value: json.outcome,
                  failure: json.firstText("failure", "error") ?? "")
    }
}

// MARK: - Watch

/// One line of a watched worker's output.
struct MultiplayerWatchEvent: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case message, tool, status }

    /// Its place in the stream this panel has read, so a repeated line is still its own row.
    var id: Int = 0
    let at: Date?
    let kind: Kind
    let text: String

    init(id: Int = 0, at: Date? = nil, kind: Kind, text: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.text = text
    }

    init?(_ json: MultiplayerJSON) {
        guard let raw = json.firstText("text", "summary", "content") else { return nil }
        at = json["at"]?.text.flatMap(MultiplayerTime.parse)
        kind = Kind(rawValue: json.firstText("kind") ?? "") ?? .message
        text = MultiplayerText.clean(raw, limit: 600, redact: true)
    }

    /// One observation of Commander's own history page, which the owner's device may pass through.
    init?(observation json: MultiplayerJSON) {
        at = json["at"]?.text.flatMap(MultiplayerTime.parse)
        if let said = json["text"]?.firstText("text") {
            kind = .message
            text = MultiplayerText.clean(said, limit: 600, redact: true)
        } else if let tool = json["tool"] {
            kind = .tool
            let parts = [tool.firstText("name"), tool.firstText("summary")].compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            text = MultiplayerText.clean(parts.joined(separator: ": "), limit: 600, redact: true)
        } else if let ended = json["turnEnded"] {
            kind = .status
            text = "Turn ended: \(MultiplayerRequestState.title(ended.firstText("reason") ?? "done").lowercasedFirst)"
        } else {
            return nil
        }
    }

    var kindTitle: String {
        switch kind {
        case .message: "Message"
        case .tool: "Tool"
        case .status: "Status"
        }
    }

    /// The trace gutter's three-letter tag.
    var tag: String {
        switch kind {
        case .message: "msg"
        case .tool: "run"
        case .status: "sys"
        }
    }
}

/// What one `watch` call brought back.
struct MultiplayerWatchReply: Equatable, Sendable {
    let events: [MultiplayerWatchEvent]
    /// Where the next call resumes. Empty keeps the cursor the panel already has.
    let cursor: String
    /// The worker's run state, in the owner's words.
    let state: String
    /// The request's own status: `ok`, or why nothing came back.
    let status: String

    init(events: [MultiplayerWatchEvent] = [], cursor: String = "", state: String = "", status: String = "ok") {
        self.events = events
        self.cursor = cursor
        self.state = state
        self.status = status
    }

    init(_ json: MultiplayerJSON) {
        // The tray verb answers with the request's row; the events sit in its result.
        let body = json["events"] != nil || json["page"] != nil ? json : (json.outcome ?? json)
        status = json.firstText("status") ?? "ok"
        state = body.firstText("state") ?? ""
        if let listed = body["events"] {
            events = listed.items.compactMap { MultiplayerWatchEvent($0) }
            cursor = body.firstText("cursor") ?? ""
        } else {
            let page = body["page"]
            events = (page?["observations"]?.items ?? []).compactMap(MultiplayerWatchEvent.init(observation:))
            cursor = page?.firstText("nextCursor") ?? ""
        }
    }

    /// Why the stream is not flowing, or nil while it is.
    var refusal: String? {
        switch status.lowercased() {
        case "ok", "done", "completed", "succeeded", "success": nil
        case "pending", "queued", "claimed": "Waiting for the owner’s Mac to answer."
        case "denied": "The owner denied Watch on this worker."
        case "expired": "The owner’s Mac didn’t answer in time."
        case "budget_exhausted": "This grant is used up. Ask the owner for more."
        default: "The watch ended as “\(MultiplayerRequestState.title(status))”."
        }
    }

    /// True when asking again can help.
    var mayRecover: Bool { ["pending", "queued", "claimed", "expired"].contains(status.lowercased()) }
}

// MARK: - Control

/// A friend holding control of one of your workers: their prompts and suggestions run without asking.
struct MultiplayerHandover: Equatable, Sendable, Identifiable {
    /// The friend's handle. Empty when the device agent names only the account.
    var handle: String
    /// The friend's account on the relay. `handback` takes it as well as the handle.
    let user: String
    let resource: String
    let until: Date
    /// The server the device agent says the hand-over is on.
    var server: String = ""
    /// How long the hand-over was for, when this panel started it.
    var minutes: Int? = nil

    var id: String { "\(user.isEmpty ? handle : user)|\(resource)" }

    init(handle: String, user: String = "", resource: String, until: Date, server: String = "", minutes: Int? = nil) {
        self.handle = handle
        self.user = user
        self.resource = resource
        self.until = until
        self.server = server
        self.minutes = minutes
    }

    init?(_ json: MultiplayerJSON) {
        guard let resource = json.firstText("resource"), let until = json["until"]?.text.flatMap(MultiplayerTime.parse) else { return nil }
        user = json.firstText("user") ?? ""
        handle = json.firstText("handle", "peer") ?? ""
        guard !handle.isEmpty || !user.isEmpty else { return nil }
        self.resource = resource
        self.until = until
        server = json.firstText("server") ?? ""
    }

    /// The holder as the tray names them: the handle, or "A friend" when only the account is known.
    /// An account ID is never shown as a name.
    var who: String { handle.isEmpty ? "A friend" : handle.multiplayerDisplay }

    /// What `handback` is given: the account when the device listed one, since it always matches
    /// the hand-over's own key; otherwise the handle.
    var holderKey: String { user.isEmpty ? handle : user }

    func remaining(now: Date) -> TimeInterval { max(until.timeIntervalSince(now), 0) }
    func isLive(now: Date) -> Bool { until > now }

    /// The span the countdown's line drains over, in seconds: the hand-over's length when this
    /// panel started it, otherwise the shortest length the tray offers that still holds what is left.
    func span(now: Date) -> TimeInterval {
        if let minutes, minutes > 0 { return Double(minutes) * 60 }
        let left = remaining(now: now)
        let fits = MultiplayerHandoverLength.allCases.map { Double($0.rawValue) * 60 }.first { $0 >= left }
        return fits ?? max(left, 1)
    }

    /// The share of the hand-over still to run.
    func fraction(now: Date) -> Double { min(remaining(now: now) / span(now: now), 1) }

    /// "24:13", or "1:02:13" past the hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// The same time for VoiceOver: "24 minutes left".
    static func spoken(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds <= 0 { return "ended" }
        return minutes == 1 ? "1 minute left" : "\(minutes) minutes left"
    }
}

/// How long control is handed over for. The device agent takes 1 to 240 minutes.
enum MultiplayerHandoverLength: Int, CaseIterable, Identifiable, Sendable {
    case quarter = 15, half = 30, hour = 60, two = 120

    static let `default` = MultiplayerHandoverLength.half

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .quarter: "15 min"
        case .half: "30 min"
        case .hour: "1 hour"
        case .two: "2 hours"
        }
    }

    var spoken: String {
        switch self {
        case .quarter: "15 minutes"
        case .half: "30 minutes"
        case .hour: "1 hour"
        case .two: "2 hours"
        }
    }
}

struct MultiplayerHandoverDraft: Equatable {
    var handle = ""
    var length = MultiplayerHandoverLength.default
}

// MARK: - Review exchange

/// One thing a review found.
struct MultiplayerFinding: Equatable, Sendable, Identifiable {
    let id: Int
    let file: String
    let line: Int
    let severity: String
    let text: String

    var isImportant: Bool { severity.lowercased() == "important" }
    var severityTitle: String { isImportant ? "Important" : severity.lowercased() == "nit" ? "Nit" : severity.multiplayerDisplay }

    /// "relay/lease.go:118", or the file alone when the review names no line.
    var location: String {
        let name = file.multiplayerDisplay
        return line > 0 ? "\(name):\(line)" : name
    }
}

/// What `review.request` returned.
struct MultiplayerReview: Equatable, Sendable {
    let summary: String
    let findings: [MultiplayerFinding]

    init(summary: String, findings: [MultiplayerFinding] = []) {
        self.summary = summary
        self.findings = findings
    }

    init?(_ value: MultiplayerJSON?) {
        guard let value else { return nil }
        // A worker that didn't answer in JSON leaves its raw answer as the summary.
        let summary = value.firstText("summary") ?? value.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else { return nil }
        self.summary = summary
        findings = (value["findings"]?.items ?? []).enumerated().compactMap { index, row in
            guard let text = row.firstText("text") else { return nil }
            return MultiplayerFinding(id: index, file: row.firstText("file") ?? "", line: max(row["line"]?.int ?? 0, 0),
                                      severity: row.firstText("severity") ?? "nit",
                                      text: MultiplayerText.clean(text, limit: 600, redact: true))
        }
    }

    var important: Int { findings.filter(\.isImportant).count }

    /// "2 important, 1 nit", in the order a reader acts on them.
    var tally: String {
        let nits = findings.count - important
        if findings.isEmpty { return "No findings" }
        return [important > 0 ? "\(important) important" : nil, nits > 0 ? (nits == 1 ? "1 nit" : "\(nits) nits") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

struct MultiplayerReviewDraft: Equatable {
    var title = ""
    var pr = ""
    var diff: MultiplayerContextItem? = nil
    var instructions = ""

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedPR: String { pr.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedInstructions: String { instructions.trimmingCharacters(in: .whitespacesAndNewlines) }

    var problem: String? {
        if trimmedTitle.count > 200 { return "Keep the title under 200 characters." }
        if !trimmedPR.isEmpty, !MultiplayerReviewDraft.isPullRequest(trimmedPR) { return "A pull request URL starts with https://." }
        if let diff, diff.bytes > MultiplayerContextBundle.byteLimit {
            return "The diff is \(MultiplayerContextBundle.size(diff.bytes)). A review takes up to 96 KiB."
        }
        if trimmedInstructions.count > 4000 { return "Keep the instructions under 4,000 characters." }
        return nil
    }

    var canSend: Bool { !trimmedTitle.isEmpty && (diff != nil || !trimmedPR.isEmpty) && problem == nil }

    var payload: MultiplayerJSON {
        var fields: [String: MultiplayerJSON] = ["title": .string(trimmedTitle)]
        if let diff { fields["diff"] = .string(diff.content) }
        if !trimmedPR.isEmpty { fields["pr"] = .string(trimmedPR) }
        if !trimmedInstructions.isEmpty { fields["instructions"] = .string(trimmedInstructions) }
        return .object(fields)
    }

    static func isPullRequest(_ text: String) -> Bool {
        guard text.hasPrefix("https://"), let url = URL(string: text), let host = url.host else { return false }
        return !host.isEmpty && !text.contains(where: \.isWhitespace)
    }
}

// MARK: - Fan-out

/// One target's part of a fan-out.
struct MultiplayerFanoutChild: Equatable, Sendable, Identifiable {
    /// The child request's ID. Names it for `thread`.
    let id: String
    let resource: String
    let action: String
    var status: String
    var value: MultiplayerJSON?

    init(id: String, resource: String, action: String = MultiplayerSharePolicy.ask, status: String = "", value: MultiplayerJSON? = nil) {
        self.id = id
        self.resource = resource
        self.action = action
        self.status = status
        self.value = value
    }

    init?(_ json: MultiplayerJSON) {
        guard let resource = json.firstText("resource") else { return nil }
        self.resource = resource
        id = json.firstText("id", "child") ?? resource
        action = json.firstText("action") ?? MultiplayerSharePolicy.ask
        status = json.firstText("status") ?? ""
        value = json.outcome
    }

    var succeeded: Bool { ["ok", "done", "completed", "succeeded", "success"].contains(status.lowercased()) }
    var isSettled: Bool { MultiplayerRequestState.isSettled(status) }

    /// The target's answer, safe to draw.
    var answer: String { value?.readable ?? "" }
}

/// One payload sent to several targets, and what each sent back.
struct MultiplayerFanout: Equatable, Sendable, Identifiable {
    let request: String
    var title: String
    var at: Date?
    var children: [MultiplayerFanoutChild]

    var id: String { request }

    init(request: String, title: String = "", at: Date? = nil, children: [MultiplayerFanoutChild] = []) {
        self.request = request
        self.title = title
        self.at = at
        self.children = children
    }

    /// The reply to `fanout`, or a row of `sent` that carries its children.
    init?(_ json: MultiplayerJSON) {
        guard let request = json.firstText("request") else { return nil }
        self.request = request
        title = json.firstText("title") ?? ""
        at = json["at"]?.text.flatMap(MultiplayerTime.parse)
        children = Self.children(json)
    }

    /// `children` is the list itself, or the submission that holds it.
    static func children(_ json: MultiplayerJSON) -> [MultiplayerFanoutChild] {
        guard let listed = json["children"] else { return [] }
        let rows = listed.items.isEmpty ? (listed["children"]?.items ?? []) : listed.items
        return MultiplayerUnique.keep(rows.compactMap(MultiplayerFanoutChild.init)) { $0.id }
    }

    var answered: Int { children.filter(\.isSettled).count }
    var isSettled: Bool { !children.isEmpty && answered == children.count }

    /// "2 of 3 answered".
    var progress: String { "\(answered) of \(children.count) answered" }
}

struct MultiplayerFanoutDraft: Equatable {
    static let targetRange = 2...32

    var targets: Set<String> = []
    var prompt = ""

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var problem: String? {
        if targets.count > Self.targetRange.upperBound { return "A fan-out takes at most 32 targets." }
        if prompt.utf8.count > MultiplayerContextBundle.byteLimit { return "The prompt is too long to send." }
        return nil
    }

    var canSend: Bool { Self.targetRange.contains(targets.count) && !trimmedPrompt.isEmpty && problem == nil }

    var payload: MultiplayerJSON { .object(["text": .string(trimmedPrompt)]) }

    var title: String { MultiplayerText.clean(trimmedPrompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "", limit: 80) }
}

/// The winner the person chose for each fan-out. Kept on this Mac only, in Commander's own folder:
/// one JSON file holding a `multiplayer.fanout.winners` dictionary keyed by server and request.
/// It never touches the app's preferences, so a fixture or debug run can't write into the live app's.
struct MultiplayerWinnerStore: Sendable {
    static let key = "multiplayer.fanout.winners"
    static let limit = 200

    let file: URL

    /// "s-home/rq-1": a request ID is only unique on its own server.
    static func key(_ request: String, on server: String) -> String { "\(server)/\(request)" }

    /// Where the live app keeps it: under AGENT_COMMANDER_HOME, or Application Support. A fixture
    /// run with no home of its own writes to the temporary folder instead.
    static func location(isFixture: Bool, environment: [String: String] = ProcessInfo.processInfo.environment,
                         support: URL = FileManager.default.homeDirectoryForCurrentUser
                            .appending(path: "Library/Application Support/Agent Commander"),
                         temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        if let home = environment["AGENT_COMMANDER_HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory).appending(path: "network/fanout-winners.json")
        }
        return (isFixture ? temporary.appending(path: "agent-commander-fixture") : support)
            .appending(path: "network/fanout-winners.json")
    }

    /// A store nothing else reads: the default for a model built outside the app.
    static func scratch() -> MultiplayerWinnerStore {
        MultiplayerWinnerStore(file: FileManager.default.temporaryDirectory
            .appending(path: "agent-commander-scratch/fanout-winners-\(UUID().uuidString).json"))
    }

    var all: [String: String] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return root[Self.key] ?? [:]
    }

    func winner(of request: String, on server: String) -> String? { all[Self.key(request, on: server)] }

    /// Records the child chosen for a fan-out, or clears the choice.
    func choose(_ child: String?, for request: String, on server: String) {
        var winners = all
        winners[Self.key(request, on: server)] = child
        // Old choices leave first, so the file stays small.
        if winners.count > Self.limit { winners.keys.sorted().prefix(winners.count - Self.limit).forEach { winners[$0] = nil } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode([Self.key: winners]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Helper calls

extension MultiplayerClient {
    /// Reads a watched worker's output after a cursor. The device agent waits up to 8 seconds.
    func watch(resource: String, after cursor: String) async throws -> MultiplayerWatchReply {
        MultiplayerWatchReply(try await fetch(.watch, ["resource": .string(resource), "after": .string(cursor)],
                                              as: MultiplayerJSON.self))
    }

    func handovers() async throws -> [MultiplayerHandover] {
        let reply = try await fetch(.handovers, [:], as: MultiplayerJSON.self)
        return MultiplayerUnique.keep((reply["handovers"]?.items ?? []).compactMap(MultiplayerHandover.init)) { $0.id }
    }

    /// Hands control of a worker to a friend. The device agent names the friend by `handle`.
    func handover(resource: String, handle: String, minutes: Int) async throws -> MultiplayerHandover? {
        let reply = try await fetch(.handover, ["resource": .string(resource), "handle": .string(handle), "minutes": .number(minutes)],
                                    as: MultiplayerJSON.self, allowsEmpty: true)
        guard var handover = reply.flatMap(MultiplayerHandover.init) else { return nil }
        handover.minutes = minutes
        return handover
    }

    /// Takes control back. `holder` is the friend's handle or the account `handovers` listed;
    /// the device agent takes either under `handle`.
    func handback(resource: String, holder: String) async throws {
        _ = try await fetch(.handback, ["resource": .string(resource), "handle": .string(holder)], as: MultiplayerIgnored.self,
                            allowsEmpty: true)
    }

    /// Every request this device sent, newest first, as plain rows.
    func sentRows() async throws -> [MultiplayerJSON] {
        try await fetch(.sent, [:], as: MultiplayerJSON.self)["sent"]?.items ?? []
    }

    /// Sends one payload to every target.
    func fanout(targets: [(resource: String, action: String)], payload: MultiplayerJSON, name: String) async throws -> MultiplayerFanout {
        let list = MultiplayerJSON.array(targets.map { .object(["resource": .string($0.resource), "action": .string($0.action)]) })
        var fields: [String: MultiplayerPayloadValue] = ["targets": .json(list), "payload": .json(payload)]
        if !name.isEmpty { fields["name"] = .string(name) }
        guard var fanout = MultiplayerFanout(try await fetch(.fanout, fields, as: MultiplayerJSON.self)) else {
            throw MultiplayerFailure.invalidResponse
        }
        if fanout.title.isEmpty { fanout.title = name }
        // The device agent may answer before it lists each child; the targets are still what was sent.
        if fanout.children.isEmpty {
            fanout.children = targets.map { MultiplayerFanoutChild(id: $0.resource, resource: $0.resource, action: $0.action, status: "pending") }
        }
        return fanout
    }

    /// Posts a review's findings to a pull request as a review comment, through `gh` on this Mac.
    func postReview(request: String, pr: String) async throws {
        _ = try await fetch(.reviewPost, ["request": .string(request), "pr": .string(pr)], as: MultiplayerIgnored.self,
                            allowsEmpty: true)
    }
}
