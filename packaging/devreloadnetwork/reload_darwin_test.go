//go:build darwin && cgo

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	// Keep the real process arguments for the kernel role check, while
	// directing the Go test binary to the isolated listener in the child.
	if os.Getenv("AC_RELOAD_TEST_SOCKET") != "" && len(os.Args) > 1 && !strings.HasPrefix(os.Args[1], "-test.") {
		os.Args = []string{os.Args[0], "-test.run=^TestReloadFixtureProcess$"}
	}
	os.Exit(m.Run())
}

// A second copy of the test executable stands in for the network helper. No
// fixture uses the normal socket, a relay, or the Keychain.
func TestReloadFixtureProcess(t *testing.T) {
	socket := os.Getenv("AC_RELOAD_TEST_SOCKET")
	if socket == "" {
		return
	}
	mode := os.Getenv("AC_RELOAD_TEST_MODE")
	term := make(chan os.Signal, 1)
	signal.Notify(term, syscall.SIGTERM)
	defer signal.Stop(term)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.WriteFile(fixtureReady(socket, os.Getpid()), nil, 0600); err != nil {
		t.Fatal(err)
	}
	switch mode {
	case "stalled":
		// The old helper held the socket before it could serve HTTP or
		// respond to its cancellation context.
		for {
			<-term
		}
	case "ready", "empty", "service":
		server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if mode == "service" && r.Method == http.MethodGet && r.URL.Path == "/v1/health" {
				io.WriteString(w, `{"status":"ok"}`)
				return
			}
			if r.Method != http.MethodPost || r.URL.Path != "/tray/servers" {
				http.NotFound(w, r)
				return
			}
			if mode == "empty" {
				io.WriteString(w, `{"ok":true,"data":{"servers":[]}}`)
			} else {
				io.WriteString(w, `{"ok":true,"data":{"servers":[{"state":"keychainPending"}]}}`)
			}
		})}
		go func() {
			<-term
			_ = server.Close()
		}()
		if err := server.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
			t.Fatal(err)
		}
	case "normal":
		<-term
	default:
		t.Fatalf("unrecognized fixture mode %q", mode)
	}
}

func fixtureReady(socket string, pid int) string { return fmt.Sprintf("%s.%d", socket, pid) }

func fixtureRoot(t *testing.T) string {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "ac-reload-test.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	return root
}

func fixtureExecutable(t *testing.T, root, relative string) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	bin, err := os.ReadFile(exe)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, bin, 0700); err != nil {
		t.Fatal(err)
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return path
}

type fixtureProcess struct {
	pid  int
	done chan struct{}
	err  error
}

func startFixture(t *testing.T, exe, socket, mode string) *fixtureProcess {
	t.Helper()
	return startFixtureArgs(t, exe, socket, mode, "-test.run=^TestReloadFixtureProcess$")
}

func startFixtureArgs(t *testing.T, exe, socket, mode string, args ...string) *fixtureProcess {
	t.Helper()
	var output bytes.Buffer
	cmd := exec.Command(exe, args...)
	cmd.Env = append(os.Environ(), "AC_RELOAD_TEST_SOCKET="+socket, "AC_RELOAD_TEST_MODE="+mode)
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	child := &fixtureProcess{pid: cmd.Process.Pid, done: make(chan struct{})}
	go func() {
		child.err = cmd.Wait()
		close(child.done)
	}()
	t.Cleanup(func() {
		if err := cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
			t.Errorf("stop test fixture: %v", err)
		}
		<-child.done
	})
	deadline := time.After(5 * time.Second)
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		if _, err := os.Stat(fixtureReady(socket, child.pid)); err == nil {
			return child
		}
		select {
		case <-deadline:
			t.Fatal("fixture did not bind its socket")
		case <-child.done:
			t.Fatalf("fixture exited before binding: %v %s", child.err, output.String())
		case <-ticker.C:
		}
	}
}

func requireLive(t *testing.T, child *fixtureProcess) {
	t.Helper()
	select {
	case <-child.done:
		t.Fatalf("unrelated PID %d was stopped: %v", child.pid, child.err)
	default:
	}
}

func requireStopped(t *testing.T, child *fixtureProcess, killed bool) {
	t.Helper()
	select {
	case <-child.done:
		var exited *exec.ExitError
		if killed {
			if !errors.As(child.err, &exited) || exited.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
				t.Fatalf("expected shutdown escalation, got %v", child.err)
			}
		} else if child.err != nil {
			t.Fatalf("expected graceful shutdown, got %v", child.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fixture was still alive after stop reported success")
	}
}

func TestReloadReplacesOwnerAndLeavesUnrelatedHelper(t *testing.T) {
	root := fixtureRoot(t)
	socket := filepath.Join(root, "owner")
	cli := fixtureExecutable(t, root, "dist/commander-network")
	bundle := fixtureExecutable(t, root, bundledHelper)
	unrelated := startFixture(t, bundle, filepath.Join(root, "fixture"), "normal")
	first := startFixture(t, cli, socket, "normal")
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	allowed := map[string]bool{cli: true, bundle: true}
	if err := stopHelper(ctx, socket, allowed, 2*time.Second, time.Second, io.Discard); err != nil {
		t.Fatal(err)
	}
	requireStopped(t, first, false)
	requireLive(t, unrelated)

	stalled := startFixture(t, bundle, socket, "stalled")
	seen, err := socketOwner(ctx, socket)
	if err != nil || seen == nil || seen.pid != stalled.pid {
		t.Fatalf("failed to identify a bound but unresponsive process: %+v %v", seen, err)
	}
	if _, err := verifyHelper(ctx, socket, bundle, time.Now()); err == nil || !strings.Contains(err.Error(), "predates") {
		t.Fatalf("accepted a same-path helper from before the build: %v", err)
	}
	probe, endProbe := context.WithTimeout(ctx, 600*time.Millisecond)
	_, err = verifyHelper(probe, socket, bundle, time.Time{})
	endProbe()
	if err == nil {
		t.Fatal("accepted a bound helper without its status response")
	}
	requireLive(t, stalled)
	var report bytes.Buffer
	if err := stopHelper(ctx, socket, allowed, 350*time.Millisecond, 2*time.Second, &report); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(report.String(), "SIGKILL") {
		t.Fatalf("stalled shutdown was not reported: %s", &report)
	}
	requireStopped(t, stalled, true)
	requireLive(t, unrelated)

	// SIGKILL leaves a stale socket file, as it does for the real helper.
	if err := os.Remove(socket); err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	fresh := startFixture(t, bundle, socket, "ready")
	file, err := os.Stat(bundle)
	if err != nil {
		t.Fatal(err)
	}
	pending, err := verifyHelper(ctx, socket, bundle, file.ModTime())
	if err != nil || !pending {
		t.Fatalf("a fresh, responsive helper waiting for Keychain should pass: %v, %v", pending, err)
	}
	requireLive(t, fresh)
	requireLive(t, unrelated)
}

func TestReloadRejectsUnknownAndAmbiguousOwners(t *testing.T) {
	root := fixtureRoot(t)
	socket := filepath.Join(root, "owner")
	bundle := fixtureExecutable(t, root, bundledHelper)
	other := fixtureExecutable(t, root, "unknown/commander-network")
	allowed := map[string]bool{bundle: true}
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
	defer cancel()

	unknown := startFixture(t, other, socket, "normal")
	if err := stopHelper(ctx, socket, allowed, time.Millisecond, time.Millisecond, io.Discard); err == nil ||
		!strings.Contains(err.Error(), "outside the registered") {
		t.Fatalf("unverified owner did not block shutdown: %v", err)
	}
	requireLive(t, unknown)
	// Unlinking a bound Unix socket allows a second listener while the
	// kernel still reports the original listener with the same address.
	if err := os.Remove(socket); err != nil {
		t.Fatal(err)
	}
	second := startFixture(t, bundle, socket, "normal")
	if err := stopHelper(ctx, socket, allowed, time.Millisecond, time.Millisecond, io.Discard); err == nil ||
		!strings.Contains(err.Error(), "ambiguous ownership") {
		t.Fatalf("ambiguous socket did not block shutdown: %v", err)
	}
	requireLive(t, unknown)
	requireLive(t, second)
}

func TestReloadNoRelaysOrFormerOwner(t *testing.T) {
	root := fixtureRoot(t)
	socket := filepath.Join(root, "owner")
	bundle := fixtureExecutable(t, root, bundledHelper)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	active := startFixture(t, bundle, socket, "empty")
	old, err := socketOwner(ctx, socket)
	if err != nil || old == nil || old.pid != active.pid {
		t.Fatalf("fixture did not own the socket: %+v %v", old, err)
	}
	if pending, err := verifyHelper(ctx, socket, bundle, time.Time{}); err != nil || pending {
		t.Fatalf("a valid empty server list should pass without a Keychain wait: %v, %v", pending, err)
	}
	if err := stopHelper(ctx, socket, map[string]bool{bundle: true}, 2*time.Second, time.Second, io.Discard); err != nil {
		t.Fatal(err)
	}
	requireStopped(t, active, false)

	// An exit between the original observation and the signal is harmless.
	if sent, err := signalHelper(ctx, socket, *old, syscall.SIGTERM); sent || err != nil {
		t.Fatalf("signaling an already exited owner: %v, %v", sent, err)
	}
	replacement := startFixture(t, bundle, socket, "empty")
	if sent, err := signalHelper(ctx, socket, *old, syscall.SIGKILL); sent || err == nil ||
		!strings.Contains(err.Error(), "ownership") {
		t.Fatalf("the same executable's replacement did not fence off the old observation: %v, %v", sent, err)
	}
	requireLive(t, replacement)
}
