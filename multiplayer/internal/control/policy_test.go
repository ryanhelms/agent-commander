package control

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestRelayPolicy(t *testing.T) {
	s := newSocialFixture(t)
	ctx := t.Context()
	if err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		return InitMembership(ctx, tx, nil, []string{"admin@example.test", "backup@example.test"})
	}); err != nil {
		t.Fatal(err)
	}
	h := s.Handler()
	const route = "/v1/admin/policy"
	put := func(edit any, status int) Policy {
		t.Helper()
		r := socialRequest(t, h, "admin", "admin-device", "PUT", route, edit, status)
		if status != http.StatusOK {
			return Policy{}
		}
		return shareResponse[Policy](t, r)
	}
	socialRequest(t, h, "", "", "GET", route, nil, 401)
	socialRequest(t, h, "member", "member-device", "GET", route, nil, 403)
	socialRequest(t, h, "member", "member-device", "PUT", route, map[string]bool{"directory": false}, 403)
	put(map[string]string{"knowledgeDefault": "server", "knowledgeWidest": "friend"}, 400)
	put(map[string]int{"retentionDays": 0}, 400)
	put(map[string]string{"directory": "wrong"}, 400)
	put(map[string]string{"reputationVisibility": "public"}, 400)

	put(map[string]any{"knowledgeDefault": "friend", "knowledgeWidest": "group", "directory": "off",
		"maxGrantDays": 1, "maxBudgetTokens": 20, "retentionDays": 2}, 200)
	p := put(map[string]string{"reputationVisibility": "users"}, 200)
	info, err := s.PublicSettings(ctx)
	want := Policy{"friend", "group", "users", false, 1, 20, 2}
	if got := shareResponse[Policy](t, socialRequest(t, h, "admin", "admin-device", "GET", route, nil, 200)); got != want {
		t.Fatalf("admin policy = %+v, want %+v", got, want)
	}
	if err != nil || p != want || info.Policy != want || info.AdminContact != "admin@example.test" || info.Membership != "open" {
		t.Fatalf("policy or public settings: %+v, %+v, %v", p, info, err)
	}

	// An unbounded action (including an old-style aggregate grant) exceeds a finite cap.
	call := func(user, method, path string, payload any, code int) {
		t.Helper()
		socialRequest(t, h, user, user+"-device", method, path, payload, code)
	}
	for _, user := range []string{"alice", "bob"} {
		call(user, "PUT", "/v1/profile", map[string]string{"handle": user}, 200)
	}
	call("alice", "POST", "/v1/friends/bob", nil, 200)
	call("bob", "PUT", "/v1/friends/alice", nil, 200)
	call("alice", "PUT", "/v1/resources/host1", map[string]any{"kind": "host", "name": "lab", "actions": []string{"host.run"}}, 200)
	path := "/v1/grants/host1/bob"
	l := Limit{Action: "host.run", ExpiresAt: time.Now().Add(time.Hour), MaxUses: 2, BudgetTokens: 20}
	call("alice", "PUT", path, map[string]any{"actions": []string{l.Action}, "expires_at": l.ExpiresAt, "max_uses": 2}, 400)
	grant := func(n int64, exp time.Time, code int) {
		t.Helper()
		l.BudgetTokens, l.ExpiresAt = n, exp
		call("alice", "PUT", path, map[string]any{"limits": []Limit{l}}, code)
	}
	grant(0, l.ExpiresAt, 400)
	grant(21, l.ExpiresAt, 400)
	grant(20, time.Now().Add(48*time.Hour), 400)
	grant(20, time.Now().Add(time.Hour), 200)

	// Retention purges message contents and keeps durable request identity and outcomes.
	exec := func(sql string) {
		t.Helper()
		if _, err := s.pool.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	exec(`INSERT INTO mp_events(recipient,kind,actor,at) VALUES ('admin','old','member',now()-interval '3 days');
		INSERT INTO mp_submissions(sender,parent,sender_device,digest) VALUES('bob','task','bob-device','');
		INSERT INTO mp_children(id,parent,sender,sender_device,owner_id,device,resource,action,envelope,result,
			expires_at,status,submitted_at,completed_at) VALUES
		('child','task','bob','bob-device','alice','alice-device','host1','host.run','"sealed request"','"a..b.c.d"',
		 now()-interval '3 days','completed',now()-interval '4 days',now()-interval '3 days');
		INSERT INTO mp_outcomes(child,accepted) VALUES ('child',true)`)
	var feed struct{ Events []Event }
	w := socialRequest(t, h, "admin", "admin-device", "GET", "/v1/events", nil, 200)
	if err := json.Unmarshal(w.Body.Bytes(), &feed); err != nil || len(feed.Events) != 0 {
		t.Fatalf("expired event visible: %+v, %v", feed, err)
	}
	if err := s.PruneHistory(ctx); err != nil {
		t.Fatal(err)
	}
	var purged, accepted bool
	err = s.pool.QueryRow(ctx, `SELECT c.envelope='null'::jsonb AND c.result IS NULL AND c.status='completed'
		AND NOT EXISTS (SELECT FROM mp_events WHERE kind='old'), o.accepted
		FROM mp_children c JOIN mp_outcomes o ON o.child=c.id WHERE c.id='child'`).Scan(&purged, &accepted)
	if err != nil || !purged || !accepted {
		t.Fatalf("after prune: %t %t %v", purged, accepted, err)
	}
	lease := shareResponse[leaseProof](t, socialRequest(t, h, "alice", "alice-device", "POST", "/v1/session", nil, 200))
	call("alice", "PUT", "/v1/session", lease, 200)
	receipt := map[string]any{"session": lease.Session, "generation": lease.Generation, "status": "completed", "result": "a..b.c.d"}
	call("alice", "PUT", "/v1/children/child/receipt", receipt, 200)
	receipt["result"] = "a..x.y.z"
	call("alice", "PUT", "/v1/children/child/receipt", receipt, 409)

}
