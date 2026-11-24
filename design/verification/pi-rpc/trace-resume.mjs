// Relay ACP stdio verbatim. Record only process IDs, method names and hashed
// fixture session identities so cold resume can be checked independently.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const [trace, adapter] = process.argv.slice(2);
const child = spawn(process.execPath, [adapter], { stdio: ["pipe", "pipe", "inherit"] });
const opens = new Set();
const hash = id => createHash("sha256").update(id).digest("hex");
function record(method, id) {
  appendFileSync(trace, JSON.stringify({ pid: child.pid, method, session: id && hash(id) }) + "\n", { mode: 0o600 });
}
function observe(input, receive) {
  const lines = createInterface({input});
  lines.on("line", line => receive(JSON.parse(line)));
}
observe(process.stdin, msg => {
  if (msg.method === "session/new") opens.add(msg.id);
  else if (["session/resume", "session/prompt", "session/cancel"].includes(msg.method)) {
    record(msg.method, msg.params.sessionId);
  }
});
observe(child.stdout, msg => {
  if (opens.delete(msg.id) && msg.result?.sessionId) record("created", msg.result.sessionId);
});
process.stdin.pipe(child.stdin);
child.stdout.pipe(process.stdout);
child.on("error", err => { console.error(err); process.exitCode = 1; });
child.stdin.on("error", err => { if (err.code !== "EPIPE") throw err; });
child.on("exit", (code, signal) => {
  record("exited");
  process.stdin.destroy();
  process.exitCode = code ?? (signal ? 1 : 0);
});
