package device

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
)

func TestNormalizeRelay(t *testing.T) {
	cases := map[string]string{
		"ryan-mac.tail.internal":            "https://ryan-mac.tail.internal",
		"Relay.Example.org:9443":            "https://relay.example.org:9443",
		"https://relay.example.org:443/":    "https://relay.example.org",
		"100.64.0.1":                        "https://100.64.0.1",
		" https://relay.example.org:8443  ": "https://relay.example.org:8443",
	}
	for in, want := range cases {
		got, err := NormalizeRelay(in)
		if err != nil || got != want {
			t.Errorf("NormalizeRelay(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "http://relay", "https://relay/path", "https://u@relay", "https://relay?x=1"} {
		if _, err := NormalizeRelay(bad); err == nil {
			t.Errorf("NormalizeRelay(%q) accepted", bad)
		}
	}
}

func testManager(t *testing.T) *Manager {
	t.Helper()
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	m, err := NewManager(context.Background(), ManagerConfig{
		Dir: state, CommanderSocket: filepath.Join(dir, "commander.sock"),
		Secrets: func(relay string) (devicekeys.Store, error) {
			return devicekeys.Directory(filepath.Join(dir, "secrets", key(relay)))
		},
		OpenBrowser: func(string) error { return nil }, NoPresence: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(m.Close)
	return m
}

func call(t *testing.T, h http.Handler, verb string, in any) (json.RawMessage, string) {
	t.Helper()
	b, _ := json.Marshal(in)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("POST", "/tray/"+verb, bytes.NewReader(b)))
	var out struct {
		OK    bool
		Data  json.RawMessage
		Error string
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatalf("%s: %v (%s)", verb, err, w.Body.String())
	}
	return out.Data, out.Error
}

func TestServerListLifecycle(t *testing.T) {
	m := testManager(t)
	h := m.Handler()
	var a, b ServerSummary
	data, e := call(t, h, "server-add", map[string]any{"url": "alpha.example.test", "pin": "sha256/AAAA"})
	if e != "" {
		t.Fatal(e)
	}
	json.Unmarshal(data, &a)
	data, e = call(t, h, "server-add", map[string]any{"url": "beta.example.test:9443", "name": "Beta"})
	if e != "" {
		t.Fatal(e)
	}
	json.Unmarshal(data, &b)
	if a.State != "signedOut" || a.Name != "alpha" || b.Name != "Beta" || b.URL != "https://beta.example.test:9443" {
		t.Fatalf("unexpected summaries %+v %+v", a, b)
	}
	if _, e = call(t, h, "server-add", map[string]any{"url": "https://alpha.example.test"}); e == "" {
		t.Fatal("duplicate server accepted")
	}
	if _, e = call(t, h, "server-update", map[string]any{"server": a.ID, "favorite": true}); e != "" {
		t.Fatal(e)
	}
	data, _ = call(t, h, "servers", map[string]any{})
	var list struct{ Servers []ServerSummary }
	json.Unmarshal(data, &list)
	if len(list.Servers) != 2 || list.Servers[0].ID != a.ID || !list.Servers[0].Favorite {
		t.Fatalf("favorites should sort first: %+v", list.Servers)
	}
	// Per-server verbs route by id; status works while signed out.
	data, e = call(t, h, "status", map[string]any{"server": b.ID})
	if e != "" || !strings.Contains(string(data), `"signedIn":false`) {
		t.Fatalf("status: %s %s", data, e)
	}
	if _, e = call(t, h, "status", map[string]any{}); e == "" {
		t.Fatal("status without a server should need one when several exist")
	}
	// The list survives a restart.
	raw, err := os.ReadFile(filepath.Join(m.cfg.Dir, "servers.json"))
	if err != nil || !strings.Contains(string(raw), "beta.example.test") {
		t.Fatalf("servers.json: %s %v", raw, err)
	}
	if _, e = call(t, h, "server-remove", map[string]any{"server": b.ID}); e != "" {
		t.Fatal(e)
	}
	data, _ = call(t, h, "servers", map[string]any{})
	json.Unmarshal(data, &list)
	if len(list.Servers) != 1 {
		t.Fatalf("remove failed: %+v", list.Servers)
	}
}

func TestProbeAndPinMismatch(t *testing.T) {
	relay := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/info" {
			json.NewEncoder(w).Encode(RelayInfo{Version: "test", Mode: "host", Issuer: "https://issuer.example.test", ClientID: "client"})
			return
		}
		http.NotFound(w, r)
	}))
	defer relay.Close()
	m := testManager(t)
	p, err := m.ProbeServer(context.Background(), relay.URL)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Steps) != 5 {
		t.Fatalf("expected five steps: %+v", p.Steps)
	}
	for _, s := range p.Steps {
		if !s.OK {
			t.Fatalf("step failed: %+v", s)
		}
	}
	if p.Steps[2].SystemTrusted || !strings.HasPrefix(p.Steps[2].Pin, "sha256/") {
		t.Fatalf("test certificate should need pinning: %+v", p.Steps[2])
	}
	if p.Steps[4].Detail != "https://issuer.example.test" {
		t.Fatalf("signin step: %+v", p.Steps[4])
	}

	// A wrong pin marks the server certChanged once a request reaches the relay.
	h := m.Handler()
	data, e := call(t, h, "server-add", map[string]any{"url": relay.URL, "pin": "sha256/d3Jvbmc="})
	if e != "" {
		t.Fatal(e)
	}
	var s ServerSummary
	json.Unmarshal(data, &s)
	m.mu.Lock()
	a := m.agents[s.ID]
	m.mu.Unlock()
	resp, err := a.http.Get(relay.URL + "/v1/info")
	if err == nil {
		resp.Body.Close()
		t.Fatal("pinned client accepted a different key")
	}
	for i := 0; i < 100; i++ {
		if sum := m.Summaries(); sum[0].State == "certChanged" {
			if _, e = call(t, h, "server-trust", map[string]any{"server": s.ID, "pin": p.Steps[2].Pin}); e != "" {
				t.Fatal(e)
			}
			if m.Summaries()[0].State == "certChanged" {
				t.Fatal("trust did not clear certChanged")
			}
			return
		}
		testSleep()
	}
	t.Fatal("server never reported certChanged")
}

func testSleep() { <-time.After(10 * time.Millisecond) }
