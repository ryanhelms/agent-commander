import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The Plugins mode: reading the service's list, the navigation's places, the settings form made
// from a plugin's schema and its checks, and the grant draft. `PLUGIN_RENDER_DIR` names a folder
// for headless pictures of the fixture pages:
//
//     PLUGIN_RENDER_DIR=design/demos/plugins swift test --filter Plugins

let pluginRenderDirectory = ProcessInfo.processInfo.environment["PLUGIN_RENDER_DIR"]

@MainActor @Suite struct PluginsTests {
    static let body = """
    {"restart_required": true,
     "plugins": [{
       "id": "adag.mqtt", "version": "0.1.0", "name": "MQTT Bridge", "description": "Read an MQTT broker.",
       "installed_at": "2026-11-27T20:00:00Z", "digest": "sha256:9f2c41d07a3be8c15d0e6a7714bb02f3",
       "settings_schema": {"type":"object","additionalProperties":false,"properties":{"topics":{"type":"array","maxItems":32,
         "items":{"type":"string","minLength":1,"maxLength":256},"description":"MQTT topic filters this project may read."}}},
       "loaded": true,
       "tools": [{"id":"adag.mqtt.list_topics","version":1,"mcp_tool":"list_topics","description":"List topics.",
                  "grants":[{"project":"/Users/x/repo","version":1,"settings":{"topics":["plant/#"]},"active":true},
                            {"project":"/Users/x/other","version":1,"active":false}]},
                 {"id":"adag.mqtt.read_messages","version":2,"mcp_tool":"read_messages"},
                 {"mcp_tool":"no_id"}]
      },
      {"id": "example.hello", "version": "0.3.1", "loaded": false,
       "problem": "plugin example.hello 0.3.1 refused: installed files do not match digest", "settings_schema": null},
      {"name": "No ID"}
     ]}
    """

    @Test func readsTheList() throws {
        let list = try PluginSnapshot.decode(Data(Self.body.utf8))
        #expect(list.restartRequired && list.plugins.map(\.id) == ["adag.mqtt", "example.hello"])
        let mqtt = list.plugins[0]
        #expect(mqtt.name == "MQTT Bridge" && mqtt.version == "0.1.0" && mqtt.installedAt != nil && mqtt.loaded)
        #expect(mqtt.shortDigest == "sha256:9f2c41d07a3b…" && mqtt.settingsSchema != nil && !mqtt.hasProblem)
        #expect(mqtt.tools.map(\.id) == ["adag.mqtt.list_topics", "adag.mqtt.read_messages"])
        #expect(mqtt.tools[0].mcpTool == "list_topics" && mqtt.tools[1].version == 2 && mqtt.tools[1].grants.isEmpty)
        let grants = mqtt.tools[0].grants
        #expect(grants.map(\.project) == ["/Users/x/repo", "/Users/x/other"] && grants.map(\.active) == [true, false])
        #expect(grants[0].settings == ["topics": ["plant/#"]] && grants[1].settings == nil && grants[0].projectName == "repo")
        #expect(mqtt.grantCount == 2 && mqtt.pendingGrantCount == 1 && mqtt.state.title == "Loaded")
        #expect(mqtt.kindLine == "adag.mqtt · 2 tools")
        let hello = list.plugins[1]
        // A plugin without a name shows its ID; a refusal outranks "loads at restart".
        #expect(hello.name == "example.hello" && hello.hasProblem && hello.state.title == "Refused" && hello.settingsSchema == nil)
        var changed = hello
        changed.problem = ""
        #expect(changed.state.title == "Loads at restart" && changed.state.tone == .attention)
        // Missing members are quiet defaults; an empty answer is an empty list.
        #expect(try PluginSnapshot.decode(Data("{}".utf8)) == PluginInventory())
        #expect(try PluginSnapshot.decode(Data(#"{"plugins":null}"#.utf8)).plugins.isEmpty)
        #expect(throws: (any Error).self) { try PluginSnapshot.decode(Data("nope".utf8)) }
    }

    @Test func readsALogAndWritesTheCallBodies() throws {
        let log = try PluginSnapshot.decodeLog(Data(#"{"path":"/s/plugins/adag.mqtt/plugin.log","text":"line\n","size":20480,"truncated":true}"#.utf8))
        #expect(log.text == "line\n" && log.truncated && log.sizeLine.hasSuffix(", showing the end") && !log.isEmpty)
        let none = try PluginSnapshot.decodeLog(Data(#"{"path":"/s/plugin.log","text":"","size":0}"#.utf8))
        #expect(none.isEmpty && !none.truncated && none.size == 0)

        let grant = try AGUIValue(json: PluginSnapshot.grantBody(tool: "adag.mqtt.list_topics", version: 1, project: "/abs/path",
                                                                   settings: ["topics": ["a/#"]]))
        #expect(grant == ["tool": "adag.mqtt.list_topics", "version": 1, "project": "/abs/path", "settings": ["topics": ["a/#"]]])
        // No settings: the member is left out, not sent as null.
        let bare = try AGUIValue(json: PluginSnapshot.grantBody(tool: "t.x", version: 2, project: "/p", settings: nil))
        #expect(bare == ["tool": "t.x", "version": 2, "project": "/p"])
        #expect(try AGUIValue(json: PluginSnapshot.revokeBody(tool: "t.x", project: "/p")) == ["tool": "t.x", "project": "/p"])
    }

    @Test func thePlacesFollowTheList() {
        let tally = PluginTally(PluginFixture.plugins)
        #expect(tally.installed == 3 && tally.problems == 1 && tally.tools == 6 && tally.grants == 5 && tally.hasMQTT)
        #expect(tally.summary == "3 installed, 6 tools, 5 grants, 1 refused")
        #expect(PluginTally().summary == "No plugin is installed")
        let navigation = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: PluginPlace.installed,
                                              needsYou: 0, network: ShellNetwork(), plugins: tally)
        let mode = navigation.modeItems[5]
        #expect(mode.mode.title == "Plugins" && mode.isSelected && mode.hotCount == 1 && mode.shortcut == 6)
        #expect(navigation.contextSections.map(\.group.title) == ["Plugins", "Panels"])
        #expect(navigation.contextSections.flatMap(\.items).map(\.place.title) == ["Problems", "Installed", "MQTT"])
        #expect(navigation.crumbs == ["Plugins", "Installed"])
        let panel = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: PluginPlace.mqtt,
                                         needsYou: 0, network: ShellNetwork(), plugins: tally)
        #expect(panel.selection == PluginPlace.mqtt && panel.crumbs == ["Plugins", "Panels", "MQTT"])
        // Without a refused plugin or the MQTT plugin, those places leave and the mode stays open.
        let quiet = PluginTally([PluginFixture.plugins[1]])
        for place in [PluginPlace.problems, PluginPlace.mqtt] {
            let next = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: place,
                                            needsYou: 0, network: ShellNetwork(), plugins: quiet)
            #expect(next.selection == PluginPlace.installed && next.selectedModeID == PluginPlace.mode)
            #expect(next.contextSections.flatMap(\.items).map(\.place.title) == ["Installed"])
        }
        #expect(PluginPlace.plugins(PluginFixture.plugins, in: PluginPlace.installed).map(\.name) == ["Hello", "Jira lookups", "MQTT Bridge"])
        #expect(PluginPlace.plugins(PluginFixture.plugins, in: PluginPlace.problems).map(\.id) == ["example.hello"])
    }

    @Test func theProjectChoicesAreTheCockpitsThenTheGrantedOnes() {
        let known = [PluginProject(path: "/Users/me/Developer/relay", name: "Relay")]
        let choices = PluginProject.choices(known: known, plugins: PluginFixture.plugins)
        #expect(choices.map(\.path) == ["/Users/me/Developer/relay", "/Users/me/Developer/beacon"])
        #expect(choices.map(\.name) == ["Relay", "beacon"])
    }

    @Test func revokeSaysWhatTheRunningServiceStillHas() {
        let loaded = PluginGrantRow.revokeNote(for: PluginGrant(project: "/Users/me/Developer/relay", active: true))
        let waiting = PluginGrantRow.revokeNote(for: PluginGrant(project: "/Users/me/Developer/beacon", active: false))
        #expect(loaded == "Agents in relay keep this tool until the service restarts, then lose it.")
        #expect(waiting == "Agents in beacon won’t have this tool after the next restart.")
    }

    // MARK: Settings schema

    @Test func theCommonShapesBecomeFormFields() {
        let schema = PluginSettingsSchema(PluginFixture.jiraSchema)
        #expect(schema.isFormable && schema.rawReason == nil)
        // Required first, then by name.
        #expect(schema.fields.map(\.name) == ["site", "detail", "include_comments", "max_results"])
        #expect(schema.fields.map(\.kind) == [.text, .choice(["summary", "full"]), .boolean, .number(integer: true)])
        #expect(schema.fields[0].isRequired && schema.fields[0].hint == "2 to 40 characters")
        #expect(schema.fields[3].hint == "1 to 100" && schema.fields[1].hint == nil)
        let mqtt = PluginSettingsSchema(PluginFixture.mqttSchema)
        #expect(mqtt.isFormable && mqtt.fields.map(\.kind) == [.list] && mqtt.fields[0].hint == "Up to 32, one per line")
        #expect(mqtt.fields[0].detail?.hasPrefix("MQTT topic filters") == true)
        let decimal = PluginSettingsSchema(["type": "object", "properties": ["ratio": ["type": "number", "title": "Ratio"]]])
        #expect(decimal.fields.map(\.kind) == [.number(integer: false)] && decimal.fields[0].title == "Ratio")
    }

    @Test func anythingElseIsEditedAsJSON() {
        let nested = PluginSettingsSchema(["type": "object", "properties": ["limits": ["type": "object"]]])
        #expect(!nested.isFormable && nested.rawReason == "“limits” has a shape the form has no control for.")
        #expect(!PluginSettingsSchema(["type": "object"]).isFormable)
        #expect(!PluginSettingsSchema(["type": "object", "properties": ["a": ["type": "string"]], "oneOf": []]).isFormable)
        #expect(!PluginSettingsSchema(["type": "object", "properties": ["a": ["type": "array", "items": ["type": "integer"]]]]).isFormable)
        #expect(!PluginSettingsSchema(["type": "object", "properties": ["a": ["type": "string", "enum": ["x", 1]]]]).isFormable)
        #expect(!PluginSettingsSchema(["type": "array"]).isFormable)
    }

    @Test func theFormIsCheckedAgainstTheSchemaBeforeItIsSent() throws {
        let schema = PluginSettingsSchema(PluginFixture.jiraSchema)
        var input = PluginSettingsInput()
        // Required and empty.
        #expect(schema.value(from: input) == .failure(PluginSettingsProblems(byField: ["site": "Required."])))
        input.text = ["site": "a", "max_results": "250", "detail": "summary"]
        #expect(schema.value(from: input) == .failure(PluginSettingsProblems(byField: ["site": "At least 2 characters.", "max_results": "At most 100."])))
        input.text["max_results"] = "2.5"
        #expect(try #require(schema.value(from: input).failure).byField["max_results"] == "Enter a whole number, such as 42.")
        input.text["max_results"] = "many"
        #expect(try #require(schema.value(from: input).failure).byField["max_results"] == "Enter a whole number, such as 42.")
        input.text = ["site": "acme", "max_results": " 25 ", "detail": "full"]
        input.flags["include_comments"] = true
        #expect(try schema.value(from: input).get() == ["site": "acme", "max_results": 25, "detail": "full", "include_comments": true])
        // An untouched optional switch and an empty optional field are left out.
        input = PluginSettingsInput(text: ["site": "acme"])
        #expect(try schema.value(from: input).get() == ["site": "acme"])
        // A string longer than maxLength.
        input.text["site"] = String(repeating: "x", count: 41)
        #expect(try #require(schema.value(from: input).failure).byField["site"] == "At most 40 characters.")
    }

    @Test func aListIsOneEntryPerLine() throws {
        let schema = PluginSettingsSchema(PluginFixture.mqttSchema)
        var input = PluginSettingsInput(text: ["topics": " plant/line1/# \n\nplant/energy/+/power\n"])
        #expect(try schema.value(from: input).get() == ["topics": ["plant/line1/#", "plant/energy/+/power"]])
        // Empty is "omit to allow every topic".
        #expect(try schema.value(from: PluginSettingsInput()).get() == [:])
        input.text["topics"] = (1...33).map { "t/\($0)" }.joined(separator: "\n")
        #expect(try #require(schema.value(from: input).failure).byField == ["topics": "At most 32 entries."])
        input.text["topics"] = "ok/#\n" + String(repeating: "x", count: 257)
        #expect(try #require(schema.value(from: input).failure).byField == ["topics": "Entry 2: At most 256 characters."])
        // Existing settings fill the form; ones the form can't hold don't.
        #expect(schema.input(from: ["topics": ["a/#", "b"]]) == PluginSettingsInput(text: ["topics": "a/#\nb"]))
        #expect(schema.input(from: ["topics": ["a", 2]]) == nil)
        #expect(schema.input(from: ["other": true]) == nil)
        #expect(schema.input(from: [:]) == PluginSettingsInput())
    }

    @Test func theCheckCoversTheSchemaSubset() {
        func problems(_ value: AGUIValue, _ schema: AGUIValue) -> [String] {
            PluginSchemaCheck.problems(in: value, schema: schema).map(\.sentence)
        }
        let schema = PluginFixture.jiraSchema
        #expect(problems(["site": "acme", "extra": 1], schema) == ["extra: Not a setting of this plugin."])
        #expect(problems(["site": 3], schema) == ["site: Use text."])
        #expect(problems(["site": "acme", "include_comments": "yes"], schema) == ["include_comments: Use true or false."])
        #expect(problems(["site": "acme", "detail": "all"], schema) == ["detail: Use one of: summary, full."])
        #expect(problems(["site": "acme", "max_results": 0], schema) == ["max_results: At least 1."])
        #expect(problems(["site": "acme", "max_results": 3.0], schema).isEmpty)
        #expect(problems("text", schema) == ["Use an object."])
        #expect(problems(["topics": ["a", ""]], PluginFixture.mqttSchema) == ["topics, entry 2: Enter text."])
        #expect(problems(["a", "a"], ["type": "array", "uniqueItems": true, "minItems": 3]) == ["At least 3 entries.", "1: Listed twice."])
        #expect(problems(5, ["type": ["string", "null"]]) == ["Use text or null."])
        #expect(problems(5, ["exclusiveMinimum": 5, "exclusiveMaximum": 5]) == ["More than 5.", "Less than 5."])
        // Additional properties with their own schema are checked; unknown keywords are the service's.
        #expect(problems(["x": 1], ["type": "object", "additionalProperties": ["type": "string"]]) == ["x: Use text."])
        #expect(problems(["x": 1], ["type": "object", "pattern": "^a$"]).isEmpty)
    }

    @Test func jsonSettingsAreCheckedTheSameWay() throws {
        let schema = PluginSettingsSchema(PluginFixture.jiraSchema)
        #expect(try schema.value(fromJSON: #"{"site":"acme","max_results":10}"#).get() == ["site": "acme", "max_results": 10])
        #expect(try #require(schema.value(fromJSON: "{site}").failure).byField[PluginSettingsSchema.general]?.hasPrefix("This isn’t valid JSON") == true)
        #expect(try #require(schema.value(fromJSON: "[1]").failure).byField[PluginSettingsSchema.general]?.hasPrefix("Settings are a JSON object") == true)
        #expect(try #require(schema.value(fromJSON: #"{"site":"a","nope":1}"#).failure).byField
                == [PluginSettingsSchema.general: "nope: Not a setting of this plugin.\nsite: At least 2 characters."])
        // Empty text is an empty object, which this schema refuses for its required field.
        #expect(try #require(schema.value(fromJSON: "  ").failure).byField == [PluginSettingsSchema.general: "site: Required."])
        #expect(try PluginSettingsSchema(PluginFixture.mqttSchema).value(fromJSON: "").get() == [:])
    }

    // MARK: Grant draft

    @Test func aDraftOpensOnTheFormAndValidatesBeforeSending() throws {
        let jira = PluginFixture.plugins[1]
        var draft = PluginGrantDraft(plugin: jira, tool: jira.tools[1])
        #expect(draft.editor == .form && !draft.isEdit && draft.toolVersion == 2 && draft.title == "Grant tool")
        // No project, no site.
        #expect(draft.validated().failure?.byField == ["site": "Required.", "project": "Choose a project."])
        #expect(draft.projectProblem == "Choose a project." && draft.problems == ["site": "Required."] && draft.hasProblems)
        draft.project = "relative/path"
        _ = draft.validated()
        #expect(draft.projectProblem == "Use an absolute path, such as /Users/me/repo.")
        draft.project = "/Users/me/Developer/beacon"
        draft.values.text["site"] = "acme"
        #expect(try draft.validated().get() == ["site": "acme"])
        #expect(!draft.hasProblems)
        // The fixture's refused draft: both problems sit beside their fields.
        let invalid = PluginFixture.invalidDraft
        #expect(invalid.problems == ["site": "At least 2 characters.", "max_results": "At most 100."] && invalid.projectProblem == nil)
    }

    @Test func aDraftCarriesWhatWasEnteredBetweenTheFormAndJSON() throws {
        let jira = PluginFixture.plugins[1]
        // An existing grant opens with its settings in the form, on its own project.
        var draft = PluginGrantDraft(plugin: jira, tool: jira.tools[0], grant: jira.tools[0].grants[0])
        #expect(draft.isEdit && draft.project == "/Users/me/Developer/relay" && draft.title == "Edit grant")
        #expect(draft.values.text == ["site": "acme", "max_results": "25"])
        draft.choose(.json)
        #expect(draft.editor == .json)
        #expect(try AGUIValue(json: draft.json) == ["site": "acme", "max_results": 25])
        draft.json = #"{"site":"beta","include_comments":true}"#
        draft.choose(.form)
        #expect(draft.editor == .form && draft.values == PluginSettingsInput(text: ["site": "beta"], flags: ["include_comments": true]))
        // JSON the form can't hold stays in the JSON editor and says so.
        draft.choose(.json)
        draft.json = #"{"site":"beta","nested":{}}"#
        draft.choose(.form)
        #expect(draft.editor == .json && draft.problems[PluginSettingsSchema.general] != nil)
        #expect(draft.validated().failure?.byField[PluginSettingsSchema.general] == "nested: Not a setting of this plugin.")

        // A schema the form can't show opens on JSON; a plugin without a schema sends no settings.
        var odd = jira
        odd.settingsSchema = ["type": "object", "properties": ["limits": ["type": "object"]]]
        #expect(PluginGrantDraft(plugin: odd, tool: odd.tools[0]).editor == .json)
        let hello = PluginFixture.plugins[2]
        var bare = PluginGrantDraft(plugin: hello, tool: hello.tools[0])
        bare.project = "/p"
        #expect(bare.schema == nil)
        #expect(try bare.validated().get() == nil)
        // Empty settings are not sent.
        let mqtt = PluginFixture.plugins[0]
        var open = PluginGrantDraft(plugin: mqtt, tool: mqtt.tools[2])
        open.project = "/p"
        #expect(try open.validated().get() == nil)
    }

    // MARK: Feed

    private final class Calls: @unchecked Sendable {
        var granted: [(tool: String, version: Int, project: String, settings: AGUIValue?)] = []
        var revoked: [(tool: String, project: String)] = []
        var refuse: String?
    }

    @Test func theFeedSendsAValidGrantAndKeepsARefusalInTheSheet() async throws {
        let calls = Calls()
        var after = PluginInventory(restartRequired: true, plugins: PluginFixture.plugins)
        after.plugins[1].tools[1].grants = [PluginGrant(project: "/Users/me/Developer/beacon", version: 2, settings: ["site": "acme"], active: false)]
        let answer = after
        let feed = PluginFeed(api: PluginAPI(
            list: { PluginInventory(plugins: PluginFixture.plugins) },
            grant: { tool, version, project, settings in
                if let refuse = calls.refuse { throw ServiceError.rejected(refuse) }
                calls.granted.append((tool, version, project, settings))
                return answer
            },
            revoke: { tool, project in
                calls.revoked.append((tool, project))
                return PluginInventory(restartRequired: true, plugins: [])
            },
            log: { _ in PluginLog(path: "/s/plugin.log", text: "started\n", size: 8) }))
        #expect(feed.link == .connecting)
        await feed.follow()
        #expect(feed.link == .live && feed.plugins.count == 3 && !feed.restartRequired)

        feed.openGrant(pluginID: "acme.jira", toolID: "acme.jira.search")
        #expect(feed.draft?.toolID == "acme.jira.search" && feed.draft?.isEdit == false)
        // An invalid draft is never sent.
        await feed.saveGrant()
        #expect(calls.granted.isEmpty && feed.draft?.problems["site"] == "Required.")
        feed.draft?.project = " /Users/me/Developer/beacon "
        feed.draft?.values.text["site"] = "acme"
        // The service's refusal stays in the sheet, with what was entered.
        calls.refuse = "project is not an existing absolute directory"
        await feed.saveGrant()
        #expect(feed.draft?.serverError == "The service refused the grant. Project is not an existing absolute directory.")
        #expect(feed.draft?.isSaving == false && feed.draft?.values.text["site"] == "acme")
        calls.refuse = nil
        await feed.saveGrant()
        #expect(calls.granted.count == 1 && calls.granted[0].tool == "acme.jira.search" && calls.granted[0].version == 2)
        #expect(calls.granted[0].project == "/Users/me/Developer/beacon" && calls.granted[0].settings == ["site": "acme"])
        #expect(feed.draft == nil && feed.restartRequired && feed.plugin("acme.jira")?.tools[1].grants.first?.active == false)

        await feed.readLog("acme.jira")
        #expect(feed.logs["acme.jira"]?.log?.text == "started\n" && feed.logs["acme.jira"]?.isLoading == false)
        await feed.revoke(pluginID: "acme.jira", toolID: "acme.jira.get_issue", project: "/Users/me/Developer/relay")
        #expect(calls.revoked.count == 1 && calls.revoked[0] == ("acme.jira.get_issue", "/Users/me/Developer/relay"))
        #expect(feed.plugins.isEmpty && feed.logs.isEmpty && feed.busy.isEmpty)
    }

    @Test func aFixtureFeedChangesItsOwnList() async {
        let feed = PluginFixture.feed()
        #expect(feed.restartRequired && feed.logs[MQTTBridge.pluginID]?.log?.isEmpty == false)
        feed.openGrant(pluginID: MQTTBridge.pluginID, toolID: "adag.mqtt.broker_status")
        feed.draft?.project = "/Users/me/Developer/relay"
        feed.draft?.values.text["topics"] = "plant/#"
        await feed.saveGrant()
        let grant = feed.plugin(MQTTBridge.pluginID)?.tools[2].grants.first
        #expect(feed.draft == nil && grant?.settings == ["topics": ["plant/#"]] && grant?.active == false)
        await feed.revoke(pluginID: MQTTBridge.pluginID, toolID: "adag.mqtt.broker_status", project: "/Users/me/Developer/relay")
        #expect(feed.plugin(MQTTBridge.pluginID)?.tools[2].grants.isEmpty == true)
        // Opening an existing grant edits it in place.
        feed.openGrant(pluginID: MQTTBridge.pluginID, toolID: "adag.mqtt.list_topics", project: "/Users/me/Developer/relay")
        #expect(feed.draft?.isEdit == true && feed.draft?.values.text["topics"] == "plant/#")
        let context = PluginsContext(feed: feed, projects: PluginFixture.projects)
        #expect(context.draft?.id == feed.draft?.id && context.projects.map(\.name) == ["Relay", "Beacon"] && !context.isUnavailable)
    }

    @Test func theScenariosOpenOnTheirPlaces() {
        #expect(DesignPreviewScenario.plugins.pluginPlace == PluginPlace.installed)
        #expect(DesignPreviewScenario.pluginsMQTT.isShell && ShellConcept(scenario: .pluginsMQTT) == .modeRail)
        #expect(ShellPreviewState(scenario: .pluginsProblem).selection == PluginPlace.problems)
        #expect(ShellPreviewState(scenario: .pluginsGrant).plugins.draft?.problems.count == 2)
        #expect(ShellPreviewState(scenario: .pluginsMQTTOffline).mqtt.link == .offline)
        #expect(MQTTContext(feed: ShellPreviewState(scenario: .pluginsMQTT).mqtt).messages.count == 12)
    }

    @Test(.enabled(if: pluginRenderDirectory != nil)) func drawsThePluginPages() async throws {
        let folder = URL(fileURLWithPath: try #require(pluginRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        func shell(_ scenario: DesignPreviewScenario) -> some View {
            ShellPreviewPage(store: PreviewStore(scenario: scenario), state: ShellPreviewState(scenario: scenario), chrome: .drawn)
        }
        try await ShellRenderTests.write(shell(.plugins), "plugins-installed", theme: .console, to: folder)
        try await ShellRenderTests.write(shell(.pluginsProblem), "plugins-problem", theme: .console, to: folder)
        try await ShellRenderTests.write(shell(.pluginsMQTT), "plugins-mqtt", theme: .console, to: folder,
                                         size: CGSize(width: 1600, height: 1000))
        try await ShellRenderTests.write(shell(.pluginsMQTTOffline), "plugins-mqtt-offline", theme: .console, to: folder)
        try await ShellRenderTests.write(shell(.plugins), "fit-1280-plugins-installed", theme: .console, to: folder,
                                         size: NetworkFitTests.window)
        try await ShellRenderTests.write(shell(.pluginsMQTT), "fit-1280-plugins-mqtt", theme: .console, to: folder,
                                         size: NetworkFitTests.window)
        try await ShellRenderTests.write(shell(.plugins), "plugins-installed", theme: .blackGlass, to: folder)
        try await ShellRenderTests.write(shell(.pluginsMQTT), "plugins-mqtt", theme: .blackGlass, to: folder,
                                         size: CGSize(width: 1600, height: 1000))
        // The grant sheet is drawn on its own: a sheet has no window in a headless picture.
        let state = ShellPreviewState(scenario: .pluginsGrant)
        let context = PluginsContext(feed: state.plugins, projects: PluginFixture.projects)
        let refused = try #require(context.draft)
        try await ShellRenderTests.write(
            ThemeCanvas { PluginGrantSheet(draft: refused, projects: context.projects, actions: context.actions).padding(20) },
            "plugins-grant-invalid", theme: .console, to: folder, size: CGSize(width: 600, height: 760))
        let mqtt = PluginFixture.plugins[0]
        var json = PluginGrantDraft(plugin: mqtt, tool: mqtt.tools[0], grant: mqtt.tools[0].grants[0])
        json.choose(.json)
        json.serverError = "The service refused the grant. Settings do not match the plugin’s schema: topics: expected array."
        try await ShellRenderTests.write(
            ThemeCanvas { PluginGrantSheet(draft: json, projects: context.projects, actions: context.actions).padding(20) },
            "plugins-grant-json", theme: .console, to: folder, size: CGSize(width: 600, height: 620))
        var missing = PluginsContext()
        missing.link = .unavailable
        try await ShellRenderTests.write(
            ThemeCanvas { PluginsPage(place: PluginPlace.installed, crumbs: ["Plugins", "Installed"], context: missing, shown: .constant(nil)) },
            "plugins-unavailable", theme: .console, to: folder)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
