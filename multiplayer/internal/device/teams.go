package device

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/identity"
)

// relayPrefixes are the team routes the tray may call through the generic relay verb.
var relayPrefixes = []string{"/v1/groups", "/v1/workspaces", "/v1/knowledge", "/v1/outcomes", "/v1/reputation", "/v1/endorsements", "/v1/directory", "/v1/admin/", "/v1/access-requests"}

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

func (a *Agent) queuePath() string { return filepath.Join(a.cfg.Dir, "merge-queue.json") }

func (a *Agent) loadQueue() []queueEntry {
	var q []queueEntry
	if b, e := os.ReadFile(a.queuePath()); e == nil {
		_ = json.Unmarshal(b, &q)
	}
	return q
}

func (a *Agent) teamVerb(ctx context.Context, s identity.Session, verb string, in input) (any, error) {
	switch verb {
	case "relay":
		method := strings.ToUpper(in.Method)
		if !slices.Contains([]string{"GET", "POST", "PUT", "DELETE"}, method) || !strings.HasPrefix(in.Path, "/v1/") || strings.Contains(in.Path, "..") ||
			!slices.ContainsFunc(relayPrefixes, func(p string) bool { return strings.HasPrefix(in.Path, p) }) {
			return nil, errors.New("that relay route is not available to the tray")
		}
		var body any
		if len(in.Body) > 0 {
			if !json.Valid(in.Body) {
				return nil, errors.New("invalid body")
			}
			body = in.Body
			if strings.HasPrefix(in.Path, "/v1/knowledge") {
				var item struct{ Kind, Content string }
				_ = json.Unmarshal(in.Body, &item)
				if LooksSecret(item.Content) {
					return nil, errors.New("this item seems to contain a secret; replace it with a ${NAME} placeholder before sharing")
				}
			}
		}
		var out any
		return out, a.remote(ctx, s, method, in.Path, body, &out)
	case "knowledge-share":
		return a.teamVerb(ctx, s, "relay", input{Method: "POST", Path: "/v1/knowledge", Body: in.Item})
	case "knowledge-install":
		var item struct{ Kind, Name, Content string }
		if json.Unmarshal(in.Item, &item) != nil || item.Name == "" {
			return nil, errors.New("invalid knowledge item")
		}
		name := filepath.Base(strings.ReplaceAll(item.Name, " ", "-"))
		switch item.Kind {
		case "skill":
			home, _ := os.UserHomeDir()
			dir := filepath.Join(home, ".claude", "skills", name)
			if e := os.MkdirAll(dir, 0755); e != nil {
				return nil, e
			}
			path := filepath.Join(dir, "SKILL.md")
			return map[string]string{"installed": path}, os.WriteFile(path, []byte(item.Content), 0644)
		default:
			if !filepath.IsAbs(in.Destination) {
				return nil, errors.New("choose where to save this item")
			}
			return map[string]string{"installed": in.Destination}, os.WriteFile(in.Destination, []byte(item.Content), 0600)
		}
	case "queue":
		return map[string]any{"queue": a.loadQueue()}, nil
	case "queue-add":
		if !filepath.IsAbs(in.Checkout) || in.Branch == "" || in.Workspace == "" {
			return nil, errors.New("queue-add needs a workspace, a branch and the absolute checkout path")
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		q := append(a.loadQueue(), queueEntry{Workspace: in.Workspace, Branch: in.Branch, Checkout: in.Checkout, Test: in.TestCommand, Added: time.Now().UTC(), State: "queued"})
		return map[string]any{"queue": q}, save(a.queuePath(), q)
	case "queue-merge":
		a.mu.Lock()
		q := a.loadQueue()
		a.mu.Unlock()
		for i := range q {
			if q[i].State != "queued" || (in.Workspace != "" && q[i].Workspace != in.Workspace) {
				continue
			}
			q[i].State, q[i].Output = mergeBranch(ctx, q[i])
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		return map[string]any{"queue": q}, save(a.queuePath(), q)
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
