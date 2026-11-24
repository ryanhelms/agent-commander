#!/usr/bin/env python3
"""Exercise four disposable vendor journals through Commander's native source inspector."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import http.client
import socket
from contextlib import closing
import tempfile
import time
import uuid
import zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def png(rgb):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    header = struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)
    scanlines = (b"\0" + bytes(rgb) * 2) * 2
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b"")


def journal(root, checkout, client, slot):
    worker = f"fixture-{client}-{slot}"
    session = str(uuid.uuid5(uuid.NAMESPACE_DNS, worker))
    color = (32 + 64 * slot, 96 if client == "claude" else 192, 24)
    image = base64.b64encode(png(color)).decode("ascii")
    claude = client == "claude"
    if claude:
        folder = re.sub(r"[^a-zA-Z0-9-]", "-", str(checkout))
        path = root / "claude/projects" / folder / f"{session}.jsonl"
        fixture = "claude-journal.jsonl"
    else:
        folder = "sessions/2026/11/23" if slot == 1 else "archived_sessions"
        path = root / "codex" / folder / f"rollout-2026-11-23T00-00-00-{session}.jsonl"
        fixture = "codex-rollout.jsonl"
    original = []
    source = []
    if not claude:
        header = {"type": "session_meta", "payload": {"id": session, "cwd": str(checkout), "cli_version": "0.171.0"}}
        source.append(json.dumps(header))
    for line in (HERE / fixture).read_text().splitlines():
        # The shared fixtures use a short media placeholder. Put a distinct, real
        # PNG into the same source field for each session.
        row = json.loads(line.replace("AAE=", image))
        row["journalFixture"] = {"worker": worker, "counter": 9007199254740993, "optional": None}
        if claude:
            row.update(cwd=str(checkout), sessionId=session, version="2.1.330")
        encoded = json.dumps(row, ensure_ascii=False, separators=(",", ":"))
        source.append(encoded)
        original.append(base64.b64encode((encoded + "\n").encode()).decode("ascii"))
    if claude:
        unsupported = {"type": "assistant", "sessionId": session, "cwd": str(checkout), "version": "99.0.0"}
        reason = "Claude journal version has no verified reader"
    else:
        unsupported = {"type": "future-native-event", "payload": {"type": "future-item"}}
        reason = "Codex journal contains an unrecognized record type"
    unsupported["privateBody"] = "UNRECOGNIZED_" + worker
    source.append(json.dumps(unsupported))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(source) + "\n")
    path.chmod(0o400)
    return path, dict(worker=worker, client=client, session=session, originals=original, png=image, gap=reason)


def send_acp_text(endpoint, samples, tokens):
    class Connection(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.settimeout(5)
            self.sock.connect(str(endpoint))

    for sample in samples:
        worker = sample["worker"]
        marker = "VISIBLE-ACP-" + worker
        event = {"kind": "text", "text": marker, "acp": {"source": "live", "cursor": "src-" + worker,
                 "turnId": "turn-" + worker, "kind": "agent_message_chunk", "contentType": "text"}}
        with closing(Connection("localhost")) as conn:
            conn.request("POST", "/v1/workers/" + worker + "/output", json.dumps({"text": marker, "events": [event]}),
                         {"Content-Type": "application/json", "Authorization": "Bearer " + tokens[worker],
                          "Idempotency-Key": "seed-" + worker})
            response = conn.getresponse()
            if response.status != 200:
                raise RuntimeError(f"Failed to publish fixture ACP text for {worker}: {response.read()!r}")


def verify(binary, root, interactive=False):
    checkout = root / "same checkout"
    checkout.mkdir()
    state = root / "commander"
    state.mkdir()
    sources = [journal(root, checkout, client, slot) for client in ("claude", "codex") for slot in (1, 2)]
    before = {path: path.read_bytes() for path, _ in sources}
    # Restore fixture worker identities without launching a CLI or tmux process.
    samples = [example for _, example in sources]
    workers = [dict(id=s["worker"], name=s["worker"], client=s["client"], worktree=str(checkout),
                    run_id="fixture-run", state="unknown", host="local", role="worker", parent_id="fixture-claude-1", task="Journal recovery fixture",
                    native_session={"harness_instance": "local-" + s["client"], "session_id": s["session"]})
               for s in samples]
    workers[0].update(role="coordinator", parent_id="")
    run = dict(id="fixture-run", status="running", task="Journal recovery acceptance", title="Journal recovery", project="Journal acceptance", path=str(checkout),
               coordinator_id=workers[0]["id"], client="claude", workers=workers, requests=[])
    tokens = {w["id"]: uuid.uuid4().hex for w in workers}
    (state / "state.json").write_text(json.dumps({"runs": [run], "tokens":
        {hashlib.sha256(token.encode()).hexdigest(): worker for worker, token in tokens.items()}}))
    manifest = root / "expected.json"
    manifest.write_text(json.dumps(samples))
    socket = root / "s.sock"
    receipt = root / "verified.json"
    env = {key: value for key, value in os.environ.items() if not key.startswith(("AGENT_COMMANDER_", "COMMANDER_"))}
    env.update(AGENT_COMMANDER_HOME=str(state), AGENT_COMMANDER_SOCKET=str(socket),
               CLAUDE_CONFIG_DIR=str(root / "claude"), CODEX_HOME=str(root / "codex"))
    with (root / "service.log").open("w") as log:
        proc = subprocess.Popen([binary, "serve"], env=env, stdout=log, stderr=log)
        try:
            for _ in range(200):
                if socket.is_socket():
                    break
                if proc.poll() is not None:
                    raise RuntimeError("The isolated Commander service exited")
                time.sleep(0.025)
            else:
                raise RuntimeError("The isolated Commander socket was unavailable")
            send_acp_text(socket, samples, tokens)
            test_env = env | {"COMMANDER_JOURNAL_FIXTURE": str(manifest), "COMMANDER_JOURNAL_RECEIPT": str(receipt)}
            if interactive:
                print(f"QA socket {socket}\nQA workers " + ", ".join(s["worker"] for s in samples), flush=True)
                input("Press return to close the isolated journal service.\n")
            else:
                subprocess.run(["make", "test-native"], cwd=ROOT, env=test_env, check=True)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
    confirmed = []
    if not interactive:
        confirmed = json.loads(receipt.read_text())
        want = sorted(s["worker"] + "/" + mode for s in samples for mode in ("pretty", "console"))
        if confirmed != want:
            raise RuntimeError("The native test did not complete all eight selections")
    if any(path.read_bytes() != content for path, content in before.items()):
        raise RuntimeError("A provider journal changed during inspection")
    return {"selections": confirmed, "byteIdentical": {s["worker"]: hashlib.sha256(before[path]).hexdigest()
                                                       for path, s in sources}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agentctl", type=Path, required=True)
    parser.add_argument("--serve", action="store_true", help="keep the isolated fixture open for native QA until Return")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ac-journal-", dir="/tmp") as tmp:
        result = verify(args.agentctl.resolve(strict=True), Path(tmp).resolve(), args.serve)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
