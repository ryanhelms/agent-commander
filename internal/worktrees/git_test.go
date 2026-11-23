package worktrees

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func makeRepository(t *testing.T) (Git, Checkout) {
	t.Helper()
	ctx := context.Background()
	path := t.TempDir()
	for _, args := range [][]string{
		{"init", "-b", "main"}, {"config", "user.name", "Commander Test"}, {"config", "user.email", "qa@example.test"},
		{"remote", "add", "origin", "git@example.test:team/checkout-name.git"},
	} {
		if _, err := git(ctx, path, args...); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, path, "shared", "original\n")
	for _, args := range [][]string{{"add", "shared"}, {"commit", "-m", "base"}} {
		if _, err := git(ctx, path, args...); err != nil {
			t.Fatal(err)
		}
	}
	target, err := Source(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	return Git{userHome: t.TempDir()}, target
}

func writeFile(t *testing.T, path, file, data string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(path, file), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}

func makeChange(t *testing.T, repo Git, target Checkout, worker, file, contents string) string {
	t.Helper()
	ctx := context.Background()
	checkout, err := repo.Create(ctx, target, worker)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(repo.userHome, ".worktrees", "checkout-name", worker)
	if checkout.Path != want || checkout.Path == target.Path {
		t.Fatalf("worktree directory = %q, want %q", checkout.Path, want)
	}
	writeFile(t, checkout.Path, file, contents)
	rev, err := Commit(ctx, checkout, "change "+file, []string{file})
	if err != nil || VerifyRevision(ctx, checkout, rev) != nil {
		t.Fatalf("cannot verify worker revision %q: %v", rev, err)
	}
	return rev
}

func TestCombineTwoCodingWorktrees(t *testing.T) {
	repo, target := makeRepository(t)
	ctx := context.Background()
	first := makeChange(t, repo, target, "worker-one", "first", "one")
	second := makeChange(t, repo, target, "worker-two", "second", "two")
	if _, err := os.Stat(filepath.Join(target.Path, "first")); !os.IsNotExist(err) {
		t.Fatalf("worker edit leaked into coordinator checkout: %v", err)
	}
	test := []string{"sh", "-ec", "test \"$(cat first)$(cat second)\" = onetwo; echo combined-tests-passed"}
	candidate := repo.Prepare(ctx, target, "i-success", []string{first, second}, test)
	if candidate.Status != "tested" || candidate.Tests != "combined-tests-passed\n" {
		t.Fatalf("candidate was not tested with both changes: %+v", candidate)
	}
	result := Advance(ctx, target, candidate)
	live, err := Source(ctx, target.Path)
	if err != nil || result.Status != "integrated" || live.Base != candidate.Revision || live.Branch != "main" {
		t.Fatalf("target did not receive the tested revision: %+v, %+v, %v", result, live, err)
	}
}

func TestConflictFailedTestAndMovingTargetKeepCoordinatorBranch(t *testing.T) {
	repo, target := makeRepository(t)
	ctx := context.Background()
	first := makeChange(t, repo, target, "worker-one", "shared", "one")
	second := makeChange(t, repo, target, "worker-two", "shared", "two")
	conflict := repo.Prepare(ctx, target, "i-conflict", []string{first, second}, []string{"true"})
	if conflict.Status != "conflict" || conflict.Path == "" {
		t.Fatalf("merge conflict did not preserve its candidate: %+v", conflict)
	}
	failed := repo.Prepare(ctx, target, "i-test", []string{first}, []string{"sh", "-c", "echo failure; exit 3"})
	if failed.Status != "tests_failed" || failed.Tests != "failure\n" {
		t.Fatalf("failed combined test lost its outcome: %+v", failed)
	}
	candidate := repo.Prepare(ctx, target, "i-target", []string{first}, []string{"true"})
	if candidate.Status != "tested" {
		t.Fatalf("prepare move-target candidate: %+v", candidate)
	}
	writeFile(t, target.Path, "dirty", "mine")
	if got := Advance(ctx, target, candidate); got.Status != "target_dirty" {
		t.Fatalf("dirty target was not guarded: %+v", got)
	}
	if _, err := git(ctx, target.Path, "commit", "--allow-empty", "-m", "developer commit"); err != nil {
		t.Fatal(err)
	}
	if got := Advance(ctx, target, candidate); got.Status != "target_changed" {
		t.Fatalf("concurrent target commit was not guarded: %+v", got)
	}
}
