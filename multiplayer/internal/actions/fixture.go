//go:build pilotfixture

package actions

import (
	"net"
	"net/url"
	"os"
	"path/filepath"
)

// WithFixtureRemotes is available only in explicit pilot fixture builds. It
// permits tests in sibling packages to exercise real dispatch without sending
// a provider credential, issue mutation, or Git push to an external service.
func WithFixtureRemotes(cfg Config, githubURL, bareOrigin string) (Config, error) {
	u, err := url.Parse(githubURL)
	if err != nil || u.Scheme != "http" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.Port() == "" {
		return Config{}, ErrInvalid
	}
	ip := net.ParseIP(u.Hostname())
	if ip == nil || !ip.IsLoopback() {
		return Config{}, ErrInvalid
	}
	if !filepath.IsAbs(bareOrigin) {
		return Config{}, ErrInvalid
	}
	d, e := filepath.EvalSymlinks(bareOrigin)
	if e != nil || d != bareOrigin {
		return Config{}, ErrInvalid
	}
	for _, name := range []string{"objects", "refs"} {
		dir := filepath.Join(d, name)
		st, e := os.Lstat(dir)
		if e != nil || !st.IsDir() {
			return Config{}, ErrInvalid
		}
	}
	if _, e := smallFile(filepath.Join(d, "HEAD")); e != nil {
		return Config{}, ErrInvalid
	}
	cfg.testGitHub, cfg.testPushURL = githubURL, d
	return cfg, nil
}
