import SwiftUI

// ATOMIC LEVEL: Organism for the cockpit wall, with its values.
// A hand-off runs on a friend's Mac, so it has no terminal here. The wall shows it as a remote
// worker: the same console title bar, harness surface and status label as a local worker tile,
// named for the friend's agent and labelled with the friend and the server it went through.
// Opening one opens the tray on that hand-off. Nothing here sends anything.
//   Values:    MultiplayerRemoteWorker
//   Molecule:  RemoteWorkerTile
//   Organism:  RemoteWorkerGroup, MultiplayerRemoteWorkerBand (reads the tray's model)

/// One hand-off you sent, as the wall shows it.
struct MultiplayerRemoteWorker: Identifiable, Equatable {
    let server: String
    let request: String
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
                server: pending.server, request: row.request,
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

    /// Opens the tray's page for one remote worker.
    func open(_ worker: MultiplayerRemoteWorker) {
        open(.handoffDetail(request: worker.request), on: worker.server)
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
        .help(onOpen == nil ? worker.spoken : "Open this hand-off in the network tray")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(worker.spoken)
        .accessibilityAddTraits(onOpen == nil ? .isStaticText : .isButton)
        .accessibilityHint(onOpen == nil ? "" : "Opens the hand-off in the network tray")
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
        let shown = Array(workers.prefix(Self.limit))
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11))
                Text("Remote workers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text(workers.count == 1 ? "1 hand-off on a friend’s Mac" : "\(workers.count) hand-offs on friends’ Macs")
                    .font(.system(size: 10.5))
                Spacer(minLength: 8)
                if workers.count > shown.count, let onOpenAll {
                    Button("\(workers.count - shown.count) more…", action: onOpenAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .accessibilityLabel("Show \(workers.count - shown.count) more hand-offs in the network tray")
                }
            }
            .foregroundStyle(.inkSecondary)
            .frame(minHeight: Metric.groupHeaderHeight)
            .accessibilityElement(children: .contain)
            HStack(spacing: Metric.tileGap) {
                ForEach(shown) { worker in
                    RemoteWorkerTile(worker: worker, now: now, onOpen: onOpen.map { open in { open(worker) } })
                        .frame(maxWidth: .infinity)
                }
                // Keeps a lone tile at a column's width instead of stretching across the wall.
                ForEach(0..<max(0, min(2, Self.limit - shown.count)), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                }
            }
            .frame(height: Self.tileHeight)
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 9)
        .background(Palette.groupFill, in: shape)
        .overlay { shape.strokeBorder(Palette.groupEdge) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remote workers")
    }
}

/// The cockpit's view of the tray's hand-offs. Draws nothing until there is one.
struct MultiplayerRemoteWorkerBand: View {
    var model: MultiplayerModel

    var body: some View {
        let workers = model.share.remoteWorkers
        Group {
            if !workers.isEmpty {
                RemoteWorkerGroup(workers: workers, now: model.currentDate(),
                                  onOpen: { MultiplayerRemoteWorkerLauncher.open($0, in: model) },
                                  onOpenAll: workers.first.map { first in
                                      { MultiplayerRemoteWorkerLauncher.openList(on: first.server, in: model) }
                                  })
                    .padding(.top, Metric.wallRowGap)
                    .transition(.opacity)
            }
        }
        .animation(MultiplayerTheme.Motion.ease(), value: workers.isEmpty)
        .onAppear { model.share.wallAppeared() }
        .onDisappear { model.share.wallDisappeared() }
    }
}

/// Opens the tray in its own window on a hand-off chosen on the wall.
@MainActor
enum MultiplayerRemoteWorkerLauncher {
    static func open(_ worker: MultiplayerRemoteWorker, in model: MultiplayerModel) {
        MultiplayerLinkWindow.show(model)
        model.go(.home)
        model.share.open(worker)
    }

    static func openList(on server: String, in model: MultiplayerModel) {
        MultiplayerLinkWindow.show(model)
        model.go(.home)
        model.share.open(.handoffs, on: server)
    }
}
