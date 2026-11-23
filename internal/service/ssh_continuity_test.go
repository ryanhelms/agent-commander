package service

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
)

type continuityLauncher struct {
	recorder
	history func(NativeSession, string, string) (json.RawMessage, error)
}

func (continuityLauncher) WorkerCheckout(string, string, string) (string, error) {
	return "/home/worker/checkout", nil
}

func (p continuityLauncher) ReadNativeHistoryPage(_ context.Context, ref NativeSession, cwd, cursor string, _ uint32) (json.RawMessage, error) {
	return p.history(ref, cwd, cursor)
}

func TestSSHDisconnectPreservesOriginalRequests(t *testing.T) {
	f := newFixture(t)
	launcher := continuityLauncher{recorder: f.p}
	var err error
	f.api, err = New(f.dir, launcher)
	if err != nil {
		t.Fatal(err)
	}
	coordinator := f.run()
	local := f.delegate(coordinator, "local")
	runPath := "/v1/runs/" + coordinator.RunID
	f.call("POST", runPath+"/workers", coordinator.Token, map[string]string{
		"name": "remote", "task": "read remote source", "host": "test-linux",
	}, 201, "remote")
	remote := f.launched()
	remotePath := "/v1/workers/" + remote.ID
	native := NativeSession{HarnessInstance: "ssh-test-linux-claude", SessionID: "original-session"}
	f.call("POST", remotePath+"/native-session", "", native, 200, "")
	for _, worker := range []LaunchSpec{remote, local} {
		path := "/v1/workers/" + worker.ID
		f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
		f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	}
	ask := func(worker LaunchSpec, prompt string) Question {
		t.Helper()
		var q Question
		raw := f.call("POST", "/v1/workers/"+worker.ID+"/questions", worker.Token, map[string]string{"question": prompt}, 201, prompt)
		if err := json.Unmarshal(raw, &q); err != nil {
			t.Fatal(err)
		}
		return q
	}
	localQuestion := ask(local, "local pending")
	remoteQuestion := ask(remote, "remote pending")
	ambiguous := ask(remote, "remote answered")
	answerKnown := false
	launcher.history = func(ref NativeSession, cwd, cursor string) (json.RawMessage, error) {
		if ref != native || cwd != remote.Worktree {
			return nil, fmt.Errorf("incorrect recovery target: %v at %s", ref, cwd)
		}
		if !answerKnown {
			return json.RawMessage(`{"observations":[]}`), nil
		}
		observed := ambiguous
		observed.Status, observed.Answer = "answered", "literal answer"
		result, _ := json.Marshal(observed)
		content, _ := json.Marshal([]map[string]string{{"type": "text", "text": string(result)}})
		if cursor == "" {
			return json.Marshal(map[string]any{
				"nextCursor": "page2",
				"observations": []map[string]any{{"tool": map[string]string{
					"callId": "wait", "phase": "started", "name": "mcp__commander__commander_wait",
					"summary": fmt.Sprintf(`{"request_id":%q}`, ambiguous.ID),
				}}},
			})
		}
		return json.Marshal(map[string]any{
			"observations": []map[string]any{{"tool": map[string]string{
				"callId": "wait", "phase": "completed", "summary": string(content),
			}}},
		})
	}
	reply := map[string]string{"answer": "literal answer"}
	ambiguousReply := "/v1/requests/" + ambiguous.ID + "/reply"
	f.call("POST", ambiguousReply, "", reply, 200, "")
	f.call("POST", remotePath+"/control/finish", remote.Token, map[string]string{"state": "disconnected"}, 200, "")
	var run Run
	if err := json.Unmarshal(f.call("GET", runPath, "", nil, 200, ""), &run); err != nil {
		t.Fatal(err)
	}
	if run.Workers[1].State != "working" || run.Workers[2].State != "disconnected" ||
		run.Workers[2].NativeSession == nil || *run.Workers[2].NativeSession != native {
		t.Fatalf("disconnect affected the wrong worker or lost its native session: %+v", run.Workers[2])
	}
	f.api, err = New(f.dir, launcher)
	if err != nil {
		t.Fatal(err)
	}
	f.call("POST", remotePath+"/control/finish", remote.Token, map[string]string{"state": "disconnected"}, 200, "")
	f.call("POST", ambiguousReply, "", reply, 200, "")
	f.call("POST", ambiguousReply, "", map[string]string{"answer": "duplicate replacement"}, 409, "")
	f.call("GET", remotePath+"/questions/"+ambiguous.ID, remote.Token, nil, 409, "")
	f.call("POST", "/v1/requests/"+remoteQuestion.ID+"/reply", "", reply, 409, "")
	f.call("POST", "/v1/requests/"+localQuestion.ID+"/reply", "", reply, 200, "")
	var q Question
	if err := json.Unmarshal(f.call("GET", remotePath+"/questions/"+ambiguous.ID, "", nil, 200, ""), &q); err != nil {
		t.Fatal(err)
	}
	if q.Status != "answered" || q.Delivery != "unknown" || q.Answer != reply["answer"] {
		t.Fatalf("ambiguous reply lost its evidence: %+v", q)
	}
	if err := json.Unmarshal(f.call("GET", remotePath+"/questions/"+remoteQuestion.ID, "", nil, 200, ""), &q); err != nil {
		t.Fatal(err)
	}
	if q.Status != "pending" || q.ID != remoteQuestion.ID {
		t.Fatalf("original remote request changed after disconnect: %+v", q)
	}
	reconcile := "/v1/requests/" + ambiguous.ID + "/reconcile"
	f.call("POST", reconcile, remote.Token, nil, 403, "")
	f.call("POST", reconcile, local.Token, nil, 403, "")
	f.call("POST", "/v1/requests/"+remoteQuestion.ID+"/reconcile", "", nil, 409, "")
	var evidence sshReplyEvidence
	checkEvidence := func(expected string) {
		t.Helper()
		if err := json.Unmarshal(f.call("POST", reconcile, coordinator.Token, nil, 200, ""), &evidence); err != nil {
			t.Fatal(err)
		}
		if evidence.RequestID != ambiguous.ID || evidence.Delivery != expected || evidence.Source != "native_history" {
			t.Fatalf("unexpected reconciliation evidence: %+v", evidence)
		}
	}
	checkEvidence("unknown")
	answerKnown = true
	checkEvidence("confirmed")
	f.call("GET", remotePath+"/questions/"+ambiguous.ID, remote.Token, nil, 409, "")
}
