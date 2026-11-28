package device

import (
	"context"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
)

func TestClassifyRefresh(t *testing.T) {
	ctx := context.Background()
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	for _, tc := range []struct {
		name   string
		ctx    context.Context
		err    error
		want   refreshClass
		status int
	}{
		{"ok", ctx, nil, refreshOK, 0},
		{"401", ctx, identity.HTTPError{Status: 401}, refreshTerminal, 401},
		{"403", ctx, identity.HTTPError{Status: 403}, refreshTerminal, 403},
		{"wrapped 401", ctx, fmt.Errorf("x: %w", identity.HTTPError{Status: 401}), refreshTerminal, 401},
		{"500", ctx, identity.HTTPError{Status: 500}, refreshTransient, 500},
		{"503", ctx, identity.HTTPError{Status: 503}, refreshTransient, 503},
		{"429", ctx, identity.HTTPError{Status: 429}, refreshTransient, 429},
		{"net", ctx, &net.OpError{Op: "dial", Err: errors.New("connection refused")}, refreshTransient, 0},
		{"timeout", ctx, context.DeadlineExceeded, refreshTransient, 0},
		{"canceled", canceled, context.Canceled, refreshCanceled, 0},
	} {
		class, status := classifyRefresh(tc.ctx, tc.err)
		if class != tc.want || status != tc.status {
			t.Errorf("%s: got %s/%d, want %s/%d", tc.name, class, status, tc.want, tc.status)
		}
	}
}

func TestBackoffSchedule(t *testing.T) {
	b := backoff{jitter: func() float64 { return 0.5 }}
	var got []time.Duration
	for range 9 {
		got = append(got, b.next())
	}
	want := []time.Duration{1, 2, 4, 8, 16, 32, 60, 60, 60}
	for i := range want {
		if got[i] != want[i]*time.Second {
			t.Fatalf("schedule %v, want %v seconds", got, want)
		}
	}
	b.reset()
	if d := b.next(); d != time.Second {
		t.Fatalf("after reset %v", d)
	}
	for _, r := range []float64{0, 0.999} {
		b := backoff{jitter: func() float64 { return r }}
		for i := range 12 {
			d := b.next()
			if d < retryMin || d > retryMax {
				t.Fatalf("jitter %v step %d gave %v", r, i, d)
			}
		}
	}
	lo, hi := backoff{attempt: 3, jitter: func() float64 { return 0 }}, backoff{attempt: 3, jitter: func() float64 { return 0.999 }}
	if a, b := lo.next(), hi.next(); a >= b || a < 6*time.Second || b > 10*time.Second {
		t.Fatalf("8s step jitter range %v..%v", a, b)
	}
}

// fakeClock advances only when told. Its sleeper advances both clocks.
type fakeClock struct {
	mu   sync.Mutex
	mono time.Duration
	wall time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{wall: time.Date(2026, 11, 28, 3, 0, 0, 0, time.UTC)}
}
func (c *fakeClock) Mono() time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.mono
}
func (c *fakeClock) Wall() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.wall
}
func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.mono += d
	c.wall = c.wall.Add(d)
	c.mu.Unlock()
}

// sleepMac moves the wall clock only, as macOS does while asleep.
func (c *fakeClock) sleepMac(d time.Duration) {
	c.mu.Lock()
	c.wall = c.wall.Add(d)
	c.mu.Unlock()
}

func token43() string {
	var b [32]byte
	rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}

// stubRelay rotates refresh tokens like the relay. With grace it also accepts
// the previous token until the successor is used (#218). dropNext commits a
// refresh and then aborts the response, as a lost reply during sleep would.
type stubRelay struct {
	*httptest.Server
	mu                sync.Mutex
	user, device      string
	access, current   string
	previous          string
	successorUsed     bool
	grace             bool
	refreshStatus     int // forced failure status; 0 is normal
	dropNext          atomic.Bool
	refreshes         atomic.Int32
	issued            []string
	lastRefreshCaller atomic.Int64
}

func newStubRelay(t *testing.T, grace bool) *stubRelay {
	r := &stubRelay{user: "u-alice", device: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", grace: grace}
	r.access, r.current = token43(), token43()
	r.issued = []string{r.access, r.current}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/auth/refresh", func(w http.ResponseWriter, req *http.Request) {
		r.refreshes.Add(1)
		var in struct {
			Refresh string `json:"refresh_token"`
		}
		_ = json.NewDecoder(req.Body).Decode(&in)
		r.mu.Lock()
		if r.refreshStatus != 0 {
			r.mu.Unlock()
			http.Error(w, "{}", r.refreshStatus)
			return
		}
		ok := in.Refresh == r.current || (r.grace && in.Refresh == r.previous && r.previous != "" && !r.successorUsed)
		if !ok {
			r.mu.Unlock()
			http.Error(w, `{"error":"Unauthorized"}`, http.StatusUnauthorized)
			return
		}
		if in.Refresh == r.current {
			r.previous = r.current
		}
		r.access, r.current, r.successorUsed = token43(), token43(), false
		r.issued = append(r.issued, r.access, r.current)
		s := identity.Session{User: r.user, Device: r.device, AccessToken: r.access, RefreshToken: r.current, ExpiresAt: time.Now().Add(15 * time.Minute)}
		r.mu.Unlock()
		if r.dropNext.CompareAndSwap(true, false) {
			panic(http.ErrAbortHandler)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(s)
	})
	authorized := func(w http.ResponseWriter, req *http.Request) bool {
		r.mu.Lock()
		defer r.mu.Unlock()
		if req.Header.Get("Authorization") != "Bearer "+r.access {
			http.Error(w, `{"error":"Unauthorized"}`, http.StatusUnauthorized)
			return false
		}
		r.successorUsed = true
		return true
	}
	lease := func(w http.ResponseWriter, req *http.Request) {
		if authorized(w, req) {
			json.NewEncoder(w).Encode(control.Lease{Session: "lease-1", Generation: 1, ExpiresAt: time.Now().Add(time.Minute)})
		}
	}
	mux.HandleFunc("POST /v1/session", lease)
	mux.HandleFunc("PUT /v1/session", lease)
	mux.HandleFunc("GET /v1/inbox", func(w http.ResponseWriter, req *http.Request) {
		if authorized(w, req) {
			select {
			case <-req.Context().Done():
			case <-time.After(100 * time.Millisecond):
			}
			w.Write([]byte(`{"children":[]}`))
		}
	})
	mux.HandleFunc("PUT /v1/profile", func(w http.ResponseWriter, req *http.Request) {
		if authorized(w, req) {
			w.Write([]byte(`{}`))
		}
	})
	r.Server = httptest.NewUnstartedServer(mux)
	r.Server.Config.ErrorLog = nil
	r.StartTLS()
	t.Cleanup(r.Close)
	return r
}

func (r *stubRelay) roots() *x509.CertPool {
	p := x509.NewCertPool()
	p.AddCert(r.Certificate())
	return p
}

// stubAgent prepares an agent whose stored session needs a refresh now.
func stubAgent(t *testing.T, r *stubRelay, mutate func(*Config)) *Agent {
	t.Helper()
	dir := t.TempDir()
	secrets, err := devicekeys.Directory(filepath.Join(dir, "secrets"))
	if err != nil {
		t.Fatal(err)
	}
	keys, err := devicekeys.Generate()
	if err != nil {
		t.Fatal(err)
	}
	r.mu.Lock()
	seed := credentials{Keys: keys, Session: identity.Session{User: r.user, Device: r.device, AccessToken: r.access, RefreshToken: r.current, ExpiresAt: time.Now().Add(-time.Second)}}
	r.mu.Unlock()
	raw, _ := json.Marshal(seed)
	if err = secrets.Save(raw); err != nil {
		t.Fatal(err)
	}
	cfg := Config{Relay: r.URL, Dir: filepath.Join(dir, "device"), Roots: r.roots(), Secrets: secrets, OpenBrowser: func(string) error { return nil }}
	if mutate != nil {
		mutate(&cfg)
	}
	a, err := prepareAgent(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.Close)
	return a
}

func agentSummary(a *Agent) ServerSummary {
	m := &Manager{agents: map[string]*Agent{"s": a}, certChanged: map[string]bool{}}
	return m.summary(Server{ID: "s"})
}

func waitState(t *testing.T, a *Agent, want string, within time.Duration) ServerSummary {
	t.Helper()
	end := time.Now().Add(within)
	for {
		s := agentSummary(a)
		if s.State == want {
			return s
		}
		if time.Now().After(end) {
			t.Fatalf("state %q (error %q), want %q", s.State, s.Error, want)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func TestDroppedRefreshWithoutGraceSignsOut(t *testing.T) {
	r := newStubRelay(t, false)
	a := stubAgent(t, r, nil)
	r.dropNext.Store(true)
	a.start()
	s := waitState(t, a, "signedOut", 5*time.Second)
	if s.Error != sessionEndedText || s.SignedIn {
		t.Fatalf("summary %+v", s)
	}
	if n := r.refreshes.Load(); n != 2 {
		t.Fatalf("refresh calls %d, want the lost one and one retry", n)
	}
	raw, err := a.cfg.Secrets.Load()
	if err != nil {
		t.Fatal(err)
	}
	var stored credentials
	if err = json.Unmarshal(raw, &stored); err != nil || stored.Keys == nil || stored.Session.User != "" || stored.Session.RefreshToken != "" {
		t.Fatalf("stored credentials keep the dead session or lost keys: %+v %v", stored.Session, err)
	}
	time.Sleep(2500 * time.Millisecond)
	if n := r.refreshes.Load(); n != 2 {
		t.Fatalf("kept refreshing after sign-out: %d calls", n)
	}
	if got := agentSummary(a); got.State != "signedOut" || got.Error != sessionEndedText {
		t.Fatalf("problem overwritten: %+v", got)
	}
	// The tray's Sign in still works from here.
	res, err := a.startLogin("", "")
	if err != nil || res == nil {
		t.Fatalf("sign-in refused after a terminal refresh: %v", err)
	}
}

func TestDroppedRefreshWithGraceRecovers(t *testing.T) {
	r := newStubRelay(t, true)
	a := stubAgent(t, r, nil)
	r.dropNext.Store(true)
	a.start()
	s := waitState(t, a, "online", 5*time.Second)
	if s.Error != "" {
		t.Fatalf("problem left after recovery: %q", s.Error)
	}
	if n := r.refreshes.Load(); n != 2 {
		t.Fatalf("refresh calls %d", n)
	}
	a.mu.Lock()
	got := a.creds.Session.RefreshToken
	a.mu.Unlock()
	r.mu.Lock()
	want := r.current
	r.mu.Unlock()
	if got != want {
		t.Fatal("agent does not hold the relay's current refresh token")
	}
}

func TestTransientRefreshFailuresBackOff(t *testing.T) {
	r := newStubRelay(t, false)
	r.refreshStatus = http.StatusServiceUnavailable
	clk := newFakeClock()
	var mu sync.Mutex
	var waits []time.Duration
	a := stubAgent(t, r, func(c *Config) {
		c.clock = clk
		c.sleep = func(ctx context.Context, d time.Duration) bool {
			mu.Lock()
			waits = append(waits, d)
			n := len(waits)
			mu.Unlock()
			clk.advance(d)
			return n < 9 && ctx.Err() == nil
		}
	})
	a.receiveLoop()
	mu.Lock()
	defer mu.Unlock()
	if r.refreshes.Load() != 9 {
		t.Fatalf("%d refresh calls for %d waits", r.refreshes.Load(), len(waits))
	}
	prev := time.Duration(0)
	for i, d := range waits[:9] {
		if d < retryMin || d > retryMax {
			t.Fatalf("wait %d is %v: %v", i, d, waits)
		}
		if i > 0 && i < 6 && d <= prev {
			t.Fatalf("wait %d did not grow: %v", i, waits)
		}
		prev = d
	}
	if waits[8] < 48*time.Second {
		t.Fatalf("schedule did not reach the cap: %v", waits)
	}
	s := agentSummary(a)
	if s.SignedIn != true || s.Error == "" {
		t.Fatalf("transient failure not shown: %+v", s)
	}
}

func TestRefreshGateWaitsAndRetriesAfterWake(t *testing.T) {
	r := newStubRelay(t, false)
	r.refreshStatus = http.StatusBadGateway
	clk := newFakeClock()
	a := stubAgent(t, r, func(c *Config) { c.clock = clk })
	ctx := t.Context()
	_, err := a.getSession(ctx)
	var re *refreshError
	if !errors.As(err, &re) || re.terminal || r.refreshes.Load() != 1 {
		t.Fatalf("first failure %v, %d calls", err, r.refreshes.Load())
	}
	for range 5 {
		if _, err = a.getSession(ctx); !errors.As(err, &re) || re.retryIn <= 0 {
			t.Fatalf("gated call returned %v", err)
		}
	}
	if r.refreshes.Load() != 1 {
		t.Fatalf("gate let %d calls through", r.refreshes.Load())
	}
	clk.advance(re.retryIn)
	a.getSession(ctx)
	if r.refreshes.Load() != 2 {
		t.Fatalf("no retry once the delay passed: %d", r.refreshes.Load())
	}
	// A long sleep moves only the wall clock. The next call retries at once.
	clk.sleepMac(time.Hour)
	a.getSession(ctx)
	if r.refreshes.Load() != 3 {
		t.Fatalf("no retry after wake: %d", r.refreshes.Load())
	}
	r.mu.Lock()
	r.refreshStatus = 0
	r.mu.Unlock()
	clk.advance(retryMax)
	if s, err := a.getSession(ctx); err != nil || s.RefreshToken == "" {
		t.Fatalf("recovery failed: %v", err)
	}
	if a.refresh.last != nil {
		t.Fatal("success did not reset the gate")
	}
}

func TestPauseReturnsEarlyAfterWake(t *testing.T) {
	clk := newFakeClock()
	a := &Agent{cfg: Config{clock: clk}}
	go func() {
		time.Sleep(50 * time.Millisecond)
		clk.sleepMac(10 * time.Minute)
	}()
	start := time.Now()
	if !a.pause(t.Context(), "test", time.Hour) {
		t.Fatal("pause canceled")
	}
	if time.Since(start) > 3*wakePoll {
		t.Fatalf("pause ignored the wake for %v", time.Since(start))
	}
}

func TestTerminalRefreshKeepsANewerSession(t *testing.T) {
	keys, err := devicekeys.Generate()
	if err != nil {
		t.Fatal(err)
	}
	store, err := devicekeys.Directory(filepath.Join(t.TempDir(), "s"))
	if err != nil {
		t.Fatal(err)
	}
	newer := identity.Session{User: "u", Device: "d", RefreshToken: "new"}
	a := &Agent{cfg: Config{Secrets: store, Dir: t.TempDir()}, creds: credentials{Keys: keys, Session: newer}}
	a.endSession("old", 401)
	if a.creds.Session != newer || a.problem != "" {
		t.Fatalf("a stale terminal refresh cleared a newer session: %+v %q", a.creds.Session, a.problem)
	}
	a.endSession("new", 401)
	if a.creds.Session.User != "" || a.creds.Keys != keys || a.problem != sessionEndedText {
		t.Fatalf("terminal refresh: %+v %q", a.creds.Session, a.problem)
	}
}
