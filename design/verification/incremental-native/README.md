# Native Claude and Codex conversation verification

Two managed workers ran in the same local Commander workspace on November 23, 2026. Claude Code 2.1.330 received a purple PNG and used Read to retrieve `PLUM-4761`. Codex CLI 0.171.0 received a teal PNG, asked for its receipt code through Commander and obtained `CEDAR-47291` from the correlated `commander_wait` result. The QA driver answered that request from a local fixture file. Both workers identified their swatch and reported the correct code.

| Capture before the display-check follow-up | Claude | Codex |
| --- | ---: | ---: |
| Retained live ACP records | 26 | 64 |
| Provider history records | 7 | 11 |
| Supplemental journal records | 14 | 42 |
| Exact bytes in the user message’s PNG | 110 | 108 |

Each user message carried its own turn and source cursor. Opening the attachment made a worker-scoped history request with `source=live`, that `turnId` and `kind=acp.prompt_part`. Both requests returned exactly one record with the original cursor and byte-identical PNG. The Claude Read entry preserved three contributing ACP cursors in order.

## Field comparison

An independent reference reducer applied the initial workspace snapshot and 71 JSON Patch deltas. The native reducer matched its expected state after every frame. Each display mode made all 105 original AG-UI messages and 718 message field values reachable through 52 displayed entries. Across six joined assistant turns, both modes reproduced the text of all 55 contributing chunks exactly, including whitespace.

The native source inspector's expanded record uses the same field rows in both modes. The comparison read its actual record model, traversed its fields, and compared field paths and values with the captured source responses. Across the 164 records above, it matched all 3,716 values, including decoded JSON extensions. All 37 long string values could be reconstructed from the expanded text, including a 35,464-character value. Seven records contained the supplied PNGs across the six history sources. Codex recorded the image in two journal shapes.

Across three independently captured Claude/Codex pairs, the same check matched 13,735 values in 621 source records and recovered the exact PNG bytes in all 21 media-bearing records. These counts cover conversation data available through the selected worker’s live, provider and supported journal readers. Retention gaps have an explicit UI state. The original transcripts and private session credentials stay out of this repository.

## Native interaction

macOS Accessibility operated the running app on its private QA socket. For each worker, the test opened its tool result and used **View attachment** directly on its user message in both modes. The attachment disclosure showed the raster image, its MIME type and byte count. Its fields exposed the decoded prompt part and original observation. In the Codex worker's Live source tab, the test opened the command list and scrolled to `availableCommands[82].name` to read the final command beyond the old 6,000-character cutoff.

An additional prompt arrived while Codex was open in Console and while Claude was open in Pretty. For each worker, the same submitted prompt and the completed reply, “Swatch delivery confirmed”, appeared after switching modes. The QA workspace used two workers and the existing coordinator/focused-worker split. Pretty used the supplied chat reference for its trailing user bubbles and leading assistant prose. [Claude conversation](claude-pretty-chat.png) · [Approved focus composition](../../concepts/focused-worker.png)

| Harness | Pretty | Console |
| --- | --- | --- |
| Claude | [Purple PNG opened from the prompt](claude-pretty-attachment.png) | [Expanded Read result](claude-console-tool.png) |
| Codex | [Expanded Commander wait result](codex-pretty-tool.png) | [Teal PNG and joined terminal text](codex-console-attachment.png) |

## Pending-request rendering

A live cold launch with a pending coordinator request saturated one CPU core and stopped answering accessibility queries. Pausing the QA window’s feed reader for six seconds left CPU at 99%. A frozen snapshot of the same run reproduced a smaller steady rendering cost with the request present.

The corrected build animates the waiting border and shadows in Core Animation. With the request still pending, Accessibility opened both workers, switched display modes and operated tool and attachment disclosures. During a subsequent 12.1-second idle observation, the app consumed 0.02 CPU seconds and a separate feed reader observed one initial snapshot and zero deltas. This measures idle behavior on the verification Mac.

In a separate QA window, expanding a restored Pi tool result coincided with a foreground Console stall. Two process samples found repeated native layout and selection work at 94–99% CPU. In a matched offscreen comparison, the original and experimental builds both paged 21 real provider observations, opened the record, expanded and selected the Console result and stayed responsive. The candidate scroll change was withdrawn. Reproducing the foreground stall remains open.

## Repeating the checks

Run `make test-native` for the native regression suite. Set `COMMANDER_AGUI_REPLAY` to a private JSONL capture containing the AG-UI frame in `event` and its independently reduced workspace in `expected` on each line to include real stream replay. Use `python3 packaging/go-with-sdk.py dist/sdk/agent-acp-0.1.13 test -race ./...` for the backend suite. The local ACP/tmux integration test also accepts `AGENT_COMMANDER_TEST_TMUX=1` and exercises mixed text, image and audio delivery. [Native replay test](../../../Tests/AgentCommanderTests/NativeCaptureReplayTests.swift) · [ACP runner integration test](../../../internal/provider/acp_profiles_test.go)
