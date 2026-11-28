import AppKit
import SwiftUI

// ATOMIC LEVEL: Page (new run).
// NewRunView is the single run-setup page. It fills the TaskSheet template:
//   header  Kicker + title
//   form    LabeledField + StaticField / TextField / TextEditor, CapabilityChip, ChoiceRow
//   aside   run preview card: KeyValueRow, HostAvailabilityRow, delegation note
//   footer  CapsuleButtonStyle actions
//
// Opened from a project, the form shows that project's recorded folder and sends the project's ID
// (NewRunProject). On a headless host's service the directory is typed, never picked on this Mac.
//
// What the form offers is decided by RunSetupCapabilities. The live app passes the local default,
// which is exactly what POST /v1/runs accepts: a directory, a task and an optional title, with one
// coordinator client on this Mac. Worker policy, model choice, remote hosts, disconnect behavior
// and the delegation card appear only when a capability set declares them. Today only the design
// fixture does, so those panels are never shown on a live page.

/// The recorded project a run is started in. The form then shows the project's folder and
/// offers no other: the folder is the project's, whatever run was open before.
struct NewRunProject: Equatable {
    /// The catalog ID. Nil for a project known only by the directory its runs name.
    let id: String?
    let name: String
    let path: String
}

struct NewRunDraft: Equatable {
    var title = ""
    var path = ""
    var task = ""
    /// The project the form was opened from. Nil lets the person choose a directory.
    var project: NewRunProject? = nil
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

    /// A harness a run can be started with, as the Harnesses mode reports it.
    struct RunHarness: Identifiable, Equatable {
        let id: String
        let name: String
        /// Installed and signed in (or it needs no sign-in).
        let isReady: Bool
        /// The word beside it: "Signed in", "Not signed in".
        let state: String
        /// The service's own reason a run can't start with it, when it gives one.
        var reason: String? = nil
        /// The harness has a sign-in command the app can open, and isn't signed in.
        var canSignIn = true
    }

    /// The harness the coordinator runs in. POST /v1/runs starts Claude Code.
    static let coordinatorHarness = "claude"

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
    /// The managed harnesses that are turned on. Nil where nothing reports them: the form then
    /// names the coordinator alone and holds no run back.
    var harnesses: [RunHarness]? = nil
    /// The headless host whose service is in use. The directory is then that host's own absolute
    /// path, typed: this Mac's folder picker would name a folder on the wrong machine.
    var typedDirectoryHost: String? = nil

    /// Why a run can't start with the coordinator's harness now. Nil when it can, or when nothing
    /// reports harnesses.
    var coordinatorBlock: String? {
        guard let harnesses else { return nil }
        guard let coordinator = harnesses.first(where: { $0.id == Self.coordinatorHarness }) else {
            return "Claude Code is turned off. Turn it on in Harnesses to start a run."
        }
        if coordinator.isReady { return nil }
        return coordinator.reason ?? "\(coordinator.name) is \(coordinator.state.lowercased()). Sign in to start a run."
    }

    /// True when several coordinators, models or hosts can be chosen, so values show a chevron.
    var offersChoices: Bool { coordinatorModel != nil }
    var hasWorkerPolicy: Bool { !allowedClients.isEmpty || allowedModels != nil || workerLimit != nil }
}

struct NewRunView: View {
    private enum Field: Hashable { case title, task, directory }

    let connection: CockpitModel.Connection
    let projectName: String?
    let capabilities: RunSetupCapabilities
    let create: @MainActor (_ path: String, _ task: String, _ title: String?, _ operationID: String) async throws -> Void
    /// Starts the run in a recorded project by its ID. Nil sends the project's directory instead.
    var createInProject: (@MainActor (_ projectID: String, _ task: String, _ title: String?,
                                      _ operationID: String) async throws -> Void)? = nil
    let cancel: () -> Void
    /// Opens a harness's own sign-in. Nil leaves the gate without a button.
    var signIn: ((String) -> Void)? = nil
    /// The project the form was opened from. Its folder is fixed.
    private let project: NewRunProject?

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
         cancel: @escaping () -> Void, signIn: ((String) -> Void)? = nil,
         createInProject: (@MainActor (_ projectID: String, _ task: String, _ title: String?,
                                       _ operationID: String) async throws -> Void)? = nil) {
        self.signIn = signIn
        self.connection = connection
        self.projectName = draft.project?.name ?? projectName
        self.capabilities = capabilities
        self.create = create
        self.createInProject = createInProject
        self.cancel = cancel
        project = draft.project
        _title = State(initialValue: draft.title)
        // A project's own folder, never the directory of whichever run was open.
        _path = State(initialValue: draft.project?.path ?? draft.path)
        _task = State(initialValue: draft.task)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTask: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isOnline: Bool { connection == .online }
    /// The directory as it is sent. On a headless host it is typed, so it is trimmed and must be
    /// absolute; nil until it is.
    private var runPath: String? {
        guard project == nil, capabilities.typedDirectoryHost != nil else { return path.isEmpty ? nil : path }
        return ProjectFolderPicker.typed(path)
    }
    private var canStart: Bool {
        runPath != nil && !trimmedTask.isEmpty && isOnline && !busy && capabilities.coordinatorBlock == nil
    }

    /// A path as the form shows it. A headless host's path is shown as it is: this Mac's home
    /// folder says nothing about it.
    private func shown(_ path: String) -> String {
        capabilities.typedDirectoryHost == nil ? PathDisplay.abbreviated(path) : path
    }

    private var directoryLabel: String { project == nil ? "Project directory" : "Project folder" }

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

    private var headerText: String {
        if capabilities.hasWorkerPolicy {
            return "Choose the coordinator, its workspace, and the limits for everyone it delegates to."
        }
        if let project { return "Describe the task for the coordinator. It runs in \(project.name)’s folder." }
        return "Choose the project directory and describe the task for the coordinator."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: projectName.map { "\($0) / Runs" } ?? "Runs")
            Text("Start a coordinator run").font(TypeRole.pageTitle).tracking(-1.1)
                .foregroundStyle(Palette.foreground).accessibilityAddTraits(.isHeader)
            Text(headerText)
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
                    LabeledField(label: directoryLabel) { directoryField }
                    LabeledField(label: "Coordinator host") {
                        StaticField(symbol: "desktopcomputer", value: capabilities.localHostName, showsChevron: true)
                    }
                }
            } else if let harnesses = capabilities.harnesses {
                // What the Harnesses mode reports: a harness that isn't signed in is off, with the
                // way to sign in beside it. The rows follow the live list while the form is open.
                LabeledField(label: "Harnesses") {
                    VStack(spacing: 7) {
                        ForEach(harnesses) { harness in
                            RunHarnessGateRow(harness: harness,
                                              role: harness.id == RunSetupCapabilities.coordinatorHarness ? "Coordinator" : "Workers",
                                              signIn: signIn.map { open in { open(harness.id) } })
                        }
                        if harnesses.isEmpty {
                            StaticField(symbol: "exclamationmark.triangle", value: "No harness is turned on. Turn one on in Harnesses.")
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    LabeledField(label: directoryLabel) { directoryField }
                    LabeledField(label: "Coordinator host") {
                        StaticField(symbol: "desktopcomputer", value: capabilities.localHostName)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    LabeledField(label: "Coordinator") { StaticField(symbol: "terminal", value: "Claude Code") }
                    LabeledField(label: "Coordinator host") {
                        StaticField(symbol: "desktopcomputer", value: capabilities.localHostName)
                    }
                }
                LabeledField(label: directoryLabel) { directoryField }
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

    /// The run's directory, in one of three forms.
    ///   A project's folder   shown, not chosen: the form was opened from that project.
    ///   A headless host      typed, as that host's own absolute path. No local picker.
    ///   This Mac             chosen with the folder picker, as before.
    @ViewBuilder private var directoryField: some View {
        if let project {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.inkSecondary)
                Text(shown(project.path))
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.foreground)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(project.path)
                Spacer(minLength: 8)
                Text(project.name).font(TypeRole.caption).foregroundStyle(.inkSecondary).lineLimit(1)
            }
            .fieldBox()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Project folder")
            .accessibilityValue("\(project.path), the folder of \(project.name)")
        } else if let host = capabilities.typedDirectoryHost {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.inkSecondary)
                TextField("Absolute path on \(host)", text: $path)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .focused($focus, equals: .directory)
                    .disabled(busy)
                    .accessibilityLabel("Project directory on \(host)")
            }
            .fieldBox(focused: focus == .directory)
            .help("The directory’s absolute path on \(host). This Mac’s folders are not on that host.")
        } else {
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
    }

    // MARK: Aside

    private var previewRows: [RunSetupCapabilities.PreviewRow] {
        if let rows = capabilities.previewRows { return rows }
        return [
            .init(key: "Project", value: project?.name ?? (path.isEmpty ? "Not chosen" : URL(filePath: path).lastPathComponent)),
            .init(key: "Directory", value: path.isEmpty ? "Not chosen" : shown(path), monospaced: true),
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
            } else if let block = capabilities.coordinatorBlock {
                Label(block, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.attention).lineLimit(2)
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
            .help(canStart ? "Start run (⌘↩)" : capabilities.coordinatorBlock ?? "Choose a directory and enter a task")
        }
    }

    // MARK: Intents

    private func start() {
        guard canStart, let runPath = runPath else { return }
        busy = true
        message = nil
        let runTask = task, runKey = key
        let runTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        // A recorded project is named by its ID, and the service uses the folder it recorded.
        let projectID = createInProject == nil ? nil : project?.id
        let remembersDirectory = project == nil && capabilities.typedDirectoryHost == nil
        Task {
            do {
                if let projectID, let createInProject {
                    try await createInProject(projectID, runTask, runTitle, runKey)
                } else {
                    try await create(runPath, runTask, runTitle, runKey)
                }
                // Remember real directories of this Mac only, so neither a sample path nor a
                // headless host's path becomes the next default.
                if remembersDirectory, FileManager.default.fileExists(atPath: runPath) {
                    UserDefaults.standard.set(runPath, forKey: "recentProject")
                }
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    /// This Mac's folder picker. It is never offered for a headless host's service.
    private func pickDirectory() {
        guard capabilities.typedDirectoryHost == nil else { return }
        if let chosen = ProjectFolderPicker.pick(prompt: "Use project", startingAt: path) { path = chosen }
        if capabilities.showsTaskEditor { focus = .task }
    }
}

/// One harness in the run form: its name, what it does in the run, and whether a run can use it
/// now. A harness that isn't ready is dimmed, says why in the attention role, and offers its own
/// sign-in. It follows the live harness list, so it turns back on as soon as the sign-in lands.
struct RunHarnessGateRow: View {
    let harness: RunSetupCapabilities.RunHarness
    let role: String
    var signIn: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 13)).foregroundStyle(.inkSecondary)
            Text(harness.name).font(TypeRole.body)
                .foregroundStyle(harness.isReady ? Palette.foreground : Palette.secondary).lineLimit(1)
            Text(role).font(TypeRole.caption).foregroundStyle(.inkSecondary).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Label(harness.isReady ? harness.state : harness.reason ?? harness.state,
                  systemImage: harness.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(harness.isReady ? Palette.working : Palette.attention)
                .lineLimit(1)
            if !harness.isReady, harness.canSignIn, let signIn {
                Button("Sign in", action: signIn)
                    .accessibilityLabel("Sign in to \(harness.name)")
                    .accessibilityIdentifier("run-harness-sign-in-\(harness.id)")
            }
        }
        .fieldBox()
        .help(harness.reason ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(harness.name), \(role.lowercased()), \(harness.reason ?? harness.state.lowercased())")
    }
}
