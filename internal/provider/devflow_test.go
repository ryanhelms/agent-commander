package provider

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/service"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestDevflowCompanionFixture(t *testing.T) {
	mode := os.Getenv("COMMANDER_TEST_DEVFLOW_MODE")
	if mode == "" {
		return
	}
	if mode == "hang" {
		time.Sleep(time.Minute)
		os.Exit(1)
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "devflow-fixture", Version: "fixture"}, nil)
	install := func(name string) {
		mcp.AddTool(server, &mcp.Tool{Name: name}, func(context.Context, *mcp.CallToolRequest, struct{}) (*mcp.CallToolResult, struct{}, error) {
			// Discovery must never call a companion tool.
			os.Exit(1)
			return nil, struct{}{}, nil
		})
	}
	install(devflowTool)
	if mode == "too-broad" {
		install("some_other_tool")
	}
	if server.Run(context.Background(), &mcp.StdioTransport{}) != nil {
		os.Exit(1)
	}
	os.Exit(0)
}

func devflowFixture(t *testing.T, checkout, mode string) string {
	t.Helper()
	t.Setenv("COMMANDER_TEST_DEVFLOW_MODE", mode)
	t.Setenv("COMMANDER_TEST_CHECKOUT", checkout)
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("COMMANDER_TEST_MCP_HELPER", binary)
	name := filepath.Join(t.TempDir(), "devflow")
	script := `#!/bin/sh
[ "$#" = 4 ] && [ "$1" = mcp ] && [ "$2" = --ui-only ] && [ "$3" = --client ] && [ "$4" = agent-commander ] || exit 1
[ "$(pwd -P)" = "$(cd "$COMMANDER_TEST_CHECKOUT" && pwd -P)" ] || exit 1
exec "$COMMANDER_TEST_MCP_HELPER" -test.run='^TestDevflowCompanionFixture$'
`
	if err = os.WriteFile(name, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENT_COMMANDER_DEVFLOW", name)
	return name
}

func TestCoordinatorProbesOnlyNarrowCompanions(t *testing.T) {
	worker := service.LaunchSpec{Role: "coordinator", Path: t.TempDir()}
	t.Setenv("AGENT_COMMANDER_FOCUSED_PROOF", "")
	path := devflowFixture(t, worker.Path, "one")
	if got := coordinatorDevflow(t.Context(), worker); got != path {
		t.Fatalf("compatible companion: got %q, want %q", got, path)
	}
	t.Setenv("COMMANDER_TEST_DEVFLOW_MODE", "too-broad")
	if got := coordinatorDevflow(t.Context(), worker); got != "" {
		t.Fatal("registered a process exposing an additional MCP tool")
	}
	t.Setenv("COMMANDER_TEST_DEVFLOW_MODE", "hang")
	ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
	defer cancel()
	before := time.Now()
	if got := coordinatorDevflow(ctx, worker); got != "" || time.Since(before) > 3*time.Second {
		t.Fatal("unresponsive discovery did not cancel promptly")
	}
	t.Setenv("AGENT_COMMANDER_FOCUSED_PROOF", "1")
	t.Setenv("COMMANDER_TEST_DEVFLOW_MODE", "one")
	if got := coordinatorDevflow(t.Context(), worker); got != "" {
		t.Fatal("registered a companion for the focused proof")
	}
	t.Setenv("AGENT_COMMANDER_FOCUSED_PROOF", "")
	worker.Role = "worker"
	if got := coordinatorDevflow(t.Context(), worker); got != "" {
		t.Fatal("registered a companion for a planning worker")
	}
	t.Setenv("AGENT_COMMANDER_DEVFLOW", "./devflow")
	if got := devflowExecutable(); got != "" {
		t.Fatal("accepted a checkout-relative executable override")
	}
	t.Setenv("AGENT_COMMANDER_DEVFLOW", filepath.Join(worker.Path, "missing"))
	if got := devflowExecutable(); got != "" {
		t.Fatal("accepted a missing explicit executable")
	}
}

func TestCoordinatorAllowlistAndPrivateBinding(t *testing.T) {
	for _, tc := range []struct {
		role   string
		path   string
		active bool
	}{
		{"coordinator", "/trusted/devflow", true},
		{"coordinator", "", false},
		{"worker", "/trusted/devflow", false},
	} {
		dir := t.TempDir()
		worker := service.LaunchSpec{Role: tc.role, Path: dir, Token: "worker-only"}
		cmd, err := agentCommand(t.Context(), job{Worker: worker, DevflowUI: tc.path, Executable: "/agentctl", Claude: "/claude"}, dir)
		if err != nil {
			t.Fatal(err)
		}
		data, err := os.ReadFile(filepath.Join(dir, "mcp.json"))
		if err != nil {
			t.Fatal(err)
		}
		var conf mcpConfig
		if err = json.Unmarshal(data, &conf); err != nil {
			t.Fatal(err)
		}
		companion, configured := conf.Servers["devflow"]
		if configured != tc.active || (tc.active && len(conf.Servers) != 2) || (!tc.active && len(conf.Servers) != 1) || cmd.Dir != dir {
			t.Fatalf("%s: unexpected servers or target checkout", tc.role)
		}
		if configured && (companion.Command != tc.path || !slices.Equal(companion.Args, []string{"mcp", "--ui-only", "--client", "agent-commander", "--auto-open"}) || len(companion.Env) != 0) {
			t.Fatal("unexpected companion configuration or credentials")
		}
		if conf.Servers["commander"].Env["AGENT_COMMANDER_TOKEN"] != worker.Token {
			t.Fatal("Commander lost its scoped worker binding")
		}
		allowedIndex := slices.Index(cmd.Args, "--allowedTools")
		if allowedIndex == -1 || !slices.Contains(cmd.Args, "--strict-mcp-config") || !slices.Contains(cmd.Args, "dontAsk") {
			t.Fatal("runner lost strict tool permissions")
		}
		var devflow []string
		for _, name := range strings.Split(cmd.Args[allowedIndex+1], ",") {
			if strings.HasPrefix(name, "mcp__devflow") {
				devflow = append(devflow, name)
			}
		}
		if tc.active && !slices.Equal(devflow, []string{"mcp__devflow__devflow_ui_open"}) || !tc.active && len(devflow) != 0 {
			t.Fatalf("%s: unexpected allowed tools: %v", tc.role, devflow)
		}
	}
}

func TestReleasedDevflowUICompanion(t *testing.T) {
	path := os.Getenv("AGENT_COMMANDER_TEST_DEVFLOW_EXECUTABLE")
	if path == "" {
		t.Skip("set AGENT_COMMANDER_TEST_DEVFLOW_EXECUTABLE to a devflow binary with UI-only MCP")
	}
	dir := t.TempDir()
	if out, err := exec.Command("git", "-C", dir, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	t.Setenv("AGENT_COMMANDER_DEVFLOW", path)
	t.Setenv("AGENT_COMMANDER_FOCUSED_PROOF", "")
	if got := coordinatorDevflow(t.Context(), service.LaunchSpec{Role: "coordinator", Path: dir}); got != path {
		t.Fatal("installed Devflow did not advertise the UI-only tool for the temporary Git checkout")
	}
}
