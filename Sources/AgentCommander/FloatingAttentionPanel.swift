import AppKit
import Observation
import SwiftUI

// ATOMIC LEVEL: Page (window host).
//
//   FloatingAttentionController  owns one floating NSPanel for the PiP presentation in the live app.
//     FloatingAttentionRoot      the panel's page: the same AttentionStack organism the in-window
//                                PiP renders, fed from the same request queue and drafts.
//
// The panel floats above normal windows, stays up while another app is active or the cockpit
// window is minimized, and is dragged by its header's title area. It is ordered in without becoming key, so
// a request that arrives never takes the keyboard. Its position is kept across launches and is
// moved back onto a screen when the saved place is no longer visible.

/// A borderless panel that can take the keyboard for its reply field, without ever becoming the
/// app's main window.
final class AttentionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingAttentionController: NSObject, NSWindowDelegate {
    /// Clear space around the stack inside the panel, so its shadow is not cut off.
    static let margin: CGFloat = 36
    /// Tallest the stack is drawn before its content scrolls: the next-request card, the header,
    /// the title bar, recent output, a long question, a four-line reply and the status line.
    static let stackHeight: CGFloat = 430
    /// The panel's one size. The stack sits at its top; the rest is clear and passes clicks through.
    static let panelSize = NSSize(width: Metric.pipWidth + margin * 2, height: stackHeight + margin * 2)
    /// Where the panel's top-left corner was last left, in screen coordinates.
    private static let placementKey = "attentionPiPTopLeft"

    private let model: CockpitModel
    private let consoleModes: ConsoleModeStore
    private let ui: CockpitPresentationState
    private let actions: CockpitActions
    private var panel: AttentionPanel?
    private var isTracking = false
    /// True while the controller itself moves the panel, so those moves are not saved as the
    /// developer's placement.
    private var isPlacing = false

    init(model: CockpitModel, ui: CockpitPresentationState, actions: CockpitActions, consoleModes: ConsoleModeStore) {
        self.consoleModes = consoleModes
        self.model = model
        self.ui = ui
        self.actions = actions
        super.init()
    }

    func start() {
        guard !isTracking else { return }
        isTracking = true
        ui.bringFloatingPanelForward = { [weak self] in self?.bringForward() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        // AppKit reorders an app's windows when one is minimized or restored and when the app
        // gains or loses activation, and that can take an already showing panel off screen.
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowOrderingChanged(_:)),
                                                   name: name, object: nil)
        }
        track()
    }

    /// After a minimize, restore or activation change, puts the existing panel back in front if a
    /// request still calls for it. It is checked right away and again after the Dock animation has
    /// finished, because the system's own reordering lands at different moments. The same panel is
    /// reordered; it is not moved, resized, made key or recreated, and the app is not activated.
    @objc private func windowOrderingChanged(_ notification: Notification) {
        // The panel's own notifications are not a reason to reorder it.
        if let window = notification.object as? NSWindow, window === panel { return }
        Task { @MainActor [weak self] in
            for delay in [60, 700, 1500] {
                try? await Task.sleep(for: .milliseconds(delay))
                self?.reassert()
            }
        }
    }

    private func reassert() {
        guard isTracking, wantsPanel, let panel else { return }
        // `isVisible` can still read true for a panel the window server no longer shows, so the
        // panel is ordered front whatever it reports. It is placed only if it was really out.
        if !panel.isVisible { place(panel) }
        panel.orderFrontRegardless()
    }

    func stop() {
        isTracking = false
        ui.bringFloatingPanelForward = nil
        NotificationCenter.default.removeObserver(self)
        panel?.orderOut(nil)
    }

    // MARK: Visibility

    /// The panel shows while the PiP presentation is chosen and a request is waiting that no
    /// other surface is answering.
    private var wantsPanel: Bool {
        ui.usesFloatingPanel && !CockpitContent(model: model).attentionQueue(ui).isEmpty
    }

    /// Follows the model and the presentation state directly, so the panel appears and goes
    /// whatever the cockpit window is doing (minimized, hidden behind another app).
    private func track() {
        guard isTracking else { return }
        let visible = withObservationTracking {
            wantsPanel
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        setVisible(visible)
    }

    private func setVisible(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        guard !panel.isVisible else { return }
        place(panel)
        // In front of other apps' windows, without activating this app or taking the keyboard.
        panel.orderFrontRegardless()
    }

    private func makePanel() -> AttentionPanel {
        let root = FloatingAttentionRoot(model: model, ui: ui, actions: actions,
                                         reveal: { [weak self] request in self?.reveal(request) },
                                         dragEnded: { [weak self] in self?.savePlacement() })
            .environment(consoleModes)
            .preferredColorScheme(.dark)
        let host = NSHostingController(rootView: AnyView(root))
        // The panel has one fixed size and the hosting view never resizes the window. Letting the
        // content drive the window size made layout and window resizing feed each other without end.
        host.sizingOptions = []

        let size = Self.panelSize
        let panel = AttentionPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.setContentSize(size)
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.title = "Needs attention"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Moved only by the header's drag handle (WindowDragHandle). Background dragging is off:
        // it was not reliable through the hosting view, and the transcript, the buttons and the
        // reply field must keep their own mouse behavior.
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        self.panel = panel
        return panel
    }

    // MARK: Placement

    private func place(_ panel: NSPanel) {
        isPlacing = true
        defer { isPlacing = false }
        if let saved = UserDefaults.standard.string(forKey: Self.placementKey) {
            panel.setFrameTopLeftPoint(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            // First run: the lower trailing corner of the main screen, where the in-window PiP sits.
            let area = screen.visibleFrame
            let size = Self.panelSize
            // The stack is top-aligned in the panel and is typically about 330 pt tall, so the
            // panel starts a little below the screen's edge to bring the stack near the corner.
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 20 + Self.margin,
                                         y: area.minY + 42 - Self.margin - (Self.stackHeight - 330)))
        }
        recover(panel)
    }

    /// Moves the panel back inside a screen when it is partly or wholly outside every one, for
    /// example after a display was unplugged. The saved placement is left as it was, so the panel
    /// returns there when that display comes back. Called only when the panel is shown and when
    /// the displays change, never from a layout or resize callback.
    private func recover(_ panel: NSPanel) {
        let frame = panel.frame
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.visibleFrame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let nearest = NSScreen.screens.max(by: { overlap($0) < overlap($1) }) else { return }
        let screen = overlap(nearest) > 0 ? nearest : (NSScreen.main ?? nearest)
        // The clear margin around the stack may hang past the edge; the stack itself may not.
        let area = screen.visibleFrame.insetBy(dx: -Self.margin, dy: -Self.margin)
        var origin = frame.origin
        origin.x = max(area.minX, min(origin.x, area.maxX - frame.width))
        // The stack sits at the top of the panel and is usually shorter than it, so the clear
        // lower part may hang below the screen as long as a usable height of the stack stays on it.
        let lowest = area.minY - (Self.stackHeight - 220)
        origin.y = max(lowest, min(origin.y, area.maxY - frame.height))
        guard origin != frame.origin else { return }
        let wasPlacing = isPlacing
        isPlacing = true
        panel.setFrameOrigin(origin)
        isPlacing = wasPlacing
    }

    @objc private func screensChanged(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        place(panel)
    }

    /// Saves where the developer left the panel. Called once, when a drag of the header handle
    /// ends. Showing the panel, screen recovery and display changes never write the placement.
    private func savePlacement() {
        guard let panel else { return }
        let frame = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)),
                                  forKey: Self.placementKey)
    }

    // MARK: Intents

    /// A deliberate move to a reply in the panel (View request, Next request). The panel becomes
    /// key so its field can take typing; the app itself is not activated.
    private func bringForward() {
        guard wantsPanel else { return }
        setVisible(true)
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Opens the source run and worker of a request in the cockpit window and brings that window
    /// forward, restoring it from the Dock if it was minimized.
    private func reveal(_ request: RequestPresentation) {
        let select = actions.selectRun
        ui.reveal(request, from: CockpitContent(model: model).selected, selectRun: { id in select(id) })
        NSApp.activate()
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

/// The part of a floating window that moves it. It follows each mouse event in screen coordinates:
/// the window's origin moves by exactly the pointer's travel since the press, so the grabbed spot
/// stays under the pointer. It takes the first click, so the window can be dragged while another
/// app is active, and it never activates this app. It draws nothing.
struct WindowDragHandle: NSViewRepresentable {
    /// Called once when a drag that moved the window ends.
    let onEnd: () -> Void

    final class Handle: NSView {
        var onEnd: (() -> Void)?
        private var pressPoint: NSPoint?
        private var pressOrigin = NSPoint.zero
        private var moved = false

        // This view moves the window itself; AppKit's own background dragging stays out of it.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // The pointer's place comes from each delivered event, converted to screen coordinates.
        // The hardware pointer is never read, so real input and delivered synthetic events move
        // the window the same way.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            pressPoint = window.convertPoint(toScreen: event.locationInWindow)
            pressOrigin = window.frame.origin
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let pressPoint else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            let origin = NSPoint(x: (pressOrigin.x + pointer.x - pressPoint.x).rounded(),
                                 y: (pressOrigin.y + pointer.y - pressPoint.y).rounded())
            guard origin != window.frame.origin else { return }
            window.setFrameOrigin(origin)
            moved = true
        }

        override func mouseUp(with event: NSEvent) {
            if moved { onEnd?() }
            pressPoint = nil
            moved = false
        }
    }

    func makeNSView(context: Context) -> Handle {
        let handle = Handle()
        handle.onEnd = onEnd
        handle.setAccessibilityElement(true)
        handle.setAccessibilityRole(.handle)
        handle.setAccessibilityLabel("Move the Needs attention panel")
        handle.setAccessibilityHelp("Drag to move the panel. Its position is kept.")
        return handle
    }

    func updateNSView(_ handle: Handle, context: Context) { handle.onEnd = onEnd }
}

/// The floating panel's page. It renders the shared AttentionStack from the same queue, drafts and
/// active request as the cockpit window, so a draft follows its request between the two. Keyboard
/// focus is this window's own.
struct FloatingAttentionRoot: View {
    let model: CockpitModel
    @Bindable var ui: CockpitPresentationState
    let actions: CockpitActions
    let reveal: (RequestPresentation) -> Void
    /// The developer finished dragging the panel by its header.
    let dragEnded: () -> Void

    @FocusState private var replyFocus: String?

    var body: some View {
        let content = CockpitContent(model: model)
        let queue = content.attentionQueue(ui)
        let current = queue.first { $0.id == ui.activeRequestID } ?? queue.first
        Group {
            if let current {
                // The stack at its own height when it fits the panel; otherwise the same stack
                // scrolls inside the panel's fixed height. The window is never resized.
                ViewThatFits(in: .vertical) {
                    stack(current, queue: queue, content: content)
                    ScrollView(.vertical) { stack(current, queue: queue, content: content) }
                }
            }
        }
        .frame(width: Metric.pipWidth, height: FloatingAttentionController.stackHeight, alignment: .top)
        .padding(FloatingAttentionController.margin)
        .onChange(of: ui.floatingReplyFocus) { _, requestID in
            guard let requestID else { return }
            ui.floatingReplyFocus = nil
            Task {
                // After the panel is key and the request's field is in place.
                try? await Task.sleep(for: .milliseconds(120))
                replyFocus = requestID
            }
        }
    }

    private func stack(_ current: RequestPresentation, queue: [RequestPresentation],
                       content: CockpitContent) -> some View {
        let index = queue.firstIndex { $0.id == current.id } ?? 0
        return AttentionStack(current: current,
                              next: queue.count > 1 ? queue[(index + 1) % queue.count] : nil,
                              position: index + 1, count: queue.count,
                              reply: replyContext(content),
                              showNext: { ui.activeRequestID = queue[(index + 1) % queue.count].id },
                              expand: { reveal(current) },
                              close: { close(current) },
                              dragHandle: AnyView(WindowDragHandle(onEnd: dragEnded)),
                              // The floating stack points to the worker's console in the cockpit
                              // window, which is brought forward and opens the inspector there.
                              source: ui.sourcePointer(for: current, intents: actions.source,
                                                       reveal: { reveal(current) }))
    }

    private func replyContext(_ content: CockpitContent) -> ReplyContext {
        ReplyContext(
            draft: { id in Binding(get: { ui.drafts[id] ?? "" }, set: { ui.drafts[id] = $0 }) },
            focus: $replyFocus,
            sending: content.sending,
            isOnline: content.connection == .online,
            send: { request in send(request) })
    }

    /// Answers exactly this request by ID with its own draft.
    private func send(_ request: RequestPresentation) {
        let text = ui.drafts[request.id] ?? ""
        guard !request.isWorkerDisconnected,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await actions.reply(request.id, text) {
                ui.drafts[request.id] = nil
                if replyFocus == request.id { replyFocus = nil }
            }
        }
    }

    private func close(_ request: RequestPresentation) {
        ui.dismissedRequests.insert(request.id)
        ui.surfacedRequests.remove(request.id)
        if replyFocus == request.id { replyFocus = nil }
    }
}
