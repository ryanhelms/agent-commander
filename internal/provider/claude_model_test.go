package provider

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	agentacp "agent-acp.local/sdks/go"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/service"
)

func TestManagedClaudeModelNegotiation(t *testing.T) {
	for _, tc := range []struct {
		mode    string
		wantErr string
	}{
		{"config-option", ""},
		{"legacy-method", ""},
		{"unsupported-option", "model unavailable"},
		{"missing-both-methods", "method unavailable"},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			j := job{Harness: "claude", Adapter: os.Args[0], Executable: "/bin/echo", Worker: service.LaunchSpec{Path: t.TempDir()}}
			cfg, err := planningConfig(j)
			if err != nil {
				t.Fatal(err)
			}
			cfg.Args = []string{"-test.run=^TestClaudeModelWirePeer$"}
			cfg.Env = map[string]string{"COMMANDER_MODEL_TEST_PEER": tc.mode}
			rt, err := runtime.New(cfg)
			if err != nil {
				t.Fatal(err)
			}
			defer rt.Close()
			ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
			defer cancel()
			session, err := agentacp.New(rt).Open(ctx, acpOpenRequest(j, cfg.HarnessInstance, j.Worker.Path))
			if tc.wantErr == "" {
				if err != nil || session.GetSession().GetRef().GetSessionId() != "selected" {
					t.Fatalf("open after Opus selection: %v", err)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.wantErr) || session.GetSession() != nil {
				t.Fatalf("rejected model selection: got %v, want %q", err, tc.wantErr)
			}
		})
	}
}

// Run as a child process by TestManagedClaudeModelNegotiation.
func TestClaudeModelWirePeer(t *testing.T) {
	mode := os.Getenv("COMMANDER_MODEL_TEST_PEER")
	if mode == "" {
		return
	}
	input, output := json.NewDecoder(os.Stdin), json.NewEncoder(os.Stdout)
	for {
		var req struct {
			ID     json.RawMessage
			Method string
			Params map[string]any
		}
		if input.Decode(&req) != nil {
			os.Exit(0)
		}
		response := map[string]any{"jsonrpc": "2.0", "id": req.ID}
		switch req.Method {
		case "initialize":
			response["result"] = map[string]any{"protocolVersion": 1, "agentCapabilities": map[string]any{}}
		case "session/new":
			result := map[string]any{"sessionId": "selected"}
			if mode == "config-option" || mode == "unsupported-option" {
				result["configOptions"] = []map[string]string{{"id": "provider-model", "type": "select", "category": "model", "currentValue": "other"}}
			}
			response["result"] = result
		case "session/set_config_option":
			if mode != "config-option" && mode != "unsupported-option" || req.Params["configId"] != "provider-model" || req.Params["value"] != "opus" || req.Params["sessionId"] != "selected" {
				os.Exit(2)
			}
			if mode == "unsupported-option" {
				response["error"] = map[string]any{"code": -32602, "message": "model unavailable"}
			} else {
				response["result"] = map[string]any{}
			}
		case "session/set_model":
			if mode != "legacy-method" && mode != "missing-both-methods" || req.Params["modelId"] != "opus" || req.Params["sessionId"] != "selected" {
				os.Exit(2)
			}
			if mode == "missing-both-methods" {
				response["error"] = map[string]any{"code": -32601, "message": "method unavailable"}
			} else {
				response["result"] = map[string]any{}
			}
		default:
			os.Exit(2)
		}
		if output.Encode(response) != nil {
			os.Exit(0)
		}
	}
}
