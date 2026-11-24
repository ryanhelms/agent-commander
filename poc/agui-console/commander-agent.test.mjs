import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { test } from 'node:test';
import { CommanderIncompleteRunError, connectCommanderWorker } from './commander-agent.mjs';

test('exact provider history reads keep the worker binding and encode the page hint and owner independently', async t => {
  const paths = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(url.pathname, '/v1/workers/selected/history');
    assert.equal(options.headers.get('authorization'), 'Bearer test-app');
    paths.push(Object.fromEntries(url.searchParams));
    return Response.json({ observations: [] });
  });
  const worker = connectCommanderWorker({ workerId: 'selected', baseURL: 'https://example.invalid', getAccessToken: () => 'test-app' });
  await worker.readHistory({ source: 'provider', cursor: 'page+/=', recordCursor: 'owner+#/=' });
  await worker.readHistory({ source: 'provider', recordCursor: 'first' });
  assert.deepEqual(paths, [
    { source: 'provider', cursor: 'page+/=', recordCursor: 'owner+#/=' }, { source: 'provider', recordCursor: 'first' },
  ]);
});

test('premature EOF leaves the original operation recoverable without redispatch', async t => {
  const life = { threadId: 'w-fixture', runId: 'r-durable' };
  const calls = [];
  let mode = 'revoking';
  const stream = () => {
    const events = [
      { type: 'RUN_STARTED', ...life },
      { type: 'STATE_SNAPSHOT', snapshot: { operationId: 'm-original', operationStatus: mode === 'restored' ? 'completed' : 'processing' } },
    ];
    if (mode === 'restored') events.push({ type: 'RUN_FINISHED', ...life });
    return new Response(events.map(event => 'data: ' + JSON.stringify(event) + '\n\n').join(''), {
      headers: { 'content-type': 'text/event-stream', 'Commander-Frontend-Tools': 'observe' },
    });
  };
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    calls.push([options.method ?? 'GET', url.pathname]);
    if (url.pathname.endsWith('/operations')) {
      if (mode === 'revoked') return Response.json({ error: 'forbidden' }, { status: 403 });
      assert.equal(url.searchParams.get('runId'), life.runId);
      return Response.json({ runId: life.runId, operationId: 'm-original' });
    }
    if (url.pathname.endsWith('/m-original')) assert.equal(url.searchParams.get('frontendTools'), 'observe');
    return stream();
  });
  const w = connectCommanderWorker({ workerId: life.threadId, baseURL: 'https://commander.example', getAccessToken: () => 'fixture' });
  w.agent.addMessage({ id: 'user', role: 'user', content: 'fixture' });
  const incomplete = err => err instanceof CommanderIncompleteRunError && err.runId === life.runId;
  await assert.rejects(w.agent.runAgent({ runId: life.runId, forwardedProps: { generation: 1 } }), incomplete);
  assert.equal(w.agent.state.operationStatus, 'processing');
  mode = 'revoked';
  const passive = () => w.resume({ runId: life.runId, dispatchTools: false });
  await assert.rejects(passive(), { status: 403 });
  mode = 'earlyEof';
  await assert.rejects(passive(), incomplete);
  mode = 'restored';
  await passive();
  assert.equal(w.agent.state.operationStatus, 'completed');
  assert.equal(calls.filter(([method]) => method === 'POST').length, 1);
});

test('terminal failure and deliberate observer detach retain the AG-UI lifecycle', async t => {
  const life = { threadId: 'w-fixture', runId: 'r-fixture' };
  let start, body;
  const started = new Promise(resolve => { start = resolve; });
  const frame = event => new TextEncoder().encode('data: ' + JSON.stringify(event) + '\n\n');
  t.mock.method(globalThis, 'fetch', async () => new Response(new ReadableStream({
    start(controller) {
      body = controller;
      controller.enqueue(frame({ type: 'RUN_STARTED', ...life }));
    },
  }), { headers: { 'content-type': 'text/event-stream' } }));
  const { agent } = connectCommanderWorker({ workerId: life.threadId, baseURL: 'https://commander.example', getAccessToken: () => 'fixture' });
  agent.addMessage({ id: 'user', role: 'user', content: 'fixture' });
  const run = () => agent.runAgent({ runId: life.runId, forwardedProps: { generation: 1 } }, { onRunStartedEvent() { start(); } });
  const detached = run();
  await started;
  await agent.detachActiveRun();
  await detached;
  let error;
  agent.subscribe({ onRunErrorEvent({ event }) { error = event.message; } });
  const failing = new Promise(resolve => { start = resolve; });
  const failed = run();
  await failing;
  body.enqueue(frame({ type: 'RUN_ERROR', message: 'Worker operation failed' }));
  body.close();
  await failed;
  assert.equal(error, 'Worker operation failed');
});

test('HttpAgent submits a prompt and renders the worker stream over the owner socket', async t => {
  const dir = await mkdtemp('/tmp/ac-reference-');
  t.after(() => rm(dir, { recursive: true, force: true }));
  const socketPath = join(dir, 'api.sock');
  const base = '/v1/ag-ui/workers/w-fixture';
  const lifecycle = { threadId: 'w-fixture', runId: 'r-fixture' };
  const seen = [];
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : null;
    seen.push({ path: req.url, method: req.method, body });
    if (req.url === base + '/requests/q-fixture/reply') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ id: 'q-fixture', status: 'answered' }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    for (const event of [
      { type: 'RUN_STARTED', ...lifecycle },
      { type: 'STATE_SNAPSHOT', snapshot: { operationId: 'm-fixture', pendingRequests: [{ id: 'q-fixture' }] } },
      { type: 'MESSAGES_SNAPSHOT', messages: [
        { id: 'assistant', role: 'assistant', toolCalls: [
          { id: 'read-1', type: 'function', function: { name: 'Read', arguments: '{}' } },
        ] },
        { id: 'result', role: 'tool', toolCallId: 'read-1', content: 'fixture bytes' },
      ] },
      { type: 'RUN_FINISHED', ...lifecycle },
    ]) res.write('data: ' + JSON.stringify(event) + '\n\n');
    res.end();
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(socketPath, resolve);
  });
  t.after(() => new Promise(resolve => server.close(resolve)));
  const { agent, observe, reply } = connectCommanderWorker({ socketPath, workerId: 'w-fixture' });
  agent.addMessage({ id: 'prompt', role: 'user', content: '  literal $value\n' });
  await agent.runAgent({ runId: 'r-fixture', forwardedProps: { generation: 2 } });
  assert.equal(seen[0].path, base + '/run?projection=incremental');
  assert.equal(seen[0].body.threadId, 'w-fixture');
  assert.equal(seen[0].body.messages.at(-1).content, '  literal $value\n');
  assert.equal(seen[0].body.forwardedProps.generation, 2);
  assert.equal(agent.messages.find(message => message.role === 'tool')?.content, 'fixture bytes');
  assert.equal(agent.state.operationId, 'm-fixture');

  const answer = await reply({ requestId: agent.state.pendingRequests[0].id, answer: 'Choice A' });
  assert.equal((await answer.json()).status, 'answered');
  assert.deepEqual(seen[1], { path: base + '/requests/q-fixture/reply', method: 'POST', body: { answer: 'Choice A' } });
  const resumed = await observe({ operationId: 'm-fixture', runId: 'r-fixture' });
  assert.match(await resumed.text(), /RUN_FINISHED/);
  assert.deepEqual(seen[2], { path: base + '/operations/m-fixture?runId=r-fixture&projection=incremental', method: 'GET', body: null });
});

test('Hosted connector pins worker routes to HTTPS and refreshes credentials per request', async t => {
  const calls = [];
  let token = 0;
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    calls.push({ path: url.href, init });
    if (url.pathname.endsWith('/run')) {
      const lifecycle = { threadId: 'w-fixture', runId: 'r-fixture' };
      const events = ['RUN_STARTED', 'RUN_FINISHED']
        .map(type => 'data: ' + JSON.stringify({ type, ...lifecycle }) + '\n\n').join('');
      return new Response(events, { headers: { 'content-type': 'text/event-stream' } });
    }
    return Response.json({ generation: 3 });
  });
  const getAccessToken = async () => 'token-' + ++token;
  assert.throws(() => connectCommanderWorker({
    workerId: 'w-fixture', baseURL: 'http://commander.example', getAccessToken,
  }), /HTTPS origin/);
  const connector = connectCommanderWorker({
    workerId: 'w-fixture', baseURL: 'https://commander.example', getAccessToken,
  });
  assert.equal((await (await connector.workerInfo()).json()).generation, 3);
  connector.agent.addMessage({ id: 'm', role: 'user', content: 'Hosted prompt' });
  await connector.agent.runAgent({ runId: 'r-fixture', forwardedProps: { generation: 3 } });
  await connector.reply({ requestId: 'q', answer: 'Yes', generation: 3, idempotencyKey: 'reply-id' });
  const toolMessage = { id: 'result', role: 'tool', toolCallId: 'ft-call', content: 'plans.md' };
  await connector.submitToolResult({ operationId: 'operation', message: toolMessage });
  await connector.findOperation({ runId: 'r-fixture' });
  await connector.observe({ operationId: 'operation', runId: 'r-fixture' });
  await connector.readHistory({ source: 'journal', cursor: 'query&value', limit: 2 });
  await connector.readHistory({ source: 'live', view: 'acp' });
  const base = 'https://commander.example/v1/ag-ui/workers/w-fixture';
  assert.deepEqual(calls.map(call => call.path), [
    base, base + '/run?projection=incremental', base + '/requests/q/reply', base + '/operations/operation/tools/ft-call/result',
    base + '/operations?runId=r-fixture',
    base + '/operations/operation?runId=r-fixture&projection=incremental',
    'https://commander.example/v1/workers/w-fixture/history?source=journal&cursor=query%26value&limit=2',
    'https://commander.example/v1/workers/w-fixture/history?source=live&view=acp',
  ]);
  assert.deepEqual(calls.map(call => call.init.headers.get('authorization')), [
    'Bearer token-1', 'Bearer token-2', 'Bearer token-3', 'Bearer token-4', 'Bearer token-5', 'Bearer token-6', 'Bearer token-7', 'Bearer token-8',
  ]);
  assert.ok(calls.every(call => call.init.redirect === 'error'));
  assert.equal(calls[2].init.headers.get('idempotency-key'), 'reply-id');
  assert.deepEqual(JSON.parse(calls[2].init.body), { answer: 'Yes', generation: 3 });
  assert.deepEqual(JSON.parse(calls[3].init.body), toolMessage);
});

test('resume restores the original run through AG-UI using only observational requests', async t => {
  const lifecycle = { threadId: 'w-fixture', runId: 'r-original' };
  const base = '/v1/ag-ui/workers/w-fixture';
  const seen = [];
  const events = [
    { type: 'RUN_STARTED', ...lifecycle },
    { type: 'STATE_SNAPSHOT', snapshot: { operationId: 'm-original', pendingRequests: [{ id: 'q-original' }] } },
    { type: 'MESSAGES_SNAPSHOT', messages: [
      { id: 'read', role: 'assistant', toolCalls: [{ id: 'read-1', type: 'function', function: { name: 'Read', arguments: '{}' } }] },
      { id: 'output', role: 'tool', toolCallId: 'read-1', content: 'Recovered file content' },
    ] },
    { type: 'RUN_FINISHED', ...lifecycle },
  ];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    assert.ok(init.method === undefined || init.method === 'GET');
    assert.equal(init.body, undefined);
    seen.push([url.pathname + url.search, init.headers.get('authorization')]);
    if (url.pathname === base + '/operations') {
      if (url.searchParams.get('runId') === 'missing') return Response.json({ error: 'worker operation' }, { status: 404 });
      return Response.json({ runId: lifecycle.runId, operationId: 'm-original' });
    }
    if (url.pathname === '/v1/workers/w-fixture/history') {
      assert.equal(url.searchParams.get('source'), 'live');
      assert.equal(url.searchParams.get('turnId'), 'm-original');
      return Response.json({ observations: [{
        turnId: 'm-original',
        extension: { type: 'acp.prompt_part', data: 'AAE=' },
      }] });
    }
    assert.equal(url.pathname, base + '/operations/m-original');
    assert.equal(url.searchParams.get('runId'), lifecycle.runId);
    return new Response(events.map(event => 'data: ' + JSON.stringify(event) + '\n\n').join(''), {
      headers: { 'content-type': 'text/event-stream' },
    });
  });
  let token = 0;
  const worker = connectCommanderWorker({
    workerId: lifecycle.threadId, baseURL: 'https://commander.example', getAccessToken: () => 'token-' + ++token,
  });
  await worker.agent.connectAgent();
  assert.deepEqual(seen, [], 'an idle thread connection queried a run receipt');
  const pending = [];
  const result = await worker.resume({ runId: lifecycle.runId }, {
    onStateSnapshotEvent({ event }) { pending.push(...event.snapshot.pendingRequests); },
    onToolCallEndEvent() { assert.fail('a recovered tool result was reissued'); },
  });
  assert.deepEqual(pending, [{ id: 'q-original' }]);
  assert.equal(worker.agent.state.operationId, 'm-original');
  assert.equal(result.newMessages.find(item => item.role === 'tool')?.content, 'Recovered file content');
  await worker.resume({ runId: lifecycle.runId });
  assert.equal(worker.agent.messages.filter(item => item.id === 'output').length, 1);
  const history = await worker.readHistory({ source: 'live', turnId: worker.agent.state.operationId });
  assert.equal((await history.json()).observations[0].extension.data, 'AAE=');

  t.mock.method(console, 'error', () => {});
  await assert.rejects(worker.resume({ runId: 'missing' }), { status: 404 });
  await assert.rejects(worker.resume({ runId: 'mismatch' }), /mismatched operation receipt/);
  await assert.rejects(worker.resume({ runId: 'cancelled', signal: AbortSignal.abort() }), { name: 'AbortError' });
  assert.deepEqual(seen, [
    [base + '/operations?runId=r-original', 'Bearer token-1'],
    [base + '/operations/m-original?runId=r-original&projection=incremental', 'Bearer token-2'],
    [base + '/operations?runId=r-original', 'Bearer token-3'],
    [base + '/operations/m-original?runId=r-original&projection=incremental', 'Bearer token-4'],
    ['/v1/workers/w-fixture/history?source=live&turnId=m-original', 'Bearer token-5'],
    [base + '/operations?runId=missing', 'Bearer token-6'],
    [base + '/operations?runId=mismatch', 'Bearer token-7'],
  ]);
});

test('incremental text and observed tool corrections retain exact content, source and roles', async t => {
  const lifecycle = { threadId: 'w-fixture', runId: 'r-incremental' };
  const initial = { id: 'history', role: 'user', content: 'Earlier prompt' };
  const parts = [
    { id: 'assistant-part', role: 'assistant', content: '  hello\n' },
    { id: 'space', role: 'assistant', content: ' ' },
    { id: 'user-part', role: 'user', content: 'follow-up' },
    { id: 'notice', role: 'system', content: 'diagnostic' },
  ].map(message => ({
    ...message, metadata: { acp: { source: 'live', cursor: message.id, nested: { value: null } } },
  }));
  const observedCall = { id: 'read', role: 'assistant', toolCalls: [
    { id: 'call-id', type: 'function', function: { name: 'Read', arguments: '{}' } },
  ] };
  const failure = { id: 'read-result', role: 'tool', toolCallId: 'call-id', error: 'missing file', content: 'partial',
    metadata: { acp: { source: 'live', cursor: 'result-2' } } };
  const corrected = [initial, ...parts, observedCall, failure];
  const question = { id: 'q-1', status: 'pending', question: 'Which file?' };
  const answered = { ...question, status: 'answered', answer: 'receipt.txt' };
  const events = [{ type: 'RUN_STARTED', ...lifecycle },
    { type: 'STATE_SNAPSHOT', snapshot: { operationId: 'op-1', requests: [question], pendingRequests: [question] } },
    { type: 'MESSAGES_SNAPSHOT', messages: [initial] }];
  for (const message of parts) {
    events.push(
      { type: 'TEXT_MESSAGE_START', messageId: message.id, role: message.role, metadata: message.metadata },
      { type: 'TEXT_MESSAGE_CONTENT', messageId: message.id, delta: message.content },
      { type: 'TEXT_MESSAGE_END', messageId: message.id },
    );
  }
  events.push({ type: 'STATE_DELTA', delta: [
    { op: 'replace', path: '/requests/0', value: answered },
    { op: 'remove', path: '/pendingRequests/0' },
  ] }, { type: 'MESSAGES_SNAPSHOT', messages: [...corrected.slice(0, -1), { ...failure, content: 'working', error: undefined }] },
    { type: 'MESSAGES_SNAPSHOT', messages: corrected }, { type: 'RUN_FINISHED', ...lifecycle });
  t.mock.method(globalThis, 'fetch', async () => new Response(events.map(event =>
    'data: ' + JSON.stringify(event) + '\n\n').join(''), { headers: { 'content-type': 'text/event-stream' } }));
  const { agent } = connectCommanderWorker({ workerId: lifecycle.threadId, baseURL: 'https://commander.example', getAccessToken: () => 'fixture' });
  const streamed = [];
  await agent.runAgent({ runId: lifecycle.runId }, {
    onTextMessageEndEvent({ event, messages }) { streamed.push(structuredClone(messages.find(message => message.id === event.messageId))); },
    onToolCallEndEvent() { assert.fail('an observed tool was presented as executable work'); },
  });
  assert.deepEqual(streamed, parts);
  assert.deepEqual(agent.messages, corrected);
  assert.deepEqual(agent.state, { operationId: 'op-1', requests: [answered], pendingRequests: [] });
});

test('AG-UI tool events can resolve the originating app call through the connector', async t => {
  const lifecycle = { threadId: 'w-fixture', runId: 'r-tool' };
  const metadata = { commanderOperationId: 'op-fixture' };
  const events = [
    { type: 'RUN_STARTED', ...lifecycle },
    { type: 'TOOL_CALL_START', toolCallId: 'ft-call', toolCallName: 'select_document', parentMessageId: 'frontend-ft-call', metadata },
    { type: 'TOOL_CALL_ARGS', toolCallId: 'ft-call', delta: '{"folder":"plans"}' },
    { type: 'TOOL_CALL_END', toolCallId: 'ft-call', metadata },
    { type: 'TOOL_CALL_RESULT', toolCallId: 'ft-call', messageId: 'result-ft-call', role: 'tool', content: 'plans.md' },
    { type: 'RUN_FINISHED', ...lifecycle },
  ];
  const schema = { type: 'object', properties: { folder: { type: 'string' } } };
  const definition = { name: 'select_document', description: 'Pick a document', parameters: schema };
  let returned;
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    if (url.pathname.endsWith('/run')) {
      assert.deepEqual(JSON.parse(init.body).tools, [definition]);
      return new Response(events.map(event => 'data: ' + JSON.stringify(event) + '\n\n').join(''), {
        headers: { 'content-type': 'text/event-stream' },
      });
    }
    assert.match(url.pathname, /\/operations\/op-fixture\/tools\/ft-call\/result$/);
    returned = JSON.parse(init.body);
    return Response.json({ ok: true });
  });
  const connector = connectCommanderWorker({
    workerId: 'w-fixture', baseURL: 'https://commander.example', getAccessToken: async () => 'test-token',
  });
  const { agent } = connector;
  const { unsubscribe } = agent.subscribe({
    async onToolCallEndEvent({ event, toolCallName, toolCallArgs }) {
      assert.equal(toolCallName, definition.name);
      assert.deepEqual(toolCallArgs, { folder: 'plans' });
      await connector.submitToolResult({
        operationId: event.metadata.commanderOperationId,
        message: { id: 'result-ft-call', role: 'tool', toolCallId: event.toolCallId, content: 'plans.md' },
      });
    },
  });
  t.after(unsubscribe);
  agent.addMessage({ id: 'prompt', role: 'user', content: 'Use the app tool.' });
  await agent.runAgent({ runId: 'r-tool', tools: [definition], forwardedProps: { generation: 2 } });
  assert.deepEqual(returned, { id: 'result-ft-call', role: 'tool', toolCallId: 'ft-call', content: 'plans.md' });
  assert.equal(agent.messages.find(message => message.id === 'result-ft-call')?.content, 'plans.md');
});

test('passive observers require confirmation before giving AG-UI the stream', async t => {
  let supported = false;
  const lifecycle = { threadId: 'w-fixture', runId: 'r-passive' };
  t.mock.method(globalThis, 'fetch', async url => {
    if (url.pathname.endsWith('/operations')) return Response.json({ runId: lifecycle.runId, operationId: 'op' });
    assert.equal(url.searchParams.get('frontendTools'), 'observe');
    const headers = { 'content-type': 'text/event-stream' };
    if (supported) headers['Commander-Frontend-Tools'] = 'observe';
    const events = [
      { type: 'RUN_STARTED', ...lifecycle },
      { type: 'STATE_SNAPSHOT', snapshot: { operationId: 'op', unconfirmedToolCalls: [{ id: 'ft', name: 'select', arguments: {} }] } },
      { type: 'RUN_FINISHED', ...lifecycle },
    ];
    return new Response(events.map(event => 'data: ' + JSON.stringify(event) + '\n\n').join(''), { headers });
  });
  const worker = connectCommanderWorker({
    workerId: lifecycle.threadId, baseURL: 'https://commander.example', getAccessToken: async () => 'fixture-token',
  });
  await assert.rejects(worker.observe({ operationId: 'op', runId: lifecycle.runId, dispatchTools: false }), /did not confirm passive/);
  supported = true;
  await worker.resume({ runId: lifecycle.runId, dispatchTools: false }, {
    onToolCallEndEvent() { assert.fail('passive tool was executed'); },
  });
  assert.equal(worker.agent.state.unconfirmedToolCalls[0].id, 'ft');
});
