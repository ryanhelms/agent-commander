package actions

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const (
	firstLaunch  = "12345678-1234-4000-8000-123456789abc"
	secondLaunch = "12345678-1234-4000-8000-123456789def"
	firstNonce   = "0123456789abcdef0123456789abcdef"
	secondNonce  = "abcdef0123456789abcdef0123456789"
)

func TestDesktopBuildFreshGrantedObservation(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "service.sock")
	observedLaunch := firstLaunch
	now := time.Now().UTC()
	reads := 0
	read := func(_ context.Context, got string) (DesktopBuild, error) {
		reads++
		if got != socket {
			t.Fatalf("app observer bound to %q, want %q", got, socket)
		}
		return DesktopBuild{Version: "0.1.0-pilot.6-9-gabcde12-dirty", Revision: strings.Repeat("a", 40),
			Tree: "dirty", Started: now.Add(-time.Minute), LaunchID: observedLaunch}, nil
	}
	resource := Resource{ID: "bob-coordinator", Kind: "agent", Target: "worker", Run: "run", Coordinator: true}
	cfg := Config{
		StateDir: t.TempDir(), CommanderSocket: socket, ReadDesktopBuild: read, Resources: []Resource{resource},
		Grants: []Grant{{ID: "note", Peer: "alice", Resource: resource.ID, Action: "agent.message", ExpiresAt: now.Add(time.Hour)}},
	}
	makeRequest := func(id, nonce string, issued time.Time) Request {
		p, err := json.Marshal(DesktopBuildChallenge{Nonce: nonce, IssuedAt: issued})
		if err != nil {
			t.Fatal(err)
		}
		return Request{ID: id, Peer: "alice", Resource: resource.ID, Action: "app.build", Payload: p}
	}
	request := makeRequest("observe", firstNonce, now)
	if _, err := Execute(t.Context(), cfg, request); !errors.Is(err, ErrDenied) || reads != 0 {
		t.Fatalf("note-only grant: reads=%d, %v", reads, err)
	}
	cfg.Grants = append(cfg.Grants, Grant{ID: "build", Peer: "alice", Resource: resource.ID, Action: "app.build", ExpiresAt: now.Add(time.Hour)})
	if _, err := Execute(t.Context(), cfg, makeRequest("stale", firstNonce, now.Add(-2*time.Minute))); !errors.Is(err, ErrBuildRequestExpired) || reads != 0 {
		t.Fatalf("expired request reached live app: reads=%d, %v", reads, err)
	}
	if _, err := Execute(t.Context(), cfg, makeRequest("future", firstNonce, now.Add(time.Minute))); !errors.Is(err, ErrBuildRequestExpired) || reads != 0 {
		t.Fatalf("future request reached live app: reads=%d, %v", reads, err)
	}
	if _, err := Execute(t.Context(), cfg, makeRequest("bad-nonce", "not-fresh", now)); !errors.Is(err, ErrInvalid) || reads != 0 {
		t.Fatalf("invalid request reached live app: reads=%d, %v", reads, err)
	}
	out, err := Execute(t.Context(), cfg, request)
	var reply struct {
		DesktopBuild
		Nonce      string
		ObservedAt time.Time
	}
	if err != nil || json.Unmarshal(out, &reply) != nil || reply.Nonce != firstNonce || reply.LaunchID != firstLaunch ||
		reply.ObservedAt.Before(now) || reply.Tree != "dirty" || reply.Revision != strings.Repeat("a", 40) {
		t.Fatalf("incorrect live evidence: %s, %v", out, err)
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(out, &fields) != nil || len(fields) != 7 || bytes.Contains(out, []byte(socket)) {
		t.Fatalf("unexpected evidence fields: %s", out)
	}
	// A retry retrieves the same observation even if the app has relaunched.
	observedLaunch = secondLaunch
	replay, err := Execute(t.Context(), cfg, request)
	if err != nil || !bytes.Equal(out, replay) || reads != 1 {
		t.Fatalf("replay resampled the app: reads=%d, %v, %s", reads, err, replay)
	}
	if _, err = Execute(t.Context(), cfg, makeRequest(request.ID, secondNonce, now)); !errors.Is(err, ErrConflict) || reads != 1 {
		t.Fatalf("changed nonce reused operation: %v, reads=%d", err, reads)
	}
	fresh, err := Execute(t.Context(), cfg, makeRequest("relaunch", secondNonce, now))
	if err != nil || json.Unmarshal(fresh, &reply) != nil || reply.Nonce != secondNonce || reply.LaunchID != secondLaunch || reads != 2 {
		t.Fatalf("fresh operation did not see relaunch: reads=%d, %v, %s", reads, err, fresh)
	}
	cfg.ReadDesktopBuild = func(context.Context, string) (DesktopBuild, error) {
		return DesktopBuild{}, errors.New("private local detail")
	}
	if _, err = Execute(t.Context(), cfg, makeRequest("no-app", secondNonce, now)); FailureCode(err) != "app_build_unavailable" ||
		strings.Contains(FailureReason(err), "private") {
		t.Fatalf("unavailable application produced unsuitable peer error: %v", err)
	}
}

func newDesktopFixtureRecord(socket string, pid int) launchRecord {
	now := time.Now().Add(-time.Minute)
	return launchRecord{
		Schema: 1, PID: pid, StartedSeconds: now.Unix(), StartedMicros: int64(now.Nanosecond() / 1000),
		LaunchID: firstLaunch, Revision: strings.Repeat("a", 40), Tree: "clean",
		Version: "0.1.0-pilot.6-9-gabcde12", Executable: "/fixture/Commander.app/Contents/MacOS/AgentCommander",
		CommanderSocket: socket,
	}
}

func holdDesktopFixtureLease(t *testing.T, path string, raw []byte) *os.File {
	t.Helper()
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { file.Close() })
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write(raw); err != nil {
		t.Fatal(err)
	}
	return file
}

func encodedDesktopFixtureRecord(t *testing.T, record launchRecord) []byte {
	t.Helper()
	raw, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestDesktopBuildRequiresUnambiguousMatchingLiveLease(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "default.sock")
	other := filepath.Join(dir, "other.sock")
	lease := func(pid int, data []byte) *os.File {
		return holdDesktopFixtureLease(t, filepath.Join(dir, strconv.Itoa(pid)+".lease"), data)
	}
	theRecord := newDesktopFixtureRecord(socket, 101)
	raw := encodedDesktopFixtureRecord(t, theRecord)
	match := func(r launchRecord) bool { return r == theRecord }
	original := lease(101, raw)
	// This app is live but belongs to a different owner's configured endpoint.
	wrongProfile := newDesktopFixtureRecord(other, 102)
	lease(102, encodedDesktopFixtureRecord(t, wrongProfile))

	check := func(verifier func(launchRecord) bool, wantSuccess bool) {
		t.Helper()
		got, err := readDesktopLaunchDirectory(t.Context(), dir, socket, verifier)
		if wantSuccess {
			if err != nil || got.LaunchID != firstLaunch {
				t.Fatalf("matching live app not found: %+v, %v", got, err)
			}
		} else if !errors.Is(err, ErrDesktopBuildUnavailable) || got.LaunchID != "" {
			t.Fatalf("returned evidence without a matching live app: %+v, %v", got, err)
		}
	}
	check(match, true)
	check(func(launchRecord) bool { return false }, false)
	check(func(record launchRecord) bool {
		if err := original.Close(); err != nil {
			t.Fatal(err)
		}
		return record == theRecord
	}, false)

	one := lease(103, encodedDesktopFixtureRecord(t, newDesktopFixtureRecord(socket, 103)))
	two := lease(104, encodedDesktopFixtureRecord(t, newDesktopFixtureRecord(socket, 104)))
	check(func(launchRecord) bool { return true }, false)
	if err := two.Close(); err != nil {
		t.Fatal(err)
	}
	check(func(launchRecord) bool { return true }, true)
	legacy := lease(105, nil) // Older builds hold a lease but write no startup evidence.
	check(func(launchRecord) bool { return true }, false)
	if err := legacy.Close(); err != nil {
		t.Fatal(err)
	}
	if err := one.Close(); err != nil {
		t.Fatal(err)
	}
	check(match, false)
}

func TestDesktopBuildChallengeRejectsMismatchedAndStaleProof(t *testing.T) {
	now := time.Date(2026, 11, 27, 18, 10, 0, 0, time.UTC)
	challenge := DesktopBuildChallenge{Nonce: firstNonce, IssuedAt: now}
	build := DesktopBuild{Version: "0.1.0-pilot.6", Revision: strings.Repeat("a", 40),
		Tree: "clean", LaunchID: firstLaunch, Started: now.Add(-time.Minute)}
	proof := desktopBuildProof{DesktopBuild: build, Nonce: firstNonce, ObservedAt: now}
	encode := func(proof desktopBuildProof) json.RawMessage {
		t.Helper()
		raw, err := json.Marshal(proof)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	good := encode(proof)
	wrongNonce := proof
	wrongNonce.Nonce = secondNonce
	staleObservation := proof
	staleObservation.ObservedAt = now.Add(-time.Minute)
	staleObservation.Started = now.Add(-2 * time.Minute)
	futureObservation := proof
	futureObservation.ObservedAt = now.Add(time.Minute)
	unexpectedMetadata := append(bytes.TrimSuffix(bytes.Clone(good), []byte("}")), []byte(`,"executable":"/private/path"}`)...)
	for _, test := range []struct {
		name      string
		challenge DesktopBuildChallenge
		response  json.RawMessage
		at        time.Time
		want      string
	}{
		{"fresh", challenge, good, now, "verified"},
		{"aged receipt", challenge, good, now.Add(91 * time.Second), "expired"},
		{"other nonce", challenge, encode(wrongNonce), now, "invalid"},
		{"prior observation", challenge, encode(staleObservation), now, "invalid"},
		{"future observation", challenge, encode(futureObservation), now, "invalid"},
		{"extra local fields", challenge, unexpectedMetadata, now, "invalid"},
		{"missing sender challenge", DesktopBuildChallenge{}, good, now, "invalid"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := test.challenge.ProofState(test.response, test.at); got != test.want {
				t.Fatalf("ProofState = %q, want %q", got, test.want)
			}
		})
	}
}
