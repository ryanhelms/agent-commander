import Observation
import SwiftUI

// TAILNET (design/COMMANDER-NETWORK-TAILNET.md, "Device side: the tray UI").
// The Add server form's Tailnet band: the relays this Mac can see on its Headscale or Tailscale
// network, or the way onto one. The device agent runs the local `tailscale` CLI; nothing here
// talks to a control server. Choosing a relay only fills the address and starts the same health
// check as typing it, so a listed relay is pinned and saved exactly like any other.
//
// ATOMIC LEVELS in this file:
//   values     MultiplayerTailnetStatus, MultiplayerTailnetRelay, MultiplayerTailnetDraft
//   model      MultiplayerTailnetModel (owns the three verbs and the login poll)
//   molecules  MultiplayerTailnetRelayRow, MultiplayerSecretField
//   organism   MultiplayerTailnetBand

// MARK: - Contract

/// A `tailnet-status` reply, and what `tailnet-join` answers. Every key may be missing: a browser
/// join answers only `{"state": "needsLogin", "authURL": …}`.
struct MultiplayerTailnetStatus: Decodable, Equatable, Sendable {
    /// One node: this Mac.
    struct Node: Decodable, Equatable, Sendable {
        let hostName: String
        let dnsName: String
        let addresses: [String]
        let online: Bool

        private enum CodingKeys: String, CodingKey { case hostName, dnsName, addresses, online }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            hostName = (try? values.decodeIfPresent(String.self, forKey: .hostName)) ?? ""
            dnsName = (try? values.decodeIfPresent(String.self, forKey: .dnsName)) ?? ""
            addresses = (try? values.decodeIfPresent([String].self, forKey: .addresses)) ?? []
            online = (try? values.decodeIfPresent(Bool.self, forKey: .online)) ?? false
        }
    }

    /// The Tailscale CLI was found on this Mac.
    var installed: Bool
    var backendState: String
    var running: Bool
    var tailnet: String
    var magicDNSSuffix: String
    var node: Node?
    /// The page that finishes a browser login, while one is offered.
    var authURL: String
    /// A browser login the device agent started is still open.
    var loginPending: Bool

    private enum CodingKeys: String, CodingKey {
        case installed, backendState, running, tailnet, magicDNSSuffix, authURL, loginPending, state
        case node = "self"
    }

    init(installed: Bool = true, backendState: String = "", running: Bool = false, tailnet: String = "",
         magicDNSSuffix: String = "", authURL: String = "", loginPending: Bool = false) {
        self.installed = installed
        self.backendState = backendState
        self.running = running
        self.tailnet = tailnet
        self.magicDNSSuffix = magicDNSSuffix
        self.authURL = authURL
        self.loginPending = loginPending
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { ((try? values.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
        func flag(_ key: CodingKeys) -> Bool? { (try? values.decodeIfPresent(Bool.self, forKey: key)) ?? nil }
        // A browser join's short answer: the login page is open and the login goes on.
        let needsLogin = text(.state) == "needsLogin"
        backendState = text(.backendState)
        running = flag(.running) ?? (backendState == "Running")
        installed = flag(.installed) ?? (needsLogin || running || !backendState.isEmpty)
        tailnet = text(.tailnet)
        magicDNSSuffix = text(.magicDNSSuffix)
        node = (try? values.decodeIfPresent(Node.self, forKey: .node)) ?? nil
        authURL = text(.authURL)
        loginPending = flag(.loginPending) ?? needsLogin
    }

    /// The name to show for the tailnet: its own name, else its MagicDNS suffix.
    var displayName: String {
        let name = tailnet.isEmpty ? magicDNSSuffix : tailnet
        return name.isEmpty ? "This Mac’s tailnet" : name
    }

    /// The login page, only when it is an address the system can open in a browser.
    var loginPage: URL? {
        guard let url = URL(string: authURL), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}

/// One peer tagged as a relay, from `tailnet-relays`.
struct MultiplayerTailnetRelay: Decodable, Equatable, Sendable, Identifiable {
    let name: String
    let dnsName: String
    /// The address the health check and `server-add` take.
    let url: String
    let addresses: [String]
    let online: Bool
    let os: String
    /// The URL is already in the server list.
    let added: Bool

    var id: String { url.isEmpty ? dnsName : url }

    private enum CodingKeys: String, CodingKey { case name, dnsName, url, addresses, online, os, added }

    init(name: String, dnsName: String, url: String, addresses: [String] = [], online: Bool = true,
         os: String = "", added: Bool = false) {
        self.name = name
        self.dnsName = dnsName
        self.url = url
        self.addresses = addresses
        self.online = online
        self.os = os
        self.added = added
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { ((try? values.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
        let dns = text(.dnsName)
        let address = text(.url)
        dnsName = dns
        url = address.isEmpty && !dns.isEmpty ? "https://\(dns)" : address
        name = text(.name).isEmpty ? (dns.split(separator: ".").first.map(String.init) ?? dns) : text(.name)
        addresses = (try? values.decodeIfPresent([String].self, forKey: .addresses)) ?? []
        online = ((try? values.decodeIfPresent(Bool.self, forKey: .online)) ?? nil) ?? false
        os = text(.os)
        added = ((try? values.decodeIfPresent(Bool.self, forKey: .added)) ?? nil) ?? false
    }
}

struct MultiplayerTailnetRelayList: Decodable {
    let relays: [MultiplayerTailnetRelay]

    private enum CodingKeys: String, CodingKey { case relays }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        relays = ((try? values.decodeIfPresent([MultiplayerTailnetRelay].self, forKey: .relays)) ?? nil) ?? []
    }
}

// MARK: - Form values

/// What the join form holds. The key is cleared as soon as it is sent.
struct MultiplayerTailnetDraft: Equatable {
    enum Method: String, CaseIterable, Hashable, Sendable {
        case browser, authKey

        var title: String {
            switch self {
            case .browser: "Sign in with browser"
            case .authKey: "Use an auth key"
            }
        }
    }

    var loginServer = ""
    var method = Method.browser
    var authKey = ""

    var trimmedLoginServer: String { loginServer.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAuthKey: String { authKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the login server can't be sent, once something is typed. The device agent checks again.
    var loginServerProblem: String? {
        let text = trimmedLoginServer
        guard !text.isEmpty else { return nil }
        guard let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.query == nil, parts.fragment == nil else {
            return "Enter an https:// address, such as https://headscale.example."
        }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard parts.scheme == "https" || (parts.scheme == "http" && local) else {
            return "The login server must be an https:// address."
        }
        return nil
    }

    var canJoin: Bool {
        !trimmedLoginServer.isEmpty && loginServerProblem == nil && (method == .browser || !trimmedAuthKey.isEmpty)
    }
}

/// What the Tailnet band shows.
enum MultiplayerTailnetPhase: Equatable {
    /// Before the first `tailnet-status` reply.
    case reading
    /// The status couldn't be read.
    case failed(String)
    /// The Tailscale CLI isn't on this Mac.
    case missing
    /// Installed and not on a tailnet: the join form.
    case signedOut
    /// A browser login is open. The page's address, once the CLI has offered one.
    case pending(URL?)
    /// On a tailnet. The relays are nil until `tailnet-relays` answers.
    case running(name: String, relays: [MultiplayerTailnetRelay]?, failure: String?)
}

// MARK: - Model

/// The tailnet as the Add server form sees it. It reads `tailnet-status` while a form is on
/// screen, lists the relays once this Mac is on a tailnet, and polls while a browser login is open.
/// Every read stops when the last form leaves.
@MainActor @Observable
final class MultiplayerTailnetModel {
    private(set) var status: MultiplayerTailnetStatus?
    /// Nil until `tailnet-relays` has answered for the tailnet this Mac is on.
    private(set) var relays: [MultiplayerTailnetRelay]?
    /// Why the status couldn't be read.
    private(set) var failure: String?
    /// Why the relays couldn't be listed.
    private(set) var relaysFailure: String?
    /// Why the last join was refused.
    private(set) var joinFailure: String?
    private(set) var isJoining = false
    private(set) var isReading = false
    /// The tray page's join form. A host keeps its own.
    var draft = MultiplayerTailnetDraft()

    private let client: MultiplayerClient?
    private let pollInterval: Duration
    @ObservationIgnored private var forms = 0
    @ObservationIgnored private(set) var readTask: Task<Void, Never>?
    @ObservationIgnored private(set) var joinTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pollTask: Task<Void, Never>?
    @ObservationIgnored private var token = 0

    init(client: MultiplayerClient?, pollInterval: Duration = .seconds(2)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    /// True while a login poll is scheduled.
    var isPolling: Bool { pollTask != nil }

    var phase: MultiplayerTailnetPhase {
        guard let status else { return failure.map { .failed($0) } ?? .reading }
        if !status.installed { return .missing }
        if status.running { return .running(name: status.displayName, relays: relays, failure: relaysFailure) }
        if status.loginPending { return .pending(status.loginPage) }
        return .signedOut
    }

    // MARK: Intents

    /// An Add server form came on screen.
    func formAppeared() {
        forms += 1
        if forms == 1 { refresh() }
    }

    /// An Add server form left. With none left every read and the login poll stop, and a typed key
    /// is dropped.
    func formDisappeared() {
        guard forms > 0 else { return }
        forms -= 1
        guard forms == 0 else { return }
        stop()
        draft.authKey = ""
        joinFailure = nil
    }

    /// Reads the status again, then the relays when this Mac is on a tailnet.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard let client else {
            failure = "The network helper isn’t available."
            return nil
        }
        guard forms > 0, readTask == nil, !isJoining else { return readTask }
        let token = token
        isReading = true
        let task = Task {
            let answer = await Self.read(client)
            guard token == self.token else { return }
            self.readTask = nil
            self.isReading = false
            switch answer {
            case .success(let next): await self.take(next, with: client, token: token)
            case .failure(.cancelled): break
            case .failure(let reason):
                // A status already on show stays; only a first read has nothing else to say.
                self.failure = MultiplayerSentence.join("Couldn’t check Tailscale.", reason.message)
                if self.status?.loginPending == true { self.schedulePoll() }
            }
        }
        readTask = task
        return task
    }

    /// Joins the tailnet the draft names. A browser login answers with the page to finish it on.
    @discardableResult
    func join(_ draft: MultiplayerTailnetDraft) -> Task<Void, Never>? {
        guard let client, forms > 0, !isJoining, draft.canJoin else { return nil }
        readTask?.cancel()
        readTask = nil
        pollTask?.cancel()
        pollTask = nil
        token &+= 1
        let token = token
        isReading = false
        isJoining = true
        joinFailure = nil
        let server = draft.trimmedLoginServer
        let key = draft.method == .authKey ? draft.trimmedAuthKey : nil
        // The key leaves the form as it is sent.
        self.draft.authKey = ""
        let task = Task {
            let answer: Result<MultiplayerTailnetStatus, MultiplayerFailure>
            do { answer = .success(try await client.joinTailnet(loginServer: server, authKey: key)) }
            catch { answer = .failure(.from(error)) }
            guard token == self.token else { return }
            self.joinTask = nil
            self.isJoining = false
            switch answer {
            case .success(let next): await self.take(next, with: client, token: token)
            case .failure(.cancelled): break
            case .failure(let reason):
                self.joinFailure = MultiplayerSentence.join("Couldn’t join the tailnet.", reason.message)
                // The CLI may have acted before the failure, so read where this Mac stands now.
                self.refresh()
            }
        }
        joinTask = task
        return task
    }

    func dismissJoinFailure() { joinFailure = nil }

    // MARK: Reads

    private static func read(_ client: MultiplayerClient) async -> Result<MultiplayerTailnetStatus, MultiplayerFailure> {
        do { return .success(try await client.tailnetStatus()) } catch { return .failure(.from(error)) }
    }

    /// Takes a status. On a tailnet it lists the relays; with a login open it schedules the next read.
    private func take(_ next: MultiplayerTailnetStatus, with client: MultiplayerClient, token: Int) async {
        let wasRunning = status?.running == true
        status = next
        failure = nil
        guard next.running else {
            relays = nil
            relaysFailure = nil
            if next.installed, next.loginPending { schedulePoll() }
            return
        }
        joinFailure = nil
        if !wasRunning { relays = nil }
        do {
            let listed = try await client.tailnetRelays()
            guard token == self.token else { return }
            relays = Self.ordered(listed)
            relaysFailure = nil
        } catch {
            guard token == self.token else { return }
            let reason = MultiplayerFailure.from(error)
            if reason != .cancelled {
                relaysFailure = MultiplayerSentence.join("Couldn’t list the relays.", reason.message)
            }
        }
    }

    /// Relays you can add come first, the ones that answer before the ones that don't, then the
    /// ones already in the list. Within each, by name, so the list keeps its order between reads.
    static func ordered(_ relays: [MultiplayerTailnetRelay]) -> [MultiplayerTailnetRelay] {
        func rank(_ relay: MultiplayerTailnetRelay) -> Int { relay.added ? 2 : relay.online ? 0 : 1 }
        return relays.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The next status read while a browser login is open, one interval from now.
    private func schedulePoll() {
        guard forms > 0, pollTask == nil else { return }
        let token = token
        let interval = pollInterval
        pollTask = Task {
            try? await Task.sleep(for: interval)
            guard token == self.token, !Task.isCancelled else { return }
            self.pollTask = nil
            self.refresh()
        }
    }

    private func stop() {
        token &+= 1
        readTask?.cancel()
        readTask = nil
        joinTask?.cancel()
        joinTask = nil
        pollTask?.cancel()
        pollTask = nil
        isReading = false
        isJoining = false
    }

    /// Waits until no read or join is in flight. A scheduled poll is not waited for.
    func settle() async {
        while let task = joinTask ?? readTask { await task.value }
    }
}

// MARK: - Molecules

/// One relay on the tailnet: its mark, its name, its MagicDNS name, and whether it answers. The
/// row is one button that fills the address and starts the check. A relay already in the server
/// list shows an Added badge and is plain text.
struct MultiplayerTailnetRelayRow: View {
    let relay: MultiplayerTailnetRelay
    /// The address field holds this relay's URL.
    let isChosen: Bool
    let isEnabled: Bool
    let onChoose: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        if relay.added {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(relay.name), \(relay.dnsName), already in your list")
        } else {
            Button(action: onChoose) { content.contentShape(Rectangle()) }
                .buttonStyle(MultiplayerRowButtonStyle())
                .disabled(!isEnabled)
                .help("Check \(relay.dnsName)")
                .accessibilityLabel("\(relay.name), \(relay.dnsName), \(relay.online ? "online" : "offline")")
                .accessibilityHint("Fills in this relay’s address and checks it")
                .accessibilityAddTraits(isChosen ? .isSelected : [])
        }
    }

    private var content: some View {
        HStack(spacing: Space.s) {
            MultiplayerMark(symbol: "server.rack", tone: relay.added ? .neutral : relay.online ? .working : .neutral)
            VStack(alignment: .leading, spacing: 1) {
                Text(relay.name.multiplayerDisplay)
                    .font(MultiplayerTheme.name)
                    .foregroundStyle(relay.added ? MultiplayerTheme.secondary : MultiplayerTheme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(relay.dnsName.multiplayerDisplay)
                    .font(MultiplayerTheme.mono)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if relay.added {
                MultiplayerBadge(text: "Added", symbol: "checkmark")
            } else {
                MultiplayerStateLabel(lamp: relay.online ? .on : .off, text: relay.online ? "Online" : "Offline",
                                      tone: relay.online ? .working : .neutral)
            }
        }
        .padding(.horizontal, Space.s)
        .frame(minHeight: theme.space.rowHeight)
        .padding(.vertical, 3)
        .background { if isChosen, !relay.added { Rectangle().fill(MultiplayerTheme.selection) } }
        .overlay(alignment: .leading) {
            if isChosen, !relay.added { Rectangle().fill(MultiplayerTheme.focus).frame(width: theme.line.selectedMarker) }
        }
    }
}

/// A single-line field for a secret, in the field box: the text is never drawn.
struct MultiplayerSecretField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var isFocused = false

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(MultiplayerTheme.foreground)
            .multiplayerFieldBox(focused: isFocused)
            .privacySensitive()
            .accessibilityLabel(label)
    }
}

// MARK: - Organism

/// The Add server form's Tailnet band. It never stands in the way of the address field under it:
/// every state is a note, a list or a small form of its own.
struct MultiplayerTailnetBand: View {
    let phase: MultiplayerTailnetPhase
    @Binding var draft: MultiplayerTailnetDraft
    /// The address in the form's field, to mark the relay it came from.
    let address: String
    let isJoining: Bool
    let isReading: Bool
    let joinFailure: String?
    /// Whether a relay can be checked now.
    let canChoose: Bool
    let onChoose: (MultiplayerTailnetRelay) -> Void
    let onJoin: () -> Void
    let onRefresh: () -> Void
    var onCopy: (String) -> Void = { MultiplayerHashChip.copy($0) }

    static let download = URL(string: "https://tailscale.com/download")!

    @Environment(\.openURL) private var openURL
    @FocusState private var focus: Field?
    private enum Field { case loginServer, authKey }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Tailnet", count: count) { state }
                content
            }
        }
    }

    private var count: String? {
        if case .running(_, let relays?, _) = phase { return "\(relays.count)" }
        return nil
    }

    @ViewBuilder private var state: some View {
        switch phase {
        case .reading:
            MultiplayerSpinner().accessibilityLabel("Checking Tailscale")
        case .failed:
            MultiplayerStateLabel(lamp: .error, text: "Not checked", tone: .failure)
        case .missing:
            MultiplayerStateLabel(lamp: .off, text: "Not installed")
        case .signedOut:
            MultiplayerStateLabel(lamp: .off, text: "Not joined")
        case .pending:
            MultiplayerStateLabel(lamp: .waiting, text: "Waiting for sign-in", tone: .attention)
        case .running(let name, _, _):
            MultiplayerStateLabel(lamp: .on, text: name.multiplayerDisplay, tone: .working)
                .help("This Mac is on \(name.multiplayerDisplay)")
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .reading:
            note("Checking Tailscale on this Mac…")
        case .failed(let message):
            problem(message)
            note("You can still type an address below.")
            Button("Try again", action: onRefresh)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(isReading)
        case .missing:
            note("Tailscale isn’t installed on this Mac. Install it to find relays on your tailnet, or type an address below.")
            HStack(spacing: Space.s) {
                Button { openURL(Self.download) } label: { leaving("Get Tailscale") }
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .help("Opens tailscale.com/download in your browser")
                    .accessibilityHint("Opens Tailscale’s download page in your browser")
                Button("Check again", action: onRefresh)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(isReading)
            }
        case .signedOut:
            joinForm
        case .pending(let page):
            pending(page)
        case .running(_, let relays, let failure):
            running(relays, failure: failure)
        }
    }

    // MARK: Running

    @ViewBuilder private func running(_ relays: [MultiplayerTailnetRelay]?, failure: String?) -> some View {
        if let failure {
            problem(failure)
            note("You can still type an address below.")
            Button("Try again", action: onRefresh)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(isReading)
        } else if let relays {
            if relays.isEmpty {
                note("No relays on this tailnet yet. A relay shows here once its node is tagged tag:relay.")
                Button("Check again", action: onRefresh)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(isReading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(relays.enumerated()), id: \.element.id) { index, relay in
                        if index > 0 {
                            Rectangle().fill(MultiplayerTheme.hair).frame(height: 1).padding(.horizontal, Space.s)
                        }
                        MultiplayerTailnetRelayRow(relay: relay, isChosen: Self.matches(address, relay),
                                                   isEnabled: canChoose) { onChoose(relay) }
                    }
                }
                .padding(.horizontal, -Space.s)
                note(relays.allSatisfy(\.added) ? "Every relay on this tailnet is in your list."
                                                 : "Choose a relay to fill in its address and check it.")
            }
        } else {
            note("Looking for relays…")
        }
    }

    /// Whether the address field holds this relay's URL, with or without the scheme.
    static func matches(_ address: String, _ relay: MultiplayerTailnetRelay) -> Bool {
        func bare(_ text: String) -> String {
            var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text.hasPrefix("https://") { text.removeFirst("https://".count) }
            while text.hasSuffix("/") { text.removeLast() }
            if text.hasSuffix(":443") { text.removeLast(4) }
            return text
        }
        let typed = bare(address)
        return !typed.isEmpty && typed == bare(relay.url)
    }

    // MARK: Join

    @ViewBuilder private var joinForm: some View {
        note("This Mac isn’t on a tailnet. Join one to find its relays, or type an address below.")
        if let joinFailure { problem(joinFailure) }
        MultiplayerField(label: "Login server", hint: "Your Headscale or Tailscale control server.",
                         problem: draft.loginServerProblem) {
            MultiplayerTextField(label: "Login server", placeholder: "https://headscale.example", text: $draft.loginServer,
                                 monospaced: true, isFocused: focus == .loginServer)
                .focused($focus, equals: .loginServer)
                .onSubmit { if canJoin { onJoin() } }
        }
        MultiplayerSegments(label: "How to sign in", options: MultiplayerTailnetDraft.Method.allCases,
                            title: \.title, selection: $draft.method)
        if draft.method == .authKey {
            MultiplayerField(label: "Auth key", hint: "Tailscale uses the key once. Commander doesn’t keep it.") {
                MultiplayerSecretField(label: "Auth key", placeholder: "Paste key", text: $draft.authKey,
                                       isFocused: focus == .authKey)
                    .focused($focus, equals: .authKey)
                    .onSubmit { if canJoin { onJoin() } }
            }
        } else {
            note("Your browser opens so you can sign in.")
        }
        HStack(spacing: Space.s) {
            Button("Join tailnet", action: onJoin)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(!canJoin)
            if isJoining {
                MultiplayerSpinner()
                Text("Joining…").font(MultiplayerTheme.state).foregroundStyle(MultiplayerTheme.focus)
            }
        }
        .disabled(isJoining)
    }

    private var canJoin: Bool { draft.canJoin && !isJoining }

    // MARK: Pending

    @ViewBuilder private func pending(_ page: URL?) -> some View {
        if let page {
            note("Finish signing in on the login page. This updates when this Mac joins.")
            MultiplayerCopyChip(label: "login", value: page.absoluteString, onCopy: onCopy)
            Button { openURL(page) } label: { leaving("Open login page") }
                .buttonStyle(MultiplayerTrayButtonStyle())
                .accessibilityHint("Opens the login page in your browser")
        } else {
            note("Waiting for Tailscale to offer its login page…")
        }
    }

    // MARK: Parts

    private func note(_ text: String) -> some View {
        Text(text)
            .font(MultiplayerTheme.sub)
            .foregroundStyle(.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problem(_ text: String) -> some View {
        Text(text)
            .font(MultiplayerTheme.sub)
            .foregroundStyle(MultiplayerTheme.failure)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// A button title for an action that leaves the app, with the same up-right arrow as a pull request row.
    private func leaving(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
        }
    }
}
