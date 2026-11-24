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
        let messages = (try? JSONDecoder().decode([AGUIMessage].self, from: Data(json.utf8))) ?? []
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
