package control

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
	"time"
)

func TestGroupsAndExpandedGrants(t *testing.T) {
	call := sharingAPI(t)
	create := func(name string) string {
		t.Helper()
		id := shareResponse[struct{ ID string }](t, call("alice", "POST", "/v1/groups", map[string]string{"name": name}, 200)).ID
		if id == "" {
			t.Fatal("missing group ID")
		}
		return id
	}
	list := func(user string) []Group {
		t.Helper()
		return shareResponse[struct{ Groups []Group }](t, call(user, "GET", "/v1/groups", nil, 200)).Groups
	}
	grants := func(user string) []Grant {
		t.Helper()
		return shareResponse[struct{ Grants []Grant }](t, call(user, "GET", "/v1/grants", nil, 200)).Grants
	}
	first, second := create("Design"), create("Review")
	member := func(group, handle string) string { return "/v1/groups/" + group + "/members/" + handle }
	groupGrant := func(group string) string { return "/v1/grants/worker/group:" + group }
	until := time.Now().Add(time.Hour)
	policy := func(action string) grantPolicy {
		return grantPolicy{Limits: []Limit{{Action: action, ExpiresAt: until, MaxUses: 1, Approval: "auto", BudgetTokens: 100, Attribution: "requester"}}}
	}
	publish := func(actions ...string) {
		t.Helper()
		call("alice", "PUT", "/v1/resources/worker", map[string]any{"kind": "agent", "name": "Worker", "actions": actions}, 200)
	}
	publish("read", "write", "run")
	call("alice", "PUT", member(first, "cara"), nil, 403)
	call("bob", "PUT", member(first, "bob"), nil, 403)
	call("bob", "DELETE", "/v1/groups/"+first, nil, 403)
	call("alice", "PUT", member(first, "bob"), nil, 200)
	call("alice", "PUT", member(first, "bob"), nil, 200)
	if gs := list("bob"); len(gs) != 1 || gs[0].Owner != "alice" || !slices.Equal(gs[0].Members, []string{"alice", "bob"}) {
		t.Fatalf("member list: %+v", gs)
	}
	if gs := list("cara"); len(gs) != 0 {
		t.Fatalf("stranger saw groups: %+v", gs)
	}
	call("alice", "PUT", groupGrant(first), policy("read"), 200)
	call("alice", "PUT", groupGrant(second), policy("write"), 200)
	call("alice", "PUT", member(second, "bob"), nil, 200)
	direct := grantPolicy{Actions: []string{"run"}, ExpiresAt: until, MaxUses: 2}
	call("alice", "PUT", "/v1/grants/worker/bob", direct, 200)
	if gs := grants("bob"); len(gs) != 1 || !slices.Equal(gs[0].Actions, []string{"read", "run", "write"}) || gs[0].Limits[0].BudgetTokens != 100 {
		t.Fatalf("expanded grants: %+v", gs)
	}
	call("alice", "POST", "/v1/friends/cara", nil, 200)
	call("cara", "PUT", "/v1/friends/alice", nil, 200)
	call("alice", "PUT", member(first, "cara"), nil, 200)
	if gs := grants("cara"); len(gs) != 1 || !slices.Equal(gs[0].Actions, []string{"read"}) {
		t.Fatalf("new group member's grants: %+v", gs)
	}

	lease := shareResponse[Lease](t, call("alice", "POST", "/v1/session", nil, 200))
	proof := leaseProof{Session: lease.Session, Generation: lease.Generation}
	call("alice", "PUT", "/v1/session", proof, 200)
	submit := func(user, id, action string) {
		t.Helper()
		child := Addressed{ID: id, Resource: "worker", Device: "alice-device", Action: action, ExpiresAt: until, Envelope: json.RawMessage(`"hdr..iv.ciphertext.tag"`)}
		call(user, "POST", "/v1/submissions", map[string]any{"id": id, "children": []Addressed{child}}, 200)
	}
	submit("bob", "queued", "read")
	submit("cara", "working", "read")
	receipt := shareResponse[struct{ Claimed bool }](t, call("alice", "POST", "/v1/children/working/claim", proof, 200))
	if !receipt.Claimed {
		t.Fatal("expanded grant did not admit execution")
	}
	if gs := grants("bob"); gs[0].Used != 0 {
		t.Fatal("another member's execution consumed this grant", gs)
	}
	call("alice", "DELETE", member(first, "bob"), nil, 200)
	got := shareResponse[Submission](t, call("bob", "GET", "/v1/submissions/queued", nil, 200))
	if got.Children[0].Status != "revoked" {
		t.Fatalf("removed member's queue: %+v", got)
	}
	if gs := grants("bob"); len(gs) != 1 || !slices.Equal(gs[0].Actions, []string{"run", "write"}) {
		t.Fatalf("removal affected an independent grant: %+v", gs)
	}
	// Both grants now authorize run, with separate one-use and two-use ledgers.
	call("alice", "PUT", groupGrant(second), policy("run"), 200)
	for _, id := range []string{"direct-one", "direct-two", "group-one"} {
		submit("bob", id, "run")
		result := shareResponse[struct{ Claimed bool }](t, call("alice", "POST", "/v1/children/"+id+"/claim", proof, 200))
		if !result.Claimed {
			t.Fatal("unused source did not admit execution", id)
		}
	}
	call("alice", "DELETE", groupGrant(second), nil, 200)
	if gs := grants("bob"); len(gs) != 1 || !slices.Equal(gs[0].Actions, []string{"run"}) || gs[0].Used != 2 {
		t.Fatalf("group revocation removed direct grant: %+v", gs)
	}
	publish("write", "run")
	publish("read", "write", "run")
	call("alice", "PUT", member(first, "bob"), nil, 200)
	if gs := grants("bob"); len(gs) != 1 || !slices.Equal(gs[0].Actions, []string{"run"}) {
		t.Fatalf("republication restored withdrawn group action: %+v", gs)
	}
	call("alice", "DELETE", "/v1/groups/"+first, nil, 200)
	if gs := grants("cara"); len(gs) != 0 {
		t.Fatalf("group deletion kept grant: %+v", gs)
	}
	call("bob", "DELETE", "/v1/friends/alice", nil, 200)
	if gs := list("bob"); len(gs) != 0 {
		t.Fatalf("former friend still belongs to owner's groups: %+v", gs)
	}
	events := shareResponse[struct{ Events []Event }](t, call("bob", "GET", "/v1/events", nil, 200)).Events
	var changes []string
	for _, event := range events {
		if event.Resource == first {
			changes = append(changes, event.Kind)
		}
	}
	if !slices.Equal(changes, []string{"group.added", "group.removed", "group.added", "group.removed"}) {
		t.Fatalf("group membership events: %v", changes)
	}
}

func TestGroupMigrationPreservesExistingDirectGrant(t *testing.T) {
	pool := controlTestPool(t)
	ctx := t.Context()
	if _, err := pool.Exec(ctx, socialSchema+schema); err != nil {
		t.Fatal(err)
	}
	// Pre-Teams relays had a two-kind resource constraint and direct grants
	// keyed only by (resource, grantee). Some aggregate grants predate the
	// per-action ledger and need their old receipts to reconstruct its debits.
	if _, err := pool.Exec(ctx, `ALTER TABLE mp_resources DROP CONSTRAINT mp_resources_team_kind;
		ALTER TABLE mp_resources ADD CHECK(kind IN ('agent','repo'));
		INSERT INTO mp_profiles(user_id,handle) VALUES('owner','owner'),('peer','peer');
		INSERT INTO mp_friends(a,b,requester,accepted) VALUES('owner','peer','owner',true);
		INSERT INTO mp_resources(id,owner_id,device,kind,name,actions) VALUES
		    ('worker','owner','owner-device','agent','Worker','{read,run}'),
		    ('repo','owner','owner-device','repo','Repo','{view}');
		INSERT INTO mp_grants(resource,grantee,actions,expires_at,max_uses,used,per_action) VALUES
		    ('worker','peer','{read}',now()+interval '1 hour',1,1,false),
		    ('repo','peer','{view}',now()+interval '1 hour',5,2,true);
		INSERT INTO mp_grant_limits(resource,grantee,action,expires_at,max_uses,used)
		    VALUES('repo','peer','view',now()+interval '1 hour',5,2);
		INSERT INTO mp_submissions(sender,parent,sender_device,digest) VALUES('peer','past','peer-device','');
		INSERT INTO mp_children(id,parent,sender,sender_device,owner_id,device,resource,action,envelope,expires_at,status)
		    VALUES('past','past','peer','peer-device','owner','owner-device','worker','read','{}',now(),'completed')`); err != nil {
		t.Fatal(err)
	}
	auth := func(r *http.Request) (Principal, error) {
		return Principal{User: r.Header.Get("Test-User"), Device: r.Header.Get("Test-Device")}, nil
	}
	restart := func() http.Handler {
		t.Helper()
		s, err := New(ctx, pool, "edge", auth, nil)
		if err != nil {
			t.Fatal(err)
		}
		return s.Handler()
	}
	h := restart()
	call := func(who, method, path string, body any) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, who, who+"-device", method, path, body, 200)
	}
	call("owner", "PUT", "/v1/resources/host", map[string]any{"name": "Host", "kind": "host", "actions": []string{"host.run"}})
	id := shareResponse[struct{ ID string }](t, call("owner", "POST", "/v1/groups", map[string]string{"name": "Review"})).ID
	call("owner", "PUT", "/v1/groups/"+id+"/members/peer", nil)
	until := time.Now().Add(time.Hour)
	call("owner", "PUT", "/v1/grants/worker/group:"+id, grantPolicy{Actions: []string{"run"}, ExpiresAt: until, MaxUses: 2})
	lease := shareResponse[Lease](t, call("owner", "POST", "/v1/session", nil))
	proof := leaseProof{Session: lease.Session, Generation: lease.Generation}
	call("owner", "PUT", "/v1/session", proof)
	child := Addressed{ID: "group-use", Device: "owner-device", Resource: "worker", Action: "run", ExpiresAt: until, Envelope: json.RawMessage(`"hdr..iv.ciphertext.tag"`)}
	call("peer", "POST", "/v1/submissions", map[string]any{"id": child.ID, "children": []Addressed{child}})
	if result := shareResponse[struct{ Claimed bool }](t, call("owner", "POST", "/v1/children/group-use/claim", proof)); !result.Claimed {
		t.Fatal("group debit did not commit")
	}
	h = restart()
	call("owner", "PUT", "/v1/grants/worker/peer", grantPolicy{Limits: []Limit{{Action: "read", ExpiresAt: until, MaxUses: 1}}})
	grants := shareResponse[struct{ Grants []Grant }](t, call("owner", "GET", "/v1/grants", nil)).Grants
	if len(grants) != 2 || grants[0].Resource != "repo" || grants[0].Limits[0].Used != 2 {
		t.Fatalf("pre-existing per-action debit: %+v", grants)
	}
	worker := grants[1]
	if len(worker.Limits) != 2 || worker.Limits[0].Action != "read" || worker.Limits[0].Used != 1 ||
		worker.Limits[1].Action != "run" || worker.Limits[1].Used != 1 {
		t.Fatalf("migrated aggregate and subsequent group debits: %+v", worker)
	}
}

func TestGroupMemberAddedAfterPolicyTightens(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	call := func(who, method, path string, body any) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, who, who+"-device", method, path, body, 200)
	}
	for _, who := range []string{"owner", "peer"} {
		call(who, "PUT", "/v1/profile", map[string]string{"handle": who})
	}
	call("owner", "POST", "/v1/friends/peer", nil)
	call("peer", "PUT", "/v1/friends/owner", nil)
	group := shareResponse[struct{ ID string }](t, call("owner", "POST", "/v1/groups", map[string]string{"name": "Team"})).ID
	for _, res := range []struct {
		name   string
		budget int64
	}{{"large", 500}, {"small", 10}} {
		call("owner", "PUT", "/v1/resources/"+res.name, map[string]any{"name": res.name, "kind": "agent", "actions": []string{"run"}})
		call("owner", "PUT", "/v1/grants/"+res.name+"/group:"+group, grantPolicy{Limits: []Limit{{Action: "run", ExpiresAt: time.Now().Add(time.Hour), MaxUses: 2, BudgetTokens: res.budget}}})
	}
	if _, err := s.pool.Exec(t.Context(), "UPDATE mp_policy SET max_budget_tokens=100"); err != nil {
		t.Fatal(err)
	}
	call("owner", "PUT", "/v1/groups/"+group+"/members/peer", nil)
	groups := shareResponse[struct{ Groups []Group }](t, call("peer", "GET", "/v1/groups", nil)).Groups
	grants := shareResponse[struct{ Grants []Grant }](t, call("peer", "GET", "/v1/grants", nil)).Grants
	if len(groups) != 1 || len(grants) != 1 || grants[0].Resource != "small" {
		t.Fatalf("membership and grants under tightened cap: groups=%+v grants=%+v", groups, grants)
	}
}

func TestGroupMemberPublishesToOtherMembers(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	call := func(who, method, path string, body any, status int) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, who, who+"-device", method, path, body, status)
	}
	for _, who := range []string{"alice", "bob", "cara"} {
		call(who, "PUT", "/v1/profile", map[string]string{"handle": who}, 200)
	}
	for _, peer := range []string{"bob", "cara"} {
		call("alice", "POST", "/v1/friends/"+peer, nil, 200)
		call(peer, "PUT", "/v1/friends/alice", nil, 200)
	}
	group := shareResponse[struct{ ID string }](t, call("alice", "POST", "/v1/groups", map[string]string{"name": "Team"}, 200)).ID
	member := "/v1/groups/" + group + "/members/"
	call("alice", "PUT", member+"bob", nil, 200)
	call("bob", "PUT", "/v1/resources/worker", map[string]any{"name": "Worker", "kind": "agent", "actions": []string{"read", "run"}}, 200)
	until := time.Now().Add(time.Hour)
	policy := grantPolicy{Limits: []Limit{{Action: "run", MaxUses: 1, ExpiresAt: until}}}
	call("bob", "PUT", "/v1/grants/worker/group:"+group, policy, 200)
	call("bob", "PUT", "/v1/grants/worker/cara", policy, 403)
	keys := func(want bool) {
		t.Helper()
		for _, users := range [][2]string{{"cara", "bob"}, {"bob", "cara"}} {
			got, err := s.CanLookup(t.Context(), users[0], users[1])
			if err != nil || got != want {
				t.Fatalf("key access between %v: got=%t, err=%v", users, got, err)
			}
		}
	}
	keys(false)
	call("alice", "PUT", member+"cara", nil, 200)
	keys(true)
	catalog := shareResponse[struct {
		Resources []Resource
		Directory []DirectoryResource
	}](t, call("cara", "GET", "/v1/resources", nil, 200))
	if len(catalog.Resources) != 1 || !slices.Equal(catalog.Resources[0].Actions, []string{"run"}) || len(catalog.Directory) != 0 {
		t.Fatalf("nonfriend group grantee catalog: %+v", catalog)
	}
	submit := func(id string, status int) {
		t.Helper()
		child := Addressed{ID: id, Device: "bob-device", Resource: "worker", Action: "run", ExpiresAt: until, Envelope: json.RawMessage(`"hdr..iv.ciphertext.tag"`)}
		call("cara", "POST", "/v1/submissions", map[string]any{"id": id, "children": []Addressed{child}}, status)
	}
	submit("valid", 200)
	call("bob", "POST", "/v1/friends/cara", nil, 200)
	call("cara", "PUT", "/v1/friends/bob", nil, 200)
	call("bob", "PUT", "/v1/grants/worker/cara", grantPolicy{Actions: []string{"read"}, MaxUses: 1, ExpiresAt: until}, 200)
	call("bob", "DELETE", "/v1/friends/cara", nil, 200)
	keys(true)
	lease := shareResponse[Lease](t, call("bob", "POST", "/v1/session", nil, 200))
	proof := leaseProof{lease.Session, lease.Generation}
	call("bob", "PUT", "/v1/session", proof, 200)
	if got := shareResponse[struct{ Claimed bool }](t, call("bob", "POST", "/v1/children/valid/claim", proof, 200)); !got.Claimed {
		t.Fatal("third party's group grant was lost on friend removal")
	}
	submit("exhausted", 403)
	keys(true) // The exhausted grant's in-flight request can still be decrypted.
	call("alice", "DELETE", member+"cara", nil, 200)
	keys(false)
	grants := func(who string) []Grant {
		t.Helper()
		return shareResponse[struct{ Grants []Grant }](t, call(who, "GET", "/v1/grants", nil, 200)).Grants
	}
	if gs := grants("bob"); len(gs) != 1 || gs[0].Grantee != "alice" {
		t.Fatalf("other member's grant lost: %+v", gs)
	}
	call("alice", "PUT", member+"cara", nil, 200)
	submit("pending", 200)
	call("alice", "DELETE", member+"bob", nil, 200)
	if gs := grants("bob"); len(gs) != 0 {
		t.Fatalf("departing grantor's expansions: %+v", gs)
	}
	if receipt := shareResponse[Submission](t, call("cara", "GET", "/v1/submissions/pending", nil, 200)); receipt.Children[0].Status != "revoked" {
		t.Fatal(receipt)
	}
	keys(false)
	call("alice", "PUT", member+"bob", nil, 200)
	if gs := grants("cara"); len(gs) != 0 {
		t.Fatalf("former grantor's template was restored: %+v", gs)
	}
	submit("withdrawn", 403)
}
