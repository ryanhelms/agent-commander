package provider

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"agentcommander/internal/service"
)

func TestManagedCodexPolicyReplacesAdapterToolAndTurnOverrides(t *testing.T) {
	checkout, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	policy := codexPolicy{Checkout: checkout, Server: mcpServer{Command: "/fixture/agentctl", Args: []string{"mcp"}}, Tools: []string{"commander_result"}}
	start := codexRPC{Method: "thread/start", Params: map[string]json.RawMessage{
		"cwd": rpcValue(checkout), "approvalPolicy": rpcValue("on-request"),
		"config":       rpcValue(map[string]any{"mcp_servers": map[string]any{"ambient": map[string]any{"enabled": true}}}),
		"dynamicTools": rpcValue([]string{"ambient"}),
	}}
	if err := policy.apply(&start, ""); err != nil {
		t.Fatal(err)
	}
	var native struct {
		Features   map[string]bool
		WebSearch  string `json:"web_search"`
		MCPServers map[string]struct {
			Command      string
			EnabledTools []string `json:"enabled_tools"`
			Tools        map[string]struct {
				ApprovalMode string `json:"approval_mode"`
			}
		} `json:"mcp_servers"`
		Projects map[string]struct {
			TrustLevel string `json:"trust_level"`
		}
	}
	if err := json.Unmarshal(start.Params["config"], &native); err != nil {
		t.Fatal(err)
	}
	server := native.MCPServers["commander"]
	if len(native.MCPServers) != 1 || server.Command != policy.Server.Command ||
		len(server.EnabledTools) != 1 || server.EnabledTools[0] != "commander_result" ||
		len(server.Tools) != 1 || server.Tools["commander_result"].ApprovalMode != "approve" ||
		native.Projects[checkout].TrustLevel != "untrusted" || start.Params["dynamicTools"] != nil {
		t.Fatal("managed session accepted adapter-supplied tool configuration")
	}
	for _, name := range []string{"shell_tool", "goals", "view_image", "image_generation", "request_permissions_tool", "skill_mcp_dependency_install", "plugins", "apps", "multi_agent"} {
		if enabled, configured := native.Features[name]; !configured || enabled {
			t.Errorf("managed Codex did not disable %s", name)
		}
	}
	if native.WebSearch != "disabled" {
		t.Error("managed Codex did not disable web search")
	}
	turn := codexRPC{Method: "turn/start", Params: map[string]json.RawMessage{
		"threadId": rpcValue("assigned"), "sandboxPolicy": rpcValue(map[string]string{"type": "dangerFullAccess"}),
		"permissions": rpcValue("custom"), "approvalPolicy": rpcValue("on-request"),
		"input": rpcValue([]map[string]string{{"type": "text", "text": "Line one\n$HOME"}}),
	}}
	if err := policy.apply(&turn, "assigned"); err != nil {
		t.Fatal(err)
	}
	if string(turn.Params["approvalPolicy"]) != `"never"` || string(turn.Params["sandboxPolicy"]) != `{"networkAccess":false,"type":"readOnly"}` ||
		turn.Params["permissions"] != nil || string(turn.Params["input"]) != `[{"text":"Line one\n$HOME","type":"text"}]` {
		t.Fatalf("unexpected native turn parameters: %v", turn.Params)
	}
	for _, method := range []string{"thread/resume", "turn/start", "turn/interrupt", "thread/read"} {
		if err := policy.apply(&codexRPC{Method: method, Params: map[string]json.RawMessage{"threadId": rpcValue("neighbor")}}, "assigned"); err == nil {
			t.Fatalf("%s allowed on a different worker thread", method)
		}
	}
	if err := validateCodexEffectiveConfig(json.RawMessage(`{"config":{"mcp_servers":{"ambient":{}}}}`)); err == nil {
		t.Fatal("managed Codex accepted inherited MCP configuration")
	}
}

func TestManagedCodexAvailabilityUsesDedicatedProfileLogin(t *testing.T) {
	profile := t.TempDir()
	if err := os.Chmod(profile, 0700); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(t.TempDir(), "codex")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\n[ \"$1\" = login ] && [ \"$2\" = status ] && [ -f \"$CODEX_HOME/signed-in\" ]\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENT_COMMANDER_RUNTIME", "acp")
	t.Setenv("AGENT_COMMANDER_FOCUSED_PROOF", "")
	t.Setenv("AGENT_COMMANDER_CODEX_PROFILE", profile)
	t.Setenv("AGENT_COMMANDER_CODEX", binary)
	t.Setenv("AGENT_COMMANDER_CODEX_ACP", binary)
	launcher := &Local{}
	if err := launcher.CheckClient("codex"); err == nil || !strings.Contains(err.Error(), "signed out") {
		t.Fatalf("expected the signed-out profile to be unavailable, got %v", err)
	}
	if err := os.WriteFile(filepath.Join(profile, "signed-in"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := launcher.CheckClient("codex"); err != nil {
		t.Fatalf("expected the signed-in dedicated profile to be available: %v", err)
	}
}

func TestManagedCodexRemovesInheritedAdapterOverrides(t *testing.T) {
	profile := t.TempDir()
	if err := os.Chmod(profile, 0700); err != nil {
		t.Fatal(err)
	}
	codex := managedCodex{Profile: profile, Executable: "/fixture/codex"}
	config, err := codex.config(job{
		Worker:  service.LaunchSpec{Path: t.TempDir(), Role: "worker"},
		Adapter: "/fixture/codex-acp", Executable: "/fixture/agentctl",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"-u", "CODEX_CONFIG", "-u", "DEFAULT_AUTH_REQUEST", "-u", "MODEL_PROVIDER", "/fixture/codex-acp"}
	if config.Command != "/usr/bin/env" || !slices.Equal(config.Args, want) {
		t.Fatalf("launcher does not unset adapter overrides before exec: %s %v", config.Command, config.Args)
	}
}
