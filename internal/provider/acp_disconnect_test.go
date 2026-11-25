package provider

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

func TestLocalACPDisconnectPreservesFollowUpDeliveryEvidence(t *testing.T) {
	dir, err := os.MkdirTemp("", "ac-delivery-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	launcher := make(sourceTestLauncher, 2)
	handler, err := service.New(dir, launcher)
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "s")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	go server.Serve(listener)
	defer server.Close()

	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	owner := &api{client: localapi.New(socket, "")}
	call := func(method, path string, body, dest any) {
		t.Helper()
		if err := owner.requestContext(ctx, method, path, body, dest); err != nil {
			t.Fatal(err)
		}
	}
	var run service.Run
	call("POST", "/v1/runs", map[string]string{"client": "codex", "task": "hold", "path": dir}, &run)
	runPath := "/v1/runs/" + run.ID
	var worker service.Worker
	call("POST", runPath+"/workers", map[string]string{"client": "codex", "name": "fixture", "task": "start"}, &worker)
	var launch service.LaunchSpec
	for launch.ID != worker.ID {
		select {
		case launch = <-launcher:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	client := &api{client: localapi.New(socket, launch.Token)}
	path := "/v1/workers/" + launch.ID
	if err := client.requestContext(ctx, "POST", path+"/state", map[string]string{"state": "working"}, nil); err != nil {
		t.Fatal(err)
	}
	profile := &acpProfile{
		Command: exe, Args: []string{"-test.run=^TestLocalACPDisconnectPeer$"}, OmitCommanderMCP: true,
	}
	job := job{Worker: launch, Socket: socket, Harness: "fixture", RegisteredACP: profile,
		RegisteredEnv: map[string]string{"COMMANDER_DISCONNECT_FIXTURE": "1"}}
	screen := openScreen(ctx, client, launch.ID)
	defer screen.close()
	finished := make(chan error, 1)
	go func() { finished <- runACP(ctx, job, client, screen) }()

	waitFor := func(ready func(*service.Worker) bool) *service.Worker {
		t.Helper()
		for {
			var current service.Run
			call("GET", runPath, nil, &current)
			for _, row := range current.Workers {
				if row.ID == worker.ID && ready(row) {
					return row
				}
			}
			select {
			case <-time.After(10 * time.Millisecond):
			case <-ctx.Done():
				t.Fatal("worker did not reach the expected state")
			}
		}
	}
	waitFor(func(w *service.Worker) bool { return w.State == "completed" })
	call("POST", path+"/control", map[string]any{"held": true, "generation": 1}, nil)
	send := func(text string) {
		call("POST", path+"/messages", map[string]any{"text": text, "generation": 2}, nil)
	}
	send("finish before disconnect")
	waitFor(func(w *service.Worker) bool {
		return len(w.Control.Messages) == 1 && w.Control.Messages[0].Status == "completed"
	})
	send("disconnect before prompt result")
	select {
	case err := <-finished:
		if !errors.Is(err, errACPDisconnected) {
			t.Fatalf("worker returned %v", err)
		}
	case <-ctx.Done():
		t.Fatal("peer disconnect did not finish the runner")
	}

	resolved := waitFor(func(w *service.Worker) bool { return w.State == "failed" })
	before, during := resolved.Control.Messages[0], resolved.Control.Messages[1]
	if before.Status != "completed" || before.StopReason != "end_turn" ||
		during.Status != "delivery_unknown" || during.StopReason != "" || during.End == nil {
		t.Fatalf("incorrect delivery evidence before or during disconnect: %+v, %+v", before, during)
	}
}

func TestLocalACPDisconnectPeer(t *testing.T) {
	if os.Getenv("COMMANDER_DISCONNECT_FIXTURE") != "1" {
		return
	}
	input, output := json.NewDecoder(os.Stdin), json.NewEncoder(os.Stdout)
	for {
		var req struct {
			Method string
			ID     json.RawMessage
			Params struct{ Prompt []struct{ Text string } }
		}
		if err := input.Decode(&req); err != nil {
			os.Exit(2)
		}
		var result map[string]any
		switch req.Method {
		case "initialize":
			result = map[string]any{"protocolVersion": 1}
		case "session/new":
			result = map[string]any{"sessionId": "fixture"}
		case "session/prompt":
			if len(req.Params.Prompt) == 1 && req.Params.Prompt[0].Text == "disconnect before prompt result" {
				os.Exit(0)
			}
			result = map[string]any{"stopReason": "end_turn"}
		}
		if err := output.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result}); err != nil {
			os.Exit(3)
		}
	}
}
