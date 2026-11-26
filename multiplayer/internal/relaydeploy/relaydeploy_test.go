package relaydeploy

import (
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
