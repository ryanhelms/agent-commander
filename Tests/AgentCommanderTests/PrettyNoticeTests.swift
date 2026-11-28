import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// A provider notice in Pretty (DESIGN.md, "Pretty transcript"; spec section H, "ACP `notice`").
// The messages have the shape the service sends for a negotiated ACP session: one `system`
// message per notice with the text `[ACP notice] <title>`, and the provider's severity in
// `metadata.acp.noticeSeverity` only when it is exactly `info`, `warning` or `error`. The run is
// the one of issue 157: three notices between two replies.

private func message(_ json: String) throws -> AGUIMessage {
    try AGUIMessage(fields: AGUIValue(json: json))
}

/// The service's message for one notice. `severity` is written as given, quotes included, so a
/// test can send a value of any JSON type; nil leaves the field out, as an older record does.
private func notice(_ sequence: Int, _ title: String, severity: String? = nil, kind: String = "notice",
                    role: String = "system") throws -> AGUIMessage {
    var acp = #""source":"live","cursor":"c.\#(sequence)","turnId":"op-7","kind":"\#(kind)""#
    if let severity { acp += #","noticeSeverity":\#(severity)"# }
    let text = title.isEmpty ? "[ACP notice]" : "[ACP notice] " + title
    return try message(#"{"id":"w:\#(sequence)","role":"\#(role)","content":"\#(text)","metadata":{"acp":{\#(acp)}}}"#)
}

private func prose(_ sequence: Int, _ text: String, role: String = "assistant") throws -> AGUIMessage {
    try message(#"{"id":"w:\#(sequence)","role":"\#(role)","content":"\#(text)"}"#)
}

private func usage(_ sequence: Int) throws -> AGUIMessage {
    try message(#"{"id":"w:\#(sequence)","role":"system","content":"[ACP usage_update]","metadata":{"acp":{"source":"live","cursor":"c.\#(sequence)","kind":"usage_update","usage":{"used":13600,"size":200000}}}}"#)
}

private func entries(_ messages: [AGUIMessage]) -> [TranscriptEntry] {
    TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: .pretty)
}

private func pretty(_ messages: [AGUIMessage]) -> [PrettyItem] {
    ActivityConversation.items(ConversationActivity.items(entries(messages)))
}

/// The conversation as a console builds it under the transcript setting.
private func pretty(_ messages: [AGUIMessage], hidesSecrets: Bool) -> [PrettyItem] {
    var facts = ActivityFacts.none
    facts.hidesSecrets = hidesSecrets
    return ActivityConversation.items(ConversationActivity.items(entries(messages)), facts: facts)
}

/// The event of the one notice a conversation holds at `id`.
private func event(_ messages: [AGUIMessage], id: String = "w:3") throws -> ActivityEvent {
    let entry = try #require(entries(messages).first { $0.id == id })
    return try #require(ActivityEvent(entry: entry))
}

/// The run of issue 157, as the service projects the negotiated fixture's console.
private func run() throws -> [AGUIMessage] {
    [
        try prose(1, "ACP activity fixture; execute nothing", role: "user"),
        try prose(2, "BEFORE_NOTICE_QA"),
        try notice(3, "QUIET_TITLE_QA", severity: #""info""#),
        try notice(4, "WARNING_TITLE_QA", severity: #""warning""#),
        try notice(5, "ERROR_TITLE_QA", severity: #""error""#),
        try prose(6, "AFTER_NOTICE_QA"),
        try message(#"{"id":"w:7","role":"system","content":"[Provider event: Turn ended]","metadata":{"acp":{"source":"live","cursor":"c.7","turnId":"op-7","kind":"acp.prompt_result"}}}"#)
    ]
}

@MainActor @Suite struct PrettyNoticeTests {
    @Test func aWarningAndAnErrorStayOpenAtTheirOwnPositionsAndInfoFolds() throws {
        let items = pretty(try run())

        // The info notice is a line of its own group; the warning and the error are entries.
        #expect(items.map(\.id) == ["w:1", "w:2", "w:3#group", "w:4", "w:5", "w:6", "w:7#group"])
        guard case .entry(let before) = items[1], case .group(let quiet) = items[2], case .entry(let warning) = items[3],
              case .entry(let error) = items[4], case .entry(let after) = items[5] else {
            Issue.record("expected reply, group, warning, error, reply"); return
        }
        #expect(before.kind == .prose("BEFORE_NOTICE_QA", fromUser: false))
        #expect(after.kind == .prose("AFTER_NOTICE_QA", fromUser: false))
        #expect(quiet.lines.map(\.id) == ["w:3"] && quiet.failures.isEmpty)
        #expect(quiet.lines[0].sentence.plain == "Notice QUIET_TITLE_QA")
        #expect(quiet.lines[0].kind == .quiet && !quiet.lines[0].opens)

        let warned = try #require(ActivityEvent(entry: warning)), failed = try #require(ActivityEvent(entry: error))
        #expect(warned == ActivityEvent(symbol: "exclamationmark.triangle", label: "Warning", detail: "WARNING_TITLE_QA",
                                        tone: .attention))
        #expect(failed == ActivityEvent(symbol: "exclamationmark.octagon", label: "Error", detail: "ERROR_TITLE_QA",
                                        tone: .attention))
        #expect(!warned.folds && !failed.folds)
        // VoiceOver names the level the provider stated, then the title as sent.
        #expect(warned.accessibilityLabel == "Warning: WARNING_TITLE_QA")
        #expect(failed.accessibilityLabel == "Error: ERROR_TITLE_QA")
        // Every entry is shown exactly once, in the order it arrived.
        #expect(items.flatMap(\.entries).map(\.id) == (1...7).map { "w:\($0)" })
    }

    @Test func aWarningEndsTheGroupOfSessionUpdatesBesideIt() throws {
        let items = pretty([
            try prose(1, "Go on.", role: "user"),
            try usage(2),
            try notice(3, "Quiet", severity: #""info""#),
            try notice(4, "Rate limit close", severity: #""warning""#),
            try usage(5),
            try notice(6, "Provider failed", severity: #""error""#),
            try notice(7, "Still quiet", severity: #""info""#)
        ])
        #expect(items.map(\.id) == ["w:1", "w:2#group", "w:4", "w:5#group", "w:6", "w:7#group"])
        guard case .group(let first) = items[1], case .group(let second) = items[3] else {
            Issue.record("expected groups around the warning"); return
        }
        // The warning is in neither group and in neither count.
        #expect(first.lines.map(\.id) == ["w:2", "w:3"] && first.summary.text == "2 session updates")
        #expect(first.summary.accessibilityLabel == "Activity, 2 steps. 2 session updates")
        #expect(second.lines.map(\.id) == ["w:5"])
    }

    @Test func aNoticeWithNoSupportedLevelStaysVisibleAndNamesNoSeverity() throws {
        // An older record, and every value that is not exactly one of the three levels.
        let unstated: [String?] = [nil, #""""#, #""critical""#, #""Warning""#, #""ERROR""#, #"" error""#, "2", "true", "null",
                                   #"{"level":"error"}"#]
        for severity in unstated {
            let messages = [try prose(1, "Go on.", role: "user"), try usage(2),
                            try notice(3, "LEGACY_TITLE_QA", severity: severity), try usage(4)]
            let items = pretty(messages)
            // In the open, at its own position, between the two groups.
            #expect(items.map(\.id) == ["w:1", "w:2#group", "w:3", "w:4#group"], "severity \(severity ?? "absent")")
            let shown = try event(messages)
            #expect(shown == ActivityEvent(symbol: "bell", label: "Notice", detail: "LEGACY_TITLE_QA", tone: .quiet, folds: false))
            #expect(shown.tone != .attention)
            #expect(shown.accessibilityLabel == "Notice: LEGACY_TITLE_QA")
        }
    }

    @Test func aLevelIsNeverReadFromTheTitleOrFromAnotherRecord() throws {
        // A title that reads as an error is still what its reference says: info, or no level.
        let alarming = "ERROR: warning, the build failed https://example.com/error?severity=error"
        let quiet = [try prose(1, "Go on.", role: "user"), try usage(2), try notice(3, alarming, severity: #""info""#)]
        #expect(pretty(quiet).map(\.id) == ["w:1", "w:2#group"])
        #expect(try event(quiet).tone == .quiet)
        #expect(try event(quiet).label == "Notice")
        let legacy = try event([try prose(1, "Go on.", role: "user"), try usage(2), try notice(3, alarming)])
        #expect(legacy.label == "Notice" && legacy.tone == .quiet && !legacy.folds)
        #expect(legacy.detail == alarming)

        // A record of another kind is not a notice, whatever its text or a severity field says.
        for kind in ["session_info_update", "notice_update", "Notice", "acp.notice", ""] {
            let messages = [try prose(1, "Go on.", role: "user"), try usage(2),
                            try notice(3, "Error: disk failed", severity: #""error""#, kind: kind)]
            let entry = try #require(entries(messages).first { $0.id == "w:3" })
            #expect(entry.origin?.notice == nil, "kind \(kind)")
            let other = ActivityEvent(entry: entry)
            #expect(other?.tone != .attention && other?.label != "Error" && other?.label != "Warning", "kind \(kind)")
        }
        // The agent's or the developer's own message is prose, even with a notice reference.
        for role in ["assistant", "user"] {
            let said = try notice(3, "Error: disk failed", severity: #""error""#, role: role)
            let entry = try #require(TranscriptEntry.entries(from: [said]).first)
            #expect(entry.origin?.notice == nil)
            #expect(ActivityEvent(entry: entry) == nil)
        }
        // Text that looks like the service's marker, with no reference, is a role note.
        let bare = try prose(3, "[ACP notice] Error: disk failed", role: "system")
        let entry = try #require(TranscriptEntry.entries(from: [bare]).first)
        #expect(entry.origin == nil && ActivityEvent(entry: entry) == nil)
    }

    @Test func theTitleIsShownAsSent() throws {
        // A title that starts with the row's own label keeps it.
        for (title, severity) in [("Notice of a rate limit", #""info""#), ("Warning lights are on", #""warning""#),
                                  ("Error budget is spent", #""error""#), ("Notice · board", nil)] {
            let shown = try event([try prose(1, "Go on.", role: "user"), try prose(2, "Before."),
                                   try notice(3, title, severity: severity)])
            #expect(shown.detail == title)
        }
        // A notice with no title has no detail: its content is in its fields.
        let empty = try event([try prose(1, "Go on.", role: "user"), try prose(2, "Before."),
                               try notice(3, "", severity: #""warning""#)])
        #expect(empty.detail.isEmpty && empty.label == "Warning" && !empty.folds)
        #expect(empty.accessibilityLabel == "Warning: no text, content in its fields")
    }

    @Test func consoleAndTerminalKeepTheServicesRows() throws {
        let messages = try run()
        let built = TranscriptEntry.entries(from: messages)
        for mode in [ConsoleDisplayMode.console, .terminal] {
            let shown = TranscriptEntry.displayed(built, mode: mode)
            #expect(shown == built)
            #expect(shown.map(\.id) == (1...7).map { "w:\($0)" })
            #expect(shown[2].kind == .other(role: "system", text: "[ACP notice] QUIET_TITLE_QA"))
            #expect(shown[3].kind == .other(role: "system", text: "[ACP notice] WARNING_TITLE_QA"))
            #expect(shown[4].kind == .other(role: "system", text: "[ACP notice] ERROR_TITLE_QA"))
        }
        // Pretty changes no text either: the entries are the ones Console shows.
        #expect(entries(messages).map(\.kind) == built.map(\.kind))
    }

    @Test func eachNoticeKeepsItsOwnRecordBehindItsFieldsAction() throws {
        let messages = try run()
        for item in pretty(messages) {
            for entry in item.entries where entry.origin?.notice != nil {
                #expect(ConsoleRecordDetail.messageIDs(entryID: entry.id, in: messages) == [entry.id])
                #expect(entry.sourceIDs == [entry.id])
            }
        }
        let marks = entries(messages).compactMap { $0.origin?.notice?.level }
        #expect(marks == [.info, .warning, .error])
    }

    @Test func aNoticeBesideACompactionKeepsItsPlace() throws {
        let compaction = try message(#"{"id":"w:4","role":"system","content":"Provider context compaction completed","metadata":{"acp":{"source":"live","cursor":"c.4","turnId":"op-7","kind":"compaction_update","messageId":"\#(CompactionRecord.identity(of: "cmp-a"))","messageOp":"replace"}}}"#)
        let items = pretty([
            try prose(1, "Go on.", role: "user"),
            try prose(2, "Before."),
            try notice(3, "Context is almost full", severity: #""warning""#),
            compaction,
            try notice(5, "Compacted", severity: #""info""#),
            try prose(6, "After.")
        ])
        #expect(items.map(\.id) == ["w:1", "w:2", "w:3", "w:4#compaction", "w:5#group", "w:6"])
    }

    @Test func thePipKeepsTheWarningAndTheErrorOfTheNoticeTurn() throws {
        // The asking worker's current turn, as the PiP reads it.
        let shown = ActivityConversation.recent(pretty(try run()))
        #expect(shown.map(\.id) == ["w:4", "w:5", "w:6", "w:7#group"])
    }

    @Test func thePipKeepsEachOpenNoticeOfTheTurnBeforeItsLatestWorkGroup() throws {
        var wire = Wire()
        // An earlier turn, with a warning of its own.
        wire.user("Read the file")
        wire.messages.append(try notice(101, "EARLIER_TURN_WARNING", severity: #""warning""#))
        wire.call("Read", detail: "/a/first.txt", result: "x")
        // The current turn: notices, harness stderr and prose before the latest group of calls.
        wire.user("Go on")
        wire.say("Before.")
        wire.messages.append(try notice(102, "QUIET_TITLE_QA", severity: #""info""#))
        wire.messages.append(try notice(103, "WARNING_TITLE_QA", severity: #""warning""#))
        wire.messages.append(try prose(900, "[Provider stderr] boom", role: "system"))
        wire.messages.append(try notice(104, "LEGACY_TITLE_QA"))
        wire.call("Read", detail: "/a/second.txt", result: "x")
        wire.messages.append(try notice(105, "ERROR_TITLE_QA", severity: #""error""#))
        wire.call("Read", detail: "/a/third.txt", result: "x")
        wire.say("Done.")

        let full = pretty(wire.messages)
        let shown = ActivityConversation.recent(full)
        // The latest group that holds a call, and the reply after it, as before.
        let tail = Array(full.suffix(2))
        guard case .group(let latest) = tail[0], case .entry(let reply) = tail[1] else {
            Issue.record("expected the latest group, then the reply"); return
        }
        #expect(latest.lines.contains { $0.kind == .call })
        #expect(reply.kind == .prose("Done.", fromUser: false))
        // Before it: the warning, the notice with no level and the error, in the order they
        // arrived. The info notice stays folded in its group, which is left out; so are the
        // prose, harness stderr, the earlier group of calls and the earlier turn's warning.
        #expect(shown.map(\.id) == ["w:103", "w:104", "w:105"] + tail.map(\.id))
        #expect(shown.prefix(3).allSatisfy { if case .entry = $0 { true } else { false } })
        #expect(full.contains { $0.id == "w:101" } && full.contains { $0.id == "w:900" })
        // Each kept row is the item the focused worker draws, unchanged.
        #expect(shown.prefix(3).allSatisfy { full.contains($0) })
    }

    // MARK: Secrets

    @Test func aHiddenValueInANoticeTitleIsHiddenWhereverPrettyShowsOrSaysIt() throws {
        // An overtly synthetic value: the keyed and Bearer contexts around it are what is masked.
        let placeholder = "fixture-placeholder-for-masking"
        let keyed = "Refresh failed for token=\(placeholder) on the build host"
        let bearer = "Sent Authorization: Bearer \(placeholder) to the proxy"
        let messages = [
            try prose(1, "Go on.", role: "user"),
            try usage(2),
            try notice(3, bearer, severity: #""info""#),
            try notice(4, keyed, severity: #""warning""#),
            try notice(5, bearer, severity: #""error""#),
            try notice(6, keyed),
            try prose(7, "After.")
        ]
        let built = entries(messages)
        let ids = ["w:1", "w:2#group", "w:4", "w:5", "w:6", "w:7"]

        // With the setting off, every title is the provider's text.
        let open = pretty(messages, hidesSecrets: false)
        #expect(open.map(\.id) == ids)
        guard case .group(let plain) = open[1] else { Issue.record("expected the group"); return }
        #expect(plain.lines[1].sentence.plain == "Notice " + bearer)
        #expect(ActivityEvent(entry: built[3])?.detail == keyed)

        // With it on: the same items, in the same order, with the same levels.
        let hidden = pretty(messages, hidesSecrets: true)
        #expect(hidden.map(\.id) == ids)
        guard case .group(let group) = hidden[1] else { Issue.record("expected the group"); return }
        // The folded line: what is drawn and what VoiceOver reads hold no secret.
        let line = group.lines[1]
        #expect(line.id == "w:3" && line.kind == .quiet)
        #expect(!line.sentence.plain.contains(placeholder) && !line.accessibilityLabel.contains(placeholder))
        #expect(line.sentence.plain.hasPrefix("Notice Sent Authorization: Bearer "))
        #expect(line.sentence.plain.hasSuffix(" to the proxy"))
        // The rows in the open, as the console draws them.
        let expected: [(index: Int, label: String, tone: ActivityEvent.Tone, lead: String, trail: String)] = [
            (3, "Warning", .attention, "Refresh failed for token=", " on the build host"),
            (4, "Error", .attention, "Sent Authorization: Bearer ", " to the proxy"),
            (5, "Notice", .quiet, "Refresh failed for token=", " on the build host")
        ]
        for row in expected {
            let shown = try #require(ActivityEvent(entry: built[row.index], hidesSecrets: true))
            #expect(shown.label == row.label && shown.tone == row.tone && !shown.folds)
            #expect(!shown.detail.contains(placeholder) && !shown.accessibilityLabel.contains(placeholder))
            #expect(shown.detail.hasPrefix(row.lead) && shown.detail.hasSuffix(row.trail))
            #expect(shown.accessibilityLabel == row.label + ": " + shown.detail)
            // Only the title's text differs from the unmasked row.
            let unmasked = try #require(ActivityEvent(entry: built[row.index]))
            #expect(unmasked.symbol == shown.symbol && unmasked.label == shown.label && unmasked.folds == shown.folds)
            #expect(unmasked.detail.contains(placeholder))
        }

        // The record is untouched: the entries the items hold, Console and Terminal keep the
        // service's text, and each notice still reaches its own message.
        #expect(hidden.flatMap(\.entries).map(\.kind) == built.map(\.kind))
        #expect(built[3].kind == .other(role: "system", text: "[ACP notice] " + keyed))
        for mode in [ConsoleDisplayMode.console, .terminal] {
            let shown = TranscriptEntry.displayed(TranscriptEntry.entries(from: messages), mode: mode)
            #expect(shown[2].kind == .other(role: "system", text: "[ACP notice] " + bearer))
            #expect(shown[3].kind == .other(role: "system", text: "[ACP notice] " + keyed))
        }
        #expect(ConsoleRecordDetail.messageIDs(entryID: "w:4", in: messages) == ["w:4"])
        // The PiP keeps the same rows: what stays is chosen by level, not by the title.
        #expect(ActivityConversation.recent(hidden).map(\.id) == ActivityConversation.recent(open).map(\.id))
    }

    @Test func anOrdinaryTitleAndEveryOtherEventReadTheSameWithTheSettingOn() throws {
        let messages = try run() + [
            try prose(8, "[Provider stderr] token=fixture-placeholder-for-masking was refused", role: "system"),
            try usage(9)
        ]
        let built = entries(messages)
        // Ordinary notice titles are the provider's text, masked or not.
        for entry in built where entry.origin?.notice != nil {
            #expect(ActivityEvent(entry: entry, hidesSecrets: true) == ActivityEvent(entry: entry))
        }
        #expect(pretty(try run(), hidesSecrets: true) == pretty(try run()))
        // Harness stderr and a usage row are not notices: this change leaves them as they were.
        for id in ["w:8", "w:9"] {
            let entry = try #require(built.first { $0.id == id })
            #expect(entry.origin?.notice == nil)
            #expect(ActivityEvent(entry: entry, hidesSecrets: true) == ActivityEvent(entry: entry))
        }
        // The level alone says whether a notice folds.
        #expect(NoticeMark(level: .info).folds)
        #expect(!NoticeMark(level: .warning).folds && !NoticeMark(level: .error).folds && !NoticeMark(level: nil).folds)
    }

    @Test func aChildsFoldedNoticeIsMaskedInItsParentsBackgroundLine() throws {
        let placeholder = "fixture-placeholder-for-masking"
        let child = TranscriptEntry.entries(from: [
            try prose(1, "Go on.", role: "user"),
            try notice(2, "Using token=\(placeholder) from the cache", severity: #""info""#)
        ])
        #expect(BackgroundTurn(child).summary == "Notice Using token=\(placeholder) from the cache")
        let masked = try #require(BackgroundTurn(child, hidesSecrets: true).summary)
        #expect(!masked.contains(placeholder) && masked.hasPrefix("Notice Using token=") && masked.hasSuffix(" from the cache"))
    }

    @Test func theTitleFollowsTheStoresPolicyAndIsHiddenUntilTheSettingIsRead() async throws {
        let placeholder = "fixture-placeholder-for-masking"
        let entry = try #require(entries([try notice(1, "Rejected token=\(placeholder)", severity: #""warning""#)]).first)
        func shown(_ store: ToolDetailStore) -> String? {
            // The policy the console passes on, as the store answers it.
            ActivityEvent(entry: entry, hidesSecrets: store.hidesSecrets)?.detail
        }
        // Fixed values read their own setting.
        #expect(shown(ToolDetailStore(summaries: [:], settings: TranscriptSettings(hideSecrets: true)))?.contains(placeholder) == false)
        #expect(shown(ToolDetailStore(summaries: [:])) == "Rejected token=\(placeholder)")
        // A store that reads the service hides until the saved setting has answered.
        let store = ToolDetailStore(source: ToolDetailSource(
            page: { _, _ in ToolDetailPage(revision: 0, records: []) },
            record: { _, key in ToolDetailRecord(key: key, kind: "tool", input: "{}") },
            readSettings: { TranscriptSettings() },
            writeSettings: { $0 }))
        #expect(store.hidesSecrets && shown(store)?.contains(placeholder) == false)
        await store.loadSettings()
        #expect(!store.hidesSecrets && shown(store) == "Rejected token=\(placeholder)")
    }

    /// Headless pictures of the run on the three Pretty surfaces, for comparison with the
    /// approved section H. Skipped unless PRETTY_RENDER_DIR names a folder.
    @Test(.enabled(if: prettyRenderDirectory != nil)) func drawsTheNoticeRows() async throws {
        let folder = URL(fileURLWithPath: try #require(prettyRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var messages = try run()
        messages.insert(try notice(8, "LEGACY_TITLE_QA"), at: 5)
        let built = TranscriptEntry.entries(from: messages)
        for (density, name, size) in [(PrettyDensity.regular, "pretty-notice-focused", CGSize(width: 800, height: 420)),
                                      (.compact, "pretty-notice-wall-tile", CGSize(width: 440, height: 400)),
                                      (.pip, "pretty-notice-pip", CGSize(width: 350, height: 340))] {
            try await ShellRenderTests.write(PrettyRenderTests.console(built, density: density, coordinator: false, size: size),
                                             name, theme: .console, to: folder, size: size)
        }
    }
}
