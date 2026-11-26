package device

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
)

func TestTrayResourceAndGrantRoundTrip(t *testing.T) {
	// Exercise the device's real worker-info request. Keep the socket path short on macOS.
	socket := filepath.Join("/tmp", "ac-share-"+newID()[:10]+".sock")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	commander := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/ag-ui/workers/worker" || r.Method != "GET" {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"workerId": "worker", "role": "worker", "client": "Claude Code", "model": "worker-model"})
	})}
	go commander.Serve(ln)
	t.Cleanup(func() { commander.Close() })

	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/profile", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(control.User{User: "alice", Handle: "alice"})
	})
	mux.HandleFunc("GET /v1/friends", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"friends": []Friend{}})
	})
	mux.HandleFunc("GET /v1/users/bob", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(control.User{User: "bob", Handle: "bob"})
	})
	var own control.Resource
	mux.HandleFunc("PUT /v1/resources/agent", func(w http.ResponseWriter, r *http.Request) {
		own = control.Resource{ID: "agent", Device: "mac", Owner: "alice", Handle: "alice"}
		if err := json.NewDecoder(r.Body).Decode(&own); err != nil {
			t.Error(err)
		}
	})
	mux.HandleFunc("GET /v1/resources", func(w http.ResponseWriter, _ *http.Request) {
		shared := control.Resource{ID: "other-agent", Device: "other-mac", Owner: "bob", Handle: "bob", Kind: "agent", Capabilities: &control.Capabilities{Harness: "codex"}}
		json.NewEncoder(w).Encode(map[string]any{"resources": []control.Resource{own, shared}, "directory": []control.DirectoryResource{{Resource: shared}}})
	})
	var grants []control.Grant
	mux.HandleFunc("GET /v1/grants", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"grants": grants})
	})
	mux.HandleFunc("PUT /v1/grants/agent/bob", func(w http.ResponseWriter, r *http.Request) {
		g := control.Grant{Resource: "agent", Grantee: "bob", Handle: "bob", Owner: "alice", Device: "mac"}
		if err := json.NewDecoder(r.Body).Decode(&g); err != nil {
			t.Error(err)
		}
		for _, limit := range g.Limits {
			g.Actions = append(g.Actions, limit.Action)
			if g.ExpiresAt.Before(limit.ExpiresAt) {
				g.ExpiresAt = limit.ExpiresAt
			}
			g.MaxUses += limit.MaxUses
		}
		grants = []control.Grant{g}
	})
	relay := httptest.NewServer(mux)
	t.Cleanup(relay.Close)
	s := identity.Session{User: "alice", Device: "mac", ExpiresAt: time.Now().Add(time.Hour)}
	a := &Agent{cfg: Config{Dir: t.TempDir(), Relay: relay.URL, CommanderSocket: socket}, http: relay.Client(), creds: credentials{Session: s}}
	h := a.Handler()
	trayCall := func(verb string, in any) json.RawMessage {
		t.Helper()
		data, why := call(t, h, verb, in)
		if why != "" {
			t.Fatalf("%s: %s", verb, why)
		}
		return data
	}
	slots := 2
	caps := &control.Capabilities{Slots: &slots, Tools: []string{"git"}, Environments: []string{"gpu"}}
	trayCall("resource-add", input{ID: "agent", Name: "Agent", Kind: "agent", Target: "worker", Capabilities: caps})
	want := *caps
	want.Harness, want.Model = "claude", "worker-model"
	if !reflect.DeepEqual(own.Capabilities, &want) {
		t.Fatalf("published capabilities: %+v, want %+v", own.Capabilities, want)
	}
	trayCall("resource-update", input{ID: "agent", Capabilities: &control.Capabilities{Harness: "other", Model: "owner-model", Tools: []string{}}})
	want.Harness, want.Model, want.Tools = "other", "owner-model", []string{}
	if !reflect.DeepEqual(own.Capabilities, &want) {
		t.Fatalf("updated capabilities: %+v, want %+v", own.Capabilities, want)
	}
	trayCall("resource-add", input{ID: "agent", Name: "Agent", Kind: "agent", Target: "worker"})
	if !reflect.DeepEqual(own.Capabilities, &want) {
		t.Fatalf("re-enrolling overwrote owner settings: %+v", own.Capabilities)
	}

	trayCall("grant", input{Resource: "agent", Handle: "bob", Capability: "agent.ask", MaxUses: 3, Approval: "auto", BudgetTokens: 70, Attribution: "requester"})
	trayCall("grant", input{Resource: "agent", Handle: "bob", Capability: "agent.handoff", MaxUses: 1})
	if len(grants) != 1 || len(grants[0].Limits) != 2 {
		t.Fatalf("published grants: %+v", grants)
	}
	limits := grants[0].Limits
	if limits[0].Approval != "auto" || limits[0].BudgetTokens != 70 || limits[0].Attribution != "requester" ||
		limits[1].Approval != "ask" || limits[1].BudgetTokens != 0 || limits[1].Attribution != "owner" {
		t.Fatalf("published grant limits: %+v", limits)
	}
	if err := a.loadPolicy(s.User); err != nil {
		t.Fatal(err)
	}
	if len(a.policy.Grants) != 2 || a.policy.Grants[0].Approval != "auto" || a.policy.Grants[0].BudgetTokens != 70 ||
		a.policy.Grants[0].Attribution != "requester" || a.policy.Grants[1].Approval != "ask" || a.policy.Grants[1].Attribution != "owner" {
		t.Fatalf("persisted grant policy: %+v", a.policy.Grants)
	}
	// A stricter published budget and a relay-only action are display data.
	grants[0].Limits[0].BudgetTokens = 65
	grants[0].Actions = append(grants[0].Actions, "agent.suggest")
	grants[0].Limits = append(grants[0].Limits, control.LimitUsage{Limit: control.Limit{
		Action: "agent.suggest", MaxUses: 1, ExpiresAt: s.ExpiresAt, Approval: "auto", Attribution: "owner",
	}})
	var status struct {
		Resources, Shared, Directory []control.Resource
		Grants                       []trayGrant
	}
	if err := json.Unmarshal(trayCall("status", input{}), &status); err != nil {
		t.Fatal(err)
	}
	if len(status.Resources) != 1 || !reflect.DeepEqual(status.Resources[0].Capabilities, &want) ||
		len(status.Shared) != 1 || len(status.Directory) != 1 || status.Shared[0].Capabilities == nil || status.Shared[0].Capabilities.Harness != "codex" ||
		!reflect.DeepEqual(status.Shared[0].Capabilities, status.Directory[0].Capabilities) {
		t.Fatalf("status resources: %+v", status)
	}
	if len(status.Grants) != 3 || status.Grants[0].Approval != "auto" || status.Grants[0].BudgetTokens != 65 || status.Grants[0].Attribution != "requester" ||
		status.Grants[1].Approval != "ask" || status.Grants[1].Attribution != "owner" || status.Grants[1].MaxUses != 1 || status.Grants[2].Approval != "auto" {
		t.Fatalf("status grant limits: %+v", status.Grants)
	}
	if err := a.loadPolicy(s.User); err != nil {
		t.Fatal(err)
	}
	if len(a.policy.Published) != 3 || a.policy.Published[0].BudgetTokens != 65 || a.policy.Published[2].Capability != "agent.suggest" {
		t.Fatalf("relay display limits were not persisted: %+v", a.policy.Published)
	}
	enforced := a.localConfig(s).Grants
	if len(enforced) != 2 || enforced[0].BudgetTokens != 70 || enforced[1].Action != "agent.handoff" {
		t.Fatalf("relay display limits changed local authorization: %+v", enforced)
	}
	before, err := os.Stat(a.policyPath(s.User))
	if err != nil {
		t.Fatal(err)
	}
	trayCall("status", input{})
	after, err := os.Stat(a.policyPath(s.User))
	if err != nil || !os.SameFile(before, after) {
		t.Fatalf("unchanged status replaced the persisted policy: %v", err)
	}
	legacy := &grants[0].Limits[0]
	legacy.Approval, legacy.Attribution, legacy.BudgetTokens = "", "", 0
	if err := json.Unmarshal(trayCall("status", input{}), &status); err != nil {
		t.Fatal(err)
	}
	if got := status.Grants[0]; got.Approval != "auto" || got.Attribution != "requester" || got.BudgetTokens != 70 {
		t.Fatalf("older relay hid the owner's local settings: %+v", got)
	}

	// Simulate a local grant predating the explicit usage ID. Editing its
	// expiry must retain its receipt ledger, even across a device restart.
	a.policy.Grants[0].UsageID = ""
	ledger := a.policy.Grants[0].ReceiptKey()
	edit := input{Handle: "bob", Resource: "agent", Capability: "agent.ask", Approval: "auto",
		MaxUses: 10, BudgetTokens: 100, ExpiresAt: time.Now().Add(48 * time.Hour)}
	trayCall("grant", edit)
	if err := a.loadPolicy(s.User); err != nil {
		t.Fatal(err)
	}
	ask := a.policy.Grants[1]
	if ask.Action != "agent.ask" || ask.ReceiptKey() != ledger {
		t.Fatalf("editing the grant reset its receipt ledger: %+v", ask)
	}
	trayCall("revoke", input{ID: ask.ID})
	trayCall("grant", edit)
	if ask := a.policy.Grants[1]; ask.Action != "agent.ask" || ask.ReceiptKey() == ledger {
		t.Fatalf("a new grant inherited the revoked grant's ledger: %+v", ask)
	}
}
