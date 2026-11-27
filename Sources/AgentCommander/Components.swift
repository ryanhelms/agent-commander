import AppKit
import SwiftUI

// COMPONENT CONTRACTS and the terminal leaf.
// Components receive these values and emit targeted actions. The mapping from the service types
// (Run, Worker, Question) lives at the bottom of this file, so no atom, molecule or organism reads
// the API model or a global "current worker". Design fixtures build the same values directly.

// MARK: - Shared vocabulary

enum Tone: Equatable {
    case working, attention, failure, focus, neutral

    var color: Color {
        switch self {
        case .working: Palette.working
        case .attention: Palette.attention
        case .failure: Palette.failure
        case .focus: Palette.focus
        case .neutral: Palette.secondary
        }
    }
}

enum AgentClient: Equatable {
    case claude, codex, mcp, other(String)

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .mcp: "MCP client"
        case .other(let name): name.isEmpty ? "Agent" : name
        }
    }
}

/// Task progress. Human attention (a pending request) is folded in only for the label; the request
/// itself stays a separate value on the worker. A lost connection is reported ahead of a pending
/// request: the request is still shown beside it, but it cannot be answered until the service has
/// reconciled the worker, so "Needs input" would promise an action that is not available.
enum TaskState: Equatable {
    case running, working, idle, needsInput, starting, stopping, completed, failed, stopped
    case disconnected
    case unknown(String)

    /// A turn is in progress: the worker is starting, running or working.
    var isActiveTurn: Bool {
        switch self {
        case .running, .working, .starting: true
        default: false
        }
    }

    /// The service's worker state for a lost connection. A contract value.
    static let apiDisconnected = "disconnected"

    init(api: String, hasPendingRequest: Bool = false) {
        if api.lowercased() == Self.apiDisconnected { self = .disconnected; return }
        if hasPendingRequest { self = .needsInput; return }
        switch api.lowercased() {
        case "running": self = .running
        case "working": self = .working
        case "idle": self = .idle
        case "waiting": self = .needsInput
        case "starting": self = .starting
        case "stopping": self = .stopping
        case "completed": self = .completed
        case "failed": self = .failed
        case "stopped": self = .stopped
        default: self = .unknown(api)
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .working: "Working"
        case .idle: "Idle"
        case .needsInput: "Needs input"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .disconnected: "Disconnected"
        case .unknown(let raw): raw.isEmpty ? "Unknown" : raw.capitalized
        }
    }

    var tone: Tone {
        switch self {
        case .running, .working, .completed: .working
        case .needsInput, .starting, .stopping, .disconnected: .attention
        case .failed: .failure
        case .idle, .stopped, .unknown: .neutral
        }
    }

    /// One-cell mark shown beside the lowercase label in terminal status lines.
    var glyph: String {
        switch self {
        case .running, .working: "●"
        case .idle: "○"
        case .needsInput: "?"
        case .starting, .stopping: "…"
        case .completed: "✓"
        case .failed: "✗"
        case .stopped: "■"
        case .disconnected: "!"
        case .unknown: "·"
        }
    }

    /// Terminal ink for the state. Always shown with `glyph` and the label.
    var ink: Color {
        switch tone {
        case .working: Term.green
        case .attention: Term.amber
        case .failure: Term.red
        case .focus: Term.cyan
        case .neutral: Term.dim
        }
    }

    /// Distinct symbol used when Differentiate Without Color is on.
    var symbol: String {
        switch self {
        case .running, .working: "circle.fill"
        case .idle: "pause.circle"
        case .needsInput: "questionmark.circle.fill"
        case .starting, .stopping: "clock"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .stopped: "stop.circle"
        case .disconnected: "bolt.slash.fill"
        case .unknown: "questionmark.diamond"
        }
    }
}

/// Terminal input ownership as the interface can truthfully state it today. The API has no lease,
/// so production always reports `.observing`; `.held` exists for the design fixture and the future lease.
enum InputControl: Equatable {
    case observing(holder: String)
    case held
}

/// The platform a terminal executes on. It comes only from explicit platform metadata for the
/// execution host. It is never derived from a host name, a branch or the transport, so a host
/// without that metadata is `.unknown` and renders neutrally.
enum HostPlatform: Equatable {
    /// This Mac: the terminal runs on the machine Commander runs on.
    case localMac
    /// Another Mac, reached over SSH.
    case remoteMac
    /// A Linux host, reached over SSH.
    case remoteLinux
    /// No platform metadata for this host.
    case unknown

    var isRemote: Bool { self == .remoteMac || self == .remoteLinux }

    /// Spoken and tooltip name of the platform.
    var label: String {
        switch self {
        case .localMac: "macOS, this Mac"
        case .remoteMac: "macOS over SSH"
        case .remoteLinux: "Linux over SSH"
        case .unknown: "platform not reported"
        }
    }
}

/// What a tool call returned: its output and, when it did not succeed, the service's error. Either
/// can be empty without the other.
struct ToolResult: Equatable {
    let output: String
    /// The service's reason the call ended without succeeding, trimmed. Nil on success.
    let error: String?

    init(output: String, error: String? = nil) {
        self.output = output
        let reason = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.error = reason.isEmpty ? nil : reason
    }

    /// The error, when the output does not already state it. The service can include its error in
    /// the output; it is then shown once, as output. The match is on whole lines.
    var separateError: String? {
        guard let error else { return nil }
        let wanted = Self.lines(error), present = Self.lines(output)
        guard present.count >= wanted.count else { return error }
        let found = (0...(present.count - wanted.count)).contains { start in
            Array(present[start..<(start + wanted.count)]) == wanted
        }
        return found ? nil : error
    }

    /// True when there is an error or any output to read.
    var hasText: Bool { error != nil || output.contains { !$0.isWhitespace } }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Where a tool call stands. This is the one mapping from a result to a status; the Console and
/// Pretty transcripts, the focused worker and the PiP all read it through `TranscriptToolRow`.
enum ToolStatus: Equatable {
    case running, done, failed, declined, cancelled, interrupted
    /// A call with no result whose worker is waiting for the developer's reply to a request. Never
    /// read from a result: only the ACP Pretty console sets it, for the open call it can identify.
    case awaitingApproval

    /// No result yet is running, and a result without an error is done. The service's fixed
    /// reasons name their own status, and any other error is a failure.
    init(result: ToolResult?) {
        guard let result else { self = .running; return }
        guard let error = result.error else { self = .done; return }
        var reason = error.lowercased()
        while reason.hasSuffix(".") { reason.removeLast() }
        switch reason {
        case "tool declined": self = .declined
        case "tool cancelled", "tool canceled": self = .cancelled
        case "tool interrupted": self = .interrupted
        default: self = .failed
        }
    }

    var word: String {
        switch self {
        case .running: "running"
        case .done: "done"
        case .failed: "failed"
        case .declined: "declined"
        case .cancelled: "cancelled"
        case .interrupted: "interrupted"
        // Written as the status it is everywhere it is read, visible row and spoken label alike.
        case .awaitingApproval: "Awaiting approval"
        }
    }

    /// The terminal mark ahead of the word, so the status never rests on colour alone.
    var mark: String {
        switch self {
        case .running: "…"
        case .awaitingApproval: "?"
        case .done: "✓"
        case .failed: "✗"
        case .declined, .cancelled, .interrupted: "!"
        }
    }

    /// Green for success and red for failure. Amber for a call still running and for one that was
    /// stopped before it could finish, which is neither.
    var ink: Color {
        switch self {
        case .done: Term.green
        case .failed: Term.red
        case .running, .awaitingApproval, .declined, .cancelled, .interrupted: Term.amber
        }
    }
}

/// One entry of a console's structured transcript, built from the service's AG-UI messages. A
/// tool call and its result are one entry, so showing a window of entries never leaves a result
/// without its call. IDs are the service's message and tool-call IDs and stay stable as the
/// transcript grows.
struct TranscriptEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Text written by the agent, or by the developer when `fromUser` is set.
        case prose(String, fromUser: Bool)
        /// A tool call. `detail` is the call's own summary when it has one. `result` is nil while
        /// the call is still running.
        case tool(name: String, detail: String?, result: ToolResult?)
        /// A tool result whose call the service did not send.
        case output(ToolResult)
        /// A message from any other role, named as the service names it. The text can be empty:
        /// the entry then stands for a record whose content is only in its fields.
        case other(role: String, text: String)
    }

    let id: String
    let kind: Kind
    /// What the service's ACP reference says about the entry's record. Nil without one. Pretty
    /// uses it to read a run of live chunks as one turn; see `ConversationChunks`.
    var origin: TranscriptOrigin? = nil
    /// For a Commander tool call, the `commander` correlation object its arguments carried and
    /// the live request state the projection matched to it. Nil for every other entry. Pretty
    /// links Commander calls only through it and the calls' own exact IDs; see `CommanderActivity`.
    var commander: CommanderCallFacts? = nil
    /// For a result whose call the service did not send: the tool call ID the result names, when
    /// it names one. Stored details are kept under it.
    var toolCallID: String? = nil

    /// The key the entry's stored details are kept under: the call's ID.
    var detailKey: String { toolCallID ?? id }

    var isFromUser: Bool {
        if case .prose(_, let fromUser) = kind { return fromUser }
        return false
    }
}

// MARK: - Presentation values

struct RequestPresentation: Identifiable, Equatable {
    let id: String
    let shortID: String
    let question: String
    let workerID: String
    let workerName: String
    let workerIsCoordinator: Bool
    let client: AgentClient
    let runID: String
    let runTitle: String
    let project: String
    let host: String
    let platform: HostPlatform
    let inputHolder: String
    let contextTail: [String]
    /// The worker's most recent structured transcript entries, when the service sends structured
    /// messages. Empty otherwise, and the surface shows `contextTail`.
    var contextEntries: [TranscriptEntry] = []
    /// The asking worker's current conversation turn (`TranscriptEntry.currentTurn`), from that
    /// worker's own transcript. Pretty in the PiP groups it as the focused worker does and then
    /// shows a bounded part (`ActivityConversation.recent`), so a failure or the latest group is
    /// never lost to the four-entry cut. Console and Terminal keep `contextEntries`.
    var turnEntries: [TranscriptEntry] = []
    /// What Pretty in the PiP reads: the current turn, or the recent entries where a request was
    /// built without one.
    var prettyEntries: [TranscriptEntry] { turnEntries.isEmpty ? contextEntries : turnEntries }
    /// Set while the worker that asked is disconnected, with the service's explanation. The
    /// request stays pending and readable. It cannot be answered until the service has reconciled
    /// the worker, so every reply surface is closed and says why.
    var disconnectReason: String? = nil

    var isWorkerDisconnected: Bool { disconnectReason != nil }

    /// The persistent SSH link to the worker's host is reconnecting. The worker is still running
    /// on that host and the request can be answered: Commander keeps one answer and the worker
    /// reads it when the link comes back. Never set together with `disconnectReason`.
    var hostIsReconnecting = false
    /// The asking worker's background jobs, as on its own console.
    var workerBackgroundJobs: [BackgroundJob] = []
    /// The service says the asking worker's turn is still running (`WorkerPresentation.turnIsRunning`).
    var workerTurnIsRunning = false
    /// The asking worker's provider session, when the service has bound one. A request surface
    /// uses it to point to that worker's source inspector.
    var workerSession: NativeSession? = nil
    /// The explicit choices the service offered. When present, the reply must be the exact ID of
    /// one of them; the service rejects any other answer. Empty for a free-form request.
    var choices: [QuestionChoice] = []
    /// The asking worker's reported provider usage, as on its tile. Nil without a session.
    var workerTelemetry: ProviderTelemetry? = nil
    /// The asking worker's one tool call that is awaiting this request's approval, resolved from
    /// its whole transcript before `contextEntries` is cut to a recent window. Nil unless the
    /// request offers choices and exactly one call is open; see `PrettyRunStatus.awaitingToolID`.
    var awaitingApprovalToolID: String? = nil
    /// This request's Commander workflow (its ask, waits and linked result), linked over the
    /// asking worker's whole transcript before `contextEntries` is cut to a recent window, so the
    /// PiP reads the request as one story with its Ask. Nil when no Commander call names it.
    var requestWorkflow: CommanderWorkflow? = nil

    /// The question without the choice list the service appends for text surfaces, when that
    /// list is exactly the one `choices` describes. Otherwise the question as sent.
    var promptWithoutChoiceList: String {
        guard !choices.isEmpty else { return question }
        let suffix = "\nReply with one of the IDs in brackets."
            + choices.map { "\n\($0.label) [\($0.id)]" }.joined()
        guard question.hasSuffix(suffix) else { return question }
        return String(question.dropLast(suffix.count))
    }

    /// What happens to a reply sent while the host reconnects, in full. Nil otherwise.
    var replyHeldStatement: String? {
        guard hostIsReconnecting, !isWorkerDisconnected else { return nil }
        return "The SSH link to \(host) is reconnecting. \(workerName) is still running there. "
            + "You can reply to request \(shortID) now: Commander keeps one answer and "
            + "\(workerName) reads it when the link comes back."
    }

    /// Status of the asking worker as a request surface states it.
    var workerState: TaskState { isWorkerDisconnected ? .disconnected : .needsInput }

    /// Why the reply is closed, in full. Nil when the request can be answered.
    var replyUnavailableStatement: String? {
        guard let disconnectReason else { return nil }
        return "\(workerName) is disconnected. Replying to request \(shortID) is unavailable until "
            + "\(host) reconnects and Commander has reconciled this request. \(disconnectReason)"
    }
}

struct WorkerPresentation: Identifiable, Equatable {
    let id: String
    let shortID: String
    let name: String
    let client: AgentClient
    let host: String
    let platform: HostPlatform
    /// Branch when the service reports one, otherwise the worktree directory name.
    let location: String
    let locationIsBranch: Bool
    let task: String
    let output: String
    let error: String?
    let state: TaskState
    let isCoordinator: Bool
    /// Run title, then each parent worker, then this worker.
    let lineage: [String]
    let control: InputControl
    /// The worker's first pending request in the service's order: the one its inline form answers
    /// and its tile marks. Further requests from the same worker are in `pendingRequests`.
    let request: RequestPresentation?
    /// Local clock time the worker started, when the service recorded it.
    let startedAt: String?
    /// Structured transcript, when the service sends structured messages for this worker. Empty
    /// otherwise, and the surface shows `output` in the terminal well.
    var transcript: [TranscriptEntry] = []
    /// Follow-ups the service has accepted for this worker and not yet delivered to it.
    var queuedFollowUps = 0
    /// The follow-ups the service holds for this worker's next turn, oldest first, as written.
    var queuedMessages: [QueuedFollowUp] = []
    /// Every follow-up receipt of a managed local Claude worker, from the service's durable
    /// `control.messages`, with what a queued one waits for. Nil for every other worker and while
    /// the service lists none; those keep the `queuedFollowUps` cue.
    var followUpReceipts: FollowUpReceipts? = nil
    /// The service has been asked to interrupt this worker's current turn and has not done so yet.
    var interruptRequested = false
    /// The service's receipt for the latest interrupt of this worker, with the last confirmed step
    /// and outcome, addressed to its original turn. Nil from an older service and for a coordinator,
    /// whose surfaces keep the `interruptRequested` cue.
    var interruptReceipt: InterruptReceiptStatement? = nil
    /// Short ID of this worker's most recent answered request whose delivery the service could not
    /// confirm. The answer was accepted; whether the worker received it is unknown.
    var unconfirmedReply: String? = nil
    /// The persistent SSH link to this worker's host is reconnecting. `state` is still the
    /// worker's own turn state, and a pending request can still be answered.
    var hostIsReconnecting = false
    /// The provider session the service has bound this worker to. Nil for a legacy or unbound
    /// worker, which has no source inspector and shows its console as before.
    var session: NativeSession? = nil
    /// What the bound provider session last reported about its consumption. Nil for a worker
    /// without a session, whose footer shows no usage cue; empty when it has reported nothing.
    var telemetry: ProviderTelemetry? = nil
    /// The service's reported progress for a delegated worker on the built-in local Claude
    /// session. Nil for every other worker, whose footer and Pretty status are unchanged.
    var claudeProgress: ClaudeProgressTrack? = nil
    /// Whether the bound local Claude adapter has exited or is being checked after a service
    /// restart. Nil for every other worker, whose surfaces and gates are unchanged. Independent of
    /// `state`, which keeps the worker's own Completed, Idle or Unknown.
    var providerAvailability: ProviderAvailability? = nil
    /// Every pending request from this worker, in the service's order, each by its own ID. The
    /// first is `request`. Empty where a fixture sets only `request`; see `allRequests`.
    var pendingRequests: [RequestPresentation] = []
    /// The worker's checkout as the service reports it. A file link is offered only inside it.
    var checkout: String = ""
    /// The prompt content the session accepts beyond text, from the service's control record.
    /// Nil from an older service, and the follow-up then offers no file context.
    var promptCapabilities: WorkerPromptCapabilities? = nil
    /// The jobs this worker's calls started, each read from the run by exact ID.
    var backgroundJobs: [BackgroundJob] = []
    /// The service's own state says a turn is in progress, whatever `state` reads. A worker that
    /// asked the developer a question and waits for the reply inside its turn reads needs-input,
    /// and its turn is still running: the live line spins and the message box queues.
    var turnIsRunning = false

    var isDisconnected: Bool { state == .disconnected }
    /// A turn is in progress: the message box queues and offers Stop. A disconnected or finished
    /// worker is never in a turn.
    var isInTurn: Bool { state.isActiveTurn || (state == .needsInput && turnIsRunning) }

    /// The scope a follow-up's file context is prepared in. Nil when the session accepts neither a
    /// file link nor a snapshot.
    var followUpContextScope: FollowUpContextScope? {
        guard let promptCapabilities, promptCapabilities.acceptsFileContext else { return nil }
        return FollowUpContextScope(workerID: id, host: host, checkout: checkout, capabilities: promptCapabilities)
    }

    /// An interrupt of this worker's current turn is waiting: the legacy flag, or an unresolved
    /// receipt for the turn the worker is in now. The action list shows it as requested.
    var interruptPending: Bool {
        if interruptRequested { return true }
        guard let receipt = interruptReceipt, receipt.receipt.isUnresolved else { return false }
        return receipt.activeTurnID == receipt.receipt.turnID
    }

    /// Every pending request from this worker, oldest first. Attention counts and navigates these
    /// by request ID, so a second approval stays reachable while the first is answered inline.
    var allRequests: [RequestPresentation] {
        pendingRequests.isEmpty ? (request.map { [$0] } ?? []) : pendingRequests
    }

    /// What the worker's surfaces say about its availability. Nil while it is normal.
    var availabilityStatement: ProviderAvailabilityStatement? {
        providerAvailability.map { ProviderAvailabilityStatement(availability: $0, serviceError: error, workerName: name) }
    }
}

struct WorkerGroup: Identifiable, Equatable {
    let parent: WorkerPresentation
    let members: [WorkerPresentation]
    var id: String { parent.id }
    var all: [WorkerPresentation] { [parent] + members }
}

struct WallLayout: Equatable {
    var leaves: [WorkerPresentation] = []
    var groups: [WorkerGroup] = []
    var workers: [WorkerPresentation] { leaves + groups.flatMap(\.all) }
}

struct RunSummary: Identifiable, Equatable {
    let id: String
    let project: String
    let path: String
    let title: String
    let status: TaskState
}

struct RunContent: Identifiable, Equatable {
    let id: String
    let shortID: String
    let project: String
    let path: String
    let title: String
    let task: String
    let client: AgentClient
    let branch: String?
    let startedAt: String?
    let status: TaskState
    let canStop: Bool
    let coordinator: WorkerPresentation?
    let wall: WallLayout
    let awaiting: [RequestPresentation]
}

struct CockpitContent {
    var connection: CockpitModel.Connection
    var notice: String?
    var isStopping: Bool
    var runs: [RunSummary]
    var selected: RunContent?
    /// Pending requests across every run, oldest first.
    var pending: [RequestPresentation]
    var sending: Set<String>
    /// The open source inspection, for the one worker whose source is being read.
    var sourceInspection: SourceInspection? = nil
}

/// Targeted intents emitted by the cockpit. Each names its run or request by stable ID.
struct CockpitActions {
    var selectRun: @MainActor (String) -> Void
    var reply: @MainActor (_ requestID: String, _ answer: String) async -> Bool
    var stopRun: @MainActor (_ runID: String) -> Void
    var reconnect: @MainActor () -> Void
    var dismissNotice: @MainActor () -> Void
    var createRun: @MainActor (_ path: String, _ task: String, _ title: String?, _ operationID: String) async throws -> Void
    /// Hands a worker the developer controls back to its owner.
    var handBack: (@MainActor (_ workerID: String) -> Void)? = nil
    /// Sends a follow-up message to one worker the developer controls. The text is passed exactly
    /// as written. Returns true once the service accepts it; false leaves the draft in place.
    var sendFollowUp: (@MainActor (_ workerID: String, _ text: String) async -> Bool)? = nil
    /// Sends a follow-up whose content carries file context: the text exactly as written, then
    /// each file in order. Nil where the service has no content route; the composer then offers
    /// no file context. A draft without files always uses `sendFollowUp`.
    var sendFollowUpWithContext: (@MainActor (_ workerID: String, _ text: String,
                                              _ context: [FollowUpContextItem]) async -> Bool)? = nil
    /// Prepares a chosen file for one worker's follow-up. The feature layer reads the file.
    var prepareFollowUpContext: (@MainActor (_ url: URL, _ kind: FollowUpContextKind,
                                             _ scope: FollowUpContextScope) -> Result<FollowUpContextItem, FollowUpContextError>)? = nil
    /// A worker's provider session: status, discovery and reattach. Nil where the service offers
    /// none, and no console offers the panel.
    var providerSession: ProviderSessionIntents? = nil
    /// A worker's structured requests from its agent: read, answer and open. Nil where the service
    /// offers none, and no console offers the panel.
    var elicitations: ElicitationIntents? = nil
    // Feature capabilities drawn in the concepts. Each control appears only when its action exists,
    // so the live app offers none of them until the service supports the operation.
    var messageCoordinator: (@MainActor (_ runID: String, _ text: String) -> Void)? = nil
    var searchWorkspace: (@MainActor () -> Void)? = nil
    var chooseWallGrouping: (@MainActor () -> Void)? = nil
    /// Worker-level operations from the tile's action list. Nil until the service exposes each one.
    var takeControl: (@MainActor (_ workerID: String) -> Void)? = nil
    var interruptWorker: (@MainActor (_ workerID: String) -> Void)? = nil
    var stopWorker: (@MainActor (_ workerID: String) -> Void)? = nil
    /// Takes back a follow-up that is still queued, by its exact message ID.
    var cancelFollowUp: (@MainActor (_ workerID: String, _ messageID: String) -> Void)? = nil
    /// Whether each operation applies to a given worker right now. Nil means it applies wherever
    /// the action exists, which is what the design fixtures use.
    var canControlWorker: (@MainActor (_ workerID: String) -> Bool)? = nil
    var canInterruptWorker: (@MainActor (_ workerID: String) -> Bool)? = nil
    var canStopWorker: (@MainActor (_ workerID: String) -> Bool)? = nil
    /// True while a control, interrupt or stop request for the worker is still in flight.
    var workerIsBusy: (@MainActor (_ workerID: String) -> Bool)? = nil
    /// Reads a worker's provider source. Nil where no source can be read, and then no console
    /// offers the inspector.
    var source: ConsoleSourceIntents? = nil
    /// Every field behind one transcript entry of one worker, from the state the app holds. Nil
    /// where no service record backs the transcript, and an entry then shows the fields it holds.
    var recordDetail: (@MainActor (_ workerID: String, _ entryID: String) -> ConsoleRecordDetail?)? = nil
    /// Reads the images and audio one prompt carried, by its worker and turn. Nil where no
    /// service backs the transcript, and a user entry then offers no attachments action.
    var promptAttachments: PromptAttachmentIntents? = nil

    /// True when a worker's action list carries more than zoom, reply and copy.
    var offersWorkerOperations: Bool { takeControl != nil || interruptWorker != nil || stopWorker != nil }
}

/// How pending decisions are presented. The live cockpit defaults to the side panel and offers
/// the PiP stack as the alternative; the other modes are presentation preferences in the plan.
enum AttentionPresentation: String, CaseIterable, Identifiable {
    case pip, queue, drawer, switchRun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pip: "Picture-in-picture"
        case .queue: "Global queue"
        case .drawer: "Side panel"
        case .switchRun: "Switch to run"
        }
    }

    var detail: String {
        switch self {
        case .pip: "Float live prompts in a window that stays above other apps."
        case .queue: "Collect requests from every run in one list."
        case .drawer: "Open pending decisions beside the current run."
        case .switchRun: "Focus the run that owns the blocked worker."
        }
    }
}

/// Where the developer was before following a request into another run.
struct ReturnTarget: Equatable {
    let runID: String
    let runTitle: String
    let workerID: String?
    let workerName: String?
    /// The request that caused the switch, e.g. "Field ownership · Q-021".
    let requestLabel: String

    var title: String { workerName.map { "\(runTitle) / \($0)" } ?? runTitle }
}

// MARK: - Formatting helpers

enum Identifier {
    /// Compact form for display. The full value stays available to accessibility and copy actions.
    static func short(_ id: String) -> String {
        id.count > 10 ? String(id.prefix(8)) : id
    }

    /// Compact form for a locally assigned turn ID. `initial-<worker>` keeps its worker suffix
    /// ("initial · w-abc123"); other turns use `short`.
    static func turn(_ id: String) -> String {
        let prefix = "initial-"
        guard id.hasPrefix(prefix), id.count > prefix.count else { return short(id) }
        return "initial · \(short(String(id.dropFirst(prefix.count))))"
    }
}

enum Timestamp {
    /// Local wall-clock time from an RFC 3339 value. Returns nil when the value is absent or unreadable.
    static func clock(_ value: String?, seconds: Bool = false) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let plain = try? Date(value, strategy: .iso8601)
        let fractional = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        guard let date = plain ?? fractional else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0, second = parts.second ?? 0
        return seconds ? String(format: "%02d:%02d:%02d", hour, minute, second)
                       : String(format: "%02d:%02d", hour, minute)
    }
}

enum PathDisplay {
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - TerminalWell (atom, AppKit leaf)

/// One opaque, selectable terminal projection. Every surface that shows a worker's output (wall tile,
/// focused worker, coordinator console, PiP context) uses this view; density is its font size and
/// inset. It is passive: it never resizes the pane and accepts no terminal input.
///
/// Coloring is lexical and works on plain captured text, which stays the supported pipeline:
///   `14:14:03 CODEX`        speaker line, drawn as `● codex` in cyan with a dim time
///   `$ command`             cyan
///   `✓` / `✗` / `? `        green / red / amber result lines
///   `▸ name …` / `▾ name …` tool row: violet tool name, a `$ command` in cyan, and a trailing
///                           `✓ done`, `… running` or `✗ failed`
///   `│ …`                   detail of the tool row above, behind a dim rule
///   `` `code` ``            inline code in cyan, without the backticks
/// Tool rows here are styled text and do not open or close. A worker with structured messages is
/// shown by TranscriptView instead, where tool calls are real disclosure rows.
struct TerminalWell: NSViewRepresentable {
    /// `tail` is the dense wall projection. `transcript` is the expanded reading view with a little
    /// more line height. Both render the same text with the same grammar.
    enum Style { case tail, transcript }

    let output: String
    let workerID: String
    var style: Style = .tail
    var workerName: String = ""
    var fontSize: CGFloat = TypeRole.wallTerminalSize
    var inset: NSSize = NSSize(width: 11, height: 12)
    /// Reports the laid-out height of the content, so a surface can place something directly after
    /// a short transcript. The well itself still scrolls when it is given less room than this.
    var onContentHeight: ((CGFloat) -> Void)? = nil

    @MainActor final class Coordinator: NSObject {
        var identity = ""
        var previous = ""
        var fontSize: CGFloat = 0
        var onContentHeight: ((CGFloat) -> Void)?
        weak var textView: NSTextView?
        private var reported: CGFloat = -1

        @objc func frameChanged(_ notification: Notification) { measure() }

        func measure() {
            guard onContentHeight != nil, let text = textView,
                  let container = text.textContainer, let manager = text.layoutManager else { return }
            manager.ensureLayout(for: container)
            let height = (manager.usedRect(for: container).height + text.textContainerInset.height * 2).rounded(.up)
            guard abs(height - reported) > 0.5 else { return }
            reported = height
            // Deliver after the current view update so SwiftUI state is not changed mid-layout.
            Task { @MainActor [weak self] in self?.onContentHeight?(height) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.textContainerInset = inset
        text.textContainer?.lineFragmentPadding = 0
        text.postsFrameChangedNotifications = true
        context.coordinator.textView = text
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        text.setAccessibilityLabel(workerName.isEmpty ? "Console output" : "Console output, \(workerName)")
        let cache = context.coordinator
        cache.onContentHeight = onContentHeight
        let changedPane = cache.identity != workerID
        guard changedPane || cache.previous != output || cache.fontSize != fontSize else { return }
        defer { cache.measure() }
        let following = changedPane || scroll.documentVisibleRect.maxY >= text.bounds.height - 6
        let savedOrigin = scroll.contentView.bounds.origin
        let oldSelection = text.selectedRange()
        text.textStorage?.setAttributedString(Self.styled(output, fontSize: fontSize, style: style))
        if !changedPane, NSMaxRange(oldSelection) <= text.string.utf16.count {
            text.setSelectedRange(oldSelection)
        }
        if following {
            text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0))
        } else {
            scroll.contentView.scroll(to: savedOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        cache.previous = output
        cache.identity = workerID
        cache.fontSize = fontSize
    }

    private static func styled(_ output: String, fontSize: CGFloat, style: Style) -> NSAttributedString {
        let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = (fontSize * (style == .transcript ? 1.56 : 1.5)).rounded()
        paragraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString()
        func run(_ text: String, _ hex: UInt32, bold isBold: Bool = false) {
            guard !text.isEmpty else { return }
            result.append(NSAttributedString(string: text, attributes: [
                .font: isBold ? bold : regular, .foregroundColor: NSColor(hex: hex), .paragraphStyle: paragraph
            ]))
        }

        /// Plain text with `inline code` drawn in cyan.
        func prose(_ text: String, _ hex: UInt32) {
            let parts = text.components(separatedBy: "`")
            guard parts.count >= 3, parts.count % 2 == 1 else { run(text, hex); return }
            for (index, part) in parts.enumerated() { run(part, index % 2 == 1 ? Term.Hex.cyan : hex) }
        }

        /// A result or command line, by its first mark.
        func body(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$ ") { run(text, Term.Hex.cyan) }
            else if trimmed.hasPrefix("✓") || trimmed.hasPrefix("✔") { run(text, Term.Hex.green) }
            else if trimmed.hasPrefix("✗") || trimmed.hasPrefix("✘") { run(text, Term.Hex.red) }
            else if trimmed.hasPrefix("? ") { run(text, Term.Hex.amber) }
            else { prose(text, Term.Hex.text) }
        }

        var afterToolRow = false
        let lines = output.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))

            if let turn = turnLabel(trimmed) {
                let isDeveloper = turn.speaker == "YOU"
                run(isDeveloper ? "❯ " : "● ", isDeveloper ? Term.Hex.dim : Term.Hex.cyan)
                run(turn.speaker.lowercased(), isDeveloper ? Term.Hex.text : Term.Hex.cyan, bold: true)
                run("  " + turn.time, Term.Hex.dim)
                afterToolRow = false
            } else if trimmed.hasPrefix("▸ ") || trimmed.hasPrefix("▾ ") {
                toolRow(trimmed, indent: indent, run: run)
                afterToolRow = true
            } else if trimmed.hasPrefix("│") {
                run(indent + "│", Term.Hex.dim)
                body(String(trimmed.dropFirst()))
            } else if afterToolRow, indent.count >= 2, !trimmed.isEmpty {
                // An indented line directly under a tool row is that row's detail.
                run(line, Term.Hex.dim)
            } else {
                body(line)
                afterToolRow = false
            }
            if index < lines.count - 1 { run("\n", Term.Hex.text) }
        }
        return result
    }

    /// `▸ name rest   ✓ done`: dim disclosure mark, violet tool name, the rest, then the state.
    private static func toolRow(_ trimmed: String, indent: String,
                                run: (_ text: String, _ hex: UInt32, _ bold: Bool) -> Void) {
        run(indent + String(trimmed.prefix(2)), Term.Hex.dim, false)
        var rest = String(trimmed.dropFirst(2))
        var state: (text: String, hex: UInt32)?
        for (mark, hex) in [("✓", Term.Hex.green), ("…", Term.Hex.amber), ("✗", Term.Hex.red)] {
            if let range = rest.range(of: "  \(mark) ", options: .backwards) {
                state = (String(rest[range.lowerBound...]), hex)
                rest = String(rest[..<range.lowerBound])
                break
            }
        }
        let name = String(rest.prefix(while: { $0 != " " }))
        let detail = String(rest.dropFirst(name.count))
        run(name, Term.Hex.violet, true)
        let parts = detail.components(separatedBy: "`")
        if detail.trimmingCharacters(in: .whitespaces).hasPrefix("$ ") {
            run(detail, Term.Hex.cyan, false)
        } else if parts.count >= 3, parts.count % 2 == 1 {
            // A path or name written as `inline code`.
            for (index, part) in parts.enumerated() { run(part, index % 2 == 1 ? Term.Hex.cyan : Term.Hex.text, false) }
        } else {
            run(detail, Term.Hex.text, false)
        }
        if let state { run(state.text, state.hex, false) }
    }

    /// A line of the form "14:14:03 CODEX" is a turn label: a time and an upper-case speaker.
    private static func turnLabel(_ line: String) -> (time: String, speaker: String)? {
        let characters = Array(line)
        guard characters.count > 9, characters[2] == ":", characters[5] == ":", characters[8] == " " else { return nil }
        let time = String(characters[0..<8])
        let speaker = String(characters[9...])
        guard time.allSatisfy({ $0.isNumber || $0 == ":" }),
              speaker == speaker.uppercased(), speaker.contains(where: \.isLetter) else { return nil }
        return (time, speaker)
    }
}

// MARK: - Mapping from the service model (feature layer)

extension HostPlatform {
    /// The marker the local service writes on every worker its local provider launches
    /// (`newWorker` in internal/service/store.go). It is a contract value, compared exactly.
    static let serviceLocalMarker = "localhost"

    /// Platform of a live worker. The service reaches this app over its local socket and marks
    /// workers it launched on this machine with `serviceLocalMarker`; this app runs on macOS, so
    /// that exact marker means this Mac. The API carries no platform field for any other host, so
    /// every other value is `.unknown`. No name matching, DNS lookup or transport check is done.
    init(serviceHost: String) {
        self = serviceHost == Self.serviceLocalMarker ? .localMac : .unknown
    }
}

extension TranscriptEntry {
    /// How many recent entries a request surface (the PiP) shows as context.
    static let recentWindow = 4

    /// Builds transcript entries from AG-UI messages. Each tool call is paired with the `tool`
    /// message that answers it by tool-call ID. When several answer one call, the row shows the
    /// last and the call's fields list every one. `user` and `assistant` text is prose. Text from any
    /// other role keeps its role, and a message with no text and no tool call still has an entry,
    /// so its fields stay reachable.
    static func entries(from messages: [AGUIMessage]) -> [TranscriptEntry] {
        var results: [String: ToolResult] = [:]
        var callIDs = Set<String>()
        for message in messages {
            if message.role == "tool", let callID = message.toolCallID {
                results[callID] = ToolResult(output: message.content ?? "", error: message.error)
            }
            for call in message.toolCalls ?? [] { callIDs.insert(call.id) }
        }
        var entries: [TranscriptEntry] = []
        // The live-chunk key of the message before this one, so a chunk knows whether it
        // continues a reply. Any other message, a tool result included, ends the reply.
        var previousChunk: ConversationChunks.Key?
        for message in messages {
            let chunk = ConversationChunks.key(of: message)
            defer { previousChunk = chunk }
            if message.role == "tool" {
                // A result with a known call is shown inside that call's entry.
                if let callID = message.toolCallID, callIDs.contains(callID) { continue }
                // A result without its call stays readable, including a failure with no output.
                // Each one is its own entry under its message ID, so several for one missing
                // call all stay, in the order they arrived.
                let result = ToolResult(output: message.content ?? "", error: message.error)
                let origin = TranscriptOrigin(message: message, key: nil, previous: nil)
                // With nothing to read it is still a record: its metadata and every other field
                // are reached from the entry, which says that it has no text.
                entries.append(TranscriptEntry(
                    id: message.id, kind: result.hasText ? .output(result) : .other(role: message.role, text: ""),
                    origin: origin, toolCallID: message.toolCallID))
                continue
            }
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let calls = message.toolCalls ?? []
            let origin = TranscriptOrigin(message: message, key: chunk, previous: previousChunk)
            if message.role == "user" || message.role == "assistant" || message.role.isEmpty {
                if !text.isEmpty {
                    entries.append(TranscriptEntry(id: message.id, kind: .prose(text, fromUser: message.role == "user"), origin: origin))
                } else if calls.isEmpty {
                    entries.append(TranscriptEntry(id: message.id, kind: .other(role: message.role, text: ""), origin: origin))
                }
            } else if !text.isEmpty || calls.isEmpty {
                entries.append(TranscriptEntry(id: message.id, kind: .other(role: message.role, text: text), origin: origin))
            }
            for call in message.toolCalls ?? [] {
                entries.append(TranscriptEntry(
                    id: call.id,
                    kind: .tool(name: call.function.name, detail: detail(of: call.function.arguments),
                                result: results[call.id]),
                    commander: CommanderCallFacts(arguments: call.function.arguments)))
            }
        }
        return entries
    }

    /// The `detail` string of a tool call's JSON arguments, when the object carries one.
    private static func detail(of arguments: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let detail = object["detail"] as? String, !detail.isEmpty else { return nil }
        return detail
    }
}

extension RunSummary {
    init(run: Run) {
        self.init(id: run.id, project: run.project, path: run.path, title: run.title,
                  status: TaskState(api: run.status))
    }
}

extension RunContent {
    init(run: Run) {
        let workers = run.workers ?? []
        let byID = Dictionary(workers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = (run.requests ?? []).filter { $0.status == "pending" }
        // Every pending request per worker, in the service's stable order. The first is the one the
        // worker's inline form answers; all of them are projected by ID into Attention.
        let requestsByWorker = Dictionary(grouping: pending, by: \.workerID)
        // Answers the service accepted and could not confirm as delivered: the latest one per worker.
        let unconfirmed = (run.requests ?? []).filter { $0.status != "pending" && $0.deliveryIsUnknown }
        let unconfirmedByWorker = Dictionary(unconfirmed.map { ($0.workerID, $0) }, uniquingKeysWith: { _, last in last })
        let runClient = run.client
        let runTitle = run.title
        let coordinatorID = run.coordinatorID
        let live = CommanderLiveState(run: run)

        func parents(of worker: Worker) -> [String] {
            var names: [String] = []
            var seen: Set<String> = [worker.id]
            var current = worker
            while let parent = byID[current.parentID], parent.id != coordinatorID, seen.insert(parent.id).inserted {
                names.insert(parent.name, at: 0)
                current = parent
            }
            return names
        }

        // Each worker's entries are built once: for its own console, and for the background
        // line of the console that delegated it.
        var transcripts: [String: [TranscriptEntry]] = [:]
        func transcript(of worker: Worker) -> [TranscriptEntry] {
            if let built = transcripts[worker.id] { return built }
            let built = CommanderActivity.annotate(TranscriptEntry.entries(from: worker.messages ?? []), live: live)
            transcripts[worker.id] = built
            return built
        }
        let records = BackgroundJobs.Records(workers: byID, requests: run.requests ?? [], integrations: live.integrations,
                                             transcript: { transcript(of: $0) })

        func present(_ worker: Worker) -> WorkerPresentation {
            let isCoordinator = worker.id == coordinatorID
            let ancestors = parents(of: worker)
            let holder = ancestors.last ?? runTitle
            let client = AgentClient(worker.client, fallback: runClient)
            let branch = worker.branch?.trimmingCharacters(in: .whitespaces) ?? ""
            let platform = HostPlatform(serviceHost: worker.host)
            // Commander calls carry the current state of their request, follow-up or integration
            // from this run, by exact ID, so Pretty never shows a pending request as done or a
            // finished follow-up as queued. No polling: the workspace projection holds it all.
            let transcript = transcript(of: worker)
            let background = BackgroundJobs.jobs(entries: transcript, records: records)
            let questions = requestsByWorker[worker.id] ?? []
            let state = TaskState(api: worker.state, hasPendingRequest: !questions.isEmpty)
            // The service's own explanation, or a plain statement when it sent none.
            let explanation = worker.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let disconnectReason: String? = state == .disconnected
                ? (explanation.isEmpty ? "The connection to \(worker.host) was lost." : explanation) : nil
            // A persistent link that is reconnecting. A disconnected worker is reported as that alone.
            let reconnecting = state != .disconnected
                && worker.connection?.lowercased() == Worker.connectionReconnecting
            let telemetry = worker.boundSession.map { _ in
                ProviderTelemetry.reported(fields: worker.allFields, messages: worker.messages ?? [])
            }
            let requests = questions.map { question in
                // From the full transcript: the PiP's window could hide a competing open call.
                let awaitingToolID = PrettyRunStatus(state: state, entries: transcript)
                    .awaitingToolID(choiceRequestPending: !(question.choices ?? []).isEmpty)
                return RequestPresentation(
                    id: question.id, shortID: Identifier.short(question.id), question: question.question,
                    workerID: worker.id, workerName: worker.name, workerIsCoordinator: isCoordinator,
                    client: client, runID: run.id, runTitle: runTitle, project: run.project, host: worker.host,
                    platform: platform, inputHolder: isCoordinator ? worker.name : holder,
                    contextTail: Self.tail(of: worker.output),
                    contextEntries: TranscriptEntry.recent(transcript),
                    turnEntries: TranscriptEntry.currentTurn(transcript),
                    disconnectReason: disconnectReason,
                    hostIsReconnecting: reconnecting,
                    workerBackgroundJobs: background,
                    workerTurnIsRunning: TaskState(api: worker.state).isActiveTurn,
                    workerSession: worker.boundSession,
                    choices: question.choices ?? [],
                    workerTelemetry: telemetry,
                    awaitingApprovalToolID: awaitingToolID,
                    // Also from the full transcript: the window could cut off the request's Ask.
                    requestWorkflow: CommanderActivity.workflow(request: question.id, in: transcript,
                                                                awaitingToolID: awaitingToolID))
            }
            let request = requests.first
            let claudeProgress = ClaudeProgressTrack.eligible(worker, isCoordinator: isCoordinator)
            return WorkerPresentation(
                id: worker.id, shortID: Identifier.short(worker.id), name: worker.name, client: client,
                host: worker.host, platform: platform,
                location: branch.isEmpty ? URL(filePath: worker.worktree).lastPathComponent : branch,
                locationIsBranch: !branch.isEmpty,
                task: worker.task, output: worker.output, error: worker.error,
                state: state,
                isCoordinator: isCoordinator,
                lineage: isCoordinator ? [runTitle] : [runTitle] + ancestors + [worker.name],
                // The service's control record is the authority on who directs a worker. The
                // coordinator is never taken over.
                control: !isCoordinator && worker.control?.held == true
                    ? .held : .observing(holder: isCoordinator ? worker.name : holder),
                request: request,
                startedAt: Timestamp.clock(worker.createdAt, seconds: true),
                transcript: transcript,
                queuedFollowUps: (worker.control?.messages ?? []).filter { $0.status == "queued" }.count,
                queuedMessages: isCoordinator ? [] : QueuedFollowUp.queued(worker.control),
                // Only a managed local Claude worker, the same scope as its progress track.
                followUpReceipts: claudeProgress == nil ? nil
                    : FollowUpReceipts(control: worker.control, workerID: worker.id, workerName: worker.name,
                                       requests: requests),
                interruptRequested: worker.control?.interruptRequested == true,
                interruptReceipt: isCoordinator ? nil : worker.control.flatMap { control in
                    control.interrupt.map {
                        InterruptReceiptStatement(receipt: $0, workerName: worker.name,
                                                  activeTurnID: control.activeTurnID)
                    }
                },
                unconfirmedReply: unconfirmedByWorker[worker.id].map { Identifier.short($0.id) },
                hostIsReconnecting: reconnecting,
                session: worker.boundSession,
                telemetry: telemetry,
                claudeProgress: claudeProgress,
                providerAvailability: isCoordinator ? nil : ProviderAvailability(worker: worker),
                pendingRequests: requests,
                checkout: worker.worktree,
                promptCapabilities: isCoordinator ? nil : worker.control?.promptCapabilities,
                backgroundJobs: background,
                turnIsRunning: TaskState(api: worker.state).isActiveTurn)
        }

        // Wall: root workers without children fill the top rows; a root with nested workers becomes a group.
        let delegates = run.delegates
        let delegateIDs = Set(delegates.map(\.id))
        let children = Dictionary(grouping: delegates, by: \.parentID)
        var layout = WallLayout()
        var visited = Set<String>()
        func descendants(of worker: Worker) -> [Worker] {
            var found: [Worker] = []
            for child in children[worker.id] ?? [] where visited.insert(child.id).inserted {
                found.append(child)
                found += descendants(of: child)
            }
            return found
        }
        for root in delegates where !delegateIDs.contains(root.parentID) {
            guard visited.insert(root.id).inserted else { continue }
            let nested = descendants(of: root)
            if nested.isEmpty {
                layout.leaves.append(present(root))
            } else {
                layout.groups.append(WorkerGroup(parent: present(root), members: nested.map(present)))
            }
        }
        // A parent cycle would leave workers unvisited; show them as leaves so nothing disappears.
        for worker in delegates where visited.insert(worker.id).inserted {
            layout.leaves.append(present(worker))
        }

        let coordinator = run.coordinator.map(present)
        let everyone = (coordinator.map { [$0] } ?? []) + layout.workers
        self.init(
            id: run.id, shortID: Identifier.short(run.id), project: run.project, path: run.path,
            title: runTitle, task: run.task, client: AgentClient(runClient),
            branch: run.branch.flatMap { $0.isEmpty ? nil : $0 },
            startedAt: Timestamp.clock(run.createdAt),
            status: TaskState(api: run.status), canStop: run.canStop,
            coordinator: coordinator, wall: layout,
            awaiting: everyone.flatMap(\.allRequests))
    }

    /// Last two non-empty lines of terminal output, used as context beside a pending question.
    static func tail(of output: String) -> [String] {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(2).map { $0.count > 90 ? String($0.prefix(90)) + "…" : $0 }
    }
}

extension CockpitContent {
    @MainActor init(model: CockpitModel) {
        let contents = model.runs.map(RunContent.init(run:))
        self.init(connection: model.connection, notice: model.notice, isStopping: model.isStopping,
                  runs: model.runs.map(RunSummary.init(run:)),
                  selected: contents.first { $0.id == model.selectedID },
                  pending: contents.flatMap(\.awaiting),
                  sending: model.sending,
                  sourceInspection: model.source.inspection)
    }
}
