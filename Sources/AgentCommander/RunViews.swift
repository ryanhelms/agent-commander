import AppKit
import SwiftUI

// ATOMIC LEVEL: Page (new run).
// NewRunView is the single run-setup page. It fills the TaskSheet template:
//   header  Kicker + title
//   form    LabeledField + StaticField / TextField / TextEditor, CapabilityChip, ChoiceRow
//   aside   run preview card: KeyValueRow, HostAvailabilityRow, delegation note
//   footer  CapsuleButtonStyle actions
//
// What the form offers is decided by RunSetupCapabilities. The live app passes the local default,
// which is exactly what POST /v1/runs accepts: a directory, a task and an optional title, with one
// coordinator client on this Mac. Worker policy, model choice, remote hosts, disconnect behavior
// and the delegation card appear only when a capability set declares them. Today only the design
// fixture does, so those panels are never shown on a live page.

struct NewRunDraft: Equatable {
    var title = ""
    var path = ""
    var task = ""
}

struct RunSetupCapabilities {
    struct Host: Identifiable {
        let id: String
        let symbol: String
        let name: String
        let detail: String
    }

    struct DisconnectChoice: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isSelected: Bool
    }

    struct PreviewRow: Identifiable {
        let key: String
        let value: String
        var monospaced = false
        var id: String { key }
    }

    struct Delegation {
        let title: String
        let detail: String
    }

    var localHostName = "This Mac"
    var coordinatorModel: String? = nil
    var allowedClients: [String] = []
    var allowedModels: String? = nil
    var workerLimit: String? = nil
    var disconnectChoices: [DisconnectChoice] = []
    var remoteHosts: [Host] = []
    var previewRows: [PreviewRow]? = nil
    var delegation: Delegation? = nil
    var limitsNote: String? = nil
    var footerNote: String? = nil
    var showsTaskEditor = true

    /// True when several coordinators, models or hosts can be chosen, so values show a chevron.
    var offersChoices: Bool { coordinatorModel != nil }
    var hasWorkerPolicy: Bool { !allowedClients.isEmpty || allowedModels != nil || workerLimit != nil }
}

struct NewRunView: View {
    private enum Field: Hashable { case title, task }

    let connection: CockpitModel.Connection
    let projectName: String?
    let capabilities: RunSetupCapabilities
    let create: @MainActor (_ path: String, _ task: String, _ title: String?, _ operationID: String) async throws -> Void
    let cancel: () -> Void

    @State private var title: String
    @State private var path: String
    @State private var task: String
    @State private var key = UUID().uuidString
    @State private var busy = false
    @State private var message: String?
    @FocusState private var focus: Field?

    init(connection: CockpitModel.Connection, draft: NewRunDraft, projectName: String?,
         capabilities: RunSetupCapabilities = RunSetupCapabilities(),
         create: @escaping @MainActor (_ path: String, _ task: String, _ title: String?, _ operationID: String) async throws -> Void,
         cancel: @escaping () -> Void) {
        self.connection = connection
        self.projectName = projectName
        self.capabilities = capabilities
        self.create = create
        self.cancel = cancel
        _title = State(initialValue: draft.title)
        _path = State(initialValue: draft.path)
        _task = State(initialValue: draft.task)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTask: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isOnline: Bool { connection == .online }
    private var canStart: Bool { !path.isEmpty && !trimmedTask.isEmpty && isOnline && !busy }

    private var previewTitle: String {
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let line = trimmedTask.split(whereSeparator: \.isNewline).first { return String(line) }
        return "Untitled run"
    }

    var body: some View {
        TaskSheet {
            header
        } form: {
            form
        } aside: {
            aside
        } footer: {
            footer
        }
        .onChange(of: title) { _, _ in key = UUID().uuidString }
        .onChange(of: task) { _, _ in key = UUID().uuidString }
        .onChange(of: path) { _, _ in key = UUID().uuidString }
        .onAppear { if capabilities.showsTaskEditor { focus = .task } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start a coordinator run")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: projectName.map { "\($0) / Runs" } ?? "Runs")
            Text("Start a coordinator run").font(TypeRole.pageTitle).tracking(-1.1)
                .foregroundStyle(Palette.foreground).accessibilityAddTraits(.isHeader)
            Text(capabilities.hasWorkerPolicy
                 ? "Choose the coordinator, its workspace, and the limits for everyone it delegates to."
                 : "Choose the project directory and describe the task for the coordinator.")
                .font(TypeRole.body).foregroundStyle(.inkSecondary)
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Run setup")
            LabeledField(label: "Run name") {
                TextField("Optional. Defaults to the first line of the task.", text: $title)
                    .textFieldStyle(.plain).font(TypeRole.body)
                    .focused($focus, equals: .title)
                    .disabled(busy)
                    .fieldBox(focused: focus == .title)
                    .accessibilityLabel("Run name, optional")
            }
            if let model = capabilities.coordinatorModel {
                HStack(alignment: .top, spacing: 16) {
                    LabeledField(label: "Coordinator") {
                        StaticField(symbol: "terminal", value: "Claude Code", showsChevron: true)
                    }
                    LabeledField(label: "Coordinator model") {
                        StaticField(symbol: "slider.horizontal.3", value: model, showsChevron: true)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    LabeledField(label: "Project directory") { directoryField }
                    LabeledField(label: "Coordinator host") {
                        StaticField(symbol: "desktopcomputer", value: capabilities.localHostName, showsChevron: true)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    LabeledField(label: "Coordinator") { StaticField(symbol: "terminal", value: "Claude Code") }
                    LabeledField(label: "Coordinator host") {
                        StaticField(symbol: "desktopcomputer", value: capabilities.localHostName)
                    }
                }
                LabeledField(label: "Project directory") { directoryField }
            }
            if capabilities.hasWorkerPolicy {
                Hairline().padding(.vertical, 4)
                sectionTitle("Worker policy")
                if !capabilities.allowedClients.isEmpty {
                    LabeledField(label: "Allowed clients") {
                        HStack(spacing: 8) {
                            ForEach(capabilities.allowedClients, id: \.self) { CapabilityChip(text: $0) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    if let models = capabilities.allowedModels {
                        LabeledField(label: "Allowed models") {
                            StaticField(symbol: "slider.horizontal.3", value: models, showsChevron: true)
                        }
                    }
                    if let limit = capabilities.workerLimit {
                        LabeledField(label: "Worker limit") { StaticField(value: limit) }
                    }
                }
            }
            if !capabilities.disconnectChoices.isEmpty {
                Hairline().padding(.vertical, 4)
                sectionTitle("When a host disconnects")
                VStack(spacing: 7) {
                    ForEach(capabilities.disconnectChoices) { choice in
                        ChoiceRow(title: choice.title, detail: choice.detail, isSelected: choice.isSelected)
                    }
                }
            }
            if capabilities.showsTaskEditor {
                Hairline().padding(.vertical, 4)
                sectionTitle("Coordinator task")
                LabeledField(label: "What should the coordinator plan and delegate?") {
                    let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    TextEditor(text: $task)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Palette.foreground)
                        .padding(8)
                        .frame(height: 150)
                        .background(Palette.field, in: shape)
                        .overlay { shape.strokeBorder(focus == .task ? Palette.focus : Palette.fieldBorder, lineWidth: focus == .task ? 1.5 : 1) }
                        .focused($focus, equals: .task)
                        .disabled(busy)
                        .accessibilityLabel("Coordinator task")
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(TypeRole.section).tracking(-0.4).foregroundStyle(Palette.foreground)
            .accessibilityAddTraits(.isHeader)
    }

    private var directoryField: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.inkSecondary)
            Text(path.isEmpty ? "Choose a directory" : PathDisplay.abbreviated(path))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(path.isEmpty ? Palette.secondary : Palette.foreground)
                .lineLimit(1).truncationMode(.middle)
                .help(path)
            Spacer(minLength: 8)
            Button("Choose…", action: pickDirectory).disabled(busy)
        }
        .fieldBox()
    }

    // MARK: Aside

    private var previewRows: [RunSetupCapabilities.PreviewRow] {
        if let rows = capabilities.previewRows { return rows }
        return [
            .init(key: "Project", value: path.isEmpty ? "Not chosen" : URL(filePath: path).lastPathComponent),
            .init(key: "Directory", value: path.isEmpty ? "Not chosen" : PathDisplay.abbreviated(path), monospaced: true),
            .init(key: "Coordinator", value: "Claude Code"),
            .init(key: "Host", value: capabilities.localHostName)
        ]
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15)).foregroundStyle(.inkSecondary)
                    .frame(width: 37, height: 37)
                    .background(Palette.chrome, in: RoundedRectangle(cornerRadius: Radius.avatar))
                    .overlay { RoundedRectangle(cornerRadius: Radius.avatar).strokeBorder(.inkHairline) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Kicker(text: "Run preview")
                    Text(previewTitle).font(TypeRole.section).tracking(-0.4)
                        .foregroundStyle(Palette.foreground).lineLimit(2)
                }
            }
            // Section rhythm from the concept card: 33 pt row pitch, 59 pt host pitch, and wider
            // gaps around each divider.
            Hairline().padding(.top, 20).padding(.bottom, 22)
            VStack(spacing: 17) {
                ForEach(previewRows) { row in
                    KeyValueRow(key: row.key, value: row.value, monospaced: row.monospaced)
                }
            }
            Hairline().padding(.top, 26).padding(.bottom, 25)
            Kicker(text: "Host availability")
            VStack(spacing: 21) {
                localHostRow
                ForEach(capabilities.remoteHosts) { host in
                    HostAvailabilityRow(symbol: host.symbol, name: host.name, detail: host.detail,
                                        status: "Online", tone: .working)
                }
            }
            .padding(.top, 22)
            if let delegation = capabilities.delegation {
                let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                Hairline().padding(.top, 24).padding(.bottom, 25)
                Kicker(text: "Delegation")
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.working).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(delegation.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text(delegation.detail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15).padding(.vertical, 16)
                .background(Palette.well, in: shape)
                .overlay { shape.strokeBorder(.inkHairline) }
                .padding(.top, 14)
                .accessibilityElement(children: .combine)
            }
            if let note = capabilities.limitsNote {
                Text(note).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
            }
        }
        .padding(.horizontal, 25).padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run preview")
    }

    private var localHostRow: some View {
        var status = "Offline"
        var tone = Tone.failure
        var symbol = "exclamationmark.circle.fill"
        switch connection {
        case .online:
            status = "Online"; tone = .working; symbol = "checkmark.circle.fill"
        case .connecting:
            status = "Connecting"; tone = .attention; symbol = "clock"
        case .offline:
            break
        }
        return HostAvailabilityRow(symbol: "desktopcomputer", name: capabilities.localHostName,
                                   detail: "Local service · coordinator",
                                   status: status, tone: tone, statusSymbol: symbol)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.failure).lineLimit(2).textSelection(.enabled)
            } else if !isOnline {
                Label("The local service is offline. Reconnect to start a run.", systemImage: "bolt.slash")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.attention)
            } else if let note = capabilities.footerNote {
                Label(note, systemImage: "lock").font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 12)
            Button("Cancel", action: cancel)
                .buttonStyle(CapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(busy)
            Button(action: start) {
                Label(busy ? "Starting…" : "Start run", systemImage: "play")
            }
            .buttonStyle(CapsuleButtonStyle(prominent: true))
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canStart)
            .help(canStart ? "Start run (⌘↩)" : "Choose a directory and enter a task")
        }
    }

    // MARK: Intents

    private func start() {
        guard canStart else { return }
        busy = true
        message = nil
        let runPath = path, runTask = task, runKey = key
        let runTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        Task {
            do {
                try await create(runPath, runTask, runTitle, runKey)
                // Remember real directories only, so a sample path never becomes the next default.
                if FileManager.default.fileExists(atPath: runPath) {
                    UserDefaults.standard.set(runPath, forKey: "recentProject")
                }
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use project"
        if !path.isEmpty { panel.directoryURL = URL(filePath: path, directoryHint: .isDirectory) }
        if panel.runModal() == .OK, let url = panel.url { path = url.standardizedFileURL.path }
        if capabilities.showsTaskEditor { focus = .task }
    }
}
