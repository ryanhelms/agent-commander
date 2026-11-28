import Foundation
import Testing
@testable import AgentCommander

// A failed call's output can hold a secret-looking value. Under the hide-secrets setting the
// failure line, what VoiceOver reads, and the opened Reason, Exact text and rest hide it; the
// outcome and the fixed words are still told from the message as sent, and the result keeps
// that message (DESIGN.md, "Hidden secrets"). The values below are fabricated; none is a real
// credential.

private let fixtureValue = "synthetic-bearer-value"
private let hiddenValue = "Hidden, 22 characters"

/// One stored summary, decoded from the service's wire form.
private func summary(_ key: String, kind: String, title: String) throws -> ToolDetailSummary {
    let members: [String: Any] = ["kind": "tool", "key": key, "tool_kind": kind, "title": title]
    let page = try JSONSerialization.data(withJSONObject: ["revision": 1, "records": [members]])
    return try #require(try JSONDecoder().decode(ToolDetailPage.self, from: page).records.first)
}

private func entry(_ id: String, name: String, detail: String? = nil, output: String, error: String? = "Tool failed.") -> TranscriptEntry {
    TranscriptEntry(id: id, kind: .tool(name: name, detail: detail, result: ToolResult(output: output, error: error)))
}

private func facts(_ summaries: [ToolDetailSummary] = [], hidesSecrets: Bool) -> ActivityFacts {
    var facts = ActivityFacts(summaries: Dictionary(uniqueKeysWithValues: summaries.map { ($0.key, $0) }))
    facts.hidesSecrets = hidesSecrets
    return facts
}

private func step(_ entry: TranscriptEntry, _ summaries: [ToolDetailSummary] = [], hidesSecrets: Bool) throws -> ActivityStep {
    try #require(ActivitySteps.step(tool: entry, awaitingToolID: nil, facts: facts(summaries, hidesSecrets: hidesSecrets)))
}

private func result(_ entry: TranscriptEntry) throws -> ToolResult {
    guard case .tool(_, _, let result) = entry.kind else { throw CancellationError() }
    return try #require(result)
}

@Suite struct PrettySecretFailureTests {
    // The mock ACP peer's failed search as the service stores it: a clean title, the kind
    // `search`, and the value only in the failed output.
    private static let searchOutput = "Tool failed.\nUpstream refused Authorization: Bearer " + fixtureValue
        + " for marker. Retry after the limit resets."

    @Test func aFailedSearchHidesTheValueInItsLineItsSpokenLabelAndTheOpenedReason() throws {
        let stored = [try summary("ac-search", kind: "search", title: "Find marker")]
        let call = entry("ac-search", name: "Find marker", detail: "search", output: Self.searchOutput)

        let hidden = try step(call, stored, hidesSecrets: true)
        let failure = try #require(hidden.failure)
        // #179's wording and the tag stay as they were.
        #expect(hidden.state == .failed && hidden.sentence.plain == "Couldn't search Find marker")
        #expect(hidden.tag == .failed && failure.outcome == .failed)
        // The whole message is masked, then its first sentence is cut.
        #expect(failure.reason == "Upstream refused Authorization: Bearer " + hiddenValue + " for marker.")
        #expect(failure.exact == failure.reason)
        #expect(failure.rest == "Retry after the limit resets.")
        #expect(hidden.failureLabel == "Couldn't search Find marker, failed, " + failure.reason)
        #expect(!hidden.failureLabel.contains(fixtureValue) && !hidden.accessibilityLabel.contains(fixtureValue))

        // The opened line draws the step's failure. The result keeps the output as sent.
        let source = ActivityResultSource(entry: call, step: hidden, record: nil, summary: stored[0], hidesSecrets: true)
        #expect(source.failure == failure)
        #expect(source.resultText == Self.searchOutput)
        #expect(try result(call).output == Self.searchOutput)
    }

    @Test func withTheSettingOffTheFailureReadsAsSent() throws {
        let stored = [try summary("ac-search", kind: "search", title: "Find marker")]
        let call = entry("ac-search", name: "Find marker", detail: "search", output: Self.searchOutput)

        let shown = try step(call, stored, hidesSecrets: false)
        let failure = try #require(shown.failure)
        #expect(failure.reason == "Upstream refused Authorization: Bearer " + fixtureValue + " for marker.")
        #expect(failure.exact == failure.reason && failure.rest == "Retry after the limit resets.")
        #expect(shown.failureLabel == "Couldn't search Find marker, failed, " + failure.reason)
        #expect(ActivityResultSource(entry: call, step: shown, record: nil, summary: stored[0]).failure == failure)
        // The parameter's default is the setting off.
        #expect(ActivityFailureWords.read(try result(call), status: .failed) == failure)
    }

    @Test func theValueIsHiddenBeforeTheFirstSentenceIsCut() throws {
        // The value holds ". ": cut first, its tail would be left in the rest, unhidden.
        let value = "sk-synthetic. tail-of-the-value"
        let call = entry("c", name: "deploy", output: "Tool failed.\nRejected API_TOKEN=\"sk-synthetic.\" by policy. Bearer " + fixtureValue)
        let hidden = try #require(try step(call, hidesSecrets: true).failure)
        #expect(!hidden.reason.contains("sk-synthetic") && !(hidden.rest ?? "").contains(fixtureValue))
        #expect(hidden.rest == "Bearer " + hiddenValue)

        // A value under a secret-looking key in the error text itself.
        let keyed = entry("k", name: "deploy", output: "", error: "password=" + value.prefix(12) + " was refused. See the log.")
        let failure = try #require(try step(keyed, hidesSecrets: true).failure)
        #expect(failure.reason == "password=Hidden, 12 characters was refused.")
        #expect(failure.rest == "See the log.")
    }

    @Test func aRecognisedDenialKeepsItsOutcomeAndFixedWordsAndHidesTheExactTextAndTheRest() throws {
        let output = "Tool failed.\nPreToolUse:Bash hook error: [check token=" + fixtureValue + "]: denied. "
            + "Later output: Authorization: Bearer " + fixtureValue
        let call = entry("c", name: "Bash", detail: #"{"command":"make deploy"}"#, output: output)

        let shown = try #require(try step(call, hidesSecrets: false).failure)
        let hidden = try #require(try step(call, hidesSecrets: true).failure)
        for failure in [shown, hidden] {
            #expect(failure.outcome == .blocked && failure.tag == .blocked)
            #expect(failure.reason == "A hook blocked this.")
        }
        #expect(shown.exact == "PreToolUse:Bash hook error: [check token=" + fixtureValue + "]: denied.")
        #expect(shown.rest == "Later output: Authorization: Bearer " + fixtureValue)
        #expect(hidden.exact == "PreToolUse:Bash hook error: [check token=" + hiddenValue + "]: denied.")
        #expect(hidden.rest == "Later output: Authorization: Bearer " + hiddenValue)

        // The line and its spoken label hold the fixed words only.
        let line = try step(call, hidesSecrets: true)
        #expect(line.tag == .blocked)
        #expect(line.failureLabel == line.sentence.plain + ", blocked, A hook blocked this.")
        #expect(try result(call).output == output)
    }

    @Test func theOutcomeIsToldFromTheMessageAsSentWhenTheMaskTakesAPhraseAway() throws {
        // Each recognised phrase sits where the mask replaces part of it.
        let cases: [(output: String, outcome: ActivityFailure.Outcome, words: String)] = [
            ("Authorization: Bearer PreToolUse:Bash hook error: [denied]", .blocked, "A hook blocked this."),
            ("Permission to use token=" + fixtureValue + " has been denied.", .blocked, "Permission to use this tool was denied."),
            ("token=Permission for this command was denied by a built-in Claude Code safety check", .blocked,
             "A Claude Code safety check denied this."),
            ("api_key=[Tool call interrupted: the session ended before this call's result was recorded]", .interrupted, "Interrupted."),
            ("secret=developer holds worker input", .blocked, "Someone holds input for this worker."),
        ]
        for item in cases {
            let call = entry("c", name: "deploy", output: "Tool failed.\n" + item.output)
            let shown = try #require(try step(call, hidesSecrets: false).failure)
            let hidden = try #require(try step(call, hidesSecrets: true).failure)
            #expect(shown.outcome == item.outcome && shown.reason == item.words)
            #expect(hidden.outcome == item.outcome && hidden.reason == item.words && hidden.tag == shown.tag)
            // The exact text is the masked one: part of the phrase is gone from it.
            #expect(hidden.exact != shown.exact && hidden.exact.contains("Hidden, "), "\(hidden.exact)")
        }

        // A shell timeout is matched on the whole result as sent.
        let timeout = entry("t", name: "Bash", output: "Exit code 143\nCommand timed out after 2m 0s\nBearer " + fixtureValue,
                            error: "Tool failed.")
        let failure = try #require(try step(timeout, hidesSecrets: true).failure)
        #expect(failure.outcome == .failed && failure.reason == ActivityFailureWords.timedOut)
        #expect(failure.exact == "Exit code 143" && failure.rest?.hasSuffix("Bearer " + hiddenValue) == true)
    }

    @Test func aDeclinedOrCancelledCallHidesItsExactText() throws {
        let declined = ToolResult(output: "Tool declined.\nRefused Bearer " + fixtureValue + ".", error: "Tool declined.")
        let hidden = ActivityFailureWords.read(declined, status: .declined, hidesSecrets: true)
        #expect(hidden.outcome == .blocked && hidden.reason == "You denied this.")
        #expect(hidden.exact == "Refused Bearer " + hiddenValue + ".")
        let shown = ActivityFailureWords.read(declined, status: .declined, hidesSecrets: false)
        #expect(shown.reason == "You denied this." && shown.exact == "Refused Bearer " + fixtureValue + ".")
        let cancelled = ActivityFailureWords.read(declined, status: .cancelled, hidesSecrets: true)
        #expect(cancelled.reason == "The request was cancelled." && cancelled.exact == hidden.exact)
    }

    @Test func aFailingCallInsideAGroupReadsItsOwnFailureHidden() throws {
        // The opened line draws each call. Only the last takes the step's failure; an earlier
        // failing call reads its own result.
        let first = entry("a", name: "deploy", output: "Tool failed.\nFirst refused Bearer " + fixtureValue + ".")
        let last = entry("b", name: "deploy", output: "Tool failed.\nSecond refused.")
        var line = try step(last, hidesSecrets: true)
        line.entries = [first, last]

        let hidden = ActivityResultSource(entry: first, step: line, record: nil, hidesSecrets: true)
        #expect(hidden.failure?.reason == "First refused Bearer " + hiddenValue + ".")
        #expect(hidden.failure?.exact == hidden.failure?.reason)
        let shown = ActivityResultSource(entry: first, step: line, record: nil, hidesSecrets: false)
        #expect(shown.failure?.reason == "First refused Bearer " + fixtureValue + ".")
        #expect(ActivityResultSource(entry: last, step: line, record: nil, hidesSecrets: true).failure == line.failure)
        #expect(hidden.resultText == "Tool failed.\nFirst refused Bearer " + fixtureValue + ".")
    }

    @Test func aFailedCommanderWorkflowHidesItsLatestFailure() throws {
        var wire = Wire()
        wire.call("commander_status", error: "Tool failed.\nStatus refused Bearer " + fixtureValue + ". Try again.")
        // Through the conversation, as the console builds it: the failed line under its group.
        func line(hidesSecrets: Bool) throws -> ActivityStep {
            let items = ActivityConversation.items(ConversationActivity.items(wire.entries), facts: facts(hidesSecrets: hidesSecrets))
            let failures = items.flatMap { item -> [ActivityStep] in
                if case .group(let group) = item { group.failures } else { [] }
            }
            return try #require(failures.first)
        }

        let hidden = try line(hidesSecrets: true)
        #expect(hidden.workflow != nil)
        #expect(hidden.state == .failed && hidden.failure?.reason == "Status refused Bearer " + hiddenValue + ".")
        #expect(hidden.failure?.rest == "Try again." && !hidden.failureLabel.contains(fixtureValue))
        let shown = try line(hidesSecrets: false)
        #expect(shown.failure?.reason == "Status refused Bearer " + fixtureValue + ".")
        #expect(shown.sentence == hidden.sentence && shown.tag == hidden.tag)
    }

    @Test func aResultWithNoRecordedCallHidesItsFailure() throws {
        var wire = Wire()
        wire.messages.append(AGUIMessage(id: "m-1", role: "tool", content: "Refused Bearer " + fixtureValue + ".",
                                         toolCallID: "w-1:toolu_gone", error: "Tool failed."))
        let orphan = wire.entries[0]
        let hidden = try #require(ActivitySteps.step(orphan: orphan, facts: facts(hidesSecrets: true)))
        #expect(hidden.kind == .orphanResult && hidden.failure?.reason == "Refused Bearer " + hiddenValue + ".")
        let shown = try #require(ActivitySteps.step(orphan: orphan, facts: facts(hidesSecrets: false)))
        #expect(shown.failure?.reason == "Refused Bearer " + fixtureValue + ".")
    }

    @Test func aWrapperErrorIsHiddenWholeAndKeepsItsFallbacks() {
        let error = "The network refused Bearer " + fixtureValue + ". It said so twice."
        let hidden = ActivityFailureWords.wrapper(error, hidesSecrets: true)
        #expect(hidden.outcome == .failed)
        #expect(hidden.reason == "The network refused Bearer " + hiddenValue + ". It said so twice.")
        #expect(hidden.exact == hidden.reason && hidden.rest == nil)
        // As sent with the setting off: the whole error, never cut.
        let shown = ActivityFailureWords.wrapper(error, hidesSecrets: false)
        #expect(shown.reason == error && shown.exact == error && shown.rest == nil)
        // No error: the fixed sentence, either way.
        for hides in [false, true] {
            let none = ActivityFailureWords.wrapper(nil, hidesSecrets: hides)
            #expect(none.reason == ActivityFailureWords.noReason && none.exact == ActivityFailureWords.noReason)
        }
        // The wrapper's own sentence for a failure it does not explain holds no value.
        let payload = ResultPayload.read(#"{"ok":false,"data":{}}"#, cut: .unrecorded)
        #expect(ActivityFailureWords.wrapper(payload.wrapperError, hidesSecrets: true).reason == "The network reported a failure.")
    }

    @Test func aFailureThatIsWholeJSONHidesTheValueUnderItsKey() throws {
        // Whole JSON is masked by key and value, as Source masks it, so no text holds the value.
        let output = "Tool failed.\n" + #"{"message":"Upstream said no. Twice.","authorization":"Bearer "# + fixtureValue + #""}"#
        let call = entry("j", name: "deploy", output: output)
        let hidden = try #require(try step(call, hidesSecrets: true).failure)
        #expect(hidden.outcome == .failed)
        // Sent as one line, it stays one line: the reason is the diagnostic, not a bare brace.
        #expect(hidden.reason == #"{"message": "Upstream said no."#)
        #expect(hidden.exact == hidden.reason)
        #expect(hidden.rest == #"Twice.","authorization": "Hidden, 29 characters"}"#)
        let shown = try #require(try step(call, hidesSecrets: false).failure)
        #expect(shown.reason == #"{"message":"Upstream said no."#)
        #expect(shown.rest == #"Twice.","authorization":"Bearer "# + fixtureValue + #""}"#)
        #expect(try result(call).output == output)

        // A one-line array of objects, and a recognised phrase inside the JSON.
        let list = entry("l", name: "deploy", output: #"[{"error":"Refused. Again."},{"token":""# + fixtureValue + #""}]"#)
        let listed = try #require(try step(list, hidesSecrets: true).failure)
        #expect(listed.reason == #"[{"error": "Refused."#)
        #expect(listed.rest == #"Again."},{"token": ""# + hiddenValue + #""}]"#)
        let held = entry("h", name: "deploy", output: #"{"error":"developer holds worker input","cookie":""# + fixtureValue + #""}"#)
        let blocked = try #require(try step(held, hidesSecrets: true).failure)
        #expect(blocked.outcome == .blocked && blocked.reason == "Someone holds input for this worker.")
        #expect(blocked.exact == #"{"error": "developer holds worker input","cookie": ""# + hiddenValue + #""}"# && blocked.rest == nil)

        // JSON with nothing to hide reads as sent, and JSON sent on several lines keeps its lines.
        let clean = entry("c", name: "deploy", output: #"{"message":"Upstream said no. Twice."}"#)
        #expect(try step(clean, hidesSecrets: true) == (try step(clean, hidesSecrets: false)))
        let lines = entry("m", name: "deploy", output: "{\n  \"message\": \"No.\",\n  \"token\": \"" + fixtureValue + "\"\n}")
        let multi = try #require(try step(lines, hidesSecrets: true).failure)
        #expect(multi.reason == "{" && multi.rest == "\"message\": \"No.\",\n  \"token\": \"" + hiddenValue + "\"\n}")
        #expect(try step(lines, hidesSecrets: false).failure?.reason == "{")
    }

    @Test func aValueOnTheLineAfterBearerIsHiddenAcrossTheCut() throws {
        // The first sentence ends at the line break, between "Bearer" and its value. The value
        // has no secret form of its own: masked after the cut, it would stay in the rest.
        let output = "Tool failed.\nUpstream refused Authorization: Bearer\n" + fixtureValue + " was sent. Retry later."
        let call = entry("b", name: "deploy", output: output)
        #expect(SecretValues.masked(prose: fixtureValue + " was sent. Retry later.").count == 0)

        let hidden = try #require(try step(call, hidesSecrets: true).failure)
        #expect(hidden.reason == "Upstream refused Authorization: Bearer")
        #expect(hidden.rest == hiddenValue + " was sent. Retry later.")
        let shown = try #require(try step(call, hidesSecrets: false).failure)
        #expect(shown.reason == hidden.reason && shown.rest == fixtureValue + " was sent. Retry later.")
        #expect(try result(call).output == output)
    }

    @Test func aFailureWithNoValueAndOneWithNoReasonReadTheSameEitherWay() throws {
        let plain = entry("p", name: "Find marker", output: "Tool failed.\nProvider result ac-search. Second sentence.")
        let bare = entry("n", name: "Find marker", output: "", error: "Tool failed.")
        let denied = entry("d", name: "Bash", output: "",
                           error: "Permission to use Bash has been denied because Claude Code is running in don't ask mode.")
        for call in [plain, bare, denied] {
            let shown = try step(call, hidesSecrets: false)
            let hidden = try step(call, hidesSecrets: true)
            #expect(shown == hidden)
        }
        #expect(try step(plain, hidesSecrets: true).failure?.reason == "Provider result ac-search.")
        let none = try #require(try step(bare, hidesSecrets: true).failure)
        #expect(none.reason == ActivityFailureWords.noReason && none.exact == ActivityFailureWords.noReason && none.rest == nil)
        #expect(try step(denied, hidesSecrets: true).failure?.reason == "Claude Code is in don't-ask mode.")
    }
}
