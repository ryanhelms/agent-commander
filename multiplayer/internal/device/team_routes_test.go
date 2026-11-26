package device

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/identity"
)

func TestNamedTeamRelayRoutes(t *testing.T) {
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
	create := map[string]string{"name": "Release", "goal": "Ship", "repository": "repo", "base": "main", "integration": "queue", "group": "g1"}
	claim := map[string]string{"kind": "paths", "key": "src", "holder": "alice/agent"}
	for _, tc := range []struct {
		verb string
		args any
		want request
	}{
		{"groups", input{}, request{"GET", "/v1/groups", nil}},
		{"group-create", map[string]string{"name": "Core"}, request{"POST", "/v1/groups", map[string]string{"name": "Core"}}},
		{"group-add", input{Group: "g1", Handle: "bob"}, request{"PUT", "/v1/groups/g1/members/bob", nil}},
		{"group-remove", input{Group: "g1", Handle: "bob"}, request{"DELETE", "/v1/groups/g1/members/bob", nil}},
		{"group-delete", input{ID: "g1"}, request{"DELETE", "/v1/groups/g1", nil}},
		{"workspaces", input{}, request{"GET", "/v1/workspaces", nil}},
		{"workspace-create", create, request{"POST", "/v1/workspaces", create}},
		{"claim", input{Workspace: "w1", Kind: "paths", Key: "src", Holder: "alice/agent"}, request{"POST", "/v1/workspaces/w1/claims", claim}},
		{"release", input{Workspace: "w1", Claim: "c1"}, request{"DELETE", "/v1/workspaces/w1/claims/c1", nil}},
		{"knowledge", input{}, request{"GET", "/v1/knowledge", nil}},
		{"relay", input{Method: "GET", Path: "/v1/info"}, request{"GET", "/v1/info", nil}},
	} {
		t.Run(tc.verb, func(t *testing.T) {
			data, why := call(t, h, tc.verb, tc.args)
			var got request
			if why != "" || json.Unmarshal(data, &got) != nil || !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %s (%s), want %+v", data, why, tc.want)
			}
		})
	}
	for _, in := range []input{{Method: "POST", Path: "/v1/info"}, {Method: "PUT", Path: "/v1/info"}, {Method: "DELETE", Path: "/v1/info"}, {Method: "GET", Path: "/v1/info/private"}} {
		if _, why := call(t, h, "relay", in); why == "" {
			t.Errorf("allowed %s %s", in.Method, in.Path)
		}
	}
	if _, why := call(t, h, "group-add", input{Group: "g1/members", Handle: "bob"}); why == "" {
		t.Error("accepted a group ID containing a path separator")
	}
}

func TestTrayClaimConflictNamesHolder(t *testing.T) {
	for _, message := range []string{"", "overlapping claim", "overlapping claim held by bob/agent"} {
		relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusConflict)
			json.NewEncoder(w).Encode(map[string]string{"error": message, "holder": "bob/agent"})
		}))
		t.Cleanup(relay.Close)
		s := identity.Session{User: "alice", ExpiresAt: time.Now().Add(time.Hour)}
		a := &Agent{cfg: Config{Relay: relay.URL}, http: relay.Client(), creds: credentials{Session: s}}
		_, why := call(t, a.Handler(), "claim", input{Workspace: "w1", Kind: "issue", Key: "42", Holder: "alice/agent"})
		if !strings.Contains(why, "409") || strings.Count(why, "held by bob/agent") != 1 {
			t.Fatalf("conflict for %q: %s", message, why)
		}
	}
}

func TestTrayTeamRefusals(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/grants", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"grants":[]}`)
	})
	mux.HandleFunc("PUT /v1/groups/core/members/nobody", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		io.WriteString(w, `{"error":"nobody is not your friend"}`)
	})
	mux.HandleFunc("POST /v1/workspaces", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, `{"error":"integration must be queue or pull_request"}`)
	})
	s := identity.Session{User: "alice", Device: "mac", ExpiresAt: time.Now().Add(time.Hour)}
	a := &Agent{cfg: Config{Dir: t.TempDir(), Relay: testRelayURL}, http: &http.Client{Transport: relayTransport{mux}}, creds: credentials{Session: s}}
	for _, tc := range []struct {
		verb  string
		input any
		want  string
	}{
		{"group-add", input{Group: "core", Handle: "nobody"}, "nobody is not your friend"},
		{"grant", map[string]any{"group": "core", "resource": "missing", "actions": []string{"agent.ask"}}, "no resource missing"},
		{"grant", input{Group: "core", Resource: "missing", Capability: "agent.ask"}, "no resource missing"},
		{"workspace-create", input{Integration: "invalid"}, "integration must be queue or pull_request"},
	} {
		if _, why := call(t, a.Handler(), tc.verb, tc.input); why != tc.want {
			t.Errorf("%s: got %q, want %q", tc.verb, why, tc.want)
		}
	}
}

func TestTrayCanReadPublicPolicyBeforeLogin(t *testing.T) {
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/v1/info" || r.Header.Get("Authorization") != "" {
			t.Errorf("unexpected public info request: %s %s", r.Method, r.URL.Path)
		}
		io.WriteString(w, `{"policy":{"knowledgeWidest":"group"}}`)
	}))
	t.Cleanup(relay.Close)
	a := &Agent{cfg: Config{Relay: relay.URL}, http: relay.Client()}
	data, why := call(t, a.Handler(), "relay", input{Method: "GET", Path: "/v1/info"})
	var info struct {
		Policy struct{ KnowledgeWidest string }
	}
	if why != "" || json.Unmarshal(data, &info) != nil || info.Policy.KnowledgeWidest != "group" {
		t.Fatalf("public policy: %s (%s)", data, why)
	}
}
