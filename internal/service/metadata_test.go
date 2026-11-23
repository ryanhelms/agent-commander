package service

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestCheckoutMetadataAndRunTitle(t *testing.T) {
	f := newFixture(t)
	dir := t.TempDir()
	git, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git unavailable")
	}
	runGit := func(args ...string) {
		t.Helper()
		cmd := exec.Command(git, args...)
		cmd.Dir = dir
		cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "GIT_CONFIG_GLOBAL=" + os.DevNull, "GIT_CONFIG_NOSYSTEM=1"}
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	runGit("init", "--initial-branch=feature/planning")
	t.Setenv("GIT_DIR", filepath.Join(f.dir, "unrelated"))
	task := "\n  Plan the rollout\nInclude a rollback plan."
	input := map[string]string{"title": " Rollout review ", "task": task, "path": dir, "client": "claude"}
	data := f.call("POST", "/v1/runs", "", input, 201, "start")
	var run Run
	if err := json.Unmarshal(data, &run); err != nil {
		t.Fatal(err)
	}
	c := f.launched()
	if run.Title != "Rollout review" || run.Task != task || run.Branch != "feature/planning" {
		t.Fatalf("unexpected metadata %+v", run)
	}
	checkTime := func(stamp string) {
		t.Helper()
		value, err := time.Parse(time.RFC3339, stamp)
		if err != nil || !strings.HasSuffix(stamp, "Z") || time.Since(value) > time.Minute {
			t.Fatalf("unexpected UTC timestamp %q", stamp)
		}
	}
	checkTime(run.CreatedAt)
	checkTime(run.Workers[0].CreatedAt)
	runGit("symbolic-ref", "HEAD", "refs/heads/next")
	w := f.delegate(c, "subtask")
	data = f.call("POST", "/v1/runs", "", input, 200, "start")
	if err := json.Unmarshal(data, &run); err != nil {
		t.Fatal(err)
	}
	for _, worker := range run.Workers {
		if worker.Client != "claude" || worker.Branch != "feature/planning" || worker.Worktree != dir || worker.Host != "localhost" {
			t.Fatalf("unexpected worker metadata %+v", worker)
		}
		checkTime(worker.CreatedAt)
	}
	if run.Workers[1].ID != w.ID || run.Branch != "feature/planning" {
		t.Fatal("lost original checkout metadata")
	}
	runGit("-c", "user.name=Test", "-c", "user.email=test@localhost", "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "test")
	runGit("checkout", "--detach", "HEAD")
	if b := checkoutBranch(context.Background(), dir); b != "" {
		t.Fatalf("detached checkout reported branch %q", b)
	}
}

func TestFallbackTitleAndMissingMetadata(t *testing.T) {
	f := newFixture(t)
	task := "\n  \n " + strings.Repeat("界", 80) + " \r\nPreserve these instructions."
	data := f.call("POST", "/v1/runs", "", map[string]string{"task": task, "path": f.dir}, 201, "")
	var run Run
	if err := json.Unmarshal(data, &run); err != nil {
		t.Fatal(err)
	}
	if run.Task != task || run.Title != strings.Repeat("界", 71)+"…" || utf8.RuneCountInString(run.Title) != 72 {
		t.Fatal("incorrect title fallback or modified task")
	}
	if strings.Contains(string(data), `"branch":`) {
		t.Fatal("non-Git directory supplied a branch")
	}
	_ = f.launched()
}

func TestLegacyRunMetadata(t *testing.T) {
	dir := t.TempDir()
	old := `{"runs":[{"id":"r-old","path":"/old","task":"\n  First task\nMore instructions","client":"claude","status":"completed","workers":[{"id":"w-old","run_id":"r-old","state":"completed"}],"requests":[]}],"tokens":{},"receipts":{}}`
	if err := os.WriteFile(filepath.Join(dir, "state.json"), []byte(old), 0600); err != nil {
		t.Fatal(err)
	}
	api, err := New(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	f := fixture{t: t, api: api}
	data := f.call("GET", "/v1/runs/r-old", "", nil, 200, "")
	var run Run
	if err := json.Unmarshal(data, &run); err != nil {
		t.Fatal(err)
	}
	if run.Title != "First task" || run.Workers[0].Client != "claude" {
		t.Fatal("lost known legacy metadata")
	}
	if strings.Contains(string(data), `"created_at":`) || strings.Contains(string(data), `"branch":`) {
		t.Fatal("supplied historical timestamp or branch without evidence")
	}
}
