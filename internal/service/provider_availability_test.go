package service

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestConfirmedClaudeExitPreservesOutcomeAndClosesOnlyItsInbox(t *testing.T) {
	for _, raceClaim := range []bool{false, true} {
		name := "unclaimed"
		if raceClaim {
			name = "claim response lost"
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			coordinator := f.run()
			worker := f.delegate(coordinator, "original")
			sibling := f.delegate(coordinator, "sibling")
			path := "/v1/workers/" + worker.ID
			for _, candidate := range []LaunchSpec{worker, sibling} {
				target := "/v1/workers/" + candidate.ID
				f.call("POST", target+"/native-session", "", NativeSession{"local-claude", candidate.ID}, 200, "")
				f.call("POST", target+"/state", candidate.Token, map[string]string{"state": "working"}, 200, "")
				f.call("POST", target+"/control/ready", candidate.Token, struct{}{}, 200, "")
				f.call("POST", target+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
			}

			followUp := map[string]any{"text": "another turn", "generation": 2}
			var receipt WorkerFollowUp
			accepted := f.call("POST", path+"/messages", "", followUp, 202, "before-exit")
			if err := json.Unmarshal(accepted, &receipt); err != nil {
				t.Fatal(err)
			}
			f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
			want := "cancelled"
			if raceClaim {
				f.call("POST", path+"/messages/"+receipt.ID+"/claim", worker.Token, struct{}{}, 200, "")
				f.call("POST", path+"/messages", "", followUp, 202, "after-claim")
				want = "delivery_unknown"
			}

			exit := path + "/control/provider-exit"
			body := map[string]string{"harness_instance": "local-claude", "session_id": worker.ID, "last_state": "completed"}
			f.call("POST", exit, sibling.Token, body, 403, "")
			body["session_id"] = sibling.ID
			f.call("POST", exit, worker.Token, body, 409, "")
			body["session_id"] = worker.ID
			f.call("POST", exit, worker.Token, body, 200, "")
			f.call("POST", exit, worker.Token, body, 200, "")

			refusal := f.call("POST", path+"/messages", "", followUp, 409, "after-exit")
			if !strings.Contains(string(refusal), "local Claude adapter exited") {
				t.Fatalf("follow-up did not explain the provider exit: %s", refusal)
			}
			replayed := f.call("POST", path+"/messages", "", followUp, 200, "before-exit")
			if err := json.Unmarshal(replayed, &receipt); err != nil || receipt.Status != want {
				t.Fatalf("original receipt = %+v, want %s (%v)", receipt, want, err)
			}
			f.call("POST", "/v1/workers/"+sibling.ID+"/messages", "", followUp, 202, "")

			restarted, err := New(f.dir, f.p)
			if err != nil {
				t.Fatal(err)
			}
			f.api = restarted
			var result struct {
				Workers []struct {
					State                string
					ProviderAvailability string `json:"provider_availability"`
					Control              WorkerControl
				}
			}
			run := f.call("GET", "/v1/runs/"+coordinator.RunID+"?view=ag-ui", "", nil, 200, "")
			if err := json.Unmarshal(run, &result); err != nil {
				t.Fatal(err)
			}
			got := result.Workers[1]
			if got.State != "completed" || got.ProviderAvailability != "exited" || got.Control.Held ||
				got.Control.Messages[0].Status != want || got.Control.Messages[0].End == nil {
				t.Fatalf("worker lost its completed outcome or receipt on restart: %+v", got)
			}
			if raceClaim && got.Control.Messages[1].Status != "cancelled" {
				t.Fatalf("unclaimed follow-up after the ambiguous claim was not cancelled: %+v", got.Control.Messages)
			}
			if got := result.Workers[2]; got.ProviderAvailability != "" || !got.Control.Held ||
				got.Control.Messages[0].Status != "queued" {
				t.Fatalf("other worker's control or receipt changed: %+v", got)
			}
		})
	}
}

func TestLocalClaudeReconcilesOnlyTheOriginalActiveTurnAfterRestart(t *testing.T) {
	f := newFixture(t)
	parent := f.run()
	worker := f.delegate(parent, "surviving")
	absent := f.delegate(parent, "absent")
	for _, candidate := range []LaunchSpec{worker, absent} {
		path := "/v1/workers/" + candidate.ID
		session := NativeSession{"local-claude", candidate.ID}
		f.call("POST", path+"/native-session", "", session, 200, "")
		f.call("POST", path+"/state", candidate.Token, map[string]string{"state": "working"}, 200, "")
		f.call("POST", path+"/control/ready", candidate.Token, map[string]any{"provider_session": session,
			"session_capabilities": SessionCapabilities{CanInterrupt: true}}, 200, "")
		f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
	}
	restarted, err := New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.api = restarted
	project := func(index int) struct {
		State                string
		ProviderAvailability string `json:"provider_availability"`
		Control              WorkerControl
	} {
		t.Helper()
		var run struct {
			Workers []struct {
				State                string
				ProviderAvailability string `json:"provider_availability"`
				Control              WorkerControl
			}
		}
		if err := json.Unmarshal(f.call("GET", "/v1/runs/"+parent.RunID+"?view=ag-ui", "", nil, 200, ""), &run); err != nil {
			t.Fatal(err)
		}
		return run.Workers[index]
	}
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/output", worker.Token, map[string]string{"text": "a queued terminal diagnostic"}, 200, "")
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 409, "")
	f.call("POST", path+"/control/ready", worker.Token, map[string]bool{"idle": true}, 200, "")
	if got := project(1); got.State != "unknown" || got.ProviderAvailability != "checking" || !got.Control.Held {
		t.Fatalf("restart or diagnostic did not preserve pending reconciliation: %+v", got)
	}
	f.call("POST", path+"/interrupt", "", nil, 409, "")
	report := map[string]any{"session": NativeSession{"local-claude", worker.ID}, "turn_id": "initial-" + worker.ID, "generation": 2}
	route := path + "/control/reconcile"
	f.call("POST", route, absent.Token, report, 403, "")
	report["generation"] = 1
	f.call("POST", route, worker.Token, report, 409, "")
	report["generation"] = 2
	report["turn_id"] = "initial-" + absent.ID
	f.call("POST", route, worker.Token, report, 409, "")
	report["turn_id"] = "initial-" + worker.ID
	report["session"] = NativeSession{"local-claude", absent.ID}
	f.call("POST", route, worker.Token, report, 409, "")
	report["session"] = NativeSession{"local-claude", worker.ID}
	f.call("POST", route, worker.Token, report, 200, "")
	f.call("POST", route, worker.Token, report, 200, "")
	if got := project(1); got.State != "working" || got.ProviderAvailability != "available" || !got.Control.Held || got.Control.Generation != 2 {
		t.Fatalf("original runner did not restore its existing turn and input lease: %+v", got)
	}
	f.call("POST", path+"/interrupt", "", nil, 202, "")
	f.call("POST", "/v1/workers/"+absent.ID+"/interrupt", "", nil, 409, "")
	if got := project(2); got.State != "unknown" || got.ProviderAvailability != "checking" {
		t.Fatalf("absent worker was considered recovered: %+v", got)
	}
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", route, worker.Token, report, 409, "")
}
