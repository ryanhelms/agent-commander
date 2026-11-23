package service

import (
	"encoding/json"
	"testing"
	"time"
)

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
