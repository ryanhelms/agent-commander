package identity

import (
	"errors"
	"net/http"
	"slices"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"github.com/go-jose/go-jose/v4/jwt"
)

func TestInviteEnrollment(t *testing.T) {
	ctx := t.Context()
	pool := identityTestPool(t)
	f := issuer(t, "")
	auth, err := New(ctx, pool, Config{Issuer: f.URL, ClientID: "native", AllowLoopbackHTTP: true,
		Admins: []string{"admin@example.test"}, AllowedEmails: []string{"listed@example.test"}})
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
		keys *devicekeys.Keys
	}
	newDevice := func() device {
		c, k := identityClient(t, edge)
		return device{c, k}
	}
	// Prepare independently so two verified, challenge-bound sign-ins can finish concurrently.
	prepare := func(d device, subject string, verified bool, invite string) func() (Session, error) {
		t.Helper()
		pub, err := d.keys.Public()
		if err != nil {
			t.Fatal(err)
		}
		var ch challenge
		err = d.request(ctx, "POST", "/v1/auth/challenge", "", map[string]any{"public": pub, "invite": invite}, &ch)
		if err != nil || !ch.Email {
			t.Fatalf("challenge before email verification = %+v, %v", ch, err)
		}
		proof, err := jwt.Signed(f.signer).Claims(map[string]any{
			"iss": f.name, "sub": subject, "aud": "native", "exp": time.Now().Add(time.Hour).Unix(),
			"nonce": ch.Nonce, "email": subject + "@Example.Test", "email_verified": verified,
		}).Serialize()
		if err != nil {
			t.Fatal(err)
		}
		return func() (Session, error) {
			var session Session
			err := d.request(ctx, "POST", "/v1/auth/finish", "", map[string]string{"id_token": proof}, &session)
			return session, err
		}
	}
	requireCode := func(err error, code int) {
		t.Helper()
		var httpErr HTTPError
		if !errors.As(err, &httpErr) || httpErr.Status != code {
			t.Fatalf("expected HTTP %d, got %v", code, err)
		}
	}
	admin := newDevice()
	session, err := prepare(admin, "admin", true, "")()
	if err != nil {
		t.Fatal(err)
	}
	adminCall := func(method, path string, in, out any) {
		t.Helper()
		if err := admin.request(ctx, method, path, session.AccessToken, in, out); err != nil {
			t.Fatalf("%s %s: %v", method, path, err)
		}
	}
	createInvite := func() string {
		var invite struct{ Code string }
		adminCall("POST", "/v1/invites", map[string]int{"maxUses": 1, "ttlHours": 1}, &invite)
		return invite.Code
	}
	setMode := func(mode string) {
		adminCall("PUT", "/v1/admin/membership", map[string]any{
			"mode": mode, "allowedEmails": []string{"listed@example.test"}, "admins": []string{"admin@example.test"},
		}, nil)
	}
	var me struct {
		Admin bool
		Mode  string
	}
	adminCall("GET", "/v1/me", nil, &me)
	if !me.Admin || me.Mode != "allowlist" {
		t.Fatalf("verified admin = %+v", me)
	}
	setMode("invite")
	listed := newDevice()
	_, err = prepare(listed, "listed", true, "")()
	requireCode(err, 403)

	code := createInvite()
	guest := newDevice()
	stale := prepare(guest, "guest", true, code)
	current := prepare(guest, "guest", true, "")
	_, err = stale()
	requireCode(err, 401)
	_, err = current()
	requireCode(err, 403)
	_, err = prepare(guest, "guest", false, code)()
	requireCode(err, 403)
	_, err = prepare(admin, "other-owner", true, code)()
	requireCode(err, 403)
	expired := createInvite()
	if _, err := pool.Exec(ctx, "UPDATE mp_invites SET expires_at=now() WHERE code=$1", expired); err != nil {
		t.Fatal(err)
	}
	_, err = prepare(guest, "guest", true, expired)()
	requireCode(err, 403)

	type candidate struct {
		device
		subject string
	}
	type result struct {
		candidate
		Session
		err error
	}
	results := make(chan result, 2)
	start := make(chan struct{})
	for _, c := range []candidate{{guest, "guest"}, {newDevice(), "other"}} {
		finish := prepare(c.device, c.subject, true, code)
		go func() {
			<-start
			session, err := finish()
			results <- result{c, session, err}
		}()
	}
	close(start)
	first, second := <-results, <-results
	if first.err != nil {
		first, second = second, first
	}
	if first.err != nil {
		t.Fatalf("no one could redeem the single-use invite: %v, %v", first.err, second.err)
	}
	requireCode(second.err, 403)
	_, err = prepare(newDevice(), "late", true, code)()
	requireCode(err, 403)

	var uses int
	if err := pool.QueryRow(ctx, "SELECT uses FROM mp_invites WHERE code=$1", code).Scan(&uses); err != nil || uses != 1 {
		t.Fatalf("uses = %d, %v", uses, err)
	}
	again, err := prepare(newDevice(), first.subject, true, "")()
	if err != nil || again.User != first.User {
		t.Fatalf("returning member on a second device = %q, %v", again.User, err)
	}
	var info struct {
		AllowedEmails []string
		MemberCount   int
	}
	adminCall("GET", "/v1/admin/membership", nil, &info)
	if info.MemberCount != 2 || !slices.Equal(info.AllowedEmails, []string{"listed@example.test", first.subject + "@example.test"}) {
		t.Fatalf("membership after invite = %+v", info)
	}
	var user control.User
	err = first.request(ctx, "PUT", "/v1/profile", first.AccessToken, map[string]string{"handle": first.subject}, &user)
	if err != nil || user.ContactKey != emailHash(first.subject+"@example.test") {
		t.Fatalf("enrolled contact key = %q, %v", user.ContactKey, err)
	}
	var feed struct{ Events []control.Event }
	adminCall("GET", "/v1/events", nil, &feed)
	if len(feed.Events) != 1 || feed.Events[0].Kind != "member.joined" || feed.Events[0].Actor != first.subject {
		t.Fatalf("member activity = %+v", feed)
	}

	setMode("allowlist")
	// Removing the email from the policy invalidates credentials already issued to it.
	err = first.request(ctx, "GET", "/v1/me", first.AccessToken, nil, nil)
	requireCode(err, 401)
	_, err = first.Refresh(ctx, first.RefreshToken)
	requireCode(err, 401)
	if _, err := prepare(listed, "listed", true, "")(); err != nil {
		t.Fatalf("allowlisted first enrollment: %v", err)
	}
}
