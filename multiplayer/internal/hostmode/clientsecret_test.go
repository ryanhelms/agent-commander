package hostmode

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const desktopClient = "desktop.apps.googleusercontent.com"

func TestParseClientSecret(t *testing.T) {
	good := map[string]string{
		`{"installed":{"client_id":"` + desktopClient + `","client_secret":"GOCSPX-abc"}}`: "GOCSPX-abc",
		`{"installed":{"client_secret":"GOCSPX-abc"}}`:                                     "GOCSPX-abc",
		"  GOCSPX-bare\n": "GOCSPX-bare",
	}
	for in, want := range good {
		if got, err := ParseClientSecret([]byte(in), desktopClient); err != nil || got != want {
			t.Errorf("ParseClientSecret(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	bad := []string{
		`{"installed":{"client_id":"other","client_secret":"x"}}`,
		`{"web":{"client_id":"` + desktopClient + `","client_secret":"x"}}`,
		`{"installed":{"client_id":"` + desktopClient + `","client_secret":""}}`,
		"two words", "", strings.Repeat("a", 513), "{not json",
	}
	for _, in := range bad {
		if _, err := ParseClientSecret([]byte(in), desktopClient); err == nil {
			t.Errorf("accepted %q", in)
		}
	}
}

func configuredRelay(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	cfg := Config{
		Name: "Relay", Listen: ":8443", Hostnames: []string{"relay.example.test"},
		Issuer: GoogleIssuer, ClientID: desktopClient, Admins: []string{"admin@example.test"},
	}
	if err := InitConfig(dir, cfg); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestSetAndClearClientSecret(t *testing.T) {
	dir := configuredRelay(t)
	if ClientSecret(dir) != "" {
		t.Fatal("a new relay should not provide a secret")
	}
	if err := SetClientSecret(dir, strings.NewReader(`{"installed":{"client_id":"`+desktopClient+`","client_secret":"GOCSPX-x"}}`)); err != nil {
		t.Fatal(err)
	}
	if got := ClientSecret(dir); got != "GOCSPX-x" {
		t.Fatalf("secret %q", got)
	}
	checkMode(t, filepath.Join(dir, clientSecretFile), 0600)
	if err := SetClientSecret(dir, strings.NewReader(`{"installed":{"client_id":"other","client_secret":"y"}}`)); err == nil {
		t.Fatal("accepted another client's file")
	}
	if got := ClientSecret(dir); got != "GOCSPX-x" {
		t.Fatalf("a refused update changed the secret: %q", got)
	}
	if err := ClearClientSecret(dir); err != nil {
		t.Fatal(err)
	}
	if err := ClearClientSecret(dir); err != nil {
		t.Fatal("clearing twice should succeed")
	}
	if ClientSecret(dir) != "" {
		t.Fatal("secret still provided after clearing")
	}
	if err := SetClientSecret(t.TempDir(), strings.NewReader("x")); err == nil {
		t.Fatal("stored a secret for an unconfigured relay")
	}
}

func TestConfigureAdoptsThisMacsClientSecret(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "relay")
	if err := Configure(dir, Setup{Admin: "ryan@example.org"}, fakeProbe(t, desktopClient)); err != nil {
		t.Fatal(err)
	}
	if got := ClientSecret(dir); got != "s" {
		t.Fatalf("adopted secret %q", got)
	}

	// A Mac whose client differs from the one chosen keeps the relay without a secret.
	other := filepath.Join(t.TempDir(), "relay")
	if err := Configure(other, Setup{Admin: "ryan@example.org", ClientID: "chosen.apps.googleusercontent.com"}, fakeProbe(t, desktopClient)); err != nil {
		t.Fatal(err)
	}
	if ClientSecret(other) != "" {
		t.Fatal("adopted a secret for a different client")
	}
	if _, err := os.Stat(filepath.Join(other, clientSecretFile)); !os.IsNotExist(err) {
		t.Fatalf("secret file: %v", err)
	}
}
