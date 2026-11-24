"""Exercise selected-session ACP params through a real stdio worker, private service and native replay."""
import argparse
import base64
import hashlib
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve()
spec = importlib.util.spec_from_file_location("pane", HERE.parents[1] / "30-pane" / "measure.py")
pane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pane)
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPoCFUFAAJrAQOclS6xAAAAAElFTkSuQmCC"
WIRE_ID = 9007199254740993


def wire_extras(label):
    return {"vendorWire": {"proof": label, "counter": WIRE_ID, "present": None}}


def examples(session):
    def record(label, **fields):
        return {"sessionId": session, "_meta": {"proof": label, "revision": 9007199254740993}, **fields}
    return [
        record("typed-text", update={"sessionUpdate": "agent_message_chunk", "messageId": "m1",
                                     "content": {"type": "text", "text": "Ready to inspect."}}),
        record("typed-tool", update={"sessionUpdate": "tool_call", "toolCallId": "read-1",
                                     "title": "Read receipt", "kind": "read", "status": "pending",
                                     "rawInput": {"path": "receipt.txt"}}),
        record("typed-result", update={"sessionUpdate": "tool_call_update", "toolCallId": "read-1",
                                       "status": "completed", "content": [
                                          {"type": "content", "content": {"type": "text", "text": "UMBER-731"}},
                                          {"type": "content", "content": {"type": "image", "mimeType": "image/png", "data": PNG}}]}),
        record("idle-notice", update={"sessionUpdate": "notice", "title": "Between turns", "message": "The fixture is idle."}),
        record("idle-null", update=None, extra=["", None, {"fraction": -1.5}]),
        record("idle-missing", extra={"empty": {}, "values": []},
               Update={"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "CASE_SIBLING_PRIVATE"}}),
    ]


def peer(root):
    session = "scoped-" + str(os.getpid())
    records = examples(session)
    prompt_id = None
    def write(message):
        print(json.dumps({"jsonrpc": "2.0", **message}, separators=(",", ":")), flush=True)
    def notify(params):
        write({"method": "session/update", "params": params})
    def between_turns():
        for _ in range(2000):
            if (root / "emit-idle").exists():
                notify(dict(records[3], sessionId="other-session", _meta={"proof": "FOREIGN_ONLY"}))
                for record in records[3:]:
                    notify(record)
                return
            time.sleep(.015)
    for line in sys.stdin:
        m = json.loads(line)
        if m.get("id") == WIRE_ID and (m.get("result") or {}).get("outcome", {}).get("optionId") == "once":
            write({"id": prompt_id, "result": {"stopReason": "end_turn", "vendorWire": "result-payload"},
                   **wire_extras("result")})
        elif m.get("method") == "initialize":
            # A transport diagnostic must never copy a malformed frame into worker output.
            print("INVALID_FRAME_PRIVATE_SENTINEL", flush=True)
            write({"id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
        elif m.get("method") == "session/new":
            write({"id": m["id"], "result": {"sessionId": session}})
        elif m.get("method") == "session/prompt":
            task = m["params"]["prompt"][0].get("text")
            if task == "Hold the coordinator.":
                continue
            if task.startswith("Wire proof "):
                case = task.removeprefix("Wire proof ")
                prompt_id = m["id"]
                (root / ("prompt-id-" + case)).write_text(json.dumps(prompt_id))
                if case == "disconnect":
                    return
                if case == "permission":
                    write({"method": "session/update", **wire_extras("notice"), "params": {
                        "sessionId": session, "update": {"sessionUpdate": "notice", "title": "Check receipt",
                                                         "message": "Inspect the selected notification."}}})
                    write({"method": "session/update", **wire_extras("FOREIGN_WIRE_ONLY"),
                           "params": {"sessionId": "foreign", "update": {"sessionUpdate": "notice", "title": "Foreign"}}})
                    write({"id": WIRE_ID, "method": "session/request_permission", **wire_extras("permission"),
                           "params": {"sessionId": session, "vendorWire": "permission-payload",
                                      "toolCall": {"toolCallId": "receipt", "title": "Allow receipt inspection?"},
                                      "options": [{"kind": "allow_once", "optionId": "once", "name": "Allow once"}]}})
                else:
                    write({"id": prompt_id, **wire_extras(case), "error": {
                        "code": int(case), "message": "Peer ended the turn", "vendorWire": "error-payload",
                        "data": {"counter": WIRE_ID, "present": None}}})
                continue
            for record in records[:3]:
                notify(record)
            write({"id": m["id"], "result": {"stopReason": "end_turn"}})
            threading.Thread(target=between_turns, daemon=True).start()


def check_wire(sock, rid, root, until, snapshot):
    captured = {}
    for case, expected in [("permission", ["notice", "permission", "result"]),
                           ("-32603", ["-32603"]), ("-32800", ["-32800"]), ("disconnect", [])]:
        worker = pane.api(sock, "POST", "/v1/runs/" + rid + "/workers",
                          {"client": "params", "name": case, "task": "Wire proof " + case}, 201)["id"]
        if case == "permission":
            question = until(lambda: next((q for r in snapshot()["snapshot"]["runs"] for q in r.get("requests", [])
                                           if q["worker_id"] == worker and q["status"] == "pending"), None),
                             bool, "the selected worker's permission request")
            assert question["id"] != str(WIRE_ID)
            pane.api(sock, "POST", "/v1/requests/" + question["id"] + "/reply", {"answer": "once"})
        until(lambda: pane.api(sock, "GET", "/v1/ag-ui/workers/" + worker),
              lambda w: w.get("status") in ("completed", "failed", "idle"), case + " to end")
        prompt_id = (root / ("prompt-id-" + case)).read_text()
        path = "/v1/workers/" + worker + "/history?source=live&limit=32"
        def wire_records(observations):
            return [r for r in observations if "wireProvenance" in r]
        def read():
            return pane.api(sock, "GET", path).get("observations", [])
        records = until(read, lambda rs: len(wire_records(rs)) >= len(expected), "wire receipts for " + case)
        actual = wire_records(records)
        gaps = [r["gap"]["reason"] for r in records if "gap" in r]
        if len(actual) != len(expected) or any(case != "disconnect" or g != "No live ACP source records are retained for this session" for g in gaps):
            raise ValueError("Unexpected wire records or source gap for " + case)
        for r, label in zip(actual, expected):
            wire = r["wireProvenance"]
            kind = {"notice": "NOTIFICATION", "permission": "REQUEST", "result": "RESULT"}.get(label, "ERROR")
            method = {"notice": "session/update", "permission": "session/request_permission"}.get(label, "session/prompt")
            assert wire["kind"].endswith("_" + kind) and wire["method"] == method and wire["protocolVersion"] == "2.0", wire
            assert json.loads(wire["additionalFieldsJson"]) == wire_extras(label)
            if label == "notice":
                assert "idJson" not in wire
            else:
                assert wire["idJson"] == (str(WIRE_ID) if label == "permission" else prompt_id)
            if kind in ("ERROR", "REQUEST", "RESULT"):
                original = r.get("sourceRecord") or r["extension"]
                payload = json.loads(base64.b64decode(original["data"]))
                assert payload["vendorWire"] == {"REQUEST": "permission", "RESULT": "result", "ERROR": "error"}[kind] + "-payload"
                if kind == "ERROR":
                    assert payload["code"] == int(label) and payload["data"] == {"counter": WIRE_ID, "present": None}
        assert "FOREIGN_WIRE_ONLY" not in json.dumps(records)
        if case == "disconnect":
            assert all((r.get("sourceRecord") or r.get("extension") or {}).get("type") != "acp.prompt_error" for r in records)
        typed = pane.api(sock, "GET", path + "&view=acp")["records"]
        by_cursor = {r["cursor"]: r for r in typed if "cursor" in r}
        for r in actual:
            view = by_cursor[r["cursor"]]
            assert (view.get("wireProvenance") or view["observation"]["wireProvenance"]) == r["wireProvenance"]
        captured[case] = {"worker": worker, "observations": records, "cursors": [r["cursor"] for r in actual]}
    return captured


def run(binary, output, require_wire):
    def until(read, ready, description):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            value = read()
            if ready(value):
                return value
            time.sleep(.08)
        raise RuntimeError("Timed out waiting for " + description)
    with tempfile.TemporaryDirectory(prefix="ac-params-", dir="/tmp") as folder:
        root = Path(folder).resolve()
        state, sock = root / "state", root / "s.sock"
        state.mkdir(mode=0o700)
        (state / "acp-profiles.json").write_text(json.dumps({"params": {
            "command": sys.executable, "args": [str(HERE), "--peer", str(root)], "omit_commander_mcp": True}}))
        env = {k: v for k, v in os.environ.items() if not k.startswith("AGENT_COMMANDER_") and k not in ("TMUX", "TMUX_PANE")}
        env.update(AGENT_COMMANDER_HOME=str(state), AGENT_COMMANDER_SOCKET=str(sock), TMUX_TMPDIR=str(root))
        with (root / "service.log").open("w") as log:
            proc = subprocess.Popen([str(binary), "serve"], env=env, stdout=log, stderr=log)
            rid = None
            try:
                until(sock.exists, bool, "the private socket")
                rid = pane.api(sock, "POST", "/v1/runs", {"client": "params", "path": str(root),
                               "task": "Hold the coordinator.", "worker_limit": 6}, 201)["id"]
                worker = pane.api(sock, "POST", "/v1/runs/" + rid + "/workers", {"client": "params",
                                  "name": "Params", "task": "Return the receipt and swatch."}, 201)["id"]
                worker_path = "/v1/workers/" + worker
                until(lambda: pane.api(sock, "GET", "/v1/ag-ui/workers/" + worker),
                      lambda w: w.get("status") in ("completed", "idle"), "the worker to finish its turn")
                (root / "emit-idle").touch()
                def source():
                    return pane.api(sock, "GET", worker_path + "/history?source=live&limit=32").get("observations", [])
                def enriched(records):
                    return [(r, json.loads(base64.b64decode(e["data"]))) for r in records
                            for e in [r.get("sourceRecord") or r.get("extension", {})]
                            if e.get("type") == "acp.session_update_params"]
                records = until(source, lambda items: len(enriched(items)) >= 6, "six enriched originals, including three between turns")
                actual = enriched(records)
                expected = examples(actual[0][0]["session"]["sessionId"])
                if [params for _, params in actual] != expected or len({r["cursor"] for r, _ in actual}) != 6:
                    raise ValueError("The original selected records, number representations or cursor order changed")
                active_turn = "initial-" + worker
                if (any("gap" in r for r in records) or any(r.get("turnId") != active_turn for r, _ in actual[:3])
                        or any(r.get("turnId") for r, _ in actual[3:])):
                    gaps = [r["gap"] for r in records if "gap" in r]
                    turns = [(v["_meta"]["proof"], r.get("turnId")) for r, v in actual]
                    raise ValueError(f"Unexpected loss or turn association: {gaps}, {turns}")
                def snapshot():
                    with closing(pane.LocalHTTP(sock)) as conn:
                        conn.request("GET", "/v1/ag-ui/events?projection=incremental")
                        with conn.getresponse() as response:
                            return next(json.loads(line[6:]) for line in response if line.startswith(b"data: "))
                def all_linked(event):
                    row = next(w for r in event["snapshot"]["runs"] for w in r["workers"] if w["id"] == worker)
                    links = set()
                    for m in row.get("messages", []):
                        meta = m.get("metadata", {})
                        for a in [meta.get("acp", {}), *meta.get("acpSources", [])]:
                            if a.get("source") == "live":
                                links.add(a.get("cursor"))
                    return all(r["cursor"] in links for r, _ in actual)
                event = until(snapshot, all_linked, "all six linked source records in the workspace")
                wire = check_wire(sock, rid, root, until, snapshot) if require_wire else {}
                if require_wire:
                    def wire_linked(event):
                        for item in wire.values():
                            row = pane.worker(event["snapshot"]["runs"], item["worker"])
                            linked = {a.get("cursor") for m in row.get("messages", [])
                                      for meta in [m.get("metadata", {})]
                                      for a in [meta.get("acp", {}), *meta.get("acpSources", [])] if a.get("source") == "live"}
                            if not set(item["cursors"]).issubset(linked):
                                return False
                        return True
                    event = until(snapshot, wire_linked, "every wire receipt to be linked on its worker")
                workspace = json.dumps(event)
                for marker in ("FOREIGN_ONLY", "FOREIGN_WIRE_ONLY", "error-payload", "result-payload", "permission-payload",
                               "INVALID_FRAME_PRIVATE_SENTINEL", "CASE_SIBLING_PRIVATE", "9007199254740993", PNG):
                    if marker in workspace:
                        raise ValueError("Private marker entered the workspace")
                with os.fdopen(os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as f:
                    json.dump({"event": event, "worker": worker, "live": {"observations": records},
                               "expected": expected, "wire": wire}, f)
                print("Six original ACP records matched and all six cursors resolved, including three between turns.")
                if require_wire:
                    print("Five matched wire records resolved on their selected workers. Local EOF had no peer receipt.")
            finally:
                try:
                    if rid:
                        subprocess.run([str(binary), "stop", rid], env=env, stdout=subprocess.DEVNULL, timeout=12)
                finally:
                    if proc.poll() is None:
                        proc.terminate()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    # Stop the service's final tmux checks before removing
                    # the socket directory belonging to this exercise.
                    label = "ac-" + hashlib.sha256(str(state).encode()).hexdigest()[:12]
                    subprocess.run(["tmux", "-L", label, "kill-server"], env=env, capture_output=True, timeout=10)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--peer":
        peer(Path(sys.argv[2]))
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--agentctl", required=True, type=Path)
        parser.add_argument("--output", required=True, type=Path)
        parser.add_argument("--require-wire", action="store_true", help="Exercise wire receipts and local EOF with four additional workers")
        args = parser.parse_args()
        run(args.agentctl.resolve(), args.output, args.require_wire)
