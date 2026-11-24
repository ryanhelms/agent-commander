# Frontend tool verification

## Local protocol and authorization

The integration suite runs the actual `agentctl mcp` stdio subprocess with a disposable worker. The MCP client discovers `select_document` in the definitions offered on an AG-UI run, invokes it with a folder argument and receives the literal app result as MCP text. The same result appears in a correlated AG-UI tool result event.

The hosted suite runs the same service workflow through direct HTTPS and through the outbound relay. It verifies missing tool scope, absent bridge capability, schema mismatch, wrong app and wrong worker, duplicate results, late results after lease handback, and denied access after grant revocation. It checks that an already resolved call is restored as conversation messages on reconnect. The Node connector suite exercises the real AG-UI JavaScript client with tool events and result submission.

Both hosted routes accept a document number of `9007199254740992` at the schema maximum and reject `9007199254740993` above it. In the stdio integration, a tool with no maximum receives `9007199254740993` from the real MCP subprocess and exposes the same integer in the AG-UI argument event. The bridge forwards the original JSON, and Commander validates 64-bit decimal integers without a float conversion. The assertion reads the argument JSON from the wire. [Hosted check](../../internal/service/hosted_test.go) · [Stdio MCP check](../../cmd/agentctl/integration_test.go)

With the installed 0.1.4 connector, a first client executed the tool and disconnected before submitting its result. A second client for the same app found the original ID and arguments in `state.unconfirmedToolCalls` and returned the recorded outcome. The real stdio MCP worker received it. Together the clients executed the app action once. A passive viewer can connect with `dispatchTools: false` before the first handler arrives. The service acknowledges that choice across both routes. [Connector contract](../../poc/agui-console/connector/README.md) · [Real client tests](../../poc/agui-console/commander-agent.test.mjs)

Canceling the originating MCP wait retires the identified call and persists a terminal result describing its uncertain app-side effect. A result that already committed wins the race. A failed HTTP poll preserves the app's ability to return the original result. The hosted tests repeated these cases with direct HTTPS and the outbound relay under the race detector. [Hosted tests](../../internal/service/hosted_test.go)

On both hosted transports, a short-lived access token expired while the original tool call was pending. The worker kept polling that call and could not issue a new one during the gap. An observe-only token received ordinary output without the app's invocation arguments. A second app and a token missing the original prompt scope could not resolve the call after expiry. A fully scoped token for the same app recovered the original call ID and delivered the result to the waiting worker. [Hosted regression tests](../../internal/service/hosted_test.go)

The hosted suite forced a result-store write failure and verified the worker still saw a pending invocation. Once accepted, the result survived a later turn and a service restart. The original app recovered the same arguments and result without a new tool invocation. The same result could be retried, and a different result conflicted. The record stayed outside workspace views and was unavailable to an observe-only token. A corrupt record produced an explicit gap. A different call that was unresolved when the service restarted stayed unconfirmed. [Durable result regression](../../internal/service/hosted_test.go)

```sh
AGENT_COMMANDER_TEST_INTEGRATION=1 go test -race -count=1 ./...
node --test poc/agui-console/commander-agent.test.mjs poc/agui-console/attached-console.test.mjs
```

## Live Claude ACP

A fresh service launched a real Claude ACP worker on a disposable workspace. After the initial assignment, the worker advertised its frontend MCP bridge and accepted an AG-UI follow-up with the `select_document` definition under the held input generation. The agent discovered the tool through `commander_frontend_tools`, invoked it through `commander_call_frontend`, and waited for the app result. The app submitted `CLAUDE_FRONTEND_TOOL_RESULT_84` to the original call. Claude reported that exact text through `commander_result`, and the operation finished. The worker record contained a native session binding.

## Live Codex ACP

A second disposable service launched a managed Codex worker under a real Claude coordinator, using the signed-in QA profile and the native Codex App Server. The first attempt initialized the native session and MCP bridge, then timed out in the initial assignment. A direct Codex prompt succeeded with the same QA sign-in. The managed retry used a minimal initial assignment and temporarily selected `gpt-6.1-sol` at low reasoning effort in the QA profile. Codex discovered and invoked the same `select_document` tool, reported the exact `CODEX_FRONTEND_TOOL_RESULT_84` result, and finished the AG-UI operation. The temporary model settings were removed after the run.
