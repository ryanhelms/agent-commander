import SwiftUI

// ATOMIC LEVEL: Pages (attention queue and workspace).
// Each page fills a template with organisms from the values it is given and keeps only its own
// presentation state (selection, filters, drafts). Domain changes leave through closures.
//
//   AttentionQueuePage  header | RequestList | RequestInspector        (collection with inspector)
//   AllAgentsPage       WorkspacePage: FilterChip bar + AgentConsoleCard grid or DataTable
//   ProjectPage         WorkspacePage: CoordinatorSummary + CoordinatorRow (running, then earlier
//                       runs) + DataTable of checkouts where the page has them
//   SmartViewPage       WorkspacePage: CollectionInspector(previews + DataTable | RuleInspector)
//   LinkCheckoutPage    WorkspacePage: CheckoutComparison

// MARK: - Attention queue

struct AttentionQueuePage: View {
    let pending: [RequestPresentation]
    let resolved: [ResolvedRequest]
    let sending: Set<String>
    let presentation: AttentionPresentation
    /// The requesting worker, when its run is loaded.
    let worker: (RequestPresentation) -> WorkerPresentation?
    let reply: @MainActor (_ requestID: String, _ answer: String) async -> Bool
    var takeControl: ((RequestPresentation) -> Void)? = nil
    let openWorker: (RequestPresentation) -> Void
    let choosePresentation: (AttentionPresentation) -> Void

    @State private var selection: String?
    @State private var drafts: [String: String] = [:]
    @State private var project = "All projects"
    @FocusState private var replyFocus: String?

    private var projects: [String] {
        var seen = Set<String>()
        return ["All projects"] + pending.map(\.project).filter { seen.insert($0).inserted }
    }

    private var visible: [RequestPresentation] {
        pending.filter { project == "All projects" || $0.project == project }
    }

    private var selected: RequestPresentation? {
        visible.first { $0.id == selection } ?? visible.first
    }

    private var replyContext: ReplyContext {
        ReplyContext(
            draft: { id in Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 }) },
            focus: $replyFocus,
            sending: sending,
            isOnline: true,
            send: { request in send(request) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Requests").font(TypeRole.sectionTitle).foregroundStyle(Palette.foreground)
                            Spacer(minLength: 8)
                            FilterChip(name: "Project", symbol: "line.3.horizontal.decrease", options: projects,
                                       selection: $project)
                        }
                        if visible.isEmpty {
                            Text(pending.isEmpty ? "No request is waiting." : "No request in this project.")
                                .font(.system(size: 13)).foregroundStyle(.inkSecondary).padding(.vertical, 8)
                        }
                        RequestList(requests: visible, resolved: resolved, selection: selected?.id) { request in
                            selection = request.id
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 20)
                }
                .frame(width: 440)
                Hairline(vertical: true)
                detail
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attention queue")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Breadcrumb(items: ["Workspace", "All runs"], symbol: "square.stack.3d.up")
                HStack(spacing: 14) {
                    Text("Needs attention").font(TypeRole.pageTitle).tracking(-1.1).foregroundStyle(Palette.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Text(pending.isEmpty ? "All clear" : "\(pending.count) pending")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(pending.isEmpty ? Palette.working : Palette.attention)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(pending.isEmpty ? Palette.workingFill : Palette.attentionFill,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(pending.isEmpty ? Palette.workingEdge : Palette.attentionSoftEdge)
                        }
                }
            }
            Spacer(minLength: 12)
            Menu {
                ForEach(AttentionPresentation.allCases) { mode in
                    Button { choosePresentation(mode) } label: {
                        if mode == presentation { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                    }
                }
            } label: {
                Label("Presentation", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 33)
            .overlay { Capsule().strokeBorder(Palette.controlEdge).allowsHitTesting(false) }
            .accessibilityLabel("Attention presentation: \(presentation.title)")
        }
        .padding(.horizontal, Metric.runHeaderInset)
        .frame(maxWidth: .infinity, minHeight: Metric.runHeaderHeight, alignment: .leading)
    }

    @ViewBuilder private var detail: some View {
        if let request = selected {
            let takeInput: (() -> Void)? = takeControl.map { acquire in { acquire(request) } }
            RequestInspector(request: request, worker: worker(request), reply: replyContext,
                             takeControl: request.workerIsCoordinator ? nil : takeInput,
                             openWorker: { openWorker(request) })
                .padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(request.id)
        } else {
            ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle",
                                   description: Text("New requests from any run will appear here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func send(_ request: RequestPresentation) {
        let text = drafts[request.id] ?? ""
        guard !request.isWorkerDisconnected,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await reply(request.id, text) {
                drafts[request.id] = nil
                if replyFocus == request.id { replyFocus = nil }
                selection = nil
            }
        }
    }
}

// MARK: - All agents

struct AllAgentsPage: View {
    let agents: [AgentConsole]
    let open: (AgentConsole) -> Void
    let startRun: () -> Void
    let saveView: () -> Void

    @State private var project: String
    @State private var host = "All hosts"
    @State private var state = "All states"
    @State private var role = "All roles"
    @State private var run = "All runs"
    @State private var client = "All clients"
    @State private var showsList = false
    @Environment(\.theme) private var theme

    init(agents: [AgentConsole], project: String = "All projects",
         open: @escaping (AgentConsole) -> Void, startRun: @escaping () -> Void, saveView: @escaping () -> Void) {
        self.agents = agents
        self.open = open
        self.startRun = startRun
        self.saveView = saveView
        _project = State(initialValue: project)
    }

    private func options(_ all: String, _ values: [String]) -> [String] {
        var seen = Set<String>()
        return [all] + values.filter { seen.insert($0).inserted }
    }

    private var visible: [AgentConsole] {
        agents.filter { agent in
            (project == "All projects" || agent.project == project)
                && (host == "All hosts" || agent.host == host)
                && (state == "All states" || agent.state == state)
                && (role == "All roles" || agent.role == role)
                && (run == "All runs" || agent.runID == run)
                && (client == "All clients" || agent.client.displayName == client)
        }
    }

    /// How many of the Run, Client and Role clauses are narrowing the view.
    private var moreCount: Int {
        [run != "All runs", client != "All clients", role != "All roles"].filter { $0 }.count
    }

    private var isFiltered: Bool {
        project != "All projects" || host != "All hosts" || state != "All states" || moreCount > 0
    }

    /// The fourth clause groups the less common attributes: run, client and role.
    private var moreFilters: some View {
        Menu {
            clause("Run", options("All runs", agents.map(\.runID)), $run)
            clause("Client", options("All clients", agents.map(\.client.displayName)), $client)
            clause("Role", options("All roles", agents.map(\.role)), $role)
        } label: {
            Label(moreCount == 0 ? "Run, client & more" : "Run, client & more · \(moreCount)",
                  systemImage: "slider.horizontal.3")
        }
        .filterChipFrame()
        .accessibilityLabel("Run, client and more: \(moreCount == 0 ? "no filter" : "\(moreCount) active")")
        .accessibilityIdentifier("all-agents-more-filters")
    }

    private func clause(_ name: String, _ values: [String], _ selection: Binding<String>) -> some View {
        Section(name) {
            ForEach(values, id: \.self) { value in
                Button { selection.wrappedValue = value } label: {
                    if value == selection.wrappedValue { Label(value, systemImage: "checkmark") } else { Text(value) }
                }
            }
        }
    }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "Workspace", title: "All agents",
                       subtitle: "Live consoles across projects and enrolled hosts.") {
                Button(action: startRun) { Label("Start run", systemImage: "plus") }
                    .buttonStyle(ThemeButtonStyle(prominent: true))
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                ThemeRule()
                filters
                ThemeRule()
            }
            SectionHeading(title: "Live consoles") {
                MetaText(text: "\(visible.count) visible  ·  Sorted by recent activity")
            }
            if visible.isEmpty {
                ContentUnavailableView("No agents match", systemImage: "line.3.horizontal.decrease",
                                       description: Text("Change or clear a filter to see more consoles."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if showsList {
                list
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330, maximum: 620), spacing: 14)], spacing: 14) {
                    ForEach(visible) { agent in
                        AgentConsoleCard(agent: agent) { open(agent) }.frame(height: 275)
                    }
                }
            }
            HStack {
                Label("Watching live output", systemImage: "eye")
                Spacer(minLength: 12)
                Text("Open a tile to focus its console")
            }
            .themeType(theme.pageType.meta).foregroundStyle(.theme(\.color.secondary))
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            FilterChip(name: "Project", symbol: "folder", options: options("All projects", agents.map(\.project)),
                       selection: $project)
            FilterChip(name: "Host", symbol: "server.rack", options: options("All hosts", agents.map(\.host)),
                       selection: $host)
            FilterChip(name: "State", symbol: "waveform.path.ecg", options: options("All states", agents.map(\.state)),
                       selection: $state)
            moreFilters
            if isFiltered {
                Button("Clear") {
                    project = "All projects"; host = "All hosts"; state = "All states"; role = "All roles"
                    run = "All runs"; client = "All clients"
                }
                .buttonStyle(.plain).themeType(theme.pageType.meta).foregroundStyle(.theme(\.color.focus))
                .accessibilityLabel("Clear filters")
            }
            Spacer(minLength: Space.m)
            Button(action: saveView) { Label("Save view", systemImage: "line.3.horizontal.decrease") }
                .buttonStyle(ThemeButtonStyle(compact: true))
            HStack(spacing: 2) {
                layoutButton("square.grid.2x2", "Grid layout", active: !showsList) { showsList = false }
                layoutButton("list.bullet", "List layout", active: showsList) { showsList = true }
            }
            .padding(.horizontal, 5)
            .frame(height: theme.space.controlHeight)
            .overlay { theme.controlShape.strokeBorder(.theme(\.surface.controlEdge)) }
        }
    }

    private func layoutButton(_ symbol: String, _ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        SymbolButton(symbol: symbol, label: label, action: action)
            .foregroundStyle(.theme(active ? \.color.focus : \.color.secondary))
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var list: some View {
        DataTable(headers: ["Agent", "Project / run", "Host", "Worktree", "State"],
                  weights: [28, 22, 16, 18, 16], rows: visible) { agent, column in
            switch column {
            case 0:
                Button { open(agent) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.title).themeType(theme.type.title).foregroundStyle(.theme(\.color.foreground))
                        Text("\(agent.role) · \(agent.client.displayName)").themeType(theme.pageType.meta).foregroundStyle(.theme(\.color.secondary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(agent.title)")
            case 1:
                Text("\(agent.project) · \(agent.runID)").themeType(theme.type.sub).foregroundStyle(.theme(\.surface.softInk))
            case 2:
                Text(agent.host).themeType(theme.type.sub).foregroundStyle(.theme(\.surface.softInk))
            case 3:
                ValueTag(text: agent.branch)
            default:
                ThemeStatus(text: agent.state, tone: agent.tone)
            }
        }
    }
}

// MARK: - Project overview

struct CheckoutLink: Identifiable, Equatable {
    let id: String
    let host: String
    let worktree: String
    let identity: String

    var path: String { id }
}

/// A project: its folder, the coordinators running in it and the runs that ended.
///
/// The live window draws it from the service's project catalog and runs. It then has no linked
/// checkouts and no identity, which are the concept's (`linkCheckout` and `identity` are nil), and
/// the page ends after the runs.
struct ProjectPage: View {
    let name: String
    let path: String
    var identity: String? = nil
    /// The runs still going, newest first. The first is drawn in full.
    let runs: [RunContent]
    /// The runs that ended, newest first, one row each.
    var history: [RunContent] = []
    var checkouts: [CheckoutLink] = []
    let openRun: (RunContent) -> Void
    let openWorker: (RunContent, WorkerPresentation) -> Void
    let startCoordinator: () -> Void
    /// False where no run can start now: the service is offline.
    var canStart = true
    var linkCheckout: (() -> Void)? = nil

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "Project", title: name, subtitle: path) {
                Button(action: startCoordinator) { Label("Start coordinator", systemImage: "plus") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(!canStart)
                    .help(canStart ? "Start a coordinator run in \(path)" : "The service is offline. Reconnect to start a run.")
            }
        } content: {
            // A project whose runs all ended opens on "Earlier runs": the
            // running band is left out rather than drawn empty.
            if !runs.isEmpty || history.isEmpty {
                SectionHeading(title: "Running coordinators") {
                    MetaText(text: Self.count(runs.count))
                }
                if runs.isEmpty {
                    ContentUnavailableView("No runs in this project yet",
                                           systemImage: "square.stack.3d.up",
                                           description: Text("Start a coordinator to plan and delegate work in this project."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    VStack(spacing: 0) {
                        if let lead = runs.first {
                            CoordinatorSummary(run: lead, open: { openRun(lead) }, openWorker: { openWorker(lead, $0) })
                        }
                        ForEach(runs.dropFirst()) { run in
                            Hairline()
                            CoordinatorRow(run: run) { openRun(run) }
                        }
                    }
                    .panelSurface()
                }
            }
            if !history.isEmpty {
                SectionHeading(title: "Earlier runs") {
                    MetaText(text: Self.count(history.count))
                }
                VStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Hairline() }
                        CoordinatorRow(run: run) { openRun(run) }
                    }
                }
                .panelSurface()
            }
            if let linkCheckout {
                SectionHeading(title: "Linked checkouts") {
                    Button(action: linkCheckout) { Label("Link checkout", systemImage: "link") }
                        .buttonStyle(CapsuleButtonStyle(height: 33))
                }
                DataTable(headers: ["Checkout", "Host", "Worktree", "Identity"], weights: [35, 19, 23, 23],
                          rows: checkouts) { checkout, column in
                    switch column {
                    case 0:
                        Text(checkout.path).font(.system(size: 13.5)).foregroundStyle(Palette.foreground)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    case 1:
                        Text(checkout.host).font(.system(size: 13.5)).foregroundStyle(Palette.foreground)
                    case 2:
                        ValueTag(text: checkout.worktree)
                    default:
                        StatusLabel(text: checkout.identity, tone: .working, symbol: "checkmark.circle.fill", size: 12)
                    }
                }
            }
            if let identity {
                HStack {
                    Label("Project identity", systemImage: "folder")
                    Spacer(minLength: 12)
                    Text(identity).textSelection(.enabled)
                }
                .font(.system(size: 12)).foregroundStyle(.inkSecondary)
            }
        }
    }

    private static func count(_ runs: Int) -> String { runs == 1 ? "1 run" : "\(runs) runs" }
}

// MARK: - Smart view

struct SmartViewPage: View {
    let agents: [AgentConsole]
    let open: (AgentConsole) -> Void

    @State private var name: String
    @State private var rules: [ViewRule]
    @State private var savedRules: [ViewRule]
    @State private var namingCopy = false
    @State private var copyName = ""

    init(name: String, rules: [ViewRule], agents: [AgentConsole], open: @escaping (AgentConsole) -> Void) {
        self.agents = agents
        self.open = open
        _name = State(initialValue: name)
        _rules = State(initialValue: rules)
        _savedRules = State(initialValue: rules)
    }

    private func value(_ id: String) -> String { rules.first { $0.id == id }?.value ?? "" }

    private var matches: [AgentConsole] {
        let host = value("host"), lifecycle = value("lifecycle"), project = value("project")
        let filtered = agents.filter { agent in
            (host == "Any host" || (host == "SSH host") == agent.isRemote)
                && (lifecycle != "Needs attention" || agent.tone == .attention)
                && (lifecycle != "Working" || agent.state == "Working")
                && (project == "Any project" || agent.project == project)
        }
        switch (value("sort"), value("group")) {
        case ("Name", _): return filtered.sorted { $0.title < $1.title }
        case (_, "Host"): return filtered.sorted { $0.host < $1.host }
        default: return filtered
        }
    }

    var body: some View {
        let found = matches
        let pinned = Array(found.prefix(2))
        let rest = Array(found.dropFirst(2))
        WorkspacePage {
            PageHeader(kicker: "Smart views", title: name,
                       subtitle: "Live consoles that match your saved rules.") {
                Button { rules = savedRules } label: { Label("Revert rules", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(rules == savedRules)
                Button {
                    copyName = name + " copy"
                    namingCopy = true
                } label: { Label("Save as…", systemImage: "plus") }
                    .buttonStyle(CapsuleButtonStyle())
            }
        } content: {
            CollectionInspector(spacing: 22, inspectorWidth: 330) {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "Console previews") {
                        MetaText(text: pinned.isEmpty ? "No match" : "\(pinned.count) pinned")
                    }
                    if pinned.isEmpty {
                        ContentUnavailableView("No agent matches these rules", systemImage: "line.3.horizontal.decrease",
                                               description: Text("Loosen a rule to widen the view."))
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        HStack(spacing: 14) {
                            ForEach(pinned) { agent in
                                AgentConsoleCard(agent: agent) { open(agent) }.frame(height: 262)
                            }
                        }
                    }
                    if !rest.isEmpty {
                        SectionHeading(title: "Matching agents") {
                            MetaText(text: rest.count == 1 ? "1 more match" : "\(rest.count) more matches")
                        }
                        DataTable(headers: ["Agent", "Host", "Worktree", "Task state"], weights: [32, 20, 26, 22],
                                  rows: rest) { agent, column in
                            switch column {
                            case 0:
                                Button { open(agent) } label: {
                                    Label(agent.title, systemImage: "terminal")
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(agent.title)")
                            case 1:
                                Text(agent.host).font(.system(size: 13)).foregroundStyle(Color(hex: 0xD3D6E0))
                            case 2:
                                ValueTag(text: agent.branch)
                            default:
                                StatusLabel(text: agent.state, tone: agent.tone, size: 12)
                            }
                        }
                    }
                }
            } inspector: {
                RuleInspector(rules: $rules, footnote: rules == savedRules ? "Visible to this workspace" : "Unsaved rule changes")
            }
        }
        .alert("Save smart view", isPresented: $namingCopy) {
            TextField("Name", text: $copyName)
            Button("Save") {
                let trimmed = copyName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { name = trimmed }
                savedRules = rules
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current rules are saved under this name.")
        }
    }
}

// MARK: - Link a checkout

struct LinkCheckoutPage: View {
    let projectName: String
    let checks: [IdentityCheck]
    let noticeTitle: String
    let noticeDetail: String
    /// Reports the decision so the owner can record it.
    let decided: (CheckoutComparison.Decision) -> Void

    @State private var decision = CheckoutComparison.Decision.undecided

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "\(projectName) / Project settings", title: "Link a checkout",
                       subtitle: "Review an SSH checkout before adding it to the project.") {
                EmptyView()
            }
        } content: {
            CheckoutComparison(projectName: projectName, checks: checks, noticeTitle: noticeTitle,
                               noticeDetail: noticeDetail, decision: $decision)
                .frame(maxWidth: 1040, alignment: .leading)
        }
        .onChange(of: decision) { _, value in decided(value) }
    }
}
