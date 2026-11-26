import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Remote (design/COMMANDER-NETWORK-INCREMENT-6.md), the cockpit's zoom view for a remote worker,
// and the increment 4 demo's frontend defects (design/demos/increment-4/demo.md: D4, D5, D7 to D10).
// Every name, address and code here is made up. No test reaches a network or the real helper.

@MainActor @Suite struct MultiplayerRemoteTests {
    static let home = "s-fixture-home"

    /// A model on the fixture with a state file of its own. The fixture reads its state path from
    /// the environment, which every test in the process shares, so each model here runs it through
    /// a launcher that names its own file. Tests that change state can then run side by side.
    static func fixtureModel(_ name: String) async throws -> MultiplayerModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("multiplayer-remote-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launcher = folder.appendingPathComponent("fixture")
        let script = "#!/bin/sh\nCOMMANDER_NETWORK_FIXTURE_STATE='\(folder.path)/state.json' exec '\(MultiplayerRenderTests.fixture.path)' \"$@\"\n"
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let model = MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: launcher)),
                                     usesFixtureHelper: true, steadyPoll: .seconds(3600), fastPoll: .seconds(3600))
        model.open()
        await model.settle()
        model.refresh()
        await model.settle()
        return model
    }

    // MARK: Contract

    @Test func tracksTheRemoteVerbs() {
        #expect(MultiplayerVerb.remoteEnable.arguments == ["tray", "remote-enable"])
        #expect(Set(["remote-enable", "remote-disable", "remote-devices", "remote-revoke"])
            .isSubset(of: Set(MultiplayerVerb.allCases.map(\.rawValue))))
    }

    @Test func readsAPairingAndTheDeviceList() throws {
        let now = MultiplayerFixtureClock.start
        let pairing = try #require(MultiplayerRemotePairing(try MultiplayerLiveFixture.json(
            #"{"url":"http://100.64.0.7:8780","code":"ABCD2345","expiresAt":"2026-11-23T12:10:00.123456Z","pairURL":"http://100.64.0.7:8780/pair?code=ABCD2345"}"#), now: now))
        #expect(pairing.spacedCode == "ABCD 2345" && pairing.spokenCode == "A B C D 2 3 4 5")
        #expect(pairing.isLive(now: now) && !pairing.isLive(now: now.addingTimeInterval(601)))
        // A reply with no link or expiry still pairs: both follow from the address and the code.
        let bare = try #require(MultiplayerRemotePairing(try MultiplayerLiveFixture.json(#"{"url":"http://h:1","code":"ZZZZ9999"}"#), now: now))
        #expect(bare.pairURL == "http://h:1/pair?code=ZZZZ9999" && bare.expiresAt == now.addingTimeInterval(600))
        #expect(MultiplayerRemotePairing(try MultiplayerLiveFixture.json(#"{"url":"http://h:1"}"#), now: now) == nil)

        let status = MultiplayerRemoteStatus(try MultiplayerLiveFixture.json(
            #"{"running":true,"url":"http://100.64.0.7:8780","devices":[{"id":"D1","name":"Phone","paired":"2026-11-20T08:00:00Z","expires":"2026-12-20T08:00:00Z"},{"id":"D1","name":"Twice"},{"name":"No id"}]}"#))
        #expect(status.running && status.url == "http://100.64.0.7:8780" && status.devices.map(\.id) == ["D1"])
        #expect(MultiplayerRemoteDeviceRow.dates(status.devices[0], now: now).hasPrefix("paired "))
        #expect(!MultiplayerRemoteStatus(try MultiplayerLiveFixture.json(#"{"devices":[]}"#)).running)
    }

    @Test func aQRCodeIsReadAsModules() throws {
        let modules = try #require(MultiplayerQRCode.modules(for: "http://100.64.0.7:8780/pair?code=ABCD2345"))
        // Square, and small enough to draw on whole points inside the band.
        #expect(modules.count >= 21 && modules.allSatisfy { $0.count == modules.count })
        // Every QR code starts with a finder pattern: a dark 7 by 7 ring around a dark 3 by 3 core.
        #expect(modules[0].prefix(7).allSatisfy { $0 } && !modules[1][1] && modules[3][3])
        #expect(!modules[7][0..<8].contains(true))
        let unit = MultiplayerQRCode.moduleSize(count: modules.count)
        #expect(unit == unit.rounded() && unit >= 2)
        #expect(unit * CGFloat(modules.count + 2 * MultiplayerQRCode.quietZone) <= MultiplayerQRCode.maxSide)
    }

    // MARK: Model

    @Test func remoteTurnsOnPairsRevokesAndTurnsOff() async throws {
        let model = try await Self.fixtureModel("remote")
        defer { model.close() }
        let remote = model.remote
        // It starts off, with the devices paired earlier.
        #expect(remote.status?.running == false && remote.devices.map(\.name) == ["Ryan’s iPhone", "iPad mini"])
        #expect(remote.livePairing == nil && !remote.pairingExpired)

        await remote.enable()?.value
        await model.settle()
        let first = try #require(remote.livePairing)
        #expect(remote.isRunning && remote.status?.url == "http://100.64.0.7:8780" && first.code.count == 8)
        #expect(first.pairURL == "http://100.64.0.7:8780/pair?code=\(first.code)" && model.failure == nil)
        // Asking again makes a new code and leaves the web view running.
        await remote.enable()?.value
        await model.settle()
        #expect(remote.isRunning && remote.livePairing?.code != first.code)

        // Revoke asks first; only the second click sends.
        remote.askRevoke("RD3XW9PT")
        #expect(remote.confirmingRevoke == "RD3XW9PT" && remote.devices.count == 2)
        remote.cancelRevoke()
        #expect(remote.confirmingRevoke == nil && remote.confirmRevoke() == nil)
        remote.askRevoke("RD3XW9PT")
        await remote.confirmRevoke()?.value
        await model.settle()
        #expect(remote.devices.map(\.id) == ["RD7K2MQA"] && remote.confirmingRevoke == nil)
        #expect(model.notice?.contains("iPad mini is signed out") == true)

        await remote.disable()?.value
        await model.settle()
        // Off keeps the pairings and drops the code.
        #expect(!remote.isRunning && remote.livePairing == nil && remote.devices.count == 1)
    }

    @Test func aNewDeviceEndsTheCodeThatPairedIt() async throws {
        let clock = MultiplayerFixtureClock()
        let enable = MultiplayerLiveFixture.ok(#"{"url":"http://100.64.0.7:8780","code":"ABCD2345","expiresAt":"2026-11-23T12:10:00Z","pairURL":"http://100.64.0.7:8780/pair?code=ABCD2345"}"#)
        let none = MultiplayerLiveFixture.ok(#"{"running":true,"url":"http://100.64.0.7:8780","devices":[]}"#)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)], .status: [MultiplayerLiveFixture.status],
            .remoteEnable: [enable], .remoteDevices: [MultiplayerLiveFixture.ok(#"{"running":false,"url":"","devices":[]}"#), none]])
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     now: { clock.now })
        model.open()
        await model.settle()
        let remote = model.remote
        await remote.enable()?.value
        await model.settle()
        // The device agent refuses fields it doesn't know: these verbs carry no server.
        #expect(helper.lastInput(.remoteEnable) == [:] && helper.lastInput(.remoteDevices) == [:])
        #expect(remote.livePairing?.code == "ABCD2345")
        remote.take(MultiplayerRemoteStatus(running: true, url: "http://100.64.0.7:8780",
                                            devices: [MultiplayerRemoteDevice(id: "N1", name: "Pixel")]))
        #expect(remote.livePairing == nil && !remote.pairingExpired && model.notice?.hasPrefix("Paired Pixel.") == true)
        model.close()
    }

    @Test func aCodeThatRanOutIsSaidToHaveExpired() async throws {
        let clock = MultiplayerFixtureClock()
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)], .status: [MultiplayerLiveFixture.status],
            .remoteEnable: [MultiplayerLiveFixture.ok(#"{"url":"http://h:1","code":"ABCD2345","expiresAt":"2026-11-23T12:10:00Z"}"#)],
            .remoteDevices: [MultiplayerLiveFixture.ok(#"{"running":true,"url":"http://h:1","devices":[]}"#)]])
        let model = MultiplayerModel(client: MultiplayerClient(helper: helper), steadyPoll: .seconds(3600), fastPoll: .seconds(3600),
                                     now: { clock.now })
        model.open()
        await model.settle()
        await model.remote.enable()?.value
        await model.settle()
        #expect(model.remote.livePairing != nil)
        clock.advance(3600)
        #expect(model.remote.livePairing == nil && model.remote.pairingExpired)
        model.close()
    }

    // MARK: Increment 4 defects

    /// D4: the fixture names the holder as the device agent does, and Take back works for them.
    @Test func theHolderIsNamedByHandleAndCanBeTakenBack() async throws {
        let model = try await Self.fixtureModel("holder")
        defer { model.close() }
        let live = model.share.live
        let held = try #require(live.activeHandovers.first)
        #expect(held.item.handle == "fixture-sam" && held.item.user == "u-sam" && held.item.server == Self.home)
        #expect(held.item.who == "fixture-sam")
        await live.takeBack(held.item, on: Self.home)?.value
        await model.settle()
        #expect(model.failure == nil && live.activeHandovers.isEmpty)
        #expect(model.notice?.contains("fixture-sam’s requests wait for your approval") == true)
    }

    /// The review composer's 96 KiB diff fits the request once it is escaped and wrapped.
    @Test func a96KiBDiffFitsAReviewRequest() throws {
        // Quotes, backslashes and newlines each double in JSON: the worst case for a diff.
        let line = "+  let path = \"C:\\\\temp\\\\x\"\t// \"quoted\"\n"
        let diff = String(repeating: line, count: MultiplayerContextBundle.byteLimit / line.utf8.count)
        var draft = MultiplayerReviewDraft(title: String(repeating: "t", count: 200), pr: "https://github.com/example/relay/pull/212",
                                           instructions: String(repeating: "i", count: 4000))
        draft.diff = MultiplayerContextItem(name: "change.diff", content: diff)
        #expect(draft.problem == nil && draft.canSend && diff.utf8.count > 95 * 1024)
        let fields: [String: MultiplayerPayloadValue] = ["server": "s-fixture-home", "resource": "dir-sam-agent",
                                                        "action": .string(MultiplayerSharePolicy.review),
                                                        "name": .string(draft.trimmedTitle), "payload": .json(draft.payload)]
        let body = try MultiplayerClient.encode(fields, limit: MultiplayerClient.inputLimit(for: .send))
        // Over the old 96 KiB bound, inside the device agent's 192 KiB.
        #expect(body.count > 96 * 1024 && body.count <= 196_608)
        #expect(MultiplayerClient.sendInputLimit == 196_608)
    }

    /// D9 (d): a worker waiting for input shows the open arc, not the outlined circle.
    @Test func aWorkerAwaitingInputShowsTheWaitingLamp() {
        var watch = MultiplayerWatchState(server: "s", resource: "r")
        watch.take(MultiplayerWatchReply(events: [MultiplayerWatchEvent(kind: .message, text: "Done.")], cursor: "1", state: "awaiting_input"),
                   at: MultiplayerFixtureClock.start)
        #expect(watch.lamp == .waiting && watch.stateTone == .attention && watch.isAwaiting)
        watch.take(MultiplayerWatchReply(state: "running"), at: MultiplayerFixtureClock.start)
        #expect(watch.lamp != .waiting && watch.total == 1 && watch.polls == 2)
    }

    /// D5: the cockpit's zoom reads a remote worker's output while it is shown, and stops after.
    @Test func theCockpitZoomReadsARemoteWorkersOutputReadOnly() async throws {
        let model = try await Self.fixtureModel("zoom")
        defer { model.close() }
        let worker = try #require(model.share.remoteWorkers.first { $0.request == "rq-handoff-1" })
        #expect(worker.resource == "dir-sam-agent" && worker.canWatch)
        let live = model.share.live
        live.beginZoomWatch(worker.resource, on: worker.server)
        #expect(await MultiplayerLiveFixture.eventually { live.zoomWatch.phase == .live && live.zoomWatch.total > 0 })
        #expect(live.zoomWatch.server == Self.home && live.zoomWatch.resource == "dir-sam-agent")
        // The tray's own watch page is a separate stream and was never opened.
        #expect(live.watch.total == 0 && model.route == .home)
        live.endZoomWatch()
        #expect(live.zoomTask == nil)
        // A worker with no Watch grant is never asked.
        live.beginZoomWatch("", on: Self.home)
        #expect(live.zoomTask == nil)
    }

    /// D10: live-work rows have roles, and each picker is offered once.
    @Test func exposesTheLiveWorkPagesToAssistiveApps() async throws {
        let model = try await Self.fixtureModel("ax-live")
        defer { model.close() }
        let live = model.share.live
        let pages: [(String, () -> Void)] = [
            ("agents", {}),
            ("control", { live.startControl("res-2", on: Self.home) }),
            ("watch", { live.startWatch("dir-sam-agent", on: Self.home) }),
            ("review", { live.openReview("rq-review-1", on: Self.home); live.askPost() }),
            ("network", { model.tab = .network }),
        ]
        for (name, open) in pages {
            model.go(.home)
            open()
            await model.settle()
            if name == "watch" { #expect(await MultiplayerLiveFixture.eventually { live.watch.total > 0 }) }
            let nodes = try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model))
            let dump = nodes.map(\.description).joined(separator: "\n")
            #expect(!nodes.contains { $0.role == "AXUnknown" }, "\(name)\n\(dump)")
            #expect(!nodes.contains { $0.role == "AXButton" && $0.label.isEmpty }, "\(name)\n\(dump)")
            switch name {
            case "agents":
                #expect(nodes.filter { $0.label == "Your presence" }.count == 1, "\(dump)")
                // The holder is spoken by handle, and the approval says which server it is on.
                #expect(nodes.contains { $0.label.hasPrefix("fixture-sam has control of ") }, "\(dump)")
                #expect(!nodes.contains { $0.label.contains("u-sam") }, "\(dump)")
                let server = try #require(model.server(Self.home)?.displayName)
                #expect(nodes.contains { $0.label.hasPrefix("Suggestion from fixture-sam") && $0.label.contains(" on \(server)") }, "\(dump)")
            case "control":
                let pickers = nodes.filter { $0.label == "Friend" }
                #expect(pickers.count == 1 && pickers.first?.value.isEmpty == false, "\(dump)")
                #expect(nodes.contains { $0.label == "Hand over control" }, "\(dump)")
            case "watch":
                let lines = nodes.filter { $0.role == "AXStaticText" && ($0.label + $0.value).contains("Message: ") }
                #expect(!lines.isEmpty, "\(dump)")
            case "review":
                let findings = nodes.filter { $0.role == "AXStaticText" && ($0.label + $0.value).hasPrefix("Important, ") }
                #expect(findings.count == 2, "\(dump)")
            case "network":
                #expect(nodes.contains { $0.label == "Remote" }, "\(dump)")
                #expect(nodes.contains { $0.label == "Revoke iPad mini" }, "\(dump)")
            default: break
            }
        }
    }

    // MARK: Pictures

    static func write(_ view: some View, size: CGSize, _ name: String, to folder: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            try await Task.sleep(for: .milliseconds(140))
        }
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }

    @Test(.enabled(if: multiplayerRenderDirectory != nil)) func drawsRemoteAndTheCockpitWatch() async throws {
        let folder = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = try await Self.fixtureModel("remote-render")
        defer { model.close() }
        let remote = model.remote, live = model.share.live

        model.tab = .network
        try await MultiplayerRenderTests.write(model, "remote-band-off", to: folder)
        await remote.enable()?.value
        await model.settle()
        try await MultiplayerRenderTests.write(model, "remote-band", to: folder)
        remote.askRevoke("RD3XW9PT")
        try await MultiplayerRenderTests.write(model, "remote-band-revoke", to: folder)
        remote.cancelRevoke()

        // The tray pages the increment 4 fixes changed.
        model.tab = .agents
        try await MultiplayerRenderTests.write(model, "fix-agents-holder-approval", to: folder)
        live.startControl("res-2", on: Self.home)
        await model.settle()
        try await MultiplayerRenderTests.write(model, "fix-control", to: folder)
        model.go(.home)
        live.startWatch("dir-sam-agent", on: Self.home)
        for _ in 0..<40 where live.watch.state != "awaiting_input" { try await Task.sleep(for: .milliseconds(250)) }
        try await MultiplayerRenderTests.write(model, "fix-watch-awaiting-input", to: folder)
        model.go(.home)

        // The cockpit's zoom view on a remote worker: the hand-off, then its output, read-only.
        let worker = try #require(model.share.remoteWorkers.first { $0.request == "rq-handoff-1" })
        live.beginZoomWatch(worker.resource, on: worker.server)
        _ = await MultiplayerLiveFixture.eventually { live.zoomWatch.total > 0 }
        let zoom = RemoteWorkerZoom(worker: worker, watch: live.zoomWatch, entry: model.share.entry(worker.resource, on: worker.server),
                                    color: MultiplayerTheme.swatch(for: worker.server), interval: 2, now: model.currentDate(),
                                    onRetry: {}, onOpenTray: {})
            .padding(17)
            .background(Palette.window)
        try await Self.write(zoom, size: CGSize(width: 900, height: 640), "cockpit-watch", to: folder)
        live.endZoomWatch()
        var unshared = worker
        unshared.canWatch = false
        let closed = RemoteWorkerZoom(worker: unshared, watch: MultiplayerWatchState(), entry: nil,
                                      color: MultiplayerTheme.swatch(for: worker.server), interval: 2, now: model.currentDate(),
                                      onRetry: {}, onOpenTray: {})
            .padding(17)
            .background(Palette.window)
        try await Self.write(closed, size: CGSize(width: 900, height: 300), "cockpit-watch-not-shared", to: folder)
    }
}
