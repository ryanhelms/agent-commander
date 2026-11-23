import AppKit
import SwiftUI

// ATOMIC LEVEL: Pages (setup, recovery and settings).
//
//   FirstRunPage         WorkspacePage: project + host selection | preflight + discovered sessions, step flow
//   HostsPage            WorkspacePage: CollectionInspector(host list | host detail + capability matrix)
//   ClientsPage          WorkspacePage: client tiles, launch-profile form | advertised capabilities
//   AdoptionPage         WorkspacePage: CollectionInspector(discovered panes | preservation checks)
//   RecoveryPage         TaskSheet: connection timeline + affected workers | uncertain delivery
//   OperationDetailPage  WorkspacePage: operation facts | operation history
//   PreferencesPage      WorkspacePage: PresentationChoiceCard set + recording settings
//
// Pages take values and keep presentation state only. Selecting, checking, verifying and adopting
// change that local state, so each view can be exercised before it is connected to the service.

// MARK: - Shared organisms

/// Small picture of how one attention presentation arranges the window.
struct PresentationThumbnail: View {
    let mode: AttentionPresentation

    private let quiet = Color(hex: 0x2A2B33)
    private let bright = Color(hex: 0x3A3C46)
    private let ink = Color(hex: 0xA9ADBA)

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(quiet).frame(width: 26)
            content
        }
        .padding(5)
        .frame(width: 126, height: 76)
        .background(Color(hex: 0x1B1C22), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)) }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .pip:
            ZStack(alignment: .bottomTrailing) {
                grid(columns: 2)
                panel(lines: 2).frame(width: 46, height: 30).offset(x: 2, y: 2)
            }
        case .queue:
            panel(lines: 3, filled: true)
        case .drawer:
            HStack(spacing: 4) {
                grid(columns: 1)
                panel(lines: 3).frame(width: 40)
            }
        case .switchRun:
            panel(lines: 2)
        }
    }

    private func grid(columns: Int) -> some View {
        VStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(quiet) }
                }
            }
        }
    }

    private func panel(lines: Int, filled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<lines, id: \.self) { index in
                Capsule().fill(ink).frame(width: filled ? nil : (index == 0 ? 26 : 18), height: filled ? 4 : 2)
            }
            if !filled { Spacer(minLength: 0) }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(bright, in: RoundedRectangle(cornerRadius: 3))
        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.55)) }
    }
}

/// One attention presentation as a selectable card.
struct PresentationChoiceCard: View {
    let mode: AttentionPresentation
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 0) {
                PresentationThumbnail(mode: mode)
                    .frame(maxWidth: .infinity, minHeight: 118)
                    .background(Palette.well.opacity(0.75), in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.inkHairline) }
                HStack(spacing: 9) {
                    ZStack {
                        Circle().strokeBorder(isSelected ? Palette.focus : Color(hex: 0x5B6070), lineWidth: 1)
                        if isSelected { Circle().fill(Palette.focus).padding(3) }
                    }
                    .frame(width: 15, height: 15)
                    Text(mode.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isSelected {
                        Text("Selected").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.working)
                    }
                }
                .padding(.top, 19)
                Text(mode.detail).font(.system(size: 13)).lineSpacing(4).foregroundStyle(.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                    .padding(.top, 12)
            }
            .padding(16)
            .selectionCard(isSelected, radius: 11)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title). \(mode.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A moment in a connection's history.
struct TimelineEvent: Identifiable, Equatable {
    let id: Int
    let time: String
    let title: String
    let detail: String
    let tone: Tone
}

struct ConnectionTimeline: View {
    let events: [TimelineEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle().fill(event.tone.color).frame(width: 8, height: 8).padding(.top, 5)
                        if event.id != events.last?.id {
                            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 8)
                    Text(event.time).font(TypeRole.monoID).foregroundStyle(.inkSecondary).frame(width: 64, alignment: .leading)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text(event.detail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 16)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Connect a workspace

struct SetupHost: Identifiable, Equatable {
    let id: String
    let detail: String
    let symbol: String
    let isRemote: Bool

    var name: String { id }
}

struct DiscoveredSession: Identifiable, Equatable {
    let id: String
    let client: AgentClient
    let place: String
    let state: TaskState
}

struct FirstRunPage: View {
    let hosts: [SetupHost]
    let sessions: [DiscoveredSession]
    let steps: [String]
    let proceed: () -> Void

    @State private var projectName: String
    @State private var projectKind: String
    @State private var projectPath: String
    @State private var selected: Set<String>

    init(projectName: String, projectKind: String, projectPath: String, hosts: [SetupHost], selected: Set<String>,
         sessions: [DiscoveredSession], steps: [String], proceed: @escaping () -> Void) {
        self.hosts = hosts
        self.sessions = sessions
        self.steps = steps
        self.proceed = proceed
        _projectName = State(initialValue: projectName)
        _projectKind = State(initialValue: projectKind)
        _projectPath = State(initialValue: projectPath)
        _selected = State(initialValue: selected)
    }

    /// Picks a directory with the system panel. Only this page's draft changes.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        projectName = url.lastPathComponent
        projectPath = PathDisplay.abbreviated(path)
        projectKind = FileManager.default.fileExists(atPath: path + "/.git") ? "Git repository" : "Directory without Git"
    }

    private var checks: [String] {
        ["API online", "tmux available", "Git origin verified"]
            + hosts.filter { $0.isRemote && selected.contains($0.id) }.map { "\($0.name) reachable" }
    }

    private var visibleSessions: [DiscoveredSession] {
        sessions.filter { session in selected.contains { session.place.hasPrefix($0) } }
    }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "Workspace setup / Discovery", title: "Connect your workspace",
                       subtitle: "Choose a project and hosts, then review the agents already running there.") {
                EmptyView()
            }
        } content: {
            HStack(alignment: .top, spacing: 20) {
                projectCard
                discoveryCard.frame(width: 430)
            }
            flow
        }
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Project directory").font(TypeRole.section).tracking(-0.4).foregroundStyle(Palette.foreground)
                HStack(spacing: 14) {
                    IconTile(symbol: "folder", tone: .working, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(projectName).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text(projectKind).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                    }
                    Spacer(minLength: 12)
                    Button(action: chooseFolder) { Label("Choose folder", systemImage: "folder") }
                        .buttonStyle(CapsuleButtonStyle(height: 33))
                }
                HStack(spacing: 10) {
                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.inkSecondary)
                    Text(projectPath).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.foreground)
                        .textSelection(.enabled)
                }
                .fieldBox()
            }
            .padding(24)
            Hairline()
            VStack(alignment: .leading, spacing: 16) {
                Text("Hosts to connect").font(TypeRole.section).tracking(-0.4).foregroundStyle(Palette.foreground)
                ForEach(hosts) { host in
                    HStack(spacing: 13) {
                        CheckToggle(label: "Connect \(host.name)", isOn: inclusion(of: host))
                        Image(systemName: host.symbol).font(.system(size: 15)).foregroundStyle(.inkSecondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                            Text(host.detail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Label("Remote aliases are read from ~/.ssh/config.", systemImage: "book")
                    .font(.system(size: 12)).foregroundStyle(.inkSecondary).padding(.top, 2)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Kicker(text: "Preflight")
                Text("Connection checks").font(TypeRole.section).tracking(-0.4).foregroundStyle(Palette.foreground)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 11) {
                    ForEach(checks, id: \.self) { check in
                        Label(check, systemImage: "checkmark").font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xCFE5D8))
                    }
                }
                .padding(.top, 3)
            }
            .padding(24)
            Hairline()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Kicker(text: "Existing sessions")
                    Spacer(minLength: 8)
                    MetaText(text: "\(visibleSessions.count)", monospaced: true)
                }
                if visibleSessions.isEmpty {
                    Text("No agent session found on the selected hosts.").font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                }
                ForEach(visibleSessions) { session in
                    HStack(spacing: 12) {
                        AgentAvatar(client: session.client, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.client.displayName).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.foreground)
                            Text(session.place).font(.system(size: 12)).foregroundStyle(.inkSecondary)
                        }
                        Spacer(minLength: 8)
                        StatusLabel(session.state, size: 12)
                    }
                    .accessibilityElement(children: .combine)
                }
                Label("Discovered panes are currently view-only.", systemImage: "eye")
                    .font(.system(size: 12)).foregroundStyle(.inkSecondary)
            }
            .padding(24)
        }
        .panelSurface()
    }

    private var flow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Kicker(text: "Workspace setup")
                Spacer(minLength: 8)
                MetaText(text: "Step 1 of \(steps.count)")
            }
            HStack(spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.inkSecondary)
                    }
                    HStack(spacing: 9) {
                        Text("\(index + 1)").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(index == 0 ? Palette.onAccent : Palette.secondary)
                            .frame(width: 22, height: 22)
                            .background(index == 0 ? Palette.focus : Palette.chrome, in: Circle())
                        Text(step).font(.system(size: 13, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(index == 0 ? Palette.foreground : Palette.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(index == 0 ? .isSelected : [])
                }
                Spacer(minLength: 12)
                Button(action: proceed) { Label("Continue to clients", systemImage: "arrow.right") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(selected.isEmpty)
                    .help(selected.isEmpty ? "Select at least one host" : "Continue to client setup")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .panelSurface()
    }

    private func inclusion(of host: SetupHost) -> Binding<Bool> {
        Binding(get: { selected.contains(host.id) },
                set: { isOn in
                    if isOn { selected.insert(host.id) } else { selected.remove(host.id) }
                })
    }
}

// MARK: - Hosts and capabilities

struct EnrolledHost: Identifiable, Equatable {
    let id: String
    let kind: String
    let typeLabel: String
    let symbol: String
    let isConnected: Bool
    /// "Persistent helper", "SSH-only" or "Local service".
    let mode: String
    let checkout: String
    let activeRun: String?
    let lastSeen: String?

    var name: String { id }
}

struct CapabilityComparison: Identifiable, Equatable {
    let id: String
    let persistentHelper: String
    let sshOnly: String
}

struct HostsPage: View {
    let subtitle: String
    let hosts: [EnrolledHost]
    let capabilities: [CapabilityComparison]
    let configPath: String
    let policyTitle: String
    let policyDetail: String
    let policyStatus: String
    let enroll: () -> Void
    let recover: (EnrolledHost) -> Void

    @State private var selection: String
    @State private var checking = false
    @State private var lastCheck = "just now"

    init(subtitle: String, hosts: [EnrolledHost], selection: String, capabilities: [CapabilityComparison],
         configPath: String, policyTitle: String, policyDetail: String, policyStatus: String,
         enroll: @escaping () -> Void, recover: @escaping (EnrolledHost) -> Void) {
        self.subtitle = subtitle
        self.hosts = hosts
        self.capabilities = capabilities
        self.configPath = configPath
        self.policyTitle = policyTitle
        self.policyDetail = policyDetail
        self.policyStatus = policyStatus
        self.enroll = enroll
        self.recover = recover
        _selection = State(initialValue: selection)
    }

    private var host: EnrolledHost? { hosts.first { $0.id == selection } ?? hosts.first }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "Workspace / Infrastructure", title: "Hosts", subtitle: subtitle) {
                Button(action: enroll) { Label("Enroll SSH host", systemImage: "plus") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
            }
        } content: {
            CollectionInspector(collectionWidth: 382) {
                hostList
            } inspector: {
                if let host { detail(host) }
            }
            HStack(spacing: 15) {
                IconTile(symbol: "checkmark.shield", tone: .focus)
                VStack(alignment: .leading, spacing: 5) {
                    Text(policyTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                    Text(policyDetail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                }
                Spacer(minLength: 12)
                StatusLabel(text: policyStatus, tone: .focus, symbol: "pause.circle", size: 12)
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .panelSurface()
            .accessibilityElement(children: .combine)
        }
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Kicker(text: "Enrolled hosts")
                Spacer(minLength: 8)
                MetaText(text: "\(hosts.count)", monospaced: true)
            }
            .padding(.horizontal, 15).padding(.top, 8).padding(.bottom, 12)
            ForEach(hosts) { item in
                let isSelected = item.id == host?.id
                Button {
                    selection = item.id
                    lastCheck = "just now"
                } label: {
                    HStack(spacing: 13) {
                        IconTile(symbol: item.symbol, tone: isSelected && item.isConnected ? .working : .neutral, size: 31)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                            Text(item.kind).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                        }
                        Spacer(minLength: 8)
                        StatusLabel(text: item.isConnected ? "Connected" : "Disconnected",
                                    tone: item.isConnected ? .working : .attention,
                                    symbol: item.isConnected ? "checkmark.circle.fill" : "bolt.slash", size: 11.5)
                    }
                    .padding(.horizontal, 15)
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                    .background {
                        if isSelected { Color.clear.selectionCard(true) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name), \(item.kind), \(item.isConnected ? "connected" : "disconnected")")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Hairline().padding(.horizontal, 14).padding(.top, 14)
            HStack(spacing: 12) {
                Image(systemName: "book").font(.system(size: 13)).foregroundStyle(.inkSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SSH configuration").font(.system(size: 13)).foregroundStyle(Color(hex: 0xD3D6E0))
                    Text(configPath).font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                }
            }
            .padding(.horizontal, 15).padding(.top, 10).padding(.bottom, 6)
        }
        .padding(10)
        .panelSurface()
    }

    private func detail(_ host: EnrolledHost) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                IconTile(symbol: host.symbol, tone: host.isConnected ? .working : .attention, size: 46)
                VStack(alignment: .leading, spacing: 6) {
                    Kicker(text: host.typeLabel)
                    Text(host.name).font(.system(size: 30, weight: .semibold)).tracking(-0.9)
                        .foregroundStyle(Palette.foreground).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 12)
                StatusLabel(text: host.isConnected ? "Connected" : "Disconnected",
                            tone: host.isConnected ? .working : .attention,
                            symbol: host.isConnected ? "checkmark.circle.fill" : "bolt.slash", size: 12)
            }
            .padding(.horizontal, 26).padding(.top, 24)
            HStack(alignment: .top, spacing: 16) {
                FactColumn(label: "Connection mode", value: host.mode)
                Hairline(vertical: true).frame(height: 42)
                FactColumn(label: "Project checkout", value: host.checkout, monospaced: true)
                Hairline(vertical: true).frame(height: 42)
                FactColumn(label: "Active run", value: host.activeRun ?? "None")
            }
            .padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 24)
            Hairline()
            VStack(alignment: .leading, spacing: 16) {
                Text("Connection capabilities").font(.system(size: 22, weight: .semibold)).tracking(-0.6)
                    .foregroundStyle(Palette.foreground).accessibilityAddTraits(.isHeader)
                DataTable(headers: ["During an SSH outage", "Persistent helper", "SSH-only"], weights: [36, 33, 31],
                          rows: capabilities, carded: false, rowHeight: 51) { row, column in
                    switch column {
                    case 0:
                        Text(row.id).font(.system(size: 14)).foregroundStyle(Palette.foreground)
                    case 1:
                        Text(row.persistentHelper).font(.system(size: 14))
                            .foregroundStyle(host.mode == "Persistent helper" ? Palette.working : Palette.secondary)
                    default:
                        Text(row.sshOnly).font(.system(size: 14))
                            .foregroundStyle(host.mode == "SSH-only" ? Palette.working : Palette.secondary)
                    }
                }
                if !host.isConnected {
                    Callout(symbol: "bolt.slash", title: "\(host.name) is disconnected",
                            detail: "Last output \(host.lastSeen ?? "unknown"). Existing tmux work can continue; decisions are reviewed on reconnect.",
                            tone: .attention)
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 24)
            Hairline()
            HStack(spacing: 10) {
                if checking { ProgressView().controlSize(.small) } else {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 12)).foregroundStyle(.inkSecondary)
                }
                Text(checking ? "Checking connection…" : "Last connection check \(lastCheck)")
                    .font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                Spacer(minLength: 12)
                if !host.isConnected {
                    Button { recover(host) } label: { Label("Review recovery", systemImage: "arrow.right") }
                        .buttonStyle(CapsuleButtonStyle())
                }
                Button(action: check) { Label("Check connection", systemImage: "arrow.clockwise") }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(checking)
            }
            .padding(.horizontal, 26)
            .frame(minHeight: 66)
            .background(Palette.footer.opacity(0.6))
        }
        .panelSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Host \(host.name)")
    }

    private func check() {
        checking = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            checking = false
            lastCheck = "a moment ago"
        }
    }
}

// MARK: - Clients and MCP

struct ClientCapability: Identifiable, Equatable {
    let id: String
    let detail: String
}

struct ClientProfile: Identifiable, Equatable {
    let id: String
    let kind: String
    let symbol: String
    let tone: Tone
    /// A launch profile's executable and arguments can be edited; a discovered client's cannot.
    let isLaunchProfile: Bool
    var name: String
    var executable: String
    var arguments: String
    let mcpCommand: String
    let connectionTest: String
    let capabilities: [ClientCapability]
    let delegationMode: String
    let delegationDetail: String
    let hint: String
}

struct ClientsPage: View {
    @State private var profiles: [ClientProfile]
    @State private var selection: String
    @State private var copied = false

    init(profiles: [ClientProfile], selection: String) {
        _profiles = State(initialValue: profiles)
        _selection = State(initialValue: selection)
    }

    /// Adds an empty launch profile to this page's draft list, modelled on the last launch profile.
    private func addProfile() {
        guard let template = profiles.last(where: \.isLaunchProfile) ?? profiles.last else { return }
        let id = "profile-\(profiles.count + 1)"
        profiles.append(ClientProfile(
            id: id, kind: "Reusable launch profile", symbol: "command", tone: .working, isLaunchProfile: true,
            name: "New profile", executable: "", arguments: "",
            mcpCommand: template.mcpCommand, connectionTest: "Not tested yet",
            capabilities: template.capabilities, delegationMode: template.delegationMode,
            delegationDetail: template.delegationDetail, hint: template.hint))
        selection = id
    }

    private var index: Int? { profiles.firstIndex { $0.id == selection } ?? (profiles.isEmpty ? nil : 0) }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "Workspace / Integrations", title: "Clients & MCP",
                       subtitle: "Configure launch profiles and the tools available to managed agents.") {
                Button(action: addProfile) { Label("Add launch profile", systemImage: "plus") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
            }
        } content: {
            HStack(spacing: 14) {
                ForEach(profiles) { profile in
                    let isSelected = profile.id == selection
                    Button {
                        selection = profile.id
                        copied = false
                    } label: {
                        HStack(spacing: 14) {
                            IconTile(symbol: profile.symbol, tone: profile.tone, size: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                                Text(profile.kind).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.inkSecondary)
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                        .selectionCard(isSelected, radius: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(profile.name), \(profile.kind)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            if let index {
                HStack(alignment: .top, spacing: 20) {
                    profileCard(index)
                    capabilityCard(profiles[index])
                }
            }
        }
    }

    private func profileCard(_ index: Int) -> some View {
        let profile = profiles[index]
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Kicker(text: profile.isLaunchProfile ? "Launch profile" : "Discovered client")
                HStack {
                    Text(profile.name).font(TypeRole.focusTitle).tracking(-0.5).foregroundStyle(Palette.foreground)
                    Spacer(minLength: 8)
                    StatusLabel(text: "Enabled", tone: .working, symbol: "checkmark.circle.fill", size: 12)
                }
                if profile.isLaunchProfile {
                    LabeledField(label: "Profile name") { editor("Profile name", symbol: "command", text: $profiles[index].name) }
                    LabeledField(label: "Executable") { editor("Executable", symbol: "terminal", text: $profiles[index].executable) }
                    LabeledField(label: "Launch arguments") {
                        editor("Launch arguments", symbol: "chevron.left.forwardslash.chevron.right",
                               text: $profiles[index].arguments)
                    }
                } else {
                    LabeledField(label: "Executable") { StaticField(symbol: "terminal", value: profile.executable) }
                    LabeledField(label: "Launch arguments") {
                        StaticField(symbol: "chevron.left.forwardslash.chevron.right", value: profile.arguments)
                    }
                    Text("Commander found this client on its own. Add a launch profile to start it with different arguments.")
                        .font(.system(size: 12.5)).foregroundStyle(.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            Hairline()
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Commander MCP").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                    Spacer(minLength: 8)
                    StatusLabel(text: "Connected", tone: .working, symbol: "checkmark.circle.fill", size: 12)
                }
                Text("Add this command as a stdio server in your client’s MCP settings.")
                    .font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                HStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(.inkSecondary)
                    Text(profile.mcpCommand).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.foreground)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(profile.mcpCommand, forType: .string)
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy config", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(CapsuleButtonStyle(height: 29))
                }
                .fieldBox(height: 46)
                KeyValueRow(key: "Connection test", value: profile.connectionTest)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }

    private func editor(_ label: String, symbol: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.inkSecondary)
            TextField(label, text: text).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .accessibilityLabel(label)
        }
        .fieldBox()
    }

    private func capabilityCard(_ profile: ClientProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                Kicker(text: "Advertised capabilities")
                Text("Delegation & control").font(TypeRole.focusTitle).tracking(-0.5).foregroundStyle(Palette.foreground)
                ForEach(profile.capabilities) { capability in
                    EvidenceRow(title: capability.id, detail: capability.detail)
                }
            }
            .padding(24)
            Hairline()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Managed delegation").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                    Spacer(minLength: 8)
                    StatusLabel(text: profile.delegationMode, tone: .focus, symbol: "person.2", size: 12)
                }
                Text(profile.delegationDetail).font(.system(size: 13)).lineSpacing(4).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(profile.hint, systemImage: "bubble.left").font(.system(size: 12)).foregroundStyle(.inkSecondary)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

// MARK: - Adopt an existing session

struct PreservationCheck: Identifiable, Equatable {
    let id: String
    let detail: String
    /// What the check reports before the identity is verified in the live pane.
    var pendingDetail: String? = nil
}

struct DiscoveredPane: Identifiable, Equatable {
    enum Identity: Equatable { case verified, needsVerification, consoleOnly }

    let id: String
    let name: String
    /// Typed provider reported by discovery. Nil for plain shells and unidentified sessions; never
    /// derived from `name`.
    var provider: AgentClient? = nil
    let place: String
    let identity: Identity
    var note: String? = nil
    let pane: String
    let conversation: String?
    let hostDirectory: String
    let taskState: String
    let joinMethod: String
    let checks: [PreservationCheck]
    var warningTitle: String? = nil
    var warningDetail: String? = nil
}

struct AdoptionPage: View {
    let panes: [DiscoveredPane]
    let runLabel: String
    let runID: String

    @State private var selection: String
    @State private var verified = Set<String>()
    @State private var adopted = Set<String>()
    @State private var refreshing = false

    init(panes: [DiscoveredPane], selection: String, runLabel: String, runID: String) {
        self.panes = panes
        self.runLabel = runLabel
        self.runID = runID
        _selection = State(initialValue: selection)
    }

    private var pane: DiscoveredPane? { panes.first { $0.id == selection } ?? panes.first }

    private func identity(of pane: DiscoveredPane) -> DiscoveredPane.Identity {
        pane.identity == .needsVerification && verified.contains(pane.id) ? .verified : pane.identity
    }

    private func label(for identity: DiscoveredPane.Identity) -> (String, Tone, String) {
        switch identity {
        case .verified: return ("Verified", Tone.working, "checkmark.circle.fill")
        case .needsVerification: return ("Verify identity", Tone.attention, "questionmark.circle.fill")
        case .consoleOnly: return ("Console only", Tone.neutral, "terminal")
        }
    }

    private var unverified: DiscoveredPane? { panes.first { identity(of: $0) == .needsVerification } }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "Workspace / Discovery", title: "Adopt a session",
                       subtitle: "Link an existing tmux pane to its live conversation.") {
                Button(action: refresh) {
                    Label(refreshing ? "Refreshing…" : "Refresh discovery", systemImage: "arrow.clockwise")
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(refreshing)
            }
        } content: {
            CollectionInspector(collectionWidth: 430) {
                paneList
            } inspector: {
                if let pane { detail(pane) }
            }
            if let pending = unverified, let title = pending.warningTitle {
                HStack(spacing: 15) {
                    IconTile(symbol: "exclamationmark.triangle", tone: .attention)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text(pending.warningDetail ?? "").font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button { selection = pending.id } label: { Label("View \(pending.name) pane", systemImage: "eye") }
                        .buttonStyle(CapsuleButtonStyle())
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                .panelSurface(edge: Palette.attentionSoftEdge)
            }
        }
    }

    private var paneList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Kicker(text: "Discovered panes")
                Spacer(minLength: 8)
                MetaText(text: "\(panes.count)", monospaced: true)
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 6)
            ForEach(panes) { item in
                let isSelected = item.id == pane?.id
                let state = label(for: identity(of: item))
                Button { selection = item.id } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if let provider = item.provider {
                                AgentAvatar(client: provider, size: 31)
                            } else {
                                IconTile(symbol: "terminal", tone: state.1, size: 31)
                            }
                            Spacer(minLength: 8)
                            StatusLabel(text: adopted.contains(item.id) ? "Adopted" : state.0, tone: state.1,
                                        symbol: state.2, size: 11.5)
                        }
                        Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text(item.place).font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                        if let note = item.note {
                            Text(note).font(.system(size: 12)).foregroundStyle(.inkSecondary)
                        }
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .selectionCard(isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name), \(item.place), \(state.0)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(14)
        .panelSurface()
    }

    private func detail(_ pane: DiscoveredPane) -> some View {
        let current = identity(of: pane)
        let state = label(for: current)
        let isAdopted = adopted.contains(pane.id)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Kicker(text: "Selected session")
                        Text(pane.name).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                            .foregroundStyle(Palette.foreground).accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 12)
                    StatusLabel(text: current == .verified ? "Identity verified" : state.0, tone: state.1,
                                symbol: state.2, size: 12)
                }
                HStack(spacing: 12) {
                    endpoint("terminal", "tmux pane", pane.pane)
                    Image(systemName: current == .verified ? "link" : "link.badge.plus").font(.system(size: 15))
                        .foregroundStyle(current == .verified ? Palette.working : Palette.secondary)
                    endpoint("bubble.left", "Conversation", pane.conversation ?? "Not available")
                }
                VStack(spacing: 13) {
                    KeyValueRow(key: "Host and directory", value: pane.hostDirectory, monospaced: true)
                    KeyValueRow(key: "Existing task state", value: pane.taskState)
                    KeyValueRow(key: "Join method", value: pane.joinMethod)
                }
            }
            .padding(24)
            Hairline()
            VStack(alignment: .leading, spacing: 16) {
                Kicker(text: "Preservation checks")
                if pane.checks.isEmpty {
                    Text("This pane has no agent conversation. Its console stays visible and ordinary terminal use is unaffected.")
                        .font(.system(size: 12.5)).foregroundStyle(.inkSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                              alignment: .leading, spacing: 17) {
                        ForEach(pane.checks) { check in
                            let passed = current == .verified || check.pendingDetail == nil
                            EvidenceRow(title: check.id, detail: passed ? check.detail : (check.pendingDetail ?? check.detail),
                                        passed: passed)
                        }
                    }
                }
            }
            .padding(24)
            Hairline()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Associate with run").font(.system(size: 12)).foregroundStyle(.inkSecondary)
                    HStack(spacing: 7) {
                        Text(runLabel).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text(runID).font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                    }
                }
                Spacer(minLength: 12)
                if current == .needsVerification {
                    Button { verified.insert(pane.id) } label: { Label("Verify in live pane", systemImage: "eye") }
                        .buttonStyle(CapsuleButtonStyle())
                }
                if current == .consoleOnly {
                    UnavailableAction(title: "Adopt session", symbol: "link",
                                      reason: "This pane has no agent conversation to adopt.")
                } else {
                    Button { adopted.insert(pane.id) } label: {
                        Label(isAdopted ? "Adopted" : "Adopt session", systemImage: isAdopted ? "checkmark" : "link")
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(isAdopted || current != .verified)
                    .help(current == .verified ? "Adopt this session into \(runLabel)" : "Verify the session's identity first")
                }
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 72)
            .background(Palette.footer.opacity(0.6))
        }
        .panelSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session \(pane.name)")
    }

    private func endpoint(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.inkSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text(value).font(TypeRole.monoID).foregroundStyle(.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: Radius.field))
        .overlay { RoundedRectangle(cornerRadius: Radius.field).strokeBorder(.inkHairline) }
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        refreshing = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            refreshing = false
        }
    }
}

// MARK: - Recover a connection

struct AffectedWorker: Identifiable, Equatable {
    enum Follow: Equatable { case checkDelivery, heldByYou }

    let id: String
    let detail: String
    let branch: String
    let follow: Follow

    var name: String { id }
}

struct RecoveryReport {
    let kicker: String
    let summary: String
    let events: [TimelineEvent]
    let workers: [AffectedWorker]
    let heldWorker: String
    let gapNote: String
    let recipient: String
    let messageID: String
    let accepted: String
    let message: String
    let reconciled: String
}

struct RecoveryPage: View {
    private enum Delivery: Equatable { case unknown, checking, confirmed }

    let report: RecoveryReport
    let openWorker: (String) -> Void

    @State private var delivery = Delivery.unknown
    @State private var handedBack = false

    var body: some View {
        TaskSheet {
            PageHeader(kicker: report.kicker, title: "Connection recovery", subtitle: report.summary) { EmptyView() }
        } form: {
            VStack(alignment: .leading, spacing: 18) {
                FormSection(title: "Connection timeline") {
                    StatusLabel(text: "Connected", tone: .working, symbol: "checkmark.circle.fill", size: 12)
                } content: {
                    ConnectionTimeline(events: report.events)
                }
                Hairline()
                FormSection(title: "Affected workers") { EmptyView() } content: { workers }
                control
                Label(report.gapNote, systemImage: "clock").font(.system(size: 12)).foregroundStyle(.inkSecondary)
            }
        } aside: {
            operation
        } footer: {
            SheetFooter(symbol: "clock", note: delivery == .confirmed ? "Reconciled just now" : report.reconciled) {
                UnavailableAction(title: "Resend message",
                                  reason: delivery == .confirmed
                                      ? "The worker already received \(report.messageID)."
                                      : "Sending again is disabled until delivery can be ruled out.")
                Button(action: check) {
                    Label(delivery == .checking ? "Checking…" : "Check delivery", systemImage: "arrow.clockwise")
                }
                .buttonStyle(CapsuleButtonStyle(prominent: true))
                .disabled(delivery != .unknown)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection recovery")
    }

    private var workers: some View {
        DataTable(headers: ["Worker", "Connection", "Action"], weights: [44, 24, 32], rows: report.workers,
                  carded: false, rowHeight: 57) { worker, column in
            switch column {
            case 0:
                Button { openWorker(worker.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(worker.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
                        Text("\(worker.detail) · \(worker.branch)").font(TypeRole.meta).foregroundStyle(.inkSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(worker.name)")
            case 1:
                StatusLabel(text: "Restored", tone: .working, symbol: "checkmark.circle.fill", size: 12)
            default:
                switch worker.follow {
                case .checkDelivery:
                    CapabilityChip(text: delivery == .confirmed ? "Delivered" : "Check delivery",
                                   tone: delivery == .confirmed ? .working : .attention)
                case .heldByYou:
                    Label(handedBack ? "Handed back" : "You have control", systemImage: handedBack ? "eye" : "hand.raised")
                        .font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xD3D6E0))
                }
            }
        }
    }

    private var control: some View {
        HStack(alignment: .center, spacing: 12) {
            if handedBack {
                Callout(symbol: "eye", title: "\(report.heldWorker) is back with its coordinator",
                        detail: "You are observing again. Take terminal control from the worker's tile to type into it.")
            } else {
                Callout(symbol: "waveform.path.ecg", title: "You retain control of \(report.heldWorker)",
                        detail: "Only you can hand \(report.heldWorker) back to its coordinator. Reconnecting preserved your input control.")
            }
            if !handedBack {
                Button("Hand back") { handedBack = true }
                    .buttonStyle(HandbackButtonStyle())
                    .accessibilityLabel("Hand back input for \(report.heldWorker)")
            }
        }
    }

    private var operation: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(symbol: "bubble.left", kicker: "Operation detail", title: "Worker message")
            Group {
                switch delivery {
                case .unknown:
                    StatusLabel(text: "Delivery unknown", tone: .attention, symbol: "questionmark.circle.fill", size: 12)
                case .checking:
                    StatusLabel(text: "Checking the worker inbox", tone: .attention, symbol: "clock", size: 12)
                case .confirmed:
                    StatusLabel(text: "Delivered", tone: .working, symbol: "checkmark.circle.fill", size: 12)
                }
            }
            .padding(.top, 18)
            Hairline().padding(.top, 16).padding(.bottom, 20)
            VStack(spacing: 15) {
                KeyValueRow(key: "Recipient", value: report.recipient)
                KeyValueRow(key: "Message ID", value: report.messageID, monospaced: true)
                KeyValueRow(key: "Accepted", value: report.accepted)
                KeyValueRow(key: "Worker receipt", value: delivery == .confirmed ? "Found in inbox" : "Unverified")
                KeyValueRow(key: "Outcome", value: delivery == .confirmed ? "delivered" : "delivery_unknown", monospaced: true)
            }
            Hairline().padding(.top, 22).padding(.bottom, 20)
            Kicker(text: "Original message")
            Text(report.message).font(.system(size: 14)).lineSpacing(4).foregroundStyle(Color(hex: 0xE6E8F0))
                .padding(.leading, 14).padding(.vertical, 4)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.assignmentRule).frame(width: 2) }
                .padding(.top, 13).padding(.bottom, 20)
                .textSelection(.enabled)
            if delivery == .confirmed {
                Callout(symbol: "checkmark", title: "Delivery confirmed",
                        detail: "\(report.messageID) is in the worker's inbox. Nothing was sent twice.")
            } else {
                Callout(symbol: "exclamationmark.triangle", title: "Awaiting delivery evidence",
                        detail: "Check the worker inbox for \(report.messageID). Sending again is disabled until delivery can be ruled out.",
                        tone: .attention)
            }
        }
        .inspectorCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Operation detail for \(report.messageID)")
    }

    private func check() {
        delivery = .checking
        Task {
            try? await Task.sleep(for: .milliseconds(1100))
            delivery = .confirmed
        }
    }
}

// MARK: - Provider sign-in (operation detail)

struct OperationFact: Identifiable, Equatable {
    let id: String
    let value: String
    var monospaced = false
}

struct OperationEvent: Identifiable, Equatable {
    let id: Int
    let time: String
    let text: String
}

struct OperationDetail {
    let kicker: String
    let title: String
    let noticeTitle: String
    let noticeDetail: String
    let facts: [OperationFact]
    let history: [OperationEvent]
    let workerName: String
}

struct OperationDetailPage: View {
    private enum Phase: Equatable { case waiting, checking, resumed }

    let operation: OperationDetail
    let openPrompt: () -> Void

    @State private var phase = Phase.waiting

    private var history: [OperationEvent] {
        guard phase == .resumed else { return operation.history }
        let next = (operation.history.map(\.id).max() ?? 0) + 1
        return operation.history + [
            OperationEvent(id: next, time: "now", text: "Sign-in confirmed"),
            OperationEvent(id: next + 1, time: "now", text: "Assignment resumed on the same operation")
        ]
    }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: operation.kicker, title: "Operation detail",
                       subtitle: "Resume the original request after completing the provider step.") { EmptyView() }
        } content: {
            HStack(alignment: .top, spacing: 22) {
                main
                aside.frame(width: 340)
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: operation.title) {
                switch phase {
                case .waiting:
                    StatusLabel(text: "Needs your input", tone: .attention, symbol: "questionmark.circle.fill", size: 12)
                case .checking:
                    StatusLabel(text: "Checking sign-in", tone: .attention, symbol: "clock", size: 12)
                case .resumed:
                    StatusLabel(text: "Resumed", tone: .working, symbol: "checkmark.circle.fill", size: 12)
                }
            }
            if phase == .resumed {
                Callout(symbol: "checkmark", title: "Sign-in complete",
                        detail: "\(operation.workerName) resumed its existing assignment. No new operation was created.")
            } else {
                Callout(symbol: "lock", title: operation.noticeTitle, detail: operation.noticeDetail, tone: .attention)
            }
            DataTable(headers: ["Operation", "Value"], weights: [32, 68], rows: operation.facts, carded: false,
                      rowHeight: 48) { fact, column in
                if column == 0 {
                    Text(fact.id).font(.system(size: 13)).foregroundStyle(.inkSecondary)
                } else {
                    Text(fact.id == "Outcome" && phase == .resumed ? "resumed" : fact.value)
                        .font(fact.monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
                        .foregroundStyle(Palette.foreground).textSelection(.enabled)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: Radius.field).strokeBorder(.inkHairline) }
            .clipShape(RoundedRectangle(cornerRadius: Radius.field))
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(action: refresh) {
                    Label(phase == .checking ? "Checking…" : "Refresh status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(phase != .waiting)
                Button(action: openPrompt) { Label("Open sign-in prompt", systemImage: "terminal") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(phase == .resumed)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Operation history", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 14)
            ForEach(history) { event in
                Hairline()
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.time).font(TypeRole.monoMeta).foregroundStyle(.inkSecondary)
                    Text(event.text).font(.system(size: 13.5)).foregroundStyle(Palette.foreground)
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
            Hairline()
            Label(phase == .resumed ? "Operation resumed" : "Waiting on you",
                  systemImage: phase == .resumed ? "checkmark" : "clock")
                .font(.system(size: 12)).foregroundStyle(.inkSecondary)
                .padding(.top, 14)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }

    private func refresh() {
        phase = .checking
        Task {
            try? await Task.sleep(for: .milliseconds(1100))
            phase = .resumed
        }
    }
}

// MARK: - Preferences

struct PreferencesPage: View {
    let projectName: String
    let retentionOptions: [String]
    /// Shown when the page is drawn with the system's reduced-transparency and contrast settings.
    let showsSystemAppearance: Bool
    let presentation: AttentionPresentation
    let choosePresentation: (AttentionPresentation) -> Void

    @Environment(\.usesOpaqueSurfaces) private var opaqueSurfaces
    @Environment(\.usesStrongContrast) private var strongContrast
    @State private var recording = true
    @State private var retention: String

    init(projectName: String, retention: String, retentionOptions: [String], showsSystemAppearance: Bool,
         presentation: AttentionPresentation, choosePresentation: @escaping (AttentionPresentation) -> Void) {
        self.projectName = projectName
        self.retentionOptions = retentionOptions
        self.showsSystemAppearance = showsSystemAppearance
        self.presentation = presentation
        self.choosePresentation = choosePresentation
        _retention = State(initialValue: retention)
    }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "Workspace / Settings", title: "Preferences",
                       subtitle: "Set how Commander presents pending decisions and records project activity.") {
                EmptyView()
            }
        } content: {
            if showsSystemAppearance { systemAppearance }
            heading("Attention", "When a worker needs you", note: "Workspace preference", symbol: "desktopcomputer")
            HStack(alignment: .top, spacing: 14) {
                ForEach(AttentionPresentation.allCases) { mode in
                    PresentationChoiceCard(mode: mode, isSelected: mode == presentation) { choosePresentation(mode) }
                }
            }
            heading("Transcripts", "Recording & retention", note: "\(projectName) project", symbol: "folder")
            VStack(spacing: 0) {
                SettingRow(title: "Record terminal output",
                           detail: "Make timestamped worker output searchable for \(projectName).") {
                    HStack(spacing: 9) {
                        Text(recording ? "On" : "Off").font(.system(size: 13)).foregroundStyle(Color(hex: 0xD3D6E0))
                        Toggle("Record terminal output", isOn: $recording).toggleStyle(.switch).labelsHidden()
                            .tint(Palette.accentBottom)
                    }
                }
                Hairline()
                SettingRow(title: "Keep recordings for",
                           detail: "Expired output and its search index entries are removed together.") {
                    MenuField(name: "Keep recordings for", options: retentionOptions, selection: $retention)
                        .frame(width: 132)
                        .disabled(!recording)
                }
            }
            .panelSurface()
            Label("Transcripts are private to your local user. Recording captures terminal output and excludes raw input keystrokes.",
                  systemImage: "lock")
                .font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
        }
    }

    private func heading(_ kicker: String, _ title: String, note: String, symbol: String) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 11) {
                Kicker(text: kicker)
                Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.7).foregroundStyle(Palette.foreground)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
            Label(note, systemImage: symbol).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
        }
        .padding(.top, 6)
    }

    private var systemAppearance: some View {
        HStack(spacing: 16) {
            IconTile(symbol: "desktopcomputer", size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("System appearance").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text("Follows macOS display settings").font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 12)
            systemState("Reduce Transparency", isOn: opaqueSurfaces)
            systemState("Increase Contrast", isOn: strongContrast)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .panelSurface()
    }

    private func systemState(_ name: String, isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.system(size: 12)).foregroundStyle(.inkSecondary)
            Label(isOn ? "On" : "Off", systemImage: isOn ? "checkmark" : "minus")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground)
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) is \(isOn ? "on" : "off")")
    }
}
