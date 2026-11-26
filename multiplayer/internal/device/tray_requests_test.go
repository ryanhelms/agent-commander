package device

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
	"agentcommander.network/pilot/internal/sharing"
)

// envelope returns the whole tray answer, including refusal fields beside error.
func envelope(t *testing.T, h http.Handler, verb string, in any) map[string]any {
	t.Helper()
	b, _ := json.Marshal(in)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("POST", "/tray/"+verb, bytes.NewReader(b)))
	var out map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatalf("%s: %v (%s)", verb, err, w.Body.String())
	}
	return out
}

func TestTrayWorkspaceAndAdminVerbRoutes(t *testing.T) {
	type request struct {
		Method string
		Path   string
		Body   map[string]string
	}
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := request{Method: r.Method, Path: r.URL.Path}
		if err := json.NewDecoder(r.Body).Decode(&got.Body); err != nil && err != io.EOF {
			t.Error(err)
		}
		json.NewEncoder(w).Encode(got)
	}))
	t.Cleanup(relay.Close)
	s := identity.Session{User: "alice", ExpiresAt: time.Now().Add(time.Hour)}
	a := &Agent{cfg: Config{Relay: relay.URL}, http: relay.Client(), creds: credentials{Session: s}}
	h := a.Handler()
	for _, tc := range []struct {
		verb string
		args any
		want request
	}{
		{"admin-members", input{}, request{"GET", "/v1/admin/members", nil}},
		{"workspace-edit", input{Workspace: "w1", Goal: "Ship the relay", Integration: "pull_request"},
			request{"PUT", "/v1/workspaces/w1", map[string]string{"goal": "Ship the relay", "integration": "pull_request"}}},
		{"workspace-edit", input{ID: "w1", Name: "Relay"}, request{"PUT", "/v1/workspaces/w1", map[string]string{"name": "Relay"}}},
		{"workspace-leave", input{Workspace: "w1"}, request{"DELETE", "/v1/workspaces/w1/membership", nil}},
	} {
		t.Run(tc.verb, func(t *testing.T) {
			data, why := call(t, h, tc.verb, tc.args)
			var got request
			if why != "" || json.Unmarshal(data, &got) != nil || !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %s (%s), want %+v", data, why, tc.want)
			}
		})
	}
	if _, why := call(t, h, "workspace-edit", input{Workspace: "w1"}); why != "nothing to change" {
		t.Errorf("empty edit: %q", why)
	}
	if _, why := call(t, h, "workspace-leave", input{Workspace: "w1/claims"}); why == "" {
		t.Error("accepted a workspace ID containing a path separator")
	}
	for _, verb := range []string{"admin-members", "workspace-combined"} {
		if !readOnlyVerbs[verb] {
			t.Errorf("%s is not read-only", verb)
		}
	}
}

func TestTrayClaimRefusalCarriesHolderFields(t *testing.T) {
	body := `{"error":"overlapping claim held by bob/w-7","holder":"bob/w-7","holderHandle":"bob","claim":"c9"}`
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		io.WriteString(w, body)
	}))
	t.Cleanup(relay.Close)
	s := identity.Session{User: "alice", ExpiresAt: time.Now().Add(time.Hour)}
	a := &Agent{cfg: Config{Relay: relay.URL}, http: relay.Client(), creds: credentials{Session: s}}
	h := a.Handler()
	for _, tc := range []struct {
		verb string
		in   input
	}{
		{"claim", input{Workspace: "w1", Kind: "issue", Key: "12", Holder: "alice/w-1"}},
		{"relay", input{Method: "POST", Path: "/v1/workspaces/w1/claims", Body: json.RawMessage(`{"kind":"issue","key":"12","holder":"alice/w-1"}`)}},
		{"relay", input{Method: "PUT", Path: "/v1/workspaces/w1/cards/k1", Body: json.RawMessage(`{"state":"done"}`)}},
	} {
		got := envelope(t, h, tc.verb, tc.in)
		if got["ok"] != false || got["holder"] != "bob" || got["agent"] != "w-7" || got["claim"] != "c9" || got["error"] != "relay HTTP 409: overlapping claim held by bob/w-7" {
			t.Fatalf("%s refusal: %+v", tc.verb, got)
		}
	}
	// Other conflicts carry no holder fields.
	body = `{"error":"an active device lease is required to claim work"}`
	got := envelope(t, h, "claim", input{Workspace: "w1", Kind: "issue", Key: "12", Holder: "alice/w-1"})
	if _, has := got["holder"]; has || got["ok"] != false {
		t.Fatalf("plain conflict: %+v", got)
	}
}

func TestTrayCombinedWorkspaceJoinsOwnClaims(t *testing.T) {
	expires := time.Date(2026, 11, 26, 6, 0, 0, 0, time.UTC)
	view := control.CombinedView{Workspace: "w1", Members: []control.CombinedMember{
		{Handle: "alice", Online: true, Workers: []control.CombinedWorker{
			{ID: "alice-agent", Name: "Alice worker", Resource: "alice-agent", Harness: "claude", Model: "opus", State: "online", Claims: []control.CombinedClaim{}},
			{ID: "idle-agent", Name: "Idle", Resource: "idle-agent", State: "offline", Claims: []control.CombinedClaim{}},
			{ID: "alice/w-42", Name: "w-42", Agent: "w-42", State: "working", Claims: []control.CombinedClaim{{ID: "c1", Kind: "paths", Key: "src", ExpiresAt: expires}}},
			{ID: "alice/w-99", Name: "w-99", Agent: "w-99", State: "working", Claims: []control.CombinedClaim{{ID: "c2", Kind: "issue", Key: "7", ExpiresAt: expires}}},
		}},
		{Handle: "bob", Workers: []control.CombinedWorker{
			{ID: "bob-agent", Name: "Bob worker", Resource: "bob-agent", State: "online", Claims: []control.CombinedClaim{}},
			{ID: "bob/w-42", Name: "w-42", Agent: "w-42", State: "working", Claims: []control.CombinedClaim{{ID: "c3", Kind: "issue", Key: "12", ExpiresAt: expires}}},
		}},
	}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/workspaces/w1/combined", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(view)
	})
	mux.HandleFunc("GET /v1/workspaces/w2/combined", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		io.WriteString(w, `{"error":"no workspace w2 in your groups"}`)
	})
	s := identity.Session{User: "alice", Device: "mac", ExpiresAt: time.Now().Add(time.Hour)}
	a := &Agent{cfg: Config{Dir: t.TempDir(), Relay: testRelayURL}, http: &http.Client{Transport: relayTransport{mux}}, creds: credentials{Session: s},
		policy: localPolicy{Resources: []actions.Resource{{ID: "alice-agent", Kind: "agent", Target: "w-42"}, {ID: "idle-agent", Kind: "agent", Target: "w-5"}}}}
	data, why := call(t, a.Handler(), "workspace-combined", input{Workspace: "w1"})
	var got control.CombinedView
	if why != "" || json.Unmarshal(data, &got) != nil {
		t.Fatalf("combined: %s (%s)", data, why)
	}
	alice := got.Members[0].Workers
	if len(alice) != 3 || alice[0].Agent != "w-42" || alice[0].State != "working" || len(alice[0].Claims) != 1 || alice[0].Claims[0].ID != "c1" ||
		alice[1].Agent != "w-5" || alice[1].State != "offline" || alice[2].ID != "alice/w-99" {
		t.Fatalf("own workers: %+v", alice)
	}
	// Another member's claim under the same worker name is not this device's worker.
	if bob := got.Members[1].Workers; len(bob) != 2 || bob[0].Agent != "" || bob[1].ID != "bob/w-42" {
		t.Fatalf("other member's workers: %+v", bob)
	}
	var raw struct {
		Members []struct{ Workers []map[string]any }
	}
	if json.Unmarshal(data, &raw) != nil || raw.Members[0].Workers[0]["checks"] != nil || raw.Members[0].Workers[0]["branch"] != "" {
		t.Fatalf("unavailable fields: %s", data)
	}
	if _, has := raw.Members[0].Workers[0]["checks"]; !has {
		t.Fatalf("checks key missing: %s", data)
	}
	if _, why := call(t, a.Handler(), "workspace-combined", input{Workspace: "w2"}); why != "no workspace w2 in your groups" {
		t.Fatalf("outsider refusal: %q", why)
	}
}

func TestTrayStatusListsOwnHostCommands(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "commands.json")
	if err := save(file, map[string]any{"commands": []actions.HostCommand{
		{Name: "test", Args: []string{"make", "test"}, Dir: dir, Environment: "macos"},
		{Name: "lint", Args: []string{"make", "lint"}, Dir: dir, AllowArgs: true},
	}}); err != nil {
		t.Fatal(err)
	}
	s := identity.Session{User: "alice", Device: "mac", ExpiresAt: time.Now().Add(time.Hour)}
	published := &control.Capabilities{Tools: []string{"build"}, Commands: []sharing.Command{{Name: "build"}}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/profile", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(control.User{User: "alice", Handle: "alice"})
	})
	mux.HandleFunc("GET /v1/friends", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, `{"friends":[]}`) })
	mux.HandleFunc("GET /v1/grants", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, `{"grants":[]}`) })
	mux.HandleFunc("GET /v1/resources", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"resources": []control.Resource{
			{ID: "studio", Owner: "alice", Device: "mac", Kind: "host", Name: "Studio", Handle: "alice", Actions: []string{"host.run"}},
			{ID: "old", Owner: "alice", Device: "mac", Kind: "host", Name: "Old", Handle: "alice", Actions: []string{"host.run"}, Capabilities: published},
			{ID: "bare", Owner: "alice", Device: "mac", Kind: "host", Name: "Bare", Handle: "alice", Actions: []string{"host.run"}},
		}})
	})
	a := &Agent{cfg: Config{Dir: dir, Relay: testRelayURL}, http: &http.Client{Transport: relayTransport{mux}}, creds: credentials{Session: s},
		policy: localPolicy{Resources: []actions.Resource{
			{ID: "studio", Name: "Studio", Kind: "host", Target: file},
			{ID: "old", Name: "Old", Kind: "host", Target: filepath.Join(dir, "missing.json")},
		}}}
	data, why := call(t, a.Handler(), "status", input{})
	var status struct {
		Resources []struct {
			ID           string
			Capabilities map[string]json.RawMessage
		}
	}
	if why != "" || json.Unmarshal(data, &status) != nil || len(status.Resources) != 3 {
		t.Fatalf("status: %s (%s)", data, why)
	}
	want := map[string]string{
		"studio": `[{"name":"test","allowArgs":false,"environment":"macos"},{"name":"lint","allowArgs":true}]`,
		"old":    `[{"name":"build","allowArgs":false}]`,
		"bare":   `[]`,
	}
	for _, r := range status.Resources {
		if got := string(r.Capabilities["commands"]); got != want[r.ID] {
			t.Errorf("%s commands: %s, want %s", r.ID, got, want[r.ID])
		}
	}
}
