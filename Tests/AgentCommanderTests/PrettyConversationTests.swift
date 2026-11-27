import Foundation
import Testing
@testable import AgentCommander

// Pretty as a conversation: the wording of table A, the grouping rules of section B and the
// result shapes of section E in design/mockups/pretty-conversation.md, as pure values.

private func prettyItems(_ wire: Wire, awaiting: String? = nil, facts: ActivityFacts = .none,
                         coordinator: Bool = false, live: CommanderLiveState = CommanderLiveState()) -> [PrettyItem] {
    let entries = CommanderActivity.annotate(wire.entries, live: live)
    let items = ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty), awaitingToolID: awaiting)
    return ActivityConversation.items(items, awaitingToolID: awaiting, facts: facts, reportsAsCoordinator: coordinator)
}

private func groups(_ items: [PrettyItem]) -> [ActivityGroup] {
    items.compactMap { if case .group(let group) = $0 { group } else { nil } }
}

private func call(_ name: String, detail: String? = nil, result: String? = nil, error: String? = nil) -> CommanderCall {
    var wire = Wire()
    wire.call(name, detail: detail, result: result, error: error)
    return CommanderCall(entry: wire.entries[0])!
}

private let denial = "Permission to use mcp__commander__commander_network_online has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may* attempt to accomplish this action using other tools. Let the user decide how to proceed."

@Suite struct ActivitySentenceTests {
    /// Table A, Commander tools: running, the fallback without any value, failed, summary phrase.
    static let commanderTable: [(CommanderTool, String, String, String, String)] = [
        (.delegate, "Starting a worker", "Delegated to a new worker", "Couldn't start a worker", "delegated to a new worker"),
        (.ask, "Asking", "Asked a question", "Couldn't send the question", "asked a question"),
        (.wait, "Waiting for a reply", "Waited for a reply", "Couldn't wait for the reply", "waited for a reply"),
        (.reply, "Replying", "Replied to a question", "Couldn't send the reply", "replied to a question"),
        (.reconcileReply, "Checking whether the reply arrived", "Checked a reply's delivery", "Couldn't check the reply", "checked a reply"),
        (.result, "Reporting", "Reported a result", "Couldn't report the result", "reported a result"),
        (.commit, "Committing", "Committed changes", "Couldn't commit", "committed changes"),
        (.integrate, "Starting an integration", "Asked to integrate changes", "Couldn't start the integration", "started an integration"),
        (.send, "Sending a follow-up", "Sent a follow-up to a worker", "Couldn't send the follow-up", "sent a follow-up"),
        (.interrupt, "Interrupting", "Asked to interrupt a worker", "Couldn't interrupt a worker", "asked to interrupt a worker"),
        (.stopWorker, "Stopping", "Asked to stop a worker", "Couldn't stop a worker", "asked to stop a worker"),
        (.status, "Checking worker progress", "Checked worker progress", "Couldn't check the run", "checked progress"),
        (.listTools, "Listing extensions", "Listed extensions", "Couldn't list extensions", "listed extensions"),
        (.callTool, "Calling an extension", "Called an extension", "Extension failed", "called an extension"),
        (.networkInbox, "Reading the network inbox", "Read the network inbox", "Couldn't read the network inbox", "read the inbox"),
        (.networkDiscover, "Looking for shared resources", "Looked for shared resources", "Couldn't look for shared resources", "looked for shared resources"),
        (.networkSubmit, "Sending an operation", "Sent a network operation", "Couldn't send the operation", "sent an operation"),
        (.networkReceipt, "Checking the receipt", "Checked a receipt", "Couldn't read the receipt", "checked its receipt"),
        (.networkOnline, "Seeing who is online", "Checked who is online", "Couldn't see who is online", "checked who is online"),
        (.networkThread, "Reading a request thread", "Read a request thread", "Couldn't read the thread", "read a thread"),
        (.networkBoard, "Opening the task board", "Used the task board", "Couldn't use the task board", "used the task board"),
        (.frontendTools, "Listing app tools", "Listed app tools", "Couldn't list app tools", "listed app tools"),
        (.callFrontend, "Using an app tool", "Used an app tool", "App tool failed", "used an app tool"),
    ]

    @Test func everyCommanderToolHasItsTableWording() {
        #expect(Set(Self.commanderTable.map(\.0)) == Set(CommanderTool.allCases))
        for (tool, running, fallback, failed, phrase) in Self.commanderTable {
            let words = ActivityWords.commander(call(tool.rawValue))
            #expect(words.running.plain == running, "\(tool)")
            #expect(words.fallback.plain == fallback, "\(tool)")
            #expect(words.done.plain == fallback, "\(tool) without a value uses its fallback")
            #expect(words.failed.plain == failed, "\(tool)")
            #expect(words.phrase?.one == phrase, "\(tool)")
        }
    }

    /// Table A with the values a call or its result holds.
    @Test func commanderSentencesReadTheirValues() {
        let cases: [(String, String?, String?, String)] = [
            ("commander_delegate", "reader", #"{"id":"w-779b15a33e2ed37dbe74d7bab6d102bf","name":"reader","state":"starting"}"#,
             "Delegated to a new worker, reader"),
            ("commander_ask", #"{"question":"Which database?"}"#, nil, "Asking"),
            ("commander_list_tools", nil, #"{"tools":[]}"#, "Found no extensions granted"),
            ("commander_list_tools", nil, #"{"tools":[{"id":"a"},{"id":"b"}]}"#, "Found 2 extensions"),
            ("commander_network_online", nil, #"{"data":{"friends":[]},"ok":true}"#, "No contacts to show"),
            ("commander_network_online", nil, #"{"data":{"friends":[{"name":"a","online":true},{"name":"b","online":false}]},"ok":true}"#,
             "2 contacts, 1 online"),
            // Contacts without `online` cannot be counted as online: the fallback.
            ("commander_network_online", nil, #"{"data":{"friends":[{"name":"a"}]},"ok":true}"#, "Checked who is online"),
            ("commander_network_board", nil, #"{"data":{"workspaces":[]},"ok":true}"#, "Opened the task board: no workspaces"),
            ("commander_network_thread", nil, #"{"data":{"comments":[]},"ok":true}"#, "Read a request thread: no comments"),
            ("commander_network_inbox", nil, #"{"messages":[{"id":"1","text":"hi"}]}"#, "Read the network inbox: 1 message"),
            ("commander_status", nil, #"{"status":"running","workers":[{"state":"working"},{"state":"completed"}]}"#,
             "Checked the run: 2 workers, 1 running"),
            ("commander_commit", #"{"message":"Fix retry","files":["a","b"]}"#, #"{"revision":"1a2b3c4d5e6f7a8b"}"#,
             "Committed 2 files: “Fix retry”"),
            ("commander_call_tool", #"{"id":"jira.search"}"#, "{}", "Called extension jira.search"),
            ("commander_frontend_tools", nil, #"{"tools":[{"name":"a"}]}"#, "Found 1 app tool"),
        ]
        for (name, detail, result, expected) in cases {
            let made = call(name, detail: detail, result: result)
            let words = ActivityWords.commander(made)
            #expect((result == nil ? words.running : words.done).plain == expected, "\(name)")
        }
        let asked = ActivityWords.commander(call("commander_ask", detail: #"{"question":"Which database?"}"#, result: "{}"))
        #expect(asked.done.plain == "Asked: “Which database?”")
        let commit = ActivityWords.commander(call("commander_commit", result: #"{"revision":"1a2b3c4d5e6f7a8b"}"#))
        #expect(commit.tag?.word == "rev 1a2b3c4d")
    }

    @Test func aDelegationSaysWhatWasAskedAndTagsTheRunRecordState() {
        var wire = Wire()
        wire.call("commander_delegate", detail: "reader", result: #"{"id":"w-779b15a33e2ed37dbe74d7bab6d102bf","name":"reader","state":"starting"}"#)
        // Without a run record the tag is `accepted`, whatever the call's own snapshot said.
        let accepted = groups(prettyItems(wire))[0].lines[0]
        #expect(accepted.tag?.word == "accepted")
        let live = CommanderLiveState(workers: ["w-779b15a33e2ed37dbe74d7bab6d102bf": "completed"])
        let completed = groups(prettyItems(wire, live: live))[0].lines[0]
        #expect(completed.sentence.plain == "Delegated to a new worker, reader")
        #expect(completed.tag == ActivityTag(word: "completed", tone: .ok))
    }

    /// Table A, provider tools and other records.
    @Test func providerToolsReadAsSentences() {
        let cases: [(String, String?, String, String, String, String)] = [
            ("Read", "/private/tmp/acsmoke/words.txt", "Reading words.txt", "Read words.txt", "Couldn't read words.txt", "read a file"),
            ("Read", nil, "Reading a file", "Read a file", "Couldn't read a file", "read a file"),
            ("Edit", #"{"file_path":"/a/b/runner.go"}"#, "Editing runner.go", "Edited runner.go", "Couldn't edit runner.go", "edited a file"),
            ("Write", "/a/notes.md", "Writing notes.md", "Wrote notes.md", "Couldn't write notes.md", "wrote a file"),
            ("Grep", "TODO", "Searching for “TODO”", "Searched for “TODO”", "Search for “TODO” failed", "ran a search"),
            ("Glob", nil, "Searching files", "Searched files", "Search failed", "ran a search"),
            ("Bash", "swift build", "Running swift build", "Ran swift build", "swift build failed", "ran a command"),
            ("Bash", nil, "Running a command", "Ran a command", "A command failed", "ran a command"),
            ("WebSearch", "swift testing", "Searching the web for “swift testing”", "Searched the web for “swift testing”", "Web search failed", "searched the web"),
            ("WebFetch", "https://example.com/docs/page", "Fetching example.com/docs/page", "Fetched example.com/docs/page",
             "Couldn't fetch example.com/docs/page", "fetched a page"),
            ("mcp__github__list_issues", nil, "Using list_issues", "Used list_issues", "list_issues failed", "used another tool"),
        ]
        for (name, detail, running, done, failed, phrase) in cases {
            let words = ActivityWords.provider(name: name, detail: detail)
            #expect(words.running.plain == running, "\(name)")
            #expect(words.done.plain == done, "\(name)")
            #expect(words.failed.plain == failed, "\(name)")
            #expect(words.phrase?.one == phrase, "\(name)")
        }
        #expect(ActivityWords.provider(name: "TodoWrite", detail: nil).done.plain == "Updated the plan")
        #expect(ActivityWords.orphanResult.done.plain == "Got a result whose call was not recorded")
    }

    @Test func storedFieldsSupplyTheSubjectAndTheDescription() throws {
        let json = #"{"key":"t1","kind":"tool","name":"Bash","fields":{"command":"git worktree add ../x","description":"Created the task worktree"},"input_bytes":80}"#
        let summary = try JSONDecoder().decode(ToolDetailSummary.self, from: Data(json.utf8))
        // An ACP placeholder is not a subject; the stored fields are.
        let words = ActivityWords.provider(name: "Bash", detail: "execute", summary: summary)
        #expect(words.done.plain == "Created the task worktree")
        #expect(words.running.plain == "Running git worktree add ../x")
        #expect(words.help == "git worktree add ../x")
    }

    @Test func aLongCommandIsCutInTheMiddle() {
        let command = String(repeating: "a", count: 60) + " --flag " + String(repeating: "z", count: 60)
        let cut = ActivityWords.middle(command)
        #expect(cut.count == 72 && cut.hasPrefix("aaaa") && cut.hasSuffix("zzzz") && cut.contains("…"))
    }

    @Test func thoughtsShowATimeOnlyWhenTheRecordHoldsBothTimes() {
        #expect(ActivityWords.thought(duration: 112).plain == "Thought for 1m 52s")
        #expect(ActivityWords.thought(duration: nil).plain == "Thought")
        #expect(ActivityWords.thought(duration: 52, live: true).plain == "Thinking 52s")
        #expect(ActivityWords.thought(duration: nil, live: true).plain == "Thinking")
        #expect(ElapsedTime.text(0.2) == "1s")
        #expect(ElapsedTime.spoken(112) == "1 minute 52 seconds")
        let started = ToolDetailSummary(key: "m1", kind: "thought", startedAt: "2026-11-27T01:59:10Z")
        #expect(started.duration == nil)
        let timed = ToolDetailSummary(key: "m1", kind: "thought", startedAt: "2026-11-27T01:59:10.25Z", endedAt: "2026-11-27T01:59:22.25Z")
        #expect(timed.duration == 12)
    }

    @Test func aKnownDenialIsBlockedInPlainWordsAndAnythingElseIsTheFirstSentence() {
        let blocked = ActivityFailureWords.read(ToolResult(output: denial, error: "Tool failed."), status: .failed)
        #expect(blocked.outcome == .blocked)
        #expect(blocked.reason == "Claude Code is in don't-ask mode.")
        #expect(blocked.exact == "Permission to use mcp__commander__commander_network_online has been denied because Claude Code is running in don't ask mode.")
        #expect(blocked.rest?.hasPrefix("IMPORTANT:") == true)

        let failed = ActivityFailureWords.read(ToolResult(output: "", error: "Tool failed.\nexit status 1: no such file. Try again."), status: .failed)
        #expect(failed.outcome == .failed && failed.reason == "exit status 1: no such file.")
        #expect(failed.rest == "Try again.")

        let silent = ActivityFailureWords.read(ToolResult(output: "", error: "Tool failed."), status: .failed)
        #expect(silent.reason == "No reason was given." && silent.outcome == .failed)

        let declined = ActivityFailureWords.read(ToolResult(output: "", error: "Tool declined."), status: .declined)
        #expect(declined.outcome == .blocked && declined.reason == "You denied this.")
        let held = ActivityFailureWords.read(ToolResult(output: "", error: "developer holds worker input"), status: .failed)
        #expect(held.outcome == .blocked && held.reason == "Someone holds input for this worker.")
    }
}

@Suite struct ActivityGroupingTests {
    @Test func finishedCallsFoldIntoOneSummaryInOrderOfFirstAppearance() {
        var wire = Wire()
        wire.user("Go")
        wire.call("Bash", detail: "ls", result: "a")
        wire.call("Read", detail: "/a/one.txt", result: "1\tx")
        wire.call("Bash", detail: "pwd", result: "/a")
        wire.call("Read", detail: "/a/two.txt", result: "1\ty")
        wire.call("Bash", detail: "date", result: "now")
        let items = prettyItems(wire)
        #expect(items.count == 2)
        let group = groups(items)[0]
        #expect(group.lines.count == 5 && !group.isSingle)
        #expect(group.summary.text == "Ran 3 commands, read 2 files")
        #expect(group.summary.accessibilityLabel == "Activity, 5 steps. Ran 3 commands, read 2 files")
        // Nothing is dropped: every original entry is inside a line.
        #expect(items.flatMap(\.entries).count == wire.entries.count)
    }

    @Test func aSummaryNamesAtMostThreeKindsThenCountsTheRest() {
        var wire = Wire()
        wire.call("Bash", detail: "ls", result: "a")
        wire.call("Read", detail: "/a/one.txt", result: "x")
        wire.call("Grep", detail: "TODO", result: "x")
        wire.call("Edit", detail: "/a/one.txt", result: "ok")
        wire.call("Write", detail: "/a/two.txt", result: "ok")
        wire.call("Write", detail: "/a/three.txt", result: "ok")
        #expect(groups(prettyItems(wire))[0].summary.text == "Ran a command, read a file, ran a search, and 3 more steps")
    }

    @Test func aGroupOfOneIsItsSentenceAlone() {
        var wire = Wire()
        wire.call("Read", detail: "/private/tmp/acsmoke/words.txt", result: "1\talpha")
        let group = groups(prettyItems(wire))[0]
        #expect(group.isSingle && group.lines[0].sentence.plain == "Read words.txt")
        #expect(group.lines[0].help == "/private/tmp/acsmoke/words.txt")
    }

    @Test func proseAndPromptsEndAGroup() {
        var wire = Wire()
        wire.call("Bash", detail: "ls", result: "a")
        wire.say("Now step 4.")
        wire.call("Bash", detail: "pwd", result: "b")
        wire.user("And then?")
        wire.call("Bash", detail: "date", result: "c")
        let kinds = prettyItems(wire).map { item -> String in
            switch item {
            case .group: "group"
            case .entry: "entry"
            default: "other"
            }
        }
        #expect(kinds == ["group", "entry", "group", "entry", "group"])
    }

    @Test func aFailureIsNeverCountedAwayAndEndsItsGroup() {
        var wire = Wire()
        wire.call("commander_list_tools", result: #"{"tools":[]}"#)
        wire.call("mcp__commander__commander_network_online", result: denial, error: "Tool failed.")
        wire.call("Bash", detail: "ls", result: "a")
        let made = groups(prettyItems(wire))
        #expect(made.count == 2)
        #expect(made[0].lines.map(\.sentence.plain) == ["Found no extensions granted"])
        #expect(made[0].failures.map(\.sentence.plain) == ["Couldn't see who is online"])
        #expect(made[0].failures[0].tag == .blocked)
        #expect(made[0].failures[0].failure?.reason == "Claude Code is in don't-ask mode.")
        #expect(made[0].summary.text == "Listed extensions" && made[0].summary.failed == ["1 blocked"])
        #expect(made[0].summary.accessibilityLabel == "Activity, 2 steps, 1 blocked. Listed extensions")
        #expect(made[1].lines.map(\.sentence.plain) == ["Ran ls"])
    }

    @Test func aGroupWhoseCallsAllFailedHasNoSummary() {
        var wire = Wire()
        wire.call("Bash", detail: "make", result: "", error: "Tool failed.\nexit status 2")
        wire.call("Bash", detail: "make test", result: "", error: "Tool failed.\nexit status 1")
        let group = groups(prettyItems(wire))[0]
        #expect(group.lines.isEmpty && group.failures.count == 2)
        #expect(group.summary.text.isEmpty && group.summary.failed == ["2 failed"])
        #expect(group.failures[0].sentence.plain == "make failed" && group.failures[0].failure?.reason == "exit status 2")
    }

    @Test func identicalConsecutiveCallsMergeIntoOneLineWithACount() {
        var wire = Wire()
        for _ in 0..<3 { wire.call("Bash", detail: "git status", result: "clean") }
        wire.call("Bash", detail: "git diff", result: "")
        let group = groups(prettyItems(wire))[0]
        #expect(group.lines.count == 2)
        #expect(group.lines[0].count == 3 && group.lines[0].tag?.word == "3 times" && group.lines[0].entries.count == 3)
        #expect(group.summary.text == "Ran 4 commands")
    }

    @Test func theOpenCallIsTheLiveLineAndAHeldCallNeedsApproval() {
        var wire = Wire()
        wire.call("Read", detail: "/a/one.txt", result: "x")
        let open = wire.call("Bash", detail: "swift test")
        let items = prettyItems(wire)
        guard case .live(let step) = items.last else { Issue.record("no live line"); return }
        #expect(step.sentence.plain == "Running swift test" && items.count == 2)

        let held = prettyItems(wire, awaiting: open)
        guard case .approval(let approval) = held.last else { Issue.record("no approval line"); return }
        #expect(approval.sentence.plain == "Needs your approval to run swift test")
    }

    @Test func aReportIsProseAndClampsOnlyWhenAClosingMessageFollows() {
        var wire = Wire()
        wire.call("Read", detail: "/a/words.txt", result: "1\talpha")
        wire.call("commander_result", detail: #"{"result":"words.txt has 3 lines."}"#, result: #"{"id":"w-1","result":"words.txt has 3 lines."}"#)
        var items = prettyItems(wire)
        guard case .report(let report) = items.last else { Issue.record("no report"); return }
        #expect(report.text == "words.txt has 3 lines." && report.heading == "Reported to the coordinator")
        #expect(!report.closingMessageFollows)
        wire.say("I sent this to the coordinator.")
        items = prettyItems(wire, coordinator: true)
        guard case .report(let clamped) = items[1] else { Issue.record("no report"); return }
        #expect(clamped.closingMessageFollows && clamped.heading == "Reported the run result")
    }

    /// Run r-f4af52ff: the path is 172 characters. A headline's 160-character cap cut it before
    /// its file name, and the stored fields, kept under the bare tool ID, were never found.
    @Test func aCallsValueKeepsItsLengthAndTheStoredValueWinsOverThePreview() {
        let path = "/private/tmp/claude-501/-Users-ryan-GitHub-agent-commander--claude-worktrees-suspicious-jackson-eddc88/29515b22-3db8-4269-9a95-34d2a9075528/scratchpad/detailcheck/notes.txt"
        var wire = Wire()
        let read = wire.call("Read", detail: path, result: "1\tThe launch code word is heron.")
        #expect(groups(prettyItems(wire))[0].lines[0].sentence.plain == "Read notes.txt")

        // The console's preview is cut; the stored values are exact.
        wire = Wire()
        let cut = wire.call("Read", detail: String(path.prefix(159)) + "…", result: "1\talpha")
        let shell = wire.call("Bash", detail: "swift te…", result: "ok")
        let search = wire.call("Grep", detail: "retr…", result: "a.swift")
        let fetch = wire.call("WebFetch", detail: "https://example.com/do…", result: "ok")
        #expect(groups(prettyItems(wire))[0].lines[0].sentence.plain == "Read detailch…")
        func summary(_ key: String, _ name: String, _ fields: [String: AGUIValue]) -> ToolDetailSummary {
            ToolDetailSummary(key: key, kind: "tool", name: name, fields: fields)
        }
        let facts = ActivityFacts(summaries: [
            cut: summary(cut, "Read", ["file_path": .string(path)]),
            shell: summary(shell, "Bash", ["command": .string("swift test --filter Retry")]),
            search: summary(search, "Grep", ["pattern": .string("retryBudget"), "path": .string("/a")]),
        ], records: [fetch: ToolDetailRecord(key: fetch, kind: "tool", name: "WebFetch", input: #"{"url":"https://example.com/docs/page"}"#)])
        let lines = groups(prettyItems(wire, facts: facts))[0].lines.map(\.sentence.plain)
        #expect(lines == ["Read notes.txt", "Ran swift test --filter Retry", "Searched for “retryBudget”", "Fetched example.com/docs/page"])
        // The opened line's fields read the stored value too, before the full record arrives.
        let entry = wire.entries[0]
        let step = groups(prettyItems(wire, facts: facts))[0].lines[0]
        let source = ActivityResultSource(entry: entry, step: step, record: nil, summary: facts.summary(cut))
        #expect(source.fields?["file_path"] == .string(path) && !source.callIsStored)
        #expect(ActivityWords.fact("Read", detail: String(path.prefix(159)) + "…", summary: facts.summary(cut)) == path)
        _ = read
    }

    @Test @MainActor func storedDetailsAreFoundByTheFeedsWorkerPrefixedCallID() {
        let store = ToolDetailStore(summaries: ["w-1": [ToolDetailSummary(key: "toolu_01", kind: "tool", name: "Read")]],
                                    records: ["w-1": [ToolDetailRecord(key: "toolu_01", kind: "tool", input: "{}")]])
        #expect(store.summary(worker: "w-1", key: "w-1:toolu_01")?.name == "Read")
        #expect(store.summary(worker: "w-1", key: "toolu_01")?.name == "Read")
        #expect(store.record(worker: "w-1", key: "w-1:toolu_01")?.input == "{}")
        // Another worker's prefix is not removed, and a key that is only the prefix stays whole.
        #expect(store.summary(worker: "w-1", key: "w-2:toolu_01") == nil)
        #expect(ToolDetailStore.storedKey(worker: "w-1", key: "w-1:") == "w-1:")
        #expect(ToolDetailStore.storedKey(worker: "w-1", key: "event-7") == "event-7")
    }

    @Test func aResultWithNoRecordedCallIsNamedOnlyByTheRecordUnderItsExactToolID() {
        let status = #"{"id":"r-1","project":"detailcheck","status":"running","workers":[{"name":"Coordinator","state":"working"}],"requests":[]}"#
        var wire = Wire()
        wire.messages.append(AGUIMessage(id: "m-3", role: "tool", content: status, toolCallID: "w-1:toolu_01KCj"))
        wire.messages.append(AGUIMessage(id: "m-4", role: "tool", content: status))
        let entries = wire.entries
        #expect(entries[0].toolCallID == "w-1:toolu_01KCj" && entries[0].detailKey == "w-1:toolu_01KCj" && entries[1].toolCallID == nil)

        let named = ActivityFacts(summaries: ["w-1:toolu_01KCj": ToolDetailSummary(key: "toolu_01KCj", kind: "tool", name: "commander_status")])
        let lines = groups(prettyItems(wire, facts: named))[0].lines
        #expect(lines.map(\.sentence.plain) == ["Checked the run: 1 worker, 1 running", "Got a result whose call was not recorded"])
        let source = ActivityResultSource(entry: entries[0], step: lines[0], record: nil, summary: named.summary("w-1:toolu_01KCj"))
        #expect(source.name == "commander_status" && source.tried != "A call that was not recorded")

        // A record under another ID names nothing, whatever its position or time; nor does a thought's.
        let other = ActivityFacts(summaries: [
            "w-1:toolu_other": ToolDetailSummary(key: "toolu_other", kind: "tool", sequence: 1, name: "commander_status"),
        ])
        #expect(groups(prettyItems(wire, facts: other))[0].summary.text == "Got 2 results with no recorded call")
        let thought = ActivityFacts(summaries: ["w-1:toolu_01KCj": ToolDetailSummary(key: "toolu_01KCj", kind: "thought", name: "x")])
        #expect(groups(prettyItems(wire, facts: thought))[0].summary.text == "Got 2 results with no recorded call")
        #expect(ActivityResultSource(entry: entries[1], step: lines[1], record: nil, summary: nil).name.isEmpty)
    }

    @Test func theOpenCallShowsATimeOnlyFromItsRecordOverALiveConnection() {
        let started = ToolDetailSummary(key: "t", kind: "tool", startedAt: "2026-11-27T01:59:10.338546Z")
        let live = PrettyLive(isActive: true)
        #expect(live.callStart(started) == ToolDetailSummary.date("2026-11-27T01:59:10.338546Z"))
        #expect(live.callStart(started) != nil)
        // No record, no start time, a record that has ended, an idle worker or a lost connection: no time.
        #expect(live.callStart(nil) == nil)
        #expect(live.callStart(ToolDetailSummary(key: "t", kind: "tool")) == nil)
        #expect(live.callStart(ToolDetailSummary(key: "t", kind: "tool", startedAt: started.startedAt, endedAt: "2026-11-27T01:59:11Z")) == nil)
        #expect(PrettyLive().callStart(started) == nil)
        #expect(PrettyLive(isActive: true, isDisconnected: true).callStart(started) == nil)
    }

    /// The older runner keeps no arguments on a report's event: the service's response is then
    /// the only copy of the text (runs r-c7085325 and r-30bb462d).
    @Test func aReportWithoutArgumentsReadsTheTextTheServiceReturned() {
        var wire = Wire()
        wire.call("Read", detail: "/a/words.txt", result: "1\talpha")
        wire.call("commander_result", commander: ["workerId": "w-1"], result: #"{"id":"w-1","result":"words.txt has 3 lines."}"# + "\n")
        wire.say("I sent this to the coordinator.")
        let items = prettyItems(wire)
        #expect(groups(items).map(\.summary.text) == ["Read a file"])
        guard case .report(let report) = items[1] else { Issue.record("no report"); return }
        #expect(report.text == "words.txt has 3 lines." && report.closingMessageFollows)
    }

    @Test func aReportReadsItsArgumentsThenItsStoredRecordThenTheResponse() {
        var wire = Wire()
        let sent = wire.call("commander_result", detail: #"{"result":"As sent."}"#, result: #"{"id":"w-1","result":"Returned."}"#)
        let bare = wire.call("commander_result", result: #"{"id":"w-1","result":"Returned."}"#)
        let stored = #"{"result":"As stored, in full."}"#
        var facts = ActivityFacts(summaries: [:], records: [
            sent: ToolDetailRecord(key: sent, kind: "tool", input: stored),
            bare: ToolDetailRecord(key: bare, kind: "tool", input: stored),
        ])
        func texts(_ facts: ActivityFacts) -> [String] {
            prettyItems(wire, facts: facts).compactMap { if case .report(let report) = $0 { report.text } else { nil } }
        }
        #expect(texts(facts) == ["As sent.", "As stored, in full."])
        // A short value is in the summary's fields; a stored input that was cut short is not the text.
        facts = ActivityFacts(summaries: [bare: ToolDetailSummary(key: bare, kind: "tool", fields: ["result": .string("Short.")])],
                              records: [bare: ToolDetailRecord(key: bare, kind: "tool", input: #"{"result":"As stor"#)])
        #expect(texts(facts) == ["As sent.", "Short."])
        #expect(texts(.none) == ["As sent.", "Returned."])
        // Only a finished report whose call carries no text has its record read.
        wire.call("commander_result", result: "", error: "Tool failed.\nexit status 1")
        wire.call("commander_result")
        #expect(ActivitySteps.reportsToRead(wire.entries) == [bare])
    }

    @Test func aReportWithNoTextStandsAloneAndAFailedOneKeepsItsError() {
        var wire = Wire()
        wire.call("Read", detail: "/a/words.txt", result: "1\talpha")
        wire.call("commander_result", result: "{}")
        var items = prettyItems(wire)
        #expect(items.count == 2 && groups(items).map(\.summary.text) == ["Read a file", "Reported a result"])
        #expect(groups(items)[1].isSingle)

        wire = Wire()
        wire.call("Read", detail: "/a/words.txt", result: "1\talpha")
        wire.call("commander_result", result: #"{"id":"w-1","result":"not a report"}"#, error: "Tool failed.")
        items = prettyItems(wire)
        #expect(!items.contains { if case .report = $0 { true } else { false } })
        #expect(groups(items).flatMap(\.failures).map(\.sentence.plain) == ["Couldn't report the result"])
        #expect(!groups(items).flatMap(\.lines).contains { $0.sentence.plain == "Reported a result" })
    }

    @Test func aQuestionWithItsAnswerIsOneLineAndAPendingOneStandsAlone() {
        let id = "q-83202cb42d449a0f52b7981d56ac896a"
        func record(_ status: String, _ answer: String = "") -> String {
            #"{"id":"\#(id)","worker_id":"w","question":"Which database?","status":"\#(status)","answer":"\#(answer)"}"#
        }
        var wire = Wire()
        wire.call("Bash", detail: "ls", result: "a")
        wire.call("commander_ask", detail: #"{"question":"Which database?"}"#, result: record("pending"))
        wire.call("commander_wait", commander: ["requestId": id], result: record("pending"))
        var made = groups(prettyItems(wire))
        // Pending: never folded, tagged waiting.
        #expect(made.count == 2 && made[1].isSingle)
        #expect(made[1].lines[0].sentence.plain == "Asked: “Which database?”" && made[1].lines[0].tag?.word == "waiting")

        wire.call("commander_wait", commander: ["requestId": id], result: record("answered", "Postgres"))
        made = groups(prettyItems(wire))
        #expect(made.count == 1 && made[0].lines.count == 2)
        #expect(made[0].lines[1].workflow?.calls.count == 3)
        #expect(made[0].summary.text == "Ran a command, asked a question and got an answer")
    }

    @Test func quietRowsFoldAndAttentionEventsDoNot() throws {
        var wire = Wire()
        wire.call("Bash", detail: "ls", result: "a")
        let usage = #"{"id":"u1","role":"system","content":"[ACP usage_update]","metadata":{"acp":{"kind":"usage_update","source":"live","usage":{"used":45200,"size":200000}}}}"#
        wire.messages.append(try JSONDecoder().decode(AGUIMessage.self, from: Data(usage.utf8)))
        wire.messages.append(AGUIMessage(id: "e1", role: "system", content: "[Provider stderr] warning: slow disk"))
        wire.call("Bash", detail: "pwd", result: "b")
        let items = prettyItems(wire)
        #expect(items.count == 3)
        let first = groups(items)[0]
        #expect(first.lines.map(\.kind) == [.call, .quiet])
        #expect(first.summary.text == "Ran a command")
        guard case .entry(let stderr) = items[1] else { Issue.record("stderr folded"); return }
        #expect(stderr.id == "e1")
    }

    @Test func aGroupOfOnlySessionRowsCountsThem() {
        let quiet = { (id: String) in
            ActivityStep(id: id, kind: .quiet, entries: [], state: .done, sentence: ActivitySentence("Mode default"))
        }
        #expect(ActivityGroup.summary(lines: [quiet("a"), quiet("b")], failures: []).text == "2 session updates")
        let thought = { (seconds: TimeInterval?) in
            ActivityStep(id: "t", kind: .thought, entries: [], state: .done, sentence: ActivitySentence("Thought"),
                         duration: seconds, text: "x")
        }
        #expect(ActivityGroup.summary(lines: [thought(60), thought(52)], failures: []).text == "Thought for 1m 52s")
        #expect(ActivityGroup.summary(lines: [thought(60), thought(nil)], failures: []).text == "Thought")
    }

    @Test func aClosedGroupNamesATagThatIsNotPlainSuccess() {
        var wire = Wire()
        wire.call("commander_delegate", detail: "reader", result: #"{"id":"w-1","name":"reader","state":"starting"}"#)
        wire.call("commander_delegate", detail: "tracer", result: #"{"id":"w-2","name":"tracer","state":"starting"}"#)
        let live = CommanderLiveState(workers: ["w-1": "completed"])
        let summary = groups(prettyItems(wire, live: live))[0].summary
        #expect(summary.text == "Delegated to 2 workers" && summary.notes == ["1 accepted"])
    }

    @Test func aPlanIsOneCardPerTurnUpdatedInPlace() throws {
        var wire = Wire()
        wire.user("Plan it")
        wire.call("TodoWrite", detail: #"{"todos":[{"content":"Map phases","status":"in_progress","activeForm":"Mapping phases"}]}"#, result: "ok")
        wire.call("Bash", detail: "ls", result: "a")
        wire.call("TodoWrite", detail: #"{"todos":[{"content":"Map phases","status":"completed"},{"content":"Run suite","status":"pending"}]}"#, result: "ok")
        let items = prettyItems(wire)
        let plans = items.compactMap { if case .plan(let plan) = $0 { plan } else { nil } }
        #expect(plans.count == 1 && plans[0].entries.count == 2)
        #expect(plans[0].items?.map(\.state) == [.done, .pending])
        // Without the items the card is its fallback line.
        var bare = Wire()
        bare.call("TodoWrite", detail: "other", result: "ok")
        guard case .plan(let fallback) = prettyItems(bare)[0] else { Issue.record("no plan"); return }
        #expect(fallback.items == nil && fallback.fallback == "Updated the plan")
    }

    @Test func aBoundedSurfaceShowsTheFirstAndLatestThreeLinesOfAnOpenGroup() {
        var wire = Wire()
        for index in 0..<7 { wire.call("Read", detail: "/a/f\(index).txt", result: "x") }
        let group = groups(prettyItems(wire))[0]
        let shown = group.shownLines(limit: 4)
        #expect(shown.hidden == 3 && shown.lines.map(\.sentence.plain) == ["Read f0.txt", "Read f4.txt", "Read f5.txt", "Read f6.txt"])
        #expect(group.shownLines(limit: nil).hidden == 0)
    }
}

@Suite struct ActivityResultTests {
    @Test func jsonIsIndentedTwoSpacesWithKeysInTheOrderSent() {
        let formatted = PrettyJSON.format(#"{"zeta":1,"alpha":{"b":[1,"two",null],"a":"{\"inner\":true}"},"empty":[]}"#)
        #expect(formatted.isJSON && !formatted.isCut)
        #expect(formatted.text == """
        {
          "zeta": 1,
          "alpha": {
            "b": [
              1,
              "two",
              null
            ],
            "a": "{\\"inner\\":true}"
          },
          "empty": []
        }
        """)
        #expect(!PrettyJSON.format("1\talpha\n2\tbravo").isJSON)
    }

    @Test func cutJSONIsIndentedAsFarAsItGoes() {
        let formatted = PrettyJSON.format(#"{"id":"r-1","workers":[{"name":"a"},{"name":"b","resu"# + "\n[Output shortened]")
        #expect(formatted.isJSON && formatted.isCut)
        #expect(formatted.text.contains("\"name\": \"a\""))
        let payload = ResultPayload.read(#"{"id":"r-1","status":"running","workers":[{"name":"a"},{"na"# + "\n[Output shortened]")
        #expect(payload.isCut && payload.value?["workers"]?.items?.count == 1)
    }

    @Test func aResultIsUnwrappedFromMCPContentAndTheNetworkWrapper() {
        let mcp = ResultPayload.read(#"{"content":[{"type":"text","text":"{\"tools\":[]}"}]}"#)
        #expect(mcp.value?["tools"]?.items?.isEmpty == true)
        let network = ResultPayload.read(#"{"data":{"friends":[]},"ok":true}"#)
        #expect(network.value?["friends"]?.items?.isEmpty == true && network.wrapperError == nil)
        let refused = ResultPayload.read(#"{"ok":false,"error":"not a member"}"#)
        #expect(refused.wrapperError == "not a member")
    }

    /// Section E: the renderer a result selects, from run1 and run2's shapes.
    @Test func aRendererIsSelectedByTheResultsShape() {
        let cases: [(String, String, ResultShape)] = [
            ("commander_delegate", #"{"id":"w-1","name":"reader","role":"worker","state":"starting","task":"Read words.txt","output":""}"#, .workerCard),
            // A run status with no recorded call still draws as a roster.
            ("", #"{"id":"r-1","project":"acsmoke","status":"running","workers":[{"name":"Coordinator","state":"working"}],"requests":[]}"#, .runRoster),
            ("commander_ask", #"{"id":"q-1","question":"Which?","status":"pending","answer":""}"#, .questionCard),
            ("commander_reply", #"{"id":"w-1","state":"working"}"#, .acknowledgement),
            ("commander_commit", #"{"revision":"1a2b3c4"}"#, .acknowledgement),
            ("commander_result", #"{"id":"w-1","result":"done"}"#, .report),
            ("commander_send", #"{"id":"m-1","status":"queued","text":"Also check X","generation":2}"#, .followUp),
            ("commander_interrupt", #"{"held":false,"generation":3,"messages":[]}"#, .controlState),
            ("commander_integrate", #"{"id":"i-1","workers":["w-1"],"candidate":{"status":"tested"}}"#, .operationReceipt),
            ("commander_list_tools", #"{"tools":[]}"#, .empty("No extensions are granted.")),
            ("commander_list_tools", #"{"tools":[{"id":"a","version":"1"},{"id":"b","version":"2"}]}"#, .recordTable(key: "tools")),
            ("commander_network_online", #"{"data":{"friends":[]},"ok":true}"#, .empty("The contact list is empty.")),
            ("commander_network_board", #"{"data":{"workspaces":[]},"ok":true}"#, .empty("No workspaces.")),
            ("commander_network_inbox", #"{"messages":[{"id":"1","peer":"ana","text":"hi","receivedAt":"2026-11-27T00:30:33Z"}]}"#, .messageList(key: "messages")),
            ("TodoWrite", #"[{"content":"Map","status":"pending"}]"#, .checklist(key: nil)),
            ("Read", "1\talpha\n2\tbravo", .textFile),
            ("Read", "", .empty("The file is empty.")),
            ("Bash", "ok\n", .terminal),
            ("Bash", "", .empty("The command printed nothing.")),
            ("Grep", "", .empty("Nothing matched.")),
            ("Grep", "a.swift:3:TODO", .searchResults),
            ("mcp__x__unknown", #"{"a":1,"b":{"c":2},"d":[1,2],"e":"x"}"#, .generic),
            ("mcp__x__unknown", "plain words", .text),
            ("mcp__x__unknown", "{}", .empty("Empty result.")),
        ]
        for (tool, result, shape) in cases {
            let selection = ResultShape.select(tool: tool, payload: .read(result), resultText: result, failed: false)
            #expect(selection.shape == shape, "\(tool) \(result)")
        }
        let failed = ResultShape.select(tool: "Bash", payload: .read("boom"), resultText: "boom", failed: true)
        #expect(failed.shape == .failure)
        let refused = ResultShape.select(tool: "commander_network_online", payload: .read(#"{"ok":false,"error":"x"}"#),
                                         resultText: nil, failed: false)
        #expect(refused.shape == .failure)
    }

    @Test func aRendererPlacesItsPropertiesAndLeavesTheRestForMoreFields() {
        let worker = #"{"id":"w-1","name":"reader","role":"worker","parent_id":"w-0","run_id":"r-1","state":"starting","host":"localhost","task":"Read","output":""}"#
        let selection = ResultShape.select(tool: "commander_delegate", payload: .read(worker), resultText: worker, failed: false)
        #expect(selection.placed == ["name", "role", "state", "task", "host"])
        #expect(selection.remaining == ["id", "parent_id", "run_id", "output"])
    }

    @Test func genericFieldsAreLabelledAndTypedByTheirValues() {
        let value = OrderedJSON.read(#"{"created_at":"2026-11-27T00:30:33Z","state":"starting","held":false,"output":"","coordinator_id":"w-da045371c3671b03b68accb481575127","worktree":"/private/tmp/acsmoke","count":3,"names":["a","b"],"apiToken":"abc"}"#)!.value
        let rows = ResultField.rows(value)
        #expect(rows.map(\.label) == ["Created at", "State", "Held", "Output", "Coordinator ID", "Worktree", "Count", "Names", "Api token"])
        #expect(rows.map(\.kind) == [.time, .status, .yesNo, .empty, .id, .path, .number, .scalarList, .secret])
        #expect(ResultField.statusWord("delivery_unknown") == "Delivery unknown")
    }

    @Test func secretLookingValuesAreHiddenOnlyByKeyOrKnownForm() {
        #expect(SecretValues.keyLooksSecret("api_key") && SecretValues.keyLooksSecret("Authorization"))
        #expect(!SecretValues.keyLooksSecret("idempotency_key") && !SecretValues.keyLooksSecret("path"))
        #expect(SecretValues.valueLooksSecret("Bearer abcdefghijklmnop"))
        #expect(SecretValues.valueLooksSecret("sk-abcdefghijklmnopqrstuv"))
        #expect(SecretValues.valueLooksSecret("eyJhbGciOi.eyJzdWIiOi.signature"))
        #expect(!SecretValues.valueLooksSecret("skip this"))
        let masked = SecretValues.masked(text: #"{"url":"https://x","headers":{"authorization":"Bearer abcdefghijklmnop"},"idempotency_key":"k1"}"#)
        #expect(masked.count == 1)
        #expect(masked.text.contains("Hidden, 23 characters") && !masked.text.contains("abcdefghijklmnop"))
        #expect(masked.text.contains("\"idempotency_key\": \"k1\""))
        let plain = SecretValues.masked(text: "curl -H Authorization: Bearer abcdefghijklmnop https://x")
        #expect(plain.count == 1 && !plain.text.contains("abcdefghijklmnop"))
        #expect(SecretValues.masked(text: "nothing here").count == 0)
    }

    @Test func toolDetailSummariesDecodeTheServicesShape() throws {
        let json = #"{"revision":4,"records":[{"key":"toolu_01","kind":"tool","sequence":1,"name":"Read","started_at":"2026-11-27T01:59:10.338546Z","ended_at":"2026-11-27T01:59:10.388417Z","revision":3,"fields":{"file_path":"/a/b.txt","limit":20},"input_bytes":40,"result_bytes":12},{"key":"event-7","kind":"plan","sequence":7,"plan":[{"content":"Map","priority":"high","status":"in_progress"}],"revision":4}]}"#
        let page = try JSONDecoder().decode(ToolDetailPage.self, from: Data(json.utf8))
        #expect(page.revision == 4 && page.records.count == 2)
        #expect(page.records[0].field("file_path") == "/a/b.txt" && page.records[0].field("limit") == "20")
        #expect(page.records[0].duration.map { $0 > 0.04 && $0 < 0.06 } == true)
        #expect(page.records[1].plan?.first?.state == .inProgress)
        let settings = try JSONDecoder().decode(TranscriptSettings.self, from: Data(#"{"hide_secrets":true,"limit_bytes":16384}"#.utf8))
        #expect(settings.hideSecrets && settings.limitBytes == TranscriptSettings.offeredLimit && !settings.keepsEverything)
        #expect(String(decoding: try JSONEncoder().encode(TranscriptSettings()), as: UTF8.self).contains("\"hide_secrets\":false"))
    }
}
