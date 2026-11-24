package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// TestDevflowHarnessFixture is launched by the real runner as Claude or ACP.
// It follows the harness's supplied MCP configuration without calling a model.
func TestDevflowHarnessFixture(t *testing.T) {
	mode := os.Getenv("COMMANDER_TEST_DEVFLOW_HARNESS")
	if mode == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var err error
	if mode == "legacy" {
		err = runDevflowLegacyFixture(ctx)
	} else {
		err = runDevflowACPFixture(ctx)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		cancel()
		os.Exit(1)
	}
	cancel()
	os.Exit(0)
}

func runDevflowLegacyFixture(ctx context.Context) error {
	i := slices.Index(os.Args, "--mcp-config")
	if i < 0 || i+1 >= len(os.Args) {
		return errors.New("missing legacy MCP configuration")
	}
	data, err := os.ReadFile(os.Args[i+1])
	if err != nil {
		return err
	}
	var config mcpConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return err
	}
	if err := exerciseDevflowConnection(ctx, config.Servers["devflow"]); err != nil {
		return err
	}
	if _, err := io.Copy(io.Discard, os.Stdin); err != nil {
		return err
	}
	_, err = fmt.Fprintln(os.Stdout, `{"type":"result","subtype":"success","result":"Devflow MCP verified."}`)
	return err
}

func runDevflowACPFixture(ctx context.Context) error {
	input, output := json.NewDecoder(os.Stdin), json.NewEncoder(os.Stdout)
	var companion mcpServer
	for {
		var request struct {
			ID     json.RawMessage
			Method string
			Params struct {
				ModelID    string
				MCPServers []struct {
					Name, Command string
					Args          []string
					Env           []struct{ Name, Value string }
				}
			}
		}
		if err := input.Decode(&request); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		result := map[string]any{}
		switch request.Method {
		case "initialize":
			result["protocolVersion"] = 1
		case "session/new":
			result["sessionId"] = "devflow-fixture-session"
			for _, server := range request.Params.MCPServers {
				if server.Name != "devflow" {
					continue
				}
				companion = mcpServer{Command: server.Command, Args: server.Args, Env: make(map[string]string)}
				for _, pair := range server.Env {
					companion.Env[pair.Name] = pair.Value
				}
			}
		case "session/set_model":
			if request.Params.ModelID != "opus" {
				return errors.New("managed Claude did not select Opus")
			}
		case "session/prompt":
			if err := exerciseDevflowConnection(ctx, companion); err != nil {
				return err
			}
			result["stopReason"] = "end_turn"
		default:
			return fmt.Errorf("unexpected ACP request %s", request.Method)
		}
		if err := output.Encode(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": result}); err != nil {
			return err
		}
	}
}

func exerciseDevflowConnection(ctx context.Context, server mcpServer) error {
	if server.Command == "" {
		return errors.New("runner did not attach Devflow")
	}
	command := exec.CommandContext(ctx, server.Command, server.Args...)
	command.Env = os.Environ()
	for name, value := range server.Env {
		command.Env = append(command.Env, name+"="+value)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "claude-code", Version: "fixture"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: command}, nil)
	if err != nil {
		return err
	}
	defer session.Close()
	tools, err := session.ListTools(ctx, nil)
	if err != nil {
		return err
	}
	if len(tools.Tools) != 1 || tools.Tools[0].Name != devflowTool {
		return errors.New("Devflow did not expose exactly its UI tool")
	}
	destination := devflowDestination{Screen: "providers", Role: "task_management"}
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: devflowTool, Arguments: destination})
	if err != nil {
		return err
	}
	var actual devflowDestination
	if result.IsError || len(result.Content) == 0 {
		return errors.New("Devflow returned no destination")
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok || json.Unmarshal([]byte(text.Text), &actual) != nil || actual != destination {
		return errors.New("Devflow did not confirm the requested destination")
	}
	return nil
}

func TestDevflowThroughManagedRunners(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_TMUX") != "1" {
		t.Skip("requires a real isolated tmux and Commander service")
	}
	if _, err := TmuxExecutable(); err != nil {
		t.Skip(err)
	}
	root, err := os.MkdirTemp("/tmp", "ac-df-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	binary := filepath.Join(root, "agentctl")
	build := exec.CommandContext(t.Context(), "go", "build", "-o", binary, "./cmd/agentctl")
	build.Dir = "../.."
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build Commander: %v %s", err, output)
	}
	for _, mode := range []string{"legacy", "acp"} {
		t.Run(mode, func(t *testing.T) {
			dir := filepath.Join(root, mode)
			checkout := filepath.Join(dir, "checkout")
			if err := os.MkdirAll(checkout, 0700); err != nil {
				t.Fatal(err)
			}
			socket, events := filepath.Join(dir, "s.sock"), filepath.Join(dir, "events")
			devflowFixture(t, checkout, "record")
			harness := filepath.Join(dir, "claude")
			if err := os.WriteFile(harness, []byte("#!/bin/sh\nexec \"$COMMANDER_TEST_MCP_HELPER\" -test.run='^TestDevflowHarnessFixture$' -- \"$@\"\n"), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("TMUX_TMPDIR", dir)
			t.Setenv("AGENT_COMMANDER_HOME", dir)
			t.Setenv("AGENT_COMMANDER_SOCKET", socket)
			t.Setenv("AGENT_COMMANDER_RUNTIME", mode)
			t.Setenv("AGENT_COMMANDER_CLAUDE", harness)
			t.Setenv("AGENT_COMMANDER_CLAUDE_ACP", harness)
			t.Setenv("AGENT_COMMANDER_FOCUSED_PROOF", "")
			t.Setenv("AGENT_COMMANDER_HOSTED_CONFIG", "")
			t.Setenv("COMMANDER_TEST_DEVFLOW_HARNESS", mode)
			t.Setenv("COMMANDER_TEST_DEVFLOW_EVENTS", events)
			runDevflowTestService(t, binary, socket, dir, checkout, events)
		})
	}
}

func runDevflowTestService(t *testing.T, binary, socket, dir, checkout, events string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	daemon := exec.CommandContext(ctx, binary, "serve")
	if err := daemon.Start(); err != nil {
		cancel()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cancel()
		_ = daemon.Wait()
	})
	owner := localapi.New(socket, "")
	poll := time.NewTicker(30 * time.Millisecond)
	defer poll.Stop()
	for {
		if _, err := owner.Do(ctx, http.MethodGet, "/v1/health", nil); err == nil {
			break
		}
		select {
		case <-poll.C:
		case <-ctx.Done():
			t.Fatal("Commander service did not start")
		}
	}
	data, err := owner.Do(ctx, http.MethodPost, "/v1/runs", map[string]string{
		"path": checkout, "task": "Open the Devflow task provider screen.",
	})
	if err != nil {
		t.Fatal(err)
	}
	var run service.Run
	if err := json.Unmarshal(data, &run); err != nil {
		t.Fatal(err)
	}
	local, err := New(dir, socket, binary)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = local.Stop(context.Background(), run.CoordinatorID) })
	for run.Status == "running" {
		select {
		case <-poll.C:
		case <-ctx.Done():
			t.Fatalf("timed out with coordinator state %+v", run.Workers)
		}
		data, err := owner.Do(ctx, http.MethodGet, "/v1/runs/"+run.ID, nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &run); err != nil {
			t.Fatal(err)
		}
	}
	if run.Status != "completed" {
		t.Fatalf("Devflow coordinator ended with %+v", run.Workers)
	}
	got, err := os.ReadFile(events)
	want := "probe\nauto " + run.CoordinatorID + "\nexplicit providers task_management\n"
	if err != nil || string(got) != want {
		t.Fatalf("Devflow lifecycle: got %q (%v), want %q", got, err, want)
	}
}
