package bonjour

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Output captured from macOS dns-sd.
const browseOutput = `Browsing for _agentcommander._tcp.local.
DATE: ---Fri 27 Nov 2026---
10:44:42.397  ...STARTING...
Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
10:44:42.397  Add        3   1 local.               _agentcommander._tcp. Test Relay
10:44:42.397  Add        3  29 local.               _agentcommander._tcp. Test Relay
10:44:42.397  Add        2  18 local.               _agentcommander._tcp. Other
10:44:43.000  Rmv        0  18 local.               _agentcommander._tcp. Other
10:44:43.100  Rmv        0   1 local.               _agentcommander._tcp. Test Relay
`

const lookupOutput = `Lookup Test Relay._agentcommander._tcp.local.
DATE: ---Fri 27 Nov 2026---
10:44:44.402  ...STARTING...
10:44:44.403  Test\032Relay._agentcommander._tcp.local. can be reached at Nicks-MacBook-Pro.local.:18443 (interface 18) Flags: 1
 v=1 name=Test\ Relay pin=sha256/AbC+/= mode=host odd=a\\b\032c
10:44:44.403  Test\032Relay._agentcommander._tcp.local. can be reached at Nicks-MacBook-Pro.local.:18443 (interface 18)
 v=1
`

func TestParseBrowseKeepsPresentInstances(t *testing.T) {
	got := parseBrowse(strings.NewReader(browseOutput))
	if len(got) != 1 || got[0] != "Test Relay" {
		t.Fatalf("names: %q", got)
	}
}

func TestParseBrowseAcceptsSpacePaddedHours(t *testing.T) {
	const output = `Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
 0:51:56.064  Add        3   1 local.               _agentcommander._tcp. First Relay
 0:51:56.064  Add        3  29 local.               _agentcommander._tcp. First Relay
 0:51:56.065  Add        2  18 local.               _agentcommander._tcp. Removed Relay
 0:51:57.000  Rmv        0  18 local.               _agentcommander._tcp. Removed Relay
 0:51:57.100  Rmv        0   1 local.               _agentcommander._tcp. First Relay
10:44:42.397  Add        2  18 local.               _agentcommander._tcp. Last Relay
`
	got := parseBrowse(strings.NewReader(output))
	if len(got) != 2 || got[0] != "First Relay" || got[1] != "Last Relay" {
		t.Fatalf("names: %q", got)
	}
}

func TestParseLookup(t *testing.T) {
	in, err := parseLookup(strings.NewReader(lookupOutput))
	if err != nil {
		t.Fatal(err)
	}
	if in.Host != "Nicks-MacBook-Pro.local" || in.Port != 18443 {
		t.Fatalf("instance: %+v", in)
	}
	want := map[string]string{"v": "1", "name": "Test Relay", "pin": "sha256/AbC+/=", "mode": "host", "odd": `a\b c`}
	for k, v := range want {
		if in.TXT[k] != v {
			t.Fatalf("TXT %s = %q, want %q (all %q)", k, in.TXT[k], v, in.TXT)
		}
	}
	if _, err := parseLookup(strings.NewReader("Lookup x\n")); err == nil {
		t.Fatal("expected no answer")
	}
}

func TestCleanName(t *testing.T) {
	if got := CleanName("  My\x00 Relay\n "); got != "My Relay" {
		t.Fatalf("got %q", got)
	}
	long := strings.Repeat("é", 40) // 80 bytes
	if got := CleanName(long); len(got) > 63 || !strings.HasPrefix(long, got) {
		t.Fatalf("got %q (%d bytes)", got, len(got))
	}
}

func TestServiceValidate(t *testing.T) {
	ok := Service{Name: "R", Port: 443, TXT: map[string]string{"v": "1"}}
	if err := ok.validate(); err != nil {
		t.Fatal(err)
	}
	for _, s := range []Service{
		{Name: "", Port: 443},
		{Name: "R", Port: 0},
		{Name: "R", Port: 443, TXT: map[string]string{"Bad Key": "x"}},
		{Name: "R", Port: 443, TXT: map[string]string{"v": "a\nb"}},
	} {
		if s.validate() == nil {
			t.Fatalf("accepted %+v", s)
		}
	}
}

// fakeDNSSD stands in for dns-sd: -B prints browse.txt, -L prints lookup.txt,
// -R records its arguments and confirms. Each then waits to be killed.
const fakeDNSSD = `#!/bin/sh
D="$(dirname "$0")"
case "$1" in
-B) cat "$D/browse.txt"; exec sleep 30 ;;
-L) cat "$D/lookup.txt"; exec sleep 30 ;;
-R) printf '%s\n' "$@" > "$D/register-args"
    echo "Got a reply for service x: Name now registered and active"; exec sleep 30 ;;
esac
exit 2
`

func fakeTools(t *testing.T) (Tools, string) {
	t.Helper()
	dir := t.TempDir()
	write := func(name, body string, mode os.FileMode) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), mode); err != nil {
			t.Fatal(err)
		}
	}
	write("dns-sd", fakeDNSSD, 0755)
	write("browse.txt", browseOutput, 0644)
	write("lookup.txt", lookupOutput, 0644)
	warmUp(filepath.Join(dir, "dns-sd"))
	return Tools{DNSSD: filepath.Join(dir, "dns-sd")}, dir
}

// warmUp runs a new script once. macOS scans a freshly written executable on
// its first run, which can outlast a short browse window under load.
func warmUp(path string) {
	_ = exec.Command(path, "-warm").Run()
}

func TestBrowseWithFakeTool(t *testing.T) {
	tools, _ := fakeTools(t)
	list, err := tools.Browse(context.Background(), 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].Name != "Test Relay" || list[0].Port != 18443 || list[0].TXT["pin"] != "sha256/AbC+/=" {
		t.Fatalf("list: %+v", list)
	}
}

func TestAdvertiseWithFakeTool(t *testing.T) {
	tools, dir := fakeTools(t)
	stop, err := tools.Advertise(context.Background(), Service{Name: "My Relay", Port: 8443, TXT: map[string]string{"v": "1", "pin": "sha256/x"}})
	if err != nil {
		t.Fatal(err)
	}
	stop()
	stop() // idempotent
	b, _ := os.ReadFile(filepath.Join(dir, "register-args"))
	want := "-R\nMy Relay\n_agentcommander._tcp\nlocal.\n8443\npin=sha256/x\nv=1\n"
	if string(b) != want {
		t.Fatalf("args:\n%s\nwant:\n%s", b, want)
	}
}

func TestUnavailable(t *testing.T) {
	tools := Tools{DNSSD: filepath.Join(t.TempDir(), "missing")}
	if _, err := tools.Browse(context.Background(), time.Millisecond); err != ErrUnavailable {
		t.Fatalf("browse: %v", err)
	}
}

// TestSystemResponder registers and finds a relay through the real dns-sd.
func TestSystemResponder(t *testing.T) {
	if runtime.GOOS != "darwin" || testing.Short() {
		t.Skip("needs macOS dns-sd")
	}
	var tools Tools
	name := fmt.Sprintf("Commander Test %d", time.Now().UnixNano())
	stop, err := tools.Advertise(context.Background(), Service{Name: name, Port: 18443, TXT: map[string]string{"v": "1", "name": name, "pin": "sha256/test="}})
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	list, err := tools.Browse(context.Background(), 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	for _, in := range list {
		if in.Name == name {
			if in.Port != 18443 || in.TXT["pin"] != "sha256/test=" || in.TXT["name"] != name || in.Host == "" {
				t.Fatalf("instance: %+v", in)
			}
			return
		}
	}
	t.Fatalf("%q not found in %+v", name, list)
}
