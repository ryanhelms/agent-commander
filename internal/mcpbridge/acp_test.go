package mcpbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/localapi"
)

func TestDraftMCPHandlerFiltersToolsAndSeparatesErrorDomains(t *testing.T) {
	ctx := t.Context()
	call, err := NewACPHandler(ctx, localapi.New(t.TempDir()+"/absent.sock", "test-token"), map[string]string{
		"AGENT_COMMANDER_WORKER_ID": "worker",
		"AGENT_COMMANDER_RUN_ID":    "run",
		"AGENT_COMMANDER_TOKEN":     "test-token",
		"AGENT_COMMANDER_ROLE":      "worker",
	}, []string{"commander_ask"})
	if err != nil {
		t.Fatal(err)
	}
	params := func(payload map[string]any, version string) json.RawMessage {
		t.Helper()
		payload["_meta"] = map[string]any{
			"io.modelcontextprotocol/protocolVersion":    version,
			"io.modelcontextprotocol/clientCapabilities": map[string]any{},
			"io.modelcontextprotocol/clientInfo":         map[string]string{"name": "fixture", "version": "1"},
		}
		raw, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	for _, tc := range []struct{ method, want string }{
		{"server/discover", runtime.ACPMCPProtocolVersion},
		{"tools/list", "commander_ask"},
	} {
		result, err := call(ctx, runtime.MCPACPRequest{RequestID: "literal $HOME", Method: tc.method,
			Params: params(map[string]any{}, runtime.ACPMCPProtocolVersion)})
		if err != nil || !bytes.Contains(result.Result, []byte(tc.want)) || bytes.Contains(result.Result, []byte("commander_delegate")) {
			t.Fatalf("%s did not return its authorized MCP result: %s %s %v", tc.method, result.Result, result.Error, err)
		}
	}
	denied, err := call(ctx, runtime.MCPACPRequest{RequestID: "denied", Method: "tools/call",
		Params: params(map[string]any{"name": "commander_delegate"}, runtime.ACPMCPProtocolVersion)})
	if err != nil || !bytes.Contains(denied.Error, []byte(`"code":-32602`)) || len(denied.Result) != 0 {
		t.Fatalf("wrong tool authorization result: %+v %v", denied, err)
	}
	unsupported, err := call(ctx, runtime.MCPACPRequest{RequestID: "unsupported", Method: "tools/list",
		Params: params(map[string]any{}, "2025-11-25")})
	if err != nil || !bytes.Contains(unsupported.Error, []byte(`"code":-32022`)) || len(unsupported.Result) != 0 {
		t.Fatalf("wrong error domain for unsupported MCP version: %+v %v", unsupported, err)
	}
	allowed, err := call(ctx, runtime.MCPACPRequest{RequestID: "allowed", Method: "tools/call",
		Params: params(map[string]any{"name": "commander_ask", "arguments": map[string]string{"question": "literal $HOME"}}, runtime.ACPMCPProtocolVersion)})
	if err != nil || !bytes.Contains(allowed.Result, []byte(`"isError":true`)) || len(allowed.Error) != 0 {
		t.Fatalf("tool failure did not remain an MCP tool result: %+v %v", allowed, err)
	}
}

func TestDraftMCPCallUsesAddressedAPIAndCancelsItsWork(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "ac-mcp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "mcp.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	started, cancelled := make(chan struct{}), make(chan struct{})
	requests := make(chan map[string]string, 1)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Header.Get("Authorization") != "Bearer fixture-token" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch req.URL.Path {
		case "/v1/workers/worker/frontend-tools/ready":
			_, _ = w.Write([]byte(`{}`))
		case "/v1/workers/worker/questions":
			var payload map[string]string
			if json.NewDecoder(req.Body).Decode(&payload) != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			requests <- payload
			_, _ = w.Write([]byte(`{"ID":"bound-question","status":"pending"}`))
		case "/v1/workers/worker/questions/bound-question":
			close(started)
			<-req.Context().Done()
			close(cancelled)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})}
	go server.Serve(listener)
	t.Cleanup(func() { _ = server.Close() })
	call, err := NewACPHandler(t.Context(), localapi.New(socket, "fixture-token"), map[string]string{
		"AGENT_COMMANDER_WORKER_ID": "worker", "AGENT_COMMANDER_RUN_ID": "run",
		"AGENT_COMMANDER_TOKEN": "fixture-token", "AGENT_COMMANDER_ROLE": "worker",
	}, []string{"commander_ask", "commander_wait"})
	if err != nil {
		t.Fatal(err)
	}
	ask := runtime.MCPACPRequest{RequestID: "ask", Method: "tools/call", Params: json.RawMessage(`{
		"name":"commander_ask","arguments":{"question":"literal $HOME","idempotency_key":"exact"},
		"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"test","version":"1"}}
	}`)}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	answer, err := call(ctx, ask)
	if err != nil || !bytes.Contains(answer.Result, []byte("bound-question")) {
		t.Fatalf("scoped Commander tool was not invoked: %+v, %v", answer, err)
	}
	if payload := <-requests; payload["question"] != "literal $HOME" || payload["idempotency_key"] != "exact" {
		t.Fatalf("Commander tool arguments changed: %v", payload)
	}
	wait := runtime.MCPACPRequest{RequestID: "wait", Method: "tools/call", Params: json.RawMessage(`{
		"name":"commander_wait","arguments":{"request_id":"bound-question"},
		"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"test","version":"1"}}
	}`)}
	finished := make(chan error, 1)
	go func() {
		_, err := call(ctx, wait)
		finished <- err
	}()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("wait did not start on the scoped API")
	}
	cancel()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("MCP cancellation failed to reach the original worker operation")
	}
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("cancelled tool reported success")
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled tool did not clean up")
	}
}
