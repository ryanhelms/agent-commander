import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// The live main-window shell, built from values:
//   1. The navigation comes from the cockpit's runs and the network's state.
//   2. Needs you merges the person's stopped workers with the network's requests, in the order of
//      urgency, and each row offers only the answers the models can take.
//   3. The window's place follows the cockpit: a project on the wall, New run in the form.

@MainActor @Suite struct ShellLiveTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two servers (one offline), two approvals, an access request, a friend request, a workspace.
    static let network: ShellNetwork = {
        var network = ShellNetwork()
        network.servers = [
            MultiplayerServerSummary(id: "srv-studio", url: "https://studio.example", name: "studio", state: .online,
                                     signedIn: true, handle: "ryan", presence: .online),
            MultiplayerServerSummary(id: "srv-lab", url: "https://lab.example", name: "lab", state: .offline)
        ]
        network.approvals = [
            MultiplayerPending(server: "srv-studio", item: MultiplayerApproval(
                id: "ap-1", peer: "jonah", resource: "res-docs", action: MultiplayerSharePolicy.ask, summary: "Read docs/retries.md",
                arrived: now.addingTimeInterval(-130), expires: now.addingTimeInterval(700))),
            MultiplayerPending(server: "srv-studio", item: MultiplayerApproval(
                id: "ap-2", peer: "mira", resource: "res-relay", action: MultiplayerSharePolicy.handoff, summary: "Run the integration tests",
                arrived: now.addingTimeInterval(-48), expires: now.addingTimeInterval(252)))
        ]
        network.access = [
            MultiplayerPending(server: "srv-studio", item: MultiplayerAccessRequest(
                id: "ac-1", resource: "res-relay", owner: "ryan", requester: "ines", actions: [MultiplayerSharePolicy.watch],
                createdAt: now.addingTimeInterval(-1_260)))
        ]
        network.friendRequests = [
            ShellNetwork.FriendRequest(server: "srv-studio", request: MultiplayerIncoming(id: "fr-1", handle: "tomas"))
        ]
        network.workspaces = [
            MultiplayerPending(server: "srv-studio", item: MultiplayerWorkspace(id: "ws-1", name: "Relay launch"))
        ]
        network.resourceNames = ["srv-studio/res-docs": "docs-agent", "srv-studio/res-relay": "relay-worker"]
        network.handoffs = 2
        network.friendsOnline = 3
        network.presence = .online
        network.presenceChoice = .auto
        return network
    }()

    static let runs = [
        RunSummary(id: "R-1", project: "Relay", path: "/code/relay", title: "Retry policy", status: .running),
        RunSummary(id: "R-2", project: "Beacon", path: "/code/beacon", title: "Field names", status: .running),
        RunSummary(id: "R-3", project: "Relay", path: "/code/relay", title: "Backoff", status: .running)
    ]

    static func navigation(place: String = LiveShell.wall, openRunPath: String? = "/code/relay", composing: Bool = false,
                           needsYou: Int = 6, network: ShellNetwork = network) -> CommanderNavigation {
        LiveShell.navigation(runs: runs, openRunPath: openRunPath, composing: composing, place: place,
                             needsYou: needsYou, network: network)
    }

    // MARK: Navigation

    @Test func navigationListsTheModesAndTheirPlacesFromLiveState() {
        let navigation = Self.navigation()
        #expect(navigation.modeItems.map(\.mode.title) == ["Agents", "Network", "People", "Teams", "Settings"])
        #expect(navigation.modeItems.last?.mode.isTrailing == true)
        let known = Set(navigation.places.map(\.id))
        #expect(known.count == navigation.places.count)
        #expect(Set(navigation.modes.flatMap(\.placeIDs)) == known, "the rail reaches every place")

        // Agents: the inbox, runs, new run, then one row per project.
        let agents = navigation.contextSections
        #expect(agents.map(\.group.title) == ["Workspace", "Projects"])
        #expect(agents[0].items.map(\.place.title) == ["Needs you", "Runs", "New run"])
        #expect(agents[1].items.map(\.place.title) == ["Relay", "Beacon"])
        #expect(agents[1].items.allSatisfy { $0.place.canShare })
        #expect(agents[0].items[0].place.badge == "6" && agents[0].items[0].place.isHot)
        // No context row takes a ⌘-number: ⌘1 stays the coordinator's.
        #expect(agents.flatMap(\.items).allSatisfy { $0.shortcut == nil })

        let network = Self.navigation(place: LiveShell.servers).contextSections.flatMap(\.items).map(\.place)
        #expect(network.map(\.title) == ["Servers", "Directory", "Approvals", "Hand-offs", "Threads", "Audit", "Fan-out", "Shared"])
        #expect(network[0].badge == "1/2" && !network[0].isHot)
        #expect(network[2].badge == "2" && network[2].isHot)
        #expect(network[3].badge == "2" && !network[3].isHot)

        #expect(Self.navigation(place: LiveShell.people).contextSections.flatMap(\.items).map(\.place.spoken)
                == ["People, 3 friends online"])
        #expect(Self.navigation(place: "team:srv-studio/ws-1").contextSections.flatMap(\.items).map(\.place.title)
                == ["Relay launch"])
    }

    @Test func railCountsWhatNeedsThePerson() {
        let modes = Self.navigation().modeItems
        #expect(modes.first { $0.id == "agents" }?.hotCount == 6)
        #expect(modes.first { $0.id == "network" }?.hotCount == 2)
        #expect(modes.first { $0.id == "people" }?.hotCount == 0)
        #expect(Self.navigation(needsYou: 0).modeItems.first?.hotCount == 0)
    }

    @Test func selectionFollowsTheCockpit() {
        // On the wall the open run's project is the selected row.
        #expect(Self.navigation().selection == LiveShell.project("/code/relay"))
        #expect(Self.navigation().selectedModeID == "agents")
        // With no run open, Runs is.
        #expect(Self.navigation(openRunPath: nil).selection == LiveShell.wall)
        // The new-run form selects New run wherever the window was.
        #expect(Self.navigation(place: LiveShell.needsYou, composing: true).selection == LiveShell.newRun)
        #expect(Self.navigation(place: LiveShell.needsYou).selection == LiveShell.needsYou)
        #expect(Self.navigation(place: LiveShell.settings).selectedModeID == "settings")
        // A workspace that is gone leaves the window on the wall.
        #expect(Self.navigation(place: "team:srv-studio/gone").selection == LiveShell.project("/code/relay"))
        for id in [LiveShell.wall, LiveShell.newRun, LiveShell.project("/code/relay")] { #expect(LiveShell.showsWall(id)) }
        for id in [LiveShell.needsYou, LiveShell.settings, LiveShell.servers] { #expect(!LiveShell.showsWall(id)) }
    }

    @Test func switchingModeGoesToItsFirstPlaceAndTheCrumbsNameThePlace() {
        var navigation = Self.navigation()
        navigation.apply(.selectMode("network"))
        #expect(navigation.selection == LiveShell.servers)
        #expect(navigation.crumbs == ["Network", "Servers"])
        navigation.apply(.selectMode("agents"))
        #expect(navigation.selection == LiveShell.needsYou)
        navigation.apply(.selectMode("teams"))
        #expect(navigation.crumbs == ["Teams", "Relay launch"])
        // A place named like its mode is said once.
        navigation.apply(.selectMode("people"))
        #expect(navigation.crumbs == ["People"])
        // Sharing a project changes nothing in the navigation.
        let before = navigation
        navigation.apply(.share(LiveShell.project("/code/relay")))
        #expect(navigation == before)
    }

    @Test func anEmptyNetworkStillHasAPlaceInEveryMode() {
        let navigation = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: LiveShell.wall,
                                              needsYou: 0, network: ShellNetwork())
        #expect(navigation.modes.allSatisfy { !$0.placeIDs.isEmpty })
        #expect(navigation.selection == LiveShell.wall)
        #expect(navigation.contextSections.map(\.group.title) == ["Workspace"])
        #expect(navigation.place(LiveShell.servers)?.badge == nil)
        #expect(navigation.place(LiveShell.workspaces) != nil)
        #expect(navigation.profile?.presenceTitle == "Signed out")
        #expect(ShellNetwork().health.tone == .neutral)
        #expect(LiveShell.note(for: LiveShell.servers, network: ShellNetwork()).hasPrefix("No server yet"))
    }

    @Test func modeShortcutsLeaveTheCockpitKeysAlone() {
        #expect(LiveShell.modeModifiers == [.command, .option])
        #expect(LiveShell.modeModifiers.shellKeyCap == "⌥⌘")
        #expect(EventModifiers.command.shellKeyCap == "⌘")
        #expect(Self.navigation().modeItems.map(\.shortcut) == [1, 2, 3, 4, 5])
    }

    // MARK: Needs you

    static var pending: [RequestPresentation] { DesignFixture.requests }

    @Test func inboxMergesWorkersAndTheNetworkInTheOrderOfUrgency() {
        let inbox = LiveShell.inbox(pending: Self.pending, network: Self.network, now: Self.now)
        #expect(inbox.pendingCount == Self.pending.count + 4)
        #expect(inbox.localCount == Self.pending.count)
        #expect(inbox.networkCount == 4)
        let ordered = inbox.ordered
        // Under five minutes left goes first, whatever its kind.
        #expect(ordered.first?.id == "approval:srv-studio/ap-2")
        #expect(ordered.first?.expiresIn == 252)
        // Then the person's own workers, in the cockpit's order (oldest first).
        #expect(ordered.dropFirst().prefix(Self.pending.count).map(\.id) == Self.pending.map(\.id))
        // Then the other approval, the access request and the friend request.
        #expect(ordered.suffix(3).map(\.id) == ["approval:srv-studio/ap-1", "access:srv-studio/ac-1", "friend:srv-studio/fr-1"])
        #expect(inbox.soonestEnd == 252)
        #expect(inbox.summary == "\(Self.pending.count) from your workers, 4 from the network")
    }

    @Test func rowsSayWhereTheyCameFromAndOfferOnlyWhatCanBeDone() throws {
        let inbox = LiveShell.inbox(pending: Self.pending, network: Self.network, now: Self.now)
        let local = try #require(inbox.items.first)
        let request = try #require(Self.pending.first)
        #expect(local.origin == .worker(name: request.workerName, host: request.host))
        #expect(local.kind.isLocal && local.verbs == [.reply] && local.waiting == nil)

        let approval = try #require(inbox.items.first { $0.id == "approval:srv-studio/ap-1" })
        #expect(approval.origin == .friend(handle: "jonah", server: "studio", serverID: "srv-studio"))
        #expect(approval.detail.hasPrefix("docs-agent on studio"))
        #expect(approval.verbs == [.deny, .approve])
        #expect(approval.waiting == 130 && approval.expiresIn == 700)

        let access = try #require(inbox.items.first { $0.id == "access:srv-studio/ac-1" })
        #expect(access.title == "ines asks for access")
        #expect(access.detail.hasPrefix("relay-worker on studio."))
        #expect(access.verbs == [.decline, .review] && access.waiting == 1_260)

        // The network model has no way to decline a friend request, so the row offers Accept alone.
        let friend = try #require(inbox.items.first { $0.id == "friend:srv-studio/fr-1" })
        #expect(friend.title == "tomas sent a friend request")
        #expect(friend.verbs == [.accept])
    }

    @Test func aDecidedRequestShowsItsOutcomeEvenAfterItsSourceDropsIt() throws {
        var approved = try #require(LiveShell.inbox(pending: [], network: Self.network, now: Self.now)
            .items.first { $0.id == "approval:srv-studio/ap-1" })
        approved.decision = .approved
        // Still listed by the model: the decided form replaces the waiting one, in place.
        let during = LiveShell.inbox(pending: [], network: Self.network, now: Self.now, decided: [approved])
        #expect(during.items.count == 4)
        #expect(during.items.first { $0.id == approved.id }?.decision == .approved)
        #expect(during.pendingCount == 3)
        // Dropped by the model: the outcome still shows.
        var after = Self.network
        after.approvals.removeAll { $0.item.id == "ap-1" }
        let later = LiveShell.inbox(pending: [], network: after, now: Self.now, decided: [approved])
        #expect(later.items.count == 4 && later.pendingCount == 3)
        // Once the outcome has been shown the row is gone.
        #expect(LiveShell.inbox(pending: [], network: after, now: Self.now).items.count == 3)
    }

    @Test func aLapsedCountdownStopsAtZeroAndAnEmptyInboxIsEmpty() {
        let late = LiveShell.inbox(pending: [], network: Self.network, now: Self.now.addingTimeInterval(10_000))
        #expect(late.items.compactMap(\.expiresIn).allSatisfy { $0 == 0 })
        let empty = LiveShell.inbox(pending: [], network: ShellNetwork(), now: Self.now)
        #expect(empty.items.isEmpty && empty.summary == nil)
    }

    // MARK: Presentation state

    @Test func theWallIsTheDefaultPlaceAndRevealingARequestReturnsToIt() throws {
        let ui = CockpitPresentationState()
        #expect(ui.shellPlace == LiveShell.wall && !ui.wallHidden)
        ui.shellPlace = LiveShell.needsYou
        #expect(ui.wallHidden)
        let request = try #require(Self.pending.first)
        ui.reveal(request, from: nil, selectRun: { _ in })
        #expect(!ui.wallHidden)
    }

    @Test func aRequestIsNotCountedAsInViewWhileAnotherPageShows() throws {
        let store = PreviewStore(scenario: .coordinatorWall)
        let content = DesignFixture.content(for: store)
        let ui = CockpitPresentationState()
        ui.suppressesVisibleSources = true
        ui.cockpitWindowAttended = true
        let request = try #require(content.pending.first { content.shownRequestID(ofWorker: $0.workerID) == $0.id && !$0.workerIsCoordinator })
        ui.visibleConsoles = [ConsoleVisibility.key(.wall, request.workerID)]
        #expect(content.isSourceInView(request, ui))
        ui.shellPlace = LiveShell.needsYou
        #expect(!content.isSourceInView(request, ui))
    }
}
