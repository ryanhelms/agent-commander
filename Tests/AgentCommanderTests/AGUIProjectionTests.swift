import Foundation
import Testing
@testable import AgentCommander

// Frames here use the service's wire shapes: the incremental snapshot carries `outputChunks`
// and `messages` on every worker, and each delta is the patch the Go projection generates.

private func worker(_ id: String, chunks: String = "[]", messages: String = "[]", extra: String = "") -> String {
    #"{"id":"\#(id)","name":"\#(id)","role":"worker","parent_id":"","run_id":"r","state":"working","host":"local","worktree":"/tmp/w","task":"build","error":"",\#(extra)"outputChunks":\#(chunks),"messages":\#(messages)}"#
}

private func run(_ id: String = "r", workers: [String], extra: String = "") -> String {
    #"{"id":"\#(id)","project":"p","path":"/p","task":"ship it","client":"claude","coordinator_id":"w","status":"running","worker_limit":4,"requests":[],\#(extra)"workers":[\#(workers.joined(separator: ","))]}"#
}

private func snapshot(_ runs: [String], reason: String? = nil) -> String {
    let metadata = reason.map { #""metadata":{"commander":{"reason":"\#($0)"}},"# } ?? ""
    return #"{"type":"STATE_SNAPSHOT",\#(metadata)"snapshot":{"runs":[\#(runs.joined(separator: ","))]}}"#
}

private func delta(_ operations: String...) -> String {
    #"{"type":"STATE_DELTA","delta":[\#(operations.joined(separator: ","))]}"#
}

private func text(_ id: String, _ content: String, role: String = "assistant") -> String {
    #"{"id":"\#(id)","role":"\#(role)","content":"\#(content)"}"#
}

private let quiet = worker("quiet", chunks: #"["untouched tail"]"#, messages: "[\(text("quiet:1", "still here"))]")

private func started(_ first: String = worker("w")) throws -> AGUIWorkspaceReducer {
    var reducer = AGUIWorkspaceReducer()
    #expect(try reducer.apply(frame: snapshot([run(workers: [first, quiet])])) == .snapshot)
    return reducer
}

private func lead(_ reducer: AGUIWorkspaceReducer) -> Worker { reducer.runs[0].workers![0] }

@Suite struct AGUIValueTests {
    @Test func keepsEveryKindOfValueAndNumberLiteral() throws {
        let source = #"{"a":null,"b":[true,false,[],{}],"big":12345678901234567890123,"exact":0.1000000000000000055511151231257827,"exp":-1.5E+300,"neg":-0,"s":"\u00e9\ud83c\udf33\u003c\/\n\"","n":{"deep":[{"k":1}]}}"#
        let value = try AGUIValue(json: source)
        #expect(value["a"] == .null)
        #expect(value["missing"] == nil)
        #expect(value["b"]?[0] == true)
        #expect(value["b"]?[2] == .array([]))
        #expect(value["big"]?.numberValue?.literal == "12345678901234567890123")
        #expect(value["big"]?.intValue == nil)
        #expect(value["exact"]?.numberValue?.literal == "0.1000000000000000055511151231257827")
        #expect(value["exp"]?.numberValue?.literal == "-1.5E+300")
        #expect(value["neg"]?.numberValue?.literal == "-0")
        #expect(value["s"] == .string("é🌳</\n\""))
        #expect(value["n"]?["deep"]?[0]?["k"]?.intValue == 1)
        // Both renderings read back as the same value.
        #expect(try AGUIValue(json: value.compactText) == value)
        #expect(try AGUIValue(json: value.prettyText) == value)
        #expect(value.prettyText.contains("\"big\": 12345678901234567890123"))
    }

    @Test func prettyTextIsSortedAndIndented() throws {
        let value = try AGUIValue(json: #"{"b":[1,{"y":null,"x":"t\tab"}],"a":{}}"#)
        #expect(value.prettyText == """
        {
          "a": {},
          "b": [
            1,
            {
              "x": "t\\tab",
              "y": null
            }
          ]
        }
        """)
        #expect(value.compactText == #"{"a":{},"b":[1,{"x":"t\tab","y":null}]}"#)
        #expect(AGUIValue.string("plain").displayText == "plain")
    }

    @Test func numbersAreEqualAsWrittenAndComparableByValue() throws {
        // State equality is by literal, so a rewritten number is a visible change.
        #expect(try AGUIValue(json: "1.0") != AGUIValue(json: "1"))
        #expect(try AGUIValue(json: "[1.0]").isJSONEqual(to: AGUIValue(json: "[1]")))
        #expect(try AGUIValue(json: #"{"n":1e2,"z":-0}"#).isJSONEqual(to: AGUIValue(json: #"{"z":0,"n":100}"#)))
        #expect(try !AGUIValue(json: "0.1").isJSONEqual(to: AGUIValue(json: "0.1000000000000000055511151231257827")))
        #expect(try !AGUIValue(json: "9007199254740993").isJSONEqual(to: AGUIValue(json: "9007199254740992")))
        #expect(try !AGUIValue(json: "1").isJSONEqual(to: AGUIValue(json: #""1""#)))
        #expect(AGUINumber(literal: "01") == nil)
        #expect(AGUINumber(literal: "1.") == nil)
    }

    @Test(arguments: [
        "", "{", "[1,]", #"{"a":1,}"#, "01", "-", "1.e3", "nul", "tru", #""abc"#, "\"a\u{01}b\"", #""\x""#, #""\u12""#,
        "1 2", "{} x", #"{"a" 1}"#, #"{a:1}"#, "+1", ".5", "NaN"
    ])
    func rejectsMalformedDocuments(source: String) {
        #expect(throws: AGUIValueError.self) { try AGUIValue(json: source) }
    }

    @Test func rejectsInvalidUTF8AndRunawayNesting() {
        #expect(throws: AGUIValueError.self) { try AGUIValue(json: [0x22, 0xFF, 0xFE, 0x22]) }
        #expect(throws: AGUIValueError.self) { try AGUIValue(json: String(repeating: "[", count: 100_000)) }
        // A surrogate with no partner is read the way the service's encoder writes one.
        #expect((try? AGUIValue(json: #""\ud83cx""#)) == .string("\u{FFFD}x"))
    }

    @Test func decodesThroughFoundationToo() throws {
        let data = Data(#"{"a":null,"n":[1,2.5,18446744073709551615],"t":true,"s":"x"}"#.utf8)
        let decoded = try JSONDecoder().decode(AGUIValue.self, from: data)
        #expect(decoded == (try AGUIValue(json: data)))
        #expect(try AGUIValue(json: JSONEncoder().encode(decoded)) == decoded)
    }

    @Test func pointersUnescapeMembers() throws {
        #expect(try AGUIPointer("").tokens == [])
        #expect(try AGUIPointer("/").tokens == [""])
        #expect(try AGUIPointer("/a~1b/m~0n/~01/-").tokens == ["a/b", "m~n", "~1", "-"])
        #expect(try AGUIPointer("/a~1b/m~0n").description == "/a~1b/m~0n")
        #expect(throws: AGUIValueError.self) { try AGUIPointer("runs/0") }
        #expect(throws: AGUIValueError.self) { try AGUIPointer("/a~2") }
        #expect(throws: AGUIValueError.self) { try AGUIPointer("/a~") }
        #expect(AGUIPointer.index("0") == 0)
        #expect(AGUIPointer.index("12") == 12)
        #expect(AGUIPointer.index("01") == nil)
        #expect(AGUIPointer.index("-1") == nil)
        #expect(AGUIPointer.index("") == nil)
    }
}

@Suite struct AGUIWorkspaceReducerTests {
    @Test func appendsOutputAndMessagesWithoutTouchingOtherWorkers() throws {
        var reducer = try started()
        let untouched = reducer.runs[0].workers![1]
        #expect(lead(reducer).output == "")
        #expect(lead(reducer).messages == [])

        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"event 1\n"}"#,
            #"{"op":"add","path":"/runs/0/workers/0/messages/-","value":\#(text("w:1", "event 1\\n"))}"#))
        // Small writes extend the last chunk; the service replaces it whole.
        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/workers/0/outputChunks/0","value":"event 1\nevent 2\n"}"#,
            #"{"op":"add","path":"/runs/0/workers/0/messages/-","value":\#(text("w:2", "event 2\\n"))}"#))
        try reducer.apply(frame: delta(#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"🌳 tail"}"#))

        #expect(lead(reducer).output == "event 1\nevent 2\n🌳 tail")
        #expect(lead(reducer).messages?.map(\.id) == ["w:1", "w:2"])
        #expect(lead(reducer).messages?.last?.content == "event 2\n")
        #expect(reducer.runs[0].workers![1] == untouched)
        #expect(reducer.runs[0].workers![1].output == "untouched tail")
        #expect(reducer.document?["runs"]?[0]?["workers"]?[0]?["outputChunks"] == ["event 1\nevent 2\n", "🌳 tail"])
    }

    @Test func trimsAndReplacesTheRetainedTail() throws {
        var reducer = try started(worker("w", chunks: #"["aaaa","bbbb","cccc"]"#))
        // The service retires whole chunks from the front, then cuts into the next one.
        try reducer.apply(frame: delta(
            #"{"op":"remove","path":"/runs/0/workers/0/outputChunks/0"}"#,
            #"{"op":"replace","path":"/runs/0/workers/0/outputChunks/0","value":"bb"}"#,
            #"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"dddd"}"#))
        #expect(lead(reducer).output == "bbccccdddd")
        // A reconciliation inserts and removes in the middle.
        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/0/outputChunks/1","value":"-mid-"}"#,
            #"{"op":"remove","path":"/runs/0/workers/0/outputChunks/2"}"#))
        #expect(lead(reducer).output == "bb-mid-dddd")
        // A tail that no longer overlaps is replaced as a list, including by an empty one.
        try reducer.apply(frame: delta(#"{"op":"replace","path":"/runs/0/workers/0/outputChunks","value":["fresh"]}"#))
        #expect(lead(reducer).output == "fresh")
        try reducer.apply(frame: delta(#"{"op":"replace","path":"/runs/0/workers/0/outputChunks","value":[]}"#))
        #expect(lead(reducer).output == "")
    }

    @Test func keepsMessageOrderThroughRemovalInsertionAndReplacement() throws {
        let history = [text("w:1", "one"), text("w:2", "two"), text("w:4", "four")].joined(separator: ",")
        var reducer = try started(worker("w", messages: "[\(history)]"))
        try reducer.apply(frame: delta(
            #"{"op":"remove","path":"/runs/0/workers/0/messages/0"}"#,
            #"{"op":"add","path":"/runs/0/workers/0/messages/1","value":\#(text("w:3", "three"))}"#,
            #"{"op":"replace","path":"/runs/0/workers/0/messages/2","value":\#(text("w:4", "FOUR", role: "user"))}"#,
            #"{"op":"add","path":"/runs/0/workers/0/messages/-","value":\#(text("w:5", "five"))}"#))
        let messages = try #require(lead(reducer).messages)
        #expect(messages.map(\.id) == ["w:2", "w:3", "w:4", "w:5"])
        #expect(messages.map(\.content) == ["two", "three", "FOUR", "five"])
        #expect(messages[2].role == "user")
    }

    @Test func editsRunAndWorkerAttributesAndNestedMembers() throws {
        var reducer = try started(worker("w", extra: #""connection":"connected","coding":{"a/b":{"m~n":[1,2]},"base":"main"},"#))
        let before = reducer.runs[0]
        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/status","value":"failed"}"#,
            #"{"op":"add","path":"/runs/0/title","value":"Named"}"#,
            #"{"op":"replace","path":"/runs/0/requests","value":[{"id":"q","worker_id":"w","question":"go?","status":"pending","answer":"","choices":[{"id":"y","label":"Yes"}]}]}"#,
            #"{"op":"replace","path":"/runs/0/workers/0/state","value":"waiting"}"#,
            #"{"op":"remove","path":"/runs/0/workers/0/connection"}"#,
            #"{"op":"add","path":"/runs/0/workers/0/control","value":{"generation":3,"held":true,"messages":[{"id":"m","status":"queued","text":"t","generation":3}]}}"#,
            // Members whose names need escaping, and edits several levels down.
            #"{"op":"add","path":"/runs/0/workers/0/coding/a~1b/m~0n/-","value":3}"#,
            #"{"op":"replace","path":"/runs/0/workers/0/coding/a~1b/m~0n/0","value":null}"#,
            #"{"op":"remove","path":"/runs/0/workers/0/coding/base"}"#,
            #"{"op":"add","path":"/runs/0/workers/0/coding/x~0~1y","value":{"z":[]}}"#))
        let run = reducer.runs[0]
        #expect(run != before)
        #expect(run.status == "failed")
        #expect(run.title == "Named")
        #expect(run.requests?.first?.question == "go?")
        #expect(run.allFields["requests"]?[0]?["choices"]?[0]?["label"] == "Yes")
        #expect(run.extendedFields == ["worker_limit": 4])
        let worker = lead(reducer)
        #expect(worker.state == "waiting")
        #expect(worker.connection == nil)
        #expect(worker.control == WorkerControl(held: true, generation: 3, interruptRequested: nil,
                                                 messages: [WorkerFollowUp(id: "m", status: "queued")]))
        #expect(worker.allFields["control"]?["messages"]?[0]?["text"] == "t")
        #expect(worker.extendedFields == ["coding": ["a/b": ["m~n": [nil, 2, 3]], "x~/y": ["z": []]]])
        #expect(worker.allFields["outputChunks"] == nil)
        #expect(worker.allFields["messages"] == nil)
    }

    @Test func addsWorkersAndRunsAtTheEnd() throws {
        var reducer = try started()
        let first = reducer.runs[0]
        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/-","value":\#(worker("late", chunks: #"["hi"]"#))}"#))
        #expect(reducer.runs[0].workers?.map(\.id) == ["w", "quiet", "late"])
        #expect(reducer.runs[0].workers?[2].output == "hi")
        #expect(reducer.runs[0].workers?[0] == first.workers?[0])
        try reducer.apply(frame: delta(#"{"op":"add","path":"/runs/-","value":\#(run("r2", workers: []))}"#))
        #expect(reducer.runs.map(\.id) == ["r", "r2"])
        #expect(reducer.runs[1].workers == [])
        // The first run was not touched by the second frame and is the same value.
        let afterWorker = reducer.runs[0]
        try reducer.apply(frame: delta(#"{"op":"replace","path":"/runs/1/status","value":"completed"}"#))
        #expect(reducer.runs[0] == afterWorker)
        #expect(reducer.runs[1].status == "completed")
    }

    @Test func keepsNullsAndUnknownToolAndAttachmentFields() throws {
        let call = #"{"id":"w:7","role":"assistant","metadata":{"acp":{"source":"live","cursor":"opaque.cursor","kind":"tool_call_update","usage":{"used":12345678901234567890,"size":200000,"cost":{"amount":0.1000000000000000055,"currency":"USD"}}},"acpSources":[{"source":"provider","cursor":"a","kind":"tool_call"},{"source":"live","cursor":"opaque.cursor","kind":"tool_call_update"}]},"toolCalls":[{"id":"w:call","type":"function","function":{"name":"Read","arguments":"{\"detail\":\"read a file\"}"},"encryptedValue":null,"vendor":{"depth":[1,[2,[3]]]}}]}"#
        let result = #"{"id":"w:8","role":"tool","toolCallId":"w:call","error":"exit 2","content":[{"type":"text","text":"first"},{"type":"binary","mimeType":"image/png","filename":"chart.png","data":"aGk=","id":null},{"type":"image","source":{"type":"url","value":"https://example.invalid/a.png","mimeType":"image/jpeg"}},{"type":"text","text":"last"}],"encryptedValue":null}"#
        var reducer = try started()
        try reducer.apply(frame: delta(
            #"{"op":"add","path":"/runs/0/workers/0/messages/-","value":\#(call)}"#,
            #"{"op":"add","path":"/runs/0/workers/0/messages/-","value":\#(result)}"#,
            #"{"op":"add","path":"/runs/0/workers/0/handoff","value":null}"#))
        let messages = try #require(lead(reducer).messages)

        #expect(messages[0].allFields == (try AGUIValue(json: call)))
        #expect(messages[0].content == nil)
        #expect(messages[0].toolCalls?.first?.function == .init(name: "Read", arguments: #"{"detail":"read a file"}"#))
        #expect(messages[0].toolCalls?.first?.allFields["encryptedValue"] == .null)
        #expect(messages[0].toolCalls?.first?.allFields["vendor"]?["depth"]?[1]?[1]?[0] == 3)
        #expect(messages[0].metadata?["acp"]?["usage"]?["used"]?.numberValue?.literal == "12345678901234567890")
        #expect(messages[0].metadata?["acp"]?["usage"]?["cost"]?["amount"]?.numberValue?.literal == "0.1000000000000000055")
        #expect(messages[0].sources.map(\.source) == ["provider", "live"])
        #expect(messages[0].sources.last?.cursor == "opaque.cursor")
        #expect(messages[0].extendedFields.sortedKeys == ["metadata"])

        #expect(messages[1].allFields == (try AGUIValue(json: result)))
        #expect(messages[1].content == "first\n[binary · image/png · chart.png]\n[image · image/jpeg]\nlast")
        #expect(messages[1].hasStructuredContent)
        #expect(messages[1].contentValue?[1]?["id"] == .null)
        #expect(messages[1].toolCallID == "w:call")
        #expect(messages[1].error == "exit 2")
        #expect(messages[1].extendedFields.sortedKeys == ["content", "encryptedValue"])
        #expect(messages[1].allFields.prettyText.contains("\"encryptedValue\": null"))

        // An explicit null is a member, and stays one. A missing member is different.
        #expect(lead(reducer).allFields["handoff"] == .null)
        #expect(lead(reducer).allFields["result"] == nil)
        #expect(lead(reducer).extendedFields == ["handoff": nil])
    }

    @Test func editsInsideOneMessage() throws {
        let call = #"{"id":"w:1","role":"assistant","metadata":{"acp":{"source":"live","kind":"tool_call"}},"toolCalls":[{"id":"w:call","type":"function","function":{"name":"","arguments":"{}"}}]}"#
        var reducer = try started(worker("w", messages: "[\(call),\(text("w:2", "after"))]"))
        let second = lead(reducer).messages![1]
        try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/runs/0/workers/0/messages/0/toolCalls/0/function/name","value":"Read"}"#,
            #"{"op":"add","path":"/runs/0/workers/0/messages/0/metadata/acp/cursor","value":"c.1"}"#,
            #"{"op":"add","path":"/runs/0/workers/0/messages/0/content","value":null}"#,
            #"{"op":"remove","path":"/runs/0/workers/0/messages/0/metadata/acp/kind"}"#))
        let message = lead(reducer).messages![0]
        #expect(message.toolCalls?.first?.function.name == "Read")
        #expect(message.sources == [AGUISource(fields: ["source": "live", "cursor": "c.1"])!])
        #expect(message.content == nil)
        #expect(message.contentValue == .null)
        #expect(lead(reducer).messages![1] == second)
    }

    @Test func snapshotResetsStateAfterReconnectOrExpiredCursor() throws {
        var reducer = try started()
        try reducer.apply(frame: delta(#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"old"}"#))
        #expect(reducer.snapshotReason == nil)

        // The viewer fell behind the retained deltas: the service resends everything.
        let recovered = run("r", workers: [worker("w", chunks: #"["new ","tail"]"#, messages: "[\(text("w:79", "event 79"))]")])
        #expect(try reducer.apply(frame: snapshot([recovered, run("r9", workers: [])],
                                                  reason: AGUIWorkspaceReducer.deltaExpiredReason)) == .snapshot)
        #expect(reducer.snapshotReason == AGUIWorkspaceReducer.deltaExpiredReason)
        #expect(reducer.runs.map(\.id) == ["r", "r9"])
        #expect(reducer.runs[0].workers?.map(\.id) == ["w"])
        #expect(lead(reducer).output == "new tail")
        #expect(lead(reducer).messages?.map(\.id) == ["w:79"])

        // Deltas continue from the new state, and a later plain snapshot clears the reason.
        try reducer.apply(frame: delta(#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"!"}"#))
        #expect(lead(reducer).output == "new tail!")
        try reducer.apply(frame: snapshot([]))
        #expect(reducer.runs.isEmpty)
        #expect(reducer.snapshotReason == nil)
        #expect(reducer.document == ["runs": []])
    }

    @Test(arguments: [
        // A later operation fails after earlier ones applied.
        [#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"x"}"#, #"{"op":"remove","path":"/runs/0/workers/0/messages/5"}"#],
        [#"{"op":"replace","path":"/runs/0/status","value":"done"}"#, #"{"op":"replace","path":"/runs/0/workers/0/nope","value":1}"#],
        [#"{"op":"remove","path":"/runs/0/workers/1"}"#, #"{"op":"replace","path":"/runs/0/workers/1/state","value":"x"}"#],
        // Out of order: a position that only exists on a state this viewer does not have.
        [#"{"op":"replace","path":"/runs/0/workers/0/outputChunks/3","value":"x"}"#],
        [#"{"op":"add","path":"/runs/0/workers/0/messages/2","value":{"id":"w:9","role":"assistant"}}"#],
        [#"{"op":"add","path":"/runs/4/workers/-","value":{}}"#],
        [#"{"op":"replace","path":"/runs/0/workers/0/outputChunks/-","value":"x"}"#],
        [#"{"op":"remove","path":"/runs/0/workers/0/outputChunks/00"}"#],
        // Values of the wrong shape.
        [#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":7}"#],
        [#"{"op":"add","path":"/runs/0/workers/0/messages/-","value":{"role":"assistant"}}"#],
        [#"{"op":"add","path":"/runs/0/workers/0/messages/-","value":"text"}"#],
        [#"{"op":"replace","path":"/runs/0/workers/0/state","value":5}"#],
        [#"{"op":"remove","path":"/runs/0/workers/0/id"}"#],
        [#"{"op":"replace","path":"/runs/0/workers","value":{"0":{}}}"#],
        [#"{"op":"replace","path":"/runs/0/workers/0/control","value":{"held":"yes","generation":1}}"#],
        [#"{"op":"add","path":"/runs/-","value":{"id":"r2"}}"#],
        [#"{"op":"add","path":"/runs/0/workers/0/outputChunks/0/deeper","value":"x"}"#],
        // Operations that are not well formed.
        [#"{"op":"merge","path":"/runs/0/status","value":"x"}"#],
        [#"{"op":"replace","path":"runs/0/status","value":"x"}"#],
        [#"{"op":"replace","path":"/runs/0/workers/0/coding~2","value":"x"}"#],
        [#"{"path":"/runs/0/status","value":"x"}"#],
        [#"{"op":"remove","path":""}"#],
        [#"{"op":"test","path":"/runs/0/status","value":"stopped"}"#],
        [#"{"op":"move","from":"/runs/0","path":"/runs/0/workers/0/inner"}"#],
        [#""remove""#]
    ])
    func rejectsABadTransactionWhole(operations: [String]) throws {
        var reducer = try started()
        let before = reducer.runs
        let document = reducer.document
        #expect(throws: AGUIValueError.self) {
            try reducer.apply(frame: #"{"type":"STATE_DELTA","delta":[\#(operations.joined(separator: ","))]}"#)
        }
        #expect(reducer.runs == before)
        #expect(reducer.document == document)
        // The state is still usable: the next good patch applies to exactly what was there.
        try reducer.apply(frame: delta(#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"ok"}"#))
        #expect(lead(reducer).output == "ok")
        #expect(reducer.runs[0].workers?.count == 2)
    }

    @Test func rejectsCorruptFramesAndDeltasBeforeASnapshot() throws {
        var reducer = AGUIWorkspaceReducer()
        #expect(throws: AGUIValueError.self) {
            try reducer.apply(frame: delta(#"{"op":"replace","path":"/runs","value":[]}"#))
        }
        #expect(!reducer.hasSnapshot)
        reducer = try started()
        let before = reducer.runs
        for frame in [#"{"type":"STATE_DELTA","delta":[{"op":"add","path":"/runs/0/wor"#, "", "[]", #"{"delta":[]}"#,
                      #"{"type":"STATE_DELTA","delta":{"op":"remove"}}"#, #"{"type":"STATE_SNAPSHOT"}"#,
                      #"{"type":"STATE_SNAPSHOT","snapshot":[]}"#, #"{"type":"STATE_SNAPSHOT","snapshot":{"runs":{}}}"#,
                      #"{"type":"STATE_SNAPSHOT","snapshot":{"runs":[{"id":"only"}]}}"#] {
            #expect(throws: AGUIValueError.self) { try reducer.apply(frame: frame) }
            #expect(reducer.runs == before)
        }
        // Events that carry no workspace state are passed over.
        #expect(try reducer.apply(frame: #"{"type":"CUSTOM","name":"x","value":1}"#) == nil)
        #expect(try reducer.apply(frame: #"{"type":"STATE_DELTA"}"#) == .delta)
        #expect(reducer.runs == before)
    }

    @Test func supportsTheRemainingPatchOperations() throws {
        var reducer = try started(worker("w", chunks: #"["a","b"]"#, extra: #""coding":{"base":"main"},"#))
        try reducer.apply(frame: delta(
            #"{"op":"test","path":"/runs/0/workers/0/coding","value":{"base":"main"}}"#,
            #"{"op":"copy","from":"/runs/0/workers/0/coding/base","path":"/runs/0/workers/0/branch"}"#,
            #"{"op":"move","from":"/runs/0/workers/0/outputChunks/0","path":"/runs/0/workers/0/outputChunks/-"}"#,
            #"{"op":"move","from":"/runs/0/workers/1","path":"/runs/0/workers/0"}"#))
        #expect(reducer.runs[0].workers?.map(\.id) == ["quiet", "w"])
        #expect(reducer.runs[0].workers?[1].branch == "main")
        #expect(reducer.runs[0].workers?[1].output == "ba")
    }

    @Test func reducesTheLegacyProjection() throws {
        // A service without the incremental projection sends `output` and replaces whole runs.
        func legacy(_ id: String, output: String, state: String = "working") -> String {
            #"{"id":"\#(id)","project":"p","path":"/p","task":"t","client":"claude","coordinator_id":"w","status":"running","requests":[],"workers":[{"id":"w","name":"w","role":"coordinator","parent_id":"","run_id":"\#(id)","state":"\#(state)","host":"local","worktree":"","task":"t","output":"\#(output)","messages":[\#(text("w:1", "hello"))]}]}"#
        }
        var reducer = AGUIWorkspaceReducer()
        try reducer.apply(frame: snapshot([legacy("a", output: "one"), legacy("b", output: "two")]))
        let untouched = reducer.runs[1]
        try reducer.apply(frame: delta(#"{"op":"replace","path":"/runs/0","value":\#(legacy("a", output: "one more", state: "completed"))}"#))
        #expect(reducer.runs[0].workers?.first?.output == "one more")
        #expect(reducer.runs[0].workers?.first?.state == "completed")
        #expect(reducer.runs[0].workers?.first?.messages?.first?.content == "hello")
        #expect(reducer.runs[1] == untouched)
        try reducer.apply(frame: delta(#"{"op":"replace","path":"/runs","value":[\#(legacy("c", output: "three"))]}"#))
        #expect(reducer.runs.map(\.id) == ["c"])
        #expect(reducer.runs[0].coordinator?.output == "three")
    }

    @Test func replaysALongStreamAgainstTheWholeDocument() throws {
        // The reduced tree must equal the same patches applied to one plain JSON value.
        var reducer = try started()
        var plain = try #require(reducer.document)
        var expected = ""
        for step in 1...400 {
            var operations: [String] = []
            let piece = "t\(step) "
            expected += piece
            operations.append(#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"\#(piece)"}"#)
            operations.append(#"{"op":"add","path":"/runs/0/workers/0/messages/-","value":\#(text("w:\(step)", piece))}"#)
            if step % 7 == 0 {
                expected.removeFirst(lead(reducer).output.prefix { $0 != " " }.count + 1)
                operations.insert(#"{"op":"remove","path":"/runs/0/workers/0/outputChunks/0"}"#, at: 0)
                operations.append(#"{"op":"remove","path":"/runs/0/workers/0/messages/0"}"#)
            }
            if step % 11 == 0 {
                operations.append(#"{"op":"replace","path":"/runs/0/workers/1/state","value":"s\#(step)"}"#)
            }
            let frame = delta(operations.joined(separator: ","))
            try reducer.apply(frame: frame)
            for operation in try AGUIValue(json: frame)["delta"]!.arrayValue! {
                let edit: AGUIEdit = switch operation["op"]!.stringValue! {
                case "add": .add(operation["value"]!)
                case "replace": .replace(operation["value"]!)
                default: .remove
                }
                try plain.apply(edit, at: AGUIPointer(operation["path"]!.stringValue!).tokens[...])
            }
        }
        #expect(reducer.document == plain)
        #expect(lead(reducer).output == expected)
        #expect(reducer.runs[0].workers?[1].state == "s396")
        #expect(lead(reducer).messages?.count == 400 - 400 / 7)
    }

    @Test func comparesUntouchedValuesByIdentityAndChangedOnesByContent() throws {
        var first = try started()
        var second = try started()
        // Separate connections build separate values with the same content.
        #expect(first.runs == second.runs)
        try first.apply(frame: delta(#"{"op":"add","path":"/runs/0/workers/0/coding","value":{"base":"main"}}"#))
        #expect(first.runs != second.runs)
        try second.apply(frame: delta(#"{"op":"add","path":"/runs/0/workers/0/coding","value":{"base":"main"}}"#))
        #expect(first.runs == second.runs)
        try second.apply(frame: delta(#"{"op":"replace","path":"/runs/0/workers/0/coding/base","value":"dev"}"#))
        #expect(first.runs != second.runs)
    }
}

@Suite struct AGUIModelTests {
    @Test func readsTheRequestAPIWithTheSameModels() throws {
        let body = #"{"runs":[{"id":"r","project":"p","path":"/p","task":"first line\nsecond","client":"claude","coordinator_id":"w","workers":[{"id":"w","name":"lead","role":"coordinator","parent_id":"","run_id":"r","state":"working","host":"local","worktree":"/w","task":"t","output":"tail","console":[{"sequence":1,"kind":"text","text":"hi"}],"native_session":{"harness_instance":"codex","session_id":"s1"},"frontend_tools":true}],"requests":null,"status":"running","worker_limit":4},{"id":"empty","project":"p","path":"/p","task":"t","client":"codex","coordinator_id":"","workers":null,"requests":null,"status":"completed","worker_limit":1}]}"#
        let runs = try Run.list(json: Data(body.utf8))
        #expect(runs.map(\.id) == ["r", "empty"])
        #expect(runs[0].title == "first line")
        #expect(runs[0].coordinator?.output == "tail")
        #expect(runs[0].coordinator?.boundSession == NativeSession(harnessInstance: "codex", sessionID: "s1"))
        #expect(runs[0].coordinator?.extendedFields["frontend_tools"] == true)
        #expect(runs[0].coordinator?.allFields["console"]?[0]?["text"] == "hi")
        #expect(runs[0].requests == nil)
        #expect(runs[1].workers == nil)
        #expect(try Run.list(json: Data(#"{"runs":null}"#.utf8)).isEmpty)
        // The Foundation decoder reads the same shapes.
        #expect(try JSONDecoder().decode(RunList.self, from: Data(body.utf8)).runs == runs)
    }

    @Test func readsContentOfEveryShape() throws {
        func content(_ json: String) throws -> String? {
            try AGUIMessage(fields: AGUIValue(json: #"{"id":"m","role":"assistant","content":\#(json)}"#)).content
        }
        #expect(try content(#""plain""#) == "plain")
        #expect(try content("null") == nil)
        #expect(try content(#"[{"type":"text","text":"a"},"b",{"text":"c"}]"#) == "a\nb\nc")
        #expect(try content(#"{"type":"document","source":{"mediaType":"application/pdf","name":"spec.pdf"}}"#)
            == "[document · application/pdf · spec.pdf]")
        #expect(try content(#"[{"unknown":1}]"#) == "[content]")
        #expect(try content("[]") == "")
        #expect(try content("42") == "42")
        let none = try AGUIMessage(fields: ["id": "m", "role": "tool", "toolCallId": "c"])
        #expect(none.content == nil)
        #expect(none.contentValue == nil)
        #expect(none.sources.isEmpty)
    }

    @Test func keepsTheOriginalConstructors() {
        let call = AGUIToolCall(id: "c", function: .init(name: "Read", arguments: "{}"))
        let message = AGUIMessage(id: "m", role: "assistant", content: "hi", toolCalls: [call], toolCallID: nil, error: nil)
        #expect(message.allFields["content"] == "hi")
        #expect(message.allFields["toolCalls"]?[0]?["function"]?["name"] == "Read")
        #expect(message == AGUIMessage(id: "m", role: "assistant", content: "hi", toolCalls: [call]))
        #expect(message != AGUIMessage(id: "m", role: "assistant", content: "bye", toolCalls: [call]))
        let worker = Worker(id: "w", name: "w", role: "worker", parentID: "", runID: "r", state: "working",
                            host: "local", worktree: "", task: "t", output: "o", error: nil, messages: [message])
        #expect(worker == worker)
        #expect(worker.extendedFields == [:])
        let run = Run(id: "r", project: "p", path: "/p", task: "t", client: "claude", coordinatorID: "w",
                      status: "running", workers: [worker], requests: nil)
        #expect(run.coordinator == worker)
    }
}

@Suite struct AGUIEventStreamParserTests {
    private func outputs(_ body: String) throws -> [AGUIEventStreamParser.Output] {
        var parser = AGUIEventStreamParser()
        return try body.utf8.compactMap { try parser.consume($0) }
    }

    private func event(_ text: String) -> AGUIEventStreamParser.Output { .event(Array(text.utf8)) }

    @Test func splitsFramesAndSkipsHeartbeats() throws {
        let body = "data: {\"a\":1}\n\n: heartbeat\n\ndata: {\"b\":2}\n\n\ncommander-http-status: 200\n"
        #expect(try outputs(body) == [event(#"{"a":1}"#), event(#"{"b":2}"#), .status(200)])
    }

    @Test func acceptsOtherLineEndingsFieldsAndSplitData() throws {
        let body = "event: state\r\nid: 4\r\ndata:{\"a\":\r\ndata: 1}\r\n\r\nretry: 5\rdata: x\r\r"
        #expect(try outputs(body) == [event("{\"a\":\n1}"), event("x")])
    }

    @Test func dropsAFrameCutOffByADisconnect() throws {
        #expect(try outputs("data: {\"a\":1}\n\ndata: {\"b\":") == [event(#"{"a":1}"#)])
        // The transport's status line follows the cut and is still read.
        #expect(try outputs("data: {\"b\":\ncommander-http-status: 404\n") == [.status(404)])
    }

    @Test func feedsTheReducer() throws {
        var reducer = AGUIWorkspaceReducer()
        let body = "data: \(snapshot([run(workers: [worker("w")])]))\n\n: heartbeat\n\n" +
            "data: \(delta(#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"a\n"}"#))\n\n" +
            "data: \(delta(#"{"op":"add","path":"/runs/0/workers/0/outputChunks/-","value":"b"}"#))\n\n"
        for case .event(let frame) in try outputs(body) { try reducer.apply(frame: frame) }
        #expect(reducer.runs[0].workers?[0].output == "a\nb")
    }
}
