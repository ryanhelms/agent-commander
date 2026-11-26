import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// The tray's token layer reads the app theme, and what the main window asked the tray for after
// increment 4: an apply that answers for its artifact, a zoom whose footer and suggestions the
// caller decides, a countdown with a clock, wall reads with no panel open, a worker's resource, and
// removing a server by value. Also two defects from the window's check: the certificate review's
// accessibility tree, and how long an answered row is held.

/// Reads a tray colour token as a view would, in the theme given.
@MainActor private func resolved(_ color: Color, in theme: Theme, contrast: Bool = false) -> Color.Resolved {
    var environment = EnvironmentValues()
    environment.theme = theme
    environment.increaseContrastOverride = contrast
    return color.resolve(in: environment)
}

@MainActor private func resolved(_ color: ThemeColor) -> Color.Resolved { color.color.resolve(in: EnvironmentValues()) }

@MainActor @Suite struct MultiplayerTrayThemeTests {
    @Test func aColourTokenIsTheRoleOfTheThemeItIsDrawnIn() {
        for theme in [Theme.console, Theme.blackGlass] {
            #expect(resolved(MultiplayerTheme.hair, in: theme) == resolved(theme.color.hair))
            #expect(resolved(MultiplayerTheme.focus, in: theme) == resolved(theme.color.focus))
            #expect(resolved(MultiplayerTheme.fieldFill, in: theme) == resolved(theme.surface.fieldFill))
            #expect(resolved(MultiplayerTheme.controlEdge, in: theme) == resolved(theme.surface.controlEdge))
            #expect(resolved(MultiplayerTheme.groupFill, in: theme) == resolved(theme.wall.groupFill))
            // A token with its opacity changed still follows the theme.
            #expect(resolved(MultiplayerTheme.failure.opacity(0.45), in: theme) == resolved(theme.color.failure.opacity(0.45)))
        }
        // The two themes differ where their tokens do, so the token is not a fixed colour.
        #expect(resolved(MultiplayerTheme.hair, in: .console) != resolved(MultiplayerTheme.hair, in: .blackGlass))
        // Increase Contrast swaps the rule and outline roles, as it does in the main window.
        #expect(resolved(MultiplayerTheme.border, in: .console, contrast: true) == resolved(Theme.console.contrast.strongBorder))
    }

    @Test func consoleKeepsTheValuesTheTrayAlwaysDrew() {
        let console = Theme.console
        // The surface roles the atoms now read are, in console, the base roles they read before.
        #expect(console.surface.fieldFill == console.color.well && console.surface.fieldEdge == console.color.border)
        #expect(console.surface.markFill == console.color.well && console.surface.markEdge == console.color.border)
        #expect(console.surface.controlEdge == console.color.border && console.surface.controlInk == console.color.foreground)
        #expect(console.surface.primaryFill == .flat(console.color.focus) && console.surface.primaryEdge == console.color.focus)
        #expect(console.surface.tagEdge == console.color.border && console.surface.footerFill == console.color.well)
        #expect(console.surface.unselectedFill == console.color.well && console.surface.panelFill == .flat(console.color.panel))
        #expect(console.surface.panelEdge == console.color.hair)
        #expect(console.surface.highlightFill == console.color.attention && console.surface.highlightInk == console.color.onAccent)
        #expect(console.surface.controlFill.stops.allSatisfy { $0.opacity == 0 })
        // Sizes that were written into the atoms.
        #expect(console.space.controlHeight == 24 && console.space.controlHeightLarge == 28 && console.space.fieldHeight == 30)
        #expect(console.space.tabHeight == 34 && console.space.chipHeightMin == 16 && console.space.chipHeightMax == 18)
        #expect(console.space.sectionInset == 14 && console.space.bandTop == 10 && console.space.bandBottom == 12)
        #expect(console.line.selectedMarker == 2 && console.line.focusedField == 1.5 && console.line.hairline == 1)
        #expect(console.radius.tile == 2 && console.radius.control == 2 && console.radius.chip == 1)
        // The tray button: mono 11 medium, 12 when large, semibold when primary.
        #expect(console.trayButtonType(large: false, primary: false) == Font.system(size: 11, weight: .medium, design: .monospaced))
        #expect(console.trayButtonType(large: true, primary: true) == Font.system(size: 12, weight: .semibold, design: .monospaced))
    }

    @Test func aTypeTokenIsTheRoleOfTheThemeItIsDrawnIn() {
        #expect(MultiplayerTheme.sub.font(in: .console) == Theme.console.type.sub.font)
        #expect(MultiplayerTheme.sub.font(in: .blackGlass) == Theme.blackGlass.type.sub.font)
        #expect(MultiplayerTheme.heading.font(in: .console) != MultiplayerTheme.heading.font(in: .blackGlass))
        #expect(MultiplayerTheme.figure.monospacedDigit().font(in: .console) == Theme.console.type.figure.font.monospacedDigit())
        #expect(MultiplayerTheme.groupTitle.font(in: .blackGlass) == Theme.blackGlass.wall.groupTitleType.font)
    }

    @Test func theSwitchIsTheThemesOwnFormAndStillSaysItsLabel() async throws {
        for theme in [Theme.console, Theme.blackGlass] {
            let toggle = Toggle("Remote access", isOn: .constant(true)).toggleStyle(MultiplayerSwitchStyle())
                .environment(\.theme, theme)
            let nodes = try await MultiplayerAX.nodes(of: toggle)
            #expect(nodes.contains { $0.label == "Remote access" }, "\(theme.name): \(nodes)")
        }
    }
}

// MARK: - What the window asked for

@MainActor @Suite struct MultiplayerWindowRequestTests {
    static let home = "s-home"

    // 1. Apply answers for its artifact and names the saved file's final name.
    @Test func applyAnswersForItsArtifactAndNamesTheSavedFile() async throws {
        let handoff = #"{"request":"rq-1","id":"c-1","status":"ok","value":{"run":"run-1","worker":"w-1"}}"#
        let result = ##"{"request":"rq-9","id":"c-9","status":"ok","value":{"run":"run-1","state":"completed","summary":"Done.","artifacts":[{"kind":"report","name":"report.md","content":"# Done"},{"kind":"patch","name":"fix.patch","content":"--- a\n"}]}}"##
        let (model, helper) = MultiplayerShareModelTests.model([
            .send: [MultiplayerFixture.output(#"{"ok":true,"data":\#(handoff)}"#), MultiplayerFixture.output(#"{"ok":true,"data":\#(result)}"#)],
            .applyArtifact: [MultiplayerFixture.output(#"{"ok":true,"data":{"saved":"/tmp/relay/report.md.1a2b3c4d"}}"#),
                             MultiplayerFixture.output(#"{"ok":true,"data":{"applied":"fix.patch"}}"#),
                             MultiplayerFixture.output(#"{"ok":true,"data":{"saved":"/tmp/relay/report.md"}}"#),
                             MultiplayerFixture.output(#"{"ok":false,"error":"the patch does not apply"}"#)]])
        model.open()
        await model.settle()
        model.share.startHandoff("dir-1", on: Self.home)
        model.share.handoffDraft.title = "Fix the test"
        model.share.handoffDraft.task = "Make it pass."
        await model.share.sendHandoff()?.value
        let row = try #require(model.share.handoff("rq-1", on: Self.home))
        let place = model.route

        // Nothing is sent before the result is read, or to a path that isn't absolute.
        let early = await model.apply(artifact: 0, of: row, on: Self.home, checkout: "/tmp/relay")
        #expect(early == .failed(id: "rq-1", server: Self.home, reason: "Couldn’t apply the artifact. Read the hand-off’s result first."))
        await model.share.check(row, on: Self.home, result: true)?.value
        let relative = await model.apply(artifact: 0, of: row, on: Self.home, checkout: "relay")
        #expect(relative.reason == "Couldn’t apply report.md. Choose a local checkout.")
        let missing = await model.apply(artifact: 7, of: row, on: Self.home, checkout: "/tmp/relay")
        #expect(missing.reason == "Couldn’t apply the artifact. That artifact is no longer in the result.")
        #expect(helper.count(.applyArtifact) == 0)

        // A file saved under another name: the message says which.
        let saved = await model.apply(artifact: 0, of: row, on: Self.home, checkout: "/tmp/relay")
        #expect(saved == .done(id: "rq-1", server: Self.home, message: "Saved report.md into relay as report.md.1a2b3c4d."))
        #expect(model.notice == saved.message)
        let patched = await model.apply(artifact: 1, of: row, on: Self.home, checkout: "/tmp/relay")
        #expect(patched.message == "Applied fix.patch to relay. The changes are staged, not committed.")
        let plain = await model.apply(artifact: 0, of: row, on: Self.home, checkout: "/tmp/relay")
        #expect(plain.message == "Saved report.md into relay.")
        let refused = await model.apply(artifact: 1, of: row, on: Self.home, checkout: "/tmp/relay")
        #expect(refused.reason == "Couldn’t apply fix.patch. the patch does not apply" || refused.reason?.hasPrefix("Couldn’t apply fix.patch.") == true)
        #expect(helper.count(.applyArtifact) == 4 && model.route == place)
        model.close()
    }

    @Test func theAppliedReplySaysWhatTheDeviceDid() throws {
        let saved = try JSONDecoder().decode(MultiplayerApplied.self, from: Data(#"{"saved":"/Users/ada/relay/notes.txt.9f8e7d6c"}"#.utf8))
        #expect(saved.savedName == "notes.txt.9f8e7d6c" && saved.applied == nil)
        #expect(saved.confirmation(artifact: "notes.txt", patch: false, folder: "relay") == "Saved notes.txt into relay as notes.txt.9f8e7d6c.")
        // An older device that answers with nothing: the artifact's kind decides.
        #expect(MultiplayerApplied().confirmation(artifact: "a.patch", patch: true, folder: "relay").hasPrefix("Applied a.patch to relay."))
        #expect(MultiplayerApplied().confirmation(artifact: "a.txt", patch: false, folder: "relay") == "Saved a.txt into relay.")
    }

    // 2 and 7. The zoom's footer and its suggestions are the caller's.
    @Test func theZoomTakesItsFooterTitleAndASuggestionFromItsCaller() async throws {
        let (model, _) = MultiplayerLiveFixture.model([:])
        model.open()
        await model.settle()
        let entry = try #require(model.share.entry("dir-1", on: Self.home))
        #expect(entry.canSuggest)
        let worker = MultiplayerRemoteWorker(server: Self.home, request: "rq-1", resource: "dir-1", canWatch: true, task: "Fix the test",
                                             agent: "bo-agent", friend: "fixture-bo", serverName: "home", harness: "codex",
                                             state: "Started", tone: .working, at: nil)
        func zoom(footer: String?, suggests: Bool, entry: MultiplayerDirectoryEntry?) -> some View {
            RemoteWorkerZoom(worker: worker, watch: MultiplayerWatchState(server: Self.home, resource: "dir-1"), entry: entry,
                             color: .pink, interval: 2, now: Date(), footerTitle: footer, allowsSuggestion: suggests,
                             suggestion: .constant("Pin the clock."), onSuggest: {}, onRetry: {}, onOpenTray: {})
                .frame(height: 560).environment(\.theme, .console)
        }
        // As before: read-only, with the button that opens the hand-off's window page.
        let plain = try await MultiplayerAX.nodes(of: RemoteWorkerZoom(worker: worker, watch: MultiplayerWatchState(), entry: entry,
                                                                        color: .pink, interval: 2, now: Date(), onRetry: {}, onOpenTray: {})
            .frame(height: 560).environment(\.theme, .console))
        #expect(plain.contains { $0.role == "AXButton" && $0.label == "Open hand-off" })
        #expect(!plain.contains { $0.label == "Send suggestion" || $0.label == "Suggestion" })

        let titled = try await MultiplayerAX.nodes(of: zoom(footer: "Show hand-off", suggests: false, entry: entry))
        #expect(titled.contains { $0.role == "AXButton" && $0.label == "Show hand-off" } && !titled.contains { $0.label == "Open hand-off" })

        let suggesting = try await MultiplayerAX.nodes(of: zoom(footer: nil, suggests: true, entry: entry))
        #expect(!suggesting.contains { $0.label == "Open hand-off" })
        #expect(suggesting.contains { $0.role == "AXButton" && $0.label == "Send suggestion" })
        #expect(suggesting.contains { $0.label == "Suggestion" })

        // Without Suggest shared on the worker, the field stays away whatever the caller allows.
        let unshared = try await MultiplayerAX.nodes(of: zoom(footer: nil, suggests: true, entry: model.share.entry("dir-2", on: Self.home)))
        #expect(!unshared.contains { $0.label == "Send suggestion" })
        model.close()
    }

    // 4. The countdown counts from the clock it is given.
    @Test func theCountdownCountsFromTheClockItIsGiven() async throws {
        let until = Date(timeIntervalSince1970: 1_780_000_000)
        let spoken = MultiplayerHandover.spoken(754)
        let given = try await MultiplayerAX.nodes(of: MultiplayerCountdown(until: until, span: 1800, now: until.addingTimeInterval(-754)))
        #expect(given.contains { $0.label == spoken || $0.value == spoken }, "\(given)")
        // A clock set for everything below: a fixture or a picture.
        let below = try await MultiplayerAX.nodes(of: MultiplayerCountdown(until: until, span: 1800)
            .environment(\.multiplayerFixedNow, until.addingTimeInterval(-754)))
        #expect(below.contains { $0.label == spoken || $0.value == spoken })
        // The clock given outranks the one below, and a clock past the end reads as ended.
        let ended = try await MultiplayerAX.nodes(of: MultiplayerCountdown(until: until, span: 1800, now: until.addingTimeInterval(60))
            .environment(\.multiplayerFixedNow, until.addingTimeInterval(-754)))
        let over = MultiplayerHandover.spoken(0)
        #expect(ended.contains { $0.label == over || $0.value == over })
    }

    // 5. With only the wall showing, the wall's rows are still read, and read again at its pace.
    @Test func theWallReadsHandOversAndSentWorkWithNoPanelOpen() async throws {
        let handovers = MultiplayerLiveFixture.ok(#"{"handovers":[{"user":"u-cy","resource":"res-9","until":"2099-01-01T00:00:00Z"}]}"#)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)], .status: [MultiplayerLiveFixture.status],
            .handovers: [handovers], .sent: [MultiplayerLiveFixture.ok(#"{"sent":[]}"#)],
            .handoffs: [MultiplayerLiveFixture.ok(#"{"handoffs":[]}"#)]])
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .milliseconds(60), fastPoll: .milliseconds(60))
        let share = model.share, live = model.share.live
        // No panel and no wall: nothing is read.
        live.refresh()
        #expect(live.quietTask == nil && !live.watchesWall && !share.watchesWall)

        share.wallAppeared()
        #expect(live.watchesWall && share.watchesWall)
        _ = await MultiplayerLiveFixture.eventually { helper.count(.handovers) >= 1 && helper.count(.sent) >= 1 && !live.handovers.isEmpty }
        #expect(live.handovers[Self.home]?.map(\.resource) == ["res-9"])
        #expect(helper.count(.handoffs) >= 1)
        // A panel's own reads stay with the panel.
        #expect(helper.count(.approvals) == 0)
        // It is read again while the wall shows, with no panel to poll for it.
        let first = helper.count(.handovers)
        _ = await MultiplayerLiveFixture.eventually { helper.count(.handovers) > first }
        #expect(helper.count(.handovers) > first)

        share.wallDisappeared()
        await model.settle()
        let last = helper.count(.handovers)
        try await Task.sleep(for: .milliseconds(250))
        #expect(helper.count(.handovers) == last && !live.watchesWall)
        live.refresh()
        #expect(live.quietTask == nil)
    }

    // 6. A worker's resource comes from the model.
    @Test func aWorkersResourceComesFromTheModel() async throws {
        let (model, _) = MultiplayerShareModelTests.model([.status: [MultiplayerShareFixture.statusWithWorker]])
        #expect(model.share.resource(forWorker: "w-7") == nil)
        model.open()
        await model.settle()
        let resource = try #require(model.share.resource(forWorker: "w-7"))
        #expect(resource.id == MultiplayerShareTarget.agent(id: "w-7", name: "tests").resourceID && resource.name == "tests")
        #expect(model.share.resource(forWorker: "w-7", on: Self.home) == resource)
        #expect(model.share.resource(forWorker: "w-7", on: "s-elsewhere") == nil)
        #expect(model.share.resource(forWorker: "w-8") == nil)
        model.close()
    }

    // 8. Removing a server by value leaves the tray's page and its confirm step alone.
    @Test func removingAServerByValueLeavesTheTrayWhereItIs() async throws {
        let both = MultiplayerServerFixture.servers(MultiplayerServerFixture.home, MultiplayerServerFixture.team)
        let helper = ScriptedMultiplayerHelper([
            .servers: [both, both, MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .status: [MultiplayerShareFixture.status], .serverRemove: [MultiplayerFixture.ok]])
        let model = MultiplayerServerFixture.model(helper)
        model.open()
        await model.settle()
        let home = try #require(model.server("s-home")), team = try #require(model.server("s-team"))
        // The tray is on another server's page, in the middle of its own confirm step.
        model.openServer("s-home")
        model.askRemove(home)
        let place = model.route

        let result = await model.remove(team)
        #expect(result == .done(id: "s-team", server: "s-team", message: "Removed team."))
        #expect(helper.lastInput(.serverRemove) == ["server": "s-team"])
        #expect(model.server("s-team") == nil && model.servers.map(\.id) == ["s-home"])
        #expect(model.route == place && model.confirmingRemoval == "s-home")

        // Removing it twice sends nothing.
        let again = await model.remove(team)
        #expect(again == .failed(id: "s-team", server: "s-team", reason: "Couldn’t remove the server. That server is no longer in your list."))
        #expect(helper.count(.serverRemove) == 1)
        model.close()
    }

    @Test func aTrayOnTheRemovedServersOwnPageGoesHome() async throws {
        let both = MultiplayerServerFixture.servers(MultiplayerServerFixture.home, MultiplayerServerFixture.team)
        let helper = ScriptedMultiplayerHelper([
            .servers: [both, both, MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .status: [MultiplayerShareFixture.status], .serverRemove: [MultiplayerFixture.ok]])
        let model = MultiplayerServerFixture.model(helper)
        model.open()
        await model.settle()
        let team = try #require(model.server("s-team"))
        model.openServer("s-team")
        #expect(await model.remove(team).isDone)
        // That page is gone with the server.
        #expect(model.route == .home)
        model.close()
    }
}

// MARK: - Defects from the window's check

/// An answered row's hold the test ends by hand, so nothing waits on the clock.
@MainActor final class MultiplayerManualHold {
    /// The durations the model asked to hold for, in order.
    private(set) var asked: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var ended = false

    nonisolated var timer: MultiplayerHoldTimer { MultiplayerHoldTimer { [self] in await self.wait($0) } }

    private func wait(_ duration: Duration) async {
        asked.append(duration)
        guard !ended else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Ends the hold of every row answered so far, and returns once each row's hold is over.
    func end(in model: MultiplayerModel) async {
        ended = true
        waiting.forEach { $0.resume() }
        waiting = []
        await model.share.settleHolds()
        ended = false
    }
}

@MainActor @Suite struct MultiplayerWindowCheckTests {
    static let pin = "sha256/nUnZnJ0SWPmE73KXxj+i59pMBxAJmysaaVUgzoL+cgg="

    static func review(_ presented: MultiplayerProbeState, pin: String = MultiplayerWindowCheckTests.pin) -> some View {
        let server = MultiplayerServerSummary(id: "s-team", url: "https://relay.team.example", name: "team-relay", pin: pin, state: .certChanged)
        return VStack(spacing: 0) {
            MultiplayerCertificateReview(server: server, presented: presented, confirmingTrust: true, confirmingRemoval: true,
                                         isBusy: false, onCheck: {}, onCancelTrust: {}, onConfirmTrust: {}, onCancelRemove: {},
                                         onConfirmRemove: {})
        }
        .environment(\.theme, .console)
    }

    /// The certificate inspector's tree: every text says something, and none sits inside another.
    @Test func theCertificateReviewOffersNoEmptyOrDoubledText() async throws {
        let probe = MultiplayerProbe(url: "https://relay.team.example",
                                     steps: [MultiplayerProbeStep(step: "tls", ok: true, pin: "sha256/9sJ3AAECAwQFBgcICQoLDA0ODxAREhMUFRYXxy4V")])
        let states: [(String, MultiplayerProbeState, String)] = [
            ("idle", .idle, Self.pin), ("running", .running(address: "x"), Self.pin),
            ("finished", .finished(probe, address: "x"), Self.pin),
            ("failed with no reason", .failed(address: "x", message: ""), Self.pin),
            ("failed", .failed(address: "x", message: "No route to the relay."), Self.pin),
            ("unreadable pin", .idle, "not-a-pin")]
        for (name, state, pin) in states {
            let nodes = try await MultiplayerAX.nodes(of: Self.review(state, pin: pin))
            let texts = nodes.filter { $0.role == "AXStaticText" }
            #expect(!texts.isEmpty)
            for text in texts {
                #expect(!(text.label.isEmpty && text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), "\(name): an empty text in \(nodes)")
            }
            // Selectable text is one element, not a text inside a text.
            for (index, node) in nodes.enumerated() where node.role == "AXStaticText" && index + 1 < nodes.count {
                #expect(!(nodes[index + 1].role == "AXStaticText" && nodes[index + 1].depth > node.depth), "\(name): a text inside a text in \(nodes)")
            }
            let fingerprints = texts.filter { ($0.label + $0.value).hasPrefix("Fingerprint ") }
            #expect(fingerprints.count == (name == "finished" ? 2 : name == "unreadable pin" ? 0 : 1), "\(name): \(nodes)")
            if name == "failed with no reason" {
                #expect(texts.contains { $0.value == "Commander couldn’t read the certificate." })
            }
        }
    }

    /// The live sequence: the window's answer, the tray's reads after it, a panel closing and
    /// opening, and the tray moving between pages. The row and its outcome stay for the hold.
    /// Nothing here depends on time: no poll fires during the test, every read is one the test
    /// asks for, and the hold ends when the test says so.
    @Test func anAnsweredRowIsHeldForTheLiveHoldThroughReadsAndNavigation() async throws {
        let none = MultiplayerFixture.output(#"{"ok":true,"data":{"approvals":[]}}"#)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)], .status: [MultiplayerShareFixture.status],
            .approvals: [MultiplayerShareFixture.approvals, none], .approve: [MultiplayerShareFixture.empty], .deny: [MultiplayerShareFixture.empty]])
        let hold = MultiplayerManualHold()
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     answeredHold: MultiplayerShareModel.answeredHold, holdTimer: hold.timer)
        model.open()
        await model.settle()
        // Approvals are read once the session is known to be signed in: on this read, or the next.
        if helper.count(.approvals) == 0 {
            model.refreshAll()
            await model.settle()
        }
        #expect(helper.count(.approvals) == 1)
        let pending = try #require(model.share.pendingApprovals.first)
        let server = pending.server
        func listed() -> Bool { model.share.approvals[server]?.contains { $0.id == pending.item.id } == true }
        func held() -> Bool { listed() && model.share.answer(for: pending.item, on: server) == .approved }

        let result = await model.decide(pending.item, on: server, approve: true)
        #expect(result.isDone && held())
        // A read after the action no longer lists it.
        model.refreshAll()
        await model.settle()
        #expect(helper.count(.approvals) >= 2 && held())
        // What waits no longer counts it; what is listed still has it.
        #expect(model.share.waitingApprovals.isEmpty && model.share.pendingApprovals.map(\.item.id) == [pending.item.id])
        #expect(model.tally.needsYou == 1)

        // The last panel closes and one opens; the tray moves through its pages; everything is read again.
        model.close()
        #expect(held())
        model.open()
        model.openServer(server)
        model.share.open(.requests, on: server)
        model.share.open(.approval(pending.item.id), on: server)
        model.share.back()
        model.go(.home)
        model.refreshAll()
        await model.settle()
        #expect(held())
        // It stays through more reads, for as long as the hold lasts.
        for _ in 0..<3 {
            model.refreshAll()
            await model.settle()
            #expect(held())
        }

        // The hold ends. The row leaves, with its outcome.
        await hold.end(in: model)
        // The hold asked for was the live one.
        #expect(hold.asked == [MultiplayerShareModel.answeredHold])
        #expect(!listed() && model.share.answer(for: pending.item, on: server) == nil && model.share.pendingApprovals.isEmpty)
        model.close()
    }

    /// Request 9: the relay keeps listing a denied approval. Its answer outlasts the hold, for as
    /// long as the relay lists the request, and goes when the relay stops.
    @Test func anAnswerOutlastsTheHoldWhileTheRelayStillListsTheRequest() async throws {
        let none = MultiplayerFixture.output(#"{"ok":true,"data":{"approvals":[]}}"#)
        let listing = MultiplayerShareFixture.approvals
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)], .status: [MultiplayerShareFixture.status],
            .approvals: [listing, listing, listing, listing, none], .approve: [MultiplayerShareFixture.empty], .deny: [MultiplayerShareFixture.empty]])
        let hold = MultiplayerManualHold()
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     answeredHold: MultiplayerShareModel.answeredHold, holdTimer: hold.timer)
        func read() async {
            model.refreshAll()
            await model.settle()
        }
        model.open()
        await model.settle()
        if helper.count(.approvals) == 0 { await read() }
        #expect(helper.count(.approvals) == 1)
        let pending = try #require(model.share.pendingApprovals.first)
        let server = pending.server
        func listed() -> Bool { model.share.approvals[server]?.contains { $0.id == pending.item.id } == true }
        func answer() -> MultiplayerAnswer? { model.share.answer(for: pending.item, on: server) }

        #expect(await model.decide(pending.item, on: server, approve: false).isDone)
        #expect(listed() && answer() == .denied)
        // The tray reads again after every action. The relay still lists it, during the hold and after.
        await model.settle()
        #expect(helper.count(.approvals) == 2 && listed() && answer() == .denied)
        await hold.end(in: model)
        #expect(listed() && answer() == .denied)
        #expect(model.share.waitingApprovals.isEmpty && model.share.pendingApprovals.map(\.item.id) == [pending.item.id])
        await read()
        await read()
        #expect(helper.count(.approvals) == 4 && listed() && answer() == .denied)
        // An answered row can't be answered again.
        #expect(await model.decide(pending.item, on: server, approve: true).reason == "Couldn’t approve the request. It was already denied.")
        #expect(helper.count(.approve) == 0 && helper.count(.deny) == 1)
        // The relay stops listing it. The row and its answer go.
        await read()
        #expect(helper.count(.approvals) == 5 && !listed() && answer() == nil && model.share.pendingApprovals.isEmpty)
        model.close()
    }

    /// The hold ends before any read succeeds. The row leaves; if the relay then lists the request
    /// again, it comes back answered, not waiting.
    @Test func aRequestTheRelayListsAgainAfterTheHoldComesBackAnswered() async throws {
        let none = MultiplayerFixture.output(#"{"ok":true,"data":{"approvals":[]}}"#)
        let unreachable = MultiplayerFixture.output(#"{"ok":false,"error":"the relay did not answer"}"#)
        let listing = MultiplayerShareFixture.approvals
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)], .status: [MultiplayerShareFixture.status],
            .approvals: [listing, unreachable, listing, none, listing], .approve: [MultiplayerShareFixture.empty],
            .deny: [MultiplayerShareFixture.empty]])
        let hold = MultiplayerManualHold()
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     answeredHold: MultiplayerShareModel.answeredHold, holdTimer: hold.timer)
        func read() async {
            model.refreshAll()
            await model.settle()
        }
        model.open()
        await model.settle()
        if helper.count(.approvals) == 0 { await read() }
        #expect(helper.count(.approvals) == 1)
        let pending = try #require(model.share.pendingApprovals.first)
        let server = pending.server
        func listed() -> Bool { model.share.approvals[server]?.contains { $0.id == pending.item.id } == true }
        func answer() -> MultiplayerAnswer? { model.share.answer(for: pending.item, on: server) }

        #expect(await model.decide(pending.item, on: server, approve: false).isDone)
        // The read after the action fails, so the relay hasn't said whether it still lists it.
        await model.settle()
        #expect(helper.count(.approvals) == 2 && listed() && answer() == .denied)
        await hold.end(in: model)
        #expect(!listed() && answer() == nil)
        await read()
        #expect(helper.count(.approvals) == 3 && listed() && answer() == .denied && model.share.waitingApprovals.isEmpty)
        // Once the relay has let it go, the answer is forgotten: the same ID listed later waits.
        await read()
        #expect(helper.count(.approvals) == 4 && !listed() && answer() == nil)
        await read()
        #expect(helper.count(.approvals) == 5 && listed() && answer() == nil && model.share.waitingApprovals.count == 1)
        model.close()
    }

    /// A model built with no hold drops the row at once, and still keeps the answer for a request
    /// the relay goes on listing.
    @Test func withNoHoldARequestTheRelayStillListsReadsAsAnswered() async throws {
        let none = MultiplayerFixture.output(#"{"ok":true,"data":{"approvals":[]}}"#)
        let listing = MultiplayerShareFixture.approvals
        let (model, helper) = MultiplayerAnsweredRowTests.model([.approvals: [listing, listing, none], .approve: [MultiplayerShareFixture.empty], .deny: [MultiplayerShareFixture.empty]],
                                                               hold: .zero)
        func read() async {
            model.refreshAll()
            await model.settle()
        }
        model.open()
        await model.settle()
        if helper.count(.approvals) == 0 { await read() }
        #expect(helper.count(.approvals) == 1)
        let pending = try #require(model.share.pendingApprovals.first)
        let server = pending.server
        func answer() -> MultiplayerAnswer? { model.share.answer(for: pending.item, on: server) }

        #expect(await model.decide(pending.item, on: server, approve: false).isDone)
        // The read after the action still lists it: answered, not waiting.
        await model.settle()
        #expect(helper.count(.approvals) == 2)
        #expect(model.share.pendingApprovals.count == 1 && answer() == .denied && model.share.waitingApprovals.isEmpty)
        await read()
        #expect(helper.count(.approvals) == 3 && model.share.pendingApprovals.isEmpty && answer() == nil)
        model.close()
    }

    /// The tray's own row: the outcome takes the verbs' place, and the heading stops counting it.
    @Test func theTraysAnsweredRowShowsItsOutcomeInPlaceOfItsVerbs() async throws {
        let (model, _) = MultiplayerShareModelTests.model([.approvals: [MultiplayerShareFixture.approvals]])
        model.open()
        await model.settle()
        let pending = model.share.pendingApprovals
        #expect(pending.count == 1)
        func band(_ answer: MultiplayerAnswer?) -> some View {
            MultiplayerNeedsYou(groups: [], approvals: pending, isBusy: false, onAccept: { _, _ in }, approvalAnswer: { _ in answer })
                .environment(\.theme, .console)
        }
        let waiting = try await MultiplayerAX.nodes(of: band(nil))
        #expect(waiting.contains { $0.role == "AXButton" && $0.label.hasPrefix("Approve: ") })
        #expect(waiting.contains { $0.role == "AXButton" && $0.label.hasPrefix("Deny: ") })

        let approved = try await MultiplayerAX.nodes(of: band(.approved))
        #expect(!approved.contains { $0.role == "AXButton" && ($0.label.hasPrefix("Approve: ") || $0.label.hasPrefix("Deny: ")) })
        #expect(approved.contains { ($0.label + $0.value).hasPrefix("Approved: ") }, "\(approved)")
        let denied = try await MultiplayerAX.nodes(of: band(.denied))
        #expect(denied.contains { ($0.label + $0.value).hasPrefix("Denied: ") })
        model.close()
    }
}
