package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Each managed actor gets a fresh instance of the actual agentctl MCP entry point.
// Exit before the Go test harness can write its PASS banner to the JSON-RPC pipe.
func TestMCPSubprocess(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_MCP_CHILD") != "1" {
		t.Skip("MCP test subprocess")
	}
	if err := run([]string{"mcp"}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

type captureLaunch chan service.LaunchSpec

func (c captureLaunch) Launch(_ context.Context, spec service.LaunchSpec) error {
	c <- spec
	return nil
}
func (captureLaunch) Stop(context.Context, string) error { return nil }

func callMCP(ctx context.Context, session *mcp.ClientSession, name string, args any) (json.RawMessage, error) {
	reply, err := session.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		return nil, err
	}
	if len(reply.Content) != 1 {
		return nil, fmt.Errorf("%s returned %d content items", name, len(reply.Content))
	}
	text, ok := reply.Content[0].(*mcp.TextContent)
	if !ok || reply.IsError {
		return nil, fmt.Errorf("%s tool error: %v", name, reply.Content[0])
	}
	return json.RawMessage(text.Text), nil
}

func TestLocalMCPPlanningRun(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_INTEGRATION") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_INTEGRATION=1 for the Unix socket and stdio integration")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()

	// Short path for the macOS sockaddr_un limit.
	dir, err := os.MkdirTemp("/tmp", "ac-mcp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "s.sock")
	launched := make(captureLaunch, 3)
	handler, err := service.New(dir, launched)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	pendingRead := make(chan struct{})
	var observed sync.Once
	server := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handler.ServeHTTP(w, r)
		if r.Method == "GET" && strings.Contains(r.URL.Path, "/questions/") {
			observed.Do(func() { close(pendingRead) })
		}
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	human := localapi.New(socket, "")

	humanCall := func(method, path string, in, out any) {
		t.Helper()
		data, err := human.Do(ctx, method, path, in)
		if err != nil {
			t.Fatal(err)
		}
		if out != nil {
			if err := json.Unmarshal(data, out); err != nil {
				t.Fatal(err)
			}
		}
	}
	connectActor := func(expectedID string) *mcp.ClientSession {
		t.Helper()
		var spec service.LaunchSpec
		select {
		case spec = <-launched:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
		if spec.ID != expectedID || spec.Token == "" {
			t.Fatalf("missing binding for %s (got %s)", expectedID, spec.ID)
		}
		exe, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.CommandContext(ctx, exe, "-test.run=^TestMCPSubprocess$")
		cmd.Env = append(os.Environ(), "AGENT_COMMANDER_TEST_MCP_CHILD=1", "AGENT_COMMANDER_HOME="+dir, "AGENT_COMMANDER_SOCKET="+socket,
			"AGENT_COMMANDER_WORKER_ID="+spec.ID, "AGENT_COMMANDER_RUN_ID="+spec.RunID, "AGENT_COMMANDER_TOKEN="+spec.Token)
		client := mcp.NewClient(&mcp.Implementation{Name: "commander-flow-test", Version: "1"}, nil)
		session, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { session.Close() })
		return session
	}
	tool := func(actor *mcp.ClientSession, name string, args any, out any) {
		t.Helper()
		raw, err := callMCP(ctx, actor, name, args)
		if err != nil {
			t.Fatal(err)
		}
		if out != nil {
			if err := json.Unmarshal(raw, out); err != nil {
				t.Fatal(err)
			}
		}
	}

	var runInfo service.Run
	humanCall("POST", "/v1/runs", map[string]string{"task": "Plan a terminal feature", "path": dir, "client": "claude"}, &runInfo)
	coordinator := connectActor(runInfo.CoordinatorID)
	delegate := func(name string) (string, *mcp.ClientSession) {
		t.Helper()
		var worker service.Worker
		tool(coordinator, "commander_delegate", map[string]string{"name": name, "task": "Review " + name}, &worker)
		if worker.ParentID != runInfo.CoordinatorID {
			t.Fatalf("incorrect parent for %s", name)
		}
		return worker.ID, connectActor(worker.ID)
	}
	idA, workerA := delegate("Protocol")
	idB, workerB := delegate("Display")
	var questionA, questionB service.Question
	tool(workerA, "commander_ask", map[string]string{"question": "What literal input should we preserve?"}, &questionA)
	tool(workerB, "commander_ask", map[string]string{"question": "What terminal width?"}, &questionB)
	if questionA.WorkerID != idA || questionB.WorkerID != idB || questionA.ID == questionB.ID {
		t.Fatal("each question must be bound to its original worker")
	}

	type waitResult struct {
		data json.RawMessage
		err  error
	}
	waited := make(chan waitResult, 1)
	go func() {
		b, e := callMCP(ctx, workerA, "commander_wait", map[string]any{"request_id": questionA.ID, "timeout_seconds": 5})
		waited <- waitResult{b, e}
	}()
	select {
	case <-pendingRead:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	const literal = "Keep $HOME and 'quotes'\non two lines, including \"double quotes\"."
	humanCall("POST", "/v1/requests/"+questionA.ID+"/reply", map[string]string{"answer": literal}, nil)
	var received service.Question
	select {
	case result := <-waited:
		if result.err != nil {
			t.Fatal(result.err)
		}
		if err := json.Unmarshal(result.data, &received); err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if received.ID != questionA.ID || received.WorkerID != idA || received.Status != "answered" || received.Answer != literal {
		t.Fatalf("wrong receipt: %+v", received)
	}

	finding := "Preserve this literal input: " + received.Answer
	tool(workerA, "commander_result", map[string]string{"result": finding}, nil)
	var status service.Run
	tool(coordinator, "commander_status", map[string]any{}, &status)
	if !slices.ContainsFunc(status.Workers, func(w *service.Worker) bool { return w.ID == idA && w.Result == finding }) {
		t.Fatal("coordinator did not receive the worker's finding")
	}
	if !slices.ContainsFunc(status.Requests, func(q *service.Question) bool {
		return q.ID == questionB.ID && q.WorkerID == idB && q.Status == "pending" && q.Answer == ""
	}) {
		t.Fatal("answering one question changed its sibling")
	}
}
