package hostmode

import (
	"net"
	"path/filepath"
	"strings"
	"testing"
)

func serviceFixture(t *testing.T) (string, Config) {
	t.Helper()
	cfg := Config{
		Name: "studio", Listen: ":0", Hostnames: []string{"studio.test"},
		Issuer: "https://issuer.test", ClientID: "relay", Admins: []string{"user@example.org"},
	}
	dir := filepath.Join(t.TempDir(), "Studio & Relay")
	if err := InitConfig(dir, cfg); err != nil {
		t.Fatal(err)
	}
	return dir, cfg
}

func TestStatusTracksHostDirectory(t *testing.T) {
	dir, cfg := serviceFixture(t)
	status := func(want ...string) {
		t.Helper()
		var out strings.Builder
		if err := Status(dir, &out); err != nil {
			t.Fatal(err)
		}
		for _, line := range want {
			if !strings.Contains(out.String(), line) {
				t.Fatalf("status missing %q in %q", line, out.String())
			}
		}
	}
	status("State: stopped", "Server pin: unavailable until first start", "CA SPKI pin: unavailable until first start")
	if _, err := EnsureTLS(dir, cfg.Hostnames); err != nil {
		t.Fatal(err)
	}
	addr := &net.TCPAddr{IP: net.IPv6unspecified, Port: 12345}
	lock, err := LockHost(dir, addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lock.Close() })
	if other, err := LockHost(dir, addr); err == nil {
		other.Close()
		t.Fatal("a second host acquired the same directory")
	}
	status("State: running", "Listen URL: https://studio.test:12345", "Server pin: sha256/", "CA SPKI pin: sha256/")
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	status("State: stopped", "Listen URL: https://studio.test:0", "CA SPKI pin: sha256/")
}
