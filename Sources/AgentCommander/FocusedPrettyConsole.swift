import SwiftUI

// ATOMIC LEVEL: Organism.
// The Pretty console for a worker bound to a provider (ACP) session, on every surface that shows
// one: the focused worker, a wall tile, the coordinator and the PiP. It reads only the structured
// transcript the workspace projection already holds for that worker: there is no new storage, no
// service call and no fallback to the worker's PTY output. CopilotKit has no SwiftUI SDK, so the
// CopilotKit reference console (poc/agui-console) guides the parts and native SwiftUI controls
// draw them: a run status line, the assistant's messages, tool calls as sentences (the live one
// inline, last in the transcript) and a request form.
//
//   Values     PrettyACPScope               whether a console uses this view
//              PrettyRunStatus              what the run is doing, from the worker state and transcript
//              PrettyACPMetrics             inset, type and status height for a density
//   Molecules  PrettyRunStatusBar           harness chip, lamp and word, counts as a sentence, session
//              PrettyEmptyConversation      no ACP events yet, said plainly
//              PrettyRequestForm            the pending request answered by ID, as a bordered block
//              PrettyFormButtonStyle        the form's and the message box's buttons
//   Organism   PrettyACPConsole             = PrettyRunStatusBar + PrettyConsoleView (with its
//                                             inline PrettyLiveLine) + PrettyRequestForm
//
// Densities: `.regular` for the focused worker and coordinator, `.compact` for a wall tile,
// `.pip` for the attention stack. Only a surface that owns a request's reply passes `reply`, so a
// request has one form: the focused worker or the PiP. A wall tile and the coordinator link to it.
// Activity lines take their actions from the same parent (`ActivityStoryContext`): Reply or
// Review approval focuses this surface's one form; Open request uses the tile's or coordinator's
// existing route. The PiP anchors its request's story from the whole transcript.
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
    /// How many of the failed calls the provider refused permission for: the tool never ran.
    let blockedTools: Int
    /// How many calls ran and reported an error.
    let ranAndFailedTools: Int
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
        var prompts = 0, tools = 0, failed = 0, blocked = 0, ranAndFailed = 0
        func count(_ result: ToolResult) {
            let status = ToolStatus(result: result)
            switch status {
            case .failed, .declined, .cancelled:
                if status == .failed { failed += 1 }
                if ActivityFailureWords.read(result, status: status).outcome == .blocked { blocked += 1 } else { ranAndFailed += 1 }
            default: break
            }
        }
        var openTool: String?
        var openToolIDs: [String] = []
        for entry in entries {
            switch entry.kind {
            case .prose(_, let fromUser):
                if fromUser { prompts += 1 }
                openTool = nil
            case .tool(let name, _, let result):
                tools += 1
                if let result { count(result) }
                openTool = result == nil ? name : nil
                if result == nil { openToolIDs.append(entry.id) }
            case .output(let result):
                count(result)
            case .other:
                break
            }
        }
        self.prompts = prompts
        self.tools = tools
        self.failedTools = failed
        self.blockedTools = blocked
        self.ranAndFailedTools = ranAndFailed
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

    /// The counts as the status line reads them: `3 prompts, 14 tool calls, 1 blocked`. A call the
    /// provider refused is counted as blocked, apart from one that ran and failed.
    var sentence: String {
        var parts = [prompts == 1 ? "1 prompt" : "\(prompts) prompts"]
        if tools > 0 { parts.append(tools == 1 ? "1 tool call" : "\(tools) tool calls") }
        if blockedTools > 0 { parts.append("\(blockedTools) blocked") }
        if ranAndFailedTools > 0 { parts.append("\(ranAndFailedTools) failed") }
        return parts.joined(separator: ", ")
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
            self.inset = inset ?? 21; barHeight = 34; barSize = 12.5; showsSession = true; showsCounts = true
        case .compact:
            self.inset = inset ?? 11; barHeight = 26; barSize = 11.5; showsSession = false; showsCounts = true
        case .pip:
            // The PiP's transcript is a recent window, so whole-run counts would mislead.
            self.inset = inset ?? 11; barHeight = 22; barSize = 10.5; showsSession = false; showsCounts = false
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
    /// The phase that service reports now. Only a reported thinking phase adds a Thinking line.
    var reportedPhase: ClaudeProgress.Phase? = nil
    /// The console is a coordinator's: its report is the run's result.
    var isCoordinator = false
    /// Where the call awaiting approval comes from. A surface holding the whole transcript
    /// derives it; the PiP, which holds a window, takes the one its request resolved.
    var awaitingApproval: AwaitingApproval = .derived
    /// The requests this surface can act on for activity story actions: its own form's request,
    /// or the requests it routes to where they are answered. Empty offers no request action.
    var stories = ActivityStoryContext()
    /// The PiP's request workflow linked over the whole transcript, so its Ask stays in the window.
    var anchor: CommanderWorkflow? = nil
    /// The jobs this console's calls started, for the background stack.
    var background: [BackgroundJob] = []

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
                              awaitingToolID: awaitingToolID(status), stories: stories, anchor: anchor,
                              live: PrettyLive(state: state, workerName: name, reportsProgress: reportsProgress,
                                               reportedPhase: reportedPhase),
                              reportsAsCoordinator: isCoordinator, background: background)
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
    /// A worker's console: the focused worker, a wall tile or the coordinator. With `reply`, its
    /// stories focus the worker's one request form; otherwise `stories` names what the parent
    /// routes (the wall tile's request, the coordinator's waiting requests), or nothing.
    init(worker: WorkerPresentation, session: NativeSession, reply: ReplyContext? = nil,
         density: PrettyDensity = .regular, inset: CGFloat? = nil, stories: ActivityStoryContext? = nil) {
        self.init(consoleID: worker.id, name: worker.name, client: worker.client, state: worker.state,
                  entries: worker.transcript, session: session,
                  request: reply == nil ? nil : worker.request, reply: reply, density: density, inset: inset,
                  choiceRequestPending: !(worker.request?.choices.isEmpty ?? true),
                  reportsProgress: worker.claudeProgress != nil,
                  reportedPhase: worker.claudeProgress?.evidence?.phase,
                  isCoordinator: worker.isCoordinator,
                  stories: stories ?? .form(for: worker.request, reply: reply),
                  background: worker.backgroundJobs)
    }

    /// The asking worker's console in the PiP: its recent window and the request it answers. The
    /// request's own story is anchored from the whole transcript, so the Ask is never cut off.
    init(request: RequestPresentation, session: NativeSession, reply: ReplyContext,
         inset: CGFloat? = nil, conversationHeight: CGFloat? = nil) {
        self.init(consoleID: request.workerID, name: request.workerName, client: request.client,
                  state: request.workerState, entries: request.contextEntries, session: session,
                  request: request, reply: reply, density: .pip, inset: inset,
                  conversationHeight: conversationHeight,
                  // The PiP holds a recent window, which cannot rule out an older open call, so
                  // it shows the call its request resolved from the whole transcript.
                  awaitingApproval: .resolved(request.awaitingApprovalToolID),
                  stories: .form(for: request, reply: reply),
                  anchor: request.requestWorkflow,
                  background: request.workerBackgroundJobs)
    }
}

// MARK: - Molecules

/// The run status line: one quiet line with a hairline beneath. Harness chip, lamp and word,
/// the counts as a sentence, and the short session ID at the trailing edge.
struct PrettyRunStatusBar: View {
    let status: PrettyRunStatus
    let session: NativeSession
    let client: AgentClient
    var metrics = PrettyACPMetrics(.regular)

    var body: some View {
        let harness = session.harnessInstance.isEmpty ? client.displayName : session.harnessInstance
        let sessionHelp = "Session \(session.sessionID) · \(harness)"
        HStack(spacing: metrics.showsSession ? 12 : 8) {
            Text(verbatim: client.displayName.lowercased())
                .font(Term.font(metrics.barSize - 1.5)).foregroundStyle(.inkSecondary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .help("Structured transcript from the provider session over ACP. " + sessionHelp)
                .accessibilityLabel("Harness \(client.displayName), over ACP")
            HStack(spacing: 6) {
                Circle().fill(status.ink).frame(width: 7, height: 7)
                Text(status.word).font(.system(size: metrics.barSize)).foregroundStyle(.inkSecondary)
                    .lineLimit(1).fixedSize()
            }
            .accessibilityElement(children: .combine)
            if metrics.showsCounts {
                Text(status.sentence)
                    .font(.system(size: metrics.barSize)).monospacedDigit().foregroundStyle(.inkSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if metrics.showsSession {
                Text(verbatim: String(session.sessionID.prefix(8)))
                    .font(Term.font(metrics.barSize - 1.5)).foregroundStyle(.inkSecondary)
                    .lineLimit(1).fixedSize()
                    .help(sessionHelp)
                    .accessibilityLabel("Session \(session.sessionID)")
            }
        }
        .padding(.horizontal, metrics.inset)
        .frame(height: metrics.barHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
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

/// The pending request as a bordered block: who asks and the short request ID, the question as
/// prose, the provider's choices as full-width buttons with the first one primary, or a reply
/// field. It answers exactly one request by ID with the same reply context as `RequestReply`: the
/// same draft, focus target and send action. Offline, held, closed and sending states keep the
/// form visible, disable input and say why in one line.
///
/// A choice's click sends that choice's exact ID through the request's own draft and reply
/// action, because the service accepts only an offered ID. The free-form field is shown only for
/// a request without choices. The choice list the service appends to the question text is left
/// out when it matches `choices`.
struct PrettyRequestForm: View {
    let request: RequestPresentation
    let context: ReplyContext
    /// `.regular` on the focused worker; `.pip` in the attention stack.
    var density: PrettyDensity = .regular

    private var isRegular: Bool { density == .regular }

    var body: some View {
        let metrics = PrettyMetrics(density)
        let draft = context.draft(request.id)
        let isSending = context.sending.contains(request.id)
        let unavailable = request.replyUnavailableStatement
        let held = request.replyHeldStatement
        let blocked = !context.isOnline || isSending || unavailable != nil
        let isEmpty = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isFocused = context.focus.wrappedValue == request.id && unavailable == nil
        let shape = RoundedRectangle(cornerRadius: metrics.blockRadius, style: .continuous)
        let approval = !request.choices.isEmpty

        VStack(alignment: .leading, spacing: isRegular ? 8 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: approval ? "\(request.workerName) needs your approval" : "\(request.workerName) asks")
                    .font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                IDChip(id: request.id, size: metrics.tagSize + 0.5)
                    .help("Request \(request.id)")
            }
            Text(request.promptWithoutChoiceList)
                .font(metrics.body).foregroundStyle(Palette.foreground)
                .lineSpacing(isRegular ? 3 : 1.5).lineLimit(isRegular ? 10 : 6).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = stateLine(isSending: isSending, unavailable: unavailable, held: held) {
                Text(verbatim: reason.text)
                    .font(.system(size: metrics.detailSize)).foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(reason.help).accessibilityValue(reason.help)
            }
            if approval {
                choices(blocked: blocked, isFocused: isFocused, unavailable: unavailable, metrics: metrics)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Reply to \(request.workerName)", text: draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(metrics.body)
                        .lineLimit(1...5)
                        .padding(.horizontal, 10).padding(.vertical, isRegular ? 7 : 5)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous)
                                .strokeBorder(isFocused ? Palette.focus : Palette.hairline, lineWidth: 1)
                        }
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
                            .buttonStyle(PrettyFormButtonStyle(isPrimary: true, metrics: metrics))
                            .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                            .disabled(blocked || isEmpty)
                            .help(unavailable ?? (context.isOnline ? "Send reply to \(request.workerName) (↩ or ⌘↩)"
                                                                   : "The local service is offline"))
                            .accessibilityLabel("Send reply to \(request.workerName)")
                    }
                }
            }
        }
        .padding(.horizontal, isRegular ? 16 : 10).padding(.vertical, isRegular ? 14 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.well, in: shape)
        .overlay { shape.strokeBorder(Palette.attention.opacity(isFocused ? 0.8 : 0.45), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request \(request.shortID) from \(request.workerName)")
    }

    /// Why input is disabled or held, in one line. Nil when the form can take input.
    private func stateLine(isSending: Bool, unavailable: String?, held: String?) -> (text: String, help: String)? {
        if let unavailable { return ("Reply unavailable until \(request.host) reconnects.", unavailable) }
        if !context.isOnline { return ("The local service is offline. Your draft is kept.", "The local service is offline") }
        if isSending { return ("Sending your reply.", "Sending your reply") }
        if let held { return ("Reply now. It is held until \(request.host) reconnects.", held) }
        return nil
    }

    /// One full-width button per choice, the first one primary. The group is the request's focus
    /// target; it never selects or sends a choice by itself.
    private func choices(blocked: Bool, isFocused: Bool, unavailable: String?, metrics: PrettyMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(request.choices.enumerated()), id: \.element.id) { index, choice in
                Button {
                    guard !blocked else { return }
                    context.draft(request.id).wrappedValue = RequestChoiceButtons.answer(for: choice)
                    context.send(request)
                } label: {
                    Text(verbatim: choice.label).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PrettyFormButtonStyle(isPrimary: index == 0, metrics: metrics, fillsWidth: true))
                .disabled(blocked)
                .help(unavailable ?? "Reply with \(choice.id)")
                .accessibilityLabel(choice.label)
                .accessibilityHint("Replies to request \(request.shortID) with \(choice.id)")
            }
        }
        .padding(3)
        .overlay {
            RoundedRectangle(cornerRadius: metrics.listRadius + 3)
                .strokeBorder(Palette.focus, lineWidth: 1.5)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .focusable()
        .focusEffectDisabled()
        .focused(context.focus, equals: request.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choices for request \(request.shortID)")
    }
}

/// A button of the request form and the message box: a 9 pt outline, the first one primary.
struct PrettyFormButtonStyle: ButtonStyle {
    var isPrimary = false
    let metrics: PrettyMetrics
    var fillsWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous)
        configuration.label
            .font(.system(size: metrics.bodySize, weight: fillsWidth ? .regular : .medium))
            .foregroundStyle(isPrimary && !fillsWidth ? Palette.onAccent : Palette.foreground)
            .padding(.horizontal, 12).padding(.vertical, metrics.density == .regular ? 6 : 4)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(isPrimary && !fillsWidth ? AnyShapeStyle(Palette.focus) : AnyShapeStyle(Color.clear), in: shape)
            .overlay { shape.strokeBorder(isPrimary ? Palette.focus : Palette.hairline, lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(shape)
    }
}
