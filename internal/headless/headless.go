// Package headless installs and runs the Commander service on a Linux server
// without the desktop app. It owns the server side: installed versions, the
// systemd user unit, health, rollback and prerequisite checks. The Mac side
// that deploys releases over SSH lives in package hostdeploy.
package headless

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"

	"agentcommander.network/hostkit/systemd"

	"agentcommander/internal/buildinfo"
	"agentcommander/internal/localapi"
)

// UnitName is the systemd user unit that runs the headless service.
const UnitName = "agent-commander.service"

// keepVersions is how many installed versions stay on disk, including the
// current and previous ones. Running workers may still use an old binary.
const keepVersions = 3

var versionName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$`)

// Layout locates the installed versions. Versions holds one directory per
// version; Current and Previous are symbolic links into it.
type Layout struct {
	Root, Versions, Current, Previous string
	// Bin is a convenience link to the current agentctl on the user's PATH.
	Bin string
	// Paths are the service's state directory and API socket.
	Paths localapi.Paths
	// SudoLinger lets Install enable linger with passwordless sudo.
	SudoLinger bool
}

// DefaultLayout uses ~/.local/share/agent-commander for versions and the
// normal Commander state directory for the service.
func DefaultLayout() (Layout, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Layout{}, err
	}
	data := os.Getenv("XDG_DATA_HOME")
	if data == "" {
		data = filepath.Join(home, ".local", "share")
	}
	paths, err := localapi.Config()
	if err != nil {
		return Layout{}, err
	}
	root := filepath.Join(data, "agent-commander")
	return Layout{Root: root, Versions: filepath.Join(root, "versions"),
		Current: filepath.Join(root, "current"), Previous: filepath.Join(root, "previous"),
		Bin: filepath.Join(home, ".local", "bin", "agentctl"), Paths: paths}, nil
}

// Step is one checked action. Required steps that fail stop the operation.
type Step struct {
	Step     string `json:"step"`
	OK       bool   `json:"ok"`
	Required bool   `json:"required,omitempty"`
	Detail   string `json:"detail,omitempty"`
	Fix      string `json:"fix,omitempty"`
}

// Report is the result of install, rollback and status.
type Report struct {
	Version  string   `json:"version,omitempty"`
	Previous string   `json:"previous,omitempty"`
	API      int      `json:"api,omitempty"`
	State    string   `json:"state,omitempty"`
	Linger   bool     `json:"linger"`
	Socket   string   `json:"socket,omitempty"`
	Versions []string `json:"versions,omitempty"`
	Steps    []Step   `json:"steps,omitempty"`
	OK       bool     `json:"ok"`
}

func (r *Report) add(s Step) bool {
	r.Steps = append(r.Steps, s)
	return s.OK || !s.Required
}

// Health is the service's /v1/health answer.
type Health struct {
	Status  string `json:"status"`
	API     int    `json:"api"`
	Version string `json:"version"`
}

// ReadHealth asks the service on socket for its health.
func ReadHealth(ctx context.Context, socket string) (Health, error) {
	body, err := localapi.New(socket, "").Do(ctx, "GET", "/v1/health", nil)
	if err != nil {
		return Health{}, err
	}
	var h Health
	if err := json.Unmarshal(body, &h); err != nil {
		return Health{}, fmt.Errorf("read service health: %w", err)
	}
	return h, nil
}

// WaitHealthy waits until the service reports version, or the timeout ends.
func WaitHealthy(ctx context.Context, socket, version string, timeout time.Duration) (Health, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	var last error
	for {
		h, err := ReadHealth(ctx, socket)
		if err == nil && h.Status == "ok" && (version == "" || h.Version == version) {
			return h, nil
		}
		if err == nil {
			err = fmt.Errorf("the service reports version %q, not %q", h.Version, version)
		}
		last = err
		select {
		case <-ctx.Done():
			return Health{}, fmt.Errorf("the service did not become healthy: %w", last)
		case <-tick.C:
		}
	}
}

// Link reads a version link. A missing link returns "".
func (l Layout) Link(path string) (string, error) {
	target, err := os.Readlink(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return filepath.Base(target), nil
}

func (l Layout) setLink(path, version string) error {
	if version == "" {
		err := os.Remove(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	tmp := path + ".new"
	_ = os.Remove(tmp)
	if err := os.Symlink(filepath.Join("versions", version), tmp); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Installed lists installed versions, newest first.
func (l Layout) Installed() ([]string, error) {
	entries, err := os.ReadDir(l.Versions)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	type item struct {
		name string
		mod  time.Time
	}
	var items []item
	for _, e := range entries {
		if info, err := e.Info(); err == nil && e.IsDir() {
			items = append(items, item{e.Name(), info.ModTime()})
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].mod.After(items[j].mod) })
	names := make([]string, len(items))
	for i, it := range items {
		names[i] = it.name
	}
	return names, nil
}

// Executable returns the agentctl path for an installed version.
func (l Layout) Executable(version string) string {
	return filepath.Join(l.Versions, version, "agentctl")
}

// Stage copies the binary at source into the versions directory under
// version and returns that version. A local build is named after its digest
// so two different dev builds never share a directory.
func (l Layout) Stage(source, version string) (string, error) {
	in, err := os.Open(source)
	if err != nil {
		return "", err
	}
	defer in.Close()
	sum := sha256.New()
	if _, err := io.Copy(sum, in); err != nil {
		return "", err
	}
	digest := hex.EncodeToString(sum.Sum(nil))
	if !buildinfo.IsRelease(version) {
		version = "dev-" + digest[:12]
	}
	if !versionName.MatchString(version) {
		return "", fmt.Errorf("invalid version name %q", version)
	}
	dir := filepath.Join(l.Versions, version)
	target := filepath.Join(dir, "agentctl")
	if existing, err := fileDigest(target); err == nil {
		if existing == digest {
			return version, nil
		}
		return "", fmt.Errorf("version %s is already installed with different contents", version)
	}
	if err := os.MkdirAll(l.Versions, 0700); err != nil {
		return "", err
	}
	tmp, err := os.MkdirTemp(l.Versions, ".stage-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmp)
	if _, err := in.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	out, err := os.OpenFile(filepath.Join(tmp, "agentctl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0755)
	if err != nil {
		return "", err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return "", err
	}
	if err := out.Close(); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, "VERSION"), []byte(version+"\n"), 0644); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, dir); err != nil {
		return "", err
	}
	return version, nil
}

func fileDigest(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	sum := sha256.New()
	if _, err := io.Copy(sum, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

// ServicePath is the PATH the unit runs with: ~/.local/bin, where the Claude
// installer and the agentctl link live, followed by the installing shell's
// PATH. Noninteractive SSH sessions often leave ~/.local/bin out.
func ServicePath() string {
	home, _ := os.UserHomeDir()
	parts := []string{filepath.Join(home, ".local", "bin")}
	seen := map[string]bool{parts[0]: true}
	for _, p := range filepath.SplitList(os.Getenv("PATH")) {
		if p != "" && !seen[p] {
			seen[p] = true
			parts = append(parts, p)
		}
	}
	return strings.Join(parts, string(os.PathListSeparator))
}

// Unit describes the headless service. KillMode=process stops only agentctl
// on a restart, so tmux sessions and running workers survive an upgrade.
func (l Layout) Unit() systemd.Unit {
	return systemd.Unit{Name: UnitName, Description: "Agent Commander headless service",
		Exec:        []string{filepath.Join(l.Current, "agentctl"), "serve"},
		Environment: []string{"PATH=" + ServicePath(), "AGENT_COMMANDER_HOME=" + l.Paths.State, "AGENT_COMMANDER_SOCKET=" + l.Paths.Socket},
		Restart:     "on-failure", KillMode: "process", TimeoutStopSec: 30}
}

// Options control Install.
type Options struct {
	// Source is the agentctl binary to install, and Version its release tag.
	Source, Version string
	// Timeout bounds the wait for the new version to become healthy.
	Timeout time.Duration
}

// Install stages the binary, makes it current, writes and restarts the
// unit, and waits for the new version to report healthy. When it does not,
// Install switches back to the previous version and restarts that.
func (l Layout) Install(ctx context.Context, o Options) Report {
	var r Report
	if runtime.GOOS != "linux" {
		r.add(Step{Step: "platform", Required: true, Detail: "headless install runs on Linux; this is " + runtime.GOOS})
		return r
	}
	if o.Timeout == 0 {
		o.Timeout = 30 * time.Second
	}
	version, err := l.Stage(o.Source, o.Version)
	if !r.add(stepFrom("stage", err, version, true)) {
		return r
	}
	r.Version = version
	previous, err := l.Link(l.Current)
	if !r.add(stepFrom("read current version", err, previous, true)) {
		return r
	}
	earlier, _ := l.Link(l.Previous)
	if previous == version {
		previous = earlier
	}
	r.Previous = previous
	if err := l.activate(version, previous); !r.add(stepFrom("activate", err, version, true)) {
		return r
	}
	r.add(l.linkBin())
	r.add(l.ensureLinger())
	if err := systemd.Install(l.Unit(), true); !r.add(stepFrom("start unit", err, UnitName, true)) {
		l.revert(ctx, &r, previous, earlier)
		return r
	}
	h, err := WaitHealthy(ctx, l.Paths.Socket, expected(version, o.Version), o.Timeout)
	if !r.add(stepFrom("health", err, fmt.Sprintf("version %s, API %d", h.Version, h.API), true)) {
		l.revert(ctx, &r, previous, earlier)
		return r
	}
	r.API = h.API
	r.State = "active"
	r.Linger, _ = systemd.Linger(currentUser())
	r.add(stepFrom("prune", l.prune(), "", false))
	r.Versions, _ = l.Installed()
	r.OK = true
	return r
}

// Rollback switches back to the previous version and restarts the service.
func (l Layout) Rollback(ctx context.Context, timeout time.Duration) Report {
	var r Report
	current, err := l.Link(l.Current)
	if !r.add(stepFrom("read current version", err, current, true)) {
		return r
	}
	previous, err := l.Link(l.Previous)
	if err == nil && previous == "" {
		err = errors.New("no previous version is installed")
	}
	if !r.add(stepFrom("read previous version", err, previous, true)) {
		return r
	}
	if err := l.activate(previous, current); !r.add(stepFrom("activate", err, previous, true)) {
		return r
	}
	r.Version, r.Previous = previous, current
	if err := systemd.Install(l.Unit(), true); !r.add(stepFrom("restart unit", err, UnitName, true)) {
		return r
	}
	if timeout == 0 {
		timeout = 30 * time.Second
	}
	h, err := WaitHealthy(ctx, l.Paths.Socket, expected(previous, ""), timeout)
	if !r.add(stepFrom("health", err, fmt.Sprintf("version %s, API %d", h.Version, h.API), true)) {
		return r
	}
	r.API, r.State, r.OK = h.API, "active", true
	return r
}

// Status reports the installed versions, the unit state and the service's
// health.
func (l Layout) Status(ctx context.Context) Report {
	var r Report
	r.Version, _ = l.Link(l.Current)
	r.Previous, _ = l.Link(l.Previous)
	r.Versions, _ = l.Installed()
	r.Linger, _ = systemd.Linger(currentUser())
	r.Socket = l.Paths.Socket
	state, err := systemd.State(UnitName, false)
	r.State = state
	r.add(stepFrom("unit", err, state, true))
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	h, err := ReadHealth(ctx, l.Paths.Socket)
	r.add(stepFrom("health", err, fmt.Sprintf("version %s, API %d", h.Version, h.API), true))
	r.API = h.API
	r.OK = err == nil && state == "active"
	return r
}

// Remove stops and removes the unit. Installed versions and the service's
// state directory stay in place.
func (l Layout) Remove() Report {
	var r Report
	err := systemd.Uninstall(UnitName, false)
	r.add(stepFrom("remove unit", err, UnitName, true))
	r.OK = err == nil
	return r
}

func (l Layout) activate(version, previous string) error {
	if _, err := os.Stat(l.Executable(version)); err != nil {
		return err
	}
	if err := l.setLink(l.Previous, previous); err != nil {
		return err
	}
	return l.setLink(l.Current, version)
}

// revert returns to previous and restores earlier as its fallback.
func (l Layout) revert(ctx context.Context, r *Report, previous, earlier string) {
	failed := r.Version
	if previous == "" {
		r.add(Step{Step: "roll back", Detail: "no previous version to return to", Fix: "run `journalctl --user -u " + UnitName + "` on the server"})
		return
	}
	if earlier == previous {
		earlier = ""
	}
	err := l.activate(previous, earlier)
	if err == nil {
		err = systemd.Install(l.Unit(), true)
	}
	if err == nil {
		_, err = WaitHealthy(ctx, l.Paths.Socket, expected(previous, ""), 30*time.Second)
	}
	r.add(stepFrom("roll back", err, "returned to "+previous+" after "+failed+" failed", false))
	if err == nil {
		r.Version, r.Previous = previous, earlier
	}
}

func (l Layout) linkBin() Step {
	target := filepath.Join(l.Current, "agentctl")
	if info, err := os.Lstat(l.Bin); err == nil && info.Mode()&os.ModeSymlink == 0 {
		return Step{Step: "link agentctl", Detail: l.Bin + " exists and is not a link; leaving it"}
	}
	if err := os.MkdirAll(filepath.Dir(l.Bin), 0755); err != nil {
		return stepFrom("link agentctl", err, "", false)
	}
	tmp := l.Bin + ".new"
	_ = os.Remove(tmp)
	err := os.Symlink(target, tmp)
	if err == nil {
		err = os.Rename(tmp, l.Bin)
	}
	return stepFrom("link agentctl", err, l.Bin, false)
}

// prune removes the oldest versions beyond keepVersions, never the current
// or previous one.
func (l Layout) prune() error {
	names, err := l.Installed()
	if err != nil {
		return err
	}
	current, _ := l.Link(l.Current)
	previous, _ := l.Link(l.Previous)
	kept := 0
	for _, name := range names {
		if name == current || name == previous || kept < keepVersions-2 {
			if name != current && name != previous {
				kept++
			}
			continue
		}
		if err := os.RemoveAll(filepath.Join(l.Versions, name)); err != nil {
			return err
		}
	}
	return nil
}

// expected is the version a healthy service must report. A release reports
// its tag. A local build is staged under its digest but reports its VCS
// revision, so only the build that installs it knows what it reports.
func expected(staged, reported string) string {
	if buildinfo.IsRelease(staged) {
		return staged
	}
	return reported
}

func stepFrom(name string, err error, detail string, required bool) Step {
	if err != nil {
		return Step{Step: name, Required: required, Detail: err.Error()}
	}
	return Step{Step: name, OK: true, Required: required, Detail: detail}
}

func currentUser() string {
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	return fmt.Sprint(os.Getuid())
}
