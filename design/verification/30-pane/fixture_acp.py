"""Disposable ACP process for the 30-pane performance fixture."""
import datetime
import json
import os
from pathlib import Path
import sys
import threading
import time
import uuid

ROOT = Path(sys.argv[1])
SESSION = str(uuid.uuid4())
lock = threading.Lock()
stop = threading.Event()


def send(**row):
    with lock:
        print(json.dumps({"jsonrpc": "2.0", **row}), flush=True)


def update(text):
    send(method="session/update", params={"sessionId": SESSION, "update": {
        "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text},
    }})


def history_header(cwd):
    project = "--" + cwd.lstrip("/").replace("/", "-").replace(":", "-") + "--"
    directory = ROOT / "sessions" / project
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / ("fixture_" + SESSION + ".jsonl")
    path.write_text(json.dumps({"type": "session", "version": 3, "id": SESSION, "cwd": cwd,
                                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat()}) + "\n")


def flood():
    tick = 0
    while not stop.wait(0.05):
        if (ROOT / "flood").exists():
            tick += 1
            update(f"FIXTURE_TICK:{tick}\n" + "x" * (16 * 1024 - 64) + "\n")


def approve():
    ticket = 0
    while not stop.wait(0.02):
        if (ROOT / f"request-{ticket}").exists():
            name = f"approval-{ticket}"
            send(id=name, method="session/request_permission", params={
                "sessionId": SESSION,
                "toolCall": {"toolCallId": name, "title": f"Confirm fixture {ticket}?"},
                "options": [{"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"}],
            })
            ticket += 1


def main():
    turn = None
    for line in sys.stdin:
        received_ns = time.monotonic_ns()
        frame = json.loads(line)
        method = frame.get("method")
        if method == "initialize":
            send(id=frame["id"], result={"protocolVersion": 1})
        elif method == "session/new":
            history_header(os.path.realpath(frame["params"]["cwd"]))
            send(id=frame["id"], result={"sessionId": SESSION})
        elif method == "session/prompt":
            turn = frame["id"]
            role = frame["params"]["prompt"][0]["text"]
            if role.startswith("textprobe "):
                ticket = int(role.split()[1])
                update(f"FIRST:{ticket}:{time.monotonic_ns()}:chunk")
                time.sleep(2)
                (ROOT / f"text-finished-{ticket}").write_text(str(time.monotonic_ns()))
                send(id=turn, result={"stopReason": "end_turn"})
                turn = None
            else:
                update("READY:" + role + "\n")
                if role == "textprobe-ready":
                    send(id=turn, result={"stopReason": "end_turn"})
                    turn = None
                elif role in ("heavy", "approval"):
                    threading.Thread(target=flood if role == "heavy" else approve, daemon=True).start()
        elif method == "session/cancel" and turn is not None:
            stop.set()
            send(id=turn, result={"stopReason": "cancelled"})
            turn = None
        elif not method and str(frame.get("id", "")).startswith("approval-"):
            outcome = frame.get("result", {}).get("outcome", {})
            update(f"ACK:{frame['id']}:{outcome.get('optionId', '(none)')}:{received_ns}\n")


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
    finally:
        stop.set()
