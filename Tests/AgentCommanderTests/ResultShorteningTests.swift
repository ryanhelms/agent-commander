import Foundation
import Testing
@testable import AgentCommander

/// Issue #111: a value the service shortened is marked where it is drawn, from the service's own
/// record of what it cut. The end-of-result banner stays for a result whose end is gone.
@Suite struct ResultShorteningTests {
    static let mark = PrettyJSON.storedMark
    static let end = ShorteningNotice.endMissing

    /// The #72 fixture's result as the service stores it under a 1,024-byte limit: one string cut,
    /// both rows and the later property whole.
    static let kept = "VISIBLE_PARTIAL_72_" + String(repeating: "a", count: 1005)
    static let stored = #"{"complete_field":"INTACT_PREFIX_72","rows":[{"name":"alpha","status":"complete","count":1},"#
        + #"{"name":"bravo","status":"working","count":2}],"cut_field":""# + kept + mark + #"","later_field":"UNRECEIVED_72"}"#

    static func record(_ result: String, truncated: [String]? = ["result"], shortened: [String: [String]]? = nil,
                       input: String? = nil) -> ToolDetailRecord {
        ToolDetailRecord(key: "call-w:1", kind: "tool", name: "structured", input: input, result: result,
                         truncated: truncated, shortened: shortened)
    }

    /// The opened line's source for one call whose console preview is `preview`.
    static func source(_ record: ToolDetailRecord?, preview: String = "{}", tool: String = "structured") -> ActivityResultSource {
        var wire = Wire()
        wire.call(tool, detail: "{}", result: preview)
        let entry = wire.entries[0]
        let step = ActivityStep(id: entry.id, entries: [entry], state: .done, sentence: ActivitySentence("Structured cut fixture"))
        return ActivityResultSource(entry: entry, step: step, record: record)
    }

    struct Opened {
        let source: ActivityResultSource
        let payload: ResultPayload
        let selection: ResultShape.Selection
        var notice: ShorteningNotice { ResultShape.notice(selection, payload: payload) }
        /// Every top-level property as the generic rows draw it.
        var rows: [ResultField] { payload.value.map { ResultField.rows($0, shortened: payload.shortened) } ?? [] }
        func row(_ key: String) -> ResultField? { rows.first { $0.key == key } }
        var sourceNote: String? {
            let result = PrettyJSON.format(source.resultText ?? "", cut: source.resultCut)
            return ResultSourceDisclosure.note(call: .none, result: ResultSourceDisclosure.cut(result, stored: source.resultCut))
        }
    }

    static func open(_ record: ToolDetailRecord?, preview: String = "{}", tool: String = "structured") -> Opened {
        let source = source(record, preview: preview, tool: tool)
        let payload = ResultPayload.read(source.resultText, cut: source.resultCut)
        return Opened(source: source, payload: payload,
                      selection: ResultShape.select(tool: source.name, payload: payload, resultText: source.resultText, failed: false))
    }

    // MARK: The fixture

    @Test func theCutPropertyIsMarkedAndTheResultKeepsItsShape() throws {
        let opened = Self.open(Self.record(Self.stored, shortened: ["result": ["/cut_field"]]))
        #expect(opened.source.resultCut == .strings([["cut_field"]]))
        // No banner: the result is whole, and the one shortened value carries its own tag.
        #expect(opened.notice == .none && opened.payload.notice == .none && !opened.payload.isCut)
        #expect(opened.payload.shortened == ShortenedPaths(paths: [["cut_field"]]))

        // The renderer, its placed and remaining properties and their order are what the same
        // text selects with no record at all.
        let plain = ResultPayload.read(Self.stored, cut: .complete)
        #expect(opened.selection == ResultShape.select(tool: "structured", payload: plain, resultText: Self.stored, failed: false))
        #expect(opened.selection.shape == .recordTable(key: "rows"))
        #expect(opened.selection.remaining == ["complete_field", "cut_field", "later_field"])
        #expect(opened.payload.value == plain.value)

        // Both rows are whole, with their values and types as sent.
        let rows = try #require(opened.payload.value?["rows"]?.items)
        #expect(rows == [
            .object([.init(key: "name", value: .string("alpha")), .init(key: "status", value: .string("complete")),
                     .init(key: "count", value: .number("1"))]),
            .object([.init(key: "name", value: .string("bravo")), .init(key: "status", value: .string("working")),
                     .init(key: "count", value: .number("2"))]),
        ])
        #expect(opened.payload.shortened.under("rows").isEmpty)

        // Only the cut property is marked. It is drawn without the service's mark, as long text.
        #expect(opened.rows.map(\.key) == ["complete_field", "rows", "cut_field", "later_field"])
        #expect(opened.rows.filter(\.isShortened).map(\.key) == ["cut_field"])
        let cut = try #require(opened.row("cut_field"))
        #expect(cut.value == .string(Self.kept) && cut.kind == .longText && cut.label == "Cut field")
        #expect(opened.row("complete_field")?.value == .string("INTACT_PREFIX_72") && opened.row("complete_field")?.kind == .text)
        #expect(opened.row("later_field")?.value == .string("UNRECEIVED_72") && opened.row("later_field")?.kind == .text)
        #expect(opened.row("rows")?.kind == .table && opened.row("rows")?.shortened.isEmpty == true)
        #expect(ActivityTag.shortened == ActivityTag(word: "Shortened", tone: .wait))
    }

    @Test func sourceKeepsTheExactStoredTextAndSaysWhatWasShortened() {
        let opened = Self.open(Self.record(Self.stored, shortened: ["result": ["/cut_field"]]), preview: "a console preview")
        // Copy result copies this: the record's text, byte for byte, mark included.
        #expect(opened.source.resultText == Self.stored)
        let shown = PrettyJSON.format(Self.stored, cut: opened.source.resultCut)
        #expect(shown.isJSON && !shown.isCut)
        #expect(shown.text.contains("\"cut_field\": \"" + Self.kept + Self.mark + "\","))
        #expect(shown.text.hasSuffix("\"later_field\": \"UNRECEIVED_72\"\n}"))
        // Source does not claim the text ends early.
        #expect(opened.sourceNote == "One or more values were shortened before this text was stored.")

        // A whole stored text that ends in the mark's characters is shown with them.
        let literal = #"{"said":"x"}"# + Self.mark
        let whole = Self.open(Self.record(literal, truncated: nil))
        #expect(whole.source.resultText == literal && whole.sourceNote == nil)
        #expect(PrettyJSON.format(literal, cut: whole.source.resultCut) == PrettyJSON.Formatted(text: literal, isJSON: false))
    }

    // MARK: Literal marks

    @Test func aMarkInAnUncutValueIsNeverTakenForACut() throws {
        let literal = "the provider wrote " + Self.mark
        // A record the service did not list: whole, whatever its values or its text end in.
        let whole = Self.open(Self.record(#"{"note":""# + literal + #"","count":2,"more":["a","b"],"deep":{"x":1},"last":true}"#, truncated: nil))
        #expect(whole.source.resultCut == .complete && whole.notice == .none && whole.payload.shortened.isEmpty)
        #expect(whole.rows.allSatisfy { !$0.isShortened } && whole.row("note")?.value == .string(literal))
        let text = Self.open(Self.record("plain output that ends in " + Self.mark, truncated: nil))
        #expect(text.notice == .none && text.selection.shape == .text && text.sourceNote == nil)

        // Beside a value that was shortened, a sibling ending in the mark stays as sent.
        let stored = #"{"literal":""# + literal + #"","rows":[{"name":"alpha","note":""# + literal + #""},{"name":"bravo","note":"x"}],"#
            + #""cut_field":""# + Self.kept + Self.mark + #"","e":1,"f":2}"#
        let opened = Self.open(Self.record(stored, shortened: ["result": ["/cut_field"]]))
        #expect(opened.notice == .none)
        #expect(opened.rows.filter(\.isShortened).map(\.key) == ["cut_field"])
        #expect(opened.row("literal")?.value == .string(literal))
        #expect(opened.row("rows")?.shortened.isEmpty == true)
        #expect(opened.payload.value?["rows"]?.items?.first?["note"] == .string(literal))
    }

    // MARK: Whole-result cuts

    @Test func aResultWhoseEndIsGoneKeepsItsBanner() {
        // Plain text the service cut at the end.
        let plain = Self.open(Self.record(String(repeating: "line of output\n", count: 60) + Self.mark, shortened: ["result": [""]]))
        #expect(plain.source.resultCut == .end && plain.notice == Self.end && plain.payload.shortened.isEmpty)
        #expect(plain.sourceNote == "The text ends here: it was cut short before it was stored.")
        // JSON the hard cap cut before it closed: whole members are kept, the banner stays.
        let json = Self.open(Self.record(#"{"id":"r-1","status":"running","workers":[{"name":"a"},{"na"# + Self.mark, shortened: ["result": [""]]))
        #expect(json.notice == Self.end && json.payload.isCut && json.payload.value?["workers"]?.items?.count == 1)
        #expect(json.rows.allSatisfy { !$0.isShortened })
        // With no stored record, the console preview's own mark still says so.
        let preview = Self.open(nil, preview: #"{"id":"r-1","workers":[{"name":"a"},{"na"# + "\n[Output shortened]")
        #expect(preview.source.resultCut == .unrecorded && preview.notice == Self.end)
        #expect(ShorteningNotice.endMissing.sentence == "Commander kept only the first part of this result. The end is missing.")
    }

    @Test func aShortenedStringIsNeverReadAsWholeNestedJSON() throws {
        // An MCP text part holding JSON, cut by the service: the data's end is missing.
        let inner = #"{\"tools\":[{\"id\":\"one\"},{\"id\":\"two\"},{\"id\":\"thr"#
        let envelope = #"{"content":[{"type":"text","text":""# + inner + Self.mark + #""}],"isError":false}"#
        let opened = Self.open(Self.record(envelope, shortened: ["result": ["/content/0/text"]]))
        #expect(opened.notice == Self.end && opened.payload.isCut)
        // It is read as far as it goes, as any result whose end is gone: the last ID is partial.
        #expect(opened.payload.value?["tools"]?.items?.map { $0["id"]?.string } == ["one", "two", "thr"])
        // The same envelope, whole: no notice.
        let whole = Self.open(Self.record(#"{"content":[{"type":"text","text":"{\"tools\":[{\"id\":\"one\"}]}"}]}"#, truncated: nil))
        #expect(whole.notice == .none && whole.payload.value?["tools"]?.items?.count == 1)

        // A property whose shortened string starts like JSON is a marked string, not a nested record.
        let stored = #"{"id":"x","payload":"{\"a\":1,\"b\":\""# + String(repeating: "b", count: 1010) + Self.mark + #"","n":1,"m":2,"k":3}"#
        let field = try #require(Self.open(Self.record(stored, shortened: ["result": ["/payload"]])).row("payload"))
        #expect(field.isShortened && field.kind == .longText && field.value.string?.hasPrefix(#"{"a":1,"b":"bbb"#) == true)
        #expect(field.value.string?.hasSuffix(Self.mark) == false)
    }

    // MARK: Records without paths

    @Test func anOlderRecordGetsAGeneralNoticeAndNoFieldIsNamed() throws {
        // The same stored text from a service that listed the result and kept no paths.
        let old = Self.open(Self.record(Self.stored))
        #expect(old.source.resultCut == .unlocated)
        #expect(old.notice == .valuesShortened && old.payload.notice == .valuesShortened && !old.payload.isCut)
        #expect(ShorteningNotice.valuesShortened.sentence == "Commander shortened one or more values in this result before storing it.")
        // No value is singled out, and each is drawn as stored.
        #expect(old.payload.shortened.isEmpty && old.rows.allSatisfy { !$0.isShortened })
        #expect(old.row("cut_field")?.value == .string(Self.kept + Self.mark))
        #expect(old.selection.shape == .recordTable(key: "rows") && old.payload.value?["later_field"] == .string("UNRECEIVED_72"))
        #expect(old.sourceNote == "One or more values were shortened before this text was stored.")

        // Older plain text and JSON that stops early keep the end-of-result banner.
        #expect(Self.open(Self.record("output " + Self.mark)).notice == Self.end)
        #expect(Self.open(Self.record("a runner's cut with no mark")).notice == Self.end)
        let early = Self.open(Self.record(#"{"id":"r-1","workers":[{"name":"a"},{"na"#))
        #expect(early.notice == Self.end && early.sourceNote == "The text ends here: it was cut short before it was stored.")

        // An older service's response decodes; a newer one carries the paths.
        let decoder = JSONDecoder()
        let before = try decoder.decode(ToolDetailRecord.self, from: Data(#"{"key":"t","kind":"tool","result":"{}","truncated":["result"]}"#.utf8))
        #expect(before.shortened == nil && StoredCut(record: before, field: "result", isStored: true) == .unlocated)
        let after = try decoder.decode(ToolDetailRecord.self, from: Data(
            #"{"key":"t","kind":"tool","result":"{}","truncated":["result"],"shortened":{"result":["/a~1b~0c/deep/1"]}}"#.utf8))
        #expect(StoredCut(record: after, field: "result", isStored: true) == .strings([["a/b~c", "deep", "1"]]))
        #expect(StoredCut(record: after, field: "input", isStored: true) == .complete)
        #expect(StoredCut(record: after, field: "result", isStored: false) == .unrecorded)
    }

    @Test func aPathThatDoesNotLeadToACutStringNamesNothing() {
        let paths: [[String]] = [
            ["/later_field"],              // a whole string
            ["/missing"], ["/rows/7/name"], ["/rows/0/count"], ["/rows"],
            ["not-a-pointer"],
        ]
        for path in paths {
            let opened = Self.open(Self.record(Self.stored, shortened: ["result": path]))
            #expect(opened.notice == .valuesShortened && opened.rows.allSatisfy { !$0.isShortened }, "\(path)")
        }
        // A key sent twice cannot say which member was cut.
        let twice = #"{"a":"whole "# + Self.mark + #"","a":""# + Self.kept + Self.mark + #"","b":1,"c":2,"d":3}"#
        let opened = Self.open(Self.record(twice, shortened: ["result": ["/a"]]))
        #expect(opened.notice == .valuesShortened && opened.payload.shortened.isEmpty)
        // One good path beside a bad one: the good one is marked, and the notice covers the other.
        let mixed = Self.open(Self.record(Self.stored, shortened: ["result": ["/cut_field", "/missing"]]))
        #expect(mixed.notice == .valuesShortened && mixed.rows.filter(\.isShortened).map(\.key) == ["cut_field"])
    }

    // MARK: Rows, nesting and wrappers

    @Test func aPathMarksItsOwnRowAndColumn() throws {
        let stored = #"{"rows":[{"name":"alpha","note":"short"},{"name":"bravo","note":""# + Self.kept + Self.mark
            + #""},{"name":"charlie","note":"short"}]}"#
        let opened = Self.open(Self.record(stored, shortened: ["result": ["/rows/1/note"]]))
        #expect(opened.selection.shape == .recordTable(key: "rows") && opened.notice == .none)
        let table = opened.payload.shortened.under("rows")
        #expect(table.under(1).under("note").isHere)
        #expect(!table.under(0).under("note").isHere && !table.under(2).under("note").isHere && !table.under(1).under("name").isHere)

        // A column the table does not show cannot carry the tag, so the notice says it.
        let wide = #"{"rows":[{"name":"a","b":1,"c":2,"d":3,"e":4,"note":"x"},{"name":"b","b":1,"c":2,"d":3,"e":4,"note":""#
            + Self.kept + Self.mark + #""}]}"#
        #expect(Self.open(Self.record(wide, shortened: ["result": ["/rows/1/note"]])).notice == .valuesShortened)
        // So does a renderer that draws its own properties without tags.
        let roster = #"{"status":"running","workers":[{"name":"a","state":"working","result":""# + Self.kept + Self.mark + #""}]}"#
        let run = Self.open(Self.record(roster, shortened: ["result": ["/workers/0/result"]]))
        #expect(run.selection.shape == .runRoster && run.notice == .valuesShortened)
    }

    @Test func pathsFollowTheDataThroughNestingAndWrappers() throws {
        let cut = Self.kept + Self.mark
        // Nested objects, a list of scalars and unlike records are marked where they are drawn.
        let nested = #"{"a":{"b":{"c":""# + cut + #""}},"tags":["x",""# + cut + #""],"mixed":[{"k":""# + cut + #""},"plain"],"n":1,"m":2}"#
        let opened = Self.open(Self.record(nested, shortened: ["result": ["/a/b/c", "/tags/1", "/mixed/0/k"]]))
        #expect(opened.selection.shape == .generic && opened.notice == .none)
        let a = try #require(opened.row("a"))
        #expect(!a.isShortened && a.shortened == ShortenedPaths(paths: [["b", "c"]]))
        let b = try #require(ResultField.rows(a.value, shortened: a.shortened).first)
        #expect(ResultField.rows(b.value, shortened: b.shortened).first?.isShortened == true)
        #expect(opened.row("tags")?.kind == .scalarList && opened.row("tags")?.shortened.under(1).isHere == true)
        #expect(opened.row("mixed")?.shortened.under(0).under("k").isHere == true)
        // Past four levels the row reads "Deeper values are in Source", so the notice stands in.
        let deep = #"{"a":{"b":{"c":{"d":{"e":{"f":""# + cut + #""}}}}},"n":1,"m":2,"k":3}"#
        #expect(Self.open(Self.record(deep, shortened: ["result": ["/a/b/c/d/e/f"]])).notice == .valuesShortened)

        // Paths are carried into `structuredContent` and the network wrapper's `data`.
        let structured = #"{"content":[{"type":"text","text":"see data"}],"structuredContent":{"id":"x","note":""# + cut + #"","n":1,"m":2}}"#
        let mcp = Self.open(Self.record(structured, shortened: ["result": ["/structuredContent/note"]]))
        #expect(mcp.notice == .none && mcp.rows.filter(\.isShortened).map(\.key) == ["note"])
        let wrapped = #"{"ok":true,"data":{"id":"x","note":""# + cut + #"","n":1,"m":2}}"#
        let network = Self.open(Self.record(wrapped, shortened: ["result": ["/data/note"]]))
        #expect(network.notice == .none && network.rows.filter(\.isShortened).map(\.key) == ["note"])
    }

    // MARK: Secrets and the call

    @Test func aShortenedSecretStaysHidden() throws {
        let stored = #"{"id":"x","api_token":""# + Self.kept + Self.mark + #"","auth":"sk-"# + String(repeating: "k", count: 1021) + Self.mark
            + #"","n":1,"m":2}"#
        let opened = Self.open(Self.record(stored, shortened: ["result": ["/api_token", "/auth"]]))
        #expect(opened.notice == .none)
        #expect(opened.row("api_token")?.kind == .secret && opened.row("api_token")?.isShortened == true)
        #expect(opened.row("auth")?.kind == .secret && opened.row("auth")?.isShortened == true)
        // Source masks the same values, and Copy still holds the stored text.
        let shown = PrettyJSON.format(stored, cut: opened.source.resultCut)
        let masked = SecretValues.masked(text: shown.text)
        #expect(masked.count == 2 && !masked.text.contains(Self.kept) && opened.source.resultText == stored)
    }

    @Test func theCallTextIsReadByItsOwnRecord() {
        let input = #"{"prompt":""# + Self.kept + Self.mark + #"","mode":"fast"}"#
        let record = ToolDetailRecord(key: "call-w:1", kind: "tool", input: input, result: "done " + Self.mark,
                                      truncated: ["input"], shortened: ["input": ["/prompt"]])
        let source = Self.source(record)
        #expect(source.callText == input && source.callCut == .strings([["prompt"]]) && source.resultCut == .complete)
        let call = ResultSourceDisclosure.cut(PrettyJSON.format(input, cut: source.callCut), stored: source.callCut)
        let result = ResultSourceDisclosure.cut(PrettyJSON.format("done " + Self.mark, cut: source.resultCut), stored: source.resultCut)
        #expect(call == .values && result == .none)
        #expect(ResultSourceDisclosure.note(call: call, result: result) == "One or more values were shortened before this text was stored.")
        #expect(ResultSourceDisclosure.note(call: .none, result: .none) == nil)
    }
}
