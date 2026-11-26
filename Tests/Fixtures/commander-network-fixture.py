#!/usr/bin/env python3
"""Review fixture for the Commander network tray (increment 1).

Stands in for `commander-network tray VERB` so the panel can be previewed without a relay:

    AGENT_COMMANDER_NETWORK_PANEL=1 \
    COMMANDER_NETWORK_BIN="$PWD/Tests/Fixtures/commander-network-fixture.py" \
    swift run AgentCommander          # debug builds only

It starts with two servers: ryan-mac (online, with friends and one friend request) and team-relay
(certificate changed). Changes are kept in a scratch file so add, rename, favorite, trust, sign-in
and remove can be exercised; delete that file, or set COMMANDER_NETWORK_FIXTURE_STATE to a new
path, to start again. Every name, host and fingerprint here is made up. Nothing touches a network.

Probe an address containing "fail" to see a failed step, or "trusted" for a certificate the system
already trusts. Any other address passes and asks for its fingerprint to be confirmed.
"""
import base64
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone

STATE = os.environ.get("COMMANDER_NETWORK_FIXTURE_STATE") or os.path.join(
    tempfile.gettempdir(), "commander-network-fixture-state.json")


def now(delta_minutes=0):
    moment = datetime.now(timezone.utc) + timedelta(minutes=delta_minutes)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def key(seed):
    digest = hashlib.sha256(seed.encode()).digest()
    pin = "sha256/" + base64.b64encode(digest).decode()
    return pin, ":".join(f"{byte:02X}" for byte in digest)


def seed():
    return {"servers": [
        {"id": "s-fixture-home", "url": "https://ryan-mac.tail.internal", "name": "ryan-mac", "favorite": True,
         "autoConnect": True, "pin": key("ryan-mac")[0], "lastUsedAt": now(-5), "state": "online",
         "signedIn": True, "handle": "fixture-ryan", "lastSeen": now(), "error": ""},
        {"id": "s-fixture-team", "url": "https://relay.team.example", "name": "team-relay", "favorite": False,
         "autoConnect": True, "pin": key("team-relay")[0], "lastUsedAt": now(-180), "state": "certChanged",
         "signedIn": False, "handle": "", "lastSeen": now(-120), "error": ""},
    ]}


def load():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return seed()


def save(state):
    with open(STATE, "w") as handle:
        json.dump(state, handle)


HOME_STATUS = {
    "online": True, "signedIn": True, "handle": "fixture-ryan",
    "friends": [{"id": "f-1", "handle": "fixture-sam", "online": True},
                {"id": "f-2", "handle": "fixture-jonas", "online": True},
                {"id": "f-3", "handle": "fixture-mei", "online": False}],
    "incoming": [{"id": "in-1", "handle": "fixture-priya"}],
    "outgoing": [], "grants": [],
    "resources": [{"id": "res-1", "name": "relay", "kind": "repo", "actions": ["issue.read", "git.push"]}],
    "shared": [{"id": "sh-1", "name": "sam-agent", "kind": "agent", "owner": "fixture-sam", "actions": ["agent.ask"]}],
}


def summary(server):
    home = server["id"] == "s-fixture-home" and server["state"] == "online"
    return dict(server, friendsOnline=2 if home else 0, incoming=1 if home else 0)


def find(state, request):
    for server in state["servers"]:
        if server["id"] == request.get("server"):
            return server
    raise ValueError("No server with that ID.")


def presented(url):
    """The key a host presents now. team-relay presents a different key from its pinned one."""
    host = url.split("://")[-1].strip("/")
    return key(host + "/rotated" if "relay.team.example" in host else host)


def probe(request):
    url = (request.get("url") or "").strip()
    if not url:
        raise ValueError("Enter the server's address.")
    full = url if "://" in url else "https://" + url
    host = full.split("://")[-1].strip("/")
    pin, fingerprint = presented(full)
    trusted = "trusted" in host
    steps = [
        {"step": "dns", "ok": True, "detail": f"{host.split(':')[0]} resolves to 100.64.0.12"},
        {"step": "tcp", "ok": True, "detail": "100.64.0.12:443 in 4 ms"},
        {"step": "tls", "ok": True, "pin": pin, "fingerprint": fingerprint, "systemTrusted": trusted,
         "detail": "Trusted by the system" if trusted else "Issued by the relay's own CA. macOS does not already trust it, so you pin it."},
        {"step": "relay", "ok": True, "detail": "commander-relay 0.4.0 (fixture), compatible"},
    ]
    if "fail" in host:
        steps.append({"step": "signin", "ok": False, "clientId": "fixture.apps.example", "clientConfigured": False,
                      "detail": "The relay signs in with Google, but this Mac has no Desktop OAuth client file for this relay's client ID. Ask the admin for the file, add it, then check again."})
    else:
        steps.append({"step": "signin", "ok": True, "detail": "https://accounts.example", "clientId": "fixture.apps.example",
                      "clientConfigured": True})
    return {"url": full, "steps": steps}


def run(verb, request):
    state = load()
    if verb == "servers":
        ordered = sorted(state["servers"], key=lambda s: (not s["favorite"], s.get("lastUsedAt") or ""), reverse=False)
        favorites = sorted([s for s in ordered if s["favorite"]], key=lambda s: s.get("lastUsedAt") or "", reverse=True)
        others = sorted([s for s in ordered if not s["favorite"]], key=lambda s: s.get("lastUsedAt") or "", reverse=True)
        return {"servers": [summary(s) for s in favorites + others]}
    if verb == "server-probe":
        return probe(request)
    if verb == "server-add":
        checked = probe(request)
        host = checked["url"].split("://")[-1]
        server = {"id": "s-" + hashlib.sha256(checked["url"].encode()).hexdigest()[:8], "url": checked["url"],
                  "name": request.get("name") or host.split(":")[0].split(".")[0], "favorite": False,
                  "autoConnect": True, "pin": request.get("pin") or "", "lastUsedAt": now(), "state": "signedOut",
                  "signedIn": False, "handle": "", "lastSeen": "", "error": ""}
        if any(s["id"] == server["id"] for s in state["servers"]):
            raise ValueError("That server is already in your list.")
        state["servers"].append(server)
        save(state)
        return summary(server)
    if verb == "server-remove":
        find(state, request)
        state["servers"] = [s for s in state["servers"] if s["id"] != request.get("server")]
        save(state)
        return {}
    if verb in ("server-update", "server-trust", "login", "logout", "status"):
        server = find(state, request)
        if verb == "server-update":
            for field in ("name", "favorite", "autoConnect"):
                if field in request:
                    server[field] = request[field]
        elif verb == "server-trust":
            server.update(pin=request.get("pin") or "", state="signedOut")
        elif verb == "login":
            server.update(state="online", signedIn=True, handle="fixture-ryan", lastUsedAt=now(), lastSeen=now())
        elif verb == "logout":
            server.update(state="signedOut", signedIn=False, handle="")
        else:
            if server["id"] == "s-fixture-home" and server["state"] == "online":
                return HOME_STATUS
            online = server["state"] == "online"
            return {"online": online, "signedIn": server["signedIn"], "handle": server["handle"], "friends": [],
                    "incoming": [], "outgoing": [], "grants": [], "resources": [], "shared": []}
        save(state)
        return summary(server) if verb.startswith("server-") else {}
    if verb == "search":
        return {"handle": request.get("handle", "")}
    return {}


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "tray":
        print(json.dumps({"ok": False, "error": "usage: tray VERB"}))
        return 2
    try:
        request = json.loads(sys.stdin.read() or "{}")
        print(json.dumps({"ok": True, "data": run(sys.argv[2], request)}))
        return 0
    except ValueError as problem:
        print(json.dumps({"ok": False, "error": str(problem)}))
        return 0


if __name__ == "__main__":
    sys.exit(main())
