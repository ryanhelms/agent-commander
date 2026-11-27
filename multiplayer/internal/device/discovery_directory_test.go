package device

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
)

func TestDiscoverReadsThePublicDirectory(t *testing.T) {
	relay := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/info" {
			json.NewEncoder(w).Encode(map[string]any{"version": "1", "mode": "edge", "name": "Public Relay", "membership": "open"})
			return
		}
		http.NotFound(w, r)
	}))
	defer relay.Close()
	pin := SPKIPin(relay.Certificate())
	dir := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/relays" {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"relays": []map[string]any{
			{"url": "https://public.example.test", "name": "Listed name", "pin": pin},
			{"url": "not a url"},
		}})
	}))
	defer dir.Close()
	roots := x509.NewCertPool()
	roots.AddCert(dir.Certificate())
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		switch address {
		case "example.com:443":
			return (&net.Dialer{}).DialContext(ctx, network, dir.Listener.Addr().String())
		case "public.example.test:443":
			return (&net.Dialer{}).DialContext(ctx, network, relay.Listener.Addr().String())
		}
		return nil, errors.New("connection refused")
	}
	base := t.TempDir()
	missing := filepath.Join(base, "missing")
	m, err := NewManager(context.Background(), ManagerConfig{
		Dir: filepath.Join(base, "state"), CommanderSocket: filepath.Join(base, "commander.sock"),
		Secrets: func(relay string) (devicekeys.Store, error) {
			return devicekeys.Directory(filepath.Join(base, "secrets", key(relay)))
		},
		OpenBrowser: func(string) error { return nil }, NoPresence: true, Tailscale: missing, DNSSD: missing,
		BonjourWindow: 100 * time.Millisecond, Dial: dial, Roots: roots, DirectoryURL: "https://example.com",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	d, err := m.Discover(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	var src *DiscoverySource
	for i := range d.Sources {
		if d.Sources[i].Name == "directory" {
			src = &d.Sources[i]
		}
	}
	if src == nil || !src.OK {
		t.Fatalf("directory source: %+v", d.Sources)
	}
	if len(d.Relays) != 1 {
		t.Fatalf("relays: %+v", d.Relays)
	}
	r := d.Relays[0]
	if r.URL != "https://public.example.test" || r.Sources[0] != "directory" || r.Name != "Public Relay" || r.Membership != "open" {
		t.Fatalf("relay: %+v", r)
	}
	// The listed pin is a hint: the relay still needs confirmation.
	if !r.AdvertisedPinMatches || r.Verified != "" || r.Next != "confirm" {
		t.Fatalf("trust: %+v", r)
	}

	// An unreachable directory is reported, not fatal.
	m.cfg.DirectoryURL = "https://unreachable.example.test"
	d, _ = m.Discover(context.Background(), true)
	for _, s := range d.Sources {
		if s.Name == "directory" && (s.OK || s.Detail != "cannot reach the directory") {
			t.Fatalf("unreachable: %+v", s)
		}
	}
	// No directory configured leaves the source out.
	m.cfg.DirectoryURL = ""
	d, _ = m.Discover(context.Background(), true)
	for _, s := range d.Sources {
		if s.Name == "directory" {
			t.Fatal("directory source without a directory")
		}
	}
}
