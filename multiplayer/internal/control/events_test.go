package control

import (
	"encoding/json"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestSocialEvents(t *testing.T) {
	ctx := t.Context()
	service := newSocialFixture(t)
	handler := service.Handler()
	call := func(user, method, path string, in any) {
		t.Helper()
		socialRequest(t, handler, user, user+"-device", method, path, in, 200)
	}
	feed := func(user, query string) []Event {
		t.Helper()
		w := socialRequest(t, handler, user, user+"-device", "GET", "/v1/events"+query, nil, 200)
		var result struct {
			Events []Event `json:"events"`
		}
		if err := json.NewDecoder(w.Body).Decode(&result); err != nil || result.Events == nil {
			t.Fatalf("invalid events array for %s: %v", user, err)
		}
		return result.Events
	}
	for _, user := range []string{"alice", "bob", "cara"} {
		call(user, "PUT", "/v1/profile", map[string]string{"handle": user})
	}

	call("alice", "POST", "/v1/friends/bob", nil)
	call("alice", "POST", "/v1/friends/bob", nil)
	socialRequest(t, handler, "alice", "alice-device", "PUT", "/v1/friends/bob", nil, 403)
	call("bob", "PUT", "/v1/friends/alice", nil)
	call("bob", "PUT", "/v1/friends/alice", nil)
	call("alice", "PUT", "/v1/resources/worker", map[string]any{"kind": "agent", "name": "Worker", "actions": []string{"ask.v1"}})
	call("alice", "PUT", "/v1/grants/worker/bob", map[string]any{"actions": []string{"ask.v1"}, "expires_at": time.Now().Add(time.Hour), "max_uses": 5})
	call("alice", "DELETE", "/v1/grants/worker/bob", nil)
	call("alice", "DELETE", "/v1/grants/worker/bob", nil)
	call("alice", "DELETE", "/v1/friends/bob", nil)
	call("alice", "DELETE", "/v1/friends/bob", nil)
	if got := feed("alice", ""); len(got) != 1 || got[0].Kind != "friend.accepted" || got[0].Actor != "bob" {
		t.Fatalf("requester's feed: %+v", got)
	}
	all := feed("bob", "")
	var kinds []string
	for i, event := range all {
		if event.Actor != "alice" || event.At.IsZero() || event.Seq <= 0 || (i > 0 && event.Seq <= all[i-1].Seq) {
			t.Fatalf("invalid event or sequence: %+v", all)
		}
		kinds = append(kinds, event.Kind)
	}
	if !slices.Equal(kinds, []string{"friend.request", "grant.received", "grant.revoked", "friend.removed"}) || all[1].Resource != "worker" || all[2].Resource != "worker" {
		t.Fatalf("peer's feed: %+v", all)
	}
	page := feed("bob", "?after="+strconv.FormatInt(all[0].Seq, 10)+"&limit=2")
	if !slices.Equal(page, all[1:3]) {
		t.Fatalf("cursor page: %+v", page)
	}
	if other := feed("cara", ""); len(other) != 0 {
		t.Fatalf("unrelated member's feed: %+v", other)
	}

	// Force the event insert to fail and verify the friend request rolls back.
	if _, err := service.pool.Exec(ctx, `ALTER TABLE mp_events ADD CHECK (kind <> 'friend.request') NOT VALID`); err != nil {
		t.Fatal(err)
	}
	socialRequest(t, handler, "alice", "alice-device", "POST", "/v1/friends/cara", nil, 503)
	var requested bool
	if err := service.pool.QueryRow(ctx, "SELECT EXISTS(SELECT FROM mp_friends WHERE a='alice' AND b='cara')").Scan(&requested); err != nil || requested {
		t.Fatalf("request persisted without event: %v, %v", requested, err)
	}

	// The identity path calls this only on first enrollment. New members may
	// choose their handle after the event commits.
	if err := pgx.BeginFunc(ctx, service.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "INSERT INTO mp_members(user_id) VALUES('alice'),('bob'),('cara'),('new-id') ON CONFLICT DO NOTHING"); err != nil {
			return err
		}
		return RecordMemberJoined(ctx, tx, "new-id")
	}); err != nil {
		t.Fatal(err)
	}
	call("new-id", "PUT", "/v1/profile", map[string]string{"handle": "sam"})
	if got := feed("cara", ""); len(got) != 1 || got[0].Kind != "member.joined" || got[0].Actor != "sam" {
		t.Fatalf("member announcement: %+v", got)
	}
	if got := feed("new-id", ""); len(got) != 0 {
		t.Fatalf("new member received own announcement: %+v", got)
	}
}

func TestEventPageLimitsAndRetention(t *testing.T) {
	ctx := t.Context()
	service := newSocialFixture(t)
	handler := service.Handler()
	if _, err := service.pool.Exec(ctx, `INSERT INTO mp_events(recipient,kind,actor,at)
		SELECT 'recipient','member.joined','old',now()-interval '31 days'
		UNION ALL SELECT 'recipient','member.joined','current',now() FROM generate_series(1,205)`); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		query string
		want  int
	}{{"", 50}, {"?limit=1", 1}, {"?limit=200", 200}, {"?limit=201", 200}} {
		w := socialRequest(t, handler, "recipient", "device", "GET", "/v1/events"+tc.query, nil, 200)
		var result struct{ Events []Event }
		if err := json.NewDecoder(w.Body).Decode(&result); err != nil {
			t.Fatal(err)
		}
		if len(result.Events) != tc.want || result.Events[0].Actor != "current" {
			t.Fatalf("wrong page for %q: %v", tc.query, result.Events)
		}
	}
	for _, invalid := range []string{"?after=x", "?after=-1", "?limit=no", "?limit=-1"} {
		socialRequest(t, handler, "recipient", "device", "GET", "/v1/events"+invalid, nil, 400)
	}
	socialRequest(t, handler, "", "", "GET", "/v1/events", nil, 401)
	if err := service.PruneHistory(ctx); err != nil {
		t.Fatal(err)
	}
	var remaining int
	if err := service.pool.QueryRow(ctx, "SELECT count(*) FROM mp_events").Scan(&remaining); err != nil || remaining != 205 {
		t.Fatalf("retained rows: %d, %v", remaining, err)
	}
}
