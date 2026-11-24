"""Capture selected Claude/Codex workers for native live or cold replay tests."""
import argparse
import base64
from contextlib import closing
import http.client
import json
import os
from pathlib import Path
import socket
import time
from urllib.parse import quote, urlencode


def verify_provider_media(read, worker, sample):
    original_png = sample["png"]
    if original_png in json.dumps(worker):
        raise RuntimeError("The workspace projection contains the original image bytes")
    claims = [m.get("metadata", {}).get("acp", {}) for m in worker.get("messages", []) if m.get("role") == "user"]
    claims = [c for c in claims if c.get("source") == "provider" and c.get("kind") == "provider_prompt_media"]
    if not claims:
        raise RuntimeError("No recovered user prompt offers a provider attachment")
    owners = {o["cursor"]: o for o in sample["provider"]["observations"]
              if o.get("cursor") and o.get("sourceCursor") == o["cursor"]}
    matched_png = False
    sample["providerMediaReads"] = {}
    for claim in claims:
        query = {"recordCursor": claim["cursor"]}
        if claim.get("pageCursor"):
            query["cursor"] = claim["pageCursor"]
        page = read(f"/v1/workers/{quote(worker['id'], safe='')}/history?{urlencode(query)}")
        records = page.get("observations", [])
        if len(records) != 1 or page.get("nextCursor") or records[0] != owners.get(claim["cursor"]):
            raise RuntimeError("The attachment read did not return exactly the selected original")
        sample["providerMediaReads"][claim["cursor"]] = page
        envelope = records[0].get("sourceRecord") or records[0]["extension"]
        original = json.loads(base64.b64decode(envelope["data"], validate=True))
        matched_png |= original_png in json.dumps(original)
    if not matched_png:
        raise RuntimeError("The selected prompt media did not contain the original PNG")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--source", choices=("provider", "live"), default="provider")
    parser.add_argument("--require-complete-live", action="store_true",
                        help="Check every visible live source link for a settled worker inside its retention window")
    parser.add_argument("--require-provider-media", action="store_true",
                        help="Open each recovered prompt attachment reference and verify the original swatch")
    for name in ("claude", "codex"):
        parser.add_argument("--" + name, required=True, help="Worker ID")
        parser.add_argument("--" + name + "-png", type=Path, help="Original swatch for the cold provider replay")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.require_complete_live and args.source != "live":
        parser.error("--require-complete-live requires --source live")
    if args.require_provider_media and args.source != "provider":
        parser.error("--require-provider-media requires --source provider")
    if args.source == "provider" and not (args.claude_png and args.codex_png):
        parser.error("cold provider replay requires both original PNG files")

    class OwnerSocket(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.settimeout(30)
            self.sock.connect(args.socket)

    def read(path, stream=False):
        with closing(OwnerSocket("localhost")) as conn:
            conn.request("GET", path)
            with conn.getresponse() as response:
                if response.status != 200:
                    raise RuntimeError(f"Commander returned HTTP {response.status}")
                if stream:
                    return next(json.loads(line[6:]) for line in response if line.startswith(b"data: "))
                return json.load(response)

    sessions = {}
    for name in ("claude", "codex"):
        worker = getattr(args, name)
        records, cursors, cursor = [], set(), ""
        while True:
            selection = {"limit": 1, "cursor": cursor}
            if args.source == "live":
                selection["source"] = "live"
            query = urlencode(selection)
            page = read(f"/v1/workers/{quote(worker, safe='')}/history?{query}")
            records.extend(page["observations"])
            cursor = page.get("nextCursor", "")
            if not cursor:
                break
            if cursor in cursors:
                raise RuntimeError("Selected history repeated a page cursor")
            cursors.add(cursor)
        sessions[name] = {"worker": worker, args.source: {"observations": records}}
        if args.source == "provider":
            image = getattr(args, name + "_png").read_bytes()
            sessions[name]["png"] = base64.b64encode(image).decode("ascii")
        elif not any(o.get("sourceRecord", {}).get("type") == "acp.prompt_result" for o in records):
            raise RuntimeError(f"{name} has no retained live ACP prompt response")

    wanted = {args.claude, args.codex}
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        event = read("/v1/ag-ui/events?projection=incremental", stream=True)
        selected = []
        for run in event["snapshot"]["runs"]:
            workers = [w for w in run["workers"] if w["id"] in wanted]
            if workers:
                requests = [q for q in run.get("requests", []) if q["worker_id"] in wanted]
                selected.append(dict(run, workers=workers, requests=requests))
        if len(selected) == 1 and len(selected[0]["workers"]) == 2 and all(
            any(m.get("metadata", {}).get("acp", {}).get("source") == args.source for m in w.get("messages", []))
            for w in selected[0]["workers"]
        ):
            if args.require_provider_media:
                for name, sample in sessions.items():
                    worker = next(w for w in selected[0]["workers"] if w["id"] == sample["worker"])
                    verify_provider_media(read, worker, sample)
                    print(f"{name}: prompt attachment opened from its source reference", flush=True)
            if args.require_complete_live:
                for name, session in sessions.items():
                    worker = next(w for w in selected[0]["workers"] if w["id"] == session["worker"])
                    records = session["live"]["observations"]
                    available = {r["cursor"] for r in records if "cursor" in r and "gap" not in r}
                    visible = set()
                    for message in worker["messages"]:
                        meta = message.get("metadata", {})
                        for ref in (meta.get("acp", {}), *meta.get("acpSources", [])):
                            if ref.get("source") == "live" and ref.get("cursor"):
                                visible.add(ref["cursor"])
                    gaps = sum("gap" in r for r in records)
                    missing = sorted(visible - available)
                    if gaps or missing or not visible:
                        raise RuntimeError(f"{name}: {gaps} gaps, {len(visible)} visible source links, missing {missing}")
                    print(f"{name}: {len(visible)} live source links resolved in {len(records)} records", flush=True)
            event["snapshot"]["runs"] = selected
            with os.fdopen(os.open(args.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as out:
                json.dump({"event": event, "sessions": sessions}, out)
            return
        time.sleep(.25)
    raise RuntimeError(f"Expected two workers with {args.source} references in the selected run")


if __name__ == "__main__":
    main()
