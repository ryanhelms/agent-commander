"""Start a disposable deterministic worker and the independently installed example."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve()
QUESTION = "Which code confirms ASK-TOOL-RECEIPT?"
ANSWER = "LAPIS-742"


def peer():
    session = f"fixture-{os.getpid()}"
    prompt_id = None

    def send(**fields):
        print(json.dumps({"jsonrpc": "2.0", **fields}), flush=True)

    def update(**fields):
        send(method="session/update", params={"sessionId": session, "update": fields})

    def finish(text):
        update(sessionUpdate="agent_message_chunk", content={"type": "text", "text": text})
        send(id=prompt_id, result={"stopReason": "end_turn"})

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            send(id=message["id"], result={"protocolVersion": 1, "agentCapabilities": {}})
        elif method == "session/new":
            send(id=message["id"], result={"sessionId": session})
        elif method == "session/prompt":
            prompt_id = message["id"]
            text = message["params"]["prompt"][0]["text"]
            if text == "Hold the coordinator.":
                continue
            if text == "Say READY.":
                finish("READY")
                continue
            update(sessionUpdate="tool_call", toolCallId="ask", title="commander_ask",
                   kind="other", status="pending", rawInput={"question": QUESTION})
            update(sessionUpdate="tool_call_update", toolCallId="ask", status="completed",
                   content=[{"type": "content", "content": {"type": "text", "text": QUESTION}}],
                   rawOutput={"marker": "ASK-TOOL-RECEIPT", "question": QUESTION})
            send(id="peer-request", method="session/request_permission", params={"sessionId": session,
                 "toolCall": {"toolCallId": "ask", "title": QUESTION},
                 "options": [{"kind": "allow_once", "optionId": ANSWER, "name": ANSWER}]})
        elif message.get("id") == "peer-request":
            finish(message["result"]["outcome"]["optionId"])


def launch(binary, app):
    spec = importlib.util.spec_from_file_location("pane", HERE.parents[1] / "30-pane/measure.py")
    pane = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pane)
    with tempfile.TemporaryDirectory(prefix="ac-example-", dir="/tmp") as tmp:
        root = Path(tmp).resolve()
        state = root / "state"
        state.mkdir(mode=0o700)
        sock = root / "api.sock"
        profile = {"command": sys.executable, "args": [str(HERE), "--peer"], "omit_commander_mcp": True}
        (state / "acp-profiles.json").write_text(json.dumps({"example": profile}))
        env = {k: v for k, v in os.environ.items() if not k.startswith("AGENT_COMMANDER_") and k not in ("TMUX", "TMUX_PANE")}
        env.update(AGENT_COMMANDER_HOME=str(state), AGENT_COMMANDER_SOCKET=str(sock), TMUX_TMPDIR=str(root))
        with (root / "service.log").open("w") as log:
            service = subprocess.Popen([str(binary), "serve"], stdout=log, stderr=log, env=env)
            run_id = None
            try:
                deadline = time.monotonic() + 30
                while not sock.exists():
                    if service.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("The private Commander service did not start.")
                    time.sleep(0.05)
                run = pane.api(sock, "POST", "/v1/runs", {"path": str(root), "client": "example", "task": "Hold the coordinator."}, 201)
                run_id = run["id"]
                worker = pane.api(sock, "POST", f"/v1/runs/{run_id}/workers", {
                    "client": "example", "name": "CopilotKit example", "task": "Say READY."}, 201)["id"]
                while pane.api(sock, "GET", f"/v1/ag-ui/workers/{worker}")["status"] not in ("idle", "completed"):
                    if time.monotonic() >= deadline:
                        raise RuntimeError("The fixture worker did not finish its first assignment.")
                    time.sleep(0.1)
                pane.api(sock, "POST", f"/v1/workers/{worker}/control", {"held": True, "generation": 1})
                subprocess.run(["node", "run.mjs", "--worker", worker], cwd=app, env=env, check=True)
            finally:
                if run_id:
                    subprocess.run([str(binary), "stop", run_id], env=env, stdout=subprocess.DEVNULL)
                service.terminate()
                service.wait(timeout=10)
                label = "ac-" + hashlib.sha256(str(state).encode()).hexdigest()[:12]
                subprocess.run(["tmux", "-L", label, "kill-server"], env=env, capture_output=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--peer"]:
        peer()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--agentctl", required=True, type=Path)
        parser.add_argument("--app", required=True, type=Path)
        args = parser.parse_args()
        try:
            launch(args.agentctl.resolve(), args.app.resolve())
        except KeyboardInterrupt:
            pass
