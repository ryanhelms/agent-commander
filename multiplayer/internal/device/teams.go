package device

import (
	"context"
	"errors"
	"os/exec"
	"regexp"
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
	case "queue", "queue-add", "queue-merge":
		return a.queueVerb(ctx, verb, in)
	}
	return nil, errors.New("unknown operation")
}

// mergeBranch fetches nothing: the branch must already be in the checkout
// (pushed there through the owner's git.push grant). It tests, then merges.
func mergeBranch(ctx context.Context, q queueEntry) (string, string) {
	run := func(args ...string) (string, error) {
		c := exec.CommandContext(ctx, args[0], args[1:]...)
		c.Dir = q.Checkout
		out, e := c.CombinedOutput()
		return string(out), e
	}
	if out, e := run("git", "merge", "--no-ff", "--no-commit", q.Branch); e != nil {
		run("git", "merge", "--abort")
		return "conflict", out
	}
	if len(q.Test) > 0 {
		if out, e := run(q.Test...); e != nil {
			run("git", "merge", "--abort")
			return "failed", tail(out)
		}
	}
	if out, e := run("git", "commit", "--no-edit"); e != nil {
		return "failed", tail(out)
	}
	return "merged", ""
}

func tail(s string) string {
	if len(s) > 8192 {
		return s[len(s)-8192:]
	}
	return s
}
