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
	"agentcommander/internal/toolregistry"
	"agentcommander/internal/worktrees"
)

type Local struct {
	stateDir, socket, executable, label string
	acpProfiles                         map[string]acpProfile
	replaySlot                          chan struct{}
	replayCache                         replayCache
	acpBroker                           *acpBrokerService
	tools                               *toolregistry.Registry
}

type job struct {
	Worker                            service.LaunchSpec
	Socket, Executable, Claude, Label string
	Adapter, Harness, NodePath        string          `json:",omitempty"`
	BuiltinInstance                   string          `json:",omitempty"`
	ProviderBinding                   string          `json:",omitempty"`
	ACPBroker                         *acpBrokerLease `json:",omitempty"`
	FocusedProof                      bool            `json:",omitempty"`
	MCPOverACP                        bool            `json:",omitempty"`
	Companions                        []toolregistry.CompanionBinding
	DevflowUI                         string            `json:",omitempty"` // pending launch records from before the registry
	SSH                               *sshProfile       `json:",omitempty"`
	RegisteredACP                     *acpProfile       `json:",omitempty"`
	RegisteredEnv                     map[string]string `json:",omitempty"`
	Codex                             *managedCodex     `json:",omitempty"`
}

func New(stateDir, socketPath, executable string) (*Local, error) {
	return NewWithToolRegistry(stateDir, socketPath, executable, nil)
}

func NewWithToolRegistry(stateDir, socketPath, executable string, registry *toolregistry.Registry) (*Local, error) {
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
	profiles, err := loadACPProfiles(dir)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256([]byte(dir))
	return &Local{stateDir: dir, socket: socket, executable: binary, label: fmt.Sprintf("ac-%x", sum[:6]),
		acpProfiles: profiles, replaySlot: make(chan struct{}, 1), tools: registry}, nil
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

// TmuxExecutable uses the same owner-configured binary for launching and observing workers.
func TmuxExecutable() (string, error) {
	return executablePath("tmux", "AGENT_COMMANDER_TMUX")
}

func localRunner(client string) (command string, useACP bool, err error) {
	mode := os.Getenv("AGENT_COMMANDER_RUNTIME")
	if mode != "" && mode != "acp" && mode != "legacy" {
		return "", false, errors.New("AGENT_COMMANDER_RUNTIME must be acp or legacy when set")
	}
	legacy := mode == "legacy" || os.Getenv("AGENT_COMMANDER_FOCUSED_PROOF") == "1"
	switch strings.ToLower(strings.TrimSpace(client)) {
	case "", "claude", "claude code":
		if !legacy {
			command, err = localAdapter("claude-agent-acp", "AGENT_COMMANDER_CLAUDE_ACP")
			if err == nil || mode == "acp" || os.Getenv("AGENT_COMMANDER_CLAUDE_ACP") != "" || os.Getenv("AGENT_ACP_HARNESS_DIR") != "" {
				return command, true, err
			}
		}
		command, err = executablePath("claude", "AGENT_COMMANDER_CLAUDE")
		return command, false, err
	case "codex":
		if !legacy {
			command, err = localAdapter("codex-acp", "AGENT_COMMANDER_CODEX_ACP")
			return command, true, err
		}
	}
	return "", false, fmt.Errorf("managed provider unavailable: %s", client)
}

func localAdapter(name, override string) (string, error) {
	if dir := os.Getenv("AGENT_ACP_HARNESS_DIR"); dir != "" && os.Getenv(override) == "" {
		if !filepath.IsAbs(dir) {
			return "", errors.New("AGENT_ACP_HARNESS_DIR must be an absolute path")
		}
		return exec.LookPath(filepath.Join(dir, "node_modules", ".bin", name))
	}
	return executablePath(name, override)
}

func (l *Local) CheckClient(client string) error {
	if _, selected, err := selectedBuiltin(client); selected {
		return err
	}
	id, profile, registered, err := l.registeredACP(client)
	if err != nil {
		return err
	}
	if registered {
		if _, err := profile.executable(); err != nil {
			return fmt.Errorf("ACP profile %q executable is unavailable: %w", id, err)
		}
		return nil
	}
	_, useACP, err := localRunner(client)
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
	if w.CodingSource != nil && w.Reattach == nil {
		if err := l.CheckCodingClient(w.Client); err != nil {
			return err
		}
		git, err := worktrees.New()
		if err != nil {
			return err
		}
		assigned, err := git.Create(ctx, *w.CodingSource, w.ID)
		if err != nil {
			return err
		}
		if assigned.Path != w.Worktree {
			return errors.New("coding worktree changed after worker reservation")
		}
		w.Path = assigned.Path
	}
	launch, err := l.prepareLaunch(w)
	if err != nil {
		return err
	}
	if launch.localACP() {
		launch.ProviderBinding, err = providerBindingFingerprint(launch)
		if err != nil {
			return err
		}
	}
	if w.Reattach != nil {
		if err := verifyProviderBinding(launch, w.Reattach.Ref, w.Reattach.ProviderBinding); err != nil {
			return err
		}
		l.replayCache.invalidate(w.Reattach.Ref)
	}
	return l.startLaunch(ctx, launch)
}

func (l *Local) prepareLaunch(w service.LaunchSpec) (job, error) {
	focused := os.Getenv("AGENT_COMMANDER_FOCUSED_PROOF") == "1"
	var useACP bool
	var remote *sshProfile
	var registered *acpProfile
	var registeredID string
	var registeredEnv map[string]string
	var executable string
	var builtinInstance, builtinID string
	if w.Host != "" && w.Host != "localhost" {
		checkout, checkErr := l.WorkerCheckout(w.Host, w.Path, w.Client)
		if checkErr != nil {
			return job{}, checkErr
		}
		if checkout != w.Worktree {
			return job{}, errors.New("SSH checkout changed after worker reservation")
		}
		profile, profileErr := configuredSSHProfile()
		if profileErr != nil {
			return job{}, profileErr
		}
		remote = &profile
		useACP, focused = true, false
		executable = "/usr/bin/ssh"
	} else if adapter, selected, err := selectedBuiltin(w.Client); selected {
		if err != nil {
			return job{}, err
		}
		builtinInstance, builtinID = adapter.Instance(), adapter.ID
		useACP, focused = true, false
	} else {
		id, profile, ok, err := l.registeredACP(w.Client)
		if err != nil {
			return job{}, err
		}
		if ok {
			executable, err = profile.executable()
			if err != nil {
				return job{}, fmt.Errorf("ACP profile %q executable is unavailable: %w", id, err)
			}
			profile.Command = executable
			registered, registeredID, registeredEnv = &profile, id, profile.Env
			useACP, focused = true, false
		} else {
			executable, useACP, err = localRunner(w.Client)
			if err != nil {
				return job{}, err
			}
		}
	}
	var claude, adapter, harness, nodePath string
	var codex *managedCodex
	if useACP {
		adapter, harness = executable, "claude"
		if builtinInstance != "" {
			harness = builtinID
		} else if registered != nil {
			harness = registeredID
		} else if remote == nil && strings.EqualFold(strings.TrimSpace(w.Client), "codex") {
			managed, err := configuredManagedCodex()
			if err != nil {
				return job{}, err
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
	launch := job{
		Worker: w, Socket: l.socket, Executable: l.executable, Claude: claude, Label: l.label,
		FocusedProof: focused, Adapter: adapter, Harness: harness, NodePath: nodePath, SSH: remote,
		RegisteredACP: registered, RegisteredEnv: registeredEnv, Codex: codex,
		BuiltinInstance: builtinInstance,
		MCPOverACP:      os.Getenv("AGENT_COMMANDER_MCP_OVER_ACP") == "1",
	}
	return launch, nil
}

func (l *Local) startLaunch(ctx context.Context, launch job) error {
	w, remote := launch.Worker, launch.SSH
	tmux, err := TmuxExecutable()
	if err != nil {
		return err
	}
	dir := filepath.Join(l.stateDir, "jobs", w.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	jobPath := filepath.Join(dir, "launch.json")
	launch.Companions = l.tools.BindCompanions(ctx, launch.companionScope())
	launch.ACPBroker, err = l.acpBroker.register(launch)
	if err != nil {
		return fmt.Errorf("register ACP adapter launch: %w", err)
	}
	// The prompt and scoped credential stay in a private file, outside shell argv.
	contents, err := json.Marshal(launch)
	if err != nil {
		return err
	}
	if err := os.WriteFile(jobPath, contents, 0600); err != nil {
		return err
	}
	if remote != nil && remote.Persistent {
		profile, err := json.Marshal(remote)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "persistent-ssh.json"), profile, 0600); err != nil {
			return err
		}
	}
	if w.Reattach != nil {
		panes, err := exec.CommandContext(ctx, tmux, "-L", l.label, "list-panes", "-t", "="+w.ID, "-F", "#{pane_id} #{pane_dead}").Output()
		if err == nil {
			fields := strings.Fields(string(panes))
			if len(fields) != 2 || !strings.HasPrefix(fields[0], "%") || fields[1] != "1" {
				return errors.New("the original tmux worker still has an active pane")
			}
			// Without -k, tmux refuses to replace a pane that became active.
			out, err := exec.CommandContext(ctx, tmux, "-L", l.label, "respawn-pane", "-t", fields[0],
				"-c", w.Path, "--", l.executable, "runner", jobPath).CombinedOutput()
			if err != nil {
				return fmt.Errorf("reattach tmux worker: %w: %s", err, strings.TrimSpace(string(out)))
			}
			return nil
		}
		// Creating by the original worker ID still fails if an existing
		// session could not be inspected.
	}
	// tmux executes multi-argument commands directly. None of its arguments are prompt text.
	args := []string{"-L", l.label, "-f", "/dev/null", "new-session", "-d", "-s", w.ID, "-x", "120", "-y", "38", "-c", w.Path, "--", l.executable, "runner", jobPath, ";", "set-option", "-w", "-t", "=" + w.ID + ":", "remain-on-exit", "on"}
	out, err := exec.CommandContext(ctx, tmux, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("start tmux worker: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (l *Local) CheckCodingClient(client string) error {
	id, _, registered, err := l.registeredACP(client)
	if err != nil {
		return err
	}
	if registered {
		return fmt.Errorf("coding is unavailable in the registered ACP profile %q", id)
	}
	client = strings.ToLower(strings.TrimSpace(client))
	if client != "claude" && client != "claude code" {
		return errors.New("coding assignments currently require the managed Claude ACP profile")
	}
	_, useACP, err := localRunner(client)
	if err != nil {
		return err
	}
	if !useACP {
		return errors.New("coding assignments currently require the managed Claude ACP profile")
	}
	return nil
}

func (l *Local) Stop(ctx context.Context, id string) error {
	if !validID.MatchString(id) {
		return errors.New("invalid worker ID")
	}
	profilePath := filepath.Join(l.stateDir, "jobs", id, "persistent-ssh.json")
	if data, err := os.ReadFile(profilePath); err == nil {
		var profile sshProfile
		if err := json.Unmarshal(data, &profile); err != nil {
			return err
		}
		proxy := persistentProxy{Profile: profile, Worker: id}
		if err := proxy.stop(); err != nil {
			return fmt.Errorf("stop original persistent SSH worker: %w", err)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	tmux, err := TmuxExecutable()
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
