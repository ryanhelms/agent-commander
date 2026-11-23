package worktrees

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type Candidate struct {
	Path     string `json:"path,omitempty"`
	Revision string `json:"revision,omitempty"`
	Status   string `json:"status"`
	Detail   string `json:"detail,omitempty"`
	Tests    string `json:"tests,omitempty"`
}

// Prepare constructs and tests a candidate without touching the coordinator's
// checkout. Its worktree is retained for inspection when preparation fails.
func (g Git) Prepare(ctx context.Context, target Checkout, id string, revisions, test []string) Candidate {
	fail := func(status string, err error) Candidate { return Candidate{Status: status, Detail: err.Error()} }
	if len(test) == 0 || strings.TrimSpace(test[0]) == "" {
		return fail("missing_tests", errors.New("set a combined test command for this integration"))
	}
	if len(revisions) == 0 || target.Branch == "" {
		return fail("invalid_candidate", errors.New("integration requires a target branch and worker revisions"))
	}
	for _, revision := range append([]string{target.Base}, revisions...) {
		value, err := git(ctx, target.Path, "rev-parse", "--verify", "--end-of-options", revision+"^{commit}")
		if err != nil || value != revision {
			return fail("invalid_candidate", errors.New("integration revisions must be recorded commit IDs in the coordinator repository"))
		}
	}
	path, err := g.home(ctx, target.Path, id)
	if err != nil {
		return fail("preparation_failed", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fail("preparation_failed", err)
	}
	if _, err := git(ctx, target.Path, "worktree", "add", "--detach", path, target.Base); err != nil {
		return fail("preparation_failed", err)
	}
	candidate := Candidate{Path: path}
	for _, rev := range revisions {
		if _, err := git(ctx, path, "merge", "--no-edit", "--no-ff", "--no-gpg-sign", rev); err != nil {
			candidate.Status, candidate.Detail = "merge_failed", err.Error()
			if paths, _ := git(ctx, path, "diff", "--name-only", "--diff-filter=U"); paths != "" {
				candidate.Status = "conflict"
			}
			return candidate
		}
	}
	snapshot, err := Source(ctx, path)
	if err != nil {
		candidate.Status, candidate.Detail = "preparation_failed", err.Error()
		return candidate
	}
	candidate.Revision = snapshot.Base
	cmd := exec.CommandContext(ctx, test[0], test[1:]...)
	cmd.Dir = path
	log := &testLog{}
	cmd.Stdout, cmd.Stderr = log, log
	err = cmd.Run()
	candidate.Tests = string(log.data)
	if err != nil {
		candidate.Status, candidate.Detail = "tests_failed", err.Error()
		return candidate
	}
	head, err := Source(ctx, path)
	if err != nil || head.Base != candidate.Revision || head.Branch != "" {
		candidate.Status, candidate.Detail = "candidate_changed", "tests moved the candidate checkout away from its recorded revision"
		return candidate
	}
	candidate.Status = "tested"
	return candidate
}

// Advance checks the coordinator's live checkout after tests complete. Git's
// fast-forward operation protects tracked changes and rejects divergent refs.
func Advance(ctx context.Context, target Checkout, candidate Candidate) Candidate {
	if candidate.Status != "tested" {
		return candidate
	}
	live, err := Source(ctx, target.Path)
	if err != nil || live != target {
		candidate.Status, candidate.Detail = "target_changed", "the coordinator changed branch or revision while the candidate was being prepared"
		return candidate
	}
	status, err := git(ctx, target.Path, "status", "--porcelain=v1", "--untracked-files=normal")
	if err != nil || status != "" {
		candidate.Status, candidate.Detail = "target_dirty", "the coordinator checkout has uncommitted changes or its status is unavailable"
		return candidate
	}
	if _, err := git(ctx, target.Path, "merge", "--ff-only", "--no-edit", "--no-autostash", candidate.Revision); err != nil {
		candidate.Status, candidate.Detail = "target_changed", fmt.Sprintf("could not advance the tested revision: %v", err)
		return candidate
	}
	candidate.Status = "integrated"
	return candidate
}

type testLog struct{ data []byte }

func (l *testLog) Write(data []byte) (int, error) {
	const maximum = 64 << 10
	if room := maximum - len(l.data); room > 0 {
		l.data = append(l.data, data[:min(room, len(data))]...)
	}
	return len(data), nil
}
