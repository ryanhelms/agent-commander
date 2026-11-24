package provider

import (
	"encoding/json"
	"os"
	"slices"
	"testing"

	"agentcommander/internal/service"
)

func TestManagedHarnessesAllowScopedToolsForCoordinators(t *testing.T) {
	profile := t.TempDir()
	if err := os.Chmod(profile, 0700); err != nil {
		t.Fatal(err)
	}
	for _, role := range []string{"coordinator", "worker"} {
		t.Run(role, func(t *testing.T) {
			assignment := job{
				Worker:     service.LaunchSpec{Role: role, Path: t.TempDir()},
				Executable: "/fixture/agentctl",
				Adapter:    "/fixture/adapter",
				Harness:    "claude",
			}
			claudeConfig, err := planningConfig(assignment)
			if err != nil {
				t.Fatal(err)
			}
			claudeMeta := claudeConfig.SessionMeta["claudeCode"].(map[string]any)
			claudeAllowed := claudeMeta["options"].(map[string]any)["allowedTools"].([]string)
			codexConfig, err := (managedCodex{Executable: "/fixture/codex", Profile: profile}).config(assignment)
			if err != nil {
				t.Fatal(err)
			}
			var bridge codexBridgeConfig
			if err := json.Unmarshal([]byte(codexConfig.Env[codexBridgeEnv]), &bridge); err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"commander_list_tools", "commander_call_tool"} {
				want := role == "coordinator"
				if slices.Contains(claudeAllowed, "mcp__commander__"+name) != want || slices.Contains(bridge.Policy.Tools, name) != want {
					t.Fatalf("unexpected %s allowlist for %s: Claude %v, Codex %v", role, name, claudeAllowed, bridge.Policy.Tools)
				}
			}
		})
	}
}
