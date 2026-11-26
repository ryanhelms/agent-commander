package control

import (
	"net/http/httptest"
	"testing"
)

func TestWorkspaceCombinedEditLeaveAndRefusedHolder(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	call := func(user, method, path string, in any, status int) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, user, user+"-device", method, path, in, status)
	}
	for _, user := range []string{"alice", "bob", "cara"} {
		call(user, "PUT", "/v1/profile", map[string]string{"handle": user}, 200)
		lease := shareResponse[Lease](t, call(user, "POST", "/v1/session", nil, 200))
		call(user, "PUT", "/v1/session", leaseProof{lease.Session, lease.Generation}, 200)
	}
	call("alice", "POST", "/v1/friends/bob", nil, 200)
	call("bob", "PUT", "/v1/friends/alice", nil, 200)
	group := shareResponse[struct{ ID string }](t, call("alice", "POST", "/v1/groups", map[string]string{"name": "Crew"}, 200)).ID
	member := "/v1/groups/" + group + "/members/bob"
	call("alice", "PUT", member, nil, 200)
	w := shareResponse[workspace](t, call("alice", "POST", "/v1/workspaces", map[string]string{"name": "Relay", "goal": "Ship", "repository": "repo", "base": "main", "group": group, "integration": "queue"}, 200))
	base := "/v1/workspaces/" + w.ID
	call("alice", "PUT", "/v1/resources/alice-agent", map[string]any{"kind": "agent", "name": "Alice worker", "actions": []string{"agent.handoff"},
		"capabilities": map[string]any{"harness": "claude", "model": "opus"}}, 200)
	call("bob", "PUT", "/v1/resources/bob-agent", map[string]any{"kind": "agent", "name": "Bob worker", "actions": []string{"agent.handoff"},
		"capabilities": map[string]any{"harness": "codex", "model": "gpt"}}, 200)
	// Cara is not alice's friend and not in the group, so her agent stays hidden.
	call("cara", "PUT", "/v1/resources/cara-agent", map[string]any{"kind": "agent", "name": "Cara worker", "actions": []string{"agent.handoff"}}, 200)

	// Request 7: a refused claim names the blocking claim and its holder.
	held := shareResponse[workspaceClaim](t, call("bob", "POST", base+"/claims", map[string]string{"kind": "issue", "key": "12", "holder": "bob/w-7"}, 200))
	refusal := shareResponse[map[string]string](t, call("alice", "POST", base+"/claims", map[string]string{"kind": "issue", "key": "12", "holder": "alice/w-1"}, 409))
	if refusal["holder"] != "bob/w-7" || refusal["holderHandle"] != "bob" || refusal["claim"] != held.ID || refusal["error"] == "" {
		t.Fatalf("claim refusal: %+v, held %s", refusal, held.ID)
	}
	card := shareResponse[workspaceCard](t, call("alice", "POST", base+"/cards", map[string]string{"title": "Checks"}, 200))
	call("bob", "PUT", base+"/cards/"+card.ID, map[string]string{"state": "claimed", "assignee": "bob/w-7"}, 200)
	var cardClaim string
	for _, c := range shareResponse[struct{ Workspaces []workspace }](t, call("alice", "GET", "/v1/workspaces", nil, 200)).Workspaces[0].Claims {
		if c.Kind == "card" {
			cardClaim = c.ID
		}
	}
	refusal = shareResponse[map[string]string](t, call("alice", "PUT", base+"/cards/"+card.ID, map[string]string{"state": "done"}, 409))
	if refusal["holderHandle"] != "bob" || refusal["claim"] == "" || refusal["claim"] != cardClaim {
		t.Fatalf("card refusal: %+v, card claim %s", refusal, cardClaim)
	}

	// Request 2: each member's published agents and claim holders.
	call("cara", "GET", base+"/combined", nil, 404)
	view := shareResponse[CombinedView](t, call("alice", "GET", base+"/combined", nil, 200))
	if view.Workspace != w.ID || len(view.Members) != 2 || view.Members[0].Handle != "alice" || view.Members[1].Handle != "bob" || !view.Members[0].Online {
		t.Fatalf("combined members: %+v", view)
	}
	aliceWorkers, bobWorkers := view.Members[0].Workers, view.Members[1].Workers
	if len(aliceWorkers) != 1 || aliceWorkers[0].Resource != "alice-agent" || aliceWorkers[0].Harness != "claude" || aliceWorkers[0].Model != "opus" ||
		aliceWorkers[0].State != "online" || aliceWorkers[0].Branch != "" || aliceWorkers[0].Checks != nil || aliceWorkers[0].Claims == nil {
		t.Fatalf("alice workers: %+v", aliceWorkers)
	}
	if len(bobWorkers) != 2 || bobWorkers[0].Resource != "bob-agent" || bobWorkers[0].Harness != "codex" || bobWorkers[0].State != "online" ||
		bobWorkers[1].ID != "bob/w-7" || bobWorkers[1].Agent != "w-7" || bobWorkers[1].Resource != "" || bobWorkers[1].State != "working" || len(bobWorkers[1].Claims) != 2 {
		t.Fatalf("bob workers: %+v", bobWorkers)
	}
	if _, err := s.pool.Exec(t.Context(), "UPDATE mp_leases SET ready=false,expires_at=now() WHERE device='bob-device'"); err != nil {
		t.Fatal(err)
	}
	view = shareResponse[CombinedView](t, call("alice", "GET", base+"/combined", nil, 200))
	if bob := view.Members[1]; bob.Online || bob.Workers[0].State != "offline" || bob.Workers[1].State != "working" {
		t.Fatalf("offline bob: %+v", bob)
	}
	lease := shareResponse[Lease](t, call("bob", "POST", "/v1/session", nil, 200))
	call("bob", "PUT", "/v1/session", leaseProof{lease.Session, lease.Generation}, 200)

	// Request 6: the owner edits; a member leaves.
	call("bob", "PUT", base, map[string]string{"goal": "Mine"}, 403)
	call("cara", "PUT", base, map[string]string{"goal": "Mine"}, 404)
	call("alice", "PUT", base, map[string]string{}, 400)
	call("alice", "PUT", base, map[string]string{"integration": "merge"}, 400)
	call("alice", "PUT", base, map[string]string{"name": " "}, 400)
	edited := shareResponse[workspace](t, call("alice", "PUT", base, map[string]string{"goal": "Ship the relay", "integration": "pull_request"}, 200))
	if edited.Goal != "Ship the relay" || edited.Integration != "pull_request" || edited.Name != "Relay" || edited.OwnerHandle != "alice" || len(edited.Claims) != 2 {
		t.Fatalf("edited workspace: %+v", edited)
	}
	call("alice", "DELETE", base+"/membership", nil, 403)
	call("cara", "DELETE", base+"/membership", nil, 404)
	call("bob", "DELETE", base+"/membership", nil, 200)
	call("bob", "DELETE", base+"/membership", nil, 404)
	if ws := shareResponse[struct{ Workspaces []workspace }](t, call("bob", "GET", "/v1/workspaces", nil, 200)).Workspaces; len(ws) != 0 {
		t.Fatalf("left workspace still listed: %+v", ws)
	}
	call("bob", "GET", base+"/cards", nil, 404)
	call("bob", "GET", base+"/combined", nil, 404)
	call("bob", "POST", base+"/claims", map[string]string{"kind": "issue", "key": "13", "holder": "bob/w-7"}, 404)
	after := shareResponse[workspace](t, call("alice", "PUT", base, map[string]string{"base": "develop"}, 200))
	if len(after.Claims) != 0 || after.Base != "develop" {
		t.Fatalf("leaving kept claims: %+v", after)
	}
	if view := shareResponse[CombinedView](t, call("alice", "GET", base+"/combined", nil, 200)); len(view.Members) != 1 {
		t.Fatalf("left member still combined: %+v", view)
	}
	// Bob is still in the group. Removing and re-adding him clears the departure.
	call("alice", "DELETE", member, nil, 200)
	call("alice", "PUT", member, nil, 200)
	if ws := shareResponse[struct{ Workspaces []workspace }](t, call("bob", "GET", "/v1/workspaces", nil, 200)).Workspaces; len(ws) != 1 {
		t.Fatalf("re-added member: %+v", ws)
	}
}

func TestKnowledgeOwnerHandle(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	call := func(user, method, path string, in any, status int) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, user, user+"-device", method, path, in, status)
	}
	for _, user := range []string{"alice", "bob"} {
		call(user, "PUT", "/v1/profile", map[string]string{"handle": user}, 200)
	}
	saved := shareResponse[knowledgeItem](t, call("alice", "POST", "/v1/knowledge", map[string]string{"kind": "prompt", "name": "Review", "content": "Check tests", "visibility": "server"}, 200))
	if saved.Owner != "alice" || saved.OwnerHandle != "alice" {
		t.Fatalf("saved item: %+v", saved)
	}
	call("alice", "PUT", "/v1/profile", map[string]string{"handle": "alice-renamed"}, 200)
	items := shareResponse[struct{ Items []knowledgeItem }](t, call("bob", "GET", "/v1/knowledge", nil, 200)).Items
	if len(items) != 1 || items[0].Owner != "alice" || items[0].OwnerHandle != "alice-renamed" {
		t.Fatalf("listed items: %+v", items)
	}
	versions := shareResponse[struct{ Versions []knowledgeItem }](t, call("bob", "GET", "/v1/knowledge/"+saved.ID+"/versions", nil, 200)).Versions
	if len(versions) != 1 || versions[0].OwnerHandle != "alice-renamed" {
		t.Fatalf("versions: %+v", versions)
	}
}
