// Package release lists and downloads GitHub releases and checks what it
// downloads. It reads through the signed-in gh CLI when there is one, so a
// private repository works with the user's own login, and otherwise over
// HTTPS with GH_TOKEN or GITHUB_TOKEN, or anonymously.
package release

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Asset is one downloadable release file.
type Asset struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	URL  string `json:"url"` // API URL, served as octet-stream
}

// Release is one GitHub release.
type Release struct {
	Tag         string    `json:"tag_name"`
	Name        string    `json:"name"`
	Draft       bool      `json:"draft"`
	Prerelease  bool      `json:"prerelease"`
	PublishedAt time.Time `json:"published_at"`
	Assets      []Asset   `json:"assets"`
}

// Has reports whether the release carries every named asset.
func (r Release) Has(names ...string) bool {
	for _, n := range names {
		found := false
		for _, a := range r.Assets {
			found = found || a.Name == n
		}
		if !found {
			return false
		}
	}
	return true
}

// Source reads one repository's releases.
type Source struct {
	Repo string // owner/name
	// Mirror, when set, is a directory or base URL laid out as
	// releases.json plus TAG/ASSET. Tests and offline installs use it.
	Mirror string
	HTTP   *http.Client
}

var repoPattern = func(s string) bool {
	owner, name, ok := strings.Cut(s, "/")
	valid := func(p string) bool {
		return p != "" && p != "." && p != ".." && strings.Trim(p, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.") == ""
	}
	return ok && valid(owner) && valid(name)
}

func (s Source) client() *http.Client {
	if s.HTTP != nil {
		return s.HTTP
	}
	return &http.Client{Timeout: 5 * time.Minute}
}

// gh reports whether the gh CLI is installed and signed in.
func gh(ctx context.Context) bool {
	if _, err := exec.LookPath("gh"); err != nil {
		return false
	}
	return exec.CommandContext(ctx, "gh", "auth", "status", "--hostname", "github.com").Run() == nil
}

// List returns releases that are not drafts, newest first.
func (s Source) List(ctx context.Context) ([]Release, error) {
	if !repoPattern(s.Repo) && s.Mirror == "" {
		return nil, fmt.Errorf("invalid repository %q; use owner/name", s.Repo)
	}
	var data []byte
	var err error
	switch {
	case s.Mirror != "":
		data, err = s.mirrorRead(ctx, "releases.json")
	case gh(ctx):
		data, err = run(ctx, "gh", "api", "--paginate", "--slurp", "repos/"+s.Repo+"/releases?per_page=100")
		if err == nil {
			data, err = flatten(data)
		}
	default:
		data, err = s.httpGet(ctx, "https://api.github.com/repos/"+s.Repo+"/releases?per_page=100", "application/vnd.github+json")
	}
	if err != nil {
		return nil, err
	}
	var all []Release
	if err := json.Unmarshal(data, &all); err != nil {
		return nil, fmt.Errorf("read releases: %w", err)
	}
	out := all[:0]
	for _, r := range all {
		if !r.Draft {
			out = append(out, r)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].PublishedAt.After(out[j].PublishedAt) })
	return out, nil
}

func flatten(pages []byte) ([]byte, error) {
	var nested [][]json.RawMessage
	if err := json.Unmarshal(pages, &nested); err != nil {
		return nil, err
	}
	var flat []json.RawMessage
	for _, page := range nested {
		flat = append(flat, page...)
	}
	return json.Marshal(flat)
}

// Find returns the release with tag, or the newest one carrying every named
// asset when tag is "" or "latest".
func (s Source) Find(ctx context.Context, tag string, assets ...string) (Release, error) {
	all, err := s.List(ctx)
	if err != nil {
		return Release{}, err
	}
	for _, r := range all {
		if (tag == "" || tag == "latest") && r.Has(assets...) || r.Tag == tag {
			if !r.Has(assets...) {
				return Release{}, fmt.Errorf("release %s does not include %s", r.Tag, strings.Join(assets, ", "))
			}
			return r, nil
		}
	}
	if tag == "" || tag == "latest" {
		return Release{}, fmt.Errorf("no release of %s includes %s", s.Repo, strings.Join(assets, ", "))
	}
	return Release{}, fmt.Errorf("no release %s in %s", tag, s.Repo)
}

// Download saves one asset of r into dir and returns its path.
func (s Source) Download(ctx context.Context, r Release, name, dir string) (string, error) {
	if strings.ContainsAny(name, `/\`) || name == "" || name == "." || name == ".." {
		return "", fmt.Errorf("invalid asset name %q", name)
	}
	var asset *Asset
	for i := range r.Assets {
		if r.Assets[i].Name == name {
			asset = &r.Assets[i]
		}
	}
	if asset == nil {
		return "", fmt.Errorf("release %s has no asset %s", r.Tag, name)
	}
	dst := filepath.Join(dir, name)
	switch {
	case s.Mirror != "":
		data, err := s.mirrorRead(ctx, r.Tag+"/"+name)
		if err != nil {
			return "", err
		}
		return dst, os.WriteFile(dst, data, 0600)
	case gh(ctx):
		_, err := run(ctx, "gh", "release", "download", r.Tag, "-R", s.Repo, "-p", name, "-D", dir, "--clobber")
		return dst, err
	default:
		data, err := s.httpGet(ctx, asset.URL, "application/octet-stream")
		if err != nil {
			return "", err
		}
		return dst, os.WriteFile(dst, data, 0600)
	}
}

func (s Source) mirrorRead(ctx context.Context, rel string) ([]byte, error) {
	if strings.HasPrefix(s.Mirror, "http://") || strings.HasPrefix(s.Mirror, "https://") {
		return s.httpGet(ctx, strings.TrimSuffix(s.Mirror, "/")+"/"+rel, "")
	}
	return os.ReadFile(filepath.Join(s.Mirror, filepath.FromSlash(rel)))
}

func (s Source) httpGet(ctx context.Context, raw, accept string) ([]byte, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return nil, err
	}
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	if u.Host == "api.github.com" {
		req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
		for _, env := range []string{"GH_TOKEN", "GITHUB_TOKEN"} {
			if tok := os.Getenv(env); tok != "" {
				req.Header.Set("Authorization", "Bearer "+tok)
				break
			}
		}
	}
	resp, err := s.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound && u.Host == "api.github.com" {
		return nil, fmt.Errorf("GitHub answered 404 for %s; for a private repository, sign in with `gh auth login` or set GH_TOKEN", u.Path)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", raw, resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 512<<20))
}

func run(ctx context.Context, name string, args ...string) ([]byte, error) {
	var stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// VerifySum checks path against its line in a SHA256SUMS file.
func VerifySum(sums, path string) error {
	f, err := os.Open(sums)
	if err != nil {
		return err
	}
	defer f.Close()
	name := filepath.Base(path)
	want := ""
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		fields := strings.Fields(scan.Text())
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == name {
			if want != "" {
				return fmt.Errorf("SHA256SUMS lists %s twice", name)
			}
			want = fields[0]
		}
	}
	if err := scan.Err(); err != nil {
		return err
	}
	if want == "" {
		return fmt.Errorf("SHA256SUMS does not list %s", name)
	}
	got, err := Digest(path)
	if err != nil {
		return err
	}
	if !strings.EqualFold(got, want) {
		return fmt.Errorf("checksum mismatch for %s", name)
	}
	return nil
}

// Digest returns the hex SHA-256 of a file.
func Digest(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Attestation is the result of an attestation check.
type Attestation string

const (
	Verified Attestation = "verified"
	Absent   Attestation = "absent"
	// Unchecked means gh is not available to check.
	Unchecked Attestation = "unchecked"
)

// ErrAttestation means an attestation exists and does not match.
var ErrAttestation = errors.New("the build attestation does not match")

// VerifyAttestation checks a file's GitHub build attestation with gh.
// Attestations are optional: a missing one is Absent, not an error.
func VerifyAttestation(ctx context.Context, repo, path string) (Attestation, error) {
	if !gh(ctx) {
		return Unchecked, nil
	}
	var out bytes.Buffer
	cmd := exec.CommandContext(ctx, "gh", "attestation", "verify", path, "-R", repo)
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err == nil {
		return Verified, nil
	}
	text := strings.ToLower(out.String())
	if strings.Contains(text, "no attestations found") || strings.Contains(text, "not found") || strings.Contains(text, "404") {
		return Absent, nil
	}
	return "", fmt.Errorf("%w: %s", ErrAttestation, strings.TrimSpace(out.String()))
}
