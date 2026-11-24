# Live CopilotKit parity for Claude and Codex

## Opening archived prompt attachments

The reference console and a separately installed CopilotKit app opened the actual prompt image from one archived Claude session and one archived Codex session. Headless Chrome expanded the user message in **Provider history**, selected its attachment, and decoded the returned PNG. Each private response contained exactly the original record named by the message. Each PNG matched the original capture byte for byte.

| Provider | PNG bytes | Decoded dimensions | SHA-256 |
| --- | ---: | --- | --- |
| Claude | 110 | 48 × 32 | `8081d6e201249d84d7ba90404d771d2b8535b145b7659b0ceaf20c67f0f08615` |
| Codex | 108 | 48 × 32 | `64f4679f22790bbee77423ed181f22e0aee76a5d115f04f110064156c5c7f3d6` |

The same browser run replayed each archived AG-UI user message through the client’s reconnect stream and opened the attachment directly from the conversation. The recorded stream carried the original cursor and item count. All eight selections fetched the original from a running, isolated Commander service using its copied worker bindings. The run issued zero prompt submissions. The local Commander executable SHA-256 was `6e0e350cc9b474e3de4ca14c3dbb0d9209287b5b1d9d76865846cabd46673116` and the installed connector 0.1.6 archive SHA-256 was `39d822b9e24545a55393074c13585735f86a6204b6cdf83565e29603eb1f8ea2`. [Browser verifier](check-provider-media.mjs) · [Independent app setup](../../../examples/copilotkit/README.md)

To repeat, build the reference console and the independent example, start a disposable Commander service with the same native session bindings as the paired capture, then run the verifier with Playwright available. `CHROME_BIN` can select an installed Chromium executable and `PLAYWRIGHT_MODULE` can select an existing Playwright installation.

```sh
AGENT_COMMANDER_SOCKET="$QA_SOCKET" node design/verification/copilotkit-live/check-provider-media.mjs "$INSTALLED_EXAMPLE_DIR" "$CAPTURE"
```

## Recovering an interrupted observation

An independent Node app installed connector 0.1.5 from its local tarball, SHA-256 `e2fd5cc64c32f757e364b27020163ab6f3cc6c7db7bea56776e84674745e01af`. The original 0.1.4 client had resolved a run whose HTTP stream ended with the operation still processing. The new client rejected that stream with `CommanderIncompleteRunError` and the original run ID. The installed suite passed eight checks covering submission, resume, passive viewing, genuine terminal events and explicit detach. [Connector regression tests](../../../poc/agui-console/commander-agent.test.mjs)

With Commander’s local HTTPS gateway and outbound relay, an authorized app observed a real service operation, lost its worker grant while connected, and saw its observation end without a terminal event. The connector reported the incomplete run. The next receipt lookup returned HTTP 403. After the test developer restored the grant, a passive reconnect to the original run and operation IDs returned the completed state and one `RUN_FINISHED`. The test used a fixture worker and OAuth introspection service. [Grant revocation exercise](../../../internal/service/hosted_test.go)

Headless Chrome exercised the independent example against a local HTTP fixture. It showed **Outcome unconfirmed**, preserved the run ID across an access denial and page reload, then restored the operation with an observational GET. The service received exactly one submission. A separate fixture operation returned `RUN_ERROR` and the browser displayed its failure. The normal stdio fixture also passed with the installed package, including opening the original tool result while the question was pending and receiving the exact addressed answer. [Browser recovery exercise](check-interrupted.mjs) · [Tool and reply exercise](check-independent.mjs)

## Independent CopilotKit runtime on SDK 0.1.13

A separate Node project installed `@agent-commander/copilotkit` 0.1.4 from the local release tarball and `@copilotkit/core` and `@copilotkit/runtime` 1.90.0 from the npm cache. It ran outside the Commander checkout. Chrome used the public CopilotKit client to discover the agent, send the same literal prompt to Claude and Codex, inspect the real tool result and its original ACP record, and answer the pending question by ID. Each history lookup used the operation and source cursor carried by the tool message. Codex, the archive and the deterministic peer ran against Commander build `f8178137291282e891f9dcf7645fbf2ee3059debf552be5bcf7c44b03fdf5629`. The fresh Claude run used `640f0f42926dbb27fb3bbbfafb87e0f53fa397be4085c4241c9923b20576b920`. [Runnable example](../../../examples/copilotkit/README.md) · [Browser exercise](check-independent.mjs)

| Worker | Browser evidence |
| --- | --- |
| Real Codex | The `commander_ask` tool returned the same request ID that the browser answered. Chrome inspected `rawOutput.result.content` containing the literal fixture question and received `LAPIS-742` in assistant text. The network trace contained one runtime submission and one addressed reply. This run inspected the original after answering. A separate attempt to repeat the inspection while the question was pending stopped at the local Codex sign-in preflight timeout. |
| Deterministic stdio | The browser expanded the completed tool update and its original `rawOutput.marker` while the ACP permission was still pending, verified the request ID again, then replied and received the selected option in assistant text. |
| Real Claude archive | On a copied stopped-worker binding, Chrome expanded the archived Read result containing `PLUM-4761` and decoded the 48×32 PNG. All 110 bytes matched SHA-256 `8081d6e201249d84d7ba90404d771d2b8535b145b7659b0ceaf20c67f0f08615`. The browser used only GET requests, and the seven records matched the earlier genuine Claude capture. |
| Fresh Claude | Claude ACP 0.109.1 acknowledged `model=opus`. While the request was pending, Chrome opened the real `commander_ask` result and its original `rawOutput[0].text`. Both contained the question ID on the form. The browser submitted one reply addressed to that ID. Claude’s `commander_wait` result contained the same ID and answer, its final assistant text was exactly `LAPIS-742`, and ACP returned `end_turn`. [Captured fields and HTTP sequence](independent-claude-opus.json) |

The fresh Claude run used a disposable Commander service. A recording wrapper completed the synthetic setup assignment locally and forwarded the single browser prompt after the real adapter acknowledged Opus. The provider’s terminal response attributed 28,867 tokens to `claude-opus-5-5` and also listed `claude-haiku-5-5` with 1,232 input and 373 output tokens. The provider supplied no role for the Haiku entry. Commander selected only Opus for the session. An earlier independent Claude attempt had returned HTTP 429 before session creation. [Model acknowledgement and terminal response](independent-claude-opus.json)

With Playwright and Chromium available locally, the following command checks the independent app, first against the fixture. For a live test, set `AGENT_COMMANDER_SOCKET` and pass a disposable held worker ID in place of `--fixture`. Set `PLAYWRIGHT_MODULE` to an installed Playwright module and `CHROME_BIN` to a Chrome executable when they live outside the default lookup paths.

```sh
node design/verification/copilotkit-live/check-independent.mjs "$example_dir" --fixture
```

## Earlier real-session checks

The release build pinned Go SDK 0.1.4. It ran two real ACP workers in one disposable Commander service and tmux server. Claude Code 2.1.330 used the installed Fable model. Managed Codex CLI 0.171.0 used an isolated QA launcher with `gpt-6.1-sol` and low reasoning effort. The existing dedicated Codex profile supplied sign-in. The launcher left its permanent configuration unchanged.

The same Chrome workflow opened the attached reference console for each worker under its held input generation. From the follow-up field, it asked the worker to call `commander_ask` with an exact fixture question and wait. It opened the real tool result, found the live request by its exact ID, sent the fixture answer through the request card, and observed that answer on the resolved card and verbatim in the completed assistant reply.

| Harness | Pending request and disclosed tool result | Completed turn |
| --- | --- | --- |
| Claude | [Waiting](claude-waiting.png) | [Answered](claude-answered.png) |
| Codex | [Waiting](codex-waiting.png) | [Answered](codex-answered.png) |

An independent Node consumer then used the same connector for a second prompt on each worker. It inspected the tool-role message, replied to the pending request by ID, and received the exact answer in the assistant stream. The service retained exactly one addressed answer for each of the four requests.

A separate two-worker run submitted follow-ups over AG-UI and disconnected the observers. Each target reconnected by its original run and operation IDs and recovered its original pending request ID. Interrupting Claude closed only Claude's request and marked its operation interrupted. Codex kept its distinct pending request and accepted its exact answer. The same sequence passed with Codex as the target and Claude as the neighbor. After each interrupt, a new addressed turn completed in the target's original native session.

The live test exposed two integration defects. The conversation state originally dropped the answered request as soon as it stopped being pending. It now keeps recent answered and cancelled requests alongside the pending list, including after reconnect. Codex reported its real MCP result as `rawOutput.result.content`, so the SDK now previews those typed blocks when the ordinary ACP display content is absent. The complete source stays available through scoped history pages. Closing the attached console while waiting now aborts its observer connection. [State regression](../../../internal/service/agui_run_test.go) · [Attached console tests](../../../poc/agui-console/attached-console.test.mjs)

The connector was also packed as `@agent-commander/copilotkit@0.1.0` and installed in a separate consumer directory. The installed package passed its socket, HTTPS and tool-correlation tests and its declarations compiled in a TypeScript consumer. The archive SHA-256 is `bc08b3b4e4a539086937cd1d3631dc70606acec7f29560788628b0bc3bda9981`. [Connector package](../../../poc/agui-console/connector/README.md)

Version 0.1.1 passed the independent install, connector tests, and a strict TypeScript check of the resume API. A separate consumer submitted over direct HTTPS, detached while a deterministic ACP worker awaited permission, and resumed through the outbound relay under the same app principal. The AG-UI subscriber received the original request ID and the tool result. The client answered the permission once and fetched the original attachment bytes through scoped history. The ACP process recorded only one prompt. The archive SHA-256 is `7a375219c10c3277c97f097da6026727b492898266faedd74b70a396107fd4a7`. [Connector resume](../../../poc/agui-console/connector/README.md) · [Hosted route and scope checks](../../../internal/service/hosted_test.go)

The attached reference console reloaded in Chrome while a deterministic ACP worker awaited permission. The same request ID, tool result, and input status reappeared. The browser answered the request and reloaded the completed transcript. Both reconnects used the original run ID. The ACP fixture recorded one prompt and one addressed reply. A subsequent reload with a missing receipt displayed an error and cleared the stored ID. [Reload capture](reference-reload.png) · [Runtime checks](../../../poc/agui-console/attached-console.test.mjs)

The operation replay tests opened an earlier completed run while the same worker was processing a later prompt. The earlier result and resolved approval remained visible. The later turn's output and pending approval were absent over the owner socket, direct HTTPS, and the outbound relay. After console eviction, and after a native service restart reused the sequence numbers, the older operation showed a history gap. The browser reload scenario passed again with this service build. [Operation replay tests](../../../internal/service/agui_run_test.go) · [Hosted replay tests](../../../internal/service/hosted_test.go)

Connector 0.1.2 passed an independent install and strict TypeScript compilation for turn-scoped history. In headless Chrome, the reference console reloaded a completed fixture turn, opened **This turn’s ACP source**, and rendered its inline image. The fixture counted one prompt submission and one observational reconnect. An independently launched ACP fixture also recovered its image and audio through the original operation receipt. Direct HTTPS and outbound relay tests checked the same history grant before and after revocation. Interleaved records, cross-turn cursor rejection, and the restart gap are covered by the service tests. The archive SHA-256 is `10026514ccec8c78f8806e7395d078a7942e51c30ade47326ae51b5f6339fe5a`. [Console reload test](../../../poc/agui-console/attached-console.test.mjs) · [Live source tests](../../../internal/service/live_source_test.go) · [ACP fixture](../../../internal/provider/acp_profiles_test.go)

## Incremental worker streams

An independent Node project installed the local 0.1.3 package and connected to two real workers using SDK 0.1.7. It submitted a follow-up to each worker, observed the pending question in `agent.state`, and answered it by request ID. Claude delivered nine text messages as AG-UI start, content and end events, and Codex delivered 23. Eight Claude messages and 22 Codex messages carried ACP source cursors. Each observer received four state deltas. The terminal message lists included the ordinary tool results and exact assistant answers. Neither worker's ordinary tool calls triggered a frontend tool callback.

A fresh instance of the installed client resumed each completed operation by run ID. It received one state snapshot and one message snapshot. The reconstructed messages, source metadata, resolved request and operation state matched the original client exactly. The package also passed the installed-client tests and strict TypeScript compilation. Its archive SHA-256 is `00f04a733f37d1da79d9b5978edb5cd0d5e79d859fc9c6239690cf55e7cb4bf8`. The reference console's CopilotKit runtime forwarded the streamed text and cursor metadata on submit and reconnect. [Connector tests](../../../poc/agui-console/commander-agent.test.mjs) · [Reference console test](../../../poc/agui-console/attached-console.test.mjs)

The same release passed all four Claude/Codex and direct HTTPS/outbound relay combinations from a read-only Linux backend on the local test host. Keycloak issued authorization-code tokens using PKCE. Each turn streamed four state deltas. The Claude turns each delivered eight streamed text messages. Codex delivered 23 over direct HTTPS and 27 over the relay. Each app answered and recovered the original receipt through the opposite route. Both routes enforced revocation for both workers and continued serving the other app. The Linux relay recovered its connector after restart.

## Direct HTTPS and outbound relay

In a local two-worker test against SDK 0.1.7, the developer took control of Claude and Codex before their coordinator finished. Both workers completed a turn, then accepted simultaneous AG-UI follow-ups. Each returned its own literal marker and operation receipt from its original native session. Returning Claude's input left Codex available. Returning Codex's input completed the run. The reference console now bootstraps through the connector's worker summary, which reports native history availability and a generation for actionable held input. [Worker lifetime regression](../../../internal/service/control_test.go) · [Reference console regression](../../../poc/agui-console/attached-console.test.mjs)

An independent Node app installed the same package in its own directory and connected to disposable loopback HTTPS listeners with a fixture OAuth issuer. Two app identities had grants for the same Claude and Codex workers. After the owner took control once, the Node app sent a prompt, inspected the real harness tool result and submitted the addressed reply through the opposite route. The same app then recovered the run receipt, replayed the completed operation through that route and read the worker's scoped Live ACP source. The other app could observe the worker under its own grant and received HTTP 404 when it asked for the first app's receipt. Both harnesses completed with each listener as the submission route, for four completed turns. Ordinary harness tools appeared as AG-UI messages and emitted zero executable frontend tool events.

The workflow passed with a native relay and again with the standalone Linux arm64 relay in a read-only non-root container. The isolated Linux relay recovered its host association and authorized dispatch after restarting. The test covered the packaged client, real harness interaction, the authenticated gateway and the distributed relay binary on one computer. [Local relay deployment](../../RELAY-DEPLOYMENT.md)

An independently installed connector 0.1.2 then ran in a separate non-root, read-only Linux backend using Node 24.22.2. Its mounts held the consumer, test CA and two app tokens. Commander and the workers ran on macOS with SDK 0.1.7. Keycloak 26.6.4 issued both clients authorization-code tokens using PKCE for the same test developer. Each of four real Claude and Codex prompts produced a harness tool result and a pending question. The backend replied through the opposite route, checked the exact completed answer against the stream, recovered the same run and operation IDs, and replayed the result and turn-scoped Live source. After the owner revoked one app, its worker and history reads returned HTTP 403 on both routes for both workers. The other app still received HTTP 200. All deployments stayed on one computer. The public managed relay and a separately operated production issuer remain unverified. [Hosted client exercise](hosted-client.mjs) · [Local relay deployment](../../RELAY-DEPLOYMENT.md)

All four hosted answers spanned multiple adjacent assistant text chunks. The reference timeline now joins only adjacent live ACP assistant text with matching turn and message identity. It preserves the first chunk’s stable display ID, all contributing AG-UI IDs, and the exact text, including whitespace. An additional replay of the Color Studio operation snapshots produced a 103-character Claude reply from six records and a 57-character Codex reply from 18 records. Each kept its corresponding tool result. [Timeline model and boundary tests](../../../poc/agui-console/ui/model/contract.test.mjs)

### Running the independent backend check

Install the packaged connector in a separate Node 22+ project and copy the hosted client exercise alongside its `package.json`. Supply the direct and relay HTTPS origins and the IDs of two held test workers, Claude first and Codex second. The exercise sends four real prompts and answers their four requests. Each origin must resolve in the backend environment. [Consumer exercise](hosted-client.mjs) · [Connector packaging](../../../poc/agui-console/connector/README.md)

Give two distinct app clients grants for the same developer and both workers, with `commander:observe`, `commander:prompt`, `commander:reply`, and `commander:history`. Mount their access tokens in a private JSON file with properties `direct` and `relay`. The backend uses the submission app's token when replying through the opposite route. It also checks that the other app receives HTTP 404 for that operation. The TLS trust file is necessary when using a private CA.

```sh
COMMANDER_APP_TOKENS=/run/tokens NODE_EXTRA_CA_CERTS=/run/ca.pem \
  node hosted-client.mjs "$DIRECT_ORIGIN" "$RELAY_ORIGIN" "$CLAUDE_WORKER" "$CODEX_WORKER"
```
