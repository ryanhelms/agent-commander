#!/usr/bin/env python3
"""A stand-in for `commander-relay host --json <action>`, for tests and headless renders.

Point COMMANDER_RELAY_BIN at this file in a debug build's fixture mode. It starts nothing, loads no
launch agent and reaches no network: it keeps a made-up host in a scratch file
(COMMANDER_RELAY_FIXTURE_STATE, or a file in the temporary folder) and answers each action with
the relay's own envelope, `{"ok": bool, "host": Report, "error": string}`.

    status      the host as it stands.
    setup       takes `{"admin", "name", "clientId"}` and starts the relay.
    install     starts the relay; `uninstall` stops it.
    listing     `{"url": "https://relay.example.org"}` lists the relay under that public https
                origin (a host or host:port is taken as https; http is refused), `{"url": ""}`
                unlists it. `directory` overrides the directory's origin.

COMMANDER_RELAY_FIXTURE_HOST picks where a fresh host starts: `running` (the default), `stopped`
or `unconfigured`. COMMANDER_RELAY_FIXTURE_LISTING picks how a listing turns out, which the report
shows from the second `status` read after it was turned on, as the running relay takes a moment:

    listed       (the default) the directory took it.
    private      "the relay's address is not public".
    key          "the relay at that URL presents a different key".
    unreachable  the directory can't be reached.
    checking     the relay never reports a try.

While the relay is stopped nothing is checked. Every action refuses a field it doesn't know.
"""
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

STATE = os.environ.get("COMMANDER_RELAY_FIXTURE_STATE") or os.path.join(tempfile.gettempdir(), "commander-relay-fixture.json")
DIRECTORY = "https://directory.bytedesk.ai"
DIR = "/Users/fixture/Library/Application Support/Agent Commander/relay"
OUTCOMES = {
    "listed": "",
    "private": "the relay's address is not public",
    "key": "the relay at that URL presents a different key",
    "unreachable": "cannot reach the directory at directory.bytedesk.ai: dial tcp: lookup directory.bytedesk.ai: no such host",
}


def now():
    fixed = os.environ.get("COMMANDER_NETWORK_FIXTURE_NOW")
    moment = datetime.fromtimestamp(int(fixed), timezone.utc) if fixed else datetime.now(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def load():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        start = os.environ.get("COMMANDER_RELAY_FIXTURE_HOST", "running")
        return {"state": start if start in ("running", "stopped", "unconfigured") else "running",
                "listing": {"url": "", "directory": DIRECTORY, "listed": False}, "reads": 0}


def save(state):
    with open(STATE, "w") as handle:
        json.dump(state, handle)


def report(state):
    if state["state"] == "unconfigured":
        return {"state": "unconfigured", "installed": False, "dir": DIR, "log": DIR + "/logs/relay.err.log",
                "setup": {"name": "fixture-mac", "hostnames": ["fixture-mac.tail.example"],
                          "issuer": "https://accounts.example", "clientId": "fixture.apps.example"}}
    running = state["state"] == "running"
    return {"state": state["state"], "installed": running, "name": "fixture-mac",
            "url": "https://fixture-mac.tail.example:443", "pin": "sha256/" + "A" * 43 + "=",
            "dir": DIR, "log": DIR + "/logs/relay.err.log", "listing": state["listing"]}


def origin(text):
    text = text.strip()
    if text.lower().startswith("http://"):
        raise ValueError("the public URL must use https")
    host = text[8:] if text.lower().startswith("https://") else text
    host = host.rstrip("/")
    if not host or "/" in host or " " in host or "." not in host:
        raise ValueError("the public URL must be an https origin, such as https://relay.example.org")
    return "https://" + host.lower()


def check(state):
    """The running relay's registration, written a read after the listing was turned on."""
    listing = state["listing"]
    mode = os.environ.get("COMMANDER_RELAY_FIXTURE_LISTING", "listed")
    if state["state"] != "running" or not listing["url"] or mode not in OUTCOMES:
        return
    state["reads"] = state.get("reads", 0) + 1
    if state["reads"] < 2:
        return
    listing.update(listed=mode == "listed", checkedAt=now())
    listing.pop("error", None)
    if OUTCOMES[mode]:
        listing["error"] = OUTCOMES[mode]


def run(action, request):
    state = load()
    allowed = {"status": set(), "install": set(), "uninstall": set(), "setup": {"admin", "name", "clientId"},
               "listing": {"url", "directory"}}
    if action not in allowed:
        raise ValueError("unknown host action %s" % action)
    if set(request) - allowed[action]:
        raise ValueError("invalid request")
    if action == "status":
        check(state)
    elif action == "setup":
        if not request.get("admin"):
            raise ValueError("an admin email is required")
        state["state"] = "running"
    elif action == "install":
        if state["state"] == "unconfigured":
            raise ValueError("set the relay up first")
        state["state"] = "running"
    elif action == "uninstall":
        if state["state"] != "unconfigured":
            state["state"] = "stopped"
        state["listing"].update(listed=False)
    else:
        if state["state"] == "unconfigured":
            raise ValueError("set the relay up first")
        url = request.get("url", "")
        listing = {"url": origin(url) if url else "", "directory": request.get("directory") or DIRECTORY, "listed": False}
        state.update(listing=listing, reads=0)
    save(state)
    return report(state)


def main():
    if len(sys.argv) != 4 or sys.argv[1:3] != ["host", "--json"]:
        print(json.dumps({"ok": False, "error": "usage: host --json ACTION"}))
        return 2
    try:
        request = json.loads(sys.stdin.read() or "{}")
        print(json.dumps({"ok": True, "host": run(sys.argv[3], request)}))
    except ValueError as problem:
        print(json.dumps({"ok": False, "error": str(problem)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
