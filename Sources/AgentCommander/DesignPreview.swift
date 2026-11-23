import AppKit
import SwiftUI

// ATOMIC LEVEL: Pages (design fixtures).
// Each scenario fills the production CockpitScreen with sample values that match one original
// concept frame, for 1:1 comparison. Nothing here is reachable in a normal launch and nothing
// contacts the service. Launch with either form:
//
//   AGENT_COMMANDER_DESIGN_PREVIEW=<state> AgentCommander
//   AgentCommander --design-preview <state>
//
//   <state>: coordinator-wall | focused-worker | attention-pip | pip-arrival | start-run
//
// Preview mode asks for a 1600 x 1000 window frame placed 62 pt below the top of the screen, as in
// the concept captures. Production windows get no special sizing.

enum DesignPreviewScenario: String, CaseIterable {
    case coordinatorWall = "coordinator-wall"
    case focusedWorker = "focused-worker"
    case attentionPip = "attention-pip"
    case pipArrival = "pip-arrival"
    case startRun = "start-run"

    static let requested: DesignPreviewScenario? = {
        let process = ProcessInfo.processInfo
        var value = process.environment["AGENT_COMMANDER_DESIGN_PREVIEW"]
        let arguments = process.arguments
        if let index = arguments.firstIndex(of: "--design-preview"), index + 1 < arguments.count {
            value = arguments[index + 1]
        }
        if let inline = arguments.first(where: { $0.hasPrefix("--design-preview=") }) {
            value = String(inline.dropFirst("--design-preview=".count))
        }
        return value.flatMap { DesignPreviewScenario(rawValue: $0) }
    }()
}

struct DesignPreviewPage: View {
    let scenario: DesignPreviewScenario
    @State private var ui: CockpitPresentationState

    init(scenario: DesignPreviewScenario) {
        self.scenario = scenario
        _ui = State(initialValue: DesignFixture.state(for: scenario))
    }

    var body: some View {
        CockpitScreen(content: DesignFixture.content(for: scenario), ui: ui,
                      actions: DesignFixture.actions, fixtureNavigation: DesignFixture.navigation,
                      runSetup: DesignFixture.referenceRunSetup)
            .background(PreviewWindowFrame())
    }
}

/// Requests the concept's outer window frame for preview captures.
private struct PreviewWindowFrame: NSViewRepresentable {
    final class Probe: NSView {
        private var applied = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !applied else { return }
            applied = true
            applyFrame()
            // SwiftUI may apply its own default size after the view attaches; ask once more.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.applyFrame()
            }
        }

        private func applyFrame() {
            guard let window else { return }
            let size = NSSize(width: 1600, height: 1000)
            let screen = window.screen?.frame ?? NSScreen.main?.frame ?? NSRect(origin: .zero, size: size)
            let origin = NSPoint(x: (screen.midX - size.width / 2).rounded(),
                                 y: (screen.maxY - 62 - size.height).rounded())
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

@MainActor
enum DesignFixture {
    // MARK: Presentation state per scenario

    static func state(for scenario: DesignPreviewScenario) -> CockpitPresentationState {
        let ui = CockpitPresentationState()
        switch scenario {
        case .coordinatorWall:
            ui.dismissedRequests = ["Q-018", "Q-021"]
        case .focusedWorker:
            ui.zoomedWorkerID = "W-047"
            ui.dismissedRequests = ["Q-021"]
        case .attentionPip:
            ui.activeRequestID = "Q-021"
            ui.drafts["Q-021"] = "Server owns emitted field names."
            ui.initialReplyFocus = "Q-021"
        case .pipArrival:
            ui.activeRequestID = "Q-021"
            ui.initialPaneFocus = "W-043"
        case .startRun:
            ui.sidebarExpanded = true
            ui.composingRun = true
            ui.newRunDraft = NewRunDraft(
                title: "Retry policy",
                path: NSHomeDirectory() + "/Developer/relay",
                task: "Plan and implement a retry policy for upstream requests. Keep non-idempotent calls safe.")
        }
        return ui
    }

    // MARK: Content

    static func content(for scenario: DesignPreviewScenario) -> CockpitContent {
        let backoffControl: InputControl = scenario == .pipArrival ? .held : .observing(holder: "Retry policy")
        // The focused-worker concept shows the developer holding Timeout cases' terminal.
        let timeoutControl: InputControl = scenario == .focusedWorker ? .held : .observing(holder: "Failure paths")
        let wall = WallLayout(
            leaves: [
                worker(id: "W-043", name: "Backoff strategy", client: .codex, host: "Mac Studio", branch: "feat/backoff",
                       state: .working, started: "14:16:34", control: backoffControl, output: backoffOutput),
                worker(id: "W-044", name: "Retry telemetry", client: .codex, host: "build-01", branch: "feat/telemetry",
                       state: .working, started: "14:16:32", output: telemetryOutput),
                worker(id: "W-045", name: "API compatibility", client: .mcp, host: "Mac Studio", branch: "main",
                       state: .idle, started: "14:16:19", output: compatibilityOutput)
            ],
            groups: [
                WorkerGroup(
                    parent: worker(id: "W-046", name: "Failure paths", client: .claude, host: "build-01", branch: "main",
                                   state: .working, started: "14:16:28", output: failurePathsOutput),
                    members: [
                        worker(id: "W-047", name: "Timeout cases", client: .codex, host: "build-01", branch: "main",
                               state: .needsInput, started: "14:12:41", parents: ["Failure paths"],
                               control: timeoutControl, request: timeoutRequest,
                               task: "Cover timeout behavior before headers, after headers, and after the first body chunk.\nReport any ambiguous cases.",
                               // The wall and PiP frames show the compact tail with the pending
                               // question; the focused frame shows the expanded turn.
                               output: scenario == .focusedWorker ? timeoutTranscript : timeoutTail)
                    ])
            ])
        let coordinator = WorkerPresentation(
            id: "W-042", shortID: "W-042", name: "Claude Code", client: .claude, host: "Mac Studio",
            location: "main", locationIsBranch: true, task: assignment, output: coordinatorOutput, error: nil,
            state: .working, isCoordinator: true, lineage: ["Retry policy"],
            control: .observing(holder: "Claude Code"), request: nil, startedAt: "14:08:02")
        let run = RunContent(
            id: "R-042", shortID: "R-042", project: "Relay", path: NSHomeDirectory() + "/Developer/relay",
            title: "Retry policy", task: assignment, client: .claude, branch: "main", startedAt: "14:08",
            status: .running, canStop: true, coordinator: coordinator, wall: wall, awaiting: [timeoutRequest])
        return CockpitContent(
            connection: .online, notice: nil, isStopping: false,
            runs: [
                RunSummary(id: "R-042", project: "Relay", path: NSHomeDirectory() + "/Developer/relay",
                           title: "Retry policy", status: .running),
                RunSummary(id: "R-039", project: "Beacon", path: NSHomeDirectory() + "/Developer/beacon",
                           title: "Event schema", status: .running)
            ],
            selected: run,
            pending: [fieldOwnershipRequest, timeoutRequest],
            sending: [])
    }

    /// Fixture intents change nothing. Hand back is present so the held-input arrangement can be compared.
    static let actions = CockpitActions(
        selectRun: { _ in },
        reply: { _, _ in false },
        stopRun: { _ in },
        reconnect: {},
        dismissNotice: {},
        createRun: { _, _, _, _ in },
        handBack: { _ in },
        sendTerminalInput: { _, _ in },
        messageCoordinator: { _, _ in },
        searchWorkspace: {},
        chooseWallGrouping: {})

    /// Destinations drawn in the concepts that the product does not implement yet.
    static let navigation = FixtureNavigation(
        workspace: [
            NavigationItem(id: "fixture-history", title: "History", mark: .symbol("clock.arrow.circlepath"), action: {}),
            NavigationItem(id: "fixture-integrations", title: "Integrations", mark: .symbol("arrow.triangle.merge"), action: {})
        ],
        smartViews: [
            NavigationItem(id: "fixture-remote", title: "Remote workers", mark: .symbol("line.3.horizontal.decrease"), action: {})
        ],
        footer: [
            NavigationItem(id: "fixture-hosts", title: "Hosts", mark: .symbol("server.rack"), action: {}),
            NavigationItem(id: "fixture-clients", title: "Clients & MCP", mark: .symbol("terminal"), action: {}),
            NavigationItem(id: "fixture-settings", title: "Settings", mark: .symbol("gearshape"), action: {})
        ])

    // MARK: Sample values

    private static func worker(id: String, name: String, client: AgentClient, host: String, branch: String,
                               state: TaskState, started: String, parents: [String] = [],
                               control: InputControl? = nil, request: RequestPresentation? = nil,
                               task: String = "", output: String) -> WorkerPresentation {
        let holder = parents.last ?? "Retry policy"
        return WorkerPresentation(
            id: id, shortID: id, name: name, client: client, host: host,
            location: branch, locationIsBranch: true, task: task, output: output, error: nil,
            state: state, isCoordinator: false, lineage: ["Retry policy"] + parents + [name],
            control: control ?? .observing(holder: holder), request: request, startedAt: started)
    }

    private static let assignment =
        "Plan and implement a retry policy for upstream requests. Keep non-idempotent calls safe."

    private static let timeoutRequest = RequestPresentation(
        id: "Q-018", shortID: "Q-018",
        question: "Should the client retry after response body bytes have already been delivered?",
        workerID: "W-047", workerName: "Timeout cases", workerIsCoordinator: false, client: .codex,
        runID: "R-042", runTitle: "Retry policy", project: "Relay", host: "build-01",
        inputHolder: "Failure paths",
        contextTail: ["$ pnpm test timeout", "✓ connection can retry"])

    private static let fieldOwnershipRequest = RequestPresentation(
        id: "Q-021", shortID: "Q-021",
        question: "Should the server or client own the emitted field names?",
        workerID: "W-052", workerName: "Field ownership", workerIsCoordinator: false, client: .claude,
        runID: "R-039", runTitle: "Event schema", project: "Beacon", host: "Mac Studio",
        inputHolder: "Event schema",
        contextTail: ["$ rg 'source_name' packages/events", "emit.ts:42 · source_name"])

    private static let coordinatorOutput = """
    14:08:07 CLAUDE CODE
    I’ll map the failure paths first, then split the
    backoff and telemetry changes into separate worktrees.

    ↳ Delegated Backoff strategy
      Codex · Mac Studio
    ↳ Delegated Failure paths
      Claude Code · build-01
    ↳ Delegated Retry telemetry
      Codex · build-01
    ↳ Delegated API compatibility
      MCP client · Mac Studio

    14:16:28 CLAUDE CODE
    The retry budget is scoped per request. The remaining
    decision is whether a partially consumed response can
    be retried.
    """

    private static let backoffOutput = """
    $ git diff --stat
     retry/backoff.ts  | 42 ++++++
     retry/budget.ts   | 18 +++
     2 files changed

    $ pnpm test backoff
    ✓ jitter stays within cap
    ✓ budget resets per request
    """

    private static let telemetryOutput = """
    $ rg 'retry.count' src/
    src/metrics/requests.ts:41

    Editing metrics/requests.ts
    + retry_attempt_total
    + retry_exhausted_total

    Updating metric assertions…
    """

    private static let compatibilityOutput = """
    Reading public exports…

    Checked RequestOptions and
    the HTTP client constructor.

    ✓ Defaults remain compatible
    Review result sent to coordinator.
    """

    private static let failurePathsOutput = """
    Mapped retry eligibility across
    connect, headers and body reads.

    ↳ Delegated Timeout cases
      Validate partial-body behavior.
    """

    /// Terminal tail from the wall and PiP concepts.
    private static let timeoutTail = """
    $ pnpm test timeout
    ✓ connection can retry

    ? Should the client retry after response body bytes have
    already been delivered?
    """

    /// Expanded turn from the focused-worker concept.
    private static let timeoutTranscript = """
    14:14:03 CODEX
    Pre-header retry is covered. I’m checking the streaming path against the public client contract.

    $ pnpm test timeout --reporter=spec
    ✓ connect timeout retries inside the request budget
    ✓ exhausted retries return the upstream timeout
    ? partial response body • policy decision required
    """

    /// Capabilities drawn in the start-run concept that the local service does not offer yet.
    static let referenceRunSetup = RunSetupCapabilities(
        localHostName: "Mac Studio",
        coordinatorModel: "Sonnet",
        allowedClients: ["Claude Code", "Codex", "Generic MCP client"],
        allowedModels: "Sonnet · Codex default",
        workerLimit: "10 across all levels",
        disconnectChoices: [
            .init(id: "finish", title: "Finish current assignments",
                  detail: "Hold new delegation until the host reconnects.", isSelected: true),
            .init(id: "continue", title: "Continue where supported",
                  detail: "Allow reachable helpers to delegate within this run’s limits.", isSelected: false)
        ],
        remoteHosts: [
            .init(id: "build-01", symbol: "server.rack", name: "build-01", detail: "SSH · persistent helper")
        ],
        previewRows: [
            .init(key: "Project / branch", value: "Relay · main"),
            .init(key: "Run ID", value: "R-042", monospaced: true),
            .init(key: "Root assignment", value: "A-042", monospaced: true),
            .init(key: "Allowed hosts", value: "Mac Studio · build-01")
        ],
        delegation: .init(title: "Commander MCP connected",
                          detail: "Claude Code can delegate workers into this run."),
        limitsNote: "Limits apply to every descendant, including workers launched by another worker.",
        footerNote: "Run policy applies from launch.",
        showsTaskEditor: false)
}
