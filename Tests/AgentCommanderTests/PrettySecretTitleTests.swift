import Foundation
import Testing
@testable import AgentCommander

// A tool Commander does not know by name can carry the provider's own title as its name. Under
// the hide-secrets setting, a secret-looking value in it is hidden in the collapsed line, its
// help, what VoiceOver reads, the failure renderer's "Tried" and Source's name (DESIGN.md,
// "Hidden secrets"). The values below are fabricated; none is a real credential.

private let fixtureValue = "synthetic-secret-value"
private let hiddenValue = "Hidden, 22 characters"
private let findTitle = "Find token=" + fixtureValue
private let readTitle = "Materialize password=" + fixtureValue

private func facts(hidesSecrets: Bool, summaries: [String: ToolDetailSummary] = [:]) -> ActivityFacts {
    var facts = ActivityFacts(summaries: summaries)
    facts.hidesSecrets = hidesSecrets
    return facts
}

private func step(_ entry: TranscriptEntry, hidesSecrets: Bool, awaiting: String? = nil) throws -> ActivityStep {
    try #require(ActivitySteps.step(tool: entry, awaitingToolID: awaiting, facts: facts(hidesSecrets: hidesSecrets)))
}

@Suite struct PrettySecretTitleTests {
    @Test func aFailedUnknownToolHidesItsTitleInTheLineItsHelpAndItsSpokenLabel() throws {
        var wire = Wire()
        wire.call(findTitle, error: "Tool failed.")
        let entry = wire.entries[0]

        let hidden = try step(entry, hidesSecrets: true)
        #expect(hidden.state == .failed)
        #expect(hidden.sentence.plain == "Find token=" + hiddenValue + " failed")
        #expect(hidden.help == "Find token=" + hiddenValue)
        #expect(!hidden.accessibilityLabel.contains(fixtureValue))

        // With the setting off, the title reads as sent.
        let shown = try step(entry, hidesSecrets: false)
        #expect(shown.sentence.plain == findTitle + " failed")
        #expect(shown.help == findTitle)
    }

    @Test func aRunningAndAFinishedUnknownToolHideTheirTitle() throws {
        var wire = Wire()
        wire.call(readTitle)
        wire.call(readTitle, result: "ok")
        let entries = wire.entries

        let running = try step(entries[0], hidesSecrets: true)
        #expect(running.sentence.plain == "Using Materialize password=" + hiddenValue)
        let done = try step(entries[1], hidesSecrets: true)
        #expect(done.sentence.plain == "Used Materialize password=" + hiddenValue)
        #expect(done.help == "Materialize password=" + hiddenValue)
        #expect(!done.accessibilityLabel.contains(fixtureValue))

        #expect(try step(entries[0], hidesSecrets: false).sentence.plain == "Using " + readTitle)
        #expect(try step(entries[1], hidesSecrets: false).sentence.plain == "Used " + readTitle)
    }

    @Test func aHeldUnknownToolHidesItsTitleInTheApprovalLine() throws {
        var wire = Wire()
        wire.call(findTitle)
        let entry = wire.entries[0]
        #expect(try step(entry, hidesSecrets: true, awaiting: entry.id).sentence.plain
                == "Needs your approval to use Find token=" + hiddenValue)
        #expect(try step(entry, hidesSecrets: false, awaiting: entry.id).sentence.plain
                == "Needs your approval to use " + findTitle)
    }

    @Test func theFailureRendererHidesTriedAndSourceHidesTheNameWhileTheRecordStaysAsSent() throws {
        var wire = Wire()
        wire.call(findTitle, error: "Tool failed.")
        let entry = wire.entries[0]
        let source = ActivityResultSource(entry: entry, step: try step(entry, hidesSecrets: true), record: nil)

        #expect(source.failure != nil)
        #expect(source.tried(hidesSecrets: true) == "Use Find token=" + hiddenValue)
        #expect(source.tried(hidesSecrets: false) == "Use " + findTitle)
        // Source counts the name with its texts, so one Reveal shows it. The value is unchanged.
        #expect(source.shownName(hidesSecrets: true).text == "Find token=" + hiddenValue)
        #expect(source.shownName(hidesSecrets: true).hidden == 1)
        #expect(source.shownName(hidesSecrets: false).text == findTitle && source.shownName(hidesSecrets: false).hidden == 0)
        #expect(source.name == findTitle && source.tried == "Use " + findTitle)
    }

    @Test func eachOpenedCallReadsItsOwnTitle() throws {
        var wire = Wire()
        wire.call(findTitle, error: "Tool failed.")
        wire.call(readTitle, error: "Tool failed.")
        let entries = wire.entries.filter { if case .tool = $0.kind { true } else { false } }
        #expect(entries.count == 2)
        let sources = try entries.map { ActivityResultSource(entry: $0, step: try step($0, hidesSecrets: true), record: nil) }
        #expect(sources.map { $0.tried(hidesSecrets: true) }
                == ["Use Find token=" + hiddenValue, "Use Materialize password=" + hiddenValue])
        #expect(sources.map(\.toolID) == entries.map(\.detailKey))
    }

    @Test func aResultNamedByTheRecordUnderItsExactToolIDHidesThatTitleOnly() throws {
        var wire = Wire()
        wire.messages.append(AGUIMessage(id: "m-1", role: "tool", content: "", toolCallID: "w-1:toolu_find", error: "Tool failed."))
        let entry = wire.entries[0]
        let stored = ToolDetailSummary(key: "toolu_find", kind: "tool", name: findTitle)

        let named = facts(hidesSecrets: true, summaries: ["w-1:toolu_find": stored])
        let line = try #require(ActivitySteps.step(orphan: entry, facts: named))
        #expect(line.sentence.plain == "Find token=" + hiddenValue + " failed")
        #expect(line.help == "Find token=" + hiddenValue && !line.accessibilityLabel.contains(fixtureValue))
        let source = ActivityResultSource(entry: entry, step: line, record: nil, summary: named.summary("w-1:toolu_find"))
        #expect(source.tried(hidesSecrets: true) == "Use Find token=" + hiddenValue)
        #expect(source.tried(hidesSecrets: false) == "Use " + findTitle)

        // A record under another ID names nothing, hidden or not.
        let other = facts(hidesSecrets: true, summaries: ["w-1:toolu_other": stored])
        let unnamed = try #require(ActivitySteps.step(orphan: entry, facts: other))
        #expect(unnamed.kind == .orphanResult)
        let orphan = ActivityResultSource(entry: entry, step: unnamed, record: nil, summary: other.summary(entry.detailKey))
        #expect(orphan.name.isEmpty)
        #expect(orphan.tried(hidesSecrets: true) == "A call that was not recorded")
        #expect(orphan.tried(hidesSecrets: false) == "A call that was not recorded")
    }

    @Test func theValueIsHiddenBeforeTheNameIsCut() throws {
        // `bareName` keeps what follows the last "__": cut first, the tail of the value would show.
        var wire = Wire()
        wire.call("Find token=ab__cd", error: "Tool failed.")
        let entry = wire.entries[0]
        let hidden = try step(entry, hidesSecrets: true)
        #expect(hidden.sentence.plain == "Find token=Hidden, 6 characters failed")
        let source = ActivityResultSource(entry: entry, step: hidden, record: nil)
        #expect(source.tried(hidesSecrets: true) == "Use Find token=Hidden, 6 characters")
    }

    @Test func aNameWithNoSecretAndAKnownToolReadTheSameEitherWay() throws {
        var wire = Wire()
        wire.call("mcp__github__list_issues", error: "Tool failed.")
        wire.call("Read", detail: #"{"file_path":"/work/Sources/Retry.swift"}"#, error: "Tool failed.")
        wire.call("commander_status", error: "Tool failed.")
        let entries = wire.entries.filter { if case .tool = $0.kind { true } else { false } }

        for hides in [false, true] {
            let unknown = try step(entries[0], hidesSecrets: hides)
            #expect(unknown.sentence.plain == "list_issues failed" && unknown.help == "mcp__github__list_issues")
            #expect(unknown.phrase?.key == "other")
            let read = try step(entries[1], hidesSecrets: hides)
            #expect(read.sentence.plain == "Couldn't read Retry.swift" && read.help == "/work/Sources/Retry.swift")
            #expect(read.phrase?.key == "read")

            #expect(ActivityResultSource(entry: entries[0], step: unknown, record: nil).tried(hidesSecrets: hides) == "Use list_issues")
            #expect(ActivityResultSource(entry: entries[1], step: read, record: nil).tried(hidesSecrets: hides)
                    == "Read file: /work/Sources/Retry.swift")
            let status = ActivityResultSource(entry: entries[2], step: read, record: nil)
            #expect(status.tried(hidesSecrets: hides) == status.tried && !status.tried.isEmpty)
        }
    }
}
