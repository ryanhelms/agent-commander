package identity

import (
	"bytes"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
)

type graceHarness struct {
	t    *testing.T
	srv  *Server
	c    Client
	logs *bytes.Buffer
	mu   *sync.Mutex
}

func newGraceHarness(t *testing.T) (graceHarness, Session) {
	t.Helper()
	ctx := t.Context()
	pool := identityTestPool(t)
	f := issuer(t, "")
	var mu sync.Mutex
	logs := &bytes.Buffer{}
	logger := slog.New(slog.NewTextHandler(lockedWriter{&mu, logs}, nil))
	s, err := New(ctx, pool, Config{Issuer: f.URL, ClientID: "native", AllowLoopbackHTTP: true,
		AllowedEmails: []string{"tester@example.test"}, Logger: logger})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	s.Register(mux)
	edge := identityEdge(t, mux)
	c, keys := identityClient(t, edge)
	session, err := c.Login(ctx, keys, simulatedBrowser)
	if err != nil {
		t.Fatal(err)
	}
	return graceHarness{t: t, srv: s, c: c, logs: logs, mu: &mu}, session
}

type lockedWriter struct {
	mu *sync.Mutex
	b  *bytes.Buffer
}

func (w lockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.Write(p)
}

func (h graceHarness) log() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.logs.String()
}

func (h graceHarness) exec(sql string, args ...any) {
	h.t.Helper()
	if _, err := h.srv.pool.Exec(h.t.Context(), sql, args...); err != nil {
		h.t.Fatal(err)
	}
}

// A refresh whose response never reaches the device must not strand it, no
// matter how long the device sleeps before retrying or how many responses in
// a row are lost.
func TestRefreshSurvivesLostResponses(t *testing.T) {
	ctx := t.Context()
	h, first := newGraceHarness(t)
	// Each of these responses is "lost": the device never stores them.
	for i := 0; i < 3; i++ {
		if _, err := h.c.Refresh(ctx, first.RefreshToken); err != nil {
			t.Fatalf("lost response %d: previous token refused: %v", i, err)
		}
	}
	// Hours later, after the access token has long expired.
	h.exec("UPDATE mp_auth_devices SET access_expires=now()-interval '5 hours' WHERE device=$1", first.Device)
	recovered, err := h.c.Refresh(ctx, first.RefreshToken)
	if err != nil {
		t.Fatalf("recovery after sleep: %v", err)
	}
	if p, err := h.c.Lookup(ctx, recovered.AccessToken, recovered.Device); err != nil || p.User != first.User {
		t.Fatalf("recovered access token unusable: %v", err)
	}
	if _, err := h.c.Refresh(ctx, recovered.RefreshToken); err != nil {
		t.Fatalf("recovered refresh token unusable: %v", err)
	}
	// The successor has now been used: the original token is finally retired.
	if _, err := h.c.Refresh(ctx, first.RefreshToken); err == nil {
		t.Fatal("previous token accepted after its successor was used")
	}
	out := h.log()
	if !strings.Contains(out, "outcome=grace_reuse") || !strings.Contains(out, "outcome=unknown_token") {
		t.Fatalf("refresh outcomes not logged:\n%s", out)
	}
	for _, secret := range []string{first.RefreshToken, first.AccessToken, recovered.RefreshToken, recovered.AccessToken} {
		if strings.Contains(out, secret) {
			t.Fatal("relay log contains token material")
		}
	}
}

func TestRefreshPreviousTokenClearedBySignOut(t *testing.T) {
	ctx := t.Context()
	h, first := newGraceHarness(t)
	next, err := h.c.Refresh(ctx, first.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if err = h.c.SignOut(ctx, next.AccessToken); err != nil {
		t.Fatal(err)
	}
	if _, err = h.c.Refresh(ctx, first.RefreshToken); err == nil {
		t.Fatal("previous token survived sign-out")
	}
}

func TestRefreshRefusalReasons(t *testing.T) {
	ctx := t.Context()
	h, first := newGraceHarness(t)
	h.exec("UPDATE mp_auth_devices SET refresh_expires=now()-interval '1 second' WHERE device=$1", first.Device)
	if _, err := h.c.Refresh(ctx, first.RefreshToken); err == nil {
		t.Fatal("expired refresh accepted")
	}
	h.exec("UPDATE mp_auth_devices SET refresh_expires=now()+interval '1 day', revoked=true WHERE device=$1", first.Device)
	if _, err := h.c.Refresh(ctx, first.RefreshToken); err == nil {
		t.Fatal("revoked refresh accepted")
	}
	out := h.log()
	for _, want := range []string{"outcome=expired", "outcome=revoked"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %s in:\n%s", want, out)
		}
	}
	if strings.Contains(out, first.Device) {
		t.Fatal("relay log contains the full device ID")
	}
}

// Two refreshes racing on the same token both resolve without a server error,
// and the device ends with exactly one usable successor.
func TestConcurrentRefreshSameToken(t *testing.T) {
	ctx := t.Context()
	h, first := newGraceHarness(t)
	var wg sync.WaitGroup
	results := make([]Session, 2)
	errs := make([]error, 2)
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i], errs[i] = h.c.Refresh(ctx, first.RefreshToken)
		}()
	}
	wg.Wait()
	usable := 0
	for i := range 2 {
		if errs[i] != nil {
			var he HTTPError
			if !errors.As(errs[i], &he) || he.Status != http.StatusUnauthorized {
				t.Fatalf("racing refresh failed with %v", errs[i])
			}
			continue
		}
		if _, err := h.c.Lookup(ctx, results[i].AccessToken, results[i].Device); err == nil {
			usable++
		}
	}
	if usable != 1 {
		t.Fatalf("usable sessions after race = %d, want 1", usable)
	}
	// The original token still recovers, since neither successor was used.
	if _, err := h.c.Refresh(ctx, first.RefreshToken); err != nil {
		t.Fatalf("previous token after race: %v", err)
	}
}
