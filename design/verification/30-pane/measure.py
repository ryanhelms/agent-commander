#!/usr/bin/env python3
"""Measure a pinned Commander service with 30 disposable tmux panes."""
import argparse
import base64
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import re
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time


PANES = 30
SAMPLES = 6
ATTACHMENT = "Q09NTUFOREVSX0FUVEFDSE1FTlRfRklYVFVSRS4h" * 14000
MARKER = ATTACHMENT[:120]


class LocalHTTP(http.client.HTTPConnection):
    def __init__(self, socket_path):
        super().__init__("localhost", timeout=15)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.socket_path))


def api(path, method, route, data=None, expected=200):
    with contextlib.closing(LocalHTTP(path)) as connection:
        body = json.dumps(data) if data is not None else None
        connection.request(method, route, body, {"Content-Type": "application/json"})
        reply = connection.getresponse()
        result = json.loads(reply.read())
        if reply.status != expected:
            raise RuntimeError(f"{method} {route}: expected {expected}, received {reply.status}: {result}")
        return result


def apply_delta(state, patches):
    for patch in patches:
        parts = [key.replace("~1", "/").replace("~0", "~") for key in patch["path"][1:].split("/")]
        parent = state
        for key in parts[:-1]:
            parent = parent[int(key)] if isinstance(parent, list) else parent[key]
        key = parts[-1]
        if isinstance(parent, list):
            key = len(parent) if key == "-" else int(key)
        if patch["op"] == "remove":
            del parent[key]
        elif patch["op"] == "add" and isinstance(parent, list):
            parent.insert(key, patch["value"])
        elif patch["op"] in ("add", "replace"):
            parent[key] = patch["value"]
        else:
            raise ValueError(f"unsupported patch {patch['op']}")


class Workspace:
    def __init__(self, path, route="/v1/ag-ui/events"):
        self.route = route
        self.connection = LocalHTTP(path)
        self.ready = threading.Condition()
        self.frames = 0
        self.payload_bytes = 0
        self.leaked = False
        self.error = None
        self.runs = []
        self.requested = time.monotonic()
        self.connection.request("GET", route)
        self.response = self.connection.getresponse()
        if self.response.status != 200:
            raise RuntimeError(f"Workspace response: {self.response.status}")
        self.thread = threading.Thread(target=self._follow, daemon=True)
        self.thread.start()

    def _follow(self):
        try:
            for line in self.response:
                if not line.startswith(b"data: "):
                    continue
                raw = line[6:]
                event = json.loads(raw)
                with self.ready:
                    self.frames += 1
                    self.payload_bytes += len(raw)
                    self.leaked = self.leaked or MARKER.encode() in raw
                    if event["type"] == "STATE_SNAPSHOT":
                        self.runs = event["snapshot"]["runs"]
                    elif event["type"] == "STATE_DELTA":
                        state = {"runs": self.runs}
                        apply_delta(state, event["delta"])
                        self.runs = state["runs"]
                    self.ready.notify_all()
        except Exception as error:
            with self.ready:
                self.error = error
                self.ready.notify_all()

    def until(self, predicate, label, timeout=20):
        with self.ready:
            def ready():
                return predicate(self.runs) or self.error is not None

            if not self.ready.wait_for(ready, timeout):
                raise RuntimeError(f"Workspace did not show {label}")
            if self.error:
                raise RuntimeError(f"Workspace disconnected waiting for {label}") from self.error
            return predicate(self.runs)

    def close(self):
        if self.connection.sock is not None:
            with contextlib.suppress(OSError):
                self.connection.sock.shutdown(socket.SHUT_RDWR)
        self.connection.close()
        self.thread.join(timeout=2)
        self.response.close()


def worker(runs, worker_id):
    return next((w for run in runs for w in run.get("workers", []) if w["id"] == worker_id), {})


def output_text(row):
    return "".join(row["outputChunks"]) if "outputChunks" in row else row.get("output", "")


def question(runs, worker_id, ticket):
    return next((q for run in runs for q in run.get("requests", []) if
                 q["worker_id"] == worker_id and q["question"].startswith(f"Confirm fixture {ticket}?")), {})


def rss(pid):
    raw = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True)
    return round(int(raw.strip()) / 1024, 2)


def elapsed(start):
    return round((time.monotonic() - start) * 1000, 2)


def metrics(samples):
    return {"median_ms": round(statistics.median(samples), 2), "max_ms": max(samples), "samples_ms": samples}


def phase(root, path, approval, feed, pid, load):
    shown = []
    command = []
    projection = []
    delivery = []
    memory = [rss(pid)]
    start_ticket = SAMPLES if load else 0
    before = feed.payload_bytes
    previous_subscription_bytes = 0
    for ticket in range(start_ticket, start_ticket + SAMPLES):
        started = time.monotonic()
        (root / f"request-{ticket}").touch()
        pending = feed.until(lambda runs: (
            q if (q := question(runs, approval, ticket)).get("status") == "pending" else {}
        ), f"pending fixture approval {ticket}")
        shown.append(elapsed(started))
        if load and ticket == start_ticket:
            # Retain the same pending request through a new workspace subscription.
            previous_subscription_bytes = feed.payload_bytes - before
            route = feed.route
            assert not feed.leaked
            feed.close()
            before = 0
            feed = Workspace(path, route)
            restored = feed.until(lambda runs: (q := question(runs, approval, ticket)).get("id") == pending["id"] and q["status"] == "pending",
                                  "the same approval after reconnect")
            assert restored
            reconnect = elapsed(feed.requested)
        started = time.monotonic()
        reply = api(path, "POST", "/v1/requests/" + pending["id"] + "/reply", {"answer": "allow_once"})
        assert reply["status"] == "answered" and reply["answer"] == "allow_once"
        command.append(elapsed(started))
        feed.until(lambda runs: question(runs, approval, ticket).get("status") == "answered", "answered approval")
        projection.append(elapsed(started))
        marker = f"ACK:approval-{ticket}:allow_once"
        feed.until(lambda runs: marker in output_text(worker(runs, approval)), "ACP reply acknowledgement")
        delivery.append(elapsed(started))
        memory.append(rss(pid))
    result = {
        "approval_visible": metrics(shown), "reply_http": metrics(command), "reply_visible": metrics(projection),
        "reply_observed_at_adapter": metrics(delivery), "service_rss_peak_sampled_mib": max(memory),
        "workspace_payload_bytes": previous_subscription_bytes + feed.payload_bytes - before,
    }
    if load:
        result["reconnect_with_pending_approval_ms"] = reconnect
    return result, feed


def create_panes(path, workspace):
    ids = {}
    for group in range(3):
        role = ("heavy", "approval", "quiet")[group]
        run = api(path, "POST", "/v1/runs", {"client": "fixture", "path": str(workspace), "task": role}, 201)
        if role in ("heavy", "approval"):
            ids[role] = run["coordinator_id"]
        for index in range(9):
            api(path, "POST", f"/v1/runs/{run['id']}/workers",
                {"client": "fixture", "name": f"Quiet {group}-{index}", "task": "quiet"}, 201)
    return ids


def attachment(root, path, heavy, feed):
    w = feed.until(lambda runs: worker(runs, heavy), "heavy worker")
    session = w["native_session"]["session_id"]
    source = next((root / "sessions").glob(f"*/fixture_{session}.jsonl"))
    with source.open("a") as file:
        file.write(json.dumps({"type": "message", "id": "fixture-image", "message": {
            "role": "toolResult", "toolCallId": "fixture-resource", "toolName": "attachment",
            "content": [{"type": "image", "mimeType": "image/png", "data": ATTACHMENT}],
        }}) + "\n")
    page = api(path, "GET", f"/v1/workers/{heavy}/history?limit=32")
    for record in page["observations"]:
        original = record.get("extension", {})
        if original.get("type") != "pi.message":
            continue
        row = json.loads(base64.b64decode(original["data"]))
        if row.get("id") == "fixture-image" and row["message"]["toolCallId"] == "fixture-resource":
            part, = row["message"]["content"]
            assert part == {"type": "image", "mimeType": "image/png", "data": ATTACHMENT}
            cursor = record["cursor"]
            break
    else:
        raise RuntimeError("The selected tool result was missing from provider history")
    if feed.leaked:
        raise RuntimeError("Live workspace received attachment bytes")
    return len(base64.b64decode(ATTACHMENT)), cursor


def wait_for_service(process, path):
    for _ in range(200):
        try:
            api(path, "GET", "/v1/health")
            return
        except OSError:
            if process.poll() is not None:
                raise RuntimeError("Fixture service exited during startup")
            time.sleep(0.05)
    raise TimeoutError("Fixture service did not become available")


def benchmark(binary, output, projection):
    stream_route = "/v1/ag-ui/events" + ("?projection=incremental" if projection == "incremental" else "")
    with tempfile.TemporaryDirectory(prefix="ac-30-", dir="/tmp") as name:
        root = Path(name).resolve()
        state, workspace = root / "data", root / "work"
        for directory in (state, workspace, root / "sessions"):
            directory.mkdir(mode=0o700)
        fixture = Path(__file__).with_name("fixture_acp.py").resolve()
        (state / "acp-profiles.json").write_text(json.dumps({"fixture": {
            "command": sys.executable, "args": [str(fixture), str(root)], "omit_commander_mcp": True,
            "history": {"format": "pi-jsonl-v3", "directory": str(root / "sessions")},
        }}))
        path = root / "s.sock"
        env = os.environ | {"TMUX_TMPDIR": str(root), "AGENT_COMMANDER_SOCKET": str(path),
                            "AGENT_COMMANDER_HOME": str(state)}
        for key in ("AGENT_COMMANDER_TOKEN", "AGENT_COMMANDER_HOSTED_CONFIG", "AGENT_COMMANDER_FOCUSED_PROOF"):
            env.pop(key, None)
        label = "ac-" + hashlib.sha256(str(state).encode()).hexdigest()[:12]
        feed = None
        with (root / "service.log").open("w") as log:
            process = subprocess.Popen([binary, "serve"], env=env, stdout=log, stderr=log)
            try:
                wait_for_service(process, path)
                ids = create_panes(path, workspace)
                feed = Workspace(path, stream_route)
                feed.until(lambda runs: sum("READY:" in output_text(w) and bool(w.get("native_session"))
                                           for r in runs for w in r.get("workers", [])) == PANES,
                            "30 live ACP workers", timeout=50)
                panes = subprocess.check_output(["tmux", "-L", label, "list-panes", "-a", "-F", "#{pane_id}"], env=env)
                assert len(panes.splitlines()) == PANES
                print(f"Confirmed {PANES} active tmux panes.", flush=True)
                baseline, feed = phase(root, path, ids["approval"], feed, process.pid, False)
                (root / "flood").touch()
                feed.until(lambda runs: re.search(r"FIXTURE_TICK:[1-9][0-9]{2,}\n", output_text(worker(runs, ids["heavy"]))),
                           "sustained heavy output")
                loaded, feed = phase(root, path, ids["approval"], feed, process.pid, True)
                bytes_read, cursor = attachment(root, path, ids["heavy"], feed)
                run_ids = [r["id"] for r in feed.runs]
                feed.close()
                feed = None
                for rid in run_ids:
                    api(path, "POST", "/v1/runs/" + rid + "/stop", {})
                for _ in range(100):
                    if all(api(path, "GET", "/v1/runs/" + rid)["status"] == "stopped" for rid in run_ids):
                        break
                    time.sleep(0.05)
                else:
                    raise RuntimeError("The fixture runs did not stop")
                # Reopening an SSE connection preserves the live console. A
                # fresh service must reconstruct it from the provider journal.
                process.terminate()
                process.wait(timeout=8)
                process = subprocess.Popen([binary, "serve"], env=env, stdout=log, stderr=log)
                wait_for_service(process, path)
                feed = Workspace(path, stream_route)
                def restored(runs):
                    for message in worker(runs, ids["heavy"]).get("messages", []):
                        meta = message.get("metadata", {})
                        for source in [meta.get("acp", {}), *meta.get("acpSources", [])]:
                            if source.get("source") == "provider" and source.get("cursor") == cursor:
                                return True
                    return False
                feed.until(restored, "cold restoration of the original tool result")
                result = {"projection": projection, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                          "host": {"system": platform.system(), "version": platform.mac_ver()[0],
                                   "arch": platform.machine()}, "panes": PANES, "idle": baseline,
                          "loaded": loaded, "attachment_bytes_retrieved": bytes_read,
                          "cold_snapshot_contains_attachment_bytes": feed.leaked}
                output.write_text(json.dumps(result, indent=2) + "\n")
                print(json.dumps(result, indent=2), flush=True)
            finally:
                if feed:
                    feed.close()
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=8)
                subprocess.run(["tmux", "-L", label, "kill-server"], env=env, capture_output=True)
    if result["cold_snapshot_contains_attachment_bytes"]:
        raise RuntimeError("Cold workspace history copied attachment bytes into its stream")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agentctl", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--projection", choices=["incremental", "legacy"], default="legacy")
    args = parser.parse_args()
    benchmark(args.agentctl.resolve(), args.output, args.projection)


if __name__ == "__main__":
    main()
