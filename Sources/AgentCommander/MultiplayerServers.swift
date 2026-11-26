import Foundation

// MULTIPLAYER CONTRACT: the server list (design/COMMANDER-NETWORK-INCREMENT-1.md).
// The device agent keeps the list and one relay connection per server. The tray reads summaries,
// runs the staged health check before saving a server, and confirms a certificate pin. These are
// the values those verbs exchange; only MultiplayerModel calls the helper.

/// The device agent's word on one server's connection. A word this build does not know reads as
/// `unknown`, never as online.
enum MultiplayerServerState: String, Codable, Sendable, Equatable {
    case signedOut, connecting, online, offline, certChanged, error, unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }

    var title: String {
        switch self {
        case .signedOut: "Signed out"
        case .connecting: "Connecting…"
        case .online: "Online"
        case .offline: "Offline"
        case .certChanged: "Certificate changed"
        case .error: "Problem"
        case .unknown: "Unknown"
        }
    }

    var tone: Tone {
        switch self {
        case .online: .working
        case .connecting: .focus
        case .certChanged, .error: .failure
        case .signedOut, .offline, .unknown: .neutral
        }
    }
}

/// One saved server with its live state, as `servers`, `server-add`, `server-update` and
/// `server-trust` return it.
struct MultiplayerServerSummary: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let url: String
    let name: String
    let favorite: Bool
    let autoConnect: Bool
    /// `sha256/<base64 SPKI hash>`, or empty when the system trusts the certificate.
    let pin: String
    let lastUsedAt: Date?
    let state: MultiplayerServerState
    let signedIn: Bool
    let handle: String
    let lastSeen: Date?
    let error: String
    let friendsOnline: Int
    let incoming: Int
    /// The presence this account shows on the server (increment 2). Nil when the helper doesn't say.
    let presence: MultiplayerPersonPresence?
    /// Feed events on this server the person hasn't seen.
    let unseen: Int

    private enum CodingKeys: String, CodingKey {
        case id, url, name, favorite, autoConnect, pin, lastUsedAt, state, signedIn, handle, lastSeen, error
        case friendsOnline, incoming, presence, unseen
    }

    init(id: String, url: String, name: String, favorite: Bool = false, autoConnect: Bool = true, pin: String = "",
         lastUsedAt: Date? = nil, state: MultiplayerServerState = .signedOut, signedIn: Bool = false,
         handle: String = "", lastSeen: Date? = nil, error: String = "", friendsOnline: Int = 0, incoming: Int = 0,
         presence: MultiplayerPersonPresence? = nil, unseen: Int = 0) {
        self.id = id
        self.url = url
        self.name = name
        self.favorite = favorite
        self.autoConnect = autoConnect
        self.pin = pin
        self.lastUsedAt = lastUsedAt
        self.state = state
        self.signedIn = signedIn
        self.handle = handle
        self.lastSeen = lastSeen
        self.error = error
        self.friendsOnline = friendsOnline
        self.incoming = incoming
        self.presence = presence
        self.unseen = unseen
    }

    /// The identity and the state are required. Everything else is read leniently, so a sparse
    /// reply still lists the server.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            ((try? container.decodeIfPresent(String.self, forKey: key)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func flag(_ key: CodingKeys) -> Bool { (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? false }
        func count(_ key: CodingKeys) -> Int { max((try? container.decodeIfPresent(Int.self, forKey: key)) ?? 0, 0) }
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        state = try container.decode(MultiplayerServerState.self, forKey: .state)
        name = text(.name)
        favorite = flag(.favorite)
        autoConnect = flag(.autoConnect)
        pin = text(.pin)
        lastUsedAt = MultiplayerTime.parse(text(.lastUsedAt))
        signedIn = flag(.signedIn)
        handle = text(.handle)
        lastSeen = MultiplayerTime.parse(text(.lastSeen))
        error = text(.error)
        friendsOnline = count(.friendsOnline)
        incoming = count(.incoming)
        presence = MultiplayerPersonPresence(word: text(.presence))
        unseen = count(.unseen)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(name, forKey: .name)
        try container.encode(favorite, forKey: .favorite)
        try container.encode(autoConnect, forKey: .autoConnect)
        try container.encode(pin, forKey: .pin)
        try container.encodeIfPresent(lastUsedAt.map(MultiplayerTime.format), forKey: .lastUsedAt)
        try container.encode(state, forKey: .state)
        try container.encode(signedIn, forKey: .signedIn)
        try container.encode(handle, forKey: .handle)
        try container.encodeIfPresent(lastSeen.map(MultiplayerTime.format), forKey: .lastSeen)
        try container.encode(error, forKey: .error)
        try container.encode(friendsOnline, forKey: .friendsOnline)
        try container.encode(incoming, forKey: .incoming)
        try container.encodeIfPresent(presence, forKey: .presence)
        try container.encode(unseen, forKey: .unseen)
    }

    /// The nickname, or the host when the server has none.
    var displayName: String { name.isEmpty ? host : name.multiplayerDisplay }

    /// The address without the scheme, the default port or a trailing slash.
    var host: String { MultiplayerServerAddress.host(url).multiplayerDisplay }

    /// State as a sentence fragment: "Offline, seen 2 hr. ago".
    func stateTitle(now: Date = Date()) -> String {
        guard state == .offline, let lastSeen, lastSeen < now else { return state.title }
        let style = Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated)
        return "Offline, seen \(lastSeen.formatted(style))"
    }

    /// Favorites first, then most recently used. A server never used sorts after one that was;
    /// the name, then the ID, settle ties so rows don't swap between refreshes.
    static func ordered(_ servers: [MultiplayerServerSummary]) -> [MultiplayerServerSummary] {
        MultiplayerUnique.keep(servers) { $0.id }.sorted { left, right in
            if left.favorite != right.favorite { return left.favorite }
            let leftUsed = left.lastUsedAt ?? .distantPast
            let rightUsed = right.lastUsedAt ?? .distantPast
            if leftUsed != rightUsed { return leftUsed > rightUsed }
            if left.displayName != right.displayName {
                return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
            }
            return left.id < right.id
        }
    }
}

enum MultiplayerServerAddress {
    static let limit = 253 + 16

    /// "https://relay.example:443/" reads as "relay.example".
    static func host(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(":443") { text.removeLast(4) }
        return text
    }

    /// This Mac's own names, lowercased: its host name and the first label of it.
    static let localNames: Set<String> = {
        var names: Set<String> = ["localhost", "127.0.0.1", "::1"]
        for name in [ProcessInfo.processInfo.hostName, Host.current().localizedName ?? ""] {
            let lower = name.lowercased().replacingOccurrences(of: " ", with: "-")
            guard !lower.isEmpty else { continue }
            names.insert(lower)
            if let label = lower.split(separator: ".").first { names.insert(String(label)) }
        }
        return names
    }()

    /// The relay at this address runs on this Mac: the host, or its first label, is one of this
    /// Mac's names. "ryan-mac.tail.internal" matches a Mac named "ryan-mac.local".
    static func isThisMac(_ url: String, localNames: Set<String> = localNames) -> Bool {
        var name = host(url).lowercased()
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            name = String(name[name.index(after: name.startIndex)..<close])
        } else if let colon = name.lastIndex(of: ":"), name.filter({ $0 == ":" }).count == 1 {
            name = String(name[..<colon])
        }
        if localNames.contains(name) { return true }
        guard name.contains(where: \.isLetter), let label = name.split(separator: ".").first else { return false }
        return localNames.contains(String(label))
    }

    /// The helper decides what resolves. This only stops an entry it could never read.
    static func problem(_ address: String) -> String? {
        if address.isEmpty { return "Enter the server’s address." }
        if address.count > limit { return "That address is too long." }
        let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        if address.unicodeScalars.contains(where: disallowed.contains) { return "Addresses have no spaces." }
        if let scheme = address.range(of: "://"), address[..<scheme.lowerBound].lowercased() != "https" {
            return "Use https, or leave the scheme out."
        }
        return nil
    }
}

/// The five health-check steps, in the order the helper runs them.
enum MultiplayerProbeStage: String, CaseIterable, Sendable, Identifiable {
    case dns, tcp, tls, relay, signin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dns: "Name resolution"
        case .tcp: "TCP connect"
        case .tls: "TLS and certificate"
        case .relay: "Relay version"
        case .signin: "Sign-in provider"
        }
    }
}

/// One step's result. `pin`, `fingerprint` and `systemTrusted` come with the TLS step; the client
/// fields come with the sign-in step.
struct MultiplayerProbeStep: Codable, Equatable, Sendable {
    let step: String
    let ok: Bool
    var detail: String? = nil
    var pin: String? = nil
    var fingerprint: String? = nil
    var systemTrusted: Bool? = nil
    var clientId: String? = nil
    var clientConfigured: Bool? = nil
}

/// A `server-probe` reply: the steps that ran, in order. A failed step ends the probe.
struct MultiplayerProbe: Codable, Equatable, Sendable {
    let url: String
    let steps: [MultiplayerProbeStep]
    /// The ID of the saved server this address already belongs to, when there is one.
    var existing: String? = nil

    func step(_ stage: MultiplayerProbeStage) -> MultiplayerProbeStep? {
        steps.first { $0.step == stage.rawValue }
    }

    /// Every one of the five steps ran and passed.
    var passed: Bool { MultiplayerProbeStage.allCases.allSatisfy { step($0)?.ok == true } }

    /// The first step that failed, or the first that never ran.
    var stoppedAt: MultiplayerProbeStage? {
        MultiplayerProbeStage.allCases.first { step($0)?.ok != true }
    }

    /// The key to pin when the system does not already trust the certificate; empty otherwise.
    var pin: String {
        guard let tls = step(.tls), tls.ok, tls.systemTrusted != true else { return "" }
        return tls.pin ?? ""
    }

    /// The person must confirm the fingerprint before this server can be saved.
    var needsPinConfirmation: Bool { !pin.isEmpty }

    /// The presented certificate's fingerprint, as the helper wrote it or derived from the pin.
    var fingerprint: String? {
        guard let tls = step(.tls) else { return nil }
        if let text = tls.fingerprint, !text.isEmpty { return text }
        return tls.pin.flatMap(MultiplayerFingerprint.text(pin:))
    }
}

/// Renders a pin as the colon-separated SHA-256 the person compares with the relay admin.
enum MultiplayerFingerprint {
    /// "sha256/<base64>" as "AB:CD:…". Nil when the pin isn't a readable hash.
    static func text(pin: String) -> String? {
        guard let slash = pin.firstIndex(of: "/"), pin[..<slash].lowercased() == "sha256",
              let hash = Data(base64Encoded: String(pin[pin.index(after: slash)...])), !hash.isEmpty
        else { return nil }
        return hash.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Two lines of sixteen bytes, as the fingerprint is usually read aloud.
    static func lines(_ fingerprint: String) -> String {
        let bytes = fingerprint.multiplayerDisplay.split(separator: ":")
        guard bytes.count > 16 else { return bytes.joined(separator: ":") }
        return stride(from: 0, to: bytes.count, by: 16)
            .map { bytes[$0..<min($0 + 16, bytes.count)].joined(separator: ":") }
            .joined(separator: "\n")
    }
}

/// The add-server form.
struct MultiplayerServerDraft: Equatable {
    var address = ""
    var name = ""
    var autoConnect = true
    /// "I checked this with the relay admin." Cleared whenever a new check starts.
    var pinConfirmed = false
    /// The invite this form was opened from. It applies only while the address is still its server.
    var invite: MultiplayerInviteLink? = nil

    var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
