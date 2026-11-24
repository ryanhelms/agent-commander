# Agent Commander connector

Use this Node package from a CopilotKit backend or an AG-UI consumer. A connector addresses one existing Commander worker. Give a local backend the owner socket. Give a hosted backend the developer's HTTPS or relay origin and an access-token function for that app's worker grant.

```js
import { connectCommanderWorker } from '@agent-commander/copilotkit';

const worker = connectCommanderWorker({ baseURL, getAccessToken, workerId });
const result = await worker.workerInfo();
if (!result.ok) throw new Error(`Cannot open worker (${result.status})`);
const { generation } = await result.json();
if (generation === undefined) throw new Error('Take input control in Commander.');

const id = crypto.randomUUID();
worker.agent.addMessage({ id, role: 'user', content: prompt });
await worker.agent.runAgent({ runId: id, forwardedProps: { generation } });
```

For CopilotKit, register `worker.agent` in your backend runtime's `agents` map. While the run streams, use its state to find pending requests and call `worker.reply` with the exact request ID, answer, and held generation. Inspect scoped source details with `worker.readHistory`. The optional connection signal ends outstanding requests when the owning app closes.

Version 0.1.3 requests incremental AG-UI delivery on submission and reconnect. The standard AG-UI client applies `STATE_SNAPSHOT` and `STATE_DELTA` to `worker.agent.state` and updates `worker.agent.messages` from message snapshots and streamed text, including ACP source metadata. A raw `worker.observe` consumer must process these events to follow a live run. Existing Commander services that ignore the projection parameter continue to send snapshots.

To inspect a resumed turn, call `worker.readHistory({ source: 'live', turnId: worker.agent.state.operationId })` after `resume`. Reuse that turn ID when passing the returned `nextCursor`. Hosted apps need the worker's `commander:history` grant. If the records have expired or Commander has restarted, Live source reports a gap. Provider history and the session journal remain available according to the harness's retention policy.

After an interruption, keep the original submitted run ID and call `worker.resume({ runId, signal })`. Subscribe before calling resume to receive restored state, messages, and pending tool events. You can also pass a subscriber as the second argument. If the prior stream is still attached, detach it with `worker.agent.detachActiveRun()` first. Resume uses the receipt and observation routes for the same worker and app principal. It fails when the receipt is missing or the app's access has expired. The lower-level `worker.findOperation` and `worker.observe` methods remain available for consumers that apply their own stream.

An authorized tool handler can execute an invocation when it receives `onToolCallEndEvent`. Keep the returned call ID, operation ID and the result of any external action. Commander attempts executable delivery to one connection per call. If a connection might already have received an unresolved call, another observer receives its ID, name and arguments under `agent.state.unconfirmedToolCalls`. Check the original app or provider for the outcome and submit the confirmed tool message with `worker.submitToolResult`. If the outcome is unknown, continue to report it as unconfirmed. An identical accepted result can be retried.

Version 0.1.4 supports `dispatchTools: false` on `resume` and `observe` for a dashboard or additional viewer. This requires matching Commander service and relay support. The connector checks that the service acknowledged passive observation before exposing the stream. A tool-capable app can still receive the first invocation when it connects later.

Version 0.1.5 checks for an AG-UI terminal event on submission and reconnect. If HTTP closes cleanly before one arrives, the run promise rejects with `CommanderIncompleteRunError`. The error carries the submitted `runId`. This can happen when a hosted grant expires or is revoked during a run. After access is restored, call `worker.resume({ runId, dispatchTools: false })` to reconcile the original operation without dispatching another tool. Intentional `detachActiveRun()` still resolves normally. A real `RUN_ERROR` is delivered through the regular AG-UI subscriber.

`worker.observeRun({ runId, dispatchTools: false, signal })` looks up the receipt and returns the raw observation response for an HTTP bridge. Consumers of that raw SSE stream should wait for `RUN_FINISHED` or `RUN_ERROR` before treating the operation as settled.

The release candidate can be packed from this directory with `npm pack --ignore-scripts` and installed in a separate project using the resulting tarball.

Version 0.1.6 supports attachments on restored user messages. Pass the message’s `metadata.acp` to `providerPromptReference` from the browser-safe `@agent-commander/copilotkit/provider-media` export. To open the attachments, call `worker.readHistory({ source: 'provider', recordCursor: ref.cursor, cursor: ref.pageCursor })` under the same worker and history grant. Pass the resulting page to `selectedProviderMedia(page, ref)`. Each entry corresponds to one media part in the original user prompt. `preview` contains an inline image or audio data URL and `reference` contains an unfetched provider URL or path. A missing original produces an explicit error from the selected record's gap. The source payload stays in the private history response.
