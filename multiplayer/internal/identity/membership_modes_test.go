package identity

import (
	"errors"
	"net/http"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"github.com/go-jose/go-jose/v4/jwt"
)

// TestInviteModeKeepsMembers: switching a relay to invite governs who may join,
// not who already belongs. An allowlist stays strict, and suspension always wins.
func TestInviteModeKeepsMembers(t *testing.T) {
	ctx := t.Context()
	pool := identityTestPool(t)
	f := issuer(t, "")
	// No allowed emails: the relay starts open.
	auth, err := New(ctx, pool, Config{Issuer: f.URL, ClientID: "native", AllowLoopbackHTTP: true, Admins: []string{"admin@example.test"}})
	if err != nil {
		t.Fatal(err)
	}
	s, err := control.New(ctx, pool, "social", auth.Authenticate, auth.DeviceActive)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	auth.Register(mux)
	mux.Handle("/v1/", s.Handler())
	edge := identityEdge(t, mux)

	type device struct {
		Client
		finish func(subject string) (Session, error)
	}
	newDevice := func() device {
		c, keys := identityClient(t, edge)
		d := device{Client: c}
		d.finish = func(subject string) (Session, error) {
			pub, err := keys.Public()
			if err != nil {
				t.Fatal(err)
			}
			var ch challenge
			if err := c.request(ctx, "POST", "/v1/auth/challenge", "", map[string]any{"public": pub}, &ch); err != nil {
				t.Fatal(err)
			}
			proof, err := jwt.Signed(f.signer).Claims(map[string]any{
				"iss": f.name, "sub": subject, "aud": "native", "exp": time.Now().Add(time.Hour).Unix(),
				"nonce": ch.Nonce, "email": subject + "@example.test", "email_verified": true,
			}).Serialize()
			if err != nil {
				t.Fatal(err)
			}
			var session Session
			err = c.request(ctx, "POST", "/v1/auth/finish", "", map[string]string{"id_token": proof}, &session)
			return session, err
		}
		return d
	}
	status := func(err error) int {
		var h HTTPError
		if errors.As(err, &h) {
			return h.Status
		}
		if err == nil {
			return http.StatusOK
		}
		t.Fatalf("unexpected error %v", err)
		return 0
	}

	admin := newDevice()
	adminSession, err := admin.finish("admin")
	if err != nil {
		t.Fatal(err)
	}
	setMode := func(mode string, allowed ...string) {
		t.Helper()
		if allowed == nil {
			allowed = []string{}
		}
		if err := admin.request(ctx, "PUT", "/v1/admin/membership", adminSession.AccessToken, map[string]any{
			"mode": mode, "allowedEmails": allowed, "admins": []string{"admin@example.test"},
		}, nil); err != nil {
			t.Fatalf("set %s: %v", mode, err)
		}
	}
	me := func(d device, sess Session) int {
		t.Helper()
		return status(d.request(ctx, "GET", "/v1/me", sess.AccessToken, nil, nil))
	}

	// Two people join while the relay is open.
	member := newDevice()
	memberSession, err := member.finish("member")
	if err != nil {
		t.Fatal(err)
	}
	other := newDevice()
	otherSession, err := other.finish("other")
	if err != nil {
		t.Fatal(err)
	}

	// Invite: existing members keep working, refresh and sign in again unlisted.
	setMode("invite")
	if got := me(member, memberSession); got != http.StatusOK {
		t.Fatalf("member after switching to invite: HTTP %d", got)
	}
	refreshed, err := member.Refresh(ctx, memberSession.RefreshToken)
	if err != nil {
		t.Fatalf("member refresh in invite mode: %v", err)
	}
	if got := me(member, refreshed); got != http.StatusOK {
		t.Fatalf("member after refresh: HTTP %d", got)
	}
	if _, err := newDevice().finish("member"); err != nil {
		t.Fatalf("member signing in from a new Mac in invite mode: %v", err)
	}
	// A newcomer still needs an invite or an approved request.
	if _, err := newDevice().finish("newcomer"); status(err) != http.StatusForbidden {
		t.Fatalf("newcomer in invite mode: %v", err)
	}

	// Allowlist stays strict: only listed members keep access.
	setMode("allowlist", "other@example.test")
	if got := me(member, refreshed); got != http.StatusUnauthorized {
		t.Fatalf("unlisted member in allowlist mode: HTTP %d", got)
	}
	if got := me(other, otherSession); got != http.StatusOK {
		t.Fatalf("listed member in allowlist mode: HTTP %d", got)
	}
	if _, err := newDevice().finish("member"); status(err) != http.StatusForbidden {
		t.Fatalf("unlisted member signing in under an allowlist: %v", err)
	}

	// Back to invite, the member is in again; suspension still removes them.
	setMode("invite")
	if got := me(member, refreshed); got != http.StatusOK {
		t.Fatalf("member after returning to invite: HTTP %d", got)
	}
	if _, err := pool.Exec(ctx, "UPDATE mp_members SET suspended=true WHERE user_id=$1", memberSession.User); err != nil {
		t.Fatal(err)
	}
	if got := me(member, refreshed); got != http.StatusUnauthorized {
		t.Fatalf("suspended member in invite mode: HTTP %d", got)
	}
	if _, err := newDevice().finish("member"); status(err) != http.StatusForbidden {
		t.Fatalf("suspended member signing in: %v", err)
	}
	// The admin was never affected.
	if got := me(admin, adminSession); got != http.StatusOK {
		t.Fatalf("admin: HTTP %d", got)
	}
}
