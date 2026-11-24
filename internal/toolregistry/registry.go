// Package toolregistry scopes compiled read tools and local session companions.
package toolregistry

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"
	segmentjson "github.com/segmentio/encoding/json"
)

type Action string

const Read Action = "read"

type Descriptor struct {
	ID          string          `json:"id"`
	Version     int             `json:"version"`
	Action      Action          `json:"action"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema"`
}

// Scope carries the authenticated assignment and the resolved project directory.
type Scope struct {
	RunID, WorkerID, ProjectPath string
}

type Handler func(context.Context, Scope, map[string]any) (json.RawMessage, error)

// Tool is registered by trusted Go code. Run receives validated arguments and
// must honor the context deadline. It may be called concurrently. A configured
// tool supplies Bind instead of Run to create a handler for each project grant.
type Tool struct {
	Descriptor Descriptor
	Run        Handler
	Bind       func(json.RawMessage) (Handler, error)
}

type Invocation struct {
	ID        string          `json:"id"`
	Version   int             `json:"version"`
	Arguments json.RawMessage `json:"arguments"`
}

type Registered struct {
	tool   Tool
	schema *jsonschema.Resolved
}

func (t Registered) Arguments(raw json.RawMessage) (map[string]any, error) {
	var args map[string]any
	if _, err := segmentjson.Parse(raw, &args, segmentjson.UseInt64|segmentjson.UseUint64); err != nil ||
		args == nil || t.schema.Validate(args) != nil {
		return nil, errors.New("arguments do not match the registered tool schema")
	}
	return args, nil
}

func (t Registered) Run(ctx context.Context, scope Scope, args map[string]any) (json.RawMessage, error) {
	return t.tool.Run(ctx, scope, args)
}

type projectGrant struct {
	Path  string                     `json:"path"`
	Tools map[string]json.RawMessage `json:"tools"`
}

type toolGrant struct {
	Version  int             `json:"version"`
	Settings json.RawMessage `json:"settings,omitempty"`
}

func (t Registered) bindGrant(raw json.RawMessage) (Registered, error) {
	var grant toolGrant
	if err := json.Unmarshal(raw, &grant.Version); err != nil {
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&grant); err != nil {
			return Registered{}, errors.New("expected a tool version or an object with version and settings")
		}
	}
	if t.tool.Descriptor.Version != grant.Version {
		return Registered{}, fmt.Errorf("version %d is unavailable", grant.Version)
	}
	if t.tool.Bind == nil {
		if len(grant.Settings) != 0 {
			return Registered{}, errors.New("this tool does not accept project settings")
		}
		return t, nil
	}
	handler, err := t.tool.Bind(grant.Settings)
	if err != nil {
		return Registered{}, err
	}
	if handler == nil {
		return Registered{}, errors.New("tool did not bind a handler")
	}
	t.tool.Run = handler
	return t, nil
}

type Project struct {
	Path  string
	tools map[string]Registered
}

func (p Project) Descriptors() []Descriptor {
	descriptors := make([]Descriptor, 0, len(p.tools))
	for _, id := range slices.Sorted(maps.Keys(p.tools)) {
		descriptor := p.tools[id].tool.Descriptor
		descriptor.InputSchema = bytes.Clone(descriptor.InputSchema)
		descriptors = append(descriptors, descriptor)
	}
	return descriptors
}

func (p Project) Lookup(id string, version int) (Registered, bool) {
	tool, ok := p.tools[id]
	return tool, ok && tool.tool.Descriptor.Version == version
}

type Registry struct {
	projects   map[string]Project
	registered map[string]Registered
	companions []Companion
}

// Project authorizes the exact checkout spelling configured by the owner and
// checks that it still resolves to the directory bound at service startup.
func (r *Registry) Project(path string) Project {
	project, ok := r.projects[path]
	if !ok {
		return Project{}
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || resolved != project.Path {
		return Project{}
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return Project{}
	}
	return project
}

var toolID = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`)

// Load validates compiled registrations before reading the optional startup
// grants. Configuration can grant a registered version but cannot install code.
func Load(stateDir string, tools ...Tool) (*Registry, error) {
	registered := make(map[string]Registered, len(tools))
	for _, tool := range tools {
		descriptor := tool.Descriptor
		if len(descriptor.ID) > 64 || !toolID.MatchString(descriptor.ID) || descriptor.Version < 1 ||
			descriptor.Action != Read || (tool.Run == nil) == (tool.Bind == nil) || strings.TrimSpace(descriptor.Description) == "" ||
			len(descriptor.Description) > 1024 || len(descriptor.InputSchema) > 8192 {
			return nil, fmt.Errorf("invalid scoped tool registration %q", descriptor.ID)
		}
		if _, exists := registered[descriptor.ID]; exists {
			return nil, fmt.Errorf("duplicate scoped tool registration %q", descriptor.ID)
		}
		var schema jsonschema.Schema
		if err := json.Unmarshal(descriptor.InputSchema, &schema); err != nil || schema.Type != "object" {
			return nil, fmt.Errorf("scoped tool %q requires an object input schema", descriptor.ID)
		}
		resolved, err := schema.Resolve(nil)
		if err != nil {
			return nil, fmt.Errorf("scoped tool %q requires a self-contained input schema: %w", descriptor.ID, err)
		}
		tool.Descriptor.InputSchema = bytes.Clone(descriptor.InputSchema)
		registered[descriptor.ID] = Registered{tool: tool, schema: resolved}
	}

	grants, err := loadGrants(filepath.Join(stateDir, "tool-grants.json"))
	if err != nil {
		return nil, err
	}
	registry := &Registry{projects: make(map[string]Project, len(grants)), registered: registered}
	for _, grant := range grants {
		path := filepath.Clean(grant.Path)
		if !filepath.IsAbs(path) || len(grant.Tools) == 0 {
			return nil, errors.New("scoped tool grants require an absolute project path and tool versions")
		}
		if _, exists := registry.projects[path]; exists {
			return nil, fmt.Errorf("duplicate scoped tool project %q", path)
		}
		resolved, err := filepath.EvalSymlinks(path)
		if err != nil {
			return nil, fmt.Errorf("resolve scoped tool project %q: %w", path, err)
		}
		info, err := os.Stat(resolved)
		if err != nil || !info.IsDir() {
			return nil, fmt.Errorf("scoped tool project %q must be a directory", path)
		}
		project := Project{Path: resolved, tools: make(map[string]Registered, len(grant.Tools))}
		for id, raw := range grant.Tools {
			tool, ok := registered[id]
			if !ok {
				return nil, fmt.Errorf("scoped tool %q is unavailable", id)
			}
			bound, err := tool.bindGrant(raw)
			if err != nil {
				return nil, fmt.Errorf("grant scoped tool %q to %q: %w", id, path, err)
			}
			project.tools[id] = bound
		}
		registry.projects[path] = project
	}
	return registry, nil
}

func loadGrants(path string) ([]projectGrant, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("tool-grants.json must be a private regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) || opened.Mode().Perm()&0077 != 0 {
		return nil, errors.New("tool-grants.json changed while opening")
	}
	const limit = 64 << 10
	raw, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > limit {
		return nil, errors.New("tool-grants.json exceeds 64 KiB")
	}
	var config struct {
		Projects []projectGrant `json:"projects"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return nil, fmt.Errorf("read tool-grants.json: %w", err)
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) || config.Projects == nil {
		return nil, errors.New("tool-grants.json must contain an explicit projects array")
	}
	return config.Projects, nil
}
