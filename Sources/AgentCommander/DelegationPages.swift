import SwiftUI

// ATOMIC LEVEL: Pages (delegation and review), each filling the TaskSheet template.
//
//   DelegateWorkerPage  form: LabeledField/MenuField/TextArea/ChoiceRow    aside: snapshot preview
//   IntegrationPage     form: DataTable + VerificationLog + AttemptHistory  aside: target evidence
//   HistoryPage         form: SearchField + FilterChip + match list         aside: TranscriptInspector
//   CrossRunPage        form: worker + shared transcript + question         aside: access decision
//
// The organisms they share sit above the pages. Every page takes its content as values and keeps
// only presentation state; the actions it would send to the service leave through closures.

// MARK: - Organisms

struct LogLine: Identifiable, Equatable {
    let id: Int
    /// RUN, PASS or FAIL, when the line carries a result.
    var tag: String? = nil
    let text: String
}

/// Numbered output of one verification command.
struct VerificationLog: View {
    let lines: [LogLine]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%02d", line.id)).foregroundStyle(Color(hex: 0x6F7483))
                    if let tag = line.tag {
                        Text(tag).fontWeight(tag == "FAIL" ? .bold : .regular).foregroundStyle(color(for: tag))
                    }
                    Text(line.text).foregroundStyle(Palette.terminalText)
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(.horizontal, 15).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.well, in: shape)
        .overlay { shape.strokeBorder(.inkEdge) }
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verification output. " + lines.map { [$0.tag, $0.text].compactMap { $0 }.joined(separator: " ") }.joined(separator: ". "))
    }

    private func color(for tag: String) -> Color {
        switch tag {
        case "PASS": Color(hex: 0xA5D7B6)
        case "FAIL": Palette.failure
        default: Palette.terminalDim
        }
    }
}

struct IntegrationAttempt: Identifiable, Equatable {
    enum Outcome: Equatable { case passed, failed, stale, conflict }

    let id: String
    let title: String
    let time: String
    let revision: String
    let outcome: Outcome
    var duration: String? = nil
    var log: [LogLine] = []
    /// What happened to the combined suite at this revision.
    let suiteTitle: String
    let suiteDetail: String
    /// One sentence for the page heading.
    let summary: String

    var label: String {
        switch outcome {
        case .passed: "Ready"
        case .failed: "Tests failed"
        case .stale: "Stale base"
        case .conflict: "Conflict"
        }
    }

    var tone: Tone {
        switch outcome {
        case .passed: .working
        case .failed: .failure
        case .stale, .conflict: .attention
        }
    }
}

/// Every attempt to integrate the selected handoffs, newest first. Selecting one inspects it.
struct AttemptHistory: View {
    let attempts: [IntegrationAttempt]
    let selection: String
    let select: (IntegrationAttempt) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(attempts) { attempt in
                let isSelected = attempt.id == selection
                Button { select(attempt) } label: {
                    HStack(spacing: 11) {
                        Text(attempt.id).font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                        Text(attempt.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                            .lineLimit(1)
                        Text("\(attempt.time)  ·  \(attempt.revision)").font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                        Spacer(minLength: 8)
                        StatusLabel(text: attempt.label, tone: attempt.tone, size: 12)
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 41)
                    .background(isSelected ? Palette.selection.opacity(0.7) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attempt \(attempt.id): \(attempt.title), \(attempt.label)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                Hairline()
            }
        }
    }
}

struct TranscriptLine: Identifiable, Equatable {
    let id: Int
    var time: String? = nil
    var speaker: String? = nil
    let text: String
    var isHit = false
}

struct TranscriptMatch: Identifiable, Equatable {
    let id: String
    let worker: String
    let runID: String
    let runTitle: String
    let project: String
    let client: String
    let host: String
    let parent: String
    let workspace: String
    let position: String
    let time: String
    let excerpt: String
    let lines: [TranscriptLine]
    var gapTitle: String? = nil
    var gapDetail: String? = nil
    var resolution: String? = nil
}

/// The recorded transcript around one match, bound to its worker, timestamp and line.
struct TranscriptInspector: View {
    let match: TranscriptMatch
    let term: String
    let openWorker: () -> Void
    let openRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(symbol: "terminal", kicker: "Selected transcript", title: match.worker)
            Hairline().padding(.top, 18).padding(.bottom, 16)
            HStack(spacing: 8) {
                CapabilityChip(text: "\(match.runID) · \(match.runTitle)")
                CapabilityChip(text: match.client)
                CapabilityChip(text: match.host)
            }
            HStack(alignment: .top, spacing: 16) {
                FactColumn(label: "Parent worker", value: match.parent)
                FactColumn(label: "Workspace", value: match.workspace, monospaced: true)
                FactColumn(label: "Position", value: match.position, monospaced: true)
            }
            .padding(.top, 18).padding(.bottom, 16)
            transcript
            if let gapTitle = match.gapTitle {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Palette.attention).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(gapTitle).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.attention)
                        if let detail = match.gapDetail {
                            Text(detail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Palette.attentionFill)
                .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0xDFB476)).frame(width: 2) }
                .padding(.top, 9)
                .accessibilityElement(children: .combine)
            }
            if let resolution = match.resolution {
                Label(resolution, systemImage: "checkmark").font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                    .padding(.top, 14)
            }
            Hairline().padding(.top, 16).padding(.bottom, 15)
            HStack(spacing: 9) {
                Button(action: openWorker) { Label("Open worker", systemImage: "terminal") }
                    .buttonStyle(CapsuleButtonStyle())
                Button(action: openRun) { Label("Open run", systemImage: "arrow.right") }
                    .buttonStyle(CapsuleButtonStyle())
            }
        }
        .inspectorCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript of \(match.worker)")
    }

    private var transcript: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(match.lines) { line in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(line.id)").font(TypeRole.monoID).foregroundStyle(Color(hex: 0x6F7483))
                        .frame(width: 30, alignment: .trailing).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        if let time = line.time {
                            Text([time, line.speaker].compactMap { $0 }.joined(separator: "  "))
                                .font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                        }
                        HighlightedText(text: line.text, term: term, monospaced: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(line.isHit ? Color.white.opacity(0.06) : Color.clear)
                .overlay(alignment: .leading) {
                    if line.isHit { Rectangle().fill(Color(hex: 0x8E93A6)).frame(width: 2) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(line.isHit ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.well, in: shape)
        .overlay { shape.strokeBorder(.inkEdge) }
        .textSelection(.enabled)
    }
}

// MARK: - Delegate a worker

struct WorkingChange: Identifiable, Equatable {
    let id: String
    let kind: String

    var path: String { id }
}

struct DelegationSetup {
    let kicker: String
    let context: String
    let assignmentID: String
    let workerName: String
    let instructions: String
    let clients: [String]
    let models: [String]
    let hosts: [String]
    let sourceHost: String
    let sourceCheckout: String
    let baseRevision: String
    let workerBranch: String
    let changes: [WorkingChange]
    let included: Set<String>
    /// Worktree directory per destination host.
    let worktree: String
    let slotsNote: String
}

struct DelegateWorkerPage: View {
    private enum Workspace: String, CaseIterable, Identifiable {
        case commit, changes, sourceHost
        var id: String { rawValue }
    }

    let setup: DelegationSetup
    let delegate: (_ workerName: String) -> Void
    let cancel: () -> Void

    @State private var name: String
    @State private var instructions: String
    @State private var client: String
    @State private var model: String
    @State private var host: String
    @State private var workspace = Workspace.changes
    @State private var included: Set<String>

    init(setup: DelegationSetup, delegate: @escaping (_ workerName: String) -> Void, cancel: @escaping () -> Void) {
        self.setup = setup
        self.delegate = delegate
        self.cancel = cancel
        _name = State(initialValue: setup.workerName)
        _instructions = State(initialValue: setup.instructions)
        _client = State(initialValue: setup.clients.first ?? "")
        _model = State(initialValue: setup.models.first ?? "")
        _host = State(initialValue: setup.hosts.first ?? "")
        _included = State(initialValue: setup.included)
    }

    private var destination: String { workspace == .sourceHost ? setup.sourceHost : host }
    private var carried: [WorkingChange] { workspace == .changes ? setup.changes.filter { included.contains($0.id) } : [] }

    private var canDelegate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        TaskSheet {
            PageHeader(kicker: setup.kicker, title: "Delegate a worker", subtitle: setup.context) { EmptyView() }
        } form: {
            VStack(alignment: .leading, spacing: 18) {
                assignment
                Hairline()
                startingWorkspace
            }
        } aside: {
            preview
        } footer: {
            SheetFooter(symbol: "arrow.triangle.branch", note: setup.slotsNote) {
                Button("Cancel", action: cancel).buttonStyle(CapsuleButtonStyle()).keyboardShortcut(.cancelAction)
                Button { delegate(name) } label: { Label("Delegate worker", systemImage: "plus") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(!canDelegate)
                    .help(canDelegate ? "Delegate \(name)" : "Give the worker a name and instructions")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delegate a worker")
    }

    private var assignment: some View {
        FormSection(title: "Assignment") { EmptyView() } content: {
            HStack(alignment: .top, spacing: 16) {
                LabeledField(label: "Worker name") {
                    TextField("Name shown on the worker's tile", text: $name)
                        .textFieldStyle(.plain).font(TypeRole.body).fieldBox()
                        .accessibilityLabel("Worker name")
                }
                LabeledField(label: "Assignment ID") { StaticField(symbol: "lock", value: setup.assignmentID) }
            }
            LabeledField(label: "Instructions") { TextArea(label: "Instructions", text: $instructions) }
            HStack(alignment: .top, spacing: 16) {
                LabeledField(label: "Client") {
                    MenuField(name: "Client", symbol: "terminal", options: setup.clients, selection: $client)
                }
                LabeledField(label: "Model profile") {
                    MenuField(name: "Model profile", symbol: "slider.horizontal.3", options: setup.models, selection: $model)
                }
            }
            LabeledField(label: "Destination host") {
                MenuField(name: "Destination host", symbol: "server.rack", options: setup.hosts, selection: $host)
            }
        }
    }

    private var startingWorkspace: some View {
        FormSection(title: "Starting workspace") { EmptyView() } content: {
            VStack(spacing: 7) {
                ForEach(Workspace.allCases) { option in
                    Button { workspace = option } label: {
                        ChoiceRow(title: title(for: option), detail: detail(for: option), isSelected: workspace == option)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func title(for option: Workspace) -> String {
        switch option {
        case .commit: "Start from a commit"
        case .changes: "Include working changes"
        case .sourceHost: "Keep work on the source host"
        }
    }

    private func detail(for option: Workspace) -> String {
        switch option {
        case .commit: "Use the recorded revision without working changes."
        case .changes: "Apply the selected files to a new worker worktree."
        case .sourceHost: "Create a separate worktree on \(setup.sourceHost)."
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(symbol: "folder", kicker: "Workspace preview",
                       title: workspace == .commit ? "Recorded revision" : "Selected snapshot")
            Hairline().padding(.top, 20).padding(.bottom, 20)
            VStack(spacing: 15) {
                KeyValueRow(key: "Source host", value: setup.sourceHost)
                KeyValueRow(key: "Source checkout", value: setup.sourceCheckout, monospaced: true)
                KeyValueRow(key: "Base revision", value: setup.baseRevision, monospaced: true)
                KeyValueRow(key: "Send to", value: destination)
                KeyValueRow(key: "Worker branch", value: setup.workerBranch, monospaced: true)
            }
            Hairline().padding(.top, 22).padding(.bottom, 20)
            HStack {
                Kicker(text: "Included paths")
                Spacer(minLength: 8)
                MetaText(text: "\(carried.count) of \(setup.changes.count)")
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(setup.changes) { change in
                    HStack(spacing: 12) {
                        CheckToggle(label: "Include \(change.path)", isOn: inclusion(of: change))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.path).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Palette.foreground)
                            Text(change.kind).font(.system(size: 12)).foregroundStyle(.inkSecondary)
                        }
                    }
                }
            }
            .padding(.top, 15)
            .disabled(workspace != .changes)
            .opacity(workspace == .changes ? 1 : 0.5)
            Hairline().padding(.top, 22).padding(.bottom, 20)
            Kicker(text: "Destination worktree")
            Text(setup.worktree).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Palette.terminalText)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.inkHairline) }
                .padding(.top, 12)
            Text("Commander verifies the snapshot on \(destination) before starting the worker.")
                .font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 13)
        }
        .inspectorCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace preview")
    }

    private func inclusion(of change: WorkingChange) -> Binding<Bool> {
        Binding(get: { included.contains(change.id) },
                set: { isOn in
                    if isOn { included.insert(change.id) } else { included.remove(change.id) }
                })
    }
}

// MARK: - Integration review

struct Handoff: Identifiable, Equatable {
    let id: String
    let branch: String
    let revision: String
    let tests: String

    var worker: String { id }
}

struct IntegrationReview {
    let kicker: String
    let target: String
    let targetBranch: String
    let coordinatorHost: String
    let expectedHead: String
    let command: String
    let handoffs: [Handoff]
    /// Newest first.
    let attempts: [IntegrationAttempt]
    let remediationTargets: [String]
    let worktreeNote: String
    /// Files changed by the candidate against the target branch.
    let diffStat: [LogLine]
}

struct IntegrationPage: View {
    let review: IntegrationReview

    @State private var selection: String
    @State private var fixTarget: String
    @State private var fixRequestedFor: String?
    @State private var advancedTo: String?
    @State private var showsDiff = false

    init(review: IntegrationReview) {
        self.review = review
        _selection = State(initialValue: review.attempts.first?.id ?? "")
        _fixTarget = State(initialValue: review.remediationTargets.first ?? "")
    }

    private var attempt: IntegrationAttempt? {
        review.attempts.first { $0.id == selection } ?? review.attempts.first
    }

    var body: some View {
        TaskSheet {
            PageHeader(kicker: review.kicker, title: "Integration review", subtitle: attempt?.summary) { EmptyView() }
        } form: {
            VStack(alignment: .leading, spacing: 18) {
                handoffs
                Hairline()
                if let attempt { verification(attempt) }
                if showsDiff {
                    FormSection(title: "Candidate diff") {
                        MetaText(text: "against \(review.targetBranch)", monospaced: true)
                    } content: {
                        VerificationLog(lines: review.diffStat)
                    }
                }
                Hairline()
                FormSection(title: "Attempt history") { EmptyView() } content: {
                    AttemptHistory(attempts: review.attempts, selection: attempt?.id ?? "") { selection = $0.id }
                }
            }
        } aside: {
            target
        } footer: {
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Integration review")
    }

    private var handoffs: some View {
        FormSection(title: "Selected handoffs") {
            CapabilityChip(text: review.handoffs.count == 1 ? "1 worker" : "\(review.handoffs.count) workers")
        } content: {
            DataTable(headers: ["Worker / branch", "Revision", "Worker tests"], weights: [42, 24, 34],
                      rows: review.handoffs, carded: false, rowHeight: 57) { handoff, column in
                switch column {
                case 0:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(handoff.worker).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text(handoff.branch).font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                    }
                case 1:
                    Text(handoff.revision).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color(hex: 0xDCE0EA))
                default:
                    StatusLabel(text: handoff.tests, tone: .working, symbol: "checkmark.circle.fill", size: 12)
                }
            }
        }
    }

    private func verification(_ attempt: IntegrationAttempt) -> some View {
        FormSection(title: "Combined verification") {
            MetaText(text: "candidate \(attempt.revision)", monospaced: true)
        } content: {
            if attempt.log.isEmpty {
                Callout(symbol: "exclamationmark.triangle", title: attempt.suiteTitle, detail: attempt.suiteDetail,
                        tone: .attention)
            } else {
                HStack(spacing: 12) {
                    StatusLabel(text: attempt.outcome == .passed ? "Passed" : "Failed", tone: attempt.tone,
                                symbol: attempt.outcome == .passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                                size: 12)
                    Text(review.command).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color(hex: 0xDCE0EA))
                    Spacer(minLength: 8)
                    if let duration = attempt.duration { MetaText(text: duration, monospaced: true) }
                }
                VerificationLog(lines: attempt.log)
            }
        }
    }

    private var target: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(symbol: "arrow.triangle.merge", kicker: "Integration target", title: review.target)
            Hairline().padding(.top, 20).padding(.bottom, 20)
            VStack(spacing: 15) {
                KeyValueRow(key: "Coordinator host", value: review.coordinatorHost)
                KeyValueRow(key: "Target branch", value: review.targetBranch, monospaced: true)
                KeyValueRow(key: "Expected HEAD", value: advancedTo ?? review.expectedHead, monospaced: true)
                if let attempt { KeyValueRow(key: "Tested candidate", value: attempt.revision, monospaced: true) }
            }
            Hairline().padding(.top, 22).padding(.bottom, 20)
            Kicker(text: "Before advancing")
            VStack(alignment: .leading, spacing: 17) {
                EvidenceRow(title: "Target revision matches",
                            detail: "\(review.targetBranch) is still at \(review.expectedHead).",
                            passed: attempt?.outcome != .stale)
                EvidenceRow(title: "Checkout verified", detail: "The target working tree is clean.")
                if let attempt {
                    EvidenceRow(title: attempt.suiteTitle, detail: attempt.suiteDetail, passed: attempt.outcome == .passed)
                }
            }
            .padding(.top, 16)
            if let attempt { resolution(attempt).padding(.top, 22) }
        }
        .inspectorCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Integration target \(review.target)")
    }

    @ViewBuilder private func resolution(_ attempt: IntegrationAttempt) -> some View {
        if attempt.outcome == .passed {
            if let advancedTo {
                Callout(symbol: "checkmark", title: "\(review.targetBranch) advanced",
                        detail: "\(review.targetBranch) now points at \(advancedTo). Worker branches are retained until you remove them.")
            } else {
                Callout(symbol: "arrow.triangle.branch", title: "Ready to advance",
                        detail: "Commander verifies \(review.targetBranch) again when you advance to the tested revision.")
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Hairline().padding(.bottom, 8)
                Kicker(text: "Remediation")
                LabeledField(label: "Send failure details to") {
                    MenuField(name: "Send failure details to", symbol: "bubble.left",
                              options: review.remediationTargets, selection: $fixTarget)
                }
                if fixRequestedFor == attempt.id {
                    Callout(symbol: "paperplane", title: "Fix requested",
                            detail: "\(fixTarget) received the failure from attempt \(attempt.id). A new attempt starts when it hands off again.")
                } else {
                    Text("The worker receives the assertion, candidate revision, and failing test command.")
                        .font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let attempt, attempt.outcome == .passed {
            SheetFooter(symbol: "arrow.triangle.merge", note: review.worktreeNote) {
                Button { showsDiff.toggle() } label: {
                    Label(showsDiff ? "Hide diff" : "View diff", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(CapsuleButtonStyle())
                Button { advancedTo = attempt.revision } label: {
                    Label(advancedTo == nil ? "Advance \(review.targetBranch)" : "Advanced", systemImage: "arrow.right")
                }
                .buttonStyle(CapsuleButtonStyle(prominent: true))
                .disabled(advancedTo != nil)
            }
        } else {
            SheetFooter(symbol: "arrow.triangle.merge", note: "Test evidence and worker branches retained") {
                Button { fixRequestedFor = attempt?.id } label: { Label("Request fix", systemImage: "bubble.left") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(attempt == nil || fixRequestedFor == attempt?.id)
                UnavailableAction(title: "Advance \(review.targetBranch)",
                                  reason: "The selected attempt did not pass the combined suite.")
            }
        }
    }
}

// MARK: - Search history

struct HistoryPage: View {
    let kicker: String
    let subtitle: String
    let matches: [TranscriptMatch]
    let sharingNote: String
    let retention: String
    let openWorker: (TranscriptMatch) -> Void
    let openRun: (TranscriptMatch) -> Void

    @State private var query: String
    @State private var project: String
    @State private var run = "All runs"
    @State private var host = "All hosts"
    @State private var selection: String?

    init(kicker: String, subtitle: String, query: String, project: String, matches: [TranscriptMatch],
         sharingNote: String, retention: String,
         openWorker: @escaping (TranscriptMatch) -> Void, openRun: @escaping (TranscriptMatch) -> Void) {
        self.kicker = kicker
        self.subtitle = subtitle
        self.matches = matches
        self.sharingNote = sharingNote
        self.retention = retention
        self.openWorker = openWorker
        self.openRun = openRun
        _query = State(initialValue: query)
        _project = State(initialValue: project)
    }

    private func options(_ all: String, _ values: [String]) -> [String] {
        var seen = Set<String>()
        return [all] + values.filter { seen.insert($0).inserted }
    }

    private var term: String { query.trimmingCharacters(in: .whitespaces) }

    private var results: [TranscriptMatch] {
        guard !term.isEmpty else { return [] }
        return matches.filter { match in
            (project == "All projects" || match.project == project)
                && (run == "All runs" || match.runTitle == run)
                && (host == "All hosts" || match.host == host)
                && (match.excerpt.localizedCaseInsensitiveContains(term)
                    || match.lines.contains { $0.text.localizedCaseInsensitiveContains(term) })
        }
    }

    var body: some View {
        let found = results
        let selected = found.first { $0.id == selection } ?? found.first
        TaskSheet(formWidth: 440) {
            PageHeader(kicker: kicker, title: "Search history", subtitle: subtitle) { EmptyView() }
        } form: {
            VStack(alignment: .leading, spacing: 14) {
                SearchField(prompt: "Search recorded output", text: $query)
                HStack(spacing: 8) {
                    FilterChip(name: "Project", symbol: "folder", options: options("All projects", matches.map(\.project)),
                               selection: $project)
                    FilterChip(name: "Run", symbol: "square.stack.3d.up", options: options("All runs", matches.map(\.runTitle)),
                               selection: $run)
                    FilterChip(name: "Host", symbol: "server.rack", options: options("All hosts", matches.map(\.host)),
                               selection: $host)
                }
                Hairline().padding(.top, 6)
                HStack {
                    Kicker(text: "Transcript matches")
                    Spacer(minLength: 8)
                    MetaText(text: found.count == 1 ? "1 result" : "\(found.count) results")
                }
                if found.isEmpty {
                    Text(term.isEmpty ? "Type to search recorded terminal output." : "No recorded output matches “\(term)”.")
                        .font(.system(size: 13)).foregroundStyle(.inkSecondary).padding(.vertical, 10)
                }
                ForEach(found) { match in
                    matchRow(match, isSelected: match.id == selected?.id)
                }
            }
        } aside: {
            if let selected {
                TranscriptInspector(match: selected, term: term,
                                    openWorker: { openWorker(selected) }, openRun: { openRun(selected) })
            } else {
                ContentUnavailableView("No transcript selected", systemImage: "text.magnifyingglass",
                                       description: Text("Matches open here with their worker, time and line."))
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .panelSurface()
            }
        } footer: {
            HStack {
                Label(sharingNote, systemImage: "eye").font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                Spacer(minLength: 12)
                MetaText(text: retention, monospaced: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search history")
    }

    private func matchRow(_ match: TranscriptMatch, isSelected: Bool) -> some View {
        Button { selection = match.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(match.worker).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                    Spacer(minLength: 8)
                    Text(match.time).font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                }
                Text("\(match.runID) · \(match.runTitle)").font(TypeRole.meta).foregroundStyle(.inkSecondary)
                HighlightedText(text: match.excerpt, term: term).lineLimit(2).padding(.top, 3)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionCard(isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(match.worker) in \(match.runTitle) at \(match.time). \(match.excerpt)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Cross-run access

struct SharedEntry: Identifiable, Equatable {
    let id: Int
    let time: String
    let speaker: String
    let text: String
    var isFinding = false
}

struct CrossRunAccess {
    let kicker: String
    let context: String
    let workerName: String
    let workerDetail: String
    let branch: String
    let assignmentID: String
    let workerID: String
    let owner: String
    let ownerAddress: String
    let actingAs: String
    let deniedCommand: String
    let outcome: String
    let explanation: String
    let transcript: [SharedEntry]
    let question: String
    let historyNote: String
}

struct CrossRunPage: View {
    let access: CrossRunAccess
    let openTranscript: () -> Void

    @State private var question: String
    @State private var sent: String?

    init(access: CrossRunAccess, openTranscript: @escaping () -> Void) {
        self.access = access
        self.openTranscript = openTranscript
        _question = State(initialValue: access.question)
    }

    private var canAsk: Bool { !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        TaskSheet {
            PageHeader(kicker: access.kicker, title: "Cross-run access", subtitle: access.context) { EmptyView() }
        } form: {
            VStack(alignment: .leading, spacing: 18) {
                worker
                Hairline()
                transcript
                Hairline()
                ask
            }
        } aside: {
            decision
        } footer: {
            SheetFooter(symbol: "eye", note: access.historyNote) {
                Button(action: openTranscript) { Label("Open transcript", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(CapsuleButtonStyle())
                Button {
                    sent = question
                    question = ""
                } label: { Label("Ask owner", systemImage: "paperplane") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(!canAsk)
                    .help(canAsk ? "Send the question to \(access.owner)" : "Write a question first")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cross-run access")
    }

    private var worker: some View {
        FormSection(title: "Selected worker") { EmptyView() } content: {
            HStack(spacing: 14) {
                IconTile(symbol: "terminal", size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(access.workerName).font(TypeRole.focusTitle).tracking(-0.5).foregroundStyle(Palette.foreground)
                    Text("\(access.workerDetail) · \(access.branch)").font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                }
                Spacer(minLength: 12)
                StatusLabel(text: "Connected", tone: .working, symbol: "checkmark.circle.fill", size: 12)
            }
            VStack(spacing: 13) {
                KeyValueRow(key: "Assignment", value: access.assignmentID, monospaced: true)
                KeyValueRow(key: "Worker", value: access.workerID, monospaced: true)
                KeyValueRow(key: "Owning coordinator", value: access.owner)
            }
        }
    }

    private var transcript: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return FormSection(title: "Shared transcript") { CapabilityChip(text: "Read access") } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(access.transcript) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.time).foregroundStyle(Color(hex: 0x6F7483))
                        Text(entry.speaker).foregroundStyle(entry.isFinding ? Color(hex: 0xA5D7B6) : Palette.terminalDim)
                        Text(entry.text).foregroundStyle(Palette.terminalText)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 15).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.well, in: shape)
            .overlay { shape.strokeBorder(.inkEdge) }
            .textSelection(.enabled)
        }
    }

    private var ask: some View {
        FormSection(title: "Ask the owning coordinator") { EmptyView() } content: {
            LabeledField(label: "To") { StaticField(symbol: "bubble.left", value: access.ownerAddress) }
            LabeledField(label: "Question") { TextArea(label: "Question for \(access.owner)", text: $question, height: 76) }
            if let sent {
                Callout(symbol: "paperplane", title: "Question sent to \(access.owner)",
                        detail: "“\(sent)” The owner's reply will arrive in this run's inbox.")
            }
        }
    }

    private var decision: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(symbol: "checkmark.shield", kicker: "Access decision", title: "Worker commands restricted")
            Hairline().padding(.top, 20).padding(.bottom, 20)
            VStack(spacing: 15) {
                KeyValueRow(key: "Acting as", value: access.actingAs)
                KeyValueRow(key: "Requested command", value: access.deniedCommand, monospaced: true)
                KeyValueRow(key: "Worker owner", value: access.owner)
                KeyValueRow(key: "Outcome", value: access.outcome, monospaced: true)
            }
            Callout(symbol: "lock", title: "\(access.owner.components(separatedBy: " · ").first ?? access.owner) owns this worker",
                    detail: access.explanation, tone: .attention)
                .padding(.top, 22)
            Hairline().padding(.top, 22).padding(.bottom, 20)
            Kicker(text: "Worker controls")
            HStack(spacing: 9) {
                UnavailableAction(title: "Interrupt", symbol: "stop", reason: "Only the owning coordinator can interrupt this worker.")
                UnavailableAction(title: "Stop worker", reason: "Only the owning coordinator can stop this worker.")
            }
            .padding(.top, 13)
        }
        .inspectorCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Access decision")
    }
}
