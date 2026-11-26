package service

import (
	"encoding/json"
	"testing"

	"agentcommander/internal/acpprocessor"
)

func TestV2PermissionSurvivesForegroundAndDismissesByIdentity(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "v2-worker")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/native-session", "", map[string]any{
		"session_id": "peer", "harness_instance": "fixture", "peer_capabilities": SessionCapabilities{ProtocolVersion: 2},
	}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	question := func(id string) string {
		var q Question
		if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token, map[string]any{
			"question": "Read fixture?", "choices": []QuestionChoice{{ID: "once", Label: "Allow once"}},
			"provider_turn": ACPSessionPermissionScope, "provider_request": id,
		}, 201, ""), &q); err != nil {
			t.Fatal(err)
		}
		return q.ID
	}
	first, second := question("background-a"), question("background-b")
	f.call("POST", path+"/control/finish", worker.Token, map[string]any{
		"state": "completed", "observed_turn_end": true, "stop_reason": "end_turn",
	}, 200, "")
	f.call("POST", path+"/questions/dismiss-provider", worker.Token, map[string]string{"provider_request": "background-a"}, 200, "")
	f.call("POST", "/v1/requests/"+first+"/reply", "", map[string]string{"answer": "once"}, 409, "")
	f.call("POST", "/v1/requests/"+second+"/reply", "", map[string]string{"answer": "once"}, 200, "")
	var control workerControlFeed
	if err := json.Unmarshal(f.call("GET", path+"/control?turn=%24session", worker.Token, nil, 200, ""), &control); err != nil {
		t.Fatal(err)
	}
	if len(control.Answers) != 1 || control.Answers[0].ProviderRequest != "background-b" {
		t.Fatalf("permission outcome scope: %+v", control.Answers)
	}
}

func TestV2MessagePatchPreservesFirstPosition(t *testing.T) {
	update := func(seq int, op, text string) ConsoleEvent {
		return ConsoleEvent{Kind: "text", Text: text, Sequence: seq, ACP: &acpprocessor.Activity{
			Source: "live", Kind: "agent_message", MessageID: "peer-message", MessageOp: op,
		}}
	}
	events := []ConsoleEvent{update(1, "append", "partial "), {Kind: "output", Sequence: 2, Text: "notice"},
		update(3, "replace", "corrected"), update(4, "append", " answer")}
	result := aguiMessages("worker", events)
	if len(result) != 2 || result[0].sequence != 1 || *result[0].Content != "corrected answer" ||
		result[1].sequence != 2 || *result[1].Content != "notice" {
		t.Fatalf("message patch moved or duplicated the row: %+v", result)
	}
	if plainConsole(events) {
		t.Fatal("message patches must leave the append-only projection")
	}
}
