// Read only. Supply a disposable Commander service and its verified paired cold-session capture.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const [app, capturePath] = process.argv.slice(2);
if (!app || !capturePath || !process.env.AGENT_COMMANDER_SOCKET) throw new Error('Supply the installed example, its paired capture and AGENT_COMMANDER_SOCKET.');
const capture = JSON.parse(await readFile(capturePath, 'utf8'));
const reference = fileURLToPath(new URL('../../../poc/agui-console/', import.meta.url));
async function assertAttachment(page, section, owner, session) {
  const original = page.waitForResponse(response => new URL(response.url()).searchParams.get('recordCursor') === owner.cursor);
  await section.getByText('Open attachments (' + owner.itemCount + ')', { exact: true }).click();
  const response = await original;
  assert.equal(response.status(), 200);
  const result = await response.json();
  assert.deepEqual(result.observations.map(r => r.cursor), [owner.cursor]);
  await section.getByText('Attachment 1 · image/png', { exact: true }).click();
  const image = section.locator('img').first();
  await image.waitFor();
  const src = await image.getAttribute('src');
  assert.equal(src, 'data:image/png;base64,' + session.png);
  const pixels = await image.evaluate(async node => { await node.decode(); return [node.naturalWidth, node.naturalHeight]; });
  const bytes = Buffer.from(src.split(',')[1], 'base64');
  return bytes.length + ' bytes; ' + pixels.join('×') + '; ' + createHash('sha256').update(bytes).digest('hex');
}

const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_BIN });
try {
  for (const [harness, session] of Object.entries(capture.sessions)) {
    const worker = capture.event.snapshot.runs.flatMap(run => run.workers).find(w => w.id === session.worker);
    const message = worker.messages.find(m => m.metadata?.acp?.kind === 'provider_prompt_media');
    const owner = message?.metadata.acp;
    assert.ok(owner?.cursor);
    for (const mode of ['reference', 'independent']) {
      const attached = mode === 'reference';
      const child = spawn(process.execPath, [attached ? 'server.mjs' : 'run.mjs', '--worker', session.worker], {
        cwd: attached ? reference : app, stdio: ['ignore', 'pipe', 'inherit'],
      });
      const page = await browser.newPage();
      page.setDefaultTimeout(25_000);
      const requests = [];
      page.on('request', req => requests.push([req.method(), new URL(req.url()).pathname]));
      try {
        const lines = createInterface({ input: child.stdout });
        const [line] = await Promise.race([once(lines, 'line'), once(child, 'exit').then(() => { throw Error('Console exited before startup.'); })]);
        lines.close();
        const url = attached ? await readFile(line.match(/launch URL in (.+)$/)[1], 'utf8') : line;
        await page.goto(url.trim());
        await page.getByText(attached ? 'Provider history' : 'Open provider history', { exact: true }).click();
        const prompts = page.getByText('user message', { exact: true });
        await prompts.first().waitFor();
        let selected = false;
        for (const prompt of await prompts.all()) {
          await prompt.click();
          const record = prompt.locator('xpath=ancestor::details[1]');
          await record.locator('pre').first().waitFor();
          const open = record.getByText('Open attachments (' + owner.itemCount + ')', { exact: true });
          if (!(await open.count())) continue;
          console.log(mode, harness, 'cold history;', await assertAttachment(page, record, owner, session));
          selected = true;
          break;
        }
        assert.ok(selected, 'archived prompt could not open its attachment');
        // A cold archive has no new app-owned operation receipt. Replay its captured AG-UI
        // user message at the browser transport; exact source still comes from real Commander.
        const runId = 'archived-message-replay';
        const life = { threadId: session.worker, runId };
        await page.route('**/agent/commander/connect', async route => {
          const input = route.request().postDataJSON();
          if (!input?.forwardedProps?.commanderObserve || input.runId !== runId) return route.continue();
          const events = [{ type: 'RUN_STARTED', ...life }, { type: 'MESSAGES_SNAPSHOT', messages: [message] },
            { type: 'RUN_FINISHED', ...life }];
          await route.fulfill({ status: 200, contentType: 'text/event-stream', body: events.map(e => 'data: ' + JSON.stringify(e) + '\n\n').join('') });
        });
        await page.evaluate(([key, value]) => sessionStorage.setItem(key, value),
          [(attached ? 'commander.lastRun.' : 'commander.run.') + session.worker, runId]);
        await page.reload();
        if (!attached) await page.getByRole('button', { name: 'Reconnect to this run' }).click();
        const transcript = attached ? page.getByRole('list', { name: 'Session transcript' }) : page.locator('#user-media');
        console.log(mode, harness, 'recorded AG-UI prompt;', await assertAttachment(page, transcript, owner, session));
        assert.ok(!requests.some(([method, path]) => method === 'POST' && path.endsWith('/run')));
      } finally {
        await page.close();
        if (child.exitCode === null && !child.signalCode) {
          const done = once(child, 'exit');
          child.kill();
          await done;
        }
      }
    }
  }
} finally { await browser.close(); }
