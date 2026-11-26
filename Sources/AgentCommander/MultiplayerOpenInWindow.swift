import AppKit
import SwiftUI

// ATOMIC LEVEL: Values and one molecule for the triage tray (design/MAIN-WINDOW-INCREMENT-6-PLAN.md,
// "How the tray opens a window page").
// A tray page that moves to the main window carries an "Open in Agent Commander" row. The row
// sends one `CommanderOpenRequest` to the window's router and then closes the panel. The tray
// depends on that value and that call only, never on the window's models or templates.
//
//   MultiplayerWindowLink         a tray page as the window page it opens, and how to name it
//   MultiplayerWindowOpener       sends the request, then closes the panel; both steps are injected
//   MultiplayerPanelWindow        the window the panel is drawn in, so the opener can close it
//   MultiplayerOpenInWindowRow    the row: a native button in the tray's skin

// MARK: - Values

/// A tray page as the main-window page that replaces it: the request to send and the words that
/// name where it lands. Nil for a page that stays in the tray (a quick action or a composer).
struct MultiplayerWindowLink: Equatable, Sendable {
    let request: CommanderOpenRequest
    /// The window's own breadcrumb to the place: "Network", "Hand-offs".
    let crumbs: [String]
    /// What is opened on the place, when the request names an item: "this hand-off".
    let item: String?

    init(request: CommanderOpenRequest, crumbs: [String], item: String? = nil) {
        self.request = request
        self.crumbs = crumbs
        self.item = item
    }

    /// The place's name, as the window's navigation shows it.
    var place: String { crumbs.last ?? "Agent Commander" }

    /// Where the row lands, drawn under its title: "Network › Hand-offs › this hand-off".
    var crumb: String { (crumbs + (item.map { [$0] } ?? [])).joined(separator: " › ") }

    /// What VoiceOver calls the row.
    var label: String { "Open \(place) in Agent Commander" }

    /// What pressing it does, beyond the label.
    var hint: String { item.map { "Shows \($0) there and closes this panel." } ?? "Closes this panel." }
}

extension MultiplayerWindowLink {
    /// The link for a tray page on a server. The request is the router's own for every page it
    /// maps. Watching and reviewing move to the worker wall, which the router has no page mapping
    /// for, so that request is built here and opens the wall without an item.
    init?(page: MultiplayerSharePage, server: String) {
        func link(_ crumbs: [String], _ item: String? = nil) -> MultiplayerWindowLink? {
            CommanderOpenRequest(page: page, server: server).map { MultiplayerWindowLink(request: $0, crumbs: crumbs, item: item) }
        }
        let workspace = ["Teams", "Workspaces"]
        func tool(_ name: String) -> [String] { ["Teams", "Team tools", name] }
        let found: MultiplayerWindowLink?
        switch page {
        case .directory: found = link(["Network", "Directory"])
        case .requests: found = link(["Network", "Approvals"])
        case .approval: found = link(["Network", "Approvals"], "this request")
        case .handoffs: found = link(["Network", "Hand-offs"])
        case .handoffDetail: found = link(["Network", "Hand-offs"], "this hand-off")
        case .thread: found = link(["Network", "Threads"], "this thread")
        case .audit(let resource): found = link(["Network", "Audit"], resource.isEmpty ? nil : "this resource")
        case .fanout: found = link(["Network", "Fan-out"])
        case .compare: found = link(["Network", "Fan-out"], "this fan-out")
        case .watch, .review:
            found = MultiplayerWindowLink(request: CommanderOpenRequest(place: LiveShell.wall, server: server), crumbs: ["Agents", "Runs"])
        case .groups: found = link(tool("Groups"))
        case .group: found = link(tool("Groups"), "this group")
        case .workspaces: found = link(workspace)
        case .workspace: found = link(workspace, "this workspace")
        case .claim: found = link(workspace, "this workspace’s claims")
        case .card: found = link(workspace, "this card")
        case .queueAdd: found = link(workspace, "this workspace’s integration")
        case .hosts: found = link(tool("Hosts"))
        case .hostRun: found = link(tool("Hosts"), "this host")
        case .knowledge, .knowledgeShare: found = link(tool("Knowledge"))
        case .knowledgeItem: found = link(tool("Knowledge"), "this item")
        case .reputation: found = link(tool("Directory"), "this reputation")
        case .search: found = link(tool("Directory"))
        case .policy: found = link(tool("Admin"), "this server’s policy")
        case .requestAccess, .grant, .consult, .handoff, .control, .reviewRequest, .workspaceCreate: found = nil
        }
        guard let found else { return nil }
        self = found
    }
}

/// How a tray row opens a window page: send the request, then close the panel. The live opener
/// sends to the shared router; a test passes its own two steps and reads what was sent.
struct MultiplayerWindowOpener: Sendable {
    var open: @MainActor @Sendable (CommanderOpenRequest) -> Void
    var close: @MainActor @Sendable () -> Void

    init(open: @escaping @MainActor @Sendable (CommanderOpenRequest) -> Void = { CommanderWindowRouter.shared.open($0) },
         close: @escaping @MainActor @Sendable () -> Void = {}) {
        self.open = open
        self.close = close
    }

    /// Opens the window page, then closes the panel the row was in.
    @MainActor func send(_ request: CommanderOpenRequest) {
        open(request)
        close()
    }

    /// The same way to open, with another way to close.
    func closing(_ close: @escaping @MainActor @Sendable () -> Void) -> MultiplayerWindowOpener {
        MultiplayerWindowOpener(open: open, close: close)
    }
}

private struct MultiplayerWindowOpenerKey: EnvironmentKey {
    static let defaultValue = MultiplayerWindowOpener()
}

extension EnvironmentValues {
    /// How an "Open in Agent Commander" row sends its request. `MultiplayerPanel` adds the close
    /// of its own window to whatever opener it is given.
    var multiplayerWindowOpener: MultiplayerWindowOpener {
        get { self[MultiplayerWindowOpenerKey.self] }
        set { self[MultiplayerWindowOpenerKey.self] = newValue }
    }
}

// MARK: - The panel's window

/// The window a panel is drawn in: the menu bar panel, or the window a join link opens. The menu
/// bar panel can't be reached from SwiftUI, so the panel finds its window through a probe view.
@MainActor final class MultiplayerPanelWindow {
    weak var window: NSWindow?

    /// Closes the panel's window. Nothing happens before the panel is in one.
    func close() { window?.close() }
}

/// Tells a `MultiplayerPanelWindow` which window its panel is in. Draws nothing.
struct MultiplayerPanelWindowProbe: NSViewRepresentable {
    let panel: MultiplayerPanelWindow

    final class Probe: NSView {
        var panel: MultiplayerPanelWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            panel?.window = window
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.panel = panel
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.panel = panel
        panel.window = view.window
    }
}

// MARK: - Molecule

/// "Open in Agent Commander": the first row of a tray page that has a window page. A window mark,
/// the title, where it lands as the window's own breadcrumb, and an up-right arrow because the row
/// leaves the tray. Under the pointer the arrow leans out; pressed, it leaves. With Reduce Motion
/// the arrow stays and only its ink changes.
struct MultiplayerOpenInWindowRow: View {
    let link: MultiplayerWindowLink
    @Environment(\.multiplayerWindowOpener) private var opener
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Button { opener.send(link.request) } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 12))
                        .foregroundStyle(MultiplayerTheme.focus)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open in Agent Commander")
                            .font(MultiplayerTheme.name)
                            .foregroundStyle(MultiplayerTheme.foreground)
                        Text(link.crumb)
                            .font(MultiplayerTheme.fingerprint)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(MultiplayerOpenInWindowStyle())
            .accessibilityLabel(link.label)
            .accessibilityHint(link.hint)
            .help("\(link.label): \(link.crumb)")
            Rectangle().fill(MultiplayerTheme.hair).frame(height: theme.line.hairline)
        }
        .background(MultiplayerTheme.footerFill)
    }
}

/// The row's face: the tray's row tint, and the arrow that answers the pointer and the press.
private struct MultiplayerOpenInWindowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct Face<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @State private var hovering = false
        @Environment(\.theme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// How far the arrow has gone: a third of the way under the pointer, all the way pressed.
        private var lean: CGFloat {
            guard !reduceMotion else { return 0 }
            return isPressed ? theme.motion.travel : hovering ? (theme.motion.travel / 3).rounded() : 0
        }

        var body: some View {
            HStack(spacing: Space.s) {
                label
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering || isPressed ? AnyShapeStyle(MultiplayerTheme.focus) : AnyShapeStyle(.inkSecondary))
                    .offset(x: lean, y: -lean)
                    .opacity(isPressed && !reduceMotion ? 0 : 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, theme.space.sectionInset)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
            .modifier(MultiplayerResponsive(isPressed: isPressed))
            .onHover { hovering = $0 }
            .animation(theme.motion.animation(theme.motion.fast), value: hovering)
            .animation(theme.motion.animation(theme.motion.fast), value: isPressed)
        }
    }
}
