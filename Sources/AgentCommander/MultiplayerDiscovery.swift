import Foundation
import Observation

// RELAY DISCOVERY (design/COMMANDER-NETWORK-DISCOVERY.md, "The tray").
// The relays this Mac could join, found by the device agent on the tailnet and the local network,
// and the four steps between finding one and being a member of it. The device agent does the
// finding, the probing and the trust decision; nothing here dials a relay. Rules this file keeps:
// - A relay verified on the tailnet or trusted by macOS is added with no pin. Any other relay is
//   added only with the pin the device agent observed, and only from the person's Confirm.
// - The fingerprint a relay advertises on the local network is a hint. It is drawn, never sent.
// - A relay the person has not seen is notified once, and never while they are looking at the list.
// - Joining goes through the tray's one-action-at-a-time rule; signing in is the server's own flow.
//
// ATOMIC LEVELS:
//   values     MultiplayerDiscoveredRelay, MultiplayerDiscoverySource, MultiplayerDiscovery,
//              MultiplayerJoinChecklist
//   model      MultiplayerDiscoveryModel (owns the three verbs, the seen marks and the notifications)
//   views      MultiplayerDiscoveryViews.swift

// MARK: - Contract

/// Where the device agent found a relay. A word this build does not know is kept and drawn as "Nearby".
enum MultiplayerRelaySource: Hashable, Sendable {
    case tailnet, bonjour
    case other(String)

    init(word: String) {
        switch word.lowercased() {
        case "tailnet": self = .tailnet
        case "bonjour": self = .bonjour
        default: self = .other(word)
        }
    }

    var word: String {
        switch self {
        case .tailnet: "tailnet"
        case .bonjour: "bonjour"
        case .other(let word): word
        }
    }

    /// The label on a relay's row.
    var title: String {
        switch self {
        case .tailnet: "Tailnet"
        case .bonjour: "Local network"
        case .other: "Nearby"
        }
    }

    /// Where the relay is, as a notification says it.
    var place: String {
        switch self {
        case .tailnet: "on your tailnet"
        case .bonjour: "on your local network"
        case .other: "nearby"
        }
    }
}

/// How a relay admits people, from its public `/v1/info`. Empty while the relay can't be reached.
enum MultiplayerRelayMembership: String, Sendable, Equatable {
    case open, allowlist, invite, unknown

    init(word: String) { self = Self(rawValue: word.lowercased()) ?? .unknown }

    /// The badge on a relay's row. Nil when the relay didn't say.
    var title: String? {
        switch self {
        case .open: "Open"
        case .allowlist: "Allowlist"
        case .invite: "Invite only"
        case .unknown: nil
        }
    }
}

/// The first join step left, in the device agent's words.
enum MultiplayerRelayNext: String, Sendable, Equatable {
    case unreachable, confirm, add
    case signIn = "sign-in"
    case done
    case unknown
}

/// One relay found on a network, merged across sources, as `relay-discover` lists it. Only the ID
/// is required: every other key may be missing, and a relay that can't be reached says little.
struct MultiplayerDiscoveredRelay: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    var url: String
    var sources: [MultiplayerRelaySource]
    var reachable: Bool
    /// Why the probe failed, in the device agent's words.
    var error: String
    /// `sha256/<base64 SPKI hash>` of the key the device agent observed.
    var pin: String
    /// The observed certificate's fingerprint, colon-separated.
    var fingerprint: String
    var systemTrusted: Bool
    /// "tailnet" when `tailscale whois` confirmed the answering node is a tagged relay of this tailnet.
    var verified: String
    var tailnetNode: String
    /// The pin a Bonjour record claimed. A hint only: it is never sent as the confirmation.
    var advertisedPin: String
    /// Nil when the relay advertised no pin.
    var advertisedPinMatches: Bool?
    var version: String
    var mode: String
    var membership: MultiplayerRelayMembership
    var adminContact: String
    var issuer: String
    var clientID: String
    /// The relay is already in the server list, as `serverID`.
    var added: Bool
    var serverID: String
    /// The person has not seen this relay yet.
    var isNew: Bool
    var next: MultiplayerRelayNext
    var lastSeen: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, url, sources, reachable, error, pin, fingerprint, systemTrusted, verified, tailnetNode
        case advertisedPin, advertisedPinMatches, version, mode, membership, adminContact, issuer, added, next, lastSeen
        case clientID = "clientId"
        case serverID = "serverId"
        case isNew = "new"
    }

    init(id: String, name: String, url: String, sources: [MultiplayerRelaySource] = [.tailnet], reachable: Bool = true,
         error: String = "", pin: String = "", fingerprint: String = "", systemTrusted: Bool = false,
         verified: String = "", tailnetNode: String = "", advertisedPin: String = "", advertisedPinMatches: Bool? = nil,
         version: String = "", mode: String = "", membership: MultiplayerRelayMembership = .unknown,
         adminContact: String = "", issuer: String = "", clientID: String = "", added: Bool = false,
         serverID: String = "", isNew: Bool = false, next: MultiplayerRelayNext = .unknown, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.sources = sources
        self.reachable = reachable
        self.error = error
        self.pin = pin
        self.fingerprint = fingerprint
        self.systemTrusted = systemTrusted
        self.verified = verified
        self.tailnetNode = tailnetNode
        self.advertisedPin = advertisedPin
        self.advertisedPinMatches = advertisedPinMatches
        self.version = version
        self.mode = mode
        self.membership = membership
        self.adminContact = adminContact
        self.issuer = issuer
        self.clientID = clientID
        self.added = added
        self.serverID = serverID
        self.isNew = isNew
        self.next = next
        self.lastSeen = lastSeen
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            (((try? values.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func flag(_ key: CodingKeys) -> Bool? { (try? values.decodeIfPresent(Bool.self, forKey: key)) ?? nil }
        let id = try values.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "a relay has an ID")
        }
        self.id = id
        url = text(.url)
        let named = text(.name)
        name = named.isEmpty ? MultiplayerServerAddress.host(url) : named
        let words = ((try? values.decodeIfPresent([String].self, forKey: .sources)) ?? nil) ?? []
        sources = MultiplayerUnique.keep(words.filter { !$0.isEmpty }.map(MultiplayerRelaySource.init(word:))) { $0.word }
        reachable = flag(.reachable) ?? false
        error = text(.error)
        pin = text(.pin)
        fingerprint = text(.fingerprint)
        systemTrusted = flag(.systemTrusted) ?? false
        verified = text(.verified)
        tailnetNode = text(.tailnetNode)
        advertisedPin = text(.advertisedPin)
        // The Go side leaves the flag out when it is false, so an advertised pin without it differs.
        advertisedPinMatches = advertisedPin.isEmpty ? nil : (flag(.advertisedPinMatches) ?? false)
        version = text(.version)
        mode = text(.mode)
        membership = MultiplayerRelayMembership(word: text(.membership))
        adminContact = text(.adminContact)
        issuer = text(.issuer)
        clientID = text(.clientID)
        added = flag(.added) ?? false
        serverID = text(.serverID)
        isNew = flag(.isNew) ?? false
        next = MultiplayerRelayNext(rawValue: text(.next)) ?? .unknown
        lastSeen = MultiplayerTime.parse(text(.lastSeen))
    }

    /// The name, made safe to draw. Bonjour names are whatever a device on the network wrote.
    var displayName: String {
        let shown = MultiplayerText.clean(name, limit: 63)
        return shown.isEmpty ? host : shown
    }

    /// The address without the scheme or the default port.
    var host: String { MultiplayerServerAddress.host(url).multiplayerDisplay }

    /// The source a row and a notification name: the tailnet when the relay was found there too.
    var source: MultiplayerRelaySource { sources.contains(.tailnet) ? .tailnet : sources.first ?? .other("") }

    /// `tailscale whois` vouched for the node, so its key is pinned without asking.
    var isTailnetVerified: Bool { verified.lowercased() == "tailnet" }

    /// The fingerprint to compare, as the device agent wrote it or derived from the observed pin.
    var shownFingerprint: String? {
        if !fingerprint.isEmpty { return fingerprint }
        return MultiplayerFingerprint.text(pin: pin)
    }

    /// The step left, by the device agent's word, or by the fields when this build doesn't know the word.
    var step: MultiplayerRelayNext {
        if next != .unknown { return next }
        if added { return .signIn }
        if !reachable { return .unreachable }
        return isTailnetVerified || systemTrusted ? .add : .confirm
    }

    /// Why the relay can't be reached, as one plain sentence. Common network failures from the
    /// device agent read as what they mean; anything else is cleaned and shown as it came.
    var unreachableReason: String {
        let reason = MultiplayerText.clean(error, limit: 160, redact: true)
        let lower = reason.lowercased()
        let plain: [(needles: [String], text: String)] = [
            (["offline on the tailnet"], "It’s offline on the tailnet."),
            (["i/o timeout", "deadline exceeded", "timed out"], "It didn’t answer in time."),
            (["connection refused"], "It refused the connection. The relay may be stopped."),
            (["no route to host", "network is unreachable", "host is down"], "This Mac has no route to it."),
            (["no such host"], "Its name doesn’t resolve from this Mac."),
            (["tls handshake"], "Its secure connection failed."),
            (["not a commander relay"], "It answered, but it isn’t a Commander relay."),
        ]
        if let match = plain.first(where: { entry in entry.needles.contains { lower.contains($0) } }) { return match.text }
        return reason.isEmpty || reason.contains("[redacted]") ? "This Mac can’t reach it right now."
            : MultiplayerSentence.sentence(reason)
    }

    /// Whether the relay lives on a tailnet: found there, or named or failing at a tailnet address
    /// (100.64.0.0/10 or Tailscale's fd7a:115c:a1e0::/48). Only then does joining a tailnet help.
    var looksLikeTailnet: Bool {
        if sources.contains(.tailnet) { return true }
        let text = (host + " " + error).lowercased()
        if text.contains("fd7a:115c:a1e0:") { return true }
        return text.ranges(of: /\b100\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b/).contains { range in
            guard let match = text[range].wholeMatch(of: /100\.(\d{1,3})\.\d{1,3}\.\d{1,3}/), let second = Int(match.1) else { return false }
            return (64...127).contains(second)
        }
    }
}

/// Whether one discovery source could run, and why not.
struct MultiplayerDiscoverySource: Decodable, Equatable, Sendable {
    let name: String
    let ok: Bool
    let detail: String

    private enum CodingKeys: String, CodingKey { case name, ok, detail }

    init(name: String, ok: Bool, detail: String = "") {
        self.name = name
        self.ok = ok
        self.detail = detail
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = ((try? values.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        ok = ((try? values.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil) ?? false
        detail = ((try? values.decodeIfPresent(String.self, forKey: .detail)) ?? nil) ?? ""
    }

    /// The tailnet source didn't run because this Mac is on no tailnet.
    var saysNotOnTailnet: Bool {
        name.lowercased() == "tailnet" && !ok && detail.lowercased().contains("not on a tailnet")
    }
}

/// A `relay-discover` reply. A relay without an ID is dropped; every key may be missing.
struct MultiplayerDiscovery: Decodable, Equatable, Sendable {
    let relays: [MultiplayerDiscoveredRelay]
    let sources: [MultiplayerDiscoverySource]
    let refreshedAt: Date?

    private enum CodingKeys: String, CodingKey { case relays, sources, refreshedAt }

    init(relays: [MultiplayerDiscoveredRelay] = [], sources: [MultiplayerDiscoverySource] = [], refreshedAt: Date? = nil) {
        self.relays = relays
        self.sources = sources
        self.refreshedAt = refreshedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let listed = ((try? values.decodeIfPresent(MultiplayerLenientList<MultiplayerDiscoveredRelay>.self, forKey: .relays)) ?? nil)?.items ?? []
        relays = MultiplayerUnique.keep(listed) { $0.id }
        sources = ((try? values.decodeIfPresent(MultiplayerLenientList<MultiplayerDiscoverySource>.self, forKey: .sources)) ?? nil)?.items ?? []
        refreshedAt = MultiplayerTime.parse(((try? values.decodeIfPresent(String.self, forKey: .refreshedAt)) ?? nil) ?? "")
    }

    /// This Mac is on no tailnet, by the tailnet source's own word.
    var notOnTailnet: Bool { sources.contains(where: \.saysNotOnTailnet) }
}

// MARK: - Join checklist

/// Where the server's own sign-in stands, for a relay that is in the list.
enum MultiplayerJoinSignIn: Equatable, Sendable {
    case idle
    case waitingForBrowser
    case failed(String)
}

/// The four steps between finding a relay and being a member of it, for one relay as it stands.
/// The steps complete in order; at most one waits on the person, and `action` is what it offers.
struct MultiplayerJoinChecklist: Equatable {
    enum Stage: Int, CaseIterable, Identifiable, Sendable {
        case reachable, certificate, signIn, membership

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .reachable: "Reachable"
            case .certificate: "Certificate trusted"
            case .signIn: "Signed in"
            case .membership: "Membership"
            }
        }
    }

    enum Mark: Equatable, Sendable {
        case done
        /// The step the checklist stands at.
        case current
        /// A later step: nothing to do until the ones before it pass.
        case waiting
        case failed

        /// The step mark's value: a tick, a cross, or the number.
        var passed: Bool? {
            switch self {
            case .done: true
            case .failed: false
            case .current, .waiting: nil
            }
        }
    }

    /// The one thing the person can do now.
    enum Action: Equatable, Sendable {
        case joinTailnet
        case confirmFingerprint
        case signIn
        /// Every step passed: open the server it became.
        case openServer(String)

        var title: String {
            switch self {
            case .joinTailnet: "Join a tailnet"
            case .confirmFingerprint: "Confirm fingerprint"
            case .signIn: "Sign in"
            case .openServer: "Open server"
            }
        }

        /// The step the action belongs to.
        var stage: Stage {
            switch self {
            case .joinTailnet: .reachable
            case .confirmFingerprint: .certificate
            case .signIn: .signIn
            case .openServer: .membership
            }
        }
    }

    struct Step: Equatable, Identifiable {
        let stage: Stage
        let mark: Mark
        let detail: String

        var id: Int { stage.rawValue }
    }

    let steps: [Step]
    let action: Action?
    /// The one step left, in a line.
    let hint: String
    /// The fingerprint to compare, only while the certificate waits for the person's Confirm.
    let fingerprint: String?
    /// Whether the fingerprint the relay advertises matches the observed one. A hint, drawn beside
    /// the fingerprint; nil when the relay advertised none.
    let advertisedMatches: Bool?

    func step(_ stage: Stage) -> Step { steps[stage.rawValue] }

    /// The step the checklist stands at, or nil when every step passed.
    var standing: Stage? { steps.first { $0.mark != .done }?.stage }

    init(relay: MultiplayerDiscoveredRelay, server: MultiplayerServerSummary? = nil,
         signIn: MultiplayerJoinSignIn = .idle, notOnTailnet: Bool = false) {
        // The saved server is fresher than the discovery row: a join answers with it at once.
        let standing: MultiplayerRelayNext = server.map { $0.signedIn ? .done : .signIn } ?? relay.step
        let offersTailnet = standing == .unreachable && notOnTailnet && relay.looksLikeTailnet
        let contact = MultiplayerText.clean(relay.adminContact, limit: 120)
        let ask = contact.isEmpty ? "Ask the relay’s admin." : "Ask \(contact)."

        // 1. Reachable
        let reachable: Step
        switch standing {
        case .unreachable:
            reachable = Step(stage: .reachable, mark: .failed,
                             detail: offersTailnet ? "This Mac isn’t on a tailnet. Join one to reach this relay."
                                                   : relay.unreachableReason)
        default:
            reachable = relay.reachable
                ? Step(stage: .reachable, mark: .done, detail: "Answers at \(relay.host).")
                : Step(stage: .reachable, mark: .failed, detail: relay.unreachableReason)
        }

        // 2. Certificate trusted
        let certificate: Step
        var fingerprint: String?
        switch standing {
        case .unreachable:
            certificate = Step(stage: .certificate, mark: .waiting, detail: "")
        case .confirm:
            fingerprint = relay.shownFingerprint
            certificate = Step(stage: .certificate, mark: .current,
                               detail: fingerprint == nil ? "The relay’s certificate couldn’t be read. Refresh to check again."
                                   : "Compare this fingerprint with the relay’s admin before you confirm it.")
        default:
            let how: String
            if relay.isTailnetVerified {
                let node = MultiplayerText.clean(relay.tailnetNode, limit: 80)
                how = node.isEmpty ? "Verified on your tailnet." : "Verified on your tailnet as \(node)."
            } else if relay.systemTrusted {
                how = "Trusted by macOS."
            } else {
                how = "You confirmed its fingerprint."
            }
            certificate = Step(stage: .certificate, mark: .done, detail: how)
        }

        // 3. Signed in
        let signedIn: Step
        var signInWaits = false
        switch standing {
        case .unreachable, .confirm:
            signedIn = Step(stage: .signIn, mark: .waiting, detail: "")
        case .done:
            let handle = server?.handle.multiplayerDisplay ?? ""
            signedIn = Step(stage: .signIn, mark: .done, detail: handle.isEmpty ? "Signed in." : "Signed in as \(handle).")
        default:
            switch signIn {
            case .waitingForBrowser:
                signInWaits = true
                signedIn = Step(stage: .signIn, mark: .current, detail: "Finish signing in in your browser.")
            case .failed(let reason):
                signedIn = Step(stage: .signIn, mark: .failed, detail: reason)
            case .idle:
                let issuer = MultiplayerServerAddress.host(relay.issuer).multiplayerDisplay
                signedIn = Step(stage: .signIn, mark: .current,
                                detail: issuer.isEmpty ? "Your browser opens so you can sign in."
                                                       : "Your browser opens so you can sign in with \(issuer).")
            }
        }

        // 4. Membership
        let isMember = standing == .done
        let membershipDetail: String
        switch relay.membership {
        case .open:
            membershipDetail = isMember ? "Open. You’re a member." : "Open. Anyone who signs in is a member."
        case .allowlist:
            membershipDetail = isMember ? "Allowlist. Your email is on the list."
                : "Allowlist. The admin must add your email before you can sign in. \(ask)"
        case .invite:
            membershipDetail = isMember ? "Invite only. You’re a member."
                : "Invite only. You need an invite link or the admin’s approval. \(ask)"
        case .unknown:
            membershipDetail = isMember ? "You’re a member." : standing == .unreachable ? ""
                : "This relay didn’t say how it admits people."
        }
        let membership = Step(stage: .membership, mark: isMember ? .done : .waiting, detail: membershipDetail)

        steps = [reachable, certificate, signedIn, membership]
        self.fingerprint = fingerprint
        advertisedMatches = fingerprint == nil ? nil : relay.advertisedPinMatches

        switch standing {
        case .unreachable:
            action = offersTailnet ? .joinTailnet : nil
            hint = offersTailnet ? "Join a tailnet to reach this relay." : "Waiting for the relay to answer."
        case .confirm:
            action = fingerprint == nil || relay.pin.isEmpty ? nil : .confirmFingerprint
            hint = "Confirm the fingerprint to add this relay."
        case .done:
            let id = server?.id ?? relay.serverID
            action = id.isEmpty ? nil : .openServer(id)
            hint = "You’re in."
        default:
            action = signInWaits ? nil : .signIn
            if signInWaits {
                hint = "Finish signing in in your browser."
            } else {
                switch relay.membership {
                case .allowlist: hint = "Sign in once the admin has added your email."
                case .invite: hint = "Sign in once you have an invite or the admin’s approval."
                case .open, .unknown: hint = "Sign in to finish."
                }
            }
        }
    }
}

// MARK: - Preferences

/// What discovery keeps between launches: the notification switch and the relays already notified.
/// The app's model keeps them in the app's defaults; any other model keeps them in memory.
struct MultiplayerDiscoveryStore {
    static let notifyKey = "network.relaysNearby.notify"
    static let notifiedKey = "network.relaysNearby.notified"
    /// The newest relay IDs kept, so the record stays small.
    static let notifiedLimit = 200

    let defaults: UserDefaults?

    /// A store that keeps nothing past the model that holds it.
    static var scratch: MultiplayerDiscoveryStore { MultiplayerDiscoveryStore(defaults: nil) }

    var notifies: Bool { defaults?.object(forKey: Self.notifyKey) as? Bool ?? true }
    func set(notifies: Bool) { defaults?.set(notifies, forKey: Self.notifyKey) }

    var notified: [String] { defaults?.stringArray(forKey: Self.notifiedKey) ?? [] }
    func set(notified: [String]) { defaults?.set(Array(notified.suffix(Self.notifiedLimit)), forKey: Self.notifiedKey) }
}

// MARK: - Model

/// The relays nearby, as the tray sees them. It reads `relay-discover` after each server list (so
/// on the tray's own cadence, open or closed), marks relays seen while the list is on screen,
/// notifies once for each new one, and runs the join: Confirm, then the server's own sign-in.
@MainActor @Observable
final class MultiplayerDiscoveryModel {
    /// Every relay the device agent listed, the added ones included.
    private(set) var relays: [MultiplayerDiscoveredRelay] = []
    private(set) var sources: [MultiplayerDiscoverySource] = []
    private(set) var refreshedAt: Date?
    /// A `relay-discover` reply has arrived at least once.
    private(set) var hasLoaded = false
    private(set) var isReading = false
    /// Why the relays couldn't be listed. A list already on show stays.
    private(set) var failure: String?
    /// The relay whose checklist is open.
    private(set) var selected: String?
    /// "Notify me about relays nearby".
    var notifies: Bool {
        didSet { if notifies != oldValue { store.set(notifies: notifies) } }
    }

    @ObservationIgnored weak var tray: MultiplayerModel?
    private let client: MultiplayerClient?
    private let store: MultiplayerDiscoveryStore
    @ObservationIgnored private var notified: [String]
    /// The lists on screen. While there is one, a new relay is seen, not notified.
    @ObservationIgnored private var lists = 0
    @ObservationIgnored private(set) var readTask: Task<Void, Never>?
    @ObservationIgnored private(set) var seenTask: Task<Void, Never>?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var seenToken = 0
    /// The server each relay became when it was joined here, by relay ID. A discovery pass made
    /// before the join still says "not added"; this keeps the row with its server until it agrees.
    private var joinedServers: [String: String] = [:]

    init(client: MultiplayerClient?, store: MultiplayerDiscoveryStore = .scratch) {
        self.client = client
        self.store = store
        notifies = store.notifies
        notified = store.notified
    }

    // MARK: Derived values

    /// The relays the list shows: not yet in the server list, plus the one whose checklist is
    /// open. The ones that answer come first; within each, by name, so rows keep their order.
    var nearby: [MultiplayerDiscoveredRelay] {
        Self.ordered(relays.filter { !isAdded($0) || $0.id == selected })
    }

    /// Relays the person has not seen. The menu bar label and the Network tab count them.
    var newCount: Int { relays.filter { $0.isNew && !isAdded($0) }.count }

    var selectedRelay: MultiplayerDiscoveredRelay? { selected.flatMap { id in relays.first { $0.id == id } } }

    var notOnTailnet: Bool { sources.contains(where: \.saysNotOnTailnet) }

    /// The saved server a relay became, by the device agent's word or by address.
    func server(for relay: MultiplayerDiscoveredRelay) -> MultiplayerServerSummary? {
        guard let tray else { return nil }
        if !relay.serverID.isEmpty, let saved = tray.server(relay.serverID) { return saved }
        if let id = joinedServers[relay.id], let saved = tray.server(id) { return saved }
        let host = MultiplayerServerAddress.host(relay.url).lowercased()
        guard !host.isEmpty else { return nil }
        return tray.servers.first { MultiplayerServerAddress.host($0.url).lowercased() == host }
    }

    private func isAdded(_ relay: MultiplayerDiscoveredRelay) -> Bool { relay.added || server(for: relay) != nil }

    /// The checklist for a relay as it stands now.
    func checklist(for relay: MultiplayerDiscoveredRelay) -> MultiplayerJoinChecklist {
        let saved = server(for: relay)
        var signIn = MultiplayerJoinSignIn.idle
        if let saved, !saved.signedIn, let session = tray?.session(saved.id) {
            switch session.presence {
            case .waitingForBrowser: signIn = .waitingForBrowser
            case .signInIncomplete(let detail): signIn = .failed(detail ?? "The sign-in didn’t finish. Try again.")
            default:
                if let failed = session.actionFailure, failed.command == .login { signIn = .failed(failed.message) }
            }
        }
        return MultiplayerJoinChecklist(relay: relay, server: saved, signIn: signIn, notOnTailnet: notOnTailnet)
    }

    static func ordered(_ relays: [MultiplayerDiscoveredRelay]) -> [MultiplayerDiscoveredRelay] {
        relays.sorted { left, right in
            if left.reachable != right.reachable { return left.reachable }
            let order = left.displayName.localizedStandardCompare(right.displayName)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }

    // MARK: Reads

    /// Reads the relays. `force` asks the device agent for a fresh pass instead of its last one.
    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never>? {
        guard let client, readTask == nil else { return readTask }
        let token = token
        isReading = true
        let task = Task {
            let answer: Result<MultiplayerDiscovery, MultiplayerFailure>
            do { answer = .success(try await client.discoverRelays(refresh: force)) } catch { answer = .failure(.from(error)) }
            guard token == self.token else { return }
            self.readTask = nil
            self.isReading = false
            switch answer {
            case .success(let next): self.take(next)
            case .failure(.cancelled): break
            case .failure(let reason):
                self.failure = MultiplayerSentence.join("Couldn’t look for relays.", reason.message)
            }
        }
        readTask = task
        return task
    }

    private func take(_ next: MultiplayerDiscovery) {
        relays = next.relays
        sources = next.sources
        refreshedAt = next.refreshedAt
        hasLoaded = true
        failure = nil
        if let selected, !relays.contains(where: { $0.id == selected }) { self.selected = nil }
        if lists > 0 { markSeen() } else { announce() }
    }

    /// The panel closed: the read in flight stops. Seen marks already sent are left to finish.
    func cancel() {
        guard readTask != nil else { return }
        token &+= 1
        readTask?.cancel()
        readTask = nil
        isReading = false
    }

    // MARK: Seen and notified

    /// A Relays nearby list came on screen: what it shows is seen.
    func listAppeared() {
        lists += 1
        markSeen()
    }

    func listDisappeared() { lists = max(lists - 1, 0) }

    /// Tells the device agent the listed new relays were seen. They stop counting at once.
    @discardableResult
    func markSeen() -> Task<Void, Never>? {
        let ids = relays.filter(\.isNew).map(\.id)
        guard let client, !ids.isEmpty else { return nil }
        for index in relays.indices where relays[index].isNew { relays[index].isNew = false }
        // A relay seen in the list needs no notification later.
        remember(ids)
        let earlier = seenTask
        seenToken &+= 1
        let token = seenToken
        let task = Task {
            await earlier?.value
            try? await client.markRelaysSeen(ids)
            if token == self.seenToken { self.seenTask = nil }
        }
        seenTask = task
        return task
    }

    /// Posts one notification for each new relay not notified before. With the switch off, or in
    /// Do not disturb, nothing is posted; a relay passed over with the switch off stays passed over.
    private func announce() {
        let fresh = relays.filter { $0.isNew && !isAdded($0) && !notified.contains($0.id) }
        guard !fresh.isEmpty else { return }
        guard notifies else {
            remember(fresh.map(\.id))
            return
        }
        guard let notifier = tray?.notifier, tray?.isDoNotDisturb != true else { return }
        remember(fresh.map(\.id))
        let posts = fresh.map { (id: "relay-\($0.id)", title: "Relay nearby", body: Self.notice(for: $0)) }
        Task {
            for post in posts { await notifier.post(id: post.id, title: post.title, body: post.body) }
        }
    }

    /// "studio-relay is on your tailnet. Open the network tray to join it."
    static func notice(for relay: MultiplayerDiscoveredRelay) -> String {
        "\(relay.displayName) is \(relay.source.place). Open the network tray to join it."
    }

    private func remember(_ ids: [String]) {
        let added = ids.filter { !notified.contains($0) }
        guard !added.isEmpty else { return }
        notified = Array((notified + added).suffix(MultiplayerDiscoveryStore.notifiedLimit))
        store.set(notified: notified)
    }

    // MARK: Intents

    /// Opens a relay's checklist, or closes it when it is the one open.
    func select(_ id: String?) {
        selected = selected == id ? nil : id
    }

    /// Whether a join step can start now: one server action at a time.
    var canAct: Bool { client != nil && tray?.isBusy == false }

    /// The person confirmed the fingerprint on show: the relay is added with the pin the device
    /// agent observed. The pin a relay advertises is never what is sent.
    @discardableResult
    func confirmFingerprint(_ relay: MultiplayerDiscoveredRelay) -> Task<Void, Never>? {
        guard relay.step == .confirm, !relay.pin.isEmpty, server(for: relay) == nil else { return nil }
        return join(relay, pin: relay.pin, thenSignIn: false)
    }

    /// Signs in to the relay. A relay verified on the tailnet or trusted by macOS is added first,
    /// with no pin; one that still needs its fingerprint confirmed is not touched.
    @discardableResult
    func signIn(_ relay: MultiplayerDiscoveredRelay) -> Task<Void, Never>? {
        if let saved = server(for: relay) {
            guard !saved.signedIn else { return nil }
            tray?.signIn(saved.id)
            return nil
        }
        guard relay.step == .add else { return nil }
        return join(relay, pin: nil, thenSignIn: true)
    }

    private func join(_ relay: MultiplayerDiscoveredRelay, pin: String?, thenSignIn: Bool) -> Task<Void, Never>? {
        guard let tray else { return nil }
        let name = relay.displayName
        return tray.act("Adding \(name)…", failing: "Couldn’t add \(name).") { client in
            let saved = try await client.joinRelay(id: relay.id, pin: pin)
            tray.merge(saved)
            self.joined(relay.id, as: saved)
            if thenSignIn { tray.signIn(saved.id) } else { tray.post(notice: "Added \(saved.displayName). Sign in to finish.") }
        }
    }

    /// The row as the join left it, ahead of the next discovery read.
    private func joined(_ id: String, as saved: MultiplayerServerSummary) {
        joinedServers[id] = saved.id
        guard let index = relays.firstIndex(where: { $0.id == id }) else { return }
        relays[index].added = true
        relays[index].serverID = saved.id
        relays[index].isNew = false
        relays[index].next = saved.signedIn ? .done : .signIn
    }

    // MARK: Testing support

    /// Waits until no discovery read or seen mark is in flight.
    func settle() async {
        while let task = readTask ?? seenTask { await task.value }
    }
}
