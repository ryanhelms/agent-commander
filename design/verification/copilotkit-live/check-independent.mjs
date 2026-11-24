// Run with a prepared disposable worker and a locally installed Playwright browser.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const [appDirectory, workerId] = process.argv.slice(2);
const fixture = workerId === '--fixture';
if (!appDirectory || !workerId || (!fixture && !process.env.AGENT_COMMANDER_SOCKET)) {
  throw new Error('Pass the installed app directory and either --fixture or a held worker ID with AGENT_COMMANDER_SOCKET.');
}

const question = 'Which code confirms ASK-TOOL-RECEIPT?';
const prompt = `Call commander_ask with exactly this question: "${question}" Call commander_wait with the returned question ID. Reply with my exact answer after it arrives.`;
const answer = 'LAPIS-742';
const io = { stdio: ['ignore', 'pipe', 'inherit'] };
const server = fixture
  ? spawn('python3', [fileURLToPath(new URL('independent-fixture.py', import.meta.url)),
      '--agentctl', process.env.AGENTCTL || 'dist/agentctl', '--app', appDirectory], io)
  : spawn(process.execPath, ['run.mjs', '--worker', workerId], { ...io, cwd: appDirectory });
let browser;
try {
  const lines = createInterface({ input: server.stdout });
  const [url] = await Promise.race([once(lines, 'line'), once(server, 'exit').then(() => { throw new Error('Example exited before listening.'); })]);
  lines.close();
  browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_BIN });
  const page = await browser.newPage();
  page.setDefaultTimeout(120_000);
  const calls = [];
  page.on('response', response => calls.push([response.request().method(), new URL(response.url()).pathname, response.status()]));
  await page.goto(url);
  await page.getByText('Ready', { exact: true }).waitFor();
  await page.getByLabel('Prompt', { exact: true }).fill(prompt);
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  const request = page.locator('#pending form').filter({ hasText: question });
  await request.waitFor();
  const requestId = await request.getAttribute('data-request-id');
  assert.ok(requestId);

  const tool = page.locator('#results details').filter({ hasText: 'ASK-TOOL-RECEIPT' }).first();
  await tool.locator('summary').click();
  await tool.getByRole('button', { name: 'Open original ACP result' }).click();
  const fields = tool.locator('pre');
  await fields.nth(2).waitFor();
  const [projected, raw, observation] = await fields.allTextContents();
  assert.ok(projected.includes('ASK-TOOL-RECEIPT'));
  assert.ok(raw.includes('ASK-TOOL-RECEIPT'));
  assert.ok(JSON.parse(observation).cursor);
  assert.equal(await request.getAttribute('data-request-id'), requestId);

  await request.locator('input').fill(answer);
  await request.getByRole('button', { name: 'Answer' }).click();
  await page.getByText('Finished', { exact: true }).waitFor();
  assert.equal(await page.locator('#error').textContent(), '');
  assert.ok((await page.locator('#assistant').textContent()).includes(answer));
  for (const [method, path] of [['GET', '/copilotkit/info'], ['POST', '/copilotkit/agent/commander/run'], ['POST', '/reply']]) {
    assert.equal(calls.filter(([m, p, s]) => m === method && p === path && s === 200).length, 1);
  }
  console.log('CopilotKit discovered its agent, displayed the original tool result, answered its pending request once and received the exact assistant reply.');
} finally {
  await browser?.close();
  if (server.exitCode === null && server.signalCode === null) {
    const done = once(server, 'exit');
    server.kill(fixture ? 'SIGINT' : 'SIGTERM');
    await done;
  }
}
