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
//                                    trailing  SectionBar + WorkerWall of WorkerTile, or one focused WorkerTile,
//                                              with AttentionDrawer beside either (the default)
//                                    floating  AttentionStack (the PiP alternative)
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
    /// Worker whose action list is open.
    var actionMenuWorkerID: String?
    /// The one worker the developer has asked to stop and not yet confirmed.
    var stopWorkerCandidate: StopWorkerCandidate?
    /// How pending decisions are shown. The side panel is the default; the PiP stack is the
    /// alternative, chosen from the worker pane's menu.
    var attentionPresentation = AttentionPresentation.drawer
    /// The side panel was closed by the developer. A deliberate Next request or View request, a
    /// change of presentation, or a newly arrived request shows it again.
    var drawerClosed = false
    /// Pinned, the side panel takes its own width beside the wall or focused worker. Unpinned, it
    /// lies over them at the same edge and they keep their size.
    var drawerPinned = true
    /// When set, following a request into another run records where to return to.
    var offersReturnNavigation = false
    var returnTarget: ReturnTarget?
    /// The live app shows the PiP presentation in its own floating window. Fixtures leave this
    /// off and keep the PiP inside the cockpit window, where it is deterministic to capture.
    var floatsPiP = false
    /// A deliberate request to type a reply in the floating window. The window's own view moves
    /// its keyboard focus there and clears this. Arrival of a request never sets it.
    var floatingReplyFocus: String?
    /// Brings the floating window forward so it can take the keyboard. Set by its controller.
    var bringFloatingPanelForward: (() -> Void)?

    /// True when the PiP presentation is shown in the floating window.
    var usesFloatingPanel: Bool { floatsPiP && attentionPresentation == .pip }

    /// The live app leaves a request out of the attention surfaces while its waiting console is
    /// already in view. Fixtures leave this off, so each preview shows the state it is named for.
    var suppressesVisibleSources = false
    /// Consoles whose tile is at least half inside the worker viewport right now, as
    /// `ConsoleVisibility.key(variant, workerID)`. Reported by the tiles themselves as they are
    /// laid out, scrolled, zoomed or removed with a collapsed group.
    var visibleConsoles = Set<String>()
    /// The cockpit window is in front of the developer: this app is active and the window is
    /// neither minimized nor fully covered. Reported by WindowAttentionProbe.
    var cockpitWindowAttended = false
    /// Requests the developer asked for by View request or Next request. They are shown even
    /// while their console is in view, until answered or closed.
    var surfacedRequests = Set<String>()
    /// Worker whose source inspector is open. The console showing that worker presents it; the
    /// cockpit page starts and abandons the reading as this changes.
    var sourceInspectorWorkerID: String?

    /// Opens a worker's source inspector on its console, once the menu or list that asked for it
    /// has closed and, after a reveal, once that console is in place.
    func presentSource(of workerID: String, after delay: Duration = .milliseconds(120)) {
        Task {
            try? await Task.sleep(for: delay)
            sourceInspectorWorkerID = workerID
        }
    }

    /// Source access for a compact request surface (the PiP, in the window or floating). Its
    /// action shows the asking worker's console and opens the inspector there.
    func sourcePointer(for request: RequestPresentation, intents: ConsoleSourceIntents?,
                       reveal: @escaping () -> Void) -> ConsoleSourceAccess? {
        guard let session = request.workerSession, intents != nil else { return nil }
        return ConsoleSourceAccess(workerName: request.workerName, client: request.client, session: session,
                                   open: { [weak self] in
                                       reveal()
                                       self?.presentSource(of: request.workerID, after: .milliseconds(400))
                                   })
    }

    /// Shows the worker that raised a request: zooms it in the selected run, or selects its run
    /// and zooms it there. The in-window surfaces and the floating window both use this.
    func reveal(_ request: RequestPresentation, from run: RunContent?, selectRun: (String) -> Void) {
        let target = request.workerIsCoordinator ? nil : request.workerID
        if request.runID == run?.id {
            zoomedWorkerID = target
            returnFocusWorkerID = request.workerID
        } else {
            if offersReturnNavigation, let run {
                let zoomed = run.wall.workers.first { $0.id == zoomedWorkerID }
                let origin = zoomed ?? run.wall.workers.first { $0.id == returnFocusWorkerID }
                returnTarget = ReturnTarget(runID: run.id, runTitle: run.title,
                                            workerID: zoomed?.id, workerName: origin?.name,
                                            requestLabel: "\(request.workerName) · \(request.shortID)")
            }
            zoomAfterSelection = target
            selectRun(request.runID)
        }
    }
}

extension CockpitContent {
    /// The request answered inline in the focused worker, if there is one.
    @MainActor func inlineRequestID(_ ui: CockpitPresentationState) -> String? {
        guard let id = ui.zoomedWorkerID else { return nil }
        return selected?.wall.workers.first { $0.id == id }?.request?.id
    }

    /// Pending requests for the attention surfaces, oldest first: every run's requests, without
    /// the ones the developer hid and without the one answered inline in the focused worker, so
    /// each request has exactly one reply field. The side panel, the in-window PiP and the
    /// floating window all read this one queue.
    @MainActor func attentionQueue(_ ui: CockpitPresentationState) -> [RequestPresentation] {
        // The focused worker's inline prompt answers its request only while the developer can see
        // it. When the PiP floats and the cockpit is behind another app, minimized or showing the
        // new-run form, that request joins the queue so the floating window can carry it. Back in
        // an attended cockpit it leaves the queue again, and the inline prompt is the one field.
        // The side panel and the fixtures render in the cockpit window itself, beside the inline
        // prompt, so there the inline request always stays out.
        let inlineIsOutOfSight = ui.usesFloatingPanel && ui.suppressesVisibleSources
            && (!ui.cockpitWindowAttended || ui.composingRun)
        let inline = inlineIsOutOfSight ? nil : inlineRequestID(ui)
        return pending.filter { request in
            !ui.dismissedRequests.contains(request.id) && request.id != inline
                && (ui.surfacedRequests.contains(request.id) || !isSourceInView(request, ui))
        }
    }

    /// True when the console that raised this request is already in front of the developer, so
    /// surfacing the request again would repeat what its highlighted console shows. That needs
    /// all of: the live rule is on; the cockpit window is attended; the request belongs to the
    /// selected run and the run is showing; and the worker's tile is inside the worker viewport
    /// (the coordinator's console is always in the pane). A request from another run, a worker
    /// scrolled away or inside a collapsed group, or a cockpit that is behind another app or
    /// minimized is not in view.
    @MainActor func isSourceInView(_ request: RequestPresentation, _ ui: CockpitPresentationState) -> Bool {
        guard ui.suppressesVisibleSources, ui.cockpitWindowAttended, !ui.composingRun,
              request.runID == selected?.id else { return false }
        if request.workerIsCoordinator { return true }
        return ui.visibleConsoles.contains(ConsoleVisibility.key(.wall, request.workerID))
            || ui.visibleConsoles.contains(ConsoleVisibility.key(.focused, request.workerID))
    }
}

/// Names for the worker viewport and the consoles reported inside it.
enum ConsoleVisibility {
    /// Coordinate space of the clipped region that shows worker consoles: the wall's scroll view,
    /// or the focused worker's area.
    static let viewport = "workerViewport"
    /// Share of a tile's area that must be inside the viewport for it to count as in view.
    static let threshold: CGFloat = 0.5

    static func key(_ variant: WorkerTile.Variant, _ workerID: String) -> String {
        (variant == .focused ? "focused:" : "wall:") + workerID
    }
}

/// The worker named in a stop confirmation.
struct StopWorkerCandidate: Equatable {
    let id: String
    let name: String
}

/// The whole navigation model, supplied by a page that owns more destinations than the live
/// cockpit has (the design preview). Production never supplies this and builds its own rows.
struct FixtureNavigation {
    var groups: [NavigationGroup] = []
    var footer: [NavigationItem] = []
}

/// Title-bar content shared by every page in the window: the navigation toggle, wordmark and
/// breadcrumb at the leading edge, then optional search, an optional accessory and the service state.
struct WorkspaceToolbar: ToolbarContent {
    @Binding var sidebarExpanded: Bool
    let crumbs: [String]
    let connection: CockpitModel.Connection
    /// Workspace search is offered only where a search action exists.
    var search: (@MainActor () -> Void)? = nil
    var accessory: AnyView? = nil

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { sidebarExpanded.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(sidebarExpanded ? "Collapse navigation" : "Expand navigation")
                .accessibilityLabel(sidebarExpanded ? "Collapse navigation" : "Expand navigation")
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
        ConsoleModeToolbarItem()
        if let accessory {
            ToolbarItem(placement: .primaryAction) { accessory }
        }
        if let search {
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
            ConnectionIndicator(connection: connection)
        }
    }
}

struct CockpitScreen: View {
    let content: CockpitContent
    @Bindable var ui: CockpitPresentationState
    let actions: CockpitActions
    var fixtureNavigation: FixtureNavigation? = nil
    /// What the run setup form may offer. The live app uses the local default.
    var runSetup = RunSetupCapabilities()
    /// Extra title-bar control supplied by the hosting page (the preview gallery).
    var toolbarAccessory: AnyView? = nil

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
    private var inlineRequestID: String? { content.inlineRequestID(ui) }

    private var stack: [RequestPresentation] { content.attentionQueue(ui) }

    private var current: RequestPresentation? {
        let queue = stack
        return queue.first { $0.id == ui.activeRequestID } ?? queue.first
    }

    /// The PiP inside the cockpit window. The live app floats it in its own window instead.
    private var showsStack: Bool {
        current != nil && !ui.composingRun && run != nil && ui.attentionPresentation == .pip && !ui.floatsPiP
    }

    /// Side-panel presentation: the current request sits beside the wall, or beside the focused
    /// worker, in place of the PiP. A request answered inline in the focused worker is already
    /// left out of `stack`, so the panel then shows the other runs' and workers' requests.
    private var showsDrawer: Bool {
        ui.attentionPresentation == .drawer && current != nil && !ui.drawerClosed
    }

    /// The presentation menu's binding. Choosing a presentation shows it, even if the panel was closed.
    private var presentationChoice: Binding<AttentionPresentation> {
        Binding(get: { ui.attentionPresentation },
                set: { mode in
                    ui.attentionPresentation = mode
                    ui.drawerClosed = false
                })
    }

    private var replyContext: ReplyContext {
        ReplyContext(
            draft: { id in Binding(get: { ui.drafts[id] ?? "" }, set: { ui.drafts[id] = $0 }) },
            focus: $replyFocus,
            sending: content.sending,
            isOnline: isOnline,
            send: { request in send(request) })
    }

    /// Pending requests whose worker is disconnected, across every run.
    private var disconnectedRequestIDs: [String] {
        content.pending.filter(\.isWorkerDisconnected).map(\.id)
    }

    /// Pending requests whose host link is reconnecting, across every run. Their reply stays open.
    private var heldReplyRequestIDs: [String] {
        content.pending.filter { $0.replyHeldStatement != nil }.map(\.id)
    }

    private var stopWorkerTitle: String {
        ui.stopWorkerCandidate.map { "Stop \($0.name)?" } ?? "Stop worker?"
    }

    // MARK: Body

    var body: some View {
        // Reactions to data sit apart from the window chrome, which keeps each expression small
        // enough for the type checker.
        chrome
            .onChange(of: run?.id) { _, _ in runChanged() }
            .onChange(of: paneFocus) { _, focus in
                if let focus { ui.returnFocusWorkerID = focus }
            }
            .onChange(of: content.pending.map(\.id)) { old, new in pendingChanged(from: old, to: new) }
            .onChange(of: disconnectedRequestIDs) { old, new in disconnectedRequestsChanged(from: old, to: new) }
            .onChange(of: heldReplyRequestIDs) { old, new in heldReplyRequestsChanged(from: old, to: new) }
            // One inspector at a time. Opening it on a worker starts that worker's reading, and
            // closing it or moving to another worker abandons the one in flight.
            .onChange(of: ui.sourceInspectorWorkerID) { _, workerID in actions.source?.inspect(workerID) }
            .onAppear { seedFocus() }
    }

    private var chrome: some View {
        CockpitShell {
            navigation
        } banners: {
            banners
        } canvas: {
            canvas
        }
        .background { shortcuts }
        .background { WindowAttentionProbe { attended in ui.cockpitWindowAttended = attended } }
        .toolbar {
            WorkspaceToolbar(sidebarExpanded: $ui.sidebarExpanded, crumbs: crumbs, connection: content.connection,
                             search: actions.searchWorkspace, accessory: toolbarAccessory)
        }
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .alert("Stop this run?", isPresented: $ui.showingStopConfirmation, presenting: run) { run in
            Button("Stop run", role: .destructive) { actions.stopRun(run.id) }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("Stop delegation and cancel the managed agents in “\(run.title)”.")
        }
        .alert(stopWorkerTitle,
               isPresented: Binding(get: { ui.stopWorkerCandidate != nil },
                                    set: { if !$0 { ui.stopWorkerCandidate = nil } }),
               presenting: ui.stopWorkerCandidate) { candidate in
            Button("Stop worker", role: .destructive) { actions.stopWorker?(candidate.id) }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text("This stops only “\(candidate.name)”. The run, its coordinator and the other workers keep going.")
        }
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
        if let fixtureNavigation { return fixtureNavigation.groups }
        let workspace = [
            NavigationItem(id: "runs", title: "Runs", mark: .symbol("square.grid.2x2"),
                           isEnabled: !content.runs.isEmpty,
                           action: { ui.showingRunChooser.toggle() }),
            NavigationItem(id: "attention", title: "Attention", mark: .symbol("bell"),
                           badge: content.pending.count, isEnabled: !content.pending.isEmpty,
                           shortcut: KeyboardShortcut("a", modifiers: [.command, .shift]),
                           action: { nextRequest() })
        ]

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
        return groups
    }

    private var navigationFooter: [NavigationItem] {
        if let fixtureNavigation { return fixtureNavigation.footer }
        return [NavigationItem(id: "new-run", title: "New run", mark: .symbol("plus"),
                               isActive: ui.composingRun, isEnabled: isOnline,
                               shortcut: KeyboardShortcut("n", modifiers: .command),
                               action: { startComposing() })]
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
            // The live Attention row carries ⇧⌘A. A supplied navigation model has its own rows, so
            // the shortcut is kept here.
            if fixtureNavigation != nil {
                Button("Next request") { nextRequest() }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
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
                VStack(spacing: 0) {
                    RunHeader(run: run, canStop: run.canStop && isOnline && !content.isStopping,
                              showingDetails: $ui.showingRunDetails,
                              showRuns: { ui.showingRunChooser = true },
                              stop: { ui.showingStopConfirmation = true })
                    if let target = ui.returnTarget, target.runID != run.id {
                        Hairline()
                        ReturnStrip(target: target, goBack: { followReturn(target) },
                                    dismiss: { ui.returnTarget = nil })
                    }
                }
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
                                   sendMessage: sendMessage, source: sourceAccess(coordinator)) { request in
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

    /// The wall or the focused worker, with the attention side panel beside either one.
    private func workerPane(_ run: RunContent) -> some View {
        // The panel is one overlay at the pane's trailing edge in both states, so pinning and
        // unpinning keep the same view with its draft, focus and scroll position. Pinned, the
        // wall or focused worker gives up the panel's width; unpinned, the panel lies over it.
        VStack(spacing: 0) { workerRegion(run) }
            .padding(.trailing, showsDrawer && ui.drawerPinned ? Metric.attentionDrawerWidth : 0)
            .overlay(alignment: .trailing) {
                if showsDrawer { attentionDrawer }
            }
    }

    @ViewBuilder private func workerRegion(_ run: RunContent) -> some View {
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
                    HStack(spacing: 12) {
                        KeyHint(keys: "⌘[", title: "Return to wall") { returnToWall() }
                        AttentionPresentationMenu(selection: presentationChoice)
                    }
                }
                tile(zoomed, variant: .focused)
                    .coordinateSpace(.named(ConsoleVisibility.viewport))
            }
        } else {
            let count = run.wall.workers.count
            VStack(spacing: 0) {
                SectionBar {
                    SectionTitle(symbol: "square.grid.2x2", title: "Worker wall", count: count > 0 ? count : nil)
                } trailing: {
                  HStack(spacing: 12) {
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
                    AttentionPresentationMenu(selection: presentationChoice)
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

    /// The drawer reaches the pane's trailing and bottom edges, outside the wall's insets.
    @ViewBuilder private var attentionDrawer: some View {
        if let current = current {
            let canControl = !current.workerIsCoordinator && (actions.canControlWorker?(current.workerID) ?? true)
            let takeControl: (() -> Void)? = canControl
                ? actions.takeControl.map { take in { take(current.workerID); expand(current) } } : nil
            AttentionDrawer(current: current,
                            others: stack.filter { $0.id != current.id },
                            reply: replyContext,
                            takeControl: takeControl,
                            isPinned: ui.drawerPinned,
                            togglePin: { ui.drawerPinned.toggle() },
                            show: { request in ui.activeRequestID = request.id },
                            openWorker: { expand(current) },
                            close: { closeDrawer() })
                .frame(width: Metric.attentionDrawerWidth)
                .padding(.top, 10)
                .padding(.leading, 14)
                .padding(.trailing, 6 - Metric.paneInset)
                .padding(.bottom, 8 - Metric.paneBottom)
        }
    }

    private func tile(_ worker: WorkerPresentation, variant: WorkerTile.Variant) -> some View {
        let openRequest: (() -> Void)? = worker.request.map { request in { open(request) } }
        // One mapping for every surface of a worker (wall tile, focused view, action list). Each
        // action is offered only where it exists and the service says it applies to this worker
        // now; every closure is bound to this worker's ID.
        let held = worker.control == .held
        let canControl = actions.canControlWorker?(worker.id) ?? true
        let canInterrupt = actions.canInterruptWorker?(worker.id) ?? true
        let canStop = actions.canStopWorker?(worker.id) ?? true
        let handBack: (() -> Void)? = held ? actions.handBack.map { handBack in { handBack(worker.id) } } : nil
        let sendInput: ((String) async -> Bool)? = actions.sendFollowUp.map { send in
            { text in await send(worker.id, text) }
        }
        let takeControl: (() -> Void)? = !held && canControl
            ? actions.takeControl.map { take in { take(worker.id) } } : nil
        let interrupt: (() -> Void)? = canInterrupt
            ? actions.interruptWorker.map { interrupt in { interrupt(worker.id) } } : nil
        // Stopping asks first, naming this worker.
        let stop: (() -> Void)? = canStop && actions.stopWorker != nil
            ? { ui.stopWorkerCandidate = StopWorkerCandidate(id: worker.id, name: worker.name) } : nil
        // The richer action list exists only where the service offers worker operations. Viewing the
        // assignment and sending a follow-up open the worker, where both are shown.
        let rich = actions.offersWorkerOperations
        let showWorker: (() -> Void)? = rich && variant == .wall ? { toggleZoom(worker.id) } : nil
        // A follow-up is written in the focused worker. Taking control first when it is not held.
        let followUp: (() -> Void)? = rich && sendInput != nil && (held || takeControl != nil)
            ? { if !held { takeControl?() }; if ui.zoomedWorkerID != worker.id { toggleZoom(worker.id) } } : nil
        let tileActions = WorkerTileActions(
            toggleZoom: { toggleZoom(worker.id) },
            openRequest: openRequest,
            copyID: { copy(worker.id) },
            handBack: handBack,
            sendInput: sendInput,
            isBusy: actions.workerIsBusy?(worker.id) ?? false,
            viewAssignment: showWorker,
            followUp: followUp,
            takeControl: takeControl,
            interrupt: interrupt,
            stop: stop)
        let menuPresented: Binding<Bool>? = rich ? Binding(
            get: { ui.actionMenuWorkerID == worker.id },
            set: { open in
                if open { ui.actionMenuWorkerID = worker.id }
                else if ui.actionMenuWorkerID == worker.id { ui.actionMenuWorkerID = nil }
            }) : nil
        return WorkerTile(worker: worker, variant: variant, isKeyFocused: paneFocus == worker.id,
                          reply: variant == .focused ? replyContext : nil, actions: tileActions,
                          menuPresented: menuPresented, source: sourceAccess(worker))
            .focusable()
            .focusEffectDisabled()
            .focused($paneFocus, equals: worker.id)
            .simultaneousGesture(TapGesture().onEnded { ui.returnFocusWorkerID = worker.id })
            .modifier(ConsoleVisibilityReport(key: ConsoleVisibility.key(variant, worker.id), ui: ui))
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
                           close: { close(current) },
                           source: ui.sourcePointer(for: current, intents: actions.source,
                                                    reveal: { expand(current) }))
        }
    }

    /// Source access for a console that hosts the inspector: a wall tile, the focused worker or
    /// the coordinator. Nil for a worker without a provider session, and where no source can be
    /// read, so those consoles are unchanged. The inspection is handed over only when it is this
    /// worker's, so another worker's records are never drawn here.
    private func sourceAccess(_ worker: WorkerPresentation) -> ConsoleSourceAccess? {
        guard let session = worker.session, let intents = actions.source else { return nil }
        let id = worker.id
        let isPresented = Binding(
            get: { ui.sourceInspectorWorkerID == id },
            set: { shown in
                if shown { ui.sourceInspectorWorkerID = id }
                else if ui.sourceInspectorWorkerID == id { ui.sourceInspectorWorkerID = nil }
            })
        let panel = ConsoleSourceAccess.Panel(
            isPresented: isPresented,
            inspection: content.sourceInspection.flatMap { $0.workerID == id ? $0 : nil },
            select: { source in intents.select(source) },
            loadMore: { intents.loadMore() },
            retry: { intents.retry() },
            copy: { text in copy(text) })
        return ConsoleSourceAccess(workerName: worker.name, client: worker.client, session: session,
                                   open: { ui.presentSource(of: id) }, panel: panel)
    }

    // MARK: Intents

    private func startComposing() {
        ui.newRunDraft = NewRunDraft(path: run?.path ?? UserDefaults.standard.string(forKey: "recentProject") ?? "")
        ui.composingRun = true
    }

    private func send(_ request: RequestPresentation) {
        let text = ui.drafts[request.id] ?? ""
        guard !request.isWorkerDisconnected,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = ui.returnFocusWorkerID ?? run?.coordinator?.id
        Task {
            if await actions.reply(request.id, text) {
                ui.drafts[request.id] = nil
                if replyFocus == request.id { replyFocus = nil }
                restorePaneFocus(target)
            }
        }
    }

    /// Returns keyboard focus to the pane that had it before a reply field took it. The answered
    /// request's field is still being removed when the reply resolves, and AppKit clears the first
    /// responder as it goes, which would discard a focus set in the same update. So focus is set
    /// after the views settle, and once more if that did not hold. It never takes focus from a
    /// reply field the developer has moved into meanwhile.
    private func restorePaneFocus(_ target: String?) {
        guard let target else { return }
        Task {
            for delay in [90, 220] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard replyFocus == nil, paneFocus != target else { return }
                paneFocus = target
            }
        }
    }

    /// Deliberate move into a reply field. Arrival of a request never calls this.
    private func focusReply(_ requestID: String) {
        // A request shown in the floating window is answered there: bring that window forward and
        // let its own view take the keyboard.
        if ui.usesFloatingPanel, requestID != inlineRequestID {
            ui.floatingReplyFocus = requestID
            ui.bringFloatingPanelForward?()
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            replyFocus = requestID
        }
    }

    /// Hides the side panel. Its requests stay pending and its drafts are kept. Keyboard focus
    /// returns to the pane that had it if a reply field in the panel held it.
    private func closeDrawer() {
        ui.drawerClosed = true
        ui.surfacedRequests.removeAll()
        if replyFocus != nil, replyFocus != inlineRequestID {
            replyFocus = nil
            restorePaneFocus(ui.returnFocusWorkerID ?? run?.coordinator?.id)
        }
    }

    private func open(_ request: RequestPresentation) {
        ui.drawerClosed = false
        ui.surfacedRequests.insert(request.id)
        ui.dismissedRequests.remove(request.id)
        if request.id != inlineRequestID { ui.activeRequestID = request.id }
        focusReply(request.id)
    }

    private func nextRequest() {
        ui.drawerClosed = false
        // A deliberate step through every pending request, including ones left out of the
        // attention surfaces because their console is in view.
        let inline = inlineRequestID
        var queue = content.pending.filter { $0.id != inline && !ui.dismissedRequests.contains($0.id) }
        if queue.isEmpty {
            ui.dismissedRequests.removeAll()
            queue = content.pending.filter { $0.id != inline }
        }
        guard !queue.isEmpty else {
            if let inline { focusReply(inline) }
            return
        }
        var target = queue.first { $0.id == ui.activeRequestID } ?? queue[0]
        // Pressing it again on the request already being answered moves to the next one.
        let isAnswering = replyFocus == target.id
            || (ui.usesFloatingPanel && ui.surfacedRequests.contains(target.id) && ui.activeRequestID == target.id)
        if isAnswering, queue.count > 1, let index = queue.firstIndex(where: { $0.id == target.id }) {
            target = queue[(index + 1) % queue.count]
        }
        ui.surfacedRequests.insert(target.id)
        ui.activeRequestID = target.id
        focusReply(target.id)
    }

    private func showNext(after request: RequestPresentation) {
        let queue = stack
        guard queue.count > 1, let index = queue.firstIndex(where: { $0.id == request.id }) else { return }
        ui.activeRequestID = queue[(index + 1) % queue.count].id
    }

    private func expand(_ request: RequestPresentation) {
        ui.reveal(request, from: run, selectRun: { id in actions.selectRun(id) })
    }

    /// Goes back to the run and worker recorded before following a request.
    private func followReturn(_ target: ReturnTarget) {
        ui.returnTarget = nil
        ui.zoomAfterSelection = target.workerID
        actions.selectRun(target.runID)
    }

    private func close(_ request: RequestPresentation) {
        ui.dismissedRequests.insert(request.id)
        ui.surfacedRequests.remove(request.id)
        if replyFocus == request.id { replyFocus = nil }
        restorePaneFocus(ui.returnFocusWorkerID ?? run?.coordinator?.id)
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
        ui.sourceInspectorWorkerID = nil
        ui.returnFocusWorkerID = ui.zoomedWorkerID ?? run?.coordinator?.id
    }

    /// A new decision is announced once and leaves the current first responder alone.
    private func pendingChanged(from old: [String], to new: [String]) {
        let known = Set(old)
        for request in content.pending where !known.contains(request.id) {
            AccessibilityNotification.Announcement(
                "\(request.workerName) in \(request.runTitle) needs input").post()
            // A new request shows a closed side panel again. It does not move keyboard focus.
            ui.drawerClosed = false
        }
        let live = Set(new)
        ui.dismissedRequests.formIntersection(live)
        ui.surfacedRequests.formIntersection(live)
        ui.drafts = ui.drafts.filter { live.contains($0.key) }
        if let active = ui.activeRequestID, !live.contains(active) { ui.activeRequestID = nil }
    }

    /// A worker that drops with a request waiting is announced once. A reply field that held the
    /// keyboard is now closed, so focus goes back to the pane that had it. The draft is kept.
    private func disconnectedRequestsChanged(from old: [String], to new: [String]) {
        let known = Set(old)
        for request in content.pending where request.isWorkerDisconnected && !known.contains(request.id) {
            AccessibilityNotification.Announcement(
                "\(request.workerName) in \(request.runTitle) is disconnected. Its request stays pending and cannot be answered until it reconnects.").post()
            if replyFocus == request.id {
                replyFocus = nil
                restorePaneFocus(ui.returnFocusWorkerID ?? run?.coordinator?.id)
            }
        }
    }

    /// A host that starts reconnecting with a request waiting is announced once. The reply stays
    /// open, so focus and the draft are left where they are.
    private func heldReplyRequestsChanged(from old: [String], to new: [String]) {
        let known = Set(old)
        for request in content.pending where !known.contains(request.id) {
            if let statement = request.replyHeldStatement {
                AccessibilityNotification.Announcement(statement).post()
            }
        }
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

// MARK: - Visibility reporting

/// Reports whether a console's tile is in view, into `visibleConsoles`. In view means at least
/// `ConsoleVisibility.threshold` of the tile's area lies inside the worker viewport's bounds, so a
/// tile scrolled out of the wall is not in view. A tile that leaves the hierarchy (its group was
/// collapsed, the wall gave way to a focused worker, another run was selected) is removed.
struct ConsoleVisibilityReport: ViewModifier {
    let key: String
    let ui: CockpitPresentationState

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { proxy in
                guard let viewport = proxy.bounds(of: .named(ConsoleVisibility.viewport)) else { return false }
                let own = CGRect(origin: .zero, size: proxy.size)
                let shared = own.intersection(viewport)
                guard !shared.isNull, own.width > 0, own.height > 0 else { return false }
                return shared.width * shared.height >= own.width * own.height * ConsoleVisibility.threshold
            } action: { inView in
                if inView { ui.visibleConsoles.insert(key) } else { ui.visibleConsoles.remove(key) }
            }
            .onDisappear { ui.visibleConsoles.remove(key) }
    }
}

/// Reports whether the window this view sits in is in front of the developer: the app is active,
/// and the window is neither minimized nor fully covered. It follows the app's activation, the
/// window's miniaturization and its occlusion state.
struct WindowAttentionProbe: NSViewRepresentable {
    let report: (Bool) -> Void

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.didChangeOcclusionStateNotification] {
                    center.addObserver(self, selector: #selector(changed(_:)), name: name, object: window)
                }
                for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                    center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
                }
            }
            publish()
        }

        @objc private func changed(_ notification: Notification) { publish() }

        private func publish() {
            let attended = window.map { window in
                NSApp.isActive && !window.isMiniaturized && window.occlusionState.contains(.visible)
            } ?? false
            guard attended != last else { return }
            last = attended
            // Delivered after the current view update, so state is not changed mid-layout.
            Task { @MainActor [weak self] in self?.report?(attended) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = report
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.report = report }
}

// MARK: - Live page

/// The production cockpit. It maps the feature model to presentation values on every refresh and
/// routes each intent back to the model by run or request ID.
struct CockpitView: View {
    @Environment(ConsoleModeStore.self) private var consoleModes
    let model: CockpitModel
    @State private var ui = CockpitView.initialState()
    /// The floating window for the PiP presentation. It lives as long as the live page.
    @State private var floatingPanel: FloatingAttentionController?

    /// Where the developer's choice of attention presentation is kept on this Mac.
    private static let attentionPresentationKey = "attentionPresentation"
    private static let attentionPanelPinnedKey = "attentionPanelPinned"

    /// Starts from the stored choice when there is one. Without one the side-panel default applies
    /// and nothing is written, so a default never replaces a choice.
    private static func initialState() -> CockpitPresentationState {
        let ui = CockpitPresentationState()
        ui.floatsPiP = true
        ui.suppressesVisibleSources = true
        if let raw = UserDefaults.standard.string(forKey: attentionPresentationKey),
           let stored = AttentionPresentation(rawValue: raw),
           AttentionPresentationMenu.options.contains(stored) {
            ui.attentionPresentation = stored
        }
        if let pinned = UserDefaults.standard.object(forKey: attentionPanelPinnedKey) as? Bool {
            ui.drawerPinned = pinned
        }
        return ui
    }

    var body: some View {
        CockpitScreen(content: CockpitContent(model: model), ui: ui, actions: actions)
            .task { await model.follow() }
            .onAppear {
                guard floatingPanel == nil else { return }
                let controller = FloatingAttentionController(model: model, ui: ui, actions: actions, consoleModes: consoleModes)
                controller.start()
                floatingPanel = controller
            }
            // Written only when the developer changes it from the menu.
            .onChange(of: ui.attentionPresentation) { _, mode in
                UserDefaults.standard.set(mode.rawValue, forKey: Self.attentionPresentationKey)
            }
            .onChange(of: ui.drawerPinned) { _, pinned in
                UserDefaults.standard.set(pinned, forKey: Self.attentionPanelPinnedKey)
            }
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
            },
            // Per-worker control. Each call names its worker; the model decides, per worker, which
            // of them apply (see the `can…` queries below).
            handBack: { workerID in Task { await model.handBack(workerID) } },
            sendFollowUp: { workerID, text in await model.sendFollowUp(to: workerID, text: text) },
            takeControl: { workerID in Task { await model.takeControl(workerID) } },
            interruptWorker: { workerID in Task { await model.interruptWorker(workerID) } },
            stopWorker: { workerID in Task { await model.stopWorker(workerID) } },
            canControlWorker: { workerID in model.canControlWorker(workerID) },
            canInterruptWorker: { workerID in model.canInterruptWorker(workerID) },
            canStopWorker: { workerID in model.canStopWorker(workerID) },
            workerIsBusy: { workerID in model.workerActions.contains(workerID) },
            // Source reads name only the worker. The service resolves its bound session.
            source: ConsoleSourceIntents(
                inspect: { workerID in model.source.inspect(workerID) },
                select: { source in model.source.select(source) },
                loadMore: { model.source.loadMore() },
                retry: { model.source.retry() }))
    }
}
