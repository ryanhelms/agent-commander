package release

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func mirror(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	releases := []map[string]any{
		{"tag_name": "v2", "published_at": "2026-02-01T00:00:00Z", "prerelease": true, "assets": []map[string]any{{"name": "a.tar.gz"}}},
		{"tag_name": "v3", "published_at": "2026-03-01T00:00:00Z", "draft": true, "assets": []map[string]any{{"name": "a.tar.gz"}, {"name": "SUMS"}}},
		{"tag_name": "v1", "published_at": "2026-01-01T00:00:00Z", "assets": []map[string]any{{"name": "a.tar.gz"}, {"name": "SUMS"}}},
	}
	data, _ := json.Marshal(releases)
	if err := os.WriteFile(filepath.Join(dir, "releases.json"), data, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "v1"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "v1", "a.tar.gz"), []byte("archive"), 0644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestFindSkipsDraftsAndReleasesWithoutAssets(t *testing.T) {
	src := Source{Repo: "o/r", Mirror: mirror(t)}
	r, err := src.Find(context.Background(), "", "a.tar.gz", "SUMS")
	if err != nil || r.Tag != "v1" {
		t.Fatalf("latest with assets = %q, %v; want v1 (v3 is a draft, v2 lacks SUMS)", r.Tag, err)
	}
	if _, err := src.Find(context.Background(), "v2", "a.tar.gz", "SUMS"); err == nil {
		t.Fatal("expected v2 to be refused for its missing asset")
	}
	if _, err := src.Find(context.Background(), "v3", "a.tar.gz"); err == nil {
		t.Fatal("expected a draft to be invisible")
	}
	path, err := src.Download(context.Background(), r, "a.tar.gz", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "archive" {
		t.Fatalf("downloaded %q", data)
	}
	if _, err := src.Download(context.Background(), r, "../x", t.TempDir()); err == nil {
		t.Fatal("expected a path in an asset name to be refused")
	}
}

func TestVerifySum(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "a.tar.gz")
	if err := os.WriteFile(file, []byte("archive"), 0644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("archive"))
	sums := filepath.Join(dir, "SHA256SUMS")
	write := func(content string) {
		if err := os.WriteFile(sums, []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	write(hex.EncodeToString(sum[:]) + "  a.tar.gz\n")
	if err := VerifySum(sums, file); err != nil {
		t.Fatal(err)
	}
	write(hex.EncodeToString(sum[:]) + " *a.tar.gz\n")
	if err := VerifySum(sums, file); err != nil {
		t.Fatalf("binary-mode line refused: %v", err)
	}
	write("00  a.tar.gz\n")
	if err := VerifySum(sums, file); err == nil {
		t.Fatal("expected a mismatch")
	}
	write(hex.EncodeToString(sum[:]) + "  other\n")
	if err := VerifySum(sums, file); err == nil {
		t.Fatal("expected a missing entry to fail")
	}
}

func TestRepoPattern(t *testing.T) {
	for repo, ok := range map[string]bool{"o/r": true, "o-x/r.y": true, "o": false, "o/r/x": false, "../r": false, "o/": false} {
		if repoPattern(repo) != ok {
			t.Errorf("repoPattern(%q) != %v", repo, ok)
		}
	}
}
