package sshx

import (
	"context"
	"os/exec"
	"testing"
)

func TestQuoteRoundTripsThroughSh(t *testing.T) {
	for _, word := range []string{"plain", "with space", "it's", `$HOME "x"`, "", "a\nb", "*"} {
		out, err := exec.Command("sh", "-c", "printf %s "+Quote(word)).Output()
		if err != nil {
			t.Fatal(err)
		}
		if string(out) != word {
			t.Errorf("Quote(%q) came back as %q", word, out)
		}
	}
}

func TestCommandRefusesOptionDestinations(t *testing.T) {
	if _, err := (Target{Destination: "-oProxyCommand=x"}).Command(context.Background(), "true"); err == nil {
		t.Fatal("expected a destination that looks like an option to be refused")
	}
	cmd, err := Target{Destination: "ops@server", Options: []string{"-p", "2222"}}.Command(context.Background(), "echo 'hi'")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"ssh", "-o", "BatchMode=yes", "-p", "2222", "--", "ops@server", `sh -c 'echo '\''hi'\'''`}
	if len(cmd.Args) != len(want) {
		t.Fatalf("args %q", cmd.Args)
	}
	for i := range want {
		if cmd.Args[i] != want[i] {
			t.Fatalf("args %q, want %q", cmd.Args, want)
		}
	}
}
