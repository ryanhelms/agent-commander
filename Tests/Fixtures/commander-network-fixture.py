#!/usr/bin/env python3
"""Review fixture for the Commander network tray (increments 1 to 4).

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

Increment 3: ryan-mac starts with two approvals waiting (one Consult, one Hand off), an access request
from fixture-jonas, a shared directory where sam-agent is granted and jonas-ios and mei-docs are only
offered, two hand-offs you sent (one done with a report, a patch and a branch; one waiting on its
owner), threads, and an audit log. Consult answers at once; a prompt containing "wait" stays pending
and one containing "deny" is denied. Share, approve, deny, request access, withdraw, comment and
apply are all kept in the scratch file. Apply writes nothing: it only checks the folder exists.

Increment 4: relay-worker starts handed over to fixture-sam with about 24 minutes left, and a
suggestion from fixture-sam waits in approvals. sam-agent offers Watch, Suggest and Review; its
trace starts with a few lines and gains one on each `watch` call. "Live remote work" also has a
finished review (two findings; `review-post` checks the URL and posts nothing) and a fan-out to
sam-agent and mei-agent with both answers in. A suggestion stays pending unless its text contains
"approve"; a review whose title contains "wait" stays pending; a fan-out prompt containing "wait"
leaves its last worker pending. `sent` rows of a fan-out carry `children` here.

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
    ], "presence": "auto", "seen": 4,
        "profiles": {"s-fixture-home": {"handle": "fixture-ryan", "displayName": "Ryan (fixture)",
                                        "statusMessage": "Shipping the relay", "avatar": AVATAR},
                     "s-fixture-studio": {"handle": "fixture-ryan", "displayName": "", "statusMessage": "", "avatar": ""}},
        "membership": {"mode": "allowlist",
                       "allowedEmails": ["sam@example.test", "jonas@example.test", "mei@example.test", "ryan@example.test"],
                       "admins": ["ryan@example.test"], "memberCount": 4},
        "invites": 0,
        "resources": {"s-fixture-home": [
            {"id": "res-1", "name": "relay", "kind": "repo", "actions": REPO_ACTIONS},
            {"id": "res-2", "name": "relay-worker", "kind": "agent", "actions": AGENT_ACTIONS,
             "capabilities": {"harness": "claude", "model": "opus", "slots": 2, "tools": ["gh", "xcodebuild"],
                              "environments": ["ios-simulator"]}}]},
        "grants": {"s-fixture-home": [
            {"id": "g-1", "handle": "fixture-sam", "kind": "agent", "resource": "res-2", "capability": "agent.ask",
             "maxUses": 10, "expiresAt": now(60 * 20), "approval": "ask", "budgetTokens": 200000, "attribution": "owner"},
            {"id": "g-2", "handle": "fixture-sam", "kind": "agent", "resource": "res-2", "capability": "agent.handoff",
             "maxUses": 10, "expiresAt": now(60 * 20), "approval": "ask", "budgetTokens": 200000, "attribution": "owner"},
            {"id": "g-3", "handle": "fixture-sam", "kind": "agent", "resource": "res-2", "capability": "agent.suggest",
             "maxUses": 10, "expiresAt": now(60 * 20), "approval": "ask", "budgetTokens": 200000, "attribution": "owner"},
            {"id": "g-4", "handle": "fixture-jonas", "kind": "agent", "resource": "res-2", "capability": "agent.ask",
             "maxUses": 5, "expiresAt": now(60 * 20), "approval": "ask", "budgetTokens": 50000, "attribution": "owner"}]},
        "handovers": {"s-fixture-home": [{"user": "u-sam", "resource": "res-2", "until": now(24)}]},
        "approvals": {"s-fixture-home": [
            {"id": "ap-3", "peer": "fixture-sam", "resource": "res-2", "action": "agent.suggest",
             "summary": json.dumps({"text": "Pin the lease clock in the test instead of sleeping for the renewal."}),
             "arrived": now(-1), "expires": now(60 * 24 - 1)},
            {"id": "ap-1", "peer": "fixture-sam", "resource": "res-2", "action": "agent.ask",
             "summary": json.dumps({"text": "Why does the reconnect test flake on CI but pass locally?"}),
             "arrived": now(-3), "expires": now(60 * 24 - 3)},
            {"id": "ap-2", "peer": "fixture-sam", "resource": "res-2", "action": "agent.handoff",
             "summary": json.dumps({"title": "Run tests on relay", "task": "Run the relay test suite and report failures."}),
             "arrived": now(-14), "expires": now(60 * 24 - 14)}]},
        "access": {"s-fixture-home": [
            {"id": "ar-1", "resource": "res-1", "owner": "u-ryan", "ownerHandle": "fixture-ryan", "requester": "u-jonas",
             "requesterHandle": "fixture-jonas", "actions": ["issue.read", "issue.comment"],
             "note": "I want to triage the open relay issues this week.", "status": "pending", "createdAt": now(-50)},
            {"id": "ar-2", "resource": "dir-mei-docs", "owner": "u-mei", "ownerHandle": "fixture-mei", "requester": "u-ryan",
             "requesterHandle": "fixture-ryan", "actions": ["issue.read"], "note": "", "status": "pending",
             "createdAt": now(-600)}]},
        "sent": {"s-fixture-home": [
            {"request": "rq-fanout-1", "child": "", "resource": "dir-sam-agent", "action": "fanout:agent.ask",
             "title": "Where should the retry budget live?", "at": now(-21), "status": "ok",
             "value": {"text": FANOUT_ANSWERS["dir-sam-agent"]},
             "children": [{"id": "c-fan-1", "resource": "dir-sam-agent", "action": "agent.ask", "status": "ok",
                           "value": {"text": FANOUT_ANSWERS["dir-sam-agent"]}},
                          {"id": "c-fan-2", "resource": "dir-mei-agent", "action": "agent.ask", "status": "ok",
                           "value": {"text": FANOUT_ANSWERS["dir-mei-agent"]}}]},
            {"request": "rq-review-1", "child": "c-review-1", "resource": "dir-sam-agent", "action": "review.request",
             "title": "Wait for lease renewal before dropping the link", "at": now(-33), "status": "ok", "value": REVIEW},
            {"request": "rq-handoff-2", "child": "c-2", "resource": "dir-sam-agent", "action": "agent.handoff",
             "title": "Add a retry to the avatar upload", "at": now(-8), "status": "pending", "value": None},
            {"request": "rq-handoff-1", "child": "c-1", "resource": "dir-sam-agent", "action": "agent.handoff",
             "title": "Fix flaky reconnect test", "at": now(-95), "status": "ok",
             "value": {"run": "run-fixture-1", "worker": "w-fixture-1"}}]},
        "threads": {"rq-handoff-1": [
            {"id": "cm-1", "author": "fixture-ryan", "authorKind": "person", "at": now(-94),
             "text": "The flake shows up about one run in five on CI. Logs attached to the hand-off."},
            {"id": "cm-2", "author": "sam-agent", "authorKind": "agent", "at": now(-70),
             "text": "Reproduced. The test races the lease renewal. I am adding a wait on the renewal event."},
            {"id": "cm-3", "author": "fixture-sam", "authorKind": "person", "at": now(-40),
             "text": "Looks right to me. Take the patch when it lands."}]},
        "audit": [
            {"request": "rq-in-9", "peer": "fixture-sam", "resource": "res-2", "action": "agent.ask", "started": now(-200),
             "ended": now(-199), "outcome": "ok", "tokens": 18400, "summary": "Explained the lease renewal path."},
            {"request": "rq-in-8", "peer": "fixture-sam", "resource": "res-2", "action": "agent.handoff", "started": now(-1400),
             "ended": now(-1360), "outcome": "ok", "tokens": 96200, "summary": "Run run-fixture-0 finished with a patch."},
            {"request": "rq-in-7", "peer": "fixture-jonas", "resource": "res-1", "action": "git.push", "started": now(-2900),
             "ended": now(-2900), "outcome": "denied", "tokens": 0, "summary": "Denied by you."},
            {"request": "rq-in-6", "peer": "fixture-sam", "resource": "res-2", "action": "agent.ask", "started": now(-4300),
             "ended": now(-4300), "outcome": "budget_exhausted", "tokens": 0, "summary": ""}]}


def load():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return seed()


# A 2 by 2 pixel PNG, so an avatar can be drawn.
AVATAR = ("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGOw2Pvjv9e9hv8MMAYA"
          "YSsLJ1I7NOIAAAAASUVORK5CYII=")
REPO_ACTIONS = ["git.commit", "git.head", "git.push", "issue.close", "issue.comment", "issue.read"]
AGENT_ACTIONS = ["agent.ask", "agent.handoff", "agent.result", "agent.status", "agent.suggest", "agent.watch",
                 "review.request", "thread.comment", "thread.read"]
REVIEW = {"summary": "The wait fixes the race, but the test can now hang for the full default timeout when the renewal "
                     "never arrives. Bound the wait and assert on the timeout path.",
          "findings": [
              {"file": "Tests/ReconnectTests.swift", "line": 43, "severity": "important",
               "text": "relay.renewed() has no deadline. Pass a 2 second timeout so a lost renewal fails the test instead of hanging CI."},
              {"file": "Sources/Relay/Lease.swift", "line": 118, "severity": "important",
               "text": "renewed() resumes every waiter, including ones for an older lease. Key the continuation by lease ID."},
              {"file": "Tests/ReconnectTests.swift", "line": 12, "severity": "nit",
               "text": "The helper makeRelay() is now unused in this file."}]}
FANOUT_ANSWERS = {
    "dir-sam-agent": "Keep the budget in the client. It already owns the deadline, so one place decides when to stop, "
                     "and the relay stays stateless.",
    "dir-mei-agent": "Put it in the relay. Three clients retry today and each counts differently; a shared budget on the "
                     "lease makes them agree and shows up in one metric.",
}
TRACE = [
    (-190, "status", "Turn started"),
    (-171, "message", "Reading the reconnect test and the relay client before touching anything."),
    (-152, "tool", "rg -n \"renew\" Sources/Relay"),
    (-118, "tool", "swift test --filter ReconnectTests"),
    (-96, "message", "Reproduced: 1 of 5 runs fails. The link drops before the lease renewal lands."),
    (-61, "tool", "apply_patch Tests/ReconnectTests.swift"),
    (-40, "tool", "swift test --filter ReconnectTests  (40 runs)"),
    (-22, "message", "40 of 40 pass with the wait in place. Checking the timeout path next."),
    (-9, "tool", "rg -n \"timeout\" Tests/ReconnectTests.swift"),
    (-2, "message", "The wait has no deadline. Adding one so a lost renewal fails fast."),
    (0, "status", "Waiting for input"),
]
TRACE_START = 6
DIRECTORY = {
    "s-fixture-home": [
        {"id": "dir-sam-agent", "owner": "u-sam", "handle": "fixture-sam", "device": "d-sam", "kind": "agent",
         "name": "sam-agent", "actions": AGENT_ACTIONS, "grantedActions": AGENT_ACTIONS,
         "capabilities": {"harness": "codex", "model": "gpt-5.2-codex", "slots": 3, "tools": ["gh", "docker"],
                          "environments": ["gpu", "linux"]}},
        {"id": "dir-mei-agent", "owner": "u-mei", "handle": "fixture-mei", "device": "d-mei", "kind": "agent",
         "name": "mei-agent", "actions": AGENT_ACTIONS,
         "grantedActions": ["agent.ask", "agent.watch", "thread.comment", "thread.read"],
         "capabilities": {"harness": "claude", "model": "fable", "slots": 2, "tools": ["gh"], "environments": ["linux"]}},
        {"id": "dir-jonas-ios", "owner": "u-jonas", "handle": "fixture-jonas", "device": "d-jonas", "kind": "agent",
         "name": "jonas-ios", "actions": AGENT_ACTIONS, "grantedActions": [],
         "capabilities": {"harness": "claude", "model": "opus", "slots": 1, "tools": ["xcodebuild"],
                          "environments": ["ios-simulator"]}},
        {"id": "dir-mei-docs", "owner": "u-mei", "handle": "fixture-mei", "device": "d-mei", "kind": "repo",
         "name": "mei-docs", "actions": ["issue.comment", "issue.read"], "grantedActions": []}],
    "s-fixture-studio": [
        {"id": "sh-1", "owner": "u-sam", "handle": "fixture-sam", "device": "d-sam", "kind": "agent",
         "name": "sam-agent", "actions": AGENT_ACTIONS, "grantedActions": ["agent.ask", "thread.read", "thread.comment"]}],
}
REPORT = ("## sam-agent\n\nThe reconnect test raced the lease renewal. It now waits for the renewal event "
          "before it drops the link. 40 runs in a row pass.")
PATCH = ("--- a/Tests/ReconnectTests.swift\n+++ b/Tests/ReconnectTests.swift\n@@ -41,3 +41,4 @@\n"
         "     relay.drop()\n+    try await relay.renewed()\n     #expect(client.isOnline)\n")
CONTACT_SAM = hashlib.sha256(b"sam@example.test").hexdigest()

FRIENDS = {
    "s-fixture-home": [("f-1", "fixture-sam", "busy", "2 agents running"), ("f-2", "fixture-jonas", "online", ""),
                       ("f-3", "fixture-mei", "away", ""), ("f-4", "fixture-noor", "offline", "")],
    "s-fixture-studio": [("g-1", "fixture-sam", "busy", "2 agents running"), ("g-2", "fixture-dev", "dnd", ""),
                         ("g-3", "fixture-priya", "online", "Reviewing")],
}


def events():
    rows = [
        ("s-fixture-home", 7, -3, "approval.pending", "fixture-sam", "res-2", "agent.ask"),
        ("s-fixture-home", 6, -50, "access.requested", "fixture-jonas", "res-1", ""),
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
        "friends": [{"id": ident, "user": "u-" + handle.split("-", 1)[-1], "handle": handle, "online": presence != "offline"}
                    for ident, handle, presence, _ in FRIENDS.get(server["id"], [])],
        "incoming": [{"id": "in-1", "handle": "fixture-priya"}] if home else [],
        "outgoing": [], "grants": share(state, "grants").get(server["id"], []),
        "resources": share(state, "resources").get(server["id"], []),
        "shared": [{"id": row["id"], "name": row["name"], "kind": row["kind"], "owner": row["handle"],
                    "actions": row["grantedActions"], "capabilities": row.get("capabilities")}
                   for row in DIRECTORY.get(server["id"], []) if row["grantedActions"]],
        "directory": DIRECTORY.get(server["id"], []),
    }


def share(state, name):
    """One of the increment 3 tables, filled from the seed when an older scratch file lacks it."""
    if name not in state:
        state[name] = seed()[name]
    return state[name]


def answer(request):
    """What a friend's device sends back for one request."""
    action, payload = request.get("capability"), request.get("payload") or {}
    if action == "agent.ask":
        text = payload.get("text", "")
        if "wait" in text:
            return "pending", None
        if "deny" in text:
            return "denied", None
        files = len(payload.get("context") or [])
        return "ok", {"text": "Fixture answer. The worker read your prompt%s and would look at the lease renewal first: "
                              "the test drops the link before the renewal lands." % (" and %d file(s)" % files if files else "")}
    if action == "agent.handoff":
        return "ok", {"run": "run-fixture-%d" % (abs(hash(payload.get("title", ""))) % 900 + 100), "worker": "w-fixture"}
    if action == "agent.suggest":
        if "approve" in payload.get("text", ""):
            return "ok", {"text": "Fixture answer. The owner approved it and the worker took the suggestion."}
        return "pending", None
    if action == "review.request":
        return ("pending", None) if "wait" in payload.get("title", "") else ("ok", REVIEW)
    if action in ("agent.status", "agent.result"):
        done = payload.get("run") == "run-fixture-1"
        value = {"run": payload.get("run"), "state": "completed" if done else "running", "title": "Hand-off",
                 "summary": "40 runs in a row pass." if done else "Reading the test and the relay client.", "updatedAt": now()}
        if action == "agent.result":
            value["artifacts"] = [{"kind": "report", "name": "Result", "content": REPORT},
                                  {"kind": "patch", "name": "reconnect-wait.patch", "content": PATCH},
                                  {"kind": "branch", "name": "handoff/fix-flaky-reconnect"}] if done else []
        return "ok", value
    return "ok", {}


def seconds(delta):
    moment = datetime.now(timezone.utc) + timedelta(seconds=delta)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def live(state, verb, request):
    """Increment 4: watch, control hand-over, fan-out and posting a review."""
    server = find(state, request)["id"]
    if "handovers" not in state:
        # Kept at once, so the countdown runs down instead of starting again on each call.
        state["handovers"] = seed()["handovers"]
        save(state)
    held = state["handovers"].setdefault(server, [])
    held[:] = [row for row in held if row["until"] > now()]
    if verb == "handovers":
        return {"handovers": held}
    if verb in ("handover", "handback"):
        handle, resource = request.get("handle") or "", request.get("resource") or ""
        if not any(friend[1] == handle for friend in FRIENDS.get(server, [])):
            raise ValueError("unknown friend")
        user = "u-" + handle.split("-", 1)[-1]
        held[:] = [row for row in held if not (row["user"] == user and row["resource"] == resource)]
        if verb == "handback":
            save(state)
            return {}
        minutes = request.get("minutes") or 0
        if not resource or not 1 <= minutes <= 240:
            raise ValueError("handover needs a friend, a resource and 1–240 minutes")
        held.append({"user": user, "resource": resource, "until": now(minutes)})
        save(state)
        return {"handle": handle, "resource": resource, "until": now(minutes)}
    if verb == "watch":
        entry = [row for row in DIRECTORY.get(server, []) if row["id"] == request.get("resource")]
        if not entry or "agent.watch" not in entry[0]["grantedActions"]:
            return {"id": "c-watch", "resource": request.get("resource"), "action": "agent.watch", "status": "denied"}
        after = request.get("after") or ""
        start = int(after) if after.isdigit() else 0
        end = TRACE_START if start == 0 else min(start + 1, len(TRACE))
        # A line read live is stamped now; the first page keeps its history.
        rows = [{"at": seconds(delta if start == 0 else 0), "kind": kind, "text": text} for delta, kind, text in TRACE[start:end]]
        return {"id": "c-watch", "resource": request.get("resource"), "action": "agent.watch", "status": "ok",
                "value": {"events": rows, "cursor": str(end), "state": "awaiting_input" if end == len(TRACE) else "running"}}
    if verb == "fanout":
        targets, payload = request.get("targets") or [], request.get("payload")
        if not 2 <= len(targets) <= 32 or not isinstance(payload, dict):
            raise ValueError("fan-out needs 2–32 targets and a JSON payload")
        ident = "rq-%s" % hashlib.sha256(json.dumps(request, sort_keys=True).encode() + now().encode()).hexdigest()[:10]
        children = []
        for index, target in enumerate(targets):
            waits = "wait" in payload.get("text", "") and index == len(targets) - 1
            text = FANOUT_ANSWERS.get(target.get("resource"), "Fixture answer from %s." % target.get("resource"))
            children.append({"id": "c-%s-%d" % (ident[3:], index), "resource": target.get("resource"),
                             "action": target.get("action"), "status": "pending" if waits else "ok",
                             "value": None if waits else {"text": text}})
        share(state, "sent").setdefault(server, []).insert(0, {
            "request": ident, "child": "", "resource": targets[0].get("resource"), "action": "fanout:" + (targets[0].get("action") or ""),
            "title": request.get("name") or "Fan-out", "at": now(), "status": children[0]["status"],
            "value": children[0]["value"], "children": children})
        save(state)
        # The device agent answers with the submission: its children carry `result`, not `value`.
        return {"request": ident, "children": {"id": ident, "children": [
            dict({key: child[key] for key in ("id", "resource", "action", "status")},
                 **({"result": child["value"]} if child["value"] else {})) for child in children]}}
    if verb == "review-post":
        if not (request.get("pr") or "").startswith("https://"):
            raise ValueError("name the pull request URL")
        rows = [row for row in share(state, "sent").get(server, []) if row["request"] == request.get("request")]
        if not rows or not (rows[0].get("value") or {}).get("summary"):
            raise ValueError("that request has no review result yet")
        return {"posted": request["pr"]}
    raise ValueError("unknown tray operation")


def sharing(state, verb, request):
    server = find(state, request)["id"]
    if verb == "approvals":
        return {"approvals": share(state, "approvals").get(server, [])}
    if verb in ("approve", "deny"):
        rows = share(state, "approvals").setdefault(server, [])
        hit = [row for row in rows if row["id"] == request.get("id")]
        if not hit:
            raise ValueError("That request is no longer waiting.")
        rows.remove(hit[0])
        share(state, "audit").insert(0, {"request": hit[0]["id"], "peer": hit[0]["peer"], "resource": hit[0]["resource"],
                                         "action": hit[0]["action"], "started": now(), "ended": now(),
                                         "outcome": "ok" if verb == "approve" else "denied",
                                         "tokens": 12300 if verb == "approve" else 0,
                                         "summary": "Approved by you." if verb == "approve" else "Denied by you."})
        save(state)
        return {}
    if verb == "audit":
        rows = [row for row in share(state, "audit")
                if (not request.get("resource") or row["resource"] == request["resource"])
                and (not request.get("handle") or row["peer"] == request["handle"])]
        return {"entries": rows[:200]}
    if verb == "resource-add":
        rows = share(state, "resources").setdefault(server, [])
        if not any(row["id"] == request.get("id") for row in rows):
            kind = request.get("kind")
            rows.append({"id": request.get("id"), "name": request.get("name"), "kind": kind,
                         "actions": AGENT_ACTIONS if kind == "agent" else REPO_ACTIONS})
        save(state)
        return {"id": request.get("id")}
    if verb == "grant":
        if request.get("approval") not in ("", None, "ask", "auto"):
            raise ValueError("approval must be ask or auto")
        own = [row for row in share(state, "resources").get(server, []) if row["id"] == request.get("resource")]
        if not own or request.get("capability") not in own[0]["actions"]:
            raise ValueError("unsupported local resource or capability")
        rows = share(state, "grants").setdefault(server, [])
        ident = "g-%s-%s-%s" % (request["resource"], request.get("handle"), request["capability"])
        rows[:] = [row for row in rows if row["id"] != ident]
        rows.append({"id": ident, "handle": request.get("handle"), "kind": own[0]["kind"], "resource": request["resource"],
                     "capability": request["capability"], "maxUses": request.get("maxUses", 100),
                     "expiresAt": request.get("expiresAt") or now(60 * 24), "approval": request.get("approval", "ask"),
                     "budgetTokens": request.get("budgetTokens", 0), "attribution": request.get("attribution", "owner")})
        for row in share(state, "access").get(server, []):
            if row["resource"] == request["resource"] and row["requesterHandle"] == request.get("handle"):
                row["status"] = "granted"
        save(state)
        return {}
    if verb == "revoke":
        rows = share(state, "grants").setdefault(server, [])
        rows[:] = [row for row in rows if row["id"] != request.get("id")]
        save(state)
        return {}
    if verb == "send":
        if not request.get("resource") or not request.get("capability") or not isinstance(request.get("payload"), dict):
            raise ValueError("send needs a resource, capability and JSON payload")
        status, value = answer(request)
        ident = "rq-%s" % hashlib.sha256(json.dumps(request, sort_keys=True).encode() + now().encode()).hexdigest()[:10]
        row = {"request": ident, "child": "c-" + ident[3:], "resource": request["resource"], "action": request["capability"],
               "title": request.get("name") or request["capability"], "at": now(), "status": status, "value": value}
        share(state, "sent").setdefault(server, []).insert(0, row)
        save(state)
        return {"request": ident, "id": row["child"], "status": status, "value": value}
    if verb in ("sent", "handoffs"):
        rows = [row for row in share(state, "sent").get(server, []) if verb == "sent" or row["action"] == "agent.handoff"]
        return {verb: rows[:50]}
    if verb in ("thread", "comment"):
        rows = share(state, "threads").setdefault(request.get("request") or "", [])
        if verb == "comment":
            if not (request.get("text") or "").strip():
                raise ValueError("Write a comment first.")
            rows.append({"id": "cm-%d" % (len(rows) + 10), "author": "fixture-ryan", "authorKind": "person", "at": now(),
                         "text": request["text"]})
            save(state)
        return {"request": request.get("request"), "comments": rows}
    if verb == "apply-artifact":
        if not os.path.isdir(request.get("checkout") or ""):
            raise ValueError("name the absolute path of a local checkout")
        if request.get("artifact") not in (0, 1):
            raise ValueError("this artifact kind is not applied automatically; fetch the branch from the owner's repository")
        return {"applied": "fixture"}
    if verb == "relay":
        path, method = request.get("path") or "", (request.get("method") or "").upper()
        if not path.startswith("/v1/access-requests"):
            raise ValueError("that relay route is not available to the tray")
        rows = share(state, "access").setdefault(server, [])
        if method == "GET":
            return {"requests": rows}
        if method == "POST":
            body = request.get("body") or {}
            entry = [row for row in DIRECTORY.get(server, []) if row["id"] == body.get("resource")]
            if not entry or not body.get("actions"):
                raise ValueError("provide a resource and 1-32 distinct actions")
            ident = "ar-%d" % (len(rows) + 10)
            rows.insert(0, {"id": ident, "resource": entry[0]["id"], "owner": entry[0]["owner"],
                            "ownerHandle": entry[0]["handle"], "requester": "u-ryan", "requesterHandle": "fixture-ryan",
                            "actions": sorted(body["actions"]), "note": body.get("note", ""), "status": "pending",
                            "createdAt": now()})
            save(state)
            return {"id": ident}
        if method == "DELETE":
            ident = path.rsplit("/", 1)[-1]
            if not any(row["id"] == ident and row["status"] == "pending" for row in rows):
                raise ValueError("not found")
            rows[:] = [row for row in rows if row["id"] != ident]
            save(state)
            return {}
    raise ValueError("unknown tray operation")



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
    if verb in ("approvals", "approve", "deny", "audit", "resource-add", "grant", "revoke", "send", "sent", "handoffs",
                "thread", "comment", "apply-artifact", "relay"):
        return sharing(state, verb, request)
    if verb in ("watch", "handover", "handback", "handovers", "fanout", "review-post"):
        return live(state, verb, request)
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
