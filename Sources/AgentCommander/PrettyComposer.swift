import SwiftUI

// PRETTY MESSAGE BOX AND TRANSCRIPT SETTING
// The follow-up composer in the Pretty language (DESIGN.md, "The frame"), and the setting for
// what Commander keeps of a tool call (spec section F, decisions 6 and 8).
//
//   Value      QueuedFollowUp            a follow-up the service holds for the worker's next turn
//   Molecules  PrettyQueuedMessage       "Queued for the next turn: …" with Remove
//              PrettyComposer            rounded field, Add file, Queue or Send, and Stop
//   Organism   TranscriptSettingsSection Settings › Transcript: keep, hide secrets, limit values
//
// The composer sends a message to one named worker, exactly as written. It is not keystrokes
// into a terminal. Sending, queueing, removing and stopping are the parent's actions: the box
// emits the text, the queued message's ID, or a stop.

struct QueuedFollowUp: Identifiable, Equatable {
    let id: String
    /// The message as written. Empty when an older service did not send it.
    let text: String

    /// The worker's follow-ups the service still holds, oldest first.
    static func queued(_ control: WorkerControl?) -> [QueuedFollowUp] {
        (control?.messages ?? []).filter { $0.status == "queued" }.map { QueuedFollowUp(id: $0.id, text: $0.text ?? "") }
    }
}

struct PrettyQueuedMessage: View {
    let message: QueuedFollowUp
    let metrics: PrettyMetrics
    /// Nil where the service offers no cancel: the line then has no Remove.
    var remove: (() -> Void)? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            (Text("Queued for the next turn: ").foregroundColor(Palette.secondary)
             + Text(verbatim: message.text.isEmpty ? "a follow-up" : CommanderCall.firstLine(message.text))
                .foregroundColor(message.text.isEmpty ? Palette.secondary : Palette.foreground))
                .font(.system(size: metrics.detailSize))
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let remove {
                Button("Remove", action: remove)
                    .buttonStyle(.plain).font(.system(size: metrics.detailSize)).foregroundStyle(Palette.focus)
                    .help("Take this message back before the next turn starts")
                    .accessibilityLabel("Remove queued message")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay { shape.strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued for the next turn: \(message.text)")
    }
}

/// The message box. While a turn runs the action reads Queue and a square Stop interrupts the
/// turn and keeps the conversation; idle, the square is a Send arrow. While a send is in flight
/// the box is locked, and the draft is cleared only once the send is accepted.
struct PrettyComposer: View {
    let workerName: String
    /// A turn is running: a message waits for the next turn, and Stop shows.
    let isWorking: Bool
    var queued: [QueuedFollowUp] = []
    /// Returns true when the message was accepted.
    let send: (String) async -> Bool
    /// File context for the follow-up. Nil where the session accepts neither a link nor a snapshot.
    var context: FollowUpContextAccess? = nil
    var removeQueued: ((String) -> Void)? = nil
    /// Interrupts the running turn. It is not Stop worker, which stays in the worker's menu.
    var stop: (() -> Void)? = nil
    /// Why Stop is disabled, when the service refuses an interrupt.
    var stopUnavailable: String? = nil

    @State private var text = ""
    @State private var isSending = false
    @State private var files: [FollowUpContextItem] = []
    @State private var isChoosing = false
    @State private var chosenKind: FollowUpContextKind?
    @State private var fileError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        let metrics = PrettyMetrics(.regular)
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
        let shape = RoundedRectangle(cornerRadius: metrics.blockRadius, style: .continuous)
        let placeholder = isWorking ? "⌘↩ queues it while the agent works" : "Follow up with \(workerName)"
        VStack(alignment: .leading, spacing: 8) {
            ForEach(queued) { message in
                PrettyQueuedMessage(message: message, metrics: metrics,
                                    remove: removeQueued.map { remove in { remove(message.id) } })
            }
            VStack(alignment: .leading, spacing: 10) {
                TextField("Follow-up message for \(workerName)", text: $text, prompt: Text(placeholder), axis: .vertical)
                    .textFieldStyle(.plain).font(metrics.body)
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .disabled(isSending)
                    .onSubmit(submit)
                if !files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(files) { file in
                                FollowUpContextChip(item: file, isEnabled: !isSending) { files.removeAll { $0.id == file.id } }
                            }
                        }
                    }
                }
                if let fileError {
                    Text(verbatim: fileError).font(.system(size: metrics.detailSize)).foregroundStyle(Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("File not attached: \(fileError)")
                }
                HStack(spacing: 10) {
                    if let context {
                        FollowUpContextMenu(linkUnavailable: context.linkUnavailable,
                                            snapshotUnavailable: context.snapshotUnavailable,
                                            isEnabled: !isSending) { kind in
                            fileError = nil
                            chosenKind = kind
                            isChoosing = true
                        }
                        Text("Add file").font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 8)
                    if isSending {
                        Text(isWorking ? "Queueing…" : "Sending…").font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                            .accessibilityLabel("Sending to \(workerName)")
                    } else if isWorking {
                        Button("Queue", action: submit)
                            .buttonStyle(PrettyFormButtonStyle(isPrimary: !isEmpty, metrics: metrics))
                            .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                            .disabled(isEmpty)
                            .help("Queue this for \(workerName)'s next turn (⌘↩)")
                            .accessibilityLabel("Queue message for \(workerName)")
                    }
                    if isWorking {
                        Button { stop?() } label: {
                            RoundedRectangle(cornerRadius: 2).fill(Palette.panel).frame(width: 9, height: 9)
                                .frame(width: 26, height: 26)
                                .background(Palette.foreground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(stop == nil)
                        .opacity(stop == nil ? 0.4 : 1)
                        .help(stop == nil ? (stopUnavailable ?? "This turn cannot be interrupted right now.")
                                          : "Stop this turn. The conversation is kept.")
                        .accessibilityLabel("Stop this turn")
                    } else if !isSending {
                        Button(action: submit) {
                            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.panel)
                                .frame(width: 26, height: 26)
                                .background(Palette.foreground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                        .disabled(isEmpty)
                        .opacity(isEmpty ? 0.4 : 1)
                        .help("Send to \(workerName) (↩ or ⌘↩; ⌥↩ for a new line)")
                        .accessibilityLabel("Send to \(workerName)")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Palette.well, in: shape)
            .overlay { shape.strokeBorder(isFocused ? Palette.focus.opacity(0.7) : Palette.hairline, lineWidth: 1) }
        }
        .padding(.horizontal, 21).padding(.vertical, 10)
        .background(Term.background)
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            attach(result)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message box for \(workerName)")
    }

    private func attach(_ result: Result<[URL], Error>) {
        // The chooser clears its presentation before it reports, so the kind is kept apart.
        guard let kind = chosenKind, let context else { return }
        chosenKind = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            switch context.prepare(url, kind) {
            case .success(let item):
                files.append(item)
                fileError = nil
            case .failure(let error):
                fileError = error.localizedDescription
            }
        case .failure(let error):
            fileError = error.localizedDescription
        }
        isFocused = true
    }

    private func submit() {
        // Emptiness is judged without whitespace, but the text that goes out is the literal draft.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !isSending, hasText || !files.isEmpty else { return }
        let message = text
        let attached = files
        isSending = true
        Task {
            let accepted: Bool
            if let context, !attached.isEmpty {
                accepted = await context.send(message, attached)
            } else {
                accepted = await send(message)
            }
            isSending = false
            // Cleared only on acceptance, and only if the developer has not edited it meanwhile.
            if accepted, text == message, files == attached {
                text = ""
                files = []
                fileError = nil
            }
        }
    }
}

// MARK: - Settings › Transcript

/// What Commander keeps of a tool call, stored with the service so every client sees the same
/// records. The first option is the default and clears the other two, which can both be on.
struct TranscriptSettingsSection: View {
    let settings: TranscriptSettings
    /// The service answered: the options show its values. Until then they are disabled.
    var isLoaded = true
    var error: String? = nil
    let change: (TranscriptSettings) -> Void

    static let sizes: [(bytes: Int, label: String)] = [
        (4 << 10, "4 KB"), (16 << 10, "16 KB"), (64 << 10, "64 KB"), (256 << 10, "256 KB"),
    ]

    static let warning = "With \u{201C}Keep everything as sent\u{201D}, secrets an agent passes to a tool are stored and shown on every surface, including the PiP."
    static let limits = "A single argument, result or content value is capped at 512 KB, and each worker keeps its latest 256 records or 16 MB; older records are dropped."

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 11) {
                    Kicker(text: "Transcript")
                    Text("Tool calls in the transcript")
                        .font(.system(size: 22, weight: .semibold)).tracking(-0.7)
                        .foregroundStyle(Palette.foreground)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: Space.m)
                Label("Stored with the service", systemImage: "externaldrive")
                    .font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                option("Keep everything as sent", detail: "Full arguments and results.", isOn: settings.keepsEverything,
                       identifier: "transcript-keep") { change(TranscriptSettings()) }
                Text(verbatim: Self.warning)
                    .font(.system(size: 12.5)).foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24).padding(.bottom, 6)
                    .accessibilityIdentifier("transcript-warning")
                option("Hide values that look like secrets",
                       detail: "Tokens, passwords and keys show as Hidden with Reveal, in Source too. Copy needs Reveal first.",
                       isOn: settings.hideSecrets, identifier: "transcript-hide-secrets") {
                    var next = settings
                    next.hideSecrets.toggle()
                    change(next)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    option("Limit large values", detail: "Longer values are shortened and marked.",
                           isOn: settings.limitBytes > 0, identifier: "transcript-limit") {
                        var next = settings
                        next.limitBytes = settings.limitBytes > 0 ? 0 : TranscriptSettings.offeredLimit
                        change(next)
                    }
                    Picker("Limit", selection: Binding(
                        get: { settings.limitBytes > 0 ? settings.limitBytes : TranscriptSettings.offeredLimit },
                        set: { bytes in
                            var next = settings
                            next.limitBytes = bytes
                            change(next)
                        })) {
                        ForEach(sizes, id: \.bytes) { size in Text(size.label).tag(size.bytes) }
                    }
                    .labelsHidden().frame(width: 96)
                    .disabled(settings.limitBytes == 0 || !isLoaded)
                    .accessibilityLabel("Largest value kept")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface()
            .disabled(!isLoaded)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: Self.limits)
                Text("These settings apply to new records. Stored records keep what they have.")
                if !isLoaded { Text("The service has not answered yet, so the options are disabled.").foregroundStyle(Palette.attention) }
                if let error { Text(verbatim: "Not saved: \(error)").foregroundStyle(Palette.failure) }
            }
            .font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The limit menu's sizes, with the current one when it is not among them.
    private var sizes: [(bytes: Int, label: String)] {
        guard settings.limitBytes > 0, !Self.sizes.contains(where: { $0.bytes == settings.limitBytes }) else { return Self.sizes }
        return (Self.sizes + [(settings.limitBytes, "\(settings.limitBytes / 1024) KB")]).sorted { $0.bytes < $1.bytes }
    }

    private func option(_ title: String, detail: String, isOn: Bool, identifier: String, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .strokeBorder(isOn ? Palette.focus : Palette.border, lineWidth: isOn ? 4 : 1.5)
                    .frame(width: 13, height: 13)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.foreground)
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(detail)
    }
}

/// The section bound to the launch's detail store, for the Settings window.
struct TranscriptSettingsHost: View {
    @Environment(ToolDetailStore.self) private var details: ToolDetailStore?

    var body: some View {
        if let details {
            TranscriptSettingsSection(settings: details.settings, isLoaded: details.settingsLoaded || details.source == nil,
                                      error: details.settingsError) { next in
                Task { await details.save(next) }
            }
            .task { await details.loadSettings() }
        }
    }
}
