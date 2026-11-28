package control

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

func TestInboxLeaseAcknowledgesReadinessOnce(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	const user, device = "inbox-owner", "inbox-device"
	socialRequest(t, h, user, device, http.MethodPut, "/v1/profile", map[string]string{"handle": user}, 200)
	open := func(h http.Handler) Lease {
		t.Helper()
		response := socialRequest(t, h, user, device, http.MethodPost, "/v1/session", nil, 200)
		var lease Lease
		if err := json.NewDecoder(response.Body).Decode(&lease); err != nil {
			t.Fatal(err)
		}
		return lease
	}
	inbox := func(lease Lease) string {
		return fmt.Sprintf("/v1/inbox?generation=%d&session=%s", lease.Generation, lease.Session)
	}
	version := func(wantReady bool) string {
		t.Helper()
		var revision string
		var ready bool
		if err := s.pool.QueryRow(t.Context(), `SELECT xmin::text, ready FROM mp_leases WHERE device=$1`, device).Scan(&revision, &ready); err != nil {
			t.Fatal(err)
		}
		if ready != wantReady {
			t.Fatalf("lease ready = %t, want %t", ready, wantReady)
		}
		return revision
	}

	lease := open(h)
	before := version(false)
	socialRequest(t, h, user, device, http.MethodGet, inbox(lease), nil, 200)
	acknowledged := version(true)
	if acknowledged == before {
		t.Fatal("initial inbox poll did not acknowledge readiness")
	}
	for i := range 20 {
		socialRequest(t, h, user, device, http.MethodGet, inbox(lease), nil, 200)
		if got := version(true); got != acknowledged {
			t.Fatalf("empty poll %d replaced the ready lease row: %s -> %s", i+1, acknowledged, got)
		}
	}

	// An empty long poll rechecks on the fallback timer on a different edge.
	other, err := New(t.Context(), s.pool, "other-edge", s.auth, nil)
	if err != nil {
		t.Fatal(err)
	}
	otherHandler := other.Handler()
	socialRequest(t, otherHandler, user, device, http.MethodGet, inbox(lease)+"&wait=1", nil, 200)
	if got := version(true); got != acknowledged {
		t.Fatalf("long poll replaced the ready lease row: %s -> %s", acknowledged, got)
	}

	newLease := open(otherHandler)
	beforeTakeoverPoll := version(false)
	socialRequest(t, h, user, device, http.MethodGet, inbox(lease), nil, 409)
	wrongSession := newLease
	wrongSession.Session = "wrong-session"
	socialRequest(t, h, user, device, http.MethodGet, inbox(wrongSession), nil, 409)
	if got := version(false); got != beforeTakeoverPoll {
		t.Fatal("an invalid inbox poll replaced the new lease row")
	}
	socialRequest(t, h, user, device, http.MethodGet, inbox(newLease), nil, 200)
	if got := version(true); got == beforeTakeoverPoll {
		t.Fatal("replacement generation did not acknowledge readiness")
	}
	if _, err := s.pool.Exec(t.Context(), `UPDATE mp_leases SET expires_at=clock_timestamp() WHERE device=$1`, device); err != nil {
		t.Fatal(err)
	}
	expired := version(true)
	socialRequest(t, h, user, device, http.MethodGet, inbox(newLease), nil, 409)
	if got := version(true); got != expired {
		t.Fatal("expired inbox poll replaced the lease row")
	}
}
