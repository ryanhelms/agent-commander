import AppKit
import SwiftUI

// ATOMIC LEVEL: Organisms (attention queue and workspace views).
// Each organism presents one coherent activity from values and emits targeted actions.
//
//   DataTable             = WeightedRow header + rows of caller-supplied cells
//   AgentConsoleCard      = role + identity + ConsolePreview + ValueTag/StatusLabel
//   CoordinatorSummary    = run lead + worker tree (built from the production RunContent)
//   RequestList           = selectable RequestPresentation rows + resolved history
//   RequestInspector      = WorkerIdentity + question + TerminalWell + LineagePath + RequestReply
//   RuleInspector         = FilterChip clauses that decide a smart view's membership
//   CheckoutComparison    = DataTable of identity evidence + Callout + explicit decision

// MARK: - DataTable

/// Header and rows on shared column weights. Cells are supplied per row and column.
struct DataTable<Row: Identifiable, Cell: View>: View {
    let headers: [String]
    let weights: [CGFloat]
    let rows: [Row]
    var carded = true
    var rowHeight: CGFloat = 54
    @ViewBuilder let cell: (Row, Int) -> Cell

    var body: some View {
        if carded { table.panelSurface() } else { table }
    }

    private var table: some View {
        VStack(spacing: 0) {
            WeightedRow(weights: weights) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(header).font(.system(size: 12, weight: .semibold)).foregroundStyle(.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color.white.opacity(0.03))
            ForEach(rows) { row in
                Hairline()
                WeightedRow(weights: weights) {
                    ForEach(0..<headers.count, id: \.self) { column in
                        cell(row, column).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: rowHeight)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - AgentConsoleCard

/// An agent anywhere in the workspace, as the overview shows it.
struct AgentConsole: Identifiable, Equatable {
    let id: String
    let title: String
    let role: String
    let client: AgentClient
    let host: String
    let isRemote: Bool
    let branch: String
    let project: String
    let runID: String
    let state: String
    let tone: Tone
    let lines: [ConsolePreview.Line]

    var isCoordinator: Bool { role == "Coordinator" }
}

/// Overview tile: who the agent is, a passive console snapshot, its worktree and its state.
struct AgentConsoleCard: View {
    @Environment(\.usesStrongContrast) private var usesStrongContrast
    let agent: AgentConsole
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(agent.role, systemImage: agent.isCoordinator ? "square.stack.3d.up" : "terminal")
                            .font(.system(size: 12)).foregroundStyle(Term.text)
                        Spacer(minLength: 8)
                        Text(agent.runID).font(TypeRole.monoMeta).foregroundStyle(Term.text)
                    }
                    HStack(spacing: 8) {
                        AgentAvatar(client: agent.client, size: 18, onHarnessHeader: true)
                        Text(agent.title).font(.system(size: 18, weight: .semibold)).tracking(-0.4)
                            .foregroundStyle(Palette.foreground).lineLimit(1)
                    }
                    Text("\(agent.project)  /  \(agent.client.displayName)  ·  \(agent.host)")
                        .font(.system(size: 12)).foregroundStyle(Term.text).lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .harnessHeaderFill(agent.client)
                Hairline()
                ConsolePreview(lines: agent.lines)
                Hairline()
                HStack {
                    MetaItem(symbol: "arrow.triangle.branch", text: agent.branch, help: "Branch \(agent.branch)")
                    Spacer(minLength: 8)
                    StatusLabel(text: agent.state, tone: agent.tone, size: 11.5)
                }
                .padding(.horizontal, 16).frame(height: 33)
                .background(Palette.footer)
            }
            .panelSurface(edge: HarnessAccentStore.shared.accent(for: agent.client).edge(strong: usesStrongContrast))
            .harnessAttentionInset(agent.tone == .attention, cornerRadius: Radius.tile)
            .registersHarness(agent.client)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.title), \(agent.role), \(agent.client.displayName) on \(agent.host), \(agent.state)")
        .accessibilityHint("Opens this agent's console")
    }
}

// MARK: - CoordinatorSummary

/// The lead coordinator of a project: its assignment and place, with the workers it delegated to.
struct CoordinatorSummary: View {
    let run: RunContent
    let open: () -> Void
    let openWorker: (WorkerPresentation) -> Void

    private struct Node: Identifiable {
        let worker: WorkerPresentation
        let nested: Bool
        var id: String { worker.id }
    }

    private var nodes: [Node] {
        run.wall.leaves.map { Node(worker: $0, nested: false) }
            + run.wall.groups.flatMap { group in
                [Node(worker: group.parent, nested: false)] + group.members.map { Node(worker: $0, nested: true) }
            }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("Coordinator", systemImage: "square.stack.3d.up")
                        .font(.system(size: 13)).foregroundStyle(Color(hex: 0xC9D3F2))
                    ValueTag(symbol: nil, text: run.shortID)
                }
                Text(run.title).font(.system(size: 28, weight: .semibold)).tracking(-0.9)
                    .foregroundStyle(Palette.foreground).lineLimit(1)
                Text(run.task).font(TypeRole.body).foregroundStyle(.inkSecondary).lineLimit(2)
                HStack(spacing: 7) {
                    Image(systemName: "desktopcomputer").font(.system(size: 11))
                    Text([run.coordinator?.host, run.client.displayName].compactMap { $0 }.joined(separator: "  ·  "))
                    if let branch = run.branch {
                        Text("·")
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(branch)
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.inkSecondary)
                Button(action: open) { Label("Open coordinator", systemImage: "arrow.right") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Hairline(vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Workers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.foreground)
                    .padding(.bottom, 4)
                ForEach(nodes) { node in
                    Button { openWorker(node.worker) } label: {
                        HStack(spacing: 9) {
                            Rectangle().fill(Color.white.opacity(0.22)).frame(width: 12, height: 1)
                            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.inkSecondary)
                            Text(node.worker.name).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.foreground).lineLimit(1)
                            Spacer(minLength: 8)
                            StatusLabel(node.worker.state, size: 11.5)
                        }
                        .padding(.leading, node.nested ? 27 : 0)
                        .frame(minHeight: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(node.worker.name), \(node.worker.state.label)\(node.nested ? ", nested" : "")")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24).padding(.vertical, 24)
    }
}

/// A further coordinator in the project, as one row.
struct CoordinatorRow: View {
    let run: RunContent
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                IconTile(symbol: "square.stack.3d.up")
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                    Text([run.shortID, run.client.displayName, run.coordinator?.host].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 12)).foregroundStyle(.inkSecondary)
                }
                Spacer(minLength: 12)
                StatusLabel(run.status, size: 12)
                Text(run.wall.workers.count == 1 ? "1 worker" : "\(run.wall.workers.count) workers")
                    .font(.system(size: 12)).foregroundStyle(.inkSecondary)
                if !run.awaiting.isEmpty {
                    StatusLabel(text: "\(run.awaiting.count) awaiting input", tone: .attention,
                                symbol: "questionmark.circle.fill", size: 12)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.inkSecondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(run.title), \(run.status.label). Open coordinator.")
    }
}

// MARK: - RequestList

struct ResolvedRequest: Identifiable, Equatable {
    let id: String
    let workerName: String
    let time: String
}

/// Pending decisions across runs, one selectable row each, with today's resolved requests below.
struct RequestList: View {
    let requests: [RequestPresentation]
    let resolved: [ResolvedRequest]
    let selection: String?
    let select: (RequestPresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(requests) { request in
                let isSelected = request.id == selection
                Button { select(request) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            StatusLabel(request.workerState, size: 11.5)
                            Spacer(minLength: 8)
                            Text(request.shortID).font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                        }
                        Text(request.workerName).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.foreground)
                        Text(request.question).font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xD3D6E0))
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(request.runTitle)  ·  \(request.host)").font(TypeRole.meta).foregroundStyle(.inkSecondary)
                    }
                    .padding(.horizontal, 15).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .selectionCard(isSelected)
                    .overlay(alignment: .leading) {
                        if isSelected {
                            UnevenRoundedRectangle(topLeadingRadius: Radius.field, bottomLeadingRadius: Radius.field)
                                .fill(Palette.working).frame(width: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Request \(request.shortID) from \(request.workerName) in \(request.runTitle). \(request.question)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            if !resolved.isEmpty {
                Hairline().padding(.top, 10)
                Kicker(text: "Resolved today").padding(.top, 8).padding(.leading, 5)
                ForEach(resolved) { item in
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.inkSecondary)
                        Text(item.workerName).font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xD3D6E0))
                        Spacer(minLength: 8)
                        Text(item.time).font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                    }
                    .padding(.horizontal, 5).frame(minHeight: 24)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - RequestInspector

/// One pending request with the context needed to answer it: who asked, the question, recent
/// terminal output and the worker's lineage. The reply is the shared RequestReply.
struct RequestInspector: View {
    let request: RequestPresentation
    /// The requesting worker, when its run is loaded. Supplies lineage and the terminal tail.
    let worker: WorkerPresentation?
    let reply: ReplyContext
    var takeControl: (() -> Void)? = nil
    let openWorker: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Text("REQUEST \(request.shortID)").font(TypeRole.kicker).tracking(1.1)
                        .foregroundStyle(Color(hex: 0xD5D9E5))
                    if let started = worker?.startedAt {
                        Text(started).font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                    }
                }
                Text("\(request.workerName) needs a decision").font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                    .foregroundStyle(Palette.foreground).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text("\(request.project)  ·  \(request.runTitle)  ·  \(request.runID)")
                    .font(TypeRole.meta).foregroundStyle(.inkSecondary)
            }
            .padding(.bottom, 18)
            Hairline()
            Kicker(text: "Requesting worker").padding(.top, 18).padding(.bottom, 11)
            HStack {
                WorkerIdentity(name: request.workerName, client: request.client, details: identityDetails,
                               density: .console)
                Spacer(minLength: 12)
                Button(action: openWorker) { Label("Open worker", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(CapsuleButtonStyle(height: 33))
            }
            question.padding(.top, 16)
            if let worker, !worker.output.isEmpty || !worker.transcript.isEmpty {
                HStack {
                    AgentAvatar(client: worker.client, size: 16, onHarnessHeader: true)
                    Kicker(text: "Recent output")
                    Spacer()
                    ConsoleModeTitlebarControl(consoleID: worker.id, consoleName: worker.name, client: worker.client)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .harnessHeaderFill(worker.client)
                .padding(.top, 18)
                ConsoleScrollback(consoleID: worker.id, entries: worker.transcript, rawOutput: worker.output, density: .compact, horizontalInset: 8) {
                    TerminalWell(output: worker.output, workerID: worker.id, workerName: worker.name,
                                 fontSize: 12.5, inset: NSSize(width: 14, height: 11))
                }
                    .frame(height: 124)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: 6))
                    .harnessAccentOutline(worker.client, cornerRadius: 6)
                LineagePath(names: worker.lineage).padding(.top, 13)
            }
            Spacer(minLength: 16)
            Hairline()
            HStack(spacing: 10) {
                Label("Terminal input · \(request.inputHolder)", systemImage: "eye")
                    .font(.system(size: 12)).foregroundStyle(.inkSecondary).lineLimit(1)
                    .accessibilityLabel("Terminal input is held by \(request.inputHolder)")
                Spacer(minLength: 12)
                RequestReply(request: request, context: reply).frame(maxWidth: 380)
                if let takeControl {
                    Button(action: takeControl) { Label("Take terminal control", systemImage: "hand.raised") }
                        .buttonStyle(CapsuleButtonStyle(height: 33))
                }
            }
            .padding(.top, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request \(request.shortID) from \(request.workerName)")
    }

    private var identityDetails: [WorkerIdentity.Detail] {
        var details = [WorkerIdentity.Detail(text: request.client.displayName), WorkerIdentity.Detail(text: request.host)]
        if let worker, !worker.location.isEmpty { details.append(WorkerIdentity.Detail(text: worker.location)) }
        return details
    }

    private var question: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return VStack(alignment: .leading, spacing: 9) {
            Label("Question for you", systemImage: "bubble.left")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.attention)
            Text(request.question).font(.system(size: 15, weight: .medium)).foregroundStyle(Color(hex: 0xEFE9D9))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Your answer applies to this request only.").font(.system(size: 12)).foregroundStyle(Color(hex: 0xBBAD91))
        }
        .padding(.leading, 17).padding(.trailing, 14).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.attentionFill, in: shape)
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0xDFB476)).frame(width: 3) }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.attentionSoftEdge) }
    }
}

// MARK: - RuleInspector

/// One rule of a smart view: the attribute it tests and the values it may take.
struct ViewRule: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let options: [String]
    var value: String
}

/// The rules that decide which agents a smart view contains. Editing a rule changes membership.
struct RuleInspector: View {
    @Binding var rules: [ViewRule]
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("View rules", systemImage: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                .accessibilityAddTraits(.isHeader)
            Text("Match all of the following rules.").font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                .padding(.top, 9).padding(.bottom, 14)
            ForEach($rules) { $rule in
                Hairline()
                VStack(alignment: .leading, spacing: 8) {
                    Text(rule.name).font(.system(size: 12)).foregroundStyle(.inkSecondary)
                    FilterChip(name: rule.name, symbol: rule.symbol, options: rule.options, selection: $rule.value)
                }
                .padding(.vertical, 13)
            }
            Hairline()
            Label(footnote, systemImage: "eye").font(.system(size: 12)).foregroundStyle(.inkSecondary)
                .padding(.top, 15)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View rules")
    }
}

// MARK: - CheckoutComparison

struct IdentityCheck: Identifiable, Equatable {
    let id: String
    let project: String
    let candidate: String
    var isBranch = false
    var agrees = true
}

/// Identity evidence for a candidate checkout beside the project's, with an explicit decision.
struct CheckoutComparison: View {
    enum Decision: Equatable { case undecided, linked, separate }

    let projectName: String
    let checks: [IdentityCheck]
    let noticeTitle: String
    let noticeDetail: String
    @Binding var decision: Decision

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Compare checkouts") {
                switch decision {
                case .undecided: StatusLabel(text: "Decision needed", tone: .attention, symbol: "questionmark.circle.fill", size: 12)
                case .linked: StatusLabel(text: "Linked to \(projectName)", tone: .working, symbol: "checkmark.circle.fill", size: 12)
                case .separate: StatusLabel(text: "Kept separate", tone: .neutral, symbol: "minus.circle", size: 12)
                }
            }
            DataTable(headers: ["Identity check", "\(projectName) project", "Candidate checkout"],
                      weights: [28, 36, 36], rows: checks, carded: false) { check, column in
                switch column {
                case 0:
                    Text(check.id).font(.system(size: 13)).foregroundStyle(.inkSecondary)
                case 1:
                    value(check.project, isBranch: check.isBranch, agrees: true)
                default:
                    value(check.candidate, isBranch: check.isBranch, agrees: check.agrees)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: Radius.field).strokeBorder(.inkHairline) }
            .clipShape(RoundedRectangle(cornerRadius: Radius.field))
            switch decision {
            case .undecided:
                Callout(symbol: "exclamationmark.triangle", title: noticeTitle, detail: noticeDetail, tone: .attention)
            case .linked:
                Callout(symbol: "link", title: "Checkout linked",
                        detail: "Runs started in this checkout now appear under \(projectName). You can unlink it from the project's linked checkouts.")
            case .separate:
                Callout(symbol: "folder", title: "Checkout kept separate",
                        detail: "It stays its own project. Commander will not offer this match again unless its identity changes.")
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if decision == .undecided {
                    Button("Keep separate") { decision = .separate }.buttonStyle(CapsuleButtonStyle())
                    Button { decision = .linked } label: { Label("Link to \(projectName)", systemImage: "link") }
                        .buttonStyle(CapsuleButtonStyle(prominent: true))
                } else {
                    Button("Review again") { decision = .undecided }.buttonStyle(CapsuleButtonStyle())
                }
            }
        }
        .padding(24)
        .panelSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checkout comparison")
    }

    @ViewBuilder private func value(_ text: String, isBranch: Bool, agrees: Bool) -> some View {
        if isBranch {
            ValueTag(text: text)
        } else {
            Text(text).font(.system(size: 13, design: .monospaced))
                .foregroundStyle(agrees ? Palette.foreground : Palette.attention)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
