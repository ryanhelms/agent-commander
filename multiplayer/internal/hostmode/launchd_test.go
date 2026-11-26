package hostmode

import (
	"bytes"
	"encoding/xml"
	"errors"
	"net"
	"os"
	"path/filepath"
	"slices"
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

func TestLaunchAgentInstallUninstall(t *testing.T) {
	dir, _ := serviceFixture(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PATH", home)
	t.Setenv("COMMANDER_PG_BIN", filepath.Join(dir, "my postgres", "bin"))
	const mock = `#!/bin/sh
case "$1" in
  bootstrap)
    [ "$2" = "$TEST_DOMAIN" ] && [ -f "$3" ] || exit 1
    : > "$HOME/loaded"
    ;;
  print) [ "$2" = "$TEST_DOMAIN/local.agentcommander.relay" ] && [ -f "$HOME/loaded" ] || exit 113 ;;
  bootout)
    [ "$2" = "$TEST_DOMAIN/local.agentcommander.relay" ] || exit 1
    [ -f "$HOME/loaded" ] || exit 3
    /bin/rm "$HOME/loaded"
    ;;
  *) exit 1 ;;
esac
`
	t.Setenv("TEST_DOMAIN", guiDomain())
	if err := os.WriteFile(filepath.Join(home, "launchctl"), []byte(mock), 0700); err != nil {
		t.Fatal(err)
	}
	if err := Install(dir); err != nil {
		t.Fatal(err)
	}
	plist := filepath.Join(home, "Library", "LaunchAgents", "local.agentcommander.relay.plist")
	data, err := os.ReadFile(plist)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Args []string `xml:"dict>array>string"`
	}
	if err := xml.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(doc.Args, []string{exe, "host", "--dir", dir}) {
		t.Fatalf("unexpected launch arguments %q", doc.Args)
	}
	for _, fragment := range []string{
		"<key>RunAtLoad</key><true/>", "<key>KeepAlive</key><true/>",
		"/logs/relay.log</string>", "/logs/relay.err.log</string>", "my postgres/bin</string>",
	} {
		if !bytes.Contains(data, []byte(fragment)) {
			t.Errorf("plist missing %q", fragment)
		}
	}
	for _, path := range []string{filepath.Join(dir, "logs"), filepath.Join(home, "loaded")} {
		if _, err := os.Stat(path); err != nil {
			t.Fatal(err)
		}
	}
	if err := Uninstall(); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{plist, filepath.Join(home, "loaded")} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("expected uninstall to remove %s, stat error %v", path, err)
		}
	}
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
	status("State: stopped", "CA SPKI pin: unavailable until first start")
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
	status("State: running", "Listen URL: https://studio.test:12345", "CA SPKI pin: sha256/")
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	status("State: stopped", "Listen URL: https://studio.test:0", "CA SPKI pin: sha256/")
}
