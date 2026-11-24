"""Compare a cold Commander capture to the selected harnesses' passive APIs."""
import argparse
import base64
import collections
import json
import os
from pathlib import Path
import subprocess


def claude_records(session, project, sdk_anchor):
    # Resolve the same installed provider SDK independently of Commander's reader.
    script = """
      import {createRequire} from 'node:module';
      import {pathToFileURL} from 'node:url';
      const [anchor, id, dir] = process.argv.slice(1);
      const sdk = await import(pathToFileURL(createRequire(anchor).resolve('@anthropic-ai/claude-agent-sdk')));
      for (let offset = 0;;) {
        const rows = await sdk.getSessionMessages(id, {dir, offset, limit:64, includeSystemMessages:true});
        for (const row of rows) console.log(JSON.stringify(row));
        if (rows.length < 64) break;
        offset += rows.length;
      }
    """
    data = subprocess.check_output(["node", "--input-type=module", "-e", script, "--",
                                    str(sdk_anchor.resolve()), session, str(project.resolve())], timeout=60)
    return [json.loads(line) for line in data.splitlines()]


def codex_records(session, executable, profile):
    env = None if profile is None else {**os.environ, "CODEX_HOME": str(profile.resolve(strict=True))}
    peer = subprocess.Popen([executable, "app-server", "--listen", "stdio://"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, text=True, env=env)
    request_id = 0

    def send(message):
        peer.stdin.write(json.dumps(message) + "\n")
        peer.stdin.flush()

    def call(method, params):
        nonlocal request_id
        request_id += 1
        send({"id": request_id, "method": method, "params": params})
        for line in peer.stdout:
            message = json.loads(line)
            if message.get("id") == request_id:
                if "error" in message:
                    raise ValueError(f"Codex could not read {method}")
                return message["result"]
        raise ValueError(f"Codex closed during {method}")

    try:
        call("initialize", {"clientInfo": {"name": "commander-history-audit", "version": "1"},
                            "capabilities": {"experimentalApi": False}})
        send({"method": "initialized"})
        thread = call("thread/read", {"threadId": session, "includeTurns": False})
        if thread["thread"]["id"] != session:
            raise ValueError("Codex returned a different selected session")
        records = []
        params = {"threadId": session, "limit": 8, "sortDirection": "asc", "itemsView": "full"}
        seen = set()
        while True:
            page = call("thread/turns/list", params)
            for turn in page["data"]:
                records.extend(turn.pop("items"))
                records.append(turn)
            cursor = page.get("nextCursor")
            if not cursor:
                return [*records, thread]
            if cursor in seen:
                raise ValueError("Codex repeated a native cursor")
            seen.add(cursor)
            params["cursor"] = cursor
    finally:
        peer.stdin.close()
        peer.terminate()
        try:
            peer.wait(timeout=5)
        except subprocess.TimeoutExpired:
            peer.kill()
            peer.wait()
        peer.stdout.close()


def original_key(value):
    # JSON object key order is immaterial. Keep arrays ordered, integer precision
    # intact, and booleans distinct from 0 and 1 in the multiset comparison.
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--claude-sdk-anchor", type=Path, required=True, help="Installed harness package.json")
    parser.add_argument("--claude-project", type=Path, required=True)
    parser.add_argument("--codex", default="codex", help="Codex executable for the selected profile")
    parser.add_argument("--codex-profile", type=Path, help="Existing managed profile that owns the selected Codex session")
    args = parser.parse_args()
    samples = json.loads(args.capture.read_bytes())["sessions"]
    for name in ("claude", "codex"):
        rows = samples[name]["provider"]["observations"]
        sessions = {r["session"]["sessionId"] for r in rows}
        if len(sessions) != 1:
            raise ValueError(f"{name} capture must contain one selected session")
        session = sessions.pop()
        direct = (claude_records(session, args.claude_project, args.claude_sdk_anchor) if name == "claude"
                  else codex_records(session, args.codex, args.codex_profile))
        owners = {}
        for row in rows:
            if row.get("sourceCursor") == row.get("cursor") and row.get("cursor"):
                record = row.get("sourceRecord") or row["extension"]
                if row["cursor"] in owners:
                    raise ValueError(f"{name} emitted a duplicate source owner")
                owners[row["cursor"]] = json.loads(base64.b64decode(record["data"], validate=True))
        if any(r.get("sourceCursor") not in owners for r in rows):
            raise ValueError(f"{name} has an unresolved original")
        expected = collections.Counter(map(original_key, direct))
        actual = collections.Counter(map(original_key, owners.values()))
        if expected != actual:
            raise ValueError(f"{name}: {sum((expected-actual).values())} missing or changed originals, "
                             f"{sum((actual-expected).values())} unexpected originals")
        print(f"{name}: all {len(direct)} provider originals matched the captured values")


if __name__ == "__main__":
    main()
