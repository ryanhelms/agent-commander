// Package provider runs managed Claude conversations in dedicated tmux panes.
package provider

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"agentcommander/internal/service"
)

type Local struct {
	stateDir, socket, executable, label string
}

type job struct {
	Worker                            service.LaunchSpec
	Socket, Executable, Claude, Label string
}

func New(stateDir, socketPath, executable string) (*Local, error) {
	dir, err := filepath.Abs(stateDir)
	if err != nil {
		return nil, err
	}
	socket, err := filepath.Abs(socketPath)
	if err != nil {
		return nil, err
	}
	binary, err := filepath.Abs(executable)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dir, "jobs"), 0700); err != nil {
		return nil, err
	}
	sum := sha256.Sum256([]byte(dir))
	return &Local{dir, socket, binary, fmt.Sprintf("ac-%x", sum[:6])}, nil
}

// A Finder-launched process may lack the PATH entries used by a login shell.
func executablePath(name, override string) (string, error) {
	if path := os.Getenv(override); path != "" {
		if !filepath.IsAbs(path) {
			return "", fmt.Errorf("%s must contain an absolute path", override)
		}
		return exec.LookPath(path)
	}
	if found, err := exec.LookPath(name); err == nil {
		return filepath.Abs(found)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	for _, dir := range []string{filepath.Join(home, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"} {
		if found, err := exec.LookPath(filepath.Join(dir, name)); err == nil {
			return found, nil
		}
	}
	return "", fmt.Errorf("could not find %s; configure its full path with %s", name, override)
}

var validID = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,100}$`)

func (l *Local) Launch(ctx context.Context, w service.LaunchSpec) error {
	if !validID.MatchString(w.ID) {
		return errors.New("invalid worker ID")
	}
	if w.Client != "" && !strings.EqualFold(w.Client, "claude") && !strings.EqualFold(w.Client, "claude code") {
		return fmt.Errorf("managed provider unavailable: %s", w.Client)
	}
	tmux, err := executablePath("tmux", "AGENT_COMMANDER_TMUX")
	if err != nil {
		return err
	}
	claude, err := executablePath("claude", "AGENT_COMMANDER_CLAUDE")
	if err != nil {
		return err
	}
	dir := filepath.Join(l.stateDir, "jobs", w.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	jobPath := filepath.Join(dir, "launch.json")
	// The prompt and scoped credential stay in a private file, outside shell argv.
	contents, err := json.Marshal(job{w, l.socket, l.executable, claude, l.label})
	if err != nil {
		return err
	}
	if err := os.WriteFile(jobPath, contents, 0600); err != nil {
		return err
	}
	// tmux executes multi-argument commands directly. None of its arguments are prompt text.
	args := []string{"-L", l.label, "-f", "/dev/null", "new-session", "-d", "-s", w.ID, "-x", "120", "-y", "38", "-c", w.Path, "--", l.executable, "runner", jobPath, ";", "set-option", "-w", "-t", "=" + w.ID + ":", "remain-on-exit", "on"}
	out, err := exec.CommandContext(ctx, tmux, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("start tmux worker: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (l *Local) Stop(ctx context.Context, id string) error {
	if !validID.MatchString(id) {
		return errors.New("invalid worker ID")
	}
	tmux, err := executablePath("tmux", "AGENT_COMMANDER_TMUX")
	if err != nil {
		return err
	}
	out, err := exec.CommandContext(ctx, tmux, "-L", l.label, "kill-session", "-t", "="+id).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if !(strings.Contains(msg, "can't find session") || strings.Contains(msg, "no server running") || strings.Contains(msg, "No such file or directory")) {
			return fmt.Errorf("stop tmux worker: %w: %s", err, msg)
		}
	}
	return nil
}
