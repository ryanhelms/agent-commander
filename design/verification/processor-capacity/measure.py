#!/usr/bin/env python3
"""Measure ACP input through Commander workspace delivery on macOS. No third-party Python packages."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pane_fixture", HERE.parent / "30-pane" / "measure.py")
pane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pane)
MARKER = re.compile(r"CPEV([0-9]{9})Z")


class WorkerMarkers:
    def __init__(self):
        self.seen = set()
        self.output_seen = set()
        self.gap_seen = False
        self.ready_seen = self.fence_seen = False

    def record(self, worker):
        output = "".join(worker["outputChunks"]) if "outputChunks" in worker else worker.get("output", "")
        self.output_seen.update(map(int, MARKER.findall(output)))
        for message in worker.get("messages", []):
            fields = [message.get("content") or ""]
            fields.extend(call["function"]["arguments"] for call in message.get("toolCalls", []))
            for value in fields:
                self.seen.update(map(int, MARKER.findall(value)))
                self.ready_seen |= "CAPACITY_READY" in value
                self.fence_seen |= "CAPACITY_FENCE" in value
                self.gap_seen |= "Some console output could not be synchronized" in value


class Observer(pane.Workspace):
    def __init__(self, path, worker, extra_workers=(), projection="legacy", check_private=False):
        self.check_private = check_private
        self.private_marker_seen = False
        self.markers = {key: WorkerMarkers() for key in (worker, *extra_workers)}
        route = "/v1/ag-ui/events" if projection == "legacy" else "/v1/ag-ui/events?projection=incremental"
        super().__init__(path, route)

    def _follow(self):
        state = {}
        try:
            for line in self.response:
                if not line.startswith(b"data: "):
                    continue
                payload = line[6:].rstrip(b"\r\n")
                event = json.loads(payload)
                if event["type"] == "STATE_SNAPSHOT":
                    state = event["snapshot"]
                else:
                    pane.apply_delta(state, event["delta"])
                with self.ready:
                    self.payload_bytes += len(payload)
                    if self.check_private and b"CPSRC_" in payload:
                        self.private_marker_seen = True
                    self.frames += 1
                    for key, markers in self.markers.items():
                        markers.record(pane.worker(state["runs"], key))
                    self.ready.notify_all()
        except Exception as error:
            with self.ready:
                self.error = error
                self.ready.notify_all()

    def stats(self):
        with self.ready:
            if self.error:
                raise RuntimeError("observer failed") from self.error
            return self.frames, self.payload_bytes


class SourceReader:
    """Advance opaque page cursors, revisiting only the unfinished tail page."""
    def __init__(self, socket, worker, outer, text_bytes, tool_every):
        self.socket, self.worker = socket, worker
        self.outer, self.text_bytes, self.tool_every = outer, text_bytes, tool_every
        self.carriers = {}
        self.kinds = {}
        self.fence_carrier = None
        self.valid_fence = False
        self.cursor = ""
        self.cursors, self.sequence = set(), []
        self.gaps, self.invalid = set(), []
        self.fence = False
        self.pages = 0
        self.poll_interval = 0.25
        self.next_poll = 0

    def poll(self):
        if time.monotonic() < self.next_poll or self.fence:
            return
        self.next_poll = time.monotonic() + self.poll_interval
        while True:
            query = {"source": "live", "turnId": "initial-" + self.worker, "limit": 24}
            if self.cursor:
                query["cursor"] = self.cursor
            route = f"/v1/workers/{self.worker}/history?" + urlencode(query)
            page = pane.api(self.socket, "GET", route)
            self.accept_page(page)
            following = page.get("nextCursor")
            if not following:
                break
            if following == self.cursor:
                raise RuntimeError("private source cursor did not advance")
            self.cursor = following

    def accept_page(self, page, *, dedupe=True):
        self.pages += 1
        for row in page.get("observations", []):
            cursor = row.get("cursor", "")
            if row.get("gap"):
                reason = row["gap"].get("reason", "")
                if reason not in ("No live ACP source records are retained for this session",
                                  "No live ACP source records are retained for this turn"):
                    self.gaps.add((cursor or self.cursor, reason))
                continue
            if not dedupe or cursor not in self.cursors:
                self.cursors.add(cursor)
                self.record(row)

    def record(self, row):
        carrier = "sourceRecord" if row.get("sourceRecord") else "extension"
        payload = row.get(carrier, {})
        source_type = payload.get("type")
        if source_type not in ("acp.session_update", "acp.session_update_params"):
            return
        original = json.loads(base64.b64decode(payload["data"], validate=True))
        outer = source_type == "acp.session_update_params"
        if not isinstance(original, dict) or not isinstance(original.get("_meta"), dict):
            return
        marker = original["_meta"].get("privateSequence")
        if not isinstance(marker, str) or not marker:
            return
        update = original.get("update") if outer else original
        if not isinstance(update, dict):
            update = {}
        valid = outer == self.outer and row.get("turnId") == "initial-" + self.worker
        if outer:
            valid &= original.get("sessionId") == (row.get("session") or {}).get("sessionId") and row.get("sourceCursor") == row["cursor"]
            valid &= "privateSequence" not in (update.get("_meta") or {})
        if marker == "CPSRC_FENCE":
            self.fence = True
            self.fence_carrier = carrier
            if outer:
                valid &= carrier == "extension" and update.get("sessionUpdate") == "notice"
            else:
                valid &= update.get("content", {}).get("text") == "CAPACITY_FENCE\n"
            self.valid_fence = valid
            return
        index = int(marker.removeprefix("CPSRC_"))
        self.sequence.append(index)
        self.carriers[carrier] = self.carriers.get(carrier, 0) + 1
        kind = update.get("sessionUpdate")
        self.kinds[kind] = self.kinds.get(kind, 0) + 1
        is_tool = bool(self.tool_every and index % self.tool_every == 0)
        expected_text = f"CPEV{index:09d}Z".ljust(self.text_bytes - 1, "x") + "\n"
        if kind == "agent_message_chunk":
            valid &= not is_tool and update.get("messageId") == "capacity-message" and update.get("content") == {"type": "text", "text": expected_text}
        elif kind == "tool_call_update":
            expected_content = [{"type": "content", "content": {"type": "text", "text": expected_text}}]
            valid &= is_tool and update.get("toolCallId") == "fixture-tool" and update.get("content") == expected_content
        else:
            valid = False
        if outer:
            valid &= carrier == "sourceRecord" and (row.get("tool") is not None if is_tool else row.get("text") is not None)
        if not valid:
            self.invalid.append(index)

    def report(self, expected):
        seen = set(self.sequence)
        return {"delivered_unique": len(seen & expected), "missing": len(expected - seen),
                "first_missing_ids": sorted(expected - seen)[:10], "unexpected": len(seen - expected),
                "duplicate_ids": len(self.sequence) - len(seen), "in_order": self.sequence == sorted(self.sequence),
                "invalid_originals": self.invalid[:10], "invalid_count": len(self.invalid), "fence": self.fence,
                "valid_fence": self.valid_fence, "fence_carrier": self.fence_carrier, "carriers": self.carriers,
                "update_types": self.kinds, "pages_read": self.pages,
                "poll_interval_s": self.poll_interval, "gaps": sorted({reason for _, reason in self.gaps}),
                "gap_records_seen": len(self.gaps)}


class SourceStream(SourceReader, pane.Workspace):
    """Read the same private source records from one continuous subscription."""
    def __init__(self, socket, worker, outer, text_bytes, tool_every):
        SourceReader.__init__(self, socket, worker, outer, text_bytes, tool_every)
        self.poll_interval = None
        pane.Workspace.__init__(self, socket, f"/v1/workers/{worker}/live-source/events")

    def _follow(self):
        checkpoint = ""
        try:
            for line in self.response:
                if line.startswith(b"id: "):
                    checkpoint = line[4:].rstrip(b"\r\n").decode()
                if not line.startswith(b"data: "):
                    continue
                raw = line[6:].rstrip(b"\r\n")
                with self.ready:
                    self.payload_bytes += len(raw)
                    self.accept_page(json.loads(raw), dedupe=False)
                    self.cursor = checkpoint
        except Exception as error:
            with self.ready:
                self.error = error

    def poll(self):
        with self.ready:
            if self.error:
                raise RuntimeError("private source stream failed") from self.error

    def report(self, expected):
        with self.ready:
            return super().report(expected) | {"sse_json_bytes": self.payload_bytes}


def cpu_seconds(value):
    parts = value.split(":")
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(parts)))


def sample(pids):
    raw = subprocess.check_output(["ps", "-p", ",".join(map(str, pids)), "-o", "pid=,time=,rss="], text=True)
    by_pid = {}
    for line in raw.splitlines():
        pid, cpu, rss = line.split()
        by_pid[int(pid)] = (cpu_seconds(cpu), int(rss) / 1024)
    return time.monotonic(), [by_pid[pid] for pid in pids]


def phase(pids, observers, seconds, start=None, complete=None, process_names=("service", "runner")):
    before = [o.stats() for o in observers]
    samples = [sample(pids)]
    first, initial = samples[0]
    if start:
        start()
    deadline = first + seconds
    while True:
        time.sleep(0.1)
        samples.append(sample(pids))
        now = samples[-1][0]
        if complete and complete():
            break
        if now >= deadline:
            if complete:
                raise RuntimeError("timed out waiting for the producer and every observer's delivery fence")
            break
    elapsed = now - first
    result = {"wall_s": elapsed, "rss_samples": len(samples)}
    for idx, name in enumerate(process_names):
        cpu = samples[-1][1][idx][0] - initial[idx][0]
        memory = [stats[idx][1] for _, stats in samples]
        result[name] = {"cpu_s": cpu, "cpu_pct_one_core": 100 * cpu / elapsed,
                        "rss_median_mib": statistics.median(memory), "rss_peak_mib": max(memory)}
    result["observers"] = []
    for observer, (old_frames, old_bytes) in zip(observers, before):
        frames, nbytes = observer.stats()
        result["observers"].append({"frames": frames - old_frames, "sse_json_bytes": nbytes - old_bytes,
                                    "sse_json_bytes_per_s": (nbytes - old_bytes) / elapsed})
    return result


def trial(binary, args, rate, trial_number):
    with tempfile.TemporaryDirectory(prefix="ac-cap-", dir="/tmp") as tmp:
        root = Path(tmp).resolve()
        state, work, sock = root / "data", root / "work", root / "s.sock"
        state.mkdir(mode=0o700)
        work.mkdir(mode=0o700)
        count = max(1, round(rate * args.seconds))
        if count > 999999999:
            raise ValueError("fixture marker count exceeded")
        (root / "config.json").write_text(json.dumps({"count": count, "rate": rate, "size": args.size,
                                                      "tool_every": args.tool_every, "rich_source": args.rich_source, "outer_source": args.outer_source, "burst": args.burst}))
        profile = {"command": sys.executable, "args": [str(HERE / "fixture_acp.py"), str(root)],
                   "omit_commander_mcp": True}
        (state / "acp-profiles.json").write_text(json.dumps({"fixture": profile}))
        env = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_COMMANDER_")
               and key not in ("TMUX", "TMUX_PANE")}
        env.update(TMUX_TMPDIR=str(root), AGENT_COMMANDER_HOME=str(state), AGENT_COMMANDER_SOCKET=str(sock))
        label = "ac-" + hashlib.sha256(str(state).encode()).hexdigest()[:12]
        tmux = [shutil.which("tmux"), "-L", label]
        observers = []
        source_reader = None
        with (root / "service.log").open("w+") as log:
            proc = subprocess.Popen([binary, "serve"], env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    try:
                        pane.api(sock, "GET", "/v1/health")
                        break
                    except OSError:
                        if proc.poll() is not None:
                            raise RuntimeError("isolated service exited")
                        time.sleep(0.05)
                run = pane.api(sock, "POST", "/v1/runs", {"client": "fixture", "path": str(work),
                                                          "task": "capacity"}, 201)
                worker = run["coordinator_id"]
                for _ in range(args.observers):
                    observer = Observer(sock, worker, projection=args.projection, check_private=args.rich_source)
                    observers.append(observer)
                    observer.until(lambda _: observer.markers[worker].ready_seen, "fixture ready", timeout=25)
                runner = int(subprocess.check_output(tmux + ["display-message", "-p", "-t", "=" + worker + ":",
                                                               "#{pane_pid}"], env=env, text=True))
                comm = subprocess.check_output(["ps", "-p", str(runner), "-o", "comm="], text=True).strip()
                if Path(comm).name != binary.name:
                    raise RuntimeError(f"tmux pane PID is not the expected runner: {comm}")
                pids = [proc.pid, runner]
                idle = phase(pids, observers, args.idle)
                if args.rich_source:
                    reader = SourceStream if args.stream_source else SourceReader
                    source_reader = reader(sock, worker, args.outer_source, args.size, args.tool_every)

                def delivered():
                    if source_reader is not None:
                        source_reader.poll()
                    return all(o.markers[worker].fence_seen for o in observers) and (
                        source_reader is None or source_reader.fence)

                measured = phase(pids, observers, args.seconds * 2 + 15,
                                 start=lambda: (root / "start").touch(),
                                 complete=delivered)
                sent = json.loads((root / "sent.json").read_text())
                interval = measured["wall_s"]
                expected = set(range(1, count + 1))
                for observer, row in zip(observers, measured["observers"]):
                    with observer.ready:
                        markers = observer.markers[worker]
                        delivered = markers.seen & expected
                        missing = expected - markers.seen
                        row.update(delivered_unique=len(delivered), delivered_per_s=len(delivered) / interval,
                                   missing=len(missing), first_missing_ids=sorted(missing)[:10],
                                   output_unique=len(markers.output_seen & expected),
                                   synchronization_gap_seen=markers.gap_seen,
                                   unexpected=len(markers.seen - expected))
                result = {"trial": trial_number, "target_per_s": rate, "idle": idle, "load": measured,
                          "sent": count, "tool_updates_sent": count // args.tool_every if args.tool_every else 0,
                          "acp_stdio_bytes": sent["acp_stdio_bytes"], "acp_stdio_bytes_per_s": sent["acp_stdio_bytes"] / interval,
                          "offered_per_s_over_load_window": count / interval,
                          "input_text_bytes_per_s_over_load_window": args.size * count / interval}
                if source_reader is not None:
                    result["private_source"] = source_reader.report(expected)
                    result["private_marker_in_workspace"] = any(o.private_marker_seen for o in observers)
                span = sent["last_flush_monotonic"] - sent["first_scheduled_monotonic"]
                result["emission_span_s"] = span
                result["producer_interarrival_rate"] = (count - 1) / span if count > 1 else None
                return result
            finally:
                if isinstance(source_reader, SourceStream):
                    source_reader.close()
                for observer in observers:
                    observer.close()
                subprocess.run(tmux + ["kill-server"], env=env, capture_output=True)
                if proc.poll() is None:
                    proc.terminate()
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agentctl", type=Path, required=True)
    parser.add_argument("--rates", type=int, nargs="+", default=[10, 50, 100])
    parser.add_argument("--seconds", type=float, default=6)
    parser.add_argument("--idle", type=float, default=2)
    parser.add_argument("--size", type=int, default=256, help="text bytes per event, including marker and newline")
    parser.add_argument("--tool-every", type=int, default=0, help="make every Nth input a tool progress update")
    parser.add_argument("--rich-source", action="store_true", help="mark every update and verify private originals via a scoped history reader")
    parser.add_argument("--stream-source", action="store_true", help="read tracked originals from the private SSE endpoint")
    parser.add_argument("--outer-source", action="store_true", help="place the private marker on ACP params and end with a passive source fence")
    parser.add_argument("--burst", type=int, default=1, help="release this many scheduled updates together at the group's last deadline")
    parser.add_argument("--observers", type=int, default=1)
    parser.add_argument("--projection", choices=["legacy", "incremental"], default="legacy")
    parser.add_argument("--trials", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.outer_source or args.stream_source:
        args.rich_source = True
    if min(args.rates) < 1 or min(args.seconds, args.idle, args.observers, args.trials) <= 0 or args.tool_every < 0 or args.burst < 1:
        parser.error("rates, windows, observers, trials must be positive; tool-every must be nonnegative")
    if not 16 <= args.size <= 16384:
        parser.error("--size must be between 16 and 16384 bytes")
    if platform.system() != "Darwin" or not shutil.which("tmux"):
        parser.error("requires macOS and tmux in PATH")
    binary = args.agentctl.resolve(strict=True)
    report = {"system": platform.platform(), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "configuration": {k: v for k, v in vars(args).items() if k not in ("agentctl", "output")},
              "trials": []}
    for trial_number in range(1, args.trials + 1):
        for rate in args.rates:
            row = trial(binary, args, rate, trial_number)
            report["trials"].append(row)
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
