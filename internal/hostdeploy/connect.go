package hostdeploy

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"agentcommander.network/hostkit/sshx"
	"agentcommander.network/hostkit/systemd"

	"agentcommander/internal/buildinfo"
	"agentcommander/internal/headless"
)

// Host is one headless server this Mac deployed to or connected to.
type Host struct {
	Destination string    `json:"destination"`
	Options     []string  `json:"options,omitempty"`
	Version     string    `json:"version,omitempty"`
	API         int       `json:"api,omitempty"`
	Updated     time.Time `json:"updated"`
}

// Target returns the SSH target for the host.
func (h Host) Target() sshx.Target {
	return sshx.Target{Destination: h.Destination, Options: h.Options}
}

// Registry is the list of headless hosts, kept in the local Commander state
// directory. The app reads it to show the hosts beside the local service.
type Registry struct{ Path string }

// NewRegistry uses headless-hosts.json in the state directory.
func NewRegistry(state string) Registry {
	return Registry{Path: filepath.Join(state, "headless-hosts.json")}
}

// List returns the hosts sorted by destination.
func (r Registry) List() ([]Host, error) {
	data, err := os.ReadFile(r.Path)
	if errors.Is(err, os.ErrNotExist) {
		return []Host{}, nil
	}
	if err != nil {
		return nil, err
	}
	var hosts []Host
	if err := json.Unmarshal(data, &hosts); err != nil {
		return nil, fmt.Errorf("read %s: %w", r.Path, err)
	}
	sort.Slice(hosts, func(i, j int) bool { return hosts[i].Destination < hosts[j].Destination })
	return hosts, nil
}

// Find returns the saved host for destination, or a host with no options.
func (r Registry) Find(destination string) Host {
	hosts, _ := r.List()
	for _, h := range hosts {
		if h.Destination == destination {
			return h
		}
	}
	return Host{Destination: destination}
}

// Save adds or replaces the host.
func (r Registry) Save(h Host) error {
	hosts, err := r.List()
	if err != nil {
		return err
	}
	h.Updated = time.Now().UTC().Truncate(time.Second)
	out := []Host{h}
	for _, existing := range hosts {
		if existing.Destination != h.Destination {
			out = append(out, existing)
		}
	}
	return r.write(out)
}

// Forget removes the host. A missing host is not an error.
func (r Registry) Forget(destination string) error {
	hosts, err := r.List()
	if err != nil {
		return err
	}
	out := hosts[:0]
	for _, h := range hosts {
		if h.Destination != destination {
			out = append(out, h)
		}
	}
	return r.write(out)
}

func (r Registry) write(hosts []Host) error {
	sort.Slice(hosts, func(i, j int) bool { return hosts[i].Destination < hosts[j].Destination })
	data, err := json.MarshalIndent(hosts, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(r.Path), 0700); err != nil {
		return err
	}
	return systemd.WriteFileAtomic(r.Path, append(data, '\n'), 0600)
}

// maxSocketPath is the longest Unix socket path macOS accepts, less one.
const maxSocketPath = 103

// LocalSocket is where the forwarded socket for destination appears. It is
// short enough for the macOS limit on socket paths.
func LocalSocket(state, destination string) string {
	sum := sha256.Sum256([]byte(destination))
	return filepath.Join(state, "hosts", hex.EncodeToString(sum[:6])+".sock")
}

// Event is one line connect writes: ready, disconnected or failed.
type Event struct {
	Event       string `json:"event"`
	Destination string `json:"destination"`
	Socket      string `json:"socket,omitempty"`
	Version     string `json:"version,omitempty"`
	API         int    `json:"api,omitempty"`
	Detail      string `json:"detail,omitempty"`
}

// Connect forwards the headless service's socket on the target to a local
// socket and keeps it forwarded until ctx ends, reconnecting after a drop.
// It writes one JSON Event per line to out. The app runs it as a child
// process and talks to the local socket as it talks to its own service.
func Connect(ctx context.Context, state string, t sshx.Target, out io.Writer) error {
	emit := func(e Event) {
		e.Destination = t.Destination
		data, _ := json.Marshal(e)
		fmt.Fprintf(out, "%s\n", data)
	}
	local := LocalSocket(state, t.Destination)
	if len(local) > maxSocketPath {
		return fmt.Errorf("the local socket path %s is longer than %d bytes; use a shorter AGENT_COMMANDER_HOME", local, maxSocketPath)
	}
	if err := os.MkdirAll(filepath.Dir(local), 0700); err != nil {
		return err
	}
	backoff := time.Second
	for attempt := 0; ; attempt++ {
		started := time.Now()
		err := forwardOnce(ctx, t, local, emit)
		if ctx.Err() != nil {
			_ = os.Remove(local)
			return nil
		}
		var incompatible *incompatibleError
		if errors.As(err, &incompatible) {
			emit(Event{Event: "failed", Detail: err.Error()})
			return err
		}
		emit(Event{Event: "disconnected", Detail: errText(err)})
		if time.Since(started) > time.Minute {
			backoff = time.Second
		}
		select {
		case <-ctx.Done():
			_ = os.Remove(local)
			return nil
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

type incompatibleError struct {
	version string
	api     int
}

func (e *incompatibleError) Error() string {
	return fmt.Sprintf("the server runs %s with API %d and this Commander uses API %d; deploy a matching release", e.version, e.api, buildinfo.APIVersion)
}

func errText(err error) string {
	if err == nil {
		return "the SSH connection ended"
	}
	return err.Error()
}

func forwardOnce(ctx context.Context, t sshx.Target, local string, emit func(Event)) error {
	status, err := Remote(ctx, t, "status")
	if err != nil {
		return err
	}
	if status.Socket == "" || !strings.HasPrefix(status.Socket, "/") {
		return errors.New("the server did not report its service socket; deploy a newer release")
	}
	if status.API != 0 && status.API != buildinfo.APIVersion {
		return &incompatibleError{status.Version, status.API}
	}
	_ = os.Remove(local)
	args := append([]string{"-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
		"-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
		"-o", "StreamLocalBindUnlink=yes", "-o", "StreamLocalBindMask=0177"}, t.Options...)
	// LocalForward with quoted paths, because -L splits on ':' and a
	// default Commander socket path contains a space.
	if strings.ContainsAny(local+status.Socket, "\"\n") {
		return errors.New("socket paths must not contain quotes or newlines")
	}
	args = append(args, "-o", `LocalForward="`+local+`" "`+status.Socket+`"`, "--", t.Destination)
	cmd := exec.CommandContext(ctx, "ssh", args...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	ready := time.NewTimer(20 * time.Second)
	defer ready.Stop()
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case err := <-exited:
			return fmt.Errorf("ssh: %v: %s", err, strings.TrimSpace(stderr.String()))
		case <-ready.C:
			_ = cmd.Process.Kill()
			<-exited
			return errors.New("the forwarded socket did not answer")
		case <-tick.C:
			hctx, cancel := context.WithTimeout(ctx, 2*time.Second)
			h, err := headless.ReadHealth(hctx, local)
			cancel()
			if err != nil {
				continue
			}
			emit(Event{Event: "ready", Socket: local, Version: h.Version, API: h.API})
			err = <-exited
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("ssh: %v: %s", err, strings.TrimSpace(stderr.String()))
		}
	}
}
