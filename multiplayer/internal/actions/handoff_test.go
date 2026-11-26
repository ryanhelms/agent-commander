package actions

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHandoffCreatesRunAndOnlyItsPeerCanRead(t *testing.T) {
	dir, err := os.MkdirTemp("", "ac-h-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "svc.sock")
	l, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	var created string
	srv := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch {
		case req.Method == "GET" && req.URL.Path == "/v1/ag-ui/workers/worker":
			fmt.Fprint(w, `{"workerId":"worker","role":"worker","runId":"r-src","generation":3}`)
		case req.Method == "GET" && req.URL.Path == "/v1/runs/r-src":
			fmt.Fprint(w, `{"id":"r-src","path":"/tmp/project","client":"claude","status":"running"}`)
		case req.Method == "POST" && req.URL.Path == "/v1/runs":
			b, _ := io.ReadAll(req.Body)
			created = string(b)
			if req.Header.Get("Idempotency-Key") == "" {
				t.Error("missing idempotency key")
			}
			fmt.Fprint(w, `{"id":"r-new","status":"running"}`)
		case req.Method == "GET" && req.URL.Path == "/v1/runs/r-new":
			fmt.Fprint(w, `{"id":"r-new","title":"Fix it","branch":"fix-it","status":"done","workers":[{"id":"w","name":"Lead","state":"done","result":"Fixed the bug."}]}`)
		default:
			http.NotFound(w, req)
		}
	})}
	go srv.Serve(l)
	t.Cleanup(func() { srv.Close() })

	cfg := Config{StateDir: filepath.Join(dir, "state"), CommanderSocket: socket,
		Resources: []Resource{{ID: "res", Name: "Agent", Kind: "agent", Target: "worker"}, {ID: "other", Kind: "agent", Target: "worker"}},
		Grants: []Grant{
			{Peer: "sam", Resource: "res", Action: "agent.handoff", ExpiresAt: time.Now().Add(time.Hour), MaxUses: 1},
			{Peer: "sam", Resource: "res", Action: "agent.result", ExpiresAt: time.Now().Add(time.Hour), MaxUses: 1},
			{Peer: "eve", Resource: "res", Action: "agent.result", ExpiresAt: time.Now().Add(time.Hour), MaxUses: 5},
			{Peer: "sam", Resource: "other", Action: "agent.result", ExpiresAt: time.Now().Add(time.Hour), MaxUses: 1},
		}}
	if err := os.MkdirAll(cfg.StateDir, 0700); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	out, err := Execute(ctx, cfg, Request{ID: "op1", Peer: "sam", Resource: "res", Action: "agent.handoff",
		Payload: json.RawMessage(`{"title":"Fix it","task":"Fix the bug","context":[{"name":"log.txt","content":"panic: boom"}]}`)})
	if err != nil || !strings.Contains(string(out), `"run":"r-new"`) {
		t.Fatalf("handoff: %s %v", out, err)
	}
	if !strings.Contains(created, "Fix the bug") || !strings.Contains(created, "panic: boom") || !strings.Contains(created, "/tmp/project") {
		t.Fatalf("run body: %s", created)
	}
	out, err = Execute(ctx, cfg, Request{ID: "op2", Peer: "sam", Resource: "res", Action: "agent.result", Payload: json.RawMessage(`{"run":"r-new"}`)})
	if err != nil || !strings.Contains(string(out), "Fixed the bug.") || !strings.Contains(string(out), `"kind":"branch"`) {
		t.Fatalf("result: %s %v", out, err)
	}
	if _, err = Execute(ctx, cfg, Request{ID: "op3", Peer: "eve", Resource: "res", Action: "agent.result", Payload: json.RawMessage(`{"run":"r-new"}`)}); err == nil {
		t.Fatal("another peer read a run it did not hand off")
	}
	if _, err = Execute(ctx, cfg, Request{ID: "op4", Peer: "sam", Resource: "other", Action: "agent.result", Payload: json.RawMessage(`{"run":"r-new"}`)}); err == nil {
		t.Fatal("a grant on another resource reached the run")
	}
	if _, err = Execute(ctx, cfg, Request{ID: "op5", Peer: "sam", Resource: "res", Action: "agent.result", Payload: json.RawMessage(`{"run":"r-new"}`)}); err != nil {
		t.Fatalf("reading a result consumed a use: %v", err)
	}
}
