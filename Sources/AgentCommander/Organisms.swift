import AppKit
import SwiftUI

// ATOMIC LEVEL: Organisms.
// Distinct regions of the cockpit, each composed from molecules, atoms and the shared TerminalWell.
// Organisms receive presentation values and emit targeted actions. They hold no API access.
//
//   WorkerTile          = ConsoleTitleBar + TerminalWell + TerminalStatusLine + InputOwnership
//                         (+ RequestPrompt in the focused variant)
//                         (+ ProviderAvailabilityNotice row while a bound Claude adapter has exited or
//                            is being checked after a restart)
//                         (+ ClaudeProgressStatus row above the status line of a tracked local Claude worker)
//                         (+ InterruptReceiptStatus row above the status line: always in the
//                            focused variant, on the wall while the outcome is unresolved or unknown)
//                         (+ FollowUpReceiptStatus row directly above the status line in the focused
//                            variant of a managed local Claude worker with follow-up receipts)
//                         (+ ProviderSessionPanel popover from the action list for a bound worker:
//                            status, capabilities, discovery and explicit reattach; the
//                            CoordinatorConsole opens the same panel from its display menu)
//                         (+ FollowUpContextMenu and FollowUpContextChip in the focused follow-up's
//                            TerminalComposer when the session accepts file links or snapshots)
//                         (+ ElicitationPanel popover from the action list for a bound worker: the
//                            agent's form and URL requests with accept, decline and cancel)
//                         (identityOnly: the title bar and the status line alone, for the parent
//                            pinned over an opened group in a short pane)
//   NestedWorkerGroup   = disclosure header (+ Open group) + WorkerTile row
//   WorkerWall          = WorkerTile rows + NestedWorkerGroup
//   CoordinatorConsole  = ConsoleTitleBar (CoordinatorAssignmentButton) + TerminalWell + AttentionNotice + TerminalStatusLine
//                         (+ TerminalComposer as the footer line: the owner's follow-up to a
//                            recovered coordinator the owner controls, else the preview's message)
//   AttentionStack      = request controls + ConsoleTitleBar + TerminalWell + RequestPrompt
//                         + TerminalStatusLine (the PiP)
//
// In Pretty on an ACP-bound worker, PrettyACPConsole replaces the scrollback on each of these:
// regular with the request form on the focused WorkerTile; compact with no form on a wall tile;
// regular with no form on CoordinatorConsole, whose AttentionNotices still open each request;
// pip with the request form in AttentionStack, in place of the scrollback and RequestPrompt.
//   RunHeader           = Breadcrumb + StatusLabel + run actions
//   NavigationRail      = BrandMark + NavigationRow

// MARK: - WorkerTile

struct WorkerTileActions {
    var toggleZoom: (() -> Void)? = nil
    var openRequest: (() -> Void)? = nil
    /// Opens this worker's next pending request after the one its console marks, by request ID,
    /// in Attention. Present only while the worker has more than one pending request.
    var openFurtherRequest: (() -> Void)? = nil
    /// Opens the pending request a queued follow-up waits for, by that request's exact ID, through
    /// the same routing as `openRequest`. Present only while a queued follow-up waits on one.
    var openFollowUpBlocker: (() -> Void)? = nil
    var copyID: () -> Void = {}
    var handBack: (() -> Void)? = nil
    /// Sends a follow-up message to this worker and reports whether it was accepted. Present
    /// only where the service supports it.
    var sendInput: ((String) async -> Bool)? = nil
    /// File context for the focused follow-up. Present only where the session accepts a file
    /// link or snapshot and a follow-up can be sent.
    var followUpContext: FollowUpContextAccess? = nil
    /// Takes back a queued follow-up by its message ID. Present only where the service offers it.
    var removeQueued: ((String) -> Void)? = nil
    /// A control, interrupt or stop request for this worker is in flight. Its controls wait.
    var isBusy = false
    // Worker operations from the action list. Each row appears only when its action exists.
    var viewAssignment: (() -> Void)? = nil
    var followUp: (() -> Void)? = nil
    var takeControl: (() -> Void)? = nil
    var interrupt: (() -> Void)? = nil
    var stop: (() -> Void)? = nil
    /// Opens the network tray's share sheet for this worker. Present where the network is available.
    var share: (() -> Void)? = nil
}

/// One worker. The wall and the focused (zoomed) view are variants of this single type, so identity,
/// status, terminal output, actions and input ownership cannot drift apart between surfaces.
struct WorkerTile: View {
    enum Variant { case wall, focused }

    let worker: WorkerPresentation
    var variant: Variant = .wall
    /// The wall variant without its console: the title bar and the status line alone. An opened
    /// group pins its parent this way where the pane is too short for the parent's tile.
    var identityOnly = false
    var isKeyFocused = false
    /// Present in the focused variant when this worker's request is answered inline.
    var reply: ReplyContext? = nil
    var actions = WorkerTileActions()
    /// When present, the tile's actions open as an anchored list (WorkerActionMenu) whose
    /// presentation the page controls. Without it the tile uses the native menu.
    var menuPresented: Binding<Bool>? = nil
    /// This worker's provider source, when it has one. Both variants offer the same inspector
    /// from the title bar's display menu and from the action list.
    var source: ConsoleSourceAccess? = nil
    /// This worker's provider session: status, discovery and reattach. Both variants offer the
    /// same panel from the action list. Nil for a worker without a bound session.
    var providerSession: ProviderSessionAccess? = nil
    /// This worker's structured requests from its agent. Both variants offer the same panel from
    /// the action list. Nil for a worker without a bound session.
    var elicitations: ElicitationAccess? = nil

    /// Laid-out height of the focused transcript, reported by the terminal well.
    @State private var transcriptHeight: CGFloat = 160
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    /// The standalone read-only terminal window, the same route as the display menu's item.
    @Environment(\.openWindow) private var openWindow

    /// The provider session when this console shows `PrettyACPConsole`: Pretty mode on an
    /// ACP-bound worker, in either variant. Nil otherwise.
    private var prettySession: NativeSession? {
        guard PrettyACPScope.applies(mode: modes?.mode(for: worker.id) ?? .console, session: worker.session)
        else { return nil }
        return worker.session
    }

    private var isPending: Bool { worker.request != nil }
    private var isFocusedVariant: Bool { variant == .focused }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isFocusedVariant { conversation } else if !identityOnly { well }
            // While the service checks the session, the availability strip shows its explanation
            // as the restart reason, so it is not repeated here.
            if !identityOnly, let error = worker.error, !error.isEmpty,
               worker.availabilityStatement?.suppressesConsoleNotice != true {
                ConsoleNotice(text: error, state: worker.state)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, isFocusedVariant ? 21 : Metric.tileInset).padding(.vertical, 6)
                    .background(Term.background)
            }
            if !identityOnly {
                availabilityRow
                progressRow
                interruptRow
                followUpRow
            }
            footer
            // A follow-up cannot reach a disconnected worker, or a Claude adapter that has exited or
            // is being checked, so its compose line waits with it.
            if isFocusedVariant, worker.control == .held, !worker.isDisconnected,
               ProviderAvailability.allowsControl(worker.providerAvailability), let sendInput = actions.sendInput {
                if (modes?.mode(for: worker.id) ?? .console) == .pretty {
                    // Pretty's message box: it queues while a turn runs, and Stop interrupts the turn.
                    PrettyComposer(workerName: worker.name, isWorking: worker.isInTurn,
                                   queued: worker.queuedMessages, send: sendInput, context: actions.followUpContext,
                                   removeQueued: actions.removeQueued, stop: actions.interrupt)
                } else {
                    TerminalComposer(workerName: worker.name, send: sendInput, context: actions.followUpContext)
                }
            }
        }
        .harnessConsoleSurface(worker.client, attention: isPending)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
    }

    /// One console title bar for both variants. The focused worker adds its lineage before the
    /// title and its short ID beside the actions; the wall's group header already shows nesting.
    private var header: some View {
        ConsoleTitleBar(title: worker.name, client: worker.client, host: worker.host, platform: worker.platform,
                        location: worker.location, locationIsBranch: worker.locationIsBranch,
                        lineage: isFocusedVariant ? Array(worker.lineage.dropLast()) : [],
                        density: isFocusedVariant ? .focused : .tile) {
            if isFocusedVariant {
                Text("#\(worker.shortID)").font(Term.font(11)).foregroundStyle(Term.text)
                    .lineLimit(1).fixedSize()
                    .help("Worker \(worker.id)").accessibilityLabel("Worker ID \(worker.id)")
            }
            // The display modes belong to a console, and the strip draws none.
            if !identityOnly {
                ConsoleModeTitlebarControl(consoleID: worker.id, consoleName: worker.name, client: worker.client,
                                           source: source, terminal: NativeTerminalTarget(worker: worker))
            }
            actionMenu
                // The action list's own popover is on the button; the session panel is anchored
                // beside it, so the two never share a presenter.
                .background { Color.clear.modifier(ProviderSessionPresentation(access: providerSession)) }
                // The input-request panel has its own anchor beside the same button.
                .background { Color.clear.modifier(ElicitationPresentation(access: elicitations)) }
        }
    }

    /// Wall density: the terminal tail fills the tile. In Pretty on an ACP-bound worker, the
    /// compact structured console; its request is answered in the PiP or the focused worker.
    @ViewBuilder private var well: some View {
        if let session = prettySession {
            // The tile's own Reply to request action routes the worker's request by exact ID.
            PrettyACPConsole(worker: worker, session: session, density: .compact,
                             stories: actions.openRequest.map { open in
                                 ActivityStoryContext.opens(worker.request.map { [$0] } ?? []) { _ in open() }
                             })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            terminalWell
        }
    }

    private var terminalWell: some View {
        ZStack(alignment: .topLeading) {
            Term.background
            ConsoleScrollback(worker: worker, density: .compact,
                              terminal: NativeTerminalTarget(worker: worker),
                              live: PrettyLive(state: worker.state, workerName: worker.name, reportsProgress: worker.claudeProgress != nil,
                                               reportedPhase: worker.claudeProgress?.evidence?.phase,
                                               turnIsRunning: worker.turnIsRunning)) {
                if !worker.transcript.isEmpty {
                    TranscriptView(entries: worker.transcript, agentName: worker.name,
                                   fontSize: TypeRole.wallTerminalSize, inset: 11,
                                   consoleID: worker.id, density: .compact)
                } else {
                    TerminalWell(output: worker.output, workerID: worker.id, workerName: worker.name,
                                 fontSize: TypeRole.wallTerminalSize, inset: NSSize(width: 11, height: 9))
                }
            }
            if worker.transcript.isEmpty && worker.output.isEmpty {
                NativeTerminalTranscriptOnly(consoleID: worker.id, target: NativeTerminalTarget(worker: worker)) {
                    Text(worker.task)
                        .font(Term.font(TypeRole.wallTerminalSize))
                        .foregroundStyle(.inkTermDim)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                        .allowsHitTesting(false)
                        .accessibilityLabel("No output yet. Task: \(worker.task)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Focused worker: assignment, then the transcript, then the pending request directly after it.
    /// A short transcript takes only its own height, so the request sits partway down as in the
    /// concept. A long transcript scrolls inside the well and the request stays visible below it.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One full-width scrollback: the assignment, the transcript, then the request as an
            // inline prompt directly after it.
            if !worker.task.isEmpty {
                ConsoleAssignment(consoleID: worker.id, assignment: worker.task, entries: worker.transcript,
                                  rawOutput: worker.output) {
                    AssignmentBlock(label: assignmentLabel, time: worker.startedAt, text: worker.task, fontSize: 13)
                        .padding(.horizontal, 21).padding(.top, 12).padding(.bottom, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let session = prettySession {
                // Pretty on an ACP-bound worker: the structured transcript only, with the request
                // as a native form inside it.
                PrettyACPConsole(worker: worker, session: session, reply: reply)
            } else {
                ConsoleScrollback(worker: worker, density: .regular, horizontalInset: 21,
                                  terminal: NativeTerminalTarget(worker: worker),
                                  live: PrettyLive(state: worker.state, workerName: worker.name, reportsProgress: worker.claudeProgress != nil,
                                               reportedPhase: worker.claudeProgress?.evidence?.phase,
                                               turnIsRunning: worker.turnIsRunning)) {
                    if !worker.transcript.isEmpty {
                        // Structured messages: the transcript takes the room above the request.
                        TranscriptView(entries: worker.transcript, agentName: worker.name,
                                       fontSize: TypeRole.focusTerminalSize, inset: 21,
                                       consoleID: worker.id, density: .regular)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    } else if worker.output.isEmpty {
                        Text("… waiting for this worker's first output")
                            .font(Term.font(13)).foregroundStyle(.inkTermDim)
                            .padding(.horizontal, 21).padding(.vertical, 8)
                    } else {
                        TerminalWell(output: worker.output, workerID: worker.id, style: .transcript, workerName: worker.name,
                                     fontSize: TypeRole.focusTerminalSize, inset: NSSize(width: 21, height: 4),
                                     onContentHeight: { transcriptHeight = $0 })
                            .frame(maxWidth: .infinity, maxHeight: transcriptHeight)
                            .layoutPriority(1)
                    }
                }
                if let request = worker.request, let reply {
                    RequestPrompt(request: request, reply: reply, density: .focused, inset: 21)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Takes only the room left over. It never sets the transcript's or the request's size.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Term.background)
    }

    private var assignmentLabel: String {
        let parent = worker.lineage.dropLast().last
        return parent.map { "Assignment · \($0)" } ?? "Assignment"
    }

    /// A tracked local Claude worker's last reported phase, its time and advancing age, in every
    /// display mode, in its own row above the status line so the footer keeps its actions and
    /// telemetry. While progress is unknown it offers this worker's read-only source inspector.
    /// Absent, with no strip, while the molecule draws nothing (a known worker with no report).
    /// Whether the bound Claude adapter exited or is being checked after a service restart, in its
    /// own row above the progress row, in every display mode. Offers the existing passive routes:
    /// the read-only terminal window while checking, and the read-only source inspector. The task
    /// status line below keeps the worker's own state. Absent for a normal worker.
    @ViewBuilder private var availabilityRow: some View {
        if let statement = worker.availabilityStatement {
            let target = NativeTerminalTarget(worker: worker)
            ProviderAvailabilityNotice(statement: statement, size: isFocusedVariant ? 11 : 10,
                                       watchTerminal: { openWindow(id: NativeTerminalScene.id, value: target) },
                                       inspectSource: source?.open)
                .padding(.horizontal, isFocusedVariant ? 21 : Metric.tileInset).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Term.bar)
                .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
        }
    }

    @ViewBuilder private var progressRow: some View {
        if let track = worker.claudeProgress,
           ClaudeProgressDisplay(track: track, state: worker.state, now: Date()).isVisible {
            // The availability strip above, or the interrupt row below, already offers the source,
            // so it is offered once.
            ClaudeProgressStatus(track: track, state: worker.state, workerName: worker.name,
                                 size: isFocusedVariant ? 11 : 10,
                                 inspectSource: worker.providerAvailability == nil && !interruptOffersSource
                                     ? source?.open : nil)
                .padding(.horizontal, isFocusedVariant ? 21 : Metric.tileInset).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Term.bar)
                .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
        }
    }

    /// The receipt shown on this surface: always in the focused worker, and on the wall only while
    /// its outcome is unresolved or unknown. Nil from an older service.
    private var shownInterruptReceipt: InterruptReceiptStatement? {
        worker.interruptReceipt.flatMap { $0.isShown(focused: isFocusedVariant) ? $0 : nil }
    }

    /// The interrupt row offers the read-only source while its outcome is unresolved or unknown,
    /// unless the availability strip already does.
    private var interruptOffersSource: Bool {
        InterruptReceiptStatement.rowOffersSource(worker.interruptReceipt, focused: isFocusedVariant,
                                                  hasSource: source != nil,
                                                  availability: worker.providerAvailability)
    }

    /// What happened to the developer's interrupt of this worker's turn, in its own row directly
    /// above the status line, in every display mode. It replaces the generic `interrupt requested`
    /// cue. Passive: it offers only the read-only source inspector; stopping stays in the actions.
    @ViewBuilder private var interruptRow: some View {
        if let statement = shownInterruptReceipt {
            InterruptReceiptStatus(statement: statement, size: isFocusedVariant ? 11 : 10,
                                   inspectSource: interruptOffersSource ? source?.open : nil)
                .padding(.horizontal, isFocusedVariant ? 21 : Metric.tileInset).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Term.bar)
                .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
        }
    }

    /// The focused worker's follow-up receipts, in their own row directly above the status line:
    /// the receipt still awaiting an outcome first, with what it waits for, then the retained latest
    /// outcome. Passive apart from opening the blocking request by its ID.
    @ViewBuilder private var followUpRow: some View {
        if isFocusedVariant, let receipts = worker.followUpReceipts, receipts.isShown {
            FollowUpReceiptStatus(receipts: receipts, size: 11, openBlocker: actions.openFollowUpBlocker)
                .padding(.horizontal, 21).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Term.bar)
                .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
        }
    }

    /// One slim status line for both variants: live status, then `[ view request ]` on a wall tile
    /// whose request is answered elsewhere, then input ownership. In the focused variant the
    /// request is the inline prompt above, so the line shows the send key instead.
    private var footer: some View {
        let size: CGFloat = isFocusedVariant ? 12 : 11
        return TerminalStatusLine(state: worker.state, size: size,
                                  inset: isFocusedVariant ? 21 : Metric.tileInset,
                                  request: worker.request,
                                  openRequest: isFocusedVariant ? nil : actions.openRequest,
                                  reconnectingHost: worker.hostIsReconnecting ? worker.host : nil,
                                  statusLabel: worker.statusLabel) {
            if isFocusedVariant, let request = worker.request, !request.isWorkerDisconnected, reply != nil,
               request.choices.isEmpty {
                TermHint(keys: "↩", action: "send", size: size - 1)
            }
            // Further pending requests from this worker, answered in Attention by their own IDs.
            let further = worker.allRequests.count - 1
            if further > 0, let openFurtherRequest = actions.openFurtherRequest {
                Button(further == 1 ? "+1 request" : "+\(further) requests", action: openFurtherRequest)
                    .buttonStyle(TermButtonStyle(ink: Term.amber, size: size - 1))
                    .fixedSize()
                    .help("\(worker.name) has \(further + 1) pending requests. Show the next one in Attention.")
                    .accessibilityLabel("Show the next of \(further + 1) pending requests from \(worker.name)")
            }
            // An answer the service accepted and could not confirm as delivered.
            if isFocusedVariant, let unconfirmed = worker.unconfirmedReply {
                Text("reply \(unconfirmed) delivery unknown").font(Term.font(size - 1)).foregroundStyle(Term.amber)
                    .lineLimit(1).fixedSize()
                    .help("Your reply to request \(unconfirmed) was accepted. Whether \(worker.name) received it is unknown.")
                    .accessibilityLabel("Reply to request \(unconfirmed): delivery unknown")
            }
            // What the service reports about the developer's own requests to this worker. A
            // receipt's row above says more, so the generic cue is only for an older service.
            if isFocusedVariant, worker.interruptRequested, worker.interruptReceipt == nil {
                Text("interrupt requested").font(Term.font(size - 1)).foregroundStyle(Term.amber)
                    .lineLimit(1).fixedSize()
                    .accessibilityLabel("Interrupt requested for \(worker.name)")
            }
            // The follow-up row above says more for a managed local Claude worker.
            if isFocusedVariant, worker.followUpReceipts == nil, worker.queuedFollowUps > 0 {
                Text(worker.queuedFollowUps == 1 ? "1 follow-up queued" : "\(worker.queuedFollowUps) follow-ups queued")
                    .font(Term.font(size - 1)).foregroundStyle(Term.cyan)
                    .lineLimit(1).fixedSize()
            }
            if let telemetry = worker.telemetry {
                ProviderUsageStatus(telemetry: telemetry, size: size - 1)
            }
            // A normal worker keeps the ownership cue. While exited or checking there is no usable
            // input path: a held lease while checking reads as reserved; otherwise no owner is named.
            if let availability = worker.availabilityStatement {
                if availability.showsReservedInput(control: worker.control) {
                    ReservedInputCue(workerName: worker.name, isKeyFocused: isKeyFocused, size: size - 0.5)
                } else if isKeyFocused {
                    KeyFocusCue(size: size - 0.5)
                }
            } else {
                InputOwnership(workerName: worker.name, control: worker.control,
                               isKeyFocused: isKeyFocused, handBack: actions.handBack,
                               takeControl: isFocusedVariant ? actions.takeControl : nil,
                               isBusy: actions.isBusy, size: size - 0.5,
                               handBackNote: isFocusedVariant ? worker.followUpReceipts?.handBackNote : nil,
                               handBackStatement: isFocusedVariant ? worker.followUpReceipts?.handBackStatement : nil)
            }
        }
    }

    @ViewBuilder private var actionMenu: some View {
        if let menuPresented {
            Button { menuPresented.wrappedValue.toggle() } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.consoleHeaderControlInk(active: menuPresented.wrappedValue ? Palette.focus : nil))
                    .frame(width: 23, height: 23).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.consoleHeaderControlInk(active: menuPresented.wrappedValue ? Palette.focus : nil))
            .popover(isPresented: menuPresented, arrowEdge: .bottom) {
                WorkerActionMenu(worker: worker, isFocused: isFocusedVariant, actions: actions,
                                 inspectSource: source?.open,
                                 openProviderSession: providerSession?.open,
                                 openElicitations: elicitations?.open,
                                 dismiss: { menuPresented.wrappedValue = false })
            }
            .help("Actions for \(worker.name)")
            .accessibilityLabel("Actions for \(worker.name)")
        } else {
            nativeActionMenu
        }
    }

    private var nativeActionMenu: some View {
        Menu {
            if let toggleZoom = actions.toggleZoom {
                Button(isFocusedVariant ? "Return to wall" : "Zoom worker", action: toggleZoom)
            }
            if let openRequest = actions.openRequest {
                Button(worker.isDisconnected ? "View request" : "Reply to request", action: openRequest)
            }
            if let source { Button("Inspect source…", action: source.open) }
            if let elicitations { Button("Input requests…", action: elicitations.open) }
            if let providerSession { Button("Provider session…", action: providerSession.open) }
            if let share = actions.share { Button("Share…", action: share) }
            Divider()
            Button("Copy worker ID", action: actions.copyID)
        } label: {
            // Coloured inside the label and drawn as a plain button: the borderless menu style on
            // macOS paints the glyph in its own dim control tint and ignores the style set outside.
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.consoleHeaderControlInk())
                .frame(width: 23, height: 23).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.consoleHeaderControlInk())
        .help("Actions for \(worker.name)")
        .accessibilityLabel("Actions for \(worker.name)")
    }

    private var summary: String {
        var parts = [worker.name, worker.client.displayName, "host \(worker.host), \(worker.platform.label)",
                     worker.statusLabel]
        if worker.hostIsReconnecting { parts.append("host reconnecting") }
        if let availability = worker.availabilityStatement { parts.append(availability.summary) }
        // The phase only: the advancing age and freshness are read from the footer cue itself.
        if let evidence = worker.claudeProgress?.evidence {
            parts.append("Claude last reported \(evidence.phase.label.lowercased())")
        }
        if let availability = worker.availabilityStatement {
            // Exited or checking: never a live, usable control claim.
            if let control = availability.controlSummary(control: worker.control) { parts.append(control) }
        } else {
            switch worker.control {
            case .observing(let holder): parts.append("directed by \(holder)")
            case .held: parts.append("you have control")
            }
        }
        if let receipt = shownInterruptReceipt {
            parts.append(receipt.summary)
        } else if worker.interruptRequested, worker.interruptReceipt == nil {
            parts.append("interrupt requested")
        }
        if let receipts = worker.followUpReceipts {
            if isFocusedVariant, receipts.isShown { parts.append(receipts.summary) }
            else if worker.queuedFollowUps > 0 { parts.append("\(worker.queuedFollowUps) follow-ups queued") }
        } else if worker.queuedFollowUps > 0 {
            parts.append("\(worker.queuedFollowUps) follow-ups queued")
        }
        if let request = worker.request {
            parts.append(request.isWorkerDisconnected
                ? "request \(request.shortID) waiting, reply unavailable until reconnected"
                : request.hostIsReconnecting
                ? "request \(request.shortID) waiting, a reply is held until the host reconnects"
                : "request \(request.shortID) waiting")
        }
        // A request its owner answers is named, and never as something the developer can do.
        if let owner = worker.inputOwner {
            for request in worker.observedRequests {
                parts.append("request \(request.shortID) waiting for \(owner.phrase)")
            }
        }
        if let unconfirmed = worker.unconfirmedReply { parts.append("reply to request \(unconfirmed) delivery unknown") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - WorkerActionMenu

/// The action list for one identified worker. Its heading names the worker and assignment the
/// actions apply to; interrupt and stop are set apart and say which worker they affect.
struct WorkerActionMenu: View {
    let worker: WorkerPresentation
    let isFocused: Bool
    let actions: WorkerTileActions
    /// Opens this worker's source inspector. Present only for a worker with a provider source.
    var inspectSource: (() -> Void)? = nil
    /// Opens this worker's provider-session panel. Present only for a worker with a bound session.
    var openProviderSession: (() -> Void)? = nil
    /// Opens this worker's input-request panel. Present only for a worker with a bound session.
    var openElicitations: (() -> Void)? = nil
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(worker.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.foreground)
                Spacer(minLength: 12)
                Text(worker.shortID).font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
            }
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 7)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let view = actions.viewAssignment { row("doc.text", "View assignment", action: view) }
            if let followUp = actions.followUp { row("bubble.left", "Send follow-up…", action: followUp) }
            if let zoom = actions.toggleZoom {
                row("arrow.up.left.and.arrow.down.right", isFocused ? "Return to wall" : "Zoom worker",
                    key: isFocused ? "⌘[" : "⌘]", action: zoom)
            }
            if let reply = actions.openRequest {
                row("bell", worker.isDisconnected ? "View request" : "Reply to request", action: reply)
            }
            if let inspectSource {
                row("doc.text.magnifyingglass", "Inspect source…", label: "Inspect the source of \(worker.name)",
                    action: inspectSource)
            }
            if let openElicitations {
                row("list.bullet.rectangle", "Input requests…",
                    label: "Structured input requests from the agent of \(worker.name)",
                    action: openElicitations)
            }
            if let openProviderSession {
                row("arrow.triangle.2.circlepath", "Provider session…",
                    label: "Provider session, discovery and reattach for \(worker.name)",
                    action: openProviderSession)
            }
            if worker.control != .held, let take = actions.takeControl {
                row("hand.raised", "Take control", label: "Take control of \(worker.name)",
                    isEnabled: !actions.isBusy, action: take)
            }
            if worker.control == .held, let handBack = actions.handBack {
                row("arrow.uturn.backward", "Hand back control", label: "Hand back control of \(worker.name)",
                    isEnabled: !actions.isBusy, action: handBack)
            }
            if let share = actions.share {
                row("square.and.arrow.up", "Share…", label: "Share \(worker.name) with a friend on the network", action: share)
            }
            row("doc.on.doc", "Copy worker ID", action: actions.copyID)
            if actions.interrupt != nil || actions.stop != nil {
                Hairline().padding(.vertical, 5)
                if let interrupt = actions.interrupt {
                    row("waveform.path.ecg", worker.interruptPending ? "Interrupt requested" : "Interrupt turn",
                        label: "Interrupt the current turn of \(worker.name)",
                        isEnabled: !actions.isBusy && !worker.interruptPending, action: interrupt)
                }
                if let stop = actions.stop {
                    row("stop.circle", "Stop worker…", tone: .failure, label: "Stop \(worker.name)",
                        isEnabled: !actions.isBusy, action: stop)
                }
            }
        }
        .padding(8)
        .frame(width: 232, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(worker.name)")
    }

    private func row(_ symbol: String, _ title: String, key: String? = nil, tone: Tone? = nil,
                     label: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 10)
                if let key { KeyCap(keys: key) }
            }
            .foregroundStyle(tone?.color ?? Color(hex: 0xE3E5EE))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(label ?? title)
    }
}

// MARK: - NestedWorkerGroup

/// A parent worker with the workers it delegated to. The header is a disclosure button, then,
/// where the group can be opened, a separate Open group button.
struct NestedWorkerGroup<Content: View>: View {
    let name: String
    let nestedCount: Int
    let collapsed: Bool
    var hasRequest = false
    /// A worker in the group is disconnected. Shown on the collapsed header, where its tile is hidden.
    var hasDisconnected = false
    /// Hosts of the group's workers whose persistent SSH link is reconnecting, named together.
    /// Shown on the collapsed header, where the tiles are hidden.
    var reconnectingHost: String? = nil
    let toggle: () -> Void
    /// Opens the group in the worker pane: the parent pinned over its direct children. Folded or
    /// expanded, the disclosure stays as it is. Nil where the group cannot be opened.
    var open: (() -> Void)? = nil
    @ViewBuilder let content: Content
    /// The group is part of the wall's frame, so it follows the theme. The tiles inside do not.
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Button(action: toggle) {
                    HStack(spacing: 7) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                        Text(name).themeType(theme.wall.groupTitleType).foregroundStyle(.theme(\.color.foreground))
                            .lineLimit(1)
                        Text(nestedCount == 1 ? "1 nested worker" : "\(nestedCount) nested workers")
                            .themeType(theme.wall.groupNoteType).lineLimit(1)
                        Spacer(minLength: 8)
                        if collapsed && hasDisconnected { StatusLabel(.disconnected, size: 10.5) }
                        if collapsed, let reconnectingHost {
                            HostLinkStatus(host: reconnectingHost, style: .label, size: 10.5)
                        }
                        if collapsed && hasRequest {
                            StatusLabel(text: "Needs input", tone: .attention, symbol: "questionmark.circle.fill", size: 10.5)
                        }
                    }
                    .foregroundStyle(.inkSecondary)
                    .frame(minHeight: Metric.groupHeaderHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NestedWorkerGroupLabel.spoken(name: name, nestedCount: nestedCount, collapsed: collapsed,
                                                                  hasRequest: hasRequest, hasDisconnected: hasDisconnected,
                                                                  reconnectingHost: reconnectingHost))
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                .accessibilityHint("Shows or hides this worker group")
                if let open {
                    Button(action: open) {
                        HStack(spacing: 5) {
                            Text("Open group")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .themeType(theme.type.state)
                        .foregroundStyle(.theme(\.color.secondary))
                        .frame(minHeight: Metric.groupHeaderHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(name) over the workers it delegated to")
                    .accessibilityLabel("Open group \(name)")
                    .accessibilityHint("Shows this worker pinned over the workers it delegated to")
                }
            }
            if !collapsed { content }
        }
        .wallGroupFrame(bottom: collapsed ? 0 : WallFrameLayout.groupInset)
    }
}

/// What VoiceOver reads for a worker group's heading. A folded group hides its tiles, so the
/// "Needs input" cue its heading shows is spoken with it; an open group's tiles say it themselves.
enum NestedWorkerGroupLabel {
    static func spoken(name: String, nestedCount: Int, collapsed: Bool, hasRequest: Bool,
                       hasDisconnected: Bool, reconnectingHost: String?) -> String {
        "\(name), \(nestedCount) nested" + (collapsed && hasRequest ? ", needs input" : "")
            + (hasDisconnected ? ", a worker is disconnected" : "")
            + (reconnectingHost.map { ", host \($0) reconnecting" } ?? "")
    }
}

// MARK: - WorkerWall

/// Multirow wall, laid out from a `WallPlan`. Standalone workers fill rows of up to three columns;
/// each parent with nested workers gets a collapsible group. The last row can give way to the
/// attention stack. Whatever follows the local workers (the remote band) is the `footer`, in the
/// same scroll, so it never takes height the tiles need. Every tile is one child keyed by its
/// worker's ID, so a new column count, or a worker moving into a group, moves tiles without
/// rebuilding them.
struct WorkerWall<Tile: View, Footer: View>: View {
    let layout: WallLayout
    let collapsed: Set<String>
    /// Width kept clear at the trailing edge of the last row for the PiP. Zero when no PiP is showing.
    var reservedTrailing: CGFloat = 0
    /// Where the wall is scrolled to, kept by its owner so it survives a zoom and the way back.
    /// The wall starts from it and reports every change. Nil keeps the offset to the wall itself.
    var scrollOffset: Binding<CGFloat>? = nil
    /// The worker whose tile is brought into view when this changes.
    var reveal: WallReveal? = nil
    let toggleGroup: (String) -> Void
    /// Opens a group in the worker pane, by its parent's ID. Nil offers no Open group.
    var openGroup: ((String) -> Void)? = nil
    @ViewBuilder let tile: (WorkerPresentation) -> Tile
    @ViewBuilder let footer: Footer

    /// The footer's laid-out height, so the local rows are planned in the height it leaves.
    @State private var footerHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    /// The offset as last reported. A reference, so scrolling never invalidates the wall.
    @State private var tracker = WallScrollTracker()

    var body: some View {
        if layout.workers.isEmpty {
            VStack(spacing: 0) {
                ContentUnavailableView("Waiting for workers", systemImage: "terminal",
                                       description: Text("Delegated workers will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        } else {
            GeometryReader { geo in
                let plan = WallPlan(WallPlan.Input(width: geo.size.width, height: geo.size.height, layout: layout,
                                                   collapsed: collapsed, reservedTrailing: reservedTrailing,
                                                   footerHeight: footerHeight))
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        // Every tile on the wall is a child of this one layout, standalone or inside
                        // a group, and each group's heading and frame is drawn under its tiles. So
                        // a worker that gains its first nested worker moves into the new group as
                        // the same view, with its keyboard focus and terminal.
                        let shown = plan.shownWorkers
                        let byID = Dictionary(layout.workers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        WallFrames(frames: plan.groups.map(\.frame) + shown.map { plan.frame(of: $0) ?? .zero },
                                   height: plan.tilesHeight) {
                            ForEach(layout.groups) { group in groupFrame(group) }
                            ForEach(shown.compactMap { byID[$0] }) { worker in tile(worker) }
                        }
                        VStack(spacing: 0) { footer }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                    }
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                    tracker.report(offset, to: scrollOffset)
                }
                // The clipped region tiles measure themselves against to report whether they are in view.
                .coordinateSpace(.named(ConsoleVisibility.viewport))
                .onAppear { restore() }
                // The same worker stays at the top when the wall is laid out again.
                .onChange(of: plan) { old, new in
                    let anchored = WallPlan.anchoredOffset(tracker.offset, from: old, to: new)
                    if abs(anchored - tracker.offset) > 0.5 { scroll(to: anchored) }
                }
                .onChange(of: reveal) { _, reveal in
                    guard let reveal, let offset = plan.offset(revealing: reveal.workerID, from: tracker.offset) else { return }
                    scroll(to: offset)
                }
            }
        }
    }

    private func scroll(to offset: CGFloat) {
        tracker.offset = offset
        position.scrollTo(y: offset)
    }

    /// Returns to the offset the owner kept. Reports are held back until then, so the wall's
    /// first layout at the top does not replace the kept offset.
    private func restore() {
        let kept = scrollOffset?.wrappedValue ?? 0
        guard kept > 0.5 else { tracker.isRestored = true; return }
        scroll(to: kept)
        Task {
            // Once more after the first layout, in case the content was not yet measured.
            try? await Task.sleep(for: .milliseconds(60))
            if !tracker.isRestored, abs(tracker.offset - kept) < 0.5 { position.scrollTo(y: kept) }
            tracker.isRestored = true
        }
    }

    /// A group's heading and frame. Its tiles are the wall's own children, placed over it.
    @ViewBuilder private func groupFrame(_ group: WorkerGroup) -> some View {
        let isClosed = collapsed.contains(group.id)
        let reconnecting = Set(group.all.filter(\.hostIsReconnecting).map(\.host)).sorted()
        NestedWorkerGroup(name: group.parent.name, nestedCount: group.members.count, collapsed: isClosed,
                          hasRequest: group.all.contains { $0.request != nil },
                          hasDisconnected: group.all.contains(where: \.isDisconnected),
                          reconnectingHost: reconnecting.isEmpty ? nil : reconnecting.joined(separator: ", "),
                          toggle: { toggleGroup(group.id) },
                          open: openGroup.map { open in { open(group.id) } }) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
        }
    }
}

extension WorkerWall where Footer == EmptyView {
    /// A wall with nothing after its local workers.
    init(layout: WallLayout, collapsed: Set<String>, reservedTrailing: CGFloat = 0,
         scrollOffset: Binding<CGFloat>? = nil, reveal: WallReveal? = nil,
         toggleGroup: @escaping (String) -> Void, openGroup: ((String) -> Void)? = nil,
         @ViewBuilder tile: @escaping (WorkerPresentation) -> Tile) {
        self.init(layout: layout, collapsed: collapsed, reservedTrailing: reservedTrailing, scrollOffset: scrollOffset,
                  reveal: reveal, toggleGroup: toggleGroup, openGroup: openGroup, tile: tile, footer: { EmptyView() })
    }
}

/// The wall's scroll offset as last reported, held outside view state.
@MainActor final class WallScrollTracker {
    var offset: CGFloat = 0
    /// The kept offset has been applied, so reports may replace it.
    var isRestored = false

    func report(_ offset: CGFloat, to binding: Binding<CGFloat>?) {
        guard isRestored || offset > 0.5 else { return }
        isRestored = true
        self.offset = offset
        if let binding, abs(binding.wrappedValue - offset) > 0.5 { binding.wrappedValue = offset }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - CoordinatorConsole

/// The coordinator in the stationary left pane: who it is, its live terminal output and any
/// request waiting inside the run. The assignment the developer gave this run stays out of the
/// scrollback in every display mode; the title bar's assignment button opens it in a sheet.
struct CoordinatorConsole: View {
    let coordinator: WorkerPresentation
    let assignment: String
    let startedAt: String?
    let awaiting: [RequestPresentation]
    var isKeyFocused = false
    /// Sends a message to the coordinator. Present only where the service supports it.
    var sendMessage: ((String) -> Void)? = nil
    /// Sends the owner's follow-up to a coordinator the owner controls, and reports whether the
    /// service accepted it. Present only while the feature model's gate is open; it then takes the
    /// composer in place of `sendMessage`, and a refused draft stays in the field.
    var sendFollowUp: ((String) async -> Bool)? = nil
    /// The coordinator's provider source, when it has one.
    var source: ConsoleSourceAccess? = nil
    /// The coordinator's provider session: status, discovery and reattach, the same panel a
    /// worker's action list opens. Offered from the display menu, the control this console has.
    var providerSession: ProviderSessionAccess? = nil
    let openRequest: (RequestPresentation) -> Void
    /// Laid-out height of the transcript, reported by the terminal well.
    @State private var transcriptHeight: CGFloat = 160
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?

    private var prettySession: NativeSession? {
        guard PrettyACPScope.applies(mode: modes?.mode(for: coordinator.id) ?? .console, session: coordinator.session)
        else { return nil }
        return coordinator.session
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status lives in the terminal's status line, once.
            ConsoleTitleBar(title: coordinator.name, client: coordinator.client, host: coordinator.host,
                            platform: coordinator.platform, location: coordinator.location,
                            locationIsBranch: coordinator.locationIsBranch, density: .console) {
                // The assignment is not in the scrollback in any mode; this opens it.
                if CoordinatorAssignmentButton.isOffered(for: assignment) {
                    CoordinatorAssignmentButton(assignment: assignment, startedAt: startedAt)
                }
                ConsoleModeTitlebarControl(consoleID: coordinator.id, consoleName: coordinator.name,
                                           client: coordinator.client, source: source,
                                           providerSession: providerSession,
                                           terminal: NativeTerminalTarget(worker: coordinator))
            }
            if let session = prettySession {
                prettyScrollback(session: session)
            } else {
                // One scrollback: the transcript, then any waiting request directly after it. A long
                // transcript scrolls in place while the notices stay visible beneath it.
                VStack(alignment: .leading, spacing: 0) {
                    ConsoleScrollback(worker: coordinator, density: .regular, horizontalInset: 0,
                                      terminal: NativeTerminalTarget(worker: coordinator),
                                      live: PrettyLive(state: coordinator.state, workerName: coordinator.name,
                                                       turnIsRunning: coordinator.turnIsRunning),
                                      reportsAsCoordinator: true) {
                        if !coordinator.transcript.isEmpty {
                            TranscriptView(entries: coordinator.transcript, agentName: coordinator.name,
                                           fontSize: 12.5, inset: 0,
                                           consoleID: coordinator.id, density: .regular)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .layoutPriority(1)
                        } else if coordinator.output.isEmpty {
                            Text("… waiting for the coordinator's first output")
                                .font(Term.font(12.5)).foregroundStyle(.inkTermDim)
                        } else {
                            TerminalWell(output: coordinator.output, workerID: coordinator.id, workerName: coordinator.name,
                                         fontSize: 12.5, inset: NSSize(width: 0, height: 2),
                                         onContentHeight: { transcriptHeight = $0 })
                                .frame(maxWidth: .infinity, maxHeight: transcriptHeight)
                                .layoutPriority(1)
                        }
                    }
                    if let error = coordinator.error, !error.isEmpty {
                        ConsoleNotice(text: error, state: coordinator.state)
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(awaiting) { request in
                        AttentionNotice(request: request, detail: detail(for: request)) { openRequest(request) }
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 12).padding(.horizontal, 17).padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Term.background)
            }
            TerminalStatusLine(state: coordinator.state, size: 11.5, inset: 17,
                               reconnectingHost: coordinator.hostIsReconnecting ? coordinator.host : nil) {
                if let telemetry = coordinator.telemetry {
                    ProviderUsageStatus(telemetry: telemetry, size: 10.5)
                }
                if isKeyFocused {
                    InputOwnership(workerName: coordinator.name, control: coordinator.control, isKeyFocused: true)
                }
            }
            if let sendFollowUp {
                // The same quiet footer line: only what the send reports differs.
                TerminalComposer(workerName: coordinator.name, prompt: "Message coordinator",
                                 outlined: false, send: sendFollowUp)
            } else if let sendMessage {
                TerminalComposer(workerName: coordinator.name, prompt: "Message coordinator",
                                 outlined: false, send: { text in
                                     sendMessage(text)
                                     return true
                                 })
            }
        }
        .harnessConsoleSurface(coordinator.client, attention: coordinator.request != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coordinator \(coordinator.name), \(coordinator.state.label)"
                            + (coordinator.hostIsReconnecting ? ", host reconnecting" : ""))
    }

    /// Pretty on an ACP-bound coordinator: the structured console at the
    /// console's own inset, then the error and the waiting-request notices. Each notice opens its
    /// request where it is answered; the coordinator holds no reply form.
    private func prettyScrollback(session: NativeSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Stories open each waiting request through the same route as its notice below.
            PrettyACPConsole(worker: coordinator, session: session, density: .regular, inset: 17,
                             stories: .opens(awaiting) { request in openRequest(request) })
            VStack(alignment: .leading, spacing: 8) {
                if let error = coordinator.error, !error.isEmpty {
                    ConsoleNotice(text: error, state: coordinator.state)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(awaiting) { request in
                    AttentionNotice(request: request, detail: detail(for: request)) { openRequest(request) }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, (coordinator.error?.isEmpty == false || !awaiting.isEmpty) ? 8 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Term.background)
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
    /// Laid over the header's title area when the stack is the content of its own window, so that
    /// area moves the window. The in-window PiP has none.
    var dragHandle: AnyView? = nil
    /// The asking worker's provider source, when it has one. The stack stays compact: its action
    /// opens the source inspector on that worker's own console.
    var source: ConsoleSourceAccess? = nil
    /// The conversation's exact height when the stack fills a resizable window of its own: Pretty
    /// and Terminal both take exactly this much, so the window's room goes to the transcript and
    /// everything else keeps its size. Nil keeps the compact in-window PiP (92 pt at most).
    var conversationHeight: CGFloat? = nil
    /// Laid-out height of the context tail, reported by the terminal well.
    @State private var tailHeight: CGFloat = 44
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?

    /// The asking worker's session when the PiP shows `PrettyACPConsole`: Pretty mode on that
    /// worker's console and an ACP-bound session. The mode follows the worker, as on its tile.
    private var prettySession: NativeSession? {
        guard PrettyACPScope.applies(mode: modes?.mode(for: current.workerID) ?? .console,
                                     session: current.workerSession) else { return nil }
        return current.workerSession
    }

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
        .accessibilityLabel("Request from \(current.workerName) in \(current.runTitle)"
                            + (current.isWorkerDisconnected ? ". \(current.workerName) is disconnected." : "")
                            + (current.replyHeldStatement.map { ". \($0)" } ?? ""))
    }

    private var front: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                // The title area: everything in the header that is not a control. In its own
                // window this whole area, including the empty space up to the controls, is the
                // drag handle.
                HStack(spacing: 5) {
                    Image(systemName: "bell").font(.system(size: 11))
                    Text("Needs attention").font(.system(size: 12, weight: .semibold))
                }
                .padding(.leading, 13)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .overlay { if let dragHandle { dragHandle } }
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
            .padding(.trailing, 8).padding(.vertical, 2)
            Hairline()
            VStack(alignment: .leading, spacing: 0) {
                // The same terminal pane as the wall and the focused worker, at PiP density: the
                // shared title bar naming the source run, worker and host, the worker's recent
                // output, the request as an inline prompt, and the slim status line.
                VStack(spacing: 0) {
                    ConsoleTitleBar(title: current.workerName, client: current.client, host: current.host,
                                    platform: current.platform, lineage: [current.runTitle], density: .pip) {
                        ConsoleModeTitlebarControl(consoleID: current.workerID, consoleName: current.workerName,
                                                   client: current.client, source: source,
                                                   terminal: NativeTerminalTarget(request: current))
                    }
                    if let session = prettySession {
                        // Pretty on an ACP-bound worker: the recent part of its current turn and this
                        // request's one reply form, at PiP density.
                        PrettyACPConsole(request: current, session: session, reply: reply,
                                         inset: 11, conversationHeight: conversationHeight ?? 92)
                    } else {
                        // Terminal mode shows the asking worker's live terminal here, with or without
                        // AG-UI context; its identity follows the request's worker, so rotating the
                        // stack changes the attachment. With a conversation height the slot keeps that
                        // height even before there is output, so the stack's size never depends on it.
                        VStack(spacing: 0) {
                            NativeTerminalRegion(consoleID: current.workerID, target: NativeTerminalTarget(request: current),
                                                 hasTranscript: !current.contextEntries.isEmpty || !current.contextTail.isEmpty) {
                                ConsoleScrollback(request: current, density: .pip,
                                                  horizontalInset: 8, terminal: NativeTerminalTarget(request: current),
                                                  live: PrettyLive(state: current.workerState, workerName: current.workerName,
                                                                   turnIsRunning: current.workerTurnIsRunning)) {
                                    if !current.contextEntries.isEmpty {
                                        // A recent window of whole entries: a tool result always sits with its call.
                                        TranscriptView(entries: current.contextEntries, agentName: current.workerName,
                                                       fontSize: 10.75, inset: 11,
                                                       consoleID: current.workerID, density: .pip)
                                            .frame(height: conversationHeight ?? 92)
                                    } else if !current.contextTail.isEmpty {
                                        TerminalWell(output: current.contextTail.joined(separator: "\n"),
                                                     workerID: "pip-\(current.id)", workerName: current.workerName,
                                                     fontSize: 10.75, inset: NSSize(width: 11, height: 7),
                                                     onContentHeight: { tailHeight = $0 })
                                            .frame(height: conversationHeight ?? min(tailHeight, 86))
                                    }
                                }
                                .frame(minHeight: conversationHeight, maxHeight: conversationHeight ?? 92)
                            }
                        }
                        .frame(height: conversationHeight, alignment: .top)
                        RequestPrompt(request: current, reply: reply, density: .compact, inset: 11)
                    }
                    // The asking worker's status: disconnected ahead of needs input, as on its tile.
                    TerminalStatusLine(state: current.workerState, size: 10.75, inset: 11,
                                       reconnectingHost: current.hostIsReconnecting ? current.host : nil) {
                        if let telemetry = current.workerTelemetry {
                            ProviderUsageStatus(telemetry: telemetry, size: 10)
                        }
                        // The shared ownership cue: its words whole, or the symbol alone with the
                        // full statement in its help tag and accessibility label.
                        InputOwnership(workerName: current.workerName,
                                       control: .observing(holder: current.inputHolder), size: 10.5)
                    }
                }
                .harnessConsoleSurface(current.client, raised: false)
            }
            .padding(.horizontal, 11).padding(.top, 10).padding(.bottom, 11)
        }
        .glassSurface(.floating, radius: Radius.overlay)
        .attentionGlow(true, radius: Radius.overlay)
    }
}

// MARK: - AttentionDrawer

/// The side-panel presentation of pending decisions: the same request the PiP would show, beside
/// the coordinator and wall. It carries the shared RequestReply, so a draft follows its request.
struct AttentionDrawer: View {
    let current: RequestPresentation
    let others: [RequestPresentation]
    let reply: ReplyContext
    var takeControl: (() -> Void)? = nil
    /// Pinned: the panel has its own width beside the content. Unpinned: it lies over the content.
    var isPinned = true
    /// Switches between pinned and unpinned. The toggle is shown only where this exists.
    var togglePin: (() -> Void)? = nil
    let show: (RequestPresentation) -> Void
    let openWorker: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text("Needs attention").font(TypeRole.section).tracking(-0.4).foregroundStyle(Palette.foreground)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let togglePin {
                    SymbolButton(symbol: isPinned ? "pin.fill" : "pin",
                                 label: isPinned ? "Unpin panel so it overlays the content"
                                                 : "Pin panel beside the content",
                                 action: togglePin)
                        .foregroundStyle(isPinned ? AnyShapeStyle(Palette.foreground) : AnyShapeStyle(.inkSecondary))
                        .accessibilityValue(isPinned ? "Pinned" : "Unpinned")
                }
                SymbolButton(symbol: "xmark", label: "Close attention panel", action: close)
                    .foregroundStyle(.inkSecondary)
            }
            .padding(.bottom, 10)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        StatusLabel(current.workerState, size: 11.5)
                        if current.hostIsReconnecting {
                            HostLinkStatus(host: current.host, style: .label, size: 11.5)
                        }
                        Spacer(minLength: 8)
                        Text(current.shortID).font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                            .help("Request \(current.id)")
                    }
                    .padding(.top, 14).padding(.bottom, 12)
                    WorkerIdentity(name: current.workerName, client: current.client,
                                   details: [.init(text: current.runTitle), .init(text: current.host)], density: .pip)
                        .padding(.bottom, 16)
                    section("Question") {
                        // Its choices are the buttons below, so their appended text list is left out.
                        Text(current.promptWithoutChoiceList).font(.system(size: 13)).lineSpacing(4)
                            .foregroundStyle(Color(hex: 0xE6E8F0)).textSelection(.enabled)
                    }
                    if !current.contextTail.isEmpty {
                        section("Worker context") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(current.contextTail.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.inkSecondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    section("Input owner") {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(current.inputHolder, systemImage: "arrow.triangle.branch")
                                .font(.system(size: 14)).foregroundStyle(Palette.foreground)
                            Text("\(current.project) · \(current.runTitle) · \(current.runID)")
                                .font(TypeRole.meta).foregroundStyle(.inkSecondary)
                        }
                    }
                    if !others.isEmpty {
                        section("Also pending") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(others) { request in
                                    Button { show(request) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 7) {
                                                Image(systemName: "bubble.left").font(.system(size: 12))
                                                Text(request.workerName).font(.system(size: 14))
                                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                            }
                                            .foregroundStyle(Palette.foreground)
                                            Text("\(request.runTitle) · \(request.host) · \(request.shortID)")
                                                .font(TypeRole.meta).foregroundStyle(.inkSecondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Show request \(request.shortID) from \(request.workerName)")
                                }
                            }
                        }
                    }
                }
            }
            VStack(spacing: 8) {
                RequestReply(request: current, context: reply)
                if let takeControl {
                    Button(action: takeControl) {
                        Label("Take control", systemImage: "hand.raised").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CapsuleButtonStyle())
                }
                Button(action: openWorker) {
                    Label("Open worker", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButtonStyle())
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 15).padding(.top, 16).padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSurface(.floating, radius: Radius.overlay)
        .attentionGlow(true, radius: Radius.overlay)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs attention: \(current.workerName) in \(current.runTitle)")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Hairline()
            Kicker(text: title).padding(.top, 5)
            content()
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Banner shown after following a request into another run, with the way back.
struct ReturnStrip: View {
    let target: ReturnTarget
    let goBack: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell").font(.system(size: 12)).foregroundStyle(Palette.attention)
            Text("Switched to pending request").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            Text(target.requestLabel).font(.system(size: 12)).foregroundStyle(.inkSecondary).lineLimit(1)
            Spacer(minLength: 12)
            Button(action: goBack) {
                Label("Return to \(target.title)", systemImage: "chevron.left")
            }
            .buttonStyle(CapsuleButtonStyle(height: 29))
            SymbolButton(symbol: "xmark", label: "Stay in this run", size: 10, action: dismiss)
                .foregroundStyle(.inkSecondary)
        }
        .padding(.horizontal, Metric.runHeaderInset)
        .frame(minHeight: 44)
        .background(Palette.attentionFill.opacity(0.7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switched to pending request \(target.requestLabel)")
    }
}

// MARK: - RunHeader

/// Identity and state of the selected run with its run-level actions.
struct RunHeader: View {
    let run: RunContent
    let canStop: Bool
    @Binding var showingDetails: Bool
    let showRuns: () -> Void
    /// Goes back to the run's project. Nil where the window has no project overview, and the
    /// project's name is then plain text.
    var showProject: (() -> Void)? = nil
    let stop: () -> Void
    /// Opens the network tray's share sheet for this run's repository.
    var share: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 11))
                    if let showProject {
                        Button(run.project, action: showProject).buttonStyle(.plain).lineLimit(1)
                            .help("Back to \(run.project)")
                            .accessibilityLabel("Back to project \(run.project)")
                    } else {
                        Text(run.project).lineLimit(1)
                    }
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
                    if let share {
                        Button("Share repository…", action: share)
                        Divider()
                    }
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
