import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// Identified ACP plans in Pretty (issue 162): one checklist card per provider plan, updated in
// place by the plan's identity, and the line "The plan was removed" in place of a removed plan.
// The events are the service's projection of the negotiated fixture turn: prose, plan alpha,
// plan beta, alpha again, alpha removed, prose. The message ID is `<worker>:<sequence>` and a
// plan record carries the sequence of the console event it was kept from.

private let alpha = String(repeating: "a1", count: 32)
private let beta = String(repeating: "b2", count: 32)
/// The same provider plan ID in another provider session: another fingerprint.
private let alphaElsewhere = String(repeating: "c3", count: 32)

/// Overtly synthetic values for the masking cases, built when the tests run. Neither is a
/// credential: the first only has the shape `SecretValues` hides on sight (the key prefix and
/// 24 more characters), and the second is hidden for the `Bearer` word before it.
private let syntheticKey = "sk" + "-" + String(repeating: "x", count: 24)
private let bearerPlaceholder = "fixture-placeholder-for-masking"

private func message(_ sequence: Int, role: String, _ text: String, acp: String? = nil, worker: String = "w") throws -> AGUIMessage {
    let metadata = acp.map { #","metadata":{"acp":\#($0)}"# } ?? ""
    return try JSONDecoder().decode(AGUIMessage.self, from: Data(
        #"{"id":"\#(worker):\#(sequence)","role":"\#(role)","content":"\#(text)"\#(metadata)}"#.utf8))
}

/// A plan event as the service projects a console `output` event: role `system`, the bracketed
/// text, and the reference's source. `source` is the JSON member as written, or nil for none.
private func update(_ sequence: Int, _ identity: String?, source: String? = #""live""#, worker: String = "w") throws -> AGUIMessage {
    let member = identity.map { #","planIdentity":"\#($0)""# } ?? ""
    let from = source.map { #""source":\#($0),"# } ?? ""
    return try message(sequence, role: "system", "[ACP plan_update]",
                       acp: #"{\#(from)"cursor":"c.\#(sequence)","turnId":"t-1","kind":"plan_update"\#(member)}"#, worker: worker)
}

private func removal(_ sequence: Int, _ identity: String?, source: String? = #""live""#, worker: String = "w") throws -> AGUIMessage {
    let member = identity.map { #","planIdentity":"\#($0)""# } ?? ""
    let from = source.map { #""source":\#($0),"# } ?? ""
    return try message(sequence, role: "system", "[ACP plan_removed]",
                       acp: #"{\#(from)"cursor":"c.\#(sequence)","turnId":"t-1","kind":"plan_removed"\#(member)}"#, worker: worker)
}

private func record(_ sequence: Int, _ items: [(String, String)]) -> ToolDetailSummary {
    ToolDetailSummary(key: "event-\(sequence)", kind: "plan", sequence: sequence,
                      plan: items.map { PlanItem(content: $0.0, status: $0.1) })
}

private func pretty(_ messages: [AGUIMessage], _ records: [ToolDetailSummary], worker: String? = "w") -> [PrettyItem] {
    let entries = TranscriptEntry.entries(from: messages)
    let facts = ActivityFacts(summaries: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }), worker: worker)
    return ActivityConversation.items(ConversationActivity.items(TranscriptEntry.displayed(entries, mode: .pretty)), facts: facts)
}

private func plans(_ items: [PrettyItem]) -> [ActivityPlan] {
    items.compactMap { if case .plan(let plan) = $0 { plan } else { nil } }
}

/// What each item is, in order: prose by its text, a plan by its contents or its line.
private func outline(_ items: [PrettyItem]) -> [String] {
    items.map { item in
        switch item {
        case .entry(let entry):
            if case .prose(let text, _) = entry.kind { return text }
            return "entry"
        case .plan(let plan):
            return plan.shown(hidesSecrets: false).map { "card:" + $0.map(\.content).joined(separator: ",") } ?? "line:" + plan.line
        case .group: return "group"
        default: return "other"
        }
    }
}

/// The negotiated turn without its removal: alpha, beta, alpha again, between prose.
private func interleaved() throws -> [AGUIMessage] {
    [try message(1, role: "user", "Plan it"), try message(2, role: "assistant", "BEFORE_PLAN_QA"),
     try update(3, alpha), try update(4, beta), try update(5, alpha)]
}

private let exactRecords = [record(3, [("ALPHA_INITIAL_QA", "pending")]), record(4, [("BETA_STAYS_QA", "pending")]),
                            record(5, [("ALPHA_LATEST_QA", "completed")])]

@Suite struct PrettyPlanIdentityTests {
    @Test func aLaterUpdateReplacesItsOwnPlansCardAndLeavesTheOtherPlan() throws {
        let events = try interleaved() + [try message(6, role: "assistant", "AFTER_PLAN_QA")]
        let items = pretty(events, exactRecords)
        // One card per plan, each where its first update arrived, between the prose.
        #expect(outline(items) == ["Plan it", "BEFORE_PLAN_QA", "card:ALPHA_LATEST_QA", "card:BETA_STAYS_QA", "AFTER_PLAN_QA"])
        let cards = plans(items)
        #expect(cards.map(\.id) == ["w:3#plan", "w:4#plan"])
        #expect(cards[0].entries.map(\.id) == ["w:3", "w:5"] && cards[0].items?.map(\.state) == [.done])
        #expect(cards[1].entries.map(\.id) == ["w:4"] && cards[1].items?.map(\.state) == [.pending])
        #expect(cards.allSatisfy { !$0.isRemoved })
    }

    @Test func aRemovalReplacesOnlyItsOwnPlanInPlace() throws {
        let events = try interleaved() + [try removal(6, alpha), try message(7, role: "assistant", "AFTER_PLAN_QA")]
        let items = pretty(events, exactRecords)
        #expect(outline(items) == ["Plan it", "BEFORE_PLAN_QA", "line:The plan was removed", "card:BETA_STAYS_QA", "AFTER_PLAN_QA"])
        let cards = plans(items)
        // The line keeps the card's place and ID, and holds every event of that plan.
        #expect(cards[0].id == "w:3#plan" && cards[0].isRemoved && cards[0].entries.map(\.id) == ["w:3", "w:5", "w:6"])
        #expect(cards[1].entries.map(\.id) == ["w:4"] && !cards[1].isRemoved)
        // A record at the removal's own sequence is not a checklist for it.
        let odd = plans(pretty(events, exactRecords + [record(6, [("STRAY", "pending")])]))
        #expect(odd[0].isRemoved && odd[0].shown(hidesSecrets: false) == nil && odd[0].line == "The plan was removed")
    }

    @Test func anUpdateWithoutItsOwnRecordNeverShowsEarlierItemsOrAnotherPlans() throws {
        let events = try interleaved()
        // The latest alpha event has no record: the fallback line, not the first list or beta's.
        let missing = plans(pretty(events, [exactRecords[0], exactRecords[1]]))
        #expect(missing[0].items == nil && missing[0].line == "Updated the plan")
        #expect(missing[1].items?.map(\.content) == ["BETA_STAYS_QA"])
        // Records kept from other events, as many as the plan events: none is read.
        let mismatched = plans(pretty(events, [record(7, [("X", "pending")]), record(8, [("Y", "pending")]), record(9, [("Z", "pending")])]))
        #expect(mismatched.count == 2 && mismatched.allSatisfy { $0.items == nil })
        // Two records claiming one event name neither; another kind at the sequence is no plan.
        let twin = ToolDetailSummary(key: "event-5b", kind: "plan", sequence: 5, plan: [PlanItem(content: "Twin", status: "pending")])
        #expect(plans(pretty(events, exactRecords + [twin]))[0].items == nil)
        let tool = ToolDetailSummary(key: "t", kind: "tool", sequence: 5, plan: [PlanItem(content: "x", status: "pending")])
        #expect(plans(pretty(events, [exactRecords[0], tool]))[0].items == nil)
        // Another console's sequences match nothing, and neither does an unknown console.
        #expect(plans(pretty(events, exactRecords, worker: "other")).allSatisfy { $0.items == nil })
        #expect(plans(pretty(events, exactRecords, worker: nil)).allSatisfy { $0.items == nil })
        // A markdown plan may carry the identity and a count, with no items: the count line.
        let counted = try message(3, role: "system", "[ACP plan_update]",
                                  acp: #"{"source":"live","kind":"plan_update","itemCount":2,"planIdentity":"\#(alpha)"}"#)
        #expect(plans(pretty([counted], []))[0].line == "Updated the plan: 2 items")
    }

    @Test func onlyALiveEventReadsARecordAtItsSequence() throws {
        // A reopened worker: the console is provider history numbered afresh, and the record at
        // sequence 3 was kept from an unrelated live event of the earlier console.
        let stale = [record(3, [("UNRELATED_LOCAL", "in_progress")]), record(4, [("ALSO_UNRELATED", "pending")])]
        let provider = #""provider""#
        let history = [try message(1, role: "user", "Plan it"), try message(2, role: "assistant", "BEFORE_PLAN_QA"),
                       try update(3, alpha, source: provider), try update(4, beta, source: provider),
                       try update(5, alpha, source: provider), try message(6, role: "assistant", "AFTER_PLAN_QA")]
        let items = pretty(history, stale)
        // Still one card per plan, by identity, each as its fallback line: no borrowed list.
        #expect(outline(items) == ["Plan it", "BEFORE_PLAN_QA", "line:Updated the plan", "line:Updated the plan", "AFTER_PLAN_QA"])
        let cards = plans(items)
        #expect(cards.map(\.identity) == [alpha, beta] && cards[0].entries.map(\.id) == ["w:3", "w:5"])
        #expect(cards.allSatisfy { $0.items == nil && $0.shown(hidesSecrets: false) == nil })
        // A history removal still replaces only its own plan's line, in place.
        let removed = pretty(Array(history.dropLast()) + [try removal(6, alpha, source: provider)], stale)
        #expect(outline(removed) == ["Plan it", "BEFORE_PLAN_QA", "line:The plan was removed", "line:Updated the plan"])
        // A missing, empty, unknown, differently cased or non-string source reads no record either.
        for source in [nil, #""""#, #""replay""#, #""Live""#, #""live ""#, "true", "1", "null", #"["live"]"#] as [String?] {
            let card = plans(pretty([try update(3, alpha, source: source)], stale))
            #expect(card.count == 1 && card[0].identity == alpha && card[0].items == nil && card[0].line == "Updated the plan")
        }
        // The same event observed live reads the record kept from it.
        #expect(plans(pretty([try update(3, alpha)], stale))[0].items?.map(\.content) == ["UNRELATED_LOCAL"])
        // A live update after history rows of the same plan updates that card with its own record.
        let mixed = plans(pretty([try update(3, alpha, source: provider), try update(7, alpha)], stale + [record(7, [("LIVE_NOW", "pending")])]))
        #expect(mixed.count == 1 && mixed[0].id == "w:3#plan" && mixed[0].items?.map(\.content) == ["LIVE_NOW"])
        // And a history update after a live one drops the live list: the fallback, never stale items.
        let back = plans(pretty([try update(3, alpha), try update(4, alpha, source: provider)], stale))
        #expect(back.count == 1 && back[0].items == nil)
        // An older `plan` event keeps its placement and its record whatever its source says.
        let legacy = try message(3, role: "system", "[ACP plan] 1 items", acp: #"{"source":"provider","kind":"plan","itemCount":1}"#)
        #expect(plans(pretty([legacy], stale))[0].items?.map(\.content) == ["UNRELATED_LOCAL"])
    }

    @Test func anEmptyChecklistIsNotAMissingOne() throws {
        let events = [try update(2, alpha)]
        let empty = plans(pretty(events, [record(2, [])]))
        #expect(empty[0].items == [] && empty[0].shown(hidesSecrets: true) == [])
        let absent = plans(pretty(events, [ToolDetailSummary(key: "event-2", kind: "plan", sequence: 2)]))
        #expect(absent[0].items == nil && absent[0].shown(hidesSecrets: false) == nil)
    }

    @Test func aRemovalWithNoCardIsItsOwnLineAndTouchesNoOtherPlan() throws {
        let events = [try message(1, role: "user", "Plan it"), try update(2, beta), try removal(3, alpha),
                      try removal(4, alpha), try message(5, role: "assistant", "Done"), try update(6, alpha)]
        let items = pretty(events, [record(2, [("BETA_STAYS_QA", "pending")]), record(6, [("ALPHA_AGAIN", "pending")])])
        // The repeated removal adds no second line; the update after it is a new card, where it arrived.
        #expect(outline(items) == ["Plan it", "card:BETA_STAYS_QA", "line:The plan was removed", "Done", "card:ALPHA_AGAIN"])
        let cards = plans(items)
        #expect(cards[1].entries.map(\.id) == ["w:3", "w:4"] && cards[2].id == "w:6#plan" && !cards[2].isRemoved)
    }

    @Test func anotherTurnOrProviderSessionIsAnotherCard() throws {
        let events = [try message(1, role: "user", "Plan it"), try update(2, alpha),
                      try message(3, role: "user", "Next part"), try update(4, alpha), try update(5, alphaElsewhere),
                      try message(6, role: "user", "Clean up"), try removal(7, alpha)]
        let records = [record(2, [("FIRST_TURN", "completed")]), record(4, [("SECOND_TURN", "pending")]),
                       record(5, [("OTHER_SESSION", "pending")])]
        let items = pretty(events, records)
        // A turn's card is history: a later turn's update or removal never reaches back into it.
        #expect(outline(items) == ["Plan it", "card:FIRST_TURN", "Next part", "card:SECOND_TURN", "card:OTHER_SESSION",
                                   "Clean up", "line:The plan was removed"])
        #expect(plans(items).map(\.id) == ["w:2#plan", "w:4#plan", "w:5#plan", "w:7#plan"])
    }

    @Test func onlyAStrictIdentityOnAPlanEventNamesAPlan() throws {
        func identity(_ kind: String, _ value: String) -> String? {
            TranscriptOrigin.planIdentity(kind: kind, acp: ["planIdentity": .string(value)])
        }
        #expect(identity("plan_update", alpha) == alpha && identity("plan_removed", alpha) == alpha)
        #expect(identity("plan", alpha) == nil && identity("usage_update", alpha) == nil)
        for bad in ["", String(alpha.dropLast()), alpha + "a", alpha.uppercased(), String(alpha.dropLast()) + "g",
                    String(alpha.dropLast()) + " ", String(repeating: "１", count: 64)] {
            #expect(identity("plan_update", bad) == nil)
        }
        #expect(TranscriptOrigin.planIdentity(kind: "plan_update", acp: ["planIdentity": .bool(true)]) == nil)
        #expect(TranscriptOrigin.planIdentity(kind: "plan_update", acp: [:]) == nil)
        // Without a usable identity the events fold as the session updates they were, and a
        // record at their sequence is not drawn.
        let unnamed = pretty([try update(2, nil), try update(3, alpha.uppercased()), try removal(4, nil)],
                             [record(2, [("NOT_SHOWN", "pending")])])
        #expect(plans(unnamed).isEmpty && outline(unnamed) == ["group"])
    }

    @Test func legacyPlansKeepTheirOneCardPerTurn() throws {
        func legacy(_ sequence: Int, count: Int) throws -> AGUIMessage {
            // An identity on the older event kind is ignored.
            try message(sequence, role: "system", "[ACP plan] \(count) items",
                        acp: #"{"source":"live","kind":"plan","itemCount":\#(count),"planIdentity":"\#(alpha)"}"#)
        }
        let events = [try message(1, role: "user", "Plan it"), try legacy(2, count: 1), try update(3, alpha),
                      try legacy(4, count: 2), try removal(5, alpha)]
        let cards = plans(pretty(events, [record(2, [("OLD", "pending")]), record(3, [("NEW", "pending")]),
                                          record(4, [("OLD", "completed"), ("OLDER", "pending")])]))
        #expect(cards.map(\.id) == ["w:2#plan", "w:3#plan"])
        #expect(cards[0].identity == nil && cards[0].entries.map(\.id) == ["w:2", "w:4"] && cards[0].items?.count == 2 && !cards[0].isRemoved)
        #expect(cards[1].identity == alpha && cards[1].isRemoved)
        // A TodoWrite list is untouched by the setting; an identified plan is masked.
        var wire = Wire()
        wire.call("TodoWrite", detail: #"{"todos":[{"content":"Use \#(syntheticKey)","status":"pending"}]}"#, result: "ok")
        let todo = plans(ActivityConversation.items(ConversationActivity.items(TranscriptEntry.displayed(wire.entries, mode: .pretty))))
        #expect(SecretValues.valueLooksSecret(syntheticKey))
        #expect(todo[0].shown(hidesSecrets: true)?.map(\.content) == ["Use " + syntheticKey])
    }

    @Test func aPlansWordsAreMaskedWholeAndItsIdentityIsNeverShown() throws {
        let secret = syntheticKey
        let long = "Rotate the deploy key, then call the API with Bearer \(bearerPlaceholder) and API_TOKEN=\(secret) before the cutover"
        let events = [try update(2, alpha)]
        let records = [ToolDetailSummary(key: "event-2", kind: "plan", sequence: 2,
                                         plan: [PlanItem(content: long, status: "in_progress", activeForm: "Calling with \(secret)"),
                                                PlanItem(content: "Write the notes", status: "pending")])]
        let plan = plans(pretty(events, records))[0]
        let hidden = try #require(plan.shown(hidesSecrets: true))
        // What the card draws and what VoiceOver reads are both made from these values.
        #expect(!hidden.contains { $0.content.contains(secret) || $0.content.contains(bearerPlaceholder) })
        #expect(hidden[0].activeForm?.contains(secret) == false)
        #expect(hidden[0].content.contains(SecretValues.hidden(secret)) && hidden[0].content.contains(SecretValues.hidden(bearerPlaceholder)))
        #expect(SecretValues.hidden(secret) == "Hidden, 27 characters")
        #expect(hidden[0].content.hasPrefix("Rotate the deploy key") && hidden[0].content.hasSuffix("before the cutover"))
        #expect(hidden[1] == PlanItem(content: "Write the notes", status: "pending") && hidden.map(\.state) == [.inProgress, .pending])
        // The stored values are unchanged, and shown as sent when the setting keeps everything.
        #expect(plan.items?[0].content == long && plan.shown(hidesSecrets: false) == plan.items)
        // The identity is in no ID, line or item the reader can see, hear or copy.
        let removed = plans(pretty(events + [try removal(3, alpha)], records))[0]
        for text in [plan.id, plan.line, removed.id, removed.line] + hidden.map(\.content) {
            #expect(!text.contains(alpha))
        }
    }

    @Test func consoleKeepsTheRawRows() throws {
        let events = try interleaved() + [try removal(6, alpha)]
        let console = TranscriptEntry.displayed(TranscriptEntry.entries(from: events), mode: .console)
        let texts = console.compactMap { entry -> String? in
            if case .other(_, let text) = entry.kind { return text }
            return nil
        }
        #expect(texts == ["[ACP plan_update]", "[ACP plan_update]", "[ACP plan_update]", "[ACP plan_removed]"])
    }
}

@MainActor @Suite struct PrettyPlanIdentityRenderTests {
    /// The negotiated turn on the focused worker, a wall tile and the PiP: before the removal
    /// (two cards) and after it (the removal line above the other plan's card).
    @Test(.enabled(if: prettyRenderDirectory != nil)) func drawsTheIdentifiedPlans() async throws {
        let folder = URL(fileURLWithPath: try #require(prettyRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        func turn(removed: Bool) throws -> [TranscriptEntry] {
            var events = [try message(1, role: "user", "ACP activity fixture; execute nothing", worker: "c"),
                          try message(2, role: "assistant", "BEFORE_PLAN_QA", worker: "c"),
                          try update(3, alpha, worker: "c"), try update(4, beta, worker: "c"), try update(5, alpha, worker: "c")]
            if removed { events.append(try removal(6, alpha, worker: "c")) }
            events.append(try message(7, role: "assistant", "AFTER_PLAN_QA", worker: "c"))
            return TranscriptEntry.entries(from: events)
        }
        let details = ToolDetailStore(summaries: ["c": [
            record(3, [("ALPHA_INITIAL_QA", "pending")]),
            record(4, [("BETA_STAYS_QA", "pending"), ("Call the API with " + syntheticKey, "in_progress")]),
            record(5, [("ALPHA_LATEST_QA", "completed"), ("Report the result", "pending")]),
        ]], settings: TranscriptSettings(hideSecrets: true))
        let sizes: [(String, PrettyDensity, CGSize)] = [("focused", .regular, CGSize(width: 800, height: 520)),
                                                        ("wall-tile", .compact, CGSize(width: 440, height: 420)),
                                                        ("pip", .pip, CGSize(width: 350, height: 380))]
        for (name, density, size) in sizes {
            for removed in [false, true] {
                let view = PrettyRenderTests.console(try turn(removed: removed), density: density, coordinator: false,
                                                     size: size, details: details)
                try await ShellRenderTests.write(view, "pretty-plan-identity-\(name)-\(removed ? "removed" : "updated")",
                                                 theme: .console, to: folder, size: size)
            }
        }
        let last = ShellRenderTests.fileName("pretty-plan-identity-pip-removed", .console)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(last).path))
    }
}
