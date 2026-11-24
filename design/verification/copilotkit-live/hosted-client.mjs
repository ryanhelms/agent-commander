import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';
import { connectCommanderWorker } from '@agent-commander/copilotkit';

const [direct, relayed, claude, codex] = process.argv.slice(2);
if (!direct || !relayed || !claude || !codex || claude === codex) {
  throw new Error('Pass the direct HTTPS origin, relay HTTPS origin, Claude worker ID and Codex worker ID.');
}
const tokens = JSON.parse(readFileSync(process.env.COMMANDER_APP_TOKENS ?? '/run/tokens', 'utf8'));
const tokenFor = name => name === 'direct' ? tokens.direct : tokens.relay;
const origin = { direct, relayed };
const connect = (workerId, route, identity = route) => {
  const lifetime = new AbortController();
  const client = connectCommanderWorker({
    baseURL: origin[route],
    workerId,
    getAccessToken: async () => tokenFor(identity),
    signal: AbortSignal.any([lifetime.signal, AbortSignal.timeout(120000)]),
  });
  return { lifetime, ...client };
};
const decode = async (response, expected = 200) => {
  assert.equal(response.status, expected, `unexpected HTTP status for ${new URL(response.url).pathname}`);
  return response.json();
};
const parseSSE = text => text.split('\n').filter(x => x.startsWith('data: ')).map(x => JSON.parse(x.slice(6)));

function includesAssistantReply(messages, expected) {
  let previous, text = '';
  for (const message of messages) {
    const acp = message.metadata?.acp;
    const assistantText = message.role === 'assistant' && !message.toolCalls?.length &&
      typeof message.content === 'string';
    const chunk = assistantText && acp?.source === 'live' && acp.kind === 'agent_message_chunk' &&
      (acp.contentType ?? 'text') === 'text';
    if (chunk && previous && acp.turnId === previous.turnId && acp.messageId === previous.messageId) {
      text += message.content;
    } else {
      text = assistantText ? message.content : '';
    }
    if (text.includes(expected)) return true;
    previous = chunk ? acp : undefined;
  }
  return false;
}

async function exercise(harness, worker, route) {
  const destination = route === 'direct' ? 'relayed' : 'direct';
  const connection = connect(worker, route);
  const resumed = connect(worker, destination, route);
  const unauthorized = connect(worker, destination);
  const { agent } = connection;
  const { generation } = await decode(await connection.workerInfo());
  assert.ok(generation, 'worker input must be held for this run');
  const runId = randomUUID();
  const question = `Local ${route} hosted connector check for ${harness}?`;
  const answer = `HOSTED_${route.toUpperCase()}_${harness.toUpperCase()}_79`;
  const prompt = 'Call commander_ask with exactly this question: ' + JSON.stringify(question) +
    '. Call commander_wait with the returned question ID, then write the exact received answer as your final text.';
  let success = false;
  let fault;
  let observedAction = 0;
  const subscription = agent.subscribe({ onToolCallEndEvent: () => { observedAction++; } });
  agent.addMessage({ id: runId, role: 'user', content: prompt });
  const active = agent.runAgent({ runId, forwardedProps: { generation } }).then(
    () => { success = true; }, error => { fault = error; });
  try {
    const end = Date.now() + 105000;
    let addressed, submittedReceipt;
    while (!fault && !success && Date.now() < end) {
      const pending = (agent.state.pendingRequests ?? []).find(q => q.question === question);
      if (pending && !addressed) {
        addressed = pending.id;
        assert.equal(agent.state.workerId, worker);
        submittedReceipt = await decode(await connection.findOperation({ runId }));
        assert.equal(submittedReceipt.runId, runId);
        const rejected = await unauthorized.findOperation({ runId });
        assert.equal(rejected.status, 404);
        assert.equal(submittedReceipt.operationId, agent.state.operationId);
        const reply = await resumed.reply({ requestId: addressed, answer, generation, idempotencyKey: randomUUID() });
        assert.ok(reply.ok, await reply.text());
        console.log(harness, route, 'resolved its addressed request through', destination);
      }
      await delay(150);
    }
    if (fault) throw fault;
    assert.ok(success && addressed, `${harness} ${route} never completed the addressed flow`);
    assert.ok(agent.messages.some(m => m.role === 'tool' && String(m.content).includes(question)),
      'snapshot omitted the harness tool output');
    assert.ok(includesAssistantReply(agent.messages, answer),
      'snapshot omitted the exact answer');
    assert.equal(observedAction, 0, 'a harness tool result emitted a frontend tool action');
    const receipt = await decode(await resumed.findOperation({ runId }));
    assert.deepEqual(receipt, submittedReceipt, 'the other route must recover the original receipt');
    const replay = await resumed.observe({ runId, operationId: receipt.operationId });
    assert.ok(replay.ok);
    const frames = parseSSE(await replay.text());
    assert.ok(frames.some(e => e.type === 'STATE_SNAPSHOT' && e.snapshot.operationStatus === 'completed'
      && e.snapshot.requests.some(q => q.id === addressed && q.status === 'answered' && q.answer === answer)));
    assert.ok(frames.some(e => e.type === 'MESSAGES_SNAPSHOT' && includesAssistantReply(e.messages, answer) &&
      e.messages.some(m => m.role === 'tool' && String(m.content).includes(question))));
    assert.equal(frames.filter(e => String(e.type).startsWith('TOOL_CALL')).length, 0);
    const source = await decode(await resumed.readHistory({ source: 'live', turnId: receipt.operationId, limit: 64 }));
    assert.ok(source.observations.some(o => o.extension?.data && o.session?.sessionId),
      'same scoped app could not read original worker material');
    console.log(harness, route, 'verified tool snapshot, completed turn, cross-route replay and scoped live source');
  } finally {
    subscription.unsubscribe();
    connection.lifetime.abort();
    resumed.lifetime.abort();
    unauthorized.lifetime.abort();
    await active;
  }
}
await Promise.all([
  (async () => { await exercise('claude', claude, 'direct'); await exercise('claude', claude, 'relayed'); })(),
  (async () => { await exercise('codex', codex, 'relayed'); await exercise('codex', codex, 'direct'); })(),
]);
