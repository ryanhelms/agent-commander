package identity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGoogleDesktopSecretFallsBackToRelay(t *testing.T) {
	c := Client{GoogleDesktopConfig: filepath.Join(t.TempDir(), "google-desktop-client.json")}
	write := func(id string) {
		t.Helper()
		data := `{"installed":{"client_id":"` + id + `","client_secret":"local-secret"}}`
		if err := os.WriteFile(c.GoogleDesktopConfig, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}

	// No local file: the relay's secret is used; without one, the provisioning error stays.
	if got, err := c.googleDesktopSecret("native", googleTokenEndpoint, "relay-secret"); err != nil || got != "relay-secret" {
		t.Fatalf("missing file: %q %v", got, err)
	}
	if _, err := c.googleDesktopSecret("native", googleTokenEndpoint, ""); err == nil || !strings.Contains(err.Error(), "provision this Mac") {
		t.Fatalf("missing file without relay secret: %v", err)
	}
	// A matching local file wins over the relay.
	write("native")
	if got, err := c.googleDesktopSecret("native", googleTokenEndpoint, "relay-secret"); err != nil || got != "local-secret" {
		t.Fatalf("matching file: %q %v", got, err)
	}
	// A file for another client gives way to the relay's secret.
	write("another-relay")
	if got, err := c.googleDesktopSecret("native", googleTokenEndpoint, "relay-secret"); err != nil || got != "relay-secret" {
		t.Fatalf("other client: %q %v", got, err)
	}
	if _, err := c.googleDesktopSecret("native", googleTokenEndpoint, ""); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("other client without relay secret: %v", err)
	}
	// A malformed relay secret is ignored.
	if _, err := c.googleDesktopSecret("native", googleTokenEndpoint, "has space"); err == nil {
		t.Fatal("used a malformed relay secret")
	}
	// The token endpoint check still comes first.
	if _, err := c.googleDesktopSecret("native", "https://evil.example.test/token", "relay-secret"); err == nil || !strings.Contains(err.Error(), "unexpected token endpoint") {
		t.Fatalf("unexpected endpoint: %v", err)
	}
}

func TestProvidedClientSecret(t *testing.T) {
	if (Config{}).ProvidedClientSecret() != "" {
		t.Fatal("no function should provide nothing")
	}
	if got := (Config{ClientSecret: func() string { return "s" }}).ProvidedClientSecret(); got != "s" {
		t.Fatalf("got %q", got)
	}
}
