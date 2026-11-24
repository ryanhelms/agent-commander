package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"agentcommander/internal/service"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Run the normal agentctl MCP subprocess. The receiver must ask the authoritative
// local service to validate the presented credential before accepting any action.
func TestCoordinatorNetworkToolsUseBoundActor(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_INTEGRATION") != "1" {
		t.Skip("requires disposable Unix sockets and stdio subprocess")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	dir, err := os.MkdirTemp("/tmp", "ac-net-mcp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	starts := make(captureLaunch, 3)
	api, err := service.New(dir, starts)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"path": dir, "task": "collaborate", "client": "codex"})
	owner := httptest.NewRecorder()
	api.ServeHTTP(owner, httptest.NewRequest("POST", "/v1/runs", bytes.NewReader(body)))
	if owner.Code != 201 {
		t.Fatalf("create: %s", owner.Body.String())
	}
	var actor service.LaunchSpec
	select {
	case actor = <-starts:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	socket := filepath.Join(dir, "network.sock")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	network := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proof := httptest.NewRecorder()
		req := httptest.NewRequest("GET", "/v1/network/coordinator", nil)
		for _, h := range []string{"Authorization", "X-Commander-Run", "X-Commander-Worker"} {
			req.Header[h] = r.Header.Values(h)
		}
		api.ServeHTTP(proof, req)
		if proof.Code != 200 {
			http.Error(w, "invalid caller", 403)
			return
		}
		var body map[string]any
		if r.Method != "POST" || json.NewDecoder(r.Body).Decode(&body) != nil {
			http.Error(w, "bad request", 400)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"path": r.URL.Path, "body": body})
	})}
	go network.Serve(ln)
	defer network.Close()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, exe, "-test.run=^TestMCPSubprocess$")
	cmd.Env = append(os.Environ(), "AGENT_COMMANDER_TEST_MCP_CHILD=1", "AGENT_COMMANDER_HOME="+dir, "AGENT_COMMANDER_WORKER_ID="+actor.ID, "AGENT_COMMANDER_RUN_ID="+actor.RunID, "AGENT_COMMANDER_TOKEN="+actor.Token, "AGENT_COMMANDER_ROLE=coordinator", "COMMANDER_NETWORK_SOCKET="+socket)
	client := mcp.NewClient(&mcp.Implementation{Name: "network-test", Version: "1"}, nil)
	sess, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	for _, op := range []struct {
		name string
		body any
	}{{"discover", struct{}{}}, {"inbox", struct{}{}}, {"submit", map[string]any{"id": "bound-1", "targets": []map[string]any{{"resource": "shared", "action": "agent.ask", "payload": map[string]any{"text": "review"}}}}}, {"receipt", map[string]string{"id": "bound-1"}}} {
		raw, err := callMCP(ctx, sess, "commander_network_"+op.name, op.body)
		if err != nil {
			t.Fatal(err)
		}
		var out struct {
			Path string
			Body json.RawMessage
		}
		if json.Unmarshal(raw, &out) != nil || out.Path != "/coordinator/"+op.name {
			t.Fatalf("unexpected network response: %s", raw)
		}
		want, _ := json.Marshal(op.body)
		var value any
		_ = json.Unmarshal(want, &value)
		want, _ = json.Marshal(value)
		if string(out.Body) != string(want) {
			t.Fatalf("network request changed: %s != %s", out.Body, want)
		}
	}
}
