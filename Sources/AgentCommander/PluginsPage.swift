import AppKit
import SwiftUI

// The Plugins mode's page: the tool plugins installed on this Mac, and the chosen one's tools,
// grants per project and log (design/PLUGINS.md, DESIGN.md "Plugins page").
//
//   Molecules  PluginRow           a plugin in a list: mark, name, ID and tool count, version, state
//              PluginGrantRow      one checkout a tool is granted to, with its settings and verbs
//              PluginToolBlock     a tool: its name, what it does, its grants, and Grant
//              PluginSettingField  one settings field with the control for its kind
//   Organisms  PluginList          one place's plugins on a panel; choosing a row shows it
//              PluginDetail        the inspector: problem, plugin, tools and grants, log
//              PluginGrantSheet    a grant: the checkout and the settings form or JSON editor
//   Page       PluginsPage         WorkspacePage: header, restart note, NetworkSplit(list | detail)
//
// The page takes a `PluginsContext` (values and intents) and the place it filters by. The feed
// (Plugins.swift) owns every call. The window presents the grant sheet.

enum PluginLayout {
    /// The least a plugin row can take: mark, name, version and state without cutting the state.
    static let listMinimum: CGFloat = 392
    static let versionColumn: CGFloat = 76
    static let stateColumn: CGFloat = 136
    static let sheetWidth: CGFloat = 560
}

// MARK: - Molecules

/// One plugin in a list. The state is a lamp and a word at the trailing edge, in a column of its
/// own so states line up down the list; the version is mono data before it.
struct PluginRow: View {
    let plugin: Plugin
    var isSelected = false
    @Environment(\.theme) private var theme

    var body: some View {
        let state = plugin.state
        HStack(spacing: Space.m + 1) {
            IconTile(symbol: "puzzlepiece.extension", tone: plugin.hasProblem ? .failure : isSelected ? .working : .neutral, size: 31)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(plugin.name).themeType(theme.type.name)
                        .foregroundStyle(.theme(plugin.hasProblem ? \.surface.softInk : \.color.foreground))
                        .lineLimit(1).truncationMode(.middle)
                    if plugin.grantCount > 0 {
                        MultiplayerBadge(text: Plugin.count(plugin.grantCount, "grant"), tone: plugin.pendingGrantCount > 0 ? .attention : .neutral)
                    }
                }
                Text(plugin.kindLine).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: Space.s)
            Text(plugin.version)
                .themeType(theme.type.data).foregroundStyle(.theme(\.color.secondary))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: PluginLayout.versionColumn, alignment: .trailing)
            ThemeStatus(text: state.title, tone: state.tone, symbol: state.symbol)
                .frame(width: PluginLayout.stateColumn, alignment: .trailing)
        }
        .padding(.horizontal, Space.l - 1)
        .frame(maxWidth: .infinity, minHeight: theme.space.rowHeight + 24, alignment: .leading)
        .background {
            if isSelected { Color.clear.selectionCard(true) }
        }
        .contentShape(Rectangle())
    }
}

/// One checkout a tool is granted to: its name over its path, the settings it carries, and the
/// verbs. Revoke asks once more in place before it is sent.
struct PluginGrantRow: View {
    let grant: PluginGrant
    /// The plugin's grants carry settings, so the grant can be edited.
    var canEdit = true
    var isBusy = false
    let edit: () -> Void
    let revoke: () -> Void
    @State private var isConfirming = false
    @Environment(\.theme) private var theme

    private var verbs: [MultiplayerRowVerb] {
        if isConfirming {
            return [MultiplayerRowVerb(id: "keep", title: "Keep", hint: "Keep the grant for \(grant.projectName)") { isConfirming = false },
                    MultiplayerRowVerb(id: "revoke", title: "Revoke", isPrimary: true, hint: "Revoke the grant for \(grant.projectName)") {
                        isConfirming = false
                        revoke()
                    }]
        }
        var verbs: [MultiplayerRowVerb] = []
        if canEdit {
            verbs.append(MultiplayerRowVerb(id: "edit", title: "Edit", isEnabled: !isBusy, hint: "Edit the settings for \(grant.projectName)", action: edit))
        }
        verbs.append(MultiplayerRowVerb(id: "revoke", title: "Revoke…", isEnabled: !isBusy, hint: "Revoke the grant for \(grant.projectName)") { isConfirming = true })
        return verbs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .center, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s) {
                        Text(grant.projectName).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground))
                            .lineLimit(1).truncationMode(.middle)
                        if !grant.active { MultiplayerBadge(text: "At restart", symbol: "arrow.clockwise", tone: .attention) }
                    }
                    Text(grant.project).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary))
                        .lineLimit(1).truncationMode(.head).help(grant.project)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(grant.projectName), \(grant.project)\(grant.active ? "" : ", applies at the next restart")")
                Spacer(minLength: Space.s)
                if isBusy { MultiplayerSpinner() }
                MultiplayerVerbStrip(verbs: verbs)
            }
            if isConfirming {
                Text("Agents in \(grant.projectName) lose this tool at the next restart.")
                    .themeType(theme.type.sub).foregroundStyle(.theme(\.color.attention))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let settings = grant.settings {
                Text(settings.compactText).themeType(theme.type.mono).foregroundStyle(.theme(\.color.secondary))
                    .lineLimit(2).truncationMode(.tail).textSelection(.enabled).help(settings.prettyText)
                    .accessibilityLabel("Settings \(settings.compactText)")
            }
        }
        .animation(theme.motion.animation(theme.motion.fast), value: isConfirming)
        .accessibilityIdentifier("plugin-grant-\(grant.project)")
    }
}

/// One tool of a plugin: its MCP name and version, what it does, the checkouts it is granted
/// to, and the action that grants it to another.
struct PluginToolBlock: View {
    let tool: PluginTool
    var canEdit = true
    /// The plugin is refused, so a new grant would do nothing until it is reinstalled.
    var isRefused = false
    var busy = Set<String>()
    let grant: () -> Void
    let edit: (_ project: String) -> Void
    let revoke: (_ project: String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(tool.mcpTool.isEmpty ? tool.id : tool.mcpTool).themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground))
                    .lineLimit(1).truncationMode(.middle)
                MultiplayerBadge(text: "v\(tool.version)")
                Spacer(minLength: Space.s)
                Button(action: grant) { Label("Grant…", systemImage: "plus") }
                    .buttonStyle(ThemeButtonStyle(compact: true))
                    .disabled(isRefused)
                    .help(isRefused ? "Reinstall the plugin before granting its tools" : "Grant \(tool.id) to a project")
                    .accessibilityLabel("Grant \(tool.id) to a project")
                    .accessibilityIdentifier("plugin-grant-add-\(tool.id)")
            }
            Text(tool.id).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if !tool.description.isEmpty {
                Text(tool.description).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tool.grants.isEmpty {
                Text("Not granted to any project.").themeType(theme.type.sub).foregroundStyle(.theme(\.surface.softInk))
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(tool.grants) { item in
                        MultiplayerWell(edge: MultiplayerTheme.hair) {
                            PluginGrantRow(grant: item, canEdit: canEdit,
                                           isBusy: busy.contains(PluginFeed.key(tool: tool.id, project: item.project)),
                                           edit: { edit(item.project) }, revoke: { revoke(item.project) })
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool \(tool.id)")
    }
}

/// One settings field: its name, the control for its kind, and its description and bounds, or
/// the problem the last Save found in their place.
struct PluginSettingField: View {
    let field: PluginSettingsSchema.Field
    @Binding var input: PluginSettingsInput
    var problem: String? = nil
    @Environment(\.theme) private var theme

    private var text: Binding<String> {
        Binding(get: { input.text[field.name] ?? "" }, set: { input.text[field.name] = $0.isEmpty ? nil : $0 })
    }

    private var hint: String? {
        let parts = [field.detail, field.hint.map { $0 + "." }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var body: some View {
        MultiplayerField(label: field.isRequired ? "\(field.title) · required" : field.title, hint: hint, problem: problem) {
            switch field.kind {
            case .text:
                MultiplayerTextField(label: field.title, placeholder: field.isRequired ? "" : "Not set", text: text)
            case .number(let integer):
                MultiplayerTextField(label: field.title, placeholder: integer ? "42" : "2.5", text: text, monospaced: true)
                    .frame(maxWidth: 180, alignment: .leading)
            case .boolean:
                HStack(spacing: Space.s) {
                    Toggle(field.title, isOn: Binding(get: { input.flags[field.name] ?? false }, set: { input.flags[field.name] = $0 }))
                        .labelsHidden().themeSwitch()
                        .accessibilityLabel(field.title)
                    Text(input.flags[field.name].map { $0 ? "On" : "Off" } ?? (field.isRequired ? "Off" : "Not set"))
                        .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                }
            case .choice(let options):
                MultiplayerMenuField(label: field.title, placeholder: "Not set",
                                     options: (field.isRequired ? [] : [(value: "", title: "Not set")]) + options.map { (value: $0, title: $0) },
                                     selection: text)
            case .list:
                PluginBufferedTextArea(label: field.title, text: text, lines: 4)
            }
        }
        .accessibilityIdentifier("plugin-setting-\(field.name)")
    }
}

/// A `MultiplayerTextArea` whose text the view itself holds while the person types. The sheet's
/// draft round-trips through the plugin feed, and a text view fed that echo can overwrite
/// keystrokes typed before it arrives. The draft still receives every change.
private struct PluginBufferedTextArea: View {
    let label: String
    @Binding var text: String
    var lines = 3
    @State private var typed: String? = nil

    var body: some View {
        MultiplayerTextArea(label: label, text: Binding(get: { typed ?? text }, set: { typed = $0; text = $0 }), lines: lines)
    }
}

// MARK: - Organisms

/// One place's plugins: a heading with the count, then a row per plugin.
struct PluginList: View {
    let title: String
    let plugins: [Plugin]
    let empty: (text: String, lamp: MultiplayerLamp.Kind)
    let shown: String?
    let show: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ShellBandHeading(title: title, count: "\(plugins.count)")
                .padding(.horizontal, Space.l - 1).padding(.top, Space.xs)
            if plugins.isEmpty {
                ShellNote(text: empty.text, lamp: empty.lamp).padding(.horizontal, Space.xs)
            }
            ForEach(plugins) { plugin in
                Button { show(plugin.id) } label: {
                    PluginRow(plugin: plugin, isSelected: plugin.id == shown)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(plugin.spoken)
                .accessibilityHint("Shows this plugin in the inspector")
                .accessibilityAddTraits(plugin.id == shown ? .isSelected : [])
                .accessibilityIdentifier("plugin-row-\(plugin.id)")
            }
        }
        .padding(10)
        .frame(minWidth: PluginLayout.listMinimum, alignment: .leading)
        .themePanel()
        .animation(theme.motion.animation(theme.motion.standard), value: plugins.map(\.id))
    }
}

/// One plugin: why the service refuses it when it does, what it is, its tools with their grants
/// per project, and the end of its log.
struct PluginDetail: View {
    let plugin: Plugin
    var busy = Set<String>()
    var failure: String? = nil
    var log = PluginLogState()
    var restartRequired = false
    let actions: PluginActions
    /// Opens the plugin's own panel. Nil for a plugin without one.
    var openPanel: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    /// The footer's one line.
    static func note(for plugin: Plugin, restartRequired: Bool) -> String {
        if plugin.hasProblem { return "Reinstall it with agentctl plugin install. Its grants are kept." }
        if restartRequired || !plugin.loaded || plugin.pendingGrantCount > 0 { return "Changes apply when the service restarts." }
        return "Grants apply when the service restarts."
    }

    var body: some View {
        let state = plugin.state
        NetworkInspector(title: plugin.name, serverName: plugin.id,
                         state: (lamp: state.lamp, text: state.title, tone: state.tone),
                         note: Self.note(for: plugin, restartRequired: restartRequired)) {
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
                if plugin.hasProblem {
                    Callout(symbol: "exclamationmark.octagon", title: "The service refuses \(plugin.name)",
                            detail: plugin.problem, tone: .failure)
                        .padding(.horizontal, theme.space.sectionInset).padding(.vertical, theme.space.bandTop)
                        .accessibilityIdentifier("plugin-problem")
                    ThemeRule()
                }
                band("Plugin") {
                    if !plugin.description.isEmpty { sentence(plugin.description) }
                    line("Version", plugin.version.isEmpty ? "Unknown" : plugin.version, mono: true)
                    if let installed = plugin.installedAt {
                        line("Installed", installed.formatted(date: .abbreviated, time: .shortened), time: true)
                    }
                    if !plugin.digest.isEmpty { line("Digest", plugin.shortDigest, mono: true, help: plugin.digest) }
                    line("Settings", plugin.settingsSchema == nil ? "None" : "Per project")
                    if !plugin.loaded, !plugin.hasProblem {
                        sentence("Installed or changed since the service started. It loads at the next restart.")
                    }
                    if let openPanel {
                        Button(action: openPanel) { Label("Open MQTT panel", systemImage: "dot.radiowaves.left.and.right") }
                            .buttonStyle(ThemeButtonStyle())
                            .accessibilityIdentifier("plugin-open-panel")
                    }
                }
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: Space.m) {
                        ShellBandHeading(title: "Tools", count: "\(plugin.tools.count)")
                        if plugin.tools.isEmpty { sentence("This plugin contributes no tools.") }
                        ForEach(Array(plugin.tools.enumerated()), id: \.element.id) { index, tool in
                            if index > 0 { ThemeRule() }
                            PluginToolBlock(tool: tool, canEdit: plugin.settingsSchema != nil, isRefused: plugin.hasProblem, busy: busy,
                                            grant: { actions.openGrant(plugin.id, tool.id, nil) },
                                            edit: { actions.openGrant(plugin.id, tool.id, $0) },
                                            revoke: { actions.revoke(plugin.id, tool.id, $0) })
                        }
                    }
                }
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ShellBandHeading(title: "Log", note: log.log.flatMap { $0.isEmpty ? nil : $0.sizeLine }) {
                            Button { Task { await actions.readLog(plugin.id) } } label: {
                                Label(log.isLoading ? "Reading…" : "Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(ThemeButtonStyle(compact: true))
                            .disabled(log.isLoading)
                            .help("Read the end of plugin.log again")
                            .accessibilityIdentifier("plugin-log-refresh")
                        }
                        if let failure = log.failure {
                            Text(failure).themeType(theme.type.sub).foregroundStyle(.theme(\.color.failure))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let read = log.log, !read.isEmpty {
                            MultiplayerOutputWell(text: read.text, lines: 14)
                                .accessibilityIdentifier("plugin-log")
                            Text(read.path).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary))
                                .lineLimit(1).truncationMode(.head).textSelection(.enabled).help(read.path)
                        } else if log.log != nil {
                            sentence("No log yet. The plugin writes here when it starts and when a call fails.")
                        } else if log.failure == nil {
                            sentence("Reading the log…")
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("plugin-detail")
    }

    private func band(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                ThemeHeading(text: title).accessibilityAddTraits(.isHeader)
                content()
            }
        }
    }

    private func line(_ label: String, _ value: String, mono: Bool = false, time: Bool = false, help: String? = nil) -> some View {
        MultiplayerSummaryLine(label: label, value: value, monospaced: mono, isTime: time)
            .textSelection(.enabled)
            .help(help ?? (mono ? value : ""))
    }

    private func sentence(_ text: String) -> some View {
        Text(text).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A grant: the tool, the checkout it is granted to, and its settings as a form made from the
/// plugin's schema or as JSON. Save checks the settings here first and shows each problem beside
/// its field; the service checks again and its refusal is shown above the buttons.
struct PluginGrantSheet: View {
    let draft: PluginGrantDraft
    let projects: [PluginProject]
    let actions: PluginActions
    @Environment(\.theme) private var theme

    private func edit(_ change: (inout PluginGrantDraft) -> Void) {
        var next = draft
        change(&next)
        actions.editDraft(next)
    }

    private var input: Binding<PluginSettingsInput> {
        Binding(get: { draft.values }, set: { values in edit { $0.values = values } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                IconTile(symbol: "puzzlepiece.extension", size: 31)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(draft.title) · \(draft.pluginName)").themeType(theme.type.title).foregroundStyle(.theme(\.color.foreground))
                        .lineLimit(1).accessibilityAddTraits(.isHeader)
                    Text("\(draft.toolID)@\(draft.toolVersion)").themeType(theme.type.mono).foregroundStyle(.theme(\.color.secondary))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space.sectionInset).padding(.vertical, Space.m)
            ThemeRule()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    project
                    settings
                }
            }
            .frame(maxHeight: 460)
            if let error = draft.serverError {
                ThemeRule()
                Text(error).themeType(theme.type.sub).foregroundStyle(.theme(\.color.failure))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, theme.space.sectionInset).padding(.vertical, Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color.failure.color.opacity(0.12))
                    .accessibilityIdentifier("plugin-grant-server-error")
            }
            HStack(spacing: Space.s) {
                Text(draft.hasProblems ? "Fix what is marked, then save again." : "Applies when the service restarts.")
                    .themeType(theme.type.sub).foregroundStyle(.theme(draft.hasProblems ? \.color.failure : \.color.secondary))
                    .lineLimit(2)
                Spacer(minLength: Space.s)
                Button("Cancel") { actions.closeGrant() }
                    .buttonStyle(ThemeButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(draft.isSaving)
                Button { actions.saveGrant() } label: {
                    Label(draft.isSaving ? "Saving…" : draft.isEdit ? "Save" : "Grant", systemImage: "checkmark")
                }
                .buttonStyle(ThemeButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(draft.isSaving)
                .accessibilityIdentifier("plugin-grant-save")
            }
            .padding(.horizontal, theme.space.sectionInset).padding(.vertical, Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface.footerFill.color)
        }
        .frame(width: PluginLayout.sheetWidth)
        .themePanel()
        .accessibilityIdentifier("plugin-grant-sheet")
    }

    @ViewBuilder private var project: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                ThemeHeading(text: "Project").accessibilityAddTraits(.isHeader)
                if draft.isEdit {
                    MultiplayerSummaryLine(label: "Name", value: PluginProject.name(of: draft.project))
                    MultiplayerSummaryLine(label: "Path", value: draft.project, monospaced: true).help(draft.project)
                } else {
                    MultiplayerField(label: "Checkout", hint: "The absolute path of an existing directory. Agents working in it can call the tool.",
                                     problem: draft.projectProblem) {
                        VStack(alignment: .leading, spacing: Space.s) {
                            if !projects.isEmpty {
                                MultiplayerMenuField(label: "Known projects", placeholder: "Choose a project",
                                                     options: projects.map { (value: $0.path, title: $0.name) },
                                                     selection: Binding(get: { draft.project }, set: { path in edit { $0.project = path; $0.projectProblem = nil } }))
                                    .accessibilityIdentifier("plugin-grant-project-menu")
                            }
                            HStack(spacing: Space.s) {
                                MultiplayerTextField(label: "Project path", placeholder: "/Users/me/repo",
                                                     text: Binding(get: { draft.project }, set: { path in edit { $0.project = path; $0.projectProblem = nil } }),
                                                     monospaced: true)
                                    .accessibilityIdentifier("plugin-grant-project-path")
                                Button("Choose folder…") { chooseFolder() }
                                    .buttonStyle(ThemeButtonStyle())
                                    .accessibilityIdentifier("plugin-grant-choose-folder")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var settings: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    ThemeHeading(text: "Settings").accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Space.s)
                    if let schema = draft.schema, schema.isFormable {
                        MultiplayerSegments(label: "Settings editor", options: [PluginGrantDraft.Editor.form, .json],
                                            title: { $0 == .form ? "Form" : "JSON" },
                                            selection: Binding(get: { draft.editor }, set: { editor in edit { $0.choose(editor) } }))
                            .frame(width: 132)
                    }
                }
                if let schema = draft.schema {
                    if let general = draft.problems[PluginSettingsSchema.general] {
                        Label(general, systemImage: "exclamationmark.circle")
                            .themeType(theme.type.sub).foregroundStyle(.theme(\.color.failure))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("plugin-grant-problem")
                    }
                    switch draft.editor {
                    case .form:
                        ForEach(schema.fields) { field in
                            PluginSettingField(field: field, input: input, problem: draft.problems[field.name])
                        }
                    case .json:
                        if let reason = schema.rawReason {
                            Text(reason).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        PluginBufferedTextArea(label: "Settings as JSON",
                                            text: Binding(get: { draft.json }, set: { text in edit { $0.json = text } }), lines: 10)
                            .accessibilityIdentifier("plugin-grant-json")
                    }
                } else {
                    Text("\(draft.pluginName) takes no settings. The grant only names the project.")
                        .themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use project"
        if draft.project.hasPrefix("/") { panel.directoryURL = URL(filePath: draft.project, directoryHint: .isDirectory) }
        if panel.runModal() == .OK, let url = panel.url {
            edit { $0.project = url.standardizedFileURL.path; $0.projectProblem = nil }
        }
    }
}

// MARK: - Page

struct PluginsPage: View {
    /// The place whose plugins are listed (`PluginPlace`).
    let place: String
    var crumbs: [String] = ["Plugins"]
    let context: PluginsContext
    /// The plugin in the inspector. Nil shows the place's first.
    @Binding var shown: String?
    /// Opens a plugin's own panel by its place.
    var openPanel: ((String) -> Void)? = nil
    @Environment(\.theme) private var theme

    private var listed: [Plugin] { PluginPlace.plugins(context.plugins, in: place) }
    private var plugin: Plugin? { listed.first { $0.id == shown } ?? listed.first }

    private var summary: String {
        if context.isUnavailable { return "The tool plugins installed on this Mac, and the projects each tool is granted to." }
        if context.isLoading { return "Reading the plugins on this Mac…" }
        let tally = context.tally.summary
        return context.link == .stale ? "\(tally). The service didn’t answer; this is the last list it sent." : "\(tally)."
    }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: crumbs.map { $0.uppercased() }.joined(separator: " / "), title: "Plugins", subtitle: summary) {
                Button { Task { await context.actions.refresh(plugin?.id) } } label: {
                    Label(context.isRefreshing ? "Reading…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ThemeButtonStyle())
                .disabled(context.isRefreshing || context.isUnavailable || context.isLoading)
                .help("Read the plugins and their grants again")
                .accessibilityIdentifier("plugins-refresh")
            }
        } content: {
            if context.isUnavailable {
                unavailable
            } else if context.isLoading {
                ShellNote(text: "Reading the plugins on this Mac…", lamp: .waiting).themePanel()
            } else {
                if context.restartRequired {
                    Callout(symbol: "arrow.clockwise.circle", title: "Restart the service to apply",
                            detail: "Grants and plugin changes are saved, but the running service still uses what it read when it started. Rows marked “At restart” take effect then.",
                            tone: .attention)
                        .accessibilityIdentifier("plugins-restart-note")
                }
                NetworkSplit {
                    PluginList(title: PluginPlace.title(place), plugins: listed, empty: PluginPlace.emptyNote(place),
                               shown: plugin?.id) { shown = $0 }
                } inspector: {
                    if let plugin {
                        PluginDetail(plugin: plugin, busy: context.busy, failure: context.failures[plugin.id],
                                     log: context.logs[plugin.id] ?? PluginLogState(), restartRequired: context.restartRequired,
                                     actions: context.actions,
                                     openPanel: plugin.id == MQTTBridge.pluginID && openPanel != nil ? { openPanel?(PluginPlace.mqtt) } : nil)
                            // The log is read for the plugin on screen, once each time it is chosen.
                            .task(id: plugin.id) { await context.actions.readLog(plugin.id) }
                    } else {
                        NetworkInspectorNote(text: "Choose a plugin to see its tools, grants and log.")
                    }
                }
            }
        }
        .accessibilityIdentifier("plugins-page")
    }

    /// The service has no plugin routes yet, or can't be reached: say so calmly, and offer one way on.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShellNote(text: "Plugins are unavailable. The service on this Mac didn’t answer, or doesn’t report plugins yet. Agent Commander keeps trying.",
                      lamp: .error)
            Button("Try again") { context.actions.retry() }
                .buttonStyle(ThemeButtonStyle())
                .padding(.horizontal, Space.m).padding(.bottom, theme.space.bandBottom)
                .accessibilityIdentifier("plugins-retry")
        }
        .frame(maxWidth: 540, alignment: .leading)
        .themePanel()
    }
}
