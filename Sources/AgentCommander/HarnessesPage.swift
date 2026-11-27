import SwiftUI

// The Harnesses mode's page: the harnesses this Mac can run, and the chosen one's install,
// sign-in, adapter and settings (design/HARNESSES.md, DESIGN.md "Harnesses page").
//
//   Molecule   HarnessRow        a harness in a list: mark, name, who makes it, version, state
//   Organisms  HarnessList       one place's harnesses on a panel; choosing a row shows it
//              HarnessDetail     the inspector: install, sign-in, ACP, settings, and the one action
//   Page       HarnessesPage     WorkspacePage: header, then NetworkSplit(list | detail)
//
// The page takes a `HarnessesContext` (values and intents) and the place it filters by. The feed
// (Harnesses.swift) owns the subscription and every call. The sign-in terminal is
// HarnessSessionSheet (HarnessTerminal.swift), presented by the window.

enum HarnessLayout {
    /// The least a harness row can take: mark, name, version and state without cutting the state.
    static let listMinimum: CGFloat = 392
    static let versionColumn: CGFloat = 76
    static let stateColumn: CGFloat = 136
}

// MARK: - Molecule

/// One harness in a list. The state is a lamp and a word at the trailing edge, in a column of its
/// own so states line up down the list; the version is mono data before it.
struct HarnessRow: View {
    let harness: Harness
    var isSelected = false
    @Environment(\.theme) private var theme

    var body: some View {
        let state = harness.state
        HStack(spacing: Space.m + 1) {
            IconTile(symbol: harness.symbol, tone: isSelected && harness.auth.state == .signedIn ? .working : .neutral, size: 31)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(harness.name).themeType(theme.type.name)
                        .foregroundStyle(.theme(harness.installed ? \.color.foreground : \.surface.softInk))
                        .lineLimit(1).truncationMode(.middle)
                    if harness.managed { MultiplayerBadge(text: "Runs", symbol: "play.fill", tone: .focus) }
                    if harness.cantRun { MultiplayerBadge(text: "Blocked", symbol: "exclamationmark.triangle.fill", tone: .attention) }
                    if harness.installed, !harness.settings.enabled { MultiplayerBadge(text: "Off") }
                }
                Text(harness.kindLine).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: Space.s)
            Text(harness.version.isEmpty ? "" : harness.version)
                .themeType(theme.type.data).foregroundStyle(.theme(\.color.secondary))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: HarnessLayout.versionColumn, alignment: .trailing)
            ThemeStatus(text: state.title, tone: state.tone, symbol: state.symbol)
                .frame(width: HarnessLayout.stateColumn, alignment: .trailing)
        }
        .padding(.horizontal, Space.l - 1)
        .frame(maxWidth: .infinity, minHeight: theme.space.rowHeight + 24, alignment: .leading)
        .background {
            if isSelected { Color.clear.selectionCard(true) }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Organisms

/// One place's harnesses: a heading with the count, then a row per harness.
struct HarnessList: View {
    let title: String
    let harnesses: [Harness]
    let empty: (text: String, lamp: MultiplayerLamp.Kind)
    let shown: String?
    let show: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ShellBandHeading(title: title, count: "\(harnesses.count)")
                .padding(.horizontal, Space.l - 1).padding(.top, Space.xs)
            if harnesses.isEmpty {
                ShellNote(text: empty.text, lamp: empty.lamp).padding(.horizontal, Space.xs)
            }
            ForEach(harnesses) { harness in
                Button { show(harness.id) } label: {
                    HarnessRow(harness: harness, isSelected: harness.id == shown)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(harness.spoken)
                .accessibilityHint("Shows this harness in the inspector")
                .accessibilityAddTraits(harness.id == shown ? .isSelected : [])
                .accessibilityIdentifier("harness-row-\(harness.id)")
            }
        }
        .padding(10)
        .frame(minWidth: HarnessLayout.listMinimum, alignment: .leading)
        .themePanel()
        .animation(theme.motion.animation(theme.motion.standard), value: harnesses.map(\.id))
    }
}

/// One harness: whether it is installed and where, its sign-in, its ACP adapter, its settings,
/// and the one action that changes its state: Install or Sign in.
struct HarnessDetail: View {
    let harness: Harness
    var isBusy = false
    var failure: String? = nil
    let actions: HarnessActions
    @Environment(\.theme) private var theme

    /// The footer's one line.
    static func note(for harness: Harness) -> String {
        guard harness.installed else {
            if harness.install.available { return "Install runs \(harness.name)’s own command in a terminal here." }
            return harness.website.isEmpty ? "Agent Commander has no install command for it." : "Install it from \(harness.website)."
        }
        switch harness.auth.state {
        case .signedOut, .expired, .unknown:
            return harness.login.available
                ? "Sign in runs \(harness.name)’s own command. Agent Commander never sees the credentials."
                : "Sign in with \(harness.name) itself; Agent Commander has no sign-in command for it."
        default:
            return harness.checkedAt.map { "Checked \($0.formatted(date: .omitted, time: .shortened))." } ?? "Not checked yet."
        }
    }

    static func expiry(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    var body: some View {
        let state = harness.state
        NetworkInspector(title: harness.name, serverName: harness.kindLine,
                         state: (lamp: state.lamp, text: state.title, tone: state.tone),
                         note: Self.note(for: harness)) {
            VStack(alignment: .leading, spacing: 0) {
                if let failure {
                    Text(failure).themeType(theme.type.sub).foregroundStyle(.theme(\.color.failure))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, theme.space.sectionInset).padding(.vertical, Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.color.failure.color.opacity(0.12))
                        .accessibilityLabel(failure)
                    ThemeRule()
                }
                if !harness.runBlocker.isEmpty {
                    Callout(symbol: "exclamationmark.triangle", title: "Runs can’t start with \(harness.name)",
                            detail: harness.runBlocker, tone: .attention)
                        .padding(.horizontal, theme.space.sectionInset).padding(.vertical, theme.space.bandTop)
                    ThemeRule()
                }
                band("Install") {
                    line("State", harness.installed ? "Installed" : "Not installed")
                    if harness.installed {
                        line("Path", harness.executable.isEmpty ? "Unknown" : harness.executable, mono: true)
                        line("Version", harness.version.isEmpty ? "Unknown" : harness.version, mono: true)
                    } else if !harness.install.display.isEmpty {
                        line("Command", harness.install.display, mono: true)
                    }
                }
                if harness.installed {
                    band("Sign-in") {
                        line("State", state.title)
                        if !harness.auth.account.isEmpty { line("Account", harness.auth.account) }
                        if !harness.auth.plan.isEmpty { line("Plan", harness.auth.plan) }
                        if !harness.auth.method.isEmpty { line("Method", harness.auth.method) }
                        if let expires = harness.auth.expiresAt { line("Expires", Self.expiry(expires), time: true) }
                        if harness.auth.state != .notRequired { line("Source", harness.sourceTitle) }
                        if !harness.verified, harness.auth.state != .notRequired {
                            sentence("Read from credential files. Agent Commander hasn’t checked this against \(harness.name)’s own status command.")
                        }
                        if !harness.auth.detail.isEmpty { sentence(harness.auth.detail) }
                    }
                }
                band("ACP") {
                    line("Adapter", harness.acp.adapter.isEmpty ? "None" : harness.acp.adapter, mono: !harness.acp.adapter.isEmpty)
                    line("Mode", harness.acpModeTitle)
                    // The service's own reason, shown first in the inspector, already says what is in the way.
                    if harness.adapterIsMissing, harness.runBlocker.isEmpty {
                        Callout(symbol: "exclamationmark.triangle", title: "Adapter not found", detail: harness.adapterWarning,
                                tone: .attention)
                    }
                }
                if harness.installed {
                    band("Settings") {
                        HStack(spacing: Space.m) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Enabled").themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                                Text(harness.managed ? "Offered when you start a run." : "Kept for when Agent Commander can start runs with it.")
                                    .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Space.m)
                            Toggle("Enabled", isOn: Binding(get: { harness.settings.enabled },
                                                            set: { actions.setEnabled($0, harness.id) }))
                                .labelsHidden()
                                .themeSwitch()
                                .accessibilityLabel("\(harness.name) enabled")
                                .accessibilityIdentifier("harness-enabled")
                        }
                        if !harness.models.isEmpty {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                ThemeHeading(text: "Default model")
                                MultiplayerMenuField(label: "Default model for \(harness.name)", placeholder: "Harness default",
                                                     options: [(value: "", title: "Harness default")] + harness.models.map { (value: $0, title: $0) },
                                                     selection: Binding(get: { harness.settings.defaultModel },
                                                                        set: { actions.setDefaultModel($0, harness.id) }))
                                    .accessibilityIdentifier("harness-default-model")
                            }
                        }
                    }
                }
            }
        } footer: {
            action
        }
        .accessibilityIdentifier("harness-detail")
    }

    /// One action. A harness that isn't installed can be installed; one whose sign-in is gone or
    /// can't be read can be signed in.
    @ViewBuilder private var action: some View {
        if !harness.installed {
            if harness.install.available {
                Button { actions.install(harness.id) } label: {
                    Label(isBusy ? "Starting…" : "Install", systemImage: "arrow.down.square")
                }
                .buttonStyle(ThemeButtonStyle(prominent: true))
                .disabled(isBusy)
                .accessibilityIdentifier("harness-install")
            }
        } else if harness.login.available, [.signedOut, .expired, .unknown].contains(harness.auth.state) {
            Button { actions.signIn(harness.id) } label: {
                Label(isBusy ? "Starting…" : "Sign in", systemImage: "person.badge.key")
            }
            .buttonStyle(ThemeButtonStyle(prominent: true))
            .disabled(isBusy)
            .accessibilityIdentifier("harness-sign-in")
        }
    }

    private func band(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                ThemeHeading(text: title).accessibilityAddTraits(.isHeader)
                content()
            }
        }
    }

    private func line(_ label: String, _ value: String, mono: Bool = false, time: Bool = false) -> some View {
        MultiplayerSummaryLine(label: label, value: value, monospaced: mono, isTime: time)
            .textSelection(.enabled)
            .help(mono ? value : "")
    }

    private func sentence(_ text: String) -> some View {
        Text(text).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Page

struct HarnessesPage: View {
    /// The place whose harnesses are listed (`HarnessPlace`).
    let place: String
    var crumbs: [String] = ["Harnesses"]
    let context: HarnessesContext
    /// The harness in the inspector. Nil shows the place's first.
    @Binding var shown: String?
    @Environment(\.theme) private var theme

    private var listed: [Harness] { HarnessPlace.harnesses(context.harnesses, in: place) }
    private var harness: Harness? { listed.first { $0.id == shown } ?? listed.first }

    private var summary: String {
        if context.isUnavailable { return "The harnesses this Mac can run, and whether each is signed in." }
        if context.isLoading { return "Reading the harnesses on this Mac…" }
        let tally = context.tally.summary
        return context.link == .reconnecting ? "\(tally). Reconnecting; this is the last list the service sent." : "\(tally)."
    }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: crumbs.map { $0.uppercased() }.joined(separator: " / "), title: "Harnesses", subtitle: summary) {
                Button { Task { await context.actions.refresh() } } label: {
                    Label(context.isRefreshing ? "Checking…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ThemeButtonStyle())
                .disabled(context.isRefreshing || context.harnesses.isEmpty)
                .help("Check every installed harness again")
                .accessibilityIdentifier("harnesses-refresh")
            }
        } content: {
            if context.isUnavailable {
                unavailable
            } else if context.isLoading {
                ShellNote(text: "Reading the harnesses on this Mac…", lamp: .waiting).themePanel()
            } else {
                NetworkSplit {
                    HarnessList(title: HarnessPlace.title(place), harnesses: listed, empty: HarnessPlace.emptyNote(place),
                                shown: harness?.id) { shown = $0 }
                } inspector: {
                    if let harness {
                        HarnessDetail(harness: harness, isBusy: context.busy.contains(harness.id),
                                      failure: context.failures[harness.id], actions: context.actions)
                    } else {
                        NetworkInspectorNote(text: "Choose a harness to see its install, sign-in and settings.")
                    }
                }
            }
        }
        .accessibilityIdentifier("harnesses-page")
    }

    /// The service has no harness routes yet, or can't be reached: say so calmly, and offer one way on.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShellNote(text: "Harness status is unavailable. The service on this Mac didn’t answer, or doesn’t report harnesses yet. Agent Commander keeps trying.",
                      lamp: .error)
            Button("Try again") { context.actions.retry() }
                .buttonStyle(ThemeButtonStyle())
                .padding(.horizontal, Space.m).padding(.bottom, theme.space.bandBottom)
                .accessibilityIdentifier("harnesses-retry")
        }
        .frame(maxWidth: 540, alignment: .leading)
        .themePanel()
    }
}
