import SwiftUI

// NATIVE TERMINAL VIEWER — components
//
//   Atom       NativeTerminalLinkStatus   observing, detached or ended, in terminal ink
//   Molecules  NativeTerminalMenuItems    the action in a console title bar's display menu
//              NativeTerminalHeader       the shared ConsoleTitleBar, the link status, detach or
//                                          reconnect, and close, on one line
//   Organism   NativeTerminalViewer       header, opaque well and its one-line notice, square surface
//   Page       NativeTerminalWindowPage   one viewer window for one worker
//   Scene      NativeTerminalScene        a window per worker, opened by value, never restored
//
// The components receive values and emit actions. The feature model owns the attachment.

// MARK: - Atom

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

// MARK: - Molecules

/// The native action that opens a worker's terminal viewer. It sits in the title bar's display
/// menu beside the source inspector. A worker on another host shows the item disabled, with the
/// reason in its title.
struct NativeTerminalMenuItems: View {
    let target: NativeTerminalTarget
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Terminal — This Console") {
            Button {
                openWindow(id: NativeTerminalScene.id, value: target)
            } label: {
                Label(target.isLocal ? "Watch Terminal…" : "Watch Terminal — This Mac Only",
                      systemImage: "apple.terminal")
            }
            .disabled(!target.isLocal)
        }
    }
}

/// One line: the console title bar names the worker and its host; the trailing accessory states
/// the link and offers detach or reconnect, then close.
struct NativeTerminalHeader: View {
    let target: NativeTerminalTarget
    let phase: NativeTerminalPhase
    let detach: () -> Void
    let reconnect: () -> Void
    let close: () -> Void

    var body: some View {
        ConsoleTitleBar(title: target.workerName, client: target.client, host: target.host,
                        platform: target.isLocal ? .localMac : .unknown, density: .focused) {
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

// MARK: - Organism

/// The square console with the opaque terminal well. The notice line states what the well cannot:
/// that input is not sent, why the viewer ended, or why there is no viewer.
struct NativeTerminalViewer: View {
    let target: NativeTerminalTarget
    let phase: NativeTerminalPhase
    let launch: NativeTerminalLaunch?
    let generation: Int
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
                    NativeTerminalWell(launch: launch, isLive: phase.isObserving) { code in
                        processEnded(attachment, code)
                    }
                    .id(attachment)
                    .padding(.leading, 8).padding(.vertical, 4)
                }
            }
            Hairline()
            notice
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

    init(target: NativeTerminalTarget) {
        _model = State(initialValue: NativeTerminalViewerModel(target: target))
    }

    var body: some View {
        NativeTerminalViewer(target: model.target, phase: model.phase, launch: model.launch,
                             generation: model.generation,
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

    var body: some Scene {
        WindowGroup("Terminal", id: Self.id, for: NativeTerminalTarget.self) { $target in
            if let target {
                NativeTerminalWindowPage(target: target)
                    .singleInstanceAuxiliaryScene()
            }
        }
        .defaultSize(width: 920, height: 580)
        .windowToolbarStyle(.unifiedCompact)
        // A restored window would start agentctl at launch without the developer asking.
        .restorationBehavior(.disabled)
    }
}
