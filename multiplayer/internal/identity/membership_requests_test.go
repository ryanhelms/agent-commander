package identity

import (
	"errors"
	"fmt"
	"net/http"
	"slices"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"github.com/go-jose/go-jose/v4/jwt"
)

func TestMembershipRequests(t *testing.T) {
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

	// finish runs one challenge-bound sign-in for subject on the device behind c.
	type device struct {
		Client
		finish func(subject string, verified bool) (Session, error)
	}
	newDevice := func() device {
		c, keys := identityClient(t, edge)
		d := device{Client: c}
		d.finish = func(subject string, verified bool) (Session, error) {
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
				"nonce": ch.Nonce, "email": subject + "@Example.Test", "email_verified": verified,
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
	refusal := func(err error) HTTPError {
		t.Helper()
		var h HTTPError
		if !errors.As(err, &h) || h.Status != http.StatusForbidden {
			t.Fatalf("expected a 403 refusal, got %v", err)
		}
		return h
	}
	requireStatus := func(err error, code int) {
		t.Helper()
		var h HTTPError
		if !errors.As(err, &h) || h.Status != code {
			t.Fatalf("expected HTTP %d, got %v", code, err)
		}
	}

	admin := newDevice()
	adminSession, err := admin.finish("admin", true)
	if err != nil {
		t.Fatal(err)
	}
	adminCall := func(method, path string, in, out any) error {
		return admin.request(ctx, method, path, adminSession.AccessToken, in, out)
	}
	pending := func() []MembershipRequest {
		t.Helper()
		var list struct{ Requests []MembershipRequest }
		if err := adminCall("GET", "/v1/admin/membership-requests", nil, &list); err != nil {
			t.Fatal(err)
		}
		return list.Requests
	}
	setMode := func(mode string) {
		t.Helper()
		var m struct{ AllowedEmails []string }
		if err := adminCall("GET", "/v1/admin/membership", nil, &m); err != nil {
			t.Fatal(err)
		}
		if err := adminCall("PUT", "/v1/admin/membership", map[string]any{
			"mode": mode, "allowedEmails": m.AllowedEmails, "admins": []string{"admin@example.test"},
		}, nil); err != nil {
			t.Fatal(err)
		}
	}

	// A refused, verified stranger may ask; an unverified one may not.
	stranger := newDevice()
	_, err = stranger.finish("stranger", false)
	if refusal(err).Requestable {
		t.Fatal("an unverified email was offered a request")
	}
	_, err = stranger.finish("stranger", true)
	if !refusal(err).Requestable {
		t.Fatal("a verified refusal was not requestable")
	}

	// Only the refused device can turn its refusal into a request.
	other := newDevice()
	_, err = other.RequestMembership(ctx, "hello")
	requireStatus(err, http.StatusNotFound)
	_, err = other.MyMembershipRequest(ctx)
	requireStatus(err, http.StatusNotFound)

	req, err := stranger.RequestMembership(ctx, "  Hi\x00, I'm on the build team  ")
	if err != nil || req.Status != "pending" || req.Note != "Hi, I'm on the build team" || req.Email != "" {
		t.Fatalf("request = %+v, %v", req, err)
	}
	if mine, err := stranger.MyMembershipRequest(ctx); err != nil || mine.Status != "pending" || mine.ID != req.ID {
		t.Fatalf("mine = %+v, %v", mine, err)
	}
	// The refusal is spent once used.
	_, err = stranger.RequestMembership(ctx, "again")
	requireStatus(err, http.StatusNotFound)

	// A listed member who is not an admin cannot see or decide requests.
	listed := newDevice()
	listedSession, err := listed.finish("listed", true)
	if err != nil {
		t.Fatal(err)
	}
	err = listed.request(ctx, "GET", "/v1/admin/membership-requests", listedSession.AccessToken, nil, nil)
	requireStatus(err, http.StatusForbidden)
	err = listed.request(ctx, "POST", "/v1/admin/membership-requests/"+req.ID+"/approve", listedSession.AccessToken, nil, nil)
	requireStatus(err, http.StatusForbidden)

	list := pending()
	if len(list) != 1 || list[0].ID != req.ID || list[0].Email != "stranger@example.test" || list[0].Note != req.Note {
		t.Fatalf("pending = %+v", list)
	}

	// Approval admits the stranger once and adds them to the allowlist.
	if err := adminCall("POST", "/v1/admin/membership-requests/"+req.ID+"/approve", nil, nil); err != nil {
		t.Fatal(err)
	}
	if err := adminCall("POST", "/v1/admin/membership-requests/"+req.ID+"/approve", nil, nil); err == nil {
		t.Fatal("approved a request twice")
	}
	if mine, _ := stranger.MyMembershipRequest(ctx); mine.Status != "approved" {
		t.Fatalf("after approval: %+v", mine)
	}
	if _, err := stranger.finish("stranger", true); err != nil {
		t.Fatalf("approved stranger refused: %v", err)
	}
	if mine, _ := stranger.MyMembershipRequest(ctx); mine.Status != "admitted" {
		t.Fatalf("after admission: %+v", mine)
	}
	var m struct{ AllowedEmails []string }
	if err := adminCall("GET", "/v1/admin/membership", nil, &m); err != nil || !slices.Contains(m.AllowedEmails, "stranger@example.test") {
		t.Fatalf("allowlist = %v, %v", m.AllowedEmails, err)
	}
	if len(pending()) != 0 {
		t.Fatal("decided request still pending")
	}

	// Invite mode: approval admits even though the allowlist alone would not.
	setMode("invite")
	guest := newDevice()
	_, err = guest.finish("guest", true)
	refusal(err)
	greq, err := guest.RequestMembership(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := adminCall("POST", "/v1/admin/membership-requests/"+greq.ID+"/approve", nil, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := guest.finish("guest", true); err != nil {
		t.Fatalf("approved guest refused in invite mode: %v", err)
	}

	// Denial: the person sees it, and cannot ask again until the cool-down ends.
	visitor := newDevice()
	_, err = visitor.finish("visitor", true)
	refusal(err)
	vreq, err := visitor.RequestMembership(ctx, "please")
	if err != nil {
		t.Fatal(err)
	}
	if err := adminCall("POST", "/v1/admin/membership-requests/"+vreq.ID+"/deny", nil, nil); err != nil {
		t.Fatal(err)
	}
	if mine, _ := visitor.MyMembershipRequest(ctx); mine.Status != "denied" {
		t.Fatalf("after denial: %+v", mine)
	}
	_, err = visitor.finish("visitor", true)
	refusal(err)
	_, err = visitor.RequestMembership(ctx, "please again")
	requireStatus(err, http.StatusTooManyRequests)
	if _, err := pool.Exec(ctx, "UPDATE mp_membership_requests SET decided_at=now()-interval '25 hours' WHERE id=$1", vreq.ID); err != nil {
		t.Fatal(err)
	}
	_, err = visitor.finish("visitor", true)
	refusal(err)
	if again, err := visitor.RequestMembership(ctx, "it has been a day"); err != nil || again.Status != "pending" {
		t.Fatalf("request after cool-down = %+v, %v", again, err)
	}

	// The queue has a cap.
	for i := range maxPendingRequests {
		if _, err := pool.Exec(ctx, `INSERT INTO mp_membership_requests(id,email,email_hash,device,status)
			VALUES ($1,$2,$3,'d','pending')`, fmt.Sprintf("fill-%d", i), fmt.Sprintf("fill%d@example.test", i), fmt.Sprintf("hash-%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	late := newDevice()
	_, err = late.finish("late", true)
	refusal(err)
	_, err = late.RequestMembership(ctx, "")
	requireStatus(err, http.StatusTooManyRequests)

	// A suspended member is refused without an offer to ask.
	if _, err := pool.Exec(ctx, "UPDATE mp_members SET suspended=true WHERE user_id=$1", listedSession.User); err != nil {
		t.Fatal(err)
	}
	_, err = listed.finish("listed", true)
	if refusal(err).Requestable {
		t.Fatal("a suspended member was offered a request")
	}
}
