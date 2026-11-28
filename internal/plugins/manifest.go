// Package plugins installs user-written, out-of-process MCP servers and exposes
// their read tools through the scoped tool registry. Commander never loads
// plugin code into its own process: each plugin runs as a supervised child that
// speaks MCP over stdio, with a stripped environment and no Commander
// credentials. Installing a plugin grants nothing; tool-grants.json remains the
// only route from a plugin tool to an agent.
package plugins

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"agentcommander/internal/toolregistry"
	"github.com/google/jsonschema-go/jsonschema"
)

// ManifestName is the file a plugin package carries at its root.
const ManifestName = "plugin.json"

const (
	maxManifestBytes = 64 << 10
	maxSchemaBytes   = 8192
	maxDescription   = 1024
)

var (
	// Plugin and tool IDs share the scoped tool ID rule, so they live in one namespace.
	pluginID     = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`)
	toolIDRule   = pluginID
	versionRule  = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$`)
	mcpToolName  = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,128}$`)
	envName      = regexp.MustCompile(`^[A-Z_][A-Z0-9_]{0,127}$`)
	reservedEnvs = []string{"AGENT_COMMANDER_", "COMMANDER_", "SSH_AUTH_SOCK", "DYLD_", "LD_"}
)

// Manifest is plugin.json.
type Manifest struct {
	Schema         int             `json:"schema"`
	ID             string          `json:"id"`
	Version        string          `json:"version"`
	Name           string          `json:"name"`
	Description    string          `json:"description,omitempty"`
	Command        []string        `json:"command"`
	EnvAllow       []string        `json:"env_allow,omitempty"`
	Contributes    Contributions   `json:"contributes"`
	SettingsSchema json.RawMessage `json:"settings_schema,omitempty"`
}

// Contributions lists what the plugin adds. Increment 1 accepts read tools only.
type Contributions struct {
	Tools []ToolContribution `json:"tools"`
}

// ToolContribution maps one MCP tool to a versioned Commander tool ID.
type ToolContribution struct {
	MCPTool     string              `json:"mcp_tool"`
	ID          string              `json:"id"`
	Version     int                 `json:"version"`
	Action      toolregistry.Action `json:"action"`
	Description string              `json:"description,omitempty"`
}

// ReadManifest reads and validates dir/plugin.json.
func ReadManifest(dir string) (Manifest, error) {
	path := filepath.Join(dir, ManifestName)
	info, err := os.Lstat(path)
	if err != nil {
		return Manifest{}, fmt.Errorf("read %s: %w", ManifestName, err)
	}
	if !info.Mode().IsRegular() {
		return Manifest{}, fmt.Errorf("%s must be a regular file", ManifestName)
	}
	file, err := os.Open(path)
	if err != nil {
		return Manifest{}, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maxManifestBytes+1))
	if err != nil {
		return Manifest{}, err
	}
	if len(raw) > maxManifestBytes {
		return Manifest{}, fmt.Errorf("%s exceeds 64 KiB", ManifestName)
	}
	return ParseManifest(raw)
}

// ParseManifest decodes a manifest strictly and validates it.
func ParseManifest(raw []byte) (Manifest, error) {
	var m Manifest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&m); err != nil {
		return Manifest{}, fmt.Errorf("invalid %s: %w", ManifestName, err)
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return Manifest{}, fmt.Errorf("unexpected data after %s", ManifestName)
	}
	return m, m.Validate()
}

// Validate checks everything that can be checked without running the plugin.
func (m Manifest) Validate() error {
	if m.Schema != 1 {
		return errors.New("plugin manifest schema must be 1")
	}
	if len(m.ID) > 64 || !pluginID.MatchString(m.ID) {
		return fmt.Errorf("plugin id %q must be dotted lowercase, such as acme.jira", m.ID)
	}
	if !versionRule.MatchString(m.Version) {
		return fmt.Errorf("plugin version %q is invalid", m.Version)
	}
	if strings.TrimSpace(m.Name) == "" || len(m.Name) > 128 || len(m.Description) > maxDescription {
		return errors.New("plugin name is required and must be short")
	}
	if err := validCommand(m.Command); err != nil {
		return err
	}
	seenEnv := map[string]bool{}
	for _, name := range m.EnvAllow {
		if !envName.MatchString(name) || seenEnv[name] || reservedEnv(name) {
			return fmt.Errorf("env_allow entry %q is invalid or reserved", name)
		}
		seenEnv[name] = true
	}
	if len(m.Contributes.Tools) == 0 {
		return errors.New("plugin contributes no tools")
	}
	seenMCP, seenID := map[string]bool{}, map[string]bool{}
	for _, t := range m.Contributes.Tools {
		if !mcpToolName.MatchString(t.MCPTool) || seenMCP[t.MCPTool] {
			return fmt.Errorf("mcp_tool %q is invalid or repeated", t.MCPTool)
		}
		if len(t.ID) > 64 || !toolIDRule.MatchString(t.ID) || seenID[t.ID] || !strings.HasPrefix(t.ID, m.ID+".") {
			return fmt.Errorf("tool id %q must be unique and start with the plugin id %q", t.ID, m.ID+".")
		}
		if t.Version < 1 {
			return fmt.Errorf("tool %q needs a version of 1 or more", t.ID)
		}
		if t.Action != toolregistry.Read {
			return fmt.Errorf("tool %q: only the read action is supported", t.ID)
		}
		if len(t.Description) > maxDescription {
			return fmt.Errorf("tool %q description exceeds %d bytes", t.ID, maxDescription)
		}
		seenMCP[t.MCPTool], seenID[t.ID] = true, true
	}
	if len(m.SettingsSchema) != 0 {
		if _, err := resolveObjectSchema(m.SettingsSchema); err != nil {
			return fmt.Errorf("settings_schema: %w", err)
		}
	}
	return nil
}

// validCommand accepts either a path inside the package (containing a slash,
// relative, no ..) or a bare program name looked up on PATH, such as node.
func validCommand(command []string) error {
	if len(command) == 0 || command[0] == "" || len(command) > 64 {
		return errors.New("plugin command must name a program")
	}
	program := command[0]
	if strings.ContainsRune(program, '/') {
		clean := filepath.Clean(program)
		if filepath.IsAbs(program) || clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
			return fmt.Errorf("plugin command %q must stay inside the package", program)
		}
	}
	for _, arg := range command {
		if strings.ContainsRune(arg, 0) || len(arg) > 4096 {
			return errors.New("plugin command arguments are invalid")
		}
	}
	return nil
}

func reservedEnv(name string) bool {
	for _, prefix := range reservedEnvs {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return name == "PATH" || name == "HOME"
}

func resolveObjectSchema(raw json.RawMessage) (*jsonschema.Resolved, error) {
	if len(raw) > maxSchemaBytes {
		return nil, fmt.Errorf("schema exceeds %d bytes", maxSchemaBytes)
	}
	var schema jsonschema.Schema
	if err := json.Unmarshal(raw, &schema); err != nil || schema.Type != "object" {
		return nil, errors.New("schema must be a JSON object schema")
	}
	resolved, err := schema.Resolve(nil)
	if err != nil {
		return nil, fmt.Errorf("schema must be self-contained: %w", err)
	}
	return resolved, nil
}
