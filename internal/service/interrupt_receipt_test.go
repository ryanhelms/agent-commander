package service

import (
	"encoding/json"
	"testing"
)

func TestLocalClaudeInterruptRetainsDispatchAndOriginalTurnOutcome(t *testing.T) {
	for _, observed := range []bool{true, false} {
		name := "confirmed turn end"
		if !observed {
			name = "unknown after provider loss"
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			parent := f.run()
			worker := f.delegate(parent, "interrupt-target")
			sibling := f.delegate(parent, "sibling")
			path := "/v1/workers/" + worker.ID
			session := NativeSession{"local-claude", worker.ID}
			f.call("POST", path+"/native-session", "", session, 200, "")
			f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
			f.call("POST", path+"/control/ready", worker.Token, map[string]any{"provider_session": session,
				"session_capabilities": SessionCapabilities{CanInterrupt: true}}, 200, "")
			f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
			turn := "initial-" + worker.ID
			input := map[string]any{"turn_id": turn, "generation": 2}
			type interruptReceipt struct {
				ID         string
				TurnID     string `json:"turn_id"`
				Generation int
				Phase      string
				Outcome    string
			}
			type controlProjection struct {
				Interrupt interruptReceipt
			}
			decode := func(raw []byte) interruptReceipt {
				t.Helper()
				var control controlProjection
				if err := json.Unmarshal(raw, &control); err != nil {
					t.Fatal(err)
				}
				return control.Interrupt
			}
			request := decode(f.call("POST", path+"/interrupt", "", input, 202, ""))
			if request.ID == "" || request.Phase != "accepted" || request.TurnID != turn || request.Generation != 2 || request.Outcome != "" {
				t.Fatalf("missing accepted interrupt receipt: %+v", request)
			}
			if repeat := decode(f.call("POST", path+"/interrupt", "", input, 200, "")); repeat != request {
				t.Fatalf("interrupt retry created another operation: %+v", repeat)
			}
			claim := map[string]any{"id": request.ID, "turn_id": turn, "generation": 2}
			claimRoute := path + "/control/interrupt/claim"
			claim["turn_id"] = "initial-" + sibling.ID
			f.call("POST", claimRoute, worker.Token, claim, 409, "")
			claim["turn_id"] = turn
			claimed := decode(f.call("POST", claimRoute, worker.Token, claim, 200, ""))
			if claimed.ID != request.ID || claimed.Phase != "claimed" || claimed.Outcome != "" {
				t.Fatalf("the original controlled turn was not claimed: %+v", claimed)
			}
			claim["phase"] = "sent"
			report := path + "/control/interrupt/report"
			f.call("POST", report, sibling.Token, claim, 403, "")
			delivered := decode(f.call("POST", report, worker.Token, claim, 200, ""))
			if delivered.Phase != "sent" || delivered.Outcome != "" || delivered.ID != request.ID {
				t.Fatalf("dispatch was treated as a confirmed cancellation: %+v", delivered)
			}

			state, expected := "idle", "interrupted"
			if !observed {
				state, expected = "failed", "unknown"
			}
			f.call("POST", path+"/control/finish", worker.Token,
				map[string]any{"state": state, "observed_turn_end": observed}, 200, "")
			receipt := decode(f.call("POST", path+"/interrupt", "", input, 200, ""))
			if receipt.ID != request.ID || receipt.Phase != "sent" || receipt.Outcome != expected {
				t.Fatalf("final interrupt lost its dispatch evidence or outcome: %+v", receipt)
			}
			restarted, err := New(f.dir, f.p)
			if err != nil {
				t.Fatal(err)
			}
			f.api = restarted
			var run struct {
				Workers []struct{ Control controlProjection }
			}
			if err := json.Unmarshal(f.call("GET", "/v1/runs/"+parent.RunID+"?view=ag-ui", "", nil, 200, ""), &run); err != nil {
				t.Fatal(err)
			}
			if got := run.Workers[1].Control.Interrupt; got != receipt {
				t.Fatalf("reconnect lost the original interrupt: got %+v, want %+v", got, receipt)
			}
		})
	}
}

func TestLocalClaudeInterruptResolvesWhenCapabilityIsWithdrawnBeforeClaim(t *testing.T) {
	f := newFixture(t)
	worker := f.delegate(f.run(), "interrupt-target")
	path := "/v1/workers/" + worker.ID
	session := NativeSession{"local-claude", worker.ID}
	f.call("POST", path+"/native-session", "", session, 200, "")
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, map[string]any{
		"provider_session": session, "session_capabilities": SessionCapabilities{CanInterrupt: true},
	}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
	input := map[string]any{"turn_id": "initial-" + worker.ID, "generation": 2}
	f.call("POST", path+"/interrupt", "", input, 202, "")
	f.call("POST", path+"/control/ready", worker.Token, map[string]any{
		"session_capabilities": SessionCapabilities{CanInterrupt: false},
	}, 200, "")
	var control WorkerControl
	if err := json.Unmarshal(f.call("POST", path+"/interrupt", "", input, 200, ""), &control); err != nil {
		t.Fatal(err)
	}
	if control.InterruptRequested || control.Interrupt == nil ||
		control.Interrupt.Phase != "accepted" || control.Interrupt.Outcome != "cancelled" {
		t.Fatalf("withdrawn capability left an unclaimed request unresolved: %+v", control.Interrupt)
	}
}
