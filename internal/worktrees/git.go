// Package worktrees creates isolated Git workspaces and prepares tested
// integration candidates for Commander.
package worktrees

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

type Checkout struct {
	Path   string `json:"path"`
	Branch string `json:"branch"`
	Base   string `json:"base"`
}

var idPattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}$`)

type Git struct{ userHome string }

func New() (Git, error) {
	userHome, err := os.UserHomeDir()
	return Git{userHome}, err
}

func git(ctx context.Context, cwd string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", cwd, "-c", "core.hooksPath=/dev/null"}, args...)...)
	cmd.Env = append(slices.DeleteFunc(os.Environ(), func(value string) bool {
		return strings.HasPrefix(value, "GIT_")
	}), "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true", "GIT_MERGE_AUTOEDIT=no")
	output, err := cmd.CombinedOutput()
	value := strings.TrimSpace(string(output))
	if err != nil {
		return value, fmt.Errorf("git %s: %w: %s", args[0], err, value)
	}
	return value, nil
}

// Source captures the branch and commit in the coordinator's checkout.
// Uncommitted contents are left in that checkout.
func Source(ctx context.Context, directory string) (Checkout, error) {
	root, err := git(ctx, directory, "rev-parse", "--show-toplevel")
	if err != nil {
		return Checkout{}, err
	}
	head, err := git(ctx, root, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		return Checkout{}, err
	}
	branch, _ := git(ctx, root, "symbolic-ref", "--quiet", "HEAD")
	if !strings.HasPrefix(branch, "refs/heads/") {
		branch = ""
	}
	return Checkout{Path: root, Branch: strings.TrimPrefix(branch, "refs/heads/"), Base: head}, nil
}

func (g Git) home(ctx context.Context, source, worktreeID string) (string, error) {
	if !idPattern.MatchString(worktreeID) {
		return "", errors.New("invalid worktree ID")
	}
	repository, err := repositoryName(ctx, source)
	if err != nil {
		return "", err
	}
	return filepath.Join(g.userHome, ".worktrees", repository, worktreeID), nil
}

func repositoryName(ctx context.Context, source string) (string, error) {
	remote, err := git(ctx, source, "remote", "get-url", "origin")
	if err == nil {
		if parsed, parseErr := url.Parse(remote); parseErr == nil && parsed.Scheme != "" && parsed.Path != "" {
			remote = parsed.Path
		} else if _, after, scp := strings.Cut(remote, ":"); scp && !strings.HasPrefix(remote, "/") {
			remote = after
		}
		name := strings.TrimSuffix(filepath.Base(strings.TrimRight(remote, "/")), ".git")
		if validRepositoryComponent(name) {
			return name, nil
		}
	}
	list, err := git(ctx, source, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		return "", err
	}
	first, _, _ := strings.Cut(list, "\x00")
	path, ok := strings.CutPrefix(first, "worktree ")
	name := filepath.Base(path)
	if !ok || !validRepositoryComponent(name) {
		return "", errors.New("could not determine the primary repository name")
	}
	return name, nil
}

func validRepositoryComponent(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsAny(name, "/\\\n\r\x00")
}

// Create provisions a named branch from the recorded commit under the worker ID.
func (g Git) Create(ctx context.Context, source Checkout, id string) (Checkout, error) {
	target, err := g.Plan(ctx, source, id)
	if err != nil {
		return Checkout{}, err
	}
	head, err := git(ctx, source.Path, "rev-parse", "--verify", source.Base+"^{commit}")
	if err != nil || head != source.Base {
		return Checkout{}, errors.New("coding worktree requires a recorded commit ID")
	}
	if err := os.MkdirAll(filepath.Dir(target.Path), 0700); err != nil {
		return Checkout{}, err
	}
	if _, err := git(ctx, source.Path, "worktree", "add", "-b", target.Branch, target.Path, source.Base); err != nil {
		return Checkout{}, err
	}
	return target, nil
}

func (g Git) Plan(ctx context.Context, source Checkout, id string) (Checkout, error) {
	path, err := g.home(ctx, source.Path, id)
	if err != nil {
		return Checkout{}, err
	}
	return Checkout{Path: path, Branch: "commander/" + id, Base: source.Base}, nil
}

// VerifyRevision confirms that the worker handed off a committed revision from
// its assigned branch, descending from the recorded base.
func VerifyRevision(ctx context.Context, assignment Checkout, revision string) error {
	current, err := Source(ctx, assignment.Path)
	if err != nil || current.Branch != assignment.Branch || current.Base != revision {
		return errors.New("handoff revision must be the assigned worktree branch's current commit")
	}
	if _, err := git(ctx, assignment.Path, "merge-base", "--is-ancestor", assignment.Base, revision); err != nil {
		return errors.New("handoff revision does not descend from the assignment's recorded base")
	}
	return nil
}

// Commit records explicitly selected files on the assigned worker branch.
func Commit(ctx context.Context, assignment Checkout, message string, files []string) (string, error) {
	current, err := Source(ctx, assignment.Path)
	if err != nil || VerifyRevision(ctx, assignment, current.Base) != nil {
		return "", errors.New("coding worktree is no longer on its assigned branch")
	}
	if len(files) == 0 || strings.TrimSpace(message) == "" {
		return "", errors.New("a commit message and changed paths are required")
	}
	for _, file := range files {
		clean := filepath.Clean(file)
		if filepath.IsAbs(file) || clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return "", errors.New("commit paths must name files within the coding worktree")
		}
	}
	if _, err := git(ctx, assignment.Path, append([]string{"--literal-pathspecs", "add", "--"}, files...)...); err != nil {
		return "", err
	}
	staged, err := git(ctx, assignment.Path, append([]string{"--literal-pathspecs", "diff", "--cached", "--name-only", "--"}, files...)...)
	if err != nil || staged == "" {
		return current.Base, err
	}
	if _, err := git(ctx, assignment.Path, append([]string{"--literal-pathspecs", "commit", "--no-gpg-sign", "--only", "-m", message, "--"}, files...)...); err != nil {
		return "", err
	}
	next, err := Source(ctx, assignment.Path)
	return next.Base, err
}
