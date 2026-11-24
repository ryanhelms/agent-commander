import Foundation
import Testing
@testable import AgentCommander

/// Replays a privately captured workspace feed through `AGUIWorkspaceReducer` and compares the
/// state after every frame with one computed independently.
///
/// `COMMANDER_AGUI_REPLAY` names a JSONL file. Each line is
/// `{"event": <AG-UI event>, "expected": {"runs": [...]}}`, where `expected` is the whole state
/// after that event as a separate RFC 6902 implementation computed it. Lines are read with
/// `AGUIValue`, so no number passes through a `Double`. The capture holds real session content
/// and stays outside the repository: a failure names a frame, a path and sizes, never a value.
@Suite struct NativeCaptureReplayTests {
    static let variable = "COMMANDER_AGUI_REPLAY"

    static var capturePath: String? {
        ProcessInfo.processInfo.environment[variable].flatMap { $0.isEmpty ? nil : $0 }
    }

    @Test(.enabled(if: NativeCaptureReplayTests.capturePath != nil,
                   "Set COMMANDER_AGUI_REPLAY to a private paired capture to run this replay."))
    func reducerMatchesTheIndependentStateAfterEveryCapturedFrame() throws {
        let path = try #require(Self.capturePath)
        let capture = try Data(contentsOf: URL(filePath: path))
        // A complete line ends with a newline. Anything after the last one is an unfinished write.
        let complete = capture[..<((capture.lastIndex(of: UInt8(ascii: "\n")) ?? capture.startIndex))]

        var reducer = AGUIWorkspaceReducer()
        var frames = 0, snapshots = 0, deltas = 0, messages = 0
        for (offset, line) in complete.split(separator: UInt8(ascii: "\n")).enumerated() {
            let frame = offset + 1
            guard let pair = try? AGUIValue(json: Data(line)), let event = pair["event"], let expected = pair["expected"] else {
                Issue.record("Line \(frame) is not an {event, expected} pair.")
                return
            }
            let kind = event["type"]?.stringValue ?? "untyped"
            do {
                switch try reducer.apply(event: event) {
                case .snapshot?: snapshots += 1
                case .delta?: deltas += 1
                case nil:
                    Issue.record("Frame \(frame) (\(kind)): not read as workspace state.")
                    return
                }
            } catch {
                Issue.record("Frame \(frame) (\(kind)): the reducer threw \(type(of: error)).")
                return
            }
            guard let document = reducer.document else {
                Issue.record("Frame \(frame) (\(kind)): the reducer holds no document.")
                return
            }
            let difference = Replay.difference(document, expected, at: "$")
                ?? Replay.projectionDifference(reducer.runs, expected, messages: &messages)
            if let difference {
                Issue.record("Frame \(frame) (\(kind)): \(difference)")
                return
            }
            frames = frame
        }

        #expect(frames > 0, "The capture has no complete frame.")
        #expect(snapshots > 0, "The capture has no snapshot.")
        #expect(deltas > 0, "The capture has no delta, so it does not exercise the incremental reducer.")
        print("NativeCaptureReplayTests: \(frames) frames matched (\(snapshots) snapshots, \(deltas) deltas, \(messages) message comparisons).")
    }
}

private enum Replay {
    /// The first place two JSON values differ, or nil. Numbers compare by exact value, because
    /// the expected state was written by another serializer. Strings compare byte for byte.
    static func difference(_ actual: AGUIValue, _ expected: AGUIValue, at path: String) -> String? {
        switch (actual, expected) {
        case (.null, .null):
            return nil
        case (.bool(let actual), .bool(let expected)):
            return actual == expected ? nil : "\(path) is the other boolean"
        case (.number(let actual), .number(let expected)):
            return actual.hasSameValue(as: expected) ? nil : "\(path) is a different number"
        case (.string(let actual), .string(let expected)):
            return text(actual, expected).map { "\(path) \($0)" }
        case (.array(let actual), .array(let expected)):
            guard actual.count == expected.count else { return "\(path) has \(actual.count) items, expected \(expected.count)" }
            for index in actual.indices {
                if let found = difference(actual[index], expected[index], at: "\(path)[\(index)]") { return found }
            }
            return nil
        case (.object(let actual), .object(let expected)):
            let missing = expected.keys.filter { actual[$0] == nil }.count
            let unexpected = actual.keys.filter { expected[$0] == nil }.count
            guard missing == 0, unexpected == 0 else {
                return "\(path) has \(missing) members missing and \(unexpected) unexpected"
            }
            for key in actual.keys.sorted() {
                if let found = difference(actual[key]!, expected[key]!, at: "\(path).\(key)") { return found }
            }
            return nil
        default:
            return "\(path) is \(kind(actual)), expected \(kind(expected))"
        }
    }

    /// The typed projection against the expected state: the same workers in the same order,
    /// each message's retained fields, and the output as the expected chunks joined.
    static func projectionDifference(_ runs: [Run], _ expected: AGUIValue, messages compared: inout Int) -> String? {
        let wantRuns = expected["runs"]?.arrayValue ?? []
        guard runs.count == wantRuns.count else { return "there are \(runs.count) runs, expected \(wantRuns.count)" }
        for (r, run) in runs.enumerated() {
            let workers = run.workers ?? []
            let wantWorkers = wantRuns[r]["workers"]?.arrayValue ?? []
            guard workers.map(\.id) == wantWorkers.map({ $0["id"]?.stringValue ?? "" }) else {
                return "runs[\(r)] projects \(workers.count) worker ids that differ from the \(wantWorkers.count) expected"
            }
            for (w, worker) in workers.enumerated() {
                let path = "runs[\(r)].workers[\(w)]"
                let want = wantWorkers[w]
                let wantOutput = want["outputChunks"]?.arrayValue.map { $0.map { $0.stringValue ?? "" }.joined() }
                    ?? want["output"]?.stringValue ?? ""
                if let found = text(worker.output, wantOutput) { return "\(path).output \(found)" }

                let messages = worker.messages ?? []
                let wantMessages = want["messages"]?.arrayValue ?? []
                guard messages.count == wantMessages.count else {
                    return "\(path) has \(messages.count) messages, expected \(wantMessages.count)"
                }
                for (m, message) in messages.enumerated() {
                    if let found = difference(message.allFields, wantMessages[m], at: "\(path).messages[\(m)].allFields") {
                        return found
                    }
                }
                compared += messages.count
            }
        }
        return nil
    }

    /// Byte-for-byte. Swift's `==` also accepts canonically equivalent text.
    private static func text(_ actual: String, _ expected: String) -> String? {
        if actual.utf8.elementsEqual(expected.utf8) { return nil }
        let shared = zip(actual.utf8, expected.utf8).prefix { $0 == $1 }.count
        return "differs at byte \(shared) (\(actual.utf8.count) bytes, expected \(expected.utf8.count))"
    }

    private static func kind(_ value: AGUIValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}
