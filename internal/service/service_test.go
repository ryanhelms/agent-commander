package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type recorder struct {
	starts chan LaunchSpec
	stops  chan string
}

func (p recorder) Launch(_ context.Context, spec LaunchSpec) error { p.starts <- spec; return nil }
func (p recorder) Stop(_ context.Context, id string) error         { p.stops <- id; return nil }

type fixture struct {
	t   *testing.T
	api http.Handler
	dir string
	p   recorder
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{t: t, dir: t.TempDir(), p: recorder{make(chan LaunchSpec, 10), make(chan string, 10)}}
	var err error
	f.api, err = New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	return f
}
func (f *fixture) call(method, path, token string, input any, code int, key string) []byte {
	f.t.Helper()
	data, _ := json.Marshal(input)
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	if key != "" {
		r.Header.Set("Idempotency-Key", key)
	}
	w := httptest.NewRecorder()
	f.api.ServeHTTP(w, r)
	if w.Code != code {
		f.t.Fatalf("%s %s got %d, expected %d: %s", method, path, w.Code, code, w.Body.String())
	}
	return w.Body.Bytes()
}
func (f *fixture) launched() LaunchSpec {
	f.t.Helper()
	select {
	case w := <-f.p.starts:
		return w
	case <-time.After(3 * time.Second):
		f.t.Fatal("launch not dispatched")
		return LaunchSpec{}
	}
}
func (f *fixture) run() LaunchSpec {
	f.t.Helper()
	f.call("POST", "/v1/runs", "", map[string]string{"project": "example", "path": f.dir, "client": "codex", "task": "plan a feature"}, 201, "")
	return f.launched()
}
func (f *fixture) delegate(parent LaunchSpec, key string) LaunchSpec {
	f.t.Helper()
	f.call("POST", "/v1/runs/"+parent.RunID+"/workers", parent.Token, map[string]string{"name": "reviewer", "task": "read source"}, 201, key)
	return f.launched()
}

type selectiveLauncher struct{ recorder }

func (selectiveLauncher) CheckAgentClient(client string) error {
	if client == "owner-only" {
		return errors.New("owner selection required")
	}
	return nil
}

func (selectiveLauncher) CheckClient(client string) error {
	if client == "unavailable" {
		return errors.New("test client is unavailable")
	}
	return nil
}

func TestDelegationSelectsAvailableClientBeforeReservation(t *testing.T) {
	f := newFixture(t)
	var err error
	f.api, err = New(f.dir, selectiveLauncher{f.p})
	if err != nil {
		t.Fatal(err)
	}
	c := f.run()
	path := "/v1/runs/" + c.RunID + "/workers"
	input := map[string]string{"name": "review", "task": "read source", "client": "unavailable"}
	f.call("POST", path, c.Token, input, 409, "choose")
	input["client"] = "claude"
	f.call("POST", path, c.Token, input, 201, "choose")
	w := f.launched()
	if w.Client != "claude" || w.ParentID != c.ID {
		t.Fatalf("wrong worker client or parent: %s, %s", w.Client, w.ParentID)
	}
	if w := f.delegate(c, "inherit"); w.Client != c.Client {
		t.Fatalf("expected inherited client %q, got %q", c.Client, w.Client)
	}
	var run Run
	raw := f.call("GET", "/v1/runs/"+c.RunID, "", nil, 200, "")
	if err := json.Unmarshal(raw, &run); err != nil {
		t.Fatal(err)
	}
	if len(run.Workers) != 3 || run.Workers[1].ID != w.ID || run.Workers[1].Client != "claude" {
		t.Fatal("unexpected persisted workers after rejected and accepted delegations")
	}
}

func TestOwnerCanDelegateExplicitACPProfile(t *testing.T) {
	f := newFixture(t)
	var err error
	f.api, err = New(f.dir, selectiveLauncher{f.p})
	if err != nil {
		t.Fatal(err)
	}
	coordinator := f.run()
	path := "/v1/runs/" + coordinator.RunID + "/workers"
	input := map[string]string{"name": "review", "task": "read source", "client": "owner-only"}
	f.call("POST", path, coordinator.Token, input, 409, "")
	f.call("POST", path, "", input, 201, "")
	if spec := f.launched(); spec.Client != "owner-only" || spec.ParentID != coordinator.ID {
		t.Fatalf("owner selection did not reach the launcher: %+v", spec)
	}
}

func TestScopedConversationAndRecovery(t *testing.T) {
	f := newFixture(t)
	coord := f.run()
	w := f.delegate(coord, "r1")
	// Retried delegation returns the original receipt, including after other work.
	delegated := f.call("POST", "/v1/runs/"+coord.RunID+"/workers", coord.Token, map[string]string{"name": "reviewer", "task": "read source"}, 200, "r1")
	if !bytes.Contains(delegated, []byte(w.ID)) {
		t.Fatal("lost worker identity")
	}
	f.call("POST", "/v1/runs/"+coord.RunID+"/workers", coord.Token, map[string]string{"name": "another", "task": "read source"}, 409, "r1")
	question := "Which API receives `" + string('$') + "HOME`?\nUse the literal value."
	target := "/v1/workers/" + w.ID + "/questions"
	f.call("POST", target, "", map[string]string{"question": question}, 403, "")
	f.call("POST", target, coord.Token, map[string]string{"question": question}, 403, "")
	raw := f.call("POST", target, w.Token, map[string]string{"question": question}, 201, "q1")
	var q Question
	if err := json.Unmarshal(raw, &q); err != nil || q.Question != question || q.Status != "pending" {
		t.Fatalf("bad question: %s", raw)
	}
	other := f.run()
	f.call("POST", "/v1/requests/"+q.ID+"/reply", other.Token, map[string]string{"answer": "no"}, 403, "")
	f.call("POST", "/v1/requests/"+q.ID+"/reply", w.Token, map[string]string{"answer": "no"}, 403, "")
	for range 2 {
		f.call("POST", "/v1/requests/"+q.ID+"/reply", "", map[string]string{"answer": "the local API"}, 200, "")
	}
	f.call("POST", "/v1/requests/"+q.ID+"/reply", coord.Token, map[string]string{"answer": "another answer"}, 409, "")
	f.call("POST", "/v1/workers/"+w.ID+"/result", w.Token, map[string]string{"result": "tested local"}, 200, "")
	disk, err := os.ReadFile(filepath.Join(f.dir, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(disk, []byte(w.Token)) {
		t.Fatal("cleartext bearer stored")
	}
	f.api, err = New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	raw = f.call("GET", target+"/"+q.ID, w.Token, nil, 200, "")
	var confirmed Question
	if err := json.Unmarshal(raw, &confirmed); err != nil || confirmed.Answer != "the local API" || confirmed.Status != "answered" {
		t.Fatalf("lost resolution: %s", raw)
	}
	rdata := f.call("GET", "/v1/runs/"+coord.RunID, w.Token, nil, 200, "")
	var run Run
	if err := json.Unmarshal(rdata, &run); err != nil || len(run.Workers) != 2 || run.Workers[1].Result != "tested local" {
		t.Fatalf("lost run state: %s", rdata)
	}
	f.call("GET", "/v1/runs", "expired", nil, 401, "")
	select {
	case <-f.p.starts:
		t.Fatal("duplicate launch on retry or restart")
	default:
	}
}

func TestStopIsScopedAndNoNewWorkers(t *testing.T) {
	f := newFixture(t)
	coord := f.run()
	w := f.delegate(coord, "one")
	other := f.run()
	f.call("POST", "/v1/runs/"+coord.RunID+"/stop", other.Token, nil, 403, "")
	f.call("POST", "/v1/runs/"+coord.RunID+"/stop", "", nil, 200, "")
	f.call("POST", "/v1/runs/"+coord.RunID+"/workers", coord.Token, map[string]string{"name": "late", "task": "new"}, 409, "")
	seen := map[string]bool{}
	for range 2 {
		select {
		case id := <-f.p.stops:
			seen[id] = true
		case <-time.After(3 * time.Second):
			t.Fatal("stop timed out")
		}
	}
	if !seen[coord.ID] || !seen[w.ID] || seen[other.ID] {
		t.Fatalf("incorrect stop set: %v", seen)
	}
	deadline := time.Now().Add(time.Second)
	for {
		var snapshot Run
		_ = json.Unmarshal(f.call("GET", "/v1/runs/"+coord.RunID, "", nil, 200, ""), &snapshot)
		if snapshot.Status == "stopped" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("remained %s", snapshot.Status)
		}
		time.Sleep(time.Millisecond)
	}
	f.call("POST", "/v1/workers/"+w.ID+"/state", w.Token, map[string]string{"state": "working"}, 409, "")
}

func TestOutputTailAndFailedPersistence(t *testing.T) {
	f := newFixture(t)
	coord := f.run()
	text := strings.Repeat("界", 50000) + "END"
	f.call("POST", "/v1/workers/"+coord.ID+"/output", coord.Token, map[string]string{"text": text}, 200, "")
	var run Run
	_ = json.Unmarshal(f.call("GET", "/v1/runs/"+coord.RunID, "", nil, 200, ""), &run)
	tail := run.Workers[0].Output
	if !strings.HasSuffix(tail, "END") || strings.ContainsRune(tail, '�') || len(tail) > 64<<10 {
		t.Fatal("invalid terminal tail")
	}
	// A write error cannot make an uncommitted question visible to observers.
	if err := os.Rename(filepath.Join(f.dir, "state.json"), filepath.Join(f.dir, "backup")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(f.dir, "state.json"), 0700); err != nil {
		t.Fatal(err)
	}
	f.call("POST", "/v1/workers/"+coord.ID+"/questions", coord.Token, map[string]string{"question": "is it saved?"}, 500, "")
	var snapshot Run
	_ = json.Unmarshal(f.call("GET", "/v1/runs/"+coord.RunID, "", nil, 200, ""), &snapshot)
	if len(snapshot.Requests) != 0 {
		t.Fatal("unsaved question leaked")
	}
}

func TestConcurrentReplyAndCompletion(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	first := f.delegate(coordinator, "1")
	second := f.delegate(coordinator, "2")
	askPath := "/v1/workers/" + first.ID + "/questions"
	input := map[string]string{"question": "Choose a schema", "idempotency_key": "schema"}
	var q Question
	_ = json.Unmarshal(f.call("POST", askPath, first.Token, input, 201, ""), &q)
	if q.ID == "" {
		t.Fatal("missing question")
	}
	f.call("POST", askPath, first.Token, input, 200, "")
	replyPath := "/v1/requests/" + q.ID + "/reply"
	f.call("POST", replyPath, second.Token, map[string]string{"answer": "sibling"}, 403, "")

	// A cockpit and coordinator can race on the same pending request.
	codes := make(chan int, 2)
	for i, token := range []string{"", coordinator.Token} {
		go func() {
			body, _ := json.Marshal(map[string]string{"answer": []string{"operator", "coordinator"}[i]})
			req := httptest.NewRequest("POST", replyPath, bytes.NewReader(body))
			if token != "" {
				req.Header.Set("Authorization", "Bearer "+token)
			}
			res := httptest.NewRecorder()
			f.api.ServeHTTP(res, req)
			codes <- res.Code
		}()
	}
	a, b := <-codes, <-codes
	if !((a == 200 && b == 409) || (a == 409 && b == 200)) {
		t.Fatalf("competing replies returned %d, %d", a, b)
	}
	_ = json.Unmarshal(f.call("GET", askPath+"/"+q.ID, first.Token, nil, 200, ""), &q)
	prior := f.call("POST", replyPath, coordinator.Token, map[string]string{"answer": q.Answer}, 200, "")
	if !bytes.Contains(prior, []byte(q.ID)) {
		t.Fatal("retry lost the original resolution")
	}

	snapshot := func() Run {
		var r Run
		_ = json.Unmarshal(f.call("GET", "/v1/runs/"+coordinator.RunID, "", nil, 200, ""), &r)
		return r
	}
	for _, w := range []LaunchSpec{coordinator, first} {
		f.call("POST", "/v1/workers/"+w.ID+"/state", w.Token, map[string]string{"state": "completed"}, 200, "")
		if status := snapshot().Status; status != "running" {
			t.Fatalf("early completion: %s", status)
		}
	}
	f.call("POST", "/v1/workers/"+second.ID+"/state", second.Token, map[string]string{"state": "completed"}, 200, "")
	if got := snapshot().Status; got != "completed" {
		t.Fatalf("finished run status: %s", got)
	}
	// The tmux runner's final buffered output can arrive after the final state.
	f.call("POST", "/v1/workers/"+second.ID+"/output", second.Token, map[string]string{"text": "Complete.\n"}, 200, "")
	f.call("POST", "/v1/workers/"+second.ID+"/state", second.Token, map[string]string{"state": "working"}, 409, "")
}

func TestFailedCoordinatorAndLateChild(t *testing.T) {
	f := newFixture(t)
	c := f.run()
	w := f.delegate(c, "one")
	f.call("POST", "/v1/workers/"+c.ID+"/state", c.Token, map[string]string{"state": "failed", "error": "provider exited"}, 200, "")
	var r Run
	_ = json.Unmarshal(f.call("GET", "/v1/runs/"+c.RunID, "", nil, 200, ""), &r)
	if r.Status != "failed" {
		t.Fatal(r.Status)
	}
	f.call("POST", "/v1/runs/"+c.RunID+"/workers", w.Token, map[string]string{"name": "extra", "task": "keep launching"}, 409, "")
	f.call("POST", "/v1/workers/"+w.ID+"/result", w.Token, map[string]string{"result": "child finished"}, 200, "")
	f.call("POST", "/v1/workers/"+w.ID+"/state", w.Token, map[string]string{"state": "completed"}, 200, "")
}

func TestInterruptedStopResumesWithoutLaunching(t *testing.T) {
	f := newFixture(t)
	c := f.run()
	w := f.delegate(c, "1")
	path := filepath.Join(f.dir, "state.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var db database
	if err = json.Unmarshal(data, &db); err != nil {
		t.Fatal(err)
	}
	r := db.Runs[0]
	r.Status = "stopping"
	r.Workers[0].State = "stopped"
	r.Workers[1].State = "stopping"
	data, err = json.Marshal(db)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	f.api, err = New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case id := <-f.p.stops:
		if id != w.ID {
			t.Fatalf("stopped %s instead of outstanding worker %s", id, w.ID)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("stop did not resume")
	}
	deadline := time.Now().Add(time.Second)
	for {
		var snap Run
		_ = json.Unmarshal(f.call("GET", "/v1/runs/"+c.RunID, "", nil, 200, ""), &snap)
		if snap.Status == "stopped" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("stop never completed")
		}
		time.Sleep(time.Millisecond)
	}
	select {
	case <-f.p.starts:
		t.Fatal("startup relaunched stopped work")
	default:
	}
}
