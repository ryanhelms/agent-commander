package control

import (
	"net/http/httptest"
	"net/url"
	"slices"
	"testing"
	"time"
)

func TestOptInDirectoryAndRequestReputation(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	call := func(who, method, path string, in any, status int) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, who, who+"-device", method, path, in, status)
	}
	for _, u := range []string{"alice", "bob", "cara"} {
		call(u, "PUT", "/v1/profile", map[string]string{"handle": u}, 200)
	}
	call("alice", "POST", "/v1/friends/bob", nil, 200)
	call("bob", "PUT", "/v1/friends/alice", nil, 200)
	pub := map[string]any{"kind": "host", "name": "Mac build", "actions": []string{"host.run"}, "capabilities": Capabilities{Environments: []string{"ios-simulator"}}}
	call("alice", "PUT", "/v1/resources/mac", pub, 200)
	type matches struct {
		Handles   []string
		Resources []directoryHit
	}
	search := func(q string) matches {
		t.Helper()
		return shareResponse[matches](t, call("cara", "GET", "/v1/directory?q="+url.QueryEscape(q), nil, 200))
	}
	if got := search(""); len(got.Handles)+len(got.Resources) != 0 {
		t.Fatal(got)
	}
	pub["listed"] = true
	call("alice", "PUT", "/v1/resources/mac", pub, 200)
	for _, term := range []string{"BUILD", "simulator", "Host.Run", "alice"} {
		if got := search(term); len(got.Resources) != 1 || got.Resources[0].ID != "mac" {
			t.Fatal(term, got)
		}
	}
	if got := search("ali"); !slices.Equal(got.Handles, []string{"alice"}) {
		t.Fatal(got)
	}
	if got := search("bob"); !slices.Equal(got.Handles, []string{"bob"}) || len(got.Resources) != 0 {
		t.Fatal(got)
	}
	delete(pub, "listed")
	call("alice", "PUT", "/v1/resources/mac", pub, 200)
	if got := search("%"); len(got.Resources) != 0 {
		t.Fatal(got)
	}
	ctx := t.Context()
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := s.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec("INSERT INTO mp_members(user_id,suspended) VALUES('alice',true) ON CONFLICT(user_id) DO UPDATE SET suspended=true")
	if got := search("alice"); len(got.Handles)+len(got.Resources) != 0 {
		t.Fatal(got)
	}
	exec("UPDATE mp_members SET suspended=false WHERE user_id='alice'")
	exec("UPDATE mp_policy SET directory=false")
	call("cara", "GET", "/v1/directory", nil, 403)
	exec("UPDATE mp_policy SET directory=true")
	endorse := map[string]string{"resource": "mac", "skill": "iOS builds"}
	call("bob", "POST", "/v1/endorsements", endorse, 403)
	const rep = "/v1/reputation/mac"
	getRep := func(who string) reputationSummary {
		return shareResponse[reputationSummary](t, call(who, "GET", rep, nil, 200))
	}
	call("bob", "GET", rep, nil, 403)
	if got := getRep("alice"); got.MedianSeconds != nil || got.Completed != 0 {
		t.Fatal(got)
	}
	expiry := time.Now().Add(time.Hour)
	call("alice", "PUT", "/v1/grants/mac/bob", map[string]any{"actions": []string{"host.run"}, "expires_at": expiry, "max_uses": 3}, 200)
	lease := shareResponse[leaseProof](t, call("alice", "POST", "/v1/session", nil, 200))
	call("alice", "PUT", "/v1/session", lease, 200)
	for _, req := range []string{"one", "two", "three"} {
		child := map[string]any{"id": req + "-child", "device": "alice-device", "resource": "mac", "action": "host.run", "expires_at": expiry, "envelope": "a..b.c.d"}
		call("bob", "POST", "/v1/submissions", map[string]any{"id": req, "children": []any{child}}, 200)
		call("alice", "POST", "/v1/children/"+req+"-child/claim", lease, 200)
		call("alice", "PUT", "/v1/children/"+req+"-child/receipt", map[string]any{"status": "completed", "result": "a..b.c.d", "session": lease.Session, "generation": lease.Generation}, 200)
	}
	report := func(who, request string, accepted bool, status int) {
		t.Helper()
		call(who, "POST", "/v1/outcomes", map[string]any{"request": request, "resource": "mac", "accepted": accepted}, status)
	}
	report("bob", "one", true, 200)
	report("bob", "one-child", true, 200)
	report("bob", "one", false, 409)
	report("bob", "two-child", false, 200)
	report("cara", "three", true, 404)
	report("alice", "three", true, 404)
	got := getRep("alice")
	if got.MedianSeconds == nil || got.Completed != 3 || got.Accepted != 1 || got.Rejected != 1 {
		t.Fatal(got)
	}
	exec(`UPDATE mp_children SET submitted_at=CASE parent WHEN 'three' THEN NULL ELSE completed_at -
		CASE parent WHEN 'one' THEN interval '20 seconds' ELSE interval '30 seconds' END END`)
	if v := getRep("alice").MedianSeconds; v == nil || *v != 25 {
		t.Fatal("median duration", v)
	}
	for _, visibility := range []string{"users", "friends", "server"} {
		exec("UPDATE mp_policy SET reputation_visibility=$1", visibility)
		if getRep("bob").Completed != 3 {
			t.Fatal(visibility)
		}
		if visibility == "server" {
			getRep("cara")
		} else {
			call("cara", "GET", rep, nil, 403)
		}
	}
	call("bob", "POST", "/v1/endorsements", endorse, 200)
	call("bob", "POST", "/v1/endorsements", endorse, 200)
	call("cara", "POST", "/v1/endorsements", endorse, 403)
	if v := search("mac").Resources[0].Endorsements; !slices.Equal(v, []Endorsement{{Handle: "bob", Skill: "iOS builds"}}) {
		t.Fatal(v)
	}
	type catalog struct{ Resources []Resource }
	if v := shareResponse[catalog](t, call("alice", "GET", "/v1/resources", nil, 200)).Resources[0]; !v.Listed || len(v.Endorsements) != 1 {
		t.Fatal(v)
	}
	pub["listed"] = false
	call("alice", "PUT", "/v1/resources/mac", pub, 200)
	if got := search(""); len(got.Handles)+len(got.Resources) != 0 {
		t.Fatal(got)
	}
}
