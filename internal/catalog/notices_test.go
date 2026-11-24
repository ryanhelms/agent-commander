package catalog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRefreshNoticeFollowsTheCheckedPin(t *testing.T) {
	state := t.TempDir()
	root := filepath.Join(state, "catalog")
	if err := os.MkdirAll(filepath.Join(root, "pins"), 0700); err != nil {
		t.Fatal(err)
	}
	p := pin{
		Current:      InstalledBinary{StagedBinary: StagedBinary{ID: "demo", Version: "2.0.0", ManifestSHA256: strings.Repeat("a", 64)}, Command: "/test/adapter"},
		UpdateSource: &updateSource{EntryURL: "https://example.test/entry", SignatureURL: "https://example.test/sig"},
	}
	save := func(p pin) {
		t.Helper()
		if err := writePin(t.Context(), root, "demo", p); err != nil {
			t.Fatal(err)
		}
	}
	save(p)
	pending := Notice{AdapterID: "demo", CurrentVersion: "2.0.0", AvailableVersion: "4.0.0", ManifestSHA256: strings.Repeat("b", 64)}
	if err := recordRefreshNotice(t.Context(), state, &p, &pending); err != nil {
		t.Fatal(err)
	}
	info := func() os.FileInfo {
		t.Helper()
		fi, err := os.Stat(filepath.Join(root, "pins", "demo.json"))
		if err != nil {
			t.Fatal(err)
		}
		return fi
	}
	before := info()
	if err := recordRefreshNotice(t.Context(), state, &p, &pending); err != nil || !os.SameFile(before, info()) {
		t.Fatalf("identical verified refresh rewrote the pin: %v", err)
	}
	p.Notice = &pending
	for _, v := range []string{"1.0.0", "3.0.0"} {
		if got := p.noticeFor(v); got == nil || got.CurrentVersion != v || p.Notice.CurrentVersion != "2.0.0" {
			t.Fatalf("moving pin to %s corrupted the verified notice: %+v", v, got)
		}
	}
	changed := p
	changed.Current.ManifestSHA256 = strings.Repeat("c", 64)
	save(changed)
	if err := recordRefreshNotice(t.Context(), state, &p, nil); err == nil {
		t.Fatal("a stale refresh cleared a newer pin's notice")
	}
	changed = p
	changed.UpdateSource = &updateSource{EntryURL: "https://other.test/entry", SignatureURL: p.UpdateSource.SignatureURL}
	save(changed)
	if err := recordRefreshNotice(t.Context(), state, &p, nil); err == nil {
		t.Fatal("a refresh from a previous source changed the notice")
	}
	for _, version := range []string{"4.0.0", "5.0.0", "invalid"} {
		if got := p.noticeFor(version); got != nil {
			t.Fatalf("unexpected notice after selecting %s: %+v", version, got)
		}
	}
	p.Notice.AvailableVersion = "invalid"
	if got := p.noticeFor("1.0.0"); got != nil {
		t.Fatalf("notice accepted invalid candidate: %+v", got)
	}
}
