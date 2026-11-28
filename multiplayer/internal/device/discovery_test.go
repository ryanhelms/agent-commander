package device

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
)

// fakeDiscoveryDNSSD stands in for dns-sd: -B prints browse.txt and -L prints
// lookup.txt, then each waits to be killed. No browse.txt means no services.
const fakeDiscoveryDNSSD = `#!/bin/sh
D="$(dirname "$0")"
case "$1" in
-B) [ -f "$D/browse.txt" ] && cat "$D/browse.txt"; exec sleep 30 ;;
-L) cat "$D/lookup.txt"; exec sleep 30 ;;
esac
exit 2
`

type discoveryFixture struct {
	relay *httptest.Server
	pin   string
	ts    fakeCLI
	dir   string // dns-sd fixture directory
	m     *Manager
	h     http.Handler
}

func newDiscoveryFixture(t *testing.T, status string) *discoveryFixture {
	t.Helper()
	f := &discoveryFixture{}
	f.relay = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/info" {
			json.NewEncoder(w).Encode(map[string]any{
				"version": "1", "mode": "host", "name": "Agent Relay", "membership": "invite",
				"adminContact": "admin@example.test", "issuer": "https://issuer.example.test", "clientId": "client",
			})
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(f.relay.Close)
	f.pin = SPKIPin(f.relay.Certificate())
	f.ts = newFakeCLI(t, status)
	f.dir = t.TempDir()
	if err := os.WriteFile(filepath.Join(f.dir, "dns-sd"), []byte(fakeDiscoveryDNSSD), 0755); err != nil {
		t.Fatal(err)
	}
	// macOS scans a new executable on its first run; keep that out of the browse window.
	_ = exec.Command(filepath.Join(f.dir, "dns-sd"), "-warm").Run()
	_ = exec.Command(f.ts.path, "version").Run()
	relayAddr := f.relay.Listener.Addr().String()
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		switch address {
		case "100.64.0.7:443", "relay-host.local:8443":
			return (&net.Dialer{}).DialContext(ctx, network, relayAddr)
		}
		return nil, errors.New("connection refused")
	}
	dir := t.TempDir()
	m, err := NewManager(context.Background(), ManagerConfig{
		Dir: filepath.Join(dir, "state"), CommanderSocket: filepath.Join(dir, "commander.sock"),
		Secrets: func(relay string) (devicekeys.Store, error) {
			return devicekeys.Directory(filepath.Join(dir, "secrets", key(relay)))
		},
		OpenBrowser: func(string) error { return nil }, NoPresence: true, Tailscale: f.ts.path,
		DNSSD: filepath.Join(f.dir, "dns-sd"), BonjourWindow: time.Second, Dial: dial,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		m.Close()
		// Live shutdown does not wait for Keychain. This fixture owns only
		// disposable stores, so let canceled activations finish using them
		// before TempDir removes the state and credential directories.
		m.mu.Lock()
		settled := make([]<-chan struct{}, 0, len(m.activations))
		for _, attempt := range m.activations {
			settled = append(settled, attempt.done)
		}
		m.mu.Unlock()

		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for _, done := range settled {
			select {
			case <-done:
			case <-deadline.C:
				t.Error("fixture relay activation did not settle during cleanup")
				return
			}
		}
	})
	f.m, f.h = m, m.Handler()
	return f
}

// advertise makes the fake dns-sd list the relay at relay-host.local:8443.
func (f *discoveryFixture) advertise(t *testing.T, pin string) {
	t.Helper()
	browse := "Timestamp     A/R    Flags  if Domain               Service Type         Instance Name\n" +
		"10:00:00.000  Add        2   4 local.               _agentcommander._tcp. Agent Relay\n"
	lookup := "10:00:00.100  Agent\\032Relay._agentcommander._tcp.local. can be reached at relay-host.local.:8443 (interface 4)\n" +
		" v=1 name=Agent\\ Relay pin=" + pin + " mode=host\n"
	for name, body := range map[string]string{"browse.txt": browse, "lookup.txt": lookup} {
		if err := os.WriteFile(filepath.Join(f.dir, name), []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}
}

func (f *discoveryFixture) whois(t *testing.T, name string, tags ...string) {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"Node": map[string]any{"Name": name, "Tags": tags, "Addresses": []string{"100.64.0.7/32"}}})
	f.ts.write(t, "whois-100.64.0.7.json", string(b))
}

func (f *discoveryFixture) discover(t *testing.T) Discovery {
	t.Helper()
	data, e := call(t, f.h, "relay-discover", map[string]any{"refresh": true})
	if e != "" {
		t.Fatal(e)
	}
	var d Discovery
	if err := json.Unmarshal(data, &d); err != nil {
		t.Fatal(err)
	}
	return d
}

func findRelay(d Discovery, url string) *DiscoveredRelay {
	for i := range d.Relays {
		if d.Relays[i].URL == url {
			return &d.Relays[i]
		}
	}
	return nil
}

func TestDiscoverMergesTailnetAndBonjour(t *testing.T) {
	f := newDiscoveryFixture(t, runningStatus)
	f.whois(t, "agent-relay.tail.internal.", "tag:relay")
	f.advertise(t, f.pin)
	d := f.discover(t)

	for _, s := range d.Sources {
		if !s.OK {
			t.Fatalf("source %+v", s)
		}
	}
	if len(d.Relays) != 2 {
		t.Fatalf("expected the merged relay and the offline peer: %+v", d.Relays)
	}
	r := findRelay(d, "https://agent-relay.tail.internal")
	if r == nil {
		t.Fatalf("merged relay should use the tailnet origin: %+v", d.Relays)
	}
	if !slices.Equal(r.Sources, []string{"tailnet", "bonjour"}) || !r.Reachable || r.Pin != f.pin {
		t.Fatalf("relay: %+v", r)
	}
	if r.Verified != "tailnet" || r.TailnetNode != "agent-relay.tail.internal" || r.Name != "Agent Relay" {
		t.Fatalf("identity: %+v", r)
	}
	if r.Membership != "invite" || r.AdminContact != "admin@example.test" || r.Issuer != "https://issuer.example.test" {
		t.Fatalf("info: %+v", r)
	}
	if !r.AdvertisedPinMatches || r.Next != "add" || !r.New || r.Added {
		t.Fatalf("state: %+v", r)
	}
	off := findRelay(d, "https://zeta-relay.tail.internal")
	if off == nil || off.Reachable || off.Next != "unreachable" || !strings.Contains(off.Error, "offline") {
		t.Fatalf("offline peer: %+v", off)
	}
	if d.Relays[0].URL != r.URL {
		t.Fatal("reachable relays sort first")
	}

	// A verified tailnet relay joins without a confirmed pin.
	data, e := call(t, f.h, "relay-join", map[string]any{"relay": r.ID})
	if e != "" {
		t.Fatal(e)
	}
	var s ServerSummary
	json.Unmarshal(data, &s)
	if s.URL != r.URL || s.Pin != f.pin || s.Name != "Agent Relay" {
		t.Fatalf("added server: %+v", s)
	}
	data, _ = call(t, f.h, "relay-discover", map[string]any{})
	var again Discovery
	json.Unmarshal(data, &again)
	r = findRelay(again, "https://agent-relay.tail.internal")
	if !r.Added || r.ServerID != s.ID || r.New || r.Next != "sign-in" {
		t.Fatalf("after join: %+v", r)
	}
}

func TestDiscoverDoesNotVerifyMismatchedNode(t *testing.T) {
	cases := map[string]func(f *discoveryFixture){
		"untagged":      func(f *discoveryFixture) { f.whois(t, "agent-relay.tail.internal.", "tag:server") },
		"other node":    func(f *discoveryFixture) { f.whois(t, "laptop.tail.internal.", "tag:relay") },
		"whois refuses": func(f *discoveryFixture) {},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			f := newDiscoveryFixture(t, runningStatus)
			setup(f)
			r := findRelay(f.discover(t), "https://agent-relay.tail.internal")
			if r == nil || !r.Reachable || r.Verified != "" || r.Next != "confirm" {
				t.Fatalf("relay: %+v", r)
			}
			if _, e := call(t, f.h, "relay-join", map[string]any{"relay": r.ID}); !strings.Contains(e, "confirm the certificate fingerprint") {
				t.Fatalf("join without pin: %q", e)
			}
		})
	}
}

func TestJoinBonjourRelayNeedsConfirmedPin(t *testing.T) {
	f := newDiscoveryFixture(t, needsLoginStatus)
	f.advertise(t, "sha256/bm90IHRoZSBwaW4=")
	d := f.discover(t)
	if d.Sources[0].Name != "tailnet" || d.Sources[0].OK || d.Sources[0].Detail != "this Mac is not on a tailnet" || !d.Sources[1].OK {
		t.Fatalf("sources: %+v", d.Sources)
	}
	r := findRelay(d, "https://relay-host.local:8443")
	if r == nil || r.Verified != "" || r.Next != "confirm" || r.AdvertisedPinMatches || r.Pin != f.pin {
		t.Fatalf("relay: %+v", d.Relays)
	}
	if !slices.Equal(r.Sources, []string{"bonjour"}) {
		t.Fatalf("sources: %v", r.Sources)
	}
	if _, e := call(t, f.h, "relay-join", map[string]any{"relay": r.ID}); !strings.Contains(e, r.Fingerprint) {
		t.Fatalf("join without pin should name the fingerprint: %q", e)
	}
	// The advertised pin is only a hint: it cannot stand in for confirmation.
	if _, e := call(t, f.h, "relay-join", map[string]any{"relay": r.ID, "pin": r.AdvertisedPin}); e != ErrPinMismatch.Error() {
		t.Fatalf("join with advertised pin: %q", e)
	}
	data, e := call(t, f.h, "relay-join", map[string]any{"relay": r.ID, "pin": f.pin, "name": "Office"})
	if e != "" {
		t.Fatal(e)
	}
	var s ServerSummary
	json.Unmarshal(data, &s)
	if s.URL != "https://relay-host.local:8443" || s.Pin != f.pin || s.Name != "Office" {
		t.Fatalf("added: %+v", s)
	}
	if _, e := call(t, f.h, "relay-join", map[string]any{"relay": "r-unknown"}); !strings.Contains(e, "unknown relay") {
		t.Fatalf("unknown relay: %q", e)
	}
}

func TestDiscoverSeenPersists(t *testing.T) {
	f := newDiscoveryFixture(t, runningStatus)
	d := f.discover(t)
	if len(d.Relays) == 0 || !d.Relays[0].New {
		t.Fatalf("relays: %+v", d.Relays)
	}
	if _, e := call(t, f.h, "relay-discover-seen", map[string]any{}); e != "" {
		t.Fatal(e)
	}
	for _, r := range f.discover(t).Relays {
		if r.New {
			t.Fatalf("still new: %+v", r)
		}
	}
	raw, err := os.ReadFile(filepath.Join(f.m.cfg.Dir, "discovery.json"))
	if err != nil || !strings.Contains(string(raw), d.Relays[0].ID) {
		t.Fatalf("discovery.json: %s %v", raw, err)
	}
}

func TestDiscoverWithoutTools(t *testing.T) {
	f := newDiscoveryFixture(t, runningStatus)
	f.m.cfg.Tailscale = filepath.Join(t.TempDir(), "missing")
	f.m.cfg.DNSSD = filepath.Join(t.TempDir(), "missing")
	d := f.discover(t)
	if len(d.Relays) != 0 || len(d.Sources) != 2 {
		t.Fatalf("discovery: %+v", d)
	}
	want := map[string]string{"tailnet": "Tailscale is not installed", "bonjour": "Bonjour is not available on this system"}
	for _, s := range d.Sources {
		if s.OK || s.Detail != want[s.Name] {
			t.Fatalf("source: %+v", s)
		}
	}
	if _, e := call(t, f.h, "relay-discover", map[string]any{"bogus": true}); e != "invalid request" {
		t.Fatalf("unknown field: %q", e)
	}
}

func TestDiscoverCachesBetweenRefreshes(t *testing.T) {
	f := newDiscoveryFixture(t, runningStatus)
	f.discover(t)
	before := strings.Count(f.ts.read("args"), "status --json")
	for i := 0; i < 3; i++ {
		if _, e := call(t, f.h, "relay-discover", map[string]any{}); e != "" {
			t.Fatal(e)
		}
	}
	if after := strings.Count(f.ts.read("args"), "status --json"); after != before {
		t.Fatalf("cached reads ran tailscale %d more times", after-before)
	}
}
