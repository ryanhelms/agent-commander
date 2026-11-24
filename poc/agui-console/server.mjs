import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { copyFile, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createServer, request } from 'node:http';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { HttpAgent } from '@ag-ui/client';
import { EventType } from '@ag-ui/core';
import { connectCommanderWorker } from './commander-agent.mjs';

process.env.COPILOTKIT_TELEMETRY_DISABLED = 'true';
const { CopilotRuntime, InMemoryAgentRunner } = await import('@copilotkit/runtime/v2');
const { createCopilotNodeListener } = await import('@copilotkit/runtime/v2/node');

const dir = fileURLToPath(new URL('.', import.meta.url));
const app = join(dir, 'dist', 'Agent Commander Console.app');
const workerArg = process.argv.indexOf('--worker');
const workerId = workerArg === -1 ? undefined : process.argv[workerArg + 1];
if (workerArg !== -1 && (!workerId || !/^w-[a-zA-Z0-9_-]+$/.test(workerId))) {
  throw new Error('Pass a Commander worker ID after --worker.');
}
const stateDir = await mkdtemp('/tmp/ac-agui-');
const socketPath = workerId ? process.env.AGENT_COMMANDER_SOCKET : join(stateDir, 'service.sock');
if (!socketPath) throw new Error('Set AGENT_COMMANDER_SOCKET to the running service’s owner socket.');
const workspace = !workerId && join(stateDir, 'sample');
if (workspace) {
  await mkdir(workspace, { mode: 0o700 });
  await copyFile(join(dir, 'sample', 'scenario.md'), join(workspace, 'scenario.md'));
}
const launchKey = randomUUID();
const cookieName = 'ac_console_session';
const token = randomBytes(24).toString('hex');
const agentPath = '/_agent/' + token;
const tmuxLabel = !workerId && 'ac-' + createHash('sha256').update(stateDir).digest('hex').slice(0, 12);
const attachedLifetime = new AbortController();
const attached = workerId && connectCommanderWorker({ socketPath, workerId, signal: attachedLifetime.signal });
const assignment = [
  'Use Read to read scenario.md in the current working directory. This is a one-agent release planning exercise.',
  'Give a brief status update. Ask the developer the exact question in scenario.md using commander_ask.',
  'Call commander_wait with the returned request ID until a reply arrives.',
  'Report the answer verbatim, preserving punctuation and line breaks, then give a one-sentence release recommendation via commander_result and your final response.',
  'Use only the fictional sample. Remain read-only and do not delegate.'
].join(' ');

class HTTPError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const service = !attached && spawn(join(dir, 'dist', 'agentctl'), ['serve'], {
  env: {
    ...process.env,
    AGENT_COMMANDER_HOME: stateDir,
    AGENT_COMMANDER_SOCKET: socketPath,
    AGENT_COMMANDER_FOCUSED_PROOF: '1',
  },
  stdio: ['ignore', 'ignore', 'inherit'],
});
let serviceError;
if (service) service.on('error', error => { serviceError = error; });

function commander(path, { method = 'GET', body, key } = {}) {
  const payload = body === undefined ? undefined : JSON.stringify(body);
  const headers = payload ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) } : {};
  if (key) headers['idempotency-key'] = key;
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, path, method, headers, timeout: 5000 }, response => {
      response.setEncoding('utf8');
      let data = '';
      response.on('data', chunk => { data += chunk; });
      response.on('error', reject);
      response.on('end', () => {
        try {
          const result = JSON.parse(data);
          if (response.statusCode >= 400) reject(new HTTPError(response.statusCode, result.error || 'Commander request failed.'));
          else resolve(result);
        } catch (error) {
          reject(error);
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error('Commander service timed out.')));
    req.on('error', reject);
    req.end(payload);
  });
}

async function waitForService() {
  const deadline = Date.now() + 9000;
  while (Date.now() < deadline) {
    if (serviceError) throw serviceError;
    if (service && service.exitCode !== null) throw new Error('Commander service exited during startup.');
    try {
      await commander('/v1/health');
      return;
    } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'ECONNREFUSED') throw error;
      await delay(100);
    }
  }
  throw new Error('Commander service did not start.');
}

async function workerConfiguration() {
  if (!attached) return { mode: 'demo' };
  const response = await attached.workerInfo({ signal: AbortSignal.timeout(5000) });
  if (!response.ok) throw new HTTPError(response.status, 'The selected managed worker is unavailable.');
  const worker = await response.json();
  if (worker.role !== 'worker' || worker.workerId !== workerId) throw new HTTPError(404, 'The selected managed worker is unavailable.');
  return { mode: 'worker', workerId, client: worker.client, generation: worker.generation,
    status: worker.status, nativeHistory: worker.nativeHistory };
}

let launch;
function startRun() {
  if (!launch) {
    launch = commander('/v1/runs', {
      method: 'POST',
      key: launchKey,
      body: { path: workspace, title: 'Release decision', project: 'Relay · proof of concept', task: assignment, worker_limit: 1 },
    }).catch(error => {
      launch = undefined;
      throw error;
    });
  }
  return launch;
}

function runState(run) {
  const worker = run.workers.find(item => item.id === run.coordinator_id);
  const requests = run.requests.filter(item => item.worker_id === worker.id)
    .map(({ id, question, status, answer }) => ({ id, question, status, ...(status === 'answered' && { answer }) }));
  const terminal = ['completed', 'failed', 'stopped'].includes(worker.state);
  const status = terminal ? worker.state : requests.some(item => item.status === 'pending') ? 'waiting' : 'working';
  return {
    worker,
    terminal,
    snapshot: {
      status, runId: run.id, workerId: worker.id, requests,
      ...(worker.error && { error: worker.error }),
      attachCommand: 'tmux -L ' + tmuxLabel + ' attach -t ' + worker.id,
    },
  };
}

async function jsonBody(req) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > 128 * 1024) throw new HTTPError(413, 'Request is too large.');
    chunks.push(chunk);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value;
  } catch {
    throw new HTTPError(400, 'Expected a JSON object.');
  }
}

async function serveAgent(req, res) {
  const input = await jsonBody(req);
  if (typeof input.threadId !== 'string' || typeof input.runId !== 'string') {
    throw new HTTPError(400, 'Expected an AG-UI thread ID and run ID.');
  }
  const { threadId, runId } = input;
  const disconnect = new AbortController();
  res.once('close', () => disconnect.abort());
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store',
    'x-accel-buffering': 'no',
  });
  const send = event => { if (!res.destroyed) res.write('data: ' + JSON.stringify(event) + '\n\n'); };
  send({ type: EventType.RUN_STARTED, threadId, runId });
  try {
    const { id } = await startRun();
    let previousMessages = '';
    let previousSnapshot = '';
    while (!disconnect.signal.aborted) {
      const run = await commander('/v1/runs/' + id + '?view=ag-ui');
      const { terminal, snapshot, worker } = runState(run);
      const messages = worker.messages ?? [];
      const serializedMessages = JSON.stringify(messages);
      if (serializedMessages !== previousMessages) {
        send({ type: EventType.MESSAGES_SNAPSHOT, messages });
        previousMessages = serializedMessages;
      }
      const serialized = JSON.stringify(snapshot);
      if (serialized !== previousSnapshot) {
        send({ type: EventType.STATE_SNAPSHOT, snapshot });
        previousSnapshot = serialized;
      }
      if (terminal) {
        if (snapshot.status === 'failed') {
          send({ type: EventType.RUN_ERROR, message: snapshot.error || 'Claude ended with an error.' });
        } else {
          send({ type: EventType.RUN_FINISHED, threadId, runId });
        }
        break;
      }
      await delay(300, undefined, { signal: disconnect.signal });
    }
  } catch (error) {
    if (!disconnect.signal.aborted) send({ type: EventType.RUN_ERROR, message: error.message });
  } finally {
    res.end();
  }
}

function json(res, status, value) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(value));
}

async function reply(req, res) {
  const { requestId, answer, operationId } = await jsonBody(req);
  if (typeof requestId !== 'string' || typeof answer !== 'string' || !answer.trim() || answer.length > 8000) {
    throw new HTTPError(400, 'Provide an answer for the selected request.');
  }
  if (operationId !== undefined && (typeof operationId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(operationId))) {
    throw new HTTPError(400, 'Invalid reply operation ID.');
  }
  if (attached) {
    const response = await attached.reply({ requestId, answer, idempotencyKey: operationId });
    return json(res, response.status, await response.json());
  }
  if (!launch) throw new HTTPError(409, 'Start the Claude session first.');
  const { id } = await launch;
  const current = await commander('/v1/runs/' + id);
  if (!current.requests.some(item => item.id === requestId && item.worker_id === current.coordinator_id)) {
    throw new HTTPError(404, 'That request is outside this console.');
  }
  const answered = await commander('/v1/requests/' + requestId + '/reply', {
    method: 'POST', body: { answer }, key: operationId,
  });
  json(res, 200, { id: answered.id, status: answered.status });
}

async function resumeAttachedRun({ request, route }) {
  if (!attached || route.method !== 'agent/connect' || route.agentId !== 'commander') return;
  const input = await request.clone().json().catch(() => undefined);
  if (input?.forwardedProps?.commanderObserve !== true) return;
  const { threadId, runId } = input;
  if (threadId !== workerId || typeof runId !== 'string' || !runId || runId.length > 128) {
    throw Response.json({ error: 'Expected the attached worker and original run ID.' }, { status: 400 });
  }
  const options = { runId, signal: request.signal, dispatchTools: false };
  const response = await attached.findOperation(options);
  if (!response.ok) throw response;
  const receipt = await response.json();
  if (receipt?.runId !== runId || typeof receipt.operationId !== 'string' || !receipt.operationId) {
    throw Response.json({ error: 'Commander returned a mismatched operation receipt.' }, { status: 502 });
  }
  // The runtime handles a Response thrown by a request hook as the response.
  throw await attached.observe({ ...options, operationId: receipt.operationId });
}

const assets = new Map([
  ['/', { file: 'ui/index.html', type: 'text/html; charset=utf-8' }],
  ['/ui.js', { file: 'dist/ui.js', type: 'text/javascript; charset=utf-8' }],
  ['/ui.css', { file: 'dist/ui.css', type: 'text/css; charset=utf-8' }],
]);
const historySources = new Map([
  ['/provider-history', undefined],
  ['/session-journal', 'journal'],
  ['/live-acp-source', 'live'],
]);
let copilot;
let origin;
const server = createServer(async (req, res) => {
  try {
    if (req.headers.host !== new URL(origin).host) throw new HTTPError(403, 'Expected the local console address.');
    const { pathname, searchParams } = new URL(req.url, origin);
    res.setHeader('cache-control', 'no-store');
    res.setHeader('x-content-type-options', 'nosniff');
    if (req.method === 'GET' && pathname === '/session/' + token) {
      res.writeHead(303, { location: '/', 'set-cookie': cookieName + '=' + token + '; Path=/; HttpOnly; SameSite=Strict' });
      return res.end();
    }
    if (!attached && req.method === 'POST' && pathname === agentPath) return await serveAgent(req, res);
    const cookies = (req.headers.cookie || '').split(';').map(value => value.trim());
    if (!cookies.includes(cookieName + '=' + token)) throw new HTTPError(403, 'Open the console from its launcher.');
    if (req.headers.origin && req.headers.origin !== origin) throw new HTTPError(403, 'Unexpected request origin.');
    if (pathname.startsWith('/api/copilotkit/')) return copilot(req, res);
    if (req.method === 'GET' && pathname === '/console-config') return json(res, 200, await workerConfiguration());
    if (req.method === 'GET' && attached && historySources.has(pathname)) {
      const recordCursor = pathname === '/provider-history' ? searchParams.get('recordCursor') ?? undefined : undefined;
      const page = await attached.readHistory({
        source: recordCursor !== undefined ? 'provider' : historySources.get(pathname),
        recordCursor,
        turnId: searchParams.get('turnId') ?? undefined,
        cursor: searchParams.get('cursor') ?? undefined, limit: recordCursor === undefined ? 12 : undefined,
        signal: AbortSignal.timeout(23000),
      });
      // Preserve the original JSON representation, including vendor numbers
      // outside JavaScript's safe integer range. Reading a source is scoped.
      res.writeHead(page.status, { 'content-type': 'application/json; charset=utf-8' });
      if (!page.body) return res.end();
      return await pipeline(Readable.fromWeb(page.body), res);
    }
    if (req.method === 'POST' && pathname === '/reply') return await reply(req, res);
    const asset = assets.get(pathname);
    if (req.method !== 'GET' || !asset) throw new HTTPError(404, 'Page unavailable.');
    const content = await readFile(join(dir, asset.file));
    res.writeHead(200, {
      'content-type': asset.type,
      'content-security-policy': "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; media-src data:; frame-ancestors 'none'; base-uri 'none'",
    });
    res.end(content);
  } catch (error) {
    if (res.headersSent) res.end();
    else json(res, error.status || 500, { error: error.message });
    if (!error.status || error.status >= 500) console.error(error);
  }
});

let closing = false;
async function shutdown(exitCode = 0) {
  if (closing) return;
  closing = true;
  try {
    if (launch) {
      const run = await launch;
      const current = await commander('/v1/runs/' + run.id);
      if (current.status === 'running' || current.status === 'stopping') {
        await commander('/v1/runs/' + run.id + '/stop', { method: 'POST', body: {} });
        for (let i = 0; i < 20; i++) {
          const stopping = await commander('/v1/runs/' + run.id);
          if (stopping.status !== 'stopping') break;
          await delay(100);
        }
      }
    }
  } catch (error) {
    console.error('Could not stop the isolated run:', error.message);
  } finally {
    attachedLifetime.abort();
    server.close();
    server.closeAllConnections();
    if (service) service.kill();
    process.exitCode = exitCode;
  }
}

process.once('SIGINT', () => void shutdown());
process.once('SIGTERM', () => void shutdown());

try {
  if (attached) await workerConfiguration();
  else await waitForService();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  origin = 'http://127.0.0.1:' + server.address().port;
  const runtime = new CopilotRuntime({
    agents: { commander: attached ? attached.agent : new HttpAgent({ url: origin + agentPath }) },
    runner: new InMemoryAgentRunner(),
    identifyUser: () => ({ id: 'local-console', name: 'Local Console' }),
  });
  copilot = createCopilotNodeListener({
    runtime, basePath: '/api/copilotkit', hooks: { onBeforeHandler: resumeAttachedRun },
  });
  const address = origin + '/session/' + token;
  await writeFile(join(stateDir, 'console-url'), address + '\n', { mode: 0o600 });
  console.log(attached ? `Commander worker ${workerId} · launch URL in ${join(stateDir, 'console-url')}` : 'Focused Claude console · isolated data at ' + stateDir);
  if (process.argv.includes('--open')) {
    const opener = spawn('/usr/bin/open', ['-n', '-W', app, '--args', address], { stdio: 'inherit' });
    opener.once('error', error => { console.error(error); void shutdown(1); });
    opener.once('exit', code => void shutdown(code ?? 1));
  }
} catch (error) {
  console.error(error);
  await shutdown(1);
}
