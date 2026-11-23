import AppKit
import SwiftUI

// ATOMIC LEVEL: Pages.
//
//   CockpitScreen  fills the templates with organisms from presentation values. It is the one
//                  composition used by both the live app and the design preview.
//                    CockpitShell
//                      navigation  NavigationRail (+ RunChooser popover)
//                      banners     NoticeBanner
//                      canvas      CoordinatorSplit
//                                    header    RunHeader
//                                    leading   SectionBar + CoordinatorConsole
//                                    trailing  SectionBar + WorkerWall of WorkerTile, or one focused WorkerTile
//                                    floating  AttentionStack
//                                  or TaskSheet via NewRunView
//   CockpitView    the live page: binds CockpitModel to CockpitScreen and owns the subscription.

/// Presentation state keyed by stable IDs. It survives data refreshes and belongs to the feature
/// layer, never to a component: zoom, collapsed groups, the split, and one draft per request.
@Observable @MainActor
final class CockpitPresentationState {
    var zoomedWorkerID: String?
    var zoomAfterSelection: String?
    var collapsedGroups = Set<String>()
    var drafts: [String: String] = [:]
    var activeRequestID: String?
    var dismissedRequests = Set<String>()
    var returnFocusWorkerID: String?
    var splitFraction = Metric.coordinatorFraction
    var sidebarExpanded = false
    var composingRun = false
    var newRunDraft = NewRunDraft()
    var showingRunChooser = false
    var showingRunDetails = false
    var showingStopConfirmation = false
    /// Focus to apply once after the first layout. Used by design fixtures.
    var initialPaneFocus: String?
    var initialReplyFocus: String?
}

/// Extra navigation rows that exist only in design fixtures, to compare the rail and sidebar
/// arrangement with the concepts. Production never supplies this.
struct FixtureNavigation {
    var workspace: [NavigationItem] = []
    var smartViews: [NavigationItem] = []
    var footer: [NavigationItem] = []
}

struct CockpitScreen: View {
    let content: CockpitContent
    @Bindable var ui: CockpitPresentationState
    let actions: CockpitActions
    var fixtureNavigation: FixtureNavigation? = nil
    /// What the run setup form may offer. The live app uses the local default.
    var runSetup = RunSetupCapabilities()

    @FocusState private var paneFocus: String?
    @FocusState private var replyFocus: String?

    // MARK: Derived values

    private var isOnline: Bool { content.connection == .online }
    private var run: RunContent? { content.selected }

    private var zoomed: WorkerPresentation? {
        guard let id = ui.zoomedWorkerID else { return nil }
        return run?.wall.workers.first { $0.id == id }
    }

    /// A request answered inline in the focused worker is left out of the PiP, so each request has
    /// exactly one reply field on screen.
    private var inlineRequestID: String? { zoomed?.request?.id }

    private var stack: [RequestPresentation] {
        let inline = inlineRequestID
        return content.pending.filter { !ui.dismissedRequests.contains($0.id) && $0.id != inline }
    }

    private var current: RequestPresentation? {
        let queue = stack
        return queue.first { $0.id == ui.activeRequestID } ?? queue.first
    }

    private var showsStack: Bool { current != nil && !ui.composingRun && run != nil }

    private var replyContext: ReplyContext {
        ReplyContext(
            draft: { id in Binding(get: { ui.drafts[id] ?? "" }, set: { ui.drafts[id] = $0 }) },
            focus: $replyFocus,
            sending: content.sending,
            isOnline: isOnline,
            send: { request in send(request) })
    }

    // MARK: Body

    var body: some View {
        CockpitShell {
            navigation
        } banners: {
            banners
        } canvas: {
            canvas
        }
        .background { shortcuts }
        .toolbar { toolbarContent }
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .alert("Stop this run?", isPresented: $ui.showingStopConfirmation, presenting: run) { run in
            Button("Stop run", role: .destructive) { actions.stopRun(run.id) }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("Stop delegation and cancel the managed agents in “\(run.title)”.")
        }
        .onChange(of: run?.id) { _, _ in runChanged() }
        .onChange(of: paneFocus) { _, focus in
            if let focus { ui.returnFocusWorkerID = focus }
        }
        .onChange(of: content.pending.map(\.id)) { old, new in pendingChanged(from: old, to: new) }
        .onAppear { seedFocus() }
    }

    // MARK: Navigation

    private var navigation: some View {
        NavigationRail(groups: navigationGroups, footer: navigationFooter, expanded: ui.sidebarExpanded)
            .popover(isPresented: $ui.showingRunChooser, arrowEdge: .trailing) {
                RunChooser(runs: content.runs, selected: run?.id) { id in
                    ui.showingRunChooser = false
                    ui.composingRun = false
                    actions.selectRun(id)
                }
            }
    }

    private var navigationGroups: [NavigationGroup] {
        var workspace = [
            NavigationItem(id: "runs", title: "Runs", mark: .symbol("square.grid.2x2"),
                           isEnabled: !content.runs.isEmpty,
                           action: { ui.showingRunChooser.toggle() }),
            NavigationItem(id: "attention", title: "Attention", mark: .symbol("bell"),
                           badge: content.pending.count, isEnabled: !content.pending.isEmpty,
                           shortcut: KeyboardShortcut("a", modifiers: [.command, .shift]),
                           action: { nextRequest() })
        ]
        workspace += fixtureNavigation?.workspace ?? []

        var seen = Set<String>()
        var projects: [NavigationItem] = []
        for summary in content.runs where seen.insert(summary.path).inserted {
            let path = summary.path
            let latest = content.runs.last { $0.path == path }?.id ?? summary.id
            projects.append(NavigationItem(
                id: "project-\(path)", title: summary.project,
                mark: .letter(String(summary.project.prefix(1)).uppercased()),
                isActive: run?.path == path && !ui.composingRun,
                action: {
                    ui.composingRun = false
                    actions.selectRun(latest)
                }))
        }

        var groups = [NavigationGroup(id: "workspace", title: "Workspace", items: workspace)]
        if !projects.isEmpty { groups.append(NavigationGroup(id: "projects", title: "Projects", items: projects)) }
        if let smart = fixtureNavigation?.smartViews, !smart.isEmpty {
            groups.append(NavigationGroup(id: "smart", title: "Smart views", items: smart))
        }
        return groups
    }

    private var navigationFooter: [NavigationItem] {
        [NavigationItem(id: "new-run", title: "New run", mark: .symbol("plus"),
                        isActive: ui.composingRun, isEnabled: isOnline,
                        shortcut: KeyboardShortcut("n", modifiers: .command),
                        action: { startComposing() })]
            + (fixtureNavigation?.footer ?? [])
    }

    @ViewBuilder private var banners: some View {
        if let notice = content.notice {
            NoticeBanner(text: notice, symbol: "exclamationmark.triangle", tone: .failure,
                         actionTitle: "Dismiss") { actions.dismissNotice() }
        }
        if case .offline(let reason) = content.connection {
            NoticeBanner(text: reason, symbol: "bolt.slash", tone: .attention,
                         actionTitle: "Reconnect") { actions.reconnect() }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { ui.sidebarExpanded.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(ui.sidebarExpanded ? "Collapse navigation" : "Expand navigation")
                .accessibilityLabel(ui.sidebarExpanded ? "Collapse navigation" : "Expand navigation")
        }
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                Text("Agent Commander").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                if !crumbs.isEmpty {
                    Hairline(vertical: true).frame(height: 18)
                    Breadcrumb(items: crumbs)
                }
            }
            .padding(.horizontal, 6)
        }
        // Flexible space keeps the breadcrumb leading and pins the service indicator to the trailing
        // edge. Without it the native toolbar packs the indicator directly after the breadcrumb.
        ToolbarSpacer(.flexible, placement: .automatic)
        // Workspace search is offered only where a search action exists.
        if let search = actions.searchWorkspace {
            ToolbarItem(placement: .primaryAction) {
                Button { search() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11))
                        Text("Search workspace").font(.system(size: 12))
                        KeyCap(keys: "⌘K")
                    }
                    .foregroundStyle(Color(hex: 0xE0E1EA))
                    .padding(.horizontal, 6)
                }
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Search workspace")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            ConnectionIndicator(connection: content.connection)
        }
    }

    private var crumbs: [String] {
        if ui.composingRun { return (run.map { [$0.project] } ?? []) + ["New run"] }
        guard let run else { return [] }
        return [run.project, run.title] + (zoomed.map { [$0.name] } ?? [])
    }

    /// Keyboard paths that must work whichever region is showing. Native defaults from the design
    /// system: ⌘1 coordinator, ⌘] zoom, ⌘[ return. ⌘N and ⇧⌘A live on their navigation rows.
    private var shortcuts: some View {
        Group {
            Button("Focus coordinator") { focusCoordinator() }.keyboardShortcut("1", modifiers: .command)
            Button("Zoom worker") { zoomFocused() }.keyboardShortcut("]", modifiers: .command)
            Button("Return to wall") { returnToWall() }.keyboardShortcut("[", modifiers: .command)
                .disabled(ui.zoomedWorkerID == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Canvas

    @ViewBuilder private var canvas: some View {
        if ui.composingRun {
            NewRunView(connection: content.connection, draft: ui.newRunDraft, projectName: run?.project,
                       capabilities: runSetup,
                       create: { path, task, title, key in
                           try await actions.createRun(path, task, title, key)
                           ui.composingRun = false
                       },
                       cancel: { ui.composingRun = false })
        } else if let run = run {
            CoordinatorSplit(fraction: $ui.splitFraction, showsFloating: showsStack) {
                RunHeader(run: run, canStop: run.canStop && isOnline && !content.isStopping,
                          showingDetails: $ui.showingRunDetails,
                          showRuns: { ui.showingRunChooser = true },
                          stop: { ui.showingStopConfirmation = true })
            } leading: {
                coordinatorPane(run)
            } trailing: {
                workerPane(run)
            } floating: {
                attentionStack
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 32)).foregroundStyle(Palette.working)
            Text("Open a project").font(TypeRole.pageTitle).tracking(-1.1)
            Text("Choose a directory and give your coordinator a task.").font(TypeRole.body).foregroundStyle(.inkSecondary)
            Button { startComposing() } label: { Label("Start a run…", systemImage: "play") }
                .buttonStyle(CapsuleButtonStyle(prominent: true))
                .disabled(!isOnline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coordinatorPane(_ run: RunContent) -> some View {
        VStack(spacing: 0) {
            SectionBar {
                SectionTitle(symbol: "terminal", title: "Coordinator")
            } trailing: {
                EmptyView()
            }
            if let coordinator = run.coordinator {
                let sendMessage: ((String) -> Void)? = actions.messageCoordinator.map { send in { text in send(run.id, text) } }
                CoordinatorConsole(coordinator: coordinator, assignment: run.task, startedAt: run.startedAt,
                                   awaiting: run.awaiting, isKeyFocused: paneFocus == coordinator.id,
                                   sendMessage: sendMessage) { request in
                    open(request)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($paneFocus, equals: coordinator.id)
                .simultaneousGesture(TapGesture().onEnded { ui.returnFocusWorkerID = coordinator.id })
            } else {
                ContentUnavailableView("Coordinator unavailable", systemImage: "terminal",
                                       description: Text("The service has not reported a coordinator for this run."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func workerPane(_ run: RunContent) -> some View {
        if let zoomed = zoomed {
            VStack(spacing: 0) {
                SectionBar {
                    HStack(spacing: 8) {
                        Button { returnToWall() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.inkSecondary)
                                Text("Worker wall").font(TypeRole.sectionTitle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Return to worker wall")
                        Text("/").foregroundStyle(.inkSecondary).opacity(0.6)
                        Text(zoomed.name).font(.system(size: 14)).foregroundStyle(.inkSecondary).lineLimit(1)
                    }
                } trailing: {
                    KeyHint(keys: "⌘[", title: "Return to wall") { returnToWall() }
                }
                tile(zoomed, variant: .focused)
            }
        } else {
            let count = run.wall.workers.count
            VStack(spacing: 0) {
                SectionBar {
                    SectionTitle(symbol: "square.grid.2x2", title: "Worker wall", count: count > 0 ? count : nil)
                } trailing: {
                    // Offered only where the wall can actually be regrouped.
                    if let chooseGrouping = actions.chooseWallGrouping {
                        Button { chooseGrouping() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.stack.3d.up").font(.system(size: 11))
                                Text("Group by parent")
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                                Hairline(vertical: true).frame(height: 17).padding(.horizontal, 3)
                                Image(systemName: "square.grid.2x2").font(.system(size: 12))
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.inkSecondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Wall grouping: by parent")
                    }
                }
                WorkerWall(layout: run.wall, collapsed: ui.collapsedGroups,
                           reservedTrailing: showsStack ? Metric.pipReservedWidth : 0,
                           toggleGroup: { id in toggleGroup(id) }) { worker in
                    tile(worker, variant: .wall)
                }
                HStack(spacing: 17) {
                    KeyHint(keys: "⌘1", title: "Coordinator") { focusCoordinator() }
                    KeyHint(keys: "⇧⌘A", title: "Next request", isEnabled: !content.pending.isEmpty) { nextRequest() }
                    KeyHint(keys: "⌘]", title: "Zoom worker", isEnabled: count > 0) { zoomFocused() }
                    Spacer(minLength: 0)
                }
                .frame(height: 31, alignment: .bottom)
                .padding(.bottom, -11)
            }
        }
    }

    private func tile(_ worker: WorkerPresentation, variant: WorkerTile.Variant) -> some View {
        let openRequest: (() -> Void)? = worker.request.map { request in { open(request) } }
        let handBack: (() -> Void)? = actions.handBack.map { handBack in { handBack(worker.id) } }
        let sendInput: ((String) -> Void)? = actions.sendTerminalInput.map { send in { text in send(worker.id, text) } }
        let tileActions = WorkerTileActions(
            toggleZoom: { toggleZoom(worker.id) },
            openRequest: openRequest,
            copyID: { copy(worker.id) },
            handBack: handBack,
            sendInput: sendInput)
        return WorkerTile(worker: worker, variant: variant, isKeyFocused: paneFocus == worker.id,
                          reply: variant == .focused ? replyContext : nil, actions: tileActions)
            .focusable()
            .focusEffectDisabled()
            .focused($paneFocus, equals: worker.id)
            .simultaneousGesture(TapGesture().onEnded { ui.returnFocusWorkerID = worker.id })
    }

    @ViewBuilder private var attentionStack: some View {
        if let current = current {
            let queue = stack
            let index = queue.firstIndex { $0.id == current.id } ?? 0
            AttentionStack(current: current,
                           next: queue.count > 1 ? queue[(index + 1) % queue.count] : nil,
                           position: index + 1, count: queue.count,
                           reply: replyContext,
                           showNext: { showNext(after: current) },
                           expand: { expand(current) },
                           close: { close(current) })
        }
    }

    // MARK: Intents

    private func startComposing() {
        ui.newRunDraft = NewRunDraft(path: run?.path ?? UserDefaults.standard.string(forKey: "recentProject") ?? "")
        ui.composingRun = true
    }

    private func send(_ request: RequestPresentation) {
        let text = ui.drafts[request.id] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = ui.returnFocusWorkerID ?? run?.coordinator?.id
        Task {
            if await actions.reply(request.id, text) {
                ui.drafts[request.id] = nil
                if replyFocus == request.id { replyFocus = nil }
                if let target { paneFocus = target }
            }
        }
    }

    /// Deliberate move into a reply field. Arrival of a request never calls this.
    private func focusReply(_ requestID: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            replyFocus = requestID
        }
    }

    private func open(_ request: RequestPresentation) {
        ui.dismissedRequests.remove(request.id)
        if request.id != inlineRequestID { ui.activeRequestID = request.id }
        focusReply(request.id)
    }

    private func nextRequest() {
        if stack.isEmpty { ui.dismissedRequests.removeAll() }
        let queue = stack
        guard !queue.isEmpty else {
            if let inline = inlineRequestID { focusReply(inline) }
            return
        }
        var target = queue.first { $0.id == ui.activeRequestID } ?? queue[0]
        if replyFocus == target.id, queue.count > 1, let index = queue.firstIndex(where: { $0.id == target.id }) {
            target = queue[(index + 1) % queue.count]
        }
        ui.activeRequestID = target.id
        focusReply(target.id)
    }

    private func showNext(after request: RequestPresentation) {
        let queue = stack
        guard queue.count > 1, let index = queue.firstIndex(where: { $0.id == request.id }) else { return }
        ui.activeRequestID = queue[(index + 1) % queue.count].id
    }

    private func expand(_ request: RequestPresentation) {
        let target = request.workerIsCoordinator ? nil : request.workerID
        if request.runID == run?.id {
            ui.zoomedWorkerID = target
            ui.returnFocusWorkerID = request.workerID
        } else {
            ui.zoomAfterSelection = target
            actions.selectRun(request.runID)
        }
    }

    private func close(_ request: RequestPresentation) {
        ui.dismissedRequests.insert(request.id)
        if replyFocus == request.id { replyFocus = nil }
        if let target = ui.returnFocusWorkerID ?? run?.coordinator?.id { paneFocus = target }
    }

    private func toggleZoom(_ workerID: String) {
        if ui.zoomedWorkerID == workerID {
            returnToWall()
        } else {
            ui.zoomedWorkerID = workerID
            ui.returnFocusWorkerID = workerID
            refocus(workerID)
        }
    }

    private func returnToWall() {
        guard let workerID = ui.zoomedWorkerID else { return }
        ui.zoomedWorkerID = nil
        ui.returnFocusWorkerID = workerID
        refocus(workerID)
    }

    private func zoomFocused() {
        guard let run else { return }
        if ui.zoomedWorkerID != nil { returnToWall(); return }
        let candidate = paneFocus ?? ui.returnFocusWorkerID
        guard let candidate, run.wall.workers.contains(where: { $0.id == candidate }) else { return }
        toggleZoom(candidate)
    }

    private func focusCoordinator() {
        if let id = run?.coordinator?.id { paneFocus = id }
    }

    /// Restore keyboard focus after the worker's view is rebuilt in its new position.
    private func refocus(_ workerID: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            paneFocus = workerID
        }
    }

    private func toggleGroup(_ id: String) {
        if ui.collapsedGroups.contains(id) { ui.collapsedGroups.remove(id) } else { ui.collapsedGroups.insert(id) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: Reactions to data

    private func runChanged() {
        ui.zoomedWorkerID = ui.zoomAfterSelection
        ui.zoomAfterSelection = nil
        ui.collapsedGroups.removeAll()
        ui.showingRunDetails = false
        ui.returnFocusWorkerID = ui.zoomedWorkerID ?? run?.coordinator?.id
    }

    /// A new decision is announced once and leaves the current first responder alone.
    private func pendingChanged(from old: [String], to new: [String]) {
        let known = Set(old)
        for request in content.pending where !known.contains(request.id) {
            AccessibilityNotification.Announcement(
                "\(request.workerName) in \(request.runTitle) needs input").post()
        }
        let live = Set(new)
        ui.dismissedRequests.formIntersection(live)
        ui.drafts = ui.drafts.filter { live.contains($0.key) }
        if let active = ui.activeRequestID, !live.contains(active) { ui.activeRequestID = nil }
    }

    private func seedFocus() {
        guard ui.initialPaneFocus != nil || ui.initialReplyFocus != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if let id = ui.initialPaneFocus { paneFocus = id }
            if let id = ui.initialReplyFocus { replyFocus = id }
            ui.initialPaneFocus = nil
            ui.initialReplyFocus = nil
        }
    }
}

// MARK: - Live page

/// The production cockpit. It maps the feature model to presentation values on every refresh and
/// routes each intent back to the model by run or request ID.
struct CockpitView: View {
    let model: CockpitModel
    @State private var ui = CockpitPresentationState()

    var body: some View {
        CockpitScreen(content: CockpitContent(model: model), ui: ui, actions: actions)
            .task { await model.follow() }
    }

    private var actions: CockpitActions {
        CockpitActions(
            selectRun: { id in model.select(id) },
            reply: { requestID, answer in
                guard let item = model.pending.first(where: { $0.id == requestID }) else { return false }
                return await model.reply(to: item, text: answer)
            },
            stopRun: { runID in
                guard let run = model.runs.first(where: { $0.id == runID }) else { return }
                Task { await model.stop(run) }
            },
            reconnect: { Task { await model.refresh(allowStart: true) } },
            dismissNotice: { model.notice = nil },
            createRun: { path, task, title, key in
                try await model.create(path: path, task: task, title: title, operationID: key)
            })
    }
}
