package actions

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	c := exec.Command("/usr/bin/git", append([]string{"-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@localhost"}, args...)...)
	c.Dir = dir
	c.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + dir, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
	v, e := c.Output()
	if e != nil {
		t.Fatalf("git %q: %v: %s", args, e, v)
	}
	return strings.TrimSpace(string(v))
}
func repoFixture(t *testing.T) (Config, Resource, string) {
	t.Helper()
	dir, e := filepath.EvalSymlinks(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	work := filepath.Join(dir, "work")
	origin := filepath.Join(dir, "publisher.git")
	runGit(t, dir, "init", "-b", "main", work)
	runGit(t, dir, "init", "--bare", origin)
	if e := os.WriteFile(filepath.Join(work, "original.txt"), []byte("base"), 0600); e != nil {
		t.Fatal(e)
	}
	runGit(t, work, "add", "--", "original.txt")
	runGit(t, work, "commit", "-qm", "initial")
	runGit(t, work, "remote", "add", "origin", "https://github.com/studio/fixture.git")
	res, e := PrepareResource(t.Context(), Resource{ID: "clay", Name: "Studio", Target: work, Kind: "repo"})
	if e != nil {
		t.Fatal(e)
	}
	cfg := Config{StateDir: filepath.Join(dir, "state"), Resources: []Resource{res}, testPushURL: origin}
	for _, a := range Capabilities("repo") {
		cfg.Grants = append(cfg.Grants, Grant{ID: "allow", Peer: "alice", Resource: "clay", Action: a, ExpiresAt: time.Now().Add(time.Hour)})
	}
	return cfg, res, origin
}
func action(t *testing.T, cfg Config, id, peer, resource, verb string, params any) (map[string]any, error) {
	t.Helper()
	raw, e := json.Marshal(params)
	if e != nil {
		t.Fatal(e)
	}
	result, e := Execute(t.Context(), cfg, Request{ID: id, Peer: peer, Resource: resource, Action: verb, Payload: raw})
	if e != nil {
		return nil, e
	}
	var out map[string]any
	if e = json.Unmarshal(result, &out); e != nil {
		t.Fatal(e)
	}
	return out, nil
}

func TestGitSharingBoundToBranchCallerAndCheckout(t *testing.T) {
	cfg, r, origin := repoFixture(t)
	dir := filepath.Dir(origin)
	hooks := filepath.Join(dir, "hooks")
	if e := os.Mkdir(hooks, 0700); e != nil {
		t.Fatal(e)
	}
	marker := filepath.Join(dir, "hook-fired")
	hook := fmt.Sprintf("#!/bin/sh\ntouch '%s'\n", marker)
	for _, name := range []string{"reference-transaction", "pre-commit", "pre-push"} {
		if e := os.WriteFile(filepath.Join(hooks, name), []byte(hook), 0700); e != nil {
			t.Fatal(e)
		}
	}
	runGit(t, r.Target, "config", "core.hooksPath", hooks)
	baseline, e := action(t, cfg, "inspect", "alice", "clay", "git.head", struct{}{})
	if e != nil || baseline["head"] != r.Base || baseline["branch"] != r.Branch {
		t.Fatal(baseline, e)
	}
	if _, e = action(t, cfg, "invented", "alice", "clay", "git.shell", struct{}{}); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	input := changes{ExpectedHead: r.Base, Message: "Add sample", Files: map[string]string{"samples/blue.txt": "blue"}}
	if _, e := action(t, cfg, "write1", "mallory", "clay", "git.commit", input); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	v, e := action(t, cfg, "write1", "alice", "clay", "git.commit", input)
	if e != nil {
		t.Fatal(e)
	}
	head := v["head"].(string)
	if head == r.Base || !oid.MatchString(head) {
		t.Fatal(v)
	}
	if runGit(t, r.Target, "rev-parse", "HEAD") != r.Base || runGit(t, r.Target, "status", "--porcelain") != "" {
		t.Fatalf("active worktree changed: base=%q HEAD=%q status=%q", r.Base, runGit(t, r.Target, "rev-parse", "HEAD"), runGit(t, r.Target, "status", "--porcelain"))
	}
	if got := runGit(t, r.Target, "show", r.Branch+":samples/blue.txt"); got != "blue" {
		t.Fatal(got)
	}
	if again, e := action(t, cfg, "write1", "alice", "clay", "git.commit", input); e != nil || again["head"] != head {
		t.Fatal(again, e)
	}
	input.Message = "changed intent"
	if _, e = action(t, cfg, "write1", "alice", "clay", "git.commit", input); !errors.Is(e, ErrConflict) || FailureCode(e) != "conflict" {
		t.Fatal(e)
	}
	for range 2 {
		if _, e = action(t, cfg, "write2", "alice", "clay", "git.commit", input); !errors.Is(e, ErrConflict) || FailureCode(e) != "stale_revision" {
			t.Fatal(e)
		}
	}
	input.ExpectedHead = head
	input.Files = map[string]string{"../outside": "x"}
	if _, e = action(t, cfg, "bad-file", "alice", "clay", "git.commit", input); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	input.Files = map[string]string{".github/workflows/publish.yml": "job"}
	if _, e = action(t, cfg, "bad-flow", "alice", "clay", "git.commit", input); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	if _, e = action(t, cfg, "stale-push", "alice", "clay", "git.push", map[string]string{"expectedHead": r.Base}); !errors.Is(e, ErrConflict) || FailureCode(e) != "stale_revision" {
		t.Fatal(e)
	}
	if _, e = action(t, cfg, "push1", "alice", "clay", "git.push", map[string]string{"expectedHead": head}); e != nil {
		t.Fatal(e)
	}
	if got := runGit(t, dir, "--git-dir="+origin, "rev-parse", "refs/heads/"+r.Branch); got != head {
		t.Fatal(got)
	}
	if _, e = os.Stat(marker); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("repository-provided hook executed")
	}
	runGit(t, r.Target, "remote", "set-url", "origin", "https://github.com/different/project.git")
	if _, e = action(t, cfg, "push2", "alice", "clay", "git.push", map[string]string{"expectedHead": head}); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
}

func TestEnrollmentRejectsUncheckedTargetsAndProtectedReferences(t *testing.T) {
	cfg, r, _ := repoFixture(t)
	invalid := r
	invalid.Branch = "main"
	if _, e := PrepareResource(t.Context(), invalid); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	for _, remote := range []string{"https://wrong.example/studio/fixture.git", "https://u:p@github.com/studio/fixture.git", "https://github.com/studio/fixture.git?extra=1", "https://github.com/studio/../fixture", "-arbitrary-option"} {
		if _, e := parseRepository(remote); !errors.Is(e, ErrInvalid) {
			t.Fatalf("untrusted origin %q accepted", remote)
		}
	}
	alias := filepath.Join(filepath.Dir(r.Target), "other-checkout")
	if e := os.Symlink(r.Target, alias); e != nil {
		t.Fatal(e)
	}
	invalid = r
	invalid.Target = alias
	if _, e := PrepareResource(t.Context(), invalid); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	sharedDir := filepath.Join(r.Target, ".git", "refs", "heads", "commander-share")
	if e := os.Symlink(filepath.Dir(r.Target), sharedDir); e != nil {
		t.Fatal(e)
	}
	if _, e := action(t, cfg, "redirected", "alice", r.ID, "git.head", struct{}{}); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	for i := range cfg.Grants {
		cfg.Grants[i].ExpiresAt = time.Now().Add(-time.Second)
	}
	if _, e := action(t, cfg, "expired", "alice", r.ID, "git.head", struct{}{}); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
}

func TestIssueEffectsReceiptsRevocationAndUnknownOutcome(t *testing.T) {
	cfg, _, _ := repoFixture(t)
	var comments, reads, closed atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Header.Get("Authorization") != "Bearer scoped" {
			t.Error("wrong scoped credential")
		}
		path := req.URL.Path
		switch {
		case req.Method == "GET" && path == "/repos/studio/fixture/issues":
			reads.Add(1)
			fmt.Fprint(w, `[{"number":1,"title":"fixture","state":"open"},{"number":2,"title":"PR","pull_request":{}}]`)
		case req.Method == "GET" && path == "/repos/studio/fixture/issues/1":
			reads.Add(1)
			fmt.Fprint(w, `{"number":1,"title":"fixture","state":"open"}`)
		case req.Method == "POST" && path == "/repos/studio/fixture/issues/1/comments":
			comments.Add(1)
			var v struct{ Body string }
			json.NewDecoder(req.Body).Decode(&v)
			if v.Body == "ambiguous" {
				w.WriteHeader(502)
				return
			}
			fmt.Fprint(w, `{"id":51}`)
		case req.Method == "PATCH" && path == "/repos/studio/fixture/issues/1":
			closed.Add(1)
			fmt.Fprint(w, `{"number":1,"title":"fixture","state":"closed"}`)
		default:
			t.Errorf("unexpected %s %s", req.Method, path)
			http.NotFound(w, req)
		}
	}))
	defer s.Close()
	cfg.testGitHub = s.URL
	cfg.GitHubToken = func(ctx context.Context, id, a string) (string, error) {
		if id != "clay" || !strings.HasPrefix(a, "issue.") {
			t.Error("credential selector escaped grant")
		}
		return "scoped", nil
	}
	cfg.Grants = append(cfg.Grants, Grant{Peer: "bob", Resource: "clay", Action: "issue.read", ExpiresAt: time.Now().Add(time.Minute), MaxUses: 1})
	before := reads.Load()
	if _, e := action(t, cfg, "shadow", "bob", "clay", "issue.close", map[string]int{"number": 1}); !errors.Is(e, ErrDenied) || reads.Load() != before {
		t.Fatal(e)
	}
	if list, e := action(t, cfg, "list", "bob", "clay", "issue.read", struct{}{}); e != nil || len(list["issues"].([]any)) != 1 {
		t.Fatal(list, e)
	}
	if _, e := action(t, cfg, "next", "bob", "clay", "issue.read", struct{}{}); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	comment := map[string]any{"number": 1, "body": "owner approved"}
	for i := 0; i < 2; i++ {
		v, e := action(t, cfg, "comment", "alice", "clay", "issue.comment", comment)
		if e != nil || v["commentId"] != float64(51) {
			t.Fatal(e, v)
		}
	}
	if comments.Load() != 1 {
		t.Fatal("duplicate comment")
	}
	if _, e := action(t, cfg, "close", "alice", "clay", "issue.close", map[string]int{"number": 1}); e != nil || closed.Load() != 1 {
		t.Fatal(e)
	}
	comment["body"] = "ambiguous"
	for i := 0; i < 2; i++ {
		if _, e := action(t, cfg, "uncertain", "alice", "clay", "issue.comment", comment); !errors.Is(e, ErrUncertain) {
			t.Fatal(e)
		}
	}
	if comments.Load() != 2 {
		t.Fatal("replayed uncertain remote effect")
	}
	cfg.Grants = nil
	if _, e := action(t, cfg, "list", "bob", "clay", "issue.read", struct{}{}); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
}

func serveCommander(t *testing.T, handler http.Handler) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "ac-s-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "svc.sock")
	l, e := net.Listen("unix", socket)
	if e != nil {
		t.Fatal(e)
	}
	srv := &http.Server{Handler: handler}
	go srv.Serve(l)
	t.Cleanup(func() { srv.Close() })
	return socket
}

type askWorker struct {
	socket      string
	ready, drop atomic.Bool
	calls       atomic.Int32
	savedText   atomic.Value
}

func startAskWorker(t *testing.T, response string) *askWorker {
	t.Helper()
	worker := &askWorker{}
	var savedID atomic.Value
	worker.socket = serveCommander(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Header.Get("Authorization") != "" {
			t.Error("peer supplied credentials")
		}
		if req.Method == "GET" && req.URL.Path == "/v1/ag-ui/workers/worker" {
			g := 0
			if worker.ready.Load() {
				g = 9
			}
			fmt.Fprintf(w, `{"workerId":"worker","role":"worker","generation":%d}`, g)
			return
		}
		var runID, prompt string
		switch {
		case req.Method == "GET" && req.URL.Path == "/v1/ag-ui/workers/worker/operations":
			if req.URL.Query().Get("runId") != savedID.Load() {
				t.Error("lookup changed run identity")
			}
			fmt.Fprintf(w, `{"operationId":"op-1","runId":%q}`, savedID.Load())
			return
		case req.Method == "GET" && req.URL.Path == "/v1/ag-ui/workers/worker/operations/op-1":
			runID, prompt = savedID.Load().(string), worker.savedText.Load().(string)
		case req.Method == "POST" && req.URL.Path == "/v1/ag-ui/workers/worker/run":
			worker.calls.Add(1)
			var in struct {
				RunID          string
				ForwardedProps struct{ Generation int }
				Messages       []struct{ Content string }
			}
			if json.NewDecoder(req.Body).Decode(&in) != nil || in.ForwardedProps.Generation != 9 || len(in.Messages) != 1 {
				t.Error("invalid worker request")
				return
			}
			runID, prompt = in.RunID, in.Messages[0].Content
			savedID.Store(runID)
			worker.savedText.Store(prompt)
			if worker.drop.Load() {
				w.WriteHeader(502)
				return
			}
		default:
			t.Errorf("unexpected request: %s %s", req.Method, req.URL.Path)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: "+`{"type":"STATE_SNAPSHOT","snapshot":{"workerId":"worker","operationId":"op-1","operationStatus":"completed"}}`+"\n\n")
		usage := func(turn string, counts map[string]int) map[string]any {
			return map[string]any{"role": "system", "metadata": map[string]any{"acp": map[string]any{
				"source": "live", "kind": "acp.prompt_result", "turnId": turn, "turnTokens": counts,
			}}}
		}
		counts := map[string]int{"inputTokens": 2, "outputTokens": 1, "cachedReadTokens": 4}
		if req.Method == http.MethodPost {
			counts["totalTokens"] = 7
		}
		msgs, _ := json.Marshal(map[string]any{"type": "MESSAGES_SNAPSHOT", "messages": []map[string]any{
			{"role": "assistant", "content": "older private turn"}, usage("earlier", map[string]int{"totalTokens": 100}),
			{"role": "user", "content": prompt}, {"role": "tool", "content": "private trace"}, {"role": "assistant", "content": response},
			usage("op-1", counts),
		}})
		fmt.Fprintf(w, "data: %s\n\ndata: {\"type\":\"RUN_FINISHED\",\"runId\":%q}\n\n", msgs, runID)
	}))
	return worker
}

func TestAgentAskRequiresControlAndReturnsOnlyAddressedTurn(t *testing.T) {
	worker := startAskWorker(t, "scoped answer")
	cfg := Config{StateDir: t.TempDir(), CommanderSocket: worker.socket, Resources: []Resource{{ID: "coach", Kind: "agent", Target: "worker"}}, Grants: []Grant{{ID: "allow", Peer: "alice", Resource: "coach", Action: "agent.ask", ExpiresAt: time.Now().Add(time.Minute), BudgetTokens: 14}}}
	if _, err := PrepareLocalResource(context.Background(), worker.socket, cfg.Resources[0]); err != nil {
		t.Fatal("existing worker must be enrollable before input is held", err)
	}
	msg := map[string]string{"text": "Please summarize"}
	if _, e := action(t, cfg, "early", "alice", "coach", "agent.ask", msg); !errors.Is(e, ErrDenied) || worker.calls.Load() != 0 {
		t.Fatal(e)
	}
	worker.ready.Store(true)
	for i := 0; i < 2; i++ {
		r, e := action(t, cfg, "ask", "alice", "coach", "agent.ask", msg)
		if e != nil || r["text"] != "scoped answer" || r["operationId"] != "op-1" || r["tokens"] != float64(7) {
			t.Fatal(r, e)
		}
	}
	if worker.calls.Load() != 1 {
		t.Fatal("duplicate worker turn")
	}
	worker.drop.Store(true)
	if _, e := action(t, cfg, "lost", "alice", "coach", "agent.ask", msg); !errors.Is(e, ErrUncertain) {
		t.Fatal(e)
	}
	result, e := action(t, cfg, "lost", "alice", "coach", "agent.ask", msg)
	if e != nil || result["text"] != "scoped answer" || worker.calls.Load() != 2 {
		t.Fatal(result, e, worker.calls.Load())
	}
	// Upgrade an existing grant using its legacy fingerprint when editing
	// its expiration. Both previously completed turns remain chargeable.
	cfg.Grants[0].UsageID = cfg.Grants[0].ReceiptKey()
	cfg.Grants[0].ExpiresAt = time.Now().Add(time.Hour)
	req := Request{ID: "over", Peer: "alice", Resource: "coach", Action: "agent.ask"}
	if e := CheckBudget(cfg, req); !errors.Is(e, ErrBudgetExhausted) {
		t.Fatalf("approval preflight should refuse a spent budget: %v", e)
	}
	if _, e := action(t, cfg, "over", "alice", "coach", "agent.ask", msg); FailureCode(e) != "budget_exhausted" || worker.calls.Load() != 2 {
		t.Fatalf("spent budget sent another prompt: %v, %d calls", e, worker.calls.Load())
	}
	if _, e := action(t, cfg, "ask", "alice", "coach", "agent.ask", msg); e != nil || worker.calls.Load() != 2 {
		t.Fatalf("replaying an answer should succeed after the budget is spent: %v", e)
	}
}

func TestCoordinatorMailboxBindsRunRoleAndSender(t *testing.T) {
	dir, e := os.MkdirTemp("", "ac-inbox-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "c.sock")
	listener, e := net.Listen("unix", socket)
	if e != nil {
		t.Fatal(e)
	}
	var active atomic.Bool
	active.Store(true)
	srv := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/v1/ag-ui/workers/pilot" {
			t.Errorf("unexpected local request %s %s", r.Method, r.URL.Path)
			http.NotFound(w, r)
			return
		}
		var runStatus = "running"
		if !active.Load() {
			runStatus = "completed"
		}
		json.NewEncoder(w).Encode(map[string]string{"role": "coordinator", "workerId": "pilot", "runId": "run-a", "runStatus": runStatus})
	})}
	go srv.Serve(listener)
	defer srv.Close()
	ctx := context.Background()
	resource, e := PrepareLocalResource(ctx, socket, Resource{ID: "design", Kind: "agent", Target: "pilot"})
	if e != nil || !resource.Coordinator || resource.Run != "run-a" || !slices.Equal(ResourceCapabilities(resource), []string{"agent.message"}) {
		t.Fatal(resource, e)
	}
	cfg := Config{CommanderSocket: socket, StateDir: dir, Resources: []Resource{resource}, Grants: []Grant{{ID: "post", Peer: "alice", Resource: "design", Action: "agent.message", ExpiresAt: time.Now().Add(time.Minute)}, {ID: "fake", Peer: "alice", Resource: "design", Action: "agent.ask", ExpiresAt: time.Now().Add(time.Minute)}}}
	msg := map[string]string{"text": "Review the estimate."}
	for _, c := range []struct{ id, peer, action string }{{"outside", "bob", "agent.message"}, {"wrong", "alice", "agent.ask"}} {
		if _, e := action(t, cfg, c.id, c.peer, "design", c.action, msg); !errors.Is(e, ErrDenied) {
			t.Fatal(e)
		}
	}
	var delivered string
	for i := 0; i < 2; i++ {
		out, e := action(t, cfg, "m1", "alice", "design", "agent.message", msg)
		if e != nil || out["status"] != "completed" || i > 0 && out["messageId"] != delivered {
			t.Fatal(out, e)
		}
		delivered = out["messageId"].(string)
	}
	result, e := CoordinatorInbox(cfg, "pilot", "run-a")
	if e != nil {
		t.Fatal(e)
	}
	box := result.(coordinatorMailbox)
	if len(box.Messages) != 1 || box.Messages[0].ID != delivered || box.Messages[0].Text != msg["text"] || box.Messages[0].Peer != "alice" {
		t.Fatal(box)
	}
	// A process can stop after persisting the note but before finalizing its receipt.
	receiptPath := filepath.Join(cfg.StateDir, "device-action-receipts", delivered+".json")
	interrupted, e := load(receiptPath)
	if e != nil {
		t.Fatal(e)
	}
	interrupted.Status, interrupted.Result = "started", nil
	if e = save(receiptPath, interrupted); e != nil {
		t.Fatal(e)
	}
	recovered, e := action(t, cfg, "m1", "alice", "design", "agent.message", msg)
	if e != nil || recovered["messageId"] != delivered {
		t.Fatal(recovered, e)
	}
	for i := 0; i < 32; i++ {
		if _, e := action(t, cfg, fmt.Sprintf("note-%d", i), "alice", "design", "agent.message", map[string]string{"text": fmt.Sprint(i)}); e != nil {
			t.Fatal(e)
		}
	}
	result, e = CoordinatorInbox(cfg, "pilot", "run-a")
	if e != nil {
		t.Fatal(e)
	}
	box = result.(coordinatorMailbox)
	if !box.Truncated || len(box.Messages) != 32 || box.Messages[0].Text != "0" || box.Messages[31].Text != "31" {
		t.Fatal("incorrect recent message window")
	}
	if _, e := CoordinatorInbox(cfg, "pilot", "run-b"); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	if _, e := CoordinatorInbox(cfg, "stranger", "run-a"); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	active.Store(false)
	if _, e := CoordinatorInbox(cfg, "pilot", "run-a"); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	if _, e := action(t, cfg, "m3", "alice", "design", "agent.message", msg); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
}
