package control

import (
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestMembershipRoutes(t *testing.T) {
	s := newSocialFixture(t)
	ctx := t.Context()
	seed := func(allowed, admins []string) {
		t.Helper()
		if err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
			return InitMembership(ctx, tx, allowed, admins)
		}); err != nil {
			t.Fatal(err)
		}
	}
	seed([]string{"Member@example.test", "member@example.test"}, []string{"Admin@example.test"})
	if _, err := s.pool.Exec(ctx, "INSERT INTO mp_members(user_id) VALUES ('admin'),('member')"); err != nil {
		t.Fatal(err)
	}
	h := s.Handler()
	call := func(user, method, path string, payload any, status int, out any) {
		t.Helper()
		w := socialRequest(t, h, user, "device", method, path, payload, status)
		if out != nil {
			if err := json.Unmarshal(w.Body.Bytes(), out); err != nil {
				t.Fatal(err)
			}
		}
	}

	const settings = "/v1/admin/membership"
	want := membershipInfo{membershipSettings{"allowlist", []string{"member@example.test"}, []string{"admin@example.test"}}, 2}
	var got membershipInfo
	call("admin", "GET", settings, nil, 200, &got)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("seeded membership = %+v, want %+v", got, want)
	}
	var access memberAccess
	call("admin", "GET", "/v1/me", nil, 200, &access)
	if !access.Admin || access.Mode != "allowlist" {
		t.Fatalf("admin access = %+v", access)
	}
	call("member", "GET", "/v1/me", nil, 200, &access)
	if access.Admin || access.Mode != "allowlist" {
		t.Fatalf("member access = %+v", access)
	}
	call("member", "GET", settings, nil, http.StatusForbidden, nil)
	call("member", "PUT", settings, want.membershipSettings, http.StatusForbidden, nil)
	call("admin", "PUT", settings, membershipSettings{"open", []string{}, []string{}}, http.StatusBadRequest, nil)
	call("admin", "PUT", settings, membershipSettings{"invalid", []string{}, want.Admins}, http.StatusBadRequest, nil)
	call("admin", "PUT", settings, membershipSettings{"open", []string{"not-an-email"}, want.Admins}, http.StatusBadRequest, nil)
	call("member", "POST", "/v1/invites", map[string]int{}, http.StatusForbidden, nil)
	for _, mode := range []string{"invite", "open"} {
		want.Mode = mode
		want.AllowedEmails = []string{}
		call("admin", "PUT", settings, want.membershipSettings, 200, &got)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("updated membership = %+v, want %+v", got, want)
		}
		call("member", "GET", "/v1/me", nil, 200, &access)
		if access.Admin || access.Mode != mode {
			t.Fatalf("updated access = %+v", access)
		}
		issuer := "member"
		if mode == "invite" {
			call("member", "POST", "/v1/invites", map[string]int{}, http.StatusForbidden, nil)
			issuer = "admin"
		}
		var code invite
		start := time.Now().Add(2 * time.Hour)
		call(issuer, "POST", "/v1/invites", map[string]int{"maxUses": 3, "ttlHours": 2}, 200, &code)
		if code.Code == "" || code.MaxUses != 3 || code.Uses != 0 || code.ExpiresAt.Before(start.Add(-time.Second)) || code.ExpiresAt.After(time.Now().Add(2*time.Hour+time.Second)) {
			t.Fatalf("issued invite = %+v", code)
		}
	}
	var defaults invite
	call("member", "POST", "/v1/invites", map[string]int{}, 200, &defaults)
	if defaults.MaxUses < 1 || !defaults.ExpiresAt.After(time.Now()) {
		t.Fatalf("default invite = %+v", defaults)
	}
	call("admin", "POST", "/v1/invites", map[string]int{"ttlHours": 0}, http.StatusBadRequest, nil)
	call("admin", "POST", "/v1/invites", map[string]int{"maxUses": -1}, http.StatusBadRequest, nil)
	call("", "POST", "/v1/invites", map[string]int{}, http.StatusUnauthorized, nil)

	// Replace the original admin, then restart with the previous edge config.
	want.Admins = []string{"member@example.test"}
	call("admin", "PUT", settings, want.membershipSettings, 200, &got)
	seed([]string{"stale@example.test"}, []string{"admin@example.test"})
	call("admin", "GET", settings, nil, http.StatusForbidden, nil)
	call("member", "GET", settings, nil, 200, &got)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("membership after restart = %+v, want %+v", got, want)
	}
}

func TestOpenMembershipSeed(t *testing.T) {
	s := newSocialFixture(t)
	ctx := t.Context()
	if err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		return InitMembership(ctx, tx, nil, []string{"admin@example.test"})
	}); err != nil {
		t.Fatal(err)
	}
	w := socialRequest(t, s.Handler(), "admin", "device", "GET", "/v1/admin/membership", nil, 200)
	var got membershipInfo
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Mode != "open" || got.AllowedEmails == nil || len(got.AllowedEmails) != 0 || got.MemberCount != 0 {
		t.Fatalf("initial open membership = %+v", got)
	}
}
