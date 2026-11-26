package device

import (
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"slices"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
)

// Use the acceptance fixture's Commander identity proof without starting a relay or broker.
func coordinatorPeer(t *testing.T, a *Agent) *pilotPeer {
	t.Helper()
	p, socket := startPilotCommander(t, a.handle)
	a.cfg.CommanderSocket = socket
	p.agent, p.api = a, a.Handler()
	return p
}

func coordinatorWithRelay(t *testing.T, mux *http.ServeMux) *pilotPeer {
	t.Helper()
	return coordinatorPeer(t, &Agent{
		cfg: Config{Dir: t.TempDir(), Relay: testRelayURL}, http: &http.Client{Transport: relayTransport{mux}},
		handle: "alice", creds: credentials{Session: identity.Session{User: "alice-id", ExpiresAt: time.Now().Add(time.Hour)}},
	})
}

func TestCoordinatorOnline(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/friends", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"friends": []Friend{
			{User: "sam-id", Handle: "sam", DisplayName: "Sam", Status: "accepted", Online: true, Presence: "busy", StatusMessage: "Reviewing"},
			{User: "pat-id", Handle: "pat", Status: "incoming"},
		}})
	})
	mux.HandleFunc("GET /v1/resources", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"resources": []control.Resource{
			{ID: "mine", Owner: "alice-id"},
			{ID: "sam-worker", Owner: "sam-id", Name: "Reviewer", Kind: "agent", Actions: []string{"agent.ask", "agent.watch"}},
			{ID: "pat-worker", Owner: "pat-id"},
		}})
	})
	p := coordinatorWithRelay(t, mux)
	var got struct {
		Friends []struct {
			Friend
			Resources []control.Resource
		}
	}
	p.must(t, t.Context(), "/coordinator/online", struct{}{}, &got)
	if len(got.Friends) != 1 {
		t.Fatalf("online friends = %+v", got.Friends)
	}
	f := got.Friends[0]
	if f.Handle != "sam" || f.DisplayName != "Sam" || !f.Online || f.Presence != "busy" || f.StatusMessage != "Reviewing" {
		t.Errorf("online friend = %+v", f)
	}
	if len(f.Resources) != 1 {
		t.Fatalf("resources shared by sam = %+v", f.Resources)
	}
	if r := f.Resources[0]; r.ID != "sam-worker" || r.Name != "Reviewer" || r.Kind != "agent" || !slices.Equal(r.Actions, []string{"agent.ask", "agent.watch"}) {
		t.Errorf("shared worker = %+v", r)
	}
}

func TestCoordinatorBoard(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/workspaces", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"workspaces":[{"id":"space"}]}`)
	})
	const cards = "/v1/workspaces/space/cards"
	mux.HandleFunc("GET "+cards, func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"cards":[{"id":"card","state":"open"}]}`)
	})
	mux.HandleFunc("GET "+cards+"/card", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"id":"card","state":"done","result":"Tests passed."}`)
	})
	mux.HandleFunc("PUT "+cards+"/card", func(w http.ResponseWriter, r *http.Request) {
		var changes map[string]string
		if err := json.NewDecoder(r.Body).Decode(&changes); err != nil {
			t.Errorf("decode update: %v", err)
			http.Error(w, "invalid card update", http.StatusBadRequest)
			return
		}
		changes["id"] = "card"
		json.NewEncoder(w).Encode(changes)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("unexpected board request to relay: %s %s", r.Method, r.URL)
		http.NotFound(w, r)
	})
	p := coordinatorWithRelay(t, mux)
	for _, tc := range []struct {
		name string
		in   boardInput
		want any
	}{
		{"workspaces", boardInput{}, map[string]any{"workspaces": []any{map[string]any{"id": "space"}}}},
		{"cards", boardInput{Op: "list", Workspace: "space"}, map[string]any{"cards": []any{map[string]any{"id": "card", "state": "open"}}}},
		{"claim", boardInput{Op: "claim", Workspace: "space", Card: "card"}, map[string]any{"id": "card", "state": "claimed", "assignee": "alice/" + p.actor}},
		{"complete", boardInput{Op: "complete", Workspace: "space", Card: "card", Result: "Tests passed."}, map[string]any{"id": "card", "state": "done", "result": "Tests passed."}},
		{"comment", boardInput{Op: "comment", Workspace: "space", Card: "card", Text: "Verified."}, map[string]any{"id": "card", "result": "Tests passed.\n[alice/" + p.actor + "] Verified."}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var got any
			p.must(t, t.Context(), "/coordinator/board", tc.in, &got)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("board response = %+v, want %+v", got, tc.want)
			}
		})
	}
	for _, tc := range []struct {
		name string
		in   boardInput
	}{
		{"invalid workspace", boardInput{Op: "list", Workspace: "bad/space"}},
		{"invalid card", boardInput{Op: "claim", Workspace: "space", Card: "bad/card"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, why := p.call(t, t.Context(), "/coordinator/board", tc.in); why == "" {
				t.Errorf("accepted invalid board input %+v", tc.in)
			}
		})
	}
}
