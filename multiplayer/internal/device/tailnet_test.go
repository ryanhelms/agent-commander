package device

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
)

// fakeTailscale is a shell script that stands in for the tailscale CLI.
//
//	status.json    printed by `status --json`; status.exit makes it exit 1
//	after-login.json  copied over status.json by `login`
//	args           one line of arguments per call
//	keyfile        `login --auth-key file:P` copies P here and records whether P existed
const fakeTailscale = `#!/bin/sh
D="$(dirname "$0")"
echo "$@" >> "$D/args"
case "$1" in
status)
  cat "$D/status.json"
  [ -f "$D/status.exit" ] && exit 1
  exit 0 ;;
login)
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--auth-key" ]; then
      p="${a#file:}"
      cat "$p" > "$D/keyfile"
      echo "$p" > "$D/keypath"
    fi
    prev="$a"
  done
  [ -f "$D/login.fail" ] && { echo "backend error: invalid key" >&2; exit 1; }
  [ -f "$D/after-login.json" ] && cp "$D/after-login.json" "$D/status.json"
  [ -f "$D/login.block" ] && sleep 1
  exit 0 ;;
esac
echo "unknown command $1" >&2
exit 2
`

const (
	runningStatus = `{
  "BackendState": "Running",
  "AuthURL": "",
  "MagicDNSSuffix": "tail.internal",
  "CurrentTailnet": {"Name": "adag", "MagicDNSSuffix": "tail.internal"},
  "Self": {"HostName": "ryan-mac", "DNSName": "ryan-mac.tail.internal.", "OS": "macOS",
    "TailscaleIPs": ["100.64.0.5", "fd7a:115c:a1e0::5"], "Online": true},
  "Peer": {
    "nodekey:b": {"HostName": "zeta-relay", "DNSName": "zeta-relay.tail.internal.", "OS": "linux",
      "TailscaleIPs": ["100.64.0.9"], "Online": false, "Tags": ["tag:relay"]},
    "nodekey:a": {"HostName": "agent-relay", "DNSName": "agent-relay.tail.internal.", "OS": "linux",
      "TailscaleIPs": ["100.64.0.7"], "Online": true, "Tags": ["tag:server", "tag:relay"]},
    "nodekey:c": {"HostName": "laptop", "DNSName": "laptop.tail.internal.", "OS": "macOS",
      "TailscaleIPs": ["100.64.0.8"], "Online": true},
    "nodekey:d": {"HostName": "build", "DNSName": "build.tail.internal.", "OS": "linux",
      "TailscaleIPs": ["100.64.0.10"], "Online": true, "Tags": ["tag:ci"]}
  }
}`
	needsLoginStatus = `{"BackendState": "NeedsLogin", "AuthURL": "", "Self": {"HostName": "ryan-mac", "DNSName": "", "Online": false}, "CurrentTailnet": null, "Peer": null}`
	authURLStatus    = `{"BackendState": "NeedsLogin", "AuthURL": "https://hs.example.test/register/abc123", "CurrentTailnet": null}`
)

type fakeCLI struct{ dir, path string }

func newFakeCLI(t *testing.T, status string) fakeCLI {
	t.Helper()
	dir := t.TempDir()
	f := fakeCLI{dir: dir, path: filepath.Join(dir, "tailscale")}
	if err := os.WriteFile(f.path, []byte(fakeTailscale), 0755); err != nil {
		t.Fatal(err)
	}
	f.write(t, "status.json", status)
	return f
}

func (f fakeCLI) write(t *testing.T, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.dir, name), []byte(body), 0644); err != nil {
		t.Fatal(err)
	}
}

func (f fakeCLI) read(name string) string {
	b, _ := os.ReadFile(filepath.Join(f.dir, name))
	return string(b)
}

type browserLog struct {
	mu   sync.Mutex
	urls []string
}

func (b *browserLog) open(u string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.urls = append(b.urls, u)
	return nil
}

func tailnetManager(t *testing.T, cli string, browser *browserLog) *Manager {
	t.Helper()
	dir := t.TempDir()
	open := func(string) error { return nil }
	if browser != nil {
		open = browser.open
	}
	m, err := NewManager(context.Background(), ManagerConfig{
		Dir: filepath.Join(dir, "state"), CommanderSocket: filepath.Join(dir, "commander.sock"),
		Secrets: func(relay string) (devicekeys.Store, error) {
			return devicekeys.Directory(filepath.Join(dir, "secrets", key(relay)))
		},
		OpenBrowser: open, NoPresence: true, Tailscale: cli,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(m.Close)
	return m
}

func TestTailnetStatusRunning(t *testing.T) {
	f := newFakeCLI(t, runningStatus)
	data, e := call(t, tailnetManager(t, f.path, nil).Handler(), "tailnet-status", map[string]any{})
	if e != "" {
		t.Fatal(e)
	}
	var st TailnetStatus
	json.Unmarshal(data, &st)
	if !st.Installed || !st.Running || st.BackendState != "Running" || st.Tailnet != "adag" || st.MagicDNSSuffix != "tail.internal" {
		t.Fatalf("status: %+v", st)
	}
	if st.Self == nil || st.Self.HostName != "ryan-mac" || st.Self.DNSName != "ryan-mac.tail.internal" || len(st.Self.Addresses) != 2 || !st.Self.Online {
		t.Fatalf("self: %+v", st.Self)
	}
	if strings.TrimSpace(f.read("args")) != "status --json" {
		t.Fatalf("args: %q", f.read("args"))
	}
}

func TestTailnetStatusNeedsLoginWithNonZeroExit(t *testing.T) {
	f := newFakeCLI(t, needsLoginStatus)
	f.write(t, "status.exit", "")
	data, e := call(t, tailnetManager(t, f.path, nil).Handler(), "tailnet-status", map[string]any{})
	if e != "" {
		t.Fatal(e)
	}
	var st TailnetStatus
	json.Unmarshal(data, &st)
	if !st.Installed || st.Running || st.BackendState != "NeedsLogin" || st.Tailnet != "" {
		t.Fatalf("status: %+v", st)
	}
}

func TestTailnetStatusMissingCLI(t *testing.T) {
	h := tailnetManager(t, filepath.Join(t.TempDir(), "no-tailscale"), nil).Handler()
	data, e := call(t, h, "tailnet-status", map[string]any{})
	if e != "" {
		t.Fatal(e)
	}
	var st TailnetStatus
	json.Unmarshal(data, &st)
	if st.Installed || st.Running {
		t.Fatalf("missing CLI should report installed:false: %+v", st)
	}
	if _, e = call(t, h, "tailnet-relays", map[string]any{}); e == "" {
		t.Fatal("relays without a CLI should fail")
	}
	if _, e = call(t, h, "tailnet-status", map[string]any{"bogus": 1}); e != "invalid request" {
		t.Fatalf("unknown field accepted: %q", e)
	}
}

func TestTailnetRelays(t *testing.T) {
	f := newFakeCLI(t, runningStatus)
	m := tailnetManager(t, f.path, nil)
	h := m.Handler()
	if _, e := call(t, h, "server-add", map[string]any{"url": "agent-relay.tail.internal"}); e != "" {
		t.Fatal(e)
	}
	data, e := call(t, h, "tailnet-relays", map[string]any{})
	if e != "" {
		t.Fatal(e)
	}
	var out struct{ Relays []TailnetRelay }
	json.Unmarshal(data, &out)
	if len(out.Relays) != 2 {
		t.Fatalf("want two tagged relays: %+v", out.Relays)
	}
	a, z := out.Relays[0], out.Relays[1]
	if a.Name != "agent-relay" || a.URL != "https://agent-relay.tail.internal" || a.DNSName != "agent-relay.tail.internal" || !a.Added || !a.Online || a.OS != "linux" || a.Addresses[0] != "100.64.0.7" {
		t.Fatalf("first relay: %+v", a)
	}
	if z.Name != "zeta-relay" || z.Added || z.Online {
		t.Fatalf("second relay: %+v", z)
	}

	data, e = call(t, h, "tailnet-relays", map[string]any{"tag": "tag:ci"})
	json.Unmarshal(data, &out)
	if e != "" || len(out.Relays) != 1 || out.Relays[0].Name != "build" {
		t.Fatalf("custom tag: %+v %s", out.Relays, e)
	}
	if _, e = call(t, h, "tailnet-relays", map[string]any{"tag": "relay"}); e == "" {
		t.Fatal("tag without tag: prefix accepted")
	}

	f.write(t, "status.json", needsLoginStatus)
	if _, e = call(t, h, "tailnet-relays", map[string]any{}); !strings.Contains(e, "not on a tailnet") {
		t.Fatalf("relays while logged out: %q", e)
	}
}

func TestTailnetJoinValidation(t *testing.T) {
	f := newFakeCLI(t, needsLoginStatus)
	h := tailnetManager(t, f.path, nil).Handler()
	for _, bad := range []map[string]any{
		{"loginServer": "http://hs.example.test"},
		{"loginServer": "hs.example.test"},
		{"loginServer": "https://"},
		{"loginServer": "https://user@hs.example.test"},
		{"loginServer": "https://hs.example.test?x=1"},
		{"loginServer": "https://hs.example.test#frag"},
		{"loginServer": "ftp://hs.example.test"},
		{"loginServer": "https://hs.example.test", "hostname": "bad host"},
		{"loginServer": "https://hs.example.test", "hostname": "a.b"},
		{"loginServer": "https://hs.example.test", "hostname": "-lead"},
	} {
		if _, e := call(t, h, "tailnet-join", bad); e == "" {
			t.Errorf("tailnet-join accepted %v", bad)
		}
	}
	if f.read("args") != "" {
		t.Fatalf("invalid input reached the CLI: %q", f.read("args"))
	}
	if _, e := validLoginServer("http://127.0.0.1:8080"); e != nil {
		t.Fatalf("loopback http rejected: %v", e)
	}

	f.write(t, "status.json", runningStatus)
	_, e := call(t, h, "tailnet-join", map[string]any{"loginServer": "https://hs.example.test", "authKey": "tskey-secret"})
	if !strings.Contains(e, "already on tailnet adag") {
		t.Fatalf("join while running: %q", e)
	}
	if strings.Contains(f.read("args"), "login") {
		t.Fatalf("login ran while already on a tailnet: %q", f.read("args"))
	}
}

func TestTailnetJoinWithAuthKey(t *testing.T) {
	const secret = "tskey-auth-k1234-SECRETVALUE"
	f := newFakeCLI(t, needsLoginStatus)
	f.write(t, "after-login.json", runningStatus)
	m := tailnetManager(t, f.path, nil)
	data, e := call(t, m.Handler(), "tailnet-join", map[string]any{
		"loginServer": "https://hs.example.test", "authKey": secret, "hostname": "ryan-mac",
	})
	if e != "" {
		t.Fatal(e)
	}
	var st TailnetStatus
	json.Unmarshal(data, &st)
	if !st.Running || st.Tailnet != "adag" {
		t.Fatalf("status after join: %+v", st)
	}
	args := f.read("args")
	if strings.Contains(args, secret) {
		t.Fatalf("auth key passed in argv: %q", args)
	}
	if !strings.Contains(args, "login --login-server https://hs.example.test --hostname ryan-mac --auth-key file:") {
		t.Fatalf("login args: %q", args)
	}
	if f.read("keyfile") != secret {
		t.Fatalf("CLI read %q from the key file", f.read("keyfile"))
	}
	path := strings.TrimSpace(f.read("keypath"))
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("key file %s left behind: %v", path, err)
	}
	if m.tailnet.pending {
		t.Fatal("login still marked pending")
	}
}

func TestTailnetJoinAuthKeyFailureRemovesKey(t *testing.T) {
	f := newFakeCLI(t, needsLoginStatus)
	f.write(t, "login.fail", "")
	m := tailnetManager(t, f.path, nil)
	_, e := call(t, m.Handler(), "tailnet-join", map[string]any{"loginServer": "https://hs.example.test", "authKey": "tskey-bad"})
	if !strings.Contains(e, "invalid key") || strings.Contains(e, "tskey-bad") {
		t.Fatalf("join error: %q", e)
	}
	if _, err := os.Stat(strings.TrimSpace(f.read("keypath"))); !os.IsNotExist(err) {
		t.Fatalf("key file left behind after failure: %v", err)
	}
}

func TestTailnetJoinWithBrowser(t *testing.T) {
	f := newFakeCLI(t, needsLoginStatus)
	f.write(t, "after-login.json", authURLStatus)
	f.write(t, "login.block", "")
	browser := &browserLog{}
	m := tailnetManager(t, f.path, browser)
	h := m.Handler()
	data, e := call(t, h, "tailnet-join", map[string]any{"loginServer": "https://hs.example.test"})
	if e != "" {
		t.Fatal(e)
	}
	var out struct{ State, AuthURL string }
	json.Unmarshal(data, &out)
	if out.State != "needsLogin" || out.AuthURL != "https://hs.example.test/register/abc123" {
		t.Fatalf("join: %s", data)
	}
	browser.mu.Lock()
	opened := append([]string(nil), browser.urls...)
	browser.mu.Unlock()
	if len(opened) != 1 || opened[0] != out.AuthURL {
		t.Fatalf("browser opened %v", opened)
	}
	if !strings.Contains(f.read("args"), "login --login-server https://hs.example.test\n") {
		t.Fatalf("login args: %q", f.read("args"))
	}

	// The login is still running: a second join is refused and status shows it.
	if _, e = call(t, h, "tailnet-join", map[string]any{"loginServer": "https://hs.example.test"}); !strings.Contains(e, "already in progress") {
		t.Fatalf("second join: %q", e)
	}
	data, _ = call(t, h, "tailnet-status", map[string]any{})
	var st TailnetStatus
	json.Unmarshal(data, &st)
	if !st.LoginPending || st.AuthURL != out.AuthURL {
		t.Fatalf("status during login: %+v", st)
	}

	// Once the CLI exits the login is no longer pending.
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); testSleep() {
		m.tailnet.mu.Lock()
		pending := m.tailnet.pending
		m.tailnet.mu.Unlock()
		if !pending {
			return
		}
	}
	t.Fatal("login stayed pending after the CLI exited")
}
