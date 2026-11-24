import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

test('attached console resumes an existing run and replies through CopilotKit', { timeout: 15000 }, async t => {
  const dir = await mkdtemp('/tmp/ac-attached-test-');
  const socketPath = join(dir, 'owner.sock');
  const enrichedPage = await readFile(new URL('./testdata/enriched-update-history.json', import.meta.url), 'utf8');
  const base = '/v1/ag-ui/workers/w-fixture';
  const lifecycle = { threadId: 'w-fixture', runId: 'run-fixture' };
  const prompt = '  Inspect the sample $value.\n';
  let sent;
  let answer;
  const active = new Set();
  let submissions = 0;
  let observations = 0;
  let upstreamClosed;
  const attachmentClosed = new Promise(resolve => { upstreamClosed = resolve; });
  const sleepSignal = AbortSignal.timeout(9000);
  const json = (res, payload) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(payload));
  };
  const event = (res, payload) => res.write('data: ' + JSON.stringify(payload) + '\n\n');
  const open = (res, passive = false) => {
    active.add(res);
    res.once('close', () => active.delete(res));
    res.writeHead(200, { 'content-type': 'text/event-stream', ...(passive ? { 'Commander-Frontend-Tools': 'observe' } : {}) });
    event(res, { type: 'RUN_STARTED', ...lifecycle });
    event(res, { type: 'STATE_SNAPSHOT', snapshot: { operationId: 'm-fixture', pendingRequests: [{ id: 'q-fixture', question: 'Which choice?' }] } });
    event(res, { type: 'MESSAGES_SNAPSHOT', messages: [] });
    event(res, { type: 'TEXT_MESSAGE_START', messageId: 'live-part', role: 'assistant',
      metadata: { acp: { source: 'live', cursor: 'fixture-cursor' } } });
    event(res, { type: 'TEXT_MESSAGE_CONTENT', messageId: 'live-part', delta: 'incremental fixture reply' });
    event(res, { type: 'TEXT_MESSAGE_END', messageId: 'live-part' });
  };
  const server = createServer(async (req, res) => {
    if (req.url === '/v1/health') return json(res, { status: 'ok' });
    if (req.url === base) return json(res, {
      workerId: 'w-fixture', role: 'worker', client: 'codex', status: 'working', nativeHistory: true, generation: 3,
    });
    if (req.url === '/v1/workers/w-fixture/history?source=journal&cursor=next&limit=12') {
      return json(res, { observations: [{ extension: { type: 'codex.journal.response_item', data: 'AAE=' } }] });
    }
    if (req.url === '/v1/workers/w-fixture/history?source=live&turnId=turn-swatch&limit=12') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(enrichedPage);
    }
    if (req.url === '/v1/workers/w-fixture/history?source=live&limit=12') {
      return json(res, { observations: [{ cursor: 'live-1', extension: { type: 'acp.session_update', data: 'AAI=' } }] });
    }
    if (req.url === '/v1/workers/w-fixture/history?source=live&cursor=page%2B2%2F%3D&turnId=m-fixture&limit=12') {
      return json(res, { observations: [{ turnId: 'm-fixture', extension: { type: 'acp.prompt_part', data: 'AAI=' } }] });
    }
    const route = new URL(req.url, 'http://localhost');
    if (route.pathname === '/v1/workers/w-fixture/history' && !route.searchParams.has('source')) {
      assert.equal(route.searchParams.get('limit'), '12');
      return json(res, { observations: [{ text: { speaker: 'SPEAKER_ASSISTANT',
        text: route.searchParams.get('cursor') === 'page+2/=' ? 'next retained text' : 'retained text' } }],
        nextCursor: 'page+2/=' });
    }
    if (req.method === 'GET' && route.pathname === base + '/operations') {
      if (sent && route.searchParams.get('runId') === lifecycle.runId) {
        return json(res, { runId: lifecycle.runId, operationId: 'm-fixture' });
      }
      res.writeHead(404, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: 'worker operation not found' }));
    }
    if (req.method === 'GET' && req.url === base + '/operations/m-fixture?runId=run-fixture&projection=incremental&frontendTools=observe') {
      observations++;
      open(res, true);
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const input = JSON.parse(Buffer.concat(chunks).toString());
    if (req.url === base + '/run?projection=incremental') {
      if (input.runId === 'fixture-close') {
        res.once('close', upstreamClosed);
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        event(res, { type: 'RUN_STARTED', threadId: lifecycle.threadId, runId: input.runId });
        return;
      }
      submissions++;
      sent = input;
      open(res);
      return;
    }
    if (req.url === base + '/requests/q-fixture/reply') {
      answer = input.answer;
      json(res, { id: 'q-fixture', status: 'answered' });
      for (const observer of active) {
        event(observer, { type: 'STATE_SNAPSHOT', snapshot: {
          operationId: 'm-fixture', pendingRequests: [],
          requests: [{ id: 'q-fixture', question: 'Which choice?', status: 'answered', answer }],
        } });
        event(observer, { type: 'MESSAGES_SNAPSHOT', messages: [
          { id: 'call', role: 'assistant', toolCalls: [{ id: 'read', type: 'function', function: { name: 'Read', arguments: '{}' } }] },
          { id: 'result', role: 'tool', toolCallId: 'read', content: 'inspected fixture' },
        ] });
        event(observer, { type: 'RUN_FINISHED', ...lifecycle });
        observer.end();
      }
      return;
    }
    res.writeHead(404).end();
  });
  server.listen(socketPath);
  await once(server, 'listening');
  const child = spawn(process.execPath, [fileURLToPath(new URL('./server.mjs', import.meta.url)), '--worker', 'w-fixture'], {
    env: { ...process.env, AGENT_COMMANDER_SOCKET: socketPath },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let consolePath;
  t.after(async () => {
    child.kill();
    if (child.exitCode === null && child.signalCode === null) await once(child, 'exit');
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
    if (consolePath) await rm(join(consolePath, '..'), { recursive: true, force: true });
  });
  const lines = createInterface({ input: child.stdout });
  for await (const line of lines) {
    const match = /launch URL in (.+)$/.exec(line);
    if (match) {
      consolePath = match[1];
      break;
    }
  }
  assert.ok(consolePath, 'missing launch URL file');
  const address = (await readFile(consolePath, 'utf8')).trim();
  const auth = await fetch(address, { redirect: 'manual', signal: sleepSignal });
  const cookie = auth.headers.get('set-cookie').split(';')[0];
  const url = new URL(address).origin;
  const headers = { cookie, 'content-type': 'application/json' };
  const config = await fetch(url + '/console-config', { headers, signal: sleepSignal });
  assert.deepEqual(await config.json(), { mode: 'worker', workerId: 'w-fixture', client: 'codex', generation: 3, status: 'working', nativeHistory: true });
  const unauthenticated = await fetch(url + '/session-journal?cursor=next', { signal: sleepSignal });
  assert.equal(unauthenticated.status, 403);
  const journal = await fetch(url + '/session-journal?cursor=next', { headers, signal: sleepSignal });
  assert.equal((await journal.json()).observations[0].extension.data, 'AAE=');
  const enriched = await fetch(url + '/live-acp-source?turnId=turn-swatch', { headers, signal: sleepSignal });
  const pageText = await enriched.text();
  assert.equal(pageText, enrichedPage, 'the scoped history bridge must preserve Commander’s JSON bytes');
  const records = JSON.parse(pageText).observations;
  const originals = records.map(record => Buffer.from((record.sourceRecord ?? record.extension).data, 'base64').toString('utf8'));
  assert.equal(records[0].tool.callId, 'call-swatch');
  assert.ok(originals[0].includes('"futureParams":[9007199254740993,true,null,{"deep":[-9007199254740995'));
  assert.ok(originals[0].includes('"mimeType":"image/png"'));
  assert.ok(!Object.hasOwn(JSON.parse(originals[1]), 'update'));
  assert.ok(originals[1].includes('9007199254740997'));
  assert.ok(Object.hasOwn(JSON.parse(originals[2]), 'update'));
  assert.equal(JSON.parse(originals[2]).update, null);
  assert.ok(originals[2].includes('9007199254740999'));
  const live = await fetch(url + '/live-acp-source', { headers, signal: sleepSignal });
  assert.equal((await live.json()).observations[0].cursor, 'live-1');
  const protectedHistory = await fetch(url + '/provider-history', { signal: sleepSignal });
  assert.equal(protectedHistory.status, 403);
  const provider = await fetch(url + '/provider-history', { headers, signal: sleepSignal });
  assert.equal((await provider.json()).observations[0].text.text, 'retained text');
  const next = await fetch(url + '/provider-history?' + new URLSearchParams({
    cursor: 'page+2/=', workerId: 'another-worker', source: 'journal',
  }), { headers, signal: sleepSignal });
  assert.equal((await next.json()).observations[0].text.text, 'next retained text');

  const stream = await fetch(url + '/api/copilotkit/agent/commander/run', {
    method: 'POST', headers, signal: sleepSignal,
    body: JSON.stringify({ ...lifecycle, messages: [{ id: 'prompt', role: 'user', content: prompt }],
      state: {}, context: [], tools: [], forwardedProps: { generation: 3 } }),
  });
  assert.equal(stream.status, 200, await (stream.ok ? '' : stream.text()));
  const received = stream.body.getReader();
  const decoder = new TextDecoder();
  let transcript = '';
  while (!transcript.includes('incremental fixture reply')) {
    const chunk = await received.read();
    assert.equal(chunk.done, false, transcript);
    transcript += decoder.decode(chunk.value, { stream: true });
  }
  assert.equal(sent.messages.at(-1).content, prompt);
  assert.equal(sent.forwardedProps.generation, 3);
  assert.match(transcript, /q-fixture/);
  assert.match(transcript, /fixture-cursor/);
  await received.cancel();
  const resume = ({ threadId = lifecycle.threadId, runId = lifecycle.runId, authorized = true } = {}) =>
    fetch(url + '/api/copilotkit/agent/commander/connect', {
      method: 'POST',
      headers: authorized ? headers : { 'content-type': 'application/json' },
      signal: sleepSignal,
      body: JSON.stringify({ threadId, runId, state: {}, messages: [], context: [], tools: [],
        forwardedProps: { commanderObserve: true } }),
    });
  assert.equal((await resume({ authorized: false })).status, 403);
  assert.equal((await resume({ threadId: 'w-other' })).status, 400);
  assert.equal((await resume({ runId: 'missing' })).status, 404);
  const resumed = await resume();
  assert.equal(resumed.status, 200, await (resumed.ok ? '' : resumed.text()));
  const restored = resumed.body.getReader();
  transcript = '';
  while (!transcript.includes('incremental fixture reply')) {
    const chunk = await restored.read();
    assert.equal(chunk.done, false, transcript);
    transcript += decoder.decode(chunk.value, { stream: true });
  }
  assert.match(transcript, /"operationId":"m-fixture"/);
  assert.match(transcript, /fixture-cursor/);
  const source = await fetch(url + '/live-acp-source?' + new URLSearchParams({
    turnId: 'm-fixture', cursor: 'page+2/=', workerId: 'another-worker',
  }), { headers, signal: sleepSignal });
  assert.equal(source.status, 200);
  assert.deepEqual((await source.json()).observations[0], {
    turnId: 'm-fixture', extension: { type: 'acp.prompt_part', data: 'AAI=' },
  });
  assert.equal(submissions, 1);
  assert.equal(observations, 1);
  const reply = await fetch(url + '/reply', {
    method: 'POST', headers, signal: sleepSignal,
    body: JSON.stringify({ requestId: 'q-fixture', answer: 'Choice A' }),
  });
  assert.equal((await reply.json()).status, 'answered');
  assert.equal(answer, 'Choice A');
  for (;;) {
    const chunk = await restored.read();
    if (chunk.done) break;
    transcript += decoder.decode(chunk.value, { stream: true });
  }
  assert.match(transcript, /inspected fixture/);
  assert.match(transcript, /"requests":\[\{"id":"q-fixture","question":"Which choice\?","status":"answered","answer":"Choice A"\}\]/);
  assert.match(transcript, /RUN_FINISHED/);

  const waiting = await fetch(url + '/api/copilotkit/agent/commander/run', {
    method: 'POST', headers, signal: sleepSignal,
    body: JSON.stringify({ ...lifecycle, runId: 'fixture-close', messages: [{ id: 'close', role: 'user', content: 'Wait.' }],
      state: {}, context: [], tools: [], forwardedProps: { generation: 3 } }),
  });
  assert.match(new TextDecoder().decode((await waiting.body.getReader().read()).value), /RUN_STARTED/);
  const exited = once(child, 'exit', { signal: AbortSignal.timeout(3000) });
  child.kill();
  assert.deepEqual(await exited, [0, null]);
  await attachmentClosed;
});
