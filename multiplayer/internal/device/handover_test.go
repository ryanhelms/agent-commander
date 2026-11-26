package device

import (
	"encoding/json"
	"net/http"
	"testing"
	"testing/synctest"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
)

func serveHandoverProfiles(mux *http.ServeMux, users ...Friend) {
	var friends []Friend
	for _, u := range users {
		mux.HandleFunc("GET /v1/users/"+u.Handle, func(w http.ResponseWriter, _ *http.Request) {
			json.NewEncoder(w).Encode(u)
		})
		if u.Status != "" {
			friends = append(friends, u)
		}
	}
	mux.HandleFunc("GET /v1/friends", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"friends": friends})
	})
}

func TestHandoverRequiresGrantedFriendAndEndsOnHandbackOrExpiry(t *testing.T) {
	mux := http.NewServeMux()
	serveHandoverProfiles(mux, Friend{User: "owner-id", Handle: "owner"},
		Friend{User: "stranger-id", Handle: "stranger"}, Friend{User: "pending-id", Handle: "pending", Status: "incoming"},
		Friend{User: "sam-id", Handle: "sam", Status: "accepted"})
	client := &http.Client{Transport: relayTransport{mux}}
	newOwner := func(grants []actions.Grant) *pilotPeer {
		a := &Agent{cfg: Config{Relay: testRelayURL, ServerID: "office"}, http: client,
			creds: credentials{Session: identity.Session{User: "owner-id", ExpiresAt: time.Now().Add(time.Hour)}}, policy: localPolicy{Grants: grants}}
		return &pilotPeer{agent: a, api: a.Handler()}
	}
	type holder struct {
		User, Handle, Resource, Server string
		Until                          time.Time
	}
	list := func(t *testing.T, tray *pilotPeer) []holder {
		t.Helper()
		var out struct{ Handovers []holder }
		tray.must(t, t.Context(), "/tray/handovers", input{}, &out)
		return out.Handovers
	}
	grant := func(peer, resource, action string) actions.Grant {
		return actions.Grant{Peer: peer, Resource: resource, Action: action, ExpiresAt: time.Now().Add(time.Hour)}
	}
	expired := grant("sam-id", "agent", "agent.ask")
	expired.ExpiresAt = time.Now().Add(-time.Minute)
	for _, tc := range []struct {
		name, handle string
		grants       []actions.Grant
	}{
		{"self", "owner", []actions.Grant{grant("owner-id", "agent", "agent.ask")}},
		{"non-friend with stale grant", "stranger", []actions.Grant{grant("stranger-id", "agent", "agent.ask")}},
		{"pending friend with grant", "pending", []actions.Grant{grant("pending-id", "agent", "agent.suggest")}},
		{"no grant", "sam", nil},
		{"different action", "sam", []actions.Grant{grant("sam-id", "agent", "agent.watch")}},
		{"different resource", "sam", []actions.Grant{grant("sam-id", "other-agent", "agent.suggest")}},
		{"different friend", "sam", []actions.Grant{grant("stranger-id", "agent", "agent.ask")}},
		{"expired grant", "sam", []actions.Grant{expired}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tray := newOwner(tc.grants)
			if _, why := tray.call(t, t.Context(), "/tray/handover", input{Handle: tc.handle, Resource: "agent", Minutes: 5}); why == "" {
				t.Fatalf("handed control to %s with grants %+v", tc.handle, tc.grants)
			}
			if rows := list(t, tray); len(rows) != 0 {
				t.Fatalf("rejected handover listed holders %+v", rows)
			}
		})
	}

	for _, tc := range []struct{ action, end string }{
		{"agent.ask", "sam"}, {"agent.suggest", "sam-id"}, {"agent.ask", "expiry"},
	} {
		t.Run(tc.action+"/"+tc.end, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				tray := newOwner([]actions.Grant{grant("sam-id", "agent", tc.action)})
				before := time.Now()
				tray.must(t, t.Context(), "/tray/handover", input{Handle: "sam", Resource: "agent", Minutes: 5}, nil)
				rows := list(t, tray)
				if len(rows) != 1 {
					t.Fatalf("want one holder, got %+v", rows)
				}
				row := rows[0]
				if row.User != "sam-id" || row.Handle != "sam" || row.Resource != "agent" || row.Server != "office" ||
					!row.Until.Equal(before.Add(5*time.Minute)) {
					t.Fatalf("unexpected holder %+v", row)
				}
				if tc.end == "expiry" {
					time.Sleep(5*time.Minute + time.Second)
				} else {
					tray.must(t, t.Context(), "/tray/handback", input{Handle: tc.end, Resource: "agent"}, nil)
				}
				if rows := list(t, tray); len(rows) != 0 {
					t.Fatalf("holders after %s: %+v", tc.end, rows)
				}
				if _, exists := tray.agent.handovers["sam-id|agent"]; exists {
					t.Fatalf("holder still stored after %s", tc.end)
				}
			})
		})
	}
}

func TestSuggestQueuesForOwnerExceptDuringMatchingHandover(t *testing.T) {
	ownerKeys, owner := makeDevicePeer(t, "owner-id")
	friendKeys, friend := makeDevicePeer(t, "sam-id")
	commander, socket := startPilotCommander(t, "owner")
	mux := http.NewServeMux()
	serveHandoverProfiles(mux, Friend{User: friend.User, Handle: "sam", Status: "accepted"})
	mux.HandleFunc("GET /v1/identity/devices/"+friend.Device, func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(friend)
	})
	mux.HandleFunc("POST /v1/children/{id}/claim", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]bool{"claimed": true})
	})
	receipts := map[string]json.RawMessage{}
	mux.HandleFunc("PUT /v1/children/{id}/receipt", func(w http.ResponseWriter, r *http.Request) {
		var receipt ack
		if err := json.NewDecoder(r.Body).Decode(&receipt); err != nil || receipt.Status != "completed" {
			t.Errorf("unexpected %s receipt: %+v, %v", r.PathValue("id"), receipt, err)
		}
		id := r.PathValue("id")
		if _, ok := receipts[id]; ok {
			t.Errorf("unexpected extra receipt for %s", id)
		}
		receipts[id] = receipt.Result
	})
	client := &http.Client{Transport: relayTransport{mux}}
	until := time.Now().Add(time.Hour)
	s := identity.Session{User: owner.User, Device: owner.Device, ExpiresAt: until}
	a := &Agent{ctx: t.Context(), cfg: Config{Dir: t.TempDir(), Relay: testRelayURL, CommanderSocket: socket, ServerID: "office"},
		http: client, identity: identity.Client{BaseURL: testRelayURL, HTTP: client}, keys: ownerKeys,
		creds: credentials{Session: s}, handovers: map[string]time.Time{
			"sam-id|agent": time.Now().Add(-time.Minute), "sam-id|another-agent": until, "another-friend|agent": until,
		},
		policy: localPolicy{
			Pins:      map[string]devicekeys.Public{friend.Device: friend},
			Resources: []actions.Resource{{ID: "agent", Kind: "agent", Target: commander.worker}},
			Grants:    []actions.Grant{{Peer: friend.User, Resource: "agent", Action: "agent.suggest", ExpiresAt: until}},
		}}
	tray := &pilotPeer{api: a.Handler()}
	const suggestion = `{"text":"Run the focused tests."}`
	for _, tc := range []struct {
		id, mode string
		handover bool
	}{
		{"default-grant", "", false}, {"ask-grant", "ask", false}, {"auto-grant", "auto", false},
		{"during-handover", "ask", true}, {"after-handback", "auto", false},
	} {
		t.Run(tc.id, func(t *testing.T) {
			a.policy.Grants[0].Approval = tc.mode
			if tc.handover {
				tray.must(t, t.Context(), "/tray/handover", input{Handle: "sam", Resource: "agent", Minutes: 5}, nil)
				defer tray.must(t, t.Context(), "/tray/handback", input{Handle: "sam", Resource: "agent"}, nil)
			}
			child := control.Child{Addressed: control.Addressed{ID: tc.id, Resource: "agent", Action: "agent.suggest", Device: owner.Device, ExpiresAt: until},
				Owner: owner.User, Sender: friend.User, SenderDevice: friend.Device}
			var err error
			child.Envelope, err = friendKeys.Seal(owner, header(child, "request"), json.RawMessage(suggestion))
			if err != nil {
				t.Fatal(err)
			}
			before := commander.turns.Load()
			if err := a.deliver(t.Context(), s, control.Lease{}, child); err != nil {
				t.Fatal(err)
			}
			var list struct{ Approvals []Approval }
			tray.must(t, t.Context(), "/tray/approvals", input{}, &list)
			if tc.handover {
				if len(list.Approvals) != 0 {
					t.Fatalf("suggestion waited for approval during handover: %+v", list.Approvals)
				}
			} else {
				if len(list.Approvals) != 1 || commander.turns.Load() != before || receipts[child.ID] != nil {
					t.Fatalf("expected a queued suggestion before any worker turn: %+v, turns %d", list.Approvals, commander.turns.Load()-before)
				}
				row := list.Approvals[0]
				if row.ID != child.ID || row.Peer != friend.User || row.Handle != "sam" || row.Action != child.Action || row.Summary != suggestion {
					t.Fatalf("unexpected approval %+v", row)
				}
				tray.must(t, t.Context(), "/tray/approve", input{ID: child.ID}, nil)
			}
			if commander.turns.Load() != before+1 {
				t.Fatalf("expected one worker turn, got %d", commander.turns.Load()-before)
			}
			raw, err := friendKeys.Open(owner, header(child, "result"), receipts[child.ID])
			var answer struct {
				Status string
				Value  struct{ Text string }
			}
			if err != nil || json.Unmarshal(raw, &answer) != nil || answer.Status != "completed" || answer.Value.Text != "answer from owner" {
				t.Fatalf("unexpected suggestion result %s, %v", raw, err)
			}
		})
	}
}
