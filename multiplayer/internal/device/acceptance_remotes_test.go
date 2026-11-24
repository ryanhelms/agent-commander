//go:build pilotfixture

package device

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/actions"
)

// This build uses real Git against a disposable bare origin. The HTTPS GitHub
// provider's issue contract is exercised against a loopback test double.
func TestTwoDevicesPushAndCloseIssue(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	origin := filepath.Join(dir, "published.git")
	pilotGit(t, dir, "init", "--bare", origin)
	token := newID()
	var closed atomic.Bool
	var comments atomic.Int32
	issues := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token {
			http.Error(w, "wrong resource token", 403)
			return
		}
		route := r.Method + " " + r.URL.Path
		switch route {
		case "GET /repos/example/fixture/issues/7":
			state := "open"
			if closed.Load() {
				state = "closed"
			}
			fmt.Fprintf(w, `{"number":7,"state":%q,"title":"Review shared checkout"}`, state)
		case "POST /repos/example/fixture/issues/7/comments":
			var in struct{ Body string }
			if json.NewDecoder(r.Body).Decode(&in) != nil || in.Body != "The collaboration branch is ready." {
				http.Error(w, "wrong comment", 400)
				return
			}
			comments.Add(1)
			fmt.Fprint(w, `{"id":21}`)
		case "PATCH /repos/example/fixture/issues/7":
			var in struct{ State string }
			if json.NewDecoder(r.Body).Decode(&in) != nil || in.State != "closed" {
				http.Error(w, "wrong state", 400)
				return
			}
			closed.Store(true)
			fmt.Fprint(w, `{"number":7,"state":"closed"}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(issues.Close)
	if _, err = actions.WithFixtureRemotes(actions.Config{}, issues.URL, origin); err != nil {
		t.Fatal(err)
	}
	configure := func(cfg actions.Config) actions.Config {
		fixture, e := actions.WithFixtureRemotes(cfg, issues.URL, origin)
		if e != nil {
			t.Errorf("fixture unavailable: %v", e)
			return actions.Config{}
		}
		return fixture
	}
	runDevicePilot(t, configure, func(ctx context.Context, alice, bob *pilotPeer, revision, branch string) {
		bob.must(t, ctx, "/tray/repo-credential", input{Resource: "bob-repo", Token: token}, nil)
		for _, action := range []string{"git.push", "issue.read", "issue.comment", "issue.close"} {
			bob.must(t, ctx, "/tray/grant", input{Resource: "bob-repo", Handle: alice.handle, Capability: action, ExpiresAt: time.Now().Add(time.Hour), MaxUses: 4}, nil)
		}
		send := func(action string, value any) map[string]any {
			t.Helper()
			payload, err := json.Marshal(value)
			if err != nil {
				t.Fatal(err)
			}
			sub := Submit{ID: "shared-" + action, Targets: []Target{{"bob-repo", action, payload}}}
			alice.must(t, ctx, "/coordinator/submit", sub, nil)
			return alice.completed(t, ctx, sub.ID, 1)["bob-repo"].Result
		}
		if out := send("issue.read", map[string]int{"number": 7}); out["status"] != "completed" {
			t.Fatalf("read did not complete: %+v", out)
		}
		if out := send("git.push", map[string]string{"expectedHead": revision}); out["head"] != revision || pilotGit(t, dir, "--git-dir="+origin, "rev-parse", "refs/heads/"+branch) != revision {
			t.Fatalf("shared revision did not reach the bare origin: %+v", out)
		}
		if out := send("issue.comment", map[string]any{"number": 7, "body": "The collaboration branch is ready."}); out["commentId"] != float64(21) || comments.Load() != 1 {
			t.Fatalf("comment did not reach the provider: %+v", out)
		}
		if out := send("issue.close", map[string]int{"number": 7}); out["state"] != "closed" || !closed.Load() {
			t.Fatalf("issue remained open: %+v", out)
		}
	})
}
