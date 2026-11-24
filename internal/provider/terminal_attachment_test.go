package provider

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestTerminalAttachmentIsolatedTmux(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_TMUX") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_TMUX=1 for the real tmux identity test")
	}
	tmux, err := executablePath("tmux", "AGENT_COMMANDER_TMUX")
	if err != nil {
		t.Fatal(err)
	}
	// Keep UNIX socket paths short on macOS.
	dir, err := os.MkdirTemp("/tmp", "ac-view-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	t.Setenv("TMUX_TMPDIR", dir)
	script := filepath.Join(dir, "fixture runner")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexec /bin/cat\n"), 0700); err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(dir, "state directory")
	local, err := New(stateDir, filepath.Join(dir, "api.sock"), script)
	if err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) {
		t.Helper()
		args = append([]string{"-L", local.label, "-f", "/dev/null"}, args...)
		if data, err := exec.CommandContext(t.Context(), tmux, args...).CombinedOutput(); err != nil {
			t.Fatalf("tmux fixture: %s (%v)", data, err)
		}
	}
	for _, id := range []string{"w-first", "w-first-extra"} {
		run("new-session", "-d", "-s", id, "--", script, "runner", filepath.Join(stateDir, "jobs", id, "launch.json"))
		t.Cleanup(func() { _ = exec.Command(tmux, "-N", "-L", local.label, "kill-session", "-t", "="+id).Run() })
	}
	a, err := local.ResolveTerminal(t.Context(), "w-first")
	if err != nil {
		t.Fatal(err)
	}
	b, err := local.ResolveTerminal(t.Context(), "w-first-extra")
	if err != nil || a.WorkerID != "w-first" || b.WorkerID != "w-first-extra" ||
		a.SessionID == b.SessionID || a.SocketPath != b.SocketPath || !filepath.IsAbs(a.SocketPath) {
		t.Fatalf("got %+v and %+v: %v", a, b, err)
	}
	if info, err := os.Stat(a.SocketPath); err != nil || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("returned path is not the server socket: %v", err)
	}
	if _, err := local.ResolveTerminal(t.Context(), "w-fir"); err == nil {
		t.Fatal("a session name prefix attached to a different worker")
	}
	run("swap-pane", "-s", "=w-first:", "-t", "=w-first-extra:")
	if _, err := local.ResolveTerminal(t.Context(), "w-first"); err == nil {
		t.Fatal("a swapped pane passed the original worker identity check")
	}
	run("swap-pane", "-s", "=w-first:", "-t", "=w-first-extra:")
	run("split-window", "-d", "-t", "=w-first:", "/bin/cat")
	if _, err := local.ResolveTerminal(t.Context(), "w-first"); err == nil {
		t.Fatal("a session with unrelated panes returned a worker attachment")
	}
}
