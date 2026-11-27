import Foundation
import Testing
@testable import AgentCommander

// Directory-backed projects and read-only links:
//   1. A link is taken only in its exact form, and only navigates.
//   2. The Projects group comes from the catalog and the runs, keyed by project ID, with the
//      directory rows of a service that has no catalog.
//   3. The navigation lists Open folder, selects a project's own place and the open run's project.
//   4. The router carries a link to the window, also one that arrived before it.
//   5. The model reads the catalog, tolerates a service without one and never guesses a target.

@MainActor @Suite struct ProjectsTests {
    static let runID = "r-0123456789abcdef0123456789abcdef"
    static let projectID = "p-fedcba9876543210fedcba9876543210"

    static let relay = Project(id: projectID, path: "/code/relay", name: "Relay")
    static let empty = Project(id: "p-00000000000000000000000000000000", path: "/code/empty", name: "Empty")

    // MARK: Links

    @Test func aLinkNamesOneRunOrProjectByItsExactID() throws {
        #expect(CommanderLink(try #require(URL(string: "agentcommander://run/\(Self.runID)"))) == .run(Self.runID))
        #expect(CommanderLink(try #require(URL(string: "agentcommander://project/\(Self.projectID)"))) == .project(Self.projectID))
        // The scheme and the host are not case-sensitive. The ID is.
        #expect(CommanderLink(try #require(URL(string: "AgentCommander://Run/\(Self.runID)"))) == .run(Self.runID))
    }

    @Test func anythingElseIsNoLink() throws {
        let refused = [
            "agentcommander://join?server=https%3A%2F%2Flab.example",
            "https://run/\(Self.runID)",
            "agentcommander://run",
            "agentcommander://run/",
            // The kind and the ID's prefix must agree.
            "agentcommander://run/\(Self.projectID)",
            "agentcommander://project/\(Self.runID)",
            // 32 lowercase hex digits, no more and no fewer.
            "agentcommander://run/r-0123456789abcdef0123456789abcde",
            "agentcommander://run/r-0123456789abcdef0123456789abcdef0",
            "agentcommander://run/r-0123456789ABCDEF0123456789ABCDEF",
            "agentcommander://run/r-0123456789abcdef0123456789abcdeg",
            // Nothing rides along: no further path, query, fragment, port or credentials.
            "agentcommander://run/\(Self.runID)/stop",
            "agentcommander://run/\(Self.runID)?task=rm",
            "agentcommander://run/\(Self.runID)#x",
            "agentcommander://run:80/\(Self.runID)",
            "agentcommander://user@run/\(Self.runID)",
            "agentcommander://start/\(Self.runID)",
            "agentcommander://worker/w-0123456789abcdef0123456789abcdef"
        ]
        for text in refused {
            let url = try #require(URL(string: text))
            #expect(CommanderLink(url) == nil, "\(text) must not navigate")
        }
        #expect(CommanderLink.isID(Self.runID, prefix: "r-") && !CommanderLink.isID(Self.runID, prefix: "p-"))
    }

    // MARK: Catalog values

    @Test func theCatalogIsReadFromTheServicesAnswer() throws {
        let json = #"{"projects":[{"id":"\#(Self.projectID)","path":"/code/relay","name":"Relay"},{"id":"p-1","path":"/srv/api","name":""}]}"#
        let projects = try Project.list(json: Data(json.utf8))
        #expect(projects.first == Self.relay)
        // A project without a name is named for its folder.
        #expect(projects.last?.displayName == "api")
        #expect(try Project.list(json: Data(#"{"projects":null}"#.utf8)).isEmpty)
        #expect(try Project.list(json: Data("{}".utf8)).isEmpty)
    }

    @Test func aRunCarriesItsProjectAndARunInAProjectSendsNoPath() throws {
        func run(_ extra: String) throws -> Run {
            let json = #"{"runs":[{"id":"r-1","project":"Relay","path":"/code/relay","task":"t","client":"claude","coordinator_id":"w","status":"running"\#(extra)}]}"#
            return try #require(Run.list(json: Data(json.utf8)).first)
        }
        #expect(try run(#","project_id":"\#(Self.projectID)""#).projectID == Self.projectID)
        // An older service sends none, and an empty one reads the same.
        #expect(try run("").projectID == nil)
        #expect(try run(#","project_id":"""#).projectID == nil)
        #expect(RunSummary(run: try run(#","project_id":"\#(Self.projectID)""#)).projectID == Self.projectID)

        let fields = ServiceClient.runFields(projectID: Self.projectID, task: "Tighten retries", title: "  ")
        #expect(fields == ["project_id": Self.projectID, "task": "Tighten retries", "client": "claude"])
        #expect(ServiceClient.runFields(projectID: Self.projectID, task: "t", title: "Retries")["title"] == "Retries")
    }

    // MARK: The Projects group

    static func summary(_ id: String, _ project: String, _ path: String, projectID: String? = nil) -> RunSummary {
        RunSummary(id: id, project: project, path: path, title: id, status: .running, projectID: projectID)
    }

    @Test func recordedProjectsListBeforeAnyRunAndHoldTheirRuns() {
        let runs = [
            Self.summary("R-1", "Relay", "/code/relay", projectID: Self.projectID),
            // A run that names no project joins the project recorded for its directory.
            Self.summary("R-2", "Relay", "/code/relay"),
            // A run that matches nothing is grouped by directory, as before the catalog.
            Self.summary("R-3", "Beacon", "/code/beacon"),
            // A project the catalog doesn't list yet keeps a row under its own ID.
            Self.summary("R-4", "Lab", "/code/lab", projectID: "p-new")
        ]
        let entries = ProjectEntry.list(catalog: [Self.relay, Self.empty], runs: runs)
        #expect(entries.map(\.key) == [Self.projectID, Self.empty.id, "/code/beacon", "p-new"])
        #expect(entries.map(\.name) == ["Relay", "Empty", "Beacon", "Lab"])
        #expect(entries.map(\.runIDs) == [["R-1", "R-2"], [], ["R-3"], ["R-4"]])
        #expect(entries.map(\.projectID) == [Self.projectID, Self.empty.id, nil, "p-new"])
        #expect(entries[1].path == "/code/empty")
        // When the catalog catches up the row keeps its key, so the window stays on it.
        let later = ProjectEntry.list(catalog: [Self.relay, Self.empty, Project(id: "p-new", path: "/code/lab", name: "Lab")], runs: runs)
        #expect(later.map(\.key) == [Self.projectID, Self.empty.id, "p-new", "/code/beacon"])
        #expect(ProjectEntry.entry(for: runs[1], in: entries)?.key == Self.projectID)
    }

    @Test func aServiceWithoutACatalogKeepsItsDirectoryRows() {
        let entries = ProjectEntry.list(catalog: [], runs: ShellLiveTests.runs)
        #expect(entries.map(\.key) == ["/code/relay", "/code/beacon"])
        #expect(entries.map(\.runIDs) == [["R-1", "R-3"], ["R-2"]])
        #expect(entries.allSatisfy { $0.projectID == nil })
    }

    // MARK: Navigation

    static func navigation(place: String = LiveShell.wall, openRunID: String? = nil, composing: Bool = false,
                           isOnline: Bool = true) -> (CommanderNavigation, [ProjectEntry]) {
        let runs = [summary("R-1", "Relay", "/code/relay", projectID: projectID), summary("R-2", "Beacon", "/code/beacon")]
        let entries = ProjectEntry.list(catalog: [relay, empty], runs: runs)
        let navigation = LiveShell.navigation(runs: runs, openRunPath: nil, composing: composing, place: place, needsYou: 0,
                                              network: ShellNetwork(), isOnline: isOnline, projects: entries,
                                              openRunID: openRunID, canOpenFolder: true)
        return (navigation, entries)
    }

    @Test func agentsListsOpenFolderAndEveryProject() {
        let (navigation, _) = Self.navigation()
        let agents = navigation.contextSections
        #expect(agents[0].items.map(\.place.title) == ["Needs you", "Runs", "New run", "Open folder…"])
        #expect(agents[1].items.map(\.place.title) == ["Relay", "Empty", "Beacon"])
        #expect(agents[1].items.map(\.place.id)
                == [LiveShell.project(Self.projectID), LiveShell.project(Self.empty.id), LiveShell.project("/code/beacon")])
        // A folder can't be recorded while the service is offline.
        #expect(Self.navigation(isOnline: false).0.place(LiveShell.openFolder)?.isDisabled == true)
        // Where nothing records projects the row is not listed.
        #expect(ShellLiveTests.navigation().place(LiveShell.openFolder) == nil)
    }

    @Test func aProjectHasItsOwnPlaceAndTheWallSelectsTheOpenRunsProject() {
        // A project with no run is a place of its own.
        let place = LiveShell.project(Self.empty.id)
        let (onProject, entries) = Self.navigation(place: place)
        #expect(onProject.selection == place && onProject.crumbs == ["Agents", "Projects", "Empty"])
        #expect(LiveShell.shownProject(place: place, composing: false, in: entries)?.key == Self.empty.id)
        // The run form and the wall draw no overview; nor does a project that is gone.
        #expect(LiveShell.shownProject(place: place, composing: true, in: entries) == nil)
        #expect(LiveShell.shownProject(place: LiveShell.wall, composing: false, in: entries) == nil)
        #expect(LiveShell.shownProject(place: LiveShell.project("p-gone"), composing: false, in: entries) == nil)
        // On the wall the selected row is the project that holds the open run, by the run's ID.
        #expect(Self.navigation(openRunID: "R-1").0.selection == LiveShell.project(Self.projectID))
        #expect(Self.navigation(openRunID: "R-2").0.selection == LiveShell.project("/code/beacon"))
        #expect(Self.navigation().0.selection == LiveShell.wall)
        // Open folder is an action: the window is never on it.
        #expect(Self.navigation(place: LiveShell.openFolder, openRunID: "R-1").0.selection == LiveShell.project(Self.projectID))
        #expect(LiveShell.projectKey(of: place) == Self.empty.id && LiveShell.projectKey(of: LiveShell.wall) == nil)
    }

    @Test func aProjectsRunsSplitIntoRunningAndEarlier() throws {
        func content(_ id: String, _ status: String) throws -> RunContent {
            let json = #"{"runs":[{"id":"\#(id)","project":"Relay","path":"/code/relay","task":"t","client":"claude","coordinator_id":"w","status":"\#(status)","project_id":"\#(Self.projectID)"}]}"#
            return RunContent(run: try #require(Run.list(json: Data(json.utf8)).first))
        }
        let runs = [try content("R-1", "completed"), try content("R-2", "running"), try content("R-3", "stopped"), try content("R-4", "running")]
        var cockpit = CockpitContent(connection: .online, notice: nil, isStopping: false, runs: [], selected: runs[1],
                                     pending: [], sending: [])
        cockpit.allRuns = runs
        cockpit.projects = [ProjectEntry(key: Self.projectID, projectID: Self.projectID, name: "Relay", path: "/code/relay",
                                         runIDs: runs.map(\.id))]
        let split = cockpit.runs(in: cockpit.projects[0])
        // Newest first in each.
        #expect(split.active.map(\.id) == ["R-4", "R-2"] && split.earlier.map(\.id) == ["R-3", "R-1"])
        #expect(cockpit.selectedProject?.key == Self.projectID)
    }

    // MARK: Presentation

    @Test func aRunOpensByItsExactIDAndAProjectByItsKey() {
        let ui = CockpitPresentationState()
        var selected: [String] = []
        ui.shellPlace = LiveShell.settings
        ui.composingRun = true
        ui.zoomedWorkerID = "w-old"
        // Another run: it is selected, and its wall shows unzoomed when it arrives.
        ui.showRun("R-2", current: "R-1") { selected.append($0) }
        #expect(selected == ["R-2"] && ui.shellPlace == LiveShell.wall && !ui.composingRun && ui.zoomAfterSelection == nil)
        // The run already on the wall is shown at once, zoomed to the worker named.
        ui.showRun("R-1", worker: "w-2", current: "R-1") { selected.append($0) }
        #expect(selected == ["R-2"] && ui.zoomedWorkerID == "w-2" && ui.returnFocusWorkerID == "w-2")
        ui.showRun("R-1", current: "R-1") { selected.append($0) }
        #expect(ui.zoomedWorkerID == nil)

        ui.composingRun = true
        ui.showProject(Self.projectID)
        #expect(ui.shellPlace == LiveShell.project(Self.projectID) && !ui.composingRun && ui.wallHidden)
    }

    @Test func aTypedHostPathMustBeAbsolute() {
        #expect(ProjectFolderPicker.typed("  /srv/relay/ \n") == "/srv/relay")
        #expect(ProjectFolderPicker.typed("/") == "/")
        #expect(ProjectFolderPicker.typed("~/relay") == nil && ProjectFolderPicker.typed("relay") == nil)
        #expect(ProjectFolderPicker.typed("") == nil)
    }

    // MARK: The router

    @Test func aLinkWaitsForTheWindowAndOnlyTheLastIsFollowed() throws {
        var presented = 0
        var followed: [CommanderLink] = []
        var shown: [CommanderOpenRequest] = []
        let router = CommanderWindowRouter(present: { presented += 1 })
        // A cold launch: the link arrives before the cockpit exists.
        router.open(.run(Self.runID))
        router.open(.project(Self.projectID))
        #expect(presented == 2 && followed.isEmpty && router.waitingLink == .project(Self.projectID))
        let token = router.attach({ shown.append($0) }, follow: { followed.append($0) })
        #expect(followed == [.project(Self.projectID)] && router.waitingLink == nil && shown.isEmpty)

        // A list of URLs: join links and strangers are left alone.
        let urls = try ["agentcommander://join?server=lab.example", "agentcommander://run/\(Self.runID)", "https://example.com"]
            .map { try #require(URL(string: $0)) }
        #expect(router.open(links: urls) && followed.last == .run(Self.runID))
        #expect(!router.open(links: [urls[0], urls[2]]) && followed.count == 2)

        // A window that takes no links leaves one waiting; a closed window does too.
        router.detach(token)
        router.open(.run(Self.runID))
        router.attach { shown.append($0) }
        #expect(router.waitingLink == .run(Self.runID) && followed.count == 2)
    }

    // MARK: The model

    @Test func theModelReadsTheCatalogAndToleratesAServiceWithoutOne() async {
        let model = CockpitModel(endpoint: ServiceEndpoint(environment: ["AGENT_COMMANDER_SOCKET": "/tmp/ac-projects-test.sock"]))
        #expect(model.projectCatalog == .unknown && model.projects.isEmpty)
        let listed = [Self.relay, Self.empty]
        model.readProjects = { listed }
        await model.refreshProjects()
        #expect(model.projectCatalog == .supported && model.projects == listed)
        #expect(model.lists(.project(Self.projectID)) && !model.lists(.project("p-gone")) && !model.lists(.run(Self.runID)))

        // A passing failure keeps the last list.
        model.readProjects = { throw ServiceError.offline("down") }
        await model.refreshProjects()
        #expect(model.projectCatalog == .supported && model.projects == listed)

        // An older service has no route: no catalog, and it is not asked again.
        model.readProjects = { throw ServiceStatusError(status: 404, message: "Not Found") }
        await model.refreshProjects()
        #expect(model.projectCatalog == .unsupported && model.projects.isEmpty)
        model.readProjects = { listed }
        await model.refreshProjects()
        #expect(model.projectCatalog == .unsupported && model.projects.isEmpty)

        // A link's target is only ever looked up: one the service doesn't list is not found.
        let found = await model.awaitTarget(of: .project(Self.projectID), settle: .milliseconds(40), limit: .milliseconds(120),
                                            step: .milliseconds(10))
        #expect(!found && model.runs.isEmpty)
    }
}
