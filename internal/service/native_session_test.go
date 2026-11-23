package service

import (
	"context"
	"encoding/json"
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

func (n *nativeFixtureLauncher) ReadConsoleHistory(_ context.Context, ref NativeSession, cwd string) ([]ConsoleEvent, error) {
	n.ref, n.cwd = ref, cwd
	return []ConsoleEvent{{Sequence: 1, Kind: "user", Text: "native history marker"}}, nil
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
