"""Run two isolated managed workers and observe their real tmux screens through agentctl."""

from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time


def wait(check, label, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if result := check():
            return result
        time.sleep(0.025)
    raise TimeoutError(label)


class Client:
    def __init__(self, args, env, rows, cols):
        self.fd, slave = pty.openpty()
        self.output = bytearray()
        try:
            self.resize(rows, cols)
            self.proc = subprocess.Popen(
                args, stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
                preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        finally:
            os.close(slave)

    def resize(self, rows, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def expect(self, marker):
        def ready():
            if select.select([self.fd], [], [], 0.05)[0]:
                block = os.read(self.fd, 65536)
                if not block:
                    raise EOFError(f"terminal closed waiting for {marker!r}: {self.output[-500:]!r}")
                self.output.extend(block)
                # xterm primary device attributes reply. Do not inject replies
                # unsolicited: on a writable client those become pane input.
                if b"\x1b[c" in block:
                    os.write(self.fd, b"\x1b[?1;2c")
            return marker.encode() in self.output

        wait(ready, f"PTY did not render {marker!r}: {self.proc.args}")

    def close(self):
        os.close(self.fd)
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            self.proc.wait(timeout=5)
            raise AssertionError(f"closing the PTY left the observer process running: {self.proc.args}")


def verify(binary, root, stack):
    service_socket = root / "api.sock"
    # Substitute only the model process. The real agentctl runner owns each pane.
    harness = root / "model"
    harness.write_text(
        "#!/bin/sh\n"
        'task=$(cat)\n'
        'printf \'{"type":"assistant","message":{"content":[{"type":"text","text":"LIVE_%s"}]}}\\n\' "$task"\n'
        'while [ ! -f "$task.release" ]; do sleep 0.05; done\n'
        'printf \'{"type":"result","subtype":"success","result":"LATE_%s"}\\n\' "$task"\n'
    )
    harness.chmod(0o700)
    env = {k: v for k, v in os.environ.items() if not k.startswith("AGENT_COMMANDER_")}
    env.update(AGENT_COMMANDER_HOME=str(root), AGENT_COMMANDER_SOCKET=str(service_socket),
               AGENT_COMMANDER_CLAUDE=str(harness), AGENT_COMMANDER_RUNTIME="legacy",
               TMUX_TMPDIR=str(root), TERM="xterm-256color")
    env.pop("TMUX", None)
    server = subprocess.Popen([binary, "serve"], env=env)

    def stop_service():
        server.terminate()
        server.wait(timeout=5)

    stack.callback(stop_service)
    wait(service_socket.exists, "isolated service socket")

    def command(*args):
        return subprocess.check_output(args, text=True, env=env, timeout=8).strip()

    def api(method, path, body=None):
        response = subprocess.check_output(
            [binary, "api", method, path], input=json.dumps(body) if body is not None else "",
            text=True, env=env, timeout=8)
        return json.loads(response)

    run = api("POST", "/v1/runs", {"task": "COORD", "path": str(root), "client": "claude"})
    stack.callback(command, binary, "stop", run["id"])
    workers = [api("POST", f"/v1/runs/{run['id']}/workers", {"name": m, "task": m})
               for m in ("ALPHA", "BRAVO")]
    # Worker creation schedules the tmux launch asynchronously.
    def descriptor(worker):
        cmd = [binary, "api", "GET", f"/v1/workers/{worker['id']}/terminal"]
        result = subprocess.run(cmd, text=True, capture_output=True, env=env, timeout=8)
        if result.returncode == 0:
            return json.loads(result.stdout)
        if "(409)" not in result.stderr:
            raise RuntimeError(result.stderr)

    descriptors = [wait(lambda: descriptor(w), f"live tmux target for {w['name']}") for w in workers]
    a, b = descriptors
    assert a["session_id"] != b["session_id"] and a["socket_path"] == b["socket_path"]
    assert [d["worker_id"] for d in descriptors] == [w["id"] for w in workers]
    socket = a["socket_path"]
    assert Path(socket).resolve().is_relative_to(root.resolve()), socket

    def tmux(*args):
        return command("tmux", "-S", socket, *args)

    def pane(target, format_string):
        return tmux("display-message", "-p", "-t", target, format_string)

    def text(target):
        return tmux("capture-pane", "-pt", target)

    target, neighbor = a["session_id"], b["session_id"]
    wait(lambda: "LIVE_ALPHA" in text(target) and "LIVE_BRAVO" in text(neighbor), "workers ready")
    size = "#{pane_width}x#{pane_height}"
    original_size = pane(target, size)
    pids = [pane(t, "#{pane_pid}") for t in (target, neighbor)]
    observe = [binary, "terminal", "observe", workers[0]["id"]]

    def clients():
        return tmux("list-clients", "-F", "#{session_id} #{client_flags} #{client_width}").splitlines()

    first = Client(observe, env, 23, 87)
    try:
        first.expect("LIVE_ALPHA")
        assert pane(target, size) == original_size, "first observer resized a detached worker"
        first.resize(31, 101)
        wait(lambda: any("read-only" in v and v.endswith(" 101") for v in clients()), "PTY resize")
        assert pane(target, size) == original_size
        os.write(first.fd, b"NO_VIEWER_INPUT\r\x03")
    finally:
        first.close()
    wait(lambda: tmux("list-clients", "-F", "#{client_name}") == "", "first observer teardown")
    assert "NO_VIEWER_INPUT" not in text(target)

    # A writable external terminal stays attached when the viewer is reopened.
    with ExitStack() as attached:
        writer = Client(["tmux", "-S", socket, "attach", "-t", target], env, 36, 108)
        attached.callback(writer.close)
        writer.expect("LIVE_ALPHA")
        writer_size = pane(target, size)
        second = Client(observe, env, 20, 72)
        attached.callback(second.close)
        second.expect("LIVE_ALPHA")
        assert b"LIVE_BRAVO" not in second.output
        assert len(clients()) == 3, clients()
        assert all(v.startswith(target + " ") for v in clients()), clients()
        assert pane(target, size) == writer_size
        writer.resize(40, 112)
        wait(lambda: pane(target, size) == "112x39", "external writer still sizes the pane")
        os.write(second.fd, b"NO_SECOND_INPUT\r")
        (root / "ALPHA.release").touch()
        second.expect("LATE_ALPHA")
        writer.expect("LATE_ALPHA")
        assert b"NO_SECOND_INPUT" not in writer.output
        assert pane(target, size) == "112x39"
        assert "LATE_BRAVO" not in text(neighbor) and "NO_SECOND_INPUT" not in text(neighbor)

    wait(lambda: tmux("list-clients", "-F", "#{client_name}") == "", "all observer teardown")
    third = Client(observe, env, 27, 94)
    try:
        third.expect("LATE_ALPHA")
        assert b"LIVE_BRAVO" not in third.output
    finally:
        third.close()
    assert pids == [pane(t, "#{pane_pid}") for t in (target, neighbor)]


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="ac-pty-", dir="/tmp") as temp, ExitStack() as cleanup:
        verify(sys.argv[1], Path(temp), cleanup)
