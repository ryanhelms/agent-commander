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

	dest := record.Dir(stateDir)
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
