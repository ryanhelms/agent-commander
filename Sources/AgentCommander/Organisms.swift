import AppKit
import SwiftUI

// ATOMIC LEVEL: Organisms.
// Distinct regions of the cockpit, each composed from molecules, atoms and the shared TerminalWell.
// Organisms receive presentation values and emit targeted actions. They hold no API access.
//
//   WorkerTile          = WorkerIdentity + WorkerLocation + TerminalWell + StatusLabel + NeedsInputFlag
//                         + InputOwnership (+ RequestReply in the focused variant)
//   NestedWorkerGroup   = disclosure header + WorkerTile row
//   WorkerWall          = WorkerTile rows + NestedWorkerGroup
//   CoordinatorConsole  = WorkerIdentity + StatusLabel + TerminalWell + AttentionNotice
//   AttentionStack      = WorkerIdentity + question well + RequestReply (the PiP)
//   RunHeader           = Breadcrumb + StatusLabel + run actions
//   NavigationRail      = BrandMark + NavigationRow

// MARK: - WorkerTile

struct WorkerTileActions {
    var toggleZoom: (() -> Void)? = nil
    var openRequest: (() -> Void)? = nil
    var copyID: () -> Void = {}
    var handBack: (() -> Void)? = nil
    /// Terminal input for this worker. Present only where the service supports it.
    var sendInput: ((String) -> Void)? = nil
}

/// One worker. The wall and the focused (zoomed) view are variants of this single type, so identity,
/// status, terminal output, actions and input ownership cannot drift apart between surfaces.
struct WorkerTile: View {
    enum Variant { case wall, focused }

    let worker: WorkerPresentation
    var variant: Variant = .wall
    var isKeyFocused = false
    /// Present in the focused variant when this worker's request is answered inline.
    var reply: ReplyContext? = nil
    var actions = WorkerTileActions()

    /// Laid-out height of the focused transcript, reported by the terminal well.
    @State private var transcriptHeight: CGFloat = 160

    private var isPending: Bool { worker.request != nil }
    private var isFocusedVariant: Bool { variant == .focused }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if isFocusedVariant { conversation } else { well }
            if let error = worker.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Palette.failure)
                    .lineLimit(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Palette.well)
            }
            if !isFocusedVariant {
                Hairline()
                footer
            }
            Hairline()
            InputOwnership(workerName: worker.name, control: worker.control,
                           isKeyFocused: isKeyFocused, handBack: actions.handBack)
                .padding(.horizontal, isFocusedVariant ? 13 : 7)
                .frame(minHeight: isFocusedVariant ? 44 : Metric.ownershipRowHeight)
                .background(Palette.footer)
            if isFocusedVariant, worker.control == .held, let sendInput = actions.sendInput {
                TerminalComposer(workerName: worker.name, send: sendInput)
            }
        }
        .panelSurface(edge: isPending ? Palette.attentionEdge : nil)
        .focusRing(isKeyFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
    }

    @ViewBuilder private var header: some View {
        if isFocusedVariant {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    WorkerIdentity(name: worker.name, client: worker.client, details: focusedDetails, density: .focused)
                    Spacer(minLength: 8)
                    StatusLabel(worker.state, size: 12)
                    actionMenu
                }
                .padding(.top, 17).padding(.horizontal, 20).padding(.bottom, 14)
                Hairline()
                HStack(spacing: 8) {
                    LineagePath(names: worker.lineage)
                    Spacer(minLength: 8)
                    Text("#\(worker.shortID)").font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                        .help("Worker \(worker.id)").accessibilityLabel("Worker ID \(worker.id)")
                }
                .padding(.horizontal, 19).padding(.vertical, 9)
            }
            .background(Palette.chrome)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    WorkerIdentity(name: worker.name, client: worker.client,
                                   details: [.init(text: worker.client.displayName)], density: .tile)
                    Spacer(minLength: 2)
                    actionMenu
                }
                .padding(.top, 12).padding(.horizontal, Metric.tileInset).padding(.bottom, 9)
                WorkerLocation(host: worker.host, location: worker.location, isBranch: worker.locationIsBranch)
                    .padding(.horizontal, Metric.tileInset).padding(.bottom, 9)
            }
            .background(Palette.chrome)
        }
    }

    private var focusedDetails: [WorkerIdentity.Detail] {
        var details: [WorkerIdentity.Detail] = [.init(text: worker.client.displayName), .init(text: worker.host)]
        if !worker.location.isEmpty {
            details.append(.init(symbol: worker.locationIsBranch ? "arrow.triangle.branch" : "folder", text: worker.location))
        }
        return details
    }

    /// Wall density: the terminal tail fills the tile.
    private var well: some View {
        ZStack(alignment: .topLeading) {
            Palette.well
            TerminalWell(output: worker.output, workerID: worker.id, workerName: worker.name,
                         fontSize: TypeRole.wallTerminalSize, inset: NSSize(width: 11, height: 12))
            if worker.output.isEmpty {
                Text(worker.task)
                    .font(.system(size: 12.7, design: .monospaced))
                    .foregroundStyle(.inkSecondary)
                    .padding(.horizontal, 11).padding(.vertical, 12)
                    .allowsHitTesting(false)
                    .accessibilityLabel("No output yet. Task: \(worker.task)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Focused worker: assignment, then the transcript, then the pending request directly after it.
    /// A short transcript takes only its own height, so the request sits partway down as in the
    /// concept. A long transcript scrolls inside the well and the request stays visible below it.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Concept spacing (.ck-focusbody): 19 top, assignment with an 18 pt bottom margin, turn
            // labels and an inset command block in the transcript, then the request in normal flow.
            if !worker.task.isEmpty {
                AssignmentBlock(label: assignmentLabel, time: worker.startedAt, text: worker.task, fontSize: 13)
                    .padding(.horizontal, 21).padding(.top, 19).padding(.bottom, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if worker.output.isEmpty {
                Text("Waiting for this worker's first output.")
                    .font(TypeRole.terminal).foregroundStyle(.inkSecondary)
                    .padding(.horizontal, 21).padding(.vertical, 14)
            } else {
                TerminalWell(output: worker.output, workerID: worker.id, style: .transcript, workerName: worker.name,
                             fontSize: TypeRole.focusTerminalSize, inset: NSSize(width: 21, height: 8),
                             onContentHeight: { transcriptHeight = $0 })
                    .frame(maxWidth: .infinity, maxHeight: transcriptHeight)
                    .layoutPriority(1)
            }
            if let request = worker.request, let reply {
                requestBlock(request, reply: reply)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Takes only the room left over. It never sets the transcript's or the request's size.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.well)
    }

    private var assignmentLabel: String {
        let parent = worker.lineage.dropLast().last
        return parent.map { "Assignment · \($0)" } ?? "Assignment"
    }

    private var footer: some View {
        HStack(spacing: 7) {
            StatusLabel(worker.state, size: 10.5)
            if let request = worker.request { NeedsInputFlag(request: request) }
            Spacer(minLength: 4)
            if let started = worker.startedAt {
                Text(started).font(TypeRole.timestamp).foregroundStyle(.inkSecondary)
                    .help("Started at \(started)").accessibilityLabel("Started at \(started)")
            }
        }
        .padding(.horizontal, Metric.tileInset).padding(.vertical, 9)
        .background(isPending ? Palette.attentionFooter : Palette.footer)
    }

    private func requestBlock(_ request: RequestPresentation, reply: ReplyContext) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left")
                Text("Needs input")
                Spacer(minLength: 8)
                Text(request.shortID).font(TypeRole.monoMeta).help("Request \(request.id)")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.attention)
            Text(request.question)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(hex: 0xEFE9D9))
                .lineLimit(8).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            RequestReply(request: request, context: reply)
        }
        .padding(.leading, 17).padding(.trailing, 14).padding(.vertical, 12)
        .background(Palette.attentionFill, in: shape)
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0xDFB476)).frame(width: 3) }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.attentionSoftEdge) }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            // Turn label for the request, in the same role as the transcript's turn labels.
            Text("REQUEST \(request.shortID)").font(TypeRole.kicker).tracking(1)
                .foregroundStyle(.inkSecondary)
                .offset(y: -14)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 21).padding(.top, 22).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Palette.well)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request \(request.shortID) from \(request.workerName)")
    }

    private var actionMenu: some View {
        Menu {
            if let toggleZoom = actions.toggleZoom {
                Button(isFocusedVariant ? "Return to wall" : "Zoom worker", action: toggleZoom)
            }
            if let openRequest = actions.openRequest {
                Button("Reply to request", action: openRequest)
            }
            Divider()
            Button("Copy worker ID", action: actions.copyID)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 23, height: 23)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.inkSecondary)
        .help("Actions for \(worker.name)")
        .accessibilityLabel("Actions for \(worker.name)")
    }

    private var summary: String {
        var parts = [worker.name, worker.client.displayName, "host \(worker.host)", worker.state.label]
        switch worker.control {
        case .observing(let holder): parts.append("input held by \(holder)")
        case .held: parts.append("you hold input")
        }
        if let request = worker.request { parts.append("request \(request.shortID) waiting") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - NestedWorkerGroup

/// A parent worker with the workers it delegated to. The header is one disclosure button.
struct NestedWorkerGroup<Content: View>: View {
    let name: String
    let nestedCount: Int
    let collapsed: Bool
    var hasRequest = false
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                    Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.foreground)
                    Text(nestedCount == 1 ? "1 nested worker" : "\(nestedCount) nested workers")
                        .font(.system(size: 10.5))
                    Spacer(minLength: 8)
                    if collapsed && hasRequest {
                        StatusLabel(text: "Needs input", tone: .attention, symbol: "questionmark.circle.fill", size: 10.5)
                    }
                }
                .foregroundStyle(.inkSecondary)
                .frame(minHeight: Metric.groupHeaderHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(nestedCount) nested")
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .accessibilityHint("Shows or hides this worker group")
            if !collapsed { content }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, collapsed ? 0 : 9)
        .background(Palette.groupFill, in: shape)
        .overlay { shape.strokeBorder(Palette.groupEdge) }
    }
}

// MARK: - WorkerWall

/// Multirow wall. Root workers without children fill rows of up to three; each parent with nested
/// workers gets a collapsible group. The last row can give way to the attention stack.
struct WorkerWall<Tile: View>: View {
    let layout: WallLayout
    let collapsed: Set<String>
    /// Width kept clear at the trailing edge of the last row for the PiP. Zero when no PiP is showing.
    var reservedTrailing: CGFloat = 0
    let toggleGroup: (String) -> Void
    @ViewBuilder let tile: (WorkerPresentation) -> Tile

    private struct Row: Identifiable {
        let id: String
        var leaves: [WorkerPresentation] = []
        var group: WorkerGroup? = nil
    }

    var body: some View {
        if layout.workers.isEmpty {
            ContentUnavailableView("Waiting for workers", systemImage: "terminal",
                                   description: Text("Delegated workers will appear here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let columns = max(1, min(3, Int((geo.size.width + Metric.tileGap) / (Metric.minimumTileWidth + Metric.tileGap))))
                let rows = makeRows(columns: columns)
                let heights = rowHeights(rows, columns: columns, available: geo.size.height)
                ScrollView(.vertical) {
                    VStack(spacing: Metric.wallRowGap) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, columns: columns, height: heights[index])
                                .padding(.trailing, reserve(for: row, isLast: index == rows.count - 1, count: rows.count))
                        }
                    }
                }
            }
        }
    }

    private func makeRows(columns: Int) -> [Row] {
        let leafRows = layout.leaves.chunked(into: columns).enumerated().map { index, chunk in
            Row(id: "leaves-\(index)", leaves: chunk)
        }
        return leafRows + layout.groups.map { Row(id: "group-\($0.id)", group: $0) }
    }

    private func isCollapsed(_ row: Row) -> Bool {
        row.group.map { collapsed.contains($0.id) } ?? false
    }

    private func reserve(for row: Row, isLast: Bool, count: Int) -> CGFloat {
        isLast && count > 1 && !isCollapsed(row) ? reservedTrailing : 0
    }

    /// Leaf rows weigh 1.1 against 1 for a group's tile row, as in the concept (flex 1.1 : 1).
    private func rowHeights(_ rows: [Row], columns: Int, available: CGFloat) -> [CGFloat] {
        let collapsedHeight = Metric.groupHeaderHeight + 2
        let weights: [CGFloat] = rows.map { row in
            guard let group = row.group else { return 1.1 }
            if collapsed.contains(group.id) { return 0 }
            return CGFloat(max(1, group.all.chunked(into: columns).count))
        }
        let fixed = CGFloat(rows.filter(isCollapsed).count) * collapsedHeight
        let gaps = CGFloat(max(0, rows.count - 1)) * Metric.wallRowGap
        let total = max(1, weights.reduce(0, +))
        let unit = max(0, available - fixed - gaps) / total
        return weights.map { weight in
            weight == 0 ? collapsedHeight : max(Metric.minimumWallRowHeight * max(1, weight.rounded(.down)), unit * weight)
        }
    }

    @ViewBuilder private func rowView(_ row: Row, columns: Int, height: CGFloat) -> some View {
        if let group = row.group {
            let isClosed = collapsed.contains(group.id)
            NestedWorkerGroup(name: group.parent.name, nestedCount: group.members.count, collapsed: isClosed,
                              hasRequest: group.all.contains { $0.request != nil },
                              toggle: { toggleGroup(group.id) }) {
                VStack(spacing: 9) {
                    ForEach(Array(group.all.chunked(into: columns).enumerated()), id: \.offset) { _, chunk in
                        tileRow(chunk)
                    }
                }
            }
            .frame(height: isClosed ? nil : height)
        } else {
            tileRow(row.leaves).frame(height: height)
        }
    }

    private func tileRow(_ workers: [WorkerPresentation]) -> some View {
        HStack(spacing: Metric.tileGap) {
            ForEach(workers) { worker in
                tile(worker).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - CoordinatorConsole

/// The coordinator in the stationary left pane: who it is, the assignment the developer gave this
/// run, its live terminal output and any request waiting inside the run.
struct CoordinatorConsole: View {
    let coordinator: WorkerPresentation
    let assignment: String
    let startedAt: String?
    let awaiting: [RequestPresentation]
    var isKeyFocused = false
    /// Sends a message to the coordinator. Present only where the service supports it.
    var sendMessage: ((String) -> Void)? = nil
    let openRequest: (RequestPresentation) -> Void
    /// Laid-out height of the transcript, reported by the terminal well.
    @State private var transcriptHeight: CGFloat = 160

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                WorkerIdentity(name: coordinator.name, client: coordinator.client, details: details, density: .console)
                Spacer(minLength: 8)
                StatusLabel(coordinator.state, size: 10.5)
            }
            .padding(.horizontal, 17).padding(.vertical, 16)
            .background(Palette.chrome)
            Hairline()
            // Assignment, transcript, then any waiting request directly after the transcript. A long
            // transcript scrolls inside its well while the notices stay visible beneath it.
            VStack(alignment: .leading, spacing: 0) {
                AssignmentBlock(label: "You", time: startedAt, text: assignment)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
                if coordinator.output.isEmpty {
                    Text("Waiting for the coordinator's first output.")
                        .font(TypeRole.terminalSmall).foregroundStyle(.inkSecondary)
                } else {
                    TerminalWell(output: coordinator.output, workerID: coordinator.id, workerName: coordinator.name,
                                 fontSize: 12.5, inset: NSSize(width: 0, height: 2),
                                 onContentHeight: { transcriptHeight = $0 })
                        .frame(maxWidth: .infinity, maxHeight: transcriptHeight)
                        .layoutPriority(1)
                }
                if let error = coordinator.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(Palette.failure).lineLimit(4).textSelection(.enabled)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(awaiting) { request in
                    AttentionNotice(request: request, detail: detail(for: request)) { openRequest(request) }
                        .padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 18).padding(.horizontal, 17).padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.well)
            if let sendMessage {
                Hairline()
                TerminalComposer(workerName: coordinator.name, prompt: "Message coordinator…",
                                 outlined: false, send: sendMessage)
            }
        }
        .panelSurface()
        .focusRing(isKeyFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coordinator \(coordinator.name), \(coordinator.state.label)")
    }

    private var details: [WorkerIdentity.Detail] {
        var details: [WorkerIdentity.Detail] = [.init(text: coordinator.host)]
        if !coordinator.location.isEmpty {
            details.append(.init(symbol: coordinator.locationIsBranch ? "arrow.triangle.branch" : "folder",
                                 text: coordinator.location))
        }
        return details
    }

    private func detail(for request: RequestPresentation) -> String {
        request.workerIsCoordinator ? "Request \(request.shortID)" : "\(request.inputHolder) → \(request.workerName)"
    }
}

// MARK: - AttentionStack (PiP)

/// Floating request from any run. The front card names its source and carries the shared
/// RequestReply; the back card identifies the next waiting worker. Arrival never takes focus.
struct AttentionStack: View {
    let current: RequestPresentation
    let next: RequestPresentation?
    let position: Int
    let count: Int
    let reply: ReplyContext
    let showNext: () -> Void
    let expand: () -> Void
    let close: () -> Void

    var body: some View {
        // Layered stack: the opaque back card sits behind and above the front card, with its own lit
        // edge, so the next request reads as a separate sheet.
        VStack(spacing: -6) {
            if let next {
                let backShape = RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous)
                Button(action: showNext) {
                    HStack(spacing: 7) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 10))
                        Text(next.workerName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(next.runTitle) · \(next.shortID)").font(.system(size: 10)).lineLimit(1)
                    }
                    .foregroundStyle(Color(hex: 0xC6C8D2))
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(LinearGradient(colors: [Palette.stackBackTop, Palette.stackBackBottom],
                                           startPoint: .top, endPoint: .bottom), in: backShape)
                .overlay {
                    backShape.strokeBorder(LinearGradient(colors: [Palette.rimBright, Palette.rimDim],
                                                          startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 12)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                .help("Show the request from \(next.workerName)")
                .accessibilityLabel("Next request: \(next.workerName) in \(next.runTitle)")
            }
            front.zIndex(1)
        }
        .shadow(color: .black.opacity(0.62), radius: 22, y: 13)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request from \(current.workerName) in \(current.runTitle)")
    }

    private var front: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "bell").font(.system(size: 11))
                Text("Needs attention").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if count > 1 {
                    Button(action: showNext) {
                        Text("\(position) of \(count)").font(TypeRole.monoMeta)
                    }
                    .buttonStyle(.plain)
                    .help("Show next request")
                    .accessibilityLabel("Request \(position) of \(count). Show next.")
                }
                SymbolButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Show \(current.workerName) in its run",
                             size: 10, action: expand)
                SymbolButton(symbol: "xmark", label: "Hide this request", size: 10, action: close)
            }
            .foregroundStyle(Palette.attention)
            .padding(.leading, 13).padding(.trailing, 8).padding(.vertical, 2)
            Hairline()
            // Spacing and insets are 14 pt tighter in total than the first pass, per the measured capture.
            VStack(alignment: .leading, spacing: 8) {
                WorkerIdentity(name: current.workerName, client: current.client,
                               details: [.init(text: current.runTitle), .init(text: current.host), .init(text: current.shortID)],
                               density: .pip)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(current.contextTail.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.inkSecondary).lineLimit(1)
                        }
                        Text(current.question)
                            .font(TypeRole.terminalSmall).lineSpacing(3)
                            .foregroundStyle(Color(hex: 0xDAE0E6))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 132)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.inkHairline) }
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left").font(.system(size: 10))
                    Text("Reply to \(current.shortID)")
                    Spacer(minLength: 8)
                    Text("Input · \(current.inputHolder)").lineLimit(1)
                        .accessibilityLabel("Terminal input is held by \(current.inputHolder)")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0xD5D9E5))
                RequestReply(request: current, context: reply)
            }
            .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 12)
        }
        .glassSurface(.floating, radius: Radius.overlay)
    }
}

// MARK: - RunHeader

/// Identity and state of the selected run with its run-level actions.
struct RunHeader: View {
    let run: RunContent
    let canStop: Bool
    @Binding var showingDetails: Bool
    let showRuns: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text(run.project).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).opacity(0.7)
                    Button("Runs", action: showRuns).buttonStyle(.plain)
                        .accessibilityLabel("Show projects and runs")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).opacity(0.7)
                    Text(run.shortID).font(TypeRole.monoID).help("Run \(run.id)").accessibilityLabel("Run \(run.id)")
                    if let startedAt = run.startedAt {
                        Text("· Started \(startedAt)").font(.system(size: 11))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.inkSecondary)
                HStack(spacing: 14) {
                    Text(run.title).font(TypeRole.pageTitle).tracking(-1.1)
                        .foregroundStyle(Palette.foreground).lineLimit(1).help(run.task)
                        .accessibilityAddTraits(.isHeader)
                    StatusLabel(run.status, pill: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                Label(run.wall.workers.count == 1 ? "1 worker" : "\(run.wall.workers.count) workers",
                      systemImage: "square.stack.3d.up")
                    .foregroundStyle(.inkSecondary)
                if !run.awaiting.isEmpty {
                    Label("\(run.awaiting.count) awaiting input", systemImage: "bell")
                        .foregroundStyle(Palette.attention)
                }
                Hairline(vertical: true).frame(height: 17)
                Button { showingDetails.toggle() } label: {
                    Label("Run details", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(CapsuleButtonStyle(height: 31))
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) { RunDetails(run: run) }
                Menu {
                    Button("Stop run…", role: .destructive, action: stop).disabled(!canStop)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 33, height: 31)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .overlay { Capsule().strokeBorder(Palette.controlEdge).allowsHitTesting(false) }
                .accessibilityLabel("Run actions")
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, Metric.runHeaderInset)
        .frame(maxWidth: .infinity, minHeight: Metric.runHeaderHeight, alignment: .leading)
    }
}

/// Facts about a run that the service reports. Absent metadata is left out.
struct RunDetails: View {
    let run: RunContent

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Kicker(text: "Run details")
            Text(run.title).font(TypeRole.section).foregroundStyle(Palette.foreground).lineLimit(2)
            Hairline()
            KeyValueRow(key: "Project", value: run.project)
            KeyValueRow(key: "Directory", value: PathDisplay.abbreviated(run.path), monospaced: true)
            if let branch = run.branch { KeyValueRow(key: "Branch", value: branch, monospaced: true) }
            KeyValueRow(key: "Coordinator", value: run.client.displayName)
            KeyValueRow(key: "Run ID", value: run.id, monospaced: true)
            if let startedAt = run.startedAt { KeyValueRow(key: "Started", value: startedAt, monospaced: true) }
            Hairline()
            Kicker(text: "Assignment")
            ScrollView {
                Text(run.task).font(TypeRole.terminalSmall).foregroundStyle(Palette.terminalText)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
    }
}

// MARK: - NavigationRail

struct NavigationGroup: Identifiable {
    let id: String
    var title: String? = nil
    let items: [NavigationItem]
}

/// Glass navigation: a 54 pt rail, or a 204 pt sidebar with labels when expanded.
struct NavigationRail: View {
    let groups: [NavigationGroup]
    var footer: [NavigationItem] = []
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark()
                if expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Commander").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text("Local service").font(.system(size: 11)).foregroundStyle(.inkSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.horizontal, expanded ? 5 : 0)
            .padding(.bottom, expanded ? 18 : 14)
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if expanded, let title = group.title {
                    Kicker(text: title).padding(.horizontal, 10).padding(.top, index == 0 ? 0 : 18).padding(.bottom, 7)
                } else if index > 0 {
                    Hairline().padding(.vertical, 10)
                }
                ForEach(group.items) { item in
                    NavigationRow(item: item, expanded: expanded).padding(.vertical, 2)
                }
            }
            Spacer(minLength: 8)
            if !footer.isEmpty {
                Hairline().padding(.bottom, 9)
                ForEach(footer) { item in
                    NavigationRow(item: item, expanded: expanded).padding(.vertical, 2)
                }
            }
        }
        .padding(.top, expanded ? 18 : 14)
        .padding(.horizontal, expanded ? 12 : 6)
        .padding(.bottom, expanded ? 15 : 8)
        .frame(width: expanded ? Metric.sidebarWidth : Metric.railWidth)
        .frame(maxHeight: .infinity)
        .glassSurface(.navigation, radius: Radius.sidebar)
        .padding(.leading, Metric.navigationLeading)
        .padding(.trailing, Metric.navigationTrailing)
        .padding(.bottom, Metric.navigationBottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }
}

// MARK: - RunChooser

/// Projects and their runs, newest first, for switching the selected run.
struct RunChooser: View {
    let runs: [RunSummary]
    let selected: String?
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects and runs").font(.headline)
            if runs.isEmpty {
                Text("No runs yet.").foregroundStyle(.inkSecondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let groups = Dictionary(grouping: runs, by: \.path)
                        ForEach(groups.keys.sorted(), id: \.self) { path in
                            let projectRuns = groups[path] ?? []
                            VStack(alignment: .leading, spacing: 4) {
                                Label(projectRuns.first?.project ?? path, systemImage: "folder")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(PathDisplay.abbreviated(path)).font(.caption).foregroundStyle(.inkSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                                ForEach(projectRuns.reversed()) { run in
                                    Button { choose(run.id) } label: {
                                        HStack {
                                            Image(systemName: run.id == selected ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(run.id == selected ? Palette.working : Palette.secondary)
                                            Text(run.title).lineLimit(1)
                                            Spacer()
                                            StatusLabel(run.status, size: 11)
                                        }
                                        .padding(.vertical, 4).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(run.title), \(run.status.label)")
                                    .accessibilityAddTraits(run.id == selected ? .isSelected : [])
                                }
                            }
                            .padding(.vertical, 4)
                            Hairline()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .foregroundStyle(Palette.foreground)
        .padding(16)
        .frame(width: 365, alignment: .leading)
    }
}
