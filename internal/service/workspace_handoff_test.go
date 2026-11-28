package service

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func workspaceHandoffOutput(t *testing.T, body []byte) workspaceHandoffStatus {
	t.Helper()
	var result workspaceHandoffStatus
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestWorkspaceHandoffAutoStartAndReplay(t *testing.T) {
	f := newFixture(t)
	anchor := f.run()
	route := "/v1/network/workspace-handoffs/child-one"
	in := workspaceHandoffInput{Workspace: "workspace", Anchor: anchor.RunID, Title: "Review", Text: "Review the patch.", ExpiresAt: time.Now().Add(time.Hour)}
	f.call("GET", route, anchor.Token, nil, 403, "")
	f.call("POST", route, anchor.Token, in, 403, "")
	f.call("POST", route, "", in, 409, "")
	// A busy coordinator is never bypassed by starting another one.
	in.AutoStart = true
	f.call("POST", route, "", in, 409, "")
	f.call("POST", "/v1/workers/"+anchor.ID+"/state", anchor.Token, map[string]string{"state": "completed"}, 200, "")
	in.AutoStart = false
	f.call("POST", route, "", in, 409, "")
	in.AutoStart = true
	queued := workspaceHandoffOutput(t, f.call("POST", route, "", in, 202, ""))
	worker := f.launched()
	if !worker.WorkspaceCoordinator || worker.RunID != queued.Run || worker.ID != queued.Worker || worker.Path != anchor.Path ||
		queued.State != "queued" || queued.AcceptedAt != "" || queued.VerifiedAt != "" {
		t.Fatalf("incorrect startup receipt: %+v", queued)
	}
	restarted, err := New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.api = restarted
	in.AutoStart = false
	replay := workspaceHandoffOutput(t, f.call("POST", route, "", in, 200, ""))
	if replay != queued {
		t.Fatalf("replayed receipt after restart changed: %+v", replay)
	}
	select {
	case <-f.p.starts:
		t.Fatal("handoff replay started a second coordinator")
	default:
	}
	in.Text = "different intent"
	f.call("POST", route, "", in, 409, "")
	work := "/v1/workers/" + worker.ID
	f.call("POST", work+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", work+"/control/ready", worker.Token, struct{}{}, 200, "")
	accepted := workspaceHandoffOutput(t, f.call("GET", route, "", nil, 200, ""))
	if accepted.State != "accepted" || accepted.AcceptedAt == "" || accepted.VerifiedAt != "" {
		t.Fatalf("worker claim was not recorded separately: %+v", accepted)
	}
	f.call("POST", work+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", work+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	done := workspaceHandoffOutput(t, f.call("GET", route, "", nil, 200, ""))
	if done.State != "unverified" || done.Failure != "missing_evidence" ||
		done.AcceptedAt != accepted.AcceptedAt || done.VerifiedAt != "" {
		t.Fatalf("generic provider completion became verified: %+v", done)
	}
}

func TestWorkspaceHandoffPreservesDeveloperControlAndVerifiesExactTurn(t *testing.T) {
	f := newFixture(t)
	anchor := f.run()
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = anchor.Path
		data, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v: %s", args, err, data)
		}
		return strings.TrimSpace(string(data))
	}
	git("init")
	git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-m", "expected")
	head := git("rev-parse", "HEAD")
	f.call("POST", "/v1/workers/"+anchor.ID+"/state", anchor.Token, map[string]string{"state": "completed"}, 200, "")
	in := workspaceHandoffInput{Workspace: "workspace", Anchor: anchor.RunID, Title: "Handoff", Text: "Check checkout.", AutoStart: true, ExpiresAt: time.Now().Add(time.Hour)}
	f.call("POST", "/v1/network/workspace-handoffs/start", "", in, 202, "")
	worker := f.launched()
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	route := "/v1/network/workspace-handoffs/child-two"
	in.ExpectedHead = head
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
	f.call("POST", route, "", in, 409, "")
	f.call("POST", path+"/control", "", map[string]any{"held": false, "generation": 2}, 200, "")
	queued := workspaceHandoffOutput(t, f.call("POST", route, "", in, 202, ""))
	if queued.Run != worker.RunID || queued.Worker != worker.ID || queued.Operation == "" || queued.State != "queued" || queued.AcceptedAt != "" {
		t.Fatalf("handoff failed to target the original idle coordinator: %+v", queued)
	}
	f.call("POST", "/v1/network/workspace-handoffs/child-three", "", in, 409, "")
	oldControl := "/messages/" + queued.Operation + "/claim"
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 3}, 200, "")
	f.call("POST", path+oldControl, worker.Token, struct{}{}, 409, "")
	cancelled := workspaceHandoffOutput(t, f.call("GET", route, "", nil, 200, ""))
	if cancelled.State != "failed" || cancelled.Failure != "developer_control_changed" || cancelled.AcceptedAt != "" {
		t.Fatalf("developer takeover let a workspace turn survive its original generation: %+v", cancelled)
	}
	f.call("POST", path+"/control", "", map[string]any{"held": false, "generation": 4}, 200, "")
	f.call("POST", path+oldControl, worker.Token, struct{}{}, 409, "")
	route = "/v1/network/workspace-handoffs/child-three"
	queued = workspaceHandoffOutput(t, f.call("POST", route, "", in, 202, ""))
	f.call("POST", path+"/messages/"+queued.Operation+"/claim", worker.Token, struct{}{}, 200, "")
	before := workspaceHandoffOutput(t, f.call("GET", route, "", nil, 200, ""))
	if before.State != "accepted" || before.AcceptedAt == "" || before.VerifiedAt != "" {
		t.Fatalf("claim became verified prematurely: %+v", before)
	}
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed", "message_id": "wrong-message"}, 409, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed", "message_id": queued.Operation}, 200, "")
	done := workspaceHandoffOutput(t, f.call("GET", route, "", nil, 200, ""))
	if done.State != "verified" || done.Head != head || done.VerifiedAt == "" || done.AcceptedAt != before.AcceptedAt {
		t.Fatalf("missing proof from exact completed handoff: %+v", done)
	}
	git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-m", "later")
	preserved := workspaceHandoffOutput(t, f.call("GET", route, "", nil, 200, ""))
	if preserved != done {
		t.Fatalf("later checkout change rewrote completed evidence: %+v", preserved)
	}
}

func TestWorkspaceHandoffConcurrentAutoStartReservesOneCoordinator(t *testing.T) {
	f := newFixture(t)
	anchor := f.run()
	f.call("POST", "/v1/workers/"+anchor.ID+"/state", anchor.Token, map[string]string{"state": "completed"}, 200, "")
	in := workspaceHandoffInput{Workspace: "workspace", Anchor: anchor.RunID, Title: "Handoff", Text: "Check checkout.", AutoStart: true, ExpiresAt: time.Now().Add(time.Hour)}
	body, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	ready := make(chan struct{})
	result := make(chan int, 2)
	for _, id := range []string{"child-a", "child-b"} {
		go func(id string) {
			<-ready
			rec := httptest.NewRecorder()
			request := httptest.NewRequest(http.MethodPost, "/v1/network/workspace-handoffs/"+id, bytes.NewReader(body))
			f.api.ServeHTTP(rec, request)
			result <- rec.Code
		}(id)
	}
	close(ready)
	first, second := <-result, <-result
	if !((first == http.StatusAccepted && second == http.StatusConflict) ||
		(first == http.StatusConflict && second == http.StatusAccepted)) {
		t.Fatalf("concurrent handoffs did not reserve exactly one coordinator: %d / %d", first, second)
	}
	f.launched()
	select {
	case <-f.p.starts:
		t.Fatal("concurrent handoffs started two coordinators")
	default:
	}
}

func TestWorkspaceHandoffRejectsExpiredClaimAndReleasesInbox(t *testing.T) {
	f := newFixture(t)
	anchor := f.run()
	f.call("POST", "/v1/workers/"+anchor.ID+"/state", anchor.Token, map[string]string{"state": "completed"}, 200, "")
	in := workspaceHandoffInput{Workspace: "workspace", Anchor: anchor.RunID, Title: "Handoff", Text: "Check checkout.",
		AutoStart: true, ExpiresAt: time.Now().Add(time.Hour)}
	f.call("POST", "/v1/network/workspace-handoffs/start", "", in, 202, "")
	worker := f.launched()
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")

	route := "/v1/network/workspace-handoffs/short-lived"
	in.ExpiresAt = time.Now().Add(time.Second)
	send := workspaceHandoffOutput(t, f.call("POST", route, "", in, 202, ""))
	<-time.After(time.Until(in.ExpiresAt))
	f.call("POST", path+"/messages/"+send.Operation+"/claim", worker.Token, struct{}{}, 409, "")
	expired := workspaceHandoffOutput(t, f.call("GET", route, "", nil, 200, ""))
	if expired.State != "failed" || expired.Failure != "handoff_expired" || expired.AcceptedAt != "" {
		t.Fatalf("expired handoff acquired an admission: %+v", expired)
	}
	replay := workspaceHandoffOutput(t, f.call("POST", route, "", in, 200, ""))
	if replay != expired {
		t.Fatalf("expiry failure was lost on replay: %+v", replay)
	}
	in.ExpiresAt = time.Now().Add(time.Hour)
	f.call("POST", "/v1/network/workspace-handoffs/following", "", in, 202, "")
}
