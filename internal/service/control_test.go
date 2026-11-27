package service

import (
	"encoding/json"
	"testing"
	"time"
)

func TestHeldWorkersStayAddressableAfterCoordinatorFinishes(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	first := f.delegate(coordinator, "first")
	second := f.delegate(coordinator, "second")
	path := func(w LaunchSpec) string { return "/v1/workers/" + w.ID }
	for _, worker := range []LaunchSpec{first, second} {
		f.call("POST", path(worker)+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
		f.call("POST", path(worker)+"/control/ready", worker.Token, struct{}{}, 200, "")
		f.call("POST", path(worker)+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
	}
	complete := map[string]string{"state": "completed"}
	f.call("POST", path(coordinator)+"/state", coordinator.Token, complete, 200, "")
	for _, worker := range []LaunchSpec{first, second} {
		f.call("POST", path(worker)+"/control/finish", worker.Token, complete, 200, "")
	}
	restarted, err := New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.api = restarted
	handBack := map[string]any{"held": false, "generation": 2}
	f.call("POST", path(first)+"/control", "", handBack, 200, "")
	var feed workerControlFeed
	if err := json.Unmarshal(f.call("GET", path(second)+"/control", second.Token, nil, 200, ""), &feed); err != nil ||
		!feed.Live || feed.State != "completed" || feed.Generation != 2 {
		t.Fatalf("remaining held worker cannot receive another turn after restart: %+v, %v", feed, err)
	}
	prompt := map[string]any{"generation": 2, "text": "another turn"}
	var sent WorkerFollowUp
	if err := json.Unmarshal(f.call("POST", path(second)+"/messages", "", prompt, 202, "again"), &sent); err != nil {
		t.Fatal(err)
	}
	f.call("POST", path(second)+"/messages/"+sent.ID+"/claim", second.Token, struct{}{}, 200, "")
	f.call("POST", path(second)+"/control/finish", second.Token, map[string]string{"state": "completed", "message_id": sent.ID}, 200, "")
	f.call("POST", path(second)+"/control", "", handBack, 200, "")
	var run Run
	if err := json.Unmarshal(f.call("GET", "/v1/runs/"+coordinator.RunID, "", nil, 200, ""), &run); err != nil || run.Status != "completed" {
		t.Fatalf("last handback did not complete the run: %s, %v", run.Status, err)
	}
}

func TestNativeWorkerRepliesFollowInputControl(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "answer routing")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")

	ask := func(spec LaunchSpec, prompt string) string {
		t.Helper()
		var question Question
		raw := f.call("POST", "/v1/workers/"+spec.ID+"/questions", spec.Token,
			map[string]any{"question": prompt, "choices": []QuestionChoice{{ID: "allow", Label: "Allow once"}}}, 201, "")
		if err := json.Unmarshal(raw, &question); err != nil {
			t.Fatal(err)
		}
		return "/v1/requests/" + question.ID + "/reply"
	}
	control := func(held bool, generation int) {
		t.Helper()
		f.call("POST", path+"/control", "", map[string]any{"held": held, "generation": generation}, 200, "")
	}
	nativeReply := func(target string, generation, code int) {
		t.Helper()
		f.call("POST", target, "", map[string]any{"answer": "allow", "generation": generation}, code, "")
	}
	ownerAnswer := map[string]string{"answer": "allow"}

	agentRequest := ask(worker, "Coordinator decision")
	nativeReply(agentRequest, 1, 409)
	f.call("POST", agentRequest, coordinator.Token, ownerAnswer, 200, "")

	control(true, 1)
	heldRequest := ask(worker, "Developer decision")
	f.call("POST", heldRequest, coordinator.Token, ownerAnswer, 409, "")
	nativeReply(heldRequest, 2, 200)

	returned := ask(worker, "Back to coordinator")
	control(false, 2)
	nativeReply(returned, 2, 409)
	nativeReply(heldRequest, 2, 200) // The same settled answer remains idempotent.
	control(true, 3)
	nativeReply(returned, 2, 409)
	control(false, 4)
	f.call("POST", returned, coordinator.Token, ownerAnswer, 200, "")

	escalation := ask(coordinator, "Needs the developer")
	f.call("POST", escalation, "", ownerAnswer, 200, "")
}

func TestManagedWorkerControl(t *testing.T) {
	f := newFixture(t)
	coord := f.run()
	worker := f.delegate(coord, "controlled")
	neighbor := f.delegate(coord, "neighbor")
	path := "/v1/workers/" + worker.ID
	for _, spec := range []LaunchSpec{worker, neighbor} {
		target := "/v1/workers/" + spec.ID
		f.call("POST", target+"/state", spec.Token, map[string]string{"state": "working"}, 200, "")
		f.call("POST", target+"/control/ready", spec.Token, struct{}{}, 200, "")
	}
	var q Question
	if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token, map[string]string{"question": "Which value?"}, 201, ""), &q); err != nil {
		t.Fatal(err)
	}
	take := map[string]any{"held": true, "generation": 1}
	f.call("POST", path+"/control", coord.Token, take, 403, "")
	f.call("POST", path+"/messages", neighbor.Token, map[string]string{"text": "wrong worker"}, 403, "")
	f.call("POST", path+"/messages", coord.Token, map[string]string{"text": "queued before takeover"}, 202, "")
	f.call("POST", path+"/control", "", take, 200, "")
	f.call("POST", path+"/messages", coord.Token, map[string]string{"text": "blocked by takeover"}, 409, "")
	f.call("POST", path+"/interrupt", coord.Token, nil, 409, "")
	f.call("POST", path+"/stop", coord.Token, nil, 409, "")
	reply := "/v1/requests/" + q.ID + "/reply"
	f.call("POST", reply, coord.Token, map[string]string{"answer": "blocked"}, 409, "")
	f.call("POST", reply, "", map[string]string{"answer": "literal"}, 200, "")

	literal := "  use \"$HOME\" and `literal`\n\tsecond line\n"
	in := map[string]any{"text": literal, "generation": 2}
	var sent, replay WorkerFollowUp
	if err := json.Unmarshal(f.call("POST", path+"/messages", "", in, 202, "literal"), &sent); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(f.call("POST", path+"/messages", "", in, 200, "literal"), &replay); err != nil {
		t.Fatal(err)
	}
	if sent != replay || sent.Text != literal || sent.Status != "queued" {
		t.Fatalf("wrong delivery receipt: %+v, replay %+v", sent, replay)
	}
	claim := path + "/messages/" + sent.ID + "/claim"
	f.call("POST", claim, worker.Token, struct{}{}, 409, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	var claimed WorkerFollowUp
	if err := json.Unmarshal(f.call("POST", claim, worker.Token, struct{}{}, 200, ""), &claimed); err != nil {
		t.Fatal(err)
	}
	if claimed.ID != sent.ID || claimed.Text != literal || claimed.Status != "processing" {
		t.Fatalf("wrong claimed message: %+v", claimed)
	}

	f.call("POST", path+"/interrupt", "", nil, 202, "")
	interrupt := path + "/control/interrupt/claim"
	f.call("POST", interrupt, worker.Token, map[string]int{"generation": 1}, 409, "")
	f.call("POST", interrupt, worker.Token, map[string]int{"generation": 2}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "idle", "message_id": sent.ID}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": false, "generation": 2}, 200, "")
	f.call("POST", path+"/messages", "", in, 409, "")
	f.call("POST", path+"/messages", coord.Token, map[string]string{"text": "accepted after handback"}, 202, "")
	f.call("POST", path+"/stop", "", nil, 202, "")
	select {
	case id := <-f.p.stops:
		if id != worker.ID {
			t.Fatalf("stop targeted %s instead of %s", id, worker.ID)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("per-worker stop was not dispatched")
	}
	var run Run
	if err := json.Unmarshal(f.call("GET", "/v1/runs/"+coord.RunID, "", nil, 200, ""), &run); err != nil {
		t.Fatal(err)
	}
	c := run.Workers[1].Control
	if run.Status != "running" || run.Workers[2].State != "working" || c.Held || c.InterruptRequested ||
		len(c.Messages) != 3 || c.Messages[0].Status != "cancelled" || c.Messages[1].Status != "interrupted" || c.Messages[2].Status != "cancelled" {
		t.Fatalf("wrong scope or message history: run %s, neighbor %s, control %+v", run.Status, run.Workers[2].State, c)
	}
}

func TestRegisteredSessionCapabilitiesGateInterrupts(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "capability negotiation")
	path := "/v1/workers/" + worker.ID
	infoPath := "/v1/ag-ui/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/interrupt", "", nil, 409, "")
	ready := func(caps *SessionCapabilities) WorkerControl {
		t.Helper()
		var body any = struct{}{}
		if caps != nil {
			body = map[string]any{"session_capabilities": caps}
		}
		var control WorkerControl
		if err := json.Unmarshal(f.call("POST", path+"/control/ready", worker.Token, body, 200, ""), &control); err != nil {
			t.Fatal(err)
		}
		return control
	}
	checkInfo := func(want *SessionCapabilities) {
		t.Helper()
		var info struct {
			SessionCapabilities *SessionCapabilities `json:"sessionCapabilities"`
		}
		if err := json.Unmarshal(f.call("GET", infoPath, "", nil, 200, ""), &info); err != nil {
			t.Fatal(err)
		}
		if want == nil && info.SessionCapabilities != nil || want != nil && (info.SessionCapabilities == nil || *info.SessionCapabilities != *want) {
			t.Fatalf("published session capabilities = %+v, want %+v", info.SessionCapabilities, want)
		}
	}

	ready(nil)
	checkInfo(nil)
	f.call("POST", path+"/interrupt", "", nil, 202, "")
	limited := &SessionCapabilities{CanReadHistory: true}
	control := ready(limited)
	if control.InterruptRequested || control.InterruptClaimed {
		t.Fatal("capability downgrade kept an undispatched interrupt")
	}
	f.call("POST", path+"/control/interrupt/claim", worker.Token, map[string]int{"generation": control.Generation}, 409, "")
	f.call("POST", path+"/interrupt", "", nil, 501, "")
	ready(nil) // Older reconnect and heartbeat messages do not erase negotiation.
	checkInfo(limited)

	reloaded, err := New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.api = reloaded
	checkInfo(limited)
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/interrupt", "", nil, 501, "")
	full := &SessionCapabilities{CanAnswer: true, CanInterrupt: true, CanReadHistory: true}
	ready(full)
	checkInfo(full)
	f.call("POST", path+"/interrupt", "", nil, 202, "")
	f.call("POST", path+"/control/interrupt/claim", worker.Token, map[string]int{"generation": control.Generation}, 200, "")
	control = ready(limited)
	if !control.InterruptRequested || !control.InterruptClaimed {
		t.Fatal("capability downgrade lost evidence of an interrupt already dispatched")
	}
}
