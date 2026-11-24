import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { parseArgs } from 'node:util';
import { connectCommanderWorker } from '@agent-commander/copilotkit';

process.env.COPILOTKIT_TELEMETRY_DISABLED = 'true';
const { CopilotRuntime, InMemoryAgentRunner } = await import('@copilotkit/runtime/v2');
const { createCopilotNodeListener } = await import('@copilotkit/runtime/v2/node');
const { values: { worker: workerId } } = parseArgs({ options: { worker: { type: 'string' } } });
if (!workerId || !process.env.AGENT_COMMANDER_SOCKET) throw new Error('Set AGENT_COMMANDER_SOCKET and pass --worker ID.');

const lifetime = new AbortController();
const worker = connectCommanderWorker({ workerId, socketPath: process.env.AGENT_COMMANDER_SOCKET, signal: lifetime.signal });
const runtime = new CopilotRuntime({
  agents: { commander: worker.agent }, runner: new InMemoryAgentRunner(),
  forwardHeaders: { deny: ['authorization'] },
  identifyUser: () => ({ id: 'example-developer' }),
});
const copilot = createCopilotNodeListener({ runtime, basePath: '/copilotkit', hooks: {
  async onBeforeHandler({ request, route }) {
    if (route.method !== 'agent/connect' || route.agentId !== 'commander') return;
    const { threadId, runId, forwardedProps } = await request.clone().json();
    if (forwardedProps?.commanderObserve !== true) return;
    if (threadId !== workerId || typeof runId !== 'string' || !runId || runId.length > 128) {
      throw Response.json({ error: 'Expected this worker and its original run ID.' }, { status: 400 });
    }
    throw await worker.observeRun({ runId, signal: request.signal, dispatchTools: false });
  },
} });
const html = await readFile(new URL('./index.html', import.meta.url));
const css = await readFile(new URL('./styles.css', import.meta.url));
const js = await readFile(new URL('./dist/client.js', import.meta.url));
const token = randomUUID();

async function forward(response, upstream) {
  response.writeHead(upstream.status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(Buffer.from(await upstream.arrayBuffer()));
}

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://localhost');
    if (url.pathname === '/favicon.ico') return response.writeHead(204).end();
    if (request.method === 'GET' && ['/', '/client.js', '/styles.css'].includes(url.pathname)) {
      const home = url.pathname === '/';
      response.writeHead(200, { 'content-type': home ? 'text/html; charset=utf-8' : url.pathname === '/styles.css' ? 'text/css' : 'text/javascript',
        'content-security-policy': "default-src 'self'; img-src 'self' data:; media-src data:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'" });
      response.end(home ? html : url.pathname === '/styles.css' ? css : js);
      return;
    }
    if (request.headers.authorization !== 'Bearer ' + token) return response.writeHead(403).end();
    if (url.pathname.startsWith('/copilotkit/')) return await copilot(request, response);
    if (request.method === 'GET' && url.pathname === '/worker') return await forward(response, await worker.workerInfo());
    if (request.method === 'GET' && url.pathname === '/source') {
      const recordCursor = url.searchParams.get('recordCursor') ?? undefined;
      const source = recordCursor !== undefined ? 'provider' : url.searchParams.has('turnId') ? 'live' : undefined;
      return await forward(response, await worker.readHistory({ source, recordCursor, limit: recordCursor === undefined ? 32 : undefined,
        cursor: url.searchParams.get('cursor') ?? undefined, turnId: url.searchParams.get('turnId') ?? undefined }));
    }
    if (request.method === 'POST' && url.pathname === '/reply') {
      let size = 0;
      const parts = [];
      for await (const part of request) {
        size += part.length;
        if (size > 64 * 1024) return response.writeHead(413).end();
        parts.push(part);
      }
      const { requestId, generation, answer, idempotencyKey } = JSON.parse(Buffer.concat(parts).toString('utf8'));
      return await forward(response, await worker.reply({ requestId, generation, answer, idempotencyKey }));
    }
    response.writeHead(404).end();
  } catch (error) {
    if (!response.headersSent) response.writeHead(500, { 'content-type': 'text/plain' });
    response.end(error.message);
  }
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
console.log(`http://127.0.0.1:${server.address().port}/#${token}`);
function close() {
  lifetime.abort();
  server.close();
  server.closeAllConnections();
}
process.once('SIGINT', close);
process.once('SIGTERM', close);
