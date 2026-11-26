package device

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/identity"
)

var secretPattern = regexp.MustCompile(`(?i)(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9-]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*["']?[^\s"'${}]{6,})`)

// LooksSecret reports whether shared content appears to carry a credential.
func LooksSecret(content string) bool { return secretPattern.MatchString(content) }

type queueEntry struct {
	Workspace string    `json:"workspace"`
	Branch    string    `json:"branch"`
	Checkout  string    `json:"checkout"`
	Test      []string  `json:"test"`
	Added     time.Time `json:"added"`
	State     string    `json:"state"`
	Output    string    `json:"output,omitempty"`
}

func (a *Agent) teamVerb(ctx context.Context, s identity.Session, verb string, in input) (any, error) {
	switch verb {
	case "relay":
		return a.teamRelay(ctx, s, in.Method, in.Path, in.Body)
	case "knowledge-share":
		method, path := "POST", "/v1/knowledge"
		if in.ID != "" {
			id, err := segment(in.ID)
			if err != nil {
				return nil, err
			}
			method, path = "PUT", path+"/"+id
		}
		return a.teamRelay(ctx, s, method, path, in.Item)
	case "knowledge-install":
		return installKnowledge(ctx, in, knowledgePassword)
	case "queue", "queue-add", "queue-merge", "queue-remove":
		return a.queueVerb(ctx, s, verb, in)
	}
	return nil, errors.New("unknown operation")
}

func runInCheckout(ctx context.Context, dir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		if message := strings.TrimSpace(tail(string(out))); message != "" {
			return "", fmt.Errorf("%s: %w", message, err)
		}
		return "", fmt.Errorf("%s: %w", args[0], err)
	}
	return string(out), nil
}

func checkQueueCheckout(ctx context.Context, dir string) error {
	if !filepath.IsAbs(dir) {
		return fmt.Errorf("checkout %q must be an absolute path", dir)
	}
	out, err := runInCheckout(ctx, dir, "git", "rev-parse", "--is-inside-work-tree")
	if err != nil {
		return fmt.Errorf("checkout %s is not a Git work tree: %w", dir, err)
	}
	if strings.TrimSpace(out) != "true" {
		return fmt.Errorf("checkout %s is not a Git work tree", dir)
	}
	return nil
}

// mergeBranch fetches nothing. The relay supplies the base,
// including for entries written before the queue checked workspace metadata.
func mergeBranch(ctx context.Context, q queueEntry, base string) (string, string) {
	if err := checkQueueCheckout(ctx, q.Checkout); err != nil {
		return "failed", err.Error()
	}
	git := func(args ...string) (string, error) {
		return runInCheckout(ctx, q.Checkout, append([]string{"git"}, args...)...)
	}
	changes, err := git("status", "--porcelain", "--untracked-files=no")
	if err != nil {
		return "failed", err.Error()
	}
	if changes != "" {
		return "failed", "the checkout has uncommitted changes"
	}
	// A branch shorthand such as @{-1} or "-" must not select another base.
	if name, err := git("check-ref-format", "--branch", base); err != nil || strings.TrimSpace(name) != base {
		return "failed", fmt.Sprintf("invalid workspace base branch %q", base)
	}
	if _, err := git("switch", "--no-guess", "--", base); err != nil {
		return "failed", fmt.Sprintf("cannot switch to workspace base %s: %v", base, err)
	}
	// git accepts shorthand such as @ in branch arguments. Verify the actual
	// destination before writing to the checkout.
	if head, err := git("symbolic-ref", "HEAD"); err != nil || strings.TrimSpace(head) != "refs/heads/"+base {
		return "failed", fmt.Sprintf("checkout is not on workspace base branch %s", base)
	}
	abort := func() {
		// A disconnected tray must not leave its merge in progress.
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		_, _ = runInCheckout(cleanup, q.Checkout, "git", "merge", "--abort")
	}
	if _, err := git("merge", "--no-ff", "--no-commit", "--", q.Branch); err != nil {
		// switch above already refused any pre-existing in-progress merge.
		defer abort()
		if unmerged, _ := git("ls-files", "--unmerged", "--", ":/"); unmerged != "" {
			return "conflict", err.Error()
		}
		return "failed", err.Error()
	}
	_, mergeErr := git("rev-parse", "--verify", "--quiet", "MERGE_HEAD")
	var exit *exec.ExitError
	if mergeErr != nil && !(errors.As(mergeErr, &exit) && exit.ExitCode() == 1) {
		abort()
		return "failed", mergeErr.Error()
	}
	if len(q.Test) > 0 {
		if _, err := runInCheckout(ctx, q.Checkout, q.Test...); err != nil {
			if mergeErr == nil {
				abort()
			}
			return "failed", err.Error()
		}
	}
	if mergeErr == nil { // An already-integrated branch has no merge to commit.
		if _, err := git("commit", "--no-edit"); err != nil {
			abort()
			return "failed", err.Error()
		}
	}
	return "merged", ""
}

func tail(s string) string {
	if len(s) > 8192 {
		return s[len(s)-8192:]
	}
	return s
}
