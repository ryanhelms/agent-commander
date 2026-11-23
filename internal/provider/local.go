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
	Adapter, Harness, NodePath        string        `json:",omitempty"`
	FocusedProof                      bool          `json:",omitempty"`
	DevflowUI                         string        `json:",omitempty"`
	SSH                               *sshProfile   `json:",omitempty"`
	Codex                             *managedCodex `json:",omitempty"`
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
	return &Local{stateDir: dir, socket: socket, executable: binary, label: fmt.Sprintf("ac-%x", sum[:6])}, nil
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

func localClientExecutable(client string, useACP bool) (string, error) {
	switch strings.ToLower(strings.TrimSpace(client)) {
	case "", "claude", "claude code":
		if useACP {
			return executablePath("claude-agent-acp", "AGENT_COMMANDER_CLAUDE_ACP")
		}
		return executablePath("claude", "AGENT_COMMANDER_CLAUDE")
	case "codex":
		if useACP {
			if _, err := configuredManagedCodex(); err != nil {
				return "", err
			}
			return executablePath("codex-acp", "AGENT_COMMANDER_CODEX_ACP")
		}
	}
	return "", fmt.Errorf("managed provider unavailable: %s", client)
}

func (l *Local) CheckClient(client string) error {
	useACP := os.Getenv("AGENT_COMMANDER_RUNTIME") == "acp" && os.Getenv("AGENT_COMMANDER_FOCUSED_PROOF") != "1"
	_, err := localClientExecutable(client, useACP)
	if err == nil && useACP && strings.EqualFold(strings.TrimSpace(client), "codex") {
		profile, profileErr := configuredManagedCodex()
		if profileErr != nil {
			return profileErr
		}
		return profile.checkLogin()
	}
	return err
}

func (l *Local) Launch(ctx context.Context, w service.LaunchSpec) error {
	if !validID.MatchString(w.ID) {
		return errors.New("invalid worker ID")
	}
	focused := os.Getenv("AGENT_COMMANDER_FOCUSED_PROOF") == "1"
	useACP := os.Getenv("AGENT_COMMANDER_RUNTIME") == "acp" && !focused
	var remote *sshProfile
	var executable string
	if w.Host != "" && w.Host != "localhost" {
		checkout, checkErr := l.WorkerCheckout(w.Host, w.Path, w.Client)
		if checkErr != nil {
			return checkErr
		}
		if checkout != w.Worktree {
			return errors.New("SSH checkout changed after worker reservation")
		}
		profile, profileErr := configuredSSHProfile()
		if profileErr != nil {
			return profileErr
		}
		remote = &profile
		useACP, focused = true, false
		executable = "/usr/bin/ssh"
	} else {
		var err error
		executable, err = localClientExecutable(w.Client, useACP)
		if err != nil {
			return err
		}
	}
	tmux, err := executablePath("tmux", "AGENT_COMMANDER_TMUX")
	if err != nil {
		return err
	}
	var claude, adapter, harness, nodePath string
	var codex *managedCodex
	if useACP {
		adapter, harness = executable, "claude"
		if remote == nil && strings.EqualFold(strings.TrimSpace(w.Client), "codex") {
			managed, err := configuredManagedCodex()
			if err != nil {
				return err
			}
			harness, codex = "codex", &managed
		}
		// tmux may retain an older server PATH after the service is restarted.
		if node, e := executablePath("node", "AGENT_COMMANDER_NODE"); e == nil {
			nodePath = filepath.Dir(node)
		}
	} else {
		claude = executable
	}
	dir := filepath.Join(l.stateDir, "jobs", w.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	jobPath := filepath.Join(dir, "launch.json")
	devflow := coordinatorDevflow(ctx, w)
	// The prompt and scoped credential stay in a private file, outside shell argv.
	contents, err := json.Marshal(job{
		Worker: w, Socket: l.socket, Executable: l.executable, Claude: claude, Label: l.label,
		FocusedProof: focused, Adapter: adapter, Harness: harness, NodePath: nodePath,
		DevflowUI: devflow, SSH: remote, Codex: codex,
	})
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
