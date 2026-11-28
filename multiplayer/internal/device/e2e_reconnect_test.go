package device

import (
	"bytes"
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/testpilot"
	"github.com/jackc/pgx/v5/pgxpool"

	"agentcommander.network/pilot/internal/netlog"
)

func openTestNetLog(t *testing.T, path string) *slog.Logger {
	t.Helper()
	l, err := netlog.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	return l.Logger
}

func (r *reconnectRig) deviceID() string {
	r.peer.agent.mu.Lock()
	defer r.peer.agent.mu.Unlock()
	return r.peer.agent.creds.Session.Device
}

// End-to-end reconnect tests: a real commander-relay process (PostgreSQL,
// JetStream, fixture OIDC issuer) and an in-process device agent that reaches
// it through a fault-injecting TCP proxy. They reproduce the 2026-11-28
// incident, where a refresh committed on the relay but its response never
// reached a sleeping Mac.

type reconnectStatus struct {
	Online, SignedIn, LoginPending bool
	Handle, Error                  string
}

type reconnectRig struct {
	p     *testpilot.Pilot
	proxy *faultProxy
	peer  *pilotPeer
	db    *pgxpool.Pool
	log   string
}

func startReconnectRig(t *testing.T, ctx context.Context, handle string) *reconnectRig {
	t.Helper()
	p := testpilot.Start(t)
	proxy := newFaultProxy(t, strings.TrimPrefix(p.Edges[0], "https://"))
	who, socket := startPilotCommander(t, handle)
	dir := t.TempDir()
	secrets, err := devicekeys.Directory(filepath.Join(dir, "secrets"))
	if err != nil {
		t.Fatal(err)
	}
	issuerHTTP := p.OIDCHTTP()
	t.Cleanup(issuerHTTP.CloseIdleConnections)
	logPath := filepath.Join(dir, "logs", "network.log")
	who.agent, err = New(ctx, Config{Relay: "https://" + proxy.addr(), Dir: filepath.Join(dir, "device"), CommanderSocket: socket,
		Roots: p.Roots, OpenBrowser: p.Browser(handle), Secrets: secrets, OIDCHTTP: issuerHTTP, Log: openTestNetLog(t, logPath)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(who.agent.Close)
	who.api = who.agent.Handler()
	who.otherRun.api = who.api
	db, err := pgxpool.New(ctx, p.DatabaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	r := &reconnectRig{p: p, proxy: proxy, peer: who, db: db, log: logPath}
	who.must(t, ctx, "/tray/login", input{Handle: handle}, nil)
	who.waitOnline(t, ctx)
	return r
}

func (r *reconnectRig) status(t *testing.T, ctx context.Context) reconnectStatus {
	t.Helper()
	var s reconnectStatus
	r.peer.must(t, ctx, "/tray/status", input{}, &s)
	return s
}

func (r *reconnectRig) refreshHash(t *testing.T, ctx context.Context) []byte {
	t.Helper()
	var h []byte
	if err := r.db.QueryRow(ctx, "SELECT refresh_hash FROM mp_auth_devices WHERE device=$1", r.deviceID()).Scan(&h); err != nil {
		t.Fatal(err)
	}
	return h
}

func (r *reconnectRig) storedRefresh() string {
	r.peer.agent.mu.Lock()
	defer r.peer.agent.mu.Unlock()
	return r.peer.agent.creds.Session.RefreshToken
}

// expireAccess makes the device's access token due, as fifteen minutes of
// sleep would.
func (r *reconnectRig) expireAccess() {
	r.peer.agent.mu.Lock()
	r.peer.agent.creds.Session.ExpiresAt = time.Now().Add(-time.Minute)
	r.peer.agent.mu.Unlock()
}

// loseNextRefreshResponse lets the device's next refresh reach the relay and
// commit there, while every byte back to the device is dropped.
func (r *reconnectRig) loseNextRefreshResponse(t *testing.T, ctx context.Context) {
	t.Helper()
	before := r.refreshHash(t, ctx)
	r.triggerRefreshOverOpenConnection(ctx)
	deadline := time.Now().Add(45 * time.Second)
	for bytes.Equal(r.refreshHash(t, ctx), before) {
		if time.Now().After(deadline) {
			t.Fatal("device never sent a refresh to the relay")
		}
		time.Sleep(50 * time.Millisecond)
	}
	// The relay has rotated; the device has not seen the answer. Then the
	// "network comes back": connections reset, faults cleared.
	time.Sleep(500 * time.Millisecond)
	r.proxy.set(false, false)
	r.proxy.dropAll()
}

// triggerRefreshOverOpenConnection starts dropping relay→device bytes on the
// already-established TLS connection, then makes the access token due and
// asks for a session, so the refresh request reaches the relay over that
// connection while its response is lost. (A new connection could not even
// finish its TLS handshake under the blackhole.)
func (r *reconnectRig) triggerRefreshOverOpenConnection(ctx context.Context) {
	r.proxy.set(true, false)
	r.expireAccess()
	go r.peer.agent.getSession(ctx)
}

func (r *reconnectRig) logText(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(r.log)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func waitFor(t *testing.T, ctx context.Context, within time.Duration, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(within)
	for !ok() {
		if time.Now().After(deadline) || ctx.Err() != nil {
			t.Fatalf("timed out after %s waiting for %s", within, what)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestE2EReconnectAfterLostRefreshResponse(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 4*time.Minute)
	defer cancel()
	r := startReconnectRig(t, ctx, "nick")
	original := r.storedRefresh()
	r.loseNextRefreshResponse(t, ctx)
	waitFor(t, ctx, 90*time.Second, "device back online after a lost refresh response", func() bool {
		s := r.status(t, ctx)
		return s.Online && s.SignedIn
	})
	if got := r.storedRefresh(); got == original {
		t.Fatal("device still holds the pre-incident refresh token")
	}
	// A second loss in a row also recovers.
	r.loseNextRefreshResponse(t, ctx)
	waitFor(t, ctx, 90*time.Second, "device online after a second lost response", func() bool {
		return r.status(t, ctx).Online
	})
	assertLogClean(t, r)
}

// Against a relay that refuses the previous token (the pre-fix relay, or a
// revoked or expired session), the device must stop retrying and ask for
// sign-in, and sign-in must bring it back.
func TestE2ERefusedRefreshAsksForSignIn(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 4*time.Minute)
	defer cancel()
	r := startReconnectRig(t, ctx, "nick")
	before := r.refreshHash(t, ctx)
	r.triggerRefreshOverOpenConnection(ctx)
	waitFor(t, ctx, 45*time.Second, "refresh committed on relay", func() bool { return !bytes.Equal(r.refreshHash(t, ctx), before) })
	// Emulate the old relay: no previous-token grace.
	if _, err := r.db.Exec(ctx, "UPDATE mp_auth_devices SET prev_refresh_hash=NULL WHERE device=$1", r.deviceID()); err != nil {
		t.Fatal(err)
	}
	r.proxy.set(false, false)
	r.proxy.dropAll()
	var last reconnectStatus
	waitFor(t, ctx, 60*time.Second, "signed-out state with a sign-in message", func() bool {
		last = r.status(t, ctx)
		return !last.SignedIn && !last.Online && strings.Contains(strings.ToLower(last.Error), "sign in")
	})
	t.Logf("tray after refusal: %+v", last)
	// No hot loop: refresh attempts stop once the refusal is terminal.
	attempts := func() int { return strings.Count(r.logText(t), "refresh") }
	n := attempts()
	time.Sleep(10 * time.Second)
	if extra := attempts() - n; extra > 1 {
		t.Fatalf("device kept refreshing after a terminal refusal: %d more log lines", extra)
	}
	r.peer.must(t, ctx, "/tray/login", input{Handle: "nick"}, nil)
	r.peer.waitOnline(t, ctx)
	assertLogClean(t, r)
}

// A relay outage is transient: the device keeps its session, backs off, and
// reconnects when the relay returns.
func TestE2EOutageBacksOffAndReconnects(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 4*time.Minute)
	defer cancel()
	r := startReconnectRig(t, ctx, "nick")
	token := r.storedRefresh()
	r.proxy.set(false, true)
	r.expireAccess()
	r.proxy.dropAll()
	time.Sleep(40 * time.Second)
	s := r.status(t, ctx)
	if !s.SignedIn {
		t.Fatalf("outage signed the device out: %+v", s)
	}
	if r.storedRefresh() != token {
		t.Fatal("refresh token changed during an outage")
	}
	r.proxy.set(false, false)
	waitFor(t, ctx, 75*time.Second, "reconnect after outage", func() bool { return r.status(t, ctx).Online })
	assertLogClean(t, r)
}

func assertLogClean(t *testing.T, r *reconnectRig) {
	t.Helper()
	text := r.logText(t)
	if text == "" {
		t.Fatal("network log is empty")
	}
	r.peer.agent.mu.Lock()
	secrets := []string{r.peer.agent.creds.Session.RefreshToken, r.peer.agent.creds.Session.AccessToken}
	r.peer.agent.mu.Unlock()
	for _, s := range secrets {
		if s != "" && strings.Contains(text, s) {
			t.Fatal("network log contains token material")
		}
	}
	t.Logf("network log (%d lines), tail:\n%s", strings.Count(text, "\n"), tailLines(text, 25))
}

func tailLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
