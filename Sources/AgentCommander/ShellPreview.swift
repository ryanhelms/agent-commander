import SwiftUI

// ATOMIC LEVEL: Pages (design previews of the main-window shell).
// Three sidebar prototypes over one navigation model, with the Needs you inbox, as full preview
// windows filled with sample values. Nothing here is reachable in a normal launch and nothing
// contacts the service or the network model.
//
//   open "dist/Agent Commander.app" --args --design-preview shell-a    grouped sidebar
//   open "dist/Agent Commander.app" --args --design-preview shell-b    mode rail with context list
//   open "dist/Agent Commander.app" --args --design-preview shell-c    Needs you first
//   open "dist/Agent Commander.app" --args --design-preview needs-you  the inbox, in sidebar C
//
// The A, B, C control in the toolbar (⌥⌘1, ⌥⌘2, ⌥⌘3) changes the sidebar and keeps the selected
// place. ⌥⌘T changes the theme. Decisions change the sample inbox only.

/// The three sidebar concepts.
enum ShellConcept: String, CaseIterable, Identifiable, Sendable {
    case grouped = "A", modeRail = "B", needsYouFirst = "C"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .grouped: "Grouped sidebar"
        case .modeRail: "Mode rail with context list"
        case .needsYouFirst: "Needs you first"
        }
    }

    var scenario: DesignPreviewScenario {
        switch self {
        case .grouped: .shellA
        case .modeRail: .shellB
        case .needsYouFirst: .shellC
        }
    }

    init?(scenario: DesignPreviewScenario) {
        switch scenario {
        case .shellA: self = .grouped
        case .shellB: self = .modeRail
        case .shellC, .needsYou: self = .needsYouFirst
        default:
            // A network or Teams page opens in the chosen sidebar, B.
            guard scenario.networkPlace != nil || scenario.teamsPlace != nil else { return nil }
            self = .modeRail
        }
    }
}

// MARK: - Sample values

enum ShellSample {
    static let servers = CommanderServerHealth(online: 2, total: 3)

    static let profile = CommanderProfile(name: "Ryan", handle: "ryan", presence: .online, choice: .auto)

    /// The sample inbox: two questions and an approval from local workers, then two approvals, an
    /// access request and a friend request from the network. Q-018 and Q-021 are the Attention
    /// queue's sample questions.
    static let inbox = NeedsYouInbox(items: [
        NeedsYouItem(id: "F-031", kind: .friendRequest,
                     origin: .friend(handle: "tomas", server: "studio.example", serverID: "srv-studio"),
                     title: "tomas sent a friend request",
                     detail: "You are both members of studio.example. Friends can see presence and ask for access.",
                     waiting: 5_400),
        NeedsYouItem(id: "Q-021", kind: .workerQuestion,
                     origin: .worker(name: "Field ownership", host: "lab-02"),
                     title: "Should the server or client own the emitted field names?",
                     detail: "Event schema is stopped until this is answered.",
                     waiting: 260),
        NeedsYouItem(id: "N-114", kind: .networkApproval,
                     origin: .friend(handle: "mira", server: "studio.example", serverID: "srv-studio"),
                     title: "relay-worker on ryan-mac wants to run the integration tests",
                     detail: "mira's hand-off asks to run make integration in ~/Developer/relay. Nothing is written outside the checkout.",
                     waiting: 48, expiresIn: 252),
        NeedsYouItem(id: "X-207", kind: .accessRequest,
                     origin: .friend(handle: "ines", server: "lab.example", serverID: "srv-lab"),
                     title: "ines asks to watch Retry policy",
                     detail: "Watch is read-only: ines sees the worker's output and can't type.",
                     waiting: 1_260),
        NeedsYouItem(id: "A-007", kind: .workerApproval,
                     origin: .worker(name: "Backoff strategy", host: "Mac Studio"),
                     title: "Backoff strategy wants to edit retry/policy.go",
                     detail: "The edit changes the default backoff ceiling from 30 s to 60 s.",
                     waiting: 95),
        NeedsYouItem(id: "Q-018", kind: .workerQuestion,
                     origin: .worker(name: "Timeout cases", host: "build-01"),
                     title: "Should the client retry after response body bytes have already been delivered?",
                     detail: "Retry policy is stopped until this is answered.",
                     waiting: 410),
        NeedsYouItem(id: "N-118", kind: .networkApproval,
                     origin: .friend(handle: "jonah", server: "lab.example", serverID: "srv-lab"),
                     title: "docs-agent on ryan-mac wants to read docs/retries.md",
                     detail: "jonah's consult asks to read one file. The answer is signed by this Mac.",
                     waiting: 130, expiresIn: 700)
    ])

    /// The whole navigation for the given counts.
    static func navigation(inbox: NeedsYouInbox, attention: Int, selection: String,
                           collapsed: Set<String> = [], profile: CommanderProfile = profile,
                           servers: CommanderServerHealth = servers, approvals: Int? = nil, friendRequests: Int? = nil,
                           handoffs: Int = 0, workspaces: [CommanderPlace] = TeamsSample.workspacePlaces(TeamsSample.content),
                           isAdmin: Bool = true) -> CommanderNavigation {
        func place(_ id: String, _ title: String, _ symbol: String, count: Int = 0, figure: String? = nil,
                   hot: Bool = false, detail: Bool = false, noun: String = "waiting") -> CommanderPlace {
            CommanderPlace(id: id, title: title, mark: .symbol(symbol), count: count, figure: figure,
                           isHot: hot && count > 0, isDetail: detail, countNoun: noun)
        }
        let approvals = approvals ?? inbox.pendingCount(of: .networkApproval)
        let friendRequests = friendRequests ?? inbox.pendingCount(of: .friendRequest)
        let places = [
            place("needs-you", "Needs you", "tray", count: inbox.pendingCount, hot: true),
            place("runs", "Runs", "rectangle.split.2x1"),
            place("all-agents", "All agents", "square.grid.2x2"),
            place("attention", "Attention", "bell", count: attention, hot: true),
            place("history", "History", "clock.arrow.circlepath"),
            CommanderPlace(id: "project.relay", title: "Relay", mark: .letter("R")),
            CommanderPlace(id: "project.beacon", title: "Beacon", mark: .letter("B")),
            place("network.people", "People", "person.2", count: 4, noun: "friends"),
            place("network.servers", "Servers", "server.rack", figure: servers.figure),
            place("network.shared", "Shared", "square.and.arrow.up.on.square"),
            place("network.directory", "Directory", "magnifyingglass", detail: true),
            place("network.approvals", "Approvals", "checkmark.shield", count: approvals, hot: true, detail: true),
            place("network.handoffs", "Hand-offs", "arrow.up.right", count: handoffs, detail: true, noun: "sent"),
            place("network.threads", "Threads", "bubble.left.and.bubble.right", detail: true),
            place("network.audit", "Audit", "list.bullet.rectangle", detail: true),
            place("network.fanout", "Fan-out", "arrow.triangle.branch", detail: true),
            place("people.requests", "Friend requests", "person.badge.plus", count: friendRequests, hot: true, detail: true),
            place("people.groups", "Groups", "person.3", detail: true),
        ] + workspaces + LiveShell.teamTools(isAdmin: isAdmin) + [
            place("hosts", "Hosts", "desktopcomputer"),
            place("settings", "Settings", "gearshape")
        ]
        let workspace = CommanderPlaceGroup(id: "workspace", title: "Workspace",
                                            placeIDs: ["needs-you", "runs", "all-agents", "attention", "history"])
        let projects = CommanderPlaceGroup(id: "projects", title: "Projects",
                                           placeIDs: ["project.relay", "project.beacon"], isCollapsible: true)
        let teams = CommanderPlaceGroup(id: "teams", title: "Teams", placeIDs: workspaces.map(\.id), isCollapsible: true)
        return CommanderNavigation(
            places: places,
            inbox: CommanderInbox(placeID: "needs-you", absorbs: ["attention", "network.approvals", "people.requests"],
                                  summary: inbox.summary),
            groups: [
                workspace, projects,
                CommanderPlaceGroup(id: "network", title: "Network",
                                    placeIDs: ["network.people", "network.servers", "network.shared"], isCollapsible: true),
                teams
            ],
            modes: [
                CommanderMode(id: "agents", title: "Agents", symbol: "terminal", sections: [workspace, projects]),
                CommanderMode(id: "network", title: "Network", symbol: "network", sections: [
                    CommanderPlaceGroup(id: "network", title: "Network",
                                        placeIDs: ["network.servers", "network.directory", "network.approvals",
                                                   "network.handoffs", "network.threads", "network.audit",
                                                   "network.fanout", "network.shared"])
                ]),
                CommanderMode(id: "people", title: "People", symbol: "person.2", sections: [
                    CommanderPlaceGroup(id: "people", title: "People",
                                        placeIDs: ["network.people", "people.requests", "people.groups"])
                ]),
                CommanderMode(id: "teams", title: "Teams", symbol: "rectangle.3.group",
                              sections: LiveShell.teamsSections(workspaces: workspaces.map(\.id), isAdmin: isAdmin)),
                CommanderMode(id: "settings", title: "Settings", symbol: "gearshape", sections: [
                    CommanderPlaceGroup(id: "settings", title: "Settings", placeIDs: ["settings", "hosts"])
                ], isTrailing: true)
            ],
            footer: ["hosts", "settings"],
            profile: profile,
            selection: selection,
            collapsed: collapsed)
    }

    /// What a place without a page yet says, and which increment brings it.
    static func note(for placeID: String) -> String {
        switch placeID {
        case "network.people": return "Your friends, their presence and their agents arrive with the network pages."
        case "network.servers": return "Server health, certificates and settings arrive with the network pages."
        case "network.shared": return "What you share and what friends share with you arrives with the network pages."
        case "network.approvals", "people.requests": return "Decide these in Needs you. The full list arrives with the network pages."
        default: return "This page arrives with the network pages."
        }
    }
}

// MARK: - Preview state

/// What the owner has changed in the shell preview: the selected place, folded groups, presence
/// and inbox decisions. It stands in for the feature model.
@Observable @MainActor
final class ShellPreviewState {
    var selection: String
    var collapsed: Set<String> = []
    var profile = ShellSample.profile
    var inbox = ShellSample.inbox
    /// The sample network behind the network pages.
    let network: NetworkPreviewState
    /// The sample teams behind the Teams pages.
    let teams: TeamsPreviewState
    /// How long an outcome stays before its row leaves.
    var outcomeDwell: Duration = .milliseconds(2400)
    /// What the sample network adds to the wall. Take back removes the hold.
    var wall = WallSample.work()

    init(selection: String, teams: TeamsPreviewState? = nil) {
        self.selection = selection
        // A page opened directly shows its detail; the others start with nothing open.
        network = NetworkPreviewState(place: NetworkPlace.hasPage(selection) ? selection : nil)
        self.teams = teams ?? TeamsPreviewState(place: TeamsPlace.hasPage(selection) ? selection : nil)
    }

    /// The state a scenario opens with.
    convenience init(scenario: DesignPreviewScenario) {
        self.init(selection: scenario.networkPlace ?? scenario.teamsPlace ?? (scenario == .needsYou ? "needs-you" : "all-agents"),
                  teams: scenario.teamsPlace == nil ? nil : TeamsPreviewState(scenario: scenario))
    }

    /// The inbox without the questions already answered in the Attention queue.
    func inbox(answered: Set<String>) -> NeedsYouInbox {
        var result = inbox
        for id in answered { result.withdraw(id) }
        return result
    }

    func navigation(attention: Int, answered: Set<String>) -> CommanderNavigation {
        ShellSample.navigation(inbox: inbox(answered: answered), attention: attention, selection: selection,
                               collapsed: collapsed, profile: profile, servers: network.health,
                               approvals: network.approvalCount, friendRequests: network.friendRequestCount,
                               handoffs: network.handoffCount, workspaces: teams.workspacePlaces,
                               isAdmin: teams.content.isAdmin)
    }

    func apply(_ action: CommanderNavigationAction, to navigation: CommanderNavigation) {
        var next = navigation
        next.apply(action)
        // What a Teams page said stays on that page.
        if next.selection != selection { teams.state.left(selection) }
        selection = next.selection
        collapsed = next.collapsed
        if let profile = next.profile { self.profile = profile }
    }

    /// Records a decision, shows its outcome, then lets the row leave.
    func decide(_ id: String, _ decision: NeedsYouDecision) {
        guard inbox.decide(id, decision) else { return }
        Task { [weak self, outcomeDwell] in
            try? await Task.sleep(for: outcomeDwell)
            self?.inbox.clear(id)
        }
    }
}

// MARK: - Preview page

/// One shell preview window: the chosen navigation template, the toolbar and the selected place.
struct ShellPreviewPage: View {
    let store: PreviewStore
    /// The preview gallery's control, kept beside the shell's own toolbar content.
    var gallery: AnyView? = nil
    var chrome = ShellChrome.native
    @State private var state: ShellPreviewState

    init(store: PreviewStore, gallery: AnyView? = nil, state: ShellPreviewState? = nil,
         chrome: ShellChrome = .native) {
        self.store = store
        self.gallery = gallery
        self.chrome = chrome
        _state = State(initialValue: state ?? ShellPreviewState(scenario: store.scenario))
    }

    private var concept: ShellConcept { ShellConcept(scenario: store.scenario) ?? .grouped }
    private var answered: Set<String> { Set(store.answers.keys) }

    var body: some View {
        let navigation = state.navigation(attention: DesignFixture.pending(for: store).count, answered: answered)
        let act: (CommanderNavigationAction) -> Void = { state.apply($0, to: navigation) }
        ShellTemplate(chrome: chrome) {
            switch concept {
            case .grouped: AnyView(ShellSidebarGrouped(navigation: navigation, act: act))
            case .modeRail: AnyView(ShellModeRail(navigation: navigation, act: act))
            case .needsYouFirst: AnyView(ShellNeedsYouSidebar(navigation: navigation, act: act))
            }
        } toolbarLeading: {
            AnyView(ShellToolbarTitle(crumbs: navigation.crumbs))
        } toolbarTrailing: {
            AnyView(HStack(spacing: Space.m) {
                if let gallery { gallery }
                ShellPreviewSwitcher(concept: concept, choose: { store.scenario = $0.scenario },
                                     chooseTheme: { ThemeChoice.select($0) })
                ShellToolbarReadouts(servers: state.network.health,
                                     profile: concept == .needsYouFirst ? nil : navigation.profile,
                                     openServers: { act(.select("network.servers")) },
                                     pickPresence: { act(.setPresence($0)) })
            })
        } canvas: {
            AnyView(ShellPreviewCanvas(store: store, state: state, navigation: navigation, act: act))
        }
    }
}

/// The preview's own control: which of the three sidebars is showing, and in which theme.
struct ShellPreviewSwitcher: View {
    @Environment(\.theme) private var theme
    let concept: ShellConcept
    let choose: (ShellConcept) -> Void
    let chooseTheme: (ThemeID) -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            ShellSegments(options: ShellConcept.allCases.map { (value: $0, title: $0.rawValue, help: "Sidebar \($0.rawValue): \($0.name)") },
                          selection: concept, choose: choose)
                .background {
                    // ⌥⌘1, ⌥⌘2 and ⌥⌘3 choose the sidebar.
                    ForEach(Array(ShellConcept.allCases.enumerated()), id: \.element) { index, option in
                        Button(option.name) { choose(option) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                    }
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sidebar concept")
                .accessibilityIdentifier("shell-concept")
            ShellSegments(options: ThemeID.allCases.map { (value: $0, title: Theme.named($0).name, help: "\(Theme.named($0).name) theme") },
                          selection: theme.id, choose: chooseTheme)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Theme")
                .accessibilityIdentifier("shell-theme")
        }
    }
}

/// The page for the selected place: an existing preview page, the Needs you inbox, or a
/// placeholder for a page a later increment brings.
struct ShellPreviewCanvas: View {
    let store: PreviewStore
    let state: ShellPreviewState
    let navigation: CommanderNavigation
    let act: (CommanderNavigationAction) -> Void

    private func openRuns() { act(.select("runs")) }

    /// The Teams pages. Sharing a host and asking for access are the network pages' own flows.
    private var teamsPages: TeamsPages {
        state.teams.shareHost = { _, server in
            state.network.pages(go: { _ in }).actions.share(server, nil, nil)
            act(.select(NetworkPlace.shared))
        }
        state.teams.requestAccess = { _, _ in act(.select(NetworkPlace.directory)) }
        return state.teams.pages(place: navigation.selection, go: { act(.select($0)) })
    }

    var body: some View {
        switch navigation.selection {
        case "needs-you":
            NeedsYouPage(inbox: state.inbox(answered: Set(store.answers.keys)),
                         decide: { id, decision in
                             state.decide(id, decision)
                             // A sample question is also the Attention queue's, so both agree.
                             if case .replied(let text) = decision, DesignFixture.requests.contains(where: { $0.id == id }) {
                                 store.resolve(id, answer: text)
                             }
                         },
                         open: { id in
                             if state.inbox.items.first(where: { $0.id == id })?.kind.isLocal == true { act(.select("attention")) }
                         })
        case "runs", "project.relay":
            ShellWallPage(run: DesignFixture.content(for: store).selected, live: state.wall,
                          takeBack: { control in state.wall.controls.removeAll { $0.id == control.id } },
                          go: { place in act(.select(place)) })
        case "all-agents", "project.beacon":
            AllAgentsPage(agents: PreviewSample.agents(tick: store.liveTick),
                          project: navigation.selection == "project.beacon" ? "Beacon" : "All projects",
                          open: { _ in openRuns() }, startRun: openRuns, saveView: {})
                .id(navigation.selection)
        case "attention":
            AttentionQueuePage(
                pending: Array(DesignFixture.pending(for: store).reversed()),
                resolved: store.resolvedLog + PreviewSample.resolvedToday,
                sending: [],
                presentation: store.presentation,
                worker: { request in DesignFixture.worker(for: request, store: store) },
                reply: { requestID, answer in
                    store.resolve(requestID, answer: answer)
                    return true
                },
                takeControl: { _ in openRuns() },
                openWorker: { _ in openRuns() },
                choosePresentation: { mode in store.presentation = mode })
        case "history":
            HistoryPage(kicker: "RELAY / HISTORY",
                        subtitle: "15:02 · Search the Relay project’s recorded output, including conversations owned by another coordinator.",
                        query: "timeout budget", project: "Relay", matches: PreviewSample.transcriptMatches,
                        sharingNote: "Project history shared across its coordinators.", retention: "Retention · 30 days",
                        openWorker: { _ in openRuns() }, openRun: { _ in openRuns() })
        case "hosts":
            HostsPage(subtitle: "Local and SSH execution environments for Relay.", hosts: PreviewSample.hosts,
                      selection: "build-01", capabilities: PreviewSample.hostCapabilities, configPath: "~/.ssh/config",
                      policyTitle: "Run disconnect policy",
                      policyDetail: "Retry policy can finish current assignments on build-01. Further delegation waits for reconnect.",
                      policyStatus: "Hold delegation", enroll: {}, recover: { _ in })
        case "settings":
            PreferencesPage(projectName: "Relay", retention: "30 days",
                            retentionOptions: ["7 days", "30 days", "90 days", "1 year"],
                            showsSystemAppearance: false, presentation: store.presentation,
                            choosePresentation: { mode in store.presentation = mode },
                            chooseTheme: { id in ThemeChoice.select(id) })
        case let place where NetworkPlace.hasPage(place):
            NetworkPageView(place: place, pages: state.network.pages(go: { act(.select($0)) }))
        case let place where TeamsPlace.hasPage(place):
            TeamsPageView(place: place, pages: teamsPages)
        default:
            ShellPlaceholderPage(crumbs: navigation.crumbs, title: navigation.selectedPlace?.title ?? "",
                                 note: ShellSample.note(for: navigation.selection))
        }
    }
}

/// A place whose page a later increment brings: the page header and one note.
struct ShellPlaceholderPage: View {
    let crumbs: [String]
    let title: String
    let note: String
    /// The one way to reach this place's content today, when there is one.
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: crumbs.map { $0.uppercased() }.joined(separator: " / "), title: title) {
                if let actionTitle {
                    Button(actionTitle, action: action).buttonStyle(ThemeButtonStyle())
                        .accessibilityIdentifier("shell-placeholder-action")
                }
            }
        } content: {
            ShellLoadNote(text: note)
        }
        .accessibilityIdentifier("shell-placeholder")
    }
}

/// The coordinator wall inside the shell, read-only: the run header, the coordinator and its
/// workers, built from the cockpit's own organisms and the preview's sample run. The consoles are
/// exactly the cockpit's; nothing can be typed, zoomed or stopped here.
struct ShellWallPage: View {
    let run: RunContent?
    /// What the network adds to the wall. Empty leaves the wall as it is.
    var live = WallLiveWork()
    var takeBack: (WallLiveWork.Control) -> Void = { _ in }
    /// Goes to a place of the shell.
    var go: (String) -> Void = { _ in }
    @State private var fraction = Metric.coordinatorFraction
    @State private var collapsed = Set<String>()
    @State private var showingDetails = false

    var body: some View {
        if let run {
            CoordinatorSplit(fraction: $fraction, showsFloating: false) {
                RunHeader(run: run, canStop: false, showingDetails: $showingDetails, showRuns: {}, stop: {})
            } leading: {
                VStack(spacing: 0) {
                    SectionBar { WallHeading(symbol: "terminal", title: "Coordinator") } trailing: { EmptyView() }
                    if let coordinator = run.coordinator {
                        CoordinatorConsole(coordinator: coordinator, assignment: run.task, startedAt: run.startedAt,
                                           awaiting: run.awaiting) { _ in }
                    }
                }
            } trailing: {
                VStack(spacing: 0) {
                    let count = run.wall.workers.count
                    SectionBar {
                        WallHeading(symbol: "square.grid.2x2", title: "Worker wall", count: count > 0 ? count : nil)
                    } trailing: { EmptyView() }
                    WorkerWall(layout: run.wall, collapsed: collapsed,
                               toggleGroup: { id in
                                   if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                               }) { worker in
                        VStack(spacing: 0) {
                            WorkerTile(worker: worker, variant: .wall).frame(maxWidth: .infinity, maxHeight: .infinity)
                            WallControlDock(controls: live.controls(forWorker: worker.id), suggestions: live.suggestions(forWorker: worker.id),
                                            now: live.now, isBusy: live.isBusy, takeBack: takeBack,
                                            openShared: { go(NetworkPlace.shared) }, review: { _ in go(NetworkPlace.approvals) })
                        }
                    }
                    // Remote workers aren't zoomed in the preview: a tile goes to Hand-offs.
                    WallRemoteBand(workers: live.remoteWorkers, work: live.work, now: live.now,
                                   zoom: { _ in go(NetworkPlace.handoffs) },
                                   openHandoffs: { go(NetworkPlace.handoffs) },
                                   openWork: { item in go(WallLiveWork.place(for: item.kind)) })
                        .padding(.top, live.remoteWorkers.isEmpty && live.work.isEmpty ? 0 : Metric.wallRowGap)
                }
            } floating: {
                EmptyView()
            }
            .foregroundStyle(Palette.foreground)
        } else {
            ShellPlaceholderPage(crumbs: ["Workspace", "Runs"], title: "Runs", note: "No run is open.")
        }
    }
}
