import Foundation
import Observation

// MULTIPLAYER CONTRACT.
// The values exchanged with the bundled `commander-network` helper, the commands the network panel
// can send, and the single envelope parser. The helper owns TLS, the Keychain and the browser. A
// repository token passes through once, from MultiplayerSecretEntry to the helper's stdin; nothing
// here stores, logs or draws it. Components receive these values; only
// MultiplayerModel calls the helper (GoF Command for each verb, Adapter for the process boundary).

/// One helper verb. Each invocation is `commander-network tray <verb>` with one JSON object on stdin.
enum MultiplayerVerb: String, Sendable, CaseIterable {
    case status, login, logout, profile, search, request, accept, grant, revoke
    case resourceAdd = "resource-add"
    /// Stores a repository's GitHub token in the helper's Keychain. Never a `MultiplayerCommand`.
    case repoCredential = "repo-credential"
    /// The server list (increment 1). These act on the device agent's list, not on one relay.
    case servers
    case serverProbe = "server-probe"
    case serverAdd = "server-add"
    case serverUpdate = "server-update"
    case serverRemove = "server-remove"
    case serverTrust = "server-trust"
    /// Social (increment 2). `contacts`, `activity`, `activity-seen` and `join` name no server.
    case presence, contacts, activity, avatar, membership, join, me
    case activitySeen = "activity-seen"
    case membershipSet = "membership-set"
    case inviteCreate = "invite-create"

    /// Positional process arguments. Never passed through a shell.
    var arguments: [String] { ["tray", rawValue] }
}

// MARK: - Status

/// A friend, or a person you've asked. `online` is nil when the service doesn't say, so the panel
/// never draws a presence it wasn't given.
struct MultiplayerFriend: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let handle: String
    let online: Bool?

    private enum CodingKeys: String, CodingKey { case id, handle, online }

    init(id: String? = nil, handle: String, online: Bool? = nil) {
        self.id = id ?? handle
        self.handle = handle
        self.online = online
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let handle = try container.decode(String.self, forKey: .handle)
        self.init(id: try container.decodeIfPresent(String.self, forKey: .id).flatMap { $0.isEmpty ? nil : $0 },
                  handle: handle,
                  online: try container.decodeIfPresent(Bool.self, forKey: .online))
    }

    /// Spoken and drawn presence, or nil when unknown.
    var presenceTitle: String? { online.map { $0 ? "Online" : "Offline" } }
}

struct MultiplayerIncoming: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let handle: String
}

struct MultiplayerGrant: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let handle: String
    let kind: String
    /// The granted resource's ID.
    let resource: String
    let capability: String
    /// The helper's use limit, when it reports one. Older replies omit it.
    let maxUses: Int?
    /// The helper's expiry, when it reports a readable one. Older replies omit it.
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey { case id, handle, kind, resource, capability, maxUses, expiresAt }

    init(id: String, handle: String, kind: String, resource: String, capability: String,
         maxUses: Int? = nil, expiresAt: Date? = nil) {
        self.id = id
        self.handle = handle
        self.kind = kind
        self.resource = resource
        self.capability = capability
        self.maxUses = maxUses
        self.expiresAt = expiresAt
    }

    /// Identity fields are required; the limits are read leniently so a sparse or older reply, or
    /// one limit the panel can't read, never hides the grant itself.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let uses: Int? = try? container.decodeIfPresent(Int.self, forKey: .maxUses)
        let expiry: String? = try? container.decodeIfPresent(String.self, forKey: .expiresAt)
        self.init(id: try container.decode(String.self, forKey: .id),
                  handle: try container.decode(String.self, forKey: .handle),
                  kind: try container.decode(String.self, forKey: .kind),
                  resource: try container.decode(String.self, forKey: .resource),
                  capability: try container.decode(String.self, forKey: .capability),
                  maxUses: uses.flatMap { $0 > 0 ? $0 : nil },
                  expiresAt: expiry.flatMap(MultiplayerTime.parse))
    }
}

struct MultiplayerResource: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let kind: String
    /// Service-owned list of actions this resource allows. The panel never invents one.
    let actions: [String]

    private enum CodingKeys: String, CodingKey { case id, name, kind, actions }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(String.self, forKey: .kind)
        actions = MultiplayerUnique.keep(try container.decodeIfPresent([String].self, forKey: .actions) ?? []) { $0 }
    }
}

struct MultiplayerShared: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let owner: String
    let actions: [String]

    private enum CodingKeys: String, CodingKey { case id, name, kind, owner, actions }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(String.self, forKey: .kind)
        owner = try container.decode(String.self, forKey: .owner)
        actions = MultiplayerUnique.keep(try container.decodeIfPresent([String].self, forKey: .actions) ?? []) { $0 }
    }
}

/// One definite `status` reply. `online` and `signedIn` must be present booleans; a reply without
/// them is unreadable, so the panel never infers a signed-in or online state.
struct MultiplayerStatus: Decodable, Equatable, Sendable {
    let online: Bool
    let signedIn: Bool
    let handle: String
    /// The service's own word on a browser sign-in in progress. Authoritative over local memory.
    let loginPending: Bool
    /// A service-reported problem. When present the panel shows neither Online nor handle setup.
    let error: String
    let friends: [MultiplayerFriend]
    let outgoing: [MultiplayerFriend]
    let incoming: [MultiplayerIncoming]
    let grants: [MultiplayerGrant]
    let resources: [MultiplayerResource]
    let shared: [MultiplayerShared]
    /// The person's own profile on this server, when the helper reports it (increment 2).
    let displayName: String
    let statusMessage: String
    let hasAvatar: Bool

    private enum CodingKeys: String, CodingKey {
        case online, signedIn, handle, loginPending, error, friends, outgoing, incoming, grants, resources, shared
        case displayName, statusMessage, hasAvatar
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        online = try container.decode(Bool.self, forKey: .online)
        signedIn = try container.decode(Bool.self, forKey: .signedIn)
        handle = (try container.decodeIfPresent(String.self, forKey: .handle) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        loginPending = try container.decodeIfPresent(Bool.self, forKey: .loginPending) ?? false
        error = (try container.decodeIfPresent(String.self, forKey: .error) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        friends = MultiplayerUnique.keep(try container.decodeIfPresent([MultiplayerFriend].self, forKey: .friends) ?? []) { $0.id }
        outgoing = MultiplayerUnique.keep(try container.decodeIfPresent([MultiplayerFriend].self, forKey: .outgoing) ?? []) { $0.id }
        incoming = MultiplayerUnique.keep(try container.decodeIfPresent([MultiplayerIncoming].self, forKey: .incoming) ?? []) { $0.id }
        grants = MultiplayerUnique.keep(try container.decodeIfPresent([MultiplayerGrant].self, forKey: .grants) ?? []) { $0.id }
        resources = MultiplayerUnique.keep(try container.decodeIfPresent([MultiplayerResource].self, forKey: .resources) ?? []) { $0.id }
        shared = MultiplayerUnique.keep(try container.decodeIfPresent([MultiplayerShared].self, forKey: .shared) ?? []) { $0.id }
        displayName = ((try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        statusMessage = ((try? container.decodeIfPresent(String.self, forKey: .statusMessage)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        hasAvatar = (try? container.decodeIfPresent(Bool.self, forKey: .hasAvatar)) ?? false
    }
}

/// Keeps the first item for each identity so lists render stable rows.
enum MultiplayerUnique {
    static func keep<Item>(_ items: [Item], by key: (Item) -> String) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }
    }
}

// MARK: - Resources and capabilities

enum MultiplayerResourceKind: String, CaseIterable, Sendable, Identifiable {
    case repo, agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repo: "Repository"
        case .agent: "Agent"
        }
    }

    var symbol: String {
        switch self {
        case .repo: "folder"
        case .agent: "terminal"
        }
    }

    var targetLabel: String {
        switch self {
        case .repo: "Checkout path"
        case .agent: "Worker or coordinator ID"
        }
    }

    var targetPlaceholder: String {
        switch self {
        case .repo: "/path/to/checkout"
        case .agent: "Worker or coordinator ID"
        }
    }

    var targetHint: String {
        switch self {
        case .repo: "Absolute path of a local checkout. You can drop a folder here."
        case .agent: "The exact ID of an enrolled worker or coordinator on this Mac."
        }
    }

    /// Title and symbol for a kind the service reports, including one this build does not know.
    static func title(for kind: String) -> String { Self(rawValue: kind)?.title ?? kind }
    static func symbol(for kind: String) -> String { Self(rawValue: kind)?.symbol ?? "shippingbox" }
}

/// Plain-language meaning of the service's action identifiers. The list of actions comes from the
/// service; these strings only explain an identifier the panel shows.
enum MultiplayerCapability {
    static func title(_ capability: String) -> String {
        switch capability {
        case "issue.read": "Read issues"
        case "issue.comment": "Comment on issues"
        case "issue.close": "Close issues"
        case "git.head": "Read collaboration branch head"
        case "git.commit": "Commit to the collaboration branch"
        case "git.push": "Push the collaboration branch"
        case "agent.ask": "Send prompts to the worker"
        case "agent.message": "Send the coordinator a note"
        default: capability
        }
    }

    static func symbol(_ capability: String) -> String {
        switch capability {
        case "issue.read": "eye"
        case "issue.comment": "text.bubble"
        case "issue.close": "checkmark.circle"
        case "git.head": "arrow.triangle.branch"
        case "git.commit": "square.and.pencil"
        case "git.push": "arrow.up.circle"
        case "agent.ask": "questionmark.bubble"
        case "agent.message": "tray.and.arrow.down"
        default: "key"
        }
    }

    /// What a friend can do once granted, in the developer's terms.
    static func explanation(_ capability: String, resource name: String) -> String {
        switch capability {
        case "issue.read": "Lets them read issues in \(name)."
        case "issue.comment": "Lets them comment on issues in \(name), using this repository’s GitHub token."
        case "issue.close": "Lets them close issues in \(name), using this repository’s GitHub token."
        case "git.head": "Lets them read which commit the collaboration branch of \(name) points to."
        case "git.commit": "Lets them commit only on the dedicated local collaboration branch of \(name). Your other branches aren’t touched."
        case "git.push": "Lets them push only the collaboration branch of \(name) to its fixed GitHub repository, using this repository’s GitHub token."
        case "agent.ask":
            "Lets them submit prompts to the enrolled worker \(name). The worker acts on each prompt with its existing tools, within the tool permissions you’ve enabled for it, and uses your provider quota."
        case "agent.message":
            "Lets them send a note to the private inbox of the coordinator \(name). The coordinator decides whether to act on it; nothing runs automatically and nothing is typed into its terminal."
        default: "Lets them use “\(capability)” on \(name), as the network service defines it."
        }
    }
}

// MARK: - Grant limits

/// RFC 3339 times exchanged with the helper. Sent in UTC with whole seconds.
enum MultiplayerTime {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Accepts whole or fractional seconds and any offset; nil for anything else.
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Compact local date and time for the panel. The year appears only when it isn't `now`'s.
    static func display(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        var style = Date.FormatStyle().month(.abbreviated).day().hour().minute()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }
}

/// How long a new grant lasts. Presets are measured from the moment the owner chooses Review.
enum MultiplayerGrantExpiry: String, CaseIterable, Identifiable, Sendable {
    case hour = "1h", workday = "8h", day = "24h", threeDays = "3d", week = "7d", month = "30d"
    case custom

    static let `default` = MultiplayerGrantExpiry.day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: "For 1 hour"
        case .workday: "For 8 hours"
        case .day: "For 24 hours"
        case .threeDays: "For 3 days"
        case .week: "For 7 days"
        case .month: "For 30 days"
        case .custom: "Until a set time…"
        }
    }

    /// Seconds from review to expiry; nil for a custom time.
    var interval: TimeInterval? {
        let hour: TimeInterval = 3600
        switch self {
        case .hour: return hour
        case .workday: return 8 * hour
        case .day: return 24 * hour
        case .threeDays: return 72 * hour
        case .week: return 168 * hour
        case .month: return 720 * hour
        case .custom: return nil
        }
    }
}

/// The owner's limits on one grant: a concrete use count and an absolute expiry.
struct MultiplayerGrantLimits: Equatable, Sendable {
    static let usesRange = 1...1_000_000
    static let defaultUses = 100
    /// A reviewed expiry closer than this is treated as passed and must be reviewed again.
    static let minimumLead: TimeInterval = 60
    /// The furthest a custom expiry may be set.
    static let maximumHorizon: TimeInterval = 365 * 24 * 3600

    let maxUses: Int
    /// Whole minutes, so the time drawn at review is exactly the time sent.
    let expiresAt: Date

    init(maxUses: Int, expiresAt: Date) {
        self.maxUses = maxUses
        self.expiresAt = Self.wholeMinute(expiresAt)
    }

    var expiresAtText: String { MultiplayerTime.format(expiresAt) }

    /// Still far enough in the future to send.
    func isLive(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) >= Self.minimumLead }

    var usesTitle: String { Self.usesTitle(maxUses) }

    static func usesTitle(_ count: Int) -> String { count == 1 ? "1 use" : "\(count.formatted()) uses" }

    static func wholeMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// Reads the use-count field. Digits only, with optional grouping separators.
    static func parseUses(_ text: String) -> Result<Int, MultiplayerLimitProblem> {
        let grouping: Set<Character> = [",", "_", " ", "'", "\u{00A0}", "\u{202F}"]
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).filter { !grouping.contains($0) }
        if digits.isEmpty { return .failure(.usesMissing) }
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .failure(.usesNotWhole) }
        guard digits.count <= 7, let value = Int(digits), usesRange.contains(value) else { return .failure(.usesOutOfRange) }
        return .success(value)
    }
}

enum MultiplayerLimitProblem: Error, Equatable, Sendable {
    case usesMissing, usesNotWhole, usesOutOfRange, expiryTooSoon, expiryTooFar

    var message: String {
        switch self {
        case .usesMissing: "Enter how many times they can use it."
        case .usesNotWhole, .usesOutOfRange: "Use a whole number from 1 to 1,000,000."
        case .expiryTooSoon: "Choose a time at least a minute from now."
        case .expiryTooFar: "Choose a time within a year."
        }
    }
}

// MARK: - Commands

/// One JSON value in a helper request. Strings stay strings; a count is a real JSON number and a
/// server setting a real JSON boolean.
enum MultiplayerPayloadValue: Encodable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case string(String)
    case number(Int)
    case bool(Bool)
    /// A list of plain strings, for the membership lists.
    case strings([String])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(value) }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text): try container.encode(text)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .strings(let values): try container.encode(values)
        }
    }
}

/// One explicit, scoped mutation. The panel creates a command only from a deliberate control; the
/// model never issues one on a timer or as a side effect.
enum MultiplayerCommand: Equatable, Sendable {
    case login
    case logout
    case claimHandle(String)
    case sendRequest(handle: String)
    case accept(requestID: String, handle: String)
    /// The limits are the reviewed ones, sent exactly as the owner confirmed them.
    case grant(handle: String, kind: String, resourceID: String, resourceName: String, capability: String,
               limits: MultiplayerGrantLimits)
    case revoke(grantID: String, handle: String, resourceName: String, capability: String)
    case addResource(id: String, name: String, kind: String, target: String)

    var verb: MultiplayerVerb {
        switch self {
        case .login: .login
        case .logout: .logout
        case .claimHandle: .profile
        case .sendRequest: .request
        case .accept: .accept
        case .grant: .grant
        case .revoke: .revoke
        case .addResource: .resourceAdd
        }
    }

    /// The JSON object written to the helper's stdin. Only `grant` carries a number.
    var payload: [String: MultiplayerPayloadValue] {
        switch self {
        case .login, .logout: [:]
        case .claimHandle(let handle): ["handle": .string(handle)]
        case .sendRequest(let handle): ["handle": .string(handle)]
        case .accept(let id, _): ["id": .string(id)]
        case .grant(let handle, let kind, let resource, _, let capability, let limits):
            ["handle": .string(handle), "kind": .string(kind), "resource": .string(resource),
             "capability": .string(capability), "maxUses": .number(limits.maxUses),
             "expiresAt": .string(limits.expiresAtText)]
        case .revoke(let id, _, _, _): ["id": .string(id)]
        case .addResource(let id, let name, let kind, let target):
            ["id": .string(id), "name": .string(name), "kind": .string(kind), "target": .string(target)]
        }
    }

    /// Shown while the helper works.
    var progress: String {
        switch self {
        case .login: "Opening your browser to sign in…"
        case .logout: "Signing out…"
        case .claimHandle(let handle): "Claiming \(handle.multiplayerDisplay)…"
        case .sendRequest(let handle): "Sending a friend request to \(handle.multiplayerDisplay)…"
        case .accept(_, let handle): "Accepting \(handle.multiplayerDisplay)’s request…"
        case .grant(let handle, _, _, _, _, _): "Granting access to \(handle.multiplayerDisplay)…"
        case .revoke(_, let handle, _, _): "Revoking \(handle.multiplayerDisplay)’s access…"
        case .addResource(_, let name, _, _): "Adding \(name.multiplayerDisplay)…"
        }
    }

    /// Shown only after the helper confirms. Sign-in is reported by the status that follows.
    var confirmation: String? {
        switch self {
        case .login: nil
        case .logout: "Signed out."
        case .claimHandle(let handle): "Your handle is \(handle.multiplayerDisplay)."
        case .sendRequest(let handle): "Friend request sent to \(handle.multiplayerDisplay)."
        case .accept(_, let handle): "You and \(handle.multiplayerDisplay) are now friends."
        case .grant(let handle, _, _, let name, let capability, let limits):
            "\(handle.multiplayerDisplay) can now \(MultiplayerCapability.title(capability).lowercased()) on \(name.multiplayerDisplay), up to \(limits.usesTitle) until \(MultiplayerTime.display(limits.expiresAt))."
        case .revoke(_, let handle, let name, _): "Revoked \(handle.multiplayerDisplay)’s access to \(name.multiplayerDisplay)."
        case .addResource(_, let name, _, _): "Added \(name.multiplayerDisplay). Share it with a friend when you’re ready."
        }
    }

    /// Lead sentence when the helper refused or could not run the command.
    var failureTitle: String {
        switch self {
        case .login: "Couldn’t start sign-in."
        case .logout: "Couldn’t sign out."
        case .claimHandle: "Couldn’t claim that handle."
        case .sendRequest: "Couldn’t send the friend request."
        case .accept: "Couldn’t accept the request."
        case .grant: "Couldn’t grant access."
        case .revoke: "Couldn’t revoke access."
        case .addResource: "Couldn’t add the resource."
        }
    }

    /// Noun used when the outcome is unknown.
    var noun: String {
        switch self {
        case .login: "sign-in"
        case .logout: "sign-out"
        case .claimHandle: "handle claim"
        case .sendRequest: "friend request"
        case .accept: "acceptance"
        case .grant: "grant"
        case .revoke: "revocation"
        case .addResource: "new resource"
        }
    }
}

// MARK: - Failures

enum MultiplayerFailure: Error, Equatable, Sendable {
    case helperMissing
    case badOverride
    case launchFailed
    case cancelled
    case timedOut
    case oversized
    case exited(Int32)
    case invalidResponse
    case rejected(String)
    case invalidInput(String)

    var message: String {
        switch self {
        case .helperMissing: "The network helper isn’t in this copy of Agent Commander. Reinstall the app to use the network."
        case .badOverride: "In fixture mode, COMMANDER_NETWORK_BIN must be the absolute path of an executable fixture."
        case .launchFailed: "The network helper couldn’t start."
        case .cancelled: "Stopped before the network helper answered."
        case .timedOut: "The network helper didn’t answer in time."
        case .oversized: "The network helper sent more output than Commander accepts."
        case .exited(let status): "The network helper stopped with exit status \(status)."
        case .invalidResponse: "The network helper sent a reply Commander couldn’t read."
        case .rejected(let message): message
        case .invalidInput(let message): message
        }
    }

    /// The helper may have acted before this failure, so the safe next step is to read status
    /// rather than send the command again.
    var outcomeUnknown: Bool {
        switch self {
        case .cancelled, .timedOut, .oversized, .exited, .invalidResponse: true
        default: false
        }
    }

    /// Setup failures need a different build or environment; trying again cannot help.
    var canRetry: Bool {
        switch self {
        case .helperMissing, .badOverride: false
        default: true
        }
    }

    static func from(_ error: any Error) -> MultiplayerFailure {
        if let failure = error as? MultiplayerFailure { return failure }
        if error is CancellationError { return .cancelled }
        return .invalidResponse
    }
}

// MARK: - Envelope

/// Bounded stdout and exit status of one helper invocation. Never logged or drawn.
struct MultiplayerHelperOutput: Sendable, Equatable {
    let exitStatus: Int32
    let stdout: Data
}

/// Reads the helper's single envelope: `{"ok":true,"data":…}` or `{"ok":false,"error":"…"}`.
enum MultiplayerEnvelope {
    static let messageLimit = 280

    private struct Head: Decodable {
        let ok: Bool
        let error: String?
    }

    private struct Body<Payload: Decodable>: Decodable {
        let data: Payload?
    }

    /// Returns `data`, or nil when a successful reply carries none. A nonzero exit is never a
    /// success, even with `ok: true`.
    static func decode<Payload: Decodable>(_ type: Payload.Type, from output: MultiplayerHelperOutput) throws -> Payload? {
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: output.stdout) else {
            throw output.exitStatus == 0 ? MultiplayerFailure.invalidResponse : MultiplayerFailure.exited(output.exitStatus)
        }
        guard head.ok else {
            let message = MultiplayerText.clean(head.error ?? "", limit: messageLimit, redact: true)
            throw MultiplayerFailure.rejected(message.isEmpty ? "The network helper refused without giving a reason." : message)
        }
        guard output.exitStatus == 0 else { throw MultiplayerFailure.exited(output.exitStatus) }
        guard let body = try? decoder.decode(Body<Payload>.self, from: output.stdout) else {
            throw MultiplayerFailure.invalidResponse
        }
        return body.data
    }
}

/// Accepts any `data` value, for verbs whose success carries nothing the panel reads.
struct MultiplayerIgnored: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}

// MARK: - Text

enum MultiplayerText {
    /// Control and bidirectional-format characters become spaces, runs of whitespace collapse,
    /// and the result is bounded. Used for drawing only; values sent back keep their exact form.
    /// With `redact`, anything shaped like a credential is replaced before the text is bounded, so
    /// no part of one survives truncation.
    static func clean(_ text: String, limit: Int, redact: Bool = false) -> String {
        let unsafe = CharacterSet.controlCharacters.union(.newlines)
        var flattened = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            flattened.append(unsafe.contains(scalar) ? " " : scalar)
        }
        let words = String(flattened).split(whereSeparator: \.isWhitespace).map(String.init)
        let collapsed = words.map { redact && looksSecret($0) ? "[redacted]" : $0 }.joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(limit - 1, 0))) + "…"
    }

    static let secretPrefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "bearer", "token=", "authorization"]

    /// A known token prefix, or a long opaque run of letters and digits.
    static func looksSecret(_ word: String) -> Bool {
        let lower = word.lowercased()
        if secretPrefixes.contains(where: lower.contains) { return true }
        let opaque = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let core = word.trimmingCharacters(in: .punctuationCharacters)
        return core.count >= 32 && core.unicodeScalars.allSatisfy(opaque.contains)
            && core.contains(where: \.isNumber) && core.contains(where: \.isLetter)
    }
}

extension String {
    /// Helper-supplied text made safe to draw.
    var multiplayerDisplay: String { MultiplayerText.clean(self, limit: 120) }
}

// MARK: - Input

enum MultiplayerInput {
    static let handleLimit = 100

    /// A handle is sent exactly as typed, after trimming surrounding whitespace.
    static func handleProblem(_ handle: String) -> String? {
        if handle.isEmpty { return "Enter a handle." }
        if handle.count > handleLimit { return "That handle is too long." }
        let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        if handle.unicodeScalars.contains(where: { disallowed.contains($0) }) { return "Handles have no spaces." }
        return nil
    }
}

/// Checks a GitHub token's shape. Messages never quote, count or describe the value itself.
enum MultiplayerCredential {
    static let limit = 512

    static func problem(_ token: String) -> String? {
        if token.isEmpty { return "Paste the token." }
        if token.count > limit { return "That doesn’t look like a GitHub token." }
        let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        if token.unicodeScalars.contains(where: disallowed.contains) { return "Paste the token without spaces." }
        return nil
    }
}

/// The credential editor's transient text: the only place a token lives before it is sent. Not
/// Equatable, Codable or printable, and cleared on save, navigation, cancel and panel close.
@Observable @MainActor
final class MultiplayerSecretEntry {
    var value = ""
    func clear() { value = "" }
}

extension MultiplayerSecretEntry: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "MultiplayerSecretEntry(redacted)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The add-resource form. Its ID is made once per draft, so retrying after an unconfirmed reply
/// names the same resource rather than creating a second one.
struct MultiplayerResourceDraft: Equatable {
    var id = "res-" + UUID().uuidString.lowercased()
    var kind: MultiplayerResourceKind = .repo
    var name = ""
    var target = ""

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    func nameProblem() -> String? {
        if trimmedName.isEmpty { return "Give it a name your friends will see." }
        if trimmedName.count > 80 { return "Keep the name under 80 characters." }
        return nil
    }

    func targetProblem(directoryExists: (String) -> Bool) -> String? {
        let target = trimmedTarget
        switch kind {
        case .repo:
            if target.isEmpty { return "Enter the checkout’s absolute path." }
            if !target.hasPrefix("/") { return "Use an absolute path that starts with /." }
            if target.split(separator: "/").contains("..") { return "Use a path without .. segments." }
            if !directoryExists(target) { return "There’s no folder at that path on this Mac." }
        case .agent:
            if target.isEmpty { return "Enter the worker or coordinator ID." }
            if target.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
                return "Worker and coordinator IDs have no spaces."
            }
            if target.count > 200 { return "That ID is too long." }
        }
        return nil
    }

    func command(directoryExists: (String) -> Bool) -> MultiplayerCommand? {
        guard nameProblem() == nil, targetProblem(directoryExists: directoryExists) == nil else { return nil }
        return .addResource(id: id, name: trimmedName, kind: kind.rawValue, target: trimmedTarget)
    }
}

/// The share form: one friend, one resource, one service-listed action, and the owner's limits.
struct MultiplayerGrantDraft: Equatable {
    var handle = ""
    var resourceID = ""
    var capability = ""
    /// The use-count field exactly as typed.
    var maxUsesText = String(MultiplayerGrantLimits.defaultUses)
    var expiry = MultiplayerGrantExpiry.default
    /// Used only when `expiry` is `.custom`. Seeded when the form opens.
    var customExpiry = Date.distantPast

    var usesProblem: MultiplayerLimitProblem? {
        if case .failure(let problem) = MultiplayerGrantLimits.parseUses(maxUsesText) { return problem }
        return nil
    }

    func expiryProblem(now: Date) -> MultiplayerLimitProblem? {
        guard expiry == .custom else { return nil }
        let lead = MultiplayerGrantLimits.wholeMinute(customExpiry).timeIntervalSince(now)
        if lead < MultiplayerGrantLimits.minimumLead { return .expiryTooSoon }
        if lead > MultiplayerGrantLimits.maximumHorizon { return .expiryTooFar }
        return nil
    }

    /// Concrete limits as of `now`, or nil while a field has a problem. A preset is measured from
    /// `now`; a custom time is used as chosen.
    func limits(now: Date) -> MultiplayerGrantLimits? {
        guard case .success(let uses) = MultiplayerGrantLimits.parseUses(maxUsesText),
              expiryProblem(now: now) == nil
        else { return nil }
        let expiresAt = expiry.interval.map { now.addingTimeInterval($0) } ?? customExpiry
        let limits = MultiplayerGrantLimits(maxUses: uses, expiresAt: expiresAt)
        return limits.isLive(at: now) ? limits : nil
    }

    /// The custom picker's starting value: the current preset's end, or a day from now.
    static func seedExpiry(for expiry: MultiplayerGrantExpiry, now: Date) -> Date {
        MultiplayerGrantLimits.wholeMinute(now.addingTimeInterval(expiry.interval ?? MultiplayerGrantExpiry.default.interval ?? 86_400))
    }
}
