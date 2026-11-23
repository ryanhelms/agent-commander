package service

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type nativeFixtureLauncher struct {
	recorder
	ref NativeSession
	cwd string
}

func (n *nativeFixtureLauncher) ReadNativeHistoryPage(_ context.Context, ref NativeSession, cwd, cursor string, limit uint32) (json.RawMessage, error) {
	n.ref, n.cwd = ref, cwd
	if cursor != "fixture-cursor" || limit != 2 {
		return nil, errors.New("private provider details")
	}
	return json.RawMessage(`{"observations":[{"extension":{"type":"fixture","data":"AAE="}}],"nextCursor":"next-fixture-cursor"}`), nil
}

func TestNativeHistoryPageAuthorizationAndBinding(t *testing.T) {
	f := newFixture(t)
	reader := &nativeFixtureLauncher{recorder: f.p}
	var err error
	f.api, err = New(f.dir, reader)
	if err != nil {
		t.Fatal(err)
	}
	coordinator := f.run()
	worker := f.delegate(coordinator, "delegate")
	path := "/v1/workers/" + worker.ID
	history := path + "/history"
	f.call("GET", history, "", nil, 501, "")
	ref := NativeSession{HarnessInstance: "local-codex", SessionID: "page-session"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	f.call("GET", history+"?limit=2&cursor=fixture-cursor", worker.Token, nil, 403, "")
	f.call("GET", history+"?limit=129", "", nil, 400, "")
	raw := f.call("GET", history+"?limit=2&cursor=fixture-cursor", "", nil, 200, "")
	if reader.ref != ref || reader.cwd != f.dir || !strings.Contains(string(raw), `"data":"AAE="`) || !strings.Contains(string(raw), "next-fixture-cursor") {
		t.Fatalf("history page did not preserve the bound session, extension or cursor: %s", raw)
	}
	if raw := f.call("GET", history, "", nil, 503, ""); strings.Contains(string(raw), "private provider details") {
		t.Fatal("history error exposed native diagnostics")
	}
}

func (n *nativeFixtureLauncher) ReadConsoleHistory(_ context.Context, ref NativeSession, cwd string) ([]ConsoleEvent, error) {
	n.ref, n.cwd = ref, cwd
	return []ConsoleEvent{{Sequence: 1, Kind: "user", Text: "native history marker"}}, nil
}

type transitioningHistory struct {
	recorder
	duringRead func()
}

func (n transitioningHistory) ReadConsoleHistory(context.Context, NativeSession, string) ([]ConsoleEvent, error) {
	n.duringRead()
	return []ConsoleEvent{{Sequence: 1, Kind: "text", Text: "native assistant response"}}, nil
}

func TestRestoreHistoryWhileWorkerStopSettles(t *testing.T) {
	for _, tc := range []struct {
		state    string
		restored bool
	}{{"stopped", true}, {"working", false}} {
		t.Run(tc.state, func(t *testing.T) {
			worker := &Worker{
				ID: "worker", State: "stopping",
				NativeSession: &NativeSession{HarnessInstance: "local-codex", SessionID: "conversation"},
			}
			s := &service{state: database{Runs: []*Run{{Workers: []*Worker{worker}}}}}
			s.launcher = transitioningHistory{duringRead: func() {
				s.mu.Lock()
				defer s.mu.Unlock()
				worker.State = tc.state
			}}
			s.restoreNativeHistories(context.Background())
			if got := len(worker.Console) == 1; got != tc.restored {
				t.Fatalf("restored history = %t after state changed to %s", got, tc.state)
			}
		})
	}
}

func TestNativeBindingHistoryAndLegacyPersistence(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "delegate")
	ref := NativeSession{HarnessInstance: "local-codex", SessionID: "a-test-session"}
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/native-session", worker.Token, ref, 403, "")
	f.call("POST", path+"/native-session", "", ref, 200, "")
	f.call("POST", path+"/native-session", "", ref, 200, "")
	f.call("POST", "/v1/workers/"+coordinator.ID+"/native-session", "", ref, 409, "")
	f.call("POST", path+"/native-session", "", NativeSession{"local-codex", "other"}, 409, "")

	output := map[string]any{"text": "private transient marker", "events": []ConsoleEvent{{Kind: "text", Text: "private transient marker"}}}
	f.call("POST", path+"/output", worker.Token, output, 200, "")
	f.call("POST", "/v1/workers/"+coordinator.ID+"/output", coordinator.Token, map[string]string{"text": "legacy marker"}, 200, "")
	bytes, err := os.ReadFile(filepath.Join(f.dir, "state.json"))
	if err != nil || strings.Contains(string(bytes), "private transient marker") || !strings.Contains(string(bytes), "legacy marker") {
		t.Fatal("disk snapshot did not preserve the native/legacy storage boundary", err)
	}
	reader := &nativeFixtureLauncher{recorder: f.p}
	reopened := &service{launcher: reader}
	if err := reopened.load(f.dir); err != nil {
		t.Fatal(err)
	}
	reopened.restoreNativeHistories(context.Background())
	_, w := reopened.worker(worker.ID)
	if reader.ref != ref || reader.cwd != f.dir || len(w.Console) != 1 || w.Console[0].Text != "native history marker" {
		t.Fatal("wrong native history after service restart")
	}
}

func TestNativePermissionChoiceBoundToQuestion(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	w := f.delegate(coordinator, "child")
	ask := map[string]any{"question": "Create fixture?", "choices": []QuestionChoice{{"once", "Allow once"}, {"deny", "Deny"}}}
	var q Question
	raw := f.call("POST", "/v1/workers/"+w.ID+"/questions", w.Token, ask, 201, "native-input")
	if err := json.Unmarshal(raw, &q); err != nil || !strings.Contains(q.Question, "Allow once [once]") || len(q.Choices) != 2 {
		t.Fatal("choices missing from the interactive question")
	}
	path := "/v1/requests/" + q.ID + "/reply"
	f.call("POST", path, "", map[string]string{"answer": "some-other-choice"}, 400, "")
	f.call("POST", path, w.Token, map[string]string{"answer": "once"}, 403, "")
	f.call("POST", path, "", map[string]string{"answer": "once"}, 200, "")
	f.call("POST", path, "", map[string]string{"answer": "deny"}, 409, "")
}
