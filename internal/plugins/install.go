package plugins

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// InstallOptions adjusts an install. Reserved lists tool IDs already taken by
// compiled tools, so a plugin cannot shadow them.
type InstallOptions struct {
	Reserved []string
	// environ overrides the parent environment for the probe; tests set it.
	environ func() []string
}

// Install copies the package at src into the state directory, probes it once
// over MCP, freezes its tool schemas and pins its digest. Installing grants
// nothing. Installing another version of an installed plugin replaces it; the
// plugin's data directory is kept.
func Install(ctx context.Context, stateDir, src string, opts InstallOptions) (Record, error) {
	manifest, err := ReadManifest(src)
	if err != nil {
		return Record{}, err
	}
	installed, err := List(stateDir)
	if err != nil {
		return Record{}, err
	}
	for _, t := range manifest.Contributes.Tools {
		if slices.Contains(opts.Reserved, t.ID) {
			return Record{}, fmt.Errorf("tool id %q is already registered by Commander", t.ID)
		}
		for _, other := range installed {
			if other.ID == manifest.ID {
				continue
			}
			if slices.ContainsFunc(other.Tools, func(o ToolRecord) bool { return o.ID == t.ID }) {
				return Record{}, fmt.Errorf("tool id %q is already provided by plugin %s", t.ID, other.ID)
			}
		}
	}

	root := Root(stateDir)
	if err := ensurePrivateDir(root); err != nil {
		return Record{}, err
	}
	staging, err := os.MkdirTemp(root, ".staging-")
	if err != nil {
		return Record{}, err
	}
	defer os.RemoveAll(staging)
	pkg := filepath.Join(staging, "pkg")
	if err := os.Mkdir(pkg, 0o700); err != nil {
		return Record{}, err
	}
	if err := copyPackage(src, pkg); err != nil {
		return Record{}, fmt.Errorf("copy plugin package: %w", err)
	}
	digest, err := Digest(pkg)
	if err != nil {
		return Record{}, err
	}
	record := Record{
		ID: manifest.ID, Version: manifest.Version, Name: manifest.Name, Description: manifest.Description,
		Command: manifest.Command, EnvAllow: manifest.EnvAllow, SettingsSchema: manifest.SettingsSchema,
		Digest: digest, InstalledAt: time.Now().UTC().Truncate(time.Second),
	}
	probe := record.launch(stateDir)
	probe.dir, probe.dataDir, probe.logPath = pkg, filepath.Join(staging, "data"), filepath.Join(staging, "probe.log")
	if opts.environ != nil {
		probe.environ = opts.environ
	}
	if !strings.ContainsRune(manifest.Command[0], '/') {
		if program, err := probe.program(); err == nil {
			record.Program = program
		}
	}
	record.Tools, err = probeTools(ctx, probe, manifest.Contributes.Tools)
	if err != nil {
		if log, _ := readLimited(probe.logPath, 4<<10); len(bytes.TrimSpace(log)) > 0 {
			err = fmt.Errorf("%w\nplugin stderr:\n%s", err, bytes.TrimSpace(log))
		}
		return Record{}, err
	}

	// An upgrade must still serve every existing grant of the plugin's tools:
	// the service refuses to start on a grant it can't bind. Nothing is
	// changed until the check passes.
	if err := checkGrantsServed(stateDir, installed, record); err != nil {
		return Record{}, err
	}

	dest := record.Dir(stateDir)
	if reservedVersion(record.Version) {
		return Record{}, fmt.Errorf("plugin version %q is reserved", record.Version)
	}
	if err := ensurePrivateDir(filepath.Dir(dest)); err != nil {
		return Record{}, err
	}
	if err := os.RemoveAll(dest); err != nil {
		return Record{}, err
	}
	if err := os.Rename(pkg, dest); err != nil {
		return Record{}, err
	}
	var previous *Record
	next := slices.DeleteFunc(installed, func(r Record) bool {
		if r.ID == record.ID {
			old := r
			previous = &old
			return true
		}
		return false
	})
	if err := saveInstalled(stateDir, append(next, record)); err != nil {
		return Record{}, err
	}
	if previous != nil && previous.Version != record.Version {
		_ = os.RemoveAll(previous.Dir(stateDir))
	}
	return record, nil
}

// checkGrantsServed refuses an install that would leave a grant the new
// version can't serve: a tool it no longer provides, a version it doesn't
// provide, or settings its settings_schema rejects. It names each grant, so
// the operator can revoke it before installing and grant again after.
func checkGrantsServed(stateDir string, installed []Record, next Record) error {
	ids := map[string]bool{}
	for _, r := range installed {
		if r.ID == next.ID {
			for _, t := range r.Tools {
				ids[t.ID] = true
			}
		}
	}
	provided := map[string]ToolRecord{}
	for _, t := range next.Tools {
		ids[t.ID] = true
		provided[t.ID] = t
	}
	file, err := readGrants(stateDir)
	if err != nil {
		return err
	}
	var problems []string
	for _, project := range file.Projects {
		for id, raw := range project.Tools {
			if !ids[id] {
				continue
			}
			version, settings, err := parseGrant(raw)
			where := fmt.Sprintf("%s@%d for %s", id, version, project.Path)
			tool, ok := provided[id]
			switch {
			case err != nil:
				problems = append(problems, fmt.Sprintf("%s: %v", id+" for "+project.Path, err))
			case !ok:
				problems = append(problems, where+": version "+next.Version+" no longer provides this tool")
			case tool.Version != version:
				problems = append(problems, fmt.Sprintf("%s: version %s provides tool version %d", where, next.Version, tool.Version))
			default:
				if err := validateSettings(next, settings); err != nil {
					problems = append(problems, fmt.Sprintf("%s: %v", where, err))
				}
			}
		}
	}
	if len(problems) == 0 {
		return nil
	}
	slices.Sort(problems)
	return fmt.Errorf("installing %s %s would leave grants it can't serve, and the service would not start:\n  %s\n"+
		"Revoke these grants (agentctl plugin revoke <tool> --project <path>), install, then grant the new versions",
		next.ID, next.Version, strings.Join(problems, "\n  "))
}

// parseGrant reads a grant value as the tool registry does: a bare version,
// or an object with version and settings.
func parseGrant(raw json.RawMessage) (int, json.RawMessage, error) {
	var version int
	if err := json.Unmarshal(raw, &version); err == nil {
		return version, nil, nil
	}
	var grant struct {
		Version  int             `json:"version"`
		Settings json.RawMessage `json:"settings,omitempty"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&grant); err != nil {
		return 0, nil, errors.New("expected a tool version or an object with version and settings")
	}
	return grant.Version, grant.Settings, nil
}

// probeTools starts the plugin once and reads each contributed tool's schema.
func probeTools(ctx context.Context, l launch, contributed []ToolContribution) ([]ToolRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, defaultStartTimeout)
	defer cancel()
	session, err := l.connect(ctx)
	if err != nil {
		return nil, err
	}
	defer session.Close()
	listed := map[string]*mcp.Tool{}
	for tool, err := range session.Tools(ctx, nil) {
		if err != nil {
			return nil, fmt.Errorf("list plugin tools: %w", err)
		}
		listed[tool.Name] = tool
	}
	records := make([]ToolRecord, 0, len(contributed))
	for _, c := range contributed {
		tool, ok := listed[c.MCPTool]
		if !ok {
			return nil, fmt.Errorf("plugin does not serve the MCP tool %q it contributes", c.MCPTool)
		}
		schema, err := json.Marshal(tool.InputSchema)
		if err != nil || tool.InputSchema == nil {
			return nil, fmt.Errorf("MCP tool %q has no input schema", c.MCPTool)
		}
		if _, err := resolveObjectSchema(schema); err != nil {
			return nil, fmt.Errorf("MCP tool %q input schema: %w", c.MCPTool, err)
		}
		description := strings.TrimSpace(c.Description)
		if description == "" {
			description = strings.TrimSpace(tool.Description)
		}
		if description == "" || len(description) > maxDescription {
			return nil, fmt.Errorf("tool %q needs a description of at most %d bytes", c.ID, maxDescription)
		}
		records = append(records, ToolRecord{
			ID: c.ID, Version: c.Version, MCPTool: c.MCPTool, Description: description, InputSchema: schema,
		})
	}
	return records, nil
}

// Remove uninstalls a plugin and withdraws every grant of its tools. The
// plugin's data directory and log are deleted with it.
func Remove(stateDir, id string) (Record, error) {
	installed, err := List(stateDir)
	if err != nil {
		return Record{}, err
	}
	index := slices.IndexFunc(installed, func(r Record) bool { return r.ID == id })
	if index < 0 {
		return Record{}, fmt.Errorf("plugin %s is not installed", id)
	}
	record := installed[index]
	ids := make([]string, 0, len(record.Tools))
	for _, t := range record.Tools {
		ids = append(ids, t.ID)
	}
	if err := revokeTools(stateDir, "", ids); err != nil {
		return Record{}, err
	}
	if err := saveInstalled(stateDir, slices.Delete(installed, index, index+1)); err != nil {
		return Record{}, err
	}
	if !pluginID.MatchString(record.ID) {
		return record, errors.New("refusing to delete files for an invalid plugin id")
	}
	return record, os.RemoveAll(filepath.Join(Root(stateDir), record.ID))
}
