package plugins

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/toolregistry"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const fixtureMode = "PLUGIN_FIXTURE_MODE"

// TestMain lets the test binary act as the plugin under test.
func TestMain(m *testing.M) {
	if os.Getenv(fixtureMode) == "serve" {
		serveFixture()
		return
	}
	os.Exit(m.Run())
}

func serveFixture() {
	server := mcp.NewServer(&mcp.Implementation{Name: "fixture", Version: "1"}, nil)
	type echoIn struct {
		Text string `json:"text"`
	}
	mcp.AddTool(server, &mcp.Tool{Name: "echo", Description: "Echo the text with the scope Commander sent."},
		func(_ context.Context, req *mcp.CallToolRequest, in echoIn) (*mcp.CallToolResult, map[string]any, error) {
			return nil, map[string]any{
				"text":     in.Text,
				"meta":     req.Params.Meta,
				"token":    os.Getenv("AGENT_COMMANDER_TOKEN"),
				"plugin":   os.Getenv("AGENT_COMMANDER_PLUGIN_ID"),
				"secret":   os.Getenv("FIXTURE_SECRET"),
				"disallow": os.Getenv("FIXTURE_UNLISTED"),
				"pid":      os.Getpid(),
			}, nil
		})
	mcp.AddTool(server, &mcp.Tool{Name: "hang", Description: "Never return."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
			time.Sleep(time.Hour)
			return nil, nil, nil
		})
	mcp.AddTool(server, &mcp.Tool{Name: "fail", Description: "Return a tool error."},
		func(context.Context, *mcp.CallToolRequest, struct{}) (*mcp.CallToolResult, any, error) {
			return nil, nil, errors.New("no such issue")
		})
	_ = server.Run(context.Background(), &mcp.StdioTransport{})
}

// fixturePackage writes a plugin package whose command is a copy of this test binary.
func fixturePackage(t *testing.T, id string, mutate func(*Manifest)) string {
	t.Helper()
	dir := t.TempDir()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	in, err := os.Open(self)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	if err := os.Mkdir(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := os.OpenFile(filepath.Join(dir, "bin", "server"), os.O_CREATE|os.O_WRONLY, 0o755)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(out, in); err != nil {
		t.Fatal(err)
	}
	out.Close()
	manifest := Manifest{
		Schema: 1, ID: id, Version: "1.0.0", Name: "Fixture",
		Command:  []string{"bin/server"},
		EnvAllow: []string{fixtureMode, "FIXTURE_SECRET"},
		Contributes: Contributions{Tools: []ToolContribution{
			{MCPTool: "echo", ID: id + ".echo", Version: 1, Action: toolregistry.Read},
			{MCPTool: "hang", ID: id + ".hang", Version: 1, Action: toolregistry.Read},
			{MCPTool: "fail", ID: id + ".fail", Version: 1, Action: toolregistry.Read},
		}},
		SettingsSchema: json.RawMessage(`{"type":"object","additionalProperties":false,"properties":{"site":{"type":"string"}}}`),
	}
	if mutate != nil {
		mutate(&manifest)
	}
	raw, _ := json.MarshalIndent(manifest, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, ManifestName), raw, 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func fixtureEnv() []string {
	return append(os.Environ(), fixtureMode+"=serve", "FIXTURE_SECRET=s3cret",
		"FIXTURE_UNLISTED=leak", "AGENT_COMMANDER_TOKEN=commander-token")
}

func install(t *testing.T, state, id string) Record {
	t.Helper()
	t.Setenv(fixtureMode, "serve")
	t.Setenv("FIXTURE_SECRET", "s3cret")
	t.Setenv("FIXTURE_UNLISTED", "leak")
	t.Setenv("AGENT_COMMANDER_TOKEN", "commander-token")
	record, err := Install(context.Background(), state, fixturePackage(t, id, nil), InstallOptions{environ: fixtureEnv})
	if err != nil {
		t.Fatal(err)
	}
	return record
}

func loadRegistry(t *testing.T, state string) (*Host, *toolregistry.Registry) {
	t.Helper()
	host, err := Load(state)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(host.Close)
	registry, err := toolregistry.Load(state, host.Tools()...)
	if err != nil {
		t.Fatal(err)
	}
	return host, registry
}

func runTool(t *testing.T, project toolregistry.Project, id string, timeout time.Duration, args string) (map[string]any, error) {
	t.Helper()
	tool, ok := project.Lookup(id, 1)
	if !ok {
		t.Fatalf("%s is not granted", id)
	}
	parsed, err := tool.Arguments(json.RawMessage(args))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	raw, err := tool.Run(ctx, toolregistry.Scope{RunID: "run-1", WorkerID: "worker-1", ProjectPath: project.Path}, parsed)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("result %s: %v", raw, err)
	}
	return out, nil
}

func TestManifestValidation(t *testing.T) {
	good := `{"schema":1,"id":"acme.jira","version":"1.0.0","name":"Jira","command":["bin/server"],
		"contributes":{"tools":[{"mcp_tool":"get","id":"acme.jira.get","version":1,"action":"read"}]}}`
	if _, err := ParseManifest([]byte(good)); err != nil {
		t.Fatalf("good manifest rejected: %v", err)
	}
	for name, edit := range map[string][2]string{
		"bad id":           {`"id":"acme.jira"`, `"id":"Acme"`},
		"escaping command": {`["bin/server"]`, `["../server"]`},
		"absolute command": {`["bin/server"]`, `["/bin/sh"]`},
		"write action":     {`"action":"read"`, `"action":"write"`},
		"foreign tool id":  {`"id":"acme.jira.get"`, `"id":"other.get"`},
		"reserved env":     {`"name":"Jira"`, `"name":"Jira","env_allow":["AGENT_COMMANDER_TOKEN"]`},
		"unknown field":    {`"name":"Jira"`, `"name":"Jira","hooks":[]`},
		"no tools":         {`[{"mcp_tool":"get","id":"acme.jira.get","version":1,"action":"read"}]`, `[]`},
	} {
		if _, err := ParseManifest([]byte(strings.Replace(good, edit[0], edit[1], 1))); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestInstallGrantAndCall(t *testing.T) {
	state, project, other := t.TempDir(), t.TempDir(), t.TempDir()
	record := install(t, state, "example.hello")
	if len(record.Tools) != 3 || !strings.HasPrefix(record.Digest, "sha256:") {
		t.Fatalf("record = %+v", record)
	}
	if err := Grant(state, "example.hello.echo", 1, project, json.RawMessage(`{"site":"acme"}`)); err != nil {
		t.Fatal(err)
	}
	if err := Grant(state, "example.hello.echo", 2, project, nil); err == nil {
		t.Fatal("granted a version the plugin does not provide")
	}
	if err := Grant(state, "example.hello.echo", 1, project, json.RawMessage(`{"nope":1}`)); err == nil {
		t.Fatal("granted settings that do not match the schema")
	}
	_, registry := loadRegistry(t, state)

	if _, ok := registry.Project(other).Lookup("example.hello.echo", 1); ok {
		t.Fatal("tool visible in an ungranted project")
	}
	granted := registry.Project(project)
	if got := len(granted.Descriptors()); got != 1 {
		t.Fatalf("granted project lists %d tools, want 1", got)
	}
	out, err := runTool(t, granted, "example.hello.echo", 10*time.Second, `{"text":"hi"}`)
	if err != nil {
		t.Fatal(err)
	}
	meta := out["meta"].(map[string]any)
	scope := meta[MetaScope].(map[string]any)
	if out["text"] != "hi" || scope["worker_id"] != "worker-1" || scope["project_path"] != granted.Path {
		t.Fatalf("echo = %v", out)
	}
	if settings := meta[MetaSettings].(map[string]any); settings["site"] != "acme" {
		t.Fatalf("settings = %v", meta[MetaSettings])
	}
	if out["token"] != "" || out["disallow"] != "" {
		t.Fatalf("plugin received undeclared environment: %v", out)
	}
	if out["secret"] != "s3cret" || out["plugin"] != "example.hello" {
		t.Fatalf("plugin missed declared environment: %v", out)
	}
}

func TestToolErrorReachesAgent(t *testing.T) {
	state, project := t.TempDir(), t.TempDir()
	install(t, state, "example.hello")
	if err := Grant(state, "example.hello.fail", 1, project, nil); err != nil {
		t.Fatal(err)
	}
	_, registry := loadRegistry(t, state)
	out, err := runTool(t, registry.Project(project), "example.hello.fail", 10*time.Second, `{}`)
	if err != nil || !strings.Contains(out["error"].(string), "no such issue") {
		t.Fatalf("out = %v, err = %v", out, err)
	}
}

func TestHungCallRestartsPlugin(t *testing.T) {
	state, project := t.TempDir(), t.TempDir()
	install(t, state, "example.hello")
	for _, id := range []string{"example.hello.echo", "example.hello.hang"} {
		if err := Grant(state, id, 1, project, nil); err != nil {
			t.Fatal(err)
		}
	}
	_, registry := loadRegistry(t, state)
	granted := registry.Project(project)
	first, err := runTool(t, granted, "example.hello.echo", 10*time.Second, `{"text":"a"}`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := runTool(t, granted, "example.hello.hang", 300*time.Millisecond, `{}`); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("hang err = %v, want deadline", err)
	}
	second, err := runTool(t, granted, "example.hello.echo", 10*time.Second, `{"text":"b"}`)
	if err != nil {
		t.Fatal(err)
	}
	if first["pid"] == second["pid"] {
		t.Fatal("plugin was not restarted after a missed deadline")
	}
}

func TestTamperedPluginIsRefused(t *testing.T) {
	state, project := t.TempDir(), t.TempDir()
	record := install(t, state, "example.hello")
	if err := Grant(state, "example.hello.echo", 1, project, nil); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(record.Dir(state), "extra.js"), []byte("evil"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, registry := loadRegistry(t, state)
	if len(host.Problems) != 1 || !strings.Contains(host.Problems[0].Error(), "digest") {
		t.Fatalf("problems = %v", host.Problems)
	}
	if _, err := runTool(t, registry.Project(project), "example.hello.echo", 5*time.Second, `{"text":"x"}`); !errors.Is(err, toolregistry.ErrUnavailable) {
		t.Fatalf("err = %v, want unavailable", err)
	}
}

func TestInstallRejectsCollisions(t *testing.T) {
	state := t.TempDir()
	t.Setenv(fixtureMode, "serve")
	pkg := fixturePackage(t, "example.hello", nil)
	if _, err := Install(context.Background(), state, pkg, InstallOptions{Reserved: []string{"example.hello.echo"}}); err == nil {
		t.Fatal("installed a tool that shadows a compiled one")
	}
	install(t, state, "example.hello")
	clash := fixturePackage(t, "example.other", func(m *Manifest) {
		m.Contributes.Tools[0].ID = "example.hello.echo"
	})
	if _, err := Install(context.Background(), state, clash, InstallOptions{}); err == nil {
		t.Fatal("installed a tool id that does not start with its plugin id")
	}
}

func TestInstallRejectsMissingMCPTool(t *testing.T) {
	state := t.TempDir()
	t.Setenv(fixtureMode, "serve")
	pkg := fixturePackage(t, "example.hello", func(m *Manifest) { m.Contributes.Tools[0].MCPTool = "absent" })
	if _, err := Install(context.Background(), state, pkg, InstallOptions{environ: fixtureEnv}); err == nil || !strings.Contains(err.Error(), "absent") {
		t.Fatalf("err = %v", err)
	}
	if records, _ := List(state); len(records) != 0 {
		t.Fatal("failed install left a record")
	}
}

func TestRemoveWithdrawsGrants(t *testing.T) {
	state, project := t.TempDir(), t.TempDir()
	install(t, state, "example.hello")
	if err := os.WriteFile(filepath.Join(state, grantsName), []byte(`{"projects":[{"path":"`+project+`","tools":{"linear.issue.read":1}}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Grant(state, "example.hello.echo", 1, project, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := Remove(state, "example.hello"); err != nil {
		t.Fatal(err)
	}
	file, err := readGrants(state)
	if err != nil {
		t.Fatal(err)
	}
	if len(file.Projects) != 1 || len(file.Projects[0].Tools) != 1 || file.Projects[0].Tools["linear.issue.read"] == nil {
		t.Fatalf("grants after remove = %+v", file)
	}
	if _, err := os.Stat(filepath.Join(Root(state), "example.hello")); !os.IsNotExist(err) {
		t.Fatal("plugin files remain after remove")
	}
}

func TestBareCommandFallsBackToInstallPath(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	l := launch{command: []string{filepath.Base(self)}, fallback: self,
		environ: func() []string { return []string{"PATH=/nonexistent"} }}
	if got, err := l.program(); err != nil || got != self {
		t.Fatalf("program = %q, %v", got, err)
	}
	l.fallback = "/bin/sh" // A fallback for a different program name is ignored.
	if _, err := l.program(); err == nil {
		t.Fatal("used a fallback whose name does not match the command")
	}
}

// installPackage installs a fixture package with the fixture's environment.
func installPackage(t *testing.T, state, id string, mutate func(*Manifest)) (Record, error) {
	t.Helper()
	t.Setenv(fixtureMode, "serve")
	return Install(context.Background(), state, fixturePackage(t, id, mutate), InstallOptions{environ: fixtureEnv})
}

func TestUpgradeKeepsEveryGrantServable(t *testing.T) {
	state, project := t.TempDir(), t.TempDir()
	install(t, state, "example.hello")
	if err := Grant(state, "example.hello.echo", 1, project, json.RawMessage(`{"site":"acme"}`)); err != nil {
		t.Fatal(err)
	}
	if err := Grant(state, "example.hello.fail", 1, project, nil); err != nil {
		t.Fatal(err)
	}
	for name, upgrade := range map[string]struct {
		mutate func(*Manifest)
		want   string
	}{
		"tool version bumped": {func(m *Manifest) {
			m.Version = "2.0.0"
			m.Contributes.Tools[0].Version = 2
		}, "example.hello.echo@1 for " + project + ": version 2.0.0 provides tool version 2"},
		"tool dropped": {func(m *Manifest) {
			m.Version = "2.0.0"
			m.Contributes.Tools = m.Contributes.Tools[:2]
		}, "example.hello.fail@1 for " + project + ": version 2.0.0 no longer provides this tool"},
		"settings no longer accepted": {func(m *Manifest) {
			m.Version = "2.0.0"
			m.SettingsSchema = json.RawMessage(`{"type":"object","additionalProperties":false,"properties":{"region":{"type":"string"}}}`)
		}, "example.hello.echo@1 for " + project + ": plugin settings do not match"},
	} {
		_, err := installPackage(t, state, "example.hello", upgrade.mutate)
		if err == nil || !strings.Contains(err.Error(), upgrade.want) || !strings.Contains(err.Error(), "agentctl plugin revoke") {
			t.Fatalf("%s: err = %v, want it to name %q", name, err, upgrade.want)
		}
	}
	// Nothing changed: the old version is still installed and the service still starts.
	installed, err := List(state)
	if err != nil || len(installed) != 1 || installed[0].Version != "1.0.0" {
		t.Fatalf("installed = %+v, %v", installed, err)
	}
	if _, err := os.Stat(installed[0].Dir(state)); err != nil {
		t.Fatalf("old package removed: %v", err)
	}
	_, registry := loadRegistry(t, state)
	if _, err := runTool(t, registry.Project(project), "example.hello.echo", 10*time.Second, `{"text":"still"}`); err != nil {
		t.Fatal(err)
	}

	// A compatible upgrade goes through and the grants still bind.
	if _, err := installPackage(t, state, "example.hello", func(m *Manifest) { m.Version = "1.1.0" }); err != nil {
		t.Fatalf("compatible upgrade: %v", err)
	}
	host, err := Load(state)
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	if _, err := toolregistry.Load(state, host.Tools()...); err != nil {
		t.Fatalf("service would not start after a compatible upgrade: %v", err)
	}
}

func TestReservedVersionsCannotReplacePluginData(t *testing.T) {
	good := `{"schema":1,"id":"acme.jira","version":"1.0.0","name":"Jira","command":["bin/server"],
		"contributes":{"tools":[{"mcp_tool":"get","id":"acme.jira.get","version":1,"action":"read"}]}}`
	for _, version := range []string{"data", "Data", "plugin.log", "PLUGIN.LOG"} {
		if _, err := ParseManifest([]byte(strings.Replace(good, `"1.0.0"`, `"`+version+`"`, 1))); err == nil {
			t.Errorf("version %q accepted", version)
		}
	}
	state := t.TempDir()
	record := install(t, state, "example.hello")
	saved := filepath.Join(record.DataDir(state), "saved.json")
	if err := os.MkdirAll(record.DataDir(state), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(saved, []byte(`{"keep":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := installPackage(t, state, "example.hello", func(m *Manifest) { m.Version = "data" }); err == nil {
		t.Fatal("installed a version named data")
	}
	if raw, err := os.ReadFile(saved); err != nil || string(raw) != `{"keep":true}` {
		t.Fatalf("plugin data lost: %q, %v", raw, err)
	}
}

func TestColdStartHonorsTheCallersDeadline(t *testing.T) {
	checked := errors.New("package check finished")
	sup := newSupervisor(launch{id: "example.slow"}, func() error {
		time.Sleep(300 * time.Millisecond)
		return checked
	})
	defer sup.close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	began := time.Now()
	if _, _, err := sup.get(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("first caller err = %v, want its deadline", err)
	}
	if waited := time.Since(began); waited > 150*time.Millisecond {
		t.Fatalf("the caller that began the start waited %v past a 20ms deadline", waited)
	}
	// The start carries on without that caller; the next caller sees how it ended.
	if _, _, err := sup.get(context.Background()); !errors.Is(err, checked) {
		t.Fatalf("second caller err = %v, want the start's result", err)
	}
}
