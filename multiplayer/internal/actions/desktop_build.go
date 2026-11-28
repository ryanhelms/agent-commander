package actions

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	desktopBundleID  = "local.agentcommander.cockpit"
	buildProofWindow = 90 * time.Second
	buildClockSkew   = 10 * time.Second
	maxLaunchRecord  = 4096
	maxLaunchEntries = 256
)

var (
	buildNonce   = regexp.MustCompile(`^[0-9a-f]{32}$`)
	buildSHA     = regexp.MustCompile(`^[0-9a-f]{40}$`)
	launchUUID   = regexp.MustCompile(`^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)
	buildVersion = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,127}$`)
)

// DesktopBuild is the narrow view an app-build grant can expose. Its source
// has local process and socket identifiers which stay on the recipient device.
type DesktopBuild struct {
	Version  string    `json:"version"`
	Revision string    `json:"revision,omitempty"`
	Tree     string    `json:"tree"`
	LaunchID string    `json:"launchId"`
	Started  time.Time `json:"startedAt"`
}

// launchRecord is written to the locked SingleInstanceMembership descriptor
// by the running native application itself. It is not read from its current
// installation on disk, which could already hold a newer bundle.
type launchRecord struct {
	Schema          int    `json:"schema"`
	PID             int    `json:"pid"`
	StartedSeconds  int64  `json:"startedSeconds"`
	StartedMicros   int64  `json:"startedMicros"`
	LaunchID        string `json:"launchId"`
	Version         string `json:"version"`
	Revision        string `json:"revision,omitempty"`
	Tree            string `json:"tree"`
	Executable      string `json:"executable"`
	CommanderSocket string `json:"commanderSocket"`
}

func (r launchRecord) build() DesktopBuild {
	return DesktopBuild{
		Version: r.Version, Revision: r.Revision, Tree: r.Tree, LaunchID: r.LaunchID,
		Started: time.Unix(r.StartedSeconds, r.StartedMicros*1000).UTC(),
	}
}

func validDesktopBuild(b DesktopBuild, now time.Time) bool {
	if !buildVersion.MatchString(b.Version) || !launchUUID.MatchString(b.LaunchID) || !b.Started.After(time.Unix(0, 0)) || b.Started.After(now) {
		return false
	}
	if b.Revision != "" && !buildSHA.MatchString(b.Revision) {
		return false
	}
	switch b.Tree {
	case "unknown":
		return true
	case "clean", "dirty":
		return b.Revision != ""
	}
	return false
}

// DesktopBuildChallenge preserves only the public correlation fields of an
// encrypted outbound request, so its response can also be checked after retry.
type DesktopBuildChallenge struct {
	Nonce    string    `json:"nonce"`
	IssuedAt time.Time `json:"issuedAt"`
}

func ParseDesktopBuildChallenge(payload json.RawMessage) (DesktopBuildChallenge, error) {
	var challenge DesktopBuildChallenge
	if strict(payload, &challenge) != nil || !buildNonce.MatchString(challenge.Nonce) ||
		challenge.Nonce == strings.Repeat("0", 32) || challenge.IssuedAt.IsZero() {
		return DesktopBuildChallenge{}, ErrInvalid
	}
	return challenge, nil
}

// ExpiresAt is the latest time the challenge can produce fresh build evidence.
func (r DesktopBuildChallenge) ExpiresAt() time.Time {
	return r.IssuedAt.Add(buildProofWindow)
}

// FreshAt checks the proof window and the accepted clock skew.
func (r DesktopBuildChallenge) FreshAt(now time.Time) bool {
	return !now.After(r.ExpiresAt()) && !r.IssuedAt.After(now.Add(buildClockSkew))
}

type desktopBuildProof struct {
	DesktopBuild
	Nonce      string    `json:"nonce"`
	ObservedAt time.Time `json:"observedAt"`
}

// ProofState checks a response after the addressed envelope's signature and
// device have been verified. A good historical response is still expired.
func (r DesktopBuildChallenge) ProofState(response json.RawMessage, now time.Time) string {
	var proof desktopBuildProof
	if r.Nonce == "" || r.IssuedAt.IsZero() || strict(response, &proof) != nil ||
		proof.Nonce != r.Nonce || !r.FreshAt(proof.ObservedAt) || proof.ObservedAt.After(now.Add(buildClockSkew)) ||
		!validDesktopBuild(proof.DesktopBuild, proof.ObservedAt) {
		return "invalid"
	}
	if !r.FreshAt(now) {
		return "expired"
	}
	return "verified"
}

func desktopBuildAction(ctx context.Context, cfg Config, r Resource, req Request, _ string, _ bool) (json.RawMessage, error) {
	if !validCoordinatorInbox(r) {
		return nil, ErrDenied
	}

	in, err := ParseDesktopBuildChallenge(req.Payload)
	if err != nil {
		return nil, err
	}
	if !in.FreshAt(time.Now().UTC()) {
		return nil, ErrBuildRequestExpired
	}
	read := cfg.ReadDesktopBuild
	if read == nil {
		read = readDesktopBuild
	}
	build, err := read(ctx, cfg.CommanderSocket)
	if ctxErr := ctx.Err(); ctxErr != nil {
		return nil, ctxErr
	}
	if err != nil {
		return nil, ErrDesktopBuildUnavailable
	}
	now := time.Now().UTC()
	if !in.FreshAt(now) {
		return nil, ErrBuildRequestExpired
	}
	if !validDesktopBuild(build, now) {
		return nil, ErrDesktopBuildUnavailable
	}
	return answer(desktopBuildProof{DesktopBuild: build, Nonce: in.Nonce, ObservedAt: now})
}

// DesktopBuildSupported reports whether this device can verify native app
// evidence when the matching application is running.
func DesktopBuildSupported() bool { return desktopProcessHome() != "" }

func readDesktopBuild(ctx context.Context, commanderSocket string) (DesktopBuild, error) {
	home := desktopProcessHome()
	if home == "" {
		return DesktopBuild{}, ErrDesktopBuildUnavailable
	}
	support, err := filepath.EvalSymlinks(filepath.Join(home, "Library", "Application Support"))
	if err != nil || !safeDesktopDirectory(support, false) {
		return DesktopBuild{}, ErrDesktopBuildUnavailable
	}
	appDirectory := filepath.Join(support, desktopBundleID)
	if !safeDesktopDirectory(appDirectory, false) {
		return DesktopBuild{}, ErrDesktopBuildUnavailable
	}
	return readDesktopLaunchDirectory(ctx, filepath.Join(appDirectory, "Launch"), commanderSocket, desktopProcessMatches)
}

func safeDesktopDirectory(path string, private bool) bool {
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || !desktopFileOwner(info) {
		return false
	}
	mask := os.FileMode(0022)
	if private {
		mask = 0077
	}
	return info.Mode().Perm()&mask == 0
}

func desktopFileOwner(info os.FileInfo) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && st.Uid == uint32(os.Geteuid())
}

// The socket name distinguishes an app for an isolated or forwarded service
// from the device's configured local service. Resolve the directory aliases
// but require the configured socket name, even if the service is stopped.
func desktopSocketKey(socket string) string {
	if !filepath.IsAbs(socket) || filepath.Clean(socket) == "/" {
		return ""
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(socket))
	if err != nil {
		return ""
	}
	return filepath.Join(parent, filepath.Base(socket))
}

func readDesktopLaunchDirectory(ctx context.Context, directory, socket string, matchesProcess func(launchRecord) bool) (DesktopBuild, error) {
	socketKey := desktopSocketKey(socket)
	if socketKey == "" || !safeDesktopDirectory(directory, true) {
		return DesktopBuild{}, ErrDesktopBuildUnavailable
	}
	folder, err := os.Open(directory)
	if err != nil {
		return DesktopBuild{}, ErrDesktopBuildUnavailable
	}
	defer folder.Close()
	entries, err := folder.ReadDir(maxLaunchEntries + 1)
	if (err != nil && !errors.Is(err, io.EOF)) || len(entries) > maxLaunchEntries {
		return DesktopBuild{}, ErrDesktopBuildUnavailable
	}

	var found DesktopBuild
	for _, entry := range entries {
		if err = ctx.Err(); err != nil {
			return DesktopBuild{}, err
		}
		rawPID, ok := strings.CutSuffix(entry.Name(), ".lease")
		pid, parseErr := strconv.Atoi(rawPID)
		if !ok || parseErr != nil || pid <= 0 || strconv.Itoa(pid) != rawPID {
			continue
		}
		record, held, err := readDesktopLease(filepath.Join(directory, entry.Name()), pid, socketKey, matchesProcess)
		if err != nil {
			return DesktopBuild{}, err
		}
		if !held {
			continue
		}
		if found.LaunchID != "" {
			return DesktopBuild{}, ErrDesktopBuildUnavailable
		}
		found = record.build()
	}
	if found.LaunchID == "" {
		return DesktopBuild{}, ErrDesktopBuildUnavailable
	}
	return found, nil
}

func readDesktopLease(path string, pid int, socketKey string, matchesProcess func(launchRecord) bool) (launchRecord, bool, error) {
	var record launchRecord
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if errors.Is(err, os.ErrNotExist) {
		return record, false, nil
	}
	if err != nil {
		return record, false, ErrDesktopBuildUnavailable
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || !desktopFileOwner(info) || info.Mode().Perm()&0077 != 0 {
		return record, false, ErrDesktopBuildUnavailable
	}
	held, err := desktopLeaseHeld(file)
	if err != nil || !held {
		return record, false, err
	}

	raw, err := io.ReadAll(io.LimitReader(file, maxLaunchRecord+1))
	if err != nil || len(raw) > maxLaunchRecord || strict(raw, &record) != nil || record.Schema != 1 ||
		record.PID != pid || record.StartedSeconds <= 0 || record.StartedMicros < 0 || record.StartedMicros >= 1_000_000 ||
		!validDesktopBuild(record.build(), time.Now().UTC()) {
		return record, false, ErrDesktopBuildUnavailable
	}
	recordSocket := desktopSocketKey(record.CommanderSocket)
	if recordSocket == "" {
		return record, false, ErrDesktopBuildUnavailable
	}
	if recordSocket != socketKey {
		return record, false, nil
	}
	if !matchesProcess(record) {
		return record, false, ErrDesktopBuildUnavailable
	}
	// The app can exit while its metadata or OS identity is being read.
	held, err = desktopLeaseHeld(file)
	return record, held, err
}

func desktopLeaseHeld(file *os.File) (bool, error) {
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_SH|syscall.LOCK_NB)
		switch {
		case err == nil:
			return false, nil
		case errors.Is(err, syscall.EWOULDBLOCK):
			return true, nil
		case errors.Is(err, syscall.EINTR):
			continue
		default:
			return false, ErrDesktopBuildUnavailable
		}
	}
}
