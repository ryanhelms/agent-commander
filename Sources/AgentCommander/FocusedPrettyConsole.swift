import SwiftUI

// ATOMIC LEVEL: Organism.
// The Pretty console for a worker bound to a provider (ACP) session, on every surface that shows
// one: the focused worker, a wall tile, the coordinator and the PiP. It reads only the structured
// transcript the workspace projection already holds for that worker: there is no new storage, no
// service call and no fallback to the worker's PTY output. CopilotKit has no SwiftUI SDK, so the
// CopilotKit reference console (poc/agui-console) guides the parts and native SwiftUI controls
// draw them: a run status line, the assistant's messages, Thinking and tool calls as disclosures,
// a running indicator and a request form.
//
//   Values     PrettyACPScope               whether a console uses this view
//              PrettyRunStatus              what the run is doing, from the worker state and transcript
//              PrettyACPMetrics             inset, type and status height for a density
//   Molecules  PrettyRunStatusBar           ACP badge, session, phase, counts
//              PrettyRunningIndicator       the assistant is responding or a tool is running
//              PrettyEmptyConversation      no ACP events yet, said plainly
//              PrettyRequestForm            the pending request answered by ID (native RequestReply)
//   Organism   PrettyACPConsole             = PrettyRunStatusBar + PrettyConsoleView
//                                             + PrettyRunningIndicator + PrettyRequestForm
//
// Densities: `.regular` for the focused worker and coordinator, `.compact` for a wall tile,
// `.pip` for the attention stack. Only a surface that owns a request's reply passes `reply`, so a
// request has one form: the focused worker or the PiP. A wall tile and the coordinator link to it.
// A console without a session, and Terminal and Console modes, keep `ConsoleScrollback`.

enum PrettyACPScope {
    /// True for a console in Pretty mode whose worker the service has bound to a provider
    /// session. Every other console keeps `ConsoleScrollback`.
    static func applies(mode: ConsoleDisplayMode, session: NativeSession?) -> Bool {
        guard mode == .pretty, let session else { return false }
        return !session.sessionID.isEmpty
    }
}

// MARK: - Value

struct PrettyRunStatus: Equatable {
    enum Phase: Equatable {
        /// The worker is active and its last call has no result: the tool is running.
        case runningTool(String)
        /// The worker is active and no call is open: the assistant is responding.
        case responding
        /// A tracked local Claude worker that is active or in an explicit Unknown state, whose
        /// phase is reported in its progress row: the service's own state as recorded, with
        /// nothing inferred from the transcript.
        case active(TaskState)
        case waiting
        case idle
        case disconnected
        /// Finished, failed, stopped or stopping, as `TaskState` names it.
        case ended(TaskState)
    }

    let phase: Phase
    let prompts: Int
    let tools: Int
    let failedTools: Int
    /// Every tool call in the transcript that has no result yet, oldest first.
    let openToolIDs: [String]

    /// The call to show as awaiting approval, only when it is identified without doubt: the
    /// worker is waiting on a request that offers ACP choices, and exactly one call is open. The
    /// request does not name its call, so with several open calls, or a free-form question, every
    /// call keeps its own label.
    func awaitingToolID(choiceRequestPending: Bool) -> String? {
        guard phase == .waiting, choiceRequestPending, openToolIDs.count == 1 else { return nil }
        return openToolIDs.first
    }

    /// `reportsProgress` is set for a worker whose service reports its phase (a tracked local
    /// Claude worker). Its active phase is then the service's state alone: no Responding or
    /// Running tool is inferred from the transcript, so the status never contradicts the reported
    /// phase or claims work without evidence, and an explicit Unknown state is kept, not read as
    /// Idle. A waiting worker and its approvals are unchanged.
    init(state: TaskState, entries: [TranscriptEntry], reportsProgress: Bool = false) {
        var prompts = 0, tools = 0, failed = 0
        var openTool: String?
        var openToolIDs: [String] = []
        for entry in entries {
            switch entry.kind {
            case .prose(_, let fromUser):
                if fromUser { prompts += 1 }
                openTool = nil
            case .tool(let name, _, let result):
                tools += 1
                if let result, ToolStatus(result: result) == .failed { failed += 1 }
                openTool = result == nil ? name : nil
                if result == nil { openToolIDs.append(entry.id) }
            case .output(let result):
                if ToolStatus(result: result) == .failed { failed += 1 }
            case .other:
                break
            }
        }
        self.prompts = prompts
        self.tools = tools
        self.failedTools = failed
        self.openToolIDs = openToolIDs
        switch state {
        case .running, .working, .starting:
            phase = reportsProgress ? .active(state) : openTool.map(Phase.runningTool) ?? .responding
        case .needsInput: phase = .waiting
        // A tracked worker keeps an explicit Unknown as recorded rather than reading it as Idle.
        case .unknown: phase = reportsProgress ? .active(state) : .idle
        case .idle: phase = .idle
        case .disconnected: phase = .disconnected
        case .completed, .failed, .stopped, .stopping: phase = .ended(state)
        }
    }

    var isLive: Bool {
        switch phase {
        case .responding, .runningTool: true
        default: false
        }
    }

    var word: String {
        switch phase {
        case .runningTool: "Running tool"
        case .responding: "Responding"
        case .active(let state): state.label
        case .waiting: "Waiting for you"
        case .idle: "Idle"
        case .disconnected: "Disconnected"
        case .ended(let state): state.label
        }
    }

    var ink: Color {
        switch phase {
        case .runningTool, .responding: Palette.working
        case .active(let state): state.tone.color
        case .waiting, .disconnected: Palette.attention
        case .ended(.failed): Palette.failure
        case .ended(.completed): Palette.working
        default: Palette.secondary
        }
    }

    /// `3 prompts · 5 tools · 1 failed`, leaving out what is zero apart from prompts.
    var counts: String {
        var parts = [prompts == 1 ? "1 prompt" : "\(prompts) prompts"]
        if tools > 0 { parts.append(tools == 1 ? "1 tool" : "\(tools) tools") }
        if failedTools > 0 { parts.append("\(failedTools) failed") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Organism

struct PrettyACPMetrics {
    let inset: CGFloat
    let barHeight: CGFloat
    let barSize: CGFloat
    let showsSession: Bool
    let showsCounts: Bool

    init(_ density: PrettyDensity, inset: CGFloat? = nil) {
        switch density {
        case .regular:
            self.inset = inset ?? 21; barHeight = 28; barSize = 11.5; showsSession = true; showsCounts = true
        case .compact:
            self.inset = inset ?? 11; barHeight = 22; barSize = 10.5; showsSession = false; showsCounts = true
        case .pip:
            // The PiP's transcript is a recent window, so whole-run counts would mislead.
            self.inset = inset ?? 11; barHeight = 20; barSize = 10; showsSession = false; showsCounts = false
        }
    }
}

struct PrettyACPConsole: View {
    let consoleID: String
    let name: String
    let client: AgentClient
    let state: TaskState
    let entries: [TranscriptEntry]
    let session: NativeSession
    /// The request shown as a form. Pass it only with `reply`, on the surface that answers it.
    var request: RequestPresentation? = nil
    var reply: ReplyContext? = nil
    var density: PrettyDensity = .regular
    /// Overrides the density's horizontal inset, to line up with a surface's own padding.
    var inset: CGFloat? = nil
    /// A fixed height for the conversation, where the surface is bounded (the PiP). Nil fills.
    var conversationHeight: CGFloat? = nil
    /// The worker's pending request offers ACP choices. Set on every surface, with or without the
    /// form, so the open call reads the same everywhere.
    var choiceRequestPending = false
    /// The service reports this worker's phase, shown in its footer (a tracked local Claude
    /// worker). The status then infers no Responding or Running tool and draws no spinner.
    var reportsProgress = false
    /// Where the call awaiting approval comes from. A surface holding the whole transcript
    /// derives it; the PiP, which holds a window, takes the one its request resolved.
    var awaitingApproval: AwaitingApproval = .derived

    enum AwaitingApproval {
        /// From `entries` and `choiceRequestPending`, through `PrettyRunStatus.awaitingToolID`.
        case derived
        /// Already resolved from the worker's whole transcript. Nil marks no call.
        case resolved(String?)
    }

    var body: some View {
        let metrics = PrettyACPMetrics(density, inset: inset)
        let status = PrettyRunStatus(state: state, entries: entries, reportsProgress: reportsProgress)
        VStack(alignment: .leading, spacing: 0) {
            PrettyRunStatusBar(status: status, session: session, client: client, metrics: metrics)
            conversation(status: status, metrics: metrics)
                .frame(maxWidth: .infinity, maxHeight: conversationHeight == nil ? .infinity : nil)
                .frame(height: conversationHeight)
                .layoutPriority(1)
            if status.isLive {
                PrettyRunningIndicator(status: status, workerName: name, density: density, inset: metrics.inset)
            }
            if let request, let reply {
                PrettyRequestForm(request: request, context: reply, density: density)
                    .padding(.horizontal, metrics.inset).padding(.vertical, density == .regular ? 10 : 7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: conversationHeight == nil ? .infinity : nil, alignment: .topLeading)
        .background(Term.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pretty conversation with \(name)")
    }

    @ViewBuilder
    private func conversation(status: PrettyRunStatus, metrics: PrettyACPMetrics) -> some View {
        // Structured ACP entries only. `rawOutput` is empty on purpose: PTY text is never
        // shown here as if it were the conversation.
        if PrettyContent.isPresentable(entries: entries, rawOutput: "") {
            PrettyConsoleView(consoleID: consoleID, entries: entries, rawOutput: "",
                              density: density, horizontalInset: metrics.inset,
                              awaitingToolID: awaitingToolID(status))
        } else {
            PrettyEmptyConversation(status: status, workerName: name, hasEntries: !entries.isEmpty,
                                    density: density, inset: metrics.inset)
        }
    }

    private func awaitingToolID(_ status: PrettyRunStatus) -> String? {
        switch awaitingApproval {
        case .derived: status.awaitingToolID(choiceRequestPending: choiceRequestPending)
        case .resolved(let id): id
        }
    }
}

extension PrettyACPConsole {
    /// A worker's console: the focused worker, a wall tile or the coordinator.
    init(worker: WorkerPresentation, session: NativeSession, reply: ReplyContext? = nil,
         density: PrettyDensity = .regular, inset: CGFloat? = nil) {
        self.init(consoleID: worker.id, name: worker.name, client: worker.client, state: worker.state,
                  entries: worker.transcript, session: session,
                  request: reply == nil ? nil : worker.request, reply: reply, density: density, inset: inset,
                  choiceRequestPending: !(worker.request?.choices.isEmpty ?? true),
                  reportsProgress: worker.claudeProgress != nil)
    }

    /// The asking worker's console in the PiP: its recent window and the request it answers.
    init(request: RequestPresentation, session: NativeSession, reply: ReplyContext,
         inset: CGFloat? = nil, conversationHeight: CGFloat? = nil) {
        self.init(consoleID: request.workerID, name: request.workerName, client: request.client,
                  state: request.workerState, entries: request.contextEntries, session: session,
                  request: request, reply: reply, density: .pip, inset: inset,
                  conversationHeight: conversationHeight,
                  // The PiP holds a recent window, which cannot rule out an older open call, so
                  // it shows the call its request resolved from the whole transcript.
                  awaitingApproval: .resolved(request.awaitingApprovalToolID))
    }
}

// MARK: - Molecules

struct PrettyRunStatusBar: View {
    let status: PrettyRunStatus
    let session: NativeSession
    let client: AgentClient
    var metrics = PrettyACPMetrics(.regular)

    var body: some View {
        let sessionHelp = "Session \(session.sessionID) · "
            + (session.harnessInstance.isEmpty ? client.displayName : session.harnessInstance)
        HStack(spacing: metrics.showsSession ? 10 : 7) {
            Text("ACP")
                .font(.system(size: 9.5, weight: .bold)).kerning(0.6)
                .foregroundStyle(Palette.focus)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.focus.opacity(0.45)) }
                .help("Structured transcript from the provider session over ACP. " + sessionHelp)
            if metrics.showsSession {
                Text(verbatim: String(session.sessionID.prefix(8)))
                    .font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                    .help(sessionHelp)
                    .accessibilityLabel("Session \(session.sessionID)")
            }
            HStack(spacing: 5) {
                Circle().fill(status.ink).frame(width: 6, height: 6)
                Text(status.word).font(.system(size: metrics.barSize, weight: .medium)).foregroundStyle(status.ink)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            if metrics.showsCounts {
                Text(status.counts)
                    .font(.system(size: metrics.barSize - 0.5)).monospacedDigit().foregroundStyle(.inkSecondary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, metrics.inset)
        .frame(height: metrics.barHeight)
        .background(Palette.footer)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

struct PrettyRunningIndicator: View {
    let status: PrettyRunStatus
    let workerName: String
    var density: PrettyDensity = .regular
    var inset: CGFloat = 21

    var body: some View {
        let size: CGFloat = density == .regular ? 12 : 10.5
        HStack(spacing: density == .regular ? 8 : 6) {
            ProgressView().controlSize(.mini)
            if case .runningTool(let name) = status.phase {
                Text("Running \(Text(verbatim: name).font(Term.font(size - 0.5)).foregroundStyle(Palette.foreground))")
            } else {
                Text("\(workerName) is responding")
            }
        }
        .font(.system(size: size)).foregroundStyle(.inkSecondary)
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, inset).padding(.vertical, density == .regular ? 7 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct PrettyEmptyConversation: View {
    let status: PrettyRunStatus
    let workerName: String
    /// The session sent entries, and none of them has readable content.
    let hasEntries: Bool
    var density: PrettyDensity = .regular
    var inset: CGFloat = 21

    private var title: String { hasEntries ? "Nothing readable yet" : "No ACP events yet" }
    private var detail: String {
        hasEntries
            ? "\(workerName)'s session has sent only empty records. Inspect the source to see them."
            : "\(workerName)'s session has not sent a message or tool call. Status: \(status.word.lowercased())."
    }

    var body: some View {
        if density == .regular {
            ContentUnavailableView {
                Label(title, systemImage: "text.bubble")
            } description: {
                Text(detail)
            }
            .foregroundStyle(.inkSecondary)
        } else {
            // A tile or the PiP has room for one quiet line; the full statement is its help tag.
            Label(title, systemImage: "text.bubble")
                .font(.system(size: density == .pip ? 10.5 : 11.5))
                .foregroundStyle(.inkSecondary)
                .lineLimit(1)
                .padding(.horizontal, inset).padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .help(detail)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title). \(detail)")
        }
    }
}

/// The pending request as a native form. It answers exactly one request by ID with the same
/// reply context as `RequestReply`: the same draft, focus target, send action, and the same closed
/// and held states while the worker or its host is away.
///
/// A request with explicit choices shows one native button per choice. A click puts that choice's
/// exact ID in the request's draft and sends it through the same reply action, because the service
/// accepts only an offered ID. The free-form field is shown only for a request without choices.
/// The choice list the service appends to the question text is left out when it matches `choices`.
struct PrettyRequestForm: View {
    let request: RequestPresentation
    let context: ReplyContext
    /// `.regular` on the focused worker; `.pip` in the attention stack.
    var density: PrettyDensity = .regular

    private var isRegular: Bool { density == .regular }

    var body: some View {
        let draft = context.draft(request.id)
        let isSending = context.sending.contains(request.id)
        let unavailable = request.replyUnavailableStatement
        let held = request.replyHeldStatement
        let blocked = !context.isOnline || isSending || unavailable != nil
        let isEmpty = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isFocused = context.focus.wrappedValue == request.id && unavailable == nil

        VStack(alignment: .leading, spacing: isRegular ? 8 : 5) {
            HStack(spacing: 6) {
                Label("Input needed", systemImage: "questionmark.bubble.fill")
                    .font(.system(size: isRegular ? 11.5 : 10.5, weight: .semibold)).foregroundStyle(Palette.attention)
                Text(verbatim: request.shortID).font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                    .help("Request \(request.id)")
            }
            Text(request.promptWithoutChoiceList)
                .font(.system(size: isRegular ? 13.5 : 12, weight: .medium)).foregroundStyle(Palette.foreground)
                .lineSpacing(isRegular ? 3 : 1.5).lineLimit(isRegular ? 10 : 6).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let note = unavailable ?? held {
                Label(unavailable != nil ? "Reply unavailable until \(request.host) reconnects"
                                         : "Reply now · held until \(request.host) reconnects",
                      systemImage: unavailable != nil ? "exclamationmark.triangle" : "arrow.clockwise")
                    .font(.system(size: 11)).foregroundStyle(Palette.attention)
                    .help(note).accessibilityValue(note)
            }
            if !request.choices.isEmpty {
                choiceButtons(draft: draft, blocked: blocked, isSending: isSending, unavailable: unavailable)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Reply to \(request.workerName)", text: draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .focused(context.focus, equals: request.id)
                        .disabled(blocked)
                        .onSubmit { if !blocked && !isEmpty { context.send(request) } }
                        .accessibilityLabel("Reply to request \(request.shortID) from \(request.workerName)")
                        .accessibilityHint(unavailable ?? held ?? "")
                    if isSending {
                        ProgressView().controlSize(.small).frame(width: 52)
                            .accessibilityLabel("Sending reply")
                    } else {
                        Button("Reply") { context.send(request) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                            .disabled(blocked || isEmpty)
                            .help(unavailable ?? (context.isOnline ? "Send reply to \(request.workerName) (↩ or ⌘↩)"
                                                                   : "The local service is offline"))
                            .accessibilityLabel("Send reply to \(request.workerName)")
                    }
                }
            }
        }
        .controlSize(isRegular ? .regular : .small)
        .padding(isRegular ? 12 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.attentionFill, in: RoundedRectangle(cornerRadius: isRegular ? 10 : 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isRegular ? 10 : 8, style: .continuous)
                .strokeBorder(isFocused ? Palette.attention : Palette.attentionSoftEdge, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request \(request.shortID) from \(request.workerName)")
    }

    /// One row when the choices fit the form's width; otherwise one per line.
    private func choiceButtons(draft: Binding<String>, blocked: Bool, isSending: Bool,
                               unavailable: String?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { choices(draft: draft, blocked: blocked, isSending: isSending, unavailable: unavailable) }
            VStack(alignment: .leading, spacing: 6) {
                choices(draft: draft, blocked: blocked, isSending: isSending, unavailable: unavailable)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choices for request \(request.shortID)")
    }

    @ViewBuilder
    private func choices(draft: Binding<String>, blocked: Bool, isSending: Bool, unavailable: String?) -> some View {
        ForEach(request.choices) { choice in
            Button {
                // The exact ID, through the request's own draft and reply action.
                draft.wrappedValue = choice.id
                context.send(request)
            } label: {
                Text(verbatim: choice.label).lineLimit(2)
            }
            .buttonStyle(.bordered)
            .disabled(blocked)
            .help(unavailable ?? "Reply with \(choice.id)")
            .accessibilityLabel(choice.label)
            .accessibilityHint("Replies to request \(request.shortID) with \(choice.id)")
        }
        if isSending {
            ProgressView().controlSize(.small).accessibilityLabel("Sending reply")
        }
    }
}
