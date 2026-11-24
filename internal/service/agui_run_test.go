package service

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestWorkerInfoSeparatesNativeHistoryFromLiveInput(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "summary")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/native-session", "", NativeSession{HarnessInstance: "local-codex", SessionID: "summary-session"}, 200, "")
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
	type workerSummary struct {
		WorkerID, Role string
		NativeHistory  bool
		Generation     *int
	}
	info := func() workerSummary {
		t.Helper()
		var summary workerSummary
		if err := json.Unmarshal(f.call("GET", "/v1/ag-ui/workers/"+worker.ID, "", nil, 200, ""), &summary); err != nil {
			t.Fatal(err)
		}
		return summary
	}
	live := info()
	if live.WorkerID != worker.ID || live.Role != "worker" || !live.NativeHistory || live.Generation == nil || *live.Generation != 2 {
		t.Fatalf("unexpected live worker summary: %+v", live)
	}
	f.call("POST", "/v1/workers/"+coordinator.ID+"/state", coordinator.Token, map[string]string{"state": "failed"}, 200, "")
	archived := info()
	if !archived.NativeHistory || archived.Generation != nil {
		t.Fatalf("terminal run advertised the wrong capabilities: %+v", archived)
	}
}

func TestAGUIPromptMediaStaysInWorkerInbox(t *testing.T) {
	f := newFixture(t)
	run := f.run()
	worker := f.delegate(run, "media target")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/native-session", "", NativeSession{HarnessInstance: "local-claude", SessionID: "media-session"}, 200, "")
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")

	runPath := "/v1/ag-ui/workers/" + worker.ID + "/run"
	input := map[string]any{
		"threadId": worker.ID, "runId": "media-run",
		"forwardedProps": map[string]int{"generation": 2},
	}
	imagePart := map[string]string{"type": "data", "mimeType": "image/png", "value": "AAH/"}
	audioPart := map[string]string{"type": "data", "mimeType": "audio/wav", "value": "AgM="}
	input["messages"] = []any{map[string]any{"role": "user", "content": []any{
		map[string]string{"type": "text", "text": "  before\n"},
		map[string]any{"type": "image", "source": imagePart},
		map[string]string{"type": "text", "text": "\tbetween\n"},
		map[string]any{"type": "audio", "source": audioPart},
		map[string]string{"type": "text", "text": "after  "},
	}}}
	f.call("POST", runPath, "", input, 501, "")
	f.call("POST", path+"/control/ready", worker.Token, map[string]any{
		"promptCapabilities": PromptCapabilities{Image: true},
	}, 200, "")
	f.call("POST", runPath, "", input, 501, "")
	f.call("POST", path+"/control/ready", worker.Token, map[string]any{
		"promptCapabilities": PromptCapabilities{Image: true, Audio: true},
	}, 200, "")
	imagePart["type"] = "url"
	f.call("POST", runPath, "", input, 501, "")
	imagePart["type"], imagePart["value"] = "data", "!invalid"
	f.call("POST", runPath, "", input, 400, "")
	imagePart["value"] = "AAH/"

	server := httptest.NewServer(f.api)
	defer server.Close()
	client := &http.Client{Timeout: 5 * time.Second}
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Post(server.URL+runPath, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatalf("prompt failed: %s", response.Status)
	}
	events := bufio.NewScanner(response.Body)
	var operation aguiRunState
	var finished bool
	for events.Scan() {
		line := events.Text()
		if strings.Contains(line, "AAH/") || strings.Contains(line, "AgM=") {
			t.Fatal("prompt media leaked into AG-UI events")
		}
		raw, ok := strings.CutPrefix(line, "data: ")
		if !ok {
			continue
		}
		var event struct {
			Type     string
			Snapshot aguiRunState
		}
		if err := json.Unmarshal([]byte(raw), &event); err != nil {
			t.Fatal(err)
		}
		if event.Type == "RUN_FINISHED" {
			finished = true
			break
		}
		if event.Type != "STATE_SNAPSHOT" || operation.OperationID != "" {
			continue
		}
		operation = event.Snapshot
		claimPath := path + "/messages/" + operation.OperationID + "/claim"
		f.call("POST", claimPath, run.Token, struct{}{}, 403, "")
		var claimed ClaimedWorkerFollowUp
		err := json.Unmarshal(f.call("POST", claimPath, worker.Token, struct{}{}, 200, ""), &claimed)
		want := []PromptPart{
			{Type: "text", Text: "  before\n"},
			{Type: "image", MIMEType: "image/png", Data: []byte{0, 1, 255}},
			{Type: "text", Text: "\tbetween\n"},
			{Type: "audio", MIMEType: "audio/wav", Data: []byte{2, 3}},
			{Type: "text", Text: "after  "},
		}
		if err != nil || !reflect.DeepEqual(claimed.Parts, want) {
			t.Fatalf("claim did not preserve ordered media: %+v, %v", claimed.Parts, err)
		}
		workspace := f.call("GET", "/v1/runs/"+run.RunID, "", nil, 200, "")
		if bytes.Contains(workspace, []byte("AAH/")) || bytes.Contains(workspace, []byte("AgM=")) {
			t.Fatal("prompt media leaked into workspace snapshot")
		}
		imagePart["value"] = "AAI/"
		f.call("POST", runPath, "", input, 409, "")
		f.call("POST", path+"/control/finish", worker.Token, map[string]string{
			"state": "completed", "message_id": operation.OperationID,
		}, 200, "")
	}
	if !finished {
		t.Fatalf("missing terminal event: %v", events.Err())
	}
	persisted, err := os.ReadFile(filepath.Join(f.dir, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(persisted, []byte(`"prompt_parts"`)) {
		t.Fatal("finished operation retained media in the private delivery inbox")
	}
}

func TestAGUIReplaysLegacyJoinedTextReceipt(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "upgrade")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")

	// The previous AG-UI endpoint submitted the same joined-text intent as
	// the plain command endpoint. Persist that receipt under the old run ID.
	var message WorkerFollowUp
	if err := json.Unmarshal(f.call("POST", path+"/messages", "", map[string]any{"text": "a b", "generation": 2}, 202, "legacy"), &message); err != nil {
		t.Fatal(err)
	}
	f.call("POST", path+"/messages/"+message.ID+"/claim", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed", "message_id": message.ID}, 200, "")
	file := filepath.Join(f.dir, "state.json")
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var db database
	if err := json.Unmarshal(raw, &db); err != nil {
		t.Fatal(err)
	}
	runPath := "/v1/ag-ui/workers/" + worker.ID + "/run"
	db.Receipts[receiptKey("", runPath, "legacy")] = db.Receipts[receiptKey("", path+"/messages", "legacy")]
	raw, err = json.Marshal(db)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if f.api, err = New(f.dir, f.p); err != nil {
		t.Fatal(err)
	}
	input := map[string]any{"threadId": worker.ID, "runId": "legacy", "forwardedProps": map[string]int{"generation": 2}}
	for _, content := range []any{"a b", []map[string]string{{"type": "text", "text": "a"}, {"type": "text", "text": " b"}}} {
		input["messages"] = []any{map[string]any{"role": "user", "content": content}}
		stream := f.call("POST", runPath, "", input, 200, "")
		if !bytes.Contains(stream, []byte(message.ID)) || !bytes.Contains(stream, []byte("RUN_FINISHED")) {
			t.Fatalf("old acceptance did not recover its completed operation: %s", stream)
		}
	}
	input["messages"] = []any{map[string]any{"role": "user", "content": "a different prompt"}}
	f.call("POST", runPath, "", input, 409, "")
	for _, content := range []any{[]map[string]string{{"type": "text"}, {"type": "text", "text": "valid"}},
		[]map[string]string{{"type": "text", "text": ""}, {"type": "text", "text": " \t"}}} {
		input["messages"] = []any{map[string]any{"role": "user", "content": content}}
		f.call("POST", runPath, "", input, 400, "")
	}
}

func TestAGUIWorkerRunTracksOneFollowUp(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "target")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/native-session", "", NativeSession{HarnessInstance: "local-claude", SessionID: "operation-preview"}, 200, "")
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")

	runPath := "/v1/ag-ui/workers/" + worker.ID + "/run"
	input := map[string]any{
		"threadId": worker.ID, "runId": "fixture-run",
		"forwardedProps": map[string]int{"generation": 2},
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]string{"type": "text", "text": "  literal\n"},
			map[string]string{"type": "text", "text": "$value  "},
		}}},
	}
	f.call("POST", runPath, worker.Token, input, 403, "")
	input["threadId"] = coordinator.ID
	f.call("POST", runPath, "", input, 400, "")
	input["threadId"] = worker.ID
	server := httptest.NewServer(f.api)
	defer server.Close()
	client := &http.Client{Timeout: 5 * time.Second}
	openRun := func() (*http.Response, *bufio.Scanner) {
		t.Helper()
		body, _ := json.Marshal(input)
		res, err := client.Post(server.URL+runPath, "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		if res.StatusCode != 200 || res.Header.Get("Content-Type") != "text/event-stream" {
			_ = res.Body.Close()
			t.Fatalf("unexpected run response: %s", res.Status)
		}
		return res, bufio.NewScanner(res.Body)
	}
	await := func(s *bufio.Scanner, name string) map[string]json.RawMessage {
		t.Helper()
		for s.Scan() {
			raw, ok := strings.CutPrefix(s.Text(), "data: ")
			if !ok {
				continue
			}
			var event map[string]json.RawMessage
			if err := json.Unmarshal([]byte(raw), &event); err != nil {
				t.Fatal(err)
			}
			if strings.HasPrefix(string(event["type"]), "\"TOOL_CALL_") {
				t.Fatal("an ordinary harness tool was exposed as a frontend invocation")
			}
			if string(event["type"]) == `"`+name+`"` {
				return event
			}
		}
		t.Fatalf("missing %s: %v", name, s.Err())
		return nil
	}
	var queued aguiRunState
	first, events := openRun()
	defer first.Body.Close()
	await(events, "RUN_STARTED")
	if err := json.Unmarshal(await(events, "STATE_SNAPSHOT")["snapshot"], &queued); err != nil || queued.OperationStatus != "queued" || queued.OperationID == "" {
		t.Fatalf("wrong queued state: %+v, %v", queued, err)
	}
	var message WorkerFollowUp
	if err := json.Unmarshal(f.call("POST", path+"/messages/"+queued.OperationID+"/claim", worker.Token, struct{}{}, 200, ""), &message); err != nil ||
		message.Text != "  literal\n$value  " {
		t.Fatalf("wrong provider prompt: %+v, %v", message, err)
	}
	var question Question
	if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token, map[string]string{"question": "Which choice?"}, 201, ""), &question); err != nil {
		t.Fatal(err)
	}
	for {
		var state aguiRunState
		if err := json.Unmarshal(await(events, "STATE_SNAPSHOT")["snapshot"], &state); err != nil {
			t.Fatal(err)
		}
		if len(state.PendingRequests) == 1 && state.PendingRequests[0].ID == question.ID {
			break
		}
	}
	replySuffix := "/requests/" + question.ID + "/reply"
	f.call("POST", "/v1/ag-ui/workers/"+coordinator.ID+replySuffix, "", map[string]string{"answer": "Choice A"}, 404, "")
	f.call("POST", "/v1/ag-ui/workers/"+worker.ID+replySuffix, "", map[string]string{"answer": "Choice A"}, 200, "")
	f.call("POST", "/v1/workers/"+coordinator.ID+"/questions", coordinator.Token, map[string]string{"question": "Other worker"}, 201, "")
	for {
		var state aguiRunState
		if err := json.Unmarshal(await(events, "STATE_SNAPSHOT")["snapshot"], &state); err != nil {
			t.Fatal(err)
		}
		if len(state.PendingRequests) == 0 {
			if len(state.Requests) != 1 || state.Requests[0].ID != question.ID ||
				state.Requests[0].Status != "answered" || state.Requests[0].Answer != "Choice A" {
				t.Fatalf("answered request or worker boundary lost in the live state: %+v", state)
			}
			break
		}
	}
	f.call("POST", path+"/output", worker.Token, map[string]any{"events": []ConsoleEvent{
		{Kind: "tool_call", ToolID: "fixture-1", Name: "Read"},
		{Kind: "tool_result", ToolID: "fixture-1", Text: "tool fixture result"},
	}}, 200, "")
	for {
		event := await(events, "MESSAGES_SNAPSHOT")
		if strings.Contains(string(event["messages"]), "tool fixture result") {
			break
		}
	}
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed", "message_id": queued.OperationID}, 200, "")
	await(events, "RUN_FINISHED")
	observationPath := "/v1/ag-ui/workers/" + worker.ID + "/operations/" + queued.OperationID
	f.call("GET", observationPath+"?runId=wrong-run", "", nil, 404, "")
	f.call("GET", observationPath+"?runId=fixture-run", worker.Token, nil, 403, "")
	observed, err := client.Get(server.URL + observationPath + "?runId=fixture-run")
	if err != nil {
		t.Fatal(err)
	}
	defer observed.Body.Close()
	if observed.StatusCode != 200 {
		t.Fatalf("reconnect failed: %s", observed.Status)
	}
	reconnect := bufio.NewScanner(observed.Body)
	var resumed aguiRunState
	if err := json.Unmarshal(await(reconnect, "STATE_SNAPSHOT")["snapshot"], &resumed); err != nil ||
		len(resumed.Requests) != 1 || resumed.Requests[0].ID != question.ID || resumed.Requests[0].Answer != "Choice A" {
		t.Fatalf("reconnect lost the recorded answer: %+v, %v", resumed, err)
	}
	await(reconnect, "RUN_FINISHED")
	retry, retryEvents := openRun()
	defer retry.Body.Close()
	var restored aguiRunState
	if err := json.Unmarshal(await(retryEvents, "STATE_SNAPSHOT")["snapshot"], &restored); err != nil ||
		restored.OperationID != queued.OperationID || restored.OperationStatus != "completed" {
		t.Fatalf("retry changed operation: %+v, %v", restored, err)
	}
	await(retryEvents, "RUN_FINISHED")
	input["messages"] = []any{map[string]string{"role": "user", "content": "  literal\n$value  "}}
	f.call("POST", runPath, "", input, 409, "")
	input["messages"] = []any{map[string]string{"role": "user", "content": "different intent"}}
	f.call("POST", runPath, "", input, 409, "")

	input["runId"] = "later-run"
	later, laterEvents := openRun()
	var next aguiRunState
	if err := json.Unmarshal(await(laterEvents, "STATE_SNAPSHOT")["snapshot"], &next); err != nil || next.OperationID == queued.OperationID {
		t.Fatalf("expected a different follow-up: %+v, %v", next, err)
	}
	_ = later.Body.Close()
	f.call("POST", path+"/messages/"+next.OperationID+"/claim", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/output", worker.Token, map[string]any{"events": []ConsoleEvent{
		{Kind: "text", Text: "later-operation-output"},
	}}, 200, "")
	var newQuestion Question
	if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token, map[string]string{"question": "Later operation approval?"}, 201, ""), &newQuestion); err != nil {
		t.Fatal(err)
	}
	assertOriginal := func(expected, excluded string) {
		t.Helper()
		raw := f.call("GET", observationPath+"?runId=fixture-run", "", nil, 200, "")
		text := string(raw)
		if !strings.Contains(text, expected) || strings.Contains(text, excluded) ||
			strings.Contains(text, newQuestion.ID) || !strings.Contains(text, question.ID) {
			t.Fatalf("old operation returned the wrong conversation: %s", text)
		}
		if !strings.Contains(text, `"status":"completed"`) || !strings.Contains(text, `"pendingRequests":[]`) {
			t.Fatalf("later operation changed the original state: %s", text)
		}
	}
	assertOriginal("tool fixture result", "later-operation-output")

	// Once the old window is gone, a reconnect reports the gap without
	// replacing the original operation with the latest worker output.
	for range 6 {
		output := make([]ConsoleEvent, 24)
		for i := range output {
			output[i] = ConsoleEvent{Kind: "text", Text: "later-operation-output"}
		}
		f.call("POST", path+"/output", worker.Token, map[string]any{"events": output}, 200, "")
	}
	assertOriginal("console preview for this operation is unavailable", "later-operation-output")

	f.api, err = New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.call("POST", path+"/output", worker.Token, map[string]any{"text": "New live output", "events": []ConsoleEvent{
		{Kind: "text", Text: "reused-preview-sequence-1"},
		{Kind: "text", Text: "reused-preview-sequence-2"},
	}}, 200, "")
	assertOriginal("console preview for this operation is unavailable", "reused-preview-sequence")
}
