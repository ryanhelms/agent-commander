package toolregistry

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func fixtureTool() Tool {
	return Tool{
		Descriptor: Descriptor{
			ID: "fixture.read", Version: 1, Action: Read, Description: "Fixture.",
			InputSchema: json.RawMessage(`{"type":"object"}`),
		},
		Run: func(context.Context, Scope, map[string]any) (json.RawMessage, error) {
			return json.RawMessage(`{}`), nil
		},
	}
}

func writeGrant(t *testing.T, state, project string, version int, mode os.FileMode) {
	t.Helper()
	body, err := json.Marshal(map[string][]map[string]any{"projects": {{"path": project, "tools": map[string]int{"fixture.read": version}}}})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(state, "tool-grants.json")
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func TestRegistryRequiresPrivateGrantForRegisteredVersion(t *testing.T) {
	project := t.TempDir()
	tool := fixtureTool()
	registry, err := Load(t.TempDir(), tool)
	if err != nil || len(registry.Project(project).Descriptors()) != 0 {
		t.Fatalf("registration alone must grant no access: %v", err)
	}
	for _, test := range []struct {
		name    string
		version int
		mode    os.FileMode
		tools   []Tool
	}{
		{"wrong version", 2, 0600, []Tool{tool}},
		{"unknown registration", 1, 0600, nil},
		{"duplicate registration", 1, 0600, []Tool{tool, tool}},
		{"public file", 1, 0644, []Tool{tool}},
	} {
		t.Run(test.name, func(t *testing.T) {
			state := t.TempDir()
			writeGrant(t, state, project, test.version, test.mode)
			if _, err := Load(state, test.tools...); err == nil {
				t.Fatal("expected invalid tool configuration to fail closed")
			}
		})
	}
}

func TestGrantStopsMatchingRetargetedProject(t *testing.T) {
	state := t.TempDir()
	original, replacement := t.TempDir(), t.TempDir()
	configured := filepath.Join(t.TempDir(), "checkout")
	if err := os.Symlink(original, configured); err != nil {
		t.Fatal(err)
	}
	writeGrant(t, state, configured, 1, 0600)
	registry, err := Load(state, fixtureTool())
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := registry.Project(configured).Lookup("fixture.read", 1); !ok {
		t.Fatal("expected the configured checkout to have a grant")
	}
	next := configured + ".next"
	if err := os.Symlink(replacement, next); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(next, configured); err != nil {
		t.Fatal(err)
	}
	if _, ok := registry.Project(configured).Lookup("fixture.read", 1); ok {
		t.Fatal("a retargeted checkout inherited the original grant")
	}
}
