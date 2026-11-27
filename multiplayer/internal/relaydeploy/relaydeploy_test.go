package relaydeploy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agentcommander.network/pilot/internal/hostmode"
)

func TestPublicURLAndPin(t *testing.T) {
	status := "State: running\nServer pin: sha256/abc=\nCA pin: sha256/ca=\n"
	cases := []struct {
		o    Options
		ts   *TailnetState
		want string
	}{
		{Options{Port: 443, Config: hostmode.Config{Hostnames: []string{"relay.example.org"}}}, nil, "https://relay.example.org"},
		{Options{Port: 8443, Config: hostmode.Config{Hostnames: []string{"relay.example.org"}}}, nil, "https://relay.example.org:8443"},
		{Options{Port: 443, Config: hostmode.Config{Hostnames: []string{"::1"}}}, nil, "https://[::1]"},
		{Options{Port: 443}, &TailnetState{DNS: "agent-relay.tail.internal"}, "https://agent-relay.tail.internal"},
		{Options{Port: 443, PublicURL: "https://localhost:22443"}, nil, "https://localhost:22443"},
	}
	for _, c := range cases {
		url, pin := publicURL(c.o, status, c.ts)
		if url != c.want || pin != "sha256/abc=" {
			t.Errorf("publicURL = %q, %q; want %q", url, pin, c.want)
		}
	}
}

func TestInitFlagsRoundTrip(t *testing.T) {
	cfg := hostmode.Config{Name: "r", Listen: ":443", Issuer: "https://i", ClientID: "c",
		Hostnames: []string{"a", "b"}, Admins: []string{"x@y"}, AllowedEmails: []string{"m@y"}}
	got := cfg.InitFlags()
	want := []string{"--name", "r", "--listen", ":443", "--issuer", "https://i", "--client-id", "c",
		"--hostname", "a", "--hostname", "b", "--admin", "x@y", "--allow-email", "m@y"}
	if len(got) != len(want) {
		t.Fatalf("flags %q", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("flags %q, want %q", got, want)
		}
	}
}

func TestClientSecretInstall(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "client.json")
	if err := os.WriteFile(path, []byte(`{"installed":{"client_id":"desktop","client_secret":"GOCSPX-x"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := readClientSecret(path, "desktop"); err != nil || got != "GOCSPX-x" {
		t.Fatalf("read: %q %v", got, err)
	}
	if _, err := readClientSecret(path, "other"); err == nil {
		t.Fatal("accepted another client's file")
	}
	if _, err := readClientSecret(filepath.Join(dir, "missing"), "desktop"); err == nil {
		t.Fatal("accepted a missing file")
	}
	if got := dockerSecretCommand("docker"); got != "docker run --rm -i -v agent-commander-relay:/data agent-commander-relay:current configure --client-secret-file=-" {
		t.Fatalf("docker: %s", got)
	}
	got := systemdSecretCommand("sudo -n ")
	for _, want := range []string{"sudo -n sh -c ", "/usr/local/bin/commander-relay host --dir /var/lib/agent-commander/relay configure --client-secret-file=-",
		"chown agent-commander: ", "/var/lib/agent-commander/relay/oauth-client-secret"} {
		if !strings.Contains(got, want) {
			t.Fatalf("systemd command %q lacks %q", got, want)
		}
	}
	// No secret file means nothing to send.
	if err := installClientSecret(t.Context(), Options{}, nil, "unused"); err != nil {
		t.Fatal(err)
	}
}
