import AppKit
import SwiftUI

// ATOMIC LEVEL: Values and molecules for the triage tray (design/MAIN-WINDOW-INCREMENT-6-PLAN.md,
// "How the tray opens a window page").
// A page that moved to the main window is an "Open in Agent Commander" row in the tray. The row
// sends one `CommanderOpenRequest` to the window's router and then closes the panel. The tray
// depends on that value and that call only, never on the window's models or templates.
//
//   MultiplayerSharePage.staysInTray   which pages the tray still draws
//   MultiplayerWindowLink         a page as the window page it opens, and how to name it
//   MultiplayerWindowShortcut     one compact row: a place, how much is there, and its link
//   MultiplayerWindowOpener       sends the request, then closes the panel; both steps are injected
//   MultiplayerPageOpener         shows a page where it lives: in the tray, or in the window
//   MultiplayerPanelWindow        the window the panel is drawn in, so the opener can close it
//   MultiplayerOpenInWindowRow    the row at the top of a page: a native button in the tray's skin
//   MultiplayerWindowLinkRow      the compact row, where a tab's section used to be

// MARK: - Values

extension MultiplayerSharePage {
    /// True for a page the tray still draws: a quick action, a composer, Take back control, watch
    /// and review, and Relay policy. Every other page passed its running-window check and is only
    /// a link now (DESIGN.md, "The triage tray"). The cases stay because the window's own pages
    /// and the router name their items by them.
    var staysInTray: Bool {
        switch self {
        case .requestAccess, .grant, .consult, .handoff, .watch, .control, .reviewRequest, .review, .workspaceCreate, .policy:
            true
        case .directory, .requests, .approval, .handoffs, .handoffDetail, .thread, .audit, .fanout, .compare,
             .groups, .group, .workspaces, .workspace, .claim, .card, .queueAdd, .hosts, .hostRun,
             .knowledge, .knowledgeShare, .knowledgeItem, .reputation, .search:
            false
        }
    }
}

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

    /// Where a compact row lands, from the app down: "Agent Commander › Network › Hand-offs".
    var path: String { "Agent Commander › \(crumb)" }
}

extension MultiplayerWindowLink {
    /// The link for a tray page on a server: the router's own request for the page, and the
    /// words that name where it lands. Nil for a page the router has no window page for. A link
    /// with no server opens the place alone, for a row that stands for every server.
    init?(page: MultiplayerSharePage, server: String?) {
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
        case .watch, .control: found = link(["Agents", "Runs"], "this worker")
        case .review: found = link(["Agents", "Runs"], "this review")
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
        case .requestAccess, .grant, .consult, .handoff, .reviewRequest, .workspaceCreate: found = nil
        }
        guard let found else { return nil }
        self = found
    }
}

/// One compact row where a tab's section used to be: the window place by its own name, how much
/// is there now, and the link the row sends.
struct MultiplayerWindowShortcut: Identifiable, Equatable, Sendable {
    let symbol: String
    let title: String
    var count = 0
    /// A count that waits on the person is drawn in `attention`.
    var isHot = false
    let link: MultiplayerWindowLink

    var id: String { title }

    /// What VoiceOver calls the row: "Open Hand-offs in Agent Commander, 3".
    var label: String { count > 0 ? "\(link.label), \(count)" : link.label }

    init?(_ page: MultiplayerSharePage, on server: String? = nil, symbol: String, title: String? = nil, count: Int = 0, isHot: Bool = false) {
        guard let link = MultiplayerWindowLink(page: page, server: server) else { return nil }
        self.symbol = symbol
        self.title = title ?? link.place
        self.count = count
        self.isHot = isHot
        self.link = link
    }
}

extension MultiplayerWindowShortcut {
    /// Agents tab, under friends' agents: everything friends offer, and one prompt to several workers.
    static func agents() -> [MultiplayerWindowShortcut] {
        [MultiplayerWindowShortcut(.directory, symbol: "square.grid.2x2"),
         MultiplayerWindowShortcut(.fanout, symbol: "arrow.triangle.branch")].compactMap { $0 }
    }

    /// Agents tab, where the workspaces band was: workspaces, hosts and the knowledge library.
    static func teams(workspaces: Int, hosts: Int, knowledge: Int) -> [MultiplayerWindowShortcut] {
        [MultiplayerWindowShortcut(.workspaces, symbol: "square.stack.3d.up", count: workspaces),
         MultiplayerWindowShortcut(.hosts, symbol: "cpu", count: hosts),
         MultiplayerWindowShortcut(.knowledge, symbol: "books.vertical", count: knowledge)].compactMap { $0 }
    }

    /// People tab, where the groups band was.
    static func groups(_ count: Int) -> [MultiplayerWindowShortcut] {
        [MultiplayerWindowShortcut(.groups, symbol: "person.3", count: count)].compactMap { $0 }
    }

    /// A server's page, under Share and consult. Approvals and access requests are answered on
    /// the same window page, so they share a row and a count.
    static func sharing(on server: String, directory: Int, waiting: Int, handoffs: Int) -> [MultiplayerWindowShortcut] {
        [MultiplayerWindowShortcut(.directory, on: server, symbol: "square.grid.2x2", count: directory),
         MultiplayerWindowShortcut(.requests, on: server, symbol: "hand.raised", count: waiting, isHot: true),
         MultiplayerWindowShortcut(.handoffs, on: server, symbol: "arrow.up.right", count: handoffs),
         MultiplayerWindowShortcut(.audit(resource: ""), on: server, symbol: "list.bullet.rectangle")].compactMap { $0 }
    }

    /// A server's page, under Teams. Relay policy is not here: the tray still has that page.
    static func serverTeams(on server: String, groups: Int, workspaces: Int, hosts: Int, knowledge: Int) -> [MultiplayerWindowShortcut] {
        [MultiplayerWindowShortcut(.groups, on: server, symbol: "person.3", count: groups),
         MultiplayerWindowShortcut(.workspaces, on: server, symbol: "square.stack.3d.up", count: workspaces),
         MultiplayerWindowShortcut(.hosts, on: server, symbol: "cpu", count: hosts),
         MultiplayerWindowShortcut(.knowledge, on: server, symbol: "books.vertical", count: knowledge),
         MultiplayerWindowShortcut(.search, on: server, symbol: "magnifyingglass")].compactMap { $0 }
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

/// Shows a page where it lives. A page the tray still draws opens in the tray; a page that moved
/// is sent to the window, and the tray's route stays where it is. Every tray entry point that
/// names a page goes through this, so none of them can land on a page the tray no longer draws.
@MainActor struct MultiplayerPageOpener {
    let share: MultiplayerShareModel
    let window: MultiplayerWindowOpener

    func show(_ page: MultiplayerSharePage, on server: String) {
        if page.staysInTray {
            share.open(page, on: server)
        } else if let link = MultiplayerWindowLink(page: page, server: server) {
            window.send(link.request)
        }
    }

    /// A hand-off or a fan-out opens in the window. A review stays in the tray.
    func show(_ work: MultiplayerRemoteWork) {
        if work.page.staysInTray { share.live.open(work) } else { show(work.page, on: work.server) }
    }
}

extension MultiplayerRemoteWork {
    /// The page that shows this work.
    var page: MultiplayerSharePage {
        switch kind {
        case .handoff: .handoffDetail(request: request)
        case .review: .review(request: request)
        case .fanout: .compare(request: request)
        }
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

/// The compact form, inside a band where a tab's section used to be: the place's mark and name,
/// where it lands from the app down, how much is there, and the same arrow as the full row.
struct MultiplayerWindowLinkRow: View {
    let shortcut: MultiplayerWindowShortcut
    @Environment(\.multiplayerWindowOpener) private var opener

    var body: some View {
        Button { opener.send(shortcut.link.request) } label: {
            HStack(spacing: Space.s) {
                Image(systemName: shortcut.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortcut.title)
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                    Text(shortcut.link.path)
                        .font(MultiplayerTheme.fingerprint)
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if shortcut.count > 0 {
                    Text("\(shortcut.count)")
                        .font(MultiplayerTheme.heading.monospacedDigit())
                        .foregroundStyle(shortcut.isHot ? MultiplayerTheme.attention : MultiplayerTheme.foreground)
                        .multiplayerTicking(shortcut.count)
                }
            }
        }
        .buttonStyle(MultiplayerOpenInWindowStyle(isCompact: true))
        .accessibilityLabel(shortcut.label)
        .accessibilityHint(shortcut.link.hint)
        .help("\(shortcut.link.label): \(shortcut.link.crumb)")
    }
}

/// Compact rows, one under the other, in the order given.
struct MultiplayerWindowLinkRows: View {
    let shortcuts: [MultiplayerWindowShortcut]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shortcuts) { MultiplayerWindowLinkRow(shortcut: $0) }
        }
    }
}

/// The mark on anything else that leaves the tray for the window: a verb, a work row.
struct MultiplayerLeavesTrayMark: View {
    var body: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.inkSecondary)
            .accessibilityHidden(true)
    }
}

/// The row's face: the tray's row tint, and the arrow that answers the pointer and the press.
/// The compact form sits inside a band, so it takes the band's inset and a link row's height.
private struct MultiplayerOpenInWindowStyle: ButtonStyle {
    var isCompact = false

    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, isPressed: configuration.isPressed, isCompact: isCompact)
    }

    private struct Face<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let isCompact: Bool
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
            .padding(.horizontal, isCompact ? 0 : theme.space.sectionInset)
            .frame(minHeight: isCompact ? 34 : 40)
            .contentShape(Rectangle())
            .modifier(MultiplayerResponsive(isPressed: isPressed))
            .onHover { hovering = $0 }
            .animation(theme.motion.animation(theme.motion.fast), value: hovering)
            .animation(theme.motion.animation(theme.motion.fast), value: isPressed)
        }
    }
}
