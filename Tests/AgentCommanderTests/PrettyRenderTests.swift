import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of the Pretty conversation on its four surfaces, drawn from the approved
// mockup's own run (design/mockups/pretty-conversation.html). Skipped unless PRETTY_RENDER_DIR
// names a folder for the PNG files:
//
//     PRETTY_RENDER_DIR=/tmp/pretty swift test --filter PrettyRender
//
// Nothing here opens a window on screen, touches the running app or calls the service.

let prettyRenderDirectory = ProcessInfo.processInfo.environment["PRETTY_RENDER_DIR"]

@MainActor @Observable final class PrettyEntriesBox {
    var entries: [TranscriptEntry] = []
    init() {}
}

private struct PrettySwapHost: View {
    let box: PrettyEntriesBox
    let output: String
    var body: some View {
        ConsoleScrollback(consoleID: "c", entries: box.entries, rawOutput: output, density: .regular) { EmptyView() }
    }
}

@MainActor @Suite struct PrettyRenderTests {
    /// A conversation taller than its column opens at its latest content, as Console does, and
    /// new content keeps the end in view. A short one sits at the top of its column.
    @Test func aTallConversationOpensAtItsEndAndFollowsIt() async throws {
        _ = NSApplication.shared
        let box = PrettyEntriesBox()
        var wire = Wire()
        wire.user("Check each tool once and report.")
        wire.call("Read", detail: "/a/words.txt", result: "1\talpha")
        wire.say("Four of the five steps passed.\n\n| Tool | Result |\n|---|---|\n"
                 + (1...12).map { "| `commander_tool_\($0)` | Pass. It returned as soon as the worker reported, and nothing else changed. |" }.joined(separator: "\n")
                 + "\n\nNo files were changed and no network was used.")
        box.entries = wire.entries
        let size = CGSize(width: 432, height: 400)
        let host = NSHostingView(rootView: PrettySwapHost(box: box, output: "")
            .frame(width: size.width, height: size.height).environment(ConsoleModeStore()).environment(ToolDetailStore()))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func scroll(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scroll).first
        }
        func settle() async throws -> (visible: CGRect, height: CGFloat) {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
            let view = try #require(scroll(host))
            return (view.documentVisibleRect, try #require(view.documentView).frame.height)
        }
        func grow() {
            wire.user("And one more check.")
            wire.say(String(repeating: "The extra check passed and nothing else changed. ", count: 12))
            box.entries = wire.entries
        }
        // Short: the content fills the column from its top, with nothing to scroll.
        box.entries = Array(wire.entries.prefix(1))
        let short = try await settle()
        #expect(short.visible.minY == 0 && abs(short.height - size.height) <= 1)
        box.entries = wire.entries
        let opened = try await settle()
        #expect(opened.height > size.height + 40)
        #expect(abs(opened.visible.maxY - opened.height) <= 1)

        grow()
        let followed = try await settle()
        #expect(followed.height > opened.height + 40)
        #expect(abs(followed.visible.maxY - followed.height) <= 1)

        window.contentView = nil
    }

    @Test func onlyTheReadersOwnMoveDecidesWhetherTheEndIsFollowed() {
        let atEnd = PrettyScrollEnd(offset: 600, column: 400, content: 1000)
        // Scrolled up, then back to within reach of the end.
        #expect(PrettyScrollEnd(offset: 300, column: 400, content: 1000).follows(after: atEnd) == false)
        #expect(PrettyScrollEnd(offset: 580, column: 400, content: 1000).follows(after: atEnd) == true)
        // The content grew or the column was resized: the reader did not move.
        #expect(PrettyScrollEnd(offset: 600, column: 400, content: 1300).follows(after: atEnd) == nil)
        #expect(PrettyScrollEnd(offset: 700, column: 300, content: 1000).follows(after: atEnd) == nil)
        #expect(atEnd.follows(after: atEnd) == nil)
    }

    /// At launch the run list arrives first, without messages: Pretty shows the worker's
    /// unformatted output, scrolled to its end. The workspace feed then brings the conversation.
    /// A shorter conversation must be in view, not the empty space past its end.
    @Test func aConversationThatReplacesLongUnformattedOutputIsInView() async throws {
        _ = NSApplication.shared
        let modes = ConsoleModeStore()
        let box = PrettyEntriesBox()
        let output = (1...400).map { "line \($0) of the terminal output" }.joined(separator: "\n")
        let size = CGSize(width: 432, height: 400)
        let host = NSHostingView(rootView: PrettySwapHost(box: box, output: output)
            .frame(width: size.width, height: size.height).environment(modes).environment(ToolDetailStore()))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func scroll(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scroll).first
        }
        func settle() async throws {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        try await settle()
        let raw = try #require(scroll(host))
        let rawHeight = try #require(raw.documentView).frame.height
        #expect(rawHeight > size.height * 4)
        box.entries = Self.worker()
        try await settle()
        let conversation = try #require(scroll(host))
        let document = try #require(conversation.documentView).frame
        #expect(document.height < rawHeight)
        let visible = conversation.documentVisibleRect
        #expect(visible.minY <= max(0, document.height - visible.height) + 1)
        window.contentView = nil
    }

    static let denial = "Permission to use mcp__commander__commander_network_online has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to accomplish this goal, e.g. using head instead of cat. Let the user decide how to proceed."
    static let reader = "w-779b15a33e2ed37dbe74d7bab6d102bf"
    static let status = #"{"id":"r-30bb462ddf3db629d085eb0f3b948e90","project":"acsmoke","path":"/private/tmp/claude-501/acsmoke","task":"Read-only smoke test of Agent Commander tools.","client":"claude","coordinator_id":"w-da045371c3671b03b68accb481575127","status":"running","workers":[{"id":"w-da045371c3671b03b68accb481575127","role":"coordinator","name":"Coordinator","state":"working","host":"localhost"},{"id":"w-779b15a33e2ed37dbe74d7bab6d102bf","role":"worker","name":"reader","state":"working","host":"localhost","result":"words.txt has 3 lines: alpha, bravo, charlie."}],"requests":[]}"#
    static let report = "Smoke test summary (read-only; no files changed, no network used):\n\n- commander_status: PASS. Returned the run and coordinator; the wait_seconds 30 call returned when the worker reported.\n- commander_delegate: PASS. Started worker \"reader\" (client claude, host localhost).\n- reader worker result: PASS. words.txt has 3 lines: alpha, bravo, charlie.\n- commander_list_tools: PASS. No error; it returned an empty list, so no extensions are granted.\n- commander_network_online: FAIL (permission). Claude Code denied the call because it runs in don't-ask mode."

    /// The mockup's coordinator run (r-30bb462d), with one open call when `live`.
    static func coordinator(live: Bool = false) -> [TranscriptEntry] {
        var wire = Wire()
        wire.user("Read-only smoke test of Agent Commander tools. Do not create, edit, delete or commit any file, and use no network. 1) Call commander_status. 2) Call commander_delegate once to start a worker named reader. 5) Report a short pass/fail summary per tool with commander_result, then stop.")
        wire.messages.append(AGUIMessage(id: "orphan-1", role: "tool", content: status, toolCallID: "toolu_01EKn2"))
        wire.call("mcp__commander__commander_delegate", detail: "reader",
                  result: #"{"id":"\#(reader)","name":"reader","role":"worker","parent_id":"w-da045371c3671b03b68accb481575127","run_id":"r-30bb462ddf3db629d085eb0f3b948e90","state":"starting","host":"localhost","worktree":"/private/tmp/claude-501/acsmoke","branch":"main","client":"claude","created_at":"2026-11-27T00:30:33Z","task":"Read words.txt in the project root. Do not create, edit, delete or commit any file, and use no network. Report the line count and the words with commander_result.","output":""}"#)
        wire.messages.append(AGUIMessage(id: "orphan-2", role: "tool", content: status, toolCallID: "toolu_014Vy6"))
        wire.say("The worker reported. Now step 4.")
        wire.call("mcp__commander__commander_list_tools", result: #"{"tools":[]}"#)
        wire.call("mcp__commander__commander_network_online", result: denial, error: "Tool failed.")
        wire.call("mcp__commander__commander_result", detail: #"{"result":"\#(report.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\""))"}"#,
                  result: #"{"id":"w-da045371c3671b03b68accb481575127","result":"…"}"#)
        wire.say("Four of the five steps passed. `commander_network_online` failed because Claude Code is running in don't-ask mode and blocked the call, so the tool itself was never reached. No files were changed and no network was used.\n\nTo test `commander_network_online` properly, run it again with a permission mode that allows that tool.")
        if live {
            wire.user("Now check the retry budget.")
            wire.call("Read", detail: "/Users/sample/Developer/relay/retry/budget.ts", result: "1\texport const budget = 3\n2\t")
            wire.call("Bash", detail: "swift build", result: "Build complete!")
            wire.call("Bash", detail: "swift test --filter Retry")
        }
        return CommanderActivity.annotate(wire.entries, live: CommanderLiveState(workers: [reader: "completed"]))
    }

    /// The mockup's reader worker (w-779b15a3).
    static func worker() -> [TranscriptEntry] {
        var wire = Wire()
        wire.user("Read words.txt in the project root. Do not create, edit, delete or commit any file, and use no network. Report the line count and the words with commander_result.")
        wire.call("Read", detail: "/private/tmp/claude-501/acsmoke/words.txt", result: "1\talpha\n2\tbravo\n3\tcharlie\n4\t")
        wire.call("mcp__commander__commander_result", detail: #"{"result":"words.txt has 3 lines: alpha, bravo, charlie. The file ends with a newline, so the reader showed an empty 4th line. No files were created, edited, deleted or committed."}"#,
                  result: #"{"id":"w-779b15a33e2ed37dbe74d7bab6d102bf","result":"…"}"#)
        wire.say("`words.txt` has 3 lines: alpha, bravo and charlie. I sent this to the coordinator with `commander_result`. I didn't change any files or use the network.")
        return wire.entries
    }

    static let session = NativeSession(harnessInstance: "local-claude", sessionID: "5f0c2a91-77aa-4c1e-9a34-0d1b6f1c2e77")

    static func console(_ entries: [TranscriptEntry], state: TaskState = .completed, density: PrettyDensity,
                        coordinator: Bool = true, open: [String] = [], size: CGSize,
                        details: ToolDetailStore = ToolDetailStore()) -> some View {
        let modes = ConsoleModeStore()
        for id in open { modes.toggleTool(console: "c", entry: id) }
        return PrettyACPConsole(consoleID: "c", name: coordinator ? "Coordinator" : "reader", client: .claude, state: state,
                                entries: entries, session: session, density: density, isCoordinator: coordinator)
            .frame(width: size.width, height: size.height)
            .background(Palette.panel)
            .environment(modes)
            .environment(details)
    }

    /// The IDs to open so a render shows a group's lines and one typed result.
    static func openIDs(_ entries: [TranscriptEntry]) -> [String] {
        let items = ActivityConversation.items(ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty)))
        var ids: [String] = []
        for item in items {
            if case .group(let group) = item {
                ids.append(group.id)
                if let line = group.lines.first(where: { $0.sentence.plain.hasPrefix("Delegated") || $0.sentence.plain.hasPrefix("Read") }) {
                    ids.append(line.id)
                }
                ids += group.failures.map(\.id)
            }
        }
        return ids
    }

    /// A turn with every other part: a timed thought, a plan, a file, terminal output, a failure
    /// that is not a denial, an unknown tool with a secret-looking value, and a live thought.
    static func kitchen() throws -> (entries: [TranscriptEntry], details: ToolDetailStore) {
        func message(_ json: String) throws -> AGUIMessage { try JSONDecoder().decode(AGUIMessage.self, from: Data(json.utf8)) }
        func thought(_ id: String, _ messageID: String, _ text: String) throws -> AGUIMessage {
            try message(#"{"id":"\#(id)","role":"system","content":"\#(text)","metadata":{"acp":{"source":"live","kind":"agent_thought_chunk","messageId":"\#(messageID)","turnId":"t1"}}}"#)
        }
        var wire = Wire()
        wire.user("Cover timeout behavior before headers, after headers, and after the first body chunk.")
        wire.messages.append(try thought("th1", "m1", "The budget lives in retry/budget.ts. I should map the three phases first, then run the timeout suite and see which cases replay bytes."))
        let todo = wire.call("TodoWrite", detail: "other", result: "ok")
        let read = wire.call("Read", detail: "/Users/sample/Developer/relay/retry/budget.ts", result: "1\texport const budget = 3\n2\texport const idle = 30_000\n3\t")
        let bash = wire.call("Bash", detail: "swift test --filter Timeout", result: "Test Suite 'Timeout' started\n✔ beforeHeaders\n✔ afterHeaders\n✘ afterFirstChunk\nExecuted 3 tests, with 1 failure")
        wire.call("Bash", detail: "make lint", result: "", error: "Tool failed.\nexit status 2: lint found 3 problems. See the log.")
        let other = wire.call("mcp__jira__search", detail: #"{"jql":"project = RELAY","token":"sk-abcdefghijklmnopqrstuvwx"}"#,
                              result: #"{"total":2,"issues":[{"key":"RELAY-12","status":"open","summary":"Retry replays bytes"},{"key":"RELAY-19","status":"done","summary":"Idle timer"}],"next":null}"#)
        wire.say("Two of three phases pass. After the first body chunk a retry replays bytes the caller already consumed.")
        wire.messages.append(try thought("th2", "m2", "A retry after the first chunk cannot be transparent. The safest rule is to fail the request and let the caller decide. I need to check whether the budget counts that failure, and whether the idle timer restarts."))
        let summaries = try JSONDecoder().decode([ToolDetailSummary].self, from: Data("""
        [{"key":"m1","kind":"thought","started_at":"2026-11-27T01:59:10Z","ended_at":"2026-11-27T02:01:02Z"},
         {"key":"m2","kind":"thought","started_at":"2026-11-27T02:03:10Z","ended_at":"2026-11-27T02:03:10Z"},
         {"key":"\(bash)","kind":"tool","name":"Bash","fields":{"command":"swift test --filter Timeout","description":"Ran the timeout suite"}}]
        """.utf8))
        let records = try JSONDecoder().decode([ToolDetailRecord].self, from: Data("""
        [{"key":"\(todo)","kind":"tool","name":"TodoWrite","input":"{\\"todos\\":[{\\"content\\":\\"Map the three phases\\",\\"status\\":\\"completed\\"},{\\"content\\":\\"Run the timeout suite\\",\\"status\\":\\"in_progress\\",\\"activeForm\\":\\"Running the timeout suite\\"},{\\"content\\":\\"Report ambiguous cases\\",\\"status\\":\\"pending\\"}]}"}]
        """.utf8))
        _ = (read, other)
        return (wire.entries, ToolDetailStore(summaries: ["c": summaries], records: ["c": records],
                                              settings: TranscriptSettings(hideSecrets: true)))
    }

    static func kitchenOpenIDs(_ entries: [TranscriptEntry], _ details: ToolDetailStore) -> [String] {
        let facts = ActivityFacts(summaries: details.summaries(worker: "c"))
        let items = ActivityConversation.items(ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty)), facts: facts)
        var ids: [String] = []
        for item in items {
            if case .group(let group) = item { ids += [group.id] + group.lines.map(\.id) + group.failures.map(\.id) }
        }
        return ids
    }

    static func chrome(_ view: some View, size: CGSize) -> some View {
        view.frame(width: size.width, height: size.height, alignment: .top).background(Palette.window)
    }

    @Test func theKitchenTurnReadsItsStoredFacts() throws {
        let kitchen = try Self.kitchen()
        var facts = ActivityFacts(summaries: kitchen.details.summaries(worker: "c"))
        facts.record = { kitchen.details.record(worker: "c", key: $0) }
        let items = ActivityConversation.items(
            ConversationActivity.items(TranscriptEntry.displayed(kitchen.entries, mode: .pretty)), facts: facts)
        let groups = items.compactMap { if case .group(let group) = $0 { group } else { nil } }
        #expect(groups.first?.lines.first?.sentence.plain == "Thought for 1m 52s")
        #expect(items.contains { if case .plan(let plan) = $0 { plan.items?.count == 3 } else { false } })
        let work = try #require(groups.first { $0.lines.contains { $0.sentence.plain == "Ran the timeout suite" } })
        #expect(work.failures.first?.failure?.reason == "exit status 2: lint found 3 problems.")
        // The failed call ends its group; the next finished call starts another.
        #expect(work.summary.text == "Read a file, ran a command" && work.summary.failed == ["1 failed"])
        #expect(groups.contains { $0.isSingle && $0.lines[0].sentence.plain == "Used search" })
        // The conversation ends with a thought: while the turn runs it is the live line.
        #expect(ActivityConversation.liveThought(in: items)?.text.hasPrefix("A retry after") == true)
        #expect(ActivityConversation.withoutLiveThought(items).count == items.count - 1)
    }

    @Test func theStatusLineCountsBlockedCallsApartFromFailedOnes() {
        let status = PrettyRunStatus(state: .completed, entries: Self.coordinator())
        #expect(status.sentence == "1 prompt, 4 tool calls, 1 blocked")
        var wire = Wire()
        wire.user("Go")
        wire.call("Bash", detail: "make", result: "", error: "Tool failed.\nexit status 2")
        wire.call("Bash", detail: "ls", result: "", error: "Tool declined.")
        #expect(PrettyRunStatus(state: .idle, entries: wire.entries).sentence == "1 prompt, 2 tool calls, 1 blocked, 1 failed")
    }

    @Test func aSpinnerNeedsAnActiveWorkerAndNothingIsInferredForATrackedOne() {
        #expect(PrettyLive(state: .working, workerName: "reader") == PrettyLive(isActive: true, trailing: .responding("reader")))
        #expect(PrettyLive(state: .working, workerName: "reader", reportsProgress: true, reportedPhase: .toolRunning).trailing == nil)
        #expect(PrettyLive(state: .working, workerName: "reader", reportsProgress: true, reportedPhase: .thinking).trailing == .thinking)
        #expect(PrettyLive(state: .completed, workerName: "reader") == PrettyLive())
        #expect(PrettyLive(state: .disconnected, workerName: "reader").isDisconnected)
    }

    @Test func theTranscriptSettingKeepsEverythingByDefaultAndStoresItsChoices() async {
        final class Box: @unchecked Sendable { var saved: [TranscriptSettings] = [] }
        let box = Box()
        let store = ToolDetailStore(source: ToolDetailSource(
            page: { _, _ in ToolDetailPage(revision: 0, records: []) },
            record: { _, key in ToolDetailRecord(key: key, kind: "tool", input: "{}") },
            readSettings: { TranscriptSettings() },
            writeSettings: { next in
                if next.limitBytes == 1 { throw ServiceError.rejected("limit_bytes must be 0 or between 1024 and 524288") }
                box.saved.append(next)
                return next
            }))
        #expect(store.settings.keepsEverything && !store.settingsLoaded)
        await store.loadSettings()
        #expect(store.settingsLoaded)
        await store.save(TranscriptSettings(hideSecrets: true, limitBytes: TranscriptSettings.offeredLimit))
        #expect(store.settings.hideSecrets && store.settings.limitBytes == 16384 && box.saved.count == 1)
        // A refused change leaves the shown value as the service holds it, and says why.
        await store.save(TranscriptSettings(limitBytes: 1))
        #expect(store.settings.limitBytes == 16384 && store.settingsError?.contains("limit_bytes") == true)
        #expect(TranscriptSettingsSection.warning.contains("including the PiP"))
    }

    @Test func detailsAreReadAfterTheLastRevisionAndAFullRecordOnlyOnRequest() async {
        final class Box: @unchecked Sendable { var afters: [UInt64] = []; var keys: [String] = [] }
        let box = Box()
        let store = ToolDetailStore(source: ToolDetailSource(
            page: { _, after in
                box.afters.append(after)
                return after == 0 ? ToolDetailPage(revision: 4, records: [ToolDetailSummary(key: "t1", kind: "tool", name: "Read")])
                                  : ToolDetailPage(revision: 4, records: [])
            },
            record: { _, key in
                box.keys.append(key)
                if key == "gone" { throw ServiceError.rejected("tool detail not found") }
                return ToolDetailRecord(key: key, kind: "tool", input: "{}", result: "ok")
            },
            readSettings: { TranscriptSettings() }, writeSettings: { $0 }))
        await store.refresh(worker: "w")
        await store.refresh(worker: "w")
        #expect(box.afters == [0, 4] && store.summary(worker: "w", key: "t1")?.name == "Read")
        #expect(box.keys.isEmpty && store.record(worker: "w", key: "t1") == nil)
        await store.open(worker: "w", key: "t1")
        await store.open(worker: "w", key: "t1")
        await store.open(worker: "w", key: "gone")
        await store.open(worker: "w", key: "gone")
        #expect(box.keys == ["t1", "gone"] && store.record(worker: "w", key: "t1")?.result == "ok")
        #expect(ServiceClient.toolDetailsPath("w-1", after: 7) == "/v1/workers/w-1/tool-details?after=7")
        #expect(ServiceClient.toolDetailPath("w-1", key: "event-3 a&b") == "/v1/workers/w-1/tool-details?key=event-3%20a%26b")
    }

    @Test func theMockupRunReadsAsTheApprovedSentences() {
        let items = ActivityConversation.items(
            ConversationActivity.items(TranscriptEntry.displayed(Self.coordinator(), mode: .pretty)), reportsAsCoordinator: true)
        let groups = items.compactMap { if case .group(let group) = $0 { group } else { nil } }
        #expect(groups.count == 2)
        #expect(groups[0].summary.text == "Got 2 results with no recorded call, delegated to reader")
        #expect(groups[0].lines[1].tag == ActivityTag(word: "completed", tone: .ok))
        #expect(groups[1].summary.text == "Listed extensions" && groups[1].summary.failed == ["1 blocked"])
        #expect(items.contains { if case .report(let report) = $0 { report.closingMessageFollows } else { false } })
    }

    @Test(.enabled(if: prettyRenderDirectory != nil)) func drawsTheFourSurfaces() async throws {
        let folder = URL(fileURLWithPath: try #require(prettyRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let coordinator = Self.coordinator(), worker = Self.worker(), live = Self.coordinator(live: true)
        let regular = CGSize(width: 800, height: 900), tile = CGSize(width: 440, height: 520), pip = CGSize(width: 350, height: 430)
        func write(_ view: some View, _ name: String, _ size: CGSize) async throws {
            try await ShellRenderTests.write(view, name, theme: .console, to: folder, size: size)
        }
        try await write(Self.console(coordinator, density: .regular, size: regular), "pretty-coordinator-closed", regular)
        try await write(Self.console(coordinator, density: .regular, open: Self.openIDs(coordinator),
                                     size: CGSize(width: 800, height: 1500)),
                        "pretty-coordinator-open", CGSize(width: 800, height: 1500))
        try await write(Self.console(worker, density: .regular, coordinator: false, open: Self.openIDs(worker), size: regular),
                        "pretty-focused-worker", regular)
        try await write(Self.console(live, state: .working, density: .regular, size: regular), "pretty-coordinator-live", regular)
        try await write(Self.console(live, state: .working, density: .compact, size: tile), "pretty-wall-tile", tile)
        try await write(Self.console(coordinator, density: .compact, open: Self.openIDs(coordinator), size: CGSize(width: 440, height: 900)),
                        "pretty-wall-tile-open", CGSize(width: 440, height: 900))
        try await write(Self.console(live, state: .working, density: .pip, size: pip), "pretty-pip", pip)
        let kitchen = try Self.kitchen()
        let tall = CGSize(width: 800, height: 1700)
        try await write(Self.console(kitchen.entries, state: .working, density: .regular, coordinator: false,
                                     open: Self.kitchenOpenIDs(kitchen.entries, kitchen.details) + ["th2"], size: tall,
                                     details: kitchen.details), "pretty-parts-open", tall)
        try await write(Self.console(kitchen.entries, state: .working, density: .compact, coordinator: false, size: tile,
                                     details: kitchen.details), "pretty-wall-tile-thinking", tile)
        // The frame: the message box while a turn runs and idle, and Settings › Transcript.
        let box = CGSize(width: 800, height: 230)
        try await write(Self.chrome(PrettyComposer(workerName: "reader", isWorking: true,
                                                   queued: [QueuedFollowUp(id: "m-1", text: "Also check the idle timer after a retry.")],
                                                   send: { _ in true }, removeQueued: { _ in }, stop: {}), size: box),
                        "pretty-message-box-working", box)
        try await write(Self.chrome(PrettyComposer(workerName: "reader", isWorking: false, send: { _ in true }), size: box),
                        "pretty-message-box-idle", box)
        let settings = CGSize(width: 560, height: 470)
        try await write(Self.chrome(TranscriptSettingsSection(settings: TranscriptSettings(hideSecrets: true)) { _ in }
                            .padding(Space.xl), size: settings), "settings-transcript", settings)
        // The live cockpit pages, when the preview conversation is asked for.
        if ConversationFixture.display == .pretty {
            for (scenario, name) in [(DesignPreviewScenario.coordinatorWall, "cockpit-wall"), (.focusedWorker, "cockpit-focused-worker"),
                                     (.attentionPip, "cockpit-pip")] {
                let modes = ConsoleModeStore()
                modes.applyGlobal(.pretty)
                try await ShellRenderTests.write(DesignPreviewPage(scenario: scenario).environment(modes), name,
                                                 theme: .blackGlass, to: folder)
            }
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pretty-pip-console.png").path))
    }
}
