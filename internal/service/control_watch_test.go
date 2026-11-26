package service

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestWorkerControlWaitWakesForAddressedApproval(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "control-watch")
	other := f.delegate(coordinator, "unrelated-worker")
	path := "/v1/workers/" + worker.ID
	turn := "initial-" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/native-session", "", NativeSession{HarnessInstance: "fixture", SessionID: "first"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")

	var q Question
	choice := QuestionChoice{ID: "allow_once", Label: "Allow once"}
	input := map[string]any{
		"question": "Read fixture?", "choices": []QuestionChoice{choice},
		"provider_turn": turn, "provider_request": "provider-request",
	}
	if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token, input, 201, ""), &q); err != nil {
		t.Fatal(err)
	}
	route := path + "/control?turn=" + turn
	var first workerControlFeed
	if err := json.Unmarshal(f.call("GET", route, worker.Token, nil, 200, ""), &first); err != nil {
		t.Fatal(err)
	}
	if first.Revision == "" || len(first.Answers) != 0 {
		t.Fatalf("invalid control snapshot: %+v", first)
	}
	f.call("GET", route, other.Token, nil, 403, "")

	request := httptest.NewRequest("GET", route+"&after="+first.Revision+"&wait_seconds=25", nil)
	request.Header.Set("Authorization", "Bearer "+worker.Token)
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		w := httptest.NewRecorder()
		f.api.ServeHTTP(w, request)
		done <- w
	}()
	f.call("POST", "/v1/workers/"+other.ID+"/questions", other.Token, map[string]string{"question": "Unrelated?"}, 201, "")
	select {
	case w := <-done:
		t.Fatalf("unrelated mutation ended the wait: %s", w.Body)
	case <-time.After(30 * time.Millisecond):
	}
	f.call("POST", "/v1/requests/"+q.ID+"/reply", "", map[string]string{"answer": choice.ID}, 200, "")
	select {
	case w := <-done:
		var next workerControlFeed
		if err := json.Unmarshal(w.Body.Bytes(), &next); err != nil {
			t.Fatal(err)
		}
		want := workerControlAnswer{ID: q.ID, ProviderRequest: "provider-request", Choice: choice.ID}
		if w.Code != 200 || next.Revision == first.Revision || len(next.Answers) != 1 || next.Answers[0] != want {
			t.Fatalf("worker did not receive its addressed approval: %d %+v", w.Code, next)
		}
	case <-time.After(time.Second):
		t.Fatal("committed answer did not wake the worker")
	}

	var pending Question
	input["provider_request"] = "pending-2"
	if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token, input, 201, ""), &pending); err != nil {
		t.Fatal(err)
	}
	var interrupt WorkerControl
	if err := json.Unmarshal(f.call("POST", path+"/interrupt", "", nil, 202, ""), &interrupt); err != nil || interrupt.Interrupt == nil {
		t.Fatalf("active ACP turn had no interrupt receipt: %+v, %v", interrupt, err)
	}
	f.call("POST", path+"/control/interrupt/claim", worker.Token, map[string]any{
		"generation": 1, "permission_turn_id": turn, "id": interrupt.Interrupt.ID, "turn_id": turn,
	}, 200, "")
	f.call("POST", "/v1/requests/"+pending.ID+"/reply", "", map[string]string{"answer": choice.ID}, 409, "")
	var retired Question
	if err := json.Unmarshal(f.call("GET", path+"/questions/"+pending.ID, worker.Token, nil, 200, ""), &retired); err != nil || retired.Status != "cancelled" {
		t.Fatalf("claimed interrupt left permission available: %+v, %v", retired, err)
	}
	input["provider_request"] = "arrived-after-interrupt"
	if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token, input, 200, ""), &retired); err != nil || retired.Status != "cancelled" {
		t.Fatalf("late provider permission became actionable: %+v, %v", retired, err)
	}
}

type blockedLaunchCheck struct {
	recorder
	started chan struct{}
	release chan struct{}
}

func (p blockedLaunchCheck) CheckClient(client string) error {
	if client == "slow" {
		close(p.started)
		<-p.release
	}
	return nil
}

func TestLaunchCheckDoesNotBlockServiceAndRevalidatesCapacity(t *testing.T) {
	f := newFixture(t)
	p := blockedLaunchCheck{recorder: f.p, started: make(chan struct{}), release: make(chan struct{})}
	defer close(p.release)
	var err error
	f.api, err = New(f.dir, p)
	if err != nil {
		t.Fatal(err)
	}
	f.call("POST", "/v1/runs", "", map[string]any{"path": f.dir, "task": "launch", "worker_limit": 1}, 201, "")
	parent := f.launched()
	route := "/v1/runs/" + parent.RunID + "/workers"
	reply := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		req := httptest.NewRequest("POST", route, bytes.NewBufferString(`{"name":"slow","task":"inspect","client":"slow"}`))
		req.Header.Set("Authorization", "Bearer "+parent.Token)
		w := httptest.NewRecorder()
		f.api.ServeHTTP(w, req)
		reply <- w
	}()
	select {
	case <-p.started:
	case <-time.After(time.Second):
		t.Fatal("external check was not called")
	}
	read := make(chan int, 1)
	go func() {
		w := httptest.NewRecorder()
		f.api.ServeHTTP(w, httptest.NewRequest("GET", "/v1/runs", nil))
		read <- w.Code
	}()
	select {
	case code := <-read:
		if code != http.StatusOK {
			t.Fatalf("unrelated read returned %d", code)
		}
	case <-time.After(time.Second):
		t.Fatal("external check blocked an unrelated read")
	}
	f.delegate(parent, "fills-capacity")
	// Send to the check rather than closing its channel so early failures can
	// still release the goroutine through the deferred close above.
	p.release <- struct{}{}
	select {
	case w := <-reply:
		if w.Code != http.StatusConflict {
			t.Fatalf("slow launch reserved a slot after capacity changed: %d %s", w.Code, w.Body)
		}
	case <-time.After(time.Second):
		t.Fatal("launch returned no outcome after the check")
	}
}

func TestProviderStopReasonKeepsFollowUpAvailable(t *testing.T) {
	for _, reason := range []string{"max_tokens", "max_turn_requests", "refusal"} {
		t.Run(reason, func(t *testing.T) {
			f := newFixture(t)
			worker := f.delegate(f.run(), "stop-reason")
			path := "/v1/workers/" + worker.ID
			f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
			f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
			f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
			f.call("POST", path+"/control/finish", worker.Token, map[string]string{
				"state": "idle", "stop_reason": reason,
			}, 200, "")
			var sent WorkerFollowUp
			if err := json.Unmarshal(f.call("POST", path+"/messages", "", map[string]any{
				"generation": 2, "text": "continue explicitly",
			}, 202, reason), &sent); err != nil {
				t.Fatal(err)
			}
			f.call("POST", path+"/messages/"+sent.ID+"/claim", worker.Token, struct{}{}, 200, "")
			var result Worker
			if err := json.Unmarshal(f.call("POST", path+"/control/finish", worker.Token, map[string]any{
				"state": "idle", "stop_reason": reason, "message_id": sent.ID,
			}, 200, ""), &result); err != nil {
				t.Fatal(err)
			}
			message := result.Control.message(sent.ID)
			if result.State != "idle" || result.Control.LastStopReason != reason || message == nil ||
				message.Status != "completed" || message.StopReason != reason {
				t.Fatalf("provider stop lost its outcome or closed the worker: %+v, %+v", result, message)
			}
		})
	}
}
