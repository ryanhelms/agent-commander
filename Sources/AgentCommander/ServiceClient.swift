import Foundation

/// One follow-up the service accepted for a worker, from `control.messages`. The service keeps
/// the whole list in acceptance order, terminal entries included. The message text is not read:
/// a receipt is identified by its ID. See `FollowUpReceipt` for the status vocabulary.
struct WorkerFollowUp: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// The status exactly as sent, so a value this version does not know is still shown.
    let status: String
    /// The control generation the follow-up was accepted under. Nil from an older service.
    let generation: Int?
    /// The message as written. Nil from an older service.
    let text: String?

    init(id: String, status: String, generation: Int? = nil, text: String? = nil) {
        self.id = id
        self.status = status
        self.generation = generation
        self.text = text
    }
}

/// What the worker's session can do, as the service reports it under `control`.
struct WorkerSessionCapabilities: Decodable, Equatable, Sendable {
    /// Whether the session's current turn can be interrupted. The service always states it.
    let canInterrupt: Bool?

    init(canInterrupt: Bool?) { self.canInterrupt = canInterrupt }

    private enum CodingKeys: String, CodingKey {
        case canInterrupt = "can_interrupt"
    }
}

struct WorkerControl: Decodable, Equatable, Sendable {
    let held: Bool
    let generation: Int
    let interruptRequested: Bool?
    let messages: [WorkerFollowUp]?
    /// Nil from an older service or a legacy runner, which leaves every action as it was.
    let sessionCapabilities: WorkerSessionCapabilities?
    /// The ACP turn the service expects the worker to be in now. Sent for a bound managed local
    /// Claude worker; nil from an older service or another provider.
    let activeTurnID: String?
    /// The receipt of the latest interrupt, kept after its outcome. Nil from an older service.
    let interrupt: WorkerInterruptReceipt?
    /// The prompt content the session accepts beyond text. Nil from an older service or a
    /// session that has not reported it; a follow-up then offers no file context.
    let promptCapabilities: WorkerPromptCapabilities?

    /// False only when the service says this session cannot be interrupted.
    var sessionCanInterrupt: Bool { sessionCapabilities?.canInterrupt != false }

    init(held: Bool, generation: Int, interruptRequested: Bool?, messages: [WorkerFollowUp]?,
         sessionCapabilities: WorkerSessionCapabilities? = nil, activeTurnID: String? = nil,
         interrupt: WorkerInterruptReceipt? = nil, promptCapabilities: WorkerPromptCapabilities? = nil) {
        self.held = held
        self.generation = generation
        self.interruptRequested = interruptRequested
        self.messages = messages
        self.sessionCapabilities = sessionCapabilities
        self.activeTurnID = activeTurnID
        self.interrupt = interrupt
        self.promptCapabilities = promptCapabilities
    }

    private enum CodingKeys: String, CodingKey {
        case held, generation, interruptRequested = "interrupt_requested", messages
        case sessionCapabilities = "session_capabilities"
        case activeTurnID = "active_turn_id", interrupt
        case promptCapabilities = "prompt_capabilities"
    }
}

extension WorkerSessionCapabilities {
    init(projection value: AGUIValue) throws {
        guard case .object(let fields) = value else {
            throw AGUIValueError("A worker's session capabilities are not an object")
        }
        self.init(canInterrupt: try fields.optionalBool("can_interrupt"))
    }
}

extension WorkerFollowUp {
    init(projection value: AGUIValue) throws {
        guard case .object(let fields) = value else { throw AGUIValueError("A follow-up is not an object") }
        self.init(id: try fields.string("id"), status: try fields.string("status"),
                  generation: try fields.optionalInt("generation"),
                  // Shown only in the message box, as "Queued for the next turn". A receipt never reads it.
                  text: try fields.optionalString("text"))
    }
}

extension WorkerControl {
    init(projection value: AGUIValue) throws {
        guard case .object(let fields) = value else { throw AGUIValueError("A worker control is not an object") }
        guard let held = try fields.optionalBool("held"), let generation = try fields.optionalInt("generation") else {
            throw AGUIValueError("A worker control has no held or generation")
        }
        self.init(held: held, generation: generation,
                  interruptRequested: try fields.optionalBool("interrupt_requested"),
                  messages: try fields.optionalList("messages", make: WorkerFollowUp.init(projection:)),
                  sessionCapabilities: try fields["session_capabilities"].flatMap {
                      $0.isNull ? nil : try WorkerSessionCapabilities(projection: $0)
                  },
                  activeTurnID: try fields.optionalString("active_turn_id"),
                  interrupt: try fields["interrupt"].flatMap {
                      $0.isNull ? nil : try WorkerInterruptReceipt(projection: $0)
                  },
                  // Never throws: an unreadable set reads as not reported, so it cannot cost the
                  // worker its control record.
                  promptCapabilities: fields["prompt_capabilities"].flatMap(WorkerPromptCapabilities.init(projection:)))
    }
}

struct Worker: Decodable, Identifiable, Sendable {
    let id, name, role, parentID, runID, state, host, worktree, task: String
    /// The retained terminal tail. The live feed sends it in chunks, which are joined here with
    /// nothing between them.
    let output: String
    /// The feed's `outputChunks` exactly as sent: the same pieces in the same order, unjoined.
    /// Nil when the worker came with a whole `output` or was not read from the feed. The array
    /// shares its storage with the reducer's until one of them changes.
    let outputChunks: [String]?
    let error: String?
    // Optional metadata. Older service records omit these; the interface shows them only when present.
    let client: String?
    let branch: String?
    let createdAt: String?
    let messages: [AGUIMessage]?
    let control: WorkerControl?
    /// Link to the execution host. Sent only for workers in persistent SSH mode, as `connected`
    /// or `reconnecting`. While it reconnects, `state` keeps the worker's own turn state.
    let connection: String?

    /// The service's value for a persistent link that is being re-established. A contract value.
    static let connectionReconnecting = "reconnecting"

    /// The provider session the service has bound this worker to. Legacy and unbound workers
    /// omit it, and they have no provider source to inspect.
    let nativeSession: NativeSession?

    /// Every field of the worker as the service sent it, including those this model does not
    /// name, such as `coding`, `handoff`, `result` and the whole `control` object. The feed's
    /// own `outputChunks` and `messages` are not repeated here: read `outputChunks` and `messages`.
    /// An empty object for a worker that was not read from the service.
    let allFields: AGUIValue

    private let stamp: UInt64

    /// The binding, when it names a session. Only then is the worker's source offered.
    var boundSession: NativeSession? {
        nativeSession.flatMap { $0.sessionID.isEmpty ? nil : $0 }
    }

    /// The members of `allFields` that have a typed property.
    static let namedFields: Set<String> = [
        "id", "name", "role", "parent_id", "run_id", "state", "host", "worktree", "task", "output", "error",
        "client", "branch", "created_at", "control", "connection", "native_session"
    ]

    init(id: String, name: String, role: String, parentID: String, runID: String, state: String, host: String,
         worktree: String, task: String, output: String, error: String? = nil, client: String? = nil,
         branch: String? = nil, createdAt: String? = nil, messages: [AGUIMessage]? = nil,
         control: WorkerControl? = nil, connection: String? = nil, nativeSession: NativeSession? = nil,
         outputChunks: [String]? = nil, allFields: AGUIValue = [:]) {
        self.id = id
        self.name = name
        self.role = role
        self.parentID = parentID
        self.runID = runID
        self.state = state
        self.host = host
        self.worktree = worktree
        self.task = task
        self.output = output
        self.error = error
        self.client = client
        self.branch = branch
        self.createdAt = createdAt
        self.messages = messages
        self.control = control
        self.connection = connection
        self.nativeSession = nativeSession
        self.outputChunks = outputChunks
        self.allFields = allFields
        stamp = 0
    }

    /// Builds a worker from its projected fields. `outputChunks` and `messages` are the feed's
    /// own members, which the reducer keeps apart from the rest.
    init(projection fields: [String: AGUIValue], outputChunks: [String]?, messages: [AGUIMessage]?) throws {
        id = try fields.string("id")
        name = try fields.string("name")
        role = try fields.string("role")
        parentID = try fields.string("parent_id")
        runID = try fields.string("run_id")
        state = try fields.string("state")
        host = try fields.string("host")
        worktree = try fields.string("worktree")
        task = try fields.string("task")
        output = try outputChunks?.joined() ?? fields.optionalString("output") ?? ""
        self.outputChunks = outputChunks
        error = try fields.optionalString("error")
        client = try fields.optionalString("client")
        branch = try fields.optionalString("branch")
        createdAt = try fields.optionalString("created_at")
        self.messages = messages
        control = try fields["control"].flatMap { $0.isNull ? nil : try WorkerControl(projection: $0) }
        connection = try fields.optionalString("connection")
        nativeSession = fields["native_session"].flatMap { $0.isNull ? nil : NativeSession(projection: $0) }
        allFields = .object(fields)
        stamp = AGUIStamp.next()
    }

    /// Reads a whole worker object, as the request API and the legacy feed send it.
    init(projection value: AGUIValue) throws {
        var node = try AGUIWorkerNode(value: value)
        self = try node.materialize()
    }

    init(from decoder: Decoder) throws { try self.init(projection: AGUIValue(from: decoder)) }
}

extension Worker: Equatable {
    static func == (lhs: Worker, rhs: Worker) -> Bool {
        // A worker the feed did not touch is the same value as before.
        if lhs.stamp != 0, lhs.stamp == rhs.stamp { return true }
        return lhs.id == rhs.id && lhs.state == rhs.state && lhs.name == rhs.name && lhs.role == rhs.role &&
            lhs.parentID == rhs.parentID && lhs.runID == rhs.runID && lhs.host == rhs.host &&
            lhs.worktree == rhs.worktree && lhs.task == rhs.task && lhs.error == rhs.error &&
            lhs.client == rhs.client && lhs.branch == rhs.branch && lhs.createdAt == rhs.createdAt &&
            lhs.connection == rhs.connection && lhs.nativeSession == rhs.nativeSession &&
            lhs.control == rhs.control && lhs.output == rhs.output && lhs.messages == rhs.messages &&
            lhs.outputChunks == rhs.outputChunks && lhs.allFields == rhs.allFields
    }
}

extension Worker {
    /// The fields with no typed property, for an inspector. An object.
    var extendedFields: AGUIValue {
        .object((allFields.objectValue ?? [:]).filter { !Self.namedFields.contains($0.key) })
    }
}

/// A worker's provider session, as the service reports it. It is shown for provenance only:
/// requests address the worker by its ID and the service resolves the session itself.
struct NativeSession: Hashable, Sendable {
    let harnessInstance: String
    let sessionID: String
}

extension NativeSession: Decodable {
    private enum CodingKeys: String, CodingKey {
        case harnessInstance = "harness_instance", sessionID = "session_id"
    }

    /// An unreadable binding reads as unbound, so it cannot cost the worker its ordinary console.
    init(projection value: AGUIValue) {
        harnessInstance = value["harness_instance"]?.stringValue ?? ""
        sessionID = value["session_id"]?.stringValue ?? ""
    }

    /// Never throws: an unreadable binding reads as unbound, so it cannot cost the worker its
    /// ordinary console.
    init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        harnessInstance = (try? fields?.decodeIfPresent(String.self, forKey: .harnessInstance)) ?? ""
        sessionID = (try? fields?.decodeIfPresent(String.self, forKey: .sessionID)) ?? ""
    }
}

/// Where a worker's source records are read from. The provider's own history is the default;
/// the other two are named in the request.
enum ConsoleSourceKind: String, CaseIterable, Identifiable, Sendable {
    case provider, live, journal

    var id: String { rawValue }

    /// The `source` query value. The provider history is the request without one.
    var queryValue: String? { self == .provider ? nil : rawValue }
}

/// One record of a worker's source, in the portable SDK envelope. Optional strings that the
/// service leaves out are empty here. `record` is the original structured record as sent.
struct SourceObservation: Identifiable, Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case text(speaker: String, text: String)
        case tool(callID: String, name: String, phase: String, summary: String)
        /// A historical input request. It is shown and never answered from here.
        case input(prompt: String, choices: [String])
        case turnEnded(reason: String)
        /// The source states that records are missing here, and why.
        case gap(reason: String)
        /// A provider extension. `data` is the decoded bytes, nil when the base64 is unreadable.
        case attachment(type: String, mediaType: String, data: Data?)
        /// A record with none of the known bodies.
        case unrecognized
    }

    /// Position in the selected source, assigned as pages arrive. Stable while that source is open.
    var id: String
    let session: NativeSession?
    let cursor: String
    let turnID: String
    let body: Body
    /// The whole original record, as indented JSON. Every member the source sent is in it,
    /// named by the envelope or not, and each number keeps the literal it was written with.
    let record: String
}

struct SourcePage: Sendable {
    var observations: [SourceObservation]
    let nextCursor: String?
}

extension SourcePage {
    /// Reads the envelope `{ "observations": [...], "nextCursor": "..." }`. Either field may be absent.
    init(envelope data: Data) throws {
        // Read without converting numbers, so each observation keeps what the source wrote.
        guard case .object(let root)? = try? AGUIValue(json: data) else {
            throw ServiceError.rejected("The service returned an unreadable source page.")
        }
        let items = root["observations"]?.arrayValue ?? []
        observations = items.enumerated().map { index, item in SourceObservation(json: item, index: index) }
        let next = root["nextCursor"]?.stringValue ?? ""
        nextCursor = next.isEmpty ? nil : next
    }
}

extension SourceObservation {
    /// Reads one observation. The typed fields are for the row's heading and preview; `record`
    /// is the whole value, so nothing the typed fields do not name is lost.
    init(json: AGUIValue, index: Int) {
        let fields = json.objectValue ?? [:]
        func string(_ object: [String: AGUIValue], _ key: String) -> String {
            switch object[key] {
            case .string(let value)?: value
            case .number(let value)?: value.literal
            case .bool(let value)?: value ? "true" : "false"
            default: ""
            }
        }

        id = String(index)
        if let session = fields["session"]?.objectValue {
            self.session = NativeSession(harnessInstance: string(session, "harnessInstance"),
                                         sessionID: string(session, "sessionId"))
        } else {
            session = nil
        }
        cursor = string(fields, "cursor")
        turnID = string(fields, "turnId")

        if let gap = fields["gap"]?.objectValue {
            body = .gap(reason: string(gap, "reason"))
        } else if let text = fields["text"]?.objectValue {
            body = .text(speaker: string(text, "speaker"), text: string(text, "text"))
        } else if let tool = fields["tool"]?.objectValue {
            body = .tool(callID: string(tool, "callId"), name: string(tool, "name"),
                         phase: string(tool, "phase"), summary: string(tool, "summary"))
        } else if let input = fields["input"]?.objectValue {
            let choices = (input["choices"]?.arrayValue ?? []).map(Self.choiceLabel)
            body = .input(prompt: string(input, "prompt"), choices: choices)
        } else if let ended = fields["turnEnded"]?.objectValue {
            body = .turnEnded(reason: string(ended, "reason"))
        } else if let ext = fields["extension"]?.objectValue {
            let encoded = string(ext, "data")
            body = .attachment(type: string(ext, "type"), mediaType: string(ext, "mediaType"),
                               data: encoded.isEmpty ? Data() : Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        } else {
            body = .unrecognized
        }

        record = json.prettyText
    }

    /// A choice as text: the string itself, or the naming field of a structured choice.
    private static func choiceLabel(_ choice: AGUIValue) -> String {
        if let text = choice.stringValue { return text }
        if let object = choice.objectValue {
            for key in ["label", "title", "name", "text", "value", "id"] {
                if let text = object[key]?.stringValue, !text.isEmpty { return text }
            }
        }
        return choice.compactText
    }
}

struct Question: Decodable, Identifiable, Equatable, Sendable {
    let id, workerID, question, status, answer: String
    /// What the service knows about the answer reaching the worker. Absent on older records and on
    /// requests that have no answer yet.
    var delivery: String? = nil
    /// The explicit choices the service offered with the question. When present, the service
    /// accepts only the exact ID of one of them as the answer. Absent on free-form requests.
    var choices: [QuestionChoice]? = nil

    init(id: String, workerID: String, question: String, status: String, answer: String,
         delivery: String? = nil, choices: [QuestionChoice]? = nil) {
        self.id = id
        self.workerID = workerID
        self.question = question
        self.status = status
        self.answer = answer
        self.delivery = delivery
        self.choices = choices
    }

    /// One reader for the request API and the AG-UI projection, so both treat `choices` alike.
    init(from decoder: Decoder) throws { try self.init(projection: AGUIValue(from: decoder)) }

    /// The answer was accepted, and the service cannot say whether the worker received it.
    var deliveryIsUnknown: Bool { delivery?.lowercased() == "unknown" }
}

/// One choice offered with a request: the ID the reply must carry and the label to show.
struct QuestionChoice: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String

    init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    init(projection value: AGUIValue) throws {
        guard case .object(let fields) = value else { throw AGUIValueError("A choice is not an object") }
        self.init(id: try fields.string("id"), label: try fields.string("label"))
    }
}

extension Question {
    init(projection value: AGUIValue) throws {
        guard case .object(let fields) = value else { throw AGUIValueError("A request is not an object") }
        self.init(id: try fields.string("id"), workerID: try fields.string("worker_id"),
                  question: try fields.string("question"), status: try fields.string("status"),
                  answer: try fields.string("answer"), delivery: try fields.optionalString("delivery"),
                  choices: Self.choices(fields["choices"]))
    }

    /// The offered choices, all or none. A list with any element that is not an `{id, label}`
    /// object with both set, or a legacy list of strings, reads as no choices: the request stays
    /// free-form and its question keeps the service's text list. It never rejects the request.
    static func choices(_ value: AGUIValue?) -> [QuestionChoice]? {
        guard let list = try? AGUINode.list(value, make: QuestionChoice.init(projection:)),
              !list.isEmpty,
              list.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty }) else { return nil }
        return list
    }
}

struct Run: Decodable, Identifiable, Sendable {
    let id, project, path, task, client, coordinatorID, status: String
    let workers: [Worker]?
    let requests: [Question]?
    // Optional metadata. Older service records omit these; the interface shows them only when present.
    let givenTitle: String?
    let createdAt: String?
    let branch: String?

    /// Every field of the run as the service sent it, including those this model does not name,
    /// such as `worker_limit`, `test_command` and `integrations`.
    /// Workers are not repeated here: read `workers`. An empty object for a run that was not
    /// read from the service.
    let allFields: AGUIValue

    private let stamp: UInt64

    /// The members of `allFields` that have a typed property.
    static let namedFields: Set<String> = [
        "id", "project", "path", "task", "client", "coordinator_id", "status", "requests",
        "title", "created_at", "branch"
    ]

    init(id: String, project: String, path: String, task: String, client: String, coordinatorID: String,
         status: String, workers: [Worker]?, requests: [Question]?, givenTitle: String? = nil,
         createdAt: String? = nil, branch: String? = nil, allFields: AGUIValue = [:]) {
        self.id = id
        self.project = project
        self.path = path
        self.task = task
        self.client = client
        self.coordinatorID = coordinatorID
        self.status = status
        self.workers = workers
        self.requests = requests
        self.givenTitle = givenTitle
        self.createdAt = createdAt
        self.branch = branch
        self.allFields = allFields
        stamp = 0
    }

    /// Builds a run from its projected fields and its workers, which the reducer keeps apart.
    init(projection fields: [String: AGUIValue], workers: [Worker]?) throws {
        id = try fields.string("id")
        project = try fields.string("project")
        path = try fields.string("path")
        task = try fields.string("task")
        client = try fields.string("client")
        coordinatorID = try fields.string("coordinator_id")
        status = try fields.string("status")
        self.workers = workers
        requests = try fields.optionalList("requests", make: Question.init(projection:))
        givenTitle = try fields.optionalString("title")
        createdAt = try fields.optionalString("created_at")
        branch = try fields.optionalString("branch")
        allFields = .object(fields)
        stamp = AGUIStamp.next()
    }

    /// Reads a whole run object, as the request API and the legacy feed send it.
    init(projection value: AGUIValue) throws {
        var node = try AGUIRunNode(value: value)
        self = try node.materialize()
    }

    init(from decoder: Decoder) throws { try self.init(projection: AGUIValue(from: decoder)) }

    /// Reads the request API's `{ "runs": [...] }`. A missing or null list is empty.
    static func list(json data: Data) throws -> [Run] {
        try AGUINode.list(AGUIValue(json: data)["runs"], make: Run.init(projection:)) ?? []
    }

    /// The fields with no typed property, for an inspector. An object.
    var extendedFields: AGUIValue {
        .object((allFields.objectValue ?? [:]).filter { !Self.namedFields.contains($0.key) })
    }

    var canStop: Bool {
        if status == "running" { return true }
        return status == "failed" && (workers ?? []).contains { !["completed", "failed", "stopped"].contains($0.state) }
    }

    var coordinator: Worker? { workers?.first { $0.id == coordinatorID } }
    var delegates: [Worker] { (workers ?? []).filter { $0.id != coordinatorID } }
    var title: String {
        if let given = givenTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty { return given }
        return String(task.split(whereSeparator: \.isNewline).first ?? "Untitled run")
    }
}

extension Run: Equatable {
    static func == (lhs: Run, rhs: Run) -> Bool {
        // A run the feed did not touch is the same value as before.
        if lhs.stamp != 0, lhs.stamp == rhs.stamp { return true }
        return lhs.id == rhs.id && lhs.status == rhs.status && lhs.project == rhs.project && lhs.path == rhs.path &&
            lhs.task == rhs.task && lhs.client == rhs.client && lhs.coordinatorID == rhs.coordinatorID &&
            lhs.givenTitle == rhs.givenTitle && lhs.createdAt == rhs.createdAt && lhs.branch == rhs.branch &&
            lhs.requests == rhs.requests && lhs.workers == rhs.workers && lhs.allFields == rhs.allFields
    }
}

struct RunList: Decodable, Sendable { let runs: [Run]? }

struct PendingDecision: Identifiable {
    let run: Run
    let worker: Worker
    let request: Question
    var id: String { request.id }
}

enum ServiceError: LocalizedError {
    case offline(String)
    case rejected(String)
    var errorDescription: String? {
        switch self { case .offline(let detail), .rejected(let detail): detail }
    }
}

/// A refusal with its HTTP status, for a caller that acts on the status itself.
struct ServiceStatusError: LocalizedError, Equatable {
    let status: Int
    let message: String

    var errorDescription: String? { message }

    /// The service no longer holds the addressed item in a state that takes this request.
    var isWithdrawn: Bool { status == 404 || status == 409 }
}

/// The service the app talks to now: this Mac's own, or a headless host's through its
/// SSH-forwarded socket. One value is shared by every client path (requests, the two event
/// streams and the agentctl children), and each reads it when it starts a request, so a change
/// reaches all of them. `CommanderHostsModel` is the only writer.
final class ServiceEndpoint: @unchecked Sendable {
    /// A headless host's service, reached through the socket `agentctl host connect` forwards.
    struct Remote: Equatable, Sendable {
        let destination: String
        let socket: String
    }

    /// The endpoint the running app uses.
    static let live = ServiceEndpoint()

    /// This Mac's service socket.
    let localSocket: String
    private let lock = NSLock()
    private var selected: Remote?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["AGENT_COMMANDER_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ??
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Agent Commander")
        localSocket = environment["AGENT_COMMANDER_SOCKET"] ?? environment["AC_SOCKET"] ?? home.appending(path: "service.sock").path
    }

    /// The selected host, or nil while the app uses this Mac's service.
    var remote: Remote? {
        lock.lock()
        defer { lock.unlock() }
        return selected
    }

    /// The socket every request goes to.
    var socket: String { remote?.socket ?? localSocket }

    /// Points every client path at a host's forwarded socket, or back at this Mac with nil.
    /// Returns whether the socket changed.
    @discardableResult func select(_ remote: Remote?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = selected?.socket != remote?.socket
        selected = remote
        return changed
    }

    /// The environment for an agentctl child that must reach the selected service: a remote
    /// host's forwarded socket replaces the socket setting. This Mac's settings are left as given.
    func agentctlEnvironment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        guard let remote else { return base }
        var values = base
        values.removeValue(forKey: "AC_SOCKET")
        values["AGENT_COMMANDER_SOCKET"] = remote.socket
        return values
    }

    /// The agentctl the app runs: the named override, else the one bundled beside the executable.
    static func agentctl(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment["AGENT_COMMANDER_CLI"] ?? environment["AC_CLI"] { return URL(filePath: path) }
        return Bundle.main.url(forAuxiliaryExecutable: "agentctl") ??
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "agentctl")
    }
}

extension FileHandle {
    /// What is written to this handle, in the chunks it arrives in, read on the handle's own
    /// dispatch source. The stream ends when the writer closes its end.
    ///
    /// `FileHandle.bytes` reads every handle in the process through one shared actor, one blocking
    /// read at a time. A handle that stays quiet, like the output of `agentctl host connect`
    /// between events, holds that actor, and nothing reaches any other `bytes` reader until the
    /// quiet handle has data. Every long-lived child (both event streams and the host connection)
    /// is read this way instead, so each is independent of the others.
    var ownChunks: AsyncStream<Data> {
        AsyncStream { output in
            readabilityHandler = { handle in
                let data = handle.availableData
                // No data means the writer closed its end.
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    output.finish()
                } else {
                    output.yield(data)
                }
            }
            output.onTermination = { [weak self] _ in self?.readabilityHandler = nil }
        }
    }

    /// The lines written to this handle, read as `ownChunks` reads.
    var ownLines: AsyncStream<String> {
        let chunks = ownChunks
        return AsyncStream { output in
            let reader = Task.detached {
                var buffer = LineBuffer()
                for await chunk in chunks {
                    for line in buffer.take(chunk) { output.yield(line) }
                }
                if let rest = buffer.rest() { output.yield(rest) }
                output.finish()
            }
            output.onTermination = { _ in reader.cancel() }
        }
    }
}

/// Splits what a child writes into lines.
struct LineBuffer {
    private var pending = Data()

    /// The lines `chunk` completes.
    mutating func take(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...end)
        }
        return lines
    }

    /// A last line that was not ended, once the writer closed.
    mutating func rest() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

// All GUI operations use the service's HTTP API over the selected endpoint's socket. The
// serialized client keeps short requests off the UI thread and sends project paths and prompt
// text as JSON data.
actor ServiceClient {
    private let endpoint: ServiceEndpoint
    private let command: URL?

    /// The selected service's socket, read for each request.
    private nonisolated var socket: String { endpoint.socket }

    /// `endpoint` is the shared selection. Without one the client keeps to the local service the
    /// environment names.
    init(environment: [String: String] = ProcessInfo.processInfo.environment, endpoint: ServiceEndpoint? = nil) {
        self.endpoint = endpoint ?? ServiceEndpoint(environment: environment)
        command = ServiceEndpoint.agentctl(environment: environment)
    }

    /// The socket a request started now would use.
    nonisolated var currentSocket: String { socket }

    func runs() throws -> [Run] {
        try Run.list(json: request("/v1/runs"))
    }

    func watchRuns() -> AsyncThrowingStream<[Run], Error> {
        AGUIStream.follow(socket: socket)
    }

    /// One connection to the catalog notices: staged adapter updates. It runs beside the
    /// workspace feed and every request, so it never delays a conversation.
    nonisolated func watchAdapterUpdates() -> AsyncThrowingStream<[AdapterUpdate], Error> {
        AdapterUpdateStream.connect(socket: socket)
    }

    func create(path: String, task: String, title: String? = nil, operationID: String) throws -> Run {
        var fields = ["project": URL(filePath: path).lastPathComponent, "path": path, "task": task, "client": "claude"]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { fields["title"] = title }
        return try Run(projection: AGUIValue(json: request("/v1/runs", fields: fields, operationID: operationID)))
    }

    /// `generation` is the worker-control generation the developer answers a delegated worker's
    /// request under; the service refuses the reply once control has changed. Nil sends the
    /// request exactly as before: a coordinator's own request, and the legacy owner reply.
    func reply(to requestID: String, answer: String, operationID: String, generation: Int? = nil) throws {
        _ = try Self.send(socket: socket, path: "/v1/requests/\(requestID)/reply",
                          body: Self.replyBody(answer: answer, generation: generation), operationID: operationID)
    }

    /// The reply request's JSON. `generation` is left out when nil, never sent as null.
    static func replyBody(answer: String, generation: Int?) throws -> Data {
        struct Reply: Encodable { let answer: String; let generation: Int? }
        return try JSONEncoder().encode(Reply(answer: answer, generation: generation))
    }

    func stop(runID: String) throws {
        _ = try request("/v1/runs/\(runID)/stop", fields: [String: String]())
    }

    func setWorkerControl(_ workerID: String, held: Bool, generation: Int) throws {
        struct Change: Encodable { let held: Bool; let generation: Int }
        _ = try request("/v1/workers/\(workerID)/control", fields: Change(held: held, generation: generation))
    }

    func sendFollowUp(to workerID: String, text: String, generation: Int, operationID: String) throws {
        struct FollowUp: Encodable { let text: String; let generation: Int }
        _ = try request("/v1/workers/\(workerID)/messages",
                        fields: FollowUp(text: text, generation: generation), operationID: operationID)
    }

    /// Sends a follow-up whose content carries file context: `body` is the whole JSON request,
    /// `{ "generation": N, "content": [...] }`, already encoded and checked against the service's
    /// request bound by `FollowUpContent.requestBody`. The same route and idempotency header as text.
    func sendFollowUp(to workerID: String, body: Data, operationID: String) throws {
        _ = try Self.send(socket: socket, path: "/v1/workers/\(workerID)/messages", body: body,
                          operationID: operationID)
    }

    /// Takes back a follow-up that is still queued. The service refuses once it has started.
    func cancelFollowUp(_ workerID: String, messageID: String) throws {
        _ = try request("/v1/workers/\(Self.percentEncoded(workerID))/messages/\(Self.percentEncoded(messageID))/cancel",
                        fields: [String: String]())
    }

    // MARK: Tool details (internal/service/tool_details.go). Owner socket only.

    /// The worker's tool-detail summaries changed after `revision`. Not queued behind this
    /// client's other requests, and cancellable.
    nonisolated func toolDetails(_ workerID: String, after revision: UInt64) async throws -> ToolDetailPage {
        try JSONDecoder().decode(ToolDetailPage.self, from: await read(Self.toolDetailsPath(workerID, after: revision), timeout: 6))
    }

    /// One full record, read when its line is opened.
    nonisolated func toolDetail(_ workerID: String, key: String) async throws -> ToolDetailRecord {
        try JSONDecoder().decode(ToolDetailRecord.self, from: await read(Self.toolDetailPath(workerID, key: key), timeout: 10))
    }

    nonisolated func transcriptSettings() async throws -> TranscriptSettings {
        try JSONDecoder().decode(TranscriptSettings.self, from: await read("/v1/settings/transcript", timeout: 6))
    }

    /// Applies to records stored from now on. Returns what the service kept.
    func setTranscriptSettings(_ settings: TranscriptSettings) throws -> TranscriptSettings {
        try JSONDecoder().decode(TranscriptSettings.self, from: try request("/v1/settings/transcript", fields: settings))
    }

    nonisolated static func toolDetailsPath(_ workerID: String, after revision: UInt64) -> String {
        "/v1/workers/\(percentEncoded(workerID))/tool-details?after=\(revision)"
    }

    nonisolated static func toolDetailPath(_ workerID: String, key: String) -> String {
        "/v1/workers/\(percentEncoded(workerID))/tool-details?key=\(percentEncoded(key))"
    }

    // MARK: Provider session

    /// What the service knows about the worker's provider session. Not queued behind this
    /// client's other requests, and cancellable.
    nonisolated func providerSessionStatus(_ workerID: String) async throws -> ProviderSessionStatus {
        try ProviderSessionStatus(json: await read(Self.providerSessionPath(workerID), timeout: 6))
    }

    /// One page of the sessions the worker's provider lists in its scope. `cursor` is the
    /// `next_cursor` of an earlier page of the same worker. The service gives a provider up to 20
    /// seconds to answer.
    nonisolated func providerSessions(_ workerID: String, cursor: String? = nil,
                                      limit: Int = ProviderSessionPage.limit) async throws -> ProviderSessionPage {
        try ProviderSessionPage(json: await read(Self.providerSessionsPath(workerID, cursor: cursor, limit: limit),
                                                 timeout: 25))
    }

    /// Reattaches the worker to its own bound provider session under `request.generation`. The
    /// same `operationID` is sent for a retry of the same request, so the service applies it once.
    func reattachWorker(_ workerID: String, request body: ProviderReattachRequest, operationID: String) throws {
        _ = try request("/v1/workers/\(Self.percentEncoded(workerID))/reattach", fields: body,
                        operationID: operationID)
    }

    nonisolated static func providerSessionPath(_ workerID: String) -> String {
        "/v1/workers/\(percentEncoded(workerID))/session"
    }

    /// The path and query of one page of provider sessions. Every value is percent-encoded.
    nonisolated static func providerSessionsPath(_ workerID: String, cursor: String? = nil,
                                                 limit: Int = ProviderSessionPage.limit) -> String {
        var query = "limit=\(min(max(limit, 1), 128))"
        if let cursor, !cursor.isEmpty { query += "&cursor=\(percentEncoded(cursor))" }
        return "/v1/workers/\(percentEncoded(workerID))/provider-sessions?\(query)"
    }

    // MARK: Elicitation

    /// The structured requests the worker's agent has put to its owner. Not queued behind this
    /// client's other requests, and cancellable.
    nonisolated func elicitations(_ workerID: String) async throws -> [Elicitation] {
        try Elicitation.list(json: await read(Self.elicitationsPath(workerID), timeout: 6))
    }

    /// Sends the owner's decision on one request. `body` is the whole JSON request from
    /// `ElicitationReply.body`. A refusal carries its status, so a 404 or 409 reads as withdrawn.
    /// Off the request queue and off the main actor; it is not cancelled with the panel.
    nonisolated func replyToElicitation(_ workerID: String, id: String, body: Data) async throws {
        let socket = socket
        let path = Self.elicitationReplyPath(workerID, id: id)
        _ = try await Task.detached(priority: .userInitiated) {
            try Self.send(socket: socket, path: path, body: body, operationID: nil, reportsStatus: true)
        }.value
    }

    nonisolated static func elicitationsPath(_ workerID: String) -> String {
        "/v1/workers/\(percentEncoded(workerID))/elicitations"
    }

    nonisolated static func elicitationReplyPath(_ workerID: String, id: String) -> String {
        "/v1/workers/\(percentEncoded(workerID))/elicitations/\(percentEncoded(id))/reply"
    }

    /// Reads one GET answer at `path`, off the request queue and cancellable.
    private nonisolated func read(_ path: String, timeout: Int) async throws -> Data {
        let socket = socket
        let transfer = Transfer()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let data = try Self.send(socket: socket, path: path, body: nil, operationID: nil,
                                         timeout: timeout, transfer: transfer)
                try Task.checkCancellation()
                return data
            }.value
        } onCancel: {
            transfer.cancel()
        }
    }

    /// Interrupts the worker's current turn. With a `target`, the request names the observed turn
    /// and control generation, so a retry returns the same receipt and a stale one is rejected.
    /// Without one the body is the original empty object.
    func interruptWorker(_ workerID: String, target: WorkerInterruptTarget? = nil) throws {
        _ = try request("/v1/workers/\(workerID)/interrupt", fields: Self.interruptFields(target))
    }

    /// The interrupt request's JSON body.
    nonisolated static func interruptFields(_ target: WorkerInterruptTarget?) -> any Encodable {
        if let target { return target }
        return [String: String]()
    }

    func stopWorker(_ workerID: String) throws {
        _ = try request("/v1/workers/\(workerID)/stop", fields: [String: String]())
    }

    /// One page of a worker's source records. The worker ID is the only address: the service has
    /// already bound the provider session. `cursor` is the `nextCursor` of an earlier page of the
    /// same worker and source.
    ///
    /// A read is not queued behind this client's other requests, and cancelling the calling task
    /// ends the transfer, so an abandoned read does not hold up the next one.
    nonisolated func workerHistory(_ workerID: String, source: ConsoleSourceKind, cursor: String? = nil,
                                   limit: Int = 12, turnID: String? = nil,
                                   kind: String? = nil) async throws -> SourcePage {
        try await historyPage(Self.historyPath(workerID, source: source, cursor: cursor, limit: limit,
                                               turnID: turnID, kind: kind))
    }

    /// The page that holds one record of a worker's provider history: the record whose cursor is
    /// `recordCursor`, or one gap that says why it cannot be read. `pageCursor` is the opaque hint
    /// the message gave for where that record sits; without it the service starts at the first
    /// page. Nothing else narrows the request, so the service's default reader, the provider's own
    /// history, answers it.
    nonisolated func workerRecord(_ workerID: String, recordCursor: String,
                                  pageCursor: String? = nil) async throws -> SourcePage {
        try await historyPage(Self.recordPath(workerID, recordCursor: recordCursor, pageCursor: pageCursor))
    }

    /// The path and query of a one-record read. Only `recordCursor` and, when given, `cursor` are
    /// sent: no source, kind, turn, view or limit. Every value is percent-encoded.
    nonisolated static func recordPath(_ workerID: String, recordCursor: String, pageCursor: String? = nil) -> String {
        var query = "recordCursor=\(percentEncoded(recordCursor))"
        if let pageCursor, !pageCursor.isEmpty { query += "&cursor=\(percentEncoded(pageCursor))" }
        return "/v1/workers/\(percentEncoded(workerID))/history?\(query)"
    }

    /// Reads one history page at `path`, off the request queue and cancellable.
    private nonisolated func historyPage(_ path: String) async throws -> SourcePage {
        let socket = socket
        let transfer = Transfer()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                // A provider may take longer to read its history than a state change takes to accept.
                let data = try Self.send(socket: socket, path: path, body: nil, operationID: nil,
                                         timeout: 20, transfer: transfer)
                try Task.checkCancellation()
                return try SourcePage(envelope: data)
            }.value
        } onCancel: {
            transfer.cancel()
        }
    }

    /// The path and query of one history page. `turnID` and `kind` narrow the page to one turn's
    /// records of one kind, such as the media parts of a prompt. Every ID is percent-encoded.
    nonisolated static func historyPath(_ workerID: String, source: ConsoleSourceKind, cursor: String? = nil,
                                        limit: Int = 12, turnID: String? = nil, kind: String? = nil) -> String {
        var query = "limit=\(limit)"
        if let value = source.queryValue { query += "&source=\(value)" }
        if let turnID, !turnID.isEmpty { query += "&turnId=\(percentEncoded(turnID))" }
        if let kind, !kind.isEmpty { query += "&kind=\(percentEncoded(kind))" }
        if let cursor, !cursor.isEmpty { query += "&cursor=\(percentEncoded(cursor))" }
        return "/v1/workers/\(percentEncoded(workerID))/history?\(query)"
    }

    /// The process of one cancellable request. Cancelling before it starts stops it at launch.
    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func started(_ process: Process) {
            lock.lock()
            defer { lock.unlock() }
            self.process = process
            if cancelled { process.terminate() }
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// Percent-encodes everything outside the RFC 3986 unreserved set, for one path segment or
    /// query value.
    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: Harnesses (design/HARNESSES.md)

    /// One connection to the harness list. It runs beside the workspace feed and every request.
    nonisolated func watchHarnesses() -> AsyncThrowingStream<[Harness], Error> {
        HarnessStream.connect(socket: socket)
    }

    /// Probes one harness again and returns it.
    nonisolated func checkHarness(_ id: String) async throws -> Harness {
        try HarnessSnapshot.decodeOne(try await harnessCall("POST", "\(Self.percentEncoded(id))/check", timeout: 30))
    }

    /// Starts the harness's own sign-in or install command in its tmux session.
    nonisolated func startHarnessSession(_ id: String, purpose: HarnessSession.Purpose) async throws -> HarnessAttachment {
        try HarnessSnapshot.decodeAttachment(try await harnessCall("POST", "\(Self.percentEncoded(id))/\(purpose.rawValue)", timeout: 20))
    }

    nonisolated func saveHarnessSettings(_ id: String, _ settings: Harness.Settings) async throws -> Harness {
        struct Body: Encodable { let enabled: Bool; let default_model: String }
        let body = try JSONEncoder().encode(Body(enabled: settings.enabled, default_model: settings.defaultModel))
        return try HarnessSnapshot.decodeOne(try await harnessCall("PUT", "\(Self.percentEncoded(id))/settings", body: body, timeout: 10))
    }

    /// One harness request, off the request queue and cancellable. No bearer credential is sent:
    /// the routes refuse an Authorization header.
    private nonisolated func harnessCall(_ method: String, _ rest: String, body: Data? = nil, timeout: Int) async throws -> Data {
        let socket = socket
        let transfer = Transfer()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let data = try Self.send(socket: socket, path: "/v1/harnesses/\(rest)", body: body ?? Data("{}".utf8),
                                         operationID: nil, timeout: timeout, transfer: transfer, method: method)
                try Task.checkCancellation()
                return data
            }.value
        } onCancel: {
            transfer.cancel()
        }
    }

    func startService() throws {
        // A headless host's service is started on that host. Only this Mac's is started from here.
        if let remote = endpoint.remote {
            throw ServiceError.offline("The service on \(remote.destination) is unreachable.")
        }
        guard let command, FileManager.default.isExecutableFile(atPath: command.path) else {
            throw ServiceError.offline("Start the local service with agentctl start, or open the built Agent Commander app.")
        }
        let process = Process()
        process.executableURL = command
        process.arguments = ["start"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ServiceError.offline(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func request(_ path: String, fields: (any Encodable)? = nil, operationID: String? = nil) throws -> Data {
        let body = try fields.map { try JSONEncoder().encode($0) }
        return try Self.send(socket: socket, path: path, body: body, operationID: operationID)
    }

    /// One request over the owner socket. `transfer`, when given, lets the caller end it early.
    /// With `reportsStatus`, a refusal is a `ServiceStatusError` carrying its HTTP status.
    private static func send(socket: String, path: String, body: Data?, operationID: String?,
                             timeout: Int = 6, transfer: Transfer? = nil, reportsStatus: Bool = false,
                             method: String? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/curl")
        var args = ["--disable", "--silent", "--show-error", "--max-time", String(timeout), "--noproxy", "*",
                    "--unix-socket", socket, "--write-out", "\n%{http_code}"]
        if let operationID { args += ["--header", "Idempotency-Key: \(operationID)"] }
        if let method { args += ["--request", method] }
        let input = Pipe()
        if body != nil {
            args += ["--header", "Content-Type: application/json", "--data-binary", "@-"]
            process.standardInput = input
        }
        process.arguments = args + ["http://localhost\(path)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        transfer?.started(process)
        if let body {
            try input.fileHandleForWriting.write(contentsOf: body)
            try input.fileHandleForWriting.close()
        }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ServiceError.offline("The service is unreachable at \(socket).")
        }
        guard let separator = bytes.lastIndex(of: 10), let status = Int(String(decoding: bytes.suffix(from: separator + 1), as: UTF8.self)) else {
            throw ServiceError.rejected("The service returned an unreadable response.")
        }
        let payload = bytes.prefix(upTo: separator)
        guard (200..<300).contains(status) else {
            let info = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let message = info?["error"] as? String ?? info?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            if reportsStatus { throw ServiceStatusError(status: status, message: message) }
            throw ServiceError.rejected(message)
        }
        return Data(payload)
    }
}
