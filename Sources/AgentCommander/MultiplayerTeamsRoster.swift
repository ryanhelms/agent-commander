import Foundation

// MULTIPLAYER CONTRACT: what the Teams pages asked for after increment 5
// (design/demos/main-window-5/TRAY-API.md).
//   admin-members        a relay's members and devices, for its admin
//   workspace-combined   a workspace's members and their workers
//   workspace-edit       the owner changes a workspace's name, goal, repository, base or integration
//   workspace-leave      a member leaves a workspace
//   a refused claim      the holder, the agent and the claim that stopped it
// Values and client calls only. Every reply is read from plain JSON, leniently: a row this build
// can't read is dropped, and a field the device doesn't send reads as empty, never as a guess.

// MARK: - Members and devices

/// One member of a relay, as its admin sees them.
struct MultiplayerRelayMember: Equatable, Sendable, Identifiable {
    /// The handle, or the row's place in the list for a member who hasn't chosen one.
    let id: String
    /// Empty until the member chooses a handle. Such a member can't be suspended yet.
    let handle: String
    let suspended: Bool
    let admin: Bool

    init(id: String? = nil, handle: String, suspended: Bool = false, admin: Bool = false) {
        self.id = id ?? handle
        self.handle = handle
        self.suspended = suspended
        self.admin = admin
    }

    init?(_ json: MultiplayerJSON, index: Int) {
        guard case .object = json else { return nil }
        let handle = json.firstText("handle") ?? ""
        self.init(id: handle.isEmpty ? "#\(index)" : handle, handle: handle, suspended: json["suspended"]?.bool ?? false,
                  admin: json["admin"]?.bool ?? false)
    }

    /// Suspend and Unsuspend name a member by handle.
    var canModerate: Bool { !handle.isEmpty }
}

/// One enrolled device of a relay that is not revoked.
struct MultiplayerRelayDevice: Equatable, Sendable, Identifiable {
    let id: String
    /// Empty today: the relay stores no device name. Show `id` instead.
    let name: String
    /// The owner's handle. Empty until they choose one.
    let owner: String
    /// The device holds a live session now. Nil when the relay doesn't say.
    let online: Bool?
    /// When its last session ended. Nil while it is online, and for a device that never opened one.
    let lastSeen: Date?

    init(id: String, name: String = "", owner: String = "", online: Bool? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.owner = owner
        self.online = online
        self.lastSeen = lastSeen
    }

    init?(_ json: MultiplayerJSON) {
        guard let id = json.firstText("id") else { return nil }
        self.init(id: id, name: json.firstText("name") ?? "", owner: json.firstText("owner") ?? "",
                  online: json["online"]?.bool, lastSeen: json.date("lastSeen"))
    }

    /// The name, or the ID when the relay has none.
    var title: String { name.isEmpty ? id : name }
}

/// A relay's members and devices: what `admin-members` answers.
struct MultiplayerRelayRoster: Equatable, Sendable {
    var members: [MultiplayerRelayMember] = []
    var devices: [MultiplayerRelayDevice] = []

    init(members: [MultiplayerRelayMember] = [], devices: [MultiplayerRelayDevice] = []) {
        self.members = members
        self.devices = devices
    }

    init(_ json: MultiplayerJSON) {
        let rows = (json["members"]?.items ?? []).enumerated().compactMap { MultiplayerRelayMember($0.element, index: $0.offset) }
        members = MultiplayerUnique.keep(rows) { $0.id }
        devices = MultiplayerUnique.keep((json["devices"]?.items ?? []).compactMap(MultiplayerRelayDevice.init)) { $0.id }
    }

    func devices(of handle: String) -> [MultiplayerRelayDevice] {
        handle.isEmpty ? [] : devices.filter { $0.owner == handle }
    }
}

// MARK: - Combined view

/// What a worker's checks came to. The relay has no source for this yet, so a worker's `checks`
/// is nil today; nil is "not reported", never zero.
struct MultiplayerWorkerChecks: Equatable, Sendable {
    var passed = 0
    var failed = 0
    var running = 0

    init(passed: Int = 0, failed: Int = 0, running: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.running = running
    }

    init?(_ json: MultiplayerJSON?) {
        guard let json, case .object = json else { return nil }
        self.init(passed: max(0, json["passed"]?.int ?? 0), failed: max(0, json["failed"]?.int ?? 0),
                  running: max(0, json["running"]?.int ?? 0))
    }
}

/// One worker in a workspace's combined view: a published agent, or the holder of a live claim.
struct MultiplayerCombinedWorker: Equatable, Sendable, Identifiable {
    /// The relay's words for `state`.
    enum State: String, CaseIterable, Sendable {
        /// Holds at least one live claim in this workspace.
        case working
        /// A published agent whose device is connected.
        case online
        /// A published agent whose device is not.
        case offline

        var title: String {
            switch self {
            case .working: "Working"
            case .online: "Online"
            case .offline: "Offline"
            }
        }
    }

    /// The resource's ID for a published agent, "<handle>/<agent>" for a claim holder.
    let id: String
    let name: String
    /// The agent resource, when the worker is a published agent. Empty for a claim holder.
    let resource: String
    /// The agent name its claims are held under, when known.
    let agent: String
    /// Empty when not published.
    let harness: String
    let model: String
    let state: String
    /// Empty today: no relay record ties a worker to a branch.
    let branch: String
    let checks: MultiplayerWorkerChecks?
    /// Its live claims in this workspace. Each claim's holder is "<handle>/<agent>".
    let claims: [MultiplayerClaim]

    init(id: String, name: String, resource: String = "", agent: String = "", harness: String = "", model: String = "",
         state: String = "", branch: String = "", checks: MultiplayerWorkerChecks? = nil, claims: [MultiplayerClaim] = []) {
        self.id = id
        self.name = name
        self.resource = resource
        self.agent = agent
        self.harness = harness
        self.model = model
        self.state = state
        self.branch = branch
        self.checks = checks
        self.claims = claims
    }

    init?(_ json: MultiplayerJSON, handle: String) {
        guard let id = json.firstText("id") else { return nil }
        let agent = json.firstText("agent") ?? ""
        // A combined row's claim leaves its holder out: it is the row's own member and agent.
        let holder = agent.isEmpty ? handle : "\(handle)/\(agent)"
        let claims = (json["claims"]?.items ?? []).compactMap { row -> MultiplayerClaim? in
            guard let claim = MultiplayerClaim(row) else { return nil }
            return claim.holder.isEmpty
                ? MultiplayerClaim(id: claim.id, kind: claim.kind, key: claim.key, holder: holder, expiresAt: claim.expiresAt) : claim
        }
        self.init(id: id, name: json.firstText("name") ?? id, resource: json.firstText("resource") ?? "", agent: agent,
                  harness: json.firstText("harness") ?? "", model: json.firstText("model") ?? "",
                  state: json.firstText("state") ?? "", branch: json.firstText("branch") ?? "",
                  checks: MultiplayerWorkerChecks(json["checks"]), claims: MultiplayerUnique.keep(claims) { $0.id })
    }

    /// The state as the relay names it, when this build knows the word.
    var knownState: State? { State(rawValue: state) }
    var stateTitle: String { knownState?.title ?? state.multiplayerDisplay }
    /// A published agent, not only the holder of a claim.
    var isPublished: Bool { !resource.isEmpty }
}

/// One member of a workspace's group who hasn't left the workspace, with their workers.
struct MultiplayerCombinedMember: Equatable, Sendable, Identifiable {
    let handle: String
    /// Any of the member's devices is connected. Nil when the relay doesn't say.
    let online: Bool?
    let workers: [MultiplayerCombinedWorker]

    var id: String { handle }

    init(handle: String, online: Bool? = nil, workers: [MultiplayerCombinedWorker] = []) {
        self.handle = handle
        self.online = online
        self.workers = workers
    }

    init?(_ json: MultiplayerJSON) {
        guard let handle = json.firstText("handle") else { return nil }
        let workers = (json["workers"]?.items ?? []).compactMap { MultiplayerCombinedWorker($0, handle: handle) }
        self.init(handle: handle, online: json["online"]?.bool, workers: MultiplayerUnique.keep(workers) { $0.id })
    }
}

/// A workspace's combined view: what `workspace-combined` answers.
struct MultiplayerCombinedView: Equatable, Sendable {
    let workspace: String
    let members: [MultiplayerCombinedMember]

    init(workspace: String, members: [MultiplayerCombinedMember] = []) {
        self.workspace = workspace
        self.members = members
    }

    init(_ json: MultiplayerJSON, workspace: String) {
        self.init(workspace: json.firstText("workspace") ?? workspace,
                  members: MultiplayerUnique.keep((json["members"]?.items ?? []).compactMap(MultiplayerCombinedMember.init)) { $0.id })
    }

    var workers: [MultiplayerCombinedWorker] { members.flatMap(\.workers) }
}

// MARK: - Editing a workspace

/// The owner's edit of a workspace. The group can't change.
struct MultiplayerWorkspaceEdit: Equatable, Sendable {
    var name = ""
    var goal = ""
    var repository = ""
    var base = ""
    var integration = MultiplayerIntegration.queue

    init(name: String = "", goal: String = "", repository: String = "", base: String = "",
         integration: MultiplayerIntegration = .queue) {
        self.name = name
        self.goal = goal
        self.repository = repository
        self.base = base
        self.integration = integration
    }

    /// The workspace as it stands, ready to edit.
    init(_ workspace: MultiplayerWorkspace) {
        self.init(name: workspace.name, goal: workspace.goal, repository: workspace.repository, base: workspace.base,
                  integration: MultiplayerIntegration(rawValue: workspace.integration) ?? .queue)
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What is missing, in one line. The relay keeps a field that is sent empty, so none may be.
    var hint: String? {
        if trimmed(name).isEmpty { return "Give it a name." }
        if trimmed(goal).isEmpty { return "Say what it is for." }
        if trimmed(repository).isEmpty { return "Name the repository." }
        if trimmed(base).isEmpty { return "Name the base branch." }
        return nil
    }

    /// Only the fields that differ from `saved`: the device applies a partial edit.
    func changes(from saved: MultiplayerWorkspace) -> [String: String] {
        var fields: [String: String] = [:]
        if trimmed(name) != saved.name { fields["name"] = trimmed(name) }
        if trimmed(goal) != saved.goal { fields["goal"] = trimmed(goal) }
        if trimmed(repository) != saved.repository { fields["repository"] = trimmed(repository) }
        if trimmed(base) != saved.base { fields["base"] = trimmed(base) }
        if integration.rawValue != saved.integration { fields["integration"] = integration.rawValue }
        return fields
    }
}

// MARK: - A refused claim

/// Who stopped a claim: the fields a refusal carries beside its sentence.
struct MultiplayerClaimRefusal: Equatable, Sendable {
    /// The holder's handle.
    let holder: String
    /// The holding agent: the part after "/" in a claim row's holder. Empty when not said.
    let agent: String
    /// The blocking claim's ID, as listed in the workspace's claims. Empty when not said.
    let claim: String

    init(holder: String, agent: String = "", claim: String = "") {
        self.holder = holder
        self.agent = agent
        self.claim = claim
    }

    /// Reads a refusal's own fields. The device sends `holder`, `agent` and `claim`; the relay's
    /// own body has `holder` as "<handle>/<agent>" with `holderHandle`. Nil when it names no one.
    init?(_ json: MultiplayerJSON) {
        let raw = json.firstText("holder") ?? ""
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        let holder = json.firstText("holderHandle") ?? parts.first ?? ""
        let agent = json.firstText("agent") ?? (parts.count > 1 ? parts[1] : "")
        let claim = json.firstText("claim") ?? ""
        guard !holder.isEmpty || !claim.isEmpty else { return nil }
        self.init(holder: holder, agent: agent, claim: claim)
    }

    /// The holder as a claim row names it: "<handle>/<agent>".
    var holderName: String { agent.isEmpty ? holder : "\(holder)/\(agent)" }

    /// The claim in `claims` that stopped it: by its ID, or by its holder when the ID isn't said.
    func blocking(in claims: [MultiplayerClaim]) -> MultiplayerClaim? {
        if !claim.isEmpty, let found = claims.first(where: { $0.id == claim }) { return found }
        let held = claims.filter { $0.holder == holderName }
        return held.count == 1 ? held[0] : nil
    }
}

/// A claim, or a card claim or edit, the relay refused and said who holds the work.
struct MultiplayerClaimRefused: Error, Equatable, Sendable {
    /// The refusal as any other caller reads it.
    let failure: MultiplayerFailure
    let refusal: MultiplayerClaimRefusal
}

/// The result of a claim, or of a card claim or edit, with who stopped it, when someone did.
struct MultiplayerClaimAnswer: Equatable, Sendable {
    /// As `claim(_:in:on:)` or `updateCard(_:in:on:to:result:)` returns it: the new claim's ID or
    /// the card's, or why it wasn't done.
    let result: MultiplayerActionResult
    /// The holder and the blocking claim, when the relay refused because someone else holds it.
    let refusal: MultiplayerClaimRefusal?

    init(result: MultiplayerActionResult, refusal: MultiplayerClaimRefusal? = nil) {
        self.result = result
        self.refusal = refusal
    }
}

extension MultiplayerClaimAnswer {
    /// Hands the answer to a host's caller: who stopped it first, when the relay named a holder,
    /// then the result as every host reports it.
    @MainActor func report(to onFinish: (MultiplayerActionResult) -> Void, refused onRefused: ((MultiplayerClaimRefusal) -> Void)?) {
        if let refusal { onRefused?(refusal) }
        onFinish(result)
    }
}

extension MultiplayerEnvelope {
    /// The fields a refusal carries beside `error`. Nil for a success or an unreadable reply.
    static func refusal(from output: MultiplayerHelperOutput) -> MultiplayerJSON? {
        guard let reply = try? JSONDecoder().decode(MultiplayerJSON.self, from: output.stdout),
              reply["ok"]?.bool == false else { return nil }
        return reply
    }
}

// MARK: - Client

extension MultiplayerClient {
    /// A relay's members and devices. Only the relay's admin can read them.
    func relayRoster() async throws -> MultiplayerRelayRoster {
        MultiplayerRelayRoster(try await fetch(.adminMembers, [:], as: MultiplayerJSON.self, allowsEmpty: true) ?? .null)
    }

    /// A workspace's members and their workers.
    func combinedView(of workspace: String) async throws -> MultiplayerCombinedView {
        let reply = try await fetch(.workspaceCombined, ["workspace": .string(workspace)], as: MultiplayerJSON.self, allowsEmpty: true) ?? .null
        return MultiplayerCombinedView(reply, workspace: workspace)
    }

    /// Changes the given fields of a workspace. The workspace as it now stands, when the device
    /// sends it back.
    @discardableResult
    func editWorkspace(_ workspace: String, fields: [String: String]) async throws -> MultiplayerWorkspace? {
        var payload: [String: MultiplayerPayloadValue] = fields.mapValues { .string($0) }
        payload["workspace"] = .string(workspace)
        let reply = try await fetch(.workspaceEdit, payload, as: MultiplayerJSON.self, allowsEmpty: true) ?? .null
        return MultiplayerWorkspace(reply)
    }

    /// Leaves a workspace. The caller's live claims in it end.
    func leaveWorkspace(_ workspace: String) async throws {
        _ = try await fetch(.workspaceLeave, ["workspace": .string(workspace)], as: MultiplayerJSON.self, allowsEmpty: true)
    }

    /// Claims part of a workspace. A refusal that names who holds it is thrown as
    /// `MultiplayerClaimRefused`; every other failure as a `MultiplayerFailure`. The new claim's
    /// ID, when the relay names it.
    @discardableResult
    func claimNamingHolder(_ body: MultiplayerJSON, in workspace: String) async throws -> String {
        let path = "/v1/workspaces/\(try Self.segment(workspace))/claims"
        return try await relayNamingHolder("POST", path, body: body)?.firstText("id") ?? ""
    }

    /// Claims, completes or reopens a card. A refusal that names who holds the card is thrown as
    /// `MultiplayerClaimRefused`; every other failure as a `MultiplayerFailure`.
    func updateCardNamingHolder(_ card: String, in workspace: String, fields: [String: MultiplayerJSON]) async throws {
        let path = "/v1/workspaces/\(try Self.segment(workspace))/cards/\(try Self.segment(card))"
        _ = try await relayNamingHolder("PUT", path, body: .object(fields))
    }

    /// A relay request whose refusal can name a holder. The reply, when there is one.
    private func relayNamingHolder(_ method: String, _ path: String, body: MultiplayerJSON) async throws -> MultiplayerJSON? {
        do {
            let output = try await call(.relay, payload: ["method": .string(method), "path": .string(path), "body": .json(body)])
            do {
                return try MultiplayerEnvelope.decode(MultiplayerJSON.self, from: output)
            } catch {
                guard let refusal = MultiplayerEnvelope.refusal(from: output).flatMap(MultiplayerClaimRefusal.init) else { throw error }
                throw MultiplayerClaimRefused(failure: .from(error), refusal: refusal)
            }
        } catch let refused as MultiplayerClaimRefused {
            throw refused
        } catch {
            throw MultiplayerFailure.from(error)
        }
    }
}
