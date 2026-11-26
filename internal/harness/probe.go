package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Status is one harness as the cockpit reads it. See design/HARNESSES.md.
type Status struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Vendor     string    `json:"vendor"`
	Kind       string    `json:"kind"`
	Group      string    `json:"group"`
	Website    string    `json:"website,omitempty"`
	Managed    bool      `json:"managed"`
	Verified   bool      `json:"verified"`
	Installed  bool      `json:"installed"`
	Executable string    `json:"executable,omitempty"`
	Version    string    `json:"version,omitempty"`
	Auth       Auth      `json:"auth"`
	ACP        ACP       `json:"acp"`
	Install    Action    `json:"install"`
	Login      Action    `json:"login"`
	Settings   Settings  `json:"settings"`
	Models     []string  `json:"models,omitempty"`
	CheckedAt  time.Time `json:"checked_at"`
	// RunBlocker says why Commander cannot start a run with a managed harness
	// right now, in the launcher's own words. Empty means it can.
	RunBlocker string `json:"run_blocker,omitempty"`
	Changed    string `json:"changed,omitempty"`
}

type Auth struct {
	State     string     `json:"state"`
	Account   string     `json:"account,omitempty"`
	Plan      string     `json:"plan,omitempty"`
	Method    string     `json:"method,omitempty"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
	Source    string     `json:"source"`
	Detail    string     `json:"detail,omitempty"`
}

type ACP struct {
	Adapter   string `json:"adapter,omitempty"`
	Installed bool   `json:"installed"`
	Mode      string `json:"mode"`
}

type Action struct {
	Available bool   `json:"available"`
	Display   string `json:"display,omitempty"`
}

type Settings struct {
	Enabled      bool   `json:"enabled"`
	DefaultModel string `json:"default_model"`
}

const (
	SignedIn     = "signed_in"
	SignedOut    = "signed_out"
	Expired      = "expired"
	NotRequired  = "not_required"
	Unknown      = "unknown"
	NotInstalled = "not_installed"
)

// Env gives a probe the process environment and filesystem view. Tests replace it.
type Env struct {
	Home    string
	Getenv  func(string) string
	Now     func() time.Time
	Run     func(ctx context.Context, dir string, env []string, argv ...string) (stdout []byte, exitCode int, err error)
	Timeout time.Duration
	// SystemDirs are searched after PATH and the home folder's usual bin folders.
	SystemDirs []string
}

// DefaultEnv reads the real process environment.
func DefaultEnv() Env {
	home, _ := os.UserHomeDir()
	return Env{Home: home, Getenv: os.Getenv, Now: time.Now, Run: runCommand, Timeout: 10 * time.Second,
		SystemDirs: []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"}}
}

func runCommand(ctx context.Context, dir string, env []string, argv ...string) ([]byte, int, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir, cmd.Env, cmd.Stdin = dir, env, nil
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	cmd.WaitDelay = time.Second
	err := cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return out.Bytes(), exit.ExitCode(), nil
	}
	if err != nil {
		return out.Bytes(), -1, err
	}
	return out.Bytes(), 0, nil
}

// SearchDirs are the folders searched for harness binaries beyond PATH,
// because a Finder-launched process lacks a login shell's PATH.
func (e Env) SearchDirs() []string {
	dirs := filepath.SplitList(e.Getenv("PATH"))
	for _, d := range []string{".local/bin", ".npm-global/bin", ".bun/bin", ".cargo/bin", ".volta/bin", "go/bin"} {
		dirs = append(dirs, filepath.Join(e.Home, d))
	}
	return append(dirs, e.SystemDirs...)
}

func (e Env) pathValue() string {
	return strings.Join(unique(e.SearchDirs()), string(filepath.ListSeparator))
}

func (e Env) lookPath(name string) string {
	for _, dir := range e.SearchDirs() {
		if dir == "" || !filepath.IsAbs(dir) {
			continue
		}
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return candidate
		}
	}
	return ""
}

func (e Env) expand(path string) string {
	if path == "~" {
		return e.Home
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(e.Home, path[2:])
	}
	return path
}

// profileHome is the dedicated home Commander uses for this harness, or "".
// It applies the launcher's rules: a private directory, apart from the default home.
func (e Env) profileHome(entry Entry) string {
	if entry.Profile == nil {
		return ""
	}
	dir := e.Getenv(entry.Profile.Env)
	if !filepath.IsAbs(dir) {
		return ""
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return ""
	}
	if standard, err := os.Stat(filepath.Join(e.Home, "."+entry.ID)); err == nil && os.SameFile(standard, info) {
		return ""
	}
	return dir
}

// needsProfile reports a harness Commander can only use through a dedicated home that is not set up.
func (e Env) needsProfile(entry Entry) bool {
	return entry.Profile != nil && e.profileHome(entry) == ""
}

// CommandEnv is the environment a probe, login or install runs with.
func (e Env) CommandEnv(entry Entry) []string {
	env := []string{"PATH=" + e.pathValue(), "HOME=" + e.Home, "TERM=xterm-256color", "NO_COLOR=1"}
	for _, key := range []string{"USER", "LOGNAME", "SHELL", "LANG", "TMPDIR", "SSH_AUTH_SOCK"} {
		if v := e.Getenv(key); v != "" {
			env = append(env, key+"="+v)
		}
	}
	for _, key := range entry.CredentialEnv {
		if v := e.Getenv(key); v != "" {
			env = append(env, key+"="+v)
		}
	}
	if home := e.profileHome(entry); home != "" {
		env = append(env, entry.Profile.HomeEnv+"="+home)
	}
	return env
}

// WatchPaths are the files and folders whose change can alter this harness's state.
func (e Env) WatchPaths(entry Entry) []string {
	var paths []string
	if entry.Profile != nil {
		if home := e.profileHome(entry); home != "" {
			for _, p := range entry.Profile.Watch {
				paths = append(paths, filepath.Join(home, p))
			}
		}
	} else {
		for _, p := range entry.Watch {
			paths = append(paths, e.expand(p))
		}
	}
	for _, p := range entry.Credentials {
		paths = append(paths, e.expand(p))
	}
	paths = append(paths, entry.Apps...)
	return unique(paths)
}

var versionPattern = regexp.MustCompile(`\d+\.\d+(?:\.\d+)?(?:[-+.][0-9A-Za-z.-]+)?`)

// Check probes one harness. It runs at most its version and status commands.
func Check(ctx context.Context, env Env, entry Entry, settings Settings) Status {
	s := Status{ID: entry.ID, Name: entry.Name, Vendor: entry.Vendor, Kind: entry.Kind, Group: entry.Group,
		Website: entry.Website, Managed: entry.Managed, Verified: entry.Verified, Models: entry.Models,
		Settings: settings, CheckedAt: env.Now().UTC()}
	for _, name := range entry.Binaries {
		if path := env.lookPath(name); path != "" {
			s.Executable, s.Installed = path, true
			break
		}
	}
	if !s.Installed {
		for _, app := range entry.Apps {
			if _, err := os.Stat(app); err == nil {
				s.Installed = true
				break
			}
		}
	}
	s.Install = installAction(env, entry)
	if s.Executable != "" && entry.Login != nil && !env.needsProfile(entry) {
		s.Login = Action{Available: true, Display: strings.TrimSpace(filepath.Base(s.Executable) + " " + strings.Join(entry.Login, " "))}
	}
	s.ACP = acpState(env, entry)
	if s.Executable != "" && len(entry.VersionArgs) > 0 {
		out, code, err := env.run(ctx, entry, append([]string{s.Executable}, entry.VersionArgs...))
		if err == nil && code == 0 {
			s.Version = versionPattern.FindString(firstLine(out))
		}
	}
	s.Auth = authState(ctx, env, entry, s)
	return s
}

func (e Env) run(ctx context.Context, entry Entry, argv []string) ([]byte, int, error) {
	timeout := e.Timeout
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	dir := e.Home
	if home := e.profileHome(entry); home != "" {
		dir = home
	}
	out, code, err := e.Run(ctx, dir, e.CommandEnv(entry), argv...)
	if ctx.Err() != nil {
		return out, -1, errors.New("timed out")
	}
	return out, code, err
}

func installAction(env Env, entry Entry) Action {
	if entry.InstallScript != "" {
		return Action{Available: env.lookPath("bash") != "" || env.lookPath("sh") != "", Display: entry.InstallScript}
	}
	if len(entry.Install) == 0 {
		return Action{}
	}
	return Action{Available: env.lookPath(entry.Install[0]) != "", Display: strings.Join(entry.Install, " ")}
}

// acpOverride names the variable that points the service at an adapter, as in internal/provider.
var acpOverride = map[string]string{"claude-agent-acp": "AGENT_COMMANDER_CLAUDE_ACP", "codex-acp": "AGENT_COMMANDER_CODEX_ACP"}

func (e Env) adapterPath(name string) string {
	if path := e.Getenv(acpOverride[name]); filepath.IsAbs(path) {
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
		return ""
	}
	if dir := e.Getenv("AGENT_ACP_HARNESS_DIR"); filepath.IsAbs(dir) {
		path := filepath.Join(dir, "node_modules", ".bin", name)
		if _, err := os.Stat(path); err == nil {
			return path
		}
		return ""
	}
	return e.lookPath(name)
}

func acpState(env Env, entry Entry) ACP {
	a := ACP{Adapter: entry.ACPAdapter, Mode: "unsupported"}
	if entry.ACPAdapter == "" {
		return a
	}
	a.Installed = env.adapterPath(entry.ACPAdapter) != ""
	switch {
	case a.Installed:
		a.Mode = "acp"
	case entry.ID == "claude":
		// Claude Code still runs in a tmux terminal without its adapter.
		a.Mode = "legacy"
	default:
		a.Mode = "adapter_missing"
	}
	return a
}

func authState(ctx context.Context, env Env, entry Entry, s Status) Auth {
	if entry.Kind == "runner" {
		if !s.Installed {
			return Auth{State: NotInstalled, Source: "none"}
		}
		return Auth{State: NotRequired, Source: "none"}
	}
	if !s.Installed {
		return Auth{State: NotInstalled, Source: "none"}
	}
	if env.needsProfile(entry) {
		return Auth{State: Unknown, Source: "none", Detail: "Commander needs a dedicated, private profile. Set " + entry.Profile.Env + " to it."}
	}
	if entry.Status != nil && s.Executable != "" {
		return probeAuth(ctx, env, entry, s.Executable)
	}
	for _, path := range entry.Credentials {
		if info, err := os.Stat(env.expand(path)); err == nil && info.Size() > 0 {
			return Auth{State: SignedIn, Source: "credential_file", Detail: "Found " + path + "."}
		}
	}
	for _, key := range entry.CredentialEnv {
		if env.Getenv(key) != "" {
			return Auth{State: SignedIn, Source: "environment", Method: "api_key", Detail: key + " is set."}
		}
	}
	if len(entry.Credentials) > 0 {
		return Auth{State: SignedOut, Source: "credential_file", Detail: "No stored sign-in found."}
	}
	return Auth{State: Unknown, Source: "none", Detail: "This harness does not report its sign-in."}
}

func probeAuth(ctx context.Context, env Env, entry Entry, executable string) Auth {
	p := entry.Status
	out, code, err := env.run(ctx, entry, append([]string{executable}, p.Args...))
	if err != nil {
		return Auth{State: Unknown, Source: "status_command", Detail: "The status command failed: " + err.Error()}
	}
	a := Auth{Source: "status_command"}
	if env.profileHome(entry) != "" {
		a.Detail = "Commander's dedicated profile."
	}
	switch p.Parse {
	case "exit":
		a.State = SignedOut
		if code == 0 {
			a.State = SignedIn
			a.Method = firstLine(out)
		}
	case "text":
		a.State = SignedOut
		if code == 0 && (p.SignedOutMatch == "" || !bytes.Contains(out, []byte(p.SignedOutMatch))) {
			a.State = SignedIn
		}
	case "json":
		var fields map[string]any
		start := bytes.IndexByte(out, '{')
		if start < 0 || json.Unmarshal(out[start:], &fields) != nil {
			return Auth{State: Unknown, Source: "status_command", Detail: "The status command returned unreadable output."}
		}
		a.State = SignedOut
		if signed, _ := fields[p.SignedInField].(bool); signed {
			a.State = SignedIn
		}
		a.Account, a.Plan, a.Method = text(fields, p.AccountField), text(fields, p.PlanField), text(fields, p.MethodField)
		if raw := text(fields, p.ExpiresField); raw != "" {
			if t, err := time.Parse(time.RFC3339Nano, raw); err == nil {
				t = t.UTC()
				a.ExpiresAt = &t
				if a.State == SignedIn && !t.After(env.Now()) {
					a.State = Expired
				}
			}
		}
	}
	return a
}

func text(fields map[string]any, key string) string {
	if key == "" {
		return ""
	}
	v, _ := fields[key].(string)
	return v
}

func firstLine(out []byte) string {
	line, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	return strings.TrimSpace(line)
}

func unique(items []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, item := range items {
		if item != "" && !seen[item] {
			seen[item] = true
			out = append(out, item)
		}
	}
	return out
}
