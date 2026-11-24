import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { get } from "node:http";
import { createServer } from "node:https";
import { basename, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import { parseArgs, promisify } from "node:util";

const { values } = parseArgs({options: {
  agentctl: {type: "string"}, "catalog-test": {type: "string"}, serve: {type: "boolean"},
}});
assert.ok(values.agentctl, "supply --agentctl PATH");
const binary = resolve(values.agentctl);
const cli = values["catalog-test"] ? resolve(values["catalog-test"]) : binary;
const testArgs = values["catalog-test"] ? ["-test.run=^TestCatalogFixtureCLI$", "--"] : [];
const run = promisify(execFile);
const id = "catalog-fixture";
const empty = {updates: []};
const root = await mkdtemp("/tmp/ac-notice-");
const certPath = join(root, "tls.pem");
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
  !key.startsWith("AGENT_COMMANDER_") && !key.startsWith("COMMANDER_")));
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const services = [], readers = [];
let registry;

function archive(version) {
  return Buffer.from("#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' " +
    "'{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1}}'\n# " + version + "\n");
}

async function startRegistry() {
  const cfg = join(root, "openssl.cnf");
  await writeFile(cfg, "[req]\ndistinguished_name=sub\nx509_extensions=ext\nprompt=no\n" +
    "[sub]\nCN=Commander fixture\n[ext]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n");
  const tlsKey = join(root, "tls-key.pem");
  await run("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
    "-config", cfg, "-keyout", tlsKey, "-out", certPath]);
  const {publicKey, privateKey} = generateKeyPairSync("ed25519");
  const keyFile = join(root, "publisher.pem");
  await writeFile(keyFile, publicKey.export({type: "spki", format: "pem"}));
  const site = {badSignature: false, downloads: 0, keyFile};
  registry = createServer({key: await readFile(tlsKey), cert: await readFile(certPath)}, (req, res) => {
    switch (req.url) {
      case "/registry": return res.end(site.list);
      case "/entry": return res.end(site.entry);
      case "/sig": return res.end(site.badSignature ? Buffer.alloc(64) : site.sig);
      case "/2.0.0": site.downloads++; return res.end(archive("2.0.0"));
      case "/1.0.0": return res.end(archive("1.0.0"));
      default: res.writeHead(404); res.end();
    }
  });
  await new Promise((ok, fail) => registry.once("error", fail).listen(0, "127.0.0.1", ok));
  site.url = "https://127.0.0.1:" + registry.address().port;
  site.publish = version => {
    const platform = process.platform + "-" + ({arm64: "aarch64", x64: "x86_64"})[process.arch];
    const entry = {id, name: "Catalog fixture", version, distribution: {binary: {
      [platform]: {archive: site.url + "/" + version, cmd: "./adapter", sha256: sha(archive(version))},
    }}};
    site.entry = Buffer.from(JSON.stringify(entry));
    site.sig = sign(null, site.entry, privateKey);
    site.list = JSON.stringify({version: "1.0.0", agents: [entry]});
  };
  return site;
}

async function waitFor(check, description, timeout = 15000) {
  const end = performance.now() + timeout;
  while (!check() && performance.now() < end) await delay(40);
  assert.ok(check(), "Timed out waiting for " + description);
}

async function service(name) {
  const dir = join(root, name);
  const socket = join(dir, "s.sock");
  await mkdir(dir, {mode: 0o700});
  const marker = name + " retained conversation";
  const worker = {id: "archived-worker", role: "coordinator", run_id: "archived-run", name: "Archived",
    state: "completed", client: "fixture", host: "local", worktree: dir, task: "Earlier assignment",
    output: marker, console: [{kind: "text", sequence: 1, text: marker}]};
  const archived = {id: worker.run_id, coordinator_id: worker.id, status: "completed", project: "Catalog fixture",
    title: "Archived conversation", task: worker.task, path: dir, client: worker.client, workers: [worker], requests: []};
  await writeFile(join(dir, "state.json"), JSON.stringify({runs: [archived]}), {mode: 0o600});
  const localEnv = {...env, AGENT_COMMANDER_HOME: dir, AGENT_COMMANDER_SOCKET: socket, NO_PROXY: "127.0.0.1"};
  const command = async (...args) => {
    const result = await run(cli, [...testArgs, "catalog", ...args], {timeout: 22000, env: {...localEnv,
      SSL_CERT_FILE: certPath, COMMANDER_TEST_CATALOG_CA: certPath}});
    return result.stdout.trim() ? JSON.parse(result.stdout) : undefined;
  };
  const proc = spawn(binary, ["serve"], {env: localEnv, stdio: ["ignore", "ignore", "inherit"]});
  const stopped = once(proc, "exit");
  services.push(async () => { if (proc.exitCode === null) proc.kill("SIGTERM"); await stopped; });
  const response = path => new Promise((ok, fail) => get({socketPath: socket, path}, ok).on("error", fail));
  const json = async path => {
    const res = await response(path);
    assert.equal(res.statusCode, 200);
    let text = "";
    for await (const part of res) text += part;
    return JSON.parse(text);
  };
  const deadline = performance.now() + 30000;
  for (;;) {
    try { await json("/v1/health"); break; } catch (err) {
      if (proc.exitCode !== null || proc.signalCode || performance.now() >= deadline) {
        throw new Error("Commander service unavailable at " + socket + " (exit " +
          (proc.exitCode ?? proc.signalCode ?? "pending") + ")", {cause: err});
      }
      await delay(80);
    }
  }
  return {dir, socket, command, json, response, marker};
}

async function subscribe(host) {
  const response = await host.response("/v1/catalog/notices/events");
  assert.equal(response.statusCode, 200);
  assert.equal(response.headers["content-type"], "text/event-stream");
  const stream = {frames: [], beats: 0, error: null, close: () => response.destroy()};
  readers.push(stream);
  const lines = createInterface({input: response});
  response.on("error", err => stream.error = err);
  lines.on("error", err => stream.error = err);
  lines.on("line", line => {
    if (line.startsWith("data: ")) {
      try { stream.frames.push(JSON.parse(line.slice(6))); } catch (err) { stream.error = err; }
    } else if (line === ": heartbeat") stream.beats++;
  });
  stream.expect = async (index, frame) => {
    await waitFor(() => stream.error || stream.frames.length > index, "SSE data frame " + index);
    if (stream.error) throw stream.error;
    assert.deepEqual(stream.frames[index], frame);
  };
  stream.heartbeat = async () => {
    const beats = stream.beats;
    await waitFor(() => stream.error || stream.beats > beats, "a fresh server heartbeat");
    if (stream.error) throw stream.error;
  };
  return stream;
}

async function install(host, site) {
  const entry = join(root, "initial.json"), sig = join(root, "initial.sig");
  await writeFile(entry, site.entry);
  await writeFile(sig, site.sig);
  const stage = await host.command("stage-binary", site.url + "/registry", id, "1.0.0", entry, sig, site.keyFile);
  const current = await host.command("activate", basename(stage.directory), stage.publisher_key_sha256);
  await host.command("update-source", id, site.url + "/entry", site.url + "/sig", site.keyFile);
  assert.equal(await host.command("refresh", id), null);
  return current;
}

async function verify(primary, other, site, initial) {
  const a = await subscribe(primary), b = await subscribe(other);
  await Promise.all([a.expect(0, empty), b.expect(0, empty)]);
  const runs = await primary.json("/v1/runs");
  const transcript = await primary.json("/v1/runs/archived-run?view=ag-ui");
  assert.ok(JSON.stringify(transcript).includes(primary.marker), "missing unrelated archived conversation");
  const notice = {updates: [{adapterId: id, currentVersion: "1.0.0", availableVersion: "2.0.0",
    manifestSHA256: sha(site.entry)}]};
  const pin = async () => JSON.parse(await readFile(join(primary.dir, "catalog", "pins", id + ".json")));
  site.badSignature = true;
  await assert.rejects(primary.command("refresh", id), /signature did not verify/);
  assert.equal(site.downloads, 0);
  site.badSignature = false;
  await other.command("refresh", id);
  await b.expect(1, notice);
  await a.heartbeat();
  assert.deepEqual(a.frames, [empty], "unverified or foreign refresh reached this service");
  const before = site.downloads;
  const updates = await Promise.all([primary.command("refresh", id), primary.command("refresh", id)]);
  const update = updates[0];
  assert.equal(updates[1].stage, update.stage);
  assert.equal(update.manifest_sha256, notice.updates[0].manifestSHA256);
  assert.equal(site.downloads, before + 1);
  assert.deepEqual((await pin()).current, initial);
  await a.expect(1, notice);
  const again = await subscribe(primary);
  await again.expect(0, notice);
  assert.equal((await primary.command("refresh", id)).stage, update.stage);
  await a.heartbeat();
  assert.deepEqual(a.frames, [empty, notice], "repeated refresh emitted another change");
  const installed = await primary.command("activate", update.stage, update.publisher_key_sha256);
  assert.equal(installed.version, "2.0.0");
  await Promise.all([a.expect(2, empty), again.expect(1, empty)]);
  assert.equal((await primary.command("rollback", id)).command, initial.command);
  const rolled = await subscribe(primary);
  await rolled.expect(0, empty);
  assert.deepEqual((await pin()).current, initial);
  assert.equal((await primary.command("refresh", id)).stage, update.stage);
  await Promise.all([a.expect(3, notice), again.expect(2, notice), rolled.expect(1, notice)]);
  assert.deepEqual(b.frames, [empty, notice], "another owner observed this service's clear and reoffer");
  assert.deepEqual(await primary.json("/v1/runs"), runs);
  assert.deepEqual(await primary.json("/v1/runs/archived-run?view=ag-ui"), transcript);
  return {adapter: id, stage: update.stage, stream: a.frames, reconnect: again.frames,
    afterRollback: rolled.frames, independentOwner: b.frames, archiveDownloadsPerOwner: 1};
}

async function interactive(host) {
  console.log(JSON.stringify({socket: host.socket, state: host.dir, agentctl: binary, adapter: id}));
  console.log("Enter refresh, activate, rollback or quit. The signed 2.0.0 release is ready.");
  let staged;
  for await (const input of createInterface({input: process.stdin})) {
    try {
      switch (input.trim()) {
        case "refresh": staged = await host.command("refresh", id); console.log("refresh", staged?.version ?? null); break;
        case "activate":
          assert.ok(staged, "refresh first");
          console.log("activated", (await host.command("activate", staged.stage, staged.publisher_key_sha256)).version);
          break;
        case "rollback": console.log("rolled back", (await host.command("rollback", id)).version); break;
        case "quit": process.stdin.unref?.(); return;
        default: console.log("Expected refresh, activate, rollback or quit");
      }
    } catch (err) { console.error(err.message); }
  }
}

try {
  const site = await startRegistry();
  site.publish("1.0.0");
  const primary = await service("primary"), initial = await install(primary, site);
  const other = values.serve ? undefined : await service("other");
  if (other) await install(other, site);
  site.publish("2.0.0");
  if (values.serve) await interactive(primary);
  else console.log(JSON.stringify(await verify(primary, other, site, initial), null, 2));
} finally {
  for (const reader of readers) reader.close();
  await Promise.all(services.map(stop => stop()));
  if (registry) await new Promise(done => registry.close(done));
  await rm(root, {recursive: true, force: true});
}
