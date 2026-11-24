package control

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestSealedWire(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want bool
	}{
		{`"hdr..iv.ciphertext.tag"`, true}, {`"hdr.ek.iv.ciphertext.tag"`, true},
		{`{"body":"text"}`, false}, {`"one.two.three"`, false}, {`"a.b.c.d."`, false}, {`"a.b.c.d.!"`, false},
	} {
		if got := sealed(json.RawMessage(tc.raw)); got != tc.want {
			t.Fatalf("unexpected compact envelope validation: %s", tc.raw)
		}
	}
}

func TestDurableControlPilot(t *testing.T) {
	dsn := os.Getenv("PILOT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set PILOT_TEST_DATABASE_URL to exercise two edges against PostgreSQL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	namespace := pgx.Identifier{"pilot_test_" + secret()}.Sanitize()
	if _, err = admin.Exec(ctx, "CREATE SCHEMA "+namespace); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, err := admin.Exec(context.Background(), "DROP SCHEMA "+namespace+" CASCADE")
		if err != nil {
			t.Error(err)
		}
	}()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = namespace
	cfg.MaxConns = 12
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	auth := func(r *http.Request) (Principal, error) {
		return Principal{r.Header.Get("Test-User"), r.Header.Get("Test-Device")}, nil
	}
	left, err := New(ctx, pool, "left", auth, nil)
	if err != nil {
		t.Fatal(err)
	}
	right, err := New(ctx, pool, "right", auth, nil)
	if err != nil {
		t.Fatal(err)
	}
	edges := map[string]http.Handler{"left": left.Handler(), "right": right.Handler()}
	type who struct{ user, device, edge string }
	alice := who{"alice", "a1", "left"}
	bob := who{"bob", "b1", "right"}
	cara := who{"cara", "c1", "right"}
	call := func(who who, method, path string, in any) (int, map[string]any) {
		payload, _ := json.Marshal(in)
		r := httptest.NewRequest(method, path, bytes.NewReader(payload)).WithContext(ctx)
		r.Header.Set("Test-User", who.user)
		r.Header.Set("Test-Device", who.device)
		w := httptest.NewRecorder()
		edges[who.edge].ServeHTTP(w, r)
		var obj map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &obj)
		return w.Code, obj
	}
	check := func(person who, method, path string, in any, code int) map[string]any {
		t.Helper()
		status, obj := call(person, method, path, in)
		if status != code {
			t.Fatalf("%s %s as %s: wanted %d, got %d %+v", method, path, person.user, code, status, obj)
		}
		return obj
	}
	open := func(person who) map[string]any {
		o := check(person, "POST", "/v1/session", nil, 200)
		lease := map[string]any{"session": o["session"], "generation": o["generation"]}
		check(person, "PUT", "/v1/session", lease, 200)
		return lease
	}
	for _, person := range []who{alice, bob, cara} {
		check(person, "PUT", "/v1/profile", map[string]string{"handle": person.user}, 200)
	}
	check(alice, "POST", "/v1/friends/bob", nil, 200)
	check(alice, "PUT", "/v1/friends/bob", nil, 403)
	check(bob, "PUT", "/v1/friends/alice", nil, 200)
	check(alice, "POST", "/v1/friends/cara", nil, 200)
	check(cara, "PUT", "/v1/friends/alice", nil, 200)
	if known, err := left.CanLookup(ctx, alice.user, bob.user); !known || err != nil {
		t.Fatalf("friend key access: %t %v", known, err)
	}
	if known, err := left.CanLookup(ctx, bob.user, cara.user); known || err != nil {
		t.Fatalf("stranger key access: %t %v", known, err)
	}
	until := time.Now().Add(time.Hour).UTC().Truncate(time.Microsecond)
	put := func(person who, id string) {
		check(person, "PUT", "/v1/resources/"+id, map[string]any{"kind": "agent", "name": id, "actions": []string{"ask.v1"}}, 200)
	}
	grant := func(person who, id string, max int) {
		check(person, "PUT", "/v1/grants/"+id+"/alice", map[string]any{"actions": []string{"ask.v1"}, "expires_at": until, "max_uses": max}, 200)
	}
	put(bob, "worker-b")
	put(cara, "worker-c")
	put(cara, "worker-c2")
	grant(bob, "worker-b", 2)
	grant(cara, "worker-c", 3)
	grant(cara, "worker-c2", 1)
	check(who{bob.user, "b2", "left"}, "DELETE", "/v1/grants/worker-b/alice", nil, 404)
	if got := len(check(alice, "GET", "/v1/resources", nil, 200)["resources"].([]any)); got != 3 {
		t.Fatalf("expected three granted resources: %d", got)
	}
	newChild := func(id, device, resource string) Addressed {
		return Addressed{ID: id, Device: device, Resource: resource, Action: "ask.v1", Envelope: json.RawMessage(`"a..i.c.t"`), ExpiresAt: until}
	}
	a := newChild("one", "b1", "worker-b")
	b := newChild("two", "c1", "worker-c")
	c := newChild("three", "c1", "worker-c2")
	submit := func(parent string, children ...Addressed) map[string]any {
		return map[string]any{"id": parent, "children": children}
	}
	group := submit("room", a, b, c)
	check(alice, "POST", "/v1/submissions", group, 200)
	check(alice, "POST", "/v1/submissions", submit("room", c, b, a), 200)
	mismatch := a
	mismatch.Envelope = json.RawMessage(`"x..i.c.t"`)
	check(alice, "POST", "/v1/submissions", submit("room", mismatch, b, c), 409)
	check(who{alice.user, "a2", "left"}, "GET", "/v1/submissions/room", nil, 404)
	check(cara, "GET", "/v1/submissions/room", nil, 404)
	no := newChild("no", "b1", "worker-c")
	check(alice, "POST", "/v1/submissions", submit("all-or-none", newChild("good", "b1", "worker-b"), no), 403)
	check(alice, "GET", "/v1/submissions/all-or-none", nil, 404)
	if ok, err := left.PumpOne(ctx, func(context.Context, string) error { return errors.New("offline") }); ok || err == nil {
		t.Fatalf("publisher failure lost retry: %t %v", ok, err)
	}
	var published []string
	for {
		ok, err := right.PumpOne(ctx, func(_ context.Context, id string) error { published = append(published, id); return nil })
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			break
		}
	}
	sort.Strings(published)
	if len(published) != 3 || published[0] != "one" || published[2] != "two" {
		t.Fatalf("durable delivery ids: %v", published)
	}
	leaseB := open(bob)
	leaseC := open(cara)
	if edge, device, err := left.Route(ctx, "one"); edge != "right" || device != "b1" || err != nil {
		t.Fatalf("live route: %q %q %v", edge, device, err)
	}
	bob.edge = "left"
	leaseNew := open(bob)
	// Each HTTP request can use a different TLS connection and reach either edge.
	bob.edge = "right"
	check(bob, "PUT", "/v1/session", leaseNew, 200)
	if leaseNew["generation"].(float64) <= leaseB["generation"].(float64) {
		t.Fatal("takeover did not fence the old generation")
	}
	check(who{"bob", "b1", "right"}, "POST", "/v1/children/one/claim", leaseB, 409)
	q := "/v1/inbox?session=" + leaseNew["session"].(string) + "&generation=" + strconv.Itoa(int(leaseNew["generation"].(float64)))
	if got := len(check(bob, "GET", q, nil, 200)["children"].([]any)); got != 1 {
		t.Fatalf("offline inbox catchup: %d", got)
	}
	var wg sync.WaitGroup
	claimed := make(chan bool, 8)
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			status, out := call(bob, "POST", "/v1/children/one/claim", leaseNew)
			if status != 200 {
				t.Errorf("concurrent claim: %d %v", status, out)
				return
			}
			claimed <- out["claimed"].(bool)
		}()
	}
	wg.Wait()
	close(claimed)
	count := 0
	for yes := range claimed {
		if yes {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("granted %d execution claims", count)
	}
	bob.edge = "left"
	result := map[string]any{"session": leaseNew["session"], "generation": leaseNew["generation"], "status": "completed", "result": "x..i.y.z"}
	check(bob, "PUT", "/v1/children/one/receipt", result, 200)
	check(bob, "PUT", "/v1/children/one/receipt", result, 200)
	result["result"] = "x..i.z.z"
	check(bob, "PUT", "/v1/children/one/receipt", result, 409)
	check(cara, "DELETE", "/v1/grants/worker-c/alice", nil, 200)
	if out := check(cara, "POST", "/v1/children/two/claim", leaseC, 200); out["claimed"].(bool) {
		t.Fatal("revoked work executed")
	}
	if out := check(cara, "POST", "/v1/children/three/claim", leaseC, 200); !out["claimed"].(bool) {
		t.Fatal("missing valid claim")
	}
	leaseC = open(cara)
	if out := check(cara, "POST", "/v1/children/three/claim", leaseC, 200); out["claimed"].(bool) || out["child"].(map[string]any)["status"] != "uncertain" {
		t.Fatal("uncertain work was rerun")
	}
	check(alice, "POST", "/v1/submissions", submit("overcap", newChild("four", "c1", "worker-c2")), 403)
	// Upgrade a previously consumed aggregate grant from before per-action
	// accounting was introduced. Its completed child reconstructs the debit.
	if _, err = pool.Exec(ctx, "DELETE FROM mp_grant_limits WHERE resource='worker-b'"); err != nil {
		t.Fatal(err)
	}
	check(bob, "PUT", "/v1/grants/worker-b/alice", map[string]any{"limits": []Limit{{"ask.v1", until, 1}}}, 200)
	check(alice, "POST", "/v1/submissions", submit("legacy-debit", newChild("legacy-debit", "b1", "worker-b")), 403)
	// Each capability spends only its own budget. A policy snapshot can
	// retire a heavily used action without consuming an unrelated allowance.
	check(bob, "PUT", "/v1/resources/tools", map[string]any{"name": "tools", "kind": "repo", "actions": []string{"read", "patch", "draft"}}, 200)
	setLimits := func(limits ...Limit) {
		check(bob, "PUT", "/v1/grants/tools/alice", map[string]any{"limits": limits}, 200)
	}
	readLimit, patchLimit, draftLimit := Limit{"read", until, 1}, Limit{"patch", until, 1}, Limit{"draft", until, 2}
	setLimits(readLimit, patchLimit, draftLimit)
	addressed := func(id, action string) Addressed { v := newChild(id, "b1", "tools"); v.Action = action; return v }
	run := func(id, action string) {
		check(alice, "POST", "/v1/submissions", submit(id, addressed(id, action)), 200)
		if !check(bob, "POST", "/v1/children/"+id+"/claim", leaseNew, 200)["claimed"].(bool) {
			t.Fatal("missing claim for", id)
		}
	}
	terminal := func(id, status string) {
		t.Helper()
		claim := check(bob, "POST", "/v1/children/"+id+"/claim", leaseNew, 200)
		receipt := check(alice, "GET", "/v1/submissions/"+id, nil, 200)["children"].([]any)[0].(map[string]any)
		if claim["claimed"].(bool) || claim["child"].(map[string]any)["status"] != status || receipt["status"] != status || receipt["result"] != nil {
			t.Fatalf("%s: expected a terminal %s without an execution receipt, got %v and %v", id, status, claim, receipt)
		}
	}
	queued := submit("queued-read", addressed("queued-read", "read"))
	check(alice, "POST", "/v1/submissions", queued, 200)
	run("r1", "read")
	terminal("queued-read", "denied")
	readLimit.MaxUses = 2
	setLimits(readLimit, patchLimit, draftLimit)
	if replay := check(alice, "POST", "/v1/submissions", queued, 200)["children"].([]any)[0].(map[string]any); replay["status"] != "denied" {
		t.Fatal("a renewed grant revived the old submission", replay)
	}
	run("renewed-read", "read")
	check(alice, "POST", "/v1/submissions", submit("later-draft", addressed("later-draft", "draft")), 200)
	check(alice, "POST", "/v1/submissions", submit("sender-observed-draft", addressed("sender-observed-draft", "draft")), 200)
	check(alice, "POST", "/v1/submissions", submit("unobserved-draft", addressed("unobserved-draft", "draft")), 200)
	if _, err := pool.Exec(ctx, "UPDATE mp_grant_limits SET expires_at=now()-interval '1 second' WHERE resource='tools' AND action='draft'"); err != nil {
		t.Fatal(err)
	}
	check(alice, "POST", "/v1/submissions", submit("r2", addressed("r2", "read")), 403)
	terminal("later-draft", "denied")
	if receipt := check(alice, "GET", "/v1/submissions/sender-observed-draft", nil, 200)["children"].([]any)[0].(map[string]any); receipt["status"] != "denied" || receipt["result"] != nil {
		t.Fatal("sender could not settle the expired grant before the recipient claimed it", receipt)
	}
	check(alice, "POST", "/v1/submissions", submit("d2", addressed("d2", "draft")), 403)
	actionsFor := func() []string {
		for _, raw := range check(alice, "GET", "/v1/resources", nil, 200)["resources"].([]any) {
			v := raw.(map[string]any)
			if v["id"] == "tools" {
				var actions []string
				for _, one := range v["actions"].([]any) {
					actions = append(actions, one.(string))
				}
				return actions
			}
		}
		return nil
	}
	if got := actionsFor(); len(got) != 1 || got[0] != "patch" {
		t.Fatal("catalog exposed exhausted or expired action", got)
	}
	inboxPath := "/v1/inbox?session=" + leaseNew["session"].(string) + "&generation=" + strconv.Itoa(int(leaseNew["generation"].(float64)))
	for _, raw := range check(bob, "GET", inboxPath, nil, 200)["children"].([]any) {
		if raw.(map[string]any)["id"] == "later-draft" {
			t.Fatal("expired capability reached owner inbox")
		}
	}
	setLimits(readLimit, patchLimit, draftLimit)
	terminal("unobserved-draft", "denied")
	for _, raw := range check(alice, "GET", "/v1/grants", nil, 200)["grants"].([]any) {
		grant := raw.(map[string]any)
		if grant["resource"] == "tools" && grant["used"] != float64(2) {
			t.Fatal("refused claims changed the usage ledger", grant)
		}
	}
	run("renewed-draft", "draft")
	setLimits(patchLimit)
	run("p1", "patch")
	setLimits(patchLimit)
	if got := actionsFor(); len(got) != 0 {
		t.Fatal("editing a granted capability reset its usage", got)
	}
	for _, raw := range check(alice, "GET", "/v1/grants", nil, 200)["grants"].([]any) {
		v := raw.(map[string]any)
		if v["resource"] == "tools" {
			l := v["limits"].([]any)
			if len(l) != 1 || l[0].(map[string]any)["used"] != float64(1) {
				t.Fatal("used count missing", l)
			}
		}
	}
	check(bob, "DELETE", "/v1/friends/alice", nil, 200)
	if known, _ := left.CanLookup(ctx, bob.user, alice.user); known {
		t.Fatal("revoked relationship still allows key discovery")
	}
	check(alice, "POST", "/v1/friends/bob", nil, 200)
	check(bob, "PUT", "/v1/friends/alice", nil, 200)
	if got := actionsFor(); len(got) != 0 {
		t.Fatal("renewed friendship restored old capability", got)
	}
	receipts := check(alice, "GET", "/v1/submissions/room", nil, 200)["children"].([]any)
	if len(receipts) != 3 {
		t.Fatal("missing individual receipts")
	}
}
