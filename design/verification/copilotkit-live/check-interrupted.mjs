// Run against the standalone example after installing and building it in a separate directory.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const app = process.argv[2];
if (!app) throw new Error('Pass the directory of the installed example.');
const dir = await mkdtemp('/tmp/ac-browser-stream-');
const socket = join(dir, 'owner.sock');
const worker = 'w-fixture';
const steps = [];
let runId, restored = false, failNext = false;
const socketServer = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const base = '/v1/ag-ui/workers/' + worker;
  const json = (value, status = 200) => {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify(value));
  };
  const event = value => res.write('data: ' + JSON.stringify(value) + '\n\n');
  if (url.pathname === base) return json({ workerId: worker, client: 'fixture', generation: 2 });
  if (url.pathname === base + '/operations') {
    assert.equal(url.searchParams.get('runId'), runId);
    steps.push('receipt');
    return restored ? json({ runId, operationId: 'm-original' }) : json({ error: 'revoked' }, 403);
  }
  if (url.pathname === base + '/operations/m-original') {
    assert.equal(url.searchParams.get('runId'), runId);
    assert.equal(url.searchParams.get('frontendTools'), 'observe');
    steps.push('passive');
    res.writeHead(200, { 'content-type': 'text/event-stream', 'Commander-Frontend-Tools': 'observe' });
    event({ type: 'RUN_STARTED', threadId: worker, runId });
    event({ type: 'STATE_SNAPSHOT', snapshot: { operationId: 'm-original', operationStatus: 'completed' } });
    event({ type: 'RUN_FINISHED', threadId: worker, runId });
    return res.end();
  }
  assert.equal(url.pathname, base + '/run');
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  runId = JSON.parse(Buffer.concat(chunks)).runId;
  steps.push('submit');
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  event({ type: 'RUN_STARTED', threadId: worker, runId });
  event({ type: 'STATE_SNAPSHOT', snapshot: { operationId: 'm-original', operationStatus: failNext ? 'failed' : 'processing' } });
  if (failNext) event({ type: 'RUN_ERROR', message: 'Worker operation failed' });
  res.end();
});
let server, browser;
try {
  socketServer.listen(socket);
  await once(socketServer, 'listening');
  server = spawn(process.execPath, ['run.mjs', '--worker', worker], {
    cwd: app, env: { ...process.env, AGENT_COMMANDER_SOCKET: socket }, stdio: ['ignore', 'pipe', 'inherit'],
  });
  const lines = createInterface({ input: server.stdout });
  const [url] = await once(lines, 'line');
  lines.close();
  browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_BIN });
  const page = await browser.newPage();
  page.setDefaultTimeout(12_000);
  await page.goto(url);
  const status = text => page.getByText(text, { exact: true }).waitFor();
  const reconnect = page.getByRole('button', { name: 'Reconnect to this run' });
  const prompt = page.getByLabel('Prompt');
  const send = page.getByRole('button', { name: 'Send', exact: true });
  await status('Ready');
  await prompt.fill('Synthetic transport check.');
  await send.click();
  await status('Outcome unconfirmed');
  assert.equal(await send.isEnabled(), false);
  await reconnect.click();
  await status('Outcome unconfirmed');
  assert.equal(await send.isEnabled(), false);
  restored = true;
  await page.reload();
  await reconnect.click();
  await status('Finished');
  assert.equal(await send.isEnabled(), true);
  assert.deepEqual(steps, ['submit', 'receipt', 'receipt', 'passive']);
  failNext = true;
  await prompt.fill('Synthetic terminal failure.');
  await send.click();
  await status('Failed');
  assert.equal(await reconnect.isVisible(), false);
  assert.match(await page.locator('#error').textContent(), /Worker operation failed/);
  console.log('Browser kept the original run across EOF, denial and reload, recovered passively, and displayed the later terminal failure.');
} finally {
  await browser?.close();
  if (server && server.exitCode === null && !server.signalCode) {
    const done = once(server, 'exit');
    server.kill();
    await done;
  }
  socketServer.closeAllConnections();
  await new Promise(resolve => socketServer.close(resolve));
  await rm(dir, { recursive: true, force: true });
}
