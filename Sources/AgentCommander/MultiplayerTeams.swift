import Foundation

// MULTIPLAYER CONTRACT: teams (design/COMMANDER-NETWORK-INCREMENT-5.md).
// Groups, shared workspaces with claims, the task board, the merge queue, lent hosts, the knowledge
// library, reputation, the directory search and the relay's admin policy. Relay routes are reached
// through the device verb `relay`; the merge queue and knowledge install are device verbs.
// Values only; MultiplayerTeamsModel calls the helper. Every reply is read from plain JSON,
// leniently: a row this build can't read is dropped rather than failing the page.

extension MultiplayerJSON {
    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var strings: [String] { items.compactMap(\.text) }

    func date(_ key: String) -> Date? {
        self[key]?.text.flatMap(MultiplayerTime.parse).flatMap { $0.timeIntervalSince1970 < 0 ? nil : $0 }
    }

    /// A typed value read back out of plain JSON.
    func decoded<Value: Decodable>(as type: Value.Type) -> Value? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension MultiplayerText {
    /// Output read closely: each line made safe to draw, with its line breaks kept and credentials
    /// replaced. The end is kept when it is too long, since that is where a run says how it went.
    static func cleanLines(_ text: String, limit: Int) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { clean(String($0), limit: 400, redact: true) }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count > limit ? "…" + joined.suffix(limit - 1) : joined
    }
}

// MARK: - Groups

/// A named group of friends on one server. Only its owner changes it.
struct MultiplayerGroup: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// The owner's handle.
    let owner: String
    /// Members' handles, the owner among them.
    let members: [String]

    init(id: String, name: String, owner: String = "", members: [String] = []) {
        self.id = id
        self.name = name
        self.owner = owner
        self.members = members
    }

    init?(_ json: MultiplayerJSON) {
        guard let id = json.firstText("id") else { return nil }
        self.init(id: id, name: json.firstText("name") ?? id, owner: json.firstText("ownerHandle", "owner") ?? "",
                  members: MultiplayerUnique.keep(json["members"]?.strings ?? []) { $0 })
    }

    func isOwned(by handle: String) -> Bool { !handle.isEmpty && owner == handle }

    /// "3 members", counting the owner.
    var memberTitle: String { members.count == 1 ? "1 member" : "\(members.count) members" }
}

// MARK: - Workspaces

/// A live claim on part of a workspace: an issue, a set of paths or a card.
struct MultiplayerClaim: Equatable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Sendable, Identifiable {
        case issue, paths, card

        var id: String { rawValue }

        var title: String {
            switch self {
            case .issue: "Issue"
            case .paths: "Paths"
            case .card: "Card"
            }
        }

        var symbol: String {
            switch self {
            case .issue: "number"
            case .paths: "folder"
            case .card: "rectangle.on.rectangle"
            }
        }

        var keyLabel: String {
            switch self {
            case .issue: "Issue"
            case .paths: "Paths"
            case .card: "Card"
            }
        }

        var keyPlaceholder: String {
            switch self {
            case .issue: "#212"
            case .paths: "Sources/Relay, Tests/Relay"
            case .card: "card ID"
            }
        }
    }

    let id: String
    let kind: String
    let key: String
    /// "<handle>/<agent>".
    let holder: String
    let expiresAt: Date?

    init(id: String, kind: String, key: String, holder: String, expiresAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.key = key
        self.holder = holder
        self.expiresAt = expiresAt
    }

    init?(_ json: MultiplayerJSON) {
        guard let id = json.firstText("id"), let key = json.firstText("key") else { return nil }
        self.init(id: id, kind: json.firstText("kind") ?? "", key: key, holder: json.firstText("holder") ?? "",
                  expiresAt: json.date("expiresAt"))
    }

    var holderHandle: String { holder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? holder }
    var holderAgent: String { holder.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }

    func isHeld(by handle: String) -> Bool { !handle.isEmpty && holderHandle == handle }

    var symbol: String { Kind(rawValue: kind)?.symbol ?? "lock" }
    var kindTitle: String { Kind(rawValue: kind)?.title ?? kind.multiplayerDisplay }
}

enum MultiplayerIntegration: String, CaseIterable, Sendable, Identifiable {
    case queue
    case pullRequest = "pull_request"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: "Merge queue"
        case .pullRequest: "Pull requests"
        }
    }

    var explanation: String {
        switch self {
        case .queue: "Contributors push branches to the owner’s Mac. The owner’s Mac tests each one and merges them in order."
        case .pullRequest: "Contributors open pull requests themselves. Commander links to them here."
        }
    }

    static func title(for raw: String) -> String { Self(rawValue: raw)?.title ?? raw.multiplayerDisplay }
}

/// A goal, a repository, a base branch and a member group, on one server. The relay keeps only this
/// metadata; code never crosses it.
struct MultiplayerWorkspace: Equatable, Sendable, Identifiable {
    let id: String
    /// The owner's account on the relay.
    let owner: String
    let group: String
    let name: String
    let goal: String
    let repository: String
    let base: String
    let integration: String
    let claims: [MultiplayerClaim]

    init(id: String, owner: String = "", group: String = "", name: String, goal: String = "", repository: String = "",
         base: String = "", integration: String = "", claims: [MultiplayerClaim] = []) {
        self.id = id
        self.owner = owner
        self.group = group
        self.name = name
        self.goal = goal
        self.repository = repository
        self.base = base
        self.integration = integration
        self.claims = claims
    }

    init?(_ json: MultiplayerJSON) {
        guard let id = json.firstText("id") else { return nil }
        self.init(id: id, owner: json.firstText("owner") ?? "", group: json.firstText("group") ?? "",
                  name: json.firstText("name") ?? id, goal: json.firstText("goal") ?? "",
                  repository: json.firstText("repository") ?? "", base: json.firstText("base") ?? "",
                  integration: json.firstText("integration") ?? "",
                  claims: (json["claims"]?.items ?? []).compactMap(MultiplayerClaim.init))
    }

    var usesQueue: Bool { integration == MultiplayerIntegration.queue.rawValue }

    /// Where the repository's pull requests are, when the repository names a GitHub project.
    var pullRequestsURL: URL? {
        var text = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasPrefix("git@github.com:") { text = "https://github.com/" + text.dropFirst("git@github.com:".count) }
        if text.hasPrefix("github.com/") { text = "https://" + text }
        if !text.contains("://"), !text.hasPrefix("/"), text.split(separator: "/").count == 2, !text.contains(" ") {
            text = "https://github.com/" + text
        }
        guard let url = URL(string: text), url.scheme == "https", url.host == "github.com",
              url.pathComponents.filter({ $0 != "/" }).count == 2 else { return nil }
        return url.appendingPathComponent("pulls")
    }
}

/// One card of a workspace's board.
struct MultiplayerCard: Equatable, Sendable, Identifiable {
    enum State: String, CaseIterable, Sendable {
        case open, claimed, done

        var title: String {
            switch self {
            case .open: "Open"
            case .claimed: "Claimed"
            case .done: "Done"
            }
        }

        var lamp: MultiplayerLamp.Kind {
            switch self {
            case .open: .off
            case .claimed: .busy
            case .done: .on
            }
        }

        var tone: Tone {
            switch self {
            case .open: .neutral
            case .claimed: .attention
            case .done: .working
            }
        }
    }

    let id: String
    let title: String
    let body: String
    let state: String
    /// "<handle>/<agent>" while claimed, or whoever it was assigned to.
    let assignee: String
    let result: String

    init(id: String, title: String, body: String = "", state: String = "open", assignee: String = "", result: String = "") {
        self.id = id
        self.title = title
        self.body = body
        self.state = state
        self.assignee = assignee
        self.result = result
    }

    init?(_ json: MultiplayerJSON) {
        guard let id = json.firstText("id") else { return nil }
        self.init(id: id, title: json.firstText("title") ?? id, body: json["body"]?.text ?? "",
                  state: json.firstText("state") ?? "open", assignee: json.firstText("assignee") ?? "",
                  result: json["result"]?.text ?? "")
    }

    var known: State { State(rawValue: state) ?? .open }

    func isAssigned(to handle: String) -> Bool {
        !handle.isEmpty && assignee.split(separator: "/", maxSplits: 1).first.map(String.init) == handle
    }
}

/// One branch waiting in, or through, the owner's merge queue. The queue lives on the owner's Mac.
struct MultiplayerQueueEntry: Equatable, Sendable, Identifiable {
    let workspace: String
    let branch: String
    let checkout: String
    let test: [String]
    let added: Date?
    /// `queued`, `merged`, `conflict` or `failed`.
    let state: String
    let output: String

    var id: String { "\(workspace)/\(branch)/\(added?.timeIntervalSince1970 ?? 0)" }

    init(workspace: String, branch: String, checkout: String = "", test: [String] = [], added: Date? = nil,
         state: String = "queued", output: String = "") {
        self.workspace = workspace
        self.branch = branch
        self.checkout = checkout
        self.test = test
        self.added = added
        self.state = state
        self.output = output
    }

    init?(_ json: MultiplayerJSON) {
        guard let workspace = json.firstText("workspace"), let branch = json.firstText("branch") else { return nil }
        self.init(workspace: workspace, branch: branch, checkout: json.firstText("checkout") ?? "",
                  test: json["test"]?.strings ?? [], added: json.date("added"), state: json.firstText("state") ?? "queued",
                  output: MultiplayerText.cleanLines(json["output"]?.text ?? "", limit: 8192))
    }

    var isQueued: Bool { state == "queued" }

    var stateTitle: String {
        switch state {
        case "queued": "Queued"
        case "merged": "Merged"
        case "conflict": "Conflict"
        case "failed": "Tests failed"
        default: state.multiplayerDisplay
        }
    }

    var lamp: MultiplayerLamp.Kind {
        switch state {
        case "queued": .waiting
        case "merged": .on
        case "conflict", "failed": .error
        default: .unknown
        }
    }

    var tone: Tone {
        switch state {
        case "queued": .focus
        case "merged": .working
        case "conflict", "failed": .failure
        default: .neutral
        }
    }
}

/// A count with its noun: "1 claim", "3 claims". Used for what is drawn and what is spoken.
enum MultiplayerPlural {
    static func count(_ number: Int, _ one: String, _ many: String? = nil) -> String {
        "\(number) \(number == 1 ? one : many ?? one + "s")"
    }
}

// MARK: - Hosts

extension MultiplayerDirectoryEntry {
    var isHost: Bool { kind == MultiplayerResourceKind.host.rawValue }
    var canRunOnHost: Bool { granted.contains(MultiplayerSharePolicy.hostRun) }
}

/// What one `host.run` brought back: the exit code and the end of the output.
struct MultiplayerHostRun: Equatable, Sendable {
    let command: String
    let exitCode: Int
    let output: String
    let seconds: Int

    init(command: String, exitCode: Int, output: String = "", seconds: Int = 0) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
        self.seconds = seconds
    }

    init?(_ json: MultiplayerJSON?) {
        guard let json, let code = json["exitCode"]?.int else { return nil }
        self.init(command: json.firstText("command") ?? "", exitCode: code,
                  output: MultiplayerText.cleanLines(json["output"]?.text ?? "", limit: 64 * 1024),
                  seconds: json["seconds"]?.int ?? 0)
    }

    var succeeded: Bool { exitCode == 0 }

    /// The exit state and the time it took, as one readout: "Exit 1, 41 seconds".
    var spoken: String { "Exit \(exitCode), \(MultiplayerPlural.count(seconds, "second"))" }
}

/// One run of an enrolled command on a friend's host.
struct MultiplayerHostRunDraft: Equatable {
    var command = ""
    /// Extra arguments as typed, split on spaces. Sent only when the owner's command allows them.
    var argumentText = ""

    var arguments: [String] { argumentText.split(whereSeparator: \.isWhitespace).map(String.init) }

    var canSend: Bool { !command.trimmingCharacters(in: .whitespaces).isEmpty && arguments.count <= 32 }

    var payload: MultiplayerJSON { payload(allowingArguments: true) }

    /// What is sent. Extra arguments are left out for a command the host says takes none.
    func payload(allowingArguments: Bool) -> MultiplayerJSON {
        var fields: [String: MultiplayerJSON] = ["command": .string(command.trimmingCharacters(in: .whitespaces))]
        if allowingArguments, !arguments.isEmpty { fields["args"] = .array(arguments.map(MultiplayerJSON.string)) }
        return .object(fields)
    }
}

// MARK: - Knowledge

enum MultiplayerKnowledgeKind: String, CaseIterable, Sendable, Identifiable {
    case prompt, skill, instructions, mcp, summary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prompt: "Prompt"
        case .skill: "Skill"
        case .instructions: "Instructions"
        case .mcp: "MCP"
        case .summary: "Summary"
        }
    }

    var symbol: String {
        switch self {
        case .prompt: "text.quote"
        case .skill: "wand.and.stars"
        case .instructions: "list.bullet.rectangle"
        case .mcp: "puzzlepiece.extension"
        case .summary: "doc.plaintext"
        }
    }

    /// What Install does with an item of this kind.
    var installTitle: String {
        switch self {
        case .skill: "Install skill"
        case .mcp: "Save to file…"
        case .prompt, .instructions, .summary: "Copy"
        }
    }

    var installNote: String {
        switch self {
        case .skill: "Writes ~/.claude/skills/<name>/SKILL.md on this Mac."
        case .mcp: "Saves the configuration to a file you choose."
        case .prompt, .instructions, .summary: "Copies the text. Nothing is written to disk."
        }
    }

    static func title(for raw: String) -> String { Self(rawValue: raw)?.title ?? raw.multiplayerDisplay }
    static func symbol(for raw: String) -> String { Self(rawValue: raw)?.symbol ?? "doc" }
}

/// Who can see a knowledge item, or a relay-wide limit on that.
enum MultiplayerKnowledgeScope: String, CaseIterable, Sendable, Identifiable {
    case `private`, friend, group, server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .private: "Private"
        case .friend: "Friend"
        case .group: "Group"
        case .server: "Server"
        }
    }

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// "friend:sam" reads as (.friend, "sam").
    static func parse(_ visibility: String) -> (scope: MultiplayerKnowledgeScope, target: String)? {
        let parts = visibility.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let scope = Self(rawValue: first) else { return nil }
        return (scope, parts.count > 1 ? parts[1] : "")
    }

    /// "Friend sam", "Group relay-team", "Everyone on this server", "Only you".
    static func describe(_ visibility: String, groupName: (String) -> String? = { _ in nil }) -> String {
        guard let (scope, target) = parse(visibility) else { return visibility.multiplayerDisplay }
        switch scope {
        case .private: return "Only you"
        case .friend: return target.isEmpty ? "A friend" : "Friend \(target.multiplayerDisplay)"
        case .group: return "Group \((groupName(target) ?? target).multiplayerDisplay)"
        case .server: return "Everyone on this server"
        }
    }
}

/// A prompt, skill, instructions snippet, MCP configuration or summary kept by the relay.
struct MultiplayerKnowledgeItem: Equatable, Sendable, Identifiable {
    let id: String
    /// The owner's account on the relay.
    let owner: String
    let kind: String
    let name: String
    let content: String
    let visibility: String
    let version: Int
    let createdAt: Date?

    init(id: String, owner: String = "", kind: String, name: String, content: String = "", visibility: String = "private",
         version: Int = 1, createdAt: Date? = nil) {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.name = name
        self.content = content
        self.visibility = visibility
        self.version = version
        self.createdAt = createdAt
    }

    init?(_ json: MultiplayerJSON) {
        guard let id = json.firstText("id") else { return nil }
        self.init(id: id, owner: json.firstText("owner") ?? "", kind: json.firstText("kind") ?? "",
                  name: json.firstText("name") ?? id, content: json["content"]?.text ?? "",
                  visibility: json.firstText("visibility") ?? "private", version: json["version"]?.int ?? 1,
                  createdAt: json.date("createdAt"))
    }

    /// What `knowledge-install` takes.
    var installItem: MultiplayerJSON {
        .object(["kind": .string(kind), "name": .string(name), "content": .string(content)])
    }

    /// The `${NAME}` placeholders the content leaves for the person who installs it.
    var placeholders: [String] { MultiplayerSecretCheck.placeholders(in: content) }
}

/// The device refuses to share content that seems to carry a credential. The same patterns are
/// checked here first, so the form can say so before anything is sent.
enum MultiplayerSecretCheck {
    static let refusal = "This item seems to contain a secret. Replace the value with a ${NAME} placeholder, then share it."

    private static let pattern = try? NSRegularExpression(
        pattern: #"(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9-]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*["']?[^\s"'${}]{6,})"#,
        options: [.caseInsensitive])

    static func looksSecret(_ content: String) -> Bool {
        guard let pattern else { return false }
        return pattern.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
    }

    /// Whether a refusal the device sent back is this one.
    static func isRefusal(_ message: String) -> Bool { message.localizedCaseInsensitiveContains("seems to contain a secret") }

    static func placeholders(in content: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#) else { return [] }
        let found = expression.matches(in: content, range: NSRange(content.startIndex..., in: content)).compactMap { match in
            Range(match.range(at: 1), in: content).map { String(content[$0]) }
        }
        return MultiplayerUnique.keep(found) { $0 }
    }
}

struct MultiplayerKnowledgeDraft: Equatable {
    static let nameLimit = 256
    /// The helper's input bound leaves about this much for content.
    static let contentLimit = 12 * 1024

    /// The item a new version is for; empty for a new item.
    var editing = ""
    var kind = MultiplayerKnowledgeKind.prompt
    var name = ""
    var content = ""
    var scope = MultiplayerKnowledgeScope.private
    /// A friend's handle or a group's ID, for those scopes.
    var target = ""

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var visibility: String {
        switch scope {
        case .private, .server: scope.rawValue
        case .friend, .group: "\(scope.rawValue):\(target)"
        }
    }

    var secretProblem: String? { MultiplayerSecretCheck.looksSecret(content) ? MultiplayerSecretCheck.refusal : nil }

    var contentProblem: String? {
        if let secretProblem { return secretProblem }
        if content.utf8.count > Self.contentLimit { return "Keep the content under 12 KB." }
        return nil
    }

    var nameProblem: String? { trimmedName.count > Self.nameLimit ? "Keep the name under 256 characters." : nil }

    var canSend: Bool {
        !trimmedName.isEmpty && nameProblem == nil && contentProblem == nil
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (scope == .private || scope == .server || !target.isEmpty)
    }

    var body: MultiplayerJSON {
        .object(["kind": .string(kind.rawValue), "name": .string(trimmedName), "content": .string(content),
                 "visibility": .string(visibility)])
    }
}

// MARK: - Reputation and directory

struct MultiplayerEndorsement: Decodable, Equatable, Sendable, Identifiable {
    let handle: String
    let skill: String

    var id: String { "\(handle)/\(skill)" }

    init(handle: String, skill: String) {
        self.handle = handle
        self.skill = skill
    }

    init?(_ json: MultiplayerJSON) {
        guard let skill = json.firstText("skill") else { return nil }
        self.init(handle: json.firstText("handle") ?? "", skill: skill)
    }

    /// Skills with how many people vouched for each, most vouched first.
    static func tally(_ endorsements: [MultiplayerEndorsement]) -> [(skill: String, count: Int)] {
        var counts: [String: Int] = [:], order: [String] = []
        for endorsement in endorsements {
            if counts[endorsement.skill] == nil { order.append(endorsement.skill) }
            counts[endorsement.skill, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }.sorted { $0.count > $1.count }
    }
}

/// How a resource's finished requests went, as the people who sent them reported.
struct MultiplayerReputation: Equatable, Sendable {
    let resource: String
    let completed: Int
    let accepted: Int
    let rejected: Int
    let medianSeconds: Double?

    init(resource: String, completed: Int = 0, accepted: Int = 0, rejected: Int = 0, medianSeconds: Double? = nil) {
        self.resource = resource
        self.completed = completed
        self.accepted = accepted
        self.rejected = rejected
        self.medianSeconds = medianSeconds
    }

    init(_ json: MultiplayerJSON) {
        self.init(resource: json.firstText("resource") ?? "", completed: json["completed"]?.int ?? 0,
                  accepted: json["accepted"]?.int ?? 0, rejected: json["rejected"]?.int ?? 0,
                  medianSeconds: json["medianSeconds"]?.double)
    }

    /// "42 s", "3 min", "1.5 h"; a dash when nothing has finished.
    var medianTitle: String {
        guard let seconds = medianSeconds, seconds >= 0 else { return "–" }
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        return "\((seconds / 3600).formatted(.number.precision(.fractionLength(1)))) h"
    }

    /// Of the results people judged, the share they accepted.
    var acceptedPercent: Int? {
        let judged = accepted + rejected
        return judged > 0 ? Int((Double(accepted) / Double(judged) * 100).rounded()) : nil
    }
}

/// A resource its owner chose to list, found by the directory search.
struct MultiplayerDirectoryHit: Equatable, Sendable, Identifiable {
    let id: String
    let handle: String
    let name: String
    let kind: String
    let actions: [String]
    let capabilities: MultiplayerCapabilities?
    let endorsements: [MultiplayerEndorsement]

    init(id: String, handle: String, name: String, kind: String, actions: [String] = [],
         capabilities: MultiplayerCapabilities? = nil, endorsements: [MultiplayerEndorsement] = []) {
        self.id = id
        self.handle = handle
        self.name = name
        self.kind = kind
        self.actions = actions
        self.capabilities = capabilities
        self.endorsements = endorsements
    }

    init?(_ json: MultiplayerJSON) {
        guard let id = json.firstText("id") else { return nil }
        let capabilities = json["capabilities"]?.decoded(as: MultiplayerCapabilities.self)
        self.init(id: id, handle: json.firstText("handle") ?? "", name: json.firstText("name") ?? id,
                  kind: json.firstText("kind") ?? "", actions: json["actions"]?.strings ?? [],
                  capabilities: capabilities.flatMap { $0.isEmpty ? nil : $0 },
                  endorsements: (json["endorsements"]?.items ?? []).compactMap(MultiplayerEndorsement.init))
    }
}

struct MultiplayerDirectorySearch: Equatable, Sendable {
    var query = ""
    var handles: [String] = []
    var resources: [MultiplayerDirectoryHit] = []

    var isEmpty: Bool { handles.isEmpty && resources.isEmpty }
}

// MARK: - Relay policy

enum MultiplayerReputationVisibility: String, CaseIterable, Sendable, Identifiable {
    case owner, users, friends, server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .owner: "Owner"
        case .users: "Users"
        case .friends: "Friends"
        case .server: "Server"
        }
    }

    var explanation: String {
        switch self {
        case .owner: "Only a resource’s owner sees its reputation."
        case .users: "The owner and the people who have used the resource see it."
        case .friends: "The owner and the owner’s friends see it."
        case .server: "Everyone on this relay sees it."
        }
    }
}

/// The relay's admin policy.
struct MultiplayerRelayPolicy: Equatable, Sendable {
    var knowledgeDefault = "private"
    var knowledgeWidest = "server"
    var reputationVisibility = "friends"
    var directory = false
    var maxGrantDays = 0
    var maxBudgetTokens = 0
    var retentionDays = 30

    init() {}

    init?(_ json: MultiplayerJSON) {
        guard case .object = json, let widest = json.firstText("knowledgeWidest") else { return nil }
        knowledgeWidest = widest
        knowledgeDefault = json.firstText("knowledgeDefault") ?? "private"
        reputationVisibility = json.firstText("reputationVisibility") ?? "owner"
        directory = json["directory"]?.bool ?? (json["directory"]?.text == "on")
        maxGrantDays = json["maxGrantDays"]?.int ?? 0
        maxBudgetTokens = json["maxBudgetTokens"]?.int ?? 0
        retentionDays = json["retentionDays"]?.int ?? 30
    }
}

/// The policy editor. Number fields are kept as typed so a half-typed value isn't lost.
struct MultiplayerPolicyDraft: Equatable {
    var knowledgeDefault = MultiplayerKnowledgeScope.private
    var knowledgeWidest = MultiplayerKnowledgeScope.server
    var reputationVisibility = MultiplayerReputationVisibility.friends
    var directory = false
    var maxGrantDays = "0"
    var maxBudgetTokens = "0"
    var retentionDays = "30"
    /// A member to suspend or restore, and a device to revoke.
    var member = ""
    var device = ""

    init() {}

    init(_ policy: MultiplayerRelayPolicy) {
        knowledgeDefault = MultiplayerKnowledgeScope(rawValue: policy.knowledgeDefault) ?? .private
        knowledgeWidest = MultiplayerKnowledgeScope(rawValue: policy.knowledgeWidest) ?? .server
        reputationVisibility = MultiplayerReputationVisibility(rawValue: policy.reputationVisibility) ?? .owner
        directory = policy.directory
        maxGrantDays = String(policy.maxGrantDays)
        maxBudgetTokens = String(policy.maxBudgetTokens)
        retentionDays = String(policy.retentionDays)
    }

    private static func whole(_ text: String, atLeast floor: Int, atMost ceiling: Int) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).filter { $0 != "," && $0 != "_" }
        guard !digits.isEmpty, digits.count <= 12, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits),
              value >= floor, value <= ceiling else { return nil }
        return value
    }

    var grantDays: Int? { Self.whole(maxGrantDays, atLeast: 0, atMost: 3650) }
    var budgetTokens: Int? { Self.whole(maxBudgetTokens, atLeast: 0, atMost: 1_000_000_000_000) }
    var retention: Int? { Self.whole(retentionDays, atLeast: 1, atMost: 3650) }

    var scopeProblem: String? {
        knowledgeDefault.rank > knowledgeWidest.rank ? "The default can’t be wider than the widest scope allowed." : nil
    }

    var grantDaysProblem: String? { grantDays == nil ? "Use a whole number of days. 0 means no limit." : nil }
    var budgetProblem: String? { budgetTokens == nil ? "Use a whole number of tokens. 0 means no limit." : nil }
    var retentionProblem: String? { retention == nil ? "Use a whole number of days, at least 1." : nil }

    /// The policy as edited; nil while a field can't be read.
    var policy: MultiplayerRelayPolicy? {
        guard scopeProblem == nil, let grantDays, let budgetTokens, let retention else { return nil }
        var policy = MultiplayerRelayPolicy()
        policy.knowledgeDefault = knowledgeDefault.rawValue
        policy.knowledgeWidest = knowledgeWidest.rawValue
        policy.reputationVisibility = reputationVisibility.rawValue
        policy.directory = directory
        policy.maxGrantDays = grantDays
        policy.maxBudgetTokens = budgetTokens
        policy.retentionDays = retention
        return policy
    }

    /// Only the settings that differ from `saved`: the relay applies a partial edit.
    func changes(from saved: MultiplayerRelayPolicy) -> [String: MultiplayerJSON]? {
        guard let next = policy else { return nil }
        var fields: [String: MultiplayerJSON] = [:]
        if next.knowledgeDefault != saved.knowledgeDefault { fields["knowledgeDefault"] = .string(next.knowledgeDefault) }
        if next.knowledgeWidest != saved.knowledgeWidest { fields["knowledgeWidest"] = .string(next.knowledgeWidest) }
        if next.reputationVisibility != saved.reputationVisibility { fields["reputationVisibility"] = .string(next.reputationVisibility) }
        if next.directory != saved.directory { fields["directory"] = .bool(next.directory) }
        if next.maxGrantDays != saved.maxGrantDays { fields["maxGrantDays"] = .number(Double(next.maxGrantDays)) }
        if next.maxBudgetTokens != saved.maxBudgetTokens { fields["maxBudgetTokens"] = .number(Double(next.maxBudgetTokens)) }
        if next.retentionDays != saved.retentionDays { fields["retentionDays"] = .number(Double(next.retentionDays)) }
        return fields
    }

    var trimmedMember: String { member.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var trimmedDevice: String { device.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Drafts

struct MultiplayerWorkspaceDraft: Equatable {
    var name = ""
    var goal = ""
    var repository = ""
    var base = "main"
    var group = ""
    var integration = MultiplayerIntegration.queue

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSend: Bool {
        ![name, goal, repository, base, group].contains { trimmed($0).isEmpty }
    }

    /// What is still missing, in one line.
    var hint: String? {
        if group.isEmpty { return "Choose the group that works in it." }
        if trimmed(name).isEmpty { return "Give it a name." }
        if trimmed(goal).isEmpty { return "Say what it is for." }
        if trimmed(repository).isEmpty { return "Name the repository." }
        if trimmed(base).isEmpty { return "Name the base branch." }
        return nil
    }

    var body: MultiplayerJSON {
        .object(["name": .string(trimmed(name)), "goal": .string(trimmed(goal)), "repository": .string(trimmed(repository)),
                 "base": .string(trimmed(base)), "group": .string(group), "integration": .string(integration.rawValue)])
    }
}

struct MultiplayerClaimDraft: Equatable {
    var kind = MultiplayerClaim.Kind.issue
    var key = ""
    /// The agent that will do the work. The holder is "<your handle>/<agent>".
    var agent = ""

    var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAgent: String { agent.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func isAgentName(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil
    }

    var agentProblem: String? {
        trimmedAgent.isEmpty || Self.isAgentName(trimmedAgent) ? nil : "Use letters, digits, dots, dashes and underscores, with no spaces."
    }

    var keyProblem: String? {
        guard kind == .paths, !trimmedKey.isEmpty else { return nil }
        let bad = trimmedKey.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0.isEmpty || $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }
        return bad ? "Use paths inside the repository, separated by commas." : nil
    }

    var canSend: Bool { !trimmedKey.isEmpty && keyProblem == nil && Self.isAgentName(trimmedAgent) }

    func body(handle: String) -> MultiplayerJSON {
        .object(["kind": .string(kind.rawValue), "key": .string(trimmedKey), "holder": .string("\(handle)/\(trimmedAgent)")])
    }
}

struct MultiplayerCardDraft: Equatable {
    var title = ""
    var body = ""

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSend: Bool { !trimmedTitle.isEmpty && trimmedTitle.count <= 256 }

    var json: MultiplayerJSON { .object(["title": .string(trimmedTitle), "body": .string(body)]) }
}

struct MultiplayerQueueDraft: Equatable {
    var branch = ""
    var checkout = ""
    /// The test command as typed, split on spaces into an argument array. No shell runs it.
    var testText = ""

    var trimmedBranch: String { branch.trimmingCharacters(in: .whitespacesAndNewlines) }
    var testCommand: [String] { testText.split(whereSeparator: \.isWhitespace).map(String.init) }

    var checkoutProblem: String? {
        let path = checkout.trimmingCharacters(in: .whitespaces)
        return path.isEmpty || path.hasPrefix("/") ? nil : "Use an absolute path that starts with /."
    }

    var canSend: Bool {
        !trimmedBranch.isEmpty && !trimmedBranch.contains(" ") && checkout.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }
}

// MARK: - Client

extension MultiplayerClient {
    /// One path segment, percent-encoded so an ID can't change the route.
    static func segment(_ text: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~:")
        guard !text.isEmpty, let part = text.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw MultiplayerFailure.invalidInput("That name can’t be sent.")
        }
        return part
    }

    /// One relay call. An empty reply reads as `null`.
    @discardableResult
    func relay(_ method: String, _ path: String, body: MultiplayerJSON? = nil) async throws -> MultiplayerJSON {
        var payload: [String: MultiplayerPayloadValue] = ["method": .string(method), "path": .string(path)]
        if let body { payload["body"] = .json(body) }
        return try await fetch(.relay, payload, as: MultiplayerJSON.self, allowsEmpty: true) ?? .null
    }

    func groups() async throws -> [MultiplayerGroup] {
        (try await relay("GET", "/v1/groups")["groups"]?.items ?? []).compactMap(MultiplayerGroup.init)
    }

    func createGroup(name: String) async throws -> String {
        try await relay("POST", "/v1/groups", body: .object(["name": .string(name)])).firstText("id") ?? ""
    }

    func deleteGroup(_ id: String) async throws {
        try await relay("DELETE", "/v1/groups/\(Self.segment(id))")
    }

    func setGroupMember(_ handle: String, in group: String, isMember: Bool) async throws {
        try await relay(isMember ? "PUT" : "DELETE", "/v1/groups/\(Self.segment(group))/members/\(Self.segment(handle))")
    }

    func workspaces() async throws -> [MultiplayerWorkspace] {
        (try await relay("GET", "/v1/workspaces")["workspaces"]?.items ?? []).compactMap(MultiplayerWorkspace.init)
    }

    func createWorkspace(_ body: MultiplayerJSON) async throws -> String {
        try await relay("POST", "/v1/workspaces", body: body).firstText("id") ?? ""
    }

    func claim(_ body: MultiplayerJSON, in workspace: String) async throws {
        try await relay("POST", "/v1/workspaces/\(Self.segment(workspace))/claims", body: body)
    }

    func release(claim: String, in workspace: String) async throws {
        try await relay("DELETE", "/v1/workspaces/\(Self.segment(workspace))/claims/\(Self.segment(claim))")
    }

    func cards(in workspace: String) async throws -> [MultiplayerCard] {
        (try await relay("GET", "/v1/workspaces/\(Self.segment(workspace))/cards")["cards"]?.items ?? [])
            .compactMap(MultiplayerCard.init)
    }

    func createCard(_ body: MultiplayerJSON, in workspace: String) async throws {
        try await relay("POST", "/v1/workspaces/\(Self.segment(workspace))/cards", body: body)
    }

    func updateCard(_ card: String, in workspace: String, fields: [String: MultiplayerJSON]) async throws {
        try await relay("PUT", "/v1/workspaces/\(Self.segment(workspace))/cards/\(Self.segment(card))", body: .object(fields))
    }

    private func queue(_ verb: MultiplayerVerb, _ payload: [String: MultiplayerPayloadValue]) async throws -> [MultiplayerQueueEntry] {
        let reply = try await fetch(verb, payload, as: MultiplayerJSON.self, allowsEmpty: true) ?? .null
        return (reply["queue"]?.items ?? []).compactMap(MultiplayerQueueEntry.init)
    }

    /// The merge queue on this Mac, for every workspace.
    func mergeQueue() async throws -> [MultiplayerQueueEntry] { try await queue(.queue, [:]) }

    func queueAdd(workspace: String, branch: String, checkout: String, testCommand: [String]) async throws -> [MultiplayerQueueEntry] {
        try await queue(.queueAdd, ["workspace": .string(workspace), "branch": .string(branch), "checkout": .string(checkout),
                                    "testCommand": .strings(testCommand)])
    }

    func queueMerge(workspace: String) async throws -> [MultiplayerQueueEntry] {
        try await queue(.queueMerge, ["workspace": .string(workspace)])
    }

    /// Takes one branch out of the queue, whatever its state. The device names an entry by its
    /// workspace and branch.
    func queueRemove(workspace: String, branch: String) async throws -> [MultiplayerQueueEntry] {
        let reply = try await fetch(.queueRemove, ["workspace": .string(workspace), "branch": .string(branch)],
                                    as: MultiplayerJSON.self, allowsEmpty: true) ?? .null
        // A reply without the queue is read again rather than taken as an empty one.
        guard let rows = reply["queue"]?.items else { return try await mergeQueue() }
        return rows.compactMap(MultiplayerQueueEntry.init)
    }

    func knowledge() async throws -> [MultiplayerKnowledgeItem] {
        (try await relay("GET", "/v1/knowledge")["items"]?.items ?? []).compactMap(MultiplayerKnowledgeItem.init)
    }

    func knowledgeVersions(_ id: String) async throws -> [MultiplayerKnowledgeItem] {
        (try await relay("GET", "/v1/knowledge/\(Self.segment(id))/versions")["versions"]?.items ?? [])
            .compactMap(MultiplayerKnowledgeItem.init)
    }

    /// Shares a new item through the device, which refuses content that seems to carry a secret.
    func shareKnowledge(_ item: MultiplayerJSON) async throws {
        _ = try await fetch(.knowledgeShare, ["item": .json(item)], as: MultiplayerJSON.self, allowsEmpty: true)
    }

    func updateKnowledge(_ id: String, _ item: MultiplayerJSON) async throws {
        try await relay("PUT", "/v1/knowledge/\(Self.segment(id))", body: item)
    }

    /// Where the device wrote the item.
    func installKnowledge(_ item: MultiplayerJSON, destination: String = "") async throws -> String {
        var payload: [String: MultiplayerPayloadValue] = ["item": .json(item)]
        if !destination.isEmpty { payload["destination"] = .string(destination) }
        let reply = try await fetch(.knowledgeInstall, payload, as: MultiplayerJSON.self, allowsEmpty: true) ?? .null
        return reply.firstText("installed") ?? destination
    }

    func reputation(_ resource: String) async throws -> MultiplayerReputation {
        MultiplayerReputation(try await relay("GET", "/v1/reputation/\(Self.segment(resource))"))
    }

    func reportOutcome(resource: String, request: String, accepted: Bool) async throws {
        try await relay("POST", "/v1/outcomes", body: .object(["resource": .string(resource), "request": .string(request),
                                                                "accepted": .bool(accepted)]))
    }

    func endorse(resource: String, skill: String) async throws {
        try await relay("POST", "/v1/endorsements", body: .object(["resource": .string(resource), "skill": .string(skill)]))
    }

    func searchDirectory(_ query: String) async throws -> MultiplayerDirectorySearch {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let reply = try await relay("GET", "/v1/directory?q=\(q)")
        return MultiplayerDirectorySearch(query: query, handles: reply["handles"]?.strings ?? [],
                                          resources: (reply["resources"]?.items ?? []).compactMap(MultiplayerDirectoryHit.init))
    }

    /// Reads the policy by sending an edit that changes nothing: the relay answers with what stands.
    func relayPolicy() async throws -> MultiplayerRelayPolicy {
        try await setRelayPolicy([:])
    }

    func setRelayPolicy(_ changes: [String: MultiplayerJSON]) async throws -> MultiplayerRelayPolicy {
        guard let policy = MultiplayerRelayPolicy(try await relay("PUT", "/v1/admin/policy", body: .object(changes))) else {
            throw MultiplayerFailure.invalidResponse
        }
        return policy
    }

    func setSuspended(_ handle: String, _ suspended: Bool) async throws {
        try await relay("POST", "/v1/admin/members/\(Self.segment(handle))/\(suspended ? "suspend" : "unsuspend")")
    }

    func revokeDevice(_ device: String) async throws {
        try await relay("DELETE", "/v1/admin/devices/\(Self.segment(device))")
    }
}
