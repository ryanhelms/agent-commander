import AppKit
import SwiftUI

// ATOMIC LEVEL: Pages (design previews).
// One preview window shows every concept state as a native page filled with sample values. The
// cockpit states go through the production CockpitScreen; the other states go through the same
// shell with their own page. Nothing here is reachable in a normal launch and nothing contacts the
// service. Launch with either form:
//
//   AGENT_COMMANDER_DESIGN_PREVIEW=<state> AgentCommander
//   AgentCommander --design-preview <state>
//
//   <state>: any slug in DesignPreviewScenario (coordinator-wall … accessible-worker), or "gallery"
//            to start at the first view.
//
// Inside the window, the title-bar gallery control (and ⌥⌘← / ⌥⌘→) browses all states, and the
// navigation rail moves between views. Interactions change in-memory sample state only; choosing a
// view from the gallery resets it. Optional environment switches for captures:
//
//   AGENT_COMMANDER_PREVIEW_STATIC=1        start with live sample activity off
//   AGENT_COMMANDER_PREVIEW_GALLERY=hidden  leave the gallery control out of the title bar
//   AGENT_COMMANDER_PREVIEW_DISCONNECT=<worker ID>        show that sample worker as disconnected,
//                                           with its pending request kept and its reply closed
//                                           (W-047 Timeout cases on build-01 carries Q-018)
//   AGENT_COMMANDER_PREVIEW_RECONNECT=<worker ID>         show that sample worker with its persistent
//                                           SSH link reconnecting: its own status is kept and its
//                                           reply stays open (W-047 carries Q-018; W-044 Retry
//                                           telemetry on build-01 is working with no request).
//                                           PREVIEW_DISCONNECT wins for the same worker
//   AGENT_COMMANDER_PREVIEW_DELIVERY_UNKNOWN=<worker ID>  show that sample worker with an accepted
//                                           answer whose delivery is unknown
//
// Preview mode asks for a 1600 x 1000 window frame placed 62 pt below the top of the screen, as in
// the concept captures. Production windows get no special sizing.

enum DesignPreviewScenario: String, CaseIterable, Identifiable {
    case coordinatorWall = "coordinator-wall"
    case focusedWorker = "focused-worker"
    case tileControls = "tile-controls"
    case attentionPip = "attention-pip"
    case pipArrival = "pip-arrival"
    case attentionQueue = "attention-queue"
    case attentionPanel = "attention-panel"
    case attentionSwitch = "attention-switch"
    case allAgents = "all-agents"
    case project = "project"
    case smartView = "smart-view"
    case linkCheckout = "link-checkout"
    case startRun = "start-run"
    case delegateWorker = "delegate-worker"
    case integration = "integration"
    case integrationBlocked = "integration-blocked"
    case history = "history"
    case crossRun = "cross-run"
    case firstRun = "first-run"
    case hosts = "hosts"
    case clients = "clients"
    case adoption = "adoption"
    case recovery = "recovery"
    case operationDetail = "operation-detail"
    case preferences = "preferences"
    case reducedTransparency = "reduced-transparency"
    case accessibleWall = "accessible-wall"
    case accessibleWorker = "accessible-worker"

    struct Info {
        let title: String
        let group: String
        let crumbs: [String]
        /// Title of the navigation row that is selected on this view.
        let active: String
        let summary: String
    }

    static let groups = ["Cockpit", "Workspace", "Delegation", "Setup & recovery"]

    var id: String { rawValue }
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    var menuTitle: String { String(format: "%02d  %@", number, info.title) }

    /// States drawn by the production CockpitScreen.
    var isCockpit: Bool {
        switch self {
        case .coordinatorWall, .focusedWorker, .tileControls, .attentionPip, .pipArrival, .attentionPanel,
             .attentionSwitch, .startRun, .accessibleWall, .accessibleWorker:
            true
        default:
            false
        }
    }

    /// States shown with the reduced-transparency and increased-contrast roles.
    var usesAccessibleAppearance: Bool {
        self == .reducedTransparency || self == .accessibleWall || self == .accessibleWorker
    }

    var info: Info {
        switch self {
        case .coordinatorWall:
            Info(title: "Coordinator wall", group: "Cockpit", crumbs: ["Relay", "Retry policy"], active: "Relay",
                 summary: "The resizable coordinator stays left while five workers stream on the right.")
        case .focusedWorker:
            Info(title: "Focused worker", group: "Cockpit", crumbs: ["Relay", "Retry policy", "Timeout cases"], active: "Relay",
                 summary: "Zoom fills only the worker area. The control marker and handback identify who can type.")
        case .tileControls:
            Info(title: "Worker actions", group: "Cockpit", crumbs: ["Relay", "Retry policy"], active: "Relay",
                 summary: "Inspect the assignment, send a follow-up, interrupt, or stop a specific worker from its tile.")
        case .attentionPip:
            Info(title: "Picture-in-picture reply", group: "Cockpit", crumbs: ["Relay", "Retry policy"], active: "Relay",
                 summary: "A question from Event schema appears over Retry policy. Answer inline or expand its terminal.")
        case .pipArrival:
            Info(title: "An incoming request", group: "Cockpit", crumbs: ["Relay", "Retry policy"], active: "Relay",
                 summary: "A PiP arrives while keyboard focus and terminal control stay on Backoff strategy.")
        case .attentionQueue:
            Info(title: "Attention queue", group: "Cockpit", crumbs: ["Workspace", "Attention"], active: "Attention",
                 summary: "Review pending decisions across runs, inspect the terminal context, and respond.")
        case .attentionPanel:
            Info(title: "Attention side panel", group: "Cockpit", crumbs: ["Relay", "Retry policy"], active: "Relay",
                 summary: "Keep the coordinator and wall in view while inspecting a decision in a drawer.")
        case .attentionSwitch:
            Info(title: "Switch to a blocked run", group: "Cockpit", crumbs: ["Relay", "Event schema"], active: "Relay",
                 summary: "Follow an interruption into another run and return to the worker you were viewing.")
        case .allAgents:
            Info(title: "All agents", group: "Workspace", crumbs: ["Workspace", "All agents"], active: "All agents",
                 summary: "Watch live consoles across projects. A disconnected terminal keeps its last output.")
        case .project:
            Info(title: "Project overview", group: "Workspace", crumbs: ["Projects", "Relay"], active: "Relay",
                 summary: "A directory's coordinators, nested workers, and linked checkouts across hosts.")
        case .smartView:
            Info(title: "Saved smart view", group: "Workspace", crumbs: ["Smart views", "Remote workers"], active: "Remote workers",
                 summary: "Filter remote agents across runs and inspect the rules that determine membership.")
        case .linkCheckout:
            Info(title: "Link a checkout", group: "Workspace", crumbs: ["Relay", "Linked checkouts"], active: "Relay",
                 summary: "Compare an ambiguous remote copy with the project before linking it.")
        case .startRun:
            Info(title: "Start a coordinator", group: "Delegation", crumbs: ["Relay", "New run"], active: "Relay",
                 summary: "Set the assignment, allowable resources, worker limit, and disconnect policy.")
        case .delegateWorker:
            Info(title: "Delegate a worker", group: "Delegation", crumbs: ["Relay", "Retry policy", "Delegate"], active: "Relay",
                 summary: "Pick a host and review which local changes a coding worker will inherit.")
        case .integration:
            Info(title: "Integrate worker changes", group: "Delegation", crumbs: ["Relay", "Integrations"], active: "Integrations",
                 summary: "Review worker handoffs, test the combined revision, and inspect each attempt.")
        case .integrationBlocked:
            Info(title: "A blocked integration", group: "Delegation", crumbs: ["Relay", "Integrations"], active: "Integrations",
                 summary: "A failed combined test blocks the branch update and keeps the candidate for investigation.")
        case .history:
            Info(title: "Search run history", group: "Delegation", crumbs: ["Workspace", "History"], active: "History",
                 summary: "Search recorded terminal output and jump to the worker, timestamp, and line.")
        case .crossRun:
            Info(title: "Cross-run access", group: "Delegation", crumbs: ["Relay", "Event schema"], active: "Relay",
                 summary: "A peer coordinator reads a worker's shared transcript and can ask its owner a question.")
        case .firstRun:
            Info(title: "Connect a workspace", group: "Setup & recovery", crumbs: ["Workspace", "Setup"], active: "Hosts",
                 summary: "Open a project, choose hosts, and check the first connection.")
        case .hosts:
            Info(title: "Hosts and capabilities", group: "Setup & recovery", crumbs: ["Workspace", "Hosts"], active: "Hosts",
                 summary: "Local, persistent-helper, and SSH-only hosts and their disconnect capabilities.")
        case .clients:
            Info(title: "Clients and MCP", group: "Setup & recovery", crumbs: ["Workspace", "Clients & MCP"], active: "Clients & MCP",
                 summary: "Configure a client's launch profile and inspect the capabilities available to agents.")
        case .adoption:
            Info(title: "Adopt an existing session", group: "Setup & recovery", crumbs: ["Relay", "Discovery"], active: "Relay",
                 summary: "Verify the pane, conversation, and pending work before enabling control.")
        case .recovery:
            Info(title: "Recover a connection", group: "Setup & recovery", crumbs: ["Hosts", "build-01", "Recovery"], active: "Hosts",
                 summary: "Inspect gaps, control ownership, and an uncertain delivery after SSH reconnects.")
        case .operationDetail:
            Info(title: "Provider sign-in", group: "Setup & recovery", crumbs: ["Attention", "OP-208"], active: "Attention",
                 summary: "Handle a provider step that needs a person, then resume the same operation.")
        case .preferences:
            Info(title: "Workspace preferences", group: "Setup & recovery", crumbs: ["Workspace", "Settings"], active: "Settings",
                 summary: "Choose an attention presentation and transcript retention rules.")
        case .reducedTransparency:
            Info(title: "Reduced transparency", group: "Setup & recovery", crumbs: ["Workspace", "Settings"], active: "Settings",
                 summary: "The same preferences under Reduce Transparency and Increase Contrast.")
        case .accessibleWall:
            Info(title: "Reduced transparency · PiP", group: "Setup & recovery", crumbs: ["Relay", "Retry policy"], active: "Relay",
                 summary: "The opaque cockpit keeps the incoming request, input owner, and keyboard focus distinct.")
        case .accessibleWorker:
            Info(title: "Reduced transparency · worker", group: "Setup & recovery",
                 crumbs: ["Relay", "Retry policy", "Timeout cases"], active: "Relay",
                 summary: "The focused worker under increased contrast, with its request and explicit handback.")
        }
    }

    /// The state named on the command line or in the environment. An unknown value such as
    /// "gallery" opens the first view.
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
        guard let value, !value.isEmpty else { return nil }
        return DesignPreviewScenario(rawValue: value) ?? .coordinatorWall
    }()

    static let startsStatic = ProcessInfo.processInfo.environment["AGENT_COMMANDER_PREVIEW_STATIC"] == "1"
    static let hidesGallery = ProcessInfo.processInfo.environment["AGENT_COMMANDER_PREVIEW_GALLERY"] == "hidden"
}

// MARK: - Preview state

/// In-memory state of the preview: which view is showing and what the developer has changed in
/// the sample workspace (answers, input control, typed lines). It stands in for the feature model.
@Observable @MainActor
final class PreviewStore {
    var scenario: DesignPreviewScenario
    var ui: CockpitPresentationState
    var sidebarExpanded = true
    var selectedRunID = "R-042"
    /// Bumped on every navigation so pages start from their sample state.
    var visit = 0

    var answers: [String: String] = [:]
    var resolvedLog: [ResolvedRequest] = []
    var taken = Set<String>()
    var released = Set<String>()
    var typed: [String: [String]] = [:]
    var coordinatorNotes: [String: [String]] = [:]
    var interrupted = Set<String>()
    var stopped = Set<String>()

    var presentation = AttentionPresentation.drawer
    var agentProject = "All projects"
    var liveActivity = !DesignPreviewScenario.startsStatic
    var tick = 0

    var liveTick: Int { liveActivity ? tick : 0 }

    init(scenario: DesignPreviewScenario) {
        self.scenario = scenario
        self.ui = DesignFixture.state(for: scenario)
        self.selectedRunID = scenario == .attentionSwitch ? "R-039" : "R-042"
    }

    /// Opens a view in its concept state and discards changes made to the sample workspace.
    func go(to scenario: DesignPreviewScenario, zoom workerID: String? = nil, run: String? = nil, project: String? = nil) {
        answers = [:]
        resolvedLog = []
        taken = []
        released = []
        typed = [:]
        coordinatorNotes = [:]
        interrupted = []
        stopped = []
        tick = 0
        agentProject = project ?? "All projects"
        self.scenario = scenario
        selectedRunID = run ?? (scenario == .attentionSwitch ? "R-039" : "R-042")
        let state = DesignFixture.state(for: scenario)
        if let workerID { state.zoomedWorkerID = workerID }
        ui = state
        sidebarExpanded = true
        visit += 1
    }

    func step(_ offset: Int) {
        let all = DesignPreviewScenario.allCases
        guard let index = all.firstIndex(of: scenario) else { return }
        let target = index + offset
        if all.indices.contains(target) { go(to: all[target]) }
    }

    func resolve(_ requestID: String, answer: String) {
        guard answers[requestID] == nil else { return }
        answers[requestID] = answer
        let name = DesignFixture.requests.first { $0.id == requestID }?.workerName ?? requestID
        resolvedLog.insert(ResolvedRequest(id: requestID, workerName: name, time: "just now"), at: 0)
    }

    func take(_ workerID: String) {
        taken.insert(workerID)
        released.remove(workerID)
    }

    func release(_ workerID: String) {
        released.insert(workerID)
        taken.remove(workerID)
    }

    func open(_ request: RequestPresentation, takingControl: Bool = false) {
        if request.runID == "R-039" { go(to: .attentionSwitch) } else { go(to: .focusedWorker) }
        if takingControl { take(request.workerID) }
    }

    func open(agent: AgentConsole) {
        switch agent.id {
        case "timeout": go(to: .focusedWorker)
        case "backoff": go(to: .coordinatorWall, zoom: "W-043")
        case "telemetry": go(to: .coordinatorWall, zoom: "W-044")
        case "api-compat": go(to: .coordinatorWall, zoom: "W-045")
        case "failure-paths": go(to: .coordinatorWall, zoom: "W-046")
        case "event-schema": go(to: .coordinatorWall, run: "R-039")
        case "schema-migration": go(to: .coordinatorWall, zoom: "W-053", run: "R-039")
        case "queue-migration": go(to: .recovery)
        default: go(to: .coordinatorWall)
        }
    }

    func open(worker name: String) {
        switch name {
        case "Timeout cases": go(to: .focusedWorker)
        case "Backoff strategy": go(to: .coordinatorWall, zoom: "W-043")
        case "Retry telemetry": go(to: .coordinatorWall, zoom: "W-044")
        case "Failure paths": go(to: .coordinatorWall, zoom: "W-046")
        default: go(to: .coordinatorWall)
        }
    }

    /// Selecting a presentation from the queue opens the view that presentation produces.
    func choose(_ mode: AttentionPresentation) {
        presentation = mode
        switch mode {
        case .pip: go(to: .attentionPip)
        case .drawer: go(to: .attentionPanel)
        case .switchRun: go(to: .attentionSwitch)
        case .queue: break
        }
    }

    /// Advances the changing sample lines while live activity is on. The first change comes after
    /// a pause, so a capture taken right after launch shows the concept state.
    func runActivity() async {
        try? await Task.sleep(for: .seconds(6))
        while !Task.isCancelled {
            if liveActivity { tick += 1 }
            try? await Task.sleep(for: .milliseconds(2600))
        }
    }

    /// Presentation that can only be applied once the view is in the window.
    func settle(visit: Int) async {
        guard scenario == .tileControls else { return }
        try? await Task.sleep(for: .milliseconds(700))
        if !Task.isCancelled, self.visit == visit { ui.actionMenuWorkerID = "W-043" }
    }
}

// MARK: - Preview page

struct DesignPreviewPage: View {
    @State private var store: PreviewStore

    init(scenario: DesignPreviewScenario) {
        _store = State(initialValue: PreviewStore(scenario: scenario))
    }

    private var gallery: AnyView? {
        DesignPreviewScenario.hidesGallery ? nil : AnyView(PreviewGalleryControl(store: store))
    }

    var body: some View {
        page
            .id(store.visit)
            .environment(\.reduceTransparencyOverride, store.scenario.usesAccessibleAppearance)
            .environment(\.increaseContrastOverride, store.scenario.usesAccessibleAppearance)
            .background(PreviewWindowFrame())
            .task { await store.runActivity() }
            .task(id: store.visit) { await store.settle(visit: store.visit) }
    }

    @ViewBuilder private var page: some View {
        if store.scenario.isCockpit {
            CockpitScreen(content: DesignFixture.content(for: store), ui: store.ui,
                          actions: DesignFixture.actions(for: store),
                          fixtureNavigation: DesignFixture.navigation(for: store),
                          runSetup: DesignFixture.referenceRunSetup,
                          toolbarAccessory: gallery)
        } else {
            WorkspaceScreen(crumbs: store.scenario.info.crumbs, connection: .online,
                            navigation: DesignFixture.navigation(for: store),
                            sidebarExpanded: $store.sidebarExpanded,
                            search: { store.go(to: .history) },
                            toolbarAccessory: gallery) {
                PreviewCanvas(store: store)
            }
        }
    }
}

/// Title-bar control that browses every preview state. The menu is grouped like the concept
/// gallery; the arrows (⌥⌘← and ⌥⌘→) step through the states in order.
struct PreviewGalleryControl: View {
    @Bindable var store: PreviewStore

    var body: some View {
        HStack(spacing: 2) {
            Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(store.scenario.number == 1)
                .help("Previous view (⌥⌘←)")
                .accessibilityLabel("Previous preview view")
                .accessibilityIdentifier("preview-gallery-previous")
                .id("preview-gallery-previous")
            Menu {
                ForEach(DesignPreviewScenario.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(DesignPreviewScenario.allCases.filter { $0.info.group == group }) { scenario in
                            Button { store.go(to: scenario) } label: {
                                if scenario == store.scenario {
                                    Label(scenario.menuTitle, systemImage: "checkmark")
                                } else {
                                    Text(scenario.menuTitle)
                                }
                            }
                        }
                    }
                }
                Divider()
                Toggle("Live sample activity", isOn: $store.liveActivity)
                Button("Reset sample data") { store.go(to: store.scenario) }
            } label: {
                Text(store.scenario.menuTitle).font(.system(size: 12, weight: .medium))
            }
            .help(store.scenario.info.summary)
            .accessibilityLabel("Preview view \(store.scenario.number) of \(DesignPreviewScenario.allCases.count): \(store.scenario.info.title)")
            .accessibilityIdentifier("preview-gallery-menu")
            .id("preview-gallery-menu")
            Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(store.scenario.number == DesignPreviewScenario.allCases.count)
                .help("Next view (⌥⌘→)")
                .accessibilityLabel("Next preview view")
                .accessibilityIdentifier("preview-gallery-next")
                .id("preview-gallery-next")
        }
    }
}

/// The page for each state that is not drawn by CockpitScreen, filled with sample values.
struct PreviewCanvas: View {
    let store: PreviewStore

    var body: some View {
        switch store.scenario {
        case .attentionQueue:
            AttentionQueuePage(
                // The queue lists Timeout cases (Q-018) first and selects it, as in the concept; the
                // PiP stack keeps its own arrival order.
                pending: Array(DesignFixture.pending(for: store).reversed()),
                resolved: store.resolvedLog + PreviewSample.resolvedToday,
                sending: [],
                presentation: store.presentation,
                worker: { request in DesignFixture.worker(for: request, store: store) },
                reply: { requestID, answer in
                    store.resolve(requestID, answer: answer)
                    return true
                },
                takeControl: { request in store.open(request, takingControl: true) },
                openWorker: { request in store.open(request) },
                choosePresentation: { mode in store.choose(mode) })
        case .allAgents:
            AllAgentsPage(agents: PreviewSample.agents(tick: store.liveTick), project: store.agentProject,
                          open: { agent in store.open(agent: agent) },
                          startRun: { store.go(to: .startRun) },
                          saveView: { store.go(to: .smartView) })
        case .project:
            ProjectPage(name: "Relay", path: "~/Developer/relay", identity: "git.example / infra / relay",
                        runs: DesignFixture.runs(for: store), checkouts: PreviewSample.checkouts,
                        openRun: { run in store.go(to: .coordinatorWall, run: run.id) },
                        openWorker: { run, worker in store.go(to: .coordinatorWall, zoom: worker.id, run: run.id) },
                        startCoordinator: { store.go(to: .startRun) },
                        linkCheckout: { store.go(to: .linkCheckout) })
        case .smartView:
            SmartViewPage(name: "Remote workers", rules: PreviewSample.smartViewRules,
                          agents: PreviewSample.remoteAgents(tick: store.liveTick),
                          open: { agent in store.open(agent: agent) })
        case .linkCheckout:
            LinkCheckoutPage(projectName: "Relay", checks: PreviewSample.identityChecks,
                             noticeTitle: "Repository identity needs confirmation",
                             noticeDetail: "The directory name and commit match. This checkout has no remote origin. Linking it adds its runs to Relay.",
                             decided: { _ in })
        case .delegateWorker:
            DelegateWorkerPage(setup: PreviewSample.delegation,
                               delegate: { _ in store.go(to: .coordinatorWall) },
                               cancel: { store.go(to: .coordinatorWall) })
        case .integration:
            IntegrationPage(review: PreviewSample.integration(blocked: false))
        case .integrationBlocked:
            IntegrationPage(review: PreviewSample.integration(blocked: true))
        case .history:
            HistoryPage(kicker: "RELAY / HISTORY",
                        subtitle: "15:02 · Search the Relay project’s recorded output, including conversations owned by another coordinator.",
                        query: "timeout budget", project: "Relay", matches: PreviewSample.transcriptMatches,
                        sharingNote: "Project history shared across its coordinators.", retention: "Retention · 30 days",
                        openWorker: { match in store.open(worker: match.worker) },
                        openRun: { _ in store.go(to: .coordinatorWall) })
        case .crossRun:
            CrossRunPage(access: PreviewSample.crossRun, openTranscript: { store.go(to: .history) })
        case .firstRun:
            FirstRunPage(projectName: "Relay", projectKind: "Git repository", projectPath: "~/Developer/relay",
                         hosts: PreviewSample.setupHosts, selected: ["Mac Studio", "build-01"],
                         sessions: PreviewSample.discoveredSessions,
                         steps: ["Discover workspace", "Connect client MCP", "Review & adopt sessions"],
                         proceed: { store.go(to: .clients) })
        case .hosts:
            HostsPage(subtitle: "Local and SSH execution environments for Relay.", hosts: PreviewSample.hosts,
                      selection: "build-01", capabilities: PreviewSample.hostCapabilities, configPath: "~/.ssh/config",
                      policyTitle: "Run disconnect policy",
                      policyDetail: "Retry policy can finish current assignments on build-01. Further delegation waits for reconnect.",
                      policyStatus: "Hold delegation",
                      enroll: { store.go(to: .firstRun) },
                      recover: { _ in store.go(to: .recovery) })
        case .clients:
            ClientsPage(profiles: PreviewSample.clients, selection: "generic")
        case .adoption:
            AdoptionPage(panes: PreviewSample.panes, selection: "p1", runLabel: "Retry policy", runID: "R-042")
        case .recovery:
            RecoveryPage(report: PreviewSample.recovery, openWorker: { name in store.open(worker: name) })
        case .operationDetail:
            OperationDetailPage(operation: PreviewSample.operation,
                                openPrompt: { store.go(to: .coordinatorWall, zoom: "W-044") })
        case .preferences, .reducedTransparency:
            PreferencesPage(projectName: "Relay", retention: "30 days",
                            retentionOptions: ["7 days", "30 days", "90 days", "1 year"],
                            showsSystemAppearance: store.scenario == .reducedTransparency,
                            presentation: store.presentation,
                            choosePresentation: { mode in store.presentation = mode })
        case .coordinatorWall, .focusedWorker, .tileControls, .attentionPip, .pipArrival, .attentionPanel,
             .attentionSwitch, .startRun, .accessibleWall, .accessibleWorker:
            // Drawn by CockpitScreen in DesignPreviewPage.
            EmptyView()
        }
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

// MARK: - Cockpit fixtures

@MainActor
enum DesignFixture {
    // MARK: Presentation state per scenario

    static func state(for scenario: DesignPreviewScenario) -> CockpitPresentationState {
        let ui = CockpitPresentationState()
        ui.offersReturnNavigation = true
        switch scenario {
        case .coordinatorWall:
            ui.dismissedRequests = ["Q-018", "Q-021"]
        case .focusedWorker, .accessibleWorker:
            ui.zoomedWorkerID = "W-047"
            ui.dismissedRequests = ["Q-021"]
        case .tileControls:
            // The action list for Backoff strategy opens once the window is up (PreviewStore.settle).
            ui.dismissedRequests = ["Q-018", "Q-021"]
            ui.initialPaneFocus = "W-043"
        case .attentionPip:
            // Pinned to the PiP: this view shows that presentation whatever the default is.
            ui.attentionPresentation = .pip
            ui.activeRequestID = "Q-021"
            ui.drafts["Q-021"] = "Server owns emitted field names."
            ui.initialReplyFocus = "Q-021"
        case .pipArrival, .accessibleWall:
            ui.attentionPresentation = .pip
            ui.activeRequestID = "Q-021"
            ui.initialPaneFocus = "W-043"
        case .attentionPanel:
            ui.attentionPresentation = .drawer
            ui.activeRequestID = "Q-018"
        case .attentionSwitch:
            ui.zoomedWorkerID = "W-052"
            ui.dismissedRequests = ["Q-018"]
            ui.returnTarget = ReturnTarget(runID: "R-042", runTitle: "Retry policy", workerID: "W-047",
                                           workerName: "Timeout cases", requestLabel: "Field ownership · Q-021")
        case .startRun:
            ui.sidebarExpanded = true
            ui.composingRun = true
            ui.newRunDraft = NewRunDraft(
                title: "Retry policy",
                path: NSHomeDirectory() + "/Developer/relay",
                task: "Plan and implement a retry policy for upstream requests. Keep non-idempotent calls safe.")
        default:
            break
        }
        return ui
    }

    // MARK: Content

    static let requests: [RequestPresentation] = [fieldOwnershipRequest, timeoutRequest].map { withSampleConnection($0) }

    /// The sample worker shown as disconnected, when a capture asks for one. Its pending request
    /// stays in place with the reply closed, on the wall, in the focused worker and in the PiP.
    static let disconnectedWorkerID = ProcessInfo.processInfo.environment["AGENT_COMMANDER_PREVIEW_DISCONNECT"]
    /// The sample worker whose persistent SSH link is shown reconnecting, when a capture asks for
    /// one. It keeps its own status, and a pending request can still be answered.
    static let reconnectingWorkerID: String? = {
        let id = ProcessInfo.processInfo.environment["AGENT_COMMANDER_PREVIEW_RECONNECT"]
        return id == disconnectedWorkerID ? nil : id
    }()
    /// The sample worker shown with an accepted answer whose delivery is unknown.
    static let unconfirmedWorkerID = ProcessInfo.processInfo.environment["AGENT_COMMANDER_PREVIEW_DELIVERY_UNKNOWN"]

    static func disconnectReason(host: String) -> String {
        "SSH connection to \(host) lost at 14:34:11. Last output is shown. Waiting to reconnect and reconcile."
    }

    private static func withSampleConnection(_ request: RequestPresentation) -> RequestPresentation {
        var request = request
        if request.workerID == reconnectingWorkerID { request.hostIsReconnecting = true }
        guard request.workerID == disconnectedWorkerID else { return request }
        request.disconnectReason = disconnectReason(host: request.host)
        return request
    }

    /// Pending requests across both runs, in arrival order for the stack.
    static func pending(for store: PreviewStore) -> [RequestPresentation] {
        requests.filter { store.answers[$0.id] == nil }
    }

    static func runs(for store: PreviewStore) -> [RunContent] {
        [retryPolicyRun(store), eventSchemaRun(store)]
    }

    static func worker(for request: RequestPresentation, store: PreviewStore) -> WorkerPresentation? {
        for run in runs(for: store) {
            if let match = run.wall.workers.first(where: { $0.id == request.workerID }) { return match }
            if let coordinator = run.coordinator, coordinator.id == request.workerID { return coordinator }
        }
        return nil
    }

    static func content(for store: PreviewStore) -> CockpitContent {
        let all = runs(for: store)
        let relay = NSHomeDirectory() + "/Developer/relay"
        return CockpitContent(
            connection: .online, notice: nil, isStopping: false,
            runs: [
                RunSummary(id: "R-042", project: "Relay", path: relay, title: "Retry policy", status: .running),
                RunSummary(id: "R-039", project: "Relay", path: relay, title: "Event schema", status: .running),
                RunSummary(id: "R-038", project: "Beacon", path: NSHomeDirectory() + "/Developer/beacon",
                           title: "Queue migration", status: .disconnected)
            ],
            selected: all.first { $0.id == store.selectedRunID } ?? all.first,
            pending: pending(for: store),
            sending: [])
    }

    /// In-memory intents. Each changes the sample workspace the way the service would report it.
    static func actions(for store: PreviewStore) -> CockpitActions {
        CockpitActions(
            selectRun: { id in
                if id == "R-038" { store.go(to: .allAgents, project: "Beacon") } else { store.selectedRunID = id }
            },
            reply: { requestID, answer in
                // As in the service: a disconnected worker's request cannot be answered.
                if requests.contains(where: { $0.id == requestID && $0.isWorkerDisconnected }) { return false }
                store.resolve(requestID, answer: answer)
                return true
            },
            stopRun: { _ in },
            reconnect: {},
            dismissNotice: {},
            createRun: { _, _, _, _ in store.go(to: .coordinatorWall) },
            handBack: { workerID in store.release(workerID) },
            sendFollowUp: { workerID, text in
                store.typed[workerID, default: []].append(text)
                return true
            },
            messageCoordinator: { runID, text in store.coordinatorNotes[runID, default: []].append(text) },
            searchWorkspace: { store.go(to: .history) },
            chooseWallGrouping: {},
            takeControl: { workerID in store.take(workerID) },
            interruptWorker: { workerID in store.interrupted.insert(workerID) },
            stopWorker: { workerID in store.stopped.insert(workerID) })
    }

    /// The whole navigation model of the concepts. Every row opens the matching preview view.
    static func navigation(for store: PreviewStore) -> FixtureNavigation {
        let active = store.scenario.info.active
        func row(_ title: String, _ mark: NavigationItem.Mark, badge: Int = 0,
                 action: @escaping () -> Void) -> NavigationItem {
            NavigationItem(id: "preview-\(title)", title: title, mark: mark, badge: badge,
                           isActive: active == title, action: action)
        }
        let workspace = [
            row("All agents", .symbol("square.grid.2x2")) { store.go(to: .allAgents) },
            row("Attention", .symbol("bell"), badge: pending(for: store).count) { store.go(to: .attentionQueue) },
            row("History", .symbol("clock.arrow.circlepath")) { store.go(to: .history) },
            row("Integrations", .symbol("arrow.triangle.merge")) { store.go(to: .integration) }
        ]
        let projects = [
            row("Relay", .letter("R")) { store.go(to: .project) },
            row("Beacon", .letter("B")) { store.go(to: .allAgents, project: "Beacon") }
        ]
        let smart = [
            row("Remote workers", .symbol("line.3.horizontal.decrease")) { store.go(to: .smartView) }
        ]
        let footer = [
            NavigationItem(id: "preview-new-run", title: "New run", mark: .symbol("plus"),
                           isActive: store.scenario == .startRun,
                           shortcut: KeyboardShortcut("n", modifiers: .command),
                           action: { store.go(to: .startRun) }),
            row("Hosts", .symbol("server.rack")) { store.go(to: .hosts) },
            row("Clients & MCP", .symbol("terminal")) { store.go(to: .clients) },
            row("Settings", .symbol("gearshape")) { store.go(to: .preferences) }
        ]
        return FixtureNavigation(
            groups: [NavigationGroup(id: "workspace", title: "Workspace", items: workspace),
                     NavigationGroup(id: "projects", title: "Projects", items: projects),
                     NavigationGroup(id: "smart", title: "Smart views", items: smart)],
            footer: footer)
    }

    // MARK: Runs

    private static func retryPolicyRun(_ store: PreviewStore) -> RunContent {
        let scenario = store.scenario
        let holdsBackoff = scenario == .pipArrival || scenario == .accessibleWall
        let holdsTimeout = scenario == .focusedWorker || scenario == .accessibleWorker
        // The wall and PiP show the compact tail with the pending question; the zoomed worker
        // shows the expanded turn.
        let timeoutOutput = store.ui.zoomedWorkerID == "W-047" ? timeoutTranscript : timeoutTail
        let run = "Retry policy"
        let wall = WallLayout(
            leaves: [
                worker(store, id: "W-043", name: "Backoff strategy", client: .codex, host: .macStudio,
                       branch: "feat/backoff", state: .working, started: "14:16:34", run: run, held: holdsBackoff,
                       task: "Implement capped exponential backoff with jitter. Keep the retry budget per request.",
                       output: backoffOutput),
                worker(store, id: "W-044", name: "Retry telemetry", client: .codex, host: .build01,
                       branch: "feat/telemetry", state: .working, started: "14:16:32", run: run,
                       task: "Add retry counters and structured backoff events. Return the changed revision and the telemetry test results.",
                       output: telemetryOutput),
                worker(store, id: "W-045", name: "API compatibility", client: .mcp, host: .macStudio,
                       branch: "main", state: .idle, started: "14:16:19", run: run,
                       task: "Check that the public client options stay compatible with the new retry defaults.",
                       output: compatibilityOutput)
            ],
            groups: [
                WorkerGroup(
                    parent: worker(store, id: "W-046", name: "Failure paths", client: .claude, host: .build01,
                                   branch: "main", state: .working, started: "14:16:28", run: run,
                                   task: "Map every failure path and decide which are safe to retry. Delegate edge cases that need their own tests.",
                                   output: failurePathsOutput),
                    members: [
                        worker(store, id: "W-047", name: "Timeout cases", client: .codex, host: .build01,
                               branch: "main", state: .needsInput, started: "14:12:41", run: run,
                               parents: ["Failure paths"], held: holdsTimeout, request: timeoutRequest,
                               task: "Cover timeout behavior before headers, after headers, and after the first body chunk.\nReport any ambiguous cases.",
                               output: timeoutOutput)
                    ])
            ])
        let lead = coordinator(store, runID: "R-042", id: "W-042", name: "Claude Code", client: .claude,
                               run: run, task: assignment, started: "14:08:02", output: coordinatorOutput)
        return RunContent(
            id: "R-042", shortID: "R-042", project: "Relay", path: NSHomeDirectory() + "/Developer/relay",
            title: run, task: assignment, client: .claude, branch: "main", startedAt: "14:08",
            status: .running, canStop: true, coordinator: lead, wall: wall,
            awaiting: wall.workers.compactMap(\.request))
    }

    private static func eventSchemaRun(_ store: PreviewStore) -> RunContent {
        let run = "Event schema"
        let task = "Define the event schema and settle ownership of the fields clients emit."
        let wall = WallLayout(
            leaves: [
                worker(store, id: "W-052", name: "Field ownership", client: .claude, host: .macStudio,
                       branch: "main", state: .needsInput, started: "14:05:11", run: run, request: fieldOwnershipRequest,
                       task: "Trace public event payloads and recommend which side should define field names.",
                       output: fieldOwnershipOutput),
                worker(store, id: "W-053", name: "Schema migration", client: .codex, host: .lab02,
                       branch: "main", state: .working, started: "14:06:40", run: run,
                       task: "Check that existing consumers accept both field names during the migration.",
                       output: schemaMigrationOutput)
            ])
        let lead = coordinator(store, runID: "R-039", id: "W-050", name: "Codex", client: .codex,
                               run: run, task: task, started: "14:03:17", output: eventCoordinatorOutput)
        return RunContent(
            id: "R-039", shortID: "R-039", project: "Relay", path: NSHomeDirectory() + "/Developer/relay",
            title: run, task: task, client: .codex, branch: "main", startedAt: "14:03",
            status: .running, canStop: true, coordinator: lead, wall: wall,
            awaiting: wall.workers.compactMap(\.request))
    }

    // MARK: Sample workers

    /// A sample worker with the developer's in-memory changes applied: an answered request, input
    /// control, typed lines, interrupt and stop, and the changing tail while live activity is on.
    /// A sample execution host. Its platform is stated here as explicit fixture metadata, the way
    /// a host record would carry it; nothing reads the platform out of the name.
    private struct SampleHost {
        let name: String
        let platform: HostPlatform

        /// The Mac that Commander runs on.
        static let macStudio = SampleHost(name: "Mac Studio", platform: .localMac)
        /// A Linux build host reached over SSH.
        static let build01 = SampleHost(name: "build-01", platform: .remoteLinux)
        /// A second Mac reached over SSH.
        static let lab02 = SampleHost(name: "lab-02", platform: .remoteMac)
    }

    private static func worker(_ store: PreviewStore, id: String, name: String, client: AgentClient, host: SampleHost,
                               branch: String, state: TaskState, started: String, run: String,
                               parents: [String] = [], held: Bool = false, request: RequestPresentation? = nil,
                               task: String, output: String) -> WorkerPresentation {
        let holder = parents.last ?? run
        var output = output
        var state = state
        var pending = request.map { withSampleConnection($0) }
        var error: String? = nil
        if let asked = request, let answer = store.answers[asked.id] {
            pending = nil
            state = .working
            output += "\n\n14:19:02 YOU\n\(answer)\n\nApplying the decision and continuing."
        }
        for line in store.typed[id] ?? [] { output += "\n$ \(line)" }
        if store.stopped.contains(id) {
            state = .stopped
            output += "\n\nWorker stopped from Commander."
        } else if store.interrupted.contains(id) {
            state = .idle
            output += "\n\n^C Turn interrupted from Commander."
        } else if id == disconnectedWorkerID {
            // The worker keeps its last output and its pending request; only the connection changed.
            state = .disconnected
            error = disconnectReason(host: host.name)
        } else if state == .working, let script = liveScripts[id] {
            for line in script.prefix(store.liveTick % (script.count + 1)) { output += "\n" + line }
        }
        var control = held ? InputControl.held : InputControl.observing(holder: holder)
        if store.taken.contains(id) { control = .held }
        if store.released.contains(id) { control = .observing(holder: holder) }
        return WorkerPresentation(
            id: id, shortID: id, name: name, client: client, host: host.name, platform: host.platform,
            location: branch, locationIsBranch: true, task: task, output: output, error: error,
            state: state, isCoordinator: false, lineage: [run] + parents + [name],
            control: control, request: pending, startedAt: started,
            unconfirmedReply: id == unconfirmedWorkerID ? "Q-016" : nil,
            // Only the link changed: status, output and the pending request are as they were.
            hostIsReconnecting: id == reconnectingWorkerID && state != .stopped)
    }

    private static func coordinator(_ store: PreviewStore, runID: String, id: String, name: String,
                                    client: AgentClient, run: String, task: String, started: String,
                                    output: String) -> WorkerPresentation {
        var output = output
        for note in store.coordinatorNotes[runID] ?? [] { output += "\n\n14:19:10 YOU\n\(note)" }
        return WorkerPresentation(
            id: id, shortID: id, name: name, client: client,
            host: SampleHost.macStudio.name, platform: SampleHost.macStudio.platform,
            location: "main", locationIsBranch: true, task: task, output: output, error: nil,
            state: .working, isCoordinator: true, lineage: [run],
            control: .observing(holder: name), request: nil, startedAt: started)
    }

    /// Lines that arrive one at a time on working tiles while live activity is on.
    private static let liveScripts: [String: [String]] = [
        "W-043": ["✓ delay doubles until the cap", "✓ jitter is deterministic under a seed", "", "$ pnpm lint retry/"],
        "W-044": ["✓ retry_attempt_total increments", "✓ retry_exhausted_total increments", "", "$ pnpm test telemetry"],
        "W-046": ["", "Waiting for Timeout cases…", "Drafting the eligibility table."],
        "W-053": ["✓ consumer billing accepts sourceName", "✓ consumer audit accepts sourceName"]
    ]

    private static let assignment =
        "Plan and implement a retry policy for upstream requests. Keep non-idempotent calls safe."

    private static let timeoutRequest = RequestPresentation(
        id: "Q-018", shortID: "Q-018",
        question: "Should the client retry after response body bytes have already been delivered?",
        workerID: "W-047", workerName: "Timeout cases", workerIsCoordinator: false, client: .codex,
        runID: "R-042", runTitle: "Retry policy", project: "Relay",
        host: SampleHost.build01.name, platform: SampleHost.build01.platform,
        inputHolder: "Failure paths",
        contextTail: ["$ pnpm test timeout", "✓ connection can retry"])

    private static let fieldOwnershipRequest = RequestPresentation(
        id: "Q-021", shortID: "Q-021",
        question: "Should the server or client own the emitted field names?",
        workerID: "W-052", workerName: "Field ownership", workerIsCoordinator: false, client: .claude,
        runID: "R-039", runTitle: "Event schema", project: "Relay",
        host: SampleHost.macStudio.name, platform: SampleHost.macStudio.platform,
        inputHolder: "Event schema",
        contextTail: ["$ rg 'source_name' packages/events", "emit.ts:42 · source_name"])

    private static let coordinatorOutput = """
    14:08:07 CLAUDE CODE
    I’ll map the failure paths first, then split the
    backoff and telemetry changes into separate worktrees.

    ▸ delegate Backoff strategy  ✓ done
      Codex · Mac Studio
    ▸ delegate Failure paths  ✓ done
      Claude Code · build-01
    ▸ delegate Retry telemetry  ✓ done
      Codex · build-01
    ▸ delegate API compatibility  ✓ done
      MCP client · Mac Studio

    14:16:28 CLAUDE CODE
    The retry budget is scoped per request. The remaining
    decision is whether a partially consumed response can
    be retried.
    """

    private static let eventCoordinatorOutput = """
    14:03:22 CODEX
    I’ll compare the producer contract with existing
    consumers, then reconcile the field names.

    ▸ delegate Field ownership  ✓ done
      Claude Code · Mac Studio
    ▸ delegate Schema migration  ✓ done
      Codex · lab-02

    14:18:05 CODEX
    Both contracts allow a field rename. Ownership
    determines which implementation changes first.
    """

    private static let backoffOutput = """
    ▾ shell $ git diff --stat  ✓ done
    │ retry/backoff.ts  | 42 ++++++
    │ retry/budget.ts   | 18 +++
    │ 2 files changed

    ▾ shell $ pnpm test backoff  ✓ done
    │ ✓ jitter stays within cap
    │ ✓ budget resets per request
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

    ▸ delegate Timeout cases  … running
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

    ▸ read `retry/timeout.ts`  ✓ done
    ▾ shell $ pnpm test timeout --reporter=spec  ✓ done
    │ ✓ connect timeout retries inside the request budget
    │ ✓ exhausted retries return the upstream timeout
    │ ? partial response body • policy decision required

    14:16:28 CODEX
    The partial-body case needs a policy decision before I change `retry/timeout.ts`.
    """

    /// Expanded turn from the switch-to-run concept.
    private static let fieldOwnershipOutput = """
    14:16:40 CLAUDE CODE
    The producer emits `source_name`; the client maps it to `sourceName`. Moving ownership determines where future aliases live.

    ▾ shell $ rg 'source_name|sourceName' packages/  ✓ done
    │ packages/events/emit.ts:42       source_name
    │ packages/client/normalize.ts:18  sourceName
    """

    private static let schemaMigrationOutput = """
    $ pnpm migrate --dry-run
    Reading schema/events.json

    ✓ 3 consumers accept both field names
    Waiting for the ownership decision…
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
