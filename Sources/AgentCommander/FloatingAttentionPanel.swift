import AppKit
import Observation
import SwiftUI

// ATOMIC LEVEL: Page (window host).
//
//   FloatingAttentionController  owns one floating NSPanel for the PiP presentation in the live app.
//     FloatingAttentionRoot      the panel's page: the same AttentionStack organism the in-window
//                                PiP renders, fed from the same request queue and drafts.
//
//     FloatingPiPGeometry        plain sizing rules: minimum, default, per-screen maximum, edge resize.
//     WindowDragHandle           atom: the header's title area, which moves the window.
//     WindowResizeHandle         atom: one edge or corner zone, which resizes the window.
//     ResizeGrip                 atom: the visible corner mark that says the panel can be resized.
//     WindowResizeFrame          molecule: the eight resize zones and the grip around the stack.
//
// The panel floats above normal windows, stays up while another app is active or the cockpit
// window is minimized, and is dragged by its header's title area. It is ordered in without becoming key, so
// a request that arrives never takes the keyboard. Its edges and corners resize it, and the extra
// room goes to the conversation. Its position and its size are kept across launches under separate
// keys; both are fitted back onto a screen when the saved place is no longer visible or too small.
//
// Only the controller sizes the window, and only from a resize drag or a placement. SwiftUI reads
// the size it is given and never reports a size back, so layout and window frame cannot feed
// each other.

/// A borderless panel that can take the keyboard for its reply field, without ever becoming the
/// app's main window.
final class AttentionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The edges a resize zone moves.
struct ResizeEdges: OptionSet, Hashable {
    let rawValue: Int
    static let top = ResizeEdges(rawValue: 1 << 0)
    static let bottom = ResizeEdges(rawValue: 1 << 1)
    static let left = ResizeEdges(rawValue: 1 << 2)
    static let right = ResizeEdges(rawValue: 1 << 3)
}

/// Sizing rules for the floating PiP, as plain values so they can be checked without a window.
/// "Stack" is the visible card; "panel" is the window, which adds a clear margin on every side.
enum FloatingPiPGeometry {
    /// Clear space around the stack inside the panel, so its shadow is not cut off.
    static let margin: CGFloat = 36
    /// The stack's size before it could be resized: the compact PiP width and the tallest it was
    /// drawn before scrolling.
    static let compactStack = NSSize(width: Metric.pipWidth, height: 430)
    /// The first size, before the developer chooses one: twice the compact stack each way.
    static let defaultStack = NSSize(width: compactStack.width * 2, height: compactStack.height * 2)
    /// Smallest the stack is resized to: the compact width, and room for the header, title bar,
    /// the compact conversation, a short question and the status line.
    static let minimumStack = NSSize(width: Metric.pipWidth, height: 360)
    /// The conversation never gets less than the compact PiP's.
    static let minimumConversation: CGFloat = 92
    /// Space kept between the stack and the edges of the screen's visible area.
    static let screenInset: CGFloat = 16

    /// Largest the stack may be on a screen with this visible area. Never below the minimum.
    static func maximumStack(in visible: NSRect) -> NSSize {
        NSSize(width: max(minimumStack.width, (visible.width - screenInset * 2).rounded(.down)),
               height: max(minimumStack.height, (visible.height - screenInset * 2).rounded(.down)))
    }

    /// A stack size clamped between the minimum and that screen's maximum.
    static func fitted(_ stack: NSSize, in visible: NSRect) -> NSSize {
        let maximum = maximumStack(in: visible)
        return NSSize(width: min(max(stack.width, minimumStack.width), maximum.width).rounded(),
                      height: min(max(stack.height, minimumStack.height), maximum.height).rounded())
    }

    static func panelSize(stack: NSSize) -> NSSize {
        NSSize(width: stack.width + margin * 2, height: stack.height + margin * 2)
    }

    static func stackSize(panel: NSSize) -> NSSize {
        NSSize(width: panel.width - margin * 2, height: panel.height - margin * 2)
    }

    /// The panel frame after its `edges` have moved by `translation` (screen points, y up) from
    /// `start`. The opposite edges stay put. Each moved edge stops at the minimum stack size and
    /// at `screenInset` from the visible area's edge, but an edge already past that line is never
    /// pulled in by the first movement.
    static func resized(_ start: NSRect, edges: ResizeEdges, by translation: CGSize, visible: NSRect) -> NSRect {
        let bounds = visible.insetBy(dx: screenInset - margin, dy: screenInset - margin)
        let least = panelSize(stack: minimumStack)
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            min(max(value, low), max(low, high)).rounded()
        }
        if edges.contains(.right) {
            maxX = clamp(start.maxX + translation.width, start.minX + least.width, max(bounds.maxX, start.maxX))
        }
        if edges.contains(.left) {
            minX = clamp(start.minX + translation.width, min(bounds.minX, start.minX), start.maxX - least.width)
        }
        if edges.contains(.top) {
            maxY = clamp(start.maxY + translation.height, start.minY + least.height, max(bounds.maxY, start.maxY))
        }
        if edges.contains(.bottom) {
            minY = clamp(start.minY + translation.height, min(bounds.minY, start.minY), start.maxY - least.height)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The conversation's height in a stack of `stackHeight`, given the height of everything else
    /// in the stack. Never below the compact conversation; the stack scrolls when that overflows.
    static func conversationHeight(stackHeight: CGFloat, chrome: CGFloat) -> CGFloat {
        max(minimumConversation, (stackHeight - chrome).rounded(.down))
    }
}

@MainActor
final class FloatingAttentionController: NSObject, NSWindowDelegate {
    private typealias Geometry = FloatingPiPGeometry
    /// Where the panel's top-left corner was last left, in screen coordinates.
    private static let placementKey = "attentionPiPTopLeft"
    /// The stack size the developer last chose by resizing, kept apart from the placement.
    private static let sizeKey = "attentionPiPStackSize"

    private let model: CockpitModel
    private let consoleModes: ConsoleModeStore
    /// Inline terminal status, shared with the main window so the PiP agrees with the wall.
    private let nativeTerminals: NativeTerminalLedger?
    private let ui: CockpitPresentationState
    private let actions: CockpitActions
    private var panel: AttentionPanel?
    private var isTracking = false
    /// True while the controller itself moves the panel, so those moves are not saved as the
    /// developer's placement.
    private var isPlacing = false
    /// The frame and screen area a resize drag started from; nil when no resize is under way.
    private var resizeStart: (frame: NSRect, visible: NSRect)?

    init(model: CockpitModel, ui: CockpitPresentationState, actions: CockpitActions, consoleModes: ConsoleModeStore,
         nativeTerminals: NativeTerminalLedger? = nil) {
        self.consoleModes = consoleModes
        self.nativeTerminals = nativeTerminals
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
                                         dragEnded: { [weak self] in self?.moveEnded() },
                                         resize: WindowResizeIntents(
                                            began: { [weak self] in self?.resizeBegan() },
                                            changed: { [weak self] edges, delta in self?.resizeChanged(edges, by: delta) },
                                            ended: { [weak self] in self?.resizeEnded() }))
            .environment(consoleModes)
            .environment(model.toolDetails)
            .environment(model.compactions)
            .environment(model.replyAttachments)
            .environment(nativeTerminals)
            .preferredColorScheme(.dark)
        let host = NSHostingController(rootView: AnyView(root))
        // Only the controller sizes the panel; the hosting view never resizes the window or
        // constrains it. Letting the content drive the window size made layout and window
        // resizing feed each other without end.
        host.sizingOptions = []

        let size = Geometry.panelSize(stack: Geometry.defaultStack)
        // Borderless without `.resizable`: the window's own edges are in the clear margin, which
        // passes clicks through, so resizing is done by the zones on the stack's edges instead.
        let panel = AttentionPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.setContentSize(size)
        panel.contentMinSize = Geometry.panelSize(stack: Geometry.minimumStack)
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

    /// The stack size the developer chose, or the default before they have resized the panel.
    private var chosenStackSize: NSSize {
        guard let saved = UserDefaults.standard.string(forKey: Self.sizeKey) else { return Geometry.defaultStack }
        let size = NSSizeFromString(saved)
        return size.width > 0 && size.height > 0 ? size : Geometry.defaultStack
    }

    private func place(_ panel: NSPanel) {
        isPlacing = true
        defer { isPlacing = false }
        if let saved = UserDefaults.standard.string(forKey: Self.placementKey) {
            let topLeft = NSPointFromString(saved)
            // The chosen size, fitted to the screen the saved place is on; the corner stays put.
            let stackCorner = NSPoint(x: topLeft.x + Geometry.margin, y: topLeft.y - Geometry.margin)
            let screen = NSScreen.screens.first { $0.frame.contains(stackCorner) } ?? NSScreen.main
            let stack = screen.map { Geometry.fitted(chosenStackSize, in: $0.visibleFrame) } ?? chosenStackSize
            let size = Geometry.panelSize(stack: stack)
            panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                           display: true)
        } else if let screen = NSScreen.main {
            // Not yet moved: the lower trailing corner of the main screen, where the in-window PiP
            // sits. The stack fills the panel, so its corner is the panel's corner less the margin.
            let area = screen.visibleFrame
            let size = Geometry.panelSize(stack: Geometry.fitted(chosenStackSize, in: area))
            panel.setFrame(NSRect(x: area.maxX - Metric.pipTrailing - size.width + Geometry.margin,
                                  y: area.minY + Metric.pipBottom - Geometry.margin,
                                  width: size.width, height: size.height), display: true)
        }
        recover(panel)
    }

    /// The screen that shows most of the panel, or the main screen when none shows any of it.
    private func screen(for frame: NSRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.visibleFrame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let nearest = NSScreen.screens.max(by: { overlap($0) < overlap($1) }) else { return nil }
        return overlap(nearest) > 0 ? nearest : (NSScreen.main ?? nearest)
    }

    /// Shrinks the panel to fit `screen` when it is larger, keeping its top-left corner. The saved
    /// size is left as it was, so the panel grows back on a screen with room for it.
    private func fitSize(_ panel: NSPanel, to screen: NSScreen) {
        let frame = panel.frame
        let stack = Geometry.fitted(Geometry.stackSize(panel: frame.size), in: screen.visibleFrame)
        let size = Geometry.panelSize(stack: stack)
        guard size != frame.size else { return }
        let wasPlacing = isPlacing
        isPlacing = true
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                       display: true)
        isPlacing = wasPlacing
    }

    /// Moves the panel back inside a screen when it is partly or wholly outside every one, for
    /// example after a display was unplugged, and shrinks it to fit a smaller screen. The saved
    /// placement and size are left as they were, so the panel returns to them when that display
    /// comes back. Called only when the panel is shown and when the displays change, never from a
    /// layout or resize callback.
    private func recover(_ panel: NSPanel) {
        guard let screen = screen(for: panel.frame) else { return }
        fitSize(panel, to: screen)
        let frame = panel.frame
        // The clear margin around the stack may hang past the edge; the stack itself may not.
        let area = screen.visibleFrame.insetBy(dx: -Geometry.margin, dy: -Geometry.margin)
        var origin = frame.origin
        origin.x = max(area.minX, min(origin.x, area.maxX - frame.width))
        origin.y = max(area.minY, min(origin.y, area.maxY - frame.height))
        guard origin != frame.origin else { return }
        let wasPlacing = isPlacing
        isPlacing = true
        panel.setFrameOrigin(origin)
        isPlacing = wasPlacing
    }

    @objc private func screensChanged(_ notification: Notification) {
        guard let panel, panel.isVisible, resizeStart == nil else { return }
        place(panel)
    }

    /// A drag of the header handle ended: the placement is saved, and the panel is shrunk if it
    /// was carried onto a screen too small for it (the saved size is kept).
    private func moveEnded() {
        savePlacement()
        if let panel, let screen = screen(for: panel.frame) { fitSize(panel, to: screen) }
    }

    /// Saves where the developer left the panel. Called when a drag of the header handle ends, and
    /// when a resize that moved the top-left corner ends after the panel was already placed.
    /// Showing the panel, screen recovery and display changes never write the placement.
    private func savePlacement() {
        guard let panel else { return }
        let frame = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)),
                                  forKey: Self.placementKey)
    }

    // MARK: Resizing

    private func resizeBegan() {
        guard let panel, let screen = screen(for: panel.frame) else { return }
        // The limits come from the screen the drag started on, so they do not change mid-drag.
        resizeStart = (panel.frame, screen.visibleFrame)
    }

    /// Follows a resize drag. The frame is computed from where the drag started, never from the
    /// current frame, so rounding cannot accumulate and nothing in the layout feeds back into it.
    private func resizeChanged(_ edges: ResizeEdges, by translation: CGSize) {
        guard let panel, let resizeStart else { return }
        let frame = Geometry.resized(resizeStart.frame, edges: edges, by: translation, visible: resizeStart.visible)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// Saves the size the developer chose. The placement is saved only when the resize moved the
    /// corner it is anchored by: the saved top-left once the panel has been placed, otherwise the
    /// screen's lower trailing corner, which an unplaced panel keeps following. A resize that leaves
    /// that corner where it was leaves the placement alone.
    private func resizeEnded() {
        guard let panel, let start = resizeStart else { return }
        resizeStart = nil
        let frame = panel.frame
        guard frame != start.frame else { return }
        UserDefaults.standard.set(NSStringFromSize(Geometry.stackSize(panel: frame.size)), forKey: Self.sizeKey)
        let isPlaced = UserDefaults.standard.string(forKey: Self.placementKey) != nil
        let movedAnchor = isPlaced
            ? frame.minX != start.frame.minX || frame.maxY != start.frame.maxY
            : frame.maxX != start.frame.maxX || frame.minY != start.frame.minY
        if movedAnchor { savePlacement() }
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

/// What a resize zone reports while it is dragged. The window's owner turns it into a frame.
struct WindowResizeIntents {
    let began: () -> Void
    /// The edges being moved and the pointer's travel since the press, in screen points (y up).
    let changed: (ResizeEdges, CGSize) -> Void
    let ended: () -> Void
}

/// One edge or corner zone of a floating window that resizes it. Like WindowDragHandle, it follows
/// each delivered mouse event in screen coordinates, takes the first click and never activates the
/// app. It shows the system's frame-resize cursor for its edge, and reports travel since the press;
/// it never touches the window itself.
struct WindowResizeHandle: NSViewRepresentable {
    let edges: ResizeEdges
    let intents: WindowResizeIntents

    final class Zone: NSView {
        var edges: ResizeEdges = []
        var intents: WindowResizeIntents?
        private var pressPoint: NSPoint?
        private var tracking: NSTrackingArea?

        override init(frame: NSRect) {
            super.init(frame: frame)
            // A borderless clear window passes clicks through fully transparent pixels, and a zone
            // can lie past the card's rounded corner, so it carries a fill too faint to see.
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.015).cgColor
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        var cursor: NSCursor {
            let position: NSCursor.FrameResizePosition = switch edges {
            case [.top, .left]: .topLeft
            case [.top, .right]: .topRight
            case [.bottom, .left]: .bottomLeft
            case [.bottom, .right]: .bottomRight
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            default: .right
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }

        // The cursor is set from the zone's own tracking area, which is live while the app is
        // inactive, as the panel usually is; cursor rects alone apply only to the key window.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) {
            // The pointer can outrun a thin zone mid-drag; the cursor stays until the drag ends.
            if pressPoint == nil { NSCursor.arrow.set() }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            pressPoint = window.convertPoint(toScreen: event.locationInWindow)
            cursor.set()
            intents?.began()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let pressPoint else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            cursor.set()
            intents?.changed(edges, CGSize(width: pointer.x - pressPoint.x, height: pointer.y - pressPoint.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard pressPoint != nil else { return }
            pressPoint = nil
            intents?.ended()
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
        }
    }

    func makeNSView(context: Context) -> Zone {
        let zone = Zone(frame: .zero)
        zone.edges = edges
        zone.intents = intents
        if edges == [.bottom, .right] {
            // The corner with the visible grip speaks for all the zones.
            zone.toolTip = "Drag to resize. The size is kept."
            zone.setAccessibilityElement(true)
            zone.setAccessibilityRole(.handle)
            zone.setAccessibilityLabel("Resize the Needs attention panel")
            zone.setAccessibilityHelp("Drag an edge or corner to resize the panel. Its size is kept.")
        } else {
            zone.setAccessibilityElement(false)
        }
        return zone
    }

    func updateNSView(_ zone: Zone, context: Context) {
        zone.intents = intents
        if zone.edges != edges {
            zone.edges = edges
            zone.window?.invalidateCursorRects(for: zone)
        }
    }
}

/// The visible mark in a resizable floating card's lower trailing corner: two short diagonal
/// rules in secondary ink, as on a native resizable sheet. It draws only; the zone above it acts.
struct ResizeGrip: View {
    private struct Rules: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }

    var body: some View {
        Rules()
            .stroke(.inkSecondary, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            .frame(width: 9, height: 9)
            .opacity(0.7)
            .accessibilityHidden(true)
    }
}

/// The resize affordance laid over a floating card: thin zones along each edge, larger ones at the
/// corners, all just inside the card so the clear margin still passes clicks through, and the grip
/// in the lower trailing corner. The card's interior is untouched.
struct WindowResizeFrame: View {
    let intents: WindowResizeIntents
    /// Kept small so the zones sit in the card's own padding, clear of its controls.
    private let edge: CGFloat = 4
    private let corner: CGFloat = 10

    var body: some View {
        ZStack {
            ResizeGrip()
                .padding([.trailing, .bottom], 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
            zone(.top).frame(height: edge).padding(.horizontal, corner)
                .frame(maxHeight: .infinity, alignment: .top)
            zone(.bottom).frame(height: edge).padding(.horizontal, corner)
                .frame(maxHeight: .infinity, alignment: .bottom)
            zone(.left).frame(width: edge).padding(.vertical, corner)
                .frame(maxWidth: .infinity, alignment: .leading)
            zone(.right).frame(width: edge).padding(.vertical, corner)
                .frame(maxWidth: .infinity, alignment: .trailing)
            zone([.top, .left]).frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            zone([.top, .right]).frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            zone([.bottom, .left]).frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            // The grip's corner takes a little more room, as the place a developer aims for.
            zone([.bottom, .right]).frame(width: corner + 4, height: corner + 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func zone(_ edges: ResizeEdges) -> WindowResizeHandle {
        WindowResizeHandle(edges: edges, intents: intents)
    }
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
    /// The resize zones' drag, which the controller turns into the window's frame.
    let resize: WindowResizeIntents

    @FocusState private var replyFocus: String?
    /// Height of everything in the stack except the conversation, as last laid out. It does not
    /// depend on the conversation's height, so measuring it settles in one pass.
    @State private var chrome: CGFloat = 250

    var body: some View {
        let content = CockpitContent(model: model)
        let queue = content.attentionQueue(ui)
        let current = queue.first { $0.id == ui.activeRequestID } ?? queue.first
        // The stack takes the size the panel gives it, less the clear margin; the window's size is
        // read here and never written.
        GeometryReader { proxy in
            let area = proxy.size
            let conversation = FloatingPiPGeometry.conversationHeight(stackHeight: area.height, chrome: chrome)
            Group {
                if let current {
                    // The conversation takes the room the rest of the stack leaves, so the stack fills
                    // the panel. When even the compact conversation does not fit, the same stack
                    // scrolls inside the panel.
                    ViewThatFits(in: .vertical) {
                        stack(current, queue: queue, content: content, conversation: conversation)
                        ScrollView(.vertical) {
                            stack(current, queue: queue, content: content, conversation: conversation)
                        }
                    }
                }
            }
            .frame(width: area.width, height: area.height, alignment: .top)
            .overlay { if current != nil { WindowResizeFrame(intents: resize) } }
        }
        .padding(FloatingPiPGeometry.margin)
        .consoleRecordAccess(actions)
        // The PiP names the jobs; a worker is opened from the main window.
        .environment(\.backgroundWork, BackgroundWorkAccess(isConnected: content.connection == .online))
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
                       content: CockpitContent, conversation: CGFloat) -> some View {
        let index = queue.firstIndex { $0.id == current.id } ?? 0
        return AttentionStack(current: current,
                              next: queue.count > 1 ? queue[(index + 1) % queue.count] : nil,
                              position: index + 1, count: queue.count,
                              reply: replyContext(content),
                              showNext: { ui.show(requestID: queue[(index + 1) % queue.count].id) },
                              expand: { reveal(current) },
                              close: { close(current) },
                              dragHandle: AnyView(WindowDragHandle(onEnd: dragEnded)),
                              // The floating stack points to the worker's console in the cockpit
                              // window, which is brought forward and opens the inspector there.
                              source: ui.sourcePointer(for: current, intents: actions.source,
                                                       reveal: { reveal(current) }),
                              conversationHeight: conversation)
            // The stack's laid-out height less its exact conversation height is the rest of the
            // stack. Rounded up, so a stack sized from it always fits; changed only when it moves
            // by a whole point. This sets view state only, never the window.
            .onGeometryChange(for: CGFloat.self) { ($0.size.height - conversation).rounded(.up) } action: { measured in
                if measured > 0, measured != chrome { chrome = measured }
            }
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
