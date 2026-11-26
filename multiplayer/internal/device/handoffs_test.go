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

func TestHandoffRowsAndApplyArtifact(t *testing.T) {
	makePeer := func(user string) (*devicekeys.Keys, devicekeys.Public) {
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
	localKeys, local := makePeer("my-user-id")
	friendKeys, friend := makePeer("friend-user-id")
	const updated = "2026-11-21T11:42:00Z"
	submissions := map[string]control.Submission{}
	processing := map[string]bool{}
	processingResult := func(s control.Submission) control.Submission {
		c := s.Children[0]
		c.Status, c.Result = "processing", nil
		return control.Submission{ID: s.ID, Children: []control.Child{c}}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/friends", func(w http.ResponseWriter, req *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"friends": []Friend{{User: friend.User, Handle: "sam"}}})
	})
	mux.HandleFunc("GET /v1/identity/devices/"+friend.Device, func(w http.ResponseWriter, req *http.Request) {
		json.NewEncoder(w).Encode(friend)
	})
	mux.HandleFunc("GET /v1/resources", func(w http.ResponseWriter, req *http.Request) {
		resource := control.Resource{ID: "shared", Device: friend.Device, Owner: friend.User, Actions: []string{"agent.handoff", "agent.result"}}
		json.NewEncoder(w).Encode(map[string]any{"resources": []control.Resource{resource}})
	})
	mux.HandleFunc("POST /v1/submissions", func(w http.ResponseWriter, req *http.Request) {
		var submitted outbound
		if err := json.NewDecoder(req.Body).Decode(&submitted); err != nil || len(submitted.Children) != 1 {
			http.Error(w, "expected one target", http.StatusBadRequest)
			return
		}
		c := control.Child{Addressed: submitted.Children[0], Parent: submitted.ID, Status: "completed",
			Sender: local.User, SenderDevice: local.Device, Owner: friend.User}
		body, err := friendKeys.Open(local, header(c, "request"), c.Envelope)
		if err != nil {
			t.Errorf("open request: %v", err)
			http.Error(w, "could not open", http.StatusBadRequest)
			return
		}
		value := map[string]any{"run": "assigned-run", "state": "running"}
		if c.Action == "agent.result" {
			var target struct{ Run string }
			if json.Unmarshal(body, &target) != nil || target.Run == "" {
				http.Error(w, "missing run", http.StatusBadRequest)
				return
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
		signed, _ := json.Marshal(map[string]any{"status": c.Status, "value": value})
		c.Result, err = friendKeys.Seal(local, header(c, "result"), signed)
		if err != nil {
			t.Errorf("seal result: %v", err)
			http.Error(w, "could not seal", http.StatusInternalServerError)
			return
		}
		s := control.Submission{ID: submitted.ID, Children: []control.Child{c}}
		submissions[s.ID] = s
		if c.Action == "agent.result" {
			processing[s.ID] = true
			s = processingResult(s)
		}
		json.NewEncoder(w).Encode(s)
	})
	mux.HandleFunc("GET /v1/submissions/{id}", func(w http.ResponseWriter, req *http.Request) {
		s := submissions[req.PathValue("id")]
		if processing[s.ID] {
			delete(processing, s.ID)
			s = processingResult(s)
		}
		json.NewEncoder(w).Encode(s)
	})
	server := httptest.NewTLSServer(mux)
	defer server.Close()
	a := &Agent{cfg: Config{Dir: t.TempDir(), ServerID: "s-test", Relay: server.URL}, http: server.Client(), keys: localKeys,
		identity: identity.Client{BaseURL: server.URL, HTTP: server.Client()}, policy: localPolicy{Pins: map[string]devicekeys.Public{}},
		creds: credentials{Session: identity.Session{User: local.User, Device: local.Device, ExpiresAt: time.Now().Add(time.Hour)}}}
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
