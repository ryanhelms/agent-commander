#!/usr/bin/env python3
"""Repeat the archived capacity trials using their original workload parameters."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agentctl", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--projection", choices=("legacy", "incremental"), required=True)
    args = parser.parse_args()
    suite = Path(__file__).resolve().parent
    if args.output_dir.resolve() == suite:
        parser.error("choose a results directory separate from the baseline")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name in ("text-256", "gap-100", "fanout-4", "mixed-50", "text-4k", "text-256-30s", "two-by-50"):
        original = json.loads((suite / f"{name}.json").read_text())
        config = original["configuration"]
        destination = args.output_dir / f"{name}.json"
        common = ["--agentctl", str(args.agentctl.resolve()), "--seconds", str(config["seconds"]),
                  "--idle", str(config["idle"]), "--size", str(config["size"]),
                  "--projection", args.projection, "--output", str(destination)]
        if config.get("worker_count") == 2:
            driver = "two_workers.py"
            options = ["--rate", str(config["target_per_worker_s"]), "--trials", str(len(original["trials"]))]
        else:
            driver = "measure.py"
            options = ["--rates", *map(str, config["rates"]), "--tool-every", str(config["tool_every"]),
                       "--observers", str(config["observers"]), "--trials", str(config["trials"])]
        subprocess.run([sys.executable, "-B", str(suite / driver), *common, *options],
                       stdout=subprocess.DEVNULL, check=True)
        report = json.loads(destination.read_text())
        missing = sum(o["missing"] for trial in report["trials"]
                      for o in trial.get("workers", trial["load"]["observers"]))
        print(f"{args.projection} {name}: {len(report['trials'])} trial(s), {missing} missing IDs across readers",
              flush=True)


if __name__ == "__main__":
    main()
