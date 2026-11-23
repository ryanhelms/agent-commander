import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { copyFile, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createServer, request } from 'node:http';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { HttpAgent } from '@ag-ui/client';
import { EventType } from '@ag-ui/core';

process.env.COPILOTKIT_TELEMETRY_DISABLED = 'true';
const { CopilotRuntime, InMemoryAgentRunner } = await import('@copilotkit/runtime/v2');
const { createCopilotNodeListener } = await import('@copilotkit/runtime/v2/node');

const dir = fileURLToPath(new URL('.', import.meta.url));
const app = join(dir, 'dist', 'Agent Commander Console.app');
const stateDir = await mkdtemp('/tmp/ac-agui-');
const socketPath = join(stateDir, 'service.sock');
const workspace = join(stateDir, 'sample');
await mkdir(workspace, { mode: 0o700 });
await copyFile(join(dir, 'sample', 'scenario.md'), join(workspace, 'scenario.md'));
const launchKey = randomUUID();
const cookieName = 'ac_console_session';
const token = randomBytes(24).toString('hex');
const agentPath = '/_agent/' + token;
const tmuxLabel = 'ac-' + createHash('sha256').update(stateDir).digest('hex').slice(0, 12);
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

const service = spawn(join(dir, 'dist', 'agentctl'), ['serve'], {
  env: {
    ...process.env,
    AGENT_COMMANDER_HOME: stateDir,
    AGENT_COMMANDER_SOCKET: socketPath,
    AGENT_COMMANDER_FOCUSED_PROOF: '1',
  },
  stdio: ['ignore', 'ignore', 'inherit'],
});
let serviceError;
service.on('error', error => { serviceError = error; });

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
    if (service.exitCode !== null) throw new Error('Commander service exited during startup.');
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

function sendText(send, messageId, content) {
  send({ type: EventType.TEXT_MESSAGE_START, messageId, role: 'assistant' });
  send({ type: EventType.TEXT_MESSAGE_CONTENT, messageId, delta: content });
  send({ type: EventType.TEXT_MESSAGE_END, messageId });
}

function translate(send, item, workerID, tools) {
  if (item.kind === 'text' && item.text) {
    sendText(send, workerID + ':' + item.sequence, item.text);
  } else if (item.kind === 'tool_call' && item.tool_id && !tools.has(item.tool_id)) {
    tools.add(item.tool_id);
    send({ type: EventType.TOOL_CALL_START, toolCallId: item.tool_id, toolCallName: item.name });
    if (item.text) {
      send({ type: EventType.TOOL_CALL_ARGS, toolCallId: item.tool_id, delta: JSON.stringify({ detail: item.text }) });
    }
    send({ type: EventType.TOOL_CALL_END, toolCallId: item.tool_id });
  } else if (item.kind === 'tool_result' && tools.has(item.tool_id)) {
    send({ type: EventType.TOOL_CALL_RESULT, toolCallId: item.tool_id, messageId: workerID + ':' + item.sequence,
      role: 'tool', content: item.text || 'Tool completed.' });
  }
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
    let run = await startRun();
    let previousSequence = 0;
    let previousSnapshot = '';
    const toolCalls = new Set();
    while (!disconnect.signal.aborted) {
      const { terminal, snapshot, worker } = runState(run);
      for (const event of worker.console || []) {
        if (event.sequence > previousSequence) {
          translate(send, event, worker.id, toolCalls);
          previousSequence = event.sequence;
        }
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
      run = await commander('/v1/runs/' + run.id);
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

const assets = new Map([
  ['/', { file: 'ui/index.html', type: 'text/html; charset=utf-8' }],
  ['/ui.js', { file: 'dist/ui.js', type: 'text/javascript; charset=utf-8' }],
  ['/ui.css', { file: 'dist/ui.css', type: 'text/css; charset=utf-8' }],
]);
let copilot;
let origin;
const server = createServer(async (req, res) => {
  try {
    if (req.headers.host !== new URL(origin).host) throw new HTTPError(403, 'Expected the local console address.');
    const { pathname } = new URL(req.url, origin);
    res.setHeader('cache-control', 'no-store');
    res.setHeader('x-content-type-options', 'nosniff');
    if (req.method === 'GET' && pathname === '/session/' + token) {
      res.writeHead(303, { location: '/', 'set-cookie': cookieName + '=' + token + '; Path=/; HttpOnly; SameSite=Strict' });
      return res.end();
    }
    if (req.method === 'POST' && pathname === agentPath) return await serveAgent(req, res);
    const cookies = (req.headers.cookie || '').split(';').map(value => value.trim());
    if (!cookies.includes(cookieName + '=' + token)) throw new HTTPError(403, 'Open the console from its launcher.');
    if (req.headers.origin && req.headers.origin !== origin) throw new HTTPError(403, 'Unexpected request origin.');
    if (pathname.startsWith('/api/copilotkit/')) return copilot(req, res);
    if (req.method === 'POST' && pathname === '/reply') return await reply(req, res);
    const asset = assets.get(pathname);
    if (req.method !== 'GET' || !asset) throw new HTTPError(404, 'Page unavailable.');
    const content = await readFile(join(dir, asset.file));
    res.writeHead(200, {
      'content-type': asset.type,
      'content-security-policy': "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'",
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
    server.close();
    server.closeAllConnections();
    service.kill();
    process.exitCode = exitCode;
  }
}

process.once('SIGINT', () => void shutdown());
process.once('SIGTERM', () => void shutdown());

try {
  await waitForService();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  origin = 'http://127.0.0.1:' + server.address().port;
  const runtime = new CopilotRuntime({
    agents: { claude: new HttpAgent({ url: origin + agentPath }) },
    runner: new InMemoryAgentRunner(),
    identifyUser: () => ({ id: 'local-console', name: 'Local Console' }),
  });
  copilot = createCopilotNodeListener({ runtime, basePath: '/api/copilotkit' });
  const address = origin + '/session/' + token;
  await writeFile(join(stateDir, 'console-url'), address + '\n', { mode: 0o600 });
  console.log('Focused Claude console · isolated data at ' + stateDir);
  if (process.argv.includes('--open')) {
    const opener = spawn('/usr/bin/open', ['-n', '-W', app, '--args', address], { stdio: 'inherit' });
    opener.once('error', error => { console.error(error); void shutdown(1); });
    opener.once('exit', code => void shutdown(code ?? 1));
  }
} catch (error) {
  console.error(error);
  await shutdown(1);
}
