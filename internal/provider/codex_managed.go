package provider

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
)

type managedCodex struct {
	Profile, Executable string
}

// Check the native sign-in without opening a thread or reading credentials.
// Delegation calls this on the admission path, so bound the subprocess wait.
func (m managedCodex) checkLogin() error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, m.Executable, "login", "status")
	cmd.Dir = m.Profile
	cmd.Env = append(cmd.Environ(), "CODEX_HOME="+m.Profile)
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return errors.New("the managed Codex sign-in check timed out")
		}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return errors.New("the managed Codex profile is signed out; sign in to that profile before delegating")
		}
		return fmt.Errorf("could not check managed Codex sign-in: %w", err)
	}
	return nil
}

func (m managedCodex) readHistory(cwd string) func(context.Context, *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error) {
	return func(ctx context.Context, req *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error) {
		binary, err := os.Executable()
		if err != nil {
			return nil, err
		}
		cmd := exec.CommandContext(ctx, binary, "runner-history")
		cmd.Env = append(cmd.Environ(), "CODEX_HOME="+m.Profile, "CODEX_PATH="+m.Executable)
		return readHistoryProcess(cmd, cwd, req.GetSession(), req)
	}
}

func configuredManagedCodex() (managedCodex, error) {
	profile := os.Getenv("AGENT_COMMANDER_CODEX_PROFILE")
	if !filepath.IsAbs(profile) {
		return managedCodex{}, errors.New("managed Codex requires AGENT_COMMANDER_CODEX_PROFILE to point to a dedicated signed-in profile")
	}
	profile, err := filepath.EvalSymlinks(profile)
	if err != nil {
		return managedCodex{}, errors.New("the managed Codex profile directory is unavailable")
	}
	info, err := os.Stat(profile)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return managedCodex{}, errors.New("managed Codex requires a private, dedicated profile directory")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return managedCodex{}, err
	}
	defaultProfile, err := filepath.EvalSymlinks(filepath.Join(home, ".codex"))
	if err == nil && profile == defaultProfile {
		return managedCodex{}, errors.New("the managed Codex profile must be separate from the default Codex profile")
	}
	binary, err := executablePath("codex", "AGENT_COMMANDER_CODEX")
	if err != nil {
		return managedCodex{}, err
	}
	return managedCodex{profile, binary}, nil
}

func (m managedCodex) instance() string {
	id := sha256.Sum256([]byte(m.Profile))
	return fmt.Sprintf("local-managed-codex-%x", id[:12])
}

func (m managedCodex) config(j job) (runtime.Config, error) {
	checkout, err := filepath.EvalSymlinks(j.Worker.Path)
	if err != nil {
		return runtime.Config{}, err
	}
	servers, instructions, allowed := agentPolicy(j)
	var toolNames []string
	for _, tool := range strings.Split(allowed, ",") {
		if name, ok := strings.CutPrefix(tool, "mcp__commander__"); ok {
			toolNames = append(toolNames, name)
		}
	}
	bridge := codexBridgeConfig{
		Executable: m.Executable, Profile: m.Profile,
		Policy: codexPolicy{Checkout: checkout, Server: servers["commander"], Tools: toolNames, Instructions: instructions},
	}
	if err := bridge.validate(); err != nil {
		return runtime.Config{}, err
	}
	config := runtime.Config{
		HarnessInstance: m.instance(), WorkingDirectory: j.Worker.Path, Command: "/usr/bin/env",
		Args:                []string{"-u", "CODEX_CONFIG", "-u", "DEFAULT_AUTH_REQUEST", "-u", "MODEL_PROVIDER", j.Adapter},
		OncePermissionsOnly: true,
		Env: map[string]string{
			codexBridgeEnv: string(rpcValue(bridge)), "CODEX_PATH": j.Executable, "CODEX_HOME": m.Profile,
			"NO_BROWSER": "1",
		},
	}
	return config, nil
}
