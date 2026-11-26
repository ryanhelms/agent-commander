#!/usr/bin/env python3
"""Review fixture for the Commander network tray (increments 1 and 2).

Stands in for `commander-network tray VERB` so the panel can be previewed without a relay:

    AGENT_COMMANDER_NETWORK_PANEL=1 \
    COMMANDER_NETWORK_BIN="$PWD/Tests/Fixtures/commander-network-fixture.py" \
    swift run AgentCommander          # debug builds only

It starts with three servers: ryan-mac (online, admin, with friends and one friend request),
studio-relay (online, not admin; fixture-sam is a friend on both, so the two rows are linked) and
team-relay (certificate changed). The feed has events on both online servers, three of them unseen.
Profile, presence, invite and membership changes are kept like the rest. To try a join link, open
`agentcommander://join?server=https%3A%2F%2Flab.example&pin=<pin>&code=fixture&from=fixture-sam`
with the pin the probe of lab.example shows; `join` then adds that server. Changes are kept in a scratch file so add, rename, favorite, trust, sign-in
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
        {"id": "s-fixture-studio", "url": "https://studio.example", "name": "studio-relay", "favorite": False,
         "autoConnect": True, "pin": "", "lastUsedAt": now(-60), "state": "online",
         "signedIn": True, "handle": "fixture-ryan", "lastSeen": now(), "error": ""},
        {"id": "s-fixture-team", "url": "https://relay.team.example", "name": "team-relay", "favorite": False,
         "autoConnect": True, "pin": key("team-relay")[0], "lastUsedAt": now(-180), "state": "certChanged",
         "signedIn": False, "handle": "", "lastSeen": now(-120), "error": ""},
    ], "presence": "auto", "seen": 2,
        "profiles": {"s-fixture-home": {"handle": "fixture-ryan", "displayName": "Ryan (fixture)",
                                        "statusMessage": "Shipping the relay", "avatar": AVATAR},
                     "s-fixture-studio": {"handle": "fixture-ryan", "displayName": "", "statusMessage": "", "avatar": ""}},
        "membership": {"mode": "allowlist",
                       "allowedEmails": ["sam@example.test", "jonas@example.test", "mei@example.test", "ryan@example.test"],
                       "admins": ["ryan@example.test"], "memberCount": 4},
        "invites": 0}


def load():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return seed()


# A 2 by 2 pixel PNG, so an avatar can be drawn.
AVATAR = ("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGOw2Pvjv9e9hv8MMAYA"
          "YSsLJ1I7NOIAAAAASUVORK5CYII=")
CONTACT_SAM = hashlib.sha256(b"sam@example.test").hexdigest()

FRIENDS = {
    "s-fixture-home": [("f-1", "fixture-sam", "busy", "2 agents running"), ("f-2", "fixture-jonas", "online", ""),
                       ("f-3", "fixture-mei", "away", ""), ("f-4", "fixture-noor", "offline", "")],
    "s-fixture-studio": [("g-1", "fixture-sam", "busy", "2 agents running"), ("g-2", "fixture-dev", "dnd", ""),
                         ("g-3", "fixture-priya", "online", "Reviewing")],
}


def events():
    rows = [
        ("s-fixture-home", 5, -1, "friend.request", "fixture-priya", "", ""),
        ("s-fixture-studio", 9, -10, "grant.received", "fixture-sam", "res-9", "Run tests on relay"),
        ("s-fixture-home", 4, -35, "friend.accepted", "fixture-jonas", "", ""),
        ("s-fixture-studio", 8, -160, "member.joined", "fixture-dev", "", ""),
        ("s-fixture-home", 3, -1500, "grant.revoked", "fixture-mei", "res-2", ""),
    ]
    return [{"server": server, "seq": seq, "at": now(minutes), "kind": kind, "actor": actor,
             "resource": resource, "detail": detail} for server, seq, minutes, kind, actor, resource, detail in rows]


def contacts(state):
    online = {s["id"] for s in state["servers"] if s["state"] == "online"}
    linked, single = [], []
    for server, friends in FRIENDS.items():
        if server not in online:
            continue
        for _, handle, presence, message in friends:
            row = {"server": server, "handle": handle, "presence": presence, "online": presence != "offline",
                   "statusMessage": message, "hasAvatar": handle == "fixture-sam"}
            if handle == "fixture-sam":
                linked.append(row)
            else:
                single.append({"contactKey": "", "displayName": "", "rows": [row]})
    head = [{"contactKey": CONTACT_SAM, "displayName": "Sam Rivera", "rows": linked}] if linked else []
    return {"contacts": head + single}


def effective(state):
    return "busy" if state.get("presence", "auto") == "auto" else state["presence"]


def save(state):
    with open(STATE, "w") as handle:
        json.dump(state, handle)


def status(state, server):
    profile = state.get("profiles", {}).get(server["id"], {})
    home = server["id"] == "s-fixture-home"
    return {
        "online": True, "signedIn": True, "handle": profile.get("handle") or server["handle"],
        "displayName": profile.get("displayName", ""), "statusMessage": profile.get("statusMessage", ""),
        "hasAvatar": bool(profile.get("avatar")),
        "friends": [{"id": ident, "handle": handle, "online": presence != "offline"}
                    for ident, handle, presence, _ in FRIENDS.get(server["id"], [])],
        "incoming": [{"id": "in-1", "handle": "fixture-priya"}] if home else [],
        "outgoing": [], "grants": [],
        "resources": [{"id": "res-1", "name": "relay", "kind": "repo", "actions": ["issue.read", "git.push"]}] if home else [],
        "shared": [{"id": "sh-1", "name": "sam-agent", "kind": "agent", "owner": "fixture-sam", "actions": ["agent.ask"]}],
    }


def summary(server, state=None):
    live = server["state"] == "online" and server["id"] in FRIENDS
    home = live and server["id"] == "s-fixture-home"
    friends = sum(1 for friend in FRIENDS.get(server["id"], []) if friend[2] != "offline") if live else 0
    unseen = 0
    if state is not None and live:
        unseen = sum(1 for event in events()[:max(len(events()) - state.get("seen", 0), 0)] if event["server"] == server["id"])
    extra = {"presence": effective(state)} if state is not None and live else {}
    return dict(server, friendsOnline=friends, incoming=1 if home else 0, unseen=unseen, **extra)


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
    result = {"url": full, "steps": steps}
    for server in load()["servers"]:
        if server["url"].split("://")[-1].strip("/") == host:
            result["existing"] = server["id"]
    return result


def run(verb, request):
    state = load()
    if verb == "servers":
        ordered = sorted(state["servers"], key=lambda s: (not s["favorite"], s.get("lastUsedAt") or ""), reverse=False)
        favorites = sorted([s for s in ordered if s["favorite"]], key=lambda s: s.get("lastUsedAt") or "", reverse=True)
        others = sorted([s for s in ordered if not s["favorite"]], key=lambda s: s.get("lastUsedAt") or "", reverse=True)
        return {"servers": [summary(s, state) for s in favorites + others]}
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
            if server["id"] in FRIENDS and server["state"] == "online":
                return status(state, server)
            online = server["state"] == "online"
            return {"online": online, "signedIn": server["signedIn"], "handle": server["handle"], "friends": [],
                    "incoming": [], "outgoing": [], "grants": [], "resources": [], "shared": []}
        save(state)
        return summary(server, state) if verb.startswith("server-") else {}
    if verb == "contacts":
        return contacts(state)
    if verb == "activity":
        feed = events()
        unseen = max(len(feed) - state.get("seen", 0), 0)
        after = request.get("after")
        return {"events": [] if after == "fixture-%d" % len(feed) else feed, "cursor": "fixture-%d" % len(feed),
                "unseen": unseen}
    if verb == "activity-seen":
        state["seen"] = len(events())
        save(state)
        return {}
    if verb == "join":
        link = request.get("link") or ""
        if not link.startswith("agentcommander://join?"):
            raise ValueError("That is not an invite link.")
        from urllib.parse import parse_qs, urlsplit
        fields = {name: values[0] for name, values in parse_qs(urlsplit(link).query).items()}
        url = fields.get("server", "")
        url = url if "://" in url else "https://" + url
        host = url.split("://")[-1]
        server = {"id": "s-" + hashlib.sha256(url.encode()).hexdigest()[:8], "url": url,
                  "name": host.split(":")[0].split(".")[0], "favorite": False, "autoConnect": True,
                  "pin": fields.get("pin", ""), "lastUsedAt": now(), "state": "connecting", "signedIn": False,
                  "handle": "", "lastSeen": "", "error": ""}
        if any(s["id"] == server["id"] for s in state["servers"]):
            raise ValueError("That server is already in your list.")
        state["servers"].append(server)
        save(state)
        return summary(server, state)
    if verb in ("profile", "presence", "avatar", "me", "membership", "membership-set", "invite-create"):
        server = find(state, request)
        admin = server["id"] == "s-fixture-home"
        profile = state.setdefault("profiles", {}).setdefault(
            server["id"], {"handle": server["handle"], "displayName": "", "statusMessage": "", "avatar": ""})
        if verb == "profile":
            avatar = request.get("avatar")
            if avatar and (len(avatar) > 64 * 1024 or not avatar.startswith(("data:image/png;base64,", "data:image/jpeg;base64,"))):
                raise ValueError("The avatar must be a PNG or JPEG of at most 64 KiB.")
            for field in ("handle", "displayName", "statusMessage", "avatar"):
                if field in request:
                    profile[field] = request[field]
            server["handle"] = profile["handle"]
            save(state)
            return {}
        if verb == "presence":
            state["presence"] = request.get("presence", "auto")
            save(state)
            return {"presence": effective(state), "auto": state["presence"] == "auto"}
        if verb == "avatar":
            own = request.get("handle") == profile["handle"]
            source = profile.get("avatar") if own else (AVATAR if request.get("handle") == "fixture-sam" else "")
            if not source:
                raise ValueError("No avatar.")
            head, data = source.split(",", 1)
            return {"contentType": head[5:].split(";")[0], "data": data}
        if verb == "me":
            return {"admin": admin, "mode": state["membership"]["mode"] if admin else "open"}
        if verb in ("membership", "membership-set"):
            if not admin:
                raise ValueError("Only an admin can see membership settings.")
            if verb == "membership-set":
                if not request.get("admins"):
                    raise ValueError("The relay keeps at least one admin.")
                state["membership"].update(mode=request.get("mode", "open"),
                                           allowedEmails=request.get("allowedEmails", []),
                                           admins=request.get("admins", []))
                save(state)
            return state["membership"]
        state["invites"] = state.get("invites", 0) + 1
        save(state)
        code = "fixture-invite-%d" % state["invites"]
        from urllib.parse import quote
        link = "agentcommander://join?server=%s&pin=%s&code=%s&from=%s" % (
            quote(server["url"], safe=""), quote(server["pin"], safe=""), code, quote(profile["handle"], safe=""))
        return {"link": link, "code": code, "expiresAt": now(60 * int(request.get("ttlHours", 168))),
                "maxUses": request.get("maxUses", 5), "uses": 0}
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
