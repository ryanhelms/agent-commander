package headless

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/localapi"
)

func testLayout(t *testing.T) Layout {
	t.Helper()
	root := t.TempDir()
	return Layout{Root: root, Versions: filepath.Join(root, "versions"), Current: filepath.Join(root, "current"),
		Previous: filepath.Join(root, "previous"), Bin: filepath.Join(root, "bin", "agentctl"),
		Paths: localapi.Paths{State: filepath.Join(root, "state"), Socket: filepath.Join(root, "state", "service.sock")}}
}

func binary(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "agentctl")
	if err := os.WriteFile(path, []byte(content), 0755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestStageNamesReleasesAndLocalBuilds(t *testing.T) {
	l := testLayout(t)
	v, err := l.Stage(binary(t, "release"), "v0.2.0-pilot.1")
	if err != nil || v != "v0.2.0-pilot.1" {
		t.Fatalf("release stage = %q, %v", v, err)
	}
	if again, err := l.Stage(binary(t, "release"), "v0.2.0-pilot.1"); err != nil || again != v {
		t.Fatalf("restaging the same bytes = %q, %v", again, err)
	}
	if _, err := l.Stage(binary(t, "other"), "v0.2.0-pilot.1"); err == nil {
		t.Fatal("expected a conflict for a different binary under the same tag")
	}
	dev, err := l.Stage(binary(t, "local"), "dev-abc")
	if err != nil || !strings.HasPrefix(dev, "dev-") || dev == "dev-abc" {
		t.Fatalf("a local build must be named by digest, got %q, %v", dev, err)
	}
	if _, err := l.Stage(binary(t, "x"), "v1/../../etc"); err == nil {
		t.Fatal("expected an invalid version name to be refused")
	}
	if data, _ := os.ReadFile(filepath.Join(l.Versions, v, "VERSION")); string(data) != v+"\n" {
		t.Fatalf("VERSION = %q", data)
	}
}

func TestActivateKeepsPreviousAndPruneKeepsThree(t *testing.T) {
	l := testLayout(t)
	var names []string
	for i, content := range []string{"a", "b", "c", "d", "e"} {
		v, err := l.Stage(binary(t, content), "v0.1."+string(rune('0'+i)))
		if err != nil {
			t.Fatal(err)
		}
		// Installed sorts by modification time; make it deterministic.
		stamp := time.Now().Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(filepath.Join(l.Versions, v), stamp, stamp); err != nil {
			t.Fatal(err)
		}
		names = append(names, v)
	}
	if err := l.activate(names[0], ""); err != nil {
		t.Fatal(err)
	}
	if err := l.activate(names[1], names[0]); err != nil {
		t.Fatal(err)
	}
	if cur, _ := l.Link(l.Current); cur != names[1] {
		t.Fatalf("current = %q", cur)
	}
	if prev, _ := l.Link(l.Previous); prev != names[0] {
		t.Fatalf("previous = %q", prev)
	}
	if err := l.prune(); err != nil {
		t.Fatal(err)
	}
	left, _ := l.Installed()
	if len(left) != keepVersions {
		t.Fatalf("kept %v", left)
	}
	for _, must := range names[:2] {
		if _, err := os.Stat(l.Executable(must)); err != nil {
			t.Fatalf("prune removed %s, the current or previous version", must)
		}
	}
	if _, err := os.Stat(l.Executable(names[4])); err != nil {
		t.Fatal("prune removed the newest other version")
	}
}

func TestUnitKeepsWorkersAcrossRestart(t *testing.T) {
	l := testLayout(t)
	u := l.Unit()
	if u.KillMode != "process" || u.System || u.Exec[1] != "serve" {
		t.Fatalf("unexpected unit %+v", u)
	}
	env := strings.Join(u.Environment, "\n")
	for _, want := range []string{"AGENT_COMMANDER_HOME=" + l.Paths.State, "AGENT_COMMANDER_SOCKET=" + l.Paths.Socket, "PATH="} {
		if !strings.Contains(env, want) {
			t.Errorf("unit environment lacks %q: %s", want, env)
		}
	}
}

func TestExpectedVersion(t *testing.T) {
	if expected("v1.0.0", "ignored") != "v1.0.0" || expected("dev-1234", "dev-abcd") != "dev-abcd" {
		t.Fatal("expected() must use the tag for releases and the reported version for local builds")
	}
}
