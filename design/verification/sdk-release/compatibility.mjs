// Probe four installed ACP v1 endpoints with the independently distributed stock client.
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { Readable, Writable } from "node:stream";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs, promisify } from "node:util";

const run = promisify(execFile);
const { values } = parseArgs({ options: {
  "pi-translator": { type: "string" }, "harnesses": { type: "string" }, "list-probe": { type: "string" },
  "commander-cli": { type: "string" },
} });
if (!values["pi-translator"]) throw new Error("Supply --pi-translator with the built Pi translator fixture checkout.");
if (!values["list-probe"]) throw new Error("Supply --list-probe built against the pinned Commander SDK.");
const listProbe = resolve(values["list-probe"]);
const here = dirname(fileURLToPath(import.meta.url));
const pi = resolve(values["pi-translator"]);
const harnesses = resolve(values.harnesses ?? join(here, "../../../../agent-acp/harnesses/local"));
const require = createRequire(join(pi, "package.json"));
const { ClientSideConnection, ndJsonStream } = await import(pathToFileURL(require.resolve("@agentclientprotocol/sdk")));
const bins = join(harnesses, "node_modules/.bin");
const packages = async (directory) => JSON.parse(await readFile(join(directory, "package.json"), "utf8"));
const stockClient = await packages(join(pi, "node_modules/@agentclientprotocol/sdk"));
const peers = [
  { id: "claude", command: join(bins, "claude-agent-acp"), args: [], versionCommand: "claude",
    evidence: ["../incremental-native/README.md", "../copilotkit-live/README.md", "../sdk-runtime.md"] },
  { id: "codex", command: join(bins, "codex-acp"), args: [], versionCommand: "codex",
    evidence: ["../incremental-native/README.md", "../copilotkit-live/README.md", "../sdk-runtime.md"] },
  { id: "antigravity", command: "agy", args: ["acp", "--disable-telemetry", "--include-default-customizations=false"], versionCommand: "agy",
    evidence: ["../stock-acp.md", "../native-source/README.md"] },
  { id: "pi", command: process.execPath, args: [join(pi, "dist/index.js")], versionCommand: join(pi, "node_modules/.bin/pi"),
    evidence: ["../pi-translation.md", "../pi-rpc/verify.py"] },
];

async function probe(peer, root) {
  const cwd = join(root, peer.id);
  await mkdir(cwd);
  const env = { ...process.env };
  delete env.AGENT_COMMANDER_TOKEN;
  // The SDK child checks an empty workspace. Neither checker emits session IDs or titles.
  const version = await run(peer.versionCommand, ["--version"], { cwd, env, timeout: 10000 });
  const cliVersion = version.stdout.match(/\b\d+\.\d+\.\d+(?:[-+][\w.-]+)?\b/)?.[0];
  assert.ok(cliVersion, `no CLI version from ${peer.id}`);
  const child = spawn(peer.command, peer.args, { cwd, env, stdio: ["pipe", "pipe", "ignore"] });
  const exit = once(child, "exit");
  // Handle a missing or prematurely exited executable even before the first RPC completes.
  const failed = exit.then(() => { throw new Error(`${peer.id} exited before completing the probe`); });
  failed.catch(() => {});
  let deadline;
  const timeout = new Promise((_, reject) => {
    deadline = setTimeout(() => reject(new Error(`${peer.id} did not complete its ACP probe in 30 seconds`)), 30000);
  });
  const stream = ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(child.stdout));
  const client = new ClientSideConnection(() => ({
    async sessionUpdate() {},
    async requestPermission() { return { outcome: { outcome: "cancelled" } }; },
  }), stream);
  async function inspect() {
    const init = await client.initialize({ protocolVersion: 1, clientCapabilities: {} });
    assert.equal(init.protocolVersion, 1, peer.id);
    const caps = init.agentCapabilities ?? {};
    const session = caps.sessionCapabilities ?? {};
    const prompt = caps.promptCapabilities ?? {};
    const advertised = {
      loadSession: caps.loadSession === true,
      listSessions: session.list != null,
      resumeSession: session.resume != null,
      promptImage: prompt.image === true,
      promptAudio: prompt.audio === true,
      embeddedContext: prompt.embeddedContext === true,
    };
    let portable = null;
    if (advertised.listSessions) {
      const result = await run(listProbe, [cwd, peer.command, ...peer.args], { cwd, env, timeout: 27000 });
      portable = JSON.parse(result.stdout);
    }
    const agent = init.agentInfo ? { name: init.agentInfo.name, version: init.agentInfo.version } : null;
    return { harness: peer.id, cliVersion, agent, protocolVersion: init.protocolVersion, advertised,
      exercised: { stockInitialize: "verified", portableScopedList: portable ? "verified-empty-workspace" : "unadvertised" },
      sdk: portable, workflowEvidence: peer.evidence };
  }
  try {
    return await Promise.race([inspect(), failed, timeout]);
  } finally {
    clearTimeout(deadline);
    child.stdin.end();
    const stop = setTimeout(() => child.kill("SIGKILL"), 1250);
    try { await exit; } finally { clearTimeout(stop); }
  }
}

const root = await mkdtemp(join(tmpdir(), "commander-acp-compatibility-"));
try {
  const rows = [];
  for (const peer of peers) rows.push(await probe(peer, root));
  const sdk = rows.find(row => row.sdk)?.sdk;
  assert.ok(sdk, "at least one installed harness must support listing");
  for (const row of rows) {
    if (row.sdk) assert.deepEqual(row.sdk, sdk, "different portable SDK pins");
    delete row.sdk;
  }
  const moduleFile = await readFile(join(here, "../../../go.mod"), "utf8");
  const sums = await readFile(join(here, "../../../go.sum"), "utf8");
  const pin = moduleFile.match(/^\s*agent-acp\.local\/sdks\/go (v\S+)$/m)?.[1];
  assert.equal(sdk.version, pin, "the list probe must use the current Commander SDK pin");
  assert.ok(sums.split("\n").includes(`agent-acp.local/sdks/go ${sdk.version} ${sdk.sum}`),
    "the list probe checksum must match the Commander SDK pin");
  const { transport, ...commanderSDK } = sdk;
  const transportPin = moduleFile.match(/^[ \t]*agent-acp\.local\/transport[ \t]+(v\S+?)(?:[ \t]+\/\/[^\n]*)?[ \t]*$/m)?.[1];
  if (transportPin || transport) {
    assert.ok(transport, "the list probe must include the pinned ACP transport");
    if (transportPin) assert.equal(transport.version, transportPin, "the transport version must match the Commander pin");
    assert.ok(sums.split("\n").includes(`agent-acp.local/transport ${transport.version} ${transport.sum}`),
      "the transport checksum must match the Commander pin");
  }
  let commanderCLI;
  if (values["commander-cli"]) {
    const executable = resolve(values["commander-cli"]);
    const { stdout } = await run("go", ["version", "-m", executable]);
    const metadata = stdout.split("\n").map(line => line.trim().split("\t"));
    assert.ok(metadata.some(([kind, name]) => kind === "path" && name === "agentcommander/cmd/agentctl"),
      "the release executable must be agentctl");
    for (const [module, expected] of [["agent-acp.local/sdks/go", commanderSDK], ["agent-acp.local/transport", transport]]) {
      if (!expected) continue;
      const line = metadata.find(([kind, name]) => kind === "dep" && name === module);
      assert.deepEqual(line?.slice(2), [expected.version, expected.sum],
        `release agentctl and list probe must use the same checksummed ${module} archive`);
    }
    commanderCLI = { sha256: createHash("sha256").update(await readFile(executable)).digest("hex") };
  }
  process.stdout.write(JSON.stringify({ stockClient: { package: stockClient.name, version: stockClient.version },
    commanderSDK, ...(transport && { transport }), ...(commanderCLI && { commanderCLI }), harnesses: rows }, null, 2) + "\n");
} finally {
  await rm(root, { recursive: true, force: true });
}
