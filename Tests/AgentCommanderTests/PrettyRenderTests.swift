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

@MainActor @Suite struct PrettyRenderTests {
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
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pretty-pip-console.png").path))
    }
}
