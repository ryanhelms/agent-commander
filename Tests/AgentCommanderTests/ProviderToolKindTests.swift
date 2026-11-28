import Foundation
import Testing
@testable import AgentCommander

// The verb of a tool Commander does not know (spec section H, ACP tool `kind`): the exact wire
// kinds, the three phases, the provider's title as the object, the fallbacks, masking, and the
// closed group's phrase, which needs the call's own file location. The fixture is the mock ACP
// peer's three calls as the service stores them: a read "Materialize reference" with one
// location, a failed search "Find marker" with none, and an `other` call "Custom operation".

private let samplePath = "/private/tmp/ac-kind/Activity QA/sample.txt"

/// One stored summary, decoded from the service's wire form.
private func summary(_ key: String, kind: String? = nil, title: String? = nil, name: String? = nil,
                     path: String? = nil, record: String = "tool") throws -> ToolDetailSummary {
    var members: [String: Any] = ["kind": record, "key": key]
    if let kind { members["tool_kind"] = kind }
    if let title { members["title"] = title }
    if let name { members["name"] = name }
    if let path { members["location"] = ["path": path, "line": 1] }
    let page = try JSONSerialization.data(withJSONObject: ["revision": 1, "records": [members]])
    return try #require(try JSONDecoder().decode(ToolDetailPage.self, from: page).records.first)
}

/// A console tool call as the service sends an ACP one: the title as its name, the kind as its text.
private func entry(_ id: String, name: String, detail: String? = nil, output: String? = nil,
                   error: String? = nil) -> TranscriptEntry {
    let result = output == nil && error == nil ? nil : ToolResult(output: output ?? "", error: error)
    return TranscriptEntry(id: id, kind: .tool(name: name, detail: detail, result: result))
}

private func facts(_ summaries: [ToolDetailSummary], hidesSecrets: Bool = false) -> ActivityFacts {
    var facts = ActivityFacts(summaries: Dictionary(uniqueKeysWithValues: summaries.map { ($0.key, $0) }))
    facts.hidesSecrets = hidesSecrets
    return facts
}

private func step(_ entry: TranscriptEntry, _ summaries: [ToolDetailSummary], hidesSecrets: Bool = false,
                  awaiting: String? = nil) throws -> ActivityStep {
    try #require(ActivitySteps.step(tool: entry, awaitingToolID: awaiting, facts: facts(summaries, hidesSecrets: hidesSecrets)))
}

private func groups(_ entries: [TranscriptEntry], _ summaries: [ToolDetailSummary]) -> [ActivityGroup] {
    ActivityConversation.items(ConversationActivity.items(entries), facts: facts(summaries))
        .compactMap { if case .group(let group) = $0 { group } else { nil } }
}

@Suite struct ProviderToolKindTests {
    static let table: [(wire: String, running: String, done: String, failed: String, one: String)] = [
        ("read", "Reading T", "Read T", "Couldn't read T", "read a file"),
        ("edit", "Editing T", "Edited T", "Couldn't edit T", "edited a file"),
        ("delete", "Deleting T", "Deleted T", "Couldn't delete T", "deleted a file"),
        ("move", "Moving T", "Moved T", "Couldn't move T", "moved a file"),
        ("search", "Searching T", "Searched T", "Couldn't search T", "ran a search"),
        ("execute", "Running T", "Ran T", "Couldn't run T", "ran a command"),
        ("think", "Thinking through T", "Thought through T", "Couldn't think through T", "thought"),
        ("fetch", "Fetching T", "Fetched T", "Couldn't fetch T", "fetched a file"),
        ("switch_mode", "Switching mode: T", "Switched mode: T", "Couldn't switch mode: T", "switched mode"),
    ]

    // MARK: Exact source mapping

    @Test func eachWireKindPicksItsVerbsForEveryPhase() throws {
        #expect(Set(Self.table.map(\.wire)) == Set(ProviderToolKind.allCases.map(\.rawValue)))
        for row in Self.table {
            let words = try #require(ActivityWords.kind(summary: summary("c", kind: row.wire, title: "T")), "\(row.wire)")
            #expect(words.running.plain == row.running && words.done.plain == row.done
                    && words.fallback.plain == row.done && words.failed.plain == row.failed, "\(row.wire)")
            // With no location the call counts as another tool; with the call's own, as its kind.
            #expect(words.phrase == ActivityWords.otherToolPhrase, "\(row.wire)")
            let located = try #require(ActivityWords.kind(summary: summary("c", kind: row.wire, title: "T", path: samplePath)))
            #expect(located.phrase?.one == row.one, "\(row.wire)")
            #expect(located.done == words.done, "\(row.wire)")
        }
    }

    @Test func aKindIsMatchedOnItsWholeWireValue() throws {
        for wire in ["Read", "READ", " read", "read ", "reading", "switch mode", "switchMode", "switch-mode", "other", "", "write",
                     "terminal"] {
            #expect(ProviderToolKind(wire: wire) == nil, "\(wire)")
            #expect(try ActivityWords.kind(summary: summary("c", kind: wire, title: "T")) == nil, "\(wire)")
        }
        #expect(ProviderToolKind(wire: nil) == nil)
        #expect(ProviderToolKind(wire: "switch_mode") == .switchMode)
    }

    // MARK: The mock peer's three calls

    @Test func theFixtureCallsReadAsTheirKindsInEachPhase() throws {
        let read = try summary("ac-read", kind: "read", title: "Materialize reference", path: samplePath)
        let search = try summary("ac-search", kind: "search", title: "Find marker")
        let other = try summary("ac-other", kind: "other", title: "Custom operation")
        let all = [read, search, other]

        let running = try step(entry("ac-read", name: "Materialize reference", detail: "read"), all)
        #expect(running.state == .running && running.sentence.plain == "Reading Materialize reference")
        let done = try step(entry("ac-read", name: "Materialize reference", detail: "read", output: "Provider result ac-read"), all)
        #expect(done.state == .done && done.sentence.plain == "Read Materialize reference" && done.tag == nil)
        #expect(done.sentence == ActivitySentence(.text("Read "), .strong("Materialize reference")))
        #expect(done.accessibilityLabel == "Read Materialize reference")
        // The sentence is the line's help: no wire name or path is added to it.
        #expect(done.help == nil)

        let failed = try step(entry("ac-search", name: "Find marker", detail: "search",
                                    output: "Tool failed.\nProvider result ac-search", error: "Tool failed."), all)
        #expect(failed.state == .failed && failed.sentence.plain == "Couldn't search Find marker")
        #expect(failed.tag == .failed && failed.failure?.reason == "Provider result ac-search")
        #expect(failed.accessibilityLabel == "Couldn't search Find marker, Failed, Provider result ac-search")

        let generic = try step(entry("ac-other", name: "Custom operation", detail: "other", output: "Provider result ac-other"), all)
        #expect(generic.sentence == ActivitySentence(.text("Used "), .mono("Custom operation")))
        #expect(generic.phrase == ActivityWords.otherToolPhrase && generic.help == "Custom operation")
    }

    @Test func everyOutcomeKeepsItsOwnStatus() throws {
        let stored = [try summary("c", kind: "edit", title: "Patch config")]
        func made(_ error: String) throws -> ActivityStep { try step(entry("c", name: "Patch config", output: "", error: error), stored) }
        let declined = try made("Tool declined.")
        #expect(declined.state == .failed && declined.sentence.plain == "Couldn't edit Patch config")
        #expect(declined.tag == .blocked && declined.failure?.reason == "You denied this.")
        let cancelled = try made("Tool cancelled.")
        #expect(cancelled.sentence.plain == "Couldn't edit Patch config")
        #expect(cancelled.tag == .blocked && cancelled.failure?.reason == "The request was cancelled.")
        let interrupted = try made("Tool interrupted.")
        #expect(interrupted.state == .done && interrupted.sentence.plain == "Edited Patch config")
        #expect(interrupted.tag == ActivityTag(word: "cancelled", tone: .wait))
        // A held call keeps the approval sentence it had.
        let held = try step(entry("c", name: "Patch config"), stored, awaiting: "c")
        #expect(held.state == .awaitingApproval && held.sentence.plain == "Needs your approval to use Patch config")
    }

    // MARK: Named tools keep their own sentence

    @Test func aToolCommanderKnowsIgnoresTheStatedKind() throws {
        // The provider calls each of these something else; the tool's own name still decides.
        let cases: [(name: String, detail: String?, kind: String, done: String)] = [
            ("Read", "/repo/a.swift", "delete", "Read a.swift"),
            ("Bash", "go test ./...", "think", "Ran go test ./..."),
            ("TodoWrite", nil, "fetch", "Updated the plan"),
            ("ToolSearch", nil, "search", "Loaded tools"),
            ("sleep", nil, "execute", "Waited"),
        ]
        for row in cases {
            let stored = try summary("c", kind: row.kind, title: "Provider title")
            let words = ActivityWords.provider(name: row.name, detail: row.detail, summary: stored)
            #expect(words.done.plain == row.done, "\(row.name)")
            #expect(words == ActivityWords.provider(name: row.name, detail: row.detail, summary: try summary("c")), "\(row.name)")
        }
        // A Commander tool never reaches the provider's wording.
        var wire = Wire()
        wire.call("commander_network_online", result: "{}")
        let call = try #require(CommanderCall(entry: wire.entries[0]))
        #expect(ActivityWords.commander(call, detail: try summary("c", kind: "read", title: "Provider title")).done.plain
                == ActivityWords.commander(call).done.plain)
    }

    // MARK: Fallbacks

    @Test func missingOrUnrecognisedDataKeepsTheGenericSentence() throws {
        let generic = ActivityWords.provider(name: "Materialize reference", detail: "read")
        #expect(generic.running.plain == "Using Materialize reference" && generic.done.plain == "Used Materialize reference")
        #expect(generic.failed.plain == "Materialize reference failed" && generic.phrase == ActivityWords.otherToolPhrase)
        let stored: [ToolDetailSummary?] = [
            nil,
            try summary("c"),
            try summary("c", kind: "read"),
            try summary("c", kind: "read", title: ""),
            try summary("c", kind: "read", title: " \n\t"),
            try summary("c", title: "Materialize reference"),
            try summary("c", kind: "other", title: "Materialize reference"),
            try summary("c", kind: "unheard_of", title: "Materialize reference"),
            // A record of another type is not a tool call's, whatever members it holds.
            try summary("c", kind: "read", title: "Materialize reference", path: samplePath, record: "job"),
        ]
        for (index, summary) in stored.enumerated() {
            #expect(ActivityWords.kind(summary: summary) == nil, "\(index)")
            #expect(ActivityWords.provider(name: "Materialize reference", detail: "read", summary: summary) == generic, "\(index)")
        }
    }

    @Test func nothingIsReadFromTheCallsNameTextOrAnotherCall() throws {
        // Words that look like a kind or a path, on the call and in its stored fields.
        for name in ["Reading notes", "Search the index", "Read file /repo/a.swift", "mcp__files__delete", "switch_mode", samplePath] {
            for detail in [nil, "read", "search", "edit", samplePath, "kind: read"] as [String?] {
                let words = ActivityWords.provider(name: name, detail: detail, summary: try summary("c", name: name))
                #expect(words.done.plain == "Used " + ActivityWords.bareName(name), "\(name) \(detail ?? "nil")")
                #expect(words.phrase == ActivityWords.otherToolPhrase, "\(name) \(detail ?? "nil")")
            }
        }
        // The neighbouring call's record, under another key, is never this call's.
        let neighbour = try summary("ac-read", kind: "read", title: "Materialize reference", path: samplePath)
        let made = try step(entry("ac-other", name: "Custom operation", detail: "read", output: "ok"), [neighbour])
        #expect(made.sentence.plain == "Used Custom operation" && made.phrase == ActivityWords.otherToolPhrase)
    }

    // MARK: The provider's title

    @Test func theTitleIsTheObjectExactlyAsSent() throws {
        let long = String(repeating: "Long title ", count: 40) + "end"
        for title in ["Materialize reference", "read /etc/hosts", "`rm -rf build`", "Übersicht – «état»", "to code mode", long] {
            let words = try #require(ActivityWords.kind(summary: summary("c", kind: "read", title: title)))
            #expect(words.done == ActivitySentence(.text("Read "), .strong(title)), "\(title)")
        }
        // A sentence is one line: the title's first, without the space around it.
        let lines = try #require(ActivityWords.kind(summary: summary("c", kind: "move", title: "  First line\nsecond line ")))
        #expect(lines.done.plain == "Moved First line")
        // The stored title is the object, not the name the console event shows.
        let stored = [try summary("c", kind: "fetch", title: "Stored title")]
        #expect(try step(entry("c", name: "Console name", output: "ok"), stored).sentence.plain == "Fetched Stored title")
    }

    @Test func aTitleNeverMakesAPath() throws {
        // A title that is a path, with no location on the call: no file phrase, no help path.
        let words = try #require(ActivityWords.kind(summary: summary("c", kind: "read", title: samplePath)))
        #expect(words.done.plain == "Read " + samplePath)
        #expect(words.phrase == ActivityWords.otherToolPhrase && words.help == nil)
        // A location the service cleared, or one that is not exactly one valid file and line.
        for location in [#"{"path":"","line":0}"#, #"{"path":"relative/a.txt","line":3}"#, #"[{"path":"/a","line":1}]"#, "null"] {
            let json = #"{"revision":1,"records":[{"kind":"tool","key":"c","tool_kind":"read","title":"T","location":\#(location)}]}"#
            let stored = try #require(try JSONDecoder().decode(ToolDetailPage.self, from: Data(json.utf8)).records.first)
            #expect(ActivityWords.kind(summary: stored)?.phrase == ActivityWords.otherToolPhrase, "\(location)")
        }
    }

    // MARK: Masking

    @Test func aSecretInTheTitleIsHiddenEverywhereTheSentenceGoes() throws {
        // A fabricated named value, in the form the masking tests use. It is no real credential.
        let title = "API_TOKEN=fixtureonly make deploy", fixtureValue = "fixtureonly"
        let masked = "API_TOKEN=Hidden, 11 characters make deploy"
        let stored = [try summary("c", kind: "execute", title: title, path: samplePath)]
        let hidden = try step(entry("c", name: "deploy", output: "ok"), stored, hidesSecrets: true)
        #expect(hidden.sentence.plain == "Ran " + masked)
        for text in [hidden.sentence.plain, hidden.accessibilityLabel, hidden.help ?? hidden.sentence.plain,
                     hidden.phrase?.one ?? "", hidden.phrase?.many ?? ""] {
            #expect(!text.contains(fixtureValue))
        }
        let failed = try step(entry("c", name: "deploy", output: "", error: "Tool failed."), stored, hidesSecrets: true)
        #expect(failed.sentence.plain == "Couldn't run " + masked)
        #expect(!failed.accessibilityLabel.contains(fixtureValue))
        let running = try step(entry("c", name: "deploy"), stored, hidesSecrets: true)
        #expect(running.sentence.plain == "Running " + masked)
        // The setting off shows the title as sent; the stored summary is never changed.
        #expect(try step(entry("c", name: "deploy", output: "ok"), stored).sentence.plain == "Ran " + title)
        #expect(stored[0].title == title)
        // An orphan result named by its stored record is masked the same way.
        let named = [try summary("c", kind: "execute", title: title, name: "deploy")]
        var orphan = TranscriptEntry(id: "m-1", kind: .output(ToolResult(output: "ok")))
        orphan.toolCallID = "c"
        let line = try #require(ActivitySteps.step(orphan: orphan, facts: facts(named, hidesSecrets: true)))
        #expect(line.sentence.plain == "Ran " + masked && !line.accessibilityLabel.contains(fixtureValue))
    }

    // MARK: Closed groups

    @Test func aClosedGroupCountsAKindOnlyWithTheCallsOwnLocation() throws {
        let stored = [
            try summary("a", kind: "read", title: "Materialize reference", path: samplePath),
            try summary("b", kind: "read", title: "Load defaults", path: "/repo/defaults.json"),
            try summary("c", kind: "read", title: "/repo/looks/like/a/path.txt"),
            try summary("d", kind: "delete", title: "Drop cache"),
            try summary("e", kind: "other", title: "Custom operation"),
        ]
        let entries = [
            entry("a", name: "Materialize reference", detail: "read", output: "ok"),
            entry("b", name: "Load defaults", detail: "read", output: "ok"),
            entry("c", name: "/repo/looks/like/a/path.txt", detail: "read", output: "ok"),
            entry("d", name: "Drop cache", detail: "delete", output: "ok"),
            entry("e", name: "Custom operation", detail: "other", output: "ok"),
        ]
        let group = try #require(groups(entries, stored).first)
        #expect(group.lines.map(\.sentence.plain) == ["Read Materialize reference", "Read Load defaults",
                                                     "Read /repo/looks/like/a/path.txt", "Deleted Drop cache", "Used Custom operation"])
        #expect(group.summary.text == "Read 2 files, used 3 other tools" && group.summary.steps == 5)
    }

    @Test func aLocatedKindAddsUpWithTheNamedToolOfTheSamePhrase() throws {
        let stored = [try summary("a", kind: "read", title: "Materialize reference", path: samplePath),
                      try summary("b", kind: "execute", title: "Rebuild index", path: samplePath)]
        let entries = [entry("a", name: "Materialize reference", output: "ok"), entry("r", name: "Read", detail: "/repo/a.swift", output: "ok"),
                       entry("b", name: "Rebuild index", output: "ok"), entry("s", name: "Bash", detail: "go vet ./...", output: "ok")]
        #expect(groups(entries, stored).first?.summary.text == "Read 2 files, ran 2 commands")
        // A located ACP fetch is a file, under its own key: it never adds to the named web fetch.
        let fetched = [try summary("f", kind: "fetch", title: "Pull snapshot", path: samplePath),
                       try summary("g", kind: "fetch", title: "Pull index", path: samplePath),
                       try summary("u", kind: "fetch", title: "Pull remote")]
        let calls = [entry("f", name: "Pull snapshot", output: "ok"), entry("w", name: "WebFetch", detail: "https://example.com/docs", output: "ok"),
                     entry("g", name: "Pull index", output: "ok"), entry("u", name: "Pull remote", output: "ok")]
        let group = try #require(groups(calls, fetched).first)
        #expect(group.summary.text == "Fetched 2 files, fetched a page, used another tool")
        #expect(group.lines.map(\.sentence.plain) == ["Fetched Pull snapshot", "Fetched example.com/docs", "Fetched Pull index",
                                                     "Fetched Pull remote"])
        #expect(ProviderToolKind.fetch.phrase == ActivityPhrase(key: "fetch", one: "fetched a file", many: "fetched %d files"))
    }

    @Test func aFailedKindStaysVisibleUnderItsGroup() throws {
        let stored = [try summary("ac-read", kind: "read", title: "Materialize reference", path: samplePath),
                      try summary("ac-search", kind: "search", title: "Find marker"),
                      try summary("ac-other", kind: "other", title: "Custom operation")]
        let entries = [
            entry("ac-read", name: "Materialize reference", detail: "read", output: "Provider result ac-read"),
            entry("ac-search", name: "Find marker", detail: "search", output: "Tool failed.\nProvider result ac-search", error: "Tool failed."),
            entry("ac-other", name: "Custom operation", detail: "other", output: "Provider result ac-other"),
        ]
        let built = groups(entries, stored)
        // The grouping is as before: the failure sits under the group it follows and ends it.
        #expect(built == groups(entries, []).enumerated().map { index, plain in
            var group = plain
            group.lines = built[index].lines
            group.failures = built[index].failures
            return group
        })
        #expect(built.map { $0.lines.map(\.sentence.plain) } == [["Read Materialize reference"], ["Used Custom operation"]])
        #expect(built.first?.failures.map(\.sentence.plain) == ["Couldn't search Find marker"])
        #expect(built.first?.summary.text == "Read a file" && built.first?.summary.failed == ["1 failed"])
    }
}
