import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Increment 3 demo defects D8, D10 and D11: hand-offs on the cockpit wall, the tray's
// accessibility tree, and Markdown in a hand-off's report.

/// One element of a hosted view's accessibility tree.
struct MultiplayerAXNode: CustomStringConvertible {
    let role: String
    let subrole: String
    let label: String
    let value: String
    let selected: Bool
    let depth: Int
    var object: NSObject? = nil

    var description: String {
        "\(String(repeating: "  ", count: depth))\(role)\(subrole.isEmpty ? "" : "/\(subrole)") “\(label)”\(value.isEmpty ? "" : " = \(value)")\(selected ? " [selected]" : "")"
    }
}

@MainActor enum MultiplayerAX {
    /// Every element under a view, depth first, as assistive apps are given them.
    static func tree(_ root: Any, depth: Int = 0, into nodes: inout [MultiplayerAXNode]) {
        guard depth < 60, let element = root as? NSAccessibilityElementProtocol & NSObject else { return }
        let object = element as NSObject
        func text(_ selector: String) -> String {
            let sel = NSSelectorFromString(selector)
            guard object.responds(to: sel), let value = object.perform(sel)?.takeUnretainedValue() else { return "" }
            if let string = value as? String { return string }
            if let role = value as? NSAccessibility.Role { return role.rawValue }
            if let number = value as? NSNumber { return number.stringValue }
            return ""
        }
        let selected = (object.value(forKey: "accessibilitySelected") as? Bool) ?? false
        nodes.append(MultiplayerAXNode(role: text("accessibilityRole"), subrole: text("accessibilitySubrole"),
                                       label: [text("accessibilityLabel"), text("accessibilityTitle")].first { !$0.isEmpty } ?? "", value: text("accessibilityValue"),
                                       selected: selected, depth: depth, object: object))
        let sel = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: sel), let children = object.perform(sel)?.takeUnretainedValue() as? [Any] else { return }
        for child in children { tree(child, depth: depth + 1, into: &nodes) }
    }

    static func nodes(of view: some View, width: CGFloat = MultiplayerLayout.width,
                      after: (@MainActor ([MultiplayerAXNode]) -> Void)? = nil) async throws -> [MultiplayerAXNode] {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            try await Task.sleep(for: .milliseconds(80))
        }
        var nodes: [MultiplayerAXNode] = []
        // SwiftUI builds its accessibility tree when an assistive client first asks.
        (NSApp as NSObject).perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: true as NSNumber, with: "AXEnhancedUserInterface" as NSString)
        _ = host.accessibilityChildren()
        _ = window.accessibilityChildren()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        tree(host, into: &nodes)
        after?(nodes)
        window.contentView = nil
        return nodes
    }
}

@MainActor @Suite struct MultiplayerFixesTests {
    static func fixtureModel(_ name: String) async throws -> (MultiplayerModel, UserDefaults, String) {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("multiplayer-fixes-\(name)-\(UUID().uuidString).json")
        setenv("COMMANDER_NETWORK_FIXTURE_STATE", state.path, 1)
        // Kept for its callers. Nothing is written to preferences: the model's winners go to a scratch file.
        let suite = "multiplayer-fixes-\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = MultiplayerModel(client: MultiplayerClient(helper: MultiplayerProcessHelper(executable: MultiplayerRenderTests.fixture)),
                                     usesFixtureHelper: true, steadyPoll: .seconds(3600), fastPoll: .seconds(3600))
        model.open()
        await model.settle()
        model.refresh()
        await model.settle()
        return (model, defaults, suite)
    }

    static let home = "s-fixture-home"

    // MARK: D11

    @Test func readsMarkdownBlocks() {
        let blocks = MultiplayerMarkdownParser.blocks("""
        ## sam-agent

        The test **raced** the lease renewal.
        It now waits for `lease.renewed`.

        - Added a wait
          on the renewal event
        - Removed the sleep
          - nested note

        1. Run the suite
        2) Take the patch

        ```swift
        ## not a heading
        await renewal()
        ```
        ---
        #hashtag stays text
        """)
        #expect(blocks == [
            .heading(level: 2, text: "sam-agent"),
            .paragraph("The test **raced** the lease renewal. It now waits for `lease.renewed`."),
            .list(ordered: false, items: [
                MultiplayerMarkdownItem(text: "Added a wait on the renewal event"),
                MultiplayerMarkdownItem(text: "Removed the sleep"),
                MultiplayerMarkdownItem(text: "nested note", depth: 1),
            ]),
            .list(ordered: true, items: [
                MultiplayerMarkdownItem(marker: "1.", text: "Run the suite"),
                MultiplayerMarkdownItem(marker: "2.", text: "Take the patch"),
            ]),
            .code("## not a heading\nawait renewal()"),
            .rule,
            .paragraph("#hashtag stays text"),
        ])
        #expect(String(MultiplayerMarkdownParser.inline("The test **raced** `x`").characters) == "The test raced x")
        #expect(MultiplayerMarkdownParser.spoken(blocks).hasPrefix("sam-agent. The test raced the lease renewal."))
        // An unclosed fence still shows its code, and plain text is one paragraph.
        #expect(MultiplayerMarkdownParser.blocks("```\nopen") == [.code("open")])
        #expect(MultiplayerMarkdownParser.blocks("Just a line.") == [.paragraph("Just a line.")])
        #expect(MultiplayerMarkdownParser.blocks("").isEmpty)
    }

    // MARK: D8

    @Test func listsHandoffsAsRemoteWorkers() async throws {
        let (model, defaults, suite) = try await Self.fixtureModel("wall")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        let workers = model.share.remoteWorkers
        #expect(workers.count == model.share.allHandoffs.count && !workers.isEmpty)
        let fix = try #require(workers.first { $0.request == "rq-handoff-1" })
        #expect(fix.task == "Fix flaky reconnect test")
        #expect(fix.agent == "sam-agent" && fix.friend == "fixture-sam")
        #expect(fix.serverName == model.server(Self.home)?.displayName)
        #expect(fix.client == .codex)
        #expect(fix.origin == "fixture-sam on \(fix.serverName)")
        #expect(fix.spoken.contains("fixture-sam’s agent") && fix.spoken.contains(fix.serverName) && fix.spoken.contains(fix.state))
        // Newest first among the runs still going.
        let dates = workers.compactMap(\.at)
        #expect(dates == dates.sorted(by: >) || workers.count != dates.count)
        // Opening one opens its hand-off in the main window; the tray stays where it was.
        var sent: [CommanderOpenRequest] = []
        let opener = MultiplayerWindowOpener(open: { sent.append($0) })
        MultiplayerRemoteWorkerLauncher.open(fix, with: opener)
        MultiplayerRemoteWorkerLauncher.openList(on: Self.home, with: opener)
        #expect(sent == [CommanderOpenRequest(place: NetworkPlace.handoffs, server: Self.home, item: .handoff(request: "rq-handoff-1")),
                         CommanderOpenRequest(place: NetworkPlace.handoffs, server: Self.home)])
        #expect(model.route == .home)
    }

    @Test func readsHandoffsForTheWallWithNoPanelOpen() async throws {
        let (model, defaults, suite) = try await Self.fixtureModel("wall-closed")
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = model.share.allHandoffs.count
        model.close()
        // No panel and no wall: nothing is read.
        model.share.refresh()
        #expect(model.share.quietTask == nil)
        model.share.wallAppeared()
        #expect(model.share.quietTask != nil)
        await model.share.quietTask?.value
        #expect(model.share.allHandoffs.count == expected)
        model.share.wallDisappeared()
        model.share.refresh()
        #expect(model.share.quietTask == nil)
    }

    // MARK: D10

    @Test func exposesTheTrayToAssistiveApps() async throws {
        let (model, defaults, suite) = try await Self.fixtureModel("ax")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        let share = model.share
        let pages: [(String, () -> Void)] = [
            ("agents", {}),
            ("people", { model.tab = .people }),
            ("grant", { model.tab = .agents; share.startGrant(on: Self.home, handle: "fixture-sam", resourceID: "res-2") }),
            // A page that moved to the main window is its open-in-window row alone.
            ("directory", { share.open(.directory, on: Self.home) }),
        ]
        for (name, open) in pages {
            model.go(.home)
            open()
            await model.settle()
            let nodes = try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model))
            let dump = nodes.map(\.description).joined(separator: "\n")
            // Nothing is offered without a role, and no button without a name.
            #expect(!nodes.contains { $0.role == "AXUnknown" }, "\(name)\n\(dump)")
            #expect(!nodes.contains { $0.role == "AXButton" && $0.label.isEmpty }, "\(name)\n\(dump)")
            // The page's scroll bar and its four unnamed parts are not in the tree.
            #expect(!nodes.contains { $0.role == "AXScrollBar" && $0.depth == 2 }, "\(name)\n\(dump)")
            switch name {
            case "agents":
                let group = try #require(nodes.firstIndex { $0.role == "AXTabGroup" && $0.label == "Sections" })
                let tabs = nodes[(group + 1)...].prefix { $0.depth > nodes[group].depth }
                #expect(tabs.count == 3)
                #expect(tabs.filter(\.selected).map(\.label).first?.hasPrefix("Agents") == true)
                #expect(tabs.filter { $0.value == "Selected" }.count == 1)
                // The presence menu is one element with its value.
                #expect(nodes.filter { $0.label == "Your presence" }.count == 1)
                #expect(nodes.first { $0.label == "Your presence" }?.value.isEmpty == false)
            case "grant":
                for picker in ["Resource", "Friend"] {
                    let found = nodes.filter { $0.label == picker }
                    #expect(found.count == 1 && found.first?.value.isEmpty == false, "\(picker)\n\(dump)")
                }
                // Each menu is one element. A combined menu's role is a menu button on macOS 26 and
                // a button on macOS 27, so the count is what shows its label is not offered again.
                let menus = nodes.filter { $0.role == "AXMenuButton" }
                #expect(menus.allSatisfy { ["Resource", "Friend"].contains($0.label) }, "\(dump)")
            case "directory":
                #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Open Directory in Agent Commander" }, "\(dump)")
                #expect(!nodes.contains { $0.label.contains("sam-agent") }, "\(dump)")
            default: break
            }
        }
        // The thread is a window page. Its view, as the window draws it, reads a comment as one text.
        share.open(.thread(request: "rq-handoff-1", title: "Fix flaky reconnect test"), on: Self.home)
        await model.settle()
        let thread = MultiplayerThreadPage(title: "Fix flaky reconnect test", state: share.thread, draft: .constant(""),
                                           now: model.currentDate(), onRetry: {})
        let nodes = try await MultiplayerAX.nodes(of: thread.environment(\.theme, .console))
        let comments = nodes.filter { $0.role == "AXStaticText" && ($0.label + $0.value).hasPrefix("sam-agent, agent, ") }
        #expect(comments.count == 1, "\(nodes.map(\.description).joined(separator: "\n"))")
    }

    // MARK: Pictures

    @Test(.enabled(if: multiplayerRenderDirectory != nil)) func drawsTheFixes() async throws {
        let folder = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (model, defaults, suite) = try await Self.fixtureModel("render")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        let share = model.share

        // The wall's remote workers, as the cockpit draws them under the local tiles.
        let wall = RemoteWorkerGroup(workers: share.remoteWorkers, now: model.currentDate(), onOpen: { _ in }, onOpenAll: {})
            .padding(17)
            .frame(width: 1100)
            .background(Palette.window)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: wall)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1100, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            try await Task.sleep(for: .milliseconds(120))
        }
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("wall-remote-workers.png"))
        window.contentView = nil
    }
}
