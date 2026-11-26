import SwiftUI

// ATOMIC LEVEL: Values (main-window Teams pages).
// Everything the full-size Teams pages show, as plain values, and everything they can ask for.
// A page takes a `TeamsPages` value and never reads a model. The design previews fill it with
// samples (TeamsPagesPreview.swift). The live window will fill it from the Teams model once that
// model offers reads the caller owns (TeamsPagesLive.swift, design/demos/main-window-5/TRAY-REQUESTS.md).
//
// The window owns what it shows: which band, card, group, host, item or search is open, every
// draft, every confirmation waiting for its second press, and what it read for them. None of it
// is the tray's route.
//
//   TeamsPlace           the place IDs that have a page
//   TeamsKey             "server/id", the key of anything that lives on a server
//   TeamsBand            the four bands of a workspace page
//   TeamsPagesContent    the teams state, as values
//   Teams…Row            one row of a page's table, built from the content
//   TeamsPagesSelection  the window's own selections
//   TeamsComposer        the form open on a page
//   TeamsConfirmation    the second press a page is waiting for
//   TeamsInstallDraft    a knowledge item and where installing it writes
//   TeamsPagesDrafts     the text and choices being edited
//   TeamsIntent          what a page can ask for
//   TeamsPageActions     the one boundary every teams action crosses, as async closures
//   TeamsPagesState      the window's state, and what each intent does to it
//   TeamsPages           content, selection, drafts and `send`, as a page receives them

enum TeamsPlace {
    /// Shown in the Workspaces group while the person works in no workspace.
    static let workspaces = LiveShell.workspaces
    static let groups = "teams.groups"
    static let hosts = "teams.hosts"
    static let knowledge = "teams.knowledge"
    static let directory = "teams.directory"
    static let admin = "teams.admin"

    /// The Team tools group, in order. Admin is listed only for an admin.
    static let tools = [groups, hosts, knowledge, directory, admin]

    static func workspace(_ id: String, on server: String) -> String { "team:\(TeamsKey.make(id, on: server))" }

    /// The `server/workspace` key of a workspace place.
    static func workspaceKey(of place: String) -> String? {
        place.hasPrefix("team:") ? String(place.dropFirst("team:".count)) : nil
    }

    static func hasPage(_ id: String) -> Bool { id == workspaces || tools.contains(id) || id.hasPrefix("team:") }

    static func title(_ id: String) -> String {
        switch id {
        case workspaces: "Workspaces"
        case groups: "Groups"
        case hosts: "Hosts"
        case knowledge: "Knowledge"
        case directory: "Directory"
        case admin: "Admin"
        default: ""
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case groups: "person.3"
        case hosts: "cpu"
        case knowledge: "books.vertical"
        case directory: "magnifyingglass"
        case admin: "lock.shield"
        default: "rectangle.3.group"
        }
    }
}

enum TeamsKey {
    static func make(_ id: String, on server: String) -> String { "\(server)/\(id)" }

    /// The server and the ID of a key. A server ID never holds a slash; an ID may.
    static func split(_ key: String) -> (server: String, id: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let server = String(key[..<slash]), id = String(key[key.index(after: slash)...])
        return server.isEmpty || id.isEmpty ? nil : (server, id)
    }

    /// The key of a row's result: what it is about, then where.
    static func result(_ subject: String, _ key: String) -> String { "\(subject):\(key)" }
}

enum TeamsBand: String, CaseIterable, Identifiable, Sendable {
    case board, combined, integration, claims

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: "Board"
        case .combined: "Combined view"
        case .integration: "Integration"
        case .claims: "Claims"
        }
    }
}

// MARK: - Content

/// A host you lend: its enrolled commands and how many grants reach it.
struct TeamsHost: Identifiable, Equatable {
    let id: String
    var name: String
    var environment = ""
    var commands: [MultiplayerHostCommand] = []
    var grants = 0
}

/// A member's checks on a branch.
struct TeamsChecks: Equatable {
    var passed = 0
    var failed = 0
    var isRunning = false

    var title: String {
        if isRunning { return "Running" }
        if failed > 0 { return "\(failed) failing" }
        return passed > 0 ? "\(passed) passing" : "No checks"
    }

    var tone: Tone {
        if isRunning { return .focus }
        if failed > 0 { return .failure }
        return passed > 0 ? .working : .neutral
    }

    var lamp: MultiplayerLamp.Kind {
        if isRunning { return .waiting }
        if failed > 0 { return .error }
        return passed > 0 ? .on : .off
    }
}

/// One worker a member runs for a workspace.
struct TeamsWorker: Identifiable, Equatable {
    let id: String
    var name: String
    var capabilities = MultiplayerCapabilities()
    var state = "Working"
    var tone = Tone.working
    var branch = ""
    /// Nil while nothing reports checks for the worker: shown as a dash, never as zero.
    var checks: TeamsChecks? = nil
    /// Its live claims in the workspace, when the combined view lists them.
    var claims: [MultiplayerClaim] = []
}

/// A member of a workspace and the workers they run for it.
struct TeamsMemberWork: Identifiable, Equatable {
    let handle: String
    var isOnline = true
    var workers: [TeamsWorker] = []

    var id: String { handle }
}

/// Someone on a server an admin can moderate, and a device signed in to it.
struct TeamsMember: Identifiable, Equatable {
    /// Empty until the member chooses a handle. Such a member can't be suspended yet.
    let handle: String
    var isSuspended = false
    var isAdmin = false
    /// The list's own ID for the row, for a member without a handle.
    var key: String? = nil

    var id: String { key ?? handle }
    /// Suspend and Unsuspend name a member by handle.
    var canModerate: Bool { !handle.isEmpty }
}

struct TeamsDevice: Identifiable, Equatable {
    let id: String
    /// The relay stores no device name today, so this is the ID.
    var name: String
    var owner: String
    var lastSeen: Date? = nil
    /// The device holds a session now. Nil when the relay doesn't say.
    var isOnline: Bool? = nil
}

struct TeamsPagesContent {
    /// One server the person is signed in to, and what it lists.
    struct Server: Identifiable {
        let id: String
        var name: String
        var handle = ""
        var isAdmin = false
        var friends: [MultiplayerFriend] = []
        var groups: [MultiplayerGroup] = []
        var workspaces: [MultiplayerWorkspace] = []
        var knowledge: [MultiplayerKnowledgeItem] = []
        /// Hosts you lend here, and hosts friends lend.
        var hosts: [TeamsHost] = []
        var offeredHosts: [MultiplayerDirectoryEntry] = []
        var policy: MultiplayerRelayPolicy? = nil
        var members: [TeamsMember] = []
        var devices: [TeamsDevice] = []
        /// The widest scope the relay lets a member share knowledge with, as it tells every member.
        var knowledgeWidest: MultiplayerKnowledgeScope? = nil
        /// Why the policy or the member and device lists couldn't be read.
        var adminProblem: String? = nil
    }

    var now = Date()
    var servers: [Server] = []
    /// By workspace key.
    var cards: [String: [MultiplayerCard]] = [:]
    var queue: [String: [MultiplayerQueueEntry]] = [:]
    var pullRequests: [String: MultiplayerLoad<MultiplayerPullRequestList>] = [:]
    var work: [String: [TeamsMemberWork]] = [:]
    /// Workspaces whose merge queue is running now.
    var merging: Set<String> = []
    /// A knowledge item's versions, by item key, and a resource's reputation, by resource key.
    /// Each is the window's own read: missing while it hasn't been asked for.
    var versions: [String: MultiplayerLoad<[MultiplayerKnowledgeItem]>] = [:]
    var reputation: [String: MultiplayerLoad<MultiplayerReputation>] = [:]
    /// Why a board couldn't be read, by workspace key, and the boards being read for the first time.
    var cardProblems: [String: String] = [:]
    var readingCards: Set<String> = []
    /// The window's own reads: the last directory search and the last run on each host.
    var search: MultiplayerLoad<MultiplayerDirectorySearch>? = nil
    var hostRuns: [String: MultiplayerSentRequest] = [:]
    /// How the last action on a row ended, and the rows whose action still runs.
    var results: [String: NetworkActionResult] = [:]
    var running: Set<String> = []
    /// What the page is doing now, why its last action failed, and what it last confirmed.
    var working: String? = nil
    var failure: String? = nil
    var notice: String? = nil
    /// Why the open form's last send was refused.
    var refusal: String? = nil
    var isUnavailable = false

    var isBusy: Bool { working != nil }

    // MARK: Lookups

    func server(_ id: String) -> Server? { servers.first { $0.id == id } }
    func serverName(_ id: String) -> String { server(id)?.name ?? id }
    func handle(on server: String) -> String { self.server(server)?.handle ?? "" }

    var adminServers: [Server] { servers.filter(\.isAdmin) }
    var isAdmin: Bool { !adminServers.isEmpty }

    func workspace(_ key: String) -> (server: Server, workspace: MultiplayerWorkspace)? {
        guard let parts = TeamsKey.split(key), let server = server(parts.server),
              let workspace = server.workspaces.first(where: { $0.id == parts.id }) else { return nil }
        return (server, workspace)
    }

    func group(_ key: String) -> (server: Server, group: MultiplayerGroup)? {
        guard let parts = TeamsKey.split(key), let server = server(parts.server),
              let group = server.groups.first(where: { $0.id == parts.id }) else { return nil }
        return (server, group)
    }

    func groupName(_ id: String, on server: String) -> String? { self.server(server)?.groups.first { $0.id == id }?.name }

    func item(_ key: String) -> (server: Server, item: MultiplayerKnowledgeItem)? {
        guard let parts = TeamsKey.split(key), let server = server(parts.server),
              let item = server.knowledge.first(where: { $0.id == parts.id }) else { return nil }
        return (server, item)
    }

    func host(_ key: String) -> (server: Server, host: TeamsHost)? {
        guard let parts = TeamsKey.split(key), let server = server(parts.server),
              let host = server.hosts.first(where: { $0.id == parts.id }) else { return nil }
        return (server, host)
    }

    func offeredHost(_ key: String) -> (server: Server, entry: MultiplayerDirectoryEntry)? {
        guard let parts = TeamsKey.split(key), let server = server(parts.server),
              let entry = server.offeredHosts.first(where: { $0.id == parts.id }) else { return nil }
        return (server, entry)
    }

    func card(_ id: String, in workspace: String) -> MultiplayerCard? { cards[workspace]?.first { $0.id == id } }

    /// Friends on the server who aren't in the group yet.
    func addable(to group: MultiplayerGroup, on server: String) -> [MultiplayerFriend] {
        (self.server(server)?.friends ?? []).filter { !group.members.contains($0.handle) }
    }

    /// The widest scope a server lets knowledge be shared with.
    func widestScope(on server: String) -> MultiplayerKnowledgeScope {
        knownWidestScope(on: server) ?? .server
    }

    /// The widest scope, when the server has said: from its policy for an admin, or from what it
    /// tells every member.
    func knownWidestScope(on server: String) -> MultiplayerKnowledgeScope? {
        let found = self.server(server)
        return found?.policy.flatMap { MultiplayerKnowledgeScope(rawValue: $0.knowledgeWidest) } ?? found?.knowledgeWidest
    }

    /// What a server lets knowledge reach, as one sentence.
    func reachNote(on server: String) -> String? {
        guard let widest = knownWidestScope(on: server) else { return nil }
        let name = serverName(server)
        return widest == .server ? "\(name) lets knowledge reach everyone on it."
                                 : "\(name) lets knowledge reach \(TeamsKnowledgePage.reach(widest)) at most."
    }

    /// A refused share with the server's limit named, when the scope asked for is wider than the
    /// server allows and the refusal doesn't already say so.
    func shareRefusal(_ reason: String?, scope: MultiplayerKnowledgeScope, on server: String) -> String? {
        guard let reason, let widest = knownWidestScope(on: server), scope.rank > widest.rank,
              let note = reachNote(on: server), !reason.contains(note) else { return reason }
        return "\(reason) \(note)"
    }

    /// Who shared a knowledge item: the owner's handle, or the owner as the relay names them when
    /// it sends no handle.
    static func owner(of item: MultiplayerKnowledgeItem) -> String { item.ownerHandle.isEmpty ? item.owner : item.ownerHandle }

    // MARK: Rows

    /// The cards of a workspace in one state, as the board's column shows them.
    func boardCards(_ state: MultiplayerCard.State, in workspace: String) -> [TeamsBoardCard] {
        let handle = TeamsKey.split(workspace).map { self.handle(on: $0.server) } ?? ""
        return (cards[workspace] ?? []).filter { $0.known == state }.map { card in
            let key = TeamsKey.result("card", TeamsKey.make(card.id, on: workspace))
            // A claim's own note ("Nobody else can take it while you hold it.") is true only while
            // the card is claimed. A refusal stays until the card is tried again.
            let result = results[key].flatMap { $0.isDone && state != .claimed ? nil : $0 }
            return TeamsBoardCard(workspace: workspace, card: card, isMine: card.isAssigned(to: handle),
                                  result: result, isRunning: running.contains(key))
        }
    }

    /// Each member's workers for a workspace, with the claim each holds.
    func combinedRows(in key: String) -> [TeamsCombinedRow] {
        guard let found = workspace(key) else { return [] }
        return (work[key] ?? []).flatMap { member -> [TeamsCombinedRow] in
            let mine = member.handle == found.server.handle
            if member.workers.isEmpty {
                return [TeamsCombinedRow(id: member.handle, handle: member.handle, isOnline: member.isOnline, isMine: mine,
                                         showsMember: true, worker: nil, claim: nil)]
            }
            return member.workers.enumerated().map { index, worker in
                TeamsCombinedRow(id: "\(member.handle)/\(worker.id)", handle: member.handle, isOnline: member.isOnline, isMine: mine,
                                 showsMember: index == 0, worker: worker,
                                 claim: worker.claims.first ?? found.workspace.claims.first { $0.holder == "\(member.handle)/\(worker.name)" },
                                 moreClaims: max(0, worker.claims.count - 1))
            }
        }
    }

    var groupRows: [TeamsGroupRow] {
        servers.flatMap { server in
            server.groups.map { TeamsGroupRow(server: server.id, serverName: server.name, group: $0, isOwner: $0.isOwned(by: server.handle)) }
        }
    }

    var hostRows: [TeamsHostRow] {
        servers.flatMap { server in server.hosts.map { TeamsHostRow(server: server.id, serverName: server.name, host: $0) } }
    }

    var offeredHostRows: [TeamsOfferedHostRow] {
        servers.flatMap { server in
            server.offeredHosts.map { entry in
                let key = TeamsKey.make(entry.id, on: server.id)
                return TeamsOfferedHostRow(server: server.id, serverName: server.name, entry: entry,
                                           run: hostRuns[key].flatMap { MultiplayerHostRun($0.value) },
                                           isRunning: running.contains(TeamsKey.result("host", key)))
            }
        }
        .sorted { ($0.entry.canRunOnHost ? 0 : 1, $0.entry.name) < ($1.entry.canRunOnHost ? 0 : 1, $1.entry.name) }
    }

    var knowledgeRows: [TeamsKnowledgeRow] {
        servers.flatMap { server in
            server.knowledge.map { item in
                TeamsKnowledgeRow(server: server.id, serverName: server.name, item: item,
                                  isMine: !server.handle.isEmpty && Self.owner(of: item) == server.handle,
                                  visibility: MultiplayerKnowledgeScope.describe(item.visibility) { groupName($0, on: server.id) })
            }
        }
        .sorted { ($0.item.createdAt ?? .distantPast) > ($1.item.createdAt ?? .distantPast) }
    }

    func memberRows(on server: String) -> [TeamsMemberRow] {
        (self.server(server)?.members ?? []).map { member in
            let key = TeamsKey.result("member", TeamsKey.make(member.handle, on: server))
            return TeamsMemberRow(server: server, member: member, isYou: member.canModerate && member.handle == handle(on: server),
                                  result: results[key], isRunning: running.contains(key))
        }
    }

    // MARK: Telemetry

    func readouts(for place: String) -> [ShellReadout] {
        func cell(_ id: String, _ label: String, _ value: Int, tone: Tone = .neutral) -> ShellReadout {
            ShellReadout(id: id, label: label, value: "\(value)", tone: value > 0 ? tone : .neutral)
        }
        if let key = TeamsPlace.workspaceKey(of: place), let found = workspace(key) {
            let all = cards[key] ?? []
            let members = group(TeamsKey.make(found.workspace.group, on: found.server.id))?.group.members.count ?? (work[key]?.count ?? 0)
            var cells = [cell("members", "members", members),
                         cell("claims", "live claims", found.workspace.claims.count, tone: .attention),
                         cell("open", "open cards", all.filter { $0.known == .open }.count),
                         cell("done", "done", all.filter { $0.known == .done }.count, tone: .working)]
            if found.workspace.usesQueue {
                cells.append(cell("queue", "in the queue", (queue[key] ?? []).filter(\.isQueued).count, tone: .focus))
            } else {
                cells.append(cell("prs", "open pull requests", pullRequests[key]?.value?.pullRequests.count ?? 0, tone: .focus))
            }
            return cells
        }
        switch place {
        case TeamsPlace.groups:
            let rows = groupRows
            return [cell("groups", "groups", rows.count), cell("owned", "you own", rows.filter(\.isOwner).count),
                    cell("people", "people", Set(rows.flatMap(\.group.members)).count),
                    cell("servers", "servers", Set(rows.map(\.server)).count)]
        case TeamsPlace.hosts:
            let theirs = offeredHostRows
            return [cell("mine", "you lend", hostRows.count),
                    cell("commands", "commands enrolled", hostRows.reduce(0) { $0 + $1.host.commands.count }),
                    cell("offered", "friends lend", theirs.count),
                    cell("usable", "you can run on", theirs.filter(\.entry.canRunOnHost).count, tone: .working)]
        case TeamsPlace.knowledge:
            let rows = knowledgeRows
            return [cell("items", "items", rows.count), cell("mine", "you shared", rows.filter(\.isMine).count),
                    cell("skills", "skills", rows.filter { $0.item.kind == MultiplayerKnowledgeKind.skill.rawValue }.count),
                    cell("servers", "servers", Set(rows.map(\.server)).count)]
        case TeamsPlace.directory:
            let found = search?.value
            return [cell("resources", "resources found", found?.resources.count ?? 0),
                    cell("people", "people found", found?.handles.count ?? 0),
                    cell("endorsed", "endorsed", found?.resources.filter { !$0.endorsements.isEmpty }.count ?? 0, tone: .working)]
        case TeamsPlace.admin:
            let members = adminServers.flatMap(\.members)
            return [cell("servers", "servers you run", adminServers.count), cell("members", "members", members.count),
                    cell("suspended", "suspended", members.filter(\.isSuspended).count, tone: .failure),
                    cell("devices", "devices", adminServers.reduce(0) { $0 + $1.devices.count })]
        default:
            return []
        }
    }

    func title(for place: String) -> String {
        TeamsPlace.workspaceKey(of: place).flatMap { workspace($0)?.workspace.name.multiplayerDisplay } ?? TeamsPlace.title(place)
    }

    /// The line above the page title.
    func kicker(for place: String) -> String {
        if let key = TeamsPlace.workspaceKey(of: place), let found = workspace(key) {
            return "TEAMS / WORKSPACES / \(found.server.name.uppercased())"
        }
        return "TEAMS / \(TeamsPlace.title(place).uppercased())"
    }

    func summary(for place: String) -> String {
        if isUnavailable { return "The network helper isn’t available on this Mac." }
        if servers.isEmpty { return "No server yet. Add one to work with a team here." }
        if let key = TeamsPlace.workspaceKey(of: place) {
            return workspace(key)?.workspace.goal.multiplayerDisplay ?? "This workspace is gone, or you are no longer in its group."
        }
        switch place {
        case TeamsPlace.workspaces: return "You work in no workspace yet."
        case TeamsPlace.groups: return "The people you grant things to together. A grant to a group reaches every member."
        case TeamsPlace.hosts: return "Hardware you lend, and hardware friends lend you. Only enrolled commands run."
        case TeamsPlace.knowledge: return "Prompts, skills, instructions and MCP configurations your servers hold. Secrets never travel."
        case TeamsPlace.directory: return "Search a server for people and the resources their owners listed, and see how each has done."
        case TeamsPlace.admin: return "The policy of the servers you run, and who and what may use them."
        default: return ""
        }
    }
}

// MARK: - Rows

struct TeamsBoardCard: Identifiable, Equatable {
    let workspace: String
    let card: MultiplayerCard
    /// The person holds this card.
    let isMine: Bool
    var result: NetworkActionResult? = nil
    var isRunning = false

    var id: String { card.id }
    var key: String { TeamsKey.make(card.id, on: workspace) }
}

struct TeamsCombinedRow: Identifiable, Equatable {
    let id: String
    let handle: String
    let isOnline: Bool
    let isMine: Bool
    /// The first row of a member names them.
    let showsMember: Bool
    let worker: TeamsWorker?
    let claim: MultiplayerClaim?
    /// Claims the worker holds beside the one shown.
    var moreClaims = 0

    var spoken: String {
        var parts = [handle.multiplayerDisplay]
        guard let worker else { return parts[0] + ", no worker here" }
        parts.append("\(worker.name.multiplayerDisplay), \(worker.state)")
        if let claim {
            parts.append("holds \(claim.kindTitle.lowercased()) \(claim.key.multiplayerDisplay)"
                         + (moreClaims > 0 ? " and \(moreClaims) more" : ""))
        }
        if !worker.branch.isEmpty { parts.append("branch \(worker.branch.multiplayerDisplay)") }
        if let checks = worker.checks { parts.append("checks: \(checks.title.lowercased())") }
        return parts.joined(separator: ", ")
    }
}

struct TeamsGroupRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let group: MultiplayerGroup
    let isOwner: Bool

    var id: String { TeamsKey.make(group.id, on: server) }
}

struct TeamsHostRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let host: TeamsHost

    var id: String { TeamsKey.make(host.id, on: server) }
}

struct TeamsOfferedHostRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let entry: MultiplayerDirectoryEntry
    /// The last run here, when it ended with an exit code.
    let run: MultiplayerHostRun?
    let isRunning: Bool

    var id: String { TeamsKey.make(entry.id, on: server) }
    var commands: [String] { entry.capabilities?.commands?.map(\.name) ?? [] }
}

struct TeamsKnowledgeRow: Identifiable, Equatable {
    let server: String
    let serverName: String
    let item: MultiplayerKnowledgeItem
    let isMine: Bool
    /// Who sees it, in words.
    let visibility: String

    var id: String { TeamsKey.make(item.id, on: server) }
}

struct TeamsMemberRow: Identifiable, Equatable {
    let server: String
    let member: TeamsMember
    let isYou: Bool
    var result: NetworkActionResult? = nil
    var isRunning = false

    var id: String { TeamsKey.make(member.id, on: server) }
}

// MARK: - Selection, drafts, intents

enum TeamsComposer: Hashable {
    case card(workspace: String)
    case claim(workspace: String)
    case queue(workspace: String)
    case group(server: String)
    case knowledge(server: String)
    case workspace(server: String)
    /// The owner's edit of a workspace, by workspace key.
    case editWorkspace(String)

    var title: String {
        switch self {
        case .card: "New card"
        case .claim: "Claim"
        case .queue: "Add a branch"
        case .group: "New group"
        case .knowledge: "Share knowledge"
        case .workspace: "New workspace"
        case .editWorkspace: "Edit workspace"
        }
    }
}

/// A composer or a detail the network model hosts itself. Where the window is given hosts, a page
/// shows the host in place of its own form.
enum TeamsHosted: Hashable {
    case workspace(server: String)
    case claim(workspace: String)
    case card(String, workspace: String)
    case queue(workspace: String)
    case knowledge(server: String)
    case hostRun(resource: String)
    case policy(server: String)
}

/// A knowledge item and where installing it writes.
struct TeamsInstallDraft: Equatable {
    enum Destination: Equatable {
        /// `~/.claude/skills/<name>/SKILL.md`
        case skill(path: String)
        case clipboard
        /// A file the person chose.
        case file(path: String)
    }

    let server: String
    let item: String
    let name: String
    let kind: String
    let destination: Destination
    /// The `${NAME}` placeholders the item holds.
    var placeholders: [String] = []

    /// A skill's file name: letters, digits, dashes, dots and underscores of the item's name.
    static func skillFolder(_ name: String) -> String {
        let kept = name.lowercased().map { $0.isLetter || $0.isNumber || "-._".contains($0) ? $0 : "-" }
        let folder = String(kept).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return folder.isEmpty ? "skill" : folder
    }

    static func skillPath(_ name: String) -> String { "~/.claude/skills/\(skillFolder(name))/SKILL.md" }

    /// Where an item of this kind goes. An MCP item needs a file; nil until one is chosen.
    static func destination(for item: MultiplayerKnowledgeItem, file: String? = nil) -> Destination? {
        switch MultiplayerKnowledgeKind(rawValue: item.kind) {
        case .skill: .skill(path: skillPath(item.name))
        case .mcp: file.map { .file(path: $0) }
        default: .clipboard
        }
    }

    var question: String {
        switch destination {
        case .skill: "Install \(name) as a skill?"
        case .clipboard: "Copy \(name) to the clipboard?"
        case .file: "Save \(name) to this file?"
        }
    }

    /// The destination as the confirmation names it.
    var shownDestination: String {
        switch destination {
        case .skill(let path), .file(let path):
            let home = NSHomeDirectory()
            return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        case .clipboard: return "The clipboard"
        }
    }

    var consequence: String {
        var text: String
        switch destination {
        case .skill: text = "Writes this file on this Mac."
        case .clipboard: text = "Copies the text. Nothing is written to disk."
        case .file: text = "Saves the configuration into this file."
        }
        if !placeholders.isEmpty {
            text += " \(placeholders.map { "${\($0)}" }.formatted(.list(type: .and))) \(placeholders.count == 1 ? "is" : "are") filled from your Keychain."
        }
        return text
    }

    var confirmTitle: String {
        switch destination {
        case .skill: "Install skill"
        case .clipboard: "Copy"
        case .file: "Save to file"
        }
    }

    var keepTitle: String {
        switch destination {
        case .skill: "Don’t install"
        case .clipboard: "Don’t copy"
        case .file: "Don’t save"
        }
    }
}

enum TeamsConfirmation: Equatable {
    case releaseClaim(claim: String, workspace: String)
    case releaseCard(card: String, workspace: String)
    case removeQueued(entry: String, workspace: String)
    case merge(workspace: String)
    case saveWorkspace(workspace: String)
    case leaveWorkspace(workspace: String)
    case deleteGroup(String)
    case removeMember(handle: String, group: String)
    case install(TeamsInstallDraft)
    case setPolicy(server: String)
    case suspend(handle: String, server: String)
    case revokeDevice(device: String, server: String)
}

struct TeamsPagesSelection: Equatable {
    /// The band showing, by workspace key. Board when none is chosen.
    var band: [String: TeamsBand] = [:]
    /// The open card, as `workspace key/card`.
    var card: String? = nil
    var composer: TeamsComposer? = nil
    var confirming: TeamsConfirmation? = nil
    /// The claim that stopped the last claim, so its row can be found.
    var conflict: String? = nil
    var group: String? = nil
    /// Your host, or a friend's, by resource key.
    var host: String? = nil
    var knowledge: String? = nil
    /// The search result whose reputation is open, by resource key.
    var hit: String? = nil
    var searchServer: String? = nil
    var adminServer: String? = nil

    func band(of workspace: String) -> TeamsBand { band[workspace] ?? .board }
}

struct TeamsPagesDrafts: Equatable {
    var card = MultiplayerCardDraft()
    /// The result a claimed card is completed with.
    var cardResult = ""
    var claim = MultiplayerClaimDraft()
    var queue = MultiplayerQueueDraft()
    var workspace = MultiplayerWorkspaceEdit()
    var groupName = ""
    var hostRun = MultiplayerHostRunDraft()
    var knowledge = MultiplayerKnowledgeDraft()
    var query = ""
    var skill = ""
    var policy = MultiplayerPolicyDraft()
}

/// What a page can ask for. Each names its target.
enum TeamsIntent {
    case go(String)
    case dismissNotice, dismissFailure
    case closeComposer
    case cancelConfirmation, confirm

    // Workspace
    case newWorkspace(server: String)
    case startEdit(workspace: String), askSaveWorkspace
    case askLeave(workspace: String)
    case showBand(TeamsBand, workspace: String)
    case openCard(String?, workspace: String)
    case newCard(workspace: String), sendCard
    case claimCard(MultiplayerCard, workspace: String)
    case askReleaseCard(MultiplayerCard, workspace: String)
    case completeCard(MultiplayerCard, workspace: String)
    case startClaim(workspace: String), sendClaim
    case askRelease(MultiplayerClaim, workspace: String)
    case startQueue(workspace: String), chooseCheckout, sendQueue
    case askRemoveQueued(MultiplayerQueueEntry, workspace: String)
    case askMerge(workspace: String)
    case openWorker(TeamsCombinedRow, workspace: String)
    case openLink(URL)

    // Groups
    case openGroup(String?)
    case newGroup(server: String), createGroup
    case addMember(String, group: String)
    case askRemoveMember(String, group: String)
    case askDeleteGroup(String)

    // Hosts
    case openHost(String?)
    case runHost(resource: String, server: String)
    case shareHost(resource: String, server: String)
    case requestHost(resource: String, server: String)

    // Knowledge
    case openKnowledge(String?)
    case startShare(server: String), sendShare
    case askInstall(MultiplayerKnowledgeItem, server: String)

    // Directory
    case chooseSearchServer(String)
    case search
    case openHit(String?)
    case endorse(resource: String, server: String)
    case requestAccess(resource: String, server: String)

    // Admin
    case chooseAdminServer(String)
    case askSetPolicy(server: String)
    case askSuspend(String, server: String)
    case unsuspend(String, server: String)
    case askRevoke(String, server: String)
}

// MARK: - The action boundary

/// The one boundary every teams action crosses. Each call names its target, runs to its end and
/// returns its result for that target alone, case for case with the network model's own result.
/// The design preview supplies the sample's actions; the live window will supply the Teams
/// model's once it offers them.
struct TeamsPageActions {
    typealias Result = NetworkActionResult

    private static func unavailable(_ id: String, _ server: String) -> Result {
        .failed(id: id, server: server, reason: "Not available.")
    }

    // Workspace
    /// Saves the owner's edit, sending only what differs from the workspace as it stands.
    var editWorkspace: @MainActor (MultiplayerWorkspaceEdit, _ workspace: String, _ server: String) async -> Result
        = { _, workspace, server in unavailable(workspace, server) }
    /// Leaves a workspace. The owner can't.
    var leaveWorkspace: @MainActor (_ workspace: String, _ server: String) async -> Result
        = { workspace, server in unavailable(workspace, server) }
    var claim: @MainActor (MultiplayerClaimDraft, _ workspace: String, _ server: String) async -> TeamsClaimOutcome
        = { draft, _, server in .failed(id: draft.trimmedKey, server: server, reason: "Not available.") }
    var release: @MainActor (_ claim: String, _ workspace: String, _ server: String) async -> Result
        = { claim, _, server in unavailable(claim, server) }
    var createCard: @MainActor (MultiplayerCardDraft, _ workspace: String, _ server: String) async -> Result
        = { _, workspace, server in unavailable(workspace, server) }
    var claimCard: @MainActor (_ card: String, _ workspace: String, _ server: String) async -> TeamsClaimOutcome
        = { card, _, server in .failed(id: card, server: server, reason: "Not available.") }
    var releaseCard: @MainActor (_ card: String, _ workspace: String, _ server: String) async -> Result
        = { card, _, server in unavailable(card, server) }
    var completeCard: @MainActor (_ card: String, _ result: String, _ workspace: String, _ server: String) async -> TeamsClaimOutcome
        = { card, _, _, server in .failed(id: card, server: server, reason: "Not available.") }
    var queueAdd: @MainActor (MultiplayerQueueDraft, _ workspace: String, _ server: String) async -> Result
        = { draft, _, server in unavailable(draft.trimmedBranch, server) }
    var removeQueued: @MainActor (_ entry: String, _ workspace: String, _ server: String) async -> Result
        = { entry, _, server in unavailable(entry, server) }
    var runMerge: @MainActor (_ workspace: String, _ server: String) async -> Result
        = { workspace, server in unavailable(workspace, server) }
    /// Asks for the checkout a queued branch merges in. Nil when the person cancels.
    var chooseCheckout: (@MainActor () -> String?)? = nil

    // Groups
    var createGroup: @MainActor (_ name: String, _ server: String) async -> Result
        = { name, server in unavailable(name, server) }
    var setMember: @MainActor (_ handle: String, _ group: String, _ server: String, _ isMember: Bool) async -> Result
        = { handle, _, server, _ in unavailable(handle, server) }
    var deleteGroup: @MainActor (_ group: String, _ server: String) async -> Result
        = { group, server in unavailable(group, server) }

    // Hosts. The reply carries the exit code and the end of the output.
    var runHost: @MainActor (MultiplayerHostRunDraft, _ resource: String, _ server: String) async -> (Result, MultiplayerSentRequest?)
        = { _, resource, server in (unavailable(resource, server), nil) }

    // Knowledge
    var shareKnowledge: @MainActor (MultiplayerKnowledgeDraft, _ server: String) async -> Result
        = { draft, server in unavailable(draft.trimmedName, server) }
    var installKnowledge: @MainActor (TeamsInstallDraft) async -> Result
        = { draft in unavailable(draft.item, draft.server) }
    /// Asks where an MCP item is saved. Nil when the person cancels.
    var chooseInstallFile: (@MainActor (_ name: String) -> String?)? = nil

    // Directory and reputation
    var search: @MainActor (_ query: String, _ server: String) async -> MultiplayerLoad<MultiplayerDirectorySearch>
        = { _, _ in .failed("Not available.") }
    var endorse: @MainActor (_ resource: String, _ skill: String, _ server: String) async -> Result
        = { resource, _, server in unavailable(resource, server) }

    // The network pages' own flows, reached from a Teams page: the grant sheet for a host you lend,
    // and a request for access to a friend's resource. Nil where the window can't open them.
    var shareHost: (@MainActor (_ resource: String, _ server: String) -> Void)? = nil
    var requestAccess: (@MainActor (_ resource: String, _ server: String) -> Void)? = nil

    // Admin
    /// Saves what differs from `saved`.
    var setPolicy: @MainActor (MultiplayerPolicyDraft, _ saved: MultiplayerRelayPolicy, _ server: String) async -> Result
        = { _, _, server in unavailable("policy", server) }
    var setSuspended: @MainActor (_ handle: String, _ server: String, _ suspended: Bool) async -> Result
        = { handle, server, _ in unavailable(handle, server) }
    var revokeDevice: @MainActor (_ device: String, _ server: String) async -> Result
        = { device, server in unavailable(device, server) }
}

/// How a claim, or a card's claim or completion, ended: the result, and who stopped it when the
/// relay refused because someone else holds the work.
struct TeamsClaimOutcome: Equatable {
    var result: NetworkActionResult
    var refusal: MultiplayerClaimRefusal? = nil

    static func done(id: String, server: String, message: String?) -> TeamsClaimOutcome {
        TeamsClaimOutcome(result: .done(id: id, server: server, message: message))
    }

    static func failed(id: String, server: String, reason: String, refusal: MultiplayerClaimRefusal? = nil) -> TeamsClaimOutcome {
        TeamsClaimOutcome(result: .failed(id: id, server: server, reason: reason), refusal: refusal)
    }

    /// The result with the holder, the agent and the claim named from the refusal's own fields.
    /// `claims` are the workspace's, so the claim is named by what it holds.
    /// `known` is the claim when the caller knows what was asked for: a card's claim is on that card.
    func named(in claims: [MultiplayerClaim], known: MultiplayerClaim? = nil, card title: (String) -> String?) -> NetworkActionResult {
        guard let refusal, case .failed(let id, let server, let reason) = result else { return result }
        let sentence = Self.sentence(refusal, blocking: Self.blocking(refusal, in: claims) ?? known, card: title)
        return .failed(id: id, server: server, reason: reason.contains(sentence) ? reason : "\(Self.lead(reason)) \(sentence)")
    }

    /// The claim a refusal names. The list may be older than the refusal, so a claim it names by
    /// ID is found by that ID alone; the holder is tried only when no ID is given.
    static func blocking(_ refusal: MultiplayerClaimRefusal, in claims: [MultiplayerClaim]) -> MultiplayerClaim? {
        refusal.claim.isEmpty ? refusal.blocking(in: claims) : claims.first { $0.id == refusal.claim }
    }

    /// The row to mark for a refusal: the claim's ID.
    static func conflict(_ refusal: MultiplayerClaimRefusal, in claims: [MultiplayerClaim]) -> String? {
        refusal.claim.isEmpty ? refusal.blocking(in: claims)?.id : refusal.claim
    }

    /// The first sentence of a refusal: what couldn't be done.
    private static func lead(_ reason: String) -> String {
        guard let stop = reason.firstIndex(of: ".") else { return reason }
        return String(reason[...stop])
    }

    /// "sam holds it with the agent sam-codex, under the issue claim 12."
    static func sentence(_ refusal: MultiplayerClaimRefusal, blocking: MultiplayerClaim?, card title: (String) -> String?) -> String {
        let who = refusal.holder.isEmpty ? "Someone else" : refusal.holder.multiplayerDisplay
        var text = "\(who) holds it"
        if !refusal.agent.isEmpty { text += " with the agent \(refusal.agent.multiplayerDisplay)" }
        if let blocking {
            let isCard = blocking.kind == MultiplayerClaim.Kind.card.rawValue
            let key = (isCard ? title(blocking.key) : nil) ?? blocking.key
            text += ", under the \(blocking.kindTitle.lowercased()) claim \(key.multiplayerDisplay)"
        } else if !refusal.claim.isEmpty {
            text += ", under claim \(refusal.claim.multiplayerDisplay)"
        }
        return text + "."
    }
}

// MARK: - The window's state

/// What the window keeps for the Teams pages, and what each intent does to it. It reads the
/// content it is given and acts only through the boundary, so the preview and the live window
/// share every flow.
@Observable @MainActor
final class TeamsPagesState {
    var selection = TeamsPagesSelection()
    var drafts = TeamsPagesDrafts()
    let results = NetworkRowResults()
    /// The window's own reads.
    var search: MultiplayerLoad<MultiplayerDirectorySearch>? = nil
    var hostRuns: [String: MultiplayerSentRequest] = [:]
    /// What the last action confirmed, why it failed, and why the open form was refused.
    var notice: String? = nil
    var failure: String? = nil
    var refusal: String? = nil
    /// The place whose action raised `notice` or `failure`. The band shows on that page alone, and
    /// both are cleared when the window leaves it. Nil for a caller that names no place.
    private(set) var messagePlace: String? = nil
    /// Who stopped the last claim on a card, by card key, so the card can say who holds it.
    private(set) var refusals: [String: MultiplayerClaimRefusal] = [:]
    /// The one action that isn't a row's: what it is doing.
    var working: String? = nil

    /// The content with the window's own reads and results laid over it.
    /// `place` is the page being drawn: a message raised on another page is left out.
    func shown(_ content: TeamsPagesContent, place: String? = nil) -> TeamsPagesContent {
        var shown = content
        shown.results = results.results
        shown.running = results.running
        shown.search = search
        shown.hostRuns = hostRuns
        let isHere = place == nil || messagePlace == nil || messagePlace == place
        shown.notice = isHere ? notice : nil
        shown.failure = isHere ? failure : nil
        shown.refusal = refusal
        shown.working = working
        return shown
    }

    /// `place` is the page these values are for. Every action sent through them reports to that
    /// page alone.
    func pages(_ content: TeamsPagesContent, place: String? = nil, through actions: TeamsPageActions, go: @escaping (String) -> Void,
               host: ((TeamsHosted) -> AnyView)? = nil) -> TeamsPages {
        let laid = shown(content, place: place)
        return TeamsPages(content: laid, selection: selection,
                          drafts: Binding(get: { [self] in drafts }, set: { [self] in drafts = $0 }),
                          send: { [self] intent in send(intent, in: laid, through: actions, go: go, from: place) }, host: host)
    }

    /// The window left a page: what that page last said goes with it, and so does a second press
    /// that was waiting there.
    func left(_ place: String) {
        if messagePlace == nil || messagePlace == place {
            notice = nil
            failure = nil
            messagePlace = nil
        }
        selection.confirming = nil
    }

    /// A host put itself away.
    func hostCancelled(_ hosted: TeamsHosted) {
        switch hosted {
        case .card: selection.card = nil
        case .hostRun: selection.host = nil
        case .policy: break
        case .workspace, .claim, .queue, .knowledge:
            selection.composer = nil
            refusal = nil
        }
    }

    /// Who stopped the last claim on a card.
    func refusal(card: String, in workspace: String) -> MultiplayerClaimRefusal? { refusals[TeamsKey.make(card, on: workspace)] }

    /// A host finished a change. A form that went through is put away and its confirmation shows
    /// across the page; a refusal stays on the host, which shows it itself.
    func hostFinished(_ hosted: TeamsHosted, _ result: NetworkActionResult, from place: String? = nil) {
        guard result.isDone else { return }
        switch hosted {
        case .workspace, .claim, .queue, .knowledge: selection.composer = nil
        case .card(let card, let workspace):
            // The card moved on, so what its last claim said no longer holds.
            let key = TeamsKey.make(card, on: workspace)
            results.clear(TeamsKey.result("card", key))
            refusals[key] = nil
        // These say how they ended themselves: the run's exit code, the policy's "Saved".
        case .hostRun, .policy: return
        }
        report(result, from: place)
    }

    /// Says how an action ended, on the page that raised it. `place` is that page; the band shows
    /// there alone (`shown`), so an action that ends after the window moved on says nothing on
    /// the page it moved to.
    func report(_ result: NetworkActionResult, from place: String? = nil) {
        messagePlace = place
        if result.isDone {
            failure = nil
            notice = result.message
        } else {
            notice = nil
            failure = result.reason
        }
    }

    /// Runs a form's send: the form closes when it went through and keeps its refusal when it didn't.
    private func submit(_ key: String, from place: String?, _ work: @escaping @MainActor () async -> NetworkActionResult,
                        done: @escaping @MainActor () -> Void = {}) {
        refusal = nil
        results.run(key, work) { [self] result in
            if result.isDone {
                selection.composer = nil
                selection.conflict = nil
                done()
                report(result, from: place)
            } else {
                refusal = result.reason
            }
        }
    }

    private func run(_ key: String, from place: String?, _ work: @escaping @MainActor () async -> NetworkActionResult,
                     done: @escaping @MainActor () -> Void = {}) {
        results.run(key, work) { [self] result in
            if result.isDone { done() }
            report(result, from: place)
        }
    }

    /// `place` is the page the intent came from. What the action says is shown there alone.
    func send(_ intent: TeamsIntent, in content: TeamsPagesContent, through actions: TeamsPageActions,
              go: @escaping (String) -> Void, from place: String? = nil) {
        switch intent {
        case .go(let place):
            go(place)
        case .dismissNotice:
            notice = nil
        case .dismissFailure:
            failure = nil
        case .closeComposer:
            selection.composer = nil
            selection.conflict = nil
            refusal = nil
        case .cancelConfirmation:
            selection.confirming = nil
        case .confirm:
            confirm(in: content, through: actions, go: go, from: place)

        // Workspace
        case .newWorkspace(let server):
            open(.workspace(server: server))
        case .startEdit(let workspace):
            // Only the owner edits. The form starts from the workspace as it stands.
            guard let found = content.workspace(workspace), found.workspace.isOwned(by: found.server.handle) else { return }
            drafts.workspace = MultiplayerWorkspaceEdit(found.workspace)
            open(.editWorkspace(workspace))
        case .askSaveWorkspace:
            guard case .editWorkspace(let workspace)? = selection.composer, let found = content.workspace(workspace) else { return }
            if let hint = drafts.workspace.hint {
                refusal = hint
            } else if drafts.workspace.changes(from: found.workspace).isEmpty {
                refusal = "Nothing changed yet."
            } else {
                refusal = nil
                selection.confirming = .saveWorkspace(workspace: workspace)
            }
        case .askLeave(let workspace):
            // The owner can't leave: the relay refuses it, so it isn't offered.
            guard let found = content.workspace(workspace), !found.workspace.isOwned(by: found.server.handle) else { return }
            selection.composer = nil
            selection.confirming = .leaveWorkspace(workspace: workspace)
        case .showBand(let band, let workspace):
            selection.band[workspace] = band
            selection.composer = nil
            selection.confirming = nil
            refusal = nil
        case .openCard(let card, let workspace):
            selection.card = card.map { TeamsKey.make($0, on: workspace) }
            selection.composer = nil
            selection.confirming = nil
            drafts.cardResult = ""
        case .newCard(let workspace):
            drafts.card = MultiplayerCardDraft()
            open(.card(workspace: workspace))
        case .sendCard:
            guard case .card(let workspace)? = selection.composer, let parts = TeamsKey.split(workspace), drafts.card.canSend else { return }
            let draft = drafts.card
            submit(TeamsKey.result("composer", workspace), from: place) { await actions.createCard(draft, parts.id, parts.server) }
        case .claimCard(let card, let workspace):
            guard let parts = TeamsKey.split(workspace) else { return }
            let key = TeamsKey.make(card.id, on: workspace)
            let claims = content.workspace(workspace)?.workspace.claims ?? []
            refusals[key] = nil
            results.run(TeamsKey.result("card", key), keeps: true) { [self] in
                let outcome = await actions.claimCard(card.id, parts.id, parts.server)
                // A refused claim names who holds the card, and marks their claim's row.
                refusals[key] = outcome.refusal
                guard let refusal = outcome.refusal else { return outcome.result }
                selection.conflict = TeamsClaimOutcome.conflict(refusal, in: claims)
                // The blocking claim is newer than the list this page drew from. It is on this card.
                let held = MultiplayerClaim(id: refusal.claim, kind: MultiplayerClaim.Kind.card.rawValue, key: card.id,
                                            holder: refusal.holderName, expiresAt: nil)
                return outcome.named(in: claims, known: held) { content.card($0, in: workspace)?.title }
            }
        case .askReleaseCard(let card, let workspace):
            selection.confirming = .releaseCard(card: card.id, workspace: workspace)
        case .completeCard(let card, let workspace):
            guard let parts = TeamsKey.split(workspace) else { return }
            let text = drafts.cardResult.trimmingCharacters(in: .whitespacesAndNewlines)
            let claims = content.workspace(workspace)?.workspace.claims ?? []
            run(TeamsKey.result("card", TeamsKey.make(card.id, on: workspace)), from: place,
                { await actions.completeCard(card.id, text, parts.id, parts.server).named(in: claims) { content.card($0, in: workspace)?.title } },
                done: { [self] in drafts.cardResult = "" })
        case .startClaim(let workspace):
            drafts.claim = MultiplayerClaimDraft()
            open(.claim(workspace: workspace))
        case .sendClaim:
            guard case .claim(let workspace)? = selection.composer, let parts = TeamsKey.split(workspace), drafts.claim.canSend else { return }
            let draft = drafts.claim
            // A refused claim names its holder; the row it overlaps is found by that holder.
            let claims = content.workspace(workspace)?.workspace.claims ?? []
            refusal = nil
            var stopped: MultiplayerClaimRefusal?
            results.run(TeamsKey.result("composer", workspace), {
                let outcome = await actions.claim(draft, parts.id, parts.server)
                stopped = outcome.refusal
                return outcome.named(in: claims) { content.card($0, in: workspace)?.title }
            }) { [self] result in
                if result.isDone {
                    selection.composer = nil
                    selection.conflict = nil
                    report(result, from: place)
                } else {
                    refusal = result.reason
                    // The refusal's own fields name the claim. Without them, the holder in its sentence does.
                    selection.conflict = stopped.flatMap { TeamsClaimOutcome.conflict($0, in: claims) }
                        ?? claims.first { result.reason?.contains($0.holder) == true }?.id
                }
            }
        case .askRelease(let claim, let workspace):
            selection.confirming = .releaseClaim(claim: claim.id, workspace: workspace)
        case .startQueue(let workspace):
            drafts.queue = MultiplayerQueueDraft()
            open(.queue(workspace: workspace))
        case .chooseCheckout:
            if let path = actions.chooseCheckout?() { drafts.queue.checkout = path }
        case .sendQueue:
            guard case .queue(let workspace)? = selection.composer, let parts = TeamsKey.split(workspace), drafts.queue.canSend else { return }
            let draft = drafts.queue
            submit(TeamsKey.result("composer", workspace), from: place) { await actions.queueAdd(draft, parts.id, parts.server) }
        case .askRemoveQueued(let entry, let workspace):
            selection.confirming = .removeQueued(entry: entry.id, workspace: workspace)
        case .askMerge(let workspace):
            selection.composer = nil
            selection.confirming = .merge(workspace: workspace)
        case .openWorker(let row, _):
            // Your own worker is on the wall; a friend's is reached through its hand-off.
            go(row.isMine ? LiveShell.wall : NetworkPlace.handoffs)
        case .openLink(let url):
            NSWorkspace.shared.open(url)

        // Groups
        case .openGroup(let key):
            selection.group = key
            selection.composer = nil
            selection.confirming = nil
        case .newGroup(let server):
            drafts.groupName = ""
            open(.group(server: server))
        case .createGroup:
            guard case .group(let server)? = selection.composer else { return }
            let name = drafts.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            submit(TeamsKey.result("composer", server), from: place) { await actions.createGroup(name, server) }
        case .addMember(let handle, let group):
            guard let parts = TeamsKey.split(group) else { return }
            run(TeamsKey.result("group", group), from: place) { await actions.setMember(handle, parts.id, parts.server, true) }
        case .askRemoveMember(let handle, let group):
            selection.confirming = .removeMember(handle: handle, group: group)
        case .askDeleteGroup(let group):
            selection.confirming = .deleteGroup(group)

        // Hosts
        case .openHost(let key):
            selection.host = key
            selection.confirming = nil
            if let key, let found = content.offeredHost(key) {
                let commands = found.entry.capabilities?.commands?.map(\.name) ?? []
                drafts.hostRun = MultiplayerHostRunDraft(command: commands.first ?? "")
            }
        case .runHost(let resource, let server):
            guard drafts.hostRun.canSend else { return }
            let draft = drafts.hostRun, key = TeamsKey.make(resource, on: server)
            results.run(TeamsKey.result("host", key), { [self] in
                let answer = await actions.runHost(draft, resource, server)
                if let reply = answer.1 { hostRuns[key] = reply }
                return answer.0
            }, finished: { [self] result in
                if !result.isDone { report(result, from: place) }
            })
        case .shareHost(let resource, let server):
            actions.shareHost?(resource, server)
        case .requestHost(let resource, let server), .requestAccess(let resource, let server):
            actions.requestAccess?(resource, server)

        // Knowledge
        case .openKnowledge(let key):
            selection.knowledge = key
            selection.composer = nil
            selection.confirming = nil
        case .startShare(let server):
            var draft = MultiplayerKnowledgeDraft()
            draft.scope = content.server(server)?.policy.flatMap { MultiplayerKnowledgeScope(rawValue: $0.knowledgeDefault) } ?? .private
            drafts.knowledge = draft
            selection.knowledge = nil
            open(.knowledge(server: server))
        case .sendShare:
            guard case .knowledge(let server)? = selection.composer, drafts.knowledge.canSend else { return }
            let draft = drafts.knowledge
            submit(TeamsKey.result("composer", server), from: place) {
                let result = await actions.shareKnowledge(draft, server)
                // A relay that only says "Forbidden." is given the limit the window knows.
                guard case .failed(let id, let on, let reason) = result else { return result }
                return .failed(id: id, server: on, reason: content.shareRefusal(reason, scope: draft.scope, on: server) ?? reason)
            }
        case .askInstall(let item, let server):
            let file = MultiplayerKnowledgeKind(rawValue: item.kind) == .mcp ? actions.chooseInstallFile?(item.name.multiplayerDisplay) : nil
            // An MCP item with no file chosen installs nothing.
            guard let destination = TeamsInstallDraft.destination(for: item, file: file) else { return }
            selection.confirming = .install(TeamsInstallDraft(server: server, item: item.id, name: item.name.multiplayerDisplay,
                                                              kind: item.kind, destination: destination,
                                                              placeholders: item.placeholders))

        // Directory
        case .chooseSearchServer(let server):
            selection.searchServer = server
            selection.hit = nil
            search = nil
        case .search:
            let query = drafts.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let server = selection.searchServer ?? content.servers.first?.id else { return }
            selection.searchServer = server
            selection.hit = nil
            search = .loading
            Task { [self] in search = await actions.search(query, server) }
        case .openHit(let key):
            selection.hit = key
            drafts.skill = ""
        case .endorse(let resource, let server):
            let skill = drafts.skill.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !skill.isEmpty else { return }
            run(TeamsKey.result("endorse", TeamsKey.make(resource, on: server)), from: place,
                { await actions.endorse(resource, skill, server) },
                done: { [self] in
                    drafts.skill = ""
                    // The search holds the endorsements it read, so the new one is laid over it.
                    if var found = search?.value, let index = found.resources.firstIndex(where: { $0.id == resource }) {
                        let hit = found.resources[index]
                        found.resources[index] = MultiplayerDirectoryHit(
                            id: hit.id, handle: hit.handle, name: hit.name, kind: hit.kind, actions: hit.actions,
                            capabilities: hit.capabilities,
                            endorsements: hit.endorsements + [MultiplayerEndorsement(handle: content.handle(on: server), skill: skill)])
                        search = .loaded(found)
                    }
                })

        // Admin
        case .chooseAdminServer(let server):
            selection.adminServer = server
            selection.confirming = nil
            drafts.policy = content.server(server)?.policy.map(MultiplayerPolicyDraft.init) ?? MultiplayerPolicyDraft()
        case .askSetPolicy(let server):
            guard let saved = content.server(server)?.policy, drafts.policy.changes(from: saved)?.isEmpty == false else { return }
            selection.confirming = .setPolicy(server: server)
        case .askSuspend(let handle, let server):
            selection.confirming = .suspend(handle: handle, server: server)
        case .unsuspend(let handle, let server):
            run(TeamsKey.result("member", TeamsKey.make(handle, on: server)), from: place) { await actions.setSuspended(handle, server, false) }
        case .askRevoke(let device, let server):
            selection.confirming = .revokeDevice(device: device, server: server)
        }
    }

    private func open(_ composer: TeamsComposer) {
        selection.composer = composer
        selection.confirming = nil
        selection.conflict = nil
        refusal = nil
    }

    /// The second press: runs what was waiting for it.
    private func confirm(in content: TeamsPagesContent, through actions: TeamsPageActions,
                         go: @escaping (String) -> Void, from place: String?) {
        guard let waiting = selection.confirming else { return }
        selection.confirming = nil
        switch waiting {
        case .releaseClaim(let claim, let workspace):
            guard let parts = TeamsKey.split(workspace) else { return }
            run(TeamsKey.result("claim", TeamsKey.make(claim, on: workspace)), from: place) { await actions.release(claim, parts.id, parts.server) }
        case .releaseCard(let card, let workspace):
            guard let parts = TeamsKey.split(workspace) else { return }
            run(TeamsKey.result("card", TeamsKey.make(card, on: workspace)), from: place,
                { await actions.releaseCard(card, parts.id, parts.server) },
                done: { [self] in drafts.cardResult = "" })
        case .removeQueued(let entry, let workspace):
            guard let parts = TeamsKey.split(workspace) else { return }
            run(TeamsKey.result("queue", TeamsKey.make(entry, on: workspace)), from: place) { await actions.removeQueued(entry, parts.id, parts.server) }
        case .merge(let workspace):
            guard let parts = TeamsKey.split(workspace) else { return }
            run(TeamsKey.result("merge", workspace), from: place) { await actions.runMerge(parts.id, parts.server) }
        case .saveWorkspace(let workspace):
            guard let parts = TeamsKey.split(workspace) else { return }
            let edit = drafts.workspace
            submit(TeamsKey.result("composer", workspace), from: place) { await actions.editWorkspace(edit, parts.id, parts.server) }
        case .leaveWorkspace(let workspace):
            guard let parts = TeamsKey.split(workspace) else { return }
            // The workspace leaves the navigation, so the window goes to where the others are listed
            // and says there what happened.
            results.run(TeamsKey.result("workspace", workspace), { await actions.leaveWorkspace(parts.id, parts.server) }) { [self] result in
                guard result.isDone else { return report(result, from: place) }
                selection.band[workspace] = nil
                go(TeamsPlace.workspaces)
                report(result, from: nil)
            }
        case .deleteGroup(let group):
            guard let parts = TeamsKey.split(group) else { return }
            run(TeamsKey.result("group", group), from: place, { await actions.deleteGroup(parts.id, parts.server) },
                done: { [self] in if selection.group == group { selection.group = nil } })
        case .removeMember(let handle, let group):
            guard let parts = TeamsKey.split(group) else { return }
            run(TeamsKey.result("group", group), from: place) { await actions.setMember(handle, parts.id, parts.server, false) }
        case .install(let draft):
            run(TeamsKey.result("install", TeamsKey.make(draft.item, on: draft.server)), from: place) { await actions.installKnowledge(draft) }
        case .setPolicy(let server):
            guard let saved = content.server(server)?.policy else { return }
            let draft = drafts.policy
            run(TeamsKey.result("policy", server), from: place) { await actions.setPolicy(draft, saved, server) }
        case .suspend(let handle, let server):
            run(TeamsKey.result("member", TeamsKey.make(handle, on: server)), from: place) { await actions.setSuspended(handle, server, true) }
        case .revokeDevice(let device, let server):
            run(TeamsKey.result("device", TeamsKey.make(device, on: server)), from: place) { await actions.revokeDevice(device, server) }
        }
    }
}

/// Everything a Teams page needs.
struct TeamsPages {
    var content: TeamsPagesContent
    var selection = TeamsPagesSelection()
    var drafts: Binding<TeamsPagesDrafts> = .constant(TeamsPagesDrafts())
    var send: (TeamsIntent) -> Void = { _ in }
    /// The network model's own hosts, in the live window. Nil in a preview, which draws its own forms.
    var host: ((TeamsHosted) -> AnyView)? = nil

    /// A page's result for a key, and whether it still runs.
    func result(_ subject: String, _ key: String) -> NetworkActionResult? { content.results[TeamsKey.result(subject, key)] }
    func isRunning(_ subject: String, _ key: String) -> Bool { content.running.contains(TeamsKey.result(subject, key)) }
}
