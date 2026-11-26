package hostmode

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func fakeProbe(t *testing.T, clientID string) Probe {
	t.Helper()
	network := t.TempDir()
	if clientID != "" {
		data := `{"installed":{"client_id":"` + clientID + `","client_secret":"s"}}`
		if err := os.WriteFile(filepath.Join(network, "google-desktop-client.json"), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return Probe{
		Hostname:     func() (string, error) { return "Ryans-Mac.local", nil },
		ComputerName: func() string { return "Ryan’s Mac" },
		Tailscale:    func() (string, []string) { return "ryans-mac.tail.example.", []string{"100.64.0.1", "fd7a::1"} },
		NetworkDir:   func() string { return network },
	}
}

func TestSuggestPutsTheTailnetNameFirst(t *testing.T) {
	s := fakeProbe(t, "desktop.apps.googleusercontent.com").Suggest()
	if s.Name != "Ryan’s Mac" || s.Issuer != GoogleIssuer || s.ClientID != "desktop.apps.googleusercontent.com" {
		t.Fatalf("suggestion: %+v", s)
	}
	want := []string{"ryans-mac.tail.example", "Ryans-Mac.local", "100.64.0.1", "fd7a::1"}
	if !slices.Equal(s.Hostnames, want) {
		t.Fatalf("hostnames %v, want %v", s.Hostnames, want)
	}

	bare := Probe{Hostname: func() (string, error) { return "", errors.New("none") }}.Suggest()
	if bare.Name != "My relay" || !slices.Equal(bare.Hostnames, []string{"localhost"}) || bare.ClientID != "" {
		t.Fatalf("bare suggestion: %+v", bare)
	}
}

func TestConfigureNeedsOnlyTheAdmin(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "relay")
	probe := fakeProbe(t, "desktop.apps.googleusercontent.com")
	if err := Configure(dir, Setup{}, probe); err == nil || !strings.Contains(err.Error(), "email") {
		t.Fatalf("setup without an admin: %v", err)
	}
	if err := Configure(dir, Setup{Admin: "ryan@example.org"}, probe); err != nil {
		t.Fatal(err)
	}
	cfg, err := ReadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Name != "Ryan’s Mac" || cfg.Listen != ":443" || cfg.Hostnames[0] != "ryans-mac.tail.example" ||
		cfg.ClientID != "desktop.apps.googleusercontent.com" || !slices.Equal(cfg.Admins, []string{"ryan@example.org"}) {
		t.Fatalf("configuration: %+v", cfg)
	}
	if err := Configure(dir, Setup{Admin: "ryan@example.org"}, probe); err == nil {
		t.Fatal("setup replaced an existing configuration")
	}
}

func TestConfigureAsksForAClientIDWhenTheMacHasNone(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "relay")
	probe := fakeProbe(t, "")
	if err := Configure(dir, Setup{Admin: "ryan@example.org"}, probe); err == nil || !strings.Contains(err.Error(), "client ID") {
		t.Fatalf("setup without a client: %v", err)
	}
	if err := Configure(dir, Setup{Admin: "ryan@example.org", ClientID: "typed.example"}, probe); err != nil {
		t.Fatal(err)
	}
}

func TestInspectSuggestsASetupOnlyWhileUnconfigured(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	probe := fakeProbe(t, "desktop.apps.googleusercontent.com")
	dir := filepath.Join(t.TempDir(), "relay")
	report, err := InspectWith(dir, probe)
	if err != nil || report.Setup == nil || report.Setup.ClientID == "" {
		t.Fatalf("unconfigured report: %+v, %v", report, err)
	}
	if err := Configure(dir, Setup{Admin: "ryan@example.org"}, probe); err != nil {
		t.Fatal(err)
	}
	if report, err = InspectWith(dir, probe); err != nil || report.Setup != nil || report.State != "stopped" {
		t.Fatalf("configured report: %+v, %v", report, err)
	}
}
