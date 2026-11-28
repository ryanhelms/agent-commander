package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/plugins"
	"agentcommander/internal/service"
	"agentcommander/internal/toolregistry"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// TestPluginToolsThroughAgentctlMCP installs the example Node plugin, grants
// it to one checkout and calls it the way a coordinator does: through
// agentctl mcp, commander_list_tools and commander_call_tool.
func TestPluginToolsThroughAgentctlMCP(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_INTEGRATION") != "1" {
		t.Skip("requires disposable Unix sockets and an agentctl stdio subprocess")
	}
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("the example plugin needs node on PATH")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	defer cancel()
	dir, err := os.MkdirTemp("/tmp", "ac-plugins-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "s.sock")
	binary := filepath.Join(dir, "agentctl")
	if output, err := exec.CommandContext(ctx, "go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build agentctl: %v\n%s", err, output)
	}
	allowed, other := filepath.Join(t.TempDir(), "checkout"), filepath.Join(t.TempDir(), "checkout")
	for _, path := range []string{allowed, other} {
		if err := os.Mkdir(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(allowed, "README.md"), nil, 0o600); err != nil {
		t.Fatal(err)
	}

	example, err := filepath.Abs("../../examples/plugins/hello")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENT_COMMANDER_TOKEN", "must-not-leak")
	if _, err := plugins.Install(ctx, dir, example, plugins.InstallOptions{Reserved: compiledToolIDs()}); err != nil {
		t.Fatal(err)
	}
	if err := plugins.Grant(dir, "example.hello.echo", 1, allowed, json.RawMessage(`{"greeting":"Howdy"}`)); err != nil {
		t.Fatal(err)
	}
	if err := plugins.Grant(dir, "example.hello.project_files", 1, allowed, nil); err != nil {
		t.Fatal(err)
	}
	host, err := plugins.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(host.Close)
	if len(host.Problems) != 0 {
		t.Fatal(host.Problems)
	}

	launches := make(captureLaunch, 2)
	handler, err := service.New(dir, launches, host.Tools()...)
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

	createRun := func(path string) service.LaunchSpec {
		t.Helper()
		var run service.Run
		data, err := owner.Do(ctx, http.MethodPost, "/v1/runs", map[string]string{"path": path, "task": "Exercise plugins"})
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &run); err != nil {
			t.Fatal(err)
		}
		select {
		case spec := <-launches:
			return spec
		case <-ctx.Done():
			t.Fatal(ctx.Err())
			return service.LaunchSpec{}
		}
	}
	connect := func(spec service.LaunchSpec) *mcp.ClientSession {
		t.Helper()
		cmd := exec.CommandContext(ctx, binary, "mcp")
		cmd.Env = append(os.Environ(), "AGENT_COMMANDER_HOME="+dir, "AGENT_COMMANDER_SOCKET="+socket,
			"AGENT_COMMANDER_RUN_ID="+spec.RunID, "AGENT_COMMANDER_WORKER_ID="+spec.ID,
			"AGENT_COMMANDER_TOKEN="+spec.Token, "AGENT_COMMANDER_ROLE=coordinator")
		session, err := mcp.NewClient(&mcp.Implementation{Name: "plugin-fixture", Version: "1"}, nil).
			Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { session.Close() })
		return session
	}
	listIDs := func(session *mcp.ClientSession) []string {
		t.Helper()
		data, err := callMCP(ctx, session, "commander_list_tools", struct{}{})
		if err != nil {
			t.Fatal(err)
		}
		var result struct{ Tools []toolregistry.Descriptor }
		if err := json.Unmarshal(data, &result); err != nil {
			t.Fatal(err)
		}
		var ids []string
		for _, d := range result.Tools {
			ids = append(ids, d.ID)
		}
		return ids
	}

	coordinator := connect(createRun(allowed))
	if ids := listIDs(coordinator); !slices.Equal(ids, []string{"example.hello.echo", "example.hello.project_files"}) {
		t.Fatalf("granted coordinator lists %v", ids)
	}
	if ids := listIDs(connect(createRun(other))); len(ids) != 0 {
		t.Fatalf("ungranted coordinator lists %v", ids)
	}

	raw, err := callMCP(ctx, coordinator, "commander_call_tool",
		toolregistry.Invocation{ID: "example.hello.echo", Version: 1, Arguments: json.RawMessage(`{"text":"hi"}`)})
	if err != nil {
		t.Fatal(err)
	}
	var echo struct {
		Greeting, Text string
		Scope          map[string]string
	}
	resolved, _ := filepath.EvalSymlinks(allowed)
	if err := json.Unmarshal(raw, &echo); err != nil || echo.Greeting != "Howdy" || echo.Text != "hi" || echo.Scope["project_path"] != resolved {
		t.Fatalf("echo = %s (%v)", raw, err)
	}

	raw, err = callMCP(ctx, coordinator, "commander_call_tool",
		toolregistry.Invocation{ID: "example.hello.project_files", Version: 1, Arguments: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	var files struct {
		Entries []struct{ Name, Kind string }
	}
	if err := json.Unmarshal(raw, &files); err != nil || len(files.Entries) != 1 || files.Entries[0].Name != "README.md" {
		t.Fatalf("project_files = %s (%v)", raw, err)
	}
}
