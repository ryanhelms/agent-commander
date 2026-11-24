"""Synthetic ACP adapter for measure.py. Communicates solely through private fixture paths and stdio."""
import json
from pathlib import Path
import sys
import time
import uuid


def send(**row):
    line = json.dumps({"jsonrpc": "2.0", **row}, separators=(",", ":")) + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()
    return len(line.encode())


def run(root):
    config = json.loads((root / "config.json").read_text())
    session = str(uuid.uuid4())

    def update(body, private=None):
        params = {"sessionId": session, "update": body}
        if private is not None:
            target = params if config.get("outer_source") else body
            target["_meta"] = {"privateSequence": private}
            if body["sessionUpdate"] == "agent_message_chunk":
                body["messageId"] = "capacity-message"
        return send(method="session/update", params=params)

    def text(value, private=None):
        return update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": value}}, private)

    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if method == "initialize":
            send(id=request["id"], result={"protocolVersion": 1})
        elif method == "session/new":
            send(id=request["id"], result={"sessionId": session})
        elif method == "session/prompt":
            if config["tool_every"]:
                update({"sessionUpdate": "tool_call", "toolCallId": "fixture-tool",
                        "title": "Fixture tool", "kind": "read", "status": "in_progress"})
            text("CAPACITY_READY\n")
            while not (root / "start").exists():
                time.sleep(0.005)
            started = time.monotonic()
            wire_bytes = 0
            count = config["count"]
            burst = config.get("burst", 1)
            for sequence in range(1, count + 1):
                if burst == 1:
                    deadline = started + (sequence - 1) / config["rate"]
                    time.sleep(max(0, deadline - time.monotonic()))
                elif (sequence - 1) % burst == 0:
                    # Release each group at the deadline of its last scheduled input.
                    due = min(count, sequence + burst - 1)
                    deadline = started + (due - 1) / config["rate"]
                    time.sleep(max(0, deadline - time.monotonic()))
                marker = f"CPEV{sequence:09d}Z"
                payload = marker.ljust(config["size"] - 1, "x") + "\n"
                private = f"CPSRC_{sequence:09d}" if config.get("rich_source") else None
                if config["tool_every"] and sequence % config["tool_every"] == 0:
                    wire_bytes += update({"sessionUpdate": "tool_call_update", "toolCallId": "fixture-tool",
                                          "status": "in_progress", "content": [
                                              {"type": "content", "content": {"type": "text", "text": payload}}]}, private)
                else:
                    wire_bytes += text(payload, private)
            finished = time.monotonic()
            temp = root / "sent.tmp"
            temp.write_text(json.dumps({"count": count, "acp_stdio_bytes": wire_bytes,
                                        "first_scheduled_monotonic": started, "last_flush_monotonic": finished}))
            temp.rename(root / "sent.json")
            # Allow the runner to flush the last measured batch before emitting a delivery fence.
            time.sleep(0.20)
            if config.get("outer_source"):
                # The measured text and tools are typed observations. A passive
                # notice checks the other SDK carrier at the delivery boundary.
                text("CAPACITY_FENCE\n")
                update({"sessionUpdate": "notice", "title": "Private source fence",
                        "message": "End of measured originals"}, "CPSRC_FENCE")
            else:
                text("CAPACITY_FENCE\n", "CPSRC_FENCE" if config.get("rich_source") else None)
        elif method == "session/cancel":
            return


if __name__ == "__main__":
    run(Path(sys.argv[1]))
