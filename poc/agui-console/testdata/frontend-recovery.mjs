// Driven by TestLocalMCPPlanningRun against the actual MCP and Go service.
import assert from 'node:assert/strict';
const { connectCommanderWorker } = await import(process.env.AGENT_COMMANDER_TEST_CONNECTOR_MODULE ?? '../connector/commander-agent.mjs');

const [socketPath, workerId, runId] = process.argv.slice(2);
const first = connectCommanderWorker({ socketPath, workerId });
const link = new AbortController();
const invoked = Promise.withResolvers();
let executions = 0;
const watching = first.resume({ runId, signal: link.signal }, {
  onStateSnapshotEvent() { console.log('ready'); },
  onToolCallEndEvent({ event, toolCallName, toolCallArgs }) {
    assert.equal(toolCallName, 'select_document');
    assert.deepEqual(toolCallArgs, { folder: 'reconnect' });
    executions++;
    // The app completed the action, then lost its connection before submitting.
    invoked.resolve({ operationId: event.metadata.commanderOperationId, toolCallId: event.toolCallId });
  },
}).catch(error => { if (!link.signal.aborted) throw error; });
const chosen = await invoked.promise;
link.abort();
await watching;

const next = connectCommanderWorker({ socketPath, workerId });
let recovered = false;
await next.resume({ runId }, {
  async onStateSnapshotEvent({ event }) {
    const { operationId, unconfirmedToolCalls } = event.snapshot;
    assert.equal(operationId, chosen.operationId);
    assert.deepEqual(unconfirmedToolCalls, [{ id: chosen.toolCallId, name: 'select_document', arguments: { folder: 'reconnect' } }]);
    const ack = await next.submitToolResult({ operationId, message: {
      id: 'reconciled-result', role: 'tool', toolCallId: chosen.toolCallId, content: 'reconciled selection',
    } });
    assert.equal(ack.status, 200);
    recovered = true;
  },
  onToolCallEndEvent() { executions++; },
});
assert.equal(executions, 1);
assert.ok(recovered);
assert.equal(next.agent.state.unconfirmedToolCalls, undefined);
assert.ok(next.agent.messages.some(message => message.toolCallId === chosen.toolCallId && message.content === 'reconciled selection'));
