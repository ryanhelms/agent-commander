package headless

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"agentcommander.network/hostkit/systemd"
)

// minNode is the oldest Node major version the Claude ACP adapter supports.
const minNode = 24

// Doctor checks what the headless service needs on this server. It uses the
// same PATH the unit will run with.
func (l Layout) Doctor(ctx context.Context) Report {
	var r Report
	path := ServicePath()
	look := func(name string) (string, error) { return lookPath(name, path) }
	r.add(check("systemd user instance", true, func() (string, error) {
		_, err := run(ctx, path, "systemctl", "--user", "show-environment")
		return "reachable", err
	}, "log in once with a full session, or enable linger: sudo loginctl enable-linger "+currentUser()))
	linger, err := systemd.Linger(currentUser())
	r.Linger = linger
	switch {
	case err != nil:
		r.add(Step{Step: "linger", Detail: err.Error()})
	case !linger:
		r.add(Step{Step: "linger", Detail: "the service stops when you log out", Fix: "sudo loginctl enable-linger " + currentUser()})
	default:
		r.add(Step{Step: "linger", OK: true, Detail: "the service keeps running after logout"})
	}
	r.add(check("git", true, func() (string, error) { return versionOf(ctx, path, look, "git", "--version") }, "install git"))
	r.add(check("tmux", true, func() (string, error) { return versionOf(ctx, path, look, "tmux", "-V") }, "install tmux"))
	r.add(check("node", true, func() (string, error) {
		out, err := versionOf(ctx, path, look, "node", "--version")
		if err != nil {
			return "", err
		}
		major, _ := strconv.Atoi(strings.SplitN(strings.TrimPrefix(out, "v"), ".", 2)[0])
		if major < minNode {
			return "", fmt.Errorf("node %s is older than %d", out, minNode)
		}
		return out, nil
	}, fmt.Sprintf("install Node %d or newer on the PATH the service uses: %s", minNode, path)))
	r.add(check("claude", true, func() (string, error) { return versionOf(ctx, path, look, "claude", "--version") },
		"install Claude Code: curl -fsSL https://claude.ai/install.sh | bash"))
	r.add(check("claude-agent-acp", true, func() (string, error) { return adapter(look) },
		"install the pinned Claude ACP adapter: npm install -g @agentclientprotocol/claude-agent-acp"))
	r.add(check("claude sign-in", true, claudeSignIn, "run `claude` once on this server and sign in"))
	r.add(check("codex", false, func() (string, error) { return versionOf(ctx, path, look, "codex", "--version") }, "optional: install Codex for Codex workers"))
	r.OK = true
	for _, s := range r.Steps {
		if s.Required && !s.OK {
			r.OK = false
		}
	}
	return r
}

func check(name string, required bool, probe func() (string, error), fix string) Step {
	detail, err := probe()
	if err != nil {
		return Step{Step: name, Required: required, Detail: err.Error(), Fix: fix}
	}
	return Step{Step: name, OK: true, Required: required, Detail: detail}
}

func lookPath(name, path string) (string, error) {
	for _, dir := range filepath.SplitList(path) {
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("%s is not on PATH", name)
}

func run(ctx context.Context, path, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "PATH="+path)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s: %w: %s", name, err, bytes.TrimSpace(out))
	}
	return strings.TrimSpace(string(out)), nil
}

func versionOf(ctx context.Context, path string, look func(string) (string, error), name string, args ...string) (string, error) {
	exe, err := look(name)
	if err != nil {
		return "", err
	}
	out, err := run(ctx, path, exe, args...)
	if err != nil {
		return "", err
	}
	return strings.SplitN(out, "\n", 2)[0], nil
}

// adapter finds the Claude ACP adapter the way the service does.
func adapter(look func(string) (string, error)) (string, error) {
	if p := os.Getenv("AGENT_COMMANDER_CLAUDE_ACP"); p != "" {
		if _, err := os.Stat(p); err != nil {
			return "", err
		}
		return p, nil
	}
	if dir := os.Getenv("AGENT_ACP_HARNESS_DIR"); dir != "" {
		p := filepath.Join(dir, "node_modules", ".bin", "claude-agent-acp")
		if _, err := os.Stat(p); err != nil {
			return "", err
		}
		return p, nil
	}
	return look("claude-agent-acp")
}

// claudeSignIn looks for Claude Code's stored credentials or an API key.
func claudeSignIn() (string, error) {
	for _, env := range []string{"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"} {
		if os.Getenv(env) != "" {
			return env + " is set", nil
		}
	}
	dir := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".claude")
	}
	if _, err := os.Stat(filepath.Join(dir, ".credentials.json")); err != nil {
		return "", fmt.Errorf("no Claude credentials in %s", dir)
	}
	return "credentials in " + dir, nil
}

// ensureLinger enables linger without privileges when systemd allows it.
// With sudo it uses passwordless sudo, which the deploy offers only after
// the user agrees.
func (l Layout) ensureLinger() Step {
	user := currentUser()
	if on, err := systemd.Linger(user); err == nil && on {
		return Step{Step: "linger", OK: true, Detail: "already enabled"}
	}
	if out, err := exec.Command("loginctl", "enable-linger", user).CombinedOutput(); err == nil {
		return Step{Step: "linger", OK: true, Detail: "enabled"}
	} else if l.SudoLinger {
		if out2, err2 := exec.Command("sudo", "-n", "loginctl", "enable-linger", user).CombinedOutput(); err2 == nil {
			return Step{Step: "linger", OK: true, Detail: "enabled with sudo"}
		} else {
			out = out2
		}
		return Step{Step: "linger", Detail: string(bytes.TrimSpace(out)), Fix: "sudo loginctl enable-linger " + user}
	}
	return Step{Step: "linger", Detail: "not enabled; the service stops when you log out", Fix: "sudo loginctl enable-linger " + user}
}
