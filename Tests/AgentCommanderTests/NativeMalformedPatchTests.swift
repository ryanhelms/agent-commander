import Foundation
import Testing
@testable import AgentCommander

// RFC 6902 requires `value` on add, replace and test. An explicit null is a value. An operation
// without the member is malformed, and the delta that carries it leaves the state as it was.

private func seeded() throws -> AGUIWorkspaceReducer {
    var reducer = AGUIWorkspaceReducer()
    #expect(try reducer.apply(frame: #"{"type":"STATE_SNAPSHOT","snapshot":{"runs":[],"note":"set"}}"#) == .snapshot)
    return reducer
}

private func delta(_ operations: String...) -> String {
    #"{"type":"STATE_DELTA","delta":[\#(operations.joined(separator: ","))]}"#
}

@Suite struct NativeMalformedPatchTests {
    @Test func acceptsAnExplicitNullValue() throws {
        var reducer = try seeded()
        #expect(try reducer.apply(frame: delta(
            #"{"op":"replace","path":"/note","value":null}"#,
            #"{"op":"test","path":"/note","value":null}"#,
            #"{"op":"add","path":"/added","value":null}"#
        )) == .delta)
        #expect(reducer.document?["note"] == .null)
        #expect(reducer.document?["added"] == .null)
    }

    @Test(arguments: ["add", "replace", "test"])
    func rejectsTheWholeDeltaWhenValueIsMissing(op: String) throws {
        var reducer = try seeded()
        let before = reducer.document
        #expect(throws: AGUIValueError.self) {
            try reducer.apply(frame: delta(
                #"{"op":"add","path":"/marker","value":"applied first"}"#,
                #"{"op":"\#(op)","path":"/note"}"#
            ))
        }
        #expect(reducer.document == before)
        #expect(reducer.document?["marker"] == nil)
        #expect(reducer.document?["note"] == "set")
    }
}
