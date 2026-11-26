import SwiftUI

// The Hosts page: the services this app can talk to, and the choice of one.
//
//   Molecule   HostListRow (SetupPages.swift), FactColumn, Callout, ThemeStatus
//   Organisms  CommanderHostList     This Mac, then each headless host; choosing a row shows it
//              CommanderHostDetail   the shown host's facts, its trouble, and the one action
//   Page       CommanderHostsPage    WorkspacePage: CollectionInspector(host list | host detail)
//
// The page receives `CommanderHostEntry` values and emits `use` and `refresh`. The hosts model
// (CommanderHosts.swift) owns the list, the connect process and the choice. Compare with
// design/concepts/hosts.png.

/// What the live page hands the cockpit for the Hosts place and the toolbar.
struct CommanderHostsContext {
    var entries: [CommanderHostEntry]
    /// Why the host list could not be read.
    var listError: String? = nil
    /// Chooses the service to talk to: a host's destination, or nil for this Mac.
    var use: @MainActor (String?) -> Void = { _ in }
    var refresh: @MainActor () async -> Void = {}

    /// The headless host in use, for the toolbar. Nil while the app uses this Mac.
    var serviceName: String? { entries.first { $0.isInUse && !$0.isLocal }?.name }
}

extension CommanderHostEntry.State {
    /// This Mac's row shows the app's own link to the local service.
    init(_ connection: CockpitModel.Connection) {
        switch connection {
        case .online: self = .connected
        case .connecting: self = .connecting
        case .offline: self = .disconnected
        }
    }
}

struct CommanderHostsPage: View {
    let hosts: CommanderHostsContext
    @Environment(\.theme) private var theme
    @State private var shown: String?
    @State private var refreshing = false

    private var entry: CommanderHostEntry? {
        hosts.entries.first { $0.id == shown } ?? hosts.entries.first(where: \.isInUse) ?? hosts.entries.first
    }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: "Workspace / Infrastructure", title: "Hosts",
                       subtitle: "Agent Commander talks to one service at a time: this Mac’s, or a headless host’s over SSH.") {
                Button {
                    refreshing = true
                    Task {
                        await hosts.refresh()
                        refreshing = false
                    }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(ThemeButtonStyle())
                    .disabled(refreshing)
                    .accessibilityIdentifier("hosts-refresh")
            }
        } content: {
            CollectionInspector(collectionWidth: 382) {
                CommanderHostList(entries: hosts.entries, listError: hosts.listError, shown: entry?.id) { shown = $0 }
            } inspector: {
                if let entry { CommanderHostDetail(entry: entry, use: hosts.use) }
            }
        }
        .task { await hosts.refresh() }
    }
}

/// The host list: a heading with the count, a row per host, then how a host is added.
struct CommanderHostList: View {
    let entries: [CommanderHostEntry]
    var listError: String? = nil
    let shown: String?
    let show: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                ThemeHeading(text: "Hosts")
                Spacer(minLength: Space.s)
                MetaText(text: "\(entries.count)", monospaced: true)
            }
            .padding(.horizontal, Space.l - 1).padding(.top, Space.s).padding(.bottom, Space.m)
            ForEach(entries) { item in
                Button { show(item.id) } label: {
                    HostListRow(symbol: item.symbol, name: item.name, kind: item.kind, status: item.stateTitle,
                                tone: item.tone, statusSymbol: item.stateSymbol, isSelected: item.id == shown,
                                isLit: item.state == .connected, badge: item.isInUse ? "In use" : nil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.spoken)
                .accessibilityAddTraits(item.id == shown ? .isSelected : [])
                .accessibilityIdentifier("host-row-\(item.id)")
            }
            if let listError {
                Callout(symbol: "exclamationmark.triangle", title: "The host list can’t be read", detail: listError,
                        tone: .attention)
                    .padding(.horizontal, Space.xs).padding(.top, Space.s)
            }
            ThemeRule().padding(.horizontal, 14).padding(.top, 14)
            HStack(spacing: Space.m) {
                Image(systemName: "book").font(.system(size: theme.type.body.size - 1)).foregroundStyle(.theme(\.color.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a headless host from Terminal").themeType(theme.type.sub).foregroundStyle(.theme(\.surface.softInk))
                    Text("agentctl host deploy DESTINATION").themeType(theme.type.mono).foregroundStyle(.theme(\.color.secondary))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, Space.l - 1).padding(.top, 10).padding(.bottom, 6)
        }
        .padding(10)
        .themePanel()
    }
}

/// One host: what it is, its state, its facts, what went wrong, and the one action that changes
/// which service the app talks to.
struct CommanderHostDetail: View {
    let entry: CommanderHostEntry
    let use: @MainActor (String?) -> Void
    @Environment(\.theme) private var theme

    /// The time of the last deploy as the Mac writes dates, short enough for its column: the day
    /// and the time in this year ("Nov 26 at 1:05 PM"), the day and the year before it
    /// ("Nov 26, 2025"). The raw text when it is not a time.
    static func deployed(_ updated: String?, now: Date = .now, calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        guard let updated, !updated.isEmpty else { return "Unknown" }
        guard let date = try? Date(updated, strategy: .iso8601) else { return updated }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        style = calendar.isDate(date, equalTo: now, toGranularity: .year) ? style.hour().minute() : style.year()
        return date.formatted(style)
    }

    /// The footer's one line. Short enough to sit beside the action without wrapping.
    static func note(for entry: CommanderHostEntry) -> String {
        if entry.isInUse {
            switch entry.state {
            case .disconnected where !entry.isLocal:
                return "Waiting for SSH. The host keeps its workers running."
            default:
                return entry.isLocal ? "Agent Commander is using this Mac’s service." : "Agent Commander is using this host."
            }
        }
        switch entry.state {
        case .connecting: return "Connecting over SSH. This Mac stays in use until then."
        case .disconnected: return "Waiting for SSH. This Mac stays in use until then."
        case .failed: return "Agent Commander is using this Mac’s service."
        default: return entry.isLocal ? "This Mac’s service keeps running while you use a host." : "Runs and workers on this host show once you use it."
        }
    }

    /// What the footer's line leaves out, as its tooltip. Nil where the line says it all.
    static func noteHelp(for entry: CommanderHostEntry) -> String? {
        guard !entry.isLocal else { return nil }
        switch entry.state {
        case .disconnected:
            return "agentctl keeps retrying the SSH connection. The host keeps its workers running and holds their questions until Agent Commander is back."
        case .connecting:
            return "Agent Commander keeps using this Mac’s service until the host’s forwarded socket answers."
        default:
            return nil
        }
    }

    var body: some View {
        let inset = theme.space.sectionInset + 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.l) {
                IconTile(symbol: entry.symbol, tone: entry.tone, size: 46)
                VStack(alignment: .leading, spacing: 6) {
                    ThemeHeading(text: entry.typeLabel)
                    Text(entry.name).themeType(theme.pageType.detailTitle)
                        .foregroundStyle(.theme(\.color.foreground)).lineLimit(1).truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: Space.m)
                ThemeStatus(text: entry.stateTitle, tone: entry.tone, symbol: entry.stateSymbol)
            }
            .padding(.horizontal, inset).padding(.top, theme.space.bandTop + 2)
            HStack(alignment: .top, spacing: Space.l) {
                if entry.isLocal {
                    FactColumn(label: "Connection", value: "Local socket")
                    ThemeRule(vertical: true).frame(height: 42)
                    FactColumn(label: "Runs on", value: "This Mac")
                } else {
                    FactColumn(label: "Connection", value: "SSH socket")
                    ThemeRule(vertical: true).frame(height: 42)
                    FactColumn(label: "Version", value: entry.version ?? "Unknown", monospaced: true)
                    ThemeRule(vertical: true).frame(height: 42)
                    // The API number is short: its column hugs it and the others share the room.
                    FactColumn(label: "API", value: entry.api.map(String.init) ?? "Unknown", monospaced: true, hugs: true)
                    ThemeRule(vertical: true).frame(height: 42)
                    FactColumn(label: "Deployed", value: Self.deployed(entry.updated))
                }
            }
            .padding(.horizontal, inset).padding(.vertical, theme.space.bandTop + 2)
            if let detail = entry.detail, entry.state == .failed || entry.state == .disconnected {
                Callout(symbol: entry.stateSymbol,
                        title: entry.state == .failed ? "\(entry.name) can’t be used" : "\(entry.name) is disconnected",
                        detail: detail, tone: .attention)
                    .padding(.horizontal, inset).padding(.bottom, theme.space.bandTop + 2)
            }
            ThemeRule()
            HStack(spacing: 10) {
                if entry.state == .connecting { ProgressView().controlSize(.small) } else {
                    Image(systemName: "waveform.path.ecg").font(.system(size: theme.pageType.meta.size))
                        .foregroundStyle(.theme(\.color.secondary))
                }
                Text(Self.note(for: entry)).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .help(Self.noteHelp(for: entry) ?? "")
                Spacer(minLength: Space.m)
                action
            }
            .padding(.horizontal, inset)
            .frame(minHeight: theme.space.controlHeightLarge + 31)
            .background(theme.surface.footerFill.color)
        }
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Host \(entry.name)")
    }

    /// One action. A host in use, or on its way, can be left for this Mac; any other can be used.
    @ViewBuilder private var action: some View {
        if entry.isLocal {
            if !entry.isInUse {
                Button { use(nil) } label: { Label("Use This Mac", systemImage: "desktopcomputer") }
                    .buttonStyle(ThemeButtonStyle(prominent: true))
                    .accessibilityIdentifier("host-use")
            }
        } else if entry.isInUse || entry.state == .connecting || entry.state == .disconnected {
            Button { use(nil) } label: { Label("Disconnect", systemImage: "xmark") }
                .buttonStyle(ThemeButtonStyle())
                .help("Close the SSH connection and use This Mac")
                .accessibilityIdentifier("host-disconnect")
        } else {
            Button { use(entry.destination) } label: {
                Label(entry.state == .failed ? "Try again" : "Use this host", systemImage: "arrow.right")
            }
            .buttonStyle(ThemeButtonStyle(prominent: true))
            .accessibilityIdentifier("host-use")
        }
    }
}
