package service

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/plugins"
)

// installFakePlugin writes an installed plugin record and package directly, as
// plugins.Install would after a successful probe.
func installFakePlugin(t *testing.T, stateDir string) plugins.Record {
	t.Helper()
	record := plugins.Record{
		ID: "acme.mqtt", Version: "1.0.0", Name: "Acme MQTT", Command: []string{"bin/server"},
		SettingsSchema: json.RawMessage(`{"type":"object","additionalProperties":false,"properties":{"topics":{"type":"array","maxItems":2,"items":{"type":"string","minLength":1}}}}`),
		InstalledAt:    time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC),
		Tools: []plugins.ToolRecord{
			{ID: "acme.mqtt.list_topics", Version: 1, MCPTool: "list_topics", Description: "List topics.", InputSchema: json.RawMessage(`{"type":"object"}`)},
			{ID: "acme.mqtt.read_messages", Version: 2, MCPTool: "read_messages", Description: "Read messages.", InputSchema: json.RawMessage(`{"type":"object"}`)},
		},
	}
	dir := record.Dir(stateDir)
	if err := os.MkdirAll(filepath.Join(dir, "bin"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bin", "server"), []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	digest, err := plugins.Digest(dir)
	if err != nil {
		t.Fatal(err)
	}
	record.Digest = digest
	raw, _ := json.Marshal(map[string]any{"schema": 1, "plugins": []plugins.Record{record}})
	if err := os.WriteFile(filepath.Join(plugins.Root(stateDir), "installed.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return record
}

func decodePlugins(t *testing.T, raw []byte) PluginList {
	t.Helper()
	var list PluginList
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatalf("decode %s: %v", raw, err)
	}
	return list
}

func TestPluginRoutesServeOnlyTheOwner(t *testing.T) {
	f := newFixture(t)
	worker := f.run()
	for _, route := range []struct{ method, path string }{
		{http.MethodGet, "/v1/plugins"}, {http.MethodPost, "/v1/plugins/grants"},
		{http.MethodPost, "/v1/plugins/grants/revoke"}, {http.MethodGet, "/v1/plugins/acme.mqtt/log"},
	} {
		f.call(route.method, route.path, worker.Token, nil, http.StatusForbidden, "")
	}
}

func TestPluginListWithNothingInstalled(t *testing.T) {
	f := newFixture(t)
	list := decodePlugins(t, f.call(http.MethodGet, "/v1/plugins", "", nil, http.StatusOK, ""))
	if len(list.Plugins) != 0 || list.RestartRequired {
		t.Fatalf("expected an empty list, got %+v", list)
	}
}

func TestPluginGrantRevokeAndRestartState(t *testing.T) {
	dir := t.TempDir()
	installFakePlugin(t, dir)
	project := t.TempDir()
	// A grant present at startup is active.
	initial := `{"projects":[{"path":"` + project + `","tools":{"acme.mqtt.list_topics":{"version":1,"settings":{"topics":["a/#"]}}}}]}`
	if err := os.WriteFile(filepath.Join(dir, "tool-grants.json"), []byte(initial), 0o600); err != nil {
		t.Fatal(err)
	}
	f := &fixture{t: t, dir: dir, p: recorder{make(chan LaunchSpec, 10), make(chan string, 10)}}
	host, err := plugins.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(host.Close)
	if f.api, err = New(dir, f.p, host.Tools()...); err != nil {
		t.Fatal(err)
	}
	// A compiled tool's grant, written later, passes through untouched.
	withCompiled := `{"projects":[{"path":"` + project + `","tools":{"acme.mqtt.list_topics":{"version":1,"settings":{"topics":["a/#"]}},"linear.issue.read":{"version":1}}}]}`
	if err := os.WriteFile(filepath.Join(dir, "tool-grants.json"), []byte(withCompiled), 0o600); err != nil {
		t.Fatal(err)
	}

	list := decodePlugins(t, f.call(http.MethodGet, "/v1/plugins", "", nil, http.StatusOK, ""))
	if len(list.Plugins) != 1 || list.RestartRequired {
		t.Fatalf("unexpected list %+v", list)
	}
	p := list.Plugins[0]
	if p.ID != "acme.mqtt" || !p.Loaded || p.Problem != "" || len(p.Tools) != 2 || len(p.SettingsSchema) == 0 {
		t.Fatalf("unexpected plugin %+v", p)
	}
	if g := p.Tools[0].Grants; len(g) != 1 || g[0].Project != project || !g[0].Active || string(g[0].Settings) != `{"topics":["a/#"]}` {
		t.Fatalf("unexpected startup grant %+v", g)
	}

	// Settings are validated against the plugin's settings_schema.
	f.call(http.MethodPost, "/v1/plugins/grants", "", map[string]any{
		"tool": "acme.mqtt.read_messages", "version": 2, "project": project, "settings": map[string]any{"topics": []string{"a", "b", "c"}},
	}, http.StatusBadRequest, "")
	f.call(http.MethodPost, "/v1/plugins/grants", "", map[string]any{
		"tool": "acme.mqtt.read_messages", "version": 2, "project": project, "settings": map[string]any{"other": true},
	}, http.StatusBadRequest, "")
	// The tool version must match, the project must exist, the tool must be installed.
	f.call(http.MethodPost, "/v1/plugins/grants", "", map[string]any{"tool": "acme.mqtt.read_messages", "version": 1, "project": project}, http.StatusBadRequest, "")
	f.call(http.MethodPost, "/v1/plugins/grants", "", map[string]any{"tool": "acme.mqtt.read_messages", "version": 2, "project": filepath.Join(project, "nope")}, http.StatusBadRequest, "")
	f.call(http.MethodPost, "/v1/plugins/grants", "", map[string]any{"tool": "acme.other.tool", "version": 1, "project": project}, http.StatusNotFound, "")
	f.call(http.MethodPost, "/v1/plugins/grants", "", map[string]any{"tool": "acme.mqtt.read_messages", "version": 2, "project": project, "extra": 1}, http.StatusBadRequest, "")

	list = decodePlugins(t, f.call(http.MethodPost, "/v1/plugins/grants", "", map[string]any{
		"tool": "acme.mqtt.read_messages", "version": 2, "project": project, "settings": map[string]any{"topics": []string{"b/#"}},
	}, http.StatusOK, ""))
	g := list.Plugins[0].Tools[1].Grants
	if len(g) != 1 || g[0].Active || !list.RestartRequired {
		t.Fatalf("a new grant must wait for a restart: %+v restart=%v", g, list.RestartRequired)
	}

	// Revoking the new grant returns to what the service loaded.
	list = decodePlugins(t, f.call(http.MethodPost, "/v1/plugins/grants/revoke", "", map[string]any{"tool": "acme.mqtt.read_messages", "project": project}, http.StatusOK, ""))
	if len(list.Plugins[0].Tools[1].Grants) != 0 || list.RestartRequired {
		t.Fatalf("unexpected list after revoke %+v", list)
	}
	// Revoking a loaded grant waits for a restart too.
	list = decodePlugins(t, f.call(http.MethodPost, "/v1/plugins/grants/revoke", "", map[string]any{"tool": "acme.mqtt.list_topics", "project": project}, http.StatusOK, ""))
	if !list.RestartRequired {
		t.Fatal("revoking a loaded grant must require a restart")
	}
	// Compiled tool grants are not the plugin page's to revoke, and stay in the file.
	f.call(http.MethodPost, "/v1/plugins/grants/revoke", "", map[string]any{"tool": "linear.issue.read", "project": project}, http.StatusNotFound, "")
	grants, err := plugins.Grants(dir)
	if err != nil || len(grants) != 1 || grants[0].Tool != "linear.issue.read" {
		t.Fatalf("compiled grant must survive: %+v %v", grants, err)
	}
}

func TestPluginListReportsTamperedFiles(t *testing.T) {
	f := newFixture(t)
	record := installFakePlugin(t, f.dir)
	if err := os.WriteFile(filepath.Join(record.Dir(f.dir), "extra"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	list := decodePlugins(t, f.call(http.MethodGet, "/v1/plugins", "", nil, http.StatusOK, ""))
	p := list.Plugins[0]
	if !strings.Contains(p.Problem, "digest") {
		t.Fatalf("expected a digest problem, got %q", p.Problem)
	}
	// Installed after this service started, so it is not loaded yet.
	if p.Loaded || !list.RestartRequired {
		t.Fatalf("plugin installed after start must not be loaded: %+v", list)
	}
}

func TestPluginLogTail(t *testing.T) {
	f := newFixture(t)
	record := installFakePlugin(t, f.dir)
	var empty PluginLog
	if err := json.Unmarshal(f.call(http.MethodGet, "/v1/plugins/acme.mqtt/log", "", nil, http.StatusOK, ""), &empty); err != nil {
		t.Fatal(err)
	}
	if empty.Text != "" || empty.Size != 0 || empty.Path != record.LogPath(f.dir) {
		t.Fatalf("unexpected empty log %+v", empty)
	}
	f.call(http.MethodGet, "/v1/plugins/acme.nope/log", "", nil, http.StatusNotFound, "")
	f.call(http.MethodGet, "/v1/plugins/..%2F..%2Fetc/log", "", nil, http.StatusNotFound, "")

	line := strings.Repeat("x", 99) + "\n"
	body := "first line is partial\n" + strings.Repeat(line, 300) + "last\n"
	if err := os.WriteFile(record.LogPath(f.dir), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	var tail PluginLog
	if err := json.Unmarshal(f.call(http.MethodGet, "/v1/plugins/acme.mqtt/log", "", nil, http.StatusOK, ""), &tail); err != nil {
		t.Fatal(err)
	}
	if !tail.Truncated || tail.Size != int64(len(body)) || len(tail.Text) > pluginLogTail || !strings.HasSuffix(tail.Text, "last\n") || !strings.HasPrefix(tail.Text, "x") {
		t.Fatalf("unexpected tail: truncated=%v size=%d len=%d", tail.Truncated, tail.Size, len(tail.Text))
	}
}
