package provider

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/service"
	"agentcommander/internal/toolregistry"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestDevflowCompanionFixture(t *testing.T) {
	mode := os.Getenv("COMMANDER_TEST_DEVFLOW_MODE")
	if mode == "" {
		return
	}
	live := os.Getenv("COMMANDER_TEST_DEVFLOW_LIVE") == "1"
	if live {
		if mode != "record" || os.Getenv("AGENT_COMMANDER_ROLE") != "coordinator" ||
			os.Getenv("AGENT_COMMANDER_TOKEN") == "" || os.Getenv("AGENT_COMMANDER_WORKER_ID") == "" ||
			!filepath.IsAbs(os.Getenv("AGENT_COMMANDER_SOCKET")) {
			os.Exit(2)
		}
	} else {
		for _, key := range []string{"AGENT_COMMANDER_SOCKET", "AGENT_COMMANDER_TOKEN", "AGENT_COMMANDER_WORKER_ID", "AGENT_COMMANDER_RUN_ID", "AGENT_COMMANDER_ROLE"} {
			if _, present := os.LookupEnv(key); present {
				os.Exit(1)
			}
		}
		if mode == "record" && recordDevflow("probe") != nil {
			os.Exit(2)
		}
	}
	if mode == "hang" {
		time.Sleep(time.Minute)
		os.Exit(1)
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "devflow-fixture", Version: "fixture"}, nil)
	if live {
		if recordDevflow("auto "+os.Getenv("AGENT_COMMANDER_WORKER_ID")) != nil {
			os.Exit(2)
		}
		mcp.AddTool(server, &mcp.Tool{Name: devflowTool}, func(_ context.Context, _ *mcp.CallToolRequest, in devflowDestination) (*mcp.CallToolResult, any, error) {
			if err := recordDevflow("explicit " + in.Screen + " " + in.Role); err != nil {
				return nil, nil, err
			}
			raw, err := json.Marshal(in)
			if err != nil {
				return nil, nil, err
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(raw)}}}, nil, nil
		})
		if server.Run(context.Background(), &mcp.StdioTransport{}) != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
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

type devflowDestination struct {
	Screen string `json:"screen"`
	Role   string `json:"role"`
}

func recordDevflow(event string) error {
	path := os.Getenv("COMMANDER_TEST_DEVFLOW_EVENTS")
	if path == "" {
		return errors.New("missing Devflow fixture events file")
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.WriteString(event + "\n")
	return err
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
[ "$1" = mcp ] && [ "$2" = --ui-only ] && [ "$3" = --client ] && [ "$4" = agent-commander ] || exit 1
case "$#" in
4) unset COMMANDER_TEST_DEVFLOW_LIVE ;;
5) [ "$5" = --auto-open ] || exit 1; export COMMANDER_TEST_DEVFLOW_LIVE=1 ;;
*) exit 1 ;;
esac
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
	assignment := job{Claude: "/fixture/claude", Worker: service.LaunchSpec{Role: "coordinator", Path: t.TempDir()}}
	registry := devflowRegistry(t, t.TempDir())
	probe := func(ctx context.Context) string {
		bindings := registry.BindCompanions(ctx, assignment.companionScope())
		if len(bindings) == 0 {
			return ""
		}
		if len(bindings) != 1 || bindings[0].ID != "devflow.ui" || bindings[0].Version != 1 {
			t.Fatalf("unexpected Devflow binding: %+v", bindings)
		}
		return bindings[0].Command
	}
	t.Setenv("AGENT_COMMANDER_TOKEN", "ambient-test-value")
	t.Setenv("AGENT_COMMANDER_WORKER_ID", "ambient-test-worker")
	path := devflowFixture(t, assignment.Worker.Path, "one")
	path, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := probe(t.Context()); got != path {
		t.Fatalf("compatible companion: got %q, want %q", got, path)
	}
	t.Setenv("COMMANDER_TEST_DEVFLOW_MODE", "too-broad")
	if got := probe(t.Context()); got != "" {
		t.Fatal("registered a process exposing an additional MCP tool")
	}
	t.Setenv("COMMANDER_TEST_DEVFLOW_MODE", "hang")
	ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
	defer cancel()
	before := time.Now()
	if got := probe(ctx); got != "" || time.Since(before) > 3*time.Second {
		t.Fatal("unresponsive discovery did not cancel promptly")
	}
	assignment.FocusedProof = true
	t.Setenv("COMMANDER_TEST_DEVFLOW_MODE", "one")
	if got := probe(t.Context()); got != "" {
		t.Fatal("registered a companion for the focused proof")
	}
	assignment.FocusedProof = false
	assignment.Worker.Role = "worker"
	if got := probe(t.Context()); got != "" {
		t.Fatal("registered a companion for a planning worker")
	}
	t.Setenv("AGENT_COMMANDER_DEVFLOW", "./devflow")
	if got := devflowExecutable(); got != "" {
		t.Fatal("accepted a checkout-relative executable override")
	}
	t.Setenv("AGENT_COMMANDER_DEVFLOW", filepath.Join(assignment.Worker.Path, "missing"))
	if got := devflowExecutable(); got != "" {
		t.Fatal("accepted a missing explicit executable")
	}
}

func devflowRegistry(t *testing.T, state string) *toolregistry.Registry {
	t.Helper()
	registry, err := toolregistry.Load(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.RegisterCompanion(DevflowCompanion()); err != nil {
		t.Fatal(err)
	}
	return registry
}

func TestCoordinatorAllowlistAndPrivateBinding(t *testing.T) {
	for _, tc := range []struct {
		role    string
		path    string
		focused bool
		active  bool
	}{
		{"coordinator", "/trusted/devflow", false, true},
		{"coordinator", "/trusted/devflow", true, false},
		{"coordinator", "", false, false},
		{"worker", "/trusted/devflow", false, false},
	} {
		dir := t.TempDir()
		worker := service.LaunchSpec{Role: tc.role, Path: dir, ID: "test-actor", RunID: "test-run", Token: "worker-only"}
		cmd, err := agentCommand(t.Context(), job{Worker: worker, FocusedProof: tc.focused, Socket: "/private/service.sock", DevflowUI: tc.path, Executable: "/agentctl", Claude: "/claude"}, dir)
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
		wantEnv := map[string]string{
			"AGENT_COMMANDER_SOCKET": "/private/service.sock", "AGENT_COMMANDER_TOKEN": worker.Token,
			"AGENT_COMMANDER_WORKER_ID": worker.ID, "AGENT_COMMANDER_ROLE": worker.Role,
		}
		if configured && (companion.Command != tc.path || !slices.Equal(companion.Args, []string{"mcp", "--ui-only", "--client", "agent-commander", "--auto-open"}) || !maps.Equal(companion.Env, wantEnv)) {
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

func TestDevflowLaunchCompatibilityAndScope(t *testing.T) {
	var pending job
	if err := json.Unmarshal([]byte(`{"Worker":{"Role":"coordinator","Host":"localhost"},"Claude":"/trusted/claude","DevflowUI":"/trusted/devflow"}`), &pending); err != nil {
		t.Fatal(err)
	}
	servers, _, allow := agentPolicy(pending)
	if servers["devflow"].Command != "/trusted/devflow" || !strings.Contains(allow, "mcp__devflow__devflow_ui_open") {
		t.Fatal("pending pre-registry launch lost its verified Devflow binding")
	}
	pending.Companions = []toolregistry.CompanionBinding{DevflowCompanion().Binding("/registered/devflow")}
	if servers, _, _ := agentPolicy(pending); servers["devflow"].Command != "/registered/devflow" {
		t.Fatal("legacy path overrode the selection in the new launch record")
	}
	for _, test := range []struct {
		name   string
		change func(*job)
	}{
		{"worker", func(j *job) { j.Worker.Role = "worker" }},
		{"SSH", func(j *job) { j.Worker.Host = "dev-linux"; j.SSH = &sshProfile{} }},
		{"Codex", func(j *job) { j.Codex = &managedCodex{} }},
		{"external ACP", func(j *job) { j.RegisteredACP = &acpProfile{} }},
		{"compiled adapter", func(j *job) { j.BuiltinInstance = "fixture" }},
		{"focused proof", func(j *job) { j.FocusedProof = true }},
	} {
		t.Run(test.name, func(t *testing.T) {
			job := pending
			test.change(&job)
			servers, _, allow := agentPolicy(job)
			if _, attached := servers["devflow"]; attached || strings.Contains(allow, "mcp__devflow__") {
				t.Fatal("ineligible job received a registered Devflow connection")
			}
		})
	}
	pending.Companions = []toolregistry.CompanionBinding{DevflowCompanion().Binding("")}
	servers, instructions, allow := agentPolicy(pending)
	if _, attached := servers["devflow"]; attached || strings.Contains(allow, "mcp__devflow__") || !strings.Contains(instructions, "devflow ui in the checkout") {
		t.Fatal("an unavailable selection should offer the local Devflow fallback")
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
	t.Setenv("DEVFLOW_NO_UPDATE", "1")
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	registry := devflowRegistry(t, t.TempDir())
	bindings := registry.BindCompanions(t.Context(), toolregistry.CompanionScope{
		ProjectPath: dir, Role: "coordinator", Host: "localhost", Interactive: true,
	})
	if len(bindings) != 1 || bindings[0].Command != resolved {
		t.Fatal("installed Devflow did not advertise the UI-only tool for the temporary Git checkout")
	}
}
