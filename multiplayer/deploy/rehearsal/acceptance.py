#!/usr/bin/env python3
"""Exercise live tray and coordinator contracts on a fresh, isolated Compose project."""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


LAB = Path(__file__).with_name("lab.py")
USERS = {"alice": "peer-a", "bob": "peer-b", "carol": "peer-c"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def passed(message):
    print(f"PASS  {message}", flush=True)


class Rehearsal:
    def __init__(self, run):
        self.compose = [sys.executable, str(LAB), "compose", str(run)]
        self.expiry = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()

    def exec(self, *args, input=None, check=True):
        return subprocess.run(self.compose + list(args), input=input, text=True,
                              capture_output=True, check=check, timeout=90)

    def peer(self, who, *args, **kwargs):
        return self.exec("exec", "-T", USERS[who], "pilot-peer", *args, **kwargs)

    def facts(self, who):
        return json.loads(self.peer(who, "facts").stdout)

    def call(self, who, path, body=None, *, deny=False, other=False):
        proc = self.peer(who, "call-other" if other else "call", path,
                         input=json.dumps(body or {}), check=False)
        try:
            reply = json.loads(proc.stdout)
        except ValueError:
            raise RuntimeError(f"{who} {path}: no API response (exit {proc.returncode}): {proc.stderr.strip()}") from None
        if deny:
            require(reply.get("ok") is False and reply.get("error"), f"{who} {path}: expected refusal")
            return reply["error"]
        require(proc.returncode == 0 and reply.get("ok") is True,
                f"{who} {path}: {reply.get('error', 'unexpected peer response')}")
        return reply["data"]

    def online(self, who):
        deadline = time.monotonic() + 90
        state = {}
        while time.monotonic() < deadline:
            state = self.call(who, "/tray/status")
            if state["online"] and state["signedIn"] and state["handle"] == who:
                return state
            if state.get("error") and not state.get("loginPending") and not state["signedIn"]:
                raise RuntimeError(f"{who} login failed: {state['error']}")
            time.sleep(0.5)
        raise RuntimeError(f"{who} did not go online: {state.get('error', '')}")

    def friend(self, who, peer):
        self.call(who, "/tray/request", {"handle": peer})
        self.call(who, "/tray/accept", {"handle": peer}, deny=True)
        pending = self.call(peer, "/tray/status")["incoming"]
        require(any(row["handle"] == who and not row["online"] for row in pending),
                f"{peer} did not see an incoming request from {who} with private presence")
        self.call(peer, "/tray/accept", {"handle": who})
        for a, b in ((who, peer), (peer, who)):
            friends = self.call(a, "/tray/status")["friends"]
            require(any(row["handle"] == b and row["online"] for row in friends),
                    f"{a} did not see online friend {b}")

    def grant(self, owner, guest, resource, action, limit=6, **kwargs):
        return self.call(owner, "/tray/grant", {"handle": guest, "resource": resource,
                         "capability": action, "expiresAt": self.expiry, "maxUses": limit}, **kwargs)

    def queue(self, who, submission, targets, **kwargs):
        return self.call(who, "/coordinator/submit", {"id": submission, "targets": targets}, **kwargs)

    def receipts(self, who, submission, targets, outcome="completed"):
        expected = {(target["resource"], target["action"]) for target in targets}
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            batch = self.call(who, "/coordinator/receipt", {"id": submission})
            rows = batch["children"]
            require(batch["id"] == submission and len(rows) == len(targets) and
                    {(row["resource"], row["action"]) for row in rows} == expected,
                    f"{submission}: receipt addressed to unexpected resources")
            for row in rows:
                require(row["status"] in ("pending", "processing", outcome),
                        f"{submission}: {row['resource']} returned {row['status']}: {row.get('result')}")
            if all(row["status"] == outcome for row in rows):
                require(len({row["id"] for row in rows}) == len(targets) and
                        all(isinstance(row.get("result"), dict) for row in rows) and
                        (outcome != "completed" or all(row["result"].get("status") == "completed" for row in rows)),
                        f"{submission}: missing distinct authenticated results")
                return {row["resource"]: row for row in rows}
            time.sleep(0.4)
        raise RuntimeError(f"{submission}: timed out waiting for receipts")

    def execute(self, who, submission, resource, action, payload):
        targets = [target(resource, action, payload)]
        self.queue(who, submission, targets)
        return self.receipts(who, submission, targets)[resource]["result"]

    def message(self, sender, recipient, submission, text):
        resource = recipient + "-inbox"
        reply = self.execute(sender, submission, resource, "agent.message", {"text": text})
        messages = self.call(recipient, "/coordinator/inbox")["messages"]
        require(any(row["id"] == reply["messageId"] and row["text"] == text and
                    row["resource"] == resource and row["peer"] for row in messages),
                f"{recipient} did not receive the addressed message")


def target(resource, action, payload):
    return {"resource": resource, "action": action, "payload": payload}


def verify(run):
    lab = Rehearsal(run)
    info = {}
    for who in USERS:
        info[who] = json.loads(lab.peer(who, "info").stdout)
        require(info[who]["handle"] == who, "container identity mismatch")
        state = lab.call(who, "/tray/status")
        require(not state["signedIn"], "acceptance requires a fresh run directory")
        lab.call(who, "/tray/login", {"handle": who})
    for who in USERS:
        lab.online(who)
    passed("Three independent devices signed in through OIDC and came online")

    for who in USERS:
        for suffix, kind, field in (("agent", "agent", "worker"), ("inbox", "agent", "coordinator")):
            lab.call(who, "/tray/resource-add", {"id": f"{who}-{suffix}", "kind": kind,
                     "name": f"{who} {suffix}", "target": info[who][field]})
    repo = "bob-repo"
    lab.call("bob", "/tray/resource-add", {"id": repo, "kind": "repo", "name": "Pilot repository",
                                          "target": info["bob"]["checkout"]})
    lab.call("bob", "/tray/repo-credential", {"resource": repo})
    private_catalog = lab.call("alice", "/coordinator/discover")
    require(not private_catalog["resources"] and not private_catalog["actionContracts"],
            "discovery exposed an unshared resource or action contract")
    found = lab.call("alice", "/tray/search", {"handle": "bob"})
    require(found["handle"] == "bob" and not found["online"], "stranger could see online status")
    lab.grant("bob", "alice", repo, "issue.read", deny=True)
    lab.friend("alice", "bob")
    lab.friend("alice", "carol")
    require(not lab.call("alice", "/coordinator/discover")["resources"], "friendship alone exposed a resource")
    passed("Exact-handle discovery, private presence and recipient-only friendship acceptance")

    ask_alice = target("alice-agent", "agent.ask", {"text": "Please review issue one."})
    lab.grant("bob", "alice", "bob-agent", "agent.ask")
    lab.grant("carol", "alice", "carol-agent", "agent.ask")
    lab.queue("bob", "before-reverse", [ask_alice], deny=True)
    lab.grant("alice", "bob", "alice-agent", "agent.ask")
    answers = [target(f"{who}-agent", "agent.ask", {"text": f"{who}, review issue one."})
               for who in ("bob", "carol")]
    lab.queue("alice", "team-review", answers)
    results = lab.receipts("alice", "team-review", answers)
    for who in ("bob", "carol"):
        require(who in results[f"{who}-agent"]["result"]["text"], "worker reply mixed between recipients")
    lab.queue("alice", "team-review", answers)
    require(lab.receipts("alice", "team-review", answers) == results, "replay changed a signed receipt")
    mcp = json.loads(lab.peer("alice", "mcp", "team-review").stdout)
    wanted_tools = {"commander_network_" + op for op in ("discover", "submit", "receipt", "inbox")}
    require(wanted_tools.issubset(mcp["tools"]), "managed coordinator MCP tools were unavailable")
    available = {resource["id"] for resource in mcp["discover"]["resources"]}
    require(set(results).issubset(available), "stdio MCP discovery missed a granted resource")
    require(set(mcp["discover"]["actionContracts"]) == {"agent.ask"},
            "the same action granted on two worker resources must have a single contract")
    receipt = mcp["receipt"]
    require(receipt["id"] == "team-review" and {row["resource"]: row for row in receipt["children"]} == results,
            "stdio MCP did not return the signed per-recipient results")
    for who in ("bob", "carol"):
        require(lab.facts(who)["worker_turns"] == 1, f"{who} ran a duplicate turn")
    lab.queue("alice", "team-review", [answers[0]], deny=True)
    lab.call("alice", "/coordinator/receipt", {"id": "team-review"}, other=True, deny=True)
    lab.queue("bob", "reverse", [ask_alice])
    reverse = lab.receipts("bob", "reverse", [ask_alice])
    require("alice" in reverse["alice-agent"]["result"]["text"], "reverse worker did not answer")
    passed("One coordinator addressed two remote users, retried idempotently and received distinct replies")

    for owner, guest in (("alice", "bob"), ("bob", "alice")):
        lab.grant(owner, guest, owner + "-inbox", "agent.message")
    lab.message("alice", "bob", "start-change", "Please review issue one and the shared branch.")
    lab.message("bob", "alice", "approve-change", "I reviewed issue one. The branch is ready.")
    passed("Both coordinators exchanged addressed messages under independent grants")

    caps = ["issue.read", "git.head", "git.commit", "git.push", "issue.comment", "issue.close"]
    for cap in caps:
        lab.grant("bob", "alice", repo, cap, limit=1 if cap == "git.head" else 4)
    resources = lab.call("alice", "/coordinator/discover")["resources"]
    row = next(r for r in resources if r["id"] == repo)
    require(row["handle"] == "bob" and set(row["actions"]) == set(caps), "incorrect repository grant")
    require(not any(r["id"] == repo for r in lab.call("carol", "/coordinator/discover")["resources"]),
            "repository leaked to another group recipient")
    contracts = json.loads(lab.peer("alice", "mcp").stdout)["discover"]["actionContracts"]
    required_fields = {"agent.ask": ["text"], "agent.message": ["text"], "git.head": [],
                       "git.commit": ["expectedHead", "message", "files"], "git.push": ["expectedHead"],
                       "issue.read": [], "issue.comment": ["number", "body"], "issue.close": ["number"]}
    require(set(contracts) == set(required_fields), "MCP returned a missing or ungranted action contract")
    for action, fields in required_fields.items():
        contract = contracts[action]
        schema = contract["payloadSchema"]
        require(contract["description"] and schema["type"] == "object" and not schema["additionalProperties"] and
                set(schema.get("required", [])) == set(fields), f"incorrect MCP payload contract for {action}")
    issue = lab.execute("alice", "read-issue", repo, "issue.read", {"number": 1})["issue"]
    require(issue["number"] == 1 and issue["state"] == "open", "issue did not start open")
    head = lab.execute("alice", "read-head", repo, "git.head", {})
    require(head["head"] == info["bob"]["head"] and head["branch"] == "commander-share/" + repo,
            "unexpected shared branch or starting commit")
    lab.queue("alice", "out-of-head-uses", [target(repo, "git.head", {})], deny=True)
    content = "Reviewed by the invited coordinators.\n"
    payload = {"expectedHead": head["head"], "message": "Record review for issue #1", "files": {"review.txt": content}}
    require(set(payload) == set(contracts["git.commit"]["payloadSchema"]["required"]), "commit payload missed the schema")
    commit = [target(repo, "git.commit", payload)]
    accepted = json.loads(lab.peer("alice", "mcp-submit", input=json.dumps({"id": "commit", "targets": commit})).stdout)
    require(accepted["submission"]["id"] == "commit", "MCP did not submit the repository command")
    revision = lab.receipts("alice", "commit", commit)[repo]["result"]["head"]
    require(revision != head["head"], "commit did not move the collaboration branch")
    stale = [target(repo, "git.commit", {"expectedHead": head["head"], "message": "Stale edit",
                                          "files": {"review.txt": "This must not be committed."}})]
    lab.queue("alice", "stale-commit", stale)
    rejected = lab.receipts("alice", "stale-commit", stale, "declined")[repo]
    require(rejected["result"] == {"code": "stale_revision"} and
            lab.queue("alice", "stale-commit", stale)["children"][0] == rejected,
            "stale edit did not return the same signed recovery code")
    stale_mcp = json.loads(lab.peer("alice", "mcp", "stale-commit").stdout)["receipt"]
    require(stale_mcp["children"] == [rejected], "the coordinator did not see the signed revision failure through MCP")
    lab.grant("bob", "alice", repo, "git.head", limit=2)
    current = lab.execute("alice", "recover-head", repo, "git.head", {})["head"]
    require(current == revision, "stale edit changed the branch or the current revision could not be recovered")
    push = lab.execute("alice", "push", repo, "git.push", {"expectedHead": current})
    require(push["head"] == revision, "push returned another revision")
    verified = lab.peer("bob", "published", repo).stdout.strip()
    require(verified == revision, f"published ref differs from pushed commit: {verified}")
    content_at_commit = lab.exec("exec", "-T", "peer-b", "git", "-C", info["bob"]["checkout"], "show",
                                 revision + ":review.txt").stdout
    checkout_head = lab.exec("exec", "-T", "peer-b", "git", "-C", info["bob"]["checkout"],
                             "rev-parse", "HEAD").stdout.strip()
    require(content_at_commit == content and checkout_head == head["head"], "wrong content or active branch changed")
    comment = {"number": 1, "body": f"Reviewed the collaboration commit {revision}."}
    first = lab.execute("alice", "comment", repo, "issue.comment", comment)
    require(first["commentId"] > 0 and lab.execute("alice", "comment", repo, "issue.comment", comment) == first,
            "duplicate comment receipt changed")
    closed = lab.execute("alice", "close-issue", repo, "issue.close", {"number": 1})
    require(closed["state"] == "closed", "issue close did not complete")
    confirmed = lab.execute("alice", "verify-issue", repo, "issue.read", {"number": 1})["issue"]
    require(confirmed["state"] == "closed", "issue did not remain closed at the provider")
    facts = lab.facts("bob")
    require(facts["comments"] == 1 and facts["issue_state"] == "closed", "provider writes were missing or repeated")
    passed(f"Issue #1 was read, a commit was pushed and verified ({revision[:12]}), then the issue was commented and closed")

    lab.friend("bob", "carol")
    lab.grant("bob", "carol", repo, "git.head", limit=2)
    require(lab.execute("carol", "independent-review", repo, "git.head", {})["head"] == revision,
            "second collaborator could not read the shared revision")
    lab.queue("carol", "read-only", [target(repo, "git.push", {"expectedHead": revision})], deny=True)
    carol_catalog = json.loads(lab.peer("carol", "mcp").stdout)["discover"]
    require(set(carol_catalog["actionContracts"]) == {"git.head"}, "MCP exposed a write contract to a read-only collaborator")
    passed("Coordinator MCP discovered eight granted schemas, submitted a commit, and showed a read-only peer only git.head")

    # A peer process goes away entirely while another recipient stays available.
    held = [target("bob-inbox", "agent.message", {"text": "Check the revision after reconnect."})]
    lab.grant("bob", "alice", repo, "issue.comment", limit=2)  # One comment already spent.
    last_comment = [target(repo, "issue.comment", {"number": 1, "body": "Queue caught up after reconnect."})]
    over_budget = [target(repo, "issue.comment", {"number": 1, "body": "This must not reach GitHub."})]
    lab.exec("stop", "peer-b")
    try:
        lab.queue("alice", "offline-message", held)
        queued = lab.call("alice", "/coordinator/receipt", {"id": "offline-message"})
        require(queued["children"][0]["status"] == "pending", "offline work did not stay pending")
        for identity, targets in (("last-comment", last_comment), ("over-budget-comment", over_budget)):
            queued = lab.queue("alice", identity, targets)
            require(queued["children"][0]["status"] == "pending", "comment was not queued while its owner was offline")
        other = lab.execute("alice", "still-online", "carol-agent", "agent.ask", {"text": "Confirm availability."})
        require("carol" in other["text"], "second recipient was interrupted")
    finally:
        lab.exec("start", "peer-b")
    lab.online("bob")
    resumed = lab.receipts("alice", "offline-message", held)["bob-inbox"]["result"]["messageId"]
    inbox = lab.call("bob", "/coordinator/inbox")["messages"]
    require(sum(r["id"] == resumed for r in inbox) == 1, "offline message was lost or duplicated")
    passed("An offline peer received queued work after restart while another recipient kept working")
    comment = lab.receipts("alice", "last-comment", last_comment)[repo]["result"]
    refused = lab.call("alice", "/coordinator/receipt", {"id": "over-budget-comment"})["children"][0]
    require(comment["commentId"] > 0 and refused["status"] == "denied" and "result" not in refused and
            lab.facts("bob")["comments"] == 2, "one remaining use caused more than one GitHub write")
    lab.grant("bob", "alice", repo, "issue.comment", limit=3)
    require(lab.queue("alice", "over-budget-comment", over_budget)["children"][0] == refused,
            "renewing the grant revived the denied write")
    passed("Two queued comments competed for one remaining use. GitHub received one write and the denial survived renewal")

    ambiguous = [target(repo, "issue.comment", {"number": 1, "body": "Saved before the fixture returned an error."})]
    lab.queue("alice", "ambiguous-comment", ambiguous)
    unknown = lab.receipts("alice", "ambiguous-comment", ambiguous, "uncertain")[repo]
    require(unknown["result"] == {"code": "outcome_uncertain"} and
            lab.queue("alice", "ambiguous-comment", ambiguous)["children"][0] == unknown and
            lab.facts("bob")["comments"] == 3,
            "an ambiguous write leaked provider details, changed the receipt or posted a duplicate comment")
    unknown_mcp = json.loads(lab.peer("alice", "mcp", "ambiguous-comment").stdout)["receipt"]
    require(unknown_mcp["children"] == [unknown], "the coordinator did not see the signed uncertain receipt through MCP")
    passed("A stale revision returned a signed recovery code, and retrying an uncertain comment never posted a duplicate")

    grants = lab.call("bob", "/tray/status")["grants"]
    grant = next(g for g in grants if g["resource"] == "bob-agent" and g["capability"] == "agent.ask")
    lab.call("bob", "/tray/revoke", {"id": grant["id"]})
    lab.queue("alice", "after-revoke", [answers[0]], deny=True)
    require(lab.execute("alice", "retained-access", repo, "issue.read", {"number": 1})["issue"]["state"] == "closed",
            "revoking worker access removed independent repository access")
    lab.call("alice", "/tray/unfriend", {"handle": "bob"})
    lab.friend("bob", "alice")
    require(all(r["handle"] != "bob" for r in lab.call("alice", "/coordinator/discover")["resources"]),
            "previous grants returned after re-friending")
    lab.grant("bob", "alice", repo, "git.head", limit=1)
    catalog = lab.call("alice", "/coordinator/discover")
    scoped = [r for r in catalog["resources"] if r["handle"] == "bob"]
    require(len(scoped) == 1 and scoped[0]["actions"] == ["git.head"] and
            set(catalog["actionContracts"]) == {"agent.ask", "git.head"}, "renewed grant restored other actions or schemas")
    lab.call("bob", "/tray/logout")
    view = lab.call("alice", "/tray/search", {"handle": "bob"})
    require(not view["online"], "signed-out peer still appears online")
    passed("Revocation, independent action limits, fresh consent after re-friending and sign-out")

    # Inspect only counts and envelope structure on the relay. The relay has no
    # participant private key with which to read the request or response.
    counts = lab.exec("exec", "-T", "postgres", "sh", "-ec",
                      'export PGPASSWORD="$(cat /run/db/admin-password)"; exec psql "$@"',
                      "rehearsal-audit", "-XAt", "-U", "postgres", "-d", "commander",
                      "-c", """SELECT count(*), count(*) FILTER (WHERE status='completed'),
                          count(*) FILTER (WHERE status IN ('declined','uncertain')),
                          count(*) FILTER (WHERE status IN ('completed','declined','uncertain')
                          AND jsonb_typeof(result)='string' AND cardinality(string_to_array(result #>> '{}','.'))=5),
                          count(*) FILTER (WHERE status='denied' AND result IS NULL),
                          count(*) FILTER (WHERE jsonb_typeof(envelope)='string'
                          AND cardinality(string_to_array(envelope #>> '{}','.'))=5) FROM mp_children""").stdout.strip().split("|")
    total, completed, failures, sealed_results, denied, sealed = map(int, counts)
    require(total == completed + failures + denied == sealed and sealed_results == completed + failures and
            completed >= 12 and failures == 2 and denied == 1,
            "relay contained an unexpected request or result format")
    passed(f"The relay stored {total} encrypted requests, {sealed_results} encrypted results and one denial without a result")


def fresh_rehearsal():
    parent = Path(tempfile.mkdtemp(prefix="commander-rehearsal-"))
    run = parent / "run"
    lab = [sys.executable, str(LAB)]
    try:
        subprocess.run(lab + ["up", str(run)], check=True)
        subprocess.run(lab + ["verify", str(run)], check=True)
        verify(run)
    finally:
        if run.exists():
            subprocess.run(lab + ["down", str(run)], check=True)
        if not any(parent.iterdir()):
            parent.rmdir()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", nargs="?", type=Path, help="use an existing fresh lab instead of creating one")
    args = parser.parse_args()
    try:
        if args.run is None:
            fresh_rehearsal()
        else:
            verify(args.run)
    except (RuntimeError, subprocess.SubprocessError, KeyError, StopIteration, ValueError) as exc:
        print(f"FAIL  {exc}", file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)
