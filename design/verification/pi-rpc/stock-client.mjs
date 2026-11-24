// Exercise the installed translator directly with the official ACP client library.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import { Readable, Writable } from "node:stream";
import { pathToFileURL } from "node:url";

const [translator, cwd, trace, prompt] = process.argv.slice(2);
const require = createRequire(join(translator, "package.json"));
const { ClientSideConnection, ndJsonStream } = await import(pathToFileURL(require.resolve("@agentclientprotocol/sdk")));
const agent = spawn(process.execPath, [join(translator, "dist/index.js")], { cwd, stdio: ["pipe", "pipe", "inherit"] });
const stream = ndJsonStream(Writable.toWeb(agent.stdin), Readable.toWeb(agent.stdout));
const updates = { live: [], replay: [] };
let phase = "live";
let sessionId;
const observedSessions = new Set();
let permissions = 0;
const client = new ClientSideConnection(() => ({
  async sessionUpdate(notification) {
    observedSessions.add(notification.sessionId);
    updates[phase].push(notification.update);
  },
  async requestPermission(request) {
    assert.equal(request.sessionId, sessionId);
    assert.equal(phase, "live");
    assert.equal(request.toolCall.toolCallId, "call_fixture_read");
    assert.equal(request.toolCall.rawInput.path, "sample.txt");
    permissions++;
    const choice = request.options.find(option => option.kind === "allow_once");
    assert.ok(choice);
    return { outcome: { outcome: "selected", optionId: choice.optionId } };
  },
}), stream);
try {
  const { protocolVersion } = await client.initialize({ protocolVersion: 1, clientCapabilities: {} });
  assert.equal(protocolVersion, 1);
  ({ sessionId } = await client.newSession({ cwd, mcpServers: [] }));
  const result = await client.prompt({ sessionId, prompt: [{ type: "text", text: prompt }] });
  assert.equal(result.stopReason, "end_turn");
  const { sessions } = await client.listSessions({ cwd });
  assert.ok(sessions.some(session => session.sessionId === sessionId));
  await client.closeSession({ sessionId });
  phase = "replay";
  await client.loadSession({ cwd, sessionId, mcpServers: [] });
  await client.closeSession({ sessionId });
  assert.equal(permissions, 1);
  assert.deepEqual([...observedSessions], [sessionId]);
  await writeFile(trace, JSON.stringify(updates), { mode: 0o600 });
} finally {
  agent.stdin.end();
}
