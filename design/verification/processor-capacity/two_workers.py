#!/usr/bin/env python3
"""Compare two simultaneous ACP producers in one run with the single-worker baseline (macOS)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

from measure import HERE, Observer, pane, phase


def trial(binary, args):
    with tempfile.TemporaryDirectory(prefix="ac-dual-", dir="/tmp") as name:
        root = Path(name).resolve()
        state, work, socket = root / "data", root / "work", root / "s.sock"
        state.mkdir(mode=0o700)
        work.mkdir(mode=0o700)
        directories = [root / "fixture-a", root / "fixture-b"]
        count = round(args.rate * args.seconds)
        profiles = {}
        for directory in directories:
            directory.mkdir(mode=0o700)
            (directory / "start").symlink_to(root / "start")
            (directory / "config.json").write_text(json.dumps(
                {"rate": args.rate, "count": count, "size": args.size, "tool_every": 0}))
            profiles[directory.name] = {"command": sys.executable, "omit_commander_mcp": True,
                                        "args": [str(HERE / "fixture_acp.py"), str(directory)]}
        (state / "acp-profiles.json").write_text(json.dumps(profiles))
        env = {k: v for k, v in os.environ.items() if not k.startswith("AGENT_COMMANDER_")
               and k not in ("TMUX", "TMUX_PANE")}
        env.update(TMUX_TMPDIR=str(root), AGENT_COMMANDER_HOME=str(state), AGENT_COMMANDER_SOCKET=str(socket))
        label = "ac-" + hashlib.sha256(str(state).encode()).hexdigest()[:12]
        tmux = [shutil.which("tmux"), "-L", label]
        observer = None
        with (root / "service.log").open("w") as log:
            service = subprocess.Popen([binary, "serve"], env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    try:
                        pane.api(socket, "GET", "/v1/health")
                        break
                    except OSError:
                        if service.poll() is not None:
                            raise RuntimeError("isolated service exited during startup")
                        time.sleep(0.05)
                run = pane.api(socket, "POST", "/v1/runs", {"client": "fixture-a", "path": str(work),
                                                           "task": "capacity"}, 201)
                child = pane.api(socket, "POST", f"/v1/runs/{run['id']}/workers",
                                 {"client": "fixture-b", "name": "Producer B", "task": "capacity"}, 201)
                workers = [run["coordinator_id"], child["id"]]
                observer = Observer(socket, workers[0], workers[1:], projection=args.projection)
                records = [observer.markers[key] for key in workers]
                observer.until(lambda _: all(r.ready_seen for r in records), "both producers ready", timeout=25)
                pids = [service.pid]
                for worker in workers:
                    pid = int(subprocess.check_output(tmux + ["display-message", "-p", "-t", "=" + worker + ":",
                                                              "#{pane_pid}"], env=env, text=True))
                    comm = subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], text=True).strip()
                    if Path(comm).name != binary.name or pid in pids:
                        raise RuntimeError("unexpected runner PID")
                    pids.append(pid)
                names = ("service", "runner_a", "runner_b")
                idle = phase(pids, [observer], args.idle, process_names=names)
                load = phase(pids, [observer], 2 * args.seconds + 15, start=lambda: (root / "start").touch(),
                             complete=lambda: all(r.fence_seen for r in records), process_names=names)
                sent = [json.loads((d / "sent.json").read_text()) for d in directories]
                overlap = min(s["last_flush_monotonic"] for s in sent) - max(s["first_scheduled_monotonic"] for s in sent)
                if overlap <= 0:
                    raise RuntimeError("producer emission windows did not overlap")
                wall = load["wall_s"]
                expected = set(range(1, count + 1))
                deliveries = []
                with observer.ready:
                    for record, sender in zip(records, sent):
                        if sender["count"] != count:
                            raise RuntimeError("fixture count mismatch")
                        missing = expected - record.seen
                        deliveries.append({"sent": count, "delivered_unique": len(expected & record.seen),
                                           "delivered_per_s": len(expected & record.seen) / wall,
                                           "missing": len(missing), "first_missing_ids": sorted(missing)[:10],
                                           "output_unique": len(expected & record.output_seen),
                                           "unexpected": len(record.seen - expected), "gap_seen": record.gap_seen})
                span = max(s["last_flush_monotonic"] for s in sent) - min(s["first_scheduled_monotonic"] for s in sent)
                return {"idle": idle, "load": load, "workers": deliveries, "overlap_s": overlap,
                        "combined_emission_span_s": span, "sent_per_s_over_load_window": 2 * count / wall,
                        "acp_stdio_bytes_per_s": sum(s["acp_stdio_bytes"] for s in sent) / wall,
                        "delivered_per_s": sum(d["delivered_unique"] for d in deliveries) / wall}
            finally:
                if observer:
                    observer.close()
                subprocess.run(tmux + ["kill-server"], env=env, capture_output=True)
                if service.poll() is None:
                    service.terminate()
                try:
                    service.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    service.kill()
                    service.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agentctl", type=Path, required=True)
    parser.add_argument("--rate", type=int, default=50, help="target updates per second for EACH worker")
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--idle", type=float, default=3)
    parser.add_argument("--size", type=int, default=256)
    parser.add_argument("--trials", type=int, default=2)
    parser.add_argument("--projection", choices=["legacy", "incremental"], default="legacy")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if min(args.rate, args.seconds, args.idle, args.trials) <= 0 or not 16 <= args.size <= 16384:
        parser.error("requires positive rates, windows, trials and a payload of 16–16384 bytes")
    if not 2 <= round(args.rate * args.seconds) <= 999999999:
        parser.error("each worker must emit between 2 and 999999999 inputs to measure overlap")
    if platform.system() != "Darwin" or not shutil.which("tmux"):
        parser.error("requires macOS and tmux")
    binary = args.agentctl.resolve(strict=True)
    report = {"system": platform.platform(), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "configuration": {"worker_count": 2, "target_per_worker_s": args.rate, "seconds": args.seconds,
                                "idle": args.idle, "size": args.size, "observers": 1,
                                "projection": args.projection}, "trials": []}
    for i in range(args.trials):
        row = trial(binary, args)
        row["trial"] = i + 1
        report["trials"].append(row)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
