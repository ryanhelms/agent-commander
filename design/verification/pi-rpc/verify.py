#!/usr/bin/env python3
"""Exercise a pinned standalone Pi translator through ACP and Commander."""
import argparse
import base64
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse

MARKER = "COMMANDER_PI_READ_FIXTURE_63"
PROMPT = ("Read sample.txt and report its marker. Preserve $value and this newline.\n"
          "Read missing-swatch.txt and swatch.png, then finish.")
READS = {"call_fixture_read": "sample.txt", "call_missing_read": "missing-swatch.txt",
         "call_swatch_read": "swatch.png"}
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGMQLC+HIwbiOACYQw/x52aSlAAAAABJRU5ErkJggg=="
INTERRUPT_PROMPT = "Stream a fixture marker and wait for the conformance interruption."
INTERRUPT_MARKER = "COMMANDER_PI_INTERRUPT_READY"
EXTENSION = """
export default function (pi) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "read" && event.input.path === "sample.txt" &&
        !(await ctx.ui.confirm("Read the synthetic fixture?", "Approve the single read."))) {
      return { block: true, reason: "The fixture read was declined." };
    }
  });
}
"""

def message_text(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if part.get("type") == "text")
    return ""


class FixtureModel(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        last_user = next((item for item in reversed(messages) if item["role"] == "user"), {})
        last_prompt = message_text(last_user)
        tool_messages = [item for item in messages if item["role"] == "tool"]
        if last_prompt == "Fingerprint the attached conformance image.":
            parts = last_user.get("content")
            media = [part.get("image_url", {}).get("url", "") for part in parts
                     if part.get("type") == "image_url"] if isinstance(parts, list) else []
            prefix = "data:image/png;base64,"
            if len(media) != 1 or not media[0].startswith(prefix):
                self.send_error(400, "Expected one inline PNG in the current user message")
                return
            image = base64.b64decode(media[0][len(prefix):], validate=True)
            delta = {"content": "sha256:" + hashlib.sha256(image).hexdigest()}
            stop = "stop"
        elif last_prompt == INTERRUPT_PROMPT:
            if self.server.require_fresh_resume:
                prior = [message_text(item) for item in messages if item["role"] == "user"]
                if (PROMPT not in prior or "Fingerprint the attached conformance image." in prior or
                        {item.get("tool_call_id") for item in tool_messages} != set(READS) or
                        not any(MARKER in message_text(item) for item in tool_messages)):
                    self.send_error(400, "The resumed turn did not receive the second original conversation")
                    return
            delta = {"content": INTERRUPT_MARKER}
            stop = "stop"
        elif len(tool_messages) == len(READS):
            if not any(MARKER in message_text(item) for item in tool_messages):
                self.send_error(400, "The Pi read did not return the fixture marker")
                return
            delta = {"content": "Pi read " + MARKER}
            stop = "stop"
        else:
            if not any(PROMPT in message_text(item) for item in messages if item["role"] == "user"):
                self.send_error(400, "The literal fixture prompt was not preserved")
                return
            call = next(key for key in READS if not any(item.get("tool_call_id") == key for item in tool_messages))
            delta = {"tool_calls": [{"index": 0, "id": call, "type": "function",
                      "function": {"name": "read", "arguments": json.dumps({"path": READS[call]})}}]}
            stop = "tool_calls"

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def emit(content, reason=None):
            chunk = {"id": "chatcmpl-fixture", "object": "chat.completion.chunk",
                     "created": 1, "model": "fixture-model",
                     "choices": [{"index": 0, "delta": content, "finish_reason": reason}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())

        emit({"role": "assistant"})
        emit(delta)
        if last_prompt == INTERRUPT_PROMPT:
            self.wfile.flush()
            try:
                for _ in range(20):
                    time.sleep(0.2)
                    self.wfile.write(b": fixture waiting for cancellation\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
        emit({}, stop)
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *_):
        pass


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=8)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


def request(path, method, route, payload=None, expected=200):
    connection = UnixHTTP(path)
    try:
        body = None if payload is None else json.dumps(payload)
        connection.request(method, route, body, {"Content-Type": "application/json"})
        reply = connection.getresponse()
        value = json.loads(reply.read())
        if reply.status != expected:
            raise AssertionError((method, route, reply.status, value))
        return value
    finally:
        connection.close()


def configure_pi(root, model):
    home = root / "pi"
    extensions = home / "extensions"
    extensions.mkdir(parents=True, mode=0o700)
    (extensions / "approve-fixture.ts").write_text(EXTENSION)
    (home / "settings.json").write_text(json.dumps(
        {"defaultProvider": "fixture", "defaultModel": "fixture-model", "images": {"autoResize": False}}
    ))
    (home / "models.json").write_text(json.dumps({
        "providers": {"fixture": {"baseUrl": f"http://127.0.0.1:{model.server_port}/v1",
                                   "api": "openai-completions", "apiKey": "test-only",
                                   "models": [{"id": "fixture-model", "input": ["text", "image"]}]}}
    }))
    return home


def verify_wire(root, workspace, node, translator, env):
    trace = root / "wire.json"
    subprocess.run([node, Path(__file__).with_name("stock-client.mjs"), translator, workspace, trace, PROMPT],
                   env=env, check=True, timeout=70)
    raw = json.loads(trace.read_text())
    live = verify_tool_updates(raw["live"])
    assert verify_tool_updates(raw["replay"]) == live, "ACP replay changed the received tool blocks"
    return live


def verify_tool_updates(updates):
    results = {}
    for call, path in READS.items():
        updates_for_call = [update for update in updates if update.get("toolCallId") == call]
        assert any(update.get("rawInput", {}).get("path") == path for update in updates_for_call), (call, path)
        final, = [update for update in updates_for_call if update.get("status") in ("completed", "failed")]
        blocks = [entry["content"] for entry in final["content"]]
        text = " ".join(block["text"] for block in blocks if block["type"] == "text")
        if call == "call_missing_read":
            assert final["status"] == "failed" and path in text and "ENOENT" in text, (call, text)
        elif call == "call_swatch_read":
            assert final["status"] == "completed" and [block["type"] for block in blocks] == ["text", "image"]
            assert blocks[1]["mimeType"] == "image/png" and blocks[1]["data"] == PNG
        else:
            assert final["status"] == "completed" and MARKER in text
        results[call] = blocks
    return results


def journal_hashes(directory):
    return {path.relative_to(directory): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in directory.rglob("*.jsonl")}


def verify_adapter(root, workspace, node, translator, command, env, verify_resume=False):
    fixture = root / "adapter-conformance.json"
    fixture.write_text(json.dumps({
        "Prompt": PROMPT,
        "PermissionPrompt": "Reading: sample.txt",
        "ChoiceLabel": "Allow Once",
        "ToolResultMarker": MARKER,
        "CompletionMarker": "Pi read " + MARKER,
        "InterruptPrompt": INTERRUPT_PROMPT,
        "InterruptReady": INTERRUPT_MARKER,
    }))
    args = [node, translator / "dist/index.js"]
    trace = root / "resume-trace.jsonl"
    if verify_resume:
        args = [node, Path(__file__).with_name("trace-resume.mjs"), trace, translator / "dist/index.js"]
    subprocess.run([command, "-cwd", workspace, "-fixture", fixture, "--", *args], env=env, check=True, timeout=75)
    if verify_resume:
        rows = [json.loads(line) for line in trace.read_text().splitlines()]
        created = [row for row in rows if row["method"] == "created"]
        resumed, = [row for row in rows if row["method"] == "session/resume"]
        assert len(created) == 2 and created[0]["session"] != created[1]["session"]
        original = created[1]
        assert resumed["session"] == original["session"] and resumed["pid"] != original["pid"]
        for peer in created:
            closed = next(row for row in rows if row["method"] == "exited" and row["pid"] == peer["pid"])
            assert rows.index(closed) < rows.index(resumed)
        methods = [row["method"] for row in rows if row["pid"] == resumed["pid"] and row.get("session") == resumed["session"]]
        assert methods == ["session/resume", "session/prompt", "session/cancel"], methods
        print("Both original Pi peers exited. A new process resumed the second session ID, "
              "received the follow-up and canceled its addressed turn.", flush=True)


def verify_commander(root, workspace, node, translator, agentctl, env, wire_results, native_capture):
    state = root / "state"
    state.mkdir(mode=0o700)
    profiles = {"pi": {"command": node, "args": [str(translator / "dist/index.js")],
                       "omit_commander_mcp": True,
                       "history": {"format": "pi-jsonl-v3",
                                   "directory": str(Path(env["PI_CODING_AGENT_DIR"]) / "sessions")}}}
    (state / "acp-profiles.json").write_text(json.dumps(profiles))
    path = root / "s.sock"
    env = env | {"AGENT_COMMANDER_HOME": str(state), "AGENT_COMMANDER_SOCKET": str(path)}
    with (root / "commander.log").open("w") as log:
        process = subprocess.Popen([agentctl, "serve"], env=env, stdout=log, stderr=log)
        run = None
        try:
            wait_for_commander(process, path)
            result = subprocess.run([agentctl, "run", "--client", "pi", workspace, PROMPT],
                                    env=env, capture_output=True, text=True, timeout=12)
            if result.returncode:
                raise RuntimeError(f"Commander refused the Pi profile: {result.stderr}")
            run = json.loads(result.stdout)
            detail = "/v1/runs/" + run["id"]
            replied = None
            for _ in range(150):
                run = request(path, "GET", detail)
                worker = run["workers"][0]
                if worker["state"] == "failed":
                    raise AssertionError(worker["error"])
                for question in run["requests"]:
                    if question["status"] != "pending":
                        continue
                    choices = [c for c in question["choices"] if c["id"] == "allow_once"]
                    if replied is not None or len(choices) != 1:
                        raise AssertionError("Unexpected permission request")
                    replied = question["id"]
                    request(path, "POST", "/v1/requests/" + replied + "/reply",
                            {"answer": "allow_once"})
                if worker["state"] == "completed":
                    break
                time.sleep(0.15)
            if worker["state"] != "completed" or not replied or not worker.get("native_session"):
                raise AssertionError("No completed Pi worker with a settled approval and native identity")
            if not any(item.get("kind") == "tool_result" and MARKER in item.get("text", "")
                       for item in worker["console"]):
                raise AssertionError("Commander console did not contain the Pi read result")
            live_refs = verify_projection(path, run["id"], "live")
            print("Commander verified Pi native identity, addressed approval and AG-UI tool result.", flush=True)
            native = worker["native_session"]
            live = read_pi_history(path, worker["id"], native["session_id"], source="live")
            updates = {item["cursor"]: json.loads(base64.b64decode(item["extension"]["data"])) for item in live
                       if item.get("extension", {}).get("type") == "acp.session_update"}
            assert verify_tool_updates(updates.values()) == wire_results, "Commander live source diverged from stock ACP"
            for call, cursor in live_refs.items():
                assert updates[cursor]["toolCallId"] == call and updates[cursor]["status"] in ("failed", "completed")
            process.terminate()
            process.wait(timeout=5)
            journals = Path(env["PI_CODING_AGENT_DIR"]) / "sessions"
            before = journal_hashes(journals)
            assert len(before) >= 2
            process = subprocess.Popen([agentctl, "serve"], env=env, stdout=log, stderr=log)
            wait_for_commander(process, path)
            history = read_pi_history(path, worker["id"], native["session_id"])
            if not any(MARKER in item.get("tool", {}).get("summary", "") for item in history):
                raise AssertionError("Cold Pi history did not retain the tool result")
            if not any(PROMPT == item.get("text", {}).get("text") for item in history):
                raise AssertionError("Cold Pi history changed the literal native prompt")
            cold_refs = verify_projection(path, run["id"], "provider")
            raw_results = {item["cursor"]: json.loads(base64.b64decode(item["extension"]["data"])).get("message")
                           for item in history if item.get("extension", {}).get("type") == "pi.message"}
            for call, blocks in wire_results.items():
                result = raw_results[cold_refs[call]]
                assert result["role"] == "toolResult" and result["toolCallId"] == call
                assert result["content"] == blocks, (call, "cold Pi history diverged from stock ACP")
                assert result["isError"] == (call == "call_missing_read")
            if any("input" in item for item in history):
                raise AssertionError("Passive history exposed an actionable approval")
            restored = request(path, "GET", detail)
            if restored["workers"][0]["native_session"] != native:
                raise AssertionError("The history read changed the worker's native binding")
            if not any(q["id"] == replied and q["status"] == "answered" for q in restored["requests"]):
                raise AssertionError("Cold Pi history changed the recorded approval")
            assert journal_hashes(journals) == before, "Passive recovery modified the native Pi journals"
            if native_capture:
                connection = UnixHTTP(path)
                try:
                    connection.request("GET", "/v1/ag-ui/events?projection=incremental")
                    stream = connection.getresponse()
                    snapshot = next(json.loads(line[6:]) for line in stream if line.startswith(b"data: "))
                    assert snapshot["type"] == "STATE_SNAPSHOT"
                    with os.fdopen(os.open(native_capture, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
                        json.dump({"event": snapshot, "provider": {"observations": history}, "png": PNG}, output)
                finally:
                    connection.close()
            print("Stock ACP, live AG-UI and cold Pi history matched all three tool results, including the PNG. "
                  "Restart and history reads preserved the native journals.", flush=True)
        finally:
            try:
                if run and process.poll() is None:
                    request(path, "POST", "/v1/runs/" + run["id"] + "/stop", {})
            finally:
                label = "ac-" + hashlib.sha256(str(state).encode()).hexdigest()[:12]
                subprocess.run(["tmux", "-L", label, "kill-server"], env=env, capture_output=True)
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)


def wait_for_commander(process, path):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("Commander exited during startup")
        try:
            request(path, "GET", "/v1/health")
            return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("Commander startup timed out")


def read_pi_history(path, worker, session, source=""):
    cursor = ""
    observations = []
    for _ in range(40):
        query = urllib.parse.urlencode({"limit": 2, "cursor": cursor, "source": source})
        page = request(path, "GET", f"/v1/workers/{worker}/history?{query}")
        items = page["observations"]
        if len(items) > 2 or any(item["session"]["sessionId"] != session for item in items):
            raise AssertionError("Pi history page escaped the requested session or size")
        observations.extend(items)
        cursor = page.get("nextCursor", "")
        if not cursor:
            return observations
    raise AssertionError("Pi history did not finish in the expected number of pages")


def verify_projection(path, run_id, source):
    connection = UnixHTTP(path)
    try:
        connection.request("GET", "/v1/ag-ui/events")
        stream = connection.getresponse()
        opened = False
        for line in stream:
            if not line.startswith(b"data: "):
                continue
            event = json.loads(line[6:])
            if not opened and event["type"] != "STATE_SNAPSHOT":
                raise AssertionError("AG-UI subscription did not open with a snapshot")
            opened = True
            if event["type"] == "STATE_SNAPSHOT":
                runs = event["snapshot"]["runs"]
            else:
                # The compatibility feed replaces a run after its passive history loads.
                runs = []
                for patch in event.get("delta", []):
                    if patch["path"] == "/runs":
                        runs.extend(patch["value"])
                    elif patch["path"].startswith("/runs/"):
                        runs.append(patch["value"])
            run = next((item for item in runs if item["id"] == run_id), None)
            if not run or not run["workers"][0].get("messages"):
                continue
            worker, = run["workers"]
            references = {}
            for call in READS:
                call_id = worker["id"] + ":" + call
                result, = (item for item in worker["messages"] if item.get("toolCallId") == call_id)
                ref = result["metadata"]["acp"]
                assert result["role"] == "tool" and ref["source"] == source
                references[call] = ref["cursor"]
                assert bool(result.get("error")) == (call == "call_missing_read")
                if call == "call_fixture_read":
                    assert MARKER in result["content"]
                elif call == "call_missing_read":
                    assert "ENOENT" in result["content"] and READS[call] in result["content"]
            return references
        raise AssertionError("Read result was absent from the AG-UI projection")
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--translator", type=Path, required=True, help="built upstream translator checkout")
    parser.add_argument("--agentctl", type=Path, required=True, help="built Commander CLI")
    parser.add_argument("--conformance", type=Path, help="optional agent-acp adapter-conformance executable")
    parser.add_argument("--native-capture", type=Path, help="write a new private Swift verification fixture")
    parser.add_argument("--verify-resume", action="store_true", help="require a fresh ACP peer for an advertised resume")
    args = parser.parse_args()
    if args.verify_resume and not args.conformance:
        parser.error("--verify-resume requires --conformance")
    node = shutil.which("node")
    if not node or not shutil.which("tmux"):
        parser.error("node and tmux are required")
    with tempfile.TemporaryDirectory(prefix="ac-pi-", dir="/tmp") as folder:
        root = Path(folder).resolve()
        workspace = root / "workspace"
        workspace.mkdir()
        (workspace / "sample.txt").write_text(MARKER + "\n")
        (workspace / "swatch.png").write_bytes(base64.b64decode(PNG))
        model = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureModel)
        model.require_fresh_resume = args.verify_resume
        thread = threading.Thread(target=model.serve_forever, daemon=True)
        thread.start()
        env = os.environ | {"PI_CODING_AGENT_DIR": str(configure_pi(root, model)), "PI_ACP_EXTENSIONS": "1",
                            "TMUX_TMPDIR": str(root)}
        for key in ("AGENT_COMMANDER_TOKEN", "AGENT_COMMANDER_HOSTED_CONFIG", "AGENT_COMMANDER_FOCUSED_PROOF"):
            env.pop(key, None)
        try:
            wire_results = verify_wire(root, workspace, node, args.translator.resolve(), env)
            if args.conformance:
                verify_adapter(root, workspace, node, args.translator.resolve(), args.conformance.resolve(), env, args.verify_resume)
            verify_commander(root, workspace, node, args.translator.resolve(), args.agentctl.resolve(), env,
                             wire_results, args.native_capture)
        finally:
            model.shutdown()
            model.server_close()


if __name__ == "__main__":
    main()
