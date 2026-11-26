package control

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

func TestWorkspacePathOverlap(t *testing.T) {
	a, err := claimKey("paths", "docs, ./src/**,src")
	if err != nil || a != "docs,src" {
		t.Fatalf("canonical paths: %q, %v", a, err)
	}
	for _, tc := range []struct {
		key  string
		want bool
	}{
		{"src/file.go", true}, {"src2/file.go", false}, {"api,docs/spec", true}, {".", true}, {"README", false},
	} {
		if claimsOverlap("paths", a, tc.key) != tc.want || claimsOverlap("paths", tc.key, a) != tc.want {
			t.Errorf("%q vs %q overlap: want %v", a, tc.key, tc.want)
		}
	}
	for _, invalid := range []string{"/src", "../src", "", ",src"} {
		if _, err := claimKey("paths", invalid); err == nil {
			t.Errorf("accepted invalid key %q", invalid)
		}
	}
}

func TestWorkspaceClaimsAndBoard(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	call := func(user, method, path string, in any, status int) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, user, user+"-device", method, path, in, status)
	}
	for _, user := range []string{"alice", "bob", "cara"} {
		call(user, "PUT", "/v1/profile", map[string]string{"handle": user}, 200)
	}
	call("alice", "POST", "/v1/friends/bob", nil, 200)
	call("bob", "PUT", "/v1/friends/alice", nil, 200)
	group := shareResponse[struct{ ID string }](t, call("alice", "POST", "/v1/groups", map[string]string{"name": "Contributors"}, 200)).ID
	member := "/v1/groups/" + group + "/members/bob"
	call("alice", "PUT", member, nil, 200)
	in := map[string]string{"name": "Build", "goal": "Ship it", "repository": "repo", "base": "main", "group": group, "integration": "queue"}
	const all = "/v1/workspaces"
	call("cara", "POST", all, in, 404)
	w := shareResponse[workspace](t, call("alice", "POST", all, in, 200))
	if w.ID == "" || w.OwnerHandle != "alice" || w.Repository != "repo" || w.Group != group || w.Integration != "queue" {
		t.Fatalf("created workspace: %+v", w)
	}
	claims := all + "/" + w.ID + "/claims"
	cards := all + "/" + w.ID + "/cards"
	workspaces := func(user string) []workspace {
		t.Helper()
		return shareResponse[struct{ Workspaces []workspace }](t, call(user, "GET", all, nil, 200)).Workspaces
	}
	if ws := workspaces("cara"); ws == nil || len(ws) != 0 {
		t.Fatalf("outsider workspaces: %+v", ws)
	}
	if ws := workspaces("bob"); len(ws) != 1 || ws[0].Claims == nil || len(ws[0].Claims) != 0 {
		t.Fatalf("member workspaces: %+v", ws)
	}
	call("cara", "GET", cards, nil, 404)
	call("cara", "POST", cards, map[string]string{"title": "leak"}, 404)
	issue := map[string]string{"kind": "issue", "key": "12", "holder": "bob/worker"}
	call("bob", "POST", claims, issue, 409) // No device lease yet.
	lease := shareResponse[Lease](t, call("bob", "POST", "/v1/session", nil, 200))
	proof := leaseProof{lease.Session, lease.Generation}
	call("bob", "PUT", "/v1/session", proof, 200)
	call("alice", "POST", "/v1/session", nil, 200)
	call("bob", "POST", claims, map[string]string{"kind": "issue", "key": "12", "holder": "alice/worker"}, 403)

	created := shareResponse[workspaceClaim](t, call("bob", "POST", claims, issue, 200))
	if created.ID == "" || !created.ExpiresAt.After(time.Now().Add(10*time.Minute)) {
		t.Fatalf("claim: %+v", created)
	}
	overlap := shareResponse[map[string]string](t, call("alice", "POST", claims, map[string]string{"kind": "issue", "key": "12", "holder": "alice/agent"}, 409))
	if overlap["holder"] != "bob/worker" {
		t.Fatalf("missing blocker: %+v", overlap)
	}
	call("alice", "DELETE", claims+"/"+created.ID, nil, 404)
	call("bob", "DELETE", claims+"/"+created.ID, nil, 200)

	card := shareResponse[workspaceCard](t, call("alice", "POST", cards, map[string]string{"title": "Run checks", "body": "Check the branch"}, 200))
	cardURL := cards + "/" + card.ID
	claimed := map[string]string{"state": "claimed", "assignee": "bob/worker"}
	call("bob", "PUT", cardURL, claimed, 200)
	call("bob", "PUT", cardURL, claimed, 200)
	active := workspaces("alice")[0].Claims
	if len(active) != 1 || active[0].Kind != "card" || active[0].Key != card.ID || active[0].Holder != "bob/worker" {
		t.Fatalf("board did not acquire a claim: %+v", active)
	}
	call("alice", "POST", claims, map[string]string{"kind": "card", "key": card.ID, "holder": "alice/agent"}, 409)
	call("alice", "PUT", cardURL, map[string]string{"state": "done"}, 409)
	call("bob", "PUT", cardURL, map[string]string{"state": "done", "result": "passed"}, 200)
	got := shareResponse[workspaceCard](t, call("alice", "GET", cardURL, nil, 200))
	if got.State != "done" || got.Result != "passed" || got.Assignee != "bob/worker" || len(workspaces("alice")[0].Claims) != 0 {
		t.Fatalf("completed card: %+v", got)
	}
	call("alice", "PUT", cardURL, map[string]string{"state": "open"}, 200)
	direct := map[string]string{"kind": "card", "key": card.ID, "holder": "bob/worker"}
	call("bob", "POST", claims, direct, 200)
	getCard := func() workspaceCard {
		t.Helper()
		return shareResponse[struct{ Cards []workspaceCard }](t, call("alice", "GET", cards, nil, 200)).Cards[0]
	}
	if b := getCard(); b.State != "claimed" || b.Assignee != "bob/worker" {
		t.Fatalf("direct claim missing on board: %+v", b)
	}

	call("bob", "DELETE", "/v1/session", proof, 200)
	active = workspaces("alice")[0].Claims
	if len(active) != 1 || time.Until(active[0].ExpiresAt) > 10*time.Minute || time.Until(active[0].ExpiresAt) < 9*time.Minute {
		t.Fatalf("disconnect expiry: %+v", active)
	}
	setTime := func(query string) {
		t.Helper()
		if _, err := s.pool.Exec(t.Context(), query); err != nil {
			t.Fatal(err)
		}
	}
	// Simulate nine offline minutes then two takeovers. Only the end of the
	// generation that acquired the claim determines its remaining grace.
	setTime("UPDATE mp_leases SET expires_at=now()-interval '9 minutes' WHERE device='bob-device'")
	call("bob", "POST", "/v1/session", nil, 200)
	call("bob", "POST", "/v1/session", nil, 200)
	active = workspaces("alice")[0].Claims
	if len(active) != 1 || time.Until(active[0].ExpiresAt) > time.Minute || time.Until(active[0].ExpiresAt) < 50*time.Second {
		t.Fatalf("takeover changed grace: %+v", active)
	}
	setTime("UPDATE mp_workspace_claims SET lease_ended_at=now()-interval '10 minutes' WHERE device='bob-device'")
	if b := getCard(); b.State != "open" || b.Assignee != "" {
		t.Fatalf("expired card: %+v", b)
	}
	call("bob", "POST", claims, direct, 200)
	// A silent timeout follows the same grace window. A later heartbeat on a
	// different device cannot extend it.
	setTime("UPDATE mp_leases SET expires_at=now()-interval '11 minutes' WHERE device='bob-device'")
	if active := workspaces("alice")[0].Claims; len(active) != 0 {
		t.Fatalf("expired claims: %+v", active)
	}
	call("bob", "POST", "/v1/session", nil, 200)
	call("bob", "POST", claims, direct, 200)
	call("alice", "DELETE", member, nil, 200)
	call("bob", "GET", cards, nil, 404)
	call("alice", "PUT", member, nil, 200)
	if b := getCard(); b.State != "open" || b.Assignee != "" {
		t.Fatalf("removed member's claim returned: %+v", b)
	}

	// A pair of simultaneous path claims must return exactly one winner
	// and name that same winner to the caller whose path overlaps.
	type result struct {
		code         int
		holder, body string
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	for user, key := range map[string]string{"alice": "src", "bob": "tests,src/go"} {
		go func() {
			input, _ := json.Marshal(map[string]string{"kind": "paths", "key": key, "holder": user + "/agent"})
			req := httptest.NewRequest("POST", claims, bytes.NewReader(input))
			req.Header.Set("Test-User", user)
			req.Header.Set("Test-Device", user+"-device")
			out := httptest.NewRecorder()
			<-start
			h.ServeHTTP(out, req)
			var v struct{ Holder string }
			_ = json.Unmarshal(out.Body.Bytes(), &v)
			results <- result{out.Code, v.Holder, out.Body.String()}
		}()
	}
	close(start)
	first, second := <-results, <-results
	if first.code > second.code {
		first, second = second, first
	}
	if first.code != 200 || second.code != 409 || first.holder == "" || second.holder != first.holder {
		t.Fatalf("concurrent paths: %+v, %+v", first, second)
	}
	call("alice", "PUT", "/v1/profile", map[string]string{"handle": "alice-renamed"}, 200)
	if row := workspaces("bob")[0]; row.Owner != "alice" || row.OwnerHandle != "alice-renamed" {
		t.Fatalf("workspace owner after handle change: %+v", row)
	}
}
