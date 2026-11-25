package provider

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

// The integration fixture uses the test binary as the real tmux runner. Only
// the model executable is replaced, so this exercise never sends a paid prompt.
func TestMain(m *testing.M) {
	if len(os.Args) == 2 && os.Args[1] == "acp-broker-proxy" {
		if err := RunACPBrokerProxy(context.Background(), os.Stdin, os.Stdout); err != nil {
			os.Stderr.WriteString(err.Error() + "\n")
			os.Exit(1)
		}
		os.Exit(0)
	}
	if len(os.Args) == 3 && os.Args[1] == "runner" {
		if err := Runner(os.Args[2]); err != nil {
			os.Stderr.WriteString(err.Error() + "\n")
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestLocalRunnerPrefersInstalledACPAndHonorsRollback(t *testing.T) {
	bin := t.TempDir()
	harnessDir := t.TempDir()
	harnessBin := filepath.Join(harnessDir, "node_modules", ".bin")
	if err := os.MkdirAll(harnessBin, 0700); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{filepath.Join(bin, "claude"), filepath.Join(harnessBin, "claude-agent-acp"), filepath.Join(harnessBin, "codex-acp")} {
		if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, key := range []string{"AGENT_COMMANDER_RUNTIME", "AGENT_COMMANDER_CLAUDE", "AGENT_COMMANDER_CLAUDE_ACP", "AGENT_COMMANDER_CODEX_ACP", "AGENT_COMMANDER_FOCUSED_PROOF"} {
		t.Setenv(key, "")
	}
	t.Setenv("PATH", bin)
	t.Setenv("AGENT_ACP_HARNESS_DIR", harnessDir)
	for client, name := range map[string]string{"Claude Code": "claude-agent-acp", "codex": "codex-acp"} {
		path, acp, err := localRunner(client)
		if err != nil || !acp || path != filepath.Join(harnessBin, name) {
			t.Fatalf("default %s runner = %q, %v, %v", client, path, acp, err)
		}
	}
	t.Setenv("AGENT_COMMANDER_RUNTIME", "legacy")
	path, acp, err := localRunner("claude")
	if err != nil || acp || path != filepath.Join(bin, "claude") {
		t.Fatalf("rollback runner = %q, %v, %v", path, acp, err)
	}
	t.Setenv("AGENT_COMMANDER_RUNTIME", "")
	t.Setenv("AGENT_COMMANDER_CLAUDE_ACP", filepath.Join(bin, "missing"))
	if _, _, err := localRunner("claude"); err == nil {
		t.Fatal("invalid explicit adapter was silently replaced")
	}
}

func TestPromptAndCredentialsStayOutOfArgv(t *testing.T) {
	dir := t.TempDir()
	spec := service.LaunchSpec{ID: "worker", RunID: "run", Role: "worker", Path: dir, Token: "private-binding", Task: "A $value\n\n with quotes \" here"}
	j := job{Worker: spec, Socket: "/tmp/example.sock", Executable: "/bin/echo", Claude: "/bin/cat", Label: "test"}
	cmd, err := agentCommand(context.Background(), j, dir)
	if err != nil {
		t.Fatal(err)
	}
	if at := slices.Index(cmd.Args, "--model"); at < 0 || at+1 >= len(cmd.Args) || cmd.Args[at+1] != "opus" {
		t.Fatal("legacy Claude command did not select Opus")
	}
	for _, arg := range cmd.Args {
		if strings.Contains(arg, spec.Token) || strings.Contains(arg, spec.Task) {
			t.Fatal("sensitive argument or prompt appeared in argv")
		}
	}
	info, err := os.Stat(filepath.Join(dir, "mcp.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("MCP file mode = %o", info.Mode().Perm())
	}
	raw, err := os.ReadFile(filepath.Join(dir, "mcp.json"))
	if err != nil {
		t.Fatal(err)
	}
	var conf mcpConfig
	if err = json.Unmarshal(raw, &conf); err != nil {
		t.Fatal(err)
	}
	server := conf.Servers["commander"]
	if server.Env["AGENT_COMMANDER_WORKER_ID"] != spec.ID || server.Env["AGENT_COMMANDER_TOKEN"] != spec.Token || server.Env["AGENT_COMMANDER_RUN_ID"] != spec.RunID {
		t.Fatal("incorrect scoped MCP identity")
	}
}

func TestManagedClaudeModelScope(t *testing.T) {
	for _, tc := range []struct {
		name string
		job  job
		want string
	}{
		{"Claude coordinator", job{Harness: "claude", Worker: service.LaunchSpec{Role: "coordinator"}}, "opus"},
		{"Claude worker", job{Harness: "claude", Worker: service.LaunchSpec{Role: "worker"}}, "opus"},
		{"SSH worker", job{Harness: "claude", SSH: &sshProfile{}}, "opus"},
		{"persistent SSH worker", job{Harness: "claude", SSH: &sshProfile{Persistent: true}}, "opus"},
		{"Codex", job{Harness: "codex", Codex: &managedCodex{}}, ""},
		{"registered ACP", job{RegisteredACP: &acpProfile{Command: "/custom/claude-agent-acp"}}, ""},
		{"builtin", job{Harness: "claude", BuiltinInstance: "local-builtin:claude@1"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			q := acpOpenRequest(tc.job, "worker-instance", "/workspace")
			if q.Model != tc.want || q.HarnessInstance != "worker-instance" || q.WorkingDirectory != "/workspace" {
				t.Fatalf("unexpected ACP open request %v", q)
			}
		})
	}
}

func TestIsolatedTmuxConversation(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_TMUX") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_TMUX=1 for a real isolated tmux session")
	}
	if _, err := executablePath("tmux", "AGENT_COMMANDER_TMUX"); err != nil {
		t.Skip(err)
	}
	dir, err := os.MkdirTemp("/tmp", "ac-tmux-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	t.Setenv("TMUX_TMPDIR", dir)
	path := filepath.Join(dir, "repo $example")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	fake := filepath.Join(dir, "claude fixture")
	script := "#!/bin/sh\ncat > received.txt\nprintf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Literal assignment received.\"}]}}' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"Literal assignment received.\"}'\n"
	if err := os.WriteFile(fake, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENT_COMMANDER_CLAUDE", fake)
	t.Setenv("AGENT_COMMANDER_RUNTIME", "legacy")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "api.sock")
	local, err := New(dir, socket, exe)
	if err != nil {
		t.Fatal(err)
	}
	handler, err := service.New(dir, local)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	a := &api{localapi.New(socket, "")}
	task := "Check $HOME, `git diff`, \"strings\", and\nseveral paragraphs.\n"
	var run service.Run
	if err := a.request("POST", "/v1/runs", map[string]string{"task": task, "path": path, "client": "claude"}, &run); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { local.Stop(context.Background(), run.CoordinatorID) })
	until := time.Now().Add(12 * time.Second)
	for time.Now().Before(until) {
		if err := a.request("GET", "/v1/runs/"+run.ID, nil, &run); err != nil {
			t.Fatal(err)
		}
		w := run.Workers[0]
		if w.State == "failed" {
			t.Fatalf("launch failed: %s; %s", w.Error, w.Output)
		}
		if w.State == "completed" && strings.Contains(w.Output, "Literal assignment received.") {
			break
		}
		time.Sleep(40 * time.Millisecond)
	}
	if run.Workers[0].State != "completed" || !strings.Contains(run.Workers[0].Output, "Literal assignment received.") {
		t.Fatalf("worker did not finish: %+v", run.Workers[0])
	}
	var attachment service.TerminalAttachment
	if err := a.request("GET", "/v1/workers/"+run.CoordinatorID+"/terminal", nil, &attachment); err != nil {
		t.Fatal(err)
	}
	if attachment.WorkerID != run.CoordinatorID || !tmuxSessionID.MatchString(attachment.SessionID) {
		t.Fatalf("terminal viewer did not resolve the real coordinator: %+v", attachment)
	}
	b, err := os.ReadFile(filepath.Join(path, "received.txt"))
	if err != nil || string(b) != task {
		t.Fatalf("stdin did not preserve prompt: %q (%v)", b, err)
	}
	tmux, _ := executablePath("tmux", "AGENT_COMMANDER_TMUX")
	pane, err := exec.Command(tmux, "-L", local.label, "capture-pane", "-p", "-t", "="+run.CoordinatorID+":").CombinedOutput()
	if err != nil || !strings.Contains(string(pane), "Literal assignment received.") {
		t.Fatalf("tmux pane did not show the result: %v %s", err, pane)
	}
}

func TestStreamShowsResolvedRequestWithoutDumpingRun(t *testing.T) {
	input := strings.Join([]string{
		`{"type":"system","message":"provider status"}`,
		`{"type":"assistant","message":{"content":[{"id":"tool1","type":"tool_use","name":"mcp__commander__commander_wait"}]}}`,
		`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool1","content":[{"type":"text","text":"{\"id\":\"q-1\",\"status\":\"answered\",\"answer\":\"Use $5 and 'x'.\"}"}]}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Using your answer."}]}}`,
		`{"type":"result","subtype":"success","result":"Using your answer."}`,
	}, "\n")
	screen := &screen{}
	if err := render(strings.NewReader(input), screen); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(screen.pending), "Answer to q-1: Use $5 and 'x'.") || strings.Count(string(screen.pending), "Using your answer.") != 1 {
		t.Fatalf("unexpected terminal output %s", screen.pending)
	}
}

func TestRepeatedStatusChecksLeaveTheConversationReadable(t *testing.T) {
	status := `{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"mcp__commander__commander_status"}]}}`
	progress := `{"type":"assistant","message":{"content":[{"type":"text","text":"First finding received."}]}}`
	input := strings.Join([]string{status, status, progress, status, `{"type":"result","subtype":"success"}`}, "\n")
	s := &screen{}
	if err := render(strings.NewReader(input), s); err != nil {
		t.Fatal(err)
	}
	want := "Checking worker progress…\nFirst finding received.\nChecking worker progress…\n"
	if got := string(s.pending); got != want {
		t.Fatalf("console = %q, want %q", got, want)
	}
}
