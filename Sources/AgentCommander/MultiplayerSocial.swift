import AppKit
import Foundation

// MULTIPLAYER CONTRACT: social (design/COMMANDER-NETWORK-INCREMENT-2.md).
// Presence, linked contacts, the activity feed, avatars, invite links and relay membership, as the
// device agent's tray verbs exchange them. Values only; MultiplayerModel calls the helper.

// MARK: - Presence

/// What the person picks. `auto` lets the device agent decide between online, away and busy.
enum MultiplayerPresenceChoice: String, CaseIterable, Sendable, Identifiable {
    case auto, online, away, busy, dnd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .online: "Online"
        case .away: "Away"
        case .busy: "Busy"
        case .dnd: "Do not disturb"
        }
    }
}

/// A person's presence as a server reports it. A word this build does not know reads as `unknown`,
/// never as online.
enum MultiplayerPersonPresence: String, Codable, Sendable, Equatable {
    case online, away, busy, dnd, offline, unknown

    init(from decoder: any Decoder) throws {
        self = Self(word: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// Nil for an empty word, `unknown` for one this build can't read.
    init?(word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if word.isEmpty { return nil }
        self = Self(rawValue: word) ?? .unknown
    }

    /// The presence word when there is one; otherwise the older `online` flag.
    static func read(word: String?, online: Bool?) -> MultiplayerPersonPresence {
        if let presence = word.flatMap(Self.init(word:)) { return presence }
        switch online {
        case true?: return .online
        case false?: return .offline
        case nil: return .unknown
        }
    }

    var title: String {
        switch self {
        case .online: "Online"
        case .away: "Away"
        case .busy: "Busy"
        case .dnd: "Do not disturb"
        case .offline: "Offline"
        case .unknown: "Unknown"
        }
    }

    /// Reachable now: online or busy. Away, do not disturb and offline are not counted as online.
    var isAvailable: Bool { self == .online || self == .busy }

    /// Has a live device on the server, whatever they chose to show.
    var isConnected: Bool {
        switch self {
        case .online, .away, .busy, .dnd: true
        case .offline, .unknown: false
        }
    }
}

/// A `presence` reply: what the server now shows, and whether the device agent is choosing it.
struct MultiplayerPresenceReply: Decodable, Equatable, Sendable {
    let presence: MultiplayerPersonPresence
    let auto: Bool

    private enum CodingKeys: String, CodingKey { case presence, auto }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presence = (try? container.decodeIfPresent(MultiplayerPersonPresence.self, forKey: .presence)) ?? .unknown
        auto = (try? container.decodeIfPresent(Bool.self, forKey: .auto)) ?? false
    }
}

// MARK: - Contacts

/// One friend on one server.
struct MultiplayerContactRow: Decodable, Equatable, Sendable {
    let server: String
    let handle: String
    let presence: MultiplayerPersonPresence
    let statusMessage: String
    let hasAvatar: Bool

    private enum CodingKeys: String, CodingKey { case server, handle, presence, online, statusMessage, hasAvatar }

    init(server: String, handle: String, presence: MultiplayerPersonPresence = .unknown,
         statusMessage: String = "", hasAvatar: Bool = false) {
        self.server = server
        self.handle = handle
        self.presence = presence
        self.statusMessage = statusMessage
        self.hasAvatar = hasAvatar
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(String.self, forKey: .server)
        handle = try container.decode(String.self, forKey: .handle)
        presence = .read(word: try? container.decodeIfPresent(String.self, forKey: .presence),
                         online: try? container.decodeIfPresent(Bool.self, forKey: .online))
        statusMessage = ((try? container.decodeIfPresent(String.self, forKey: .statusMessage)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        hasAvatar = (try? container.decodeIfPresent(Bool.self, forKey: .hasAvatar)) ?? false
    }
}

/// One person. Friends with the same `contactKey` on several servers share one contact; a friend
/// without a key stays single.
struct MultiplayerContact: Decodable, Equatable, Sendable {
    let contactKey: String
    let displayName: String
    let rows: [MultiplayerContactRow]

    private enum CodingKeys: String, CodingKey { case contactKey, displayName, rows }

    init(contactKey: String = "", displayName: String = "", rows: [MultiplayerContactRow]) {
        self.contactKey = contactKey
        self.displayName = displayName
        self.rows = rows
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contactKey = (try? container.decodeIfPresent(String.self, forKey: .contactKey)) ?? ""
        displayName = ((try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        rows = try container.decodeIfPresent([MultiplayerContactRow].self, forKey: .rows) ?? []
    }
}

/// A friend as one server's group draws them: who, their presence there, and the other servers
/// the same person is a friend on.
struct MultiplayerContactEntry: Equatable, Sendable, Identifiable {
    let server: String
    let handle: String
    let displayName: String
    let presence: MultiplayerPersonPresence
    let statusMessage: String
    let hasAvatar: Bool
    /// Display names of the other servers this contact is on, in server-list order.
    let alsoOn: [String]

    var id: String { MultiplayerAvatarKey.make(server: server, handle: handle) }

    /// The display name, or the handle when the person set none.
    var title: String { displayName.isEmpty ? handle.multiplayerDisplay : displayName.multiplayerDisplay }

    /// The handle, shown under a display name.
    var handleCaption: String? { displayName.isEmpty ? nil : handle.multiplayerDisplay }

    /// "also on team-relay", or nil when this person is on one server only.
    var linkBadge: String? {
        alsoOn.isEmpty ? nil : "also on " + alsoOn.formatted(.list(type: .and))
    }

    /// Presence, then the person's own status line.
    var caption: String {
        statusMessage.isEmpty ? presence.title : "\(presence.title), \(statusMessage.multiplayerDisplay)"
    }
}

enum MultiplayerContactGrouping {
    /// One server's friends, decorated from the linked contacts. People with a live device come
    /// first, then everyone else; the name, then the handle, settle the order within each.
    /// `friends` is that server's own list, so a contact reply that lags never hides a friend.
    static func entries(friends: [MultiplayerFriend], on server: String, contacts: [MultiplayerContact],
                        servers: [MultiplayerServerSummary]) -> [MultiplayerContactEntry] {
        let order = Dictionary(servers.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = friends.map { friend -> MultiplayerContactEntry in
            let contact = contacts.first { $0.rows.contains { $0.server == server && $0.handle == friend.handle } }
            let row = contact?.rows.first { $0.server == server && $0.handle == friend.handle }
            let others = (contact?.rows ?? [])
                .filter { $0.server != server }
                .compactMap { row in order[row.server].map { (index: $0, name: servers[$0].displayName) } }
                .sorted { $0.index < $1.index }
                .map(\.name)
            return MultiplayerContactEntry(server: server, handle: friend.handle,
                                           displayName: contact?.displayName ?? "",
                                           presence: row?.presence ?? .read(word: nil, online: friend.online),
                                           statusMessage: row?.statusMessage ?? "",
                                           hasAvatar: row?.hasAvatar ?? false,
                                           alsoOn: MultiplayerUnique.keep(others) { $0 })
        }
        return entries.sorted { left, right in
            if left.presence.isConnected != right.presence.isConnected { return left.presence.isConnected }
            let names = left.title.localizedStandardCompare(right.title)
            if names != .orderedSame { return names == .orderedAscending }
            return left.handle < right.handle
        }
    }
}

// MARK: - Activity

/// One event from a server's feed.
struct MultiplayerActivityEvent: Decodable, Equatable, Sendable, Identifiable {
    let server: String
    let seq: Int
    let at: Date?
    let kind: String
    let actor: String
    let resource: String
    let detail: String

    private enum CodingKeys: String, CodingKey { case server, seq, at, kind, actor, resource, detail }

    /// A relay event has its sequence. One the device agent adds itself has none, so it is told
    /// apart by what it says.
    var id: String {
        seq > 0 ? "\(server)#\(seq)" : "\(server)#\(kind)#\(actor)#\(resource)#\(Int(at?.timeIntervalSince1970 ?? 0))"
    }

    init(server: String, seq: Int, at: Date? = nil, kind: String, actor: String = "", resource: String = "",
         detail: String = "") {
        self.server = server
        self.seq = seq
        self.at = at
        self.kind = kind
        self.actor = actor
        self.resource = resource
        self.detail = detail
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            ((try? container.decodeIfPresent(String.self, forKey: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        server = try container.decode(String.self, forKey: .server)
        seq = try container.decode(Int.self, forKey: .seq)
        kind = try container.decode(String.self, forKey: .kind)
        at = MultiplayerTime.parse(text(.at))
        actor = text(.actor)
        resource = text(.resource)
        detail = text(.detail)
    }

    /// What happened, in the reader's terms. A kind this build doesn't know is shown as the relay named it.
    var sentence: String { line(on: nil) }

    /// The same sentence naming the server: "sam shared access with you on team-relay: Run tests".
    func line(on serverName: String?) -> String {
        let who = actor.isEmpty ? "Someone" : actor.multiplayerDisplay
        let note = MultiplayerText.clean(detail, limit: 120, redact: true)
        var base: String
        switch kind {
        case "friend.request": base = "\(who) sent a friend request"
        case "friend.accepted": base = "\(who) accepted your friend request"
        case "friend.removed": base = "\(who) removed you as a friend"
        case "grant.received": base = "\(who) shared access with you"
        case "grant.revoked": base = "\(who) revoked your access"
        case "member.joined": base = "\(who) joined"
        case "access.requested": base = "\(who) asked for access"
        case "approval.pending":
            // The detail is the action's identifier; say it in words instead.
            let wants = detail.isEmpty ? "use a resource you shared" : MultiplayerCapability.title(detail).lowercasedFirst
            base = "\(who) wants to \(wants). Approve or deny it in the tray"
            return serverName.map { "\(base), on \($0)" } ?? base
        default: base = "\(who): \(kind.multiplayerDisplay)"
        }
        if let serverName { base += " on \(serverName)" }
        return note.isEmpty ? base : "\(base): \(note)"
    }

    /// Newest first; the sequence settles events of the same second on one server.
    static func newestFirst(_ events: [MultiplayerActivityEvent]) -> [MultiplayerActivityEvent] {
        MultiplayerUnique.keep(events) { $0.id }.sorted { left, right in
            let leftAt = left.at ?? .distantPast, rightAt = right.at ?? .distantPast
            if leftAt != rightAt { return leftAt > rightAt }
            if left.server != right.server { return left.server < right.server }
            return left.seq > right.seq
        }
    }
}

/// An `activity` reply.
struct MultiplayerActivityFeed: Decodable, Equatable, Sendable {
    let events: [MultiplayerActivityEvent]
    let cursor: String
    let unseen: Int

    private enum CodingKeys: String, CodingKey { case events, cursor, unseen }

    init(events: [MultiplayerActivityEvent] = [], cursor: String = "", unseen: Int = 0) {
        self.events = events
        self.cursor = cursor
        self.unseen = unseen
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decodeIfPresent([MultiplayerActivityEvent].self, forKey: .events) ?? []
        cursor = (try? container.decodeIfPresent(String.self, forKey: .cursor)) ?? ""
        unseen = max((try? container.decodeIfPresent(Int.self, forKey: .unseen)) ?? 0, 0)
    }
}

// MARK: - Avatars

enum MultiplayerAvatarKey {
    static func make(server: String, handle: String) -> String { "\(server)/\(handle)" }
}

/// An `avatar` reply: the image bytes and their type.
struct MultiplayerAvatarImage: Decodable, Equatable, Sendable {
    let contentType: String
    let data: Data

    private enum CodingKeys: String, CodingKey { case contentType, data }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentType = (try? container.decodeIfPresent(String.self, forKey: .contentType)) ?? ""
        guard let bytes = Data(base64Encoded: try container.decode(String.self, forKey: .data)), !bytes.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "not base64")
        }
        data = bytes
    }
}

/// Turns a picked image into the PNG or JPEG data URL the relay accepts, at most 64 KiB.
enum MultiplayerAvatarEncoder {
    /// The whole data URL, prefix included.
    static let limit = 64 * 1024
    static let sides = [256, 192, 128, 96, 64]
    static let qualities: [CGFloat] = [0.85, 0.7, 0.5]

    struct Encoded: Equatable, Sendable {
        let dataURL: String
        /// The bytes inside the data URL, for the preview.
        let image: Data
    }

    static func dataURL(type: String, _ data: Data) -> String { "data:\(type);base64,\(data.base64EncodedString())" }

    /// A small PNG or JPEG is sent as it is. Anything else is cropped square, scaled down and
    /// saved as JPEG until it fits. Nil when the file isn't an image.
    static func encode(_ file: Data) -> Encoded? {
        guard let source = NSBitmapImageRep(data: file), let image = source.cgImage else { return nil }
        if let type = nativeType(file), max(image.width, image.height) <= 512 {
            let url = dataURL(type: type, file)
            if url.utf8.count <= limit { return Encoded(dataURL: url, image: file) }
        }
        for side in sides {
            guard let scaled = square(image, side: side) else { continue }
            let rep = NSBitmapImageRep(cgImage: scaled)
            for quality in qualities {
                guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { continue }
                let url = dataURL(type: "image/jpeg", jpeg)
                if url.utf8.count <= limit { return Encoded(dataURL: url, image: jpeg) }
            }
        }
        return nil
    }

    /// "image/png" or "image/jpeg" by the file's leading bytes.
    static func nativeType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        return nil
    }

    /// The centre square of the image, drawn opaque at `side` pixels.
    static func square(_ image: CGImage, side: Int) -> CGImage? {
        let edge = min(image.width, image.height)
        let crop = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
        guard let cropped = image.cropping(to: crop),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}

// MARK: - Profile

/// What the avatar control will send: nothing, a new image, or a removal.
enum MultiplayerAvatarEdit: Equatable, Sendable {
    case keep
    case replace(MultiplayerAvatarEncoder.Encoded)
    case remove
}

/// One server's profile editor.
struct MultiplayerProfileDraft: Equatable {
    static let displayNameLimit = 80
    static let statusLimit = 140

    var handle = ""
    var displayName = ""
    var statusMessage = ""
    var avatar = MultiplayerAvatarEdit.keep
    /// The values the editor opened with. Only fields that differ are sent.
    var savedHandle = ""
    var savedDisplayName = ""
    var savedStatusMessage = ""

    var trimmedHandle: String { handle.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDisplayName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedStatus: String { statusMessage.trimmingCharacters(in: .whitespacesAndNewlines) }

    var problem: String? {
        if let problem = MultiplayerInput.handleProblem(trimmedHandle) { return problem }
        if trimmedDisplayName.count > Self.displayNameLimit { return "Keep the display name under \(Self.displayNameLimit) characters." }
        if trimmedStatus.count > Self.statusLimit { return "Keep the status under \(Self.statusLimit) characters." }
        return nil
    }

    var hasChanges: Bool {
        trimmedHandle != savedHandle || trimmedDisplayName != savedDisplayName
            || trimmedStatus != savedStatusMessage || avatar != .keep
    }
}

// MARK: - Membership and invites

enum MultiplayerMembershipMode: String, CaseIterable, Sendable, Identifiable {
    case open, allowlist, invite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .allowlist: "Allowed emails"
        case .invite: "Invite only"
        }
    }

    var explanation: String {
        switch self {
        case .open: "Anyone who can reach this relay and sign in becomes a member."
        case .allowlist: "Only the emails listed below can sign in. An invite adds its user to the list."
        case .invite: "People join with an invite link from an admin."
        }
    }

    static func title(for mode: String) -> String { Self(rawValue: mode)?.title ?? mode.multiplayerDisplay }
}

/// A `me` reply: whether this account administers the relay, and how people join it.
struct MultiplayerMe: Decodable, Equatable, Sendable {
    let admin: Bool
    let mode: String

    private enum CodingKeys: String, CodingKey { case admin, mode }

    init(admin: Bool, mode: String = "") {
        self.admin = admin
        self.mode = mode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        admin = try container.decode(Bool.self, forKey: .admin)
        mode = (try? container.decodeIfPresent(String.self, forKey: .mode)) ?? ""
    }

    /// Any member can invite while the relay is open; only admins otherwise.
    var canInvite: Bool { admin || mode == MultiplayerMembershipMode.open.rawValue }
}

/// The relay's membership settings, as `membership` and `membership-set` return them.
struct MultiplayerMembership: Decodable, Equatable, Sendable {
    let mode: String
    let allowedEmails: [String]
    let admins: [String]
    let memberCount: Int

    private enum CodingKeys: String, CodingKey { case mode, allowedEmails, admins, memberCount }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        allowedEmails = try container.decodeIfPresent([String].self, forKey: .allowedEmails) ?? []
        admins = try container.decodeIfPresent([String].self, forKey: .admins) ?? []
        memberCount = max((try? container.decodeIfPresent(Int.self, forKey: .memberCount)) ?? 0, 0)
    }
}

/// The membership editor. Emails are typed one per line, or separated by commas or spaces.
struct MultiplayerMembershipDraft: Equatable {
    var mode = MultiplayerMembershipMode.open.rawValue
    var allowedEmails = ""
    var admins = ""

    init() {}

    init(_ membership: MultiplayerMembership) {
        mode = membership.mode
        allowedEmails = membership.allowedEmails.joined(separator: "\n")
        admins = membership.admins.joined(separator: "\n")
    }

    static func emails(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        return MultiplayerUnique.keep(text.components(separatedBy: separators)
            .map { $0.lowercased() }.filter { !$0.isEmpty }) { $0 }
    }

    var allowedList: [String] { Self.emails(allowedEmails) }
    var adminList: [String] { Self.emails(admins) }

    var problem: String? {
        if adminList.isEmpty { return "Keep at least one admin." }
        if let bad = (allowedList + adminList).first(where: { !Self.looksLikeEmail($0) }) {
            return "“\(bad.multiplayerDisplay)” isn’t an email address."
        }
        return nil
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && text.count <= 254
    }

    func differs(from membership: MultiplayerMembership) -> Bool {
        mode != membership.mode || allowedList != membership.allowedEmails.map { $0.lowercased() }
            || adminList != membership.admins.map { $0.lowercased() }
    }
}

/// An `invite-create` reply.
struct MultiplayerInvite: Decodable, Equatable, Sendable {
    let link: String
    let code: String
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey { case link, code, expiresAt }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        link = try container.decode(String.self, forKey: .link)
        code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? ""
        expiresAt = ((try? container.decodeIfPresent(String.self, forKey: .expiresAt)) ?? nil).flatMap(MultiplayerTime.parse)
    }
}

/// How long a new invite lasts and how many people can use it.
struct MultiplayerInviteDraft: Equatable {
    static let usesRange = 1...100
    static let lifetimes: [(hours: Int, title: String)] = [(24, "1 day"), (168, "7 days"), (720, "30 days")]

    var maxUses = 5
    var ttlHours = 168
}

/// `agentcommander://join?server=<https origin>&pin=<pin or empty>&code=<invite code>&from=<handle>`.
struct MultiplayerInviteLink: Equatable, Sendable {
    static let scheme = "agentcommander"

    /// The link exactly as received; `join` is sent this text.
    let raw: String
    /// The relay's https origin.
    let server: String
    /// `sha256/<base64>`, or empty when the system trusts the relay's certificate.
    let pin: String
    let code: String
    /// The inviter's handle, or empty.
    let from: String

    /// Nil unless this is a join link naming an https relay. A link with no code is still a link:
    /// an open relay needs none.
    static func parse(_ text: String) -> MultiplayerInviteLink? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 2048, let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == scheme, parts.host?.lowercased() == "join"
        else { return nil }
        func value(_ name: String) -> String {
            (parts.queryItems?.first { $0.name == name }?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var server = value("server")
        while server.hasSuffix("/") { server.removeLast() }
        if !server.contains("://") { server = "https://" + server }
        guard MultiplayerServerAddress.problem(server) == nil,
              let origin = URLComponents(string: server), origin.scheme == "https",
              let host = origin.host, !host.isEmpty, origin.path.isEmpty, origin.query == nil, origin.user == nil
        else { return nil }
        let pin = value("pin")
        guard pin.isEmpty || MultiplayerFingerprint.text(pin: pin) != nil else { return nil }
        let from = value("from")
        guard from.isEmpty || MultiplayerInput.handleProblem(from) == nil else { return nil }
        let code = value("code")
        guard code.count <= 256 else { return nil }
        return MultiplayerInviteLink(raw: raw, server: server, pin: pin, code: code, from: from)
    }
}
