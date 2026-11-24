import Foundation
import Testing
@testable import AgentCommander

/// Number identity across the value, the reducer and the record inspector.
@Suite struct NativeIntegrationTests {
    private static let big = "1234567890123456789012345678901234567890123"
    private static let bigNeighbour = "1234567890123456789012345678901234567890124"

    private static func number(_ literal: String) throws -> AGUINumber {
        try #require(AGUINumber(literal: literal), "\(literal) is not a JSON number")
    }

    private static func state(revision: String, requests: String = "[]") -> String {
        """
        {"type":"STATE_SNAPSHOT","snapshot":{"runs":[{"id":"r1","project":"p","path":"/p","task":"t","client":"codex",\
        "coordinator_id":"w1","status":"running","worker_limit":\(revision),"requests":\(requests),"workers":[\
        {"id":"w1","name":"one","role":"coordinator","parent_id":"","run_id":"r1","state":"working","host":"local",\
        "worktree":"/p","task":"t","revision":\(revision),"outputChunks":["a","b"],\
        "messages":[{"id":"m1","role":"assistant","content":"hello","usage":{"tokens":\(revision)}}]},\
        {"id":"w2","name":"two","role":"worker","parent_id":"w1","run_id":"r1","state":"working","host":"local",\
        "worktree":"/p","task":"t","secret":"other worker","outputChunks":[],"messages":[]}]}]}}
        """
    }

    @Test func equatableKeepsEveryLiteralDifference() throws {
        #expect(try Self.number(Self.big) != Self.number(Self.bigNeighbour))
        #expect(try Self.number("1") != Self.number("1.0"))
        #expect(try Self.number("1") != Self.number("1e0"))
        #expect(try Self.number("0.1") == Self.number("0.1"))
        #expect(try AGUIValue(json: "[\(Self.big)]") != AGUIValue(json: "[\(Self.bigNeighbour)]"))
    }

    @Test func valueComparisonIsExact() throws {
        let same: [(String, String)] = [
            ("1", "1.00"), ("1", "1e0"), ("1", "10E-1"), ("100", "1e2"), ("100", "0.01e+4"), ("-0", "0"),
            ("0e99999999999999999999999999", "0.000"), ("1.5e-3", "0.0015"), ("-12.50", "-125e-1"),
            (Self.big + "0", Self.big + "e1"), ("1e99999999999999999999999999", "1.0E+99999999999999999999999999"),
            ("1e400", "10e399"), ("1e-400", "0.1e-399")
        ]
        for (left, right) in same {
            #expect(try Self.number(left).hasSameValue(as: Self.number(right)), "\(left) and \(right)")
            #expect(try Self.number(right).hasSameValue(as: Self.number(left)), "\(right) and \(left)")
        }
        let different: [(String, String)] = [
            (Self.big, Self.bigNeighbour), (Self.big + ".0", Self.big + ".0000000000000000000000000000000000000001"),
            ("1", "-1"), ("1e400", "1e401"), ("1e-400", "0"), ("1e99999999999999999999999999", "1e99999999999999999999999998"),
            ("1e99999999999999999999999999", "1e-99999999999999999999999999"), ("0.1", "0.10000000000000000555"),
            ("9007199254740993", "9007199254740992"), ("1e999999999999999999", "1e-999999999999999999")
        ]
        for (left, right) in different {
            #expect(try !Self.number(left).hasSameValue(as: Self.number(right)), "\(left) and \(right)")
        }
    }

    @Test func jsonEqualityIsByValueAndStateEqualityIsByLiteral() throws {
        let left = try AGUIValue(json: #"{"a":[1,2.50,{"b":1e2}],"c":"x"}"#)
        let right = try AGUIValue(json: #"{"c":"x","a":[1.0,2.5,{"b":100}]}"#)
        #expect(left.isJSONEqual(to: right))
        #expect(left != right)
        #expect(try !AGUIValue(json: Self.big).isJSONEqual(to: AGUIValue(json: Self.bigNeighbour)))
        #expect(!AGUIValue.string("\u{E9}").isJSONEqual(to: .string("e\u{301}")))
        #expect(!AGUIValue.number(AGUINumber(1)).isJSONEqual(to: .string("1")))
    }

    @Test func codableKeepsWhatItsCoderCanHold() throws {
        for literal in ["18446744073709551615", "-9223372036854775808", "1.5", "0.001"] {
            let value = try AGUIValue(json: literal)
            let decoded = try JSONDecoder().decode(AGUIValue.self, from: JSONEncoder().encode(value))
            let number = try #require(decoded.numberValue)
            #expect(try number.hasSameValue(as: Self.number(literal)), "\(literal) became \(number.literal)")
        }
    }

    @Test func aStreamedChangeBeyondDoublePrecisionReachesTheModels() throws {
        var reducer = AGUIWorkspaceReducer()
        try reducer.apply(frame: Self.state(revision: Self.big))
        let before = reducer.runs
        for path in ["/runs/0/worker_limit", "/runs/0/workers/0/revision", "/runs/0/workers/0/messages/0/usage/tokens"] {
            try reducer.apply(frame: #"{"type":"STATE_DELTA","delta":[{"op":"replace","path":"\#(path)","value":\#(Self.bigNeighbour)}]}"#)
        }
        let after = reducer.runs
        #expect(before != after)
        #expect(before[0].workers?[0] != after[0].workers?[0])
        #expect(before[0].workers?[0].messages?[0] != after[0].workers?[0].messages?[0])
        #expect(before[0].workers?[1] == after[0].workers?[1])
        #expect(after[0].allFields["worker_limit"]?.numberValue?.literal == Self.bigNeighbour)
        #expect(after[0].workers?[0].allFields["revision"]?.numberValue?.literal == Self.bigNeighbour)
    }

    @Test func patchTestComparesNumbersByExactValue() throws {
        var reducer = AGUIWorkspaceReducer()
        try reducer.apply(frame: Self.state(revision: "100"))
        func test(_ value: String) throws {
            try reducer.apply(frame: #"{"type":"STATE_DELTA","delta":[{"op":"test","path":"/runs/0/worker_limit","value":\#(value)}]}"#)
        }
        try test("100")
        try test("1.00e2")
        #expect(throws: AGUIValueError.self) { try test("100.0000000000000000000000000000000000000001") }

        try reducer.apply(frame: Self.state(revision: Self.big))
        try test(Self.big + ".0")
        #expect(throws: AGUIValueError.self) { try test(Self.bigNeighbour) }
        #expect(reducer.runs[0].allFields["worker_limit"]?.numberValue?.literal == Self.big)
    }

    @Test func recordFieldsAreTheRetainedFieldsOfOneWorker() throws {
        var reducer = AGUIWorkspaceReducer()
        let requests = """
        [{"id":"q1","worker_id":"w1","question":"mine","status":"open","answer":"","choices":[\(Self.big)]},\
        {"id":"q2","worker_id":"w2","question":"other worker","status":"open","answer":""}]
        """
        try reducer.apply(frame: Self.state(revision: Self.big, requests: requests))
        let run = reducer.runs[0]
        let worker = try #require(run.workers?.first)
        let detail = try #require(ConsoleRecordDetail.resolve(entryID: "m1", worker: worker, run: run))

        let sections = Dictionary(uniqueKeysWithValues: try detail.sections.map { ($0.id, try AGUIValue(json: $0.json)) })
        #expect(sections["message"] == worker.messages?.first?.allFields)
        #expect(sections["worker"] == worker.allFields)
        #expect(sections["worker"]?["revision"]?.numberValue?.literal == Self.big)
        #expect(sections["run"]?["worker_limit"]?.numberValue?.literal == Self.big)
        #expect(sections["run"]?["workers"] == nil)
        #expect(sections["run"]?["requests"]?.arrayValue?.map { $0["id"]?.stringValue } == ["q1"])
        #expect(sections["run"]?["requests"]?[0]?["choices"]?[0]?.numberValue?.literal == Self.big)

        // Copying every section keeps each literal and nothing of the other worker.
        let copied = try AGUIValue(json: detail.combinedJSON)
        #expect(copied["Worker"] == worker.allFields)
        #expect(copied["Message"]?["usage"]?["tokens"]?.numberValue?.literal == Self.big)
        #expect(!detail.combinedJSON.contains("other worker"))
    }
}
