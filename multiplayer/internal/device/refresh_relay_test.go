package device

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
	"agentcommander.network/pilot/internal/netlog"
	"agentcommander.network/pilot/internal/testpilot"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func relayTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("PILOT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set PILOT_TEST_DATABASE_URL to a disposable PostgreSQL database")
	}
	ctx := t.Context()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	schema := pgx.Identifier{"device_refresh_" + strings.ToLower(newID())}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error(err)
		}
	})
	cfg := admin.Config()
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

// faultyAuth runs the relay's real auth handlers and records every token they
// issue. Armed, it lets one refresh commit and then drops the connection.
type faultyAuth struct {
	next      http.Handler
	dropNext  atomic.Bool
	refreshes atomic.Int32
	mu        sync.Mutex
	secrets   []string
}

func (f *faultyAuth) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.URL.Path, "/v1/auth/") {
		f.next.ServeHTTP(w, r)
		return
	}
	if r.URL.Path == "/v1/auth/refresh" {
		f.refreshes.Add(1)
	}
	rec := httptest.NewRecorder()
	f.next.ServeHTTP(rec, r)
	var s identity.Session
	if json.Unmarshal(rec.Body.Bytes(), &s) == nil {
		f.mu.Lock()
		for _, v := range []string{s.AccessToken, s.RefreshToken} {
			if v != "" {
				f.secrets = append(f.secrets, v)
			}
		}
		f.mu.Unlock()
	}
	if r.URL.Path == "/v1/auth/refresh" && rec.Code == 200 && f.dropNext.CompareAndSwap(true, false) {
		panic(http.ErrAbortHandler)
	}
	for k, v := range rec.Header() {
		w.Header()[k] = v
	}
	w.WriteHeader(rec.Code)
	w.Write(rec.Body.Bytes())
}

// TestRelayDroppedRefreshResponse runs the relay's identity service in
// process. Session and inbox routes are minimal stand-ins: the refresh path
// is the real one. Without the relay's refresh grace (#218) the device signs
// out; with it, the device recovers. Either way it stops retrying.
func TestRelayDroppedRefreshResponse(t *testing.T) {
	pool := relayTestPool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	issuer := testpilot.StartIssuer(t)
	issuerHTTP := issuer.OIDCHTTP()
	t.Cleanup(issuerHTTP.CloseIdleConnections)
	ids, err := identity.New(ctx, pool, identity.Config{Issuer: issuer.Issuer, ClientID: "pilot-fixture", HTTPClient: issuerHTTP})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	ids.Register(mux)
	lease := func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(control.Lease{Session: "lease-1", Generation: 1, ExpiresAt: time.Now().Add(time.Minute)})
	}
	mux.HandleFunc("POST /v1/session", lease)
	mux.HandleFunc("PUT /v1/session", lease)
	mux.HandleFunc("GET /v1/inbox", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(100 * time.Millisecond):
		}
		w.Write([]byte(`{"children":[]}`))
	})
	mux.HandleFunc("PUT /v1/profile", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{}`)) })
	auth := &faultyAuth{next: mux}
	edge := httptest.NewUnstartedServer(auth)
	edge.TLS = &tls.Config{MinVersion: tls.VersionTLS13, ClientAuth: tls.RequireAnyClientCert}
	edge.StartTLS()
	t.Cleanup(edge.Close)
	roots := x509.NewCertPool()
	roots.AddCert(edge.Certificate())

	dir := t.TempDir()
	secrets, err := devicekeys.Directory(filepath.Join(dir, "secrets"))
	if err != nil {
		t.Fatal(err)
	}
	logPath := netlog.DefaultPath(filepath.Join(dir, "network"))
	log, err := netlog.Open(logPath)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	a, err := New(ctx, Config{Relay: edge.URL, Dir: filepath.Join(dir, "device"), Roots: roots, Secrets: secrets,
		OpenBrowser: issuer.Browser("alice"), OIDCHTTP: issuerHTTP, Log: log.With("server", "test")})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.Close)
	if _, err = a.startLogin("alice", ""); err != nil {
		t.Fatal(err)
	}
	waitState(t, a, "online", 30*time.Second)

	// One ordinary refresh, then one whose response is lost.
	expire := func() {
		a.mu.Lock()
		a.creds.Session.ExpiresAt = time.Now()
		a.mu.Unlock()
	}
	expire()
	if _, err = a.getSession(ctx); err != nil {
		t.Fatalf("ordinary refresh: %v", err)
	}
	a.mu.Lock()
	device := a.creds.Session.Device
	a.mu.Unlock()
	before := auth.refreshes.Load()
	auth.dropNext.Store(true)
	expire()

	end := time.Now().Add(20 * time.Second)
	var outcome string
	for outcome == "" {
		s := agentSummary(a)
		switch {
		case s.State == "signedOut":
			if s.Error != sessionEndedText {
				t.Fatalf("signed out with %q", s.Error)
			}
			outcome = "signedOut"
		case s.State == "online" && auth.refreshes.Load() >= before+2:
			outcome = "recovered"
		case time.Now().After(end):
			t.Fatalf("no outcome: %+v after %d refreshes", s, auth.refreshes.Load()-before)
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Logf("relay outcome after a lost refresh response: %s", outcome)
	settled := auth.refreshes.Load()
	if settled-before != 2 {
		t.Fatalf("%d refresh calls, want the lost one and one retry", settled-before)
	}
	time.Sleep(2500 * time.Millisecond)
	if n := auth.refreshes.Load(); n != settled {
		t.Fatalf("refresh calls continued: %d -> %d", settled, n)
	}

	log.Close()
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if testing.Verbose() {
		t.Logf("network log:\n%s", data)
	}
	for _, want := range []string{`"msg":"refresh"`, `"outcome":"ok"`, `"outcome":"transient"`, `"msg":"session_open"`, `"msg":"state"`} {
		if !bytes.Contains(data, []byte(want)) {
			t.Errorf("log lacks %s:\n%s", want, data)
		}
	}
	if outcome == "signedOut" && !bytes.Contains(data, []byte(`"outcome":"terminal"`)) {
		t.Errorf("log lacks the terminal refresh:\n%s", data)
	}
	auth.mu.Lock()
	secretsSeen := append([]string(nil), auth.secrets...)
	auth.mu.Unlock()
	if len(secretsSeen) < 6 {
		t.Fatalf("captured only %d tokens", len(secretsSeen))
	}
	for _, s := range append(secretsSeen, device, "alice@") {
		if s != "" && bytes.Contains(data, []byte(s)) {
			t.Fatalf("network log contains a secret or identifier %q", s[:min(len(s), 6)])
		}
	}
}

func TestDiagnosticsVerbReturnsLogTail(t *testing.T) {
	dir := t.TempDir()
	path := netlog.DefaultPath(dir)
	log, err := netlog.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	for i := range 250 {
		log.Info("event", "i", i)
	}
	log.Close()
	m := &Manager{cfg: ManagerConfig{LogPath: path}}
	rec := httptest.NewRecorder()
	m.Handler().ServeHTTP(rec, httptest.NewRequest("POST", "/tray/diagnostics", strings.NewReader("{}")))
	var out struct {
		OK   bool
		Data struct {
			LogPath string   `json:"logPath"`
			Tail    []string `json:"tail"`
		}
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || !out.OK {
		t.Fatalf("reply %s", rec.Body)
	}
	if out.Data.LogPath != path || len(out.Data.Tail) != 200 || !strings.Contains(out.Data.Tail[199], `"i":249`) {
		t.Fatalf("diagnostics %s %d", out.Data.LogPath, len(out.Data.Tail))
	}
	rec = httptest.NewRecorder()
	m.Handler().ServeHTTP(rec, httptest.NewRequest("POST", "/tray/diagnostics", strings.NewReader(`{"x":1}`)))
	if !strings.Contains(rec.Body.String(), "invalid request") {
		t.Fatalf("accepted unknown fields: %s", rec.Body)
	}
}
