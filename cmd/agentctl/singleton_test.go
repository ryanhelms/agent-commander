package main

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"agentcommander/internal/localapi"
)

func TestServiceExclusiveOwnership(t *testing.T) {
	t.Setenv("AGENT_COMMANDER_HOSTED_CONFIG", "")
	previousMask := syscall.Umask(0077)
	defer syscall.Umask(previousMask)
	// macOS limits the full Unix socket path to 103 bytes.
	dir, err := os.MkdirTemp("/tmp", "ac-ownership-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "api.sock")
	ctx, stop := context.WithTimeout(t.Context(), 10*time.Second)
	defer stop()

	// A dead process leaves its socket node behind. Another launch can already
	// own recovery before it binds a replacement listener.
	stale, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	stale.SetUnlinkOnClose(false)
	stale.Close()
	original, err := os.Stat(socket)
	if err != nil {
		t.Fatal(err)
	}
	guard, err := lockServiceFile(socket+".agentctl-lock", "busy")
	if err != nil {
		t.Fatal(err)
	}
	paths := localapi.Paths{State: filepath.Join(dir, "a"), Socket: socket}
	err = serve(ctx, paths)
	guard.Close()
	if err == nil || !strings.Contains(err.Error(), "socket is in use") {
		t.Fatalf("contended socket recovery returned %v", err)
	}
	if info, err := os.Stat(socket); err != nil || !os.SameFile(original, info) {
		t.Fatalf("contender disturbed the stale socket: %v", err)
	}

	type exit struct {
		paths localapi.Paths
		err   error
	}
	done := make(chan exit, 4)
	launch := func(c context.Context, p localapi.Paths) { go func() { done <- exit{p, serve(c, p)} }() }
	result := func() exit {
		t.Helper()
		select {
		case x := <-done:
			return x
		case <-ctx.Done():
			t.Fatal("timed out waiting for service")
			return exit{}
		}
	}
	ready := func(socket string) {
		t.Helper()
		client := localapi.New(socket, "")
		for {
			if _, err := client.Do(ctx, "GET", "/v1/health", nil); err == nil {
				return
			}
			select {
			case <-ctx.Done():
				t.Fatalf("%s did not become ready", socket)
			case <-time.After(10 * time.Millisecond):
			}
		}
	}

	owners, release := context.WithCancel(ctx)
	defer release()
	other := localapi.Paths{State: filepath.Join(dir, "b"), Socket: socket}
	launch(owners, paths)
	launch(owners, other)
	loser := result()
	if loser.err == nil || !strings.Contains(loser.err.Error(), "socket is in use") {
		t.Fatalf("concurrent starts returned %v", loser.err)
	}
	ready(socket)
	winner := paths
	if loser.paths == paths {
		winner = other
	}
	independent := localapi.Paths{State: loser.paths.State, Socket: filepath.Join(dir, "independent.sock")}
	if err := serve(ctx, localapi.Paths{State: winner.State, Socket: independent.Socket}); err == nil || !strings.Contains(err.Error(), "data directory") {
		t.Fatalf("another socket on the same state returned %v", err)
	}
	launch(owners, independent)
	ready(independent.Socket)
	ready(socket)
	release()
	for range 2 {
		if x := result(); x.err != nil {
			t.Fatalf("shutdown of %s: %v", x.paths.Socket, x.err)
		}
	}
	restarted, shutdown := context.WithCancel(ctx)
	defer shutdown()
	launch(restarted, winner)
	ready(socket)
	shutdown()
	if x := result(); x.err != nil {
		t.Fatalf("restarted service: %v", x.err)
	}
}
