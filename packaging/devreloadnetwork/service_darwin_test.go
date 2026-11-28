//go:build darwin && cgo

package main

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/localapi"
)

const bundledAgentctl = "dist/Agent Commander.app/Contents/MacOS/agentctl"

func TestServiceReloadOnlyStopsTheSelectedSocket(t *testing.T) {
	root := fixtureRoot(t)
	t.Setenv("HOME", root)
	t.Setenv("AGENT_COMMANDER_HOME", "")
	t.Setenv("AGENT_COMMANDER_SOCKET", "")
	paths, err := localapi.Config()
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(root, "Library", "Application Support", "Agent Commander", "service.sock"); paths.Socket != want {
		t.Fatalf("selected socket %q, want documented default %q", paths.Socket, want)
	}
	if err := os.MkdirAll(paths.State, 0700); err != nil {
		t.Fatal(err)
	}
	standalone := fixtureExecutable(t, root, "dist/agentctl")
	bundle := fixtureExecutable(t, root, bundledAgentctl)
	old := startFixtureArgs(t, standalone, paths.Socket, "service", "serve")
	otherCLI := startFixtureArgs(t, standalone, filepath.Join(root, "other-cli.sock"), "service", "serve")
	otherBundle := startFixtureArgs(t, bundle, filepath.Join(root, "other-bundle.sock"), "service", "serve")

	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	allowed := map[string]bool{standalone: true, bundle: true}
	var report bytes.Buffer
	if err := stopService(ctx, paths.Socket, allowed, 3*time.Second, &report); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(report.String(), "PID "+strconv.Itoa(old.pid)) || !strings.Contains(report.String(), paths.Socket) {
		t.Fatalf("stop did not identify the selected service: %s", &report)
	}
	requireStopped(t, old, false)
	requireLive(t, otherCLI)
	requireLive(t, otherBundle)

	bin, err := os.Stat(bundle)
	if err != nil {
		t.Fatal(err)
	}
	fresh := startFixtureArgs(t, bundle, paths.Socket, "service", "serve")
	if err := verifyService(ctx, paths.Socket, bundle, bin.ModTime()); err != nil {
		t.Fatal(err)
	}
	requireLive(t, fresh)

	// The app can target a deliberately configured local socket. The same
	// test uses it without stopping the freshly verified default owner.
	custom := filepath.Join(root, "other-bundle.sock")
	t.Setenv("AGENT_COMMANDER_HOME", filepath.Join(root, "custom-state"))
	t.Setenv("AGENT_COMMANDER_SOCKET", custom)
	customPaths, err := localapi.Config()
	if err != nil || customPaths.Socket != custom {
		t.Fatalf("configured socket %q, %v", customPaths.Socket, err)
	}
	if err := stopService(ctx, customPaths.Socket, allowed, 3*time.Second, io.Discard); err != nil {
		t.Fatal(err)
	}
	requireStopped(t, otherBundle, false)
	requireLive(t, otherCLI)
	requireLive(t, fresh)
}

func TestServiceReloadRefusesUnexpectedSocketOwners(t *testing.T) {
	root := fixtureRoot(t)
	bundle := fixtureExecutable(t, root, bundledAgentctl)
	foreign := fixtureExecutable(t, root, "unregistered/agentctl")
	allowed := map[string]bool{bundle: true}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	socket := filepath.Join(root, "wrong-role.sock")
	wrongRole := startFixtureArgs(t, bundle, socket, "service", "host", "connect")
	if err := stopService(ctx, socket, allowed, time.Millisecond, io.Discard); err == nil ||
		!strings.Contains(err.Error(), "not running agentctl serve") {
		t.Fatalf("unexpected service role was accepted: %v", err)
	}
	requireLive(t, wrongRole)

	socket = filepath.Join(root, "unexpected-exe.sock")
	unregistered := startFixtureArgs(t, foreign, socket, "service", "serve")
	if err := stopService(ctx, socket, allowed, time.Millisecond, io.Discard); err == nil ||
		!strings.Contains(err.Error(), "outside the registered agentctl paths") {
		t.Fatalf("unexpected executable was accepted: %v", err)
	}
	requireLive(t, unregistered)

	socket = filepath.Join(root, "ambiguous.sock")
	first := startFixtureArgs(t, bundle, socket, "service", "serve")
	if err := os.Remove(socket); err != nil {
		t.Fatal(err)
	}
	second := startFixtureArgs(t, bundle, socket, "service", "serve")
	if err := stopService(ctx, socket, allowed, time.Millisecond, io.Discard); err == nil ||
		!strings.Contains(err.Error(), "ambiguous ownership") {
		t.Fatalf("ambiguous service was accepted: %v", err)
	}
	requireLive(t, first)
	requireLive(t, second)

	socket = filepath.Join(root, "stalled.sock")
	stalled := startFixtureArgs(t, bundle, socket, "stalled", "serve")
	if err := stopService(ctx, socket, allowed, 250*time.Millisecond, io.Discard); err == nil ||
		!strings.Contains(err.Error(), "did not release") {
		t.Fatalf("stalled service reported a successful stop: %v", err)
	}
	requireLive(t, stalled)
}
