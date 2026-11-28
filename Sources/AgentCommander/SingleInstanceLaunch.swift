import AppKit
import OSLog
import SwiftUI

// Launch admission and cockpit handoff. SingleInstanceStore.swift holds the file arbitration.
//
//   SingleInstanceLaunch.admit()   process entry, before the App value, models, windows or menu bar item
//   SingleInstanceCoordinator      this process's lease, folder watcher and cockpit presentation
//   SingleInstanceAppDelegate      finish-launching replay and Dock / Launch Services reopen
//   singleInstance…Scene()         hands SwiftUI's openWindow action and the cockpit NSWindow over

@MainActor
enum SingleInstanceLaunch {
    static let cockpitSceneID = "cockpit"

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AgentCommander",
                                    category: "single-instance")

    /// Registers this process, or hands the launch to the live cockpit and exits. With the
    /// preference on, any failure to arbitrate or to watch for requests stops the launch.
    static func admit(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let onlyOneInstance = SingleInstancePreference.isEnabled(in: defaults)
        do {
            let store = try SingleInstanceStore.current(bundle: bundle)
            // Activation is yielded before the request is posted, so the target can take it.
            let admission = try store.admit(onlyOneInstance: onlyOneInstance) { target in
                yieldActivation(to: target, bundleIdentifier: bundle.bundleIdentifier)
            }
            switch admission {
            case .registered(let membership):
                try SingleInstanceCoordinator.shared.adopt(membership)
            case .handedOff(let target):
                // Outside the admission lock: this process is still alive to donate activation.
                activateHandoffTarget(target, bundleIdentifier: bundle.bundleIdentifier)
                exit(EXIT_SUCCESS)
            }
        } catch {
            guard onlyOneInstance else {
                log.error("Launch tracking unavailable: \(String(describing: error), privacy: .public)")
                return
            }
            let message = "Agent Commander: can't check for an open cockpit: \(error).\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    /// Lets the target take activation from this launch. Cooperative; no Apple Events.
    private static func yieldActivation(to pid: Int32, bundleIdentifier: String?) {
        guard let application = verifiedTarget(pid, bundleIdentifier: bundleIdentifier) else { return }
        NSApplication.shared.yieldActivation(to: application)
    }

    private static let handoffActivationWindow: TimeInterval = 1.0
    private static let handoffActivationPoll: TimeInterval = 0.1

    /// Duplicate launch only, after the focus request is posted. Asks the verified target to
    /// activate from this process while it is still alive to donate activation. Retries briefly,
    /// since an early launch may not yet hold activation to give. Stops once the target is
    /// frontmost, exits, or another app comes forward. The focus marker still drives the target's
    /// window restore, so this only moves activation.
    private static func activateHandoffTarget(_ pid: Int32, bundleIdentifier: String?) {
        guard let target = verifiedTarget(pid, bundleIdentifier: bundleIdentifier) else { return }
        let workspace = NSWorkspace.shared
        let ownPID = NSRunningApplication.current.processIdentifier
        let origin = workspace.frontmostApplication?.processIdentifier
        let deadline = Date(timeIntervalSinceNow: handoffActivationWindow)
        while !target.isTerminated {
            let front = workspace.frontmostApplication?.processIdentifier
            if front == pid { return }
            // The user brought some other app forward; leave it there.
            if let front, front != origin, front != ownPID { return }
            NSApplication.shared.yieldActivation(to: target)
            _ = target.activate(from: NSRunningApplication.current, options: [])
            guard Date() < deadline else { return }
            // Lets NSRunningApplication/NSWorkspace state refresh. No App value exists here.
            let next = Date(timeIntervalSinceNow: handoffActivationPoll)
            if !RunLoop.current.run(mode: .default, before: next) { Thread.sleep(until: next) }
        }
    }

    /// The live Commander at `pid`, only when it carries this bundle's identifier.
    private static func verifiedTarget(_ pid: Int32, bundleIdentifier: String?) -> NSRunningApplication? {
        guard let bundleIdentifier,
              let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated,
              application.bundleIdentifier == bundleIdentifier else { return nil }
        return application
    }
}

@MainActor
final class SingleInstanceCoordinator {
    static let shared = SingleInstanceCoordinator()

    private var membership: SingleInstanceMembership?
    private var watcher: (any DispatchSourceFileSystemObject)?
    private var openCockpit: OpenWindowAction?
    private weak var cockpitWindow: NSWindow?
    private var hasFinishedLaunching = false
    private var wantsCockpit = false

    /// Keeps the lease for the life of the process and watches for focus requests.
    func adopt(_ membership: SingleInstanceMembership) throws {
        watcher = try membership.watch(queue: .main) {
            MainActor.assumeIsolated { SingleInstanceCoordinator.shared.receiveFocusRequest() }
        }
        self.membership = membership
    }

    /// Replays a request that arrived while this process was starting, then records the
    /// production app's startup evidence on the lease. The evidence never affects the launch.
    func applicationDidFinishLaunching() {
        hasFinishedLaunching = true
        receiveFocusRequest()
        presentCockpitIfRequested()
        if let membership { LaunchEvidence.record(on: membership) }
    }

    var canPresentCockpit: Bool { visibleCockpit != nil || openCockpit != nil }

    func bringCockpitForward() {
        wantsCockpit = true
        presentCockpitIfRequested()
    }

    func register(openWindow: OpenWindowAction) {
        openCockpit = openWindow
        presentCockpitIfRequested()
    }

    func register(cockpitWindow window: NSWindow) {
        cockpitWindow = window
        presentCockpitIfRequested()
    }

    private func receiveFocusRequest() {
        if membership?.takeFocusRequest() == true { bringCockpitForward() }
    }

    private var visibleCockpit: NSWindow? {
        guard let window = cockpitWindow, window.isVisible || window.isMiniaturized else { return nil }
        return window
    }

    /// Unhides, restores and orders the cockpit front, or reopens it after it was closed. A request
    /// that arrives before SwiftUI has built the scene waits until the scene registers.
    private func presentCockpitIfRequested() {
        guard wantsCockpit, hasFinishedLaunching, canPresentCockpit else { return }
        wantsCockpit = false
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let window = visibleCockpit {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openCockpit {
            openCockpit(id: SingleInstanceLaunch.cockpitSceneID)
        }
        NSApp.activate()
    }
}

@MainActor
final class SingleInstanceAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstanceCoordinator.shared.applicationDidFinishLaunching()
        // Keeps the activity feed arriving for notifications while the tray is closed.
        MultiplayerModel.shared.startActivityWatch()
    }

    /// An `agentcommander://` link, on a warm or a cold start. A second copy launched by a link
    /// hands off before it gets here.
    ///   needs-you   the main window opens Needs you with that request in its review. On a cold
    ///               start the router keeps the request until the window attaches.
    ///   join        an invite: the network tray opens on its add-server page, filled in from the link
    /// A link with any other host opens nothing.
    func application(_ application: NSApplication, open urls: [URL]) {
        let links = CommanderExternalLink.first(in: urls)
        if let request = links.needsYou {
            CommanderWindowRouter.shared.open(CommanderOpenRequest(needsYou: request))
        }
        if let invite = links.invite {
            MultiplayerLinkWindow.open([invite], in: MultiplayerModel.shared)
        }
    }

    /// Dock click or Launch Services reopen: restore the cockpit even when only Settings or the
    /// menu bar panel is showing. Before the scene exists, SwiftUI's default handling applies.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let coordinator = SingleInstanceCoordinator.shared
        guard coordinator.canPresentCockpit else { return true }
        coordinator.bringCockpitForward()
        return false
    }
}

// MARK: - Scene bridge

private struct SingleInstanceSceneBridge: ViewModifier {
    let tracksCockpitWindow: Bool
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .background {
                if tracksCockpitWindow {
                    HostWindowReader { SingleInstanceCoordinator.shared.register(cockpitWindow: $0) }
                }
            }
            .onAppear { SingleInstanceCoordinator.shared.register(openWindow: openWindow) }
    }
}

/// Reports the NSWindow hosting it. Draws nothing and takes no clicks.
private struct HostWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// The cockpit window's content: supplies openWindow and the window to bring forward.
    func singleInstanceCockpitScene() -> some View {
        modifier(SingleInstanceSceneBridge(tracksCockpitWindow: true))
    }

    /// Settings content: supplies openWindow so a closed cockpit can reopen.
    func singleInstanceAuxiliaryScene() -> some View {
        modifier(SingleInstanceSceneBridge(tracksCockpitWindow: false))
    }
}
