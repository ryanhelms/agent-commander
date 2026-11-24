# Synthetic transcript coverage

## Cold provider records

The 0.1.9 SDK returned 16 original JSON records for the two selected Color Studio workers. All 152 Claude and 121 Codex scalar values matched the native provider responses, including UUIDs, timestamps, tool status, app context and result fields. Each image matched the original PNG. A second read through a cold Commander service used one observation per page to check the source cursors across page boundaries. The two workers shared a checkout. [SDK and original-record comparison](../sdk-release/README.md)

Both native renderers use those cursors to reach the originating provider record. For Codex, one retained MCP item can include the call ID, arguments and result together. Commander projects that evidence into the call and result roles used by the tool disclosure. Standalone output retains its own result identity. In the running CopilotKit reference console, the Codex wait disclosure exposed its receipt, duration and app context, and the image record rendered the teal PNG. [Native replay test](../../../Tests/AgentCommanderTests/ProviderRecoveryTests.swift) · [Codex projection](../../../internal/provider/history.go)

To repeat the native check on an isolated service restored from the Color Studio run, supply the two worker IDs and the original swatch files. The private capture includes the selected workers' conversation data.

```sh
python3 design/verification/transcript-coverage/capture-provider-replay.py \
  --socket "$QA_SOCKET" --source provider --require-provider-media \
  --claude "$CLAUDE_WORKER" --codex "$CODEX_WORKER" \
  --claude-png "$PLUM_PNG" --codex-png "$TEAL_PNG" --output "$PRIVATE_CAPTURE"
COMMANDER_PROVIDER_REPLAY="$PRIVATE_CAPTURE" make test-native
```

The attachment check follows the reference on each recovered AG-UI user message through its worker's history endpoint. It requires the response to contain the one addressed record, checks the PNG against the original swatch and saves that response for the Swift replay. The native test exercises the same prompt action in Pretty and Console. [Capture](capture-provider-replay.py) · [Native replay](../../../Tests/AgentCommanderTests/ProviderRecoveryTests.swift)

## Journal and live fixtures

The November 23, 2026 local inventory covered 358,936 Codex rollout records and 174,972 Claude journals, with separate live capture audits. These fixtures use synthetic content and keep those source formats distinct. Their record shapes are evidence for what a harness can expose. The available fields may differ by harness version and transport.

| Layer and fixture | Fields represented | Pretty | Console | Source and remaining coverage |
| --- | --- | --- | --- | --- |
| [Claude saved journal](claude-journal.jsonl) | Tool input, multipart error, embedded image, tool reference, provider result summary, unfamiliar tool-use member and separate attachment | Open the result for text the Claude history API returns. SDK extensions can appear as passive output. | The recovered history tail includes the tool result. | A worker-scoped journal page preserves the original conversation record, including the result summary and attachment. The reference console can open the source separately. |
| [Codex saved rollout](codex-rollout.jsonl) | Typed call arguments, displaced tool output, image, tool failure, duration, provider-visible reasoning summary and opaque encrypted payload | Open the tool row for results the Codex history API returns. Unrecognized App Server items can appear as passive output. | The recovered history tail includes tool summaries and supported source events. | A worker-scoped journal page complements App Server with the original result and response items. The reference console can open the source separately. |
| [Claude stream-json stdout](claude-stdout.jsonl) | Partial stream wrapper, final tool call, multipart error, image descriptor and result envelope | Open the failed tool row to see text parts and the media type. Unmatched partial assistant text uses the ordinary conversation view. | The same failed result, descriptor and recovered assistant text appear in terminal text. | The legacy reader recovers text when a complete assistant envelope is missing. It keeps ordinary complete envelopes and shows their streamed text once. The regression exercises partial text, nested source isolation and the multipart error through the actual reader. |
| [Codex exec stdout](codex-stdout.jsonl) | Started, updated and completed command snapshots, aggregated output and exit code | Managed Codex uses ACP. | Managed Codex uses ACP. | The native stdout fixture records the separate CLI shape. Its presence does not prove that ACP or App Server exposed identical fields. |
| [ACP session updates](acp-updates.jsonl) | Initial tool, unnamed progress, failure, text, resource URI and MIME type, image descriptor, unfamiliar content type and an extra update member | Open the tool row for progress and the failed result. | Progress and the same failed result appear in terminal text. | The selected worker's `source=live` pages preserve raw tool input/output, unfamiliar members, and original inline bytes. The reference console exposes these pages in **Live ACP source**. |
| [Stock ACP session replay](../stock-acp.md) | Retained user and assistant text, completed call, raw input and provider updates | The stopped worker's restored transcript shows the completed call and assistant output. | The stopped worker's restored console shows the same conversation. | The Provider source pages expose the original replay fields. Antigravity did not supply tool result bytes in the live or replayed tool record. |
| [Normalized AG-UI input](console-events.json) | Repeated assistant text, orphan result, repeated tool ID across workers, progress and title correction, multipart failure, opaque payload and history gap | Repeated turns remain distinct. Open the failed tool row for both progress updates and result parts. The orphan result and source gap remain visible. | The same records and failure status are available in the structured Console. Raw opaque provider extensions and gap text also enter the bounded console tail. | A Go regression checks worker-scoped message and call identities. Computer Use verified the exact fixture in both modes against the local service. [Console](native-console.png) · [Pretty](native-pretty.png) |

The tool and message fixtures distinguish omissions from projection failures. If the source transport did not emit a field, its absence from that view cannot be diagnosed by comparing text alone. When the field is in the test input but missing from the output, the corresponding adapter or projection has a gap. Large inline content follows the preview bounds. A descriptor in the preview is separate from retrieving the bytes from a scoped history source.

## Local journal verification

The journal reader recognizes Claude Code 2.1 conversation records and Codex CLI 0.169 and 0.171 rollout formats. It accepts conversation content and tool records, checks the recorded checkout and session, and pages complete records up to 1 MiB. It skips recognized operational snapshots and reports unsupported formats, incomplete records and other gaps. The file is opened read-only. Tests exercise two sessions in one checkout, cursor isolation, a replaced source, a symlinked source and byte-for-byte source preservation.

The 0.1.13 acceptance run restored two Claude and two Codex bindings in one disposable checkout. In both native display modes, the owner read each worker’s Journal one record per page. The native field reader recovered every scalar in the selected records, and the image reader decoded each worker’s distinct 2 × 2 PNG. An unsupported Claude version or unfamiliar Codex record produced its explicit gap. Each worker’s existing ACP text remained visible after the gap, and a page cursor from its neighboring session was rejected. All four files were byte-identical after the eight inspections. [Fixture and service runner](verify-journal.py) · [Native acceptance test](../../../Tests/AgentCommanderTests/JournalFallbackTests.swift)

```sh
python3 -B design/verification/transcript-coverage/verify-journal.py --agentctl dist/agentctl
```

In a separate native app window, Computer Use opened **Inspect Source… → Journal → Show the original record** on a Claude worker and a Codex worker in both Pretty and Console. Each inspector exposed the exact integer `9007199254740993` and the explicit `null` alongside the worker’s ACP conversation. Claude’s tool result contained the partial read and its error flag. Codex’s `function_call_output` included text and an inline PNG. The Journal list identified the unsupported Claude version and the unrecognized Codex record. [Original Codex record](journal-codex-pretty-original.jpg) · [Codex format gap](journal-codex-pretty-gap.jpg)

The pinned Commander build read a disposable Claude Code 2.1.330 run through both its supported history API and the supplementary journal. The journal returned 14 records and contained the exact file-read marker. A managed Codex 0.171.0 worker produced five native custom-tool results before the smoke run stopped it for exceeding the initial assignment timeout. After restarting Commander, the supported App Server read returned observations, and supplementary paging recovered 36 records including all five results with the same worker's persisted session identity. Neither journal reported a format gap in those runs.

The attached CopilotKit server exercises the owner-scoped route and rejects browser requests without the local session cookie. The independent connector submits the same worker-bound route over HTTPS using the hosted app's history grant. In isolated Chrome, opening **Session journal** loaded the first page, opening the attachment showed its original JSON, and the paging controls moved to a fixture format gap and back. [Reference console capture](reference-journal.png)

The same browser opened **Provider history** on the real stopped Antigravity worker after restarting the local Commander service. It displayed the completed file call, its original ACP input, and the literal retained assistant output. The stopped worker had no composer. [Retained provider replay](reference-provider-replay.png)

The Swift cockpit shares the inspector across console modes. A local native fixture verified all three source tabs from the Console wall, the live source in focused Pretty, and the PiP action that opens the asking worker's inspector while its permission remains pending. [Native source verification](../native-source/README.md)

For the normalized fixture, the local service ingested the records through its worker output API. The native client showed both repeated sentences, a result whose call had expired, the corrected tool name, both progress fragments, the two result parts, the opaque payload and the explicit history gap. A second worker reused the tool ID with distinct progress. Its progress stayed out of the first worker's focused console. Before the fix, the disclosure showed failure text while the row labeled the call done. The Swift row now uses the typed error and announces the failure in both modes. The captures preserve the approved coordinator split and worker breadcrumb. The synthetic fixture shows an idle input area where the approved concept shows an active request and composer. [Approved focus](../../concepts/focused-worker.png)

The installed Claude CLI also emitted a sequence with text deltas, a complete assistant envelope and a final result. The legacy renderer replayed the capture and emitted the synthetic text once in the terminal and once as a structured console event. Separate regressions recover text when a message or stream ends without its complete envelope and keep nested tool streams apart. [Claude streaming events](https://platform.claude.com/docs/en/build-with-claude/streaming)

The attached web reference console displayed a distinct tool error with its partial output, kept declined, cancelled and interrupted statuses distinct, and kept an error-only orphan visible. The isolated demo now polls the same Go message projection. In Chrome, the real Claude demo showed its file result, accepted the addressed reply and displayed the literal answer before completing. [Web console capture](reference-tool-errors.png)

## Live ACP source

In SDK 0.1.12 the scoped source retains the complete parameters of `session/update` when a peer supplies additional properties beside `sessionId` and `update`. A normalized text or tool event can carry a `sourceRecord`; a passive record can carry an `extension`. A selected-session stdio worker sent three active updates and three between turns. In both native display modes all six source cursors resolved from the corresponding console entry and the inspected fields preserved the nested values, the exact integer `9007199254740993`, the absent and null updates, and the tool result's PNG bytes. The installed CopilotKit connector served all six to a running reference console, which displayed the original JSON and the inline PNG. [Native regression](../../../Tests/AgentCommanderTests/ProviderRecoveryTests.swift) · [Reference browser verification](../../../poc/agui-console/README.md)

```sh
python3 -B design/verification/transcript-coverage/capture-update-params.py --agentctl dist/agentctl --output "$PRIVATE_PARAMS_CAPTURE"
COMMANDER_UPDATE_PARAMS_REPLAY="$PRIVATE_PARAMS_CAPTURE" make test-native
```

A second pair of real Claude and Codex workers ran with SDK 0.1.10. All four completed prompts returned ACP `stopReason`, `usage` and `_meta` with provider quota fields. Codex also returned `thoughtTokens`. Each completion has its own source cursor in the incremental workspace feed. The native replay checks the displayed Pretty and Console entries against the complete returned JSON. Both workers’ prompt images again matched their original bytes.

An earlier Codex run had 67 retained records and one missing source for a visible text chunk. Holding the upload response open while an ACP peer supplied 67 rich updates reproduced the loss: 9 originals arrived. After changing the runner's queue and upload batching, the same regression delivered 67 originals in order across five race-detector repetitions, including an acknowledged retry and an older service that accepts only individual records. A fresh pair of two-turn conversations resolved all 31 Claude and 66 Codex source links from the incremental workspace, with zero gaps among 32 and 67 retained records respectively. The native renderers recovered the 85 field values from the four prompt outcomes and both PNGs matched their original bytes. [Delivery regression](../../../internal/provider/acp_source_delivery_test.go) · [Queue boundaries](../../../internal/provider/source_queue_test.go)

To repeat the live method check after both workers finish on the same service, capture their Live source and pass it to the native test. Historical sessions opened in an earlier version can have a different set of available records.

```sh
python3 design/verification/transcript-coverage/capture-provider-replay.py --source live --require-complete-live \
  --socket "$QA_SOCKET" --claude "$CLAUDE_WORKER" --codex "$CODEX_WORKER" --output "$PRIVATE_LIVE_CAPTURE"
COMMANDER_LIVE_METHOD_REPLAY="$PRIVATE_LIVE_CAPTURE" make test-native
```

A standard ACP subprocess fixture supplied a tool argument, a provider revision, and one-time and persistent options in a permission request. The live source retained all of them. Only the one-time choice was actionable. The completion's vendor metadata and usage stayed in that worker's inspected record. Transport errors where the ACP client cannot establish a peer origin have a generic terminal status. [Go integration test](../../../internal/provider/acp_profiles_test.go) · [Native field checks](../../../Tests/AgentCommanderTests/ProviderRecoveryTests.swift)

SDK 0.1.10 captures the selected permission method’s parameters and a successful prompt’s result. Its upstream connection gives the method handler the method name and parameters. The JSON-RPC envelope ID and extra members on a peer error object are unavailable through this callback. The live session-update callback receives the inner `update` object. Additional members beside `update` on the outer parameters remain a coverage gap in this release. [Pinned ACP connection API](https://pkg.go.dev/github.com/coder/acp-go-sdk@v0.20.0#MethodHandler)

SDK 0.1.13 uses the independently versioned ACP transport 0.1.0. A private Commander worker exercise sent an extended notification, a permission request with ID `9007199254740993`, an extended prompt result and genuine peer errors with codes `-32603` and `-32800`. All five returned their envelope properties and original payload under their own worker’s live cursor in AG-UI and both native displays. A fifth worker disconnected before answering and had no peer receipt. The public workspace and foreign worker history did not contain the private properties. An already matched reply survives a subsequent EOF or cancellation under notification backpressure. [Private stdio exercise](capture-update-params.py) · [Both native inspectors](../../../Tests/AgentCommanderTests/ProviderRecoveryTests.swift) · [Transport release](../sdk-release/README.md#independent-go-transport)

```sh
python3 design/verification/transcript-coverage/capture-update-params.py --require-wire \
  --agentctl dist/agentctl --output "$PRIVATE_WIRE_CAPTURE"
COMMANDER_WIRE_REPLAY="$PRIVATE_WIRE_CAPTURE" COMMANDER_UPDATE_PARAMS_REPLAY="$PRIVATE_WIRE_CAPTURE" make test-native
```

On SDK 0.1.13 a fresh Codex session completed two turns. Its 66 AG-UI references resolved against 67 retained originals. Each prompt result included its matched wire ID, usage and provider metadata. The tool result and exact 108-byte PNG were present. On the preceding fresh Claude attempt the provider returned HTTP 429 during session creation. SDK 0.1.13 recovered seven originals from the existing real Claude session and eleven from Codex, including both attachments.

A registered ACP peer received a seven-block prompt containing text, an image, an empty text block, two identical whitespace-sensitive text blocks, audio and trailing text. Reading the turn source one record per page reproduced all seven ACP blocks, including their positions and values. The attachment filter returned just the image and audio. The AG-UI workspace preview kept their bytes private. [Mixed prompt regression](../../../internal/provider/acp_profiles_test.go)

The executable ACP fixture runs through the actual Commander tmux runner. It sends ordinary tool updates, an update for the wrong session, and an additional record with 420,006 decoded bytes of inline image data. The test inspects the complete encoded attachment, raw tool input/output and an unfamiliar update member through the selected worker's history endpoint. The console preview keeps the tool status and image descriptor. Source records keep the validated SDK cursor and turn ID. [Tmux test](../../../internal/provider/acp_profiles_test.go) · [ACP v1 content blocks](https://agentclientprotocol.com/protocol/v1/content)

SDK 0.1.7 also exercised a completed ACP call with a direct MCP `isError` result, partial text, structured output and embedded audio. A second completed call carried ACP display content alongside a JSON-RPC error. Both calls reached the structured console as failed with their partial output. The terminal preview included the failure, text and media descriptor. The source kept the exact structured object, error data and audio bytes. SDK tests checked the same normalization through passive ACP replay. [Pinned SDK evidence](../sdk-release/README.md#candidate-evidence) · [MCP tool errors](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#error-handling) · [ACP tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls)

The live source is retained in memory. Commander reports gaps for dropped updates, an evicted prefix or an unavailable source window. The current bounds are 720 KiB per original update, 256 records or 4 MiB per worker, and 32 MiB across up to 64 worker windows. Ordinary assistant text chunks already represented in the live conversation use the usual preview path. The vendor history sources continue to supply retained history independently. [Authorization and paging tests](../../../internal/service/live_source_test.go)

In isolated Chrome, the reference console displayed the original tool result alongside an inline PNG. The fixture's external image URI and unsupported SVG stayed visible in the original record as text. [Live source console capture](reference-live-source.png)

## Verification commands

```sh
go test ./internal/service -run 'TestAGUITranscriptFixture|TestAGUIWorkspaceStream'
AGENT_COMMANDER_TEST_TMUX=1 go test ./internal/provider -run 'TestRegisteredACPExecutableEndToEnd|TestClaudeStdoutFixture'
go test ./internal/provider ./internal/service -run 'TestVendorJournal|TestNativeHistoryPage'
```

The sibling SDK runtime suite checks ACP resource descriptors, bounded Unicode previews and the absence of raw peer output in those previews. [ACP content contract](https://agentclientprotocol.com/protocol/v1/content)

## Real session originals in SDK 0.1.14

A fresh local service recovered the two completed Color Studio sessions one observation at a time. The Claude API supplied six original messages. Codex supplied eleven original records across items, turn metadata and the complete selected `thread/read` result. These produced seven Claude and twelve Codex display observations. A separate read through each vendor API matched every JSON value, including the tool receipts, both original PNGs and the additional thread properties. Both native modes opened every original from its conversation reference and matched every decoded field. [Independent comparison](compare-provider-originals.py) · [Both native modes](../../../Tests/AgentCommanderTests/ProviderRecoveryTests.swift)

The mutable-turn regression appends a Codex item after a client has saved the trailing metadata cursor. A mismatched original now returns a session-scoped gap. An earlier, unchanged message still leads to the appended item. A change solely to an unmodeled integer above JavaScript’s safe integer limit also invalidates the cursor. A Go microbenchmark on the local Apple M5 hashed a four-MiB original in one or 512 display blocks at 280 B and six allocations per operation in both cases. Three runs measured 6.0–7.9 ms and 5.3–11.8 ms respectively. Those timings measure the cursor witness alone.

To repeat the independent comparison on a settled session, provide the cold capture made above and the same local provider installation and profile.

```sh
python3 design/verification/transcript-coverage/compare-provider-originals.py "$PRIVATE_CAPTURE" \
  --claude-project "$PROJECT_DIR" --claude-sdk-anchor "$HARNESS_DIR/package.json" \
  --codex "$CODEX_EXECUTABLE" --codex-profile "$MANAGED_CODEX_PROFILE"
```

### Opening an archived attachment in the installed cockpit

The installed Agent Commander reopened the completed Color Studio run in a single window. In each display mode, the **View attachment** button under Claude's swatch prompt opened the original 110-byte PNG. The same button under Codex's prompt opened its 108-byte PNG. Both inspectors identified **Provider history** as the source. The installed service returned bytes identical to the two original files. The shared workspace sent the prompt text and the attachment reference. Image data was fetched when the button was opened.

In each mode, expanding Claude's **Read** row showed `PLUM-4761` from the file. Expanding Codex's **commander_wait** showed the answered request and `CEDAR-47291`. The window was returned to Pretty with both tools collapsed. The two restored workers use the standard wall split and right-aligned user bubbles. The coordinator column shows its unavailable state because the recovered run has no coordinator binding. [Installed window](restored-pretty.jpg) · [Archived attachment test](../../../Tests/AgentCommanderTests/ProviderRecoveryTests.swift)
