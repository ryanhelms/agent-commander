package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
	"agentcommander/internal/toolregistry"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestScopedToolsThroughAgentctlMCP(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_INTEGRATION") != "1" {
		t.Skip("requires disposable Unix sockets and an agentctl stdio subprocess")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 45*time.Second)
	defer cancel()
	dir, err := os.MkdirTemp("/tmp", "ac-tools-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "s.sock")
	binary := filepath.Join(dir, "agentctl")
	if output, err := exec.CommandContext(ctx, "go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build agentctl: %v\n%s", err, output)
	}
	allowed := filepath.Join(t.TempDir(), "checkout")
	other := filepath.Join(t.TempDir(), "checkout") // Same basename, different project.
	for _, path := range []string{allowed, other} {
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	grants, err := json.Marshal(map[string]any{"projects": []any{
		map[string]any{"path": allowed, "tools": map[string]int{"fixture.echo": 1}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tool-grants.json"), grants, 0600); err != nil {
		t.Fatal(err)
	}

	const sentinel = "fixture upstream credential"
	started, release := make(chan struct{}), make(chan struct{})
	var invocations atomic.Int32
	tool := toolregistry.Tool{
		Descriptor: toolregistry.Descriptor{
			ID: "fixture.echo", Version: 1, Action: toolregistry.Read, Description: "Echo a fixture message.",
			InputSchema: json.RawMessage(`{"type":"object","additionalProperties":false,"required":["text"],"properties":{"text":{"type":"string"},"number":{"type":"integer"}}}`),
		},
		Run: func(ctx context.Context, scope toolregistry.Scope, args map[string]any) (json.RawMessage, error) {
			invocations.Add(1)
			switch args["text"] {
			case "wait":
				close(started)
				select {
				case <-release:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
			case "fail":
				return nil, errors.New(sentinel)
			case "timeout":
				<-ctx.Done()
				return nil, ctx.Err()
			}
			return json.Marshal(map[string]any{"text": args["text"], "number": args["number"],
				"project": scope.ProjectPath, "run": scope.RunID, "worker": scope.WorkerID})
		},
	}
	launches := make(captureLaunch, 3)
	handler, err := service.New(dir, launches, tool)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := http.Server{Handler: handler}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	owner := localapi.New(socket, "")
	apiCall := func(ctx context.Context, client *localapi.Client, method, path string, input, output any) {
		t.Helper()
		data, err := client.Do(ctx, method, path, input)
		if err != nil {
			t.Fatal(err)
		}
		if output != nil {
			if err := json.Unmarshal(data, output); err != nil {
				t.Fatal(err)
			}
		}
	}
	launch := func(expectedID string) service.LaunchSpec {
		t.Helper()
		select {
		case spec := <-launches:
			if spec.ID != expectedID || spec.Token == "" {
				t.Fatalf("expected launch of %s, got %s", expectedID, spec.ID)
			}
			return spec
		case <-ctx.Done():
			t.Fatal(ctx.Err())
			return service.LaunchSpec{}
		}
	}
	createRun := func(path string) service.LaunchSpec {
		t.Helper()
		var run service.Run
		apiCall(ctx, owner, http.MethodPost, "/v1/runs", map[string]string{"path": path, "task": "Exercise scoped tools"}, &run)
		return launch(run.CoordinatorID)
	}
	connect := func(spec service.LaunchSpec, role string) *mcp.ClientSession {
		t.Helper()
		cmd := exec.CommandContext(ctx, binary, "mcp")
		cmd.Env = append(os.Environ(), "AGENT_COMMANDER_HOME="+dir, "AGENT_COMMANDER_SOCKET="+socket,
			"AGENT_COMMANDER_RUN_ID="+spec.RunID, "AGENT_COMMANDER_WORKER_ID="+spec.ID,
			"AGENT_COMMANDER_TOKEN="+spec.Token, "AGENT_COMMANDER_ROLE="+role)
		client := mcp.NewClient(&mcp.Implementation{Name: "scoped-tools-fixture", Version: "1"}, nil)
		session, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { session.Close() })
		return session
	}
	toolPath := func(spec service.LaunchSpec) string {
		return "/v1/runs/" + spec.RunID + "/workers/" + spec.ID + "/tools"
	}
	list := func(session *mcp.ClientSession) []toolregistry.Descriptor {
		t.Helper()
		data, err := callMCP(ctx, session, "commander_list_tools", struct{}{})
		if err != nil {
			t.Fatal(err)
		}
		var result struct{ Tools []toolregistry.Descriptor }
		if err := json.Unmarshal(data, &result); err != nil {
			t.Fatal(err)
		}
		return result.Tools
	}
	invoke := func(raw string) toolregistry.Invocation {
		return toolregistry.Invocation{ID: "fixture.echo", Version: 1, Arguments: json.RawMessage(raw)}
	}

	coordinator, neighbor := createRun(allowed), createRun(other)
	session := connect(coordinator, "coordinator")
	exposed, err := session.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"commander_list_tools", "commander_call_tool"} {
		if !slices.ContainsFunc(exposed.Tools, func(tool *mcp.Tool) bool { return tool.Name == name }) {
			t.Fatalf("missing MCP tool %q", name)
		}
	}
	descriptors := list(session)
	if len(descriptors) != 1 || descriptors[0].ID != "fixture.echo" || descriptors[0].Version != 1 ||
		descriptors[0].Action != toolregistry.Read || string(descriptors[0].InputSchema) != string(tool.Descriptor.InputSchema) {
		t.Fatalf("unexpected discovery: %+v", descriptors)
	}
	if found := list(connect(neighbor, "coordinator")); len(found) != 0 {
		t.Fatalf("ungranted coordinator discovered %+v", found)
	}
	raw, err := callMCP(ctx, session, "commander_call_tool", invoke(`{"text":"$HOME\nこんにちは","number":9007199254740993}`))
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Text, Project, Run, Worker string
		Number                     int64
	}
	resolved, err := filepath.EvalSymlinks(allowed)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &result); err != nil || result.Text != "$HOME\nこんにちは" ||
		result.Number != 9007199254740993 || result.Project != resolved || result.Run != coordinator.RunID || result.Worker != coordinator.ID {
		t.Fatalf("unexpected tool result: %s (%v)", raw, err)
	}

	var assigned service.Worker
	apiCall(ctx, owner, http.MethodPost, "/v1/runs/"+coordinator.RunID+"/workers",
		map[string]string{"name": "worker", "task": "Research"}, &assigned)
	worker := launch(assigned.ID)
	for _, test := range []struct {
		name, token, path string
		status            int
	}{
		{"no credential", "", toolPath(coordinator), http.StatusUnauthorized},
		{"invalid credential", "unrecognized", toolPath(coordinator), http.StatusUnauthorized},
		{"wrong actor", neighbor.Token, toolPath(coordinator), http.StatusForbidden},
		{"wrong run", coordinator.Token, "/v1/runs/" + neighbor.RunID + "/workers/" + coordinator.ID + "/tools", http.StatusForbidden},
		{"worker", worker.Token, toolPath(worker), http.StatusForbidden},
		{"ungranted project", neighbor.Token, toolPath(neighbor), http.StatusForbidden},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := localapi.New(socket, test.token).Do(ctx, http.MethodPost, test.path+"/calls", invoke(`{"text":"denied"}`))
			var response *localapi.ResponseError
			if !errors.As(err, &response) || response.StatusCode != test.status {
				t.Fatalf("expected denial %d, got %v", test.status, err)
			}
		})
	}
	if _, err := callMCP(ctx, connect(worker, "coordinator"), "commander_list_tools", struct{}{}); err == nil || !strings.Contains(err.Error(), "(403)") {
		t.Fatalf("worker spoofing role should be denied discovery, got %v", err)
	}
	for _, in := range []toolregistry.Invocation{
		invoke(`{"text":42}`), invoke(`{"text":"hello","outside_schema":true}`),
		{ID: "fixture.echo", Version: 2, Arguments: json.RawMessage(`{"text":"wrong version"}`)},
	} {
		if _, err := callMCP(ctx, session, "commander_call_tool", in); err == nil {
			t.Fatalf("unexpected acceptance: %+v", in)
		}
	}
	if count := invocations.Load(); count != 1 {
		t.Fatalf("denied calls reached the handler, got %d invocations", count)
	}
	if _, err := callMCP(ctx, session, "commander_call_tool", invoke(`{"text":"fail"}`)); err == nil ||
		!strings.Contains(err.Error(), "(502)") || strings.Contains(err.Error(), sentinel) {
		t.Fatalf("unexpected upstream failure: %v", err)
	}
	if _, err := callMCP(ctx, session, "commander_call_tool", invoke(`{"text":"timeout"}`)); err == nil || !strings.Contains(err.Error(), "(504)") {
		t.Fatalf("expected service deadline to reach the connector, got %v", err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := callMCP(ctx, session, "commander_call_tool", invoke(`{"text":"wait"}`))
		done <- err
	}()
	select {
	case <-started:
	case err := <-done:
		t.Fatalf("blocked call never entered handler: %v", err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	independentCtx, finish := context.WithTimeout(ctx, 2*time.Second)
	defer finish()
	var question service.Question
	apiCall(independentCtx, localapi.New(socket, neighbor.Token), http.MethodPost, "/v1/workers/"+neighbor.ID+"/questions",
		map[string]string{"question": "Proceed?"}, &question)
	apiCall(independentCtx, owner, http.MethodGet, "/v1/runs/"+neighbor.RunID, nil, nil)
	apiCall(independentCtx, owner, http.MethodPost, "/v1/requests/"+question.ID+"/reply", map[string]string{"answer": "Proceed."}, nil)
	apiCall(independentCtx, owner, http.MethodPost, "/v1/runs/"+coordinator.RunID+"/stop", struct{}{}, nil)
	close(release)
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "(403)") {
			t.Fatalf("run stopped in flight should be denied its result, got %v", err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if _, err := callMCP(ctx, session, "commander_call_tool", invoke(`{"text":"already stopped"}`)); err == nil || !strings.Contains(err.Error(), "(403)") {
		t.Fatalf("stopped run should be denied before dispatch, got %v", err)
	}
	if count := invocations.Load(); count != 4 {
		t.Fatalf("unexpected dispatch count: %d", count)
	}
}
