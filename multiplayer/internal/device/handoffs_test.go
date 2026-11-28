package device

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
)

func TestApprovalsAndReceivedThreads(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/v1/friends" {
			t.Errorf("unexpected relay request: %s", req.URL)
		}
		json.NewEncoder(w).Encode(map[string]any{"friends": []Friend{{User: "peer-id", Handle: "sam"}}})
	}))
	defer server.Close()
	a := &Agent{cfg: Config{Dir: t.TempDir(), ServerID: "s-office", Relay: server.URL}, http: server.Client(),
		creds: credentials{Session: identity.Session{User: "me", ExpiresAt: time.Now().Add(time.Hour)}}, handle: "owner",
		pending: map[string]claimedRequest{"waiting": {
			child:   control.Child{Addressed: control.Addressed{ID: "waiting", Resource: "agent", Action: "agent.ask"}, Owner: "me", Sender: "peer-id"},
			arrived: time.Now(), payload: []byte(`{"text":"question"}`),
		}}}
	h := a.Handler()
	raw, err := call(t, h, "approvals", input{})
	var list struct{ Approvals []Approval }
	if err != "" || json.Unmarshal(raw, &list) != nil || len(list.Approvals) != 1 {
		t.Fatalf("approvals: %s %s", raw, err)
	}
	row := list.Approvals[0]
	if row.Server != "s-office" || row.Friend != "sam" || row.Handle != "sam" || row.Peer != "peer-id" {
		t.Fatalf("peer and server on approval: %+v", row)
	}
	_, err = call(t, h, "comment", input{Request: "unknown", Text: "no such thread"})
	if err == "" {
		t.Fatal("unknown request accepted a comment")
	}
	if _, err := os.Stat(filepath.Join(a.cfg.Dir, key("me"), "threads")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("comment on unknown request created a thread directory: %v", err)
	}
	if _, err = call(t, h, "comment", input{Request: "waiting", Text: "looking into it"}); err != "" {
		t.Fatalf("pending request rejected a comment: %s", err)
	}
	delete(a.pending, "waiting")
	a.record(AuditEntry{Request: "waiting", Peer: "peer-id", Resource: "agent", Action: "agent.ask", Recipient: "me"})
	if _, err = call(t, h, "comment", input{Request: "waiting", Text: "answered"}); err != "" {
		t.Fatalf("received request rejected a comment: %s", err)
	}
	raw, err = call(t, h, "thread", input{Request: "waiting"})
	if err != "" || !strings.Contains(string(raw), "looking into it") || !strings.Contains(string(raw), "answered") {
		t.Fatalf("thread after approval: %s %s", raw, err)
	}
	if a.receivedRequest("another-user", "", "", "waiting") || a.receivedRequest("me", "another-peer", "agent", "waiting") {
		t.Fatal("received request matched a different user or peer")
	}
}

func makeDevicePeer(t *testing.T, user string) (*devicekeys.Keys, devicekeys.Public) {
	t.Helper()
	keys, err := devicekeys.Generate()
	if err != nil {
		t.Fatal(err)
	}
	public, err := keys.Public()
	if err != nil {
		t.Fatal(err)
	}
	public.User = user
	return keys, public
}

const testRelayURL = "https://relay.test"

// relayTransport runs the relay handler synchronously, including identity lookups.
type relayTransport struct{ http.Handler }

func (rt relayTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Body != nil {
		defer r.Body.Close()
	}
	w := httptest.NewRecorder()
	rt.ServeHTTP(w, r)
	return w.Result(), nil
}

// newRequester exercises the device's real submission and receipt paths. The
// friend's resources share a device that opens each request and signs its answer.
func newRequester(t *testing.T, resources []control.Resource, pendingFirstRead bool, answer func(control.Child, json.RawMessage) any) *Agent {
	t.Helper()
	localKeys, local := makeDevicePeer(t, "my-user-id")
	friendKeys, friend := makeDevicePeer(t, "friend-user-id")
	for i := range resources {
		resources[i].Owner, resources[i].Device = friend.User, friend.Device
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/friends", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"friends": []Friend{{User: friend.User, Handle: "sam", Status: "accepted"}}})
	})
	mux.HandleFunc("GET /v1/identity/devices/"+friend.Device, func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(friend)
	})
	mux.HandleFunc("GET /v1/resources", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"resources": resources})
	})
	completed := map[string]control.Submission{}
	processing := map[string]control.Submission{}
	mux.HandleFunc("POST /v1/submissions", func(w http.ResponseWriter, r *http.Request) {
		var submitted outbound
		if err := json.NewDecoder(r.Body).Decode(&submitted); err != nil {
			t.Fatal(err)
		}
		pending := control.Submission{ID: submitted.ID}
		done := control.Submission{ID: submitted.ID}
		for _, target := range submitted.Children {
			c := control.Child{Addressed: target, Parent: submitted.ID, Status: "processing",
				Sender: local.User, SenderDevice: local.Device, Owner: friend.User}
			pending.Children = append(pending.Children, c)
			payload, err := friendKeys.Open(local, header(c, "request"), c.Envelope)
			if err != nil {
				t.Fatalf("open %s request: %v", c.Action, err)
			}
			c.Status = "completed"
			signed, err := json.Marshal(map[string]any{"status": c.Status, "value": answer(c, payload)})
			if err != nil {
				t.Fatal(err)
			}
			c.Result, err = friendKeys.Seal(local, header(c, "result"), signed)
			if err != nil {
				t.Fatalf("seal %s result: %v", c.Action, err)
			}
			done.Children = append(done.Children, c)
		}
		completed[submitted.ID] = done
		if pendingFirstRead {
			processing[submitted.ID] = pending
		}
		json.NewEncoder(w).Encode(pending)
	})
	mux.HandleFunc("GET /v1/submissions/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if p, ok := processing[id]; ok {
			delete(processing, id)
			json.NewEncoder(w).Encode(p)
			return
		}
		s, ok := completed[id]
		if !ok {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(s)
	})
	client := &http.Client{Transport: relayTransport{mux}}
	return &Agent{cfg: Config{Dir: t.TempDir(), ServerID: "s-test", Relay: testRelayURL}, http: client, keys: localKeys,
		identity: identity.Client{BaseURL: testRelayURL, HTTP: client}, policy: localPolicy{Pins: map[string]devicekeys.Public{}},
		creds: credentials{Session: identity.Session{User: local.User, Device: local.Device, ExpiresAt: time.Now().Add(time.Hour)}}}
}

func TestHandoffRowsAndApplyArtifact(t *testing.T) {
	const updated = "2026-11-21T11:42:00Z"
	resources := []control.Resource{{ID: "shared", Actions: []string{"agent.handoff", "agent.result"}}}
	a := newRequester(t, resources, true, func(c control.Child, body json.RawMessage) any {
		value := map[string]any{"run": "assigned-run", "state": "running"}
		if c.Action == "agent.result" {
			var target struct{ Run string }
			if json.Unmarshal(body, &target) != nil || target.Run == "" {
				t.Fatalf("missing run in %s", body)
			}
			value["run"], value["state"], value["updatedAt"] = target.Run, "done", updated
			value["artifacts"] = []map[string]string{
				{"kind": "report", "name": "docs/notes.md", "content": "friend's report"},
				{"kind": "file", "name": "Makefile", "content": "friend's file"},
				{"kind": "branch", "name": "fix-worker"},
			}
			if target.Run != "assigned-run" {
				value["state"], value["artifacts"] = "unrelated", []any{}
			}
		}
		return value
	})
	h := a.Handler()
	send := func(action, name, payload string) string {
		t.Helper()
		data, err := call(t, h, "send", input{Capability: action, Resource: "shared", Name: name, Payload: json.RawMessage(payload)})
		var row struct{ Request, Status string }
		if err != "" || json.Unmarshal(data, &row) != nil || row.Request == "" || row.Status != "completed" {
			t.Fatalf("send %s: %s %s", action, data, err)
		}
		return row.Request
	}
	handoff := send("agent.handoff", "Fix worker", `{"task":"fix worker","title":"Fix worker"}`)
	result := send("agent.result", "", `{"run":"assigned-run"}`)
	send("agent.result", "", `{"run":"another-run"}`)
	raw, err := call(t, h, "handoffs", input{})
	var list struct {
		Handoffs []struct{ ID, Server, Handle, Friend, Title, State, UpdatedAt string }
	}
	if err != "" || json.Unmarshal(raw, &list) != nil || len(list.Handoffs) != 1 {
		t.Fatalf("handoffs: %s %s", raw, err)
	}
	for _, milestone := range []string{"deliveredAt", "acceptedAt", "verifiedAt"} {
		if strings.Contains(string(raw), milestone) {
			t.Fatalf("legacy receipt projected %s: %s", milestone, raw)
		}
	}
	row := list.Handoffs[0]
	if row.ID != handoff || row.Server != "s-test" || row.Handle != "sam" || row.Friend != "sam" || row.State != "done" || row.UpdatedAt != updated || row.Title != "Fix worker" {
		t.Fatalf("handoff row: %+v", row)
	}
	dir := t.TempDir()
	if e := os.WriteFile(filepath.Join(dir, "Makefile"), []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	for i, args := range []map[string]any{
		{"handoff": handoff, "artifact": 0}, {"request": result, "artifact": 0}, {"handoff": handoff, "artifact": 1},
	} {
		args["checkout"] = dir
		data, err := call(t, h, "apply-artifact", args)
		var saved struct{ Saved string }
		if err != "" || json.Unmarshal(data, &saved) != nil {
			t.Fatalf("apply %d: %s %s", i, data, err)
		}
		name, body := "notes.md", "friend's report"
		if i == 2 {
			name, body = "Makefile", "friend's file"
		}
		got := filepath.Base(saved.Saved)
		if filepath.Dir(saved.Saved) != dir || (i == 0 && got != name) || (i > 0 && !(strings.HasPrefix(got, name+".") && len(got) == len(name)+9)) {
			t.Fatalf("unexpected written path %q", saved.Saved)
		}
		b, e := os.ReadFile(saved.Saved)
		if e != nil || string(b) != body {
			t.Fatalf("saved artifact: %q %v", b, e)
		}
	}
	if original, e := os.ReadFile(filepath.Join(dir, "Makefile")); e != nil || string(original) != "original" {
		t.Fatalf("overwrote original: %q %v", original, e)
	}
	_, err = call(t, h, "apply-artifact", input{Handoff: handoff, Artifact: 2, Checkout: dir})
	if !strings.Contains(err, "fetch the branch fix-worker") {
		t.Fatalf("branch guidance: %s", err)
	}
}

func TestHandoffProjectSignedMilestonesAcrossObservations(t *testing.T) {
	const (
		delivered = "2026-11-21T11:42:00.125Z"
		accepted  = "2026-11-21T11:42:02Z"
		verified  = "2026-11-21T11:42:03Z"
	)
	resources := []control.Resource{{ID: "workspace", Actions: []string{"agent.handoff", "agent.status", "agent.result"}}}
	var observation map[string]any
	a := newRequester(t, resources, false, func(c control.Child, body json.RawMessage) any {
		if c.Action == "agent.handoff" {
			return map[string]any{"run": "handoff-1", "state": "delivered", "deliveredAt": delivered}
		}
		var target struct{ Run string }
		if err := json.Unmarshal(body, &target); err != nil {
			t.Fatalf("decode handoff lookup: %v", err)
		}
		value := map[string]any{"run": target.Run, "state": "completed"}
		for field, stamp := range observation {
			value[field] = stamp
		}
		return value
	})
	h := a.Handler()
	send := func(action, payload string) map[string]any {
		t.Helper()
		raw, err := call(t, h, "send", input{Capability: action, Resource: "workspace", Payload: json.RawMessage(payload)})
		var row map[string]any
		if err != "" || json.Unmarshal(raw, &row) != nil || row["status"] != "completed" {
			t.Fatalf("send %s: %s %s", action, raw, err)
		}
		return row
	}
	list := func() map[string]any {
		t.Helper()
		raw, err := call(t, h, "handoffs", input{})
		var list struct{ Handoffs []map[string]any }
		if err != "" || json.Unmarshal(raw, &list) != nil || len(list.Handoffs) != 1 {
			t.Fatalf("handoffs: %s %s", raw, err)
		}
		return list.Handoffs[0]
	}
	check := func(row map[string]any, wantAccepted, wantVerified any) {
		t.Helper()
		if row["deliveredAt"] != delivered || row["acceptedAt"] != wantAccepted || row["verifiedAt"] != wantVerified {
			t.Fatalf("milestones delivered=%v accepted=%v verified=%v, want %v %v %v",
				row["deliveredAt"], row["acceptedAt"], row["verifiedAt"], delivered, wantAccepted, wantVerified)
		}
	}

	check(send("agent.handoff", `{"title":"Verify","task":"Verify the workspace"}`), nil, nil)
	check(list(), nil, nil)

	observation = map[string]any{"deliveredAt": delivered, "acceptedAt": true, "verifiedAt": verified}
	check(send("agent.status", `{"run":"handoff-1"}`), nil, nil)
	observation = map[string]any{"deliveredAt": delivered, "acceptedAt": "2026-11-21T1:42:02Z", "verifiedAt": verified}
	check(send("agent.status", `{"run":"handoff-1"}`), nil, nil)
	observation = map[string]any{"deliveredAt": delivered, "acceptedAt": accepted, "verifiedAt": verified}
	send("agent.result", `{"run":"different-handoff"}`)
	check(list(), nil, nil)

	observation = map[string]any{"acceptedAt": accepted, "verifiedAt": delivered}
	send("agent.status", `{"run":"handoff-1"}`)
	check(list(), accepted, nil)

	observation = map[string]any{"deliveredAt": delivered, "acceptedAt": accepted, "verifiedAt": verified}
	check(send("agent.result", `{"run":"handoff-1"}`), accepted, verified)
	observation = map[string]any{"deliveredAt": delivered, "acceptedAt": "2026-11-21T11:42:01Z"}
	send("agent.status", `{"run":"handoff-1"}`)
	observation = nil
	send("agent.status", `{"run":"handoff-1"}`)
	check(list(), accepted, verified)
}
