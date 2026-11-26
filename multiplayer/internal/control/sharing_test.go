package control

import (
	"encoding/json"
	"net/http/httptest"
	"reflect"
	"slices"
	"testing"
	"time"
)

func sharingAPI(t *testing.T) func(string, string, string, any, int) *httptest.ResponseRecorder {
	t.Helper()
	h := newSocialFixture(t).Handler()
	call := func(user, method, path string, in any, status int) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, user, user+"-device", method, path, in, status)
	}
	for _, name := range []string{"alice", "bob", "cara"} {
		call(name, "PUT", "/v1/profile", map[string]string{"handle": name}, 200)
	}
	call("alice", "POST", "/v1/friends/bob", nil, 200)
	call("bob", "PUT", "/v1/friends/alice", nil, 200)
	return call
}

func shareResponse[T any](t *testing.T, response *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.NewDecoder(response.Body).Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestSharedDirectoryAndAccessRequests(t *testing.T) {
	call := sharingAPI(t)
	const resource = "/v1/resources/worker"
	const requests = "/v1/access-requests"
	actions := []string{"agent.handoff", "thread.read"}
	capabilities := map[string]any{"harness": "claude", "model": "custom model", "slots": 2,
		"tools": []string{"git"}, "environments": []string{"ios-simulator", "gpu"}}
	publication := map[string]any{"kind": "agent", "name": "Build worker", "actions": actions, "capabilities": capabilities}
	put := shareResponse[Resource](t, call("alice", "PUT", resource, publication, 200))
	wantSlots := 2
	want := &Capabilities{Harness: "claude", Model: "custom model", Slots: &wantSlots, Tools: []string{"git"}, Environments: []string{"ios-simulator", "gpu"}}
	if put.ID != "worker" || !reflect.DeepEqual(put.Capabilities, want) {
		t.Fatalf("resource PUT: %+v", put)
	}
	type catalog struct {
		Resources []Resource
		Directory []DirectoryResource
	}
	getCatalog := func(who string) catalog {
		t.Helper()
		return shareResponse[catalog](t, call(who, "GET", "/v1/resources", nil, 200))
	}
	if own := getCatalog("alice").Resources; len(own) != 1 || !reflect.DeepEqual(own[0].Capabilities, want) {
		t.Fatalf("owner resources: %+v", own)
	}
	before := getCatalog("bob")
	if len(before.Resources) != 0 || len(before.Directory) != 1 || !slices.Equal(before.Directory[0].Actions, actions) ||
		before.Directory[0].GrantedActions == nil || len(before.Directory[0].GrantedActions) != 0 || !reflect.DeepEqual(before.Directory[0].Capabilities, want) {
		t.Fatalf("directory before grant: %+v", before)
	}
	if other := getCatalog("cara"); len(other.Directory)+len(other.Resources) != 0 {
		t.Fatalf("nonfriend directory: %+v", other)
	}
	request := map[string]any{"resource": "worker", "actions": actions, "note": "Help test a build"}
	call("cara", "POST", requests, request, 403)
	call("bob", "POST", requests, map[string]any{"resource": "worker", "actions": []string{"unknown"}}, 400)
	id := shareResponse[struct{ ID string }](t, call("bob", "POST", requests, request, 200)).ID
	if id == "" {
		t.Fatal("request has no id")
	}
	list := func(who string) []AccessRequest {
		t.Helper()
		return shareResponse[struct{ Requests []AccessRequest }](t, call(who, "GET", requests, nil, 200)).Requests
	}
	for _, who := range []string{"alice", "bob"} {
		rows := list(who)
		if len(rows) != 1 {
			t.Fatalf("requests for %s: %+v", who, rows)
		}
		r := rows[0]
		if r.ID != id || r.Owner != "alice" || r.Requester != "bob" || r.Resource != "worker" || r.Note != request["note"] ||
			!slices.Equal(r.Actions, actions) || r.Status != "pending" || r.CreatedAt.IsZero() {
			t.Fatalf("request for %s: %+v", who, r)
		}
	}
	if other := list("cara"); other == nil || len(other) != 0 {
		t.Fatalf("nonparticipant's requests: %+v", other)
	}
	call("cara", "DELETE", requests+"/"+id, nil, 404)
	events := func(who string) []Event {
		t.Helper()
		return shareResponse[struct{ Events []Event }](t, call(who, "GET", "/v1/events", nil, 200)).Events
	}
	ownerEvents := events("alice")
	if len(ownerEvents) != 2 || ownerEvents[1].Kind != "access.requested" || ownerEvents[1].Resource != "worker" || ownerEvents[1].Actor != "bob" {
		t.Fatalf("owner events: %+v", ownerEvents)
	}
	grant := map[string]any{"actions": actions[:1], "expires_at": time.Now().Add(time.Hour), "max_uses": 2}
	call("alice", "PUT", "/v1/grants/worker/bob", grant, 200)
	after := getCatalog("bob")
	if len(after.Directory) != 1 || !slices.Equal(after.Directory[0].GrantedActions, actions[:1]) || !slices.Equal(after.Directory[0].Actions, actions) {
		t.Fatalf("directory with partial grant: %+v", after)
	}
	if rows := list("bob"); len(rows) != 1 || rows[0].Status != "pending" {
		t.Fatalf("partial grant settled request: %+v", rows)
	}
	grant["actions"] = actions
	call("alice", "PUT", "/v1/grants/worker/bob", grant, 200)
	if rows := list("bob"); len(rows) != 1 || rows[0].Status != "granted" {
		t.Fatalf("full grant did not settle request: %+v", rows)
	}
	received := events("bob")
	if len(received) != 3 || received[2].Kind != "grant.received" || received[2].Actor != "alice" || received[2].Resource != "worker" {
		t.Fatalf("requester events: %+v", received)
	}
	for _, who := range []string{"bob", "alice"} {
		newID := shareResponse[struct{ ID string }](t, call("bob", "POST", requests, request, 200)).ID
		call(who, "DELETE", requests+"/"+newID, nil, 200)
		if rows := list("alice"); len(rows) != 1 || rows[0].ID != id {
			t.Fatalf("delete by %s: %+v", who, rows)
		}
	}
	delete(publication, "capabilities")
	call("alice", "PUT", resource, publication, 200)
	if got := getCatalog("bob").Directory[0].Capabilities; got != nil {
		t.Fatalf("replaced resource kept capabilities: %+v", got)
	}
}

func TestShareGrantLimitsAndDottedSubmissions(t *testing.T) {
	call := sharingAPI(t)
	actions := []string{"agent.handoff", "agent.result", "agent.status", "thread.comment", "thread.read"}
	call("alice", "PUT", "/v1/resources/worker", map[string]any{"kind": "agent", "name": "Worker", "actions": actions}, 200)
	until := time.Now().Add(time.Hour)
	var limits []map[string]any
	var children []Addressed
	for _, a := range actions {
		limits = append(limits, map[string]any{"action": a, "expires_at": until, "max_uses": 10})
		children = append(children, Addressed{ID: a, Device: "alice-device", Resource: "worker", Action: a,
			Envelope: json.RawMessage(`"hdr..iv.ciphertext.tag"`), ExpiresAt: until})
	}
	limits[0]["approval"], limits[0]["budgetTokens"], limits[0]["attribution"] = "auto", 200, "requester"
	sub := map[string]any{"id": "consult", "children": children}
	call("bob", "POST", "/v1/submissions", sub, 403)
	path := "/v1/grants/worker/bob"
	call("alice", "PUT", path, map[string]any{"limits": limits}, 200)
	for _, who := range []string{"alice", "bob"} {
		grants := shareResponse[struct{ Grants []Grant }](t, call(who, "GET", "/v1/grants", nil, 200)).Grants
		if len(grants) != 1 || len(grants[0].Limits) != len(actions) {
			t.Fatalf("grant for %s: %+v", who, grants)
		}
		for i, l := range grants[0].Limits {
			approval, budget, attribution := "ask", int64(0), "owner"
			if i == 0 {
				approval, budget, attribution = "auto", 200, "requester"
			}
			if l.Action != actions[i] || l.Approval != approval || l.BudgetTokens != budget || l.Attribution != attribution {
				t.Fatalf("limit for %s: %+v", who, l)
			}
		}
	}
	result := shareResponse[Submission](t, call("bob", "POST", "/v1/submissions", sub, 200))
	if len(result.Children) != len(actions) {
		t.Fatalf("admitted children: %+v", result.Children)
	}
	lease := shareResponse[leaseProof](t, call("alice", "POST", "/v1/session", nil, 200))
	call("alice", "PUT", "/v1/session", lease, 200)
	claim := shareResponse[struct{ Claimed bool }](t, call("alice", "POST", "/v1/children/agent.result/claim", lease, 200))
	if !claim.Claimed {
		t.Fatal("owner could not claim a request for local approval")
	}
	// Editing a policy retains usage. A spent limit cannot fulfill a new access request.
	call("bob", "POST", "/v1/access-requests", map[string]any{"resource": "worker", "actions": []string{"agent.result"}}, 200)
	limits[1]["max_uses"] = 1
	call("alice", "PUT", path, map[string]any{"limits": limits}, 200)
	requests := shareResponse[struct{ Requests []AccessRequest }](t, call("bob", "GET", "/v1/access-requests", nil, 200))
	if len(requests.Requests) != 1 || requests.Requests[0].Status != "pending" {
		t.Fatalf("exhausted limit settled request: %+v", requests)
	}
	for field, value := range map[string]any{"approval": "always", "budgetTokens": -1, "attribution": "server"} {
		limits[1][field] = value
		call("alice", "PUT", path, map[string]any{"limits": limits}, 400)
		delete(limits[1], field)
	}
}
