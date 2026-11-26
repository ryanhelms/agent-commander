package harness

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestEmbeddedCatalogIsValid(t *testing.T) {
	entries, err := Catalog()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"claude", "codex", "gemini", "opencode", "goose", "aider", "cline", "crush", "qwen",
		"copilot", "cursor", "amp", "auggie", "kiro", "droid", "warp", "ollama", "lmstudio"}
	var got []string
	for _, e := range entries {
		got = append(got, e.ID)
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("catalog order = %v", got)
	}
}

type fixture struct {
	home, bin string
	env       Env
	vars      map[string]string
	now       time.Time
	outputs   map[string]string
	codes     map[string]int
	calls     []string
	mu        sync.Mutex
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	f := &fixture{home: filepath.Join(root, "home"), bin: filepath.Join(root, "bin"), vars: map[string]string{},
		now: time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC), outputs: map[string]string{}, codes: map[string]int{}}
	for _, dir := range []string{f.home, f.bin} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	f.vars["PATH"] = f.bin
	f.env = Env{Home: f.home, Getenv: func(k string) string { return f.vars[k] }, Now: func() time.Time {
		f.mu.Lock()
		defer f.mu.Unlock()
		return f.now
	},
		Run: func(_ context.Context, _ string, env []string, argv ...string) ([]byte, int, error) {
			key := filepath.Base(argv[0]) + " " + strings.Join(argv[1:], " ")
			f.mu.Lock()
			defer f.mu.Unlock()
			f.calls = append(f.calls, key)
			return []byte(f.outputs[key]), f.codes[key], nil
		}}
	return f
}

func (f *fixture) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func (f *fixture) advance(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.now = f.now.Add(d)
}

func (f *fixture) install(t *testing.T, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.bin, name), []byte("#!/bin/sh\n"), 0700); err != nil {
		t.Fatal(err)
	}
}

func entry(t *testing.T, id string) Entry {
	t.Helper()
	entries, _ := Catalog()
	for _, e := range entries {
		if e.ID == id {
			return e
		}
	}
	t.Fatalf("no entry %s", id)
	return Entry{}
}

func TestClaudeJSONStatusReportsAccountPlanAndExpiry(t *testing.T) {
	f := newFixture(t)
	f.install(t, "claude")
	f.outputs["claude --version"] = "2.1.332 (Claude Code)\n"
	f.outputs["claude auth status --json"] = `{"loggedIn":true,"authMethod":"claude.ai","email":"dev@example.com","subscriptionType":"max","loginExpiresAt":"2026-12-23T09:55:41.055Z"}`
	s := Check(context.Background(), f.env, entry(t, "claude"), Settings{Enabled: true})
	if !s.Installed || s.Version != "2.1.332" || s.Auth.State != SignedIn || s.Auth.Account != "dev@example.com" ||
		s.Auth.Plan != "max" || s.Auth.ExpiresAt == nil || s.ACP.Mode != "legacy" || !s.Login.Available {
		t.Fatalf("status = %+v", s)
	}
	f.now = time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC)
	if s := Check(context.Background(), f.env, entry(t, "claude"), Settings{}); s.Auth.State != Expired {
		t.Fatalf("after expiry state = %s", s.Auth.State)
	}
	f.install(t, "claude-agent-acp")
	if s := Check(context.Background(), f.env, entry(t, "claude"), Settings{}); s.ACP.Mode != "acp" {
		t.Fatalf("acp mode = %s", s.ACP.Mode)
	}
}

func TestExitAndTextProbes(t *testing.T) {
	f := newFixture(t)
	f.install(t, "codex")
	f.install(t, "opencode")
	f.vars["AGENT_COMMANDER_CODEX_PROFILE"] = filepath.Join(f.home, "profile")
	os.Mkdir(f.vars["AGENT_COMMANDER_CODEX_PROFILE"], 0700)
	f.outputs["codex login status"] = "Logged in using ChatGPT"
	if s := Check(context.Background(), f.env, entry(t, "codex"), Settings{}); s.Auth.State != SignedIn || s.Auth.Method != "Logged in using ChatGPT" {
		t.Fatalf("codex = %+v", s.Auth)
	}
	f.codes["codex login status"] = 1
	if s := Check(context.Background(), f.env, entry(t, "codex"), Settings{}); s.Auth.State != SignedOut {
		t.Fatalf("codex signed out = %+v", s.Auth)
	}
	f.outputs["opencode auth list"] = "No authenticated integrations"
	if s := Check(context.Background(), f.env, entry(t, "opencode"), Settings{}); s.Auth.State != SignedOut {
		t.Fatalf("opencode = %+v", s.Auth)
	}
}

func TestCodexUsesCommanderProfile(t *testing.T) {
	f := newFixture(t)
	f.install(t, "codex")
	if s := Check(context.Background(), f.env, entry(t, "codex"), Settings{}); s.Auth.State != Unknown || s.Login.Available {
		t.Fatalf("without a profile: %+v", s)
	}
	profile := filepath.Join(f.home, "profile")
	if err := os.Mkdir(profile, 0700); err != nil {
		t.Fatal(err)
	}
	f.vars["AGENT_COMMANDER_CODEX_PROFILE"] = profile
	var gotEnv []string
	f.env.Run = func(_ context.Context, _ string, env []string, argv ...string) ([]byte, int, error) {
		gotEnv = env
		return nil, 0, nil
	}
	s := Check(context.Background(), f.env, entry(t, "codex"), Settings{})
	if !strings.Contains(strings.Join(gotEnv, "\n"), "CODEX_HOME="+profile) || s.Auth.Detail == "" {
		t.Fatalf("env = %v, auth = %+v", gotEnv, s.Auth)
	}
	if paths := f.env.WatchPaths(entry(t, "codex")); paths[0] != filepath.Join(profile, "auth.json") {
		t.Fatalf("watch = %v", paths)
	}
}

func TestCredentialFileAndRunnerStates(t *testing.T) {
	f := newFixture(t)
	f.install(t, "qwen")
	f.install(t, "ollama")
	if s := Check(context.Background(), f.env, entry(t, "qwen"), Settings{}); s.Auth.State != SignedOut || s.Auth.Source != "credential_file" {
		t.Fatalf("qwen = %+v", s.Auth)
	}
	os.MkdirAll(filepath.Join(f.home, ".qwen"), 0700)
	os.WriteFile(filepath.Join(f.home, ".qwen", "oauth_creds.json"), []byte("{}"), 0600)
	if s := Check(context.Background(), f.env, entry(t, "qwen"), Settings{}); s.Auth.State != SignedIn {
		t.Fatalf("qwen signed in = %+v", s.Auth)
	}
	if s := Check(context.Background(), f.env, entry(t, "ollama"), Settings{}); s.Auth.State != NotRequired {
		t.Fatalf("ollama = %+v", s.Auth)
	}
	if s := Check(context.Background(), f.env, entry(t, "gemini"), Settings{}); s.Installed || s.Auth.State != NotInstalled {
		t.Fatalf("gemini = %+v", s)
	}
}

func TestMonitorPublishesCredentialChangeWithoutPolling(t *testing.T) {
	f := newFixture(t)
	f.install(t, "qwen")
	entries := []Entry{entry(t, "qwen"), entry(t, "codex")}
	m, err := newMonitor(t.TempDir(), f.env, entries)
	if err != nil {
		t.Fatal(err)
	}
	m.interval = 20 * time.Millisecond
	defer m.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	first, frames, done, err := m.Subscribe(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer done()
	if first[0].Auth.State != SignedOut {
		t.Fatalf("first = %+v", first[0].Auth)
	}
	callsBefore := f.callCount()
	time.Sleep(100 * time.Millisecond)
	if f.callCount() != callsBefore {
		t.Fatal("monitor ran commands without a change")
	}
	f.advance(time.Minute) // past the recheck spacing
	os.MkdirAll(filepath.Join(f.home, ".qwen"), 0700)
	os.WriteFile(filepath.Join(f.home, ".qwen", "oauth_creds.json"), []byte("{}"), 0600)
	select {
	case frame := <-frames:
		if frame[0].ID != "qwen" || frame[0].Auth.State != SignedIn || frame[0].Changed != "auth" || frame[1].Changed != "" {
			t.Fatalf("frame = %+v", frame)
		}
	case <-ctx.Done():
		t.Fatal("no frame after the credential file appeared")
	}
}

func TestSettingsPersistAndValidateModel(t *testing.T) {
	f := newFixture(t)
	dir := t.TempDir()
	m, _ := newMonitor(dir, f.env, []Entry{entry(t, "claude")})
	defer m.Close()
	if _, err := m.UpdateSettings(context.Background(), "claude", Settings{Enabled: true, DefaultModel: "gpt-4"}); err == nil {
		t.Fatal("accepted a model Claude Code does not offer")
	}
	s, err := m.UpdateSettings(context.Background(), "claude", Settings{Enabled: false, DefaultModel: "sonnet"})
	if err != nil || s.Settings.Enabled || s.Settings.DefaultModel != "sonnet" {
		t.Fatalf("settings = %+v, %v", s.Settings, err)
	}
	again, _ := newMonitor(dir, f.env, []Entry{entry(t, "claude")})
	defer again.Close()
	if got := again.settingsFor("claude"); got.Enabled || got.DefaultModel != "sonnet" {
		t.Fatalf("reloaded = %+v", got)
	}
}

// HARNESS_LIVE=1 go test -run TestLive -v ./internal/harness prints this Mac's real harness states.
func TestLive(t *testing.T) {
	if os.Getenv("HARNESS_LIVE") != "1" {
		t.Skip("set HARNESS_LIVE=1 to probe this machine")
	}
	entries, _ := Catalog()
	for _, e := range entries {
		start := time.Now()
		s := Check(context.Background(), DefaultEnv(), e, Settings{Enabled: true})
		t.Logf("%-10s installed=%-5v v=%-10s auth=%-13s src=%-15s acp=%-11s login=%q (%s)", s.ID, s.Installed, s.Version,
			s.Auth.State, s.Auth.Source, s.ACP.Mode, s.Login.Display, time.Since(start).Round(time.Millisecond))
	}
}

func TestLoginSessionRunsInTmuxAndReportsItsEnd(t *testing.T) {
	env := DefaultEnv()
	ended := make(chan string, 1)
	s := newSessions(t.TempDir(), env, func(id string) { ended <- id })
	tmux, err := s.tmux()
	if err != nil {
		t.Skip("tmux is not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	a, err := s.open(ctx, Entry{ID: "fixture", Name: "Fixture"}, "login", []string{"/bin/echo", "signed in"})
	if err != nil {
		t.Fatal(err)
	}
	defer exec.Command(tmux, "-L", s.label, "kill-server").Run()
	if a.HarnessID != "fixture" || a.Purpose != "login" || !filepath.IsAbs(a.SocketPath) || !tmuxSessionID.MatchString(a.SessionID) {
		t.Fatalf("attachment = %+v", a)
	}
	again, err := s.open(ctx, Entry{ID: "fixture", Name: "Fixture"}, "login", []string{"/bin/echo"})
	if err != nil || again != a {
		t.Fatalf("second open = %+v, %v; want the running session", again, err)
	}
	time.Sleep(300 * time.Millisecond)
	if err := exec.Command(tmux, "-L", s.label, "send-keys", "-t", "=login-fixture:", "Enter").Run(); err != nil {
		t.Fatal(err)
	}
	select {
	case id := <-ended:
		if id != "fixture" {
			t.Fatalf("ended %s", id)
		}
	case <-ctx.Done():
		t.Fatal("the session end was not reported")
	}
}

func TestMonitorReportsRunBlockerAndKeepsSettings(t *testing.T) {
	f := newFixture(t)
	f.install(t, "claude")
	m, _ := newMonitor(t.TempDir(), f.env, []Entry{entry(t, "claude")})
	defer m.Close()
	m.SetRunCheck(func(string) error { return errors.New("adapter not found") })
	list, err := m.List(context.Background())
	if err != nil || list[0].RunBlocker != "adapter not found" {
		t.Fatalf("list = %+v, %v", list, err)
	}
	stale := list[0]
	if _, err := m.UpdateSettings(context.Background(), "claude", Settings{Enabled: false}); err != nil {
		t.Fatal(err)
	}
	m.publish(stale)
	if got, _ := m.List(context.Background()); got[0].Settings.Enabled {
		t.Fatal("an older probe turned the harness back on")
	}
}

func TestLoginSessionIsAdoptedAfterAServiceRestart(t *testing.T) {
	env := DefaultEnv()
	state := t.TempDir()
	first := newSessions(state, env, func(string) {})
	tmux, err := first.tmux()
	if err != nil {
		t.Skip("tmux is not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	defer exec.Command(tmux, "-L", first.label, "kill-server").Run()
	e := Entry{ID: "fixture", Name: "Fixture"}
	a, err := first.open(ctx, e, "login", []string{"/bin/echo"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := newSessions(state, env, func(string) {}).open(ctx, e, "login", []string{"/bin/echo"})
	if err != nil || b != a {
		t.Fatalf("after restart = %+v, %v; want %+v", b, err, a)
	}
}
