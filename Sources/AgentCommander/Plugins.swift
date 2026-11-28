import Foundation
import Observation
import SwiftUI

// Plugins: the tool plugins installed on this Mac, the projects each tool is granted to, and the
// plugin's own log (design/PLUGINS.md, increment 2).
//
//   Values         Plugin, PluginTool, PluginGrant   one plugin as the service reports it
//                  PluginLog            the end of a plugin's plugin.log
//                  PluginProject        a checkout a tool can be granted to
//                  PluginGrantDraft     the grant being written: tool, project and settings
//                  PluginTally          the counts the navigation shows
//                  PluginPlace          the mode's places and how the plugins fall into them
//   Reading        PluginSnapshot       reads `{"restart_required":…,"plugins":[…]}` and a log
//   Feature model  PluginFeed           every call to /v1/plugins, the open grant and the logs
//   For the page   PluginsContext       the feed's state as values, and its intents (PluginActions)
//
// The page (PluginsPage.swift) takes values and emits actions. Only `PluginsContext.init(feed:)`
// reads the model. The settings form and its checks are in PluginSettingsSchema.swift.

// MARK: - Values

struct PluginGrant: Identifiable, Equatable, Sendable {
    /// The absolute path of the checkout.
    var project: String
    var version = 1
    /// The grant's settings. Nil when it carries none.
    var settings: AGUIValue? = nil
    /// The running service loaded this grant as it is written. False until the next restart.
    var active = true

    var id: String { project }
    /// The checkout's folder name.
    var projectName: String { PluginProject.name(of: project) }
}

struct PluginTool: Identifiable, Equatable, Sendable {
    let id: String
    var version = 1
    var mcpTool = ""
    var description = ""
    var grants: [PluginGrant] = []
}

struct Plugin: Identifiable, Equatable, Sendable {
    let id: String
    var version = ""
    var name: String
    var description = ""
    var installedAt: Date? = nil
    var digest = ""
    /// Why the service refuses the plugin. Empty when it is healthy.
    var problem = ""
    /// The JSON Schema a grant's settings must match. Nil when grants carry no settings.
    var settingsSchema: AGUIValue? = nil
    /// The running service loaded this version. False when it was installed or changed since.
    var loaded = true
    var tools: [PluginTool] = []

    var hasProblem: Bool { !problem.isEmpty }
    var grantCount: Int { tools.reduce(0) { $0 + $1.grants.count } }
    /// Grants written but not yet loaded by the running service.
    var pendingGrantCount: Int { tools.reduce(0) { $0 + $1.grants.filter { !$0.active }.count } }

    /// The state as the row and the inspector say it.
    var state: (title: String, tone: Tone, lamp: MultiplayerLamp.Kind, symbol: String) {
        if hasProblem { return ("Refused", .failure, .error, "exclamationmark.octagon.fill") }
        if !loaded { return ("Loads at restart", .attention, .busy, "arrow.clockwise.circle.fill") }
        return ("Loaded", .working, .on, "checkmark.circle.fill")
    }

    /// "adag.mqtt · 3 tools".
    var kindLine: String { "\(id) · \(Self.count(tools.count, "tool"))" }

    /// What VoiceOver says for the row.
    var spoken: String {
        "\(name), \(id), \(state.title), version \(version.isEmpty ? "unknown" : version), \(Self.count(tools.count, "tool")), \(Self.count(grantCount, "grant"))"
    }

    static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }

    /// The digest cut short for a line: "sha256:9f2c41d07a…".
    var shortDigest: String {
        guard let colon = digest.firstIndex(of: ":") else { return String(digest.prefix(18)) }
        let hash = digest[digest.index(after: colon)...]
        return hash.count > 12 ? "\(digest[...colon])\(hash.prefix(12))…" : digest
    }
}

/// The end of a plugin's log, as the service read it.
struct PluginLog: Equatable, Sendable {
    var path = ""
    var text = ""
    var size = 0
    /// The file is longer than what `text` holds.
    var truncated = false

    var isEmpty: Bool { text.isEmpty }

    /// "12.1 KB, showing the end".
    var sizeLine: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return truncated ? "\(size), showing the end" : size
    }
}

/// What the page knows about one plugin's log.
struct PluginLogState: Equatable, Sendable {
    var log: PluginLog? = nil
    var isLoading = false
    var failure: String? = nil
}

/// A checkout a tool can be granted to.
struct PluginProject: Identifiable, Hashable, Sendable {
    let path: String
    var name: String

    var id: String { path }

    init(path: String, name: String? = nil) {
        self.path = path
        self.name = name ?? Self.name(of: path)
    }

    static func name(of path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }

    /// The checkouts the grant form offers: the cockpit's own first, then every checkout a
    /// plugin tool is already granted to, each once.
    static func choices(known: [PluginProject], plugins: [Plugin]) -> [PluginProject] {
        var seen = Set<String>()
        let granted = plugins.flatMap(\.tools).flatMap(\.grants).map { PluginProject(path: $0.project) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (known + granted).filter { !$0.path.isEmpty && seen.insert($0.path).inserted }
    }
}

/// The grant being written: one tool, one checkout, and its settings. It is the open sheet.
struct PluginGrantDraft: Identifiable, Equatable, Sendable {
    enum Editor: String, Sendable { case form, json }

    let pluginID: String
    let pluginName: String
    let toolID: String
    let toolVersion: Int
    /// The checkout's absolute path. Fixed when an existing grant is being changed.
    var project = ""
    let isEdit: Bool
    /// The settings fields. Nil when the plugin's grants carry no settings.
    let schema: PluginSettingsSchema?
    var editor: Editor = .form
    /// What the form holds, by field name.
    var values = PluginSettingsInput()
    /// What the JSON editor holds.
    var json = "{}"
    /// What the last Save found, by field name. `PluginSettingsSchema.general` is the whole form's.
    var problems: [String: String] = [:]
    var projectProblem: String? = nil
    /// The service's own refusal.
    var serverError: String? = nil
    var isSaving = false

    var id: String { "\(toolID)|\(isEdit ? project : "new")" }
    var title: String { isEdit ? "Edit grant" : "Grant tool" }
    var hasProblems: Bool { !problems.isEmpty || projectProblem != nil }

    init(plugin: Plugin, tool: PluginTool, grant: PluginGrant? = nil) {
        pluginID = plugin.id
        pluginName = plugin.name
        toolID = tool.id
        toolVersion = tool.version
        isEdit = grant != nil
        project = grant?.project ?? ""
        schema = plugin.settingsSchema.map(PluginSettingsSchema.init)
        let settings = grant?.settings ?? .object([:])
        json = settings.prettyText
        if let schema, schema.isFormable, let input = schema.input(from: settings) {
            values = input
            editor = .form
        } else {
            editor = .json
        }
    }

    /// Switches between the form and the JSON editor, carrying what was entered across. A JSON
    /// text the form can't hold stays in the JSON editor and says why.
    mutating func choose(_ next: Editor) {
        guard next != editor, let schema else { return }
        switch next {
        case .json:
            json = schema.draftValue(from: values).prettyText
            problems = [:]
            editor = .json
        case .form:
            guard schema.isFormable else { return }
            guard let value = try? AGUIValue(json: json), let input = schema.input(from: value) else {
                problems = [PluginSettingsSchema.general: "The form can’t show this JSON. Fix it here, or clear it to start over."]
                return
            }
            values = input
            problems = [:]
            editor = .form
        }
    }

    /// Checks the draft the way the service will. On success it returns the settings to send:
    /// nil when the plugin takes none. On failure the draft holds the problems.
    mutating func validated() -> Result<AGUIValue?, PluginSettingsProblems> {
        serverError = nil
        problems = [:]
        projectProblem = Self.projectProblem(project)
        var found = PluginSettingsProblems()
        var settings: AGUIValue? = nil
        if let schema {
            switch editor {
            case .form:
                switch schema.value(from: values) {
                case .success(let value): settings = value
                case .failure(let problems): found = problems
                }
            case .json:
                switch schema.value(fromJSON: json) {
                case .success(let value): settings = value
                case .failure(let problems): found = problems
                }
            }
        }
        problems = found.byField
        guard projectProblem == nil, found.isEmpty else {
            if let projectProblem { found.byField["project"] = projectProblem }
            return .failure(found)
        }
        // An empty object says nothing: the grant is sent without settings.
        if let value = settings, value.objectValue?.isEmpty == true { settings = nil }
        return .success(settings)
    }

    /// Why a path can't be granted to. The service checks that the directory exists.
    static func projectProblem(_ path: String) -> String? {
        let path = path.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return "Choose a project." }
        if !path.hasPrefix("/") { return "Use an absolute path, such as /Users/me/repo." }
        return nil
    }
}

struct PluginTally: Equatable, Sendable {
    var installed = 0
    var problems = 0
    var tools = 0
    var grants = 0
    /// The MQTT Bridge plugin is installed, so its panel has a place.
    var hasMQTT = false

    init() {}

    init(_ plugins: [Plugin]) {
        installed = plugins.count
        problems = plugins.filter(\.hasProblem).count
        tools = plugins.reduce(0) { $0 + $1.tools.count }
        grants = plugins.reduce(0) { $0 + $1.grantCount }
        hasMQTT = plugins.contains { $0.id == MQTTBridge.pluginID }
    }

    /// "2 installed, 5 tools, 3 grants, 1 refused".
    var summary: String {
        guard installed > 0 else { return "No plugin is installed" }
        var parts = ["\(installed) installed", Plugin.count(tools, "tool"), Plugin.count(grants, "grant")]
        if problems > 0 { parts.append("\(problems) refused") }
        return parts.joined(separator: ", ")
    }
}

/// The Plugins mode's places.
enum PluginPlace {
    static let mode = "plugins"
    static let problems = "plugins.problems"
    static let installed = "plugins.installed"
    /// The MQTT Bridge plugin's own panel (MQTTPanel.swift).
    static let mqtt = "plugins.mqtt"

    static func hasPage(_ id: String) -> Bool { id == problems || id == installed || id == mqtt }
    static func isPanel(_ id: String) -> Bool { id == mqtt }

    static func title(_ id: String) -> String {
        switch id {
        case problems: "Problems"
        case mqtt: "MQTT"
        default: "Installed"
        }
    }

    /// The mode's places. Problems is listed only while a plugin is refused, and a plugin's panel
    /// only while that plugin is installed.
    static func places(_ tally: PluginTally) -> [CommanderPlace] {
        var places: [CommanderPlace] = []
        if tally.problems > 0 {
            places.append(CommanderPlace(id: problems, title: title(problems), mark: .symbol("exclamationmark.octagon"),
                                         count: tally.problems, isHot: true, isDetail: true, countNoun: "refused"))
        }
        places.append(CommanderPlace(id: installed, title: title(installed), mark: .symbol("puzzlepiece.extension"),
                                     count: tally.installed, isDetail: true, countNoun: "installed"))
        if tally.hasMQTT {
            places.append(CommanderPlace(id: mqtt, title: title(mqtt), mark: .symbol("dot.radiowaves.left.and.right"), isDetail: true))
        }
        return places
    }

    /// The rail cell and its context list. Its hot count is the Problems place's.
    static func mode(_ tally: PluginTally) -> CommanderMode {
        var sections = [CommanderPlaceGroup(id: mode, title: "Plugins",
                                            placeIDs: places(tally).map(\.id).filter { !isPanel($0) })]
        if tally.hasMQTT { sections.append(CommanderPlaceGroup(id: "plugins.panels", title: "Panels", placeIDs: [mqtt])) }
        return CommanderMode(id: mode, title: "Plugins", symbol: "puzzlepiece.extension", sections: sections)
    }

    /// The plugins a place lists, by name.
    static func plugins(_ all: [Plugin], in place: String) -> [Plugin] {
        let listed = place == problems ? all.filter(\.hasProblem) : all
        return listed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What an empty place says.
    static func emptyNote(_ place: String) -> (text: String, lamp: MultiplayerLamp.Kind) {
        switch place {
        case problems: ("Every installed plugin passed its check.", .on)
        default: ("No plugin is installed yet. Install one with agentctl plugin install <directory>.", .off)
        }
    }
}

// MARK: - Reading

/// What `GET /v1/plugins` and both grant routes answer.
struct PluginInventory: Equatable, Sendable {
    var restartRequired = false
    var plugins: [Plugin] = []
}

enum PluginSnapshot {
    private struct Envelope: Decodable {
        let restart_required: Bool?
        let plugins: [PluginWire]?
    }

    private struct PluginWire: Decodable {
        let id: String?
        let version: String?
        let name: String?
        let description: String?
        let installed_at: String?
        let digest: String?
        let problem: String?
        let settings_schema: AGUIValue?
        let loaded: Bool?
        let tools: [ToolWire]?
    }

    private struct ToolWire: Decodable {
        let id: String?
        let version: Int?
        let mcp_tool: String?
        let description: String?
        let grants: [GrantWire]?
    }

    private struct GrantWire: Decodable {
        let project: String?
        let version: Int?
        let settings: AGUIValue?
        let active: Bool?
    }

    private struct LogWire: Decodable {
        let path: String?
        let text: String?
        let size: Int?
        let truncated: Bool?
    }

    /// Reads the list. A plugin or tool without an ID is skipped; a missing field takes its
    /// quiet default, so a field the app doesn't know never fails the read.
    static func decode(_ data: Data) throws -> PluginInventory {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let plugins = (envelope.plugins ?? []).compactMap { wire -> Plugin? in
            guard let id = wire.id, !id.isEmpty else { return nil }
            var plugin = Plugin(id: id, name: wire.name?.isEmpty == false ? wire.name! : id)
            plugin.version = wire.version ?? ""
            plugin.description = wire.description ?? ""
            plugin.installedAt = HarnessSnapshot.date(wire.installed_at)
            plugin.digest = wire.digest ?? ""
            plugin.problem = wire.problem ?? ""
            // `null` and a schema that is not an object both mean "no settings".
            if let schema = wire.settings_schema, schema.objectValue != nil { plugin.settingsSchema = schema }
            plugin.loaded = wire.loaded ?? true
            plugin.tools = (wire.tools ?? []).compactMap { tool -> PluginTool? in
                guard let id = tool.id, !id.isEmpty else { return nil }
                let grants = (tool.grants ?? []).compactMap { grant -> PluginGrant? in
                    guard let project = grant.project, !project.isEmpty else { return nil }
                    let settings = grant.settings.flatMap { $0.isNull ? nil : $0 }
                    return PluginGrant(project: project, version: grant.version ?? tool.version ?? 1,
                                       settings: settings, active: grant.active ?? true)
                }
                return PluginTool(id: id, version: tool.version ?? 1, mcpTool: tool.mcp_tool ?? "",
                                  description: tool.description ?? "", grants: grants)
            }
            return plugin
        }
        return PluginInventory(restartRequired: envelope.restart_required ?? false, plugins: plugins)
    }

    static func decodeLog(_ data: Data) throws -> PluginLog {
        let wire = try JSONDecoder().decode(LogWire.self, from: data)
        return PluginLog(path: wire.path ?? "", text: wire.text ?? "", size: wire.size ?? 0, truncated: wire.truncated ?? false)
    }

    /// The body of a grant: `settings` is left out when there are none.
    static func grantBody(tool: String, version: Int, project: String, settings: AGUIValue?) -> Data {
        var body: [String: AGUIValue] = ["tool": .string(tool), "version": .number(AGUINumber(version)), "project": .string(project)]
        if let settings { body["settings"] = settings }
        return Data(AGUIValue.object(body).compactText.utf8)
    }

    static func revokeBody(tool: String, project: String) -> Data {
        Data(AGUIValue.object(["tool": .string(tool), "project": .string(project)]).compactText.utf8)
    }
}

// MARK: - Feature model

/// The service's plugin routes, as the feed calls them.
struct PluginAPI: Sendable {
    var list: @Sendable () async throws -> PluginInventory
    var grant: @Sendable (_ tool: String, _ version: Int, _ project: String, _ settings: AGUIValue?) async throws -> PluginInventory
    var revoke: @Sendable (_ tool: String, _ project: String) async throws -> PluginInventory
    var log: @Sendable (_ pluginID: String) async throws -> PluginLog
}

/// The installed plugins and their grants, with every call the Plugins mode makes. The service
/// has no plugin stream: the list is read when the window opens, when the app comes forward,
/// on Refresh, and it is replaced by the answer of every grant and revoke.
@Observable @MainActor
final class PluginFeed {
    enum Link: Equatable {
        case connecting
        case live
        /// The last read failed after a list arrived. The last list is still shown.
        case stale
        /// The service has no plugin routes, or can't be reached, and nothing was ever read.
        case unavailable
    }

    private(set) var plugins: [Plugin] = []
    private(set) var restartRequired = false
    private(set) var link: Link = .connecting
    private(set) var isRefreshing = false
    /// Grants with a revoke in flight, as `PluginFeed.key`.
    private(set) var busy = Set<String>()
    /// Why the last call for a plugin didn't go through, by plugin ID.
    private(set) var failures: [String: String] = [:]
    /// Each plugin's log, once asked for.
    private(set) var logs: [String: PluginLogState] = [:]
    /// The grant the window shows in a sheet.
    var draft: PluginGrantDraft?

    @ObservationIgnored private let api: PluginAPI?
    @ObservationIgnored private var lastCall = 0
    @ObservationIgnored private var pause: Task<Void, Never>?
    @ObservationIgnored private var lastQuietRead = Date.distantPast

    init(api: PluginAPI) { self.api = api }

    /// A fixed list for previews and fixtures. It never connects, and its actions change the
    /// list in place.
    init(fixture plugins: [Plugin], restartRequired: Bool = false, logs: [String: PluginLog] = [:], link: Link = .live) {
        api = nil
        self.plugins = plugins
        self.restartRequired = restartRequired
        self.logs = logs.mapValues { PluginLogState(log: $0) }
        self.link = link
    }

    var tally: PluginTally { PluginTally(plugins) }

    func plugin(_ id: String) -> Plugin? { plugins.first { $0.id == id } }

    static func key(tool: String, project: String) -> String { "\(tool)|\(project)" }

    // MARK: Reading

    /// Reads the list, and reads again after a pause for as long as the service doesn't answer.
    /// It returns once a list arrived. The newest call wins.
    func follow() async {
        guard let api else { return }
        lastCall += 1
        let call = lastCall
        var failed = 0
        while !Task.isCancelled, call == lastCall {
            do {
                let list = try await api.list()
                guard call == lastCall else { return }
                apply(list)
                return
            } catch {
                guard !Task.isCancelled, call == lastCall else { return }
                link = plugins.isEmpty && link != .live && link != .stale ? .unavailable : .stale
                failed += 1
                let wait = Task { _ = try? await Task.sleep(for: AdapterUpdateFeed.delay(afterFailures: failed)) }
                pause = wait
                await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
            }
        }
    }

    /// Asks again now instead of waiting out the pause between attempts.
    func retry() {
        if link == .unavailable { link = .connecting }
        pause?.cancel()
    }

    /// Replaces the list with what the service answered.
    func apply(_ list: PluginInventory) {
        plugins = list.plugins
        restartRequired = list.restartRequired
        link = .live
        let known = Set(plugins.map(\.id))
        failures = failures.filter { known.contains($0.key) }
        logs = logs.filter { known.contains($0.key) }
    }

    /// Reads the list again, and the log of the plugin on screen.
    func refresh(showing pluginID: String? = nil) async {
        guard let api, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            apply(try await api.list())
        } catch {
            link = link == .live || link == .stale ? .stale : .unavailable
        }
        if let pluginID { await readLog(pluginID) }
    }

    /// The app came forward: read again, at most once in half a minute. `agentctl plugin install`
    /// and `grant` run outside the app, so the list may have changed.
    func refreshOnActivation(now: Date = .now) {
        guard api != nil, link == .live || link == .stale, now.timeIntervalSince(lastQuietRead) > 30 else { return }
        lastQuietRead = now
        Task { await refresh() }
    }

    func readLog(_ pluginID: String) async {
        guard let api else { return }
        guard logs[pluginID]?.isLoading != true else { return }
        logs[pluginID, default: PluginLogState()].isLoading = true
        do {
            logs[pluginID] = PluginLogState(log: try await api.log(pluginID))
        } catch {
            logs[pluginID] = PluginLogState(log: logs[pluginID]?.log, failure: HarnessFeed.sentence("Couldn’t read the log.", error))
        }
    }

    // MARK: Grants

    /// Opens the grant sheet for a tool: a new grant, or an existing one's settings.
    func openGrant(pluginID: String, toolID: String, project: String? = nil) {
        guard let plugin = plugin(pluginID), let tool = plugin.tools.first(where: { $0.id == toolID }) else { return }
        draft = PluginGrantDraft(plugin: plugin, tool: tool, grant: project.flatMap { path in tool.grants.first { $0.project == path } })
    }

    func closeGrant() {
        guard draft?.isSaving != true else { return }
        draft = nil
    }

    /// Checks the open draft against the schema, then sends it. The service checks again: its
    /// refusal stays in the sheet.
    func saveGrant() async {
        guard var next = draft, !next.isSaving else { return }
        next.project = next.project.trimmingCharacters(in: .whitespaces)
        guard case .success(let settings) = next.validated() else {
            draft = next
            return
        }
        next.isSaving = true
        draft = next
        guard let api else {
            // A fixture has no service: it writes the grant into its own list.
            placeFixtureGrant(next, settings)
            draft = nil
            return
        }
        do {
            apply(try await api.grant(next.toolID, next.toolVersion, next.project, settings))
            failures[next.pluginID] = nil
            draft = nil
        } catch {
            next.isSaving = false
            next.serverError = HarnessFeed.sentence("The service refused the grant.", error)
            // The sheet may have been edited or closed while the call ran.
            if draft?.id == next.id { draft?.isSaving = false; draft?.serverError = next.serverError }
        }
    }

    func revoke(pluginID: String, toolID: String, project: String) async {
        let key = Self.key(tool: toolID, project: project)
        guard !busy.contains(key) else { return }
        guard let api else {
            edit(pluginID, toolID) { $0.grants.removeAll { $0.project == project } }
            restartRequired = true
            return
        }
        busy.insert(key)
        failures[pluginID] = nil
        defer { busy.remove(key) }
        do {
            apply(try await api.revoke(toolID, project))
        } catch {
            failures[pluginID] = HarnessFeed.sentence("Couldn’t revoke the grant.", error)
        }
    }

    private func placeFixtureGrant(_ draft: PluginGrantDraft, _ settings: AGUIValue?) {
        edit(draft.pluginID, draft.toolID) { tool in
            let grant = PluginGrant(project: draft.project, version: draft.toolVersion, settings: settings, active: false)
            if let index = tool.grants.firstIndex(where: { $0.project == draft.project }) { tool.grants[index] = grant } else { tool.grants.append(grant) }
        }
        restartRequired = true
    }

    private func edit(_ pluginID: String, _ toolID: String, _ change: (inout PluginTool) -> Void) {
        guard let plugin = plugins.firstIndex(where: { $0.id == pluginID }),
              let tool = plugins[plugin].tools.firstIndex(where: { $0.id == toolID }) else { return }
        change(&plugins[plugin].tools[tool])
    }
}

// MARK: - For the page

/// What the Plugins mode can ask for.
struct PluginActions {
    var refresh: @MainActor (_ showing: String?) async -> Void = { _ in }
    var retry: @MainActor () -> Void = {}
    var readLog: @MainActor (_ pluginID: String) async -> Void = { _ in }
    var openGrant: @MainActor (_ pluginID: String, _ toolID: String, _ project: String?) -> Void = { _, _, _ in }
    var editDraft: @MainActor (PluginGrantDraft) -> Void = { _ in }
    var saveGrant: @MainActor () -> Void = {}
    var closeGrant: @MainActor () -> Void = {}
    var revoke: @MainActor (_ pluginID: String, _ toolID: String, _ project: String) -> Void = { _, _, _ in }
}

/// The feed's state as the window shows it, and its intents.
struct PluginsContext {
    var plugins: [Plugin] = []
    var restartRequired = false
    var link: PluginFeed.Link = .live
    var isRefreshing = false
    var busy = Set<String>()
    var failures: [String: String] = [:]
    var logs: [String: PluginLogState] = [:]
    var draft: PluginGrantDraft? = nil
    /// The checkouts the cockpit knows, offered first in the grant form.
    var projects: [PluginProject] = []
    var actions = PluginActions()

    init() {}

    /// Reads the feed. Every property read here is observed by the view that calls it.
    @MainActor init(feed: PluginFeed, projects: [PluginProject] = []) {
        plugins = feed.plugins
        restartRequired = feed.restartRequired
        link = feed.link
        isRefreshing = feed.isRefreshing
        busy = feed.busy
        failures = feed.failures
        logs = feed.logs
        draft = feed.draft
        self.projects = PluginProject.choices(known: projects, plugins: feed.plugins)
        actions = PluginActions(
            refresh: { await feed.refresh(showing: $0) },
            retry: { feed.retry() },
            readLog: { await feed.readLog($0) },
            openGrant: { plugin, tool, project in feed.openGrant(pluginID: plugin, toolID: tool, project: project) },
            editDraft: { draft in if feed.draft?.isSaving != true { feed.draft = draft } },
            saveGrant: { Task { await feed.saveGrant() } },
            closeGrant: { feed.closeGrant() },
            revoke: { plugin, tool, project in Task { await feed.revoke(pluginID: plugin, toolID: tool, project: project) } })
    }

    var tally: PluginTally { PluginTally(plugins) }

    /// Nothing was ever read and the service doesn't answer.
    var isUnavailable: Bool { link == .unavailable && plugins.isEmpty }
    var isLoading: Bool { link == .connecting && plugins.isEmpty }
}

// MARK: - Fixtures

/// FIXTURE ONLY. The sample plugins behind the design preview and the headless pictures.
enum PluginFixture {
    static let now = Date(timeIntervalSince1970: 1_795_809_600)   // 2026-11-27 20:00 UTC

    static let mqttSchema: AGUIValue = [
        "type": "object", "additionalProperties": false,
        "properties": ["topics": [
            "type": "array", "maxItems": 32,
            "items": ["type": "string", "minLength": 1, "maxLength": 256],
            "description": "MQTT topic filters this project may read, such as plant/line1/#. Omit to allow every topic."
        ]]
    ]

    static let jiraSchema: AGUIValue = [
        "type": "object", "additionalProperties": false, "required": ["site"],
        "properties": [
            "site": ["type": "string", "minLength": 2, "maxLength": 40, "description": "The Jira site name, as in <site>.atlassian.net."],
            "max_results": ["type": "integer", "minimum": 1, "maximum": 100, "description": "The most issues one search returns."],
            "include_comments": ["type": "boolean", "description": "Return an issue’s comments with it."],
            "detail": ["type": "string", "enum": ["summary", "full"], "description": "How much of an issue is returned."]
        ]
    ]

    static var plugins: [Plugin] {
        var mqtt = Plugin(id: MQTTBridge.pluginID, name: "MQTT Bridge")
        mqtt.version = "0.1.0"
        mqtt.description = "Read what a local MQTT broker carries: its topics, the latest message of each, and recent messages."
        mqtt.installedAt = now.addingTimeInterval(-3 * 3600)
        mqtt.digest = "sha256:9f2c41d07a3be8c15d0e6a7714bb02f3c4a9e1d55f0b6c2a8e73d9146a0c5b21"
        mqtt.settingsSchema = mqttSchema
        mqtt.tools = [
            PluginTool(id: "adag.mqtt.list_topics", version: 1, mcpTool: "list_topics",
                       description: "List the topics the bridge has seen, with a count and the last message of each.",
                       grants: [PluginGrant(project: "/Users/me/Developer/relay", settings: ["topics": ["plant/#"]]),
                                PluginGrant(project: "/Users/me/Developer/beacon", active: false)]),
            PluginTool(id: "adag.mqtt.read_messages", version: 1, mcpTool: "read_messages",
                       description: "Read recent messages that match a topic filter.",
                       grants: [PluginGrant(project: "/Users/me/Developer/relay", settings: ["topics": ["plant/#"]])]),
            PluginTool(id: "adag.mqtt.broker_status", version: 1, mcpTool: "broker_status",
                       description: "The broker’s address, uptime and counters.")
        ]

        var jira = Plugin(id: "acme.jira", name: "Jira lookups")
        jira.version = "1.2.0"
        jira.description = "Look up Jira issues by key or search."
        jira.installedAt = now.addingTimeInterval(-9 * 86_400)
        jira.digest = "sha256:41c8e0aa9d1f5b7e2c36a8804f1d7e92b05c6d3a1e4f7b8c9d0a2b3c4d5e6f70"
        jira.settingsSchema = jiraSchema
        jira.tools = [
            PluginTool(id: "acme.jira.get_issue", version: 1, mcpTool: "get_issue", description: "Read one issue by its key.",
                       grants: [PluginGrant(project: "/Users/me/Developer/relay", settings: ["site": "acme", "max_results": 25])]),
            PluginTool(id: "acme.jira.search", version: 2, mcpTool: "search", description: "Search issues with JQL.")
        ]

        var hello = Plugin(id: "example.hello", name: "Hello")
        hello.version = "0.3.1"
        hello.description = "The example plugin from examples/plugins/hello."
        hello.installedAt = now.addingTimeInterval(-40 * 86_400)
        hello.digest = "sha256:c07d2f9b6e5a4c3d2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a29181706"
        hello.problem = "plugin example.hello 0.3.1 refused: installed files do not match digest sha256:c07d2f9b6e5a (server.mjs changed). Reinstall it with agentctl plugin install."
        hello.tools = [
            PluginTool(id: "example.hello.greet", version: 1, mcpTool: "greet", description: "Say hello to a name.",
                       grants: [PluginGrant(project: "/Users/me/Developer/beacon")])
        ]
        return [mqtt, jira, hello]
    }

    static let log = PluginLog(
        path: "/Users/me/Library/Application Support/Agent Commander/plugins/adag.mqtt/plugin.log",
        text: """
        2026-11-27T19:58:02Z mqtt plugin 0.1.0 starting
        2026-11-27T19:58:02Z bridge http://127.0.0.1:18830 reachable, broker 127.0.0.1:1885
        2026-11-27T19:58:02Z initialize: protocol 2025-06-18
        2026-11-27T19:58:41Z list_topics project=/Users/me/Developer/relay filters=[plant/#] → 7 topics
        2026-11-27T19:59:10Z read_messages project=/Users/me/Developer/relay filter=plant/line1/# limit=50 → 50 messages
        2026-11-27T19:59:10Z read_messages: filter plant/office/# is outside the granted topics, refused
        2026-11-27T20:00:04Z idle
        """,
        size: 12_408, truncated: false)

    static let projects = [PluginProject(path: "/Users/me/Developer/relay", name: "Relay"),
                           PluginProject(path: "/Users/me/Developer/beacon", name: "Beacon")]

    @MainActor static func feed() -> PluginFeed {
        PluginFeed(fixture: plugins, restartRequired: true, logs: [MQTTBridge.pluginID: log, "acme.jira": PluginLog(), "example.hello": PluginLog()])
    }

    /// The grant sheet as it stands after a Save the schema refused: a Jira grant with a site
    /// that is too short and a result count that is out of range.
    static var invalidDraft: PluginGrantDraft {
        let jira = plugins[1]
        var draft = PluginGrantDraft(plugin: jira, tool: jira.tools[1])
        draft.project = "/Users/me/Developer/beacon"
        draft.values.text = ["site": "a", "max_results": "250", "detail": "summary"]
        _ = draft.validated()
        return draft
    }
}
