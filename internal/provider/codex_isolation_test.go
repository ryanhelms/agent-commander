package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// App Server launches configured MCP before the first prompt. The sentinel
// tools record exact launch behavior, independently of the model or network.
func TestCodexNativeCheckoutIsolation(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_CODEX_POLICY") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_CODEX_POLICY=1 to exercise the native Codex App Server")
	}
	binary, err := executablePath("codex", "AGENT_COMMANDER_CODEX")
	if err != nil {
		t.Fatal(err)
	}
	for _, ambientUserConfig := range []bool{false, true} {
		t.Run(fmt.Sprintf("user-MCP=%t", ambientUserConfig), func(t *testing.T) {
			dir := t.TempDir()
			profile, checkout := filepath.Join(dir, "profile"), filepath.Join(dir, "checkout")
			if err := os.MkdirAll(profile, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(checkout, ".codex"), 0700); err != nil {
				t.Fatal(err)
			}
			git := exec.Command("git", "init", "-q", checkout)
			if output, err := git.CombinedOutput(); err != nil {
				t.Fatalf("initialize fixture checkout: %v %s", err, output)
			}

			projectMarker := filepath.Join(dir, "project-started")
			userMarker := filepath.Join(dir, "user-started")
			scopedMarker := filepath.Join(dir, "scoped-started")
			projectConfig := fmt.Sprintf("[mcp_servers.checkout_fixture]\ncommand=\"/usr/bin/touch\"\nargs=[%q]\n", projectMarker)
			if err := os.WriteFile(filepath.Join(checkout, ".codex", "config.toml"), []byte(projectConfig), 0600); err != nil {
				t.Fatal(err)
			}
			// Canonicalize macOS temp paths so the trust override keys the same checkout.
			checkout, err := filepath.EvalSymlinks(checkout)
			if err != nil {
				t.Fatal(err)
			}
			config := fmt.Sprintf("[projects.%q]\ntrust_level=\"untrusted\"\n[features]\nplugins=false\napps=false\n", checkout)
			if ambientUserConfig {
				config += fmt.Sprintf("[mcp_servers.user_fixture]\ncommand=\"/usr/bin/touch\"\nargs=[%q]\n", userMarker)
			}
			if err := os.WriteFile(filepath.Join(profile, "config.toml"), []byte(config), 0600); err != nil {
				t.Fatal(err)
			}

			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, binary, "app-server", "--listen", "stdio://")
			cmd.Dir = dir
			cmd.Env = append(cmd.Environ(), "CODEX_HOME="+profile)
			stdin, err := cmd.StdinPipe()
			if err != nil {
				t.Fatal(err)
			}
			stdout, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() {
				_ = stdin.Close()
				_ = cmd.Process.Kill()
				_ = cmd.Wait()
			}()
			enc, dec := json.NewEncoder(stdin), json.NewDecoder(stdout)
			id := 0
			call := func(method string, params any, target any) {
				t.Helper()
				id++
				if err := enc.Encode(map[string]any{"id": id, "method": method, "params": params}); err != nil {
					t.Fatal(err)
				}
				for {
					var message struct {
						ID     int
						Error  json.RawMessage
						Result json.RawMessage
					}
					if err := dec.Decode(&message); err != nil {
						t.Fatal(err)
					}
					if message.ID != id {
						continue
					}
					if len(message.Error) != 0 && string(message.Error) != "null" {
						t.Fatalf("%s: %s", method, message.Error)
					}
					if target != nil {
						if err := json.Unmarshal(message.Result, target); err != nil {
							t.Fatal(err)
						}
					}
					return
				}
			}
			call("initialize", map[string]any{
				"clientInfo":   map[string]string{"name": "commander-policy-fixture", "version": "1"},
				"capabilities": map[string]bool{"experimentalApi": true},
			}, nil)
			if err := enc.Encode(map[string]string{"method": "initialized"}); err != nil {
				t.Fatal(err)
			}
			call("account/login/start", map[string]string{"type": "apiKey", "apiKey": "commander-offline-fixture"}, nil)
			var thread struct {
				ApprovalPolicy string
				Sandbox        struct{ Type string }
			}
			call("thread/start", map[string]any{
				"cwd": checkout, "sandbox": "read-only", "approvalPolicy": "never",
				"config": map[string]any{"mcp_servers": map[string]any{
					"commander_fixture": map[string]any{"command": "/usr/bin/touch", "args": []string{scopedMarker}},
				}},
			}, &thread)
			if thread.ApprovalPolicy != "never" || thread.Sandbox.Type != "readOnly" {
				t.Fatalf("unexpected native thread permissions: %+v", thread)
			}
			for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
				_, scopedErr := os.Stat(scopedMarker)
				_, userErr := os.Stat(userMarker)
				if scopedErr == nil && (!ambientUserConfig || userErr == nil) {
					break
				}
			}
			if _, err := os.Stat(scopedMarker); err != nil {
				t.Fatalf("scoped MCP tool did not start: %v", err)
			}
			if _, err := os.Stat(projectMarker); !os.IsNotExist(err) {
				t.Fatalf("untrusted checkout's MCP process should not start: %v", err)
			}
			if _, err := os.Stat(userMarker); ambientUserConfig && err != nil || !ambientUserConfig && !os.IsNotExist(err) {
				t.Fatalf("unexpected ambient user MCP launch: enabled=%t err=%v", ambientUserConfig, err)
			}
		})
	}
}
