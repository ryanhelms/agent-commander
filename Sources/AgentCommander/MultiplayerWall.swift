import SwiftUI

// ATOMIC LEVEL: Organism for the cockpit wall, with its values.
// A hand-off runs on a friend's Mac, so it has no terminal here. The wall shows it as a remote
// worker: the same console title bar, harness surface and status label as a local worker tile,
// named for the friend's agent and labelled with the friend and the server it went through.
// Opening one zooms it: the cockpit's zoom view shows the worker's output as a read-only trace,
// labelled with its owner and server, read through `watch` while the view is open. Nothing here
// sends anything to the worker.
//   Values:    MultiplayerRemoteWorker
//   Molecule:  RemoteWorkerTile
//   Organism:  RemoteWorkerGroup, RemoteWorkerZoom
//   Hosts:     MultiplayerRemoteWorkerBand, MultiplayerRemoteWorkerZoomHost (read the tray's model)

/// One hand-off you sent, as the wall shows it.
struct MultiplayerRemoteWorker: Identifiable, Equatable {
    let server: String
    let request: String
    /// The friend's worker the hand-off runs on. `watch` reads it.
    var resource: String = ""
    /// True when the friend shared Watch on that worker with you.
    var canWatch: Bool = false
    /// What was handed off.
    let task: String
    /// The friend's agent, or the resource's name when the directory doesn't list it.
    let agent: String
    /// The friend's handle. Empty when the directory doesn't say whose it is.
    let friend: String
    let serverName: String
    let harness: String
    let state: String
    let tone: Tone
    let at: Date?

    var id: String { "\(server)/\(request)" }

    var client: AgentClient {
        switch harness.lowercased() {
        case "claude": .claude
        case "codex": .codex
        default: .other(harness.isEmpty ? "Remote agent" : MultiplayerCapabilities.harnessTitle(harness))
        }
    }

    /// "fixture-sam on ryan-mac", or the server alone.
    var origin: String { friend.isEmpty ? "on \(serverName)" : "\(friend) on \(serverName)" }

    var spoken: String {
        "Remote worker \(agent), \(friend.isEmpty ? "" : "\(friend)’s agent, ")on \(serverName). \(task). \(state)"
    }
}

extension MultiplayerShareModel {
    /// Every hand-off you sent, newest first, as remote workers. Runs still going come before settled ones.
    var remoteWorkers: [MultiplayerRemoteWorker] {
        let rows = allHandoffs.map { pending -> (worker: MultiplayerRemoteWorker, settled: Bool) in
            let row = pending.item
            let entry = entry(row.resource, on: pending.server)
            let state = handoffState(row)
            let raw = reports[row.request]?.state ?? ""
            let worker = MultiplayerRemoteWorker(
                server: pending.server, request: row.request, resource: row.resource, canWatch: entry?.canWatch == true,
                task: row.title.isEmpty ? "Untitled hand-off" : row.title.multiplayerDisplay,
                agent: (entry?.name ?? resourceName(row.resource, on: pending.server)).multiplayerDisplay,
                friend: entry?.owner.multiplayerDisplay ?? "",
                serverName: tray?.server(pending.server)?.displayName ?? "a server",
                harness: entry?.capabilities?.harness ?? "",
                state: state.title, tone: state.tone, at: row.at)
            let settled = raw.isEmpty ? (!row.succeeded && MultiplayerRequestState.isSettled(row.status)) : MultiplayerRequestState.isSettled(raw)
            return (worker, settled)
        }
        return rows.enumerated().sorted { a, b in
            if a.element.settled != b.element.settled { return !a.element.settled }
            let left = a.element.worker.at ?? .distantPast, right = b.element.worker.at ?? .distantPast
            return left == right ? a.offset < b.offset : left > right
        }
        .map(\.element.worker)
    }

}

/// A remote worker on the wall: a console tile with no terminal, since the run is on a friend's Mac.
struct RemoteWorkerTile: View {
    let worker: MultiplayerRemoteWorker
    let now: Date
    var onOpen: (() -> Void)? = nil
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { onOpen?() } label: {
            VStack(spacing: 0) {
                ConsoleTitleBar(title: worker.agent, client: worker.client, host: worker.origin, platform: .unknown,
                                density: .tile) {
                    StatusLabel(text: worker.state, tone: worker.tone, size: 10.5)
                        .padding(.trailing, 5)
                }
                VStack(alignment: .leading, spacing: 5) {
                    line("task", worker.task, color: Term.bright)
                    line("from", worker.friend.isEmpty ? "a friend’s device" : worker.friend, color: Term.cyan)
                    line("via", worker.serverName, color: Term.text)
                    if let at = worker.at { line("sent", MultiplayerActivityRow.time(at, now: now), color: Term.text) }
                }
                .padding(.horizontal, Metric.tileInset)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Term.background)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .harnessConsoleSurface(worker.client, attention: worker.tone == .attention)
        .overlay { Rectangle().fill(Term.bright.opacity(hovering && onOpen != nil ? 0.04 : 0)).allowsHitTesting(false) }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : MultiplayerTheme.Motion.ease(MultiplayerTheme.Motion.fast), value: hovering)
        .help(onOpen == nil ? worker.spoken : "Zoom this remote worker to read its output")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(worker.spoken)
        .accessibilityAddTraits(onOpen == nil ? .isStaticText : .isButton)
        .accessibilityHint(onOpen == nil ? "" : "Shows its output, read-only")
    }

    private func line(_ key: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(Term.font(10.5)).foregroundStyle(Term.dim).frame(width: 30, alignment: .leading)
            Text(value).font(Term.font(11.5)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// The wall's row of remote workers, under the local ones. Drawn like a nested worker group.
struct RemoteWorkerGroup: View {
    /// A row never grows past the wall's own three columns.
    static let limit = 3
    static let tileHeight: CGFloat = 122

    let workers: [MultiplayerRemoteWorker]
    let now: Date
    var onOpen: ((MultiplayerRemoteWorker) -> Void)? = nil
    var onOpenAll: (() -> Void)? = nil
    /// The owner's keyboard focus among the tiles, by remote worker ID, so a zoom can return to
    /// the tile it came from. Each tile stays the native button it is.
    var focus: FocusState<String?>.Binding? = nil

    @Environment(\.theme) private var theme
    var body: some View {
        // The band is a worker group of the wall, so its fill, edge, radius and heading are the
        // theme's `wall` group roles, with the count in full ink.
        let shape = RoundedRectangle(cornerRadius: theme.wall.groupRadius, style: .continuous)
        let shown = Array(workers.prefix(Self.limit))
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11))
                Text("Remote workers").font(MultiplayerTheme.groupTitle).accessibilityAddTraits(.isHeader)
                Text("\(workers.count)").font(MultiplayerTheme.groupTitle.monospacedDigit()).foregroundStyle(MultiplayerTheme.foreground)
                    .multiplayerTicking(workers.count)
                Text(workers.count == 1 ? "hand-off on a friend’s Mac" : "hand-offs on friends’ Macs")
                    .font(MultiplayerTheme.groupNote)
                Spacer(minLength: 8)
                if workers.count > shown.count, let onOpenAll {
                    Button("\(workers.count - shown.count) more…", action: onOpenAll)
                        .buttonStyle(.plain)
                        .font(MultiplayerTheme.state)
                        .accessibilityLabel("Show \(workers.count - shown.count) more hand-offs in the network tray")
                }
            }
            .foregroundStyle(.inkSecondary)
            .frame(minHeight: Metric.groupHeaderHeight)
            .accessibilityElement(children: .contain)
            // As many equal columns as fit, so a card stays readable in a narrow wall. A lone tile
            // keeps a column's width instead of stretching across the wall.
            RemoteWorkerGrid {
                ForEach(shown) { worker in
                    RemoteWorkerTile(worker: worker, now: now, onOpen: onOpen.map { open in { open(worker) } })
                        .modifier(RemoteTileFocus(id: worker.id, focus: focus))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 9)
        .background(MultiplayerTheme.groupFill, in: shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.groupEdge) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remote workers")
    }
}

/// Binds a remote tile's keyboard focus to its owner's, when the owner keeps one.
private struct RemoteTileFocus: ViewModifier {
    let id: String
    let focus: FocusState<String?>.Binding?

    func body(content: Content) -> some View {
        if let focus { content.focused(focus, equals: id) } else { content }
    }
}

/// Lays remote worker tiles out in equal columns: three where the wall is wide enough, fewer where
/// a card would go under its least readable width, with further tiles on the next row. Every tile
/// has the group's fixed height, and a row that is not full stays at the column width.
struct RemoteWorkerGrid: Layout {
    /// The least width a compact card keeps its task, owner and server lines readable at.
    static let minimumTileWidth: CGFloat = 200

    static func columns(fitting width: CGFloat) -> Int {
        max(1, min(RemoteWorkerGroup.limit, Int((width + Metric.tileGap) / (minimumTileWidth + Metric.tileGap))))
    }

    /// The tiles' frames across a width, in order.
    static func frames(count: Int, width: CGFloat) -> [CGRect] {
        let columns = columns(fitting: width)
        let tile = max(0, (width - CGFloat(columns - 1) * Metric.tileGap) / CGFloat(columns))
        return (0..<count).map { index in
            CGRect(x: CGFloat(index % columns) * (tile + Metric.tileGap),
                   y: CGFloat(index / columns) * (RemoteWorkerGroup.tileHeight + Metric.tileGap),
                   width: tile, height: RemoteWorkerGroup.tileHeight)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(RemoteWorkerGroup.limit) * Self.minimumTileWidth
        return CGSize(width: width, height: Self.frames(count: subviews.count, width: width).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(count: subviews.count, width: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// A remote worker in the cockpit's zoom view: what was handed off, then the worker's output as a
/// read-only trace, labelled with its owner and server. The trace is the tray's watch view. Where
/// the caller allows it and the owner shared Suggest, the view also takes a suggestion for the
/// worker: the caller owns the draft and sends it.
struct RemoteWorkerZoom: View {
    let worker: MultiplayerRemoteWorker
    let watch: MultiplayerWatchState
    let entry: MultiplayerDirectoryEntry?
    let color: Color
    let interval: Int
    let now: Date
    /// The footer button's title. Nil leaves the button out, for a caller with its own way to the
    /// hand-off's page.
    var footerTitle: String? = "Open hand-off"
    /// Shows the suggestion field under the trace when the owner shared Suggest on the worker.
    var allowsSuggestion = false
    /// The caller's draft.
    var suggestion: Binding<String> = .constant("")
    /// The answer to the last suggestion sent, or how it stands.
    var reply: MultiplayerSentRequest? = nil
    var isBusy = false
    /// Sends the draft. Nil leaves the field without its send button.
    var onSuggest: (() -> Void)? = nil
    let onRetry: () -> Void
    let onOpenTray: () -> Void

    private var takesSuggestion: Bool { allowsSuggestion && worker.canWatch && entry?.canSuggest == true }

    @Environment(\.theme) private var theme
    var body: some View {
        let shape = theme.trayTile
        VStack(spacing: 0) {
            MultiplayerBand {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.inkSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(worker.task)
                            .font(MultiplayerTheme.name)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .lineLimit(2)
                        Text("Hand-off to \(worker.origin)\(worker.at.map { ", sent \(MultiplayerActivityRow.time($0, now: now))" } ?? "")")
                            .font(MultiplayerTheme.fingerprint)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    Text(worker.state)
                        .font(MultiplayerTheme.state)
                        .foregroundStyle(worker.tone == .neutral ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(worker.tone.color))
                        .lineLimit(1)
                        .accessibilityLabel("Hand-off state, \(worker.state)")
                }
            }
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if worker.canWatch {
                        MultiplayerWatchView(watch: watch, entry: entry, serverName: worker.serverName, color: color,
                                             interval: interval, suggestion: suggestion, reply: reply,
                                             allowsSuggestion: takesSuggestion, onRetry: onRetry)
                    } else {
                        MultiplayerBand {
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                MultiplayerLamp(kind: .off)
                                Text("\(worker.friend.isEmpty ? "The owner" : worker.friend) hasn’t shared Watch on \(worker.agent), so its output can’t be read here. The hand-off’s report and thread are in the network tray.")
                                    .font(MultiplayerTheme.sub)
                                    .foregroundStyle(.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { MultiplayerScrollerSilencer().accessibilityHidden(true) }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            MultiplayerTrayFooter(note: !worker.canWatch ? nil
                                        : takesSuggestion ? "Reads while this view is open. The owner approves each suggestion."
                                                          : "Read-only. Reads while this view is open.") {
                if let footerTitle {
                    Button(footerTitle, action: onOpenTray)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .help("Open this hand-off’s report and thread")
                }
                if takesSuggestion, let onSuggest {
                    Button("Send suggestion", action: onSuggest)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(isBusy || !MultiplayerLiveModel.canSend(suggestion: suggestion.wrappedValue))
                        .help("Send the suggestion to the owner (⌘Return)")
                }
            }
        }
        .background(MultiplayerTheme.panelFill)
        .clipShape(shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.panelEdge) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remote worker \(worker.agent), \(worker.origin)\(takesSuggestion ? "" : ", read-only")")
    }
}

/// The cockpit's view of the tray's hand-offs. Draws nothing until there is one.
struct MultiplayerRemoteWorkerBand: View {
    var model: MultiplayerModel
    /// Zooms a remote worker in the cockpit. Without it, a tile opens its hand-off's window page.
    var onZoom: ((MultiplayerRemoteWorker) -> Void)? = nil
    /// The cockpit's keyboard focus among the remote tiles.
    var focus: FocusState<String?>.Binding? = nil

    var body: some View {
        let workers = model.share.remoteWorkers
        Group {
            if !workers.isEmpty {
                RemoteWorkerGroup(workers: workers, now: model.currentDate(),
                                  onOpen: { worker in
                                      if let onZoom { onZoom(worker) } else { MultiplayerRemoteWorkerLauncher.open(worker) }
                                  },
                                  onOpenAll: workers.first.map { first in
                                      { MultiplayerRemoteWorkerLauncher.openList(on: first.server) }
                                  },
                                  focus: focus)
                    .padding(.top, Metric.wallRowGap)
                    .transition(.opacity)
            }
        }
        .animation(MultiplayerTheme.Motion.ease(), value: workers.isEmpty)
        .onAppear { model.share.wallAppeared() }
        .onDisappear { model.share.wallDisappeared() }
    }
}

/// The cockpit's zoom view for one remote worker. It reads the worker's output while it is on
/// screen and stops when it leaves. Calls `onGone` when the hand-off is no longer listed. With
/// `allowsSuggestion` it keeps a suggestion draft of its own and sends it for the person.
struct MultiplayerRemoteWorkerZoomHost: View {
    var model: MultiplayerModel
    let workerID: String
    /// The footer button's title; nil leaves it out.
    var footerTitle: String? = "Open hand-off"
    var allowsSuggestion = false
    let onGone: () -> Void
    @State private var suggestion = ""
    @State private var reply: MultiplayerSentRequest?

    private func send(to worker: MultiplayerRemoteWorker) {
        let text = suggestion
        Task {
            // A refusal shows in the network's own banner; the draft stays for another try.
            if let value = await model.sendSuggestion(text, to: worker.resource, on: worker.server).value {
                reply = value
                suggestion = ""
            }
        }
    }

    var body: some View {
        let live = model.share.live
        let worker = model.share.remoteWorkers.first { $0.id == workerID }
        Group {
            if let worker {
                RemoteWorkerZoom(worker: worker, watch: live.zoomWatch,
                                 entry: model.share.entry(worker.resource, on: worker.server),
                                 color: MultiplayerTheme.swatch(for: worker.server), interval: 2, now: model.currentDate(),
                                 footerTitle: footerTitle, allowsSuggestion: allowsSuggestion, suggestion: $suggestion,
                                 reply: reply, isBusy: model.isBusy, onSuggest: { send(to: worker) },
                                 onRetry: { live.beginZoomWatch(worker.resource, on: worker.server) },
                                 onOpenTray: { MultiplayerRemoteWorkerLauncher.open(worker) })
                    .onAppear { if worker.canWatch { live.beginZoomWatch(worker.resource, on: worker.server) } }
                    .onChange(of: worker.canWatch) { _, can in
                        if can { live.beginZoomWatch(worker.resource, on: worker.server) } else { live.endZoomWatch() }
                    }
            } else {
                Color.clear.onAppear(perform: onGone)
            }
        }
        .onAppear { model.share.wallAppeared() }
        .onDisappear {
            live.endZoomWatch()
            model.share.wallDisappeared()
        }
    }
}

/// Opens the main window's Hand-offs page on a hand-off chosen on the wall. The tray had these
/// pages once; they are window pages now (DESIGN.md, "The triage tray").
@MainActor
enum MultiplayerRemoteWorkerLauncher {
    static func open(_ worker: MultiplayerRemoteWorker, with opener: MultiplayerWindowOpener = MultiplayerWindowOpener()) {
        MultiplayerWindowLink(page: .handoffDetail(request: worker.request), server: worker.server).map { opener.send($0.request) }
    }

    static func openList(on server: String, with opener: MultiplayerWindowOpener = MultiplayerWindowOpener()) {
        MultiplayerWindowLink(page: .handoffs, server: server).map { opener.send($0.request) }
    }
}
