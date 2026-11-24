import SwiftUI

// NATIVE TERMINAL VIEWER — components
//
//   Atoms      NativeTerminalLinkStatus   the standalone window's link: observing, detached, ended
//              NativeTerminalChromeStatus an inline console's terminal status in its title bar:
//                                          live, or retry / reconnect when it shows the transcript
//   Molecules  NativeTerminalMenuItems    in a console's display menu: detach or reconnect the
//                                          inline terminal, and watch it in its own window
//              NativeTerminalHeader       the window's ConsoleTitleBar with link status and actions
//              NativeTerminalViewport     one inline attachment: the shared well, keyed by worker
//                                          and reconnect generation
//   Organisms  NativeTerminalSlot         Terminal mode inside ConsoleScrollback: the viewport, or
//                                          the console's own transcript as fallback
//              NativeTerminalCardPreview  FIXTURE ONLY: a sample terminal in an All Agents card
//              NativeTerminalViewer       the standalone window's console: header, well, notice
//   Page       NativeTerminalWindowPage   one viewer window for one worker
//   Scene      NativeTerminalScene        a window per worker, opened by value, never restored
//
// Inline consoles keep their own title bar and status line; the terminal adds one status item to
// the title bar and items to the display menu it already has. Components receive values and emit
// actions. NativeTerminalLedger owns inline status; each viewport owns its own attachment.

// MARK: - Atoms

struct NativeTerminalLinkStatus: View {
    let phase: NativeTerminalPhase
    var size: CGFloat = 11.5

    private var glyph: String {
        switch phase {
        case .observing: "●"
        case .detached: "○"
        case .ended(let code): code == 0 ? "○" : "!"
        case .unsupported: "–"
        }
    }

    private var word: String {
        switch phase {
        case .observing: "observing · read-only"
        case .detached: "detached"
        case .ended(let code): code == 0 ? "ended" : "could not attach"
        case .unsupported: "unavailable"
        }
    }

    private var ink: Color {
        switch phase {
        case .observing: Term.green
        case .detached: Term.dim
        case .ended(let code): code == 0 ? Term.dim : Term.amber
        case .unsupported: Term.dim
        }
    }

    var body: some View {
        HStack(spacing: size * 0.5) {
            Text(glyph)
            Text(word)
        }
        .font(Term.font(size))
        .foregroundStyle(ink)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal viewer \(word)")
    }
}

/// The inline terminal's status, in the console title bar beside the display menu. Drawn only
/// while the console is in Terminal mode and its worker is eligible. Live is a quiet word; a
/// console showing its transcript because the terminal ended or was detached offers the one
/// action that attaches again. Nothing retries by itself.
struct NativeTerminalChromeStatus: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @Environment(NativeTerminalLedger.self) private var ledger: NativeTerminalLedger?

    let consoleID: String
    let target: NativeTerminalTarget
    var size: CGFloat = 10.5

    var body: some View {
        if let ledger, modes?.mode(for: consoleID) == .terminal, ledger.isEligible(target) {
            if let block = ledger.block(for: target.workerID) {
                let isDetached = block == .detached
                Button { ledger.reconnect(target.workerID) } label: {
                    ViewThatFits(in: .horizontal) {
                        Text(isDetached ? "○ reconnect" : "↻ retry terminal").fixedSize()
                        Text(isDetached ? "○" : "↻").fixedSize()
                    }
                }
                .buttonStyle(TermButtonStyle(ink: isDetached ? Term.dim : Term.amber, size: size))
                .help(block.statement(workerName: target.workerName))
                .accessibilityLabel(isDetached ? "Reconnect terminal for \(target.workerName)"
                                               : "Retry terminal for \(target.workerName)")
                .accessibilityHint(block.statement(workerName: target.workerName))
            } else {
                let isSample = ledger.source == .fixture
                ViewThatFits(in: .horizontal) {
                    Text(isSample ? "● sample" : "● live").fixedSize()
                    Text("●").fixedSize()
                }
                .font(Term.font(size))
                .foregroundStyle(Term.green)
                .lineLimit(1)
                .help(isSample
                      ? "Sample terminal output for this design preview. No terminal is attached."
                      : "Live terminal for \(target.workerName), read-only. Keys and paste are not sent.")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isSample ? "Sample terminal" : "Live terminal, read-only")
            }
        }
    }
}

// MARK: - Molecules

/// The terminal actions in a console title bar's display menu. The inline items appear while the
/// console is in Terminal mode; Watch Terminal opens the standalone window in any mode.
struct NativeTerminalMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @Environment(NativeTerminalLedger.self) private var ledger: NativeTerminalLedger?

    let target: NativeTerminalTarget
    var consoleID: String? = nil

    var body: some View {
        Section("Terminal — This Console") {
            if let ledger, let consoleID, modes?.mode(for: consoleID) == .terminal, ledger.isEligible(target) {
                if let block = ledger.block(for: target.workerID) {
                    Button { ledger.reconnect(target.workerID) } label: {
                        Label(block == .detached ? "Reconnect Terminal" : "Retry Terminal",
                              systemImage: "arrow.clockwise")
                    }
                } else {
                    Button { ledger.detach(target.workerID) } label: {
                        Label("Detach Terminal", systemImage: "eject")
                    }
                }
            }
            Button {
                openWindow(id: NativeTerminalScene.id, value: target)
            } label: {
                Label("Watch Terminal in Window…", systemImage: "macwindow")
            }
        }
    }
}

/// One line: the console title bar names the worker and its host; the trailing accessory states
/// the link and offers detach or reconnect, then close. Used only by the standalone window.
struct NativeTerminalHeader: View {
    let target: NativeTerminalTarget
    let phase: NativeTerminalPhase
    let detach: () -> Void
    let reconnect: () -> Void
    let close: () -> Void

    var body: some View {
        ConsoleTitleBar(title: target.workerName, client: target.client, host: target.host,
                        platform: target.platform, density: .focused) {
            NativeTerminalLinkStatus(phase: phase)
            if phase.isObserving {
                headerButton("Detach", symbol: "eject", action: detach)
                    .help("Stop watching. \(target.workerName) and its tmux session keep running.")
                    .accessibilityLabel("Detach from \(target.workerName)")
            } else if phase.canReconnect {
                headerButton("Reconnect", symbol: "arrow.clockwise", action: reconnect)
                    .help("Attach a new read-only viewer to \(target.workerName).")
                    .accessibilityLabel("Reconnect to \(target.workerName)")
            }
            Button(action: close) {
                Image(systemName: "xmark").fontWeight(.semibold)
                    .frame(minWidth: 23, minHeight: 23).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.consoleHeaderControlInk())
            .keyboardShortcut(.cancelAction)
            .help("Close this viewer. \(target.workerName) keeps running.")
            .accessibilityLabel("Close terminal viewer for \(target.workerName)")
        }
    }

    private func headerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
                .font(.system(size: 11.5, weight: .medium))
                .frame(minHeight: 23).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.consoleHeaderControlInk())
    }
}

/// One inline attachment. Its identity is the worker and the reconnect generation, so a worker
/// update redraws around it without reattaching, and a different worker (PiP rotation) or an
/// explicit reconnect gives a new attachment.
struct NativeTerminalViewport: View {
    let target: NativeTerminalTarget
    let feed: NativeTerminalFeed
    let generation: Int
    let fontSize: CGFloat
    let ended: (_ exitCode: Int32?, _ lastLine: String?) -> Void

    var body: some View {
        NativeTerminalWell(feed: feed, fontSize: fontSize, workerName: target.workerName, onExit: ended)
            .id("\(target.workerID)#\(generation)")
    }
}

// MARK: - Organisms

/// Terminal mode for one console. An eligible worker with no block shows its live terminal; any
/// other worker shows the console's own transcript, unchanged. The slot draws no header or footer.
struct NativeTerminalSlot<Fallback: View>: View {
    @Environment(NativeTerminalLedger.self) private var ledger: NativeTerminalLedger?

    let target: NativeTerminalTarget?
    let density: PrettyDensity
    let horizontalInset: CGFloat
    @ViewBuilder let fallback: () -> Fallback

    private var fontSize: CGFloat {
        switch density {
        case .regular: 12.5
        case .compact: 11
        case .pip: 10
        }
    }

    var body: some View {
        if let ledger, let target, ledger.shouldAttach(target), let feed = ledger.feed(for: target) {
            let generation = ledger.generation(for: target.workerID)
            NativeTerminalViewport(target: target, feed: feed, generation: generation, fontSize: fontSize) { code, line in
                ledger.attachmentEnded(target.workerID, generation: generation, exitCode: code, message: line)
            }
            .padding(.horizontal, max(horizontalInset - 2, 0))
            .padding(.vertical, density == .pip ? 3 : 5)
            .frame(maxWidth: .infinity, minHeight: density == .pip ? 86 : 120, maxHeight: .infinity)
            .background(Term.background)
            .layoutPriority(1)
        } else {
            fallback()
        }
    }
}

/// A console region that some surfaces draw only when there is a transcript to show (the PiP's
/// context, the queue's Recent output). In Terminal mode it is also drawn for a worker whose live
/// terminal will show, so the title bar's live status always has a viewport beneath it. The test
/// is the one NativeTerminalChromeStatus and NativeTerminalSlot use.
struct NativeTerminalRegion<Content: View>: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @Environment(NativeTerminalLedger.self) private var ledger: NativeTerminalLedger?

    let consoleID: String
    let target: NativeTerminalTarget
    let hasTranscript: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let showsTerminal = modes?.mode(for: consoleID) == .terminal && (ledger?.shouldAttach(target) ?? false)
        if hasTranscript || showsTerminal { content() }
    }
}

/// Content that belongs to the transcript only, such as a tile's "no output yet" placeholder laid
/// over the well. It is left out while the console shows its live terminal.
struct NativeTerminalTranscriptOnly<Content: View>: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @Environment(NativeTerminalLedger.self) private var ledger: NativeTerminalLedger?

    let consoleID: String
    let target: NativeTerminalTarget
    @ViewBuilder let content: () -> Content

    var body: some View {
        let showsTerminal = modes?.mode(for: consoleID) == .terminal && (ledger?.shouldAttach(target) ?? false)
        if !showsTerminal { content() }
    }
}

/// FIXTURE ONLY. In a design preview started in Terminal mode, an All Agents or Smart View card
/// draws its sample lines in the native well. It starts no process and takes no clicks, so the
/// card stays one button. Otherwise the card's own preview is shown.
struct NativeTerminalCardPreview<Fallback: View>: View {
    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @Environment(NativeTerminalLedger.self) private var ledger: NativeTerminalLedger?

    let consoleID: String
    let workerName: String
    let lines: [String]
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        if ledger?.source == .fixture, modes?.mode(for: consoleID) == .terminal {
            let text = (["\u{1B}[2m[fixture · sample terminal]\u{1B}[0m"] + lines).joined(separator: "\r\n")
            NativeTerminalWell(feed: .fixture(text), fontSize: 11, workerName: workerName) { _, _ in }
                .id(text)
                .allowsHitTesting(false)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Term.background)
        } else {
            fallback()
        }
    }
}

/// The standalone window's square console with the opaque terminal well. The notice line states
/// what the well cannot: that input is not sent, why the viewer ended, or why there is no viewer.
struct NativeTerminalViewer: View {
    let target: NativeTerminalTarget
    let phase: NativeTerminalPhase
    let launch: NativeTerminalLaunch?
    let generation: Int
    /// The worker's reported provider usage, shown beside the notice. Nil without a session.
    var telemetry: ProviderTelemetry? = nil
    let detach: () -> Void
    let reconnect: () -> Void
    let close: () -> Void
    let processEnded: (_ generation: Int, _ exitCode: Int32?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            NativeTerminalHeader(target: target, phase: phase, detach: detach, reconnect: reconnect, close: close)
            Hairline()
            ZStack(alignment: .topLeading) {
                Term.background
                if let launch, !isUnsupported {
                    let attachment = generation
                    NativeTerminalWell(feed: .process(launch), isLive: phase.isObserving,
                                       workerName: target.workerName) { code, _ in
                        processEnded(attachment, code)
                    }
                    .id(attachment)
                    .padding(.leading, 8).padding(.vertical, 4)
                }
            }
            Hairline()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                notice
                Spacer(minLength: 8)
                if let telemetry { ProviderUsageStatus(telemetry: telemetry, size: 10.5).layoutPriority(1) }
            }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Term.bar)
        }
        .harnessConsoleSurface(target.client)
    }

    private var isUnsupported: Bool {
        if case .unsupported = phase { true } else { false }
    }

    private var noticeText: String {
        switch phase {
        case .observing:
            "Read-only. Keys, paste and mouse clicks are not sent. Select text and press ⌘C to copy."
        case .detached:
            "Detached. \(target.workerName) and its tmux session keep running. Reconnect to watch again."
        case .ended(let code) where code == 0:
            "The viewer ended. The worker's terminal session closed or was replaced."
        case .ended(let code):
            "agentctl could not keep the viewer attached"
                + (code.map { " (exit \($0))" } ?? "")
                + ". Its message is shown above. Check that the Commander service is running, then reconnect."
        case .unsupported(let reason):
            reason
        }
    }

    private var noticeInk: Color {
        switch phase {
        case .ended(let code) where code != 0: Term.amber
        case .unsupported: Term.text
        default: Term.dim
        }
    }

    private var notice: some View {
        Text(noticeText)
            .font(Term.font(11))
            .foregroundStyle(noticeInk)
            .lineLimit(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Page

struct NativeTerminalWindowPage: View {
    @State private var model: NativeTerminalViewerModel
    @Environment(\.dismiss) private var dismiss
    /// The cockpit's shared model. Its runs carry the worker's usage; nothing is subscribed here.
    let cockpit: CockpitModel?

    init(target: NativeTerminalTarget, cockpit: CockpitModel? = nil) {
        _model = State(initialValue: NativeTerminalViewerModel(target: target))
        self.cockpit = cockpit
    }

    var body: some View {
        NativeTerminalViewer(target: model.target, phase: model.phase, launch: model.launch,
                             generation: model.generation,
                             telemetry: cockpit?.providerTelemetry(workerID: model.target.workerID),
                             detach: model.detach, reconnect: model.reconnect, close: { dismiss() },
                             processEnded: model.processEnded)
            .padding(10)
            .background(Palette.window)
            .navigationTitle("\(model.target.workerName) — Terminal")
            .frame(minWidth: 560, minHeight: 320)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Scene

struct NativeTerminalScene: Scene {
    static let id = "native-terminal"
    /// The cockpit's live model, read for the worker's reported usage. Nil in previews.
    var model: CockpitModel? = nil

    var body: some Scene {
        WindowGroup("Terminal", id: Self.id, for: NativeTerminalTarget.self) { $target in
            if let target {
                NativeTerminalWindowPage(target: target, cockpit: model)
                    .singleInstanceAuxiliaryScene()
            }
        }
        .defaultSize(width: 920, height: 580)
        .windowToolbarStyle(.unifiedCompact)
        // A restored window would start agentctl at launch without the developer asking.
        .restorationBehavior(.disabled)
    }
}
