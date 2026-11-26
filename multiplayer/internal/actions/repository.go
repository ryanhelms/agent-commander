package actions

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var repositoryName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$`)
var oid = regexp.MustCompile(`^[0-9a-f]{40}$`)
var shareBranch = regexp.MustCompile(`^commander-share/[A-Za-z0-9][A-Za-z0-9_-]{0,126}$`)
var filename = regexp.MustCompile(`^[A-Za-z0-9_./ -]+$`)

type repo struct{ checkout, gitdir, common string }

func parseRepository(remote string) (string, error) {
	slug := ""
	if strings.HasPrefix(remote, "git@github.com:") {
		slug = strings.TrimPrefix(remote, "git@github.com:")
	} else {
		u, e := url.Parse(remote)
		if e != nil || u.Scheme != "https" || u.Host != "github.com" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" {
			return "", ErrInvalid
		}
		slug = strings.TrimPrefix(u.Path, "/")
	}
	slug = strings.TrimSuffix(slug, ".git")
	if !repositoryName.MatchString(slug) || strings.Contains(slug, "..") || path.Base(slug) == "." {
		return "", ErrInvalid
	}
	return strings.ToLower(slug), nil
}
func bareGit(ctx context.Context, dir string, env []string, body []byte, args ...string) (string, error) {
	limit, cancel := context.WithTimeout(ctx, 35*time.Second)
	defer cancel()
	git := "/usr/bin/git"
	cmd := exec.CommandContext(limit, git, append([]string{"--no-replace-objects", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "gc.auto=0", "-c", "core.commitGraph=false", "-c", "credential.helper=", "-c", "protocol.allow=never", "-c", "http.followRedirects=false", "-c", "commit.gpgSign=false", "-c", "push.gpgSign=false"}, args...)...)
	cmd.Dir = dir
	cmd.Env = append([]string{"PATH=/usr/bin:/bin", "HOME=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_NO_LAZY_FETCH=1", "GIT_NO_REPLACE_OBJECTS=1", "GIT_ATTR_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0", "GIT_LITERAL_PATHSPECS=1", "LC_ALL=C"}, env...)
	cmd.Stdin = bytes.NewReader(body)
	var out bytes.Buffer
	cmd.Stdout = &limitedOutput{dst: &out, remaining: 512 << 10}
	cmd.Stderr = io.Discard
	if e := cmd.Run(); e != nil {
		if limit.Err() != nil {
			return "", limit.Err()
		}
		return "", e
	}
	return strings.TrimSpace(out.String()), nil
}

type limitedOutput struct {
	dst       io.Writer
	remaining int
}

func (w *limitedOutput) Write(p []byte) (int, error) {
	if len(p) > w.remaining {
		return 0, errors.New("output limit exceeded")
	}
	w.remaining -= len(p)
	return w.dst.Write(p)
}

func smallFile(p string) (string, error) {
	st, e := os.Lstat(p)
	if e != nil || !st.Mode().IsRegular() || st.Size() > 8192 {
		return "", ErrInvalid
	}
	b, e := os.ReadFile(p)
	if e != nil {
		return "", ErrInvalid
	}
	return strings.TrimSpace(string(b)), nil
}

// Git follows directory symlinks below refs and logs. Keep both the reference
// and its reflog inside the enrolled repository before running a Git ref command.
func boundedGitPath(root, relative string) bool {
	p := root
	for _, part := range strings.Split(relative, "/") {
		p = filepath.Join(p, part)
		st, err := os.Lstat(p)
		if errors.Is(err, os.ErrNotExist) {
			return true
		}
		if err != nil || st.Mode()&os.ModeSymlink != 0 {
			return false
		}
	}
	return true
}

func inspectRepo(ctx context.Context, r Resource) (repo, string, error) {
	var info repo
	if !filepath.IsAbs(r.Target) || filepath.Clean(r.Target) != r.Target {
		return info, "", ErrInvalid
	}
	canonical, e := filepath.EvalSymlinks(r.Target)
	if e != nil || canonical != r.Target {
		return info, "", ErrInvalid
	}
	info.checkout = canonical
	dot := filepath.Join(canonical, ".git")
	marker, e := os.Lstat(dot)
	if e != nil {
		return info, "", ErrInvalid
	}
	if marker.IsDir() {
		info.gitdir = dot
		info.common = dot
	} else {
		pointer, e := smallFile(dot)
		if e != nil || !strings.HasPrefix(pointer, "gitdir: ") {
			return info, "", ErrInvalid
		}
		gd := strings.TrimPrefix(pointer, "gitdir: ")
		if !filepath.IsAbs(gd) {
			gd = filepath.Join(canonical, gd)
		}
		gd, e = filepath.EvalSymlinks(gd)
		if e != nil {
			return info, "", ErrInvalid
		}
		back, e := smallFile(filepath.Join(gd, "gitdir"))
		if e != nil || back != dot {
			return info, "", ErrInvalid
		}
		relative, e := smallFile(filepath.Join(gd, "commondir"))
		if e != nil || relative != "../.." || filepath.Base(filepath.Dir(gd)) != "worktrees" {
			return info, "", ErrInvalid
		}
		info.gitdir = gd
		info.common = filepath.Dir(filepath.Dir(gd))
	}
	for _, name := range []string{"objects", "refs"} {
		dir := filepath.Join(info.common, name)
		resolved, e := filepath.EvalSymlinks(dir)
		if e != nil || resolved != dir {
			return info, "", ErrInvalid
		}
	}
	if !boundedGitPath(info.common, "config") || !boundedGitPath(info.common, "packed-refs") || !boundedGitPath(info.gitdir, "HEAD") {
		return info, "", ErrInvalid
	}
	origin, e := bareGit(ctx, "/", nil, nil, "config", "--file", filepath.Join(info.common, "config"), "--no-includes", "--get-all", "remote.origin.url")
	if e != nil || strings.Contains(origin, "\n") {
		return info, "", ErrInvalid
	}
	slug, e := parseRepository(origin)
	return info, slug, e
}
func (r repo) local(ctx context.Context, args ...string) (string, error) {
	return bareGit(ctx, "/", nil, nil, append([]string{"--git-dir", r.gitdir}, args...)...)
}

// PrepareResource pins the checkout, GitHub identity, starting revision and dedicated
// collaboration branch at owner enrollment. A peer can never supply a checkout or ref.
func PrepareResource(ctx context.Context, r Resource) (Resource, error) {
	if !identifier.MatchString(r.ID) || len(r.Name) > 128 {
		return r, ErrInvalid
	}
	if r.Kind == "agent" {
		if !identifier.MatchString(r.Target) {
			return r, ErrInvalid
		}
		return r, nil
	}
	if r.Kind == "host" {
		return prepareHost(r)
	}
	if r.Kind != "repo" {
		return r, ErrInvalid
	}
	info, slug, e := inspectRepo(ctx, r)
	if e != nil {
		return r, e
	}
	if r.Repository != "" && !strings.EqualFold(r.Repository, slug) {
		return r, ErrInvalid
	}
	r.Repository = slug
	if r.Branch == "" {
		r.Branch = "commander-share/" + r.ID
	}
	if !shareBranch.MatchString(r.Branch) {
		return r, ErrInvalid
	}
	base, e := info.local(ctx, "rev-parse", "--verify", "HEAD^{commit}")
	if e != nil || !oid.MatchString(base) {
		return r, ErrInvalid
	}
	r.Base = base
	return r, nil
}
func verifyRepo(ctx context.Context, r Resource) (repo, error) {
	info, slug, e := inspectRepo(ctx, r)
	if e != nil || slug != r.Repository || !shareBranch.MatchString(r.Branch) || !oid.MatchString(r.Base) {
		return repo{}, ErrInvalid
	}
	return info, nil
}
func safePath(name string) bool {
	if len(name) == 0 || len(name) > 240 || path.Clean(name) != name || strings.HasPrefix(name, "/") || !filename.MatchString(name) {
		return false
	}
	for _, p := range strings.Split(strings.ToLower(name), "/") {
		if p == "." || p == ".." || strings.HasPrefix(p, ".git") || p == "codeowners" || strings.HasSuffix(p, ".") || strings.HasSuffix(p, " ") || strings.HasPrefix(p, "-") {
			return false
		}
	}
	return true
}

type changes struct {
	ExpectedHead string            `json:"expectedHead"`
	Message      string            `json:"message"`
	Files        map[string]string `json:"files"`
}

func repoAction(ctx context.Context, cfg Config, r Resource, action string, payload []byte) (json.RawMessage, error) {
	info, e := verifyRepo(ctx, r)
	if e != nil {
		return nil, e
	}
	ref := "refs/heads/" + r.Branch
	if !boundedGitPath(info.common, ref) || !boundedGitPath(info.common, "logs/"+ref) {
		return nil, ErrInvalid
	}
	if _, e := info.local(ctx, "symbolic-ref", "-q", ref); e == nil {
		return nil, ErrInvalid
	}
	head, e := info.local(ctx, "rev-parse", "--verify", ref+"^{commit}")
	exists := e == nil
	if exists {
		if !oid.MatchString(head) {
			return nil, ErrInvalid
		}
		if _, e := info.local(ctx, "merge-base", "--is-ancestor", r.Base, head); e != nil {
			return nil, ErrConflict
		}
	}
	if !exists {
		head = r.Base
	}
	if !oid.MatchString(head) {
		return nil, ErrInvalid
	}
	if action == "git.head" {
		if strict(payload, &struct{}{}) != nil {
			return nil, ErrInvalid
		}
		return answer(map[string]string{"status": "completed", "head": head, "base": r.Base, "branch": r.Branch})
	}
	if action != "git.commit" && action != "git.push" {
		return nil, ErrDenied
	}
	tmp, e := os.MkdirTemp(cfg.StateDir, ".git-action-*")
	if e != nil {
		return nil, ErrUnavailable
	}
	defer os.RemoveAll(tmp)
	bare := filepath.Join(tmp, "objects.git")
	if _, e = bareGit(ctx, tmp, nil, nil, "init", "--bare", "--template=", bare); e != nil {
		return nil, ErrUnavailable
	}
	env := []string{"GIT_OBJECT_DIRECTORY=" + filepath.Join(info.common, "objects"), "GIT_INDEX_FILE=" + filepath.Join(tmp, "index"), "GIT_AUTHOR_NAME=Commander collaboration", "GIT_COMMITTER_NAME=Commander collaboration", "GIT_AUTHOR_EMAIL=network@localhost", "GIT_COMMITTER_EMAIL=network@localhost"}
	cmd := func(input []byte, args ...string) (string, error) {
		return bareGit(ctx, tmp, env, input, append([]string{"--git-dir", bare}, args...)...)
	}
	if action == "git.push" {
		var in struct {
			ExpectedHead string `json:"expectedHead"`
		}
		if strict(payload, &in) != nil || !oid.MatchString(in.ExpectedHead) {
			return nil, ErrInvalid
		}
		if !exists {
			return nil, ErrConflict
		}
		if in.ExpectedHead != head {
			return nil, ErrStaleRevision
		}
		origin := "https://github.com/" + r.Repository + ".git"
		if cfg.testPushURL != "" {
			origin = cfg.testPushURL
			env = append(env, "GIT_ALLOW_PROTOCOL=file")
		} else {
			if cfg.GitHubToken == nil {
				return nil, ErrUnavailable
			}
			token, e := cfg.GitHubToken(ctx, r.ID, action)
			if e != nil || !safeToken(token) {
				return nil, ErrUnavailable
			}
			env = append(env, "GIT_ALLOW_PROTOCOL=https", "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=http."+origin+".extraHeader", "GIT_CONFIG_VALUE_0=Authorization: Basic "+base64.StdEncoding.EncodeToString([]byte("x-access-token:"+token)))
		}
		if _, e := cmd(nil, "push", "--no-verify", "--porcelain", "--", origin, head+":"+ref); e != nil {
			return nil, ErrUncertain
		}
		return answer(map[string]string{"status": "completed", "head": head, "branch": r.Branch})
	}
	var in changes
	if strict(payload, &in) != nil || !oid.MatchString(in.ExpectedHead) || len(in.Files) < 1 || len(in.Files) > 16 || strings.TrimSpace(in.Message) == "" || len(in.Message) > 1024 || strings.ContainsRune(in.Message, 0) {
		return nil, ErrInvalid
	}
	if in.ExpectedHead != head {
		return nil, ErrStaleRevision
	}
	checked, e := info.local(ctx, "worktree", "list", "--porcelain")
	if e != nil {
		return nil, ErrUnavailable
	}
	for _, line := range strings.Split(checked, "\n") {
		if line == "branch "+ref {
			return nil, ErrConflict
		}
	}
	if _, e = cmd(nil, "read-tree", head); e != nil {
		return nil, ErrUnavailable
	}
	paths := make([]string, 0, len(in.Files))
	for n, content := range in.Files {
		if !safePath(n) || len(content) > 64<<10 || strings.ContainsRune(content, 0) {
			return nil, ErrInvalid
		}
		paths = append(paths, n)
	}
	sort.Strings(paths)
	for _, file := range paths {
		for parent := path.Dir(file); parent != "."; parent = path.Dir(parent) {
			if _, overlap := in.Files[parent]; overlap {
				return nil, ErrInvalid
			}
		}
	}
	for _, name := range paths {
		mode := "100644"
		parts := strings.Split(name, "/")
		if len(parts) > 12 {
			return nil, ErrInvalid
		}
		for i := range parts {
			target := strings.Join(parts[:i+1], "/")
			entry, e := cmd(nil, "ls-tree", head, "--", target)
			if e != nil {
				return nil, ErrUnavailable
			}
			if entry == "" {
				continue
			}
			fields := strings.Fields(entry)
			if len(fields) < 3 {
				return nil, ErrInvalid
			}
			if i+1 < len(parts) {
				if fields[0] != "040000" {
					return nil, ErrInvalid
				}
			} else {
				if fields[0] != "100644" && fields[0] != "100755" {
					return nil, ErrInvalid
				}
				mode = fields[0]
			}
		}
		blob, e := cmd([]byte(in.Files[name]), "hash-object", "--no-filters", "-w", "--stdin")
		if e != nil || !oid.MatchString(blob) {
			return nil, ErrUnavailable
		}
		if _, e = cmd(nil, "update-index", "--add", "--cacheinfo", mode, blob, name); e != nil {
			return nil, ErrUnavailable
		}
	}
	tree, e := cmd(nil, "write-tree")
	if e != nil || !oid.MatchString(tree) {
		return nil, ErrUnavailable
	}
	commit, e := cmd([]byte(in.Message+"\n"), "commit-tree", tree, "-p", head)
	if e != nil || !oid.MatchString(commit) {
		return nil, ErrUnavailable
	}
	old := head
	if !exists {
		old = strings.Repeat("0", 40)
	}
	if _, e = info.local(ctx, "update-ref", "--no-deref", ref, commit, old); e != nil {
		if errors.Is(e, context.Canceled) || errors.Is(e, context.DeadlineExceeded) {
			return nil, ErrUncertain
		}
		current, readErr := info.local(ctx, "rev-parse", "--verify", ref+"^{commit}")
		if readErr != nil {
			return nil, ErrUncertain
		}
		if current != commit {
			if current != old {
				return nil, ErrStaleRevision
			}
			return nil, ErrConflict
		}
	}
	return answer(map[string]string{"status": "completed", "head": commit, "branch": r.Branch})
}
