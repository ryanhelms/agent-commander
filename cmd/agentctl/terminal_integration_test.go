package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Exercise the shipped CLI, local API, provider and tmux on independently sized
// PTYs. Python supplies openpty and TIOCSWINSZ on both macOS and Linux.
func TestNativeTerminalObserver(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_TMUX") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_TMUX=1 for the native terminal PTY integration")
	}
	binary := filepath.Join(t.TempDir(), "agentctl")
	if out, err := exec.CommandContext(t.Context(), "go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build CLI: %v\n%s", err, out)
	}
	if out, err := exec.CommandContext(t.Context(), "python3", "testdata/observe_terminal.py", binary).CombinedOutput(); err != nil {
		t.Fatalf("exercise native terminal: %v\n%s", err, out)
	}
}
