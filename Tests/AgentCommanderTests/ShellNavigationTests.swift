import Foundation
import Testing
@testable import AgentCommander

// The navigation model that the three sidebar templates share, and the Needs you inbox:
//   1. One model arranges the same places as a grouped list, a pinned-inbox list and a mode rail.
//   2. Selection, folding and presence change only through CommanderNavigationAction.
//   3. The inbox orders requests by urgency and a decision is recorded once.

@Suite struct ShellNavigationTests {
    static func sample(selection: String = "all-agents", collapsed: Set<String> = []) -> CommanderNavigation {
        ShellSample.navigation(inbox: ShellSample.inbox, attention: 2, selection: selection, collapsed: collapsed)
    }

    @Test func everyArrangementNamesOnlyKnownPlacesAndEveryPlaceIsReachable() {
        let navigation = Self.sample()
        let known = Set(navigation.places.map(\.id))
        #expect(known.count == navigation.places.count, "place IDs are unique")
        let listed = navigation.groups.flatMap(\.placeIDs) + navigation.footer
        let inModes = navigation.modes.flatMap(\.placeIDs)
        #expect(Set(listed).isSubset(of: known))
        #expect(Set(inModes).isSubset(of: known))
        // The mode rail reaches every place, and no place sits in two modes.
        #expect(Set(inModes) == known)
        #expect(inModes.count == known.count)
    }

    @Test func groupedListShowsTheSketchedPlacesWithCounts() {
        let sections = Self.sample().sections(pinningInbox: false, folding: false)
        #expect(sections.map(\.group.title) == ["Workspace", "Projects", "Network", "Teams"])
        #expect(sections[0].items.map(\.place.title) == ["Needs you", "Runs", "All agents", "Attention", "History"])
        #expect(sections[2].items.map(\.place.title) == ["People", "Servers", "Shared"])
        let attention = sections[0].items[3].place
        #expect(attention.badge == "2" && attention.isHot)
        let servers = sections[2].items[1].place
        #expect(servers.badge == "2/3" && !servers.isHot)
        #expect(servers.spoken == "Servers, 2 of 3")
        #expect(sections[2].items[0].place.spoken == "People, 4 friends")
        // Detail pages are rows only in the context list.
        #expect(!sections.flatMap(\.items).contains { $0.place.isDetail })
        // A template that doesn't fold gets every group open.
        #expect(!sections.contains { $0.group.isCollapsible || $0.isCollapsed })
    }

    @Test func shortcutsRunDownTheVisibleRows() {
        let grouped = Self.sample().sections(pinningInbox: false, folding: false).flatMap(\.items)
        #expect(grouped.prefix(9).map(\.shortcut) == Array(1...9))
        #expect(grouped.dropFirst(9).allSatisfy { $0.shortcut == nil })
        let pinned = Self.sample()
        #expect(pinned.inboxItem?.shortcut == 1)
        #expect(pinned.sections(pinningInbox: true).first?.items.first?.shortcut == 2)
        #expect(pinned.footerItems.allSatisfy { $0.shortcut == nil })
        #expect(pinned.modeItems.map(\.shortcut) == [1, 2, 3, 4, 5])
    }

    @Test func pinningTheInboxLeavesOutThePlacesItStandsInFor() {
        let navigation = Self.sample()
        let sections = navigation.sections(pinningInbox: true)
        #expect(sections[0].items.map(\.place.id) == ["runs", "all-agents", "history"])
        #expect(navigation.inboxItem?.place.count == 7)
        #expect(navigation.inbox?.summary == "3 from your workers, 4 from the network")
        // The inbox row is selected while a queue it stands in for is showing.
        #expect(navigation.inboxItem?.isSelected == false)
        #expect(Self.sample(selection: "attention").inboxItem?.isSelected == true)
        #expect(Self.sample(selection: "needs-you").inboxItem?.isSelected == true)
    }

    @Test func modeRailFollowsTheSelectionAndCountsEachRequestOnce() {
        let navigation = Self.sample(selection: "network.approvals")
        #expect(navigation.selectedModeID == "network")
        let modes = navigation.modeItems
        #expect(modes.map(\.mode.title) == ["Agents", "Network", "People", "Teams", "Settings"])
        #expect(modes.last?.mode.isTrailing == true)
        #expect(modes.filter(\.isSelected).map(\.id) == ["network"])
        // Agents holds the inbox (7) and Attention (2), which the inbox already counts.
        #expect(modes[0].hotCount == 7)
        #expect(modes[1].hotCount == 2)
        #expect(modes[2].hotCount == 1)
        #expect(navigation.contextSections.flatMap(\.items).map(\.place.title)
                == ["Servers", "Directory", "Approvals", "Hand-offs", "Threads", "Audit", "Fan-out", "Shared"])
        #expect(navigation.crumbs == ["Network", "Approvals"])
    }

    @Test func actionsSelectFoldAndSetPresence() {
        var navigation = Self.sample()
        navigation.apply(.select("history"))
        #expect(navigation.selection == "history")
        navigation.apply(.select("no-such-place"))
        #expect(navigation.selection == "history")

        navigation.apply(.selectMode("network"))
        #expect(navigation.selection == "network.servers")
        // Choosing the mode that is already showing keeps the page.
        navigation.apply(.select("network.audit"))
        navigation.apply(.selectMode("network"))
        #expect(navigation.selection == "network.audit")

        navigation.apply(.toggleGroup("teams"))
        #expect(navigation.collapsed == ["teams"])
        #expect(navigation.sections(pinningInbox: true).first { $0.id == "teams" }?.isCollapsed == true)
        navigation.apply(.toggleGroup("workspace"))
        #expect(navigation.collapsed == ["teams"], "the workspace group does not fold")
        // Selecting a place inside a folded group opens it.
        navigation.apply(.select("team.infra-guild"))
        #expect(navigation.collapsed.isEmpty)

        navigation.apply(.setPresence(.busy))
        #expect(navigation.profile?.choice == .busy)
        #expect(navigation.profile?.presence == .busy)
        #expect(navigation.profile?.presenceTitle == "Busy")
    }

    @Test func foldedGroupKeepsItsHotCount() {
        var navigation = Self.sample()
        navigation.groups[2].placeIDs.append("network.approvals")
        navigation.places[navigation.places.firstIndex { $0.id == "network.approvals" }!].isDetail = false
        navigation.apply(.toggleGroup("network"))
        let network = navigation.sections(pinningInbox: false).first { $0.id == "network" }
        #expect(network?.isCollapsed == true)
        #expect(network?.hotCount == 2)
    }

    @Test func serverHealthToneFollowsHowManyAnswer() {
        #expect(CommanderServerHealth(online: 3, total: 3).tone == .working)
        #expect(CommanderServerHealth(online: 2, total: 3).tone == .attention)
        #expect(CommanderServerHealth(online: 0, total: 3).tone == .failure)
        #expect(CommanderServerHealth(online: 0, total: 0).tone == .neutral)
        #expect(CommanderServerHealth(online: 2, total: 3).figure == "2/3")
    }

    @Test func shellScenariosLaunchByNameAndMapToAConcept() {
        #expect(DesignPreviewScenario(rawValue: "shell-a") == .shellA)
        #expect(DesignPreviewScenario(rawValue: "shell-b") == .shellB)
        #expect(DesignPreviewScenario(rawValue: "shell-c") == .shellC)
        #expect(DesignPreviewScenario(rawValue: "needs-you") == .needsYou)
        #expect(ShellConcept(scenario: .shellB) == .modeRail)
        #expect(ShellConcept(scenario: .needsYou) == .needsYouFirst)
        #expect(ShellConcept(scenario: .coordinatorWall) == nil)
        for concept in ShellConcept.allCases { #expect(concept.scenario.isShell && !concept.scenario.isCockpit) }
        #expect(DesignPreviewScenario.allCases.filter(\.isShell).allSatisfy { DesignPreviewScenario.groups.contains($0.info.group) })
    }
}

@Suite struct NeedsYouTests {
    @Test func ordersByUrgency() {
        let inbox = ShellSample.inbox
        // About to lapse, then stopped workers (longest wait first), then the network approval
        // with time left, then access, then the friend request.
        #expect(inbox.ordered.map(\.id) == ["N-114", "Q-018", "Q-021", "A-007", "N-118", "X-207", "F-031"])
        #expect(inbox.ordered.map(NeedsYouInbox.rank) == [0, 1, 1, 1, 2, 3, 4])
    }

    @Test func aRequestAboutToLapseGoesFirstWhateverItsKind() {
        var inbox = ShellSample.inbox
        let friend = inbox.items.firstIndex { $0.id == "F-031" }!
        inbox.items[friend].expiresIn = 30
        #expect(inbox.ordered.map(\.id).prefix(2) == ["F-031", "N-114"])
        inbox.items[friend].expiresIn = NeedsYouInbox.closing
        #expect(inbox.ordered.last?.id == "F-031", "exactly five minutes left is not yet closing")
    }

    @Test func countsAndSummaryFollowWhatIsPending() {
        var inbox = ShellSample.inbox
        #expect(inbox.pendingCount == 7 && inbox.localCount == 3 && inbox.networkCount == 4)
        #expect(inbox.pendingCount(of: .networkApproval) == 2)
        #expect(inbox.soonestEnd == 252)
        let approved = inbox.decide("N-114", .approved)
        #expect(approved)
        #expect(inbox.pendingCount == 6 && inbox.networkCount == 3)
        #expect(inbox.soonestEnd == 700)
        for id in ["N-118", "X-207", "F-031"] { inbox.decide(id, .declined) }
        #expect(inbox.summary == "3 from your workers")
        for id in ["Q-018", "Q-021"] { inbox.decide(id, .replied("No")) }
        inbox.decide("A-007", .denied)
        #expect(inbox.pendingCount == 0 && inbox.summary == nil)
    }

    @Test func aDecisionIsRecordedOnceAndKeepsTheRowInPlace() {
        var inbox = ShellSample.inbox
        let before = inbox.ordered.map(\.id)
        let first = inbox.decide("A-007", .approved)
        let second = inbox.decide("A-007", .denied)
        #expect(first && !second, "the first decision stands")
        #expect(inbox.items.first { $0.id == "A-007" }?.decision == .approved)
        let unknown = inbox.decide("no-such-request", .approved)
        #expect(!unknown)
        let result1 = inbox.decide("Q-018", .replied("   "))
        #expect(!result1, "an empty reply is not sent")
        #expect(inbox.items.first { $0.id == "Q-018" }?.isPending == true)
        #expect(inbox.ordered.map(\.id) == before, "a decided row shows its outcome where it was")

        // Clearing removes only a decided request; withdrawing removes only a pending one.
        inbox.clear("Q-018")
        inbox.withdraw("A-007")
        #expect(inbox.items.count == 7)
        inbox.clear("A-007")
        inbox.withdraw("Q-018")
        #expect(inbox.ordered.map(\.id) == ["N-114", "Q-021", "N-118", "X-207", "F-031"])
    }

    @Test func eachKindOffersItsAnswersWithOnePrimary() {
        func verbs(_ kind: NeedsYouItem.Kind) -> [NeedsYouVerb] {
            NeedsYouItem(id: "x", kind: kind, origin: .worker(name: "w", host: "h"), title: "", detail: "", waiting: 0).verbs
        }
        #expect(verbs(.workerQuestion) == [.reply])
        #expect(verbs(.workerApproval) == [.deny, .approve])
        #expect(verbs(.networkApproval) == [.deny, .approve])
        #expect(verbs(.accessRequest) == [.decline, .review])
        #expect(verbs(.friendRequest) == [.decline, .accept])
        for kind in NeedsYouItem.Kind.allCases {
            #expect(verbs(kind).filter(\.isPrimary).count == 1)
            #expect(verbs(kind).last?.isPrimary == true)
        }
        #expect(NeedsYouVerb.reply.decision == nil)
        #expect(NeedsYouVerb.approve.decision == .approved && NeedsYouVerb.deny.decision == .denied)
        #expect(NeedsYouVerb.review.decision == .inReview && NeedsYouVerb.accept.decision == .accepted)
        #expect(NeedsYouDecision.denied.tone == .failure && NeedsYouDecision.replied("ok").title == "Replied")
    }

    @Test func clockReadsAsAgeOrTimeLeft() {
        #expect(NeedsYouClock.age(48) == "48s")
        #expect(NeedsYouClock.age(410) == "6m")
        #expect(NeedsYouClock.age(5_400) == "1h 30m")
        #expect(NeedsYouClock.left(252) == "4:12")
        #expect(NeedsYouClock.left(-3) == "0:00")
    }

    @MainActor @Test func previewStateDecidesShowsTheOutcomeThenClears() async throws {
        let state = ShellPreviewState(selection: "needs-you")
        state.outcomeDwell = .milliseconds(40)
        state.decide("N-114", .approved)
        #expect(state.inbox.items.first { $0.id == "N-114" }?.decision == .approved)
        #expect(state.navigation(attention: 2, answered: []).place("needs-you")?.count == 6)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!state.inbox.items.contains { $0.id == "N-114" })
        // A question answered in the Attention queue leaves the inbox and its count.
        #expect(state.inbox(answered: ["Q-018"]).pendingCount == 5)
        let navigation = state.navigation(attention: 1, answered: ["Q-018"])
        #expect(navigation.place("needs-you")?.count == 5)
        state.apply(.select("history"), to: navigation)
        #expect(state.selection == "history")
    }
}
