package service

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"

	"agentcommander/internal/hosted"
	"agentcommander/internal/plugins"
)

// pluginLogTail bounds how much of plugin.log the cockpit receives.
const pluginLogTail = 16 << 10

// pluginRoutes serve the owner's cockpit Plugins page. Installs, grants and
// revokes reuse internal/plugins, so the CLI and the cockpit share one store.
// The service reads installed plugins and grants once at startup; the routes
// keep that snapshot so the page can say what waits for a restart.
type pluginRoutes struct {
	stateDir string
	// mu serializes grant changes made through the API.
	mu sync.Mutex
	// loaded is what the running service loaded: plugin ID to version and
	// digest, and project/tool to the grant value.
	loadedPlugins map[string]string
	loadedGrants  map[string]string
	snapshotErr   error
}

func newPluginRoutes(stateDir string) *pluginRoutes {
	p := &pluginRoutes{stateDir: stateDir, loadedPlugins: map[string]string{}, loadedGrants: map[string]string{}}
	records, err := plugins.List(stateDir)
	if err == nil {
		for _, r := range records {
			p.loadedPlugins[r.ID] = r.Version + "\x00" + r.Digest
		}
		var grants []plugins.ProjectGrant
		if grants, err = plugins.Grants(stateDir); err == nil {
			for _, g := range grants {
				p.loadedGrants[grantKey(g)] = grantValue(g)
			}
		}
	}
	p.snapshotErr = err
	return p
}

func grantKey(g plugins.ProjectGrant) string { return g.Project + "\x00" + g.Tool }

func grantValue(g plugins.ProjectGrant) string {
	settings := []byte(g.Settings)
	var compact bytes.Buffer
	if len(settings) != 0 && json.Compact(&compact, settings) == nil {
		settings = compact.Bytes()
	}
	raw, _ := json.Marshal(struct {
		V int
		S string
	}{g.Version, string(settings)})
	return string(raw)
}

func (p *pluginRoutes) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/plugins", p.owner(p.list))
	mux.HandleFunc("POST /v1/plugins/grants", p.owner(p.grant))
	mux.HandleFunc("POST /v1/plugins/grants/revoke", p.owner(p.revoke))
	mux.HandleFunc("GET /v1/plugins/{id}/log", p.owner(p.log))
}

func (p *pluginRoutes) owner(next func(http.ResponseWriter, *http.Request) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, supplied := r.Header["Authorization"]; supplied || hosted.From(r.Context()) != nil {
			respondError(w, denied())
			return
		}
		if err := next(w, r); err != nil {
			respondError(w, err)
		}
	}
}

// PluginGrant is one project grant of a plugin tool.
type PluginGrant struct {
	Project  string          `json:"project"`
	Version  int             `json:"version"`
	Settings json.RawMessage `json:"settings,omitempty"`
	// Active is false when the running service has not loaded this grant as
	// written, because it was added or changed after the service started.
	Active bool `json:"active"`
}

// PluginTool is one contributed tool with its grants.
type PluginTool struct {
	ID          string        `json:"id"`
	Version     int           `json:"version"`
	MCPTool     string        `json:"mcp_tool"`
	Description string        `json:"description,omitempty"`
	Grants      []PluginGrant `json:"grants"`
}

// PluginView is one installed plugin as the cockpit shows it.
type PluginView struct {
	ID             string          `json:"id"`
	Version        string          `json:"version"`
	Name           string          `json:"name"`
	Description    string          `json:"description,omitempty"`
	InstalledAt    string          `json:"installed_at"`
	Digest         string          `json:"digest"`
	SettingsSchema json.RawMessage `json:"settings_schema,omitempty"`
	// Problem names why the service refuses the plugin, such as a digest mismatch.
	Problem string `json:"problem,omitempty"`
	// Loaded is false when this version was installed after the service started.
	Loaded bool         `json:"loaded"`
	Tools  []PluginTool `json:"tools"`
}

// PluginList is the body of GET /v1/plugins and of every grant change.
type PluginList struct {
	Plugins []PluginView `json:"plugins"`
	// RestartRequired is true when installed plugins or grants differ from
	// what the running service loaded.
	RestartRequired bool `json:"restart_required"`
}

func (p *pluginRoutes) snapshot() (PluginList, error) {
	records, err := plugins.List(p.stateDir)
	if err != nil {
		return PluginList{}, &apiError{http.StatusServiceUnavailable, "read installed plugins: " + err.Error()}
	}
	grants, err := plugins.Grants(p.stateDir)
	if err != nil {
		return PluginList{}, &apiError{http.StatusServiceUnavailable, "read tool grants: " + err.Error()}
	}
	byTool := map[string][]plugins.ProjectGrant{}
	seen := map[string]bool{}
	restart := p.snapshotErr != nil
	for _, g := range grants {
		byTool[g.Tool] = append(byTool[g.Tool], g)
	}
	list := PluginList{Plugins: make([]PluginView, 0, len(records))}
	for _, r := range records {
		view := PluginView{
			ID: r.ID, Version: r.Version, Name: r.Name, Description: r.Description,
			InstalledAt: r.InstalledAt.UTC().Format("2006-01-02T15:04:05Z"), Digest: r.Digest,
			SettingsSchema: r.SettingsSchema, Loaded: p.loadedPlugins[r.ID] == r.Version+"\x00"+r.Digest,
			Tools: make([]PluginTool, 0, len(r.Tools)),
		}
		if err := r.Verify(p.stateDir); err != nil {
			view.Problem = "plugin " + r.ID + " " + r.Version + " refused: " + err.Error()
		}
		restart = restart || !view.Loaded
		for _, t := range r.Tools {
			tool := PluginTool{ID: t.ID, Version: t.Version, MCPTool: t.MCPTool, Description: t.Description, Grants: []PluginGrant{}}
			for _, g := range byTool[t.ID] {
				key := grantKey(g)
				seen[key] = true
				active := view.Loaded && p.loadedGrants[key] == grantValue(g)
				restart = restart || !active
				tool.Grants = append(tool.Grants, PluginGrant{Project: g.Project, Version: g.Version, Settings: g.Settings, Active: active})
			}
			view.Tools = append(view.Tools, tool)
		}
		list.Plugins = append(list.Plugins, view)
	}
	// A loaded plugin grant that has since been revoked also waits for a restart.
	for key := range p.loadedGrants {
		if seen[key] {
			continue
		}
		_, tool, _ := strings.Cut(key, "\x00")
		for id := range p.loadedPlugins {
			if strings.HasPrefix(tool, id+".") {
				restart = true
			}
		}
	}
	for id := range p.loadedPlugins {
		if !installed(records, id) {
			restart = true
		}
	}
	list.RestartRequired = restart
	return list, nil
}

func installed(records []plugins.Record, id string) bool {
	for _, r := range records {
		if r.ID == id {
			return true
		}
	}
	return false
}

func (p *pluginRoutes) respond(w http.ResponseWriter) error {
	list, err := p.snapshot()
	if err != nil {
		return err
	}
	writeHarnessJSON(w, list)
	return nil
}

func (p *pluginRoutes) list(w http.ResponseWriter, _ *http.Request) error { return p.respond(w) }

func decodePluginBody(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return bad("invalid request body: " + err.Error())
	}
	return nil
}

func pluginError(err error) error {
	if strings.HasPrefix(err.Error(), "no installed plugin provides ") {
		return missing("plugin tool")
	}
	return bad(err.Error())
}

func (p *pluginRoutes) grant(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		Tool     string          `json:"tool"`
		Version  int             `json:"version"`
		Project  string          `json:"project"`
		Settings json.RawMessage `json:"settings"`
	}
	if err := decodePluginBody(r, &body); err != nil {
		return err
	}
	if body.Tool == "" || body.Version < 1 || body.Project == "" {
		return bad(`a grant needs {"tool": string, "version": int, "project": absolute path, "settings"?: object}`)
	}
	if string(body.Settings) == "null" {
		body.Settings = nil
	}
	p.mu.Lock()
	err := plugins.Grant(p.stateDir, body.Tool, body.Version, body.Project, body.Settings)
	p.mu.Unlock()
	if err != nil {
		return pluginError(err)
	}
	return p.respond(w)
}

func (p *pluginRoutes) revoke(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		Tool    string `json:"tool"`
		Project string `json:"project"`
	}
	if err := decodePluginBody(r, &body); err != nil {
		return err
	}
	if body.Tool == "" || body.Project == "" {
		return bad(`a revoke needs {"tool": string, "project": absolute path}`)
	}
	// Revoke only tools an installed plugin provides; compiled tool grants
	// are not this page's to change.
	records, err := plugins.List(p.stateDir)
	if err != nil {
		return &apiError{http.StatusServiceUnavailable, "read installed plugins: " + err.Error()}
	}
	if !providesTool(records, body.Tool) {
		return missing("plugin tool")
	}
	p.mu.Lock()
	err = plugins.Revoke(p.stateDir, body.Tool, body.Project)
	p.mu.Unlock()
	if err != nil {
		return pluginError(err)
	}
	return p.respond(w)
}

func providesTool(records []plugins.Record, tool string) bool {
	for _, r := range records {
		for _, t := range r.Tools {
			if t.ID == tool {
				return true
			}
		}
	}
	return false
}

// PluginLog is the tail of one plugin's stderr log.
type PluginLog struct {
	Path      string `json:"path"`
	Text      string `json:"text"`
	Size      int64  `json:"size"`
	Truncated bool   `json:"truncated"`
}

func (p *pluginRoutes) log(w http.ResponseWriter, r *http.Request) error {
	records, err := plugins.List(p.stateDir)
	if err != nil {
		return &apiError{http.StatusServiceUnavailable, "read installed plugins: " + err.Error()}
	}
	id := r.PathValue("id")
	for _, record := range records {
		if record.ID != id {
			continue
		}
		out := PluginLog{Path: record.LogPath(p.stateDir)}
		file, err := os.Open(out.Path)
		if errors.Is(err, os.ErrNotExist) {
			writeHarnessJSON(w, out)
			return nil
		}
		if err != nil {
			return err
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil {
			return err
		}
		out.Size = info.Size()
		start := max(out.Size-pluginLogTail, 0)
		raw, err := io.ReadAll(io.NewSectionReader(file, start, out.Size-start))
		if err != nil {
			return err
		}
		if start > 0 {
			out.Truncated = true
			// Start at a line boundary so the tail does not begin mid-line.
			if i := bytes.IndexByte(raw, '\n'); i >= 0 && i < len(raw)-1 {
				raw = raw[i+1:]
			}
		}
		out.Text = strings.ToValidUTF8(string(raw), "�")
		writeHarnessJSON(w, out)
		return nil
	}
	return missing("plugin")
}
