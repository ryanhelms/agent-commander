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
//                  Given a ShellContext (the live page), the same canvas sits in the redesigned
//                  shell instead:
//                    ShellTemplate
//                      navigation  ShellModeRail (+ RunChooser popover), from LiveShell.navigation
//                      toolbar     ShellToolbarTitle, service state, ShellToolbarReadouts
//                      canvas      banners over the wall above, LiveNeedsYouPage, PreferencesPage
//                                  or ShellPlaceholderPage, by the selected place
//   CockpitView    the live page: binds CockpitModel to CockpitScreen and owns the subscription.

/// Presentation state keyed by stable IDs. It survives data refreshes and belongs to the feature
/// layer, never to a component: zoom, collapsed groups, the split, and one draft per request.
@Observable @MainActor
final class CockpitPresentationState {
    var zoomedWorkerID: String?
    /// A remote worker (a hand-off on a friend's Mac) shown in the zoom view, by `server/request`.
    var zoomedRemoteWorkerID: String?
    var zoomAfterSelection: String?
    var collapsedGroups = Set<String>()
    var drafts: [String: String] = [:]
    var activeRequestID: String?
    var dismissedRequests = Set<String>()
    var returnFocusWorkerID: String?
    var splitFraction = Metric.coordinatorFraction
    var sidebarExpanded = false
    /// The redesigned shell's place, by `LiveShell` ID. The wall is the default, as before.
    var shellPlace = LiveShell.wall
    /// The mode rail's context list is put away, leaving the rail.
    var contextListHidden = false
    /// Network requests answered in Needs you a moment ago, kept while their outcome shows.
    var needsYouDecided: [NeedsYouItem] = []
    /// Why the last answer to a network request didn't go through, by request.
    var needsYouFailures: [String: String] = [:]
    /// Network requests whose answer is still on its way.
    var needsYouRunning = Set<String>()
    /// The network pages' own selections and each row's last result.
    let networkPages = NetworkPagesLiveState()
    /// The window's own place, reads and drafts on the Teams pages.
    let teamsPages = TeamsPagesLiveState()
    /// The shell shows a page other than the wall, so no console is in front of the developer.
    var wallHidden: Bool { shellPlace != LiveShell.wall }
    /// The last key command pressed and how many there have been. The page runs each one from
    /// its current state (CockpitShortcuts.swift).
    private(set) var keyCommand: CockpitCommand?
    private(set) var keyCommandCount = 0

    /// Records a key command for the page to run.
    func press(_ command: CockpitCommand) {
        keyCommand = command
        keyCommandCount += 1
    }
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
    /// The request Next request or View request last brought forward, by request ID, inline or
    /// in Attention. Pressing Next request again moves past it, so a choice-only request, whose
    /// reply has no text field to hold focus, still advances. Cleared when the developer picks
    /// another request by hand or it is no longer pending.
    var reachedRequestID: String?
    /// Worker whose source inspector is open. The console showing that worker presents it; the
    /// cockpit page starts and abandons the reading as this changes.
    var sourceInspectorWorkerID: String?
    /// Worker whose provider-session panel is open. The console showing that worker presents it;
    /// the cockpit page starts and abandons the reading as this changes.
    var providerSessionWorkerID: String?
    /// Worker whose input-request panel is open. The console showing that worker presents it; the
    /// cockpit page starts and abandons the reading as this changes.
    var elicitationWorkerID: String?

    /// Opens a worker's source inspector on its console, once the menu or list that asked for it
    /// has closed and, after a reveal, once that console is in place.
    func presentSource(of workerID: String, after delay: Duration = .milliseconds(120)) {
        Task {
            try? await Task.sleep(for: delay)
            sourceInspectorWorkerID = workerID
        }
    }

    /// Opens a worker's provider-session panel on its console, once the menu that asked for it
    /// has closed.
    func presentProviderSession(of workerID: String, after delay: Duration = .milliseconds(120)) {
        Task {
            try? await Task.sleep(for: delay)
            providerSessionWorkerID = workerID
        }
    }

    /// Opens a worker's input-request panel on its console, once the menu that asked for it has
    /// closed.
    func presentElicitations(of workerID: String, after delay: Duration = .milliseconds(120)) {
        Task {
            try? await Task.sleep(for: delay)
            elicitationWorkerID = workerID
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

    /// Shows this request in the attention surfaces, picked by hand (Also pending, the stack's
    /// next card or its position). The next Next request starts from it.
    func show(requestID: String) {
        activeRequestID = requestID
        reachedRequestID = nil
    }

    /// Shows the worker that raised a request: zooms it in the selected run, or selects its run
    /// and zooms it there. The in-window surfaces and the floating window both use this.
    func reveal(_ request: RequestPresentation, from run: RunContent?, selectRun: (String) -> Void) {
        let target = request.workerIsCoordinator ? nil : request.workerID
        shellPlace = LiveShell.wall
        if request.runID == run?.id {
            zoomedRemoteWorkerID = nil
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
    /// The request answered inline in the focused worker, if there is one: that worker's first
    /// pending request. Its other pending requests are answered from Attention.
    @MainActor func inlineRequestID(_ ui: CockpitPresentationState) -> String? {
        guard let id = ui.zoomedWorkerID else { return nil }
        return selected?.wall.workers.first { $0.id == id }?.request?.id
    }

    /// The inline request while its form is actually in front of the developer. The focused
    /// worker's inline prompt answers its request only while the developer can see it. When the
    /// PiP floats and the cockpit is behind another app, minimized or showing the new-run form,
    /// that request joins the queue so the floating window can carry it. Back in an attended
    /// cockpit it leaves the queue again, and the inline prompt is the one field. The side panel
    /// and the fixtures render in the cockpit window itself, beside the inline prompt, so there
    /// the inline request always stays out.
    @MainActor func shownInlineRequestID(_ ui: CockpitPresentationState) -> String? {
        let inlineIsOutOfSight = ui.usesFloatingPanel && ui.suppressesVisibleSources
            && (!ui.cockpitWindowAttended || ui.composingRun || ui.wallHidden)
        return inlineIsOutOfSight ? nil : inlineRequestID(ui)
    }

    /// Pending requests for the attention surfaces, oldest first: every run's requests, by request
    /// ID, without the ones the developer hid and without the one answered inline in the focused
    /// worker, so each request has exactly one reply field. A second request from the focused or a
    /// visible worker stays in, because no console shows it. The side panel, the in-window PiP and
    /// the floating window all read this one queue.
    @MainActor func attentionQueue(_ ui: CockpitPresentationState) -> [RequestPresentation] {
        let inline = shownInlineRequestID(ui)
        return pending.filter { request in
            !ui.dismissedRequests.contains(request.id) && request.id != inline
                && (ui.surfacedRequests.contains(request.id) || !isSourceInView(request, ui))
        }
    }

    /// The explicit Next request step for the current presentation state.
    @MainActor func attentionNavigation(_ ui: CockpitPresentationState, answering: String?) -> AttentionNavigation {
        AttentionNavigation(order: pending.map(\.id), inline: shownInlineRequestID(ui),
                            dismissed: ui.dismissedRequests, active: ui.activeRequestID,
                            current: answering ?? ui.reachedRequestID)
    }

    /// The request a worker's console marks: its first pending one. A console shows exactly one
    /// request, so only that request ID counts as already in view.
    @MainActor func shownRequestID(ofWorker workerID: String) -> String? {
        guard let run = selected else { return nil }
        if run.coordinator?.id == workerID { return run.coordinator?.request?.id }
        return run.wall.workers.first { $0.id == workerID }?.request?.id
    }

    /// True when the console that raised this request is already in front of the developer and
    /// shows this very request, so surfacing it again would repeat what its highlighted console
    /// shows. That needs all of: the live rule is on; the cockpit window is attended; the request
    /// belongs to the selected run and the run is showing; the request is the one its worker's
    /// console marks (decided by request ID, never by worker); and the worker's tile is inside the
    /// worker viewport (the coordinator's console is always in the pane). A request from another
    /// run, a worker's further request, a worker scrolled away or inside a collapsed group, or a
    /// cockpit that is behind another app or minimized is not in view.
    @MainActor func isSourceInView(_ request: RequestPresentation, _ ui: CockpitPresentationState) -> Bool {
        guard ui.suppressesVisibleSources, ui.cockpitWindowAttended, !ui.composingRun, !ui.wallHidden,
              request.runID == selected?.id,
              shownRequestID(ofWorker: request.workerID) == request.id else { return false }
        if request.workerIsCoordinator { return true }
        return ui.visibleConsoles.contains(ConsoleVisibility.key(.wall, request.workerID))
            || ui.visibleConsoles.contains(ConsoleVisibility.key(.focused, request.workerID))
    }
}

/// One step of Next request, as plain values so it can be exercised without a window. It walks
/// every pending request by ID in the cockpit's stable order, including those left out of the
/// attention surfaces because their console is in view, and the focused worker's inline request,
/// which is reached in its own form. Requests the developer hid are skipped until none is left.
struct AttentionNavigation: Equatable {
    /// Every pending request ID, oldest first, across runs.
    let order: [String]
    /// The request answered inline in the focused worker and shown there now. Nil otherwise.
    let inline: String?
    let dismissed: Set<String>
    /// The request the attention surfaces show.
    let active: String?
    /// The request the developer is answering or last reached: pressing again moves past it.
    let current: String?

    enum Target: Equatable {
        /// Show this request in Attention and move to its reply.
        case attention(String)
        /// Move to the focused worker's inline form for this request.
        case inline(String)
        case none
    }

    /// The requests Next request steps through, and whether reaching them restores hidden ones:
    /// once every request Attention could show is hidden, they all come back.
    var candidates: (ids: [String], restoresDismissed: Bool) {
        let open = order.filter { !dismissed.contains($0) }
        let restores = !open.contains { $0 != inline } && order.contains { $0 != inline && dismissed.contains($0) }
        return restores ? (order, true) : (open, false)
    }

    var target: Target {
        let ids = candidates.ids
        guard !ids.isEmpty else { return .none }
        let id: String
        if let current, let index = ids.firstIndex(of: current) {
            // Pressing it again on the request already being answered moves to the next one.
            id = ids.count > 1 ? ids[(index + 1) % ids.count] : current
        } else if let active, active != inline, ids.contains(active) {
            id = active
        } else {
            // The first request Attention can show; the inline one only when it is the only one.
            id = ids.first { $0 != inline } ?? ids[0]
        }
        return id == inline ? .inline(id) : .attention(id)
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
    /// The headless host whose service is in use. Nil for this Mac's.
    var serviceHost: String? = nil
    /// Workspace search is offered only where a search action exists.
    var search: (@MainActor () -> Void)? = nil
    var accessory: AnyView? = nil
    /// Staged adapter updates. The notice appears beside the service state only while the set is
    /// not empty.
    var adapterUpdates: AdapterUpdateFeed? = nil
    /// The redesigned shell's wordmark and breadcrumb, in place of the ones drawn here.
    var title: AnyView? = nil
    /// The redesigned shell's readouts, after the service state. Each is its own toolbar item, so
    /// each is its own element for assistive apps: the servers button, then the presence menu.
    var readouts: AnyView? = nil
    var presence: AnyView? = nil

    /// The shell's items sit flat on the toolbar: no shared glass capsule behind them. The console
    /// display menu and the adapter notice are the console's own controls and keep their look.
    private var capsule: Visibility { title == nil ? .automatic : .hidden }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { sidebarExpanded.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain)
                .help(sidebarExpanded ? "Collapse navigation" : "Expand navigation")
                .accessibilityLabel(sidebarExpanded ? "Collapse navigation" : "Expand navigation")
        }
        .sharedBackgroundVisibility(capsule)
        ToolbarItem(placement: .navigation) {
            if let title {
                title
            } else {
                HStack(spacing: 12) {
                    Text("Agent Commander").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                    if !crumbs.isEmpty {
                        Hairline(vertical: true).frame(height: 18)
                        Breadcrumb(items: crumbs)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .sharedBackgroundVisibility(capsule)
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
                .keyboardShortcut(KeyEquivalent(CockpitShortcuts.search.key), modifiers: CockpitShortcuts.search.modifiers)
                .accessibilityLabel("Search workspace")
            }
            .sharedBackgroundVisibility(capsule)
        }
        if let adapterUpdates {
            AdapterUpdateToolbarItem(feed: adapterUpdates)
        }
        ToolbarItem(placement: .primaryAction) {
            ConnectionIndicator(connection: connection, host: serviceHost)
        }
        .sharedBackgroundVisibility(capsule)
        if let readouts {
            ToolbarItem(placement: .primaryAction) { readouts }
                .sharedBackgroundVisibility(capsule)
        }
        if let presence {
            ToolbarItem(placement: .primaryAction) { presence }
                .sharedBackgroundVisibility(capsule)
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
    /// Staged adapter updates for the title bar. The feed is read by the toolbar item alone.
    var adapterUpdates: AdapterUpdateFeed? = nil
    /// The redesigned shell: the mode rail, the toolbar readouts and the Needs you inbox, with
    /// the network's state. The live page supplies it. Without it the cockpit keeps the earlier
    /// navigation rail, as the design previews of the cockpit do.
    var shell: ShellContext? = nil

    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
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

    /// Opens a worker's Source inspector. Nil when the service offers no source. The closure is
    /// typed as main-actor where it is written, so it is never converted from an unisolated one.
    private var openSource: (@MainActor (_ workerID: String) -> Void)? {
        guard actions.source != nil else { return nil }
        let present: @MainActor (String) -> Void = { workerID in ui.presentSource(of: workerID) }
        return present
    }

    // MARK: Body

    var body: some View {
        // Reactions to data sit apart from the window chrome, which keeps each expression small
        // enough for the type checker.
        chrome
            .consoleRecordAccess(actions, openSource: openSource)
            .onChange(of: run?.id) { _, _ in runChanged() }
            // A key command is run here, where the page's values are current.
            .onChange(of: ui.keyCommandCount) { _, _ in if let command = ui.keyCommand { perform(command) } }
            .onChange(of: paneFocus) { _, focus in
                if let focus { ui.returnFocusWorkerID = focus }
            }
            .onChange(of: content.pending.map(\.id)) { old, new in pendingChanged(from: old, to: new) }
            .onChange(of: disconnectedRequestIDs) { old, new in disconnectedRequestsChanged(from: old, to: new) }
            .onChange(of: heldReplyRequestIDs) { old, new in heldReplyRequestsChanged(from: old, to: new) }
            // One inspector at a time. Opening it on a worker starts that worker's reading, and
            // closing it or moving to another worker abandons the one in flight.
            .onChange(of: ui.sourceInspectorWorkerID) { _, workerID in actions.source?.inspect(workerID) }
            // The same for the provider-session panel: one worker at a time, read while it is open.
            .onChange(of: ui.providerSessionWorkerID) { _, workerID in actions.providerSession?.inspect(workerID) }
            // And for input requests: read on opening and while open, dropped on closing.
            .onChange(of: ui.elicitationWorkerID) { _, workerID in actions.elicitations?.inspect(workerID) }
            .onAppear { seedFocus() }
    }

    /// The window's frame: the redesigned shell when the page supplies one, otherwise the
    /// earlier navigation rail.
    private var frame: AnyView {
        guard let shell else {
            return AnyView(CockpitShell {
                navigation
            } banners: {
                banners
            } canvas: {
                canvas
            })
        }
        return AnyView(shellFrame(shell, shellNavigation(shell)))
    }

    private var chrome: some View {
        let shellNavigation = shell.map { self.shellNavigation($0) }
        return frame
        .background { shortcuts }
        .background { WindowAttentionProbe { attended in ui.cockpitWindowAttended = attended } }
        .toolbar {
            if let shell, let shellNavigation {
                if shell.chrome == .hosted {
                    WorkspaceToolbar(sidebarExpanded: Binding(get: { !ui.contextListHidden },
                                                              set: { ui.contextListHidden = !$0 }),
                                     crumbs: [], connection: content.connection,
                                     serviceHost: shell.hosts?.serviceName,
                                     search: actions.searchWorkspace, accessory: toolbarAccessory,
                                     adapterUpdates: adapterUpdates,
                                     // Toolbar items don't inherit the window's theme, so it is handed on.
                                     title: AnyView(ShellToolbarTitle(crumbs: shellCrumbs(shellNavigation))
                                        .environment(\.theme, theme)),
                                     readouts: AnyView(shellReadouts(shell, part: .servers).environment(\.theme, theme)),
                                     presence: AnyView(shellReadouts(shell, part: .presence).environment(\.theme, theme)))
                }
            } else {
                WorkspaceToolbar(sidebarExpanded: $ui.sidebarExpanded, crumbs: crumbs, connection: content.connection,
                                 search: actions.searchWorkspace, accessory: toolbarAccessory,
                                 adapterUpdates: adapterUpdates)
            }
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

    // MARK: Shell (the redesigned main window)

    /// The inbox as the navigation counts it: what waits now, without rows showing an outcome.
    private func shellNavigation(_ shell: ShellContext) -> CommanderNavigation {
        let inbox = LiveShell.inbox(pending: content.pending, network: shell.network, now: shell.now ?? Date(),
                                    decided: ui.needsYouDecided)
        return LiveShell.navigation(runs: content.runs, openRunPath: run?.path, composing: ui.composingRun,
                                    place: ui.shellPlace, needsYou: inbox.pendingCount, network: shell.network,
                                    isOnline: isOnline, showsHosts: shell.hosts != nil,
                                    serviceHost: shell.hosts?.serviceName)
    }

    /// On the wall the breadcrumb is the cockpit's own: project, run, then the zoomed worker.
    private func shellCrumbs(_ navigation: CommanderNavigation) -> [String] {
        guard LiveShell.showsWall(navigation.selection) else { return navigation.crumbs }
        // With no run open the wall has no crumbs of its own, so the place says where this is.
        if crumbs.isEmpty {
            let mode = navigation.modes.first { $0.id == navigation.selectedModeID }?.title
            return [mode, navigation.place(LiveShell.wall)?.title].compactMap { $0 }
        }
        return crumbs
    }

    private func shellReadouts(_ shell: ShellContext, part: ShellToolbarReadouts.Part = .both) -> some View {
        ShellToolbarReadouts(part: part, servers: shell.network.health, profile: shell.network.profile,
                             openServers: { show(place: LiveShell.servers) },
                             pickPresence: { shell.actions.setPresence($0) })
    }

    private func shellFrame(_ shell: ShellContext, _ navigation: CommanderNavigation) -> some View {
        ShellTemplate(chrome: shell.chrome) {
            // The modes' keys are bound once, with the window's other shortcuts.
            ShellModeRail(navigation: navigation, modeModifiers: LiveShell.modeModifiers,
                          showsContext: !ui.contextListHidden, bindsModeKeys: false) { action in
                act(action, in: navigation, shell)
            }
            .popover(isPresented: $ui.showingRunChooser, arrowEdge: .trailing) {
                RunChooser(runs: content.runs, selected: run?.id) { id in
                    ui.showingRunChooser = false
                    ui.composingRun = false
                    ui.shellPlace = LiveShell.wall
                    actions.selectRun(id)
                }
            }
        } toolbarLeading: {
            ShellToolbarTitle(crumbs: shellCrumbs(navigation))
        } toolbarTrailing: {
            HStack(spacing: Space.m) {
                ConnectionIndicator(connection: content.connection, host: shell.hosts?.serviceName)
                shellReadouts(shell)
            }
        } canvas: {
            VStack(spacing: 0) {
                banners
                shellCanvas(shell, navigation).frame(maxWidth: .infinity, maxHeight: .infinity)
                AppVersionFooter()
            }
        }
        // A countdown drawn by the network's own rows counts from the window's fixed time, when it has one.
        .environment(\.multiplayerFixedNow, shell.now)
    }

    @ViewBuilder private func shellCanvas(_ shell: ShellContext, _ navigation: CommanderNavigation) -> some View {
        let selection = navigation.selection
        if LiveShell.showsWall(selection) {
            canvas
        } else if selection == LiveShell.needsYou {
            LiveNeedsYouPage(pending: content.pending, network: shell.network, decided: ui.needsYouDecided,
                             failures: ui.needsYouFailures, now: shell.now,
                             decide: { inbox, id, decision in decide(id, decision, in: inbox, shell) },
                             open: { id in openFromInbox(id, shell) },
                             reply: { id in openFromInbox(id, shell) })
        } else if selection == LiveShell.settings {
            PreferencesPage(projectName: run?.project ?? "", retention: "", retentionOptions: [],
                            showsSystemAppearance: false, presentation: ui.attentionPresentation,
                            choosePresentation: { mode in presentationChoice.wrappedValue = mode },
                            chooseTheme: { id in ThemeChoice.select(id) },
                            presentations: AttentionPresentationMenu.options, showsRecording: false,
                            openAppSettings: { openSettings() })
        } else if selection == LiveShell.hosts, let hosts = shell.hosts {
            CommanderHostsPage(hosts: hosts)
        } else if NetworkPlace.hasPage(selection), let page = shell.networkPage {
            page(selection) { place in show(place: place) }
        } else if TeamsPlace.hasPage(selection), let page = shell.teamsPage {
            page(selection) { place in show(place: place) }
        } else {
            ShellPlaceholderPage(crumbs: navigation.crumbs, title: navigation.selectedPlace?.title ?? "",
                                 note: LiveShell.note(for: selection, network: shell.network),
                                 actionTitle: shell.actions.openNetworkPanel == nil ? nil : "Open network panel",
                                 action: { shell.actions.openNetworkPanel?() })
        }
    }

    /// Routes one navigation action. The navigation value itself is rebuilt from state.
    private func act(_ action: CommanderNavigationAction, in navigation: CommanderNavigation, _ shell: ShellContext) {
        switch action {
        case .select(let id):
            show(place: id, from: navigation)
        case .selectMode:
            var next = navigation
            next.apply(action)
            if next.selection != navigation.selection { show(place: next.selection, from: navigation) }
        case .setPresence(let choice):
            shell.actions.setPresence(choice)
        case .share(let id):
            guard let path = LiveShell.projectPath(of: id), let name = navigation.place(id)?.title else { return }
            MultiplayerShareLauncher.action(.repo(path: path, name: name))?()
        case .toggleGroup:
            break
        }
    }

    /// Goes to a place. Runs shows the wall, and offers the run chooser when the wall is already
    /// showing; a project opens its newest run; New run opens the form.
    private func show(place id: String, from navigation: CommanderNavigation? = nil) {
        if id == LiveShell.wall {
            if let navigation, LiveShell.showsWall(navigation.selection), !ui.composingRun, !content.runs.isEmpty {
                ui.showingRunChooser.toggle()
            }
            ui.composingRun = false
            ui.shellPlace = LiveShell.wall
        } else if id == LiveShell.newRun {
            // No run can start while the service is offline; the row and ⌘N are both off.
            guard isOnline else { return }
            ui.shellPlace = LiveShell.wall
            startComposing()
        } else if let path = LiveShell.projectPath(of: id) {
            ui.shellPlace = LiveShell.wall
            ui.composingRun = false
            if let latest = content.runs.last(where: { $0.path == path }) { actions.selectRun(latest.id) }
        } else {
            ui.composingRun = false
            ui.shellPlace = id
        }
    }

    /// A worker's request chosen in Needs you is answered where it always is: the wall comes
    /// back and the request opens exactly as Next request opens it. A network request opens on
    /// its page: an approval in Approvals with its review beside it, an access request in
    /// Approvals, a friend request in People.
    private func openFromInbox(_ id: String, _ shell: ShellContext) {
        if let link = NetworkDeepLink(inboxID: id) {
            shell.actions.openLink(link)
            show(place: link.place)
            return
        }
        guard let request = content.pending.first(where: { $0.id == id }) else { return }
        ui.composingRun = false
        ui.shellPlace = LiveShell.wall
        open(request)
    }

    /// One answer to a network request. The network model does the work and says how it ended
    /// for this request alone: the row shows the outcome for a moment and then leaves, or says
    /// why the answer didn't go through and keeps its answers.
    private func decide(_ id: String, _ decision: NeedsYouDecision, in inbox: NeedsYouInbox, _ shell: ShellContext) {
        guard var item = inbox.items.first(where: { $0.id == id }), item.isPending, !ui.needsYouRunning.contains(id) else { return }
        let network = shell.network, answers = shell.actions.answers
        let work: @MainActor () async -> NetworkActionResult
        switch (item.kind, decision) {
        case (.networkApproval, .approved), (.networkApproval, .denied):
            guard let approval = network.approvals.first(where: { LiveShell.id($0) == id }) else { return }
            work = { await answers.decide(approval.item, approval.server, decision == .approved) }
        case (.accessRequest, .declined):
            guard let request = network.access.first(where: { LiveShell.id($0) == id }) else { return }
            work = { await answers.removeAccess(request.item, request.server, true) }
        case (.accessRequest, .inReview):
            // The grant sheet is the review. It opens beside the request in Approvals.
            guard let request = network.access.first(where: { LiveShell.id($0) == id }) else { return }
            if shell.actions.reviewAccess(request) { show(place: NetworkPlace.approvals) }
            return
        case (.friendRequest, .accepted), (.friendRequest, .declined):
            guard let friend = network.friendRequests.first(where: { LiveShell.id($0) == id }) else { return }
            if decision == .accepted {
                work = { await answers.acceptFriend(friend.request, friend.server) }
            } else {
                guard let decline = answers.declineFriend else { return }
                work = { await decline(friend.request, friend.server) }
            }
        default:
            return
        }
        ui.needsYouRunning.insert(id)
        ui.needsYouFailures[id] = nil
        Task {
            let result = await work()
            ui.needsYouRunning.remove(id)
            guard result.isDone else {
                ui.needsYouFailures[id] = result.reason
                return
            }
            // The network holds an answered approval or access request itself, with its outcome
            // (`ShellNetwork.answers`), so the window keeps no copy and adds no time of its own.
            guard item.kind == .friendRequest else { return }
            // A friend request leaves the network's list at once. The window shows its outcome
            // for as long as the network holds an answered row.
            item.decision = decision
            item.failure = nil
            ui.needsYouDecided.append(item)
            try? await Task.sleep(for: MultiplayerShareModel.answeredHold)
            ui.needsYouDecided.removeAll { $0.id == id }
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
                           shortcut: CockpitShortcuts.nextRequest.shortcut,
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
                share: MultiplayerShareLauncher.action(.repo(path: path, name: summary.project)),
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
                               shortcut: CockpitShortcuts.newRun.shortcut,
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
    /// system: ⌘1 coordinator, ⌘] zoom, ⌘[ return, and the shell's modes on ⌥⌘1 to ⌥⌘5. Each
    /// button only records its command; `perform` runs it from the page's current state, so a
    /// shortcut never acts on values captured when the window opened.
    private var shortcuts: some View {
        Group {
            // The shell's modes come before ⌘1.
            if shell != nil {
                ForEach(CockpitShortcuts.modes) { key in
                    Button(key.title) { ui.press(key.command) }.keyboardShortcut(key.shortcut)
                }
                // The window hears the mode keys itself too, before anything else can take one.
                CockpitModeKeys { ui.press($0) }
            }
            Button(CockpitShortcuts.focusCoordinator.title) { ui.press(.focusCoordinator) }
                .keyboardShortcut(CockpitShortcuts.focusCoordinator.shortcut)
            Button(CockpitShortcuts.zoomWorker.title) { ui.press(.zoomWorker) }
                .keyboardShortcut(CockpitShortcuts.zoomWorker.shortcut)
            Button(CockpitShortcuts.returnToWall.title) { ui.press(.returnToWall) }
                .keyboardShortcut(CockpitShortcuts.returnToWall.shortcut)
            // The live Attention row carries ⇧⌘A. A supplied navigation model has its own rows, so
            // the shortcut is kept here.
            if fixtureNavigation != nil || shell != nil {
                Button(CockpitShortcuts.nextRequest.title) { ui.press(.nextRequest) }
                    .keyboardShortcut(CockpitShortcuts.nextRequest.shortcut)
            }
            // The shell's New run row has no key of its own, so ⌘N is kept here.
            if shell != nil {
                Button(CockpitShortcuts.newRun.title) { ui.press(.newRun) }
                    .keyboardShortcut(CockpitShortcuts.newRun.shortcut)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Runs a key command against what the page shows now.
    private func perform(_ command: CockpitCommand) {
        switch command {
        case .mode(let index):
            guard let shell else { return }
            let navigation = shellNavigation(shell)
            let modes = navigation.modeItems
            guard modes.indices.contains(index) else { return }
            act(.selectMode(modes[index].mode.id), in: navigation, shell)
        case .focusCoordinator: focusCoordinator()
        case .zoomWorker: zoomFocused()
        case .returnToWall: returnToWall()
        case .nextRequest: nextRequest()
        // No run can start while the service is offline; `show` leaves the window where it is.
        case .newRun: if shell != nil { show(place: LiveShell.newRun) }
        }
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
                              stop: { ui.showingStopConfirmation = true },
                              share: content.runs.first { $0.id == run.id }.flatMap {
                                  MultiplayerShareLauncher.action(.repo(path: $0.path, name: $0.project))
                              })
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
                WallHeading(symbol: "terminal", title: "Coordinator")
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
        if let remoteID = ui.zoomedRemoteWorkerID {
            // A remote worker's output, read-only (network tray, increment 4 Watch).
            let remote = shell?.wall.remoteWorkers.first { $0.id == remoteID }
            let name = shell == nil
                ? MultiplayerModel.shared.share.remoteWorkers.first { $0.id == remoteID }?.agent ?? "Remote worker"
                : remote?.agent ?? "Remote worker"
            VStack(spacing: 0) {
                SectionBar {
                    WallCrumb(name: name, back: { returnToWall() }) { MultiplayerReadOnlyBadge() }
                } trailing: {
                    HStack(spacing: 12) {
                        // The hand-off's report, artifacts and thread are on its page.
                        if let remote, shell != nil {
                            Button("Open hand-off") { openWork(.handoff, request: remote.request, on: remote.server) }
                                .buttonStyle(ThemeButtonStyle(compact: true))
                                .help("Open this hand-off in Hand-offs: its report, what it left to apply, and its thread")
                        }
                        KeyHint(keys: "⌘[", title: "Return to wall") { returnToWall() }
                        AttentionPresentationMenu(selection: presentationChoice)
                    }
                }
                if let shell {
                    if let zoom = shell.wallActions.zoom {
                        zoom(remoteID) { ui.zoomedRemoteWorkerID = nil }
                    } else {
                        Color.clear.onAppear { ui.zoomedRemoteWorkerID = nil }
                    }
                } else {
                    MultiplayerRemoteWorkerZoomHost(model: .shared, workerID: remoteID) { ui.zoomedRemoteWorkerID = nil }
                }
            }
        } else if let zoomed = zoomed {
            VStack(spacing: 0) {
                SectionBar {
                    WallCrumb(name: zoomed.name, back: { returnToWall() })
                } trailing: {
                    HStack(spacing: 12) {
                        KeyHint(keys: "⌘[", title: "Return to wall") { returnToWall() }
                        AttentionPresentationMenu(selection: presentationChoice)
                    }
                }
                tile(zoomed, variant: .focused)
                    .coordinateSpace(.named(ConsoleVisibility.viewport))
                controlDock(for: zoomed)
            }
        } else {
            let count = run.wall.workers.count
            VStack(spacing: 0) {
                SectionBar {
                    WallHeading(symbol: "square.grid.2x2", title: "Worker wall", count: count > 0 ? count : nil)
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
                    // The dock sits under the tile, outside its shell.
                    VStack(spacing: 0) {
                        tile(worker, variant: .wall).frame(maxWidth: .infinity, maxHeight: .infinity)
                        controlDock(for: worker)
                    }
                }
                remoteBand
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

    /// Hand-offs running on friends' Macs, as remote workers, and the reviews and fan-outs that
    /// still need a look. The redesigned shell draws them from values in the wall's own frame;
    /// without it the network's own band stands in.
    @ViewBuilder private var remoteBand: some View {
        if let shell {
            let wall = shell.wall
            Group {
                if !wall.remoteWorkers.isEmpty || !wall.work.isEmpty {
                    WallRemoteBand(workers: wall.remoteWorkers, work: wall.work, now: wall.now,
                                   zoom: { worker in
                                       ui.zoomedWorkerID = nil
                                       ui.zoomedRemoteWorkerID = worker.id
                                   },
                                   openHandoffs: { show(place: NetworkPlace.handoffs) },
                                   openWork: { item in openWork(item.kind, request: item.request, on: item.server) })
                        .padding(.top, Metric.wallRowGap)
                        .transition(.opacity)
                }
            }
            .animation(theme.motion.animation(theme.motion.standard), value: wall.remoteWorkers.isEmpty && wall.work.isEmpty)
            .onAppear { shell.wallActions.appeared() }
            .onDisappear { shell.wallActions.disappeared() }
        } else {
            MultiplayerRemoteWorkerBand(model: .shared) { worker in
                ui.zoomedWorkerID = nil
                ui.zoomedRemoteWorkerID = worker.id
            }
        }
    }

    /// Who holds control of this worker and what a friend suggests for it, under its tile.
    @ViewBuilder private func controlDock(for worker: WorkerPresentation) -> some View {
        if let shell {
            let wall = shell.wall
            WallControlDock(controls: wall.controls(forWorker: worker.id), suggestions: wall.suggestions(forWorker: worker.id),
                            now: wall.now, isBusy: wall.isBusy,
                            takeBack: { control in shell.wallActions.takeBack(control) },
                            openShared: { show(place: NetworkPlace.shared) },
                            review: { suggestion in
                                shell.actions.openLink(.approval(id: suggestion.approval, server: suggestion.server))
                                show(place: NetworkPlace.approvals)
                            })
        }
    }

    /// Opens a hand-off, a review or a fan-out in the network and goes to the page that shows it.
    private func openWork(_ kind: MultiplayerRemoteWork.Kind, request: String, on server: String) {
        guard let shell else { return }
        shell.wallActions.openWork(kind, request, server)
        show(place: WallLiveWork.place(for: kind))
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
                            show: { request in ui.show(requestID: request.id) },
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
        // The worker's further requests, by ID. Repeated presses step past the one already shown.
        let further = worker.allRequests.dropFirst()
        let openFurtherRequest: (() -> Void)? = (further.first { $0.id != ui.activeRequestID } ?? further.first)
            .map { request in { open(request) } }
        // The exact pending request a queued follow-up waits for, through the same ID routing: its
        // inline form when it is the one shown there, otherwise Attention. Never Next request.
        let openFollowUpBlocker: (() -> Void)? = worker.followUpReceipts?.blockingRequest
            .map { request in { open(request) } }
        // One mapping for every surface of a worker (wall tile, focused view, action list). Each
        // action is offered only where it exists and the service says it applies to this worker
        // now; every closure is bound to this worker's ID.
        let held = worker.control == .held
        // An exited or checking Claude adapter offers no take control, handback, interrupt or
        // follow-up. One gate decides taking and returning control, read from the same policy as
        // the model, so fixtures without model gates agree with the live app. Stop and passive
        // source remain.
        let controlAllowed = ProviderAvailability.allowsControl(worker.providerAvailability)
        let canControl = controlAllowed && (actions.canControlWorker?(worker.id) ?? true)
        let canInterrupt = controlAllowed && (actions.canInterruptWorker?(worker.id) ?? true)
        let canStop = actions.canStopWorker?(worker.id) ?? true
        let handBack: (() -> Void)? = held && canControl
            ? actions.handBack.map { handBack in { handBack(worker.id) } } : nil
        let sendInput: ((String) async -> Bool)? = controlAllowed ? actions.sendFollowUp.map { send in
            { text in await send(worker.id, text) }
        } : nil
        let followUpContext = sendInput == nil ? nil : followUpContextAccess(worker)
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
            openFurtherRequest: openFurtherRequest,
            openFollowUpBlocker: openFollowUpBlocker,
            copyID: { copy(worker.id) },
            handBack: handBack,
            sendInput: sendInput,
            followUpContext: followUpContext,
            isBusy: actions.workerIsBusy?(worker.id) ?? false,
            viewAssignment: showWorker,
            followUp: followUp,
            takeControl: takeControl,
            interrupt: interrupt,
            stop: stop,
            share: MultiplayerShareLauncher.action(.agent(id: worker.id, name: worker.name)))
        let menuPresented: Binding<Bool>? = rich ? Binding(
            get: { ui.actionMenuWorkerID == worker.id },
            set: { open in
                if open { ui.actionMenuWorkerID = worker.id }
                else if ui.actionMenuWorkerID == worker.id { ui.actionMenuWorkerID = nil }
            }) : nil
        return WorkerTile(worker: worker, variant: variant, isKeyFocused: paneFocus == worker.id,
                          reply: variant == .focused ? replyContext : nil, actions: tileActions,
                          menuPresented: menuPresented, source: sourceAccess(worker),
                          providerSession: providerSessionAccess(worker),
                          elicitations: elicitationAccess(worker))
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
            copy: { text in copy(text) },
            follow: { intents.follow?() },
            // Changes when the worker gains an entry or changes state, not as text streams into
            // an entry, so the open source is checked for new records at that pace.
            revision: "\(worker.transcript.count) \(worker.state)")
        return ConsoleSourceAccess(workerName: worker.name, client: worker.client, session: session,
                                   open: { ui.presentSource(of: id) }, panel: panel)
    }

    /// File context for a worker's focused follow-up, bound to that worker's checkout and the
    /// prompt content its session accepts. Nil where the session or the service offers none.
    private func followUpContextAccess(_ worker: WorkerPresentation) -> FollowUpContextAccess? {
        guard let scope = worker.followUpContextScope, let sendContext = actions.sendFollowUpWithContext,
              let prepare = actions.prepareFollowUpContext else { return nil }
        let id = worker.id
        return FollowUpContextAccess(
            linkUnavailable: scope.linkUnavailableReason,
            snapshotUnavailable: scope.snapshotUnavailableReason,
            prepare: { url, kind in prepare(url, kind, scope) },
            send: { text, context in await sendContext(id, text, context) })
    }

    /// Provider-session access for a worker console: a wall tile or the focused worker. Nil for a
    /// worker without a bound session and where the service offers none. The reading is handed
    /// over only when it is this worker's, and reattach always names this worker.
    private func providerSessionAccess(_ worker: WorkerPresentation) -> ProviderSessionAccess? {
        guard !worker.isCoordinator, let session = worker.session, let intents = actions.providerSession else { return nil }
        let id = worker.id
        let isPresented = Binding(
            get: { ui.providerSessionWorkerID == id },
            set: { shown in
                if shown { ui.providerSessionWorkerID = id }
                else if ui.providerSessionWorkerID == id { ui.providerSessionWorkerID = nil }
            })
        let panel = ProviderSessionAccess.Panel(
            isPresented: isPresented,
            inspection: intents.inspection().flatMap { $0.workerID == id ? $0 : nil },
            refresh: { intents.refresh() },
            discover: { intents.discover() },
            loadMore: { intents.loadMore() },
            reattach: { acknowledge in intents.reattach(id, acknowledge) },
            copy: { text in copy(text) })
        return ProviderSessionAccess(workerID: id, workerName: worker.name, client: worker.client, session: session,
                                     open: { ui.presentProviderSession(of: id) }, panel: panel)
    }

    /// Input-request access for a worker console: a wall tile or the focused worker. Nil for a
    /// worker without a bound session and where the service offers none. The reading is handed
    /// over only when it is this worker's, and every reply and open names this worker; the model
    /// checks each against the worker's bound session.
    private func elicitationAccess(_ worker: WorkerPresentation) -> ElicitationAccess? {
        guard !worker.isCoordinator, let session = worker.session, let intents = actions.elicitations else { return nil }
        let id = worker.id
        let isPresented = Binding(
            get: { ui.elicitationWorkerID == id },
            set: { shown in
                if shown { ui.elicitationWorkerID = id }
                else if ui.elicitationWorkerID == id { ui.elicitationWorkerID = nil }
            })
        let panel = ElicitationAccess.Panel(
            isPresented: isPresented,
            inspection: intents.inspection().flatMap { $0.workerID == id ? $0 : nil },
            refresh: { intents.refresh() },
            edit: { elicitationID, field, value in intents.edit(elicitationID, field, value) },
            reply: { elicitationID, action in intents.reply(id, elicitationID, action) },
            open: { elicitationID in intents.open(id, elicitationID) },
            copy: { text in copy(text) })
        return ElicitationAccess(workerID: id, workerName: worker.name, client: worker.client, session: session,
                                 open: { ui.presentElicitations(of: id) }, panel: panel)
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
        if ui.usesFloatingPanel, requestID != content.shownInlineRequestID(ui) {
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
        ui.reachedRequestID = request.id
        focusReply(request.id)
    }

    /// A deliberate step through every pending request by ID (see `AttentionNavigation`),
    /// including a second request from the focused or a visible worker and ones left out of the
    /// attention surfaces because their console is in view.
    private func nextRequest() {
        // Requests are answered beside the wall, so Next request brings it back.
        if !content.pending.isEmpty, ui.wallHidden { ui.shellPlace = LiveShell.wall }
        ui.drawerClosed = false
        let answering = replyFocus.flatMap { id in content.pending.contains { $0.id == id } ? id : nil }
        let navigation = content.attentionNavigation(ui, answering: answering)
        if navigation.candidates.restoresDismissed { ui.dismissedRequests.removeAll() }
        switch navigation.target {
        case .attention(let id):
            ui.surfacedRequests.insert(id)
            ui.activeRequestID = id
            ui.reachedRequestID = id
            focusReply(id)
        case .inline(let id):
            // The focused worker's own form answers it; Attention keeps showing the others.
            ui.reachedRequestID = id
            focusReply(id)
        case .none:
            break
        }
    }

    private func showNext(after request: RequestPresentation) {
        let queue = stack
        guard queue.count > 1, let index = queue.firstIndex(where: { $0.id == request.id }) else { return }
        ui.show(requestID: queue[(index + 1) % queue.count].id)
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
            ui.zoomedRemoteWorkerID = nil
            ui.zoomedWorkerID = workerID
            ui.returnFocusWorkerID = workerID
            refocus(workerID)
        }
    }

    private func returnToWall() {
        if ui.zoomedRemoteWorkerID != nil { ui.zoomedRemoteWorkerID = nil; return }
        guard let workerID = ui.zoomedWorkerID else { return }
        ui.zoomedWorkerID = nil
        ui.returnFocusWorkerID = workerID
        refocus(workerID)
    }

    private func zoomFocused() {
        guard let run else { return }
        if ui.zoomedWorkerID != nil || ui.zoomedRemoteWorkerID != nil { returnToWall(); return }
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
        if ui.zoomAfterSelection != nil { ui.zoomedRemoteWorkerID = nil }
        ui.zoomedWorkerID = ui.zoomAfterSelection
        ui.zoomAfterSelection = nil
        ui.collapsedGroups.removeAll()
        ui.showingRunDetails = false
        ui.sourceInspectorWorkerID = nil
        // A panel left open on the previous run's worker would keep reading it out of view.
        ui.elicitationWorkerID = nil
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
        if let reached = ui.reachedRequestID, !live.contains(reached) { ui.reachedRequestID = nil }
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
    @Environment(NativeTerminalLedger.self) private var nativeTerminals: NativeTerminalLedger?
    let model: CockpitModel
    /// The network tray's model. The main window reads it and calls its intents; it owns nothing
    /// of the network's.
    private let network = MultiplayerModel.shared
    @State private var ui = CockpitView.initialState()
    /// The floating window for the PiP presentation. It lives as long as the live page.
    @State private var floatingPanel: FloatingAttentionController?
    /// This window's place with the open-in-window router, while it shows.
    @State private var routerAttachment: Int?

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
        CockpitScreen(content: CockpitContent(model: model), ui: ui, actions: actions,
                      adapterUpdates: model.adapterUpdates,
                      shell: ShellContext(network: ShellNetwork(model: network), actions: networkActions,
                                          networkPage: { place, go in
                                              AnyView(LiveNetworkPage(place: place, model: network, state: ui.networkPages, go: go,
                                                                      openPanel: networkActions.openNetworkPanel))
                                          },
                                          teamsPage: { place, go in
                                              AnyView(LiveTeamsPage(place: place, model: network, state: ui.teamsPages, go: go,
                                                                    share: { resource, server in
                                                                        // The grant sheet is the network pages' own, on Shared.
                                                                        guard networkActions.answers.prepareGrant(server, nil, resource, []) else { return }
                                                                        ui.networkPages.selection.grant = server
                                                                        go(NetworkPlace.shared)
                                                                    }))
                                          },
                                          // The wall's live work, read from the network model as values.
                                          wall: WallLiveWork(model: network, workers: CockpitContent(model: model).selected?.wall.workers.map(\.id) ?? []),
                                          wallActions: .live(network, pages: ui.networkPages),
                                          hosts: CommanderHostsContext(
                                              entries: model.hosts.entries(local: .init(model.connection)),
                                              listError: model.hosts.listError,
                                              use: { model.hosts.use($0) },
                                              refresh: { await model.hosts.refresh() })))
            // Both subscriptions start again when the service changes, on the new socket.
            .task(id: model.serviceGeneration) { await model.follow() }
            // The window is one more viewer of the network model: it polls while the window shows.
            .onAppear { network.open() }
            .onDisappear { network.close() }
            // The tray's "Open in Agent Commander" arrives here (CommanderWindowRouter.swift). A
            // request sent while the window was closed is handed over as it reopens.
            .onAppear {
                let ui = ui, network = network
                routerAttachment = CommanderWindowRouter.shared.attach { request in
                    let places = LiveShell.places(network: ShellNetwork(model: network))
                    request.destination(in: CommanderOpenCatalog(places: places, model: network)).show(in: ui, model: network)
                }
            }
            .onDisappear {
                if let routerAttachment { CommanderWindowRouter.shared.detach(routerAttachment) }
                routerAttachment = nil
            }
            // Its own task: a missing or old catalog endpoint never holds up the workspace feed.
            .task(id: model.serviceGeneration) { await model.adapterUpdates.follow() }
            .onAppear {
                guard floatingPanel == nil else { return }
                let controller = FloatingAttentionController(model: model, ui: ui, actions: actions, consoleModes: consoleModes,
                                                             nativeTerminals: nativeTerminals)
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

    /// The network intents the shell may ask for: the same model methods the tray calls.
    private var networkActions: ShellNetworkActions {
        let network = network
        var panel: (@MainActor () -> Void)?
        if network.client != nil { panel = { MultiplayerLinkWindow.show(network) } }
        return ShellNetworkActions(
            setPresence: { choice in _ = network.setPresence(choice) },
            answers: .live(network),
            openNetworkPanel: panel,
            // The window opens the approval on its own page. The tray stays where it is.
            openLink: { link in
                if case .approval(let id, let server) = link { ui.networkPages.open(.share(server, .approval(id))) }
            },
            reviewAccess: { pending in
                // Fills the grant sheet from the request; Approvals then hosts it beside the request.
                guard network.share.prepareGrant(on: pending.server, handle: pending.item.requester,
                                                 resourceID: pending.item.resource, actions: Set(pending.item.actions)) else { return false }
                ui.networkPages.selection.grant = pending.server
                return true
            })
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
            sendFollowUpWithContext: { workerID, text, context in
                await model.sendFollowUp(to: workerID, text: text, context: context)
            },
            // The chosen file is read on this Mac, for the named worker's scope only.
            prepareFollowUpContext: { url, kind, scope in FollowUpContextReader.prepare(url, kind: kind, scope: scope) },
            // Status, discovery and reattach name the worker only. The model owns every request.
            providerSession: model.providerSessionIntents,
            // Input requests name the worker; the model checks its bound session and owns replies.
            elicitations: model.elicitationIntents,
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
                retry: { model.source.retry() },
                follow: { model.source.follow() }),
            // Entry fields come from the state the app already holds, for the named worker only.
            recordDetail: { workerID, entryID in model.recordDetail(workerID: workerID, entryID: entryID) },
            // A prompt's media is read by its own worker and turn. The model owns the read.
            promptAttachments: model.promptAttachmentIntents)
    }
}
