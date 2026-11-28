import Foundation

// ATOMIC LEVEL: Pages (design previews).
// A sample conversation for the cockpit previews, so the Pretty and Console transcripts can be
// reviewed on the wall, the focused worker and the PiP without a service. It is off unless asked
// for:
//
//   AGENT_COMMANDER_PREVIEW_DISPLAY=pretty|console   give every sample console this conversation
//                                                    and start all consoles in that display mode
//
// The messages are AG-UI JSON read by the production decoder and turned into entries by the
// production `TranscriptEntry.entries(from:)`, and an entry's fields come from the production
// `ConsoleRecordDetail.resolve`. They carry what a real feed can: Markdown, a tool call with JSON
// arguments and its result, a failed call, a `system` line, multimodal content with an inline
// image, source metadata and fields the app does not name.

@MainActor
enum ConversationFixture {
    /// The display mode the preview was asked to start in. Nil leaves the previews as they are.
    static let display: ConsoleDisplayMode? =
        ProcessInfo.processInfo.environment["AGENT_COMMANDER_PREVIEW_DISPLAY"].flatMap(ConsoleDisplayMode.init(rawValue:))

    private static var cache: [String: [AGUIMessage]] = [:]

    static func messages(workerID: String) -> [AGUIMessage] {
        guard display != nil else { return [] }
        if let hit = cache[workerID] { return hit }
        let json = template.replacingOccurrences(of: "WID", with: workerID)
        var messages = (try? JSONDecoder().decode([AGUIMessage].self, from: Data(json.utf8))) ?? []
        if CompactionFixture.isRequested { messages += CompactionFixture.messages(workerID: workerID) }
        cache[workerID] = messages
        return messages
    }

    static func transcript(workerID: String) -> [TranscriptEntry] {
        TranscriptEntry.entries(from: messages(workerID: workerID))
    }

    /// The fields of one sample entry, through the production resolver.
    static func detail(workerID: String, entryID: String, name: String, host: String) -> ConsoleRecordDetail? {
        let messages = messages(workerID: workerID)
        guard !messages.isEmpty else { return nil }
        let worker = Worker(id: workerID, name: name, role: "worker", parentID: "W-041", runID: "R-042",
                            state: "working", host: host, worktree: "/Users/sample/Developer/relay",
                            task: "Cover timeout behavior.", output: "", client: "codex",
                            branch: "main", messages: messages)
        let run = Run(id: "R-042", project: "Relay", path: "/Users/sample/Developer/relay",
                      task: "Plan and implement a retry policy for upstream requests.", client: "claude",
                      coordinatorID: "W-041", status: "running", workers: nil, requests: nil,
                      givenTitle: "Retry policy")
        return ConsoleRecordDetail.resolve(entryID: entryID, worker: worker, run: run)
    }

    private static let template = #"""
    [
      {"id": "WID:1", "role": "user",
       "content": "Cover timeout behavior before headers, after headers, and after the first body chunk. Report any ambiguous cases."},
      {"id": "WID:2", "role": "assistant",
       "metadata": {"acp": {"source": "provider", "cursor": "c-002", "kind": "agent_message", "messageId": "msg_01"}},
       "content": "I'll map the three phases first, then run the timeout suite.\n\n1. **Before headers** — the connect and first-byte timers apply.\n2. **After headers** — only the idle timer applies.\n3. **After the first body chunk** — a retry could replay bytes the caller already consumed.\n\nThe budget lives in `retry/budget.ts`; the contract is described in the [client guide](https://example.com/relay/client#timeouts)."},
      {"id": "WID:3", "role": "assistant",
       "metadata": {"acp": {"source": "live", "cursor": "c-003", "kind": "tool_call"}},
       "toolCalls": [
         {"id": "WID:t1", "type": "function", "x-sandbox": "workspace-write",
          "function": {"name": "shell", "arguments": "{\"detail\":\"$ pnpm test timeout --reporter=spec\",\"command\":[\"pnpm\",\"test\",\"timeout\",\"--reporter=spec\"],\"cwd\":\"/Users/sample/Developer/relay\",\"timeoutMs\":120000}"}},
         {"id": "WID:t2", "type": "function",
          "function": {"name": "read_file", "arguments": "{\"detail\":\"src/client/stream.ts\",\"path\":\"/Users/sample/Developer/relay/src/client/stream.ts\"}"}}
       ]},
      {"id": "WID:4", "role": "tool", "toolCallId": "WID:t1",
       "metadata": {"acp": {"source": "live", "cursor": "c-004", "kind": "tool_call_update"}, "exitCode": 0, "durationMs": 4812},
       "content": "✓ connect timeout retries inside the request budget\n✓ exhausted retries return the upstream timeout\n? partial response body · policy decision required\n\nsrc/client/timeout.test.ts  2 passed, 1 pending"},
      {"id": "WID:5", "role": "tool", "toolCallId": "WID:t2", "error": "ENOENT: no such file or directory",
       "content": ""},
      {"id": "WID:6", "role": "system",
       "content": "retry budget reloaded from config/retry.toml"},
      {"id": "WID:7", "role": "assistant",
       "metadata": {"acp": {"source": "live", "cursor": "c-007", "kind": "agent_message", "usage": {"used": 45210, "size": 200000}},
                    "x-trace": {"span": "7f3a91", "sampled": true}},
       "content": [
         {"type": "text", "text": "Pre-header retry is covered. Here is where each phase stands:\n\n| Phase | Retry | Evidence |\n| --- | --- | --- |\n| Before headers | Safe | `timeout.test.ts` |\n| After headers | Safe for idempotent calls | `stream.test.ts` |\n| After first chunk | **Ambiguous** | no test yet |\n\n```ts\nif (attempt.bytesDelivered > 0 && !request.idempotent) {\n  return RetryDecision.surface(error)\n}\n```"},
         {"type": "image", "mimeType": "image/png", "filename": "timeline.png",
          "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="}
       ]},
      {"id": "WID:8", "role": "user", "content": "Which case is ambiguous?"},
      {"id": "WID:9", "role": "assistant",
       "content": "Only the third: once body bytes have reached the caller, retrying can duplicate them. I've raised it as a request rather than choosing a default."}
    ]
    """#
}

/// Provider compactions for the sample conversation, so the Pretty compaction row can be reviewed
/// on the wall, the focused worker and the PiP without a service. Off unless asked for, beside
/// `AGENT_COMMANDER_PREVIEW_DISPLAY`:
///
///   AGENT_COMMANDER_PREVIEW_COMPACTION=1   append a notice and four compactions to every sample
///                                          conversation: finished with a summary, finished with
///                                          none, failed with an error, and still running
///
/// The messages have the shape the service sends for a negotiated ACP session: one `system`
/// message per compaction, replaced in place, with its identity and source cursor. The summary
/// and error are served as the SDK's `acp.compaction_state` snapshots through the production
/// page decoder and `CompactionSummaryStore`.
@MainActor
enum CompactionFixture {
    static let isRequested = ProcessInfo.processInfo.environment["AGENT_COMMANDER_PREVIEW_COMPACTION"] == "1"

    /// The store the preview's consoles read: each row's snapshot, by its exact cursor.
    static let store = CompactionSummaryStore { _, mark, _ in
        try SourcePage(envelope: Data(page(for: mark.cursor).utf8))
    }

    /// The source page for one row: the snapshot whose ID ends the cursor, or no record.
    nonisolated static func page(for cursor: String) -> String {
        let observations = snapshots.compactMap { id, body -> String? in
            guard cursor.hasSuffix(id) else { return nil }
            let data = Data(body.utf8).base64EncodedString()
            return #"{"cursor":"\#(cursor)","extension":{"type":"acp.compaction_state","mediaType":"application/json","data":"\#(data)"}}"#
        }
        return #"{"observations":[\#(observations.joined(separator: ","))]}"#
    }

    private nonisolated static let snapshots: [String: String] = [
        "cmp-1": #"{"compactionId":"cmp-1","status":"completed","firstOrdinal":12,"summary":[{"type":"text","text":"The developer asked for timeout coverage in three phases: before headers, after headers and after the first body chunk.\n\n"},{"type":"text","text":"Done so far: the timeout suite ran with 2 passed and 1 pending. Retry before headers is covered by timeout.test.ts.\n\nOpen: a retry after the first body chunk can duplicate bytes the caller already has. That case was raised as a request and waits for a decision."}]}"#,
        "cmp-2": #"{"compactionId":"cmp-2","status":"completed","firstOrdinal":15,"summary":[]}"#,
        "cmp-3": #"{"compactionId":"cmp-3","status":"failed","error":"The summary request exceeded the context window. Start a new session or clear earlier turns.","firstOrdinal":17,"summary":[]}"#
    ]

    static func messages(workerID: String) -> [AGUIMessage] {
        var json = template.replacingOccurrences(of: "WID", with: workerID)
        for id in ["cmp-1", "cmp-2", "cmp-3", "cmp-4"] {
            json = json.replacingOccurrences(of: "ID(\(id))", with: CompactionRecord.identity(of: id))
        }
        return (try? JSONDecoder().decode([AGUIMessage].self, from: Data(json.utf8))) ?? []
    }

    private static let template = #"""
    [
      {"id": "WID:10", "role": "system", "content": "[ACP notice] Context is almost full",
       "metadata": {"acp": {"source": "live", "cursor": "WID-notice-1", "turnId": "op-9", "kind": "notice"}}},
      {"id": "WID:11", "role": "system", "content": "Provider context compaction completed",
       "metadata": {"acp": {"source": "live", "cursor": "WID-cmp-1", "turnId": "op-9", "kind": "compaction_update",
                            "messageId": "ID(cmp-1)", "messageOp": "replace"}}},
      {"id": "WID:14", "role": "assistant",
       "content": "With the earlier turns compacted, I'll continue with the ambiguous case: the caller decides whether a partial body may be replayed."},
      {"id": "WID:15", "role": "system", "content": "Provider context compaction completed",
       "metadata": {"acp": {"source": "live", "cursor": "WID-cmp-2", "turnId": "op-9", "kind": "compaction_update",
                            "messageId": "ID(cmp-2)", "messageOp": "replace"}}},
      {"id": "WID:16", "role": "assistant", "content": "The provider sent no summary for that one."},
      {"id": "WID:17", "role": "system", "content": "Provider context compaction failed",
       "metadata": {"acp": {"source": "live", "cursor": "WID-cmp-3", "turnId": "op-9", "kind": "compaction_update",
                            "messageId": "ID(cmp-3)", "messageOp": "replace"}}},
      {"id": "WID:18", "role": "assistant", "content": "I'll keep working in the context that is left."},
      {"id": "WID:19", "role": "system", "content": "Provider context compaction in progress",
       "metadata": {"acp": {"source": "live", "cursor": "WID-cmp-4", "turnId": "op-9", "kind": "compaction_update",
                            "messageId": "ID(cmp-4)", "messageOp": "replace"}}}
    ]
    """#
}
